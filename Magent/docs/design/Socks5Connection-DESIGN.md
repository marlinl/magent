# Socks5Connection Product Design

更新日期：2026-10-10。状态：**TCP / UDP 职责与成员设计提案；交接接口待确认，尚不能据此直接迁移源码**。
行为基线：[SOCKS5 SPEC](../SOCKS5_PROXY_SPEC.md)、[Wire SPEC](../WIRES_SPEC.md)、[MODELS SPEC](../MODELS_SPEC.md)。

## Context

上游为 [MagentTCPConnection 设计的 Core Logic](MagentTCPConnection-DESIGN.md#core-logic)。
上游识别 SOCKS5 后创建并保存唯一 `Socks5Connection`，主 handler 从 `.detecting` 进入 `.socks5`，
通过 [ProxyConnection 三个入口](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)
交付客户端字节、输入 EOF 和清理通知，并拥有 accepted Channel 的最终关闭。
这一步只完成协议选择；上游当前 Contract 交付的是累计探测字节，不等于完整命令交接或 SOCKS5 握手完成。

本文后续流程以前述分派之后的**完整命令交接**为目标前提：主 handler 先完成方法协商并写成方法回复，
再收齐、校验命令；CONNECT 交接逻辑目标，ASSOCIATE 交接已规范化的客户端 hint。
父对象完成 TCP 下游或 UDP 关联装配后，主 handler 才能回复命令成功；完整成功回复写成后才激活相应转发路径。
这段请求交接、建立结果及激活接口仍待确认，不能把上游进入 `.socks5` 当作这些步骤已经完成。

本文件定义两个业务类，均留在现有 `Socks5Connection.swift`；UDP 类型私有地嵌套在 TCP 类型内：

- `Socks5Connection`：承接主 handler 已验证的命令；TCP CONNECT 时建立下游并转发；
  UDP ASSOCIATE 时持有一个 `Socks5UDPConnection`，将控制连接的关闭传给它。
- `Socks5UDPConnection`：独立的关联资源 owner，负责两个 UDP Channel、可选 DNS client、
  来源固定、逐包 Core 路由与后端回包。父对象通过成员持有它；类型嵌套不表示继承，也不按业务目标创建对象。

因此顺序为：上游协议分派与完整命令交接 → 本文 TCP / UDP 装配 → 上游成功回复 → 本文转发与清理。
沿上游当前目标装配，`dnsAddress` 为 nil；本文保留可选 DNS client 的契约，但该入口不启用它，
UDP DIRECT 域名按 SPEC 失败并结束所属关联，不回退系统解析。
现行架构、SPEC 与源码的解析/回复归属仍待迁移，差异见 [共同设计前提](Socks4Connection-DESIGN.md#context)。

## Contract

### Core 与 Channel 所有权

所有 Connection 都保留当前 runtime 的 Core 引用。`Socks5Connection` 用它完成 TCP 路由和建连，
`Socks5UDPConnection` 接收父对象使用的同一个 Core，对每个合法客户端数据报选路并创建关联 Channel。
持有多个引用不会创建多个 Core；任何 Connection 都不负责关闭或替换 Core。

TCP 模式下，父对象拥有一个 `wireChannel`，PROXY 路径另有独占 TCP Wire，没有 UDP 子对象。
UDP 模式下，父对象持有唯一 UDP 子对象，自己的 TCP 下游和 Wire 保持 nil。
UDP 子对象拥有 IPv4 relay/outbound、IPv6 outbound 及可选 DNS client，全部使用控制 TCP 的 EventLoop。
子对象直接处理两个 Channel 的 NIO 回调，替代旧 `DatagramHandler` 的转交层。

### Socks5Connection 的全部实例成员

父对象共 **6 个基础成员**；多出的一个是有明确生命周期的 UDP 子对象。
这一数字不作为尚未定稿的 TCP EOF/在途写协调的硬上限。

| 声明 | 用途与生命周期 |
| --- | --- |
| `private let proxyChannel: Channel` | 借用 accepted；TCP 模式写回业务，两种模式均经其 owner 报告失败。嵌套 UDP 类型可以读取控制端点。 |
| `private let core: MagentCore` | 当前 runtime 注入；TCP 选路建连，并把同一实例提供给 UDP 子对象。 |
| `private var wireChannel: Channel?` | TCP 模式的唯一下游；初始 nil，终止时关闭并释放。 |
| `private var wire: Wire?` | TCP PROXY 的独占 Wire；TCP DIRECT 或 UDP 模式保持 nil。 |
| `private var state: State = .requesting` | 命令建立、TCP 转发、UDP 控制及终止；不保存关联数据包。 |
| `private var udpConnection: Socks5UDPConnection?` | 仅 ASSOCIATE 创建一次；控制结束时先关闭子对象再释放。 |

方法协商/命令分片缓冲、阶段回复资格归主 handler；已解析目标、hint、DNS 地址、启动报文及写 Future
归相应装配或转发操作。父对象不再保存 UDP Channel、DNS client、来源或后端字典。
DNS 配置沿装配交接传给子对象；旧 `dnsAddress` 构造参数如何交接列为接口待确认，不另加永久配置字段补洞。
嵌套 UDP 类型可以访问父对象的 `private proxyChannel`、`core` 和 `fail(_:)`，不需要扩大到 `fileprivate`。
子对象借此取得依赖并上报原始错误，不取得 accepted 的关闭权，也不新增错误转交接口。

### Socks5UDPConnection 的完整定义

该类定义在 `Socks5Connection` 的类型体内，替代原嵌套 `DatagramHandler`。父对象强持有
`udpConnection`，子对象弱引用 `owner`；两个 UDP Channel 的 handler 都是同一个子对象。

下面集中给出类的声明草图，省略方法体。**构造、装配、激活、关闭四个生命周期声明是本次待确认提案**；
NIO 回调及三个数据报方法沿用此前声明。确认之前不据此修改 Swift 源码或删除旧方法。
生命周期入口不再标 `private`，父对象才能调用；整个嵌套类型已是 `private`，这些入口不会成为包内或公共 API。

```swift
internal final class Socks5Connection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
    // 父对象的成员、TCP 方法及回调见本文其他 Contract 小节。

    /// 一条 SOCKS5 控制连接拥有的 UDP 关联；不继承 TCP Connection。
    private final class Socks5UDPConnection: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>

        private enum State {
            case preparing
            case ready
            case awaitingClient
            case forwarding
            case closed
        }

        private weak var owner: Socks5Connection?
        private let core: MagentCore
        private var state: State = .preparing
        private var ipv4Channel: Channel? = nil
        private var ipv6Channel: Channel? = nil
        private var dnsClient: DNSClient? = nil
        private var clientEndpoint: SocketAddress
        private var backendWires: [SocketAddress: Wire?] = [:]

        /// 待确认：保存父对象与已规范化 hint，core 取 owner.core；不访问网络。
        init(owner: Socks5Connection, hint: SocketAddress)

        /// 待确认：装配两个 UDP Channel 及可选 DNS client，返回实际 IPv4 BND；暂不启读。
        func openAssociation(dnsAddress: SocketAddress?) -> EventLoopFuture<SocketAddress>

        /// 待确认：仅在本地成功回复已写成后由父对象调用，开启两个 Channel 的读取。
        func activate()

        /// 待确认：封闭状态并提交关联资源关闭；幂等，不回复、不向父对象再报失败。
        func closeConnection()

        /// 单包处理 Future 完成后才续读本 Channel；终止性失败统一交父对象。
        func channelRead(context: ChannelHandlerContext, data: NIOAny)

        /// 清理期间仅传播失效事件；活动关联的意外失效结束本关联并报告父对象。
        func channelInactive(context: ChannelHandlerContext)

        /// 报文过大按包级失败处理；其余终止性错误保留原始错误并结束关联。
        func errorCaught(context: ChannelHandlerContext, error: Error)

        /// 单包最高边界；覆盖解析、选路、DNS、登记及写入，不持有跨包载荷。
        private func handleDatagram(_ packet: AddressedEnvelope<ByteBuffer>, channel: Channel)
            -> EventLoopFuture<Void>

        /// 校验一个完整 SOCKS5 UDP 包，返回当包目标与载荷。
        private static func decodeDatagram(_ data: ByteBuffer)
            throws -> (target: NetworkAddress, payload: ByteBuffer)

        /// 使用实际或 Wire 解码得到的来源封装回包，不为来源执行 DNS。
        private static func encodeDatagram(payload: ByteBuffer, source: NetworkAddress.Address) throws -> ByteBuffer
    }
}
```

#### 父子生命周期接口

| 声明 | 调用者与输入 | 完成语义与失败责任 |
| --- | --- | --- |
| `init(owner:hint:)` | 父对象仅为一个已验证 ASSOCIATE 创建子对象；hint 的 IP 已按 TCP 来源规范化，端口可为 0。 | `owner` 弱持有，`core = owner.core`，`clientEndpoint = hint`，其余成员使用上面的初值；不 bind、不 DNS、不回复。父对象随即保存子对象。 |
| `openAssociation(dnsAddress:)` | 父对象保存子对象后调用一次；DNS 地址来自本次请求的装配流程，不保存为新成员。 | 两个 bind 和所需 DNS client 全部成功才置 `.ready` 并返回 BND；失败先清理已创建资源，再将原始错误通过 Future 返回父对象，不能同时调用 `owner.fail` 双重上报。 |
| `activate()` | 父对象收到主 handler 的完整命令成功回复写成通知后调用。 | 仅 `.ready → .awaitingClient` 时各发起一次读取；装配未完不得启读，重复激活及关闭后调用不追加读取。没有本地协议回复或 Wire 启动。 |
| `closeConnection()` | 父对象 `closeConnection(error:)` 或 UDP 回调的终止边界调用。 | 先置 `.closed`，移除并关闭两个 UDP Channel、DNS client，清空登记；不关闭 accepted、Core 或共享 Wire，不调用父对象的 `fail`。 |

`openAssociation` 的一次调用由父对象唯一的命令处理流程保证；`.preparing` 本身不能区分
“尚未调用”与“装配在途”，因此不声称这个枚举会自动阻止重复装配。子对象不重开、不复用。
父对象发起装配时必须存活；装配链从控制 Channel 取得 EventLoop 和端点局部值，后续完成点检查子状态。

运行期 `channelRead` 的终止性 Future 失败、不可恢复 `errorCaught` 或非清理中的 `channelInactive`，
先调用子对象 `closeConnection()`，再通过弱引用 `owner?.fail(error)` 报告一次。它们是关联的错误边界，
不新增子对象 `fail` 或错误包装方法；包级失败仍只丢包。父对象关闭子对象不会递归触发父失败。

`closeConnection()` 返回表示状态已封闭、关闭已提交，**不表示异步 Channel / DNS 关闭全部完成**。
运行周期的 EventLoopGroup 结束仍由服务层原有流程负责；不能据此提前销毁 group。
迟到 bind/DNS 资源由接收结果的回调直接关闭，不写回成员；不能因为已处于 `.closed` 而跳过实际清理。

### Socks5UDPConnection 的全部实例成员

子对象共 **8 个实例成员**。这些是跨数据报仍需保留的依赖、资源与关联事实，没有另定义资源结构打包计数。

| 声明 | 用途与生命周期 |
| --- | --- |
| `private weak var owner: Socks5Connection?` | 关联所属控制连接；提供控制端点及统一失败出口。父对象强持有子对象，子对象弱引用父对象避免循环。 |
| `private let core: MagentCore` | 与父对象相同的 runtime；创建 UDP Channel、逐包选路及取得 DNS 超时。 |
| `private var state: State = .preparing` | 装配、等回复、待首包、固定来源转发及关闭；关闭后禁止发送、登记和续读。 |
| `private var ipv4Channel: Channel?` | 绑定临时 IPv4 relay；收客户端包、IPv4 出站及向客户端回包；关闭时释放。 |
| `private var ipv6Channel: Channel?` | 同一关联的 IPv6 出站及收包；关闭时释放，不按目标另建 Channel。 |
| `private var dnsClient: DNSClient?` | 配置 DNS 时装配；仅 DIRECT 域名目标查询；随关联释放。 |
| `private var clientEndpoint: SocketAddress` | 初始保存规范化来源提示；首个完整合法客户端包后替换为实际收到的来源端点，后续固定。 |
| `private var backendWires: [SocketAddress: Wire?]` | 初始空；记录实际后端与解码 Wire。存在 key 且 value 为 nil 表示 DIRECT，缺少 key 表示未知来源；关闭时清空。 |

`clientEndpoint` 由构造参数 hint 设置：传入前已将零地址替换为 TCP 对端 IP，非零地址须匹配，
端口可暂为 0。即使 hint 的端口非零，也只表示来源限制，不能假装已经观测到客户端。
首个全部校验通过的包才保存真实 `SocketAddress`；无效包不能抢占来源，回包保留实际地址表示。

不另存 `sourceHint`、最近一次目标/Wire、数据报缓冲、写 Future 或 DNS 结果缓存。
SPEC 允许的 DNS 结果缓存是可选优化，本版不引入。DNS 地址、BND、当包目标、解析结果与 Future
仅在装配/单包操作链中存活；当前回调的 Channel 由 `context.channel` 提供。
字典只承担 SPEC 要求的后端登记，不能用来塞入其他会话字段。固定包大小和登记容量是方法内常量，不增加实例配置。

### Socks5Connection 的 State 定义与转换

旧版 `.negotiating` 对应方法协商；在本轮完整请求交接前提下，这一阶段归主 handler。
父对象从命令交接开始，保留原有 `requesting / tcpRelay / udpAssociated / closed`，不保留永远不会进入的协商状态。

```swift
private enum State {
    case requesting
    case tcpRelay
    case udpAssociated
    case closed
}

private var state: State = .requesting
```

| 当前状态 | 允许的输入与操作 | 转换条件及推进者 |
| --- | --- | --- |
| `.requesting` | 接收一个已验证命令，建立 TCP 下游或装配 UDP 子对象；不接受业务或额外 TCP 输入。 | 主 handler 确认命令成功回复写成后，CONNECT 进入 `.tcpRelay`，ASSOCIATE 进入 `.udpAssociated` 并激活子对象。 |
| `.tcpRelay` | `upstream` / `channelRead` 只转发 TCP 业务；单方向 EOF 不直接结束整个会话。 | 正常双向结束协调完成，或 `fail` / `closeConnection` 终止时进入 `.closed`。 |
| `.udpAssociated` | TCP 仅维持控制连接；数据报完全交子对象，任何额外非空 TCP 字节失败。 | 控制 EOF、子对象终止性错误或外部关闭进入 `.closed`，并清理子对象。 |
| `.closed` | 禁止回复、转发和续读；仅清理自有下游及子对象、回收迟到资源。 | 终态，无回退。 |

构造设置 `.requesting`；`fail` / `closeConnection` 可从任何非终态封闭状态。
同一实例不在 TCP / UDP 两种模式之间切换；`wire` 或 Channel 是否为 nil 不能代替明确状态。
成功回复后的激活接口待确认，以上转换条件保留为约束，不能因此省略 State 声明。

### Socks5UDPConnection 的 State 定义与转换

子对象的状态只描述关联生命周期和来源是否已观测，不携带 Channel、包或 Future。

精确枚举与 `.preparing` 初值见 [完整定义](#socks5udpconnection-的完整定义)。

| 当前状态 | 允许的输入与操作 | 转换条件及推进者 |
| --- | --- | --- |
| `.preparing` | 装配两个 UDP Channel 及所需 DNS client，不启读、不发送业务。 | 装配链全部成功、已取得实际 BND 后进入 `.ready`。 |
| `.ready` | 资源就绪，等待本地 ASSOCIATE 成功回复写成；仍不启读。 | 父对象转交成功回复写成通知后进入 `.awaitingClient`，才启动两个 Channel 的读取。 |
| `.awaitingClient` | 按 hint 校验来源及完整客户端包；非法包不改变端点或状态。 | `channelRead → handleDatagram` 接受首个合法包，保存实际来源后进入 `.forwarding`；hint 端口非零也须经过此步。 |
| `.forwarding` | 固定来源后逐包路由、登记及回包；后续包不能改变客户端端点。 | 父对象要求结束或发生关联终止性错误时进入 `.closed`。 |
| `.closed` | 停止发送、登记和续读；关闭仍持有的 Channel / DNS，释放登记，回收迟到资源。 | 终态；包级失败不得把活动关联置为此状态。 |

构造设置 `.preparing`；装配失败、控制关闭或终止性错误可从任意活动状态进入 `.closed`。
先封闭状态再清理或通知父对象，清理幂等；转换由完整定义中的装配、激活、关闭及单包方法承担。
四个生命周期声明确认后，按本表实施，不再另设一套关联状态。

### 方法声明与迁移边界

父对象保留 [ProxyConnection 三个共享声明](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)。

| 入口 | 调用者及责任 |
| --- | --- |
| `upstream(context:data:)` | 主 handler 交付激活后的输入；TCP 模式转发业务，UDP 控制模式拒绝额外非空 TCP 数据。 |
| `proxyInputClosed(context:)` | TCP 模式按正常方向结束流程处理；UDP 模式终止整个关联，再由 accepted owner 结束控制连接。 |
| `closeConnection(error:)` | accepted owner 调用；先封闭父状态，清理 TCP 下游或 UDP 子对象，不关闭 accepted，不重复回复。 |

两个类直接采用 SwiftNIO `ChannelInboundHandler` 的回调，均在控制连接的 EventLoop 执行：

```swift
internal final class Socks5Connection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
}

internal func channelRead(context: ChannelHandlerContext, data: NIOAny)
internal func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)
internal func channelInactive(context: ChannelHandlerContext)
internal func errorCaught(context: ChannelHandlerContext, error: Error)
```

父对象的四个回调只处理 TCP 下游；读入业务交解码/写回，EOF 交正常方向结束，异常失效/错误交 accepted owner。

UDP 类型及其三个 NIO 回调完整定义见 [私有嵌套类](#socks5udpconnection-的完整定义)，不再另列空类壳。

子对象的 `channelRead` 根据来源和登记区分客户端包/后端包；`channelInactive` 的非清理中失效结束关联；
`errorCaught` 在单包边界处理 `ChannelError.writeMessageTooLarge`，不可恢复错误原样交父对象。
它不实现面向 accepted TCP 的 `ProxyConnection`，不产生本地 SOCKS5 TCP 回复，不直接关闭 accepted。

以下交接中，上层完整请求接口仍待确认；UDP 父子生命周期已在完整定义中给出四个精确声明提案，待确认后实施：

| 交接 | 调用方 → 拥有者 | 责任及原因 |
| --- | --- | --- |
| 已验证命令、目标/hint 与 DNS 配置 | 主 handler → 父对象 | 完整请求交接，选择唯一 TCP 或 UDP 模式；不重解析原始握手。 |
| TCP 建立结果 | 父对象 → 主 handler | 建连及 Wire 启动写成后才允许命令成功回复。 |
| UDP 创建、装配与 BND 返回 | 父对象 → 子对象 → 父对象 → 主 handler | 提案为 `init(owner:hint:)` 后调用 `openAssociation(dnsAddress:)`；资源齐备后返回 BND。 |
| 命令成功回复写成 | 主 handler → 父对象 → 所选转发路径 | TCP 按其交接激活；UDP 调用提案 `activate()`，不能用首包代替成功回复通知。 |
| UDP 终止与资源释放 | 父对象 → 子对象 | 父对象清理调用提案 `closeConnection()`；装配中也可关闭，清理幂等。 |
| UDP 终止性错误 | 子对象 → 父对象 → accepted owner | 子对象先清理，再调用父对象既有 `fail(_:)`；装配失败只经 Future 返回，成功后不追加 REP。 |

原 `parseHandshake` / `consumeHandshake` / `writeReply` 的本地握手责任移到主 handler。
原 `openAssociation`、`handleDatagram`、`decodeDatagram`、`encodeDatagram` 的责任移到 UDP 子对象，
不在 TCP 类保留同一套实现。已有声明及迁移归属在下节保留；嵌套作用域解决父私有访问，四个生命周期提案另行确认。
旧 `DatagramHandler` 转交层由子对象替代，不能借此直接更改已有业务方法的签名。

### 构造与私有方法定义

以下列出完整的构造及私有方法签名，并逐项注明职责。私有方法同样属于 Contract，
不能在精简成员时一并省略、合并或擅自改签名。涉及职责迁移的方法仍保留原声明和去向，
其新归属及调用接口确认前不删除；新增跨组件入口单独确认。
除注明的迁移项外，不通过 extension、helper、wrapper、重载或新文件扩充方法集合；
同步错误原样抛至拥有入口，Future 失败交统一错误边界，不在细节方法包装错误。

#### Socks5Connection 构造与 TCP 私有方法

```swift
/// 已有父对象构造；注入 accepted、Core 与可选 DNS 配置，新的装配交接须先确认。
internal init(proxyChannel: Channel, core: MagentCore, dnsAddress: SocketAddress?)

/// 父对象对 CONNECT 目标路由并建连；Future 成功表示 DIRECT 已连接或 Wire 启动写成。
private func openTCP(target: NetworkAddress) -> EventLoopFuture<Void>

/// 父对象 TCP 转发态处理客户端业务；DIRECT 透传或经独占 TCP Wire 编码。
private func relayClient(_ data: ByteBuffer) throws

/// 父对象处理 TCP 下游业务；Wire 解码后按序写回 accepted，不处理 UDP 数据报。
private func relayRemote(_ data: ByteBuffer) throws

/// 父对象处理正常 TCP EOF；检查 Wire，并按成功回复及在途写完成条件传播方向结束。
private func finishRemoteInput() throws

/// 父对象统一失败入口，保留原始首因；嵌套 UDP 类型可在关联错误边界调用。
private func fail(_ error: Error)
```

#### Socks5UDPConnection 数据报私有方法

`handleDatagram`、`decodeDatagram`、`encodeDatagram` 的完整声明已集中放入
[私有 UDP 类定义](#socks5udpconnection-的完整定义)。参数、返回值、访问级别及 `throws` 与原契约一致；
它们直接属于子对象，父对象不保留转发包装方法。

#### 保留声明的握手与装配迁移方法

```swift
/// 纯解析当前握手消息，报告消费长度和不足量；随主 handler 的本地握手责任迁移。
private func parseHandshake(_ input: ByteBuffer)
    throws -> (message: HandshakeMessage?, consumed: Int, minimumAdditional: Int)

/// 原握手推进入口，完整消息后的额外字节必须拒绝；随本地握手责任迁移。
private func consumeHandshake() throws

/// 原当前阶段完整本地回复入口；随主 handler 迁移，不用于 UDP 数据报回包。
private func writeReply(_ data: ByteBuffer) -> EventLoopFuture<Void>

/// 迁移对照：原父对象装配入口。新提案将 hint 放入子构造，并由 openAssociation(dnsAddress:) 接收 DNS 配置。
private func openAssociation(hint: SocketAddress) -> EventLoopFuture<SocketAddress>
```

| 方法 | 归属与调用责任 |
| --- | --- |
| 父对象 `init` | 保留已有声明基线；Core / accepted 依赖不变。新方案在命令交接时创建，初态改为 `.requesting`；dnsAddress 如何随装配交接需先确认，不能悄悄改构造。 |
| `parseHandshake` / `consumeHandshake` / `writeReply` | 方法协商及命令解析/回复随主 handler 迁移；每阶段严格一次回复、完整消息余量检查继续保留。 |
| `openTCP` | 保留父对象的 TCP 建立责任；一次路由，Future 仅表示连接及 Wire 启动完成，由主 handler 再完成命令回复。 |
| `relayClient` / `relayRemote` | 保留父对象 TCP 转发；分别由 `.tcpRelay` 的 `upstream` / `channelRead` 调用，不承担 UDP 收发。 |
| `finishRemoteInput` / `fail` | 保留父对象 TCP 正常 EOF 和统一失败入口；嵌套子对象的终止性错误可直接调用父对象 `fail`，无需新增转交方法。 |
| 原 `openAssociation(hint:)` | 保留迁移前声明；目标装配由子对象的 `openAssociation(dnsAddress:)` 承担，hint 在子构造中设置。新声明待确认后才替换源码。 |
| `handleDatagram` | 迁入子对象，保持单包参数/返回契约；`channelRead` 调用。包级失败完成本包并续读，路由/DNS/资源失败返回原始失败，由关联边界处理。 |
| `decodeDatagram` / `encodeDatagram` | 迁入子对象的纯报文方法；当包处理调用，零载荷合法，不为回包来源执行 DNS，不创建新的逻辑地址包装类型。 |

`HandshakeMessage` 是原握手解析结果声明，随解析责任迁移；它不是 State 或成员打包容器：

```swift
private enum HandshakeMessage {
    case greeting(methods: [UInt8])
    case request(command: UInt8, address: NetworkAddress)
    case unsupportedCommand(UInt8)
}
```

旧 `DatagramHandler` 仅转交回调，其 `init(owner: Socks5Connection)` 随转交层被子对象替代；
不恢复成第六个业务类，也不把这个单参数构造冒充能够初始化全部 UDP 关联依赖的新构造。

### 协作者与容量契约

Core 的精确接口引用 [Core Contract](MagentCore-DESIGN.md#contract)，Wire 方法与结果类型引用
[Wire 抽象接口](../WIRES_SPEC.md#抽象接口草图)。TCP 路由一次，DIRECT 返回 nil Wire，PROXY 使用独占 TCP Wire；
代理端点与超时来自同一 Wire。规则失败或节点缺失不回退 DIRECT，Connection 不再自行匹配规则。
全部下游复用 accepted EventLoop；`@unchecked Sendable` 不允许跨 EventLoop 并发访问。

调用 Wire 前按 [容量契约](../WIRES_SPEC.md#缓冲和进度)预留输入和最坏输出空间；
当前输入、Wire 内部分片、编码输出和在途写都计入有界内存，方法局部捕获也不能例外。
启动流程遵守 [TCP 启动约束](../WIRES_SPEC.md#启动与状态转换)，正常下游 EOF 遵守
[完整性与半关闭](../WIRES_SPEC.md#eof-与半关闭)。不通过新增全局配额、公共配置或无归属任务实现这些要求。

## Core Logic

以下两条流程承接 Context 中的完整命令交接；协议选择本身不触发建连、UDP 装配或成功回复。

### TCP CONNECT

1. 父对象接收上游交付的已验证 CONNECT 目标，从 `.requesting` 开始建立下游，不再重复方法协商与命令解析。
2. 父对象通过 Core 选路一次，DIRECT 连接目标，PROXY 连接同一 Wire 端点并完成启动写入。
3. 主 handler 写成命令成功回复后激活 TCP 双向转发。业务只做透传或 Wire 编解码；每批写成才续读来源。
4. 正常 EOF、Wire 完整性、写入排空与 accepted 最终结束遵循
   [共同转发契约](Socks4Connection-DESIGN.md#core-logic)。不把写 Future 默认提升为成员，
   也不把基础成员数量当成 EOF 协调已经完成的证明。

### UDP ASSOCIATE

1. 父对象接收上游已校验并规范化的数值 hint；按接口提案，通过 `init(owner:hint:)` 创建并保存子对象，
   再调用一次 `openAssociation(dnsAddress: nil)`，装配 IPv4 `0.0.0.0:0` 与 IPv6 `[::]:0`；本入口不创建 DNS client。
   部分失败清理后原样返回。
2. BND 使用控制 TCP 的具体本地 IPv4 地址及 IPv4 relay 的实际临时端口。
   资源就绪只允许回复，**完整成功回复写成才调用子对象 `activate()` 开启 UDP 读取**；ASSOCIATE 此时不选择业务目标或 Wire。
3. 子对象校验客户端来源和完整 UDP 包，拒绝 FRAG、超限或非法目标。
   首个合法包固定真实来源；之后只接受该客户端。客户端包移除 SOCKS5 头后，经 Core 按当包目标选路。
4. DIRECT 数值目标直接发送 DATA；本次装配没有 DNS client，DIRECT 域名按 SPEC 失败并结束所属关联。
   PROXY 不解析业务域名，以当包目标调用 Wire 编码并发送到 Wire 实际端点。
   两者都按实际后端地址族使用既有 IPv4/IPv6 Channel，不按目标建新 Channel。
5. 发送前登记后端实际端点与 Wire。相同端点只能有一种解码归属；冲突拒绝新包而保留原登记，
   后端不能等于固定客户端。登记固定上限 1024；满时丢弃需要新增记录的包，不驱逐已有记录。
6. 只接受已登记后端回包。DIRECT 使用实际来源，PROXY 使用登记 Wire 解码出的逻辑来源；
   封装 SOCKS5 UDP 头后，经 IPv4 relay 发往固定客户端。未知来源丢弃，不按最近目标猜测 Wire。
7. 每个 Channel 完成本包及其 DNS/写操作后才续读；两个 Channel 各自有序，在同一 EventLoop 共享关联状态。
   在异步完成后、发送/登记/续读前再次检查终态。合法零载荷仍回复一个包，UDP 没有流 EOF。

### 失败与关闭

包级失败包括坏包、FRAG、超限、未知来源、登记冲突/满、Wire 编解码错误与 `writeMessageTooLarge`，
仅丢当前包并按读取许可续读。路由/DNS 失败或 Channel 无法继续服务原样交父对象，结束该关联；
中间帮助方法不包装错误，只在单包或关联的最高拥有边界选择动作。
子对象发现首次终止性错误时先封闭自身状态，再通知父对象，阻止另一 UDP Channel 或迟到 DNS 继续工作。
后续清理仍须关闭并释放实际资源，不能仅因状态已经关闭就跳过清理。

控制 EOF、accepted 失效或 runtime 关闭时，父对象先封闭状态，再调用子对象 `closeConnection()`，
子对象提交两个 UDP Channel 和 DNS client 的关闭并清空登记，父对象随后释放子对象引用。
异步关闭的完成由既有资源流程收敛，父对象不以该 Void 返回值断言网络资源已经全部释放。
异步 bind/DNS 在关闭后成功，只回收返回资源或丢弃结果，不复活关联。
正常关闭产生的 Channel 回调不再次上报失败；子对象不关闭 Core 或共享 UDP Wire。

## Corners

| 场景 | 必须保持的结果 |
| --- | --- |
| SOCKS5 方法请求与命令粘在一起 | 主 handler 保持严格阶段顺序，不靠子对象“收到完整请求”放宽协议。 |
| UDP 部分装配失败，或回复写入失败 | 已创建资源全部释放；未写成成功回复不启读。 |
| hint 端口为 0 / 非 0，首包非法 | 均不能被非法包锁定来源；首合法包保存实际回包端点。 |
| 后端未登记、同端点不同 Wire、端点等于客户端 | 丢包；不能覆盖归属或反射回错误对象。 |
| 完整数据报超过 65507 字节或接收截断 | 丢整包，不拆分、不补齐、不降级 TCP；不能只凭长度等于缓冲容量判断未截断。 |
| UDP 无任何后端记录时控制关闭 | 仍释放两个 Channel 和 DNS client，不能以登记非空作为清理条件。 |
| 关闭与 DNS / bind / 写入完成竞争 | 不发包、不登记、不续读；迟到资源释放。 |

本轮按字段职责、来源固定、资源装配/回复/启读顺序及关闭竞态静态复核；源码未修改，未跑网络测试。
UDP 8 个成员覆盖的是必要关联信息，不构成上线证明。完整请求交接、父子接口和 TCP 收尾需要确认后再实施。

### 实施验收引用

恢复 [SOCKS5 验收](../SOCKS5_PROXY_SPEC.md#s26) 与 [Wire 验收](../WIRES_SPEC.md#验收)，
覆盖两轮严格协商、TCP 回复/EOF、双 UDP bind、首包来源固定、DIRECT/PROXY 解码归属、DNS 及迟到资源清理。
地址与回包类型引用 [MODELS 地址声明](../MODELS_SPEC.md#类型构造入口与地址输出)；
UDP 不调用 Wire 的 `start`、`finishInbound` 或 `getTimeout`，共享 UDP Wire 遵守独立包契约。
