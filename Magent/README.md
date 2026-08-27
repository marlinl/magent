# Magent

Magent 是基于 SwiftNIO 的本地代理服务类库。应用通过一个 `MagentConfig` 启动服务，
Magent 自己创建并管理 TCP listener、accepted TCP connections、出站 channels 和
`MultiThreadedEventLoopGroup`。

当前支持：

- HTTP/1.0、HTTP/1.1 CONNECT。
- 受限的单请求 HTTP/1.x forward。
- SOCKS4、SOCKS4a CONNECT。
- SOCKS5 no-auth CONNECT。
- SOCKS5 control connection 独占的 UDP relay 数据面。
- direct 和 Shadowsocks AEAD TCP/UDP 出站。
- exact domain、domain suffix、domain keyword、IPv4/IPv6 CIDR 路由规则。

完整的产品边界、RFC 能力声明和上线状态见
[`docs/Magent/Magent_Design.md`](../docs/Magent/Magent_Design.md)。

## 安装

```swift
.package(url: "https://github.com/marlinl/magent.git", branch: "master")
```

```swift
.product(name: "Magent", package: "magent")
```

## 启动

```swift
import Magent
import NIOCore

let proxyAddress = try SocketAddress.makeAddressResolvingHost("proxy.example.com", port: 8388)
let node = ProxyNode(
    address: proxyAddress,
    cipher: .chacha20IetfPoly1305,
    password: "sample-password",
    timeout: 10
)

let rules = [
    try ProxyRule(
        matchType: .domainSuffix,
        matchValue: "example.com",
        decision: .proxy(node.id),
        order: 0
    ),
]

let config = MagentConfig(
    address: .domain("127.0.0.1", port: 1080),
    defaultDecision: .direct,
    defaultProxyNode: node,
    enableMatchTable: true,
    maxAcceptedConnections: 256,
    rules: rules,
    dnsServers: [try SocketAddress(ipAddress: "1.1.1.1", port: 53)]
)

let magent = Magent(threadNumber: 2)
try await magent.start(config)
```

`start(_:)` 绑定配置地址的 TCP listener。HTTP/SOCKS 协议探测、local reply、规则匹配、
目标建连和双向转发全部由 Magent 内部完成；SOCKS5 UDP ASSOCIATE 成功后按 control
connection 创建随机端口的 UDP relay。

生命周期方法是 actor 隔离的同步边界，从 actor 外调用需要 `await`。不要从 Magent 自己的
NIO EventLoop 中调用 `start`、`restart` 或 `close`。

## 配置切换与关闭

```swift
try await magent.restart(newConfig)

// 最终停止。
try await magent.close()
```

`restart(_:)` 使用同一个 EventLoopGroup 创建新的 Core 和 TCP listener，并结束旧运行周期。
accepted connection 额度由 `Magent` 实例持有；restart 期间尚未完成关闭的旧 connection 仍占用额度，
直到对应 Channel 的 `closeFuture` 完成。
`close()` 关闭当前 listener、accepted/backend channels，随后关闭 Magent 自己的
EventLoopGroup。

`close()` 是当前 `Magent` 实例的终止操作。关闭后需要再次运行时，应创建新的 `Magent`
实例；运行中切换配置使用 `restart(_:)`。

## 路由与节点

`MagentConfig` 是一次 start/restart 的完整配置：

- `address`：TCP listener 的 bind 地址。
- `defaultDecision`：未命中规则或关闭匹配表时的决策。
- `defaultProxyNode`：Core 初始化时注册的默认代理节点。
- `enableMatchTable`：是否执行规则匹配。
- `maxAcceptedConnections`：当前 `Magent` 实例允许同时持有的 accepted TCP connection 总数，
  默认 256；超限的新 connection 会立即关闭。
- `rules`：按 `order` 匹配的规则。
- `proxyNodes`：默认节点之外的代理节点。
- `dnsServers`：SOCKS5 UDP 直连域名使用的远端 DNS 地址；为空时拒绝直连域名目标。

`.direct` 连接原始目标；`.proxy(nodeID)` 使用对应节点的 Wire。找不到代理节点时请求失败，
不会降级为明文直连。代理 TCP connect timeout 从 `ProxyNode.timeout` 动态取得。

## SOCKS5 UDP

每条 SOCKS5 UDP ASSOCIATE control connection 创建一个绑定系统随机端口的 UDP relay。
SOCKS5 success reply 使用 control connection 的本地 IP 和该随机端口；首个 UDP datagram
确定客户端 source `IP:port`。关闭 control connection 会关闭对应 UDP relay。每条 association
只能属于一条 accepted control connection，因此 `maxAcceptedConnections` 同时给 association
及其 UDP/DNS Channel 数量建立服务级上界。

relay 固定使用 IPv4，IPv4 relay/outbound 与 IPv6 outbound 各自使用一个 Channel；具体出站
Channel 只由最终远端 `SocketAddress` 的地址族决定。直连域名通过 `dnsServers` 异步解析，
代理域名保持域名形式交给 Wire。当前只支持 `FRAG=0`；非零 fragmentation 会结束当前
association。

## 当前协议边界

- HTTP forward 只支持一条请求，拒绝 chunked、pipelining 和后续 keep-alive 请求。
- HTTP forward 不支持 `https://` absolute-form；HTTPS 客户端应使用 CONNECT。
- SOCKS4、SOCKS5 和 HTTP CONNECT 不接受 success reply 前提前发送的 tunnel payload。
- SOCKS4 不支持 BIND、ident authentication 和原生 IPv6。
- SOCKS5 只支持 no-auth，不支持 BIND、GSSAPI 和 username/password。
- HTTP/2、HTTP/3 和 Extended CONNECT 当前不支持。

## 监听与安全

Magent 允许配置 loopback、局域网地址、具体公网接口或 `0.0.0.0`。HTTP、SOCKS4 和
SOCKS5 前端当前没有本地用户认证。开放监听是受支持的产品能力，但部署方必须自行承担
防火墙、安全组、来源限制和凭据保护。

不要把真实 Shadowsocks 密码、节点地址或用户代理设置提交到仓库。

## 所有权

- App 负责平台权限、UI、配置持久化、系统代理或 Network Extension 集成。
- `Magent` 拥有并关闭 EventLoopGroup 和 TCP listener。
- `MagentTCPConnection` 拥有 accepted TCP channel 的代理生命周期。
- 每条 TCP stream 使用独立的 Shadowsocks TCP Wire、salt、nonce 和 frame buffer。
- `Socks5Connection` 拥有对应 control connection 的 UDP relay，control connection 关闭时回收。

## 构建与测试

从 `Magent/` 目录执行：

```bash
swift build
swift build -Xswiftc -strict-concurrency=complete
swift build -c release
swift test --filter ConnectionTests
swift test
git diff --check
```
