---
desc: SOCKS4 和 SOCKS4a CONNECT 的组件边界、固定方法与连接生命周期
updated_at: 2026-10-09
baseline: target-design
---

# Socks4Connection 产品设计

状态：目标设计，不表示实现已完成。规范基线为
[SOCKS4 SPEC v0.3.0（2026-10-09）](../SOCKS4_PROXY_SPEC.md) 与
[Wire SPEC v0.3.1（2026-10-09）](../WIRES_SPEC.md)。
范围遵循现有模型、严格请求/回复顺序和 `start` / `restart` / `close` 生命周期。

相关边界：[架构](../ARCHITECTURE.md) ·
[ProxyConnection](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection) ·
[模型](../MODELS_SPEC.md) · [路由](MagentAccessControl_Design.md)。

## Context

`MagentTCPConnection` 识别 SOCKS4 后创建 `Socks4Connection`，并继续拥有 accepted Channel。
本组件拥有一次 SOCKS4/4a CONNECT 的解析、本地回复、下游 Channel、可选独立 TCP Wire、
双向余量与清理。每条会话只有一个逻辑目标，只作一次路由和 Wire 选择。

Core 拥有规则、节点选择和下游创建；Wire 拥有出站启动和编解码，不拥有 Channel 或本地回复。
`Socks4Connection.closeConnection` 只关闭下游；accepted Channel 的最终关闭由主 handler 完成。
本组件不执行客户端认证、IDENT、BIND、UDP、业务协议解析或 PROXY 到 DIRECT 回退。

## Contract

### 受限类型与方法集合

受限类型为 `Sources/Connection/Socks4Connection.swift` 中的 `Socks4Connection`。
允许的 extension 范围为无；主声明与 extension 都不得增加未列方法、回调、重载、默认参数、
wrapper、protocol 或源文件来绕开本表。`Socks4Command` 沿用现有类型，不增加成员。
除静态完整头校验器外均为实例方法；未标 `private` 的 `func` 是 `internal`，未标
`throws` / `async` 即不具有该属性。所有调用由 accepted EventLoop 串行执行，
`@unchecked Sendable` 不放宽这一约束。

下列构造、引用入口、回调和内部阶段构成本组件的方法集合；声明及引用均为实现约束，
不通过未列 helper 扩展责任。

### 构造与入口

```swift
/// Owns one SOCKS4 session after the accepted Channel has been classified.
internal final class Socks4Connection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
  /// Declares the SwiftNIO inbound payload type for this handler.
  typealias InboundIn = ByteBuffer
}

/// Creates the connection with its accepted Channel and immutable runtime Core.
internal init(proxyChannel: Channel, core: MagentCore)
```

`MagentTCPConnection.installProxyConnection` 在 `ProxyProbe.socks4` 后调用构造，随后提交已有字节。
构造只保存 accepted Channel 与本运行周期 Core；不读写网络、不路由、不创建 Wire。

三个 `ProxyConnection` 声明、参数语义和默认 EOF 行为以
[主 handler 设计的协议及调用映射](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)
为唯一来源。本组件的实现职责如下。

| 引用入口 | 调用责任 |
| --- | --- |
| `upstream` | 请求未完成时调用 `paserLength`；完整后先确认输入恰好等于请求长度，再调用 `paserSocks4`、`installWireChannel`。同 read 余量、请求已接受但成功回复未完成时的额外字节立即 `fail`，不缓冲或转发。回复完成后才调用 `outbound`；不二次解析/路由。同步错误和写 future 失败交给 `fail`。 |
| `proxyInputClosed` | 只在**请求头未完成**时以截断错误调用 `fail`。完整无余量请求后的 FIN 记录为方向结束，等待建立与成功回复后半关闭下游输出，保留反向读取；转发阶段先排空已有上行业务。 |
| `closeConnection` | 进入终态，幂等关闭下游并释放 Wire 及用户态余量；不写回复，不关闭 accepted Channel。 |

### 下游 Channel 回调

以下四项是本类型唯一允许实现的 SwiftNIO `ChannelInboundHandler` 回调；均由所属 EventLoop
调用，不 `throws`、不 `async`。

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

