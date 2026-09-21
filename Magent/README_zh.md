# Magent

[English](README.md) | 中文

Magent 是基于 SwiftNIO 的代理服务类库，用于在应用中嵌入 HTTP 和 SOCKS 代理能力。
配置一个 `Magent` 实例并启动本地监听后，类库负责协议识别、路由、连接管理和数据转发。

应用负责界面、持久化、平台权限，以及系统代理或 Network Extension 集成；Magent 负责管理自身的网络资源。

## 功能

- HTTP CONNECT 与受限的 HTTP 正向代理。
- SOCKS4、SOCKS4a、SOCKS5 CONNECT，以及 SOCKS5 UDP ASSOCIATE。
- 直连与 Shadowsocks AEAD TCP/UDP 转发。
- 完整域名、域名后缀、域名关键字和 IPv4/IPv6 CIDR 路由规则。
- 每条 Shadowsocks TCP 流使用独立的加密状态。
- 通过 `restart(_:)` 整体替换运行配置。

支持的加密方法包括 `aes-128-gcm`、`aes-256-gcm`、
`chacha20-ietf-poly1305` 和 `xchacha20-ietf-poly1305`。

## 环境要求

- Swift 6.4 或更高版本，具体要求见 [Package.swift](Package.swift)。
- 包清单声明的 Apple 平台最低版本为 macOS 14 和 iOS 17。
- 宿主应用具备打开监听和出站套接字的权限。

## 安装

Swift 包位于仓库的 `Magent/` 子目录。先克隆仓库，再在 Xcode 中将该目录添加为本地 Swift 包：

```bash
git clone https://github.com/marlinl/magent.git
```

如果使用另一个 Swift 包接入，在其 `dependencies` 数组中添加以下条目。
本地路径相对于使用方的包目录，请按实际克隆位置调整。
节点和 DNS 示例会使用 `NIOCore.SocketAddress`，因此这里显式声明 SwiftNIO 依赖。

```swift
.package(path: "../magent/Magent"),
.package(url: "https://github.com/apple/swift-nio.git", from: "2.102.0"),
```

在使用方 target 的 `dependencies` 数组中添加以下产品：

```swift
.product(name: "Magent", package: "Magent"),
.product(name: "NIOCore", package: "swift-nio"),
```

## 快速开始

在应用的异步上下文中执行以下代码，即可在 `127.0.0.1:1080` 启动代理，并直连客户端请求的目标。
这种配置不需要代理节点。

```swift
import Magent

let listenAddress = NetworkAddress.domain("127.0.0.1", port: 1080)
let service = Magent(threadNumber: 2)
let directConfig = MagentConfig(listener: listenAddress)

try await service.start(directConfig)
```

保持应用运行，并持有该服务实例，以便后续切换配置或关闭服务。
客户端可以通过同一个 TCP 监听端口使用 HTTP CONNECT、HTTP 正向代理或 SOCKS，Magent 会自动识别协议。

## 路由与代理节点

所有代理节点统一放在 `proxyNodes` 中，`.proxy(node.id)` 决策通过 UUID 选择其中的节点。
下面的示例分别创建全局代理配置，以及仅代理命中规则域名的配置。

示例中的代理服务器 IP、DNS IP 和密码均为占位值。使用这些代理配置前，请替换为自己的实际设置。

```swift
import NIOCore

let node = ProxyNode(
    address: try SocketAddress(ipAddress: "192.0.2.10", port: 8388),
    cipher: .chacha20IetfPoly1305,
    password: "replace-with-your-password",
    timeout: 10
)

let globalConfig = MagentConfig(
    listener: listenAddress,
    defaultDecision: .proxy(node.id),
    proxyNodes: [node]
)

let rule = try ProxyRule(
    matchType: .domainSuffix,
    matchValue: "example.com",
    decision: .proxy(node.id),
    order: 0
)

let ruleConfig = MagentConfig(
    listener: listenAddress,
    rules: [rule],
    proxyNodes: [node],
    dnsListener: try SocketAddress(ipAddress: "192.0.2.53", port: 53)
)
```

| 模式 | 规则 | 默认决策 |
| --- | --- | --- |
| 全部直连 | 空数组 | `.direct` |
| 全局代理 | 空数组 | `.proxy(node.id)` |
| 按规则路由 | 本次运行使用的规则 | 未命中规则时采用 |

`order` 越小，规则优先级越高。规则为空或没有规则命中时，使用 `defaultDecision`。
如果 `defaultDecision` 引用的节点不存在，会在 Core 初始化时失败，此时尚未绑定新监听；
在 `restart` 中发生该错误时，旧运行周期继续运行。规则引用缺失节点则在使用该路由时失败。
这两种情况都不会降级为直连。路由器目前不支持 `urlRegex` 枚举值。

## 配置参数

