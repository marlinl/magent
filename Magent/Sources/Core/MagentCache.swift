//
//  MagentCache.swift
//  Magent
//
//  Created by MarlinL on 2026/6/23.
//

import Foundation
import Dispatch
import os
import Atomics

// MARK: - Magent Cache

/// Cache entry expiration policy.
package enum MagentCacheExpiration: Sendable {
    case never
    case afterWrite(Duration)
    case afterRead(Duration)
}

/// Magent 模块内部使用的 W-TinyLFU loading cache。
///
/// Value 类型在创建 cache 类型时确定，例如 `MagentCache<Decision>`。
/// 业务代码只使用这个入口，具体 W-TinyLFU 实现由父类提供。
internal final class MagentCache<Value: Sendable>: WTinyLFUCache<Value>, @unchecked Sendable {
    /// 创建指定容量的 cache；`capacity == 0` 表示禁用存储但保留 loader bypass。
    internal override init(
        capacity: Int,
        expiration: MagentCacheExpiration = .never,
        onEvict: (@Sendable (Value) -> Void)? = nil
    ) {
        super.init(capacity: capacity, expiration: expiration, onEvict: onEvict)
    }
}

/// W-TinyLFU loading cache。
///
/// Key 固定为 `String`，Value 为调用方自定义 `Object`。cache 内部使用
/// 每个实例的串行 DispatchQueue 执行 policy maintenance，所有实例共享系统
/// Dispatch executor，不为单个 cache 创建专用线程。
package class WTinyLFUCache<Object: Sendable>: @unchecked Sendable {
    private let maximum: Int
    private let expiration: MagentCacheExpiration
    private let ttl: Int64?
    /// 过期线程通过一次 CAS 把时间戳改成该标记，避免并发续期后仍删除同一个节点。
    private let expiredTimestampMilliseconds: Int64 = -1
    private let expirationScanIntervalSeconds: Int64 = 10
    private let expirationScanPercentage: Int = 5
    private var expirationTimer: DispatchSourceTimer? = nil
    private let onEvict: (@Sendable (Object) -> Void)?
    private let data: ConcurrentStringMap<Object>
    private let policy: PolicyState<Object>
    private let readBuffer = ReadBuffer<Object>()
    private let writeBuffer: WriteBuffer<Object>
    private let maintenanceQueue: DispatchQueue
    private let maintenanceQueueKey = DispatchSpecificKey<UInt8>()
    private let writeLock = UnfairLock()
    private let maintenanceLock = UnfairLock()
    private let schedulingLock = UnfairLock()
    private let generation = CacheGeneration()
    private let isShutdown = ManagedAtomic(false)
    private let drainScheduled = ManagedAtomic(false)
    private let maintenanceBatchLimit = 1024

    /// 创建 cache。
    ///
    /// - Parameters:
    ///   - capacity: 最大 item 数；`0` 表示禁用存储但仍允许 loader bypass。
    ///   - expiration: entry 过期策略，默认为永不过期。
    package init(
        capacity: Int,
        expiration: MagentCacheExpiration = .never,
        onEvict: (@Sendable (Object) -> Void)? = nil
    ) {
        precondition(capacity >= 0, "WTinyLFUCache capacity must be >= 0")

        self.maximum = capacity
        self.expiration = expiration
        self.onEvict = onEvict
        switch expiration {
        case .never:
            self.ttl = nil
        case .afterWrite(let duration), .afterRead(let duration):
            let ttl = Int64(duration / .milliseconds(1))
            precondition(ttl > 0, "WTinyLFUCache expiration must be at least one millisecond")
            self.ttl = ttl
        }
        self.data = ConcurrentStringMap()
        self.policy = PolicyState(maximum: capacity, data: data, generation: generation)
        self.writeBuffer = WriteBuffer(capacity: max(64, min(4_096, max(1, capacity) * 2)))
        self.maintenanceQueue = DispatchQueue(
            label: "com.marlinl.magent.wtinylfu-maintenance",
            qos: .utility,
            target: .global(qos: .utility)
        )
        self.maintenanceQueue.setSpecific(key: maintenanceQueueKey, value: 1)

        if ttl != nil {
            let timer = DispatchSource.makeTimerSource(queue: maintenanceQueue)
            timer.schedule(
                deadline: .now() + .seconds(Int(expirationScanIntervalSeconds)),
                repeating: .seconds(Int(expirationScanIntervalSeconds))
            )
            timer.setEventHandler { [weak self] in
                self?.scanExpiredEntries()
            }
            timer.resume()
            self.expirationTimer = timer
        }
    }

    /// 同步读取缓存。
    package func get(_ key: String) -> Object? {
        lookup(key, keyHash: stableHash(key), recordAccess: true)
    }

    /// 判断 key 对应的未过期 entry 是否存在；过期 entry 会在返回前删除。
    package func contains(_ key: String) -> Bool {
        guard maximum > 0,
              let hit = data.getNodeAndObject(key, keyHash: stableHash(key)) else {
            return false
        }
        return validateExpiration(of: hit.node)
    }

    /// 校验节点是否仍在 TTL 内。
    private func validateExpiration(of node: Node<Object>) -> Bool {
        let timestamp: ManagedAtomic<Int64>
        switch expiration {
        case .never:
            return true
        case .afterWrite:
            timestamp = node.writtenAtMilliseconds
        case .afterRead:
            timestamp = node.readAtMilliseconds
        }

        guard let ttl else {
            return false
        }
        let nowMilliseconds = currentMilliseconds()
        let timestampMilliseconds = timestamp.load(ordering: .acquiring)
        guard timestampMilliseconds >= 0 else {
            return false
        }
        guard nowMilliseconds - timestampMilliseconds < ttl else {
            invalidateExpiredNode(node, expectedTimestampMilliseconds: timestampMilliseconds)
            return false
        }

        return true
    }

    private func lookup(_ key: String, keyHash: Int, recordAccess: Bool) -> Object? {
        guard maximum > 0 else {
            return nil
        }

        guard let hit = data.getNodeAndObject(key, keyHash: keyHash) else {
            if recordAccess, isCacheRunning {
                readBuffer.offer(.miss(keyHash: keyHash, generation: currentGeneration()))
                scheduleDrain()
            }
            return nil
        }

        guard validateExpiration(of: hit.node) else {
            return nil
        }

        if isCacheRunning, case .afterRead = expiration {
            let readAtMilliseconds = hit.node.readAtMilliseconds.load(ordering: .acquiring)
            if readAtMilliseconds >= 0 {
                let nowMilliseconds = currentMilliseconds()
                // 续期只尝试一次。失败表示其他路径已修改时间戳，当前读取无需重试。
                _ = hit.node.readAtMilliseconds.compareExchange(
                    expected: readAtMilliseconds,
                    desired: nowMilliseconds,
                    ordering: .acquiringAndReleasing
                )
            }
        }

        if recordAccess, isCacheRunning {
            readBuffer.offer(.hit(keyHash: hit.node.keyHash, node: hit.node, generation: hit.node.generation))
            scheduleDrain()
        }
        return hit.object
    }

    /// 读取缓存；miss 时同步调用传入 loader，成功返回后写入缓存。
    package func getOrLoad(_ key: String, _ loader: (String) -> Object) -> Object {
        let keyHash = stableHash(key)

        guard isCacheRunning else {
            return loader(key)
        }

        if let object = lookup(key, keyHash: keyHash, recordAccess: true) {
            return object
        }

        let object = loader(key)

        if maximum == 0 {
            return object
        }

        if isCacheRunning {
            if let existing = lookup(key, keyHash: keyHash, recordAccess: false) {
                return existing
            }
            put(key, keyHash: keyHash, object)
        }
        return object
    }

    /// 写入或更新缓存对象。
    package func put(_ key: String, _ object: Object) {
        put(key, keyHash: stableHash(key), object)
    }

    private func put(_ key: String, keyHash: Int, _ object: Object) {
        guard maximum > 0, isCacheRunning else { return }

        let inserted: Bool
        var evictedObjects: [Object] = []
        writeLock.lock()
        guard isCacheRunning else {
            writeLock.unlock()
            return
        }
        let writeGeneration = currentGeneration()
        switch data.putOrUpdate(key, keyHash: keyHash, object, generation: writeGeneration) {
        case .inserted(let node, let replaced):
            if let replaced {
                evictedObjects.append(replaced.object)
                offerWrite(.remove(replaced), evictedObjects: &evictedObjects)
            }
            offerWrite(.add(node), evictedObjects: &evictedObjects)
            inserted = true

        case .updated(let node):
            if case .afterWrite = expiration {
                node.writtenAtMilliseconds.store(currentMilliseconds(), ordering: .releasing)
            }
            readBuffer.offer(.hit(keyHash: node.keyHash, node: node, generation: node.generation))
            inserted = false
        }

        if inserted {
            enforceMaximumIfNeeded(evictedObjects: &evictedObjects)
        }
        writeLock.unlock()

        notifyEvictions(evictedObjects)
        scheduleDrain()
    }

    /// 删除一个 key。
    package func invalidate(_ key: String) {
        guard maximum > 0, isCacheRunning else { return }

        let keyHash = stableHash(key)
        writeLock.lock()
        guard isCacheRunning else {
            writeLock.unlock()
            return
        }
        if let node = data.remove(key, keyHash: keyHash) {
            var evictedObjects = [node.object]
            offerWrite(.remove(node), evictedObjects: &evictedObjects)
            writeLock.unlock()
            notifyEvictions(evictedObjects)
            scheduleDrain()
        } else {
            writeLock.unlock()
        }

    }

    /// 清空缓存。
    package func removeAll() {
        guard maximum > 0, isCacheRunning else { return }

        writeLock.lock()
        guard isCacheRunning else {
            writeLock.unlock()
            return
        }
        let nextGeneration = advanceGeneration()
        var evictedObjects = data.removeAll().map(\.object)
        readBuffer.removeAll()
        writeBuffer.removeAll()
        offerWrite(.clear(generation: nextGeneration), evictedObjects: &evictedObjects)
        writeLock.unlock()

        notifyEvictions(evictedObjects)
        scheduleDrain()
    }

    /// 当前缓存 item 数量估算。
    package func estimatedSize() -> Int {
        maximum == 0 ? 0 : data.estimatedSize()
    }

    /// 停止 mutation，并在已排队的 maintenance 完成且事件缓冲清空后回调。
    package func shutdownGracefully(_ callback: @escaping @Sendable (Error?) -> Void) {
        schedulingLock.lock()
        isShutdown.store(true, ordering: .releasing)
        expirationTimer?.setEventHandler {}
        expirationTimer?.cancel()

        // 等待已经通过 lifecycle 检查的 mutation 离开 write 临界区，再把完成回调
        // 排到当前实例的串行 maintenance queue 尾部。
        writeLock.lock()
        writeLock.unlock()

        maintenanceQueue.async { [weak self] in
            self?.readBuffer.removeAll()
            self?.writeBuffer.removeAll()
            callback(nil)
        }
        schedulingLock.unlock()
    }

    private var isCacheRunning: Bool {
        isShutdown.load(ordering: .relaxed) == false
    }

    private func currentMilliseconds() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private func scanExpiredEntries() {
        guard isCacheRunning, ttl != nil else { return }

        let entryCount = data.estimatedSize()
        guard entryCount > 0 else { return }

        let scanCount = min(entryCount, max(1, (entryCount * expirationScanPercentage + 99) / 100))

        for node in data.sampleNodes(count: scanCount) {
            _ = contains(node.key)
        }
    }

    /// 时间戳仍等于读取时观察值时才认领并删除节点；竞争失败时留到后续周期处理。
    private func invalidateExpiredNode(_ node: Node<Object>, expectedTimestampMilliseconds: Int64) {
        guard isCacheRunning else { return }

        let timestamp: ManagedAtomic<Int64>
        switch expiration {
        case .never:
            return
        case .afterWrite:
            timestamp = node.writtenAtMilliseconds
        case .afterRead:
            timestamp = node.readAtMilliseconds
        }

        writeLock.lock()
        guard isCacheRunning else {
            writeLock.unlock()
            return
        }
        guard timestamp.compareExchange(
            expected: expectedTimestampMilliseconds,
            desired: expiredTimestampMilliseconds,
            ordering: .acquiringAndReleasing
        ).exchanged else {
            writeLock.unlock()
            return
        }
        guard data.removeIfSameNode(node.key, keyHash: node.keyHash, node) else {
            writeLock.unlock()
            return
        }
        var evictedObjects = [node.object]
        offerWrite(.remove(node), evictedObjects: &evictedObjects)
        writeLock.unlock()
        notifyEvictions(evictedObjects)
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard isCacheRunning else { return }
        guard drainScheduled.load(ordering: .relaxed) == false else { return }
        guard drainScheduled.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged else {
            return
        }

        schedulingLock.lock()
        guard isCacheRunning else {
            drainScheduled.store(false, ordering: .releasing)
            schedulingLock.unlock()
            return
        }

        maintenanceQueue.async { [weak self] in
            guard let self else { return }

            self.notifyEvictions(self.drainBuffers())
            self.drainScheduled.store(false, ordering: .releasing)
            if self.readBuffer.hasPending || self.writeBuffer.hasPending {
                self.scheduleDrain()
            }
        }
        schedulingLock.unlock()
    }

    private func drainBuffers() -> [Object] {
        var evictedObjects: [Object] = []
        maintenanceLock.lock()
        drainBuffersLocked(evictedObjects: &evictedObjects)
        maintenanceLock.unlock()
        return evictedObjects
    }

    private func drainBuffersLocked(evictedObjects: inout [Object]) {
        let writeEvents = writeBuffer.pollBatch(limit: maintenanceBatchLimit)
        if writeEvents.isEmpty == false {
            evictedObjects.append(contentsOf: policy.applyWrites(writeEvents))
        }

        let readEvents = readBuffer.pollBatch(limit: maintenanceBatchLimit)
        if readEvents.isEmpty == false {
            policy.applyReads(readEvents)
        }
    }

    private var maximumAllowedTransientSize: Int {
        maximum + max(1, min(maintenanceBatchLimit, maximum))
    }

    private func enforceMaximumIfNeeded(evictedObjects: inout [Object]) {
        guard isCacheRunning, maximum > 0 else { return }
        guard data.estimatedSize() >= maximumAllowedTransientSize else { return }
        drainUntilSizeWithinMaximum(evictedObjects: &evictedObjects)
    }

    private func drainUntilSizeWithinMaximum(evictedObjects: inout [Object]) {
        maintenanceLock.lock()
        defer { maintenanceLock.unlock() }
        while data.estimatedSize() > maximum, writeBuffer.hasPending {
            drainBuffersLocked(evictedObjects: &evictedObjects)
        }
    }

    /// 有界 write buffer 满时由当前生产者同步推进一个 maintenance batch，避免事件和
    /// 被事件强引用的旧对象无界积压。
    private func offerWrite(_ event: WriteEvent<Object>, evictedObjects: inout [Object]) {
        while writeBuffer.offer(event) == false {
            evictedObjects.append(contentsOf: drainBuffers())
        }
    }

    /// 调用方必须在释放 cache、maintenance 和 policy 锁后通知业务层。
    private func notifyEvictions(_ objects: [Object]) {
        guard let onEvict else { return }
        objects.forEach(onEvict)
    }

    private func currentGeneration() -> UInt64 {
        generation.current()
    }

    private func advanceGeneration() -> UInt64 {
        generation.advance()
    }
}

