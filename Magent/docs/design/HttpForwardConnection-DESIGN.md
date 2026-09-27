# HttpForwardConnection Product Design

更新日期：2026-09-27。状态：**目标设计**；依据对应 SPEC 设计完整产品流程，
不按当前源码裁剪能力，不表示实现或运行验证已经完成。

规范基线：[HTTP SPEC v0.2.0](../HTTP_PROXY_SPEC.md)、[Wire SPEC v0.3.0](../WIRES_SPEC.md)，
均为 2026-09-26 工作树草案。模型依赖 [MODELS SPEC v0.4.2](../MODELS_SPEC.md)。
客户端调用入口引用 [ProxyConnection](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)，
后续 CONNECT 委托 [HttpConnectConnection](HttpConnectConnection-DESIGN.md)。

当前产品范围不支持入站认证。引用 SPEC 中的 Basic、用户/密码配置、本地 407 挑战及相关验收
不纳入本设计；本轮范围调整以此为准，其余协议约束继续适用。

## Context

`HttpForwardConnection` 拥有一条 HTTP 客户端连接上的事务调度：每次从请求行重新提取业务目标，
检查策略、路由、建立专属出站，重建源站请求，增量处理响应，再决定是否接收下一请求。
同一客户端连接可以依次访问不同目标；不能在第一条请求以后退化为到第一个网站的盲目字节转发。

本组件支持 HTTP/1.1 absolute-form、流式请求/响应体、chunked 和允许的 Trailer、Expect/1xx、
本地 OPTIONS、顺序 keep-alive、有界 pipelining、WebSocket Upgrade，以及后续 CONNECT 的交接。
每条客户端连接至多一个活动事务；同一事务的上传与响应读取可以并行。

`MagentTCPConnection` 拥有 accepted Channel 与最终关闭。本组件拥有客户端解析/预读、当前事务、
源站响应解析、本地响应写权、下游 Channel 和可选 TCP Wire。Core 负责路由和出站创建；
Wire 负责出站协议。普通事务完成只关闭自己的出站，不因此关闭可复用的 accepted Channel。

不提供源站连接池、HTTP 缓存、内容解压缩、自动跟随重定向、业务请求重放或失败直连回退。
不接受入站 origin-form、absolute HTTPS、HTTP/1.0、h2c、HTTP/2 prior knowledge 或 HTTP/3。
透明隧道内的业务协议不受上述入站协议范围限制。

## Contract

### 受限类型与 24 个方法

受限类型为 `HttpForwardConnection`，固定 **24 个方法**：1 个构造、3 个引用的入口、
4 个 NIO 回调及 16 个私有产品阶段。无其他自有 handler、wrapper、protocol 或公共 API。
所有 extension 受同一集合限制，不添加 helper、重载或默认参数；未标 `throws` 即不抛错，
没有 `static`、`async` 或 actor 隔离。匿名异步回调只推进所属阶段，不绕过方法集合另设产品入口。
以下是省略实现的目标声明，其访问级别、参数和返回类型均为硬约束。

所有入口、下游回调、Wire 调用和异步完成后的状态推进都在原 accepted EventLoop 串行执行。
下游 TCP 使用同一服务的 EventLoopGroup 和同一个 EventLoop；双向 I/O 可以独立等待，
不能并发修改同一 Wire/事务状态。外部解析结果回到该 EventLoop 后检查 generation，
不使用阻塞等待、detached Task 或未纳入清理的后台任务。

```swift
/// 在一条 accepted HTTP 连接上串行调度事务，并管理合法的协议切换。
internal final class HttpForwardConnection: ChannelInboundHandler, ProxyConnection {
    typealias InboundIn = ByteBuffer
}

/// 绑定 accepted Channel 与其接入时的 Core；不提前路由或创建出站。
internal init(proxyChannel: Channel, core: MagentCore)
```

构造由 `MagentTCPConnection` 调用。Core/配置绑定覆盖整个客户端 TCP 生命周期，包括后续请求及
CONNECT/WebSocket 隧道。服务级预算、时钟、Resolver 和停止信号仍由运行周期装配，
本设计不新增未经定义的配置对象、依赖 getter 或测试专用构造入口。

三个客户端入口的精确声明及参数含义引用
[ProxyConnection（2026-09-27）](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)，
不重复定义协议。

| 入口 | 本组件的固定职责 |
| --- | --- |
| `upstream` | HTTP 模式下无完整请求头时进入 `beginTransaction`；普通活动事务交 `consumeRequestBody`，后续请求只预读。当前请求为 Upgrade 时，头后的客户端字节属于待确认升级余量；等待 101 或写 101 期间仅有界保存。WebSocket 态调用 `relayClient`；CONNECT 委托态只调用子对象同名入口。 |
| `proxyInputClosed` | 标记客户端不会再输入，先处理已读缓冲；缓冲消费完仍缺当前头/body 才按截断失败，不把背压暂停误判为截断。完整请求可等待响应，后续预读只在轮到时处理；WebSocket 排空后半关闭；CONNECT 态仅转交同名入口。 |
| `closeConnection` | 置终态并使事务 generation 失效，释放自己的出站/余量/期限/许可；有 CONNECT 子对象时将同一个原始 error 转交其清理入口一次。不写新响应、不关闭 accepted Channel、不重入失败流程。 |

### NIO 回调

