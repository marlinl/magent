---
desc: accepted TCP 的协议识别、唯一分派和关闭所有权
updated_at: 2026-10-10
baseline: target-design
---

# MagentTCPConnection 产品设计

状态：目标设计；合并状态与协议探测类型，相关私有签名待确认；DNS 参数移除和完整请求交接均尚未迁移源码。
相关边界：[架构](../ARCHITECTURE.md#ownership-and-lifecycle) ·
[HTTP SPEC](../HTTP_PROXY_SPEC.md) · [组件源码](../../Sources/Connection/MagentTCPConnection.swift)。

## Context

`Magent` 为每条 accepted TCP Channel 安装本 handler。按现有接口，本组件识别协议、创建唯一具体 Connection、
分派客户端字节及 EOF，并拥有 accepted Channel 的最终关闭。具体 Connection 拥有协议回复与下游资源；
Core 路由和创建下游，Wire 编解码。

同一 listener 接受 SOCKS4、SOCKS5、HTTP CONNECT 和普通 HTTP。不增加 HTTP-only listener、
服务配置快照、协议工厂或第二套分派协议。分类成功不表示请求已经完整或合法。

四份 Connection design 已提出由本组件收齐、校验完整请求并负责本地回复，再交具体 Connection 建立下游和转发。
这一职责迁移尚缺完整请求交接、建立结果和成功回复后激活的接口。以下定义当前分派边界下的状态、成员和方法；
这些声明不能直接承载全部新职责，迁移所需签名须先确认，不能把已解析目标塞进 `NIOAny` 或默默扩充私有函数。

本版不配置 SOCKS5 UDP 的专用 DNS 服务器，因此本组件不接收、保存或透传 `dnsAddress`。
该地址原本供 UDP 直连域名查询使用，并非本地 DNS 监听端口；移除它不改变 accepted listener 或 UDP relay 的端口。

## Contract

### 受限类型与执行边界

主类型的目标定义为 **5 个实例成员、6 个状态、8 个方法**：1 个构造、5 个 NIO 回调、2 个私有流程方法。
`State` 同时表达探测阶段、选定协议和终态；不再保留独立 `ProxyProbe` 或 `.active`。
`ProxyConnection` 只有三个共享入口。不通过 extension、helper、wrapper 或新文件扩展集合。
下列精确声明固定参数、访问级别和返回类型；未标访问级别的方法为 internal，除显式 throws 外无 async 或默认参数。
所有状态和下游调用在 accepted Channel 的 EventLoop 串行推进。

```swift
internal final class MagentTCPConnection: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
}
```

### State 定义与转换

```swift
private enum State {
    case detecting
    case socks4
    case socks5
    case httpConnect
    case httpForward
    case closed
}
```

初态为 `.detecting`。四个协议状态既表示已经选定对象，也标明协议种类；不携带 Connection、缓冲、资源或 Future。
数据不足保持 `.detecting`，不支持的输入抛错并走统一关闭，不增加 `.incomplete` 或 `.unsupported` 状态。

| 状态 | 允许的输入与操作 | 合法转换与负责方法 |
| --- | --- | --- |
| `.detecting` | `channelRead` 累计协议前缀；不足时续读；完整分类后构造一个具体 Connection。 | `installProxyConnection` 先保存唯一对象，再进入匹配的协议状态；错误或完整关闭分别由 `errorCaught` / `channelInactive` 进入 `.closed`。 |
| `.socks4` / `.socks5` / `.httpConnect` / `.httpForward` | 字节与输入 EOF 委派给对应的唯一对象，不再探测。具体 Connection 可能仍在握手。 | `errorCaught` / `channelInactive` 进入 `.closed`；不切换协议、不退回 `.detecting`，单向 EOF 本身不改变状态。 |
| `.closed` | 不再分派数据、输入 EOF 或重复清理下游；保留必要的 NIO 事件传播及关闭请求。 | 终态，无回退。 |

探测期收到 EOF 或 runtime 的 `shutdownFuture` 完成时，先请求 accepted 关闭，由 `channelInactive` 收敛终态；
它们不是额外状态。错误路径必须先置 `.closed` 再清理具体 Connection，阻断关闭回调重入。
进入具体协议状态不代表请求完整、下游建连成功或本地成功回复写成；这些阶段仍由具体 Connection 的状态约束。

### 全部实例成员

以下为目标设计的全部存储属性。它们覆盖当前探测与分派职责，不是完整请求交接方案的成员上限或上线证明。

| 精确声明 | 初值、用途与生命周期 |
| --- | --- |
| `private let serverChannel: Channel` | 构造注入的 accepted Channel；本组件拥有其最终关闭，不能替换为 listener 或下游。 |
| `private let core: MagentCore` | 构造注入当前 runtime 的 Core，传给所有具体 Connection；活动连接不切换 Core，也不关闭 Core。 |
| `private var detectBuffer: ByteBuffer` | 用 accepted allocator 创建空缓冲；只在探测期保存尚未交付的原始字节，分类成功后交付一次并清空，不保存转发流量。未分类就关闭时随 handler 释放。 |
| `private var state: State = .detecting` | 保存上节六个状态；同时记录协议选择和生命周期，不另存协议种类。所有转换在 accepted EventLoop 完成，终态不可恢复。 |
| `private var proxyConnection: ProxyConnection? = nil` | 强持有唯一具体 Connection；完整类型和对应关系见下节。安装时赋值一次，终止时清理其下游，引用随 handler 释放。 |

`shutdownFuture` 只在构造中订阅，回调弱引用 accepted Channel，不另存为成员。
`context`、本批 `input`、探测结果 `proxy`、交接数据 `initialData` 及构造中的 `connection` 均为方法局部值。
不新增计数、写入 Future 或结构体来隐藏状态；本组件没有 Wire、下游 Channel 或业务写入完成计数。

### 下游 Connection 协议：ProxyConnection

`proxyConnection` 是主 handler 的成员，`ProxyConnection` 是它引用的现有类约束协议；不新增名为 ProxyConnection 的包装类。
完整成员声明为：

```swift
private var proxyConnection: ProxyConnection? = nil
```

该成员可以持有四种具体 Connection 中的一种。三个入口统一定义在协议中，由各具体类完整实现，
不提供协议默认实现：

```swift
internal protocol ProxyConnection: AnyObject {
    /// 主 handler 交付客户端字节；具体对象按自身协议阶段处理并管理续读。
    func upstream(context: ChannelHandlerContext, data: NIOAny)

    /// accepted 结束或出错时只清理自有下游；不关闭 accepted、不发回复或反向上报错误。
    func closeConnection(error: Error?)

    /// 客户端输入 EOF；具体对象负责截断检查、半关闭或结束 UDP 关联。
    func proxyInputClosed(context: ChannelHandlerContext)
}
```

`proxyInputClosed` 必须按具体协议处理 EOF：TCP 隧道协调半关闭，HTTP forward 继续完成请求与响应，
SOCKS5 UDP 模式结束关联。源码迁移时删除原协议 extension 中的默认关闭实现，保留各具体类已有的同名方法；
三个入口的签名不变。

| `state` | `proxyConnection` 的合法值 |
| --- | --- |
| `.detecting` | nil，尚未创建具体 Connection。 |
| `.socks4` | 唯一 `Socks4Connection` 实例。 |
| `.socks5` | 唯一 `Socks5Connection` 实例；其 UDP 子对象由它持有，不直接保存在本成员中。 |
| `.httpConnect` | 唯一 `HttpConnectConnection` 实例。 |
| `.httpForward` | 唯一 `HttpForwardConnection` 实例。 |
| `.closed` | 分类前关闭时为 nil；分类后关闭可保留原对象引用，但已经提交下游清理，不再分派业务。 |

安装必须在同一 EventLoop 内按“保存对象 → 写入对应协议状态 → 取出并清空探测缓冲 → 调用 upstream”完成，
保存对象到写入状态之间不调用外部回调。进入具体协议状态后不更换对象；若出现 nil 或类型不匹配，属于内部状态错误，
应进入已有错误关闭入口，不能静默丢数据或重新创建对象。
类型对应由安装分支保证，不要求逐包重复类型判断或强制转换。
关闭先置 `.closed`，再调用一次 `closeConnection(error:)`，避免同步回调重入重复清理。
accepted 的最终关闭仍由主 handler 负责；持有具体对象不转移 accepted 的所有权。

### 开放入口与 NIO 回调

这里的“开放”指供 `Magent` 或 NIO 调用的 internal 入口，不增加应用可调用的 public API。
五个事件回调来自 SwiftNIO `ChannelInboundHandler`，构造由 `Magent` 安装 accepted handler 时调用。

```swift
/// Magent 创建；绑定 accepted Channel、当前 Core 及关闭通知。
internal init(
    _ serverChannel: Channel, core: MagentCore,
    shutdownFuture: EventLoopFuture<Void>
)

/// accepted 激活后发起首次手动读取。
func channelActive(context: ChannelHandlerContext)

/// 探测时累计并分类；四种协议状态只调用唯一 Connection.upstream。
func channelRead(context: ChannelHandlerContext, data: NIOAny)

/// accepted 完整关闭时置终态并清理下游一次。
func channelInactive(context: ChannelHandlerContext)

/// inputClosed 委派给具体 Connection；未选定时结束连接，其他事件继续传播。
func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)

/// 固定终态、用原始错误清理下游，再关闭 accepted；重复错误不重复清理。
func errorCaught(context: ChannelHandlerContext, error: Error)
```

| 入口 | 调用责任与完成边界 |
| --- | --- |
| `init` | 保存依赖、创建空探测缓冲并订阅关闭通知；不创建出站，不启动读写。关闭通知只请求 accepted 关闭，清理由已有 NIO 回调收敛。 |
| `channelActive` | 传播激活事件并发起首次手动读取。 |
| `channelRead` | `.detecting` 下调用可抛错的探测方法，不足则续读；四种协议状态交唯一对象，`.closed` 忽略。捕获探测原始错误后调用本类 `errorCaught(context:error:)` 收敛，不跳过本 handler 的清理入口。分类后读许可归具体 Connection。 |
| `channelInactive` | 首次完整失效先进入终态，再以 nil 错误清理下游；重复调用仍传播 inactive，但不再次清理。 |
| `userInboundEventTriggered` | 只消费 `ChannelEvent.inputClosed`；探测期请求关闭，四种协议状态转交具体 Connection，终态忽略。协议状态与对象不一致时走已有错误关闭入口；其他事件原样传播。 |
| `errorCaught` | 首次错误先进入终态，再将原始 Error 交下游清理并请求 accepted 关闭；不包装错误、不生成本地协议回复。重复错误仅维持关闭请求。 |

`Magent` 安装前设置 `autoRead=false`、单批读取和允许远端半关闭。
分类前本组件续读，分类后具体 Connection 控制读许可，主 handler 不追加无条件 read。
构造无需额外 deadline、时钟服务或许可对象参数。

源码迁移时，`Magent` 安装本 handler 的调用同步去掉 `dnsAddress: config.dnsListener`，
本类删除对应成员及赋值。本轮仅修改本篇设计，不修改 Swift 或 `MagentConfig` 的公共声明；
不能把现有源码仍接受 DNS 配置描述为已完成删除。

### 私有函数定义

两个私有函数均由 `.detecting` 分支调用。以下为合并类型所需的精确签名提案，确认后再改源码；
它们只负责协议分类和安装，完整请求解析、路由和本地回复不隐含在其中。

```swift
/// 数据不足返回 detecting，识别成功返回四种协议之一，不支持则抛错；不修改成员。
private func detectProxyProtocol() throws -> State

/// 分类完成时创建唯一对象，保存引用后交出全部探测字节一次。
private func installProxyConnection(_ proxy: State, context: ChannelHandlerContext)
```

| 方法 | 调用者、输入输出与副作用 |
| --- | --- |
| `detectProxyProtocol` | `channelRead` 追加本批输入后调用；只读取 `detectBuffer`。不足返回 `.detecting`，成功返回四种协议之一，不支持则抛出现有 `MagentError.invalidOptions`；绝不返回 `.closed`，不消耗缓冲、不修改状态、不做网络操作。 |
| `installProxyConnection` | `channelRead` 得到具体协议分类后调用；只接受 `.detecting` 阶段的四种协议结果。按上节顺序安装和交付一次，不执行规则匹配或直接建连。关闭后或已经安装时不得再构造；传入 `.detecting` / `.closed` 属调用错误，交已有错误关闭入口。 |

这次合并仅调整以下方法契约，其他构造、NIO 回调与 `ProxyConnection` 三个入口保持原声明：

| 原声明 | 目标调整与原因 |
| --- | --- |
| `private func detectProxyProtocol() -> ProxyProbe` | 改为上面的 `throws -> State`；复用状态类型表达分类结果，用原始错误结束不支持的输入。 |
| `private func installProxyConnection(_ proxy: ProxyProbe, context: ChannelHandlerContext)` | 参数类型改为 `State`，名称和其余参数不变；安装结果直接对应协议状态。 |
| `ProxyProbe` 的 `static func detect(_ data: Data) -> ProxyProbe` | 随独立类型移除，分类逻辑直接归已有 `detectProxyProtocol`；不新增替代静态方法或辅助类型。 |

### 协议探测与对象选择

| 输入 | 选择及唯一构造 |
| --- | --- |
| 首字节 0x04 | `Socks4Connection(proxyChannel: serverChannel, core: core)` |
| 首字节 0x05 | `Socks5Connection(proxyChannel: serverChannel, core: core, dnsAddress: nil)` |
| 精确 CONNECT 前缀 | `HttpConnectConnection(proxyChannel: serverChannel, core: core)` |
| 合法 HTTP 方法及目标前缀 | `HttpForwardConnection(proxyChannel: serverChannel, core: core)` |

`Socks5Connection` 沿用其当前构造声明，此处显式传 nil 表示未配置专用 DNS；不新增读取配置或解析器的替代入口。
按 [SOCKS5 SPEC 的 DNS 契约](../SOCKS5_PROXY_SPEC.md#s09)，TCP DIRECT 域名仍由 Core 的 NIO 连接流程解析，
PROXY 的业务域名原样交 Wire，UDP DIRECT 数值 IP 不需要解析；UDP DIRECT 域名因缺少 DNS 配置失败，
按关联错误边界结束该关联。不会自动回退系统解析，也不会按 UDP 载荷中的域名做解析或路由。
上述 nil 装配只表达本组件的目标调用；SOCKS5 内部可选 DNS 能力及公共配置的整体移除须另行统一相关契约。

HTTP 方法上限按 [HTTP SPEC](../HTTP_PROXY_SPEC.md#s21)统一为 32 字节。合法但尚缺字节返回 `.detecting`；
不支持的输入抛错。识别 origin-form、absolute-form 或 `*` 只选择 HTTP 解析器，
不绕过模型对 URI 方案、OPTIONS、方法或目标的限制。探测缓冲有界，不以方法长度替代整批字节限额。
TODO：当前源码尚未对 `detectBuffer` 追加设置整批字节限额，实施时需补齐，不能把 32 字节方法限制当作缓冲上限。

### 主 handler 到下游协议的调用映射

| 方法 | 输入、责任与完成边界 |
| --- | --- |
| `upstream` | context 为 accepted handler context；首次收到完整探测缓冲，之后收到原序字节。具体对象校验握手余量/请求边界，并控制客户端续读。 |
| `proxyInputClosed` | 所有已读数据交付后通知输入 EOF；由具体协议判断截断、半关闭或 UDP 关联结束。 |
| `closeConnection` | accepted 正常失效传 nil，错误传原 Error；只释放下游资源，不再次关闭 accepted、不发回复或反向上报。 |

具体 Connection 在最高失败边界完成适用的失败回复后，通过 accepted pipeline 的 errorCaught
交回原始错误。不新增错误代理；主 handler 置 closed 后清理下游，防止下游关闭回调再次形成关闭循环。

## Core Logic

1. 激活后读取。探测不足则保留 `.detecting`、保存原字节并续读；不支持的输入抛错，由本类错误入口关闭，不猜测协议回复格式。
2. 分类后创建并保存唯一具体对象，进入对应协议状态，再把全部累计字节交付一次；前缀和同批余量都不能丢失。
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
| 协议已识别但请求仍未完整 | 保持对应协议状态，具体 Connection 继续处理分片；识别成功不等于允许业务转发。 |
| 协议状态与具体对象不一致，或重复安装 | 不覆盖对象、不重放首包；状态错误交统一关闭入口，终态只做必要清理。 |
| 分类前 EOF / 分类后 EOF | 前者结束；后者交具体对象，不能直接把单向 FIN 当整连接结束。 |
| 具体对象失败后再来 inactive/error | 不重复回复或清理，不复活活动状态。 |
| restart/close 与下游建连完成竞争 | 旧 accepted 关闭；具体 owner 回收迟到下游，不迁入新周期。 |
| 未配置专用 DNS 的 SOCKS5 UDP | IP 直连和 PROXY 按原流程处理；DIRECT 域名按 SPEC 失败并结束所属关联，不静默更换解析策略。 |

实施检查覆盖唯一构造、三入口参数方向、严格余量校验交接、读许可、EOF 和重复清理。
本文不改变源码；能力是否已实现需按各 SPEC 和现有 Connection 测试验证。
