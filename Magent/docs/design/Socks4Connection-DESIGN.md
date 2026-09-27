---
desc: SOCKS4 和 SOCKS4a CONNECT 入口的目标产品设计、协作边界与迁移约束
updated_at: 2026-09-27
baseline: target-design
---

# Socks4Connection 产品设计

状态：目标设计，依据 [SOCKS4 / SOCKS4a SPEC](../SOCKS4_PROXY_SPEC.md) 和
[Wire SPEC](../WIRES_SPEC.md) 定义产品行为，不表示实现已完成。SOCKS4 SPEC 第 03 节与第 05 节、
Wire SPEC 和模型的根点身份要求尚未统一；提前数据和运行周期依赖仍需与包级契约联动。

规范基线：当前工作树草案 [SOCKS4 SPEC v0.2.0（2026-09-26）](../SOCKS4_PROXY_SPEC.md) 与
[Wire SPEC v0.3.0（2026-09-26）](../WIRES_SPEC.md)。

相关边界：[Magent 架构](../ARCHITECTURE.md) ·
[SOCKS4 解析](../SOCKS4_PROXY_SPEC.md#doc-03-incremental-parser) ·
[SOCKS4 DNS 与安全](../SOCKS4_PROXY_SPEC.md#doc-05-dns-and-addresses) ·
[SOCKS4 出站](../SOCKS4_PROXY_SPEC.md#doc-06-outbound-connectors) ·
[SOCKS4 会话](../SOCKS4_PROXY_SPEC.md#doc-07-session-and-relay) ·
[Wire SPEC](../WIRES_SPEC.md) · [路由与访问控制设计](MagentAccessControl_Design.md)。

## Context

`Socks4Connection` 是已经识别为 SOCKS4 的本地 TCP 会话的协议拥有者。它把 SOCKS4 或
SOCKS4a CONNECT 请求转换为一个逻辑 `NetworkAddress`，要求 Core 为该目标作一次路由，建立
DIRECT 目标连接或 PROXY 节点连接，并在本地成功回复完成后维持透明的双向字节流。

```text
accepted Channel
  └─ MagentTCPConnection：协议探测、accepted Channel 和最终关闭
       └─ Socks4Connection：SOCKS4 请求、回复屏障、会话状态、下游 Channel
            └─ MagentCore：一次路由及 DIRECT / 独立 TCP Wire 的选择
                 ├─ DIRECT：目标 TCP Channel
                 └─ PROXY：Wire 给出的节点端点 + 该连接独有的编解码状态
```

`MagentTCPConnection` 保有 accepted Channel；`Socks4Connection` 不得关闭它来完成自身清理，
而是在 accepted Channel 的结束或错误路径中释放自己持有的下游 Channel、Wire、待写数据和回调。
Core 负责规则、节点引用和 Wire 实例选择，Wire 负责出站协议的启动与编解码；这两个组件都不解析
SOCKS4 字节，也不生成 SOCKS4 回复。Wire 不拥有 Channel、网络 I/O 或本地会话。

本组件不执行客户端认证、IDENT、BIND、UDP 中继、应用层协议解析或节点协议分支。它不以 USERID
作为身份、路由键或日志中的可信字段，不从节点端点反推业务目标，也不因 PROXY 失败改走 DIRECT。
目标域名的 DNS 所有权、DIRECT 候选连接和节点名称装配遵循引用 SPEC；入口解析本身不做 DNS。

每个 accepted TCP 连接只拥有一个 `Socks4Connection` 和一个逻辑目标。它在任意时刻至多持有一个
已选中的业务下游 Channel；DIRECT 域名的受控候选拨号由 Core 与连接适配层在同一候选集合内管理，
不能因此重新解析或重新路由。PROXY 的 TCP Wire 必须是该连接独有的实例，因此其启动、加密或帧状态
不能跨客户端、目标或运行周期共享。

## Contract

### 受限类型与方法集合

本设计受限的组件是 `Sources/Connection/Socks4Connection.swift` 中的
`Socks4Connection`。它拥有本文列出的本地 SOCKS4 状态、下游 Channel、Wire 引用和用户态余量；
`Socks4Command` 仅是现有参数类型，不在本设计中增加 case 或方法。允许的 extension 范围为无：
`Socks4Connection` 的主声明及所有 extension 均不得增加方法、回调、重载或默认参数，也不得引入
wrapper、protocol 或源文件来绕开此表。本文列出及引用的 target 声明是实现约束；除静态完整头校验器外均为实例
方法，均不带默认参数、重载、`async` 或 actor 隔离。代码中未标 `private` 的 `func` 是 `internal`，未标
`throws` / `async` 等属性即不具有该属性。`@unchecked Sendable` 不改变所有调用仍由所属 EventLoop 串行的
约束；未列出的 `private` helper 禁止。服务级预算、来源准入和解析依赖仍是外部契约，本设计不为它们伪造
构造参数或 API。

受限方法集合共 18 项：1 个构造、3 个 `ProxyConnection` 入口、4 个 SwiftNIO 回调及 10 个内部产品阶段。

其中 3 个 `ProxyConnection` 入口通过引用
[MagentTCPConnection 设计的下游 Connection 协议（2026-09-27）](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)
纳入本设计。协议声明、方法签名、参数语义、默认 EOF 行为与
[主 handler 调用映射](MagentTCPConnection-DESIGN.md#主-handler-到下游协议的调用映射)
均以该文档为唯一来源，本节只规定 SOCKS4 对这些入口的实现职责，不重复定义协议或声明。

`MagentTCPConnection` 是 `Socks4Connection` 的创建者和 accepted Channel 所有者。它构造实例后只通过
`ProxyConnection` 入口提交已有字节、输入方向结束和最终清理。`Socks4Connection` 不拥有
`MagentTCPConnection`，也不冻结其未列出的成员。

```swift
/// Owns one SOCKS4 session after the accepted Channel has been classified.
internal final class Socks4Connection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
  /// Declares the SwiftNIO inbound payload type for this handler.
  typealias InboundIn = ByteBuffer
}

/// Creates the connection with its accepted Channel and immutable runtime Core.
internal init(proxyChannel: Channel, core: MagentCore)
```

| 声明 | 谁调用 | 输入、状态与后继 |
| --- | --- | --- |
| `init` | `MagentTCPConnection.installProxyConnection` 在 `ProxyProbe.socks4` 后调用。 | 保存同一 accepted Channel 与当前运行周期 Core，初始为读取请求；不读写网络、不路由、不创建 Wire。完成后由创建者第一次调用 `upstream`。 |

引用协议在本组件中的具体职责如下；三个入口仍计入上述 18 项方法集合。

| 引用的方法 | SOCKS4 实现职责 |
| --- | --- |
| `upstream` | 读取请求时调用增量长度和完整头校验阶段，保留有界余量并调用 `installWireChannel`；转发时调用 `outbound`。握手中建连、启动或回复写入期间已在途到达的客户端字节只能进入有界 `clientRemainder` 或触发停止续读，不能重复路由或提前调用 `outbound`。同步抛错和写入 future 失败都调用 `fail`；终态不再读或创建资源。 |
| `proxyInputClosed` | 提供 SOCKS4 专属 EOF 实现：记录客户端 FIN，先排空已接收客户端业务及可选启动字节，再半关闭下游输出，保留反向读取。握手尚未完成时以截断错误调用 `fail`。 |
| `closeConnection` | 按引用协议进入终态，关闭本组件的下游 Channel 并释放 Wire 和用户态余量；保持清理幂等及 accepted Channel 的所有权边界。 |

下列四项来自 SwiftNIO 的 `ChannelInboundHandler` 回调；它们是此组件唯一允许自行实现的该协议回调，
没有额外回调 extension。它们都不 `throws`、不 `async`，并由所属 EventLoop 串行调用。

```swift
/// Consumes one downstream Channel payload after a successful downstream connection.
func channelRead(context: ChannelHandlerContext, data: NIOAny)

/// Handles a downstream input-close event without closing the still-writable opposite direction.
func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)

/// Completes downstream cleanup after the downstream Channel becomes inactive.
func channelInactive(context: ChannelHandlerContext)

/// Routes a downstream pipeline error to the accepted-Channel owning error boundary.
func errorCaught(context: ChannelHandlerContext, error: Error)
```

| 声明 | 谁调用 | 输入、状态与后继 |
| --- | --- | --- |
| `channelRead` | 下游 Channel 的 SwiftNIO pipeline。 | DIRECT 和 PROXY 都将字节交给 `inbound`；后者解码为 `InboundData`，前者透明回写。`start` 尚未成功前的原始节点字节只可有界保留或不发读；`start` 成功后可解码，即使启动写仍在途。空 `InboundData.data` 继续受读许可控制，不是 EOF。其同步抛错或写 future 失败调用 `fail`。 |
| `userInboundEventTriggered` | 下游 Channel 的 SwiftNIO pipeline。 | 仅处理 `.inputClosed`：DIRECT 排空后传播输出结束；PROXY 在已解码输入后调用 `Wire.finishInbound()`，其截断错误调用 `fail`。其他事件原样向 pipeline 传递。 |
| `channelInactive` | 下游 Channel 的 SwiftNIO pipeline。 | 正常全关闭而未收到 `.inputClosed` 时补做同一 EOF 语义；该检查的截断错误调用 `fail`，已知网络错误或取消不以截断覆盖。随后把最终关闭交给 accepted 所有者。 |
| `errorCaught` | 下游 Channel 的 SwiftNIO pipeline。 | 调用 `fail(error)`；该方法在条件性 `0x5B` 完成或回复期限到达后才将原始错误交给 accepted pipeline，之后 `MagentTCPConnection` 关闭 accepted Channel 并回调 `closeConnection`。 |

内部阶段仅使用下列声明。它们不是可供其他类型调用的 API；每个阶段有至少一个明确产品调用点，不能再以
额外 helper 分拆同一责任。标有 `throws` 的阶段将同步原始错误原样抛给调用者，再由 `upstream`、
`channelRead` 等最高协议边界调用 `fail`；这些 helper 不 catch 后自行改路。它们拥有的异步 future
失败回调可以把原始错误交给 `fail`。

```swift
/// Advances this connection's incremental SOCKS4 header scan without counting trailing business bytes.
private func paserLength(_ input: ByteBuffer) throws -> Int?

/// Validates a complete header and returns its command, logical target, and owned trailing payload.
private static func paserSocks4(_ input: ByteBuffer)
  throws -> (command: Socks4Command, address: NetworkAddress, remainder: ByteBuffer)

/// Routes the validated target and begins the selected DIRECT or PROXY downstream connection.
private func installWireChannel(command: Socks4Command, address: NetworkAddress) throws

/// Writes the local success reply and then enables independently ordered tunnel draining and reads.
private func startTunnel(_ channel: Channel) -> EventLoopFuture<Void>

/// Preserves the first protocol failure, optionally writes one failure reply, and then reports the original error.
private func fail(_ error: Error)

/// Encodes or transparently forwards one client tunnel payload to the downstream Channel.
private func outbound(_ data: ByteBuffer) throws

/// Decodes or transparently forwards one downstream payload to the accepted Channel.
private func inbound(_ data: ByteBuffer) throws

/// Writes optional startup or already encoded downstream business bytes in source order.
private func requestWireChannel(_ data: Data) -> EventLoopFuture<Void>

/// Writes a SOCKS4 reply or decoded business bytes to the accepted Channel in source order.
private func respondProxyChannel(_ data: Data) -> EventLoopFuture<Void>

/// Starts at most one SOCKS4 reply write and returns nil after any prior reply has started.
private func respondProxyChannelOnce(_ data: Data) -> EventLoopFuture<Void>?
```

| 声明 | 谁调用 | 输入、状态与后继 |
| --- | --- | --- |
| `paserLength` | 仅 `upstream` 的读取请求阶段调用。 | 在 `Socks4Connection` 所有的字段扫描进度上继续扫描新到字节，返回 `nil` 时仅等待更多字节；它绝不从头重复扫描先前分片。确定字段超限或头部非法时抛原始错误；完整头返回实际 header 长度，不吸收业务尾部。随后由静态 `paserSocks4` 校验一次完整头。 |
| `paserSocks4` | 仅 `upstream` 在 `paserLength` 已确认完整后调用。 | 验证 SOCKS4/4a、端口和目标，返回有界且拥有的 `remainder`；不 DNS、路由或写网络。成功后 `upstream` 保存余量并调用 `installWireChannel`。 |
| `installWireChannel` | 仅 `upstream` 的有效 CONNECT 路径调用。 | 调用列出的 Core 消费接口一次；DIRECT 建立目标 Channel 后调用 `startTunnel`。PROXY 建立 Wire 节点 Channel 后仅调用一次 `Wire.start`：返回 `nil` 直接调用 `startTunnel`，非空启动字节经 `requestWireChannel` 写成后才调用它。路由或建连准备的同步错误原样抛回 `upstream`，由它调用 `fail`；节点 Channel future 成功回调中的 `start` 抛错使该所属 future 以原始错误失败，再交给 `fail`，建连或启动写 future 失败亦然。迟到成功 Channel 在终态立即关闭。 |
| `startTunnel` | 仅 `installWireChannel` 的 DIRECT 建连成功路径，或 PROXY `start` 成功且可选启动字节已写成的路径调用。 | 它是唯一写成功 `0x5A` 的方法，其 future **只**在完整八字节成功回复写完后成功；随后两个方向各自排空已拥有余量并恢复本方向读取，互不等待。早到的已解码节点业务必须等启动写和该回复都完成后才经 `respondProxyChannel` 按序交付。回复写失败调用 `fail`，但因成功回复已开始而不改发 `0x5B`。调用时 Channel 必须存在且活跃，因此不接受可选参数。 |
| `fail` | `upstream` 的解析/路由失败，`installWireChannel` 的建连或启动写 future 失败，`outbound` / `inbound` 的抛错或写 future 失败，`proxyInputClosed` 的握手截断，NIO EOF/错误回调及这些已列方法安排的期限匿名回调。 | 原子地保留首次原始终因并停止新工作；仅尚未开始任何本地回复且 accepted 写端可用时，经 `respondProxyChannelOnce` 尽力写 `0x5B`。它等待该写完成或外部提供的独立 1 s 回复期限到达，再把**原始**错误交给 accepted pipeline；回复写错不能覆盖终因。匿名 future/EventLoop 回调只能调用此已列阶段，不得另建命名失败接口。 |
| `outbound` | `upstream` 的转发路径，以及 `startTunnel` 成功后的客户端余量排空。 | DIRECT 透明转发；PROXY 仅在 `start` 成功、可选启动字节写成和本地成功回复完成后以 `address: nil` 调用 Wire 编码。余量与后续输入都经过本方法，不能把未编码余量直接交给 `requestWireChannel`。同步错误抛回调用边界后交 `fail`；写 future 失败直接交 `fail`，写成才续读。 |
| `inbound` | `channelRead` 及启动后已读原始余量的排空。 | DIRECT 透明转发；PROXY 在 `start` 成功后以 `decodeInbound` 得到 `InboundData`。`data` 为空不输出也不是 EOF；非空业务在启动写或本地成功回复未完成时有界保存，完成后由 `respondProxyChannel` 按序交付。其地址固定为启动目标；解码同步错误原样抛回 `channelRead`，由它调用 `fail`；业务写 future 失败直接交给 `fail`。 |
| `requestWireChannel` | `installWireChannel`、`outbound` 和客户端余量排空阶段调用。 | 只写可选启动字节或已编码下游业务，并返回可排序 future；没有下游 Channel 返回 `connectionClosed` 失败 future。调用者把该 future 的失败交给 `fail`。 |
| `respondProxyChannel` | `startTunnel`、`inbound` 和 `respondProxyChannelOnce` 调用。 | 写本地回复或已解码业务，返回其完成 future；不负责回复次数或状态改变。正常业务或成功回复写失败由调用者调用 `fail`；`fail` 自己发起的失败回复写错只保留原始终因。 |
| `respondProxyChannelOnce` | `startTunnel` 和 `fail` 调用。 | 原子地取得唯一回复写权；已开始任意回复时返回 `nil`，调用者只清理资源。 |

`paserLength` 由连接持有增量扫描进度，`paserSocks4` 返回明确的请求边界和业务余量；
`startTunnel` 只接受已选定的非可选 Channel。`fail` 统一接收同步抛错、异步失败、EOF 和期限错误。
这些职责与签名直接作为目标约束，不按旧实现增加兼容 helper。

### 协作类型的受限消费声明

Wire、Core、`ProxyConnection` 和 SwiftNIO 由其他所有者维护。`ProxyConnection` 沿用前述
MagentTCPConnection 设计引用，不在本节重定义。本设计严格采用 [Wire SPEC v0.3.0 的
抽象接口](../WIRES_SPEC.md#抽象接口草图)、[TCP 启动](../WIRES_SPEC.md#启动与状态转换)、
[增量解码](../WIRES_SPEC.md#增量解码) 与 [EOF / 半关闭](../WIRES_SPEC.md#eof-与半关闭) 的精确签名、
`InboundData` 数据结构与语义，不在此重定义协作者接口。

`Socks4Connection` 仅约束自己的调用责任：`installWireChannel` 在 PROXY 节点 Channel 建好后，以一次
`start` 的 `nil` 结果直接进入 `startTunnel`，或把非空启动字节直接写成后进入；`outbound` 只在屏障完成后
编码，`inbound` 只在启动成功后解码并按屏障交付业务；正常 PROXY EOF 由
`userInboundEventTriggered(.inputClosed)` 或 `channelInactive` 发起；若 Wire 尚未初始化，启动后续接同一次检查。同一有状态 TCP Wire
始终由本连接的 EventLoop 串行调用；不增加兼容 wrapper、入口特例或额外 Wire 成员。

```swift
/// Routes one logical TCP target and returns nil only for the selected DIRECT route.
internal func routeTCPWire(_ address: NetworkAddress) throws -> Wire?

/// Provides the current DIRECT timeout until a service-level candidate budget API is designed.
internal let defaultTimeout: Int64

/// Opens a direct logical-target TCP Channel with manual-read and half-close behavior.
internal func createTCPClientChannel(
  group: EventLoopGroup, address: NetworkAddress, timeout: Int64,
  handler: ChannelHandler & Sendable
) -> EventLoopFuture<Channel>

/// Opens a proxy-node TCP Channel at an already resolved actual endpoint.
internal func createTCPClientChannel(
  group: EventLoopGroup, address: SocketAddress, timeout: Int64,
  handler: ChannelHandler & Sendable
) -> EventLoopFuture<Channel>
```

| Core 消费声明 | `Socks4Connection` 调用点 | 限制范围 |
| --- | --- | --- |
| `routeTCPWire` | `installWireChannel` 对每个已验证逻辑目标调用一次。 | `nil` 是 DIRECT，非 nil 是独立 TCP Wire；PROXY 节点缺失原样失败，不能 fallback。 |
| `defaultTimeout` 与 `NetworkAddress` 建连重载 | `installWireChannel` 的当前 DIRECT 路径。 | 这是当前消费声明，不是对 DIRECT DNS、候选或总预算的完整服务 API；这些外部契约待单独设计。 |
| `SocketAddress` 建连重载 | `installWireChannel` 的 PROXY 路径，参数来自 `getEndpoint()`。 | 不得将节点地址再次路由、解析为业务目标或传给 Wire 启动。 |

### 入口、目标与本地回复

调用者仅在 `MagentTCPConnection` 已根据首字节确定 SOCKS4 后创建本组件，并把探测阶段保留的
所有字节和后续任意分片按序交给它。组件以受限的增量解析处理一次请求：只接受 `VN = 0x04` 和
`CD = 0x01` 的 CONNECT，端口必须非零；`BIND (0x02)` 及其他命令失败。普通 SOCKS4 使用四个
数值 IPv4 字节，SOCKS4a 只在 `00 00 00 xx` 且 `xx != 00` 时读取 USERID 后的独立 DOMAIN 字段。

USERID 是不透明的 NUL 结尾字节串，可以为空，不能替代 SOCKS4a 的 DOMAIN，也不送往节点。目标
字段遵守 SOCKS4 SPEC 的产品子集：USERID 至多 255 字节，DOMAIN 为 1 至 254 个 ASCII 字节，
域名规范化后最多 253 字节且每个 label 为 1 至 63 字节；端口 0、未结束字符串、非 ASCII 名称、
URL、IPv6 文本、空域名和单 label 名称都不能通过该入口。头部实际消费部分受 1024 字节防御上限
约束，业务余量不能被计入头部长度。

尚未出现 NUL 但字段仍未超过相应上限时，解析结果只能是等待更多字节；不能因一段读取结束就判失败。
只有已确定非法输入、字段超长、EOF 造成截断或绝对握手期限到达才进入失败路径。

普通 SOCKS4 的 IPv4 必须由四个原始字节构造，不能经过宽松十进制文本解析。SOCKS4a 的有效域名
或规范数值 IPv4 由模型构造边界生成 `NetworkAddress`；构造失败进入失败路径。业务目标、实际
节点端点和任何 DIRECT 解析出的候选端点分属不同值，后两者不得覆盖前者。Core 和 Wire 收到的
必须是同一逻辑目标与端口，而不是原始 SOCKS4 头、USERID 或节点地址。

成功回复固定为八字节 `00 5A 00 00 00 00 00 00`，失败回复固定为
`00 5B 00 00 00 00 00 00`。成功的必要条件彼此独立：PROXY 的 `start(handshake: target)` 已成功，
且其非空启动字节已经按序写入成功；DIRECT 则是目标 TCP Channel 已建立。`start` 不等待远端确认，
无启动字节时不等待节点首包。随后组件
写成功回复，只有该写入完成后才能向客户端转发任何业务字节。每条连接最多开始一次本地回复；成功
回复一旦开始，后续失败不能追加 `0x5B`。

首字节已确定为 `0x04` 时，尚未开始回复且写端可用的协议、路由、连接、启动或回复前失败尽力映射
为一次 `0x5B`，并由 accepted Channel 的统一错误路径关闭。未知版本不写 SOCKS4 回复。下游和
Wire 的原始错误仍供最高拥有边界记录与关闭判断；本组件不能把它们改写成具体节点协议状态或隐藏为
DIRECT 成功。

### 阶段与资源预算

下表是 SOCKS4 SPEC 的产品初值，不是现有 `MagentConfig` 的新增字段、性能承诺或公共 API。服务
运行周期所有者负责把这些预算、名额和取消信号提供给 Connection；本设计不自行定义配置格式。所有
期限使用单调时钟。只有 DNS、DIRECT 候选拨号、PROXY 节点拨号和 Wire 启动受 20 s 出站总截止点
约束；入口握手、回复、relay、半关闭和服务排空各自计时。握手、出站与半关闭等绝对期限不因零星
输入续期；若配置非零 relay 空闲期限，仅实际业务转发进展重置空闲计时。

| 项目 | 目标初值 | 归属与边界 |
| --- | ---: | --- |
| 入口握手绝对期限 | 10 s，自 TCP accept 起 | Connection 在请求未完成前执行；没有首字节可直接关闭，已确认 `0x04`、未开始回复且仍可写的超时尽力写 `0x5B`。 |
| 出站总建连期限 | 20 s，自路由完成起 | Core/Connection 的共同上界，覆盖 DNS、DIRECT 候选或 PROXY 节点建立及 Wire 启动。 |
| DIRECT 逻辑 DNS | 5 s | 仅 DIRECT 域名的一次逻辑解析，包含等待解析额度。 |
| DIRECT 单候选拨号 | 8 s | 对已检查的数值候选；不允许 `connect(hostname)` 触发第二次解析。 |
| PROXY 节点拨号 | `Wire.getTimeout()` 的正毫秒值 | Wire 的节点端点超时，不替代 20 s 总期限或后续启动期限。 |
| Wire 启动 / 本地回复写入 | 8 s / 1 s | 前者从节点 Channel 就绪到 `start` 成功及所需启动字节写成，并受出站总期限限制；回复有独立收尾预算，20 s 出站失败后仍可用它尽力写失败，成功回复失败不改发 `0x5B`。 |
| 双向 relay 空闲 / 半关闭 | 0（禁用）/ 30 s | 空闲期限为零；半关闭期限从首先观察到方向 EOF 起，不能被零星反向流量续期，设为 0 只表示显式禁用。 |
| 服务优雅排空 | 30 s | 跨组件前置条件；只在服务已选择停止 accept、保留旧会话排空的生命周期方案时适用。 |

| 用户态资源 | 目标初值 | 归属与计费 |
| --- | ---: | --- |
| 已接纳会话 / 未完成成功回复会话 | 512 / 64 | 监听和服务准入所有者在解析前或请求处理前拒绝新会话；不是 `Socks4Connection` 的私有计数器。 |
| 单次读取 | 16 KiB | 读许可按本方向和全局可用额度决定。 |
| 单方向 relay 高 / 低水位 | 64 KiB / 32 KiB | 高水位包含排队和 in-flight 用户态字节；无额度即暂停源读取，写入完成后公平唤醒。 |
| 提前数据 | 64 KiB / 方向 | 分别限制 `clientRemainder` 与成功回复屏障前的上游业务余量。 |
| 全局用户态缓冲 | 64 MiB | 共享预算所有者在读取前预留、在消费或释放后归还；握手、余量和 relay 转移时只计费一次。 |

Wire 自行限制协议缓冲和单次输出，Connection 不查询或累加 Wire 内部占用。64 MiB 只覆盖被共享预算
管理的 Connection 用户态数据，不包含 Wire 协议状态、内核 socket 缓冲、TLS、对象或运行时内存，
不能据此声称 RSS 有上界。额度、Channel、解析观察者和会话名额均以一次幂等清理归还；迟到回调不再
占用或重复归还它们。

### 提前业务数据与回复屏障

目标流程采用 SOCKS4 SPEC 的有界 `clientRemainder`：解析完成时，同次读取中头部后的字节全部是
业务字节，不能再次按 SOCKS 解析。组件仅将实际已经持有的这些字节转移到 `clientRemainder`，上限
64 KiB；在启动处理和成功回复完成前停止继续读取客户端，以 TCP 背压限制后续数据。超过上限才是
`EARLY_DATA_LIMIT`，不能把内核接收缓冲或完整短头后的任意尾部当成超长头部。

节点 Channel 在 `start` 尚未成功前不得把原始输入交给解码器；Connection 只能以同一方向预算有界
保留这些原始字节，或暂不发起读取。`start` 成功后先按接收顺序解码已保留的原始字节，再处理后续读取；
即使启动字节写入仍在途也可以解码，其中非空业务数据
以独立、至多 64 KiB 的上游余量保存，必须等待启动写入和本地成功回复都完成后才交付。成功回复完整写入
后，两个方向可以独立并行排空各自余量：客户端方向必须先将 `clientRemainder` 发送到下游，才读取和
发送之后到达的客户端字节；上游方向按已解码顺序交付上游余量，随后到达的上游字节不得越过它。客户端
在完整请求后紧跟 FIN 时仍保留该余量：建立下游、完成成功回复、排空余量后才关闭下游输出方向，反向
响应继续可读。

当前包级规则要求成功回复前严格拒绝完整请求后的字节，与此目标流程不能同时落地。交付实现前必须由
规范或包级规则明确取舍；在取舍完成前，当前严格拒绝不是对本目标流程的许可，但这不妨碍本文明确
SOCKS4 SPEC 所要求的有界流程和对应验收。

### 尚待统一的入口契约

下列问题是规范内部的前置阻塞点，而不是实现可自行选择的策略。

| 问题 | 相互冲突的要求 | 需要统一后才能固定的组件行为 |
| --- | --- | --- |
| SOCKS4a 尾随根点 | SOCKS4 SPEC §03.4 要求移除一个尾随 `.`，但 §05.5 要求 PROXY 将保留根点的 `NetworkAddress` 交给 Wire；Wire SPEC 的地址契约和当前模型也保留根点身份。 | 定义入口交给 `NetworkAddress`、路由和 Wire 的唯一根点身份；在此之前不能同时承诺“去根点”与“保留根点”。 |

提前数据、旧会话和准入不是两份 SPEC 的相互冲突：前者是上节目标流程与当前包级规则的落地差异，
后者是 SOCKS4 SPEC 的服务依赖与现有 restart 语义的落地差异。它们分别在上节和下文说明；根点身份
未统一前，任何涉及 SOCKS4a PROXY 根点的整体验收仍不能成立。

### 状态契约

SOCKS4 与 SOCKS4a 都是“一次 CONNECT 请求、一次结果回复、一个固定 TCP 目标”。4a 只改变
目标的编码方式，DIRECT / PROXY 只改变出站路径；它们不改变客户端后续字节的含义。因此以
成功回复完成和终结为边界定义 **3 个状态**；解析、路由和启动由方法流程表达。
`State` 为本类型内部的私有枚举，没有方法。

```swift
/// 区分握手、业务转发和逻辑终结，不表示每个异步操作的进度。
private enum State {
    case handshaking
    case forwarding
    case closed
}

/// 构造后等待 SOCKS4 请求，尚未允许业务转发。
private var state: State = .handshaking
```

| 状态 | 允许的行为 | 离开条件与负责方法 |
| --- | --- | --- |
| `.handshaking` | `upstream` 解析一次请求；`installWireChannel` 建立下游并完成可选启动；提前业务只缓冲。 | `startTunnel` 的完整成功回复写成后进入 `.forwarding`；失败或关闭进入 `.closed`。 |
| `.forwarding` | `outbound` / `inbound` 双向转发；一侧 EOF 只排空并半关闭该方向，另一侧继续。 | 两侧均结束、不可恢复错误或取消时进入 `.closed`。 |
| `.closed` | 禁止新的解析、建连、Wire 调用和业务转发；只完成已安排的失败回复与幂等清理。 | 终态，不恢复。 |

状态只能在 accepted EventLoop 上推进：`handshaking -> forwarding -> closed`，也允许
`handshaking -> closed`。成功回复只是开始写、或仅下游建连成功，都不能进入 `.forwarding`。

以下是已有流程必须保存的事实，不另建回复或方向状态枚举：

| 数据 | 初值与约束 |
| --- | --- |
| 请求是否已接受 | 初始否；完整头校验通过后置是，只路由一次；之后输入只属于业务余量。 |
| 回复是否已提交 | 初始否；`respondProxyChannelOnce` 在实际写前占用，成功和失败共用一次权利，写失败也不恢复。 |
| 两侧 EOF、正常下游 EOF 是否已检查、两侧输出是否已关闭 | 初始均为否，分别记录；只关闭排空后的对应输出，不把单侧 EOF 当整连接结束。 |
| 首次错误、是否已上报、是否已清理 | 初始 nil / 否 / 否；首次错误保留，终因上报和资源清理各至多一次。 |

`fail` 先固定首因及本次允许的失败回复，置 `.closed` 后限时完成该次回复并上报；关闭期间不能
再生成另一回复。accepted owner 随后调用 `closeConnection` 时仍须执行尚未完成的清理，不能仅因
`state == .closed` 跳过；重复清理按清理事实拦截。正常结束先置 `.closed` 再请求 accepted 关闭。
迟到建连只释放资源，迟到业务回调不能恢复状态。EOF 早于 Wire 初始化时保留该事实及原始余量，
初始化且已读数据解码完成后检查一次；已有错误或取消不执行正常 EOF 检查。

### 生命周期与调用不变量

主状态只区分握手、转发与关闭；校验、路由、启动和回复是握手内部步骤。除了已安排的失败回复
与清理，终态不再接受新的工作。同一会话的状态推进、Wire 调用和每个方向的写入均在 accepted
Channel 所属 EventLoop 上按序进行。

在 Wire 启动期间，`start(handshake:)` 只能以该逻辑目标成功调用一次。`start` 成功即完成本地
编解码初始化；非空启动字节的写入成功才允许本地成功回复，期间可以解码并有界保存节点业务，但不得
调用 `encodeOutbound` 或向客户端交付业务。`decodeInbound` 只返回业务数据，不推进启动或生成节点写入。
DIRECT 不创建占位 Wire，PROXY 也不能在 Wire 创建、建连、启动或编解码失败时退回直连。

会话只接受首次终因；多个同时到达的失败只保留首个终因，后续错误可作为次级诊断但不得二次写回复、
关闭资源或归还名额。取消、超时、RST 与 read/write 错误先经 `fail` 收敛，再由它把原始原因交给最高
拥有边界；后者选择关闭 accepted Channel 并触发幂等清理。日志默认脱敏，不输出 USERID、业务载荷、节点凭据或控制帧；
结构化日志只记录阶段、动作、脱敏目标类型/端口和首个终因。业务字节指标只计入目的流适配器实际消费的
字节，不把 socket 接收、缓冲容量或远端应用已读取混为吞吐。

## Core Logic

### 建议的方法调用流程图

方法名沿用 `Contract`，包括 `paserLength` / `paserSocks4` 的既定拼写；方括号表示状态或条件，
不是新增方法；只有带点名称表示生命周期状态。箭头表示调用或完成后的推进；标注“写成”的边必须等待对应 future 成功。

```text
MagentTCPConnection
  -> Socks4Connection.init(proxyChannel:core:)
  -> upstream(context:data:)
       |
       +-- [.handshaking: 请求未完成] -> paserLength(input)
       |                    +-- nil -> [保留输入, 等下一次 upstream]
       |                    +-- 完整 -> Self.paserSocks4(input)
       |                                  -> [保存 target 与 remainder]
       |                                  -> installWireChannel(command:address:)
       |                                       -> Core.routeTCPWire(target)
       |                                            +-- DIRECT -> Core.createTCPClientChannel(...)
       |                                            |               -> [建连成功: 下游就绪]
       |                                            +-- PROXY -> Core.createTCPClientChannel(...)
       |                                                            -> Wire.start(handshake: target)
       |                                                                 +-- nil -> [下游就绪]
       |                                                                 +-- 启动字节
       |                                                                      -> requestWireChannel(...)
       |                                                                      -> [写成: 下游就绪]
       +-- [建立/回复中] -> [有界保存客户端余量, 不重新解析或路由]
       +-- [.forwarding] -> outbound(data) -> [DIRECT 直通 / Wire.encodeOutbound]
                                             -> requestWireChannel(...) -> [写成后续读客户端]

[下游就绪] -> startTunnel(channel)
             -> respondProxyChannelOnce(0x5A) -> respondProxyChannel(...)
                  -> [完整成功回复写成: .forwarding, 两个方向独立排空余量]

下游 channelRead(context:data:) -> inbound(data)
  -> [DIRECT 直通 / Wire 已初始化后 decodeInbound]
       +-- [空业务结果] -> [等待后续输入, 不是 EOF]
       +-- [启动写/成功回复尚未完成] -> [有界保存已解码业务]
       +-- [屏障已完成] -> respondProxyChannel(...) -> [写成后续读下游]
```

Wire 初始化前的原始节点输入只作有界保留；已解码余量在屏障完成后直接经 `respondProxyChannel`
排空，不再次交给 `inbound` 解码。拒绝、同步抛错和 future 失败按下面的终结流程汇合。

```text
proxyInputClosed(context:)
  +-- [请求截断] -> fail(error)
  +-- [完整请求/转发中] -> [等待建立及回复, 排空上行, 半关闭下游输出]

userInboundEventTriggered(.inputClosed) / channelInactive([正常结束且尚未处理 EOF])
  -> [处理完已读输入; PROXY 调 Wire.finishInbound(), DIRECT 跳过]
       +-- [成功] -> [反向排空, 半关闭客户端输出, 保留另一方向]
       +-- [抛错] -> [所属 NIO 回调] -> fail(error)

errorCaught(error) / [入口捕获的原始错误、future 失败、期限到达]
  -> fail(error) [.closed, 完成本次错误收尾]
       +-- [尚未提交回复且可写] -> respondProxyChannelOnce(0x5B)
       |                           -> respondProxyChannel(...)
       |                           -> [写完或回复期限到达: REPORT]
       +-- [已提交回复或不可写] -> [REPORT]

[REPORT] -> accepted.pipeline.fireErrorCaught(原始错误)
  -> MagentTCPConnection.errorCaught -> closeConnection(error:)
  -> [幂等清理下游; accepted 的关闭由主 handler 完成]

[正常双方排空 / accepted 失效]
  -> MagentTCPConnection.channelInactive -> closeConnection(error: nil)
```

### 路由、DNS 与安全协作

`Socks4Connection` 只提交已经校验的逻辑目标和接收 Core 的一次决策；来源准入、目标保护、解析、
节点装配和下游拨号由对应拥有者完成。下表规定这些协作的输入输出，避免入口把节点端点当目标、把
解析结果重当路由输入，或因例外规则绕过安全边界。

Core 的迁移前置契约是：规则按配置顺序有序首匹配、未命中使用显式 final；域名匹配不为 CIDR 查询
DNS，数值 IP 不反查域名，入口也不从隧道载荷嗅探目标。`Socks4Connection` 不能为满足这些要求自建
路由器、补充目标信息或改变 Core 已作出的动作。

| 阶段 / 决策 | 所有者 | Socks4Connection 可依赖的输入与后续动作 |
| --- | --- | --- |
| 客户端来源准入 | listener / 服务入口 | 所有连接均在协议探测前检查来源；默认仅回环，非回环监听需显式许可及非空来源白名单。拒绝的连接不创建解析器、DNS、Core 路由或下游。 |
| 已知数值目标保护 | TargetGuard | IPv4 目标在普通路由前按数值和端口检查；自身监听端点无条件拒绝，IPv4-mapped IPv6 先归一为 IPv4。精确允许例外只能放行对应 deny CIDR，不能绕过自身监听保护或普通 `REJECT` 决策。 |
| `REJECT` | Core | 回复前失败、零目标 DNS、零节点或目标下游创建；不能为解释规则或记录目标而产生外部连接。 |
| DIRECT IPv4 | Core / Connection | 不解析名称，使用已检查的数值目标拨号；不会因为连接失败改成 PROXY。 |
| DIRECT Domain | resolver / TargetGuard / Connection | 每次逻辑解析取得 A/AAAA 候选，最多 16 个去重候选；整个服务同时运行的实际底层解析任务最多 16 个。取消后底层任务仍占额度至真实结束，过期结果不得新拨号。每个候选先做数值保护，再以固定数值地址拨号，同时最多两个候选拨号，默认以 250 ms 错峰，成功后关闭其余候选；不能 `connect(hostname)` 二次 DNS，也不把候选重新送入普通路由。 |
| PROXY IPv4 或 Domain | Core / Wire | Core 一次选择独立 Wire；Domain 不作目标 DNS，完整逻辑地址原样交给 Wire。Wire 无法表达地址即失败，入口不得改解析为 IP、换节点或退回 DIRECT。 |
| 节点配置及节点端点 | 配置装配 / Core / Wire | 节点名称解析只发生在配置装配边界；Connection 仅连接 Wire 提供的实际端点，不为节点运行业务目标路由。每次连接仍检查节点端点不会回到本服务监听地址。 |

PROXY 域名路径保留一个有意的远端解析盲区：本地为保护隐私不解析名称，因而无法确认远端最终地址是否
落入内网或回环。远端节点必须自行执行出站 ACL、解析结果过滤和回环保护；本地 SOCKS4 成功回复不能
被解释为已获得完整的远端 SSRF 防护。

### Contract 方法到产品流程映射

下表是封闭方法集合与状态机的唯一调用关系。future 与 EventLoop 的匿名完成回调是列出方法的实现细节，
只能续接本表指定的方法或 `fail`，不能形成未声明的阶段接口。

| 状态 / 流程步骤 | 仅允许的 Contract 方法调用 | 完成条件与后继 |
| --- | --- | --- |
| 分类后进入 `.handshaking` | `init`，随后 `upstream` | 创建者只传交已探测字节；`upstream` 调用实例 `paserLength`，在完整头时调用静态 `paserSocks4`。`nil` 保持读取请求；解析抛错或握手 deadline 匿名回调进入 `fail`。 |
| 握手中的校验、路由与建连 | `upstream → installWireChannel` | 仅完整且有效 CONNECT 到达这里。`installWireChannel` 一次调用 `routeTCPWire`，并按路由调用一个 Core 建连重载；同步抛错、超时、取消及建连 future 失败进入 `fail`。 |
| DIRECT 建连成功 | `installWireChannel → startTunnel` | 仅活跃的目标 Channel 可进入；`startTunnel` 的回复 future 成功后，两个方向分别排空各自余量和恢复读取。成功回复写错进入 `fail`，但不能再写 `0x5B`。 |
| PROXY 建连和启动 | `installWireChannel → Wire.start → requestWireChannel? → startTunnel` | `start` 只返回 `nil` 或一次直接写入节点的非空启动字节；前者立即调用 `startTunnel`，后者仅在其写成后调用。`start` 成功后可由 `inbound` 解码早到节点业务，但只能有界保存到启动写和成功回复都完成。Wire 抛错或启动写 future 失败进入 `fail`。 |
| `.handshaking -> .forwarding` | `upstream → outbound`；`channelRead → inbound` | 两个方向仅各自在前一批写成功后继续读。`outbound` 调用 `encodeOutbound` 后以 `requestWireChannel` 写下游；`inbound` 的 DIRECT 路径用 `respondProxyChannel` 回写，PROXY 路径调用 `decodeInbound` 并只交付非空 `InboundData.data`。这些方法的抛错或业务写 future 失败进入 `fail`。 |
| 方向 EOF | `proxyInputClosed`；`userInboundEventTriggered` / `channelInactive` | 客户端 FIN 排空后关下游输出。DIRECT 下游 EOF 排空后传播；PROXY 正常 EOF 调用 `finishInbound`，成功后排空再传播，截断错误进入 `fail`。 |
| 进入 `.closed` 后完成清理 | `fail`，然后由 accepted owner 调用 `closeConnection` | `fail` 是同步、future、EOF 和 deadline 的唯一协议失败入口；它按回复规则把原始错误交给 accepted pipeline。`closeConnection` 只做最终幂等资源清理，不写回复且不关闭 accepted Channel。 |

解析进度由实例 `paserLength` 保存已消费的头部和各个字符串扫描位置，直到得到一个完整、可构造的目标或
确定的无效输入；它不会在每个分片从头搜索 NUL。一次读取不是请求边界；完整短头与业务字节同次到达时按
上文目标流程保留有界 `clientRemainder`，实施前仍须与当前严格拒绝规则统一。余量不能借此重新开始 SOCKS
解析，也不支持同一隧道中的第二个 CONNECT。

得到目标后，`Socks4Connection` 对该 TCP 会话只调用一次 Core 路由。DIRECT 路径建立到已确定目标
或 Core/适配层控制的数值候选；PROXY 路径取得该次选择的 Wire，用其稳定的节点端点和毫秒超时建立
节点 Channel，再以业务目标调用一次 `start`。Connection 管理 Channel、连接超时、读许可和写入 future；
Wire 只产出一次可选启动字节或已验证业务数据。

PROXY 的 `start` 结果只有两种：`nil` 表示无启动写入，Connection 不等待节点首包即可调用
`startTunnel`；非空 `Data` 只能直接写节点、写成后才能调用它，且不得再次经 `encodeOutbound` 编码。
`start` 成功后，下游输入由 `inbound` 调用 `decodeInbound`：它只返回 `InboundData`，不推进启动且不产生
反向节点写入。TCP 业务地址始终是启动目标，空 `data` 不表示 EOF。启动写或成功回复尚未完成时，非空
业务按预算保存；两个方向随后各自独立排空与续读，任何一方不得等待另一方。

### 转发、背压与方向结束

进入 `.forwarding` 后，DIRECT 的业务字节直接在两端传递；PROXY 的客户端到下游方向以
`encodeOutbound(data, address: nil)` 编码，反向方向以 `decodeInbound` 解码。Wire 的 TCP 业务目标
已经由启动固定，后续编码不能另带目标或重新路由；空业务输入不产生输出也不推进 Wire 状态。Connection 每次只在本方向前一批数据成功写到
对端后续读来源 Channel，分别维持两方向顺序与背压，不能把下游原始控制字节、部分 Wire 帧或空
解码结果误当作 SOCKS4 业务数据。

客户端输入 EOF 不等于整个会话结束：组件先处理已接收的业务数据和可选启动字节，待相应下游写入
排空后再关闭下游的输出方向，并保留反向读取。下游正常 EOF 也不等于连接错误：DIRECT 排空已读业务
余量后直接向客户端传播正常输出关闭；PROXY 先将先前输入都交给 Wire 解码，再调用 `finishInbound()`
一次检查 Wire 自身协议单元是否截断。只有 PROXY 调用该方法；合法零业务流及尚未开始的可选
Wire 协议单元不得误报截断。PROXY 检查成功后排空已解码上游业务余量和客户端待写数据，才向客户端
传播正常输出关闭。该检查不验证隧道内 HTTP、TLS 或其他业务报文。若下游完整关闭没有先给出
`.inputClosed`，最终正常结束边界仍必须执行同一次检查。已经确定的网络错误或取消保留原始原因，不能
被尾部截断错误覆盖。

`finishInbound()` 成功后仅结束 Wire 的入站解码方向；仍可使用的客户端到下游方向保持可写。客户端输入
结束后，Connection 只需排空已有启动字节和业务输出，不存在额外 Wire 编码结束或解码触发的节点写入。两个方向均结束，或收到错误、取消、所属运行周期的关闭信号时，组件停止读写、关闭它拥有的下游
资源并释放 Wire 与缓冲引用；accepted Channel 的最终关闭继续归属 `MagentTCPConnection`。

### 运行周期协作

Core、路由缓存和 TCP Wire 归接入时的 Magent 运行周期，配置更新不能在活动会话中替换它们。
按 SOCKS4 SPEC 处理普通更新与优雅停止：停止新接入，允许旧会话在 30 s 宽限内排空，到期取消；
立即撤销则直接终结。运行周期负责区分这些通知及提供准入、期限和全局预算，具体服务装配仍需联动。
`Socks4Connection` 只管理自己的可取消阶段 deadline 和资源，不自建线程、Task 或服务级计数器。

## Corners

| 场景 | 目标行为或边界 |
| --- | --- |
| 逐字节、任意分片、两个 NUL 分开到达 | 解析进度单调前进；不重复扫描已消费字节，不因暂缺数据创建下游或写回复。 |
| 未知版本、端口 0、BIND、超长字段或非法目标 | 已确定非法时尽早停止解析并按已确认的版本和回复状态决定关闭或一次 `0x5B`；不等待无界输入。 |
| 缺少 NUL | 字段尚在上限内且未 EOF/超时则等待更多；超长、EOF 截断或绝对握手期限到达才按失败路径处理。 |
| 4a 标记 | 所有 `00 00 00 xx`（`xx != 00`）均是扩展标记；它不是目标 IPv4，也不能只接受 `00 00 00 01`。 |
| USERID | 允许空和非 UTF-8 原始字节；不作认证、不替代 DOMAIN、不转发为节点凭据，默认不记录内容。 |
| SOCKS4a 根点身份 | 在 §03.4 与 §05.5、Wire/模型统一前，不得声称该场景已验收；现有实现如何保留或丢弃根点都不是目标设计的许可。 |
| 完整请求后的业务尾部 | 采用上文的有界 `clientRemainder`、暂停读取、回复后先排空和 FIN 延迟传播流程；与当前严格拒绝包级规则统一前不得落地。 |
| 连接、路由或 Wire 失败 | 未开始本地成功时至多尝试一次 `0x5B`；PROXY 不降级 DIRECT，已开始成功回复后不追加失败回复。 |
| 无启动字节或节点服务器先发 | `start` 返回 `nil` 时不等首包而开始本地成功回复；`start` 成功后解出的早到节点业务仍受启动写和成功回复屏障约束。 |
| 启动写入期间的节点业务 | `start` 成功后可以解码，非空业务按 64 KiB 上游预算保存；可选启动字节写成及完整成功回复后才按序交付。 |
| 空 `InboundData.data` | 本次没有可交付业务数据，不是 EOF、不触发节点写入，也不排除后续输入。 |
| 成功回复写入期间的业务数据 | 不向客户端泄露；分别按 64 KiB / 方向的目标预算保存或暂停读取，写失败则不进入转发。 |
| 任一方向 half-close | 保留另一方向；客户端 FIN 先排空再关下游输出，PROXY 的正常下游 EOF 必须经过 `finishInbound()`。 |
| 下游截断、网络错误、取消或迟到回调 | 正常 EOF 的截断走 Wire 原始错误；已知网络错误和取消优先保留。终态后不二次回复、不重启 Wire、不恢复读写；迟到建连成功的 Channel 立即关闭。 |
| 资源与缓冲 | Wire 独立限制自身协议缓冲；Connection 及共享预算所有者执行解析、提前数据、成功屏障业务余量、I/O 队列、512/64 准入和全局预算。内存初值不能被表述为 RSS 上限。 |
| 显式不支持 | BIND、IDENT、SOCKS5 协商、UDP ASSOCIATE、IPv6 SOCKS4a 文本、二次 CONNECT、客户端凭据认证、应用层请求解释、多轮 Wire 协商及解码反向控制。 |

定向验收按 SOCKS4 SPEC 分组追踪；下表是目标行为的覆盖映射，不表示已有测试或实现已经通过。

| SPEC 分组 | 本设计要求验证的可观察行为 |
| --- | --- |
| P01..P15，L01 | SOCKS4/4a 字段、所有分片、255 个 4a 标记、header/USERID/DOMAIN 边界、根点统一结论、提前数据与二进制透明性。 |
| R01..R10，O04 | 一次路由、REJECT 零 DNS/出站、目标与节点分离、数值目标保护、精确例外不绕过 REJECT、根点及地址身份。 |
| D01..D10 | DIRECT 域名的一次解析、最多 16 个候选、候选过滤和固定数值拨号；PROXY 目标 DNS 为零及节点 DNS 分离。 |
| O01..O16 | 可控 Wire 的单次启动、可选启动字节写成、回复屏障、启动后早到业务、空解码结果、业务排序、EOF/截断、超时、实例隔离及无 DIRECT 回退。 |
| W-01..W-12、W-16..W-21、W-23、W-24、W-26 | TCP Wire 端点/毫秒超时、同目标传递、一次选择、单次启动、可选启动字节、单向解码、分片、EOF、错误与清理、隔离、运行周期、最小接口及字节流交付。UDP 专属 W-13..W-15、W-25 和 HTTP 专属 W-22 不属于本组件。 |
| L02..L12 | 两方向背压、高低水位和全局预算、FIN、半关闭期限、首次终因、取消、迟到回调、准入与服务停止。 |
| C01..C03，S01..S05 | 无效配置不发布、来源准入早于探测、自身监听与 mapped IPv6 保护、日志脱敏、节点/目标安全边界。 |
