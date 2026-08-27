# WTinyLFUCache 产品设计文档

## 0. 文档目标

本文档使用 4C 法则组织 `WTinyLFUCache` 的产品设计，并以当前代码为基线：

```text
Magent/Sources/Core/MagentCache.swift
```

- Context：缓存组件的定位、目标和非目标
- Contract：公开 API、调用方契约和内部模块契约
- Core Logic：核心读写链路、W-TinyLFU 策略和容量收敛
- Corners：边界场景、测试、benchmark、观测和降级

本次 review 的结论是：旧文档总体方向仍成立，但内容过长，并混入了早期 loading 方案、阶段计划和重复使用说明。当前文档已按代码压缩并修正文档漂移。

---

# 1. Context

## 1.1 产品定位

`WTinyLFUCache<Object>` 是 Magent Core 内部的通用本地内存缓存组件。

它的抽象是：

```text
String -> Object
```

当前实现包含两个入口：

| 入口 | 定位 |
|---|---|
| `WTinyLFUCache<Object>` | 通用泛型缓存 |
| `MagentCache` | 面向 `AccessControlPolicy` 的 Magent 策略缓存包装层 |

`MagentCache` 不重新实现策略，只固定 value 类型并透传到底层 `WTinyLFUCache`。

## 1.2 设计目标

| 目标 | 说明 |
|---|---|
| 命中路径轻量 | `get` / hit `getOrLoad` 同步返回，不创建 future |
| 高基数友好 | 用 Window LRU + TinyLFU Admission + Main SLRU 抵抗 scan 污染 |
| API 简洁 | 初始化只暴露 `capacity`，不公开内部策略参数 |
| NIO 友好 | 对外 API 同步，内部 maintenance 使用专用 `EventLoopGroup` |
| 并发安全 | map、buffer、policy maintenance 分层处理并发读写 |
| 可观测 | stats 默认关闭，显式 `recordStats()` 后提供快照 |
| 可测试 | internal `debugValidate()` 校验 map / policy / deque 一致性 |

## 1.3 非目标

`WTinyLFUCache` 不负责：

- 定义业务 key 格式。
- normalize、trim、lowercase 或校验 key。
- 定义业务 value schema。
- 判断 TTL、业务版本、tenant 或 namespace。
- 表达 not found / no match；这类语义由 `Object` 自己表达。
- 按字节容量淘汰。
- 持久化或分布式缓存。
- 合并同 key 并发 loader。
- 在 NIO `EventLoop` 上执行阻塞 I/O。

---

# 2. Contract

## 2.1 当前公开 API

```swift
public protocol Cache: AnyObject, Sendable {
    associatedtype Object

    init(capacity: Int)

    @discardableResult
    func recordStats() -> Self

    func get(_ key: String) -> Object?
    func getOrLoad(_ key: String, _ loader: (String) -> Object) -> Object
    func put(_ key: String, _ object: Object)
    func invalidate(_ key: String)
    func removeAll()
    func estimatedSize() -> Int
    func statsSnapshot() -> WTinyLFUStatsSnapshot
    func shutdownGracefully(_ callback: @escaping @Sendable (Error?) -> Void)
}
```

关键契约：

- `capacity < 0` 触发 precondition failure。
- `capacity == 0` 表示禁用存储，但 `getOrLoad` 仍调用 loader 并返回结果。
- loader 是 `getOrLoad` 调用点传入的同步闭包，cache 不保存 loader。
- `getOrLoad` 不返回 `EventLoopFuture`，也不接收外部 `EventLoop`。
- `get` 返回 `Object?`，miss 用 `nil` 表达。
- `getOrLoad` 返回 `Object`，不缓存 `nil`；空结果应由业务 value 类型表达。
- shutdown 后 `getOrLoad` 直接 bypass 到 loader，不再定义不会被抛出的 cache shutdown error。

## 2.2 Loader 契约

```swift
let object = cache.getOrLoad(key) { key in
    loadObject(for: key)
}
```

loader 行为：

- miss 时由当前调用线程同步执行。
- 返回值先作为当前请求结果返回；是否长期保留由 W-TinyLFU admission 决定。
- 同 key 并发 miss 可能重复调用 loader。
- loader 返回后，cache 会二次 lookup；如果同 key 已被其它请求写入，则返回已有对象。
- 慢 loader、异步 I/O、失败重试、single-flight 都应在 cache 外层处理。

