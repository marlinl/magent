# Magent

English | [中文](README_zh.md)

Magent is a SwiftNIO-based proxy service library for embedding HTTP and SOCKS
proxying in applications. Configure a `Magent` instance, start its local listener,
and let the library handle protocol detection, routing, connections, and forwarding.

The application owns its UI, persistence, platform permissions, and system proxy
or Network Extension integration. Magent owns its networking resources.

## Features

- HTTP CONNECT and a restricted HTTP forward proxy.
- SOCKS4, SOCKS4a, and SOCKS5 CONNECT; SOCKS5 UDP ASSOCIATE.
- Direct connections and Shadowsocks AEAD TCP/UDP forwarding.
- Routing by exact domain, domain suffix, domain keyword, or IPv4/IPv6 CIDR.
- Independent encryption state for each Shadowsocks TCP stream.
- Configuration replacement through `restart(_:)`.

Supported ciphers are `aes-128-gcm`, `aes-256-gcm`,
`chacha20-ietf-poly1305`, and `xchacha20-ietf-poly1305`.

## Requirements

- Swift 6.4 or later, as required by [Package.swift](Package.swift).
- The package declares macOS 14 and iOS 17 as its minimum Apple platform versions.
- Permission to open the listener and outbound sockets in the host application.

## Installation

The Swift package lives in the repository's `Magent/` subdirectory. Clone the
repository, then add that directory as a local package in Xcode:

```bash
git clone https://github.com/marlinl/magent.git
```

For another Swift package, add the following entries to its `dependencies` array.
The local path is relative to the consuming package; adjust it to your checkout.
SwiftNIO is listed explicitly because the node and DNS examples use `NIOCore.SocketAddress`.

```swift
.package(path: "../magent/Magent"),
.package(url: "https://github.com/apple/swift-nio.git", from: "2.102.0"),
```

Add these products to the consuming target's `dependencies` array:

```swift
.product(name: "Magent", package: "Magent"),
.product(name: "NIOCore", package: "swift-nio"),
```

## Quick start

Run the following from an asynchronous application context. This starts a proxy
on `127.0.0.1:1080` and connects directly to requested destinations. No proxy node
is required.

```swift
import Magent

let listenAddress = NetworkAddress.domain("127.0.0.1", port: 1080)
let service = Magent(threadNumber: 2)
let directConfig = MagentConfig(address: listenAddress)

try await service.start(directConfig)
```

Keep the application running and retain the service for later reconfiguration or
shutdown. Clients may use HTTP CONNECT, HTTP forward, or SOCKS on the same TCP
listener; Magent detects the protocol automatically.

## Routing and proxy nodes

All proxy nodes belong in `proxyNodes`. A `.proxy(node.id)` decision selects one
of them by UUID. The following example creates both a global proxy configuration
and a configuration that proxies only domains matching a rule.

The server IP, DNS IP, and password below are placeholders. Replace them with
your own settings before using the proxy configurations.

```swift
import NIOCore

let node = ProxyNode(
    address: try SocketAddress(ipAddress: "192.0.2.10", port: 8388),
    cipher: .chacha20IetfPoly1305,
    password: "replace-with-your-password",
    timeout: 10
)

let globalConfig = MagentConfig(
    address: listenAddress,
    defaultDecision: .proxy(node.id),
    proxyNodes: [node]
)

let rule = try ProxyRule(
    matchType: .domainSuffix,
    matchValue: "example.com",
    decision: .proxy(node.id),
    order: 0
)

let ruleConfig = MagentConfig(
    address: listenAddress,
    rules: [rule],
    proxyNodes: [node],
    dnsAddress: try SocketAddress(ipAddress: "192.0.2.53", port: 53)
)
```

| Mode | Rules | Default decision |
| --- | --- | --- |
| Direct | Empty | `.direct` |
| Global proxy | Empty | `.proxy(node.id)` |
| Rule-based | Rules for the current run | Used when no rule matches |

Rules with smaller `order` values take precedence. If no rule matches, or the
rule list is empty, routing uses `defaultDecision`. A decision referencing a
missing node fails when that route is used; it does not fall back to a direct
connection. The `urlRegex` enum case is currently unsupported by the router.

## Configuration

`MagentConfig` describes one complete start or restart. Only `address` is required.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `address` | Required | Local TCP listener address; port must be in `1...65535`. |
| `defaultDecision` | `.direct` | Decision used when rules are empty or no rule matches. |
| `rules` | `[]` | Rules to match during this run. |
| `proxyNodes` | `[]` | All available nodes, including any selected by the default decision. |
| `defaultTimeout` | `10_000` | Direct TCP connection and UDP DNS query timeout, in milliseconds. |
| `dnsAddress` | `nil` | One DNS server address for direct SOCKS5 UDP domain destinations. |

