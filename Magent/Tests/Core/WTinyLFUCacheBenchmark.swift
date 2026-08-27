//
//  WTinyLFUCacheBenchmark.swift
//  Magent
//
//  Created by MarlinL on 2026/6/23.
//

import Foundation
import Magent

/// 可手动运行的 W-TinyLFU benchmark。
///
/// 运行方式：
///
/// ```bash
/// swift run -c release WTinyLFUCacheBenchmark
/// swift run -c release WTinyLFUCacheBenchmark -- --scenario=1m
/// swift run -c release WTinyLFUCacheBenchmark -- --scenario=10m
/// swift run WTinyLFUCacheBenchmark -- --quick
/// ```
///
/// 默认场景：
/// - 1M keyspace, capacity 10K, 1M operations
/// - 10M keyspace, capacity 10K, 10M operations
@main
struct WTinyLFUCacheBenchmark {
    static func main() throws {
        let arguments = BenchArguments(CommandLine.arguments.dropFirst())
        let scenarios = arguments.scenarios

        print("")
        print("===== WTiny_LFU_Cache Benchmark =====")
        print("buildMode: \(isDebugBuild ? "debug" : "release")")
        print("scenarioCount: \(scenarios.count)")
        print("latencySamplesPerPhase: \(arguments.latencySamples)")
        print("======================================")

        for scenario in scenarios {
            try runScenario(scenario, latencySamples: arguments.latencySamples)
        }

        print("")
    }

    private static func runScenario(
        _ scenario: BenchScenario,
        latencySamples: Int
    ) throws {
        print("")
        print("----- scenario: \(scenario.name) -----")
        print("keyspace: \(formatCount(scenario.keyspace))")
        print("capacity: \(formatCount(scenario.capacity))")
        print("operationsPerPhase: \(formatCount(scenario.operations))")
        print("hotKeyCount: \(formatCount(scenario.hotKeyCount))")
        print("scanPercent: \(scenario.scanPercent)%")
        print("")

        try runPutPhase(scenario, latencySamples: latencySamples)
        try runGetHitPhase(scenario, latencySamples: latencySamples)
        try runGetHitPrebuiltKeyPhase(scenario, latencySamples: latencySamples)
        try runGetHitConcurrentPrebuiltKeyPhase(scenario, threadCount: 8)
        try runGetMissPhase(scenario, latencySamples: latencySamples)
        try runInvalidatePhase(scenario, latencySamples: latencySamples)
        try runMixedGetOrLoadPhase(scenario, latencySamples: latencySamples)
        try runScanHotRetentionPhase(scenario, latencySamples: latencySamples)
        try runSimpleLRUComparisonPhase(scenario, latencySamples: latencySamples)
        try runDefaultPolicyValidationPhase(scenario, latencySamples: latencySamples)
    }

    private static func runPutPhase(
        _ scenario: BenchScenario,
        latencySamples: Int
    ) throws {
        let cache = WTinyLFUCache<Int>(capacity: scenario.capacity)
        defer { shutdown(cache) }

        var generator = SeededGenerator(seed: scenario.seed ^ 0x1111)
        var latency = LatencyRecorder(totalOperations: scenario.operations, sampleLimit: latencySamples)
        let elapsed = measure {
            for index in 0..<scenario.operations {
                let key = "put-\(generator.uniformIndex(upperBound: scenario.keyspace))"
                latency.measureIfNeeded(index) {
                    cache.put(key, index)
                } otherwise: {
                    cache.put(key, index)
                }
            }
        }

        waitForMaintenance(cache, capacity: scenario.capacity)

        let report = PhaseReport(
            name: "put",
            operations: scenario.operations,
            elapsed: elapsed,
            latency: latency.summary(),
            extra: [
                ("writeQPS", formatRate(Double(scenario.operations) / elapsed.seconds)),
                ("estimatedSize", "\(cache.estimatedSize())")
            ]
        )
        report.print()

        guard cache.estimatedSize() <= scenario.capacity else {
            throw BenchError.capacityExceeded(cache.estimatedSize(), scenario.capacity)
        }
    }