`MagentConfig` 描述一次启动或重启的完整配置，只有 `listener` 必填。

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `listener` | 必填 | 本地 TCP 监听地址；端口必须在 `1...65535` 范围内。 |
| `defaultDecision` | `.direct` | 规则为空或未命中时采用的决策。 |
| `rules` | `[]` | 本次运行参与匹配的规则。 |
| `proxyNodes` | `[]` | 所有可用节点，包含默认决策选中的节点。 |
| `defaultTimeout` | `10_000` | 直连 TCP 建连和 UDP DNS 查询的超时时间，单位为毫秒。 |
| `dnsListener` | `nil` | UDP 直连域名目标使用的单个 DNS 服务器地址。 |

代理 TCP 建连使用 `ProxyNode.timeout`，单位为**秒**，默认值为 `30`。
它与使用毫秒的 `MagentConfig.defaultTimeout` 不同。

`dnsListener` 仅影响 SOCKS5 UDP 直连域名解析。为 `nil` 时，UDP IP 目标和经代理访问的域名目标仍然可用，
但 UDP 直连域名目标会被拒绝。该参数不覆盖 TCP 域名解析行为，也不提供第二个 DNS 服务器的回退。

Magent 不设置应用层连接数上限。EventLoop 线程数和监听 backlog 均不代表已建立连接的数量上限；
实际承载能力取决于文件描述符、内存和处理负载。

## 切换配置与关闭

沿用快速开始中已经启动的服务实例：

```swift
try await service.restart(ruleConfig)

// 应用不再使用代理服务时：
try await service.close()
```

`restart(_:)` 创建新的运行周期并替换监听，同时复用服务持有的 EventLoopGroup。
旧运行周期的连接会被关闭，因此它不会无缝保留已有隧道。
启动后修改原配置值，不会改变已经运行的服务。

将 `close()` 视为当前实例的终止操作。关闭后如需再次启动，应创建新的 `Magent` 实例。
`start`、`restart` 和 `close` 必须从 NIO EventLoop 之外调用，因为这些 actor 隔离的生命周期方法
会在内部等待 NIO Future 完成。从 actor 外部调用时使用 `await`。

## 协议支持范围

- **HTTP：** 支持 HTTP/1.0 和 HTTP/1.1 CONNECT。HTTP 正向代理每条连接只处理一个请求，
  拒绝 chunked framing、流水线请求和后续 keep-alive 请求。HTTPS 应使用 CONNECT，
  不支持以 `https://` absolute-form 发起正向代理请求。
- **SOCKS4/SOCKS4a：** 支持 CONNECT，不支持 BIND、ident 认证和 SOCKS4 原生 IPv6 地址。
- **SOCKS5：** 支持无认证 CONNECT 和 UDP ASSOCIATE，不支持 BIND、GSSAPI 和用户名/密码认证。
- **握手顺序：** SOCKS4、SOCKS5 和 HTTP CONNECT 会拒绝完整握手请求之后、本地成功响应之前发送的载荷字节。
- **UDP：** 每条 SOCKS5 控制连接独占一个临时 relay 端口。目前要求控制连接使用 IPv4，
  出站目标可以使用 IPv4、IPv6 或域名。关闭控制连接会回收其 UDP 和 DNS 资源。
  仅支持 `FRAG=0`，分片数据报会被拒绝。
- **其他 HTTP 版本：** 不支持 HTTP/2、HTTP/3 和 Extended CONNECT。

以上描述当前已实现的协议边界，不表示完整符合 HTTP 或 SOCKS RFC。

## 部署职责

应用决定使用回环、局域网或通配监听地址。目前本地代理协议入口不提供客户端认证，
因此对外开放监听的应用需要自行设置访问控制。

Magent 不负责配置操作系统代理、申请平台权限或持久化节点凭据，这些职责属于宿主应用。
不要将真实服务器地址、密码和本地用户设置提交到源码仓库。

## 开发

在仓库的 `Magent/` 目录执行包命令：

```bash
swift build
swift build -Xswiftc -strict-concurrency=complete
swift build -c release
swift test --filter ConnectionTests
swift test --filter AeadCipherTests
swift test
git diff --check
```

测试覆盖路由、报文解析、加密、连接生命周期和本地 TCP/UDP 转发。
套接字测试需要本地网络权限；依赖 IPv6 回环的测试会在环境不支持时报告跳过。

代码格式使用所选 Xcode 工具链自带的官方 `swift-format`。
格式化通过命令显式执行，不作为 SwiftPM build-tool plugin 随每次构建运行：

```bash
xcrun swift-format format --in-place --parallel --recursive Package.swift Sources Tests
xcrun swift-format lint --strict --parallel --recursive Package.swift Sources Tests
```

| 目录 | 内容 |
| --- | --- |
| `Sources/Connection` | 协议识别、客户端握手与转发。 |
| `Sources/Core` | 路由、节点选择、Channel 创建与缓存。 |
| `Sources/Model` | 地址、节点、规则与协议类型。 |
| `Sources/Wire/Shadowsocks` | Shadowsocks 分帧、地址编码与 AEAD 加密。 |
| `Tests` | XCTest 单元测试与本地网络测试。 |
| `docs` | 架构、协议、路由、缓存设计与模型映射。 |

## 许可证与贡献

除个别文件或第三方组件另有声明外，Magent 使用 [GPL-3.0-only](../LICENSE) 许可证。
贡献遵循 [Magent 贡献者许可协议](../CLA.md)。
