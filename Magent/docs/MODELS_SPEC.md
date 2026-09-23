# Magent Model SPEC

Version: 0.1.0 · Date: 2026-09-22 · Status: design specification pending implementation

This document defines redesigned `NetworkAddress`, `HttpProtocol`, `ProxyNode`, and `ProxyRule` models and their acceptance contracts. Related enums are described in their respective model sections. The model APIs and the serialization formats they actually use may change; legacy construction paths that bypass validation are not retained. The interfaces in this document are design sketches and do not mean the current source implements them; this documentation change does not modify production code or tests.

## NetworkAddress

### 1. Purpose and responsibilities

`NetworkAddress` is an immutable value type representing **one IP address or hostname plus one port**. It describes the logical address in a proxy request and can also express an address field in a protocol response.

Successful construction must mean that the address satisfies this model's format contract and has already been normalized. Core and Wire can consume the value directly, without repairing, sanitizing, or normalizing it again.

The model is responsible for:

- Structural validation of IP addresses and hostnames.
- Unified representation of hostname case, IP text and raw bytes, and IPv4-mapped IPv6.
- The numeric port range.
- Deterministic equality, hashing, and serialization semantics.

The respective consuming layers are responsible for:

- Parsing HTTP, SOCKS, and Shadowsocks messages, their length fields, and command semantics.
- DNS queries, caching, resolution lifetimes, and search-suffix policy.
- Listening, connection establishment, address-family selection, and Channel lifecycle.
- Whether port `0` is valid for the current operation.
- Route-rule matching, destination safety policy, and protocol error replies.

Successful construction guarantees only format validity; it does not guarantee that a domain exists, a destination is reachable, or access is authorized.

### 2. Types and construction entry points

The public type is a `struct`, with an internal enum distinguishing address kinds. The read-only enum is for package-internal Core and Wire branches; no public initializer accepts an arbitrary enum value.

The following is an interface sketch. Method bodies are omitted, so it cannot be compiled directly as a complete Swift source file:

```swift
public struct NetworkAddress: Sendable, Hashable, Codable {
    internal enum Host: Sendable, Hashable {
        case ipv4([UInt8])
        case ipv6([UInt8])
        case domain(String)
    }

    internal let hostValue: Host
    public let port: UInt16

    public init(host: String, port: UInt16) throws {
        // Validate, normalize, and write immutable storage.
    }

    internal init(ipBytes: [UInt8], port: UInt16) throws {
        // Validate byte count, handle mapped IPv6, then write immutable storage.
    }

    public var host: String {
        // Generate deterministic host text from valid storage.
    }

    public init(from decoder: any Decoder) throws {
        // Call the same construction entry point after decoding fields.
    }

    public func encode(to encoder: any Encoder) throws {
        // Encode normalized host and port.
    }
}
```

Usage:

```swift
let server = try NetworkAddress(host: "API.Example.COM.", port: 443)
let local = try NetworkAddress(host: "127.0.0.1", port: 8080)
let ipv6 = try NetworkAddress(host: "2001:db8::1", port: 443)
```

Construction entry points must satisfy the following constraints:

1. Text construction accepts only a standalone host. Callers parse URLs, HTTP authority, brackets, and embedded ports first.
2. IP-byte construction accepts 4 or 16 bytes and applies the same IP normalization rules as the text entry point.
3. `Host` is only a package-internal representation; do not add an initializer that places an unvalidated `Host` directly in an address.
4. Every entry point, including decoding, must establish the same storage invariants.
5. Do not provide `unchecked` construction, writable properties, or test-only construction paths.
6. Do not add construction switches such as `allowZeroPort`, `forBinding`, `forRouting`, or `strict` that change the model's meaning.

### 3. Storage invariants

| Storage | Invariant |
|---|---|
| `ipv4` | Exactly 4 bytes, stored in network byte order |
| `ipv6` | Exactly 16 bytes, stored in network byte order; mapped IPv6 is not stored |
| `domain` | Satisfies the §5 ASCII hostname grammar, has been lowercased, and retains a valid explicit root dot |
| `port` | `UInt16`, in the range `0...65535` |

IP bytes use `[UInt8]` with zero-based array indexing. After extracting an address field from `Data` or `ByteBuffer`, a protocol parser should copy that field to a byte array. It cannot assume a `Data` slice has a zero `startIndex`.

`host` is a text view generated from valid storage:

- IPv4 emits ordinary decimal dotted-quad notation without leading zeroes.
- IPv6 emits canonical lowercase compressed text without brackets or a scope suffix.
- A domain emits its normalized name, retaining an explicit root dot.
- It does not emit a port or add HTTP syntax.
- It does not return an empty string or another error placeholder, and it does not trigger DNS.

IP equality and rule matching use bytes rather than display text. An implementation may use existing numeric-address parsing and formatting capabilities, but must guarantee no name-resolution side effect.

### 4. IP parsing and normalization

The text entry point first distinguishes strict IP literals from hostnames, then constructs final storage. It must not leave non-standard numeric addresses for a permissive system name resolver to interpret.

IPv4 text accepts only four decimal integer components, each `0...255`, without leading zeroes except for a single `0`.

IPv6 text accepts ordinary full and compressed representations and parses to 16 bytes. Only IPv4-mapped IPv6 whose first 80 bits are zero and whose following 16 bits are `0xffff` converts to equivalent IPv4; all other IPv6, including IPv4-compatible and NAT64-prefix addresses, remains IPv6.

Text and byte entry points must produce the same result:

| Input | Result |
|---|---|
| `192.0.2.1` | IPv4 `[192, 0, 2, 1]` |
| `::ffff:192.0.2.1` | The same IPv4 value |
| The corresponding 16 bytes of mapped IPv6 | The same IPv4 value |
| `2001:db8::1` | Native IPv6 |
| `::192.0.2.1` | Remains IPv6 |
| `64:ff9b::192.0.2.1` | Remains IPv6 |
| `127.1`, `2130706433` | Reject abbreviated components and integer form |
| `127.000.0.1`, `0177.0.0.1` | Reject leading-zero forms |
| `0x7f000001`, `0X7F.0.0.1` | Reject hexadecimal forms |
| `256.0.0.1`, `1.2.3.4.5`, `192..2.1` | Reject invalid numeric expressions |
| `192.0.2.1.` | Reject a pure numeric expression with a root dot; do not pass it to the resolver as a domain |
| `[::1]`, `fe80::1%en0` | Reject bracket and scope text extensions |

The numeric-ambiguity check is an explicit input policy of this model: text made only of digits and dots, and text whose components are each decimal digits or `0x`-style hexadecimal numbers, must pass strict IPv4 grammar to be accepted; empty components and an empty hexadecimal body are also rejected. They must not be accepted by trimming first, removing a root dot, or filling in missing components.

This check must not wrongly reject a domain containing an ordinary name label, such as `0xfeed.example`. Such names continue through hostname grammar validation.

### 5. Hostname contract

This model accepts ASCII hostnames and does not directly accept raw Unicode domains. Hostname rules are as follows:

| Item | Rule |
|---|---|
| Empty name | Reject |
| Character set | ASCII letters, digits, hyphens, and dots between labels |
| Case | Convert to ASCII lowercase during construction |
| Label length | `1...63` bytes per label |
| Total length | `1...253` bytes after removing one valid trailing root dot |
| Hyphen | Not allowed at the start or end of a label |
| Root dot | One trailing root dot is allowed and retained in storage and forwarding |
| Single label | Ordinary names satisfying the other rules are allowed, e.g. `localhost`; pure numeric ambiguity is still rejected as §4 requires |
| Whitespace, control characters, NUL | Reject; do not trim or truncate |
| Empty label, leading dot, consecutive dots, multiple root dots | Reject |
| `_`, `/`, `\`, `@`, `:`, `[`, `]`, `%` | Not allowed hostname characters |

A valid name with a root dot can be at most 254 bytes. A protocol parser and encoder must handle the length limits of their own address fields; the wire protocol's 255-byte upper limit cannot replace the hostname-length rules.

When UI and configuration-import layers need Unicode support, they should convert and validate with a versioned IDNA implementation that has test vectors, then call this model. The model cannot hand-write an incomplete Punycode algorithm.

This model promises only ASCII hostname grammar; it does not treat an `xn--` prefix and LDH-character checks as proof of complete A-label validity. If a protocol entry point promises complete IDNA validity, it must call the appropriate complete validation implementation; that additional contract must be accepted separately. The existing SOCKS5 SPEC's valid-A-label requirement cannot be marked complete merely because this model passes.

### 6. Ports and operation semantics

Ports use `UInt16` consistently. Conversion from configuration integers, strings, or serialized input must be exact; overflow, negative numbers, and non-integers must fail, with no truncation, wrapping, or replacement by a default.

The model permits `0`; the specific operation entry point decides whether it may be used:

| Use case | Responsibility |
|---|---|
| CONNECT destination, UDP data destination | The corresponding operation entry point rejects port `0` |
| Ephemeral socket binding | Binding policy may allow `0` to mean system assignment |
| SOCKS5 ASSOCIATE source hint, protocol response address | Handle according to the semantics of that field; CONNECT-destination rules cannot be applied |
| Route matching and Wire encoding | Consume the established model and operation contract without repeating the same port policy |

The model permitting port `0` does not automatically change Magent listener product policy. Whether the listener supports an ephemeral port needs to be explicit in the listening-configuration contract.

### 7. Equality and hashing

`Equatable` and `Hashable` use normalized address kind, stored contents, and port. Both must use the same identity semantics.

| Two values, with the same port unless stated otherwise | Equality |
|---|---|
| `API.Example.COM` and `api.example.com` | Equal |
| Different text forms of the same IP | Equal |
| IPv4 and its corresponding mapped IPv6 | Equal |
| The same IP constructed from text and from the byte entry point | Equal |
| Same host, different port | Not equal |
| `example.com` and `example.com.` | Not equal; the explicit root dot is information retained by the model |
| A domain and the IP it currently resolves to | Not equal; do not perform DNS for comparison |

Ports and root dots cannot be removed from address equality to reuse a route cache. `Hashable` does not promise a stable hash value across processes; `hashValue` must not be used as a persistent identifier.

### 8. Routing, caching, and forwarding

The data path for a destination address is:

```text
protocol message / application configuration / Codable input
                  ↓
       construct NetworkAddress
       validate and normalize to obtain an immutable value
                  ↓
       operation entry point checks command and port policy
                  ↓
       routing → DNS or dial → Wire
            consumes the same address value
