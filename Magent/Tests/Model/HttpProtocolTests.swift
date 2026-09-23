import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest

@testable import Magent

// 对照 docs/MODELS_SPEC.md 的 HttpProtocol 首版契约。
// HP-01～15、22～24 在此直接调用唯一模型入口；HP-16 在此验证共享地址身份和 Wire 编码。
// HP-17～21 在同一测试类中验证真实接收、时序、背压和关闭。
// 测试以新契约为目标；缺失 API 是迁移阻塞，不使用兼容适配器、跳过或 expected failure 隐藏。
final class HttpProtocolTests: XCTestCase {
  // MARK: - 请求分支、版本和 Host

  func testHP01ConstructsTheOnlyValidBranchFromACompleteHead() throws {
    try assertConnect(
      head(.CONNECT, "api.example.com:443", [("Host", "api.example.com:443")]),
      host: "api.example.com", port: 443
    )
    try assertForward(
      head(.GET, "http://example.com/resource", [("Host", "example.com")]),
      host: "example.com", port: 80, uri: "/resource", hostField: "example.com"
    )
    try assertForward(
      head(.POST, "/resource", [("Host", "example.com:8080")]),
      host: "example.com", port: 8080, uri: "/resource", hostField: "example.com:8080"
    )
  }

  func testHP02PreservesSupportedVersionsAndRejectsOtherVersions() throws {
    for version in [HTTPVersion.http1_0, .http1_1] {
      try assertConnect(
        head(.CONNECT, "example.com:443", [("Host", "example.com:443")], version: version),
        host: "example.com", port: 443
      )
      try assertForward(
        head(.GET, "/", [("Host", "example.com")], version: version),
        host: "example.com", port: 80, uri: "/", hostField: "example.com"
      )
    }
    for version in [HTTPVersion.http0_9, HTTPVersion(major: 1, minor: 2), .http2] {
      for (method, uri) in [(HTTPMethod.CONNECT, "example.com:443"), (.GET, "/")] {
        assertFailure(
          head(method, uri, [("Host", "example.com:443")], version: version),
          .unsupportedVersion
        )
      }
    }
  }

  func testHP02PreservesCaseSensitiveAndUnknownMethodTokens() throws {
    for method in ["GET", "get", "connect", "trace", "PROPFIND", "X-Custom", "!#$%&'*+-.^_`|~09Az"]
    {
      try assertForward(
        head(HTTPMethod(rawValue: method), "/", [("Host", "example.com")]),
        host: "example.com", port: 80, uri: "/", hostField: "example.com"
      )
    }
    assertFailure(
      head(HTTPMethod(rawValue: "connect"), "example.com:443", [("Host", "example.com:443")]),
      .invalidRequest
    )
    for uri in ["http://example.com/", "/", "*"] {
      assertInvalidTarget(head(.CONNECT, uri, [("Host", "example.com:443")]))
    }
    assertFailure(head(.GET, "example.com:80", [("Host", "example.com")]), .invalidRequest)
  }

  func testHP02ProbeRecognizesLegalExtensionMethodsWithoutChangingCase() {
    for method in ["connect", "X-Custom", String(repeating: "X", count: 64)] {
      XCTAssertEqual(ProxyProbe.detect(Data("\(method) /resource HTTP/1.1\r\n".utf8)), .httpForward)
    }
    XCTAssertEqual(
      ProxyProbe.detect(Data("CONNECT example.com:443 HTTP/1.1\r\n".utf8)), .httpConnect)
  }

  func testHP03AppliesHostCardinalityToEveryVersionAndTargetForm() throws {
    for version in [HTTPVersion.http1_0, .http1_1] {
      for (method, uri) in [
        (HTTPMethod.CONNECT, "example.com:443"), (.GET, "http://example.com/"), (.GET, "/"),
      ] {
        for fields in [
          [("Host", "example.com"), ("Host", "example.com")],
          [("Host", "example.com"), ("hOsT", "other.example")],
        ] {
          assertFailure(head(method, uri, fields, version: version), .invalidRequest)
        }
        if version == .http1_1 || uri == "/" {
          assertFailure(head(method, uri, [], version: version), .invalidRequest)
        }
      }
    }
    try assertConnect(
      head(.CONNECT, "example.com:443", [], version: .http1_0), host: "example.com", port: 443
    )
    try assertForward(
      head(.GET, "http://example.com/", [], version: .http1_0),
      host: "example.com", port: 80, uri: "/", hostField: "example.com"
    )
  }

  func testHP03RejectsEmptyOrInvalidHostEvenWhenAbsoluteURIProvidesTheTarget() {
    for version in [HTTPVersion.http1_0, .http1_1] {
      for host in [
        "", " \t", "user@example.com", "example.com:", "example.com:0", "exa%mple.com",
        "[127.0.0.1]",
      ] {
        assertInvalidTarget(head(.GET, "http://example.com/", [("Host", host)], version: version))
      }
    }
  }

  func testHP04UsesOnlyTheAbsoluteURITargetToRebuildHost() throws {
    let output = try assertForward(
      head(.GET, "http://API.Example.COM.:8080/x", [("Host", "other.example:9000")]),
      host: "api.example.com.", port: 8080, uri: "/x", hostField: "api.example.com.:8080"
    )
    XCTAssertEqual(output.headers.count, 2)
    try assertForward(
      head(.GET, "http://example.com/", [("Host", "\tignored.example:90 \t")]),
      host: "example.com", port: 80, uri: "/", hostField: "example.com"
    )
  }

  func testHP05ConnectHostUsesAddressIdentityAndBorrowsOnlyTheTargetPort() throws {
    let cases: [(String, String, String, UInt16)] = [
      ("API.Example.COM.:443", "api.example.com.", "api.example.com.", 443),
      ("example.com:8443", "EXAMPLE.COM", "example.com", 8443),
      ("example.com:443", "\tEXAMPLE.COM:00443 \t", "example.com", 443),
      ("[2001:0DB8:0:0:0:0:0:1]:443", "[2001:db8::1]", "2001:db8::1", 443),
      ("[::ffff:192.0.2.1]:443", "192.0.2.1:443", "192.0.2.1", 443),
      ("192.0.2.1:443", "[::ffff:c000:201]", "192.0.2.1", 443),
    ]
    for (uri, hostField, host, port) in cases {
      try assertConnect(head(.CONNECT, uri, [("Host", hostField)]), host: host, port: port)
    }
    for (uri, hostField) in [
      ("example.com:443", "example.com:80"), ("example.com:443", "other.example:443"),
      ("example.com.:443", "example.com:443"), ("example.com:443", "example.com.:443"),
      ("192.0.2.1:443", "[::192.0.2.1]:443"),
    ] {
      assertFailure(head(.CONNECT, uri, [("Host", hostField)]), .invalidRequest)
    }
  }

  // MARK: - HTTP authority、URI 字面量和规范化

  func testHP06PreservesIPv6AndAcceptsMappedIPv6BeforeNormalization() throws {
    let cases: [(String, String, String)] = [
      ("[2001:0DB8:0:0:0:0:0:1]", "2001:db8::1", "[2001:db8::1]:8080"),
      ("[::ffff:192.0.2.1]", "192.0.2.1", "192.0.2.1:8080"),
      ("[::ffff:c000:201]", "192.0.2.1", "192.0.2.1:8080"),
      ("192.0.2.1", "192.0.2.1", "192.0.2.1:8080"),
    ]
    for (authority, host, hostField) in cases {
      try assertConnect(
        head(.CONNECT, "\(authority):8080", [("Host", "\(authority):8080")]), host: host, port: 8080
      )
      try assertForward(
        head(.GET, "http://\(authority):8080/", [("Host", "ignored.example")]),
        host: host, port: 8080, uri: "/", hostField: hostField
      )
      try assertForward(
        head(.GET, "/", [("Host", "\(authority):8080")]),
        host: host, port: 8080, uri: "/", hostField: hostField
      )
    }
    try assertForward(
      head(.GET, "http://[2001:db8::1]/", [("Host", "ignored.example")]),
      host: "2001:db8::1", port: 80, uri: "/", hostField: "[2001:db8::1]"
    )
  }

