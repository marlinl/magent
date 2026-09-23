# MagentCache Benchmark

归档日期：2026-09-22。

本文集中记录缓存性能测量的入口、方法与结果。第 1–4 节保留原缓存实现的
2026-07-02、2026-07-22 性能记录，数据未重新测量；第 5 节定义目标版本的测量范围，尚无实测结果。
原始内容可通过 `git show ec3cad4:Magent/docs/WTiny_LFU_Cache_Design.md` 追溯。
这些数值不能作为新版 MagentCache 设计的性能或验收证据；旧统计接口和容量语义也不代表新设计。

相关文档：[MagentCache 产品设计](../design/MagentCache_Design.md) · [架构索引](../ARCHITECTURE.md)。
测量约束：[W-TinyLFU Cache SPEC](../W-TinyLFU_CACHE_SPCE.md)。

## 1. 运行入口与统计口径

`WTinyLFUCacheBenchmark` 是这些记录使用的 benchmark 入口。以下保留历史设备、命令和原始结果；旧 stats 字段不保证当前 executable 仍然输出，运行入口应以实际 Package.swift 为准。

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

## 2. 设备结果索引

| 日期 | 设备 | 芯片 / 核心 | 内存 | 系统 | 架构 | build | scenario | operations / phase | capacity | keyspace | scan |
|---|---|---|---:|---|---|---|---|---:|---:|---:|---:|
| 2026-07-02 | MacBookPro17,1 | Apple M1 / 8 cores | 16 GB | macOS 26.5.1 | arm64 | release | quick-smoke | 50,000 | 1,000 | 100,000 | 20% |
| 2026-07-22 | Mac15,10 | Apple M3 Max / 14 cores | 36 GB | macOS 26.5.2 | arm64 | release | 1m-keyspace-capacity-10k | 1,000,000 | 10,000 | 1,000,000 | 20% |
| 2026-07-22 | Mac15,10 | Apple M3 Max / 14 cores | 36 GB | macOS 26.5.2 | arm64 | release | 10m-keyspace-capacity-10k | 10,000,000 | 10,000 | 10,000,000 | 20% |

## 3. 2026-07-02 quick-smoke 历史数据

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

## 4. 2026-07-22 M3 Max release 数据

运行命令：

```bash
swift run -c release WTinyLFUCacheBenchmark -- --scenario=1m --latency-samples=1000
swift run -c release WTinyLFUCacheBenchmark -- --scenario=10m --latency-samples=10000
```

本次结果是单次运行数据。`ops/s` 表示整个 phase 的吞吐量；
`get-hit-concurrent-8-prebuilt-key` 表示 8 个 worker 访问同一个 cache 的并发总吞吐，
不是固定 OS 线程或单 worker 吞吐。该并发 phase 不采集单操作 latency，因此延迟列记为 `—`。

### 4.1 1m-keyspace-capacity-10k

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

### 4.2 10m-keyspace-capacity-10k

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

## 5. 目标版本的测量范围

目标版本尚未完成实现与测量。本节是后续测量要求，不能把上面的历史结果视为达标证据。

### 5.1 入口与复现信息

现有入口为 [WTinyLFUCacheBenchmark.swift](../../Tests/Core/WTinyLFUCacheBenchmark.swift)，
可执行目标仍名为 `WTinyLFUCacheBenchmark`。实现迁移后，benchmark 应通过同一个生产
`MagentCache` 入口调用，并同步更新命令与参数说明；不得为测量增加只供测试的生产 API。

每次记录实现 commit、工作树状态、完整命令、Swift/Xcode 版本、设备与系统、构建模式、
容量、有效期、key/value 大小、请求分布、随机种子、并发度、预热和重复次数。
保留原始输出，说明延迟采样方式；未采样的指标标记为未测，不把零当作测量结果。

### 5.2 场景与指标

覆盖稳定热点、均匀随机、一次性扫描、热点迁移、写密集、TTL 批量到期，以及同 key 和不同 key
的并发访问。分别测量缓存操作和 Core 本地规则匹配调用链，避免把 loader 的业务耗时计为纯缓存成本。

报告吞吐、p50/p95/p99 延迟、命中率、loader 调用数、驻留数量和内存占用。
同时记录单次维护或成批清理造成的延迟峰值；区分缓存元数据与 key/value 对象的内存成本。
对比测试采用相同容量、有效期、负载、并发度与计时口径，并明确不同实现的契约差异。

### 5.3 结论边界

严格容量、同步策略维护和完整请求计数都可能增加并发竞争或单次操作耗时。
应重点测量频率统计衰减、批量到期回收和竞争下的尾延迟，再判断是否适合 Core 的 EventLoop 调用路径。
平均吞吐不能证明单次操作具有固定耗时，缓存操作数据也不能替代代理服务的端到端测量。

SPEC 的功能验收与性能测量分别记录。性能结果不放宽容量、失效、关闭或错误传播契约；
如确需改变契约，应先修订 SPEC，再更新设计及测量基线。
