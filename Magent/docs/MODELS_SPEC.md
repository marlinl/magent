---
desc: "NetworkAddress、HttpProtocol、ProxyNode、ProxyRule 及关联枚举的模型契约与验收标准。"
version: "0.4.1"
updated_at: "2026-09-23"
status: "草案"
notes: "NetworkAddress 采用 NIO IP 存储与按需系统域名解析；调用方迁移和连接层 DNS 策略单独处理。"
---

# Magent 模型规范

关联枚举在所属模型章节中说明。模型 API 及其实际使用的序列化格式可以变更；不保留绕过校验的历史构造路径。

## NetworkAddress

本章规定以未解析域名和 NIO `SocketAddress` 表示逻辑地址，并通过 `socketAddress` 按需取得实际端点。模型重写与调用方迁移分开进行；连接层的异步解析和配置 DNS 策略不因模型重写而自动改变。

### 1. 定位与职责

模型接口以现有生产调用需求为依据，不为假设场景增加方法或协议符合性。

`NetworkAddress` 是不可变的逻辑目标地址：**未解析的主机名与端口，或数值 IP 端点**。它用于代理请求目标、路由和协议地址字段。实际的 UDP 发送方、接收方或代理节点端点使用 `SocketAddress` 表示。

构造成功表示输入和地址身份满足模型契约，构造过程不执行 DNS。它不证明域名存在、端点可达或访问已获授权。

模型负责主机名校验、数值输入策略、IPv4 映射 IPv6 地址的规范化、端口范围、相等性和哈希。消费方显式读取 `socketAddress` 时，IP 直接返回存储的套接字，域名委托 SwiftNIO 进行系统名称解析。IP 文本解析和数值文本格式化也交给 SwiftNIO；模型不另行维护 IPv4/IPv6 文本到字节的解析器或 IPv6 压缩算法。协议二进制 IP 字段的读取和转换属于协议层。

协议解析器负责消息边界、ATYP、字段长度和命令语义。Core 负责规则匹配和路由选择。连接流程负责异步解析、套接字选择、超时和 Channel 生命周期。端口 `0` 是否可用，由具体操作入口决定。

### 2. 类型、构造入口与地址输出

公开类型继续使用 `struct`。调用方统一通过 `init(host:port:)` 输入文本主机名或 IP；需要 IP 端点时，读取非可选、可抛错的 `socketAddress`。内部枚举命名为 `Address`，字段命名为 `address`，只有域名及其端口、已包含端口的 IP `SocketAddress` 两个分支。不得在套接字地址之外重复保存端口或并行维护一份 IP 字节数组。

本草图保留 `struct`，以保证调用方经过文本构造入口校验。公开枚举的分支也会公开，调用方能够绕过初始化器直接构造；若把 `NetworkAddress` 改为公开枚举，必须同时重新确定输入校验、规范化及相等性的保证，不能继续宣称所有值都已通过受控构造。`self` 表示当前的 `NetworkAddress` 值，不是另一个存储字段。

以下是接口草图，不是可直接编译的完整实现：

```swift
public struct NetworkAddress: Sendable, Hashable {
    internal enum Address: Sendable, Hashable {
        case domain(String, port: UInt16)
        case ip(SocketAddress)
    }

    internal let address: Address

    public init(host: String, port: UInt16) throws {
        // 这里只按文本特征选择分支，不验证 IPv4 是否完整、范围是否有效。
        let isIPv4Candidate = !host.contains(":") && host.lowercased()
            .split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { part in
                if part.hasPrefix("0x") {
                    return part.dropFirst(2).utf8.allSatisfy {
                        (48...57).contains($0) || (97...102).contains($0)
                    }
                }
                return part.utf8.allSatisfy { (48...57).contains($0) }
            }

        switch host {
        case let text where isIPv4Candidate:
            self.address = .ip(try Self.parseIPv4Text(text, port: port))
        case let text where text.contains(":"):
            self.address = .ip(try Self.parseIPv6Text(text, port: port))
        default:
            // 直接在此按第 5 节校验域名；不另设域名校验方法。
            // 校验失败在此抛错；成功后转为小写并保留合法根点。
            self.address = .domain(host.lowercased(), port: port)
        }
    }

    public var host: String {
        // 返回域名或 NIO 生成的数值 IP 文本，不包含主机与端口部分的组合语法。
    }

    public var port: UInt16 {
        // 从存储中读取唯一且已验证的端口。
    }

    public var socketAddress: SocketAddress {
        get throws {
            // IP 直接返回已存储的端点；域名委托 NIO 同步解析，失败时传播原始错误。
        }
    }

    private static func parseIPv4Text(_ text: String, port: UInt16) throws -> SocketAddress {
        // 在此完成 IPv4 校验和 NIO 解析；识别失败或输入非法时直接抛错。
    }

    private static func parseIPv6Text(_ text: String, port: UInt16) throws -> SocketAddress {
        // 在此完成 IPv6 校验和 NIO 解析；识别失败或输入非法时直接抛错。
        // 成功后只将映射 IPv6 规范化为 IPv4。
    }
}
```

构造和输出遵循以下规则：

1. 公开文本入口只接受独立主机名或 IP 文本。HTTP 地址的主机与端口部分、URL 语法、方括号和内嵌端口由调用方拆分。
2. `init` 使用 `switch` 按文本特征分派：IPv4 候选只调用 `parseIPv4Text`，IPv6 候选只调用 `parseIPv6Text`，`default` 直接校验域名并保存 `.domain`。两个私有方法负责各自的完整校验、NIO 数值解析及失败报错，成功返回非可选 `SocketAddress`；构造过程不执行 DNS。
3. `socketAddress` 是按需转换接口，调用形式为 `try target.socketAddress`。IP 直接返回内部保存的规范化 `SocketAddress`，不重新解析文本；域名调用 `SocketAddress.makeAddressResolvingHost(_:port:)`，返回 NIO 选出的一个实际端点，仅在解析失败时抛出原始错误。转换不修改模型、不缓存结果、不改变域名身份。结果不返回 `nil`，也不使用默认端点或强制解包掩盖失败。域名分支会阻塞调用线程，不得在 NIO EventLoop 上执行。
4. 不提供接受 `SocketAddress`、原始 IP 字节或任意 `Address` 的构造入口，也不提供未经校验、可写或仅供测试的构造路径。
5. 不通过 `allowZeroPort`、`forBinding`、`forRouting` 或 `strict` 等构造开关改变模型含义。

当前调用场景与本契约的对应关系如下；表中输入指业务或协议边界的输入，不把旧代码的中间包装当作新增接口需求：

| 场景 | 边界输入 | 本契约中的处理 |
|---|---|---|
| HTTP CONNECT、绝对 URI、Host | 文本主机名和端口 | HTTP 层拆分后调用 `init(host:port:)` |
| SOCKS4a / SOCKS5 域名字段 | 协议中的名称字节和端口 | 协议层解码名称，再调用文本构造入口 |
| SOCKS4 / SOCKS5 的 IP 字段、Shadowsocks 二进制地址字段 | 4 或 16 字节的 IP 和端口 | 协议层借助 NIO 生成数值 IP 文本，再调用文本构造入口 |
| 配置 | 文本主机名和端口 | 调用同一个文本构造入口 |
| TCP / UDP 数值目标直连 | 已构造的 `NetworkAddress` | 按需读取 `try target.socketAddress`，直接连接或发送 |
| 域名按需转换 | 已构造的 `NetworkAddress` | 在允许阻塞的调用边界读取 `try target.socketAddress`，通过 NIO 系统解析取得端点 |
| TCP / UDP 域名目标直连 | 已构造的 `NetworkAddress` | EventLoop 流程按 `host`、`port` 异步解析；不能直接执行阻塞的域名转换属性 |
| UDP 来源比较、直连回包来源、绑定地址回复 | NIO 提供的实际 `SocketAddress` | 在连接或协议层直接比较、读取和编码；不先包装成逻辑目标 |
| 监听器、代理节点和 DNS 服务器端点 | 实际 `SocketAddress` | 直接使用端点 |

SOCKS 的 IP 输入并非天然就是字符串。采用单一文本构造入口后，协议层只把字段中可读的 4 或 16 字节交给 `SocketAddress(packedIPAddress:port:)`，读取其数值 `ipAddress` 文本，再构造逻辑地址。此路径包含一次二进制到文本转换和模型内的文本解析；本契约明确接受这一转换，不以尚未验证的性能收益预留第二套构造接口。转换不执行 DNS，也不保留这个临时套接字作为模型的另一份状态。

### 3. 存储不变量与文本视图

| 存储 | 不变量 |
|---|---|
| `domain` | 符合第 5 节的合法 ASCII 主机名，转为小写并保留一个合法的显式根点；端口为 `UInt16` |
| `ip` | IPv4 或 IPv6 `SocketAddress`，端口在 `0...65535` 内；IPv4 映射 IPv6 地址存为 IPv4 |
| 逻辑 IPv6 | 由无作用域的数值文本构造，作用域和流信息均为零 |

逻辑 IP 身份由地址族、IP 字节和端口组成。模型不导入实际传输套接字，因此不承担实际套接字的作用域校验、流信息清理或主机名元数据转换。输入文本中的作用域后缀按第 4 节拒绝；实际传输端点及其元数据继续由连接层保留。

`host` 返回规范化域名或 NIO 的数值 `ipAddress` 文本。不得使用用于诊断的 `SocketAddress.description`。结果不包含端口、方括号或作用域后缀，也不使用空字符串兜底错误。等价 IPv6 的文本拼写不作为身份键；本契约不保证不同依赖版本生成完全相同的 IPv6 文本，也不为此添加自定义格式化器。

