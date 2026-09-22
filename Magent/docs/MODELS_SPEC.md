# Magent 模型 SPEC

版本：0.1.0 · 日期：2026-09-22 · 状态：待实现的设计规范

本文定义重新设计后的 `NetworkAddress`、`HttpProtocol`、`ProxyNode`、`ProxyRule` 模型及其验收契约。关联枚举在对应模型章节内说明。允许调整模型 API 和实际涉及的序列化格式，不保留绕过校验的旧构造入口。本文中的接口是设计草图，不代表当前源码已经实现；本次文档变更不修改生产代码或测试。

## NetworkAddress

### 1. 定位与职责

`NetworkAddress` 是一个不可变的值类型，表示 **一个 IP 或主机名，加一个端口**。它描述代理请求中的逻辑地址，也可以表达协议响应中的地址字段。

构造成功必须意味着地址符合本模型的格式契约，并且已经完成规范化。Core 和 Wire 可以直接消费该值，不需要再次修复、清洗或规范化。

模型负责：

- IP 与主机名的结构校验。
- 主机名大小写、IP 文本与原始字节、IPv4-mapped IPv6 的统一表示。
- 端口的数值范围。
- 确定的相等性、哈希和序列化语义。

以下工作由对应的使用层负责：

- HTTP、SOCKS、Shadowsocks 报文的解析、长度字段和命令语义。
- DNS 查询、缓存、解析期限及搜索后缀策略。
- 监听、连接建立、地址族选择和 Channel 生命周期。
- 端口 `0` 是否适用于当前操作。
- 路由规则匹配、目标安全策略和协议错误回复。

构造成功只保证格式有效，不保证域名存在、目标可连接或访问已获授权。

### 2. 类型与构造入口

公开类型使用 `struct`，内部使用枚举区分地址种类。只读枚举供包内 Core 和 Wire 分支处理，不对外提供接受任意枚举值的初始化方法。

以下是接口草图，方法体省略，不能作为完整 Swift 源文件直接编译：

```swift
public struct NetworkAddress: Sendable, Hashable, Codable {
    internal enum Host: Sendable, Hashable {
        case ipv4([UInt8])
        case ipv6([UInt8])
        case domain(String)
    }

    internal let hostValue: Host
    public let port: UInt16

    public init(host: String, port: UInt16) throws {
        // 校验、规范化并写入不可变存储。
    }

    internal init(ipBytes: [UInt8], port: UInt16) throws {
        // 校验字节数，处理 mapped IPv6，再写入不可变存储。
    }

    public var host: String {
        // 从有效存储生成确定的 host 文本。
    }

    public init(from decoder: any Decoder) throws {
        // 解码字段后调用同一构造入口。
    }

    public func encode(to encoder: any Encoder) throws {
        // 编码规范化的 host 和 port。
    }
}
```

使用方式：

```swift
let server = try NetworkAddress(host: "API.Example.COM.", port: 443)
let local = try NetworkAddress(host: "127.0.0.1", port: 8080)
let ipv6 = try NetworkAddress(host: "2001:db8::1", port: 443)
```

构造入口必须满足以下约束：

1. 文本构造只接受独立的 host。URL、HTTP authority、方括号、内嵌端口由调用方先解析。
2. IP 字节构造接受 4 或 16 字节，并应用与文本入口相同的 IP 规范化规则。
3. `Host` 只是包内的表示形式；不得新增将未经验证的 `Host` 直接装入地址的初始化方法。
4. 所有入口，包括解码入口，都必须建立同一组存储不变量。
5. 不提供 `unchecked` 构造、可写属性或测试专用构造通道。
6. 不设置 `allowZeroPort`、`forBinding`、`forRouting`、`strict` 等改变模型含义的构造开关。

### 3. 存储不变量

| 存储 | 不变量 |
|---|---|
| `ipv4` | 恰好 4 字节，按网络字节顺序存储 |
| `ipv6` | 恰好 16 字节，按网络字节顺序存储；不存储 mapped IPv6 |
| `domain` | 符合第 5 节 ASCII 主机名语法，已经小写化，保留合法的显式根点 |
| `port` | `UInt16`，范围为 `0...65535` |

IP 字节采用 `[UInt8]`，使用从零开始的数组索引。协议解析器从 `Data` 或 `ByteBuffer` 取出地址字段后，应将该字段复制为字节数组。不能假定 `Data` 切片的 `startIndex` 为零。

`host` 是从有效存储生成的文本视图：

- IPv4 输出普通十进制 dotted-quad，不含前导零。
- IPv6 输出统一的小写压缩文本，不带方括号或 scope 后缀。
- 域名输出已经规范化的名称，保留显式根点。
- 不输出端口，不添加 HTTP 语法。
- 不返回空字符串或其他错误占位值，不触发 DNS。

IP 的相等性和规则匹配使用字节，不依赖展示文本。实现可以采用现有数值地址解析和格式化能力，但必须保证没有名称解析副作用。

### 4. IP 解析与规范化

文本入口先区分严格的 IP 字面量与主机名，再构造最终存储。不得把非标准数值地址留给宽松的系统名称解析器解释。

IPv4 文本只接受四段十进制整数，每段为 `0...255`，除单个 `0` 外不得带前导零。

IPv6 文本接受常规完整和压缩表示，解析为 16 字节。只有前 80 位为零、随后 16 位为 `0xffff` 的 IPv4-mapped IPv6 转换为等价 IPv4；其他 IPv6，包括 IPv4-compatible 和 NAT64 前缀地址，保持 IPv6。

文本与字节入口必须产生相同结果：

| 输入 | 结果 |
|---|---|
| `192.0.2.1` | IPv4 `[192, 0, 2, 1]` |
| `::ffff:192.0.2.1` | 同一个 IPv4 值 |
| 对应 mapped IPv6 的 16 字节 | 同一个 IPv4 值 |
| `2001:db8::1` | 原生 IPv6 |
| `::192.0.2.1` | 保持 IPv6 |
| `64:ff9b::192.0.2.1` | 保持 IPv6 |
| `127.1`、`2130706433` | 拒绝省略段或整数形式 |
| `127.000.0.1`、`0177.0.0.1` | 拒绝前导零形式 |
| `0x7f000001`、`0X7F.0.0.1` | 拒绝十六进制形式 |
| `256.0.0.1`、`1.2.3.4.5`、`192..2.1` | 拒绝无效数值表达 |
| `192.0.2.1.` | 拒绝带根点的纯数值表达，不作为域名转交解析器 |
| `[::1]`、`fe80::1%en0` | 拒绝方括号和 scope 文本扩展 |

数字歧义检查是本模型明确采用的输入策略：仅由数字和点组成的文本，以及各段均为十进制数字或 `0x` 风格十六进制数值的文本，必须通过严格 IPv4 语法才能被接受；空段、空十六进制主体同样拒绝。不得通过先 trim、删除根点或补齐缺失段来接受它们。

该检查不能误伤包含普通名称标签的域名，例如 `0xfeed.example`。这类名称继续执行主机名语法校验。

### 5. 主机名契约

本模型接受 ASCII 主机名，不直接接受原始 Unicode 域名。主机名规则如下：

| 项目 | 规则 |
|---|---|
| 空名称 | 拒绝 |
| 字符集 | ASCII 字母、数字、连字符及标签间的点 |
| 大小写 | 构造时转换为 ASCII 小写 |
| 标签长度 | 每个标签 `1...63` 字节 |
| 总长度 | 去掉一个合法末尾根点后为 `1...253` 字节 |
| 连字符 | 标签首尾不允许 |
| 根点 | 允许一个末尾根点，存储和转发时保留 |
| 单标签 | 允许符合其他规则的普通名称，例如 `localhost`；纯数值歧义仍按第 4 节拒绝 |
| 空白、控制字符、NUL | 拒绝，不 trim、不截断 |
| 空标签、前导点、连续点、多个根点 | 拒绝 |
| `_`、`/`、`\`、`@`、`:`、`[`、`]`、`%` | 不属于允许的主机名字符 |

带根点的合法名称最长可为 254 字节。协议自身的地址字段长度限制必须由协议解析器和编码器处理，不能用线协议的 255 字节上限替代主机名长度规则。

UI 和配置导入层需要支持 Unicode 时，应使用明确版本、具备测试向量的 IDNA 实现完成转换和验证，再调用本模型。不能在模型内手写不完整的 Punycode 算法。

本模型只承诺 ASCII 主机名语法，不把 `xn--` 前缀和 LDH 字符检查视为完整 A-label 有效性证明。如果某协议入口承诺完整 IDNA 有效性，该入口必须调用相应的完整校验实现；这项额外契约必须单独验收。现有 SOCKS5 SPEC 的有效 A-label 要求不能仅凭本模型通过而标记完成。

### 6. 端口与操作语义

端口统一使用 `UInt16`。从配置整数、字符串或序列化输入转换时必须精确转换；溢出、负数或非整数必须失败，禁止截断、回绕和替换为默认值。

模型允许 `0`，具体操作入口决定是否允许使用：

| 使用场景 | 职责 |
|---|---|
| CONNECT 目标、UDP 业务目标 | 对应操作入口拒绝端口 `0` |
| 临时 socket 绑定 | 绑定策略可以允许 `0`，表示系统分配 |
| SOCKS5 ASSOCIATE 来源提示、协议响应地址 | 按对应字段语义处理，不能套用 CONNECT 目标规则 |
| 路由匹配和 Wire 编码 | 消费前面建立的模型与操作契约，不重复执行同一端口策略 |

模型允许端口 `0` 不等于自动改变 Magent listener 的产品策略。listener 是否支持临时端口，需要在监听配置的契约中明确。

### 7. 相等性与哈希

`Equatable` 和 `Hashable` 使用规范化后的地址种类、存储内容和端口。两者必须采用相同的身份语义。

| 两个值，除特别标明外端口相同 | 相等性 |
|---|---|
| `API.Example.COM` 与 `api.example.com` | 相等 |
| 相同 IP 的不同文本写法 | 相等 |
| IPv4 与对应 mapped IPv6 | 相等 |
| 文本入口与字节入口构造的同一个 IP | 相等 |
| host 相同、端口不同 | 不相等 |
| `example.com` 与 `example.com.` | 不相等，显式根点属于模型保留的信息 |
| 某域名与它当前解析出的 IP | 不相等，不为比较执行 DNS |

端口和根点不能为了路由缓存复用而从地址相等性中删除。`Hashable` 不承诺跨进程稳定的哈希数值，不得把 `hashValue` 用作持久化标识。

### 8. 路由、缓存和转发

目标地址的数据路径为：

```text
协议报文 / 应用配置 / Codable 输入
                  ↓
       构造 NetworkAddress
       校验并规范化，得到不可变值
                  ↓
       操作入口检查命令和端口策略
                  ↓
       路由 → DNS 或拨号 → Wire
            消费同一个地址值
