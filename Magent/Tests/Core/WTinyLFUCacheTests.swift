//
//  WTinyLFUCacheTests.swift
//  Magent
//
//  Created by MarlinL on 2026/6/23.
//

import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest
@testable import Magent

// MARK: - WTinyLFUCache Public API Tests

/// WTinyLFUCache 对外 API 和并发容量边界测试。
final class WTinyLFUCacheTests: XCTestCase {

    /// 未写入的 key 应返回 nil。
    func testGetReturnsNilForMissingKey() {
        let cache = WTinyLFUCache<String>(capacity: 4)
        defer { shutdown(cache) }

        XCTAssertNil(cache.get("missing"))
    }

    /// `put` 后应能通过同一个 key 读回对象。
    func testPutThenGetReturnsStoredObject() {
        let cache = WTinyLFUCache<String>(capacity: 4)
        defer { shutdown(cache) }

        cache.put("k1", "v1")

        XCTAssertEqual(cache.get("k1"), "v1")
    }

    /// `afterRead` 新节点应以创建时间作为首次读取时间，不能在第一次读取时直接过期。
    func testAfterReadFirstReadReturnsStoredObject() {
        let cache = WTinyLFUCache<String>(capacity: 4, expiration: .afterRead(.seconds(60)))
        defer { shutdown(cache) }

        cache.put("k1", "v1")

        XCTAssertTrue(cache.contains("k1"))
        XCTAssertEqual(cache.get("k1"), "v1")
    }

    /// 并发续期使用一次性 CAS；某个线程续期失败不能让仍有效的节点变成 miss。
    func testAfterReadConcurrentReadsKeepEntryVisible() {
        let cache = WTinyLFUCache<String>(capacity: 4, expiration: .afterRead(.seconds(60)))
        defer { shutdown(cache) }
        let misses = LockedIntCounter()
        cache.put("k1", "v1")

        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in
            if cache.get("k1") == nil {
                misses.increment()
            }
        }

