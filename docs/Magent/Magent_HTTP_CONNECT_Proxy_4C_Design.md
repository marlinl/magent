---
desc: Magent HTTP CONNECT 请求解析、路由、Wire 编解码与 TCP tunnel 生命周期
updated_at: 2026-07-24
commit: af5ba87
---

# Magent HTTP CONNECT 代理链路 4C 产品设计文档

## 0. 文档目标

本文使用 Context、Contract、Core Logic、Corners 描述 HTTP CONNECT 从本地请求解析、路由和
下游建连，到 TCP tunnel 双向关闭的完整链路。

# 1. Context

## 1.1 协议定位

HTTP CONNECT 用一个 HTTP 请求建立目标 TCP tunnel：

```http
CONNECT example.com:443 HTTP/1.1
Host: example.com:443

```

`MagentTCPConnection` 识别 `CONNECT ` 前缀后创建 `HttpConnectConnection`。CONNECT 请求只在
本地代理前端消费，不会原样发给目标站或 Shadowsocks 节点。

## 1.2 分层

```text
local HTTP client
  -> Magent TCP listener
  -> MagentTCPConnection（协议探测）
  -> HttpConnectConnection（解析、reply、tunnel 生命周期）
  -> MagentCore（路由和 Channel 创建）
  -> direct target 或 ShadowsocksTCPWire + Shadowsocks server
```

`HttpProtocol` 是无状态 parser。`HttpConnectConnection` 持有 `proxyChannel`、`wireChannel`、
连接状态和可选 `Wire`。Wire 不知道 HTTP 状态码。

# 2. Contract

## 2.1 请求契约

当前 parser 要求：

- method 必须是 `CONNECT`。
- request-target 必须是显式 `host:port` 或 `[IPv6]:port` authority-form。
- 端口必须在 `1...65535`。
- 只接受 CRLF 行结束，不接受裸 LF 或非法 CR。
- 不接受 obs-fold header。
- HTTP 版本只接受 `HTTP/1.0` 和 `HTTP/1.1`。
- HTTP/1.1 必须且只能有一个 `Host`；HTTP/1.0 最多一个。
- 存在 `Host` 时必须与 request-target 的 host、port 一致。
- 请求缓冲上限为 64 KiB。
- 支持 header 分片并等待 `\r\n\r\n`。
- 完整 CONNECT header 后不得存在 tunnel remainder；存在额外字节时返回 400 并关闭。

## 2.2 状态契约

| 状态 | 含义 |
| --- | --- |
| `handshake` | 等待完整 CONNECT 请求并异步创建下游 TCP Channel |
| `tunnel` | 已写入本地 200，开始双向 TCP 转发 |
| `closed` | 连接结束，缓冲清空，`wireChannel` 已关闭或正在关闭 |

## 2.3 路由契约

```swift
let wire = try core.routeTCPWire(target)
```

- `nil`：连接原始 target，connect timeout 固定 10 秒。
- 非空：连接 `wire.getTargetAddress()`，connect timeout 使用 `wire.getTimeout()`。
- 代理节点缺失：失败关闭，不得回退直连。

一个 CONNECT 连接只执行一次路由。该次结果同时决定拨号地址和整个 tunnel 使用的 Wire 状态。

## 2.4 Wire 契约

代理路径的启动顺序：

1. 下游 TCP Channel 建立。
2. `wire.start(handshake: target)` 生成 Shadowsocks 目标启动帧。
3. 启动帧写入 `wireChannel`。
4. 本地客户端收到 `200 Connection Established`。
5. 后续 TCP payload 使用 `wire.encodeOutbound(_:address: nil)`。

Direct 路径没有 `DirectNodeWire` 类型，`wire == nil` 就表示明文透传。

## 2.5 本地响应契约

| 场景 | 响应 |
| --- | --- |
| 建连成功 | `HTTP/1.1 200 Connection Established` |
| 请求或地址非法 | `HTTP/1.1 400 Bad Request` |
| 下游创建/连接失败 | `HTTP/1.1 502 Bad Gateway` |
| connect timeout | `HTTP/1.1 504 Gateway Timeout` |

错误响应使用 `Connection: close`，写完后关闭 accepted `proxyChannel`。

# 3. Core Logic

## 3.1 建连链路

```text
累积 CONNECT header
  -> HttpProtocol.parseIfComplete
  -> checkConnect
  -> 拒绝 remainder
  -> routeTCPWire(target)
  -> direct: connect target
  -> proxy: connect proxy node
  -> 保存 wireChannel
  -> proxy 路径发送 Wire start frame
  -> 写 200
  -> state = tunnel
```

`createTCPClientChannel` 返回 `EventLoopFuture<Channel>`；连接完成后通过回调继续，不在
EventLoop handler 中同步 `wait()`。

## 3.2 Tunnel 上行

```text
proxyChannel payload
  -> direct: 原样写入 wireChannel
  -> proxy: ShadowsocksTCPWire.encodeOutbound
  -> wireChannel.writeAndFlush
```

## 3.3 Tunnel 下行

```text
wireChannel bytes
  -> direct: 原样写回 proxyChannel
  -> proxy: ShadowsocksTCPWire.decodeInbound
  -> 完整明文写回 proxyChannel
```

Shadowsocks 解码可能因半帧暂时返回空数据，连接继续等待后续字节。

## 3.4 生命周期

- `proxyChannel` 被动关闭：`MagentTCPConnection` 将具体连接标记关闭并关闭 `wireChannel`。
- `wireChannel` 被动关闭：`HttpConnectConnection` 关闭 `proxyChannel`。
- `wireChannel` error：错误转发给 `proxyChannel` pipeline，由 accepted 连接统一关闭。
- 所有 close 路径先检查 `closed`，避免两端互相 close 形成循环。

# 4. Corners

## 4.1 当前支持边界

| 场景 | 当前行为 |
| --- | --- |
| CONNECT header 分片 | 支持 |
| CONNECT header 与 TLS ClientHello 粘包 | 400；当前采用严格请求/响应顺序，不接受提前 tunnel 数据 |
| HTTP/1.1 缺少或重复 Host | 400 |
| Host 与 authority 不一致 | 400 |
| IPv6 authority | 必须使用 `[address]:port` |
| direct connect timeout | 10 秒，返回 504 |
| proxy connect timeout | 使用节点 timeout，返回 504 |
| 后端建立后目标站迟迟无数据 | 当前没有 read idle timeout |
| 双向写入背压 | 尚未联动 `isWritable/autoRead` |
| 本地认证 | 无认证开放代理是当前产品设计 |

## 4.2 不应跨层的职责

- HTTP 400/502/504/200 只能由 HTTP CONNECT 前端生成。
- Core 不解析 HTTP header。
- Wire 不创建 Channel，不保存 HTTP 状态。
- Shadowsocks Wire 启动帧携带最终 target；CONNECT 原始请求不能进入 Wire payload。

## 4.3 验证重点

- authority、Host、HTTP version 和 CRLF 校验。
- 分片 header 与 remainder 拒绝。
- direct/proxy 拨号地址和 timeout。
- 200 必须晚于下游 Channel 建立。
- 任一侧 inactive/error 后两端最终关闭。
