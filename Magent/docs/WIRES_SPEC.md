---
desc: "出站 Wire 的抽象接口、TCP 启动与编解码、UDP 数据报、所有权、错误及验收契约。"
version: "0.2.0"
updated_at: "2026-09-24"
status: "草案"
---

# Magent Wire 规范

本规范定义本地代理 Connection 与出站编解码实现之间的抽象边界。HTTP、SOCKS4、SOCKS5 入口都通过同一套 Wire 契约提交逻辑目标和业务数据，不按节点协议分支处理请求。

本文不列举具体后端协议，不定义其报文、认证算法、密钥格式或部署配置。具体实现必须满足本规范，但其细节不能反向进入入口 SPEC 或成为统一接口的必需字段。

阅读顺序：[范围与所有权](#范围与所有权) → [模型与接口](#模型与接口) → [逐项接口说明](#逐项接口说明) → [业务调用顺序](#业务调用顺序) → [TCP 契约](#tcp-契约) → [UDP 契约](#udp-契约) → [错误与资源](#错误与资源) → [验收](#验收)。本文中的“必须”“禁止”均为验收要求；接口草图不代表当前代码已完成迁移。

## 范围与所有权

### 各层职责

| 层 | 拥有的行为和状态 | 输入 / 输出边界 |
|---|---|---|
| Magent | EventLoopGroup、监听和运行周期关闭通知 | 完整运行配置与生命周期操作 |
| MagentTCPConnection | accepted Channel、协议探测及其关闭 | 向唯一的具体 Connection 分派本地字节 |
| 具体 Connection | 本地协议、下游 Channel、回复屏障、读写背压、EOF、取消及 UDP 关联 | 将协议解析结果交给 Core / Wire；将业务结果编码为本地回复 |
| Core | 规则匹配、节点引用解析、Wire 选择及 Channel 创建 | 消费已验证目标，提供 DIRECT 路径或匹配传输种类的 Wire |
| Wire | 一个明确传输种类的启动、控制状态、出站编码、入站解码及内部有界缓冲 | 提供实际节点端点；只接收和产生数据与状态，不执行网络 I/O |

Wire 不拥有 Channel、EventLoopGroup、DNS 客户端或本地会话；不匹配路由，不选择其他节点，不创建线程或 Task，不自行发送数据、定时重试或调用 Connection 的清理路径。所有网络读写和截止时间由 Connection 执行。

DIRECT 不要求构造空 Wire 或假节点。PROXY 的 Wire 创建或执行失败不能转换为 DIRECT。每条 TCP 路由只匹配一次并选择一次 Wire；同一个 Wire 同时决定拨号端点和该连接的编解码状态。

### 与其他 SPEC 的关系

- [模型规范](MODELS_SPEC.md) 定义 NetworkAddress、ProxyNode、Decision 与规则的构造和身份语义；本规范不增加地址兼容入口或新的节点协议枚举。
- [HTTP SPEC](HTTP_PROXY_SPEC.md)、[SOCKS4 SPEC](SOCKS4_PROXY_SPEC.md)、[SOCKS5 SPEC](SOCKS5_PROXY_SPEC.md) 定义各自的本地报文、认证、回复、提前数据及 UDP 来源规则。
- 本规范统一定义入口完成路由之后如何使用 Wire。新增实现不能要求入口识别其协议名称、控制字段、状态码或凭据。

本版表达一条 TCP 业务字节流或独立 UDP 数据报。连接池、跨客户端多路复用、多个 Channel 联合控制和传输种类转换不属于本接口的隐含能力；需要这些能力时先定义可验证的所有权与数据边界，不能在现有返回值中隐藏第二条连接。

## 模型与接口

### 地址与时间

| 值 | 契约 |
|---|---|
| 业务目标 | NetworkAddress；由本地协议层经过模型构造入口创建，业务端口必须非零 |
| 节点端点 | 已校验的 IPv4 / IPv6 SocketAddress，端口非零；保留实际端点的地址族、作用域等信息 |
| TCP 解码数据地址 | 当前 TCP 逻辑目标，不能由任意后续输入改变 |
| UDP 解码数据地址 | 该业务数据报的逻辑回复来源，与实际节点发送方分开 |
| 连接超时 | 正 Int64 毫秒，遵循模型规定的可转换范围；不是秒，不是整个会话的超时 |

Wire 读取目标已有的地址身份，不修剪、重新规范化或解析域名。域名根点必须保留；数值 IP 不交给名称解析器。无法表达某个合法目标时明确失败，不改写目标或自行解析成另一种地址类型。

节点端点与连接超时在一个 Wire 生命周期内稳定。需要更换节点配置时，由新运行周期或所属连接的重新创建决定，不能通过 Wire getter 隐式迁移活动流。节点名称的解析在配置装配边界完成，getter 本身不访问 DNS。

### 抽象接口草图

以下声明描述目标接口，支持类型放在消费它们的 Wire 所属文件即可，不要求新增包装文件或公开 API。

```swift
import Foundation
import NIOCore

/// 一段解码后的业务数据。TCP 为空时不产生此记录；UDP 允许空载荷。
internal struct InboundData {
    let data: Data
    let address: NetworkAddress
}

/// 同一次状态推进产生的有序输出；两个方向分别保序。
internal struct WireResult {
    let outbound: [Data]
    let inbound: [InboundData]
    let ready: Bool
}

internal protocol Wire: AnyObject {
    /// 当前仍由 Wire 保留的协议数据字节数，供 Connection 计入缓冲预算。
    var bufferedBytes: Int { get }

    /// 与该 Wire 通信的实际节点端点；不是客户端请求中的业务目标。
    func getEndpoint() -> SocketAddress
    /// 连接节点的超时，单位为毫秒；不表示 UDP 响应期限。
    func getTimeout() -> Int64

    /// 以业务目标启动 Wire，返回控制输出、业务输出与就绪状态。
    func start(handshake target: NetworkAddress) throws -> WireResult
    /// 编码业务字节；流的目标已在启动时固定，数据报逐包提供目标。
    func encodeOutbound(_ data: Data, address: NetworkAddress?) throws -> Data
    /// 消费下游输入；控制信息留在 Wire，业务数据交回 Connection。
    func decodeInbound(_ bytes: Data) throws -> WireResult

    /// 输入确实结束时检查是否截断，不关闭 Channel 或结束反向发送。
    func finishInbound() throws
}
```

接口不包含入口协议种类、HTTP 方法、SOCKS 命令、节点协议名或具体安全参数。Wire 构造由 Core 与节点配置负责；此处不规定一个能接收任意协议参数字典的通用初始化器。

这里只定义一套 Wire 接口。Core 的 TCP / UDP 选择入口和 Connection 已经知道当前业务的数据边界，不再由 Wire 重复暴露一个 transport 开关。Core 必须返回适用于当前操作的实例；同一节点的 TCP 可用不证明 UDP 可用。本版连接流程分别使用 TCP Channel 和 UDP Channel；这不表示任意后端的承载方式都必然等于入口业务种类，跨传输承载仍属于本版范围之外。

`WireResult` 的三个字段分别解决控制写入、业务交付和启动判定，不能只返回一个 Data 后让 Connection 猜测其含义：

| 字段 | Connection 的处理 |
|---|---|
| outbound | 按数组顺序写入下游 Channel 的控制字节；不得再次调用 encodeOutbound，不能写给本地客户端 |
| inbound | 按数组顺序处理的纯业务数据；已消费的协议控制字节不能混入 |
| ready | 本次处理后，Wire 的启动条件是否满足；不证明返回的 outbound 已经写入完成 |

所有返回数组必须有界。TCP outbound 不包含空 Data；UDP 中一个 Data 元素表示一个完整数据报，不能拆成多个 UDP 包或与相邻元素合并。TCP inbound 不包含空业务记录，空数组表示暂未解出数据；UDP 可以用一个空 data 的 InboundData 表示合法零长度业务数据报。

返回前，Wire 必须取得输入的所有权或复制需要保留的部分，不能持有调用方之后可能改写的非拥有视图。返回数据的生命周期不依赖下一次 Wire 调用；Connection 取得返回结果后，负责其排队、字节预算和释放。

### 调用与线程约束

方法同步执行，只推进协议状态，不阻塞等待网络或任务。Connection 按所属 EventLoop 串行调用同一有状态实例，禁止两个方向并发改写其内部状态。接口不默认承诺任意并发调用安全。

TCP 每条连接创建独立实例，不能跨目标或跨连接复用启动状态与流缓冲。UDP 只有在实现明确保证每包独立、没有关联私有状态且满足并发安全时，才可由 Core 共享实例；否则按所属本地关联与后端使用范围隔离。无论是否共享 Wire，客户端、实际端点和授权记录始终留在各自 Connection 中。

## 逐项接口说明

### 接口取舍与当前使用状态

每个成员必须对应明确的业务调用点，不能仅为“以后可能需要”增加方法。下表区分现有调用和目标接口；源码索引只证明当前调用位置，不证明目标接口已经实现。

| 成员 | 业务用途 / 调用者 | 与当前代码的关系 |
|---|---|---|
| getEndpoint | TCP 建连前取得节点端点；SOCKS5 UDP 发包前取得实际接收方 | 已有 getTargetAddress 的语义，规范改名以区分业务目标 |
| getTimeout | TCP Connection 将毫秒值传给 Core 的节点建连方法 | 已有方法和调用；当前无连接 UDP 发包不消费该超时 |
| start | TCP Channel 建好后固定业务目标并产生启动结果 | 已有方法；WireResult 是待迁移返回值 |
| encodeOutbound | HTTP 源站请求、隧道载荷或单个 UDP DATA 编码 | 已有方法和调用 |
| decodeInbound | 下游 TCP 读取或已确认来源的 UDP 回包解码 | 已有方法；WireResult 是待迁移返回值 |
| finishInbound | 下游流 EOF 时检查 Wire 内是否还缺少必需字节 | 新增；当前 EOF 路径直接传播半关闭，尚未检查解码器尾部状态 |
| bufferedBytes | 将 Wire 保留的半帧 / 控制数据计入 Connection 的缓冲预算 | 新增属性；内部缓冲已存在，统一计量和预算消费路径尚未实现 |

以下职责不增加独立接口成员：

| 不纳入的成员 | 对应职责 | 不纳入本版的理由 |
|---|---|---|
| transport | 标识 TCP / UDP | 当前 Core 选择入口和 Channel 流程已有该信息，没有额外消费者 |
| finishOutbound | 结束编码并产生尾部字节 | 当前编码调用立即返回本次输入的全部输出，没有需要额外 flush 的业务；本地 EOF 的写入排空和半关闭归 Connection |
| close | 显式释放 Wire 状态 | Wire 没有 Channel、Task 或异步关闭工作；Connection / Core 释放所属引用即可，无须再建立一套关闭状态机 |

如果以后确有编码尾部、主动会话结束或额外资源需要释放，先补充具体调用点、所有权和验收，再扩充接口，不能把这些能力当作当前已支持。

### getEndpoint()

```swift
func getEndpoint() -> SocketAddress
```

| 项目 | 说明 |
|---|---|
| 调用时机 | TCP：Core 已选中 Wire、建立节点 Channel 之前。UDP：选择 Wire 后，为待发送数据报确定实际后端 |
| 输入 | 无；端点在 Wire 构造时来自已校验的节点配置 |
| 返回 | 实际 IPv4 / IPv6 SocketAddress，端口非零；保留实际地址族和作用域 |
| 副作用与失败 | 不执行 DNS、路由、连接或状态推进，不抛错；无法提供合法端点时应在创建 Wire 时失败 |
| 不得混用 | 返回值不能作为 TCP 握手业务目标、UDP 业务来源或本地成功回复的绑定地址 |

TCP 并不要求一律用 NetworkAddress 建连：DIRECT 可以从业务 NetworkAddress 解析目标；PROXY 连接的是该方法返回的实际节点端点。节点连通后，原业务 NetworkAddress 再传给 start。UDP 编码目标与发包节点同样分开。

### getTimeout()

```swift
func getTimeout() -> Int64
```

| 项目 | 说明 |
|---|---|
| 调用时机 | TCP Connection 建立节点 Channel 时，与 getEndpoint 一起读取，传给 Core 的 connect timeout |
| 输入 / 返回 | 无输入；返回节点配置中已验证的正整数毫秒，例如 1_250 表示 1.25 秒 |
| 稳定性 | 同一 Wire 实例返回值稳定；不执行 I/O、不随每次读取重新计时 |
| 不适用的期限 | 不代替入口握手、Wire 启动、业务空闲、HTTP 响应或 UDP 关联期限 |

当前 UDP 数据报路径不调用该方法计时；它只是同一接口可读取的节点配置值。不能因为存在该 getter，就给每个 UDP 包增加 TCP 式连接等待或推断一个响应超时。

### start(handshake:)

```swift
func start(handshake target: NetworkAddress) throws -> WireResult
```

| 项目 | 说明 |
|---|---|
| 调用时机 | TCP 节点 Channel 建立后、本地 CONNECT 成功回复或普通 HTTP 源站请求发送之前 |
| 参数 | 客户端请求中经过模型校验的业务目标；不能传节点端点或本地 listener |
| 返回 | outbound 为待写入节点的启动字节；ready 表示内部启动条件；inbound 按统一结果规则处理，通常为空 |
| 状态 | TCP 首次调用固定目标；重复启动或不支持该目标时报原始错误，不重新选路 |
| 调用者后续动作 | 按序写完 outbound；ready=false 时继续接收下游并调用 decodeInbound，直到就绪或启动期限到期 |

本版独立数据报实现不需要连接级启动，UDP 发送路径可以直接编码；若调用 start，返回空输出、ready=true，不固定参数中的目标，也不改变后续逐包目标。这里规定的是本版数据报能力范围，不能由“UDP”推断任意实现都不需要启动交互。需要会话协商的数据报实现必须先定义其启动和关联所有权，再纳入本规范。

### encodeOutbound(_:address:)

```swift
func encodeOutbound(_ data: Data, address: NetworkAddress?) throws -> Data
```

| 项目 | 说明 |
|---|---|
| 调用时机 | 普通 HTTP：Wire 就绪后编码重建的源站请求。CONNECT 隧道：本地成功回复写完后编码客户端载荷。UDP：本地来源与头部校验通过后编码一包 DATA |
| data | 纯业务数据；不包含本地 SOCKS 头、本地 CONNECT 请求或本地认证信息 |
| address | TCP 必须 nil，复用 start 固定的目标；UDP 必须是当前包的非零端口目标 |
| 返回 | 可直接写下游的完整编码输出；TCP 按调用顺序写，UDP 一次返回对应一个完整数据报 |
| 失败 | 未就绪、缺少目标、目标不可表达或长度超限等原始错误；不能返回截断结果或换路重试 |

成功返回必须交付本次业务输入所需的全部输出，不等待下一次调用或结束方法补发。TCP 空输入返回空 Data 且不推进状态；UDP 空载荷是一个真实业务数据报。返回内容不得再次送入 encodeOutbound，网络写入与背压由 Connection 负责。

### decodeInbound(_:)

```swift
func decodeInbound(_ bytes: Data) throws -> WireResult
```

| 项目 | 说明 |
|---|---|
| 调用时机 | TCP 节点 Channel 每次读到字节，包括启动尚未就绪期间。UDP 收到完整包并验证实际来源、选中登记的 Wire 后 |
| bytes | TCP 是任意分片；UDP 是一个完整后端数据报。都不是客户端入口原始报文 |
| 返回 | outbound 是必要控制输出；inbound 是纯业务数据及逻辑来源；ready 是内部就绪状态 |
| 不完整输入 | TCP 保存合法半帧、返回空业务数组；UDP 整包拒绝，不能借下一包补齐 |
| 空输入与失败 | TCP 空 Data 不表示 EOF。无法验证的控制或业务编码抛原始错误，不向客户端交付未验证数据 |

TCP 的业务结果地址必须保持启动目标；UDP 的业务来源由当前包解码取得。Connection 写出控制结果，再按本地回复屏障和输出预算交付业务数据。普通 HTTP 将业务数据交给 HTTP 响应处理；UDP 重新生成本地数据报头。

WireResult 是对已有 start / decode 返回值的扩展，不是额外的网络操作。当前实现尚无“收到控制输入后再产生控制输出”的通用消费路径；这是草案明确要求补齐的启动能力。它也解决“同一次处理既就绪又返回业务数据”的排序，不能因这项目标要求宣称当前实现已经支持多轮启动。

### finishInbound()

```swift
func finishInbound() throws
```

| 项目 | 说明 |
|---|---|
| 实际需求 | TCP decode 已收下半个帧时，对端关闭连接；仅向本地传播 EOF 会把协议截断伪装成正常结束 |
| 调用时机 | 下游输入真正结束，所有先前读取已交给 decodeInbound 之后、向本地传播正常 EOF 之前 |
| 输入 / 返回 | 无参数、无业务输出；完整输入返回 Void，缺少必需的启动 / 帧字节时抛原始截断错误 |
| 状态 | 流的成功结束标记解码方向完成；重复调用不重复处理，之后不能继续解码新输入；出站编码方向仍可使用 |
| 职责边界 | 不关闭任何 Channel，不等待写入，不把空解码结果当作结束，不决定本地 HTTP / SOCKS 错误码 |

待迁移调用点是具体 TCP Connection 的 `userInboundEventTriggered(.inputClosed)`，包括普通 HTTP；有正常全关闭而无该事件的路径时，也必须在相同最终结束边界检查一次。已确定网络错误或取消的路径保留原错误，不通过该方法把它覆盖成截断错误。

从未开始接收的可选业务单元不能因“没有首字节”就被判定为截断。已经开始但未完整的单元，或当前启动状态明确要求而尚未收到的必需输入，才构成截断；合法的零业务字节流应正常结束。

本版 UDP 每次 decode 已完成整包验证，没有跨包残留需要在关联结束时检查，因此 finishInbound 是无副作用的空操作，正常 UDP 回包路径不调用它；调用也不能影响其他包或共享实例。与 TCP 的语义差异来自输入边界，不需要另建一个 UDP 接口。

### bufferedBytes

```swift
var bufferedBytes: Int { get }
```

| 项目 | 说明 |
|---|---|
| 实际需求 | 节点逐次发送不足一个完整单元的字节，decode 暂无业务输出，但这些字节已占用 Wire 内部缓冲；只统计 Connection 队列会漏掉它们 |
| 调用时机 | 状态推进后同步读取，Connection 合并自身排队数据的计费，再决定后续读取或超限失败；内部实现须在分配前自行检查预算 |
| 返回 | 当前仍保留的协议数据逻辑字节数，非负；不包括已移交结果及固定大小算法状态 |
| 计量边界 | 已消费但仍留在输入片段中的字节也计入，直到释放或压缩该片段；该值不是分配器容量、完整堆内存或 RSS |
| UDP | 本版独立数据报调用返回后不保留包数据，返回 0；不把共享实例占用重复计入多个关联 |

该属性只用于资源预算和观测，不能判断是否已经收到完整帧、是否就绪或是否结束。Wire 内部先限制分配，Connection 的事后读取不能替代这个保护；目标预算消费路径尚未实现。

等待更多输入才能完成的半帧不能靠永久暂停读取来“等待自身排空”。预算不足以继续推进时须明确失败或按既定期限结束，不能出现既不读取也不释放的死等。

## 业务调用顺序

### TCP：HTTP CONNECT、SOCKS4 CONNECT、SOCKS5 CONNECT

```text
入口解析 → NetworkAddress → Core.routeTCPWire(target)
    → getEndpoint() + getTimeout() → 创建节点 TCP Channel
    → start(handshake: target) → 计入 bufferedBytes 与结果队列预算
    → 写控制输出；需要输入时 decodeInbound，再检查预算和启动期限
    → ready 且必要写入完成 → 写完整本地成功回复
    → 客户端业务数据：encodeOutbound(data, address: nil) → 下游写入
    → 节点输入：decodeInbound → 必要控制写入 + 业务数据回送
    → 节点正常 EOF：finishInbound → 传播本地输出结束
    → 最终清理：Connection 关闭所属 Channel 并释放 Wire 引用
```

客户端输入 EOF 由 Connection 等待已排队输出写完，再半关闭节点 Channel；不需要额外 Wire 编码结束方法。DIRECT 分支不调用 Wire。

### 普通 HTTP

节点选择、建连和启动顺序相同。Wire 就绪后，`HttpForwardConnection` 将重建的源站请求交给 encodeOutbound；decodeInbound 只交付业务响应，不能将节点控制字节交给 HTTP 响应处理，也不生成本地 CONNECT 成功回复。节点 EOF 检查 Wire 完整性之后，HTTP 层仍须按自身消息定界判断响应是否完整。

### SOCKS5 UDP

```text
客户端数据报 → 来源校验 / 去除本地 UDP 头 → target + DATA
    → Core.routeUDPWire(target) → getEndpoint()
    → encodeOutbound(DATA, address: target) → 向实际节点发送一个数据报
节点数据报 → 来源校验 / 找到登记的 Wire
    → decodeInbound → 必要控制包 + 解码业务来源与 DATA
    → 重新生成本地 UDP 头 → 发回固定客户端端点
关联结束 → 关闭所属 Channel / 清理记录 / 释放独占 Wire 引用
```

该路径不执行 TCP connect，不套用 getTimeout 等待每包响应，也不伪造 TCP EOF。共享 Wire 的引用由 Core 运行周期管理，单个关联结束不能销毁其他关联仍在使用的实例。

### 当前源码调用入口

| 源码 | 已有调用与待迁移位置 |
|---|---|
| [Socks4Connection.swift](../Sources/Connection/Socks4Connection.swift) | installWireChannel 调端点、超时与 start；outbound / inbound 调编解码；inputClosed 待加入 finishInbound |
| [Socks5Connection.swift](../Sources/Connection/Socks5Connection.swift) | TCP 同上；UDP handler 的 outbound / inbound 按包调用编解码并记录实际端点 |
| [HttpConnectConnection.swift](../Sources/Connection/HttpConnectConnection.swift) | installWireChannel 建连与启动；隧道编解码；成功回复和 EOF 由 Connection 控制 |
| [HttpForwardConnection.swift](../Sources/Connection/HttpForwardConnection.swift) | installWireChannel 启动后编码源站请求；inbound 解码响应；EOF 待加入完整性检查 |
| [MagentCore.swift](../Sources/Core/MagentCore.swift) | routeTCPWire / routeUDPWire 选择实现；createTCPClientChannel 消费实际 SocketAddress 与毫秒超时 |

原始协议字节和具体后端实现文件不属于本规范的接口说明范围。

## TCP 契约

### 启动与状态转换

```text
创建 Wire → idle
下游 Channel 建立 → start(target)
    ├─ ready=false → starting → decodeInbound(后续下游字节) → starting / ready
    └─ ready=true  → ready
ready → 编码 / 解码 → 各方向结束 → Connection 清理并释放引用
任意不可恢复错误 → failed → Connection 清理并释放引用
任意阶段取消 → Connection 清理并释放引用
```

1. `start(handshake:)` 只能成功调用一次，并固定该 TCP 逻辑目标。重复调用必须报状态错误，不能悄悄忽略第二个目标或重新启动。
2. 不需要发出启动字节时，outbound 可以为空。需要等待下游控制输入时返回 ready=false；收到该输入后由 decodeInbound 继续推进，必要时再产生 outbound。
3. ready 一旦为 true，在后续成功返回中不得回到 false；断开或错误通过失败路径处理，不用 ready=false 隐藏已经失效的连接。
4. Wire 不得等待客户端首段业务数据才判断是否可以开始业务传输。需要固定目标和配置的启动内容应通过 start 产生。
5. Connection 在 starting 阶段持续按预算读取下游，并写入返回的控制字节；不能因为尚未 ready 就停止所有下游读取，也不能转发客户端提前业务数据。
6. 只有 ready=true，且截至该结果所产生的全部必要 outbound 已成功写入，下游路径才可被 Connection 标记为就绪。任一写失败、截止时间到期或取消都使本地成功失去资格。

Wire 自身判断启动条件；Connection 只检查抽象 ready 与写入 future。ready 允许表示无需额外远端确认的实现已经完成本地启动，但不能被描述成最终目标一定可达。

### 本地回复屏障

HTTP CONNECT、SOCKS4 CONNECT 和 SOCKS5 CONNECT 在下游就绪后生成自己的成功回复。回复完整写完之前，Wire 解码出的业务数据由 Connection 按入口预算保留。ready=false 时，TCP WireResult.inbound 必须为空；ready=true 与首段业务数据可在同一结果中出现。

普通 HTTP 在下游就绪后发送已经校验、重建的源站请求，不能自造 CONNECT 成功响应代替源站业务响应。HTTP 消息解析只接收 Wire 解码后的业务字节。

本地成功一旦开始，后续失败不能追加另一条协议错误回复。是否接收本地客户端提前数据、余量上限与回复内容由对应入口 SPEC 决定，不由 Wire 改变。

### 业务编码

ready 之前禁止 encodeOutbound。TCP 的 address 参数必须为 nil；目标已经由 start 固定，后续数据不得重新选择目标或将目标头当作业务内容重复发送。

一次调用的业务字节按序编码到返回的 Data。调用边界不等于线上帧边界，但成功返回必须交付本次输入所需的输出，不能把业务数据无限留在 Wire 内等待下一次调用。空业务输入不推进流状态，不产生额外线上字节。

Connection 将编码结果按调用顺序写入下游；前一次写入的背压约束未解除时不无限读取本地数据。Wire 不能直接操作 Channel 来绕过排序和预算。

### 增量解码

decodeInbound 接受任意大小的 TCP 分片。一个片段可以只包含部分控制信息、一个完整业务单元或多个单元。方法必须精确消费自己的协议内容，保留尚未完整的部分；不能假定一次 read 就是一帧。

不完整但仍合法的输入返回空业务数组并保留状态，不抛“截断”错误。已确定非法的输入立即失败；不能跳过坏字节尝试重新同步，不能交付未验证的业务数据。若同次输入解析到后续错误并抛出，调用方不能收到该次调用中尚未返回的部分结果。

控制输出与业务输出分别保序。Connection 先处理该结果的必要控制写入，再按就绪与本地回复屏障交付业务数据，不把控制输出重新编码。

### EOF 与半关闭

Wire 必须显式区分输入为空和传输 EOF。空 Data 不是 EOF；真实下游 EOF 到达时 Connection 调用 finishInbound。

- finishInbound 检查尚未完成的启动或帧；存在必需但缺失的字节时抛截断错误，不能当成正常流结束。合法 EOF 只结束入站解码方向，出站方向仍可使用。
- 本地输入 EOF 时，Connection 先处理已接收的全部业务字节；按序写完所有在途业务和控制输出后，才关闭下游 Channel 的输出方向。编码调用必须已返回本次输入的全部输出，不隐含待刷新的尾部。
- 输出方向关闭后，Connection 不再调用 encodeOutbound；入站解码仍可继续。如果此后结果要求新的控制写入，Connection 按无法完成写入处理错误，不能丢弃控制输出后继续宣称成功。
- finishInbound 成功后再次调用为空操作，不重复校验已释放的数据；首次失败使该 TCP Wire 进入 failed。
- EOF 不等于整个实例结束。两个方向结束，或发生错误、取消后，Connection 再关闭所属资源并释放引用。

## UDP 契约

### 单包输入与输出

本版独立数据报实例创建并校验后即可执行每包编码和解码，decode 成功返回 ready=true。正常 UDP 路径不需要调用 start 或 finishInbound；二者被调用时分别返回立即就绪的空结果或执行空操作，不改变逐包目标及其他关联状态。需要会话启动的数据报能力不由这一规则自动获得支持。

encodeOutbound 的 address 必须是该数据报的非零端口 NetworkAddress；data 可以为空。一次调用返回一个完整出站数据报。接口不隐式分片、不合并相邻数据报，也不把 UDP 数据写入 TCP 控制连接。

decodeInbound 的输入是一个完整接收的后端数据报；丢包或截断不能等待下一包补齐。一次成功解码只交付该包完整的业务数据与逻辑来源。无法验证的输入整包拒绝，不返回部分载荷。UDP 控制包若不含业务内容可以返回空 inbound；其必要控制输出仍是独立完整数据报。

本版不定义跨包重组或一包聚合多个业务数据报；需要这些能力时必须补充明确的包边界、丢包与资源契约。

### 与本地关联协作

SOCKS5 Connection 校验本地 UDP 来源并移除本地头部后，才把目标与 DATA 交给 Wire。Wire 不接受本地控制请求作为目标，也不以本地 UDP 头的字段推断自己的节点协议。

Connection 将编码结果发送到 getEndpoint 返回的实际节点端点，记录所属关联、实际后端及对应 Wire。后端响应先经过实际来源检查，再选择已登记的 Wire 解码，不能仅凭载荷声称的地址选择解码器。

解码得到的逻辑来源由 Connection 按本地协议重新封装。实际节点地址不是业务来源；未知来源不能跨关联转发。共享 Wire 不共享客户端端点、授权或本地中继生命周期。

单个坏包通常只丢弃该包，不能破坏其他独立包或关联。若实现状态已经不可恢复，应原样报告错误并由 Connection 关闭所属后端状态；不得扩大为无关连接的关闭。

## 错误与资源

### 错误归属

| 情况 | 抽象处理 |
|---|---|
| 目标缺失、地址类型不可表达、传输不匹配 | 当前操作失败，不更换目标或尝试另一传输 |
| 重复 TCP 启动、提前业务编码、已结束后继续解码 | 明确状态错误，不重新激活流状态 |
| 启动或协议字段非法 | 抛出所属边界原始错误，TCP 进入 failed |
| 内部缓冲或结果超过预算 | 失败，不返回截断数据或无限扩容 |
| TCP EOF 时有未完成的必需输入 | 截断错误 |
| UDP 坏包 | 拒绝当前数据报；独立后续包仍可处理 |
| 网络写入、连接超时、取消 | Connection 处理；Wire 不伪造网络结果 |

辅助方法不得仅为包装、改名或路由错误而 catch。需要本地清理时重抛原始错误。HTTP 状态和 SOCKS 回复码只由 Connection 统一映射；Wire 不返回任何本地协议响应。

### 缓冲和进度

bufferedBytes 报告 Wire 当前仍保留的协议数据逻辑字节数，不包括已移交结果或固定大小实现状态。保留完整输入片段的切片按该片段长度计费；消费偏移前移但尚未释放的部分仍计入。释放或压缩片段后及时减少。分配容量和临时峰值还须由实现的独立上限约束，该属性不承诺计量完整物理内存。

每个实现必须在创建时取得有界缓冲和单次输出预算；校验长度、溢出和预算后才分配。未知的线上长度不能直接变成无界容量。Connection 将 Wire 内部占用与自身结果队列纳入统一预算，数据转移只计费一次。

每次同步方法必须有限完成。增量解析保存进度，已消费字节不在每次调用中重复扫描；不允许输入不前进却不断产生控制输出的循环。下游迟迟不给出必需输入时，由 Connection 的绝对启动期限终止，收到少量字节不自动续期。

### 关闭和生命周期

本版没有 Wire.close。TCP Connection 最终清理时停止新的编解码，关闭所属下游资源并释放 Wire 引用；需要立即释放缓冲时，必须清除仍捕获该实例的任务、回调和队列所有权。内存状态随最后一个引用释放，不以一个空 close 方法替代真实所有权清理。

独占 UDP Wire 随所属后端状态释放；共享且经验证可共享的 UDP Wire 由 Core 的运行周期持有，各 Connection 只释放自己的关联记录和引用。单个关联不能清空其他关联仍使用的共享状态。Connection 的缓冲计费记录也必须在所属对象结束时释放。

所有 Channel 和正在等待的 future 由 Connection 处理。关闭后的迟到回调不得再次调用 Wire、写本地成功或创建新 Channel。restart 产生新 Core / 新运行周期，旧 Wire 不进入新周期。

## 验收

### 接口与消费路径

| ID | 场景 | 必须断言 |
|---|---|---|
| W-01 | 端点与超时 | 精确保留实际 SocketAddress 与毫秒字面量，getter 无 DNS / I/O |
| W-02 | 相同目标经三个 TCP 入口 | Wire 收到相同规范化 NetworkAddress；不收到原始入口头或本地凭据 |
| W-03 | 目标与节点不同 | 路由一次、选择一次，实际拨号与所选 Wire 一致，不把节点再次路由 |
| W-04 | TCP 无控制输出启动 | ready=true、outbound 为空；可立即进入本地成功流程 |
| W-05 | TCP 启动需要多轮输入 | ready=false 时继续下游读写，返回的控制输出只写下游 |
| W-06 | ready=true 但启动写未完成 | 本地成功尚未开始；写失败走唯一失败边界 |
| W-07 | 重复启动或提前编码 | 明确失败，不换目标、不污染另一实例 |
| W-08 | TCP 全部分片、逐字节与多帧粘包 | 最终业务字节精确一致，无重复、遗漏或控制字节泄露 |
| W-09 | ready 与首段业务数据同次返回 | 启动写和本地成功屏障后才交付业务数据 |
| W-10 | 暂无完整帧与合法空输入 | 空结果不是 EOF；不会提前关闭或忙循环 |
| W-11 | TCP 本地输入 EOF | 已排队业务与控制输出完整写完才关闭输出；无需额外编码 flush，反向继续可用 |
| W-12 | 启动/帧中途 EOF 与合法空业务流 | 缺失必需输入时截断失败；未开始可选单元不误报截断 |
| W-13 | UDP 空载荷与完整数据报 | 空业务包可往返；不合包、不拆包、不跨包补齐 |
| W-14 | UDP 多目标与实际后端 | 逐包目标正确，回包使用登记的 Wire，节点不冒充业务来源 |
| W-15 | UDP 单个坏包 | 整包拒绝，后续独立合法包与其他关联不受污染 |
| W-16 | 缺少目标、端口 0、能力不符 | 当前操作失败，无默认端点或 DIRECT 回退 |
| W-17 | 替换两个行为不同的测试 Wire | HTTP / SOCKS 解析和回复代码不按实现名称分支 |
| W-18 | 原始错误传播 | Connection 收到原始错误；只有最高拥有边界决定本地回复和关闭 |
| W-19 | 长度溢出、超限、逐字节输入 | 内存与解析工作有界，先校验后分配 |
| W-20 | Connection 清理、取消与迟到完成竞争 | 释放所属引用与计费记录，迟到回调不再调用 Wire、不重复回复 |
| W-21 | 并发连接与 UDP 共享条件 | TCP 状态隔离；UDP 共享不串客户端或端点，独占实例串行调用 |
| W-22 | HTTP 普通请求与 CONNECT | 前者发送源站请求并处理业务响应；后者本地成功后进入隧道 |
| W-23 | restart 与运行周期 | 旧 Wire 清理，新周期不继承旧缓冲、状态或已完成通知 |
| W-24 | 接口最小集合 | 仅一套 Wire；端点 getter 明确返回节点；Core / Connection 不依赖额外传输开关 |
| W-25 | UDP 非必需生命周期调用 | start 返回立即就绪且不固定逐包目标；finishInbound 为空操作，不污染后续包或共享关联 |
| W-26 | 缓冲计量 | TCP 未完整输入计入预算，已移交结果不重复计费；UDP 每包调用后为零 |

测试先使用可控 Wire 和 Channel 验证集成契约，再由各具体实现单独验收其编解码及互操作。测试必须经过真实 Core / Connection 所有权路径，不为方便测试添加生产专用开关。成功证据区分静态检查、定向测试、包级测试和真实网络集成。

### 当前接口与迁移边界

[Wire.swift](../Sources/Wire/Wire.swift) 是当前抽象入口，[WireTests.swift](../Tests/Wire/WireTests.swift) 是已有公共端点与超时测试入口。当前代码仍名为 getTargetAddress；start 返回可选 Data，decodeInbound 返回单个 InboundData；尚无本规范的 WireResult、bufferedBytes 与 finishInbound。名称迁移、返回值扩展及两项新增成员都需要实现和消费路径配套修改，不能因本文建立就宣称已经完成。

迁移时同时更新 Core、HTTP/SOCKS Connection 与所有实现：由 Connection 处理 ready 和必要控制写入；原来仅生成启动字节的路径可以一次返回 ready=true，但仍须等待写入完成。需要下游输入的启动路径通过同一接口推进，不新增入口专属控制解析器。

本规范不授权保留一套旧兼容接口或为每个入口增加特例。迁移必须保持模型构造、Channel 所有权与错误路由边界，完成 W-01～W-26 对应验收后，才能声明抽象接口及其消费路径一致。