  func testHP06RejectsMalformedAuthoritiesWithoutDomainFallback() {
    let authorities = [
      "[example.com]:443", "[192.0.2.1]:443", "[::1:443", "[::1]443", "[::1]:443:80",
      "[::1]extra:443", "[v1.fe]:443", "[fe80::1%en0]:443", "[fe80::1%25en0]:443",
      "2001:db8::1:443", "user@example.com:443", "%65xample.com:443", "example..com:443",
      "-example.com:443", "example_.com:443", "例子.example:443", "127.1:443", "0127.0.0.1:443",
      "0x7f000001:443", "256.0.0.1:443", "[::ffff:192.000.2.1]:443",
      "example.com :443", "example.com:443/path",
      "example.com:443?query", "example.com:443#fragment", "example.com:443\\path",
    ]
    for authority in authorities {
      assertInvalidTarget(head(.CONNECT, authority, [("Host", "example.com:443")]))
      assertInvalidTarget(head(.GET, "/", [("Host", authority)]))
    }
  }

  func testHP07ChecksPortBoundariesAndPreservesExplicitDefaultPort() throws {
    for (text, port) in [("1", UInt16(1)), ("65535", UInt16(65535)), ("00080", UInt16(80))] {
      try assertConnect(
        head(.CONNECT, "example.com:\(text)", [("Host", "example.com")]), host: "example.com",
        port: port
      )
    }
    for (uri, hostField) in [
      ("http://example.com/x", "example.com"),
      ("http://example.com:80/x", "example.com:80"),
      ("http://example.com:00080/x", "example.com:80"),
    ] {
      try assertForward(
        head(.GET, uri, [("Host", "ignored.example")]),
        host: "example.com", port: 80, uri: "/x", hostField: hostField
      )
    }
    for (inputHost, outputHost) in [
      ("example.com", "example.com"), ("example.com:00080", "example.com:80"),
    ] {
      try assertForward(
        head(.GET, "/", [("Host", inputHost)]),
        host: "example.com", port: 80, uri: "/", hostField: outputHost
      )
    }
    assertInvalidTarget(head(.CONNECT, "example.com", [("Host", "example.com")]))
    for port in ["", "0", "0000", "65536", "+443", "-1", "4 43", "４４３", "184467440737095516160"] {
      assertInvalidTarget(head(.CONNECT, "example.com:\(port)", [("Host", "example.com")]))
      assertInvalidTarget(head(.GET, "http://example.com:\(port)/", [("Host", "example.com")]))
      assertInvalidTarget(head(.GET, "/", [("Host", "example.com:\(port)")]))
    }
  }

  func testHP08PreservesExactPathQueryAndEscapeText() throws {
    let cases = [
      ("http://example.com", "/"), ("http://example.com?", "/?"),
      ("http://example.com?x=1", "/?x=1"),
      ("http://example.com/a%2Fb?q=%0D%0A", "/a%2Fb?q=%0D%0A"),
      ("http://example.com/%2f%2F?b=2&a=1&a=0", "/%2f%2F?b=2&a=1&a=0"),
      ("http://example.com/a/../b//c", "/a/../b//c"),
      ("HtTp://example.com/x", "/x"), ("/a%2Fb?x=", "/a%2Fb?x="),
      ("//other.example/a/../b?", "//other.example/a/../b?"),
    ]
    for (uri, expected) in cases {
      try assertForward(
        head(.GET, uri, [("Host", "example.com")]),
        host: "example.com", port: 80, uri: expected, hostField: "example.com"
      )
    }
  }

  func testHP09RejectsInvalidURITextAndUnsupportedSchemes() {
    for path in [
      "/a b", "/a\tb", "/a\rb", "/a\nb", "/a\u{0}b", "/a\u{7f}b", "/a\\b", "/a#b", "/%", "/%0",
      "/%GG", "/你好", "/a\u{a0}b",
    ] {
      for uri in [path, "http://example.com" + path] {
        assertFailure(head(.GET, uri, [("Host", "example.com")]), .invalidRequest)
      }
    }
    for uri in [
      "", " http://example.com/", "http://user@example.com/", "http://user:pass@example.com/",
      "http:///path", "http://%65xample.com/", "http://example.com#fragment",
    ] {
      assertInvalidTarget(head(.GET, uri, [("Host", "example.com")]))
    }
    for scheme in ["https", "HTTPS", "ws", "wss", "ftp"] {
      assertFailure(
        head(.GET, "\(scheme)://example.com/", [("Host", "example.com")]), .unsupportedFeature)
    }
  }

  // MARK: - 定界、逐跳字段和注入防护

  func testHP10DistinguishesAbsentZeroAndFixedLengthWithoutAllocatingABody() throws {
    let cases: [(String?, HttpProtocol.BodyFraming, String?)] = [
      (nil, .none, nil), ("0", .fixedLength(0), "0"),
      ("0004", .fixedLength(4), "4"), (" \t0004\t ", .fixedLength(4), "4"),
      ("18446744073709551615", .fixedLength(UInt64.max), "18446744073709551615"),
    ]
    for method in [HTTPMethod.GET, .POST, .HEAD] {
      for (length, framing, outputLength) in cases {
        var fields = [("Host", "example.com")]
        if let length { fields.append(("Content-Length", length)) }
        try assertForward(
          head(method, "/", fields), host: "example.com", port: 80, uri: "/",
          hostField: "example.com",
          body: framing, contentLength: outputLength
        )
      }
    }
  }

  func testHP11RejectsAmbiguousAndOverflowingContentLengthBeforeFiltering() {
    let invalid: [[(String, String)]] = [
      [("Content-Length", "4"), ("Content-Length", "4")],
      [("Content-Length", "4"), ("cOnTeNt-LeNgTh", "5")],
      [("Content-Length", "4, 4")], [("Content-Length", "")], [("Content-Length", "+4")],
      [("Content-Length", "-1")], [("Content-Length", "1 0")], [("Content-Length", "1\t0")],
      [("Content-Length", "0x10")], [("Content-Length", "４")], [("Content-Length", "\u{a0}4")],
      [("Content-Length", "18446744073709551616")],
      [("Content-Length", "0"), ("Transfer-Encoding", "chunked")],
      [("Transfer-Encoding", "identity"), ("Content-Length", "0")],
      [("Connection", "Content-Length"), ("Content-Length", "4, 4")],
    ]
    for fields in invalid {
      for (method, uri) in [(HTTPMethod.POST, "/"), (.CONNECT, "example.com:443")] {
        assertFailure(head(method, uri, [("Host", "example.com:443")] + fields), .invalidRequest)
      }
    }
  }

  func testHP12ConnectAllowsOnlyAbsentOrZeroContentLength() throws {
    for fields in [[], [("Content-Length", "0")], [("Content-Length", " \t000\t ")]] {
      try assertConnect(
        head(.CONNECT, "example.com:443", [("Host", "example.com")] + fields),
        host: "example.com", port: 443
      )
    }
    for fields in [
      [("Content-Length", "1")], [("Content-Length", "18446744073709551615")],
      [("Transfer-Encoding", "chunked")], [("Transfer-Encoding", "")],
    ] {
      assertFailure(
        head(.CONNECT, "example.com:443", [("Host", "example.com")] + fields), .invalidRequest)
    }
  }

