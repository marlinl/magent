---
desc: Magent SOCKS5 no-auth、TCP CONNECT与每控制连接独占UDP relay链路
updated_at: 2026-09-21
baseline: current-working-tree
---

# Magent SOCKS5 代理链路 4C 产品设计文档

## 0. 文档目标

本文使用 Context、Contract、Core Logic、Corners 描述当前 SOCKS5 no-auth、TCP CONNECT 和
每条控制连接独占的 UDP relay。TCP control 与 UDP datagram 分别传输数据，但共享 association 生命周期。

# 1. Context

## 1.1 支持范围

当前 SOCKS5 前端支持：

- no-auth method negotiation。
- IPv4、IPv6 和域名目标。
- TCP `CONNECT`。
- `UDP ASSOCIATE`。
- direct 和 Shadowsocks AEAD TCP/UDP 出站。

当前不支持：

- username/password 等认证方法。
- `BIND`。
- SOCKS5 UDP fragmentation。
- greeting/request 与下一阶段数据粘包。

no-auth 和非 loopback 监听是 Magent 支持的开放代理产品能力，不属于待修复缺陷。

## 1.2 两条数据路径

TCP CONNECT：

```text
local TCP client
  -> MagentTCPConnection
  -> Socks5Connection
  -> direct TCP 或 ShadowsocksTCPWire
```

UDP ASSOCIATE：

```text
TCP control connection -> Socks5Connection
  -> 当前控制连接独占的 Socks5UDPConnection handler
       -> IPv4 relay/outbound Channel（0.0.0.0:0）
       -> IPv6 outbound Channel（[::]:0）
       -> 可选的 DNSClient

local UDP client -> success reply 返回的 IPv4 relay 地址
  -> direct target 或 ShadowsocksUDPWire + Shadowsocks server
```

`Magent.start` 只绑定 TCP listener。UDP ASSOCIATE 到来后才创建 relay，UDP 端口由系统分配，
不以 TCP 监听端口作为绑定配置；客户端必须使用 reply 返回的 UDP 端口。
控制连接当前必须使用 IPv4；初始化也要求 IPv6 outbound Channel 绑定成功。
这些 Channel 使用 accepted control connection 的 EventLoop。

# 2. Contract

## 2.1 Greeting

请求：

```text
VER | NMETHODS | METHODS
```

约束：

- `VER` 必须为 `0x05`。
- client methods 必须包含 `0x00` no-auth。
- 支持分片，等待 `2 + NMETHODS` 字节。
- 完整 greeting 后不得有 remainder。

成功响应：

```text
05 00
```

没有可接受 method：

```text
05 FF
```

## 2.2 Request

```text
VER | CMD | RSV | ATYP | DST.ADDR | DST.PORT
```

约束：

- `VER = 0x05`，`RSV = 0x00`。
- ATYP 支持 IPv4 (`0x01`)、DOMAIN (`0x03`)、IPv6 (`0x04`)。
- CONNECT 目标端口必须在 `1...65535`。
- UDP ASSOCIATE request 允许端口为 0。
- request 缓冲上限为 64 KiB。
- 支持 request 分片。
- 完整 request 后不得有 remainder。

命令：

| CMD | 当前行为 |
| --- | --- |
| `0x01 CONNECT` | 创建 TCP `wireChannel`，成功后进入 tunnel |
| `0x02 BIND` | 返回 command-not-supported 并关闭 |
| `0x03 UDP ASSOCIATE` | 返回本 association 的 IPv4 relay 地址和临时端口，control 进入 idle |

## 2.3 TCP 状态

| 状态 | 含义 |
| --- | --- |
| `greeting` | 等待并校验 method negotiation |
| `request` | 等待 SOCKS5 command request |
| `tunnel` | TCP CONNECT 双向转发 |
| `idle` | UDP ASSOCIATE 已成功；TCP 上后续 bytes 不作为 UDP datagram |
| `closed` | 连接结束，关闭 TCP `wireChannel` |

## 2.4 CONNECT 路由和 Wire

