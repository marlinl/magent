---
desc: "SOCKS5 无认证协商、TCP CONNECT、控制连接所属 UDP 关联及其模型、Wire 和生命周期契约。"
version: "1.2.0"
updated_at: "2026-10-09"
status: "草案"
---

# Magent SOCKS5 规范

本文定义 Magent 库中的 SOCKS5 入口目标契约。公共配置及资源所有权遵守
[Architecture](ARCHITECTURE.md)，地址、规则和节点遵守 [MODELS v0.4.3](MODELS_SPEC.md)，
出站编码遵守 [Wire v0.3.1](WIRES_SPEC.md)。本文不增加公共配置、规则动作或服务生命周期 API。
规范要求不表示当前源码已经实现或通过验收。

<a id="s01"></a>
<a id="s02"></a>
## 01. 范围

支持无认证方法 `0x00`、TCP CONNECT，以及由控制 TCP 连接拥有的 UDP ASSOCIATE。
业务目标支持 IPv4、IPv6 和模型接受的 ASCII 域名；UDP 本地中继仅使用 IPv4，后端可以是 IPv4 或 IPv6。

不支持用户名密码、GSSAPI、BIND、SOCKS UDP 分片、UDP over TCP 或载荷中的 DNS/HTTP/TLS 嗅探。
只提供 `0x02` 等不支持的方法时回复 `05 FF` 并关闭。不能声称完整实现 RFC 1928 的全部要求。

TCP 使用严格请求/回复顺序：greeting 后须等待方法回复，请求后须等待命令成功回复，才能发送下一阶段字节。
没有提前业务数据队列，也不接受 greeting 与 request 粘包。客户端可以分片发送当前阶段消息。

<a id="s03"></a>
<a id="s23"></a>
## 03. 所有权与协作者

| 所有者 | 职责 |
| --- | --- |
| Magent | EventLoopGroup、listener、accepted Channel 和运行周期关闭通知 |
| MagentTCPConnection | 协议探测、客户端输入/EOF 分派、accepted Channel 最终关闭 |
| Socks5Connection | 本地解析及回复、TCP 下游、UDP 关联 Channel、可选 DNS client、后端登记及清理 |
| MagentCore | 使用模型规则选路、提供 TCP/UDP Wire、创建下游 Channel |
| Wire | 节点端点、TCP 启动及编解码；不拥有 Channel 或发送本地 SOCKS 回复 |

所有 Channel 使用服务拥有的 EventLoopGroup；本连接的 Channel 和状态在 accepted EventLoop 上推进。
不创建专用线程池、Task 或第二套会话调度器。各异步完成回调必须先检查所属连接仍存活；迟到资源立即释放。
`closeConnection` 只清理本组件拥有的资源，不关闭 accepted Channel，也不重复上报清理错误。

<a id="s04"></a>
<a id="s20"></a>
## 04. 配置与地址

只消费 `MagentConfig` 已有的 listener、defaultDecision、rules、proxyNodes、defaultTimeout 和 dnsListener。
应用决定监听地址及是否暴露 LAN；库没有入站用户、密码、访问名单、独立认证阶段或额外 JSON 配置格式。
UDP 的客户端来源固定属于关联校验，不代表用户身份认证。

| 地址 | 表达与用途 |
| --- | --- |
| CONNECT / UDP 业务目标 | `NetworkAddress`；操作入口拒绝端口 0 |
| 客户端来源、节点、BND、DNS 服务器 | 实际 `SocketAddress`；不能与业务目标互换 |
| ASSOCIATE 请求地址 | 客户端 UDP 来源提示，允许端口 0；不参与业务路由 |

<a id="s05"></a>
<a id="s06"></a>
## 05. TCP 协商、请求与回复

### greeting

```text
VER(1) | NMETHODS(1) | METHODS(NMETHODS)
```

VER 必须是 `05`，NMETHODS 为 `1...255`，当前消息长 `2 + NMETHODS`，最多 257 字节。
完整列表包含 `00` 才回复 `05 00`；无 `00` 或空列表回复 `05 FF` 后结束。
同时包含 `00` 和 `02` 仍只选择 `00`；不进入 RFC 1929 子协商。