// MARK: - Generation

/// 缓存代际计数器，用于 `removeAll` 整代清空后让滞留的旧读/写事件失效。
final class CacheGeneration: @unchecked Sendable {
    private let value = ManagedAtomic<UInt64>(0)

    fileprivate func current() -> UInt64 {
        value.load(ordering: .relaxed)
    }

    func advance() -> UInt64 {
        value.wrappingIncrementThenLoad(ordering: .acquiringAndReleasing)
    }
}

// MARK: - Locking

/// 基于 `os_unfair_lock` 的轻量互斥锁，用于替代 `NSLock`。
///
/// 非竞争路径无 syscall、不走 ObjC 派发，比 `NSLock` 显著更快。对外暴露与
/// `NSLock` 一致的 `lock()` / `unlock()`，便于直接替换；同时提供 `withLock`。
fileprivate final class UnfairLock: @unchecked Sendable {
    private var storage = os_unfair_lock_s()

    fileprivate func lock() {
        os_unfair_lock_lock(&storage)
    }

    fileprivate func unlock() {
        os_unfair_lock_unlock(&storage)
    }

    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}

// MARK: - Buffers

/// 读路径访问事件，记录 hit/miss 与代际，供 maintenance 消费。
enum ReadEvent<Object> {
    // 注意：不携带 `key: String`。maintenance（`applyReadLocked`）只用 `keyHash`（+ hit 的
    // `node`），从不读 key。若带上 key，每次 get 的 offer 都会 retain/release 一条 String，
    // 是 get / getOrLoad 热路径上的纯开销。
    case hit(keyHash: Int, node: Node<Object>, generation: UInt64)
    case miss(keyHash: Int, generation: UInt64)

