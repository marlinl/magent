import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest

@testable import Magent

/// `HttpConnectConnection` 解析、隧道、背压和 half-close 测试。
final class HttpConnectConnectionTests: XCTestCase {
  /// HTTP CONNECT 直连建立后只发送一次成功响应。
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

    let core = try MagentCore(
      defaultDecision: .direct,
      proxyNodes: [],
      defaultTimeout: 10_000,
      rules: []
    )
    let proxyServer = try bindTCPProxy(
      group: group,
      core: core,
      shutdownFuture: shutdownPromise.futureResult
    )
    channels.append(proxyServer)

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let responsePromise = client.eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandler(
      TestDataCollector(expectedByteCount: httpConnectEstablished.count, promise: responsePromise)
    ).wait()

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(httpConnectRequest(host: "127.0.0.1", port: targetPort), to: client)

    XCTAssertEqual(try responsePromise.futureResult.wait(), httpConnectEstablished)
    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    XCTAssertTrue(targetChannel.isActive)
  }

  /// HTTP CONNECT 两个转发方向均等待上一批写入完成。
  func testHTTPConnectUsesStrictBackpressureInBothDirections() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let firstWirePayload = Data("first-http-wire-payload".utf8)
    let secondWirePayload = Data("second-http-wire-payload".utf8)
    let firstProxyPayload = Data(repeating: 0xA5, count: 32 * 1024)
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

    let core = try MagentCore(
      defaultDecision: .direct,
      proxyNodes: [],
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

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let responsePromise = eventLoop.makePromise(of: Data.self)
    let tunnelPayloadsPromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(
        expectedByteCount: httpConnectEstablished.count, promise: responsePromise),
      TestDataCollector(
        expectedByteCount: httpConnectEstablished.count + firstWirePayload.count
          + secondWirePayload.count,
        promise: tunnelPayloadsPromise
      )
    ).wait()

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try manualReads.enqueue([httpConnectRequest(host: "127.0.0.1", port: targetPort)]).wait()
    XCTAssertEqual(try responsePromise.futureResult.wait(), httpConnectEstablished)

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    try writeData(firstWirePayload, to: targetChannel)
    XCTAssertEqual(try firstTunnelWritePromise.futureResult.wait(), firstWirePayload)
    try writeData(secondWirePayload, to: targetChannel)
    XCTAssertEqual(try delayedWrites.writeCount().wait(), 2)

    try delayedWrites.release().wait()
    XCTAssertEqual(
      try tunnelPayloadsPromise.futureResult.wait(),
      httpConnectEstablished + firstWirePayload + secondWirePayload
    )
    XCTAssertEqual(try delayedWrites.writeCount().wait(), 3)

    try manualReads.enqueue([firstProxyPayload, secondProxyPayload]).wait()
    // Socket send buffers may complete either batch immediately; compare bytes and order, not timing.
    try targetChannel.setOption(ChannelOptions.autoRead, value: true).wait()
    let receivedPayload = try targetPayloadPromise.futureResult.wait()
    XCTAssertEqual(receivedPayload.count, firstProxyPayload.count + secondProxyPayload.count)
    XCTAssertEqual(receivedPayload.suffix(secondProxyPayload.count), secondProxyPayload)
    XCTAssertEqual(try manualReads.deliveredCount().wait(), 3)
  }

  /// 200 的网络写 Future 未完成时，源站数据与 FIN 都不能越过成功屏障。
  func testHTTPConnectDefersRemotePayloadAndFINUntilSuccessIsWritten() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let loop = group.next()
    let shutdown = loop.makePromise(of: Void.self)
    let accepted = loop.makePromise(of: Channel.self)
    let successPending = loop.makePromise(of: Data.self)
    let delayed = DelayedTestWrites(eventLoop: loop, firstWritePromise: successPending)
    let payload = Data("remote-before-success".utf8)
    var channels: [Channel] = []
    defer {
      _ = try? delayed.release().wait()
      shutdown.succeed(())
      shutdownTestChannels(channels, group: group)
    }
    let targetServer = try ServerBootstrap(group: group)
      .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .childChannelInitializer { channel in
        accepted.succeed(channel)
        return channel.pipeline.addHandler(TestInboundHandler())
      }.bind(host: "127.0.0.1", port: 0).wait()
    channels.append(targetServer)
    let core = try MagentCore(
      defaultDecision: .direct, proxyNodes: [], defaultTimeout: 10_000, rules: [])
    let proxyServer = try bindTCPProxy(
      group: group, core: core, shutdownFuture: shutdown.futureResult
    ) {
      $0.pipeline.addHandler(delayed)
    }
    channels.append(proxyServer)
    let client = try ClientBootstrap(group: group)
      .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .connect(to: XCTUnwrap(proxyServer.localAddress)).wait()
    channels.append(client)
    let response = loop.makePromise(of: Data.self)
    let inputClosed = expectation(description: "remote FIN follows complete 200 and payload")
    try client.pipeline.addHandlers(
      TestDataCollector(
        expectedByteCount: httpConnectEstablished.count + payload.count, promise: response),
      TestInputClosedRecorder(expectation: inputClosed)
    ).wait()
    try writeData(
      httpConnectRequest(host: "127.0.0.1", port: XCTUnwrap(targetServer.localAddress?.port)),
      to: client)
    XCTAssertEqual(try successPending.futureResult.wait(), httpConnectEstablished)
    let target = try accepted.futureResult.wait()
    channels.append(target)
    try writeData(payload, to: target)
    try target.close(mode: .output).wait()
    XCTAssertEqual(try delayed.writeCount().wait(), 1)
    try delayed.release().wait()
    XCTAssertEqual(try response.futureResult.wait(), httpConnectEstablished + payload)
    wait(for: [inputClosed], timeout: 2)
    XCTAssertTrue(client.isActive)
  }

  func testHTTPConnectRejectsInvalidUTF8AcrossEverySplit() throws {
    let bytes =
      Data("CONNECT 127.0.0.1:9 HTTP/1.1\r\nHost: 127.0.0.1:9\r\nX-Value: ".utf8)
      + Data([0xFF]) + Data("\r\n\r\n".utf8)
    for split in 0...bytes.count {
      let channel = try makeConnectionChannel()
      try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
      try writeInbound(Data(bytes.prefix(split)), to: channel)
      try writeInbound(Data(bytes.dropFirst(split)), to: channel)
      XCTAssertEqual(try readOutboundData(from: channel), httpErrorResponse(.badRequest))
      XCTAssertNil(try readOutboundData(from: channel))
      XCTAssertFalse(channel.isActive)
      XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true))
    }
  }

  /// HTTP CONNECT 客户端半关闭前的数据必须先于下游 FIN 转发。
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

    let core = try MagentCore(
      defaultDecision: .direct,
      proxyNodes: [],
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
      TestDataCollector(
        expectedByteCount: httpConnectEstablished.count, promise: responsePromise),
      TestDataCollector(
        expectedByteCount: httpConnectEstablished.count + wirePayload.count,
        promise: wirePayloadPromise
      )
    ).wait()

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(httpConnectRequest(host: "127.0.0.1", port: targetPort), to: client)
    XCTAssertEqual(try responsePromise.futureResult.wait(), httpConnectEstablished)

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    try writeData(proxyPayload, to: client)
    try client.close(mode: .output).wait()

    wait(for: [targetInputClosed], timeout: 2)
    XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), proxyPayload)

    try writeData(wirePayload, to: targetChannel)
    XCTAssertEqual(
      try wirePayloadPromise.futureResult.wait().suffix(wirePayload.count), wirePayload)
  }

  /// HTTP CONNECT 下游半关闭后保留另一方向的转发。
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

    let core = try MagentCore(
      defaultDecision: .direct,
      proxyNodes: [],
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
      TestDataCollector(
        expectedByteCount: httpConnectEstablished.count, promise: responsePromise),
      TestDataCollector(
        expectedByteCount: httpConnectEstablished.count + wirePayload.count,
        promise: wirePayloadPromise
      ),
      TestInputClosedRecorder(expectation: clientInputClosed)
    ).wait()

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(httpConnectRequest(host: "127.0.0.1", port: targetPort), to: client)
    XCTAssertEqual(try responsePromise.futureResult.wait(), httpConnectEstablished)

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    try writeData(wirePayload, to: targetChannel)
    try targetChannel.close(mode: .output).wait()

    wait(for: [clientInputClosed], timeout: 2)
    XCTAssertEqual(
      try wirePayloadPromise.futureResult.wait().suffix(wirePayload.count), wirePayload)
    XCTAssertTrue(client.isActive)
    XCTAssertTrue(targetChannel.isActive)

    try writeData(proxyPayload, to: client)
    XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), proxyPayload)
  }

  /// HTTP CONNECT 建连期间收到半关闭时等待隧道建立后再传播。
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

    let core = try MagentCore(
      defaultDecision: .direct,
      proxyNodes: [],
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
        expectedByteCount: httpConnectEstablished.count + wirePayload.count,
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

  /// HTTP CONNECT 请求不完整便半关闭时回收连接。
  func testHTTPConnectClosesIncompleteRequestWhenProxyHalfCloses() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let core = try MagentCore(
      defaultDecision: .direct,
      proxyNodes: [],
      defaultTimeout: 10_000,
      rules: []
    )
    let proxyServer = try bindTCPProxy(
      group: group,
      core: core,
      shutdownFuture: shutdownPromise.futureResult
    )
    channels.append(proxyServer)

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let responsePromise = eventLoop.makePromise(of: Data.self)
    let clientClosed = expectation(
      description: "incomplete HTTP CONNECT request closes after one bad request response")
    try client.pipeline.addHandler(
      TestDataCollector(
        expectedByteCount: httpErrorResponse(.badRequest).count, promise: responsePromise)
    ).wait()
    client.closeFuture.whenComplete { _ in
      clientClosed.fulfill()
    }

    try writeData(Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example".utf8), to: client)
    try client.close(mode: .output).wait()

    wait(for: [clientClosed], timeout: 2)
    XCTAssertEqual(try responsePromise.futureResult.wait(), httpErrorResponse(.badRequest))
  }

  /// 通过节点列表选中的 Shadowsocks Wire 建立 HTTP CONNECT 隧道。
  func testMagentTCPConnectionWritesShadowsocksHandshakeAndEstablishesHTTPConnect() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let proxyNodeAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let cipher = ProxyCipher.aes256Gcm
    let host = "example.com"
    let shadowsocksAddressLength = 1 + 1 + host.utf8.count + 2
    let expectedHandshakeLength =
      cipher.saltSize
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

    let defaultNode = try ProxyNode(
      address: try XCTUnwrap(shadowsocksServer.localAddress),
      cipher: cipher,
      password: "test"
    )
    let core = try MagentCore(
      defaultDecision: .proxy(defaultNode.id),
      proxyNodes: [defaultNode],
      defaultTimeout: 10_000,
      rules: []
    )
    let proxyServer = try bindTCPProxy(
      group: group,
      core: core,
      shutdownFuture: shutdownPromise.futureResult
    )
    channels.append(proxyServer)

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let responsePromise = client.eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandler(
      TestDataCollector(expectedByteCount: httpConnectEstablished.count, promise: responsePromise)
    ).wait()

    try writeData(httpConnectRequest(host: host, port: 443), to: client)

    XCTAssertEqual(try responsePromise.futureResult.wait(), httpConnectEstablished)
    XCTAssertEqual(try handshakePromise.futureResult.wait().count, expectedHandshakeLength)
    channels.append(try proxyNodeAcceptedPromise.futureResult.wait())
  }

  /// HTTP CONNECT 直连失败时向客户端返回网关错误。
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

    let core = try MagentCore(
      defaultDecision: .direct,
      proxyNodes: [],
      defaultTimeout: 10_000,
      rules: []
    )
    let proxyServer = try bindTCPProxy(
      group: group,
      core: core,
      shutdownFuture: shutdownPromise.futureResult
    )
    channels.append(proxyServer)

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let responsePromise = eventLoop.makePromise(of: Data.self)
    let clientClosed = expectation(
      description: "HTTP CONNECT closes after the bad gateway response")
    try client.pipeline.addHandler(
      TestDataCollector(
        expectedByteCount: httpErrorResponse(.badGateway).count, promise: responsePromise)
    ).wait()
    client.closeFuture.whenComplete { _ in
      clientClosed.fulfill()
    }

    try writeData(httpConnectRequest(host: "127.0.0.1", port: unavailablePort), to: client)

    XCTAssertEqual(try responsePromise.futureResult.wait(), httpErrorResponse(.badGateway))
    wait(for: [clientClosed], timeout: 2)
  }

  func testMagentTCPConnectionRejectsHTTPConnectPayloadInDecoderLeftovers() throws {
    let channel = try makeConnectionChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
    defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
    var requestAndPayload = httpConnectRequest(host: "127.0.0.1", port: 443)
    // 合法 method 前缀会留在 decoder 缓冲区，确保测试命中 decoder removal 的 leftover 路径。
    requestAndPayload.append(contentsOf: Data("G".utf8))

    try writeInbound(requestAndPayload, to: channel)
    channel.embeddedEventLoop.run()

    XCTAssertEqual(try readOutboundData(from: channel), httpErrorResponse(.badRequest))
    XCTAssertNil(try readOutboundData(from: channel))
    XCTAssertFalse(channel.isActive)
  }

  func testMagentTCPConnectionBuffersHTTPConnectAndReturnsBadRequest() throws {
    let channel = try makeConnectionChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
    defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
    let first = Data("CONNECT example.com:443 HTTP/1.1\r\nHost: other".utf8)
    let second = Data(".example:443\r\n\r\n".utf8)

    try writeInbound(first, to: channel)
    XCTAssertNil(try readOutboundData(from: channel))
    try writeInbound(second, to: channel)

    XCTAssertEqual(try readOutboundData(from: channel), httpErrorResponse(.badRequest))
    XCTAssertFalse(channel.isActive)
  }

  func testMagentTCPConnectionRejectsOversizedIncompleteHTTPConnectRequest() throws {
    let channel = try makeConnectionChannel()
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
    defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
    try writeInbound(Data("CONNECT ".utf8), to: channel)
    try writeInbound(Data(repeating: 0x61, count: 64 * 1024), to: channel)

    XCTAssertEqual(try readOutboundData(from: channel), httpErrorResponse(.badRequest))
    XCTAssertFalse(channel.isActive)
  }

  func testHTTPConnectParserValidatesRequestHeadAndHost() throws {
    let model = try HttpProtocol(
      head: HTTPRequestHead(
        version: .http1_1, method: .CONNECT, uri: "example.com:443",
        headers: HTTPHeaders([("Host", "EXAMPLE.com:443"), ("X-Test", "value")])
      ))
    guard case .connect(let target, let version) = model.request else {
      return XCTFail("CONNECT must produce tunnel semantics")
    }
    XCTAssertEqual(target, try NetworkAddress(host: "example.com", port: 443))
    XCTAssertEqual(version, .http1_1)
  }

  /// HTTP CONNECT 数值地址保留 IP 类型并参与 CIDR 规则匹配。
  func testHTTPConnectNumericAddressesPreserveIPTypeAndMatchCIDR() throws {
    let proxyNode = try ProxyNode(
      address: try SocketAddress(ipAddress: "192.0.2.252", port: 8388),
      cipher: .aes256Gcm,
      password: "test"
    )
    let core = try MagentCore(
      defaultDecision: .direct,
      proxyNodes: [proxyNode],
      defaultTimeout: 10_000,
      rules: [
        try ProxyRule(
          matchType: .ipCIDR, matchValue: "10.0.0.0/8", decision: .proxy(proxyNode.id), order: 0),
        try ProxyRule(
          matchType: .ipCIDR, matchValue: "fd00::/8", decision: .proxy(proxyNode.id), order: 1),
      ]
    )

    let ipv4Model = try HttpProtocol(
      head: HTTPRequestHead(
        version: .http1_1, method: .CONNECT, uri: "10.1.2.3:443",
        headers: HTTPHeaders([("Host", "10.1.2.3:443")])
      ))
    let ipv6Model = try HttpProtocol(
      head: HTTPRequestHead(
        version: .http1_1, method: .CONNECT, uri: "[fd00::1]:443",
        headers: HTTPHeaders([("Host", "[fd00::1]:443")])
      ))
    guard case .connect(let ipv4, _) = ipv4Model.request,
      case .connect(let ipv6, _) = ipv6Model.request
    else {
      return XCTFail("numeric CONNECT targets must produce tunnel semantics")
    }
    XCTAssertEqual(ipv4, try NetworkAddress(host: "10.1.2.3", port: 443))
    XCTAssertEqual(ipv6, try NetworkAddress(host: "fd00::1", port: 443))
    XCTAssertNotNil(try core.routeTCPWire(ipv4))
    XCTAssertNotNil(try core.routeTCPWire(ipv6))
  }

  func testMagentTCPConnectionRejectsHTTPConnectBodyFraming() throws {
    let requests = [
      Data(
        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nContent-Length: 1\r\n\r\nx"
          .utf8
      ),
      Data(
        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n"
          .appending("Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n").utf8
      ),
    ]

    for request in requests {
      let channel = try makeConnectionChannel()
      try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
      try writeInbound(request, to: channel)

      XCTAssertEqual(try readOutboundData(from: channel), httpErrorResponse(.badRequest))
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
    ]
    for request in malformedRequests {
      let channel = try makeConnectionChannel()
      try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
      try writeInbound(request, to: channel)

      XCTAssertEqual(try readOutboundData(from: channel), httpErrorResponse(.badRequest))
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

/// Byte-level expectations are independent of production response builders/encoders.
private let httpConnectEstablished = Data("HTTP/1.1 200 OK\r\n\r\n".utf8)

func httpErrorResponse(_ status: HTTPResponseStatus, version: String = "HTTP/1.1") -> Data {
  Data(
    "\(version) \(status.code) \(status.reasonPhrase)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      .utf8)
}