        XCTAssertEqual(misses.value, 0)
    }

    /// `afterWrite` 到期后，首次校验应删除节点并且只回调一次。
    func testAfterWriteExpiresEntryAndEvictsOnce() {
        let evictions = LockedIntCounter()
        let cache = WTinyLFUCache<String>(capacity: 4, expiration: .afterWrite(.milliseconds(50))) { _ in
            evictions.increment()
        }
        defer { shutdown(cache) }

        cache.put("k1", "v1")

        XCTAssertTrue(eventually(timeout: 1, interval: 0.005) { cache.contains("k1") == false })
        XCTAssertNil(cache.get("k1"))
        XCTAssertEqual(evictions.value, 1)
    }

    /// `afterRead` 命中应从本次读取重新计算 TTL，而不是继续使用节点创建时间。
    func testAfterReadRenewsEntryUntilLastReadExpires() {
        let cache = WTinyLFUCache<String>(capacity: 4, expiration: .afterRead(.milliseconds(500)))
        defer { shutdown(cache) }

        cache.put("k1", "v1")
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(cache.get("k1"), "v1")

        Thread.sleep(forTimeInterval: 0.35)
        XCTAssertEqual(cache.get("k1"), "v1")
        XCTAssertTrue(eventually(timeout: 1) { cache.contains("k1") == false })
    }

    /// `Sendable` value 的 cache 应可安全传入并发边界。
    func testCacheWithSendableValueIsSendable() {
        let cache = WTinyLFUCache<String>(capacity: 4)
        defer { shutdown(cache) }

        requireSendable(cache)
    }

    /// 重复写入同一 key 应更新对象且不增加 size。
    func testPutExistingKeyUpdatesObject() {
        let cache = WTinyLFUCache<String>(capacity: 4)
        defer { shutdown(cache) }

        cache.put("k1", "v1")
        cache.put("k1", "v2")

        XCTAssertEqual(cache.get("k1"), "v2")
        XCTAssertEqual(cache.estimatedSize(), 1)
    }

    /// `invalidate` 应删除单个 key。
    func testInvalidateRemovesObject() {
        let cache = WTinyLFUCache<String>(capacity: 4)
        defer { shutdown(cache) }

        cache.put("k1", "v1")
        cache.invalidate("k1")

        XCTAssertNil(cache.get("k1"))
        XCTAssertEqual(cache.estimatedSize(), 0)
    }

    /// 同一个节点只有成功从 map 删除的路径可以触发一次淘汰回调。
    func testInvalidateCallsOnEvictExactlyOnce() {
        let evictions = LockedIntCounter()
        let cache = WTinyLFUCache<String>(capacity: 4) { _ in evictions.increment() }
        defer { shutdown(cache) }

        cache.put("k1", "v1")
        cache.invalidate("k1")
        cache.invalidate("k1")

        XCTAssertEqual(evictions.value, 1)
    }

    /// 淘汰回调应在 cache 内部锁释放后执行，允许业务回调重新进入同一个 cache。
    func testOnEvictCanReenterCache() {
        let cacheReference = WTinyLFUCacheReference<String>()
        let cache = WTinyLFUCache<String>(capacity: 4) { _ in
            cacheReference.cache?.put("from-callback", "value")
        }
        cacheReference.cache = cache
        defer { shutdown(cache) }

        cache.put("k1", "v1")
        cache.invalidate("k1")

        XCTAssertEqual(cache.get("from-callback"), "value")
    }

    /// `removeAll` 应清空所有 key。
    func testRemoveAllClearsObjects() {
        let cache = WTinyLFUCache<String>(capacity: 4)
        defer { shutdown(cache) }

        cache.put("k1", "v1")
        cache.put("k2", "v2")
        cache.removeAll()

        XCTAssertNil(cache.get("k1"))
        XCTAssertNil(cache.get("k2"))
        XCTAssertEqual(cache.estimatedSize(), 0)
    }

    /// `removeAll` 只回调本次实际移除的节点，重复清空不能重复通知。
    func testRemoveAllCallsOnEvictOncePerRemovedEntry() {
        let evictions = LockedIntCounter()
        let cache = WTinyLFUCache<String>(capacity: 4) { _ in evictions.increment() }
        defer { shutdown(cache) }

        cache.put("k1", "v1")
        cache.put("k2", "v2")
        cache.removeAll()
        cache.removeAll()

        XCTAssertEqual(evictions.value, 2)
    }

    /// 容量为 0 时不存储对象，但 `getOrLoad` 仍应调用 loader 返回值。
    func testCapacityZeroDisablesStorageButAllowsLoaderBypass() {
        let cache = WTinyLFUCache<String>(capacity: 0)
        defer { shutdown(cache) }
        var loadCount = 0

        let loader: (String) -> String = { key in
            loadCount += 1
            return "loaded-\(key)"
        }

        XCTAssertEqual(cache.getOrLoad("k1", loader), "loaded-k1")
        XCTAssertEqual(cache.getOrLoad("k1", loader), "loaded-k1")
        XCTAssertNil(cache.get("k1"))
        XCTAssertEqual(cache.estimatedSize(), 0)
        XCTAssertEqual(loadCount, 2)
    }

    /// `getOrLoad` miss 后应写回缓存，后续读取不再调用 loader。
    func testGetOrLoadLoadsAndCachesObject() {
        let cache = WTinyLFUCache<String>(capacity: 4)
        defer { shutdown(cache) }
        var loadCount = 0

        let loader: (String) -> String = { key in
            loadCount += 1
            return "loaded-\(key)"
        }

        XCTAssertEqual(cache.getOrLoad("k1", loader), "loaded-k1")
        XCTAssertEqual(cache.get("k1"), "loaded-k1")
        XCTAssertEqual(cache.getOrLoad("k1", loader), "loaded-k1")
        XCTAssertEqual(loadCount, 1)
    }

    /// `getOrLoad` 命中已有对象时不应调用 loader。
    func testGetOrLoadHitDoesNotCallLoader() {
        let cache = WTinyLFUCache<String>(capacity: 4)
        defer { shutdown(cache) }

        cache.put("k1", "cached")

        let value = cache.getOrLoad("k1") { _ in
            XCTFail("Loader should not be called on cache hit")
            return "loaded"
        }

        XCTAssertEqual(value, "cached")
    }

    /// 并发读写和 loading 不应破坏容量收敛。
    func testGetOrLoadConcurrentNormalReadsAndWrites() {
        let cache = WTinyLFUCache<String>(capacity: 4)
        defer { shutdown(cache) }
        let loadCount = LockedIntCounter()

        let loader: @Sendable (String) -> String = { key in
            loadCount.increment()
            return "loaded-\(key)"
        }

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            let key = "k\(index % 8)"
            XCTAssertEqual(cache.getOrLoad(key, loader), "loaded-\(key)")
        }

        XCTAssertGreaterThan(loadCount.value, 0)
        XCTAssertTrue(eventually { cache.estimatedSize() <= 4 })
    }

    /// 不同 key 的 loader 调用应互相独立。
    func testDifferentKeysLoadIndependently() {
        let cache = WTinyLFUCache<String>(capacity: 4)
        defer { shutdown(cache) }
        let lock = NSLock()
        var loadedKeys: [String] = []

        let loader: (String) -> String = { key in
            lock.lock()
            loadedKeys.append(key)
            lock.unlock()
            return "loaded-\(key)"
        }

        XCTAssertEqual(cache.getOrLoad("k1", loader), "loaded-k1")
        XCTAssertEqual(cache.getOrLoad("k2", loader), "loaded-k2")

        lock.lock()
        let keys = loadedKeys
        lock.unlock()
        XCTAssertEqual(Set(keys), Set(["k1", "k2"]))
    }

    /// `getOrLoad` 应可安全地从多个 NIO EventLoop 调用。
    func testGetOrLoadCanBeCalledFromMultipleEventLoops() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { shutdown(group) }
        let cache = WTinyLFUCache<Int>(capacity: 32)
        defer { shutdown(cache) }

        let futures = (0..<128).map { index in
            group.next().submit {
                let key = "nio-\(index % 16)"
                return cache.getOrLoad(key) { canonicalIntValue(for: $0) }
            }
        }

        let values = try EventLoopFuture.whenAllSucceed(futures, on: group.next()).wait()

        XCTAssertEqual(values.count, 128)
        for index in values.indices {
            XCTAssertEqual(values[index], canonicalIntValue(for: "nio-\(index % 16)"))
        }
        XCTAssertTrue(eventually { cache.estimatedSize() <= 32 })
    }

    /// `getOrLoad` 应可在 ChannelHandler 的 EventLoop 回调中完成读写。
    func testGetOrLoadWorksInsideChannelHandler() throws {
        let cache = WTinyLFUCache<String>(capacity: 4)
        defer { shutdown(cache) }
        let channel = EmbeddedChannel(handler: WTinyLFUCacheChannelHandler(cache: cache))

        var inbound = channel.allocator.buffer(capacity: 16)
        inbound.writeString("channel-key")

        try channel.writeInbound(inbound)
        channel.embeddedEventLoop.run()

        var outbound = try XCTUnwrap(channel.readOutbound(as: ByteBuffer.self))
        XCTAssertEqual(outbound.readString(length: outbound.readableBytes), "loaded-channel-key")
        XCTAssertEqual(cache.get("channel-key"), "loaded-channel-key")

        _ = try channel.finish()
    }

    /// cache 关闭后 `getOrLoad` 应绕过缓存并直接调用 loader。
    func testShutdownGetOrLoadBypassesCacheAndUsesLoader() {
        let cache = WTinyLFUCache<String>(capacity: 4)
        shutdown(cache)

        XCTAssertEqual(cache.getOrLoad("k1") { "loaded-\($0)" }, "loaded-k1")
        XCTAssertNil(cache.get("k1"))
    }

    func testShutdownMakesAllMutationsNoOps() {
        let cache = WTinyLFUCache<String>(capacity: 4)
        cache.put("existing", "value")
        XCTAssertTrue(eventually { cache.get("existing") == "value" })
        shutdown(cache)

        let size = cache.estimatedSize()
        cache.put("new", "new-value")
        cache.invalidate("existing")
        cache.removeAll()

        XCTAssertEqual(cache.get("existing"), "value")
        XCTAssertNil(cache.get("new"))
        XCTAssertEqual(cache.estimatedSize(), size)
    }

    /// 重复 shutdown 的每个 callback 都应经过同一个 maintenance barrier。
    func testRepeatedShutdownCompletesEveryCallback() {
        let cache = WTinyLFUCache<Int>(capacity: 16)
        let first = expectation(description: "first shutdown")
        let second = expectation(description: "second shutdown")

        for index in 0..<256 {
            cache.put("k\(index)", index)
        }

        cache.shutdownGracefully { error in
            XCTAssertNil(error)
            first.fulfill()
        }
        cache.shutdownGracefully { error in
            XCTAssertNil(error)
            second.fulfill()
        }

        wait(for: [first, second], timeout: 5)
    }

    /// shutdown callback 返回后，之前已经发起的并发 mutation 也不能继续改变 cache。
    func testShutdownCallbackFormsMutationBarrier() {
        let cache = WTinyLFUCache<Int>(capacity: 64)
        let workers = DispatchGroup()

        for worker in 0..<8 {
            workers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for index in 0..<10_000 {
                    cache.put("worker-\(worker)-\(index)", index)
                }
                workers.leave()
            }
        }

        let shutdown = expectation(description: "shutdown barrier")
        cache.shutdownGracefully { error in
            XCTAssertNil(error)
            shutdown.fulfill()
        }
        wait(for: [shutdown], timeout: 5)

        let sizeAfterShutdown = cache.estimatedSize()
        XCTAssertEqual(workers.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(cache.estimatedSize(), sizeAfterShutdown)
    }

    /// 连续写入超过容量后最终应收敛到容量以内。
    func testCapacityEventuallyConvergesAfterWrites() {
        let cache = WTinyLFUCache<Int>(capacity: 2)
        defer { shutdown(cache) }

        for key in 0..<20 {
            cache.put("k\(key)", key)
        }

        XCTAssertTrue(eventually { cache.estimatedSize() <= 2 })
    }

    /// burst 写入期间允许短暂超量，但不能超过约束上界。
    func testCapacityOvershootIsBoundedDuringBurstWrites() {
        let capacity = 8
        let cache = WTinyLFUCache<Int>(capacity: capacity)
        defer { shutdown(cache) }

        for key in 0..<500 {
            cache.put("k\(key)", key)
            XCTAssertLessThanOrEqual(cache.estimatedSize(), capacity * 2)
        }

        XCTAssertTrue(eventually { cache.estimatedSize() <= capacity })
    }

    /// 另一线程在 put 内部任意时点观察 size，也不能看到超过两倍容量的瞬时状态。
    func testConcurrentObserverNeverSeesBeyondTransientLimit() {
        let capacity = 8
        let cache = WTinyLFUCache<Int>(capacity: capacity)
        defer { shutdown(cache) }
        let writer = DispatchGroup()
        var peakSize = 0

        writer.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            for index in 0..<100_000 {
                cache.put("observed-\(index)", index)
            }
            writer.leave()
        }

        while writer.wait(timeout: .now()) == .timedOut {
            peakSize = max(peakSize, cache.estimatedSize())
        }
        peakSize = max(peakSize, cache.estimatedSize())

        XCTAssertLessThanOrEqual(peakSize, capacity * 2)
        XCTAssertTrue(eventually { cache.estimatedSize() <= capacity })
    }

    /// 多线程混合 put/get/invalidate/removeAll 后容量仍应收敛。
    func testConcurrentMutationsStayBounded() {
        let capacity = 16
        let cache = WTinyLFUCache<Int>(capacity: capacity)
        defer { shutdown(cache) }

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            switch index % 5 {
            case 0:
                cache.put("k\(index)", index)
            case 1:
                _ = cache.get("k\(index - 1)")
            case 2:
                cache.invalidate("k\(index - 2)")
            case 3:
                cache.put("shared-\(index % 32)", index)
            default:
                if index % 100 == 0 {
                    cache.removeAll()
                } else {
                    _ = cache.get("shared-\(index % 32)")
                }
            }
        }

        XCTAssertLessThanOrEqual(cache.estimatedSize(), capacity * 2)
        XCTAssertTrue(eventually { cache.estimatedSize() <= capacity })
    }

    /// removeAll + shutdown 后应释放缓存对象，避免节点或链表形成 ARC 保留环。
    func testRemoveAllAndShutdownReleaseCachedObjects() {
        let deinitCounter = LockedIntCounter()
        var cache: WTinyLFUCache<CacheARCProbe>? = WTinyLFUCache(capacity: 32)
        weak var weakCache: WTinyLFUCache<CacheARCProbe>?
        weakCache = cache

        for index in 0..<32 {
            cache?.put("probe-\(index)", CacheARCProbe {
                deinitCounter.increment()
            })
        }

        XCTAssertTrue(eventually { cache?.estimatedSize() == 32 })

        cache?.removeAll()

        XCTAssertTrue(eventually { cache?.estimatedSize() == 0 })
        if let liveCache = cache {
            shutdown(liveCache)
        }
        cache = nil

        XCTAssertNil(weakCache)
        XCTAssertTrue(eventually { deinitCounter.value == 32 })
    }
}

