//
//  Socks5ProtocolTests.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Unit and integration tests for SOCKS5 protocol/server behavior.
//

import XCTest
@testable import MagentX
import MagentCore
import MagentLocal
import MagentCrypto

// MARK: - 测试辅助方法

extension Data {
    static func socks5Greeting(methods: [UInt8]) -> Data {
        Data([0x05, UInt8(methods.count)] + methods)
    }

    static func socks5AuthRequest(username: String, password: String) -> Data {
        let uData = Data(username.utf8)
        let pData = Data(password.utf8)
        return Data([0x01, UInt8(uData.count)]) + uData + Data([UInt8(pData.count)]) + pData
    }

    static func socks5Connect(address: ProxyAddress) -> Data {
        Data([0x05, 0x01, 0x00]) + address.encode()
    }
}

// MARK: - 阶段 1：握手

final class Socks5HandshakeTests: XCTestCase {

    // MARK: 无认证

    func testHandshakeNoAuth() {
        let proto = Socks5Protocol(authMode: .noAuth)
        let outputs = proto.feed(.socks5Greeting(methods: [0x00]))

        XCTAssertEqual(outputs, [.send(Data([0x05, 0x00]))])
        XCTAssertEqual(proto.state, .request)
    }

    func testHandshakeNoAuthAmongMultipleMethods() {
        let proto = Socks5Protocol(authMode: .noAuth)
        let outputs = proto.feed(.socks5Greeting(methods: [0x01, 0x00, 0x02]))

        XCTAssertEqual(outputs, [.send(Data([0x05, 0x00]))])
        XCTAssertEqual(proto.state, .request)
    }

    func testHandshakeNoAcceptableMethod() {
        let proto = Socks5Protocol(authMode: .noAuth)
        let outputs = proto.feed(.socks5Greeting(methods: [0x01, 0x02]))

        XCTAssertEqual(outputs, [.sendAndClose(Data([0x05, 0xFF]))])
        XCTAssertEqual(proto.state, .closed)
    }

    // MARK: 非法版本

    func testHandshakeInvalidVersion() {
        let proto = Socks5Protocol(authMode: .noAuth)
        let outputs = proto.feed(Data([0x04, 0x01, 0x00]))

        XCTAssertEqual(outputs, [.close])
        XCTAssertEqual(proto.state, .closed)
    }

    // MARK: 分段数据

    func testHandshakePartialThenComplete() {
        let proto = Socks5Protocol(authMode: .noAuth)

        // 只发送第一个字节
        let out1 = proto.feed(Data([0x05]))
        XCTAssertTrue(out1.isEmpty)

        // 发送剩余握手数据
        let out2 = proto.feed(Data([0x01, 0x00]))
        XCTAssertEqual(out2, [.send(Data([0x05, 0x00]))])
        XCTAssertEqual(proto.state, .request)
    }

    // MARK: 握手与 CONNECT 粘包

    func testHandshakePipelinedWithConnect() {
        let proto = Socks5Protocol(authMode: .noAuth)
        let target = ProxyAddress.domain("example.com", port: 443)

        var input = Data([0x05, 0x01, 0x00]) // 握手：VER=5, NMETHODS=1, METHOD=NO_AUTH
        input.append(.socks5Connect(address: target))

        let outputs = proto.feed(input)
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(outputs[0], .send(Data([0x05, 0x00])))
        XCTAssertEqual(outputs[1], .connect(target))
        XCTAssertEqual(proto.state, .connecting)
    }

    // MARK: 用户名/密码模式

    func testHandshakeSelectsUsernamePassword() {
        let proto = Socks5Protocol(authMode: .usernamePassword(username: "admin", password: "pass"))
        let outputs = proto.feed(.socks5Greeting(methods: [0x02]))

        XCTAssertEqual(outputs, [.send(Data([0x05, 0x02]))])
        XCTAssertEqual(proto.state, .auth)
    }

