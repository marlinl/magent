---
desc: Magent类库当前公开API、路由、TCP和UDP连接架构及生命周期总览
updated_at: 2026-07-28
commit: 9c6216b
---

# Magent 网络代理类库产品设计文档

## 0. 文档目标

本文是 `Magent/` Swift package 的当前实现总览。内容以 commit `9c6216b` 的
`Magent/Sources` 为准，不再保留已删除的 `MagentClient`、`attach(channel:)`、
`CoreService.shared`、`DirectNodeWire`、Transport wrapper 或公开 `MagentConnection`
方案。

协议细节见同目录四份 4C 文档：

- `Magent_HTTP_CONNECT_Proxy_4C_Design.md`
- `Magent_HTTP_FORWARD_Proxy_4C_Design.md`
- `Magent_SOCKS4_Proxy_4C_Design.md`
- `Magent_SOCKS5_Proxy_4C_Design.md`

# 1. Context

## 1.1 项目定位

Magent 是 SwiftNIO 实现的本地正向代理类库。当前 package 支持 macOS 14+ 和 iOS 17+，提供：

- HTTP CONNECT。
- HTTP forward 单请求。
- SOCKS4/SOCKS4a CONNECT。
- SOCKS5 no-auth CONNECT。
- SOCKS5 UDP ASSOCIATE 和 control connection 独占 UDP relay。
- direct 路由。
- Shadowsocks AEAD TCP/UDP 出站。
- exact domain、domain suffix、domain keyword、IPv4/IPv6 CIDR 规则。

`Magent` 自己创建并拥有：

- `MultiThreadedEventLoopGroup`。
- TCP listener。
- accepted TCP connection。
- direct/proxy TCP `wireChannel`。
- 每条 SOCKS5 control connection 创建的 UDP relay/outbound Channel。

App 只负责构造配置并调用 `start`、`restart`、`close`。当前实现不是“App 创建 listener 后把
accepted Channel attach 给 library”的模型。

## 1.2 产品边界

- Magent 允许绑定 loopback、局域网地址、具体公网接口或 `0.0.0.0`。
- HTTP、SOCKS4 和 SOCKS5 当前都没有本地用户认证。
- 无认证开放代理是支持的产品能力，不强制 loopback、来源 ACL 或认证。
- 平台网络权限、防火墙、安全组、Network Extension 和进程生命周期由 App/部署环境负责。
- Magent 不持久化节点或规则；持久化模型属于 MagentX/iMagent 等 App。

## 1.3 总体结构

```text
App
  -> Magent actor
       -> MultiThreadedEventLoopGroup
       -> TCP ServerBootstrap
            -> MagentTCPConnection
                 -> Socks4Connection
                 -> Socks5Connection
                      -> per-control UDP relay/outbound DatagramChannel
                 -> HttpConnectConnection
                 -> HttpForwardConnection
       -> MagentCore
            -> MagentRouter
            -> route cache
            -> ProxyNode tables
            -> Shadowsocks TCP/UDP Wire
```

# 2. Contract

## 2.1 公开 API

当前主要公开类型：

| 类型 | 职责 |
| --- | --- |
| `Magent` | 服务 actor 和生命周期入口 |
| `MagentConfig` | 单次 start/restart 的完整运行配置 |
| `NetworkAddress` | IPv4、IPv6、domain 和端口 |
| `ProxyNode` | Shadowsocks 节点、cipher、密码、timeout |
| `ProxyRule` | 一条规范化路由规则 |
| `MatchType` | exact/suffix/keyword/CIDR/urlRegex |
| `Decision` | `.direct` 或 `.proxy(UUID)` |
| `MagentError` | 配置、协议、节点、Channel、crypto 和生命周期错误 |

基本用法：

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
    address: .domain("0.0.0.0", port: 1080),
    defaultDecision: .direct,
    defaultProxyNode: node,
    enableMatchTable: true,
    maxAcceptedConnections: 256,
    defaultTimeout: 10_000,
    rules: rules,
    proxyNodes: [node],
    dnsServers: [try SocketAddress(ipAddress: "1.1.1.1", port: 53)]
)

let magent = Magent(threadNumber: 2)
try await magent.start(config)

// 配置整体切换。
try await magent.restart(config)