    private static func runGetHitPhase(
        _ scenario: BenchScenario,
        latencySamples: Int
    ) throws {
        let cache = WTinyLFUCache<Int>(capacity: scenario.capacity)
        defer { shutdown(cache) }

        let preloaded = min(scenario.capacity, scenario.hotKeyCount)
        for index in 0..<preloaded {
            cache.put("hit-\(index)", index)
        }
        waitForMaintenance(cache, capacity: scenario.capacity)

        var generator = SeededGenerator(seed: scenario.seed ^ 0x2222)
        var hits = 0
        var latency = LatencyRecorder(totalOperations: scenario.operations, sampleLimit: latencySamples)
        let elapsed = measure {
            for index in 0..<scenario.operations {
                let key = "hit-\(generator.zipfLikeIndex(upperBound: preloaded))"
                let value: Int?
                if latency.shouldSample(index) {
                    let started = DispatchTime.now().uptimeNanoseconds
                    value = cache.get(key)
                    latency.record(startedAt: started)
                } else {
                    value = cache.get(key)
                }
                if value != nil {
                    hits += 1
                }
            }
        }

        let hitRate = Double(hits) / Double(max(1, scenario.operations))
        let report = PhaseReport(
            name: "get-hit",
            operations: scenario.operations,
            elapsed: elapsed,
            latency: latency.summary(),
            extra: [
                ("queryQPS", formatRate(Double(scenario.operations) / elapsed.seconds)),
                ("hitRate", formatPercent(hitRate)),
                ("estimatedSize", "\(cache.estimatedSize())")
            ]
        )
        report.print()

        guard hits > 0 else {
            throw BenchError.invalidHitRate(hitRate)
        }
    }

    private static func runGetHitPrebuiltKeyPhase(
        _ scenario: BenchScenario,
        latencySamples: Int
    ) throws {
        let cache = WTinyLFUCache<Int>(capacity: scenario.capacity)
        defer { shutdown(cache) }

        let preloaded = min(scenario.capacity, scenario.hotKeyCount)
        guard preloaded > 0 else {
            throw BenchError.invalidHitRate(0)
        }
        let keys = (0..<preloaded).map { "hit-\($0)" }
        for (index, key) in keys.enumerated() {
            cache.put(key, index)
        }
        waitForMaintenance(cache, capacity: scenario.capacity)

        var generator = SeededGenerator(seed: scenario.seed ^ 0x2A2A)
        var hits = 0
        var latency = LatencyRecorder(totalOperations: scenario.operations, sampleLimit: latencySamples)
        let elapsed = measure {
            for index in 0..<scenario.operations {
                let key = keys[generator.zipfLikeIndex(upperBound: preloaded)]
                let value: Int?
                if latency.shouldSample(index) {
                    let started = DispatchTime.now().uptimeNanoseconds
                    value = cache.get(key)
                    latency.record(startedAt: started)
                } else {
                    value = cache.get(key)
                }
                if value != nil {
                    hits += 1
                }
            }
        }

        let hitRate = Double(hits) / Double(max(1, scenario.operations))
        let report = PhaseReport(
            name: "get-hit-prebuilt-key",
            operations: scenario.operations,
            elapsed: elapsed,
            latency: latency.summary(),
            extra: [
                ("queryQPS", formatRate(Double(scenario.operations) / elapsed.seconds)),
                ("hitRate", formatPercent(hitRate)),
                ("estimatedSize", "\(cache.estimatedSize())")
            ]
        )
        report.print()

        guard hits > 0 else {
            throw BenchError.invalidHitRate(hitRate)
        }
    }

    private static func runGetHitConcurrentPrebuiltKeyPhase(
        _ scenario: BenchScenario,
        threadCount: Int
    ) throws {
        let cache = WTinyLFUCache<Int>(capacity: scenario.capacity)
        defer { shutdown(cache) }

        let preloaded = min(scenario.capacity, scenario.hotKeyCount)
        guard preloaded > 0 else {
            throw BenchError.invalidHitRate(0)
        }

        let keys = (0..<preloaded).map { "hit-\($0)" }
        for (index, key) in keys.enumerated() {
            cache.put(key, index)
        }
        waitForMaintenance(cache, capacity: scenario.capacity)

        let workers = max(1, threadCount)
        let baseOperations = scenario.operations / workers
        let remainder = scenario.operations % workers
        let startSignal = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let hitCounter = LockedCounter()

        for worker in 0..<workers {
            let workerOperations = baseOperations + (worker < remainder ? 1 : 0)
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                startSignal.wait()

                var generator = SeededGenerator(seed: scenario.seed ^ UInt64(0x5500 + worker))
                var localHits = 0
                for _ in 0..<workerOperations {
                    let key = keys[generator.zipfLikeIndex(upperBound: preloaded)]
                    if cache.get(key) != nil {
                        localHits += 1
                    }
                }

                hitCounter.add(localHits)
                group.leave()
            }
        }

