// Socks5ConnectionTests.swift
//
// 覆盖 SOCKS5 方法协商、请求与地址解析、路由、TCP 隧道和背压/半关闭、
// UDP 关联、数据报转发、来源校验及资源清理。测试按业务场景统一排列，
// 使用真实 Core/handler、EmbeddedChannel 和本机 TCP/UDP 节点。
//
// 对照 docs/SOCKS5_PROXY_SPEC.md 的目标断言与现有行为回归共同维护。
// 严格 XCTExpectFailure 标记已知规格差异，修复后应保留断言并移除标记；
// 对严格握手顺序、畸形 UDP 关闭关联、远端 DNS 等现有行为的回归通过，
// 不代表对应 spec 要求已满足。环境受限的测试明确报告跳过原因。
//
// 以下验收要求尚缺生产能力或完整验证入口，不使用占位测试标记为通过或跳过：
// P02/P03/P08：可配置认证、SOCKS5 上游回复解析；
// P10（关闭 UDP）、R（端口/传输/REJECT）、D03（Resolver 调用计数）、D04..D07；
// O01..O05/O09/O10、U13..U15/U18..U21：SOCKS5 上游、TLS、逐流预算与队列；
// L04/L06..L08、C01/C03..C08、S02/S03/S06/S07：资源预算、解析/时钟可控验证、
// 配置 schema、目标保护、遥测及优雅重载/关闭。

import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest

@testable import Magent

/// SOCKS5 协议、传输与生命周期的完整测试集合。
final class Socks5ConnectionTests: XCTestCase {

  // MARK: - 方法协商与请求解析

  func testMagentTCPConnectionAcceptsFragmentedSOCKS5Greeting() throws {
    let channel = try makeConnectionChannel()
    defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }

    try writeInbound(Data([0x05]), to: channel)
    XCTAssertNil(try readOutboundData(from: channel))

