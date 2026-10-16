# MagentCore 产品设计

更新日期：2026-10-14。状态：**目标设计**，按初始化只读配置与 Connection 所有权收敛接口；
不表示源码已完成迁移或通过验收。
契约依据：[MODELS SPEC v0.4.3](../MODELS_SPEC.md#proxyrule)、
[Wire SPEC v0.3.1](../WIRES_SPEC.md) 及 [架构](../ARCHITECTURE.md#core)。

## Context

`MagentCore` 将 Connection 已解析的业务目标变成可用的下游路径：匹配规则，取得 DIRECT 或
PROXY 决策，选择节点及 Wire，并按 Connection 的请求创建 Channel。规则由应用通过
`MagentConfig.rules` 提供，`ProxyRule` 定义并校验规则，Core 负责在本运行周期执行它们。

```text
MagentConfig → Magent.start / restart → 本运行周期 MagentCore
Connection(target) → Core 路由 → DIRECT：连接 target
                            → PROXY：连接 Wire endpoint → Wire 启动携带 target
下游 Channel → Connection 持有并转发 → target
```

| 组件 | 拥有的责任 |
| --- | --- |
| `Magent` | EventLoopGroup、listener、运行周期和关闭通知；创建 Core。 |
| `MagentCore` | 默认决策、规则匹配器、决策缓存、节点及共享 UDP Wire；创建下游 Channel。 |
| 具体 Connection | 解析并固定目标，持有选中的 TCP Wire 和下游 Channel，执行启动、回复、读写、EOF 与清理。 |
| `MagentTCPConnection` | accepted Channel 的探测、分派和最终关闭。 |
| `Wire` | 提供节点 endpoint 与超时，编解码目标及业务数据。 |

Core 不持有创建成功的 Channel，不接收 HTTP/SOCKS 原始报文，不发送本地成功回复。
TCP 连接代理节点及写成启动字节，只表示出站路径已建立；本版 Wire 没有远端 target 可达性的确认消息。

## Contract

### 类型、数据与执行边界

约束对象为 [MagentCore.swift](../../Sources/Core/MagentCore.swift) 中的 `MagentCore`，以及
同文件私有协作者 `MagentRouter`。以下声明按初始化、路由、建连职责列出；方法数量不作为设计目标。
声明仍是实现约束，调整须按[设计规则](DESIGN.md#writing-rules)说明调用者及职责并同步文档。
Router 只匹配规则；TCP Wire 在路由时创建，UDP Wire 在初始化装载节点时创建。

```swift
internal final class MagentCore: @unchecked Sendable {
    private let defaultDecision: Decision
    private let router: MagentRouter
    private let routeCache: MagentCache<Decision>
    private let nodes: [UUID: ProxyNode]
    private let udpWires: [UUID: Wire]
    internal let defaultTimeout: Int64
}

private struct MagentRouter: Sendable {}
```

| 成员 | 用途、初始化与生命周期 |
| --- | --- |
| `defaultDecision: Decision` | 规则为空或未命中时使用的默认决策。init 注入并校验，初始化后不变。 |
| `router: MagentRouter` | 当前运行周期的规则匹配器。init 根据规则创建，初始化后不变。 |
| `routeCache: MagentCache<Decision>` | 规则匹配结果缓存，只缓存 Decision。init 创建，空规则时 capacity 为 0，否则为 4096，默认不过期；运行期间引用不替换。 |
| `nodes: [UUID: ProxyNode]` | 按 UUID 保存的节点表。init 成功时一次赋值，运行期间只读。 |
| `udpWires: [UUID: Wire]` | 按节点 UUID 保存的共享 UDP Wire。init 成功时一次赋值，运行期间不替换；各实例必须支持安全共享。 |
| `defaultTimeout: Int64` | DIRECT TCP 与关联内 DNS 使用的超时毫秒数。init 接收已由 Magent 配置边界校验的正数，初始化后不变。 |

`addressNodes` 仅为 init 内检查 endpoint 唯一性的局部记录，不是 Core 成员。

Core 可供多个 accepted EventLoop 同时读取。发布后没有节点修改入口；缓存自行同步。
TCP Wire 每次选择独立创建，随后只由所属 Connection 串行使用。共享 UDP Wire 必须满足
[Wire 并发约束](../WIRES_SPEC.md#调用与线程约束)，每包临时状态不跨调用或关联保留。
`@unchecked Sendable` 不代替这些所有权条件。

### 初始化、规则与 Wire 选择

以下是精确声明；注释说明调用者及唯一责任。方法不增加默认参数或 `async`。

```swift
/// Magent.start / restart 调用；局部装载节点、创建 UDP Wire 并校验默认节点，成功后发布只读配置。
internal init(
    defaultDecision: Decision, proxyNodes: [ProxyNode],
    defaultTimeout: Int64, rules: [ProxyRule]
) throws

/// 两种 route 方法共用；通过一次 getOrLoad 返回匹配或默认决策，不执行网络 I/O。
private func routeDecision(_ address: NetworkAddress) -> Decision

/// routeDecision 调用；生成规则匹配身份的缓存键，不修改业务目标。
private static func routeCacheKey(_ address: NetworkAddress) -> String

/// 四种 TCP Connection 每条连接调用一次；DIRECT 返回 nil，PROXY 按节点类型创建新的 TCP Wire。
internal func routeTCPWire(_ address: NetworkAddress) throws -> Wire?

/// SOCKS5 关联每个合法客户端数据报调用；DIRECT 返回 nil，PROXY 返回对应共享 UDP Wire。
internal func routeUDPWire(_ address: NetworkAddress) throws -> Wire?
```

实施时将当前源码的 `putAllProxyNodes`、`createTCPWire`、`createUDPWire` 分别收回 `init` 或
`routeTCPWire`，保留原始构造错误。测试通过完整初始化配置验证装载规则，不保留测试专用修改入口。

模型声明绑定 [NetworkAddress](../MODELS_SPEC.md#networkaddress)、
[ProxyNode](../MODELS_SPEC.md#proxynode) 和 [ProxyRule / Decision](../MODELS_SPEC.md#proxyrule)。
Wire 声明绑定 [v0.3.1 接口](../WIRES_SPEC.md#抽象接口草图)，不在 Core 增加 Direct Wire 或路由结果包装。

规则覆盖和选择遵循 [Core 的选择顺序](../MODELS_SPEC.md#core-的选择顺序)：
相同 `Match` 保留最后配置及其位置；所有命中先比 `order`，再比具体性，最后比保留输入位置。
Router 不重复解析规则文本，不执行 DNS，也不读取端口、URL、传输种类或客户端身份。

```swift
/// Core.init 调用；消费已校验规则，按 Match 去重并保留稳定输入位置。
fileprivate init(_ sourceRules: [ProxyRule])

/// routeDecision 调用；返回最优命中的 Decision；无命中为 nil。
fileprivate func match(_ address: NetworkAddress) -> Decision?

/// match 调用；按模型的 order、具体性和稳定位置比较两个实际命中候选。
private func isPreferred(_ candidate: Int, over current: Int) -> Bool
```

缓存键区分 domain、IPv4 和 IPv6，省略当前规则不读取的端口；域名匹配与缓存视图去掉一个末尾根点，
传给 DNS / Wire 的目标仍保留根点。缓存命中只省去规则匹配，不能复用其他 TCP 连接的 Wire。
`routeDecision` 直接调用一次 `getOrLoad`；其缺失分支执行本地匹配，不再先调用 `get` 重复查询。

### 下游 Channel 创建

```swift
/// TCP Connection 的 DIRECT 分支调用；数值目标直接连接，域名交 NIO 异步解析及连接。
internal func createTCPClientChannel(
    eventLoop: EventLoop, address: NetworkAddress, timeout: Int64,
    handler: ChannelHandler & Sendable
) -> EventLoopFuture<Channel>

/// TCP Connection 的 PROXY 分支调用；直接连接所选 Wire 的实际节点 endpoint。
internal func createTCPClientChannel(
    eventLoop: EventLoop, address: SocketAddress, timeout: Int64,
    handler: ChannelHandler & Sendable
) -> EventLoopFuture<Channel>

/// SOCKS5 关联创建 IPv4 relay / IPv6 outbound 时调用；address 是本地 bind 地址，可用端口 0。
internal func createUDPClientChannel(
    eventLoop: EventLoop, address: SocketAddress,
    handler: ChannelHandler & Sendable
) -> EventLoopFuture<Channel>
```

| 调用契约 | 结果与交接 |
| --- | --- |
| `eventLoop` | 必须传入所属 accepted Channel 的 EventLoop；创建的 Channel、返回的 future 及回调均在该 loop，包括参数校验失败。Core 不新建线程、group 或 Task。 |
| TCP 参数 | target / endpoint 为合法非零端口；endpoint 为数值 IP；timeout 按模型毫秒范围校验。 |
| TCP 成功 | handler 在激活前安装；返回已连接 Channel，`autoRead=false`、`maxMessagesPerRead=1`、允许远端半关闭。 |
| UDP 成功 | handler 已安装并完成本地 bind；手动读取，每次最多一条消息，接收容量 65,535 字节。完整包校验属于关联。 |
| 失败 | 参数错误返回 failed future；NIO 连接、bind、handler 安装错误原样传播，Core 不写协议回复或关闭 accepted。 |
| 资源归属 | 调用方成功后接管 Channel；若自身已关闭，立即关闭迟到 Channel。工厂失败不遗留可用 Channel。 |

两个 TCP 重载共用相同选项和成功语义；区别只在地址消费路径。现有重载足以表达 DIRECT 与 PROXY，
不能为合并方法把实际 SocketAddress 转成 NetworkAddress，导致地址族或 IPv6 作用域丢失。
共同配置按上表统一约束，并由两个真实入口的测试验证一致性；不新增连接工厂层。
调用方通过 future 续接，不在 EventLoop 上 `wait()` / `get()`。

当前源码的工厂参数仍是 `group: EventLoopGroup`，须与调用方一起迁移为 `eventLoop: EventLoop`。
源码还把 NIO 错误包装为 `channelCreationFailed` / `channelConnectionTimedOut`；这是待迁移项。
目标实现保留原始错误，由 Connection 的统一失败边界识别超时并选择本地响应；不能只保留错误字符串。
Wire 当前的 `getTargetAddress()` 同样须按 Wire SPEC 迁移为 `getEndpoint()`，本设计不增加兼容 getter。

## Core Logic

### 初始化与运行周期

`Magent.start` / `restart` 校验配置后创建 Core：准备规则与空缓存，在 `init` 的局部表中按输入顺序
装载节点及 UDP Wire，最后验证默认 `.proxy(UUID)` 存在，再赋给只读字段。规则引用在实际命中时检查。
同 UUID 后值覆盖前值，换地址移除旧记录；不同 UUID 占用当时仍在使用的 endpoint 即失败。
不能先按 UUID 去重再检查 endpoint，否则会改变顺序装载语义。构造失败不发布 Core，不影响旧 runtime。

Core 没有独立运行状态枚举或 `start/restart/close`。初始化完成后提供路由与建连；
Magent 的关闭通知使旧 Connection 停止新操作并清理资源，最后释放旧 Core 的节点、缓存及 Wire 引用。
缓存内部维护由缓存组件负责；当前无期限缓存的实例归属不引入另一套服务生命周期。

这里固定的是当前缓存的非抛错查询和引用释放边界，不表示已实现
[缓存目标设计](MagentCache_Design.md)中的显式 `close` / `CacheClosed` 契约。
该目标接口尚待迁移，不能直接替换到本版非抛错的 `routeDecision` 下；实施缓存迁移时，
须同步修订并确认 Core 的查询错误传播与缓存终止边界。释放引用不承诺同步排空内部维护任务。

restart 先构造新 Core，再结束旧 runtime 并绑定新 listener。新 Core 构造失败保留旧 runtime；
新 listener 绑定失败按架构进入停止态。旧连接不迁移，新 Core 不读取旧缓存或复用旧 TCP Wire。

### TCP 到达目标

1. Connection 校验唯一 target，调用一次 `routeTCPWire(target)` 并保留结果。
2. DIRECT 用原 target 和 `core.defaultTimeout` 建连；PROXY 用同一个 Wire 的 `getEndpoint()` 和
   `getTimeout()` 建连，不解析代理路径上的业务域名，不再次路由 endpoint。
3. Channel 成功后由 Connection 接管；PROXY 调用一次 `start(handshake: target)` 并写完启动字节。
   本地 SOCKS / CONNECT 成功回复或 HTTP Forward 请求发送，均在各 Connection 的既有阶段内继续。
4. 后续字节和 EOF 由 Connection / Wire 处理。Core 不参与每次 TCP 读写，也不在失败时换节点或回退 DIRECT。

### UDP 到达目标

SOCKS5 control connection 使用工厂创建自己的 IPv4 / IPv6 Channel，部分成功或关闭竞争由该关联收尾。
每包校验来源和目标后调用 `routeUDPWire`；DIRECT 发送原数据，PROXY 用对应 Wire 编码并发向其 endpoint。
DIRECT 域名由关联自有 DNS client 处理；Core 不建立 resolver，PROXY 域名保持在包内交给节点。

关联记录实际出站 endpoint 及所选 Wire；回包据此解码，不重新匹配规则或从全局节点表猜测来源。
UDP 不执行 TCP connect / startup，不将 `getTimeout()` 变成逐包响应期限。
关联关闭只释放自己的 Channel、DNS 与记录，不终止其他关联共享的 UDP Wire。

## Corners

| 场景 | 可观察结果 |
| --- | --- |
| 空规则 / 全部未命中 | 使用默认决策；capacity=0 只禁用缓存存储，不改变路由结果。 |
| 默认代理节点缺失 / 命中规则引用缺失 | 分别在初始化 / 路由时报 `proxyNodeNotFound`；均不转为 DIRECT。 |
| 同 Match 多次配置、不同 order、极值 order | 最后配置参与比较；更小 order 胜出，比较不作相减，不被精确索引提前命中截断。 |
| 同域名不同端口或单根点 | 可复用 Decision，但每次连接仍使用自己的原 target 和端口。 |
| 同目标的并发 TCP / 多关联 UDP | TCP Wire 互相独立；UDP 只共享符合每包隔离与并发契约的实现。 |
| PROXY Wire 构造或节点连接失败 | 原样失败；不尝试默认决策、其他节点或 DIRECT。 |
| bind / connect 期间 control 或 runtime 关闭 | Connection 关闭迟到资源；不写成功、不继续启动，不复活旧 runtime。 |
| 一个关联部分 bind 成功或发生 endpoint 歧义 | 由 SOCKS5 关联按其设计清理 / 拒绝；Core 不增加每目标 socket 或关联表。 |

验证入口：[MagentCoreTests](../../Tests/Core/MagentCoreTests.swift)、
[模型规则验收](../MODELS_SPEC.md#proxyrule)、[Wire 验收](../WIRES_SPEC.md#验收)。
现有规则与节点用例可复用，但通过 `putAllProxyNodes` 装载的测试须改为传入完整 `proxyNodes` 构造。
当前 TCP 工厂用例只覆盖数值 IPv4 的 NetworkAddress 路径；UDP 单 EventLoop 用例直接使用
DatagramBootstrap，不能作为 Core UDP 工厂的验收证据。

### 实施验收

| 真实入口 | 必须验证的结果 |
| --- | --- |
| `init` 与路由 | 默认决策、缺失节点、重复 UUID、地址冲突及同 UUID 换地址按既定顺序生效；初始化后无节点修改入口。 |
| 两种 TCP 工厂重载 | 数值 IPv4 / IPv6 与实际节点端点正确；保留节点地址族及作用域；handler 激活前安装，手动读取和半关闭选项一致，Channel 与 future 属于传入的 EventLoop。 |
| DIRECT 域名工厂 | 覆盖域名解析、双栈/多 IP 候选及解析失败；保留逻辑目标和根点，解析过程不阻塞 EventLoop，失败候选不终止最终成功路径。 |
| Core UDP 工厂 | 通过工厂验证 IPv4 / IPv6 bind、端口 0 分配、handler 安装、接收容量、手动读取和同 EventLoop 完成；不能绕过 Core 直接测 DatagramBootstrap。 |
| 工厂失败与 Connection 响应 | 非法参数、连接超时、拒绝连接、bind 及 handler 安装失败均正确传播；保留原始错误信息，Connection 正确选择协议响应，失败无残留 Channel。 |
| Connection 关闭 / restart 竞争 | 建连期间关闭、迟到 Channel、UDP 部分 bind 成功后失败均回收资源；不重复回复，不复活旧连接，不影响其他关联。 |
| TCP / UDP Wire 使用 | 两条 TCP 连接的流状态独立；多关联共享 UDP Wire 时每包与关联状态互不污染。 |

实施后执行 Core 定向测试及仓库要求的连接、并发检查。上表是验收要求，不能用声明或链接检查替代。
2026-10-10 的 Core 定向测试尝试在 HttpProtocol 对旧 NetworkAddress 接口的调用处编译失败，
测试未执行；须完成相关迁移后重新验证。