// 最终关闭。
try await magent.close()
```

`Magent` 是 actor。其方法声明虽然是同步 `throws`，从 actor 外调用仍需要 `await`。调用方不能从
Magent 自己的 NIO EventLoop 内调用这些同步生命周期边界。

## 2.2 MagentConfig

| 字段 | 语义 |
| --- | --- |
| `address` | TCP listener 的 bind 地址和端口 |
| `maxAcceptedConnections` | 当前 `Magent` 实例允许同时持有的 accepted TCP connection 总数；默认 256，必须大于 0 |
| `defaultTimeout` | direct TCP connect 和 SOCKS5 UDP 直连 DNS 查询的超时毫秒数 |
| `dnsServers` | SOCKS5 UDP 直连域名目标使用的远端 DNS server；空数组表示拒绝该能力 |
| `defaultDecision` | 未命中规则或关闭匹配表时的决策 |
| `defaultProxyNode` | Core 初始化时必定注册的默认节点 |
| `enableMatchTable` | 是否执行规则表；关闭后直接使用默认决策 |
| `rules` | 当前运行周期的完整规则数组 |
| `proxyNodes` | 默认节点之外追加注册的节点 |

`rules` 和 `proxyNodes` 是配置值，不是运行中热更新接口。`start/restart` 创建新的 `MagentCore`，
运行期间修改原 `MagentConfig` 不会改变已经启动的 Core。

## 2.3 NetworkAddress

```swift
public enum NetworkAddress {
    case ipv4(Data, port: Int)
    case ipv6(Data, port: Int)
    case domain(String, port: Int)
}
```

- IPv4 必须是 4 字节。
- IPv6 必须是 16 字节。
- SOCKS/HTTP 出站端口必须在 `1...65535`。
- `.unspecifiedIPv4` 是每条 SOCKS5 association 的内部 UDP relay/outbound bind 地址。
- domain 在 NIO 建连阶段由 `SocketAddress.makeAddressResolvingHost` 解析。

## 2.4 ProxyNode

当前只支持 `.shadowsocks`，cipher：

- `aes-128-gcm`
- `aes-256-gcm`
- `chacha20-ietf-poly1305`
- `xchacha20-ietf-poly1305`

`timeout` 的公开单位是秒。Wire 初始化时向上取整转换为正 `Int64` 毫秒；0、负数、NaN、无穷或
不能放入 `Int64` 的值会使 Core/启动失败。

`ProxyNode.address` 是启动前已经解析完成的 `SocketAddress`。同一 Core 中代理 endpoint 必须
唯一：不同 UUID 不能使用相同地址；同 UUID 更新地址时会删除旧 endpoint 映射。

## 2.5 ProxyRule

支持的匹配类型：

| MatchType | 当前 Core 行为 |
| --- | --- |
| `exactDomain` | 规范化后精确匹配 |
| `domainSuffix` | 按域名标签逐级匹配 |
| `domainKeyword` | 小写包含匹配 |
| `ipCIDR` | IPv4/IPv6 网络前缀匹配 |
| `urlRegex` | 构造时校验正则，但当前 `MagentRouter` 初始化会明确拒绝 |

排序规则：

1. `order` 更小优先。
2. `order` 相同时，更高特异度优先。
3. 仍相同时，初始化数组中更早的位置优先。

相同 `matchType + normalized matchValue` 重复出现时，最后一条覆盖前面的同值规则。route cache
按 domain/IP 缓存，不包含端口，因为当前规则不匹配端口。

## 2.6 Core 路由

TCP：

```swift
try core.routeTCPWire(target) -> Wire?
```

UDP：

```swift
try core.routeUDPWire(target) -> Wire?
```

共同语义：

- `.direct` 返回 `nil`。
- `.proxy(nodeID)` 返回对应 Wire。
- 节点或 UDP Wire 不存在时抛出 `proxyNodeNotFound`，绝不 fail-open 到直连。

TCP 每条 proxy connection 创建独立 `ShadowsocksTCPWire`，保证 salt、nonce、frame buffer 不跨
stream 共享。UDP Wire 按节点保存在 Core 中，因为每个 UDP packet 自带独立 salt/cipher 状态。

## 2.7 Wire

当前内部 `Wire` 契约：

```swift
func start(handshake address: NetworkAddress) throws -> Data?
func getTargetAddress() -> SocketAddress
func getTimeout() -> Int64
func encodeOutbound(_ data: Data, address: NetworkAddress?) throws -> Data
func decodeInbound(_ bytes: Data) throws -> InboundData
```

- TCP Wire 的 `start` 发送一次目标地址启动帧。
- `getTimeout()` 从当前 `ProxyNode.timeout` 转换得到毫秒值；代理 TCP 建连必须动态使用该值。
- TCP 后续 `encodeOutbound` 不再携带 target。
- UDP Wire 没有 stream start；每次 `encodeOutbound` 必须携带 target。
- `Wire` 不持有 NIO Channel，不生成 HTTP/SOCKS 本地响应。
- Direct 使用 `wire == nil`，当前没有 `DirectNodeWire`。

## 2.8 连接所有权

| Owner | 拥有内容 |
| --- | --- |
| `Magent` | group、TCP listener、运行周期 shutdown promise、跨 restart 共享的 accepted connection 计数器 |
| `MagentTCPConnection` | accepted `proxyChannel`、协议探测缓冲、具体 `ProxyConnection` |
| 具体 TCP connection | `wireChannel`、协议状态、首请求缓冲、TCP Wire |
| `Socks5Connection` | 当前 control connection 的 UDP relay、IPv4/IPv6 outbound Channel 和 DNS clients |
| UDP inbound handler | 首个 client source、实际远端 endpoint 到所选 Wire 的映射 |
| `MagentCore` | 路由表、route cache、节点映射、UDP Wires |

`ProxyConnection.closeConnection(error:)` 只关闭下游资源，不关闭 accepted `proxyChannel`；
accepted Channel 的所有权留在 `MagentTCPConnection`，从而避免循环 close。

# 3. Core Logic

## 3.1 start

```text
validate config
  -> 创建运行周期独有 MagentCore
  -> 创建 shutdown promise
  -> bind TCP listener
  -> 每个 child Channel 先获取 accepted connection 额度
     -> 超限：立即关闭
     -> 成功：closeFuture 完成时归还一次额度
  -> 成功后 state = running