    try writeInbound(Data([0x01, 0x00]), to: channel)
    XCTAssertEqual(try readOutboundData(from: channel), Data([0x05, 0x00]))
  }

  /// P01/P05/P11, §25: every split, byte-at-a-time and deterministic mixed segmentation.
  func testSpecGreetingSegmentationAndMethodSelection() throws {
    let greetings: [Data] = [
      Data([5, 1, 0]), Data([5, 2, 0, 2]), Data([5, 3, 0x80, 2, 0]),
      Data([5, 255]) + Data(repeating: 0x80, count: 254) + Data([0]),
    ]
    for greeting in greetings {
      for chunks in specSegmentations(greeting) {
        let channel = try makeConnectionChannel()
        defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
        for chunk in chunks.dropLast() {
          try writeInbound(chunk, to: channel)
          XCTAssertNil(try readOutboundData(from: channel))
        }
        try writeInbound(try XCTUnwrap(chunks.last), to: channel)
        XCTAssertEqual(try readOutboundData(from: channel), Data([5, 0]))
        XCTAssertNil(try readOutboundData(from: channel))
      }
    }
  }

  func testMagentTCPConnectionRejectsSOCKS5GreetingWithoutNoAuth() throws {
    let channel = try makeConnectionChannel()
    defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }

    try writeInbound(Data([0x05, 0x01, 0x02]), to: channel)
    XCTAssertEqual(try readOutboundData(from: channel), Data([0x05, 0xFF]))
    XCTAssertFalse(channel.isActive)
  }

  func testSpecRejectsEmptyAndUnsupportedMethodLists() throws {
    for greeting in [Data([5, 0]), Data([5, 1, 1]), Data([5, 2, 2, 0x80])] {
      let channel = try makeConnectionChannel()
      defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
      try writeInbound(greeting, to: channel)
      XCTAssertEqual(try readOutboundData(from: channel), Data([5, 255]))
      XCTAssertNil(try readOutboundData(from: channel))
      XCTAssertFalse(channel.isActive)
    }
  }

  func testMagentTCPConnectionRejectsSOCKS5BindCommand() throws {
    let channel = try makeConnectionChannel()
    defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
    try writeInbound(Data([0x05, 0x01, 0x00]), to: channel)
    XCTAssertEqual(try readOutboundData(from: channel), Data([0x05, 0x00]))

    let bind = Data([0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1, 0x01, 0xBB])
    try writeInbound(bind, to: channel)
    let response = try XCTUnwrap(readOutboundData(from: channel))

    XCTAssertEqual(response.prefix(2), Data([0x05, 0x07]))
    XCTAssertFalse(channel.isActive)
  }

  /// P09/P10: failure frames include RSV, IPv4 wildcard and zero port, not just REP.
  func testSpecInvalidRequestHeadersAndUnsupportedCommands() throws {
    var requests: [(Data, UInt8)] = [
      (Data([5, 1, 1, 1, 192, 0, 2, 1, 1, 187]), 1),
      (Data([5, 1, 0, 2]), 8),
    ]
    for command in UInt8.min...UInt8.max where command != 1 && command != 3 {
      requests.append((Data([5, command, 0, 1, 192, 0, 2, 1, 1, 187]), 7))
    }
    for (request, rep) in requests {
      let channel = try specNegotiatedChannel()
      defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
      try writeInbound(request, to: channel)
      XCTAssertEqual(try readOutboundData(from: channel), specFailure(rep), "\(request as NSData)")
      XCTAssertFalse(channel.isActive)
      XCTAssertNil(try readOutboundData(from: channel))
    }
  }

  /// §18.2 requires closing an invalid request version without a SOCKS failure frame.
  func testSpecInvalidRequestVersionClosesWithoutReply() throws {
    let channel = try specNegotiatedChannel()
    defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
    try writeInbound(Data([4, 1, 0, 1, 192, 0, 2, 1, 1, 187]), to: channel)
    let response = try readOutboundData(from: channel)
    XCTExpectFailure("§18.2: invalid request version currently emits REP=01") {
      XCTAssertNil(response)
    }
    XCTAssertFalse(channel.isActive)
  }

  func testSpecZeroConnectPortUsesGeneralFailure() throws {
    for address in [
      Data([1, 192, 0, 2, 1, 0, 0]),
      Data([3, 1, 97, 0, 0]),
      Data([4]) + Data(repeating: 0, count: 15) + Data([1, 0, 0]),
    ] {
      let channel = try specNegotiatedChannel()
      defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
      try writeInbound(Data([5, 1, 0]) + address, to: channel)
      let response = try readOutboundData(from: channel)
      XCTExpectFailure("§18.2: zero business port currently maps to REP=08 instead of 01") {
        XCTAssertEqual(response, specFailure(1))
      }
      XCTAssertFalse(channel.isActive)
    }
  }

  /// §6.5: each incomplete greeting/request prefix terminates on EOF without dialing.
  func testSpecIncompleteHandshakeEOFAtEveryOffset() throws {
    let greeting = Data([5, 3, 0x80, 2, 0])
    let requests: [Data] = [
      Data([5, 1, 0, 1, 192, 168, 2, 10, 31, 144]),
      Data([5, 1, 0, 3, 11]) + Data("example.com".utf8) + Data([1, 187]),
      Data([5, 1, 0, 4, 32, 1, 13, 184]) + Data(repeating: 0, count: 11)
        + Data([1, 1, 187]),
    ]
    for (index, message) in ([greeting] + requests).enumerated() {
      for offset in 1..<message.count {
        let channel = try index == 0 ? makeConnectionChannel() : specNegotiatedChannel()
        defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
        try writeInbound(Data(message.prefix(offset)), to: channel)
        XCTAssertNil(try readOutboundData(from: channel))
        channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        XCTAssertFalse(channel.isActive, "message \(index), prefix \(offset)")
        XCTAssertNil(try readOutboundData(from: channel))
      }
    }
  }

  /// §19.1: advancing virtual time avoids spending ten real seconds on a slowloris test.
  func testSpecHandshakeDeadlineIsAbsolute() throws {
    let channel = try makeConnectionChannel()
    defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
    try writeInbound(Data([5]), to: channel)
    channel.embeddedEventLoop.advanceTime(by: .seconds(9))
    XCTAssertTrue(channel.isActive)
    try writeInbound(Data([2]), to: channel)
    channel.embeddedEventLoop.advanceTime(by: .seconds(2))
    XCTExpectFailure("§19.1: there is no absolute inbound handshake deadline") {
      XCTAssertFalse(channel.isActive)
    }
  }

  /// §6.1/6.4: only the current message is consumed; method selection remains first.
  func testSpecCoalescedGreetingAndRequestPreservesReplyOrder() throws {
    let channel = try makeConnectionChannel()
    defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
    try writeInbound(Data([5, 1, 0, 5, 2, 0, 1, 192, 0, 2, 1, 1, 187]), to: channel)
    let first = try readOutboundData(from: channel)
    let second = try readOutboundData(from: channel)
    XCTExpectFailure("P06: strict greeting length rejects the following request") {
      XCTAssertEqual((first ?? Data()) + (second ?? Data()), Data([5, 0]) + specFailure(7))
    }
  }

  func testSpecEarlyDataWaitsForSuccessAndPreservesBytes() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let core = try harness.proxyCore()
    let capture = SpecTCPBytes(eventLoop: harness.group.next())
    let client = try harness.connect(core: core, capture: capture)
    let accepted = try specWait(harness.accepted.next())
    let request = Data([5, 1, 0, 3, 11]) + Data("example.com".utf8) + Data([1, 187])
    let payload = Data([5, 0, 255, 0, 104, 101, 108, 108, 111])
    try specWait(
      accepted.eventLoop.submit {
        var input = accepted.allocator.buffer(capacity: request.count + payload.count)
        input.writeBytes(request + payload)
        accepted.pipeline.fireChannelRead(input)
      })
    let response = try specWait(capture.atLeast(12))
    XCTExpectFailure("P07: request+earlyData is rejected before any outbound is created") {
      XCTAssertEqual(Data(response.dropFirst(2).prefix(3)), Data([5, 0, 0]))
    }
    // When the implementation supports early data, this also verifies all plaintext in order.
    if response[3] == 0 {
      let expected = Data(request.dropFirst(3)) + payload
      var received = Data()
      while received.count < expected.count {
        received.append(try specWait(harness.proxyPlaintext.next()))
      }
      XCTAssertEqual(received, expected)
    }
    try? specWait(client.close())
  }

  // MARK: - 地址解析与规范化

  /// P04/P05/P11: real CONNECT parsing, captured after decryption at a local test node.
  /// This proves byte boundaries and address preservation; the node is Shadowsocks, not SOCKS5.
  func testSpecConnectAddressVectorsAtEverySplit() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let core = try harness.proxyCore()
    let domain253 = [63, 63, 63, 61].map { String(repeating: "a", count: $0) }.joined(
      separator: ".")
    let domain254 = domain253 + "."
    let addresses: [Data] = [
      Data([1, 192, 168, 2, 10, 31, 144]),
      Data([3, 11]) + Data("example.com".utf8) + Data([1, 187]),
      Data([4, 32, 1, 13, 184]) + Data(repeating: 0, count: 11) + Data([1, 1, 187]),
      Data([3, 1, 97, 0, 1]),
      Data([3, 253]) + Data(domain253.utf8) + Data([255, 255]),
      Data([3, 254]) + Data(domain254.utf8) + Data([0, 53]),
    ]
    // Fragment delivery is injected at the accepted pipeline, so TCP coalescing cannot erase splits.
    for address in addresses {
      let request = Data([5, 1, 0]) + address
      for chunks in specSegmentations(request) {
        let capture = SpecTCPBytes(eventLoop: harness.group.next())
        let client = try harness.connect(core: core, capture: capture)
        let accepted = try specWait(harness.accepted.next())
        for chunk in chunks.dropLast() {
          try specWait(
            accepted.eventLoop.submit {
              var buffer = accepted.allocator.buffer(capacity: chunk.count)
              buffer.writeBytes(chunk)
              accepted.pipeline.fireChannelRead(buffer)
            })
          XCTAssertEqual(try specWait(capture.snapshot()), Data([5, 0]))
        }
        let last = try XCTUnwrap(chunks.last)
        try specWait(
          accepted.eventLoop.submit {
            var buffer = accepted.allocator.buffer(capacity: last.count)
            buffer.writeBytes(last)
            accepted.pipeline.fireChannelRead(buffer)
          })
        let response = try specWait(capture.atLeast(12))
        XCTAssertEqual(response.prefix(6), Data([5, 0, 5, 0, 0, 1]))
        XCTAssertEqual(try specWait(harness.proxyPlaintext.next()), address)
        try? specWait(client.close())
      }
    }
  }

  /// §7/§25.2: invalid UTF-8, NUL, label/total lengths and disguised numeric hosts.
  func testSpecRejectsInvalidDomainExpressionsBeforeOpeningProxy() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let core = try harness.proxyCore()
    let domain255 = [63, 63, 63, 63].map { String(repeating: "a", count: $0) }.joined(
      separator: ".")
    let names: [Data] = [
      Data("a\0b".utf8), Data("你好.example".utf8),
      Data("a..b".utf8), Data("example.com..".utf8), Data("-a.test".utf8),
      Data("a-.test".utf8), Data("a_b.test".utf8), Data("a b.test".utf8),
      Data("a/b".utf8), Data("a\\b".utf8), Data("a@b".utf8), Data("[::1]".utf8),
      Data("::1".utf8), Data("fe80::1%en0".utf8), Data("a\nb".utf8),
      Data("2130706433".utf8), Data("0x7f000001".utf8), Data("127.1".utf8),
      Data("127.000.0.1".utf8), Data("0X7F.0.0.1".utf8), Data("192.0.2.1.".utf8),
      Data("256.0.0.1".utf8), Data(".example.com".utf8), Data(" example.com".utf8),
      Data(String(repeating: "a", count: 64).utf8),
      Data(domain255.utf8), Data(domain255.dropLast().utf8),
    ]
    for name in names {
      let capture = SpecTCPBytes(eventLoop: harness.group.next())
      let client = try harness.connect(core: core, capture: capture)
      _ = try specWait(harness.accepted.next())
      try writeData(Data([5, 1, 0, 3, UInt8(name.count)]) + name + Data([1, 187]), to: client)
      let response = try specWait(capture.atLeast(12))
      XCTAssertEqual(Data(response.dropFirst(2)), specFailure(8), "\(name as NSData)")
      // Wait for close, then verify that no target bytes reached the proxy.
      try specWait(client.closeFuture)
      XCTAssertEqual(try specWait(harness.proxyPlaintext.count()), 0)
      try? specWait(client.close())
    }
  }

  /// C08/C12 尚未修复的编码错误回复；保留原审查断言的严格预期失败。
  func testSpecInvalidDomainEncodingUsesAddressFailure() throws {
    for name in [Data(), Data([0xFF])] {
      let channel = try specNegotiatedChannel()
      defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
      try writeInbound(Data([5, 1, 0, 3, UInt8(name.count)]) + name + Data([1, 187]), to: channel)
      let response = try readOutboundData(from: channel)
      XCTExpectFailure("§7.3/18.2: empty or invalid UTF-8 still maps to REP=01 instead of 08") {
        XCTAssertEqual(response, specFailure(8))
      }
      XCTAssertFalse(channel.isActive)
    }
  }

  func testSpecNormalizesDomainForwardingAndNumericAddresses() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let core = try harness.proxyCore()
    let vectors: [(Data, Data)] = [
      (
        Data([3, 16]) + Data("API.Example.COM.".utf8) + Data([1, 187]),
        Data([3, 16]) + Data("api.example.com.".utf8) + Data([1, 187])
      ),
      (
        Data([3, 9]) + Data("192.0.2.1".utf8) + Data([1, 187]),
        Data([1, 192, 0, 2, 1, 1, 187])
      ),
      (
        Data([4]) + Data(repeating: 0, count: 10) + Data([255, 255, 192, 0, 2, 1, 1, 187]),
        Data([1, 192, 0, 2, 1, 1, 187])
      ),
    ]
    for (address, expected) in vectors {
      let capture = SpecTCPBytes(eventLoop: harness.group.next())
      let client = try harness.connect(core: core, capture: capture)
      _ = try specWait(harness.accepted.next())
      try writeData(Data([5, 1, 0]) + address, to: client)
      _ = try specWait(capture.atLeast(12))
      let forwarded = try specWait(harness.proxyPlaintext.next())
      XCTAssertEqual(forwarded, expected)
      try? specWait(client.close())
    }
  }

  // MARK: - 路由与目标策略

  /// C02: rule references must be validated at construction, not fail at first request.
  func testSpecConfigurationRejectsMissingRuleNode() throws {
    let missing = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let rule = try ProxyRule(
      matchType: .exactDomain, matchValue: "example.com", decision: .proxy(missing), order: 0)
    try XCTExpectFailure(
      "C02: MagentCore validates only the default node, not nodes referenced by rules"
    ) {
      XCTAssertThrowsError(
        try MagentCore(
          defaultDecision: .direct, proxyNodes: [], defaultTimeout: 1000, rules: [rule]))
    }
  }

  /// §8.3/R06: same-priority specificity and duplicate replacement must not beat array order.
  func testSpecRoutingUsesFirstConfiguredMatch() throws {
    let node = ProxyNode(
      address: try SocketAddress(ipAddress: "127.0.0.1", port: 11080),
      cipher: .aes256Gcm, password: "spec-test")
    let cases: [[ProxyRule]] = [
      [
        try ProxyRule(
          matchType: .domainSuffix, matchValue: "example.com", decision: .direct, order: 0),
        try ProxyRule(
          matchType: .exactDomain, matchValue: "api.example.com", decision: .proxy(node.id),
          order: 0),
      ],
      [
        try ProxyRule(
          matchType: .exactDomain, matchValue: "api.example.com", decision: .direct, order: 0),
        try ProxyRule(
          matchType: .exactDomain, matchValue: "api.example.com", decision: .proxy(node.id),
          order: 0),
      ],
      [
        try ProxyRule(
          matchType: .domainSuffix, matchValue: "example.com", decision: .direct, order: 10),
        try ProxyRule(
          matchType: .exactDomain, matchValue: "api.example.com", decision: .proxy(node.id),
          order: 0),
      ],
    ]
    for rules in cases {
      let core = try MagentCore(
        defaultDecision: .direct, proxyNodes: [node], defaultTimeout: 1000, rules: rules)
      let wire = try core.routeTCPWire(.domain("api.example.com", port: 443))
      XCTExpectFailure("R06: order/specificity/last duplicate override the SPEC's first match") {
        XCTAssertNil(wire)
      }
    }
  }

  func testSpecDomainSuffixBoundaryAndNumericTargetsDoNotGuessDomains() throws {
    let node = ProxyNode(
      address: try SocketAddress(ipAddress: "127.0.0.1", port: 11080),
      cipher: .aes256Gcm, password: "spec-test")
    let core = try MagentCore(
      defaultDecision: .direct, proxyNodes: [node], defaultTimeout: 1000,
      rules: [
        try ProxyRule(
          matchType: .domainSuffix, matchValue: "example.com", decision: .proxy(node.id), order: 0)
      ])
    for name in ["example.com", "a.example.com", "API.Example.COM."] {
      XCTAssertEqual(
        try core.routeTCPWire(.domain(name, port: 443))?.getTargetAddress(), node.address)
      XCTAssertEqual(
        try core.routeUDPWire(.domain(name, port: 53))?.getTargetAddress(), node.address)
    }
    for address in [
      NetworkAddress.domain("notexample.com", port: 443),
      .domain("example.com.evil", port: 443), .ipv4(Data([192, 0, 2, 1]), port: 443),
    ] {
      XCTAssertNil(try core.routeTCPWire(address))
      XCTAssertNil(try core.routeUDPWire(address))
    }
  }

  func testSpecMappedIPv6CannotBypassIPv4Rule() throws {
    let node = ProxyNode(
      address: try SocketAddress(ipAddress: "127.0.0.1", port: 11080),
      cipher: .aes256Gcm, password: "spec-test")
    let core = try MagentCore(
      defaultDecision: .direct, proxyNodes: [node], defaultTimeout: 1000,
      rules: [
        try ProxyRule(
          matchType: .ipCIDR, matchValue: "192.0.2.0/24", decision: .proxy(node.id), order: 0)
      ])
    let mapped = NetworkAddress.ipv6(
      Data(repeating: 0, count: 10) + Data([255, 255, 192, 0, 2, 1]), port: 443)
    for address in [
      mapped, .domain("192.0.2.1", port: 443), .ipv4(Data([192, 0, 2, 1]), port: 443),
    ] {
      XCTAssertEqual(try core.routeTCPWire(address)?.getTargetAddress(), node.address)
      XCTAssertEqual(try core.routeUDPWire(address)?.getTargetAddress(), node.address)
    }
  }

  /// S01: even a PROXY decision must not bypass numeric target safety checks.
  func testSpecForbiddenNumericTargetsAreRejectedBeforeProxyDial() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let core = try harness.proxyCore()
    let forbidden: [Data] = [
      Data([1, 0, 0, 0, 0]), Data([1, 127, 0, 0, 1]), Data([1, 169, 254, 1, 1]),
      Data([1, 224, 0, 0, 1]), Data([1, 240, 0, 0, 1]), Data([1, 255, 255, 255, 255]),
      Data([4]) + Data(repeating: 0, count: 16),
      Data([4]) + Data(repeating: 0, count: 15) + Data([1]),
      Data([4, 0xFE, 0x80]) + Data(repeating: 0, count: 13) + Data([1]),
      Data([4, 0xFF, 2]) + Data(repeating: 0, count: 13) + Data([1]),
    ]
    for address in forbidden {
      let capture = SpecTCPBytes(eventLoop: harness.group.next())
      let client = try harness.connect(core: core, capture: capture)
      _ = try specWait(harness.accepted.next())
      try writeData(Data([5, 1, 0]) + address + Data([1, 187]), to: client)
      let response = try specWait(capture.atLeast(12))
      XCTExpectFailure("S01/§21.2: there is no target safety guard before proxy routing") {
        XCTAssertEqual(Data(response.dropFirst(2)), specFailure(2))
      }
      try? specWait(client.close())
    }
  }

  /// O06: a broken selected proxy must fail, never send the business request directly.
  func testSpecMissingProxyDoesNotFallBackToDirect() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let directAttempts = SpecInbox<Channel>(eventLoop: harness.group.next())
    defer { try? directAttempts.finish().wait() }
    let target = try ServerBootstrap(group: harness.group).childChannelInitializer { channel in
      directAttempts.append(channel)
      return channel.eventLoop.makeSucceededFuture(())
    }.bind(host: "127.0.0.1", port: 0).wait()
    harness.channels.append(target)
    let missing = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let rule = try ProxyRule(
      matchType: .ipCIDR, matchValue: "127.0.0.1/32", decision: .proxy(missing), order: 0)
    let core = try MagentCore(
      defaultDecision: .direct, proxyNodes: [], defaultTimeout: 1000, rules: [rule])
    let capture = SpecTCPBytes(eventLoop: harness.group.next())
    let client = try harness.connect(core: core, capture: capture)
    _ = try specWait(harness.accepted.next())
    let port = try XCTUnwrap(target.localAddress?.port)
    try writeData(Data([5, 1, 0, 1, 127, 0, 0, 1]) + UInt16(port).bigEndianBytes, to: client)
    let response = try specWait(capture.atLeast(12))
    XCTExpectFailure("§18: a missing proxy is a general failure, not target network unreachable") {
      XCTAssertEqual(Data(response.dropFirst(2)), specFailure(1))
    }
    try harness.settleDatagrams()
    XCTAssertEqual(try specWait(directAttempts.count()), 0)
  }

  // MARK: - TCP 建连与转发

  /// SOCKS5 直连建立后只发送一次成功响应。
  func testMagentTCPConnectionEstablishesSOCKS5DirectConnectOnce() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let targetServer = try ServerBootstrap(group: group)
      .childChannelInitializer { channel in
        targetAcceptedPromise.succeed(channel)
        return channel.pipeline.addHandler(TestInboundHandler())
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
    let greetingPromise = client.eventLoop.makePromise(of: Data.self)
    let responsesPromise = client.eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12, promise: responsesPromise)
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(
      socks5ConnectRequest(.ipv4(Data([127, 0, 0, 1]), port: targetPort)),
      to: client
    )

    let responses = try responsesPromise.futureResult.wait()
    XCTAssertEqual(responses.prefix(2), testSocks5NoAuthentication)
    XCTAssertEqual(responses.dropFirst(2).prefix(2), Data([0x05, 0x00]))
    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    XCTAssertTrue(targetChannel.isActive)
  }

  /// 通过节点列表选中的 Shadowsocks Wire 建立 SOCKS5 隧道。
  func testMagentTCPConnectionWritesShadowsocksHandshakeAndEstablishesSOCKS5Connect() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let proxyNodeAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let cipher = ProxyCipher.aes256Gcm
    let host = "example.com"
    let shadowsocksAddressLength = 1 + 1 + host.utf8.count + 2
    let expectedHandshakeLength =
      cipher.saltSize
      + 2 + cipher.tagSize
      + shadowsocksAddressLength + cipher.tagSize
    let handshakePromise = eventLoop.makePromise(of: Data.self)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let shadowsocksServer = try ServerBootstrap(group: group)
      .childChannelInitializer { channel in
        proxyNodeAcceptedPromise.succeed(channel)
        return channel.pipeline.addHandler(
          TestDataCollector(expectedByteCount: expectedHandshakeLength, promise: handshakePromise)
        )
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
    let greetingPromise = client.eventLoop.makePromise(of: Data.self)
    let responsesPromise = client.eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12, promise: responsesPromise)
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    try writeData(socks5ConnectRequest(.domain(host, port: 443)), to: client)

    let responses = try responsesPromise.futureResult.wait()
    XCTAssertEqual(responses.prefix(2), testSocks5NoAuthentication)
    XCTAssertEqual(responses.dropFirst(2).prefix(2), Data([0x05, 0x00]))
    XCTAssertEqual(try handshakePromise.futureResult.wait().count, expectedHandshakeLength)
    channels.append(try proxyNodeAcceptedPromise.futureResult.wait())
  }

  /// P12/L02: server-first bytes and SOCKS-looking payloads are transparent in both directions.
  func testSpecDirectConnectReportsActualBoundEndpointAndPreservesTunnelBytes() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let serverBytes = Data([5, 1, 0, 0, 255, 1, 2])
    let clientBytes = Data([5, 3, 0, 1, 0, 0, 0, 0, 0, 0])
    let targetCapture = SpecTCPBytes(eventLoop: harness.group.next(), serverFirst: serverBytes)
    let targetAccepted = SpecInbox<Channel>(eventLoop: harness.group.next())
    let target = try ServerBootstrap(group: harness.group)
      .childChannelInitializer { channel in
        targetAccepted.append(channel)
        return channel.pipeline.addHandler(targetCapture)
      }.bind(host: "127.0.0.1", port: 0).wait()
    harness.channels.append(target)
    let capture = SpecTCPBytes(eventLoop: harness.group.next())
    let client = try harness.connect(capture: capture)
    _ = try specWait(harness.accepted.next())
    let port = try XCTUnwrap(target.localAddress?.port)
    try writeData(Data([5, 1, 0, 1, 127, 0, 0, 1]) + UInt16(port).bigEndianBytes, to: client)
    let targetChannel = try specWait(targetAccepted.next())
    harness.channels.append(targetChannel)
    let localPort = try XCTUnwrap(targetChannel.remoteAddress?.port)
    let response = try specWait(capture.atLeast(12 + serverBytes.count))
    XCTAssertEqual(
      response,
      Data([5, 0, 5, 0, 0, 1, 127, 0, 0, 1])
        + UInt16(localPort).bigEndianBytes + serverBytes)
    try writeData(clientBytes, to: client)
    XCTAssertEqual(try specWait(targetCapture.atLeast(clientBytes.count)), clientBytes)
  }

  /// C09：DIRECT CONNECT 的两种数字别名连接同一个本地目标，并透明传输载荷。
  func testSpecTCPNumericAliasesUseDirect() throws {
    for address in [
      Data([3, 9]) + Data("127.0.0.1".utf8),
      Data([4]) + Data(repeating: 0, count: 10) + Data([255, 255, 127, 0, 0, 1]),
    ] {
      let harness = SOCKS5SpecHarness()
      defer { harness.close() }
      let targetBytes = SpecTCPBytes(eventLoop: harness.group.next(), serverFirst: Data([9]))
      let accepted = harness.accepted
      let target = try ServerBootstrap(group: harness.group)
        .childChannelInitializer { channel in
          accepted.append(channel)
          return channel.pipeline.addHandler(targetBytes)
        }.bind(host: "127.0.0.1", port: 0).wait()
      harness.channels.append(target)
      let capture = SpecTCPBytes(eventLoop: harness.group.next())
      let client = try harness.connect(capture: capture)
      _ = try specWait(harness.accepted.next())
      let port = try XCTUnwrap(target.localAddress?.port)
      try writeData(Data([5, 1, 0]) + address + UInt16(port).bigEndianBytes, to: client)
      let targetChannel = try specWait(harness.accepted.next())
      harness.channels.append(targetChannel)
      let response = try specWait(capture.atLeast(13))
      XCTAssertEqual(response.prefix(6), Data([5, 0, 5, 0, 0, 1]))
      XCTAssertEqual(response.suffix(1), Data([9]))
      try writeData(Data([42, 0, 255]), to: client)
      XCTAssertEqual(try specWait(targetBytes.atLeast(3)), Data([42, 0, 255]))
    }
  }

  func testSpecDirectConnectionRefusalUsesREP05() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    // Reserve the port with UDP only; its TCP endpoint is not listening.
    let reservation = try harness.datagram()
    let port = try XCTUnwrap(reservation.channel.localAddress?.port)
    let capture = SpecTCPBytes(eventLoop: harness.group.next())
    let client = try harness.connect(capture: capture)
    _ = try specWait(harness.accepted.next())
    try writeData(Data([5, 1, 0, 1, 127, 0, 0, 1]) + UInt16(port).bigEndianBytes, to: client)
    let response = try specWait(capture.atLeast(12))
    XCTExpectFailure("§18.1: MagentCore wraps ECONNREFUSED; SOCKS5 returns 01 instead of 05") {
      XCTAssertEqual(Data(response.dropFirst(2)), specFailure(5))
    }
  }

  /// SOCKS5 直连迟到完成时不得重复发送失败响应。
  func testMagentTCPConnectionSendsSingleSOCKS5FailureWhenDirectConnectCompletesLate() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let firstResponsePromise = eventLoop.makePromise(of: Data.self)
    let delayedWrites = DelayedTestWrites(
      eventLoop: eventLoop,
      firstWritePromise: firstResponsePromise,
      writesBeforeDelay: 1
    )
    var channels: [Channel] = []
    defer {
      _ = try? delayedWrites.release().wait()
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let targetServer = try ServerBootstrap(group: group)
      .childChannelInitializer { channel in
        targetAcceptedPromise.succeed(channel)
        return channel.pipeline.addHandler(TestInboundHandler())
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
    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    let request = socks5ConnectRequest(.ipv4(Data([127, 0, 0, 1]), port: targetPort))
    let proxyServer = try bindTCPProxy(
      group: group,
      core: core,
      shutdownFuture: shutdownPromise.futureResult
    ) { channel in
      channel.pipeline.addHandlers(
        SplitProxyRequest(requestLength: request.count, leadingRequestLengths: [3]),
        delayedWrites
      )
    }
    channels.append(proxyServer)

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let greetingPromise = client.eventLoop.makePromise(of: Data.self)
    let responsesPromise = client.eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(
        expectedByteCount: testSocks5NoAuthentication.count + testSocks5GeneralFailure.count,
        promise: responsesPromise
      )
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    var requestAndPayload = request
    requestAndPayload.append(0xAA)
    try writeData(requestAndPayload, to: client)

    XCTAssertEqual(try firstResponsePromise.futureResult.wait(), testSocks5GeneralFailure)
    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    let targetClosed = expectation(
      description: "late SOCKS5 direct wire closes after failure reply wins")
    targetChannel.closeFuture.whenComplete { _ in
      targetClosed.fulfill()
    }
    wait(for: [targetClosed], timeout: 2)

    XCTAssertEqual(try delayedWrites.writeCount().wait(), 2)
    try delayedWrites.release().wait()
    XCTAssertEqual(
      try responsesPromise.futureResult.wait(),
      testSocks5NoAuthentication + testSocks5GeneralFailure
    )
  }

  // MARK: - TCP 背压与半关闭

  /// SOCKS5 隧道两个方向均等待上一批写入完成。
  func testSOCKS5TCPUsesStrictBackpressureInBothDirections() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let firstWirePayload = Data("first-socks5-wire-payload".utf8)
    let secondWirePayload = Data("second-socks5-wire-payload".utf8)
    let firstProxyPayload = Data(repeating: 0xA5, count: 8 * 1024 * 1024)
    let secondProxyPayload = Data("second-socks5-proxy-payload".utf8)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    let firstTunnelWritePromise = eventLoop.makePromise(of: Data.self)
    let manualReads = ManualTestReads(eventLoop: eventLoop)
    let delayedWrites = DelayedTestWrites(
      eventLoop: eventLoop,
      firstWritePromise: firstTunnelWritePromise,
      writesBeforeDelay: 2
    )
    var channels: [Channel] = []
    defer {
      _ = try? delayedWrites.release().wait()
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let targetServer = try ServerBootstrap(group: group)
      .childChannelOption(ChannelOptions.autoRead, value: false)
      .childChannelOption(ChannelOptions.socketOption(.so_rcvbuf), value: 1_024)
      .childChannelInitializer { channel in
        targetAcceptedPromise.succeed(channel)
        return channel.pipeline.addHandler(
          TestDataCollector(
            expectedByteCount: firstProxyPayload.count + secondProxyPayload.count,
            promise: targetPayloadPromise
          )
        )
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
    ) { channel in
      channel.pipeline.addHandlers(manualReads, delayedWrites)
    }
    channels.append(proxyServer)

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let greetingPromise = eventLoop.makePromise(of: Data.self)
    let responsesPromise = eventLoop.makePromise(of: Data.self)
    let tunnelPayloadsPromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12, promise: responsesPromise),
      TestDataCollector(
        expectedByteCount: 12 + firstWirePayload.count + secondWirePayload.count,
        promise: tunnelPayloadsPromise
      )
    ).wait()

    try manualReads.enqueue([Data([0x05, 0x01, 0x00])]).wait()
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    let connectRequest = socks5ConnectRequest(.ipv4(Data([127, 0, 0, 1]), port: targetPort))
    try manualReads.enqueue([connectRequest]).wait()
    let responses = try responsesPromise.futureResult.wait()
    XCTAssertEqual(responses.prefix(2), testSocks5NoAuthentication)
    XCTAssertEqual(responses.dropFirst(2).prefix(2), Data([0x05, 0x00]))

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    try writeData(firstWirePayload, to: targetChannel)
    XCTAssertEqual(try firstTunnelWritePromise.futureResult.wait(), firstWirePayload)
    try writeData(secondWirePayload, to: targetChannel)
    XCTAssertEqual(try delayedWrites.writeCount().wait(), 3)

    try delayedWrites.release().wait()
    XCTAssertEqual(
      try tunnelPayloadsPromise.futureResult.wait(),
      responses + firstWirePayload + secondWirePayload
    )
    XCTAssertEqual(try delayedWrites.writeCount().wait(), 4)

    try manualReads.enqueue([firstProxyPayload, secondProxyPayload]).wait()
    XCTAssertEqual(try manualReads.deliveredCount().wait(), 3)

    try targetChannel.setOption(ChannelOptions.autoRead, value: true).wait()
    let receivedPayload = try targetPayloadPromise.futureResult.wait()
    XCTAssertEqual(receivedPayload.count, firstProxyPayload.count + secondProxyPayload.count)
    XCTAssertEqual(receivedPayload.suffix(secondProxyPayload.count), secondProxyPayload)
    XCTAssertEqual(try manualReads.deliveredCount().wait(), 4)
  }

  /// SOCKS5 客户端半关闭前的数据必须先于下游 FIN 转发。
  func testSOCKS5TCPProxyHalfCloseForwardsFinalPayloadBeforeWireFIN() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let proxyPayload = Data("final-socks5-proxy-payload".utf8)
    let wirePayload = Data("final-socks5-wire-payload".utf8)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    let targetInputClosed = expectation(
      description: "SOCKS5 target receives FIN after proxy payload")
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let targetServer = try ServerBootstrap(group: group)
      .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .childChannelInitializer { channel in
        targetAcceptedPromise.succeed(channel)
        return channel.pipeline.addHandlers(
          TestDataCollector(expectedByteCount: proxyPayload.count, promise: targetPayloadPromise),
          TestInputClosedRecorder(expectation: targetInputClosed)
        )
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

    let client = try ClientBootstrap(group: group)
      .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let greetingPromise = eventLoop.makePromise(of: Data.self)
    let responsesPromise = eventLoop.makePromise(of: Data.self)
    let wirePayloadPromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12, promise: responsesPromise),
      TestDataCollector(expectedByteCount: 12 + wirePayload.count, promise: wirePayloadPromise)
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(socks5ConnectRequest(.ipv4(Data([127, 0, 0, 1]), port: targetPort)), to: client)
    _ = try responsesPromise.futureResult.wait()

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    try writeData(proxyPayload, to: client)
    try client.close(mode: .output).wait()

    wait(for: [targetInputClosed], timeout: 2)
    XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), proxyPayload)

    try writeData(wirePayload, to: targetChannel)
    XCTAssertEqual(
      try wirePayloadPromise.futureResult.wait().suffix(wirePayload.count), wirePayload)
  }

  /// SOCKS5 下游半关闭后保留另一方向的转发。
  func testSOCKS5TCPWireHalfCloseKeepsProxyToWireDirectionOpen() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let wirePayload = Data("final-socks5-wire-payload".utf8)
    let proxyPayload = Data("socks5-payload-after-wire-fin".utf8)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    let clientInputClosed = expectation(
      description: "SOCKS5 client receives FIN after wire payload")
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let targetServer = try ServerBootstrap(group: group)
      .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .childChannelInitializer { channel in
        targetAcceptedPromise.succeed(channel)
        return channel.pipeline.addHandler(
          TestDataCollector(expectedByteCount: proxyPayload.count, promise: targetPayloadPromise)
        )
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

    let client = try ClientBootstrap(group: group)
      .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let greetingPromise = eventLoop.makePromise(of: Data.self)
    let responsesPromise = eventLoop.makePromise(of: Data.self)
    let wirePayloadPromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12, promise: responsesPromise),
      TestDataCollector(expectedByteCount: 12 + wirePayload.count, promise: wirePayloadPromise),
      TestInputClosedRecorder(expectation: clientInputClosed)
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(socks5ConnectRequest(.ipv4(Data([127, 0, 0, 1]), port: targetPort)), to: client)
    _ = try responsesPromise.futureResult.wait()

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    try writeData(wirePayload, to: targetChannel)
    try targetChannel.close(mode: .output).wait()

    wait(for: [clientInputClosed], timeout: 2)
    XCTAssertEqual(
      try wirePayloadPromise.futureResult.wait().suffix(wirePayload.count), wirePayload)
    XCTAssertTrue(client.isActive)
    XCTAssertTrue(targetChannel.isActive)

    try writeData(proxyPayload, to: client)
    XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), proxyPayload)
  }

  /// SOCKS5 建连期间收到半关闭时等待隧道建立后再传播。
  func testSOCKS5TCPDefersProxyHalfCloseUntilTunnelIsEstablished() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let targetInputClosed = expectation(description: "SOCKS5 target receives deferred proxy FIN")
    let wirePayload = Data("socks5-response-after-handshake-fin".utf8)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let targetServer = try ServerBootstrap(group: group)
      .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .childChannelInitializer { channel in
        targetAcceptedPromise.succeed(channel)
        return channel.pipeline.addHandler(TestInputClosedRecorder(expectation: targetInputClosed))
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

    let client = try ClientBootstrap(group: group)
      .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let greetingPromise = eventLoop.makePromise(of: Data.self)
    let responsePromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12 + wirePayload.count, promise: responsePromise)
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(socks5ConnectRequest(.ipv4(Data([127, 0, 0, 1]), port: targetPort)), to: client)
    try client.close(mode: .output).wait()

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    wait(for: [targetInputClosed], timeout: 2)

    try writeData(wirePayload, to: targetChannel)
    XCTAssertEqual(try responsePromise.futureResult.wait().suffix(wirePayload.count), wirePayload)
  }

  // MARK: - UDP 关联与客户端来源

  /// 当前 IPv4 UDP relay 必须拒绝 IPv6 control connection 的 association。
  func testSOCKS5UDPAssociateRejectsIPv6ControlBecauseRelayIsIPv4() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let core = try MagentCore(
      defaultDecision: .direct,
      proxyNodes: [],
      defaultTimeout: 10_000,
      rules: []
    )
    let proxyServer: Channel
    do {
      proxyServer = try ServerBootstrap(group: group)
        .childChannelOption(ChannelOptions.autoRead, value: false)
        .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        .childChannelInitializer { channel in
          channel.pipeline.addHandler(
            MagentTCPConnection(
              channel,
              core: core,
              dnsAddress: nil,
              shutdownFuture: shutdownPromise.futureResult
            )
          )
        }
        .bind(host: "::1", port: 0)
        .wait()
    } catch {
      throw XCTSkip("IPv6 loopback is unavailable: \(error)")
    }
    channels.append(proxyServer)

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let greetingPromise = eventLoop.makePromise(of: Data.self)
    let responsesPromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12, promise: responsesPromise)
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    let controlClosed = expectation(
      description: "IPv6 SOCKS5 UDP control connection closes after rejection")
    client.closeFuture.whenComplete { _ in
      controlClosed.fulfill()
    }
    try writeData(Data([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), to: client)
    let responses = try responsesPromise.futureResult.wait()
    XCTAssertEqual(responses.prefix(2), testSocks5NoAuthentication)
    let associateResponse = responses.dropFirst(2)
    XCTAssertEqual(associateResponse, Data([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
    wait(for: [controlClosed], timeout: 2)
    XCTAssertFalse(client.isActive)
  }

  /// §13.5: a loopback IPv6 control connection must publish an IPv6 UDP relay.
  func testSpecIPv6ControlSupportsUDPAssociate() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let core = try MagentCore(
      defaultDecision: .direct, proxyNodes: [], defaultTimeout: 1000, rules: [])
    let shutdown = harness.shutdown.futureResult
    let server = try ServerBootstrap(group: harness.group)
      .childChannelOption(ChannelOptions.autoRead, value: false)
      .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
      .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .childChannelInitializer { channel in
        channel.pipeline.addHandler(
          MagentTCPConnection(channel, core: core, dnsAddress: nil, shutdownFuture: shutdown))
      }.bind(host: "::1", port: 0).wait()
    harness.channels.append(server)
    let capture = SpecTCPBytes(eventLoop: harness.group.next())
    let client = try ClientBootstrap(group: harness.group)
      .channelInitializer { $0.pipeline.addHandler(capture) }
      .connect(to: XCTUnwrap(server.localAddress)).wait()
    harness.channels.append(client)
    try writeData(Data([5, 1, 0]), to: client)
    XCTAssertEqual(try specWait(capture.atLeast(2)), Data([5, 0]))
    try writeData(Data([5, 3, 0, 4]) + Data(repeating: 0, count: 18), to: client)
    let response = try specWait(capture.atLeast(12))
    XCTExpectFailure("§13.5: UDP ASSOCIATE explicitly rejects IPv6 control connections") {
      XCTAssertEqual(Data(response.dropFirst(2).prefix(4)), Data([5, 0, 0, 4]))
    }
  }

  func testSpecUDPRejectsInvalidClientSourceHints() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let hints: [(Data, UInt8)] = [
      (Data([1, 192, 0, 2, 1, 0, 0]), 2),
      (Data([1, 192, 0, 2, 1, 0, 53]), 2),
      (Data([3, 11]) + Data("example.com".utf8) + Data([0, 0]), 8),
    ]
    for (hint, rep) in hints {
      let capture = SpecTCPBytes(eventLoop: harness.group.next())
      let client = try harness.connect(capture: capture)
      _ = try specWait(harness.accepted.next())
      try writeData(Data([5, 3, 0]) + hint, to: client)
      let response = try specWait(capture.atLeast(12))
      XCTExpectFailure("U02/§13.3: UDP ASSOCIATE discards the client source hint") {
        XCTAssertEqual(Data(response.dropFirst(2)), specFailure(rep))
      }
      try? specWait(client.close())
    }
  }

  func testSpecUDPExplicitSourcePortMustBeHonored() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let declared = try harness.datagram()
    let intruder = try harness.datagram()
    let target = try harness.datagram(echo: true)
    let declaredPort = try XCTUnwrap(declared.channel.localAddress?.port)
    let targetPort = try XCTUnwrap(target.channel.localAddress?.port)
    let hint = Data([1, 127, 0, 0, 1]) + UInt16(declaredPort).bigEndianBytes
    let association = try harness.associate(hint: hint)
    let packet = Data([0, 0, 0, 1, 127, 0, 0, 1]) + UInt16(targetPort).bigEndianBytes + Data([42])
    try writeDatagram(packet, from: intruder.channel, to: association.relay)
    try harness.settleDatagrams()
    let forwarded = try specWait(target.inbox.count())
    XCTExpectFailure("§13.3: the first UDP sender wins even when a different port was declared") {
      XCTAssertEqual(forwarded, 0)
    }
  }

  func testSpecUDPFirstSenderMustMatchControlPeerIP() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let intruder: (channel: Channel, inbox: SpecInbox<Data>)
    do { intruder = try harness.datagram(host: "127.0.0.2") } catch {
      throw XCTSkip("A second loopback source address is unavailable: \(error)")
    }
    let target = try harness.datagram(echo: true)
    let port = try XCTUnwrap(target.channel.localAddress?.port)
    let association = try harness.associate()
    let packet = Data([0, 0, 0, 1, 127, 0, 0, 1]) + UInt16(port).bigEndianBytes + Data([42])
    try writeDatagram(packet, from: intruder.channel, to: association.relay)
    try harness.settleDatagrams()
    let forwarded = try specWait(target.inbox.count())
    XCTExpectFailure("U05/S08: the IPv4 relay accepts a first sender different from the TCP peer") {
      XCTAssertEqual(forwarded, 0)
    }
  }

  func testSpecUDPStrangerPortIsDroppedWithoutClosingPinnedAssociation() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let target = try harness.datagram(echo: true)
    let client = try harness.datagram()
    let intruder = try harness.datagram()
    let association = try harness.associate()
    let port = try XCTUnwrap(target.channel.localAddress?.port)
    let packet = Data([0, 0, 0, 1, 127, 0, 0, 1]) + UInt16(port).bigEndianBytes + Data([1])
    try writeDatagram(packet, from: client.channel, to: association.relay)
    XCTAssertEqual(try specWait(client.inbox.next()), packet)
    XCTAssertEqual(try specWait(target.inbox.next()), Data([1]))
    try writeDatagram(packet, from: intruder.channel, to: association.relay)
    try harness.settleDatagrams()
    XCTAssertEqual(try specWait(target.inbox.count()), 0)
    XCTAssertEqual(try specWait(intruder.inbox.count()), 0)
    XCTExpectFailure("U05/U16: an unrecognized remote endpoint closes the whole UDP association") {
      XCTAssertTrue(association.control.isActive)
    }
    if association.control.isActive {
      try writeDatagram(packet, from: client.channel, to: association.relay)
      XCTAssertEqual(try specWait(client.inbox.next()), packet)
    }
  }

  // MARK: - UDP 数据报、地址与路由

  /// 无 DNS 配置时仍可直连 UDP IP 目标，畸形数据包经 control connection 统一报错。
  func testSOCKS5UDPDirectDataPlaneRoundTripsAndRoutesMalformedPacketToControlErrorChain() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    let clientResponsePromise = eventLoop.makePromise(of: Data.self)
    let payload = Data("direct-udp-request".utf8)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let targetServer = try bindTestDatagram(group: group) { context, envelope in
      targetPayloadPromise.succeed(Data(envelope.data.readableBytesView))
      writeTestDatagram(envelope, through: context)
    }
    channels.append(targetServer)
    let core = try makeUDPTestCore(decision: .direct, nodes: [])
    let association = try establishSOCKS5UDPAssociation(
      group: group,
      core: core,
      shutdownFuture: shutdownPromise.futureResult,
      channels: &channels
    )
    let udpClient = try bindTestDatagram(group: group) { _, envelope in
      clientResponsePromise.succeed(Data(envelope.data.readableBytesView))
    }
    channels.append(udpClient)

    let targetAddress = try XCTUnwrap(targetServer.localAddress.flatMap(NetworkAddress.init))
    let request =
      Data([0x00, 0x00, 0x00]) + Socks5Connection.addressBytes(of: targetAddress) + payload
    try writeDatagram(request, from: udpClient, to: association.relayAddress)

    XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), payload)
    XCTAssertEqual(try clientResponsePromise.futureResult.wait(), request)

    let controlClosed = expectation(
      description: "malformed UDP datagram closes its control connection")
    association.controlChannel.closeFuture.whenComplete { _ in
      controlClosed.fulfill()
    }
    var fragmentedRequest = request
    fragmentedRequest[2] = 0x01
    try writeDatagram(fragmentedRequest, from: udpClient, to: association.relayAddress)
    wait(for: [controlClosed], timeout: 2)
  }

  /// U07/U08: invalid packets are independently dropped; they do not poison a valid association.
  func testSpecUDPMalformedDatagramsDoNotCloseAssociation() throws {
    let badPackets: [Data] = [
      Data(), Data([0]), Data([0, 0, 0, 1, 127, 0]),
      Data([1, 0, 0, 1, 127, 0, 0, 1, 0, 53]),
      Data([0, 1, 0, 1, 127, 0, 0, 1, 0, 53]),
      Data([0, 0, 1, 1, 127, 0, 0, 1, 0, 53]),
      Data([0, 0, 128, 1, 127, 0, 0, 1, 0, 53]),
      Data([0, 0, 255, 1, 127, 0, 0, 1, 0, 53]),
      Data([0, 0, 0, 2]), Data([0, 0, 0, 3, 4, 97]),
      Data([0, 0, 0, 3, 0, 0, 53]),
      Data([0, 0, 0, 1, 127, 0, 0, 1, 0, 0]),
      Data([0, 0, 0, 4]) + Data(repeating: 0, count: 15),
    ]
    for bad in badPackets {
      let harness = SOCKS5SpecHarness()
      defer { harness.close() }
      let association = try harness.associate()
      let client = try harness.datagram()
      try writeDatagram(bad, from: client.channel, to: association.relay)
      try harness.settleDatagrams()
      let alive = association.control.isActive
      XCTExpectFailure("U07/U08: malformed UDP closes the parent TCP; packet \(bad as NSData)") {
        XCTAssertTrue(alive)
      }
      XCTAssertEqual(
        try specWait(association.capture.snapshot()).count, 12,
        "A UDP error must not append a second ASSOCIATE reply")
      if alive {
        let target = try harness.datagram(echo: true)
        let port = try XCTUnwrap(target.channel.localAddress?.port)
        let packet = Data([0, 0, 0, 1, 127, 0, 0, 1]) + UInt16(port).bigEndianBytes + Data([9])
        try writeDatagram(packet, from: client.channel, to: association.relay)
        XCTAssertEqual(try specWait(client.inbox.next()), packet)
      }
    }
  }

  /// U01/U06/U09/U10: zero hints, exact framing, empty payload and independent datagrams.
  func testSpecUDPAcceptsZeroHintsAndPreservesEmptyDatagramBoundaries() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let target = try harness.datagram(echo: true)
    let client = try harness.datagram()
    let port = try XCTUnwrap(target.channel.localAddress?.port)
    let header = Data([0, 0, 0, 1, 127, 0, 0, 1]) + UInt16(port).bigEndianBytes
    let hints: [Data] = [Data([1, 0, 0, 0, 0, 0, 0]), Data([4]) + Data(repeating: 0, count: 18)]
    for hint in hints {
      let association = try harness.associate(hint: hint)
      for payload in [Data(), Data([5, 1, 0]), Data([255]), Data(repeating: 7, count: 1201)] {
        try writeDatagram(header + payload, from: client.channel, to: association.relay)
        XCTAssertEqual(try specWait(target.inbox.next()), payload)
        XCTAssertEqual(try specWait(client.inbox.next()), header + payload)
        XCTAssertTrue(association.control.isActive)
      }
      try specWait(association.control.close())
    }
  }

  /// 缺少 DNS 地址时拒绝 UDP 直连域名，并通过 control connection 关闭整个 association。
  func testSOCKS5UDPDirectDomainRejectsMissingDNSAddress() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }
    let core = try makeUDPTestCore(decision: .direct, nodes: [])
    let association = try establishSOCKS5UDPAssociation(
      group: group,
      core: core,
      dnsAddress: nil,
      shutdownFuture: shutdownPromise.futureResult,
      channels: &channels
    )
    let udpClient = try bindTestDatagram(group: group) { _, _ in
      XCTFail("A direct domain without DNS must not produce a UDP response")
    }
    channels.append(udpClient)
    let controlClosed = expectation(description: "missing DNS closes the control connection")
    association.controlChannel.closeFuture.whenComplete { _ in
      controlClosed.fulfill()
    }
    let target = NetworkAddress.domain("udp.test.invalid", port: 5353)
    let request = Data([0x00, 0x00, 0x00]) + Socks5Connection.addressBytes(of: target) + Data([1])
    try writeDatagram(request, from: udpClient, to: association.relayAddress)
    wait(for: [controlClosed], timeout: 2)
  }

  /// UDP 直连域名通过单个配置 DNS 解析并完成往返传输。
  func testSOCKS5UDPDirectDomainUsesConfiguredRemoteDNS() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    let clientResponsePromise = eventLoop.makePromise(of: Data.self)
    let payload = Data("direct-domain-udp-request".utf8)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let dnsServer = try bindTestDatagram(group: group) { context, envelope in
      let response = try testDNSResponse(for: Data(envelope.data.readableBytesView))
      var buffer = context.channel.allocator.buffer(capacity: response.count)
      buffer.writeBytes(response)
      writeTestDatagram(
        AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: buffer),
        through: context
      )
    }
    channels.append(dnsServer)
    let targetServer = try bindTestDatagram(group: group) { context, envelope in
      targetPayloadPromise.succeed(Data(envelope.data.readableBytesView))
      writeTestDatagram(envelope, through: context)
    }
    channels.append(targetServer)
    let core = try makeUDPTestCore(decision: .direct, nodes: [])
    let association = try establishSOCKS5UDPAssociation(
      group: group,
      core: core,
      dnsAddress: try XCTUnwrap(dnsServer.localAddress),
      shutdownFuture: shutdownPromise.futureResult,
      channels: &channels
    )
    let udpClient = try bindTestDatagram(group: group) { _, envelope in
      clientResponsePromise.succeed(Data(envelope.data.readableBytesView))
    }
    channels.append(udpClient)

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    let targetAddress = NetworkAddress.domain("udp.test.invalid", port: targetPort)
    let request =
      Data([0x00, 0x00, 0x00]) + Socks5Connection.addressBytes(of: targetAddress) + payload
    try writeDatagram(request, from: udpClient, to: association.relayAddress)

    XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), payload)
    let responseAddress = NetworkAddress.ipv4(Data([127, 0, 0, 1]), port: targetPort)
    let expectedResponse =
      Data([0x00, 0x00, 0x00])
      + Socks5Connection.addressBytes(of: responseAddress)
      + payload
    XCTAssertEqual(try clientResponsePromise.futureResult.wait(), expectedResponse)
    XCTAssertTrue(association.controlChannel.isActive)
  }

  /// IPv4 SOCKS5 relay 使用 IPv6 下游 Channel 访问 IPv6 目标。
  func testSOCKS5UDPIPv4RelayUsesIPv6ChannelForIPv6Target() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    let clientResponsePromise = eventLoop.makePromise(of: Data.self)
    let payload = Data("direct-ipv6-udp-request".utf8)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let targetServer: Channel
    do {
      targetServer = try bindTestDatagram(group: group, host: "::1") { context, envelope in
        targetPayloadPromise.succeed(Data(envelope.data.readableBytesView))
        writeTestDatagram(envelope, through: context)
      }
    } catch {
      throw XCTSkip("IPv6 loopback is unavailable: \(error)")
    }
    channels.append(targetServer)
    let core = try makeUDPTestCore(decision: .direct, nodes: [])
    let association = try establishSOCKS5UDPAssociation(
      group: group,
      core: core,
      shutdownFuture: shutdownPromise.futureResult,
      channels: &channels
    )
    let udpClient = try bindTestDatagram(group: group) { _, envelope in
      clientResponsePromise.succeed(Data(envelope.data.readableBytesView))
    }
    channels.append(udpClient)

    let targetAddress = try XCTUnwrap(targetServer.localAddress.flatMap(NetworkAddress.init))
    let request =
      Data([0x00, 0x00, 0x00]) + Socks5Connection.addressBytes(of: targetAddress) + payload
    try writeDatagram(request, from: udpClient, to: association.relayAddress)

    XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), payload)
    XCTAssertEqual(try clientResponsePromise.futureResult.wait(), request)
    XCTAssertTrue(association.controlChannel.isActive)
  }

  /// U06/U09: an empty IPv6 datagram is a 22-byte SOCKS5 response, not EOF.
  func testSpecUDPIPv6EmptyPayloadUsesTwentyTwoByteHeader() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let target = try harness.datagram(host: "::1", echo: true)
    let client = try harness.datagram()
    let association = try harness.associate()
    let port = try XCTUnwrap(target.channel.localAddress?.port)
    let header =
      Data([0, 0, 0, 4]) + Data(repeating: 0, count: 15) + Data([1]) + UInt16(port).bigEndianBytes
    XCTAssertEqual(header.count, 22)
    try writeDatagram(header, from: client.channel, to: association.relay)
    XCTAssertEqual(try specWait(target.inbox.next()), Data())
    XCTAssertEqual(try specWait(client.inbox.next()), header)
    XCTAssertTrue(association.control.isActive)
  }

  /// UDP 代理域名无需本地 DNS，按节点 Wire 加密请求并解密回包。
  func testSOCKS5UDPShadowsocksDataPlaneEncryptsRoutesAndDecryptsResponse() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let proxyTargetPromise = eventLoop.makePromise(of: NetworkAddress.self)
    let proxyPayloadPromise = eventLoop.makePromise(of: Data.self)
    let clientResponsePromise = eventLoop.makePromise(of: Data.self)
    let requestPayload = Data("proxied-udp-request".utf8)
    let responsePayload = Data("proxied-udp-response".utf8)
    let cipher = ProxyCipher.aes256Gcm
    let password = "udp-test-password"
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let shadowsocksServer = try bindTestDatagram(group: group) { context, envelope in
      guard let address = context.channel.localAddress else {
        throw MagentError.invalidAddress("test Shadowsocks UDP server has no local address")
      }
      let node = ProxyNode(address: address, cipher: cipher, password: password)
      let wire = try ShadowsocksUDPWire(proxyNode: node)
      let decoded = try wire.decodeInbound(Data(envelope.data.readableBytesView))
      proxyTargetPromise.succeed(decoded.address)
      proxyPayloadPromise.succeed(decoded.data)
      let output = try wire.encodeOutbound(responsePayload, address: decoded.address)
      var buffer = context.channel.allocator.buffer(capacity: output.count)
      buffer.writeBytes(output)
      let response = AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: buffer)
      writeTestDatagram(response, through: context)
    }
    channels.append(shadowsocksServer)
    let nodeAddress = try XCTUnwrap(shadowsocksServer.localAddress)
    let proxyNode = ProxyNode(address: nodeAddress, cipher: cipher, password: password)
    let core = try makeUDPTestCore(decision: .proxy(proxyNode.id), nodes: [proxyNode])
    let association = try establishSOCKS5UDPAssociation(
      group: group,
      core: core,
      shutdownFuture: shutdownPromise.futureResult,
      channels: &channels
    )
    let udpClient = try bindTestDatagram(group: group) { _, envelope in
      clientResponsePromise.succeed(Data(envelope.data.readableBytesView))
    }
    channels.append(udpClient)

    let targetAddress = NetworkAddress.domain("udp.example.com", port: 5353)
    let request =
      Data([0x00, 0x00, 0x00])
      + Socks5Connection.addressBytes(of: targetAddress)
      + requestPayload
    try writeDatagram(request, from: udpClient, to: association.relayAddress)

    XCTAssertEqual(try proxyTargetPromise.futureResult.wait(), targetAddress)
    XCTAssertEqual(try proxyPayloadPromise.futureResult.wait(), requestPayload)
    let expectedResponse =
      Data([0x00, 0x00, 0x00])
      + Socks5Connection.addressBytes(of: targetAddress)
      + responsePayload
    XCTAssertEqual(try clientResponsePromise.futureResult.wait(), expectedResponse)
    XCTAssertTrue(association.controlChannel.isActive)
  }

  /// C09：UDP 在同一关联中按规范化后的类型路由，并按相同表示向代理转发。
  func testSpecUDPNormalizesBeforeRoutingAndForwarding() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let plaintext = SpecInbox<Data>(eventLoop: harness.group.next())
    defer { try? plaintext.finish().wait() }
    let proxy = try bindTestDatagram(group: harness.group) { context, envelope in
      let node = ProxyNode(
        address: try XCTUnwrap(context.channel.localAddress), cipher: .aes256Gcm,
        password: "spec-test")
      let wire = try ShadowsocksUDPWire(proxyNode: node)
      let decoded = try wire.decodeInbound(Data(envelope.data.readableBytesView))
      plaintext.append(try decoded.address.shadowsocksAddressBytes() + decoded.data)
    }
    harness.channels.append(proxy)
    let node = ProxyNode(
      address: try XCTUnwrap(proxy.localAddress), cipher: .aes256Gcm, password: "spec-test")
    let core = try MagentCore(
      defaultDecision: .direct, proxyNodes: [node], defaultTimeout: 1000,
      rules: [
        try ProxyRule(
          matchType: .exactDomain, matchValue: "api.example.com", decision: .proxy(node.id),
          order: 0),
        try ProxyRule(
          matchType: .ipCIDR, matchValue: "192.0.2.0/24", decision: .proxy(node.id), order: 0),
      ])
    // No DNS client is configured: accidental DIRECT domain routing cannot pass this test.
    let association = try harness.associate(core: core)
    let client = try harness.datagram()
    let vectors: [(Data, Data)] = [
      (
        Data([3, 16]) + Data("API.Example.COM.".utf8),
        Data([3, 16]) + Data("api.example.com.".utf8)
      ),
      (
        Data([3, 15]) + Data("API.Example.COM".utf8), Data([3, 15]) + Data("api.example.com".utf8)
      ),
      (Data([3, 9]) + Data("192.0.2.1".utf8), Data([1, 192, 0, 2, 1])),
      (
        Data([4]) + Data(repeating: 0, count: 10) + Data([255, 255, 192, 0, 2, 1]),
        Data([1, 192, 0, 2, 1])
      ),
    ]
    for (address, expected) in vectors {
      let suffix = Data([1, 187, 42, 0, 255])
      try writeDatagram(
        Data([0, 0, 0]) + address + suffix, from: client.channel, to: association.relay)
      XCTAssertEqual(try specWait(plaintext.next()), expected + suffix)
      XCTAssertTrue(association.control.isActive)
    }
  }

  /// C09：Domain IPv4 和 mapped IPv6 的 DIRECT UDP 不依赖 DNS，回包仍用 IPv4。
  func testSpecUDPNumericAliasesUseDirectWithoutDNS() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let target = try harness.datagram(echo: true)
    let client = try harness.datagram()
    let association = try harness.associate()
    let port = try XCTUnwrap(target.channel.localAddress?.port)
    let suffix = UInt16(port).bigEndianBytes + Data([42, 0, 255])
    for address in [
      Data([3, 9]) + Data("127.0.0.1".utf8),
      Data([4]) + Data(repeating: 0, count: 10) + Data([255, 255, 127, 0, 0, 1]),
    ] {
      try writeDatagram(
        Data([0, 0, 0]) + address + suffix, from: client.channel, to: association.relay)
      XCTAssertEqual(try specWait(target.inbox.next()), Data([42, 0, 255]))
      XCTAssertEqual(try specWait(client.inbox.next()), Data([0, 0, 0, 1, 127, 0, 0, 1]) + suffix)
      XCTAssertTrue(association.control.isActive)
    }
  }

  /// R10: a shared association may interleave direct and proxy routes without changing exits.
  /// D08: DNS-looking payload is opaque; its QNAME must not select the proxy rule.
  func testSpecUDPInterleavesDirectAndProxyTargetsWithoutInspectingDNSPayload() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let proxyTargets = SpecInbox<NetworkAddress>(eventLoop: harness.group.next())
    defer { try? proxyTargets.finish().wait() }
    let proxy = try bindTestDatagram(group: harness.group) { context, envelope in
      let node = ProxyNode(
        address: try XCTUnwrap(context.channel.localAddress), cipher: .aes256Gcm,
        password: "spec-test")
      let wire = try ShadowsocksUDPWire(proxyNode: node)
      let decoded = try wire.decodeInbound(Data(envelope.data.readableBytesView))
      proxyTargets.append(decoded.address)
      var buffer = context.channel.allocator.buffer(capacity: 0)
      buffer.writeBytes(try wire.encodeOutbound(decoded.data, address: decoded.address))
      writeTestDatagram(
        AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: buffer), through: context)
    }
    harness.channels.append(proxy)
    let node = ProxyNode(
      address: try XCTUnwrap(proxy.localAddress), cipher: .aes256Gcm, password: "spec-test")
    let core = try MagentCore(
      defaultDecision: .direct, proxyNodes: [node], defaultTimeout: 1000,
      rules: [
        try ProxyRule(
          matchType: .domainSuffix, matchValue: "example.com", decision: .proxy(node.id), order: 0)
      ])
    let association = try harness.associate(core: core)
    let target = try harness.datagram(echo: true)
    let client = try harness.datagram()
    let port = try XCTUnwrap(target.channel.localAddress?.port)
    let dnsQuery =
      Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7])
      + Data("example".utf8) + Data([3]) + Data("com".utf8) + Data([0, 0, 1, 0, 1])
    XCTAssertEqual(dnsQuery.count, 29)
    let directPacket = Data([0, 0, 0, 1, 127, 0, 0, 1]) + UInt16(port).bigEndianBytes + dnsQuery
    let proxyPacket = Data([0, 0, 0, 3, 11]) + Data("example.com".utf8) + Data([1, 187, 1, 2, 3])
    for _ in 0..<2 {
      try writeDatagram(directPacket, from: client.channel, to: association.relay)
      XCTAssertEqual(try specWait(target.inbox.next()), dnsQuery)
      XCTAssertEqual(try specWait(client.inbox.next()), directPacket)
      XCTAssertEqual(try specWait(proxyTargets.count()), 0)
      try writeDatagram(proxyPacket, from: client.channel, to: association.relay)
      XCTAssertEqual(try specWait(proxyTargets.next()), .domain("example.com", port: 443))
      XCTAssertEqual(try specWait(client.inbox.next()), proxyPacket)
    }
  }

  /// U18/§15.12: one failed proxy flow must not terminate independent direct flows.
  func testSpecUDPRouteFailureDoesNotDestroyOtherFlows() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let missing = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let rule = try ProxyRule(
      matchType: .exactDomain, matchValue: "broken.example", decision: .proxy(missing), order: 0)
    let core = try MagentCore(
      defaultDecision: .direct, proxyNodes: [], defaultTimeout: 1000, rules: [rule])
    let association = try harness.associate(core: core)
    let client = try harness.datagram()
    let target = try harness.datagram(echo: true)
    let port = try XCTUnwrap(target.channel.localAddress?.port)
    let direct = Data([0, 0, 0, 1, 127, 0, 0, 1]) + UInt16(port).bigEndianBytes + Data([6])
    try writeDatagram(direct, from: client.channel, to: association.relay)
    XCTAssertEqual(try specWait(client.inbox.next()), direct)
    let broken = Data([0, 0, 0, 3, 14]) + Data("broken.example".utf8) + Data([1, 187, 7])
    try writeDatagram(broken, from: client.channel, to: association.relay)
    try harness.settleDatagrams()
    XCTExpectFailure("§15.12: a failed UDP route closes all other flows through the parent TCP") {
      XCTAssertTrue(association.control.isActive)
    }
    if association.control.isActive {
      try writeDatagram(direct, from: client.channel, to: association.relay)
      XCTAssertEqual(try specWait(client.inbox.next()), direct)
    }
  }

  // MARK: - UDP 控制连接与资源清理

  func testSpecUDPControlDataIsProtocolMisuse() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let association = try harness.associate()
    try writeData(Data([42]), to: association.control)
    try harness.settleDatagrams()
    XCTExpectFailure("U22/§6.5: the idle TCP state silently ignores control payload") {
      XCTAssertFalse(association.control.isActive)
    }
    XCTAssertEqual(try specWait(association.capture.snapshot()).count, 12)
  }

  /// U17: FIN and full close release the advertised port; old packets cannot be forwarded.
  func testSpecUDPControlEOFReleasesRelayAndStopsForwarding() throws {
    for halfClose in [false, true] {
      let harness = SOCKS5SpecHarness()
      defer { harness.close() }
      let target = try harness.datagram(echo: true)
      let client = try harness.datagram()
      let association = try harness.associate()
      let port = try XCTUnwrap(target.channel.localAddress?.port)
      let packet = Data([0, 0, 0, 1, 127, 0, 0, 1]) + UInt16(port).bigEndianBytes + Data([7])
      try writeDatagram(packet, from: client.channel, to: association.relay)
      XCTAssertEqual(try specWait(client.inbox.next()), packet)
      XCTAssertEqual(try specWait(target.inbox.next()), Data([7]))
      try specWait(association.control.close(mode: halfClose ? .output : .all))
      try specWait(association.accepted.closeFuture)
      try harness.settleDatagrams()
      // Rebinding the exact advertised port is positive evidence that the relay socket was closed.
      let replacement = try DatagramBootstrap(group: harness.group).bind(to: association.relay)
        .wait()
      harness.channels.append(replacement)
      try writeDatagram(packet, from: client.channel, to: association.relay)
      try harness.settleDatagrams()
      XCTAssertEqual(try specWait(target.inbox.count()), 0)
    }
  }

  func testSpecUDPTwoAssociationsHaveIndependentPortsAndLifetime() throws {
    let harness = SOCKS5SpecHarness()
    defer { harness.close() }
    let first = try harness.associate()
    let second = try harness.associate()
    XCTAssertNotEqual(first.relay.port, second.relay.port)
    try specWait(first.control.close())
    try specWait(first.accepted.closeFuture)
    let target = try harness.datagram(echo: true)
    let client = try harness.datagram()
    let port = try XCTUnwrap(target.channel.localAddress?.port)
    let packet = Data([0, 0, 0, 1, 127, 0, 0, 1]) + UInt16(port).bigEndianBytes + Data([8])
    try writeDatagram(packet, from: client.channel, to: second.relay)
    XCTAssertEqual(try specWait(client.inbox.next()), packet)
    XCTAssertTrue(second.control.isActive)
  }

  // MARK: - 测试连接构造

  /// 按生产握手流程创建独占 UDP association，并记录待清理的 Channel。
  fileprivate func establishSOCKS5UDPAssociation(
    group: EventLoopGroup,
    core: MagentCore,
    dnsAddress: SocketAddress? = nil,
    shutdownFuture: EventLoopFuture<Void>,
    channels: inout [Channel]
  ) throws -> (controlChannel: Channel, relayAddress: SocketAddress) {
    let proxyServer = try bindTCPProxy(
      group: group,
      core: core,
      dnsAddress: dnsAddress,
      shutdownFuture: shutdownFuture
    )
    channels.append(proxyServer)
    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let greetingPromise = client.eventLoop.makePromise(of: Data.self)
    let responsesPromise = client.eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12, promise: responsesPromise)
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)
    try writeData(Data([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), to: client)

    let responses = try responsesPromise.futureResult.wait()
    XCTAssertEqual(responses.prefix(2), testSocks5NoAuthentication)
    let associateResponse = responses.dropFirst(2)
    XCTAssertEqual(associateResponse.prefix(8), Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1]))
    let port =
      Int(associateResponse[associateResponse.index(associateResponse.startIndex, offsetBy: 8)])
      << 8
      | Int(associateResponse[associateResponse.index(associateResponse.startIndex, offsetBy: 9)])
    XCTAssertGreaterThan(port, 0)
    return (client, try SocketAddress(ipAddress: "127.0.0.1", port: port))
  }

  /// 通过指定决策和完整节点列表创建 UDP 路由测试的 Core。
  fileprivate func makeUDPTestCore(decision: Decision, nodes: [ProxyNode]) throws -> MagentCore {
    return try MagentCore(
      defaultDecision: decision,
      proxyNodes: nodes,
      defaultTimeout: 10_000,
      rules: []
    )
  }
}