  func testHP12RejectsUnsupportedFeaturesWithoutSilentlyRemovingHeaders() {
    for value in ["chunked", "identity", "gzip", ""] {
      assertFailure(
        head(.POST, "/", [("Host", "example.com"), ("Transfer-Encoding", value)]),
        .unsupportedFeature)
    }
    for (method, uri) in [(HTTPMethod.GET, "/"), (.CONNECT, "example.com:443")] {
      for fields in [
        [("Trailer", "X-Checksum")], [("Upgrade", "websocket")], [("Connection", "UpGrAdE")],
      ] {
        assertFailure(head(method, uri, [("Host", "example.com")] + fields), .unsupportedFeature)
      }
      for expectation in ["100-continue", "custom", ""] {
        assertFailure(
          head(method, uri, [("Host", "example.com"), ("Expect", expectation)]),
          .unsupportedExpectation)
      }
      assertFailure(
        head(
          method, uri,
          [
            ("Host", "example.com"), ("Content-Length", "0"), ("Transfer-Encoding", "chunked"),
            ("Expect", "100-continue"),
          ]),
        .invalidRequest
      )
    }
  }

  func testHP13RemovesOrdinaryConnectionNominationsAndFixedHopByHopFields() throws {
    let output = try assertForward(
      head(
        .GET, "/",
        [
          ("Host", "example.com"), ("Connection", "keep-alive, X-Remove, ,"),
          ("cOnNeCtIoN", "\tX-Other\t,,"), ("X-Remove", "one"), ("x-remove", "two"),
          ("X-Other", "three"), ("Keep-Alive", "timeout=5"), ("Proxy-Connection", "keep-alive"),
          ("TE", "trailers"), ("Proxy-Authenticate", "Basic realm=proxy"),
          ("Proxy-Authorization", "Basic test-placeholder"), ("X-Keep", "  unchanged\tvalue  "),
        ]),
      host: "example.com", port: 80, uri: "/", hostField: "example.com"
    )
    XCTAssertEqual(output.headers["X-Keep"], ["  unchanged\tvalue  "])
    XCTAssertEqual(output.headers.count, 3)
    for name in [
      "X-Remove", "X-Other", "Keep-Alive", "Proxy-Connection", "TE", "Proxy-Authenticate",
      "Proxy-Authorization",
    ] {
      XCTAssertEqual(output.headers[name], [], name)
    }
    // TE 是可移除字段，与禁止 Connection 指名的 Transfer-Encoding 不同。
    let nominatedTE = try assertForward(
      head(.GET, "/", [("Host", "example.com"), ("Connection", "TE"), ("TE", "trailers")]),
      host: "example.com", port: 80, uri: "/", hostField: "example.com"
    )
    XCTAssertEqual(nominatedTE.headers["TE"], [])
  }

  func testHP13RejectsCriticalNominationsAndMalformedConnectionTokens() {
    for name in [
      "hOsT", "CONTENT-LENGTH", "Transfer-Encoding", "Trailer", "Authorization",
      "Proxy-Authorization", "Expect",
    ] {
      for (method, uri) in [(HTTPMethod.GET, "/"), (.CONNECT, "example.com:443")] {
        assertFailure(
          head(
            method, uri,
            [("Host", "example.com"), ("Connection", "keep-alive"), ("Connection", name)]),
          .invalidRequest)
      }
    }
    for token in ["bad token", "bad@token", "\"quoted\"", "x=y", "x:y", "非ASCII"] {
      assertFailure(
        head(.GET, "/", [("Host", "example.com"), ("Connection", token)]), .invalidRequest)
    }
  }

  func testHP14PreservesEndToEndValuesAndDuplicateOrderWithoutProxyCredentials() throws {
    let output = try assertForward(
      head(
        .POST, "/",
        [
          ("Host", "example.com"), ("Authorization", "Bearer origin-placeholder"),
          ("Cookie", "a=1"), ("X-Value", "first,second"), ("cookie", "b=2"),
          ("x-value", "third"), ("Proxy-Authorization", "Basic proxy-placeholder"),
          ("Content-Length", "0004"),
        ]),
      host: "example.com", port: 80, uri: "/", hostField: "example.com", body: .fixedLength(4),
      contentLength: "4"
    )
    XCTAssertEqual(output.headers["Authorization"], ["Bearer origin-placeholder"])
    XCTAssertEqual(output.headers["Cookie"], ["a=1", "b=2"])
    XCTAssertEqual(output.headers["X-Value"], ["first,second", "third"])
    XCTAssertEqual(output.headers["Proxy-Authorization"], [])
    XCTAssertEqual(output.headers.count, 8)
  }

  func testHP15ValidatesManuallyConstructedMethodsNamesAndControlCharacters() {
    for method in ["", "BAD METHOD", "GET\r\nInjected", "X\u{0}", "X\u{7f}", "GÉT", "X:Y", "X/Y"] {
      assertFailure(
        head(HTTPMethod(rawValue: method), "/", [("Host", "example.com")]), .invalidRequest)
    }
    for name in ["", "Bad Name", "Bad:Name", "Bad@Name", "Bad\r\nName", "X\u{0}", "Náme"] {
      assertFailure(head(.GET, "/", [("Host", "example.com"), (name, "value")]), .invalidRequest)
    }
    for byte in Array(UInt8(0)...UInt8(31)).filter({ $0 != 9 }) + [127] {
      let value = "before" + String(UnicodeScalar(byte)) + "after"
      for name in ["X-Test", "Proxy-Authorization", "Connection"] {
        assertFailure(head(.GET, "/", [("Host", "example.com"), (name, value)]), .invalidRequest)
      }
    }
  }

  func testHP15AllowsAllHTTPTokenPunctuationAndHTABInFieldValues() throws {
    let name = "!#$%&'*+-.^_`|~0123456789AZaz"
    let output = try assertForward(
      head(.GET, "/", [("Host", "example.com"), (name, "left\tright")]),
      host: "example.com", port: 80, uri: "/", hostField: "example.com"
    )
    XCTAssertEqual(output.headers[name], ["left\tright"])
  }

  // MARK: - 跨协议、OPTIONS 和值语义

  func testHP16HTTPAndWireNumericTargetsShareIdentityRoutingAndEncoding() throws {
    let model = try HttpProtocol(
      head: head(.CONNECT, "[::ffff:192.0.2.1]:443", [("Host", "192.0.2.1")]))
    guard case .connect(let httpTarget, _) = model.request else {
      return XCTFail("expected CONNECT")
    }
    let literal = Data([1, 192, 0, 2, 1, 1, 187])
    let (wireTarget, consumed) = try NetworkAddress.decodeShadowsocksAddress(from: literal)
    XCTAssertEqual(consumed, 7)
    let expected = try NetworkAddress(host: "192.0.2.1", port: 443)
    XCTAssertEqual(httpTarget, expected)
    XCTAssertEqual(wireTarget, expected)
    XCTAssertEqual(Socks5Connection.addressBytes(of: httpTarget), literal)
    XCTAssertEqual(try httpTarget.shadowsocksAddressBytes(), literal)
    XCTAssertEqual(try wireTarget.shadowsocksAddressBytes(), literal)
    let node = ProxyNode(
      address: try SocketAddress(ipAddress: "192.0.2.254", port: 8388), cipher: .aes256Gcm,
      password: "test-placeholder")
    let core = try MagentCore(
      defaultDecision: .direct, proxyNodes: [node], defaultTimeout: 10_000,
      rules: [
        try ProxyRule(
          matchType: .ipCIDR, matchValue: "192.0.2.0/24", decision: .proxy(node.id), order: 0)
      ]
    )
    XCTAssertEqual(try XCTUnwrap(core.routeTCPWire(httpTarget)).getTargetAddress(), node.address)
    XCTAssertEqual(try XCTUnwrap(core.routeTCPWire(wireTarget)).getTargetAddress(), node.address)
  }

