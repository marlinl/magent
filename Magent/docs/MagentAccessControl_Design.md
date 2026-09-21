---
desc: Magent当前规则模型、运行周期路由、节点选择与决策缓存
updated_at: 2026-09-21
baseline: current-working-tree
---

# Magent 路由与访问控制设计

## 0. 文档目标

本文以当前 [MagentCore.swift](../Sources/Core/MagentCore.swift)、
[ProxyRule.swift](../Sources/Model/ProxyRule.swift) 和 [Magent.swift](../Sources/Magent.swift) 为准。
文件名沿用旧访问控制文档；当前实现是运行周期独有的 `MagentCore` 和文件内私有 `MagentRouter`。
第 5 节单独保留旧 matcher 的 benchmark，不代表当前代码性能。

# 1. Context

## 1.1 所有权与入口

```text
App 构造 MagentConfig(rules, proxyNodes, defaultDecision)
  -> Magent.start / restart
  -> 当前运行周期独有的 MagentCore
       -> 初始化 MagentRouter
       -> 装载节点与 UDP Wire
       -> 校验默认代理节点
  -> Connection 解析 NetworkAddress
  -> Core.routeTCPWire / routeUDPWire
       -> route cache / router.match / defaultDecision
       -> nil（direct）或具体 Wire（proxy）
```

App 使用 `ProxyRule` 构造规则，不存在公开的规则热刷新接口。`restart` 创建新 Core、路由表和缓存，
复用服务拥有的 EventLoopGroup，并关闭旧运行周期的连接。运行期间修改原配置值不会改变现有 Core。

Router 只匹配目标并返回可选 `Decision`；Core 再应用默认决策、查找节点和选择 Wire。
本地 HTTP/SOCKS 解析由 Connection 负责，远端协议编码由 Wire 负责。

## 1.2 范围

支持 exact domain、domain suffix、domain keyword 和 IPv4/IPv6 CIDR。
输入只有地址及端口，没有 URL path、TLS 内容或客户端身份。当前规则不匹配端口，也不执行 DNS 查询。
这里的访问控制表示目标路由策略，不提供来源 ACL、认证或独立的 deny 决策。

# 2. Contract

## 2.1 规则模型与校验

`ProxyRule(matchType:matchValue:decision:order:)` 是抛错初始化方法。字段为只读值：

| 字段 | 契约 |
| --- | --- |
| `matchType` | `MatchType` |
| `matchValue` | 已按匹配类型规范化的字符串 |
| `decision` | `.direct` 或 `.proxy(UUID)` |
| `order` | 越小优先级越高 |

| 匹配类型 | 规范化与运行行为 |
| --- | --- |
| `exactDomain` | trim、小写、去首尾点，校验 ASCII 域名标签；规范化后完整匹配 |
| `domainSuffix` | 同上；匹配自身域名及标签边界上的子域名 |
| `domainKeyword` | trim 后小写，禁止空值；对规范化域名做包含判断 |
| `ipCIDR` | 校验 IPv4/IPv6 和前缀，清除主机位；省略前缀时使用 /32 或 /128 |
| `urlRegex` | 构造规则时校验正则语法，但 Router 初始化拒绝此类型 |

无效规则抛 `invalidPolicy`，不会由 package 静默忽略。
`.domain` 只参与域名匹配；`.ipv4` / `.ipv6` 只参与 CIDR 匹配。
将数字 IP 文本手动放入 `.domain` 不会自动改走 CIDR；HTTP 前端会把合法数字 IP 目标解析为对应 IP 类型。

## 2.2 去重和优先级

以 `matchType + normalized matchValue` 为身份，重复身份采用最后一条配置及其数组位置。
所有实际命中都通过同一顺序比较：

1. `order` 较小。
2. specificity 较高。
3. 初始化数组位置较早。

| 类型 | specificity |
| --- | --- |
| exact domain | `4000 + matchValue.utf8.count` |
| domain suffix | `3000 + 标签数量` |
| IP CIDR | `2000 + 前缀长度` |
| domain keyword | `1000 + matchValue.utf8.count` |

IP 和域名走不同的匹配分支。不能用索引遍历顺序代替以上优先级，也不能命中 exact 后直接返回而忽略更小 order 的后缀或关键字。

## 2.3 决策与节点

| 条件 | 行为 |
| --- | --- |
| 规则为空或未命中 | 使用 `defaultDecision` |
| `.direct` | route 方法返回 `nil`，Connection 直连目标 |
| 默认 `.proxy(UUID)` 缺失节点 | Core 初始化失败；start/restart 在绑定新 listener 前报错 |
| 规则 `.proxy(UUID)` 缺失节点 | 使用该路由时抛 `proxyNodeNotFound`，不会回退直连 |
| proxy TCP | 每次创建独立 `ShadowsocksTCPWire`，隔离流状态 |
| proxy UDP | 按 UUID 取得已初始化的 UDP Wire，每个 packet 独立加密 |