// MARK: - 测试辅助

private final class TestDatagramHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = AddressedEnvelope<ByteBuffer>

  private let receive: @Sendable (ChannelHandlerContext, InboundIn) throws -> Void

  init(receive: @escaping @Sendable (ChannelHandlerContext, InboundIn) throws -> Void) {
    self.receive = receive
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    do {
      try receive(context, unwrapInboundIn(data))
    } catch {
      context.fireErrorCaught(error)
    }
  }

  func errorCaught(context: ChannelHandlerContext, error _: Error) {
    context.close(promise: nil)
  }
}

private func bindTestDatagram(
  group: EventLoopGroup,
  host: String = "127.0.0.1",
  receive: @escaping @Sendable (ChannelHandlerContext, AddressedEnvelope<ByteBuffer>) throws -> Void
) throws -> Channel {
  try DatagramBootstrap(group: group)
    .channelInitializer { channel in
      channel.pipeline.addHandler(TestDatagramHandler(receive: receive))
    }
    .bind(host: host, port: 0)
    .wait()
}

/// Sends a test datagram while keeping context-relative error propagation on its owning EventLoop.
private func writeTestDatagram(
  _ envelope: AddressedEnvelope<ByteBuffer>,
  through context: ChannelHandlerContext
) {
  let loopBoundContext = context.loopBound
  context.channel.writeAndFlush(envelope).whenFailure {
    loopBoundContext.value.fireErrorCaught($0)
  }
}

