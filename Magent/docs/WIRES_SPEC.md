---
desc: "出站 Wire 的抽象接口、TCP 启动与编解码、UDP 数据报、所有权、错误及验收契约。"
version: "0.3.0"
updated_at: "2026-09-26"
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
| Wire | 一个明确传输种类的启动编码、出站编码、入站解码及内部有界缓冲 | 提供实际节点端点；按调用方向接收和返回数据，不执行网络 I/O |

Wire 不拥有 Channel、EventLoopGroup、DNS 客户端或本地会话；不匹配路由，不选择其他节点，不创建线程或 Task，不自行发送数据、定时重试或调用 Connection 的清理路径。所有网络读写和截止时间由 Connection 执行。

DIRECT 不要求构造空 Wire 或假节点。PROXY 的 Wire 创建或执行失败不能转换为 DIRECT。每条 TCP 路由只匹配一次并选择一次 Wire；同一个 Wire 同时决定拨号端点和该连接的编解码状态。

### 与其他 SPEC 的关系

- [模型规范](MODELS_SPEC.md) 定义 NetworkAddress、ProxyNode、Decision 与规则的构造和身份语义；本规范不增加地址兼容入口或新的节点协议枚举。
- [HTTP SPEC](HTTP_PROXY_SPEC.md)、[SOCKS4 SPEC](SOCKS4_PROXY_SPEC.md)、[SOCKS5 SPEC](SOCKS5_PROXY_SPEC.md) 定义各自的本地报文、认证、回复、提前数据及 UDP 来源规则。
- 本规范统一定义入口完成路由之后如何使用 Wire。新增实现不能要求入口识别其协议名称、控制字段、状态码或凭据。

本版表达采用单次本地启动的一条 TCP 业务字节流，或独立 UDP 数据报。TCP 启动不等待远端确认；需要多轮网络协商、解码时反向生成控制输出或独立 UDP 控制交互的实现不属于本版接口范围。连接池、跨客户端多路复用、多个 Channel 联合控制和传输种类转换不属于本接口的隐含能力；需要这些能力时先定义可验证的所有权与数据边界，不能在现有返回值中隐藏第二条连接。

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

/// 解码后的业务字节及逻辑来源；不携带出站数据或连接状态。
internal struct InboundData {
    let data: Data
    let address: NetworkAddress
}

internal protocol Wire: AnyObject {
    /// 与该 Wire 通信的实际节点端点；不是客户端请求中的业务目标。
    func getEndpoint() -> SocketAddress
    /// 连接节点的超时，单位为毫秒；不表示 UDP 响应期限。
    func getTimeout() -> Int64

    /// 固定 TCP 业务目标，返回直接写入节点的启动字节；无需发送时返回 nil。
    func start(handshake target: NetworkAddress) throws -> Data?
    /// 编码业务字节；流的目标已在启动时固定，数据报逐包提供目标。
    func encodeOutbound(_ data: Data, address: NetworkAddress?) throws -> Data
    /// 解码节点输入，仅返回业务数据及逻辑来源；TCP 空 data 表示暂未解出业务字节。
    func decodeInbound(_ bytes: Data) throws -> InboundData

