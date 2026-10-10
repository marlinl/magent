# HttpForwardConnection Product Design

更新日期：2026-10-09。状态：**目标设计**，不表示源码已完成迁移或通过验收。
契约依据：[HTTP SPEC v0.3.0](../HTTP_PROXY_SPEC.md)、[MODELS SPEC v0.4.3](../MODELS_SPEC.md#httpprotocol)、
[Wire SPEC v0.3.1](../WIRES_SPEC.md) 及 [架构](../ARCHITECTURE.md)。

## Context

`HttpForwardConnection` 完整接收一个 HTTP/1.0 或 HTTP/1.1 请求，按模型目标建立下游，
发送重建请求并透明返回响应，结束后关闭。它不调度后续事务，不持有 CONNECT 子对象，
不执行 keep-alive、流水线、WebSocket 或完整响应 framing 解析。

本组件拥有请求缓冲、一次 HttpProtocol、下游 Channel、可选 Wire 和在途写；主 handler 拥有
accepted Channel 的最终生命周期。目标和出站头由模型确定，路由由 Core 执行，出站协议由 Wire 处理。

## Contract

### 类型、方法与执行边界

固定 **17 个方法**：1 个构造、3 个共享入口、4 个 NIO 回调及 9 个私有阶段。
以下为精确声明；不通过 extension、helper、重载、wrapper 或新文件扩充集合。
所有有状态调用及异步回调在原 accepted EventLoop 串行执行，下游 TCP 使用同一 EventLoop。

```swift
internal final class HttpForwardConnection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
}

/// 主 handler 调用，绑定 accepted Channel 与本运行周期 Core。
internal init(proxyChannel: Channel, core: MagentCore)
```

三个入口精确声明引用 [ProxyConnection](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)：

| 入口 | 调用责任 |
| --- | --- |
| `upstream` | parseRequestHead 后只构造一次 HttpProtocol，确认 forward 分支；consumeRequestBody 检查完整请求和余量，再一次 openOutbound。请求完成后的非空客户端输入拒绝。 |
| `proxyInputClosed` | 先消费已读缓冲；缺少请求字节为截断，完整请求可继续发出并等待响应，写完请求后才关闭下游输出。 |
| `closeConnection` | 先置终态，幂等释放自有下游与缓冲；不写响应、不关闭 accepted、不再次上报错误。 |

### NIO 回调

回调来自 SwiftNIO
[`ChannelInboundHandler`](https://github.com/apple/swift-nio/blob/21de5f08c1a166a6dd293d0e587ad977bf8dac5d/Sources/NIOCore/TypeAssistedChannelHandler.swift)，
仅接收本组件的下游事件。

```swift
/// 调用 relayRemote；Wire 尚未初始化时仅保留有界原始输入。
internal func channelRead(context: ChannelHandlerContext, data: NIOAny)

/// 正常输入 EOF 调用 finishRemoteInput；其他事件原样传播。
internal func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)

/// 正常全关闭补做未处理 EOF；已知错误/取消不被正常结束覆盖。
internal func channelInactive(context: ChannelHandlerContext)

/// 原始下游错误交 fail；已关闭时不重入清理。
internal func errorCaught(context: ChannelHandlerContext, error: Error)
```

### 产品阶段的固定声明

```swift
/// upstream 调用；增量解析头部，不足返回 nil；先验证原字节 UTF-8，保留重复字段与准确余量。
private func parseRequestHead(_ input: inout ByteBuffer) throws -> HTTPRequestHead?

/// upstream 调用；按模型 none/CL 接收并有界保存体，确认 end/无 trailer/无额外字节后返回 true。
private func consumeRequestBody(_ input: inout ByteBuffer) throws -> Bool

/// 完整请求检查后调用；一次路由，DIRECT 已连接或 Wire 初始化及启动写成后成功。
private func openOutbound(target: NetworkAddress) -> EventLoopFuture<Void>

/// 出站就绪后按序提交保存的 head/body/end；NIO 编码后可选 Wire 编码，再 writeRemote。
private func forwardRequest(_ part: HTTPClientRequestPart) -> EventLoopFuture<Void>

/// 下游输入调用；DIRECT 原字节或 Wire 解码结果交 writeClient，首次提交前标记响应已开始。
private func relayRemote(_ data: ByteBuffer) throws

/// 正常下游 EOF 调用；处理完已读输入并检查 Wire，再排空客户端写入，结束单请求连接。
private func finishRemoteInput() throws

/// 入口、NIO、future 边界调用；保留首因，响应未开始时回一次本地错误，否则只终止。
private func fail(_ error: Error)

/// Wire 启动和 forwardRequest 共用；按序写启动或已编码业务，整批完成才归还缓冲。
private func writeRemote(_ data: ByteBuffer) -> EventLoopFuture<Void>

/// relayRemote、fail 共用；按序写 accepted，源站响应与本地错误不能混写。
private func writeClient(_ data: ByteBuffer) -> EventLoopFuture<Void>
```

`forwardRequest` 仅提交已完整接收的唯一请求；最后 end 写成才标记请求已发送。
它与响应读取可独立等待，不能因等待请求写完而阻止服务器返回早期响应。
模型构造后的请求头和 body 直接交 NIO 编码，不重新解析目标或手工拼接完整请求。

`fail` 使用 [HttpConnectConnection.localResponse](HttpConnectConnection-DESIGN.md#产品阶段的固定声明)
按已知请求版本生成错误；版本未知时用 HTTP/1.1。同步及 future 原始错误只在所属最高边界收敛，
中间阶段不包装。客户端写失败不追加错误；错误回复自身失败不覆盖首因。

### 状态与数据

```swift
private enum State {
    case request
    case forward
    case closed
}

private var state: State = .request
```

`.request` 只接收唯一请求并建立下游；`openOutbound` 成功后进入 `.forward`，发送已收齐请求并
返回下游字节。下游正常结束、错误或 runtime 关闭后进入 `.closed`；没有下一轮或协议升级转换。

保存一次请求模型、请求消费/写出完成、客户端 EOF、下游 EOF/Wire 检查、响应是否已开始、首因和清理事实。
头部和完整 body 共同受 [HTTP 的 64 KiB 限额](../HTTP_PROXY_SPEC.md#s21)约束；不为后续请求预读建模。
每方向一个有序在途写，Wire 调用前按其[缓冲契约](../WIRES_SPEC.md#缓冲和进度)预留输入及最坏输出。

## Core Logic

1. `upstream` 解析头并构造模型，按模型给出的无体/CL 定界收齐请求。
   检查 `.end`、无 trailer 和无多余请求字节；合法无体请求不等待后续输入。
2. `openOutbound` 使用保存的同一目标完成路由和出站。就绪后按序调用 `forwardRequest` 发送
   head/body/end；请求 body 不重复编码为目标握手。
3. `relayRemote` 只作可选 Wire 解码和客户端写入。源站状态、framing 及任意响应字节均保持不透明；
   第一个响应字节提交前记录已开始，此后不能再追加本地错误或切换成 WebSocket。
4. 下游正常 EOF 先检查 Wire 完整性，再排空客户端写入并请求 accepted 关闭。
   客户端提前 FIN 不丢弃已收齐请求；缺失请求体则失败。
5. `fail` 必要时完成一次本地错误后向 accepted pipeline 上报原始错误，由主 handler 清理。
   restart/close 终结旧连接；`closeConnection` 只释放自身资源，迟到回调不能重新发送请求。

## Corners

| 场景 | 可观察结果 |
| --- | --- |
| 头通过但 body 尚未完整 | 不拨号，不把模型构造成功当成完整请求成功。 |
| 相同请求以任意分片到达 | 目标、请求头和 body 相同，长度准确，模型只构造一次。 |
| 请求同批带第二请求、转发后又来客户端数据 | 拒绝，不调度下一请求，不创建第二出站。 |
| TE/Expect/Upgrade/OPTIONS */Trailer 或非 UTF-8 字段 | 按模型/字节错误拒绝，不删头后放行。 |
| 下游返回 1xx、401、407、101 或非 UTF-8 字节 | 字节原样返回，不变成本地认证、升级或字符串转换。 |
| 响应已部分提交后 Wire 截断/网络失败 | 只终止，不追加 502 或伪造正常响应结束。 |
| 客户端完整请求后 FIN，或旧 runtime 关闭 | 前者可继续等待响应；后者终结并幂等清理，不保留快照继续运行。 |

### 实施验收

采用 [HTTP 验收 H01–H11、H15–H17](../HTTP_PROXY_SPEC.md#s28) 及模型 HP 用例。
验证真实 NIO 请求编码、完整体缓冲、单请求拒绝、响应逐字节透传和资源清理；不宣称完整 HTTP 响应解析能力。