private func writeDatagram(_ data: Data, from channel: Channel, to address: SocketAddress) throws {
  var buffer = channel.allocator.buffer(capacity: data.count)
  buffer.writeBytes(data)
  try channel.writeAndFlush(AddressedEnvelope(remoteAddress: address, data: buffer)).wait()
}

private func testDNSResponse(for query: Data) throws -> Data {
  guard query.count >= 17 else {
    throw MagentError.malformedRequest("test DNS query is too short")
  }
  var offset = 12
  while offset < query.count {
    let labelLength = Int(query[offset])
    offset += 1
    if labelLength == 0 {
      break
    }
    guard labelLength <= 63, offset + labelLength <= query.count else {
      throw MagentError.malformedRequest("test DNS query has an invalid label")
    }
    offset += labelLength
  }
  guard offset + 4 <= query.count else {
    throw MagentError.malformedRequest("test DNS query has an incomplete question")
  }
  let recordType = query.readBigEndianUInt16(at: offset)
  let questionEnd = offset + 4
  let recordData: Data
  switch recordType {
  case 1:
    recordData = Data([127, 0, 0, 1])
  case 28:
    recordData = Data(repeating: 0, count: 15) + Data([1])
  default:
    throw MagentError.malformedRequest("test DNS query uses an unsupported record type")
  }

  var response = Data(query.prefix(2))
  response.append(contentsOf: [0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
  response.append(query[12..<questionEnd])
  response.append(contentsOf: [0xC0, 0x0C])
  response.append(contentsOf: UInt16(recordType).bigEndianBytes)
  response.append(contentsOf: [0x00, 0x01, 0x00, 0x00, 0x00, 0x3C])
  response.append(contentsOf: UInt16(recordData.count).bigEndianBytes)
  response.append(recordData)
  return response
}

private func socks5ConnectRequest(_ address: NetworkAddress) -> Data {
  Data([0x05, 0x01, 0x00]) + Socks5Connection.addressBytes(of: address)
}

private let testSocks5NoAuthentication = Data([0x05, 0x00])
private let testSocks5GeneralFailure = Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0])