```

TCP child pipeline 安装 `MagentTCPConnection`。start bind 失败会关闭已经创建的 Channel、
完成 shutdown promise，并 shutdown group。

## 3.2 restart

```text
validate new config
  -> 创建 new Core 和 new shutdown promise
  -> 关闭旧 TCP listener
  -> 完成旧 shutdown promise，旧 accepted connections 及其 UDP relay 开始关闭
  -> 保留同一个 EventLoopGroup
  -> bind 新 TCP listener
  -> state 指向新运行周期
```

新连接只使用新 Core。旧连接不会读取或覆盖新配置。当前 restart 是运行周期切换，不是保持所有旧
accepted connection 永久在线。accepted connection 计数器属于 `Magent` 实例而不是单次运行
周期；restart 后尚未关闭完成的旧 connection 继续占用额度，不能与新 listener 各自获得一套上限。

## 3.3 close

`close()`：

1. 关闭 TCP listener。
2. 完成运行周期 shutdown promise，accepted TCP 及其 UDP relay/outbound Channel 开始关闭。
3. `syncShutdownGracefully()` 回收 Magent 自己创建的 EventLoopGroup。
4. 状态进入 stop。

由于 group 已 shutdown，当前实例的 `close()` 应视为终止操作；需要继续运行时，在 close 前使用
`restart`，或 close 后创建新的 `Magent` 实例。

## 3.4 TCP 协议探测

`MagentTCPConnection` 累计首段 `ByteBuffer`：

- `0x04` -> SOCKS4。
- `0x05` -> SOCKS5。
- `CONNECT ` -> HTTP CONNECT。
- 合法 HTTP token method 后跟 origin/absolute target -> HTTP forward。
- 当前字节仍可能是 HTTP method 或 `http[s]://` target 前缀 -> 继续等待。
- 其他 -> unsupported error。

探测完成后只创建一个具体 connection，并把累计的所有字节交给它。后续 bytes 不再重复探测。

## 3.5 TCP 建连与转发

四条 TCP 路径使用相同路由原则：