// MARK: - MagentCache Tests

/// MagentCache 包装层测试。
final class MagentCacheTests: XCTestCase {

    /// MagentCache 应按 key 缓存当前 Core 使用的 Decision loader 结果。
    func testGetOrLoadCachesDecision() {
        let cache = MagentCache<Decision>(capacity: 2)
        defer { shutdownMagentCache(cache) }
        let proxyID = UUID()
        var loadCount = 0

        let loader: (String) -> Decision = { _ in
            loadCount += 1
            return .proxy(proxyID)
        }

        let first = cache.getOrLoad("domain|example.com|443", loader)
        let second = cache.getOrLoad("domain|example.com|443", loader)

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(first, .proxy(proxyID))
        XCTAssertEqual(second, .proxy(proxyID))
        XCTAssertEqual(cache.estimatedSize(), 1)
    }
}

// MARK: - Internal Structure Tests

/// W-TinyLFU 内部结构和维护事件测试。
final class WTinyLFUInternalStructureTests: XCTestCase {

    /// 容量拆分应符合 window/main/protected 的约定比例。
    func testCapacitySplitRules() {
        XCTAssertEqual(CapacitySplit(maximum: 0).windowMaximum, 0)
        XCTAssertEqual(CapacitySplit(maximum: 1).windowMaximum, 1)
        XCTAssertEqual(CapacitySplit(maximum: 1).mainMaximum, 0)
        XCTAssertEqual(CapacitySplit(maximum: 2).windowMaximum, 1)
        XCTAssertEqual(CapacitySplit(maximum: 2).mainMaximum, 1)
        XCTAssertEqual(CapacitySplit(maximum: 2).mainProtectedMaximum, 0)

        let split = CapacitySplit(maximum: 100)
        XCTAssertEqual(split.windowMaximum, 1)
        XCTAssertEqual(split.mainMaximum, 99)
        XCTAssertEqual(split.mainProtectedMaximum, 79)
        XCTAssertEqual(split.mainProbationMaximum, 20)
    }