private enum SOCKS5SpecTestError: Error { case timeout }

/// Asynchronous observations have a deadline, including a lost reply caused by a regression.
private func specWait<Value: Sendable>(_ future: EventLoopFuture<Value>) throws -> Value {
  let ready = XCTestExpectation(description: "bounded SOCKS5 SPEC operation")
  future.whenComplete { _ in ready.fulfill() }
  guard XCTWaiter.wait(for: [ready], timeout: 3) == .completed else {
    throw SOCKS5SpecTestError.timeout
  }
  return try future.wait()
}

private func specFailure(_ rep: UInt8) -> Data {
  Data([5, rep, 0, 1, 0, 0, 0, 0, 0, 0])
}

private func specNegotiatedChannel() throws -> EmbeddedChannel {
  let channel = try makeConnectionChannel()
  try writeInbound(Data([5, 1, 0]), to: channel)
  XCTAssertEqual(try readOutboundData(from: channel), Data([5, 0]))
  return channel
}

private func specSegmentations(_ data: Data) -> [[Data]] {
  var result = [[data]]
  for split in 1..<data.count {
    result.append([Data(data.prefix(split)), Data(data.dropFirst(split))])
  }
  result.append(data.map { Data([$0]) })
  var mixed: [Data] = []
  var offset = 0
  var seed: UInt64 = 0x505
  while offset < data.count {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1
    let size = min(Int(seed % 17) + 1, data.count - offset)
    mixed.append(Data(data[offset..<(offset + size)]))
    offset += size
  }
  result.append(mixed)
  return result
}