        let elapsed = measure {
            for _ in 0..<workers {
                startSignal.signal()
            }
            group.wait()
        }

        let hits = hitCounter.value
        let hitRate = Double(hits) / Double(max(1, scenario.operations))
        let report = PhaseReport(
            name: "get-hit-concurrent-8-prebuilt-key",
            operations: scenario.operations,
            elapsed: elapsed,
            latency: LatencySummary(samples: []),
            extra: [
                ("queryQPS", formatRate(Double(scenario.operations) / elapsed.seconds)),
                ("hitRate", formatPercent(hitRate)),
                ("threads", "\(workers)"),
                ("estimatedSize", "\(cache.estimatedSize())")
            ]
        )
        report.print()

        guard hits > 0 else {
            throw BenchError.invalidHitRate(hitRate)
        }
    }

    private static func runGetMissPhase(
        _ scenario: BenchScenario,
        latencySamples: Int
    ) throws {
        let cache = WTinyLFUCache<Int>(capacity: scenario.capacity)
        defer { shutdown(cache) }

        var generator = SeededGenerator(seed: scenario.seed ^ 0x3333)
        var misses = 0
        var latency = LatencyRecorder(totalOperations: scenario.operations, sampleLimit: latencySamples)
        let elapsed = measure {
            for index in 0..<scenario.operations {
                let key = "miss-\(generator.uniformIndex(upperBound: scenario.keyspace))"
                let value: Int?
                if latency.shouldSample(index) {
                    let started = DispatchTime.now().uptimeNanoseconds
                    value = cache.get(key)
                    latency.record(startedAt: started)
                } else {
                    value = cache.get(key)
                }
                if value == nil {
                    misses += 1
                }
            }
        }

        let missRate = Double(misses) / Double(max(1, scenario.operations))
        let report = PhaseReport(
            name: "get-miss",
            operations: scenario.operations,
            elapsed: elapsed,
            latency: latency.summary(),
            extra: [
                ("queryQPS", formatRate(Double(scenario.operations) / elapsed.seconds)),
                ("missRate", formatPercent(missRate)),
                ("estimatedSize", "\(cache.estimatedSize())")
            ]
        )
        report.print()

        guard misses > 0 else {
            throw BenchError.invalidMissRate(missRate)
        }
    }

    private static func runInvalidatePhase(
        _ scenario: BenchScenario,
        latencySamples: Int
    ) throws {
        let cache = WTinyLFUCache<Int>(capacity: scenario.capacity)
        defer { shutdown(cache) }

        let preloaded = min(scenario.capacity, scenario.hotKeyCount)
        guard preloaded > 0 else {
            throw BenchError.invalidHitRate(0)
        }
        let keys = (0..<preloaded).map { "del-\($0)" }
        for (index, key) in keys.enumerated() {
            cache.put(key, index)
        }
        waitForMaintenance(cache, capacity: scenario.capacity)

        let sizeBefore = cache.estimatedSize()
        var generator = SeededGenerator(seed: scenario.seed ^ 0x6666)
        var latency = LatencyRecorder(totalOperations: scenario.operations, sampleLimit: latencySamples)
        let elapsed = measure {
            for index in 0..<scenario.operations {
                let key = keys[generator.zipfLikeIndex(upperBound: preloaded)]
                if latency.shouldSample(index) {
                    let started = DispatchTime.now().uptimeNanoseconds
                    cache.invalidate(key)
                    latency.record(startedAt: started)
                } else {
                    cache.invalidate(key)
                }
            }
        }
        waitForMaintenance(cache, capacity: scenario.capacity)

        let sizeAfter = cache.estimatedSize()
        let removedCount = max(0, sizeBefore - sizeAfter)
        let removeRatio = Double(removedCount) / Double(max(1, sizeBefore))
        let report = PhaseReport(
            name: "invalidate",
            operations: scenario.operations,
            elapsed: elapsed,
            latency: latency.summary(),
            extra: [
                ("deleteQPS", formatRate(Double(scenario.operations) / elapsed.seconds)),
                ("sizeBefore", formatCount(sizeBefore)),
                ("sizeAfter", formatCount(sizeAfter)),
                ("removedCount", formatCount(removedCount)),
                ("removeRatio", formatPercent(removeRatio))
            ]
        )
        report.print()

        guard sizeAfter <= scenario.capacity else {
            throw BenchError.capacityExceeded(sizeAfter, scenario.capacity)
        }
        guard sizeAfter < sizeBefore else {
            throw BenchError.invalidDeleteResult(sizeBefore, sizeAfter)
        }
    }

    private static func runMixedGetOrLoadPhase(
        _ scenario: BenchScenario,
        latencySamples: Int
    ) throws {
        let cache = WTinyLFUCache<Int>(capacity: scenario.capacity)
        defer { shutdown(cache) }

        let loaderCounter = LockedCounter()
        let loader: (String) -> Int = { key in
            loaderCounter.increment()
            return objectValue(for: key)
        }

        let warmKeyCount = min(scenario.hotKeyCount, scenario.capacity)
        for index in 0..<warmKeyCount {
            _ = cache.getOrLoad("hot-\(index)", loader)
        }
        waitForMaintenance(cache, capacity: scenario.capacity)

        var generator = SeededGenerator(seed: scenario.seed ^ 0x4444)
        let loaderCallsBefore = loaderCounter.value
        var latency = LatencyRecorder(totalOperations: scenario.operations, sampleLimit: latencySamples)
        let elapsed = measure {
            for index in 0..<scenario.operations {
                let key: String
                if generator.percent() < scenario.scanPercent {
                    key = "scan-\(generator.uniformIndex(upperBound: scenario.keyspace))-\(index)"
                } else {
                    key = "hot-\(generator.zipfLikeIndex(upperBound: warmKeyCount))"
                }

                if latency.shouldSample(index) {
                    let started = DispatchTime.now().uptimeNanoseconds
                    _ = cache.getOrLoad(key, loader)
                    latency.record(startedAt: started)
                } else {
                    _ = cache.getOrLoad(key, loader)
                }
            }
        }

        waitForMaintenance(cache, capacity: scenario.capacity)

        let loaderCalls = loaderCounter.value - loaderCallsBefore
        let observedHits = max(0, scenario.operations - loaderCalls)
        let hitRate = Double(observedHits) / Double(max(1, scenario.operations))

        let extra = [
            ("mixedQPS", formatRate(Double(scenario.operations) / elapsed.seconds)),
            ("observedHitRate", formatPercent(hitRate)),
            ("loaderCalls", formatCount(loaderCalls)),
            ("estimatedSize", "\(cache.estimatedSize())")
        ]

        let report = PhaseReport(
            name: "getOrLoad-mixed",
            operations: scenario.operations,
            elapsed: elapsed,
            latency: latency.summary(),
            extra: extra
        )
        report.print()

        guard cache.estimatedSize() <= scenario.capacity else {
            throw BenchError.capacityExceeded(cache.estimatedSize(), scenario.capacity)
        }
        guard hitRate > 0 else {
            throw BenchError.invalidHitRate(hitRate)
        }
    }

    private static func runScanHotRetentionPhase(
        _ scenario: BenchScenario,
        latencySamples: Int
    ) throws {
        let cache = WTinyLFUCache<Int>(capacity: scenario.capacity)
        defer { shutdown(cache) }

        let hotKeyCount = min(max(1, scenario.hotKeyCount), scenario.capacity)
        for index in 0..<hotKeyCount {
            cache.put("hot-\(index)", index)
        }
        waitForMaintenance(cache, capacity: scenario.capacity)

        var warmGenerator = SeededGenerator(seed: scenario.seed ^ 0x7777)
        for _ in 0..<max(hotKeyCount * 4, scenario.operations / 4) {
            _ = cache.get("hot-\(warmGenerator.zipfLikeIndex(upperBound: hotKeyCount))")
        }
        waitForMaintenance(cache, capacity: scenario.capacity)

        var generator = SeededGenerator(seed: scenario.seed ^ 0x8888)
        var hotHits = 0
        var scanWrites = 0
        var latency = LatencyRecorder(totalOperations: scenario.operations, sampleLimit: latencySamples)
        let elapsed = measure {
            for index in 0..<scenario.operations {
                let hotKey = "hot-\(generator.zipfLikeIndex(upperBound: hotKeyCount))"
                let hotValue: Int?
                if latency.shouldSample(index) {
                    let started = DispatchTime.now().uptimeNanoseconds
                    hotValue = cache.get(hotKey)
                    latency.record(startedAt: started)
                } else {
                    hotValue = cache.get(hotKey)
                }
                if hotValue != nil {
                    hotHits += 1
                }

                if generator.percent() < scenario.scanPercent {
                    scanWrites += 1
                    cache.put("scan-\(index)-\(generator.uniformIndex(upperBound: scenario.keyspace))", index)
                }
            }
        }

        waitForMaintenance(cache, capacity: scenario.capacity)

        var hotSurvivors = 0
        for index in 0..<hotKeyCount where cache.get("hot-\(index)") != nil {
            hotSurvivors += 1
        }

        let hotHitRate = Double(hotHits) / Double(max(1, scenario.operations))
        let hotSurvivalRate = Double(hotSurvivors) / Double(max(1, hotKeyCount))
        let report = PhaseReport(
            name: "scan-hot-retention",
            operations: scenario.operations,
            elapsed: elapsed,
            latency: latency.summary(),
            extra: [
                ("scanWrites", formatCount(scanWrites)),
                ("scanWritePercent", formatPercent(Double(scanWrites) / Double(max(1, scenario.operations)))),
                ("hotHitRate", formatPercent(hotHitRate)),
                ("hotSurvivalRate", formatPercent(hotSurvivalRate)),
                ("estimatedSize", "\(cache.estimatedSize())")
            ]
        )
        report.print()

        guard cache.estimatedSize() <= scenario.capacity else {
            throw BenchError.capacityExceeded(cache.estimatedSize(), scenario.capacity)
        }
        guard hotSurvivors > 0 else {
            throw BenchError.invalidHitRate(hotSurvivalRate)
        }
    }

    private static func runSimpleLRUComparisonPhase(
        _ scenario: BenchScenario,
        latencySamples: Int
    ) throws {
        let wtiny = runWTinyComparisonWorkload(
            scenario,
            latencySamples: latencySamples,
            seed: scenario.seed ^ 0x9999
        )
        let lru = runSimpleLRUComparisonWorkload(
            scenario,
            seed: scenario.seed ^ 0x9999
        )

        let report = PhaseReport(
            name: "simple-lru-comparison",
            operations: scenario.operations,
            elapsed: wtiny.elapsed,
            latency: wtiny.latency,
            extra: [
                ("wtinyQPS", formatRate(Double(scenario.operations) / wtiny.elapsed.seconds)),
                ("wtinyHitRate", formatPercent(wtiny.hitRate)),
                ("wtinyEstimatedSize", formatCount(wtiny.size)),
                ("simpleLRUQPS", formatRate(Double(scenario.operations) / lru.elapsed.seconds)),
                ("simpleLRUHitRate", formatPercent(lru.hitRate)),
                ("simpleLRUEstimatedSize", formatCount(lru.size))
            ]
        )
        report.print()

        guard wtiny.size <= scenario.capacity else {
            throw BenchError.capacityExceeded(wtiny.size, scenario.capacity)
        }
        guard lru.size <= scenario.capacity else {
            throw BenchError.capacityExceeded(lru.size, scenario.capacity)
        }
    }

    private static func runDefaultPolicyValidationPhase(
        _ scenario: BenchScenario,
        latencySamples: Int
    ) throws {
        let cache = WTinyLFUCache<Int>(capacity: scenario.capacity)
        defer { shutdown(cache) }

        var generator = SeededGenerator(seed: scenario.seed ^ 0xAAAA)
        var peakSize = 0
        var hits = 0
        var latency = LatencyRecorder(totalOperations: scenario.operations, sampleLimit: latencySamples)
        let elapsed = measure {
            for index in 0..<scenario.operations {
                let key = workloadKey(index: index, generator: &generator, scenario: scenario)
                let value: Int?
                if latency.shouldSample(index) {
                    let started = DispatchTime.now().uptimeNanoseconds
                    value = cache.get(key)
                    if value == nil {
                        cache.put(key, objectValue(for: key))
                    }
                    latency.record(startedAt: started)
                } else {
                    value = cache.get(key)
                    if value == nil {
                        cache.put(key, objectValue(for: key))
                    }
                }
                if value != nil {
                    hits += 1
                }
                peakSize = max(peakSize, cache.estimatedSize())
            }
        }

        waitForMaintenance(cache, capacity: scenario.capacity)

        let hitRate = Double(hits) / Double(max(1, scenario.operations))
        let report = PhaseReport(
            name: "default-policy-validation",
            operations: scenario.operations,
            elapsed: elapsed,
            latency: latency.summary(),
            extra: [
                ("defaultCapacity", formatCount(scenario.capacity)),
                ("peakEstimatedSize", formatCount(peakSize)),
                ("finalEstimatedSize", formatCount(cache.estimatedSize())),
                ("hitRate", formatPercent(hitRate))
            ]
        )
        report.print()

        guard peakSize <= scenario.capacity * 2 else {
            throw BenchError.capacityExceeded(peakSize, scenario.capacity * 2)
        }
        guard cache.estimatedSize() <= scenario.capacity else {
            throw BenchError.capacityExceeded(cache.estimatedSize(), scenario.capacity)
        }
    }

    private static func runWTinyComparisonWorkload(
        _ scenario: BenchScenario,
        latencySamples: Int,
        seed: UInt64
    ) -> ComparisonResult {
        let cache = WTinyLFUCache<Int>(capacity: scenario.capacity)
        defer { shutdown(cache) }
        var generator = SeededGenerator(seed: seed)
        var hits = 0
        var latency = LatencyRecorder(totalOperations: scenario.operations, sampleLimit: latencySamples)

        let elapsed = measure {
            for index in 0..<scenario.operations {
                let key = workloadKey(index: index, generator: &generator, scenario: scenario)
                let value: Int?
                if latency.shouldSample(index) {
                    let started = DispatchTime.now().uptimeNanoseconds
                    value = cache.get(key)
                    if value == nil {
                        cache.put(key, objectValue(for: key))
                    }
                    latency.record(startedAt: started)
                } else {
                    value = cache.get(key)
                    if value == nil {
                        cache.put(key, objectValue(for: key))
                    }
                }
                if value != nil {
                    hits += 1
                }
            }
        }

        waitForMaintenance(cache, capacity: scenario.capacity)
        return ComparisonResult(
            elapsed: elapsed,
            hitRate: Double(hits) / Double(max(1, scenario.operations)),
            size: cache.estimatedSize(),
            latency: latency.summary()
        )
    }

    private static func runSimpleLRUComparisonWorkload(
        _ scenario: BenchScenario,
        seed: UInt64
    ) -> ComparisonResult {
        let cache = SimpleLRUCache<Int>(capacity: scenario.capacity)
        var generator = SeededGenerator(seed: seed)
        var hits = 0

        let elapsed = measure {
            for index in 0..<scenario.operations {
                let key = workloadKey(index: index, generator: &generator, scenario: scenario)
                if cache.get(key) != nil {
                    hits += 1
                } else {
                    cache.put(key, objectValue(for: key))
                }
            }
        }

        return ComparisonResult(
            elapsed: elapsed,
            hitRate: Double(hits) / Double(max(1, scenario.operations)),
            size: cache.estimatedSize(),
            latency: LatencySummary(samples: [])
        )
    }

    private static func workloadKey(
        index: Int,
        generator: inout SeededGenerator,
        scenario: BenchScenario
    ) -> String {
        if generator.percent() < scenario.scanPercent {
            return "scan-\(index)-\(generator.uniformIndex(upperBound: scenario.keyspace))"
        }
        return "hot-\(generator.zipfLikeIndex(upperBound: max(1, scenario.hotKeyCount)))"
    }

    private static func objectValue(for key: String) -> Int {
        var hash = 0
        for scalar in key.unicodeScalars {
            hash = hash &* 31 &+ Int(scalar.value)
        }
        return hash
    }
}

