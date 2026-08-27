---
desc: Magent HTTP Forward 单请求改写、路由、Wire 编解码与响应转发
updated_at: 2026-07-24
commit: af5ba87
---

# Magent HTTP Forward 代理链路 4C 产品设计文档

## 0. 文档目标

本文使用 Context、Contract、Core Logic、Corners 描述当前 HTTP forward 单请求链路，包括
absolute-form 改写、路由、Shadowsocks 编码和响应透传。

# 1. Context

## 1.1 协议定位

HTTP forward client 把完整 HTTP request 发给代理。常见首行：

```http
GET http://example.com/path?q=1 HTTP/1.1
```

与 CONNECT 不同，Magent 必须把请求改写为 origin-form 后发送到目标：

```http
GET /path?q=1 HTTP/1.1
```

HTTP forward 没有 `200 Connection Established`。下游建连成功后直接发送改写后的 HTTP request，
远端 response bytes 原样或经 Wire 解密后写回本地 client。

## 1.2 协议探测

`MagentTCPConnection` 当前识别以下方法：

- `DELETE`
- `GET`
- `HEAD`
- `OPTIONS`
- `POST`
- `PUT`
- `PATCH`
- `TRACE`

前缀不完整时继续累计；匹配后创建 `HttpForwardConnection`。

## 1.3 分层

```text
local HTTP client
  -> MagentTCPConnection（方法探测）
  -> HttpForwardConnection / HttpForwardProtocol
  -> MagentCore（规则匹配与 Channel 创建）
  -> direct target 或 ShadowsocksTCPWire + Shadowsocks server
```

HTTP request 的语法、目标解析和 header 改写属于前端。Core 只接收 `NetworkAddress`，Wire 只处理
节点协议。

# 2. Contract

## 2.1 请求完整性

`HttpForwardProtocol.parseIfComplete(_:)`：

- 等待 `\r\n\r\n`。
- 解析 request-line 和 headers。
- 支持无 body，或由单个合法 `Content-Length` 指定的固定长度 body。
- 数据不足时返回 `nil`。
- 禁止多个 `Content-Length`。
- 禁止 `Transfer-Encoding`，因此当前不支持 chunked request。
- 完整 request 后禁止任何额外字节。
- request 缓冲上限为 64 KiB。

当前一条 accepted TCP connection 只支持一个 HTTP forward request。进入 `forward` 后再次从
`proxyChannel` 收到数据会返回 400 并关闭；不支持 keep-alive 上的后续请求和 pipelining。

## 2.2 目标解析

目标来源按以下顺序解析：

1. request-target 是 `http://` 或 `https://` absolute URI 时，使用 URI host/port。
2. 否则使用 `Host` header；未提供端口时默认 80。

IPv6 Host 使用 `[address]:port`。端口必须在 `1...65535`。

`https://` absolute URI 只参与地址解析，当前 HTTP forward 链路不会替客户端创建 TLS 会话；
标准 HTTPS 代理访问应使用 HTTP CONNECT。

## 2.3 请求改写

发送到下游的 payload：

- absolute-form 改为 origin-form path/query。
- 重新生成一个规范的 `Host`。
- 移除固定 hop-by-hop headers：
  `Connection`、`Keep-Alive`、`Proxy-Authenticate`、`Proxy-Authorization`、
  `Proxy-Connection`、`TE`、`Trailer`、`Transfer-Encoding`、`Upgrade`。
- 移除 `Connection` header 动态列出的 header 名。
- 追加 `Connection: close`。
- 保留完整固定长度 body。

## 2.4 状态契约

| 状态 | 含义 |
| --- | --- |
| `request` | 累计首个完整 request，创建下游 Channel |
| `forward` | request 已发出，只接收下游 response |
| `closed` | 关闭下游 Channel，不再处理数据 |

## 2.5 路由和响应

- direct：连接原始 target，connect timeout 固定 10 秒。
- proxy：连接 `wire.getTargetAddress()`，timeout 使用 `wire.getTimeout()`。
- proxy 节点不存在：失败关闭，不回退 direct。

本地错误响应：

| 场景 | 响应 |
| --- | --- |
| request/header/framing 非法 | `400 Bad Request` |
| 下游连接或 Wire 失败 | `502 Bad Gateway` |
| connect timeout | `504 Gateway Timeout` |

成功路径没有额外本地 response；目标站 response 直接转发。

# 3. Core Logic

## 3.1 首个请求

```text
累计 header/body
  -> parseIfComplete
  -> 解析 target
  -> absolute-form/header 改写
  -> routeTCPWire(target)
  -> direct: connect target
  -> proxy: connect proxy node
  -> 保存 wireChannel
  -> proxy 路径发送 wire.start(target)
  -> state = forward
  -> 发送改写后的 request payload
```

先把状态切换为 `forward`，再调用 outbound，保证写入路径满足自身状态约束。

## 3.2 代理路径

Shadowsocks 路径先发送：

```text
client salt + AEAD(ATYP | ADDR | PORT)
```

然后把完整改写 HTTP request 交给 `ShadowsocksTCPWire.encodeOutbound`。CONNECT request 和
forward request 的区别只存在前端，Wire 看到的都是某条目标 TCP stream 的明文 payload。

## 3.3 Response

```text
wireChannel bytes
  -> direct: 原样写回 proxyChannel
  -> proxy: ShadowsocksTCPWire.decodeInbound
  -> 完整明文写回 proxyChannel
```

前端不解析 response status、headers、body，也不尝试复用 keep-alive。

## 3.4 关闭

- `wireChannel` inactive：关闭 `proxyChannel`。
- `proxyChannel` inactive/error：由 `MagentTCPConnection` 调用 `closeConnection(error:)`，
  只向下关闭 `wireChannel`。
- `closed` 状态阻止循环关闭。

# 4. Corners

## 4.1 当前支持边界

| 场景 | 当前行为 |
| --- | --- |
| header/body 分片 | 支持 |
| 固定 `Content-Length` body | 支持 |
| chunked request | 400 |
| 多个 `Content-Length` | 400 |
| pipelining | 400 |
| 一条连接上的第二个 request | 400 |
| absolute-form | 改写为 origin-form |
| origin-form | 使用 Host 解析 target |
| hop-by-hop headers | 剥离并强制 `Connection: close` |
| response framing | 不解析，直到下游关闭 |
| read/write idle timeout | 尚未实现 |
| 双向背压 | 尚未实现 |
| 本地认证 | 无认证开放代理是当前产品设计 |

## 4.2 不应跨层的职责

- Core 不解析 URL、Host 或 HTTP body。
- Wire 不删除 HTTP headers，也不生成 400/502/504。
- HTTP forward 前端不能把 absolute-form 原样当作 Shadowsocks 地址握手。
- Direct 路径用 `wire == nil` 表达，不存在 `DirectNodeWire`。

## 4.3 验证重点

- absolute-form 与 origin-form target 解析。
- query、IPv6 Host 和默认端口。
- hop-by-hop、`Proxy-Authorization` 和动态 Connection header 移除。
- body 分片、非法 framing、pipelining 拒绝。
- direct/proxy 拨号地址、timeout 和错误响应。