    /// 输入确实结束时检查是否截断，不关闭 Channel 或结束反向发送。
    func finishInbound() throws
}
```

接口不包含入口协议种类、HTTP 方法、SOCKS 命令、节点协议名或具体安全参数。Wire 构造由 Core 与节点配置负责；此处不规定一个能接收任意协议参数字典的通用初始化器。

这里只定义一套 Wire 接口。Core 的 TCP / UDP 选择入口和 Connection 已经知道当前业务的数据边界，不再由 Wire 重复暴露一个 transport 开关。Core 必须返回适用于当前操作的实例；同一节点的 TCP 可用不证明 UDP 可用。本版连接流程分别使用 TCP Channel 和 UDP Channel；这不表示任意后端的承载方式都必然等于入口业务种类，跨传输承载仍属于本版范围之外。

各方法的返回值只有一个方向，不携带启动、就绪、关闭等连接状态：

| 方法 | 返回值与调用者的处理 |
|---|---|
| start | Data?；非空启动字节直接写入节点，不再次编码；nil 表示无需启动写入 |
| encodeOutbound | Data；直接写入节点的编码业务数据，不能交给本地客户端 |
| decodeInbound | InboundData；仅含解码业务数据与逻辑来源，交给业务接收方，不写回节点 |

TCP 的 InboundData.data 可以为空，表示本次没有可交付业务字节，不表示 EOF。UDP 的每次成功解码返回一个完整业务数据报，data 为空仍表示有效的零长度数据报。两者由调用路径确定，不通过结果中的状态字段区分。

Wire 内部保留必要的目标、编解码进度及协议缓冲；Connection 持有网络写入和会话生命周期状态。数据返回值不承担这两类状态的同步。

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
| start | TCP Channel 建好后固定业务目标并返回可选启动字节 | 保持现有 Data? 返回类型；重复启动等行为仍须按本规范验收 |
| encodeOutbound | HTTP 源站请求、隧道载荷或单个 UDP DATA 编码 | 已有方法和调用 |
| decodeInbound | 下游 TCP 读取或已确认来源的 UDP 回包解码 | 保持现有 InboundData 返回类型 |
| finishInbound | 下游流 EOF 时检查 Wire 内是否还缺少必需字节 | 新增；当前 EOF 路径直接传播半关闭，尚未检查解码器尾部状态 |

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
func start(handshake target: NetworkAddress) throws -> Data?
```

| 项目 | 说明 |
|---|---|
| 调用时机 | TCP 节点 Channel 建立后、本地 CONNECT 成功回复或普通 HTTP 源站请求发送之前 |
| 参数 | 客户端请求中经过模型校验的业务目标；不能传节点端点或本地 listener |
| 返回 | 直接写入节点的启动字节；无需发送时返回 nil，不返回业务数据或状态 |
| 状态 | TCP 首次调用固定目标并完成本地编解码初始化；重复启动或不支持该目标时报原始错误，不重新选路 |
| 调用者后续动作 | 有启动字节时先等待写入成功；无启动字节时直接进入下一阶段。写入失败、超时或取消均终止启动 |

TCP 的非 nil 返回值必须包含启动字节，不以空 Data 表达另一个启动状态。start 成功返回只说明本地初始化成功，不能证明启动字节已经写出或最终目标已经可达。Connection 通过调用完成和网络写入完成判断下游就绪，不查询 Wire 的 ready 属性，也不依赖 decodeInbound 推进启动。

本版独立数据报实现不需要连接级启动，UDP 发送路径直接编码；若调用 start，返回 nil，不固定参数中的目标，也不改变后续逐包目标。需要会话协商的数据报实现不属于本版范围。

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
| 失败 | TCP 尚未启动、缺少目标、目标不可表达或长度超限等原始错误；不能返回截断结果或换路重试 |

成功返回必须交付本次业务输入所需的全部输出，不等待下一次调用或结束方法补发。TCP 空输入返回空 Data 且不推进状态；UDP 空载荷是一个真实业务数据报。返回内容不得再次送入 encodeOutbound，网络写入与背压由 Connection 负责。

### decodeInbound(_:)

```swift
func decodeInbound(_ bytes: Data) throws -> InboundData
```

| 项目 | 说明 |
|---|---|
| 调用时机 | TCP 已调用 start 后，节点 Channel 每次读到字节。UDP 收到完整包并验证实际来源、选中登记的 Wire 后 |
| bytes | TCP 是任意分片；UDP 是一个完整后端数据报。都不是客户端入口原始报文 |
| 返回 | 仅包含本次解码的纯业务数据及逻辑来源，不包含出站字节或生命周期状态 |
| 不完整输入 | TCP 仅保留尚不能完成解码或验证的 Wire 协议字节，将本次已解码并验证的业务字节按序合并到 data；无可交付数据时 data 为空。UDP 整包拒绝，不能借下一包补齐 |
| 空输入与失败 | TCP 空 Data 不表示 EOF。无法验证的协议编码抛原始错误，不向客户端交付未验证数据 |

TCP 的返回地址必须保持启动目标，包括 data 为空的情况；UDP 的业务来源由当前包解码取得。Connection 按本地回复屏障和输出预算交付 data，普通 HTTP 将其交给 HTTP 响应处理，UDP 重新生成本地数据报头。