`05 00` 完整写成后才进入请求阶段。greeting 后同批剩余字节，或回复写成前收到的额外字节，
都属于顺序错误，不保存为后续请求。方法回复与命令回复各有独立的一次提交权。

### request

```text
VER(1) | CMD(1) | RSV(1) | ATYP(1) | DST.ADDR(variable) | DST.PORT(2)
```

VER=`05`，RSV=`00`。CMD=`01` 为 CONNECT，`03` 为 UDP ASSOCIATE；BIND=`02` 和其他命令失败。
ATYP=`01` 为 4 字节 IPv4，`04` 为 16 字节 IPv6，`03` 为一字节长度 L 加 L 字节域名。
端口采用网络字节序。三种请求长度分别为 10、22、`7 + L` 字节；域名字段 L 不得为 0。
版本、RSV、命令、地址和业务端口都须校验；拒绝的命令不必等待无用的剩余地址体。

解析只消费当前阶段：未齐时保留已有片段，已确定非法时立即失败。
完整请求后同批余量、建立期间额外字节、成功回复写成前额外字节均失败；不向下游转发这些字节。
握手缓存仅用于当前消息，不能因为等待回复或出站建立而无限积累输入。

### reply

```text
VER=05 | REP(1) | RSV=00 | ATYP(1) | BND.ADDR(variable) | BND.PORT(2)
```

CONNECT 成功等待 DIRECT Channel 可用，或 PROXY Wire 初始化及启动写入完成；随后提交完整成功回复。
BND 使用所建下游 Channel 的实际本地端点，不可用时用 `0.0.0.0:0`。
PROXY 的该端点只是本地连接节点的绑定信息，不声称是目标侧绑定地址。
ASSOCIATE 成功等待本地中继及所属资源就绪，BND 按 §13 发布。失败统一使用 `0.0.0.0:0`。

每阶段写开始即占有回复权。部分成功回复之后发生错误，只结束连接，不追加另一个结果回复。
成功仅表示本地建立条件满足，不证明目标应用已完成操作。

<a id="s07"></a>
<a id="s21"></a>
## 07. 地址校验

协议层负责 ATYP、长度及端口；逻辑地址统一通过模型构造入口创建。
数值 IP 字段从二进制构造临时 `SocketAddress`，读取数值文本后构造 `NetworkAddress`，不执行 DNS。
实际来源比较、BND 和 UDP 回包来源直接使用 `SocketAddress`。

域名遵循模型的 ASCII、标签、长度、数字歧义和根点规则：允许合法单标签，转小写并保留一个显式根点。
不裁剪空白，不接受 NUL、原始 Unicode、空标签或宽松数值地址；不额外增加 IDNA 转换或身份字段。
域名字段内的标准 IPv4 文本按模型成为 IP；IPv6 业务地址须使用 ATYP=`04`。

规则匹配可使用去掉一个根点的视图，交给 Wire 的目标仍保留根点。
构造失败是地址错误；本规范不增加全局目标 ACL、特殊 CIDR 黑名单或新的 REJECT 路由动作。

<a id="s08"></a>
## 08. 路由

