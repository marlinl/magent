# HttpConnectConnection Product Design

更新日期：2026-09-27。状态：**目标设计**，以规范要求为依据，不继承当前实现的能力限制，
不表示代码已经实现或通过验收。

规范基线：[HTTP SPEC v0.2.0](../HTTP_PROXY_SPEC.md)、[Wire SPEC v0.3.0](../WIRES_SPEC.md)，
均为 2026-09-26 工作树草案。地址及 HTTP 模型引用 [MODELS SPEC v0.4.2](../MODELS_SPEC.md)。
共享入口引用 [ProxyConnection 契约](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)。

当前产品范围不支持入站认证。引用 SPEC 中的 Basic、用户/密码配置、本地 407 挑战及相关验收
不纳入本设计；本轮范围调整以此为准，其余协议约束继续适用。

## Context

`HttpConnectConnection` 处理一条 HTTP/1.1 CONNECT 请求：校验 authority 和安全策略，
通过 Core 为唯一业务目标选择 DIRECT 或 PROXY，在下游就绪后生成本地 `200 Connection Established`，
完整写出后切换为透明 TCP 隧道。

accepted Channel 的最终生命周期属于 `MagentTCPConnection`。本组件拥有 CONNECT 状态、
请求及双向余量、本地回复、下游 Channel、可选独立 TCP Wire 和自己的期限/额度。
Core 负责路由及出站创建；Wire 负责出站协议，二者都不生成本地 HTTP 成功或错误响应。