```text
parse final target
  -> routeTCPWire(target)
  -> direct: connect target, timeout = config.defaultTimeout
  -> proxy: connect wire target, timeout = node timeout
  -> proxy path: wire.start(target)
  -> local protocol success response
  -> tunnel/forward payload
```

本地 success response：

| 协议 | response |
| --- | --- |
| SOCKS4 CONNECT | `0x5A` granted |
| SOCKS5 CONNECT | `REP = 0x00` |
| HTTP CONNECT | `200 Connection Established` |
| HTTP forward | 无单独 success response，直接发送 request |

`createTCPClientChannel` 的连接 Future 通过 future chain 继续，不在 EventLoop handler 内执行
`wait()`。accepted/wire Channel 都关闭 `autoRead`，每批输入在对端 `writeAndFlush` 完成后才读取
下一批；两端都允许 remote half-close，并把 input close 传播为对端 output close。

## 3.6 SOCKS5 UDP

每条 SOCKS5 `UDP ASSOCIATE` control connection 创建一组独占 UDP Channel。IPv4 relay/outbound
Channel 的随机端口写入 success reply；IPv6 outbound 使用同一 association 的第二个 Channel。
每个 datagram 独立解析 target 和路由：

```text
TCP control connection
  -> bind IPv4 relay/outbound 和 IPv6 outbound Channel
  -> success reply 返回 IPv4 relay 地址
  -> 首个 client UDP source 固定为 association peer
  -> parse SOCKS5 UDP header
  -> routeUDPWire(target)
  -> direct raw datagram 或 Shadowsocks UDP packet
  -> 按真实远端 endpoint 保存本次选择的 Wire
  -> response 解密/透传
  -> 封装 SOCKS5 UDP response
  -> 写回已固定的 client source IP:port
```

control connection 关闭会关闭这组 UDP Channel 和 DNS clients。UDP Channel 无 TCP connect
阶段，同一个 association Channel 可以向多个 target 发送 datagram，因此不应用 TCP
`connectTimeout`。`ProxyNode.timeout` 只控制 proxy TCP connect；`defaultTimeout` 还控制 direct
UDP 域名的远端 DNS query。

## 3.7 关闭传播

TCP：

```text
proxyChannel inactive/error
  -> MagentTCPConnection closed
  -> ProxyConnection.closeConnection
  -> close wireChannel

wireChannel inactive/error
  -> concrete connection closed/error
  -> close or fire error to proxyChannel
```

双方回调都先检查 `closed`。TCP input half-close 只关闭另一侧 output；完整 inactive/error 才进入
统一清理路径。

UDP：

- control connection close -> 当前 association 的 UDP Channel 和 DNS clients close。
- runtime shutdown future -> accepted control connection close -> UDP resources close。

# 4. Corners

## 4.1 当前协议边界

| 能力 | 当前状态 |
| --- | --- |
| HTTP CONNECT header 分片 | 支持 |
| HTTP CONNECT header + tunnel payload remainder | 拒绝 |
| HTTP forward 固定 Content-Length body | 支持 |
| HTTP forward chunked/pipelining/keep-alive 多请求 | 不支持 |
| SOCKS4/SOCKS4a request 分片 | 支持 |
| SOCKS4 request + payload remainder | 拒绝 |
| SOCKS5 greeting/request 分片 | 支持 |
| SOCKS5 greeting/request 与下一阶段粘包 | 拒绝 |
| SOCKS5 UDP FRAG | 只支持 0，其他值当前结束 association |
| URL regex 路由 | 当前 Core 不支持 |

握手 remainder 是当前明确采用并已有回归覆盖的严格顺序边界。

## 4.2 Timeout 与背压

已经实现：

- direct TCP connect timeout 使用 `MagentConfig.defaultTimeout`，默认 10 秒。
- proxy TCP connect timeout 使用 `ProxyNode.timeout`。
- SOCKS4 超时返回 rejected。
- SOCKS5 超时返回 host unreachable。
- HTTP CONNECT/forward 超时返回 504。
- accepted/wire Channel 使用 `autoRead = false`，每批写入完成后才读取下一批，限制单连接
  in-flight payload。
- `maxAcceptedConnections` 给服务实例的活跃 accepted TCP connection 建立硬上限，默认 256；
  超限 child Channel 立即关闭。