```

不得在 Core 内仅规范化临时副本用于路由，而让调用方将原始表示用于拨号和 Wire 握手。HTTP CONNECT、HTTP forward、SOCKS4a、SOCKS5 CONNECT 和 UDP 目标必须遵循同一构造契约。

路由匹配视图由 `MagentCore` 拥有：

- 域名规则匹配可以去掉一个根点，例如两个地址的匹配名称均为 `api.example.com`。
- 当前规则不匹配端口，因此路由缓存 key 可以忽略端口；新增端口规则时必须同步修改 key。
- key 必须区分域名、IPv4 和 IPv6，使用规范化后的名称或 IP 字节。
- Wire 和解析器收到的模型仍保留显式根点。
- DNS 缓存和实际端点缓存根据自己的语义设计 key，不能直接套用路由缓存 key。

模型不再提供 `normalized()` 或 `hostForMatching`。根点是否影响实际解析以及是否使用绝对名称解析，由解析器所属层明确定义，不由路由缓存隐式决定。

### 9. NetworkAddress 与 SocketAddress

| 类型 | 含义 |
|---|---|
| `NetworkAddress` | 逻辑地址，可能包含尚未解析的域名；用于请求、路由和协议地址字段 |
| NIO `SocketAddress` | 实际 socket 端点；用于监听、连接、UDP 收发和保留传输信息 |

目标设计中 `MagentConfig.listener` 使用 `SocketAddress`，与节点地址和 DNS 地址的现有表示保持一致。若应用需要使用主机名配置监听，应先按应用配置策略解析为实际地址；该职责不放入本模型。

数值地址到 socket 的转换必须使用已经验证的 IP 字节和端口。域名解析由 Core 的连接路径或所属连接的异步解析器执行。本模型不得调用 `makeAddressResolvingHost`，不得隐藏同步 DNS，也不得创建 Channel、线程或 Task。

实际 socket 的地址族、IPv6 scope 和回复路径继续保存在 `SocketAddress` 中。不得把规范化后的逻辑地址用作原始 socket 的无损替代物：

- mapped IPv6 转换为 IPv4 后，不再保留原始传输地址族。
- 本模型不存储 scope；输入转换遇到非零 scope 时必须明确拒绝，不能只复制 IP 字节后静默丢弃。
- 不依赖 scope 的 IPv6 字节可以构造；某业务目标是否需要 scope 才能使用，由操作入口判断并拒绝无法表达的目标。
- UDP 回复继续使用记录的原始 `SocketAddress`。需要比较规范化 IP 身份时，不得覆盖原始端点。
- 原始 ATYP 若对 ASSOCIATE 来源提示、协议校验或诊断有意义，由协议解析器保留；目标规范化不承担保存原始报文的职责。

### 10. Codable 格式

使用明确的 host/port 格式，不依赖内部枚举的自动合成编码布局：

```json
{
  "host": "api.example.com.",
  "port": 443
}
```

编码输出规范化的 host 文本和数值端口。IP 不编码成原始字节数组，也不编码成带端口的 authority。

解码必须先读取 `String` 和 `UInt16`，再通过 `init(host:port:)` 构造。缺失字段、错误字段类型、端口越界或非法 host 必须失败，不补默认 host 或默认端口。

必须保证：

```text
decode(encode(address)) == address
```

往返后保留地址身份、端口和根点，不要求保留原始大小写或原始 IP 文本拼写。旧 enum 的 Codable 布局不作为兼容格式；真实持久化数据的迁移由应用的存储迁移负责，不增加绕过验证的模型解码分支。

### 11. 错误与职责分配

地址内容不符合本模型契约时，构造入口抛出 `MagentError.invalidAddress`。不使用空字符串、端口 `0` 或 unspecified 地址作为失败回退值。

解码器自身的字段缺失和类型错误按 Codable 原始错误传播；读取字段后，地址构造失败按原始构造错误传播。helper 不捕获错误再包装或改名。

HTTP 状态、SOCKS 回复码、UDP 丢包或关闭行为由最高拥有边界统一选择，不进入地址模型。

| 层 | 必须保留的检查 | 可以移除的重复工作 |
|---|---|---|
| 协议解析器 | 报文边界、字段长度、ATYP、UTF-8 解码、命令和字段允许的表示形式 | 各自实现的公共主机名清洗和数值规范化 |
| NetworkAddress | IP 结构、ASCII 主机名语法、规范化、端口类型和解码契约 | 使用阶段的补救校验 |
| 操作入口 | 端口 `0`、支持的地址族、scope 需求和具体访问策略 | 再次检查 host 非空和 IP 字节数 |
| Core | 路由、缓存、解析和连接策略 | 再次规范化地址或仅规范化局部副本 |
| Wire | 自身支持的地址类型和编码长度约束 | 再次检查模型已经保证的字节数和端口范围 |

例如 SOCKS5 Domain 字段是否允许 IPv6 文本，由 SOCKS5 解析器判断。通用文本构造支持 IPv6，不意味着所有协议的 Domain 字段都允许这种表示。

### 12. 实施边界

本次设计允许直接调整公共 API。实现时按以下顺序推进：

1. 在现有 `Sources/Model/NetworkAddress.swift` 中实现受控构造、存储、相等性和显式 Codable。
2. 将协议目标解析统一接入文本或字节构造入口，使路由和 Wire 消费同一结果。
3. 将匹配名称和路由缓存 key 的处理留在 `MagentCore`。
4. 调整 listener 配置及 socket 转换调用方，明确 scope 和原始地址族的保留路径。
5. 删除旧公开 enum 构造、`normalized()`、`hostForMatching` 和包含 DNS 的模型转换方法。
6. 删除已被新构造契约覆盖的重复验证，保留协议和操作自身的检查。
7. 更新包与应用调用方、示例和实际涉及的持久化迁移。

不新增 Validator、Normalizer、Factory、转发包装层或测试专用初始化方法。内部支撑类型可以继续放在同一个文件。

SOCKS 端口编解码等与模型无关的 `Data` / `UInt16` helper 应在相应协议代码中处理；读取失败不能伪装成合法端口 `0`。

### 13. 验收标准

以下为待实现验收项，不能仅凭本 SPEC 存在或旧测试通过而标记完成。

| 编号 | 场景 | 必须验证的结果 |
|---|---|---|
| NA-01 | 三种地址的合法构造 | 明确的存储类型、host 文本和端口 |
| NA-02 | IP 字节长度 0、3、4、5、15、16、17 | 仅 4 和 16 接受，错误稳定传播 |
| NA-03 | 非零起始索引的 `Data` 切片转字节数组 | 地址字节准确，读取 host 不越界 |
| NA-04 | 文本、原始字节、mapped IPv6 表达同一 IPv4 | `==` 成立，Set 中只保留一个身份 |
| NA-05 | 原生、compatible 和 NAT64 IPv6 | 保持 IPv6，不错误折叠 |
| NA-06 | 非标准数值表达及 `0xfeed.example` | 第 4 节拒绝向量失败，普通名称不被误拒绝 |
| NA-07 | 大小写、单根点和多根点 | 小写化、保留单根点、拒绝多个根点 |
| NA-08 | 标签 63/64 字节、名称 253/254 字节 | 长度边界精确，254 字节仅可由合法名称加根点构成 |
| NA-09 | 空串、NUL、空白、Unicode、空标签、分隔符 | 拒绝，不 trim、不截断 |
| NA-10 | 端口 0、1、65535；解码 -1、65536、错误类型 | 模型接受有效范围，越界解码失败，操作入口单独拒绝不允许的 0 |
| NA-11 | 不同端口、大小写、显式根点 | 相等性严格符合第 7 节 |
| NA-12 | Codable 往返与非法输入 | 身份保留，不能绕过构造验证 |
| NA-13 | HTTP、SOCKS4a、SOCKS5 TCP/UDP 的等价目标 | 路由决策、数值拨号与 Wire 地址编码保持一致 |
| NA-14 | 带根点域名的匹配和转发 | 匹配 key 去根点，Wire 中根点保留 |
| NA-15 | 仅构造、比较、哈希、编码、读取 host | 不查询 DNS、不创建网络资源 |
| NA-16 | scoped socket、mapped IPv6 的实际端点 | 不丢 scope，不用逻辑地址覆盖原始回复端点 |
| NA-17 | 协议 Domain 字段中的 IPv6 文本及 ASSOCIATE 提示 | 按协议字段规则处理，不被通用构造能力意外放宽 |

测试使用固定输入和字面量期望值。身份测试使用相等性和集合行为，不断言跨运行不稳定的 `hashValue` 数值。

模型实现应运行定向测试；迁移涉及连接、缓冲、并发或清理代码时，至少执行：

```bash
swift build
swift build -Xswiftc -strict-concurrency=complete
swift test --filter NetworkAddressTests
swift test --filter ConnectionTests
swift test
git diff --check
```

对实际修改的 Swift 文件运行项目规定的 strict lint。应用调用方的编译、持久化迁移和真实网络行为分别验证，不能由包测试通过推断。文档单独变更只执行结构、链接和差异检查。

### 14. 相关文件与规范边界

- [当前 NetworkAddress 实现](../Sources/Model/NetworkAddress.swift)
- [当前模型测试](../Tests/Model/NetworkAddressTests.swift)
- [当前架构](ARCHITECTURE.md)
- [SOCKS4 / SOCKS4a SPEC](SOCKS4_PROXY_SPEC.md)
- [SOCKS5 SPEC](SOCKS5_PROXY_SPEC.md)
- [HTTP SPEC](HTTP_PROXY_SPEC.md)

本文是新模型的设计目标；其他文档中对当前 enum、listener 类型、规范化入口和序列化格式的描述，须在实际迁移后更新。本文不宣称既有协议 SPEC 的全部能力已经实现，也不取消协议入口更严格的字段或 IDNA 契约。

## HttpProtocol

### 1. 定位与设计目标

`HttpProtocol` 表示 **已经校验完成的一个 HTTP 请求头所表达的代理请求语义**。它由 NIO 的 `HTTPRequestHead` 构造，确定业务目标、CONNECT 或普通转发分支，以及普通转发的出站头和请求体定界方式。

构造成功意味着头部语义符合本章契约，可以继续执行对应连接流程；不意味着请求体已经收齐、上游连接成功或响应已经发送。

职责分为三层：

| 层 | 责任 |
|---|---|
| NIOHTTP1 decoder / encoder | HTTP 报文语法、增量解码与消息编码 |
| `HttpProtocol` | 请求头语义、目标提取、Host 和分帧字段检查、出站头重建 |
| HTTP Connection | 请求体接收、运行时限额、鉴权、路由与拨号、响应选择、背压和生命周期 |

`HttpProtocol` 不持有原始接收缓冲、请求体、Channel、Wire、Core、Future 或 Task，不解析响应，也不执行 DNS。不把 `checkConnect()`、可变请求字段和静态 HTTP 响应字节继续混放在同一个对象中。

### 2. 首版范围与其他 HTTP 规范的关系

本章先为两条现有 HTTP 连接建立明确、共用的模型契约。首版选择一个有限的 HTTP/1 请求处理范围；这些是本模型的产品约束，不是所有 HTTP 实现都必须采用的限制。

| 项目 | 本章首版设计 |
|---|---|
| 版本 | HTTP/1.0、HTTP/1.1；保留类型化版本 |
| CONNECT | authority-form，显式非零端口，无请求体 |
| 普通转发 | `http` absolute-form，以及由 Host 确定目标的 origin-form |
| 请求体 | 无体，或单个 Content-Length 指定的固定长度 |
| Transfer-Encoding / 请求 trailers | 首版拒绝，不通过删除字段伪装成支持 |
| Expect / Upgrade | 首版拒绝，不触发 100-continue 或协议升级流程 |
| OPTIONS | 支持发往具体目标的普通 OPTIONS；入站 `OPTIONS *` 和带 Max-Forwards 的 OPTIONS 暂不支持 |
| TRACE | 首版按不支持的方法拒绝 |
| 其他方法 | 保留合法、区分大小写的方法 token，不建立只含常见方法的模型白名单 |
| 连接复用 | 首版 Connection 维持单请求流程，普通出站使用 `Connection: close` |

[HTTP_PROXY_SPEC.md](HTTP_PROXY_SPEC.md) 描述了更大的目标范围，包括仅接入 HTTP/1.1、拒绝入站 origin-form、chunked、完整 OPTIONS/Max-Forwards、Expect、Upgrade 和连接复用。本章不是该完整代理规格的实现声明。

两份文档有明确差异时，实现本模型首版以本章列出的范围为准；实现完整 HTTP 代理目标时，必须同步升级模型和 Connection 的契约与验收，不得只在枚举中预留一个没有执行路径的分支。原 HTTP SPEC 保留为后续完整能力的设计参考。

### 3. 类型形状与唯一入口

保留名称 `HttpProtocol`，作为包内不可变 `struct`。使用带关联值的枚举表达两种请求，避免 `isConnect`、可空目标、可空出站头和可空 body 字段的任意组合。

以下为接口草图，构造实现省略，不是可直接编译的完整源文件：

```swift
import NIOHTTP1

