---
desc: "SOCKS4 / SOCKS4a CONNECT 的报文、严格请求顺序、Core/Wire 协作和生命周期验收。"
version: "0.3.0"
updated_at: "2026-10-09"
status: "草案"
references_checked_at: "2026-09-21"
---

# SOCKS4 / SOCKS4a 代理规范

本规范定义 Magent 可复用代理库的 SOCKS4/4a CONNECT 入口，遵循
[模型规范](MODELS_SPEC.md)、[Wire v0.3.1](WIRES_SPEC.md) 和
[架构的生命周期](ARCHITECTURE.md#ownership-and-lifecycle)。这些是目标验收契约，不表示源码已全部实现。

<a id="doc-00-scope-and-requirements"></a>
## 00 · 范围

支持 SOCKS4 IPv4 CONNECT 和 SOCKS4a 名称 CONNECT，以及成功后的透明双向 TCP 字节流。
不支持 BIND、IDENT、客户端凭据认证、UDP、第二次 CONNECT 或应用层协议解析。
USERID 只用于确定报文边界，不成为身份、路由键或节点凭据。

应用提供完整 `MagentConfig` 并调用 `start`、`restart`、`close`；权限、系统代理和监听地址暴露策略
由应用负责。本规范不定义另一套 JSON 配置、控制 API、来源白名单、热更新或优雅停机机制。
本入口采用严格请求/回复顺序：本地成功回复完成前出现请求头以外的客户端字节即失败。

<a id="doc-01-architecture-and-model"></a>
## 01 · 所有权与边界

| 所有者 | 责任 |
| --- | --- |
| Magent | EventLoopGroup、listener、accepted Channel 与运行周期关闭通知 |
| MagentTCPConnection | accepted Channel 协议探测、首请求增量收齐、向唯一 Connection 分派、最终关闭 |
| Socks4Connection | 请求解析、本地回复、下游 Channel、独立 TCP Wire、背压与方向 EOF |
| Core | 消费已验证目标、规则匹配、节点 UUID 查找、Wire 选择和下游创建 |
| Wire | 实际节点端点、毫秒超时、一次启动及流编解码；不拥有 Channel 或本地回复 |

每条会话只有一个逻辑 `NetworkAddress`。业务目标、节点端点与实际网络端点分别保存，不能互相覆盖。
SOCKS4 的四字节 IPv4 由 NIO 形成规范数值文本，再调用模型构造入口；SOCKS4a 名称也通过该入口验证。
协议层负责字段边界与端口非零，模型负责地址身份。Core 与 Wire 消费同一逻辑目标。

所有 TCP 工作由 accepted Channel 所属 EventLoop 串行执行，并使用 Magent 拥有的 group。
本组件不创建线程、额外线程池、`Task.detached` 或无人管理的 Task，不在 Channel handler 中等待 future。

<a id="doc-02-inbound-wire-protocol"></a>
## 02 · 请求与回复报文

端口使用网络字节序，所有长度为字节数。

```text
SOCKS4:
  VN[1] CD[1] DSTPORT[2] DSTIP[4] USERID[可变] 00

SOCKS4a:
  04    01    DSTPORT[2] 00 00 00 xx USERID[可变] 00 DOMAIN[可变] 00
                                 xx != 0
```

| 字段 | 必须满足的条件 |
| --- | --- |
| VN | `0x04` |
| CD | CONNECT `0x01`；BIND `0x02` 和其他命令失败 |
| DSTPORT | `1...65535`，拒绝 0 |
| DSTIP | 普通请求为四个 IPv4 数值字节；`00 00 00 xx` 且 `xx != 00` 表示 SOCKS4a |
| USERID | 必须有 NUL 终止；允许空和非 UTF-8 字节，不认证、不转发 |
| DOMAIN | 仅 SOCKS4a 存在，位于 USERID 终止符之后；非空、独立 NUL 终止，不能用 USERID 替代 |

全部 255 种 SOCKS4a 标记都必须识别，标记本身不作为目标。`00 00 00 00` 是普通 IPv4 字段。
最短普通请求为 9 字节。SOCKS4a 请求结束于 DOMAIN 的终止符。

请求缓冲上限为 **64 KiB**，与现有入口的整体 guard 一致；超过即失败，不新增 USERID 独立长度配置。
DOMAIN 为 `1...254` 字节，规范名称的标签与总长度按模型校验。入口不接受原始 Unicode、URL、
`host:port` 或 IPv6 文本；需要 IDNA 转换的调用方先提供可被模型接受的 ASCII 名称。

回复固定为八字节：

```text
成功：00 5A 00 00 00 00 00 00
失败：00 5B 00 00 00 00 00 00
```

响应版本为 `00`；末六字节固定为零。本入口不发送 IDENT 专用的 `0x5C` / `0x5D`。
已确认版本为 4、写端可用且尚未开始任何回复时，协议、路由、建连或 Wire 失败尽力写一次 `0x5B`。
未知版本不写 SOCKS4 回复。一旦任意回复已开始，即使仅写出一部分也不得改发或追加另一回复。

<a id="doc-03-incremental-parser"></a>
## 03 · 增量解析、目标身份与严格顺序

请求可以任意分片，由 MagentTCPConnection 收齐首请求后交给 Socks4Connection 初始化校验；
构造只保存解析结果，安装后才启动本地回复和出站。二级对象不再积累请求分片。
已确定非法、超限或 EOF 截断时提前交接失败，仍由二级对象尽力回复 0x5B，不创建下游。
缺少固定字段或终止 NUL 时，只要尚未确定非法或超过上限，就等待更多输入。
不得把一次 read 的结束当作请求结束；USERID 扫描必须保存进度，不因逐字节输入而重扫已检查的 USERID。
SOCKS4a 的 DOMAIN 可以从其起点检查至多 255 字节（含终止 NUL）的有界窗口，不能回扫整个请求前缀。
版本、命令、端口、字段格式已确定非法时立即失败，不等待对端继续补齐。

SOCKS4a 名称严格交给 [NetworkAddress](MODELS_SPEC.md#networkaddress) 的构造和规范化规则：

- ASCII 字母转小写；每标签 `1...63` 字节，去掉一个合法根点后的名称为 `1...253` 字节。
- 合法显式根点保留在目标中；只为路由建立去掉一个根点的匹配视图，不修改目标。
- 普通合法单标签（例如 `localhost`）遵循模型接受，不另加入口禁令。
- 规范四段十进制 IPv4 文本转为数值目标；数值简写、前导零、十六进制别名、缺少分段及末尾点失败。
- 不通过修剪空白、删除根点或失败后当作域名重试来修补数值地址。

| SOCKS4a DOMAIN | 目标或结果 |
| --- | --- |
| `WWW.Example.COM.` | `domain("www.example.com.", 端口)`，根点保留 |
| `www.example.com` | 不带根点的独立目标；与上一项可使用同一路由匹配视图 |
| `localhost` | 合法单标签域名 |
| `203.0.113.10` | 数值 IPv4，不做目标 DNS |
| `203.0.113.10.`、`127.1`、`127.000.0.1`、`0x7f.0.0.1` | 拒绝 |
| 空名称、`.`、`example.com..`、`a..example.com`、原始 UTF-8、IPv6 文本 | 拒绝 |

**请求完成与本地成功回复完成之间，不接受客户端业务字节。** 同次读取中请求终止符后的任何余量，
或者建连、Wire 启动、本地回复写入期间后续读取到的字节，都按协议错误处理，不缓冲为待转发业务。
同次读取有额外字节时，必须先拒绝，不能先路由或创建下游。已经开始成功回复时发生该错误，只能结束连接。

只有成功回复完整写成后，后续字节才属于透明隧道；即使看起来像第二个 SOCKS 请求，也不再次解析或路由。
完整且**没有额外字节**的请求后收到 FIN，只记录客户端输入结束；不得因为还在建连/回复阶段就报请求截断。
请求头未完整时的 FIN 才是截断错误。

<a id="doc-04-routing-engine"></a>
## 04 · Core 路由

每条 TCP 会话对已验证目标调用一次 Core 路由。动作仅为模型的 `.direct` 与 `.proxy(UUID)`：
前者直接建立目标连接，后者选择该 UUID 的独立 TCP Wire。无规则命中才使用 `defaultDecision`；
节点不存在或选中路径失败不能被当作未命中，也不能回退 DIRECT。

规则集合完全遵循 [ProxyRule](MODELS_SPEC.md#proxyrule)：同一规范化 Match 的最后配置覆盖先前配置；
在命中项中按 `order` 较小、具体性更高、仍相同则保留输入位置更早的顺序选择。
同 `order` 下精确域名优先于后缀、后缀优先于关键字；同类后缀按标签数、关键字按字节长度、CIDR 按前缀长度比较。
更小 `order` 的宽规则可以胜过更大 `order` 的精确规则，不能采用配置首命中替代该比较。

规则不匹配端口、transport、客户端 USERID 或业务载荷。域名目标只参与域名规则，数值 IP 只参与
同族 CIDR；不为路由先做 DNS、反向解析或 SNI/HTTP 嗅探。DIRECT 域名解析后的地址也不重新匹配路由。
Core 的匹配视图和缓存可去掉域名根点，原 `NetworkAddress` 必须保留供解析与 Wire 使用。
缓存属于本运行周期 Core，只存 Decision；当前匹配维度不要求把端口加入缓存键。

安全边界产生的拒绝是独立失败，不是新增 `Decision.reject`。本规范不新增安全配置或假节点来表达拒绝。

<a id="doc-05-dns-and-addresses"></a>
## 05 · 地址解析与出站

| 目标与决策 | 连接责任 |
| --- | --- |
| 数值 IPv4 + DIRECT | 使用该数值地址与端口，不能交给名称解析器 |
| 域名 + DIRECT | 由 Core 的 TCP 创建路径解析并连接该逻辑目标；保留名称根点 |
| 任意目标 + PROXY | 连接 Wire 提供的实际节点端点；把原逻辑目标交给 `start`，入口不解析 PROXY 目标 |

节点自身的名称解析和配置装配与业务目标 DNS 分开，Wire getter 必须已经能返回稳定的实际端点。
入口不为日志、预热、测速或路由旁路解析 PROXY 目标。Wire 无法表达某个合法目标时明确失败，不改写目标。

DIRECT 使用 Core 的 `defaultTimeout`；PROXY 节点拨号使用 `Wire.getTimeout()`，单位均为正整数毫秒。
超时、DNS 或 Channel 创建失败走同一个错误边界，不引入入口专用 Resolver、候选竞速或重试服务。
已有工厂内部如何解析或选择可用地址由其 owner 负责，不能在 Connection 重复查询或改变已选路由。

<a id="doc-06-outbound-connectors"></a>
## 06 · Wire 启动与成功回复屏障

Wire 精确接口、类型与行为以 [Wire v0.3.1](WIRES_SPEC.md#抽象接口草图) 为准：

1. Core 为 PROXY 路径选择一次独立 TCP Wire；实际拨号端点来自同一个实例。
2. 节点 Channel 建立后，以原逻辑目标调用一次 `start(handshake:)`。返回 `nil` 表示无需启动写入；
   非空结果直接按序写节点，不能再次编码。
3. `start` 成功且可选启动字节写入成功，才视为下游就绪。DIRECT 则以目标 Channel 建立为就绪。
4. 下游就绪后写本地八字节成功回复；完整写成后才能业务编码、业务交付及传播正常 EOF。

`start` 不等待远端确认。无启动字节时不等节点首包，也不能等客户端业务来触发成功；本地成功不保证目标应用可达。
Wire 初始化前不解码原始输入；初始化后可以解码早到节点数据，但已解码业务必须有界保留或暂停读取，
不能越过启动写和本地成功回复屏障。这一反向余量与被严格拒绝的客户端提前业务不同。

隧道建立后，客户端数据用 `encodeOutbound(data, address: nil)` 编码；下游数据用 `decodeInbound`
解码后按顺序交付。空 `InboundData.data` 不是 EOF。地址保持启动目标，控制字节不能泄露给客户端。
DIRECT 不创建占位 Wire。每个有状态 TCP Wire 都只由本连接的 EventLoop 串行调用。

<a id="doc-07-session-and-relay"></a>
## 07 · 背压、EOF 与清理

两个方向分别执行有界读取、按序写入、写成后续读；一方向慢写不能暂停另一方向的可用传输。
已解码的节点早到业务必须先于后到业务排空，不能丢失或重排。禁止每个 read 创建无人管理的写任务。

Connection 在读取与调用 Wire 前，按 [Wire 容量契约](WIRES_SPEC.md#缓冲和进度) 为仍持有的输入、
副本、最坏返回结果与在途写预留空间；输出预留不能被后续读取占用。只限定读块大小不足以覆盖编码扩张或
历史分片完成时的大块解码结果。容量不兼容应在装配时拒绝，不新增 Wire getter 或配置开关。
Wire 内部协议状态由其自身上限管理，Connection 队列与返回结果由 Connection 管理。
本规范不新增全局会话数/缓冲配置，也不据此承诺进程 RSS 上限。

正常 EOF 分方向处理：

- 客户端请求头未完整：截断失败。完整无余量请求后 FIN：等待建连、启动写和完整成功回复，再关闭下游输出。
- 业务转发中客户端 FIN：先写完全部已接收的业务输出，再半关闭下游，反向继续读取。
- 下游正常 EOF：先处理所有已读输入，PROXY 再调用 `finishInbound()`；协议截断保留 Wire 原始错误。
- 合法下游 EOF 可以提前记录和检查，但必须等启动写、完整本地成功回复、反向余量及写队列排空后，
  才关闭客户端输出。**零业务字节也执行成功回复屏障**；DIRECT 与 PROXY 相同。
- 正常全关闭而没有 `.inputClosed` 时补做同一次 EOF 检查。已知网络错误或取消不能被尾部截断覆盖。

单侧 EOF 不等于整个会话结束。两方向结束、错误、取消或运行周期关闭才统一终结。
终结后不再解析、建连、调用 Wire 或恢复读写；迟到成功 Channel 立即关闭。
首次原始错误、回复写权、资源释放分别只提交一次；失败回复的写错不覆盖首因。
`closeConnection` 仅释放下游与本组件资源，accepted Channel 仍由主 handler 最终关闭。

<a id="doc-08-configuration"></a>
## 08 · MagentConfig 与运行周期

配置通过现有 `MagentConfig` 进入服务，使用现有 listener、defaultTimeout、defaultDecision、rules、
proxyNodes 和所属入口实际需要的字段。SOCKS4 不消费 SOCKS5 UDP 的 DNS 监听字段，不新增配置文件格式。

生命周期采用架构的 `start` / `restart` / `close`：

- `start` 为本次运行创建 Core 和关闭通知，绑定 listener 后接入会话。
- `restart` 先验证完整新配置并创建新 Core；该阶段失败保留旧运行周期。成功后关闭旧 listener 和旧会话，
  使用服务原有 EventLoopGroup 绑定新 listener。新绑定失败时服务停于未运行状态，不假装旧连接仍可用。
- `close` 关闭当前运行周期并回收 group，对该 Magent 实例为终结操作；之后需要创建新实例。

每个运行周期有独立关闭通知，不能把已完成通知传给新周期。活动连接不替换 Core、Wire 或目标，
也不保留旧隧道跨越 restart。无需快照 ID、运行中规则热替换、旧会话排空期限或独立 drain API。
应用从 NIO EventLoop 之外调用这些同步 actor 边界，不在 Channel handler 中调用并等待。

<a id="doc-09-errors-security-observability"></a>
## 09 · 错误与信息边界

解析、Core、Channel 和 Wire 的原始错误交给 Connection 的统一失败边界，再由 accepted owner 决定最终关闭。
辅助方法不得仅为包装、改名或改路捕获错误；确需本地清理时仍重抛原错误。节点类型不进入本地回复分支。

日志不记录 USERID、业务载荷、节点密码或原始控制帧。来源权限、系统代理恢复和网络暴露属于应用边界；
不能把本入口的 CONNECT 成功当作整机无 DNS 泄漏、客户端已认证或远端已执行目标安全策略的证明。

<a id="doc-10-tests-and-acceptance"></a>
## 10 · 验收

### 报文与地址向量

下面的 `\0` 表示单个 NUL，字符串拼接仅表示线上字节顺序。文档地址不作为公网可用测试服务。

| ID | 输入或构造 | 必须观察到 |
| --- | --- | --- |
| P01 | `04 01 01 BB CB 00 71 0A 00` | IPv4 `203.0.113.10:443`，恰好 9 字节请求 |
| P02 | `04 01 01 BB 00 00 00 01 00` + `example.com\0` | Domain `example.com:443`，恰好 21 字节请求 |
| P03 | SOCKS4a 标记末字节遍历 `1...255` | 全部进入 DOMAIN 分支；`0` 进入普通 IPv4 分支 |
| P04 | USERID 为空或为 `FF 00` | 接受，不当作认证或域名 |
| P05 | 总请求恰好 64 KiB，或超过 1 字节 | 前者仍按字段验证；后者拒绝，缓冲不无限扩容 |
| P06 | 标签 `63/64` 字节、标签部分总长 `253/254`、合法名称附一个根点 | 分别接受/拒绝；合法带根点名称总长可为 254，根点保留 |
| P07 | `WWW.Example.COM.`、`www.example.com`、`localhost` | 前两者大小写规范化但根点身份保留，第三项按模型合法 |
| P08 | 规范 IPv4 文本及 `203.0.113.10.`、`127.1`、前导零、十六进制别名 | 仅规范 IPv4 成功且无 DNS，其他失败 |
| P09 | 版本 5、BIND、未知命令、端口 0、空 DOMAIN、原始 UTF-8、IPv6 文本 | 协议或地址失败；未知版本不写 SOCKS4 回复 |
| P10 | 固定头/NUL 任意分片、逐字节输入 | 未完整则等待；EOF 截断才失败；总处理不因分片退化为重复全缓冲扫描 |
| P11 | 完整头与额外 1 字节同次 read | 先拒绝，零路由、零出站，不保存为客户端余量 |
| P12 | 请求已接受，建连/启动/成功回复期间再收到字节 | 失败且不转发；成功回复已开始则不追加失败回复 |
| P13 | 成功回复完整写成后收到 `04 01 ...` 载荷 | 透明转发，不重新解析或创建第二条隧道 |

每个合法请求执行所有单切点与逐字节分片。严格顺序另外覆盖“尾部同 read”和“成功前后续 read”；
是否允许业务由本地回复完成状态决定，不能只根据 TCP 分片位置决定。

### Core、Wire 与生命周期

| ID | 场景 | 必须观察到 |
| --- | --- | --- |
| R01 | 不同 order 的精确/后缀规则，同 order 不同具体性 | MODELS 的统一比较生效，不能配置首命中 |
| R02 | 重复 Match、同 order 同具体性、空规则/未命中 | 最后配置覆盖，稳定位置决胜；只有未命中使用默认动作 |
| R03 | 同 host 不同端口、域名与 CIDR、数值与域名规则 | 当前规则不按端口改变结果，不旁路 DNS 或反查 |
| R04 | 根点目标经过路由和 Wire | 路由可用去点视图；Wire 得到保留根点的原目标 |
| R05 | 默认代理引用缺失/命中规则的节点缺失 | 分别在 Core 初始化/实际命中处失败，均无 DIRECT 回退 |
| W01 | PROXY 建连、启动 nil/非空、服务器先发 | 原目标一次启动；非空启动写成后才开始成功回复，无启动字节不等首包 |
| W02 | 提前节点数据、空解码结果、任意 Wire 分片 | 业务等待屏障且有界，空结果不是 EOF，控制字节不泄漏 |
| W03 | Wire 已存大部分单元，最后 1 字节释放大输出，或编码扩张 | 调用前预留最坏输出，返回后不突破队列容量，不增加 getter |
| W04 | 双向二进制传输及一方向慢写 | 字节精确有序，两个方向独立背压，无业务重放 |
| L01 | 完整无余量请求紧跟 FIN | 建连/回复继续，成功后半关闭下游输出，反向响应可读 |
| L02 | 请求头截断后 FIN | 失败，无下游创建 |
| L03 | 启动写/成功回复未完成时下游正常 EOF，含零业务 | 先检查/记录，屏障和反向写排空后才关闭客户端输出 |
| L04 | 协议截断、已知网络错误、取消、迟到建连/写完成 | 原始首因不被覆盖，关闭与清理一次，终态不恢复 |
| L05 | 部分成功回复写出后失败 | 不追加 `0x5B` |
| L06 | restart 验证失败、成功换周期、新 listener 绑定失败 | 分别保留旧周期、结束旧会话并使用新 Core、保持停止；不热换活动 Wire |
| L07 | close 与新运行周期 | close 终结实例；新周期不得复用旧关闭通知、缓存或 Wire |

Wire 的公共验收还须覆盖 [W-01～W-30](WIRES_SPEC.md#验收) 中适用于 TCP 的项目。
测试使用实际 Core/Connection 装配路径，不添加测试专用生产 API；外部节点集成须显式启用并说明环境。
文档检查、单元测试和真实网络互操作分别报告，不能互相代替。

## 协议来源

- [SOCKS4 原始协议](https://www.openssh.org/txt/socks4.protocol)：请求/回复字段、CONNECT/BIND、IDENT 状态。
- [SOCKS4a 原始扩展](https://www.openssh.org/txt/socks4a.protocol)：`0.0.0.x` 标记及独立 DOMAIN 字段。
- [RFC 9293](https://www.rfc-editor.org/rfc/rfc9293.html)：TCP 字节流和半关闭。

64 KiB 请求上限、严格请求/回复顺序、模型地址限制和 Magent 生命周期是本库范围，
不宣称这些限制代表所有 SOCKS4 实现或完整协议兼容。