    func testHandshakeFallsBackToNoAuthWhenUPNotOffered() {
        let proto = Socks5Protocol(authMode: .usernamePassword(username: "admin", password: "pass"))
        let outputs = proto.feed(.socks5Greeting(methods: [0x00]))

        XCTAssertEqual(outputs, [.send(Data([0x05, 0x00]))])
        XCTAssertEqual(proto.state, .request)
    }

    func testHandshakeUPModeNoAcceptableMethod() {
        let proto = Socks5Protocol(authMode: .usernamePassword(username: "admin", password: "pass"))
        let outputs = proto.feed(.socks5Greeting(methods: [0x03, 0x80]))

        XCTAssertEqual(outputs, [.sendAndClose(Data([0x05, 0xFF]))])
        XCTAssertEqual(proto.state, .closed)
    }
}

// MARK: - 阶段 2：认证（RFC 1929）

final class Socks5AuthTests: XCTestCase {

    private func makeAuthProto(user: String = "admin", pass: String = "secret") -> Socks5Protocol {
        let proto = Socks5Protocol(authMode: .usernamePassword(username: user, password: pass))
        _ = proto.feed(.socks5Greeting(methods: [0x02])) // → .auth
        return proto
    }

    func testAuthCorrectCredentials() {
        let proto = makeAuthProto()
        let outputs = proto.feed(.socks5AuthRequest(username: "admin", password: "secret"))

        XCTAssertEqual(outputs, [.send(Data([0x01, 0x00]))])
        XCTAssertEqual(proto.state, .request)
    }

    func testAuthWrongUsername() {
        let proto = makeAuthProto()
        let outputs = proto.feed(.socks5AuthRequest(username: "wrong", password: "secret"))

        XCTAssertEqual(outputs, [.sendAndClose(Data([0x01, 0xFF]))])
        XCTAssertEqual(proto.state, .closed)
    }

    func testAuthWrongPassword() {
        let proto = makeAuthProto()
        let outputs = proto.feed(.socks5AuthRequest(username: "admin", password: "wrong"))

        XCTAssertEqual(outputs, [.sendAndClose(Data([0x01, 0xFF]))])
        XCTAssertEqual(proto.state, .closed)
    }

    func testAuthInvalidSubNegotiationVersion() {
        let proto = makeAuthProto()
        // RFC 1929 中 VER 应为 0x01
        let outputs = proto.feed(Data([0x05, 0x05, 0x61, 0x64, 0x6D, 0x69, 0x6E]))

        XCTAssertEqual(outputs, [.sendAndClose(Data([0x01, 0xFF]))])
        XCTAssertEqual(proto.state, .closed)
    }

    func testAuthPartialData() {
        let proto = makeAuthProto()

        // 前 3 字节（VER + ULEN + 部分用户名）
        let out1 = proto.feed(Data([0x01, 0x05, 0x61, 0x64]))
        XCTAssertTrue(out1.isEmpty)

        // 剩余用户名 + PLEN + 密码
        let out2 = proto.feed(Data([0x6D, 0x69, 0x6E, 0x06, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74]))
        XCTAssertEqual(out2, [.send(Data([0x01, 0x00]))])
        XCTAssertEqual(proto.state, .request)
    }

    func testAuthThenPipelinedConnect() {
        let proto = makeAuthProto()
        let target = ProxyAddress.domain("example.com", port: 80)

        var input = Data.socks5AuthRequest(username: "admin", password: "secret")
        input.append(.socks5Connect(address: target))

        let outputs = proto.feed(input)
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(outputs[0], .send(Data([0x01, 0x00])))
        XCTAssertEqual(outputs[1], .connect(target))
        XCTAssertEqual(proto.state, .connecting)
    }

    func testAuthEmptyCredentials() {
        let proto = Socks5Protocol(authMode: .usernamePassword(username: "", password: ""))
        _ = proto.feed(.socks5Greeting(methods: [0x02]))

        // 空用户名和空密码（ULEN=0，PLEN=0）
        let outputs = proto.feed(Data([0x01, 0x00, 0x00]))
        XCTAssertEqual(outputs, [.send(Data([0x01, 0x00]))])
        XCTAssertEqual(proto.state, .request)
    }
}