    var keyHash: Int {
        switch self {
        case .hit(let keyHash, _, _), .miss(let keyHash, _):
            return keyHash
        }
    }

    var generation: UInt64 {
        switch self {
        case .hit(_, _, let generation), .miss(_, let generation):
            return generation
        }
    }
}

/// 无锁有界 MPMC 环形缓冲（Vyukov bounded MPMC queue）。
///
/// 用途是把 get 路径的「记录访问」与 maintenance 的「消费访问」彻底解耦：生产者
/// （多个 get 线程）CAS 抢位写入，消费者（maintenance drain 与 `removeAll`）
/// CAS 抢位读取，全程无 `NSLock`、无数组扩容。环满时**静默丢弃**读事件——频率
/// sketch 只需统计采样，丢弃少量读不影响命中率；容量收敛由 `WriteBuffer` +
/// `enforceMaximumIfNeeded` 保证，与此处无关。
///
/// 正确性：负载的发布/读取同步完全由每个槽位的 `sequence` 原子的 acquire/release
/// 承担（生产者 `.releasing` 发布、消费者 `.acquiring` 读取后再 `.releasing`
/// 归还）；`enqueuePosition` / `dequeuePosition` 严格单调不回绕，故无 ABA。
/// `slot.event` 为普通 `var`，但在任意时刻仅被「持有该 ticket 的那一方」访问，
/// 因此不存在数据竞争。
final class ReadBuffer<Object: Sendable>: @unchecked Sendable {
    private final class Slot {
        let sequence: ManagedAtomic<Int>
        var event: ReadEvent<Object>?

