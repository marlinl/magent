---
desc: accepted TCP 的协议识别、唯一分派和关闭所有权
updated_at: 2026-10-09
baseline: target-design
---

# MagentTCPConnection 产品设计

状态：目标设计，按现有 Magent 生命周期和模型边界收敛，不表示所有目标行为已经实现。
相关边界：[架构](../ARCHITECTURE.md#ownership-and-lifecycle) ·
[HTTP SPEC](../HTTP_PROXY_SPEC.md) · [组件源码](../../Sources/Connection/MagentTCPConnection.swift)。

## Context

`Magent` 为每条 accepted TCP Channel 安装本 handler。本组件只识别协议、创建唯一具体 Connection、
分派客户端字节及 EOF，并拥有 accepted Channel 的最终关闭。具体 Connection 拥有协议回复与下游资源；
Core 路由和创建下游，Wire 编解码。

同一 listener 接受 SOCKS4、SOCKS5、HTTP CONNECT 和普通 HTTP。不增加 HTTP-only listener、
服务配置快照、协议工厂或第二套分派协议。分类成功不表示请求已经完整或合法。

## Contract

### 受限类型与方法数量

主类型固定 8 个方法：1 个构造、5 个 NIO 回调、2 个私有流程方法。`ProxyProbe` 另有一个静态方法，
`ProxyConnection` 只有三个共享入口。不通过 extension、helper、wrapper 或新文件扩展集合。
下列精确声明固定参数、访问级别和返回类型；未标访问级别的协议要求为 internal，无 async、throws 或默认参数。
所有状态和下游调用在 accepted Channel 的 EventLoop 串行推进。

```swift
internal final class MagentTCPConnection: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
}

/// Magent 创建；绑定 accepted Channel、当前 Core、可选 UDP DNS 配置及关闭通知。
internal init(
    _ serverChannel: Channel, core: MagentCore, dnsAddress: SocketAddress?,
    shutdownFuture: EventLoopFuture<Void>
)

/// accepted 激活后发起首次手动读取。
func channelActive(context: ChannelHandlerContext)

/// 探测时累计并分类；选定后只调用唯一 Connection.upstream。
func channelRead(context: ChannelHandlerContext, data: NIOAny)

/// accepted 完整关闭时置终态并清理下游一次。
func channelInactive(context: ChannelHandlerContext)

/// inputClosed 委派给具体 Connection；未选定时结束连接，其他事件继续传播。
func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)

/// 固定终态、用原始错误清理下游，再关闭 accepted；重复错误不重复清理。
func errorCaught(context: ChannelHandlerContext, error: Error)

/// channelRead 在探测态调用；只对当前缓冲调用 ProxyProbe.detect。
private func detectProxyProtocol() -> ProxyProbe

/// 分类完成时创建唯一对象，保存引用后交出全部探测字节一次。
private func installProxyConnection(_ proxy: ProxyProbe, context: ChannelHandlerContext)
```

五个事件回调来自 SwiftNIO `ChannelInboundHandler`。构造不创建出站；关闭通知完成时只请求关闭
accepted，由既有回调收敛清理。`dnsAddress` 只传给 SOCKS5，来自 `MagentConfig.dnsListener`，
不当作所有 TCP 请求的系统解析器。无需额外 deadline、时钟服务或许可对象的构造参数。

### 数据与状态

```swift
private enum State {
    case detecting
    case active
    case closed
}

private var state: State = .detecting
```

| 数据 | 所有权与约束 |
| --- | --- |
| `serverChannel: Channel` | 本组件持有的 accepted Channel，不能替换成 listener 或下游。 |
| `core: MagentCore` | 当前运行周期实例；活动连接不切换到新 Core。 |
| `dnsAddress: SocketAddress?` | 原配置中的可选 UDP DNS 地址。 |
| `detectBuffer: ByteBuffer` | 初始为空，保存全部未分派输入，分类后交接并清空。 |
| `proxyConnection: ProxyConnection?` | 初始 nil，进入 active 前设置一次，之后不更换对象。 |

`detecting` 解释协议前缀；`active` 只分派，具体对象是否已完成握手不影响该状态；`closed` 不再分派。
任意状态均可因错误或关闭进入终态。Magent 安装前设置 `autoRead=false`、单批读取和允许远端半关闭。
分类前本组件续读，分类后具体 Connection 控制读许可，主 handler 不追加无条件 read。

### 协议探测

```swift
internal enum ProxyProbe {
    case socks4
    case socks5
    case httpConnect
    case httpForward
    case incomplete
    case unsupported

    /// 只识别前缀，无路由、回复或资源副作用。
    static func detect(_ data: Data) -> ProxyProbe
}
```

| 输入 | 选择及唯一构造 |
| --- | --- |
| 首字节 0x04 | `Socks4Connection(proxyChannel: serverChannel, core: core)` |
| 首字节 0x05 | `Socks5Connection(proxyChannel: serverChannel, core: core, dnsAddress: dnsAddress)` |
| 精确 CONNECT 前缀 | `HttpConnectConnection(proxyChannel: serverChannel, core: core)` |
| 合法 HTTP 方法及目标前缀 | `HttpForwardConnection(proxyChannel: serverChannel, core: core)` |

HTTP 方法上限按 [HTTP SPEC](../HTTP_PROXY_SPEC.md#s21)统一为 32 字节。合法但尚缺字节为 incomplete；
不支持的输入为 unsupported。识别 origin-form、absolute-form 或 `*` 只选择 HTTP 解析器，
不绕过模型对 URI 方案、OPTIONS、方法或目标的限制。探测缓冲有界，不以方法长度替代整批字节限额。

### 下游 Connection 协议：ProxyConnection

```swift
internal protocol ProxyConnection: AnyObject {
    func upstream(context: ChannelHandlerContext, data: NIOAny)
    func closeConnection(error: Error?)
    func proxyInputClosed(context: ChannelHandlerContext)
}

extension ProxyConnection {
    func proxyInputClosed(context: ChannelHandlerContext)
}
```

默认 EOF 实现请求 accepted 关闭。支持 TCP 半关闭的具体对象提供自身实现，不能依赖默认整连接关闭。
不增加协议工厂、错误回调或第二套停止入口。

### 主 handler 到下游协议的调用映射

| 方法 | 输入、责任与完成边界 |
| --- | --- |
| `upstream` | context 为 accepted handler context；首次收到完整探测缓冲，之后收到原序字节。具体对象校验握手余量/请求边界，并控制客户端续读。 |
| `proxyInputClosed` | 所有已读数据交付后通知输入 EOF；由具体协议判断截断、半关闭或 UDP 关联结束。 |
| `closeConnection` | accepted 正常失效传 nil，错误传原 Error；只释放下游资源，不再次关闭 accepted、不发回复或反向上报。 |

具体 Connection 在最高失败边界完成适用的失败回复后，通过 accepted pipeline 的 errorCaught
交回原始错误。不新增错误代理；主 handler 置 closed 后清理下游，防止下游关闭回调再次形成关闭循环。

## Core Logic

1. 激活后读取。探测不足则保存原字节并续读；unsupported 进入错误关闭，不猜测协议回复格式。
2. 分类后创建并保存唯一具体对象，进入 active，再把全部累计字节交付一次；前缀和同批余量都不能丢失。
3. 后续读取及输入 EOF 只委派给该对象。严格握手下的额外字节由具体协议拒绝，不由本组件偷偷丢弃。
4. accepted 完整失效或错误时先进入 closed，再调用一次下游清理。重复 inactive/error 只完成必要的 NIO 传播。
5. restart 为下一周期先验证配置并创建新 Core，再结束旧周期；旧 shutdownFuture 关闭旧 accepted。
   新连接使用新 Core 和新通知。close 终结服务实例；这里没有热更新保活或优雅排空订阅。

## Corners

| 场景 | 必须保持的行为 |
| --- | --- |
| 协议前缀任意分片、与请求合包 | 识别结果稳定；累计字节完整交付一次，具体协议决定请求是否有效。 |
| HTTP 方法 31/32/33 字节 | 前两种合法 token 可分类；33 字节拒绝，不额外扩大规范范围。 |
| 成功隧道内数据类似另一协议 | 仍交同一对象，不重新探测。 |
| 分类前 EOF / 分类后 EOF | 前者结束；后者交具体对象，不能直接把单向 FIN 当整连接结束。 |
| 具体对象失败后再来 inactive/error | 不重复回复或清理，不复活活动状态。 |
| restart/close 与下游建连完成竞争 | 旧 accepted 关闭；具体 owner 回收迟到下游，不迁入新周期。 |

实施检查覆盖唯一构造、三入口参数方向、严格余量校验交接、读许可、EOF 和重复清理。
本文不改变源码；能力是否已实现需按各 SPEC 和现有 Connection 测试验证。
