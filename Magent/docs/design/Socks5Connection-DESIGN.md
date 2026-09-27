# Socks5Connection Product Design

更新日期：2026-09-27。状态：**目标设计**，依据规范定义目标行为，不以当前实现为设计依据，
不表示这些能力已经实现或通过测试。

规范基线：[SOCKS5 SPEC v1.1.0](../SOCKS5_PROXY_SPEC.md)、
[Wire SPEC v0.3.0](../WIRES_SPEC.md)，均为 2026-09-26 工作树草案。
地址模型引用 [MODELS SPEC v0.4.2](../MODELS_SPEC.md#networkaddress)。
共享入口引用 [MagentTCPConnection 的 ProxyConnection 契约](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)。

当前产品范围仅支持无入站认证。引用 SPEC 中的用户名密码认证、相关配置、服务依赖及验收要求
不纳入本设计；本轮范围调整以此为准，其余协议约束继续适用。

## Context

`Socks5Connection` 接管一条已识别为 SOCKS5 的 accepted TCP 会话，完成无认证方法协商、
CONNECT 或 UDP ASSOCIATE。CONNECT 成功后提供双向 TCP 字节流；
ASSOCIATE 成功后将该 TCP 连接保留为一个 UDP 关联的控制连接。

`MagentTCPConnection` 拥有 accepted Channel 和最终关闭；本组件拥有协议状态、本地回复、
下游 Channel、关联监听 Channel、UDP 流以及这些资源的缓冲、期限与许可。Core 负责路由、
目标解析协作、Channel 创建和 Wire 选择；Wire 负责出站协议，不处理 SOCKS5 协商或本地回复。
所有 Channel 使用服务的 EventLoopGroup，本会话的状态与 Wire 调用在 accepted EventLoop 串行推进。

一个 CONNECT 固定一个逻辑目标和一次路由。一个 UDP 关联可以有多个目标，每个流独立选择出口；
ASSOCIATE 请求中的地址只是客户端来源提示，不能作为业务目标或节点地址。客户端、业务目标、
本地 BND、DIRECT 实际目标端点和 PROXY 实际节点端点必须分开保存。

范围包括 IPv4、IPv6、域名、无认证方法 `0x00`、DIRECT / PROXY / REJECT、有界提前数据及半关闭。
不提供用户名密码认证、BIND、GSSAPI、UDP 分片重组、UDP over TCP 或 DNS 载荷嗅探。

## Contract

### 受限类型与方法数量

受限范围为 `Socks5Connection` 及其内部 `DatagramHandler`，将来均放在该 Connection 所属文件。
前者管理会话，后者仅把 NIO 数据报事件交给同一个会话 owner；不再创建 UDP 会话包装层。
主类型固定 **23 个方法**：1 个构造、3 个引用的入口、4 个 NIO 回调、15 个私有产品阶段。
`DatagramHandler` 固定 **4 个方法**；组件合计 **27 个方法**。
内部 `HandshakeMessage` 只承载协议解析事件，不增加方法或外部构造入口。

下文声明为约束性签名，代码块省略实现。没有默认参数、重载、`async` 或 actor 隔离；
仅明确标注的两个数据报 codec 为 `static`。未标 `throws` 的方法不抛错，省略返回类型表示 `Void`。
不允许在任意 extension、私有 helper、wrapper 或新增文件中扩展集合。
匿名 future / 定时器回调可保存结果、检查 generation、调用已列阶段，不另建产品入口。
需要调整集合时，先修改设计中的调用方和职责，再确认实施。

```swift
/// 管理一个 SOCKS5 TCP 会话及其可能建立的 UDP 关联。
internal final class Socks5Connection: ChannelInboundHandler, ProxyConnection {
    typealias InboundIn = ByteBuffer
}

/// 绑定 accepted Channel 和接入时的运行周期依赖；不在构造中执行网络操作。
internal init(proxyChannel: Channel, core: MagentCore)
```

构造者为 `MagentTCPConnection`。目标构造只有以上两个参数；准入、系统 Resolver、
UDP socket 工厂、时钟和预算是运行周期装配依赖，不添加入口专用 DNS 地址或测试专用默认值。
这些服务的 Swift API 尚不由本文定义，必须先在其所属契约完成装配设计。

三个客户端入口的声明和参数含义直接引用
[ProxyConnection（2026-09-27）](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)，
调用顺序引用[主 handler 调用映射](MagentTCPConnection-DESIGN.md#主-handler-到下游协议的调用映射)。
不重复声明协议，也不新增其成员。

| 引用入口 | 本组件的固定职责 |
| --- | --- |
| `upstream` | 接收全部探测余量及后续 `ByteBuffer`。`.negotiating` / `.requesting` 中按各自消息格式交 `consumeHandshake`；回复在途时保留余量，完整 CONNECT 后建立期间只保存有界业务余量。`.tcpRelay` 中交 `relayClient`；`.udpAssociated` 中额外 TCP 字节即失败；`.closed` 不接收新工作。完整 ASSOCIATE 后即使回复尚未写成，也不接受额外 TCP 字节。负责客户端续读许可。 |
| `proxyInputClosed` | 先记录 EOF 并按序消费已保存的协商字节；输入截断不创建出站，完整 CONNECT 可以完成建立，再排空业务并半关闭下游输出；UDP 控制 EOF 立即终止整个关联。提供专属实现，不使用默认整连接关闭代替 TCP 半关闭。 |
| `closeConnection` | 先置终态、失效所有回调，再清理本组件的 TCP/UDP Channel、流、缓冲、期限及许可；不写回复、不关闭 accepted Channel、不再次上报清理错误。 |

TCP 的四个回调来自 SwiftNIO 的
[`ChannelInboundHandler`](https://github.com/apple/swift-nio/blob/21de5f08c1a166a6dd293d0e587ad977bf8dac5d/Sources/NIOCore/TypeAssistedChannelHandler.swift)。
它们只接收下游 TCP Channel 的事件，客户端输入只能经上述共享入口交付。

```swift
/// 接收下游 TCP 字节，按 DIRECT 或 Wire 路径交给反向 relay。
internal func channelRead(context: ChannelHandlerContext, data: NIOAny)

/// 在下游输入 EOF 时执行协议完整性检查；其他事件继续传播。
internal func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)

/// 处理下游全关闭，补办尚未处理的正常 EOF，并保持终结幂等。
internal func channelInactive(context: ChannelHandlerContext)

/// 将下游 TCP 原始错误交给唯一会话失败边界。
internal func errorCaught(context: ChannelHandlerContext, error: Error)
```

| 回调 | 后继和错误责任 |
| --- | --- |
| `channelRead` | 调用 `relayRemote`；Wire 尚未初始化时只保留有界原始输入。同步错误交 `fail`。 |
| `userInboundEventTriggered` | `.inputClosed` 调用 `finishRemoteInput`；其他事件向后传播。 |
| `channelInactive` | 先排除已终结或取消路径；未见正常 EOF 时调用 `finishRemoteInput`。全关闭不伪装成仍可继续写的半关闭。 |
| `errorCaught` | 调用 `fail`，不能先把 Wire 错误改成正常 EOF。 |

### 15 个内部产品阶段

以下内部事件只表示当前入站阶段的解析结果，属于本组件；不取代 NetworkAddress 或共享协议。

```swift
/// 保存已完整校验的阶段输入；协议字节和业务余量不混在同一个事件中。
private enum HandshakeMessage {
    case greeting(methods: [UInt8])
    case request(command: UInt8, address: NetworkAddress)
    case unsupportedCommand(UInt8)
}
```

```swift
/// 按当前读取阶段纯解析输入，返回完整消息或最少缺失字节数，不执行会话副作用。
private func parseHandshake(_ input: ByteBuffer)
    throws -> (message: HandshakeMessage?, consumed: Int, minimumAdditional: Int)

/// 增量消费当前协商阶段，保留后续阶段及业务字节，并等待本阶段回复屏障。
private func consumeHandshake() throws

/// 为唯一 TCP 目标完成路由、建连及可选 Wire 启动，成功时下游已经可用。
private func openTCP(target: NetworkAddress) -> EventLoopFuture<Void>

/// 验证客户端来源提示并绑定关联中继；返回可向控制客户端发布的实际 BND。
private func openAssociation(hint: SocketAddress) -> EventLoopFuture<SocketAddress>

/// 串行写出当前协商阶段的一条完整本地回复，完成后才允许交出写权。
private func writeReply(_ data: ByteBuffer) -> EventLoopFuture<Void>

/// 在 TCP 成功回复完成后编码或透明发送客户端业务字节。
private func relayClient(_ data: ByteBuffer) throws

/// 解码或透明接收下游业务，在回复屏障前保留、之后有序交付。
private func relayRemote(_ data: ByteBuffer) throws

/// 对正常下游 EOF 恰好执行一次 Wire 完整性检查及反向排空。
private func finishRemoteInput() throws

/// 根据登记的本地或后端 Channel 身份处理一个完整 UDP 数据报。
private func handleDatagram(_ packet: AddressedEnvelope<ByteBuffer>, channel: Channel) throws

/// 纯解析一份完整 SOCKS5 UDP 报文，返回逻辑目标和原始 DATA。
private static func decodeDatagram(_ data: ByteBuffer)
    throws -> (target: NetworkAddress, payload: ByteBuffer)

/// 为已确认的业务来源及 DATA 生成一份完整本地 UDP 回复。
private static func encodeDatagram(payload: ByteBuffer, source: NetworkAddress) throws -> ByteBuffer

/// 对当前关联的一个新目标建立唯一流；就绪前不发送业务包。
private func openFlow(target: NetworkAddress) -> EventLoopFuture<Void>

/// 经已就绪流发送一个 DATA；PROXY 每次编码均携带该包的逻辑目标。
private func sendDatagram(_ payload: ByteBuffer, target: NetworkAddress) throws

/// 清理一个流；失败时保留有界冷却记录，正常结束不影响关联内其他流。
private func closeFlow(target: NetworkAddress, error: Error?)

/// 保留首次原始错误，按协商阶段决定回复，再交 accepted owner 终结会话。
private func fail(_ error: Error)
```

| 方法 | 调用方 | 完成含义及后继 |
| --- | --- | --- |
| `parseHandshake` | `consumeHandshake` | 只读取当前 greeting/request 阶段与输入，返回确定性结果；不改变会话、访问网络或输出回复。完整结果 consumed 为本消息长度、minimumAdditional=0；不足为 nil、consumed=0、minimumAdditional>0；已确定非法则抛错。BIND/未知命令在固定头已可判断时返回独立事件，不等待无用地址体。 |
| `consumeHandshake` | `upstream`、方法选择回复成功回调 | 调 `parseHandshake` 后只消费其 reported 长度并推进当前阶段；不足则等待，不丢余量。客户端提供 `0x00` 才经 `writeReply` 选择该方法，写完直接进入 request；完整请求只进入一次 `openTCP` 或 `openAssociation`。 |
| `openTCP` | `consumeHandshake` | future 成功表示 DIRECT 已连接，或 Wire `start` 成功且启动字节已写完。调用方写 CONNECT 成功回复，写完才进入 relay。 |
| `openAssociation` | `consumeHandshake` | hint 是数值客户端来源，不是业务目标。future 成功仅表示关联监听可用；调用方写 ASSOCIATE 成功回复后开放本地 UDP。此时不路由、不创建业务 Wire 或 TCP。 |
| `writeReply` | 协商推进、TCP/关联就绪回调、`fail` | 一阶段至多一条回复；future 成功才进入下阶段。开始结果回复前即占有提交权，部分写失败不得改写另一结果回复。 |
| `relayClient` | `upstream`、TCP 就绪后余量排空 | DIRECT 透明写；PROXY 编码后写。写完成控制续读；同步错误向边界抛出，异步写错交 `fail`。 |
| `relayRemote` | `channelRead`、初始化后的原始输入排空 | Wire 解码结果可能为空；只交付业务字节。成功回复前的业务余量有界保存，写客户端完成后才继续本方向读取。 |
| `finishRemoteInput` | TCP EOF / inactive 回调；初始化后续接已记录 EOF 的出站回调 | 处理完已读数据后检查 Wire，成功才传播正常 EOF；排空客户端写队列后半关闭输出，另一方向继续。重复通知不重复检查。 |
| `handleDatagram` | `DatagramHandler.channelRead` | 只在 `.udpAssociated` 处理业务数据报。本地包完成来源、完整性、协议和目标基础安全校验后才固定来源端口，再选择流。后端包先核实登记端点，再按登记 Wire 解码；不按最近一次目标猜路由。 |
| `decodeDatagram` | `handleDatagram` 的本地分支 | 无网络或会话副作用；不完整、非法或超长即抛错，UDP 不返回 need-more。零 DATA 合法。 |
| `encodeDatagram` | `handleDatagram` 的回包分支 | 保留来源地址身份；完整封装超过单包上限则失败，禁止截断或拆包。 |
| `openFlow` | `handleDatagram`，仅新目标或冷却到期后的新包 | 每次建立 attempt 有独立 generation；同目标并发到包加入有限队列，不重复建立。成功按序调用 `sendDatagram`；失败调用 `closeFlow`，不重放旧包。 |
| `sendDatagram` | READY 流的收包路径、OPENING 队列排空 | 恰好一次数据报写入；DIRECT 只发 DATA，PROXY 逐包编码。坏包丢弃；实际后端不可恢复错误只终止所属流。 |
| `closeFlow` | 流建连/写入失败、流空闲期限、关联清理 | 停止新工作并释放该流资源一次；独立包格式/完整性校验错误不能调用它使流进入冷却。 |
| `fail` | 客户端/TCP 边界、关联监听错误、会话期限 | 统一选择阶段回复，等待写完或 1 s 回复期限，再通过 accepted pipeline 上报原始错误。错误回复写失败不覆盖首因；已进入 relay 不再发送 REP。 |

### 数据报回调适配

```swift
/// 仅适配完整 UDP 消息；关联状态与错误范围的最终判断仍属于 Socks5Connection。
private final class DatagramHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    /// 弱引用所属会话；Channel 的角色与流身份由 owner 登记。
    init(owner: Socks5Connection)

    /// 将完整数据报交给 owner，并在此边界区分坏包丢弃与所属资源失败。
    func channelRead(context: ChannelHandlerContext, data: NIOAny)

    /// 通知 owner 当前 UDP Channel 失效；已终结或旧 generation 的事件忽略。
    func channelInactive(context: ChannelHandlerContext)

    /// 将 UDP 传输错误交 owner：本地监听失败结束关联，后端失败只结束所属流。
    func errorCaught(context: ChannelHandlerContext, error: Error)
}
```

NIO 调用后三项。创建本地监听或流后端时，分别安装独立 handler，并在启用读事件前登记
Channel 身份、角色、实际后端、目标及 generation。handler 无独立任务、路由状态或清理流程；
按登记调用 `handleDatagram`、`closeFlow` 或 `fail`，释放后收到事件不重建资源。

UDP 传输依赖必须保证回调中的 envelope 是完整原始数据报，或在交付前明确报告并丢弃截断包；
接收能力须覆盖允许的完整报文。不能仅凭“返回了 ByteBuffer”或长度恰等于接收缓冲就认为未截断。
此要求按 [SOCKS5 SPEC §23.3](../SOCKS5_PROXY_SPEC.md#s23) 验收，平台适配 API 不在本设计伪造。

### 状态契约

SOCKS5 的边界来自两次不同的协议交换和两种业务模式：先读取方法列表并回复 `05 METHOD`，
再读取命令及目标并回复带 BND 的结果。两类输入格式和失败回复不同，因此分别定义协商与请求状态；
请求成功后，TCP 字节流与 UDP 关联各有自己的资源及结束语义。由此得到以下 **5 个状态**。
建连、Wire 启动和回复写入仍由已有方法推进，不另建状态。

```swift
/// 按 SOCKS5 消息格式及后续业务模式分派输入和结束事件。
private enum State {
    case negotiating
    case requesting
    case tcpRelay
    case udpAssociated
    case closed
}

/// 构造后只接受 SOCKS5 协商，不处理业务转发。
private var state: State = .negotiating
```

`State` 是本类型内部的私有数据枚举，不增加方法。已接受的命令决定唯一后继：CONNECT 对应
`.tcpRelay`，UDP ASSOCIATE 对应 `.udpAssociated`；运行期按状态分派，不靠统一 forwarding 再判断命令。

| 状态 | 允许的行为 | 离开条件与负责方法 |
| --- | --- | --- |
| `.negotiating` | `consumeHandshake` 只解析 greeting；提供 `0x00` 时经 `writeReply` 选择无认证，回复在途时仅保存后续字节。 | `05 00` 完整写成后进入 `.requesting`，继续消费已保存余量；无可用方法回复 `05 FF` 后结束。 |
| `.requesting` | `consumeHandshake` 只解析 command / address；完整合法请求只调用一次 `openTCP` 或 `openAssociation`，经 `writeReply` 回复命令结果。 | CONNECT 成功回复完整写成进入 `.tcpRelay`；ASSOCIATE 成功回复完整写成进入 `.udpAssociated`；请求失败映射 REP 后结束。 |
| `.tcpRelay` | `upstream` / `relayClient` 与 TCP `channelRead` / `relayRemote` 转发单一目标字节流；持有一个选定下游及可选 TCP Wire，不建立 UDP 关联。 | 单侧 EOF 只排空并半关闭对应输出，状态不变；两方向结束、不可恢复错误或取消进入 `.closed`。 |
| `.udpAssociated` | accepted TCP 仅维持关联，`handleDatagram` 经本地 UDP 中继处理数据报，每目标流独立持有后端及可选 UDP Wire。 | 控制 TCP EOF、额外 TCP 数据、关联监听失败、关联到期或取消进入 `.closed`；坏包或单流失败不结束关联。 |
| `.closed` | 停止新的 TCP / UDP 业务、建连和流创建；只完成已安排的失败回复及幂等清理。 | 终态，不重新协商或重建关联。 |

主状态只允许下图的转换，由 accepted EventLoop 串行推进。两个业务模式不能互换，也不能返回协商。

```text
.negotiating -- 05 00 写成 --> .requesting
                                  +-- CONNECT 回复写成 ----> .tcpRelay -------> .closed
                                  +-- ASSOCIATE 回复写成 --> .udpAssociated --> .closed
任意未关闭状态 -- 失败 / 关闭 ------------------------------------------------> .closed
```

进入 `.tcpRelay` 前，DIRECT 已连接或 TCP Wire 已完成启动写入；进入 `.udpAssociated` 前，只需
本地中继就绪且 BND 已成功回复，不要求任何业务目标流存在。单流回收后仍可保持 `.udpAssociated`。

| 必须保存的事实 | 初值与约束 |
| --- | --- |
| 已接受请求 | 初始无；`.requesting` 内完成校验后固定命令与目标，只接受一次。方法选择完成由进入 `.requesting` 表达，不再保存另一份“已选定方法”标记。 |
| 方法回复 / 命令回复是否已提交 | 初始均为否，各有一次提交权；写前占用，部分写失败不恢复。不能用全会话“一次回复”替代这两个事实。 |
| 两侧 EOF、正常下游 EOF 是否已检查、两侧输出是否已关闭 | 初始均为否；CONNECT 独立处理方向排空，UDP 不执行 TCP relay 半关闭。 |
| UDP 来源及流登记 | 初始无关联、无固定客户端端口、无流；合法 hint 或首个通过校验的数据报固定来源，之后不能重绑。每流的队列、后端、Wire 与回调属于同一次建立 attempt。 |
| 首次错误、是否已上报、是否已清理 | 初始 nil / 否 / 否；会话首因与单流失败分开，终因上报及清理各一次。 |

UDP 流保留必要的“建立中、可用、失败冷却”区别：建立中只有限排队，可用才发送，失败清理后
冷却 1 s，再由新包触发新 attempt；移除记录即结束该流，不再增加 CLOSED 状态。旧 attempt 的
回调不能操作同目标的新流；坏包只丢包，不改变可用流或会话的生命周期。

方法回复写入期间收到 EOF，应先处理已保存的 request；完整 CONNECT 可继续建立，截断请求
不建出站，ASSOCIATE 不继续关联。Wire 初始化前收到 EOF 时记录并延后检查，不能漏检或重复检查。
`fail` 固定首因及允许的阶段失败回复后进入 `.closed`，限时完成该回复并上报；后续业务回调只释放
资源。accepted owner 的 `closeConnection` 仍执行尚未完成的清理，不能因 state 已 closed 而漏清理。
服务宽限期内保留 `.tcpRelay` 或 `.udpAssociated` 以排空既有工作，但停止新关联 / 新流；到期才结束会话。

### 数据、协作者与失败所有权

| 数据 / 资源 | 固定约束 |
| --- | --- |
| 会话状态 | `.negotiating` / `.requesting` 区分两种协议消息与回复；`.tcpRelay` / `.udpAssociated` 区分业务模式；`.closed` 终结。不存在认证阶段。 |
| 输入和回复权 | 增量消费位置、后续阶段余量、每阶段回复提交标记分开；不是整个 SOCKS 会话只允许写一次回复。 |
| TCP | 一个逻辑目标、一次决策、可选独立 Wire、获胜下游及在途候选、双向 EOF/待写状态；启动及结果回复各有独立屏障。 |
| UDP 关联 | 控制 peer、来源 hint、已固定客户端端点、本地 BND、流集合、关联期限及取消 generation。关联不通过端口 53 或载荷内容识别业务。 |
| UDP 流 | 身份包含关联、规范目标、决策、节点及配置 generation；建立中 / 可用 / 失败冷却；移除记录表示结束。对外 `target` 参数只索引本关联内已固定决策的流，不能把同目标的旧 attempt 回调应用到重建后的流。 |
| 后端登记 | 实际 Channel + SocketAddress → 所属流及 Wire。DIRECT 保存唯一数值目标；PROXY 保存 Wire 的真实节点端点。 |
| 终因和额度 | 首个会话终因、每流终因分开；许可由唯一 owner 释放一次，DNS 真实工作槽必须等底层任务实际退出。 |

Wire 的精确声明直接引用 v0.3.0 的[抽象接口](../WIRES_SPEC.md#抽象接口草图)、
[TCP 启动](../WIRES_SPEC.md#启动与状态转换)、[EOF](../WIRES_SPEC.md#eof-与半关闭)及
[UDP 契约](../WIRES_SPEC.md#udp-契约)，不复制一份协议。
`openTCP` 消费端点和毫秒超时、单次 `start`；`relayClient` 以 nil 地址编码；
`relayRemote` 解码；`finishRemoteInput` 仅在正常 TCP EOF 调用 `finishInbound`。
`sendDatagram` 逐包传入目标，回包使用登记的 Wire 解码。UDP 正常路径不调用
`start`、`finishInbound` 或 `getTimeout`，也不创建 TCP 控制链路。

本设计选择 **每流独立 UDP Wire**，所有调用在本会话 EventLoop 串行；不启用跨关联共享。
Wire 解码空 TCP data 不产生写入或 EOF；空 UDP data 仍要封装一份零载荷 SOCKS5 数据报。
纯解析/codec 方法抛原始错误；回复、记录和关闭由对应会话或数据报最高边界决定。

### 外部契约需要联动的部分

除开篇明确移除的入站认证能力外，以下仍是目标设计的实施前置条件：

| 依赖 | 规范差异及必须达到的目标 |
| --- | --- |
| Core / 路由模型 | SOCKS5 §08 要求按配置顺序首条命中、端口/transport 条件和 REJECT；MODELS v0.4.2 的 [ProxyRule](../MODELS_SPEC.md#proxyrule) 按 order/具体性选择，且 Decision 仅 direct/proxy。需联动修订；Connection 不私建另一套规则引擎，也不能把 REJECT 映射成 DIRECT。 |
| 构造与运行周期 | 上层目标设计使用本文的两参数构造；系统解析器由 §09 的运行周期依赖装配，不增加入口 DNS 参数。共享三个方法保持不变。 |
| 配置与停止 | SOCKS5 §19.5 要求 accept 时固定配置，热更新保留旧会话；§19.7 要求排空。运行周期 Core 可承载固定配置，但上层必须允许它活到所属会话排空，区分普通更新、受控重启和立即撤销。 |
| 服务依赖 | 按当前范围消费 §19、20、23 的真实 DNS 工作池、全局预算、时钟、UDP 端口分配及可取消工厂；不装配入站凭据验证器或认证配置。来源准入与目标安全检查独立执行。测试使用与生产相同的装配入口。 |

## Core Logic

### 建议的方法调用流程图

方法名沿用 `Contract`；方括号表示状态或流程条件；只有带点名称表示生命周期状态，不新增方法。箭头跨越“写成/就绪”时必须等待
future 成功。协商只包含 greeting 和 request，不存在认证子流程。

```text
MagentTCPConnection -> Socks5Connection.init(proxyChannel:core:)
  -> upstream(context:data:)
       +-- [.negotiating / .requesting] -> consumeHandshake() -> parseHandshake(input)
       |               +-- [不足] -> [保留输入, 等下一次 upstream]
       |               +-- [greeting 包含 0x00] -> writeReply(05 00)
       |               |                           -> [写成, 进入 .requesting]
       |               |                           -> consumeHandshake()
       |               +-- [无可用方法] -> fail(error) -> [失败路径写 05 FF 后关闭]
       |               +-- [CONNECT] -> openTCP(target:) -> [TCP 下游就绪]
       |               |                                  -> writeReply(REP=00)
       |               |                                  -> [写成: .tcpRelay]
       |               +-- [UDP ASSOCIATE] -> openAssociation(hint:)
       |               |                       -> [绑定本地 UDP Channel]
       |               |                       -> DatagramHandler.init(owner:)
       |               |                       -> [登记身份并安装 handler]
       |               |                       -> [future 返回实际 BND]
       |               |                       -> writeReply(REP=00)
       |               |                       -> [写成: .udpAssociated]
       |               +-- [非法请求/不支持命令] -> fail(error)
       +-- [TCP 建立/回复中] -> [有界保存客户端余量]
       +-- [.tcpRelay] -> relayClient(data) -> [DIRECT 直写 / Wire.encodeOutbound 后写下游]
       +-- [.udpAssociated 又收到 TCP 字节] -> fail(error)

openTCP(target:) -> [Core 一次路由与建连]
  +-- [DIRECT 已连接] -> [TCP 下游就绪]
  +-- [PROXY 节点已连接] -> Wire.start(handshake: target)
                             +-- nil -> [TCP 下游就绪]
                             +-- 启动字节 -> [直接写节点并写成] -> [TCP 下游就绪]

TCP 下游 channelRead(context:data:) -> relayRemote(data)
  -> [DIRECT 直通 / Wire 已初始化后 decodeInbound]
       +-- [空业务结果] -> [等待后续输入, 不是 EOF]
       +-- [启动写/成功回复尚未写成] -> [有界保存已解码业务]
       +-- [屏障已完成] -> [有序写客户端, 写成后续读下游]
```

两个 TCP 方向在成功回复完成后独立排空余量；已解码余量直接写客户端，不重复解码。
UDP 关联成功只开放本地中继，业务流仍由有效数据报按需建立：

```text
DatagramHandler.channelRead(context:data:) -> [.udpAssociated] -> handleDatagram(packet, channel:)
  |
  +-- [本地中继收到客户端包]
  |    -> [关联、来源与完整包检查] -> Self.decodeDatagram(data)
  |    -> [目标基础安全检查, 必要时固定客户端端口]
  |         +-- [READY 流] -> sendDatagram(payload, target:)
  |         +-- [OPENING 流] -> [有限排队; 满则丢新包]
  |         +-- [新流/冷却已过的新包] -> openFlow(target:)
  |              -> [Core 路由, 创建并登记专属 UDP 后端]
  |              -> DatagramHandler.init(owner:)
  |                   +-- [就绪] -> sendDatagram(排队 payload, target:)
  |                   +-- [失败] -> closeFlow(target:error:)
  |
  +-- [后端 Channel 收到回复]
       -> [先核对登记的 Channel/端点/流/Wire]
       -> [DIRECT 取得来源与 DATA / PROXY Wire.decodeInbound]
       -> Self.encodeDatagram(payload:source:) -> [写本地中继, 发给固定客户端]

sendDatagram(payload, target:)
  +-- [DIRECT] -> [只把 DATA 写到该流固定数值端点]
  +-- [PROXY] -> Wire.encodeOutbound(payload, address: target) -> [写登记的节点端点]

[包格式/完整性/来源错误] -> [DatagramHandler 边界丢当前包, 不关闭整个关联]
DatagramHandler.channelInactive(context:) / DatagramHandler.errorCaught(context:error:)
  +-- [已终结或旧 generation] -> [忽略]
  +-- [后端资源失败] -> closeFlow(target:error:) -> [只清理该流, 有界冷却]
  +-- [本地关联监听失败] -> fail(error)
[单流空闲到期] -> closeFlow(target:error: nil)
```

UDP 图中的 Wire 编解码均按完整单包进行；不经过 TCP 的 `start` 或 `finishInbound`。
同步解析错误在所属入口处理，传输错误按资源归属处理，不能统一扩大为关联失败。

```text
proxyInputClosed(context:)
  +-- [方法回复在途] -> [记录 EOF, 写成后消费已保存请求]
  +-- [协商字节截断] -> fail(error) -> [不建出站]
  +-- [完整 CONNECT / .tcpRelay] -> [排空上行后半关闭下游输出, 反向继续]
  +-- [ASSOCIATE 建立/回复 / .udpAssociated] -> [.closed, 停止关联并请求 accepted 结束]

TCP userInboundEventTriggered(.inputClosed) / channelInactive([正常且未处理 EOF])
  -> finishRemoteInput() -> [PROXY: Wire.finishInbound(); DIRECT: 跳过]
       +-- [成功] -> [排空反向写, 半关闭客户端输出]
       +-- [抛错] -> [所属 NIO 回调] -> fail(error)

TCP errorCaught(error) / [入口原始错误、会话 future 失败、会话期限到达]
  -> fail(error) [.closed, 完成本次错误收尾]
       +-- [当前阶段允许失败回复且可写] -> writeReply(该阶段失败字节)
       |                                  -> [写完或回复期限到达: REPORT]
       +-- [已提交结果回复/relay/不可写] -> [REPORT]
[REPORT] -> accepted.pipeline.fireErrorCaught(原始错误)
  -> MagentTCPConnection.errorCaught -> closeConnection(error:)
[正常结束后 accepted 失效] -> MagentTCPConnection.channelInactive -> closeConnection(error: nil)

closeConnection(error:) -> [.closed, 执行尚未完成的清理并停止新工作]
  -> [清理 TCP 下游及在途操作 / 对所有 UDP 流调用 closeFlow(target:error:)]
  -> [释放 UDP 本地监听、缓冲、期限和许可; 不反向关闭 accepted]
```

### 协商和 TCP 建立

1. 从全部探测余量开始读取 greeting；完整方法列表包含 `0x00` 才回复 `05 00`，写完直接进入 request。
   只提供 `0x02`、其他方法或空方法列表时回复 `05 FF` 后关闭；同时提供 `0x00` 和 `0x02` 时仍选
   `0x00`。不进入 RFC 1929 子协商，也不发送 `01 00` / `01 01`。同批后续字节原样保留。
2. request 检查 VER、RSV、CMD、ATYP、地址和端口；支持完整 IPv4、IPv6 和合法域名。
   CONNECT 端口必须非零；BIND/未知命令及禁用 UDP 返回 `REP=07`。
3. 目标基础安全校验后只路由一次。DIRECT 域名由受控系统 Resolver 使用绝对名称语义解析，
   对候选再次安全检查后按数值端点拨号；PROXY 和 REJECT 不解析业务域名，不读取域名的
   `NetworkAddress.socketAddress` 触发隐式 DNS。Wire 保留目标身份与域名根点。
4. `openTCP` 完成后，DIRECT 成功回复报告实际下游本地端点，PROXY 报告 `0.0.0.0:0`。
   结果回复完整写完后，两个方向独立排空余量、恢复读取。成功不代表远端应用已完成请求。

Wire 启动字节直接按序写给节点，不重复编码。初始化后可解码早到节点字节，但解码后的业务要等待
启动写入和本地成功回复两个屏障。客户端 CONNECT 后同批业务也只保存，不提前发送或一律拒绝。
正常 EOF 先排空所属方向；PROXY 的反向 EOF 还须通过 Wire 完整性检查。另一方向继续到 EOF
或半关闭截止点，网络错误/取消不通过完整性检查替换原始终因。

### UDP 关联和逐包处理

`openAssociation` 把未指定 IP 解释为控制 peer；非零 IP 必须等同该 peer（包括映射 IPv6 规范化），
域名 hint 拒绝。绑定一个属于该控制连接的中继端口，默认范围 49152..65535，BND 是客户端实际
可达的本地地址和端口，不能发布通配地址。成功回复前不转发 UDP；后端资源由首个有效业务包按需创建。

本地包依次检查关联存活、来源 IP/已固定端口、截断和大小、RSV/FRAG、目标字段及基础安全策略。
端口未知时，只有通过这些检查的首包才能固定来源端口；之后不自动换端点。FRAG 非零即丢弃。
来源固定后对目标路由，已有 READY 流直接发送，新流进入 OPENING 并有限排队。

DIRECT 流为目标独占一个连接到获准数值端点的 UDP Channel；域名最多选一个候选，不复制首包竞速。
PROXY 流独占一个后端 Channel 和 UDP Wire。实际后端必须先登记才能发送；回包先匹配登记端点，
再解码出业务来源与 DATA，并生成新的本地 SOCKS5 UDP 头，只发给固定的客户端来源。

非法单包、未知后端、Wire 完整性校验/解码坏包、封装超长或 EMSGSIZE 只丢该包并计数。后端不可恢复失败清理该流、
丢弃旧排队包并进入 1 s 冷却；冷却结束后仅新包可触发重建。绝不把 UDP 失败写成额外 TCP REP。

### 期限、背压与清理

精确默认值及共享额度引用 [SOCKS5 §19](../SOCKS5_PROXY_SPEC.md#s19)；实施必须覆盖完整表。
握手从 accept 起 10 s，出站总期限 25 s，DNS 5 s、DIRECT 单候选 10 s、Wire 启动 10 s 均受总期限
约束；回复 1 s、TCP 空闲 900 s、半关闭排空 30 s。UDP 关联/流空闲分别 300 s/60 s。

32 KiB 读取块、64 KiB early data、每个 TCP 方向 256 KiB 是 Connection 所有数据的上限，含在途写；
停止续读必须在额度耗尽之前生效。每 UDP OPENING 流最多 8 包且 128 KiB，任一耗尽即 drop-newest；
完整 UDP 报文最多 65507 字节。单关联最多 32 流，全局关联 128、流 512；与全局会话、socket、DNS、
64 MiB 缓冲预算同时约束。Wire 内部协议缓冲由其独立限制，不把 Connection 预算说成进程 RSS 上限。

关联只有成功处理的有效 UDP 活动刷新空闲期限，TCP 控制存活、坏包、REJECT 或限流丢包不刷新。
控制 EOF、异常额外 TCP 数据或关联到期触发关联结束；单流到期只清理单流。清理先阻止新工作，再清理
所有后端流和待处理操作，最后释放本地关联监听；终态后迟到 Channel 立即关闭，许可只释放一次。
正常会话结束通过 accepted Channel 的 NIO 关闭流程通知主 handler，由其调用 `closeConnection`；
错误通过 `fail` 上报。`closeConnection` 本身不再关闭 accepted Channel。

停机先禁止新关联/新流，已有 TCP 和已有 UDP 流可在 30 s 宽限内排空，到期统一取消。
该通知由运行周期依赖订阅提供；不为此给 `ProxyConnection` 增加第四个方法。

## Corners

### 失败和边界

本地错误精确映射以 [SOCKS5 §18](../SOCKS5_PROXY_SPEC.md#s18) 为准。
协商无可用方法与命令失败是不同回复阶段；前者回复 `05 FF`，不能统一发送 `REP=01`。
请求阶段的拒绝为 02、实际网络不可达 03、DIRECT 主机解析失败 04、拒绝连接 05、实际 TTL 语义才用 06、
不支持命令 07、地址类型/格式问题 08；普通超时及无法细分的后端失败用 01，不猜测不存在的原因。

| 场景 | 必须观察到的结果 |
| --- | --- |
| 每个切分点、greeting/request 粘包 | 消费边界一致，回复不乱序，余量只交付一次；不足与非法明确区分。 |
| 方法回复在途且 request 已到达 | 保持 `.negotiating` 并缓存 request；只有 `05 00` 写成才进入 `.requesting`，不能以数据已齐为由提前路由。 |
| 协商失败与命令失败 | 前者使用 `05 FF`；进入 `.requesting` 后使用对应 REP。不能在方法回复部分写出后再提交命令失败响应。 |
| 仅提供 `0x02` / 同时提供 `0x00` 与 `0x02` | 前者 `05 FF` 后关闭且不建出站；后者选择 `0x00`，不执行凭据子协商。 |
| 已完整 CONNECT 后 FIN | 可以完成建立和成功回复，排空早到字节后只关闭下游写方向。 |
| `.tcpRelay` 与 `.udpAssociated` 收到控制 TCP EOF | 前者排空上行并保留反向数据；后者结束整个关联并清理所有 UDP 流，不能共用同一种半关闭行为。 |
| ASSOCIATE 成功后尚无 UDP 包，或最后一个流已回收 | 仍保持 `.udpAssociated`；关联存活不依赖至少一个业务流存在。 |
| 握手完成后再次发送 SOCKS 命令 | `.tcpRelay` 中按原目标业务字节处理；`.udpAssociated` 中作为非法额外 TCP 数据失败，均不重新协商或切换模式。 |
| 两个 UDP 目标或两个关联使用同一节点 | 各自后端与 Wire 登记稳定，回包不串流；清理一个不影响其他。 |
| 零 DATA、恶意长度、截断、未知来源 | 零 DATA 保留；坏包整包丢弃，不跨包补齐、不学习攻击者来源。 |
| 成功回复部分写出后失败 | 直接结束，不再写失败 REP，也不将节点业务插入回复中间。 |
| PROXY 域名/失败 | Resolver 调用为零；不更换目标、不回退 DIRECT、不重放业务。 |
| 超时、关闭和迟到拨号竞态 | 不重复回复、不复活旧流、不重复释放；底层仍运行的 DNS 占用真实工作槽。 |

### 验收归属

以下是实施验收要求，不是本次文档工作的测试结果。

| 规范验收组 | 本设计负责的边界 |
| --- | --- |
| [SOCKS5 §26 P / R / D](../SOCKS5_PROXY_SPEC.md#s24) | 无认证方法协商、增量输入、目标来源、每目标路由和 DNS 调用断言；认证成功/失败用例以本节不支持方法的拒绝用例替代。 |
| 同节 O01–O16、Wire §验收 | TCP Wire 单次启动、双重回复屏障、字节方向、正常 EOF 和实例隔离。 |
| 同节 U01–U26 | 来源固定、完整包、按流出站、回包登记、坏包隔离、冷却与关联销毁。 |
| 同节 L / C / S | 当前无认证范围内的背压、真实资源预算、取消、旧配置存活、来源/目标安全和节点秘密不泄露；入站用户/密码配置及依赖认证的接入用例不适用。服务级项目需与 owner 联合验收。 |

没有完成上述模型/Core/运行周期联动及对应验收之前，不得宣称整个 SOCKS5 profile 已符合规范。