- TCP input half-close 会传播为另一侧 output close，并保留反方向读取。

尚未实现：

- TCP read idle timeout。
- TCP write timeout。

连接时限由第 5.3 节 `NEW-P1-2` 跟踪。UDP 不增加无意义的 connect timeout。

## 4.3 并发边界

- `Magent` actor 串行化 start/restart/close。
- accepted connection 额度通过 service-owned atomic counter 跨 EventLoop、跨 restart 统一竞争；
  额度只由对应 accepted Channel 的 `closeFuture` 归还一次。
- 每个 TCP connection 的状态只在所属 EventLoop 推进。
- `MagentCore` 的节点写入只发生在 start/restart 创建阶段；运行阶段没有 public mutation。
- TCP Wire 不跨连接共享。
- UDP Wire 每 packet 创建独立 AEAD cipher 和 salt。
- Channel handler 内不得同步等待尚未完成的 EventLoopFuture。

## 4.4 安全边界

- 本地前端无认证。
- 允许 `0.0.0.0` 和非 loopback。
- 密码只存在 `ProxyNode` 配置和 Wire key derivation，不应写入日志或提交真实配置。
- proxy 决策缺少节点时 fail closed。
- Shadowsocks UDP 回包按 association 出站时记录的真实代理 endpoint 选择 Wire。

## 4.5 当前验证基线

commit `9c6216b` 已验证：

```bash
swift build
swift build -Xswiftc -strict-concurrency=complete
swift build -c release
swift test --filter ConnectionTests
swift test
git diff --check
```

结果：

- 普通构建通过。
- strict concurrency 构建通过。
- release 构建通过。
- `ConnectionTests` 56/56。
- 全量测试 190/190。
- 三次构建及测试构建均执行 SwiftLint build-tool plugin。

## 4.6 发布前仍需完成

项目级上线问题、修复状态、RFC 能力边界和发布门禁只在第 5 节维护，本节不再保留第二份问题清单。
MagentX 持久化模型与 package 公共类型的映射见 `Magent_Model_SQL_Design.md`。

# 5. 上线审查（2026-07-28）

本节是对 commit `9c6216b` 的项目级审查，覆盖 `Magent/Sources`、`Magent/Tests`、
`Package.swift`、根 `README.md` 和仓库 `AGENTS.md`，并吸收原独立 RFC Gap
审计中经当前源码复核后仍成立的协议结论。
项目级问题状态和上线判断只以本节为准。

## 5.1 当前结论

**❌ 当前不满足公网、无人值守、长期运行的生产上线标准。**

核心路由、Shadowsocks Wire、TCP/UDP 基本链路、严格单批流控、half-close 和常规关闭路径已经
具备。Shadowsocks UDP 回包按实际 endpoint 关联 Wire，HTTP request 使用 NIOHTTP1 decoder，
并已拒绝 `Expect`、HTTPS absolute-form 和超限请求。服务级 accepted connection 上限同时约束
每条 accepted control connection 派生的 UDP association；但当前仍没有 read/write/idle
timeout、配置引用 fail-fast、完整 HTTP `Via` 与 SOCKS5 错误映射；CI 和 public `Magent`
端到端门禁也未完成。

在以下限制全部成立时，可以作为 **🟡 受控灰度版本**：

- 只绑定 loopback 或可信内网，不直接暴露给不受信任客户端。
- 根据进程文件描述符预算设置 `maxAcceptedConnections`（默认 256），在上层限制单连接生命周期，
  并监控内存与文件描述符。
- 不宣称完整 HTTP intermediary 或完整 RFC 1928；HTTPS 客户端使用 HTTP CONNECT。

## 5.2 已修复项目

