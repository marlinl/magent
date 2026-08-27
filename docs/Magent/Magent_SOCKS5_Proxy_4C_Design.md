---
desc: Magent SOCKS5 no-auth、TCP CONNECT与共享UDP relay完整链路
updated_at: 2026-07-24
commit: af5ba87
---

# Magent SOCKS5 代理链路 4C 产品设计文档

## 0. 文档目标

本文使用 Context、Contract、Core Logic、Corners 描述当前 SOCKS5 no-auth、TCP CONNECT 和共享
UDP relay 实现。TCP control connection 与 UDP datagram 是两条独立数据路径。

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
TCP control connection -> Socks5Connection（只维持 control 生命周期）

local UDP client -> Magent 共享 UDP service -> Socks5UDPConnection
  -> 每客户端 source endpoint 复用一个 backend UDP Channel
  -> direct target 或 ShadowsocksUDPWire + Shadowsocks server
```

共享 UDP service 在 `Magent.start` 时和 TCP listener 绑定同一个配置地址、同一个端口，不为每条
control connection 单独创建 relay socket。

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
| `0x03 UDP ASSOCIATE` | 返回共享 UDP service 地址，TCP control connection 进入 idle |

## 2.3 TCP 状态

| 状态 | 含义 |
| --- | --- |
| `greeting` | 等待并校验 method negotiation |
| `request` | 等待 SOCKS5 command request |
| `tunnel` | TCP CONNECT 双向转发 |
| `idle` | UDP ASSOCIATE 已成功；TCP 上后续 bytes 不作为 UDP datagram |
| `closed` | 连接结束，关闭 TCP `wireChannel` |

## 2.4 CONNECT 路由和 Wire

- direct：连接最终 target，connect timeout 固定 10 秒。
- proxy：连接 `wire.getTargetAddress()`，timeout 使用节点配置。
- proxy 节点缺失：失败关闭，不降级 direct。

Shadowsocks TCP 路径先发送 `wire.start(handshake: target)`，后续 tunnel bytes 只使用
`wire.encodeOutbound(_:address: nil)`。

CONNECT 成功 reply 的 `BND.ADDR/BND.PORT` 使用 `wireChannel.localAddress`；取不到时回退
`0.0.0.0:0` 编码。

## 2.5 UDP datagram

本地 client 发往共享 UDP service 的 payload：

```text
RSV(2) | FRAG(1) | ATYP | DST.ADDR | DST.PORT | DATA
```

约束：

- `RSV` 必须为 `0x0000`。
- `FRAG` 必须为 `0x00`；其他值直接丢弃。
- 目标端口必须非零。

每个 datagram 独立执行一次 `MagentCore.routeUDPWire(target)`：

- direct：去掉 SOCKS5 UDP header，把 DATA 直接发送给 target。
- proxy：`ShadowsocksUDPWire` 把 `ATYP | ADDR | PORT | DATA` 加密后发给代理节点。
- proxy 节点缺失：丢弃 datagram，不允许明文回退。

响应重新封装为：

```text
00 00 00 | ATYP | SOURCE.ADDR | SOURCE.PORT | DATA
```

## 2.6 UDP association/cache

共享 relay 以 UDP source 的完整 `IP:port` 作为 association key：

- capacity：4,096。
- expiration：`afterWrite(.seconds(600))`。
- 同一 key 并发首次创建使用同一个 pending Future，避免重复 bind。
- cache miss 或旧 Channel inactive 时绑定新的 `0.0.0.0:0` backend UDP Channel。
- TTL、容量淘汰、`removeAll` 和 service shutdown 都通过 `onEvict` 关闭 backend Channel。

该模型不把 UDP source endpoint 严格登记到某一条 TCP control connection。TCP control 关闭不会立即
删除对应 UDP cache entry；entry 由 TTL、容量或整个运行周期 shutdown 回收。这是当前共享开放
UDP relay 的明确设计。

## 2.7 UDP 回包 Wire 选择

backend UDP Channel 收到回包后：

- 来源地址命中 `MagentCore.addressNodes`：使用该代理节点的 `ShadowsocksUDPWire` 解密。
- 未命中：按 direct response 处理。

因此同一 Core 内一个代理 `IP/domain + port` 只能属于一个节点。不同 UUID 注册同一 endpoint 会
抛出 `invalidPolicy`；同 UUID 更新 endpoint 时清理旧映射。

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
  -> 返回 proxyChannel.localAddress
  -> state = idle

独立 UDP datagram 到共享 service
  -> parse relay header
  -> routeUDPWire(target)
  -> 按 source IP:port 获取/创建 backend Channel
  -> AddressedEnvelope 写给 target 或代理节点
  -> 回包解密/透传
  -> 封装 SOCKS5 UDP response
  -> 写回原 UDP source IP:port
```

## 3.4 关闭

TCP CONNECT 的关闭规则与其他 TCP 协议一致：

- accepted `proxyChannel` inactive/error 向下关闭 `wireChannel`。
- `wireChannel` inactive/error 向上关闭 `proxyChannel`。
- `closed` 防止循环。

共享 UDP service inactive 时清空并 shutdown cache。每个 backend handler 也订阅当前
Magent 运行周期的 `shutdownFuture`。

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
| UDP fragmentation | 丢弃 |
| UDP 每包目标不同 | 支持 |
| UDP connect timeout | 不适用；UDP Channel 无连接且复用多个目标 |
| UDP 空闲资源 | 600 秒 after-write TTL、容量和 shutdown 回收 |
| TCP control 与 UDP source 强绑定 | 不做，当前是共享开放 relay |
| TCP read/write idle timeout | 尚未实现 |
| TCP 双向背压 | 尚未实现 |

## 4.3 验证重点

- no-auth negotiation 分片与无可接受 method。
- CONNECT/BIND/UDP ASSOCIATE reply。
- IPv4、IPv6、domain 地址编解码。
- SOCKS5 UDP reserved、FRAG 和不完整地址拒绝。
- direct/代理 UDP response source 封装。
- association TTL/容量淘汰关闭 backend Channel。
- proxy endpoint 唯一性保证回包使用正确 Wire。