        init(sequence: Int) {
            self.sequence = ManagedAtomic(sequence)
        }
    }

    private let capacity: Int
    private let mask: Int
    private let slots: [Slot]
    private let enqueuePosition = ManagedAtomic<Int>(0)
    private let dequeuePosition = ManagedAtomic<Int>(0)

    init(capacity: Int = 8192) {
        precondition(capacity > 0, "ReadBuffer capacity must be > 0")
        let normalized = nextPowerOfTwo(capacity)
        self.capacity = normalized
        self.mask = normalized - 1

        var slots: [Slot] = []
        slots.reserveCapacity(normalized)
        for index in 0..<normalized {
            slots.append(Slot(sequence: index))
        }
        self.slots = slots
    }

    var hasPending: Bool {
        dequeuePosition.load(ordering: .relaxed) != enqueuePosition.load(ordering: .relaxed)
    }

    func offer(_ event: ReadEvent<Object>) {
        var position = enqueuePosition.load(ordering: .relaxed)
        while true {
            let slot = slots[position & mask]
            let sequence = slot.sequence.load(ordering: .acquiring)
            let difference = sequence - position
            if difference == 0 {
                if enqueuePosition.compareExchange(
                    expected: position,
                    desired: position + 1,
                    ordering: .relaxed
                ).exchanged {
                    slot.event = event
                    slot.sequence.store(position + 1, ordering: .releasing)
                    return
                }
                // CAS 失败：其它生产者抢先，重新抢位
                position = enqueuePosition.load(ordering: .relaxed)
            } else if difference < 0 {
                // 环满：丢弃本次读事件（统计采样可接受）
                return
            } else {
                // 该槽位已被其它生产者推进，重载位置
                position = enqueuePosition.load(ordering: .relaxed)
            }
        }
    }