## 2.3 Key / Object 契约

key 是普通 `String`，以下值互不相同：

```text
"abc"
" abc"
"abc "
"ABC"
"a/b/c"
"a|b|c"
```

调用方如果需要版本、tenant、namespace 或 host normalize，应自行编码：

```text
"ruleVersion=42|host=api.example.com"
"tenant=A|user=123"
"namespace=config|key=feature-x"
```

`Object` 完全由调用方定义。若 `Object` 是 class，cache 保存引用，不 copy，也不保护对象内部可变状态；调用方需要保证对象不可变或线程安全。

## 2.4 Stats 契约

stats 默认关闭。调用 `recordStats()` 后，`statsSnapshot()` 返回累计计数：

```text
requests, hits, misses, puts, loadSuccesses, admissions, rejections,
evictions, invalidations, removeAlls
```

`estimatedSize()` 不属于 stats snapshot 字段，由 cache 单独返回。业务指标可以在外层计算：

```text
hit_rate = hits / requests
```

---

# 3. Core Logic

## 3.1 结构分层

```text
WTinyLFUCache<Object>
  public API
  ConcurrentStringMap<Object>
  ReadBuffer / WriteBuffer
  PolicyState
    Window LRU
    Main Probation
    Main Protected
    FrequencySketch
  internal EventLoopGroup
```

职责边界：

- map 负责 key 到 node/object 的并发读写。
- read buffer 记录 hit/miss 访问事件，满时可丢弃读事件。
- write buffer 记录 add/remove/clear 写事件。
- policy 只在 maintenance drain 时维护 window、probation、protected 和 sketch。
- internal `EventLoopGroup` 只负责 maintenance，不执行业务 loader。

## 3.2 读链路

`get(key)`：

```text
capacity == 0
  -> nil

map hit
  -> 返回 object
  -> 记录 hit stats
  -> offer read hit
  -> schedule drain

map miss
  -> 返回 nil
  -> 记录 miss stats
  -> offer read miss
  -> schedule drain
```

读事件用于更新频率草图和访问顺序，不改变当前返回值。

## 3.3 Loading 链路

`getOrLoad(key, loader)`：

```text
cache shutdown
  -> loader(key)

lookup hit
  -> object

lookup miss
  -> loader(key)
  -> record load success
  -> capacity == 0 时直接返回
  -> 二次 lookup
  -> 仍不存在则 put
  -> 返回 loader object
```

admission reject 只影响对象是否留在缓存中，不影响当前请求的返回值。

## 3.4 写链路

`put(key, object)`：

```text
capacity == 0
  -> no-op

key exists
  -> 更新 object
  -> offer read hit
  -> schedule drain

new key
  -> 写入 map
  -> offer write add
  -> 必要时强制容量收敛
  -> schedule drain
```

`invalidate(key)` 从 map 删除 key，并提交 remove event。key 不存在时不报错。

`removeAll()` 会 advance generation，清空 map、read buffer、write buffer，并提交 clear event；旧 generation 的滞留事件在 maintenance 中被忽略。

## 3.5 W-TinyLFU 策略

当前策略由三部分组成：

| 结构 | 职责 |
|---|---|
| Window LRU | 新 key 的短期试用区 |
| TinyLFU Admission | 用近似频率决定 candidate 是否进入 main |
| Main SLRU | probation / protected 两级保护热点 |

容量切分：

| `capacity` | window | main | protected |
|---:|---:|---:|---:|
| `0` | `0` | `0` | `0` |
| `1` | `1` | `0` | `0` |
| `2` | `1` | `1` | `0` |
| `> 2` | `max(1, capacity - floor(0.99 * capacity))` | `floor(0.99 * capacity)` | `min(max(1, floor(0.8 * main)), main - 1)` |

admission 规则：

```text
candidateFrequency > victimFrequency
  -> evict victim
  -> admit candidate

candidateFrequency <= victimFrequency
  -> reject candidate
  -> keep victim
```

频率相等时保留已有 main entry，降低扫描流量导致的抖动。

## 3.6 容量收敛

正常写入允许短暂超过 `capacity`，因为 map 写入和 policy maintenance 是解耦的。

强制收敛阈值：

```text
capacity + max(1, min(1024, capacity))
```

当 `estimatedSize()` 超过该 transient budget 时，写入路径会 drain write buffer，直到 map 回到 `capacity` 内或没有 pending write event。

---

# 4. Corners

## 4.1 Public API 边界

