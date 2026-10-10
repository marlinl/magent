# HttpConnectConnection Product Design

更新日期：2026-10-09。状态：**目标设计**，不表示源码已完成迁移或通过验收。
契约依据：[HTTP SPEC v0.3.0](../HTTP_PROXY_SPEC.md)、[MODELS SPEC v0.4.3](../MODELS_SPEC.md#httpprotocol)、
[Wire SPEC v0.3.1](../WIRES_SPEC.md) 及 [架构](../ARCHITECTURE.md)。

## Context

`HttpConnectConnection` 处理一个 HTTP/1.0 或 HTTP/1.1 CONNECT 请求，完整校验后建立下游，
写出本地 200，再转为固定目标 TCP 隧道。它只由 `MagentTCPConnection` 创建，不接受后续 HTTP 事务。

本组件拥有请求状态、下游 Channel、可选 TCP Wire、早到节点输入与在途写。
主 handler 拥有 accepted Channel 的最终关闭。Core 路由，Wire 编解码，`HttpProtocol` 校验请求语义；
本组件不复制这些职责，也不把 CONNECT 头交给目标。

## Contract

### 类型、方法与执行边界

固定 **18 个方法**：1 个构造、3 个共享入口、4 个 NIO 回调、9 个私有阶段及 1 个共用响应方法。
以下为精确声明；不通过 extension、helper、重载、wrapper 或新文件扩充集合。
全部有状态调用及异步回调在原 accepted EventLoop 串行执行，下游 TCP 使用同一 EventLoop。

```swift
internal final class HttpConnectConnection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
}

/// 主 handler 调用，绑定 accepted Channel 与本运行周期 Core。
internal init(proxyChannel: Channel, core: MagentCore)
```

三个入口精确声明引用 [ProxyConnection](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)：

| 入口 | 调用责任 |
| --- | --- |
| `upstream` | 增量解析请求，构造一次 HttpProtocol 并确认 connect 分支；请求结束及余量校验后一次 openTunnel，成功后 writeSuccess。完整回复前的非空客户端业务拒绝；转发态调用 relayClient。 |
| `proxyInputClosed` | 缺请求字节时失败；完整请求后可等待建立/回复，再排空并半关闭下游输出。 |
| `closeConnection` | 先置终态，幂等释放自有资源；不写回复、不关闭 accepted、不再次上报错误。 |

context 始终是 accepted 上的主 handler context；客户端请求数据不得误作下游输入。

### NIO 回调

回调来自 SwiftNIO
[`ChannelInboundHandler`](https://github.com/apple/swift-nio/blob/21de5f08c1a166a6dd293d0e587ad977bf8dac5d/Sources/NIOCore/TypeAssistedChannelHandler.swift)，
仅用于本组件的下游 Channel。

```swift
/// 调用 relayRemote；Wire 未初始化时只保留有界原始节点字节。
internal func channelRead(context: ChannelHandlerContext, data: NIOAny)

/// 正常输入 EOF 调用 finishRemoteInput；其他事件原样传播。
internal func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)

/// 正常全关闭补做未完成的 EOF 检查；不可完成的写入按传输失败处理。
internal func channelInactive(context: ChannelHandlerContext)

/// 将原始下游错误交 fail；已关闭时不重入清理。
internal func errorCaught(context: ChannelHandlerContext, error: Error)
```

### 产品阶段的固定声明

```swift
/// upstream 调用；增量解析头部，不足返回 nil；先检查原字节 UTF-8，保留重复字段及准确余量。
private func parseRequestHead(_ input: inout ByteBuffer) throws -> HTTPRequestHead?

/// 请求结束且无提前数据后调用；一次路由，DIRECT 已连接或 Wire 初始化及启动写成后成功。
private func openTunnel(target: NetworkAddress) -> EventLoopFuture<Void>

/// openTunnel 成功后调用；占有回复权，按请求版本写完整 200 后释放反向数据与 EOF 屏障。
private func writeSuccess() -> EventLoopFuture<Void>

/// writeSuccess、relayRemote、fail 共用；按序写 accepted，整批写成后归还缓冲。
private func writeClient(_ data: ByteBuffer) -> EventLoopFuture<Void>

/// openTunnel、relayClient 共用；写启动原始字节或已编码业务，失败原样返回。
private func writeRemote(_ data: ByteBuffer) -> EventLoopFuture<Void>

/// 转发态 upstream 调用；DIRECT 直写，PROXY 编码后 writeRemote，空业务不推进 Wire。
private func relayClient(_ data: ByteBuffer) throws

/// 下游输入或初始化后余量排空调用；只解码一次，200 完成前保存业务，之后 writeClient。
private func relayRemote(_ data: ByteBuffer) throws

/// 正常下游 EOF 调用；检查 Wire，等待启动及完整 200，再排空并半关闭客户端输出。
private func finishRemoteInput() throws

/// 客户端/NIO/future 边界调用；保留首因，按回复提交状态选择一次错误响应或直接终止。
private func fail(_ error: Error)

/// 本组件及 HTTP Forward 共用；仅构造指定支持版本的 CONNECT 200 或无体错误响应。
internal static func localResponse(version: HTTPVersion, status: HTTPResponseStatus) -> HTTPResponseHead
```

`localResponse` 遵守 [HTTP 错误契约](../HTTP_PROXY_SPEC.md#s23)：200 不带 CL/TE/body 或普通关闭字段；
错误带 CL=0 和 Connection: close；不生成 401/407。它没有状态、写入或清理副作用。
其余方法的同步错误在调用入口处理，future 失败在所属边界交 `fail`，中间阶段不包装错误。

### 状态与数据

```swift
private enum State {
    case handshaking
    case forwarding
    case closed
}

private var state: State = .handshaking
```

`.handshaking` 包括请求、建立和回复；只有 `writeSuccess` 完成才进入 `.forwarding`。
两方向结束、错误或外部关闭进入 `.closed`，不再恢复。保存一次请求模型、回复是否提交/完成、
两侧 EOF/输出关闭、Wire EOF 检查、首因及清理事实；不另建状态层。

请求缓冲和早到节点输入分别受 [HTTP 限额](../HTTP_PROXY_SPEC.md#s21)约束。
Wire 调用按其[缓冲契约](../WIRES_SPEC.md#缓冲和进度)预留输入及最坏输出；无容量时暂停调用。
不增加原始字段影子模型、配置快照、期限注入或全局资源服务。

## Core Logic

1. 收齐唯一请求；以 HttpProtocol 固定目标和版本。检查 `.end`、无 body 和无多余客户端字节后再建连。
2. `openTunnel` 完成 DIRECT 或 Wire 启动；`writeSuccess` 再完整提交本地 200。两次写完成前，
   早到节点业务及正常 EOF 都不能越过屏障。客户端提前业务拒绝，不排队等待成功。
3. 进入隧道后先排空早到反向业务，再双向 relay。正常 EOF 检查并排空后只关闭对应输出；
   零业务 FIN 同样等待启动和 200。完整关闭不能冒充半关闭。
4. `fail` 固定原始首因，未提交且可写时发送一次本地错误，之后交 accepted pipeline；已提交时只终止。
   主 handler 调用清理，错误回复自身失败不覆盖首因。
5. 正常双方结束请求 accepted 关闭；restart/close 直接随所属 runtime 终结。
   `closeConnection` 幂等释放下游与缓冲，迟到回调只回收资源。

## Corners

| 场景 | 可观察结果 |
| --- | --- |
| CONNECT Host 与目标不同端口或根点 | 模型拒绝，不借助 DNS 比较，也不建出站。 |
| 请求头同批带业务、等待 200 时又来业务 | 拒绝提前数据，不向目标转发。 |
| 启动或 200 在途时下游零业务 FIN | 先检查完整性，双屏障完成后才能传播客户端输出 EOF。 |
| Wire 截断在 200 提交前 / 后 | 前者可回一次错误；后者只结束。 |
| 完整请求后客户端 FIN / 请求中途 FIN | 前者可完成建立再半关闭；后者失败。 |
| restart、读错、迟到连接竞争 | 旧连接不迁移或复活，清理及最终回复各至多一次。 |

### 实施验收

使用 [HTTP 验收 H01–H14、H16–H17](../HTTP_PROXY_SPEC.md#s28) 和 Wire 对应 TCP 用例。
本地验证须覆盖真实 NIO 解码、请求模型、早到拒绝、回复短写及 EOF；文档本身不证明运行正确。
