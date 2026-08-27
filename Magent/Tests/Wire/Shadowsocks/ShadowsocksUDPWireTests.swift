import Foundation
@testable import Magent
import NIOCore
import XCTest

/// Shadowsocks UDP Wire 数据报编解码契约测试。
final class ShadowsocksUDPWireTests: XCTestCase {

    private func makeNode(timeout: TimeInterval = 30) -> ProxyNode {
        ProxyNode(
            address: try! SocketAddress(ipAddress: "192.0.2.30", port: 8388),
            cipher: .aes256Gcm,
            password: "test-password",
            timeout: timeout
        )
    }

    func testUDPWireRoundTripsDatagramPayload() throws {
        let node = makeNode()
        let sender = try ShadowsocksUDPWire(proxyNode: node)
        let receiver = try ShadowsocksUDPWire(proxyNode: node)
        let target = NetworkAddress.domain("example.com", port: 53)
        let payload = Data([0x12, 0x34, 0x56])

        let packet = try sender.encodeOutbound(payload, address: target)
        let decoded = try receiver.decodeInbound(packet)

        XCTAssertEqual(decoded.address, target)
        XCTAssertEqual(decoded.data, payload)
    }

    func testUDPWireRoundTripsEveryAddressTypeAndUsesUniquePackets() throws {
        let node = makeNode()
        let sender = try ShadowsocksUDPWire(proxyNode: node)
        let receiver = try ShadowsocksUDPWire(proxyNode: node)
        let payload = Data("payload".utf8)
        let targets: [NetworkAddress] = [
            .ipv4(Data([1, 1, 1, 1]), port: 53),
            .ipv6(Data([0x20, 0x01, 0x0D, 0xB8] + Array(repeating: 0, count: 12)), port: 443),
            .domain("example.com", port: 8443),
        ]

        for target in targets {
            let firstPacket = try sender.encodeOutbound(payload, address: target)
            let secondPacket = try sender.encodeOutbound(payload, address: target)
            let decoded = try receiver.decodeInbound(firstPacket)

            XCTAssertNotEqual(firstPacket, secondPacket)
            XCTAssertEqual(decoded.address, target)
            XCTAssertEqual(decoded.data, payload)
        }
    }

    func testUDPWireRejectsMissingTargetTamperingAndWrongPassword() throws {
        let node = makeNode()
        let sender = try ShadowsocksUDPWire(proxyNode: node)
        XCTAssertThrowsError(try sender.encodeOutbound(Data([0x01]), address: nil))

        var tampered = try sender.encodeOutbound(Data([0x01, 0x02]), address: .domain("example.com", port: 53))
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        let receiver = try ShadowsocksUDPWire(proxyNode: node)
        XCTAssertThrowsError(try receiver.decodeInbound(tampered))

        let wrongNode = ProxyNode(
            id: node.id,
            address: node.address,
            cipher: node.cipher,
            password: "wrong-password",
            timeout: node.timeout
        )
        let validPacket = try sender.encodeOutbound(Data([0x03]), address: .domain("example.com", port: 53))
        XCTAssertThrowsError(try ShadowsocksUDPWire(proxyNode: wrongNode).decodeInbound(validPacket))
    }
}