该方法只消费入站协议字节，不触发网络写入，也不生成需要调用者写回节点的数据。本版不支持依赖此类反向控制交互的实现。

### finishInbound()

```swift
func finishInbound() throws
```

| 项目 | 说明 |
|---|---|
| 实际需求 | Wire 协议编码单元尚未接收完整时，对端关闭 TCP 连接；仅向本地传播 EOF 会把协议截断伪装成正常结束 |
| 调用时机 | 下游输入真正结束，所有先前读取已交给 decodeInbound 之后、向本地传播正常 EOF 之前 |
| 输入 / 返回 | 无参数、无业务输出；完整输入返回 Void，缺少必需的 Wire 协议编码单元字节时抛原始截断错误 |
| 状态 | 流的成功结束标记解码方向完成；重复调用不重复处理，之后不能继续解码新输入；出站编码方向仍可使用 |
| 职责边界 | 不关闭任何 Channel，不等待写入，不把空解码结果当作结束，不决定本地 HTTP / SOCKS 错误码 |

待迁移调用点是具体 TCP Connection 的 `userInboundEventTriggered(.inputClosed)`，包括普通 HTTP；有正常全关闭而无该事件的路径时，也必须在相同最终结束边界检查一次。已确定网络错误或取消的路径保留原错误，不通过该方法把它覆盖成截断错误。

从未开始接收的可选 Wire 协议编码单元不能因“没有首字节”就被判定为截断。已经开始但未完整的协议编码单元，或当前解码状态明确要求而尚未收到的必需输入，才构成截断；合法的零业务字节流应正常结束。Wire 不检查隧道内业务报文的完整性。

本版 UDP 每次 decode 已完成整包验证，没有跨包残留需要在关联结束时检查，因此 finishInbound 是无副作用的空操作，正常 UDP 回包路径不调用它；调用也不能影响其他包或共享实例。与 TCP 的语义差异来自输入边界，不需要另建一个 UDP 接口。

## 业务调用顺序

### TCP例子

调用者已取得适用于 TCP 的独立 Wire 实例 `wire`，业务目标为 `example.com:9000`，待发送数据为字符串 `hello` 的字节序列。以下伪代码采用本规范定义的目标接口；网络收发由调用者负责，业务数据不包含 HTTP / SOCKS 入口协议头。

每条 TCP 连接使用独立 Wire 实例，业务目标在启动时确定。下例中的网络操作和事件为伪代码记法；await 表示异步操作完成后继续，不表示阻塞 EventLoop。同一连接的事件按序处理；启动完成前收到的节点输入由调用者有界排队，随后交给接收处理。

```pseudocode
// target 表示业务目标；TCP 实际连接的是 Wire 提供的代理节点端点。
target = NetworkAddress(host: "example.com", port: 9000)
tcp = await TCP.connect(
    endpoint: wire.getEndpoint(),
    timeoutMilliseconds: wire.getTimeout()
)

// 启动返回值只用于向节点发送；无需启动字节时返回 nil。
startupBytes = wire.start(handshake: target)
if startupBytes != nil:
    await tcp.writeAll(startupBytes)

// 解码仅返回业务数据；空 data 表示暂未解出数据，不表示 EOF。
on tcp.received(bytes):
    message = wire.decodeInbound(bytes)
    if not message.data.isEmpty:
        application.receive(message.data)

// 仅在真实 EOF 时检查协议输入完整性；Wire 不检查业务报文边界。
on tcp.inputClosed:
    wire.finishInbound()
    application.finishInput()

// 后续发送沿用同一实例；address 为 nil，不重复指定目标或启动。
on application.send(payload):
    await tcp.writeAll(wire.encodeOutbound(payload, address: nil))

// 接收处理独立于业务发送，节点可以主动发送首段数据。
payload = Bytes.utf8("hello")
await tcp.writeAll(wire.encodeOutbound(payload, address: nil))
```

start 和 encodeOutbound 的结果直接写入节点；decodeInbound 的结果只交给业务接收方。启动写入失败、超时或取消时停止处理，不执行后续业务发送。接收处理不依赖首段业务发送或其写入完成，节点先发数据也能按序交付。