/// Single-event-loop observation queue; closing fails pending readers so no promise leaks remain.
private final class SpecInbox<Value: Sendable>: @unchecked Sendable {
  let eventLoop: EventLoop
  private var values: [Value] = []
  private var readers: [EventLoopPromise<Value>] = []

  init(eventLoop: EventLoop) { self.eventLoop = eventLoop }

  func append(_ value: Value) {
    eventLoop.preconditionInEventLoop()
    if readers.isEmpty { values.append(value) } else { readers.removeFirst().succeed(value) }
  }

  func next() -> EventLoopFuture<Value> {
    eventLoop.flatSubmit {
      if !self.values.isEmpty {
        return self.eventLoop.makeSucceededFuture(self.values.removeFirst())
      }
      let promise = self.eventLoop.makePromise(of: Value.self)
      self.readers.append(promise)
      return promise.futureResult
    }
  }

  func count() -> EventLoopFuture<Int> { eventLoop.submit { self.values.count } }

  func finish() -> EventLoopFuture<Void> {
    eventLoop.submit {
      for reader in self.readers { reader.fail(MagentError.connectionClosed) }
      self.readers.removeAll()
    }
  }
}

/// Captures the entire TCP stream, independent of network read boundaries.
private final class SpecTCPBytes: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  private let eventLoop: EventLoop
  private var bytes = Data()
  private var readers: [(Int, EventLoopPromise<Data>)] = []
  private var closed = false
  private let serverFirst: Data

  init(eventLoop: EventLoop, serverFirst: Data = Data()) {
    self.eventLoop = eventLoop
    self.serverFirst = serverFirst
  }

  func channelActive(context: ChannelHandlerContext) {
    context.fireChannelActive()
    if !serverFirst.isEmpty {
      var buffer = context.channel.allocator.buffer(capacity: serverFirst.count)
      buffer.writeBytes(serverFirst)
      context.writeAndFlush(NIOAny(buffer), promise: nil)
    }
  }

  func snapshot() -> EventLoopFuture<Data> { eventLoop.submit { self.bytes } }

  func atLeast(_ count: Int) -> EventLoopFuture<Data> {
    eventLoop.flatSubmit {
      if self.bytes.count >= count { return self.eventLoop.makeSucceededFuture(self.bytes) }
      if self.closed { return self.eventLoop.makeFailedFuture(MagentError.connectionClosed) }
      let promise = self.eventLoop.makePromise(of: Data.self)
      self.readers.append((count, promise))
      return promise.futureResult
    }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    bytes.append(contentsOf: unwrapInboundIn(data).readableBytesView)
    readers.removeAll { count, promise in
      guard bytes.count >= count else { return false }
      promise.succeed(bytes)
      return true
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    closed = true
    for (_, reader) in readers { reader.fail(MagentError.connectionClosed) }
    readers.removeAll()
    context.fireChannelInactive()
  }
}