// MARK: - 阶段 3：连接请求

final class Socks5ConnectTests: XCTestCase {

    private func makeRequestProto() -> Socks5Protocol {
        let proto = Socks5Protocol(authMode: .noAuth)
        _ = proto.feed(.socks5Greeting(methods: [0x00])) // → .request
        return proto
    }

    // MARK: IPv4

    func testConnectIPv4() {
        let proto = makeRequestProto()
        let target = ProxyAddress.ipv4(IPv4Address("127.0.0.1"), port: 8080)

        let outputs = proto.feed(.socks5Connect(address: target))
        XCTAssertEqual(outputs, [.connect(target)])
        XCTAssertEqual(proto.state, .connecting)
    }

    // MARK: IPv6

    func testConnectIPv6() {
        let proto = makeRequestProto()
        let addr = IPv6Address(Data(repeating: 0x42, count: 16))!
        let target = ProxyAddress.ipv6(addr, port: 443)

        let outputs = proto.feed(.socks5Connect(address: target))
        XCTAssertEqual(outputs, [.connect(target)])
        XCTAssertEqual(proto.state, .connecting)
    }

    // MARK: 域名

    func testConnectDomain() {
        let proto = makeRequestProto()
        let target = ProxyAddress.domain("example.com", port: 443)

        let outputs = proto.feed(.socks5Connect(address: target))
        XCTAssertEqual(outputs, [.connect(target)])
        XCTAssertEqual(proto.state, .connecting)
    }

    // MARK: 不支持的命令

    func testConnectBindNotSupported() {
        let proto = makeRequestProto()
        let input = Data([0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50])
        let outputs = proto.feed(input)

        XCTAssertEqual(outputs.count, 1)
        if case .sendAndClose(let data) = outputs[0] {
            // REP = 0x07（不支持该命令）
            XCTAssertEqual(data[1], 0x07)
        } else {
            XCTFail("Expected sendAndClose")
        }
        XCTAssertEqual(proto.state, .closed)
    }

    func testConnectUDPAssociateNotSupported() {
        let proto = makeRequestProto()
        let input = Data([0x05, 0x03, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50])
        let outputs = proto.feed(input)

        XCTAssertEqual(outputs.count, 1)
        if case .sendAndClose(let data) = outputs[0] {
            XCTAssertEqual(data[1], 0x07)
        } else {
            XCTFail("Expected sendAndClose")
        }
        XCTAssertEqual(proto.state, .closed)
    }

    // MARK: 请求中的非法版本

    func testConnectInvalidVersion() {
        let proto = makeRequestProto()
        let input = Data([0x04, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50])
        let outputs = proto.feed(input)

        XCTAssertEqual(outputs.count, 1)
        if case .sendAndClose(let data) = outputs[0] {
            XCTAssertEqual(data[1], 0x01) // 通用 SOCKS 服务失败
        } else {
            XCTFail("Expected sendAndClose")
        }
        XCTAssertEqual(proto.state, .closed)
    }

    // MARK: 分段数据

    func testConnectPartialThenComplete() {
        let proto = makeRequestProto()
        let target = ProxyAddress.domain("test.com", port: 80)
        let full = Data.socks5Connect(address: target)

        // 前 3 个字节
        let out1 = proto.feed(Data(full.prefix(3)))
        XCTAssertTrue(out1.isEmpty)

        // 剩余字节
        let out2 = proto.feed(Data(full.dropFirst(3)))
        XCTAssertEqual(out2, [.connect(target)])
        XCTAssertEqual(proto.state, .connecting)
    }

    // MARK: 不支持的地址类型

    func testConnectUnsupportedAddressType() {
        let proto = makeRequestProto()
        let input = Data([0x05, 0x01, 0x00, 0x05, 0x00])
        let outputs = proto.feed(input)

        XCTAssertEqual(outputs.count, 1)
        if case .sendAndClose(let data) = outputs[0] {
            XCTAssertEqual(data[1], 0x08) // 不支持该地址类型
        } else {
            XCTFail("Expected sendAndClose")
        }
        XCTAssertEqual(proto.state, .closed)
    }
}

