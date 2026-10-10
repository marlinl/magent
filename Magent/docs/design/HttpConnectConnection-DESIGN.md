# HttpConnectConnection Product Design

更新日期：2026-10-10。状态：**职责与成员设计提案；请求交接接口待确认，尚不能据此直接迁移源码**。
行为基线：[HTTP SPEC](../HTTP_PROXY_SPEC.md)、[Wire SPEC](../WIRES_SPEC.md)、[MODELS SPEC](../MODELS_SPEC.md)。

## Context

上游是 [MagentTCPConnection 的 Core Logic](MagentTCPConnection-DESIGN.md#core-logic)：它完成协议探测，
选择 `.httpConnect` 并持有唯一 `HttpConnectConnection`，首次交付探测缓冲，之后通过
`ProxyConnection.upstream`、`proxyInputClosed`、`closeConnection` 分派字节、EOF 和清理。
accepted Channel 的最终关闭始终由该上游负责；本类借用 accepted，拥有唯一 `wireChannel` 及可选 TCP Wire。

上游当前第 2 步只完成分类与字节交付，不代表 CONNECT 请求完整、合法或握手成功。
本篇后续流程沿用已提出的完整请求交接前提：上游收齐并完成 HTTP 解码及唯一模型校验，
再将最终目标交本类；上游负责本地 200 / 错误响应，本类负责下游建立和隧道转发。
完整目标交接、建立结果回传及 200 写成后的激活接口仍待确认，现行架构、SPEC 和源码尚未迁移。

因此本类流程从“接收已验证目标”开始，依次为 Core 路由与建连、Wire 启动写入、上游完整 200 写成、
隧道转发及收尾。四份文档、五个业务类的整体关系见
[共同设计前提](Socks4Connection-DESIGN.md#context)。隧道中的 TLS、HTTP/2 等作为业务数据，不重新解析或再次选路。

## Contract

### 全部实例成员

本类保留 **5 个基础成员**，计数不构成硬上限或正常 EOF 已闭合的证明。

| 声明 | 用途与生命周期 |
| --- | --- |
| `private let proxyChannel: Channel` | 借用 accepted，用于业务写回与向 owner 报告错误；清理不关闭它。 |
| `private let core: MagentCore` | 当前 runtime 注入；一次路由及下游创建的入口，连接内不更换。 |
| `private var wireChannel: Channel?` | 唯一 TCP 下游，初始 nil，关闭时释放，迟到建连结果直接关闭。 |
| `private var wire: Wire?` | PROXY 保存本连接独占 Wire；DIRECT 为 nil。节点端点、超时和编码使用同一实例。 |
| `private var state: State = .handshaking` | 建立与等待完整 200 合属 `.handshaking`，另区分隧道转发与终止；不以关联值存放额外数据。 |

HTTP 请求缓冲、版本和回复资格属于主 handler；目标、建连 Future、Wire 启动数据及当前写 Future
属于相应操作的局部变量/回调链。回调捕获数据仍须有界；Wire 负责自己的帧分片。
不保存第二份 HTTP 请求、早到响应队列或 `toWireWrite` / `toProxyWrite`。

状态不得携带其他资源，也不能省略必要的结束条件。
不新增基类、资源 struct、闭包容器或源文件。

### State 定义与转换

沿用既有状态名与无关联值枚举，恢复明确初值。`handshaking` 在完整请求交接方案中表示
下游建立及本地成功回复尚未完成，不再表示本类累计协议分片。

```swift
private enum State {
    case handshaking
    case forwarding
    case closed
}

private var state: State = .handshaking
```

| 当前状态 | 允许的输入与操作 | 转换条件及推进者 |
| --- | --- | --- |
| `.handshaking` | 完整目标只接收一次；建立链可拨号并写 Wire 启动数据；不转发客户端或下游业务。 | 主 handler 的完整成功回复写成通知将状态置为 `.forwarding`；建连成功本身不切状态。 |
| `.forwarding` | `upstream` / `channelRead` 转发业务；对应 EOF 入口处理方向结束，另一方向仍可继续。 | 正常双向结束协调完成，或 `fail` / `closeConnection` 终止时进入 `.closed`。 |
| `.closed` | 禁止业务、重复响应及续读；只允许关闭并释放未清理资源、回收迟到 Channel。 | 终态，无回退；重复清理仍检查并释放实际资源。 |

构造设置初态，`fail` 和 `closeConnection` 可从任何非终态进入 `.closed`。
启动与成功回复是一条有序流程；成功回复后启读的跨组件入口仍须确认，不能由普通下游回调擅自激活。
上述枚举定义协议阶段；双向 EOF 和在途写排空的协调要求继续保留，不能据此把单方向 FIN 直接视为整连接关闭。

### 方法契约与待确认交接

保留 [ProxyConnection 三个入口声明](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)。
`upstream` 仅接受激活后的业务字节；`proxyInputClosed` 接收客户端 EOF；`closeConnection` 幂等释放下游，
不生成 HTTP 响应、不关闭 accepted、不重入错误路径。

下游回调沿用现有 SwiftNIO 声明，全部在 accepted EventLoop 执行：

```swift
internal final class HttpConnectConnection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
}

internal func channelRead(context: ChannelHandlerContext, data: NIOAny)
internal func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)
internal func channelInactive(context: ChannelHandlerContext)
internal func errorCaught(context: ChannelHandlerContext, error: Error)
```

`channelRead` 解码并写回业务；正常 EOF 回调执行 Wire 检查与方向结束；异常失效及 `errorCaught`
向 accepted owner 报告原始错误。已终止回调只传播事件或释放资源，不重复清理。

| 待确认接口责任 | 调用方 → 拥有者 | 完成条件 / 原因 |
| --- | --- | --- |
| 目标交接与建立结果 | 主 handler → 本类 → 主 handler | 目标已通过 HttpProtocol 校验；建连及启动写成后才允许 200。 |
| 隧道激活 | 主 handler → 本类 | 完整 200 写成后启动业务读取，客户端与下游都不能越过屏障。 |
| EOF 与最终结束 | 主 handler ↔ 本类 | 先完成已接收数据的写入，再传播 FIN；最终关闭 accepted 由主 handler 执行。 |

不自行新增或修改这些方法的 Swift 签名。旧 `parseRequestHead`、`writeSuccess`、`localResponse`
对应的请求解析及本地回复责任移到主 handler。已有构造、建立、编解码及写入方法声明在下节完整保留；
只对新增跨组件交接单独确认，不把整个原有方法集合改成待定。

### 同文件 NIO 适配器

此前确认的 `HTTPRequestPartsHandler`、`HTTPEncodedBytesHandler` 服务于 HTTP 请求解码和本地报文编码。
在新前提下，这些操作跟随主 handler 的请求/回复流程；它们不拥有本 Connection 的路由、Wire 或生命周期。
不能把请求模型、版本或缓冲偷偷留在这些适配器中，作为本类的隐式成员。

本轮不更改适配器源码、签名或文件位置；后续迁移需确认由谁创建、消费和释放。
本提案所称“五个类”指业务 Connection 类，已有 NIO codec 适配器不算新增 Connection，也不承担新的业务 owner。

#### 已确认的适配器声明与内部成员

以下精确声明及 codec 暂存契约继续保留，运行在 accepted EventLoop；后续随解析/编码调用方迁移，
不增加网络 Channel，不转存 Connection 的 Core、Wire、EOF 或生命周期。两个适配器均沿用无参数默认构造。

```swift
internal final class HTTPRequestPartsHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart

    /// 暂存唯一 head、有界 body、end 及 trailer；第二个 head 或非法次序记录为错误。
    internal func channelRead(context: ChannelHandlerContext, data: NIOAny)

    /// 保存首个原始解码错误，交由当前解析阶段抛出。
    internal func errorCaught(context: ChannelHandlerContext, error: Error)
}

internal final class HTTPEncodedBytesHandler: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = IOData

    /// 有界收集编码器输出；只接收 ByteBuffer，拒绝 FileRegion，不向网络写入。
    internal func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?)
}
```

以下存储成员均为 `internal`，可选值初始为 nil；每次取走结果后清空，适配器不跨请求复用。

| 所属类型 / 声明 | 用途与释放 |
| --- | --- |
| `HTTPRequestPartsHandler` / `var head: HTTPRequestHead?` | 保存 NIO 头及重复字段，交解析 owner 构造一次模型；取走后释放。 |
| `HTTPRequestPartsHandler` / `var body: ByteBuffer?` | 当前 codec 调用的有界正文结果；CONNECT 必须为空，Forward 由请求 owner 取走，不长期留第二份完整请求。 |
| `HTTPRequestPartsHandler` / `var ended: Bool = false` | `.end` 到达后置 true；收到头或字节数相符都不能代替结束事件。 |
| `HTTPRequestPartsHandler` / `var trailers: HTTPHeaders?` | 记录 `.end` 的 trailer，由解析 owner 拒绝不支持的内容；结束时释放。 |
| `HTTPRequestPartsHandler` / `var failure: Error?` | 保存首个解码/事件次序错误，调用阶段原样抛出；不吞错或自行回复。 |
| `HTTPEncodedBytesHandler` / `var bytes: ByteBuffer?` | 当前编码批次的有界字节，最多 64 KiB；取走并清空后交实际网络写入。 |
| `HTTPEncodedBytesHandler` / `var failure: Error?` | 保存首个容量/不支持 IOData 错误，阶段调用方检查；不能以空输出冒充成功。 |

请求必须保留准确余量；CONNECT 解码到 `.end` 且无 body/trailer/额外字节后才建立下游。
Forward 的 body 按模型无体/Content-Length 定界，不把后续请求送入同一 decoder。
`HTTPResponseEncoder` 用于本地响应，`HTTPRequestEncoder` 用于 Forward 请求；编码结果须符合模型的字段契约。
编码 promise 只表示本地字节生成，成功回复屏障以实际网络写 Future 为准。
隧道业务及源站原始响应直接走字节写入路径，不能再次经过 HTTP 编码器。

### 构造与私有方法定义

以下列出完整的构造及私有方法签名，并逐项注明职责。私有方法同样属于 Contract，
不能在精简成员时一并省略、合并或擅自改签名。涉及职责迁移的方法仍保留原声明和去向，
其新归属及调用接口确认前不删除；新增跨组件入口单独确认。
除注明的迁移项外，不通过 extension、helper、wrapper、重载或新文件扩充方法集合；
同步错误原样抛至拥有入口，Future 失败交统一错误边界，不在细节方法包装错误。

```swift
/// 主 handler 注入 accepted 与当前 Core；初始化 handshaking，不访问网络。
internal init(proxyChannel: Channel, core: MagentCore)

/// 解析 HTTP 头并保留重复字段及准确余量，不足返回 nil；解析责任随主 handler 迁移。
private func parseRequestHead(_ input: inout ByteBuffer) throws -> HTTPRequestHead?

/// 路由并建立唯一下游；Future 成功表示连接及 Wire 启动完成，不表示本地 200 已写成。
private func openTunnel(target: NetworkAddress) -> EventLoopFuture<Void>

/// 原完整 200 回复入口；回复责任随主 handler 迁移，实际写成后才允许隧道启读。
private func writeSuccess() -> EventLoopFuture<Void>

/// 按序写回业务字节；返回实际网络写成结果，失败不在此包装。
private func writeClient(_ data: ByteBuffer) -> EventLoopFuture<Void>

/// 写入 Wire 启动或已编码上行业务；返回实际网络写成结果，保持来源顺序。
private func writeRemote(_ data: ByteBuffer) -> EventLoopFuture<Void>

/// 转发态 upstream 调用；DIRECT 透传，PROXY 编码后交 writeRemote。
private func relayClient(_ data: ByteBuffer) throws

/// 下游 channelRead 调用；DIRECT 透传或解码一次后交 writeClient。
private func relayRemote(_ data: ByteBuffer) throws

/// 正常 EOF 入口；检查 Wire，按成功回复与在途写完成条件结束对应输出。
private func finishRemoteInput() throws

/// 统一接收原始错误；主 handler 按回复资格选择本地错误响应或终止。
private func fail(_ error: Error)

/// 原共用本地响应构造器；按请求版本生成 CONNECT 200 或无体错误响应，随回复责任迁移。
internal static func localResponse(version: HTTPVersion, status: HTTPResponseStatus) -> HTTPResponseHead
```

| 方法 | 归属与调用责任 |
| --- | --- |
| `init` | 保留；主 handler 注入 accepted 与 Core，初态 `.handshaking`，不访问网络。 |
| `parseRequestHead` | 请求解析责任随主 handler 迁移；原始 UTF-8、重复字段、准确余量以及 `.end` 检查继续保留。 |
| `openTunnel` | 保留本类建立责任与声明；Future 成功表示 DIRECT 已连接或 Wire 初始化及启动写成，不表示本地 200 已写成。 |
| `writeSuccess` / `localResponse` | 本地回复责任随主 handler 迁移；按请求版本编码，完整 200 是启读条件，一次回复资格不能丢失。 |
| `relayClient` / `relayRemote` | 保留；转发态 `upstream` / 下游 `channelRead` 调用，PROXY 只编码/解码一次，不重新解析隧道业务。 |
| `writeClient` / `writeRemote` | 保留实际字节写入；所属转发或启动流程调用，Future 仅在网络写成后成功。 |
| `finishRemoteInput` | 保留；正常 EOF 或正常 inactive 调用，检查 Wire 并按成功回复及在途写完成条件传播方向结束；不得因恢复声明而虚构已解决排空。 |
| `fail` | 保留统一错误入口；转交原始错误，由主 handler 按本地回复是否已开始处理，不由 codec 或帮助方法另行回复。 |

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

1. 承接 Context 中待确认的完整请求交接：上游已选定本类，并将收齐、校验后的最终 CONNECT 目标交付一次。
   上游保留版本及本地回复资格；本类不重复协议探测，也不把 `.httpConnect` 当作握手成功。
2. 本类通过 Core 路由一次并创建下游。DIRECT 连接目标；PROXY 连接 Wire 端点，
   使用 Wire 超时，完成 `start(handshake:)` 及启动写入。
3. 本类将建立成功结果交回上游，由上游写完整 200。回复期间下游保持暂停业务读取；
   回复写成后再激活隧道，不需要本类保存另一份早到业务缓冲。
4. 上游通过 `upstream` 交付业务字节，下游回调处理返回字节；双向只做 DIRECT 透传或 Wire 编解码。
   当前批次写入完成才续读来源；同步抛错及异步失败原样交 owner。
5. 上游通过 `proxyInputClosed` 交付客户端 EOF；它与下游 EOF 都先处理已读数据，
   按方向检查 Wire 完整性并排空对应写入，保留另一方向。
   收尾要求及现有 NIO 关闭限制与 [SOCKS4 转发契约](Socks4Connection-DESIGN.md#core-logic) 一致。
6. 最终结束或错误交回上游，由其决定本地回复及 accepted 的最终关闭；本类收到 `closeConnection`
   后幂等清理下游，runtime 关闭也经该入口收敛。Core 不关闭 accepted，Wire 不拥有 Channel。

## Corners

| 场景 | 必须保持的结果 |
| --- | --- |
| HTTP 任意分片、CONNECT body、非法 Host 或额外握手字节 | 主 handler 在完整请求交接前按 HTTP SPEC 处理；不能以完整请求前提掩盖漏校验。 |
| 200 写到一半失败 | 终止，不在已有响应后追加另一个错误响应。 |
| 建立后下游立即 EOF，或没有业务数据 | 仍先完成本地成功回复，再正常结束；不跳过屏障。 |
| 客户端完整请求后 FIN | 请求仍可建立及回复；后续仅结束相应方向。 |
| 错误 / restart 与建立成功竞争 | 迟到资源关闭，不恢复转发；保留原始错误。 |

本轮验证文档边界与流程，不运行编译或网络测试。5 个基础成员不能独立证明半关闭和在途写安全；
请求交接、激活及正常结束接口确认后，才能检查完整状态集合并实施代码。

### 实施验收引用

恢复 [HTTP 验收](../HTTP_PROXY_SPEC.md#s28) 与 [Wire 验收](../WIRES_SPEC.md#验收)，
覆盖真实 NIO 解码、模型校验、提前业务拒绝、200 部分写入、成功前后截断及零业务 EOF。
CONNECT Host 的端口/根点冲突由模型校验，不通过 DNS 比较；本地 200 与错误响应字段继续遵守
[HTTP 错误契约](../HTTP_PROXY_SPEC.md#s23)。