以下四项来自 SwiftNIO
[`ChannelInboundHandler`](https://github.com/apple/swift-nio/blob/21de5f08c1a166a6dd293d0e587ad977bf8dac5d/Sources/NIOCore/TypeAssistedChannelHandler.swift)，
只用于当前普通 HTTP 或 WebSocket 的下游 Channel，不是 accepted 输入入口。

```swift
/// 读取当前事务下游，完成 Wire 解码后进入 HTTP 响应解析或 WebSocket relay。
internal func channelRead(context: ChannelHandlerContext, data: NIOAny)

/// 对当前下游的正常输入 EOF 执行双层完整性检查，其他事件继续传播。
internal func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)

/// 处理当前下游全关闭，区分事务完成、正常 EOF 与活动传输失败。
internal func channelInactive(context: ChannelHandlerContext)

/// 将当前下游的原始错误交事务失败边界，忽略已释放事务的迟到事件。
internal func errorCaught(context: ChannelHandlerContext, error: Error)
```

回调首先核对 context.channel 与当前事务 generation；旧事务主动关闭产生的 inactive/error
不能关闭下一事务。`channelRead` 的普通 HTTP 路径先做可选 Wire 解码，再交 `consumeResponse`。
合法 101 已被接受而尚未写完时，当前模式仍为 HTTP，但后续解码业务只保存为升级余量，不再调用
`consumeResponse`；WebSocket 路径交 `relayRemote`。Wire 尚未初始化时只保留有界原始输入。
`.inputClosed` 或未见 EOF 的正常 inactive 调用 `finishRemoteInput`；已知错误/取消不再用 EOF 检查
覆盖首因。真正活动的下游错误交 `fail`，不是所有 inactive 都意味着 accepted 必须关闭。

### 16 个产品阶段

```swift
/// 纯增量解析一条请求头，保留重复字段和输入余量；不足返回 nil。
private func parseRequestHead(_ input: inout ByteBuffer) throws -> HTTPRequestHead?

/// 在当前轮次启动一个请求；普通请求进入语义校验和出站，CONNECT 进入唯一交接。
private func beginTransaction(context: ChannelHandlerContext) throws

/// 为当前目标完成一次路由、专属出站建立及可选 Wire 启动写入。
private func openOutbound(target: NetworkAddress) -> EventLoopFuture<Void>

/// 按顺序编码已校验的源站请求事件，并通过当前 DIRECT 或 Wire 路径写出。
private func forwardRequest(_ part: HTTPClientRequestPart) -> EventLoopFuture<Void>

/// 流式消费当前请求体与 trailer，精确停在本请求边界并保留下一请求。
private func consumeRequestBody(_ input: inout ByteBuffer) throws

/// 增量处理源站状态行、头、body、trailer 和信息响应，不越过当前响应边界。
private func consumeResponse(_ input: inout ByteBuffer) throws

/// 编码并提交一个已验证的客户端响应事件，统一仲裁最终响应与升级提交权。
private func writeResponse(_ part: HTTPServerResponsePart) -> EventLoopFuture<Void>

/// 结算当前事务并释放专属出站，仅在请求和响应边界均完成后启动下一轮次。
private func finishTransaction()

/// 把本轮 CONNECT 的全部原始字节及后续生命周期交给唯一 HttpConnectConnection。
private func beginConnect(context: ChannelHandlerContext)

/// 完整提交已经验证的 101 后交出双方 HTTP 读写权，进入 WebSocket 原始 relay。
private func startWebSocket(_ head: HTTPResponseHead) -> EventLoopFuture<Void>

/// 在 WebSocket 升级完成后发送客户端原始业务，PROXY 继续经过同一 Wire。
private func relayClient(_ data: ByteBuffer) throws

/// 在 WebSocket 路径解码下游业务，101 写完前保留、之后按序交付。
private func relayRemote(_ data: ByteBuffer) throws

/// 先检查正常 Wire EOF，再按当前 HTTP framing 或 WebSocket 方向处理结束。
private func finishRemoteInput() throws

/// 保留当前首次原始错误，按最终提交状态生成一次本地错误或直接结束。
private func fail(_ error: Error)

/// 串行写入节点启动字节或已经编码的业务字节，并返回整批写入完成结果。
private func writeRemote(_ data: ByteBuffer) -> EventLoopFuture<Void>

/// 串行写入 accepted Channel，承载所有 HTTP 响应和升级后的反向字节。
private func writeClient(_ data: ByteBuffer) -> EventLoopFuture<Void>
```

| 方法 | 调用方 | 完成含义和后继 |
| --- | --- | --- |
| `parseRequestHead` | `beginTransaction` | 只做字节语法、限额、原始字段保留和消费边界；无网络副作用。头/body 同批到达不把 body 算进头部大小，维护增量扫描位置。 |
| `beginTransaction` | `upstream`、`finishTransaction` | 只在 HTTP 模式无已完成头部的活动事务时执行，部分头沿用本轮身份。仅在轮到处理时识别精确 CONNECT，并在消费其原始头前转 `beginConnect`；其他请求解析完整头并保存已校验语义。有效本地 OPTIONS 直接响应，其他请求经目标/安全校验后 `openOutbound`。 |
| `openOutbound` | 当前请求语义/目标检查成功路径 | future 成功表示 DIRECT 已连接或 Wire 初始化和启动写入均完成。随后先 `forwardRequest(.head)`，并独立启用响应读取；不等完整 body，不生成代理成功 200。 |
| `forwardRequest` | 出站就绪路径、`consumeRequestBody` | 接受重建的 head、内容片段、合法 trailer/end；使用 NIO 编码，再可选 Wire 编码，最后 `writeRemote`。只有最后一个请求事件写完才算 requestWriteCompleted。 |
| `consumeRequestBody` | `upstream`、出站就绪后预读排空 | 按 BodyPlan 产生有界内容/end 事件交 `forwardRequest`；未就绪或写队列满时暂停。请求完整后只保留后续字节，不路由下个目标。提前最终响应后停止生产上传事件。 |
| `consumeResponse` | `channelRead` 的原始/解码业务路径，且尚未接受合法 101 | 按完整头选择 framing、重建字段；信息/最终事件交 `writeResponse`，合法 101 交 `startWebSocket` 并在头结束处停止消费。同批及后续帧字节均归升级余量。普通 body 流式处理，错误抛回最高事务边界。 |
| `writeResponse` | `consumeResponse`、本地 OPTIONS、`startWebSocket`、`fail` | head 首字节提交前占有对应响应序号及最终提交权；信息响应不占最终权，101 占有。编码后 `writeClient`；final end 写成才标记 finalResponseCompleted。普通响应通知 `finishTransaction`，101 只完成 `startWebSocket` 的写屏障，本地错误只完成 `fail` 的收尾。 |
| `finishTransaction` | 请求 end 或最终响应 end 的写完成回调；EOF 定界完成路径 | 普通复用要求请求已完整消费/写成且响应已写完；本地 OPTIONS 没有请求出站写入，此条件直接满足。释放当前出站、Wire、事务许可、期限，失效旧 generation。满足复用条件才开始下一请求；提前响应等关闭路径不等待永远不会到达的剩余上传。 |
| `beginConnect` | `beginTransaction` 本轮次确定 CONNECT 后 | 旧事务和写队列均已结算，保存子对象并进入 delegatedConnect，再把全部未消费原始字节交其 `upstream`。本对象永久停止 HTTP 解析和响应写入。 |
| `startWebSocket` | `consumeResponse` 完成合法 101 检查后 | 通过 `writeResponse` 写完整升级响应；升级请求 end 与完整 101 均写成后 future 才成功，转 raw relay、释放事务/握手额度、排空双方余量；保留同一出站和 Wire。非 101 不调用。 |
| `relayClient` | WebSocket 态 `upstream`、升级后余量排空 | DIRECT 透明，PROXY 以 nil 地址编码；调用 `writeRemote`，不解析 WebSocket frame。 |
| `relayRemote` | WebSocket 态 `channelRead`、升级后反向余量排空 | DIRECT 透明，PROXY 只解码一次；调用 `writeClient`。已在解析 101 时解码的余量直接排空到客户端，禁止再次 Wire 解码。 |
| `finishRemoteInput` | 当前下游正常 EOF / inactive；初始化后续接已记录 EOF 的回调 | PROXY 先恰好一次 `finishInbound`。普通 HTTP 再验证消息 framing；已接受合法 101 时记录隧道 EOF，等待升级屏障完成后排空并半关闭，不再按 HTTP EOF 定界。完整性错误回到 `fail`。 |
| `fail` | 客户端/NIO 边界、future 失败、期限 | 保存首因、停止新上传/解析/路由；未最终提交时生成一个本地错误并限时写出，之后上报 accepted pipeline；已提交则只结束。不能抢占前一事务的响应序号。 |
| `writeRemote` | Wire 启动、`forwardRequest`、`relayClient` | 启动原始字节与已编码业务有序，写成归还缓冲，失败原样返回。不能把未编码业务误当节点启动数据。 |
| `writeClient` | `writeResponse`、`relayRemote`、101 后已解码余量排空 | 同一方向只有一个在途写入者；响应头、body、最终 end 和隧道余量不会交错。 |

具有同步抛错的阶段不在内部 catch 后包装或改路；由 `upstream`、`channelRead` 等最高边界调用 `fail`。
异步失败保持原始 error，经所属 future 的边界收敛。失败响应自身写错只记录，不能覆盖首次终因。

### 协作者的调用契约

| 协作者 | 本组件允许且必须完成的调用责任 |
| --- | --- |
| Wire v0.3.0 | 精确引用[抽象接口](../WIRES_SPEC.md#抽象接口草图)和 [HTTP SPEC §14](../HTTP_PROXY_SPEC.md#s14)。每事务独立 TCP Wire；`openOutbound` 读取稳定端点/毫秒超时、单次启动；请求字节编码，响应字节解码；正常 EOF 才检查 `finishInbound`。不复制其声明。 |
| HttpConnectConnection | 调用其设计中唯一 `init(proxyChannel:core:requestDeadline:)`，传入本轮已有绝对截止点；交接后只调用已经引用的三个 `ProxyConnection` 入口。另在本地 OPTIONS/错误响应时调用其[共用 `localResponse` 声明](HttpConnectConnection-DESIGN.md#产品阶段的固定声明)，不复制响应构造器。 |
| HTTP / 地址模型 | NIOHTTP1 保留有序重复字段；HttpProtocol 负责请求语义、NetworkAddress 负责地址身份。本文不增加另一套目标/规则模型；完整 HTTP 能力须由下述模型联动先决条件解决。 |
| Core / 服务 | 每个业务请求或隧道一次路由；消费实际资源许可、绝对名称 Resolver、数值候选拨号和停止通知。它们的方法签名需在各自设计定义，不能在 Connection 文档中凭空添加。 |

普通业务字节始终是重建的源站 HTTP 请求；使用 Wire 不改变 origin-form 或业务 Host，
`Proxy-Authorization` 永远不进入业务字节。Wire 的节点控制字节也不能进入 HTTP 响应解析器。
TCP 空解码结果表示继续等待，不是空响应或 EOF。decode 不等待完整 HTTP 消息。

已经评估三个 Connection 间的共用责任：请求语义归模型，路由/DNS/拨号归 Core/服务，本地无体响应
共用已有 HTTP 类型的方法。CONNECT 的成功屏障与 Forward 的持续双向 HTTP framing 不同，
因此各自保留状态推进和清理入口，不为外观相似创建通用 relay/事务包装文件。

### 状态契约

HTTP Forward 的设计单位是“一个可复用的客户端连接及其顺序事务”。普通 HTTP 每轮重新解析目标，
上传与响应可以并行；WebSocket 切换后保留当前下游并处理原始字节；后续 CONNECT 则永久交给
子对象。因此按输入处理者与资源归属定义 **4 种模式**。空闲和事务进度由当前事务是否存在及其数据表达。

```swift
/// 决定客户端输入由 HTTP、WebSocket 或 CONNECT 子对象处理。
private enum State {
    case http
    case webSocket
    case delegatedConnect
    case closed
}

/// 构造后等待首个 HTTP 请求。
private var state: State = .http
```

`State` 是本类型内部的私有数据枚举，没有方法。保留 `.delegatedConnect` 是因为它需要把入口
交给另一对象；`.webSocket` 则由本组件继续转发，二者的所有权不同。

| 状态 | 允许的行为 | 转换条件与负责方法 |
| --- | --- | --- |
| `.http` | `beginTransaction` 串行开始事务；请求上传与响应读取并行；`finishTransaction` 完成后仍为 `.http`，处理下一请求。 | 合法 101 完整写成且升级请求 end 写成后，由 `startWebSocket` 进入 `.webSocket`；本轮 CONNECT 由 `beginConnect` 进入 `.delegatedConnect`；结束或失败进入 `.closed`。 |
| `.webSocket` | `relayClient` / `relayRemote` 使用同一下游和 Wire 透明转发，半关闭方向独立。 | 两方向结束、错误或取消时进入 `.closed`；不返回 HTTP。 |
| `.delegatedConnect` | 三个共享入口只转交唯一 `HttpConnectConnection`，本对象不再解析或写响应。 | accepted owner 调用 `closeConnection` 时进入 `.closed`，并清理子对象一次。 |
| `.closed` | 不开始事务、路由、解析或转发；只完成已安排的本地错误响应及资源清理。 | 吸收终态。 |

所有转换在 accepted EventLoop 串行执行。合法 101 正在写入时仍为 `.http`，但当前事务已经
占用最终响应权，解析精确停在升级边界；两侧余量只缓冲，不能当第二条 HTTP 消息处理。
是否有活动事务、是否已接受升级由本轮数据表达。

| 必须保存的数据 / 事实 | 初值与固定约束 |
| --- | --- |
| 当前事务与请求序号 | 初始无事务、序号 0；轮到处理且首字节可用时才创建事务身份并增加序号。分片沿用同一身份；请求头解析、目标、framing、下游、Wire 和期限均归该事务。 |
| 请求消费完成 / 写出完成 | 每轮初始均为否；精确消费 body / trailer 边界与请求 end 的写成分别记录；本地无体 OPTIONS 无出站写入，直接满足相应条件。 |
| 最终响应提交 / 完成 | 每轮初始均为否；第一次提交最终 head 前占用，最终 end 写成才完成。普通 1xx 不占最终权，101 占用；不由“已收到完整响应”推断“已写完”。 |
| 提前最终响应、升级是否已接受、信息响应计数 | 每轮初始否 / 否 / 0；提前最终响应停止新增上传并要求关闭；合法 101 接受后保留升级余量，最多 16 个普通 1xx。 |
| 客户端 EOF、下游 EOF 及检查事实、输出半关闭事实 | 初始均为否；客户端 EOF 属于整条连接，不能换轮后重置；下游检查属于当前 Channel，WebSocket 继承同一 Channel 的事实。 |
| 是否允许下一事务、客户端写是否失败 | 初始是 / 否；close 策略、提前响应、上限或停机可禁止下一事务，不能在结算时恢复。任意客户端写失败后不追加 HTTP 错误。 |
| CONNECT 子对象 | 初始 nil；交接时保存唯一对象并失效父事务；所有后续输入和清理只转交一次。 |
| 首次错误、是否已上报、是否已清理 | 初始 nil / 否 / 否；首次会话错误不因结算而清空，上报和最终清理各一次。 |

以上为事务及传输事实，不另设状态枚举。HTTP 消息自身的
CL / chunked / trailer 解析进度由既有 codec / framing 契约负责，不提升为 Connection 生命周期状态。

`finishTransaction` 只有在请求完整消费且写成、最终响应完整写成、允许复用时才失效旧事务、
释放旧出站并处理下一轮。提前最终响应等关闭路径不等待被放弃的上传；普通 1xx 不结束事务，
101 也不走普通事务结算。已成功写出 103 后仍可写最终错误；103 部分写失败后不能再拼接 502。

每个异步回调同时检查当前模式、事务身份及 Channel；旧事务事件只归还自身资源，不能关闭
下一事务。WebSocket 保留原下游及身份；CONNECT 交接失效父事务并停止父期限。半关闭先完成
正常 Wire EOF 检查及方向排空，不能把单侧 EOF 当整体结束，也不能重复检查同一下游。

`fail` 固定首因及允许的本地错误响应后进入 `.closed`，限时完成该响应并上报。正常结束也先
进入 `.closed` 再请求 accepted 关闭。`closeConnection` 执行尚未完成的清理，不能仅因 state
已经 closed 而跳过；子对象也只清理一次。优雅停机保持活动模式并禁止下一事务，宽限到期才关闭。

### 数据所有权

| 数据 / 状态 | 固定约束 |
| --- | --- |
| 客户端状态 | 仅使用 `.http`、`.webSocket`、`.delegatedConnect`、`.closed`；空闲和活动事务都属于 HTTP 模式，协议切换后不再返回 HTTP。 |
| 请求序号和 generation | sequence 在同一客户端单调递增；每个事务一个 generation。旧出站回调在接触本轮状态前必须失效检查，不能只检查客户端尚未关闭。 |
| 当前请求 | 原始头、经校验的不可变语义、逻辑目标/决策、BodyPlan、请求消费结束及写出完成分别保存；本地 OPTIONS 无业务目标/出站，不保存 principal 或客户端凭据状态。 |
| 当前响应 | 当前响应头、BodyPlan、1xx 数量、finalResponseCommitted / Completed、提前最终响应标记；205 和 HEAD/304 的语义不同。 |
| 缓冲 | 当前请求余量、下一请求预读、源站原始/解码余量及双向在途写均有唯一归属和共享额度；借用视图跨异步保存前取得有界所有权。 |
| 出站 | 每普通事务独占下游/Wire及在途候选；事务结束释放，不放池。WebSocket 成功则保留直到隧道结束。 |
| CONNECT 子对象 | 至多一个，仅在永久交接后存在；原 accepted Channel/Core/context 不变。父对象不再拥有该子对象内部缓冲和下游的释放权。 |

### 外部规范衔接

| 事项 | 目标及前置条件 |
| --- | --- |
| HttpProtocol 的范围 | [MODELS 有限范围](../MODELS_SPEC.md#支持范围与-http-规范的关系) 明确不支持 chunked、Expect、Upgrade、OPTIONS *、流水线和长连接，并允许 origin-form/1.0；HTTP v0.2.0 要求相反的完整 profile。必须联动升级模型声明、连接消费规则和验收；不将这些功能标成可选，也不以新增影子请求模型绕过规范。 |
| 路由模型 | HTTP §11 的顺序首条、端口/transport、REJECT 与 MODELS 的 order/具体性、仅 direct/proxy 不一致。Core 和模型须一起对齐；不能只靠 Connection 文档声称现有契约已满足。 |
| listener 与配置 | HTTP §5 的 HTTP-only 接入要求必须由上层装配落实；混合监听不能宣称该 profile 的 listener 合规。HTTP §20.7 要求 accept 时固定配置，后续请求仍使用它，旧配置不会被中途替换。 |
| 停机和依赖 | 按 HTTP §21 停止新事务、排空当前请求/隧道；不能先关闭 accepted 再称为优雅停止。预算、系统解析池、时钟及停止订阅的 API 由其 owner 完成，不新增第四个 ProxyConnection 方法；不装配入站凭据验证器或认证配置。 |

本设计按开篇的无入站认证范围消费入口 SPEC；在上述规范差异解决前不能声称同时满足所有模型与包级契约。
其余能力不根据实现情况裁剪，认证也不作为待补齐的实施前置条件。

## Core Logic

### 建议的方法调用流程图

方法名对应 `Contract`；状态使用上节 `State`，其余方括号为流程条件或外部协作，不新增方法。图中 `child` 是已保存的
`HttpConnectConnection`；“写成/完成”要求对应 future 成功，`.head/.end` 等标记表示按序提交的事件。
同一事务两个 I/O 方向独立推进，下一事务必须等待本事务结算；整个流程没有入站认证阶段。

```text
MagentTCPConnection -> HttpForwardConnection.init(proxyChannel:core:)
  -> upstream(context:data:)
       +-- [.http: 等本轮请求头] -> beginTransaction(context:)
       |    +-- [识别到本轮 CONNECT, 尚未消费原始头] -> beginConnect(context:)
       |    |    -> HttpConnectConnection.init(proxyChannel:core:requestDeadline:)
       |    |    -> [保存 child, 永久进入 .delegatedConnect]
       |    |    -> child.upstream(context:data:) [全部未消费字节]
       |    |
       |    +-- [普通请求] -> parseRequestHead(&input)
       |         +-- nil -> [保留进度, 等下一次 upstream]
       |         +-- 完整 -> [语义、目标与安全校验]
       |              +-- [本地 OPTIONS] -> HttpConnectConnection.localResponse(status: 204, headers: ...)
       |              |    -> writeResponse(.head/.end) -> writeClient(...)
       |              |    -> [最终响应写成] -> finishTransaction()
       |              +-- [转发] -> openOutbound(target:) -> [出站就绪]
       |
       +-- [.http: 活动事务] -> consumeRequestBody(&input) [见双向流程]
       +-- [.http: 合法 101 尚未写成] -> [有界保留客户端早到字节]
       +-- [.webSocket] -> relayClient(data) [见升级流程]
       +-- [.delegatedConnect] -> child.upstream(context:data:)

openOutbound(target:) -> [Core 对本次目标路由并创建专属出站]
  +-- [DIRECT 已连接] -> [出站就绪]
  +-- [PROXY 节点已连接] -> Wire.start(handshake: target)
                             +-- nil -> [出站就绪]
                             +-- 启动字节 -> writeRemote(...) -> [写成: 出站就绪]
[出站就绪] -> forwardRequest(.head) -> [启用下面的双向 HTTP 流程, 不等待完整上传]
```

请求与响应共用现有的有序写入方法；信息响应不会触发事务完成，普通最终响应和升级响应分别处理：

```text
[请求方向: upstream / 出站就绪后的请求余量]
  -> consumeRequestBody(&input) -> forwardRequest(.body/.end)
forwardRequest(.head/.body/.end)
  -> [HTTP 编码, PROXY 再 Wire.encodeOutbound] -> writeRemote(...)
       +-- [当前批次写成] -> [按额度继续接收/消费请求]
       +-- [请求 end 写成] -> finishTransaction() [仅检查完成条件]
[已消费到本请求边界] -> [保留下一请求原始字节, 不提前调用 beginTransaction]

[响应方向: 下游 channelRead(context:data:)]
  -> [DIRECT 直通 / Wire 已初始化后 decodeInbound]
       +-- [已接受合法 101] -> [只保留升级余量, 等待写屏障]
       +-- [仍处理 HTTP 响应] -> consumeResponse(&input)
            +-- [头/内容不足] -> [保留解析进度, 按额度等后续输入]
            +-- [普通 1xx] -> writeResponse(...) -> writeClient(...) -> [继续等响应]
            +-- [普通最终响应] -> writeResponse(.head/.body/.end) -> writeClient(...)
            |    -> [最终 end 写成] -> finishTransaction()
            +-- [上传未完成就收到最终响应]
            |    -> [停止新增上传, 响应声明 close]
            |    -> writeResponse(.head/.body/.end) -> writeClient(...)
            |    -> [响应写成] -> finishTransaction() [关闭路径, 不等剩余上传]
            +-- [合法 101] -> startWebSocket(head) [见升级流程]

finishTransaction()
  +-- [本次尚未满足结束条件] -> [等待本事务其他完成事件]
  +-- [可复用且请求/响应均已完成] -> [释放旧出站和 Wire, 失效旧 generation]
  |    -> beginTransaction(context:) [预读已有下一请求时, 否则等首字节]
  +-- [响应写成且本次要求关闭] -> [释放旧事务, 丢弃预读, 请求 accepted 结束]

startWebSocket(head) -> writeResponse(.head/.end) -> writeClient(...)
  -> [完整 101 及请求 end 写成: .webSocket, 保留同一个出站/Wire, 不走普通事务结算]
       +-- [客户端余量及后续 upstream] -> relayClient(data)
       |    -> [DIRECT 直通 / Wire.encodeOutbound] -> writeRemote(...)
       +-- [后续下游 channelRead] -> relayRemote(data)
       |    -> [DIRECT 直通 / Wire.decodeInbound] -> writeClient(...)
       +-- [解析 101 时已经解码的余量] -> writeClient(...) [不重复解码]
```

本地 OPTIONS 没有出站请求写入，其请求写完成条件直接满足。最终提交标记在第一次提交最终响应
字节前设置；101 写成后由升级路径接管，不因 `.end` 误调用普通 `finishTransaction` 关闭隧道。
后续响应/关闭事件先核对 Channel 和 generation，旧事务事件不能影响当前事务。

```text
proxyInputClosed(context:)
  +-- [HTTP 已读缓冲消费完仍缺头/body] -> fail(error)
  +-- [HTTP 请求完整] -> [等待本事务响应; 已接收请求按顺序处理后结束]
  +-- [WebSocket / 升级中] -> [等待升级结果, 排空后半关闭下游输出]
  +-- [.delegatedConnect] -> child.proxyInputClosed(context:)

userInboundEventTriggered(.inputClosed) / channelInactive([正常且未处理 EOF])
  -> finishRemoteInput() -> [PROXY: Wire.finishInbound(); DIRECT: 跳过]
       +-- [HTTP] -> [校验消息 framing; 正常结束并排空写入后 finishTransaction()]
       +-- [WebSocket] -> [反向排空后半关闭客户端输出, 另一方向继续]
       +-- [Wire/HTTP 截断] -> [所属 NIO 回调] -> fail(error)

errorCaught(error) / [入口原始错误、当前事务 future 失败、期限到达]
  -> fail(error) [.closed, 完成本次错误收尾]
       +-- [最终响应未提交且可写] -> HttpConnectConnection.localResponse(status: 错误状态, headers: ...)
       |    -> writeResponse(.head/.end) -> writeClient(...)
       |    -> [写完或回复期限到达: REPORT]
       +-- [已最终提交/隧道已建立/不可写] -> [REPORT]
[REPORT] -> accepted.pipeline.fireErrorCaught(原始错误)
  -> MagentTCPConnection.errorCaught -> closeConnection(error:)
[正常结束后 accepted 失效] -> MagentTCPConnection.channelInactive -> closeConnection(error: nil)

closeConnection(error:) -> [.closed, 执行尚未完成的清理并失效回调]
  +-- [自身 HTTP/WebSocket 资源] -> [幂等释放下游、缓冲、期限与许可]
  +-- [持有 CONNECT 子对象] -> child.closeConnection(error:) [同一原始错误, 恰好一次]
```

本地错误响应由 `fail` 等待写完后上报原始错误，不进入可复用事务路径。子对象的错误也只经
accepted pipeline 回到主 handler，再由父对象转交清理，不能反向调用父对象形成关闭环。

### 一个普通请求的流程

1. 当前轮次从原始预读字节开始，按字节读取完整 HTTP/1.1 头，保存重复字段和精确消费量。
   校验 CRLF、Host、CL/TE、Connection tokens、Trailer 声明及严格限额；不执行本地认证。
2. absolute URI 决定业务目标；合法但冲突的 Host 记录诊断并按 URI 重建。
   `http` 空 path 通常补 `/`，path/query 的转义与顺序保持原字节；显式端口和域名根点保留。
   不从 origin-form 的 Host 猜目标，不将 `https://` 明文转发到 443。
3. `OPTIONS *` 或合法 `Max-Forwards: 0` 在本地返回无 CL/TE/body 的 204，无 DNS、无出站。
   此分支要求无 body、无 Expect。正数 Max-Forwards 转发前减一；普通 OPTIONS 空 path 且无 query
   发给源站时使用 `*`。TRACE 返回 403；合法扩展方法保留。
4. 其他请求按目标执行安全检查及一次路由。DIRECT 域名才使用受控绝对名称系统解析，
   校验获准数值候选后拨号；PROXY 不做目标 DNS，只消费所选 Wire 的稳定端点。
   路由固定后不再按解析 IP 重选出口，REJECT 不产生网络副作用。
5. 出站就绪后发送重建请求头，随后流式发送 body/trailer；与此同时读取响应。
   DIRECT 与 PROXY 都输出 origin-form、业务 Host 和 Via，移除本地代理凭据及被消费的逐跳字段。
   普通请求输出本跳 `Connection: close`，WebSocket 握手重建 Upgrade；不生成代理成功 200。

所有请求均无需客户端凭据。`Proxy-Authorization` 只受普通字段语法和头部限额检查，
其全部实例在重建出站头时移除，不做 Basic 解码、密码验证或身份保存，也不生成本地 407 或
`Proxy-Authenticate`。该规则同样适用于本地 OPTIONS、后续请求和 WebSocket 握手。
源站业务的 `Authorization`、`WWW-Authenticate` 及 Cookie 按端到端字段保留，不由代理验证。

字段与 framing 的完整要求分别引用 [HTTP §7–9](../HTTP_PROXY_SPEC.md#s07)。
不得先删除 TE 再判断长度，或将合法 GET body 按方法名忽略。CL/TE 同时存在、重复 CL
（即使相同）、逗号 CL 均拒绝。单独 chunked 支持流式解码和重编码；最后编码非 chunked 为 400，
`gzip, chunked` 为 501。大 chunk 不按声明长度一次分配内存，零块后必须消费合法 trailer 和最终空行。

Trailer 只允许规范列出的 content-digest、repr-digest、digest、server-timing，
实际字段必须在合法声明集合中；不合并进初始头，不验证摘要或改写内容编码。
未知声明、禁止字段、未声明实际 trailer 按发现阶段拒绝，不能静默丢弃后伪造成功结束。

### 响应、Expect 与提前结束上传

响应增量解析覆盖 HTTP/1.1 和源站 HTTP/1.0。输出采用 HTTP/1.1，Via 记录实际收到的版本，
保留多条 Set-Cookie 以及端到端字段，消费逐跳字段并重建本跳 framing。
HEAD/304 可保留合法 CL 元信息但不读 body；1xx/204 不允许 CL/TE；205 必须验证实际零内容，
仍消费其 CL=0、零 chunk 或空 EOF framing，不能直接当成 204。

定长响应精确消费 CL；chunked 响应重新分块、检查允许 trailer；额外响应字节不是下一事务响应，
关闭该出站并记录异常。EOF 定界响应向客户端声明 close，直到正常下游 EOF 后排空并关闭客户端；
不得为它生成“成功结束”的 chunked。PROXY EOF 先通过 Wire 完整性检查，再检查 HTTP framing。

`Expect: 100-continue` 请求先完成校验并转发头，立即读取响应，不缓存完整上传。
客户端自己开始 body 时正常接收。合法 100/102/103 等有序转发，单请求最多 16 个信息响应；
它们不占最终提交权，也不刷新最终响应头的绝对期限。

源站在上传结束前给出最终响应时，停止调度新的上传写入，继续返回该响应并声明客户端 close；
已经提交的上传不可撤回。剩余客户端 body 不作为下一请求，不为 keep-alive 无界丢弃上传。
源站正常 401 及其 `WWW-Authenticate` 保留；异常源站 407 映射本地 502，不向客户端转发代理挑战。

最终响应第一字节提交前设置 committed；完整 end 写成才设置 completed。
任何已提交的最终响应随后失败只终止，不追加第二条 502，不补缺失内容或 chunk 终止块。
已写 103 但未最终提交时仍可生成一次最终错误。

### 顺序复用与后续请求

当前请求完整消费且请求写成、最终响应准确结束并写成，才允许下一轮。
客户端 close、EOF 定界响应、提前最终响应、本地错误、截断、停机或请求数上限都会阻止复用。
默认最多 1000 请求，配置须为正数。源站主动 close 本身不阻止客户端复用，前提是本次消息边界完整。

流水线只保留原始有界预读，不为后续请求提前路由、申请出站或生成响应。
第二请求即使已看得出非法，也要在第一响应结束后才处理其错误；第一事务要求关闭时直接丢弃后续字节。
每请求独立申请事务/握手许可，独立路由、Wire 和出站，沿用同一 accept 配置。

### 后续 CONNECT 的交接

当本轮原始请求行为精确 CONNECT 时，`beginConnect` 按以下顺序交接：

1. 确认上一事务全部结算，旧出站和其回调已失效，客户端写队列没有前一响应。
2. 归还本对象本轮已申请的事务/握手许可，使用原 accepted Channel、Core 和本轮已有
   `requestDeadline` 构造一个 `HttpConnectConnection`，保存子对象并进入 delegatedConnect。
   子对象在处理输入前按同一服务预算申请所需许可；两者不同时持有同一请求的双份额度，
   再申请仍有期限，资源不足正常失败。原会话/socket 许可不释放，头部绝对期限不重置。
3. 将本轮尚未消费的全部原始字节交给子对象 `upstream`，包括完整原始头和早到隧道数据。
   父对象释放这些字节的所有权，不重建一份 CONNECT 请求，也不对它再次执行模型解析或路由。
4. 后续 `upstream`、`proxyInputClosed`、`closeConnection` 原样转交同名入口；已有待处理 EOF
   在字节交付之后转交一次。子对象错误仍走 accepted pipeline，主 handler 只清理其持有的父对象，
   父对象再清理子对象；不建立反向关闭回调。

主 handler 无需重新探测、更换对象或扩充协议。CONNECT 失败就结束该客户端连接；成功后不会再回到
普通 HTTP。`GET a → GET b → CONNECT c` 的目标、响应顺序和生命周期责任由此完整覆盖。

### WebSocket 升级

升级请求仍是 ordinary absolute-form：GET、无 body、无 Expect，Connection 包含 Upgrade，
只支持 websocket；版本必须唯一且为 13，key 唯一且 Base64 解码为 16 字节。
未支持协议/版本为 501，格式或重复字段错误为 400，完整规则引用 [HTTP §19](../HTTP_PROXY_SPEC.md#s19)。

响应 101 必须匹配本请求的 Upgrade、唯一正确的 Accept、已提供的一个子协议且无非法 CL/TE；
未请求升级或非法 101 在提交前转 502。合法 101 经过有序响应写入，完整头写成后才进入 raw relay，
保留同一个目标、决策、下游和 Wire。解析器中同批已解码的第一段 frame 直接交付一次，不能再 Wire 解码。
客户端早到 frame 暂存为升级余量，不作为下一 HTTP 请求。

非 101 最终响应继续按普通 HTTP framing 处理。若该 Upgrade 请求之后已有无法辨认归属的客户端
早到字节，返回最终响应后关闭，不猜测它们是 frame 还是下一请求；没有这种余量时按普通复用条件判断。
升级后不解释 WebSocket frame、子协议或压缩内容，不重新路由，半关闭按隧道规则执行。

### 资源与停止

完整默认值及额度引用 [HTTP §21](../HTTP_PROXY_SPEC.md#s21) 和 [§24](../HTTP_PROXY_SPEC.md#s24)。
头部/字段/trailer/chunk-size 限额同时生效；每个头部最大 32 KiB，客户端预读 64 KiB，
每方向升级余量 64 KiB、读块 32 KiB、方向高/低水位 256/64 KiB，且共同占用 64 MiB 全局缓冲预算。
当前 body 与下一请求预读不能重复计量，也不能放进不受限的 SDK 写队列。

请求头 10 s，keep-alive 空闲 60 s，出站总期限 25 s；DNS/单候选/启动分别 5/10/10 s 并受总期限约束。
Expect 30 s；上传期间用 body idle 60 s，完整请求写完才启动最终头等待 30 s；单个响应头读取 10 s，
1xx 不续期。响应 body idle 60 s、write-stall 30 s；主动背压时由后者约束，不能误判前者。
每方向一次有序写入和有限事件/字节处理额度保证不会用无限 future/Task 隐藏无界缓存。

停止接入后空闲连接关闭，活动响应尽可能声明 close，不执行已预读下一请求；已提交头不事后修改，
在消息边界关闭。当前事务/隧道在 30 s 宽限内排空，到期取消。Wire、自有 Channel 和许可按 generation
释放一次；不可取消 DNS 的真实工作槽仍由其工作池保留到实际退出。
正常最终关闭通过 accepted Channel 的 NIO 关闭流程收敛；错误先经 `fail` 上报，
`closeConnection` 永远只清理自己及 CONNECT 子对象的资源，不再发起 accepted 关闭。

## Corners

### 错误与边界

当前范围的本地响应状态按 [HTTP §23](../HTTP_PROXY_SPEC.md#s23)，不把所有模型错误归成 400。
请求头超限为 431，响应头超限为 502；Wire 启动失败为 502；资源耗尽为 503，
目标解析失败为 502，出站/响应期限为 504。原始错误保留，错误响应不携带凭据或内部路径。

| 场景 | 必须观察到的结果 |
| --- | --- |
| 同 read 内 CL body + 下一请求 | 只消费指定 body 字节；下一请求不会发给本次目标。 |
| 请求/响应逐字节，巨大 chunk 声明 | 结果与连续输入一致；流式消费、无整包内存申请、无空进展忙循环。 |
| 早期 413、103 后失败、最终头部分写失败 | 分别停止上传并返回最终响应、允许一次最终错误、只能中断。 |
| HEAD / 304 非零 CL；205 零 chunk | 前者不等待 body；后者消费完整 chunk framing，不能留下零块作为下一消息。 |
| 源站 EOF / Wire 截断 | 按两层协议分别判断；Wire 截断不完成 EOF 定界消息。 |
| 同客户端两个域名 | 两次独立路由/出站，旧目标或 Wire 不复用。 |
| 缺少或携带 `Proxy-Authorization` | 都不执行认证；全部代理凭据字段被移除，不影响路由或生成 407。普通 HTTP 字段语法错误仍按 400 处理。 |
| 源站业务认证字段 | `Authorization` 请求字段、401 和 `WWW-Authenticate` 响应按业务语义转发，不变成本地认证能力。 |
| 前一响应要求 close，后面已有恶意或合法请求 | 后续全部丢弃，不提前写错、不拨号、不产生副作用。 |
| 101 和第一段 frame 粘包 | 完整头写成后只交付一次余量，升级前后不会重复解码。 |
| 合法 101 正在写，下一次 read 收到 frame 或 EOF | 帧仅进入升级余量；正常 EOF 经 Wire 检查后保存到升级完成，不能继续解析 HTTP、结算普通事务或提前半关闭客户端输出。 |
| 客户端 EOF 到达时，完整 body 尚在背压缓冲中 | 继续按额度消费已读数据；只有耗尽缓冲仍缺消息字节才算截断。 |
| 已关闭源站的迟到 inactive/error | 不影响新事务、后续 CONNECT 或 WebSocket。 |

### 实施验收

覆盖 [HTTP §28](../HTTP_PROXY_SPEC.md#s28) 的 P、F、R、D、O、H、W、S、C、X 各组在当前范围适用的项目；
入站认证、用户/密码配置、依赖认证的接入和本地挑战用例不适用，替换为无需凭据及代理凭据字段剥离检查。
CONNECT 交接另联合 [HttpConnectConnection 的验收](HttpConnectConnection-DESIGN.md#实施验收)，
资源/背压采用 T07–T12。必须包含同一 TCP 上 `GET a → GET b → CONNECT c`、各请求均不要求凭据、
流水线第二请求错误不抢响应、提前最终响应、所有响应 framing、101 余量和旧事务迟到事件。

这些是目标验收条件。本次仅编写设计；在模型/Core/装配契约联动及实现验证完成前，不能声称完整
HTTP profile 已符合规范或具备现成可运行的完整 HTTP 事务 API。
