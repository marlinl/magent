import Foundation
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
}