    func poll() -> ReadEvent<Object>? {
        while true {
            let position = dequeuePosition.load(ordering: .relaxed)
            let slot = slots[position & mask]
            let sequence = slot.sequence.load(ordering: .acquiring)
            let difference = sequence - (position + 1)
            if difference == 0 {
                if dequeuePosition.compareExchange(
                    expected: position,
                    desired: position + 1,
                    ordering: .relaxed
                ).exchanged {
                    let event = slot.event
                    slot.event = nil
                    slot.sequence.store(position + capacity, ordering: .releasing)
                    return event
                }
                // CAS 失败：其它消费者抢先，重试下一槽
            } else if difference < 0 {
                // 空
                return nil
            } else {
                // 该槽位已被其它消费者处理，继续重试
            }
        }
    }

    fileprivate func pollBatch(limit: Int) -> [ReadEvent<Object>] {
        guard limit > 0 else { return [] }

        var batch: [ReadEvent<Object>] = []
        batch.reserveCapacity(Swift.min(limit, capacity))
        while batch.count < limit {
            guard let event = poll() else { break }
            batch.append(event)
        }
        return batch
    }

    func removeAll() {
        // 消费者侧 drain 到空。残留的 straggler 读事件携带旧 generation，会被
        // `PolicyState.applyReadLocked` 的 generation 守卫丢弃，语义不变。
        var drained = 0
        while drained < capacity {
            if poll() == nil {
                break
            }
            drained += 1
        }
    }
}

/// 写路径事件：新增节点、移除节点或整代清空。
enum WriteEvent<Object> {
    case add(Node<Object>)
    case remove(Node<Object>)
    case clear(generation: UInt64)
}

/// 写路径有界缓冲，按批供 maintenance 消费，读取后按需压缩。
final class WriteBuffer<Object: Sendable>: @unchecked Sendable {
    private let lock = UnfairLock()
    private let capacity: Int
    private var events: [WriteEvent<Object>] = []
    private var readIndex = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        events.reserveCapacity(capacity)
    }

    var hasPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readIndex < events.count
    }

    @discardableResult
    func offer(_ event: WriteEvent<Object>) -> Bool {
        lock.lock()
        if events.count - readIndex >= capacity {
            lock.unlock()
            return false
        }
        if readIndex > 0, events.count == events.capacity {
            events.removeFirst(readIndex)
            readIndex = 0
        }
        events.append(event)
        lock.unlock()
        return true
    }

    func removeAll() {
        lock.lock()
        events.removeAll()
        readIndex = 0
        lock.unlock()
    }

    func pollBatch(limit: Int) -> [WriteEvent<Object>] {
        lock.lock()
        defer { lock.unlock() }

        let available = min(max(0, limit), events.count - readIndex)
        guard available > 0 else {
            return []
        }

        let upperBound = readIndex + available
        let batch = Array(events[readIndex..<upperBound])
        readIndex = upperBound
        compactIfNeeded()
        return batch
    }

    private func compactIfNeeded() {
        if readIndex > 256, readIndex * 2 >= events.count {
            events.removeFirst(readIndex)
            readIndex = 0
        }
    }
}

// MARK: - ConcurrentStringMap

/// `ConcurrentStringMap.putOrUpdate` 的返回：新增（含被替换项）或原地更新。
enum PutResult<Object> {
    case inserted(Node<Object>, replaced: Node<Object>?)
    case updated(Node<Object>)
}

/// 复用已计算好的 `keyHash` 作为字典键的哈希来源，避免 Swift Dictionary 在每次
/// 查表时对整条 String 再做一次 SipHash。
///
/// `==` 必须在 `hash` 命中后再比较 `key`：FNV-1a 是 64-bit 哈希，海量 key 下
/// 存在碰撞，仅靠 `hash` 比较会导致静默数据错乱。
fileprivate struct HashedKey: Hashable {
    let key: String
    let hash: Int

    static func == (lhs: HashedKey, rhs: HashedKey) -> Bool {
        lhs.hash == rhs.hash && lhs.key == rhs.key
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(hash)
    }
}

/// 分桶加锁的并发 String→Object 字典，复用预算好的 `keyHash` 作为哈希来源，
/// 避免 Swift Dictionary 每次查表都对整条 String 再做一次 SipHash。
final class ConcurrentStringMap<Object: Sendable>: @unchecked Sendable {
    private final class Bucket {
        let lock = UnfairLock()
        var dictionary: [HashedKey: Node<Object>] = [:]
    }

    private let buckets: [Bucket]
    private let mask: Int
    private let count = ManagedAtomic(0)

    init(bucketCount: Int = 64) {
        let count = nextPowerOfTwo(max(1, bucketCount))
        self.buckets = (0..<count).map { _ in Bucket() }
        self.mask = count - 1
    }

    func getNodeAndObject(_ key: String, keyHash: Int) -> (node: Node<Object>, object: Object)? {
        let bucket = bucket(forHash: keyHash)
        bucket.lock.lock()
        defer { bucket.lock.unlock() }

        guard let node = bucket.dictionary[HashedKey(key: key, hash: keyHash)] else {
            return nil
        }

        return (node, node.object)
    }