`putAllProxyNodes` 是内部初始化路径，不是 public 热更新 API。同 UUID 按输入顺序覆盖，
更新地址时移除旧 endpoint 映射；不同 UUID 复用同一 `SocketAddress` 会报错。
检查按批次遍历顺序进行，不承诺对互换 endpoint 等配置做事务式重排。

## 2.4 缓存

Core 使用 `MagentCache<Decision>`，规则非空时 capacity 为 4096，空规则时为 0，默认不过期。
缓存同时可保存规则结果和未命中后的默认决策，不保存 Wire 或节点对象。

| 地址类型 | key |
| --- | --- |
| domain | `domain:` 加 host 小写值 |
| IPv4 | `ipv4:` 加原始字节的 Base64 |
| IPv6 | `ipv6:` 加原始字节的 Base64 |

key 不含端口。domain cache key 只做小写，Router 匹配时还会 trim 和去首尾点；
因此不同文本可能语义等价但占用不同 cache entry，不应宣称缓存 key 完全规范化。
restart 使用新 Core 的新缓存，不需要对旧缓存做热刷新或版本快照交换。

# 3. Core Logic

## 3.1 索引与匹配

| 类型 | 当前结构与查询方式 |
| --- | --- |
| exact domain | Dictionary，按规范化完整域名查询 |
| domain suffix | Dictionary，逐次移除最左标签并查询后缀 |
| domain keyword | Dictionary，遍历关键字并调用 `contains` |
| IPv4/IPv6 CIDR | Dictionary，遍历 `NetworkCIDR` 并比较前缀字节 |

精确和后缀查询依赖哈希表；不能据此声称最坏情况恒定耗时。
keyword 和 CIDR 查询随对应规则数量增长，后缀还涉及子串构造和哈希。
当前没有 Aho-Corasick、CIDR trie、正则 fallback 或 `bestPossible` 提前退出。
旧实现的算法和 benchmark 不能用于保证当前最坏情况吞吐。

## 3.2 TCP / UDP 路由

```text
routeDecision(address)
  -> cache hit: Decision
  -> cache miss: router.match(address) ?? defaultDecision
  -> 尝试写入缓存

routeTCPWire / routeUDPWire
  -> direct: nil
  -> proxy: 按 UUID 查节点 / Wire，缺失则报错
```

一个 TCP 连接只进行一次路由和 Wire 选择；该 Wire 同时确定拨号 endpoint 与协议流状态。
UDP 对每个客户端 datagram 独立路由，association 记录真实出站 endpoint 及所选 Wire 用于回包。

# 4. Corners

## 4.1 并发与生命周期

`Magent` actor 串行化生命周期方法；Core 的规则表初始化后不变，节点装载发生在发布给连接之前。
路由缓存内部处理并发访问，TCP Wire 不跨连接共享。这里没有运行中替换规则快照的并发模型。

## 4.2 当前测试与验证入口

现有 [MagentCoreTests](../Tests/Core/MagentCoreTests.swift) 覆盖：

- `testDefaultProxyDecisionHandlesEmptyAndUnmatchedRules`。
- `testInitThrowsWhenDefaultProxyNodeIsMissing`。
- `testTCPProxyRouteThrowsWhenNodeIsMissing` / `testUDPProxyRouteThrowsWhenNodeIsMissing`。
- `testDomainRulesUseOrderBeforeSpecificity` / `testDomainRulesUseSpecificityWhenOrderMatches`。
- `testDuplicateNormalizedRuleUsesLastValue`。
- `testCIDRMatchesIPv4AndIPv6` / `testUnsupportedRuleFailsCoreInitialization`。
- 节点重复 ID 覆盖、重复 endpoint 拒绝，以及单 EventLoop 建连。

在 package 根目录执行：

```bash
swift test --filter MagentCoreTests
```

列出测试表示源码中存在相应断言，不表示本次文档更新已执行测试，也不证明穷尽所有规则组合。

# 5. 旧 matcher benchmark 归档

以下为 2026-06-25 的历史数据，属于已替换的 `MagentAccessControl` matcher。
历史 `MagentAccessControlBenchmark.swift` 源文件和 executable target 均已不在当前 package，
不能运行旧命令复测，也不能将这些数据解释为当前 `MagentRouter` 的性能。
本节出现的优化点、类型和结论只描述当时版本。

历史运行配置：
```text
durationPerScenario = 10s
warmupRequests = 2000
hitRate = 85%
build = release
date = 2026-06-25
```

优化点：

- matcher 维护每个 phase 的 `bestPossible`。
- 当前命中已无法被后续 phase 打败时提前返回。
- 正则规则按策略优先级排序。
- 正则匹配到不可被后续规则打败的规则后停止。

### 阶段构建与 warmup 耗时

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

### Match 场景结果

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

结论：`exactDomain`、`domainSuffix`、`domainKeyword`、`ipCIDR` 在无缓存下都是微秒级；`urlRegex` 仍随规则数线性放大，是访问控制匹配的主要热点。历史数据中，1,000 条正则规则的 1000 qps 等价场景 p99 从优化前的 `1.16ms` 降到 `779.79us`。