- direct：连接最终 target，connect timeout 使用 `MagentConfig.defaultTimeout`（毫秒，默认 10 秒）。
- proxy：连接 `wire.getTargetAddress()`，timeout 使用节点配置。
- proxy 节点缺失：失败关闭，不降级 direct。

Shadowsocks TCP 路径先发送 `wire.start(handshake: target)`，后续 tunnel bytes 只使用
`wire.encodeOutbound(_:address: nil)`。

CONNECT 成功 reply 的 `BND.ADDR/BND.PORT` 使用 `wireChannel.localAddress`；取不到时回退
`0.0.0.0:0` 编码。

## 2.5 UDP datagram

本地 client 发往该 association 的 IPv4 relay 的 payload：

```text
RSV(2) | FRAG(1) | ATYP | DST.ADDR | DST.PORT | DATA
```

约束：

- `RSV` 必须为 `0x0000`。
- `FRAG` 必须为 `0x00`；其他值报错并经 control error chain 关闭 association。
- 目标端口必须非零。

每个通过校验的客户端 datagram 独立执行一次 `MagentCore.routeUDPWire(target)`：

- direct：去掉 SOCKS5 UDP header，把 DATA 直接发送给 target。
- proxy：`ShadowsocksUDPWire` 把 `ATYP | ADDR | PORT | DATA` 加密后发给代理节点。
- proxy 节点缺失：报错并关闭 association，不允许明文回退。

响应重新封装为：

```text
00 00 00 | ATYP | SOURCE.ADDR | SOURCE.PORT | DATA
```

## 2.6 UDP association 所有权

`Socks5UDPConnection` handler 弱引用所属控制连接，并订阅其 `closeFuture` 关闭 IPv4、IPv6 和 DNS 资源。
首个从 IPv4 relay 收到的 datagram 固定客户端 `IP:port`，以后该来源的数据按客户端请求处理。
其他来源必须匹配本 association 已记录的真实出站 endpoint 才可作为回包处理。

当前不校验 UDP ASSOCIATE request 中的 client hint 与 TCP peer/UDP source 的一致性；不能将首包固定描述为身份认证。
未使用共享 association cache，没有 4096 容量或 600 秒 TTL 回收；资源随 control close 或运行周期 shutdown 结束。

## 2.7 UDP 回包 Wire 选择

association 的 `wireMap: [SocketAddress: Wire?]` 记录实际出站地址：

- direct 记录目标 SocketAddress，值为 nil。
- proxy 记录代理节点 SocketAddress，值为当前选择的 Wire。
- 同一 endpoint 仅首次写入，后续不会覆盖其编码方式。
- 回包地址必须在 map 中；未知来源报错，经 control error chain 关闭 association。

同一 Core 中不同 UUID 不允许共用相同代理 endpoint；该校验发生在节点装载。
回包不会查询 Core 的节点地址表推断 Wire，也不会把未知来源自动当成 direct。
同一实际 endpoint 在一个 association 中混用 direct/proxy 的行为不具备独立的回包区分能力。

## 2.8 UDP 域名与 DNS

proxy domain 直接编码进 Wire，由远端处理；direct IP 不需要 DNS。
direct domain 使用 `MagentConfig.dnsListener` 创建的单个 DNSClient；nil 时该请求报错并关闭 association。
A 和 AAAA 查询共同完成后，优先选第一个 A 地址，其次第一个 AAAA 地址；任一查询失败会让组合 Future 失败，
没有多 DNS server 或失败查询回退。查询超时使用 `core.defaultTimeout` 毫秒。

结果按 `NetworkAddress`（含端口）存入 association 的 `resolvedAddressMap`，当前不按 DNS TTL 刷新。
UDP 本身没有 TCP connect 阶段，不使用节点的 connect timeout。

# 3. Core Logic

## 3.1 Greeting 到 CONNECT

```text
detect 0x05
  -> Socks5Connection(state: greeting)
  -> 累计 greeting，写 05 00
  -> state = request
  -> 累计 CONNECT request
  -> routeTCPWire(target)
  -> 创建 direct/proxy wireChannel
  -> proxy 路径发送 Wire start frame
  -> 写 succeeded reply
  -> state = tunnel
```