```

Core must not normalize only a temporary copy for routing while callers use the original representation for dialing and the Wire handshake. HTTP CONNECT, HTTP forward, SOCKS4a, SOCKS5 CONNECT, and UDP destinations must follow the same construction contract.

`MagentCore` owns the route-matching view:

- Domain-rule matching may remove one root dot; for example, both addresses use `api.example.com` as their matching name.
- Current rules do not match ports, so a route-cache key may ignore the port; adding port rules must change the key at the same time.
- The key must distinguish domains, IPv4, and IPv6, using normalized names or IP bytes.
- The model received by Wire and parsers still retains the explicit root dot.
- A DNS cache and actual-endpoint cache design their keys for their own semantics and cannot directly reuse the route-cache key.

The model no longer provides `normalized()` or `hostForMatching`. Whether a root dot affects actual resolution or absolute-name resolution is used is explicitly defined by the layer owning the resolver, not decided implicitly by the route cache.

### 9. NetworkAddress and SocketAddress

| Type | Meaning |
|---|---|
| `NetworkAddress` | A logical address that may contain an unresolved domain; used for requests, routing, and protocol address fields |
| NIO `SocketAddress` | An actual socket endpoint; used for listening, connections, UDP send/receive, and preserving transport information |

In the target design, `MagentConfig.listener` uses `SocketAddress`, consistent with the existing representation of node and DNS addresses. If an application needs to configure listening with a hostname, it resolves it to an actual address first under application-configuration policy; this responsibility does not belong to this model.

Conversion of a numeric address to a socket must use validated IP bytes and port. Domain resolution is performed by Core's connection path or the owning connection's asynchronous resolver. This model must not call `makeAddressResolvingHost`, hide synchronous DNS, or create a Channel, thread, or Task.

The actual socket's address family, IPv6 scope, and reply path remain in `SocketAddress`. A normalized logical address must not be used as a lossless substitute for the original socket:

- Once mapped IPv6 converts to IPv4, the original transport address family is no longer retained.
- This model does not store scope; input conversion encountering nonzero scope must explicitly reject it and cannot silently discard it after copying only IP bytes.
- IPv6 bytes that do not depend on scope can be constructed; whether a business destination requires scope to be usable is decided by the operation entry point, which rejects an inexpressible destination.
- UDP replies continue to use the recorded original `SocketAddress`. Comparing normalized IP identity must not overwrite the original endpoint.
- If original ATYP matters for an ASSOCIATE source hint, protocol validation, or diagnostics, the protocol parser retains it; destination normalization does not preserve the original message.

### 10. Codable format

Use an explicit host/port format rather than the internally enumerated type's automatically synthesized encoding layout:

```json
{
  "host": "api.example.com.",
  "port": 443
}
```

Encoding emits normalized host text and numeric port. IP is not encoded as a raw byte array or as an authority with a port.

Decoding must first read `String` and `UInt16`, then construct through `init(host:port:)`. Missing fields, incorrect field types, out-of-range ports, and invalid hosts must fail, with no default host or default port substituted.

The following must hold:

```text
decode(encode(address)) == address
```

The round trip retains address identity, port, and root dot; it need not retain original case or original IP text spelling. The former enum's Codable layout is not a compatibility format; migration of real persistent data belongs to the application's storage migration, without adding a model decoding branch that bypasses validation.

### 11. Errors and allocation of responsibility

When address contents do not satisfy this model's contract, a construction entry point throws `MagentError.invalidAddress`. It does not use an empty string, port `0`, or an unspecified address as a failure fallback.

The decoder's own missing-field and type errors propagate as the original Codable errors; after fields are read, address-construction failure propagates as the original construction error. Helpers do not catch an error to wrap or rename it.

The highest owning boundary selects HTTP status, SOCKS reply code, UDP packet-drop, or close behavior uniformly; these do not enter the address model.

| Layer | Checks that must remain | Duplicate work that may be removed |
|---|---|---|
| Protocol parser | Message boundaries, field length, ATYP, UTF-8 decoding, commands, and forms allowed by the field | Its own general hostname sanitization and numeric normalization |
| NetworkAddress | IP structure, ASCII hostname grammar, normalization, port type, and decoding contract | Remedial validation at the use stage |
| Operation entry point | Port `0`, supported address families, scope requirements, and specific access policy | Checking nonempty host and IP-byte count again |
| Core | Routing, caching, resolution, and connection policy | Normalizing the address again or normalizing only a local copy |
| Wire | Its supported address kinds and encoding-length constraints | Checking again byte counts and port ranges the model already guarantees |

For example, the SOCKS5 parser decides whether its Domain field permits IPv6 text. Generic text construction supporting IPv6 does not mean every protocol's Domain field permits that representation.

### 12. Implementation boundary

This design permits directly changing the public API. Implement it in the following order:

1. Implement controlled construction, storage, equality, and explicit Codable in the existing `Sources/Model/NetworkAddress.swift`.
2. Connect all protocol-destination parsing to the text or byte construction entry point so routing and Wire consume the same result.
3. Keep handling of matching names and route-cache keys in `MagentCore`.
4. Adjust listener configuration and socket-conversion callers, making the preservation path for scope and original address family explicit.
5. Remove legacy public enum construction, `normalized()`, `hostForMatching`, and model-conversion methods that include DNS.
6. Remove redundant validation covered by the new construction contract while retaining the protocol's and operation's own checks.
7. Update package and application callers, examples, and the persistent-data migrations actually involved.

Do not add a Validator, Normalizer, Factory, forwarding wrapper layer, or test-only initializer. Internal support types may remain in the same file.

Model-independent `Data` / `UInt16` helpers, such as SOCKS port encoding and decoding, should be handled in their respective protocol code; a read failure cannot masquerade as valid port `0`.

### 13. Acceptance criteria

The following are acceptance items pending implementation. They cannot be marked complete merely because this SPEC exists or legacy tests pass.

| ID | Scenario | Result that must be verified |
|---|---|---|
| NA-01 | Valid construction of the three address kinds | Explicit storage kind, host text, and port |
| NA-02 | IP byte lengths 0, 3, 4, 5, 15, 16, 17 | Only 4 and 16 are accepted; errors propagate consistently |
| NA-03 | Convert a `Data` slice with nonzero start index to a byte array | Address bytes are accurate and reading host stays in bounds |
| NA-04 | Text, raw bytes, and mapped IPv6 represent the same IPv4 | `==` holds and Set retains only one identity |
| NA-05 | Native, compatible, and NAT64 IPv6 | Remain IPv6 and do not collapse incorrectly |
| NA-06 | Non-standard numeric expressions and `0xfeed.example` | §4 rejection vectors fail; ordinary names are not falsely rejected |
| NA-07 | Case, one root dot, and multiple root dots | Lowercase, retain one root dot, reject multiple root dots |
| NA-08 | Labels of 63/64 bytes; names of 253/254 bytes | Precise length boundaries; 254 bytes can only be a valid name with a root dot |
| NA-09 | Empty string, NUL, whitespace, Unicode, empty label, separator | Reject; do not trim or truncate |
| NA-10 | Ports 0, 1, 65535; decode -1, 65536, incorrect type | Model accepts valid range, out-of-range decoding fails, operation entry point separately rejects disallowed 0 |
| NA-11 | Different ports, case, explicit root dot | Equality strictly follows §7 |
| NA-12 | Codable round trip and invalid input | Identity is retained and construction validation cannot be bypassed |
| NA-13 | Equivalent destinations in HTTP, SOCKS4a, SOCKS5 TCP/UDP | Route decision, numeric dial, and Wire address encoding stay consistent |
| NA-14 | Matching and forwarding a domain with a root dot | Matching key removes the root dot; Wire retains it |
| NA-15 | Construct, compare, hash, encode, and read host only | Do not query DNS or create network resources |
| NA-16 | Actual endpoint for scoped socket and mapped IPv6 | Do not lose scope or overwrite original reply endpoint with logical address |
| NA-17 | IPv6 text in a protocol Domain field and ASSOCIATE hint | Handle by protocol-field rules without unintentionally relaxing them through generic construction capability |

Tests use fixed inputs and literal expected values. Identity tests use equality and collection behavior, not the cross-run-unstable numeric value of `hashValue`.

A model implementation should run targeted tests; when migration touches connection, buffering, concurrency, or cleanup code, run at least:

```bash
swift build
swift build -Xswiftc -strict-concurrency=complete
swift test --filter NetworkAddressTests
swift test --filter ConnectionTests
swift test
git diff --check
```

Run the project's required strict lint on Swift files actually modified. Application-caller compilation, persistent-data migration, and real network behavior are verified separately and cannot be inferred from package-test success. A documentation-only change performs only structure, link, and diff checks.

### 14. Related files and specification boundary

- [Current NetworkAddress implementation](../Sources/Model/NetworkAddress.swift)
- [Current model tests](../Tests/Model/NetworkAddressTests.swift)
- [Current architecture](ARCHITECTURE.md)
- [SOCKS4 / SOCKS4a SPEC](SOCKS4_PROXY_SPEC.md)
- [SOCKS5 SPEC](SOCKS5_PROXY_SPEC.md)
- [HTTP SPEC](HTTP_PROXY_SPEC.md)

This document is the design target for the new model; descriptions in other documents of the current enum, listener type, normalization entry point, and serialization format must be updated after actual migration. It does not claim that all capabilities of existing protocol SPECs are already implemented or remove stricter field or IDNA contracts at protocol entry points.

## HttpProtocol

### 1. Purpose and design goals

`HttpProtocol` represents **the proxy-request semantics expressed by one HTTP request head whose validation is complete**. Constructed from NIO's `HTTPRequestHead`, it determines the business destination, the CONNECT or ordinary-forwarding branch, and the outbound head and body-framing method for ordinary forwarding.

Successful construction means the head semantics satisfy this chapter's contract and the corresponding connection flow may continue; it does not mean the request body is complete, an upstream connection succeeded, or a response was sent.

Responsibilities are divided among three layers:

| Layer | Responsibility |
|---|---|
| NIOHTTP1 decoder / encoder | HTTP message grammar, incremental decoding, and message encoding |
| `HttpProtocol` | Request-head semantics, destination extraction, Host and framing-field validation, outbound-head reconstruction |
| HTTP Connection | Request-body receipt, runtime limits, authentication, routing and dialing, response selection, backpressure, and lifecycle |

`HttpProtocol` holds no original receive buffer, request body, Channel, Wire, Core, Future, or Task; it neither parses responses nor performs DNS. It does not continue to mix `checkConnect()`, mutable request fields, and static HTTP response bytes in the same object.

### 2. Initial scope and relationship to other HTTP specifications

This chapter first establishes an explicit, shared model contract for the two existing HTTP connections. The initial version chooses a limited HTTP/1 request-processing scope; these are product constraints of this model, not limits every HTTP implementation must adopt.

| Item | Initial design in this chapter |
|---|---|
| Version | HTTP/1.0 and HTTP/1.1; retain typed versions |
| CONNECT | authority-form, explicit nonzero port, no request body |
| Ordinary forwarding | `http` absolute-form and origin-form whose destination is determined by Host |
| Request body | No body, or a fixed length specified by one Content-Length |
| Transfer-Encoding / request trailers | Reject initially; do not pretend to support them by deleting fields |
| Expect / Upgrade | Reject initially; do not trigger 100-continue or protocol-upgrade flow |
| OPTIONS | Support ordinary OPTIONS to a specific destination; inbound `OPTIONS *` and OPTIONS with Max-Forwards are not initially supported |
| TRACE | Initially reject as an unsupported method |
| Other methods | Retain valid case-sensitive method tokens; do not make a model allowlist of only common methods |
| Connection reuse | Initial Connection retains a single-request flow and ordinary outbound requests use `Connection: close` |

[HTTP_PROXY_SPEC.md](HTTP_PROXY_SPEC.md) describes a broader target scope, including HTTP/1.1 only, rejecting inbound origin-form, chunked transfer, complete OPTIONS/Max-Forwards, Expect, Upgrade, and connection reuse. This chapter is not a statement that the complete proxy specification is implemented.

Where the two documents explicitly differ, implementation of this model's initial version follows this chapter's scope; implementing the complete HTTP-proxy target must upgrade the model and Connection contract and acceptance together, rather than reserving an enum branch with no execution path. The original HTTP SPEC remains a design reference for later complete capability.

### 3. Type shape and sole entry point

Keep the name `HttpProtocol` as an immutable package-internal `struct`. Use associated-value enums to represent the two request kinds, avoiding arbitrary combinations of `isConnect`, optional target, optional outbound head, and optional body fields.

The following is an interface sketch. Construction implementation is omitted, so it is not a complete source file that can compile directly:

```swift
import NIOHTTP1