公开 `port` 视图精确读取已验证的端口，不能用 `0` 替代缺失的套接字端口。IP 的 `socketAddress`、`host` 和 `port` 来自同一份 `address` 存储；返回的值副本被调用方修改时，不影响模型。协议层转换 IP 字节时不能假设 `Data` 切片的 `startIndex` 为零，应使用字段的实际切片或 `ByteBuffer` 可读视图。

### 4. 数值输入策略与规范化

`init` 只按文本特征选择 IPv4、IPv6 或域名分支。IPv4、IPv6 的完整识别、校验、解析和报错分别放在 `parseIPv4Text` 和 `parseIPv6Text` 两个私有静态方法中，使 `init` 能在 `address` 赋值前调用。两个方法均返回非可选 `SocketAddress`，复用 SwiftNIO 完成实际 IP 语法解析和端点构造，不手写 IP 字节解析或格式化算法。

| `init` 的分支条件 | 校验、解析和错误处理 |
|---|---|
| 不含冒号，且符合本节数字、点和十六进制分段特征 | 调用 `parseIPv4Text`；方法内拒绝禁止输入、校验严格 IPv4 词法规则并通过 NIO 构造 IPv4 端点，失败直接抛错。 |
| 含冒号 | 调用 `parseIPv6Text`；方法内拒绝禁止输入、检查内嵌 IPv4 尾段的词法限制并通过 NIO 构造 IPv6 端点，失败直接抛错；成功后只将 IPv4 映射 IPv6 规范化为 IPv4。 |
| 其他文本 | 进入 `default`，在 `init` 内直接按第 5 节校验域名，成功后保存 `.domain`，失败在该分支抛错。 |

候选分支不代表 IP 已经合法。`init` 不重复 IP 校验、不依次试调用两个解析方法，也不捕获解析错误后回退为域名。解析方法不以 `nil` 表示失败。例如 `256.0.0.1` 在 IPv4 方法中失败，`2001:::1` 在 IPv6 方法中失败；`0xfeed.example` 直接进入 `default` 的域名校验。模型策略错误和 NIO 解析错误按第 10 节传播。

IPv4 文本必须恰好包含四个十进制分段，每段为 `0...255`；除单个 `0` 外，不允许前导零。IPv6 内嵌的 IPv4 尾部遵循相同词法限制。文本传入数值解析前，拒绝空白、控制字符、NUL、方括号和作用域后缀。

只由数字和点组成的文本，或每个分段均为十进制数字或 `0x` 形式十六进制数的文本，必须满足严格 IPv4 语法。空分段和没有数值部分的十六进制文本也必须拒绝。不得通过去除首尾空白、删除根点或补齐缺失分段来接受这些输入。包含普通标签的名称（例如 `0xfeed.example`）继续按主机名校验。

| 输入 | 必须得到的结果 |
|---|---|
| `192.0.2.1` | IPv4 `SocketAddress`，使用传入的端口 |
| `::ffff:192.0.2.1` | 与 `192.0.2.1` 相同的逻辑 IPv4 身份，读取输出也为 IPv4 |
| `2001:db8::1` | 原生 IPv6 |
| `::192.0.2.1`、`64:ff9b::192.0.2.1` | 保持 IPv6 |
| `127.1`、`2130706433`、`127.000.0.1`、`0177.0.0.1` | 拒绝 |
| `0x7f000001`、`0X7F.0.0.1`、`0x` | 拒绝 |
| `256.0.0.1`、`1.2.3.4.5`、`192..2.1`、`192.0.2.1.` | 拒绝 |
| `[::1]`、`fe80::1%en0`、内嵌 NUL 的 IPv6 | 拒绝 |
| `::ffff:192.000.2.1` | 拒绝不符合严格语法的 IPv4 尾部 |
| `0xfeed.example` | 合法域名 |

映射规范化只适用于前 80 位为零、随后 16 位为 `0xffff` 的地址，在存储前执行一次。路由、相等性和 Wire 消费同一个逻辑结果。原始 `SocketAddress` 本身不会建立这种逻辑等价关系。

### 5. 主机名契约

未进入 IP 候选分支的文本，由 `init(host:port:)` 的 `default` 分支直接执行本节的域名校验并在失败时抛错；不新增 `parseDomain`、`validateDomain` 或通用主机名分发方法。模型接受 ASCII 主机名。需要 Unicode 转换和完整 IDNA 校验时，由导入层或协议层负责，使用版本明确且有测试向量的实现。

| 项目 | 规则 |
|---|---|
| 空名称 | 拒绝 |
| 字符 | ASCII 字母、数字、连字符和分隔标签的点 |
| 大小写 | 转为 ASCII 小写 |
| 标签长度 | `1...63` 字节 |
| 总长度 | 去掉一个合法的末尾根点后为 `1...253` 字节 |
| 连字符 | 不能位于标签开头或结尾 |
| 根点 | 允许并保留一个末尾根点 |
| 单标签 | 允许 `localhost` 等普通合法名称；数值歧义仍按第 4 节处理 |
| 空白、控制字符、NUL、原始 Unicode | 拒绝，不去除首尾空白或截断 |
| 空标签、前导点、连续点、多个根点 | 拒绝 |
| `_`、`/`、`\`、`@`、`:`、`[`、`]`、`%` | 拒绝 |

含根点的合法名称可以达到 254 字节。协议中的地址长度字段不能代替这些主机名限制。字母、数字、连字符（LDH）检查及 `xn--` 前缀不证明 A-label 完整合法；通过本模型校验，不代表已经满足 SOCKS5 规范中更严格的有效 A-label 要求。

### 6. 端口与操作语义

模型公开的端口使用 `UInt16`。从配置整数或协议字段转换时，必须精确转换。负数、溢出和非整数输入必须失败，不允许回绕、截断或替换为默认值。

| 使用场景 | 零端口策略 |
|---|---|
| 模型构造 | 接受 `0` |
| CONNECT 或 UDP 数据目标 | 操作入口拒绝 `0` |
| 临时套接字绑定 | 绑定策略可以允许 `0` |
| ASSOCIATE 来源提示或协议响应 | 遵循对应字段语义 |
| 规则匹配和 Wire 编码 | 消费已经确立的操作契约 |

模型允许 `0` 不会隐式改变监听器的产品策略。协议解析得到的端口在构造 NIO 套接字前必须精确转换；模型不能依赖其他 API 内部的窄整数转换来完成端口校验。

### 7. 相等性与哈希

相等性和哈希使用同一个规范化身份。域名身份是存储的名称和端口。IP 身份是规范化套接字的地址族、IP 字节和端口；模型仅通过文本构造，不引入实际传输端点的作用域、流信息或主机名元数据。

| 比较值（未另行说明时端口相同） | 相等性 |
|---|---|
| `API.Example.COM` 与 `api.example.com` | 相等 |
| 同一 IP 的不同文本形式 | 相等 |
| IPv4 与其映射 IPv6 形式 | 构造规范化后相等 |
| HTTP IP 文本与协议二进制字段转换得到的等价 IP 文本 | 构造结果相等 |
| 相同主机、不同端口 | 不相等 |
| `example.com` 与 `example.com.` | 不相等 |
| 域名与其当前解析得到的 IP | 不相等；比较不执行 DNS |

存储中的规范化套接字可以复用 NIO 的相等性和哈希。不得把未经规范化的传输套接字当作已经满足模型契约的值来比较或哈希。不能为了方便路由缓存而从模型身份中删除端口或根点信息。`hashValue` 不是持久化标识。

### 8. 路由、缓存与转发

处理顺序如下：

```text
协议字段 / 配置
              ↓
构造逻辑地址，不执行 DNS
              ↓
检查命令和目标端口策略
              ↓
使用逻辑地址匹配路由规则
              ↓