/// Owns the local listeners, clients and shutdown notifications used by protocol tests.
private final class SOCKS5SpecHarness {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let shutdown: EventLoopPromise<Void>
  let accepted: SpecInbox<Channel>
  let proxyPlaintext: SpecInbox<Data>
  var channels: [Channel] = []
  private var datagramInboxes: [SpecInbox<Data>] = []

  init() {
    let loop = group.next()
    shutdown = loop.makePromise(of: Void.self)
    accepted = SpecInbox(eventLoop: loop)
    proxyPlaintext = SpecInbox(eventLoop: loop)
  }

  func connect(core: MagentCore? = nil, capture: SpecTCPBytes) throws -> Channel {
    let core =
      try core
      ?? MagentCore(defaultDecision: .direct, proxyNodes: [], defaultTimeout: 1000, rules: [])
    let accepted = self.accepted
    let server = try bindTCPProxy(group: group, core: core, shutdownFuture: shutdown.futureResult) {
      channel in
      accepted.append(channel)
      return channel.eventLoop.makeSucceededFuture(())
    }
    channels.append(server)
    let client = try ClientBootstrap(group: group).channelInitializer {
      $0.pipeline.addHandler(capture)
    }
    .connect(to: XCTUnwrap(server.localAddress)).wait()
    channels.append(client)
    try writeData(Data([5, 1, 0]), to: client)
    XCTAssertEqual(try specWait(capture.atLeast(2)), Data([5, 0]))
    return client
  }