    func putOrUpdate(_ key: String, keyHash: Int, _ object: Object, generation: UInt64 = 0) -> PutResult<Object> {
        let bucket = bucket(forHash: keyHash)
        bucket.lock.lock()
        defer { bucket.lock.unlock() }

        let hashedKey = HashedKey(key: key, hash: keyHash)
        if let node = bucket.dictionary[hashedKey], node.generation == generation {
            node.object = object
            return .updated(node)
        }

        let replaced = bucket.dictionary[hashedKey]
        let node = Node(key: key, object: object, segment: .window, generation: generation, keyHash: keyHash)
        bucket.dictionary[hashedKey] = node
        if replaced == nil {
            count.wrappingIncrement(ordering: .relaxed)
        }
        return .inserted(node, replaced: replaced)
    }

    func remove(_ key: String, keyHash: Int) -> Node<Object>? {
        let bucket = bucket(forHash: keyHash)
        bucket.lock.lock()
        defer { bucket.lock.unlock() }

        let removed = bucket.dictionary.removeValue(forKey: HashedKey(key: key, hash: keyHash))
        if removed != nil {
            decrementCount()
        }
        return removed
    }

    @discardableResult
    func removeIfSameNode(_ key: String, keyHash: Int, _ node: Node<Object>) -> Bool {
        let bucket = bucket(forHash: keyHash)
        bucket.lock.lock()
        defer { bucket.lock.unlock() }

        let hashedKey = HashedKey(key: key, hash: keyHash)
        if bucket.dictionary[hashedKey] === node {
            bucket.dictionary.removeValue(forKey: hashedKey)
            decrementCount()
            return true
        }
        return false
    }

    @discardableResult
    func removeAll() -> [Node<Object>] {
        var removedNodes: [Node<Object>] = []
        removedNodes.reserveCapacity(estimatedSize())
        for bucket in buckets {
            bucket.lock.lock()
            removedNodes.append(contentsOf: bucket.dictionary.values)
            bucket.dictionary.removeAll()
            bucket.lock.unlock()
        }
        count.store(0, ordering: .relaxed)
        return removedNodes
    }

    func estimatedSize() -> Int {
        max(0, count.load(ordering: .relaxed))
    }

    func sampleNodes(count: Int) -> [Node<Object>] {
        guard count > 0 else { return [] }

        var samples: [Node<Object>] = []
        samples.reserveCapacity(count)
        var index = 0

        for bucket in buckets {
            bucket.lock.lock()
            for node in bucket.dictionary.values {
                index += 1
                if samples.count < count {
                    samples.append(node)
                } else {
                    let replacementIndex = Int.random(in: 0..<index)
                    if replacementIndex < count {
                        samples[replacementIndex] = node
                    }
                }
            }
            bucket.lock.unlock()
        }
        return samples
    }

    private func bucket(forHash keyHash: Int) -> Bucket {
        buckets[spreadHash(keyHash) & mask]
    }

    private func decrementCount() {
        var current = count.load(ordering: .relaxed)
        while current > 0 {
            let result = count.compareExchange(
                expected: current,
                desired: current - 1,
                ordering: .relaxed
            )
            if result.exchanged {
                return
            }
            current = result.original
        }
    }
}

// MARK: - Policy

/// W-TinyLFU 策略状态：window / probation / protected 三段访问序 deque 加频率草图，
/// 由 maintenance 串行维护，负责准入、晋升与淘汰裁决。
final class PolicyState<Object: Sendable>: @unchecked Sendable {
    private let lock = UnfairLock()
    private let maximum: Int
    private let windowMaximum: Int
    private let mainMaximum: Int
    private let mainProtectedMaximum: Int
    private let data: ConcurrentStringMap<Object>
    private var window = AccessOrderDeque<Object>()
    private var probation = AccessOrderDeque<Object>()
    private var protected = AccessOrderDeque<Object>()
    private var sketch: FrequencySketch
    private let generation: CacheGeneration

    init(
        maximum: Int,
        data: ConcurrentStringMap<Object>,
        generation: CacheGeneration = CacheGeneration()
    ) {
        self.maximum = maximum
        let capacities = CapacitySplit(maximum: maximum)
        self.windowMaximum = capacities.windowMaximum
        self.mainMaximum = capacities.mainMaximum
        self.mainProtectedMaximum = capacities.mainProtectedMaximum
        self.data = data
        self.generation = generation
        self.sketch = FrequencySketch(maximumSize: max(1, maximum))
    }

    func applyReads(_ events: [ReadEvent<Object>]) {
        guard events.isEmpty == false else { return }

        lock.lock()
        for event in events {
            applyReadLocked(event)
        }
        lock.unlock()
    }

    private func applyReadLocked(_ event: ReadEvent<Object>) {
        switch event {
        case .hit(let keyHash, let node, let generation):
            let currentGeneration = self.generation.current()
            guard generation == currentGeneration, node.generation == currentGeneration else { return }
            sketch.record(keyHash)
            guard node.isAlive, node.isLinked else { return }
            onHit(node)

        case .miss(let keyHash, let generation):
            guard generation == self.generation.current() else { return }
            sketch.record(keyHash)
        }
    }

    func applyWrites(_ events: [WriteEvent<Object>]) -> [Object] {
        guard events.isEmpty == false else { return [] }

        var evictedObjects: [Object] = []
        lock.lock()
        for event in events {
            applyWriteLocked(event, evictedObjects: &evictedObjects)
        }
        lock.unlock()
        return evictedObjects
    }

