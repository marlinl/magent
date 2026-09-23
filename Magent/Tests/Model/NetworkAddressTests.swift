import NIOCore
import XCTest

@testable import Magent

/// NetworkAddress 的文本输入、逻辑身份和按需端点转换契约。
final class NetworkAddressTests: XCTestCase {

  /// 域名保持未解析；数值地址只存储 NIO 端点，视图使用同一个端口。
  func testValidAddressStorageAndViews() throws {
    let domain = try NetworkAddress(host: "Example.COM.", port: 443)
    let ipv4 = try NetworkAddress(host: "192.0.2.1", port: 53)
    let ipv6 = try NetworkAddress(host: "2001:db8::1", port: 65535)

    guard case .domain("example.com.", port: 443) = domain.address else {
      return XCTFail("域名必须保留规范化名称和端口")
    }
    guard case .ip(.v4) = ipv4.address, case .ip(.v6) = ipv6.address else {
      return XCTFail("数值地址必须存储对应地址族的 NIO 端点")
    }
    XCTAssertEqual(domain.host, "example.com.")
    XCTAssertEqual(domain.port, 443)
    XCTAssertEqual(ipv4.host, "192.0.2.1")
    XCTAssertEqual(ipv4.port, 53)
    XCTAssertEqual(ipv6.port, 65535)
    XCTAssertEqual(try ipv4.socketAddress, try SocketAddress(ipAddress: "192.0.2.1", port: 53))
    XCTAssertEqual(try ipv6.socketAddress, try SocketAddress(ipAddress: "2001:db8::1", port: 65535))
  }

  /// 二进制 IP 经 NIO 转为数值文本后，与 HTTP 文本及映射 IPv6 具有相同身份。
  func testBinaryTextAndMappedIPv6HaveOneIdentity() throws {
    let binarySocket = try SocketAddress(
      packedIPAddress: ByteBuffer(bytes: [192, 0, 2, 1]), port: 443)
    let binaryText = try XCTUnwrap(binarySocket.ipAddress)
    let values = try [
      NetworkAddress(host: "192.0.2.1", port: 443),
      NetworkAddress(host: binaryText, port: 443),
      NetworkAddress(host: "::ffff:192.0.2.1", port: 443),
      NetworkAddress(host: "::ffff:c000:201", port: 443),
    ]

    XCTAssertEqual(binaryText, "192.0.2.1")
    XCTAssertEqual(Set(values).count, 1)
    for value in values {
      XCTAssertEqual(value.host, "192.0.2.1")
      XCTAssertEqual(try value.socketAddress, try SocketAddress(ipAddress: "192.0.2.1", port: 443))
      guard case .ip(.v4) = value.address else {
        return XCTFail("映射 IPv6 应以 IPv4 存储")
      }
    }
  }

  /// IPv6 兼容地址和 NAT64 地址不能被映射地址规则误转成 IPv4。
  func testOtherIPv6FormsKeepTheirAddressFamily() throws {
    for text in ["2001:db8::1", "::192.0.2.1", "64:ff9b::192.0.2.1"] {
      let value = try NetworkAddress(host: text, port: 443)
      guard case .v6 = try value.socketAddress else {
        return XCTFail("\(text) 必须保持 IPv6")
      }
    }
    XCTAssertEqual(
      try NetworkAddress(host: "2001:0DB8:0:0:0:0:0:1", port: 443),
      try NetworkAddress(host: "2001:db8::1", port: 443))

    let binarySocket = try SocketAddress(
      packedIPAddress: ByteBuffer(bytes: [
        0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
      ]), port: 443)
    let binaryText = try XCTUnwrap(binarySocket.ipAddress)
    XCTAssertEqual(
      try NetworkAddress(host: binaryText, port: 443),
      try NetworkAddress(host: "2001:db8::1", port: 443))
  }

  /// 数字歧义必须在对应的 IP 分支失败，不能回退成域名。
  func testRejectsAmbiguousAndMalformedNumericText() throws {
    for host in [
      "127.1", "2130706433", "127.000.0.1", "0177.0.0.1", "0x7f000001",
      "0X7F.0.0.1", "0x", "256.0.0.1", "1.2.3.4.5", "192..2.1",
      "192.0.2.1.", "::ffff:192.000.2.1",
    ] {
      XCTAssertThrowsError(try NetworkAddress(host: host, port: 443), host) { error in
        guard case MagentError.invalidAddress = error else {
          return XCTFail("\(host) 应由模型策略拒绝，得到 \(error)")
        }
      }
    }
    let ordinaryDomain = try NetworkAddress(host: "0xfeed.Example", port: 443)
    XCTAssertEqual(ordinaryDomain.host, "0xfeed.example")
    guard case .domain = ordinaryDomain.address else {
      return XCTFail("普通标签不能被当作数值地址")
    }
  }

  /// IPv6 的非法外层语法由模型拒绝；NIO 解析失败保持原始错误类型。
  func testIPv6PolicyAndNIOErrorsStayDistinct() {
    for host in ["[::1]", "fe80::1%en0", "::1\u{0}", "::1 "] {
      XCTAssertThrowsError(try NetworkAddress(host: host, port: 443), host) { error in
        guard case MagentError.invalidAddress = error else {
          return XCTFail("\(host) 应由模型策略拒绝，得到 \(error)")
        }
      }
    }
    XCTAssertThrowsError(try NetworkAddress(host: "2001:::1", port: 443)) { error in
      XCTAssertEqual(error as? SocketAddressError, .failedToParseIPString("2001:::1"))
    }
  }

