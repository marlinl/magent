import Foundation
import Magent
import NIOCore
import XCTest

/// 节点构造、实际端点、密码字节、毫秒超时及协议 / 算法导入契约。
final class ProxyNodeTests: XCTestCase {

  func testIPv4NodePreservesExplicitConfiguration() throws {
    let node = try ProxyNode(
      id: XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555")),
      type: .shadowsocks,
      address: SocketAddress(ipAddress: "192.0.2.10", port: 8388),
      cipher: .aes128Gcm,
      password: "test-password",
      timeoutMilliseconds: 1_250
    )

    XCTAssertEqual(node.id.uuidString, "11111111-2222-3333-4444-555555555555")
    XCTAssertEqual(node.type, .shadowsocks)
    guard case .v4 = node.address else { return XCTFail("Expected an IPv4 endpoint") }
    XCTAssertEqual(node.address.ipAddress, "192.0.2.10")
    XCTAssertEqual(node.address.port, 8388)
    XCTAssertEqual(node.cipher, .aes128Gcm)
    XCTAssertEqual(node.password, "test-password")
    XCTAssertEqual(node.timeoutMilliseconds, 1_250)
  }

  func testIPv6NodePreservesScopeAndFlowInformation() throws {
    let endpoint = try SocketAddress(ipAddress: "fe80::1", port: 8388)
    guard case .v6(let ipv6) = endpoint else { return XCTFail("Expected an IPv6 endpoint") }
    var socket = ipv6.address
    socket.sin6_scope_id = 7
    socket.sin6_flowinfo = 17
    let node = try ProxyNode(
      address: SocketAddress(socket), cipher: .aes256Gcm, password: "test-password")

    guard case .v6(let stored) = node.address else { return XCTFail("IPv6 family was lost") }
    XCTAssertEqual(node.address.ipAddress, "fe80::1")
    XCTAssertEqual(node.address.port, 8388)
    XCTAssertEqual(stored.address.sin6_scope_id, 7)
    XCTAssertEqual(stored.address.sin6_flowinfo, 17)
  }

  func testMappedIPv6NodeKeepsActualEndpointFamily() throws {
    let node = try ProxyNode(
      address: SocketAddress(ipAddress: "::ffff:192.0.2.10", port: 8388),
      cipher: .aes256Gcm, password: "test-password")

    guard case .v6 = node.address else { return XCTFail("Mapped endpoint must remain IPv6") }
    XCTAssertEqual(
      node.address, try SocketAddress(ipAddress: "::ffff:192.0.2.10", port: 8388))
    XCTAssertNotEqual(node.address, try SocketAddress(ipAddress: "192.0.2.10", port: 8388))
  }

  func testNewNodesHaveDistinctIDsAndDefaultConfiguration() throws {
    let address = try SocketAddress(ipAddress: "192.0.2.10", port: 8388)
    let first = try ProxyNode(address: address, cipher: .aes256Gcm, password: "test-password")
    let second = try ProxyNode(address: address, cipher: .aes256Gcm, password: "test-password")

    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(first.type, .shadowsocks)
    XCTAssertEqual(first.timeoutMilliseconds, 30_000)
    XCTAssertEqual(second.timeoutMilliseconds, 30_000)
  }

  func testAcceptsPortBoundsAndKeepsEndpointValueIndependent() throws {
    for host in ["192.0.2.10", "2001:db8::10"] {
      for port in [1, 65535] {
        var address = try SocketAddress(ipAddress: host, port: port)
        let node = try ProxyNode(
          address: address, cipher: .aes256Gcm, password: "test-password")
        address.port = 0

        XCTAssertEqual(node.address.port, port)
        var copy = node.address
        copy.port = 0
        XCTAssertEqual(node.address.port, port)
      }
    }
  }

  func testRejectsUnixEndpointAndZeroPortsWithoutLeakingPassword() throws {
    let addresses = try [
      SocketAddress(unixDomainSocketPath: "/tmp/magent-proxy-node-test.sock"),
      SocketAddress(ipAddress: "192.0.2.10", port: 0),
      SocketAddress(ipAddress: "2001:db8::10", port: 0),
    ]
    for address in addresses {
      XCTAssertThrowsError(
        try ProxyNode(address: address, cipher: .aes256Gcm, password: "secret-placeholder")
      ) { error in
        XCTAssertEqual(
          error as? MagentError,
          .invalidPolicy(
            "proxy node address must be an IPv4 or IPv6 endpoint with port in 1...65535"))
      }
    }
  }

  func testTimeoutBoundsConvertToExactNanoseconds() throws {
    let cases: [(milliseconds: Int64, nanoseconds: Int64)] = [
      (1, 1_000_000),
      (30_000, 30_000_000_000),
      (9_223_372_036_854, 9_223_372_036_854_000_000),
    ]
    for (milliseconds, nanoseconds) in cases {
      let node = try ProxyNode(
        address: SocketAddress(ipAddress: "192.0.2.10", port: 8388),
        cipher: .aes256Gcm, password: "test-password", timeoutMilliseconds: milliseconds)

      XCTAssertEqual(node.timeoutMilliseconds, milliseconds)
      XCTAssertEqual(TimeAmount.milliseconds(node.timeoutMilliseconds).nanoseconds, nanoseconds)
    }
  }

