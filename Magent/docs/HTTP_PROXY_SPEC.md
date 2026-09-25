---
desc: "本地 HTTP 正向代理的请求与响应处理、CONNECT、路由、DNS、配置、生命周期及验收标准。"
version: "0.2.0"
updated_at: "2026-09-24"
status: "草案"
references_checked_at: "2026-09-21"
---

# 本地 HTTP 正向代理服务完整规格（SPEC）

本文规定本地入口协议与抽象 Wire 的协作契约。入口只处理自己的报文、目标和本地响应；具体出站协议的线上格式、认证、加密、节点部署及配置属于 Wire 和节点模型，不在本文定义，也不能由入口协议推断。

抽象接口统一由 [Wire 规范](WIRES_SPEC.md) 定义。业务目标使用 [模型规范](MODELS_SPEC.md) 中的 `NetworkAddress`；节点引用、实际端点和规则由 Core 按同一模型契约处理。本文的逻辑流程和示例不新增模型构造入口或具体 Wire 类型。协议字段限制仍由入口负责。

<a id="contents"></a>
## 目录

| 章节 | 内容 |
|---|---|
| [01](#s01) | 产品目标、范围与固定决策 |
| [02](#s02) | HTTP 代理的两种工作方式 |
| [03](#s03) | 整体架构与模块职责 |
| [04](#s04) | 核心数据模型与地址分类 |
| [05](#s05) | 监听、接入与客户端访问控制 |
| [06](#s06) | 字节级增量解析与请求状态机 |
| [07](#s07) | 请求行、请求目标与目标地址提取 |
| [08](#s08) | 请求头校验、逐跳字段与重编码 |
| [09](#s09) | 请求体、chunked 与 Trailer |
| [10](#s10) | 本地代理认证与身份隔离 |
| [11](#s11) | 分流规则、匹配算法与默认动作 |
| [12](#s12) | DNS 职责、解析时机与地址选择 |
| [13](#s13) | DIRECT：普通 HTTP 与 CONNECT 链路 |
| [14](#s14) | PROXY：抽象 Wire 集成 |
| [15](#s15) | HTTP 语义与 Wire 载荷的边界 |
| [16](#s16) | HTTP 响应解析、改写与返回 |
| [17](#s17) | Expect、信息响应与提前结束上传 |
| [18](#s18) | CONNECT 成功切换、早到数据与隧道转发 |
| [19](#s19) | WebSocket、Upgrade、HTTP/2 与 HTTP/3 |
| [20](#s20) | 长连接、流水线、连接复用与配置快照 |
| [21](#s21) | 超时、背压、资源预算与关闭流程 |
| [22](#s22) | 安全边界与防绕过要求 |
| [23](#s23) | 错误模型与 HTTP 状态码映射 |
| [24](#s24) | 完整配置示例与配置校验 |
| [25](#s25) | 日志、指标与问题定位 |
| [26](#s26) | Swift 实施结构与接口契约 |
| [27](#s27) | 端到端报文示例与调试命令 |
| [28](#s28) | 测试矩阵、故障注入与发布门槛 |
| [29](#s29) | 实施顺序与需求追踪 |
| [30](#s30) | 标准依据、参考资料与最终检查表 |

---

<a id="s01"></a>
## 01. 产品目标、范围与固定决策

### 1.1 产品目标

本服务在本机监听一个 HTTP 正向代理端口。应用显式连接本服务后，本服务从 HTTP 请求中提取**真正的业务目标**，执行安全检查和规则匹配，并选择以下动作之一：

```text
DIRECT：本服务连接业务目标，继续替客户端转发数据。
PROXY ：本服务连接指定上游，通过上游访问业务目标。
REJECT：本服务拒绝本次请求，不创建业务出站连接。
```

本服务不是网站的反向代理，也不是让浏览器访问一个“代理网页”的 Web 应用。它不通过 `302` 或某个虚构的 `DIRECT` 响应让客户端重新建立直连。

### 1.2 规范性用语

本文的 **MUST / 必须** 表示本实现配置的强制要求；**MUST NOT / 禁止** 表示不允许的行为；**SHOULD / 应当** 表示通常应采用的实现方式；**MAY / 可以** 表示可选能力。

必须区分两类约束：

- **协议要求**：来自 HTTP 及其相关标准，相关章节注明依据。
- **产品配置要求**：本项目主动选择的范围、安全限制、默认值与失败策略，不宣称其他代理也必须采用。

本文不是任何一份 RFC 的全文翻译。数值限制、默认端口、路由模型、资源预算和模块接口是本项目的设计选择。

### 1.3 V1 能力范围

| 能力 | HTTP-PROXY-V1 决策 |
|---|---|
| 本地接入 | 明文 TCP 上的 HTTP/1.1，默认回环地址 |
| 普通 HTTP 代理 | 支持 `http://` absolute-form 请求 |
| HTTPS 网站访问 | 支持 HTTP `CONNECT` 建立 TCP 隧道 |
| 入站 HTTP/1.0 | 不支持；可识别的请求返回 `505` |
| 源站 HTTP/1.0 响应 | 支持解析；不复用对应源站连接 |
| 本地 HTTPS 代理监听 | 不属于 V1；不在 HTTP 端口自动识别 TLS |
| 普通请求的 origin-form | 不作为转发入口接受；返回 `400` |
| `OPTIONS *` | 作为对本代理的能力请求在本地处理 |
| 常见 HTTP 方法 | 转发 GET、HEAD、POST、PUT、PATCH、DELETE、OPTIONS 等 |
| 扩展方法 | 语法合法、非产品禁止项时允许按普通 HTTP 转发 |
| TRACE | 产品策略禁止，返回 `403` |
| 请求体 / 响应体 | 支持无体、Content-Length、chunked；响应另支持 EOF 定界 |
| 内容编码 | 不解压或重新压缩 gzip、br 等 `Content-Encoding` |
| 传输编码 | V1 只实现单独的 `chunked`；不实现其他 Transfer-Encoding |
| Trailer | 支持明确允许的字段，见第 09、16 节 |
| HTTP 长连接 | 支持客户端顺序复用，每个请求独立匹配路由 |
| HTTP pipelining | 接受有界预读，串行执行，保证响应顺序 |
| 出站连接池 | V1 关闭；普通 HTTP 每个请求创建自己的出站 |
| WebSocket | 支持 HTTP/1.1 `Upgrade: websocket` 和 CONNECT 内的 WebSocket |
| HTTP/2 / HTTP/3 入站代理协议 | 不支持；CONNECT 内的 HTTP/2 字节不受此限制 |
| UDP、CONNECT-UDP、MASQUE | 不支持 |
| PROXY 出站 | Core 选择抽象 Wire；入口不绑定具体出站协议 |
| TLS 中间人解密 | 不做；不安装根证书，不替客户端验证目标网站证书 |
| 独立 DNS 服务 | 不做；不监听 UDP/TCP 53，不提供 DNS 数据包服务器 |

### 1.4 固定设计决策

本规格固定采用以下行为，不允许实现时自行补出另一套隐含逻辑：

```text
入站 HTTP 协议 ≠ 出站协议。
分流动作为 DIRECT / PROXY / REJECT。
规则按配置顺序首条命中；未命中使用显式 routing.default。
分流阶段不进行业务目标 DNS 查询。
DIRECT 域名调用系统解析器；PROXY 域名交给支持域名的上游。
resolve_for_ip_rules 必须为 false。
代理失败不回退直连；fallback 必须为 never。
普通 HTTP 每个请求重新取目标、重新匹配规则。
CONNECT / WebSocket 切换完成后固定目标和路由，不再解析 HTTP。
本地认证凭据和上游认证凭据完全分开。
```

### 1.5 不承诺的能力

本版本不提供 TUN、透明转发、Fake-IP、TLS SNI 嗅探、进程名识别、GeoIP 数据库、PAC 服务、系统代理设置 UI、缓存、广告过滤或 HTTP 内容修改。

系统代理设置与 PAC 可以由外层应用管理，但不属于本监听端口的协议职责。应用没有使用本服务的流量，本服务无法控制。

---

<a id="s02"></a>
## 02. HTTP 代理的两种工作方式

### 2.1 普通 HTTP：按消息转发

客户端访问一个 HTTP URL 时，可以向代理发送：

```http
GET http://www.example.com/catalog?page=1 HTTP/1.1
Host: www.example.com
Accept: */*

```

本服务从请求行中的 URL 提取：

```text
scheme       = http
address      = Domain("www.example.com")
port         = 80
origin-form  = /catalog?page=1
```

DIRECT 连接业务目标；PROXY 使用 Core 选择的 Wire。**两条路径提交到业务通道的普通 HTTP 请求都使用 origin-form：**

```http
GET /catalog?page=1 HTTP/1.1
Host: www.example.com
Accept: */*
Via: 1.1 lp-http-a1
Connection: close

```

本服务必须理解请求与响应的消息边界，不能只改写第一行后永久进行盲目双向转发。请求目标形式与代理转发要求见 [S01](#ref-s01)。

### 2.2 CONNECT：先建立通道，再转发任意 TCP 字节

客户端访问 HTTPS 网站时，典型请求为：

```http
CONNECT www.example.com:443 HTTP/1.1
Host: www.example.com:443

```

本服务完成 DIRECT 目标连接或第 14 节规定的 Wire 启动后，向客户端返回：

```http
HTTP/1.1 200 Connection Established

```

此后客户端通常在该连接内发送 TLS ClientHello，但本服务不依赖这一假设。CONNECT 建立的是 TCP 隧道，不是“只能传 HTTPS”的特殊流。

本服务不能把客户端的 CONNECT 请求原样发给目标网站的 443 端口，也不能自行替客户端执行网站 TLS 握手。CONNECT 语义见 [S02](#ref-s02)。

### 2.3 HTTPS 业务与传输边界

| 名称 | 传输关系 | 本服务是否解密网站流量 |
|---|---|---|
| 经 HTTP 代理访问 HTTPS 网站 | 客户端与网站之间，位于 CONNECT 隧道内 | 否 |
| Wire 的传输保护 | 由具体 Wire 契约决定 | 不改变 CONNECT 内客户端与网站之间的 TLS |
| 本地 HTTPS 代理监听 | 客户端与本服务监听端口之间有 TLS | V1 不提供 |

不能因为本服务支持 HTTPS 网站访问，就把监听地址配置成 `https://127.0.0.1:1087`。

### 2.4 地址从哪里获取

| 入站请求 | 业务目标的唯一来源 |
|---|---|
| `GET http://host:port/path HTTP/1.1` | 请求行 absolute URI 的 authority |
| `CONNECT host:port HTTP/1.1` | 请求行 authority-form |
| `OPTIONS * HTTP/1.1` | 本地代理自身；不生成业务目标 |
| `GET /path HTTP/1.1` | V1 不接受这种转发形式，不根据 Host 猜测 |

`Host`、URL 路径、Cookie、SNI、客户端源地址和代理节点地址都不能覆盖已经提取出的业务目标。

---

<a id="s03"></a>
## 03. 整体架构与模块职责

### 3.1 主数据路径

```text
客户端
  │ TCP / HTTP/1.1
  ▼
Listener + Client ACL + AdmissionController
  ▼
HTTP1RequestDecoder
  │ request-line / headers / framing / remainder
  ▼
LocalAuthenticator + TargetNormalizer
  ▼
TargetGuard（无需 DNS 的检查）
  ▼
RuleEngine（纯函数）
  ├── REJECT ──► LocalErrorResponder
  ├── DIRECT ──► SystemResolver（仅域名）──► NumericAddressGuard ──► TCP
  └── PROXY ──► Core 选择 Wire ──► Connection 建连与 Wire 启动
                                         │
                   ┌─────────────────────┘
                   ▼
       普通 HTTP：HTTP Transaction Engine
          请求重编码、请求体转发、响应解析、响应体转发
       CONNECT：成功响应写完后交给 DuplexRelay
       WebSocket：合法 101 写完后交给 DuplexRelay
```

### 3.2 模块边界

| 模块 | 必须负责 | 禁止负责 |
|---|---|---|
| Listener | 绑定、接收连接、取得真实 peer | 猜测 HTTP 业务目标 |
| HTTP Decoder | 字节语法、消息边界、增量事件 | DNS、路由、拨号 |
| TargetNormalizer | URI/authority、域名/IP/端口规范化 | 根据网络可达性换地址 |
| LocalAuthenticator | 本地用户认证、认证失败响应依据 | 使用上游账户代替本地账户 |
| TargetGuard | 安全地址、端口、自回环检查 | 将 REJECT 偷换成 PROXY |
| RuleEngine | 确定唯一 RouteDecision | DNS、网络探测、读取实时 UI 状态 |
| Resolver | 系统名称解析、候选集合、取消隔离 | 监听 DNS 协议端口 |
| Connector | 按协议建立目标字节流 | 解析网站业务内容 |
| HTTP Transaction Engine | 双向 HTTP 消息处理与字段重编码 | 整个文件缓存进内存 |
| DuplexRelay | 隧道字节、背压、半关闭 | 解析 HTTP、TLS、WebSocket 帧 |
| SnapshotStore | 校验并发布不可变配置 | 半更新活动请求的路由 |

### 3.3 出站就绪的统一含义

DIRECT 在目标 TCP 建立后就绪；PROXY 在节点 Channel 建立、Wire 所需启动处理完成后就绪。第 14 节定义入口可观察的条件；就绪不等于最终应用请求成功。

普通 HTTP 向该路径写入重建后的源站请求；CONNECT 则先写完本地成功回复，再交付业务字节。Wire 的控制报文不能进入 HTTP 响应解析器。

---

<a id="s04"></a>
## 04. 核心数据模型与地址分类

### 4.1 逻辑模型

以下定义为接口语义，不是完整、可直接编译的 Swift 源码。

```text
Address =
    IPv4(bytes[4])
  | IPv6(bytes[16])
  | Domain {
        originalASCII,
        matchName,       // 小写，匹配时去掉单个末尾根点
        forwardName      // 小写，保留输入末尾根点
    }

TargetEndpoint {
    address: Address,
    port: UInt16        // 业务端口 1..65535，0 不合法
}

HTTPDestination {
    target: TargetEndpoint,
    mode: forwardHTTP | connectTunnel,
    scheme: http | none,
    wireAuthority,      // 用于重建 Host；绝不能是代理节点 authority
    originFormBytes?,   // path + 可选 query；不做解码后再编码
    originalTargetBytes,
    hadEmptyPath,
    hadQueryComponent
}

RequestContext {
    sessionID,
    requestID,
    sequenceNumber,
    clientPeer,
    listenerID,
    principal?,
    method,
    destination?,       // OPTIONS * 没有业务 destination
    transport: tcp,
    configSnapshotID
}

RouteDecision {
    action: direct | proxy(outboundID) | reject,
    matchedRuleID: String | default,
    dnsOwner: none | system | upstream,
    configSnapshotID
}
```

### 4.2 至少区分四类地址

| 地址 | 示例 | 用途 |
|---|---|---|
| ClientEndpoint | `127.0.0.1:53000` | 判断谁正在使用本服务 |
| ListenerEndpoint | `127.0.0.1:1087` | 本服务实际监听位置 |
| TargetEndpoint | `www.example.com:443` | 客户端真正要访问的目标 |
| ProxyEndpoint | Wire 提供的实际 SocketAddress | Connection 实际连接的节点端点，与业务目标分离 |

Wire 的控制元数据不属于 HTTP 请求或响应。节点端点、业务目标及实际绑定地址分别保存；HTTP 入口不解码具体节点的控制报文。

### 4.3 消息分帧模型

```text
RequestBodyPlan = none | fixedLength(UInt64) | chunked

ResponseBodyPlan =
    noBody(metadataContentLength?)
  | fixedLength(UInt64)
  | chunked
  | untilEOF
  | switchProtocol(connect | websocket)
```

`HEAD` / `304` 可以携带描述潜在表示长度的 Content-Length，但实际没有消息体。模型不得把“头里出现 Content-Length”直接等同于“接下来必须读取这个长度”。

### 4.4 字段存储

HTTP 头字段必须使用保留重复项与顺序的结构，例如：

```text
HeaderField { nameBytes, lowercasedName, valueBytes }
HeaderBlock = ordered array of HeaderField
```

不能一开始就塞入普通字典并丢掉重复项。否则无法可靠发现重复 Host、重复 Content-Length，也可能错误合并多个 Set-Cookie。

---

<a id="s05"></a>
## 05. 监听、接入与客户端访问控制

### 5.1 默认监听

```text
IPv4：127.0.0.1:1087
IPv6：[::1]:1087
```

绑定地址只允许数值本地地址，不对监听地址执行 DNS。IPv6 socket 应采用明确的 v6-only 行为，避免与 IPv4 绑定产生平台相关冲突。

配置要求同时监听两个地址时，任何一个绑定失败都必须使本次启动失败并回滚已成功绑定的 socket，不能静默启动一半。

### 5.2 单端口协议边界

本监听端口只解析 HTTP/1.1。客户端误发 SOCKS 握手、TLS ClientHello、HTTP/2 prior-knowledge preface 或其他二进制流时，不尝试自动切换协议。

对于明显非 HTTP 的二进制输入，可以直接关闭；对于能够识别的非法 HTTP 请求，按错误模型返回 HTTP 错误后关闭。禁止无限等待“更多字节也许就会变成 HTTP”。

如果同一程序还提供 SOCKS4/SOCKS5，建议使用不同 listener，复用地址、规则、DNS 与出站模块，而不是复用入站解码状态。

### 5.3 LAN 暴露条件

默认不允许非回环客户端。显式启用 LAN 时，必须同时满足：

```text
access.allow_lan = true
access.client_cidrs 非空
listener.auth.mode = basic
access.allow_cleartext_lan_auth = true
```

最后一个开关表示用户明确接受 V1 明文 HTTP 代理的认证暴露风险，不是“认证已经加密”的证明。

客户端 ACL 根据 socket 的真实远端地址判断，不能信任 `X-Forwarded-For` 或请求体中的地址。IPv4-mapped IPv6 来源必须执行等价的 IPv4 ACL 检查。

### 5.4 接入顺序

```text
accept
→ 立即取得并绑定本连接的不可变配置快照
→ 按该快照执行客户端地址 ACL
→ 会话 / socket / 握手资源许可
→ 有界读取 HTTP 请求头
→ 语法与分帧校验
→ 本地认证
→ 目标 / 功能 / 安全检查
→ 路由与出站
```

ACL 拒绝可直接断开，不需要读取完整请求。未通过本地认证时不得为该请求执行目标 DNS、节点连接或 Wire 启动。

---

<a id="s06"></a>
## 06. 字节级增量解析与请求状态机

### 6.1 解析单位必须是字节

HTTP/1.1 输入先按字节流处理，再对已划定边界的协议字段进行 ASCII 判断。禁止把整个 TCP 缓冲先转换成 Unicode 字符串，再用字符串分割实现协议解析。[S01](#ref-s01)

一次 `read()` 可能包含：半个请求行、多个请求头、完整请求加部分请求体、前一请求的结尾加后一请求，或 CONNECT 头部加早到的隧道数据。每一种情况都必须正确处理。

### 6.2 请求解码事件

```text
needMoreData
requestHead(ParsedRequestHead, RequestBodyPlan)
bodyChunk(Bytes)
trailers(HeaderBlock)
messageEnd
protocolError(ErrorCode)
```

解码器必须报告准确的已消费长度，并保留未消费余量。禁止把一次读取的全部数据都标记为“握手已消费”。

### 6.3 普通 HTTP 状态机

```text
ACCEPTED
  → READING_REQUEST_LINE
  → READING_HEADERS
  → HEAD_READY
  → AUTHENTICATING
  → VALIDATING_TARGET
  → ROUTING
  → OPENING_OUTBOUND
  → FORWARDING_REQUEST_HEAD
  → EXCHANGING_HTTP
       ├── 请求方向：BODY / TRAILERS / REQUEST_END
       └── 响应方向：1xx* / FINAL_HEAD / BODY / RESPONSE_END
  → TRANSACTION_DONE
       ├── 允许继续：READING_REQUEST_LINE
       └── 否则：CLOSING
```

`EXCHANGING_HTTP` 必须允许同时发送请求体、读取响应头；不是“上传完成以后才允许接收响应”的单向流程。

### 6.4 CONNECT 状态机

```text
READING_REQUEST_LINE → READING_HEADERS
→ HEAD_READY → AUTHENTICATING → VALIDATING_TARGET → ROUTING
→ OPENING_OUTBOUND
→ WRITING_CONNECT_SUCCESS
→ RAW_RELAY
→ DRAINING_HALF_CLOSED
→ CLOSED
```

只有 `WRITING_CONNECT_SUCCESS` 成功结束才能进入 `RAW_RELAY`。失败分支在尚未提交成功响应时可以写 HTTP 错误；进入隧道后只能关闭流，不能插入 HTTP 错误页。

### 6.5 严格语法配置

| 项目 | V1 行为 |
|---|---|
| 行结束 | 只接受 CRLF；裸 LF 或裸 CR 视为非法 |
| 请求行分隔 | 方法、request-target、版本之间各一个 SP |
| 前导空行 | 每条请求最多容忍一个完整 CRLF；计入头部时间预算 |
| obs-fold | 拒绝，不折叠成空格后转发 |
| 字段名与冒号之间空白 | 拒绝 |
| 字段值前后 OWS | 解析时移除首尾 SP/HTAB，内部合法字节不擅自改写 |
| NUL / 非法控制字符 | 在请求行、字段名、字段值中拒绝 |
| Header value 的 obs-text | 作为不透明字节保留；不强制 UTF-8 解码 |
| 请求目标的非 ASCII 字节 | V1 拒绝，要求客户端使用 ASCII URI / 百分号编码 |

以上部分属于安全优先的产品严格配置，不是要求所有 HTTP 接收者都拒绝标准允许宽容处理的输入。

### 6.6 资源与算法约束

请求头必须在限额内完整校验后才能向出站写任何业务 HTTP 字节。头部检测需保持增量扫描游标，避免每收到一个字节就重新扫描整个缓冲造成二次复杂度。

请求体必须流式处理。完整头部可有界缓存，不允许将完整上传文件或响应文件缓存进内存。

一次较大的底层读取应被切分后依次消费、转发或保留。不能因为系统一次交付的数据较多，就把合法请求体误计为“HTTP 头太大”。

---

<a id="s07"></a>
## 07. 请求行、请求目标与目标地址提取

### 7.1 请求行

```text
METHOD SP REQUEST_TARGET SP HTTP/1.1 CRLF
```

方法名是区分大小写的 token。只有精确的 `CONNECT` 进入隧道语义；只有精确的 `OPTIONS` 可使用 `*`。语法合法的未知方法不自动改成 GET，也不自动进入 CONNECT。

HTTP 版本只接受入站 `HTTP/1.1`。已识别的其他版本返回 `505 HTTP Version Not Supported`；无效版本语法返回 `400`。

### 7.2 普通 HTTP：absolute-form

示例：

```http
GET http://api.example.com:8080/v1/items?cursor=a%2Fb HTTP/1.1
Host: api.example.com:8080

```

提取结果：

```text
Address       = Domain("api.example.com")
TargetPort    = 8080
wireAuthority = api.example.com:8080
originForm    = /v1/items?cursor=a%2Fb
```

规则如下：

1. scheme 按 ASCII 大小写不敏感识别，V1 只支持 `http`。
2. 必须包含非空 authority；禁止 userinfo，如 `user:pass@host`。
3. 未写端口时使用 `80`；显式空端口、0、负数、超出 65535 均拒绝。
4. 普通请求空 path 转为 `/`，query 是否存在必须单独保存。
5. 不修改路径大小写，不合并斜线，不折叠 `.` / `..`，不把 `%2F` 解码成 `/`。
6. 拒绝原始 `#fragment`、反斜线、空白和不合法百分号转义。路径中的合法 `%0D` 等保留为字面转义，不进行解码注入。
7. `GET https://host/path ...` 在 V1 返回 `501`，要求客户端使用 CONNECT；禁止因此明文连接 443，也禁止偷偷终止目标 TLS。
8. `ws://`、`wss://`、`ftp://` 等 absolute URI 不属于本普通 HTTP 入口配置，返回 `501`。WebSocket 的受支持形式见第 19 节。

### 7.3 Host 与 request-target 冲突

入站 HTTP/1.1 必须包含恰好一个语法合法、在本配置中非空的 Host 字段。缺失、重复或语法非法都返回 `400`。

对于 absolute-form，**业务目标以请求行 URI 为准，原始 Host 不参与分流，并按 URI authority 重建 Host**。[S01](#ref-s01)

```http
GET http://allowed.example/path HTTP/1.1
Host: different.example

```

上例业务目标是 `allowed.example:80`，发给目标的 Host 也是 `allowed.example`。禁止“按 allowed.example 匹配规则，实际按 different.example 拨号”。本配置记录 Host 不一致的诊断事件，但不把语法有效的冲突 Host 当成另一个目标。

### 7.4 CONNECT：authority-form

接受：

```text
example.com:443
example.com.:443
192.0.2.10:443
[2001:db8::10]:443
```

拒绝：

```text
https://example.com:443
example.com
example.com:
example.com:0
example.com:65536
example.com:443/path
user@example.com:443
2001:db8::10:443
[fe80::1%en0]:443
```

CONNECT 的目标端口必须显式给出，不根据 Host 或“通常是 HTTPS”默认补成 443。

CONNECT 的 Host 同样必须合法，但目标始终以 request-target 为准。允许 Host 省略端口；Host 不能改变 CONNECT 的目标。Connection 将解析后的目标交给 Core 和 Wire，不透传本地 CONNECT 头作为节点启动报文。

### 7.5 IPv4 / IPv6 解析

IPv4 只接受严格四段十进制，每段 `0..255`；除单独的 `0` 外不接受前导零。拒绝整数地址、十六进制地址、少段 IPv4、无效的全数字点分文本。

IPv6 authority 必须有方括号，模型里存 16 字节地址。括号不属于地址本身；序列化 authority 时再加上。V1 拒绝 zone ID 和 IPvFuture 形式。

IPv4-mapped IPv6 地址除正常 IPv6 规则外，还必须针对所映射的 IPv4 执行安全拒绝与自回环检查，避免绕过 loopback / private 限制。

### 7.6 域名规范化

V1 协议核心接受 ASCII 域名，包括合法 ASCII A-label。Unicode 域名应在 UI / 配置导入层通过经测试的 IDNA 实现转换，不在网络解析器里手写 Punycode。

本产品的域名配置为：标签非空、每标签不超过 63 字节、仅字母数字及内部连字符、无首尾连字符；允许单个末尾根点。去掉末尾根点后的总长度不得超过 253 字节。

```text
输入：API.Example.COM.
matchName：api.example.com
forwardName：api.example.com.
```

ASCII 语法通过并不证明域名存在，也不证明服务可信。不接受百分号编码的 host、下划线标签或不明确的数值地址兼容写法；这是产品限制。

### 7.7 authority 的输出规则

普通 HTTP 的 Host 从 URI authority 重建：保留显式端口与域名末尾根点，域名可规范化为小写；IPv6 加方括号。不得用直连解析出来的 IP 替换域名 Host。

```text
http://example.com/path        → Host: example.com
http://example.com:80/path     → Host: example.com:80
http://example.com:8080/path   → Host: example.com:8080
http://[2001:db8::1]:8080/path  → Host: [2001:db8::1]:8080
```

### 7.8 OPTIONS 与 Max-Forwards

`OPTIONS *` 在本地认证、基础语法校验后由本代理返回 `204 No Content`，不查询 DNS、不发起业务连接。V1 要求这类本地能力请求无请求体：缺少 CL / TE 或单个 CL=0 可接受；声明非零 CL 或任何 TE 返回 `400`，携带 Expect 返回 `417`。本地能力分支不创建业务出站，也不按 Host 选择业务目标。

对于 ordinary absolute-form OPTIONS：

- `Max-Forwards: 0` 在本地处理，不创建出站；与 `OPTIONS *` 相同，要求无请求体且无 Expect。声明非零 CL 或任何 TE 返回 `400`，携带 Expect 返回 `417`。
- 合法正整数转发前减一；V1 接受范围 `0..2147483647`，重复或非法值返回 `400`。
- 不存在时不自动添加。
- 当 URI 原本是空 path 且没有 query，并且本服务作为最后一个 HTTP 代理发给源站时，request-target 使用 `*` 而不是 `/`。PROXY 经 Wire 传递业务字节时也由本服务构造源站请求。

其他方法的 Max-Forwards 不参与路由。TRACE 始终按产品策略拒绝。相关标准语义见 [S01](#ref-s01)、[S02](#ref-s02)。

---

<a id="s08"></a>
## 08. 请求头校验、逐跳字段与重编码

### 8.1 先验证，后重建

顺序必须是：

```text
读取完整头部
→ 检查重复关键字段、语法、限额
→ 计算入站消息分帧
→ 提取并校验 Connection token 集合
→ 认证、目标与策略检查
→ 构造新的出站头部
```

禁止先删除 `Transfer-Encoding` 再判断请求体长度。禁止只过滤部分大小写写法。

### 8.2 Connection 指名字段

收到：

```http
Connection: keep-alive, X-Hop-Only
X-Hop-Only: do-not-forward

```

必须移除 `Connection` 以及它指名的 `X-Hop-Only`。多个 Connection 字段可以按标准列表规则共同解析，token 大小写不敏感。[S02](#ref-s02)

当 Connection 指名 `Host`、`Content-Length`、`Transfer-Encoding`、`Trailer`、`Proxy-Authorization`、`Authorization` 或 `Expect` 等本产品关键字段时，V1 拒绝请求，而不是通过移除它们改变认证或分帧语义。

`Connection: TE` 和 `Connection: Upgrade` 是有效特殊机制，按对应章节消费并重建，不按上述关键字段攻击处理。

### 8.3 字段处理表

| 字段 | 转发规则 |
|---|---|
| Host | 从业务 URI / authority 重建，禁止使用节点地址 |
| Connection | 消费原字段，按本跳行为重新生成 |
| Connection 指名的其他字段 | 从普通转发集合移除 |
| Proxy-Connection | 消费并移除；仅其 `close` token 可作为客户端请求关闭的兼容提示 |
| Keep-Alive | 移除，不把对端的 timeout/max 宣告为本服务能力 |
| Proxy-Authorization | 用于本地认证后移除，不转发给源站或作为 Wire 的节点凭据 |
| Proxy-Authenticate / Proxy-Authentication-Info | 不作为普通端到端字段转发给源站 |
| Transfer-Encoding | 按本跳重新编码后的 BodyPlan 生成 |
| Content-Length | 校验后按对应 BodyPlan 输出，绝不与 TE 同时生成 |
| TE | 逐跳消费；只在本服务实际支持时重建 `TE: trailers` |
| Trailer | 验证字段声明并按本跳 trailer 计划重建 |
| Upgrade | 仅 WebSocket 支持路径重建；不盲目复制 |
| Via | 保留合法已有链并追加本服务条目 |
| Authorization / Cookie | 正常端到端转发，不误删成代理认证 |
| Accept-Encoding / Content-Encoding | 保持语义，不自动解压、压缩或修改 |
| Range / If-* / Cache-Control | 正常转发，本服务不实现缓存 |
| 未知普通字段 | 语法合法且非逐跳字段时保留 |

不要把“hop-by-hop 字段处理”写成无条件删除固定字段名的几行代码。Transfer-Encoding、TE、Trailer、Upgrade 都需要结合相应功能重新生成。

### 8.4 Via

本服务在转发普通 HTTP 请求和响应时追加 Via，例如：

```http
Via: 1.1 lp-http-a1
```

`via_name` 是本实例配置的 ASCII 伪名，不含用户名、计算机名或家庭内网 IP。代理链中的实例应使用不同伪名。

收到已包含本实例完整 Via 标识的请求时，判定可能发生代理回环，返回 `502` 并记录 `PROXY_LOOP_DETECTED`。不得仅做字符串子串匹配。

本地生成的错误响应不是“转发响应”，不要求伪造上游 Via；隧道载荷不插入任何 Via。

### 8.5 Forwarded 类字段

默认不新增 `Forwarded`、`X-Forwarded-For`、`X-Real-IP` 等客户端身份字段。客户端已有的合法普通字段可以保留，但不信任其值，不用它们做 ACL 或路由。

“不自动添加真实客户端 IP”不等于请求原本就不含身份信息。Cookie、Authorization、URL 参数等仍可能暴露应用身份。

### 8.6 请求向源站输出的连接策略

V1 没有源站连接池。普通请求通常输出 `Connection: close`，必要时同时列出本跳生成的 `TE` token，例如：

```http
Connection: close, TE
TE: trailers
```

如果当前请求是受支持的 WebSocket Upgrade，则输出 `Connection: Upgrade`，不同时输出 `close`。源站连接关闭不必导致客户端代理连接关闭；两跳生命周期独立，见第 20 节。

---

<a id="s09"></a>
## 09. 请求体、chunked 与 Trailer

### 9.1 请求分帧决策表

| 条件 | V1 处理 |
|---|---|
| 没有 Content-Length，也没有 Transfer-Encoding | 无请求体；不能等待客户端 EOF |
| 恰好一个合法 Content-Length | 精确读取指定字节数 |
| 单一 `Transfer-Encoding: chunked` | 按 chunked 状态机读取 |
| Content-Length 和 Transfer-Encoding 同时出现 | `400`，关闭连接，禁止转发请求头 |
| 重复 Content-Length，包括完全相同的重复值 | 产品严格策略：`400`，关闭 |
| `Content-Length: 10, 10` | 产品严格策略：`400`，不采用容错合并 |
| 负数、带正号、非十进制、溢出、内部空白长度 | `400` |
| 最后一个编码不是 chunked，包括 `gzip`、`chunked, gzip` | 分帧非法：`400` |
| 最终 chunked 但含未实现编码，如 `gzip, chunked` | 能识别语法但能力不足：`501` |
| 重复 chunked、chunked 参数、非法 TE 列表 | `400` |
| CONNECT 带任何 TE 或非零 Content-Length | `400` |
| CONNECT 带单个 `Content-Length: 0` | 允许但不作为隧道内容长度；不向目标转发 |

Content-Length 使用有溢出检查的 UInt64 解析，并限定不超过 `Int64.max`。前导零可接受，但输出时规范化为一个十进制整数。重复字段拒绝与数值规范化是不同规则。

HTTP 分帧规则见 [S01](#ref-s01)。这里拒绝相同重复 Content-Length 是本产品比部分兼容实现更严格的选择。

### 9.2 不通过方法名猜请求体

GET、HEAD、DELETE 等方法也不能使解析器忽略合法的长度定界。语义与消息分帧分离：普通请求的 BodyPlan 由字段决定，而不是由“GET 一般没 body”决定。

CONNECT、WebSocket 握手及本地 OPTIONS 等产品专门路径可以明确禁止请求体，但必须先识别并拒绝，不能把其 body 当成下一条请求。

### 9.3 Content-Length 流式转发

维护：

```text
remaining = declaredContentLength
```

每次最多消费 `min(availableBytes, remaining, transferBudget)`。消费的请求体即使包含 `\r\n\r\n` 或 `GET ...` 字样，也不能被解释成新请求。

`remaining == 0` 才到达请求消息边界，后续字节保留给下一条请求。提前 EOF 是截断请求，关闭两端，不能补零或默认为成功。

### 9.4 chunked 状态机

```text
READ_CHUNK_SIZE_LINE
  → size > 0：READ_EXACT_CHUNK_DATA
               → REQUIRE_CRLF
               → READ_CHUNK_SIZE_LINE
  → size = 0：READ_TRAILERS
               → FINAL_CRLF
               → MESSAGE_END
```

示例字节串：

```text
4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n
```

解码后的内容是 `Wikipedia`。零块行之后必须继续解析 trailer 区域，直到最终空行；不能只看到 `0\r\n` 就认为整个消息已经结束。

### 9.5 chunk 扩展与大块

允许语法正确、长度受限的 chunk extensions，包括 quoted-string。未知扩展可忽略；V1 重新分块时不保留 chunk extensions，其逐跳性质见 [S01](#ref-s01)。

chunk-size 必须使用有溢出检查的十六进制解析，不允许负数或 `0x` 前缀。单个 chunk 的声明长度可以大于本地缓冲大小；实现必须流式消费，不按 chunk-size 一次性分配内存。

V1 将大小超过 `Int64.max` 的声明视为无法处理的非法长度。是否限制整个 HTTP body 的业务大小由独立策略决定，默认不设置固定总文件大小上限；背压和空闲超时仍有效。

### 9.6 Trailer 支持配置

本产品允许的 trailer 字段由固定能力列表控制。V1 默认列表为：

```text
content-digest
repr-digest
digest
server-timing
```

该列表仅表示本服务允许在 trailer 中传递这些字段，不表示本服务验证摘要、理解计时内容或替客户端验证完整性。摘要字段定义可参考 [S10](#ref-s10)。

规则：

1. 发送方声明 Trailer 时，消息必须是 chunked。
2. 声明字段名必须合法、无重复，并全部在允许列表中。
3. 实际 trailer 字段必须在已声明集合中；允许声明的部分字段最终不出现。
4. 不把 trailer 合并到首部区域，不把首部与 trailer 同名项擅自覆盖。
5. Host、Content-Length、Transfer-Encoding、Connection、认证字段和路由字段永远不能放入 trailer。
6. 未声明、禁止或未知 trailer 是严格配置错误，不静默改成空 trailer。
7. 请求头阶段声明未知或未实现字段时返回 `501`；声明上述永远禁止的字段、重复声明或非法 framing 时返回 `400`。
8. 若错误在 body 后部才出现，禁止为已经提交的最终响应再写第二个 HTTP 响应；按第 23 节处理。

`TE: trailers` 的本跳协商按第 08 节重建。客户端没有发送该能力提示时，本服务不主动向源站宣称客户端会使用 trailer；合法 trailer 若被转发，客户端仍可能忽略它，不得宣传端到端 trailer 使用保证。

### 9.7 出站重新分帧

V1 统一采用：

```text
入站 fixedLength → 出站相同 Content-Length + 原内容字节
入站 chunked     → 解码 chunked → 原内容字节 → 重新编码 chunked
入站 none        → 无 body；保留或规范化显式零长度语义
```

重新分块只改变传输边界，不改变 HTTP content 字节。不得因进行了 dechunking 就无依据生成 Content-Length；不知道最终长度时继续使用 chunked。

---

<a id="s10"></a>
## 10. 本地代理认证与身份隔离

### 10.1 认证模式

```text
none：仅在访问控制允许的本地回环使用。
basic：通过 Proxy-Authorization 验证本地用户。
```

本地 HTTP Basic 只用于入口认证；节点凭据由 Wire 独立处理，不复用本地认证报文。

### 10.2 407 挑战

需要认证但凭据缺失、错误或认证方案不受支持时，返回：

```http
HTTP/1.1 407 Proxy Authentication Required
Proxy-Authenticate: Basic realm="Local HTTP Proxy", charset="UTF-8"
Content-Length: 0
Cache-Control: no-store
Connection: close

```

V1 在 407 后关闭连接，避免未消费请求体被当成下一条请求。只在认证成功后执行目标解析与连接。

### 10.3 Basic 解码

`Basic` 方案名大小写不敏感。凭据使用严格 Base64 解码；解码后按第一个冒号切分用户名与密码，密码可以包含后续冒号。

本产品采用 UTF-8、禁止控制字符，用户名不允许冒号且非空。密码必须非空。凭据长度与认证头长度必须有界；用户名按配置的精确形式匹配，不擅自转小写。

重复 Proxy-Authorization、非法 Base64 或不能构成用户名密码的输入属于坏请求，返回 `400`；格式有效但凭据错误返回 `407`。日志中两者都不得包含原始凭据。

HTTP Basic 本身不加密密码，Base64 不是加密。协议与 charset 规则见 [S03](#ref-s03)。

### 10.4 每个 HTTP 请求独立认证

在同一条客户端长连接上，每条普通 HTTP 请求都必须携带有效代理凭据。不得因为第一条请求认证成功就默认之后所有请求都已认证。

CONNECT 或 WebSocket 切换后不再出现新的代理 HTTP 请求，认证身份固定为建立该隧道的请求身份。

### 10.5 身份隔离

```text
客户端 Proxy-Authorization
        ↓ 仅由本地代理消费
本地 principal

本地配置 password_ref
        ↓ 由 SecretProvider 读取
节点配置与 Wire 管理的独立凭据
```

源站的 `Authorization` / `WWW-Authenticate` 是第三套端到端身份信息。本地 `407` 不能替代源站的 `401`，也不能把上游节点认证失败包装成本地用户再次输入密码的提示。

### 10.6 凭据存储

配置文件只保存 `password_ref`，例如 Keychain 引用，不保存真实密码。错误信息、配置导出和调试日志必须脱敏。

认证比较应避免明显的逐字符提前退出差异；不得把完整 Base64 token 用作日志字段或指标标签。认证失败速率限制必须有界，不能按无限增长的用户名集合保存状态。

---

<a id="s11"></a>
## 11. 分流规则、匹配算法与默认动作

### 11.1 规则输入

规则引擎只接收已经规范化的：

```text
addressType + matchName/IP + targetPort + transport=tcp + configSnapshotID
```

本版本不根据完整 URL、请求路径、Query、Cookie、HTTP 方法、进程名或 SNI 分流。解析器知道某个字段，不等于规则配置就支持这个字段。

### 11.2 支持的字段

| 配置字段 | 语义 |
|---|---|
| `domain` | Domain 的精确匹配 |
| `domain_suffix` | Domain 本身及其子域匹配 |
| `ip_cidr` | 客户端直接提供的数值 IP 的 CIDR 匹配 |
| `ports` | 目标端口；整数或闭区间字符串，如 `443`、`"8000-8100"` |
| `transport` | 共用规则模型接受 `tcp` / `udp`；本 HTTP 入口始终是 `tcp` |

同一规则中的不同条件按 AND 组合；同一数组内部按 OR 组合。`domain`、`domain_suffix`、`ip_cidr` 三个地址条件最多出现一个，防止产生无意义组合。

空 match 不合法；无条件动作统一放在 `routing.default`。在 HTTP-only 配置中，`transport=udp` 的规则永远不会命中，可以给出配置警告，但不得把 HTTP CONNECT 当成 UDP 请求。

### 11.3 域名后缀匹配

```text
host == suffix OR host.endsWith("." + suffix)
```

`domain_suffix=example.com` 匹配 `example.com`、`a.example.com`，不匹配 `notexample.com` 或 `example.com.attacker.test`。

域名规则不对 IP 地址执行 PTR 反查。请求行已经提供 IP 时，不能用 Host 中另外一个域名“补回”域名规则。

### 11.4 首条命中和默认动作

```text
route(context, snapshot):
    target = context.destination.target
    checkPreResolutionSecurity(target)

    for rule in snapshot.routing.rules:
        if allConfiguredConditionsMatch(rule.match, target, tcp):
            return checkedDecision(rule.action, rule.id, snapshot)

    return checkedDecision(snapshot.routing.default, default, snapshot)
```

命中 PROXY 后，如果该 outbound 不存在、禁用或能力不足，不能继续找下一条 DIRECT 规则。配置引用错误应在加载阶段拒绝；运行时不可用则本次请求失败。

### 11.5 三种动作

```json
{"type":"DIRECT"}
```

```json
{"type":"PROXY","outbound":"proxy-main"}
```

```json
{"type":"REJECT"}
```

DIRECT / REJECT 禁止附带 outbound。PROXY 必须引用唯一、有效的 outbound ID。

### 11.6 IP 规则不触发 DNS

```text
输入：some.example
未命中域名规则
默认：DIRECT
系统解析结果：203.0.113.20
```

即使配置中存在匹配该 IP 的 PROXY CIDR 规则，本次仍保持 DIRECT。解析结果只再接受安全检查，不重新执行路由选择。

要做“先解析域名，再根据 IP 地区或 CIDR 决定出口”，必须另行设计版本化 DNS 路由能力；不能将 `resolve_for_ip_rules` 改为 true 后继续声称符合本规格。

### 11.7 默认动作必须显式

示例配置采用 `routing.default = DIRECT`，只是示例，不是“未命中一定应该直连”的协议结论。

默认动作也可以明确设为 PROXY 或 REJECT，但不得省略，不能由“当前有没有可用代理节点”动态推断。

### 11.8 决策缓存

V1 可以不实现路由缓存。实现缓存时，键至少为：

```text
configSnapshotID + transport + addressType + normalizedAddress + targetPort
```

缓存不能使一个客户端长连接内的第一个目标覆盖后续不同目标，也不能把曾经解析过的“域名→IP”关联视为新请求的可信域名身份。

---

<a id="s12"></a>
## 12. DNS 职责、解析时机与地址选择

### 12.1 本服务需要 Resolver，但不需要 DNS 监听端口

入口 Resolver 用于 DIRECT 业务目标；节点名称解析由配置装配层单独负责。它们都不是向客户端提供 DNS 协议服务的监听端口。

```text
不提供：UDP 53 / TCP 53 / 自定义本地 DNS 监听。
不要求：应用把 DNS 服务器改成本服务。
不实现：DNS 报文解析、DNS 分流服务器、Fake-IP。
```

### 12.2 DNS 行为矩阵

| 业务目标 | 决策 | 入口目标 DNS | 节点名称解析 | 出站输入 |
|---|---|---|---|---|
| 数值 IP | DIRECT | 不调用 | 无 | 校验后的 IP:port |
| 域名 | DIRECT | 调用系统解析器 | 无 | 校验后的数值候选 IP:port |
| 数值 IP | PROXY | 不调用 | 属于配置装配 | Wire 接收数值 NetworkAddress |
| 域名 | PROXY | **禁止调用** | 属于配置装配 | Wire 接收域名 NetworkAddress |
| 任意 | REJECT | 禁止 | 不因本次请求调用 | 无 |
| `OPTIONS *` | 本地处理 | 禁止 | 无 | 无 |

规则对普通 HTTP、CONNECT 和 WebSocket 握手一致。

### 12.3 普通 HTTP 不需要先查 IP 才知道目标

```http
GET http://api.example.com/v1/data HTTP/1.1
Host: api.example.com

```

这里已经知道目标域名 `api.example.com`。命中 PROXY 时，将该域名作为 NetworkAddress 交给 Wire，就绪后发送源站 HTTP 请求，不需要先执行 A / AAAA 查询。

CONNECT 同理：`CONNECT api.example.com:443` 已经给出了可直接交给上游的目标名称。

### 12.4 系统解析器契约

```text
resolveAbsolute(
    hostname,
    purpose: directTarget,
    deadline,
    familyPolicy: dual
) -> orderedUniqueNumericCandidates
```

必须使用经平台验证的绝对名称语义，避免搜索域后缀改变目标。应用层保留原始 HTTP authority；给系统解析器使用的绝对名称形式不能反过来随意改写 URL。

解析结果去重、截断到候选上限，并逐个执行数值安全检查。之后拨号必须使用已通过检查的数值 IP，不能又把原域名交给另一个会重新解析的拨号 API。

“解析一次”表示一次逻辑解析操作，不承诺系统只发送一个 DNS 数据包。系统缓存、hosts、mDNS 或平台名称服务的内部行为应由平台适配层明确记录和测试。

### 12.5 多地址连接

本配置最多保留 8 个候选，同时最多连接 2 个，候选启动间隔默认 250 ms。首个成功且通过安全检查的 TCP 连接获胜，其他尝试取消并关闭。

这些是有界候选竞速的产品参数，不等于声称完整实现了所有 Happy Eyeballs 细节。本节候选竞速只用于当前 DIRECT 目标；PROXY 使用所选 Wire 的实际端点，不允许竞速“直连和代理谁更快”。

### 12.6 解析后的安全结果

如果某些候选被禁止、其他候选允许，可以只连接允许集合；允许集合为空时返回策略拒绝。解析出的地址不产生新的 RouteDecision。

尤其禁止：

```text
检查第一次 DNS 得到公网地址
→ 实际连接时再解析一次
→ 第二次得到内网地址并直接访问
```

### 12.7 系统 DNS 超时与真实工作槽

系统解析可能无法立即取消。逻辑请求超时后，迟到结果必须丢弃，不为已关闭会话拨号；但解析工作槽要等实际底层任务退出后才释放。

不得“逻辑超时就释放并发许可、底层线程继续阻塞”，否则配置的并发限制是假的。解析任务池、等待队列和排队期限都必须有界。

### 12.8 DNS 隐私承诺的边界

本服务可验证的承诺是：**不会调用自己的 Resolver 去解析已决定 PROXY 的业务目标。**

该保证不等于整机没有 DNS：客户端预解析、节点配置装配、Wire 和系统其他进程必须分别验收。

入口将 NetworkAddress 交给 Wire，具体名称处理属于 Wire 契约；不能根据入口协议推断远端解析位置。

---

<a id="s13"></a>
## 13. DIRECT：普通 HTTP 与 CONNECT 链路

### 13.1 统一直连准备

```text
已校验的 TargetEndpoint
→ 目标为 IP：直接进入数值安全检查
→ 目标为 Domain：系统解析 → 候选去重 → 数值安全检查
→ 对允许候选执行有界 TCP 拨号
→ 返回 TargetByteStream
```

直连适配器不得自动使用操作系统配置的 HTTP / SOCKS 代理，否则可能回到自身 listener，形成递归。

### 13.2 普通 HTTP DIRECT

```text
Client             Local Proxy                       Origin
  | absolute-form      |                                |
  |------------------->| parse / auth / route DIRECT     |
  |                    | system DNS when needed          |
  |                    | TCP connect                     |
  |                    |-------------------------------->|
  |                    | origin-form + rebuilt headers   |
  |                    |-------------------------------->|
  | request body       | request body                    |
  |------------------->|-------------------------------->|
  |                    | response head / body             |
  |                    |<--------------------------------|
  | validated response |                                |
  |<-------------------|                                |
```

本服务不额外生成“代理连接成功 200”。客户端看到的是源站真实的 HTTP 响应，例如 `200`、`301`、`404` 或 `500`。

### 13.3 CONNECT DIRECT

```text
Client             Local Proxy                       Target
  | CONNECT host:443   |                                |
  |------------------->| parse / auth / route DIRECT     |
  |                    | resolve + connect               |
  |                    |-------------------------------->|
  | 200 Established    |                                |
  |<-------------------|                                |
  | TLS / arbitrary TCP bytes                            |
  |<==================>|<===============================>|
```

DIRECT 仍然由本服务转发所有隧道数据，不是把连接“还给客户端”。客户端到本服务的 socket 与本服务到目标的 socket 是两个独立连接。

### 13.4 已知成功范围

TCP connect 成功不意味着网站证书正确、应用登录成功或目标一定能返回完整内容。CONNECT `200` 仅说明本服务已经建立可使用的目标通道。

客户端在 `200` 后遭遇网站 TLS 错误，由客户端处理；本服务不把密文解析成 HTTP 错误，也不尝试改为另一条路线。

---

<a id="s14"></a>
## 14. PROXY：抽象 Wire 集成

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

<a id="s15"></a>
## 15. HTTP 语义与 Wire 载荷的边界

### 15.1 普通 HTTP

入口从 absolute URI 提取业务目标，校验并重建请求头。无论 DIRECT 还是 PROXY，提交到业务通道的普通请求都使用 origin-form；`Host` 表达业务目标。PROXY 再由 Wire 编码这些字节，HTTP 层不因节点协议而改成另一种请求形式或注入节点凭据。

Wire 解码得到的业务响应交给 HTTP 响应解析器。节点启动、认证、控制状态都由 Wire 消费，不作为源站状态行、响应头或消息体返回。

### 15.2 CONNECT 与隧道

客户端 CONNECT 在本地终止。Connection 根据解析得到的 NetworkAddress 建立 DIRECT 或 Wire 路径，满足第 14、18 节条件后生成自己的 `200 Connection Established`。不能把客户端 CONNECT 头当成具体 Wire 的启动报文。

成功回复之后的 TLS、WebSocket 或其他业务字节按隧道转发，PROXY 路径仍经过 Wire 编解码。入口不解释节点自己的响应码、地址字段或握手余量格式。

### 15.3 错误与身份隔离

Wire 失败交给 Connection 映射为本地 HTTP 错误；本地认证失败才使用本地 `407`。源站的业务状态码经业务响应流程处理，节点控制错误不能伪装为源站响应。

本地 Proxy-Authorization 在入口消费并移除。节点凭据由节点配置与 Wire 管理，源站 Authorization 保持端到端语义；三者不能相互替代或泄露。

---

<a id="s16"></a>
## 16. HTTP 响应解析、改写与返回

### 16.1 响应解码器是必要模块

普通 HTTP 不能只解析客户端请求、然后把源站响应盲目复制给客户端。至少必须解析状态行、字段、body 分帧、信息响应、连接关闭和 Upgrade。

源站响应也必须按字节增量解析，遵守独立的头部大小、字段数、时间和总缓冲限额。V1 接受源站 `HTTP/1.1` 及 `HTTP/1.0`；其他版本不按文本冒充支持。

### 16.2 状态行

接受合法状态行，状态码必须为 `100..599` 的三位数字，reason-phrase 可以为空。保留合法状态码和原因文本，但输出版本是本服务实际实现的 `HTTP/1.1`。

例如从 HTTP/1.0 源站收到响应，转给客户端时使用 HTTP/1.1 的正确 framing；追加 Via 时记录收到的协议版本，例如 `Via: 1.0 lp-http-a1`，而不是假称上游使用了 1.1。

### 16.3 响应体判定顺序

| 优先级 | 条件 | 分帧 |
|---|---|---|
| 1 | 当前响应是对 HEAD 的响应，或状态是普通 1xx、204、304 | 没有消息体；101 再检查是否为合法升级 |
| 2 | 其余响应同时含 CL / TE，或有重复/无效长度 | 严格策略拒绝，502 / 关闭 |
| 3 | 支持且合法的 `Transfer-Encoding: chunked` | chunked |
| 4 | 没有 TE、存在单个合法 Content-Length | 指定长度 |
| 5 | 其他可带 body 的响应，没有 CL / TE | 读到源站 EOF，并关闭客户端连接结束消息 |

响应语义与长度优先级见 [S01](#ref-s01)。产品还会校验禁止出现的字段，不会因为某响应无体就转发明显畸形的 framing。

### 16.4 无体响应细节

**HEAD / 304：**允许合法的单个 Content-Length 作为表示元信息，原值可保留；不能等待该数量的数据，也不能擅自改成 `0`。允许的 TE 元信息在本配置中移除，不生成 body。CL/TE 同时出现或关键字段畸形仍按严格配置拒绝。

**1xx / 204：**本配置拒绝出现 Content-Length 或 Transfer-Encoding 的无效响应，即使长度为 0。正确输出不包含这些字段，不包含 body。

**205：**不能简单塞入“与 204 相同”的解码分支。必须依通常 HTTP framing 读取零长度的内容：允许 `Content-Length: 0`、只含零块的 chunked，或 EOF 定界但实际零字节。若声称或实际携带非零内容，视为源站无效响应。不能因为看到 205 就把零块留给下一条消息。

**CONNECT 2xx：**按第 15、18 节特殊规则切换，不被上述通用 CL/TE 冲突策略覆盖。

### 16.5 Content-Length 响应

转发精确长度，body 可流式写给客户端。源站在长度未满足时 EOF / 超时，必须将响应标记为不完整并关闭客户端；不能伪造补齐内容。

收到长度之外的多余字节时，不能将其视为新响应。由于 V1 每个出站只服务一个请求，多余字节直接丢弃、关闭并记录协议异常。

### 16.6 chunked 响应

采用与请求一致的解码与重编码策略，保留 HTTP content 字节和允许的 trailer，移除已消费的原始 TE 并生成自己的 `Transfer-Encoding: chunked`。

遇到非法 chunk-size、缺失 CRLF、截断、禁止 trailer 时，不得发送一个正常结束的零块来伪装成功。如果最终响应头已经发出，只能中断客户端连接，令客户端观察到截断。

不支持的 Transfer-Encoding 在最终头提交前返回 502。`Content-Encoding: gzip` 并不触发该限制，因为它是端到端内容编码，不是 Transfer-Encoding。

响应 Trailer 采用第 09 节同样的声明、字段名和能力检查；在响应头阶段已能判断其未知、禁止或分帧不合法时，应在提交最终响应前返回 502，不等到收到 body 尾部才检查。

### 16.7 EOF 定界响应

V1 不为了保住客户端 keep-alive 而给 EOF 响应重新生成一个“成功结束”的 chunked 消息，采用更直接的策略：

```text
移除对端逐跳字段
不生成未知的 Content-Length
输出 Connection: close
转发内容直到上游 EOF
完成客户端写入后关闭客户端连接
```

EOF 定界无法仅凭正常 socket EOF 证明源站应用内容完整。遥测应记录 `completion_kind=eof_delimited`，不把它与“已验证满足 Content-Length”混为一谈。

### 16.8 响应字段

按请求方向相同原则消费逐跳字段，保留多条 Set-Cookie，不用逗号合并。保留源站 Cache-Control、Location、ETag、Content-Encoding、WWW-Authenticate 等端到端语义。

源站的 `Connection: close` 由源站连接管理消费。源站响应有准确边界且请求已完整结束时，本服务仍可对客户端保持连接。

正常源站 `401` / `WWW-Authenticate` 直接转发。V1 目标 HTTP 路径若出现 `407`，视为非预期代理认证边界，映射 `502 SOURCE_PROXY_AUTH_UNEXPECTED`，避免把源站变成本地代理的认证控制方。Wire 控制错误按第 15 节处理，不进入源站 HTTP 响应解析。

### 16.9 最终响应提交点

每个请求维护：

```text
finalResponseCommitted: Bool
finalResponseCompleted: Bool
```

在首次向客户端提交最终响应的任何字节之前，将 committed 设为 true。即使只写出半行后发生错误，也不能再发送新的 502。

100 / 102 / 103 等信息响应不算最终响应提交；101 在成功升级路径中作为不可逆的协议切换提交。

---

<a id="s17"></a>
## 17. Expect、信息响应与提前结束上传

### 17.1 Expect 支持范围

V1 只支持无参数的 `100-continue`，按大小写不敏感识别。不支持的 expectation 返回 `417 Expectation Failed` 并关闭，不发起业务出站。

CONNECT 和 WebSocket Upgrade 请求不接受 Expect；本地无体 OPTIONS 也不接受 Expect。普通请求 framing 没有 body 时，可移除无意义的 `100-continue`，不产生等待状态。

### 17.2 处理流程

```text
收到完整请求头与 Expect: 100-continue
→ 完成认证、目标、安全和路由检查
→ 如本地已可确定错误：立即返回最终错误并关闭
→ 建立出站
→ 转发请求头与 Expect
→ 立即开始读取源站响应，不等待完整上传
```

源站返回 100 时转发给客户端，随后正常上传。源站直接返回 401、413 等最终响应时，按提前响应流程结束上传。

本服务不周期性合成 100，也不靠“先把 body 全收齐”绕过机制。HTTP 代理的 Expect 行为依据见 [S02](#ref-s02)。

### 17.3 客户端不等待 100

客户端可能在没有收到 100 时就开始发送 body，或者其自身等待期限已到。只要请求通过校验，本服务按原 BodyPlan 接收并转发，不把这些字节误判为协议错误。

前期已收到的 body 必须受预读和全局缓冲预算控制。等待上游时达到限额，暂停读取客户端，而不是无限缓存。

### 17.4 信息响应

普通合法 1xx 可以在最终响应前转发，例如 100、102、103；必须有独立计数和超时，不允许对端发送无限 103 来长期占用请求。

V1 单请求最多允许 16 个信息响应。101 不是普通可重复的信息响应，必须进入第 19 节升级校验。未知合法 1xx 的通用处理不得绕过升级状态机。

### 17.5 源站提前返回最终响应

例如源站在收到请求头后立即返回 413：

```text
停止调度新的 client → origin body 写入
取消本请求剩余上传任务的生产端
继续读取并转发该最终响应
对客户端响应生成 Connection: close
响应发送完后关闭客户端与出站
```

已经进入系统发送缓冲的数据无法保证撤回，这不影响“停止新增写入”的要求。

禁止把客户端尚未消费的剩余 body 当成下一条 HTTP 请求。不得为了 keep-alive 无限制丢弃一个攻击者控制长度的上传内容。

### 17.6 计时关系

Expect 等待阶段从请求头发往源站后开始，直到收到有效的 100、最终响应，或客户端已经自行开始上传。该阶段适用 `expect_wait_ms`。

普通上传期间适用请求 body 空闲时间，不用“最终响应等待超时”误杀持续上传的大文件。完整请求已写完后，启动最终响应头等待期限。

收到普通 1xx 不重置最终响应头的绝对截止时间。每个响应头自身还有头部读取期限。

---

<a id="s18"></a>
## 18. CONNECT 成功切换、早到数据与隧道转发

### 18.1 CONNECT 不是带 body 的普通 HTTP 请求

V1 要求 CONNECT 没有请求体。头部结束后的字节视为待交接数据，不依据普通 HTTP request body 的长度规则读取它们。

允许 `Content-Length: 0` 只是兼容输入；非零长度、任何 TE 或 Expect 都拒绝。不能把 CONNECT 后面的 TLS 数据解析成第二条 HTTP 请求。

### 18.2 成功响应条件

必须同时满足：

```text
本地请求语法与目标有效
本地认证通过
安全策略允许
规则已固定
DIRECT 目标 TCP 成功，或第 14 节规定的 Wire 就绪条件满足
两侧初始余量已归属清晰
拥有隧道所需资源额度
```

随后生成自己的 HTTP 成功响应。成功响应不得包含 Content-Length 或 Transfer-Encoding；不包含普通响应 body。[S02](#ref-s02)

### 18.3 写入所有权交接

同一方向必须只有一个有序写入者：

```text
阶段 A：HTTP responder 独占 client 写方向。
阶段 B：成功响应 writeAll 完成。
阶段 C：将 client 写方向交给 upstream → client relay。
```

不得让 relay 与 `200` 响应同时向客户端写，避免上游 TLS 或其他字节插到 HTTP 头部中间。

`writeAll` 完成表示传输适配器按契约接收并保持了字节顺序，不等于网络对端已实际阅读。若成功响应的部分字节已经提交后写失败，直接终止，不再发送失败 HTTP 响应。

### 18.4 双向早到数据

需要分别保存：

```text
clientRemainder：客户端 CONNECT 头结束后同批到达的字节。
upstreamRemainder：Wire 解码后交付、尚未穿过本地成功回复屏障的业务字节。
```

在认证、路由和上游成功前，clientRemainder 不得写给目标。成功响应完成后，按原顺序先处理这些余量，再接入后续读取。

若启动失败，丢弃所属余量。Wire 控制字节始终由 Wire 消费，HTTP 层只接收解码后的业务数据。

### 18.5 隧道行为

隧道只做有序、无修改的双向传输：

```text
客户端读 → 目标写
目标读   → 客户端写
```

不解析 TLS ClientHello，不根据隧道内 HTTP Host/SNI 重新路由，不修改 ALPN，不跟随隧道内重定向，不验证网站证书。

一条 CONNECT 隧道可以承载多个应用层请求，甚至 HTTP/2 多路复用。本服务的路由仍固定为 CONNECT 声明的单一 TCP 目标，而不是对每个加密请求再分流。

### 18.6 半关闭

任一方向正常 EOF 时，先完成该方向尚未写完的数据，再调用对端 `finishWrite()`；另一方向继续读取，直到也 EOF 或半关闭排空期限到达。

错误、取消或硬资源失败使用 `abort()`。若底层 TLS 或平台 API 无法完全提供所需半关闭语义，适配层必须明确限制并通过测试，不得把 `cancel()` 冒称为保留读方向的半关闭。

### 18.7 成功以后失败的表现

进入隧道后，网络故障、超时、上游关闭等均表现为 EOF 或连接异常，不再返回 `502`、`504` 等 HTTP 文本。

向正在传输 TLS 的连接塞入 HTML 错误页既破坏协议，也可能暴露内部错误信息，明确禁止。

---

<a id="s19"></a>
## 19. WebSocket、Upgrade、HTTP/2 与 HTTP/3

### 19.1 普通 HTTP WebSocket 握手

V1 接受的显式代理请求形式为：

```http
GET http://ws.example.com/chat HTTP/1.1
Host: ws.example.com
Connection: Upgrade
Upgrade: websocket
Sec-WebSocket-Version: 13
Sec-WebSocket-Key: AAECAwQFBgcICQoLDA0ODw==

```

请求目标仍按 ordinary HTTP absolute URI 解析和路由。客户端也可以通过 CONNECT 建立 TCP 通道，再在里面做 WebSocket 握手；后者对本服务是完全不透明的。

### 19.2 入站 Upgrade 校验

要求方法为 GET、无请求体、无 Expect，Connection 包含 Upgrade，Upgrade 只请求本配置支持的 websocket。

Sec-WebSocket-Version 必须恰好出现一次且为 13；语法合法但不是 13 的版本按本产品未实现能力返回 501，重复或格式非法返回 400。Sec-WebSocket-Key 必须是恰好一个合法 Base64 值，解码为 16 字节。相关握手规则见 [S06](#ref-s06)。

合法但未支持的升级协议返回 `501`；字段缺失、冲突或格式错误返回 `400`。不得把未知 Upgrade 默认为 WebSocket。

### 19.3 发给源站

重建 origin-form，保留合法 WebSocket 握手字段、Origin、Cookie 等端到端信息；生成本跳的 Connection/Upgrade，移除本地代理认证。

本服务不自己选择子协议或压缩扩展，不替应用产生新的 Sec-WebSocket-Key。

### 19.4 响应 101 校验

必须确认该请求确实发起了 WebSocket Upgrade，并验证：

```text
status = 101
Connection 包含 Upgrade
Upgrade = websocket
Sec-WebSocket-Accept 恰好一个，并匹配原请求 key
若返回 Sec-WebSocket-Protocol，只能选择原请求提供的一个值
无被禁止的 Content-Length / Transfer-Encoding
```

Sec-WebSocket-Accept 的计算依据 [S06](#ref-s06)。本服务不解释后续帧，也不替客户端完成所有扩展语义校验；扩展协商字段保持给真正客户端检查。

在完整且合法的 101 头部发送完成后，双方余量交给 DuplexRelay。即使 101 和第一段 WebSocket 数据同批到达，也不能丢失边界后的字节。

### 19.5 非 101 与非法 101

源站返回 200、301、400、426 等非 101 最终响应时，仍是普通 HTTP 响应，按正常 framing 返回，不进入原始 relay。

未请求 Upgrade 却收到 101，或 101 内容不符合支持协议，必须在提交给客户端前返回 502。不能因“看到 101”就无条件切换协议。

### 19.6 HTTP/2

本地代理入口不提供 HTTP/2 帧解码、HPACK、扩展 CONNECT 或 h2c Upgrade。收到明确的 HTTP/2 prior-knowledge 输入时关闭，不能把它当作普通 HTTP/1.1 请求继续解析。

但客户端与网站在 CONNECT 隧道内协商 `h2` 完全可以工作，本服务只传输 TLS/TCP 字节。HTTP/2 自身的帧与流模型见 [S08](#ref-s08)。

HTTP/2 连接合并、隧道内其他 authority、应用在加密连接里访问哪些资源，不在本代理可见的逐请求路由范围内。规则只约束本服务建立的网络端点。

### 19.7 HTTP/3 / QUIC / UDP

普通 HTTP/1.1 CONNECT 提供 TCP 通道，不等同于 UDP 代理或 HTTP/3 代理。

CONNECT-UDP/MASQUE 是另外的协议能力，见 [S09](#ref-s09)。V1 不实现它们；不能根据客户端使用 HTTPS 就宣称 UDP / QUIC 同时经过本服务。

应用可能自行回退到 TCP，也可能失败或采用其他网络路径，取决于应用。该行为不能作为本服务的保证。

---

<a id="s20"></a>
## 20. 长连接、流水线、连接复用与配置快照

### 20.1 客户端连接不是目标连接

同一条客户端到本代理的 TCP 连接可以依次发送：

```text
GET http://a.example/...
GET http://b.example/...
CONNECT c.example:443
```

前两条必须分别提取目标并匹配规则，第三条在自身轮次到达后建立独立隧道。不能把所有后续字节固定转给第一个网站。

### 20.2 V1 每连接只有一个活动事务

本服务允许顺序 keep-alive，不并行执行同一客户端连接上的多个 HTTP 请求。

```text
parse request N
→ route N
→ exchange N
→ 完整接收 N 的请求边界
→ 完整发完 N 的最终响应
→ 才开始执行 request N+1
```

请求头和 body 读取仍可与同一事务的响应读取并行，不要将“事务串行”误解为“禁止双向 I/O”。

### 20.3 有界 pipelining

客户端可能提前发送下一条请求。V1 将尚未处理的字节保存在有界预读缓冲，达到高水位后停止读取，通过 TCP 背压限制发送方。

不因为两条请求合并在同一次 read 就拒绝，也不无限解析和创建后续请求对象。下一条请求的错误必须在它的响应顺序位置处理，不能抢在前一条响应之前写 400。

如果前一个事务最终要求关闭连接，则后续已预读请求丢弃，不再拨号或产生副作用。

### 20.4 客户端 keep-alive 条件

必须全部满足：

```text
客户端未发送 Connection: close 或兼容的 Proxy-Connection: close
本次请求体已完整消费，没有提前响应导致剩余 body
本次最终响应有确定边界，且已经完整写入
未发生语法/分帧/安全错误
没有进入 CONNECT 或 WebSocket relay
未达到单连接最大请求数
服务未进入停止接入或强制排空状态
```

EOF 定界响应、本地错误、请求截断、响应截断均不复用客户端连接。

### 20.5 出站不复用

V1 每个普通 HTTP 请求创建一个出站连接。事务结束后关闭；没有跨目标、跨客户端、跨认证身份或跨路由的共享源站连接池。

这是可验证性优先的产品取舍，可能增加握手开销，但可以避免把第一次请求的目标、认证和协议状态意外复用于后续请求。不得在未实现池隔离测试前偷偷启用“自动连接复用”。

CONNECT 和升级后的 WebSocket 占用自己的长期出站，不按普通 HTTP 事务结束来关闭。

### 20.6 后续连接池扩展的最低隔离键

如未来实现，池键至少包含：

```text
configSnapshotID
+ routeAction / outboundID
+ targetAddressIdentity + targetPort
+ Wire实例隔离身份
+ authenticationContext
+ HTTP transaction mode
```

域名与恰好解析到的 IP 不能自动合池；不同目标的 Wire 状态与通道不能互换。跨客户端复用需要单独评估连接绑定认证，不能仅按同一 IP:port 共享。

### 20.7 配置快照

V1 在客户端 TCP accept 时绑定不可变配置快照。该连接上的每条普通 HTTP 请求仍独立路由，但使用同一个快照。

热更新只影响新接受的连接。已有 CONNECT / WebSocket 隧道和已有 HTTP 长连接不在中途变更出口、认证或安全规则。

如必须立刻撤销用户权限或阻断旧目标，管理层要显式取消相关旧会话，不能假装仅更新配置就已经影响所有现存连接。

### 20.8 重定向与重试

本服务不自动跟随源站 Location；重定向响应交给客户端。客户端随后产生的新代理请求按正常顺序重新路由。

V1 不自动重放 HTTP 请求，无论其方法是否通常幂等。发生断线时由客户端或上层业务决定重试。拨号阶段在同一路由内尝试不同数值候选，不属于重放已发出的业务请求。

---

<a id="s21"></a>
## 21. 超时、背压、资源预算与关闭流程

### 21.1 时间基准

所有期限使用单调时钟计算，不能因系统时间校准、时区变化而延长或缩短。日志使用墙上时间，两者不可混用。

每个异步操作的实际截止时间是阶段截止时间与所属总截止时间的较小值。不能将各阶段独立超时简单相加，导致一次出站实际等待远超 `outbound_total_ms`。

### 21.2 默认时间预算

| 字段 | 默认值 | 起点与语义 |
|---|---:|---|
| `request_header_ms` | 10,000 | 首次请求从 accept 起；后续请求从轮到解析且首字节可用起，直到完整头部 |
| `client_keepalive_ms` | 60,000 | 完成事务后等待下一请求首字节的空闲期限 |
| `outbound_total_ms` | 25,000 | 开始出站准备，到 TargetByteStream 就绪的总期限 |
| `dns_ms` | 5,000 | 单次逻辑解析，包括其排队；仍受出站总期限约束 |
| `connect_attempt_ms` | 10,000 | 每个数值 IP 的 TCP 尝试 |
| `wire_start_ms` | 10,000 | Wire 所需启动处理 |
| `expect_wait_ms` | 30,000 | 发出带 Expect 的请求头后等待许可、最终响应或客户端自主上传 |
| `request_body_idle_ms` | 60,000 | 正常上传阶段，没有可推进的客户端 body 数据的期限 |
| `response_head_ms` | 10,000 | 从响应头首字节到完整头部的绝对期限 |
| `response_final_head_ms` | 30,000 | 完整请求写完后等待最终响应头；1xx 不重置 |
| `response_body_idle_ms` | 60,000 | 普通 HTTP 响应 body 无数据进展的期限 |
| `write_stall_ms` | 30,000 | 待写数据持续不能向下一跳取得进展 |
| `reply_flush_ms` | 1,000 | 本地错误或 CONNECT 成功响应的写入期限 |
| `tcp_idle_ms` | 900,000 | 隧道双向均无有效数据进展的期限 |
| `half_close_drain_ms` | 30,000 | 一侧 EOF 后等待另一侧排空 |
| `resource_wait_ms` | 1,000 | 请求等待事务等运行时额度的最长时间 |
| `shutdown_grace_ms` | 30,000 | 停机时允许活动请求 / 隧道结束的宽限期 |

这些数值是默认设计值，不是已有性能测量。部署可调整正整数值，不使用 0 暗示无限。

### 21.3 背压相关计时

当本服务主动因下游背压暂停上游读取时，不能把这段时间错误记成“上游没有发送数据”的 body 空闲超时。此时由对应写方向的 `write_stall_ms` 约束。

反过来，不能在写方向永久没有进展时不断重置空闲计时。队列入队、空 read 回调或收到与当前事务无关的字节，不算有效传输进展。

SSE、流式 API、大文件下载和长时间 WebSocket 可能需要更长的空闲预算。配置应根据业务调整，不得通过无限缓存解决超时。

### 21.4 解析限额

| 字段 | 默认值 | 计量范围 |
|---|---:|---|
| `method_bytes` | 64 | 方法 token |
| `request_target_bytes` | 8,000 | 原始 request-target 字节 |
| `request_line_bytes` | 8,192 | 请求行含 CRLF |
| `request_header_bytes` | 32,768 | 请求行、全部 header 行与最终空行的合计 |
| `response_header_bytes` | 32,768 | 单个响应头，含状态行和最终空行 |
| `header_field_bytes` | 8,192 | 单个完整字段行，含 CRLF |
| `header_fields` | 100 | 单个头部块字段条数 |
| `trailer_bytes` | 8,192 | trailer 区域含最终空行 |
| `trailer_fields` | 32 | trailer 字段条数 |
| `chunk_size_line_bytes` | 4,096 | chunk-size、extensions 及 CRLF |
| `auth_header_bytes` | 4,096 | Proxy-Authorization 整个字段值 |
| `auth_decoded_bytes` | 2,048 | Base64 解码后的上限 |

相同限制分别施加于请求和响应对应元素。响应超限不是客户端的 431，必须作为上游错误映射 502。

### 21.5 运行时额度

| 字段 | 默认值 | 语义 |
|---|---:|---|
| `tcp_sessions` | 512 | 客户端活动 TCP 会话总数 |
| `http_transactions` | 256 | 活动普通 HTTP / 正在建立的 CONNECT 或 Upgrade 请求 |
| `handshakes` | 64 | 从开始处理请求头到出站就绪 / 本地结束的协商额度 |
| `network_sockets` | 2,048 | listener、客户端、节点与候选连接等实际 socket 总预算 |
| `global_buffer_bytes` | 67,108,864 | 本核心纳管的有效用户态队列与预读缓冲预算 |

已有隧道不继续占用普通 HTTP 事务和握手额度，但必须继续占用会话、socket 和实际缓冲额度。申请、转移和释放必须由单一生命周期所有者负责。

已有 keep-alive 会话开始下一请求时要重新申请事务与握手额度。不得创建无限等待 task 作为隐形排队。

### 21.6 缓冲默认值

```text
read_chunk_bytes         = 32 KiB
prefetch_bytes           = 64 KiB / 客户端连接
early_tunnel_bytes       = 64 KiB / 每方向
direction_high_bytes     = 256 KiB / 每方向
direction_low_bytes      = 64 KiB / 每方向
```

所有上限按实际占用共享全局预算，不能为每条连接一开始就预分配最大方向缓冲。预读、HTTP 编码缓冲、尚未完成写入、初始隧道余量都需要纳入实际所有权核算。

这些数字不是整个进程 RSS 的硬上限。运行库、TLS 状态、内核 socket buffer、线程栈和配置对象需要单独观测与容量预算。

### 21.7 字节流契约

```text
read(maxBytes) -> nonEmptyBytes | EOF
writeAll(bytes) -> 完整消费该批字节，或抛错
finishWrite() -> 有序发送写方向 EOF，保持读方向可用；不支持时明确报错
abort() -> 立即中止，幂等
```

同一方向只允许一个有序写任务。writeAll 未完成时不能无限继续调用并把数据塞进 SDK 的隐藏发送队列。

达到方向高水位后暂停该方向读取；降到低水位后恢复。普通 HTTP 编码器和原始隧道 relay 都必须遵守同一背压契约。

### 21.8 公平性与 CPU

不能对慢 socket 忙轮询，也不能用无限 Task 数量替代非阻塞 I/O。一次事件循环处理应有字节/事件预算，防止单条大量小 chunk 的请求独占执行器。

协议解析、DNS 阻塞调用、日志写盘和 UI 更新不能混在同一关键执行路径上。DNS 阻塞接口需要隔离工作池。

### 21.9 关闭和清理

所有关闭路径最终执行幂等清理，关闭剩余候选 socket、取消计时器、释放额度、清空缓冲并提交一次会话结束事件。

普通 HTTP 完成、正常 EOF、客户端取消、上游错误、资源超限和停机都不能各自实现一套不一致的资源释放逻辑。

### 21.10 优雅停机

```text
停止接受新连接
→ 空闲 keep-alive 连接立即关闭
→ 活动普通 HTTP 响应尽可能加入 Connection: close
→ 不再执行已预读的后续请求
→ 允许当前事务 / 隧道在宽限期内完成
→ 截止后取消全部剩余会话
→ 等待可释放的任务和资源归还
```

已经提交的响应头不能事后修改。若无法再添加 Connection: close，可在该消息正确结束后关闭连接。尚未退出的不可取消系统解析任务应继续计入真实工作槽，不能伪造“所有任务已退出”。

---

<a id="s22"></a>
## 22. 安全边界与防绕过要求

### 22.1 请求走私与解析差异

必须拒绝或严格限定：CL/TE 混用、重复长度、Host 重复、非法空白、obs-fold、字段名注入、裸 CR/LF、非法 chunk 编码以及 Connection 指名关键字段。

发给下一跳的报文必须由已验证的结构重编码，而不是把未经校验的头部片段直接拼接到新请求中。相关风险背景见 [S01](#ref-s01)。

不能通过“反正 V1 不复用上游连接”省略这些检查；客户端连接仍可能复用，解析差异也可能影响源站安全。

### 22.2 目标安全检查的两个阶段

```text
阶段 1：解析出的原始 Domain / IP + port，无需 DNS。
阶段 2：仅对 DIRECT 域名的每个数值解析候选执行地址检查。
```

规则里的 DIRECT 或 PROXY 不能覆盖强制安全拒绝。`REJECT` 之后不执行网络探测。

### 22.3 固定禁止的数值类别

V1 无条件禁止业务目标使用 IPv4 的 `0.0.0.0/8`、有限广播地址 `255.255.255.255`、多播地址 `224.0.0.0/4`，以及 IPv6 未指定地址 `::`、多播地址 `ff00::/8`。

此外默认：

```text
allow_private_targets    = true
allow_loopback_targets   = false
allow_link_local_targets = false
```

private 在本配置中精确定义为 RFC1918 三段 IPv4 与 IPv6 ULA `fc00::/7`，不是所有“非公网”地址的统称。需要拒绝其他网段，例如共享地址空间，应写入 `deny_cidrs`。

loopback 包括 `127.0.0.0/8` 与 `::1`；link-local 包括 `169.254.0.0/16` 与 `fe80::/10`。数值分类必须使用二进制地址，不用字符串前缀判断。

### 22.4 自回环保护

本服务所有真实监听端点都必须进入自回环禁止集合，包含 HTTP、同进程其他 SOCKS listener、通配绑定对应的本机接口地址，以及用户显式声明的 `additional_self_endpoints`。

检查适用于：

```text
DIRECT 数值业务目标
DIRECT 域名解析候选
Wire 提供的实际节点端点
```

即使用户允许普通 loopback 目标，也不能关闭自回环保护。通配监听不能只用 `0.0.0.0:1087` 与实际拨号地址做字符串相等比较。

本机网卡变化时，适配层要刷新本机地址集合，并在实际拨号前检查最新端点事实。此类 socket 安全事实更新不意味着重新选择路由。

### 22.5 CONNECT 端口限制

默认允许 CONNECT 到 `80`、`443`。其他端口必须显式加入 `connect_allowed_ports`。这是产品防滥用策略，不是 HTTP CONNECT 只能使用这些端口。[S02](#ref-s02)

允许某个端口不证明里面实际传输 HTTP 或 TLS；代理不检查隧道载荷。允许 22、25、数据库端口等会扩大客户端可访问的服务范围，需独立授权。

普通 HTTP 请求的目标端口也必须合法并经过地址安全检查，但不自动套用 CONNECT-only 端口表。

### 22.6 域名 PROXY 的远端地址边界

本服务不解析 PROXY 业务域名，因此不能在本地证明上游解析出的地址一定不是私网、loopback 或其他受限地址。

```text
可保证：本地不解析目标，原始数值目标经过本地安全策略。
不可仅由本地保证：远端将一个域名解析为哪个 IP，以及远端的网络隔离。
```

需要约束上游访问范围时，上游节点也必须实施目标 ACL / 出站安全策略。不能为了补上这一保证，暗中对 PROXY 域名执行本地 DNS。

### 22.7 不受信任输入不能变成配置

HTTP 请求中的 Host、Via、Proxy-Authorization、路径参数或任意自定义头都不能指定新的上游地址、切换出站协议、关闭证书校验或改写路由默认动作。

上游代理地址与凭据只来自经过校验的配置快照。禁止自动采用 HTTP 重定向来变更代理节点。

### 22.8 回环不等于应用身份认证

绑定回环只限制网络来源，不等于只允许本应用或当前某个浏览器使用。本机其他进程、其他用户上下文或受控应用是否可访问，要通过实际系统权限与本地认证策略确定。

V1 不声称从 TCP peer 自动识别进程身份，也不在普通 HTTP 代理端口暴露未认证的管理 API、配置修改接口或凭据查询接口。

### 22.9 无隐式回退

以下情况均不能触发 DIRECT：节点无法连接、Wire 启动或编解码失败、目标不可达、能力不支持、流量传输中断。

客户端看到失败，也不能因此在代理内部悄悄换一个不受同等策略约束的目标或节点。

---

<a id="s23"></a>
## 23. 错误模型与 HTTP 状态码映射

### 23.1 结构化错误

```text
ProxyError {
    code,
    stage: admission | parse | auth | target | route | dns |
           nodeConnect | wireStart | wireCodec | httpExchange | relay,
    publicHTTPStatus?,
    retryableForCaller,
    underlyingCode?,
    requestID,
    finalResponseCommitted,
    tunnelEstablished
}
```

`retryableForCaller` 只是对调用者的提示，不能授权代理自动重放请求。底层没有足够信息时，不得编造 NXDOMAIN、连接拒绝或证书失败等具体原因。

### 23.2 映射表

| 情形 | 错误码示例 | 状态 / 动作 |
|---|---|---|
| 请求行、Host、authority、端口语法非法 | `MALFORMED_REQUEST` | 400 |
| CL/TE 冲突、重复 CL、无效 chunk | `INVALID_REQUEST_FRAMING` | 400 |
| 认证字段格式非法 | `MALFORMED_PROXY_AUTH` | 400 |
| 本地认证缺失或凭据错误 | `LOCAL_AUTH_REQUIRED` | 407 + 本地挑战 |
| 请求头 / 请求 body 等待超时 | `CLIENT_REQUEST_TIMEOUT` | 408，尚未提交最终响应时 |
| request-target 超长 | `REQUEST_TARGET_TOO_LONG` | 414 |
| Expect 能力不支持 | `EXPECTATION_UNSUPPORTED` | 417 |
| 请求字段数量或头部超限 | `REQUEST_HEADERS_TOO_LARGE` | 431 |
| 方法 token 长于实现允许上限 | `METHOD_UNSUPPORTED` | 501 |
| 功能 / scheme / 传输编码未实现 | `FEATURE_UNSUPPORTED` | 501 |
| 入站 HTTP 版本不支持 | `HTTP_VERSION_UNSUPPORTED` | 505 |
| REJECT / 目标或 CONNECT 端口策略拒绝 | `ROUTE_REJECTED` / `TARGET_DENIED` | 403 |
| 自回环 / 已有 Via 标识 | `PROXY_LOOP_DETECTED` | 502 |
| 目标 DNS 不存在、临时解析失败、无地址 | `TARGET_RESOLUTION_FAILED` | 502 |
| DNS / 出站 / 上游响应等超时 | 对应阶段 `*_TIMEOUT` | 504 |
| TCP 拒绝 / 网络不可达 / Wire 启动失败 | 对应 `CONNECT_FAILED` / `WIRE_START_FAILED` | 502 |
| Wire 报告认证或控制错误 | 保留原始错误，标记 Wire 阶段 | 502，不发送本地 407 |
| 源站响应头非法或超限 | `INVALID_UPSTREAM_RESPONSE` | 502 |
| 全局额度耗尽 / 请求等待许可超时 | `RESOURCE_EXHAUSTED` | 503 |
| 服务停止接入 | `SERVICE_DRAINING` | 503 或直接关闭尚未解析连接 |
| 客户端已断开 | `CLIENT_DISCONNECTED` | 关闭出站，不尝试回复 |
| 最终响应已部分提交后失败 | 对应错误 | 关闭，禁止追加第二个响应 |
| CONNECT / WebSocket 已建立后失败 | 对应 relay 错误 | EOF / abort，不插入 HTTP 文本 |

源站真实返回的业务状态，如 404、429、500、503，不由本表覆盖，也不触发路由回退；它们是普通源站响应。

### 23.3 本地错误响应模板

V1 本地错误默认使用零长度 body：

```http
HTTP/1.1 403 Forbidden
Content-Length: 0
Cache-Control: no-store
Connection: close

```

407 另加本地 Proxy-Authenticate。其他本地错误不包含节点凭据、底层系统路径、原始请求头或上游错误页。

实际生成本地响应时，在时钟可靠的情况下生成正确的 Date；本文报文展示可省略 Date，以突出协议边界。编码器必须输出 CRLF，并保证末尾完整空行。

### 23.4 错误可写性

```text
if tunnelEstablished or finalResponseCommitted:
    abortOrClose()
else if clientWritable and errorHasHTTPMapping:
    commitExactlyOneErrorResponse()
    closeAfterFlushOrTimeout()
else:
    abortOrClose()
```

已转发 100 或 103 但尚未提交最终响应时，仍可以返回一个最终 502。已开始写 200 / 404 / 101 的任何字节后则不能。

### 23.5 不复用失败连接

任何本地错误响应之后关闭客户端，避免未消费 body、未知余量或解析失败状态影响下一条请求。对端错误响应如果是正常、完整的源站 HTTP 响应，不自动等同于本地解析失败。

当请求体在一部分内容已交付源站后才被发现非法，不能承诺撤销源站已发生的业务操作。需要记录 `request_partially_forwarded=true`，但仍禁止继续转发或重试。

---

<a id="s24"></a>
## 24. 完整配置示例与配置校验

### 24.1 配置定位

以下是 HTTP-PROXY-V1 的完整生效配置示例，不是现成第三方软件可直接读取的配置文件。它定义本项目配置接口，需要由本项目实现对应 loader 和 validator。

示例默认直连，仅匹配的测试目标选择 PROXY 节点引用；实际节点与 Wire 由运行配置装配，不假设固定端口运行任何特定服务。

<a id="config-example"></a>
### 24.2 完整 JSON

```json
{
  "schema_version": 1,
  "profile": "http-proxy-v1",
  "listener": {
    "id": "http-local",
    "tcp": {
      "hosts": [
        "127.0.0.1",
        "::1"
      ],
      "port": 1087
    },
    "auth": {
      "mode": "none"
    },
    "access": {
      "allow_lan": false,
      "client_cidrs": [],
      "allow_cleartext_lan_auth": false
    }
  },
  "http": {
    "version": "1.1",
    "allow_origin_form": false,
    "allow_absolute_https": false,
    "websocket_upgrade": true,
    "upstream_pooling": false,
    "max_requests_per_connection": 1000,
    "max_informational_responses": 16,
    "via_name": "lp-http-a1",
    "trailer_allowlist": [
      "content-digest",
      "repr-digest",
      "digest",
      "server-timing"
    ]
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
        "id": "proxy-named-domain",
        "match": {
          "domain_suffix": [
            "proxy.example"
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
    "deny_cidrs": [],
    "connect_allowed_ports": [
      80,
      443
    ],
    "additional_self_endpoints": []
  },
  "dialing": {
    "parallel_candidates": 2,
    "candidate_stagger_ms": 250
  },
  "timeouts": {
    "request_header_ms": 10000,
    "client_keepalive_ms": 60000,
    "outbound_total_ms": 25000,
    "dns_ms": 5000,
    "connect_attempt_ms": 10000,
    "wire_start_ms": 10000,
    "expect_wait_ms": 30000,
    "request_body_idle_ms": 60000,
    "response_head_ms": 10000,
    "response_final_head_ms": 30000,
    "response_body_idle_ms": 60000,
    "write_stall_ms": 30000,
    "reply_flush_ms": 1000,
    "tcp_idle_ms": 900000,
    "half_close_drain_ms": 30000,
    "resource_wait_ms": 1000,
    "shutdown_grace_ms": 30000
  },
  "limits": {
    "method_bytes": 64,
    "request_target_bytes": 8000,
    "request_line_bytes": 8192,
    "request_header_bytes": 32768,
    "response_header_bytes": 32768,
    "header_field_bytes": 8192,
    "header_fields": 100,
    "trailer_bytes": 8192,
    "trailer_fields": 32,
    "chunk_size_line_bytes": 4096,
    "auth_header_bytes": 4096,
    "auth_decoded_bytes": 2048,
    "tcp_sessions": 512,
    "http_transactions": 256,
    "handshakes": 64,
    "network_sockets": 2048,
    "global_buffer_bytes": 67108864
  },
  "buffers": {
    "read_chunk_bytes": 32768,
    "prefetch_bytes": 65536,
    "early_tunnel_bytes": 65536,
    "direction_high_bytes": 262144,
    "direction_low_bytes": 65536
  },
  "telemetry": {
    "log_level": "info",
    "target_log_mode": "hash",
    "payload_logging": false,
    "metrics_enabled": true
  }
}
```

### 24.3 顶层字段契约

| 字段 | 契约 |
|---|---|
| schema_version / profile | 必须分别为 1 / http-proxy-v1 |
| listener | 必须完整定义 ID、TCP、认证与访问控制 |
| http | HTTP 特有严格配置与能力开关 |
| routing | 显式默认动作、规则数组和禁用解析式 IP 路由 |
| resolver | 只接受 system / absolute / system_only 的 V1 模式 |
| outbounds | ID 唯一的上游数组；可以为空，但所有 PROXY 引用必须能解析 |
| security | 安全策略独立于路由，不能被普通规则覆盖 |
| dialing | 正整数并发候选数、非负候选间隔 |
| timeouts | 正整数毫秒；不允许未知时间单位 |
| limits / buffers | 整数计量，明确字节与数量含义 |
| telemetry | 日志等级、目标脱敏、载荷禁录与指标开关 |

默认值允许由 loader 补齐，但导出“生效配置”必须完整。解析 JSON 时必须拒绝重复对象键；不能任由不同 JSON 库选择 first-wins / last-wins。

所有层级未知字段必须报错，而不是无声忽略。密码引用解析失败、出站引用无效、listener 重复等属于配置失败，禁止带病启动。

### 24.4 HTTP 固定值与开关

```text
version 必须为 "1.1"
allow_origin_form 必须为 false
allow_absolute_https 必须为 false
upstream_pooling 必须为 false
max_requests_per_connection 必须为正整数
max_informational_responses 必须为正整数
via_name 必须是非空 ASCII token
```

`websocket_upgrade=false` 可用于主动关闭已实现的 WebSocket Upgrade 能力，对此类请求返回 501；不影响 CONNECT 隧道内不透明的 WebSocket。

`trailer_allowlist` 必须是第 09 节固定支持集合的无重复子集；空集合表示不接受非空 trailer。不能通过加入 Host 或未知字段来绕过 trailer 校验。

### 24.5 本地 Basic 认证替换片段

用以下对象替换 `listener.auth`，其余配置不变：

```json
{
  "mode": "basic",
  "realm": "Local HTTP Proxy",
  "users": [
    {
      "username": "local-user",
      "password_ref": "keychain:local-proxy/http/local-user"
    }
  ]
}
```

`mode=none` 禁止混入 realm/users。Basic 模式必须有非空用户数组，用户名唯一；用户名 UTF-8 为 1..255 字节，密码解析后为 1..1024 字节，且符合第 10 节字符限制。

realm 必须是受限 ASCII 可打印文本；编码器正确转义 quoted-string 中的反斜线与双引号，禁止 CR/LF。不能把未转义配置直接插入 Proxy-Authenticate。

### 24.6 节点引用与 Wire 配置边界

出站配置在本文只表示对运行配置中节点的引用。`outbounds` 示例中的 `id` 由配置装配层关联到模型规定的节点 UUID；这些示例是入口策略资料，不是完整节点配置，也不是新增的 Magent 公共配置 API。

Core 根据引用选择可用 Wire；具体节点协议、凭据、启动参数和端点构造由节点模型及 Wire 配置负责。入口不得增加自己的出站 `type`、认证方法、传输协议或远端控制消息字段。默认节点和规则引用的校验时机遵循模型规范；选中后不可用必须失败，不能解释为 DIRECT。

运行时连接实际节点端点前仍须执行适用的端点安全检查。节点域名如需预先解析，由配置装配边界完成；入口只消费 Core / Wire 提供的实际端点，不为代理业务目标执行本地 DNS。

### 24.7 安全字段

`connect_allowed_ports` 接受非空的端口 / 闭区间数组，与 routing.ports 使用相同解析规则。`deny_cidrs`、`client_cidrs` 必须是有效且网络部分规范化的 CIDR。

`additional_self_endpoints` 的每项只能包含 `address` 和 `port`；address 必须是数值地址，port 为 1..65535。该字段是额外禁止集合，不代替自动收集真实 listener。

`deny_self_endpoints` 必须为 true。节点端点授权与业务目标的 loopback/private 策略分开，不能互相替代；具体 Wire 的安全配置不在本节定义。

### 24.8 跨字段检查

必须至少校验：

```text
请求行限制足以容纳最大目标、最大方法、版本和分隔符。
请求 / 响应头限制不小于对应单行限制。
0 < direction_low_bytes < direction_high_bytes。
read_chunk_bytes 不大于 direction_high_bytes。
单个配置允许的必要头部和传输缓冲能够落入全局预算。
http_transactions 不大于 tcp_sessions。
handshakes 不大于 tcp_sessions。
parallel_candidates 不大于 resolver.max_candidates。
每个 PROXY outbound 存在且支持 TCP。
非回环监听满足 LAN ACL 与认证条件。
节点不能直接指向本服务 listener；域名节点在拨号时再做数值检查。
所有规则 ID、出站 ID、listener ID 均非空且在各自命名空间唯一。
所有秘密引用满足相应认证协议的实际字节长度限制。
```

`transport=udp` 的共享规则在 HTTP-only profile 中只产生不可达规则警告，不创建 UDP socket。入口只引用节点；Wire 能力按共享契约校验，具体节点配置不由 HTTP profile 解释。

### 24.9 原子更新

```text
读取完整新配置
→ 严格结构校验
→ 编译规则
→ 解析必要秘密引用与能力校验
→ 构造不可变快照
→ 原子发布
```

失败时保留旧快照并返回清楚的配置错误。不能更新了一半规则后才发现节点不存在。外部节点暂时不可达不等于 JSON/schema 无效；它在运行时产生节点连接失败，不授权直连回退。

listener 地址/端口变更需要独立的绑定与回滚事务，不能与纯路由快照更新混为一谈。

---

<a id="s25"></a>
## 25. 日志、指标与问题定位

### 25.1 请求日志最小字段

```text
wall_time
session_id / request_id / sequence_number
listener_id / config_snapshot_id
mode = forward_http | connect | websocket | local_options
method
address_type / target_port
route_action / matched_rule_id / outbound_id
resolver_purpose / resolver_called
stage / error_code
http_status_source = local | origin | upstream_mapping
http_status
request_partially_forwarded
final_response_committed / tunnel_established
duration_ms / close_reason
```

普通 HTTP 按请求记录；CONNECT / WebSocket 按建立事件与最终会话结束记录。不要在正常每次 read/write 时写一条 info 日志。

### 25.2 目标隐私

默认 `target_log_mode=hash`，记录使用私有密钥的 HMAC 派生标识，而不是裸域名的普通 SHA256；字典可枚举的域名不能靠无盐哈希获得充分隐藏。

密钥不得进入配置导出或日志，轮换策略由运行环境管理。明确启用诊断模式时才可记录完整目标，仍不得记录用户凭据、Cookie、完整 Query 或 body。

`payload_logging` 在本 profile 中必须为 false。调试 HTTP 头时必须进行字段级脱敏，不能只把密码字符串替换一次就认为整个报文已经安全。

### 25.3 字节统计口径

至少分别统计：

```text
http_request_content_bytes
http_response_content_bytes
client_wire_bytes_read / written
outbound_wire_bytes_read / written
tunnel_payload_bytes_up / down
```

HTTP content 统计排除 chunk-size、CRLF 与首部；wire 统计包含对应连接上的协议开销。隧道 payload 从协议交接余量与后续 relay 数据开始，不包含本地 CONNECT 头和上游握手。

不能拿两种不同口径的数值作“丢包/漏字节”判断。

### 25.4 指标

| 类型 | 建议指标 |
|---|---|
| 当前数量 | 会话、活动事务、握手、socket、DNS 工作槽、DNS 排队 |
| 内存压力 | 全局纳管缓冲、方向高水位次数、暂停读取次数 |
| 总数 | 请求、路由动作、CONNECT 成功/失败、认证失败、协议拒绝 |
| 延迟 | 头部解析、路由、DNS、节点连接、握手、首个最终响应、事务总耗时 |
| 关闭原因 | 正常消息结束、EOF、超时、取消、截断、资源不足、停机 |

指标标签只使用有界集合，例如动作、模式、错误阶段与配置中的有限 outbound ID。禁止把完整域名、URL、request ID 或任意用户名作为时序标签。

### 25.5 DNS 验证

对一个明确匹配 PROXY 的域名请求，必须能观察：

```text
route_action = PROXY
resolver_called(directTarget) = false
Wire.start target = NetworkAddress(domain, port)
```

节点配置装配中的名称解析与入口目标 DNS 分开记录。网络观测须明确进程及层次范围，不能以入口日志代替整机解析行为证据。

### 25.6 故障定位顺序

从 request ID 依次判断：请求是否完整解析、目标来源是否正确、认证是否成功、命中哪条规则、是否调用了不该调用的 DNS、节点连接是否完成、Wire 是否就绪及必要控制输出是否写完、最终响应是否已提交、最后在哪里停止进展。

“curl 看到 502”不足以判定原因。日志应能区分本地 DNS、节点 DNS、节点连接拒绝、上游认证失败、源站无效响应和成功后的隧道断线。

---

<a id="s26"></a>
## 26. Swift 实施结构与接口契约

### 26.1 模块边界

MagentTCPConnection 拥有 accepted Channel 与协议探测；HttpConnectConnection / HttpForwardConnection 拥有入口语义、下游 Channel 和本地回复；MagentCore 负责路由与 Wire 选择；Wire 负责出站启动及编解码。

HTTP 模型和目标地址采用 MODELS_SPEC.md 的契约。HTTP 不复制节点模型、具体出站 connector、规则引擎或 DNS 策略；本地 UI、系统代理设置和凭据存储由应用负责。

### 26.2 增量解码器契约

下列为语言无关的接口草案，不是已经实现的可编译 Swift 服务：

```text
feed(bytes: BorrowedBytes) -> DecodeResult {
    consumed: Int,
    events: [Event],
    disposition: needMore | paused | switchedProtocol | failed
}

RequestEvent =
    head(ValidatedRequestHead)
  | body(BorrowedBytes)
  | trailers(ValidatedHeaderFields)
  | end

ResponseEvent =
    informational(ValidatedResponseHead)
  | finalHead(ValidatedResponseHead)
  | body(BorrowedBytes)
  | trailers(ValidatedHeaderFields)
  | end
  | upgrade(ValidatedUpgradeHead)
```

`consumed` 必须表示真实消费的输入字节数，不能把剩余字节默认为“下一次网络读取会重新给我”。`BorrowedBytes` 的有效期必须明确；跨异步调用保存时必须取得受预算管理的所有权。

解析器每次返回都必须满足以下之一：消费了字节、产生了可处理事件、改变了状态，或明确等待更多输入。不得在空进展状态忙循环。

头部事件与 body 事件之间应允许暂停。运行时完成头部验证、认证、分流及额度申请之前，不能任由解析器无限生产 body 事件并在队列里积压。

### 26.3 出站与流接口

Connection 按第 14 节持有 Channel 和可选 Wire。普通 HTTP 与 CONNECT 共用路由、节点端点和启动顺序；普通 HTTP 随后运行消息转发，CONNECT 则在本地成功回复完成后进入隧道。

PROXY 的写入调用 encodeOutbound，读入调用 decodeInbound；纯业务余量由 Connection 有界保存。具体协议控制余量留在 Wire 内部。不可将一个仍需入口解析节点握手的 Channel 宣称为已就绪业务通道。

### 26.4 HTTP 事务的并发职责

```text
HTTPClientSession
  ├─ 一个客户端读取拥有者
  ├─ 一个串行的请求序号调度器
  ├─ 至多一个活动 HTTPTransaction
  │    ├─ 请求体上传任务
  │    ├─ 上游响应读取任务
  │    └─ 一个客户端响应写入拥有者
  └─ 切换成功后由 TunnelRelay 接管读写权
```

上传与响应读取可以并发，客户端上的两个 HTTP 请求不能在 V1 并发执行。HTTP 头、信息响应、最终响应、错误响应与隧道前导数据必须经过同一个有序写入机制。

任务取消必须向整个事务传播；同时出现超时、EOF 与取消时，由一个状态所有者作出唯一终结决定。清理可以重复调用，但 socket 关闭、许可释放和统计结算只能发生一次。

使用 Swift actor 可以实现状态隔离，但不能假定每个 `await` 前后的状态都不变。跨挂起点回来后，应确认事务仍处于允许该操作的状态，防止已超时的连接再次写成功响应。

### 26.5 Channel 与 HTTP 编解码

网络资源使用 Magent 管理的 SwiftNIO EventLoopGroup 与 Channel；HTTP codec 的官方入口见 [S12](#ref-s12)。Wire 只做出站启动和编解码，不引入第二套网络资源所有权。

选用现成 HTTP codec 时，必须检查它对重复 Content-Length、CL/TE、CONNECT 升级、额外字节保留、Trailer 和 HTTP/1.0 的实际行为。库的默认兼容策略不一定等于本 profile 的严格策略；差异必须在适当层拒绝或通过配置收紧。

不能先让底层库把重复字段合并成单个值，再希望上层判断原始报文有没有重复。也不能在切换 pipeline 时丢掉解码器已经缓存的 TLS / WebSocket 字节。

依赖选择的验收依据是本文的报文与生命周期测试，而不是“这个框架应该已经处理了”。

### 26.6 库与宿主边界

网络权限、打包、持久化、UI 和系统代理集成属于宿主应用文档，不是入口协议前提。

系统解析可能阻塞，因此不能直接阻塞 EventLoop 或承载大量连接的串行执行器；同步解析必须有真实工作槽限制。底层连接不得隐式再次使用本服务作为代理。

协议测试不依赖平台凭据存储、系统代理设置、外部 DNS 或 UI；实际部署行为由集成测试单独验证。

### 26.7 所有权检查表

实现审查至少能回答以下问题：某个 byte buffer 目前属于谁；哪个任务拥有 socket 的读权和写权；何时进入最终响应提交状态；升级时谁接收未消费字节；超时后谁释放实际 DNS 工作槽；关闭后哪条路径阻止迟到回调再次拨号。

任何问题只能回答“多个地方都可能处理”时，应先明确仲裁者，再编写并发逻辑。

---

<a id="s27"></a>
## 27. 端到端报文示例与调试命令

### 27.1 示例约定

本章的 `http` 代码块用于展示字段和空行；真实线上报文的行结束必须是两个字节 `\r\n`。需要逐字节断言的测试应使用显式 bytes，而不是依赖编辑器保存的换行格式。

域名、IP、代理端口与响应载荷是示例，不保证外部站点具有对应接口。可重复验收应使用受控 fixture 和可注入的 Resolver / Connector，不以公共网站是否在线作为唯一判据。

### 27.2 普通 HTTP：绝对 URI 转源站路径

客户端发给本服务：

```http
GET http://www.example.com:8080/a%2Fb?x=1&x=2 HTTP/1.1
Host: ignored.example
Connection: keep-alive

```

提取和决策：

```text
TargetEndpoint = Domain("www.example.com"), port 8080
目标来源 = absolute URI；不是 Host: ignored.example
request-target 给源站 = /a%2Fb?x=1&x=2
DIRECT：系统解析 www.example.com，以验证后的数值地址拨号。
PROXY：向所选 Wire 提交逻辑目标 www.example.com:8080，启动就绪后写入重建的源站请求。
```

两条路线在目标 stream 建立后，发给源站的 HTTP 头都可以是：

```http
GET /a%2Fb?x=1&x=2 HTTP/1.1
Host: www.example.com:8080
Via: 1.1 lp-http-a1
Connection: close

```

源站响应示例：

```http
HTTP/1.1 200 OK
Content-Length: 5
Content-Type: text/plain
Connection: close

hello
```

本服务保持客户端连接时，返回可为：

```http
HTTP/1.1 200 OK
Content-Length: 5
Content-Type: text/plain
Via: 1.1 lp-http-a1

hello
```

示意代码块中 `hello` 后的排版换行不属于 Content-Length 的 5 个内容字节。源站连接关闭不等于客户端连接必须关闭；本例响应长度明确，可继续处理下一条客户端请求。

### 27.3 CONNECT 经抽象 Wire

客户端请求：

```http
CONNECT example.com:443 HTTP/1.1
Host: example.com:443

```

Connection 构造 `NetworkAddress(host: "example.com", port: 443)`，Core 选定 Wire。Connection 连接其实际节点端点，将业务目标交给 WireResult 与下游输入推进启动；入口不发送目标 DNS 请求，也不规定节点线上字节。

WireResult.ready=true 且必要控制输出写完后，本地生成：

```http
HTTP/1.1 200 Connection Established

```

随后客户端业务字节经 Wire 编码写到节点，节点字节经同一 Wire 解码后返回客户端。目标 TLS 握手仍属于客户端与目标之间的业务数据，HTTP 入口不解密或重新生成它。

### 27.4 Content-Length 与下一条请求粘包

下面是精确的 Python bytes 测试向量：

```python
wire = (
    b"POST http://upload.example/data HTTP/1.1\r\n"
    b"Host: upload.example\r\n"
    b"Content-Length: 5\r\n"
    b"\r\n"
    b"hello"
    b"GET http://next.example/ HTTP/1.1\r\n"
    b"Host: next.example\r\n"
    b"\r\n"
)
```

第一条请求 body 恰为 `hello`。后面的 `GET` 不能被上传到第一个源站，且只有前一事务完成后才能进入下一次执行。两个请求分别进行目标提取与路由。

### 27.5 chunked 与 Trailer

```python
wire = (
    b"POST http://upload.example/data HTTP/1.1\r\n"
    b"Host: upload.example\r\n"
    b"Transfer-Encoding: chunked\r\n"
    b"Trailer: Server-Timing\r\n"
    b"\r\n"
    b"4;tag=demo\r\nWiki\r\n"
    b"5\r\npedia\r\n"
    b"0\r\n"
    b"Server-Timing: upload;dur=1\r\n"
    b"\r\n"
)
```

解码内容是 9 个字节的 `Wikipedia`；`tag=demo` 不传递为业务内容。消息在 Trailer 之后的最终空行结束，不是在 `0\r\n` 结束。

转发时允许重新分块，例如一个 9 字节块，但内容字节和允许的 Trailer 字段语义必须保持。该例只测试代理的传输行为，不表示源站必须理解此处的 Server-Timing 用途。

### 27.6 WebSocket 握手与切换

客户端请求示例：

```http
GET http://ws.example/chat HTTP/1.1
Host: ws.example
Connection: Upgrade
Upgrade: websocket
Sec-WebSocket-Version: 13
Sec-WebSocket-Key: AAECAwQFBgcICQoLDA0ODw==

```

本服务重写为 origin-form 并保留经过验证的 Upgrade 语义。相应成功响应的核心字段为：

```http
HTTP/1.1 101 Switching Protocols
Connection: Upgrade
Upgrade: websocket
Sec-WebSocket-Accept: Bz3qJYTGdOe8gUSpLosEdiLKDrk=

```

该 Accept 与上述 key 的对应关系必须按 WebSocket 握手算法验证；生产转发还应按第 08、16、19 节添加本代理 Via 并处理逐跳字段。[S06](#ref-s06)

成功后不得把 WebSocket frame 当下一条 HTTP 请求，也不应自行给客户端 frame 去掩码后再转发。本服务在此模式下转发原始字节。

### 27.7 错误响应：本地认证与上游认证必须不同

本地 Basic 认证未通过时：

```http
HTTP/1.1 407 Proxy Authentication Required
Proxy-Authenticate: Basic realm="Local HTTP Proxy", charset="UTF-8"
Content-Length: 0
Connection: close

```

Wire 报告节点认证或启动失败时：

```http
HTTP/1.1 502 Bad Gateway
Content-Length: 0
Connection: close

```

第二种情况不能要求客户端输入本地密码来“修复节点认证”，更不能回退直连。上述响应省略可选诊断字段；本地生成响应的其他通用要求仍见第 23 节。

### 27.8 curl 调试

普通 HTTP，强制不使用环境变量中的 bypass 列表：

```sh
curl --verbose --noproxy "" \
  --proxy http://127.0.0.1:1087 \
  http://example.com/
```

HTTPS 网站，通过本地 HTTP CONNECT：

```sh
curl --verbose --noproxy "" \
  --proxy http://127.0.0.1:1087 \
  https://example.com/
```

对 HTTP 目标也明确使用 CONNECT 隧道：

```sh
curl --verbose --noproxy "" --proxytunnel \
  --proxy http://127.0.0.1:1087 \
  http://example.com/
```

启用本地 Basic 认证时，让 curl 交互提示密码，而不是把密码写入命令历史：

```sh
curl --verbose --noproxy "" --proxy-basic --proxy-user local-user \
  --proxy http://127.0.0.1:1087 \
  https://example.com/
```

以上 curl 参数行为以官方手册为依据。[S14](#ref-s14) 日志可能包含敏感 HTTP 字段，诊断输出分享前必须脱敏。测试网站 TLS 失败时，不应把关闭证书校验作为代理实现的修复方案。

注意第二条命令的 `--proxy` 仍然是 `http://`：它描述“客户端如何连接本地代理”，不是目标网站的 scheme。使用 `--proxy https://127.0.0.1:1087` 会要求本地 listener 支持 TLS，而 V1 不支持。

### 27.9 可运行的本地拒绝路径冒烟脚本

以下脚本只验证一个**已经由你实现并运行**的服务，不会替你创建 HTTP 代理。要求服务采用第 24 节的示例策略：本地免认证、`blocked.example` 拒绝、CONNECT 端口仅允许 80/443；端口可通过参数修改。

测试均应在业务出站前结束。默认目标域名不会实际被访问；要证明“没有 DNS / 没有拨号”，仍须结合第 28 节的可注入依赖或调用计数。

将以下代码保存为脚本后，可执行 `python3 smoke_http_proxy.py --port 1087`。它是本单文件中的嵌入式辅助代码，不是额外交付的文件。

```python
#!/usr/bin/env python3
"""Checks rejection/local-response paths of an already running proxy."""
from __future__ import annotations

import argparse
import math
import re
import socket
import sys
import time

MAX_RESPONSE_HEAD = 32768


def request(method: bytes, target: bytes, headers: list[bytes]) -> bytes:
    return b"\r\n".join([
        method + b" " + target + b" HTTP/1.1", *headers, b"", b""
    ])


def get_status(host: str, port: int, wire: bytes, timeout: float) -> int:
    deadline = time.monotonic() + timeout
    with socket.create_connection((host, port), timeout=timeout) as conn:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("test deadline elapsed during connect")
        conn.settimeout(remaining)
        conn.sendall(wire)
        head = bytearray()
        while b"\r\n\r\n" not in head:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("test response deadline elapsed")
            conn.settimeout(remaining)
            if len(head) >= MAX_RESPONSE_HEAD:
                raise ValueError("response head exceeds configured test bound")
            data = conn.recv(min(4096, MAX_RESPONSE_HEAD - len(head)))
            if not data:
                raise EOFError("proxy closed before completing response head")
            head.extend(data)
        status_line = bytes(head).split(b"\r\n", 1)[0]
        match = re.fullmatch(rb"HTTP/1\.1 ([1-5][0-9]{2})(?: [^\r\n]*)?", status_line)
        if match is None:
            raise ValueError(f"invalid status line: {status_line!r}")
        return int(match.group(1))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=1087)
    parser.add_argument("--timeout", type=float, default=3.0)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("port must be 1..65535; timeout must be positive and finite")

    host = [b"Host: test.example"]
    cases: list[tuple[str, bytes, int]] = [
        ("local OPTIONS", request(b"OPTIONS", b"*", host), 204),
        ("missing Host", request(b"GET", b"http://test.example/", []), 400),
        ("origin-form rejected", request(b"GET", b"/", host), 400),
        ("duplicate Host", request(b"GET", b"http://test.example/", host + host), 400),
        ("CL plus TE", request(b"POST", b"http://test.example/", host + [
            b"Content-Length: 0", b"Transfer-Encoding: chunked"]), 400),
        ("duplicate CL", request(b"POST", b"http://test.example/", host + [
            b"Content-Length: 0", b"Content-Length: 0"]), 400),
        ("CONNECT missing port", request(b"CONNECT", b"test.example", host), 400),
        ("CONNECT port denied", request(b"CONNECT", b"test.example:25", host), 403),
        ("absolute HTTPS rejected", request(b"GET", b"https://test.example/", host), 501),
        ("domain rule rejection", request(b"GET", b"http://blocked.example/", host), 403),
        ("TRACE disabled", request(b"TRACE", b"http://test.example/", host), 403),
        ("unsupported expectation", request(b"POST", b"http://test.example/", host + [
            b"Content-Length: 0", b"Expect: unsupported"]), 417),
    ]
    failures = 0
    for name, wire, expected in cases:
        try:
            actual = get_status(args.host, args.port, wire, args.timeout)
            if actual != expected:
                raise AssertionError(f"expected {expected}, received {actual}")
            print(f"PASS {name}: {actual}")
        except (OSError, EOFError, ValueError, AssertionError) as exc:
            failures += 1
            print(f"FAIL {name}: {exc}", file=sys.stderr)
    print(f"{len(cases) - failures}/{len(cases)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
```

这个脚本不覆盖请求体流式转发、上游协议、背压、隧道、DNS 隐私和并发资源管理。脚本通过不能替代完整验收。

---
<a id="s28"></a>
## 28. 测试矩阵、故障注入与发布门槛

### 28.1 测试环境与断言口径

下面是待实现产品的验收计划，不是声称已经运行并通过的结果。

测试至少包含三层：纯函数与增量解析；使用可控时钟、Resolver、Channel 和测试 Wire 的确定性事务测试；真实 socket 与受控业务目标的集成测试。

表中的错误状态码均以“尚未提交最终响应且客户端连接仍可写”为前提；最终响应已提交时，相应断言应改为截断关闭和正确错误记录，不再追加第二条最终响应。每个预出站拒绝用例同时断言入口目标 Resolver、目标 Connector、节点 Connector 与 Wire 启动的调用数为零。

真实回环目标的集成测试需要独立测试配置，显式允许 loopback 业务地址并选用非 listener 端口。测试配置不能偷偷成为发布默认值，`deny_self_endpoints` 始终保持 true。

### 28.2 请求解析与目标提取

| ID | 输入 / 条件 | 必须断言 |
|---|---|---|
| P01 | 合法 absolute-form GET | 正确取得域名、默认 80、path/query 与单条 head |
| P02 | absolute URI 与合法 Host 冲突 | URI 决定目标，输出 Host 重建；不使用冲突 Host 分流 |
| P03 | 缺失、重复或空 Host | 400；absolute-form 也不豁免 |
| P04 | CONNECT 域名带显式端口 | 取 authority；不是将整行当 URL |
| P05 | CONNECT 无端口、0、65536、非十进制端口 | 400，不补默认 443 |
| P06 | IPv6 `[2001:db8::1]:443` | 解析为 16 字节目标；序列化方括号正确 |
| P07 | 无括号 IPv6、zone ID、IPvFuture | 按产品边界 400 |
| P08 | 域名大小写、末尾根点 | matchName 与 forwardName 分离且稳定 |
| P09 | 严格 IPv4、前导零、整数 / 十六进制 / 少段形式 | 只接受严格格式；无兼容解析绕过 |
| P10 | 路径含 `%2F`、重复 query、双斜线与点段 | 转发字节不擅自解码、折叠或重排 |
| P11 | URI 用户信息、fragment、反斜杠、非法百分号 | 400 |
| P12 | 无 path；有 query 的无 path | 一般转 `/`；query 完整保留 |
| P13 | origin-form、absolute HTTPS、其他 scheme | 分别 400、501、501 |
| P14 | OPTIONS `*` | 本地 204，无 CL/TE，无 DNS / 出站 |
| P15 | absolute OPTIONS 空 path 无 query | 发给源站为 `*`；有 query 时不是 `*` |
| P16 | OPTIONS Max-Forwards 0 / 1 / 非法 / 重复 | 本地处理 / 转发为 0 / 400 / 400 |
| P17 | HTTP/1.0 与可识别的不支持版本 | 505；不误当网站内容 |
| P18 | bare LF、obs-fold、字段冒号前空白 | 400；不容忍产生解析歧义的形式 |
| P19 | 一条允许的前导 CRLF；多条前导 CRLF | 接受前者，拒绝后者，不能无限跳空行 |
| P20 | 请求逐字节输入、每个边界拆分、整条输入 | 事件、目标、消费总字节完全一致 |
| P21 | 方法长度、目标长度、头部总量 / 字段数量越界 | 按第 23 节分别 501、414、431；内存有界 |
| P22 | 未知但合法方法；TRACE | 普通扩展方法转发；TRACE 为 403 |
| P23 | Connection 指名关键字段 / 自定义字段 | 关键字段 400；合法自定义逐跳字段移除 |
| P24 | 请求头与下一条请求粘包 | 返回精确余量，不一次消费为同一请求 |

### 28.3 请求体与分帧

| ID | 输入 / 条件 | 必须断言 |
|---|---|---|
| F01 | 无 CL / TE 的 POST | body 长度为零，不等客户端关闭来确定长度 |
| F02 | CL=5，body 与下一条请求粘包 | 恰好转发 5 字节，下一条请求保留 |
| F03 | CL=0、合法前导零 CL、超范围 / 非十进制 CL | 前两者规范化；后两者 400 |
| F04 | 相同重复 CL、逗号 CL、不同重复 CL | 全部 400，不合并猜测 |
| F05 | 同时 CL 与 TE | 400，不先删一项再转发 |
| F06 | 单独 chunked | 内容字节准确，重新编码后边界合法 |
| F07 | `gzip, chunked`；chunked 非最后；重复 chunked | 501；400；400 |
| F08 | chunk-size 分片、扩展、终止块与 Trailer 分片 | 增量解析正确，零块不是完整消息结束 |
| F09 | 非法十六进制、size 溢出、数据后缺 CRLF | 400 / 已提交后关闭；不转发下一请求 |
| F10 | 允许且已声明的 Trailer | 保留允许字段，不作为下条 HTTP 头 |
| F11 | 未实现 Trailer 声明 / 危险字段 / 未声明实际字段 | 按第 09 节拒绝；不能静默变成有效正常结束 |
| F12 | 已承诺长度的 body 提前 EOF | 标记截断、关闭出站，不伪造缺少的字节 |
| F13 | CONNECT 含 CL>0、TE 或 Expect | 400、400 或 417；不进入隧道 |
| F14 | 大 body、慢源站读、缓冲超高水位 | 真正暂停客户端读取，不无限积累或整包缓存 |

### 28.4 路由与配置快照

| ID | 输入 / 条件 | 必须断言 |
|---|---|---|
| R01 | 精确域名规则 | 只匹配规范化同名域名 |
| R02 | suffix=example.com | 匹配根域与子域，不匹配 notexample.com |
| R03 | IP-CIDR 与数值目标 | 按二进制地址匹配，不调用 DNS |
| R04 | 域名目标，同时存在 IP-CIDR 规则 | IP-CIDR 不为其触发查询 |
| R05 | 多规则同时匹配 | 按数组首条命中，不按“更精确”重新排序 |
| R06 | 条件 AND、数组 OR、端口范围边界 | 组合逻辑与包含端点行为准确 |
| R07 | 未命中 | 使用显式 default，不临时猜直连或代理 |
| R08 | 同一客户端连接访问两个域名 | 两次独立取目标、决策与连接；不沿用第一条路线 |
| R09 | 请求期间热更新 | 原连接固定旧快照，新连接使用新快照 |
| R10 | PROXY 不可达、认证失败、能力不匹配 | 明确失败；不继续规则匹配，不 DIRECT 降级 |

### 28.5 DNS 与地址安全

| ID | 输入 / 条件 | 必须断言 |
|---|---|---|
| D01 | 域名 DIRECT | 一次逻辑系统解析；向获准数值候选拨号；Host 不变成 IP |
| D02 | 域名 PROXY | 入口目标 Resolver 调用为零，Wire 收到域名 NetworkAddress |
| D03 | 节点配置名称解析 | 配置装配与入口目标 DNS 分开；入口只消费实际端点，节点不再次走业务规则 |
| D04 | 数值 IPv4 / IPv6 | 不做正向 DNS 或 PTR |
| D05 | REJECT、认证失败、端口拒绝 | 不做目标或由该请求触发的节点 DNS |
| D06 | DIRECT 解析候选落入某 PROXY CIDR | 不重新分流；仅执行数值安全检查 |
| D07 | DNS 含禁止地址、重复地址、多于候选上限 | 安全过滤、去重、有界；没有可用地址则失败 |
| D08 | DNS 超时后迟到回调 | 不再拨号；真实工作槽直到任务退出才释放 |
| D09 | 绝对名称与搜索后缀环境 | 不在验收名称之外追加搜索后缀；不发生二次隐式目标解析 |
| D10 | IPv4-mapped IPv6、自回环 DNS、网卡地址变化 | 映射 IPv4 检查生效，实际拨号前自回环集合有效 |

### 28.6 Wire 集成

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

### 28.7 HTTP 响应与上传并发

| ID | 输入 / 条件 | 必须断言 |
|---|---|---|
| H01 | 固定长度响应后源站关闭 | 正常完成；符合条件时客户端仍可接收下一请求 |
| H02 | chunked 响应含允许 Trailer | 内容与 Trailer 完整；结束边界无歧义 |
| H03 | EOF 定界响应 | 通过关闭客户端定界，不人为加终止块伪装完整 |
| H04 | 源站 HTTP/1.0 | 正确解析、按客户端版本输出，Via 记录接收版本 |
| H05 | HEAD / 304 含合法非零 CL 元数据 | 不读取该长度的 body，也不把元数据改为零 |
| H06 | 1xx / 204 含 CL 或 TE | 严格拒绝，不信任 CL=0 的例外 |
| H07 | 205 + CL=0 / 零 chunk / 空 EOF | 正确消费分帧；零 chunk 不能留给下一响应 |
| H08 | 205 实际包含非零内容 | 拒绝 / 截断，不静默当作 204 |
| H09 | 响应 CL/TE 冲突、重复 CL、超限头部 | 502 或已提交后关闭；不当普通内容透传 |
| H10 | 源站 CL body 提前 EOF / chunk 非正常终结 | 关闭并记录截断，不追加 502 body |
| H11 | 100 Continue 后成功 / 103 后失败 | 信息响应有序；尚未最终提交时可再发最终成功或错误 |
| H12 | 最终 200 首字节已提交后发生失败 | 只能关闭，不再次写 HTTP/1.1 502 |
| H13 | Expect 等待期间源站发送 100 | 不必等待完整客户端 body；及时转发信息响应 |
| H14 | 上传中源站提前 413 / 401 等最终响应 | 停止新上传、完整返回允许的响应、关闭本事务连接 |
| H15 | 信息响应超过上限或持续发送 103 | 有界；不能无限延长最终响应等待 |
| H16 | 两个 Set-Cookie、Authorization/Cookie、逐跳字段 | 可重复端到端字段分别保留；本地代理凭据消失 |
| H17 | 源站 401 / 异常源站 407 | 401 正常转发；407 按本 profile 转为 502，不冒充本地挑战 |

### 28.8 CONNECT、生命周期与背压

| ID | 输入 / 条件 | 必须断言 |
|---|---|---|
| T01 | DIRECT 目标连接尚未完成 | 禁止提前发送 CONNECT 200 |
| T02 | Wire 就绪后本地成功回复短写 | 写入顺序正确；本地回复完成前 relay 无写权 |
| T03 | 客户端 CONNECT 头与早到不透明字节同读到达 | 有界保存；成功后恰好转发一次；失败不转发 |
| T04 | 成功后发送看似 HTTP 的原始隧道内容 | 不再触发请求解析、认证或路由 |
| T05 | 客户端读 EOF，反向仍持续响应 | 上行排空后半关闭，反向继续直到 EOF / 预算结束 |
| T06 | 上游先半关闭，客户端仍有待发送数据 | 按相反方向规则处理，不立即丢弃另一方向 |
| T07 | 慢接收、部分写、暂时不可写 | 保持字节序和高低水位；无重复、无遗漏 |
| T08 | 取消、超时、EOF 同时到达 | 单次终结、单次释放额度，无迟到成功回调 |
| T09 | socket / 事务 / 全局缓冲预算耗尽 | 有界等待后明确失败，不无限排队 |
| T10 | 本地背压暂停读取 | 不误判对端 body idle；由相应写阻塞预算控制 |
| T11 | 带早到字节的长隧道与持续流式上传 | RSS / 缓冲不随累计流量线性增长 |
| T12 | 优雅停机及 grace 到期 | 停止接入，已开始任务按策略排空，到期取消且资源回收 |

### 28.9 WebSocket 与协议边界

| ID | 输入 / 条件 | 必须断言 |
|---|---|---|
| W01 | 合法 WebSocket 请求与正确 Accept | 101 后交接原始字节；Via 与 Upgrade 字段合法 |
| W02 | 非法 key、方法错误、非 13 版本、带 body | 按第 19 节拒绝，不错误进入 Upgrade |
| W03 | 源站 Accept 不匹配 / 未提供却选择子协议 | 502，不向客户端提交 101 |
| W04 | 源站返回非 101 | 按普通 HTTP 响应处理，不把 body 当 frame |
| W05 | 101 与第一个 frame 粘包；客户端有早到 frame | 两侧余量均完整保留，顺序正确 |
| W06 | 普通请求收到未请求的 101 / 非注册 Upgrade | 502；禁止无条件切换任意协议 |
| W07 | 入站 HTTP/2 preface、TLS、SOCKS 数据 | 不建立错误协议会话；按可识别错误或直接关闭策略处理 |
| W08 | CONNECT 内 HTTP/2 或 WSS | 原始转发，不因入站 HTTP/1.1 限制破坏隧道内部协议 |

### 28.10 认证与安全

| ID | 输入 / 条件 | 必须断言 |
|---|---|---|
| S01 | 免认证回环；未经授权的 LAN peer | 前者按配置接受；后者在业务操作前拒绝 |
| S02 | Basic 缺失 / 错误 / 格式非法 / 重复字段 | 407 / 407 / 400 / 400；挑战只包含本地 realm |
| S03 | 同一连接后续请求缺少认证 | 仍要求逐请求认证，不继承上一条认证字段 |
| S04 | 本地凭据与节点凭据不同 | 分别使用；各自不流入目标 HTTP 头或日志 |
| S05 | username 含冒号；password 含额外冒号 | 配置用户名非法；密码按第一个冒号之后完整保留 |
| S06 | loopback / private / link-local / deny CIDR | 二进制策略准确，规则不能覆盖强制拒绝 |
| S07 | CONNECT 禁止端口；普通 HTTP 非标准端口 | CONNECT 被拒绝；普通请求不误套 CONNECT-only 表 |
| S08 | 允许一般 loopback 的测试配置下目标等于自身；Via 已含自身 received-by | 502，保护不受普通 allow 开关覆盖 |
| S09 | 原始恶意头值、CRLF、危险 Trailer | 无请求 / 响应拆分或凭据注入 |
| S10 | 日志和指标输出 | 无密码、认证原文、Cookie、body、任意高基数目标标签 |

### 28.11 配置、时钟与资源核算

| ID | 输入 / 条件 | 必须断言 |
|---|---|---|
| C01 | 完整有效配置 | 导出所有生效默认值，引用正确，不输出秘密 |
| C02 | 未知版本 / profile / 字段 / 重复 JSON key | 原子拒绝，不忽略后继续启动 |
| C03 | 重复 ID、悬空 outbound、非法 CIDR / 端口 | 原子拒绝，旧快照继续有效 |
| C04 | 启用 V1 不支持的 HTTP 出站或隐式 DNS 分流 | 明确不支持，不以近似能力代替 |
| C05 | LAN 不满足 ACL / auth / 明文风险声明 | 不启动相应 listener |
| C06 | 声明的一个绑定地址失败 | 整体绑定事务失败，不静默启动一部分 |
| C07 | 系统时间跳变 | 单调截止时间不受影响 |
| C08 | DNS 阻塞超时与重复请求 | 真实线程 / 工作槽 / 等待队列均不突破限制 |
| C09 | 反复连接、拒绝、超时、取消与重载 | 无 socket、许可、buffer、任务及旧快照无界残留 |

### 28.12 HTTP 与 Wire 边界测试

| ID | 场景 | 必须断言 |
|---|---|---|
| X01 | 普通 HTTP 经两个不同测试 Wire | 编码前均为相同 origin-form 和业务 Host |
| X02 | CONNECT 建立 | 本地生成 200；具体 Wire 控制字节不发给客户端 |
| X03 | 控制字节与业务数据同批到达 | Wire 消费控制部分；业务余量不丢失且符合本地响应屏障 |
| X04 | Wire 失败 | 不产生本地认证 407 或伪造源站响应；不跟随节点控制重定向 |
| X05 | 本地、节点、源站凭据 | 入口消费本地凭据；Wire 管理节点凭据；源站字段不混入节点配置 |
| X06 | Wire 启动不产出数据或解码暂为空 | 不误判 EOF，不等待首段业务数据判断就绪 |

### 28.13 模糊测试与分片性质

对每个有限长度的有效或无效协议向量，应覆盖所有单次拆分位置，并执行固定随机种子的多片拆分。相同输入的目标、事件顺序、消费字节、剩余字节与错误类别必须一致。

解析模糊测试应断言：不存在越界访问、整数溢出、无进展循环、无界缓冲及头部结束后的错误重复消费。将 HTTP 请求头、响应头、chunk 行和 Trailer分别作为输入域；不要只模糊测试最外层请求行。

取消与超时测试使用假时钟，不依赖“睡眠 100 毫秒通常够了”。负载测试使用真实时钟另行执行，不能把两个场景混在一起导致随机失败。

### 28.14 集成与容量验收

固定并记录操作系统、CPU、内存、构建模式、依赖锁定版本、socket 实现、配置与测试节点位置。至少覆盖 1 KiB、64 KiB、1 MiB 的请求和响应，以及远大于缓冲上限的持续流式传输。

按默认预算测试 512 个客户端会话、最多 256 个活动 HTTP 事务、最多 64 个握手，以及“剩余客户端在等待或隧道状态”的组合。不是要求 512 个普通事务同时绕过事务限额执行。

在慢客户端、慢源站、DNS 超时、节点断线与周期性重载混合条件下持续观测至少 30 分钟；该时长是建议的测试计划，不是本产品已取得的稳定性成绩。

报告必须包含实际吞吐与延迟分布、CPU、RSS、纳管缓冲峰值、socket / DNS / 活动任务峰值、失败分类，以及停止负载后的资源回收情况。**不得把配置的 64 MiB 缓冲预算宣传为整个进程的 64 MiB 内存上限。**

发布门槛是协议与安全不变量全部满足、资源额度真实生效且错误可定位。具体吞吐指标必须在目标设备与网络上测量后另行约定，不在本 SPEC 中编造。

---

<a id="s29"></a>
## 29. 实施顺序与需求追踪

### 29.1 建议实施顺序

| 阶段 | 交付内容 | 阶段结束的可验证结果 |
|---|---|---|
| A | 模型、配置加载、规则与安全纯函数 | 目标不混淆；规则无网络 I/O；配置原子校验 |
| B | 请求 / 响应头、body 分帧增量 codec | 所有边界分片稳定；明确 consumed 与 remainder |
| C | 复用 Core、DIRECT Channel 与 Wire，加入 HTTP 事务 | 普通 HTTP 按 route 正确连接并构造源站报文 |
| D | CONNECT、早到字节、半关闭 relay | 只在目标就绪后成功；双向字节与 EOF 正确 |
| E | 完整响应语义、Expect 与提前最终响应 | 上传和响应并发，不能出现等待死锁或第二条最终响应 |
| F | 本地认证、额度、背压、重载与日志 | 身份隔离、真实限额、迟到回调安全、观测脱敏 |
| G | WebSocket Upgrade 与真实应用联调 | 101 校验与交接正确；普通请求和隧道都可长期运行 |
| H | 故障注入、模糊测试和发布构建验收 | 第 28 节 V1 发布用例通过，记录真实测量数据 |

阶段顺序不表示前期阶段可以省略安全边界对外发布。例如在完成认证和访问控制前，只能在受控开发环境使用回环 listener，不能开启 LAN 或公网入口。

Wire 类型扩展由所属契约独立管理；HTTP 入口只按本文件的抽象集成边界验收。

### 29.2 需求追踪表

以下 REQ 是实现与评审的稳定编号；测试 ID 对应第 28 节。对任一需求的偏离必须修改 profile / 文档，而不是只在实现代码里改变行为。

| 需求 ID | 强制要求 | 主要章节 | 核心测试 |
|---|---|---|---|
| REQ-001 | HTTP/1.1 字节级增量解析，严格边界与限额 | 06–09 | P18–P24、F01–F12 |
| REQ-002 | absolute URI / CONNECT authority 正确取目标 | 04、07 | P01–P13 |
| REQ-003 | 不混淆 Client、Target、Proxy 地址 | 03–04、12–15 | P02、D03、O04、O10–O11 |
| REQ-004 | 规则顺序首条命中、显式默认、每请求分流 | 11、20 | R01–R09 |
| REQ-005 | 分流不触发目标 DNS，禁止解析后隐式改路 | 11–12 | R04、D02–D06 |
| REQ-006 | DIRECT 使用经过安全验证的数值候选 | 12–13、22 | D01、D07、D09–D10 |
| REQ-007 | PROXY 保留目标域名，节点名称解析归配置装配 | 12、14 | D02–D04、O04 |
| REQ-008 | 上游认证独立、握手完整、无失败直连 | 10、14、23 | R10、O01–O08、S04 |
| REQ-009 | 普通 HTTP 重编码头部且保护消息分帧 | 08–09、16 | P23、F01–F12、H01–H10 |
| REQ-010 | CONNECT 成功前后写权和余量交接准确 | 18、21 | T01–T04、O07 |
| REQ-011 | 不丢数据的双向背压与半关闭 | 18、21 | F14、T05–T11 |
| REQ-012 | 信息响应、Expect、提前最终响应不死锁 | 16–17 | H11–H15 |
| REQ-013 | 最终响应提交后不再生成新错误响应 | 16、23 | H10、H12、T02、T08 |
| REQ-014 | 本地逐请求认证，凭据不泄漏 | 05、08、10 | S01–S05、S10 |
| REQ-015 | 自回环、目标 ACL 与 CONNECT 端口约束 | 05、22 | D07、D10、O11、S06–S09 |
| REQ-016 | HTTP 长连接串行调度与快照固定 | 20、24 | P24、F02、R08–R09、C09 |
| REQ-017 | 超时和真实资源额度有界且正确清理 | 12、21 | D08、T08–T12、C07–C09 |
| REQ-018 | WebSocket 合法升级并停止 HTTP 解析 | 19 | W01–W08 |
| REQ-019 | 配置完整校验、未知能力不静默启用 | 24 | C01–C06 |
| REQ-020 | 错误可定位、隐私与统计口径准确 | 23、25 | O05、H12、H17、S10、C09 |

### 29.3 完成定义

本 profile 的实现只有在对应功能、拒绝路径和资源生命周期均经过测试后，才能标记为完成。仅让浏览器打开一个 HTTPS 网站不构成 HTTP 代理整体完成；那通常只说明 CONNECT 的一条成功链路工作。

WebSocket 可通过显式配置关闭；关闭时必须通过“不接受明文 Upgrade”的测试。CONNECT 内不透明字节的转发能力不因此关闭。其余声明为固定支持的 V1 能力不能被实现方默认为“以后再做”，同时仍声称完全符合本 profile。

实现测试报告应写出实际执行的测试 ID、环境、通过 / 失败 / 未执行状态与原因。Wire 具体实现的编解码和互操作验收须单独列出，不能替代入口契约验收。

### 29.4 变更控制

增加 DNS 后置分流、Wire 集成契约、TLS 入站、连接池、并发 pipelining、HTTP/2 入站或新的认证方案，都涉及现有不变量。应先补充版本化协议和配置契约，再修改实现与测试。

不改变线路语义的实现优化，例如内部 buffer 切片、解析加速或线程调度改进，也必须通过分片一致性、背压、取消与资源回收回归测试。

---

<a id="s30"></a>
## 30. 标准依据、参考资料与最终检查表

### 30.1 引用说明

本文的外部协议依据来自下列标准和官方项目资料。文中的 `[Sxx]` 均跳转到本节，不依赖其他 Markdown 文件。

标准描述通用协议；本 profile 另外规定了严格拒绝策略、支持范围和默认值。遇到产品约束比标准允许范围更窄的情况，应按文中明确标注的产品行为实现，不宣称它是所有 HTTP 代理的共同要求。

<a id="ref-s01"></a>
### S01. RFC 9112 — HTTP/1.1

主要对应：消息语法、请求目标形式、Host、消息长度、chunked、解析安全与连接管理。重点参见 §2、§3、§5、§6、§7、§9、§11。

官方地址：`https://www.rfc-editor.org/rfc/rfc9112.html`

<a id="ref-s02"></a>
### S02. RFC 9110 — HTTP Semantics

主要对应：请求语义、Connection、Via、OPTIONS、CONNECT、Expect、Upgrade、内容长度、状态码与认证字段。重点参见 §7.6、§8.6、§9.3.6、§9.3.7、§10.1.1、§11、§15。

官方地址：`https://www.rfc-editor.org/rfc/rfc9110.html`

<a id="ref-s03"></a>
### S03. RFC 7617 — The “Basic” HTTP Authentication Scheme

主要对应：Basic 的 user-pass、Base64、charset 参数与明文传输风险。本文的用户名 / 密码限额、密钥存储方式与 LAN 策略属于产品约束。

官方地址：`https://www.rfc-editor.org/rfc/rfc7617.html`


<a id="ref-s06"></a>
### S06. RFC 6455 — The WebSocket Protocol

主要对应：HTTP/1.1 Upgrade 请求、Sec-WebSocket-Key / Accept、子协议选择以及握手后协议切换。本文只处理握手与原始字节交接，不实现 WebSocket 应用服务。

官方地址：`https://www.rfc-editor.org/rfc/rfc6455.html`


<a id="ref-s08"></a>
### S08. RFC 9113 — HTTP/2

主要对应：HTTP/2 与 HTTP/1.1 的协议边界。本文不把二进制 HTTP/2 当作 HTTP/1.1 文本入口，但允许在 CONNECT 内透明承载相应字节。

官方地址：`https://www.rfc-editor.org/rfc/rfc9113.html`

<a id="ref-s09"></a>
### S09. RFC 9298 — Proxying UDP in HTTP

主要对应：说明 CONNECT-UDP 是独立的 UDP 代理机制，不是普通 HTTP/1.1 CONNECT 自动具备的功能。

官方地址：`https://www.rfc-editor.org/rfc/rfc9298.html`

<a id="ref-s10"></a>
### S10. RFC 9530 — Digest Fields

主要对应：Content-Digest、Repr-Digest 字段及其 Trailer 使用背景。允许转发字段不代表本代理已经校验或背书内容摘要。

官方地址：`https://www.rfc-editor.org/rfc/rfc9530.html`

<a id="ref-s11"></a>
### S11. RFC 3986 — Uniform Resource Identifier (URI): Generic Syntax

主要对应：scheme、authority、path、query、fragment 和百分号编码的结构边界。网络入口采用第 07 节明确收窄的 HTTP 目标解析配置。

官方地址：`https://www.rfc-editor.org/rfc/rfc3986.html`

<a id="ref-s12"></a>
### S12. SwiftNIO 官方项目

主要对应：库内 Channel、EventLoop 和 HTTP codec 的实施入口。库的具体默认策略仍需用本 SPEC 的测试向量核实。

官方地址：`https://github.com/apple/swift-nio`

<a id="ref-s14"></a>
### S14. curl 官方手册

主要对应：`--proxy`、`--noproxy`、`--proxytunnel`、`--proxy-basic` 和 `--proxy-user` 调试参数。

官方地址：`https://curl.se/docs/manpage.html`

### 30.2 最终实现检查表

```text
[ ] 普通 HTTP 的目标来自 absolute URI；CONNECT 来自 authority。
[ ] Host 合法且唯一；有冲突时仍以 absolute URI 为准并重建 Host。
[ ] 字节级解析支持拆包 / 粘包；完整区分头部、body、Trailer 和余量。
[ ] DIRECT 是本服务连接目标；PROXY 是调用明确的出站适配器。
[ ] 路由无目标 DNS；PROXY 域名不经本服务的目标 Resolver。
[ ] DIRECT 解析候选被安全校验，并按数值地址实际拨号。
[ ] 节点配置装配与业务目标 DNS、业务路由分开；入口只使用实际节点端点。
[ ] 普通请求发给源站时使用 origin-form；PROXY 由 Wire 编码，不因节点类型改变 HTTP 请求形式。
[ ] 本地认证、上游认证与网站认证互不混用。
[ ] CL/TE、逐跳字段、Trailer、1xx、HEAD/304/204/205 均正确处理。
[ ] Expect 与上传中的提前最终响应不会造成双向等待死锁。
[ ] CONNECT / 101 成功前不交接写权；成功后不再解析 HTTP。
[ ] 协议切换两侧余量保留，部分写与半关闭不丢数据。
[ ] 同一客户端连接的普通请求逐条分流、串行执行、使用固定快照。
[ ] 自回环、禁止地址、端口限制与 LAN 准入不能被普通规则绕过。
[ ] 超时、队列、socket、缓冲、DNS 真实任务有界且能够回收。
[ ] 最终响应提交后只关闭或完成传输，不再追加第二条最终响应。
[ ] 任何代理失败都不会自动改为 DIRECT。
[ ] 配置未知字段 / 未实现能力报错；重载以完整快照原子发布。
[ ] 日志不泄露凭据、Cookie、body 或未授权的完整 URL。
[ ] 测试报告区分已经执行、未执行和不属于当前 profile 的用例。
```

**整体处理闭环：读取 HTTP → 完整解析消息边界 → 提取业务目标 → 本地认证与安全检查 → Core 路由 → DIRECT 或抽象 Wire → 普通 HTTP 重编码转发，或 CONNECT / WebSocket 成功后转发隧道业务字节 → 按消息与会话生命周期回收资源。**

---

**文档结束。**
