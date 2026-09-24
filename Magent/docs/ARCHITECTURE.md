# Magent Architecture

Magent is a SwiftNIO-based local proxy service packaged as a single Swift
module. Applications configure and control the service through a deliberately
small public API. Protocol detection, routing, channel management, and remote
proxy implementations remain implementation details of the package.

## Design and Specification Index

### Architecture-related specifications

- [Model specifications](MODELS_SPEC.md): normative NetworkAddress, HttpProtocol,
  ProxyNode, and ProxyRule contracts, associated enums, ownership boundaries, and
  acceptance criteria.
- [SOCKS4 specification](SOCKS4_PROXY_SPEC.md): protocol design, packet vectors,
  and acceptance criteria.
- [SOCKS5 specification](SOCKS5_PROXY_SPEC.md): TCP/UDP protocol design, routing,
  and acceptance criteria.
- [HTTP specification](HTTP_PROXY_SPEC.md): forward proxy and CONNECT design,
  request/response handling, and acceptance criteria.
- [W-TinyLFU cache specification](W-TinyLFU_CACHE_SPCE.md): proposed cache
  functionality, constraints, algorithm invariants, and acceptance criteria.

### Product designs and supporting evidence

- [Product design](design/DESIGN.md): overall guidance, writing rules, and the
  component design index with each document's status and scope.
- [Match benchmark](benchmark/MATCH_BENCHMARK.md): routing match/cache workload,
  test entry points, device metadata, and results across matching types.
- [Cache benchmark](benchmark/MAGENT_CACHE_BENCHMARK.md): target measurement scope
  and archived results from the previous implementation; target results are pending.

This document owns package boundaries, resource ownership, lifecycle, and
protocol integration constraints. The model SPEC owns mandatory model contracts;
the cache SPEC owns proposed cache semantics and algorithm invariants; the
protocol SPECs own detailed message formats, product profiles, and acceptance
matrices. Do not maintain a separate per-protocol implementation design document
that duplicates these responsibilities.

SPECs define standalone functionality and constraints without references to
product designs. Designs reference and implement SPECs; comparisons and migration
details belong in the design, while this index may link to both.