| 编号 | 状态 | 已修复问题 | 当前证据 |
| --- | --- | --- | --- |
| FIX-1 | ✅ 已解决 | Connection handler 在 EventLoop 内同步 `.wait()`，可能死锁。 | 四个 TCP connection 使用 `EventLoopFuture` 和 `whenComplete`；UDP bind 使用异步 Future；单 EventLoop TCP/UDP liveness 测试通过。 |
| FIX-2 | ✅ 已解决 | proxy TCP 曾连接原始目标而不是 Wire 节点。 | SOCKS4、SOCKS5、HTTP CONNECT、HTTP Forward 均使用 `wire.getTargetAddress()` 建连，Shadowsocks handshake 仍编码原始目标。 |
| FIX-3 | ✅ 已解决 | Core singleton 导致实例和配置相互污染。 | `MagentCore` 由单个运行周期创建并注入 handler；节点和规则在 Core 创建阶段完成写入。 |
| FIX-4 | ✅ 已解决 | proxy 路由缺失节点时可能降级为 UDP 明文直连。 | TCP/UDP `.proxy` 缺少节点均抛出 `proxyNodeNotFound`，只有明确 `.direct` 才返回 `nil`。 |
| FIX-5 | ✅ 已解决 | 同一代理 endpoint 可能对应多个 UDP Wire。 | `putProxyNode` 拒绝不同 UUID 复用相同 `SocketAddress`；每条 association 还按实际远端 endpoint 保存出站时选择的 Wire。 |
| FIX-6 | ✅ 已解决 | UDP association 与 control connection 生命周期曾分离，可能遗留 backend Channel。 | 共享 cache/pending-bind 模型已删除；每条 control connection 独占固定 UDP Channel 和 DNS clients，control close 直接回收。 |
| FIX-7 | ✅ 已解决 | accepted TCP、wire TCP 和 UDP backend 的常规关闭链路不统一。 | 运行周期 shutdown future 关闭 accepted/backend Channel；具体 TCP connection 使用 `.closed` 守卫避免循环关闭。 |
| FIX-8 | ✅ 已解决 | `ProxyNode.timeout` 没有用于代理 TCP connect。 | `Wire.getTimeout()` 动态返回节点毫秒值，四个 proxy TCP 分支均传入 `createTCPClientChannel`。 |
| FIX-9 | ✅ 已解决 | HTTP forward 无法从协议探测入口到达。 | `.httpForward` 已安装 `HttpForwardConnection`，absolute-form 改写、header 清理、body 分片和拒绝 framing 已有回归测试。 |
| FIX-10 | ✅ 已解决 | cache shutdown、过期和容量边界缺少回归。 | cache unit/stress tests 覆盖 TTL、eviction、shutdown barrier、并发读写和瞬时容量边界。 |
| FIX-11 | ✅ 已解决 | 项目残留无引用的 cache/Core/connection 成员和仅供测试读取的 HTTP CONNECT method 字段。 | 已删除无引用声明、只赋值不读取成员、无效 UDP timeout 分支和冗余 parser 字段；保留 NIO/XCTest 间接入口及 `Wire.getTimeout()` 等真实契约。 |
| FIX-12 | ✅ 已解决 | package 根目录散落临时重构计划、审查状态和改动清单，且部分内容仍引用已删除的 `MagentClient.attach`、`CoreService` 等架构。 | 仍有效的修复状态、上线风险和设计边界已统一归入本文第 5 节；过时或重复的根目录文档已删除，package 根目录只保留 `README.md` 和 `AGENTS.md`。 |
| FIX-13 | ✅ 已解决 | RFC Gap 独立文档与主 Review 并存，审计基线和大量代码路径已经过期。 | 仍成立的 HTTP、SOCKS 和 TCP 生命周期问题及能力声明边界已合并到本节；已修复结论不重复保留，原独立文档已删除。 |
| FIX-14 | ✅ 已解决 | 原 `NEW-P0-1`：代码使用 `Magent.start/restart/close` 并由服务拥有 listener/group，但 README 和 `AGENTS.md` 仍要求已删除的 `MagentClient.attach(channel:)` 与 App-owned listener/group。 | README 和 `AGENTS.md` 已统一为当前服务模型：App 提供 `MagentConfig`，`Magent` 拥有 EventLoopGroup、TCP listener 和 Channel 生命周期；`close()` 视为实例终止操作。 |
| FIX-15 | ✅ 已解决 | 原 `NEW-P0-2`：`restart` 关闭旧服务后，新 TCP bind 失败会留下指向已关闭旧 Channel 的 `.running` 状态。 | `shutdown` 通过 `defer` 将所有退出路径收敛到 `.stop`；restart 失败路径完成新 shutdown promise 并关闭新 TCP listener。生命周期回归覆盖 TCP bind 失败及失败后使用同一 `Magent` 和 EventLoopGroup 再次 `start`。 |
| FIX-16 | ✅ 已解决 | 原 `NEW-P0-4`：accepted TCP connection 及其 SOCKS5 UDP association 没有服务级总量上限。 | `maxAcceptedConnections` 默认 256 且必须大于 0；service-owned atomic counter 跨 EventLoop/restart 统一准入，超限 child Channel 立即关闭，额度只在对应 `closeFuture` 完成时归还。并发竞争、额度复用和 restart 回归已覆盖。 |