internal struct HttpProtocol: Sendable {
    internal enum BodyFraming: Sendable, Equatable {
        case none
        case fixedLength(UInt64)
    }

    internal enum Request: Sendable {
        case connect(
            target: NetworkAddress,
            version: HTTPVersion
        )
        case forward(
            target: NetworkAddress,
            head: HTTPRequestHead,
            body: BodyFraming
        )
    }

    internal enum Failure: Error {
        case invalidRequest(String)
        case unsupportedVersion
        case unsupportedFeature(String)
        case unsupportedExpectation
    }

    internal let request: Request

    internal init(head: HTTPRequestHead) throws {
        // 检查输入、提取目标并生成最终请求语义。
    }
}
```

选择这些类型的理由：

- `HTTPRequestHead`、`HTTPVersion`、`HTTPMethod`、`HTTPHeaders` 直接复用 NIO 类型。版本不再往返转换为 `"HTTP/1.1"` 字符串，headers 不再转换为普通字典或另一套字段模型。
- `.connect` 只保留目标和入站版本，不存在发往源站的 CONNECT HTTP 请求头，也没有 HTTP 请求体状态。
- `.forward` 保存规范化目标、准备交给编码器的出站 `HTTPRequestHead` 和明确的请求体定界方式。
- `BodyFraming.none` 与 `.fixedLength(0)` 区分未声明请求体和显式声明零长度；二者均没有 body 字节，但出站字段不同。
- `Failure` 仅区分模型自身产生的语义错误，供 Connection 按枚举选择响应，不按错误描述字符串分流。

不提供接受 `Request` 的直接构造方法，也不暴露可写存储。包内可以读取和解构 `request`；修改取出的 `HTTPRequestHead` 副本不能改变模型本身。

该模型不承担缓存 key 或持久化记录的角色，首版不添加 `Hashable`、`Codable` 或保存完整请求的日志接口。验收直接检查分支、地址、NIO 字段和定界结果。

### 4. 构造阶段与验证归属

构造过程必须先验证入站含义，再删除或重建字段：

```text
HTTPRequestHead
    ↓
版本、方法、字段基本合法性和重复关键字段
    ↓
读取原始 CL / TE，确定或拒绝入站分帧
    ↓
request-target、authority、Host → NetworkAddress
    ↓
检查 Connection tokens 及不支持的特性
    ↓
CONNECT 语义 / 普通转发出站头
```

构造只依赖传入的 head，不访问配置单例、网络、系统代理状态或时钟。相同输入必须得到相同结果或相同错误类别。

NIO decoder 负责原始请求行、CRLF、字段语法和增量消息边界。模型不重新解析原始报文，但必须检查直接构造的 NIO head 也可能缺失的值约束：方法和字段名是非空 HTTP token，字段值不含 CR、LF、NUL、DEL 或除 HTAB 外的控制字符。不能认为 `HTTPRequestHead(...)` 本身等于已经完成所有语法校验。

header 名称比较使用 ASCII 大小写不敏感语义。字段值仅在 HTTP 字段语法允许的位置移除 SP / HTAB；不对 request-target 或 host 使用通用 Unicode trim。所有字段保留重复项，检查前不得通过字典、自动合并或覆盖丢失信息。

若底层 decoder 在产生 `.head` 前已经拒绝输入，错误直接到 Connection；若 decoder 折叠了判定所需的信息，必须在 NIO 解码接入处解决，不能让模型猜测丢失的原始字段。网络报文测试和直接构造 head 的测试都必须覆盖这些边界。

### 5. 请求类型与目标的唯一来源

| 方法 / request-target | 分支与业务目标 |
|---|---|
| 精确的 `CONNECT host:port` | `.connect`，目标来自 authority |
| 非 CONNECT 的 `http://host[:port]/path?query` | `.forward`，目标来自 URI authority |
| 非 CONNECT 的 `/path?query` | `.forward`，目标来自唯一合法 Host |
| CONNECT 搭配 absolute-form、origin-form 或 `*` | 非法请求 |
| 非 CONNECT 搭配裸 `host:port` | 非法请求 |
| `OPTIONS *` | 首版能力不足，拒绝；不能伪造业务目标 |
| 其他方法搭配 `*` | 非法请求 |
| `https://`、`ws://`、`wss://`、`ftp://` 等 scheme | 首版不支持，不能悄悄改用明文 TCP |

方法名区分大小写，不能把 `connect` 转为 `CONNECT`。普通方法不按 GET/POST 推断请求体是否存在；分帧独立由字段决定。

scheme 按 ASCII 大小写不敏感识别；request-target 使用 ASCII URI 文本，原始 Unicode 路径需要由客户端先做合法百分号编码。origin-form 中以 `//` 开头的合法 path 仍然是路径，不能重新解释为另一个 authority。

代理节点地址只供 Core 选择传输端点。模型里的 `target` 始终是业务目标，出站 Host 也不得替换为代理节点或 DNS 返回的数值 IP。