// MARK: - 阶段 4：中继

final class Socks5RelayTests: XCTestCase {

    private func makeRelayProto() -> Socks5Protocol {
        let proto = Socks5Protocol(authMode: .noAuth)
        _ = proto.feed(.socks5Greeting(methods: [0x00]))
        _ = proto.feed(.socks5Connect(address: .domain("example.com", port: 443)))
        // 状态 = .connecting
        return proto
    }

    func testConnectingBuffersData() {
        let proto = makeRelayProto()

        // 隧道建立期间到达的数据
        let out = proto.feed(Data("GET / HTTP/1.1\r\n".utf8))
        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(proto.state, .connecting)
    }

    func testEnterRelayEmitsSuccessAndBufferedData() {
        let proto = makeRelayProto()
        let requestData = Data("GET / HTTP/1.1\r\n".utf8)
        _ = proto.feed(requestData)

        let outputs = proto.enterRelay()
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(outputs[0], .send(Socks5Protocol.successReply()))
        XCTAssertEqual(outputs[1], .relayOutbound(requestData))
        XCTAssertEqual(proto.state, .relay)
    }

    func testEnterRelayNoBufferedData() {
        let proto = makeRelayProto()

        let outputs = proto.enterRelay()
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs[0], .send(Socks5Protocol.successReply()))
        XCTAssertEqual(proto.state, .relay)
    }

    func testEnterRelayFailed() {
        let proto = makeRelayProto()

        let outputs = proto.enterRelayFailed(rep: 0x04)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs[0], .sendAndClose(Socks5Protocol.errorReply(rep: 0x04)))
        XCTAssertEqual(proto.state, .closed)
    }

    func testEnterRelayFailedDiscardsBufferedData() {
        let proto = makeRelayProto()
        _ = proto.feed(Data("should be discarded".utf8))

        let outputs = proto.enterRelayFailed()
        XCTAssertEqual(outputs.count, 1)
        if case .sendAndClose = outputs[0] {
            // OK
        } else {
            XCTFail("Expected sendAndClose")
        }
        XCTAssertEqual(proto.state, .closed)
    }

    func testRelayData() {
        let proto = makeRelayProto()
        _ = proto.enterRelay()

        let payload = Data("hello".utf8)
        let outputs = proto.feed(payload)
        XCTAssertEqual(outputs, [.relayOutbound(payload)])
    }

    func testRelayMultipleFeeds() {
        let proto = makeRelayProto()
        _ = proto.enterRelay()

        let out1 = proto.feed(Data("hello".utf8))
        XCTAssertEqual(out1, [.relayOutbound(Data("hello".utf8))])

        let out2 = proto.feed(Data(" world".utf8))
        XCTAssertEqual(out2, [.relayOutbound(Data(" world".utf8))])
    }

    func testClosedIgnoresData() {
        let proto = makeRelayProto()
        proto.close()

        let outputs = proto.feed(Data("garbage".utf8))
        XCTAssertTrue(outputs.isEmpty)
        XCTAssertEqual(proto.state, .closed)
    }

    func testEnterRelayWhenNotConnecting() {
        let proto = Socks5Protocol(authMode: .noAuth)
        // 状态 = .handshake 时，enterRelay 应为空操作
        let outputs = proto.enterRelay()
        XCTAssertTrue(outputs.isEmpty)
    }
}

// MARK: - 完整流程

final class Socks5FullFlowTests: XCTestCase {