private struct BenchArguments {
    let scenarios: [BenchScenario]
    let latencySamples: Int

    init(_ rawArguments: ArraySlice<String>) {
        let arguments = Array(rawArguments)
        let isQuick = arguments.contains("--quick")
        let scenarioName = Self.value(for: "--scenario", in: arguments)
        let latencySamples = Self.intValue(for: "--latency-samples", in: arguments) ?? 10_000
        self.latencySamples = max(1, latencySamples)

        if let custom = Self.customScenario(from: arguments) {
            self.scenarios = [custom]
        } else if isQuick {
            self.scenarios = [.quick]
        } else {
            switch scenarioName {
            case "1m":
                self.scenarios = [.oneMillion]
            case "10m":
                self.scenarios = [.tenMillion]
            case "all", nil:
                self.scenarios = [.oneMillion, .tenMillion]
            default:
                self.scenarios = [.oneMillion, .tenMillion]
            }
        }
    }

    private static func customScenario(from arguments: [String]) -> BenchScenario? {
        guard let keyspace = intValue(for: "--keyspace", in: arguments) else {
            return nil
        }

        let capacity = intValue(for: "--capacity", in: arguments) ?? 10_000
        let operations = intValue(for: "--operations", in: arguments) ?? keyspace
        let hotKeyCount = intValue(for: "--hot-keys", in: arguments) ?? capacity
        let scanPercent = intValue(for: "--scan-percent", in: arguments) ?? 20

        return BenchScenario(
            name: "custom",
            keyspace: keyspace,
            capacity: capacity,
            operations: operations,
            hotKeyCount: hotKeyCount,
            scanPercent: scanPercent,
            seed: 0xC0FF_EE
        )
    }

