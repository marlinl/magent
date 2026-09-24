import Foundation
import NIOCore
import NIOPosix
import XCTest

@testable import Magent

/// `MagentCore` 节点、规则、Wire 路由和客户端 Channel 创建测试。
final class MagentCoreTests: XCTestCase {
  private var core: MagentCore!

  override func setUpWithError() throws {
    core = try makeCore()
  }

  override func tearDownWithError() throws {
    core = nil
  }

  func testDirectRouteReturnsNoWire() throws {
    let target = try NetworkAddress(host: "direct.example", port: 443)

    XCTAssertNil(try core.routeTCPWire(target))
    XCTAssertNil(try core.routeUDPWire(target))
  }

  /// 空规则和未命中规则均采用默认代理决策，命中直连规则时覆盖默认决策。
  func testDefaultProxyDecisionHandlesEmptyAndUnmatchedRules() throws {
    let node = try makeRoutingNode(host: "192.0.2.20")
    let directRule = try ProxyRule(
      matchType: .exactDomain,
      matchValue: "direct.example",
      decision: .direct,
      order: 0
    )
    let unmatched = try NetworkAddress(host: "unmatched.example", port: 443)
    for rules in [[], [directRule]] {
      let core = try MagentCore(
        defaultDecision: .proxy(node.id),
        proxyNodes: [node],
        defaultTimeout: 10_000,
        rules: rules
      )
      XCTAssertEqual(try core.routeTCPWire(unmatched)?.getTargetAddress(), node.address)
      XCTAssertEqual(try core.routeUDPWire(unmatched)?.getTargetAddress(), node.address)
      if !rules.isEmpty {
        let direct = try NetworkAddress(host: "direct.example", port: 443)
        XCTAssertNil(try core.routeTCPWire(direct))
        XCTAssertNil(try core.routeUDPWire(direct))
      }
    }
  }

  func testInitThrowsWhenDefaultProxyNodeIsMissing() throws {
    let missingNodeID = try XCTUnwrap(
      UUID(uuidString: "11111111-2222-3333-4444-555555555555")
    )

    XCTAssertThrowsError(
      try MagentCore(
        defaultDecision: .proxy(missingNodeID),
        proxyNodes: [],
        defaultTimeout: 10_000,
        rules: []
      )
    ) { error in
      XCTAssertEqual(error as? MagentError, .proxyNodeNotFound(missingNodeID))
    }
  }

  func testTCPProxyRouteUsesRegisteredNodeAddress() throws {
    let node = try makeProxyNode(id: UUID(), host: "192.0.2.10")
    let target = try NetworkAddress(host: "target.example", port: 443)
    core = try makeCore(rules: [
      try ProxyRule(
        matchType: .exactDomain,
        matchValue: "target.example",
        decision: .proxy(node.id),
        order: 0
      )
    ])
    try core.putAllProxyNodes([node])

    let wire = try XCTUnwrap(core.routeTCPWire(target))

    XCTAssertEqual(wire.getTargetAddress(), node.address)
  }

  func testTCPProxyRouteThrowsWhenNodeIsMissing() throws {
    let missingNodeID = UUID()
    let target = try NetworkAddress(host: "missing.example", port: 443)
    core = try makeCore(rules: [
      try ProxyRule(
        matchType: .exactDomain,
        matchValue: "missing.example",
        decision: .proxy(missingNodeID),
        order: 0
      )
    ])

    XCTAssertThrowsError(try core.routeTCPWire(target)) { error in
      XCTAssertEqual(error as? MagentError, .proxyNodeNotFound(missingNodeID))
    }
  }

  func testUDPProxyRouteThrowsWhenNodeIsMissing() throws {
    let missingNodeID = UUID()
    let target = try NetworkAddress(host: "missing.example", port: 53)
    core = try makeCore(rules: [
      try ProxyRule(
        matchType: .exactDomain,
        matchValue: "missing.example",
        decision: .proxy(missingNodeID),
        order: 0
      )
    ])

    XCTAssertThrowsError(try core.routeUDPWire(target)) { error in
      XCTAssertEqual(error as? MagentError, .proxyNodeNotFound(missingNodeID))
    }
  }