    /// 访问顺序链表应支持追加、提升、删除和清空。
    func testAccessOrderDequeAppendMoveRemoveAndClear() {
        let deque = AccessOrderDeque<Int>()
        let n1 = Node(key: "1", object: 1, segment: .window)
        let n2 = Node(key: "2", object: 2, segment: .window)
        let n3 = Node(key: "3", object: 3, segment: .window)

        deque.appendToHead(n1)
        deque.appendToHead(n2)
        deque.appendToHead(n3)

        XCTAssertTrue(deque.head === n3)
        XCTAssertTrue(deque.tail === n1)
        XCTAssertEqual(deque.count, 3)

        deque.moveToHead(n1)
        XCTAssertTrue(deque.head === n1)
        XCTAssertTrue(deque.tail === n2)

        deque.remove(n3)
        XCTAssertFalse(n3.isLinked)
        XCTAssertNil(n3.previous)
        XCTAssertNil(n3.next)
        XCTAssertEqual(deque.count, 2)

        XCTAssertTrue(deque.removeTail() === n2)
        XCTAssertEqual(deque.count, 1)

        deque.removeAll()
        XCTAssertNil(deque.head)
        XCTAssertNil(deque.tail)
        XCTAssertEqual(deque.count, 0)
        XCTAssertFalse(n1.isLinked)
    }