  func testHP22DistinguishesTargetedOptionsFromUnsupportedLocalOptionsAndTrace() throws {
    for (uri, expected) in [
      ("http://example.com", "*"), ("http://example.com?", "/?"),
      ("http://example.com?x=1", "/?x=1"), ("http://example.com/", "/"), ("/resource", "/resource"),
    ] {
      try assertForward(
        head(.OPTIONS, uri, [("Host", "example.com")]), host: "example.com", port: 80,
        uri: expected, hostField: "example.com")
    }
    assertFailure(head(.OPTIONS, "*", [("Host", "example.com")]), .unsupportedFeature)
    assertFailure(head(.GET, "*", [("Host", "example.com")]), .invalidRequest)
    for uri in ["/", "http://example.com"] {
      assertFailure(head(.TRACE, uri, [("Host", "example.com")]), .unsupportedFeature)
      for value in ["0", "1", "70"] {
        assertFailure(
          head(.OPTIONS, uri, [("Host", "example.com"), ("Max-Forwards", value)]),
          .unsupportedFeature)
      }
    }
  }

  /// 未解析域名和最大声明长度均无需网络或请求体；完整的无副作用约束仍须审查依赖与存储。
  func testHP23ConstructionIsDeterministicAndNeedsNoRuntimeOrBody() throws {
    let input = head(
      .POST, "http://never-resolve.invalid/",
      [("Host", "never-resolve.invalid"), ("Content-Length", "18446744073709551615")])
    for _ in 0..<3 {
      try assertForward(
        input, host: "never-resolve.invalid", port: 80, uri: "/",
        hostField: "never-resolve.invalid", body: .fixedLength(UInt64.max),
        contentLength: "18446744073709551615")
      assertFailure(head(.GET, "/", []), .invalidRequest)
    }
    // 编译期确认模型可以跨并发边界传递，不创建 Task 或 Channel 来伪造证明。
    func requireSendable<T: Sendable>(_: T) {}
    requireSendable(try HttpProtocol(head: input))
  }

  func testHP24InputAndExtractedHeadCopiesCannotMutateTheModel() throws {
    var input = head(
      .POST, "http://example.com:80/a?x=",
      [("Host", "ignored.example"), ("X-Keep", "original"), ("Content-Length", "0004")])
    let model = try HttpProtocol(head: input)
    input.method = .DELETE
    input.uri = "/changed-input"
    input.headers.replaceOrAdd(name: "Content-Length", value: "999")
    guard case .forward(_, var copy, _) = model.request else { return XCTFail("expected forward") }
    copy.method = .PUT
    copy.uri = "/changed-copy"
    copy.version = .http1_0
    copy.headers.replaceOrAdd(name: "Host", value: "other.example")
    copy.headers.replaceOrAdd(name: "X-Keep", value: "changed")
    copy.headers.replaceOrAdd(name: "Content-Length", value: "0")
    guard case .forward(let target, let saved, let body) = model.request else {
      return XCTFail("expected forward")
    }
    XCTAssertEqual(target, try NetworkAddress(host: "example.com", port: 80))
    XCTAssertEqual(saved.method, .POST)
    XCTAssertEqual(saved.version, .http1_1)
    XCTAssertEqual(saved.uri, "/a?x=")
    XCTAssertEqual(saved.headers["Host"], ["example.com:80"])
    XCTAssertEqual(saved.headers["X-Keep"], ["original"])
    XCTAssertEqual(saved.headers["Content-Length"], ["4"])
    XCTAssertEqual(saved.headers["Connection"], ["close"])
    XCTAssertEqual(body, .fixedLength(4))
  }

  // MARK: - 只构造输入和检查结果，不实现测试专用 HTTP parser

  private func head(
    _ method: HTTPMethod, _ uri: String, _ fields: [(String, String)],
    version: HTTPVersion = .http1_1
  ) -> HTTPRequestHead {
    HTTPRequestHead(version: version, method: method, uri: uri, headers: HTTPHeaders(fields))
  }

  private func assertConnect(
    _ input: HTTPRequestHead, host: String, port: UInt16, file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let model = try HttpProtocol(head: input)
    guard case .connect(let target, let version) = model.request else {
      return XCTFail("expected CONNECT: \(input)", file: file, line: line)
    }
    XCTAssertEqual(target, try NetworkAddress(host: host, port: port), file: file, line: line)
    XCTAssertEqual(target.host, host, file: file, line: line)
    XCTAssertEqual(target.port, port, file: file, line: line)
    XCTAssertEqual(version, input.version, file: file, line: line)
  }

  @discardableResult
  private func assertForward(
    _ input: HTTPRequestHead, host: String, port: UInt16, uri: String, hostField: String,
    body: HttpProtocol.BodyFraming = .none, contentLength: String? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) throws -> HTTPRequestHead {
    let model = try HttpProtocol(head: input)
    guard case .forward(let target, let output, let framing) = model.request else {
      XCTFail("expected forward: \(input)", file: file, line: line)
      throw AssertionFailure.wrongBranch
    }
    XCTAssertEqual(target, try NetworkAddress(host: host, port: port), file: file, line: line)
    XCTAssertEqual(target.host, host, file: file, line: line)
    XCTAssertEqual(target.port, port, file: file, line: line)
    XCTAssertEqual(output.method, input.method, file: file, line: line)
    XCTAssertEqual(output.version, input.version, file: file, line: line)
    XCTAssertEqual(output.uri, uri, file: file, line: line)
    XCTAssertEqual(output.headers["Host"], [hostField], file: file, line: line)
    XCTAssertEqual(output.headers["Connection"], ["close"], file: file, line: line)
    XCTAssertEqual(
      output.headers["Content-Length"], contentLength.map { [$0] } ?? [], file: file, line: line)
    XCTAssertEqual(output.headers["Transfer-Encoding"], [], file: file, line: line)
    XCTAssertEqual(framing, body, file: file, line: line)
    return output
  }

  private enum AssertionFailure: Error { case wrongBranch }
  private enum FailureKind {
    case invalidRequest, unsupportedVersion, unsupportedFeature, unsupportedExpectation
  }