## 3.2 TCP Tunnel

```text
proxyChannel payload
  -> direct: raw
  -> proxy: ShadowsocksTCPWire.encodeOutbound
  -> wireChannel

wireChannel bytes
  -> direct: raw
  -> proxy: ShadowsocksTCPWire.decodeInbound
  -> proxyChannel
```

## 3.3 UDP ASSOCIATE

```text
SOCKS5 UDP ASSOCIATE request
  -> 在控制连接 EventLoop 绑定 IPv4 relay 和 IPv6 outbound
  -> 配置可选 DNS client
  -> 返回 TCP 本地 IPv4 地址 + relay 临时端口
  -> reply 写入成功，state = idle，启动两个 UDP Channel 读取

UDP datagram 到本 association relay
  -> 根据首包固定的 source 区分客户端请求与远端回包
  -> 客户端请求：parse relay header -> routeUDPWire(target)
       -> 选择 IPv4/IPv6 Channel，首次记录实际 endpoint 及 Wire
       -> AddressedEnvelope 写给 target 或代理节点
  -> 远端回包：按已记录的 endpoint 查 Wire，解密/透传
  -> 封装 SOCKS5 UDP response
  -> 写回原 UDP source IP:port
```

## 3.4 关闭

TCP CONNECT 的关闭规则与其他 TCP 协议一致：

- accepted `proxyChannel` inactive/error 向下关闭 `wireChannel`。
- `wireChannel` inactive/error 向上关闭 `proxyChannel`。
- `closed` 防止循环。

TCP tunnel 的 input half-close 传播为另一侧 output close，并保留反方向读取。
UDP control 在 idle 收到 FIN 时结束连接；后续普通 TCP bytes 被忽略，不作为 UDP 数据。
control closeFuture 回收 association 的 UDP/DNS 资源；UDP Channel 的错误或 inactive 也会向 control 传播。
运行周期 shutdown 先关闭 accepted control，再触发相同的资源回收路径。

# 4. Corners

## 4.1 Reply code

| 错误 | REP |
| --- | --- |
| 成功 | `0x00` |
| 其他失败 | `0x01` general failure |
| 节点/策略缺失 | `0x03` network unreachable |
| connect timeout | `0x04` host unreachable |
| 不支持命令 | `0x07` command not supported |
| 地址非法/不支持 | `0x08` address type not supported |

## 4.2 当前边界

| 场景 | 当前行为 |
| --- | --- |
| greeting/request 分片 | 支持 |
| greeting + request 粘包 | 拒绝 |
| CONNECT request + payload 粘包 | 拒绝；当前采用严格 request/reply 顺序，不接受提前 tunnel 数据 |
| UDP fragmentation | 报错并结束 association |
| UDP 每包目标不同 | 支持 |
| UDP connect timeout | 不适用；UDP Channel 无连接且复用多个目标 |
| UDP 空闲资源 | 无独立 TTL；由 control close / runtime shutdown 回收 |
| UDP source | 每个 control 独占 relay，首包固定 source；不校验 request hint 与 TCP peer |
| TCP read/write idle timeout | 尚未实现 |
| TCP 双向流控 | autoRead=false；对端写入完成后再读来源 |

## 4.3 验证重点

- no-auth negotiation 分片与无可接受 method。
- CONNECT/BIND/UDP ASSOCIATE reply。
- IPv4、IPv6、domain 地址编解码。
- SOCKS5 UDP reserved、FRAG 和不完整地址拒绝。
- direct/代理 UDP response source 封装。
- control 关闭回收 UDP/DNS，非法 datagram 进入 control 错误链。
- IPv4 control 要求、IPv6 target、配置 DNS 与缺失 DNS 的行为。
- 按实际出站 endpoint 记录和查找 Wire；未知回包来源拒绝。

源码与现有测试：[Socks5Connection](../Sources/Connection/Socks5Connection.swift)、[Socks5ConnectionTests](../Tests/Connection/Socks5ConnectionTests.swift)。本次只静态对齐文档，未重跑测试。