公开 API 的边界是同步、窄配置、无业务语义：

| 约束 | 说明 | 覆盖测试 |
|---|---|---|
| miss 返回 `nil` | `get` 不触发 loader，也不创建 entry | `testGetReturnsNilForMissingKey` |
| `put` 后可读回 | 同 key 应命中同一个对象值 | `testPutThenGetReturnsStoredObject` |
| 重复 `put` 更新对象 | 同 key 更新不增加 size | `testPutExistingKeyUpdatesObject` |
| `invalidate` 删除单 key | key 不存在时不报错，存在时 size 回落 | `testInvalidateRemovesObject` |
| `removeAll` 清空缓存 | 所有 key 不再可读，size 归零 | `testRemoveAllClearsObjects` |
| `capacity == 0` 只禁用存储 | `getOrLoad` 仍调用 loader；`get` 仍 miss | `testCapacityZeroDisablesStorageButAllowsLoaderBypass` |
| `MagentCache` 只做包装 | value 固定为 `AccessControlPolicy`，复用同一 loading 语义 | `testGetOrLoadCachesAccessControlPolicy` |

这些测试约束说明：public API 不暴露 window/main/protected、sketch、buffer 或 EventLoop 参数；调用方只能通过 key、object、capacity 和 loader 使用缓存。

## 4.2 Loader 边界

loader 是调用点同步闭包，不是 cache 内部注册状态：

| 约束 | 说明 | 覆盖测试 |
|---|---|---|
| miss 后加载并写回 | 第一次 miss 调 loader，后续同 key 直接命中 | `testGetOrLoadLoadsAndCachesObject` |
| hit 不调用 loader | 已有对象优先，loader 不应参与 hit 路径 | `testGetOrLoadHitDoesNotCallLoader` |
| 不同 key 独立加载 | loader 看到的 key 必须是当前请求 key | `testDifferentKeysLoadIndependently` |
| 并发 loading 结果确定 | 即使同 key 并发 miss 可能重复 loader，返回值也必须是 key 的规范值 | `testConcurrentGetOrLoadReturnsDeterministicValue` |
| shutdown 后 bypass | cache 关闭后 `getOrLoad` 直接调用 loader，不写回缓存 | `testShutdownGetOrLoadBypassesCacheAndUsesLoader` |

不在 cache 内部做的事情：

- 不保存 loader。
- 不提供 `setLoader`。
- 不返回 `EventLoopFuture`。
- 不合并同 key 并发 loader。
- 不表达 loader 失败；失败语义由调用方封装到外层。

## 4.3 NIO 与并发边界

cache API 可以从 NIO EventLoop 或普通线程调用，但 loader 不应在 EventLoop 上执行阻塞 I/O。

| 约束 | 说明 | 覆盖测试 |
|---|---|---|
| 多 EventLoop 可调用 | 多个 NIO EventLoop 上调用 `getOrLoad` 不破坏返回值和容量 | `testGetOrLoadCanBeCalledFromMultipleEventLoops` |
| ChannelHandler 中可调用 | handler 回调内同步 `getOrLoad` 并写出结果 | `testGetOrLoadWorksInsideChannelHandler` |
| 并发读写 loading 收敛 | 混合 `getOrLoad` / `put` / `get` 后 size 最终回到 capacity | `testGetOrLoadConcurrentNormalReadsAndWrites` |
| 并发 mutation 收敛 | 多线程 `put/get/invalidate/removeAll` 后容量收敛 | `testConcurrentMutationsStayBounded` |
| get 热路径返回规范值 | 并发 get + 幂等 put 不允许串值、脏值或 use-after-free 痕迹 | `testConcurrentGetAlwaysReturnsCanonicalValue` |
| 重负载混合操作稳定 | 50 万次混合操作后 size 与内部结构一致 | `testHeavyConcurrentMixStaysBounded` |
| 长跑不死锁不泄漏 size | 多 worker 长跑后仍可读写，`debugValidate` 通过 | `testLongRunningMixedOpsStayStableAndBounded` |

这些测试约束把 NIO 友好限定在“可从 EventLoop 调用 cache API”，而不是允许 loader 在 EventLoop 上阻塞。

## 4.4 容量与 maintenance 边界

map 写入和 policy maintenance 解耦，所以容量语义不是“每次 `put` 后立即严格不超过 capacity”，而是“短暂超额 + 强制收敛 + 最终不超过 capacity”。

