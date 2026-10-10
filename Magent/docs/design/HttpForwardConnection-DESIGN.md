# HttpForwardConnection Product Design

更新日期：2026-10-10。状态：**职责与成员设计提案；请求交接接口待确认，尚不能据此直接迁移源码**。
行为基线：[HTTP SPEC](../HTTP_PROXY_SPEC.md)、[Wire SPEC](../WIRES_SPEC.md)、[MODELS SPEC](../MODELS_SPEC.md)。

## Context

上游是 [MagentTCPConnection 的分派流程](MagentTCPConnection-DESIGN.md#core-logic)。
该流程第 2 步在识别普通 HTTP 后唯一安装本类，主 handler 进入 `.httpForward`；
后续客户端字节、输入 EOF 和关闭分别经 `ProxyConnection` 的 `upstream`、`proxyInputClosed`、
`closeConnection` 交付。accepted Channel 的最终关闭始终由主 handler 负责。

主 handler 当前设计只完成协议探测并交付累计字节，分类不代表请求完整。
本篇沿用的目标交接前提是：上游收齐唯一 HTTP 请求（包括 Content-Length body），完成模型校验、
目标解析及 NIO 请求重写，再交付逻辑目标与已编码的完整请求。
这项完整请求交接及本地错误回复职责迁移仍待接口确认；现行架构、SPEC 和源码尚未完成迁移，
不能把当前 `upstream` 的字节交付当成已经具备该交接能力。

下文 Core Logic 从上述完整请求交接后开始：本类经 Core 建立下游、完成 Wire 启动，发送唯一请求并接收源站响应，
在提交响应前通知主 handler 封闭本地错误回复资格，最终协调 EOF 与清理。
这里没有 CONNECT 的本地成功回复，也不解析源站 HTTP 状态码、分块编码或响应语义。
HTTP 支持范围继续保持单请求：无请求体或一个 Content-Length 请求体；拒绝 TE/chunked、Expect、
Upgrade、pipelining 和后续 keep-alive 请求。完整请求上限仍为 64 KiB。

本类借用 accepted Channel，拥有一个 TCP 下游及可选独占 Wire。Core 与其他 Connection 同样必需，
负责一次选路和出站创建；不是 SOCKS5 专属依赖。

## Contract

### 全部实例成员

本类保留 **5 个基础成员**，不把这一数字视为尚未确认的收尾接口必然足够的证明。

| 声明 | 用途与生命周期 |
| --- | --- |
| `private let proxyChannel: Channel` | 借用 accepted，用于源站响应写回及错误上报；最终关闭由主 handler 负责。 |
| `private let core: MagentCore` | 当前 runtime 注入；路由和下游创建均经同一实例完成。 |
| `private var wireChannel: Channel?` | 唯一 TCP 下游；初始 nil，关闭时释放；迟到建连结果直接关闭。 |
| `private var wire: Wire?` | PROXY 独占的 TCP Wire；DIRECT 为 nil；不在后续响应中重新选取。 |
| `private var state: State = .request` | 记录请求建立、单请求转发和终止；本地错误响应资格由主 handler 唯一持有。 |

主 handler 拥有请求分片缓冲、HTTP 版本、模型、报文重写及本地错误响应资格。
目标及完整编码请求通过建立/发送操作链传递，发送完释放，不再做一份实例请求缓冲。
Future 捕获请求也是真实存储，生命周期和容量必须受限；“方法局部”不等于没有内存开销。
当前批次响应及写 Future 仅在本次操作链内保留，Wire 自己保存远端帧分片。

不增加响应解析器、业务队列、写 Future 成员或承载整份会话的辅助结构。
源站响应是否开始由主 handler 记录，提交通知不能晚于网络写入，也不能省略。

### State 定义与转换

恢复原有 `request / forward / closed`，不为已由主 handler 拥有的回复资格再加一份状态。

```swift
private enum State {
    case request
    case forward
    case closed
}

private var state: State = .request
```

| 当前状态 | 允许的输入与操作 | 转换条件及推进者 |
| --- | --- | --- |
| `.request` | 接收唯一完整请求交接并建立下游；不接受第二请求，不转发源站字节。 | `openOutbound` 完成连接及 Wire 启动后，由建立链在启动请求发送和响应读取前进入 `.forward`。 |
| `.forward` | 按序发送唯一请求，可同时接收早期响应；额外非空客户端输入拒绝。 | 正常下游 EOF 经完整性检查和写入排空后，或失败/外部关闭时进入 `.closed`。 |
| `.closed` | 停止写入与续读，释放下游和迟到资源。 | 终态；已关闭不代表可以跳过尚未执行的资源清理。 |

`fail` / `closeConnection` 可从任何非终态进入 `.closed`。
`.request` 在新前提下不再持有增量 HTTP 解析进度。每次提交源站字节前同步通知主 handler，
由它幂等封闭本地错误响应资格；这一交接接口仍待确认，本类不重复保存 `responseStarted`。
正常结束仍必须等待对应写入，`state` 不能替代在途操作的完成条件。

### 方法契约与待确认交接

保留 [ProxyConnection 三个共享声明](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)。

| 入口 | 调用者及责任 |
| --- | --- |
| `upstream(context:data:)` | 主 handler 在完整请求交接后转交额外 TCP 输入；非空数据按第二请求/越界输入拒绝，不重新建立连接。 |
| `proxyInputClosed(context:)` | 主 handler 交付客户端 EOF；完整请求仍须发送并等待响应，不直接关闭下游。 |
| `closeConnection(error:)` | accepted owner 调用；先终止，再幂等关闭下游并释放 Wire，不关闭 accepted 或生成回复。 |

完整请求通过待确认的建立/发送交接送入，不能借 `NIOAny` 隐藏一套未声明的首包类型。
下游沿用既有 SwiftNIO 回调：

```swift
internal final class HttpForwardConnection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
}

internal func channelRead(context: ChannelHandlerContext, data: NIOAny)
internal func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)
internal func channelInactive(context: ChannelHandlerContext)
internal func errorCaught(context: ChannelHandlerContext, error: Error)
```

`channelRead` 按序解码并转发源站字节；正常 EOF 回调检查 Wire 并等待反向写入；
异常失效及 `errorCaught` 交 accepted owner 的统一错误边界。已终止时不再写入或续读。

| 待确认接口责任 | 调用方 → 拥有者 | 完成条件 / 原因 |
| --- | --- | --- |
| 目标及完整编码请求交接 | 主 handler → 本类 | 请求已经完整、合法并重写完毕；本类不再解析头或累计 body。 |
| 建立及请求发送结果 | 本类 → 主 handler | Core 建连、Wire 启动、唯一请求发送按顺序进行；报告原始失败。 |
| 首次源站响应提交 | 本类 → 主 handler | 写入前同步封闭本地错误回复资格，后续错误只终止，不能追加 502。 |
| 正常响应结束 | 本类 → 主 handler | Wire 检查及已读响应写入完成后，由主 handler 结束 accepted。 |

以上接口不在本轮自拟签名。旧 `parseRequestHead` / `consumeRequestBody` 的责任移出本类；
`forwardRequest(HTTPClientRequestPart)` 的逐 part 编码责任也随完整请求重写归主 handler。
已有构造、`openOutbound`、转发及错误方法声明在下节保留；新增交接单独确认，不直接修改源码签名。
HTTP codec 适配器的迁移边界见 [HTTP CONNECT 设计](HttpConnectConnection-DESIGN.md#同文件-nio-适配器)。

### 构造与私有方法定义

以下列出完整的构造及私有方法签名，并逐项注明职责。私有方法同样属于 Contract，
不能在精简成员时一并省略、合并或擅自改签名。涉及职责迁移的方法仍保留原声明和去向，
其新归属及调用接口确认前不删除；新增跨组件入口单独确认。
除注明的迁移项外，不通过 extension、helper、wrapper、重载或新文件扩充方法集合；
同步错误原样抛至拥有入口，Future 失败交统一错误边界，不在细节方法包装错误。

```swift
/// 主 handler 注入 accepted 与当前 Core；初始化 request，不访问网络。
internal init(proxyChannel: Channel, core: MagentCore)

/// 解析唯一请求头并保留准确余量，不足返回 nil；随主 handler 的请求处理迁移。
private func parseRequestHead(_ input: inout ByteBuffer) throws -> HTTPRequestHead?

/// 原按模型定界收齐 body 并检查 end、trailer 和余量的入口；随完整请求处理迁移。
private func consumeRequestBody(_ input: inout ByteBuffer) throws -> Bool

/// 对唯一目标路由并建连；Future 成功表示 Wire 启动完成，不表示请求已经发送。
private func openOutbound(target: NetworkAddress) -> EventLoopFuture<Void>

/// 原逐 part HTTP 编码及发送入口；保留原签名，完整请求重写后的发送交接另行确认。
private func forwardRequest(_ part: HTTPClientRequestPart) -> EventLoopFuture<Void>

/// 下游 channelRead 调用；解码或透传响应，写回前通知主 handler 封闭本地错误响应资格。
private func relayRemote(_ data: ByteBuffer) throws

/// 正常下游 EOF 检查 Wire，排空已读响应后由 accepted owner 最终结束。
private func finishRemoteInput() throws

/// 统一保留原始错误；是否允许本地错误响应由主 handler 按响应是否开始决定。
private func fail(_ error: Error)

/// 按序写入启动数据或已编码请求字节；Future 表示实际网络写成。
private func writeRemote(_ data: ByteBuffer) -> EventLoopFuture<Void>

/// 按序写回源站响应字节；Future 表示实际网络写成，不生成另一份 HTTP 响应。
private func writeClient(_ data: ByteBuffer) -> EventLoopFuture<Void>
```

| 方法 | 归属与调用责任 |
| --- | --- |
| `init` | 保留；主 handler 注入 accepted 与 Core，初态 `.request`，不访问网络。 |
| `parseRequestHead` / `consumeRequestBody` | 请求收齐和模型校验责任随主 handler 迁移；body 定界、end/trailer 与额外请求检查继续保留。 |
| `openOutbound` | 保留建立责任与原声明；对唯一目标路由一次，完成 Wire 启动后才允许发送请求业务，成功不代表请求已发送。 |
| `forwardRequest` | 原逐 part HTTP 编码责任随主 handler 迁移；保留声明供核对。新完整编码请求的发送入口仍需确认，不把旧签名偷偷改成 ByteBuffer。 |
| `relayRemote` | 保留；下游 `channelRead` 调用，按序解码/透传，实际写入前通知主 handler 封闭本地错误响应资格。 |
| `writeRemote` / `writeClient` | 保留底层字节写入；分别供启动/请求发送与源站响应转发使用，返回实际网络写成 Future。 |
| `finishRemoteInput` | 保留；正常 EOF 检查 Wire、排空已读响应，再交 accepted owner 最终结束。 |
| `fail` | 保留统一错误入口；主 handler 在尚未提交源站响应时选择一次本地错误，之后只能终止，保留原始首因。 |

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

1. 承接 Context 中上游的完整请求交接，本类取得逻辑目标与完整编码请求；不重复解析或重写，
   不接收第二请求。上游交接后释放原始请求缓冲，不得在两个 owner 中长期各留一份。
2. 调用 Core 选路一次。DIRECT 连接目标；PROXY 连接同一 Wire 的端点，
   完成 `start(handshake:)` 及启动写入后再编码请求业务数据。
3. 下游就绪后启动响应读取，同时按序发送唯一请求。请求发送与响应接收可以独立等待，
   不能等整个请求写成后才开始读，以免阻塞源站早期响应。
4. 向客户端提交源站字节前，同步通知主 handler 并幂等封闭本地错误响应资格。
   每批响应写成才续读下游；不把 401、407、101 等字节解释为本地控制信号。
5. 客户端 FIN 不取消完整请求。需要结束下游输出时先等请求写完；正常下游 EOF 检查 Wire，
   等已读响应写完后才通知主 handler 最终结束。写操作完成的协调按
   [共同转发契约](Socks4Connection-DESIGN.md#core-logic) 定稿，不能由成员计数代替。
6. 源站响应开始前的失败交主 handler 选择一次合法本地错误响应；开始后只终止。
   accepted 关闭、错误或 restart 都幂等清理本类下游。

## Corners

| 场景 | 必须保持的结果 |
| --- | --- |
| 请求头完整但 body 未完，或请求超限 | 主 handler 不交接、不拨号；不能把模型构造成功当完整请求。 |
| 完整请求后还有字节 | 拒绝第二请求，不进入流式 HTTP 或连接复用。 |
| 源站在请求尚未写完时返回响应 | 可以正常读取并转发；首个响应字节前封闭本地错误回复资格。 |
| 客户端 FIN 与请求写入竞争 | 不丢尚未发送的请求；不以完整关闭代替方向结束。 |
| 源站响应已有部分字节后失败 | 终止传输，不拼接本地 502，不重放请求。 |
| 下游正常 EOF / 截断帧 / restart | 分别按正常排空、原始错误、外部关闭处理；不虚构 HTTP 响应完整性。 |

本轮静态验证完整请求、响应提交及正常结束的 owner。代码未改、未编译或测试；
5 个基础成员与上层交接尚未构成可上线实现，接口定稿时必须验证早期响应和收尾竞态。

### 实施验收引用

恢复 [HTTP 验收](../HTTP_PROXY_SPEC.md#s28) 与 [Wire 验收](../WIRES_SPEC.md#验收)，
覆盖请求任意分片、完整 body、唯一模型与重写结果、额外请求拒绝、源站早期响应及响应开始后禁止本地 502。
方法上限 32 字节、完整请求上限 64 KiB、字段过滤及拒绝范围仍由 HTTP SPEC 约束，不因转发类简化而放宽。
