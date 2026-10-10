# Socks5Connection Product Design

更新日期：2026-10-09。状态：**目标设计**；本文约束实施，不声明现有源码已经满足。
规范基线：[SOCKS5 v1.2.0](../SOCKS5_PROXY_SPEC.md)、[Wire v0.3.1](../WIRES_SPEC.md)、
[MODELS v0.4.3](../MODELS_SPEC.md) 与 [Architecture](../ARCHITECTURE.md)。

## Context

`Socks5Connection` 接管主 handler 已识别的 SOCKS5 accepted 会话，完成无认证方法协商，
随后建立单目标 TCP CONNECT，或控制连接所属的 UDP ASSOCIATE。

主 handler 拥有 accepted Channel 及最终关闭；本组件拥有本地回复、TCP 下游、关联的两个 UDP
Channel、可选 DNS client、客户端来源与后端登记。Core 选路和创建 Channel，Wire 只处理出站编码。
全部状态在 accepted EventLoop 推进。方法协商、命令请求、TCP relay、UDP 控制具有不同输入和结束语义。

采用现有库边界：严格请求/回复、MODELS 的 direct/proxy 路由、restart 关闭旧运行周期。
UDP 使用一个 IPv4 relay/outbound、一个 IPv6 outbound 和可选 DNS client；不创建每目标连接层或流状态机。

## Contract

### 类型、入口与方法集合

受限范围为本文件的 `Socks5Connection` 及内部 `DatagramHandler`。
主类型 **20 个方法**：1 个构造、3 个共享入口、4 个 NIO 回调、12 个私有阶段。
适配器 **4 个方法**，合计 **24 个**。不通过 extension、wrapper 或新增文件扩展集合。
修改成员时须先说明实际调用方和生命周期责任；方法数量本身不是设计目标。

声明是实现约束：参数标签、类型、返回值和 `throws` 均须按本文消费；没有默认值、重载或 `async`。
`@unchecked Sendable` 只用于 NIO handler 传递，不授权跨 EventLoop 并发访问。

```swift
/// accepted EventLoop 上的 SOCKS5 会话 owner。
internal final class Socks5Connection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
}

/// 保存当前运行周期 Core 与可选 UDP DNS 地址，不在构造时访问网络。
internal init(proxyChannel: Channel, core: MagentCore, dnsAddress: SocketAddress?)
```

构造者为 `MagentTCPConnection`，dnsAddress 来自 `MagentConfig.dnsListener`。
不存在 accept 截止点、解析线程池、预算服务或其他尚未定义的构造依赖。

共享入口精确声明引用
[ProxyConnection（2026-10-09）](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)。

| 入口 | 本组件责任 |
| --- | --- |
| `upstream` | 当前握手阶段交 `consumeHandshake`；回复/建立期间额外字节失败；TCP relay交 `relayClient`；UDP控制额外字节失败。决定客户端续读。 |
| `proxyInputClosed` | 截断握手结束；完整无余量CONNECT可等建立及成功回复后半关闭下游；UDP控制EOF结束关联。 |
| `closeConnection` | 先置终态，再幂等清理本组件TCP/UDP/DNS、在途操作、缓冲及登记；不关闭accepted、不回复、不上报清理错误。 |