| 约束 | 说明 | 覆盖测试 |
|---|---|---|
| 连续写入最终收敛 | 写入超过容量后最终 `estimatedSize() <= capacity` | `testCapacityEventuallyConvergesAfterWrites` |
| burst overshoot 有界 | 写入高压下允许短暂超额，但不能无限增长 | `testCapacityOvershootIsBoundedDuringBurstWrites` |
| 持续写压收敛 | 长时间写入压力下 peak size 受 force-drain 预算约束，最终收敛 | `testSustainedWritePressureKeepsTransientSizeBoundedAndConverges` |
| 混合并发收敛 | 并发 mutation、removeAll、loading 混合后容量和结构都收敛 | `testHeavyConcurrentMixStaysBounded` |
| policy 默认行为可验证 | benchmarker 中记录 peak/final size 与 admission/rejection/eviction | `default-policy-validation` benchmark phase |

当前强制收敛阈值是：

```text
capacity + max(1, min(1024, capacity))
```

文档、测试和 benchmark 都应使用这个“transient budget”语义，不再描述成严格同步上限。

## 4.5 W-TinyLFU 策略边界

policy 的核心边界是：新 key 先进入 window，main 只接收通过 TinyLFU admission 的 candidate，probation/protected 负责热点保护。

| 约束 | 说明 | 覆盖测试 |
|---|---|---|
| 容量切分稳定 | `0/1/2/>2` 容量下 window/main/protected 比例固定 | `testCapacitySplitRules` |
| 高频 candidate 准入 | 高频 window candidate 可替换低频 victim | `testPolicyAdmitsHighFrequencyCandidateOverLowerFrequencyVictim` |
| 低频 candidate 拒绝 | 低频 candidate 不替换更热 main victim | `testPolicyRejectsLowFrequencyCandidateAgainstHotVictim` |
| 频率相等拒绝 candidate | tie 时保留已有 main entry，减少 scan 抖动 | `testPolicyRejectsCandidateOnFrequencyTie` |
| probation 命中晋升 | probation hit 晋升 protected，protected 超额时 LRU 降回 probation | `testPolicyPromotesProbationHitAndDemotesProtectedOverflow` |
| 热点抵抗淘汰 | Zipf 热点在冷 key 写入压力下仍应保留有效命中率 | `testZipfHotKeysSurviveEviction` |
| scan 保留热点 | scan 写入下热点生存率和拒绝数应可观测 | `scan-hot-retention` benchmark phase |

策略相关文档必须保留 `candidateFrequency > victimFrequency` 的严格比较；不能改成 `>=`。

## 4.6 内部结构边界

内部结构不是 public API，但它们承载了并发安全和容量正确性，文档需要记录关键不变量：

| 结构 | 约束 | 覆盖测试 |
|---|---|---|
| `AccessOrderDeque` | append、move、remove、removeTail、removeAll 后 head/tail/count/link 自洽 | `testAccessOrderDequeAppendMoveRemoveAndClear` |
| `FrequencySketch` | 频率记录会饱和，采样窗口后 aging | `testFrequencySketchRecordsSaturatesAndAges` |
| `ConcurrentStringMap` | 插入、更新、按同 node 删除、generation 替换都不能误删新节点 | `testConcurrentStringMapPutUpdateRemoveAndRemoveIfSameNode` |
| `ReadBuffer` | hit/miss 事件按序 poll，`removeAll` 丢弃 pending 事件 | `testReadBufferOffersAndPollsEvents`, `testReadBufferRemoveAllDropsPendingEvents` |
| `WriteBuffer` | add/remove/clear 事件按序 poll，`removeAll` 丢弃 pending 事件 | `testWriteBufferOffersAndPollsEvents`, `testWriteBufferRemoveAllDropsPendingEvents` |
| `CacheGeneration` | `removeAll` 后旧 generation read event 不能污染新 policy | `testPolicyClearIgnoresStaleReadEventsFromPreviousGeneration` |

`debugValidate()` 是 internal 工具，不属于 public API。它会先 drain pending maintenance event，再检查：

- map 中的 live node 必须存在于 policy deque。
- policy deque 中的 node 必须存在于 map。
- node 的 generation、segment、live/link 状态必须一致。
- window、main、protected 不超过容量切分。
- deque 的 head、tail、previous、next、count 自洽。

覆盖测试：