internal struct HttpProtocol: Sendable {
    internal enum BodyFraming: Sendable, Equatable {
        case none
        case fixedLength(UInt64)
    }

    internal enum Request: Sendable {
        case connect(
            target: NetworkAddress,
            version: HTTPVersion
        )
        case forward(
            target: NetworkAddress,
            head: HTTPRequestHead,
            body: BodyFraming
        )
    }

    internal enum Failure: Error {
        case invalidRequest(String)
        case unsupportedVersion
        case unsupportedFeature(String)
        case unsupportedExpectation
    }

    internal let request: Request

    internal init(head: HTTPRequestHead) throws {
        // Validate input, extract the destination, and produce final request semantics.
    }
}
```

These types are chosen because:

- `HTTPRequestHead`, `HTTPVersion`, `HTTPMethod`, and `HTTPHeaders` directly reuse NIO types. Versions no longer round-trip through an `"HTTP/1.1"` string, and headers no longer convert to an ordinary dictionary or another field model.
- `.connect` retains only the destination and inbound version; it has no CONNECT HTTP request head sent to the origin server and no HTTP request-body state.
- `.forward` retains the normalized destination, an outbound `HTTPRequestHead` ready for the encoder, and explicit request-body framing.
- `BodyFraming.none` and `.fixedLength(0)` distinguish no declared request body from an explicitly declared zero length; neither has body bytes, but their outbound fields differ.
- `Failure` distinguishes only semantic errors produced by the model itself, so Connection selects a response by enum rather than branching on error-description text.

Do not provide direct construction accepting `Request` or expose writable storage. Package code can read and destructure `request`; changing an extracted `HTTPRequestHead` copy cannot change the model itself.

This model does not act as a cache key or persistence record; the initial version adds no `Hashable`, `Codable`, or logging interface that retains complete requests. Acceptance directly checks the branch, address, NIO fields, and framing result.

### 4. Construction phases and validation ownership

Construction must validate inbound meaning before deleting or rebuilding fields:

```text
HTTPRequestHead
    ↓
version, method, basic field validity, and duplicate critical fields
    ↓
read raw CL / TE and determine or reject inbound framing
    ↓
request-target, authority, Host → NetworkAddress
    ↓
check Connection tokens and unsupported features
    ↓
CONNECT semantics / ordinary-forwarding outbound head
```

Construction depends only on the passed head and accesses no configuration singleton, network, system-proxy state, or clock. The same input must produce the same result or error category.

The NIO decoder is responsible for the raw request line, CRLF, field grammar, and incremental-message boundaries. The model does not reparse the raw message, but must check value constraints that a directly constructed NIO head may lack: method and field names are nonempty HTTP tokens, and field values contain no CR, LF, NUL, DEL, or control character other than HTAB. `HTTPRequestHead(...)` itself cannot be assumed to mean all grammar validation is complete.

Header-name comparison uses ASCII case-insensitive semantics. Field values remove SP / HTAB only where HTTP field grammar permits; do not apply general Unicode trimming to request-target or host. Preserve duplicate fields; do not lose information through a dictionary, automatic merging, or overwriting before validation.

If the underlying decoder rejects input before producing `.head`, the error goes directly to Connection; if the decoder collapses information required for a decision, solve it at the NIO decoding integration point rather than making the model guess missing raw fields. Network-message tests and directly constructed head tests must both cover these boundaries.

### 5. Request types and the sole source of destination

| Method / request-target | Branch and business destination |
|---|---|
| Exact `CONNECT host:port` | `.connect`; destination comes from authority |
| Non-CONNECT `http://host[:port]/path?query` | `.forward`; destination comes from URI authority |
| Non-CONNECT `/path?query` | `.forward`; destination comes from the sole valid Host |
| CONNECT with absolute-form, origin-form, or `*` | Invalid request |
| Non-CONNECT with bare `host:port` | Invalid request |
| `OPTIONS *` | Initial capability is insufficient; reject and do not fabricate a business destination |
| Other methods with `*` | Invalid request |
| Schemes such as `https://`, `ws://`, `wss://`, `ftp://` | Unsupported initially; do not silently use plaintext TCP instead |

Method names are case-sensitive; `connect` cannot become `CONNECT`. Ordinary methods do not infer a request body's presence from GET/POST; framing is determined independently by fields.

Schemes are recognized ASCII-case-insensitively; request-target uses ASCII URI text, so a raw Unicode path must first be validly percent-encoded by the client. A valid origin-form path beginning with `//` remains a path and cannot be reinterpreted as another authority.

Proxy-node addresses are only for Core to select transport endpoints. The model's `target` is always the business destination, and the outbound Host must not be replaced with a proxy node or numeric IP returned by DNS.