    private func applyWriteLocked(_ event: WriteEvent<Object>, evictedObjects: inout [Object]) {
        switch event {
        case .add(let node):
            add(node, evictedObjects: &evictedObjects)

        case .remove(let node):
            remove(node)

        case .clear(let generation):
            clear(generation: generation)
        }
    }

    private func add(_ node: Node<Object>, evictedObjects: inout [Object]) {
        let currentGeneration = generation.current()
        guard maximum > 0, node.generation == currentGeneration, node.isAlive, node.isLinked == false else { return }

        sketch.record(node.keyHash)
        node.segment = .window
        window.appendToHead(node)
        enforceWindowMaximum(evictedObjects: &evictedObjects)
    }

    private func remove(_ node: Node<Object>) {
        if node.isLinked {
            removeFromCurrentSegment(node)
        }
        node.isAlive = false
        node.unlink()
    }

    private func clear(generation clearGeneration: UInt64) {
        guard clearGeneration == generation.current() else { return }

        window.removeAll(markDead: true)
        probation.removeAll(markDead: true)
        protected.removeAll(markDead: true)
        sketch.reset()
    }

    private func onHit(_ node: Node<Object>) {
        guard node.isLinked else { return }

        switch node.segment {
        case .window:
            window.moveToHead(node)

        case .probation:
            probation.remove(node)
            node.segment = .protected
            protected.appendToHead(node)
            enforceProtectedMaximum()

        case .protected:
            protected.moveToHead(node)
        }
    }

    private func enforceWindowMaximum(evictedObjects: inout [Object]) {
        while window.count > windowMaximum, let candidate = window.removeTail() {
            candidate.segment = .probation
            admitCandidateToMain(candidate, evictedObjects: &evictedObjects)
        }
    }

    private func admitCandidateToMain(_ candidate: Node<Object>, evictedObjects: inout [Object]) {
        guard mainMaximum > 0 else {
            evict(candidate, evictedObjects: &evictedObjects)
            return
        }

        if mainSize < mainMaximum {
            probation.appendToHead(candidate)
            return
        }

        guard let victim = probation.tail ?? protected.tail else {
            evict(candidate, evictedObjects: &evictedObjects)
            return
        }

        let candidateFrequency = sketch.estimate(candidate.keyHash)
        let victimFrequency = sketch.estimate(victim.keyHash)

        if candidateFrequency > victimFrequency {
            evict(victim, evictedObjects: &evictedObjects)
            probation.appendToHead(candidate)
        } else {
            evict(candidate, evictedObjects: &evictedObjects)
        }
    }

    private func enforceProtectedMaximum() {
        while protected.count > mainProtectedMaximum, let demoted = protected.removeTail() {
            demoted.segment = .probation
            probation.appendToHead(demoted)
        }
    }

    private func evict(_ node: Node<Object>, evictedObjects: inout [Object]) {
        if node.isLinked {
            removeFromCurrentSegment(node)
        }

        node.isAlive = false
        node.unlink()
        if data.removeIfSameNode(node.key, keyHash: node.keyHash, node) {
            evictedObjects.append(node.object)
        }
    }

    private func removeFromCurrentSegment(_ node: Node<Object>) {
        switch node.segment {
        case .window:
            window.remove(node)
        case .probation:
            probation.remove(node)
        case .protected:
            protected.remove(node)
        }
    }

    private var mainSize: Int {
        probation.count + protected.count
    }

}

/// 按总容量切分 window 与 main（probation / protected）的配额。
struct CapacitySplit {
    let maximum: Int
    let windowMaximum: Int
    let mainMaximum: Int
    let mainProtectedMaximum: Int
    let mainProbationMaximum: Int

    init(maximum: Int) {
        self.maximum = max(0, maximum)

        if maximum <= 0 {
            self.windowMaximum = 0
            self.mainMaximum = 0
            self.mainProtectedMaximum = 0
            self.mainProbationMaximum = 0
        } else if maximum == 1 {
            self.windowMaximum = 1
            self.mainMaximum = 0
            self.mainProtectedMaximum = 0
            self.mainProbationMaximum = 0
        } else if maximum == 2 {
            self.windowMaximum = 1
            self.mainMaximum = 1
            self.mainProtectedMaximum = 0
            self.mainProbationMaximum = 1
        } else {
            let main = Int(floor(Double(maximum) * 0.99))
            let protected = min(max(1, Int(floor(Double(main) * 0.80))), main - 1)
            self.mainMaximum = main
            self.windowMaximum = max(1, maximum - main)
            self.mainProtectedMaximum = protected
            self.mainProbationMaximum = main - protected
        }
    }
}

// MARK: - Segment And Node

/// W-TinyLFU 的三段：window（新入场）、probation（试用）、protected（受保护）。
enum Segment {
    case window
    case probation
    case protected
}

/// 缓存条目节点：承载 object、原子访问时间、segment、访问序链表指针及存活/链接标记。
final class Node<Object> {
    let key: String
    let keyHash: Int
    let generation: UInt64
    var object: Object
    /// 时间戳使用原子读写，使并发命中路径不需要额外获取 cache 全局锁。
    let writtenAtMilliseconds: ManagedAtomic<Int64>
    let readAtMilliseconds: ManagedAtomic<Int64>
    var segment: Segment
    weak var previous: Node?
    var next: Node?
    var isAlive: Bool
    var isLinked: Bool