```text
testDebugValidatePassesAfterMixedMutations
testHeavyConcurrentMixStaysBounded
testSustainedWritePressureKeepsTransientSizeBoundedAndConverges
testLongRunningMixedOpsStayStableAndBounded
```

## 4.7 Stats 与观测边界

stats 默认关闭，开启后才记录 public path 和 policy path 的计数。

| 约束 | 说明 | 覆盖测试 |
|---|---|---|
| 默认全 0 | 未调用 `recordStats()` 时，普通读写不增加计数 | `testStatsAreDisabledByDefault` |
| policy 计数也默认关闭 | admission / rejection / eviction 不应在 stats 关闭时记录 | `testStatsDisabledByDefaultSkipsPolicyCounters` |
| 开启后记录读写 | puts、requests、hits、misses、invalidations、removeAlls 可观测 | `testRecordStatsTracksNormalOperations` |

benchmarker 的 QPS、latency、hit rate、estimated size 是性能观测，不替代 `WTinyLFUStatsSnapshot` 的语义测试。

## 4.8 ARC / 生命周期边界

cache 持有内部 `EventLoopGroup`，长期实例替换、测试 tearDown、服务退出时应调用：

```swift
cache.shutdownGracefully { error in
    // observe shutdown result
}
```

`deinit` 只做 best-effort 非阻塞 cleanup，不应替代显式 shutdown。

| 约束 | 说明 | 覆盖测试 |
|---|---|---|
| 显式 shutdown 释放内部资源 | 测试 helper 均同步调用 `shutdownGracefully` | WTinyLFU 测试 helper `shutdown` / `shutdownCache` |
| removeAll 断链 | 清空后 node/deque/cache 不形成 ARC 保留环 | `testRemoveAllAndShutdownReleaseCachedObjects` |
| shutdown 后不写回 | 关闭后的 `getOrLoad` 只调用 loader，不存储对象 | `testShutdownGetOrLoadBypassesCacheAndUsesLoader` |

## 4.9 测试入口

```text
WTinyLFUCacheTests
WTinyLFUCacheStressTests
WTinyLFUInternalStructureTests
MagentCacheTests
```

`WTinyLFUInternalStructureTests` 和 `MagentCacheTests` 当前定义在 `Magent/Tests/Core/WTinyLFUCacheTests.swift` 内，不是单独文件。

本机验证命令使用 Xcode toolchain：

```bash
cd Magent
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=$PWD/.build/clang-module-cache \
swift test --filter WTinyLFUCache

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=$PWD/.build/clang-module-cache \
swift test --filter WTinyLFUInternalStructureTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=$PWD/.build/clang-module-cache \
swift test --filter MagentCacheTests
```

benchmark 归档见第 5 节。

## 4.10 降级与回退

可用方式：

- 将 `capacity` 配为 `0`，保留 loader bypass，但不存储对象。
- 业务侧绕过 cache，直接调用 resolver。
- 调用 `removeAll()` 清空当前 cache。
- 创建新 `MagentCache(capacity:)` 替换旧实例，并对旧实例调用 `shutdownGracefully`。

## 4.11 本次 review 修正点

| 旧文档问题 | 当前处理 |
|---|---|
| 表格写成 loader 注册到 cache 内部 | 改为调用点同步 loader |
| 残留早期 future / setLoader / single-flight 方案 | 从当前设计契约中删除 |
| 过度展开阶段计划和实现细节 | 压缩为 4C 产品设计结构 |
| 容量描述像严格同步上限 | 改为 transient overshoot + forced drain 收敛 |
| benchmark 说明分散 | 收敛到第 5 节 `Benchmarker` |
| 单独 README 与设计文档重复 | 删除 README，合并到本文档 |

---

# 5. Benchmarker

`WTinyLFUCacheBenchmark` 是当前 benchmarker executable target。

关键 phase：

```text
put, get-hit, get-hit-prebuilt-key, get-hit-concurrent-8-prebuilt-key,
get-miss, invalidate, getOrLoad-mixed, scan-hot-retention,
simple-lru-comparison, default-policy-validation
```

运行方式：

```bash
cd Magent
swift run WTinyLFUCacheBenchmark -- --quick --latency-samples=100
swift run -c release WTinyLFUCacheBenchmark -- --scenario=1m --latency-samples=1000
swift run -c release WTinyLFUCacheBenchmark -- --scenario=10m --latency-samples=10000
```

## 5.1 设备结果索引