  /// A local SS peer observes parsed target bytes without resolving or dialing business targets.
  func proxyCore(rules: [ProxyRule] = []) throws -> MagentCore {
    let plaintext = proxyPlaintext
    let server = try ServerBootstrap(group: group).childChannelInitializer { channel in
      do {
        let node = ProxyNode(
          address: try XCTUnwrap(channel.localAddress), cipher: .aes256Gcm, password: "spec-test")
        let decoder = try ShadowsocksTCPWire(proxyNode: node)
        _ = try decoder.start(handshake: .domain("unused.test", port: 1))
        return channel.pipeline.addHandler(SpecSSCapture(decoder: decoder, plaintext: plaintext))
      } catch { return channel.eventLoop.makeFailedFuture(error) }
    }.bind(host: "127.0.0.1", port: 0).wait()
    channels.append(server)
    let node = ProxyNode(
      address: try XCTUnwrap(server.localAddress), cipher: .aes256Gcm, password: "spec-test")
    return try MagentCore(
      defaultDecision: .proxy(node.id), proxyNodes: [node], defaultTimeout: 1000, rules: rules)
  }

  func datagram(host: String = "127.0.0.1", echo: Bool = false) throws -> (
    channel: Channel, inbox: SpecInbox<Data>
  ) {
    let inbox = SpecInbox<Data>(eventLoop: group.next())
    datagramInboxes.append(inbox)
    let channel = try bindTestDatagram(group: group, host: host) { context, envelope in
      inbox.append(Data(envelope.data.readableBytesView))
      if echo { writeTestDatagram(envelope, through: context) }
    }
    channels.append(channel)
    return (channel, inbox)
  }

  func associate(hint: Data = Data([1, 0, 0, 0, 0, 0, 0]), core: MagentCore? = nil) throws -> (
    control: Channel, accepted: Channel, relay: SocketAddress, capture: SpecTCPBytes
  ) {
    let capture = SpecTCPBytes(eventLoop: group.next())
    let client = try connect(core: core, capture: capture)
    let serverClient = try specWait(accepted.next())
    try writeData(Data([5, 3, 0]) + hint, to: client)
    let response = try specWait(capture.atLeast(12))
    XCTAssertEqual(response.prefix(10), Data([5, 0, 5, 0, 0, 1, 127, 0, 0, 1]))
    let port = Int(response[10]) << 8 | Int(response[11])
    XCTAssertGreaterThan(port, 0)
    return (client, serverClient, try SocketAddress(ipAddress: "127.0.0.1", port: port), capture)
  }

  /// A bounded observation window for packets that should have no response. Positive round trips
  /// before/after it verify liveness separately; this is not a claim about arbitrary network delays.
  func settleDatagrams() throws {
    try specWait(group.next().scheduleTask(in: .milliseconds(100)) {}.futureResult)
  }

  func close() {
    shutdown.succeed(())
    try? accepted.finish().wait()
    try? proxyPlaintext.finish().wait()
    for inbox in datagramInboxes { try? inbox.finish().wait() }
    shutdownTestChannels(channels, group: group)
  }
}

private final class SpecSSCapture: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = ByteBuffer
  let decoder: ShadowsocksTCPWire
  let plaintext: SpecInbox<Data>

  init(decoder: ShadowsocksTCPWire, plaintext: SpecInbox<Data>) {
    self.decoder = decoder
    self.plaintext = plaintext
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    do {
      let decoded = try decoder.decodeInbound(Data(unwrapInboundIn(data).readableBytesView))
      if !decoded.data.isEmpty { plaintext.append(decoded.data) }
    } catch { context.fireErrorCaught(error) }
  }
}