    private static func value(for name: String, in arguments: [String]) -> String? {
        let prefix = "\(name)="
        for argument in arguments where argument.hasPrefix(prefix) {
            return String(argument.dropFirst(prefix.count)).lowercased()
        }
        return nil
    }

    private static func intValue(for name: String, in arguments: [String]) -> Int? {
        guard let value = value(for: name, in: arguments) else {
            return nil
        }
        return Int(value.replacingOccurrences(of: "_", with: ""))
    }
}

private struct BenchScenario {
    let name: String
    let keyspace: Int
    let capacity: Int
    let operations: Int
    let hotKeyCount: Int
    let scanPercent: Int
    let seed: UInt64

    static let oneMillion = BenchScenario(
        name: "1m-keyspace-capacity-10k",
        keyspace: 1_000_000,
        capacity: 10_000,
        operations: 1_000_000,
        hotKeyCount: 10_000,
        scanPercent: 20,
        seed: 0xCAFE_BABE
    )

    static let tenMillion = BenchScenario(
        name: "10m-keyspace-capacity-10k",
        keyspace: 10_000_000,
        capacity: 10_000,
        operations: 10_000_000,
        hotKeyCount: 10_000,
        scanPercent: 20,
        seed: 0xDEAD_BEEF
    )

    static let quick = BenchScenario(
        name: "quick-smoke",
        keyspace: 100_000,
        capacity: 1_000,
        operations: 50_000,
        hotKeyCount: 1_000,
        scanPercent: 20,
        seed: 0x1234_5678
    )
}