authority-form 与 absolute-form 的基本区分，以及 absolute-form 使用 URI authority 重建 Host 的依据见 [RFC 9112 §3.2](https://www.rfc-editor.org/rfc/rfc9112.html#section-3.2)。本章另行明确 origin-form 接入和 CONNECT Host 一致性的产品策略。

### 6. Authority 与 NetworkAddress 的组合

HTTP 层只负责拆分 host、端口和 IPv6 方括号，再调用 [NetworkAddress](#networkaddress) 的受控构造入口。ASCII 主机名规则、数值地址歧义和 mapped IPv6 规范化不得另写一套。

| 场景 | 端口规则 |
|---|---|
| CONNECT request-target | 必须显式提供 `1...65535` |
| 普通 absolute-form authority | 省略时为 80；显式端口必须非零 |
| 普通转发 Host | 省略时为 80；显式端口必须非零 |
| CONNECT Host | 省略时仅用于一致性比较，采用 request-target 已经确认的端口；不得因此推断为 443 |

显式端口只接受非空十进制数字，执行溢出检查。前导零可作为端口输入接受，输出使用普通十进制；不接受正负号、内部空白、空端口或截断转换。

HTTP authority 中 IPv6 必须有完整方括号，括号外只能出现允许的端口后缀。拒绝 userinfo、百分号编码 host、scope、IPvFuture、路径、query 和 fragment 混入 authority。

必须先验证括号内是合法 IPv6 字面量，再交给 `NetworkAddress`。不能在规范化后要求结果仍为 `.ipv6`，否则 `[::ffff:192.0.2.1]:443` 会因合法地转换为 IPv4 而被误拒绝。`[example.com]:443` 和 `[192.0.2.1]:443` 则必须拒绝。

authority 的词法拆分可以在现有 `HttpProtocol.swift` 内共用一个私有方法，返回 host、可选的显式端口和表示信息。CONNECT 是否必须有端口由调用位置决定，不使用一串 `isConnect`、`allowMissingPort` 等布尔开关。需要复用的是拆分规则，不是抹平各字段的语义差异。

### 7. Host 字段契约

| 场景 | Host 要求 |
|---|---|
| HTTP/1.1 | 恰好一个合法、非空 Host |
| HTTP/1.0 CONNECT / absolute-form | 可以缺失；存在时只能有一个且必须合法 |
| HTTP/1.0 origin-form | 恰好一个合法、非空 Host，否则无法确定目标 |
| 所有版本的重复 Host | 拒绝，包括值相同或字段名大小写不同的重复 |

首版对三种目标形式作如下处理：

- absolute-form：URI authority 决定业务目标。合法但不一致的 Host 不改变路由，出站 Host 根据 URI authority 重建。
- origin-form：Host 是唯一目标来源；没有另外的 URI authority 可供回退。
- CONNECT：Host 存在时，用第 6 节端口规则构造比较值，与 request-target 的 `NetworkAddress` 比较；不一致即拒绝。

CONNECT 的一致性比较采用地址值身份：域名大小写被统一，mapped IPv6 与 IPv4 相等，显式根点差异保留。不能使用路由去根点后的匹配 key 来证明 Host 一致，也不执行 DNS 来比较两个域名是否指向同一服务器。

CONNECT 的严格一致性检查是本章产品决策；[HTTP_PROXY_SPEC.md](HTTP_PROXY_SPEC.md) 对 CONNECT Host 采用更宽松的目标优先规则，实现首版时不得混用两个分支。absolute-form 接受合法冲突 Host 也不等于接受缺失、重复或语法非法的 HTTP/1.1 Host；字段数量和语法检查仍先执行。

### 8. Path、query 与出站 authority

普通 absolute-form 只提取结构边界，不对 path/query 做解码后再编码。不得依赖会自动修复非法输入或改变转义文本的 URL 处理过程；如果复用 URL 解析能力，必须用下列字面向量验证其保真行为。

| 输入 URI | 出站 request-target |
|---|---|
| `http://example.com` | `/` |
| `http://example.com?` | `/?` |
| `http://example.com?x=1` | `/?x=1` |
| `http://example.com/a%2Fb?q=%0D%0A` | `/a%2Fb?q=%0D%0A` |
| `http://example.com/a/../b//c` | `/a/../b//c` |
| 合法 origin-form `/a%2Fb?x=` | 原样保留 |

原始空白、控制字符、反斜线、fragment 和不完整的 `%HH` 转义必须拒绝。合法转义不能解码成分隔符或控制字符。重复斜线、点路径片段和查询参数顺序保持不变。

`OPTIONS http://example.com` 是一个特殊但明确的转发请求：作为到源站前的最后一个 HTTP 代理，空 path 且没有 query 时，出站 target 为 `*`；`OPTIONS http://example.com?` 输出 `/?`。这是向已确定源站转发的 OPTIONS，与入站 `OPTIONS *` 的本地能力请求不同。该区别见 [RFC 9112 §3.2.4](https://www.rfc-editor.org/rfc/rfc9112.html#section-3.2.4)。

出站 Host 从最终 `NetworkAddress` 的规范化 host 与 HTTP authority 中的端口存在性生成：

| 入站目标 | 出站 Host |
|---|---|
| `http://API.Example.COM./x` | `api.example.com.` |
| `http://example.com/x` | `example.com` |
| `http://example.com:80/x` | `example.com:80` |
| `http://[2001:db8::1]:8080/x` | `[2001:db8::1]:8080` |
| `http://[::ffff:192.0.2.1]:80/x` | `192.0.2.1:80` |

显式默认端口是 HTTP 表示信息，不属于 `NetworkAddress` 的身份；构造 HttpProtocol 时用局部解析结果保留并生成出站头，不为此扩展通用地址模型。普通 IPv6 根据规范化后的实际类型补方括号，域名根点保留。

### 9. 请求体定界

模型保存的是 body 的定界规则，不保存 body 字节，也不维护已经收到多少字节的计数器。

| 入站字段 | 首版结果 |
|---|---|
| 普通请求无 CL / TE | `.none`，请求没有 body，不能等待 EOF 定界 |
| 普通请求单个合法 CL | `.fixedLength(n)`，包含 `n == 0` |
| 重复 CL，含相同重复值 | 非法请求 |
| 单字段 `Content-Length: 4, 4` | 非法请求，不采用容错合并 |
| CL 非数字、带符号、内部空白或 UInt64 溢出 | 非法请求 |
| 同时有 CL 和 TE | 非法请求，在任何出站之前拒绝 |
| 普通请求任何 TE | 首版不接受；decoder 已判定语法或定界非法时按原始错误处理 |
| CONNECT 无 CL / TE | 无请求体 |
| CONNECT 单个 CL=0 | 允许，但不作为隧道长度、不向目标转发 |
| CONNECT 非零 CL 或任何 TE | 非法请求 |
| 请求声明 Trailer | 首版不接受 |

CL 允许字段外侧合法 OWS 和十进制前导零；检查后以一个十进制整数重建出站 CL。不得先删除 TE、合并 CL 或移除 Connection 指名字段，再推断请求长度。相关消息定界原则见 [RFC 9112 §6.3](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3)，重复 CL 全部拒绝属于本章的严格输入策略。

`UInt64` 只用于安全表达声明长度，不是允许分配同等内存的承诺。Connection 在分配、接收或拨号之前按实际资源限额拒绝过大请求；转换为 `Int` 或累计长度时必须检查溢出。不得在模型内固定一个测试方便的最大 body 大小。

连接层负责校验 `.body` / `.end` 的时序、累计长度、提前 EOF 和实际 trailers。模型构造只看 head，因此不能声称构造成功已经验证了后续 body。

### 10. 出站头重建

使用 `HTTPHeaders` 保留允许转发的字段及重复项，不改变任意业务字段的值。重建顺序如下：

1. 在原始字段上完成 Host、CL/TE 和不支持特性的检查。
2. 按 HTTP 列表语法读取所有 Connection 字段；非空项必须为合法 token，以 ASCII 小写比较，空列表项不作为字段名。
3. Connection 指名 `Host`、`Content-Length`、`Transfer-Encoding`、`Trailer`、`Authorization`、`Proxy-Authorization` 或 `Expect` 等关键字段时拒绝，防止删除操作改变认证、目标或分帧含义。这里的 `Transfer-Encoding` 与独立的 `TE` 字段必须区分。
4. 移除 Connection 指名的普通逐跳字段，以及旧的 Connection、Keep-Alive、Proxy-Connection、TE、Trailer、Transfer-Encoding、Upgrade、Proxy-Authenticate 和 Proxy-Authorization。
5. 根据唯一业务目标重建一个 Host，根据 `BodyFraming` 重建零个或一个 Content-Length；输出中不得出现 Transfer-Encoding。
6. 保留端到端字段的值和重复顺序，例如 Authorization、Cookie、自定义字段；不把 Proxy-Authorization 当作源站 Authorization。
7. 写入首版的 `Connection: close`，使用原方法和支持的入站 HTTP 版本生成新的 `HTTPRequestHead`。

原始 Host 和 CL 由重建值替代，不能一边保留旧字段一边追加新字段。Connection tokens 的检查发生在过滤之前，包括大小写变体。

Expect、Upgrade 字段或 Connection 的 `upgrade` token、请求 Trailer 按首版能力拒绝，不能仅删除头字段后继续当普通请求处理。Expect 产生 `Failure.unsupportedExpectation`，不支持的升级和 Trailer 产生 `Failure.unsupportedFeature`；已发现的非法分帧仍先按非法请求拒绝。对带 Max-Forwards 的 OPTIONS，首版返回能力不足，不能忽略该字段继续转发；完整本地 OPTIONS 分支和递减规则留待独立扩展。

运行时需要添加 Via 或执行认证时，由 Connection 使用明确的运行配置完成。认证读取过滤前的原始 head，不能从已经删除代理凭据的出站头推断身份。Via 的配置和回环策略不进入无上下文模型；添加运行时转发字段不得修改已经确定的 method、target、Host 或 body 定界。

### 11. Connection 消费契约

Connection 收到 `.head` 时构造模型并保存结果；不能在 `.end` 时再次从原始字符串重新计算业务目标。不同事件的职责如下：

| 事件 / 阶段 | Connection 的责任 |
|---|---|
| `.head` | 只构造一次，检查运行时限额、认证与能力，保存不可变请求语义 |
| `.body` | 按模型给出的定界规则接收，进行计数、限额和背压处理 |
| `.end` | 确认消息完整、长度一致、无不支持的 trailers |
| CONNECT 建连 | 使用模型中的 target 完成路由和 Wire 握手 |
| 普通转发 | 使用同一个 target 路由；把模型里的 head 和完整 body 交给编码器 |
| 成功或失败响应 | 由连接状态和错误类别决定，写入完成后再推进状态 |

首版继续采用当前连接的完整请求后发起业务转发、单请求、不接受 pipelining 的流程。缓冲上限由 Connection 执行，模型不拥有完整 body；未来流式转发时修改 Connection 的发送时机和背压，不把 Channel 或计数器塞回模型。

CONNECT 必须等到请求结束、decoder 余量检查完成、业务连接及 Wire startup 就绪、本地 2xx 写入成功后才能进入 tunnel。拒绝提前数据、移除 decoder 的顺序、EOF 和 half-close 都是 Connection 状态机职责。

普通请求通过 NIO 编码能力得到请求字节，再进入直连 channel 或相同 Wire 的隧道载荷路径。不得继续由模型或 `buildPayload` 拼接一份完整 `Data` 请求；具体 encoder 与 Wire 的 pipeline 接法须在连接迁移中验证，不能因改用类型化 head 丢掉已有手动读取、写入完成和关闭顺序约束。

### 12. 本地响应与错误路径

`HttpProtocol` 不再定义 `established`、`badRequest`、`badGateway`、`gatewayTimeout` 等静态 `Data`。HTTP Connection 使用 `HTTPResponseHead` / encoder 生成本地响应，并持有“一次响应”的状态约束。

最高拥有边界按以下类别选择响应；模型 helper 不捕获下层错误再包装、改名或输出响应：

| 错误来源 | Connection 的首版响应策略 |
|---|---|
| `Failure.invalidRequest`、地址构造错误、NIO 请求解码错误 | 400 |
| `Failure.unsupportedVersion` | 505 |
| `Failure.unsupportedFeature` | 501 |
| `Failure.unsupportedExpectation` | 417 |
| 下游连接失败 | 502 |
| 下游连接超时 | 504 |

`unsupportedFeature` 的关联文本只用于诊断，不能据此再拆分状态码。资源限额、鉴权和其他运行错误由对应 Connection 策略处理，不能一概变成 400。成功响应已经开始或进入 tunnel 后，不得再追加 HTTP 错误响应。

CONNECT 成功响应不含 Content-Length、Transfer-Encoding 或 HTTP body，头部结束后进入隧道。普通本地错误可以发送明确的 `Content-Length: 0` 和 `Connection: close`。CONNECT 成功响应的限制见 [RFC 9110 §9.3.6](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.6)。

两个 Connection 需要共用响应编码时，先在现有 HTTP 连接 owner 中评估共享方法；不把重复字节常量移成另一个没有独立职责的文件，也不放回请求语义模型。

### 13. 具体输入与输出

以下示例描述构造的语义结果，不代表已运行新实现。

CONNECT：

```http
CONNECT API.Example.COM.:443 HTTP/1.1
Host: api.example.com.
Content-Length: 0

```

结果为 `.connect`，目标是 `NetworkAddress(host: "api.example.com.", port: 443)`，版本为 `.http1_1`。Host 未显式提供端口，按请求目标端口比较；CL=0 不进入 Wire 握手或 tunnel payload。

普通转发：

```http
POST http://API.Example.COM.:80/a%2Fb?x= HTTP/1.1
Host: ignored.example
Connection: keep-alive, X-Remove
X-Remove: local-only
Proxy-Authorization: example-placeholder
Content-Length: 0004

data
```

结果为 `.forward`，target 为 `api.example.com.:80`，body 为 `.fixedLength(4)`。关键出站字段为：

```http
POST /a%2Fb?x= HTTP/1.1
Host: api.example.com.:80
Content-Length: 4
Connection: close

```

四个 body 字节 `data` 由 Connection 单独保管和发送，不存入模型。代理认证如果启用，在 Connection 中使用原始代理凭据；示例不是认证成功的声明。运行时的 Via 等字段由 Connection 按配置追加。

### 14. 迁移范围

1. 在现有 `Sources/Model/HttpProtocol.swift` 实现唯一的 NIO head 构造入口、关联值请求枚举和必要的私有解析方法。
2. `HttpConnectConnection` 移除版本字符串转换、手工 tuple headers、`checkConnect()` 和独立的 authority 校验链。
3. `HttpForwardConnection` 的目标提取、Host/CL 校验和请求头改写合并到本模型；body 缓冲与状态机留在连接中。
4. 去掉整包 `buildRequest(head:body:)` / `buildPayload` 式模型入口，改为消费类型化 head 和独立 body。
5. 响应常量迁出模型，按 Connection 状态使用编码器发送本地响应。
6. 核对 `ProxyProbe` 与模型范围一致；探测只选择协议，不能替代模型对方法和目标形式的完整检查。
7. 更新原有模型断言与连接回归；CONNECT CL=0、Host 省略端口、错误状态码和 OPTIONS 限制等行为变化必须写成明确用例。

`HttpProtocol` 继续为 internal API，不因重构而公开给应用。嵌套类型及小型私有方法留在原文件，不引入 Context actor、Router、泛型请求框架或测试专用 parser。

### 15. 验收标准

模型纯逻辑验收和真实连接流程验收分开记录。以下均为新设计的待实现项：

| 编号 | 场景 | 必须验证的结果 |
|---|---|---|
| HP-01 | 合法 CONNECT / 普通转发 | 分别得到唯一有效分支，不依赖第二次 check |
| HP-02 | HTTP/1.0、1.1、其他版本；方法大小写和合法未知方法 | 版本策略和区分大小写语义明确，不自动改写方法 |
| HP-03 | HTTP/1.1 缺失、重复、大小写不同的重复 Host | 全部拒绝；HTTP/1.0 按目标形式处理缺失 Host |
| HP-04 | absolute-form 与合法冲突 Host | 目标和新 Host 都来自 URI，原 Host 不影响路由 |
| HP-05 | CONNECT Host 省略端口、大小写、mapped IPv6、不同端口或根点 | 相等情况通过；端口和根点身份不一致拒绝 |
| HP-06 | 方括号 IPv6、mapped IPv6、括号内域名/IPv4、scope | IPv6 字面量先验证，mapped 转为 IPv4 后仍接受，其余非法向量拒绝 |
| HP-07 | CONNECT 缺端口、空端口、0、65536、符号；普通 URI 默认/显式 80 | 端口语义精确，显式默认端口在出站 Host 保留 |
| HP-08 | 空 path、空 query、转义大小写、重复斜线、点路径 | 第 8 节所有字面期望保持；不解码重编码 |
| HP-09 | URI fragment、反斜线、空白、非法转义、userinfo | 拒绝；合法 `%0D%0A` 仍是原字面转义 |
| HP-10 | 无 CL、CL=0、CL=0004 | 分别为 none、fixedLength(0)、fixedLength(4)，出站长度规范化 |
| HP-11 | 重复 CL、逗号 CL、CL 溢出、TE+CL | 在出站前失败，网络报文与直接 head 入口均覆盖 |
| HP-12 | CONNECT CL=0、非零 CL、TE；forward TE/Trailer/Expect/Upgrade | 按首版能力准确允许或拒绝，不通过删头放行 |
| HP-13 | Connection 指名普通字段和 Host/CL/认证字段 | 普通字段移除，关键字段拒绝，比较大小写不敏感 |
| HP-14 | 重复业务字段、Authorization、Proxy-Authorization | 保留允许的字段及顺序，代理凭据不泄漏给源站 |
| HP-15 | 直接构造含非法 token、CR/LF/NUL 的 NIO head | 模型拒绝，不把 NIO 值类型误当成已验证输入 |
| HP-16 | HTTP 与 SOCKS 的等价数字目标 | 使用同一 NetworkAddress 规范化结果路由与编码 |
| HP-17 | body 未收齐、超长、提前 EOF、trailers、重复 head/end | Connection 拒绝或关闭，不把头部模型通过当成完整请求通过 |
| HP-18 | CONNECT 每个拆分点、同包余量、提前 tunnel payload | 严格成功回复顺序，decoder 移除不丢余量或提前放行 |
| HP-19 | 请求头/body 编码与 Wire startup | 先完成正确 startup，再发送 HTTP 字节，body 不重复、不丢失 |
| HP-20 | 本地错误和 CONNECT 成功 | 状态码按类别映射，至多一次响应；成功 CONNECT 无 CL/TE/body |
| HP-21 | 单请求、pipelining、后续 keep-alive 请求 | 首版 Connection 边界保持，不因改模型扩大支持声明 |
| HP-22 | OPTIONS 空 path 无 query、空 query、入站 *、Max-Forwards、TRACE | 明确区分源站 * 转发与未支持的本地能力请求，不猜测目标 |
| HP-23 | 仅构造模型及读取结果 | 无 DNS、无 Channel、无请求体缓存、无日志或认证副作用 |
| HP-24 | 取出 head 后修改副本 | 原模型的目标、头部及分帧规则不改变 |

测试断言必须包括具体 `NetworkAddress` 值、HTTP method/version、精确 target 字符串、字段数量和值、BodyFraming 和失败类别。输出字段大小写或无关字段顺序不作为协议等价性判断，但应验证重复字段的语义和顺序没有被错误合并。

字节级解析和防注入向量必须经过真实 NIO decoder，不能只使用手工构造的 head 代替。模型用例也要覆盖手工 head，证明构造入口自身的契约。Connection 测试继续覆盖背压、half-close、超时、清理和真实编码顺序。

实现后至少执行项目规定的 build、strict-concurrency build、ConnectionTests、全包测试、修改文件的 strict lint 和 `git diff --check`；增加对应的模型定向测试。文档单独变更只做结构、链接与不变量检查，不宣称上述实现验收已经完成。

### 16. 相关文件与证据

- [当前 HttpProtocol 实现](../Sources/Model/HttpProtocol.swift)
- [当前 HTTP CONNECT 连接](../Sources/Connection/HttpConnectConnection.swift)
- [当前 HTTP forward 连接](../Sources/Connection/HttpForwardConnection.swift)
- [当前 CONNECT 测试](../Tests/Connection/HttpConnectConnectionTests.swift)
- [当前 forward 测试](../Tests/Connection/HttpForwardConnectionTests.swift)
- [HTTP 完整代理目标 SPEC](HTTP_PROXY_SPEC.md)

当前源码和测试是迁移调用链的依据，不能证明新模型已经实现。构造、头部字段、分帧和语义分支应按本章重新验收；完整 HTTP 产品能力仍需逐项对照原 HTTP SPEC。

## ProxyNode

### 1. 定位与职责

`ProxyNode` 是一个不可变的、已经通过本地配置校验的出站代理节点值。它描述如何连接代理服务器及采用哪个节点协议，不表示业务目标，也不保存已经建立的连接。

模型负责节点标识、实际服务器端点、协议、密码和连接超时的配置契约。Core 负责节点集合、UUID 查找和 Wire 选择；Wire 负责密码派生、salt、nonce、帧状态及加解密；应用负责节点名称、订阅、启用状态、持久化和节点域名解析。

构造成功表示配置在本地可执行，不保证服务器可达、密码正确或远端实现支持选定算法。构造不访问 DNS，不建立 Channel，不生成连接 salt，也不预先创建 Wire。

本章的关联枚举为 `ProxyNodeType` 和 `ProxyCipher`，均在本章节内定义契约。文档归属不要求把现有枚举源码文件自动合并，也不因重设计而增加新的配置包装文件。

### 2. 类型与构造入口

首版继续表达当前有实际 Wire 支持的 Shadowsocks 节点。字段全部只读，初始化改为抛错，超时改为具有明确单位的整数毫秒。

以下是接口草图，方法实现省略：

```swift
public struct ProxyNode: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let type: ProxyNodeType
    public let address: SocketAddress
    public let cipher: ProxyCipher
    public let password: String
    public let timeoutMilliseconds: Int64

    public init(
        id: UUID = UUID(),
        type: ProxyNodeType = .shadowsocks,
        address: SocketAddress,
        cipher: ProxyCipher,
        password: String,
        timeoutMilliseconds: Int64 = 30_000
    ) throws {
        // 在保存字段之前校验端点、密码和超时。
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // 按第 6 节比较全部配置；密码采用 UTF-8 字节语义。
    }

    public func hash(into hasher: inout Hasher) {
        // 使用与相等性完全相同的字段和字节语义。
    }
}
```

`id` 默认值只用于真正的新建节点；从存储读取、导入更新或替换配置时，应用必须传入已有 UUID，不能通过重新生成 ID 修补丢失的规则引用。

首版只有一种节点协议，`cipher`、`password` 都是该协议的必需字段，不引入可空字段。以后增加不使用这些字段的协议时，应设计带关联配置的协议枚举，再一起迁移构造入口；不能先添加协议名、再依靠大量默认值凑出不完整节点。

### 3. ProxyNodeType

`ProxyNodeType` 是节点协议标识，不是 Wire 实例、网络能力探测结果或默认路由决策。

```swift
public enum ProxyNodeType: String, Codable, Sendable, Hashable, CaseIterable {
    case shadowsocks = "shadowsocks"
}
```

只列出当前具有真实 TCP/UDP 实现和验收路径的协议。暂不增加 SOCKS5、HTTP 上游、DIRECT、REJECT 或未知占位 case；DIRECT 是 [ProxyRule](#proxyrule) 章节中 `Decision` 的动作，不是代理节点。

raw value 是明确的导入标识，大小写和拼写精确匹配。未知协议必须报错，不能自动替换为 Shadowsocks。`allCases` 不构成当前网络环境一定能够使用这些协议的证明。

### 4. ProxyCipher

`ProxyCipher` 标识 Shadowsocks Wire 支持的加密算法及其固定参数；密码不是 master key，`keySize` 也不是密码字符数或 UTF-8 字节数限制。

```swift
public enum ProxyCipher: String, Codable, Sendable, Hashable, CaseIterable {
    case aes128Gcm = "aes-128-gcm"
    case aes256Gcm = "aes-256-gcm"
    case chacha20IetfPoly1305 = "chacha20-ietf-poly1305"
    case xchacha20IetfPoly1305 = "xchacha20-ietf-poly1305"
}
```

以下参数以当前包内 `ProxyCipher`、`AeadCipher` 及对应测试为基线，单位均为字节：

| case | keySize | saltSize | nonceSize | tagSize |
|---|---:|---:|---:|---:|
| `aes128Gcm` | 16 | 16 | 12 | 16 |
| `aes256Gcm` | 32 | 32 | 12 | 16 |
| `chacha20IetfPoly1305` | 32 | 32 | 12 | 16 |
| `xchacha20IetfPoly1305` | 32 | 32 | 24 | 16 |

这些只读参数继续由枚举提供，不能再作为用户可覆盖的节点字段存储。未知算法或未知 raw value 必须失败；不得静默降级、忽略算法或选择默认算法。该列表只描述本包能力，不代表任意 Shadowsocks 服务端都支持全部四种算法。

枚举不执行密码派生、不生成随机数、不维护 nonce。实际密钥长度、nonce 长度和加密帧检查仍属于 crypto / Wire 边界，不能因节点构造成功而删除。

### 5. 端点、密码和超时不变量

| 字段 | 构造成功后的契约 |
|---|---|
| `address` | IPv4 或 IPv6 的实际 `SocketAddress`，端口为 `1...65535`；拒绝 Unix socket 和端口 0 |
| `type` | 存在本包实现的明确协议 case |
| `cipher` | 存在本包实现的明确算法 case |
| `password` | UTF-8 表示非空，内容原样保存 |
| `timeoutMilliseconds` | `1...9_223_372_036_854`，可精确转换为正的 Int64 纳秒 |

节点地址必须继续保存实际地址族和 IPv6 scope。不得为了复用业务地址规范化而转成 `NetworkAddress` 后覆盖真实节点端点，也不能去掉 scope。IP 是否可达、是否自回环及是否被运行时访问策略允许，由应用和 Core 的对应策略判断，不通过一次模型构造来宣称已经验证。

密码不 trim、不做 Unicode 规范化、不按 cipher 的 keySize 截断或补齐；仅包含空格的非空密码也按原字节处理。空密码在本章作为配置错误拒绝，这是本产品的输入策略。错误消息和模型描述不包含密码或派生密钥；真实配置不写入文档或测试。

超时上限来自 `Int64.max / 1_000_000`。当前 NIO `TimeAmount.milliseconds` 对超范围转换采用饱和值，本模型选择提前拒绝，避免保存的超时与实际传入的时长不一致。TCP / UDP Wire 直接消费已验证的毫秒值，不再分别执行浮点秒乘 1000、取整和范围判断。

该超时表示连接节点时使用的期限参数，不是 DNS 超时、HTTP 请求总期限、隧道空闲超时或 UDP 响应期限的统称。UDP Wire 暴露同一配置值，也不代表无连接 UDP 具备与 TCP 相同的握手计时行为。

### 6. 标识、相等性与集合约束

`Identifiable.id` 表示节点身份；整个 `ProxyNode` 的 `==` 表示配置是否完全相同。两个值使用同一个 UUID 但地址、算法、密码或超时不同，应当不相等。

`Hashable` 与相等性共同覆盖 UUID、协议、NIO SocketAddress 的端点语义、算法、密码 UTF-8 字节和超时。密码必须按字节比较和哈希，不能直接依赖 Swift String 的规范等价比较：`"\u{00E9}"` 与 `"e\u{0301}"` 的 String 可以相等，但密码派生所用 UTF-8 字节不同。

不使用 `hashValue` 作为持久化节点 ID、秘密的摘要或稳定配置指纹。

节点集合约束仍由 Core 管理，不能放进不持有全表的单个节点构造器：

- 相同 UUID 按输入顺序使用最后一个成功装载的配置。
- 不同 UUID 使用相同实际 SocketAddress 时，按现有集合契约拒绝。
- 同 UUID 改变地址后，Core 更新旧地址到节点的反向映射和对应 Wire。
- 比较实际节点端点沿用 SocketAddress 身份，不用业务请求的 mapped IPv6 归一结果作为原始 socket 的替代物。
- 批量加载按顺序处理，不因模型重构而宣称增加事务回滚、端点互换重排或公共热更新能力。

### 7. 生命周期、引用与持久化

`ProxyNode` 不持有 TCP 加密流状态。每条代理 TCP 连接由 Core 创建独立 Wire，salt / nonce / 启动状态不能因节点 UUID 相同而复用；UDP 仍遵循 Wire 自己的独立数据报加密规则。

默认 `.proxy(UUID)` 在完整节点表装载之后校验；缺失则 Core 初始化失败。规则中的节点引用继续在实际选中该规则时检查，缺失抛出原始 `proxyNodeNotFound`，不回退 DIRECT。这些是配置集合和路由边界的契约，不是节点模型自身的存在性校验。

`restart` 为下一运行周期创建新的 Core；本章不引入跨运行周期共享 Wire、节点单例或额外配置 snapshot。

首版不为整个 `ProxyNode` 增加自动 Codable。协议/算法的 raw value 可以独立编码；应用存储负责 UUID、原始节点主机名、端口、凭据及超时字段，并在构造运行配置前解析出 `SocketAddress`。不能把含 scope 的实际端点仅序列化为普通 IP 字节而丢失作用域。

### 8. 错误与迁移

本地节点配置违反上述不变量时，构造入口抛出 `MagentError.invalidPolicy`。错误说明可以标明字段或原因，不能包含密码。DNS、密码派生和 crypto / Wire 的原始错误分别在其实际执行边界传播，不在节点 helper 内包装成另一种错误。

本次设计相对于当前实现的变化是：

1. `ProxyNode.init` 改为 throws，提前验证端点、非空密码和超时。
2. `timeout: TimeInterval` 改为 `timeoutMilliseconds: Int64`，默认值从 30 秒明确为 30_000 毫秒。
3. TCP / UDP Wire 删除重复的秒到毫秒转换，继续保留真正的加密初始化和运行错误处理。
4. 对包含密码的配置相等性和哈希实施字节语义。

历史秒值转换由应用迁移负责：拒绝非有限数及非正数；乘以 1000 后向上取整，再检查第 5 节上限并精确转为 Int64。这样延续当前 Wire 的毫秒取整规则，不能把原来的 `30` 直接解释为 30 毫秒。应用中的节点导入和存储转换必须显式处理构造失败，不能继续以 `compactMap` 静默丢掉坏配置后宣称完整加载成功。

### 9. 验收标准

| 编号 | 场景 | 必须验证的结果 |
|---|---|---|
| PN-01 | 合法 IPv4 / IPv6 节点 | 保留 UUID、实际地址、协议、算法、密码字节和超时 |
| PN-02 | Unix socket、端口 0 | 构造失败，不能延迟到业务拨号 |
| PN-03 | IPv6 scope、mapped IPv6 实际端点 | 保留真实端点信息，不用逻辑地址替换 |
| PN-04 | 超时 0、负数、1、30_000、上限及上限加 1 | 边界精确，无饱和或截断 |
| PN-05 | 旧配置 30 秒、正的小数秒、NaN、infinity | 正常转换与向上取整明确，非有限或溢出值拒绝 |
| PN-06 | 空密码、空格密码、Unicode 密码 | 空密码拒绝；其余原 UTF-8 字节不变 |
| PN-07 | 同 UUID 不同字段、规范等价但字节不同的密码 | 配置不相等；Set 不错误合并 |
| PN-08 | 四个 ProxyCipher | 每个尺寸均断言第 4 节的字面量，raw value 精确往返 |
| PN-09 | 未知协议和算法 raw value | 导入失败，无默认回退 |
| PN-10 | 重复 UUID、不同 UUID 重复端点、同 UUID 换端点 | Core 集合行为和反向映射正确 |
| PN-11 | 默认节点缺失与规则节点缺失 | 前者在全表装载后失败，后者在命中时失败；均不降级 DIRECT |
| PN-12 | 两条 TCP 连接及多个 UDP packet | Wire 状态按真实生命周期隔离 |
| PN-13 | 仅构造或比较节点 | 不执行 DNS、密码派生、加密初始化或网络 I/O |
| PN-14 | 非法配置错误及诊断 | 包含可定位字段，绝不包含密码或派生密钥 |

这些为待实现验收项。现有 `ProxyNodeTests` 主要证明 cipher 参数，不代表新增的节点构造和集合契约已经全部验收。

### 10. 相关文件

- [当前 ProxyNode / ProxyNodeType](../Sources/Model/ProxyNode.swift)
- [当前 ProxyCipher](../Sources/Model/ProxyCipher.swift)
- [当前节点及 cipher 测试](../Tests/Model/ProxyNodeTests.swift)
- [当前 Core 与节点集合](../Sources/Core/MagentCore.swift)
- [当前 Core 测试](../Tests/Core/MagentCoreTests.swift)
- [当前 TCP Wire](../Sources/Wire/Shadowsocks/ShadowsocksTCPWire.swift)
- [当前 UDP Wire](../Sources/Wire/Shadowsocks/ShadowsocksUDPWire.swift)

## ProxyRule

### 1. 定位与职责

`ProxyRule` 是一个不可变的、已经校验并规范化的单条路由规则，表达 **匹配条件、命中动作和显式优先级**。它不持有节点表，不执行路由遍历，不创建 Wire，也不解析 DNS。

模型负责把输入文本转换成可直接使用的匹配值，尤其是已经清零主机位的 CIDR 字节和前缀。Core 负责规则集合的去重、索引、优先级比较、默认决策和节点查找。

本章的关联枚举为 `MatchType`、`Decision`，以及模型内部保存有效结果的 `ProxyRule.Match`。它们放在本模型描述内，不作为独立模型章节。

### 2. 类型与构造入口

保留方便配置导入的 `matchType` / `matchValue` 构造参数；内部只保存一个经过校验的关联值枚举。公开的类型和文本视图由这个存储计算，不同时维护可以不一致的两份数据。

以下是接口草图，方法实现省略：

```swift
public struct ProxyRule: Sendable, Hashable {
    internal enum Match: Sendable, Hashable {
        case exactDomain(String)
        case domainSuffix(String)
        case domainKeyword(String)
        case ipCIDR(network: [UInt8], prefixLength: UInt8)
    }

    internal let match: Match
    public let decision: Decision
    public let order: Int

    public var matchType: MatchType {
        // 从 match 的分支计算。
    }

    public var matchValue: String {
        // 从规范化存储生成确定的配置文本。
    }

    public init(
        matchType: MatchType,
        matchValue: String,
        decision: Decision,
        order: Int
    ) throws {
        // 验证并保存一个有效的 Match，不查询节点表。
    }
}
```

`Match` 的 CIDR 网络字节数只能为 4 或 16，前缀范围由实际字节数确定。构造前先检查整数前缀，再转换为 UInt8；不能通过窄整数转换截断越界输入。

不提供接受任意 `Match` 的直接构造入口。Core 消费已经解析的匹配值，不再把 `matchValue` 重新解析成另一份 NetworkCIDR。

### 3. MatchType

`MatchType` 表示配置中的匹配类别。新设计只暴露当前地址路由实际支持的四种类别：

```swift
public enum MatchType: String, Codable, Sendable, Hashable, CaseIterable {
    case exactDomain = "EXACT-DOMAIN"
    case domainSuffix = "DOMAIN-SUFFIX"
    case domainKeyword = "DOMAIN-KEYWORD"
    case ipCIDR = "IP-CIDR"
}
```

raw value 按上述拼写精确导入。未知值必须失败，不当作普通域名或忽略。

移除当前 `urlRegex = "URL-REGEX"` 的“模型接受、Core 拒绝”状态。当前路由匹配入口收到的是 `NetworkAddress`，没有完整 URL，无法正确执行 URL 正则匹配；首版不暴露该 case。历史 URL 规则在应用迁移时明确报为不支持，不能静默跳过或改成域名关键字。

以后若支持 URL、端口或来源匹配，必须先明确输入和协议可见性，再扩展规则与缓存 key。不能仅添加枚举名称就宣称路由已支持。

### 4. Decision

`Decision` 是路由结果值，既用于 `ProxyRule.decision`，也用于 `MagentConfig.defaultDecision`。因此仍为包的顶层公共枚举；写在本模型章节不意味着改成只能通过 ProxyRule 引用的嵌套类型。

```swift
public enum Decision: Sendable, Hashable {
    case direct
    case proxy(UUID)
}
```

`.direct` 表示直连业务目标，`.proxy(UUID)` 表示按稳定 UUID 选择节点。不使用可空 UUID、特殊零 UUID、假节点或节点地址字符串表达 DIRECT。

规则构造时不能判断 UUID 是否存在。Core 在完整节点装载后检查默认代理引用，在规则实际命中时检查该规则的引用；缺失节点抛出原始错误，不把 PROXY 变为 DIRECT。无规则命中才使用 defaultDecision；某规则命中后执行失败不是“未命中”。

首版不添加没有执行路径的 REJECT、自动选择、回退链或代理分组 case。节点不可用、没有规则和明确直连是不同状态，不能用同一个空值合并。

`Hashable` 使用 case 和 UUID，不能把节点当前配置或 Wire 实例放入决策值。首版不为关联值枚举增加自动 Codable；应用持久化若使用 `direct` / `proxy` 文本和节点关联，必须显式组合并校验，不能依赖 Swift 自动合成的序列化布局。

### 5. 域名精确规则与后缀规则

这两种规则使用与 NetworkAddress 相同的 ASCII 标签结构约束：小写、每标签 `1...63` 字节、非空标签、总长上限 253 字节，允许输入单个末尾根点，保存时去掉该根点。

规则文本不 trim 首尾空白，不删除前导点，不折叠多个根点，不接受 `*`、URL 或带端口的 authority。`.example.com` 不是隐式后缀语法；应显式选择 `.domainSuffix` 并传入 `example.com`。

共用的是纯主机名标签校验，不是通过构造一个端口为 0 的假目标来校验规则。可以在现有地址/规则 owner 中共享被多个生产路径使用的纯语法方法；不要新增 Validator 包装文件。

两种规则的语义分别为：

| 规则 | 匹配 | 不匹配 |
|---|---|---|
| exactDomain `example.com` | 域名目标 `example.com`、`EXAMPLE.COM.` | `api.example.com`、数值 IP 目标 |
| domainSuffix `example.com` | `example.com`、`api.example.com`、更深子域名 | `notexample.com`、`example.com.evil`、数值 IP 目标 |

后缀比较必须以 DNS 标签为边界，不能使用没有边界检查的普通字符串 endsWith。

exactDomain 若是 NetworkAddress 会识别为 IP 或拒绝的纯数值歧义表达，应在规则构造时拒绝，并提示使用 IP-CIDR；不能产生一条永远不参与 IP 匹配的伪域名 IP 规则。domainSuffix 表达的是标签后缀，可以包含数字标签，例如 `0.1` 可以匹配域名 `a.0.1`；它始终只作用于域名目标，不把某个 IPv4 地址按点拆成域名匹配。

目标域名的匹配视图由 Core 去掉一个根点，目标自身仍保留根点供解析和 Wire 转发；规则构造不能修改目标对象。

### 6. 域名关键字规则

`domainKeyword` 是对规范化域名匹配名称的 ASCII 字面子串匹配，不是完整主机名、glob 或正则表达式。

- 输入长度为 `1...253` 字节，转为 ASCII 小写。
- 允许字母、数字、点和连字符；这些字符可以位于关键字边缘，因为关键字可能是名称片段。
- 拒绝空值、空白、控制字符、Unicode、URL 分隔符及正则/通配符符号；不 trim 输入。
- 不要求关键字自身满足完整主机名标签结构，不能直接复用 exactDomain 的全部验证。
- 只作用于域名目标，不执行 PTR、DNS 或从某个 IP 猜测域名。

例如关键字 `api` 可以匹配 `api.example.com` 和 `myapiv2.example.com`；关键字 `api.` 可以匹配前者而不匹配后者。此匹配不具有 domainSuffix 的标签边界保证，应用需要标签边界时应选择后缀规则。

### 7. CIDR 规则

CIDR 构造仅接受严格数值 IP 和可选的一个 `/prefix`，不访问 DNS。省略前缀时 IPv4 使用 `/32`，IPv6 使用 `/128`；显式前缀只接受非空十进制数字，禁止符号、内部空白、额外斜线和越界值。前缀的十进制前导零可接受，输出时去掉。

普通 IP 解析、歧义数字拒绝和 scope 文本拒绝与 NetworkAddress 的数值语法一致，但 CIDR 解析必须保留原始 IPv6 位宽，先处理前缀与 mapped IPv6 的关系，再生成规范化网络，不能先丢掉 96 位再解释原前缀。

| 输入 | 规范化匹配值 |
|---|---|
| `192.0.2.129/24` | `192.0.2.0/24` |
| `192.0.2.129` | `192.0.2.129/32` |
| `192.0.2.129/0` | `0.0.0.0/0` |
| `2001:db8::1234/64` | `2001:db8::/64` |
| `2001:db8::1` | `2001:db8::1/128` |
| `::ffff:192.0.2.129/120` | `192.0.2.0/24` |
| `::ffff:192.0.2.129/96` | `0.0.0.0/0` |
| `::ffff:192.0.2.129` | `192.0.2.129/32` |

原地址是 mapped IPv6 时，仅接受 `/96.../128`，转换为 IPv4 后将前缀减 96。对 mapped 字面量指定小于 96 的前缀会跨出映射区间，本章明确拒绝，不能简单减法、截断或悄悄把整个范围当作 IPv4。

原生 IPv6 范围保留 IPv6。规则匹配按规范化后的地址族区分：IPv4 目标只匹配 IPv4 CIDR，原生 IPv6 目标只匹配 IPv6 CIDR；`::/0` 不因为包含某些映射字节表示就匹配已经归为 IPv4 的目标。

网络存储在构造时清零所有主机位，保存 `[UInt8]` 与前缀。Core 做集合索引和包含判断时直接读取这些值，不重复解析文本、重复清零主机位或建立另一份等价的 NetworkCIDR 包装。

### 8. order、匹配身份与相等性

`order` 是显式优先级，数值越小越优先。允许完整 Int 范围，包括负数；比较时使用关系运算，不以相减方式判断先后，避免 Int.min / Int.max 溢出。

规则值相等性与集合覆盖身份必须分开：

- `ProxyRule ==` / Hashable 比较规范化 `Match`、`Decision` 和 `order`。不同动作或优先级是不同配置值。
- Core 的覆盖 key 只使用规范化 `Match`，不包含 decision / order；等价 CIDR 和域名大小写/根点变体得到相同 key。
- 同一覆盖 key 的最后一条配置生效，同时使用最后一条在输入数组中的位置参加后续比较。
- 规则不增加运行时随机 UUID，不能用 Hashable 的 hashValue 作为持久化规则 ID。

应用自己的数据库主键、策略关联和 UI 行标识继续由应用管理，不进入包内路由规则。

### 9. Core 的选择顺序

Core 对所有实际命中的候选规则按同一顺序选择：

1. `order` 较小。
2. 同 order 下更具体。
3. 仍相同则采用去重后保留下来的较早输入位置。

具体性使用明确比较项，不依赖魔法分数或字典遍历顺序：

| 同 order 的候选 | 更具体的规则 |
|---|---|
| 域名精确、域名后缀、域名关键字 | 精确优先于后缀，后缀优先于关键字 |
| 两个域名后缀 | 标签数更多者 |
| 两个域名关键字 | 规范化 UTF-8 字节数更多者 |
| 两个同族 CIDR | 前缀更长者 |

同一目标不会同时进入域名与 IP 匹配分支，因此无需为 CIDR 与域名规则设置跨类别的分数高低。精确规则的同值重复已经在去重阶段处理。

一个更小 order 的后缀或关键字必须胜过更大 order 的精确域名；命中 exact 索引后不能立即返回。规则为空或全部未命中时才应用 defaultDecision。

规则不读取端口，因此首版路由缓存 key 可以忽略端口。未来增加端口或其他匹配维度时，必须同步升级 key，不能只修改规则枚举。缓存保存 Decision，不保存某条 TCP Wire 的加密状态。

### 10. 错误、导入和迁移

规则结构或匹配文本不符合本章时，由规则构造入口抛出 `MagentError.invalidPolicy`。不要先捕获地址 helper 的错误再重命名；共享纯语法检查应提供合适的内部解析结果，由实际拥有规则输入的边界产生自己的错误。

构造时不检查节点存在性，不执行 DNS，不创建正则对象或 Wire。关联的 ProxyNode、实际目标、运行时路由错误在对应 owner 原样传播。

首版不为整个 ProxyRule 增加自动 Codable。应用导入显式解析 MatchType、Decision、order 和匹配文本，再调用唯一构造入口；无效 raw value、PROXY 动作缺少必填 UUID 和不支持的 URL-REGEX 必须报告，不能静默忽略。合法 UUID 对应的节点是否存在，仍按第 4 节在 Core 的对应边界检查。若将来需要模型 Codable，解码必须回到同一验证入口，不依赖自动合成内部 Match 的格式。

相对于当前实现，迁移包括：

1. 将字符串匹配字段改为规范化 Match 存储，保留只读的 matchType / matchValue 视图。
2. 将 CIDR 的解析、主机位清零和规范化身份收归规则模型；Core 保留匹配和索引。
3. 移除 MatchType.urlRegex 及 Core 对该“已构造但不可执行规则”的延迟拒绝路径。
4. 统一域名规则的严格输入策略，不再用 trim / 去任意首尾点修复非法值。
5. Core 用明确的具体性比较代替跨类别魔法分数，并保留既定的 order、覆盖和稳定决胜顺序。
6. 更新应用导入、持久化转换和测试；旧规则的失效不能通过少装几条规则掩盖。

先前的 NetworkAddress / HttpProtocol 章节继续适用。本章不要求把关联枚举改成嵌套公共 API，也不默认合并其现有文件。

### 11. 验收标准

| 编号 | 场景 | 必须验证的结果 |
|---|---|---|
| PR-01 | 四个 MatchType 与 raw value | 精确导入和往返，未知类型及 URL-REGEX 明确失败 |
| PR-02 | 域名大小写、单根点、空白、前导点和多根点 | 大小写/单根点规范化；非法修复式输入拒绝 |
| PR-03 | exact 与 suffix 的边界 | 第 5 节匹配/不匹配向量精确成立 |
| PR-04 | exact 数值文本、suffix 数字标签、数值目标 | exact 伪 IP 规则拒绝，合法标签后缀可用，IP 不走域名分支 |
| PR-05 | 关键字 api、api.、空值、非法字符及 253/254 长度 | 子串语义明确，不套用完整域名标签检查 |
| PR-06 | IPv4 / IPv6 /0、主机前缀和缺省前缀 | 精确清零主机位，格式和存储一致 |
| PR-07 | prefix 越界、负号、正号、空前缀、多个斜线、scope、域名 | 在构造时失败，不等待 Core 再解析 |
| PR-08 | mapped IPv6 /96、/120、/128、缺省和 /95 | 合法范围对应 IPv4 前缀，小于 96 明确拒绝 |
| PR-09 | 等价 CIDR、域名变体、不同 Decision / order | 覆盖 key 与完整规则相等性各自正确 |
| PR-10 | 重复规则的最后配置与输入位置 | 使用最后值及其位置，不能保留第一次的决胜位置 |
| PR-11 | 不同 order 的 exact、suffix、keyword | order 优先，不能按索引命中顺序提前返回 |
| PR-12 | 同 order 的类型、后缀深度、关键字长度、CIDR 长度 | 精确执行第 9 节比较，不依赖字典顺序 |
| PR-13 | Int.min / Int.max 以及同优先级同具体性 | 无比较溢出，稳定采用较早保留位置 |
| PR-14 | 无规则、无匹配、命中缺失节点 | 前两者使用默认决策；后者失败，不回退直连 |
| PR-15 | 相同 host 不同端口、域名根点、mapped 数值目标 | 与 NetworkAddress 及路由缓存语义一致 |
| PR-16 | direct / proxy(UUID) | 动作与 UUID 身份明确，没有假节点和特殊零值 |
| PR-17 | Core 消费规则 | 直接使用解析结果，不再次解析 CIDR 或丢弃模型验证结果 |
| PR-18 | 单纯规则构造、导入和比较 | 无 DNS、节点查找、网络 I/O、Wire 创建或正则编译 |

单个模型验收使用字面量期望的字符串、网络字节、前缀、动作和优先级；集合用例必须通过 Core 的真实选择路径验证。手工检查排序不变量不能代替未来的 Core 回归测试。

### 12. 相关文件与验证边界

- [当前 ProxyRule](../Sources/Model/ProxyRule.swift)
- [当前 MatchType](../Sources/Model/MatchType.swift)
- [当前 Decision](../Sources/Model/Decision.swift)
- [当前 Core 与 Router](../Sources/Core/MagentCore.swift)
- [当前 Core 测试](../Tests/Core/MagentCoreTests.swift)
- [既有访问控制设计](MagentAccessControl_Design.md)

旧访问控制文档包含 trim、URL 正则延迟拒绝、重复 CIDR 解析和数值 specificity 等当前行为；本章明确列出的变化是新模型设计目标，不能据此宣称当前源码已经更新。

实现两个模型后，应完成节点/cipher、规则/Core 的定向验收，并按项目规定执行 build、strict-concurrency build、ConnectionTests、全包测试、实际修改 Swift 文件的 strict lint 和 `git diff --check`。应用节点导入、秒到毫秒迁移和规则持久化转换需要独立验证；文档阶段只检查结构、链接、示例不变量和修改范围。