TCP 输入允许任意分片，Wire 只解码自身协议，不拼装完整业务报文。本地输入 EOF 时，调用者先完成在途输出，再关闭节点连接的输出方向；会话结束时关闭所属连接并释放 Wire 引用。Wire 自行限制协议解码所需的内部缓冲；调用者负责自身队列、背压、启动写入期限及错误处理。

### UDP例子

调用者已取得适用于 UDP 的 Wire 实例 `wire` 及匹配节点地址族的 UDP socket `udp`，业务目标为 `198.51.100.20:9001`，待发送数据为字符串 `ping` 的字节序列。以下伪代码采用本规范定义的目标接口；每次编码对应一个完整数据报，associations 表示当前关联内已登记的节点端点与 Wire 对应关系。

```pseudocode
// 独立 UDP 数据报无需启动；每次编码均传入当前数据报的业务目标。
target = NetworkAddress(host: "198.51.100.20", port: 9001)
payload = Bytes.utf8("ping")
endpoint = wire.getEndpoint()
packet = wire.encodeOutbound(payload, address: target)
// 登记实际节点端点及对应 Wire，供响应来源校验和解码使用。
associations[endpoint] = wire
// 一次编码结果作为一个完整数据报发送，不拆分或合并。
await udp.send(packet, to: endpoint)

on udp.received(packet, from: sender):
    // 先校验实际发送方；未登记来源的数据报直接丢弃。
    if sender not in associations:
        return
    wire = associations[sender]
    // 每次解码消费一个完整数据报，不与后续数据报拼接。
    message = wire.decodeInbound(packet)
    // 业务来源取解码结果中的 address；空 data 仍须交付为一个数据报。
    application.receiveDatagram(message.data, from: message.address)
```

本版独立 UDP 数据报无需调用 start / finishInbound，也无需建立 TCP 连接。每次编码必须传入当前数据报的 target；同一 Wire 支持的业务目标可逐包改变。响应数据报的业务来源由解码结果中的 address 表示，不得以代理节点 endpoint 替代。空业务载荷仍是有效数据报。

UDP Wire 在每次编解码返回后不保留跨包数据；调用者限制自身持有的数据报及发送队列。关联结束时，调用者关闭所属网络资源、清理端点记录并释放持有的 Wire 引用。

### TCP：HTTP CONNECT、SOCKS4 CONNECT、SOCKS5 CONNECT

```text
入口解析 → NetworkAddress → Core.routeTCPWire(target)
    → getEndpoint() + getTimeout() → 创建节点 TCP Channel
    → start(handshake: target) → 有启动字节时直接写入节点并等待成功
    → 无启动字节或启动写入完成 → 写完整本地成功回复
    → 客户端业务数据：encodeOutbound(data, address: nil) → 下游写入
    → 节点输入：decodeInbound → 本地成功屏障后回送非空业务数据
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
    → decodeInbound → 单个业务数据报的来源与 DATA
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

以下是调用者管理的连接流程，不是 Wire 返回值中的状态：

```text
创建 Wire → 建立节点 Channel → start(target)
    ├─ 返回 nil → 下游就绪
    └─ 返回启动字节 → 直接写入节点 → 写入成功后下游就绪