  func testUDPRouteUsesRegisteredWire() throws {
    let node = try makeProxyNode(id: UUID(), host: "192.0.2.11")
    let target = try NetworkAddress(host: "dns.example", port: 53)
    core = try makeCore(rules: [
      try ProxyRule(
        matchType: .exactDomain,
        matchValue: "dns.example",
        decision: .proxy(node.id),
        order: 0
      )
    ])
    try core.putAllProxyNodes([node])

    let routeWire = try XCTUnwrap(core.routeUDPWire(target))

    XCTAssertEqual(routeWire.getTargetAddress(), node.address)
  }

  func testPutAllProxyNodesUsesLastNodeForDuplicateID() throws {
    let nodeID = UUID()
    let first = try makeProxyNode(id: nodeID, host: "192.0.2.12")
    let last = try makeProxyNode(id: nodeID, host: "192.0.2.13")
    let target = try NetworkAddress(host: "target.example", port: 443)
    core = try makeCore(rules: [
      try ProxyRule(
        matchType: .exactDomain,
        matchValue: "target.example",
        decision: .proxy(nodeID),
        order: 0
      )
    ])
    try core.putAllProxyNodes([first, last])

    XCTAssertEqual(try core.routeTCPWire(target)?.getTargetAddress(), last.address)
    XCTAssertEqual(try core.routeUDPWire(target)?.getTargetAddress(), last.address)
  }