创建者有两种：首个请求就是 CONNECT 时由 `MagentTCPConnection` 创建；客户端先完成普通 HTTP
请求、随后发 CONNECT 时，由 [HttpForwardConnection](HttpForwardConnection-DESIGN.md#后续-connect-的交接)
在该请求轮次创建并持有本组件。两种路径使用同一个构造及相同的三个 `ProxyConnection` 入口。
子连接不接管 accepted Channel 的最终关闭，也不替换主 handler 当前持有的对象。

本组件不转发 CONNECT 头到目标，不处理普通源站 HTTP 响应，不代客户端执行 TLS、验证网站证书或
根据 SNI 重新路由。隧道内可承载任意获准 TCP 字节，包括 TLS、HTTP/2 和 WebSocket；
不提供 UDP、CONNECT-UDP、MASQUE、HTTP/2 入站或 TLS 解密。

## Contract

### 受限类型与 18 个方法

受限类型为 `HttpConnectConnection`，固定 **18 个方法**：1 个构造、3 个引用的客户端入口、
4 个 NIO 回调、9 个私有产品阶段及 1 个供两个 HTTP Connection 共用的静态响应构造方法。
不允许通过 extension、私有 helper、重载、wrapper、新协议或文件增加方法。
签名中的访问级别、参数、返回、`throws` 和 `static` 都是硬约束；无默认参数、`async` 或 actor 隔离。
下列代码块是目标声明，省略实现，不能当作已存在的可编译代码。

除无状态的 `localResponse` 外，全部调用及异步完成后的状态推进都在原 accepted EventLoop 串行执行；
下游使用同一服务的 EventLoopGroup，TCP Channel 与 accepted Channel 位于同一 EventLoop。
外部解析任务只返回结果，完成后回到该 EventLoop 校验 generation；不阻塞等待 future，
不创建 detached 或无人负责回收的任务。

```swift
/// 负责一次 HTTP CONNECT 建立及之后固定目标的透明 TCP 隧道。
internal final class HttpConnectConnection: ChannelInboundHandler, ProxyConnection {
    typealias InboundIn = ByteBuffer
}

/// 绑定原 accepted Channel、接入时的 Core 与本次请求已有的绝对头部截止点。
internal init(proxyChannel: Channel, core: MagentCore, requestDeadline: NIODeadline)
```

依赖必须绑定到原 TCP accept 的配置、来源准入和绝对计时基准，不在后续 CONNECT 创建时
重新获取新配置。`requestDeadline` 是已计算的单调时钟截止点：首请求为 accept 时间加头部预算；
后续请求按 HTTP §21 从轮到处理且首字节可用时开始。传入已经到期的值立即走超时边界，
不能在子对象创建时重置计时。它是本次请求的计时事实，不是新增配置参数。
时钟、准入、预算、Resolver 和停止信号由服务装配；本设计不为未设计的依赖编造构造参数或 API。

三个共享入口的精确声明直接引用
[ProxyConnection（2026-09-27）](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)，
不再定义协议或复制签名。

| 入口 | 本组件的职责 |
| --- | --- |
| `upstream` | 接收 `ByteBuffer` 任意分片。请求阶段调用 `parseRequestHead`，完整头通过语义/安全校验后只调用一次 `openTunnel`；就绪后调用 `writeSuccess`。期间只保存有界余量；隧道态调用 `relayClient`。 |
| `proxyInputClosed` | 未完成请求头即 EOF 视为截断，不建出站；完整有效请求之后 EOF 可等待已经启动的建立及回复，排空余量后半关闭下游输出，继续接收反向数据。 |
| `closeConnection` | 先置终态并使在途回调失效，幂等释放下游、候选、Wire、缓冲和许可；不发送新响应、不关闭 accepted Channel、不再上报清理事件。 |

调用方可以是主 handler，也可以是已经交接到本组件的 `HttpForwardConnection`。
二者传入的 context 都必须是原 accepted Channel 的主 handler context；不得传旧源站 context。
一次交接只交付一次完整 CONNECT 原始头及其后余量，不预先剥掉字段或执行路由。

### NIO 回调

下面四项来自 SwiftNIO
[`ChannelInboundHandler`](https://github.com/apple/swift-nio/blob/21de5f08c1a166a6dd293d0e587ad977bf8dac5d/Sources/NIOCore/TypeAssistedChannelHandler.swift)，
只用于本组件拥有的下游 TCP Channel。

```swift
/// 消费下游原始字节，交由 DIRECT 或 Wire 反向业务路径处理。
internal func channelRead(context: ChannelHandlerContext, data: NIOAny)

/// 处理下游输入半关闭，并将非 EOF 事件继续传递。
internal func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)

/// 处理下游全关闭；未处理过的正常 EOF 仍须完成 Wire 检查。
internal func channelInactive(context: ChannelHandlerContext)

/// 将下游原始错误交给会话的唯一失败边界。
internal func errorCaught(context: ChannelHandlerContext, error: Error)
```

`channelRead` 调用 `relayRemote`；Wire 尚未初始化时原始输入有界保留。
`.inputClosed` 调用 `finishRemoteInput`；正常 `channelInactive` 补做一次相同检查，
已经因错误/取消结束的路径不再检查或覆盖终因。`errorCaught` 直接调用 `fail`。
全关闭不等同于保持另一方向可写，剩余不可完成的写入按传输失败处理。

### 产品阶段的固定声明

```swift
/// 仅增量解析并校验完整请求头；不足返回 nil，头后的原始字节留在 input。
private func parseRequestHead(_ input: inout ByteBuffer) throws -> HTTPRequestHead?

/// 固定一次路由并完成下游建立及可选启动写入，成功后才具备本地 200 的条件。
private func openTunnel(target: NetworkAddress) -> EventLoopFuture<Void>

/// 占有成功提交权并完整写出本地 200，写完后才释放双向隧道屏障。
private func writeSuccess() -> EventLoopFuture<Void>

/// 有序写入 accepted Channel；本地响应和反向业务共用同一写队列。
private func writeClient(_ data: ByteBuffer) -> EventLoopFuture<Void>

/// 有序写入下游 Channel，接收启动原始字节或已经完成 Wire 编码的业务字节。
private func writeRemote(_ data: ByteBuffer) -> EventLoopFuture<Void>

/// 在成功屏障后透明转发或编码客户端业务，保持目标和字节顺序。
private func relayClient(_ data: ByteBuffer) throws

/// 在 Wire 初始化后解码下游业务，按本地成功屏障保存或交付。
private func relayRemote(_ data: ByteBuffer) throws

/// 先验证正常下游 EOF，再排空反向业务并半关闭客户端输出。
private func finishRemoteInput() throws

/// 保留首次原始错误，按提交状态选择一次本地错误响应或直接终止。
private func fail(_ error: Error)

/// 为 CONNECT 成功、本地 204 或本地错误构造无 body 的规范 HTTP/1.1 响应头。
internal static func localResponse(status: HTTPResponseStatus, headers: HTTPHeaders) -> HTTPResponseHead
```

| 方法 | 调用方 | 输入、完成和后继 |
| --- | --- | --- |
| `parseRequestHead` | `upstream` 请求阶段 | 只处理字节语法、重复字段及头部限额；有增量扫描位置。无 DNS/路由/写入副作用，nil 不表示错误。返回原始有序字段；代理凭据字段按下文无认证规则丢弃，不建立客户端身份。 |
| `openTunnel` | CONNECT 请求语义及安全校验完成后 | DIRECT 连接成功，或 PROXY `start` 成功且可选启动字节通过 `writeRemote` 写成，future 才成功；调用方随后调用 `writeSuccess`。不等待客户端首个业务字节或节点首包。 |
| `writeSuccess` | `openTunnel` 成功回调 | 先检查未终结及资源仍归属本次请求，使用 `localResponse`、HTTP 编码器及 `writeClient`；future 成功才排空双方余量。失败进 `fail`，不得再发错误响应。 |
| `writeClient` | `writeSuccess`、`relayRemote`、`fail` | 完成表示整批字节按序交给传输适配器，不证明对端已读；失败 future 由发起边界处理。任何 body 都不能插入正在写的响应头。 |
| `writeRemote` | `openTunnel`、`relayClient` | 只写所属下游；启动字节不得再次 Wire 编码。完成才释放该批缓冲和继续本方向读取；失败 future 保留原始错误。 |
| `relayClient` | `upstream` 隧道态、成功后的客户端余量排空 | DIRECT 直写；PROXY 以 nil 地址编码后 `writeRemote`。空 TCP 输入不写、不推进 Wire。 |
| `relayRemote` | `channelRead`、初始化后原始余量排空 | DIRECT 透明；PROXY 消费 `decodeInbound`。空 data 不是 EOF；非空业务在启动或回复屏障未完成时保存，否则 `writeClient`。 |
| `finishRemoteInput` | NIO 正常 EOF / inactive；初始化后续接已记录 EOF 的出站回调 | 处理完所有已读输入后，仅 PROXY 调一次 `finishInbound`。成功后排空客户端写队列并关闭输出方向；截断抛回回调边界进入 `fail`。 |
| `fail` | 客户端/NIO 边界、上述 future 失败、期限回调 | 第一次失败停止新工作。尚未提交成功/错误且客户端可写时生成一个错误响应；完成或 1 s 回复期限到达后，把原始错误交 accepted pipeline。部分提交后只结束。 |
| `localResponse` | 本组件 `writeSuccess` / `fail`；HTTP Forward 的本地 OPTIONS / `fail` | 仅构造响应头，无网络、状态或清理副作用。status 只接受 200（CONNECT）、204（本地能力）及当前错误映射支持的 400..599，不生成本地 401/407。headers 只含调用方已验证的 Date 等本地字段，不接受任意客户端字段或代理挑战。 |

`localResponse` 固定 HTTP/1.1：200 和 204 不生成 CL、TE 或 body；错误使用 CL=0、
`Cache-Control: no-store` 和 `Connection: close`；不生成 `Proxy-Authenticate`。
204 的是否关闭由事务所有者按 keep-alive 条件决定，200 不带普通响应关闭语义。
HTTP 编码器负责 CRLF 和完整头结束；方法不创造完整源站响应，也不负责提交标记。
这一共用点留在已有 HTTP Connection 类型内，不另建响应工具文件。

### 状态契约

CONNECT 只消费一次 HTTP 请求；完整 200 写成后，后续字节永久变为固定目标的透明隧道，不能再
生成普通 HTTP 响应。因此以这一不可逆的协议切换和终结为边界，定义以下 **3 个状态**。
解析、建连、Wire 启动及写 200 是切换前的流程。`State` 为本类型内部的私有枚举，没有方法。

```swift
/// 区分 CONNECT 建立、透明转发和逻辑终结。
private enum State {
    case handshaking
    case forwarding
    case closed
}

/// 构造后等待本次 CONNECT 请求，不允许隧道业务交付。
private var state: State = .handshaking
```

| 状态 | 允许的行为 | 离开条件与负责方法 |
| --- | --- | --- |
| `.handshaking` | `upstream` 解析一次请求，`openTunnel` 建立下游并完成可选启动，`writeSuccess` 写 200；提前业务只缓冲。 | 完整 200 写成后进入 `.forwarding`；失败或关闭进入 `.closed`。 |
| `.forwarding` | `relayClient` / `relayRemote` 透明转发；EOF 只排空并半关闭对应方向。 | 两方向均结束、不可恢复错误或取消时进入 `.closed`。 |
| `.closed` | 禁止新解析、出站工作和隧道转发；只完成已安排的错误响应及幂等清理。 | 终态，不再回到 HTTP 解析或转发。 |

转换固定为 `handshaking -> forwarding -> closed` 或 `handshaking -> closed`，只在 accepted
EventLoop 推进。下游就绪或 200 开始写均不代表转发屏障完成；半关闭期间仍保持 `.forwarding`。

| 必须保存的事实 | 初值与约束 |
| --- | --- |
| 请求是否已接受 | 初始否；完整头通过校验后置是，固定目标与一次路由；后续字节只归隧道余量。 |
| 最终响应是否已提交 | 初始否；`writeSuccess` / `fail` 在写前共用一次提交权，部分写失败也不能追加 502。 |
| 两侧 EOF、正常下游 EOF 是否已检查、两侧输出是否已关闭 | 初始均为否；方向独立，排空后才关闭对应输出。Wire 尚未初始化时记录 EOF，初始化并解码已有输入后检查一次。 |
| 首次错误、是否已上报、是否已清理 | 初始 nil / 否 / 否；首因、上报和资源释放均幂等。 |

这些事实不另设枚举。`fail` 固定首因与允许的错误响应后进入 `.closed`，限时完成该次响应并上报；
此后不能产生新响应。`closeConnection` 必须完成尚未执行的清理，不能仅因主状态已 closed 而跳过。
正常结束先置 closed 再请求 accepted 关闭；迟到回调只能释放自身资源，不能写 200 或恢复转发。
由 HTTP Forward 持有时仍遵守同一状态契约，父对象只转交共享入口，不复制本组件状态。

### 协作者和数据

| 项目 | 约束 |
| --- | --- |
| 主阶段 | 仅使用 `.handshaking`、`.forwarding`、`.closed`；步骤不另建状态，半关闭仍属转发。 |
| 请求 | 原始有序头、扫描进度及准确余量边界；目标语义归 HttpProtocol / NetworkAddress，未完成头部不触发网络。 |
| 路由 | 同一逻辑目标、一次决策、可选独立 Wire；解析 IP 或节点端点不能替换逻辑目标。 |
| 提交状态 | 回复开始提交、成功写完、隧道建立分别记录。开始写任意最终响应之前即占有提交权，不能等待 future 成功才置位。 |
| 双向状态 | 原始节点余量、已解码业务余量、客户端余量、在途写、EOF 及 finishInbound 已执行标记各有归属。转移同一字节所有权不重复计费。 |
| 终结 | 首次原始终因、generation、所属期限和许可；取消后的回调不能生成成功或启动新网络。 |

精确 Wire 接口及数据结构引用 v0.3.0 的[抽象接口](../WIRES_SPEC.md#抽象接口草图)、
[本地回复屏障](../WIRES_SPEC.md#本地回复屏障)及 [EOF / 半关闭](../WIRES_SPEC.md#eof-与半关闭)。
`openTunnel` 只消费 `getEndpoint`、毫秒 `getTimeout` 和单次 `start`；
业务阶段只消费 `encodeOutbound` / `decodeInbound`；正常 EOF 才消费 `finishInbound`。
不新增 Wire 成员、远端 ready 状态、控制响应解析或 DIRECT 回退。

HTTP 请求头、响应头和字段使用 NIOHTTP1 的 `HTTPRequestHead`、`HTTPResponseHead`、`HTTPHeaders`，
保留重复项及顺序。现成 codec 仍须满足 [HTTP §26.5](../HTTP_PROXY_SPEC.md#s26) 的严格检查，
不能让底层预先合并重复 CL，再声称上层能识别原始重复字段。

### 必须联动的外部契约

| 依赖 | 实施前置条件 |
| --- | --- |
| HttpProtocol | [MODELS 的有限范围](../MODELS_SPEC.md#支持范围与-http-规范的关系) 允许 HTTP/1.0、拒绝提前数据，并保留有限流程；本设计要求仅入站 1.1 和合法 CONNECT 余量保留。需升级相关模型/连接消费契约，不按旧模型限制削减目标，也不新增替代 HttpProtocol 的影子模型。 |
| Core / ProxyRule | HTTP §11 要求顺序首条、端口/transport、REJECT；[MODELS 的规则契约](../MODELS_SPEC.md#proxyrule) 尚不一致。由 Core/模型联动实现；本组件不得重写路由引擎或伪造 Core 方法。 |
| HTTP listener | HTTP §5.2 的 profile 要求 HTTP-only 接入；混合 SOCKS/HTTP 端口不能宣称符合该 listener profile。主 handler 可复用，但装配必须限制 HTTP listener 的接入协议；HTTP 会话建立后不探测切换成 SOCKS/TLS。 |
| 运行周期 | HTTP §20.7 固定 accept 时配置，§21.10 要求排空。旧 Core/依赖须保留至会话结束；普通配置更新不隐含立即关闭旧会话。停止信号通过运行周期订阅提供，不添加共享协议方法。 |
| 创建者 | 主 handler 目标构造显式接收并转交首请求的 `requestDeadline`；HTTP Forward 交接传入本轮原有截止点。具体运行周期计时装配由 Magent 完成，不能在探测或交接后重置预算。 |
| 服务依赖 | 时钟、全局许可、系统 DNS、候选拨号及明确半关闭传输适配需要各自 API/装配契约；不装配入站凭据验证器或认证配置，来源准入与目标安全检查独立执行。本文不声称 `core` 已具有未定义的服务 getter。 |

除开篇明确移除的入站认证能力外，上述事项仍是跨文档规范差异或未完成的依赖契约。

## Core Logic

### 建议的方法调用流程图

方法名与 `Contract` 一致；方括号为状态、外部协作或流程条件；只有带点名称表示生命周期状态，不增加方法。
“就绪”“写成”均是异步完成条件，不能用方法同步返回代替；下面两条业务方向独立推进。

```text
MagentTCPConnection / HttpForwardConnection.beginConnect(context:)
  -> HttpConnectConnection.init(proxyChannel:core:requestDeadline:)
  -> upstream(context:data:)
       +-- [.handshaking: 读取请求] -> parseRequestHead(&input)
       |                  +-- nil -> [保留解析进度, 等下一次 upstream]
       |                  +-- 完整 -> [CONNECT 语义、目标与安全校验]
       |                               -> openTunnel(target:)
       |                                    +-- [DIRECT: Core 建连成功] -> [下游就绪]
       |                                    +-- [PROXY: Core 建立节点 Channel]
       |                                         -> Wire.start(handshake: target)
       |                                              +-- nil -> [下游就绪]
       |                                              +-- 启动字节 -> writeRemote(...)
       |                                                               -> [写成: 下游就绪]
       +-- [建立/回复中] -> [有界保存客户端余量]
       +-- [.forwarding] -> relayClient(data) -> [DIRECT 直通 / Wire.encodeOutbound]
                                           -> writeRemote(...) -> [写成后续读客户端]

[下游就绪] -> writeSuccess()
  -> Self.localResponse(status: 200, headers: ...) -> [HTTP 编码] -> writeClient(...)
  -> [完整 200 写成: .forwarding, 两个方向独立排空余量]

下游 channelRead(context:data:) -> relayRemote(data)
  -> [DIRECT 直通 / Wire 已初始化后 decodeInbound]
       +-- [空业务结果] -> [等待后续输入, 不是 EOF]
       +-- [启动写/200 尚未写成] -> [有界保存已解码业务]
       +-- [屏障已完成] -> writeClient(...) -> [写成后续读下游]
```

Wire 初始化前的原始节点输入只作有界保留；已解码余量在 200 写成后直接经 `writeClient`
排空，不再次经过 `relayRemote`。所有请求都没有认证阶段。

```text
proxyInputClosed(context:)
  +-- [头部截断] -> fail(error)
  +-- [完整请求/隧道中] -> [等待建立及回复, 排空上行, 半关闭下游输出]

userInboundEventTriggered(.inputClosed) / channelInactive([正常结束且尚未处理 EOF])
  -> finishRemoteInput()
       -> [PROXY: Wire.finishInbound(); DIRECT: 跳过]
            +-- [成功] -> [反向排空, 半关闭客户端输出, 保留另一方向]
            +-- [抛错] -> [所属 NIO 回调] -> fail(error)

errorCaught(error) / [入口捕获的原始错误、future 失败、期限到达]
  -> fail(error) [.closed, 完成本次错误收尾]
       +-- [最终响应未提交且可写] -> Self.localResponse(status: 错误状态, headers: ...)
       |                           -> [HTTP 编码] -> writeClient(...)
       |                           -> [写完或回复期限到达: REPORT]
       +-- [已提交或不可写] -> [REPORT]

[REPORT] -> accepted.pipeline.fireErrorCaught(原始错误)
  -> MagentTCPConnection.errorCaught -> [主 handler 调用清理入口]
[正常双方排空 / accepted 失效]
  -> MagentTCPConnection.channelInactive -> [主 handler 调用清理入口]

[主 handler 调用清理入口]
  +-- [直接持有本组件] -> closeConnection(error:)
  +-- [持有 HTTP Forward] -> HttpForwardConnection.closeConnection(error:)
                              -> 子对象.closeConnection(error:)
  -> [本组件只幂等清理下游; 不向父对象反向触发关闭]
```

### 请求与出站

客户端输入按字节增量处理，完整头校验前不输出业务。只接受精确 `CONNECT`、HTTP/1.1 和
带显式非零端口的 authority；不从 Host 补 443，不接受 URI、路径、userinfo、IPv6 zone 或无括号
IPv6。Host 必须恰好一个、语法合法，但不覆盖 request-target。允许单个 CL=0；非零 CL/任何 TE
返回 400，Expect 返回 417。所有通用严格字段、重复字段及 Connection token 规则仍有效。

本地不执行 Basic 或其他凭据验证，也不要求客户端发送凭据。收到 `Proxy-Authorization` 时，
仅按普通 HTTP 字段检查语法和头部限额，随后丢弃全部该字段，不解码其值、不保存身份、不生成
407 或 `Proxy-Authenticate`。它不参与路由，也不传给目标或 Wire；后续 CONNECT 遵守同一规则。

请求语义校验后规范化并验证目标，CONNECT 默认只允许端口 80/443，其他端口须显式配置。
数值目标与 DIRECT DNS 候选分别接受安全检查，真实 listener 自回环始终拒绝。域名保留根点身份；
规则匹配不能由 Host、解析 IP 或节点地址替换业务目标。

Core 只作一次路由：REJECT 不执行 DNS/网络；DIRECT 域名调用受控系统解析器，最多 8 个候选、
最多 2 个并行、默认间隔 250 ms，只对安全检查通过的数值端点拨号，关闭输者与迟到成功。
PROXY 不做业务目标 DNS，只连接所选 Wire 的稳定端点，并按其正整数毫秒超时和总期限建连。
Wire 初始化、启动、编码或网络失败都不自动重试业务或改走 DIRECT。

### 成功屏障与隧道

下游就绪、目标/策略/资源仍有效后，`writeSuccess` 提交不含 CL/TE/body 的本地 200。
可选 Wire 启动字节必须已经写成；nil 启动不需要首个业务包或远端确认。
在 200 的完整头部写完以前，反向 relay 不获得客户端写权，客户端提前业务也不发给目标。

`clientRemainder` 保存 CONNECT 头后的全部字节；`upstreamRemainder` 只保存 Wire 已解码业务。
Wire 初始化前的节点原始输入另行有界保存，初始化后按序解码；不把启动控制字节混入业务。
成功后两个方向各自先排空余量，再消费后续读取，不互相等待首包。

进入隧道后不再解析 HTTP。客户端方向只发送原始业务或 Wire 编码业务；反向只发送原始/解码业务。
正常客户端 FIN 排空上行后关闭下游输出，保留反向读；正常下游 FIN 在 Wire 检查成功后排空反向输出，
保留上行。空解码 data 不等于 EOF。最终响应一旦开始提交，此后的任何失败都只能结束连接，不能
追加 HTTP 错误；Wire 截断若发生在 200 提交前且客户端可写，则由 `fail` 生成一次本地 502。

### 期限、容量和结束

全部默认值按 [HTTP §21](../HTTP_PROXY_SPEC.md#s21) 执行：请求头 10 s；出站总期限 25 s，
DNS 5 s、DIRECT 单候选 10 s、Wire 启动 10 s 均受总期限约束；本地回复 1 s；
写停滞 30 s、隧道双向空闲 900 s、半关闭排空 30 s。只用单调时钟，零星字节不重置绝对期限。

头部最多 32 KiB、请求行 8192 B、目标 8000 B，其他通用字段限额引用同节，不把业务余量计入头部。
读块 32 KiB，每方向早到数据 64 KiB，方向高/低水位 256/64 KiB，并同时占用共享全局缓冲额度。
缓冲包括在途写及编码结果；读前留出接收预算，写成后归还。Wire 另行限制自身协议缓冲。

建立期间占用事务和握手额度，隧道建立后释放这两项，继续保留会话/socket/实际缓冲许可。
主动背压暂停读取时由 write-stall 约束，不把暂停时间算成对端空闲。
超时、取消、EOF 竞争时保留一次终结；错误经 `fail` 交 accepted pipeline，主 handler 再调用清理入口。
正常双方排空后请求 accepted Channel 的 NIO 关闭流程；最终 `closeConnection` 只清理下游。
若父对象为 HTTP Forward，该父对象将清理原样转交一次，本组件不回调父对象形成关闭环。

## Corners

### 错误提交和可观察边界

当前范围的本地映射引用 [HTTP §23](../HTTP_PROXY_SPEC.md#s23)：非法输入 400、
目标或端口拒绝 403、请求超时 408、目标过长 414、Expect 417、头部超限 431、功能不支持 501、
版本不支持 505、出站/Wire 失败 502、出站期限 504、资源耗尽 503。
已有原始错误只在最高边界选响应，不在 helper 包装、改名或吞掉。

| 场景 | 目标行为 |
| --- | --- |
| 头与 TLS ClientHello 同批到达 | 正确保留 TLS 字节；成功前不转发，成功后恰好交付一次。 |
| 下游在 200 之前先发业务 | 有界保留；不得把业务插入 HTTP 成功头部。 |
| 200 只提交一个字节就失败 | 已占用最终响应提交权，只结束，不追加 502。 |
| 完整头之后 FIN / 头中途 FIN | 前者可完成建立并排空半关闭；后者不建出站。 |
| Wire 启动失败 | 返回本地 502，不生成入站认证挑战。 |
| 缺少或携带 `Proxy-Authorization` | 都不进入认证流程；字段不送往目标或 Wire，不因凭据内容生成 400/407，非法 HTTP 字段语法仍按 400 处理。 |
| 下游正常 FIN 但 Wire 帧截断 | 错误终结，不能交付正常 EOF；原网络错误或取消不被截断检查覆盖。 |
| 同一 Wire 截断发生在 200 提交前 / 后 | 前者在可写时生成一次 502；后者只终止隧道，不追加 HTTP 字节。 |
| CONNECT 内出现 HTTP/2 / 新 Host | 保持不透明转发，目标及路由不变。 |
| 后续 CONNECT 的错误 | 只在前一 HTTP 事务响应完全写完后处理，不抢先回错或重复处理上一事务。 |

### 实施验收

至少覆盖 [HTTP §28](../HTTP_PROXY_SPEC.md#s28) 的 P04–P09、P17–P21、F13、R/D、
O01–O16、T01–T12、W08、S06/S07/S08 和 X02–X06 中适用的协议与传输边界。
入站认证及本地挑战相关断言不适用；改为验证无需凭据、剥离代理凭据字段且不生成 407。
使用可观察 Channel/Wire/时钟验证回复短写、DNS 零调用、成功屏障、每种 EOF、取消和迟到回调；
不能只用一次浏览器 HTTPS 访问证明符合规范。
模型/Core/listener/运行周期的联动未完成时，组件目标可据此实施，但整体 profile 尚不可宣称通过验收。