TCP 回调来源为 SwiftNIO 的
[`ChannelInboundHandler`](https://github.com/apple/swift-nio/blob/21de5f08c1a166a6dd293d0e587ad977bf8dac5d/Sources/NIOCore/TypeAssistedChannelHandler.swift)，
只接收下游 TCP 事件，客户端只经共享入口交付。

```swift
/// 将下游TCP字节交给relayRemote。
internal func channelRead(context: ChannelHandlerContext, data: NIOAny)

/// 正常下游输入EOF交finishRemoteInput；其他事件向后传播。
internal func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)

/// 排除终结/取消后，补办未处理的正常EOF；不把全关闭当成可继续写的半关闭。
internal func channelInactive(context: ChannelHandlerContext)

/// 原始下游错误交会话失败边界。
internal func errorCaught(context: ChannelHandlerContext, error: Error)
```

### 私有阶段

`HandshakeMessage` 只是当前消息的解析结果，不承载网络资源或另一个状态机。

```swift
private enum HandshakeMessage {
    case greeting(methods: [UInt8])
    case request(command: UInt8, address: NetworkAddress)
    case unsupportedCommand(UInt8)
}

/// 纯解析当前阶段；不足不消费，已确定非法则抛错。
private func parseHandshake(_ input: ByteBuffer)
    throws -> (message: HandshakeMessage?, consumed: Int, minimumAdditional: Int)

/// 收集当前阶段消息并推进一次回复/建立；完整消息后的任何余量都失败。
private func consumeHandshake() throws

/// 一次选路和下游建立；成功表示DIRECT已连接或Wire启动字节已写成。
private func openTCP(target: NetworkAddress) -> EventLoopFuture<Void>

/// 校验来源提示并安装关联两个UDP Channel及可选DNS client，返回实际IPv4 BND。
private func openAssociation(hint: SocketAddress) -> EventLoopFuture<SocketAddress>

/// 串行提交当前阶段的一条完整本地回复。
private func writeReply(_ data: ByteBuffer) -> EventLoopFuture<Void>

/// 本地成功回复写成后转发客户端业务。
private func relayClient(_ data: ByteBuffer) throws

/// 接收下游业务；成功屏障前保留有限结果，之后按序交付。
private func relayRemote(_ data: ByteBuffer) throws

/// 检查正常EOF；等待启动及成功回复屏障、反向排空后再半关闭客户端输出。
private func finishRemoteInput() throws

/// 关联的单包最高边界：包级失败返回成功以续读；资源/路由/DNS失败返回原始失败。
private func handleDatagram(_ packet: AddressedEnvelope<ByteBuffer>, channel: Channel)
    -> EventLoopFuture<Void>

/// 纯解析完整本地UDP包，返回业务目标与DATA。
private static func decodeDatagram(_ data: ByteBuffer)
    throws -> (target: NetworkAddress, payload: ByteBuffer)

/// 用逻辑域名来源或实际数值端点封装回包，不为来源执行DNS。
private static func encodeDatagram(payload: ByteBuffer, source: NetworkAddress.Address) throws -> ByteBuffer

/// 固定首次会话错误及当前回复资格，然后交accepted owner终结。
private func fail(_ error: Error)
```

| 方法 | 调用方及完成责任 |
| --- | --- |
| `parseHandshake` | `consumeHandshake`；完整时报告当前消息长度，不足时consumed=0、minimumAdditional>0。不路由或访问网络。 |
| `consumeHandshake` | `upstream`；精确消息完成才发起本阶段动作，拒绝粘包与在途额外输入。方法回复写成进入请求状态，不消费预存下一阶段消息。 |
| `openTCP` | 完整CONNECT的`consumeHandshake`；未来成功后调用方写本地成功回复，失败交`fail`。 |
| `openAssociation` | 完整ASSOCIATE的`consumeHandshake`；资源先归owner，成功后调用方回复BND；关闭后迟到资源立即释放。 |
| `writeReply` | 协商、建立完成及`fail`；开始前占有阶段回复权，完成后才推进；写失败不能改写另一结果。 |
| `relayClient` | `.tcpRelay`的`upstream`；写完成后续读客户端，同步/异步失败都交会话失败边界。 |
| `relayRemote` | `channelRead`及初始化后的已读输入排空；空解码结果继续读，非空结果按屏障及背压写客户端。 |
| `finishRemoteInput` | EOF/inactive及初始化后续接已记录EOF的回调；检查最多一次，零业务也等待完整成功回复。 |
| `handleDatagram` | `DatagramHandler.channelRead`；只在关联存活时处理，一个future覆盖当前数据报及DNS/写操作；完成后该Channel才续读。 |
| `decodeDatagram` | `handleDatagram`本地分支；整包校验，零DATA合法，不产生副作用。 |
| `encodeDatagram` | `handleDatagram`回复分支；DIRECT用`.ip(实际来源)`，PROXY用Wire返回地址的`.address`。数值来源只接受IPv4/IPv6及可编码非零端口，不创建新逻辑地址、不解析DNS。 |
| `fail` | 客户端、TCP及关联资源边界；至多一次允许的失败回复，再通过accepted pipeline上报首次原始错误；UDP关联成功后不追加REP。 |

`NetworkAddress.Address` 的精确声明引用 [MODELS 地址类型](../MODELS_SPEC.md#类型构造入口与地址输出)，
不新增回复地址包装类型。Wire 方法签名直接引用 [Wire 抽象接口](../WIRES_SPEC.md#抽象接口草图)。

### 数据报适配器

```swift
/// 只适配关联现有两个UDP Channel；不持有另一份会话、路由或生命周期。
private final class DatagramHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    /// 弱引用owner；Channel角色由owner登记。
    init(owner: Socks5Connection)

    /// 交handleDatagram，操作成功后续读，失败交owner.fail。
    func channelRead(context: ChannelHandlerContext, data: NIOAny)

    /// 非清理中的关联Channel失效交owner.fail，已结束事件只继续传播。
    func channelInactive(context: ChannelHandlerContext)

    /// EMSGSIZE丢包并恢复读取；Channel不能继续服务的错误交owner.fail。
    func errorCaught(context: ChannelHandlerContext, error: Error)
}
```

### 状态及必要数据

```swift
private enum State {
    case negotiating
    case requesting
    case tcpRelay
    case udpAssociated
    case closed
}

private var state: State = .negotiating
```

| 状态 | 允许输入及离开条件 |
| --- | --- |
| `.negotiating` | 只收当前greeting；方法回复写成进入`.requesting`，无可用方法或额外字节结束。 |
| `.requesting` | 只收唯一命令；建立和回复在途仍保持此状态但不接收额外字节。CONNECT成功写成进入`.tcpRelay`，ASSOCIATE成功写成进入`.udpAssociated`。 |
| `.tcpRelay` | 单目标双向字节；单侧EOF只关闭对应输出，两方向结束或失败进入`.closed`。 |
| `.udpAssociated` | 控制TCP维持关联，两个UDP Channel处理业务；控制EOF/额外TCP字节/关联资源失败进入`.closed`。 |
| `.closed` | 只完成已提交的失败收尾及资源清理，不创建资源或恢复业务。 |

除主状态外只保存驱动这些责任的事实：当前消息缓存、各阶段回复提交权、已接受命令、两侧EOF及待写、首次终因和清理标记。
TCP持有一个下游及可选Wire；UDP持有两个Channel、可选DNS client、固定客户端端点、来源hint、后端/Wire登记及域名结果。
没有OPENING/READY/FAILED流、每目标socket、流队列或配置snapshot。

## Core Logic

### TCP 生命周期

主 handler 构造本组件并交付输入。`consumeHandshake` / `parseHandshake` 只处理当前阶段；
`writeReply(05 00)` 写成才接受命令。完整CONNECT经`openTCP`建立，启动完成后写成功回复，写成才放行业务。
任何客户端提前字节都走失败路径；节点早到输入由`relayRemote`按成功屏障处理。

`proxyInputClosed` 对完整无余量CONNECT保留EOF，待成功回复后半关闭下游输出；截断握手不建立下游。
`finishRemoteInput`记录下游EOF、检查Wire完整性，等启动写、成功回复和反向排空完成后再半关闭客户端输出。
两个方向保持独立；网络错误直接保留原始首因。

### UDP 生命周期

`openAssociation`安装两Channel及可选DNS client，回复实际BND后进入`.udpAssociated`。
`handleDatagram`对首个合法客户端包固定来源，再按包目标经Core选路、必要时用dnsListener解析。
发送使用现有Channel，并在发包前登记实际后端与DIRECT/Wire归属；回包按登记解码并封装。
同端点的归属冲突拒绝新包，不能覆盖记录或增加流层来规避。

`handleDatagram`是包级处置边界：解析/编解码错误、未知端点、容量不足和EMSGSIZE只丢包；
路由、DNS及不可继续服务的Channel失败保持原始错误，通过future交适配器调用`fail`。
纯codec不包装错误，也不负责关闭。具体报文和登记规则引用 [SOCKS5 §13–15](../SOCKS5_PROXY_SPEC.md#s13)。

### 结束与重启

`fail`固定首因及回复资格，进入终态，通过accepted pipeline交主 handler结束。
正常结束请求accepted关闭；`closeConnection`再幂等关闭本组件TCP/UDP/DNS，清空缓冲和登记。
创建中的资源一旦迟到成功立即释放，不能继续发送或回复。

restart通过旧运行周期的关闭通知走同一清理流程；本组件不保留旧关联到新周期，不订阅额外热更新或宽限服务。
背压与Wire最坏输出预留遵守 [SOCKS5 §12](../SOCKS5_PROXY_SPEC.md#s12) 和 [Wire容量契约](../WIRES_SPEC.md#缓冲和进度)。

## Corners

| 场景 | 可观察结果 |
| --- | --- |
| greeting/request任意分片 | 当前消息可以完成，不丢重复字节；下一阶段粘包或提前业务失败。 |
| 完整CONNECT后FIN，且无余量 | 可以成功回复，然后半关闭下游输出，反向仍可用。 |
| 启动/回复在途下游零业务EOF | 完整成功回复先写成，之后才关闭客户端输出。 |
| 成功回复部分写出后失败 | 不追加失败REP，唯一首因和清理。 |
| 两目标共用代理节点 | 同一实际后端及同一Wire可复用登记；DIRECT/Wire归属冲突拒绝且不覆盖。 |
| 坏包、零DATA、UDP codec错误 | 坏包单包丢弃，零DATA转发，同Wire后续合法包仍可用。 |
| 控制EOF、restart、迟到DNS或bind | 关联清理一次；迟到资源关闭，无复活或跨关联影响。 |

验收统一引用 [SOCKS5 §26](../SOCKS5_PROXY_SPEC.md#s26) 及 [Wire验收](../WIRES_SPEC.md#验收)。
本设计不新增实现之外的公共服务；规范目标及当前源码差异仍须通过对应测试验证，不能以文档同步代替运行证据。