## 5.3 当前未解决问题

状态说明：`❌ 阻断上线`、`🟡 上线前应解决`。

| 编号 | 级别 | 状态 | 当前问题与影响 | 上线前处理 |
| --- | --- | --- | --- | --- |
| NEW-P1-2 | P1 连接时限 | 🟡 上线前应解决 | TCP 两个方向已使用 `autoRead = false` 和“写完一批再读下一批”的严格单批流控，慢消费者不再形成无界批量 pending writes；但仍只有 connect timeout，没有 read idle/write timeout。半开或停止读写的 peer 可以永久占用连接及其 UDP association。 | 接入 read idle/write timeout，并增加停止读写、半开 control connection 和超时后资源回收测试。 |
| NEW-P1-4 | P1 配置校验 | 🟡 上线前应解决 | `start/restart` 不验证 `defaultDecision` 和所有 rule 的 `.proxy(UUID)` 是否存在于最终节点表；服务可以启动成功，直到首个命中请求才抛 `proxyNodeNotFound`。 | `makeCore` 完成节点装载后统一校验所有 proxy decision，配置错误在启动边界 fail fast。 |
| NEW-P1-5 | P1 HTTP 合规 | 🟡 上线前应解决 | HTTP CONNECT/forward 已改用 NIOHTTP1 decoder，HTTP forward 已显式拒绝 userinfo、fragment、HTTPS absolute-form，并接受通用 token method；但转发 request/response 仍没有 RFC 9110 要求的 `Via`。response 当前按原始字节透传，也没有 intermediary 级响应解析。 | 为两个方向追加 `Via` 并补充回归；在此之前继续只声明受限的单请求 HTTP forward profile。 |
| NEW-P1-7 | P1 SOCKS5 合规 | 🟡 上线前应解决 | SOCKS5 失败 reply 仍只覆盖部分 REP code，connection refused、TTL expired、ruleset denied 等错误会退化为 general failure；`FRAG != 0` 当前通过 control error chain 结束整个 association，而 RFC 1928 要求无声丢弃该 datagram。 | 完善 socket/error 到 REP 的映射；把不支持的 UDP fragment 作为无响应的普通 drop，并增加 reply mapping、association 存活和日志降噪测试。 |
| NEW-R1 | P1 发布门禁 | ❌ 阻断上线 | 仓库没有 CI workflow，当前构建和测试结果只来自本地执行，无法保证每次提交都经过相同门禁。 | CI 固定执行 debug build、strict build、release build、connection suites 和全量测试。 |
| NEW-R2 | P1 测试门禁 | ❌ 阻断上线 | Connection tests 已使用真实本地 socket 覆盖四种 TCP frontend、direct/Shadowsocks TCP、SOCKS5 UDP direct/domain/Shadowsocks、严格单批流控和 half-close；但多数测试直接安装 `MagentTCPConnection`，没有从 public `Magent.start` 到 local client/backend 的全链路。正常/重复/非法生命周期矩阵及独立 Shadowsocks server 兼容性测试也不完整。 | 增加 public `Magent` 的正常 start/close、重复生命周期和四种 frontend + UDP 的端到端测试；真实 Shadowsocks 集成测试保持可配置、可跳过并报告原因。 |
| NEW-R3 | P2 平台验证 | 🟡 上线前应解决 | Package 声明 macOS 14+、iOS 17+，当前验证只在 arm64 macOS 完成；iOS target、Network Extension 权限和真机资源回收没有验证。 | 至少增加 iOS Simulator 编译；如果产品目标包含 tunnel/Network Extension，再补真机 entitlement、前后台切换和系统停止回调测试。 |

## 5.4 RFC 与协议能力声明边界