| 回调 | 调用责任 |
| --- | --- |
| `channelRead` | 将下游字节交给 `inbound`。Wire 初始化前仅有界保留原始输入或不读；初始化后可解码，业务交付仍受成功回复屏障约束。同步错误和写 future 失败调用 `fail`。 |
| `userInboundEventTriggered` | `.inputClosed` 记录下游 EOF；处理先前输入后，PROXY 调用 `finishInbound`，截断错误交给 `fail`。正常 EOF 必须等启动写、完整本地成功回复及反向写队列排空后再传播，零业务流也如此。其他事件向 pipeline 传递。 |
| `channelInactive` | 正常全关闭且尚未检查 EOF 时补做同一流程；不能越过回复或业务排空。已知错误和取消不以截断覆盖。最终关闭交给 accepted owner。 |
| `errorCaught` | 将原始错误交给 `fail`，由它完成条件性失败回复后向 accepted pipeline 上报。 |

### 内部产品阶段

以下阶段不可供其他类型调用，也不再用未列 helper 分拆。同步错误原样抛到 `upstream` / `channelRead`
等调用边界后进入 `fail`；所属 future 的失败回调直接进入 `fail`。

```swift
/// Advances this connection's incremental SOCKS4 header scan without counting trailing business bytes.
private func paserLength(_ input: ByteBuffer) throws -> Int?

/// Validates exactly one complete request and returns its command and logical target.
private static func paserSocks4(_ input: ByteBuffer)
  throws -> (command: Socks4Command, address: NetworkAddress)

/// Routes the validated target and begins the selected DIRECT or PROXY downstream connection.
private func installWireChannel(command: Socks4Command, address: NetworkAddress) throws

/// Writes the local success reply before enabling tunnel reads and draining early downstream data.
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

| 方法 | 调用者与后继 |
| --- | --- |
| `paserLength` | `upstream` 的请求阶段调用。增量确定实际头部长度，`nil` 表示等待分片；业务尾部不计入头长。完整后调用静态校验器。 |
| `paserSocks4` | `upstream` 仅在完整请求且无额外字节时调用一次，校验命令与目标；不 DNS、路由或写网络。随后保存请求并调用 `installWireChannel`。 |
| `installWireChannel` | `upstream` 对有效 CONNECT 调用一次 Core 路由。DIRECT 建连后进入 `startTunnel`；PROXY 建连后调用一次 `Wire.start`，`nil` 直接进入，非空结果经 `requestWireChannel` 写成后进入。同步错误原样抛回，异步失败交 `fail`；终态的迟到成功 Channel 立即关闭。 |
| `startTunnel` | 只由建立流程调用，参数必须是活跃的非可选 Channel。通过 `respondProxyChannelOnce` 写唯一 `0x5A`；future 只在完整八字节写成后成功，随后排空已接收的下游业务并独立启用两个方向的读取。失败调用 `fail`，不能追加 `0x5B`。 |
| `fail` | 统一接收入口、NIO 和 future 的失败。保留首次原始终因并进入终态；未开始任何回复且 accepted 仍可写时，通过 `respondProxyChannelOnce` 尽力写 `0x5B`，其写完成后上报原始错误。无回复可写则直接上报；回复写错不能覆盖首因，accepted 关闭仍可触发幂等清理。 |
| `outbound` | 只由 `upstream` 的转发阶段调用。DIRECT 透明传递；PROXY 等启动写和本地回复完成后，以 `address: nil` 编码，再经 `requestWireChannel` 有序写出。同步错误原样抛回，写失败交 `fail`。 |
| `inbound` | `channelRead` 和启动后的原始余量排空调用。DIRECT 透明传递；PROXY 初始化后解码，空 `data` 不是 EOF。非空业务在屏障前有界保存，屏障后按序交给 `respondProxyChannel`；已解码余量不再次解码。错误按调用边界进入 `fail`。 |
| `requestWireChannel` | `installWireChannel` / `outbound` 写启动或已编码业务时调用，返回可排序 future；下游缺失返回 `connectionClosed` 失败 future，由调用者交 `fail`。 |
| `respondProxyChannel` | `startTunnel`、`inbound`、`respondProxyChannelOnce` 写本地回复或已解码业务时调用，返回写完成 future；不占用回复权。正常写失败交 `fail`，失败回复自身的写错保留原始终因。 |
| `respondProxyChannelOnce` | `startTunnel` / `fail` 原子取得同一个回复写权，调用 `respondProxyChannel`。回复已开始则返回 `nil`，不能重新写回复。 |

### 协作者与数据契约

Wire 的精确声明、`InboundData` 及语义引用
[Wire v0.3.1 抽象接口](../WIRES_SPEC.md#抽象接口草图)、[启动](../WIRES_SPEC.md#启动与状态转换)、
[EOF](../WIRES_SPEC.md#eof-与半关闭) 和[缓冲](../WIRES_SPEC.md#缓冲和进度)。
同一 TCP Wire 由本连接独占且串行调用；初始化前不编解码，编码还须等待启动写与本地成功屏障。
正常 EOF 先解码全部已读输入再检查一次；EOF 早于初始化时保留事实，初始化后续接检查。

Core 当前消费声明如下；不在此新增服务级 API。

```swift
/// Routes one logical TCP target and returns nil only for the selected DIRECT route.
internal func routeTCPWire(_ address: NetworkAddress) throws -> Wire?