    /// 频率草图应记录、饱和并在采样窗口后老化。
    func testFrequencySketchRecordsSaturatesAndAges() {
        var sketch = FrequencySketch(maximumSize: 16)
        let lowHash = stableHash("low")
        let hotHash = stableHash("hot")

        sketch.record(lowHash)
        for _ in 0..<20 {
            sketch.record(hotHash)
        }

        XCTAssertGreaterThanOrEqual(sketch.estimate(hotHash), sketch.estimate(lowHash))
        XCTAssertLessThanOrEqual(sketch.estimate(hotHash), 15)

        var agingSketch = FrequencySketch(maximumSize: 1)
        let agingHash = stableHash("k")
        for _ in 0..<9 {
            agingSketch.record(agingHash)
        }
        let beforeAging = agingSketch.estimate(agingHash)
        agingSketch.record(agingHash)
        let afterAging = agingSketch.estimate(agingHash)

        XCTAssertLessThanOrEqual(afterAging, beforeAging)
    }

    /// 分片字符串 map 应支持插入、更新、按节点删除和 generation 替换。
    func testConcurrentStringMapPutUpdateRemoveAndRemoveIfSameNode() throws {
        let map = ConcurrentStringMap<String>()
        let k1Hash = stableHash("k1")

        XCTAssertNil(map.getNodeAndObject("k1", keyHash: k1Hash))

        switch map.putOrUpdate("k1", keyHash: k1Hash, "v1", generation: 0) {
        case .inserted(let node, let replaced):
            XCTAssertEqual(node.object, "v1")
            XCTAssertNil(replaced)
        case .updated:
            XCTFail("Expected insert")
        }

        switch map.putOrUpdate("k1", keyHash: k1Hash, "v2", generation: 0) {
        case .inserted(_, _):
            XCTFail("Expected update")
        case .updated(let node):
            XCTAssertEqual(node.object, "v2")
        }

        let stored = try XCTUnwrap(map.getNodeAndObject("k1", keyHash: k1Hash)?.node)
        let replacement = Node(key: "k1", object: "replacement", segment: .window)
        XCTAssertFalse(map.removeIfSameNode("k1", keyHash: k1Hash, replacement))
        XCTAssertNotNil(map.getNodeAndObject("k1", keyHash: k1Hash))

        XCTAssertTrue(map.removeIfSameNode("k1", keyHash: k1Hash, stored))
        XCTAssertNil(map.getNodeAndObject("k1", keyHash: k1Hash))

        let generationHash = stableHash("generation")
        let oldGenerationNode: Node<String>
        switch map.putOrUpdate("generation", keyHash: generationHash, "old", generation: 0) {
        case .inserted(let node, let replaced):
            oldGenerationNode = node
            XCTAssertNil(replaced)
        case .updated:
            XCTFail("Expected generation setup insert")
            return
        }

        switch map.putOrUpdate("generation", keyHash: generationHash, "new", generation: 1) {
        case .inserted(let node, let replaced):
            XCTAssertTrue(replaced === oldGenerationNode)
            XCTAssertEqual(node.object, "new")
        case .updated:
            XCTFail("Expected generation replacement insert")
        }
        XCTAssertEqual(map.estimatedSize(), 1)
        XCTAssertEqual(map.getNodeAndObject("generation", keyHash: generationHash)?.object, "new")
        XCTAssertNotNil(map.remove("generation", keyHash: generationHash))
        XCTAssertEqual(map.estimatedSize(), 0)

        let k2Hash = stableHash("k2")
        _ = map.putOrUpdate("k2", keyHash: k2Hash, "v2", generation: 0)
        XCTAssertEqual(map.estimatedSize(), 1)
        XCTAssertNotNil(map.remove("k2", keyHash: k2Hash))
        XCTAssertEqual(map.estimatedSize(), 0)
    }

    /// `removeAll` 应返回本次真正取得删除所有权的节点，并在后续调用时返回空数组。
    func testConcurrentStringMapRemoveAllReturnsRemovedNodes() {
        let map = ConcurrentStringMap<String>()
        _ = map.putOrUpdate("k1", keyHash: stableHash("k1"), "v1", generation: 0)
        _ = map.putOrUpdate("k2", keyHash: stableHash("k2"), "v2", generation: 0)

        let removed = map.removeAll()

        XCTAssertEqual(Set(removed.map(\.key)), Set(["k1", "k2"]))
        XCTAssertEqual(map.estimatedSize(), 0)
        XCTAssertTrue(map.removeAll().isEmpty)
    }

    /// 读缓冲应按顺序提供 hit/miss 维护事件。
    func testReadBufferOffersAndPollsEvents() {
        let buffer = ReadBuffer<Int>()
        let node = Node(key: "k1", object: 1, segment: .window)

        XCTAssertFalse(buffer.hasPending)
        buffer.offer(.hit(keyHash: node.keyHash, node: node, generation: 7))
        buffer.offer(.miss(keyHash: stableHash("k2"), generation: 8))
        XCTAssertTrue(buffer.hasPending)

        guard case .hit(let hitHash, let hitNode, let hitGeneration)? = buffer.poll() else {
            return XCTFail("Expected hit event")
        }
        XCTAssertEqual(hitHash, node.keyHash)
        XCTAssertTrue(hitNode === node)
        XCTAssertEqual(hitGeneration, 7)

        guard case .miss(let missHash, let missGeneration)? = buffer.poll() else {
            return XCTFail("Expected miss event")
        }
        XCTAssertEqual(missHash, stableHash("k2"))
        XCTAssertEqual(missGeneration, 8)
        XCTAssertFalse(buffer.hasPending)
    }