  private func assertFailure(
    _ input: HTTPRequestHead, _ expected: FailureKind, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try HttpProtocol(head: input), "\(input)", file: file, line: line) {
      error in
      switch (expected, error) {
      case (.invalidRequest, HttpProtocol.Failure.invalidRequest),
        (.unsupportedVersion, HttpProtocol.Failure.unsupportedVersion),
        (.unsupportedFeature, HttpProtocol.Failure.unsupportedFeature),
        (.unsupportedExpectation, HttpProtocol.Failure.unsupportedExpectation):
        break
      default: XCTFail("expected \(expected), got \(error)", file: file, line: line)
      }
    }
  }

  /// HTTP 词法错误属于 invalidRequest；受控地址入口及 NIO 的地址错误须保持原类型上抛。
  private func assertInvalidTarget(
    _ input: HTTPRequestHead, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try HttpProtocol(head: input), "\(input)", file: file, line: line) {
      error in
      switch error {
      case HttpProtocol.Failure.invalidRequest, MagentError.invalidAddress, is SocketAddressError:
        break
      default: XCTFail("expected invalid request/address, got \(error)", file: file, line: line)
      }
    }
  }
  // MARK: - 真实 HTTP forward 报文边界（HP-03、HP-11～15、HP-17、HP-20～22）

  /// 重复字段必须经过 NIO decoder；不能只证明手工 HTTPHeaders 能保留重复值。
  func testModelSpecHP11RejectsAmbiguousFramingOnTheWire() throws {
    let fields = [
      "Content-Length: 0\r\nContent-Length: 0\r\n",
      "Content-Length: 1\r\ncOnTeNt-LeNgTh: 2\r\n",
      "Content-Length: 4, 4\r\n",
      "Content-Length: 18446744073709551616\r\n",
      "Content-Length: +4\r\n",
      "Content-Length: -1\r\n",
      "Content-Length: 1 0\r\n",
      "Content-Length: 0\r\nTransfer-Encoding: chunked\r\n",
      "Transfer-Encoding: chunked\r\nContent-Length: 0\r\n",
      "Connection: Content-Length\r\nContent-Length: 0\r\n",
    ]
    for fields in fields {
      try assertHTTPModelSpecFailure(
        "POST http://127.0.0.1:8080/ HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n"
          + fields + "\r\n",
        status: 400
      )
    }
  }

  func testModelSpecHP03RejectsMissingDuplicateAndInvalidHostOnTheWire() throws {
    for fields in [
      "", "Host: \r\n", "Host: 127.0.0.1\r\nhOsT: 127.0.0.1\r\n",
      "Host: user@127.0.0.1\r\n", "Host: 127.0.0.1:0\r\n",
    ] {
      try assertHTTPModelSpecFailure(
        "GET http://127.0.0.1:8080/ HTTP/1.1\r\n" + fields + "\r\n", status: 400
      )
    }
  }

  func testModelSpecHP12AndHP20MapUnsupportedFeaturesAndExpectation() throws {
    let cases: [(String, Int)] = [
      ("Transfer-Encoding: chunked\r\n", 501),
      ("Trailer: X-Checksum\r\n", 501),
      ("Expect: 100-continue\r\n", 417),
      ("Expect: custom-expectation\r\n", 417),
      ("Upgrade: websocket\r\n", 501),
      ("Connection: UpGrAdE\r\n", 501),
    ]
    for (fields, status) in cases {
      try assertHTTPModelSpecFailure(
        "POST http://127.0.0.1:8080/ HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n"
          + fields + "\r\n",
        status: status
      )
    }
    // 已有非法定界时，不应被 Expect 的 417 或不支持特性的 501 掩盖。
    try assertHTTPModelSpecFailure(
      "POST / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nContent-Length: 0\r\n"
        + "Content-Length: 0\r\nExpect: 100-continue\r\n\r\n",
      status: 400
    )
  }

  func testModelSpecHP13RejectsConnectionNominatedCriticalFieldsOnTheWire() throws {
    for name in [
      "hOsT", "CONTENT-LENGTH", "Transfer-Encoding", "Trailer",
      "Authorization", "Proxy-Authorization", "Expect",
    ] {
      try assertHTTPModelSpecFailure(
        "GET / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nConnection: \(name)\r\n\r\n",
        status: 400
      )
    }
    for token in ["bad token", "bad@token", "\"quoted\""] {
      try assertHTTPModelSpecFailure(
        "GET / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nConnection: \(token)\r\n\r\n",
        status: 400
      )
    }
  }

  func testModelSpecHP09AndHP15RejectMalformedBytesThroughNIODecoder() throws {
    for target in ["/a b", "/a\\b", "/a#fragment", "/%", "/%0", "/%GG"] {
      try assertHTTPModelSpecFailure(
        "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n", status: 400
      )
    }
    for field in [
      "Bad Name: value", "Bad@Name: value", "X-Test: before\u{0}after",
      "X-Test: before\u{7f}after", "X-Test: before\u{1}after",
      "X-Test: before\rafter", "X-Test: before\nafter",
    ] {
      try assertHTTPModelSpecFailure(
        "GET / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\(field)\r\n\r\n", status: 400
      )
    }
  }

  func testModelSpecHP17WaitsForCompleteBodyAndClosesOnPrematureEOF() throws {
    for received in ["", "dat"] {
      let channel = try makeHTTPModelSpecConnectionChannel()
      defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
      try writeInbound(
        Data(
          ("POST / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nContent-Length: 4\r\n\r\n"
            + received).utf8),
        to: channel
      )
      channel.embeddedEventLoop.run()
      XCTAssertTrue(channel.isActive)
      XCTAssertNil(try readOutboundData(from: channel), "未收齐请求体不得进入路由或响应阶段")

      channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
      channel.embeddedEventLoop.run()
      XCTAssertFalse(channel.isActive)
      if let response = try readOutboundData(from: channel) {
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 400 "))
      }
      XCTAssertNil(try readOutboundData(from: channel))
    }
  }

  func testModelSpecHP17AndHP21RejectExtraBodyAndPipelinedRequests() throws {
    for suffix in ["datax", "dataGET /next HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"] {
      try assertHTTPModelSpecFailure(
        "POST / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nContent-Length: 4\r\n\r\n" + suffix,
        status: 400
      )
    }
  }

  /// 在真实 decoder 后注入 typed parts，验证连接的事件约束，不改生产 handler 的可见性。
  func testModelSpecHP17RejectsDuplicateHeadsPrematureEndAndActualTrailers() throws {
    let duplicateHead = HTTPRequestHead(
      version: .http1_1, method: .POST, uri: "/",
      headers: HTTPHeaders([("Host", "127.0.0.1:8080"), ("Content-Length", "4")]))
    let cases: [[HTTPServerRequestPart]] = [
      [.head(duplicateHead)],
      [.end(nil)],
      [.body(ByteBuffer(string: "datax")), .end(nil)],
      [.body(ByteBuffer(string: "data")), .end(HTTPHeaders([("X-Trailer", "value")]))],
    ]
    for parts in cases {
      let channel = try makeHTTPModelSpecConnectionChannel()
      let errors = try channel.pipeline.syncOperations.handler(type: HTTPModelSpecErrors.self)
      defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
      try writeInbound(
        Data("POST / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nContent-Length: 4\r\n\r\n".utf8),
        to: channel)
      let decoder = try channel.pipeline.syncOperations.handler(
        type: ByteToMessageHandler<HTTPRequestDecoder>.self)
      let injector = HTTPModelSpecParts()
      try channel.pipeline.addHandler(injector, position: .after(decoder)).wait()
      for part in parts { injector.send(part) }
      channel.embeddedEventLoop.run()
      try assertHTTPModelSpecResponse(channel, errors: errors, status: 400)
    }
  }

  /// typed 错误从 NIO 解码接入边界进入实际响应路径，不依赖诊断字符串选择状态码。
  func testModelSpecHP20MapsTypedFailuresToOneResponse() throws {
    let cases: [(Error, Int)] = [
      (HttpProtocol.Failure.invalidRequest("test-invalid"), 400),
      (HttpProtocol.Failure.unsupportedVersion, 505),
      (HttpProtocol.Failure.unsupportedFeature("test-feature"), 501),
      (HttpProtocol.Failure.unsupportedExpectation, 417),
      (MagentError.invalidAddress("test-address"), 400),
      (HTTPParserError.invalidHeaderToken, 400),
    ]
    for (error, status) in cases {
      let channel = try makeHTTPModelSpecConnectionChannel()
      let errors = try channel.pipeline.syncOperations.handler(type: HTTPModelSpecErrors.self)
      defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
      try writeInbound(Data("POST / HTTP/1.1\r\n".utf8), to: channel)
      let decoder = try channel.pipeline.syncOperations.handler(
        type: ByteToMessageHandler<HTTPRequestDecoder>.self)
      let injector = HTTPModelSpecParts()
      try channel.pipeline.addHandler(injector, position: .after(decoder)).wait()
      injector.fail(error)
      injector.fail(error)
      channel.embeddedEventLoop.run()
      try assertHTTPModelSpecResponse(channel, errors: errors, status: status)
    }
    // 模型入口产生 unsupportedVersion 才是 505；NIO 在生成 head 前拒绝的版本仍是 400。
    for version in ["HTTP/0.9", "HTTP/2.0"] {
      try assertHTTPModelSpecFailure(
        "GET / \(version)\r\nHost: 127.0.0.1:8080\r\n\r\n", status: 400)
    }
  }

  func testModelSpecHP22RejectsUnsupportedOptionsAndTraceOnTheWire() throws {
    for request in [
      "OPTIONS * HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n",
      "OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nMax-Forwards: 0\r\n\r\n",
      "OPTIONS / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nMax-Forwards: 1\r\n\r\n",
      "TRACE / HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n",
    ] {
      try assertHTTPModelSpecFailure(request, status: 501)
    }
    try assertHTTPModelSpecFailure(
      "GET * HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n", status: 400
    )
    try assertHTTPModelSpecFailure(
      "GET https://127.0.0.1:8080/ HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n", status: 501)
  }

  func testModelSpecHP21ClosesASecondRequestAfterTheFirstWasForwarded() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let shutdown = group.next().makePromise(of: Void.self)
    let accepted = group.next().makePromise(of: Channel.self)
    let firstRequest = group.next().makePromise(of: Data.self)
    var channels: [Channel] = []
    defer {
      shutdown.succeed(())
      shutdownTestChannels(channels, group: group)
    }
    let target = try ServerBootstrap(group: group).childChannelInitializer { channel in
      accepted.succeed(channel)
      return channel.pipeline.addHandler(HTTPModelSpecResponseCapture(promise: firstRequest))
    }.bind(host: "127.0.0.1", port: 0).wait()
    channels.append(target)
    let core = try MagentCore(
      defaultDecision: .direct, proxyNodes: [], defaultTimeout: 1000, rules: [])
    let proxy = try bindTCPProxy(group: group, core: core, shutdownFuture: shutdown.futureResult)
    channels.append(proxy)
    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxy.localAddress)).wait()
    channels.append(client)
    let port = try XCTUnwrap(target.localAddress?.port)
    try writeData(
      Data("GET http://127.0.0.1:\(port)/first HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8),
      to: client)
    let first = try waitForHTTPModelSpec(firstRequest.futureResult)
    let (head, body) = try decodeHTTPModelSpecRequest(first)
    XCTAssertEqual(head.uri, "/first")
    XCTAssertEqual(body, Data())
    let targetChannel = try waitForHTTPModelSpec(accepted.futureResult)
    channels.append(targetChannel)
    let secondBytes = targetChannel.eventLoop.makePromise(of: Data.self)
    try targetChannel.pipeline.addHandler(
      TestDataCollector(expectedByteCount: 1, promise: secondBytes), position: .first
    ).wait()
    try writeData(
      Data("GET /second HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n".utf8), to: client)
    try waitForHTTPModelSpec(client.closeFuture)
    try waitForHTTPModelSpec(targetChannel.closeFuture)
    XCTAssertThrowsError(try waitForHTTPModelSpec(secondBytes.futureResult)) { error in
      XCTAssertEqual(error as? MagentError, .connectionClosed)
    }
  }

  func testHP19DirectRequestAndResponseUseManualReadFlow() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let targetRequestPromise = eventLoop.makePromise(of: Data.self)
    let targetRequestLengthPromise = eventLoop.makePromise(of: Int.self)
    let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".utf8)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let targetServer = try ServerBootstrap(group: group)
      .childChannelInitializer { channel in
        targetAcceptedPromise.succeed(channel)
        return targetRequestLengthPromise.futureResult.flatMap { byteCount in
          channel.pipeline.addHandler(
            TestDataCollector(expectedByteCount: byteCount, promise: targetRequestPromise)
          )
        }
      }
      .bind(host: "127.0.0.1", port: 0)
      .wait()
    channels.append(targetServer)

    let core = try MagentCore(
      defaultDecision: .direct,
      proxyNodes: [],
      defaultTimeout: 10_000,
      rules: []
    )
    let proxyServer = try bindTCPProxy(
      group: group,
      core: core,
      shutdownFuture: shutdownPromise.futureResult
    )
    channels.append(proxyServer)

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let clientResponsePromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandler(
      TestDataCollector(expectedByteCount: response.count, promise: clientResponsePromise)
    ).wait()

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    let expectedForwardedRequest = Data(
      "POST /resource HTTP/1.1\r\nHost: 127.0.0.1:\(targetPort)\r\n"
        .appending("Content-Length: 4\r\nConnection: close\r\n\r\ndata").utf8
    )
    targetRequestLengthPromise.succeed(expectedForwardedRequest.count)
    let request = Data(
      "POST http://127.0.0.1:\(targetPort)/resource HTTP/1.1\r\n"
        .appending(
          "Host: ignored.example\r\nProxy-Connection: keep-alive\r\nContent-Length: 4\r\n\r\ndata"
        ).utf8
    )
    try writeData(Data(request.dropLast(2)), to: client)
    try writeData(Data(request.suffix(2)), to: client)

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    let forwardedRequest = try targetRequestPromise.futureResult.wait()
    let (forwardedHead, forwardedBody) = try decodeHTTPModelSpecRequest(forwardedRequest)
    XCTAssertEqual(forwardedHead.method, .POST)
    XCTAssertEqual(forwardedHead.version, .http1_1)
    XCTAssertEqual(forwardedHead.uri, "/resource")
    XCTAssertEqual(forwardedHead.headers["Host"], ["127.0.0.1:\(targetPort)"])
    XCTAssertEqual(forwardedHead.headers["Content-Length"], ["4"])
    XCTAssertEqual(forwardedHead.headers["Connection"], ["close"])
    XCTAssertEqual(forwardedHead.headers.count, 3)
    XCTAssertEqual(forwardedBody, Data("data".utf8))

    try writeData(response, to: targetChannel)
    XCTAssertEqual(try clientResponsePromise.futureResult.wait(), response)
  }

  /// HP-19：解密后验证启动目标和完整 HTTP 消息，不约束编码器分几次写入或产生多少 AEAD 帧。
  func testHP19ProxyHandshakePrecedesCompleteForwardedRequest() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let proxyNodeAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let plaintextPromise = eventLoop.makePromise(of: Data.self)
    let cipher = ProxyCipher.aes256Gcm
    let host = "example.com"
    let forwardedRequest = Data(
      "POST /resource HTTP/1.1\r\nHost: example.com\r\nContent-Length: 4\r\nConnection: close\r\n\r\ndata"
        .utf8
    )
    let shadowsocksAddressLength = 1 + 1 + host.utf8.count + 2
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let shadowsocksServer = try ServerBootstrap(group: group)
      .childChannelInitializer { channel in
        proxyNodeAcceptedPromise.succeed(channel)
        do {
          let peerNode = ProxyNode(
            address: try XCTUnwrap(channel.localAddress), cipher: cipher, password: "test")
          let peer = try ShadowsocksTCPWire(proxyNode: peerNode)
          _ = try peer.start(handshake: NetworkAddress(host: "example.com", port: 80))
          return channel.pipeline.addHandlers(
            HTTPModelSpecWireDecoder(wire: peer),
            TestDataCollector(
              expectedByteCount: shadowsocksAddressLength + forwardedRequest.count,
              promise: plaintextPromise)
          )
        } catch {
          return channel.eventLoop.makeFailedFuture(error)
        }
      }
      .bind(host: "127.0.0.1", port: 0)
      .wait()
    channels.append(shadowsocksServer)

    let defaultNode = ProxyNode(
      address: try XCTUnwrap(shadowsocksServer.localAddress),
      cipher: cipher,
      password: "test"
    )
    let core = try MagentCore(
      defaultDecision: .proxy(defaultNode.id),
      proxyNodes: [defaultNode],
      defaultTimeout: 10_000,
      rules: []
    )
    let proxyServer = try bindTCPProxy(
      group: group,
      core: core,
      shutdownFuture: shutdownPromise.futureResult
    )
    channels.append(proxyServer)

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let request = Data(
      "POST http://example.com/resource HTTP/1.1\r\nHost: ignored.example\r\nContent-Length: 0004\r\n\r\ndata"
        .utf8
    )
    try writeData(request, to: client)

    let plaintext = try waitForHTTPModelSpec(plaintextPromise.futureResult)
    channels.append(try waitForHTTPModelSpec(proxyNodeAcceptedPromise.futureResult))
    let expectedAddress = Data([3, 11]) + Data("example.com".utf8) + Data([0, 80])
    XCTAssertEqual(Data(plaintext.prefix(expectedAddress.count)), expectedAddress)
    let (outboundHead, outboundBody) = try decodeHTTPModelSpecRequest(
      Data(plaintext.dropFirst(expectedAddress.count)))
    XCTAssertEqual(outboundHead.method, .POST)
    XCTAssertEqual(outboundHead.version, .http1_1)
    XCTAssertEqual(outboundHead.uri, "/resource")
    XCTAssertEqual(outboundHead.headers["Host"], ["example.com"])
    XCTAssertEqual(outboundHead.headers["Content-Length"], ["4"])
    XCTAssertEqual(outboundHead.headers["Connection"], ["close"])
    XCTAssertEqual(outboundHead.headers.count, 3)
    XCTAssertEqual(outboundBody, Data("data".utf8))
  }

  // MARK: - 真实 CONNECT 报文与时序（HP-05、HP-12、HP-18、HP-20）

  func testModelSpecHP12RejectsNonzeroLengthAndTransferEncodingOnConnect() throws {
    for fields in [
      "Content-Length: 1\r\n", "Transfer-Encoding: chunked\r\n",
      "Content-Length: 0\r\nContent-Length: 0\r\n",
      "Content-Length: 0\r\nTransfer-Encoding: chunked\r\n",
    ] {
      try assertHTTPModelSpecFailure(
        "CONNECT 127.0.0.1:443 HTTP/1.1\r\nHost: 127.0.0.1\r\n" + fields + "\r\n",
        status: 400
      )
    }
  }

  func testModelSpecHP18WaitsAtEveryConnectSplitAndRejectsEarlyTunnelBytes() throws {
    let request = Data("CONNECT 127.0.0.1:443 HTTP/1.1\r\nHost: 127.0.0.1:443\r\n\r\n".utf8)
    for split in 1..<request.count {
      let channel = try makeHTTPModelSpecConnectionChannel()
      defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
      try writeInbound(Data(request.prefix(split)), to: channel)
      channel.embeddedEventLoop.run()
      XCTAssertNil(try readOutboundData(from: channel), "split=\(split)")
      XCTAssertTrue(channel.isActive, "split=\(split)")
      // 尾部携带下一条合法 HTTP 方法前缀，专门命中 decoder 的 leftover 检查。
      try writeInbound(Data(request.dropFirst(split)) + Data("G".utf8), to: channel)
      channel.embeddedEventLoop.run()
      let response = try XCTUnwrap(try readOutboundData(from: channel))
      XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 400 "))
      XCTAssertNil(try readOutboundData(from: channel))
      XCTAssertFalse(channel.isActive)
    }
  }

  /// 成功报文也覆盖每个拆分点，Host 无端口和 CL=0 不能只在模型单测中通过。
  func testModelSpecHP05HP12HP18AndHP20AcceptsConnectAtEverySplit() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let shutdown = group.next().makePromise(of: Void.self)
    var channels: [Channel] = []
    defer {
      shutdown.succeed(())
      shutdownTestChannels(channels, group: group)
    }
    let target = try ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).wait()
    channels.append(target)
    let core = try MagentCore(
      defaultDecision: .direct, proxyNodes: [], defaultTimeout: 1000, rules: [])
    let proxy = try bindTCPProxy(group: group, core: core, shutdownFuture: shutdown.futureResult)
    channels.append(proxy)
    let port = try XCTUnwrap(target.localAddress?.port)
    let request = Data(
      "CONNECT 127.0.0.1:\(port) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n".utf8
    )
    for split in 1..<request.count {
      let response = group.next().makePromise(of: Data.self)
      let capture = HTTPModelSpecResponseCapture(promise: response)
      let client = try ClientBootstrap(group: group).channelInitializer { channel in
        channel.pipeline.addHandler(capture)
      }.connect(to: XCTUnwrap(proxy.localAddress)).wait()
      channels.append(client)
      try writeData(Data(request.prefix(split)), to: client)
      try writeData(Data(request.dropFirst(split)), to: client)
      let bytes = try waitForHTTPModelSpec(response.futureResult)
      // 精确字节同时证明只有一个成功响应且没有 CL、TE 或响应体。
      XCTAssertEqual(
        bytes, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), "split=\(split)")
      try client.close().wait()
    }
  }

  /// HP-16：真实 HTTP / SOCKS 解析器必须命中同一 CIDR 节点，并产生同一个数值 Wire 目标。
  func testModelSpecHP16HTTPAndSOCKSUseTheSameNumericRouteAndWireTarget() throws {
    let requests: [[Data]] = [
      [Data("CONNECT [::ffff:192.0.2.1]:443 HTTP/1.1\r\nHost: 192.0.2.1\r\n\r\n".utf8)],
      [Data("GET http://[::ffff:192.0.2.1]:443/ HTTP/1.1\r\nHost: ignored.example\r\n\r\n".utf8)],
      [Data([4, 1, 1, 187, 192, 0, 2, 1, 0])],
      [Data([5, 1, 0]), Data([5, 1, 0, 1, 192, 0, 2, 1, 1, 187])],
    ]
    for parts in requests {
      let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
      let shutdown = group.next().makePromise(of: Void.self)
      let encrypted = group.next().makePromise(of: Data.self)
      let accepted = group.next().makePromise(of: Channel.self)
      var channels: [Channel] = []
      defer {
        shutdown.succeed(())
        shutdownTestChannels(channels, group: group)
      }
      let server = try ServerBootstrap(group: group).childChannelInitializer { channel in
        accepted.succeed(channel)
        // AES-256-GCM salt(32) + length(2+16) + IPv4 address(7+16)。
        return channel.pipeline.addHandler(
          TestDataCollector(expectedByteCount: 73, promise: encrypted))
      }.bind(host: "127.0.0.1", port: 0).wait()
      channels.append(server)
      let node = ProxyNode(
        address: try XCTUnwrap(server.localAddress), cipher: .aes256Gcm,
        password: "test-placeholder")
      let core = try MagentCore(
        defaultDecision: .direct, proxyNodes: [node], defaultTimeout: 1000,
        rules: [
          try ProxyRule(
            matchType: .ipCIDR, matchValue: "192.0.2.0/24", decision: .proxy(node.id), order: 0)
        ]
      )
      let proxy = try bindTCPProxy(group: group, core: core, shutdownFuture: shutdown.futureResult)
      channels.append(proxy)
      let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxy.localAddress))
        .wait()
      channels.append(client)
      if parts.count == 2 {
        let greeting = client.eventLoop.makePromise(of: Data.self)
        try client.pipeline.addHandler(TestDataCollector(expectedByteCount: 2, promise: greeting))
          .wait()
        try writeData(parts[0], to: client)
        XCTAssertEqual(try waitForHTTPModelSpec(greeting.futureResult), Data([5, 0]))
      }
      try writeData(try XCTUnwrap(parts.last), to: client)
      let bytes = try waitForHTTPModelSpec(encrypted.futureResult)
      channels.append(try waitForHTTPModelSpec(accepted.futureResult))
      let peer = try ShadowsocksTCPWire(proxyNode: node)
      _ = try peer.start(handshake: NetworkAddress(host: "192.0.2.1", port: 443))
      let plaintext = try peer.decodeInbound(bytes).data
      XCTAssertEqual(Data(plaintext.prefix(7)), Data([1, 192, 0, 2, 1, 1, 187]))
    }
  }

}