  func testRejectsNonpositiveAndOverflowingTimeoutsWithoutLeakingPassword() throws {
    let address = try SocketAddress(ipAddress: "192.0.2.10", port: 8388)
    for milliseconds: Int64 in [Int64.min, -1, 0, 9_223_372_036_855, Int64.max] {
      XCTAssertThrowsError(
        try ProxyNode(
          address: address, cipher: .aes256Gcm, password: "secret-placeholder",
          timeoutMilliseconds: milliseconds)
      ) { error in
        XCTAssertEqual(
          error as? MagentError,
          .invalidPolicy("proxy node timeoutMilliseconds must be in 1...9223372036854"))
      }
    }
  }

  func testRejectsEmptyPassword() throws {
    let address = try SocketAddress(ipAddress: "192.0.2.10", port: 8388)
    XCTAssertThrowsError(try ProxyNode(address: address, cipher: .aes256Gcm, password: "")) {
      error in
      XCTAssertEqual(error as? MagentError, .invalidPolicy("proxy node password must not be empty"))
    }
  }

  func testPasswordPreservesWhitespaceAndUnicodeBytesForEveryCipher() throws {
    let cases: [(password: String, bytes: [UInt8])] = [
      (" ", [0x20]),
      (" \t\n ", [0x20, 0x09, 0x0A, 0x20]),
      ("\u{00E9}", [0xC3, 0xA9]),
      ("e\u{0301}", [0x65, 0xCC, 0x81]),
      (
        "0123456789012345678901234567890123456789",
        Array("0123456789012345678901234567890123456789".utf8)
      ),
    ]
    for cipher in ProxyCipher.allCases {
      for (password, bytes) in cases {
        let node = try ProxyNode(
          address: SocketAddress(ipAddress: "192.0.2.10", port: 8388),
          cipher: cipher, password: password)
        XCTAssertEqual(Array(node.password.utf8), bytes)
      }
    }
  }

  func testDescriptionsExposeOnlyNodeIdentity() throws {
    let node = try ProxyNode(
      id: XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555")),
      address: SocketAddress(ipAddress: "192.0.2.10", port: 8388),
      cipher: .aes256Gcm, password: "secret-placeholder")

    XCTAssertEqual(String(describing: node), "ProxyNode(id: 11111111-2222-3333-4444-555555555555)")
    XCTAssertEqual(String(reflecting: node), "ProxyNode(id: 11111111-2222-3333-4444-555555555555)")
  }

  func testNodeTypeRawValueAndCodableContract() throws {
    XCTAssertEqual(ProxyNodeType.allCases, [.shadowsocks])
    XCTAssertEqual(ProxyNodeType.shadowsocks.rawValue, "shadowsocks")
    XCTAssertEqual(ProxyNodeType(rawValue: "shadowsocks"), .shadowsocks)
    XCTAssertEqual(
      try JSONEncoder().encode(ProxyNodeType.shadowsocks), Data("\"shadowsocks\"".utf8))
    XCTAssertEqual(
      try JSONDecoder().decode(ProxyNodeType.self, from: Data("\"shadowsocks\"".utf8)),
      .shadowsocks)
    for rawValue in ["", "SHADOWSOCKS", "socks5", "direct", "unknown"] {
      XCTAssertNil(ProxyNodeType(rawValue: rawValue))
      XCTAssertThrowsError(
        try JSONDecoder().decode(ProxyNodeType.self, from: JSONEncoder().encode(rawValue)))
    }
  }

  func testCipherParametersAndSerialization() throws {
    let cases: [(ProxyCipher, String, Int, Int, Int, Int)] = [
      (.aes128Gcm, "aes-128-gcm", 16, 16, 12, 16),
      (.aes256Gcm, "aes-256-gcm", 32, 32, 12, 16),
      (.chacha20IetfPoly1305, "chacha20-ietf-poly1305", 32, 32, 12, 16),
      (.xchacha20IetfPoly1305, "xchacha20-ietf-poly1305", 32, 32, 24, 16),
    ]
    XCTAssertEqual(
      ProxyCipher.allCases, [.aes128Gcm, .aes256Gcm, .chacha20IetfPoly1305, .xchacha20IetfPoly1305])
    for (cipher, rawValue, keySize, saltSize, nonceSize, tagSize) in cases {
      XCTAssertEqual(cipher.keySize, keySize)
      XCTAssertEqual(cipher.saltSize, saltSize)
      XCTAssertEqual(cipher.nonceSize, nonceSize)
      XCTAssertEqual(cipher.tagSize, tagSize)
      XCTAssertEqual(cipher.rawValue, rawValue)
      XCTAssertEqual(ProxyCipher(rawValue: rawValue), cipher)
      XCTAssertEqual(try JSONEncoder().encode(cipher), Data("\"\(rawValue)\"".utf8))
      XCTAssertEqual(
        try JSONDecoder().decode(ProxyCipher.self, from: Data("\"\(rawValue)\"".utf8)), cipher)
    }
  }

  func testUnknownCipherIsRejectedWithoutFallback() throws {
    for rawValue in ["", "AES-128-GCM", "aes-128-cfb", "unknown"] {
      XCTAssertNil(ProxyCipher(rawValue: rawValue))
      XCTAssertThrowsError(
        try JSONDecoder().decode(ProxyCipher.self, from: JSONEncoder().encode(rawValue)))
    }
  }
}