For the basic distinction between authority-form and absolute-form and the basis for rebuilding Host from URI authority in absolute-form, see [RFC 9112 §3.2](https://www.rfc-editor.org/rfc/rfc9112.html#section-3.2). This chapter separately defines the product policy for origin-form admission and CONNECT Host consistency.

### 6. Combining Authority and NetworkAddress

The HTTP layer only separates host, port, and IPv6 brackets, then calls the controlled [NetworkAddress](#networkaddress) construction entry point. It must not write another set of ASCII-hostname rules, numeric-address ambiguity rules, or mapped-IPv6 normalization.

| Scenario | Port rule |
|---|---|
| CONNECT request-target | Must explicitly provide `1...65535` |
| Ordinary absolute-form authority | Defaults to 80 when omitted; explicit port must be nonzero |
| Ordinary-forwarding Host | Defaults to 80 when omitted; explicit port must be nonzero |
| CONNECT Host | When omitted, used only for consistency comparison with the port already confirmed by request-target; it must not therefore be inferred as 443 |

An explicit port accepts only nonempty decimal digits and checks overflow. Leading zeroes are accepted as port input and output in ordinary decimal; signs, internal whitespace, empty ports, and truncating conversion are not accepted.

IPv6 in HTTP authority must have complete brackets, with only an allowed port suffix outside them. Reject userinfo, percent-encoded hosts, scope, IPvFuture, path, query, and fragment mixed into authority.

It must first validate that the bracket contents are a valid IPv6 literal, then pass them to `NetworkAddress`. It cannot require the normalized result to remain `.ipv6`, or `[::ffff:192.0.2.1]:443` would be wrongly rejected after its valid conversion to IPv4. `[example.com]:443` and `[192.0.2.1]:443` must be rejected.

Authority lexical splitting may share one private method within the existing `HttpProtocol.swift`, returning host, optional explicit port, and representation information. Whether CONNECT must have a port is decided by the call site; do not use a chain of Boolean switches such as `isConnect` and `allowMissingPort`. Reuse the splitting rule, not by flattening semantic differences among fields.

### 7. Host-field contract

| Scenario | Host requirement |
|---|---|
| HTTP/1.1 | Exactly one valid, nonempty Host |
| HTTP/1.0 CONNECT / absolute-form | May be absent; if present, exactly one and valid |
| HTTP/1.0 origin-form | Exactly one valid, nonempty Host; otherwise the destination cannot be determined |
| Duplicate Host in every version | Reject, including duplicates with the same value or different case in field names |

The initial version handles the three target forms as follows:

- absolute-form: URI authority determines the business destination. A valid but inconsistent Host does not change routing, and outbound Host is rebuilt from URI authority.
- origin-form: Host is the sole destination source; no other URI authority exists as a fallback.
- CONNECT: when Host is present, use §6 port rules to construct a comparison value and compare it with request-target's `NetworkAddress`; reject inconsistency.

CONNECT consistency comparison uses address-value identity: domain case is unified, mapped IPv6 equals IPv4, and explicit-root-dot differences are retained. It cannot use a route matching key after root-dot removal to prove Host consistency, nor perform DNS to compare whether two domains point to the same server.

Strict CONNECT consistency checking is a product decision of this chapter; [HTTP_PROXY_SPEC.md](HTTP_PROXY_SPEC.md) uses a more permissive destination-first rule for CONNECT Host, and implementation of the initial version must not mix the two branches. Accepting a valid conflicting Host in absolute-form also does not mean accepting absent, duplicate, or grammatically invalid HTTP/1.1 Host; field-count and grammar validation still occur first.

### 8. Path, query, and outbound authority

Ordinary absolute-form extracts only structural boundaries and does not decode then reencode path/query. It must not rely on URL handling that automatically repairs invalid input or changes escaped text; if URL-parsing capability is reused, its preservation behavior must be verified with the following literal vectors.

| Input URI | Outbound request-target |
|---|---|
| `http://example.com` | `/` |
| `http://example.com?` | `/?` |
| `http://example.com?x=1` | `/?x=1` |
| `http://example.com/a%2Fb?q=%0D%0A` | `/a%2Fb?q=%0D%0A` |
| `http://example.com/a/../b//c` | `/a/../b//c` |
| Valid origin-form `/a%2Fb?x=` | Retain exactly |

Raw whitespace, control characters, backslashes, fragments, and incomplete `%HH` escapes must be rejected. Valid escapes cannot be decoded into delimiters or control characters. Repeated slashes, dot path segments, and query-parameter order remain unchanged.

`OPTIONS http://example.com` is a special but explicit forwarding request: as the last HTTP proxy before the origin server, its outbound target is `*` when path is empty and no query exists; `OPTIONS http://example.com?` emits `/?`. This is OPTIONS forwarded to a determined origin server, distinct from an inbound `OPTIONS *` local-capability request. See [RFC 9112 §3.2.4](https://www.rfc-editor.org/rfc/rfc9112.html#section-3.2.4) for this distinction.

出站 Host 从最终 `NetworkAddress` 的规范化 host 与 HTTP authority 中的端口存在性生成：

| 入站目标 | 出站 Host |
|---|---|
| `http://API.Example.COM./x` | `api.example.com.` |
| `http://example.com/x` | `example.com` |
| `http://example.com:80/x` | `example.com:80` |
| `http://[2001:db8::1]:8080/x` | `[2001:db8::1]:8080` |
| `http://[::ffff:192.0.2.1]:80/x` | `192.0.2.1:80` |

显式默认端口是 HTTP 表示信息，不属于 `NetworkAddress` 的身份；构造 HttpProtocol 时用局部解析结果保留并生成出站头，不为此扩展通用地址模型。普通 IPv6 根据规范化后的实际类型补方括号，域名根点保留。

### 9. 请求体定界

模型保存的是 body 的定界规则，不保存 body 字节，也不维护已经收到多少字节的计数器。

| 入站字段 | 首版结果 |
|---|---|
| 普通请求无 CL / TE | `.none`，请求没有 body，不能等待 EOF 定界 |
| 普通请求单个合法 CL | `.fixedLength(n)`，包含 `n == 0` |
| 重复 CL，含相同重复值 | 非法请求 |
| 单字段 `Content-Length: 4, 4` | 非法请求，不采用容错合并 |
| CL 非数字、带符号、内部空白或 UInt64 溢出 | 非法请求 |
| 同时有 CL 和 TE | 非法请求，在任何出站之前拒绝 |
| 普通请求任何 TE | 首版不接受；decoder 已判定语法或定界非法时按原始错误处理 |
| CONNECT 无 CL / TE | 无请求体 |
| CONNECT 单个 CL=0 | 允许，但不作为隧道长度、不向目标转发 |
| CONNECT 非零 CL 或任何 TE | 非法请求 |
| 请求声明 Trailer | 首版不接受 |

CL 允许字段外侧合法 OWS 和十进制前导零；检查后以一个十进制整数重建出站 CL。不得先删除 TE、合并 CL 或移除 Connection 指名字段，再推断请求长度。相关消息定界原则见 [RFC 9112 §6.3](https://www.rfc-editor.org/rfc/rfc9112.html#section-6.3)，重复 CL 全部拒绝属于本章的严格输入策略。

`UInt64` 只用于安全表达声明长度，不是允许分配同等内存的承诺。Connection 在分配、接收或拨号之前按实际资源限额拒绝过大请求；转换为 `Int` 或累计长度时必须检查溢出。不得在模型内固定一个测试方便的最大 body 大小。

连接层负责校验 `.body` / `.end` 的时序、累计长度、提前 EOF 和实际 trailers。模型构造只看 head，因此不能声称构造成功已经验证了后续 body。

### 10. 出站头重建

使用 `HTTPHeaders` 保留允许转发的字段及重复项，不改变任意业务字段的值。重建顺序如下：

1. 在原始字段上完成 Host、CL/TE 和不支持特性的检查。
2. 按 HTTP 列表语法读取所有 Connection 字段；非空项必须为合法 token，以 ASCII 小写比较，空列表项不作为字段名。
3. Connection 指名 `Host`、`Content-Length`、`Transfer-Encoding`、`Trailer`、`Authorization`、`Proxy-Authorization` 或 `Expect` 等关键字段时拒绝，防止删除操作改变认证、目标或分帧含义。这里的 `Transfer-Encoding` 与独立的 `TE` 字段必须区分。
4. 移除 Connection 指名的普通逐跳字段，以及旧的 Connection、Keep-Alive、Proxy-Connection、TE、Trailer、Transfer-Encoding、Upgrade、Proxy-Authenticate 和 Proxy-Authorization。
5. 根据唯一业务目标重建一个 Host，根据 `BodyFraming` 重建零个或一个 Content-Length；输出中不得出现 Transfer-Encoding。
6. 保留端到端字段的值和重复顺序，例如 Authorization、Cookie、自定义字段；不把 Proxy-Authorization 当作源站 Authorization。
7. 写入首版的 `Connection: close`，使用原方法和支持的入站 HTTP 版本生成新的 `HTTPRequestHead`。

原始 Host 和 CL 由重建值替代，不能一边保留旧字段一边追加新字段。Connection tokens 的检查发生在过滤之前，包括大小写变体。

Expect、Upgrade 字段或 Connection 的 `upgrade` token、请求 Trailer 按首版能力拒绝，不能仅删除头字段后继续当普通请求处理。Expect 产生 `Failure.unsupportedExpectation`，不支持的升级和 Trailer 产生 `Failure.unsupportedFeature`；已发现的非法分帧仍先按非法请求拒绝。对带 Max-Forwards 的 OPTIONS，首版返回能力不足，不能忽略该字段继续转发；完整本地 OPTIONS 分支和递减规则留待独立扩展。

运行时需要添加 Via 或执行认证时，由 Connection 使用明确的运行配置完成。认证读取过滤前的原始 head，不能从已经删除代理凭据的出站头推断身份。Via 的配置和回环策略不进入无上下文模型；添加运行时转发字段不得修改已经确定的 method、target、Host 或 body 定界。

### 11. Connection 消费契约

Connection 收到 `.head` 时构造模型并保存结果；不能在 `.end` 时再次从原始字符串重新计算业务目标。不同事件的职责如下：

| 事件 / 阶段 | Connection 的责任 |
|---|---|
| `.head` | 只构造一次，检查运行时限额、认证与能力，保存不可变请求语义 |
| `.body` | 按模型给出的定界规则接收，进行计数、限额和背压处理 |
| `.end` | 确认消息完整、长度一致、无不支持的 trailers |
| CONNECT 建连 | 使用模型中的 target 完成路由和 Wire 握手 |
| 普通转发 | 使用同一个 target 路由；把模型里的 head 和完整 body 交给编码器 |
| 成功或失败响应 | 由连接状态和错误类别决定，写入完成后再推进状态 |

首版继续采用当前连接的完整请求后发起业务转发、单请求、不接受 pipelining 的流程。缓冲上限由 Connection 执行，模型不拥有完整 body；未来流式转发时修改 Connection 的发送时机和背压，不把 Channel 或计数器塞回模型。

CONNECT 必须等到请求结束、decoder 余量检查完成、业务连接及 Wire startup 就绪、本地 2xx 写入成功后才能进入 tunnel。拒绝提前数据、移除 decoder 的顺序、EOF 和 half-close 都是 Connection 状态机职责。

普通请求通过 NIO 编码能力得到请求字节，再进入直连 channel 或相同 Wire 的隧道载荷路径。不得继续由模型或 `buildPayload` 拼接一份完整 `Data` 请求；具体 encoder 与 Wire 的 pipeline 接法须在连接迁移中验证，不能因改用类型化 head 丢掉已有手动读取、写入完成和关闭顺序约束。

### 12. 本地响应与错误路径

`HttpProtocol` 不再定义 `established`、`badRequest`、`badGateway`、`gatewayTimeout` 等静态 `Data`。HTTP Connection 使用 `HTTPResponseHead` / encoder 生成本地响应，并持有“一次响应”的状态约束。

最高拥有边界按以下类别选择响应；模型 helper 不捕获下层错误再包装、改名或输出响应：

| 错误来源 | Connection 的首版响应策略 |
|---|---|
| `Failure.invalidRequest`、地址构造错误、NIO 请求解码错误 | 400 |
| `Failure.unsupportedVersion` | 505 |
| `Failure.unsupportedFeature` | 501 |
| `Failure.unsupportedExpectation` | 417 |
| 下游连接失败 | 502 |
| 下游连接超时 | 504 |

`unsupportedFeature` 的关联文本只用于诊断，不能据此再拆分状态码。资源限额、鉴权和其他运行错误由对应 Connection 策略处理，不能一概变成 400。成功响应已经开始或进入 tunnel 后，不得再追加 HTTP 错误响应。

CONNECT 成功响应不含 Content-Length、Transfer-Encoding 或 HTTP body，头部结束后进入隧道。普通本地错误可以发送明确的 `Content-Length: 0` 和 `Connection: close`。CONNECT 成功响应的限制见 [RFC 9110 §9.3.6](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.6)。

两个 Connection 需要共用响应编码时，先在现有 HTTP 连接 owner 中评估共享方法；不把重复字节常量移成另一个没有独立职责的文件，也不放回请求语义模型。

### 13. 具体输入与输出

以下示例描述构造的语义结果，不代表已运行新实现。

CONNECT：

```http
CONNECT API.Example.COM.:443 HTTP/1.1
Host: api.example.com.
Content-Length: 0

```

结果为 `.connect`，目标是 `NetworkAddress(host: "api.example.com.", port: 443)`，版本为 `.http1_1`。Host 未显式提供端口，按请求目标端口比较；CL=0 不进入 Wire 握手或 tunnel payload。

普通转发：

```http
POST http://API.Example.COM.:80/a%2Fb?x= HTTP/1.1
Host: ignored.example
Connection: keep-alive, X-Remove
X-Remove: local-only
Proxy-Authorization: example-placeholder
Content-Length: 0004

data
```

结果为 `.forward`，target 为 `api.example.com.:80`，body 为 `.fixedLength(4)`。关键出站字段为：

```http
POST /a%2Fb?x= HTTP/1.1
Host: api.example.com.:80
Content-Length: 4
Connection: close

```

四个 body 字节 `data` 由 Connection 单独保管和发送，不存入模型。代理认证如果启用，在 Connection 中使用原始代理凭据；示例不是认证成功的声明。运行时的 Via 等字段由 Connection 按配置追加。

### 14. 迁移范围

1. 在现有 `Sources/Model/HttpProtocol.swift` 实现唯一的 NIO head 构造入口、关联值请求枚举和必要的私有解析方法。
2. `HttpConnectConnection` 移除版本字符串转换、手工 tuple headers、`checkConnect()` 和独立的 authority 校验链。
3. `HttpForwardConnection` 的目标提取、Host/CL 校验和请求头改写合并到本模型；body 缓冲与状态机留在连接中。
4. 去掉整包 `buildRequest(head:body:)` / `buildPayload` 式模型入口，改为消费类型化 head 和独立 body。
5. 响应常量迁出模型，按 Connection 状态使用编码器发送本地响应。
6. 核对 `ProxyProbe` 与模型范围一致；探测只选择协议，不能替代模型对方法和目标形式的完整检查。
7. 更新原有模型断言与连接回归；CONNECT CL=0、Host 省略端口、错误状态码和 OPTIONS 限制等行为变化必须写成明确用例。

`HttpProtocol` 继续为 internal API，不因重构而公开给应用。嵌套类型及小型私有方法留在原文件，不引入 Context actor、Router、泛型请求框架或测试专用 parser。

### 15. 验收标准

模型纯逻辑验收和真实连接流程验收分开记录。以下均为新设计的待实现项：

| 编号 | 场景 | 必须验证的结果 |
|---|---|---|
| HP-01 | 合法 CONNECT / 普通转发 | 分别得到唯一有效分支，不依赖第二次 check |
| HP-02 | HTTP/1.0、1.1、其他版本；方法大小写和合法未知方法 | 版本策略和区分大小写语义明确，不自动改写方法 |
| HP-03 | HTTP/1.1 缺失、重复、大小写不同的重复 Host | 全部拒绝；HTTP/1.0 按目标形式处理缺失 Host |
| HP-04 | absolute-form 与合法冲突 Host | 目标和新 Host 都来自 URI，原 Host 不影响路由 |
| HP-05 | CONNECT Host 省略端口、大小写、mapped IPv6、不同端口或根点 | 相等情况通过；端口和根点身份不一致拒绝 |
| HP-06 | 方括号 IPv6、mapped IPv6、括号内域名/IPv4、scope | IPv6 字面量先验证，mapped 转为 IPv4 后仍接受，其余非法向量拒绝 |
| HP-07 | CONNECT 缺端口、空端口、0、65536、符号；普通 URI 默认/显式 80 | 端口语义精确，显式默认端口在出站 Host 保留 |
| HP-08 | 空 path、空 query、转义大小写、重复斜线、点路径 | 第 8 节所有字面期望保持；不解码重编码 |
| HP-09 | URI fragment、反斜线、空白、非法转义、userinfo | 拒绝；合法 `%0D%0A` 仍是原字面转义 |
| HP-10 | 无 CL、CL=0、CL=0004 | 分别为 none、fixedLength(0)、fixedLength(4)，出站长度规范化 |
| HP-11 | 重复 CL、逗号 CL、CL 溢出、TE+CL | 在出站前失败，网络报文与直接 head 入口均覆盖 |
| HP-12 | CONNECT CL=0、非零 CL、TE；forward TE/Trailer/Expect/Upgrade | 按首版能力准确允许或拒绝，不通过删头放行 |
| HP-13 | Connection 指名普通字段和 Host/CL/认证字段 | 普通字段移除，关键字段拒绝，比较大小写不敏感 |
| HP-14 | 重复业务字段、Authorization、Proxy-Authorization | 保留允许的字段及顺序，代理凭据不泄漏给源站 |
| HP-15 | 直接构造含非法 token、CR/LF/NUL 的 NIO head | 模型拒绝，不把 NIO 值类型误当成已验证输入 |
| HP-16 | HTTP 与 SOCKS 的等价数字目标 | 使用同一 NetworkAddress 规范化结果路由与编码 |
| HP-17 | body 未收齐、超长、提前 EOF、trailers、重复 head/end | Connection 拒绝或关闭，不把头部模型通过当成完整请求通过 |
| HP-18 | CONNECT 每个拆分点、同包余量、提前 tunnel payload | 严格成功回复顺序，decoder 移除不丢余量或提前放行 |
| HP-19 | 请求头/body 编码与 Wire startup | 先完成正确 startup，再发送 HTTP 字节，body 不重复、不丢失 |
| HP-20 | 本地错误和 CONNECT 成功 | 状态码按类别映射，至多一次响应；成功 CONNECT 无 CL/TE/body |
| HP-21 | 单请求、pipelining、后续 keep-alive 请求 | 首版 Connection 边界保持，不因改模型扩大支持声明 |
| HP-22 | OPTIONS 空 path 无 query、空 query、入站 *、Max-Forwards、TRACE | 明确区分源站 * 转发与未支持的本地能力请求，不猜测目标 |
| HP-23 | 仅构造模型及读取结果 | 无 DNS、无 Channel、无请求体缓存、无日志或认证副作用 |
| HP-24 | 取出 head 后修改副本 | 原模型的目标、头部及分帧规则不改变 |

测试断言必须包括具体 `NetworkAddress` 值、HTTP method/version、精确 target 字符串、字段数量和值、BodyFraming 和失败类别。输出字段大小写或无关字段顺序不作为协议等价性判断，但应验证重复字段的语义和顺序没有被错误合并。

字节级解析和防注入向量必须经过真实 NIO decoder，不能只使用手工构造的 head 代替。模型用例也要覆盖手工 head，证明构造入口自身的契约。Connection 测试继续覆盖背压、half-close、超时、清理和真实编码顺序。

实现后至少执行项目规定的 build、strict-concurrency build、ConnectionTests、全包测试、修改文件的 strict lint 和 `git diff --check`；增加对应的模型定向测试。文档单独变更只做结构、链接与不变量检查，不宣称上述实现验收已经完成。

### 16. 相关文件与证据

- [当前 HttpProtocol 实现](../Sources/Model/HttpProtocol.swift)
- [当前 HTTP CONNECT 连接](../Sources/Connection/HttpConnectConnection.swift)
- [当前 HTTP forward 连接](../Sources/Connection/HttpForwardConnection.swift)
- [当前 CONNECT 测试](../Tests/Connection/HttpConnectConnectionTests.swift)
- [当前 forward 测试](../Tests/Connection/HttpForwardConnectionTests.swift)
- [HTTP 完整代理目标 SPEC](HTTP_PROXY_SPEC.md)

当前源码和测试是迁移调用链的依据，不能证明新模型已经实现。构造、头部字段、分帧和语义分支应按本章重新验收；完整 HTTP 产品能力仍需逐项对照原 HTTP SPEC。

## ProxyNode

### 1. 定位与职责

`ProxyNode` 是一个不可变的、已经通过本地配置校验的出站代理节点值。它描述如何连接代理服务器及采用哪个节点协议，不表示业务目标，也不保存已经建立的连接。

模型负责节点标识、实际服务器端点、协议、密码和连接超时的配置契约。Core 负责节点集合、UUID 查找和 Wire 选择；Wire 负责密码派生、salt、nonce、帧状态及加解密；应用负责节点名称、订阅、启用状态、持久化和节点域名解析。

构造成功表示配置在本地可执行，不保证服务器可达、密码正确或远端实现支持选定算法。构造不访问 DNS，不建立 Channel，不生成连接 salt，也不预先创建 Wire。

本章的关联枚举为 `ProxyNodeType` 和 `ProxyCipher`，均在本章节内定义契约。文档归属不要求把现有枚举源码文件自动合并，也不因重设计而增加新的配置包装文件。

### 2. 类型与构造入口

首版继续表达当前有实际 Wire 支持的 Shadowsocks 节点。字段全部只读，初始化改为抛错，超时改为具有明确单位的整数毫秒。

以下是接口草图，方法实现省略：

```swift
public struct ProxyNode: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let type: ProxyNodeType
    public let address: SocketAddress
    public let cipher: ProxyCipher
    public let password: String
    public let timeoutMilliseconds: Int64

    public init(
        id: UUID = UUID(),
        type: ProxyNodeType = .shadowsocks,
        address: SocketAddress,
        cipher: ProxyCipher,
        password: String,
        timeoutMilliseconds: Int64 = 30_000
    ) throws {
        // 在保存字段之前校验端点、密码和超时。
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // 按第 6 节比较全部配置；密码采用 UTF-8 字节语义。
    }

    public func hash(into hasher: inout Hasher) {
        // 使用与相等性完全相同的字段和字节语义。
    }
}
```

`id` 默认值只用于真正的新建节点；从存储读取、导入更新或替换配置时，应用必须传入已有 UUID，不能通过重新生成 ID 修补丢失的规则引用。

首版只有一种节点协议，`cipher`、`password` 都是该协议的必需字段，不引入可空字段。以后增加不使用这些字段的协议时，应设计带关联配置的协议枚举，再一起迁移构造入口；不能先添加协议名、再依靠大量默认值凑出不完整节点。

### 3. ProxyNodeType

`ProxyNodeType` 是节点协议标识，不是 Wire 实例、网络能力探测结果或默认路由决策。

```swift
public enum ProxyNodeType: String, Codable, Sendable, Hashable, CaseIterable {
    case shadowsocks = "shadowsocks"
}
```

只列出当前具有真实 TCP/UDP 实现和验收路径的协议。暂不增加 SOCKS5、HTTP 上游、DIRECT、REJECT 或未知占位 case；DIRECT 是 [ProxyRule](#proxyrule) 章节中 `Decision` 的动作，不是代理节点。

raw value 是明确的导入标识，大小写和拼写精确匹配。未知协议必须报错，不能自动替换为 Shadowsocks。`allCases` 不构成当前网络环境一定能够使用这些协议的证明。

### 4. ProxyCipher

`ProxyCipher` 标识 Shadowsocks Wire 支持的加密算法及其固定参数；密码不是 master key，`keySize` 也不是密码字符数或 UTF-8 字节数限制。

```swift
public enum ProxyCipher: String, Codable, Sendable, Hashable, CaseIterable {
    case aes128Gcm = "aes-128-gcm"
    case aes256Gcm = "aes-256-gcm"
    case chacha20IetfPoly1305 = "chacha20-ietf-poly1305"
    case xchacha20IetfPoly1305 = "xchacha20-ietf-poly1305"
}
```

以下参数以当前包内 `ProxyCipher`、`AeadCipher` 及对应测试为基线，单位均为字节：

| case | keySize | saltSize | nonceSize | tagSize |
|---|---:|---:|---:|---:|
| `aes128Gcm` | 16 | 16 | 12 | 16 |
| `aes256Gcm` | 32 | 32 | 12 | 16 |
| `chacha20IetfPoly1305` | 32 | 32 | 12 | 16 |
| `xchacha20IetfPoly1305` | 32 | 32 | 24 | 16 |

这些只读参数继续由枚举提供，不能再作为用户可覆盖的节点字段存储。未知算法或未知 raw value 必须失败；不得静默降级、忽略算法或选择默认算法。该列表只描述本包能力，不代表任意 Shadowsocks 服务端都支持全部四种算法。

枚举不执行密码派生、不生成随机数、不维护 nonce。实际密钥长度、nonce 长度和加密帧检查仍属于 crypto / Wire 边界，不能因节点构造成功而删除。

### 5. 端点、密码和超时不变量

| 字段 | 构造成功后的契约 |
|---|---|
| `address` | IPv4 或 IPv6 的实际 `SocketAddress`，端口为 `1...65535`；拒绝 Unix socket 和端口 0 |
| `type` | 存在本包实现的明确协议 case |
| `cipher` | 存在本包实现的明确算法 case |
| `password` | UTF-8 表示非空，内容原样保存 |
| `timeoutMilliseconds` | `1...9_223_372_036_854`，可精确转换为正的 Int64 纳秒 |

节点地址必须继续保存实际地址族和 IPv6 scope。不得为了复用业务地址规范化而转成 `NetworkAddress` 后覆盖真实节点端点，也不能去掉 scope。IP 是否可达、是否自回环及是否被运行时访问策略允许，由应用和 Core 的对应策略判断，不通过一次模型构造来宣称已经验证。

密码不 trim、不做 Unicode 规范化、不按 cipher 的 keySize 截断或补齐；仅包含空格的非空密码也按原字节处理。空密码在本章作为配置错误拒绝，这是本产品的输入策略。错误消息和模型描述不包含密码或派生密钥；真实配置不写入文档或测试。

超时上限来自 `Int64.max / 1_000_000`。当前 NIO `TimeAmount.milliseconds` 对超范围转换采用饱和值，本模型选择提前拒绝，避免保存的超时与实际传入的时长不一致。TCP / UDP Wire 直接消费已验证的毫秒值，不再分别执行浮点秒乘 1000、取整和范围判断。

该超时表示连接节点时使用的期限参数，不是 DNS 超时、HTTP 请求总期限、隧道空闲超时或 UDP 响应期限的统称。UDP Wire 暴露同一配置值，也不代表无连接 UDP 具备与 TCP 相同的握手计时行为。

### 6. 标识、相等性与集合约束

`Identifiable.id` 表示节点身份；整个 `ProxyNode` 的 `==` 表示配置是否完全相同。两个值使用同一个 UUID 但地址、算法、密码或超时不同，应当不相等。

`Hashable` 与相等性共同覆盖 UUID、协议、NIO SocketAddress 的端点语义、算法、密码 UTF-8 字节和超时。密码必须按字节比较和哈希，不能直接依赖 Swift String 的规范等价比较：`"\u{00E9}"` 与 `"e\u{0301}"` 的 String 可以相等，但密码派生所用 UTF-8 字节不同。

不使用 `hashValue` 作为持久化节点 ID、秘密的摘要或稳定配置指纹。

节点集合约束仍由 Core 管理，不能放进不持有全表的单个节点构造器：

- 相同 UUID 按输入顺序使用最后一个成功装载的配置。
- 不同 UUID 使用相同实际 SocketAddress 时，按现有集合契约拒绝。
- 同 UUID 改变地址后，Core 更新旧地址到节点的反向映射和对应 Wire。
- 比较实际节点端点沿用 SocketAddress 身份，不用业务请求的 mapped IPv6 归一结果作为原始 socket 的替代物。
- 批量加载按顺序处理，不因模型重构而宣称增加事务回滚、端点互换重排或公共热更新能力。

### 7. 生命周期、引用与持久化

`ProxyNode` 不持有 TCP 加密流状态。每条代理 TCP 连接由 Core 创建独立 Wire，salt / nonce / 启动状态不能因节点 UUID 相同而复用；UDP 仍遵循 Wire 自己的独立数据报加密规则。

默认 `.proxy(UUID)` 在完整节点表装载之后校验；缺失则 Core 初始化失败。规则中的节点引用继续在实际选中该规则时检查，缺失抛出原始 `proxyNodeNotFound`，不回退 DIRECT。这些是配置集合和路由边界的契约，不是节点模型自身的存在性校验。

`restart` 为下一运行周期创建新的 Core；本章不引入跨运行周期共享 Wire、节点单例或额外配置 snapshot。

首版不为整个 `ProxyNode` 增加自动 Codable。协议/算法的 raw value 可以独立编码；应用存储负责 UUID、原始节点主机名、端口、凭据及超时字段，并在构造运行配置前解析出 `SocketAddress`。不能把含 scope 的实际端点仅序列化为普通 IP 字节而丢失作用域。

### 8. 错误与迁移

本地节点配置违反上述不变量时，构造入口抛出 `MagentError.invalidPolicy`。错误说明可以标明字段或原因，不能包含密码。DNS、密码派生和 crypto / Wire 的原始错误分别在其实际执行边界传播，不在节点 helper 内包装成另一种错误。

本次设计相对于当前实现的变化是：

1. `ProxyNode.init` 改为 throws，提前验证端点、非空密码和超时。
2. `timeout: TimeInterval` 改为 `timeoutMilliseconds: Int64`，默认值从 30 秒明确为 30_000 毫秒。
3. TCP / UDP Wire 删除重复的秒到毫秒转换，继续保留真正的加密初始化和运行错误处理。
4. 对包含密码的配置相等性和哈希实施字节语义。

历史秒值转换由应用迁移负责：拒绝非有限数及非正数；乘以 1000 后向上取整，再检查第 5 节上限并精确转为 Int64。这样延续当前 Wire 的毫秒取整规则，不能把原来的 `30` 直接解释为 30 毫秒。应用中的节点导入和存储转换必须显式处理构造失败，不能继续以 `compactMap` 静默丢掉坏配置后宣称完整加载成功。

### 9. 验收标准

| 编号 | 场景 | 必须验证的结果 |
|---|---|---|
| PN-01 | 合法 IPv4 / IPv6 节点 | 保留 UUID、实际地址、协议、算法、密码字节和超时 |
| PN-02 | Unix socket、端口 0 | 构造失败，不能延迟到业务拨号 |
| PN-03 | IPv6 scope、mapped IPv6 实际端点 | 保留真实端点信息，不用逻辑地址替换 |
| PN-04 | 超时 0、负数、1、30_000、上限及上限加 1 | 边界精确，无饱和或截断 |
| PN-05 | 旧配置 30 秒、正的小数秒、NaN、infinity | 正常转换与向上取整明确，非有限或溢出值拒绝 |
| PN-06 | 空密码、空格密码、Unicode 密码 | 空密码拒绝；其余原 UTF-8 字节不变 |
| PN-07 | 同 UUID 不同字段、规范等价但字节不同的密码 | 配置不相等；Set 不错误合并 |
| PN-08 | 四个 ProxyCipher | 每个尺寸均断言第 4 节的字面量，raw value 精确往返 |
| PN-09 | 未知协议和算法 raw value | 导入失败，无默认回退 |
| PN-10 | 重复 UUID、不同 UUID 重复端点、同 UUID 换端点 | Core 集合行为和反向映射正确 |
| PN-11 | 默认节点缺失与规则节点缺失 | 前者在全表装载后失败，后者在命中时失败；均不降级 DIRECT |
| PN-12 | 两条 TCP 连接及多个 UDP packet | Wire 状态按真实生命周期隔离 |
| PN-13 | 仅构造或比较节点 | 不执行 DNS、密码派生、加密初始化或网络 I/O |
| PN-14 | 非法配置错误及诊断 | 包含可定位字段，绝不包含密码或派生密钥 |

这些为待实现验收项。现有 `ProxyNodeTests` 主要证明 cipher 参数，不代表新增的节点构造和集合契约已经全部验收。

### 10. 相关文件

- [当前 ProxyNode / ProxyNodeType](../Sources/Model/ProxyNode.swift)
- [当前 ProxyCipher](../Sources/Model/ProxyCipher.swift)
- [当前节点及 cipher 测试](../Tests/Model/ProxyNodeTests.swift)
- [当前 Core 与节点集合](../Sources/Core/MagentCore.swift)
- [当前 Core 测试](../Tests/Core/MagentCoreTests.swift)
- [当前 TCP Wire](../Sources/Wire/Shadowsocks/ShadowsocksTCPWire.swift)
- [当前 UDP Wire](../Sources/Wire/Shadowsocks/ShadowsocksUDPWire.swift)

## ProxyRule

### 1. 定位与职责

`ProxyRule` 是一个不可变的、已经校验并规范化的单条路由规则，表达 **匹配条件、命中动作和显式优先级**。它不持有节点表，不执行路由遍历，不创建 Wire，也不解析 DNS。

模型负责把输入文本转换成可直接使用的匹配值，尤其是已经清零主机位的 CIDR 字节和前缀。Core 负责规则集合的去重、索引、优先级比较、默认决策和节点查找。

本章的关联枚举为 `MatchType`、`Decision`，以及模型内部保存有效结果的 `ProxyRule.Match`。它们放在本模型描述内，不作为独立模型章节。

### 2. 类型与构造入口

保留方便配置导入的 `matchType` / `matchValue` 构造参数；内部只保存一个经过校验的关联值枚举。公开的类型和文本视图由这个存储计算，不同时维护可以不一致的两份数据。

以下是接口草图，方法实现省略：

```swift
public struct ProxyRule: Sendable, Hashable {
    internal enum Match: Sendable, Hashable {
        case exactDomain(String)
        case domainSuffix(String)
        case domainKeyword(String)
        case ipCIDR(network: [UInt8], prefixLength: UInt8)
    }

    internal let match: Match
    public let decision: Decision
    public let order: Int

    public var matchType: MatchType {
        // 从 match 的分支计算。
    }

    public var matchValue: String {
        // 从规范化存储生成确定的配置文本。
    }

    public init(
        matchType: MatchType,
        matchValue: String,
        decision: Decision,
        order: Int
    ) throws {
        // 验证并保存一个有效的 Match，不查询节点表。
    }
}
```

`Match` 的 CIDR 网络字节数只能为 4 或 16，前缀范围由实际字节数确定。构造前先检查整数前缀，再转换为 UInt8；不能通过窄整数转换截断越界输入。

不提供接受任意 `Match` 的直接构造入口。Core 消费已经解析的匹配值，不再把 `matchValue` 重新解析成另一份 NetworkCIDR。

### 3. MatchType

`MatchType` 表示配置中的匹配类别。新设计只暴露当前地址路由实际支持的四种类别：

```swift
public enum MatchType: String, Codable, Sendable, Hashable, CaseIterable {
    case exactDomain = "EXACT-DOMAIN"
    case domainSuffix = "DOMAIN-SUFFIX"
    case domainKeyword = "DOMAIN-KEYWORD"
    case ipCIDR = "IP-CIDR"
}
```

raw value 按上述拼写精确导入。未知值必须失败，不当作普通域名或忽略。

移除当前 `urlRegex = "URL-REGEX"` 的“模型接受、Core 拒绝”状态。当前路由匹配入口收到的是 `NetworkAddress`，没有完整 URL，无法正确执行 URL 正则匹配；首版不暴露该 case。历史 URL 规则在应用迁移时明确报为不支持，不能静默跳过或改成域名关键字。

以后若支持 URL、端口或来源匹配，必须先明确输入和协议可见性，再扩展规则与缓存 key。不能仅添加枚举名称就宣称路由已支持。

### 4. Decision

`Decision` 是路由结果值，既用于 `ProxyRule.decision`，也用于 `MagentConfig.defaultDecision`。因此仍为包的顶层公共枚举；写在本模型章节不意味着改成只能通过 ProxyRule 引用的嵌套类型。

```swift
public enum Decision: Sendable, Hashable {
    case direct
    case proxy(UUID)
}
```

`.direct` 表示直连业务目标，`.proxy(UUID)` 表示按稳定 UUID 选择节点。不使用可空 UUID、特殊零 UUID、假节点或节点地址字符串表达 DIRECT。

规则构造时不能判断 UUID 是否存在。Core 在完整节点装载后检查默认代理引用，在规则实际命中时检查该规则的引用；缺失节点抛出原始错误，不把 PROXY 变为 DIRECT。无规则命中才使用 defaultDecision；某规则命中后执行失败不是“未命中”。

首版不添加没有执行路径的 REJECT、自动选择、回退链或代理分组 case。节点不可用、没有规则和明确直连是不同状态，不能用同一个空值合并。

`Hashable` 使用 case 和 UUID，不能把节点当前配置或 Wire 实例放入决策值。首版不为关联值枚举增加自动 Codable；应用持久化若使用 `direct` / `proxy` 文本和节点关联，必须显式组合并校验，不能依赖 Swift 自动合成的序列化布局。

### 5. 域名精确规则与后缀规则

这两种规则使用与 NetworkAddress 相同的 ASCII 标签结构约束：小写、每标签 `1...63` 字节、非空标签、总长上限 253 字节，允许输入单个末尾根点，保存时去掉该根点。

规则文本不 trim 首尾空白，不删除前导点，不折叠多个根点，不接受 `*`、URL 或带端口的 authority。`.example.com` 不是隐式后缀语法；应显式选择 `.domainSuffix` 并传入 `example.com`。

共用的是纯主机名标签校验，不是通过构造一个端口为 0 的假目标来校验规则。可以在现有地址/规则 owner 中共享被多个生产路径使用的纯语法方法；不要新增 Validator 包装文件。

两种规则的语义分别为：

| 规则 | 匹配 | 不匹配 |
|---|---|---|
| exactDomain `example.com` | 域名目标 `example.com`、`EXAMPLE.COM.` | `api.example.com`、数值 IP 目标 |
| domainSuffix `example.com` | `example.com`、`api.example.com`、更深子域名 | `notexample.com`、`example.com.evil`、数值 IP 目标 |

后缀比较必须以 DNS 标签为边界，不能使用没有边界检查的普通字符串 endsWith。

exactDomain 若是 NetworkAddress 会识别为 IP 或拒绝的纯数值歧义表达，应在规则构造时拒绝，并提示使用 IP-CIDR；不能产生一条永远不参与 IP 匹配的伪域名 IP 规则。domainSuffix 表达的是标签后缀，可以包含数字标签，例如 `0.1` 可以匹配域名 `a.0.1`；它始终只作用于域名目标，不把某个 IPv4 地址按点拆成域名匹配。

目标域名的匹配视图由 Core 去掉一个根点，目标自身仍保留根点供解析和 Wire 转发；规则构造不能修改目标对象。

### 6. 域名关键字规则

`domainKeyword` 是对规范化域名匹配名称的 ASCII 字面子串匹配，不是完整主机名、glob 或正则表达式。

- 输入长度为 `1...253` 字节，转为 ASCII 小写。
- 允许字母、数字、点和连字符；这些字符可以位于关键字边缘，因为关键字可能是名称片段。
- 拒绝空值、空白、控制字符、Unicode、URL 分隔符及正则/通配符符号；不 trim 输入。
- 不要求关键字自身满足完整主机名标签结构，不能直接复用 exactDomain 的全部验证。
- 只作用于域名目标，不执行 PTR、DNS 或从某个 IP 猜测域名。

例如关键字 `api` 可以匹配 `api.example.com` 和 `myapiv2.example.com`；关键字 `api.` 可以匹配前者而不匹配后者。此匹配不具有 domainSuffix 的标签边界保证，应用需要标签边界时应选择后缀规则。

### 7. CIDR 规则

CIDR 构造仅接受严格数值 IP 和可选的一个 `/prefix`，不访问 DNS。省略前缀时 IPv4 使用 `/32`，IPv6 使用 `/128`；显式前缀只接受非空十进制数字，禁止符号、内部空白、额外斜线和越界值。前缀的十进制前导零可接受，输出时去掉。

普通 IP 解析、歧义数字拒绝和 scope 文本拒绝与 NetworkAddress 的数值语法一致，但 CIDR 解析必须保留原始 IPv6 位宽，先处理前缀与 mapped IPv6 的关系，再生成规范化网络，不能先丢掉 96 位再解释原前缀。

| 输入 | 规范化匹配值 |
|---|---|
| `192.0.2.129/24` | `192.0.2.0/24` |
| `192.0.2.129` | `192.0.2.129/32` |
| `192.0.2.129/0` | `0.0.0.0/0` |
| `2001:db8::1234/64` | `2001:db8::/64` |
| `2001:db8::1` | `2001:db8::1/128` |
| `::ffff:192.0.2.129/120` | `192.0.2.0/24` |
| `::ffff:192.0.2.129/96` | `0.0.0.0/0` |
| `::ffff:192.0.2.129` | `192.0.2.129/32` |

原地址是 mapped IPv6 时，仅接受 `/96.../128`，转换为 IPv4 后将前缀减 96。对 mapped 字面量指定小于 96 的前缀会跨出映射区间，本章明确拒绝，不能简单减法、截断或悄悄把整个范围当作 IPv4。

原生 IPv6 范围保留 IPv6。规则匹配按规范化后的地址族区分：IPv4 目标只匹配 IPv4 CIDR，原生 IPv6 目标只匹配 IPv6 CIDR；`::/0` 不因为包含某些映射字节表示就匹配已经归为 IPv4 的目标。

网络存储在构造时清零所有主机位，保存 `[UInt8]` 与前缀。Core 做集合索引和包含判断时直接读取这些值，不重复解析文本、重复清零主机位或建立另一份等价的 NetworkCIDR 包装。

### 8. order、匹配身份与相等性

`order` 是显式优先级，数值越小越优先。允许完整 Int 范围，包括负数；比较时使用关系运算，不以相减方式判断先后，避免 Int.min / Int.max 溢出。

规则值相等性与集合覆盖身份必须分开：

- `ProxyRule ==` / Hashable 比较规范化 `Match`、`Decision` 和 `order`。不同动作或优先级是不同配置值。
- Core 的覆盖 key 只使用规范化 `Match`，不包含 decision / order；等价 CIDR 和域名大小写/根点变体得到相同 key。
- 同一覆盖 key 的最后一条配置生效，同时使用最后一条在输入数组中的位置参加后续比较。
- 规则不增加运行时随机 UUID，不能用 Hashable 的 hashValue 作为持久化规则 ID。

应用自己的数据库主键、策略关联和 UI 行标识继续由应用管理，不进入包内路由规则。

### 9. Core 的选择顺序

Core 对所有实际命中的候选规则按同一顺序选择：

1. `order` 较小。
2. 同 order 下更具体。
3. 仍相同则采用去重后保留下来的较早输入位置。

具体性使用明确比较项，不依赖魔法分数或字典遍历顺序：

| 同 order 的候选 | 更具体的规则 |
|---|---|
| 域名精确、域名后缀、域名关键字 | 精确优先于后缀，后缀优先于关键字 |
| 两个域名后缀 | 标签数更多者 |
| 两个域名关键字 | 规范化 UTF-8 字节数更多者 |
| 两个同族 CIDR | 前缀更长者 |

同一目标不会同时进入域名与 IP 匹配分支，因此无需为 CIDR 与域名规则设置跨类别的分数高低。精确规则的同值重复已经在去重阶段处理。

一个更小 order 的后缀或关键字必须胜过更大 order 的精确域名；命中 exact 索引后不能立即返回。规则为空或全部未命中时才应用 defaultDecision。

规则不读取端口，因此首版路由缓存 key 可以忽略端口。未来增加端口或其他匹配维度时，必须同步升级 key，不能只修改规则枚举。缓存保存 Decision，不保存某条 TCP Wire 的加密状态。

### 10. 错误、导入和迁移

规则结构或匹配文本不符合本章时，由规则构造入口抛出 `MagentError.invalidPolicy`。不要先捕获地址 helper 的错误再重命名；共享纯语法检查应提供合适的内部解析结果，由实际拥有规则输入的边界产生自己的错误。

构造时不检查节点存在性，不执行 DNS，不创建正则对象或 Wire。关联的 ProxyNode、实际目标、运行时路由错误在对应 owner 原样传播。

首版不为整个 ProxyRule 增加自动 Codable。应用导入显式解析 MatchType、Decision、order 和匹配文本，再调用唯一构造入口；无效 raw value、PROXY 动作缺少必填 UUID 和不支持的 URL-REGEX 必须报告，不能静默忽略。合法 UUID 对应的节点是否存在，仍按第 4 节在 Core 的对应边界检查。若将来需要模型 Codable，解码必须回到同一验证入口，不依赖自动合成内部 Match 的格式。

相对于当前实现，迁移包括：

1. 将字符串匹配字段改为规范化 Match 存储，保留只读的 matchType / matchValue 视图。
2. 将 CIDR 的解析、主机位清零和规范化身份收归规则模型；Core 保留匹配和索引。
3. 移除 MatchType.urlRegex 及 Core 对该“已构造但不可执行规则”的延迟拒绝路径。
4. 统一域名规则的严格输入策略，不再用 trim / 去任意首尾点修复非法值。
5. Core 用明确的具体性比较代替跨类别魔法分数，并保留既定的 order、覆盖和稳定决胜顺序。
6. 更新应用导入、持久化转换和测试；旧规则的失效不能通过少装几条规则掩盖。

先前的 NetworkAddress / HttpProtocol 章节继续适用。本章不要求把关联枚举改成嵌套公共 API，也不默认合并其现有文件。

### 11. 验收标准

| 编号 | 场景 | 必须验证的结果 |
|---|---|---|
| PR-01 | 四个 MatchType 与 raw value | 精确导入和往返，未知类型及 URL-REGEX 明确失败 |
| PR-02 | 域名大小写、单根点、空白、前导点和多根点 | 大小写/单根点规范化；非法修复式输入拒绝 |
| PR-03 | exact 与 suffix 的边界 | 第 5 节匹配/不匹配向量精确成立 |
| PR-04 | exact 数值文本、suffix 数字标签、数值目标 | exact 伪 IP 规则拒绝，合法标签后缀可用，IP 不走域名分支 |
| PR-05 | 关键字 api、api.、空值、非法字符及 253/254 长度 | 子串语义明确，不套用完整域名标签检查 |
| PR-06 | IPv4 / IPv6 /0、主机前缀和缺省前缀 | 精确清零主机位，格式和存储一致 |
| PR-07 | prefix 越界、负号、正号、空前缀、多个斜线、scope、域名 | 在构造时失败，不等待 Core 再解析 |
| PR-08 | mapped IPv6 /96、/120、/128、缺省和 /95 | 合法范围对应 IPv4 前缀，小于 96 明确拒绝 |
| PR-09 | 等价 CIDR、域名变体、不同 Decision / order | 覆盖 key 与完整规则相等性各自正确 |
| PR-10 | 重复规则的最后配置与输入位置 | 使用最后值及其位置，不能保留第一次的决胜位置 |
| PR-11 | 不同 order 的 exact、suffix、keyword | order 优先，不能按索引命中顺序提前返回 |
| PR-12 | 同 order 的类型、后缀深度、关键字长度、CIDR 长度 | 精确执行第 9 节比较，不依赖字典顺序 |
| PR-13 | Int.min / Int.max 以及同优先级同具体性 | 无比较溢出，稳定采用较早保留位置 |
| PR-14 | 无规则、无匹配、命中缺失节点 | 前两者使用默认决策；后者失败，不回退直连 |
| PR-15 | 相同 host 不同端口、域名根点、mapped 数值目标 | 与 NetworkAddress 及路由缓存语义一致 |
| PR-16 | direct / proxy(UUID) | 动作与 UUID 身份明确，没有假节点和特殊零值 |
| PR-17 | Core 消费规则 | 直接使用解析结果，不再次解析 CIDR 或丢弃模型验证结果 |
| PR-18 | 单纯规则构造、导入和比较 | 无 DNS、节点查找、网络 I/O、Wire 创建或正则编译 |

单个模型验收使用字面量期望的字符串、网络字节、前缀、动作和优先级；集合用例必须通过 Core 的真实选择路径验证。手工检查排序不变量不能代替未来的 Core 回归测试。

### 12. 相关文件与验证边界

- [当前 ProxyRule](../Sources/Model/ProxyRule.swift)
- [当前 MatchType](../Sources/Model/MatchType.swift)
- [当前 Decision](../Sources/Model/Decision.swift)
- [当前 Core 与 Router](../Sources/Core/MagentCore.swift)
- [当前 Core 测试](../Tests/Core/MagentCoreTests.swift)

本章定义模型的目标功能与约束；源码是否满足这些要求，需要按本章验收场景独立验证。

实现两个模型后，应完成节点/cipher、规则/Core 的定向验收，并按项目规定执行 build、strict-concurrency build、ConnectionTests、全包测试、实际修改 Swift 文件的 strict lint 和 `git diff --check`。应用节点导入、秒到毫秒迁移和规则持久化转换需要独立验证；文档阶段只检查结构、链接、示例不变量和修改范围。