IP 直连：按需读取 try target.socketAddress，直接使用返回值
域名直连：用 host / port 异步解析，直接使用结果
代理转发：编码逻辑目标，发送到代理节点的 SocketAddress
```

域名规则使用域名，CIDR 规则使用存储套接字表示的数值 IP。地址分类不能触发 DNS；规则匹配或代理编码前，不能用已解析 IP 替换域名。

Core 负责匹配视图和路由缓存键。匹配名称可以去掉一个根点。当前规则不匹配端口，因此路由缓存键可以省略端口，但必须区分域名、IPv4 和 IPv6。增加端口规则时必须同步修改缓存键。DNS 缓存和实际端点缓存各自定义键，不能直接复用路由缓存键。

Wire 保留域名的显式根点，接收与路由使用的相同逻辑目标。模型不提供 `normalized()` 或 `hostForMatching`；消费方不再修补地址。TCP 启动后的负载不重复解析目标。每个 UDP 数据报仍携带目标，需要逐个进行路由和协议地址处理。

### 9. SocketAddress、UDP 与 DNS 的职责归属

`SocketAddress` 表示实际端点，可以从数值文本或二进制 IP 构造，无需解析域名。`socketAddress` 对域名委托其 `makeAddressResolvingHost` 辅助方法执行同步系统名称解析。NIO 负责实际解析和端点选择，模型不实现 DNS 查询或管理解析缓存。每次显式转换均委托 NIO，系统解析器是否使用缓存由系统决定。

域名转换会阻塞当前线程，不得在 NIO EventLoop 上调用；包装成已完成的 Future 或仅添加 `async` 标记也不会消除阻塞。连接层在 EventLoop 内仍使用适合其生命周期的异步解析流程。模型不为转换创建线程、Task、EventLoopGroup 或解析器实例。

| UDP 路径 | 目标处理 | 本地目标 DNS 解析 |
|---|---|---|
| 数值 IP 直连 | 读取 `try target.socketAddress`，直接使用规范化 IP 套接字 | 无 |
| 域名直连 | 保留逻辑域名，EventLoop 内异步解析后发送到结果套接字；不直接执行阻塞的域名转换 | 需要 |
| 域名或 IP 经代理转发 | 编码原始逻辑目标，发送到代理节点的实际套接字 | 不在本地解析业务目标 |
| 回复本地 UDP 客户端 | 使用记录的原始客户端套接字 | 无 |

`socketAddress` 的域名分支使用系统名称解析，不读取 Magent 的 DNS 服务器配置。所属连接或 Core 连接流程仍负责自己的异步解析器、服务器策略、超时、缓存策略和可用地址族。将连接层现有的显式 A/AAAA 查询替换为系统解析，须在调用方迁移时明确配置语义和阻塞工作的执行边界。

`socketAddress` 的非可选返回值只保证成功时得到一个实际端点，不保证任意域名都能解析成功。返回值是本次系统解析选出的端点；原模型继续保留域名及端口，用于规则匹配、代理编码和相等性。

监听器、代理节点端点、DNS 服务器端点、UDP 数据报封装及记录的后端回复端点直接使用 `SocketAddress`。目标配置契约中的监听器也使用 `SocketAddress`；应用必须先解析监听主机名，再提供实际端点。

原始传输端点保留地址族、IPv6 作用域及回复路径信息，不得被规范化逻辑地址覆盖。如果 ASSOCIATE 来源提示或协议校验依赖原始 ATYP，解析器必须在逻辑目标之外单独保留它。依赖作用域而无法由本逻辑模型表达的目标，由操作入口拒绝。

UDP 来源比较及本地回复编码直接处理实际端点，不通过构造 `NetworkAddress` 复用逻辑目标规则。若来源判断需要比较 IPv4 与其映射 IPv6 形式，连接层明确处理该比较语义，同时保存原始端点用于回包；不能假设 NIO 的原始套接字相等性已经完成映射归一。

### 10. 错误与校验边界

违反模型策略时抛出 `MagentError.invalidAddress`，包括主机名语法、数值歧义和文本中的禁止作用域。合法域名访问 `socketAddress` 时执行解析，不因地址种类而报错；解析失败时传播 NIO 原始错误。端口类型或范围错误在调用方精确转换为 `UInt16` 时失败。模型内的 NIO 数值文本构造错误和协议层的 NIO 二进制 IP 构造错误也按原始类型传播；辅助方法不得仅为包装或改名而捕获这些错误。

最上层负责该流程的协议或运行时边界统一分类错误，决定回复、丢包、日志或关闭动作。它必须同时识别适用的 NIO 地址错误和模型策略错误；失败不能转换为空主机名、零端口或未指定端点。

| 责任方 | 必须完成的工作 |
|---|---|
| 协议解析器 | 消息边界、ATYP、字段长度、命令语义、允许的字段形式及二进制 IP 到数值文本的转换 |
| SwiftNIO | 数值文本解析、二进制 IP 构造、IP 文本格式化和系统名称解析 |
| NetworkAddress | 文本输入策略、映射地址身份、受控构造和按需端点转换 |
| 操作入口 | 零端口策略和目标约束 |
| Core / 连接流程 | 规则匹配、路由选择、异步解析和端点选择 |
| Wire | 协议地址标签和编码限制；复用已经确立的 IP 存储 |

文本构造器支持 IPv6，不代表每种协议的 Domain 字段都允许 IPv6 文本。协议特有的限制仍由该字段的解析器执行。SOCKS 端口辅助方法属于协议代码，不属于地址模型；读取失败不能返回看似合法的端口 `0`。

### 11. 采用决定与实现边界

模型采用本章的存储和按需转换契约。调用方、测试引用及应用集成单独迁移；模型实现不代表连接层已经改用系统解析或完成全部验收。

在现有 `Sources/Model/NetworkAddress.swift` 中替换地址表示。移除手写 IP 字节解析器和格式化器、历史构造路径、补救式规范化及模型持有的 DNS 客户端或缓存。私有辅助方法仅保留 `parseIPv4Text`、`parseIPv6Text`，域名校验直接写在 `init` 中。域名显式转换直接委托 NIO 系统解析。不保留兼容路径，也不增加独立校验器、规范化器、工厂、转发包装或测试专用层。

调用方迁移统一采用文本构造入口：HTTP 直接传入拆分的主机名和端口，二进制协议字段由所属解析器借助 NIO 转成数值文本。IP 直连读取 `try target.socketAddress`，域名直连由连接流程异步解析；代理路径保留逻辑目标。移除旧的套接字到逻辑地址包装调用，实际端点比较和回复编码回到连接及协议层，并在所属边界处理 NIO 地址错误。监听配置和示例在各自变更中验证。

### 12. 验收标准

以下验收项覆盖模型及后续调用方迁移，不代表已经全部实现或验证。

| 编号 | 场景 | 必须验证的结果 |
|---|---|---|
| NA-01 | 合法域名、IPv4 和 IPv6 | 使用域名存储或 IP 套接字，主机名视图和端口正确；不重复存储 IP 或端口 |
| NA-02 | 按需读取域名、IPv4、IPv6 和映射 IPv6 目标的 `socketAddress` | 域名在允许阻塞的边界通过 NIO 解析，成功时返回端点，失败时传播原始错误；转换不改变域名身份；IP 直接返回规范化端点和原端口，映射 IPv6 输出 IPv4 |
| NA-03 | 协议层处理二进制 IP、非零起始的 `Data` 切片或非零读取索引的 `ByteBuffer` | 只读取正确的 4 或 16 字节；经 NIO 数值文本进入唯一构造入口；截断或长度错误在协议边界失败 |
| NA-04 | HTTP IP 文本、协议字段转换后的 IP 文本和映射 IPv6 | 值相等，输出套接字一致；Set 中只保留一个身份 |
| NA-05 | 原生、IPv4 兼容和 NAT64 IPv6 | 保持 IPv6 |
| NA-06 | 第 4 节的拒绝向量及 `0xfeed.example` | 数值歧义被拒绝；普通域名可以构造 |
| NA-07 | 域名大小写和根点 | 转为小写，保留一个根点，拒绝多个根点 |
| NA-08 | 标签长度 63/64；名称长度 253/254 | 边界精确；254 字节要求包含合法根点 |
| NA-09 | 空值、空白、控制字符、NUL、Unicode、非法分隔符 | 拒绝，不去除首尾空白或截断 |
| NA-10 | 端口 0、1、65535；非法配置端口 | 合法范围精确；具体操作的零端口策略单独处理 |
| NA-11 | 大小写、不同端口和显式根点 | 相等性与哈希符合第 7 节 |
| NA-12 | 等价 HTTP、SOCKS4a、SOCKS5 TCP/UDP 目标 | 路由、数值目标和 Wire 编码一致 |
| NA-13 | 带根点域名的匹配和转发 | 匹配时可以去点；转发时保留 |
| NA-14 | 构造、比较、哈希、读取主机名及重复读取 IP 的 `socketAddress` | 不执行 DNS，不创建 Channel、线程或 Task；套接字读取不重新解析文本 |
| NA-15 | 读取套接字后修改副本；UDP 使用带作用域或流信息的实际端点 | 模型值不变；实际端点由连接层直接保留和消费，不经过模型反向构造 |
| NA-16 | Domain 字段中的 IPv6 文本及 ASSOCIATE 来源提示 | 保留协议限制及必要的原始 ATYP |
| NA-17 | 构造入口、两种 IP 识别及域名校验位置 | `init(host:port:)` 用 `switch` 分派；IP 分支只调用对应的 `parseIPv4Text` 或 `parseIPv6Text`，方法内完成校验、解析和报错，成功返回非可选端点；`default` 在 `init` 内直接校验域名；不依次试解析或失败后回退，不增加其他构造入口或辅助方法 |
| NA-18 | 域名 UDP 目标经代理路由 | 编码域名，不调用本地目标解析 |
| NA-19 | 域名 UDP 目标直连 | 按选定 DNS 策略异步解析，再向返回的套接字发送 |
| NA-20 | 数值 UDP 目标及本地客户端回复 | 使用实际套接字，不执行 DNS；回复保留原始客户端端点 |
| NA-21 | NIO 地址错误和模型策略错误 | 到达所属错误处理入口前保持原始错误类型 |

使用固定输入和字面量期望值。相等性测试验证值及集合行为，不验证不稳定的数值 `hashValue`。解析器测试必须区分经代理转发的域名和直连域名，并证明是否调用了解析。

模型实现需要运行定向测试。迁移涉及连接、缓冲、并发或清理时，还必须执行：

```bash
swift build
swift build -Xswiftc -strict-concurrency=complete
swift test --filter NetworkAddressTests
swift test --filter ConnectionTests
swift test
git diff --check
```

对修改的 Swift 文件运行严格格式检查。应用编译和真实网络行为需要各自的验证证据。仅修改文档时，检查结构、链接、契约一致性和差异。

### 13. 相关文件与规范边界

- [当前 NetworkAddress 实现](../Sources/Model/NetworkAddress.swift)
- [当前模型测试](../Tests/Model/NetworkAddressTests.swift)
- [架构](ARCHITECTURE.md)
- [SOCKS4 / SOCKS4a 规范](SOCKS4_PROXY_SPEC.md)
- [SOCKS5 规范](SOCKS5_PROXY_SPEC.md)
- [HTTP 规范](HTTP_PROXY_SPEC.md)

本候选方案不把其他协议要求标记为已实现，也不放宽其中更严格的字段和 IDNA 契约。已实现 API 和监听行为的说明，在对应实现真正迁移时更新。

## HttpProtocol

### 1. 定位与设计目标

`HttpProtocol` 表示**一个 HTTP 请求头经过完整校验后所表达的代理请求语义**。它从 NIO 的 `HTTPRequestHead` 构造，确定业务目标、CONNECT 或普通转发分支，以及普通转发使用的出站请求头和请求体定界方式。

构造成功表示请求头语义满足本章契约，可以继续对应的连接流程；不代表请求体已经完整、上游连接已经成功或响应已经发出。

职责分为三层：

| 层次 | 职责 |
|---|---|
| NIOHTTP1 解码器 / 编码器 | HTTP 消息语法、增量解码和消息编码 |
| `HttpProtocol` | 请求头语义、目标提取、Host 与定界字段校验、出站请求头重建 |
| HTTP 连接层 | 请求体接收、运行时限额、认证、路由与拨号、响应选择、背压和生命周期 |

`HttpProtocol` 不持有原始接收缓冲、请求体、Channel、Wire、Core、Future 或 Task；不解析响应，也不执行 DNS。不再把 `checkConnect()`、可变请求字段和静态 HTTP 响应字节混放在同一对象中。

### 2. 首版范围与其他 HTTP 规范的关系

本章先为现有两个 HTTP 连接建立明确且共用的模型契约。首版选择有限的 HTTP/1 请求处理范围；这些是本模型的产品约束，不是所有 HTTP 实现都必须采用的限制。

| 项目 | 本章首版设计 |
|---|---|
| 版本 | HTTP/1.0 和 HTTP/1.1；保留类型化版本 |
| CONNECT | 主机与端口形式，必须显式提供非零端口，无请求体 |
| 普通转发 | `http` 绝对形式，以及由 Host 确定目标的源站形式 |
| 请求体 | 无请求体，或由单个 Content-Length 指定固定长度 |
| Transfer-Encoding / 请求尾部字段 | 首版拒绝；不能通过删除字段假装支持 |
| Expect / Upgrade | 首版拒绝；不触发 100-continue 或协议升级流程 |
| OPTIONS | 支持发往明确目标的普通 OPTIONS；首版不支持入站 `OPTIONS *` 及带 Max-Forwards 的 OPTIONS |
| TRACE | 首版按不支持的方法拒绝 |
| 其他方法 | 保留合法且区分大小写的方法标记；不只为常见方法建立模型白名单 |
| 连接复用 | 首版连接层保持单请求流程，普通出站请求使用 `Connection: close` |

[HTTP_PROXY_SPEC.md](HTTP_PROXY_SPEC.md) 描述了更广的目标范围，包括仅支持 HTTP/1.1、拒绝入站源站形式、分块传输、完整的 OPTIONS/Max-Forwards、Expect、Upgrade 和连接复用。本章不代表已经实现完整代理规范。

两份文档明确不一致时，模型首版实现以本章范围为准；实现完整 HTTP 代理目标时，必须一起升级模型、连接层契约和验收，不能仅预留一个没有执行路径的枚举分支。原 HTTP 规范继续作为后续完整能力的设计参考。

### 3. 类型形态与唯一入口

保留 `HttpProtocol` 名称，采用包内不可变 `struct`。使用关联值枚举表示两种请求，避免 `isConnect`、可选目标、可选出站头和可选请求体字段的任意组合。

以下是接口草图，省略构造实现，不是可直接编译的完整源文件：

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
        // 校验输入、提取目标，并生成最终请求语义。
    }
}
```