private struct PhaseReport {
    let name: String
    let operations: Int
    let elapsed: DurationReport
    let latency: LatencySummary
    let extra: [(String, String)]

    func print() {
        Swift.print("phase: \(name)")
        Swift.print("  operations: \(formatCount(operations))")
        Swift.print("  elapsedSeconds: \(formatDouble(elapsed.seconds, digits: 4))")
        Swift.print("  avgNsPerOp: \(formatDouble(elapsed.nanosecondsPerOperation(count: operations), digits: 1))")
        Swift.print("  sampledLatencyNs.p50: \(latency.p50)")
        Swift.print("  sampledLatencyNs.p95: \(latency.p95)")
        Swift.print("  sampledLatencyNs.p99: \(latency.p99)")
        for (key, value) in extra {
            Swift.print("  \(key): \(value)")
        }
        Swift.print("")
    }
}

private struct DurationReport {
    let nanoseconds: UInt64

    var seconds: Double {
        Double(nanoseconds) / 1_000_000_000
    }

    func nanosecondsPerOperation(count: Int) -> Double {
        Double(nanoseconds) / Double(max(1, count))
    }
}

private struct LatencyRecorder {
    private let sampleInterval: Int
    private var samples: [UInt64] = []

    init(totalOperations: Int, sampleLimit: Int) {
        self.sampleInterval = max(1, totalOperations / max(1, sampleLimit))
        self.samples.reserveCapacity(min(totalOperations, sampleLimit + 1))
    }