    func testFullFlowNoAuth() {
        let proto = Socks5Protocol(authMode: .noAuth)
        let target = ProxyAddress.domain("example.com", port: 443)

        // 阶段 1：握手
        let out1 = proto.feed(.socks5Greeting(methods: [0x00]))
        XCTAssertEqual(out1, [.send(Data([0x05, 0x00]))])
        XCTAssertEqual(proto.state, .request)

        // 阶段 3：CONNECT
        let out2 = proto.feed(.socks5Connect(address: target))
        XCTAssertEqual(out2, [.connect(target)])
        XCTAssertEqual(proto.state, .connecting)

        // 缓存早到数据
        _ = proto.feed(Data("early".utf8))

        // 阶段 4：隧道已建立
        let out3 = proto.enterRelay()
        XCTAssertEqual(out3.count, 2)
        XCTAssertEqual(out3[0], .send(Socks5Protocol.successReply()))
        XCTAssertEqual(out3[1], .relayOutbound(Data("early".utf8)))
        XCTAssertEqual(proto.state, .relay)

        // 中继后续数据
        let out4 = proto.feed(Data("more data".utf8))
        XCTAssertEqual(out4, [.relayOutbound(Data("more data".utf8))])
    }

    func testFullFlowWithAuth() {
        let proto = Socks5Protocol(authMode: .usernamePassword(username: "admin", password: "secret"))
        let target = ProxyAddress.ipv4(IPv4Address("10.0.0.1"), port: 80)

        // 阶段 1：握手 → 选择 USERNAME/PASSWORD
        let out1 = proto.feed(.socks5Greeting(methods: [0x02]))
        XCTAssertEqual(out1, [.send(Data([0x05, 0x02]))])
        XCTAssertEqual(proto.state, .auth)

        // 阶段 2：认证
        let out2 = proto.feed(.socks5AuthRequest(username: "admin", password: "secret"))
        XCTAssertEqual(out2, [.send(Data([0x01, 0x00]))])
        XCTAssertEqual(proto.state, .request)

        // 阶段 3：CONNECT
        let out3 = proto.feed(.socks5Connect(address: target))
        XCTAssertEqual(out3, [.connect(target)])
        XCTAssertEqual(proto.state, .connecting)

        // 阶段 4：隧道
        let out4 = proto.enterRelay()
        XCTAssertEqual(out4, [.send(Socks5Protocol.successReply())])
        XCTAssertEqual(proto.state, .relay)
    }

    func testFullFlowAuthFails() {
        let proto = Socks5Protocol(authMode: .usernamePassword(username: "admin", password: "secret"))

        // 阶段 1
        _ = proto.feed(.socks5Greeting(methods: [0x02]))

        // 阶段 2：错误密码
        let out = proto.feed(.socks5AuthRequest(username: "admin", password: "wrong"))
        XCTAssertEqual(out, [.sendAndClose(Data([0x01, 0xFF]))])
        XCTAssertEqual(proto.state, .closed)

        // 后续数据会被忽略
        let out2 = proto.feed(Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x50]))
        XCTAssertTrue(out2.isEmpty)
    }

    func testFullFlowTunnelFails() {
        let proto = Socks5Protocol(authMode: .noAuth)
        _ = proto.feed(.socks5Greeting(methods: [0x00]))
        _ = proto.feed(.socks5Connect(address: .domain("example.com", port: 443)))

        let out = proto.enterRelayFailed(rep: 0x05) // connection refused
        XCTAssertEqual(out, [.sendAndClose(Socks5Protocol.errorReply(rep: 0x05))])
        XCTAssertEqual(proto.state, .closed)
    }
}

// MARK: - Integration Test: Socks5Server → https://www.google.com

final class Socks5ServerIntegrationTests: XCTestCase {

    static let serverHost = ProcessInfo.processInfo.environment["MAGENT_SS_HOST"] ?? ""
    static let serverPort = UInt16(ProcessInfo.processInfo.environment["MAGENT_SS_PORT"] ?? "") ?? 0
    static let password = ProcessInfo.processInfo.environment["MAGENT_SS_PASSWORD"] ?? ""
    static let method = CipherMethod(rawValue: ProcessInfo.processInfo.environment["MAGENT_SS_METHOD"] ?? "")
        ?? .chacha20IetfPoly1305

    private static func makeSS() -> ShadowSocksRequest {
        ShadowSocksRequest(address: serverHost, port: serverPort, method: method, password: password)
    }