这些类型的选择依据如下：

- `HTTPRequestHead`、`HTTPVersion`、`HTTPMethod` 和 `HTTPHeaders` 直接复用 NIO 类型。版本不再通过 `"HTTP/1.1"` 字符串往返转换，请求头也不再转换为普通字典或另一套字段模型。
- `.connect` 只保留目标和入站版本；不包含发往源站的 CONNECT HTTP 请求头，也不包含 HTTP 请求体状态。
- `.forward` 保留规范化目标、可直接交给编码器的出站 `HTTPRequestHead` 和明确的请求体定界规则。
- `BodyFraming.none` 与 `.fixedLength(0)` 区分未声明请求体和显式声明零长度；两者都没有请求体字节，但出站字段不同。
- `Failure` 只区分模型自身产生的语义错误，连接层按枚举选择响应，不按错误描述文本分支。

不提供直接接受 `Request` 的构造入口，也不暴露可写存储。包内代码可以读取和解构 `request`；修改提取出的 `HTTPRequestHead` 副本不能改变模型自身。

本模型不作为缓存键或持久化记录；首版不增加 `Hashable`、`Codable` 或保留完整请求的日志接口。验收直接检查分支、地址、NIO 字段和定界结果。

### 4. 构造阶段与校验归属

构造必须先校验入站含义，再删除或重建字段：

```text
HTTPRequestHead
    ↓
检查版本、方法、字段基本合法性和关键字段重复项
    ↓
读取原始 CL / TE，确定或拒绝入站定界
    ↓
请求目标、主机与端口部分、Host → NetworkAddress
    ↓
检查 Connection 标记和不支持的特性
    ↓
生成 CONNECT 语义 / 普通转发出站请求头
```

构造只依赖传入的请求头，不访问配置单例、网络、系统代理状态或时钟。同一输入必须产生相同结果或错误类别。

NIO 解码器负责原始请求行、CRLF、字段语法和增量消息边界。模型不重新解析原始消息，但必须检查手工构造的 NIO 请求头可能缺少的值约束：方法和字段名必须是非空 HTTP 标记，字段值不得包含 CR、LF、NUL、DEL 或 HTAB 之外的控制字符。不能认为调用 `HTTPRequestHead(...)` 就意味着已经完成所有语法校验。

字段名使用 ASCII 大小写不敏感的比较语义。字段值只在 HTTP 字段语法允许的位置去除 SP / HTAB；不得对请求目标或主机名执行通用 Unicode 首尾空白清理。必须保留重复字段，不能在校验前通过字典、自动合并或覆盖丢失信息。

如果底层解码器在生成 `.head` 前拒绝输入，错误直接交给连接层；如果解码器合并了判断所需的信息，应在 NIO 解码接入点解决，不能让模型猜测缺失的原始字段。网络报文测试和直接构造请求头的测试都必须覆盖这些边界。

### 5. 请求类型与唯一目标来源

| 方法 / 请求目标 | 分支与业务目标 |
|---|---|
| 精确的 `CONNECT host:port` | `.connect`；目标来自主机与端口部分 |
| 非 CONNECT 的 `http://host[:port]/path?query` | `.forward`；目标来自 URI 主机与端口部分 |
| 非 CONNECT 的 `/path?query` | `.forward`；目标来自唯一且合法的 Host |
| CONNECT 使用绝对形式、源站形式或 `*` | 非法请求 |
| 非 CONNECT 使用裸 `host:port` | 非法请求 |
| `OPTIONS *` | 首版能力不足；拒绝，不能虚构业务目标 |
| 其他方法使用 `*` | 非法请求 |
| `https://`、`ws://`、`wss://`、`ftp://` 等 URI 方案名 | 首版不支持；不能静默改用明文 TCP |

方法名区分大小写；`connect` 不能变成 `CONNECT`。普通方法不能根据 GET/POST 推断是否存在请求体；定界由字段独立决定。

URI 方案名按 ASCII 大小写不敏感方式识别；请求目标使用 ASCII URI 文本，原始 Unicode 路径必须先由客户端合法地进行百分号编码。以 `//` 开头的合法源站形式路径仍然是路径，不能重新解释为另一个主机与端口部分。

代理节点地址只用于 Core 选择传输端点。模型的 `target` 始终是业务目标，出站 Host 不能替换为代理节点或 DNS 返回的数值 IP。

