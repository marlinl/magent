# MagentAccessControl 产品设计文档

## 0. 文档目标

本文档使用 4C 法则组织 `MagentAccessControl` 的产品设计，并以当前代码为基线：

```text
Magent/Sources/Core/MagentAccessControl.swift
Magent/Sources/AccessControlPolicy.swift
Magent/Sources/Core/CoreService.swift
Magent/Sources/MagentClient.swift
```

- Context：服务定位、目标和非目标
- Contract：策略模型、刷新、匹配、缓存和调用边界
- Core Logic：规则编译、索引、优先级、缓存和匹配流程
- Corners：边界场景、测试覆盖、benchmark 和当前缺口

`MagentAccessControl` 是 Core 内部访问控制匹配服务，不是 public API。App 侧通过 `MagentClient.putAcl(_:)` 写入 `[AccessControlPolicy]`，Core 出站流程通过 `CoreService` 调用该服务完成目标地址到 `Decision` 的匹配。

---

# 1. Context

## 1.1 产品定位

`MagentAccessControl` 是进程内单例访问控制服务：

```text
MagentClient.putAcl([AccessControlPolicy])
  -> CoreService.shared.refreshAccessControlPolicies
  -> MagentAccessControl.refreshPolicies
  -> compile immutable Rules snapshot
  -> MagentClient 请求 CoreService.getDecision(NetworkAddress)
  -> CoreService 内部调用 MagentAccessControl.match(NetworkAddress)
  -> 需要代理时通过 CoreService.getProxyNode(UUID) 查询节点
  -> Decision.direct / Decision.proxy(UUID)
```

它只负责把 `NetworkAddress` 匹配到 `Decision`。它不解析 SOCKS/HTTP、不持有代理节点表、不创建 Wire，也不发起网络连接。

## 1.2 设计目标

| 目标 | 说明 |
|---|---|
| 单例所有权 | `MagentClient` 只持有 `CoreService.shared`；规则快照和匹配缓存由 Core 内部的 `MagentAccessControl` 集中承载 |
| 刷新明确 | 全量刷新替换规则快照并清空匹配缓存 |
| 热路径稳定 | `match` 只读取编译后的不可变 `Rules` 快照 |
| 匹配可扩展 | 按 rule type 编译成不同索引，避免所有规则线性扫描 |
| 优先级统一 | 所有 phase 命中都通过同一 `order -> specificity -> sequence` 裁决 |
| 缓存热点 | 使用 `MagentCache` 缓存 target 到策略的结果 |
| Regex 可控 | `urlRegex` 作为最后 fallback，按优先级排序并支持提前停止 |

## 1.3 非目标

`MagentAccessControl` 不负责：

- 解析本地代理协议。
- 解析 URL path 或 TLS 内部内容。
- 管理 `ProxyNode` 表。
- 选择或创建 Shadowsocks / Direct wire。
- 执行 DNS 解析。
- 作为 public API 暴露给 App。
- 为每个连接保存业务状态。
- 在匹配失败时抛错；未命中规则时返回 `.direct`。

---

# 2. Contract

## 2.1 可见性与入口

当前类型是 internal singleton：

```swift
internal final class MagentAccessControl {
    internal static let shared = MagentAccessControl()
    private init()
}
```

公开到 App 的入口在 `MagentClient`：

```swift
public func putAcl(_ policies: [AccessControlPolicy]) {
    coreService.refreshAccessControlPolicies(policies)
}
```

Core 内部调用入口：

```swift
internal func getDecision(_ target: NetworkAddress) async -> Decision
internal func getProxyNode(_ id: UUID) -> ProxyNode?
```

`MagentClient` 根据 `Decision` 决定后续 wire：

| `Decision` | 出站 flow 行为 |
|---|---|
| `.direct` | 使用原始 target 和 `DirectNodeWire()` |
| `.proxy(UUID)` | 通过 `CoreService.getProxyNode(_:)` 读取 `ProxyNode`，再构造对应 `ProxyNodeWire` |

## 2.2 策略模型

```swift
public struct AccessControlPolicy: Sendable {
    public var matchType: MatchType
    public var matchValue: String
    public var decision: Decision
    public var order: Int
}
```

`MatchType` 当前支持：

| 类型 | 当前语义 | 索引 |
|---|---|---|
| `exactDomain` | 完整 host 精确匹配 | `HashSet<String>` |
| `domainSuffix` | 域名后缀匹配 | 反向 label trie |
| `domainKeyword` | host 关键字匹配 | Aho-Corasick 自动机 |
| `ipCIDR` | IPv4 / IPv6 CIDR 匹配 | bit trie |
| `urlRegex` | host / host:port 正则 fallback | sorted regex list |

注意：当前 `MatchTarget.regexMatchValues` 只包含 `host` 和 `host:port`。因此 `urlRegex` 不是完整 HTTP URL path 匹配；没有 URL path 上下文时，文档不能把它描述成可匹配任意 URL。