当前实现是明确裁剪后的本地代理 profile，不应笼统宣称“完整支持 HTTP proxy”“完整符合
RFC 1928”或“支持所有 HTTP/SOCKS 能力”。

| 协议 | 当前可以声明 | 当前不应声明 |
| --- | --- | --- |
| HTTP CONNECT | HTTP/1.0、HTTP/1.1 CONNECT；NIOHTTP1 request 校验；下游成功后返回 200 并进入支持单批流控和 half-close 的 TCP tunnel；400/502/504 基本错误分类 | Proxy authentication、HTTP/2/3 CONNECT、Extended CONNECT、完整 safe-target policy |
| HTTP Forward | HTTP/1.x 受限单请求；NIOHTTP1 request 解析；absolute-form/origin-form；唯一 `Content-Length` body；Host 重建和 proxy/hop-by-hop header 清理；强制 `Connection: close`；拒绝 `Expect`、Upgrade 和 HTTPS absolute-form | 完整 RFC 9110/9112 intermediary、`Via`、chunked、`Expect: 100-continue`、大 body streaming、keep-alive、pipelining、Upgrade/WebSocket、HTTPS absolute-form、HTTP/2/3 |
| SOCKS4/SOCKS4a | no-auth CONNECT；IPv4/domain；固定 granted/rejected reply | BIND、ident authentication、原生 IPv6、完整 SOCKS4 command 集 |
| SOCKS5 TCP | no-auth CONNECT；IPv4/domain/IPv6；不支持 command 返回失败；支持单批流控和 half-close | GSSAPI、username/password、BIND、完整 REP code 映射、完整 RFC 1928 compliant implementation |
| SOCKS5 UDP | 每条 control connection 独占 relay；control close 联动回收；IPv4/domain/IPv6 target；direct domain 使用配置 DNS；`FRAG=0`；首个 client `IP:port` 固定 association；按真实 proxy endpoint 关联 Wire；服务级 association 数量受 `maxAcceptedConnections` 间接约束 | fragment reassembly、非零 FRAG 的 RFC 静默丢弃、request client hint 与 control peer 校验、IPv6 control/relay |

主要规范基线：

- [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html)：HTTP 语义、CONNECT、Via、Expect。
- [RFC 9112](https://www.rfc-editor.org/rfc/rfc9112.html)：HTTP/1.1 framing、absolute-form、连接复用。
- [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html) 与
  [RFC 9114](https://www.rfc-editor.org/rfc/rfc9114.html)：HTTP/2、HTTP/3 stream-scoped 能力。
- [RFC 1928](https://www.rfc-editor.org/rfc/rfc1928.html)：SOCKS5 method、command、reply 与 UDP association。
- [SOCKS4](https://www.openssh.com/txt/socks4.protocol) 与
  [SOCKS4a](https://www.openssh.com/txt/socks4a.protocol)：SOCKS4/4a 没有 IETF RFC。

## 5.5 上线门禁

达到生产上线标准前，至少需要全部完成：

1. 完成 TCP read/write/idle timeout、配置引用 fail-fast、HTTP `Via` 和 SOCKS5 REP/FRAG 语义。
2. 完成 CI、public `Magent` 生命周期/端到端代理测试及可配置的真实 Shadowsocks 兼容性测试。
3. 至少完成 iOS Simulator 编译；若产品使用 Network Extension，再完成真机生命周期验证。

P0 全部完成、P1 有明确降级策略且 CI/集成测试通过后，才可以从受控灰度提升为生产上线。

## 5.6 本次验证

2026-07-28 在 arm64 macOS 上执行：

```bash
swift build
swift build -Xswiftc -strict-concurrency=complete
swift build -c release
swift test --filter ConnectionTests
swift test
git diff --check
```

结果：

- debug build：通过。
- strict-concurrency build：通过。
- release build：通过。
- `ConnectionTests`：56/56 通过。
- 全量测试：193/193 通过。
- SwiftLint build-tool plugin：随三次 build 和测试 build 通过。
- accepted connection 默认值、并发上限、超限关闭、额度复用和 restart：通过。
- restart 的 TCP bind 失败、失败后再次启动及正常 close：通过。
- iOS build、public `Magent` 完整端到端链路和独立 Shadowsocks server 兼容性：本次未验证。