主机与端口形式与绝对形式的基本区别，以及绝对形式下根据 URI 主机与端口部分重建 Host 的依据，见 [RFC 9112 §3.2](https://www.rfc-editor.org/rfc/rfc9112.html#section-3.2)。本章另行定义源站形式是否接受及 CONNECT Host 一致性的产品策略。

### 6. HTTP 地址与 NetworkAddress 的衔接

HTTP 层只拆分主机名、端口和 IPv6 方括号，再调用受控的 [NetworkAddress](#networkaddress) 构造入口。不另写一套 ASCII 主机名规则、数值地址歧义规则或映射 IPv6 规范化逻辑。

| 场景 | 端口规则 |
|---|---|
| CONNECT 请求目标 | 必须显式提供 `1...65535` |
| 普通绝对形式的主机与端口部分 | 省略时默认为 80；显式端口必须非零 |
| 普通转发的 Host | 省略时默认为 80；显式端口必须非零 |
| CONNECT 的 Host | 省略时只借用请求目标已经确定的端口进行一致性比较；不能因此推断为 443 |

显式端口只接受非空十进制数字，并检查溢出。端口输入允许前导零，输出使用普通十进制；不接受符号、内部空白、空端口或截断式转换。

HTTP 地址的主机与端口部分中的 IPv6 必须带完整方括号，括号外只能有允许的端口后缀。拒绝混入主机与端口部分的用户信息、百分号编码主机名、作用域、IPvFuture、路径、查询和片段。

必须先验证括号内容是合法 IPv6 字面量，再传给 `NetworkAddress`。不能要求规范化后的 IP 套接字仍为 `.v6`，否则 `[::ffff:192.0.2.1]:443` 在合法转换为 IPv4 后会被错误拒绝。必须拒绝 `[example.com]:443` 和 `[192.0.2.1]:443`。

主机与端口部分的词法拆分可以共用现有 `HttpProtocol.swift` 中的一个私有方法，返回主机名、可选显式端口和表示信息。CONNECT 是否必须有端口，由调用位置决定；不使用 `isConnect`、`allowMissingPort` 等布尔开关链。复用拆分规则时，不能抹平各字段之间的语义差异。

### 7. Host 字段契约

| 场景 | Host 要求 |
|---|---|
| HTTP/1.1 | 恰好一个合法且非空的 Host |
| HTTP/1.0 CONNECT / 绝对形式 | 可以缺失；存在时必须恰好一个且合法 |
| HTTP/1.0 源站形式 | 恰好一个合法且非空的 Host，否则无法确定目标 |
| 任意版本中的重复 Host | 拒绝，包括值相同或字段名大小写不同的重复项 |

首版对三种目标形式的处理如下：

- 绝对形式：URI 主机与端口部分决定业务目标。合法但不一致的 Host 不改变路由，出站 Host 根据 URI 主机与端口部分重建。
- 源站形式：Host 是唯一目标来源，没有其他 URI 主机与端口部分可以兜底。
- CONNECT：存在 Host 时，按第 6 节端口规则构造比较值，并与请求目标的 `NetworkAddress` 比较；不一致则拒绝。

CONNECT 一致性比较采用地址值身份：统一域名大小写，映射 IPv6 等于 IPv4，保留显式根点差异。不能用去掉根点后的路由匹配键证明 Host 一致，也不能执行 DNS 来比较两个域名是否指向同一服务器。

严格检查 CONNECT 一致性是本章的产品决策；[HTTP_PROXY_SPEC.md](HTTP_PROXY_SPEC.md) 对 CONNECT Host 使用更宽松的目标优先规则，首版实现不能混用两种分支。绝对形式接受合法但冲突的 Host，也不代表接受缺失、重复或语法非法的 HTTP/1.1 Host；字段数量和语法仍然先行校验。

### 8. 路径、查询与出站地址

普通绝对形式只提取结构边界，不先解码再重新编码路径或查询。不得依赖会自动修复非法输入或改变转义文本的 URL 处理方式；复用 URL 解析能力时，必须用下列字面量向量验证其保留行为。

| 输入 URI | 出站请求目标 |
|---|---|
| `http://example.com` | `/` |
| `http://example.com?` | `/?` |
| `http://example.com?x=1` | `/?x=1` |
| `http://example.com/a%2Fb?q=%0D%0A` | `/a%2Fb?q=%0D%0A` |
| `http://example.com/a/../b//c` | `/a/../b//c` |
| 合法源站形式 `/a%2Fb?x=` | 原样保留 |

必须拒绝原始空白、控制字符、反斜线、片段和不完整的 `%HH` 转义。合法转义不能解码为分隔符或控制字符。重复斜线、点路径段和查询参数顺序保持不变。

`OPTIONS http://example.com` 是一种特殊但目标明确的转发请求：作为源站之前的最后一个 HTTP 代理，当路径为空且没有查询时，出站目标为 `*`；`OPTIONS http://example.com?` 输出 `/?`。这是向已确定源站转发的 OPTIONS，与入站 `OPTIONS *` 本地能力请求不同。两者区别见 [RFC 9112 §3.2.4](https://www.rfc-editor.org/rfc/rfc9112.html#section-3.2.4)。

出站 Host 使用最终 `NetworkAddress` 的规范化主机名，并根据 HTTP 地址是否显式提供端口来生成：

| 入站目标 | 出站 Host |
|---|---|
| `http://API.Example.COM./x` | `api.example.com.` |
| `http://example.com/x` | `example.com` |
| `http://example.com:80/x` | `example.com:80` |
| `http://[2001:db8::1]:8080/x` | `[2001:db8::1]:8080` |
| `http://[::ffff:192.0.2.1]:80/x` | `192.0.2.1:80` |

显式默认端口是 HTTP 表示信息，不属于 `NetworkAddress` 的身份；构造 HttpProtocol 时用局部解析结果保留并生成出站头，不为此扩展通用地址模型。普通 IPv6 根据规范化后的实际类型补方括号，域名根点保留。

### 9. 请求体定界

模型保存请求体的定界规则，不保存请求体字节，也不维护已经收到多少字节的计数器。

| 入站字段 | 首版结果 |
|---|---|
| 普通请求无 CL / TE | `.none`，请求没有请求体，不能等待 EOF 定界 |
| 普通请求单个合法 CL | `.fixedLength(n)`，包含 `n == 0` |
| 重复 CL，含相同重复值 | 非法请求 |
| 单字段 `Content-Length: 4, 4` | 非法请求，不采用容错合并 |
| CL 非数字、带符号、内部空白或 UInt64 溢出 | 非法请求 |
| 同时有 CL 和 TE | 非法请求，在任何出站之前拒绝 |
| 普通请求任何 TE | 首版不接受；解码器已判定语法或定界非法时按原始错误处理 |
| CONNECT 无 CL / TE | 无请求体 |
| CONNECT 单个 CL=0 | 允许，但不作为隧道长度、不向目标转发 |
| CONNECT 非零 CL 或任何 TE | 非法请求 |
| 请求声明 Trailer | 首版不接受 |

CL 允许字段外侧合法 OWS 和十进制前导零；检查后以一个十进制整数重建出站 CL。不得先删除 TE、合并 CL 或移除 Connection 指名字段，再推断请求长度。相关消息定界原则见 [RFC 9112 §6.3](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3)，重复 CL 全部拒绝属于本章的严格输入策略。

`UInt64` 只用于安全表达声明长度，不是允许分配同等内存的承诺。连接层在分配、接收或拨号之前按实际资源限额拒绝过大请求；转换为 `Int` 或累计长度时必须检查溢出。不得在模型内固定一个测试方便的最大请求体大小。

连接层负责校验 `.body` / `.end` 的时序、累计长度、提前 EOF 和实际尾部字段。模型构造只看请求头，因此不能声称构造成功已经验证了后续请求体。

### 10. 出站头重建

使用 `HTTPHeaders` 保留允许转发的字段及重复项，不改变任意业务字段的值。重建顺序如下：

1. 在原始字段上完成 Host、CL/TE 和不支持特性的检查。
2. 按 HTTP 列表语法读取所有 Connection 字段；非空项必须为合法标记，以 ASCII 小写比较，空列表项不作为字段名。
3. Connection 指名 `Host`、`Content-Length`、`Transfer-Encoding`、`Trailer`、`Authorization`、`Proxy-Authorization` 或 `Expect` 等关键字段时拒绝，防止删除操作改变认证、目标或分帧含义。这里的 `Transfer-Encoding` 与独立的 `TE` 字段必须区分。
4. 移除 Connection 指名的普通逐跳字段，以及旧的 Connection、Keep-Alive、Proxy-Connection、TE、Trailer、Transfer-Encoding、Upgrade、Proxy-Authenticate 和 Proxy-Authorization。
5. 根据唯一业务目标重建一个 Host，根据 `BodyFraming` 重建零个或一个 Content-Length；输出中不得出现 Transfer-Encoding。
6. 保留端到端字段的值和重复顺序，例如 Authorization、Cookie、自定义字段；不把 Proxy-Authorization 当作源站 Authorization。
7. 写入首版的 `Connection: close`，使用原方法和支持的入站 HTTP 版本生成新的 `HTTPRequestHead`。

原始 Host 和 CL 由重建值替代，不能一边保留旧字段一边追加新字段。Connection 标记的检查发生在过滤之前，包括大小写变体。

Expect、Upgrade 字段或 Connection 的 `upgrade` 标记、请求 Trailer 按首版能力拒绝，不能仅删除头字段后继续当普通请求处理。Expect 产生 `Failure.unsupportedExpectation`，不支持的升级和 Trailer 产生 `Failure.unsupportedFeature`；已发现的非法分帧仍先按非法请求拒绝。对带 Max-Forwards 的 OPTIONS，首版返回能力不足，不能忽略该字段继续转发；完整本地 OPTIONS 分支和递减规则留待独立扩展。

运行时需要添加 Via 或执行认证时，由连接层使用明确的运行配置完成。认证读取过滤前的原始请求头，不能从已经删除代理凭据的出站头推断身份。Via 的配置和回环策略不进入无上下文模型；添加运行时转发字段不得修改已经确定的方法、目标、Host 或请求体定界。

### 11. 连接层消费契约

连接层收到 `.head` 时构造模型并保存结果；不能在 `.end` 时再次从原始字符串重新计算业务目标。不同事件的职责如下：

| 事件 / 阶段 | 连接层的责任 |
|---|---|
| `.head` | 只构造一次，检查运行时限额、认证与能力，保存不可变请求语义 |
| `.body` | 按模型给出的定界规则接收，进行计数、限额和背压处理 |
| `.end` | 确认消息完整、长度一致、无不支持的尾部字段 |
| CONNECT 建连 | 使用模型中的目标完成路由和 Wire 握手 |
| 普通转发 | 使用同一个目标路由；把模型里的请求头和完整请求体交给编码器 |
| 成功或失败响应 | 由连接状态和错误类别决定，写入完成后再推进状态 |

首版继续采用当前连接流程：完整接收请求后发起业务转发，只处理单个请求，不接受请求流水线。缓冲上限由连接层执行，模型不拥有完整请求体；未来流式转发时修改连接层的发送时机和背压，不把 Channel 或计数器塞回模型。

CONNECT 必须等到请求结束、解码器余量检查完成、业务连接及 Wire 启动握手就绪、本地 2xx 写入成功后才能进入隧道。拒绝提前数据、移除解码器的顺序、EOF 和半关闭都是连接层状态机职责。

普通请求通过 NIO 编码能力得到请求字节，再进入直连通道或相同 Wire 的隧道载荷路径。不得继续由模型或 `buildPayload` 拼接一份完整 `Data` 请求；具体编码器与 Wire 的处理管线接法须在连接迁移中验证，不能因改用类型化请求头丢掉已有手动读取、写入完成和关闭顺序约束。

### 12. 本地响应与错误路径

`HttpProtocol` 不再定义 `established`、`badRequest`、`badGateway`、`gatewayTimeout` 等静态 `Data`。HTTP 连接层使用 `HTTPResponseHead` / 编码器生成本地响应，并持有“一次响应”的状态约束。

最上层负责该流程的边界按以下类别选择响应；模型辅助方法不捕获下层错误再包装、改名或输出响应：

| 错误来源 | 连接层的首版响应策略 |
|---|---|
| `Failure.invalidRequest`、地址构造错误、NIO 请求解码错误 | 400 |
| `Failure.unsupportedVersion` | 505 |
| `Failure.unsupportedFeature` | 501 |
| `Failure.unsupportedExpectation` | 417 |
| 下游连接失败 | 502 |
| 下游连接超时 | 504 |

`unsupportedFeature` 的关联文本只用于诊断，不能据此再拆分状态码。资源限额、鉴权和其他运行错误由对应连接策略处理，不能一概变成 400。成功响应已经开始或进入隧道后，不得再追加 HTTP 错误响应。

CONNECT 成功响应不含 Content-Length、Transfer-Encoding 或 HTTP 响应体，头部结束后进入隧道。普通本地错误可以发送明确的 `Content-Length: 0` 和 `Connection: close`。CONNECT 成功响应的限制见 [RFC 9110 §9.3.6](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.6)。

两个连接类型需要共用响应编码时，先在现有 HTTP 连接类型中评估共享方法；不把重复字节常量移成另一个没有独立职责的文件，也不放回请求语义模型。

### 13. 具体输入与输出

以下示例描述构造的语义结果，不代表已运行新实现。

CONNECT：

```http
CONNECT API.Example.COM.:443 HTTP/1.1
Host: api.example.com.
Content-Length: 0

```

结果为 `.connect`，目标是 `NetworkAddress(host: "api.example.com.", port: 443)`，版本为 `.http1_1`。Host 未显式提供端口，按请求目标端口比较；CL=0 不进入 Wire 握手或隧道负载。

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

结果为 `.forward`，目标为 `api.example.com.:80`，请求体为 `.fixedLength(4)`。关键出站字段为：

```http
POST /a%2Fb?x= HTTP/1.1
Host: api.example.com.:80
Content-Length: 4
Connection: close

```

四个请求体字节 `data` 由连接层单独保管和发送，不存入模型。代理认证如果启用，在连接层中使用原始代理凭据；示例不是认证成功的声明。运行时的 Via 等字段由连接层按配置追加。

### 14. 迁移范围

1. 在现有 `Sources/Model/HttpProtocol.swift` 实现唯一的 NIO 请求头构造入口、关联值请求枚举和必要的私有解析方法。
2. `HttpConnectConnection` 移除版本字符串转换、手工元组形式的请求头字段、`checkConnect()` 和独立的主机与端口部分校验链。
3. `HttpForwardConnection` 的目标提取、Host/CL 校验和请求头改写合并到本模型；请求体缓冲与状态机留在连接中。
4. 去掉整包 `buildRequest(head:body:)` / `buildPayload` 式模型入口，改为消费类型化请求头和独立请求体。
5. 响应常量迁出模型，按连接状态使用编码器发送本地响应。
6. 核对 `ProxyProbe` 与模型范围一致；探测只选择协议，不能替代模型对方法和目标形式的完整检查。
7. 更新原有模型断言与连接回归；CONNECT CL=0、Host 省略端口、错误状态码和 OPTIONS 限制等行为变化必须写成明确用例。

`HttpProtocol` 继续为包内 API，不因重构而公开给应用。嵌套类型及小型私有方法留在原文件，不引入上下文隔离类型、路由器、泛型请求框架或测试专用解析器。

### 15. 验收标准

模型纯逻辑验收和真实连接流程验收分开记录。以下均为新设计的待实现项：

| 编号 | 场景 | 必须验证的结果 |
|---|---|---|
| HP-01 | 合法 CONNECT / 普通转发 | 分别得到唯一有效分支，不依赖第二次检查 |
| HP-02 | HTTP/1.0、1.1、其他版本；方法大小写和合法未知方法 | 版本策略和区分大小写语义明确，不自动改写方法 |
| HP-03 | HTTP/1.1 缺失、重复、大小写不同的重复 Host | 全部拒绝；HTTP/1.0 按目标形式处理缺失 Host |
| HP-04 | 绝对形式与合法冲突 Host | 目标和新 Host 都来自 URI，原 Host 不影响路由 |
| HP-05 | CONNECT Host 省略端口、大小写、IPv4 映射 IPv6、不同端口或根点 | 相等情况通过；端口和根点身份不一致拒绝 |
| HP-06 | 方括号 IPv6、IPv4 映射 IPv6、括号内域名/IPv4、作用域 | IPv6 字面量先验证，映射地址转为 IPv4 后仍接受，其余非法向量拒绝 |
| HP-07 | CONNECT 缺端口、空端口、0、65536、符号；普通 URI 默认/显式 80 | 端口语义精确，显式默认端口在出站 Host 保留 |
| HP-08 | 空路径、空查询、转义大小写、重复斜线、点路径 | 第 8 节所有字面期望保持；不解码重编码 |
| HP-09 | URI 片段、反斜线、空白、非法转义、用户信息 | 拒绝；合法 `%0D%0A` 仍是原字面转义 |
| HP-10 | 无 CL、CL=0、CL=0004 | 分别为 none、fixedLength(0)、fixedLength(4)，出站长度规范化 |
| HP-11 | 重复 CL、逗号 CL、CL 溢出、TE+CL | 在出站前失败，网络报文与直接请求头入口均覆盖 |
| HP-12 | CONNECT CL=0、非零 CL、TE；普通转发 TE/Trailer/Expect/Upgrade | 按首版能力准确允许或拒绝，不通过删头放行 |
| HP-13 | Connection 指名普通字段和 Host/CL/认证字段 | 普通字段移除，关键字段拒绝，比较大小写不敏感 |
| HP-14 | 重复业务字段、Authorization、Proxy-Authorization | 保留允许的字段及顺序，代理凭据不泄漏给源站 |
| HP-15 | 直接构造含非法标记、CR/LF/NUL 的 NIO 请求头 | 模型拒绝，不把 NIO 值类型误当成已验证输入 |
| HP-16 | HTTP 与 SOCKS 的等价数字目标 | 使用同一 NetworkAddress 规范化结果路由与编码 |
| HP-17 | 请求体未收齐、超长、提前 EOF、尾部字段、重复请求头/结束事件 | 连接层拒绝或关闭，不把头部模型通过当成完整请求通过 |
| HP-18 | CONNECT 每个拆分点、同包余量、提前隧道负载 | 严格成功回复顺序，解码器移除不丢余量或提前放行 |
| HP-19 | 请求头/请求体编码与 Wire 启动握手 | 先完成正确启动握手，再发送 HTTP 字节，请求体不重复、不丢失 |
| HP-20 | 本地错误和 CONNECT 成功 | 状态码按类别映射，至多一次响应；成功 CONNECT 无 CL/TE/响应体 |
| HP-21 | 单请求、请求流水线、后续长连接请求 | 首版连接层边界保持，不因改模型扩大支持声明 |
| HP-22 | OPTIONS 空路径无查询、空查询、入站 *、Max-Forwards、TRACE | 明确区分源站 * 转发与未支持的本地能力请求，不猜测目标 |
| HP-23 | 仅构造模型及读取结果 | 无 DNS、无 Channel、无请求体缓存、无日志或认证副作用 |
| HP-24 | 取出请求头后修改副本 | 原模型的目标、头部及分帧规则不改变 |

测试断言必须包括具体 `NetworkAddress` 值、HTTP 方法和版本、精确目标字符串、字段数量和值、BodyFraming 和失败类别。输出字段大小写或无关字段顺序不作为协议等价性判断，但应验证重复字段的语义和顺序没有被错误合并。

字节级解析和防注入向量必须经过真实 NIO 解码器，不能只使用手工构造的请求头代替。模型用例也要覆盖手工请求头，证明构造入口自身的契约。连接测试继续覆盖背压、半关闭、超时、清理和真实编码顺序。

实现后至少执行项目规定的构建、启用完整严格并发检查的构建、ConnectionTests、全包测试及修改文件的严格格式检查和 `git diff --check`；增加对应的模型定向测试。文档单独变更只做结构、链接与不变量检查，不宣称上述实现验收已经完成。

### 16. 相关文件与证据

- [当前 HttpProtocol 实现](../Sources/Model/HttpProtocol.swift)
- [当前 HTTP CONNECT 连接](../Sources/Connection/HttpConnectConnection.swift)
- [当前 HTTP 普通转发连接](../Sources/Connection/HttpForwardConnection.swift)
- [当前 CONNECT 测试](../Tests/Connection/HttpConnectConnectionTests.swift)
- [当前普通转发测试](../Tests/Connection/HttpForwardConnectionTests.swift)
- [HTTP 完整代理目标规范](HTTP_PROXY_SPEC.md)

当前源码和测试是迁移调用链的依据，不能证明新模型已经实现。构造、头部字段、分帧和语义分支应按本章重新验收；完整 HTTP 产品能力仍需逐项对照原 HTTP 规范。

## ProxyNode

### 1. 定位与职责

`ProxyNode` 是一个不可变的、已经通过本地配置校验的出站代理节点值。它描述如何连接代理服务器及采用哪个节点协议，不表示业务目标，也不保存已经建立的连接。

模型负责节点标识、实际服务器端点、协议、密码和连接超时的配置契约。Core 负责节点集合、UUID 查找和 Wire 选择；Wire 负责密码派生、盐值、一次性数值、帧状态及加解密；应用负责节点名称、订阅、启用状态、持久化和节点域名解析。

构造成功表示配置在本地可执行，不保证服务器可达、密码正确或远端实现支持选定算法。构造不访问 DNS，不建立 Channel，不生成连接盐值，也不预先创建 Wire。

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

只列出当前具有真实 TCP/UDP 实现和验收路径的协议。暂不增加 SOCKS5、HTTP 上游、DIRECT、REJECT 或未知占位枚举分支；DIRECT 是 [ProxyRule](#proxyrule) 章节中 `Decision` 的动作，不是代理节点。

原始值是明确的导入标识，大小写和拼写精确匹配。未知协议必须报错，不能自动替换为 Shadowsocks。`allCases` 不构成当前网络环境一定能够使用这些协议的证明。

### 4. ProxyCipher

`ProxyCipher` 标识 Shadowsocks Wire 支持的加密算法及其固定参数；密码不是主密钥，`keySize` 也不是密码字符数或 UTF-8 字节数限制。

```swift
public enum ProxyCipher: String, Codable, Sendable, Hashable, CaseIterable {
    case aes128Gcm = "aes-128-gcm"
    case aes256Gcm = "aes-256-gcm"
    case chacha20IetfPoly1305 = "chacha20-ietf-poly1305"
    case xchacha20IetfPoly1305 = "xchacha20-ietf-poly1305"
}
```

以下参数以当前包内 `ProxyCipher`、`AeadCipher` 及对应测试为基线，单位均为字节：

| 枚举分支 | 密钥长度（keySize） | 盐值长度（saltSize） | 一次性数值长度（nonceSize） | 认证标签长度（tagSize） |
|---|---:|---:|---:|---:|
| `aes128Gcm` | 16 | 16 | 12 | 16 |
| `aes256Gcm` | 32 | 32 | 12 | 16 |
| `chacha20IetfPoly1305` | 32 | 32 | 12 | 16 |
| `xchacha20IetfPoly1305` | 32 | 32 | 24 | 16 |

这些只读参数继续由枚举提供，不能再作为用户可覆盖的节点字段存储。未知算法或未知原始值必须失败；不得静默降级、忽略算法或选择默认算法。该列表只描述本包能力，不代表任意 Shadowsocks 服务端都支持全部四种算法。

枚举不执行密码派生、不生成随机数、不维护一次性数值。实际密钥长度、一次性数值长度和加密帧检查仍属于加密实现 / Wire 边界，不能因节点构造成功而删除。

### 5. 端点、密码和超时不变量

| 字段 | 构造成功后的契约 |
|---|---|
| `address` | IPv4 或 IPv6 的实际 `SocketAddress`，端口为 `1...65535`；拒绝 Unix 域套接字和端口 0 |
| `type` | 存在本包实现的明确协议枚举分支 |
| `cipher` | 存在本包实现的明确算法枚举分支 |
| `password` | UTF-8 表示非空，内容原样保存 |
| `timeoutMilliseconds` | `1...9_223_372_036_854`，可精确转换为正的 Int64 纳秒 |

节点地址必须继续保存实际地址族和 IPv6 作用域。不得为了复用业务地址规范化而转成 `NetworkAddress` 后覆盖真实节点端点，也不能去掉作用域。IP 是否可达、是否自回环及是否被运行时访问策略允许，由应用和 Core 的对应策略判断，不通过一次模型构造来宣称已经验证。

密码不去除首尾空白、不做 Unicode 规范化、不按 cipher 的 keySize 截断或补齐；仅包含空格的非空密码也按原字节处理。空密码在本章作为配置错误拒绝，这是本产品的输入策略。错误消息和模型描述不包含密码或派生密钥；真实配置不写入文档或测试。

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
- 比较实际节点端点沿用 SocketAddress 身份，不用业务请求的 IPv4 映射 IPv6 归一结果作为原始套接字的替代物。
- 批量加载按顺序处理，不因模型重构而宣称增加事务回滚、端点互换重排或公共热更新能力。

### 7. 生命周期、引用与持久化

`ProxyNode` 不持有 TCP 加密流状态。每条代理 TCP 连接由 Core 创建独立 Wire，盐值 / 一次性数值 / 启动状态不能因节点 UUID 相同而复用；UDP 仍遵循 Wire 自己的独立数据报加密规则。

默认 `.proxy(UUID)` 在完整节点表装载之后校验；缺失则 Core 初始化失败。规则中的节点引用继续在实际选中该规则时检查，缺失抛出原始 `proxyNodeNotFound`，不回退 DIRECT。这些是配置集合和路由边界的契约，不是节点模型自身的存在性校验。

`restart` 为下一运行周期创建新的 Core；本章不引入跨运行周期共享 Wire、节点单例或额外配置快照。

首版不为整个 `ProxyNode` 增加自动 Codable。协议/算法的原始值可以独立编码；应用存储负责 UUID、原始节点主机名、端口、凭据及超时字段，并在构造运行配置前解析出 `SocketAddress`。不能把含作用域的实际端点仅序列化为普通 IP 字节而丢失作用域。

### 8. 错误与迁移

本地节点配置违反上述不变量时，构造入口抛出 `MagentError.invalidPolicy`。错误说明可以标明字段或原因，不能包含密码。DNS、密码派生和加密实现 / Wire 的原始错误分别在其实际执行边界传播，不在节点辅助方法内包装成另一种错误。

本次设计相对于当前实现的变化是：

1. `ProxyNode.init` 改为抛错，提前验证端点、非空密码和超时。
2. `timeout: TimeInterval` 改为 `timeoutMilliseconds: Int64`，默认值从 30 秒明确为 30_000 毫秒。
3. TCP / UDP Wire 删除重复的秒到毫秒转换，继续保留真正的加密初始化和运行错误处理。
4. 对包含密码的配置相等性和哈希实施字节语义。

历史秒值转换由应用迁移负责：拒绝非有限数及非正数；乘以 1000 后向上取整，再检查第 5 节上限并精确转为 Int64。这样延续当前 Wire 的毫秒取整规则，不能把原来的 `30` 直接解释为 30 毫秒。应用中的节点导入和存储转换必须显式处理构造失败，不能继续以 `compactMap` 静默丢掉坏配置后宣称完整加载成功。

### 9. 验收标准

| 编号 | 场景 | 必须验证的结果 |
|---|---|---|
| PN-01 | 合法 IPv4 / IPv6 节点 | 保留 UUID、实际地址、协议、算法、密码字节和超时 |
| PN-02 | Unix 域套接字、端口 0 | 构造失败，不能延迟到业务拨号 |
| PN-03 | IPv6 作用域、IPv4 映射 IPv6 实际端点 | 保留真实端点信息，不用逻辑地址替换 |
| PN-04 | 超时 0、负数、1、30_000、上限及上限加 1 | 边界精确，无饱和或截断 |
| PN-05 | 旧配置 30 秒、正的小数秒、NaN、无穷大 | 正常转换与向上取整明确，非有限或溢出值拒绝 |
| PN-06 | 空密码、空格密码、Unicode 密码 | 空密码拒绝；其余原 UTF-8 字节不变 |
| PN-07 | 同 UUID 不同字段、规范等价但字节不同的密码 | 配置不相等；Set 不错误合并 |
| PN-08 | 四个 ProxyCipher | 每个尺寸均断言第 4 节的字面量，原始值精确往返 |
| PN-09 | 未知协议和算法原始值 | 导入失败，无默认回退 |
| PN-10 | 重复 UUID、不同 UUID 重复端点、同 UUID 换端点 | Core 集合行为和反向映射正确 |
| PN-11 | 默认节点缺失与规则节点缺失 | 前者在全表装载后失败，后者在命中时失败；均不降级 DIRECT |
| PN-12 | 两条 TCP 连接及多个 UDP 数据报 | Wire 状态按真实生命周期隔离 |
| PN-13 | 仅构造或比较节点 | 不执行 DNS、密码派生、加密初始化或网络 I/O |
| PN-14 | 非法配置错误及诊断 | 包含可定位字段，绝不包含密码或派生密钥 |

这些为待实现验收项。现有 `ProxyNodeTests` 主要证明加密算法参数，不代表新增的节点构造和集合契约已经全部验收。

### 10. 相关文件

- [当前 ProxyNode / ProxyNodeType](../Sources/Model/ProxyNode.swift)
- [当前 ProxyCipher](../Sources/Model/ProxyCipher.swift)
- [当前节点及加密算法测试](../Tests/Model/ProxyNodeTests.swift)
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

原始值按上述拼写精确导入。未知值必须失败，不当作普通域名或忽略。

移除当前 `urlRegex = "URL-REGEX"` 的“模型接受、Core 拒绝”状态。当前路由匹配入口收到的是 `NetworkAddress`，没有完整 URL，无法正确执行 URL 正则匹配；首版不暴露该枚举分支。历史 URL 规则在应用迁移时明确报为不支持，不能静默跳过或改成域名关键字。

以后若支持 URL、端口或来源匹配，必须先明确输入和协议可见性，再扩展规则与缓存键。不能仅添加枚举名称就宣称路由已支持。

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

首版不添加没有执行路径的 REJECT、自动选择、回退链或代理分组枚举分支。节点不可用、没有规则和明确直连是不同状态，不能用同一个空值合并。

`Hashable` 使用枚举分支和 UUID，不能把节点当前配置或 Wire 实例放入决策值。首版不为关联值枚举增加自动 Codable；应用持久化若使用 `direct` / `proxy` 文本和节点关联，必须显式组合并校验，不能依赖 Swift 自动合成的序列化布局。

### 5. 域名精确规则与后缀规则

这两种规则使用与 NetworkAddress 相同的 ASCII 标签结构约束：小写、每标签 `1...63` 字节、非空标签、总长上限 253 字节，允许输入单个末尾根点，保存时去掉该根点。

规则文本不去除首尾空白，不删除前导点，不折叠多个根点，不接受 `*`、URL 或带端口的主机地址。`.example.com` 不是隐式后缀语法；应显式选择 `.domainSuffix` 并传入 `example.com`。

共用的是纯主机名标签校验，不是通过构造一个端口为 0 的假目标来校验规则。可以在现有地址或规则所属类型中共享被多个生产路径使用的纯语法方法；不要新增校验器包装文件。

两种规则的语义分别为：

| 规则 | 匹配 | 不匹配 |
|---|---|---|
| exactDomain `example.com` | 域名目标 `example.com`、`EXAMPLE.COM.` | `api.example.com`、数值 IP 目标 |
| domainSuffix `example.com` | `example.com`、`api.example.com`、更深子域名 | `notexample.com`、`example.com.evil`、数值 IP 目标 |

后缀比较必须以 DNS 标签为边界，不能使用没有边界检查的普通字符串 endsWith。

exactDomain 若是 NetworkAddress 会识别为 IP 或拒绝的纯数值歧义表达，应在规则构造时拒绝，并提示使用 IP-CIDR；不能产生一条永远不参与 IP 匹配的伪域名 IP 规则。domainSuffix 表达的是标签后缀，可以包含数字标签，例如 `0.1` 可以匹配域名 `a.0.1`；它始终只作用于域名目标，不把某个 IPv4 地址按点拆成域名匹配。

目标域名的匹配视图由 Core 去掉一个根点，目标自身仍保留根点供解析和 Wire 转发；规则构造不能修改目标对象。

### 6. 域名关键字规则

`domainKeyword` 是对规范化域名匹配名称的 ASCII 字面子串匹配，不是完整主机名、通配模式或正则表达式。

- 输入长度为 `1...253` 字节，转为 ASCII 小写。
- 允许字母、数字、点和连字符；这些字符可以位于关键字边缘，因为关键字可能是名称片段。
- 拒绝空值、空白、控制字符、Unicode、URL 分隔符及正则/通配符符号；不去除输入首尾空白。
- 不要求关键字自身满足完整主机名标签结构，不能直接复用 exactDomain 的全部验证。
- 只作用于域名目标，不执行 PTR、DNS 或从某个 IP 猜测域名。

例如关键字 `api` 可以匹配 `api.example.com` 和 `myapiv2.example.com`；关键字 `api.` 可以匹配前者而不匹配后者。此匹配不具有 domainSuffix 的标签边界保证，应用需要标签边界时应选择后缀规则。

### 7. CIDR 规则

CIDR 构造仅接受严格数值 IP 和可选的一个 `/prefix`，不访问 DNS。省略前缀时 IPv4 使用 `/32`，IPv6 使用 `/128`；显式前缀只接受非空十进制数字，禁止符号、内部空白、额外斜线和越界值。前缀的十进制前导零可接受，输出时去掉。

普通 IP 解析、歧义数字拒绝和作用域文本拒绝与 NetworkAddress 的数值语法一致，但 CIDR 解析必须保留原始 IPv6 位宽，先处理前缀与 IPv4 映射 IPv6 的关系，再生成规范化网络，不能先丢掉 96 位再解释原前缀。

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

原地址是 IPv4 映射 IPv6 时，仅接受 `/96.../128`，转换为 IPv4 后将前缀减 96。对映射地址字面量指定小于 96 的前缀会跨出映射区间，本章明确拒绝，不能简单减法、截断或悄悄把整个范围当作 IPv4。

原生 IPv6 范围保留 IPv6。规则匹配按规范化后的地址族区分：IPv4 目标只匹配 IPv4 CIDR，原生 IPv6 目标只匹配 IPv6 CIDR；`::/0` 不因为包含某些映射字节表示就匹配已经归为 IPv4 的目标。

网络存储在构造时清零所有主机位，保存 `[UInt8]` 与前缀。Core 做集合索引和包含判断时直接读取这些值，不重复解析文本、重复清零主机位或建立另一份等价的 NetworkCIDR 包装。

### 8. order、匹配身份与相等性

`order` 是显式优先级，数值越小越优先。允许完整 Int 范围，包括负数；比较时使用关系运算，不以相减方式判断先后，避免 Int.min / Int.max 溢出。

规则值相等性与集合覆盖身份必须分开：

- `ProxyRule ==` / Hashable 比较规范化 `Match`、`Decision` 和 `order`。不同动作或优先级是不同配置值。
- Core 的覆盖键只使用规范化 `Match`，不包含 decision / order；等价 CIDR 和域名大小写/根点变体得到相同键。
- 同一覆盖键的最后一条配置生效，同时使用最后一条在输入数组中的位置参加后续比较。
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

一个更小 order 的后缀或关键字必须胜过更大 order 的精确域名；命中精确匹配索引后不能立即返回。规则为空或全部未命中时才应用 defaultDecision。

规则不读取端口，因此首版路由缓存键可以忽略端口。未来增加端口或其他匹配维度时，必须同步升级键，不能只修改规则枚举。缓存保存 Decision，不保存某条 TCP Wire 的加密状态。

### 10. 错误、导入和迁移

规则结构或匹配文本不符合本章时，由规则构造入口抛出 `MagentError.invalidPolicy`。不要先捕获地址辅助方法的错误再重命名；共享纯语法检查应提供合适的内部解析结果，由实际拥有规则输入的边界产生自己的错误。

构造时不检查节点存在性，不执行 DNS，不创建正则对象或 Wire。关联的 ProxyNode、实际目标、运行时路由错误在对应职责边界原样传播。

首版不为整个 ProxyRule 增加自动 Codable。应用导入显式解析 MatchType、Decision、order 和匹配文本，再调用唯一构造入口；无效原始值、PROXY 动作缺少必填 UUID 和不支持的 URL-REGEX 必须报告，不能静默忽略。合法 UUID 对应的节点是否存在，仍按第 4 节在 Core 的对应边界检查。若将来需要模型 Codable，解码必须回到同一验证入口，不依赖自动合成内部 Match 的格式。

相对于当前实现，迁移包括：

1. 将字符串匹配字段改为规范化 Match 存储，保留只读的 matchType / matchValue 视图。
2. 将 CIDR 的解析、主机位清零和规范化身份收归规则模型；Core 保留匹配和索引。
3. 移除 MatchType.urlRegex 及 Core 对该“已构造但不可执行规则”的延迟拒绝路径。
4. 统一域名规则的严格输入策略，不再通过去除首尾空白或任意首尾点修复非法值。
5. Core 用明确的具体性比较代替跨类别魔法分数，并保留既定的 order、覆盖和稳定决胜顺序。
6. 更新应用导入、持久化转换和测试；旧规则的失效不能通过少装几条规则掩盖。

先前的 NetworkAddress / HttpProtocol 章节继续适用。本章不要求把关联枚举改成嵌套公共 API，也不默认合并其现有文件。

### 11. 验收标准

| 编号 | 场景 | 必须验证的结果 |
|---|---|---|
| PR-01 | 四个 MatchType 与原始值 | 精确导入和往返，未知类型及 URL-REGEX 明确失败 |
| PR-02 | 域名大小写、单根点、空白、前导点和多根点 | 大小写/单根点规范化；非法修复式输入拒绝 |
| PR-03 | 精确匹配与后缀匹配的边界 | 第 5 节匹配/不匹配向量精确成立 |
| PR-04 | 精确匹配数值文本、后缀匹配数字标签、数值目标 | 精确匹配伪 IP 规则拒绝，合法标签后缀可用，IP 不走域名分支 |
| PR-05 | 关键字 api、api.、空值、非法字符及 253/254 长度 | 子串语义明确，不套用完整域名标签检查 |
| PR-06 | IPv4 / IPv6 /0、主机前缀和缺省前缀 | 精确清零主机位，格式和存储一致 |
| PR-07 | 前缀越界、负号、正号、空前缀、多个斜线、作用域、域名 | 在构造时失败，不等待 Core 再解析 |
| PR-08 | IPv4 映射 IPv6 /96、/120、/128、缺省和 /95 | 合法范围对应 IPv4 前缀，小于 96 明确拒绝 |
| PR-09 | 等价 CIDR、域名变体、不同 Decision / order | 覆盖键与完整规则相等性各自正确 |
| PR-10 | 重复规则的最后配置与输入位置 | 使用最后值及其位置，不能保留第一次的决胜位置 |
| PR-11 | 不同 order 的精确匹配、后缀匹配、关键字匹配 | order 优先，不能按索引命中顺序提前返回 |
| PR-12 | 同 order 的类型、后缀深度、关键字长度、CIDR 长度 | 精确执行第 9 节比较，不依赖字典顺序 |
| PR-13 | Int.min / Int.max 以及同优先级同具体性 | 无比较溢出，稳定采用较早保留位置 |
| PR-14 | 无规则、无匹配、命中缺失节点 | 前两者使用默认决策；后者失败，不回退直连 |
| PR-15 | 相同主机名不同端口、域名根点、映射数值目标 | 与 NetworkAddress 及路由缓存语义一致 |
| PR-16 | direct / proxy(UUID) | 动作与 UUID 身份明确，没有假节点和特殊零值 |
| PR-17 | Core 消费规则 | 直接使用解析结果，不再次解析 CIDR 或丢弃模型验证结果 |
| PR-18 | 单纯规则构造、导入和比较 | 无 DNS、节点查找、网络 I/O、Wire 创建或正则编译 |

单个模型验收使用字面量期望的字符串、网络字节、前缀、动作和优先级；集合用例必须通过 Core 的真实选择路径验证。手工检查排序不变量不能代替未来的 Core 回归测试。

### 12. 相关文件与验证边界

- [当前 ProxyRule](../Sources/Model/ProxyRule.swift)
- [当前 MatchType](../Sources/Model/MatchType.swift)
- [当前 Decision](../Sources/Model/Decision.swift)
- [当前 Core 与路由器](../Sources/Core/MagentCore.swift)
- [当前 Core 测试](../Tests/Core/MagentCoreTests.swift)

本章定义模型的目标功能与约束；源码是否满足这些要求，需要按本章验收场景独立验证。

实现两个模型后，应完成节点与加密算法、规则与 Core 的定向验收，并按项目规定执行构建、启用完整严格并发检查的构建、ConnectionTests、全包测试及实际修改 Swift 文件的严格格式检查和 `git diff --check`。应用节点导入、秒到毫秒迁移和规则持久化转换需要独立验证；文档阶段只检查结构、链接、示例不变量和修改范围。
