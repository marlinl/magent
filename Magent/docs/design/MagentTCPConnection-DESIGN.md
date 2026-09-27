---
desc: accepted TCP Channel 的协议识别、具体 Connection 创建、数据分派与生命周期设计
updated_at: 2026-09-27
baseline: target-design
---

# MagentTCPConnection 产品设计

状态：目标设计，定义协议分类、唯一分派与 accepted Channel 所有权；与四份具体 Connection
目标契约配套，不以当前源码的构造或能力限制作为设计依据，也不表示实现已完成。

相关文档：[Magent 架构](../ARCHITECTURE.md#ownership-and-lifecycle) ·
[共享 TCP 生命周期](../ARCHITECTURE.md#shared-tcp-lifecycle) ·
[组件源码](../../Sources/Connection/MagentTCPConnection.swift) ·
[现有测试](../../Tests/Connection/MagentTCPConnectionTests.swift)。

## Context

`MagentTCPConnection` 是每条 accepted TCP Channel 的入口处理器，遵循 SwiftNIO 的
`ChannelInboundHandler`。它接收客户端字节，识别本地代理协议，随后创建并持有唯一的
具体 Connection，将已收到和后续收到的数据交给该对象处理。

```text
Magent 创建 accepted TCP Channel
  └─ MagentTCPConnection：协议识别、数据分派、accepted Channel 生命周期
       ├─ Socks4Connection：SOCKS4 / SOCKS4a
       ├─ Socks5Connection：SOCKS5
       ├─ HttpConnectConnection：HTTP CONNECT
       └─ HttpForwardConnection：HTTP 正向代理
```

四个分支互斥，每条 accepted Channel 最多创建其中一个。这里的“派生”落实为创建并持有
具体对象；该对象处理请求、握手、路由、下游通信和协议回复，`MagentTCPConnection`
持续负责同一 accepted Channel 的入站分派与最终关闭。

TCP 的一次读取只是一段字节，不保证包含一个完整请求。入口可以累计多次读取后才识别
协议，也可以只收到协议前缀就完成识别。识别成功不表示请求合法、握手成功或下游已连接。

| 所有者 | 职责 |
| --- | --- |
| Magent | 创建 listener、accepted Channel、运行周期 Core 和关闭通知，安装本 handler。 |
| MagentTCPConnection | 探测阶段读取与累计、选择并创建具体 Connection、分派后续字节和 EOF、收敛 accepted Channel 的关闭。 |
| 具体 Connection | 本地协议解析、成功/失败回复、协议状态、下游 Channel、读写背压及该协议自己的资源。 |
| Core / Wire | 由具体 Connection 调用，分别负责路由与出站创建、出站协议编解码。 |

本组件不解析完整 SOCKS 请求或 HTTP 消息，不自行生成协议回复，也不解析 UDP 数据报。
SOCKS5 UDP ASSOCIATE 的控制流经本 TCP 入口进入 `Socks5Connection`；UDP relay、来源
关联和 DNS 资源由该具体 Connection 持有。

## Contract

### 受限类型与方法数量

受限的主类型是 `Sources/Connection/MagentTCPConnection.swift` 中的
`MagentTCPConnection`。**主类型固定 8 个自定义方法：1 个构造、5 个 NIO 回调、2 个
私有流程方法。** 不新增主类型 extension；不得通过私有 helper、重载、wrapper 或新源文件
扩展这一方法集合。SwiftNIO 已有的默认回调和类型转换方法不计入这 8 项，不重复实现。

同文件的 `ProxyProbe` 只有一个静态探测方法；**下游调用协议固定为
`ProxyConnection: AnyObject`，只有 3 个方法**，由本设计完整定义声明与调用责任。
协议要求不计入主类型的 8 个方法。唯一保留的协作 extension 是现有
`ProxyConnection.proxyInputClosed` 默认实现，不增加协议要求或其他默认方法。

下列签名的名称、参数标签与顺序、类型、可选性、可见性及返回值固定。主类型的方法均为
同步实例方法，无 `throws`、`async`、默认参数、重载或 actor 隔离。除构造与私有方法显式
标注外，未写访问修饰符的成员为 `internal`。`@unchecked Sendable` 不允许跨 EventLoop
并发修改状态；状态、探测缓冲与具体 Connection 的调用由 accepted Channel 的 EventLoop 串行管理。

### 数据与构造输入

| 数据 | 类型与初值 | 契约 |
| --- | --- | --- |
| `serverChannel` | `Channel`，`private let` | 当前唯一 accepted Channel；不是 listener 或下游 Channel。 |
| `core` | `MagentCore`，`private let` | 当前运行周期的 Core，原样传给所选 Connection，不在活动连接中换成新周期 Core。 |
| `requestDeadline` | `NIODeadline`，`private let` | Magent 从 accept 时刻计算的首请求绝对截止点；探测消耗计入同一预算，创建 HTTP CONNECT 时原样传入。不是从识别成功时重新计时。 |
| `probeDeadlineTask` | `Scheduled<Void>?`，`private var`，初始 `nil` | 仅探测期间有效；激活时安排，分派或关闭时取消。超时经 accepted 错误边界结束，不能自行生成未识别协议的回复。 |
| `detectBuffer` | `ByteBuffer`，`private var`，初始无可读字节 | 保存识别前已经收到的全部字节；交接后清空逻辑内容，不能吞掉识别前缀或同批尾部。 |
| `state` | `State`，`private var`，初始 `.detecting` | `State` 固定为 `.detecting`、`.active`、`.closed`；`.active` 表示已选择具体对象，不表示其握手完成。 |
| `proxyConnection` | `ProxyConnection?`，`private var`，初始 `nil` | 识别前为空；进入 `.active` 前必须保存唯一对象，后续不切换协议。 |
| `shutdownFuture` | 构造输入 `EventLoopFuture<Void>` | 属于当前运行周期；完成时请求关闭 accepted Channel，不作为实例存储属性。 |

构造参数全部由 `Magent` 的 accepted-Channel initializer 显式传入。调用方在安装前采用
`autoRead = false`、`maxMessagesPerRead = 1`、`allowRemoteHalfClosure = true`，并在
激活之前安装 handler。首读由本组件发起；分类后续读由具体 Connection 的流控规则负责。
不增加额外配置对象、构造重载或应用侧 Channel 管理入口。
当前四种入口的首请求预算均为 10 s；Magent 按运行周期预算计算 `requestDeadline`，不是由本类型
硬编码配置。SOCKS 与 HTTP Forward 的其余请求期限由各自运行周期依赖取得原 accept 基准，
不在 `upstream` 第一次调用或异步建连完成时重置。

### 状态定义与合法转换

数据表中的 `State` 属于主类型内部，固定 **3 个 case**，不声明方法；以下将既有三态约束写成
精确声明。边界是“谁解释客户端输入”：探测时本组件解释前缀，选定后只交给唯一具体对象，终结后
不再分派。它不判断具体对象正在协商、做 TCP 转发还是维护 UDP 关联。

```swift
/// 表示入口尚在探测、已交付唯一对象或已经终结。
private enum State {
    case detecting
    case active
    case closed
}

/// 由 accepted EventLoop 串行推进，构造后尚未选择协议。
private var state: State = .detecting
```

| 当前状态 | 事件 / 方法 | 下一状态及约束 |
| --- | --- | --- |
| `.detecting` | `channelRead` 探测不足，或 `installProxyConnection(.incomplete, ...)` | `.detecting`；不创建对象，不消费待交接前缀。 |
| `.detecting` | `installProxyConnection` 得到具体协议 | `.active`；先保存唯一对象并改状态，再调用一次 `upstream` 交付完整缓冲。 |
| `.active` | `channelRead` / 客户端输入 EOF | `.active`；仅转交 `upstream` / `proxyInputClosed`，不以 EOF 直接判断子对象已结束。 |
| `.detecting` / `.active` | `errorCaught` / `channelInactive` | `.closed`；先设终态，存在对象时只清理一次。 |
| `.closed` | 任意后续回调 | `.closed`；不创建对象或交付输入，不再次清理；维持已有 NIO 事件传播与关闭行为。 |

`.detecting` 要求 `proxyConnection == nil`；`.active` 要求保存一个且仅一个具体对象，之后不能
退回探测或换对象。`.closed` 可保留已清理对象的引用，但不能再调用其入口；缺失活动对象属于不变量
破坏，按已有错误 / 关闭路径收敛。`shutdownFuture` 或探测阶段 EOF 只请求关闭 accepted，实际状态
仍由 `errorCaught` / `channelInactive` 收敛；请求关闭本身不新增第四个状态或提前重复清理。

### 8 个方法的固定声明

以下是声明清单，省略方法体；具体行为由紧随其后的表格约束。

```swift
/// 接管一条 accepted TCP Channel 的分类、分派和最终关闭。
internal final class MagentTCPConnection: ChannelInboundHandler, @unchecked Sendable {
    /// NIOAny 内包装的入站数据固定为 ByteBuffer。
    typealias InboundIn = ByteBuffer

    /// 保存所属 Channel 与运行周期依赖，并订阅该周期的关闭通知。
    internal init(
        _ serverChannel: Channel, core: MagentCore, requestDeadline: NIODeadline,
        shutdownFuture: EventLoopFuture<Void>
    )

    /// 转发激活事件，安排探测绝对期限并启动首次手动读取。
    func channelActive(context: ChannelHandlerContext)

    /// 在探测阶段累计字节，选定协议后把字节交给唯一具体 Connection。
    func channelRead(context: ChannelHandlerContext, data: NIOAny)

    /// accepted Channel 失效后执行一次下游清理，并继续传播失效事件。
    func channelInactive(context: ChannelHandlerContext)

    /// 将客户端输入 EOF 交给具体 Connection，其他用户事件继续传播。
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)

    /// 保留原始错误，清理具体 Connection 并关闭 accepted Channel。
    func errorCaught(context: ChannelHandlerContext, error: Error)

    /// 只识别当前累计字节对应的入口协议，不执行完整请求解析。
    private func detectProxyProtocol() -> ProxyProbe

    /// 按探测结果创建唯一具体 Connection，并交接全部已累计字节。
    private func installProxyConnection(_ proxy: ProxyProbe, context: ChannelHandlerContext)
}
```

5 个回调的来源是 SwiftNIO `NIOCore` 的
[`ChannelInboundHandler`](https://github.com/apple/swift-nio/blob/21de5f08c1a166a6dd293d0e587ad977bf8dac5d/Sources/NIOCore/TypeAssistedChannelHandler.swift)
及其继承的
[`_ChannelInboundHandler`](https://github.com/apple/swift-nio/blob/21de5f08c1a166a6dd293d0e587ad977bf8dac5d/Sources/NIOCore/ChannelHandler.swift)。
引用固定到明确的依赖提交。其他 NIO 回调使用该依赖提供的默认行为，不另设
`handlerAdded`、`channelReadComplete` 或自定义生命周期回调。

| 编号 | 方法 / 调用者 | 输入、行为与输出 |
| --- | --- | --- |
| M-01 | `init` / Magent | 保存构造依赖，进入 `.detecting`；订阅 `shutdownFuture` 的成功或失败完成，两者都请求关闭 `serverChannel`。不在构造阶段读取、选择协议、路由或创建下游。 |
| M-02 | `channelActive` / NIO | 转发激活事件，在 `requestDeadline` 安排所属 EventLoop 的探测期限；已经到期则交错误边界结束，否则发起首次 `read()`。期限回调仅在 `.detecting` 时生效；返回 `Void`，不创建具体 Connection。 |
| M-03 | `channelRead` / NIO | `.detecting` 时累计全部输入并调用 `detectProxyProtocol`；不足则续读，其他结果交给 `installProxyConnection`。`.active` 时只调用当前对象的 `upstream`；`.closed` 时忽略输入。返回 `Void`。 |
| M-04 | `channelInactive` / NIO | 尚未关闭时先设置 `.closed`、取消探测期限，再调用 `closeConnection(error: nil)`；已经关闭则不重复清理。两种情况都向后传播 `channelInactive`，返回 `Void`。 |
| M-05 | `userInboundEventTriggered` / NIO | 非 `.inputClosed` 事件原样向后传播；输入 EOF 在 `.detecting` 时关闭 accepted Channel，在 `.active` 时调用 `proxyInputClosed`，在 `.closed` 时忽略。活动状态缺失对象时直接关闭，返回 `Void`。 |
| M-06 | `errorCaught` / NIO 或 accepted pipeline | 尚未关闭时先设置 `.closed`、取消探测期限，把原始错误传给 `closeConnection`，再请求关闭 accepted Channel。已关闭时仅维持关闭，不重复清理。返回 `Void`，不合成本地协议回复。 |
| M-07 | `detectProxyProtocol` / `channelRead` | 读取累计缓冲中的可读字节，返回一次 `ProxyProbe.detect` 的结果；不消费缓冲，不操作网络，不改变已选择的对象。 |
| M-08 | `installProxyConnection` / `channelRead` | 只在 `.detecting` 中调用；具体协议结果创建相应对象，先保存对象、取消探测期限并进入 `.active`，再把累计字节交给它。`unsupported` 进入 accepted pipeline 的错误路径；`incomplete` 不执行创建或交接。返回 `Void`。 |

### 协议探测入口

`ProxyProbe` 沿用现有六种结果：`incomplete`、`unsupported`、`socks4`、`socks5`、
`httpConnect`、`httpForward`，只有下列一个方法。它不拥有 Channel、会话或累计缓冲。

```swift
/// 根据调用方提供的当前前缀返回入口分类，不验证整个请求。
internal static func detect(_ data: Data) -> ProxyProbe
```

以上声明属于 `ProxyProbe`，生产流程中仅供 M-07 调用。

### 下游 Connection 协议：ProxyConnection

本节的“下游 Connection”指被 `MagentTCPConnection` 创建并持有的
`Socks4Connection`、`Socks5Connection`、`HttpConnectConnection` 或
`HttpForwardConnection` 对象。远端网络 Channel 由这些对象另外持有。

四个具体类型必须遵循以下完整协议。`MagentTCPConnection` 创建对象后，通过
`proxyConnection: ProxyConnection?` 调用且只调用这 3 个方法；不能按具体类型分支调用
额外业务方法。构造仍使用前述具体类型的 initializer，不纳入本协议的要求。

```swift
/// 主 TCP handler 向已选定的具体 Connection 交付客户端输入和生命周期通知。
internal protocol ProxyConnection: AnyObject {
    /// 接收客户端字节；首次为全部探测缓冲，后续为同一 accepted Channel 的输入。
    func upstream(context: ChannelHandlerContext, data: NIOAny)

    /// 幂等清理本对象拥有的下游资源，不关闭 accepted Channel 或生成新回复。
    func closeConnection(error: Error?)

    /// 接收客户端输入 EOF；由具体协议决定半关闭、等待已接收数据处理或结束。
    func proxyInputClosed(context: ChannelHandlerContext)
}
```

协议及其成员为包内 `internal`。3 个方法全部是同步实例方法，返回 `Void`，不带
`throws`、`async`、`static`、默认参数或重载；不要求属性、关联类型或构造方法。
所有调用都在 accepted Channel 的 EventLoop 上串行发生。返回 `Void` 只表示本次调用
返回，不证明建连、写入或异步关闭已经完成；这些后续操作仍由具体 Connection 管理。

`ChannelInboundHandler` 负责 NIO 向 handler 投递事件，`ProxyConnection` 负责本 handler
向具体对象委派业务。具体对象可以同时作为远端 Channel 的 NIO handler；主 handler
不能用该对象的 `channelRead`、`channelInactive` 或 `errorCaught` 代替本协议调用，否则
会混淆客户端输入与远端输入、两端 context 和各自的关闭责任。

| 协议方法 | 固定输入与职责 | 实现要求 |
| --- | --- | --- |
| `upstream(context:data:)` | `context` 是 `MagentTCPConnection` 在 accepted Channel 上的 context；`data` 内固定包装 `ByteBuffer`。首次包含探测阶段收到的全部字节，后续为同一客户端按序到达的字节。`upstream` 从被调用对象的角度表示客户端侧输入。 | 四个具体类型各自实现，无默认实现。具体对象判断握手或业务阶段、保留自己的未完成输入、处理协议回复，并决定何时续读。输入不是远端回包，也不保证是完整请求；方法返回后主 handler 不额外发起读取。 |
| `proxyInputClosed(context:)` | 同一 accepted-Channel context，无附带数据；表示客户端不会再发送字节，不表示客户端已不能接收回复。它在之前的输入交付调用之后发生，但不能假定那些调用启动的异步操作均已完成。 | 可以使用下述默认完整关闭行为；支持 half-close 的具体实现处理方向结束、未完成请求及已接收数据。SOCKS5 UDP 控制连接可因此结束关联。具体对象应容忍重复通知，不能重新开始握手或重复生成回复。 |
| `closeConnection(error:)` | `nil` 表示 accepted Channel 正常失效；非空是主 handler 收到的原始错误。调用前主 handler 已进入 `.closed`。 | 四个具体类型各自实现，无默认实现。先进入自身终态，再清理它拥有的下游资源；必须幂等，不写新协议回复，不关闭 accepted Channel，也不把清理再次当成新的连接错误向上触发。 |

`proxyInputClosed` 的唯一默认实现固定为：

```swift
extension ProxyConnection {
    /// 未提供协议专属 EOF 处理时，请求完整关闭 accepted Channel。
    func proxyInputClosed(context: ChannelHandlerContext) {
        context.close(promise: nil)
    }
}
```

该默认实现只发起 accepted Channel 关闭；它不直接调用 `closeConnection`。随后由
`MagentTCPConnection.channelInactive` 执行最终清理，保留统一关闭入口。四个具体
Connection 的目标设计均要求自己的 `proxyInputClosed` 行为；默认实现不能代替各协议的 EOF 契约。

### 主 handler 到下游协议的调用映射

| 主 handler 的入口 / 状态 | 对下游的唯一调用 | 交付与次数约束 |
| --- | --- | --- |
| M-08 `installProxyConnection`，识别成功 | `connection.upstream(context: context, data: NIOAny(initialData))` | 保存对象并进入 `.active` 后调用一次，交付完整探测缓冲；不能只交识别前缀或在 M-03 再交同批数据。 |
| M-03 `channelRead`，已经 `.active` | `proxyConnection.upstream(context: context, data: data)` | 每个后续入站回调按原顺序交付一次；不重新探测或更换对象。 |
| M-05 `.inputClosed`，已经 `.active` | `proxyConnection.proxyInputClosed(context: context)` | 每次收到该事件转交一次；不先调用 `closeConnection`，由具体协议决定方向结束行为。 |
| M-04 `channelInactive`，首次进入关闭 | `proxyConnection.closeConnection(error: nil)` | 先把主 handler 设为 `.closed`，再调用一次；后续失效或错误不重复清理。 |
| M-06 `errorCaught`，首次进入关闭 | `proxyConnection.closeConnection(error: error)` | 传递原始错误，随后由主 handler 关闭 accepted Channel；因此触发的 M-04 不再调用一次清理。 |

未选定具体对象时不调用以上协议方法；`.closed` 后不再交付数据、EOF 或第二次清理。
运行周期关闭只请求关闭 accepted Channel，随后通过 M-04 收敛，不另发一个协议关闭通知。

具体 Connection 的解析、建连或网络错误，在完成其协议要求的失败回复处理后，通过
accepted Channel 的 `pipeline.fireErrorCaught(error)` 把原始原因交回 M-06。不增加
`failed` 或错误代理方法，也不自行调用 `closeConnection` 绕过 accepted owner。

对于数据交付，主 handler 不再额外调用 `fireChannelRead`，以免重复交付；HTTP 具体实现
可以在自己的解析阶段通过收到的 context 把数据送给其安装的 HTTP decoder。

## Core Logic

### 识别与创建

```text
channelActive -> [.detecting, 按原 requestDeadline 安排探测期限]
  -> channelRead -> detectProxyProtocol
       +-- incomplete -> [保留字节并续读]
       +-- unsupported -> errorCaught -> [.closed]
       +-- 具体协议 -> installProxyConnection
            -> [保存唯一对象, 取消探测期限, .active]
            -> upstream(累计字节), 后续 channelRead 只交 upstream
[仍 .detecting 时超时] -> errorCaught -> [.closed]
[.detecting / .active, accepted 失效或错误] -> [.closed, 清理一次]
```

探测只选择下一位协议拥有者，以下构造调用必须与各组件目标契约一致。构造由本组件完成，
共享 `ProxyConnection` 仍只负责构造后的三个入口，不增加工厂或第二层协议。

| 探测结果 / 可观察入口形态 | 唯一构造调用 | 后续责任 |
| --- | --- | --- |
| `socks4`：首字节 `0x04` | `Socks4Connection(proxyChannel: serverChannel, core: core)` | 继续解析 SOCKS4 / SOCKS4a 请求，决定命令与目标是否合法。 |
| `socks5`：首字节 `0x05` | `Socks5Connection(proxyChannel: serverChannel, core: core)` | 继续方法协商与命令请求，按命令进入 TCP 转发或 UDP 关联。 |
| `httpConnect`：已收到精确的 `CONNECT ` 前缀 | `HttpConnectConnection(proxyChannel: serverChannel, core: core, requestDeadline: requestDeadline)` | 继续解析完整 CONNECT 请求；保留首请求原有截止点。 |
| `httpForward`：合法方法 token 后出现 `/`、`*` 或受识别的 HTTP URL 前缀 | `HttpForwardConnection(proxyChannel: serverChannel, core: core)` | 继续解析并校验正向代理请求。分类不保证该目标形式最终被接受。 |

空输入、尚未完成的 `CONNECT ` 前缀、HTTP 方法后尚无目标等情况保持探测。当前 HTTP
方法识别最多接受 32 字节 token；合法前缀暂缺字节与已不支持的输入必须区分。`https://`
目标可被分类为 HTTP forward，但能否转发由具体 HTTP 入口决定。

### 一次交接与持续分派

1. 探测阶段保存所有已接收字节，不能只保存识别用的版本字节或方法名。
2. 一旦选定，使用同一 accepted Channel 和运行周期 Core 创建对应对象，保存引用并将状态
   改为 `.active`，使同步失败或重入事件能够找到正确的清理对象。
3. 将探测缓冲全部交接一次并清空其逻辑内容。交付可以只是一个不完整握手，也可能包含
   完整请求及同批尾部；如何处理尾部由具体协议决定，入口不丢弃、不提前放行。
4. 后续每次 `channelRead` 直接进入同一对象的 `upstream`。不再次探测，不根据隧道载荷
   更换协议，也不在握手失败后尝试另一种 Connection。

`.active` 阶段的读取许可由具体 Connection 管理。本组件不能在每次 `upstream` 返回后
无条件追加 `read()`，否则会绕过具体连接的握手屏障和写入完成背压。

### EOF、错误与运行周期结束

accepted 输入 EOF 和完整关闭是两个事件。探测尚未完成时 EOF 直接结束连接；协议已选定
时交给具体对象处理，允许它排空已收到的数据、结束下游输出并保留反向数据流。其他用户
事件继续向后传播。

accepted Channel 完整失效或 pipeline 报错时，先进入 `.closed` 再调用具体对象的清理。
错误路径保留传入的原始错误，随后关闭 accepted Channel；由关闭触发的 `channelInactive`
不再次清理下游。若先发生正常失效，之后的错误也不重新启动清理或协议回复。

所属 `shutdownFuture` 完成时直接请求关闭 accepted Channel，再由已有回调完成资源收敛。
该通知表示所属周期要求实际终止 accepted 连接。新连接获得新的 Core 与关闭通知，本组件不迁移
活动连接。普通配置更新及优雅停止由运行周期先通知具体组件停止新工作、等待排空，宽限到期再完成
关闭通知；不能用立即完成 shutdownFuture 代替协议 SPEC 要求的宽限。服务策略和订阅依赖由 Magent
装配，本组件只拥有探测期限，不创建独立线程或后台 Task。

## Corners

| 场景 | 目标行为与边界 |
| --- | --- |
| 一次读取为空或协议前缀跨多次读取 | 保持原顺序累计，信息不足时继续探测，不提前创建下游或生成回复。 |
| 只收到 `0x04`、`0x05` 或 `CONNECT ` | 可以选定具体对象；完整请求的等待与校验由该对象接管。 |
| 识别前缀与请求尾部同批到达 | 全部字节只交接一次；余量分别遵循具体 Connection 的请求、提前业务或流水线契约。 |
| HTTP 扩展方法或 `https://` 目标 | 分类只决定使用 HTTP forward 入口；不承诺该入口完整支持该请求。 |
| 不支持的输入 | 以协议识别错误进入 accepted pipeline；不猜测应发送 SOCKS 回复还是 HTTP 错误页。 |
| 活动会话载荷看似另一种协议 | 仍交给已选对象，不能重新分类或创建第二个 Connection。 |
| EOF 尚未完成探测 | 关闭 accepted Channel，没有具体对象时无需下游清理。 |
| EOF 已有具体对象 | 调用 `proxyInputClosed`，不把单向结束直接当作整个会话结束。 |
| 错误后又收到失效、EOF 或入站数据 | 终态不再分派或重复清理；失效事件仍按 NIO 回调规则向后传播。 |
| 重启或服务关闭发生在任意阶段 | 响应所属运行周期的关闭通知，最终只清理该连接所拥有的资源，不改用新 Core。 |
| 探测迟迟不完整 | 到原始绝对截止点即结束；选定后取消本探测任务，不终止具体组件正在处理的会话。 |
| 探测缓冲 | 遵循服务接收预算；32 字节方法限制不是整批输入内存上限，识别字节和同批余量不能重复计费。预算装配须先于首次 read。 |

### 校验依据与范围

本次为目标文档审查，未验证运行时实现。实施至少应核对：8 个主类型方法的签名与调用责任、四分支唯一创建、首次字节
无损且只交接一次、下游协议恰好 3 个方法及参数方向、分类后不额外续读、EOF 正确委派，
探测超时与分类完成竞争时不误关已分派对象，以及错误/失效重复到达时只清理一次。
Magent 的构造调用须同步提供 deadline 并移除旧 DNS 参数；计时基准、接收预算、配置更新与排空
依赖须在所属服务契约完成装配，本组件文档不代表这些运行周期能力已经实现。