## 2.3 刷新契约

全量刷新：

```swift
internal func refreshPolicies(_ policies: [AccessControlPolicy])
```

契约：

- 按 `matchType + normalized(matchValue)` 做策略身份。
- 相同身份保留最后一条配置。
- 空值、非法 CIDR、无法编译的 regex 不进入运行时索引。
- 刷新会整体替换 `AccessControlState`。
- 刷新后必须 `cache.removeAll()`，防止旧匹配结果继续命中。

代码里还有单条刷新方法：

```swift
private func refreshPolicy(_ policy: AccessControlPolicy)
```

它当前是 private，只作为内部 upsert 能力保留；外部 App 当前通过 `MagentClient.putAcl(_:)` 做全量写入。

## 2.4 匹配契约

```swift
internal func match(_ address: NetworkAddress) async -> Decision
```

契约：

- 输入是已经由 Proxy/Core 层解析出的 `NetworkAddress`。
- 输出只包含 `.direct` 或 `.proxy(UUID)`。
- 未命中任何规则时返回 `.direct`。
- 匹配过程不读取代理节点表。
- 匹配过程不创建 wire。
- 结果可被 `MagentCache` 缓存。

优先级裁决：

```text
1. order 越小越优先
2. specificity 越大越优先
3. sequence 越小越优先
```

所有索引命中都必须通过 `choose` 统一裁决，不能在某个 phase 内私自返回破坏全局优先级。

## 2.5 缓存契约

`MagentAccessControl` 使用 `MagentCache` 缓存 `MatchTarget.cacheKey -> AccessControlPolicy`。

| 行为 | 契约 |
|---|---|
| 默认容量 | `4096` item |
| 扩容 | `expandCacheCapacity(to:)` 只在新容量更大时重建 cache |
| 刷新规则 | `refreshPolicies` 后清空缓存 |
| 缓存 key | 区分 `domain` / `ipv4` / `ipv6`，并包含 port |
| 默认直连 | 未命中规则时合成 `.direct` policy 并缓存 |

`expandCacheCapacity(to:)` 不迁移旧缓存条目，因为匹配缓存允许丢失；它不能改变当前规则快照。

---

# 3. Core Logic

## 3.1 状态结构

```text
MagentAccessControl
  queue: concurrent DispatchQueue
  state: AccessControlState
    policies: [AccessControlPolicy]
    indices: [AccessControlPolicyIdentity: Int]
    rules: Rules
  cache: MagentCache
```

`queue.sync(flags: .barrier)` 串行化刷新和 cache 替换；匹配路径通过 `queue.sync` 读取当前快照和缓存。

## 3.2 编译流程

```text
refreshPolicies
  -> makeState
    -> normalize policy identity
    -> de-duplicate by identity, keep last
    -> compile(uniquePolicies)
      -> exactDomain -> HashSet
      -> domainSuffix -> SubDomainsTree
      -> domainKeyword -> KeywordMatcher
      -> ipCIDR -> IpRange IPv4 / IPv6
      -> urlRegex -> RegexSet
      -> build keyword automaton
      -> sort regex by priority
  -> replace state
  -> cache.removeAll()
```

归一化规则：

| 类型 | identity 归一化 |
|---|---|
| `exactDomain` | trim、lowercase、去首尾点 |
| `domainSuffix` | trim、lowercase、去首尾点 |
| `domainKeyword` | trim 后 lowercase |
| `ipCIDR` | trim 后保留原文，编译阶段解析 CIDR |
| `urlRegex` | trim 后保留原文，编译阶段编译 regex |

## 3.3 MatchTarget

`NetworkAddress` 会先归一化为 `MatchTarget`：

| 输入 | 归一化结果 |
|---|---|
| `.domain(host, port)` | normalized host、可选 IPv4 bytes、regex values、`domain|host|port` cache key |
| `.ipv4(data, port)` | dotted IPv4 host、IPv4 bytes、regex values、`ipv4|host|port` cache key |
| `.ipv6(data, port)` | colon IPv6 host、IPv6 bytes、regex values、`ipv6|host|port` cache key |

`regexMatchValues` 当前是：

```text
host
host:port
```

## 3.4 匹配阶段

miss 后实际匹配流程：

```text
exactDomainPhase
  -> domainSuffixPhase
  -> domainKeywordPhase
  -> ipCIDRPhase
  -> regexFallbackPhase
  -> no hit ? directPolicy()
```

每个 phase 结束后，都会用后续索引的 `bestPossible` 判断是否还可能击败当前 best：

```text
canBeat(nextIndex.bestPossible, currentBest)
```

如果后续 phase 理论最优也无法击败当前命中，则提前返回，避免继续进入更重的索引，尤其是 regex fallback。

## 3.5 索引结构

