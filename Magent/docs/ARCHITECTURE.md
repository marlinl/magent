# Magent Architecture

Magent is a SwiftNIO-based local proxy service packaged as a single Swift
module. Applications configure and control the service through a deliberately
small public API. Protocol detection, routing, channel management, and remote
proxy implementations remain implementation details of the package.

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