    init(key: String, object: Object, segment: Segment, generation: UInt64 = 0, keyHash: Int? = nil) {
        let nowMilliseconds = Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
        self.key = key
        self.keyHash = keyHash ?? stableHash(key)
        self.generation = generation
        self.object = object
        self.writtenAtMilliseconds = ManagedAtomic(nowMilliseconds)
        self.readAtMilliseconds = ManagedAtomic(nowMilliseconds)
        self.segment = segment
        self.isAlive = true
        self.isLinked = false
    }

    fileprivate func unlink() {
        previous = nil
        next = nil
        isLinked = false
    }
}

// MARK: - AccessOrderDeque

/// 按访问顺序维护的节点双向链表，供各 segment 做 LRU 晋升与淘汰。
final class AccessOrderDeque<Object> {
    private(set) var head: Node<Object>?
    private(set) var tail: Node<Object>?
    private(set) var count: Int = 0

    func appendToHead(_ node: Node<Object>) {
        node.previous = nil
        node.next = head
        node.isLinked = true

        head?.previous = node
        head = node

        if tail == nil {
            tail = node
        }

        count += 1
    }

    func moveToHead(_ node: Node<Object>) {
        guard node !== head else { return }
        remove(node)
        appendToHead(node)
    }

    func remove(_ node: Node<Object>) {
        guard node.isLinked else { return }

        if node === head {
            head = node.next
        }

        if node === tail {
            tail = node.previous
        }

        node.previous?.next = node.next
        node.next?.previous = node.previous
        node.unlink()

        if count > 0 {
            count -= 1
        }

        if count == 0 {
            head = nil
            tail = nil
        }
    }

    func removeTail() -> Node<Object>? {
        guard let tail else { return nil }
        remove(tail)
        return tail
    }

    func removeAll(markDead: Bool = false) {
        var current = head
        while let node = current {
            let next = node.next
            if markDead {
                node.isAlive = false
            }
            node.unlink()
            current = next
        }

        head = nil
        tail = nil
        count = 0
    }
}

// MARK: - FrequencySketch

/// 4 行 N 列计数数组构成的 Count-Min 频率草图，达到采样阈值后整体 halving 衰减。
struct FrequencySketch {
    private static let depth = 4
    private static let counterMax: UInt8 = 15

    private let tableLength: Int
    private let mask: Int
    private let sampleSize: Int
    private var sampleCount = 0
    private var counters: [[UInt8]]

    init(maximumSize: Int) {
        self.tableLength = nextPowerOfTwo(max(1, maximumSize))
        self.mask = tableLength - 1
        self.sampleSize = max(1, 10 * max(1, maximumSize))
        self.counters = Array(
            repeating: Array(repeating: 0, count: tableLength),
            count: Self.depth
        )
    }

    mutating func record(_ keyHash: Int) {
        for row in 0..<Self.depth {
            let index = indexFor(keyHash, row: row)
            if counters[row][index] < Self.counterMax {
                counters[row][index] += 1
            }
        }

        sampleCount += 1
        if sampleCount >= sampleSize {
            age()
        }
    }

    func estimate(_ keyHash: Int) -> UInt8 {
        var result = Self.counterMax
        for row in 0..<Self.depth {
            result = min(result, counters[row][indexFor(keyHash, row: row)])
        }
        return result
    }

    fileprivate mutating func reset() {
        sampleCount = 0
        for row in counters.indices {
            counters[row].replaceSubrange(
                counters[row].indices,
                with: repeatElement(0, count: tableLength)
            )
        }
    }

    private mutating func age() {
        for row in counters.indices {
            for index in counters[row].indices {
                counters[row][index] >>= 1
            }
        }
        sampleCount = sampleSize / 2
    }

    private func indexFor(_ keyHash: Int, row: Int) -> Int {
        let mixed = keyHash ^ Int(truncatingIfNeeded: rowSeed(row))
        return spreadHash(mixed) & mask
    }

    private func rowSeed(_ row: Int) -> UInt64 {
        switch row {
        case 0: return 0x9e37_79b9_7f4a_7c15
        case 1: return 0xc2b2_ae3d_27d4_eb4f
        case 2: return 0x1656_67b1_9e37_79f9
        default: return 0x85eb_ca6b_c2b2_ae63
        }
    }
}

// MARK: - Hashing

/// FNV-1a 64-bit 稳定哈希，作为字典 key 的哈希来源，避免再对 String 做 SipHash。
func stableHash(_ key: String) -> Int {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in key.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x0000_0100_0000_01b3
    }
    return Int(truncatingIfNeeded: hash)
}

/// Murmur3 finalizer 风格的比特混淆，把哈希扩散到全字以减少分桶碰撞。
fileprivate func spreadHash(_ hash: Int) -> Int {
    var value = UInt(bitPattern: hash)
    value ^= value >> 16
    value &*= 0x7feb_352d
    value ^= value >> 15
    value &*= 0x846c_a68b
    value ^= value >> 16
    return Int(truncatingIfNeeded: value)
}

/// 不小于 `value` 的最小 2 的幂，用于把容量对齐到环形缓冲与分桶数组。
fileprivate func nextPowerOfTwo(_ value: Int) -> Int {
    guard value > 1 else { return 1 }
    var result = 1
    while result < value {
        result <<= 1
    }
    return result
}