路由完全使用 MODELS 的 `ProxyRule` / `Decision`。动作只有 `.direct` 与 `.proxy(UUID)`。
Core 从实际命中的候选中依次比较：较小 `order`、同 order 下更具体、仍相同则较早保留的输入位置。
同具体性比较及重复规则覆盖遵守 [Core 的选择顺序](MODELS_SPEC.md#core-的选择顺序)。

规则不匹配端口或 transport，不新增配置顺序首匹配、默认强制 DIRECT 或 DNS 专用规则。
无命中使用 `MagentConfig.defaultDecision`；命中代理但节点缺失或操作失败，必须报错，不当成未命中、不回退直连。
路由不执行 DNS，不以解析后的 IP 重新路由域名。缓存只保存 Decision，不保存 TCP Wire 状态。

TCP CONNECT 选路及 Wire 各一次；UDP 每个有效包使用其自身目标选路。
不同 UDP 目标可以命中同一节点，并使用 Core 在该运行周期提供的同一个可共享 UDP Wire。

<a id="s09"></a>
<a id="s10"></a>
<a id="s16"></a>
## 09. DNS

| 路径 | 行为 |
| --- | --- |
| TCP DIRECT IP | Core 使用已验证数值端点，不解析 |
| TCP DIRECT 域名 | Core 在连接流程通过 NIO 异步解析及建连；超时使用 defaultTimeout |
| UDP DIRECT IP | 使用数值端点，不解析 |
| UDP DIRECT 域名 | 使用当前关联可选 DNS client，服务器来自 dnsListener；未配置则该操作失败 |
| TCP/UDP PROXY | 只连接 Wire 的实际节点端点；业务域名原样交 Wire，入口不查询目标 DNS |

UDP 域名解析在同一 EventLoop 向配置服务器查询 A 和 AAAA；两者成功后优先选首个 A，否则首个 AAAA，
无结果则失败。查询超时采用 `core.defaultTimeout`，不回退系统 Resolver，不并发复制业务包尝试多个目标。
关联可以按完整目标缓存选定数值端点；缓存随控制连接释放，不引入 TTL 刷新服务。

禁止在 EventLoop 上读取域名的同步 `socketAddress` 转换。节点名称装配与业务目标解析分开；
不增加公共 Resolver、系统工作池、DNS 服务监听或基于 UDP DATA 中 QNAME 的路由。

<a id="s11"></a>
<a id="s17"></a>
## 11. TCP Wire 集成

接口及调用约束直接遵守 [Wire v0.3.1](WIRES_SPEC.md)。DIRECT 不构造 Wire；PROXY 使用同一个
Wire 的 `getEndpoint()` 建连，`getTimeout()` 是节点连接的正整数毫秒超时。

节点连接后恰好调用一次 `start(handshake: target)`。非 nil 启动字节直接写出，不再次编码；
写成或 start 返回 nil 后才提交本地成功回复。成功回复写成前不编码客户端业务。
后续客户端数据调用 `encodeOutbound(data, address: nil)`，节点数据调用 `decodeInbound`。
TCP 解码空 data 不是 EOF；继续读取以完成协议单元，不等待客户端先发送业务。

早到的节点数据与客户端非法提前数据不同：Wire 初始化前可保留有限原始输入，初始化后可解码；
业务结果必须等待启动写入和本地成功回复两个屏障，再有序交付。

<a id="s12"></a>
## 12. EOF、背压与结束

客户端在不完整 greeting/request 后 EOF：结束，不创建出站。
完整、无余量 CONNECT 后收到 FIN：可以完成建立和成功回复，再半关闭下游输出；反向仍可继续。
成功后每个方向写完已接收数据才传播该方向 EOF，不用整连接 close 代替半关闭。

下游正常 EOF 先处理全部已读字节；PROXY 调用 `finishInbound()` 恰好检查一次。
Wire 尚未初始化时先记录 EOF，初始化和已读输入处理后再检查。正常 EOF 必须等待启动写及完整本地成功回复，
再排空反向业务并半关闭客户端输出；**零业务字节、空写队列也不得跳过成功回复**。
截断为原始错误；网络错误和取消不额外调用完整性检查覆盖首因。

两个 TCP 方向分别手动续读：写入完成后才恢复对应来源；解码无结果时继续本方向读取。
不得为每块输入建立独立 Task 或无界写队列。具体输入和最坏输出的预留遵守 Wire 容量契约，
以现有 owner 的固定内部容量实现，不新增公共预算服务或全局会话配额 API。
两方向结束或发生错误后，请求 accepted owner 结束连接；下游清理由 `closeConnection` 收敛。

<a id="s13"></a>
## 13. UDP ASSOCIATE

控制 TCP 的本地地址必须可以发布为具体 IPv4 地址；本版不实现 IPv6 本地 UDP 入口。
关联拥有一个绑定 `0.0.0.0:0` 的 IPv4 relay/outbound Channel、一个绑定 `[::]:0` 的 IPv6 outbound Channel，
以及配置 dnsListener 时的可选 DNS client。均使用控制连接的 EventLoop。
两次 UDP bind 及所需 DNS client 装配成功后，才能回复 ASSOCIATE 成功；部分创建失败要释放已创建资源。

BND 为该 TCP 控制连接的具体本地 IPv4 地址和 IPv4 relay 的实际临时端口，不发布通配地址或自造端口范围。
成功回复写成后才开始 UDP 读取。ASSOCIATE 不预先选择业务目标、后端或 Wire。

来源提示只能是数值地址：零地址采用控制 TCP 的实际来源 IP，非零地址须与该来源相符；非零端口固定来源端口，
零端口等首个合法包固定。域名 hint 不解析，作为不支持的地址拒绝。
IPv4-mapped IPv6 按数值身份比较，但保留实际来源 SocketAddress 用于回包。

控制 EOF、失效、运行周期关闭都结束整个关联；关联不依赖至少存在一个后端记录。
控制 TCP 不承载 UDP 数据，成功后额外 TCP 字节视为协议错误并结束关联。
无单流 socket、单流 Wire、流状态机、失败冷却或关联/流空闲 TTL。

<a id="s14"></a>
## 14. UDP 报文

```text
RSV(2)=0000 | FRAG(1)=00 | ATYP(1) | DST.ADDR(variable) | DST.PORT(2) | DATA
```

IPv4 头长 10，IPv6 头长 22，域名头长 `7 + L`；域名及 IP 校验同 §07，目标端口不得为 0。
FRAG 非零直接丢弃，不重组。每次输入必须是完整原始数据报，不跨包补齐、合包或截断转发。
DATA 可为空；来自合法后端的空 DATA 必须形成合法零载荷 SOCKS5 回包，不作为 EOF。

收到或发出的完整数据报上限 65507 字节，包含本地 SOCKS5 头或 Wire 返回的后端编码。
接收能力应覆盖该范围并能识别原始包是否截断；仅 ByteBuffer 长度等于接收容量不能证明包完整。
目标回包加上本地头后超限，整包丢弃。EMSGSIZE 也只丢当前包，不拆包、不改用 TCP。

先确认关联、来源 IP 和已固定端口，再检查完整包、头部、目标。未知端口仅由首个全部通过校验的客户端包固定。
不同来源不能重新绑定；回包只发给该固定原始客户端端点。

<a id="s15"></a>
## 15. UDP 路由、登记与回包

本地客户端包去掉 SOCKS5 头后，经 Core 对该包目标选路：DIRECT 仅发送 DATA；PROXY 调用
`encodeOutbound(DATA, address: target)`，把一个完整返回包写向 `getEndpoint()`。
按实际后端地址族使用关联现有的 IPv4 或 IPv6 Channel，不创建目标专属 Channel。

发送前登记实际后端 `SocketAddress` 及其 Wire：nil 表示 DIRECT，非空表示选定代理 Wire。
后端回复必须来自已有登记端点。DIRECT 使用实际来源和 DATA；PROXY 使用登记的 Wire 解码，并采用
解码返回的逻辑来源。不能用节点端点伪造业务来源，也不按最近一次目标或当前全局规则猜测 Wire。

一个实际端点只能具有一种 DIRECT / Wire 解码归属。再次命中相同归属可复用登记；如新包要求不同归属，
拒绝该包并保留原登记，不覆盖记录或另建流 socket。实际后端也不能等于固定客户端端点，以免收包方向无法区分。
不同业务目标经同一节点和同一 Wire 可以正常共享后端；不同关联的来源和登记互不共享。

重新生成本地 RSV/FRAG/来源头，经 IPv4 relay 发给固定客户端。域名来源不为回包或展示触发 DNS。
数值回复来源直接使用实际 IPv4/IPv6 SocketAddress；拒绝 Unix socket、缺少或为零的来源端口及不可编码地址，
不为封装先构造另一个逻辑目标。
每个 Channel 完成当前数据报及其异步操作后再续读；关联保留必要端点与解析记录，不引入逐流队列或重传。
记录必须受固定内部容量约束；容量不足时丢弃需要新增记录的包，不驱逐正在使用的登记来接收新目标。

Wire 的所有 UDP 编码/解码抛错均只丢当前包，同一实例必须仍可处理后续合法包。
UDP 不调用 start、finishInbound 或 getTimeout，不建立 TCP 出站、不等待每包响应。
Core 共享的 UDP Wire 必须满足 Wire 的独立包及并发安全要求；关联结束只释放引用和自身登记。

<a id="s18"></a>
## 18. 失败边界

| 情况 | 处理 |
| --- | --- |
| 无可用方法、空方法列表 | `05 FF` 后关闭 |
| 当前阶段消息非法、顺序错误 | 按阶段失败；不重新探测、不创建后续出站 |
| 命令阶段一般失败 | REP=`01` |
| 节点不存在或无效策略 | REP=`03`，不回退 DIRECT |
| TCP 连接超时 | REP=`04` |
| BIND、未知命令或不支持的操作 | REP=`07` |
| 无效地址/来源提示、未知 ATYP | REP=`08` |
| 结果回复已开始后失败 | 结束，不追加另一结果回复 |
| UDP 坏包、未知来源/后端、归属冲突、容量不足、Wire 编解码抛错、EMSGSIZE | 丢当前包，继续处理后续包 |
| UDP 路由/DNS 操作失败，或所属 Channel 无法继续服务 | 保留原始错误，结束所属关联，不影响其他控制连接 |

本表沿用当前入口的有限错误类别，不推断不存在的远端拒绝、TTL 或目标侧认证语义。
纯解析和 Wire 抛原始错误；单包最高边界决定丢包，TCP/关联失败边界决定回复和通知 accepted owner。
失败回复写失败不覆盖首因。失效、错误、重复 EOF 和迟到完成都不能再次回复或创建资源。

<a id="s19"></a>
<a id="s22"></a>
## 19. 运行周期与资源

每次 start/restart 使用该运行周期 Core。restart 先验证新配置并创建新 Core，再关闭旧 listener 和旧 accepted
连接；旧 UDP 关联随控制连接结束。新配置或 Core 初始化失败时，旧运行周期保持可用。
关闭旧周期后新 listener 绑定失败不等于旧周期自动恢复。close 终结当前 Magent 实例及其 EventLoopGroup。

本规范不增加热更新快照、保留旧会话的更新方式或停机宽限 API。
清理先置终态，再关闭下游 TCP、关联 UDP Channel 和 DNS client，释放缓冲及登记。
DNS/Channel 操作在途时控制关闭，迟到成功资源只能释放；不能继续发送数据或重新登记后端。

TCP 默认连接超时和 UDP DNS 查询超时来自 defaultTimeout；代理 TCP 连接超时来自 Wire。
不把节点超时当成 UDP 响应期限，也不增加当前配置没有的握手、空闲、TTL 或总期限字段。
握手按最大消息长度收集，数据平面按读取/写入完成施加背压；输出扩张按 Wire 契约预留。
日志记录阶段、错误和必要端点，不记录节点秘密、完整载荷或无限堆积逐包失败。

<a id="s24"></a>
<a id="s25"></a>
## 25. 字节级示例

以下完整消息可作为 codec 向量；同阶段任意分片必须产生相同结果。网络可达性不属于解析结果。

| 消息 | 十六进制 | 结果 |
| --- | --- | --- |
| greeting | `05 01 00` | 方法 `00` |
| 同时提供两方法 | `05 02 00 02` | 仍只选择 `00` |
| 仅提供密码方法 | `05 01 02` | 回复 `05 FF`，不进入子协商 |
| 空列表 | `05 00` | 回复 `05 FF` |
| CONNECT IPv4 | `05 01 00 01 C0 00 02 01 01 BB` | `192.0.2.1:443` |
| CONNECT 域名 | `05 01 00 03 0B 65 78 61 6D 70 6C 65 2E 63 6F 6D 01 BB` | `example.com:443` |
| ASSOCIATE 未知来源端口 | `05 03 00 01 00 00 00 00 00 00` | 来源提示，非业务目标 |
| UDP 空载荷 | `00 00 00 01 C0 00 02 35 00 35` | 发给 `192.0.2.53:53` 的零 DATA |
| UDP 分片 | `00 00 01 01 C0 00 02 35 00 35` | 丢包 |

把 greeting 和 CONNECT 两条完整消息直接拼接为同次输入，必须因顺序错误失败。
完整 CONNECT 后拼接业务字节也失败；只有成功回复完整写成后，客户端字节才成为业务数据。

<a id="s26"></a>
<a id="s27"></a>
## 26. 验收

| ID | 场景与断言 |
| --- | --- |
| P01 | 方法列表各分片边界；仅选择已提供的 `00`，空列表/仅 `02` 使用 `05 FF` |
| P02 | greeting/request 粘包、各回复在途额外字节、完整 CONNECT 后余量均拒绝；不路由额外消息 |
| P03 | 三种 ATYP、端口边界、未知命令、RSV、错误版本、超长/截断输入；失败阶段及一次回复正确 |
| P04 | ASCII 单标签、根点、大小写及数值歧义严格遵守 MODELS；原始 Unicode 拒绝 |
| R01 | 低 order 胜过更具体的高 order；同 order 具体性及稳定决胜遵守 MODELS |
| R02 | 无命中用 defaultDecision；代理节点失败不直连；不匹配端口/transport |
| D01 | IP 不解析，PROXY 业务域名不调用 DNS；目标根点原样到 Wire |
| D02 | UDP DIRECT 域名只用 dnsListener；未配置/查询失败按关联失败；A/AAAA 完成及地址选择确定 |
| O01 | TCP 选路/Wire 各一次；startup 不重编码；nil startup 不等待节点首包 |
| O02 | 两个成功屏障及节点先发；解码空结果继续读，非空结果只交付一次 |
| O03 | 启动写或本地成功回复在途的零业务 EOF：完整回复先写成，然后半关闭 |
| O04 | 正常 EOF 完整性检查一次；截断失败，网络错误保留首因；输入/最坏输出/在途写不越限 |
| L01 | 完整无余量 CONNECT 后 FIN 可完成建立；截断请求 EOF 不建出站；两方向独立排空 |
| L02 | 关闭与迟到 Channel/DNS 完成竞争，回复/清理幂等，无资源复活 |
| L03 | restart 新 Core 初始化失败保留旧周期；成功切换关闭旧会话和关联；新周期不复用旧关闭通知 |
| U01 | 两个 UDP bind及可选DNS client装配成功才回复；BND是实际IPv4地址和临时端口，失败释放部分资源 |
| U02 | 首合法客户端包才固定来源；坏包不占来源、非匹配端口不能重绑；IPv6本地控制入口不宣称可用 |
| U03 | 完整包/截断/FRAG/零DATA/封装超长；EMSGSIZE只丢包且后续合法包仍可用 |
| U04 | 多目标共享关联两Channel；实际后端登记决定解码；相同归属复用、冲突拒绝且不覆盖 |
| U05 | UDP Wire 编码/解码错误仅丢包；同实例后续合法包成功，不建逐流socket或失败冷却 |
| U06 | 控制EOF、额外TCP字节、后端资源失败及restart都释放关联；不关闭别的关联共享Wire |
| U07 | UDP无start/finishInbound/TCP建连/逐包超时；输出及登记容量有限，未产生无界队列 |

先验证 codec 和可控 Channel/Wire 的真实消费路径，再运行包级测试；外部节点测试必须明确其环境依赖。
没有以上验收证据时，不能把当前源码或一次网络访问视为完整符合本规范。

<a id="s28"></a>
## 28. 参考

- [RFC 1928](https://www.rfc-editor.org/rfc/rfc1928.html)：方法、命令、地址、回复及 UDP 封装。
- [模型规范](MODELS_SPEC.md)：逻辑地址、规则、节点与身份。
- [Wire 规范](WIRES_SPEC.md)：抽象出站接口、EOF、容量及 UDP 单包错误。
- [架构](ARCHITECTURE.md)：公共配置、现有服务周期及资源所有权。

本版严格请求顺序、单 IPv4 UDP 入口和来源端口固定是产品边界，不泛化为协议唯一允许的行为。