    /// 读缓冲清空后不应再产出旧事件。
    func testReadBufferRemoveAllDropsPendingEvents() {
        let buffer = ReadBuffer<Int>()
        let node = Node(key: "k1", object: 1, segment: .window)

        buffer.offer(.hit(keyHash: node.keyHash, node: node, generation: 0))
        buffer.offer(.miss(keyHash: stableHash("k2"), generation: 0))

        buffer.removeAll()

        XCTAssertFalse(buffer.hasPending)
        XCTAssertNil(buffer.poll())
    }

    /// 写缓冲应按顺序提供 add/remove/clear 维护事件。
    func testWriteBufferOffersAndPollsEvents() {
        let buffer = WriteBuffer<Int>(capacity: 8)
        let node = Node(key: "k1", object: 1, segment: .window)

        buffer.offer(.add(node))
        buffer.offer(.remove(node))
        buffer.offer(.clear(generation: 9))

        let events = buffer.pollBatch(limit: 3)
        XCTAssertEqual(events.count, 3)
        guard case .add(let added) = events[0] else {
            return XCTFail("Expected add event")
        }
        XCTAssertTrue(added === node)

        guard case .remove(let removed) = events[1] else {
            return XCTFail("Expected remove event")
        }
        XCTAssertTrue(removed === node)

        guard case .clear(let generation) = events[2] else {
            return XCTFail("Expected clear event")
        }
        XCTAssertEqual(generation, 9)
        XCTAssertFalse(buffer.hasPending)
    }

    /// 写缓冲清空后不应再产出旧事件。
    func testWriteBufferRemoveAllDropsPendingEvents() {
        let buffer = WriteBuffer<Int>(capacity: 8)
        let node = Node(key: "k1", object: 1, segment: .window)

        buffer.offer(.add(node))
        buffer.offer(.remove(node))

        buffer.removeAll()

        XCTAssertFalse(buffer.hasPending)
        XCTAssertTrue(buffer.pollBatch(limit: 1).isEmpty)
    }

    func testWriteBufferRejectsEventsBeyondCapacityUntilConsumed() {
        let buffer = WriteBuffer<Int>(capacity: 2)
        let first = Node(key: "first", object: 1, segment: .window)
        let second = Node(key: "second", object: 2, segment: .window)
        let third = Node(key: "third", object: 3, segment: .window)

        XCTAssertTrue(buffer.offer(.add(first)))
        XCTAssertTrue(buffer.offer(.add(second)))
        XCTAssertFalse(buffer.offer(.add(third)))
        XCTAssertEqual(buffer.pollBatch(limit: 1).count, 1)
        XCTAssertTrue(buffer.offer(.add(third)))
    }

    /// policy clear 后应忽略旧 generation 的 read 事件，避免污染新缓存状态。
    func testPolicyClearIgnoresStaleReadEventsFromPreviousGeneration() throws {
        let data = ConcurrentStringMap<Int>()
        let generation = CacheGeneration()
        let policy = PolicyState(maximum: 16, data: data, generation: generation)
        let staleHash = stableHash("stale")

        XCTAssertEqual(generation.advance(), 1)
        XCTAssertTrue(policy.applyWrites([.clear(generation: 1)]).isEmpty)
        policy.applyReads(Array(repeating: ReadEvent<Int>.miss(keyHash: staleHash, generation: 0), count: 100))

        for index in 0..<16 {
            let key = "main-\(index)"
            let keyHash = stableHash(key)
            _ = data.putOrUpdate(key, keyHash: keyHash, index, generation: 1)
            let node = try XCTUnwrap(data.getNodeAndObject(key, keyHash: keyHash)?.node)
            _ = policy.applyWrites([.add(node)])
        }

        for index in 0..<15 {
            let key = "main-\(index)"
            let keyHash = stableHash(key)
            let node = try XCTUnwrap(data.getNodeAndObject(key, keyHash: keyHash)?.node)
            policy.applyReads([.hit(keyHash: node.keyHash, node: node, generation: 1)])
        }

        _ = data.putOrUpdate("stale", keyHash: staleHash, 100, generation: 1)
        let stale = try XCTUnwrap(data.getNodeAndObject("stale", keyHash: staleHash)?.node)
        _ = policy.applyWrites([.add(stale)])

        let triggerHash = stableHash("trigger")
        _ = data.putOrUpdate("trigger", keyHash: triggerHash, 101, generation: 1)
        let trigger = try XCTUnwrap(data.getNodeAndObject("trigger", keyHash: triggerHash)?.node)
        _ = policy.applyWrites([.add(trigger)])

        XCTAssertNil(data.getNodeAndObject("stale", keyHash: staleHash))
        XCTAssertNotNil(data.getNodeAndObject("main-0", keyHash: stableHash("main-0")))
    }

