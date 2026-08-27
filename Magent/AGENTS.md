# Magent Package Context

## Concurrency design constraint

Do not default to an immutable snapshot design for every consistency or concurrency issue. First determine the
actual lifecycle and ownership boundary. `Magent.restart(_:)` creates a new `MagentCore` for the next runtime,
reuses the service-owned `EventLoopGroup`, and signals the old runtime to close. Evaluate this instance-isolation
model before proposing snapshots. A snapshot is appropriate only when live mutation inside one runtime is an
explicit requirement.

## Library Scope and Public Boundary

`Magent/` is a reusable local proxy service. The public entry is `Magent`, configured by `MagentConfig` and
controlled through `start(_:)`, `restart(_:)`, and `close()`.

`Magent` owns and manages:

- its `MultiThreadedEventLoopGroup`;
- the TCP listener created by `ServerBootstrap`;
- accepted local TCP channels;
- direct or proxied TCP wire channels;
- per-control-connection UDP relay channels.

The application owns platform permission, persistence, UI, system proxy or Network Extension integration, and the
decision to expose a loopback, LAN, or wildcard listen address. It must call Magent lifecycle methods from outside
NIO EventLoops because those methods are synchronous actor boundaries that wait for NIO futures.

Do not reintroduce `MagentClient`, `attach(channel:)`, `getConnection`, an application-owned listener/group model,
or a public `MagentConnection`. The application supplies one complete `MagentConfig`; it does not parse local
proxy handshakes or move request/response `Data`.

`close()` closes the current runtime and shuts down the service-owned EventLoopGroup. Treat it as terminal for that
`Magent` instance. Use `restart(_:)` before `close()` for an in-place configuration switch, or create a new
`Magent` instance after a terminal close.

## Comments and Readability

Code must not be written as unexplained implementation-only blocks. Add documentation comments to public API and
to internal types or methods whose ownership, state transitions, protocol rules, concurrency, buffering, or
cleanup behavior is not obvious.

Comments should explain why a design or lifecycle rule exists, especially for:

- incremental protocol buffers and strict handling of bytes after a complete request;
- actor state transitions and proxy/wire channel ownership;
- backpressure, EOF, half-close, error mapping, and resource cleanup;
- rule/node consistency and cryptographic nonce or frame handling;
- every non-structured `Task`, including who owns it and how completion is joined.

Do not add comments that merely repeat a single obvious statement. Keep comments updated when behavior changes.
Use `// MARK:` sections where they materially improve navigation.

## Concurrency and Task Lifecycle

Use the `EventLoopGroup` owned by the current `Magent` instance for all NIO channels. Do not create ad-hoc thread
pools, raw threads, `Task.detached`, or fire-and-forget tasks.

Each start/restart runtime has one shutdown promise. Accepted TCP handlers subscribe to that promise; closing an
accepted SOCKS5 control connection closes its UDP relay channel. A restart creates a new promise and a new Core;
never reuse a completed promise for the new runtime.

Prefer NIO futures and EventLoop callbacks for channel setup. Never call `.wait()` or `.get()` from a Channel
handler on the same EventLoop. If a connection genuinely requires a plain Swift `Task`, the parent connection must
store it, cancel it during cleanup, close any suspending channel/stream, and join `task.value` before releasing the
parent resources. A task must not call a cleanup path that awaits that same task.

## Files and Abstractions

Do not add a Swift source file unless the user has explicitly approved that file or explicitly requested an
abstraction that cannot reasonably live in an existing file. Before proposing a new file, first try to place the
code in the existing type/file that owns the behavior.

Do not create one-file wrappers, marker protocols, forwarding protocols, context actors, routers, or result types
merely to rename control flow.

Production code under `Sources/` must not contain methods, initializers, branches, flags, placeholder configuration,
hooks, or defaults that exist only to make tests easier. Tests must construct every dependency required by the real
production API and exercise the same initialization and lifecycle paths used by production callers. If a test
cannot be written without adding a test-only surface to production code, stop and ask the user before adding it.

Whenever three or more consecutive lines implement the same control flow or resource lifecycle in multiple places,
explicitly evaluate a shared abstraction before retaining the duplication. Prefer extending an existing owner type
or protocol over creating another wrapper. Similar-looking code with different protocol semantics may remain
separate, but that distinction must be documented.

A function with exactly one call site and fewer than five implementation lines should normally be inlined. Keep it
separate only when it is a protocol/conformance requirement, forms a tested semantic boundary, or enforces a
non-obvious invariant. Any function longer than 100 lines must be reviewed for cohesive sub-operations.

Keep public support types next to the public API that consumes them. Keep small internal channel helpers next to
`Magent`, `MagentTCPConnection`, or the concrete protocol connection instead of creating standalone wrappers.

## Connection and Protocol Ownership

`Magent.start(_:)` installs one `MagentTCPConnection` for every accepted TCP channel. `MagentTCPConnection` owns
protocol detection and the accepted channel lifecycle. It buffers until `ProxyProbe` selects exactly one concrete
connection: `Socks4Connection`, `Socks5Connection`, `HttpConnectConnection`, or `HttpForwardConnection`.

Each concrete TCP connection owns its incremental request buffer, protocol state, selected `Wire`, and downstream
`wireChannel`. `ProxyConnection.closeConnection(error:)` closes only downstream resources; it must not close the
accepted proxy channel owned by `MagentTCPConnection`. All `channelInactive` and `errorCaught` paths must guard the
closed state before propagating cleanup to avoid recursive close loops.

SOCKS4, SOCKS5, and HTTP CONNECT use strict request/reply ordering: bytes received after a complete handshake
request but before the local success reply are rejected. HTTP forward currently supports one request only and
rejects chunked framing, pipelining, and subsequent keep-alive requests. Do not document these boundaries as full
HTTP or SOCKS RFC compliance.

The TCP wire startup handshake is a distinct operation after a target and wire channel have been selected.
Subsequent outbound writes contain tunnel payload only. Every TCP route performs one rule match and, for proxy
routes, one node/Wire selection; the same Wire determines both dial endpoint and stream state for that connection.
Proxy TCP connect timeout comes from `Wire.getTimeout()`.

Pure TCP outbound work and each SOCKS5 control connection's UDP relay channel use the accepted channel's
EventLoop.

SOCKS5 UDP ASSOCIATE creates one UDP relay channel for the control connection and binds it to an ephemeral port.
The first datagram fixes the client source `IP:port`; the relay records each actual backend SocketAddress and its
selected Wire so responses can be decoded and returned to that client. Closing the control connection closes its
UDP relay channel. Unsupported fragmentation is rejected.

## Validation

Run package commands from `Magent/`. Changes to connection, concurrency, buffering, or cleanup code require at
least:

```bash
swift build
swift build -Xswiftc -strict-concurrency=complete
swift test --filter ConnectionTests
swift test
git diff --check
```

Tests requiring an external Shadowsocks server must remain explicitly guarded by environment variables and report
their skip reason.
