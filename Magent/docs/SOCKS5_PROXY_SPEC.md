---
desc: "SOCKS5 入口的 TCP CONNECT、UDP ASSOCIATE、抽象 Wire 集成、地址与 DNS 边界及验收标准。"
version: "1.1.0"
updated_at: "2026-09-24"
status: "草案"
references_checked_at: "2026-09-21"
---

# 本地 SOCKS5 代理服务完整规格说明书

本文规定本地入口协议与抽象 Wire 的协作契约。入口只处理自己的报文、目标和本地响应；具体出站协议的线上格式、认证、加密、节点部署及配置属于 Wire 和节点模型，不在本文定义，也不能由入口协议推断。

抽象接口统一由 [Wire 规范](WIRES_SPEC.md) 定义。业务目标使用 [模型规范](MODELS_SPEC.md) 中的 `NetworkAddress`；节点引用、实际端点和规则由 Core 按同一模型契约处理。本文的逻辑流程和示例不新增模型构造入口或具体 Wire 类型。协议字段限制仍由入口负责。

<a id="contents"></a>
## 目录

| 章节 | 内容 |
|---|---|
| [01](#s01) | 核心结论与规范性用语 |
| [02](#s02) | 功能范围、边界与兼容性声明 |
| [03](#s03) | 总体架构与四类地址 |
| [04](#s04) | 核心数据模型 |
| [05](#s05) | TCP 入站：协商、认证、请求与回复 |
| [06](#s06) | 增量解析器与状态机 |
| [07](#s07) | 地址规范化与输入校验 |
| [08](#s08) | 分流规则与决策算法 |
| [09](#s09) | DNS 职责与解析时机 |
| [10](#s10) | TCP DIRECT 完整链路 |
| [11](#s11) | TCP PROXY 与抽象 Wire |
| [12](#s12) | TCP 双向转发、背压与半关闭 |
| [13](#s13) | UDP ASSOCIATE 控制连接 |
| [14](#s14) | SOCKS5 UDP 数据报解析与编码 |
| [15](#s15) | UDP 分流、直连、代理与回包 |
| [16](#s16) | UDP 与 DNS 的关系 |
| [17](#s17) | Wire 能力与安全边界 |
| [18](#s18) | 错误码与失败处理 |
| [19](#s19) | 超时、资源限制与生命周期 |
| [20](#s20) | 完整配置示例与字段语义 |
| [21](#s21) | 安全与隐私约束 |
| [22](#s22) | 日志、指标与故障定位 |
| [23](#s23) | Swift 模块划分与接口契约 |
| [24](#s24) | 端到端实例 |
| [25](#s25) | 字节级测试向量 |
| [26](#s26) | 测试矩阵与验收条件 |
| [27](#s27) | 实施顺序与需求追踪 |
| [28](#s28) | 设计决策汇总与参考资料 |

---

<a id="s01"></a>
## 01. 核心结论与规范性用语

### 1.1 这个服务到底负责什么

本服务接收客户端主动发来的 SOCKS5 请求，从协议头取得目标地址与端口，决定使用 `DIRECT`、`PROXY` 或 `REJECT`，然后建立相应链路并转发数据。

```text
客户端提交的目标
    ├── 域名：example.com:443
    │     ├── 命中 PROXY → 保留域名类型，交给上游代理处理
    │     ├── 命中 DIRECT → 本服务调用系统解析器，再连接目标 IP
    │     └── 命中 REJECT → 拒绝，不解析，不连接
    │
    └── IP：203.0.113.10:443 或 [2001:db8::10]:443
          ├── 命中 PROXY → 把 IP 和端口交给上游
          ├── 命中 DIRECT → 本服务直接连接该 IP
          └── 命中 REJECT → 拒绝
```

TCP 目标来自 `CONNECT` 请求；UDP 目标来自**每一个 SOCKS5 UDP 数据报的头部**。`UDP ASSOCIATE` 控制请求本身不是“连接某个 UDP 目标”的请求。相应协议字段依据 RFC 1928；本文件另外定义严格的产品行为。[S1](#ref-s1)

### 1.2 本版本固定的设计原则

| ID | 原则 |
|---|---|
| INV-01 | 先解析协议得到结构化目标，再做分流，最后才建立出站连接。 |
| INV-02 | 规则引擎是纯计算组件；不查询 DNS，不拨号，不探测目标。 |
| INV-03 | 规则按配置顺序首条匹配生效；默认动作是 `DIRECT`。不存在隐含的“域名规则永远比 IP 规则优先”。 |
| INV-04 | 域名目标命中 `PROXY` 时，本服务不解析业务目标域名；上游收到域名，而不是本地解析出的 IP。 |
| INV-05 | 域名目标命中 `DIRECT` 时，本服务按需调用系统解析接口，不实现独立 DNS 服务。 |
| INV-06 | 不监听 DNS 53 端口，不提供 Fake-IP，不解析应用载荷中的 DNS QNAME 来分流。 |
| INV-07 | 代理节点地址、业务目标地址、UDP 中继地址和客户端地址必须分开建模。 |
| INV-08 | 代理失败不自动改走直连；建立后的 TCP 流和 UDP 报文不自动重放。 |
| INV-09 | TCP 是字节流；UDP 保留数据报边界。两者不能共用一个“收到数据就拼接”的解析逻辑。 |
| INV-10 | 所有队列、缓冲、解析任务、会话和套接字都必须有上限。 |
| INV-11 | 一个 UDP 关联允许同时访问多个目标，这些目标可以分别走直连、不同代理或被拒绝。 |
| INV-12 | 下游 UDP 关联必须与创建它的 TCP 控制连接共同结束。 |

其中 INV-12 是协议生命周期要求；不支持 SOCKS 层 UDP 分片时丢弃 `FRAG != 0` 也是协议明确允许并要求的行为。[S1](#ref-s1)

### 1.3 规范性用语

`必须 / MUST` 表示本 SPEC 的验收要求；`禁止 / MUST NOT` 表示不能出现的行为；`建议 / SHOULD` 表示可有经过记录的替代实现；`可选 / MAY` 表示未实现也不影响基础版本验收。

本文件中具体超时、容量、规则格式、认证策略、源端口绑定和上游隔离方式都是**本产品的设计选择**，不是 RFC 给出的统一默认值。

---

<a id="s02"></a>
## 02. 功能范围、边界与兼容性声明

### 2.1 基础版本能力

| 能力 | 本版本要求 | 说明 |
|---|---|---|
| SOCKS5 TCP `CONNECT` | 必须实现 | `CMD=0x01` |
| SOCKS5 `UDP ASSOCIATE` | 必须实现，可配置关闭 | `CMD=0x03`；关闭时返回不支持命令 |
| IPv4 / IPv6 / 域名目标 | 必须实现 | TCP 目标与 UDP 数据报目标均支持 |
| 无认证 | 必须实现 | 默认仅允许回环地址监听 |
| 用户名/密码认证 | 必须实现，可配置启用 | 使用 RFC 1929 子协商 |
| `DIRECT / PROXY / REJECT` | 必须实现 | TCP 按连接；UDP 按逻辑流 |
| TCP Wire 集成 | 必须 | 独立启动与编解码状态，不依赖具体节点协议 |
| UDP Wire 集成 | 必须 | 逐包传递目标与 DATA，后端端点和解码器归属明确 |
| 配置校验、日志、资源预算、优雅退出 | 必须实现 | 不能只实现协议 happy path |

SOCKS5 的地址类型和命令编码见 RFC 1928；用户名/密码子协商见 RFC 1929。[S1](#ref-s1) [S2](#ref-s2)

### 2.2 明确不实现的能力

本版本不实现 `BIND`、GSSAPI、SOCKS4/4a 入站、HTTP 代理入站、TUN、透明代理、NetworkExtension 流量接管、PAC 执行、进程识别、HTTP Host / TLS SNI 嗅探、UDP-over-TCP 私有扩展、SOCKS UDP 分片重组以及独立 DNS 服务。

本服务不因为监听了 SOCKS5 端口就自动接管所有应用流量。客户端必须实际使用 SOCKS5；不会使用 SOCKS5 UDP 的应用，也不会因为设置了一个 TCP SOCKS 代理而自动获得 UDP 代理能力。

### 2.3 兼容性声明

本产品实现的是**明确约束的 SOCKS5 功能集**，不能宣称“完整实现 RFC 1928 的全部合规要求”：RFC 1928 对 GSSAPI 有额外的实现要求，而本产品不实现 GSSAPI。[S1](#ref-s1)

另外，本 SPEC 对域名语法、UDP 客户端源端口、目标安全策略和后端端点归属采用更严格的产品约束。它们必须作为可见限制记录，不能在实现中偷偷放宽，也不能被包装成 SOCKS5 标准唯一允许的做法。

---

<a id="s03"></a>
## 03. 总体架构与四类地址

### 3.1 总体结构

```text
本地 SOCKS5 TCP → Socks5Connection → NetworkAddress → Core
本地 SOCKS5 UDP → 来源校验与数据报解码 → 每包目标 → Core
Core → DIRECT 目标 Channel，或 PROXY Wire + 节点 Channel
下游响应 → DIRECT 业务数据，或 Wire 解码 → 本地 SOCKS5 回复/UDP 封装
```

Connection 拥有本地状态、下游 Channel 和 UDP 关联资源。Core 路由与选择 Wire。Wire 只处理所属出站协议的启动和编解码，不解析本地方法协商或拥有本地控制连接。

### 3.2 四类地址必须区分

| 地址 | 模型与用途 |
|---|---|
| 客户端来源 | 实际 SocketAddress；用于本地认证、来源固定和回包 |
| 业务目标 | NetworkAddress；来自 CONNECT 或每个 UDP 数据报 |
| 节点端点 | Wire 提供的实际 SocketAddress；用于发送编码后的数据 |
| 本地 UDP 中继端点 | 本地关联绑定的 SocketAddress；编码到本地 ASSOCIATE 回复 |

本地中继端点不等于节点端点。具体 Wire 的远端控制信息不能直接作为本地 BND 字段或业务来源；相应元数据必须按明确的语义交给 Connection。

### 3.3 DIRECT 不是把控制权退回客户端

客户端已经把连接交给本服务后，`DIRECT` 的含义是：**由本服务自行创建到目标的连接，然后继续转发客户端数据**。SOCKS5 没有一个通用的 `DIRECT` 回复能让应用自动改成原生直连。

同样，`PROXY` 不是将客户端原始 SOCKS5 请求不加处理地写到任意代理端口，而是调用对应出站协议适配器。

---

<a id="s04"></a>
## 04. 核心数据模型

### 4.1 目标地址模型

以下是逻辑模型，不是承诺可直接编译的完整 Swift 定义：

```text
Address =
    IPv4(bytes[4])
  | IPv6(bytes[16])
  | Domain {
        originalASCII: bytes,
        matchName: string,
        forwardName: string
    }

TargetEndpoint {
    address: Address,
    port: UInt16               // 业务目标范围 1..65535
}

RequestContext {
    sessionID,
    clientTCPPeer,
    listenerID,
    authenticatedPrincipal?,
    command,
    transport: TCP | UDP,
    target?,                   // UDP ASSOCIATE 控制请求没有业务 target
    configSnapshotID
}
```

不能只用一个未经分类的 `host: String` 贯穿系统，否则容易发生数字 IP 被再次查询 DNS、IPv6 冒号和端口混淆、域名来源丢失等错误。

### 4.2 分流结果

```text
RouteDecision {
    action: DIRECT | PROXY | REJECT,
    outboundID?,               // 仅 PROXY 必须有值
    matchedRuleID?,
    reason: MATCHED_RULE | DEFAULT_RULE | SECURITY_REJECTION,
    configSnapshotID
}
```

不得使用 `nil outbound` 同时表达“直连”“尚未选代理”和“代理选择失败”。

### 4.3 DNS 结果

```text
ResolutionResult {
    addresses: [NumericIPAddress],
    purpose: TARGET_DIRECT,
    source: SYSTEM,
    ttl: Optional<Duration>     // 系统接口未提供时必须是 unknown
}
```

一个逻辑解析调用可能由系统内部完成多个 A / AAAA 请求或直接命中系统缓存。因此“逻辑解析次数为 1”不等于“网络上只有一个 DNS 包”。

### 4.4 UDP 关联与流

```text
UDPAssociation {
    associationID,
    ownerTCPSessionID,
    expectedClientIP,
    expectedClientPort?,
    pinnedClientEndpoint?,
    localRelaySocket,
    advertisedRelayEndpoint,
    configSnapshotID,
    flows: Map<UDPFlowKey, UDPFlow>
}

UDPFlowKey {
    associationID,
    normalizedTarget,
    routeAction,
    outboundID?,
    configSnapshotID
}

UDPFlow {
    state: OPENING | READY | FAILED | CLOSED,
    directRemoteSocket? OR upstreamUDPChannel?,
    selectedDirectIP?,
    pendingDatagrams,
    bytesInFlight,
    lastActivity,
    failureCooldownUntil?
}
```

逻辑流用于保持 UDP 地址映射、出口和资源归属，不代表 UDP 建立了 TCP 那样的可靠连接。

---

<a id="s05"></a>
## 05. TCP 入站：协商、认证、请求与回复

本节的线协议布局依据 RFC 1928 和 RFC 1929；状态推进、输入限制与错误处置是本产品规定。[S1](#ref-s1) [S2](#ref-s2)

### 5.1 阶段一：客户端方法列表

```text
VER(1) | NMETHODS(1) | METHODS(NMETHODS)
```

| 字段 | 要求 |
|---|---|
| `VER` | 必须为 `0x05` |
| `NMETHODS` | `1..255`；本版本拒绝 0 |
| `METHODS` | 必须完整读取指定数量；不得只检查第一个方法 |

常见请求：

```text
05 01 00       # 仅支持无认证
05 02 00 02    # 支持无认证和用户名/密码
```

完整消息长度为 `2 + NMETHODS`，最大 257 字节。

服务器回复：

```text
05 00          # 选择无认证
05 02          # 选择用户名/密码
05 FF          # 没有可接受的方法；随后关闭
```

方法选择必须同时满足服务配置和客户端声明。不能选择客户端没有提供的方法。

### 5.2 本地认证策略

`auth.mode=none` 时只选择 `0x00`；客户端未提供 `0x00` 则返回 `05 FF`。

`auth.mode=username_password` 时只选择 `0x02`；即使客户端还提供 `0x00`，也不能降级到无认证。客户端未提供 `0x02` 则返回 `05 FF`。

`0x01` GSSAPI 和其他方法不在本产品支持范围。未知方法出现在客户端列表里并不导致整条列表无效，只要存在一个符合服务策略的方法即可。

### 5.3 阶段二：用户名/密码子协商

```text
VER(1) | ULEN(1) | UNAME(ULEN) | PLEN(1) | PASSWD(PLEN)
```

子协商的 `VER` 必须为 **`0x01`，不是 `0x05`**。用户名、密码长度分别为 `1..255` 字节；总长度为 `3 + ULEN + PLEN`，最大 513 字节。

服务器回复：

```text
01 00          # 认证成功
01 01          # 本服务统一使用的认证失败状态；发送后关闭
```

RFC 1929 只把 `STATUS=0` 定义为成功，其他值表示失败；本产品固定使用 `0x01`，不向客户端区分“用户不存在”和“密码错误”。此认证传输密码本身，不提供加密保护。[S2](#ref-s2)

认证实现要求：

- 线协议按字节读写；配置层统一编码为 UTF-8，长度按 UTF-8 字节数计算。
- 不对用户名或密码执行大小写转换、trim 或 Unicode 归一化。
- 不使用以 NUL 结尾的 C 字符串比较截断后的内容。
- 使用受保护的凭据存储或验证器；限流及验证任务队列必须有界。
- 认证失败后不再解析、路由或连接业务目标。

### 5.4 阶段三：请求头

```text
VER(1) | CMD(1) | RSV(1) | ATYP(1) | DST.ADDR(variable) | DST.PORT(2)
```

| 字段 | 取值 |
|---|---|
| `VER` | `0x05` |
| `CMD` | `0x01 CONNECT`、`0x02 BIND`、`0x03 UDP ASSOCIATE` |
| `RSV` | `0x00` |
| `ATYP` | `0x01 IPv4`、`0x03 DOMAIN`、`0x04 IPv6` |
| `DST.PORT` | 无符号 16 位网络字节序 |

地址编码：

| ATYP | 地址部分 | 请求总长度 |
|---|---|---:|
| `01` | 4 字节 IPv4 | 10 |
| `03` | 1 字节域名长度 `L` + `L` 字节域名 | `7 + L` |
| `04` | 16 字节 IPv6 | 22 |

域名不是 NUL 结尾字符串。IPv6 是 16 个原始字节，不是包含冒号的文本。

网络字节序示例：

```text
01 BB → 443
00 35 → 53
1F 90 → 8080
```

本版本在读取固定头并确认版本及保留字段合法后，遇到 `BIND` 或未知 `CMD` 可以立即回复 `REP=0x07`，不必无限等待不支持命令的剩余请求体。

### 5.5 命令对应的目标语义

`CONNECT` 中的 `DST.ADDR:DST.PORT` 是业务目标，端口必须非零。

`UDP ASSOCIATE` 中的这两个字段是**客户端预计用来发送 UDP 的源地址和源端口提示**；全零表示客户端暂时不知道。它们不能进入业务分流引擎。业务目标稍后出现在每个 UDP 数据报中。[S1](#ref-s1)

### 5.6 回复格式

```text
VER(1) | REP(1) | RSV(1) | ATYP(1) | BND.ADDR(variable) | BND.PORT(2)
```

`VER=0x05`，`RSV=0x00`。回复地址编码和请求地址编码相同，不能固定读取 10 字节而忽略 IPv6 或域名回复。

| 场景 | `BND.ADDR:BND.PORT` 的产品语义 |
|---|---|
| DIRECT CONNECT 成功 | 本服务连接目标的出站 socket 实际本地绑定地址和端口 |
| PROXY CONNECT 成功 | 本版统一回复 `0.0.0.0:0`；Wire 抽象不提供目标侧绑定元数据，不能拿节点端点或本地监听地址伪造 |
| UDP ASSOCIATE 成功 | 客户端实际应该发送 SOCKS5 UDP 数据报的本地中继地址和端口 |
| 请求失败 | 本产品统一使用 `0.0.0.0:0`，`ATYP=01` |

CONNECT 的绑定端点不是目标地址，也不应无条件填本服务监听的 `127.0.0.1:1080`。UDP 回复更不能向客户端发布不可用的 `0.0.0.0:0`。协议中两类 BND 的职责不同。[S1](#ref-s1)

### 5.7 成功回复的发送时机

DIRECT 等目标 TCP 建立成功；PROXY 等第 11 节规定的 Wire 就绪条件；UDP ASSOCIATE 等本地中继绑定且关联可用。三者不能互相替代。

在此之前不发送下游成功，不转发客户端业务载荷。成功回复只表明对应 DIRECT、Wire 或本地 UDP 关联就绪条件满足，不证明 HTTP、TLS、数据库登录或最终应用请求已经成功。

---

<a id="s06"></a>
## 06. 增量解析器与状态机

### 6.1 TCP 解析器返回契约

```text
decode(buffer, phase) ->
    NeedMore(minimumAdditionalBytes)
  | Complete(message, consumedBytes)
  | Invalid(protocolError)
```

解析器必须是纯函数或纯状态对象；不调用系统 DNS、不读写 socket、不执行业务路由。

`Complete` 只能消费当前消息的字节。调用方将剩余字节保留下来，按状态推进后继续处理。TCP 的一次接收可能包含半条消息，也可能同时包含协商、认证、请求和提前发送的业务数据。

### 6.2 消息边界处理

建议使用带读索引的缓冲区，不要每消费一个字节就从 `Data` 头部移除造成反复拷贝。

对域名请求，先有 4 字节固定头才能识别地址类型，再有第 5 字节才能知道域名长度；读取到 `7 + L` 字节后才构成完整请求。认证请求需要先读取 `ULEN`，再定位 `PLEN`。

每次读取前先申请预算。网络适配层应限制单次接收的最大字节数，不能先无限接收，再在解析结束后检查上限。

### 6.3 入站状态机

```text
ACCEPTED
   ↓
READ_GREETING → WRITE_METHOD_SELECTION
   ├── 无可用方法 → CLOSING
   ├── 无认证 ───────────────────────┐
   └── 用户名密码 → READ_AUTH → WRITE_AUTH_RESULT
                         ├── 失败 → CLOSING
                         └───────────┤
                                     ↓
                                READ_REQUEST
                 ┌───────────────────┼─────────────────────┐
                 │                   │                     │
              CONNECT           UDP ASSOCIATE         不支持/非法
                 │                   │                     │
           NORMALIZE_TARGET     CREATE_UDP_RELAY      WRITE_FAILURE
                 │                   │                     │
             ROUTE_AND_GUARD         │                  CLOSING
                 │                   │
             OPEN_OUTBOUND      WRITE_UDP_SUCCESS
                 │                   │
          WRITE_CONNECT_SUCCESS  UDP_ASSOCIATED
                 │                   │
              TCP_RELAY       控制 TCP 只维持生命周期
                 │                   │
              CLOSING ←──────────────┘
                 ↓
               CLOSED
```

所有写操作完成后才移交下一阶段的写权限。即使客户端流水线发送数据，本服务也必须按“方法选择 → 认证结果 → 请求结果”的顺序回复，不能让不同任务的写入互相穿插。

### 6.4 提前发送与粘包

本服务容忍有限的提前发送：如果请求后已经收到业务数据，先放入 `earlyDataBuffer`；等待出站准备好并完整写出下游成功回复后，再按原顺序转发。

`earlyDataBuffer` 默认最大 64 KiB，计入全局预算。填满后暂停从客户端继续读，不能无限缓存。握手消息自身仍按其独立长度上限校验。

如果 Wire 在同一结果中返回 ready=true 和首段业务数据，Connection 必须保留业务数据，待必要控制输出与本地成功回复发送完成后，再交给客户端。

### 6.5 EOF、取消与失败

握手未完整时收到 EOF：清理连接，不继续等待，不启动出站。已经收到完整 CONNECT 请求和有限 early data 后出现客户端读方向 EOF：可以完成出站建立，按顺序发送已收数据，再执行出站写半关闭，仍保留回包方向。

`UDP ASSOCIATE` 控制连接在请求后不接受业务字节。本产品将其收到的额外 TCP 数据视为协议误用并关闭整个关联。控制连接 EOF、RST、取消或超时均销毁关联。

正常 TCP relay 阶段的数据不再当作 SOCKS5 消息解析。不存在“读到 `05` 就重新握手”的逻辑。

### 6.6 Wire 状态与本地解析器独立

本地 SOCKS5 方法协商、认证和请求状态仅服务于客户端。Wire 管理自己的启动与编解码状态；Connection 不再解析第二套出站协商报文，也不把本地认证字段交给 Wire 作为节点凭据。

---

<a id="s07"></a>
## 07. 地址规范化与输入校验

### 7.1 基本原则

规范化只做语法处理，不访问网络。用于匹配的名称和向上游发送的名称必须保留明确的关系，不能由不同组件各自执行一套不一致的处理。

### 7.2 IP 处理

IPv4 / IPv6 入站按原始字节保存。配置中的 IP 只接受严格数值格式；禁止将十进制整数、十六进制、八进制或省略字段的 IPv4 表示交给系统的宽松名称解析器。

IPv4-mapped IPv6 地址，如 `::ffff:127.0.0.1`，在安全检查、CIDR 匹配、客户端源地址比较以及自回环检查之前规范化为等价 IPv4。这样不能借助映射形式绕过 IPv4 规则。原始类型可作为诊断字段保留。

SOCKS5 的 IPv6 地址字段没有单独的 scope ID。本版本拒绝需要链路作用域才能正确寻址的 link-local 业务目标，也不接受域名字符串中的 `%en0` 等地址文本扩展。

### 7.3 域名处理

SOCKS5 域名字段先按 `L` 完整读取；然后执行本产品的主机名策略：

| 项目 | 要求 |
|---|---|
| 空串 | 拒绝 |
| 线协议编码 | 接受 ASCII 主机名和有效 IDNA A-label；不直接接受原始 UTF-8 域名 |
| 大小写 | ASCII 小写化后用于匹配和转发 |
| 末尾根点 | 允许一个；匹配时移除，转发时保留是否显式提供根点 |
| 标签长度 | 每个标签 1..63 字节 |
| 规范化总长度 | 去掉末尾根点后不超过 253 字节 |
| 字符 | 主机名标签限字母、数字、连字符；标签不能以连字符开头或结尾 |
| 危险分隔符 | NUL、空白、控制字符、`/`、`\\`、`@`、`:`、`[`、`]`、`%` 均拒绝 |
| 下划线标签 | 本产品的业务主机名入口不接受；不是对所有 DNS 记录名语法的声明 |
| 单标签名称 | 本版本允许，但 DIRECT 按绝对名称解析，不使用隐式搜索后缀 |

DNS 名称长度与 IDNA 的 A-label 概念见相应规范；本产品的主机名字符策略比一般 DNS 名称的表达能力更窄。[S3](#ref-s3) [S4](#ref-s4)

UI / 配置导入层可以把 Unicode 域名转换成 ASCII A-label；必须使用明确版本、具备测试向量的 IDNA 实现，不自行编写 Punycode 算法。协议核心只接收转换并校验后的 ASCII 形式。

### 7.4 伪装成域名的数值地址

当 `ATYP=03` 的内容其实是严格、标准的 IPv4 文本，例如 `127.0.0.1`，本服务将其转换为 `IPv4` 目标，并应用 IP 安全策略及 IP 规则；向上游也按 IPv4 编码，不触发 DNS。

含冒号的 IPv6 文本不应装入域名字段，本版本拒绝，客户端必须使用 `ATYP=04`。纯数字整数、`0x` 风格地址以及仅由数字和点组成但不符合严格 IPv4 语法的文本也拒绝，避免进入系统解析器被解释成其他地址。

这一处理是产品防绕过策略，不能宣称所有 SOCKS5 服务都必须如此处理。

### 7.5 域名匹配示例

```text
输入：API.Example.COM.
matchName：api.example.com
forwardName：api.example.com.
```

`DOMAIN-SUFFIX=example.com` 匹配 `example.com` 和 `a.example.com`，不匹配 `notexample.com`。不得使用未经边界判断的普通 `endsWith("example.com")`。

匹配逻辑：

```text
host == suffix OR host.endsWith("." + suffix)
```

---

<a id="s08"></a>
## 08. 分流规则与决策算法

### 8.1 支持的匹配条件

每条规则的 `match` 对象支持下列条件；同一条规则内多个条件按 **AND** 组合。数组字段内部按 **OR** 组合。

| 配置字段 | 匹配对象 | 约束 |
|---|---|---|
| `domain` | 规范化域名精确匹配 | 只适用于 Domain |
| `domain_suffix` | 域名及其子域 | 只适用于 Domain |
| `ip_cidr` | 数值目标地址 | 只适用于 IP；不为域名查询 DNS |
| `ports` | 目标端口 | 整数或包含端点的范围，如 `443`、`"8000-8100"` |
| `transport` | `tcp` / `udp` | 指业务传输，不是控制连接的传输类型 |

同一规则不得同时声明 `domain`、`domain_suffix` 和 `ip_cidr` 中的多个，以免形成无意义的条件组合。空 `match` 对象不允许；无条件动作统一放在 `routing.default`。

### 8.2 动作

```text
{ "type": "DIRECT" }
{ "type": "PROXY", "outbound": "proxy-main" }
{ "type": "REJECT" }
```

`PROXY` 必须引用有效的出站 ID。出站不存在、禁用或者不支持当前传输，不得当成规则未命中并继续向下找；这代表配置错误或当前请求失败。

### 8.3 完整决策过程

```text
1. 取得当前会话绑定的不可变配置快照。
2. 验证并规范化目标地址、端口、传输类型。
3. 执行无需 DNS 的强制安全检查；被禁止则拒绝。
4. 按数组顺序检查每条规则。
5. 第一条全部条件匹配的规则决定动作；没有匹配则使用 default。
6. 校验动作依赖与出站能力。
7. DIRECT 域名目标：交给 Resolver 和 DirectConnector。
8. PROXY：交给选定 OutboundConnector，保留地址类型。
9. REJECT：不创建业务出站，不发起业务目标 DNS。
```

DIRECT 的解析结果还要执行**数值地址安全检查**。该检查能拒绝危险目标，但不能偷偷把 `DIRECT` 改成 `PROXY`。

### 8.4 不做隐藏的二次分流

例：`some.example` 没命中域名规则，默认 DIRECT；系统解析出一个恰好落在某条 PROXY IP-CIDR 规则里的地址。

本版本依然保持 DIRECT，除非解析结果被强制安全策略拒绝。IP 规则只检查客户端交来的数值目标；它不参与域名解析后的第二轮路线选择。

这样可以保证“分流不触发 DNS”和“同一请求不会在解析之后换出口”。需要解析后按 IP 分类的产品，应另写版本化扩展，而不是在此规则引擎里加一次隐含查询。

### 8.5 客户端只提供 IP 时

若客户端先自行解析域名，再提交 `ATYP=01/04`，本服务只能基于 IP、端口和传输类型判断。域名规则不生效，不执行 PTR 反查，也不从后续 TLS / HTTP 数据里猜测原始域名。

相同 IP 可能承载多个域名；不能把“曾经某个域名解析到了这个 IP”当成可靠的当前业务目标身份。

### 8.6 规则缓存

基础版本可以不做路由缓存。实现缓存时，键至少包含：

```text
configSnapshotID + transport + addressType + normalizedAddress + targetPort
```

缓存只保存规则决策，不保存“域名一定等价于某个 IP”的推断。配置快照变化后，旧缓存不能服务新会话。

UDP 流本身固定路由；每个新目标建立自己的流。一个关联中不能用第一个 UDP 目标的决定覆盖之后所有目标。

---

<a id="s09"></a>
## 09. DNS 职责与解析时机

### 9.1 三种容易混淆的行为

| 行为 | 本产品是否提供 | 含义 |
|---|---|---|
| 目标地址解析 | 按需提供内部能力 | DIRECT 域名转成目标 IP |
| DNS 报文转发 | 作为普通 TCP / UDP 载荷转发 | 客户端通过代理访问某个 DNS 服务器 |
| 独立 DNS 服务 | 不提供 | 不监听 53，不接管系统 DNS，不实现 DNS 分流服务器 |

“不需要独立 DNS 服务”不等于“代码里完全不需要 Resolver”。例如直连域名和代理节点本身使用域名时，仍需要系统解析能力。

### 9.2 解析矩阵

| 场景 | 本服务 Target DNS | 其他解析 | 发给下一跳的目标 |
|---|---|---|---|
| TCP / UDP 数值 IP DIRECT | 不需要 | 无 | 数值 IP |
| TCP / UDP 域名 DIRECT | 需要 | 无 | 选定并校验后的数值 IP |
| TCP / UDP 数值 IP PROXY | 不需要 | 节点配置装配可能需要解析 | 数值 IP |
| TCP / UDP 域名 PROXY | 禁止 | 节点配置装配可能需要解析 | 域名 |
| REJECT | 禁止 | 不得因该请求新建节点连接 | 无 |
| UDP 载荷内包含 DNS 查询 | 不因载荷而解析 | 按外层目标正常处理 | 原封不动的 DNS 载荷 |

### 9.3 系统解析器契约

```text
resolveAbsolute(hostname, purpose, deadline) -> numeric address candidates
```

DIRECT 解析必须使用绝对名称语义，避免额外搜索后缀改变用户提交的目标。适配层可以通过传递显式根点名称等经过平台验证的方式实现；不能先查一个名称，再让拨号 API 用另一个名称解析。

DNS 结果只产生地址候选，不产生 `RouteDecision`。最多接受配置规定的候选数量，去重并检查每个候选；随后只向通过校验的数值地址拨号。

若系统接口拿不到 DNS TTL，本服务不捏造 TTL。本版本默认只使用系统缓存，并可合并同时进行的相同查询；不再维护一个假装服从真实 DNS TTL 的独立结果缓存。

### 9.4 代理域名不能先本地解析“试试看”

以下行为禁止：

```text
收到 example.com → 先本地查询 IP → 判断能不能直连 → 不行再代理
```

对已经决定 PROXY 的域名，入口将 NetworkAddress 交给 Wire，不自行构造具体节点的地址头；Wire 自身的名称处理按其契约验收。

本 SPEC 的可验证保证是：入口的 Resolver 不用于解析 PROXY 业务目标。客户端、配置装配层、Wire 与其他进程的 DNS 行为分别观察。

### 9.5 超时后的真实资源

系统解析接口可能不能被立即中断。调用方超时后必须丢弃迟到结果、不再为已结束会话拨号；但真实解析任务占用的工作槽必须到它真正退出时才释放。

禁止“超时就释放许可，但原阻塞任务继续运行”的假限流。解析工作池、等待队列和截止时间都必须有界；全部解析工作槽被卡住时应明确失败，而不是无限创建新线程。

### 9.6 节点端点与配置装配

节点配置中的名称与请求中的业务域名属于不同边界。节点名称解析在配置装配层完成，入口只消费 Wire 提供的已校验 SocketAddress；Wire getter 不访问 DNS。

实际节点端点不再经过业务规则引擎，避免把节点连接再次送回当前代理。节点装配、入口目标解析与客户端自己的解析须分别记录和验收。

---
<a id="s10"></a>
## 10. TCP DIRECT 完整链路

### 10.1 执行流程

```text
CONNECT request
    ↓
Target 规范化 + 安全检查 + RouteDecision=DIRECT
    ↓
是数值 IP？ ── 是 → 使用该 IP
    │
    否 → 系统解析绝对域名 → 去重 → 候选上限 → 安全过滤
    ↓
对获准的数值候选建立 TCP 连接
    ↓
取得实际本地绑定端点
    ↓
写出完整 SOCKS5 成功回复
    ↓
交付 early data → 启动双向 relay
```

### 10.2 多地址与 IPv4 / IPv6

本版本规定：最多保留 8 个候选，按系统返回的优先顺序保留；可采用有界的错峰并发连接，默认最多同时尝试 2 个候选，第二个在第一个未完成 250 ms 后启动。失败后可用同一预算补充后续候选。

这是本产品的有界连接竞速策略，不宣称完整实现某个地址选择或 Happy Eyeballs 标准。任何候选成功后，必须取消其他尝试并关闭迟到的成功连接；整个过程共享出站总截止时间。

已经把业务载荷写给某个连接后，不再重试其他地址。数值目标只有一个候选，不因为连接失败改查 PTR 或换成其他域名。

### 10.3 防止二次解析

错误模式：

```text
Resolver 检查 example.com → 得到安全 IP A
Dialer 再以 example.com 拨号 → 第二次解析到 IP B
```

正确模式：

```text
Resolver 得到 [A, B]
TargetGuard 筛选出 [A]
Dialer 只接收并连接数值 A
```

网络库选择必须满足此契约。不能因为某个高级 API 方便，就让它绕过已经完成的候选校验。

### 10.4 失败与结果

解析失败、候选全部被禁止、网络不可达、目标拒绝连接和超时必须保留不同内部原因，按第 18 节映射为 SOCKS5 回复。

DIRECT 成功后，目标最先发送的数据同样需要转发。不能要求必须先收到客户端 HTTP 请求才启动回包方向，否则会破坏服务器先发的协议。

---

<a id="s11"></a>
## 11. TCP PROXY 与抽象 Wire

### Wire 与连接的职责

Wire 的接口、状态和验收以 [Wire 规范](WIRES_SPEC.md) 为准。本文只补充本地入口如何使用它：

| 所有者 | 契约 |
|---|---|
| Connection | 解析入口、构造目标、生成本地回复；持有并读写下游 Channel，负责背压、EOF、取消和清理 |
| Core | 对业务目标完成路由；PROXY 按节点引用选择匹配传输种类的 Wire；创建下游 Channel |
| Wire | 提供实际节点端点与毫秒超时，管理启动、控制状态及编解码；不持有 Channel，不生成本地协议回复 |

DIRECT 使用目标端点。PROXY 连接 `getEndpoint()` 的实际端点，采用 `getTimeout()` 的连接超时；同一条 TCP 连接使用独立 Wire，节点端点不重新进入业务路由。

### 启动与本地成功屏障

Channel 建立后，Connection 将同一个 NetworkAddress 传给 `start(handshake:)`。WireResult.outbound 是必须按序写入下游的控制字节，不能再次编码；inbound 是解码后的业务数据；ready 表示 Wire 自身的启动条件是否满足。

ready=false 时继续按预算读取下游，调用 decodeInbound 推进启动并处理必要控制输出。只有 ready=true 且此前必要控制输出全部写入成功，Connection 才能按本地入口规则进入下一阶段。不得假定存在统一的远端成功码，也不得等待首段业务数据判断就绪。

对需要本地成功回复的入口，业务数据必须排在完整成功回复之后；普通 HTTP 在 Wire 就绪后发送源站请求。Wire 的具体控制报文始终不进入入口解析器。就绪不等于最终目标应用已经成功。

### 业务、错误与资源

TCP 后续业务调用 encodeOutbound，address 为 nil；目标已经在 start 固定。收到的下游字节调用 decodeInbound，业务结果与必要控制输出分别保序。空解码结果不是 EOF。

Connection 在下游正常 EOF 时调用 finishInbound 检查截断；本地输入 EOF 时等已排队业务和控制输出写完再关闭下游输出方向。最终清理由 Connection 关闭所属 Channel 并释放 Wire 引用，不增加 Wire 的网络关闭操作。bufferedBytes 与结果队列一起计入预算。Wire 保留原始错误，Connection 在最高拥有边界统一决定本地失败和关闭；PROXY 失败不回退 DIRECT、不重放载荷，成功回复开始后不追加失败回复。

测试使用行为可观察的 Wire 与 Channel 验证接口及真实消费路径；具体实现的线上格式另行验收。更换 Wire 不应改变本地报文、本地凭据或目标来源，也不应增加入口专属节点协议分支。


---

<a id="s12"></a>
## 12. TCP 双向转发、背压与半关闭

### 12.1 字节流抽象

```text
read(maxBytes) -> non-empty bytes | EOF
writeAll(bytes) -> 所有字节按序被传输适配器消费，或抛错
finishWrite() -> 结束写方向，但继续允许读取
abort() -> 立即终止整个连接；幂等
localEndpoint() -> 实际本地绑定端点
peerEndpoint() -> 实际对端端点
```

`writeAll` 完成不代表远端应用已经处理载荷。适配器必须处理底层部分写、暂时不可写、取消和错误。

### 12.2 两个方向独立运行

```text
client → outbound
outbound → client
```

每个方向只有一个写入者。不要创建“每收到一块数据就新建一个无限并发写 Task”的结构，否则可能打乱顺序并失去背压。

建议每个方向最多持有一个正在写的块和一个受限待处理块；使用较大队列时也必须受到每方向和全局字节预算约束。

### 12.3 背压

默认读取块 32 KiB；每方向未完成缓冲上限 256 KiB。达到上限就暂停对应读方向，待写出释放额度后恢复。

不能把 socket 接收速度、进程内排队速度和对端消费速度当成相同速度。缓冲计数必须包含 early data、上游回复余留数据、正在排队的发送缓冲以及异步 API 仍持有的数据。

### 12.4 半关闭

客户端发送 FIN 只表示客户端不会再发更多字节，不表示客户端不需要读取结果。

```text
客户端读方向 EOF
    → 转发完已经收到的数据
    → outbound.finishWrite()
    → 继续 outbound → client
```

反方向同理。两个方向均完成，或者发生不可恢复错误、取消、空闲超时或半关闭排空超时后，再释放整个会话。

平台适配器必须真实支持上述契约。不能用关闭整个 Channel 或文件描述符代替写半关闭，然后声称半关闭已经实现。

### 12.5 透明性

CONNECT 成功后，除传输 EOF / 错误外，本服务不修改业务字节，不插入心跳，不尝试替换 HTTP 头，也不终止客户端的目标 TLS。

日志、限流和统计只能观察长度、时间和明确允许的元数据，不能为实现这些功能而复制并保存全部载荷。

---

<a id="s13"></a>
## 13. UDP ASSOCIATE 控制连接

### 13.1 先 TCP，后 UDP

客户端必须先通过 TCP 完成方法协商、可选认证，再发送 `UDP ASSOCIATE`。成功回复告诉客户端随后向哪个 UDP 端口发送封装报文。控制 TCP 必须保持打开。[S1](#ref-s1)

```text
客户端                         本服务
   │── TCP connect ───────────→│
   │── SOCKS5 协商/认证 ───────→│
   │── UDP ASSOCIATE ──────────→│
   │                           │ 绑定专属 UDP socket
   │←─ 成功，BND=127.0.0.1:P ──│
   │                           │
   │══ UDP 数据报到 P ════════→│
   │←═ UDP 封装回复 ═══════════│
   │                           │
   │── 控制 TCP 关闭 ──────────→│ 销毁关联和所有子流
```

### 13.2 一个关联一个入站 UDP 端口

基础版本为每个控制会话分配一个专属 UDP socket 和独立端口。SOCKS5 UDP 头没有通用 association ID；使用专属端口可以避免多个同源客户端在共享 UDP 入口上难以区分归属。

默认在 49152..65535 范围内选择可用端口；失败必须返回错误，而不是发送成功后等待以后再绑定。

本地服务监听 `TCP 1080`，不表示客户端应无条件向 `UDP 1080` 发送数据。必须使用该次回复给出的端口。

### 13.3 本版本允许的源提示

| UDP ASSOCIATE 请求 | 本版本行为 |
|---|---|
| `0.0.0.0:0` 或 `[::]:0` | IP 使用控制 TCP 实际对端；端口稍后学习 |
| 零地址 + 非零端口 | IP 使用控制 TCP 对端；端口必须匹配提示 |
| 非零数值地址 + 零端口 | 地址必须与控制 TCP 对端相同；端口稍后学习 |
| 非零数值地址 + 非零端口 | 必须匹配控制 TCP 对端及所声明的端口 |
| 域名形式的客户端源提示 | 本产品不支持，返回 `REP=0x08`；不为客户端源提示查询 DNS |
| 地址与控制 TCP 对端不同 | 返回 `REP=0x02` |

源提示使用域名被拒绝，只限制 UDP ASSOCIATE 的客户端提示；**不限制真正 UDP 数据报的域名目标**。

本版本主要面向同机回环客户端；LAN 模式要求 TCP 和 UDP 来自同一可观察 IP。跨 NAT、不同网卡出口或控制连接与 UDP 来源 IP 不一致的使用方式不在基础兼容范围内。

### 13.4 源端点绑定

IP 校验依据控制 TCP 的实际对端，不信任 UDP 数据报内的目标字段。RFC 1928 要求按关联记录的客户端 IP 丢弃其他来源的数据报；本产品在此基础上增加端口固定。[S1](#ref-s1)

端口未知时，仅在收到第一条**源 IP 合法、头部合法、目标通过基础安全检查**的数据报后固定源端口。此后不同端口的包全部丢弃，不自动重绑定。

这不构成密码学身份认证。同一台主机上的其他进程或可伪造源端点的攻击者仍可能干扰关联；基础版本使用回环监听和本机信任边界，不能声称它是强认证 UDP 会话协议。

### 13.5 发布的本地中继地址

默认 TCP 对端通过 `127.0.0.1` 进入时，UDP 回复发布 `127.0.0.1:P`；通过 `::1` 进入时发布 `[::1]:P`。关联 socket 必须与发布的地址一致。

LAN 监听时使用该控制连接被接受时的具体本地地址，不能把 wildcard 监听地址直接放进回复。端口转发或 NAT 场景需要额外的显式发布地址配置与验证，本版本不自动推断外部映射。

### 13.6 建立成功不等于某个 UDP 目标已就绪

本地 ASSOCIATE 成功时，尚未知道后续每个数据报的业务目标，因此不预先解析业务域名，也不提前固定业务出口。

UDP Wire 与下游资源可以等第一个匹配 PROXY 的数据报到来后再选择和创建。此时发生的目标或上游错误只能按 UDP 失败策略处理，不再补发第二条 TCP ASSOCIATE 结果。

### 13.7 关闭顺序

关闭关联时，先标记停止接收，关闭所属 DIRECT / PROXY UDP Channel，释放待发报文、端点记录和独占 Wire，最后释放本地中继资源。共享 Wire 按 WIRES_SPEC 的运行周期所有权处理；本地 accepted 控制 Channel 的最终关闭仍归 MagentTCPConnection。

任何迟到的 DNS、拨号或发送完成回调都必须检查关联是否仍存活，不能把已关闭关联重新插入注册表。

---

<a id="s14"></a>
## 14. SOCKS5 UDP 数据报解析与编码

### 14.1 UDP 头格式

```text
RSV(2) | FRAG(1) | ATYP(1) | DST.ADDR(variable) | DST.PORT(2) | DATA(variable)
```

字段布局、分片字段和回包封装依据 RFC 1928。这里没有 `VER`，也没有 `CMD`；不能拿 TCP CONNECT 解析器直接读取整个 UDP 包。[S1](#ref-s1)

| 字段 | 要求 |
|---|---|
| `RSV` | 两字节 `00 00` |
| `FRAG` | 本版本只接受 `00` |
| `ATYP` | `01`、`03`、`04` |
| `DST.ADDR` | 本次数据报的业务目标 |
| `DST.PORT` | 网络字节序，业务目标端口非零 |
| `DATA` | 应用载荷，允许长度为 0 |

### 14.2 精确长度

| 地址类型 | SOCKS5 UDP 头长度 | 载荷起始偏移 |
|---|---:|---:|
| IPv4 | 10 | 10 |
| Domain，长度为 L | `7 + L` | `7 + L` |
| IPv6 | 22 | 22 |

域名字段的线协议上限为 255 字节，因此理论最大域名头为 262 字节；业务主机名是否接受还要经过第 07 节更严格的校验。

IPv6 长度直接按字段求和：`2 + 1 + 1 + 16 + 2 = 22`。实现和缓冲预算必须使用这个实际布局长度，不以任何摘要表中可能出现的不同数字替代实际编码。

### 14.3 数据报边界

每次处理的是一个完整 UDP 数据报；包不足以容纳完整头部就丢弃，**不能等待下一个 UDP 包来补齐**。两个 UDP 数据报也不能合并成一个请求。

零长度原始 UDP 载荷是有效情况。直接 UDP socket 接收到 0 字节不表示 TCP 风格 EOF；若它来自合法对端，应封装一个只有 SOCKS5 头的回包。

### 14.4 校验顺序

```text
1. 找到该入站 UDP socket 对应的关联；关联必须存活。
2. 校验 UDP 源 IP 和已固定的源端口。
3. 检查截断标志和报文总长度上限。
4. 校验 RSV=0，FRAG=0。
5. 依据 ATYP 和长度字段解码目标。
6. 校验端口、域名、IP 和目标安全策略。
7. 必要时固定客户端源端口。
8. 路由 / 获取逻辑流 / 转发 DATA。
```

### 14.5 分片与 MTU

本版本不实现 SOCKS 层分片重组，所有 `FRAG != 0` 数据报直接丢弃，不向客户端发送成功或错误确认。[S1](#ref-s1)

SOCKS 层分片不等于 IP 层分片。前者有 SOCKS `FRAG` 字段，后者由网络栈及路径处理；禁止通过自行切开 DATA、各加 `FRAG=0` 来假装完成透明分片。

本产品对收到或发出的完整 UDP 报文设置保守上限 65507 字节，包含 SOCKS5 头，不支持 UDP jumbogram。该值是本产品选择的统一上限，不意味着所有网络路径都能传送这样的大包。

可记录封装后超过 1200 字节的统计，帮助诊断隧道 MTU；1200 只是诊断阈值，不是拒绝所有更大数据报的默认门槛。`EMSGSIZE` 等发送错误按整包丢弃处理，不截断载荷，不自动改走 TCP。

### 14.6 接收缓冲与截断

使用足够大的接收缓冲，并检查底层是否报告截断。若所选高级 API 无法保证消息完整性或无法区分截断，适配器必须用能够满足该契约的实现。

来自目标的原始 UDP 回包，加上 SOCKS5 头后超过下游上限时，应整体丢弃并统计 `encapsulation_too_large`，不能只转发前半部分。

---

<a id="s15"></a>
## 15. UDP 分流、直连、代理与回包

### 15.1 UDP 逻辑流建立

```text
合法 SOCKS5 UDP 数据报
    ↓
Target + transport=UDP
    ↓
规则决定 DIRECT / PROXY / REJECT
    ↓
查找 UDPFlowKey
    ├── READY   → 按原出口发送当前数据报
    ├── OPENING → 有界排队
    ├── FAILED  → 冷却期内丢弃；期满后只由新报文触发重建
    └── 不存在  → 申请预算、创建逻辑流
```

REJECT 不创建流所需的网络资源。一个关联里的不同目标各自决策；不会因为其他目标走代理，就顺便把全部 UDP 都代理出去。

同一目标和快照内的流固定出口。DNS 变化、临时网络故障和配置热更新都不能把已存在流静默改成其他出口。

### 15.2 DIRECT UDP

对数值目标，创建专属的 connected UDP socket，绑定到一个固定远端端点。对域名目标，调用系统解析器并校验候选，从获准候选中按系统顺序选择一个数值地址，然后为其创建 connected UDP socket。

```text
客户端 SOCKS5 UDP 包
    ↓ 去掉 SOCKS5 头
DATA
    ↓ 用流专属 UDP socket 发送
目标 IP:PORT
```

UDP `connect()` 或发送成功只表示本地 socket/发送操作满足条件，不证明目标在线，也不等同于 TCP 握手完成。

不能为“测试哪个 IP 可用”把同一 UDP 业务报文同时发往所有 DNS 候选。基础版本选择一个地址，流存活期间不轮换；失败的已发送数据报不重发。

### 15.3 DIRECT 回包

流专属 socket 只接受选定远端的回包；不从一个任意共享 socket 接受陌生来源后转发给客户端。

```text
目标 IP:PORT 的原始 DATA
    ↓
RSV=0000 | FRAG=00 | ATYP=实际源地址类型 | SRC.ADDR | SRC.PORT | DATA
    ↓
经该关联的本地中继 socket 发给已固定的客户端 UDP 端点
```

同一个地址字段在客户端发包时表示目标，在返回封装中表示回复来源。不能错误地填成本服务中继地址。

域名请求收到数值源地址回包是正常情况。基础版本采用端点依赖过滤，不接受目标另一个未关联端口发送的回包；需要这类行为的协议不属于基础兼容范围。

### 15.4 PROXY UDP：目标和载荷交给 Wire

Connection 校验客户端来源，解析本地 SOCKS5 UDP 头，取得规范化 NetworkAddress 和 DATA。Core 按该目标选择 UDP Wire；Connection 调用 `encodeOutbound(DATA, address: target)`，通过自己持有的 UDP Channel 将结果发送到 Wire 提供的实际节点端点。

本地 SOCKS5 的 RSV、FRAG、ATYP 和控制请求不作为出站报文透传。入口不得要求 Wire 使用相同封装或增加远端关联流程；出站状态与能力边界以 WIRES_SPEC 为准。

### 15.5 端点、Wire 与关联归属

每个本地 UDP 关联记录实际发送过的后端端点及其所选 Wire。收到后端报文时，先确认所属关联仍存活、来源是实际登记的后端，再使用对应 Wire 解码。不能根据最后一次路由、未验证载荷或另一个客户端的记录选择解码器。

Core 可以按节点复用支持独立数据报的 Wire；关联、客户端和实际端点的授权记录仍由 Connection 隔离。若一种传输需要额外状态，应由所属实现明确其生命周期，入口不强制它采用某种远端关联协议。

### 15.6 回包封装

WireResult.inbound 返回业务 DATA 和对应的逻辑来源地址；outbound 中的控制数据报由 Connection 按包写回该 Wire 的实际后端。Connection 校验适用的地址、端口与长度约束，重新生成本地 `RSV=0000 | FRAG=00 | ATYP | SRC.ADDR | SRC.PORT | DATA`，经原关联中继发给已经固定的客户端端点。

节点端点只用于传输来源验证，不能冒充业务回复来源。域名来源不为转发或展示而触发本地 DNS。畸形编码、未知来源或超长回包整包丢弃，不截断、不跨包补齐。

### 15.7 失败、等待与资源释放

等待 DIRECT DNS 或创建下游资源时，每流待发队列最多 8 包、128 KiB；任一上限先到则丢新包。队列不是重传机制；失败或取消释放全部待发数据，已发送数据不得重放。

单个后端或 Wire 失败只清理所属状态并丢弃相关数据报；不回退 DIRECT，不向已成功的本地 TCP 控制连接写入新的 REP。需要重建时，冷却 1000 ms 后只能由新报文触发。

本地控制 TCP 关闭时，整个关联及其下游 Channel、端点记录、待发队列和解析资源全部结束；迟到回包不得恢复关联。Wire 不负责关闭本地 accepted Channel。

---

<a id="s16"></a>
## 16. UDP 与 DNS 的关系

### 16.1 情况 A：外层目标是普通域名

```text
SOCKS5 UDP 目标：media.example.com:443
DATA：某个 UDP 应用的载荷
```

命中 PROXY：域名交给上游，本服务不解析；命中 DIRECT：本服务必须先取得可发送 UDP 的数值地址。

所以“支持 SOCKS5 UDP”并不自动要求一个 DNS 服务器，但**DIRECT 域名 UDP 需要内部地址解析能力**。

### 16.2 情况 B：外层目标是 DNS 服务器 IP

```text
SOCKS5 UDP 目标：192.0.2.53:53
DATA：DNS 查询报文，其中 QNAME=example.com
```

本服务看到的网络目标是 `192.0.2.53:53`。它依据这个外层 IP、端口和 UDP 传输类型分流，DATA 原样转发。

它不读取 DNS QNAME，不因为载荷里有 `example.com` 就应用 `DOMAIN-SUFFIX=example.com`。要做到按 DNS 查询名称分流，需要另一个 DNS 协议功能，不属于本版本。

示例中的 `192.0.2.53` 仅作受控测试端点，不是可直接使用的公共 DNS 服务。

### 16.3 情况 C：外层目标是 DNS 服务器的域名

```text
SOCKS5 UDP 目标：resolver.example.net:53
DATA：DNS 查询报文，其中 QNAME=example.com
```

DIRECT 可能需要本地解析 `resolver.example.net`；PROXY 把该服务器域名交给上游。无论哪种情况，本服务都不替客户端解析 DATA 里的 `example.com`，它只是转发这份查询。

这里有两个不同名称：**用于找到 DNS 服务器的名称**，以及**DNS 查询载荷中想查询的名称**。不能把它们混为同一次本地 DNS 工作。

### 16.4 TCP DNS 和加密 DNS

客户端也可以对某个 DNS 服务器建立 TCP CONNECT；CONNECT 成功后的 DNS TCP 长度前缀和消息体仍属于应用载荷，本服务不解释它们。

DoH / DoT 等加密 DNS 在本服务中也只是相应目标上的应用流量。本版本不解密、不提取内部查询名，也不承诺按这些内部名称执行规则。

### 16.5 不做协议降级代偿

上游不支持 UDP 时，不能把 DNS UDP 包直接写入普通 TCP 隧道，然后认为已经完成 DNS-over-TCP；TCP DNS 的报文封装不同，且这种转换不属于普通 UDP relay。[S3](#ref-s3)

客户端是否自行重试 TCP，属于客户端行为。本服务只报告或表现当前 UDP 路径不可用，不替任意应用设计业务级重试。

---

<a id="s17"></a>
## 17. Wire 能力与安全边界

入口只依赖 Wire 的目标表达、TCP / UDP 编解码能力与错误契约，不选择具体节点协议。TCP 能力不证明 UDP 可用；Core 无法为某目标提供所需 Wire 时，该次操作失败，不能改走直连或把 UDP 载荷写入本地 TCP 控制连接。

本地认证不等于远端认证或数据保护。凭据与具体协议安全机制属于节点配置及 Wire；入口不得复用本地用户凭据、关闭具体实现要求的校验，或把未经支持的地址形式静默改成其他形式。

PROXY 域名按 NetworkAddress 原样交给 Wire，不调用入口的目标 Resolver。该保证不替代 Wire 自身的解析行为验收，也不能证明客户端或其他进程没有执行 DNS。

---

<a id="s18"></a>
## 18. 错误码与失败处理

### 18.1 SOCKS5 请求回复码

下表的 `REP` 编码依据 RFC 1928；内部错误到这些有限回复码的映射是本产品策略。[S1](#ref-s1)

| REP | 协议含义 | 本产品使用场景 |
|---|---|---|
| `00` | 成功 | 相应建立条件已经满足 |
| `01` | 通用失败 | 无法细分的失败、资源不足、协议错误、节点基础连接失败 |
| `02` | 规则不允许 | REJECT、目标安全策略、非法 UDP 客户端来源提示 |
| `03` | 网络不可达 | DIRECT 数值连接明确得到网络不可达 |
| `04` | 主机不可达 | DIRECT 域名解析失败/超时，或明确的主机不可达 |
| `05` | 连接被拒绝 | DIRECT 目标明确拒绝 TCP 连接 |
| `06` | TTL 到期 | 仅有真实对应错误或上游明确报告时使用 |
| `07` | 不支持命令 | BIND、未知 CMD、UDP 功能整体关闭 |
| `08` | 不支持地址类型 | 未知 ATYP、本产品拒绝的地址表达形式 |

普通 socket 建连超时不等同于 IP TTL 到期，本产品将其映射为 `01`，不为方便而一律返回 `06`。

### 18.2 按阶段决定如何报告

| 阶段 / 错误 | 客户端处理 |
|---|---|
| 首字节不是 SOCKS5，尚未进入有效协商 | 直接关闭，不假装完成 SOCKS 协商 |
| 方法列表完整但没有可用方法，或 `NMETHODS=0` | `05 FF` 后关闭 |
| RFC 1929 认证失败或认证格式非法 | `01 01` 后关闭 |
| 请求版本错误 | 关闭；不把后续字节当成另一种入站协议 |
| 请求 `RSV != 0` | 有效 SOCKS5 请求阶段内返回 `REP=01` 后关闭 |
| 未知 ATYP / 拒绝的主机名表达 | `REP=08` 后关闭 |
| CONNECT 或 UDP 数据报业务端口为 0 | CONNECT 返回 `01`；UDP 丢弃 |
| 出站完成前客户端取消 | 清理，不继续为其创建连接 |
| 已成功建立的 TCP 流发生错误 | 关闭/中止流，不追加 SOCKS5 错误帧 |
| UDP ASSOCIATE 成功后的单包失败 | 丢包、计数、限速日志，不往控制 TCP 写 REP |

### 18.3 Wire 与节点错误

节点连接、Wire 初始化、启动及编解码失败由 Connection 在统一边界处理；无更精确且可靠语义时，本地请求回复 `REP=01`。保留原始原因用于内部诊断，不读取具体出站控制字节或直接复制其状态码。

有明确目标不可达、拒绝或地址不支持语义的错误，才按本节的本地 REP 表映射。节点连接失败不能伪装成业务目标拒绝；本地成功之后仅关闭或丢包，不追加 REP。

### 18.4 多候选失败的确定性

DIRECT 域名候选全部被安全策略过滤时返回 `02`。没有任何地址解析结果时返回 `04`。

存在实际连接尝试时：所有尝试都是连接拒绝才返回 `05`；所有尝试都是网络不可达才返回 `03`；所有尝试都是主机不可达才返回 `04`；混合错误、总截止时间到期或其他情况返回 `01`。内部日志保留各候选原因但不得无限累积。

### 18.5 失败回复与关闭时限

失败回复只发送一次。写失败回复最多等待 1000 ms，然后关闭；必须满足 RFC 1928 关于失败后及时结束 TCP、不得超过其规定上限的要求。[S1](#ref-s1)

如果服务已经失去可用连接或处于被取消状态，允许无法送达错误回复，但仍必须释放所有资源。不能为了“保证对方看到报错”而无限等待。

---

<a id="s19"></a>
## 19. 超时、资源限制与生命周期

### 19.1 默认时间预算

所有时间基于单调时钟。下列数值是初始产品默认值，可配置，不是已经测得的性能结果。

| 配置项 | 默认值 | 起止范围 |
|---|---:|---|
| `handshake_ms` | 10000 | accept 后至完整入站请求收到，包含协商和认证；不因每来一个字节重置 |
| `outbound_total_ms` | 25000 | 完整请求/UDP 新流开始后至出站准备好 |
| `dns_ms` | 5000 | 一次逻辑解析，包括等待工作槽 |
| `connect_attempt_ms` | 10000 | 单个 TCP 候选尝试 |
| `wire_start_ms` | 10000 | Wire 启动所需处理，合计预算 |
| `reply_flush_ms` | 1000 | 写入站结果回复 |
| `tcp_idle_ms` | 900000 | TCP relay 两个方向均无实际业务进展 |
| `half_close_drain_ms` | 30000 | 一个方向结束后等待另一方向排空 |
| `udp_association_idle_ms` | 300000 | 关联没有有效 UDP 活动；到期连同控制 TCP 关闭 |
| `udp_flow_idle_ms` | 60000 | 单个 UDP 流无有效活动 |
| `udp_failure_cooldown_ms` | 1000 | 流失败后新报文触发重建的最短等待 |
| `shutdown_grace_ms` | 30000 | 服务停止时允许存量活动排空 |

有效阶段截止时间总是 `min(阶段截止时间, 所属总截止时间)`。禁止把 DNS、多个地址与 Wire 启动的超时简单串联，产生远大于总预算的真实等待。

只有成功解析并处理的有效活动才能刷新 UDP 空闲时间；畸形包、来源不符、REJECT 包和限流丢包不能用来永久维持关联。TCP 仅有控制连接存活不刷新 UDP 活跃时间。

### 19.2 默认容量

| 资源 | 默认上限 |
|---|---:|
| 入站 TCP 会话总数，包含 UDP 控制连接 | 512 |
| 尚未完成入站请求的握手会话 | 64 |
| UDP 关联数 | 128 |
| 每个 UDP 关联的流数 | 32 |
| 全局 UDP 流数 | 512 |
| 全局网络 socket 数 | 2048 |
| 实际并发系统解析任务 | 16 |
| 等待系统解析任务 | 128 |
| 同一次 TCP 拨号的地址候选数 | 8 |
| 同一次 TCP 拨号的并行候选 | 2 |
| 应用层全局未释放数据缓冲 | 64 MiB |

这些上限是共享预算，不是保证所有独立上限可以同时达到。例如 TCP 会话数尚未到顶，但全局 socket 已满，也必须拒绝新建出站。

启动时读取操作系统实际描述符限制，保留至少 64 个描述符供日志、文件和其他系统用途；有效网络 socket 上限取配置值与可用预算中的较小者，并报告配置值及有效值。不能假定任意宿主进程都默认拥有 2048 个可用网络描述符。

### 19.3 缓冲预算

| 缓冲 | 默认上限 |
|---|---:|
| 单次 TCP 接收块 | 32 KiB |
| 每会话 early data | 64 KiB |
| 每个 TCP relay 方向 | 256 KiB |
| 每流 UDP 建立期待发包数量 | 8 |
| 每流 UDP 建立期待发字节 | 128 KiB |
| 单个完整 UDP 数据报 | 65507 字节 |

全局缓冲预算包含上述所有应用持有的数据，不只包含“队列中的 Data”。框架复制、内核 socket 缓冲、TLS 内存、线程栈及其他对象不等于这些数据缓冲；64 MiB 不能被宣传成进程 RSS 上限。

### 19.4 过载行为

握手配额不足时可以直接拒绝新 TCP accept。已经进入请求阶段但无法申请出站资源时返回 `REP=01`。UDP 无法申请流、队列或 socket 预算时丢弃当前包并统计。

禁止通过无界等待队列隐藏资源不足。所有等待必须可取消，有截止时间，并占用可计量的容量。

基础版本采用 `drop-newest`，不为了接收一个新 UDP 包而悄悄丢掉已经排队的旧包；需要其他丢弃策略必须版本化。

### 19.5 配置快照与热更新

入站 TCP 被接收时绑定一个不可变配置快照。一个 UDP 关联继承该快照，关联内后续新流也继续使用它。

因此热更新只影响之后接收的新控制/业务 TCP 会话，不会把已有 TCP 流或 UDP 关联中途换出口。管理员需要立即撤销现有授权或规则时，必须显式结束相关存量会话。

配置更新必须经历：完整读取 → 结构校验 → 语义校验 → 依赖检查 → 构建不可变快照 → 原子替换。更新失败则旧快照继续运行；不能应用半份新规则。

监听地址、端口和 socket 级参数变更不作为普通路由热更新处理；本版本要求受控重启监听或整体重启，并明确返回需要重启的状态。

### 19.6 取消和资源所有权

每个 socket、任务、缓冲和定时器必须有唯一 owner。子任务不能在父会话关闭后继续创建新资源。

关闭操作幂等。回调返回时检查 owner 状态及 generation；资源许可必须恰好释放一次。取消和正常完成竞争时，不能重复回复、重复关闭导致崩溃，或把已关闭描述符误用于另一个新连接。

### 19.7 优雅退出

停止接受新 TCP；禁止建立新的 UDP 流；允许现有 TCP relay 和已有 UDP 流在宽限期内继续处理。宽限期结束后关闭控制连接、关联和所有残留出站，丢弃排队数据，回收预算。

普通单个 UDP 流超时只清理该流；关联超时或控制 TCP 结束则清理整个关联。

---

<a id="s20"></a>
## 20. 完整配置示例与字段语义

### 20.1 基础配置

以下是入口策略的示例格式，供文档校验使用；节点以不透明引用出现，实际节点模型及 Wire 由运行配置装配。本文不提供具体节点的部署配置，也不宣称该 JSON 可直接传给 Magent。

`example.com`、`blocked.example`、`203.0.113.0/24`、`2001:db8::/32` 用于展示规则与测试，不是推荐的生产分流清单。

```json
{
  "schema_version": 1,
  "listener": {
    "tcp": {
      "hosts": [
        "127.0.0.1",
        "::1"
      ],
      "port": 1080,
      "ipv6_v6only": true
    },
    "auth": {
      "mode": "none"
    },
    "access": {
      "allow_lan": false,
      "client_cidrs": [],
      "allow_cleartext_lan_auth": false
    },
    "udp": {
      "enabled": true,
      "bind_mode": "per_association",
      "port_range": [
        49152,
        65535
      ],
      "source_port_policy": "pin"
    }
  },
  "routing": {
    "resolve_for_ip_rules": false,
    "rules": [
      {
        "id": "reject-blocked-domain",
        "match": {
          "domain_suffix": [
            "blocked.example"
          ]
        },
        "action": {
          "type": "REJECT"
        }
      },
      {
        "id": "direct-local-domains",
        "match": {
          "domain_suffix": [
            "lan",
            "local"
          ]
        },
        "action": {
          "type": "DIRECT"
        }
      },
      {
        "id": "direct-private-ip",
        "match": {
          "ip_cidr": [
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "fc00::/7"
          ]
        },
        "action": {
          "type": "DIRECT"
        }
      },
      {
        "id": "proxy-udp-dns",
        "match": {
          "transport": "udp",
          "ports": [
            53
          ]
        },
        "action": {
          "type": "PROXY",
          "outbound": "proxy-main"
        }
      },
      {
        "id": "proxy-example-domain",
        "match": {
          "domain_suffix": [
            "example.com"
          ]
        },
        "action": {
          "type": "PROXY",
          "outbound": "proxy-main"
        }
      },
      {
        "id": "proxy-test-ip",
        "match": {
          "ip_cidr": [
            "203.0.113.0/24",
            "2001:db8::/32"
          ]
        },
        "action": {
          "type": "PROXY",
          "outbound": "proxy-main"
        }
      }
    ],
    "default": {
      "type": "DIRECT"
    }
  },
  "resolver": {
    "kind": "system",
    "direct_name_mode": "absolute",
    "cache": "system_only",
    "max_parallel": 16,
    "max_queued": 128,
    "max_candidates": 8
  },
  "outbounds": [
    {
      "id": "proxy-main"
    }
  ],
  "security": {
    "allow_private_targets": true,
    "allow_loopback_targets": false,
    "allow_link_local_targets": false,
    "deny_self_endpoints": true,
    "deny_cidrs": []
  },
  "dialing": {
    "parallel_candidates": 2,
    "candidate_stagger_ms": 250
  },
  "timeouts": {
    "handshake_ms": 10000,
    "outbound_total_ms": 25000,
    "dns_ms": 5000,
    "connect_attempt_ms": 10000,
    "reply_flush_ms": 1000,
    "tcp_idle_ms": 900000,
    "half_close_drain_ms": 30000,
    "udp_association_idle_ms": 300000,
    "udp_flow_idle_ms": 60000,
    "udp_failure_cooldown_ms": 1000,
    "shutdown_grace_ms": 30000,
    "wire_start_ms": 10000
  },
  "limits": {
    "tcp_sessions": 512,
    "handshakes": 64,
    "udp_associations": 128,
    "udp_flows_per_association": 32,
    "udp_flows_global": 512,
    "network_sockets": 2048,
    "global_buffer_bytes": 67108864
  },
  "buffers": {
    "tcp_read_chunk_bytes": 32768,
    "tcp_early_bytes": 65536,
    "tcp_direction_bytes": 262144,
    "udp_packet_bytes": 65507,
    "udp_pending_packets_per_flow": 8,
    "udp_pending_bytes_per_flow": 131072
  },
  "telemetry": {
    "log_level": "info",
    "target_log_mode": "hash",
    "payload_logging": false,
    "metrics_enabled": true
  }
}
```

### 20.2 顶层字段

| 字段 | 类型 / 有效值 | 语义 |
|---|---|---|
| `schema_version` | 整数 `1` | 不接受未知版本 |
| `listener` | 对象 | 入站 TCP、认证、访问控制及 UDP 关联端口 |
| `routing` | 对象 | 顺序规则与默认动作 |
| `resolver` | 对象 | 内部系统解析策略，不定义 DNS 监听 |
| `outbounds` | 出站数组 | ID 唯一；每条代理动作引用一个 ID |
| `security` | 对象 | 不被普通路由覆盖的安全策略 |
| `dialing` | 对象 | 有界 TCP 候选竞速参数 |
| `timeouts` | 正整数毫秒字段 | 第 19 节定义；本版不使用 0 表示无限 |
| `limits / buffers` | 正整数字段 | 第 19 节定义；按字节计量，不是字符数 |
| `telemetry` | 对象 | 日志、隐私和统计 |

完整配置在规范上包含表中所有顶层对象。实现可以提供默认值，但导出“生效配置”时必须补齐它们，且不能导出凭据。

### 20.3 监听与认证字段

`listener.tcp.hosts` 只接受数值本地绑定地址，不对监听名称执行 DNS。两个回环地址默认分别绑定；IPv6 listener 设置 v6-only，避免同端口双栈覆盖。某个显式请求的绑定失败时启动失败，不悄悄只启动另一半。

`listener.tcp.port` 范围 `1..65535`；`listener.udp.port_range` 是含首尾的两个整数，基础版本允许 `1024..65535` 内的非空范围。不同关联不能同时占用同一个监听地址上的相同中继端口。

`bind_mode` 只允许 `per_association`，`source_port_policy` 只允许 `pin`。设置其他值应报配置不支持，而不是无声忽略。

认证对象是判别联合，以下片段是替换 `listener.auth` 的示例：

```json
{
  "mode": "username_password",
  "users": [
    {
      "username": "local-user",
      "password_ref": "keychain:local-proxy/user/local-user"
    }
  ]
}
```

`mode=none` 不允许混入 `users`。用户名唯一，UTF-8 字节长度符合协议范围，密码通过 `password_ref` 解析，不以明文放进本配置。

非回环监听必须显式设置 `allow_lan=true`、非空 `client_cidrs`、用户名密码认证，并明确允许当前未加密的 LAN 认证风险。基础版本不因 `allow_lan=true` 就允许匿名公网代理。

### 20.4 路由字段

`resolve_for_ip_rules` 在版本 1 中必须为 `false`；不能通过将它改为 `true` 偷偷开启另一套 DNS 分流语义。

每条规则必须有唯一、非空 ID；`match` 中的地址条件是非空字符串数组，`ports` 是非空的端口/范围数组，`transport` 是小写 `tcp` 或 `udp`。没有写 `transport` 表示两者均适用。

不支持的匹配字段，例如 `process_name`、`geoip`、`dns_qname`、`sni`，必须报错。CIDR 必须合法且网络部分规范化，端口范围必须 `1 <= start <= end <= 65535`。

`DIRECT` / `REJECT` 不允许附带 `outbound`；`PROXY` 必须附带它。不可达的节点不是 schema 错误，但无效引用和声明能力不兼容属于语义错误。

UDP 开启时，一条未限制为 TCP 的 PROXY 规则可能命中 UDP，因此引用的出站必须声明 UDP 能力；默认 PROXY 同理。要引用 TCP-only 出站，规则必须明确限定 `transport=tcp`。

### 20.5 节点引用与 Wire 配置边界

出站配置在本文只表示对运行配置中节点的引用。`outbounds` 示例中的 `id` 由配置装配层关联到模型规定的节点 UUID；这些示例是入口策略资料，不是完整节点配置，也不是新增的 Magent 公共配置 API。

Core 根据引用选择可用 Wire；具体节点协议、凭据、启动参数和端点构造由节点模型及 Wire 配置负责。入口不得增加自己的出站 `type`、认证方法、传输协议或远端控制消息字段。默认节点和规则引用的校验时机遵循模型规范；选中后不可用必须失败，不能解释为 DIRECT。

运行时连接实际节点端点前仍须执行适用的端点安全检查。节点域名如需预先解析，由配置装配边界完成；入口只消费 Core / Wire 提供的实际端点，不为代理业务目标执行本地 DNS。

### 20.6 安全字段

`allow_private_targets` 仅控制 RFC 1918 三段 IPv4 私网及 IPv6 ULA 的业务访问。允许私网不意味着允许回环或 link-local。

`deny_cidrs` 是额外的强制拒绝列表；在路由之前和 DIRECT DNS 结果检查时应用。回环目标开关只控制业务目标，不阻止明确配置的回环代理节点；基础设施连接另有严格的自回环检测。

`deny_self_endpoints` 在基础配置中必须为 `true`。即使业务允许 loopback，也不允许访问本服务自己的 SOCKS 和 UDP 中继端口造成递归。

`allow_link_local_targets` 在版本 1 中只允许 `false`，因为本版本没有定义带作用域的 IPv6 目标支持与 link-local 安全模型。

### 20.7 结构与语义校验

JSON 解析必须拒绝重复键；未知字段拒绝，不能依靠普通解码器默认忽略未知键。整数字段不能接受字符串、浮点、布尔或负数替代。

还必须检查：对象 ID 唯一、引用存在、端口合法、用户名密码字节长度合法、所有引用凭据可加载、缓冲与队列容量合理、每流预算不大于全局预算、关联上限不大于 TCP 会话上限、规则和出站 UDP 能力一致。

默认配置的 `global_buffer_bytes` 至少能够容纳一次合法协议交换和一个最大允许 UDP 包。配置不应允许出现“单包上限大于全局可申请容量”却不发出明确错误的情况。

### 20.8 配置导出

生效配置导出必须遮盖或仅保留凭据引用，不能把解析后的密码写回 JSON。日志中的配置错误需要指出字段路径，例如：

```text
routing.rules[3].action.outbound: unknown outbound "proxy-b"
routing.rules[0].action.outbound: selected node cannot provide a UDP Wire
listener.access: non-loopback binding requires explicit authenticated LAN policy
```

---

<a id="s21"></a>
## 21. 安全与隐私约束

### 21.1 入站访问控制

默认仅监听 `127.0.0.1` 和 `::1`。LAN 模式是显式部署选择，不默认监听 `0.0.0.0` 或 `::`。

访问控制先于昂贵认证、域名解析和出站建立。对握手、认证失败、关联创建和无效 UDP 包实施有界计数和限速日志，不能让日志本身成为无界消耗。

### 21.2 数值业务目标检查

以下是本产品强制拒绝策略，不是“这些地址在所有场景都没有合法用途”的泛化声明：

| 地址类别 | 默认策略 |
|---|---|
| IPv4 `0.0.0.0/8` | 拒绝作为业务目标 |
| IPv4 `224.0.0.0/4`、`240.0.0.0/4` | 拒绝组播及所列高段地址，包含有限广播地址 |
| IPv6 `::/128`、`ff00::/8` | 拒绝未指定及组播目标 |
| IPv4 `127.0.0.0/8`、IPv6 `::1/128` | 默认拒绝，需显式允许业务回环访问 |
| IPv4 `169.254.0.0/16`、IPv6 `fe80::/10` | 版本 1 拒绝 link-local 业务目标 |
| RFC 1918 / IPv6 ULA | 由 `allow_private_targets` 控制，基础配置允许 |
| 配置的 `deny_cidrs` | 始终拒绝 |
| 本服务自身端点 | 始终拒绝 |

LAN 部署还应根据实际接口地址与掩码识别并拒绝子网广播目标；不能仅判断地址最后一段是否为 `255`。

### 21.3 域名解析后的检查

DIRECT 域名必须检查解析出的每一个数值候选。过滤掉被拒绝项后，只向获准的数值地址拨号；候选全部拒绝则返回规则拒绝。

不能仅凭域名不在黑名单就允许它解析到本机管理接口。不能检查第一次解析结果后，让网络库再次按域名独立解析和连接。

### 21.4 远端解析的能力边界

PROXY 域名目标不会在本地解析，因此本服务无法完整判断它在远端解析成了公网地址、远端私网还是远端回环。

这类访问控制必须由可信上游和远端部署的 ACL 负责。本服务能限制域名本身和原始数值请求，也能检查收到的数值回包，但不能宣称在不解析目标的情况下完成所有远端 SSRF 防护。

### 21.5 自回环保护

节点最终数值地址与本机地址、监听端口组合相同则拒绝。检查必须覆盖 IPv4-mapped IPv6、节点域名解析到本机、所有实际绑定地址及当前活动 UDP 中继端点。

明确配置的节点端点不能等于本服务监听端点；同处回环网络不表示两者具有相同用途或授权。

跨多个进程或远端代理造成的复杂环路不能仅靠本地端点比较彻底识别，需要部署验证；本服务不得启用会再次读取系统代理设置的出站 HTTP API 来制造明显递归。

### 21.6 UDP 来源与反射风险

只有已认证/获准的 TCP 控制连接能创建关联，只有匹配关联源 IP 和固定端口的 UDP 包能进入业务转发。回包只能发给该固定客户端，不能使用数据报中的业务目标字段作为客户端回复地址。

限制 UDP 关联数、流数、报文长度和发送预算；禁止无关联 UDP 转发、广播和组播。即使来源校验正确，也不应把服务匿名暴露到公网。

### 21.7 凭据与载荷

不记录密码、完整认证帧、业务载荷或 TLS 密钥。用户名根据需要脱敏。凭据仅在必要阶段使用，尽可能缩短明文字节生命周期；Swift `Data` 的复制和内存管理意味着不能无条件承诺所有副本均可可靠清零。

日志默认对域名/IP 标识做带本地密钥的 HMAC 或等价伪名化，不应使用可直接跨机器关联的无盐摘要。伪名化不等于匿名化，调试明文目标日志必须显式开启并有保留期限。

---

<a id="s22"></a>
## 22. 日志、指标与故障定位

### 22.1 连接级结构化事件

```text
session_id / association_id / flow_id
config_snapshot_id
phase
transport
target_type
target_id                   // 默认伪名化
target_port
route_action
matched_rule_id
outbound_id
resolution_purpose?
result
internal_error_code?
socks_rep?
elapsed_ms
bytes_up / bytes_down
```

UDP 正常转发不逐包打印 info 日志。按流记录建立、结束、汇总计数；丢包原因使用指标及受限采样日志。

### 22.2 必须区分的内部错误

```text
inbound_protocol_error
no_acceptable_auth_method
local_auth_failed
target_rejected
target_dns_failed
target_dns_timeout
proxy_connect_failed
wire_start_failed
wire_encode_failed
wire_decode_failed
wire_target_unsupported
udp_source_mismatch
udp_fragment_unsupported
udp_packet_truncated
udp_packet_too_large
udp_queue_full
udp_upstream_unavailable
resource_limit
idle_timeout
cancelled
```

### 22.3 指标

| 指标 | 说明 |
|---|---|
| `sessions_active` | 活动 TCP 会话数 |
| `udp_associations_active` / `udp_flows_active` | 关联与流数量 |
| `network_sockets_active` | 纳入统一预算的 socket 数 |
| `buffer_bytes` | 全局及分类应用缓冲 |
| `requests_total{transport,action,result}` | 路由与建立结果 |
| `dns_calls_total{purpose,result}` | 逻辑解析调用次数，不冒充网络包数 |
| `dns_workers_active` / `dns_queue_depth` | 真实执行与等待中的解析任务 |
| `udp_datagrams_total{direction,result,reason}` | 转发与丢弃计数 |
| `handshake_duration` / `outbound_duration` | 阶段耗时分布 |
| `relay_bytes_total{direction,outbound}` | 原始业务载荷字节数 |

指标标签不能使用完整域名、IP、session ID、用户名或任意错误字符串。`rule_id` 若进入指标也必须来自容量受限的配置集合，避免高基数无限增长。

### 22.4 故障定位顺序

TCP：检查本地协商 → 目标 → Core 路由 → 目标 DNS → 下游 Channel → Wire 启动/编解码 → 本地回复 → relay 与清理。

UDP：检查本地控制 TCP → 本地中继端点 → 客户端来源与 FRAG → 目标与路由 → Wire 能力 → 实际后端登记 → 解码与本地回包封装。

“TCP 能访问网页”不能证明 UDP 链路正常。“只抓不到 UDP 53”也不能证明从未调用系统解析器。

---

<a id="s23"></a>
## 23. Swift 模块划分与接口契约

### 23.1 模块与所有权

沿用 MagentTCPConnection、Socks5Connection、MagentCore 和 Wire。SOCKS5 的 greeting、认证、请求、回复与 UDP codec 属于 Connection；模型与路由使用 MODELS_SPEC.md 的统一契约；Wire 负责具体出站编解码。

### 23.2 调用契约

TCP 按第 11 节先选 Wire、建 Channel、完成启动，再提交本地成功；后续载荷只走编解码。UDP 按第 15 节逐包提供目标与 DATA，并将实际后端及 Wire 绑定到所属本地关联。

所有 Channel 使用 Magent 管理的 EventLoopGroup；Connection 持有并清理它们。Wire 接口不返回或拥有本地控制 Channel，不替 Connection 发送 SOCKS5 回复。

### 23.3 Channel 传输契约

TCP Channel 必须提供完整读写顺序、实际端点、取消和半关闭。UDP Channel 必须保持消息边界、固定源端点、识别截断，并对关联端口有明确控制。Wire 不代替 Channel 执行这些操作。

Channel、连接状态和可能存在的 Swift Task 需要明确的 owner 和幂等清理路径，不能依赖“任务退出后大概会释放”。平台权限和应用集成由宿主文档规定。

### 23.4 并发模型

可以用 actor 管理关联注册表、流表与预算计数，但不要用一个全局 actor 串行处理所有 TCP/UDP 载荷复制和写出，造成不必要的阻塞。

每个 TCP 会话两个受控 relay 方向；每个 UDP 流一个有限状态对象。共享配置不可变，只有注册表和预算需要同步。

阻塞系统解析不在 UI 主线程执行，也不以无限 `Task.detached` 的方式逃避有界工作池约束。

### 23.5 可测试性契约

注入时钟、Resolver、Dialer、UDP socket 工厂、SecretProvider、事件接收器和配置快照。测试必须能分别断言：没有调用 DNS、没有创建目标 socket、请求发给了哪个上游、发送了哪些字节、关闭是否释放了全部预算。

协议解析器不得访问真实网络；纯规则引擎不得引用平台网络类型。这两个限制能让绝大多数协议和分流错误在快速测试中定位。

---
<a id="s24"></a>
## 24. 端到端实例

本节基于第 20 节示例规则。所有地址、端口、时序和报文都是说明或受控测试预期，不是已经运行服务得到的抓包记录。

### 24.1 域名 TCP 命中代理

客户端先发 `05 01 00`，本服务回 `05 00`。客户端随后请求 `example.com:443`：

```text
05 01 00 03 0B 65 78 61 6D 70 6C 65 2E 63 6F 6D 01 BB
│  │  │  │  │  └─────────────────────────────┘ └───┘
│  │  │  │  │              example.com          443
│  │  │  │  └─ 域名字节长度 11
│  │  │  └─ Domain
│  │  └─ RSV
│  └─ CONNECT
└─ SOCKS5
```

本服务命中 `proxy-example-domain`，Core 根据节点引用选择 Wire。Connection 连接 Wire 提供的实际端点，并以原域名目标完成 Wire 启动。

本服务入口的 Target DNS 计数保持 0。满足第 11 节就绪条件后发送本地成功；后续业务数据经 Wire 编解码，入口不再解释其中的应用协议。

### 24.2 内网 IP TCP 命中直连

目标 `192.168.2.10:8080`：

```text
05 01 00 01 C0 A8 02 0A 1F 90
```

示例安全策略允许私网，规则命中 `direct-private-ip`，直接向这个数值地址拨号，不查询 DNS，也不连接 `proxy-main`。

假设受控环境中实际出站本地绑定为 `192.168.2.20:50000`，成功回复应编码为：

```text
05 00 00 01 C0 A8 02 14 C3 50
```

这里的绑定地址是假设值；实际实现必须从真正成功的出站 socket 获取。

### 24.3 域名未匹配，默认直连

目标 `www.example.net:443` 不命中示例代理域名规则，默认 DIRECT。本服务调用系统解析器取得该名称的数值候选，执行安全过滤，然后拨号。

即使某个候选碰巧落入 `proxy-test-ip`，也不重新决定路线。想让该域名走代理，应增加域名规则，而不是依靠隐藏的解析后 IP 匹配。

### 24.4 客户端预解析导致域名规则无法匹配

客户端本来访问 `example.com`，但提交的请求是 `ATYP=01`，目标 IP 又不在示例代理 IP 范围内。

本服务无法从这条请求知道原始域名是 `example.com`，因此不会命中域名规则，可能执行默认 DIRECT。这不是解析器丢失了域名，而是客户端没有把域名交进来。

测试这种差异时应明确区分 curl 的 `--socks5` 与 `--socks5-hostname`；前者让客户端处理目标名称解析，后者向 SOCKS5 代理提交名称。[S5](#ref-s5)

### 24.5 一个 UDP 关联访问两个出口

客户端完成 TCP 协商后发送：

```text
05 03 00 01 00 00 00 00 00 00
```

本服务为它绑定 `127.0.0.1:53001` 并返回：

```text
05 00 00 01 7F 00 00 01 CF 09
```

随后同一个客户端 UDP 源端点发送两个包到 53001：

```text
包 A：目标 192.168.2.10:9000 → direct-private-ip → DIRECT
包 B：目标 example.com:443   → proxy-example-domain → proxy-main
```

本服务记录两个目标的出口。包 A 去掉本地 SOCKS5 头后直接发送；包 B 将域名目标及 DATA 交给 UDP Wire 编码。控制请求的 `0.0.0.0:0` 不参与业务分流。

### 24.6 DNS 数据报命中端口规则

客户端发送给受控 DNS 目标 `192.0.2.53:53` 的 SOCKS5 UDP 包：

```text
00 00 00 01 C0 00 02 35 00 35
12 34 01 00 00 01 00 00 00 00 00 00
07 65 78 61 6D 70 6C 65 03 63 6F 6D 00 00 01 00 01
```

前 10 字节是 SOCKS5 UDP 头，后 29 字节是示例 DNS 查询载荷。示例规则按 UDP 目标端口 53 选择 PROXY；它不读取 DNS 里的查询名称。

若目标是 `192.168.2.53:53`，由于私网 DIRECT 规则排在端口代理规则前面，最终是 DIRECT。这体现“首条匹配”，不是 DNS 端口拥有特殊优先级。

### 24.7 代理故障

如果选定节点连接或 Wire 启动失败，TCP 在本地成功前返回 `REP=01`；UDP 丢弃相关数据报并记录失败阶段。

两种情况都不会改走 DIRECT。其他已经存在的 DIRECT UDP 流仍可工作，除非父关联整体关闭。

### 24.8 客户端结束 UDP 使用

客户端关闭创建关联的 TCP 控制连接。即使稍后还有 UDP 包发到旧中继端口，本服务也不能继续替这个关联转发。所有关联子流、下游 Channel、端点记录和缓冲必须被释放。

---

<a id="s25"></a>
## 25. 字节级测试向量

### 25.1 使用说明

下面是自包含的向量集合，可从本 Markdown 中提取到测试代码。`expected.consumed` 仅指当前协议消息的消费长度；余留字节必须保留。

这些向量首先验证**线协议解析**。目标安全检查、规则决策和域名更严格的产品校验属于后续阶段，不能把两层混在同一个“解析失败”断言里。

```json
{
  "vector_set": "socks5-core-v1",
  "vectors": [
    {
      "id": "greeting-no-auth",
      "phase": "greeting",
      "hex": "05 01 00",
      "expected": {"status": "complete", "consumed": 3, "methods": [0]}
    },
    {
      "id": "greeting-two-methods",
      "phase": "greeting",
      "hex": "05 02 00 02",
      "expected": {"status": "complete", "consumed": 4, "methods": [0, 2]}
    },
    {
      "id": "greeting-partial",
      "phase": "greeting",
      "hex": "05 02 00",
      "expected": {"status": "need_more", "additional": 1}
    },
    {
      "id": "greeting-empty-methods",
      "phase": "greeting",
      "hex": "05 00",
      "expected": {"status": "invalid", "reason": "empty_methods"}
    },
    {
      "id": "auth-u-p",
      "phase": "auth",
      "hex": "01 01 75 01 70",
      "expected": {"status": "complete", "consumed": 5, "username_hex": "75", "password_hex": "70"}
    },
    {
      "id": "connect-ipv4",
      "phase": "request",
      "hex": "05 01 00 01 C0 A8 02 0A 1F 90",
      "expected": {"status": "complete", "consumed": 10, "command": 1, "host": "192.168.2.10", "port": 8080}
    },
    {
      "id": "connect-domain",
      "phase": "request",
      "hex": "05 01 00 03 0B 65 78 61 6D 70 6C 65 2E 63 6F 6D 01 BB",
      "expected": {"status": "complete", "consumed": 18, "command": 1, "host": "example.com", "port": 443}
    },
    {
      "id": "connect-ipv6",
      "phase": "request",
      "hex": "05 01 00 04 20 01 0D B8 00 00 00 00 00 00 00 00 00 00 00 01 01 BB",
      "expected": {"status": "complete", "consumed": 22, "command": 1, "host": "2001:db8::1", "port": 443}
    },
    {
      "id": "udp-associate-unspecified",
      "phase": "request",
      "hex": "05 03 00 01 00 00 00 00 00 00",
      "expected": {"status": "complete", "consumed": 10, "command": 3, "host": "0.0.0.0", "port": 0}
    },
    {
      "id": "request-bad-rsv",
      "phase": "request",
      "hex": "05 01 01 01 C0 A8 02 0A 1F 90",
      "expected": {"status": "invalid", "reason": "bad_rsv"}
    },
    {
      "id": "request-unknown-atyp",
      "phase": "request",
      "hex": "05 01 00 02",
      "expected": {"status": "invalid", "reason": "unknown_atyp"}
    },
    {
      "id": "connect-with-early-data",
      "phase": "request",
      "hex": "05 01 00 03 0B 65 78 61 6D 70 6C 65 2E 63 6F 6D 01 BB 68 65 6C 6C 6F",
      "expected": {"status": "complete", "consumed": 18, "remainder_hex": "68 65 6C 6C 6F", "host": "example.com", "port": 443}
    },
    {
      "id": "reply-udp-local",
      "phase": "reply",
      "hex": "05 00 00 01 7F 00 00 01 CF 09",
      "expected": {"status": "complete", "consumed": 10, "rep": 0, "host": "127.0.0.1", "port": 53001}
    },
    {
      "id": "reply-ipv6",
      "phase": "reply",
      "hex": "05 00 00 04 20 01 0D B8 00 00 00 00 00 00 00 00 00 00 00 01 C3 50",
      "expected": {"status": "complete", "consumed": 22, "rep": 0, "host": "2001:db8::1", "port": 50000}
    },
    {
      "id": "udp-domain-payload",
      "phase": "udp",
      "hex": "00 00 00 03 0B 65 78 61 6D 70 6C 65 2E 63 6F 6D 01 BB 01 02 03",
      "expected": {"status": "complete", "header_bytes": 18, "host": "example.com", "port": 443, "payload_hex": "01 02 03"}
    },
    {
      "id": "udp-ipv6-empty-payload",
      "phase": "udp",
      "hex": "00 00 00 04 20 01 0D B8 00 00 00 00 00 00 00 00 00 00 00 01 01 BB",
      "expected": {"status": "complete", "header_bytes": 22, "host": "2001:db8::1", "port": 443, "payload_hex": ""}
    },
    {
      "id": "udp-fragment-rejected",
      "phase": "udp",
      "hex": "00 00 01 01 C0 00 02 35 00 35 12 34",
      "expected": {"status": "drop", "reason": "fragment_unsupported"}
    },
    {
      "id": "udp-short-header",
      "phase": "udp",
      "hex": "00 00 00 01 C0 00",
      "expected": {"status": "drop", "reason": "truncated_header"}
    },
    {
      "id": "udp-dns-query",
      "phase": "udp",
      "hex": "00 00 00 01 C0 00 02 35 00 35 12 34 01 00 00 01 00 00 00 00 00 00 07 65 78 61 6D 70 6C 65 03 63 6F 6D 00 00 01 00 01",
      "expected": {"status": "complete", "header_bytes": 10, "host": "192.0.2.53", "port": 53, "payload_bytes": 29}
    }
  ]
}
```

### 25.2 必须生成的边界向量

除了上述固定向量，测试必须程序化生成：`NMETHODS=255`；用户名和密码均为 255 字节；域名线协议长度为 1、253、254、255；未知 ATYP；所有端口边界；IPv4-mapped IPv6；域名 NUL；多个末尾点；不合法标签；伪装成域名的数字地址。

长度 255 的域名字段可以在线协议层完整解析，但可能在产品主机名校验层被拒绝。测试应分别验证“读边界正确”和“业务策略拒绝”，避免通过提前截断掩盖解析缺陷。

### 25.3 分片不变性测试

对每个有效 TCP 消息，尝试在每个字节边界切成两段，再按一字节一段及随机分段喂入解析器，最终消息、消费长度和余留字节必须相同。

再测试 `greeting + request + earlyData`，以及 Wire 在同次解码结果中返回 ready=true 与首段业务数据的情况。UDP 不执行跨数据报补齐测试，而是验证每个短包独立丢弃。

---

<a id="s26"></a>
## 26. 测试矩阵与验收条件

### 26.1 P：协议与解析

| ID | 场景 | 必须满足 |
|---|---|---|
| P01 | 无认证协商 | 正确选择客户端提供的方法 |
| P02 | 要求认证但客户端仅提供无认证 | `05 FF` 后关闭，不降级 |
| P03 | 用户名密码子协商 | `VER=01`，长度按字节，失败立即结束 |
| P04 | IPv4 / Domain / IPv6 CONNECT | 目标与端口完整正确 |
| P05 | 每个切分点半包 | 最终结果与一次输入一致 |
| P06 | 多阶段粘包 | 回复顺序不变，余留字节不丢失 |
| P07 | early data | 成功前不发送目标载荷，成功后保持顺序 |
| P08 | Wire 就绪与首段业务数据同时返回 | 必要控制输出和本地成功回复完成后，业务数据按序转发 |
| P09 | 错误版本、RSV、ATYP | 精确按阶段失败，不越界 |
| P10 | BIND / 未知 CMD / UDP 关闭 | `REP=07` |
| P11 | 方法、认证、域名最大长度 | 解析长度正确且资源有界 |
| P12 | 正常 relay 中包含 `05` | 不重新进入 SOCKS 握手 |

### 26.2 R：规范化与路由

| ID | 场景 | 必须满足 |
|---|---|---|
| R01 | 精确域名匹配 | 只匹配规范化后相同名称 |
| R02 | 后缀边界 | 匹配 `a.example.com`，不匹配 `notexample.com` |
| R03 | 大小写、末尾根点、A-label | 规范化结果与转发形式符合第 07 节 |
| R04 | IPv4 与 IPv6 CIDR | 数值匹配正确，无 DNS |
| R05 | IPv4-mapped IPv6 | 不绕过 IPv4 规则与安全策略 |
| R06 | 多规则同时满足 | 首条生效，不做隐藏优先级排序 |
| R07 | 域名无匹配 | 默认 DIRECT，只在执行直连时解析 |
| R08 | 域名解析 IP 命中其他路由规则 | 不重新改变路由 |
| R09 | 数值目标原来属于代理域名 | 不猜域名，不做 PTR，不嗅探 |
| R10 | 同一关联多个 UDP 目标 | 各自路由，出口互不覆盖 |

### 26.3 D：DNS 职责与隐私

| ID | 场景 | 必须观察到 |
|---|---|---|
| D01 | 数值目标 DIRECT / PROXY | Target DNS 调用为 0 |
| D02 | TCP / UDP 域名 DIRECT | 合法系统解析；只连接已检查的数值候选 |
| D03 | TCP / UDP 域名 PROXY | 入口 Target DNS 为 0，Wire 收到域名 NetworkAddress |
| D04 | 节点配置名称解析 | 配置装配与入口目标 DNS 分开；入口只消费实际节点端点 |
| D05 | UDP 后端端点 | 使用所选 Wire 提供的实际端点，不从本地控制请求推导 |
| D06 | DNS 超时后迟到成功 | 不为已结束会话拨号；真实工作槽有界 |
| D07 | 一次安全 IP、下一次危险 IP 的假解析器 | 不出现按名称二次拨号 |
| D08 | UDP 载荷中 QNAME 命中域名规则 | 不据此分流；只使用外层目标 |
| D09 | 更换 Wire 实现 | 入口的目标 DNS 和失败不直连契约不变 |

D03 必须同时断言入口 Resolver 调用计数和测试 Wire 收到的 NetworkAddress。真实环境的网络抓包作为补充，不能把未抓到明文 DNS 当成唯一证据。

### 26.4 O：TCP Wire 集成

| ID | 场景 | 必须断言 |
|---|---|---|
| O01 | Core 选择 Wire | 每条 TCP 路由只选择一次；节点端点与业务目标分离 |
| O02 | Wire 启动 | 同一个规范化目标传给 start；按 WireResult 推进启动，不透传本地凭据或入口握手 |
| O03 | Wire 初始化、启动或编解码失败 | 由 Connection 处理本地失败；没有 DIRECT 回退 |
| O04 | 域名与数值目标 | Wire 收到模型规定的地址身份、根点和端口；PROXY 目标 DNS 为零 |
| O05 | Wire 返回错误 | 保留原始原因；不复制具体出站协议的状态码或控制字节 |
| O06 | 下游输入分片、暂未解出业务数据 | Wire 保留协议状态；入口不丢字节、不误判 EOF |
| O07 | 启动后立即产出业务数据 | 本地成功回复与业务余量按入口规定排序 |
| O08 | 启动写未完成、超时或取消 | ready 和必要控制写入均满足才就绪；迟到回调不能恢复会话 |
| O09 | 双向业务数据 | 出站经过 encode，入站经过 decode，入口只消费业务数据 |
| O10 | 更换测试 Wire | 入口报文、目标来源和本地回复契约不变 |
| O11 | 节点等于本服务监听端点 | 拒绝递归连接并清理已申请资源 |
| O12 | 无启动字节及服务器先发 | 不等待客户端首段载荷；就绪后正常完成本地回复 |

### 26.5 U：UDP

| ID | 场景 | 必须满足 |
|---|---|---|
| U01 | 全零源提示 | 使用控制 TCP 源 IP，稍后固定端口 |
| U02 | 非零错误源提示 | ASSOCIATE 拒绝，不创建可用关联 |
| U03 | 关联端口绑定失败 | 不发送成功 |
| U04 | 客户端发到非 BND 端口 | 不转发到该关联 |
| U05 | 不同来源 IP / 端口 | 丢弃，不自动学习新端点 |
| U06 | IPv4 / Domain / IPv6 数据报 | 正确提取目标与 DATA |
| U07 | `FRAG != 0` | 丢弃，不进行伪重组 |
| U08 | 头短、RSV 错、截断、超长 | 整包丢弃，不跨包补齐 |
| U09 | 零长度 DATA | 允许，回包不误判为 EOF |
| U10 | DIRECT 数值目标 | 只发送 DATA，回包补 SOCKS 头 |
| U11 | DIRECT 域名多候选 | 只选一个端点，不复制业务包做探测 |
| U12 | PROXY 域名 | Wire 收到域名 NetworkAddress 和 DATA，无入口目标 DNS |
| U13 | 一个关联两个代理目标 | 流通道隔离、回包不串流 |
| U14 | Wire 提供后端端点 | 实际发送端点与登记端点一致，不能使用本地 BND 作为后端 |
| U15 | Wire 解码业务来源 | 重新编码本地 UDP 头，节点端点不冒充业务来源 |
| U16 | 上游 UDP 从陌生端点回包 | 丢弃 |
| U17 | 控制 TCP 关闭 | 所有关联资源释放，后续 UDP 不再转发 |
| U18 | 上游不支持 UDP | 该流失败，不改 DIRECT，不写入普通 TCP |
| U19 | 建立期间队列满 | 丢新包、计数、内存不增长 |
| U20 | 发送失败/超时/冷却 | 不重放旧报文，仅由新包触发重建 |
| U21 | 目标回包封装后超长 | 整包丢弃，不截断 |
| U22 | 空闲及控制 TCP 额外数据 | 分别按关联超时或协议误用结束 |

### 26.6 L：传输、资源与生命周期

| ID | 场景 | 必须满足 |
|---|---|---|
| L01 | 客户端写半关闭、目标继续回包 | 回包完整，最后再关闭 |
| L02 | 服务器先发 | 不等待客户端载荷即可转发 |
| L03 | 慢客户端 / 慢上游 | 背压生效，字节顺序正确 |
| L04 | 双方向大流量 | 无无限 Task、无越限缓冲 |
| L05 | 会话关闭与迟到拨号竞争 | 不泄漏、不中途复活、不重复释放 |
| L06 | 候选连接竞速 | 胜者唯一，输者及迟到连接都关闭 |
| L07 | 全局 socket、缓冲、DNS 队列耗尽 | 拒绝/丢弃可预期，不创建无界队列 |
| L08 | 退出宽限期结束 | 所有 socket、任务、定时器、预算最终归零 |

### 26.7 C：配置

| ID | 场景 | 必须满足 |
|---|---|---|
| C01 | 重复 JSON 键、未知字段、错误类型 | 拒绝配置 |
| C02 | 重复 ID、无效出站引用 | 拒绝配置 |
| C03 | UDP 规则引用 TCP-only 出站 | 拒绝或要求明确限制 TCP，不静默回退 |
| C04 | 非回环匿名监听 | 拒绝启动 |
| C05 | 新配置不合法 | 旧快照继续服务 |
| C06 | 合法热更新 | 新会话用新快照，旧 TCP 和 UDP 关联保持旧快照 |
| C07 | 更换监听参数 | 明确需要重启，不假装已热更新 |
| C08 | 导出生效配置 | 不输出解析后的密码和其他秘密 |

### 26.8 S：安全

| ID | 场景 | 必须满足 |
|---|---|---|
| S01 | 业务回环/未指定/组播/link-local | 按安全策略拒绝 |
| S02 | 域名解析到被禁止地址 | 不拨号，不能二次解析绕过 |
| S03 | 节点指向本服务，含映射 IPv6/域名形式 | 自回环拒绝 |
| S04 | 授权节点与业务目标 | 独立端点授权，不绕过自身监听保护 |
| S05 | UDP 业务域名对应数值来源回包 | 先验证实际后端并选择登记的 Wire；不宣称本地 DNS 已验证域名归属 |
| S06 | Wire 能力或节点端点授权不足 | 操作失败，不放宽实现要求的校验，不回退 DIRECT |
| S07 | 密码、载荷、畸形输入进入日志 | 无秘密泄漏，控制字符转义 |
| S08 | UDP 伪造来源及反射尝试 | 不发送给任意客户端端点，不创建无界状态 |

### 26.9 手工 TCP 互操作测试

先在受控测试环境验证，不以公网目标是否恰好可达作为协议正确性的唯一判断。

以下 curl 命令会访问示例网站，属于可选的真实连通性测试；`--noproxy ""` 避免本机已有 NO_PROXY 规则跳过该次显式测试代理。[S5](#ref-s5)

```bash
# 让 SOCKS5 服务收到目标域名。
curl --noproxy "" \
  --socks5-hostname 127.0.0.1:1080 \
  --max-time 20 \
  https://example.com/

# 对比：curl 在客户端侧处理目标解析，服务通常收到数值地址。
curl --noproxy "" \
  --socks5 127.0.0.1:1080 \
  --max-time 20 \
  https://example.com/
```

上面不是 UDP 测试。UDP 必须使用专门的 SOCKS5 UDP 测试客户端：保持控制 TCP，解析 BND，发送第 25 节格式的数据报，读取并校验带 SOCKS5 头的回包，最后关闭控制连接验证清理。

### 26.10 性能与稳定性验收

以固定硬件、系统、Swift 编译配置和假上游/回显目标进行基准。至少覆盖 1 KiB、32 KiB、1 MiB TCP 载荷、服务器先发、慢读、单向 FIN，以及不同大小和速率的 UDP 数据报。

建议在平台有效资源预算允许范围内逐级增加到 512 个 TCP 会话，或 128 个 UDP 关联及配置允许的流数；不要求所有独立上限同时跑满。连续运行至少 30 分钟，记录吞吐、CPU、RSS、描述符、活动任务、队列深度和应用缓冲峰值。

验收重点是顺序正确、资源有界、失败可解释、停止后可回收。上述数字是测试计划，不是已获得的吞吐或内存成绩；没有实际基准之前，不承诺某个固定 QPS 或带宽。

---

<a id="s27"></a>
## 27. 实施顺序与需求追踪

### 27.1 实施阶段

| 阶段 | 交付内容 | 完成条件 |
|---|---|---|
| M1 | 地址模型、所有 SOCKS5 codec、增量解析 | P 系列及固定向量通过 |
| M2 | 主机名规范化、纯路由、安全检查、配置加载 | R、C 的纯计算用例及 S01/S03 通过 |
| M3 | 系统解析适配、DIRECT TCP、字节流和半关闭 | D01/D02/D06/D07、L01/L02/L03/L06 通过 |
| M4 | TCP Wire 启动、编解码、错误与清理 | O01..O12 以及 D03/D04 通过 |
| M5 | 本地 UDP 关联、UDP codec、DIRECT UDP | U01..U11、U17/U19/U21/U22 通过 |
| M6 | UDP Wire、实际后端归属、混合出口 | U12..U20、D05/D08、S05/S06/S08 通过 |
| M7 | 全局预算、生命周期、日志与 Wire 集成 | 剩余 L/C/S、D09、O10 及稳定性测试通过 |

M3 或 M4 完成时可以交付明确标识的 TCP-only 开发构建，但它**不等于本文件定义的完整版本验收通过**。完整版本必须完成 UDP 和资源生命周期要求。

### 27.2 核心需求追踪

| 需求 ID | 要求 | 主要验收 |
|---|---|---|
| REQ-01 | 正确 SOCKS5 方法协商和本地认证 | P01..P03 |
| REQ-02 | 正确解析三类目标及半包粘包 | P04..P11 |
| REQ-03 | 纯规则引擎、顺序首命中、默认直连 | R01..R10 |
| REQ-04 | PROXY 域名不做本服务 Target DNS | D01/D03/D04 |
| REQ-05 | DIRECT 安全解析且无二次解析 | D02/D06/D07、S02 |
| REQ-06 | TCP Wire 启动、编解码与本地错误映射 | O01..O12 |
| REQ-07 | TCP 不丢字节、背压、半关闭 | L01..L06 |
| REQ-08 | UDP 关联与 TCP 生命周期绑定 | U01..U05、U17/U22 |
| REQ-09 | UDP 报文边界、三类地址、无分片重组 | U06..U09、U21 |
| REQ-10 | UDP 多目标分流与 DIRECT 正确封装 | R10、U10/U11 |
| REQ-11 | UDP Wire 与实际后端端点归属 | U12..U16、S05 |
| REQ-12 | 失败不隐式 DIRECT、不重放载荷 | O06/O07、U18/U20 |
| REQ-13 | 无独立 DNS 服务，不按 DATA QNAME 分流 | D08 及监听面检查 |
| REQ-14 | 所有任务、socket、缓冲和队列有界 | L04/L05/L07/L08、U19 |
| REQ-15 | 配置原子更新和快照一致性 | C01..C07 |
| REQ-16 | 凭据隐私和默认回环监听 | C04/C08、S06/S07 |
| REQ-17 | 自回环保护与目标安全限制 | S01..S04 |
| REQ-18 | Wire 替换不改变本地入口契约 | D09、O10 |

### 27.3 可交给编码代理的任务说明

```text
入口协议按本 SPEC，模型与出站抽象分别遵循 MODELS_SPEC.md 和 WIRES_SPEC.md；按 M1 到 M7 实施。
先完成数据模型、纯 codec 和测试，不先耦合 UI、真实 DNS 或真实代理节点。
当前范围包括本地 SOCKS5 CONNECT 与 UDP ASSOCIATE；出站接口遵循 WIRES_SPEC.md，不实现本地 BIND 和 GSSAPI。
保留 consumed / remainder，TCP 支持半包粘包，UDP 不跨数据报拼接。
路由按顺序首命中，默认 DIRECT，禁止在规则引擎中执行 DNS。
PROXY 域名保留域名交上游；DIRECT 域名由系统解析并只向已校验数值地址拨号。
PROXY 只经抽象 Wire 启动和编解码；Channel 与本地回复归 Connection。
UDP 按目标记录路由和实际后端，收到响应后使用对应 Wire 解码并封装本地回复。
代理失败不回退直连，不自动重放 TCP/UDP 业务载荷。
不添加独立 DNS 监听、TUN、SNI 嗅探、PAC 执行或隐含规则优先级。
所有异步任务、解析工作、套接字、缓冲、队列和定时器必须有明确预算与 owner。
每个阶段提交对应测试；不得以浏览器打开网页替代 UDP 和生命周期验收。
未验证的传输、Wire 集成行为和性能指标必须保留为待验证项，不写成完成事实。
```

---

<a id="s28"></a>
## 28. 设计决策汇总与参考资料

### 28.1 设计决策

| 决策 | 本版本选择 | 原因与代价 |
|---|---|---|
| 默认出口 | DIRECT | 与选择性代理模型一致；未匹配目标可能本地访问，不能误认为默认全代理 |
| 域名规则是否为 IP 查询 DNS | 否 | 保持分流纯计算、避免代理目标本地解析；无法按解析后 IP 自动分类域名 |
| DNS 服务 | 不实现 | 只需内部系统解析和普通 DNS 载荷转发 |
| 原始域名缺失 | 不恢复 | 不做不可靠反查、历史 IP 映射或应用嗅探 |
| TCP PROXY | 每连接独立 Wire 状态 | 启动和流编解码不与其他连接混用 |
| Wire 边界 | 不指定具体出站协议 | 节点协议格式与配置在所属契约中验收 |
| 本地 UDP 端口 | 每关联一个 | 归属简单；消耗更多端口和 socket |
| UDP 后端 | 按关联登记实际端点与 Wire | 回包使用正确解码器且不跨客户端转发 |
| UDP 源端口 | 首合法包后固定 | 简化安全与映射；不支持无感 NAT 重绑定 |
| UDP SOCKS 分片 | 不支持 | 明确丢弃非零 FRAG，减少复杂状态 |
| UDP 多地址候选 | 不并发复制载荷 | 避免重复副作用；不自动探测最快目标 |
| 热更新 | 新会话使用新快照 | 不破坏存量流；紧急撤销需显式关闭旧会话 |
| 自动直连回退 | 禁止 | 避免出口和隐私语义发生不可见变化 |
| GSSAPI / BIND | 不实现 | 保持明确子集，不虚称完整 RFC 合规 |
| 性能声明 | 必须实测 | 规格中的预算和测试负载不是测量结果 |

### 28.2 最终应能回答的七个问题

| 问题 | 本 SPEC 的答案 |
|---|---|
| 怎么解析客户端数据？ | TCP 分阶段增量解析；UDP 按单个完整数据报解码，三种 ATYP 各有确定长度。 |
| 从哪里拿到目标地址？ | TCP 从 CONNECT；UDP 从每个 UDP 包的目标头，不能从 ASSOCIATE 的源提示取业务目标。 |
| 怎么知道走哪条链路？ | 目标规范化、安全检查、顺序首匹配规则，得到 DIRECT / PROXY / REJECT。 |
| 没有规则匹配怎么办？ | 默认 DIRECT；域名到此时才使用系统解析，数值 IP 不查询。 |
| 域名代理时谁解析？ | 入口保留名称交给 Wire；入口不执行目标 DNS，Wire 自身行为另行验收。 |
| 到代理服务器怎么通信？ | Core 选择 Wire，Connection 读写其实际端点，Wire 负责启动和编解码。 |
| 需要一个 DNS 端口吗？ | 不需要；内部 Resolver 和普通 DNS 报文转发已覆盖本版需求，UDP 中继端口不是 DNS 服务端口。 |

### 28.3 标准与官方资料

入口协议字段以以下原始资料为依据；本产品的超时、限制、配置格式、路由语义及隔离策略是本文件明确选择的工程设计。

<a id="ref-s1"></a>
**S1 — RFC 1928, SOCKS Protocol Version 5**\
用于方法协商、命令、地址类型、回复、UDP 头、分片与控制连接生命周期。\
<https://www.rfc-editor.org/rfc/rfc1928.html>

<a id="ref-s2"></a>
**S2 — RFC 1929, Username/Password Authentication for SOCKS V5**\
用于用户名/密码子协商格式、状态和明文凭据风险。\
<https://www.rfc-editor.org/rfc/rfc1929.html>

<a id="ref-s3"></a>
**S3 — RFC 1035, Domain Names — Implementation and Specification**\
用于 DNS 名称长度、DNS 消息与传输边界；本服务不因此实现 DNS 服务端。\
<https://www.rfc-editor.org/rfc/rfc1035.html>

<a id="ref-s4"></a>
**S4 — RFC 5890, Internationalized Domain Names for Applications: Definitions and Document Framework**\
用于 IDNA A-label / U-label 概念；具体输入接受策略由第 07 节限定。\
<https://www.rfc-editor.org/rfc/rfc5890.html>

<a id="ref-s5"></a>
**S5 — curl 官方命令行手册**\
用于 `--socks5`、`--socks5-hostname` 和 `--noproxy` 测试方式。\
<https://curl.se/docs/manpage.html>


---

**完成定义：** 第 27 节核心需求对应的测试全部通过，真实上游 TCP/UDP 集成通过，资源回收和代理失败不直连通过；在此之前，本文件描述的是目标规格，而不是已经完成的产品能力。
