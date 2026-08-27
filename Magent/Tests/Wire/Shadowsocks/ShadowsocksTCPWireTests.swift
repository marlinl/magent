import Foundation
@testable import Magent
import NIOCore
import XCTest

/// Shadowsocks TCP Wire 启动与流式编解码契约测试。
final class ShadowsocksTCPWireTests: XCTestCase {

    private func makeNode(timeout: TimeInterval = 30) -> ProxyNode {
        ProxyNode(
            address: try! SocketAddress(ipAddress: "192.0.2.30", port: 8388),
            cipher: .aes256Gcm,
            password: "test-password",
            timeout: timeout
        )
    }

    func testTCPWireStartIsIdempotentAndEncodingRequiresStart() throws {
        let node = makeNode()
        let wire = try ShadowsocksTCPWire(proxyNode: node)

        do {
            _ = try wire.encodeOutbound(Data([0x01]), address: nil)
            XCTFail("Expected encode before start to throw")
        } catch {
            XCTAssertEqual(
                error as? MagentError,
                .invalidOptions("Shadowsocks TCP wire must be started before encoding data")
            )
        }
        XCTAssertThrowsError(try wire.decodeInbound(Data([0x01])))

        let first = try wire.start(handshake: .domain("example.com", port: 443))
        let second = try wire.start(handshake: .domain("example.org", port: 443))

        XCTAssertNotNil(first)
        XCTAssertFalse(first?.isEmpty ?? true)
        XCTAssertEqual(second, Data())

        let encoded = try wire.encodeOutbound(Data([0x01]), address: nil)
        XCTAssertFalse(encoded.isEmpty)
    }

    func testTCPWireDecodesPartialAndMultipleInboundPayloads() throws {
        let node = makeNode()
        let server = try ShadowsocksTCPWire(proxyNode: node)
        let client = try ShadowsocksTCPWire(proxyNode: node)

        let destination = NetworkAddress.domain("ignored.example", port: 443)
        let startData = try server.start(handshake: destination)
        var inbound = try XCTUnwrap(startData)
        _ = try server.start(handshake: .domain("ignored-again.example", port: 443))
        inbound.append(try server.encodeOutbound(Data([0x01, 0x02]), address: nil))
        inbound.append(try server.encodeOutbound(Data([0x03]), address: nil))
        _ = try client.start(handshake: destination)

        let splitIndex = Swift.min(8, inbound.count)
        let partial = Data(inbound.prefix(splitIndex))
        let remaining = Data(inbound.dropFirst(splitIndex))

        let partialDecoded = try client.decodeInbound(partial)
        XCTAssertTrue(partialDecoded.data.isEmpty)

        let decoded = try client.decodeInbound(remaining)
        let addressBytes = try NetworkAddress
            .domain("ignored.example", port: 443)
            .shadowsocksAddressBytes()
        var expectedData = addressBytes
        expectedData.append(Data([0x01, 0x02]))
        expectedData.append(Data([0x03]))

        XCTAssertEqual(decoded.data, expectedData)
    }

    func testTCPWireRejectsTamperedInboundFrame() throws {
        let node = makeNode()
        let server = try ShadowsocksTCPWire(proxyNode: node)
        let client = try ShadowsocksTCPWire(proxyNode: node)
        let destination = NetworkAddress.domain("example.com", port: 443)
        var inbound = try XCTUnwrap(server.start(handshake: destination))
        inbound.append(try server.encodeOutbound(Data("payload".utf8), address: nil))
        inbound[inbound.index(before: inbound.endIndex)] ^= 0x01
        _ = try client.start(handshake: destination)

        XCTAssertThrowsError(try client.decodeInbound(inbound))
    }
}
