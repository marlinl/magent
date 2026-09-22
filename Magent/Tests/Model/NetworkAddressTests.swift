import Foundation
import NIOCore
import XCTest

@testable import Magent

/// NetworkAddress 共享地址模型测试。
final class NetworkAddressTests: XCTestCase {

  /// IPv4 原始字节应转换为 dotted host，并保留端口。
  func testIPv4HostAndPort() {
    let address = NetworkAddress.ipv4(Data([127, 0, 0, 1]), port: 8080)

    XCTAssertEqual(address.host, "127.0.0.1")
    XCTAssertEqual(address.port, 8080)
  }

  /// IPv6 原始字节应转换为冒号分隔 host，并保留端口。
  func testIPv6HostAndPort() {
    let address = NetworkAddress.ipv6(
      Data([
        0x20, 0x01,
        0x0d, 0xb8,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x01,
      ]),
      port: 443
    )

    XCTAssertEqual(address.host, "2001:db8:0:0:0:0:0:1")
    XCTAssertEqual(address.port, 443)
  }

  /// IPv6 原始字节长度不合法时 host 返回空字符串。
  func testIPv6HostReturnsEmptyStringForInvalidRawByteCount() {
    let address = NetworkAddress.ipv6(Data([0x20, 0x01]), port: 443)

    XCTAssertEqual(address.host, "")
    XCTAssertEqual(address.port, 443)
  }

  /// 域名地址直接暴露 host 和 port。
  func testDomainHostAndPort() {
    let address = NetworkAddress.domain("example.com", port: 8388)

    XCTAssertEqual(address.host, "example.com")
    XCTAssertEqual(address.port, 8388)
  }

  /// 地址类型和端口都参与相等性判断。
  func testEquality() {
    XCTAssertEqual(
      NetworkAddress.domain("example.com", port: 443),
      NetworkAddress.domain("example.com", port: 443)
    )
    XCTAssertNotEqual(
      NetworkAddress.domain("example.com", port: 443),
      NetworkAddress.domain("example.com", port: 80)
    )
    XCTAssertNotEqual(
      NetworkAddress.ipv4(Data([127, 0, 0, 1]), port: 443),
      NetworkAddress.domain("127.0.0.1", port: 443)
    )
  }

  /// Hashable 行为需要与 Equatable 保持一致。
  func testHashable() {
    let values: Set<NetworkAddress> = [
      .domain("example.com", port: 443),
      .domain("example.com", port: 443),
      .domain("example.com", port: 80),
      .ipv4(Data([127, 0, 0, 1]), port: 443),
    ]

    XCTAssertEqual(values.count, 3)
  }

  /// 三种地址 case 都应支持 Codable 往返。
  func testCodableRoundTripForEveryCase() throws {
    let values: [NetworkAddress] = [
      .ipv4(Data([10, 0, 0, 1]), port: 80),
      .ipv6(
        Data([
          0x20, 0x01,
          0x0d, 0xb8,
          0x00, 0x00,
          0x00, 0x00,
          0x00, 0x00,
          0x00, 0x00,
          0x00, 0x00,
          0x00, 0x01,
        ]),
        port: 443
      ),
      .domain("example.com", port: 8388),
    ]

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    for value in values {
      let data = try encoder.encode(value)
      let decoded = try decoder.decode(NetworkAddress.self, from: data)

      XCTAssertEqual(decoded, value)
      XCTAssertEqual(decoded.host, value.host)
      XCTAssertEqual(decoded.port, value.port)
    }
  }

  /// UDP envelope 写入需要能把本地域名解析成 SocketAddress。
  func testDomainSocketAddressResolvesLocalhost() throws {
    let socketAddress = try NetworkAddress.domain("localhost", port: 5353).socketAddress()

    XCTAssertEqual(socketAddress.port, 5353)
  }

  /// 规范化必须幂等，保留端口和转发根点，并给匹配提供不含根点的视图。
  func testNormalizationPreservesForwardingNameAndMatchingView() throws {
    for name in ["API.Example.COM", "API.Example.COM."] {
      let normalized = try NetworkAddress.domain(name, port: 443).normalized()
      XCTAssertEqual(
        normalized, .domain(name.hasSuffix(".") ? "api.example.com." : "api.example.com", port: 443)
      )
      XCTAssertEqual(normalized.hostForMatching, "api.example.com")
      XCTAssertEqual(try normalized.normalized(), normalized)
    }
    XCTAssertEqual(
      try NetworkAddress.domain("0xfeed.Example", port: 53).normalized(),
      .domain("0xfeed.example", port: 53))
    XCTAssertEqual(
      try NetworkAddress.domain("XN--BCHER-KVA.Example.", port: 53).normalized(),
      .domain("xn--bcher-kva.example.", port: 53))
  }

  /// 相同的端点在原始 IPv4、Domain 文本和 mapped IPv6 中应有相同身份。
  func testNormalizationUnifiesNumericEndpointsWithoutChangingNativeIPv6() throws {
    for port in [0, 53, 65535] {
      let expected = NetworkAddress.ipv4(Data([192, 0, 2, 1]), port: port)
      let mapped = try XCTUnwrap(
        NetworkAddress(SocketAddress(ipAddress: "::ffff:192.0.2.1", port: port)))
      let ipv4 = try XCTUnwrap(NetworkAddress(SocketAddress(ipAddress: "192.0.2.1", port: port)))
      for address in [mapped, ipv4, .domain("192.0.2.1", port: port)] {
        XCTAssertEqual(try address.normalized(), expected)
        XCTAssertEqual(try address.normalized().normalized(), expected)
      }
    }
    for literal in ["::", "::1", "::192.0.2.1", "64:ff9b::192.0.2.1", "2001:db8::1"] {
      let address = try XCTUnwrap(NetworkAddress(SocketAddress(ipAddress: literal, port: 443)))
      XCTAssertEqual(try address.normalized(), address)
    }
    XCTAssertThrowsError(try NetworkAddress.ipv4(Data([1]), port: 53).normalized())
    XCTAssertThrowsError(
      try NetworkAddress.ipv6(Data(repeating: 0, count: 17), port: 53).normalized())
  }

  /// 数字歧义与非法根点不能通过裁剪后变成合法域名或进入宽松解析器。
  func testNormalizationRejectsAmbiguousAddressesAndMalformedNames() {
    for name in [
      "", "2130706433", "0x7f000001", "0X7F.0.0.1", "127.1", "127.000.0.1",
      "256.0.0.1", "1.2.3.4.5", "192.0.2.1.", "192..2.1", "::1", "[::1]", "fe80::1%en0",
      ".example.com", "example.com..", " example.com", "example.com ", "a..b", "你好.example",
    ] {
      XCTAssertThrowsError(try NetworkAddress.domain(name, port: 443).normalized(), name) { error in
        guard case MagentError.invalidAddress = error else {
          return XCTFail("Expected invalidAddress for \(name), got \(error)")
        }
      }
    }
  }

  /// 一个根点不占匹配名称的 253 字节预算；不截断过长标签或名称。
  func testNormalizationPreservesHostnameLengthBoundaries() throws {
    let name = [63, 63, 63, 61].map { String(repeating: "a", count: $0) }.joined(separator: ".")
    for host in ["A", name, name + "."] {
      XCTAssertEqual(
        try NetworkAddress.domain(host, port: 1).normalized(), .domain(host.lowercased(), port: 1))
    }
    for host in [String(repeating: "a", count: 64), name + "a", name + "a."] {
      XCTAssertThrowsError(try NetworkAddress.domain(host, port: 1).normalized())
    }
  }
}
