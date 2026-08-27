import Foundation
@testable import Magent
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest

/// `HttpForwardConnection` 请求解析、转发改写、背压和 half-close 测试。
final class HttpForwardConnectionTests: XCTestCase {
    func testMagentTCPConnectionRoutesHTTPForwardToItsParser() throws {
        let channel = try makeConnectionChannel()
        defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }

        try writeInbound(Data("GET http://example.com/ HTTP/1.1\r\n".utf8), to: channel)
        XCTAssertNil(try readOutboundData(from: channel))

        try writeInbound(Data("Malformed-Header\r\n\r\n".utf8), to: channel)
        XCTAssertEqual(try readOutboundData(from: channel), HttpForwardConnection.badRequest)
        XCTAssertFalse(channel.isActive)
    }

    func testHTTPForwardDirectRequestAndResponseUseManualReadFlow() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let shutdownPromise = eventLoop.makePromise(of: Void.self)
        let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
        let targetRequestPromise = eventLoop.makePromise(of: Data.self)
        let targetRequestLengthPromise = eventLoop.makePromise(of: Int.self)
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".utf8)
        var channels: [Channel] = []
        defer {
            shutdownPromise.succeed(())
            shutdownTestChannels(channels, group: group)
        }

        let targetServer = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                targetAcceptedPromise.succeed(channel)
                return targetRequestLengthPromise.futureResult.flatMap { byteCount in
                    channel.pipeline.addHandler(
                        TestDataCollector(expectedByteCount: byteCount, promise: targetRequestPromise)
                    )
                }
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
        let clientResponsePromise = eventLoop.makePromise(of: Data.self)
        try client.pipeline.addHandler(
            TestDataCollector(expectedByteCount: response.count, promise: clientResponsePromise)
        ).wait()

        let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
        let expectedForwardedRequest = Data(
            "POST /resource HTTP/1.1\r\nHost: 127.0.0.1:\(targetPort)\r\n"
                .appending("Content-Length: 4\r\nConnection: close\r\n\r\ndata").utf8
        )
        targetRequestLengthPromise.succeed(expectedForwardedRequest.count)
        let request = Data(
            "POST http://127.0.0.1:\(targetPort)/resource HTTP/1.1\r\n"
                .appending(
                    "Host: ignored.example\r\nProxy-Connection: keep-alive\r\nContent-Length: 4\r\n\r\ndata"
                ).utf8
        )
        try writeData(Data(request.dropLast(2)), to: client)
        try writeData(Data(request.suffix(2)), to: client)

        let targetChannel = try targetAcceptedPromise.futureResult.wait()
        channels.append(targetChannel)
        let forwardedRequest = try targetRequestPromise.futureResult.wait()
        XCTAssertEqual(forwardedRequest, expectedForwardedRequest)

        try writeData(response, to: targetChannel)
        XCTAssertEqual(try clientResponsePromise.futureResult.wait(), response)
    }

    func testHTTPForwardProxyWritesShadowsocksHandshakeBeforeRequest() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let shutdownPromise = eventLoop.makePromise(of: Void.self)
        let proxyNodeAcceptedPromise = eventLoop.makePromise(of: Channel.self)
        let encryptedStreamPromise = eventLoop.makePromise(of: Data.self)
        let cipher = ProxyCipher.aes256Gcm
        let host = "example.com"
        let forwardedRequest = Data(
            "GET /resource HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n".utf8
        )
        let shadowsocksAddressLength = 1 + 1 + host.utf8.count + 2
        let handshakeLength = cipher.saltSize + 2 + cipher.tagSize + shadowsocksAddressLength + cipher.tagSize
        let requestLength = 2 + cipher.tagSize + forwardedRequest.count + cipher.tagSize
        var channels: [Channel] = []
        defer {
            shutdownPromise.succeed(())
            shutdownTestChannels(channels, group: group)
        }

        let shadowsocksServer = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                proxyNodeAcceptedPromise.succeed(channel)
                return channel.pipeline.addHandler(
                    TestDataCollector(
                        expectedByteCount: handshakeLength + requestLength,
                        promise: encryptedStreamPromise
                    )
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
        let request = Data(
            "GET http://example.com/resource HTTP/1.1\r\nHost: ignored.example\r\n\r\n".utf8
        )
        try writeData(request, to: client)

        XCTAssertEqual(try encryptedStreamPromise.futureResult.wait().count, handshakeLength + requestLength)
        channels.append(try proxyNodeAcceptedPromise.futureResult.wait())
    }

    func testHTTPForwardReturnsSingleBadGatewayWhenDirectConnectFails() throws {
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
        let clientClosed = expectation(description: "HTTP forward closes after the bad gateway response")
        try client.pipeline.addHandler(
            TestDataCollector(expectedByteCount: HttpForwardConnection.badGateway.count, promise: responsePromise)
        ).wait()
        client.closeFuture.whenComplete { _ in
            clientClosed.fulfill()
        }

        let request = Data(
            "GET http://127.0.0.1:\(unavailablePort)/ HTTP/1.1\r\nHost: 127.0.0.1:\(unavailablePort)\r\n\r\n".utf8
        )
        try writeData(request, to: client)

        XCTAssertEqual(try responsePromise.futureResult.wait(), HttpForwardConnection.badGateway)
        wait(for: [clientClosed], timeout: 2)
    }

    func testHTTPForwardProxyHalfCloseStillAllowsTargetResponse() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let shutdownPromise = eventLoop.makePromise(of: Void.self)
        let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
        let targetInputClosed = expectation(description: "HTTP target receives proxy input FIN")
        let response = Data("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".utf8)
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
        let clientResponsePromise = eventLoop.makePromise(of: Data.self)
        try client.pipeline.addHandler(
            TestDataCollector(expectedByteCount: response.count, promise: clientResponsePromise)
        ).wait()

        let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
        let request = Data(
            "GET http://127.0.0.1:\(targetPort)/ HTTP/1.1\r\nHost: 127.0.0.1:\(targetPort)\r\n\r\n".utf8
        )
        try writeData(request, to: client)
        try client.close(mode: .output).wait()

        let targetChannel = try targetAcceptedPromise.futureResult.wait()
        channels.append(targetChannel)
        wait(for: [targetInputClosed], timeout: 2)
        try writeData(response, to: targetChannel)

        XCTAssertEqual(try clientResponsePromise.futureResult.wait(), response)
        XCTAssertTrue(client.isActive)
        XCTAssertTrue(targetChannel.isActive)
    }

    func testHTTPForwardWaitsForProxyWriteBeforeReadingNextTargetBatch() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = group.next()
        let shutdownPromise = eventLoop.makePromise(of: Void.self)
        let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
        let firstProxyWritePromise = eventLoop.makePromise(of: Data.self)
        let delayedWrites = DelayedTestWrites(eventLoop: eventLoop, firstWritePromise: firstProxyWritePromise)
        let responseHead = Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n".utf8)
        let responseBody = Data("body".utf8)
        var channels: [Channel] = []
        defer {
            _ = try? delayedWrites.release().wait()
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
        ) { channel in
            channel.pipeline.addHandler(delayedWrites)
        }
        channels.append(proxyServer)

        let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress)).wait()
        channels.append(client)
        let responsePromise = eventLoop.makePromise(of: Data.self)
        try client.pipeline.addHandler(
            TestDataCollector(
                expectedByteCount: responseHead.count + responseBody.count,
                promise: responsePromise
            )
        ).wait()

        let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
        let request = Data(
            "GET http://127.0.0.1:\(targetPort)/ HTTP/1.1\r\nHost: 127.0.0.1:\(targetPort)\r\n\r\n".utf8
        )
        try writeData(request, to: client)
        let targetChannel = try targetAcceptedPromise.futureResult.wait()
        channels.append(targetChannel)

        try writeData(responseHead, to: targetChannel)
        XCTAssertEqual(try firstProxyWritePromise.futureResult.wait(), responseHead)
        try writeData(responseBody, to: targetChannel)
        XCTAssertEqual(try delayedWrites.writeCount().wait(), 1)

        try delayedWrites.release().wait()
        XCTAssertEqual(try responsePromise.futureResult.wait(), responseHead + responseBody)
        XCTAssertEqual(try delayedWrites.writeCount().wait(), 2)
    }

    func testHTTPForwardRewritesAbsoluteFormAndRemovesProxyHeaders() throws {
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "http://example.com/a?b=c",
            headers: HTTPHeaders([
                ("Host", "wrong.example"),
                ("Proxy-Authorization", "Basic secret"),
                ("Connection", "keep-alive, X-Remove"),
                ("X-Remove", "value"),
                ("X-Keep", "value")
            ])
        )
        let parsed = try HttpForwardConnection.buildRequest(head: head, body: Data())
        let payload = try XCTUnwrap(String(data: parsed.payload, encoding: .utf8))

        XCTAssertEqual(parsed.target, .domain("example.com", port: 80))
        XCTAssertTrue(payload.hasPrefix("GET /a?b=c HTTP/1.1\r\nHost: example.com\r\n"))
        XCTAssertFalse(payload.localizedCaseInsensitiveContains("proxy-authorization"))
        XCTAssertFalse(payload.localizedCaseInsensitiveContains("x-remove"))
        XCTAssertTrue(payload.contains("X-Keep: value\r\n"))
        XCTAssertTrue(payload.hasSuffix("Connection: close\r\n\r\n"))
    }

    func testHTTPForwardRejectsUnsupportedOrAmbiguousRequests() throws {
        let requests = [
            Data(
                "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\n"
                    .appending("Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n").utf8
            ),
            Data(
                "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\n"
                    .appending("Content-Length: 1\r\nExpect: 100-continue\r\n\r\nx").utf8
            ),
            Data(
                "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\n\r\n".utf8
            ),
            Data(
                "GET / HTTP/1.1\r\nHost: example.com\r\nHost: other.example\r\n\r\n".utf8
            ),
            Data(
                "GET http://example.com/ HTTP/1.2\r\nHost: example.com\r\n\r\n".utf8
            ),
            Data(
                "GET https://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8
            ),
            Data(
                "GET http://example.com/ HTTP/1.1\r\nHost : example.com\r\n\r\n".utf8
            ),
            Data(
                "GET / HTTP/1.1\r\n\r\n".utf8
            ),
            Data(
                "GET * HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8
            ),
            Data(
                "GET http://user@example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8
            ),
            Data(
                "GET http://example.com/#fragment HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8
            )
        ]

        for request in requests {
            let channel = try makeConnectionChannel()
            try writeInbound(request, to: channel)

            XCTAssertEqual(try readOutboundData(from: channel), HttpForwardConnection.badRequest)
            XCTAssertFalse(channel.isActive)
            XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true))
        }
    }

    func testHTTPForwardRejectsPipelinedRequestFromDecoderLeftovers() throws {
        let channel = try makeConnectionChannel()
        defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
        let request = Data(
            "GET http://127.0.0.1:9/ HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n"
                .appending("GET http://127.0.0.1:9/next HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n").utf8
        )

        try writeInbound(request, to: channel)

        XCTAssertEqual(try readOutboundData(from: channel), HttpForwardConnection.badRequest)
        XCTAssertNil(try readOutboundData(from: channel))
        XCTAssertFalse(channel.isActive)
    }

    func testHTTPForwardRequestSizeBoundaryUsesOverflowSafeRawByteCount() throws {
        let channel = try makeConnectionChannel()
        defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
        let prefix = Data(
            "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nContent-Length: 65536\r\n\r\n".utf8
        )
        let request = prefix + Data(repeating: 0x61, count: 64 * 1024 - prefix.count)

        try writeInbound(request, to: channel)
        XCTAssertNil(try readOutboundData(from: channel))
        XCTAssertTrue(channel.isActive)

        try writeInbound(Data([0x61]), to: channel)
        XCTAssertEqual(try readOutboundData(from: channel), HttpForwardConnection.badRequest)
        XCTAssertFalse(channel.isActive)
    }

    func testHTTPForwardPreservesPercentEncodedOriginForm() throws {
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "http://example.com/a%20b/%2F?q=%0D%0AInjected",
            headers: HTTPHeaders([("Host", "example.com")])
        )

        let request = try HttpForwardConnection.buildRequest(head: head, body: Data())
        let payload = try XCTUnwrap(String(data: request.payload, encoding: .utf8))

        XCTAssertTrue(
            payload.hasPrefix("GET /a%20b/%2F?q=%0D%0AInjected HTTP/1.1\r\nHost: example.com\r\n")
        )
        XCTAssertFalse(payload.contains("\r\nInjected"))
    }

    func testHTTPForwardNumericTargetsPreserveIPAddressType() throws {
        let absoluteIPv4 = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "http://10.1.2.3:8080/path",
            headers: HTTPHeaders([("Host", "ignored.example")])
        )
        let absoluteIPv6 = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "http://[fd00::1]:8080/path",
            headers: HTTPHeaders([("Host", "ignored.example")])
        )
        let hostIPv4 = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/path",
            headers: HTTPHeaders([("Host", "10.1.2.3:8080")])
        )
        let hostIPv6 = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/path",
            headers: HTTPHeaders([("Host", "[fd00::1]:8080")])
        )

        XCTAssertEqual(
            try HttpForwardConnection.buildRequest(head: absoluteIPv4, body: Data()).target,
            .ipv4(Data([10, 1, 2, 3]), port: 8080)
        )
        XCTAssertEqual(
            try HttpForwardConnection.buildRequest(head: hostIPv4, body: Data()).target,
            .ipv4(Data([10, 1, 2, 3]), port: 8080)
        )
        for request in [absoluteIPv6, hostIPv6] {
            guard case .ipv6(let bytes, let port) = try HttpForwardConnection.buildRequest(
                head: request,
                body: Data()
            ).target else {
                return XCTFail("bracketed HTTP target must preserve IPv6 type")
            }
            XCTAssertEqual(bytes.count, 16)
            XCTAssertEqual(port, 8080)
        }
    }
}