/// 所有合法的回环目标都命中缺失节点，从真实路由边界失败，避免错误放行时发起网络拨号。
/// 正确拒绝应先返回指定的 HTTP 错误；若误进入路由，该错误不能冒充预期语义错误。
private func makeHTTPModelSpecConnectionChannel() throws -> EmbeddedChannel {
  let channel = EmbeddedChannel()
  let core = try MagentCore(
    defaultDecision: .direct, proxyNodes: [], defaultTimeout: 10_000,
    rules: [
      try ProxyRule(
        matchType: .ipCIDR, matchValue: "127.0.0.0/8",
        decision: .proxy(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), order: 0)
    ]
  )
  let shutdown = channel.eventLoop.makePromise(of: Void.self)
  try channel.pipeline.addHandlers(
    HTTPModelSpecErrors(),
    MagentTCPConnection(channel, core: core, dnsAddress: nil, shutdownFuture: shutdown.futureResult)
  ).wait()
  try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
  return channel
}

/// 使用真实探测器和 NIO 请求解码器，断言类别对应的状态码、单次响应和关闭。
private func assertHTTPModelSpecFailure(
  _ request: String, status: Int, file: StaticString = #filePath, line: UInt = #line
) throws {
  let channel = try makeHTTPModelSpecConnectionChannel()
  let errors = try channel.pipeline.syncOperations.handler(type: HTTPModelSpecErrors.self)
  defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true), file: file, line: line) }
  try writeInbound(Data(request.utf8), to: channel)
  channel.embeddedEventLoop.run()
  try assertHTTPModelSpecResponse(channel, errors: errors, status: status, file: file, line: line)
}

