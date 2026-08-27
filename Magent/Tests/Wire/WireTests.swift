import Foundation
@testable import Magent
import NIOCore
import XCTest

/// Wire 公共目标地址与超时契约测试。
final class WireTests: XCTestCase {

    private func makeNode(timeout: TimeInterval = 30) -> ProxyNode {
        ProxyNode(
            address: try! SocketAddress(ipAddress: "192.0.2.30", port: 8388),
            cipher: .aes256Gcm,
            password: "test-password",
            timeout: timeout
        )
    }

    func testWireTargetAddressMatchesProxyNode() throws {
        let node = makeNode(timeout: 1.25)
        let tcpWire = try ShadowsocksTCPWire(proxyNode: node)
        let udpWire = try ShadowsocksUDPWire(proxyNode: node)

        XCTAssertEqual(tcpWire.getTargetAddress(), node.address)
        XCTAssertEqual(udpWire.getTargetAddress(), node.address)
        XCTAssertEqual(tcpWire.getTimeout(), 1_250)
        XCTAssertEqual(udpWire.getTimeout(), 1_250)
    }

    func testWireRejectsInvalidTimeout() {
        for timeout in [0, -1, .infinity, .nan] {
            let node = makeNode(timeout: timeout)
            XCTAssertThrowsError(try ShadowsocksTCPWire(proxyNode: node))
            XCTAssertThrowsError(try ShadowsocksUDPWire(proxyNode: node))
        }
    }
}