    func shouldSample(_ index: Int) -> Bool {
        index % sampleInterval == 0
    }

    mutating func measureIfNeeded(
        _ index: Int,
        _ sampledBody: () -> Void,
        otherwise: () -> Void
    ) {
        if shouldSample(index) {
            let started = DispatchTime.now().uptimeNanoseconds
            sampledBody()
            record(startedAt: started)
        } else {
            otherwise()
        }
    }

    mutating func record(startedAt: UInt64) {
        samples.append(DispatchTime.now().uptimeNanoseconds - startedAt)
    }

    func summary() -> LatencySummary {
        LatencySummary(samples: samples)
    }
}

private struct LatencySummary {
    let p50: UInt64
    let p95: UInt64
    let p99: UInt64

    init(samples: [UInt64]) {
        guard samples.isEmpty == false else {
            self.p50 = 0
            self.p95 = 0
            self.p99 = 0
            return
        }

        let sorted = samples.sorted()
        self.p50 = Self.percentile(sorted, percentile: 0.50)
        self.p95 = Self.percentile(sorted, percentile: 0.95)
        self.p99 = Self.percentile(sorted, percentile: 0.99)
    }

    private static func percentile(_ sorted: [UInt64], percentile: Double) -> UInt64 {
        let index = min(
            sorted.count - 1,
            max(0, Int((Double(sorted.count - 1) * percentile).rounded()))
        )
        return sorted[index]
    }
}