  func testPutAllProxyNodesRejectsDuplicateAddressForDifferentIDs() throws {
    let address = try SocketAddress(ipAddress: "192.0.2.14", port: 8388)
    let first = try ProxyNode(
      id: UUID(),
      address: address,
      cipher: .aes128Gcm,
      password: "first-password"
    )
    let second = try ProxyNode(
      id: UUID(),
      address: address,
      cipher: .aes256Gcm,
      password: "second-password"
    )
    XCTAssertThrowsError(try core.putAllProxyNodes([first, second])) { error in
      guard case MagentError.invalidPolicy(let message) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("192.0.2.14"))
    }
  }

  /// 更换同一节点的端点和凭据后，路由使用新配置，旧端点可交给另一个节点。
  func testReplacingNodeReleasesOldEndpointAndUpdatesWireConfiguration() throws {
    let nodeID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    let original = try ProxyNode(
      id: nodeID, address: SocketAddress(ipAddress: "192.0.2.40", port: 8388),
      cipher: .aes128Gcm, password: "original-password")
    let replacement = try ProxyNode(
      id: nodeID, address: SocketAddress(ipAddress: "192.0.2.41", port: 8389),
      cipher: .aes256Gcm, password: "replacement-password", timeoutMilliseconds: 1_250)
    let reusedEndpoint = try ProxyNode(
      id: XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")),
      address: SocketAddress(ipAddress: "192.0.2.40", port: 8388),
      cipher: .aes128Gcm, password: "another-password")
    let core = try MagentCore(
      defaultDecision: .proxy(nodeID), proxyNodes: [original], defaultTimeout: 10_000,
      rules: [])
    try core.putAllProxyNodes([replacement, reusedEndpoint])

    let target = try NetworkAddress(host: "target.example", port: 53)
    let tcpWire = try XCTUnwrap(core.routeTCPWire(target))
    let udpWire = try XCTUnwrap(core.routeUDPWire(target))
    let expectedEndpoint = try SocketAddress(ipAddress: "192.0.2.41", port: 8389)
    XCTAssertEqual(tcpWire.getTargetAddress(), expectedEndpoint)
    XCTAssertEqual(udpWire.getTargetAddress(), expectedEndpoint)
    XCTAssertEqual(tcpWire.getTimeout(), 1_250)
    XCTAssertEqual(udpWire.getTimeout(), 1_250)

    let packet = try udpWire.encodeOutbound(Data([0x12, 0x34]), address: target)
    let decoded = try ShadowsocksUDPWire(proxyNode: replacement).decodeInbound(packet)
    XCTAssertEqual(decoded.data, Data([0x12, 0x34]))
    XCTAssertEqual(decoded.address, try NetworkAddress(host: "target.example", port: 53))
  }

  func testDomainRulesUseOrderBeforeSpecificity() throws {
    let suffixNode = try makeRoutingNode(host: "192.0.2.20")
    let exactNode = try makeRoutingNode(host: "192.0.2.21")
    let core = try makeRoutingCore(
      rules: [
        try ProxyRule(
          matchType: .exactDomain,
          matchValue: "api.example.com",
          decision: .proxy(exactNode.id),
          order: 10
        ),
        try ProxyRule(
          matchType: .domainSuffix,
          matchValue: "example.com",
          decision: .proxy(suffixNode.id),
          order: 0
        ),
      ],
      nodes: [suffixNode, exactNode]
    )

    let wire = try XCTUnwrap(core.routeTCPWire(NetworkAddress(host: "API.EXAMPLE.COM", port: 443)))

    XCTAssertEqual(wire.getTargetAddress(), suffixNode.address)
  }

  func testDomainRulesUseSpecificityWhenOrderMatches() throws {
    let suffixNode = try makeRoutingNode(host: "192.0.2.20")
    let exactNode = try makeRoutingNode(host: "192.0.2.21")
    let core = try makeRoutingCore(
      rules: [
        try ProxyRule(
          matchType: .domainSuffix,
          matchValue: "example.com",
          decision: .proxy(suffixNode.id),
          order: 0
        ),
        try ProxyRule(
          matchType: .exactDomain,
          matchValue: "api.example.com",
          decision: .proxy(exactNode.id),
          order: 0
        ),
      ],
      nodes: [suffixNode, exactNode]
    )

    XCTAssertEqual(
      try core.routeTCPWire(NetworkAddress(host: "api.example.com", port: 443))?.getTargetAddress(),
      exactNode.address
    )
    XCTAssertEqual(
      try core.routeTCPWire(NetworkAddress(host: "www.example.com", port: 443))?.getTargetAddress(),
      suffixNode.address
    )
    XCTAssertNil(try core.routeTCPWire(NetworkAddress(host: "example.org", port: 443)))
  }

  func testDuplicateNormalizedRuleUsesLastValue() throws {
    let firstNode = try makeRoutingNode(host: "192.0.2.22")
    let lastNode = try makeRoutingNode(host: "192.0.2.23")
    let core = try makeRoutingCore(
      rules: [
        try ProxyRule(
          matchType: .exactDomain,
          matchValue: "example.com",
          decision: .proxy(firstNode.id),
          order: 0
        ),
        try ProxyRule(
          matchType: .exactDomain,
          matchValue: "EXAMPLE.COM.",
          decision: .proxy(lastNode.id),
          order: 0
        ),
      ],
      nodes: [firstNode, lastNode]
    )

    XCTAssertEqual(
      try core.routeTCPWire(NetworkAddress(host: "example.com", port: 80))?.getTargetAddress(),
      lastNode.address
    )
  }

  func testCIDRMatchesIPv4AndIPv6() throws {
    let ipv4Node = try makeRoutingNode(host: "192.0.2.24")
    let ipv6Node = try makeRoutingNode(host: "192.0.2.25")
    let core = try makeRoutingCore(
      rules: [
        try ProxyRule(
          matchType: .ipCIDR,
          matchValue: "10.0.0.0/8",
          decision: .proxy(ipv4Node.id),
          order: 0
        ),
        try ProxyRule(
          matchType: .ipCIDR,
          matchValue: "2001:db8::/32",
          decision: .proxy(ipv6Node.id),
          order: 0
        ),
      ],
      nodes: [ipv4Node, ipv6Node]
    )

    XCTAssertEqual(
      try core.routeTCPWire(NetworkAddress(host: "10.20.30.40", port: 53))?.getTargetAddress(),
      ipv4Node.address
    )
    XCTAssertNil(try core.routeTCPWire(NetworkAddress(host: "11.20.30.40", port: 53)))
    XCTAssertEqual(
      try core.routeTCPWire(
        NetworkAddress(host: "2001:db8::", port: 443)
      )?.getTargetAddress(),
      ipv6Node.address
    )
  }

  /// PR-03/04/05：通过真实 TCP/UDP 路由验证域名边界，不解析数值目标的名称。
  func testRuleDomainAndKeywordMatchBoundaries() throws {
    let node = try makeRoutingNode(host: "192.0.2.30")
    let cases: [(MatchType, String, [String], [String])] = [
      (
        .exactDomain, "example.com", ["example.com", "EXAMPLE.COM."],
        ["api.example.com", "192.0.2.1"]
      ),
      (
        .domainSuffix, "example.com", ["example.com", "API.EXAMPLE.COM.", "a.b.example.com"],
        ["notexample.com", "example.com.evil", "192.0.2.1"]
      ),
      (.domainSuffix, "0.1", ["a.0.1", "b.a.0.1"], ["192.168.0.1", "::ffff:192.168.0.1"]),
      (
        .domainKeyword, "api", ["api.example.com", "myapiv2.example.com"],
        ["ap.example.com", "192.0.2.1"]
      ),
      (.domainKeyword, "api.", ["api.example.com"], ["myapiv2.example.com", "192.0.2.1"]),
      (.domainKeyword, "192", ["host192.example"], ["192.0.2.1", "::ffff:192.0.2.1"]),
    ]
    for (type, text, matches, misses) in cases {
      let core = try makeRoutingCore(
        rules: [
          ProxyRule(matchType: type, matchValue: text, decision: .proxy(node.id), order: 0)
        ], nodes: [node])
      for host in matches { try assertRoute(core, host: host, expectedProxy: "192.0.2.30") }
      for host in misses { try assertRoute(core, host: host, expectedProxy: nil) }
    }
  }

  /// PR-10：覆盖后不能继续用首次位置决胜，也不能保留首次的优先级或动作。
  func testDuplicateRuleUsesLastDecisionOrderAndPosition() throws {
    let first = try makeRoutingNode(host: "192.0.2.31")
    let middle = try makeRoutingNode(host: "192.0.2.32")
    let core = try makeRoutingCore(
      rules: [
        ProxyRule(
          matchType: .domainKeyword, matchValue: "api", decision: .proxy(first.id), order: Int.min),
        ProxyRule(
          matchType: .domainKeyword, matchValue: "com", decision: .proxy(middle.id), order: 0),
        ProxyRule(matchType: .domainKeyword, matchValue: "API", decision: .direct, order: 0),
      ], nodes: [first, middle])
    try assertRoute(core, host: "api.example.com", expectedProxy: "192.0.2.32")
    try assertRoute(core, host: "api.example.org", expectedProxy: nil)
  }

  /// PR-09：原生 IPv4 与映射 IPv6 的规范化 Match 是同一覆盖键。
  func testEquivalentCIDRUsesLastConfiguration() throws {
    let node = try makeRoutingNode(host: "192.0.2.33")
    let core = try makeRoutingCore(
      rules: [
        ProxyRule(
          matchType: .ipCIDR, matchValue: "192.0.2.129/24", decision: .proxy(node.id),
          order: Int.min),
        ProxyRule(
          matchType: .ipCIDR, matchValue: "::ffff:c000:200/120", decision: .direct, order: Int.max),
      ], nodes: [node])
    try assertRoute(core, host: "192.0.2.129", expectedProxy: nil)
    try assertRoute(core, host: "::ffff:192.0.2.129", expectedProxy: nil)
  }

  /// PR-11/13：任何类型的低 order 均优先，使用完整 Int 范围且不做减法比较。
  func testOrderPrecedesEveryDomainSpecificity() throws {
    let node = try makeRoutingNode(host: "192.0.2.34")
    let matches: [(MatchType, String)] = [
      (.exactDomain, "api.example.com"), (.domainSuffix, "example.com"), (.domainKeyword, "api"),
    ]
    for (winnerType, winnerText) in matches {
      for (loserType, loserText) in matches where loserType != winnerType {
        let rules = try [
          ProxyRule(
            matchType: winnerType, matchValue: winnerText, decision: .proxy(node.id), order: Int.min
          ),
          ProxyRule(matchType: loserType, matchValue: loserText, decision: .direct, order: Int.max),
        ]
        for input in [rules, Array(rules.reversed())] {
          let core = try makeRoutingCore(rules: input, nodes: [node])
          try assertRoute(core, host: "api.example.com", expectedProxy: "192.0.2.34")
        }
      }
    }
  }

  /// IP 规则同样先比较 order，更小的 order 可以覆盖更长的前缀。
  func testCIDROrderPrecedesPrefixLength() throws {
    let node = try makeRoutingNode(host: "192.0.2.39")
    for (broad, specific, host) in [
      ("192.0.2.0/24", "192.0.2.129/32", "192.0.2.129"),
      ("2001:db8::/32", "2001:db8::1/128", "2001:db8::1"),
    ] {
      let rules = try [
        ProxyRule(matchType: .ipCIDR, matchValue: specific, decision: .direct, order: Int.max),
        ProxyRule(matchType: .ipCIDR, matchValue: broad, decision: .proxy(node.id), order: Int.min),
      ]
      for input in [rules, Array(rules.reversed())] {
        let core = try makeRoutingCore(rules: input, nodes: [node])
        try assertRoute(core, host: host, expectedProxy: "192.0.2.39")
      }
    }
  }

  /// PR-12：同 order 下显式比较类型、后缀标签数、关键字字节数与 CIDR 前缀。
  func testSpecificityComparisonIsIndependentOfInputOrder() throws {
    let node = try makeRoutingNode(host: "192.0.2.35")
    let cases: [(MatchType, String, MatchType, String, String)] = [
      (.exactDomain, "api.example.com", .domainSuffix, "example.com", "api.example.com"),
      (.exactDomain, "api.example.com", .domainKeyword, "api.example.com", "api.example.com"),
      (.domainSuffix, "example.com", .domainKeyword, "api.example.com", "api.example.com"),
      (.domainSuffix, "api.example.com", .domainSuffix, "example.com", "x.api.example.com"),
      (.domainKeyword, "api.", .domainKeyword, "api", "api.example.com"),
      (.ipCIDR, "192.0.2.128/25", .ipCIDR, "192.0.2.0/24", "192.0.2.129"),
      (.ipCIDR, "2001:db8:8000::/33", .ipCIDR, "2001:db8::/32", "2001:db8:abcd::1"),
    ]
    for (winnerType, winnerText, loserType, loserText, host) in cases {
      let rules = try [
        ProxyRule(
          matchType: winnerType, matchValue: winnerText, decision: .proxy(node.id), order: 0),
        ProxyRule(matchType: loserType, matchValue: loserText, decision: .direct, order: 0),
      ]
      for input in [rules, Array(rules.reversed())] {
        let core = try makeRoutingCore(rules: input, nodes: [node])
        try assertRoute(core, host: host, expectedProxy: "192.0.2.35")
      }
    }
  }

  /// PR-13：相同优先级和具体性的不同关键字按保留输入位置决胜，不依赖字典顺序。
  func testEqualSpecificityUsesEarlierRetainedPosition() throws {
    let node = try makeRoutingNode(host: "192.0.2.36")
    let rules = try [
      ProxyRule(matchType: .domainKeyword, matchValue: "api", decision: .proxy(node.id), order: -1),
      ProxyRule(matchType: .domainKeyword, matchValue: "com", decision: .direct, order: -1),
    ]
    try assertRoute(
      makeRoutingCore(rules: rules, nodes: [node]), host: "api.example.com",
      expectedProxy: "192.0.2.36")
    try assertRoute(
      makeRoutingCore(rules: Array(rules.reversed()), nodes: [node]), host: "api.example.com",
      expectedProxy: nil)
  }

  /// PR-06/08/15/17：读取模型网络字节比较非整字节边界，并隔离归一后的 IP 族。
  func testCIDRPartialByteHostAndFamilyBoundaries() throws {
    let node = try makeRoutingNode(host: "192.0.2.37")
    let cases: [(String, [String], [String])] = [
      (
        "192.0.2.129/25", ["192.0.2.128", "192.0.2.255", "::ffff:c000:2ff"],
        ["192.0.2.127", "192.0.3.0", "2001:db8::1"]
      ),
      ("192.0.2.129", ["192.0.2.129", "::ffff:192.0.2.129"], ["192.0.2.128", "192.0.2.130"]),
      (
        "2001:db8:ffff::/33", ["2001:db8:8000::", "2001:db8:ffff:ffff:ffff:ffff:ffff:ffff"],
        ["2001:db8:7fff::", "2001:db9::", "192.0.2.1"]
      ),
      ("2001:db8::1", ["2001:db8::1"], ["2001:db8::", "2001:db8::2"]),
      (
        "::/0", ["::", "2001:db8::1", "::192.0.2.1"],
        ["192.0.2.1", "::ffff:192.0.2.1", "example.invalid"]
      ),
      (
        "::ffff:192.0.2.1/96", ["0.0.0.0", "255.255.255.255", "::ffff:192.0.2.1"],
        ["::", "2001:db8::1", "example.invalid"]
      ),
    ]
    for (text, matches, misses) in cases {
      let core = try makeRoutingCore(
        rules: [
          ProxyRule(matchType: .ipCIDR, matchValue: text, decision: .proxy(node.id), order: 0)
        ], nodes: [node])
      for host in matches { try assertRoute(core, host: host, expectedProxy: "192.0.2.37") }
      for host in misses { try assertRoute(core, host: host, expectedProxy: nil) }
    }
  }

  /// PR-15：端口、单根点及映射表示共享路由语义，匹配不修改原域名的根点。
  func testRoutingCachePreservesNormalizedHostSemanticsAcrossPorts() throws {
    let node = try makeRoutingNode(host: "192.0.2.38")
    let core = try makeRoutingCore(
      rules: [
        ProxyRule(
          matchType: .exactDomain, matchValue: "EXAMPLE.COM.", decision: .proxy(node.id), order: 0),
        ProxyRule(
          matchType: .ipCIDR, matchValue: "192.0.2.0/24", decision: .proxy(node.id), order: 0),
        ProxyRule(matchType: .ipCIDR, matchValue: "::/0", decision: .direct, order: 0),
      ], nodes: [node])
    let target = try NetworkAddress(host: "EXAMPLE.COM.", port: 443)
    XCTAssertEqual(
      try core.routeTCPWire(target)?.getTargetAddress(),
      try SocketAddress(ipAddress: "192.0.2.38", port: 8388))
    XCTAssertEqual(target.host, "example.com.")
    for port: UInt16 in [0, 53, 80, 443, 65535] {
      for host in ["example.com", "EXAMPLE.COM.", "192.0.2.129", "::ffff:c000:281"] {
        try assertRoute(core, host: host, port: port, expectedProxy: "192.0.2.38")
      }
      try assertRoute(core, host: "2001:db8::1", port: port, expectedProxy: nil)
    }
  }

  /// PR-14/16：零 UUID 仍是普通代理引用；命中及缓存命中均抛出原始缺节点错误。
  func testMissingRuleNodeNeverFallsBackAfterCacheHit() throws {
    let zeroID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    let core = try makeCore(rules: [
      ProxyRule(
        matchType: .exactDomain, matchValue: "missing.invalid", decision: .proxy(zeroID), order: 0)
    ])
    for host in ["missing.invalid", "MISSING.INVALID."] {
      let target = try NetworkAddress(host: host, port: 443)
      XCTAssertThrowsError(try core.routeTCPWire(target)) { error in
        XCTAssertEqual(error as? MagentError, .proxyNodeNotFound(zeroID))
      }
      XCTAssertThrowsError(try core.routeUDPWire(target)) { error in
        XCTAssertEqual(error as? MagentError, .proxyNodeNotFound(zeroID))
      }
    }
    try assertRoute(core, host: "unmatched.invalid", expectedProxy: nil)
  }

  /// 路由断言同时经过 TCP/UDP 的真实 Core 入口，期望端点使用用例的字面量。
  private func assertRoute(
    _ core: MagentCore, host: String, port: UInt16 = 443, expectedProxy: String?,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let target = try NetworkAddress(host: host, port: port)
    let expected = try expectedProxy.map { try SocketAddress(ipAddress: $0, port: 8388) }
    XCTAssertEqual(
      try core.routeTCPWire(target)?.getTargetAddress(), expected, host, file: file, line: line)
    XCTAssertEqual(
      try core.routeUDPWire(target)?.getTargetAddress(), expected, host, file: file, line: line)
  }

  /// TCP client Future 必须能在创建它的 EventLoop 上完成，不能由 handler 同步等待。
  func testTCPClientChannelCompletesOnSingleEventLoop() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = try ServerBootstrap(group: group)
      .childChannelInitializer { channel in
        channel.pipeline.addHandler(TestInboundHandler())
      }
      .bind(host: "127.0.0.1", port: 0)
      .wait()
    defer {
      try? server.close().wait()
      try? group.syncShutdownGracefully()
    }

    let port = try XCTUnwrap(server.localAddress?.port)
    let target = try NetworkAddress(host: "127.0.0.1", port: UInt16(port))
    let loop = group.next()
    let promise = loop.makePromise(of: Channel.self)
    let core = try MagentCore(
      defaultDecision: .direct,
      proxyNodes: [],
      defaultTimeout: 10_000,
      rules: []
    )
    loop.execute {
      core.createTCPClientChannel(
        group: loop,
        address: target,
        timeout: 1_000,
        handler: TestInboundHandler()
      )
      .cascade(to: promise)
    }

    let client = try promise.futureResult.wait()
    XCTAssertTrue(client.isActive)
    XCTAssertFalse(try client.getOption(ChannelOptions.autoRead).wait())
    XCTAssertEqual(try client.getOption(ChannelOptions.maxMessagesPerRead).wait(), 1)
    try client.close().wait()
  }

  /// 无效建连超时必须在创建下游 Channel 前被拒绝。
  func testTCPClientChannelRejectsNonPositiveTimeout() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    defer { XCTAssertNoThrow(try group.syncShutdownGracefully()) }
    let core = try MagentCore(
      defaultDecision: .direct,
      proxyNodes: [],
      defaultTimeout: 10_000,
      rules: []
    )

    let future = core.createTCPClientChannel(
      group: group,
      address: try NetworkAddress(host: "127.0.0.1", port: 1),
      timeout: 0,
      handler: TestInboundHandler()
    )

    XCTAssertThrowsError(try future.wait()) { error in
      XCTAssertEqual(
        error as? MagentError,
        .invalidOptions("TCP connection timeout must be greater than zero")
      )
    }
  }

  /// UDP bind Future 必须能在创建它的 EventLoop 上完成，不能由 datagram handler 同步等待。
  func testUDPClientChannelBindCompletesOnSingleEventLoop() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let loop = group.next()
    let promise = loop.makePromise(of: Channel.self)
    loop.execute {
      DatagramBootstrap(group: loop)
        .channelInitializer { channel in channel.pipeline.addHandler(TestInboundHandler()) }
        .bind(host: "0.0.0.0", port: 0)
        .cascade(to: promise)
    }

    let channel = try promise.futureResult.wait()
    defer {
      try? channel.close().wait()
      try? group.syncShutdownGracefully()
    }
    XCTAssertTrue(channel.isActive)
  }
}

/// 创建无预置节点的直连 Core，供路由和节点注册测试使用。
private func makeCore(rules: [ProxyRule] = []) throws -> MagentCore {
  try MagentCore(
    defaultDecision: .direct,
    proxyNodes: [],
    defaultTimeout: 10_000,
    rules: rules
  )
}

private func makeProxyNode(id: UUID, host: String) throws -> ProxyNode {
  try ProxyNode(
    id: id,
    address: try SocketAddress(ipAddress: host, port: 8388),
    cipher: .aes128Gcm,
    password: "test-password"
  )
}

/// 使用真实节点列表与规则创建路由测试的 Core。
private func makeRoutingCore(rules: [ProxyRule], nodes: [ProxyNode]) throws -> MagentCore {
  try MagentCore(
    defaultDecision: .direct,
    proxyNodes: nodes,
    defaultTimeout: 10_000,
    rules: rules
  )
}

private func makeRoutingNode(host: String) throws -> ProxyNode {
  try ProxyNode(
    address: try SocketAddress(ipAddress: host, port: 8388),
    cipher: .aes128Gcm,
    password: "test-password"
  )
}