    /// Start Socks5Server, connect a SOCKS5 client (URLSession), request https://www.google.com.
    /// 覆盖 SOCKS5 的 4 个阶段：握手 → 认证 → CONNECT → TLS+HTTP 中继。
    func testSocks5ServerToGoogleHTTPS() async throws {
        guard !Self.serverHost.isEmpty, Self.serverPort > 0, !Self.password.isEmpty else {
            throw XCTSkip("SS server config missing")
        }

        // 1. 启动 SOCKS5 服务
        let server = Socks5Server(ssConfig: Self.makeSS())
        try await server.start(host: "127.0.0.1", port: 0)
        let socksPort = server.localPort!
        defer { server.stop() }

        // 2. SOCKS5 客户端：将 URLSession 配置为使用 SOCKS 代理
        let config = URLSessionConfiguration.default
        config.connectionProxyDictionary = [
            kCFStreamPropertySOCKSProxyHost as String: "127.0.0.1",
            kCFStreamPropertySOCKSProxyPort as String: socksPort,
            kCFStreamPropertySOCKSVersion as String: kCFStreamSocketSOCKSVersion5 as String,
        ]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        // 3. Request https://www.google.com through SOCKS5 → SS tunnel
        let url = URL(string: "https://www.google.com")!
        let (data, response) = try await session.data(from: url)

        // 4. 验证
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200,
                       "Expected HTTP 200 from https://www.google.com")
        XCTAssertFalse(data.isEmpty, "Response body should not be empty")
        print("=== SOCKS5 integration: https://www.google.com === status=\(httpResponse.statusCode) body=\(data.count) bytes")
    }
}

// MARK: - Integration Test: HttpProxyServer → https://www.google.com

final class HttpProxyServerIntegrationTests: XCTestCase {

    static let serverHost = ProcessInfo.processInfo.environment["MAGENT_SS_HOST"] ?? ""
    static let serverPort = UInt16(ProcessInfo.processInfo.environment["MAGENT_SS_PORT"] ?? "") ?? 0
    static let password = ProcessInfo.processInfo.environment["MAGENT_SS_PASSWORD"] ?? ""
    static let method = CipherMethod(rawValue: ProcessInfo.processInfo.environment["MAGENT_SS_METHOD"] ?? "")
        ?? .chacha20IetfPoly1305

    private static func makeSS() -> ShadowSocksRequest {
        ShadowSocksRequest(address: serverHost, port: serverPort, method: method, password: password)
    }

    /// Start HttpProxyServer, use URLSession to request https://www.google.com through the proxy.
    /// 覆盖 CONNECT 隧道：客户端发送 CONNECT → 代理打开 SS 隧道 → TLS+HTTP 中继。
    func testHttpProxyServerToGoogleHTTPS() async throws {
        guard !Self.serverHost.isEmpty, Self.serverPort > 0, !Self.password.isEmpty else {
            throw XCTSkip("SS server config missing")
        }

        // 1. 启动 HTTP 代理服务
        let server = HttpProxyServer(ssConfig: Self.makeSS())
        try await server.start(host: "127.0.0.1", port: 0)
        let httpPort = server.localPort!
        defer { server.stop() }
        XCTAssertTrue(server.isRunning)

        // 2. 配置使用 HTTP 代理的 URLSession，同时设置 HTTP 与 HTTPS 代理键
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFStreamPropertyHTTPProxyHost as String: "127.0.0.1",
            kCFStreamPropertyHTTPProxyPort as String: httpPort,
            kCFStreamPropertyHTTPSProxyHost as String: "127.0.0.1",
            kCFStreamPropertyHTTPSProxyPort as String: httpPort,
        ]
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        // 3. Request https://www.google.com
        let url = URL(string: "https://www.google.com")!
        let (data, response) = try await session.data(from: url)

        // 4. 验证
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 200,
                       "Expected HTTP 200 from https://www.google.com, got \(httpResponse.statusCode)")
        XCTAssertFalse(data.isEmpty, "Response body should not be empty")
        print("=== HTTP proxy integration: https://www.google.com === status=\(httpResponse.statusCode) body=\(data.count) bytes")
    }
}