  /// 域名大小写和根点在构造时确定；空标签和多余根点不能被裁剪接受。
  func testDomainCanonicalizationAndRootDot() throws {
    let name = try NetworkAddress(host: "API.Example.COM", port: 443)
    let rootName = try NetworkAddress(host: "API.Example.COM.", port: 443)
    XCTAssertEqual(name.host, "api.example.com")
    XCTAssertEqual(rootName.host, "api.example.com.")
    XCTAssertNotEqual(name, rootName)
    XCTAssertEqual(
      try NetworkAddress(host: "XN--BCHER-KVA.Example.", port: 53).host,
      "xn--bcher-kva.example.")

    for host in [".example.com", "a..b", "example.com..", "-a.example", "a-.example"] {
      XCTAssertThrowsError(try NetworkAddress(host: host, port: 443), host)
    }
  }

  /// 长度按 ASCII 字节计算，一个合法根点不占 253 字节的名称预算。
  func testDomainLengthBoundaries() throws {
    let maxName = [63, 63, 63, 61].map { String(repeating: "a", count: $0) }
      .joined(separator: ".")
    XCTAssertEqual(maxName.utf8.count, 253)
    XCTAssertEqual(try NetworkAddress(host: "a", port: 1).host, "a")
    XCTAssertEqual(try NetworkAddress(host: String(repeating: "a", count: 63), port: 1).port, 1)
    XCTAssertEqual(try NetworkAddress(host: maxName, port: 1).host, maxName)
    XCTAssertEqual(try NetworkAddress(host: maxName + ".", port: 1).host, maxName + ".")
    for host in [String(repeating: "a", count: 64), maxName + "a", maxName + "a."] {
      XCTAssertThrowsError(try NetworkAddress(host: host, port: 1), host)
    }
  }

  /// 非 ASCII、空白、控制字符和非法分隔符不能经小写或截断变成合法域名。
  func testRejectsInvalidDomainCharacters() {
    for host in [
      "", " example.com", "example.com ", "a\tb", "a\nb", "a\u{0}b", "你好.example",
      "K.example", "a_b", "a/b", "a\\b", "a@b", "a[b", "a]b", "a%b",
    ] {
      XCTAssertThrowsError(try NetworkAddress(host: host, port: 443), host) { error in
        guard case MagentError.invalidAddress = error else {
          return XCTFail("\(host) 应由模型策略拒绝，得到 \(error)")
        }
      }
    }
  }

  /// 端口、名称大小写和根点都按契约参与逻辑身份及 Set 去重。
  func testPortBoundsEqualityAndHashableIdentity() throws {
    for port in [UInt16(0), 1, 65535] {
      XCTAssertEqual(try NetworkAddress(host: "example.com", port: port).port, port)
      XCTAssertEqual(try NetworkAddress(host: "192.0.2.1", port: port).port, port)
    }
    let values = try [
      NetworkAddress(host: "API.Example.COM", port: 443),
      NetworkAddress(host: "api.example.com", port: 443),
      NetworkAddress(host: "api.example.com.", port: 443),
      NetworkAddress(host: "api.example.com", port: 80),
      NetworkAddress(host: "192.0.2.1", port: 443),
    ]
    XCTAssertEqual(values[0], values[1])
    XCTAssertNotEqual(values[0], values[2])
    XCTAssertNotEqual(values[0], values[3])
    XCTAssertNotEqual(values[0], values[4])
    XCTAssertEqual(Set(values).count, 4)
  }

  /// 读取 IP 端点不会改变模型；调用方修改结果副本也不会修改存储值。
  func testRepeatedIPConversionAndCopyIsolation() throws {
    let value = try NetworkAddress(host: "192.0.2.1", port: 443)
    let expected = try SocketAddress(ipAddress: "192.0.2.1", port: 443)
    XCTAssertEqual(try value.socketAddress, expected)
    var copy = try value.socketAddress
    copy = try SocketAddress(ipAddress: "198.51.100.1", port: 80)
    XCTAssertNotEqual(copy, expected)
    XCTAssertEqual(try value.socketAddress, expected)
    XCTAssertEqual(value.host, "192.0.2.1")
    XCTAssertEqual(value.port, 443)
  }

  /// 域名只在显式转换时通过 NIO 解析，转换结果不替换逻辑域名身份。
  func testDomainSocketAddressResolvesWithoutChangingIdentity() throws {
    let value = try NetworkAddress(host: "LOCALHOST", port: 5353)
    let expected = try NetworkAddress(host: "localhost", port: 5353)
    XCTAssertEqual(value, expected)
    let resolved = try value.socketAddress
    XCTAssertEqual(resolved.port, 5353)
    XCTAssertNotNil(resolved.ipAddress)
    XCTAssertEqual(value.host, "localhost")
    XCTAssertNotEqual(value, try NetworkAddress(host: "127.0.0.1", port: 5353))
    XCTAssertEqual(value, expected)
    XCTAssertEqual(Set([value, expected]).count, 1)
  }
}
