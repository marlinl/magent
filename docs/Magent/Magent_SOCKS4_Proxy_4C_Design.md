---
desc: Magent SOCKS4和SOCKS4a CONNECT解析、路由、Wire编解码与连接生命周期
updated_at: 2026-07-24
commit: af5ba87
---

# Magent SOCKS4 代理链路 4C 产品设计文档

## 0. 文档目标

本文使用 Context、Contract、Core Logic、Corners 描述当前 SOCKS4/SOCKS4a TCP CONNECT 链路。
文中的 `proxyChannel` 是 Magent 接受的本地客户端 TCP Channel，`wireChannel` 是连接目标站或
Shadowsocks 节点的下游 TCP Channel。

# 1. Context

## 1.1 协议定位

`MagentTCPConnection` 在 accepted TCP Channel 上累计首段数据。首字节为 `0x04` 时创建
`Socks4Connection`，并把探测期间累计的全部字节交给它。

当前支持：

- SOCKS4 `CONNECT`。
- SOCKS4a 域名扩展。
- IPv4 目标。
- direct 和 Shadowsocks AEAD TCP 两种出站路径。
- 无认证模式；`USERID` 只用于确定请求边界，不执行 identd 或账户校验。

当前不支持：

- SOCKS4 `BIND`。
- SOCKS4 UDP。
- 握手请求与首段 tunnel payload 粘在同一个 TCP read 中。

## 1.2 分层

```text
local SOCKS4 client
  -> TCP listener
  -> MagentTCPConnection（协议探测）
  -> Socks4Connection（请求解析、本地 reply、双向生命周期）
  -> MagentCore（规则匹配、节点选择、Channel 创建）
  -> direct target 或 ShadowsocksTCPWire + Shadowsocks server
```

`Socks4Connection` 同时是 `wireChannel` 的 `ChannelInboundHandler`。`Wire` 只负责编解码节点协议，
不持有 Channel，也不生成 SOCKS4 reply。

# 2. Contract

## 2.1 请求格式

SOCKS4：

```text
VN | CD | DSTPORT | DSTIP | USERID | 0x00
```

SOCKS4a：

```text
VN | CD | DSTPORT | 0.0.0.x | USERID | 0x00 | DOMAIN | 0x00
```

约束：

- `VN` 必须为 `0x04`。
- 仅 `CD = 0x01` 可以进入 CONNECT 链路。
- 端口必须在 `1...65535`。
- SOCKS4 IPv4 地址保存为 4 字节 `NetworkAddress.ipv4`。
- SOCKS4a 的 DOMAIN 必须是非空 UTF-8。
- 请求缓冲上限为 64 KiB。
- parser 支持请求分片，会持续等待 `USERID` 或 DOMAIN 结束字节。
- 完整请求后不得存在 remainder；存在额外字节时返回 rejected 并关闭。

## 2.2 状态契约

`Socks4Connection` 只有三个状态：

| 状态 | 含义 |
| --- | --- |
| `handshake` | 累计和解析 SOCKS4/SOCKS4a 请求，异步创建下游 Channel |
| `tunnel` | CONNECT 已成功，双向转发 TCP payload |
| `closed` | 不再接受数据，释放缓冲并关闭 `wireChannel` |

异步创建 `wireChannel` 期间不增加额外状态。`isReadingInitialRequest` 阻止第二段 payload 在 granted
之前进入。

## 2.3 路由与 Wire 契约

`Socks4Connection` 只对目标调用一次 `MagentCore.routeTCPWire(_:)`：

- 返回 `nil`：直连目标，超时固定为 10 秒。
- 返回 `Wire`：连接 `wire.getTargetAddress()`，超时使用 `wire.getTimeout()`。
- `.proxy(nodeID)` 找不到节点：抛出 `proxyNodeNotFound`，不得降级为直连。

代理路径建立 Channel 后先调用：

```swift
wire.start(handshake: target)
```

Shadowsocks TCP Wire 在这里生成 `salt + AEAD(ATYP | ADDR | PORT)`。后续 tunnel payload 只调用
`wire.encodeOutbound(_:address: nil)`，不能重复发送目标地址。

## 2.4 本地响应

成功：

```text
00 5A 00 00 00 00 00 00
```

失败：

```text
00 5B 00 00 00 00 00 00
```

成功响应由 `Socks4Connection` 在下游 Channel 建立且 Wire 启动帧已提交后生成。它不是目标站或
Shadowsocks server 的响应。

# 3. Core Logic

## 3.1 CONNECT 建立

```text
累计完整 request
  -> 校验 request 后没有 remainder
  -> 解析 command 与 target
  -> routeTCPWire(target)
  -> direct: connect(target, 10_000 ms)
  -> proxy:  connect(wire target, wire timeout)
  -> 保存 wireChannel
  -> proxy 路径发送 wire.start(target)
  -> 写 granted
  -> state = tunnel
```

连接创建是 `EventLoopFuture<Channel>`。完成回调在 `proxyChannel.eventLoop` 上继续，不允许在
Channel handler 中调用 `wait()`。

## 3.2 Tunnel 上行

```text
proxyChannel ByteBuffer
  -> direct: 原样写入 wireChannel
  -> proxy: wire.encodeOutbound
  -> wireChannel.writeAndFlush
```

## 3.3 Tunnel 下行

```text
wireChannel ByteBuffer
  -> direct: 原样写回 proxyChannel
  -> proxy: wire.decodeInbound
  -> 有完整明文时写回 proxyChannel
```

Shadowsocks TCP Wire 自己保存解密 salt、nonce、frame 状态和半帧缓冲；空解码结果表示还没有完整
payload。

## 3.4 关闭

- accepted `proxyChannel` 失效时，`MagentTCPConnection` 调用 `closeConnection(error:)`，
  `Socks4Connection` 只关闭自己的 `wireChannel`。
- `wireChannel` 失效时，`Socks4Connection` 关闭 `proxyChannel`。
- `wireChannel` error 通过 `proxyChannel.pipeline.fireErrorCaught` 进入上游统一错误关闭路径。
- `closed` 守卫保证双方 close 不形成循环。

# 4. Corners

## 4.1 当前边界

| 场景 | 当前行为 |
| --- | --- |
| 分片请求 | 支持，等待完整终止字段 |
| 请求后同包携带 payload | rejected；当前采用严格请求/响应顺序，不接受提前 tunnel 数据 |
| `BIND` | rejected |
| SOCKS4a 空域名 | rejected |
| direct connect timeout | 10 秒后 rejected |
| proxy connect timeout | 使用节点 timeout，超时后 rejected |
| no-auth | 产品设计，允许开放代理 |
| TCP read/write idle timeout | 尚未实现 |
| 双向背压联动 | 尚未实现 |

## 4.2 验证重点

- SOCKS4 与 SOCKS4a 请求分片。
- SOCKS4a 域名和网络序端口。
- BIND、非法版本、非法端口和超长请求。
- route direct 与 proxy 的拨号地址。
- Shadowsocks 启动帧只写一次。
- proxy/wire 任一侧关闭后另一侧最终关闭。