| 索引 | 数据结构 | 查询复杂度 |
|---|---|---|
| exact domain | Dictionary-backed hash set | 平均 O(1) |
| domain suffix | 反向 label trie | O(label count) |
| domain keyword | Aho-Corasick 自动机 | O(host bytes) |
| IPv4 CIDR | bit trie | 最多 32 步 |
| IPv6 CIDR | bit trie | 最多 128 步 |
| url regex | 优先级排序 regex list | O(R * T) |

`urlRegex` 是唯一随规则数量线性增长的 fallback，应控制数量，并依赖 `bestPossible` 和优先级排序减少进入成本。

---

# 4. Corners

## 4.1 Refresh 与缓存失效

| 约束 | 说明 | 覆盖测试 |
|---|---|---|
| 全量刷新替换规则 | 新规则快照生效，旧缓存结果必须失效 | `MagentAccessControlTests.testRefreshPoliciesReplacesCompiledRulesAndClearsCache` |
| 重复身份保留最后一条 | 归一化后相同 `matchType + matchValue` 的最后策略生效 | `MagentAccessControlTests.testRefreshPoliciesKeepsLastPolicyForDuplicateIdentity` |
| 扩容不丢规则 | `expandCacheCapacity` 可以丢缓存，但不能丢当前规则快照 | `MagentAccessControlTests.testExpandCacheCapacityKeepsCurrentPolicies` |

## 4.2 CoreService 集成边界

| 约束 | 说明 | 覆盖测试 |
|---|---|---|
| `Decision.proxy` 依赖节点表 | 规则命中 proxy 后，通过 `CoreService.getProxyNode(_:)` 按 UUID 找节点，再由调用方创建 wire | `CoreServiceTests.testRefreshProxyNodesReplacesAndRemovesNodeTable` |
| 节点表重复 ID 最后生效 | 同 UUID 多次刷新时最后节点覆盖前值 | `CoreServiceTests.testRefreshProxyNodesUsesLastNodeForDuplicateIDs` |
| 缺失节点报错 | 策略命中 proxy 但节点表没有对应 UUID 时抛 `proxyNodeNotFound` | `CoreServiceTests.testRefreshProxyNodesReplacesAndRemovesNodeTable` |

## 4.3 MagentClient 集成边界

| 约束 | 说明 | 覆盖测试 |
|---|---|---|
| App 通过 `putAcl` 写入 ACL | `MagentClient` 不暴露 `MagentAccessControl` 本体 | `MagentClientIntegrationTests.testHTTPGenerate204ThroughMagentClientConnection` |
| AccessControl + Core + Wire 串联 | domainSuffix 规则可驱动 HTTP forward 走代理节点 | `MagentClientIntegrationTests.testHTTPGenerate204ThroughMagentClientConnection` |

该集成测试依赖真实 Shadowsocks 节点，未配置环境变量时会跳过；它不是普通单元测试的必跑项。

## 4.4 当前测试缺口

当前 UT 已覆盖 refresh、去重、缓存清理、扩容、Core proxy 节点联动，但还没有直接覆盖以下 matcher 细节：

- `domainSuffix` 的最长/最优后缀选择。
- `domainKeyword` 的 Aho-Corasick 多关键字重叠命中。
- IPv4 / IPv6 CIDR 前缀优先级。
- `urlRegex` 对 `host` 与 `host:port` 的 fallback 行为。
- `order -> specificity -> sequence` 跨 phase 优先级裁决。
- invalid CIDR / invalid regex 被忽略的行为。
- `bestPossible` 提前返回的语义等价性。

这些是后续补 UT 的优先点；文档中不能把当前测试覆盖面描述成已经完整覆盖所有 matcher 内部索引。

## 4.5 Benchmarker

历史 benchmark 源文件：

```text
Magent/Tests/Core/MagentAccessControlBenchmark.swift
```

当前 `Package.swift` 未声明 `MagentAccessControlBenchmark` executable product，因此下面数据作为历史归档保留；直接执行 `swift run -c release MagentAccessControlBenchmark` 在当前 Package 配置下不可用。若要重新跑，需要先把该源文件重新纳入 executable target，或新建正式 `MagentAccessControlBenchmark` target。

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

## 4.6 验证命令

```bash
cd Magent
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=$PWD/.build/clang-module-cache \
swift test --filter MagentAccessControlTests

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH=$PWD/.build/clang-module-cache \
swift test --filter CoreServiceTests
```

---

# 5. 总结

`MagentAccessControl` 是 Core 层访问控制匹配的唯一运行时 owner。它的关键边界是：

- App 写规则走 `MagentClient.putAcl(_:)`。
- `MagentClient` 只持有 `CoreService`；访问控制刷新和匹配由 `CoreService` 转发到内部 `MagentAccessControl`。
- 规则刷新替换不可变编译快照并清空缓存。
- 匹配只返回 `Decision`，不碰节点表和 wire。
- 所有命中统一通过 `order -> specificity -> sequence` 裁决。
- `urlRegex` 是 fallback 热点，不应被当作常规高吞吐规则类型。