private func assertHTTPModelSpecResponse(
  _ channel: EmbeddedChannel, errors: HTTPModelSpecErrors, status: Int,
  file: StaticString = #filePath, line: UInt = #line
) throws {
  for error in errors.values {
    if case MagentError.proxyNodeNotFound = error {
      XCTFail("非法请求进入了路由阶段", file: file, line: line)
    }
  }
  let response = try XCTUnwrap(try readOutboundData(from: channel), file: file, line: line)
  assertHTTPModelSpecErrorBytes(response, status: status, file: file, line: line)
  XCTAssertNil(try readOutboundData(from: channel), file: file, line: line)
  XCTAssertFalse(channel.isActive, file: file, line: line)
}

/// 错误响应按状态和完整消息头比较，允许编码器增加合法的 Content-Length: 0。
private func assertHTTPModelSpecErrorBytes(
  _ response: Data, status: Int, file: StaticString = #filePath, line: UInt = #line
) {
  let text = String(decoding: response, as: UTF8.self)
  XCTAssertEqual(
    Array(text.components(separatedBy: "\r\n")[0].split(separator: " ").prefix(2)),
    ["HTTP/1.1", Substring(String(status))], file: file, line: line
  )
  XCTAssertEqual(text.components(separatedBy: "HTTP/1.1 ").count, 2, file: file, line: line)
  XCTAssertTrue(text.contains("\r\n\r\n"), file: file, line: line)
}

