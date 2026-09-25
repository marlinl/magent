---
desc: "SOCKS4 / SOCKS4a 入口、抽象 Wire 集成、连接生命周期及验收标准，附解析向量与测试工具。"
version: "0.2.0"
updated_at: "2026-09-24"
status: "草案"
references_checked_at: "2026-09-21"
---

# 本地 SOCKS4 / SOCKS4a 代理服务 · 完整 SPEC

本文规定本地入口协议与抽象 Wire 的协作契约。入口只处理自己的报文、目标和本地响应；具体出站协议的线上格式、认证、加密、节点部署及配置属于 Wire 和节点模型，不在本文定义，也不能由入口协议推断。

抽象接口统一由 [Wire 规范](WIRES_SPEC.md) 定义。业务目标使用 [模型规范](MODELS_SPEC.md) 中的 `NetworkAddress`；节点引用、实际端点和规则由 Core 按同一模型契约处理。本文的逻辑流程和示例不新增模型构造入口或具体 Wire 类型。协议字段限制仍由入口负责。

## 单文件导航

- [本地 SOCKS4 / SOCKS4a 代理服务 SPEC](#doc-readme)
- [00 · 范围、术语与需求基线](#doc-00-scope-and-requirements)
- [01 · 总体架构与数据模型](#doc-01-architecture-and-model)
- [02 · SOCKS4 / SOCKS4a 入口报文规格](#doc-02-inbound-wire-protocol)
- [03 · 增量解析、边界与规范化](#doc-03-incremental-parser)
- [04 · 地址获取与分流规则引擎](#doc-04-routing-engine)
- [05 · DNS 职责、地址选择与安全边界](#doc-05-dns-and-addresses)
- [06 · DIRECT 与抽象 Wire](#doc-06-outbound-connectors)
- [07 · 会话生命周期、转发与资源控制](#doc-07-session-and-relay)
- [08 · 配置文件与启动/热更新校验](#doc-08-configuration)
- [09 · 错误、安全与可观测性](#doc-09-errors-security-observability)
- [10 · 测试向量、故障注入与验收](#doc-10-tests-and-acceptance)
- [11 · Swift 实现边界与实施任务](#doc-11-swift-implementation-plan)
- [12 · 从客户端报文到目标服务器的完整实例](#doc-12-end-to-end-examples)
- [13 · 原始来源、设计决策与待确认事项](#doc-13-references)

## 附录导航

- [config.schema.json](#attachment-config-schema-json)
- [examples/config.direct-only.json](#attachment-examples-config-direct-only-json)
- [examples/config.wire-route.json](#attachment-examples-config-wire-route-json)
- [examples/config.test.json](#attachment-examples-config-test-json)
- [examples/parser-vectors.json](#attachment-examples-parser-vectors-json)
- [tools/probe_socks4.py](#attachment-tools-probe-socks4-py)
- [tools/validate_bundle.py](#attachment-tools-validate-bundle-py)

---

<a id="doc-readme"></a>

## 本地 SOCKS4 / SOCKS4a 代理服务 SPEC

本规格描述一个本地 TCP 代理核心：接收应用发来的 SOCKS4/4a 请求，从请求中提取目标地址和端口，按规则选择 `DIRECT`、`PROXY` 或 `REJECT`，建立出站通道，再透明转发双向字节流。

这是规格文档，不是已经完成的代理软件。文中的资源阈值、默认路由、配置格式和接口是**本稿提出的产品设计**，不是 SOCKS 协议强制值，也不代表你的现有项目已经采用。附带 JSON 配置属于本 SPEC 自定义格式，不能直接交给其他代理软件读取。

### 先明确三个协议边界

**SOCKS4 不携带域名；SOCKS4a 才增加域名字段。** 因而需要按域名分流时，本地入口必须兼容 SOCKS4a，且客户端确实需要使用它。请求只有 IP 时，本服务不能凭空恢复原始域名。报文字段的规范来源见 [S01](#s01)、[S02](#s02)。

**本地入口与出站 Wire 分离。** DIRECT 连接业务目标；PROXY 由 Core 选择 Wire，Connection 按 Wire 的启动与编解码契约处理下游。具体规则见 [06](#doc-06-outbound-connectors)。

**不提供 DNS 监听端口，不等于完全不调用解析器。** 域名直连需要取得目标 IP；域名代理默认把名称交给上游；节点自身的域名还可能需要单独解析。DNS 职责见 [05](#doc-05-dns-and-addresses)。

### 文档导航

| 文档 | 解决的问题 |
|---|---|
| [00 · 范围与需求](#doc-00-scope-and-requirements) | 做什么、不做什么、交付边界、强制不变量 |
| [01 · 架构与数据模型](#doc-01-architecture-and-model) | 模块如何拆分，目标地址与节点地址如何区分 |
| [02 · SOCKS4/4a 报文](#doc-02-inbound-wire-protocol) | 每个字节是什么、请求/响应如何编码 |
| [03 · 增量解析器](#doc-03-incremental-parser) | 半包、粘包、NUL 字符串、提前数据怎么处理 |
| [04 · 分流规则引擎](#doc-04-routing-engine) | 地址从哪里来、规则顺序、默认走向如何确定 |
| [05 · DNS 与地址安全](#doc-05-dns-and-addresses) | 谁解析哪个域名、何时解析、如何避免重复解析 |
| [06 · DIRECT 与抽象 Wire](#doc-06-outbound-connectors) | 目标、节点、启动、编解码与本地回复的职责边界 |
| [07 · 会话与转发状态机](#doc-07-session-and-relay) | 何时回复成功、背压、半关闭、取消和停机 |
| [08 · 配置规格](#doc-08-configuration) | 可用字段、默认值、启动校验、热更新 |
| [09 · 错误、安全与观测](#doc-09-errors-security-observability) | 失败映射、防止开放代理、日志与指标 |
| [10 · 测试与验收](#doc-10-tests-and-acceptance) | 协议向量、故障注入、DNS 验证、验收门槛 |
| [11 · Swift 落地与任务拆分](#doc-11-swift-implementation-plan) | 库内所有权、接口契约、实施顺序 |
| [12 · 端到端实例](#doc-12-end-to-end-examples) | 从一段客户端字节一直走到目标服务器 |
| [13 · 来源与设计决策](#doc-13-references) | 原始协议、官方实现、本稿假设和待确认项 |

阅读顺序：先读 `00 → 01 → 02 → 04 → 05 → 06 → 07`，再按开发任务查阅其余文件。

### 基线数据路径

```text
应用（显式使用 SOCKS4 或 SOCKS4a）
    │ TCP → 127.0.0.1:1080
    ▼
本地入口 → 增量解析 → 规范化目标 → 安全检查 → 规则匹配
                                            │
                         ┌──────────────────┼──────────────────┐
                         ▼                  ▼                  ▼
                       DIRECT             PROXY              REJECT
                  需要时解析目标域名      Core 选择 Wire        返回失败
                  TCP 连接目标 IP        连接节点 Channel      关闭连接
                         │               向 Wire 提交目标
                         │               Wire 就绪且启动写完
                         └─────────┬────────┘
                                   ▼
                         完成入口成功响应写入
                                   ▼
                         有界、双向 TCP 字节转发
```

### 附件

`examples/config.wire-route.json`：通过不透明节点引用选择 PROXY；实际节点和 Wire 由运行配置装配。

`examples/config.direct-only.json`：不依赖上游、默认直连的对照配置。

`examples/config.test.json`：仅用于受控本机验收，允许访问 `127.0.0.1:18080` 的测试配置，不应作为生产默认值。

`examples/parser-vectors.json`：机器可读的入口解析测试向量。

`config.schema.json`：JSON Schema，覆盖配置结构；跨字段和运行能力校验仍按 [08](#doc-08-configuration) 执行。

`tools/probe_socks4.py`：仅使用 Python 标准库的主动探针，检查实际运行中的服务；它不是代理服务实现。

`tools/validate_bundle.py`：检查本资料包内部链接、JSON 和解析向量；其参考解析器只是测试 oracle，不是生产网络实现。

### 首版的核心约束

本稿以 **TCP CONNECT、SOCKS4/4a 入口、域名优先规则、默认不为分流查询 DNS、不做透明接管** 为范围。原生 SOCKS4 不提供 UDP；BIND 也不在本次实现范围。来源及与 SOCKS5 的区别见 [S01](#s01)、[S03](#s03)。

代理失败必须报错，不能悄悄改走直连。域名是否代理与域名在哪里解析是相关但不同的两个决策；详细契约以 [04](#doc-04-routing-engine)、[05](#doc-05-dns-and-addresses) 为准。

---

<a id="doc-00-scope-and-requirements"></a>

## 00 · 范围、术语与需求基线

[返回目录](#doc-readme)

### 1. 产品目标

本服务是显式 TCP 代理，不是 IP 路由器，也不是 HTTP 服务。应用连接本地端口，把目标交给本服务；本服务替应用建立连接并中继流量。

本规范面向可复用代理库。UI、系统代理设置、应用权限、PAC 与订阅管理属于宿主应用，不构成本地协议或 Wire 接口的前提。

### 2. 规范用语与来源优先级

`MUST / 必须` 表示此规格的验收要求；`MUST NOT / 禁止` 表示违反即不合格；`SHOULD / 应当` 允许有记录的合理例外；`MAY / 可以` 表示可选。

协议字段以原始协议为准；项目安全策略和资源限制以本稿为准。原始协议允许而本产品未实现的能力，必须明确拒绝，不能以“完整 SOCKS4 服务”掩盖限制。

本文将协议来源集中在 [13](#doc-13-references)。其余无外部来源的配置值、状态机、错误名、规则行为均为本稿设计，不是引用某个现有项目的既定实现。

### 3. 范围矩阵

| 能力 | 基线要求 | 说明 |
|---|---|---|
| SOCKS4 CONNECT | 必须 | 从请求取得 IPv4 与端口 |
| SOCKS4a CONNECT | 必须 | 从请求取得域名与端口 |
| SOCKS4 BIND | 不实现 | 命令 `0x02` 失败，不伪造成功 |
| SOCKS5 本地入口 | 不实现 | 首字节 `0x05` 不是本入口支持的版本 |
| UDP 转发 | 不实现 | 不把 UDP ASSOCIATE 塞进 SOCKS4 |
| IPv6 字面量入口 | 不实现 | SOCKS4 请求没有 16 字节目标地址字段 |
| SOCKS4a 域名的 IPv6 出站 | 本产品支持 | DIRECT 可使用 AAAA；上游自行决定其解析和网络能力 |
| DIRECT / PROXY / REJECT | 必须 | 每条连接只选定一个结果 |
| TCP Wire 集成 | 必须 | 由 Core 选择，入口只依赖抽象启动与编解码契约 |
| 独立 DNS 服务端口 / fake-IP | 不实现 | 不监听 53，也不维护伪 IP 映射 |
| HTTP Host / TLS SNI 嗅探 | 不实现 | 不依赖应用数据补齐域名 |
| TUN / Network Extension flow 接管 | 不实现 | 可另做入口适配，不能声称此版本已接管所有应用 |
| 进程名规则 / GEOIP 数据库 | 不实现 | 当前入口没有可靠进程身份，也没有内置地域数据库 |

协议能力边界来自 [S01](#s01)、[S02](#s02)、[S03](#s03)。SOCKS4a 域名解析到 IPv6 是本实现的出站能力，不代表 SOCKS4 新增了 IPv6 字面量编码。

### 4. 术语

| 名称 | 定义 |
|---|---|
| Client | 连接本地入口的应用 |
| Inbound / 本地入口 | 接收 SOCKS4/4a TCP 请求的监听器 |
| Target / 业务目标 | 应用实际希望访问的 `host:port` |
| Upstream / 代理节点 | 本服务为了 PROXY 路径而连接的服务器 |
| Outbound / 出站 | 建立直连或代理通道的适配器及其配置 |
| 节点名称解析 | 配置装配时解析节点自己的名称，与入口业务目标 DNS 分开 |
| Target DNS | 把业务目标域名解析成 IP |
| Relay | 建立通道之后的双向字节转发 |
| 配置快照 | 会话固定引用的不可变配置版本 |
| Wire 就绪 | ready=true 且必要控制输出写完；不是业务请求完成，也不要求统一的远端确认 |

### 5. 强制需求与不变量

| ID | 要求 | 主文档 |
|---|---|---|
| REQ-001 | 同一端口增量解析 SOCKS4 和 SOCKS4a CONNECT | 02、03 |
| REQ-002 | 严格限定头部长度，不丢弃头部后的业务字节 | 03 |
| REQ-003 | Target 与 Upstream 分开保存，不互相覆盖 | 01、06 |
| REQ-004 | 地址只来自入口请求及明确解析结果，不反向猜测域名 | 04、05 |
| REQ-005 | 规则按配置顺序首条命中，未命中使用显式 final | 04、08 |
| REQ-006 | PROXY 域名路径不调用本服务的目标 DNS 解析 | 05、06 |
| REQ-007 | DIRECT 域名路径先解析、检查、固定候选，再连接 IP | 05 |
| REQ-008 | 出站 ready 后才写入口成功；只回复一次 | 06、07 |
| REQ-009 | 入口成功写完之前不向客户端转发业务数据 | 07 |
| REQ-010 | 流量按序、不增删；半关闭不能丢掉反向响应 | 07 |
| REQ-011 | 单连接及全局用户态缓冲均有界 | 07、08 |
| REQ-012 | 代理失败不直连；进入转发后不重放业务数据 | 06、07 |
| REQ-013 | 默认仅回环监听；不信任 USERID 为认证凭据 | 02、09 |
| REQ-014 | 防自身监听回环；节点连接不得重新进入普通路由 | 05、09 |
| REQ-015 | 错误只记录元数据，不记录明文密码与业务载荷 | 09 |
| REQ-016 | 无效配置不生效；老会话固定使用旧快照 | 08 |
| REQ-017 | 取消和超时释放 socket、缓冲、任务及计数器 | 07、10 |
| REQ-018 | 区分应用目标 DNS、节点 DNS 和外部程序自己的 DNS | 05、09 |

### 6. 连接成功的定义

DIRECT：已建立到通过检查的某个目标 IP 的 TCP 连接。

PROXY：下游 Channel 已建立，Wire 契约要求的启动处理已完成。本地成功不等于远端应用请求成功，也不假定存在统一的远端确认报文，详见 [06](#doc-06-outbound-connectors)。

入口 `0x5A` 不表示 HTTP 返回 200、不表示目标 TLS 验证成功、更不表示业务操作成功。本服务不解析这些应用层结果。

### 7. 本稿选定但尚非你的既定配置

本稿示例监听 `127.0.0.1:1080`，把未匹配目标交给 `main` 节点引用。实际节点端点与 Wire 由运行配置装配；示例不固定外部服务、端口或节点协议。

协议文本没有规定本稿的 512 会话、64 待握手、10 秒入口握手等阈值；这些是待压测校准的初值。交付不得写成已经达到某个 QPS、吞吐或内存成绩。

---

<a id="doc-01-architecture-and-model"></a>

## 01 · 总体架构与数据模型

[返回目录](#doc-readme)

### 1. 数据路径与所有权

```text
MagentTCPConnection → Socks4Connection → NetworkAddress → Core 路由
                                                    ├─ DIRECT → 目标 Channel
                                                    └─ PROXY  → Wire + 节点 Channel
本地 SOCKS4 回复 ← Socks4Connection ← 解码后的业务数据
```

accepted Channel 由 MagentTCPConnection 管理；Socks4Connection 管理请求状态与下游 Channel；Wire 仅管理出站启动和编解码状态。协议解析不执行 DNS，规则匹配不解析业务载荷。

### 2. 模块输入与输出

| 模块 | 输入 | 输出 |
|---|---|---|
| SOCKS4 解析器 | 任意分片入口字节 | 命令、NetworkAddress、已消费长度及余量 |
| Core | 已验证的逻辑目标 | DIRECT 或所选 Wire；失败保持原始错误 |
| Wire | 逻辑目标、业务数据或下游协议字节 | 启动字节、编码字节或解码后的业务数据 |
| SOCKS4 Connection | 出站结果与业务数据 | 本地八字节回复、双向转发及资源清理 |

### 3. 地址模型

业务目标使用 NetworkAddress；节点端点和实际 TCP 本地/远端地址使用 SocketAddress。SOCKS4 的四字节地址由协议层借助 NIO 转成数值文本，再调用模型的文本构造入口；SOCKS4a 解码名称后调用同一个入口。CONNECT 端口 0 由协议层拒绝。

入口只允许本章规定的 SOCKS4 / SOCKS4a 地址表达；模型支持其他地址形式不会自动扩大入口语法。目标与节点必须分别保存，不得相互覆盖。

### 4. 会话模型

```text
SessionContext {
  sessionId: random identifier
  acceptedAt: monotonic instant
  peerAddress: IP:port
  inboundEndpoint: IP:port
  snapshotId: String
  request?: ParsedRequest
  decision?: RouteDecision
  established?: EstablishedStream
  state: SessionState
  replyState: notStarted | started | completed
  terminalReason?: ProxyError
  clientToRemotePayloadBytes: UInt64
  remoteToClientPayloadBytes: UInt64
}

ParsedRequest {
  target: Target
  userIdBytes: byte[]           // 非可信输入；默认不持久化
  headerLength: Int
  clientRemainder: byte[]       // 头部结束后的字节，不属于 USERID/域名
}

RouteDecision {
  action: DIRECT | PROXY | REJECT
  matchedRuleId: String        // final 使用保留 ID __final__
  outboundId?: String         // 只有 PROXY 才能存在
  snapshotId: String
  targetDnsOwner: none | system | upstream
}
```

规则命中时只确定 DNS 职责，不要求立即解析。对于 DIRECT IP，owner 为 `none`；DIRECT 域名为 `system`；PROXY 域名为 `upstream`。

### 5. 出站状态与业务余量

Connection 保存下游 Channel、可选 Wire、启动状态和有界业务余量。DIRECT 没有 Wire；PROXY 的具体控制帧只交由 Wire 消费。不得为本地回复猜测远端选中的目标 IP，也不得把节点端点当成业务目标。

### 6. 字节流契约

```text
read(maxBytes) -> Bytes(non-empty) | EOF
writeAll(bytes) -> 完整消费本次字节，否则抛错
finishWrite() -> 保持读方向，完成写方向 EOF
abort() -> 立即终止；幂等
```

适配层要统一处理底层的部分写、空回调、暂时不可读和取消；核心不能把一次 read 当作一条消息。

每个方向只能有一个有序写入者。握手阶段由协议适配器拥有写权，转发阶段由 relay 拥有写权；交接不能重叠。

### 7. 端到端时序

```text
客户端 SOCKS4/4a 请求
→ Connection 解析并构造 NetworkAddress
→ Core 路由并选择可选 Wire
→ Connection 创建下游 Channel；PROXY 完成 Wire 启动
→ Connection 写完本地 SOCKS4 成功回复
→ 双向业务转发；PROXY 数据经过同一个 Wire 编解码
```

Wire 的线上报文不属于本地 SOCKS4 会话，入口不为它增加另一套协议状态机。

### 8. 非目标模块

本地 UI 可以把系统 SOCKS 设置指向入口，但本服务不根据系统设置回送 `DIRECT` 字符串给应用。应用既然已把连接交进来，DIRECT 的含义就是**由本服务自己打开目标连接并继续转发**。

本核心禁止在出站时调用一个会再次应用本机系统代理规则的高层 HTTP 客户端。节点连接和目标直连都必须使用明确受控的传输适配层；无法证实不会回环时，该平台适配不能通过验收。

---

<a id="doc-02-inbound-wire-protocol"></a>

## 02 · SOCKS4 / SOCKS4a 入口报文规格

[返回目录](#doc-readme)

本章“线上格式”依据 [S01](#s01)、[S02](#s02)；长度上限、合法域名子集和拒绝策略是本产品约束。

### 1. 传输前提

客户端先建立到本地监听器的 TCP 连接，再发送请求。本入口没有 SOCKS5 式方法协商，也不是 TLS 监听器或 HTTP 监听器。

所有偏移以 0 开始，字节长度均为 octet；端口按网络字节序，高字节在前。

### 2. SOCKS4 CONNECT

```text
偏移        0      1      2..3       4..7          8...
         +------+------+----------+------------+----------+------+
字段     | VN   | CD   | DSTPORT  | DSTIP      | USERID   | 00   |
         +------+------+----------+------------+----------+------+
长度        1      1        2            4          可变       1
```

| 字段 | 线上含义 | 本稿处理 |
|---|---|---|
| VN | 请求版本 | 必须 `0x04` |
| CD | 命令 | 只接受 CONNECT `0x01`；BIND `0x02` 拒绝 |
| DSTPORT | 目标端口 | `UInt16`；本产品拒绝 0 |
| DSTIP | 4 字节目标 IPv4 | 不得按字符串中的十进制数字解析 |
| USERID | NUL 结尾标识 | 允许空；不作为可信认证 |
| `00` | USERID 结束标记 | 必须出现，即使 USERID 为空 |

端口计算：`port = (UInt16(b[2]) << 8) | UInt16(b[3])`。

示例：连接文档地址 `203.0.113.10:443`，USERID 为空。

```text
04 01 01 BB CB 00 71 0A 00
│  │  └───┘ └─────────┘ └─ USERID 的终止符
│  │    443   203.0.113.10
│  └─ CONNECT
└─ SOCKS4
```

最短合法 SOCKS4 请求是 9 字节，不是 8 字节。示例中的文档 IP 不应被当作互联网测试服务，参见 [S13](#s13)。

### 3. SOCKS4a CONNECT

当 `DSTIP[0..2] == 00 00 00` 且 `DSTIP[3] != 00`，请求按 SOCKS4a 解析。

```text
04 | 01 | DSTPORT[2] | 00 00 00 xx | USERID | 00 | DOMAIN | 00
                                  xx != 0
```

`0.0.0.1` 到 `0.0.0.255` 都是有效扩展标记，不能只识别 `0.0.0.1`。标记不是实际连接目标，也不是 IPv6 地址。

域名必须位于 USERID 的 NUL 后，以自己的 NUL 结束。不能把 USERID 当域名。

示例：`example.com:443`，USERID 为空：

```text
04 01 01 BB 00 00 00 01 00
65 78 61 6D 70 6C 65 2E 63 6F 6D 00
```

总长度 21 字节。规范化后目标为 `Domain("example.com"), port=443`。

### 4. 产品输入限制

| 项目 | 上限或策略 |
|---|---|
| USERID 原始字节 | 0..255 字节，不含终止 NUL |
| 域名字段原始字节 | 1..254 字节，不含终止 NUL；254 只可能用于包含尾随点的最大名称 |
| 规范化域名 | 不含尾随点时最多 253 ASCII 字节 |
| 单个 label | 1..63 ASCII 字节 |
| 最大合法头部 | `8 + 255 + 1 + 254 + 1 = 519` 字节 |
| 防御性头部缓冲上限 | 1024 字节；不能把业务尾部算进头部 |
| 域名字符集 | 主机名 ASCII 子集或已编码 A-label；不接受原始 UTF-8 域名 |
| 空域名、根域名、内部空 label | 拒绝 |
| 单 label 目标 | 本稿拒绝；避免隐式搜索域行为 |
| IPv6 文本、URL、`host:port` | 不属于域名字段，拒绝 |

上述限制是安全与可互操作的产品子集，不宣称原始 SOCKS4 为 USERID 规定了 255 字节上限。DNS 自身的名称长度背景见 [S07](#s07)，IDNA 术语见 [S12](#s12)。

### 5. 服务端响应

固定 8 字节：

```text
VN=00 | RESULT[1] | PORT[2] | ADDR[4]
```

| RESULT | 原协议含义 | 本服务是否发送 |
|---|---|---|
| `0x5A` / 90 | 请求成功 | 是 |
| `0x5B` / 91 | 拒绝或失败 | 是 |
| `0x5C` / 92 | 无法连接客户端 identd | 否；本稿不运行 IDENT 流程 |
| `0x5D` / 93 | IDENT 返回身份不一致 | 否 |

对于 CONNECT，响应末尾六字节由原协议规定为忽略字段；本稿统一填零，不拿它们扩展错误信息。BIND 中这些字段有其他语义，但 BIND 不在本产品范围。[S01](#s01)

```text
成功：00 5A 00 00 00 00 00 00
失败：00 5B 00 00 00 00 00 00
```

请求版本是 `04`，响应版本是 `00`；不要写成 `04 5A ...`。

### 6. 成功与失败边界

只有出站达到 ready，才能开始写成功响应。完整响应写完后，才进入业务转发。出站失败、DNS 失败、规则拒绝在未开始响应时统一映射 `0x5B`；更细错误只在内部记录。

未知版本：发现首字节不是 `04` 就关闭，不写 SOCKS4 响应，也不自动切到 SOCKS5 或 HTTP。

已确认首字节 `04`，但后续协议错误：写端仍可用且尚未开始任何响应时，尽力写 `0x5B` 后关闭。没有足够资源接纳的连接、尚未收到首字节的超时连接可以直接关闭。

一旦成功响应已经开始写入，即使只写出部分字节，也不能改发失败响应。进入业务流后也禁止再次插入 SOCKS 响应。

### 7. 握手结束后的字节

请求终止符后所有字节属于业务流，即使它们恰好以 `04`、`05`、`00` 开头。一个 TCP 连接只处理一次 SOCKS4/4a 请求，不支持在相同隧道里重新 CONNECT。

例如：

```text
[21 字节 SOCKS4a 头部][16 03 01 ... TLS ClientHello]
```

解析器必须报告 `consumed=21` 并保留剩余字节，不能丢弃、解码成字符串或继续作为 SOCKS 请求解析。

---

<a id="doc-03-incremental-parser"></a>

## 03 · 增量解析、边界与规范化

[返回目录](#doc-readme)

### 1. 输入/输出契约

解析器是可独立单测的纯状态机，不执行 DNS、规则匹配、日志格式化或网络连接。

```text
feed(bytes) -> NeedMore
            | Complete(request, headerLength, remainder)
            | Invalid(error, recognizedSocks4)
```

一个请求可能逐字节送达，也可能与业务数据同次送达。TCP 提供字节流而非应用消息边界，参考 [S06](#s06)。官方实现参考可见 [S09](#s09)、[S10](#s10)，本章算法为本项目设计。

### 2. 状态机

```text
AwaitVersion → AwaitCommand → AwaitFixedHeader → ReadUserId
                                              ├─ 普通 IPv4 → Normalize → Done
                                              └─ 4a 标记 → ReadDomain → Normalize → Done
任意非终态 → Invalid
Done / Invalid 为终态
```

尽早检查 VN 和 CD：已经知道不是本协议或不支持该命令，就不继续等待攻击者发完超长字符串。

`ReadUserId` 与 `ReadDomain` 各保存独立扫描游标。每个字节最多扫描一次，不得每次 feed 从缓冲起点重新扫描，否则逐字节输入可能导致平方级扫描成本。

### 3. 解析伪代码

```text
onData(chunk):
  if terminal: 将数据交给会话既定后续阶段，不再次解析
  在有界输入窗口中增量推进：
    VN 到齐：不是 04 → Invalid(UNSUPPORTED_VERSION, false)
    CD 到齐：不是 01 → Invalid(UNSUPPORTED_COMMAND, true)
    固定头到齐：读取端口；端口 0 → Invalid(INVALID_PORT, true)
                 检测 00 00 00 xx，xx != 00
    USERID：逐字节扫描至第一个 00，最多 255 个内容字节
    普通 IPv4：构造 IPv4 Target，结束头部
    SOCKS4a：继续逐字节扫描 DOMAIN 至 00，最多 254 个内容字节
              执行 host 规范化
    输出 Complete，同时转交当前输入中未消费的剩余字节
```

**边界检查顺序：** 一个字段已有 N 个内容字节且 N 等于上限时，仍允许下一字节是 `00`；如果下一字节非零，才判定超长。不能在恰好达到上限时提前拒绝，也不能把终止符计入内容长度。

只对**头部实际消费的字节**检查头部上限。`完整短头部 + 32 KiB 业务数据` 不是 32 KiB 的超长头部。

### 4. 目标规范化

IPv4 路径直接保留四字节数值，不进行 DNS，不通过宽松文本解析函数二次解释。

SOCKS4a 域名按下列顺序处理：

1. 以严格 ASCII 解码，不容忍替换字符；拒绝控制字符、空格、斜杠、反斜杠、`@`、冒号、方括号和百分号。
2. 最多移除一个末尾 `.`；再检查为空或存在空 label 的情况。大小写按 ASCII 转小写。
3. 完全由数字和点组成，或每个点分段都是十进制数字/`0x` 十六进制数值 token 时，只接受规范四段十进制 IPv4：四段都是 0..255，除单个 `0` 外不得有前导零。合法则转成 IPv4 Target；不合法直接拒绝，不交给 DNS。
4. 其他名称要求至少两个非空 label。每个 label 仅含 `a-z`、`0-9`、`-`，且首尾不能是 `-`。总长不超过 253，label 不超过 63。
5. `xn--` label 按 ASCII 传递。本首版不把接收端变成完整 IDNA 转换服务，也不宣称已做 Unicode 混淆检测；需要显示 Unicode 的 UI 必须另行校验和安全展示。

例如：

| 原始输入 | 结果 |
|---|---|
| `WWW.Example.COM.` | `Domain("www.example.com")` |
| `203.0.113.10` | `IPv4(203,0,113,10)` |
| `127.000.0.1`、`2130706433`、`127.1`、`0x7f.0.0.1` | 拒绝；禁止宽松数值地址解释 |
| `https://example.com` | 拒绝；字段不是 URL |
| `example.com:443` | 拒绝；端口在头部独立字段 |
| `::1`、`[::1]`、`fe80::1%en0` | 拒绝；入口不提供 IPv6 字面量 |
| `a..example.com`、`.example.com`、`example.com..` | 拒绝 |
| `printer.local` | 合法；是否直连由规则决定 |
| `localhost` | 按单 label 限制拒绝 |
| `bad_name.example` | 本产品主机名子集拒绝，不代表 DNS 协议完全禁止下划线 |

域名字符串规则必须与配置规则的规范化一致。`domain_suffix` 的配置值可以是单 label，如 `local`；这不代表允许客户端传入单 label 目标。

### 5. USERID 处理

USERID 是字节串，不保证为 UTF-8。解析器可以接受 `FF 00` 这样的标识；是否显示由日志策略决定。默认不记录、不转交上游认证、不据此授予权限。

SOCKS4a 中 USERID 即使是 `example.com`，后面依然需要真正 DOMAIN 字段。程序禁止在 DOMAIN 缺失时拿 USERID 顶替。

### 6. 提前业务数据

本稿容忍客户端把请求和业务字节合并发送。头部完成时，将当前 read 多读的部分移动到 `clientRemainder`；默认上限 64 KiB。

在出站建立和成功响应完成之前，停止继续读取客户端业务字节，通过 TCP 背压限制后续数据；不主动转发提前数据。正常适配器每次最多读取 16 KiB，因此一般不会立即填满 64 KiB。

不得因为对端写了很多数据、但这些数据尚在内核接收缓冲中，就宣称用户态已经收到或溢出。只有实际持有的用户态尾部超过上限才触发 `EARLY_DATA_LIMIT`。

如果头部尾随的数据再次看起来像 SOCKS 握手，也必须作为业务字节处理；不支持握手管线化。

### 7. EOF、取消和计时

入口绝对握手期限从 accept 开始，默认 10 秒；每收到一个字节不能重置此期限。这样慢速逐字节发送不能无限占位。

头部未完成即 EOF：产生 `TRUNCATED_REQUEST`；若仍可写且版本已经确认为 4，尽力写失败响应。头部完成后收到读 EOF，应记录为客户端写半关闭，不能误当作解析失败；出站完成后要在转发已有尾部之后传递 EOF。

会话取消时，解析器缓冲必须释放；已排队但尚未执行的回调不能恢复该会话。

### 8. 最低测试要求

对每个合法头部，逐一测试全部单切点分片、逐字节 feed，以及完整头部附加随机二进制尾部；结果必须与一次性输入一致。

还要覆盖两个字符串各自缺少终止符、恰好最大长度、最大长度加一、4a 标记的 255 种值、字段内非 UTF-8、未知版本、端口 0、命令 BIND、EOF 和超时。完整矩阵见 [10](#doc-10-tests-and-acceptance)。

---

<a id="doc-04-routing-engine"></a>

## 04 · 地址获取与分流规则引擎

[返回目录](#doc-readme)

### 1. 服务如何知道应用要访问哪里

SOCKS4：从固定头 `DSTIP + DSTPORT` 得到目标 IP 和端口。

SOCKS4a：识别扩展标记后，从 `DOMAIN + DSTPORT` 得到目标名称和端口。来源见 [S01](#s01)、[S02](#s02)。

不是从 TCP 对端地址取得业务目标。入口 TCP 对端通常只是本机应用的 `127.0.0.1:临时端口`。代理节点也不等于业务目标。

输入只有 IP 时，域名规则不可用。本稿不做 PTR 反查，不通过缓存中的相同 IP 推断域名，不嗅探 HTTP Host 或 TLS SNI。多个域名可以对应相同地址，强行反推会改变用户请求的语义。

### 2. 三种动作

| 动作 | 执行语义 | 是否建立出站 |
|---|---|---|
| DIRECT | 本服务直接连接目标并转发 | 是，连接目标 |
| PROXY | 本服务连接指定节点，把目标交给它 | 是，连接节点 |
| REJECT | 返回 SOCKS4 失败后关闭 | 否 |

**未命中规则不等于自动直连。** 必须读取 `routing.final`；示例默认 PROXY，另一份示例显式设为 DIRECT。默认行为是产品配置，不是 SOCKS 协议规则。

### 3. 首版匹配类型

```json
{
  "id": "example-direct",
  "match": { "type": "domain_suffix", "value": "example.com" },
  "action": "DIRECT"
}
```

| 类型 | value | 适用目标 | 语义 |
|---|---|---|---|
| `domain_exact` | 规范化域名 | Domain | 完全相等 |
| `domain_suffix` | 规范化后缀 | Domain | 域名等于后缀，或以 `.` 加后缀结尾 |
| `ip_cidr` | 规范 IPv4 网络 CIDR | 已有数值 IPv4 | 用二进制掩码匹配 |
| `port` | 1..65535 的整数 | 所有目标 | 目标端口相等，不是节点端口 |

首版普通路由的 `ip_cidr` 只接受 IPv4 CIDR：入口没有 IPv6 字面量，且域名解析结果不重新路由。IPv6 CIDR 仍可用于来源/目标安全名单，对 DIRECT 的 AAAA 结果执行保护；不要把安全检查与普通分流混为一谈。

每条规则只有一个 matcher；首版没有隐式 AND、通配符、正则、端口范围或优先级数值。需要这些能力时必须扩展 schema 和测试，而不是根据字符串外形猜测。

匹配算法必须保留配置顺序，**首条命中终止**。不会自动让精确规则高于后缀规则，也不会自动让更长前缀覆盖前面的宽规则。

### 4. 后缀匹配的标签边界

```text
matchSuffix(host, suffix) =
    host == suffix OR host.endsWith("." + suffix)
```

| host | suffix=`example.com` |
|---|---|
| `example.com` | 命中 |
| `www.example.com` | 命中 |
| `a.b.example.com` | 命中 |
| `badexample.com` | 不命中 |
| `example.com.evil.test` | 不命中 |

禁止直接用 `contains`，也禁止只用 `endsWith("example.com")`。域名规则与输入采用相同的 ASCII 小写和单个尾随点规范化。

### 5. 规则顺序示例

```text
1. domain_exact   blocked.example.com   → REJECT
2. domain_suffix  example.com           → DIRECT
3. domain_suffix  local                 → DIRECT
4. ip_cidr        192.168.0.0/16         → DIRECT
5. ip_cidr        10.0.0.0/8             → DIRECT
6. ip_cidr        172.16.0.0/12          → DIRECT
7. final                                 PROXY(main)
```

`blocked.example.com` 被第 1 条拒绝，不会被第 2 条直连。把两条交换后结果相反，应由配置检查器发出遮蔽提示，但禁止偷偷重排。

`192.168.2.10` 直接命中 CIDR；`nas.example.net` 即使实际会解析为 `192.168.2.10`，也不会自动命中 CIDR，因为首版规则引擎不执行 DNS。必须显式添加相应域名 DIRECT 规则，或交给 final。

### 6. 严格的无解析匹配

首版 `dns.resolve_for_routing` 必须为 `false`。对于 Domain 目标，`ip_cidr` 返回 `NOT_APPLICABLE`，绝不调用解析器，也不使用操作系统缓存或历史会话结果做隐式匹配。

路由完成后，DIRECT 解析到 IP 只是执行已选定动作；**不重新跑普通路由规则**。数值目标安全检查仍然必须执行，它可以拒绝地址，但不能把 DIRECT 改成 PROXY。

这样可以保证：域名一旦命中 PROXY，或落到 PROXY final，本服务不会为了“看看是不是国内 IP”提前泄露该目标名称。

### 7. 决策伪代码

```text
route(target, snapshot):
  for rule in snapshot.routing.rules:
    if matcherNotApplicable(rule, target):
      trace(rule.id, NOT_APPLICABLE)
      continue
    if matches(rule.match, target):
      return decision(rule.action, rule.outbound, rule.id, snapshot.id)
  return decision(snapshot.routing.final, matchedRuleId="__final__")
```

PROXY 动作的 `outbound` 必须在快照中存在且能力兼容；不存在是配置错误，不是改走 DIRECT 的理由。DIRECT/REJECT 不允许带 outbound。

资源准入、已知数值目标的安全拦截发生在普通路由之前；域名直连的解析结果安全检查发生在路由之后。两类拦截必须以 `security.*` 原因记录，不能伪装成普通规则命中。

### 8. 可解释结果

计划提供的内部调试接口：

```text
explain(Target("www.example.com",443), snapshot)
```

```json
{
  "snapshot_id": "sha256:...",
  "target": {"kind":"domain","host":"www.example.com","port":443},
  "steps": [
    {"rule_id":"blocked","result":"NO_MATCH"},
    {"rule_id":"example-direct","result":"MATCH"}
  ],
  "decision": {"action":"DIRECT","rule_id":"example-direct"},
  "target_dns_owner":"system",
  "dns_performed":false
}
```

`explain` 是纯决策模拟，不建立连接、不查询 DNS。完整目标只允许出现在用户主动请求的本机诊断中，默认日志仍按脱敏策略。

### 9. 规则缓存与热更新

首版不要求路由缓存；按序线性扫描作为正确性基准。优化成后缀树或 CIDR 索引时，仍必须返回**原始序号最靠前的命中项**。

如增加缓存，键至少包含 `snapshotId + targetKind + canonicalHost + port`；不能仅按域名缓存，否则端口规则会被绕过。规则更新后，新会话用新快照，已建立连接不迁移。

### 10. 未来的“先 DNS 再按 IP”功能

此版本不实现；配置为 `resolve_for_routing=true` 必须明确拒绝，不能静默忽略。

未来扩展必须另行规定：何时查询、允许哪个解析器、一个域名多 IP 分属不同动作如何处理、是否允许本地 DNS 暴露、连接是否固定到参与判断的 IP，以及 DNS 失败时的行为。不能简单采用“任意一个 IP 在直连网段就全部直连”。

GEOIP 也需要数据来源、版本和更新策略，不应把“看起来像国内域名”当作准确地域判断。

---

<a id="doc-05-dns-and-addresses"></a>

## 05 · DNS 职责、地址选择与安全边界

[返回目录](#doc-readme)

### 1. 三种解析要分开看

| 用途 | 例子 | 谁负责 |
|---|---|---|
| Client 自己的解析 | 应用选择 SOCKS4 前已把域名转成 IPv4 | 应用及操作系统，不在本入口控制范围 |
| Target DNS | DIRECT 时把 `example.com` 转成地址 | 本服务调用系统解析器 |
| 节点名称解析 | 节点配置中使用名称 | 配置装配层负责；入口消费 Wire 已校验的实际端点 |

PROXY 域名路径将完整 NetworkAddress 交给 Wire；具体名称编码属于 Wire，入口不复制该逻辑。

**本稿不提供 UDP/TCP 53 监听，不实现自定义 DNS 包处理，不要求应用把 DNS 服务器改成它。** 系统解析器内部可能使用 DNS、hosts、系统缓存或平台名称服务；本服务只调用解析接口，不接管这些基础设施。

### 2. 强制行为矩阵

| 请求目标 | 决策 | 本服务目标解析 | 出站携带什么 |
|---|---|---|---|
| IPv4 | DIRECT | 不解析 | 连接该 IPv4 |
| IPv4 | PROXY | 不解析 | 向 Wire 提交数值 NetworkAddress |
| Domain | DIRECT | 解析一次取得本会话候选集合 | 连接选定数值 IP |
| Domain | PROXY | **禁止解析** | 向 Wire 提交域名 NetworkAddress |
| 任意 | REJECT | 不解析 | 无出站 |

表中的“解析一次”指本会话发起一次逻辑解析操作；操作系统为 A、AAAA、CNAME 或重试发送多少网络消息，不由此承诺限制。

节点配置装配时仍可能需要名称解析。因此“不在本地解析代理目标”不等于“本机绝不产生任何 DNS 流量”。应用此前自行解析过的域名，也无法在入口补救为未泄露。

### 3. Resolver 契约

```text
resolve(
  name: canonical ASCII hostname,
  purpose: directTarget,
  familyPolicy: dual,
  deadline: monotonic instant,
  networkContext: platform context
) -> orderedUniqueCandidates[IPAddress]  // 最多 16 个
```

错误至少区分 `NAME_NOT_FOUND`、`TEMPORARY_FAILURE`、`TIMEOUT`、`NO_USABLE_ADDRESS`、`CANCELLED`；底层平台不能精确区分时，不得编造 NXDOMAIN。

首版最多并发 16 个实际底层解析任务，候选最多 16 个。超时不等于底层阻塞系统调用已经退出：必须让并发额度覆盖真实底层任务生命周期，并丢弃过期结果，禁止靠无限创建新线程逃避超时。

域名应作为绝对名称处理，避免自动附加搜索域访问另一个目标。适配层需通过平台方法或显式绝对名称方式实现，并测试 hosts、正常 DNS 和 `.local` 行为；不假定简单拼接尾随点在所有系统上拥有完全相同语义。

### 4. DIRECT 域名路径

```text
1. RuleEngine 已选 DIRECT。
2. 系统解析，取得 A/AAAA 数值候选；去重，限制数量。
3. 对每个候选执行 TargetGuard；拒绝的候选不得拨号。
4. 没有可用候选 → TARGET_ADDRESS_DENIED 或 NO_USABLE_ADDRESS。
5. 只使用这组已检查的数值 IP 进行 TCP 拨号。
6. 成功后不因 DNS 改变而重定向当前连接。
```

有的候选被拒绝、有的可用时，过滤被拒绝候选后可继续；日志记录过滤数量，不必泄露所有地址。

**禁止**先解析检查一个 IP，然后再让 `connect(hostname)` 重新解析。连接必须使用已检查的数值地址，避免校验与实际拨号不一致。

IPv4/IPv6 可采用 RFC 8305 思路做有界错峰竞争；本稿默认间隔 250 ms、同时最多两个尝试，总连接期限不延长。具体排序算法是实现选择，不宣称仅一个延时参数就完整实现 RFC 8305。[S08](#s08)

失败候选可以换同一候选集合中的下一个地址；这是目标地址选择，不是把业务数据重放。任何目标都不得在入口成功写完前收到客户端业务字节。

### 5. PROXY 域名路径

保留规范化名称，不发起本服务的 Target DNS，不为了日志、GEOIP、预热、测速、证书查询而旁路解析。

如果所选 Wire 无法表达名称目标，该操作明确失败；禁止入口偷偷解析成 IP 后重试。

这里的保证是入口不为 PROXY 业务目标执行本地 DNS。Wire 自身的解析行为按其契约单独验收，不能从本地成功回复推断整机 DNS 行为。

### 6. 节点端点与防递归

Wire 提供配置装配后确定的实际节点端点。Connection 连接该端点并向 Wire 提交原始逻辑业务目标；不为节点重复运行目标路由，不在入口解析节点配置名称。

```text
PROXY target=example.com:443
→ Core 选择 Wire
→ Connection 连接 Wire.getEndpoint()
→ Wire.start(target) / decodeInbound 推进启动
→ ready 且必要控制输出写完
```

显式节点与业务目标具有不同的授权语义。实际节点端点仍须检查自身监听回环；通配监听按实际本机地址集合比较，不能只比较配置字符串。

### 7. 缓存

本稿默认不增加应用层 DNS 缓存；系统缓存仍可能存在。这样可以先避免伪造 TTL 和跨网络环境缓存混用。

未来添加应用缓存时，必须区分目标解析与节点解析，记录解析来源、接口/网络上下文和有效期。系统 API 未提供真实 TTL 时，不能把自定 60 秒标注成“DNS 返回 TTL”。不得跨网络切换无限复用结果，也不得因缓存命中而绕过 TargetGuard。

### 8. 安全边界与远端盲区

已知数值目标执行默认拒绝网段；DIRECT 域名解析后再执行相同检查。自身监听地址的保护不可通过普通 DIRECT 规则绕过。

**把名称交给上游意味着本地不知道远端最终解析到了什么。** 因此本地无法同时保证“完全不解析代理目标”与“精确阻止这个名称在远端解析成内网/回环地址”。需要由远端代理执行出站 ACL、解析结果过滤和自身回环保护；不具备这些措施的远端不能被描述为已获得完整 SSRF 防护。

`BND.ADDR` 不是远端最终目标地址，不能用于弥补这个盲区。

### 9. 需要真正 UDP 代理时

本规格的入站 TCP 字节中可以承载应用自己的任意 TCP 协议，包括应用主动使用的 DNS-over-TCP，但这不等于支持 UDP DNS，也不代表本服务理解 DNS 消息。

真正的 UDP 转发需要另行定义 SOCKS5 UDP ASSOCIATE 或其他 UDP 入口、关联寿命、数据报封装、源校验、分片与 NAT。不要把这项能力附会到 SOCKS4 上。[S03](#s03)

---

<a id="doc-06-outbound-connectors"></a>

## 06 · DIRECT 与抽象 Wire

[返回目录](#doc-readme)

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

<a id="doc-07-session-and-relay"></a>

## 07 · 会话生命周期、转发与资源控制

[返回目录](#doc-readme)

### 1. 主状态机

```text
Accepted → ReadingRequest → Validating → Routing
                    → OpeningOutbound → ReplyingSuccess → Relaying
                                                  Relaying → HalfClosed → Closed

任意成功响应开始前的可恢复协议失败 → ReplyingFailure → Closed
未知版本 / 准入失败 / 不可写 / 强制取消 → Closed
成功响应开始后的任何失败 → Closed，禁止再写 SOCKS 失败包
```

一个会话只能有一个终态原因；多个并发失败由 SessionCoordinator 以首次提交为准，后续错误仅作为可选次级诊断，不重复释放资源、不重复计数。

### 2. 默认预算

所有数值为本稿设计初值，不是性能承诺。

| 限制 | 默认值 | 计时起点 |
|---|---:|---|
| 入口握手绝对期限 | 10 s | TCP accept |
| 出站总建连期限 | 20 s | 路由决策完成 |
| 单次逻辑 DNS 期限 | 5 s | 发起解析，含等待解析额度 |
| 单候选 TCP 建连期限 | 8 s | 发起该候选 |
| Wire 启动期限 | 8 s | 下游 Channel 就绪后至所需启动处理完成 |
| 入口响应写期限 | 1 s | 首次尝试写该响应 |
| 完整双向 relay 空闲期限 | 0，关闭 | 最近实际业务转发进展 |
| 半关闭最大存活期限 | 30 s | 首次观察到某一方向 EOF |
| 优雅停机排空期限 | 30 s | 接到停止命令 |

阶段 deadline 使用 `min(阶段起点 + 阶段预算, 出站总deadline)`，没有每读取一点数据就续期的行为。入口响应写有独立 1 s 的收尾预算；所以 20 s 出站超时之后最多再用这一预算发送失败响应。

操作系统时钟调整不能延长会话预算；使用单调时钟。暂停/休眠后的行为必须按平台可用的连续时钟语义验证，不能用墙钟日期作超时计算。

### 3. 成功响应屏障

```text
outbound ready
  → 取得单一客户端写入权
  → 标记 replyState=started
  → writeAll(00 5A 00 00 00 00 00 00)
  → replyState=completed
  → 把 clientRemainder 写给出站
  → 把 upstreamRemainder 写给客户端
  → 启动或继续各自方向的有序转发
```

两个方向的 remainder 可以在屏障后分别并发发送，但同一方向的后续读取/写入不得超过其 remainder。成功响应前不向目标发送客户端提前数据；成功响应前也不向客户端发送上游业务数据。

若写入成功响应失败，直接结束并关闭出站，不另写失败。不把返回前发送了几字节推测为“客户端已经收到完整成功”。

### 4. 双向 relay

```text
pump(A, B):
  先写本方向 remainder
  loop:
    获取本方向及全局缓冲额度
    item = await A.read(maxBytes=min(16KiB, 可用额度))
    if item == EOF:
      await B.finishWrite()   // 本方向已排队字节先完成
      return NormalEOF
    await B.writeAll(item.bytes)
    记录成功转发字节数，释放额度
```

两条 pump 独立运行。某条 pump 正常 EOF 不应自动取消另一条；只有错误、取消、半关闭期限或两个方向都结束才统一清理。

不得解析 HTTP Content-Length、修改 Host、终止目标 TLS、自动解压或插入心跳字节。应用字节流必须原样有序。

`writeAll` 表示底层适配器已消费/接受这些字节，不是远端应用已读取。吞吐指标不能冒充端到端业务完成量。

### 5. 背压与内存

| 项目 | 默认 |
|---|---:|
| 最大已接纳会话 | 512，含握手与 relay |
| 最大尚未完成成功响应的会话 | 64 |
| 单次读取上限 | 16 KiB |
| 单方向 relay 高水位 | 64 KiB |
| 单方向 relay 低水位 | 32 KiB |
| 握手后的提前数据上限 | 64 KiB / 方向 |
| 全局用户态缓冲预算 | 64 MiB |

高水位包含排队和 in-flight 的用户态字节；必须先预留额度再 read，不能让大量异步回调先分配完再做限制。无额度就暂停源读取，写入完成后公平唤醒等待者。

简单的单方向“read 一块 → await writeAll → 再 read”即可满足背压，无需先实现复杂队列。禁止每个 read 都创建一个无界并发写任务。

握手缓冲、提前数据和 relay 转移所有权时，只计费一次；同一底层大缓冲的 slice 不应因表面长度很小而低估保留内存。实现要避免一个 1 字节切片持有数 MiB 原始存储。

`512 × 2 × 64 KiB = 64 MiB` 只是方向预算上界的算术，尚未包括其他缓冲，因此全局预算必须独立执行。内核 socket 缓冲、TLS 内部缓冲、对象和运行时内存不包含在这个 64 MiB 中，不能宣称 RSS 被该值封顶。

### 6. 半关闭

TCP 两个方向可以独立关闭；一个方向 EOF 后，另一个方向仍可继续发送，参见 [S06](#s06)。

```text
Client 发完请求并 shutdown(write)
→ Local 读到 EOF
→ Local 把已读业务数据写完
→ Local 对出站 finishWrite
→ 保留 Remote → Client 的响应方向
→ 收到远端 EOF 后结束
```

半关闭期限默认 30 秒，是本产品为了回收失联会话的限制，可能截断长时间单向协议；配置允许设为 0 禁用，但要明确资源风险。配置不为 0 时不因反向零星数据重置这个绝对期限。

对客户端请求后紧跟 FIN 的场景，头部完成与 EOF 都要保留，先建连、回复成功、转发剩余载荷，再向出站传递 EOF。不要把 EOF 直接等同于整个连接不可写。

PROXY 在下游正常 EOF 时调用 Wire.finishInbound 检查完整性；本地输入结束由 Connection 排空写入并半关闭 Channel，不能把关闭整条 Channel 当作单向结束。不满足反向继续读取测试时，不得宣称通过半关闭验收。

### 7. 异常、取消和清理

RST、读写错误、显式停止会话、超时：取消两个方向并关闭所有候选及主 socket，释放缓冲、解析任务观察者、会话名额和待握手名额。

正在等待系统解析时会话取消，也应立即从会话视角结束；底层不可取消调用继续受解析池限额控制，不允许晚到结果重新拨号。

为每个异步阶段附带 session generation/token。回调返回时检查仍为同一代且状态允许，避免取消后旧回调创建新连接。

### 8. 服务生命周期

启动：加载完整配置 → 校验 → 编译快照 → 绑定监听 → 发布 ready。端口占用必须启动失败，不自动改到其他端口。

停止：先停止 accept → 已接受会话继续排空 → 到达停机期限取消余下会话 → 释放监听与后台资源。控制面已设置系统代理时，恢复系统代理是控制面职责，应与核心停机协调，不能在核心中猜测并覆盖用户设置。

热更新普通规则/节点只影响新会话；修改监听地址/端口或全局资源配置，首版要求重启，不尝试半应用。配置生命周期以 [08](#doc-08-configuration) 为准。

### 9. 禁止的自动补救

禁止 PROXY 失败改 DIRECT；禁止放宽 Wire 要求的校验；禁止成功响应后切节点重放；禁止目标无响应就假定目标需要本地 DNS。

这些行为即使偶尔“让网页能打开”，也改变了调用方的隐私或传输语义，必须作为未来显式产品能力评审，不能隐藏在异常处理里。

---

<a id="doc-08-configuration"></a>

## 08 · 配置文件与启动/热更新校验

[返回目录](#doc-readme)

### 1. 文件格式

使用 UTF-8 JSON，顶层 `schema_version=1`。完整示例见 [Wire 路由配置](#attachment-examples-config-wire-route-json)、[直连配置](#attachment-examples-config-direct-only-json)、[受控测试配置](#attachment-examples-config-test-json)。

所有顶层和子对象的已定义字段均必须提供，除非 schema 的分支明确声明为可选。本文“默认值”是创建新配置时采用的初值，不意味着运行时漏填字段会悄悄获得同样设置。禁止注释、重复 JSON key、未知字段和未支持的枚举值。

结构校验采用 [config.schema.json](#attachment-config-schema-json)，之后执行本章跨字段、数值地址和实现能力校验。JSON Schema 合法不等于配置已经可以启用。

### 2. 关键片段

以下只是完整配置的节选，不能独立启动服务：

```json
{
  "listen": {
    "host": "127.0.0.1",
    "port": 1080
  },
  "routing": {
    "rules": [
      {
        "id": "local-direct",
        "match": {
          "type": "domain_suffix",
          "value": "local"
        },
        "action": "DIRECT"
      },
      {
        "id": "lan-direct",
        "match": {
          "type": "ip_cidr",
          "value": "192.168.0.0/16"
        },
        "action": "DIRECT"
      }
    ],
    "final": {
      "action": "PROXY",
      "outbound": "main"
    }
  },
  "outbounds": [
    {
      "id": "main"
    }
  ]
}
```

`127.0.0.1:1080` 是示例入口，`main` 只表示运行配置中的节点引用。对应 Wire 或节点端点不可用时，PROXY 路径失败，不自动转直连。

### 3. 顶层字段

| 字段 | 说明 |
|---|---|
| `schema_version` | 必须为 1 |
| `listen` | 一组 TCP 监听端点；首版仅一个监听器 |
| `limits` | 会话、超时与缓冲预算 |
| `dns` | 系统解析接口策略，不是 DNS 服务监听配置 |
| `routing` | 有序规则及显式 final |
| `outbounds` | 运行配置中的不透明节点引用；不定义节点协议字段 |
| `security` | 客户端 CIDR、目标地址防护、精确例外 |
| `observability` | 日志级别、目标脱敏、内部指标开关 |

配置文件上限 2 MiB；最多 10,000 条规则和 256 个节点。节点 ID、规则 ID 在各自命名空间唯一，最长 64 个 ASCII 字符，只接受字母、数字、点、下划线和连字符，且必须以字母或数字开头。`__final__` 因而保留给内部使用。

### 4. listen 与入站权限

`listen.host` 必须是数值 IPv4 或 IPv6，禁止 hostname，避免监听目标解析漂移。默认 `127.0.0.1`；需要 IPv6 回环监听时显式使用 `::1`。首版不承诺 IPv6 socket 自动接收 IPv4，必须按平台行为验证。

监听非回环或通配地址必须显式 `allow_lan_listen=true`，且 `allowed_client_cidrs` 非空。接受 TCP 后，在进入解析器前检查客户端源地址；客户端端口不能作为可信身份。

`allowed_client_cidrs` 是准入白名单，不是目标分流规则。允许 LAN 来源不会自动给代理增加用户认证或链路加密。

### 5. DNS 字段

| 字段 | 本稿允许值/初值 |
|---|---|
| `resolver` | 必须 `system`；只用于入口 DIRECT 目标解析 |
| `resolve_for_routing` | 必须 `false`；true 为不支持的功能 |
| `application_cache` | 必须 `false`；不影响操作系统缓存 |
| `direct_address_family` | 必须 `dual`，表示可使用 A/AAAA 候选 |
| `max_concurrent_queries` | 1..16，默认 16 |
| `max_addresses` | 1..16，默认 16 |
| `connect_candidate_delay_ms` | 10..2000，默认 250 |

PROXY 将域名目标交给 Wire；入口配置不定义 Wire 的名称处理策略，节点配置装配中的解析与入口目标 DNS 分开。

### 6. 节点引用与 Wire 配置边界

出站配置在本文只表示对运行配置中节点的引用。`outbounds` 示例中的 `id` 由配置装配层关联到模型规定的节点 UUID；这些示例是入口策略资料，不是完整节点配置，也不是新增的 Magent 公共配置 API。

Core 根据引用选择可用 Wire；具体节点协议、凭据、启动参数和端点构造由节点模型及 Wire 配置负责。入口不得增加自己的出站 `type`、认证方法、传输协议或远端控制消息字段。默认节点和规则引用的校验时机遵循模型规范；选中后不可用必须失败，不能解释为 DIRECT。

运行时连接实际节点端点前仍须执行适用的端点安全检查。节点域名如需预先解析，由配置装配边界完成；入口只消费 Core / Wire 提供的实际端点，不为代理业务目标执行本地 DNS。

### 7. 资源限制初值

| 字段 | 默认值 |
|---|---:|
| `max_sessions` / `max_pending_handshakes` | 512 / 64 |
| `handshake_timeout_ms` | 10000 |
| `connect_total_timeout_ms` | 20000 |
| `dns_timeout_ms` | 5000 |
| `dial_timeout_ms` / `wire_start_timeout_ms` | 8000 / 8000 |
| `reply_write_timeout_ms` | 1000 |
| `relay_idle_timeout_ms` | 0，禁用 |
| `half_close_timeout_ms` / `shutdown_grace_ms` | 30000 / 30000 |
| `read_chunk_bytes` | 16384 |
| `early_data_limit_bytes` | 65536 |
| `relay_high_water_bytes` / `relay_low_water_bytes` | 65536 / 32768 |
| `global_buffer_budget_bytes` | 67108864 |

跨字段必须满足：`pending <= sessions`；`0 < low < high`；`read_chunk <= high`；`read_chunk <= early_data_limit`；全局缓冲预算至少容纳 `max_pending_handshakes × 1024 + 2 × read_chunk_bytes`。这只是最低可运行空间，不等于所有会话能同时填满方向缓冲。

入口协议字段上限固定为 [02](#doc-02-inbound-wire-protocol) 的 255/254/1024，不通过配置放宽。

### 8. 目标安全配置

`deny_target_cidrs` 是本稿默认阻止的数值目标集合，包括未指定/保留用途、回环、链路本地、组播等示例范围。它不是穷尽所有网络安全风险的标准名单；实际默认集合以示例配置为准。

`allow_target_endpoints` 只接受 `{"host":"数值IP","port":整数}`，精确到端口。判定顺序：

```text
本服务自身监听端点 → 无条件拒绝
精确 allow_target_endpoints 命中 → 允许绕过 deny CIDR
deny_target_cidrs 命中 → 拒绝
其余 → 允许继续执行既定路由
```

例外不绕过普通 REJECT 路由，也不改变 DNS 决策。测试配置仅允许 `127.0.0.1:18080`，不开放整个回环网段。

来源/目标安全名单可包含 IPv4 或 IPv6 CIDR；普通 `routing.rules` 的 `ip_cidr` 首版只允许 IPv4，因当前入口没有可供其匹配的 IPv6 字面量。

所有 CIDR 要求数值合法且为规范网络地址，例如 `192.168.2.3/24` 拒绝，要求写 `192.168.2.0/24`。IPv4-mapped IPv6 在地址比较前规范化为 IPv4，防止绕过 IPv4 deny。

### 9. 校验流水线

```text
大小限制 → UTF-8/JSON/重复 key → schema → 跨字段约束
→ 域名/IP/CIDR 规范化 → ID 唯一性 → outbound 引用
→ listener 权限 → 明文许可 → 密钥引用与能力
→ 编译完整快照 → 尝试监听或原子发布
```

schema 不覆盖的必需检查：ID 重复、引用不存在、CIDR host bits、错误 hostname、节点引用非法、监听与节点的数值自回环、Wire 能力不可用、配置字段的跨版本不兼容。

DNS 节点解析后的自回环等运行时才能确定的事项在实际建连时再次检查，不能只靠启动时字符串比较。

### 10. 热更新

可热更新部分：`routing`、`outbounds`、`observability`。其他字段改变必须明确提示“需要重启”，不半应用。

一次更新以完整候选配置校验。失败保留旧版本；成功后原子替换新会话引用。快照 ID 使用规范化非密钥配置内容的摘要，引用的秘密本身不进入摘要。

已存在会话固定旧快照和既有通道；新建会话采用新版本。密钥轮换需要 SecretProvider 的显式版本策略或新配置发布；不要把“配置快照不变”误解为底层密钥永远不变。

### 11. 拟议控制接口，不是现有可执行命令

```text
validateConfig(bytes) -> valid + warnings | errors
applyConfig(bytes) -> newSnapshotId | unchanged + errors
explainRoute(target, snapshotId?) -> deterministic trace
getStatus() -> listening endpoint, snapshot, bounded counters
stop(grace) -> stopped
```

首版通过进程内接口供 UI/CLI 使用，不额外开放未认证的管理 HTTP 端口。附带探针和文档校验脚本是实际文件，但上述核心 API 仍需开发。

---

<a id="doc-09-errors-security-observability"></a>

## 09 · 错误、安全与可观测性

[返回目录](#doc-readme)

### 1. 错误结构

```text
ProxyError {
  code: stable enum
  phase: admission | inbound | route | dns | transport | upstream | reply | relay
  cause?: underlying error     // 仅内部，不直接打印凭据或载荷
  retryable: false              // 本稿不自动重试业务通道
}
```

外部 SOCKS4 的失败表达很少；内部错误不能直接把数字塞进 `RESULT`，也不能写 JSON 或 HTTP 错误响应。[S01](#s01)

### 2. 映射规则

“发送 5B”都以**已识别版本 4、尚未开始回复、写方向仍可用**为前提。回复一旦开始或进入 relay，只关闭，不再注入协议字节。

| 内部 code | 典型原因 | 入口处理 |
|---|---|---|
| `CAPACITY_EXCEEDED` | 会话/待握手名额不足 | 准入阶段直接关闭 |
| `UNSUPPORTED_VERSION` | 第一字节不是 04 | 直接关闭 |
| `UNSUPPORTED_COMMAND` | BIND 或其他命令 | 5B + 关闭 |
| `INVALID_PORT` / `INVALID_DOMAIN` | 无效目标输入 | 5B + 关闭 |
| `USERID_TOO_LONG` / `DOMAIN_TOO_LONG` / `HEADER_TOO_LARGE` | 超出入口限制 | 5B + 关闭 |
| `TRUNCATED_REQUEST` / `HANDSHAKE_TIMEOUT` | 头部不完整或过期 | 能写则 5B，否则关闭 |
| `EARLY_DATA_LIMIT` | 实际持有提前字节超限 | 屏障前 5B；屏障后关闭 |
| `RULE_REJECT` | 规则明确拒绝 | 5B，无 DNS/出站 |
| `TARGET_ADDRESS_DENIED` / `SELF_PROXY_LOOP` | 安全防护 | 5B，无违规拨号 |
| `DNS_TIMEOUT` / `DNS_FAILED` / `NO_USABLE_ADDRESS` | 系统解析失败/无可用候选 | 5B |
| `CONNECT_TIMEOUT` / `CONNECTION_REFUSED` | 下游 Channel 无法建立 | 5B |
| `WIRE_START_FAILED` | Wire 启动失败 | 5B，无 DIRECT 回退 |
| `WIRE_REJECTED` | Wire 报告操作被拒绝 | 5B，保留原始原因 |
| `WIRE_DECODE_FAILED` | Wire 输入非法或 EOF 截断 | 5B；已成功则只关闭 |
| `OUTBOUND_ADDRESS_UNSUPPORTED` | 不能传递目标地址类型 | 5B，不临时本地解析 |
| `RELAY_IO_ERROR` / `RELAY_IDLE_TIMEOUT` | 建连后错误/空闲限制 | 只关闭 |
| `HALF_CLOSE_TIMEOUT` | 单方向已关闭但对向未结束 | 只关闭 |
| `CANCELLED` / `SHUTDOWN` | 主动取消/退出 | 尽力清理，不保证能回复 |

底层解析错误可以保留 `NAME_NOT_FOUND`、`TEMPORARY_FAILURE` 子原因；主会话枚举仍用 DNS_FAILED，不把系统模糊错误伪装成准确 DNS RCODE。

### 3. 威胁模型

入口只绑定回环，也不能假定所有本机进程都可信。恶意本机程序可以发超长头、慢速握手、巨量连接，或请求本机敏感服务。

启用 LAN 监听后，攻击面进一步包含其他设备。SOCKS4 USERID 是客户端声明的标识，不是密码证明；本产品没有入站用户认证，不得宣称它足以安全地暴露到公网。

### 4. 必须执行的防护

采用回环监听默认值和显式 LAN 授权；在解析之前校验来源 CIDR。固定头/字符串上限、绝对握手期限、解析并发上限、会话上限以及全局缓冲预算必须同时生效。

DNS 结果必须经过数值目标检查，并在随后连接中固定使用。禁止目标访问本服务自身监听端点；相同检查适用于节点地址。IPv4-mapped IPv6 先规范化，不能用文本变体绕过。

默认拒绝目标网段中包含回环及链路本地范围；受控测试的精确例外见 [08](#doc-08-configuration)。节点端点有独立授权语义，不能把允许某个节点扩展为允许任意本机业务目标。

代理域名的远端解析盲区须由节点侧 ACL 处理；本地不能声称单靠域名透传就保证远端不会访问敏感地址。详见 [05](#doc-05-dns-and-addresses)。

### 5. 密钥与加密

不记录原始 USERID、节点凭据、控制帧、业务字节或完整配置秘密。USERID 不能用作本地身份认证，也不能用作 Wire 的节点凭据。

具体出站的安全机制由 Wire 及节点配置负责；入口不解释或放宽这些要求，不因本地 SOCKS4 握手成功就宣称链路受保护。

### 6. 日志事件

```json
{
  "event":"session.closed",
  "session_id":"s-...",
  "snapshot_id":"sha256:...",
  "inbound_protocol":"socks4a",
  "target_kind":"domain",
  "target_host":"[redacted]",
  "target_port":443,
  "route_action":"PROXY",
  "rule_id":"__final__",
  "outbound_id":"main",
  "target_dns_owner":"upstream",
  "readiness":"upstreamAccepted",
  "duration_ms":812,
  "client_to_remote_payload_bytes":1234,
  "remote_to_client_payload_bytes":5678,
  "close_reason":"NORMAL_EOF"
}
```

默认 `target_logging=redacted`，主机名和 IP 不出现在普通日志；仅保留类型、端口和规则结果。`full` 必须由用户显式选择，并对敏感日志设置本地权限与保留期限。

默认只输出一次终态摘要；debug 可增加阶段事件，但禁止让异常输入无限放大日志。日志输出队列必须有界并允许丢弃非关键 debug，不能阻塞 relay。

关键事件包括 `config.applied`、`config.rejected`、`listener.ready`、`session.rejected`、`dns.completed`、`outbound.accepted`、`session.closed`。含用户输入字段必须转义，禁止日志换行注入。

### 7. 指标定义

| 指标 | 语义 | 允许的低基数维度 |
|---|---|---|
| `proxy_sessions_active` | 当前已接纳但未结束会话 | 无 |
| `proxy_pending_handshakes` | 未完成入口成功响应的会话 | 无 |
| `proxy_connections_total` | 终态连接总数 | action、result、error_code |
| `proxy_setup_duration_seconds` | 从 accept 至成功响应完成/建立失败 | action、result |
| `proxy_payload_bytes_total` | 已由目的流适配器消费的业务字节 | direction、action |
| `proxy_user_buffer_bytes` | 被预算管理器计费的用户态缓冲 | buffer_class |
| `proxy_dns_operations_total` | 本进程逻辑解析次数 | purpose、result |
| `proxy_upstream_failures_total` | 上游建立失败次数 | outbound_id、phase |
| `proxy_log_dropped_total` | 丢弃的日志记录数 | level |

不要把目标域名、目标 IP、sessionId、完整错误文本作为指标 label。规则 ID 只出现在日志/诊断，不默认成为时间序列维度。

`metrics=true` 仅启用内部计数，不意味着新增一个公网或本地 HTTP 监听端口；导出方式属于控制面实现。

### 8. 现场定位顺序

先确认客户端确实使用 SOCKS4a 而不是已经解析后的 SOCKS4；再看 target_kind 和命中规则。随后区分目标 DNS 与节点 DNS，检查选中的 outbound 和具体失败 phase。

最后检查 Wire 就绪与业务断开是否分开：本地成功后目标应用再断开，不能倒推为本地解析器失败。默认脱敏不够诊断时，用户可在本机受控时间窗开启完整目标日志，但不得开启业务载荷日志来替代结构化观测。

---

<a id="doc-10-tests-and-acceptance"></a>

## 10 · 测试向量、故障注入与验收

[返回目录](#doc-readme)

### 1. 测试分层与环境

协议解析器、规则引擎、安全检查和预算管理须可脱离真实网络单测；系统解析、Channel 和 Wire 使用可控替身，再通过受控传输做集成验证。

测试环境包含本地入口、可观察启动和编解码行为的测试 Wire，以及支持回显、服务器先发、半关闭和限速的受控业务目标。具体出站协议不作为本地入口测试的固定依赖。

文档地址 `192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24` 只作示例，不假设可公网连通。[S13](#s13)

### 2. 入口解析向量

机器向量位于 [parser-vectors.json](#attachment-examples-parser-vectors-json)。十六进制字段的空格只为阅读方便，不属于线上报文。

| ID | 输入或构造 | 预期 |
|---|---|---|
| P01 | `04 01 01 BB CB 00 71 0A 00` | SOCKS4，203.0.113.10:443，消费 9 字节 |
| P02 | `04 01 01 BB 00 00 00 01 00` + `example.com\0` | SOCKS4a，Domain，消费 21 字节 |
| P03 | 4a 的最后标记字节 1..255 | 全部按域名模式 |
| P04 | `DSTIP=00 00 00 00` | 普通 IPv4，不等 DOMAIN；后续安全阶段拒绝该数值目标 |
| P05 | USERID 恰好 255 字节 + NUL | 接受；256 字节内容拒绝 |
| P06 | 合法 253 字节主机名、或附尾随点 254 字节 | 接受并规范化；总长/label 超限拒绝 |
| P07 | 空 USERID、非 UTF-8 USERID | 均允许解析；不作为认证 |
| P08 | 域名大小写、单个尾随点 | 规范化为相同目标 |
| P09 | 域名字段是规范 IPv4 文本 | 转成 IPv4，不查询 DNS |
| P10 | 版本 5；BIND；端口 0 | 分别版本/命令/端口错误 |
| P11 | 空域名、原始 UTF-8、URL、下划线、IPv6 文本 | 按产品限制拒绝 |
| P12 | 无 NUL；截断固定头 | 数据未结束时 NeedMore；EOF 或期限到达由会话判失败 |
| P13 | 合法头 + 任意二进制 payload | consumed 只包含头；尾部原样保留 |
| P14 | 头尾拼接第二个 SOCKS 请求 | 第二段是业务数据，不建立第二条隧道 |
| P15 | 数字简写、前导零、十六进制数值地址别名 | 拒绝，不送给宽松系统解析器 |

每个成功向量必须执行：完整输入；每个单切点分片；逐字节输入；随机多段分片；头部与载荷合并。分片方式不能改变解析结果。

参考 oracle 用于断言字节字段，不用于测量生产解析器复杂度。生产实现另外通过统计扫描次数验证线性扫描和有界内存。

### 3. 路由与地址测试

| ID | 场景 | 必须观察到 |
|---|---|---|
| R01 | 精确拒绝在后缀直连前 | REJECT，0 出站 |
| R02 | 调换上述规则顺序 | 按新顺序结果改变，不隐式优先精确 |
| R03 | example.com、a.example.com、badexample.com | 前两个后缀命中，最后一个不命中 |
| R04 | IP 目标遇到域名规则 | NOT_APPLICABLE，无反查 |
| R05 | Domain 目标遇到 CIDR 规则 | NOT_APPLICABLE，0 分流 DNS |
| R06 | 没有普通规则命中 | 使用显式 final |
| R07 | 相同主机不同端口 | port 规则结果分别正确 |
| R08 | PROXY 引用不存在的节点 | 配置拒绝，不回退 DIRECT |
| R09 | DIRECT 域名解析后命中另一个普通 CIDR 规则 | 不重新路由，只做安全过滤 |
| R10 | 调用 explain | 0 DNS、0 TCP，返回确定性 trace |

### 4. DNS 隐私与一致性

| ID | 场景 | 必须观察到 |
|---|---|---|
| D01 | SOCKS4 IPv4 DIRECT/PROXY | 本服务 Target DNS 均为 0 |
| D02 | SOCKS4a Domain DIRECT | 一次逻辑系统解析，连接被检查的数值候选 |
| D03 | SOCKS4a Domain PROXY | 入口 Target DNS 为 0；Wire 收到域名 NetworkAddress |
| D04 | 节点配置名称解析 | 配置装配与入口目标 DNS 分开；入口只消费实际节点端点 |
| D05 | 读取 Wire 实际端点 | getter 无 DNS / I/O；保持端点地址族与端口 |
| D06 | 解析结果含被拒绝与可用 IP | 过滤拒绝项；不拨号被拒绝项 |
| D07 | DNS 首次返回 A，第二次返回敏感地址 B | 一次会话不得二次按 hostname 拨号；实际使用 A |
| D08 | DNS 超时后返回成功 | 过期会话不再拨号；真实解析并发数仍有界 |
| D09 | 系统接口拿不到 TTL | 不声称取得/缓存了真实 TTL |
| D10 | 更换 Wire 实现 | 入口的 PROXY 目标 DNS 为零，失败不回退 DIRECT |

抓取网卡上的明文 UDP 53 只能覆盖一部分解析流量，不能证明没有系统缓存或加密 DNS。验收至少同时使用可注入 Resolver 计数、测试 Wire 收到的 NetworkAddress、以及真实集成环境的网络观测。

D03 的保证范围是本地入口发起的解析操作；客户端预解析、节点配置装配和 Wire 自身行为分别验收。

### 5. Wire 集成测试

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

### 6. 转发、并发与生命周期

| ID | 场景 | 必须观察到 |
|---|---|---|
| L01 | 双向传输固定种子的二进制数据 | 两端长度与 SHA-256 相同，包含 NUL 和任意字节 |
| L02 | 一个方向写入极慢 | 另一方向正常工作，用户态缓冲不越界 |
| L03 | 客户端请求后写半关闭 | 目标完整收到请求，客户端继续收到完整响应 |
| L04 | 服务器先写半关闭 | 客户端向服务端方向不被过早取消 |
| L05 | 入口成功响应只写了一部分后出错 | 不再发送另一份失败响应，出站释放 |
| L06 | 在每个 await/回调边界取消 | 不产生晚到新连接，不泄漏名额和 socket |
| L07 | 超过会话/待握手额度 | 新请求受控拒绝，已有流量保持有界 |
| L08 | 慢速逐字节握手 | 绝对 10 秒期限不被续期 |
| L09 | 规则更新 | 新会话走新规则，旧会话不改道 |
| L10 | 优雅停机与期限到达 | 先停止 accept，到期取消剩余会话 |
| L11 | 全局缓冲预算耗尽 | 暂停读、公平恢复；不是无限入队 |
| L12 | 半关闭最大期限非零/为零 | 分别有界结束/按显式禁用策略保留 |

### 7. 配置与安全测试

C01：重复 JSON key、未知字段、缺字段、未知 schema 版本全部失败。

C02：重复规则/节点 ID、无效 CIDR、错误引用、low >= high、pending > sessions、超长凭据均失败。

C03：配置更新失败保留旧快照；要求重启的字段不得局部生效。

S01：LAN/公网监听未显式授权时拒绝；来源 CIDR 在解析前生效。

S02：目标指向入口自身、节点指向入口自身、域名解析后指向入口自身，均阻止回环。

S03：精确目标例外不能绕过自身监听保护，IPv4-mapped IPv6 不能绕过 IPv4 deny。

S04：错误输入、认证失败、日志 debug 均不得输出密码、USERID 和业务载荷。

S05：模拟上游各阶段故障，目标直连适配器的调用次数必须为零。

### 8. 实际使用附带探针

需先实现并启动遵循本 SPEC 的服务。下面检查本地代理的握手，不自动启动它：

```bash
python3 tools/probe_socks4.py --proxy-port 1080 \
  --mode socks4a --host example.com --port 443
```

受控回显验收：在本机另行启动 `127.0.0.1:18080` TCP 回显目标，并让本服务使用 `examples/config.test.json` 监听 12080。

```bash
python3 tools/probe_socks4.py --proxy-port 12080 \
  --mode socks4 --host 127.0.0.1 --port 18080 \
  --fragment-size 1 --payload-hex 00010203ff68656c6c6f \
  --early-data --expect-echo --half-close
```

`fragment-size=1` 只保证探针按小块调用写入，操作系统仍可能合并 TCP 段；确定性的半包测试必须依赖 fake stream。

curl 官方提供 SOCKS4 与 SOCKS4a 选项，见 [S16](#s16)。例如：

```bash
curl --noproxy '' --socks4a 127.0.0.1:1080 https://example.com/
curl --noproxy '' --socks4  127.0.0.1:1080 https://example.com/
```

前者把名称交给本地入口；后者通常由 curl 先得到 IPv4。示例配置将 example.com 设为 DIRECT，所以这两条都不是“已证明走上游”的测试。验证 PROXY 时使用不命中 DIRECT 的自有测试域名并检查节点日志。

### 9. 文档包校验与生产验收不是一回事

```bash
python3 tools/validate_bundle.py
```

该脚本检查相对链接、JSON、schema（安装 jsonschema 时）、解析向量及分片一致性。它不检测你尚未编写的 Swift 服务，不跑真实 DNS 隐私验证，不给出产品性能成绩。

### 10. 实现发布门槛

REQ-001..018 对应的测试必须通过；基础对应关系如下：

| 需求 | 覆盖测试 |
|---|---|
| 001、002 | P01..P15、L01 |
| 003、004、005 | R01..R10、O04 |
| 006、007、018 | D01..D10 |
| 008、009 | O05..O12、L05 |
| 010、011 | L01..L04、L07、L11、L12 |
| 012 | O03、S05、L06 |
| 013、014、015 | S01..S04、D07 |
| 016、017 | C01..C03、L06、L09、L10 |

压力验收建议固定平台和版本，运行 512 个受控并发连接，覆盖 1 KiB、64 KiB、1 MiB 载荷与慢读场景；做不少于 30 分钟的稳定性观测。记录实际吞吐、CPU、RSS、句柄、任务数及峰值缓冲，并标注环境。上述负载是测试计划，不是已有测量结果。

---

<a id="doc-11-swift-implementation-plan"></a>

## 11 · Swift 实现边界与实施任务

[返回目录](#doc-readme)

实现沿用 MagentTCPConnection、Socks4Connection、MagentCore 和 Wire 的现有所有权边界。协议模型使用 MODELS_SPEC.md 中的构造入口；不为 SOCKS4 新建节点类型、具体出站 connector 或绕过模型校验的地址工厂。

解析器保存独立字段计数与扫描游标，按本 SPEC 返回 consumed / remainder。accepted Channel 与下游 Channel 在所属 EventLoop 上有序协作；Wire 不创建 Channel、线程或任务。半关闭、背压和关闭竞争按第 07 节验收。

| 阶段 | 工作 | 完成条件 |
|---|---|---|
| M1 | 入口模型适配、增量解析和回复 | P 系列通过 |
| M2 | Core 路由、地址安全与配置引用 | R、C、S 系列通过 |
| M3 | DIRECT、DNS、半关闭 | D、L 系列的直连路径通过 |
| M4 | 抽象 Wire 启动、编解码与失败路由 | O 系列通过 |
| M5 | 预算、取消、日志与服务生命周期 | 剩余 L/C/S 项通过 |
| M6 | 真实客户端与受控传输集成 | 字节、DNS 调用及资源回收证据完整 |

测试 Wire 与受控 Channel 用于验证入口集成边界。具体出站协议的互操作在对应 Wire 的验收中进行，不能用一次入口成功替代整条链路的验收。

---

<a id="doc-12-end-to-end-examples"></a>

## 12 · 从客户端报文到目标服务器的完整实例

[返回目录](#doc-readme)

本章使用本稿示例规则；所有“收到/发送”都是预期时序，不是已经运行过你的服务的抓包记录。文档 IP 用途见 [S13](#s13)。

### 实例 A：SOCKS4 IPv4 命中内网直连

客户端想访问 `192.168.2.10:8080`：

```text
04 01 1F 90 C0 A8 02 0A 00
```

解析得 `IPv4(192.168.2.10), port=8080`。目标不是默认拒绝的回环/链路本地等地址，普通路由命中 `192.168.0.0/16 → DIRECT`。

本服务不查询 DNS、不连接 main，直接建立到 `192.168.2.10:8080` 的 TCP 连接。成功后给应用写：

```text
00 5A 00 00 00 00 00 00
```

然后双向转发。客户端与目标都不会收到新的 SOCKS 头。如果该目标拒绝连接，应用收到 5B，本服务不会把它转交上游尝试另一条路径。

### 实例 B：SOCKS4a 域名命中直连

```text
目标：www.example.com:443
请求：04 01 01 BB 00 00 00 01 00
      77 77 77 2E 65 78 61 6D 70 6C 65 2E 63 6F 6D 00
```

域名规则 `example.com → DIRECT` 命中。本服务此时调用系统 Resolver 取得数值候选，通过安全检查后选定一个连接。

这说明“客户端使用 SOCKS4a”只把解析决策交给本地代理，**不意味着所有请求都由远端 DNS 解析**。最终解析位置由 DIRECT/PROXY 路径决定。

### 实例 C：SOCKS4a 域名选择 PROXY

目标为 `outside.example.net:443`，USERID 为空：

```text
04 01 01 BB 00 00 00 01 00
6F 75 74 73 69 64 65 2E 65 78 61 6D 70 6C 65 2E 6E 65 74 00
```

Connection 构造逻辑域名目标并提交 Core。Core 选择 Wire；Connection 连接该 Wire 的实际端点，将原目标传给 `start(handshake:)`，通过 WireResult 和后续 decodeInbound 完成启动。本服务不解析这个 PROXY 业务域名。

WireResult.ready=true 且必要控制输出写完后，本地回复 `00 5A 00 00 00 00 00 00`。后续业务数据经同一个 Wire 编解码。示例不规定任何节点协议报文，也不由本地回复推断远端应用已成功。

### 实例 D：客户端只交了 IP，却希望按域名走

应用曾解析 `some-site.example`，但选择 SOCKS4 只提交 `203.0.113.20:443`：

```text
04 01 01 BB CB 00 71 14 00
```

本服务只知道数值地址，不知道原域名。即使规则里存在 `some-site.example → DIRECT`，这条规则也不适用；按 IP 规则或 final 决策。

解决这个产品行为的办法是让客户端采用 SOCKS4a 并传名称，而不是在本服务里用反向 DNS 或“最近访问过这个 IP 的域名”猜测。

### 实例 E：规则拒绝，不产生额外连接

目标 `blocked.example.com:443` 命中最前面的 REJECT。本服务不解析名称，不连接 main，也不发送业务提前数据；只写：

```text
00 5B 00 00 00 00 00 00
```

内部记 `RULE_REJECT` 和规则 ID，默认不打印完整目标。

### 实例 F：上游不可用

与实例 C 相同，但 Wire 提供的实际端点不可用或拒绝连接。本地最多在本稿出站预算内失败，返回 5B。目标直连适配器调用次数必须为零。

用户看到“代理失败”比在不知情的情况下走直连更符合该规则契约。不得把默认路由 PROXY 理解为“优先代理，失败就算了”。

### 实例 G：半包、提前数据与上游服务器先发

```text
Client write #1：04 01 01
Client write #2：BB 00 00 00 01 00 65 78
Client write #3：61 6D 70 6C 65 2E 63 6F 6D 00 AA BB CC
```

解析器等到第三批才完成 21 字节头部；`AA BB CC` 进入 clientRemainder，不当作域名。出站成功后本地先完整写 5A，再把这三个业务字节交给出站。

如果 Wire 启动后立即解出 `HELLO\n`，它进入业务余量，也必须排在本地 8 字节成功响应之后。两个方向的余量各自保序。

### 实例 H：节点端点与业务目标分离

业务目标仍为 `outside.example.net:443`；Wire 提供已经装配的实际节点端点。Connection 只拨号节点端点，不将该端点再次交给业务规则引擎，也不替换业务目标。

节点配置的名称解析属于配置装配边界；入口的 Target DNS 计数仍为零。日志分别记录目标、节点引用及实际连接端点，名称默认脱敏。

### 实例 I：实际 TCP 业务的半关闭

客户端发送完整业务请求后关闭自己的写方向，等待响应。本地读取完已有数据后对出站调用 finishWrite，保留反向转发；目标响应结束之后再关闭整个会话。

如果本地在第一次 EOF 时直接取消所有任务，客户端可能永远收不到完整响应。此问题与域名规则或 SOCKS 字节编码无关，但属于代理可用性的核心验收项。

### 实例 J：为什么不需要单独 DNS 服务端口

整个链路只需要本地 TCP SOCKS 监听和出站连接。DIRECT 使用操作系统已有名称解析能力；PROXY 将域名 NetworkAddress 交给 Wire。没有任何步骤要求本服务开一个面向应用的 DNS 端口。

只有计划接管应用自己的 DNS 请求、提供 fake-IP、透明代理 UDP 或按解析结果做额外规则时，才需要另行设计相关能力；这些不属于本版。

---

<a id="doc-13-references"></a>

## 13 · 原始来源、设计决策与待确认事项

[返回目录](#doc-readme)

### 1. 来源说明

协议事实优先采用原始协议、RFC 和项目官方文档；代码仓库默认分支会变化，真正发布实现时应锁定依赖版本和参考 commit，不能把资料核对日期当作代码版本号。

以下是参考来源，不是本稿代码的依赖清单。本文没有逐字翻译完整 RFC，而是把线上字段与本产品独立设计分开。

<a id="s01"></a>
#### S01 · SOCKS4 原始协议

[Ying-Da Lee · SOCKS: A protocol for TCP proxy across firewalls](https://www.openssh.org/txt/socks4.protocol)

用于核对 CONNECT/BIND、请求与响应字段、状态码和 CONNECT 响应末六字节语义。镜像由 OpenSSH 站点提供；不是把 SOCKS4 当作 RFC 1928。

<a id="s02"></a>
#### S02 · SOCKS4a 原始扩展

[Ying-Da Lee · SOCKS 4A: A Simple Extension to SOCKS 4 Protocol](https://www.openssh.org/txt/socks4a.protocol)

用于核对 `0.0.0.x` 标记、USERID 后追加域名和名称向下一跳传递。

<a id="s03"></a>
#### S03 · RFC 1928 · SOCKS5

[RFC 1928](https://www.rfc-editor.org/rfc/rfc1928.html)

仅用于说明 SOCKS4 与另一种本地入口在地址及 UDP 能力上的区别，不定义出站报文。


<a id="s06"></a>
#### S06 · RFC 9293 · TCP

[RFC 9293](https://www.rfc-editor.org/rfc/rfc9293.html)

用于字节流与半关闭语义，重点为 §3.6.1。

<a id="s07"></a>
#### S07 · RFC 1035 · DNS 名称长度背景

[RFC 1035，§2.3.4](https://www.rfc-editor.org/rfc/rfc1035.html#section-2.3.4)

用于 DNS label/名称长度背景；本稿限定的是用于连接的主机名 ASCII 子集，并非宣称所有 DNS 名称都只能使用该子集。

<a id="s08"></a>
#### S08 · RFC 8305 · Happy Eyeballs v2

[RFC 8305](https://www.rfc-editor.org/rfc/rfc8305.html)

用于双栈连接候选调度思路。本文只给出有界候选和延时基线，不宣称已经完整实现该 RFC 的全部算法。

<a id="s09"></a>
#### S09 · curl 官方 SOCKS 实现

[curl · lib/socks.c](https://raw.githubusercontent.com/curl/curl/master/lib/socks.c)

用于交叉核对字节编码、部分读写和客户端行为；本稿未复制其实现代码。

<a id="s10"></a>
#### S10 · OpenSSH 官方实现

[openssh-portable · channels.c](https://raw.githubusercontent.com/openssh/openssh-portable/master/channels.c)

可检索 `channel_decode_socks4` 对照服务端解析流程；实现细节不是本稿全部产品限制的来源。


<a id="s12"></a>
#### S12 · RFC 5890 · IDNA 定义

[RFC 5890](https://www.rfc-editor.org/rfc/rfc5890.html)

用于 A-label / Unicode 名称边界。本入口不自行实现完整 IDNA 转换与显示安全策略。

<a id="s13"></a>
#### S13 · RFC 5737 · 文档 IPv4 地址

[RFC 5737](https://www.rfc-editor.org/rfc/rfc5737.html)

说明报文示例中的保留文档网段不是可用互联网目标服务。


<a id="s16"></a>
#### S16 · curl 命令行官方文档

[curl manpage](https://curl.se/docs/manpage.html)

用于 `--socks4`、`--socks4a` 的客户端互操作验证命令。

### 2. 本稿设计决策记录

| ID | 本稿选择 | 原因 / 代价 |
|---|---|---|
| ADR-01 | SOCKS4 与 SOCKS4a 一起支持 | 同时兼容 IP 客户端与域名分流；原生 IPv6/UDP 仍不具备 |
| ADR-02 | 首版只做 CONNECT | 收敛数据模型，明确拒绝 BIND |
| ADR-03 | Target 与 NodeEndpoint 分离 | 防止把节点当目标，便于 DNS 和日志归因 |
| ADR-04 | 分流不做 DNS | 可预测地保留域名代理路径；不能自动按解析 IP 分流域名 |
| ADR-05 | 默认 final PROXY(main) | 提供一个明确基线；用户可显式改 DIRECT |
| ADR-06 | PROXY 通过抽象 Wire | 入口不定义具体出站协议、认证或部署 |
| ADR-07 | 不提供 DNS 服务端口 | 显式代理入口可依赖系统解析/上游名称传递 |
| ADR-08 | 代理失败封闭处理 | 不偷偷泄漏或改变路径，代价是故障时不能自动可用 |
| ADR-09 | 已解析 DIRECT 候选固定为数值拨号 | 避免检查地址与实际地址不同 |
| ADR-10 | 显式半关闭与有界缓冲 | 保证通用 TCP 可用性和受控资源消耗 |
| ADR-11 | 无应用层 DNS 缓存与路由 DNS 扩展 | 避免 TTL、网络切换、多 IP 冲突先进入首版 |
| ADR-12 | 不嗅探应用载荷、不推断进程身份 | 保持目标来源明确，减少未可靠取得的元数据 |
| ADR-13 | 配置只热更规则/节点/观测 | 降低监听、预算与权限变化的运行时复杂性 |
| ADR-14 | 成功只表达可观察的就绪条件 | 不把本地回复当作端到端业务成功证明 |

这些是此文档草案的决定，并非记录用户已经确认的所有取舍。

### 3. 配置与验收范围

入口只需要明确的监听与访问策略、Core 路由配置和可用节点引用。具体 Wire 的配置不进入本文件。本文规定的测试是验收要求，不代表已经运行或通过；性能和资源回收结论必须有实际记录。

---

<a id="attachment-config-schema-json"></a>

## 附录 · config.schema.json

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:local-socks4-proxy:configuration:v1",
  "title": "Local SOCKS4/4a Proxy Configuration v1",
  "description": "Proposed configuration format; see 08-configuration.md for mandatory semantic validation.",
  "type": "object",
  "properties": {
    "schema_version": {
      "const": 1
    },
    "listen": {
      "type": "object",
      "properties": {
        "host": {
          "type": "string",
          "minLength": 1,
          "maxLength": 254
        },
        "port": {
          "type": "integer",
          "minimum": 1,
          "maximum": 65535
        }
      },
      "required": [
        "host",
        "port"
      ],
      "additionalProperties": false
    },
    "limits": {
      "type": "object",
      "properties": {
        "max_sessions": {
          "type": "integer",
          "minimum": 1,
          "maximum": 65535
        },
        "max_pending_handshakes": {
          "type": "integer",
          "minimum": 1,
          "maximum": 65535
        },
        "handshake_timeout_ms": {
          "type": "integer",
          "minimum": 1,
          "maximum": 2147483647
        },
        "connect_total_timeout_ms": {
          "type": "integer",
          "minimum": 1,
          "maximum": 2147483647
        },
        "dns_timeout_ms": {
          "type": "integer",
          "minimum": 1,
          "maximum": 2147483647
        },
        "dial_timeout_ms": {
          "type": "integer",
          "minimum": 1,
          "maximum": 2147483647
        },
        "wire_start_timeout_ms": {
          "type": "integer",
          "minimum": 1,
          "maximum": 2147483647
        },
        "reply_write_timeout_ms": {
          "type": "integer",
          "minimum": 1,
          "maximum": 2147483647
        },
        "relay_idle_timeout_ms": {
          "type": "integer",
          "minimum": 0,
          "maximum": 2147483647
        },
        "half_close_timeout_ms": {
          "type": "integer",
          "minimum": 0,
          "maximum": 2147483647
        },
        "shutdown_grace_ms": {
          "type": "integer",
          "minimum": 0,
          "maximum": 2147483647
        },
        "read_chunk_bytes": {
          "type": "integer",
          "minimum": 1,
          "maximum": 1048576
        },
        "early_data_limit_bytes": {
          "type": "integer",
          "minimum": 1,
          "maximum": 2147483647
        },
        "relay_high_water_bytes": {
          "type": "integer",
          "minimum": 1,
          "maximum": 2147483647
        },
        "relay_low_water_bytes": {
          "type": "integer",
          "minimum": 1,
          "maximum": 2147483647
        },
        "global_buffer_budget_bytes": {
          "type": "integer",
          "minimum": 1024,
          "maximum": 2147483647
        }
      },
      "required": [
        "max_sessions",
        "max_pending_handshakes",
        "handshake_timeout_ms",
        "connect_total_timeout_ms",
        "dns_timeout_ms",
        "dial_timeout_ms",
        "wire_start_timeout_ms",
        "reply_write_timeout_ms",
        "relay_idle_timeout_ms",
        "half_close_timeout_ms",
        "shutdown_grace_ms",
        "read_chunk_bytes",
        "early_data_limit_bytes",
        "relay_high_water_bytes",
        "relay_low_water_bytes",
        "global_buffer_budget_bytes"
      ],
      "additionalProperties": false
    },
    "dns": {
      "type": "object",
      "properties": {
        "resolver": {
          "const": "system"
        },
        "resolve_for_routing": {
          "const": false
        },
        "application_cache": {
          "const": false
        },
        "direct_address_family": {
          "const": "dual"
        },
        "max_concurrent_queries": {
          "type": "integer",
          "minimum": 1,
          "maximum": 16
        },
        "max_addresses": {
          "type": "integer",
          "minimum": 1,
          "maximum": 16
        },
        "connect_candidate_delay_ms": {
          "type": "integer",
          "minimum": 10,
          "maximum": 2000
        }
      },
      "required": [
        "resolver",
        "resolve_for_routing",
        "application_cache",
        "direct_address_family",
        "max_concurrent_queries",
        "max_addresses",
        "connect_candidate_delay_ms"
      ],
      "additionalProperties": false
    },
    "routing": {
      "type": "object",
      "properties": {
        "rules": {
          "type": "array",
          "items": {
            "oneOf": [
              {
                "type": "object",
                "properties": {
                  "id": {
                    "type": "string",
                    "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
                  },
                  "match": {
                    "oneOf": [
                      {
                        "type": "object",
                        "properties": {
                          "type": {
                            "enum": [
                              "domain_exact",
                              "domain_suffix",
                              "ip_cidr"
                            ]
                          },
                          "value": {
                            "type": "string",
                            "minLength": 1,
                            "maxLength": 254
                          }
                        },
                        "required": [
                          "type",
                          "value"
                        ],
                        "additionalProperties": false
                      },
                      {
                        "type": "object",
                        "properties": {
                          "type": {
                            "const": "port"
                          },
                          "value": {
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 65535
                          }
                        },
                        "required": [
                          "type",
                          "value"
                        ],
                        "additionalProperties": false
                      }
                    ]
                  },
                  "action": {
                    "enum": [
                      "DIRECT",
                      "REJECT"
                    ]
                  }
                },
                "required": [
                  "id",
                  "match",
                  "action"
                ],
                "additionalProperties": false
              },
              {
                "type": "object",
                "properties": {
                  "id": {
                    "type": "string",
                    "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
                  },
                  "match": {
                    "oneOf": [
                      {
                        "type": "object",
                        "properties": {
                          "type": {
                            "enum": [
                              "domain_exact",
                              "domain_suffix",
                              "ip_cidr"
                            ]
                          },
                          "value": {
                            "type": "string",
                            "minLength": 1,
                            "maxLength": 254
                          }
                        },
                        "required": [
                          "type",
                          "value"
                        ],
                        "additionalProperties": false
                      },
                      {
                        "type": "object",
                        "properties": {
                          "type": {
                            "const": "port"
                          },
                          "value": {
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 65535
                          }
                        },
                        "required": [
                          "type",
                          "value"
                        ],
                        "additionalProperties": false
                      }
                    ]
                  },
                  "action": {
                    "const": "PROXY"
                  },
                  "outbound": {
                    "type": "string",
                    "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
                  }
                },
                "required": [
                  "id",
                  "match",
                  "action",
                  "outbound"
                ],
                "additionalProperties": false
              }
            ]
          },
          "minItems": 0,
          "maxItems": 10000
        },
        "final": {
          "oneOf": [
            {
              "type": "object",
              "properties": {
                "action": {
                  "const": "DIRECT"
                }
              },
              "required": [
                "action"
              ],
              "additionalProperties": false
            },
            {
              "type": "object",
              "properties": {
                "action": {
                  "const": "REJECT"
                }
              },
              "required": [
                "action"
              ],
              "additionalProperties": false
            },
            {
              "type": "object",
              "properties": {
                "action": {
                  "const": "PROXY"
                },
                "outbound": {
                  "type": "string",
                  "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
                }
              },
              "required": [
                "action",
                "outbound"
              ],
              "additionalProperties": false
            }
          ]
        }
      },
      "required": [
        "rules",
        "final"
      ],
      "additionalProperties": false
    },
    "outbounds": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "id": {
            "type": "string",
            "minLength": 1,
            "maxLength": 64
          }
        },
        "required": [
          "id"
        ]
      },
      "minItems": 0,
      "maxItems": 256
    },
    "security": {
      "type": "object",
      "properties": {
        "allow_lan_listen": {
          "type": "boolean"
        },
        "allowed_client_cidrs": {
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1,
            "maxLength": 254
          },
          "minItems": 1,
          "maxItems": 256
        },
        "deny_target_cidrs": {
          "type": "array",
          "items": {
            "type": "string",
            "minLength": 1,
            "maxLength": 254
          },
          "minItems": 0,
          "maxItems": 256
        },
        "allow_target_endpoints": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "host": {
                "type": "string",
                "minLength": 1,
                "maxLength": 254
              },
              "port": {
                "type": "integer",
                "minimum": 1,
                "maximum": 65535
              }
            },
            "required": [
              "host",
              "port"
            ],
            "additionalProperties": false
          },
          "minItems": 0,
          "maxItems": 256
        }
      },
      "required": [
        "allow_lan_listen",
        "allowed_client_cidrs",
        "deny_target_cidrs",
        "allow_target_endpoints"
      ],
      "additionalProperties": false
    },
    "observability": {
      "type": "object",
      "properties": {
        "level": {
          "enum": [
            "error",
            "warning",
            "info",
            "debug"
          ]
        },
        "target_logging": {
          "enum": [
            "redacted",
            "full"
          ]
        },
        "metrics": {
          "type": "boolean"
        }
      },
      "required": [
        "level",
        "target_logging",
        "metrics"
      ],
      "additionalProperties": false
    }
  },
  "required": [
    "schema_version",
    "listen",
    "limits",
    "dns",
    "routing",
    "outbounds",
    "security",
    "observability"
  ],
  "additionalProperties": false
}
```


---

<a id="attachment-examples-config-direct-only-json"></a>

## 附录 · examples/config.direct-only.json

```json
{
  "schema_version": 1,
  "listen": {
    "host": "127.0.0.1",
    "port": 1080
  },
  "limits": {
    "max_sessions": 512,
    "max_pending_handshakes": 64,
    "handshake_timeout_ms": 10000,
    "connect_total_timeout_ms": 20000,
    "dns_timeout_ms": 5000,
    "dial_timeout_ms": 8000,
    "wire_start_timeout_ms": 8000,
    "reply_write_timeout_ms": 1000,
    "relay_idle_timeout_ms": 0,
    "half_close_timeout_ms": 30000,
    "shutdown_grace_ms": 30000,
    "read_chunk_bytes": 16384,
    "early_data_limit_bytes": 65536,
    "relay_high_water_bytes": 65536,
    "relay_low_water_bytes": 32768,
    "global_buffer_budget_bytes": 67108864
  },
  "dns": {
    "resolver": "system",
    "resolve_for_routing": false,
    "application_cache": false,
    "direct_address_family": "dual",
    "max_concurrent_queries": 16,
    "max_addresses": 16,
    "connect_candidate_delay_ms": 250
  },
  "routing": {
    "rules": [],
    "final": {
      "action": "DIRECT"
    }
  },
  "outbounds": [],
  "security": {
    "allow_lan_listen": false,
    "allowed_client_cidrs": [
      "127.0.0.0/8",
      "::1/128"
    ],
    "deny_target_cidrs": [
      "0.0.0.0/8",
      "127.0.0.0/8",
      "169.254.0.0/16",
      "224.0.0.0/4",
      "240.0.0.0/4",
      "::/128",
      "::1/128",
      "fe80::/10",
      "ff00::/8"
    ],
    "allow_target_endpoints": []
  },
  "observability": {
    "level": "info",
    "target_logging": "redacted",
    "metrics": true
  }
}
```


---

<a id="attachment-examples-config-wire-route-json"></a>

## 附录 · examples/config.wire-route.json

```json
{
  "schema_version": 1,
  "listen": {
    "host": "127.0.0.1",
    "port": 1080
  },
  "limits": {
    "max_sessions": 512,
    "max_pending_handshakes": 64,
    "handshake_timeout_ms": 10000,
    "connect_total_timeout_ms": 20000,
    "dns_timeout_ms": 5000,
    "dial_timeout_ms": 8000,
    "wire_start_timeout_ms": 8000,
    "reply_write_timeout_ms": 1000,
    "relay_idle_timeout_ms": 0,
    "half_close_timeout_ms": 30000,
    "shutdown_grace_ms": 30000,
    "read_chunk_bytes": 16384,
    "early_data_limit_bytes": 65536,
    "relay_high_water_bytes": 65536,
    "relay_low_water_bytes": 32768,
    "global_buffer_budget_bytes": 67108864
  },
  "dns": {
    "resolver": "system",
    "resolve_for_routing": false,
    "application_cache": false,
    "direct_address_family": "dual",
    "max_concurrent_queries": 16,
    "max_addresses": 16,
    "connect_candidate_delay_ms": 250
  },
  "routing": {
    "rules": [
      {
        "id": "blocked",
        "match": {
          "type": "domain_exact",
          "value": "blocked.example.com"
        },
        "action": "REJECT"
      },
      {
        "id": "example-direct",
        "match": {
          "type": "domain_suffix",
          "value": "example.com"
        },
        "action": "DIRECT"
      },
      {
        "id": "local-direct",
        "match": {
          "type": "domain_suffix",
          "value": "local"
        },
        "action": "DIRECT"
      },
      {
        "id": "lan-192",
        "match": {
          "type": "ip_cidr",
          "value": "192.168.0.0/16"
        },
        "action": "DIRECT"
      },
      {
        "id": "lan-10",
        "match": {
          "type": "ip_cidr",
          "value": "10.0.0.0/8"
        },
        "action": "DIRECT"
      },
      {
        "id": "lan-172",
        "match": {
          "type": "ip_cidr",
          "value": "172.16.0.0/12"
        },
        "action": "DIRECT"
      }
    ],
    "final": {
      "action": "PROXY",
      "outbound": "main"
    }
  },
  "outbounds": [
    {
      "id": "main"
    }
  ],
  "security": {
    "allow_lan_listen": false,
    "allowed_client_cidrs": [
      "127.0.0.0/8",
      "::1/128"
    ],
    "deny_target_cidrs": [
      "0.0.0.0/8",
      "127.0.0.0/8",
      "169.254.0.0/16",
      "224.0.0.0/4",
      "240.0.0.0/4",
      "::/128",
      "::1/128",
      "fe80::/10",
      "ff00::/8"
    ],
    "allow_target_endpoints": []
  },
  "observability": {
    "level": "info",
    "target_logging": "redacted",
    "metrics": true
  }
}
```


---

<a id="attachment-examples-config-test-json"></a>

## 附录 · examples/config.test.json

```json
{
  "schema_version": 1,
  "listen": {
    "host": "127.0.0.1",
    "port": 12080
  },
  "limits": {
    "max_sessions": 512,
    "max_pending_handshakes": 64,
    "handshake_timeout_ms": 10000,
    "connect_total_timeout_ms": 20000,
    "dns_timeout_ms": 5000,
    "dial_timeout_ms": 8000,
    "wire_start_timeout_ms": 8000,
    "reply_write_timeout_ms": 1000,
    "relay_idle_timeout_ms": 0,
    "half_close_timeout_ms": 30000,
    "shutdown_grace_ms": 30000,
    "read_chunk_bytes": 16384,
    "early_data_limit_bytes": 65536,
    "relay_high_water_bytes": 65536,
    "relay_low_water_bytes": 32768,
    "global_buffer_budget_bytes": 67108864
  },
  "dns": {
    "resolver": "system",
    "resolve_for_routing": false,
    "application_cache": false,
    "direct_address_family": "dual",
    "max_concurrent_queries": 16,
    "max_addresses": 16,
    "connect_candidate_delay_ms": 250
  },
  "routing": {
    "rules": [],
    "final": {
      "action": "DIRECT"
    }
  },
  "outbounds": [],
  "security": {
    "allow_lan_listen": false,
    "allowed_client_cidrs": [
      "127.0.0.0/8",
      "::1/128"
    ],
    "deny_target_cidrs": [
      "0.0.0.0/8",
      "127.0.0.0/8",
      "169.254.0.0/16",
      "224.0.0.0/4",
      "240.0.0.0/4",
      "::/128",
      "::1/128",
      "fe80::/10",
      "ff00::/8"
    ],
    "allow_target_endpoints": [
      {
        "host": "127.0.0.1",
        "port": 18080
      }
    ]
  },
  "observability": {
    "level": "info",
    "target_logging": "redacted",
    "metrics": true
  }
}
```


---

<a id="attachment-examples-parser-vectors-json"></a>

## 附录 · examples/parser-vectors.json

```json
{
  "schema_version": 1,
  "cases": [
    {
      "id": "P01-min-ipv4",
      "description": "最短 IPv4 CONNECT",
      "input_hex": "04 01 01 bb cb 00 71 0a 00",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "ipv4",
          "host": "203.0.113.10",
          "port": 443
        },
        "origin": "socks4",
        "consumed": 9,
        "remainder_hex": ""
      }
    },
    {
      "id": "P02-domain",
      "description": "域名 CONNECT",
      "input_hex": "04 01 01 bb 00 00 00 01 00 65 78 61 6d 70 6c 65 2e 63 6f 6d 00",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "domain",
          "host": "example.com",
          "port": 443
        },
        "origin": "socks4a",
        "consumed": 21,
        "remainder_hex": ""
      }
    },
    {
      "id": "P03-marker-2",
      "description": "标记不是只能为 1",
      "input_hex": "04 01 01 bb 00 00 00 02 00 65 78 61 6d 70 6c 65 2e 63 6f 6d 00",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "domain",
          "host": "example.com",
          "port": 443
        },
        "origin": "socks4a",
        "consumed": 21,
        "remainder_hex": ""
      }
    },
    {
      "id": "P03-marker-255",
      "description": "标记最大值",
      "input_hex": "04 01 01 bb 00 00 00 ff 00 65 78 61 6d 70 6c 65 2e 63 6f 6d 00",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "domain",
          "host": "example.com",
          "port": 443
        },
        "origin": "socks4a",
        "consumed": 21,
        "remainder_hex": ""
      }
    },
    {
      "id": "P04-zero-is-ip",
      "description": "0.0.0.0 是普通 IP，安全阶段另拒绝",
      "input_hex": "04 01 01 bb 00 00 00 00 00",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "ipv4",
          "host": "0.0.0.0",
          "port": 443
        },
        "origin": "socks4",
        "consumed": 9,
        "remainder_hex": ""
      }
    },
    {
      "id": "P05-user-max",
      "description": "255 字节 USERID",
      "input_hex": "04 01 01 bb cb 00 71 0a 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 00",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "ipv4",
          "host": "203.0.113.10",
          "port": 443
        },
        "origin": "socks4",
        "consumed": 264,
        "remainder_hex": ""
      }
    },
    {
      "id": "P05-user-over",
      "description": "256 字节 USERID",
      "input_hex": "04 01 01 bb cb 00 71 0a 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 00",
      "expected": {
        "status": "invalid",
        "error": "USERID_TOO_LONG",
        "recognized_socks4": true
      }
    },
    {
      "id": "P06-domain-max",
      "description": "253 字节合法主机名",
      "input_hex": "04 01 01 bb 00 00 00 01 00 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 2e 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 2e 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 2e 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 00",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "domain",
          "host": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc.ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
          "port": 443
        },
        "origin": "socks4a",
        "consumed": 263,
        "remainder_hex": ""
      }
    },
    {
      "id": "P06-domain-max-dot",
      "description": "254 字节含尾随点",
      "input_hex": "04 01 01 bb 00 00 00 01 00 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 2e 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 2e 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 2e 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 2e 00",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "domain",
          "host": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc.ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
          "port": 443
        },
        "origin": "socks4a",
        "consumed": 264,
        "remainder_hex": ""
      }
    },
    {
      "id": "P06-header-max",
      "description": "最大合法头部为 519 字节",
      "input_hex": "04 01 01 bb 00 00 00 01 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 75 00 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 2e 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 62 2e 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 63 2e 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 64 2e 00",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "domain",
          "host": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc.ddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
          "port": 443
        },
        "origin": "socks4a",
        "consumed": 519,
        "remainder_hex": ""
      }
    },
    {
      "id": "P06-label-over",
      "description": "单个 label 64 字节",
      "input_hex": "04 01 01 bb 00 00 00 01 00 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 2e 74 65 73 74 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P06-domain-over",
      "description": "原始域名字段超过 254",
      "input_hex": "04 01 01 bb 00 00 00 01 00 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 61 00",
      "expected": {
        "status": "invalid",
        "error": "DOMAIN_TOO_LONG",
        "recognized_socks4": true
      }
    },
    {
      "id": "P07-non-utf-user",
      "description": "USERID 非 UTF-8 仍可解析",
      "input_hex": "04 01 01 bb cb 00 71 0a ff 00",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "ipv4",
          "host": "203.0.113.10",
          "port": 443
        },
        "origin": "socks4",
        "consumed": 10,
        "remainder_hex": ""
      }
    },
    {
      "id": "P08-normalize",
      "description": "大小写与尾随点",
      "input_hex": "04 01 01 bb 00 00 00 01 00 57 57 57 2e 45 78 61 6d 70 6c 65 2e 43 4f 4d 2e 00",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "domain",
          "host": "www.example.com",
          "port": 443
        },
        "origin": "socks4a",
        "consumed": 26,
        "remainder_hex": ""
      }
    },
    {
      "id": "P09-numeric-domain",
      "description": "4a 中的规范 IPv4 归一化",
      "input_hex": "04 01 01 bb 00 00 00 01 00 32 30 33 2e 30 2e 31 31 33 2e 31 30 00",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "ipv4",
          "host": "203.0.113.10",
          "port": 443
        },
        "origin": "socks4a",
        "consumed": 22,
        "remainder_hex": ""
      }
    },
    {
      "id": "P10-version",
      "description": "错误版本",
      "input_hex": "05 01 00",
      "expected": {
        "status": "invalid",
        "error": "UNSUPPORTED_VERSION",
        "recognized_socks4": false
      }
    },
    {
      "id": "P10-bind",
      "description": "不支持 BIND",
      "input_hex": "04 02",
      "expected": {
        "status": "invalid",
        "error": "UNSUPPORTED_COMMAND",
        "recognized_socks4": true
      }
    },
    {
      "id": "P10-udp-command",
      "description": "不支持命令 3",
      "input_hex": "04 03",
      "expected": {
        "status": "invalid",
        "error": "UNSUPPORTED_COMMAND",
        "recognized_socks4": true
      }
    },
    {
      "id": "P10-zero-port",
      "description": "目标端口 0",
      "input_hex": "04 01 00 00 cb 00 71 0a 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_PORT",
        "recognized_socks4": true
      }
    },
    {
      "id": "P11-empty",
      "description": "empty",
      "input_hex": "04 01 01 bb 00 00 00 01 00 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P11-utf8",
      "description": "utf8",
      "input_hex": "04 01 01 bb 00 00 00 01 00 e4 b8 ad e6 96 87 2e 65 78 61 6d 70 6c 65 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P11-url",
      "description": "url",
      "input_hex": "04 01 01 bb 00 00 00 01 00 68 74 74 70 73 3a 2f 2f 65 78 61 6d 70 6c 65 2e 63 6f 6d 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P11-port",
      "description": "port",
      "input_hex": "04 01 01 bb 00 00 00 01 00 65 78 61 6d 70 6c 65 2e 63 6f 6d 3a 34 34 33 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P11-underscore",
      "description": "underscore",
      "input_hex": "04 01 01 bb 00 00 00 01 00 62 61 64 5f 6e 61 6d 65 2e 65 78 61 6d 70 6c 65 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P11-ipv6",
      "description": "ipv6",
      "input_hex": "04 01 01 bb 00 00 00 01 00 3a 3a 31 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P11-empty-label",
      "description": "empty-label",
      "input_hex": "04 01 01 bb 00 00 00 01 00 61 2e 2e 65 78 61 6d 70 6c 65 2e 63 6f 6d 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P11-double-dot",
      "description": "double-dot",
      "input_hex": "04 01 01 bb 00 00 00 01 00 65 78 61 6d 70 6c 65 2e 63 6f 6d 2e 2e 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P11-root",
      "description": "root",
      "input_hex": "04 01 01 bb 00 00 00 01 00 2e 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P11-single-label",
      "description": "single-label",
      "input_hex": "04 01 01 bb 00 00 00 01 00 6c 6f 63 61 6c 68 6f 73 74 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P11-bad-edge",
      "description": "bad-edge",
      "input_hex": "04 01 01 bb 00 00 00 01 00 2d 62 61 64 2e 65 78 61 6d 70 6c 65 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P12-empty",
      "description": "空输入等待",
      "input_hex": "",
      "expected": {
        "status": "need_more"
      }
    },
    {
      "id": "P12-header",
      "description": "固定头未到齐",
      "input_hex": "04 01 01 bb 00",
      "expected": {
        "status": "need_more"
      }
    },
    {
      "id": "P12-user-nul",
      "description": "缺少 USERID NUL",
      "input_hex": "04 01 01 bb cb 00 71 0a",
      "expected": {
        "status": "need_more"
      }
    },
    {
      "id": "P12-domain-nul",
      "description": "域名缺少 NUL",
      "input_hex": "04 01 01 bb 00 00 00 01 00 65 78 61 6d 70 6c 65 2e 63 6f 6d",
      "expected": {
        "status": "need_more"
      }
    },
    {
      "id": "P13-payload",
      "description": "尾部二进制原样保留",
      "input_hex": "04 01 01 bb 00 00 00 01 00 65 78 61 6d 70 6c 65 2e 63 6f 6d 00 16 03 01 00 ff",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "domain",
          "host": "example.com",
          "port": 443
        },
        "origin": "socks4a",
        "consumed": 21,
        "remainder_hex": "16 03 01 00 ff"
      }
    },
    {
      "id": "P14-second-header",
      "description": "第二个头是业务数据",
      "input_hex": "04 01 01 bb cb 00 71 0a 00 04 01 01 bb 00 00 00 01 00 65 78 61 6d 70 6c 65 2e 63 6f 6d 00",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "ipv4",
          "host": "203.0.113.10",
          "port": 443
        },
        "origin": "socks4",
        "consumed": 9,
        "remainder_hex": "04 01 01 bb 00 00 00 01 00 65 78 61 6d 70 6c 65 2e 63 6f 6d 00"
      }
    },
    {
      "id": "P15-leading-zero",
      "description": "leading-zero",
      "input_hex": "04 01 01 bb 00 00 00 01 00 31 32 37 2e 30 30 30 2e 30 2e 31 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P15-short",
      "description": "short",
      "input_hex": "04 01 01 bb 00 00 00 01 00 31 32 37 2e 31 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P15-integer",
      "description": "integer",
      "input_hex": "04 01 01 bb 00 00 00 01 00 32 31 33 30 37 30 36 34 33 33 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P15-hex",
      "description": "hex",
      "input_hex": "04 01 01 bb 00 00 00 01 00 30 78 37 66 2e 30 2e 30 2e 31 00",
      "expected": {
        "status": "invalid",
        "error": "INVALID_DOMAIN",
        "recognized_socks4": true
      }
    },
    {
      "id": "P16-port-max",
      "description": "端口 65535",
      "input_hex": "04 01 ff ff cb 00 71 0a 00",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "ipv4",
          "host": "203.0.113.10",
          "port": 65535
        },
        "origin": "socks4",
        "consumed": 9,
        "remainder_hex": ""
      }
    },
    {
      "id": "P16-user-domain",
      "description": "USERID 与域名独立",
      "input_hex": "04 01 01 bb 00 00 00 01 6e 6f 74 2d 74 68 65 2d 68 6f 73 74 2e 65 78 61 6d 70 6c 65 00 65 78 61 6d 70 6c 65 2e 6e 65 74 00",
      "expected": {
        "status": "complete",
        "target": {
          "kind": "domain",
          "host": "example.net",
          "port": 443
        },
        "origin": "socks4a",
        "consumed": 41,
        "remainder_hex": ""
      }
    }
  ]
}
```


---

<a id="attachment-tools-probe-socks4-py"></a>

## 附录 · tools/probe_socks4.py

```python
#!/usr/bin/env python3
"""Probe a running SOCKS4/4a service. Does not implement/start a proxy.

Python 3.10+, standard library only. SOCKS4 mode requires a numeric IPv4
host, keeping client-side DNS out of a deterministic test.
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import socket
import struct
import sys
import time


def valid_port(value: str) -> int:
    port = int(value)
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError('port must be 1..65535')
    return port


def receive_exact(stream: socket.socket, size: int, deadline: float) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f'receive deadline exceeded ({len(chunks)}/{size} bytes)')
        stream.settimeout(remaining)
        data = stream.recv(size - len(chunks))
        if not data:
            raise EOFError(f'EOF after {len(chunks)} of {size} expected bytes')
        chunks.extend(data)
    return bytes(chunks)


def send_all(stream: socket.socket, data: bytes, deadline: float) -> None:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError('send deadline exceeded')
    stream.settimeout(remaining)
    stream.sendall(data)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--proxy-host', default='127.0.0.1')
    parser.add_argument('--proxy-port', type=valid_port, default=1080)
    parser.add_argument('--mode', choices=['socks4','socks4a'], default='socks4a')
    parser.add_argument('--host', required=True, help='Target host, not the proxy host')
    parser.add_argument('--port', type=valid_port, required=True)
    parser.add_argument('--userid', default='')
    parser.add_argument('--timeout', type=float, default=10.0, help='Total probe I/O budget in seconds')
    parser.add_argument('--fragment-size', type=int, default=0, help='0 = one write, otherwise write chunks of N bytes')
    parser.add_argument('--payload-hex', default='')
    parser.add_argument('--early-data', action='store_true', help='Send payload directly after request before success')
    parser.add_argument('--expect-echo', action='store_true', help='Assert the target echoes exactly the payload')
    parser.add_argument('--half-close', action='store_true', help='Finish client writes and require remote EOF in echo mode')
    args = parser.parse_args()
    try:
        if args.timeout <= 0 or args.fragment_size < 0:
            raise ValueError('timeout must be positive; fragment-size must not be negative')
        user = args.userid.encode('utf-8')
        if len(user) > 255 or b'\0' in user:
            raise ValueError('userid must be at most 255 UTF-8 bytes, without NUL')
        payload = bytes.fromhex(args.payload_hex)
        if len(payload) > 65536:
            raise ValueError('probe payload is limited to 64 KiB')
        if args.expect_echo and not payload:
            raise ValueError('--expect-echo requires a non-empty --payload-hex')
        header = b'\x04\x01' + struct.pack('!H', args.port)
        if args.mode == 'socks4':
            header += ipaddress.IPv4Address(args.host).packed + user + b'\0'
        else:
            domain = args.host.encode('ascii')
            if not 1 <= len(domain) <= 254 or b'\0' in domain:
                raise ValueError('SOCKS4a host must be 1..254 ASCII bytes without NUL')
            # Other hostname syntax is intentionally left for the server to validate.
            header += b'\0\0\0\x01' + user + b'\0' + domain + b'\0'
        request = header + (payload if args.early_data else b'')
        started = time.monotonic()
        deadline = started + args.timeout
        with socket.create_connection((args.proxy_host, args.proxy_port), timeout=args.timeout) as stream:
            stride = args.fragment_size or len(request)
            for offset in range(0, len(request), stride):
                send_all(stream, request[offset:offset+stride], deadline)
            reply = receive_exact(stream, 8, deadline)
            if reply[0] != 0:
                raise ValueError(f'bad SOCKS4 reply version {reply[0]:02x}')
            status = {'0x5a':'granted','0x5b':'rejected_or_failed','0x5c':'ident_unreachable','0x5d':'ident_mismatch'}.get(f'0x{reply[1]:02x}', 'unknown')
            result = {'proxy':f'{args.proxy_host}:{args.proxy_port}', 'mode':args.mode,
                      'target':f'{args.host}:{args.port}', 'reply_hex':reply.hex(' '), 'status':status}
            if reply[1] != 0x5A:
                print(json.dumps(result, ensure_ascii=False, indent=2))
                return 2
            if payload and not args.early_data:
                send_all(stream, payload, deadline)
            if args.half_close:
                stream.shutdown(socket.SHUT_WR)
            if args.expect_echo:
                echoed = receive_exact(stream, len(payload), deadline)
                if echoed != payload:
                    raise ValueError('echo mismatch')
                result['echo_bytes_verified'] = len(payload)
                if args.half_close:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError('EOF deadline exceeded')
                    stream.settimeout(remaining)
                    if stream.recv(1) != b'':
                        raise ValueError('unexpected bytes after expected echo')
                    result['half_close_verified'] = True
            result['elapsed_ms'] = round((time.monotonic()-started)*1000, 3)
            print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (OSError, ValueError, EOFError, UnicodeError) as exc:
        print(json.dumps({'status':'probe_error','error':str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 1

if __name__ == '__main__':
    raise SystemExit(main())
```


---

<a id="attachment-tools-validate-bundle-py"></a>

## 附录 · tools/validate_bundle.py

```python
#!/usr/bin/env python3
"""Validate this SPEC bundle, not a production proxy implementation.

Python 3.10+. Standard library only, except optional jsonschema validation.
The bounded one-shot decoder below is a test oracle; its reparse-based feed
wrapper deliberately does not claim production incremental performance.
"""
from __future__ import annotations

import argparse
import ipaddress
import json
from pathlib import Path
import random
import re
import sys
from typing import Any
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]

class InvalidHost(ValueError):
    pass


def normalized_host(raw: bytes, *, allow_single: bool = False) -> tuple[str, str]:
    try:
        host = raw.decode('ascii').lower()
    except UnicodeDecodeError as exc:
        raise InvalidHost('non-ASCII hostname') from exc
    if host.endswith('.'):
        host = host[:-1]
    if not host or len(host) > 253:
        raise InvalidHost('invalid hostname length')
    parts = host.split('.')
    numeric_like = all(re.fullmatch(r'(?:[0-9]+|0x[0-9a-f]+)', part) for part in parts)
    if numeric_like:
        try:
            ip = ipaddress.IPv4Address(host)
        except ipaddress.AddressValueError as exc:
            raise InvalidHost('non-canonical numeric address') from exc
        if str(ip) != host:
            raise InvalidHost('non-canonical IPv4')
        return 'ipv4', str(ip)
    if not allow_single and len(parts) < 2:
        raise InvalidHost('single-label target is not supported')
    for label in parts:
        if not 1 <= len(label) <= 63 or not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?', label):
            raise InvalidHost('invalid hostname label')
    return 'domain', host


def parse_request(data: bytes) -> dict[str, Any]:
    """Bounded, pure, one-shot SOCKS4/4a oracle; does not apply target ACLs."""
    def invalid(code: str, recognized: bool = True) -> dict[str, Any]:
        return {'status': 'invalid', 'error': code, 'recognized_socks4': recognized}

    if not data:
        return {'status': 'need_more'}
    if data[0] != 4:
        return invalid('UNSUPPORTED_VERSION', False)
    if len(data) < 2:
        return {'status': 'need_more'}
    if data[1] != 1:
        return invalid('UNSUPPORTED_COMMAND')
    if len(data) < 8:
        return {'status': 'need_more'}
    port = int.from_bytes(data[2:4], 'big')
    if port == 0:
        return invalid('INVALID_PORT')

    def cstring(start: int, limit: int) -> tuple[bytes | None, int, bool]:
        end = data.find(b'\0', start, min(len(data), start + limit + 1))
        if end >= 0:
            return data[start:end], end + 1, False
        return None, start, len(data) - start > limit

    _, pos, too_long = cstring(8, 255)
    if too_long:
        return invalid('USERID_TOO_LONG')
    if pos == 8:
        return {'status': 'need_more'}
    is4a = data[4:7] == b'\0\0\0' and data[7] != 0
    if is4a:
        raw, end, too_long = cstring(pos, 254)
        if too_long:
            return invalid('DOMAIN_TOO_LONG')
        if raw is None:
            return {'status': 'need_more'}
        try:
            kind, host = normalized_host(raw)
        except InvalidHost:
            return invalid('INVALID_DOMAIN')
        pos = end
    else:
        kind, host = 'ipv4', str(ipaddress.IPv4Address(data[4:8]))
    if pos > 1024:
        return invalid('HEADER_TOO_LARGE')
    return {
        'status': 'complete',
        'target': {'kind': kind, 'host': host, 'port': port},
        'origin': 'socks4a' if is4a else 'socks4',
        'consumed': pos,
        'remainder_hex': data[pos:].hex(' '),
    }


def feed_oracle(parts: list[bytes]) -> dict[str, Any]:
    """Accumulate only for test purposes; preserve tail even after completion."""
    data = b''
    terminal: dict[str, Any] | None = None
    for part in parts:
        data += part
        if terminal is None:
            result = parse_request(data)
            if result['status'] != 'need_more':
                terminal = result
    if terminal is None:
        return {'status': 'need_more'}
    if terminal['status'] == 'complete':
        terminal = {**terminal, 'remainder_hex': data[terminal['consumed']:].hex(' ')}
    return terminal


def no_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate JSON key: {key}')
        result[key] = value
    return result


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=no_duplicate_keys)


def numeric_ip(text: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address:
    if '%' in text or '[' in text or ']' in text:
        raise ValueError('scoped/bracketed address not supported')
    return ipaddress.ip_address(text)


def normalized_ip(text: str) -> ipaddress.IPv4Address | ipaddress.IPv6Address:
    address = numeric_ip(text)
    if isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped:
        return address.ipv4_mapped
    return address


def validate_semantics(config: dict[str, Any]) -> None:
    limits = config['limits']
    assert limits['max_pending_handshakes'] <= limits['max_sessions'], 'pending > sessions'
    assert 0 < limits['relay_low_water_bytes'] < limits['relay_high_water_bytes'], 'invalid watermarks'
    assert limits['read_chunk_bytes'] <= limits['relay_high_water_bytes'], 'read chunk exceeds high watermark'
    assert limits['read_chunk_bytes'] <= limits['early_data_limit_bytes'], 'read chunk exceeds early limit'
    assert limits['global_buffer_budget_bytes'] >= limits['max_pending_handshakes'] * 1024 + 2 * limits['read_chunk_bytes'], 'global budget too small'
    security = config['security']
    listen = normalized_ip(config['listen']['host'])
    assert listen.is_loopback or security['allow_lan_listen'], 'non-loopback listen not permitted'
    assert security['allowed_client_cidrs'], 'empty source ACL'
    for key in ('allowed_client_cidrs', 'deny_target_cidrs'):
        for cidr in security[key]:
            ipaddress.ip_network(cidr, strict=True)
    for endpoint in security['allow_target_endpoints']:
        target = normalized_ip(endpoint['host'])
        assert not (target == listen and endpoint['port'] == config['listen']['port']), 'self-listener exception forbidden'
    ids: set[str] = set()
    for outbound in config['outbounds']:
        assert outbound['id'] not in ids, 'duplicate outbound id'
        ids.add(outbound['id'])
        # Node construction and Wire configuration are validated by their owning layer.

    rule_ids: set[str] = set()
    decisions = [config['routing']['final']]
    for rule in config['routing']['rules']:
        assert rule['id'] not in rule_ids, 'duplicate rule id'
        rule_ids.add(rule['id'])
        matcher = rule['match']
        if matcher['type'] in ('domain_exact', 'domain_suffix'):
            kind, _ = normalized_host(matcher['value'].encode('ascii'), allow_single=matcher['type'] == 'domain_suffix')
            assert kind == 'domain', 'domain rule contains numeric address'
        elif matcher['type'] == 'ip_cidr':
            network = ipaddress.ip_network(matcher['value'], strict=True)
            assert network.version == 4, 'v1 routing CIDR must be IPv4; security CIDRs can be IPv6'
        decisions.append(rule)
    for decision in decisions:
        if decision['action'] == 'PROXY':
            assert decision['outbound'] in ids, 'unknown outbound reference'


def validate_links() -> int:
    count = 0
    for path in ROOT.glob('*.md'):
        text = path.read_text(encoding='utf-8')
        assert len(re.findall(r'^```', text, re.M)) % 2 == 0, f'unbalanced fences: {path.name}'
        for match in re.finditer(r'\[[^\]\n]+\]\(([^)\s]+)\)', text):
            link = match.group(1)
            if '://' in link or link.startswith('mailto:'):
                continue
            filename, _, fragment = link.partition('#')
            target = (path.parent / unquote(filename)).resolve() if filename else path
            assert target.is_relative_to(ROOT.resolve()), f'link escapes bundle: {link}'
            assert target.is_file(), f'broken link: {path.name}: {link}'
            if fragment:
                body = target.read_text(encoding='utf-8')
                assert f'id="{fragment}"' in body, f'missing explicit anchor: {link}'
            count += 1
    return count


def main() -> int:
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--require-schema', action='store_true', help='Fail if jsonschema is unavailable')
    args = cli.parse_args()
    try:
        json_files = list(ROOT.rglob('*.json'))
        for path in json_files:
            load_json(path)
        try:
            from jsonschema import Draft202012Validator
        except ImportError:
            if args.require_schema:
                raise RuntimeError('jsonschema is required; install it in your Python environment')
            schema_status = 'skipped: optional jsonschema is not installed'
            schema_validator = None
        else:
            schema = load_json(ROOT / 'config.schema.json')
            Draft202012Validator.check_schema(schema)
            schema_validator = Draft202012Validator(schema)
            schema_status = 'passed'
        configs = list((ROOT / 'examples').glob('config.*.json'))
        for path in configs:
            config = load_json(path)
            if schema_validator:
                schema_validator.validate(config)
            validate_semantics(config)
        vectors = load_json(ROOT / 'examples/parser-vectors.json')['cases']
        partitions = 0
        rng = random.Random(20260921)
        for vector in vectors:
            data = bytes.fromhex(vector['input_hex'])
            expected = vector['expected']
            actual = parse_request(data)
            assert actual == expected, f"vector {vector['id']}: {actual!r} != {expected!r}"
            for split in range(len(data) + 1):
                assert feed_oracle([data[:split], data[split:]]) == expected, f"split {vector['id']} @ {split}"
                partitions += 1
            assert feed_oracle([bytes([byte]) for byte in data]) == expected, f"bytewise {vector['id']}"
            partitions += 1
            for _ in range(8):
                parts, pos = [], 0
                while pos < len(data):
                    end = min(len(data), pos + rng.randint(1, 17))
                    parts.append(data[pos:end]); pos = end
                assert feed_oracle(parts) == expected, f"random split {vector['id']}"
                partitions += 1
        for marker in range(1, 256):
            packet = bytes.fromhex('04 01 01 bb 00 00 00') + bytes([marker]) + b'\0example.com\0'
            result = parse_request(packet)
            assert result['status'] == 'complete' and result['origin'] == 'socks4a'
        links = validate_links()
        print(json.dumps({
            'status':'passed', 'scope':'SPEC bundle consistency, NOT a proxy implementation conformance test',
            'markdown_files':len(list(ROOT.glob('*.md'))), 'json_files':len(json_files),
            'configuration_examples':len(configs), 'schema_validation':schema_status,
            'parser_vectors':len(vectors), 'fragmentation_checks':partitions,
            'socks4a_marker_checks':255, 'relative_links':links,
            'not_tested':['real proxy service', 'real resolver privacy', 'Wire integration', 'performance']
        }, ensure_ascii=False, indent=2))
        return 0
    except Exception as exc:
        print(f'VALIDATION FAILED: {exc}', file=sys.stderr)
        return 1

if __name__ == '__main__':
    raise SystemExit(main())
```
