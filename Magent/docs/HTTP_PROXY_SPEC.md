---
desc: "Magent 当前有限 HTTP/1 请求范围、CONNECT、普通转发、Wire 协作及验收。"
version: "0.3.0"
updated_at: "2026-10-09"
status: "草案"
---

# HTTP 代理规范

本规范采用 [架构](ARCHITECTURE.md) 和 [HttpProtocol 模型契约](MODELS_SPEC.md#httpprotocol)
规定的有限 HTTP/1 范围。它定义目标契约，不表示源码已完成全部迁移或通过验收。
模型拥有请求语义，Connection 拥有请求接收、出站、响应及生命周期，
[Wire v0.3.1](WIRES_SPEC.md) 拥有具体出站协议。

<a id="s01"></a>
## 1. 支持范围

| 项目 | 契约 |
| --- | --- |
| 入站版本 | HTTP/1.0、HTTP/1.1，保留类型化版本；其他版本拒绝。 |
| CONNECT | authority-form，显式非零端口，无请求体；成功后固定目标透明 TCP 隧道。 |
| 普通请求 | `http` absolute-form，或由 Host 确定目标的 origin-form。 |
| 请求体 | 无请求体或单个 Content-Length；完整接收且校验后才发起出站。 |
| 请求 TE / Trailer | 不支持，包括 chunked；不通过删除字段放行。 |
| Expect / Upgrade | 不支持；不执行 100-continue、WebSocket Upgrade 或其他升级。 |
| OPTIONS | 支持发往明确目标的普通 OPTIONS；拒绝入站 `OPTIONS *` 和带 Max-Forwards 的 OPTIONS。 |
| TRACE | 按不支持的方法拒绝；其他合法方法保留大小写。 |
| 连接复用 | 单请求、`Connection: close`；拒绝流水线和后续 keep-alive 请求。 |
| CONNECT 提前数据 | 完整请求结束后、本地成功回复完成前的客户端业务字节拒绝。 |
| 入站认证 | 不支持，不要求凭据，不生成本地 401/407 或代理挑战。 |
| 普通响应 | 直连原始字节或 Wire 解码后的业务字节透明返回，直到下游输入结束。 |

响应透明返回不代表具备完整响应语义、chunked/trailer 校验、HTTP 缓存或协议升级能力。
不会主动将 101 切换为双向 WebSocket；客户端在普通请求结束后发送额外字节仍按单请求边界拒绝。
CONNECT 内的 TLS、HTTP/2 或 WebSocket 是不透明 TCP 业务，不受入站请求特性限制。

本规范不增加公共配置 schema、来源身份系统、连接池、请求重放、路由动作或新的网络资源层。

<a id="s03"></a>
## 2. 接入、所有权与运行周期

Magent 的同一 TCP listener 可探测 HTTP、SOCKS4 和 SOCKS5；HTTP 不另要求专用端口。
`MagentTCPConnection` 选择一个具体 Connection，交付完整探测余量及后续输入，拥有 accepted
Channel 的最终关闭。协议一旦选定，不再因请求失败或隧道内容重新探测。

每个 HTTP Connection 拥有请求缓冲、一次请求语义、下游 Channel、可选 TCP Wire、在途写和终态。
`closeConnection(error:)` 只释放自有下游资源，不关闭 accepted，不生成响应，也不重入错误路径。
主 handler 在 accepted 失效或收到原始错误时统一调用该清理入口。

全部 Channel 使用当前 Magent 实例拥有的 EventLoopGroup；TCP 下游与 accepted 使用同一 EventLoop。
同一连接的状态及 Wire 调用串行推进。异步回调先检查终态；已关闭后只能回收迟到资源，不能继续拨号、
写成功或恢复读取。不能在 EventLoop 阻塞等待，也不能用无归属任务承载网络工作。

运行周期仅遵守 `start`、`restart`、`close`：restart 先验证新配置、创建新 Core，再关闭旧 runtime；
旧连接清理，不迁移到新 Core。close 终止当前服务并关闭其 EventLoopGroup。HTTP 不另设配置热更新、
旧连接保留快照或优雅排空控制协议。

<a id="s06"></a>
## 3. 请求解析与模型消费

### 字节输入

按字节增量解析请求，不将整个接收缓冲转换为字符串后分割。支持任意 TCP 分片，保留重复字段和
准确消费量。CRLF、字段名、控制字符及原始请求行先经真实解码路径检查；底层拒绝的错误直接交
Connection。不能让解码器先合并重复 CL，再要求模型判断原始报文。

字段值只接受合法 UTF-8。必须在 NIO 将原字节转换为 `String` 前严格验证，拒绝非法序列；
不能先使用替换字符解码再声称已经校验。合法 UTF-8 内部字节保持原值，允许按字段语法裁剪首尾 OWS。
这是当前 String 模型的范围限制，不声称接收所有合法 HTTP obs-text，也不新增原始字段影子模型。
响应不经过字符串转换，继续按字节透明转发。

### 唯一请求语义

收到完整 `.head` 时只调用一次 `HttpProtocol(head:)`，保存其 `.connect` 或 `.forward` 结果。
目标、出站请求头及请求体定界以该结果为准；`.end` 不再次从字符串提取目标。
精确类型、错误枚举及构造约束引用 [MODELS 的 HttpProtocol](MODELS_SPEC.md#httpprotocol)。

| 输入 | 结果 |
| --- | --- |
| 精确 `CONNECT host:port` | 目标来自 authority；端口为 1...65535。 |
| 非 CONNECT 的 `http://host[:port]/path?query` | 目标来自 URI；省略端口为 80。 |
| 非 CONNECT 的 `/path?query` | 目标来自唯一合法 Host；`//path` 仍是路径。 |
| CONNECT 使用 URI、路径或 `*` | 非法请求。 |
| 非 CONNECT 使用裸 authority | 非法请求。 |
| 非 http URI scheme | 不支持，不明文连接所谓 HTTPS 目标。 |
| OPTIONS 空路径且无 query 的 absolute URI | 向已确定源站发送 `*`；空 query 则保留 `/?`。 |

地址通过 `NetworkAddress` 的受控入口构造，保留域名根点身份、规范化映射 IPv6；不另写一套路由地址。
路径/query 的百分号转义、顺序、空查询、重复斜线和点段按模型保留，不解码后重编码。

### Host 与请求定界

| 条件 | 契约 |
| --- | --- |
| HTTP/1.1 | 必须恰好一个合法非空 Host。 |
| HTTP/1.0 CONNECT / absolute-form | Host 可缺失；存在时必须唯一合法。 |
| HTTP/1.0 origin-form | 必须恰好一个合法非空 Host。 |
| absolute-form 与合法 Host 不一致 | URI 决定目标，按 URI 重建 Host。 |
| CONNECT 的 Host | 必须与请求目标地址身份一致；Host 缺端口时仅借用请求目标端口比较。 |
| 普通请求无 CL/TE | 无体，不等待 EOF 定界。 |
| 普通请求一个合法 CL | 精确接收该长度，包括零；声明长度不得直接用作无界分配。 |
| 重复 CL、逗号 CL、非法数字/溢出、CL+TE | 出站前拒绝，不容错合并。 |
| 普通请求任意 TE 或 Trailer | 拒绝。 |
| CONNECT CL=0 / 非零 CL / TE | 分别允许 / 拒绝 / 拒绝。 |

`.body` 和 `.end` 由 Connection 检查时序、长度、限额、提前 EOF 及实际 trailer。
普通请求必须完整接收、无多余请求字节才可发起业务出站；CONNECT 必须完成请求结束及解码器余量检查。
收到头部不表示请求已经完整。超出完整请求的同批字节在出站前拒绝；以后才到达的额外字节终止本连接，
不解释为下一事务。

<a id="s10"></a>
### 字段与无入站认证

出站请求头由模型重建：移除被消费的逐跳字段和全部 Proxy-Authorization，重新生成唯一 Host、
零个或一个 Content-Length，以及 `Connection: close`，保留原方法、支持的入站版本和端到端字段重复顺序。
Connection 指名 Host、CL、TE、Trailer、Authorization、Proxy-Authorization 或 Expect 等关键字段时拒绝；
不能通过过滤改变消息定界。完整字段规则引用 [模型的出站头重建](MODELS_SPEC.md#出站头重建)。

缺少或携带代理凭据均不执行认证；不按 Basic、Base64、未知方案或重复凭据内容分支。
普通字段语法、UTF-8 和限额检查仍有效。代理凭据不能进入目标、Wire、日志或本地身份状态。
源站 Authorization、Cookie 及下游响应是业务数据；节点凭据只由节点配置和 Wire 管理。

<a id="s14"></a>
## 4. 路由与出站

每个连接用模型中的同一 `NetworkAddress` 执行一次 Core 路由。规则顺序、具体性、去重和默认决策
遵守 [ProxyRule](MODELS_SPEC.md#proxyrule)：先比较 order，再比较具体性，最后使用保留输入位置。
只有 `.direct` 和 `.proxy(UUID)`，不新增端口/transport 匹配或 REJECT 决策。
独立的输入或安全拒绝是失败路径，不能伪装为路由结果。

DIRECT 数值目标直接拨号，域名由既有 Core 路径解析后连接。PROXY 不做业务目标 DNS；
选定同一 TCP Wire，用 `getEndpoint()` 的实际端点及正整数毫秒 `getTimeout()` 建连。
选中节点缺失、建连或 Wire 失败均结束本次连接，不继续选规则、回退 DIRECT 或重放业务。

节点连接成功后只调用一次 `start(handshake: target)`。nil 表示无需启动字节；非 nil 返回结果直接
写入节点并等待完成，不作业务编码。只有启动成功且可选输出写成后才允许本地成功回复或普通请求发送；
不等待客户端首段业务或节点确认来判断就绪。

普通请求通过 NIO 类型和编码能力生成 HTTP 字节，再直写或调用 `encodeOutbound(data, address: nil)`。
下游每次原始字节交 `decodeInbound`；返回空业务不等于 EOF。Wire 不生成本地 HTTP 响应。
真实正常 EOF 处理完所有已读输入后才调用一次 `finishInbound`；错误或取消不以 EOF 检查覆盖首因。

<a id="s18"></a>
## 5. CONNECT 生命周期

1. 完整解析并校验唯一 CONNECT 请求；完成 `.end` 和余量检查，不接受客户端提前业务数据。
2. 使用唯一目标建立 DIRECT 或 PROXY 下游，等待适用的 Wire 启动写入完成。
3. 在第一次写本地 200 前占有唯一最终回复权。使用该请求版本编码成功头，不包含 CL、TE 或 body，
   也不添加普通响应的 `Connection: close`。
4. 完整 200 写成后进入隧道。Wire 初始化前的节点原始输入和已初始化后的早到业务按所属阶段有界保留，
   只解码一次；成功后先排空反向余量再继续读取。
5. 隧道内只转发固定目标业务。每方向排空已接收/在途字节后再关闭对应输出，另一方向继续运行。

下游正常 FIN 可以早于启动写入或本地 200 完成。可先记录 EOF、初始化后检查 Wire 完整性，
但必须等启动写入成功、完整 200 写成及反向余量排空后，才关闭客户端输出。
零业务字节也不能绕过这两个屏障。启动失败或 Wire 截断按最终回复是否已提交选择错误响应或直接终止。

客户端完整请求后 FIN 可等待建立及回复，成功后半关闭下游输出；请求中途 FIN 是截断。
客户端非空提前业务始终拒绝，不能因缓存够用而放行。成功回复开始后发生任何失败都不追加 HTTP 错误。

<a id="s16"></a>
## 6. 普通转发生命周期

完整接收唯一请求头及请求体，检查无 trailer、长度准确、无流水线余量后，才建立出站。
使用保存的模型请求头和完整请求体进行编码，不重新计算目标，也不手工拼接另一份请求报文。
请求无 body 时同样提交请求 end，不等待新客户端输入。

请求发出后只接受下游响应；客户端额外数据按不支持后续请求终止。
下游原始字节或 Wire 解码后的业务按顺序透明返回，不生成本地“代理成功 200”，不解释源站状态码、
分块编码或 trailer。源站 401、407、101 等字节不转为本地认证或升级控制信号。

在首次向客户端提交源站响应字节前，标记响应已开始。此后网络/Wire 错误只能终止，不能追加本地 502。
下游正常 EOF 经 Wire 完整性检查后，排空客户端写入并结束 accepted；不复用客户端或源站 Channel。
这证明传输结束，不证明未知响应的 HTTP framing 或源站应用内容完整。

客户端 EOF 先处理已读缓冲；完整请求可继续等待发送及响应，缺少声明的请求体则失败。
下游写方向只在请求写完后关闭，不能因客户端 FIN 丢掉尚未发送的请求。

<a id="s21"></a>
## 7. 限额、背压与清理

| 项目 | 当前边界 |
| --- | --- |
| 方法 token | 最多 32 字节；共享探测与 HTTP 解码使用同一限制。 |
| 完整入站请求缓冲 | 最多 64 KiB；普通请求计入头及完整 body，CONNECT 计入请求头。 |
| 请求长度 | 累计、整数转换和分配均检查溢出；超过有限缓冲不得拨号。 |
| DIRECT 建连期限 | 使用当前 Core 的默认连接期限。 |
| PROXY 建连期限 | 使用同一 Wire 的 `getTimeout()` 毫秒值。 |

Connection 不设置另一套公开配置键、全局额度服务或 DNS 工作池；复用所属 Core/运行周期的能力。
Wire 内部缓冲和 Connection 持有的输入/输出分别按 [Wire 缓冲契约](WIRES_SPEC.md#缓冲和进度)约束。
调用前预留输入及最坏输出容量，不在巨大返回值已经分配后才检查。该核算不是进程总内存上限。

每方向一个有序在途写入；写完成才归还该批缓冲并继续对应读取，不能无限把数据排入 SDK 队列。
已有读缓冲在 EOF 后仍须先消费，不能把背压暂停当截断。请求缓存、早到节点字节、Wire 返回值及在途写
都须有界，不新建无上限队列。不能用完整关闭冒充保留另一方向的半关闭。

所有错误、正常结束、restart/close 和 accepted 失效最终幂等释放下游、缓冲及在途资源。
已经关闭的回调不能重复响应或复活连接；迟到建连结果只关闭自身 Channel。

<a id="s23"></a>
## 8. 错误与本地响应

原始错误只在最高拥有边界决定响应及关闭；辅助方法不捕获后包装、改名或按描述文本分支。

| 来源 | 未开始客户端响应且仍可写时 |
| --- | --- |
| 模型 invalidRequest、地址错误、请求解码错误、非 UTF-8 字段、越限/截断/提前数据 | 400 |
| 模型 unsupportedVersion | 505 |
| 模型 unsupportedFeature | 501 |
| 模型 unsupportedExpectation | 417 |
| 下游连接/Wire 失败 | 502 |
| 下游连接超时 | 504 |

未识别为 HTTP 的探测失败可直接关闭。已经发送 CONNECT 成功或任何普通响应字节后，失败只结束连接。
本地回复自身写失败不生成第二回复，也不覆盖首次原始错误。

本地错误用 NIO `HTTPResponseHead` 编码无 body 响应，带 `Content-Length: 0` 和 `Connection: close`。
已识别支持版本时沿用请求版本；无法取得版本时使用 HTTP/1.1。CONNECT 成功遵守第 5 节特殊规则。
本地不生成 401/407 或 Proxy-Authenticate。回复结束后向 accepted pipeline 上报原始错误，主 handler
统一清理；`closeConnection` 本身不再生成回复。

<a id="s28"></a>
## 9. 验收

先覆盖 [HttpProtocol 的 HP-01～HP-24](MODELS_SPEC.md#httpprotocol-acceptance)，再验证真实 NIO 输入、
Connection、Core、Wire 与关闭路径；仅构造模型不能替代连接验收。

| 编号 | 场景 | 必须断言 |
| --- | --- | --- |
| H01 | HTTP/1.0 与 1.1；absolute/origin/CONNECT | 分支、版本、唯一目标及 Host 规则与模型一致。 |
| H02 | CONNECT Host 不同端口/根点；absolute-form 合法冲突 Host | 前者拒绝，后者重建；无 DNS 辅助身份比较。 |
| H03 | 无 CL、CL=0、固定体、重复/逗号/溢出 CL、CL+TE | 正确定界；非法请求无出站。 |
| H04 | 请求 TE/Trailer/Expect/Upgrade、OPTIONS */Max-Forwards、TRACE | 按模型失败类别拒绝，不过滤后放行。 |
| H05 | 完整请求每个分片边界、body 提前 EOF、实际 trailer | 模型只构造一次，body 不丢不重，截断无出站。 |
| H06 | 31/32/33 字节方法；请求总量 64 KiB 边界 | 32 以内合法 token 可识别，33 拒绝；缓存不越限。 |
| H07 | 字段中单字节 FF、截断 UTF-8、多字节 UTF-8 | 前两者在 String 替换前拒绝；合法值按原值重编码。 |
| H08 | 同批第二请求、后续 keep-alive 请求、CONNECT 提前业务 | 拒绝，不路由第二目标、不把数据误送首目标。 |
| H09 | 缺少/任意/重复 Proxy-Authorization；源站 Authorization | 无入站认证，代理字段移除，合法业务字段保留。 |
| H10 | 路由 order/具体性/默认动作、缺失节点、PROXY 域名 | 遵守模型；业务域名无入口 DNS，不回退 DIRECT。 |
| H11 | Wire nil 启动、启动短写/失败、启动前后节点输入 | 单次启动，启动写成后才回复或发请求，业务只解码一次。 |
| H12 | CONNECT 本地 200 短写、部分写后失败 | 完整回复前无业务交付，部分写后不追加错误。 |
| H13 | 启动或 200 在途时下游零业务字节 FIN | Wire 检查、启动写、完整回复、输出 EOF 的顺序正确。 |
| H14 | 客户端完整请求后 FIN、双向隧道半关闭 | 先排空再关闭输出，保留另一方向，最终只清理一次。 |
| H15 | 普通请求编码与 body；下游响应含任意字节/1xx/401/407/101 | 请求发一次；响应原字节返回，不生成本地成功或升级流程。 |
| H16 | 正常 Wire EOF、截断、读错、取消同时发生 | 完整性检查只处理真实正常 EOF，首因不被覆盖。 |
| H17 | 慢写、容量不足、迟到建连、restart/close | 背压和调用前预留生效；资源有界、旧连接终结、不复活。 |

验收报告区分模型验证、连接验证和外部服务集成。未执行的路径不得标为通过；
本规格不以浏览器一次访问成功作为完整验收，也不宣称完整 HTTP 代理/RFC 合规。
