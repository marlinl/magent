# 规则匹配与缓存压力测试（Match Benchmark）

## 场景与测试范围

本场景测量同一条规则匹配与缓存调用链的吞吐和延迟。`exactDomain`、`domainSuffix`、`domainKeyword`、`ipCIDR`、`urlRegex` 是该压力测试的五个匹配维度，与规则数量、请求数量一样作为参数列记录，统一保存在本文件。

本文收录从 `MagentAccessControl_Design.md` 迁移的 **2026-06-25 旧 matcher 历史数据**，包含 10 条构建/warmup 结果和 20 条 Match 结果，原值及单位不变。迁移日期为 2026-09-22，本次没有重新运行 benchmark；数据不代表当前 `MagentRouter` 的性能。

可追溯参考源码的调用链：

```text
预生成规则和请求 → warmup
→ 顺序 await MagentAccessControl.match(address)
→ cachedPolicyPhase → cache.getOrLoad
   ├─ cache hit：返回缓存决策
   └─ cache miss：执行规则匹配并缓存结果
→ 记录调用延迟、决策数和整个循环吞吐
```

该参考路径包含缓存，不能把各匹配类型的结果当作独立的纯算法耗时。原实测的缓存配置缺少完整记录，证据差异见[缓存状态与历史结论](#缓存状态与历史结论)。测量不包含 DNS、连接建立、Wire 加密或网络端到端转发。

## 测试入口与运行环境

| 项目 | 记录 |
|---|---|
| 场景 / 记录 ID | 规则匹配与缓存压力测试 / `match-cache-2026-06-25` |
| 运行日期 / 构建模式 | 2026-06-25 / release，来自原结果记录 |
| 被测实现 | 已替换的 MagentAccessControl matcher |
| benchmark 源文件 | 历史 `Tests/Core/MagentAccessControlBenchmark.swift`；当前已删除，详见[源码追溯](#历史来源与可复现边界) |
| benchmark 入口 | 参考源码的 `runPhaseBench` → `runScenario`；@main 可执行程序，不是 XCTest 方法 |
| 实测 commit / 工作树状态 | 未记录 |
| 参考源码 commit | `1113e1635db24f751c7c94e992505f160450d4ac`（2026-07-02）；不能替代实测版本 |
| 设备型号 | 未记录 |
| 芯片 / CPU 核心数 | 未记录 |
| 内存 | 未记录 |
| 操作系统 / CPU 架构 | 未记录 |
| Swift / Xcode 版本 | 未记录；不能使用 Package 的 tools-version 代替 |
| 电源 / 温控 / 后台负载 | 未记录 |
| 匹配类型 | exactDomain、domainSuffix、domainKeyword、ipCIDR、urlRegex |
| 规则规模 | 100、1,000 |
| 请求量配置 | durationPerScenario=10s，Target QPS 100 / 1000，对应 1,000 / 10,000 次调用 |
| 预热 | warmupRequests=2000；参考源码按 90% 命中概率生成预热请求 |
| 测量负载 | hitRate=85%，表示生成概率；实际规则命中率未记录 |
| pacing / 并发 | 参考源码默认不 pacing，并顺序 await；完整实测命令未记录 |
| seed | 实测值未记录；参考源码默认为 `0x1234_5678` |
| 缓存 | 参考源码容量 4096；实测开关、冷/热状态及命中率未记录 |
| 原始日志 / 重复次数 | 原归档未附日志；重复次数和误差范围未记录 |

设备信息统一记录一次；不使用当前机器或另一批 W-TinyLFU 测试的设备信息补写历史环境。

## Benchmark 样例与参数维度

以下为参考源码中 index=7 的规则和命中请求样例，不是原始运行日志采样：

| 匹配维度 | 规则样例 | 命中请求样例 | 负载边界 |
|---|---|---|---|
| exactDomain | `exact-7.bench.test` | `exact-7.bench.test:443` | 生成的完整域名，不覆盖混合类型竞争 |
| domainSuffix | `suffix-7.bench.test` | `api.suffix-7.bench.test:443` | 固定子域名深度，不覆盖任意深度的后缀 |
| domainKeyword | `keyword-7` | `service-keyword-7.bench.test:443` | 关键字可能重叠，例如 keyword-7 也是 keyword-70 的子串 |
| ipCIDR | `10.0.7.0/24` | `10.0.7.1:443` | 命中请求只有 IPv4 /24，不含 IPv6 或其他前缀的独立测量 |
| urlRegex | `^regex-7\.bench\.test(:443)?$` | `regex-7.bench.test:443` | 只匹配 host / host:port，不是完整 URL path |

所有维度的 miss 分支都生成 `miss-<index>-<random>.bench.invalid:443`，因此 ipCIDR 的 miss 也不是网段外 IPv4。规则动作按 65% 概率选择 proxy，否则 direct；proxy/direct 返回比例不等同于规则命中率。当前记录没有并发、多类型混合或对抗性输入测量。

## 指标与统计口径

| 项目 | 含义与边界 |
|---|---|
| phase | 同一压力测试中的匹配类型维度；没有 mixed / mixed-no-regex / mixed-compare 结果 |
| Rules | 100 或 1,000；同一 phase 只生成该类型的规则 |
| Target QPS | 100 或 1000，用于计算等价请求数量，不是本表实测服务吞吐 |
| durationPerScenario | 原记录为 10s；参考程序按 `round(Target QPS × duration)` 计算 Operations，不强制测量循环跑满 10 秒 |
| pacing | 参考源码默认关闭；没有完整原始命令。表中的 Match Loop 也远短于 10 秒 |
| Policy Generation | 生成规则数组的时间 |
| Service Compile | 获取服务并 refreshPolicies / 编译索引的时间，不是编译 Swift 程序 |
| Warmup | 原记录为 2,000 次；参考源码的生成命中概率为 90%，每个规则规模/phase 一次，随后依次运行 100、1000 QPS 参数行 |
| hitRate | 测量负载生成概率为 85%；实际规则命中率未记录，不能等同于 proxy 返回比例 |
| Match Loop | 预生成请求之后顺序 await match 的整段耗时，含逐次计时、记录和决策计数；不含构建、预热或请求数组生成 |
| Actual QPS | Operations 除以未取整的 Match Loop 秒数 |
| Avg | 每次 match 耗时的算术平均，不等同于 Match Loop / Operations |
| p90 / p95 / p99 | 参考程序记录每次调用，排序后取 `ceil(p × N) - 1` 位置；不是重复运行均值的置信区间 |
| 测量范围 | 进程内旧 matcher 调用，不涉及 DNS、拨号、Wire 加密或网络端到端请求 |

Service Compile 不代表 Swift 编译耗时。每个规则规模/匹配类型只记录一次 warmup，不能解释为每条 Target QPS 参数行都做了独立预热。显示时间已四舍五入，不能用显示值重算并覆盖原 Actual QPS。

## 阶段构建与 warmup 耗时

| Phase | Rules | Policy Generation | Service Compile | Warmup |
|---|---:|---:|---:|---:|
| `exactDomain` | 100 | 67.08us | 1.44ms | 5.81ms |
| `domainSuffix` | 100 | 17.00us | 699.54us | 7.59ms |
| `domainKeyword` | 100 | 6.50us | 478.83us | 13.73ms |
| `ipCIDR` | 100 | 19.83us | 529.62us | 8.48ms |
| `urlRegex` | 100 | 132.96us | 1.70ms | 91.62ms |
| `exactDomain` | 1,000 | 135.54us | 1.55ms | 4.35ms |
| `domainSuffix` | 1,000 | 139.33us | 3.15ms | 7.33ms |
| `domainKeyword` | 1,000 | 48.29us | 1.46ms | 14.07ms |
| `ipCIDR` | 1,000 | 179.17us | 2.12ms | 8.45ms |
| `urlRegex` | 1,000 | 1.07ms | 3.72ms | 801.73ms |

## Match 场景结果

| Phase | Rules | Target QPS | Operations | Match Loop | Actual QPS | Avg | p90 | p95 | p99 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `exactDomain` | 100 | 100 | 1,000 | 2.53ms | 395217.86/s | 2.48us | 2.75us | 2.92us | 2.96us |
| `exactDomain` | 100 | 1000 | 10,000 | 22.36ms | 447137.20/s | 2.19us | 2.46us | 2.58us | 2.83us |
| `domainSuffix` | 100 | 100 | 1,000 | 3.58ms | 279030.78/s | 3.54us | 3.58us | 3.62us | 3.79us |
| `domainSuffix` | 100 | 1000 | 10,000 | 35.59ms | 280996.89/s | 3.52us | 3.62us | 3.67us | 3.83us |
| `domainKeyword` | 100 | 100 | 1,000 | 6.84ms | 146125.85/s | 6.81us | 8.21us | 8.33us | 8.67us |
| `domainKeyword` | 100 | 1000 | 10,000 | 68.46ms | 146064.21/s | 6.80us | 8.33us | 8.50us | 8.71us |
| `ipCIDR` | 100 | 100 | 1,000 | 4.07ms | 245433.95/s | 4.04us | 4.38us | 4.46us | 4.67us |
| `ipCIDR` | 100 | 1000 | 10,000 | 39.96ms | 250241.90/s | 3.96us | 4.33us | 4.38us | 4.50us |
| `urlRegex` | 100 | 100 | 1,000 | 48.08ms | 20799.12/s | 48.00us | 78.17us | 78.67us | 81.08us |
| `urlRegex` | 100 | 1000 | 10,000 | 478.22ms | 20910.67/s | 47.73us | 78.58us | 79.67us | 82.88us |
| `exactDomain` | 1,000 | 100 | 1,000 | 2.09ms | 478459.51/s | 2.05us | 2.29us | 2.33us | 2.38us |
| `exactDomain` | 1,000 | 1000 | 10,000 | 21.63ms | 462274.56/s | 2.11us | 2.38us | 2.46us | 2.58us |
| `domainSuffix` | 1,000 | 100 | 1,000 | 3.47ms | 288579.47/s | 3.42us | 3.50us | 3.54us | 3.62us |
| `domainSuffix` | 1,000 | 1000 | 10,000 | 35.03ms | 285448.88/s | 3.45us | 3.58us | 3.62us | 3.75us |
| `domainKeyword` | 1,000 | 100 | 1,000 | 6.97ms | 143538.95/s | 6.93us | 8.08us | 8.21us | 8.46us |
| `domainKeyword` | 1,000 | 1000 | 10,000 | 71.52ms | 139825.75/s | 7.10us | 8.38us | 8.62us | 8.96us |
| `ipCIDR` | 1,000 | 100 | 1,000 | 4.01ms | 249519.11/s | 3.97us | 4.33us | 4.38us | 4.58us |
| `ipCIDR` | 1,000 | 1000 | 10,000 | 40.04ms | 249736.48/s | 3.97us | 4.33us | 4.38us | 4.58us |
| `urlRegex` | 1,000 | 100 | 1,000 | 427.37ms | 2339.91/s | 427.28us | 744.42us | 753.58us | 766.33us |
| `urlRegex` | 1,000 | 1000 | 10,000 | 4393.26ms | 2276.21/s | 439.24us | 741.38us | 753.21us | 779.79us |

## 缓存状态与历史结论

旧文档将结果称为“无缓存”，benchmark 顶部注释也说默认关闭缓存。但可追溯源码调用 `MagentAccessControl.shared`，同版 matcher 的默认容量是 4096，`match` 进入 `cachedPolicyPhase` / `cache.getOrLoad`，runner 没有禁用缓存入口。加上缺少实测 commit，**实际测量是否禁用缓存无法确认**，也不能反向断言这批数据一定开启了缓存。

因此保留原始结果，但不继续把“无缓存微秒级”作为经过核验的结论。参考源码没有在两条 QPS 参数行之间刷新 service，缓存若开启，预热和先前参数行的访问还会影响后续结果。后续复测必须明确 cache off / cold / warm，分别记录。

原归档的优化背景保留为历史说明：各 phase 的 `bestPossible`、无法被后续 phase 击败时提前返回、正则按优先级排序、正则命中后提前停止。原文还记录：1,000 条正则规则、Target QPS 1000 的 p99 从优化前 `1.16ms` 降至 `779.79us`；优化前的完整结果、设备及对应源码版本未记录。两档规则规模和缺少优化前完整记录，不足以证明严格线性复杂度或可复现的优化收益。

当前 MagentRouter 已采用不同的索引实现，并在初始化时拒绝 urlRegex。上述数字仅描述旧 matcher 的记录，不能证明当前吞吐、缓存命中率或最坏情况上界。

## 历史来源与可复现边界


| 证据 | 位置 / 标识 |
|---|---|
| 原始结果记录 | `31ea88cb864d4468224234f8ed0620da0a1eb190:Magent/docs/MagentAccessControl_Design.md` 的旧 matcher benchmark 归档；文中记载运行日期 2026-06-25 |
| 可追溯 benchmark 源文件 | `1113e1635db24f751c7c94e992505f160450d4ac:Magent/Tests/Core/MagentAccessControlBenchmark.swift` |
| benchmark 文件 Git blob | `b4ae35af7427fc07155b5e50676bc44e081febb3` |
| 同版被测实现 | `1113e1635db24f751c7c94e992505f160450d4ac:Magent/Sources/Core/MagentAccessControl.swift` |
| matcher 文件 Git blob | `01fb2a8e9a28021ea84c46ab7ff914155777bf85` |
| 同版 Package | `1113e1635db24f751c7c94e992505f160450d4ac:Magent/Package.swift`，未声明对应 executable target |
| 当前功能测试 | [MagentCoreTests.swift](../../Tests/Core/MagentCoreTests.swift)，不是上述性能结果的来源 |
| 当前实现 | [MagentCore.swift](../../Sources/Core/MagentCore.swift) 内的私有 MagentRouter，已经替换旧 matcher |
| 当前 target 配置 | [Package.swift](../../Package.swift)，仍无旧 Match benchmark target |

可在仓库中只读查看历史证据：

```bash
git show 31ea88cb864d4468224234f8ed0620da0a1eb190:Magent/docs/MagentAccessControl_Design.md
git show 1113e1635db24f751c7c94e992505f160450d4ac:Magent/Tests/Core/MagentAccessControlBenchmark.swift
git show 1113e1635db24f751c7c94e992505f160450d4ac:Magent/Sources/Core/MagentAccessControl.swift
git show 1113e1635db24f751c7c94e992505f160450d4ac:Magent/Package.swift
```

2026-07-02 的参考源码比文中运行日期晚，不能当作数据生成时的 commit。它可解释场景生成和计时方法，无法证明原运行采用完全相同的代码或参数。历史源码虽然位于 Tests 下，入口是 `@main` 可执行程序，不是 `swift test` 的 XCTest 性能方法。

当前包和该参考版本的 manifest 均未声明可运行的 MagentAccessControlBenchmark target。恢复旧文件还涉及 internal API 可见性，不能直接执行旧 target 名称复测；本次没有恢复源码或新增 target。

当前 [MagentCoreTests.swift](../../Tests/Core/MagentCoreTests.swift) 中相关的是功能断言，不是本表的 benchmark 来源：

| 匹配维度 | 相关测试 |
|---|---|
| exactDomain | `testDomainRulesUseSpecificityWhenOrderMatches`、`testDuplicateNormalizedRuleUsesLastValue` |
| domainSuffix | `testDomainRulesUseOrderBeforeSpecificity`、`testDomainRulesUseSpecificityWhenOrderMatches` |
| domainKeyword | 当前该文件没有独立的该维度用例 |
| ipCIDR | `testCIDRMatchesIPv4AndIPv6`；功能测试含 IPv6，不等于历史性能数据测过 IPv6 |
| urlRegex | `testUnsupportedRuleFailsCoreInitialization`，验证当前拒绝该类型 |

## 后续记录方式

本场景的新测试仍追加到同一文档，按运行日期或版本区分记录。每次统一标注 benchmark 文件与入口、完整命令、commit/工作树、设备/系统/工具链、规则和请求生成参数、seed、并发度、pacing、cache off/cold/warm 与容量、预热方式、计时与采样方法、重复轮数、原始日志和正确性断言结果。

同一轮中的匹配类型、规则规模、命中率和缓存配置作为结果表的维度；有独立目的和测量入口的其他压力测试，再建立另一份 Markdown。

返回：[架构与文档索引](../ARCHITECTURE.md) · [路由与访问控制设计](../MagentAccessControl_Design.md)。
