# Magent Architecture

Magent is a SwiftNIO-based local proxy service packaged as a single Swift
module. Applications configure and control the service through a deliberately
small public API. Protocol detection, routing, channel management, and remote
proxy implementations remain implementation details of the package.

## Design and Specification Index

- [Model specifications](MODELS_SPEC.md): proposed NetworkAddress, HttpProtocol,
  ProxyNode, and ProxyRule contracts, associated enums, ownership boundaries, and
  acceptance criteria.
- [SOCKS4 specification](SOCKS4_PROXY_SPEC.md): protocol design, packet vectors,
  and acceptance criteria.
- [SOCKS5 specification](SOCKS5_PROXY_SPEC.md): TCP/UDP protocol design, routing,
  and acceptance criteria.
- [HTTP specification](HTTP_PROXY_SPEC.md): forward proxy and CONNECT design,
  request/response handling, and acceptance criteria.
- [W-TinyLFU cache design](WTiny_LFU_Cache_Design.md): cache contracts, expiration,
  concurrency, and maintenance.
- [Match benchmark](benchmark/MATCH_BENCHMARK.md): routing match/cache workload,
  test entry points, device metadata, and results across matching types.

This document owns package boundaries, resource ownership, lifecycle, and
protocol integration constraints. The model SPEC owns proposed model contracts;
the protocol SPECs own detailed message formats, product profiles, and acceptance
matrices. Do not maintain a separate per-protocol implementation design document
that duplicates these responsibilities.

The SPECs include proposed capabilities and product choices that differ from the
current package. Check source and tests before treating a requirement as
implemented. The [protocol integration constraints](#protocol-integration-constraints)
below record the current boundaries and distinguish them from future targets.

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
access control is the authoritative boundary.

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

`MODELS_SPEC.md` is also a proposed contract, not a description of today's model
implementation. For example, its pure `HttpProtocol` model and revised OPTIONS
handling must not be reported as implemented merely because the architecture
links to that SPEC. Existing [SOCKS5 review findings](review/README.md) retain
their own status and verification requirements.

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
