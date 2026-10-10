# Socks4Connection Product Design

更新日期：2026-10-10。状态：**职责与成员设计提案；请求交接接口待确认，尚不能据此直接迁移源码**。
行为基线：[SOCKS4 SPEC](../SOCKS4_PROXY_SPEC.md)、[Wire SPEC](../WIRES_SPEC.md)、
[MODELS SPEC](../MODELS_SPEC.md)。

## Context

上游前置步骤见 [MagentTCPConnection 的 Core Logic](MagentTCPConnection-DESIGN.md#core-logic)：
主 handler 识别 SOCKS4 后只安装一个 `Socks4Connection`，进入 `.socks4`，通过
[ProxyConnection 三个入口](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)
交付客户端输入、EOF 和关闭通知，并拥有 accepted Channel 的最终关闭。
当前主设计只保证累计探测字节交付一次；选定协议不等于收到完整请求，也不等于允许业务转发。

本篇保留“上游处理完整请求与本地回复，本类建立下游并转发”的目标职责。
下面流程的交接前置条件是：主 handler 已收齐并验证 SOCKS4/4a 请求，拒绝不支持命令和完整请求后的额外字节，
一次性交付已验证的 CONNECT 逻辑目标。之后由本类通过 Core 选路并建立下游、完成 Wire 启动，
再由上游写成完整 SOCKS4 成功回复，最后进入双向转发及 EOF/关闭处理。
SOCKS4/4a 的报文、严格请求/回复顺序及错误结果仍遵守 SPEC。

**完整请求交接、建立结果与回复后激活的接口尚待确认。** 主 handler 设计已标明这一缺口；
其现有三入口不能直接承载目标交接，[架构](../ARCHITECTURE.md)、协议 SPEC 与源码也尚未迁移解析和回复归属。
本篇不把当前探测字节当成已解析请求，不另建第二份请求缓冲，也不据此宣称整条目标流程已经落地。

四份文档对应五个业务 Connection 类：本类、`Socks5Connection`、其持有的 `Socks5UDPConnection`、
`HttpConnectConnection`、`HttpForwardConnection`。每个类都使用同一运行周期的 Core；
TCP 按连接选路一次，UDP 子对象按数据报目标选路。Core 负责规则和下游创建，Wire 负责远端协议状态。

## Contract

### 受限范围与执行边界

本类留在现有 `Socks4Connection.swift`，不引入基类、转发包装类或新的源文件。
accepted Channel 只借用；本类拥有 `wireChannel` 和独占 TCP Wire。
所有状态、路由衔接与回调在 accepted EventLoop 上串行执行；不创建独立 Task 或线程池。

### 全部实例成员

下面是责任拆分后的 **5 个基础成员**。这是本轮成员提案，不是强制上限或上线完备性证明；
正常 EOF 与在途写的协调尚需在接口定稿时验证，不能为维持数字而隐藏额外状态。

| 声明 | 用途与生命周期 |
| --- | --- |
| `private let proxyChannel: Channel` | 借用 accepted Channel，写回业务并向其 owner 报告错误；不在清理中关闭它。 |
| `private let core: MagentCore` | 构造时注入当前 runtime 的实例；选路及创建下游都经它完成，不切换或关闭 Core。 |
| `private var wireChannel: Channel?` | 初始 nil；保存唯一 TCP 下游；关闭时释放。关闭后迟到建连结果直接关闭。 |
| `private var wire: Wire?` | 初始 nil；PROXY 保存一次选出的独占 Wire；DIRECT 保持 nil。端点、超时与编码始终来自同一实例。 |
| `private var state: State = .handshaking` | 建立与等待本地成功回复合属 `.handshaking`，另区分转发和终止；终态不可恢复。不携带缓冲、Future 或资源包。 |

不新增 struct、tuple、字典或闭包容器来合并无关成员。也不在适配器或 Channel 属性中藏一份会话状态。

完整请求及分片缓冲归主 handler；目标、命令校验结果、拨号 Future、启动报文及单批写 Future
只在相应方法和回调链内使用。回调捕获的字节仍占用内存，必须有界并在操作完成后释放。
业务转发不另存完整数据流；Wire 自己保存远端帧解码所需的分片。

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

保留 [ProxyConnection 的三个共享声明](MagentTCPConnection-DESIGN.md#下游-connection-协议proxyconnection)。
其在本提案中的调用责任如下；启动交接尚未定义，不能把目标伪装成 `NIOAny` 或重放握手字节填补接口。

| 入口 | 调用者及责任 |
| --- | --- |
| `upstream(context:data:)` | 主 handler 只在允许转发后交业务字节；本类按 DIRECT / Wire 编码写向下游。 |
| `proxyInputClosed(context:)` | 主 handler 交付客户端 EOF；按正常半关闭顺序处理已接收数据。 |
| `closeConnection(error:)` | accepted owner 调用；先置终态，再幂等关闭自有下游，不回复、不重入错误路径。 |

下游回调仍使用 SwiftNIO `ChannelInboundHandler` 的既有声明：

```swift
internal final class Socks4Connection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
}

func channelRead(context: ChannelHandlerContext, data: NIOAny)
func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)
func channelInactive(context: ChannelHandlerContext)
func errorCaught(context: ChannelHandlerContext, error: Error)
```

| 回调 | 本类责任 |
| --- | --- |
| `channelRead` | DIRECT 直接写回；PROXY 解码后写回。解码未产生业务字节时继续读取。 |
| `userInboundEventTriggered` | 正常下游 EOF 检查 Wire 并进入方向结束流程；其他事件继续传播。 |
| `channelInactive` | 已在清理中只传播事件；正常失效若尚未处理输入结束，汇入同一 EOF/Wire 检查及排空流程；异常失效报告 owner，不能递归关闭或用完整性检查覆盖原始错误。 |
| `errorCaught` | 将原始错误交统一拥有者；不包装或改写首因。 |

以下是需要确认的接口责任，**不在本轮自拟 Swift 方法签名**：

| 交接 | 调用方 → 拥有者 | 完成条件 / 原因 |
| --- | --- | --- |
| 完整目标与建立结果 | 主 handler → 本类 → 主 handler | 已验证目标进入建立流程；下游连接及 Wire 启动写入完成，才允许主 handler 回复成功。 |
| 开始转发 | 主 handler → 本类 | 完整本地成功回复写成，才允许两侧业务读取；零业务时也必须发生。 |
| 正常方向结束 / 最终结束 | 主 handler ↔ 本类 | 明确 EOF、最后一次写入和最终 accepted 关闭的先后关系。 |

原 `paserLength` / `paserSocks4` 的解析责任和 `respondProxyChannelOnce` 的本地回复责任移出本类。
已有声明完整保留在下节；本轮只标明迁移归属，跨组件衔接须先确认，再实施，不能直接删除源码方法。

### 构造与私有方法定义

以下列出完整的构造及私有方法签名，并逐项注明职责。私有方法同样属于 Contract，
不能在精简成员时一并省略、合并或擅自改签名。涉及职责迁移的方法仍保留原声明和去向，
其新归属及调用接口确认前不删除；新增跨组件入口单独确认。
除注明的迁移项外，不通过 extension、helper、wrapper、重载或新文件扩充方法集合；
同步错误原样抛至拥有入口，Future 失败交统一错误边界，不在细节方法包装错误。

```swift
/// 主 handler 注入 accepted 与当前 Core；初始化状态，不读写网络。
internal init(proxyChannel: Channel, core: MagentCore)

/// 确定 SOCKS4/4a 请求长度，不足返回 nil；解析责任拟随完整请求处理迁移。
private func paserLength(_ input: ByteBuffer) throws -> Int?

/// 校验一个完整请求并返回命令与逻辑目标；无 DNS、路由或网络副作用，归属随解析迁移。
private static func paserSocks4(_ input: ByteBuffer)
  throws -> (command: Socks4Command, address: NetworkAddress)

/// 对已验证目标路由一次并开始建连；PROXY 使用同一 Wire 的端点、超时和启动状态。
private func installWireChannel(command: Socks4Command, address: NetworkAddress) throws

/// 原成功回复及启读阶段；保留原声明，回复与激活拆分后的调用衔接需确认。
private func startTunnel(_ channel: Channel) -> EventLoopFuture<Void>

/// 统一处理首次原始错误并封闭状态；本地错误回复由主 handler 选择，清理不覆盖首因。
private func fail(_ error: Error)

/// 转发态 upstream 调用；DIRECT 透传，PROXY 以 address:nil 编码后写向下游。
private func outbound(_ data: ByteBuffer) throws

/// 下游 channelRead 调用；DIRECT 透传或 Wire 解码一次，空解码结果不作为 EOF。
private func inbound(_ data: ByteBuffer) throws

/// 有序写入启动数据或已编码上行业务；返回实际网络写完成的 Future。
private func requestWireChannel(_ data: Data) -> EventLoopFuture<Void>

/// 按序写回已解码业务字节；返回实际网络写完成的 Future，不自行占用本地回复资格。
private func respondProxyChannel(_ data: Data) -> EventLoopFuture<Void>

/// 原一次本地回复入口；已提交回复时返回 nil，该回复资格随主 handler 迁移。
private func respondProxyChannelOnce(_ data: Data) -> EventLoopFuture<Void>?
```

| 方法 | 归属与调用责任 |
| --- | --- |
| `init` | 保留构造声明；主 handler 注入 accepted 与 Core，初始化 `.handshaking`，不在构造中读写网络。 |
| `paserLength` / `paserSocks4` | 解析责任随完整请求处理迁移；原入口是 `upstream`。长度扫描、完整校验和目标规范化要求继续保留。 |
| `installWireChannel` | 保留本类选路/建连责任与原声明；对一个目标路由一次，迟到 Channel 只释放；由新交接如何进入该私有阶段需确认。 |
| `startTunnel` | 原阶段同时写本地成功回复并启读；拆分后的回复归主 handler、激活归本类。保留原声明，精确衔接待确认。 |
| `outbound` / `inbound` | 保留；分别由转发态 `upstream` / `channelRead` 调用。DIRECT 透传；TCP PROXY 后续编码的 address 为 nil，解码一次，空结果不是 EOF。 |
| `requestWireChannel` / `respondProxyChannel` | 保留字节写入；启动/上行和下行分别调用，Future 表示实际网络写成。下游缺失失败，不吞掉写错或自行结束 accepted。 |
| `respondProxyChannelOnce` | 一次本地回复责任随主 handler 迁移；原 `startTunnel` / `fail` 共用回复资格，提交后即占用，不能因写失败追加另一回复。 |
| `fail` | 保留声明及统一错误出口；本地失败回复由主 handler 选择，原始首因由操作链保留，清理错误不覆盖首因。 |

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

1. 承接 Context 的完整请求交接前置步骤，本类在 `.handshaking` 接收一次已验证的 CONNECT 逻辑目标；
   不重复上游协议探测或请求解析，保持业务读取暂停。
2. 本类调用 Core 选路一次。DIRECT 由 Core 连接目标；PROXY 用同一 Wire 的端点和超时建连，
   调用一次 `start(handshake:)` 并写完启动数据。逻辑目标和节点端点不能混用。
3. 建立成功交回主 handler，由其写完整 SOCKS4 成功回复。此时下游保持暂停读取，避免产生第二份早到业务缓冲。
   回复写成后才开启转发；回复失败由 accepted owner 结束连接。
4. 每个方向按“读取一批 → 编码或解码 → 写入完成 → 续读来源”推进；Future 属于当前操作链，
   不为每次写入增加 `toWireWrite` / `toProxyWrite` 成员。单批多次回调必须有序收敛，不能各自无条件续读。
5. 正常 EOF 先处理已读字节，PROXY 的正常下游 EOF 调用一次 `finishInbound()`；
   该方向写入完成后才半关闭对端输出，另一方向仍可继续。只有正常完成条件满足后，才通知 accepted owner 最终结束。
6. 错误、外部关闭及 restart 可中断转发；清理先封闭状态，迟到回调只释放资源。旧连接一直使用旧 Core。

“需要观察写入结果”是转发桥的背压和关闭责任，并不推出“必须保存两个写 Future 成员”。
不过，单靠 `.forwarding/.closed` 也不能证明 EOF 排空：当前 NIO 在输入已关闭时可能把输出关闭升级成完整关闭。
**具体协调方式仍待接口确认；不能把 `close(.output)` 当成任何情形都安全的排空操作。**

## Corners

| 场景 | 必须保持的结果 |
| --- | --- |
| 请求分片、非法请求、握手余量 | 由主 handler 在交接前处理；本类不再建第二份请求缓冲。 |
| 完整请求后立即客户端 FIN | 建立和本地成功回复仍按顺序完成，再传播 EOF；不能漏回复。 |
| 启动写失败或回复失败 | 保留原始错误；不进入转发，不重复回复。 |
| 正常下游 EOF、零业务或截断帧 | 零业务也等成功回复；完整性错误走错误边界，正常结束不提前丢在途写。 |
| 建连未完成时关闭 / restart | 迟到 Channel 立即关闭；不回复、不续读、不使用新 Core。 |

文档验收检查责任唯一、Core 路由一次、回复后启读、accepted 关闭所有权和错误首因。
本轮只验证文档；完整请求交接、方法声明及 EOF 协调定稿前，不视为可上线设计或实现。

### 实施验收引用

恢复 [SOCKS4 报文与生命周期验收](../SOCKS4_PROXY_SPEC.md#doc-10-tests-and-acceptance) 及
[Wire 验收](../WIRES_SPEC.md#验收)。完整请求交接后，任意分片、同批余量、根点与数值地址、固定八字节回复、
成功回复部分写入、零业务 EOF、双向背压和 restart 迟到回调仍需分别验证，不能因改变 owner 而删除用例。