    /// 高频 window 候选应击败低频 main victim 并进入 probation。
    func testPolicyAdmitsHighFrequencyCandidateOverLowerFrequencyVictim() throws {
        let data = ConcurrentStringMap<Int>()
        let policy = PolicyState(maximum: 2, data: data)
        let victimHash = stableHash("victim")
        let candidateHash = stableHash("candidate")

        _ = data.putOrUpdate("victim", keyHash: victimHash, 1, generation: 0)
        let victim = try XCTUnwrap(data.getNodeAndObject("victim", keyHash: victimHash)?.node)
        _ = policy.applyWrites([.add(victim)])
        _ = data.putOrUpdate("candidate", keyHash: candidateHash, 2, generation: 0)
        let candidate = try XCTUnwrap(data.getNodeAndObject("candidate", keyHash: candidateHash)?.node)
        _ = policy.applyWrites([.add(candidate)])

        policy.applyReads(
            Array(repeating: ReadEvent<Int>.hit(keyHash: candidate.keyHash, node: candidate, generation: 0), count: 5)
        )

        let triggerHash = stableHash("trigger")
        _ = data.putOrUpdate("trigger", keyHash: triggerHash, 3, generation: 0)
        let trigger = try XCTUnwrap(data.getNodeAndObject("trigger", keyHash: triggerHash)?.node)
        _ = policy.applyWrites([.add(trigger)])

        XCTAssertNil(data.getNodeAndObject("victim", keyHash: victimHash))
        XCTAssertNotNil(data.getNodeAndObject("candidate", keyHash: candidateHash))
        assertSegment(candidate, is: .probation)
    }

    /// 低频 window 候选不应替换更热的 main victim。
    func testPolicyRejectsLowFrequencyCandidateAgainstHotVictim() throws {
        let data = ConcurrentStringMap<Int>()
        let policy = PolicyState(maximum: 2, data: data)
        let victimHash = stableHash("victim")
        let candidateHash = stableHash("candidate")

        _ = data.putOrUpdate("victim", keyHash: victimHash, 1, generation: 0)
        let victim = try XCTUnwrap(data.getNodeAndObject("victim", keyHash: victimHash)?.node)
        _ = policy.applyWrites([.add(victim)])
        _ = data.putOrUpdate("candidate", keyHash: candidateHash, 2, generation: 0)
        let candidate = try XCTUnwrap(data.getNodeAndObject("candidate", keyHash: candidateHash)?.node)
        _ = policy.applyWrites([.add(candidate)])

        policy.applyReads(
            Array(repeating: ReadEvent<Int>.hit(keyHash: victim.keyHash, node: victim, generation: 0), count: 5)
        )

        let triggerHash = stableHash("trigger")
        _ = data.putOrUpdate("trigger", keyHash: triggerHash, 3, generation: 0)
        let trigger = try XCTUnwrap(data.getNodeAndObject("trigger", keyHash: triggerHash)?.node)
        _ = policy.applyWrites([.add(trigger)])

        XCTAssertNotNil(data.getNodeAndObject("victim", keyHash: victimHash))
        XCTAssertNil(data.getNodeAndObject("candidate", keyHash: candidateHash))
    }

    /// 频率相同的候选应被拒绝，避免 one-hit scan 替换既有 main 数据。
    func testPolicyRejectsCandidateOnFrequencyTie() throws {
        let data = ConcurrentStringMap<Int>()
        let policy = PolicyState(maximum: 2, data: data)
        let existingHash = stableHash("existing")
        let tiedHash = stableHash("tied")

        _ = data.putOrUpdate("existing", keyHash: existingHash, 1, generation: 0)
        let existing = try XCTUnwrap(data.getNodeAndObject("existing", keyHash: existingHash)?.node)
        _ = policy.applyWrites([.add(existing)])
        _ = data.putOrUpdate("tied", keyHash: tiedHash, 2, generation: 0)
        let tiedCandidate = try XCTUnwrap(data.getNodeAndObject("tied", keyHash: tiedHash)?.node)
        _ = policy.applyWrites([.add(tiedCandidate)])

        let triggerHash = stableHash("trigger")
        _ = data.putOrUpdate("trigger", keyHash: triggerHash, 3, generation: 0)
        let trigger = try XCTUnwrap(data.getNodeAndObject("trigger", keyHash: triggerHash)?.node)
        _ = policy.applyWrites([.add(trigger)])

        XCTAssertNotNil(data.getNodeAndObject("existing", keyHash: existingHash))
        XCTAssertNil(data.getNodeAndObject("tied", keyHash: tiedHash))
        assertSegment(existing, is: .probation)
    }