The SPECs include proposed capabilities and product choices that differ from the
current package. Check source and tests before treating a requirement as
implemented. The [protocol integration constraints](#protocol-integration-constraints)
below record the current boundaries and distinguish them from future targets.

## 模型与 SPEC 的强制契约

所有模型及关联类型必须严格遵循对应 SPEC。`NetworkAddress`、`HttpProtocol`、`ProxyNode`、
`ProxyRule` 及其关联枚举以 [模型规范](MODELS_SPEC.md) 为契约依据；其他模型同样必须有所属 SPEC
明确其职责和使用边界。SPEC 中尚未实现的要求属于实现缺口，不构成消费方自行扩展模型的授权。

- **约束随类型生效。** 字段、存储不变量、构造入口、访问级别、供调用方使用的方法、协议符合性、
  校验和错误语义均须符合 SPEC。该约束覆盖公开和内部模型，也覆盖定义在任意目录、任意文件中的
  `extension`；不能借助 `internal`、`private` 或改变文件位置绕过模型边界。
- **调用方适配契约。** Connection、Core、Wire、应用和测试只能按 SPEC 消费模型，不得为了某个
  使用位置方便，添加未定义的构造器、转换方法、可写状态、协议符合性、默认值或兼容入口。
  也不得绕过已规定的构造与校验入口直接拼装内部状态。
- **协议行为留在协议所有者。** HTTP、SOCKS、Shadowsocks 的消息边界、ATYP、二进制地址字段和
  协议编解码由对应 Connection / Wire 负责。不得通过 `extension NetworkAddress` 给通用地址模型
  增加 `shadowsocksAddressBytes()`、`decodeShadowsocksAddress(from:)` 等协议专用能力。
  共享实现先放入已有的职责所有者；新增 Swift 文件仍须遵循 `AGENTS.md` 的明确授权要求。
- **先确定契约，再实现需求。** SPEC 未定义的模型能力不能直接加入实现。确有实际业务需求时，
  先提出并确认 SPEC 的职责、接口和验收标准变更，再修改代码；不得先扩展代码，再倒改 SPEC
  为该实现提供依据。没有实际使用场景的能力不预先设计。
- **迁移遵循目标模型。** 旧调用、旧扩展或测试与 SPEC 冲突时，修正对应的调用方和职责归属，
  不向模型恢复旧 API，不添加测试专用路径，也不以现有代码已经存在为由保留越界能力。
- **验收必须包含消费路径。** 模型修改须核对类型本体、全部扩展和实际调用，并按 SPEC 验证模型
  不变量及相关集成路径。模型定向测试通过不等于整包或协议验收通过；未迁移的调用、构建失败和
  尚未执行的验收必须明确记录，不能据此宣称实现已完整遵循 SPEC。

## SPEC 文档格式

`docs/` 下所有 SPEC 都必须采用同一种文件头格式：文件第一行是 `---`，中间是 YAML 元信息，
以独立一行 `---` 结束；空一行后写一级标题，再写正文。不要把元信息放进引用块、加粗行、
普通段落或标题副标题，也不要在各章节重复维护另一份文档版本、日期或状态。

```markdown
---
desc: "一句话说明本规范的对象、范围和主要契约。"
version: "0.1.0"
updated_at: "2026-09-23"
status: "草案"
---

# 规范标题

正文从这里开始。
```

### 字段与顺序

以下四个字段必填，顺序固定。字段名使用这里规定的英文键，描述和状态值使用中文，所有值用双引号包围。

| 字段 | 含义与写法 |
|---|---|
| `desc` | 一句话说明规范对象、功能范围和主要契约；不写实现完成声明、编辑过程或交付包装说明。 |
| `version` | 本规范的版本，统一为 `主版本.次版本.修订号`，例如 `"1.0.0"`；不附加 `draft` 等状态文本。 |
| `updated_at` | 最近一次规范内容修订日期，格式为 `YYYY-MM-DD`；仅整理排版或迁移元信息时保留原日期，不伪造历史时间。 |
| `status` | 只使用 `草案`、`已确认`、`已废弃`；分别表示仍可调整的提议、已经确认的规范契约、不再采用的规范。 |

需要补充元信息时，只使用以下可选字段，按表中顺序接在 `status` 后；不适用时省略，不填空值：

| 字段 | 含义与写法 |
|---|---|
| `notes` | 影响文档阅读的补充说明，例如某个模型的候选方案仍待决定；不代替正文中的功能约束和待决定事项。 |
| `references_checked_at` | 最近一次实际核对外部资料的日期，格式为 `YYYY-MM-DD`；与文档内容修订日期分别维护，不能因整理文档而刷新。 |

不要另起 `description`、`date`、`Version`、`Status` 或中文键等同义字段。标题保留在正文的一级标题中，
不再添加 `title` 重复保存。需要新字段时，先在本节定义用途和顺序，再统一使用。

### 维护与验证

- `status` 只描述规范是否确认，不表示功能已经实现或测试通过。实现状态和验收结论需要独立证据；
  不得因本次整理、实现部分功能或版本号为 `1.0.0` 就把草案改为已确认。
- 仅统一格式不提升规范版本。现有 `1.0` 可补齐为 `1.0.0`，`1.0 draft` 拆为 `version: "1.0.0"`
  与 `status: "草案"`；这不代表新增功能或完成验收。功能契约变更时再调整版本及内容修订日期。
- 文档版本与协议版本、配置 `schema_version`、实现配置 `profile` 是不同概念。后几项属于正文契约和示例，
  不挪到文档 `version` 中，也不随元信息整理修改。
- 文件头只保存元信息。正文保留功能范围、约束、错误语义、示例、验收标准和必要的方案决策说明；
  不增加章节级 YAML 文件头。正文中原有分隔线可保留，它们不构成元信息区块。
- 修改后验证 YAML 可解析、字段及顺序符合要求、标题紧随文件头，并检查章节锚点、链接、协议示例和验收编号。
  文档格式整理只做文档验证，不作为编译、运行或协议验收通过的证据。

## Source Layout

Paths in this document are relative to the package root. The source tree is
available at [Sources](../Sources/).

```text
Sources/
├── Magent.swift
├── MagentError.swift
├── Model/
├── Connection/
├── Core/
└── Wire/
    └── Shadowsocks/
```

The directories organize responsibilities inside the `Magent` target. They do
not create separate Swift modules.

### Public API

`Magent.swift` is the main entry point for applications. It contains:

- `MagentConfig`, the complete configuration for one running service;
- `Magent`, the actor that owns the service lifecycle, TCP listener, accepted
  connections, and `EventLoopGroup`.

Applications start, reconfigure, and stop the service through `start(_:)`,
`restart(_:)`, and `close()`. They do not create listeners, parse local proxy
handshakes, select routes, or move request and response bytes themselves.

`MagentError.swift` defines the public error taxonomy shared by configuration,
protocol parsing, routing, cryptography, channel creation, and service
lifecycle operations.

`Model/` contains the public values used to construct `MagentConfig`:

- `NetworkAddress` describes a domain, IPv4, or IPv6 endpoint;
- `ProxyNode`, `ProxyNodeType`, and `ProxyCipher` describe a remote proxy node;
- `ProxyRule`, `MatchType`, and `Decision` describe routing policy.

Small parsing helpers that also live under `Model/`, such as `HttpProtocol`,
remain internal. Source location alone does not make a type public; Swift
access control is the authoritative visibility boundary. Model responsibilities
and permitted APIs remain governed by the mandatory SPEC contract above,
including extensions located outside `Model/`.

Everything under `Connection/`, `Core/`, and `Wire/` is an implementation
detail. Some cache types use `package` access so the package's benchmark target
can exercise them, but they are not part of the API exposed to applications.

## Internal Layers

### Connection

`Connection/` implements the local proxy frontends and owns accepted-connection
protocol state.

`MagentTCPConnection` is installed on every accepted TCP channel. It buffers
the initial bytes until it can identify one supported frontend and then hands
the channel to a concrete connection:

- `HttpConnectConnection` for HTTP CONNECT tunnels;
- `HttpForwardConnection` for the supported HTTP forward-proxy subset;
- `Socks4Connection` for SOCKS4 and SOCKS4a CONNECT;
- `Socks5Connection` for SOCKS5 CONNECT and UDP ASSOCIATE.

Each concrete connection parses its local protocol incrementally, derives the
requested destination, asks `Core` for a routing decision, opens and owns the
downstream channel, and forwards data in both directions. It also owns the
frontend-specific success or failure reply and its protocol state machine.

The Connection layer does not define routing policy and does not implement a
remote proxy protocol. It consumes the decision and `Wire` selected by Core.

### Core

`Core/` contains the service's routing and channel-construction logic.

`MagentCore` is created from one `MagentConfig` for one running service cycle.
It owns the node registry, compiled rule matcher, route cache, default routing
decision, and the factories that select concrete `Wire` implementations. A
route produces one of two results:

- direct: connect the downstream channel to the requested destination without
  a `Wire`;
- proxy: resolve the referenced node and return the corresponding TCP or UDP
  `Wire`.

`MagentCore` also creates downstream TCP and UDP channels with the required
timeouts and SwiftNIO channel options. `MagentCache` provides the internal
WTinyLFU cache used for repeated route lookups.

The Core layer coordinates policy and transport selection, but it does not
parse local HTTP or SOCKS requests and does not encode a concrete remote proxy
protocol.

### Wire

`Wire/` represents concrete protocols used to communicate with remote proxy
servers.

The internal `Wire` protocol defines how a backend:

- selects its remote server address and connection timeout;
- creates any startup handshake;
- encodes outbound plaintext;
- decodes inbound protocol data back into plaintext and a destination address.

`Wire` does not own a SwiftNIO channel. The concrete Connection owns the
channel and calls its selected `Wire` on that channel's event loop.

`Wire/Shadowsocks/` contains the current backend implementation. It includes
Shadowsocks address encoding, AEAD encryption, key derivation, and separate TCP
and UDP wire behavior. Each proxied TCP stream receives a new
`ShadowsocksTCPWire`, keeping stream encryption state such as salts, nonces,
and frame buffers isolated per connection.

## Request Flow

```text
Application
    |
    | MagentConfig + start(_:)
    v
Magent
    |-- owns EventLoopGroup and local TCP listener
    |-- creates one MagentCore for the running configuration
    v
MagentTCPConnection
    |-- detects HTTP, SOCKS4, or SOCKS5
    v
Concrete Connection
    |-- parses the request and destination
    |-- asks MagentCore to route the destination
    v
MagentCore
    |-- direct ------------------------> destination server
    |
    `-- proxy --> concrete Wire -------> remote proxy server
                    |
                    `-- encodes and decodes the backend protocol
```

For a proxied connection, the same selected `Wire` determines both the remote
server endpoint and the encoding state used for the lifetime of that stream.
For a direct connection, the concrete Connection forwards unwrapped bytes to
the original destination.

## Ownership and Lifecycle

- The application owns platform permissions, persistence, UI, system proxy
  settings, and Network Extension integration.
- `Magent` owns its `EventLoopGroup`, local listener, accepted TCP channels,
  and each running cycle's shutdown signal.
- `MagentTCPConnection` owns the accepted channel's protocol detection and
  overall frontend lifecycle.
- A concrete Connection owns its protocol state, downstream channel, and any
  protocol-specific relay resources.
- A `Wire` owns only backend protocol state; it never owns the channel carrying
  that state.

The library does not read or write databases, define SQL schemas, or own storage
migrations. Applications translate persisted records into `MagentConfig` and its
public model values before calling the lifecycle API. Database and SwiftData
designs belong to the consuming application's documentation.

Each runtime has its own shutdown promise. Accepted connections subscribe to
that runtime's shutdown signal; closing a SOCKS5 control connection also releases
its UDP channels and optional DNS client. A restart creates a new Core and a new
shutdown promise, so old connections never adopt the replacement configuration.

`ProxyConnection.closeConnection(error:)` closes downstream resources only.
The accepted channel remains owned by `MagentTCPConnection`. Inactive and error
callbacks check the closed state before propagating cleanup to avoid close loops.

`start(_:)` validates the configuration and creates Core before binding the
listener. Configuration or Core initialization failure leaves the group available
for another attempt. Listener startup failure completes the shutdown promise and
shuts down the group; create a new `Magent` instance after that failure.

`restart(_:)` validates the new configuration and creates a new `MagentCore`
before closing the current running cycle, then binds the replacement listener
using the service-owned `EventLoopGroup`. Configuration or Core initialization
failure leaves the old cycle running. Replacement bind failure leaves the
service stopped with the group available for another `start`.

`close()` also shuts down the group and is terminal for that `Magent` instance.
It is not idempotent: `close` and `restart` throw when the service is stopped,
and `start` throws when it is already running. Restart closes existing tunnels.
Lifecycle methods are actor-isolated synchronous boundaries that wait for NIO
futures; call them from outside NIO EventLoops. External actor callers use `await`.

See [Magent.swift](../Sources/Magent.swift) for the lifecycle implementation and
[MagentTests](../Tests/MagentTests.swift) for its regression tests.

The default proxy node is validated when Core is initialized. Nodes referenced
by individual rules are checked when the route is used. Magent does not impose
an established-connection count limit; the listener backlog is a separate setting.

## Protocol Integration Constraints

### Scope and Specification Relationship

The ownership and ordering rules below apply to this SwiftNIO package. Capability
limits marked as current describe the working tree reviewed on 2026-09-22; they
are not a requirement to preserve every existing limitation. Moving toward a
different SPEC profile requires corresponding code, model, and regression-test
changes. Document consolidation does not resolve an implementation gap or prove
SPEC compliance.

The broader HTTP/SOCKS SPECs describe standalone service profiles with SOCKS5
upstreams or an external `sslocal` bridge, a REJECT action, first-configured-match
routing, and configuration snapshots that can outlive an update. The current
package has native Shadowsocks Wires, direct/proxy decisions, rule ordering by
`order` then specificity and input position, and restart-scoped Core instances
that close the old connections. Those differences require explicit design
changes, not new wrappers or features inferred from an example configuration.

`MODELS_SPEC.md` is the mandatory contract for model implementation and use;
it is not evidence that today's code satisfies that contract. Existing gaps
must be fixed within the specified ownership boundaries, not by adding model
APIs for individual consumers. Its pure `HttpProtocol` model and revised OPTIONS
handling must not be reported as implemented merely because this document links
to that SPEC. Existing [SOCKS5 review findings](review/README.md) retain their
own status and verification requirements.

### Shared TCP Lifecycle

- `MagentTCPConnection` incrementally probes the accepted byte stream, selects
  one concrete frontend, and transfers all buffered bytes to it. A probe match
  is not request validation. The HTTP probe accepts token methods up to 32 bytes;
  a target beginning with `https://` can select the forward parser and still be
  rejected by that parser.
- A TCP request performs one `routeTCPWire` selection. `nil` means direct;
  there is no separate Direct Wire. The selected proxy Wire determines both the
  node endpoint and the stream state. A missing node or failed proxy does not
  fall back to direct. Direct connect uses `MagentConfig.defaultTimeout` in
  milliseconds, currently 10_000 by default; proxy connect uses `Wire.getTimeout()`.
- Outbound TCP setup runs on the accepted channel's EventLoop and continues
  through futures. A handler must not block that loop with `wait()`. If the
  accepted connection closes during setup, a late-created channel must be
  closed instead of reviving the connection.
- Proxy TCP startup sends `Wire.start(handshake: target)` once. Subsequent
  payload writes encode bytes with no repeated destination. SOCKS and CONNECT
  frontends write their local success only after channel creation and completion
  of any Wire startup write; tunnel reads begin after that local reply write
  completes. With native Shadowsocks this proves a node connection and a local
  startup write, not a remote acknowledgement that the business target is reachable.
- TCP directions use `autoRead=false`: resume the source after the destination's
  `writeAndFlush` completes. A Wire decode that yields no complete plaintext must
  resume downstream reads so an encrypted partial frame can finish. Avoid an
  unbounded queue of independently scheduled writes.
- Input EOF closes the opposite output after pending payload writes, while
  leaving the reverse direction usable. An incomplete handshake followed by EOF
  terminates; EOF after a complete request can be deferred until setup finishes.
  Full close and errors follow the ownership rules above, with closed-state
  guards preventing recursive cleanup and duplicate handshake replies.

Current SOCKS4, SOCKS5, and HTTP CONNECT parsers reject bytes after a complete
handshake message and before its success reply, including same-read remainder.
SOCKS5 also rejects a greeting coalesced with the following request. The protocol
SPECs' bounded early-data/remainder handling is a different, unimplemented
profile. The current frontends have 64 KiB request guards; HTTP forward counts
the whole buffered request including its body. NIOHTTP1 may impose smaller
syntax limits. These guards do not implement the SPECs' global resource budgets,
inbound handshake deadlines, or TCP idle timers.

The current frontends use no local authentication; SOCKS4 USERID is not an
identity check and SOCKS5 only negotiates no-auth. The application chooses
listener exposure, including non-loopback addresses. Authentication and access
policies described in a broader SPEC are not implicitly provided by the package.

Source and existing test vectors: [protocol probe and accepted-channel owner](../Sources/Connection/MagentTCPConnection.swift),
[probe tests](../Tests/Connection/MagentTCPConnectionTests.swift), and the
frontend-specific files linked below. Test presence, including an expected
failure for a known SPEC gap, is not evidence that the target behavior passes.

### SOCKS4 and SOCKS4a

`Socks4Connection` owns the incremental request, local reply, and TCP tunnel.
It supports CONNECT with a SOCKS4 IPv4 target or SOCKS4a domain target; it rejects
BIND and provides no UDP command. USERID is consumed only to locate its NUL
terminator, and SOCKS4a reads a separate NUL-terminated domain. The frontend must
not substitute USERID for a missing domain or forward it as node authentication.

Current replies are local granted (`0x5A`) or rejected (`0x5B`), with zero bound
address/port fields. They are not replies received from a Shadowsocks node.
Detailed packet layouts, field limits, and the broader remainder-preserving
parser target remain in the [SOCKS4 SPEC](SOCKS4_PROXY_SPEC.md).

Implementation: [Socks4Connection](../Sources/Connection/Socks4Connection.swift).
Existing vectors: [Socks4ConnectionTests](../Tests/Connection/Socks4ConnectionTests.swift).

### SOCKS5 TCP

`Socks5Connection` owns greeting, request, tunnel/association-control, and closed
states. Greeting and command replies are separate writes. CONNECT supports
IPv4, IPv6, and domain targets; UDP ASSOCIATE creates the resources described
below; BIND is rejected. A CONNECT business port must be nonzero, while an
ASSOCIATE source hint can use port zero and is not a business destination.

CONNECT success encodes the downstream channel's local endpoint as BND, using
`0.0.0.0:0` only when no usable local endpoint is available. Current failure
mapping belongs to this frontend: general failure `0x01`, missing node/policy
`0x03`, connect timeout `0x04`, unsupported option/command `0x07`, and invalid
address `0x08`. The more detailed failure mapping in the
[SOCKS5 SPEC](SOCKS5_PROXY_SPEC.md#s18) remains a separate acceptance target.

Implementation and existing vectors for both TCP and UDP:
[Socks5Connection](../Sources/Connection/Socks5Connection.swift),
[Socks5ConnectionTests](../Tests/Connection/Socks5ConnectionTests.swift).

### SOCKS5 UDP Associations

Each accepted control connection owns its association; there is no shared UDP
association cache or service-wide fixed UDP port. The current setup binds an
IPv4 relay/outbound channel to `0.0.0.0:0`, an IPv6 outbound channel to `[::]:0`,
and an optional DNS client on the control connection's EventLoop. Both UDP binds
must succeed. The control connection currently needs an IPv4 local address;
IPv6 control support described in the SPEC is not implemented.

The success reply publishes the TCP connection's concrete local IPv4 address
and the allocated relay port. Start UDP reads after that reply write completes;
clients must use the returned port, not assume it equals the TCP listener port.
Control close releases the UDP channels and DNS client. Runtime shutdown reaches
the same cleanup through control close. A resource created after control close
must be released. In current idle state, control FIN ends the association and
ordinary control bytes are ignored rather than interpreted as UDP data.

The following are current data-plane behaviors and limitations, not a claim
that the stricter source, isolation, or error-scope requirements in the SPEC
have been satisfied:

- The first datagram arriving on the IPv4 relay fixes the client source before
  its SOCKS5 payload is validated. The ASSOCIATE hint and TCP peer are not checked
  against that source. Later client-source comparison normalizes numeric aliases,
  but replies retain the original SocketAddress and transport family. First-packet
  pinning is not authentication.
- Each valid client datagram selects a route from its own target. Direct sends
  the payload; proxy encodes target plus payload through the selected UDP Wire.
  Domains on proxy routes are sent to the node without local target DNS.
- Responses use the association's map of actual outbound SocketAddresses and
  their selected Wire, with nil recording direct. The first entry for an endpoint
  is retained. Do not infer the Wire later from a global node table or treat an
  unknown response source as direct. Sharing one endpoint between direct and
  proxy traffic cannot independently distinguish their return paths in this map;
  the SPEC's per-flow channel isolation is not implemented.
- Direct IP needs no DNS. Direct domain uses the single server configured by
  `MagentConfig.dnsListener`; missing configuration fails the operation. A and AAAA
  queries must both complete successfully, then the first A is preferred over
  the first AAAA. The query timeout is `core.defaultTimeout`; there is no resolver
  fallback. Results are cached per association by target including port, without
  DNS TTL refresh. This is different from the SPEC's system-resolver design.
- Invalid packets, nonzero FRAG, unknown remote endpoints, and route/DNS/Wire
  failures currently enter the control error path and close the association.
  Packet-drop and flow-local failure isolation in the SPEC remain unimplemented.
- There is no association idle TTL or per-flow expiry. UDP has no TCP connect
  stage, so the node's TCP connect timeout does not bound UDP responses. Channel
  reads resume after the current datagram's asynchronous operation completes.

The [SOCKS5 SPEC](SOCKS5_PROXY_SPEC.md#s13) owns packet formats, source-hint rules,
flow isolation, and the full UDP acceptance matrix; it does not turn these
current limitations into verified behavior.

### HTTP CONNECT

`HttpConnectConnection` uses a temporary NIOHTTP1 request decoder/handler for the
handshake, then returns the pipeline to raw ByteBuffers. Decoder removal must
account for the whole current decode batch and its leftovers before dialing;
otherwise bytes after the CONNECT request can escape the strict remainder rule.
Only the frontend owns the transition from HTTP reply writing to tunnel writing.
Core does not parse HTTP and Wire does not emit HTTP status codes.

The current request profile accepts HTTP/1.0 and HTTP/1.1 authority-form with an
explicit nonzero port and bracketed IPv6. HTTP/1.1 requires exactly one Host;
HTTP/1.0 allows at most one; a supplied Host must agree with the target. All
Content-Length fields, including zero, and Transfer-Encoding are rejected, as
are bodies and trailers. These differ from the broader HTTP SPEC's version and
CONNECT framing choices.

The frontend generates its own `200 Connection Established` after the shared
TCP startup sequence; the CONNECT request itself is consumed locally and never
becomes target payload. Request errors use 400, downstream setup failures use
502, and connect timeout uses 504, followed by close. Tunnel payload is opaque:
CONNECT does not provide TLS interception or UDP transport.

Implementation: [HttpConnectConnection](../Sources/Connection/HttpConnectConnection.swift).
Existing vectors: [HttpConnectConnectionTests](../Tests/Connection/HttpConnectConnectionTests.swift).
Complete target behavior: [HTTP SPEC](HTTP_PROXY_SPEC.md#s18).

### HTTP Forward

`HttpForwardConnection` currently buffers one complete HTTP/1.0 or HTTP/1.1
request through NIOHTTP1 before routing or dialing. The 64 KiB aggregate limit
includes headers and body. It supports no body or a single Content-Length body;
Transfer-Encoding, duplicate Content-Length/Host, Expect, Upgrade, trailers,
pipelining, and subsequent keep-alive requests are rejected. It does not provide
streaming upload or the response parser required by the full HTTP SPEC.

Current target extraction accepts `http://` absolute-form and Host-based
origin-form, with port 80 as the default; `OPTIONS *` is forwarded to the Host
target. HTTPS absolute-form, userinfo, and fragments are rejected. Absolute-form
uses the URI target and replaces Host, while CONNECT checks authority/Host
agreement. The new HttpProtocol model SPEC has its own stricter method and header
contract; in particular its rejection of `OPTIONS *` is still a planned change.

Rewrite absolute-form to origin-form without losing percent-encoded path/query,
regenerate Host, strip fixed hop-by-hop fields and fields named by Connection,
remove proxy credentials, and set `Connection: close`. This belongs to the HTTP
frontend/model boundary, not Core or Wire. A proxy route first writes the Wire
startup, then the encoded rewritten request; start response reads only after the
request write succeeds. There is no local success response to insert before the
origin's response.

Downstream response bytes are relayed directly or after Wire decryption; the
current frontend does not parse status, headers, framing, or response completion
for connection reuse. It reads the next downstream batch after the client write
completes. A complete request followed by client input EOF still allows the
reverse response direction. Local request/setup/timeout failures use 400/502/504
and close. Chunked transfer, response validation, ordered keep-alive, pipelining,
and Upgrade in the broader HTTP SPEC remain future work.

Implementation: [HttpForwardConnection](../Sources/Connection/HttpForwardConnection.swift).
Existing vectors: [HttpForwardConnectionTests](../Tests/Connection/HttpForwardConnectionTests.swift).
Detailed request semantics: [model SPEC](MODELS_SPEC.md#httpprotocol).
Complete product target: [HTTP SPEC](HTTP_PROXY_SPEC.md).

## Where New Behavior Belongs

- Add a new public configuration concept to `Magent.swift` or the public model
  that consumes it.
- Add a new local proxy protocol frontend to `Connection/`.
- Add or change rule matching, node selection, caching, or channel construction
  in `Core/`.
- Add a new remote proxy-server protocol to `Wire/`, with its concrete backend
  implementation in a dedicated subdirectory.
- Add public failure cases to `MagentError.swift`; keep backend-only helpers
  internal.

These boundaries keep applications independent of SwiftNIO pipelines and
backend wire formats while allowing the internal layers to evolve without
expanding the public API.