下游就绪 → 完成本地回复屏障 → 业务传输 → 各方向结束 → 清理
任意阶段错误或取消 → Connection 清理并释放引用
```

1. `start(handshake:)` 只能成功调用一次，并固定该 TCP 逻辑目标。重复调用必须报状态错误，不能忽略第二个目标或重新启动。
2. start 成功返回即完成本地编解码初始化，不等待节点输入。无需启动字节时返回 nil；否则返回一次完整的启动输出。
3. Connection 必须在启动字节写入成功后才标记下游就绪。任一写失败、截止时间到期或取消都使本地成功失去资格；start 不观察网络写入结果。
4. 启动不能等待客户端首段业务数据。没有启动字节时，Connection 不等待节点首包即可进入下一阶段；这不证明最终目标可达。
5. start 成功后，Connection 可以将节点输入交给 decodeInbound；若业务数据早于启动写入完成或本地成功回复到达，按入口预算保留，不能提前交付。
6. 需要远端确认或多轮交互才能允许业务编码的实现不满足本版契约，不能用空数据或隐藏状态让 Connection 猜测协商进度。

### 本地回复屏障

HTTP CONNECT、SOCKS4 CONNECT 和 SOCKS5 CONNECT 在下游就绪后生成自己的成功回复。回复完整写完之前，Wire 解码出的业务数据由 Connection 按入口预算保留；完成后按序交付，包括节点主动发送的首段数据。启动输出和入站业务数据通过不同方法返回，不存在同一个结果同时宣布就绪和携带业务数据的情况。

普通 HTTP 在下游就绪后发送已经校验、重建的源站请求，不能自造 CONNECT 成功响应代替源站业务响应。HTTP 消息解析只接收 Wire 解码后的业务字节。

本地成功一旦开始，后续失败不能追加另一条协议错误回复。是否接收本地客户端提前数据、余量上限与回复内容由对应入口 SPEC 决定，不由 Wire 改变。

### 业务编码

TCP 在 start 成功之前禁止 encodeOutbound；Connection 还须等待启动写入及适用的本地回复屏障完成后才提交业务编码。TCP 的 address 参数必须为 nil；目标已经由 start 固定，后续数据不得重新选择目标或将目标头当作业务内容重复发送。

一次调用的业务字节按序编码到返回的 Data。Wire 将输入视为业务字节流，不解析或等待其中的完整业务报文。调用边界不等于 Wire 协议编码单元的边界，但成功返回必须交付本次输入所需的输出，不能把业务数据留在 Wire 内等待后续业务输入。空业务输入不推进流状态，不产生额外线上字节。

Connection 将编码结果按调用顺序写入下游；前一次写入的背压约束未解除时不无限读取本地数据。Wire 不能直接操作 Channel 来绕过排序和预算。

### 增量解码

decodeInbound 接受任意大小的 TCP 字节片段，读取边界不表示 Wire 协议编码单元或业务报文边界。Wire 只处理自身协议的控制信息、封装及验证，不解析隧道内的业务协议。

只有自身协议要求完整编码单元才能解码或验证时，Wire 才保留尚未完整的协议字节；不需要此类处理的透传实现直接返回收到的业务字节。每次成功调用必须返回本次已解码并验证的全部可交付业务数据，不能等待后续输入来拼装完整业务报文。返回的数据块不承诺保留对端写入或业务报文边界。

尚不完整但仍合法的协议输入保留为内部状态，不抛截断错误；本次无可交付业务数据时返回 data 为空的 InboundData。已确定非法的输入立即失败；不能跳过错误字节尝试重新同步，不能交付未验证的业务数据。若同次输入解析到后续错误并抛出，调用方不能收到该次调用中尚未返回的部分结果。

同次解码得到的业务字节按序合并到一个 InboundData.data，不保留内部协议单元边界；Connection 按调用顺序和本地回复屏障交付。decodeInbound 不产生出站输出，Connection 无需检查或发送反向控制数据。

### EOF 与半关闭

Wire 必须显式区分输入为空和传输 EOF。空 Data 不是 EOF；真实下游 EOF 到达时 Connection 调用 finishInbound。

- finishInbound 只检查尚未完成的 Wire 协议编码单元，不检查业务报文完整性；存在必需但缺失的协议字节时抛截断错误，不能当成正常流结束。合法 EOF 只结束入站解码方向，出站方向仍可使用。
- 本地输入 EOF 时，Connection 先处理已接收的全部业务字节；按序写完所有在途启动字节和业务输出后，才关闭下游 Channel 的输出方向。编码调用必须已返回本次输入的全部输出，不隐含待刷新的尾部。
- 输出方向关闭后，Connection 不再调用 encodeOutbound；入站解码仍可继续，且不依赖已关闭方向上的网络写入。
- finishInbound 成功后再次调用为空操作，不重复校验已释放的数据；首次失败使该 TCP Wire 进入 failed。
- EOF 不等于整个实例结束。两个方向结束，或发生错误、取消后，Connection 再关闭所属资源并释放引用。

## UDP 契约

### 单包输入与输出

本版独立数据报实例创建并校验后即可执行每包编码和解码。正常 UDP 路径不需要调用 start 或 finishInbound；二者被调用时分别返回 nil 或执行空操作，不改变逐包目标及其他关联状态。需要会话启动的数据报能力不由这一规则自动获得支持。

encodeOutbound 的 address 必须是该数据报的非零端口 NetworkAddress；data 可以为空。一次调用返回一个完整出站数据报。接口不隐式分片、不合并相邻数据报，也不把 UDP 数据写入 TCP 控制连接。

decodeInbound 的输入是一个完整接收的后端数据报；丢包或截断不能等待下一包补齐。一次成功解码返回一个 InboundData，包含该包完整的业务数据与逻辑来源；data 为空仍须作为一个零长度业务数据报交付。无法验证或不符合本版独立业务数据报契约的输入整包拒绝，不返回部分载荷，也不生成响应控制包。

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
| Wire 内部缓冲或单次输出超过自身上限 | 失败，不返回截断数据或无限扩容 |
| TCP EOF 时有未完成的必需输入 | 截断错误 |
| UDP 坏包 | 拒绝当前数据报；独立后续包仍可处理 |
| 网络写入、连接超时、取消 | Connection 处理；Wire 不伪造网络结果 |

辅助方法不得仅为包装、改名或路由错误而 catch。需要本地清理时重抛原始错误。HTTP 状态和 SOCKS 回复码只由 Connection 统一映射；Wire 不返回任何本地协议响应。

### 缓冲和进度

Wire 自行限制自身协议处理所需的内部缓冲和单次输出，在分配或扩容前校验长度、整数溢出及相应上限。已消费数据应及时释放或压缩，不能根据未校验的线上长度无限分配，也不能为等待完整业务报文而持续累积已解码数据。本版 UDP 编解码调用返回后不保留跨包数据。

调用者独立限制自身持有的输入、返回结果和 I/O 队列，并负责网络背压；Wire 接口不暴露内部缓冲计量，也不要求调用者将内部占用纳入跨层统一预算。Wire 无法在内部上限内继续处理合法协议输入时，必须明确失败；不能等待调用者通过查询内部占用解除限制。

每次同步方法必须有限完成。增量解析保存进度，已消费字节不在每次调用中重复扫描；空输入不能反复返回已经交付的业务字节。启动写入迟迟不能完成时，由 Connection 的绝对启动期限终止；业务传输中的读取停滞由所属入口期限处理。

### 关闭和生命周期

本版没有 Wire.close。TCP Connection 最终清理时停止新的编解码，关闭所属下游资源并释放 Wire 引用；需要立即释放缓冲时，必须清除仍捕获该实例的任务、回调和队列所有权。内存状态随最后一个引用释放，不以一个空 close 方法替代真实所有权清理。

独占 UDP Wire 随所属后端状态释放；共享且经验证可共享的 UDP Wire 由 Core 的运行周期持有，各 Connection 只释放自己的关联记录和引用。单个关联不能清空其他关联仍使用的共享状态。Connection 持有的结果和队列数据也必须在所属对象结束时释放。

所有 Channel 和正在等待的 future 由 Connection 处理。关闭后的迟到回调不得再次调用 Wire、写本地成功或创建新 Channel。restart 产生新 Core / 新运行周期，旧 Wire 不进入新周期。

## 验收

### 接口与消费路径

| ID | 场景 | 必须断言 |
|---|---|---|
| W-01 | 端点与超时 | 精确保留实际 SocketAddress 与毫秒字面量，getter 无 DNS / I/O |
| W-02 | 相同目标经三个 TCP 入口 | Wire 收到相同规范化 NetworkAddress；不收到原始入口头或本地凭据 |
| W-03 | 目标与节点不同 | 路由一次、选择一次，实际拨号与所选 Wire 一致，不把节点再次路由 |
| W-04 | TCP 无启动字节 | start 返回 nil；不等待节点首包即可进入本地成功流程 |
| W-05 | 接口方向与能力范围 | start 仅返回出站启动字节，decodeInbound 仅返回入站业务数据；需要多轮协商的实现不能声明满足本版契约 |
| W-06 | start 已返回但启动写未完成 | 本地成功尚未开始；写失败走唯一失败边界 |
| W-07 | 重复启动或提前编码 | 明确失败，不换目标、不污染另一实例 |
| W-08 | TCP 任意分片、逐字节及多个 Wire 协议编码单元合并输入 | 最终业务字节精确一致，无重复、遗漏或控制字节泄露 |
| W-09 | 本地成功回复前收到节点业务数据 | 启动写和本地成功屏障后才交付，数据不丢失或重排 |
| W-10 | Wire 协议编码单元尚未完整与合法空输入 | 空结果不是 EOF；不会提前关闭或忙循环 |
| W-11 | TCP 本地输入 EOF | 已排队启动字节与业务输出完整写完才关闭输出；无需额外编码 flush，反向继续可用 |
| W-12 | Wire 协议编码单元中途 EOF 与合法空业务流 | 缺失必需协议输入时截断失败；未开始可选协议单元不误报截断，不检查业务报文完整性 |
| W-13 | UDP 空载荷与完整数据报 | 空业务包可往返；不合包、不拆包、不跨包补齐 |
| W-14 | UDP 多目标与实际后端 | 逐包目标正确，回包使用登记的 Wire，节点不冒充业务来源 |
| W-15 | UDP 单个坏包 | 整包拒绝，后续独立合法包与其他关联不受污染 |
| W-16 | 缺少目标、端口 0、能力不符 | 当前操作失败，无默认端点或 DIRECT 回退 |
| W-17 | 替换两个行为不同的测试 Wire | HTTP / SOCKS 解析和回复代码不按实现名称分支 |
| W-18 | 原始错误传播 | Connection 收到原始错误；只有最高拥有边界决定本地回复和关闭 |
| W-19 | 长度溢出、超限、逐字节输入 | 内存与解析工作有界，先校验后分配 |
| W-20 | Connection 清理、取消与迟到完成竞争 | 释放所属引用与队列数据，迟到回调不再调用 Wire、不重复回复 |
| W-21 | 并发连接与 UDP 共享条件 | TCP 状态隔离；UDP 共享不串客户端或端点，独占实例串行调用 |
| W-22 | HTTP 普通请求与 CONNECT | 前者发送源站请求并处理业务响应；后者本地成功后进入隧道 |
| W-23 | restart 与运行周期 | 旧 Wire 清理，新周期不继承旧缓冲、状态或已完成通知 |
| W-24 | 接口最小集合 | 仅一套 Wire；端点 getter 明确返回节点；Core / Connection 不依赖额外传输开关 |
| W-25 | UDP 非必需生命周期调用 | start 返回 nil 且不固定逐包目标；finishInbound 为空操作，不污染后续包或共享关联 |
| W-26 | 字节流交付与缓冲职责 | 已解码并验证的业务数据立即返回，不等待完整业务报文；Wire 自行限制协议缓冲，调用者独立限制自身队列；UDP 不保留跨包数据 |

测试先使用可控 Wire 和 Channel 验证集成契约，再由各具体实现单独验收其编解码及互操作。测试必须经过真实 Core / Connection 所有权路径，不为方便测试添加生产专用开关。成功证据区分静态检查、定向测试、包级测试和真实网络集成。

### 当前接口与迁移边界

[Wire.swift](../Sources/Wire/Wire.swift) 是当前抽象入口，[WireTests.swift](../Tests/Wire/WireTests.swift) 是已有公共端点与超时测试入口。当前代码仍名为 getTargetAddress；start 返回 Data?，decodeInbound 返回 InboundData，与本规范的数据返回类型一致。当前尚无 finishInbound，重复启动及 EOF 等行为仍需对照本规范迁移；不能因返回类型一致就宣称契约已全部实现。

本版删除 0.2.0 草案中的双向结果封装和 ready 字段，恢复按方向返回数据的接口，并移除多轮协商及解码生成反向控制输出的要求。实现不需要引入新的结果类型、状态 getter 或回调来替代它们。

迁移时同步更新 Core、HTTP/SOCKS Connection 与所有实现的端点名称和 EOF 消费路径。Connection 通过 start 成功返回及可选启动字节的写入完成判定下游就绪；解码结果只用于业务交付。本规范不授权保留一套旧兼容接口或为每个入口增加特例。

迁移必须保持模型构造、Channel 所有权与错误路由边界，完成 W-01～W-26 对应验收后，才能声明抽象接口及其消费路径一致。