    /// policy 中的陈旧节点已被其他路径移除时不应再次报告淘汰。
    /// 后续真实淘汰仍应正常上报。
    func testPolicyReportsOnlySuccessfulMapRemoval() throws {
        let data = ConcurrentStringMap<Int>()
        let policy = PolicyState(maximum: 1, data: data)
        let externallyRemovedHash = stableHash("externally-removed")

        _ = data.putOrUpdate("externally-removed", keyHash: externallyRemovedHash, 1, generation: 0)
        let externallyRemoved = try XCTUnwrap(
            data.getNodeAndObject("externally-removed", keyHash: externallyRemovedHash)?.node
        )
        XCTAssertTrue(policy.applyWrites([.add(externallyRemoved)]).isEmpty)
        XCTAssertTrue(data.removeIfSameNode(
            externallyRemoved.key,
            keyHash: externallyRemoved.keyHash,
            externallyRemoved
        ))

        let triggerHash = stableHash("trigger")
        _ = data.putOrUpdate("trigger", keyHash: triggerHash, 2, generation: 0)
        let trigger = try XCTUnwrap(data.getNodeAndObject("trigger", keyHash: triggerHash)?.node)
        XCTAssertTrue(policy.applyWrites([.add(trigger)]).isEmpty)

        let nextHash = stableHash("next")
        _ = data.putOrUpdate("next", keyHash: nextHash, 3, generation: 0)
        let next = try XCTUnwrap(data.getNodeAndObject("next", keyHash: nextHash)?.node)
        XCTAssertEqual(policy.applyWrites([.add(next)]), [2])
    }

    /// probation 命中应晋升 protected，protected 超额时应把最旧 protected 降回 probation。
    func testPolicyPromotesProbationHitAndDemotesProtectedOverflow() throws {
        let data = ConcurrentStringMap<Int>()
        let policy = PolicyState(maximum: 4, data: data)
        let firstHash = stableHash("first")
        let secondHash = stableHash("second")
        let thirdHash = stableHash("third")
        let fourthHash = stableHash("fourth")

        _ = data.putOrUpdate("first", keyHash: firstHash, 1, generation: 0)
        let first = try XCTUnwrap(data.getNodeAndObject("first", keyHash: firstHash)?.node)
        _ = policy.applyWrites([.add(first)])
        _ = data.putOrUpdate("second", keyHash: secondHash, 2, generation: 0)
        let second = try XCTUnwrap(data.getNodeAndObject("second", keyHash: secondHash)?.node)
        _ = policy.applyWrites([.add(second)])
        _ = data.putOrUpdate("third", keyHash: thirdHash, 3, generation: 0)
        let third = try XCTUnwrap(data.getNodeAndObject("third", keyHash: thirdHash)?.node)
        _ = policy.applyWrites([.add(third)])
        _ = data.putOrUpdate("fourth", keyHash: fourthHash, 4, generation: 0)
        let fourth = try XCTUnwrap(data.getNodeAndObject("fourth", keyHash: fourthHash)?.node)
        _ = policy.applyWrites([.add(fourth)])

        policy.applyReads([
            .hit(keyHash: first.keyHash, node: first, generation: 0),
            .hit(keyHash: second.keyHash, node: second, generation: 0),
            .hit(keyHash: third.keyHash, node: third, generation: 0),
        ])

        assertSegment(first, is: .probation)
        assertSegment(second, is: .protected)
        assertSegment(third, is: .protected)
        assertSegment(fourth, is: .window)
    }

}

// MARK: - Helpers

/// 同步关闭通用 W-TinyLFU cache，等待 maintenance barrier 完成。
private func shutdown<Object: Sendable>(_ cache: WTinyLFUCache<Object>) {
    let semaphore = DispatchSemaphore(value: 0)
    cache.shutdownGracefully { _ in
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)
}

private func requireSendable<T: Sendable>(_ value: T) {}

/// 同步关闭 MagentCache 包装层。
private func shutdownMagentCache<Value: Sendable>(_ cache: MagentCache<Value>) {
    let semaphore = DispatchSemaphore(value: 0)
    cache.shutdownGracefully { _ in
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)
}

/// 同步关闭 NIO EventLoopGroup。
private func shutdown(_ group: EventLoopGroup) {
    let semaphore = DispatchSemaphore(value: 0)
    group.shutdownGracefully { _ in
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)
}

/// 在有限时间内轮询异步维护任务是否完成。
private func eventually(
    timeout: TimeInterval = 2,
    interval: TimeInterval = 0.01,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        Thread.sleep(forTimeInterval: interval)
    }
    return condition()
}

private func canonicalIntValue(for key: String) -> Int {
    var hash = 0
    for scalar in key.unicodeScalars {
        hash = hash &* 31 &+ Int(scalar.value)
    }
    return hash
}

private func assertSegment<Object>(
    _ node: Node<Object>,
    is expected: Segment,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    switch (node.segment, expected) {
    case (.window, .window), (.probation, .probation), (.protected, .protected):
        return
    default:
        XCTFail("Expected segment \(expected), got \(node.segment)", file: file, line: line)
    }
}

private final class WTinyLFUCacheChannelHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let cache: WTinyLFUCache<String>

    init(cache: WTinyLFUCache<String>) {
        self.cache = cache
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var inbound = unwrapInboundIn(data)
        guard let key = inbound.readString(length: inbound.readableBytes) else {
            return
        }

        let value = cache.getOrLoad(key) { "loaded-\($0)" }
        var outbound = context.channel.allocator.buffer(capacity: value.utf8.count)
        outbound.writeString(value)
        context.writeAndFlush(wrapOutboundOut(outbound), promise: nil)
    }
}

private final class CacheARCProbe: @unchecked Sendable {
    private let onDeinit: () -> Void

    init(onDeinit: @escaping () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}

private final class LockedIntCounter: @unchecked Sendable {
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

private final class WTinyLFUCacheReference<Object: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storage: WTinyLFUCache<Object>?

    var cache: WTinyLFUCache<Object>? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
