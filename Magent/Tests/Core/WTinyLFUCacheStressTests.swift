//
//  WTinyLFUCacheStressTests.swift
//  Magent
//
//  Created by MarlinL on 2026/6/24.
//
//  正确性压测套件：覆盖并发读一致性 / 内存安全代理、重负载容量界、淘汰 + 热点存活、
//  getOrLoad 并发正确性、长跑稳定性。专门盯 get 热路径优化（UnfairLock / HashedKey /
//  无锁 MPMC 读缓冲）引入的并发改动，任何数据竞争 / use-after-free / 串值都会在此暴露。
//

import Foundation
import XCTest
@testable import Magent

final class WTinyLFUCacheStressTests: XCTestCase {

    // MARK: - 并发读一致性 / 内存安全代理

    /// value 是 key 的纯函数（每个 key 永远映射同一个规范值）。任何一次 get 命中
    /// 必须返回该规范值——脏值 / 串值 / 已释放对象的残留都会让断言失败。
    func testConcurrentGetAlwaysReturnsCanonicalValue() {
        let capacity = 1024
        let cache = WTinyLFUCache<Int>(capacity: capacity)
        defer { shutdownCache(cache) }

        let keyCount = 4096
        let key: @Sendable (Int) -> String = { "k-\($0)" }
        let expected: @Sendable (Int) -> Int = { $0 &* 2_654_435_761 }

        for index in 0..<keyCount {
            cache.put(key(index), expected(index))
        }
        waitMaintenance(cache, capacity: capacity)

        let mismatches = LockedCounter()
        let hits = LockedCounter()

        DispatchQueue.concurrentPerform(iterations: 200_000) { step in
            let index = step % keyCount
            if step % 7 == 0 {
                // 写者：幂等地重写规范值（驱动淘汰）
                cache.put(key(index), expected(index))
            } else {
                // 读者
                if let value = cache.get(key(index)) {
                    hits.increment()
                    if value != expected(index) {
                        mismatches.increment()
                    }
                }
            }
        }

        waitMaintenance(cache, capacity: capacity)

        XCTAssertGreaterThan(hits.value, 0, "应当至少命中一次")
        XCTAssertEqual(mismatches.value, 0, "get 返回了非规范值（脏值 / 串值 / UAF）")
        XCTAssertLessThanOrEqual(cache.estimatedSize(), capacity * 2)
    }

    // MARK: - 重负载并发容量界

    func testHeavyConcurrentMixStaysBounded() {
        let capacity = 256
        let cache = WTinyLFUCache<Int>(capacity: capacity)
        defer { shutdownCache(cache) }

        DispatchQueue.concurrentPerform(iterations: 500_000) { step in
            switch step % 6 {
            case 0:
                cache.put("k-\(step % 5000)", step)
            case 1:
                _ = cache.get("k-\(step % 5000)")
            case 2:
                cache.invalidate("k-\(step % 5000)")
            case 3:
                cache.put("shared-\(step % 64)", step)
            case 4:
                if step % 200 == 0 {
                    cache.removeAll()
                } else {
                    _ = cache.get("shared-\(step % 64)")
                }
            default:
                _ = cache.getOrLoad("load-\(step % 128)") { _ in step }
            }
        }

        waitMaintenance(cache, capacity: capacity)
        XCTAssertLessThanOrEqual(cache.estimatedSize(), capacity)
    }

    func testSustainedWritePressureKeepsTransientSizeBoundedAndConverges() {
        let capacity = 128
        let cache = WTinyLFUCache<Int>(capacity: capacity)
        defer { shutdownCache(cache) }
        var peakSize = 0

        for step in 0..<100_000 {
            cache.put("pressure-\(step)", step)
            peakSize = max(peakSize, cache.estimatedSize())

            if step % 17 == 0 {
                _ = cache.get("pressure-\(max(0, step - 1))")
            }
        }

        waitMaintenance(cache, capacity: capacity)

        XCTAssertLessThanOrEqual(
            peakSize,
            capacity * 2,
            "写入压力下瞬时 size 超过 force-drain 预算：peak=\(peakSize), capacity=\(capacity)"
        )
        XCTAssertLessThanOrEqual(cache.estimatedSize(), capacity)
    }

    // MARK: - 淘汰 + 热点存活