`ProxyNode.timeout` controls proxied TCP connection attempts. It is expressed in
**seconds** and defaults to `30`, unlike `MagentConfig.defaultTimeout`.

`dnsAddress` only affects direct SOCKS5 UDP domain resolution. With `nil`, UDP
IP destinations and proxied domain destinations still work, but direct UDP
domain destinations are rejected. It does not override TCP hostname resolution,
and there is no fallback to a second configured DNS server.

Magent has no application-level connection count limit. EventLoop thread count
and listener backlog are not limits on established connections; practical
capacity depends on file descriptors, memory, and processing load.

## Reconfiguration and shutdown

Use the running service from the quick-start example:

```swift
try await service.restart(ruleConfig)

// When the application is finished using the service:
try await service.close()
```

`restart(_:)` creates a new runtime and replaces the listener while reusing the
service-owned EventLoopGroup. It closes the old runtime's connections; it is
not a seamless handover of existing tunnels. Editing a configuration value after
startup does not change an already running service.

Treat `close()` as terminal for that instance. Create a new `Magent` instance if
you need to start again after closing it. Call `start`, `restart`, and `close`
from outside NIO EventLoops: these actor-isolated lifecycle methods internally
wait for NIO futures. Calls from outside the actor use `await`.

## Protocol scope

- **HTTP:** HTTP/1.0 and HTTP/1.1 CONNECT are supported. HTTP forward handles one
  request per connection and rejects chunked framing, pipelining, and subsequent
  keep-alive requests. Use CONNECT for HTTPS; `https://` absolute-form forward
  requests are not supported.
- **SOCKS4/SOCKS4a:** CONNECT is supported. BIND, ident authentication, and native
  SOCKS4 IPv6 addresses are not supported.
- **SOCKS5:** No-auth CONNECT and UDP ASSOCIATE are supported. BIND, GSSAPI, and
  username/password authentication are not supported.
- **Handshake ordering:** SOCKS4, SOCKS5, and HTTP CONNECT reject payload bytes
  sent after a complete handshake request but before the local success reply.
- **UDP:** Each SOCKS5 control connection owns an ephemeral relay port. The
  current relay requires an IPv4 control connection, while outbound targets may
  use IPv4, IPv6, or domains. Closing the control connection closes its UDP and
  DNS resources. Only `FRAG=0` is supported; fragmented datagrams are rejected.
- **Other HTTP versions:** HTTP/2, HTTP/3, and Extended CONNECT are not supported.

These are the implemented protocol boundaries, not a claim of full HTTP or
SOCKS RFC compliance. See the [design document](../docs/Magent/Magent_Design.md)
for detailed behavior and known limitations.

## Deployment responsibilities

The application selects a loopback, LAN, or wildcard listen address. The local
proxy frontends currently provide no client authentication, so applications
exposing the listener must arrange their own access controls.

Magent does not configure the operating system's proxy settings, request
platform permissions, or persist node credentials. Those responsibilities stay
with the host application. Keep real server addresses, passwords, and local user
settings out of source control.

## Development

Run package commands from the repository's `Magent/` directory:

```bash
swift build
swift build -Xswiftc -strict-concurrency=complete
swift build -c release
swift test --filter ConnectionTests
swift test --filter AeadCipherTests
swift test
git diff --check
```

Tests cover routing, packet parsing, encryption, connection lifecycle, and local
TCP/UDP forwarding. Socket tests require local networking permissions; tests
requiring IPv6 loopback report a skip if it is unavailable.

Formatting uses the official `swift-format` bundled with the selected Xcode
toolchain. Formatting is run explicitly, not as a SwiftPM build-tool plugin:

```bash
xcrun swift-format format --in-place --parallel --recursive Package.swift Sources Tests
xcrun swift-format lint --strict --parallel --recursive Package.swift Sources Tests
```

| Directory | Contents |
| --- | --- |
| `Sources/Connection` | Protocol detection, frontend handshakes, and forwarding. |
| `Sources/Core` | Routing, node selection, channel creation, and caches. |
| `Sources/Model` | Addresses, nodes, rules, and protocol types. |
| `Sources/Wire/Shadowsocks` | Shadowsocks framing, addresses, and AEAD encryption. |
| `Tests` | XCTest unit tests and local networking tests. |

## License and contributions

Except where a file or third-party component states otherwise, Magent is licensed
under [GPL-3.0-only](../LICENSE). Contributions are governed by the
[Magent Contributor License Agreement](../CLA.md).