/// Provides the runtime DIRECT TCP connection timeout in milliseconds.
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

`installWireChannel` 对同一逻辑目标调用一次 `routeTCPWire`：`nil` 为 DIRECT，非 nil 为独立 TCP
Wire；节点缺失或能力不符直接失败。DIRECT 通过逻辑目标重载建立下游；PROXY 仅用 Wire 的实际节点
端点与毫秒超时调用数值重载，不把节点重新路由，也不以节点覆盖业务目标。
DIRECT 域名解析由 Core 的 TCP 工厂负责，入口不新增 Resolver、候选竞速或安全配置。
调用方只使用完成后的下游；解析、节点端点与超时遵循
[地址与出站契约](../SOCKS4_PROXY_SPEC.md#doc-05-dns-and-addresses)。

SOCKS4/4a 输入、USERID、域名及数值地址限制引用
[入口报文](../SOCKS4_PROXY_SPEC.md#doc-02-inbound-wire-protocol) 和
[目标规范化](../SOCKS4_PROXY_SPEC.md#doc-03-incremental-parser)。目标保留根点，Core 的路由匹配视图
可以去点，Wire 收到原逻辑目标。回复为固定八字节成功 `00 5A 00 00 00 00 00 00`
或失败 `00 5B 00 00 00 00 00 00`；未知版本不写 SOCKS4 回复。

请求缓冲沿用 64 KiB 上限；隧道以有限队列和每方向有序写入实施背压。
按 [Wire 容量契约](../WIRES_SPEC.md#缓冲和进度)在调用前预留输入及最坏输出空间，
输出预留不能被后续读取占用；不增加 getter、全局配额、服务计数器或新配置。
关闭订阅沿用主 handler 的运行周期通知，本组件不新增时钟/停止 API、线程或 Task。

### 状态与生命周期事实

主状态只区分握手、业务转发和终结；解析、建连、启动与回复是方法流程，不另加阶段状态枚举。

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

| 状态 | 输入与退出条件 |
| --- | --- |
| `.handshaking` | 接受一次严格请求、建立下游；客户端额外字节失败，早到下游业务有界保留。`startTunnel` 的完整成功回复写成后进入 `.forwarding`，失败或取消进入 `.closed`。 |
| `.forwarding` | 两方向独立有序转发；单侧 EOF 只结束相应方向，两侧结束或错误/取消进入 `.closed`。 |
| `.closed` | 不再解析、建连、调用 Wire 或恢复业务；只完成已经安排的失败回复及幂等清理。 |

连接还须保存请求是否接受、回复是否提交、两侧 EOF/输出结束、正常下游 EOF 是否检查，以及首因、
是否上报和是否清理。它们是现有流程的事实，不再新增回复或方向状态枚举。
`fail` 先置终态再完成已有回复收尾；因此 `closeConnection` 不能仅因状态已关闭就跳过尚未完成的资源清理。

## Core Logic

### 请求到成功回复

```text
init → upstream → paserLength → paserSocks4 → installWireChannel
  → Core.routeTCPWire
  → DIRECT: 目标 Channel 建立
  → PROXY: 节点 Channel 建立 → Wire.start → requestWireChannel? 写成
  → startTunnel → respondProxyChannelOnce → 完整成功回复写成
  → .forwarding：排空早到下游业务，启用两方向各自的读取
```

`upstream` 在路由前拒绝完整请求后的同批余量。建立或回复期间若收到额外客户端字节也立即失败，
不保存 `clientRemainder`。下游初始化后可解码早到业务，但必须等完整成功回复后按序交付；
后到下游业务不得越过已有余量。

### 转发与方向结束

`upstream → outbound → requestWireChannel` 负责上行，
`channelRead → inbound → respondProxyChannel` 负责下行；每方向前一批写成后按额度续读，互不等待。
空解码结果继续受读许可控制，不是 EOF。

客户端 FIN：请求头不完整则 `fail`；完整无余量请求则等待建立与成功回复，再半关闭下游输出。
转发阶段先排空已收到的客户端业务。
下游正常 FIN：处理已读输入，PROXY 调用 `finishInbound`；等待启动写、完整成功回复、反向余量与
客户端写队列排空，再关闭客户端输出。零业务流也执行该屏障，另一方向继续。
全关闭但没有 `.inputClosed` 时补做同一 EOF 检查；已有网络错误或取消保留原错误。

### 失败、清理与运行周期

所有错误进入 `fail`，由它条件性写一次 `0x5B` 后向 accepted pipeline 上报原始终因。
主 handler 最终关闭 accepted 并调用 `closeConnection`；正常双方结束也由 accepted owner 完成最终关闭。
终态后迟到建连只关闭所得 Channel，迟到业务及写回调不能恢复读写或重复归还资源。

Core、缓存和 Wire 固定属于接入时的运行周期。`restart` 先完成新配置验证和新 Core 构造，
再关闭旧运行周期及旧会话；`close` 终结服务实例。活动连接不切换配置、不跨 restart 保活，
也不增加热更新、快照或优雅排空接口。

路由完全交给 Core：遵循 MODELS 的 `order`、具体性和稳定位置，只消费 `.direct` / `.proxy(UUID)`；
无端口/transport 规则或 `REJECT` 动作。失败不回退 DIRECT，不在本组件新增路由层。

## Corners

| 场景 | 必须保持的可观察行为 |
| --- | --- |
| 任意分片、边界 NUL | 按 SPEC 保留请求边界；未完整不产生 DNS/下游，已完整不二次解析或路由。 |
| 完整头同批附带业务、成功前后续字节 | 立即失败，不保存/转发客户端余量；同批余量在路由前拒绝。 |
| 完整无余量请求紧跟 FIN | 不报握手截断；先完成建立与成功回复，再结束下游输出。 |
| 根点或严格数值地址 | Wire 保留合法域名根点；数字地址不删除根点后重试，不隐式 DNS。 |
| 无启动字节、服务器先发 | 无启动字节不等首包；早到业务及正常 EOF 都不能越过成功回复屏障。 |
| 空解码结果、零业务 EOF、协议截断 | 分别继续读、屏障后传播 EOF、以 Wire 原始错误失败；不混为一类。 |
| 成功回复部分写入后失败 | 不再写失败包；首因与资源归属保持不变。 |
| 额度不足或一方向慢写 | 调用前预留输入/最坏输出，暂停对应方向；不阻塞另一方向或无界排队。 |
| 错误、取消与迟到完成竞争 | 首因一次、回复至多一次、资源归还一次；终态不恢复。 |
| PROXY 失败或安全边界拒绝 | 不改 DIRECT、不重放、不旁路 DNS；日志不记录 USERID、载荷或节点凭据。 |
| 不支持的能力 | BIND、IDENT、UDP、IPv6 字面量、第二次 CONNECT、客户端认证、业务解析、多轮 Wire 协商均不进入隐含路径。 |

验收用例以 [SOCKS4 验收](../SOCKS4_PROXY_SPEC.md#doc-10-tests-and-acceptance) 与
[Wire 验收](../WIRES_SPEC.md#验收) 为准。本组件覆盖 TCP 入口、启动、双向背压、EOF 与清理；
DNS、模型路由和运行周期与其 owner 联合验证，不把静态文档检查视为实现通过。
