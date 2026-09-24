import Foundation
import NIOCore
import XCTest

@testable import Magent

/// Wire 公共目标地址与超时契约测试。
final class WireTests: XCTestCase {

  func testWireTargetAddressMatchesProxyNode() throws {
    let node = try ProxyNode(
      address: SocketAddress(ipAddress: "192.0.2.30", port: 8388),
      cipher: .aes256Gcm, password: "test-password", timeoutMilliseconds: 1_250)
    let tcpWire = try ShadowsocksTCPWire(proxyNode: node)
    let udpWire = try ShadowsocksUDPWire(proxyNode: node)

    XCTAssertEqual(
      tcpWire.getTargetAddress(), try SocketAddress(ipAddress: "192.0.2.30", port: 8388))
    XCTAssertEqual(
      udpWire.getTargetAddress(), try SocketAddress(ipAddress: "192.0.2.30", port: 8388))
    XCTAssertEqual(tcpWire.getTimeout(), 1_250)
    XCTAssertEqual(udpWire.getTimeout(), 1_250)
  }

  func testBothWiresPreserveValidatedTimeoutBounds() throws {
    for milliseconds: Int64 in [1, 30_000, 9_223_372_036_854] {
      let node = try ProxyNode(
        address: SocketAddress(ipAddress: "192.0.2.30", port: 8388),
        cipher: .aes256Gcm, password: "test-password", timeoutMilliseconds: milliseconds)

      XCTAssertEqual(try ShadowsocksTCPWire(proxyNode: node).getTimeout(), milliseconds)
      XCTAssertEqual(try ShadowsocksUDPWire(proxyNode: node).getTimeout(), milliseconds)
    }
  }
}