    func testZipfHotKeysSurviveEviction() {
        let capacity = 512
        let cache = WTinyLFUCache<Int>(capacity: capacity)
        defer { shutdownCache(cache) }

        let hotCount = 256
        for index in 0..<hotCount {
            cache.put("hot-\(index)", index)
        }
        waitMaintenance(cache, capacity: capacity)

        let hits = LockedCounter()
        let total = 300_000

        DispatchQueue.concurrentPerform(iterations: total) { step in
            // min-of-three 近似 Zipf，偏向小编号（热点）
            let hotIndex = min(step % hotCount, (step / 7) % hotCount, (step / 13) % hotCount)
            if cache.get("hot-\(hotIndex)") != nil {
                hits.increment()
            }
            if step % 50 == 0 {
                cache.put("cold-\(step)", step)  // 冷 key 驱动淘汰
            }
        }

        waitMaintenance(cache, capacity: capacity)

        XCTAssertLessThanOrEqual(cache.estimatedSize(), capacity)
        let hitRate = Double(hits.value) / Double(total)
        XCTAssertGreaterThan(
            hitRate,
            0.5,
            "热点 key 应在淘汰中存活，命中率 \(hitRate) 过低（可能存在错误淘汰 / 数据丢失）"
        )
    }

    // MARK: - getOrLoad 并发正确性

    func testConcurrentGetOrLoadReturnsDeterministicValue() {
        let capacity = 256
        let cache = WTinyLFUCache<Int>(capacity: capacity)
        defer { shutdownCache(cache) }

        let loadCount = LockedCounter()
        let mismatches = LockedCounter()

        let hashOf: @Sendable (String) -> Int = { key in
            var hash = 0
            for scalar in key.unicodeScalars {
                hash = hash &* 31 &+ Int(scalar.value)
            }
            return hash
        }

        let loader: @Sendable (String) -> Int = { key in
            loadCount.increment()
            return hashOf(key)
        }

        DispatchQueue.concurrentPerform(iterations: 100_000) { step in
            let key = "gol-\(step % 1024)"
            let value = cache.getOrLoad(key, loader)
            if value != hashOf(key) {
                mismatches.increment()
            }
        }

        waitMaintenance(cache, capacity: capacity)

        XCTAssertGreaterThan(loadCount.value, 0, "loader 应当被调用过")
        XCTAssertEqual(mismatches.value, 0, "getOrLoad 返回了非规范值")
        XCTAssertLessThanOrEqual(cache.estimatedSize(), capacity)
    }

    // MARK: - 长跑稳定性（死锁 / size 泄漏 / 卡死）

    func testLongRunningMixedOpsStayStableAndBounded() {
        let capacity = 512
        let cache = WTinyLFUCache<Int>(capacity: capacity)
        defer { shutdownCache(cache) }

        let stop = LockedFlag()
        let group = DispatchGroup()
        let workerCount = 6

        for worker in 0..<workerCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var seed = UInt64(1000 + worker)
                while stop.value == false {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1
                    let roll = Int(seed % 100)
                    let index = Int(seed % 8192)
                    if roll < 40 {
                        cache.put("k-\(index)", index)
                    } else if roll < 85 {
                        _ = cache.get("k-\(index)")
                    } else if roll < 95 {
                        cache.invalidate("k-\(index)")
                    } else {
                        cache.removeAll()
                    }
                }
                group.leave()
            }
        }

        Thread.sleep(forTimeInterval: 4)
        stop.set(true)
        group.wait()  // 若出现死锁，这里会挂到测试超时

        waitMaintenance(cache, capacity: capacity)
        XCTAssertLessThanOrEqual(cache.estimatedSize(), capacity)

        // 长跑后仍应功能正常
        cache.put("probe", 42)
        waitMaintenance(cache, capacity: capacity)
        XCTAssertEqual(cache.get("probe"), 42)
    }
}

// MARK: - Helpers

private func waitMaintenance<Object: Sendable>(
    _ cache: WTinyLFUCache<Object>,
    capacity: Int,
    timeout: TimeInterval = 5
) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cache.estimatedSize() <= capacity {
            return
        }
        Thread.sleep(forTimeInterval: 0.005)
    }
}

private func shutdownCache<Object: Sendable>(_ cache: WTinyLFUCache<Object>) {
    let semaphore = DispatchSemaphore(value: 0)
    cache.shutdownGracefully { _ in
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ flag: Bool) {
        lock.lock()
        storage = flag
        lock.unlock()
    }
}