| 日期 | 设备 | 芯片 / 核心 | 内存 | 系统 | 架构 | build | scenario | operations / phase | capacity | keyspace | scan |
|---|---|---|---:|---|---|---|---|---:|---:|---:|---:|
| 2026-07-02 | MacBookPro17,1 | Apple M1 / 8 cores | 16 GB | macOS 26.5.1 | arm64 | release | quick-smoke | 50,000 | 1,000 | 100,000 | 20% |
| 2026-07-22 | Mac15,10 | Apple M3 Max / 14 cores | 36 GB | macOS 26.5.2 | arm64 | release | 1m-keyspace-capacity-10k | 1,000,000 | 10,000 | 1,000,000 | 20% |
| 2026-07-22 | Mac15,10 | Apple M3 Max / 14 cores | 36 GB | macOS 26.5.2 | arm64 | release | 10m-keyspace-capacity-10k | 10,000,000 | 10,000 | 10,000,000 | 20% |

## 5.2 当前 quick-smoke 数据

命令：

```bash
swift run -c release WTinyLFUCacheBenchmark -- --quick --latency-samples=100
```

| 设备 | phase | avg ns/op | QPS | p50 ns | p95 ns | p99 ns | 关键结果 |
|---|---|---:|---:|---:|---:|---:|---|
| MacBookPro17,1 / M1 | put | 1,221.9 | 818,380/s | 750 | 1,333 | 4,000 | estimatedSize 1,000 |
| MacBookPro17,1 / M1 | get-hit | 671.4 | 1,489,455/s | 666 | 792 | 1,042 | hitRate 100.00% |
| MacBookPro17,1 / M1 | get-hit-prebuilt-key | 583.9 | 1,712,497/s | 583 | 625 | 667 | hitRate 100.00% |
| MacBookPro17,1 / M1 | get-hit-concurrent-8-prebuilt-key | 472.8 | 2,115,041/s | 0 | 0 | 0 | 8 threads, hitRate 100.00% |
| MacBookPro17,1 / M1 | get-miss | 319.1 | 3,133,470/s | 333 | 375 | 458 | missRate 100.00% |
| MacBookPro17,1 / M1 | invalidate | 220.0 | 4,544,491/s | 208 | 250 | 1,459 | removed 925 / 92.50% |
| MacBookPro17,1 / M1 | getOrLoad-mixed | 928.0 | 1,077,551/s | 708 | 1,500 | 1,791 | hitRate 78.21%, loaderCalls 10,897 |
| MacBookPro17,1 / M1 | scan-hot-retention | 800.4 | 1,249,375/s | 584 | 667 | 708 | hotHit 98.96%, hotSurvival 80.10% |
| MacBookPro17,1 / M1 | simple-lru-comparison | 780.1 | 1,281,824/s | 625 | 1,333 | 4,042 | WTiny hit 76.41%, LRU hit 69.81% |
| MacBookPro17,1 / M1 | default-policy-validation | 773.3 | 1,293,161/s | 625 | 1,167 | 1,458 | peak 1,023, final 1,000, hitRate 76.30% |

说明：

- `get-hit-concurrent-8-prebuilt-key` 当前没有单次 latency sample，latency 列为 benchmarker 的默认空样本输出。
- `simple-lru-comparison` 的 QPS 列记录 WTinyLFU 侧 QPS；同次运行的 simple LRU QPS 为 `1,942,470/s`。
- `scan-hot-retention` 同次运行记录 `scanWrites = 9,990`、`rejections = 9,412`、`evictions = 9,990`。
- 不同设备结果按同一表格追加，避免把单机数据误判为跨设备结论。

## 5.3 2026-07-22 M3 Max release 数据

运行命令：

```bash
swift run -c release WTinyLFUCacheBenchmark -- --scenario=1m --latency-samples=1000
swift run -c release WTinyLFUCacheBenchmark -- --scenario=10m --latency-samples=10000
```

本次结果是单次运行数据。`ops/s` 表示整个 phase 的吞吐量；
`get-hit-concurrent-8-prebuilt-key` 表示 8 个 worker 访问同一个 cache 的并发总吞吐，
不是固定 OS 线程或单 worker 吞吐。该并发 phase 不采集单操作 latency，因此延迟列记为 `—`。

### 5.3.1 1m-keyspace-capacity-10k