/// 只在 EmbeddedEventLoop 使用，向现有 HTTP handler 交付协议事件和原始错误。
private final class HTTPModelSpecParts: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  private var context: ChannelHandlerContext?

  func handlerAdded(context: ChannelHandlerContext) { self.context = context }
  func send(_ part: HTTPServerRequestPart) { context?.fireChannelRead(NIOAny(part)) }
  func fail(_ error: Error) { context?.fireErrorCaught(error) }
}

/// 仅由 EmbeddedEventLoop 访问，在生产 handler 消费错误之前记录路由越界。
private final class HTTPModelSpecErrors: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  var values: [Error] = []

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    values.append(error)
    context.fireErrorCaught(error)
  }
}

/// 对未来完成设置统一上限，生产缺口不能把测试挂在无限期 future.wait() 上。
private func waitForHTTPModelSpec<Value: Sendable>(_ future: EventLoopFuture<Value>) throws -> Value
{
  let ready = XCTestExpectation(description: "HTTP Model SPEC operation completes")
  future.whenComplete { _ in ready.fulfill() }
  guard XCTWaiter.wait(for: [ready], timeout: 3) == .completed else {
    throw HTTPModelSpecWaitFailure.timeout
  }
  return try future.wait()
}

private enum HTTPModelSpecWaitFailure: Error { case timeout }

/// 本机 Shadowsocks peer 在所属 EventLoop 解密，后续收集器按明文字节而非 AEAD 帧数完成。
private final class HTTPModelSpecWireDecoder: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  typealias InboundOut = ByteBuffer
  private let wire: ShadowsocksTCPWire

  init(wire: ShadowsocksTCPWire) { self.wire = wire }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    do {
      let plaintext = try wire.decodeInbound(Data(unwrapInboundIn(data).readableBytesView)).data
      if !plaintext.isEmpty {
        context.fireChannelRead(wrapInboundOut(ByteBuffer(bytes: plaintext)))
      }
    } catch {
      context.fireErrorCaught(error)
    }
  }
}

/// 用 NIO 重新解码解密后的真实出站字节，检查头部和请求体没有丢失、重复或额外消息。
private func decodeHTTPModelSpecRequest(_ data: Data) throws -> (HTTPRequestHead, Data) {
  let channel = EmbeddedChannel(handler: ByteToMessageHandler(HTTPRequestDecoder()))
  defer { XCTAssertNoThrow(try channel.finish()) }
  try channel.writeInbound(ByteBuffer(bytes: data))
  var heads: [HTTPRequestHead] = []
  var body = Data()
  var ends = 0
  while let part = try channel.readInbound(as: HTTPServerRequestPart.self) {
    switch part {
    case .head(let head): heads.append(head)
    case .body(let bytes): body.append(contentsOf: bytes.readableBytesView)
    case .end(let trailers):
      XCTAssertNil(trailers)
      ends += 1
    }
  }
  XCTAssertEqual(heads.count, 1)
  XCTAssertEqual(ends, 1)
  return (try XCTUnwrap(heads.first), body)
}

/// 在所属 EventLoop 上收集完整响应头；错误响应也完成 promise，使成功测试及时显示差异。
private final class HTTPModelSpecResponseCapture: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  private let promise: EventLoopPromise<Data>
  private var bytes = Data()
  private var completed = false

  init(promise: EventLoopPromise<Data>) { self.promise = promise }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    bytes.append(contentsOf: unwrapInboundIn(data).readableBytesView)
    if !completed, bytes.range(of: Data([13, 10, 13, 10])) != nil {
      completed = true
      promise.succeed(bytes)
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    if !completed {
      completed = true
      promise.fail(MagentError.connectionClosed)
    }
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    if !completed {
      completed = true
      promise.fail(error)
    }
    context.close(promise: nil)
  }
}