private enum BenchError: Error, CustomStringConvertible {
    case capacityExceeded(Int, Int)
    case invalidHitRate(Double)
    case invalidMissRate(Double)
    case invalidDeleteResult(Int, Int)

    var description: String {
        switch self {
        case .capacityExceeded(let actual, let capacity):
            return "capacity exceeded: actual=\(actual), capacity=\(capacity)"
        case .invalidHitRate(let hitRate):
            return "invalid hit rate: \(hitRate)"
        case .invalidMissRate(let missRate):
            return "invalid miss rate: \(missRate)"
        case .invalidDeleteResult(let sizeBefore, let sizeAfter):
            return "delete had no effect: sizeBefore=\(sizeBefore), sizeAfter=\(sizeAfter)"
        }
    }
}

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }

    mutating func uniformIndex(upperBound: Int) -> Int {
        Int(next() % UInt64(max(1, upperBound)))
    }

    mutating func percent() -> Int {
        Int(next() % 100)
    }

    /// 生成偏向小编号热点 key 的可复现分布，用于近似 Zipf 热点访问。
    mutating func zipfLikeIndex(upperBound: Int) -> Int {
        let bound = max(1, upperBound)
        let first = Int(next() % UInt64(bound))
        let second = Int(next() % UInt64(bound))
        let third = Int(next() % UInt64(bound))
        return min(first, second, third)
    }
}

private struct ComparisonResult {
    let elapsed: DurationReport
    let hitRate: Double
    let size: Int
    let latency: LatencySummary
}

private final class SimpleLRUCache<Value> {
    private final class Entry {
        let key: String
        var value: Value
        weak var previous: Entry?
        var next: Entry?

        init(key: String, value: Value) {
            self.key = key
            self.value = value
        }
    }

    private let capacity: Int
    private var entries: [String: Entry] = [:]
    private var head: Entry?
    private var tail: Entry?

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    func get(_ key: String) -> Value? {
        guard let entry = entries[key] else {
            return nil
        }
        moveToHead(entry)
        return entry.value
    }

    func put(_ key: String, _ value: Value) {
        guard capacity > 0 else {
            return
        }

        if let entry = entries[key] {
            entry.value = value
            moveToHead(entry)
            return
        }

        let entry = Entry(key: key, value: value)
        entries[key] = entry
        appendToHead(entry)

        while entries.count > capacity, let tail {
            remove(tail)
            entries.removeValue(forKey: tail.key)
        }
    }

    func estimatedSize() -> Int {
        entries.count
    }

    private func appendToHead(_ entry: Entry) {
        entry.previous = nil
        entry.next = head
        head?.previous = entry
        head = entry
        if tail == nil {
            tail = entry
        }
    }

    private func moveToHead(_ entry: Entry) {
        guard entry !== head else {
            return
        }
        remove(entry)
        appendToHead(entry)
    }

    private func remove(_ entry: Entry) {
        if entry === head {
            head = entry.next
        }
        if entry === tail {
            tail = entry.previous
        }
        entry.previous?.next = entry.next
        entry.next?.previous = entry.previous
        entry.previous = nil
        entry.next = nil
    }
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

    func add(_ value: Int) {
        lock.lock()
        storage += value
        lock.unlock()
    }
}

private func measure(_ body: () -> Void) -> DurationReport {
    let startedAt = DispatchTime.now().uptimeNanoseconds
    body()
    return DurationReport(nanoseconds: DispatchTime.now().uptimeNanoseconds - startedAt)
}

private func shutdown<Object: Sendable>(_ cache: WTinyLFUCache<Object>) {
    let semaphore = DispatchSemaphore(value: 0)
    cache.shutdownGracefully { _ in
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 5)
}

private func waitForMaintenance<Object: Sendable>(
    _ cache: WTinyLFUCache<Object>,
    capacity: Int,
    timeout: TimeInterval = 5
) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cache.estimatedSize() <= capacity {
            return
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

private func formatCount(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

private func formatRate(_ value: Double) -> String {
    "\(formatDouble(value, digits: 2))/s"
}

private func formatPercent(_ value: Double) -> String {
    "\(formatDouble(value * 100, digits: 2))%"
}

private func formatDouble(_ value: Double, digits: Int) -> String {
    String(format: "%.\(digits)f", value)
}

private var isDebugBuild: Bool {
    #if DEBUG
    return true
    #else
    return false
    #endif
}