| phase | avg ns/op | ops/s | p50 ns | p95 ns | p99 ns | 关键结果 |
|---|---:|---:|---:|---:|---:|---|
| put | 897.9 | 1,113,726 | 500 | 709 | 1,750 | final size 10,000 |
| get-hit | 513.1 | 1,948,793 | 500 | 584 | 666 | hit rate 100.00% |
| get-hit-prebuilt-key | 506.7 | 1,973,719 | 500 | 584 | 667 | hit rate 100.00% |
| get-hit-concurrent-8-prebuilt-key | 599.1 | 1,669,242 | — | — | — | 8 workers, hit rate 100.00% |
| get-miss | 279.3 | 3,580,775 | 250 | 375 | 417 | miss rate 100.00% |
| invalidate | 171.5 | 5,831,108 | 166 | 209 | 291 | removed 9,467, ratio 94.67% |
| getOrLoad-mixed | 777.7 | 1,285,812 | 583 | 1,291 | 1,875 | hit rate 78.92%, loader calls 210,750 |
| scan-hot-retention | 703.1 | ≈1,422,273 | 500 | 625 | 709 | hot hit 99.12%, survival 80.53% |
| simple-lru-comparison | 692.8 | 1,443,322 | 500 | 1,083 | 4,500 | WTiny hit 77.76%, LRU 70.04% / 2,528,987 ops/s |
| default-policy-validation | 694.6 | ≈1,439,678 | 500 | 1,125 | 4,042 | peak 10,062, final 10,000, hit 77.74% |

### 5.3.2 10m-keyspace-capacity-10k

| phase | avg ns/op | ops/s | p50 ns | p95 ns | p99 ns | 关键结果 |
|---|---:|---:|---:|---:|---:|---|
| put | 865.2 | 1,155,842 | 459 | 667 | 1,083 | final size 10,000 |
| get-hit | 514.9 | 1,942,270 | 500 | 584 | 667 | hit rate 100.00% |
| get-hit-prebuilt-key | 493.6 | 2,025,734 | 459 | 583 | 667 | hit rate 100.00% |
| get-hit-concurrent-8-prebuilt-key | 624.5 | 1,601,299 | — | — | — | 8 workers, hit rate 100.00% |
| get-miss | 309.9 | 3,227,180 | 291 | 458 | 791 | miss rate 100.00% |
| invalidate | 154.5 | 6,472,225 | 125 | 167 | 209 | removed 9,832, ratio 98.32% |
| getOrLoad-mixed | 798.0 | 1,253,106 | 583 | 1,333 | 2,083 | hit rate 79.30%, loader calls 2,070,078 |
| scan-hot-retention | 753.6 | ≈1,327,034 | 500 | 667 | 792 | hot hit 98.80%, survival 79.89% |
| simple-lru-comparison | 748.5 | 1,335,959 | 542 | 1,125 | 1,875 | WTiny hit 79.19%, LRU 70.41% / 2,436,300 ops/s |
| default-policy-validation | 761.2 | ≈1,313,767 | 542 | 1,125 | 1,792 | peak 10,069, final 10,000, hit 79.19% |

说明：

- `scan-hot-retention` 和 `default-policy-validation` 的 `ops/s` 由 benchmark 输出的
  `operations / elapsedSeconds` 计算，因此使用近似符号；其余吞吐取自 phase 的命名 QPS 字段。
- 两个场景的最终 size 都收敛到 10,000，peak 分别为 10,062 和 10,069，未超过
  `2 * capacity = 20,000` 的 transient hard bound。
- 预构造 key 的单线程纯命中吞吐在两个场景中分别为 1.97M 和 2.03M ops/s；
  8-worker 共享 cache 并发总吞吐分别为 1.67M 和 1.60M ops/s。
- W-TinyLFU 在 comparison workload 中的命中率分别比 simple LRU 高 7.72 和 8.78 个百分点，
  但 simple LRU 的吞吐更高；这里体现的是命中质量与策略维护成本之间的权衡。

## 5.4 设计结论

`WTinyLFUCache` 当前产品设计是一个同步调用、内部异步维护的本地内存 loading cache：

```text
public path:
  get / getOrLoad / put / invalidate / removeAll

internal path:
  map + buffers + policy maintenance

policy:
  Window LRU + TinyLFU Admission + Main SLRU
```

公开 API 保持窄边界：只暴露 `capacity`、同步 loader、基础 CRUD、stats snapshot 和 shutdown。业务 key、业务 value、版本隔离、异步加载、错误语义和指标上报都留在调用方。
