import Foundation
@testable import Magent
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest

/// `HttpConnectConnection` 解析、隧道、背压和 half-close 测试。
final class HttpConnectConnectionTests: XCTestCase {
    func testMagentTCPConnectionEstablishesHTTPConnectDirectOnce() throws {
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

        let defaultNode = ProxyNode(
            address: try SocketAddress(ipAddress: "192.0.2.252", port: 8388),
            cipher: .aes256Gcm,
            password: "test"
        )
        let core = try MagentCore(
            defaultDecision: .direct,
            defaultProxyNode: defaultNode,
            enableMatchTable: false,
            defaultTimeout: 10_000,
            rules: []
        )
        let proxyServer = try bindTCPProxy(
            group: group,
            core: core,
            shutdownFuture: shutdownPromise.futureResult
        )
        channels.append(proxyServer)

        let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress)).wait()
        channels.append(client)
        let responsePromise = client.eventLoop.makePromise(of: Data.self)
        try client.pipeline.addHandler(
            TestDataCollector(expectedByteCount: HttpProtocol.established.count, promise: responsePromise)
        ).wait()

        let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
        try writeData(httpConnectRequest(host: "127.0.0.1", port: targetPort), to: client)

        XCTAssertEqual(try responsePromise.futureResult.wait(), HttpProtocol.established)
        let targetChannel = try targetAcceptedPromise.futureResult.wait()
        channels.append(targetChannel)
        XCTAssertTrue(targetChannel.isActive)
    }

    func testHTTPConnectUsesStrictBackpressureInBothDirections() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let shutdownPromise = eventLoop.makePromise(of: Void.self)
        let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
        let firstWirePayload = Data("first-http-wire-payload".utf8)
        let secondWirePayload = Data("second-http-wire-payload".utf8)
        let firstProxyPayload = Data(repeating: 0xA5, count: 8 * 1024 * 1024)
        let secondProxyPayload = Data("second-http-proxy-payload".utf8)
        let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
        let firstTunnelWritePromise = eventLoop.makePromise(of: Data.self)
        let manualReads = ManualTestReads(eventLoop: eventLoop)
        let delayedWrites = DelayedTestWrites(
            eventLoop: eventLoop,
            firstWritePromise: firstTunnelWritePromise,
            writesBeforeDelay: 1
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

        let defaultNode = ProxyNode(
            address: try SocketAddress(ipAddress: "192.0.2.252", port: 8388),
            cipher: .aes256Gcm,
            password: "test"
        )
        let core = try MagentCore(
            defaultDecision: .direct,
            defaultProxyNode: defaultNode,
            enableMatchTable: false,
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

        let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress)).wait()
        channels.append(client)
        let responsePromise = eventLoop.makePromise(of: Data.self)
        let tunnelPayloadsPromise = eventLoop.makePromise(of: Data.self)
        try client.pipeline.addHandlers(
            TestDataCollector(expectedByteCount: HttpProtocol.established.count, promise: responsePromise),
            TestDataCollector(
                expectedByteCount: HttpProtocol.established.count + firstWirePayload.count + secondWirePayload.count,
                promise: tunnelPayloadsPromise
            )
        ).wait()

        let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
        try manualReads.enqueue([httpConnectRequest(host: "127.0.0.1", port: targetPort)]).wait()
        XCTAssertEqual(try responsePromise.futureResult.wait(), HttpProtocol.established)

        let targetChannel = try targetAcceptedPromise.futureResult.wait()
        channels.append(targetChannel)
        try writeData(firstWirePayload, to: targetChannel)
        XCTAssertEqual(try firstTunnelWritePromise.futureResult.wait(), firstWirePayload)
        try writeData(secondWirePayload, to: targetChannel)
        XCTAssertEqual(try delayedWrites.writeCount().wait(), 2)

        try delayedWrites.release().wait()
        XCTAssertEqual(
            try tunnelPayloadsPromise.futureResult.wait(),
            HttpProtocol.established + firstWirePayload + secondWirePayload
        )
        XCTAssertEqual(try delayedWrites.writeCount().wait(), 3)

        try manualReads.enqueue([firstProxyPayload, secondProxyPayload]).wait()
        XCTAssertEqual(try manualReads.deliveredCount().wait(), 2)

        try targetChannel.setOption(ChannelOptions.autoRead, value: true).wait()
        let receivedPayload = try targetPayloadPromise.futureResult.wait()
        XCTAssertEqual(receivedPayload.count, firstProxyPayload.count + secondProxyPayload.count)
        XCTAssertEqual(receivedPayload.suffix(secondProxyPayload.count), secondProxyPayload)
        XCTAssertEqual(try manualReads.deliveredCount().wait(), 3)
    }

    func testHTTPConnectProxyHalfCloseForwardsFinalPayloadBeforeWireFIN() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let shutdownPromise = eventLoop.makePromise(of: Void.self)
        let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
        let proxyPayload = Data("final-http-proxy-payload".utf8)
        let wirePayload = Data("final-http-wire-payload".utf8)
        let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
        let targetInputClosed = expectation(description: "HTTP target receives FIN after proxy payload")
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

        let defaultNode = ProxyNode(
            address: try SocketAddress(ipAddress: "192.0.2.252", port: 8388),
            cipher: .aes256Gcm,
            password: "test"
        )
        let core = try MagentCore(
            defaultDecision: .direct,
            defaultProxyNode: defaultNode,
            enableMatchTable: false,
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
        let responsePromise = eventLoop.makePromise(of: Data.self)
        let wirePayloadPromise = eventLoop.makePromise(of: Data.self)
        try client.pipeline.addHandlers(
            TestDataCollector(expectedByteCount: HttpProtocol.established.count, promise: responsePromise),
            TestDataCollector(
                expectedByteCount: HttpProtocol.established.count + wirePayload.count,
                promise: wirePayloadPromise
            )
        ).wait()

        let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
        try writeData(httpConnectRequest(host: "127.0.0.1", port: targetPort), to: client)
        XCTAssertEqual(try responsePromise.futureResult.wait(), HttpProtocol.established)

        let targetChannel = try targetAcceptedPromise.futureResult.wait()
        channels.append(targetChannel)
        try writeData(proxyPayload, to: client)
        try client.close(mode: .output).wait()

        wait(for: [targetInputClosed], timeout: 2)
        XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), proxyPayload)

        try writeData(wirePayload, to: targetChannel)
        XCTAssertEqual(try wirePayloadPromise.futureResult.wait().suffix(wirePayload.count), wirePayload)
    }

    func testHTTPConnectWireHalfCloseKeepsProxyToWireDirectionOpen() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let shutdownPromise = eventLoop.makePromise(of: Void.self)
        let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
        let wirePayload = Data("final-http-wire-payload".utf8)
        let proxyPayload = Data("http-payload-after-wire-fin".utf8)
        let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
        let clientInputClosed = expectation(description: "HTTP client receives FIN after wire payload")
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

        let defaultNode = ProxyNode(
            address: try SocketAddress(ipAddress: "192.0.2.252", port: 8388),
            cipher: .aes256Gcm,
            password: "test"
        )
        let core = try MagentCore(
            defaultDecision: .direct,
            defaultProxyNode: defaultNode,
            enableMatchTable: false,
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
        let responsePromise = eventLoop.makePromise(of: Data.self)
        let wirePayloadPromise = eventLoop.makePromise(of: Data.self)
        try client.pipeline.addHandlers(
            TestDataCollector(expectedByteCount: HttpProtocol.established.count, promise: responsePromise),
            TestDataCollector(
                expectedByteCount: HttpProtocol.established.count + wirePayload.count,
                promise: wirePayloadPromise
            ),
            TestInputClosedRecorder(expectation: clientInputClosed)
        ).wait()

        let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
        try writeData(httpConnectRequest(host: "127.0.0.1", port: targetPort), to: client)
        XCTAssertEqual(try responsePromise.futureResult.wait(), HttpProtocol.established)

        let targetChannel = try targetAcceptedPromise.futureResult.wait()
        channels.append(targetChannel)
        try writeData(wirePayload, to: targetChannel)
        try targetChannel.close(mode: .output).wait()

        wait(for: [clientInputClosed], timeout: 2)
        XCTAssertEqual(try wirePayloadPromise.futureResult.wait().suffix(wirePayload.count), wirePayload)
        XCTAssertTrue(client.isActive)
        XCTAssertTrue(targetChannel.isActive)

        try writeData(proxyPayload, to: client)
        XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), proxyPayload)
    }

    func testHTTPConnectDefersProxyHalfCloseUntilTunnelIsEstablished() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let shutdownPromise = eventLoop.makePromise(of: Void.self)
        let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
        let targetInputClosed = expectation(description: "HTTP target receives deferred proxy FIN")
        let wirePayload = Data("http-response-after-handshake-fin".utf8)
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

        let defaultNode = ProxyNode(
            address: try SocketAddress(ipAddress: "192.0.2.252", port: 8388),
            cipher: .aes256Gcm,
            password: "test"
        )
        let core = try MagentCore(
            defaultDecision: .direct,
            defaultProxyNode: defaultNode,
            enableMatchTable: false,
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
        let responsePromise = eventLoop.makePromise(of: Data.self)
        try client.pipeline.addHandler(
            TestDataCollector(
                expectedByteCount: HttpProtocol.established.count + wirePayload.count,
                promise: responsePromise
            )
        ).wait()

        let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
        try writeData(httpConnectRequest(host: "127.0.0.1", port: targetPort), to: client)
        try client.close(mode: .output).wait()

        let targetChannel = try targetAcceptedPromise.futureResult.wait()
        channels.append(targetChannel)
        wait(for: [targetInputClosed], timeout: 2)

        try writeData(wirePayload, to: targetChannel)
        XCTAssertEqual(try responsePromise.futureResult.wait().suffix(wirePayload.count), wirePayload)
    }

    func testHTTPConnectClosesIncompleteRequestWhenProxyHalfCloses() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let shutdownPromise = eventLoop.makePromise(of: Void.self)
        var channels: [Channel] = []
        defer {
            shutdownPromise.succeed(())
            shutdownTestChannels(channels, group: group)
        }

        let defaultNode = ProxyNode(
            address: try SocketAddress(ipAddress: "192.0.2.252", port: 8388),
            cipher: .aes256Gcm,
            password: "test"
        )
        let core = try MagentCore(
            defaultDecision: .direct,
            defaultProxyNode: defaultNode,
            enableMatchTable: false,
            defaultTimeout: 10_000,
            rules: []
        )
        let proxyServer = try bindTCPProxy(
            group: group,
            core: core,
            shutdownFuture: shutdownPromise.futureResult
        )
        channels.append(proxyServer)

        let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress)).wait()
        channels.append(client)
        let responsePromise = eventLoop.makePromise(of: Data.self)
        let clientClosed = expectation(description: "incomplete HTTP CONNECT request closes without a response")
        try client.pipeline.addHandler(
            TestDataCollector(expectedByteCount: 1, promise: responsePromise)
        ).wait()
        client.closeFuture.whenComplete { _ in
            clientClosed.fulfill()
        }

        try writeData(Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example".utf8), to: client)
        try client.close(mode: .output).wait()

        wait(for: [clientClosed], timeout: 2)
        XCTAssertThrowsError(try responsePromise.futureResult.wait()) { error in
            XCTAssertEqual(error as? MagentError, .connectionClosed)
        }
    }

    func testMagentTCPConnectionWritesShadowsocksHandshakeAndEstablishesHTTPConnect() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let shutdownPromise = eventLoop.makePromise(of: Void.self)
        let proxyNodeAcceptedPromise = eventLoop.makePromise(of: Channel.self)
        let cipher = ProxyCipher.aes256Gcm
        let host = "example.com"
        let shadowsocksAddressLength = 1 + 1 + host.utf8.count + 2
        let expectedHandshakeLength = cipher.saltSize
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
            defaultProxyNode: defaultNode,
            enableMatchTable: false,
            defaultTimeout: 10_000,
            rules: []
        )
        let proxyServer = try bindTCPProxy(
            group: group,
            core: core,
            shutdownFuture: shutdownPromise.futureResult
        )
        channels.append(proxyServer)

        let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress)).wait()
        channels.append(client)
        let responsePromise = client.eventLoop.makePromise(of: Data.self)
        try client.pipeline.addHandler(
            TestDataCollector(expectedByteCount: HttpProtocol.established.count, promise: responsePromise)
        ).wait()

        try writeData(httpConnectRequest(host: host, port: 443), to: client)

        XCTAssertEqual(try responsePromise.futureResult.wait(), HttpProtocol.established)
        XCTAssertEqual(try handshakePromise.futureResult.wait().count, expectedHandshakeLength)
        channels.append(try proxyNodeAcceptedPromise.futureResult.wait())
    }

    func testMagentTCPConnectionReturnsBadGatewayWhenDirectConnectFails() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let shutdownPromise = eventLoop.makePromise(of: Void.self)
        var channels: [Channel] = []
        defer {
            shutdownPromise.succeed(())
            shutdownTestChannels(channels, group: group)
        }

        let unavailableServer = try ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        let unavailablePort = try XCTUnwrap(unavailableServer.localAddress?.port)
        try unavailableServer.close().wait()

        let defaultNode = ProxyNode(
            address: try SocketAddress(ipAddress: "192.0.2.252", port: 8388),
            cipher: .aes256Gcm,
            password: "test"
        )
        let core = try MagentCore(
            defaultDecision: .direct,
            defaultProxyNode: defaultNode,
            enableMatchTable: false,
            defaultTimeout: 10_000,
            rules: []
        )
        let proxyServer = try bindTCPProxy(
            group: group,
            core: core,
            shutdownFuture: shutdownPromise.futureResult
        )
        channels.append(proxyServer)

        let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress)).wait()
        channels.append(client)
        let responsePromise = eventLoop.makePromise(of: Data.self)
        let clientClosed = expectation(description: "HTTP CONNECT closes after the bad gateway response")
        try client.pipeline.addHandler(
            TestDataCollector(expectedByteCount: HttpProtocol.badGateway.count, promise: responsePromise)
        ).wait()
        client.closeFuture.whenComplete { _ in
            clientClosed.fulfill()
        }

        try writeData(httpConnectRequest(host: "127.0.0.1", port: unavailablePort), to: client)

        XCTAssertEqual(try responsePromise.futureResult.wait(), HttpProtocol.badGateway)
        wait(for: [clientClosed], timeout: 2)
    }

    func testMagentTCPConnectionRejectsHTTPConnectPayloadInDecoderLeftovers() throws {
        let channel = try makeConnectionChannel()
        defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
        var requestAndPayload = httpConnectRequest(host: "127.0.0.1", port: 443)
        // 合法 method 前缀会留在 decoder 缓冲区，确保测试命中 decoder removal 的 leftover 路径。
        requestAndPayload.append(contentsOf: Data("G".utf8))

        try writeInbound(requestAndPayload, to: channel)
        channel.embeddedEventLoop.run()

        XCTAssertEqual(try readOutboundData(from: channel), HttpProtocol.badRequest)
        XCTAssertNil(try readOutboundData(from: channel))
        XCTAssertFalse(channel.isActive)
    }

    func testMagentTCPConnectionBuffersHTTPConnectAndReturnsBadRequest() throws {
        let channel = try makeConnectionChannel()
        defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
        let first = Data("CONNECT example.com:443 HTTP/1.1\r\nHost: other".utf8)
        let second = Data(".example:443\r\n\r\n".utf8)

        try writeInbound(first, to: channel)
        XCTAssertNil(try readOutboundData(from: channel))
        try writeInbound(second, to: channel)

        XCTAssertEqual(try readOutboundData(from: channel), HttpProtocol.badRequest)
        XCTAssertFalse(channel.isActive)
    }

    func testMagentTCPConnectionRejectsOversizedIncompleteHTTPConnectRequest() throws {
        let channel = try makeConnectionChannel()
        defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
        var request = Data("CONNECT ".utf8)
        request.append(Data(repeating: 0x61, count: 64 * 1024))

        try writeInbound(request, to: channel)

        XCTAssertEqual(try readOutboundData(from: channel), HttpProtocol.badRequest)
        XCTAssertFalse(channel.isActive)
    }

    func testHTTPConnectParserValidatesRequestHeadAndHost() throws {
        let request = HttpProtocol(
            address: try HttpProtocol.parseAuthority("example.com:443"),
            version: "HTTP/1.1",
            headers: [
                (name: "Host", value: "EXAMPLE.com:443"),
                (name: "X-Test", value: "value")
            ]
        )

        XCTAssertEqual(request.address, .domain("example.com", port: 443))
        XCTAssertEqual(request.version, "HTTP/1.1")
        XCTAssertEqual(request.headers.map(\.name), ["Host", "X-Test"])
        XCTAssertEqual(request.headers.map(\.value), ["EXAMPLE.com:443", "value"])
        XCTAssertNoThrow(try request.checkConnect())
    }

    func testHTTPConnectNumericAddressesPreserveIPTypeAndMatchCIDR() throws {
        let proxyNode = ProxyNode(
            address: try SocketAddress(ipAddress: "192.0.2.252", port: 8388),
            cipher: .aes256Gcm,
            password: "test"
        )
        let core = try MagentCore(
            defaultDecision: .direct,
            defaultProxyNode: proxyNode,
            enableMatchTable: true,
            defaultTimeout: 10_000,
            rules: [
                try ProxyRule(matchType: .ipCIDR, matchValue: "10.0.0.0/8", decision: .proxy(proxyNode.id), order: 0),
                try ProxyRule(matchType: .ipCIDR, matchValue: "fd00::/8", decision: .proxy(proxyNode.id), order: 1)
            ]
        )

        let ipv4 = try HttpProtocol.parseAuthority("10.1.2.3:443")
        let ipv6 = try HttpProtocol.parseAuthority("[fd00::1]:443")

        XCTAssertEqual(ipv4, .ipv4(Data([10, 1, 2, 3]), port: 443))
        guard case .ipv6(let ipv6Bytes, let ipv6Port) = ipv6 else {
            return XCTFail("bracketed IPv6 authority must remain IPv6")
        }
        XCTAssertEqual(ipv6Bytes.count, 16)
        XCTAssertEqual(ipv6Port, 443)
        XCTAssertNotNil(try core.routeTCPWire(ipv4))
        XCTAssertNotNil(try core.routeTCPWire(ipv6))
    }

    func testMagentTCPConnectionRejectsHTTPConnectBodyFraming() throws {
        let requests = [
            Data(
                "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nContent-Length: 0\r\n\r\n".utf8
            ),
            Data(
                "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n"
                    .appending("Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n").utf8
            )
        ]

        for request in requests {
            let channel = try makeConnectionChannel()
            try writeInbound(request, to: channel)

            XCTAssertEqual(try readOutboundData(from: channel), HttpProtocol.badRequest)
            XCTAssertFalse(channel.isActive)
            XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true))
        }
    }

    func testHTTPConnectParserRejectsMalformedAuthorityHeadersAndVersion() throws {
        let malformedRequests = [
            Data("CONNECT example.com HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8),
            Data("CONNECT [::1]443 HTTP/1.1\r\nHost: [::1]443\r\n\r\n".utf8),
            Data("CONNECT [example.com]:443 HTTP/1.1\r\nHost: [example.com]:443\r\n\r\n".utf8),
            Data("CONNECT example.com:+443 HTTP/1.1\r\nHost: example.com:+443\r\n\r\n".utf8),
            Data("CONNECT example.com:443 HTTP/1.1\r\nHost : example.com:443\r\n\r\n".utf8),
            Data("CONNECT example.com:443 HTTP/1.1\r\nHost: other.example:443\r\n\r\n".utf8),
            Data("CONNECT example.com:443 HTTP/1.2\r\nHost: example.com:443\r\n\r\n".utf8)
        ]
        for request in malformedRequests {
            let channel = try makeConnectionChannel()
            try writeInbound(request, to: channel)

            XCTAssertEqual(try readOutboundData(from: channel), HttpProtocol.badRequest)
            XCTAssertFalse(channel.isActive)
            XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true))
        }
    }
}

private func httpConnectRequest(host: String, port: Int) -> Data {
    precondition(!host.isEmpty)
    precondition((1...65535).contains(port))
    return Data("CONNECT \(host):\(port) HTTP/1.1\r\nHost: \(host):\(port)\r\n\r\n".utf8)
}
