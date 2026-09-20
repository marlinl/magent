import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest

@testable import Magent

/// `Socks5Connection` 请求、隧道、背压和 half-close 测试。
final class Socks5ConnectionTests: XCTestCase {
  func testMagentTCPConnectionAcceptsFragmentedSOCKS5Greeting() throws {
    let channel = try makeConnectionChannel()
    defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }

    try writeInbound(Data([0x05]), to: channel)
    XCTAssertNil(try readOutboundData(from: channel))

    try writeInbound(Data([0x01, 0x00]), to: channel)
    XCTAssertEqual(try readOutboundData(from: channel), Data([0x05, 0x00]))
  }

  func testMagentTCPConnectionRejectsSOCKS5GreetingWithoutNoAuth() throws {
    let channel = try makeConnectionChannel()
    defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }

    try writeInbound(Data([0x05, 0x01, 0x02]), to: channel)
    XCTAssertEqual(try readOutboundData(from: channel), Data([0x05, 0xFF]))
    XCTAssertFalse(channel.isActive)
  }

  func testMagentTCPConnectionRejectsSOCKS5BindCommand() throws {
    let channel = try makeConnectionChannel()
    defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
    try writeInbound(Data([0x05, 0x01, 0x00]), to: channel)
    XCTAssertEqual(try readOutboundData(from: channel), Data([0x05, 0x00]))

    let bind = Data([0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1, 0x01, 0xBB])
    try writeInbound(bind, to: channel)
    let response = try XCTUnwrap(readOutboundData(from: channel))

    XCTAssertEqual(response.prefix(2), Data([0x05, 0x07]))
    XCTAssertFalse(channel.isActive)
  }

  /// SOCKS5 直连建立后只发送一次成功响应。
  func testMagentTCPConnectionEstablishesSOCKS5DirectConnectOnce() throws {
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
    let greetingPromise = client.eventLoop.makePromise(of: Data.self)
    let responsesPromise = client.eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12, promise: responsesPromise)
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(
      socks5ConnectRequest(.ipv4(Data([127, 0, 0, 1]), port: targetPort)),
      to: client
    )

    let responses = try responsesPromise.futureResult.wait()
    XCTAssertEqual(responses.prefix(2), testSocks5NoAuthentication)
    XCTAssertEqual(responses.dropFirst(2).prefix(2), Data([0x05, 0x00]))
    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    XCTAssertTrue(targetChannel.isActive)
  }

  /// SOCKS5 隧道两个方向均等待上一批写入完成。
  func testSOCKS5TCPUsesStrictBackpressureInBothDirections() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let firstWirePayload = Data("first-socks5-wire-payload".utf8)
    let secondWirePayload = Data("second-socks5-wire-payload".utf8)
    let firstProxyPayload = Data(repeating: 0xA5, count: 8 * 1024 * 1024)
    let secondProxyPayload = Data("second-socks5-proxy-payload".utf8)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    let firstTunnelWritePromise = eventLoop.makePromise(of: Data.self)
    let manualReads = ManualTestReads(eventLoop: eventLoop)
    let delayedWrites = DelayedTestWrites(
      eventLoop: eventLoop,
      firstWritePromise: firstTunnelWritePromise,
      writesBeforeDelay: 2
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
    let greetingPromise = eventLoop.makePromise(of: Data.self)
    let responsesPromise = eventLoop.makePromise(of: Data.self)
    let tunnelPayloadsPromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12, promise: responsesPromise),
      TestDataCollector(
        expectedByteCount: 12 + firstWirePayload.count + secondWirePayload.count,
        promise: tunnelPayloadsPromise
      )
    ).wait()

    try manualReads.enqueue([Data([0x05, 0x01, 0x00])]).wait()
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    let connectRequest = socks5ConnectRequest(.ipv4(Data([127, 0, 0, 1]), port: targetPort))
    try manualReads.enqueue([connectRequest]).wait()
    let responses = try responsesPromise.futureResult.wait()
    XCTAssertEqual(responses.prefix(2), testSocks5NoAuthentication)
    XCTAssertEqual(responses.dropFirst(2).prefix(2), Data([0x05, 0x00]))

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    try writeData(firstWirePayload, to: targetChannel)
    XCTAssertEqual(try firstTunnelWritePromise.futureResult.wait(), firstWirePayload)
    try writeData(secondWirePayload, to: targetChannel)
    XCTAssertEqual(try delayedWrites.writeCount().wait(), 3)

    try delayedWrites.release().wait()
    XCTAssertEqual(
      try tunnelPayloadsPromise.futureResult.wait(),
      responses + firstWirePayload + secondWirePayload
    )
    XCTAssertEqual(try delayedWrites.writeCount().wait(), 4)

    try manualReads.enqueue([firstProxyPayload, secondProxyPayload]).wait()
    XCTAssertEqual(try manualReads.deliveredCount().wait(), 3)

    try targetChannel.setOption(ChannelOptions.autoRead, value: true).wait()
    let receivedPayload = try targetPayloadPromise.futureResult.wait()
    XCTAssertEqual(receivedPayload.count, firstProxyPayload.count + secondProxyPayload.count)
    XCTAssertEqual(receivedPayload.suffix(secondProxyPayload.count), secondProxyPayload)
    XCTAssertEqual(try manualReads.deliveredCount().wait(), 4)
  }

  /// SOCKS5 客户端半关闭前的数据必须先于下游 FIN 转发。
  func testSOCKS5TCPProxyHalfCloseForwardsFinalPayloadBeforeWireFIN() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let proxyPayload = Data("final-socks5-proxy-payload".utf8)
    let wirePayload = Data("final-socks5-wire-payload".utf8)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    let targetInputClosed = expectation(
      description: "SOCKS5 target receives FIN after proxy payload")
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
    let greetingPromise = eventLoop.makePromise(of: Data.self)
    let responsesPromise = eventLoop.makePromise(of: Data.self)
    let wirePayloadPromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12, promise: responsesPromise),
      TestDataCollector(expectedByteCount: 12 + wirePayload.count, promise: wirePayloadPromise)
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(socks5ConnectRequest(.ipv4(Data([127, 0, 0, 1]), port: targetPort)), to: client)
    _ = try responsesPromise.futureResult.wait()

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

  /// SOCKS5 下游半关闭后保留另一方向的转发。
  func testSOCKS5TCPWireHalfCloseKeepsProxyToWireDirectionOpen() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let wirePayload = Data("final-socks5-wire-payload".utf8)
    let proxyPayload = Data("socks5-payload-after-wire-fin".utf8)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    let clientInputClosed = expectation(
      description: "SOCKS5 client receives FIN after wire payload")
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
    let greetingPromise = eventLoop.makePromise(of: Data.self)
    let responsesPromise = eventLoop.makePromise(of: Data.self)
    let wirePayloadPromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12, promise: responsesPromise),
      TestDataCollector(expectedByteCount: 12 + wirePayload.count, promise: wirePayloadPromise),
      TestInputClosedRecorder(expectation: clientInputClosed)
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(socks5ConnectRequest(.ipv4(Data([127, 0, 0, 1]), port: targetPort)), to: client)
    _ = try responsesPromise.futureResult.wait()

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

  /// SOCKS5 建连期间收到半关闭时等待隧道建立后再传播。
  func testSOCKS5TCPDefersProxyHalfCloseUntilTunnelIsEstablished() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let targetInputClosed = expectation(description: "SOCKS5 target receives deferred proxy FIN")
    let wirePayload = Data("socks5-response-after-handshake-fin".utf8)
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
    let greetingPromise = eventLoop.makePromise(of: Data.self)
    let responsePromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12 + wirePayload.count, promise: responsePromise)
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(socks5ConnectRequest(.ipv4(Data([127, 0, 0, 1]), port: targetPort)), to: client)
    try client.close(mode: .output).wait()

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    wait(for: [targetInputClosed], timeout: 2)

    try writeData(wirePayload, to: targetChannel)
    XCTAssertEqual(try responsePromise.futureResult.wait().suffix(wirePayload.count), wirePayload)
  }

  /// 当前 IPv4 UDP relay 必须拒绝 IPv6 control connection 的 association。
  func testSOCKS5UDPAssociateRejectsIPv6ControlBecauseRelayIsIPv4() throws {
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
    let proxyServer: Channel
    do {
      proxyServer = try ServerBootstrap(group: group)
        .childChannelOption(ChannelOptions.autoRead, value: false)
        .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        .childChannelInitializer { channel in
          channel.pipeline.addHandler(
            MagentTCPConnection(
              channel,
              core: core,
              dnsAddress: nil,
              shutdownFuture: shutdownPromise.futureResult
            )
          )
        }
        .bind(host: "::1", port: 0)
        .wait()
    } catch {
      throw XCTSkip("IPv6 loopback is unavailable: \(error)")
    }
    channels.append(proxyServer)

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let greetingPromise = eventLoop.makePromise(of: Data.self)
    let responsesPromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12, promise: responsesPromise)
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    let controlClosed = expectation(
      description: "IPv6 SOCKS5 UDP control connection closes after rejection")
    client.closeFuture.whenComplete { _ in
      controlClosed.fulfill()
    }
    try writeData(Data([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), to: client)
    let responses = try responsesPromise.futureResult.wait()
    XCTAssertEqual(responses.prefix(2), testSocks5NoAuthentication)
    let associateResponse = responses.dropFirst(2)
    XCTAssertEqual(associateResponse, Data([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
    wait(for: [controlClosed], timeout: 2)
    XCTAssertFalse(client.isActive)
  }

  /// 通过节点列表选中的 Shadowsocks Wire 建立 SOCKS5 隧道。
  func testMagentTCPConnectionWritesShadowsocksHandshakeAndEstablishesSOCKS5Connect() throws {
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

    let defaultNode = ProxyNode(
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
    let greetingPromise = client.eventLoop.makePromise(of: Data.self)
    let responsesPromise = client.eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12, promise: responsesPromise)
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    try writeData(socks5ConnectRequest(.domain(host, port: 443)), to: client)

    let responses = try responsesPromise.futureResult.wait()
    XCTAssertEqual(responses.prefix(2), testSocks5NoAuthentication)
    XCTAssertEqual(responses.dropFirst(2).prefix(2), Data([0x05, 0x00]))
    XCTAssertEqual(try handshakePromise.futureResult.wait().count, expectedHandshakeLength)
    channels.append(try proxyNodeAcceptedPromise.futureResult.wait())
  }

  /// SOCKS5 直连迟到完成时不得重复发送失败响应。
  func testMagentTCPConnectionSendsSingleSOCKS5FailureWhenDirectConnectCompletesLate() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let firstResponsePromise = eventLoop.makePromise(of: Data.self)
    let delayedWrites = DelayedTestWrites(
      eventLoop: eventLoop,
      firstWritePromise: firstResponsePromise,
      writesBeforeDelay: 1
    )
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

    let core = try MagentCore(
      defaultDecision: .direct,
      proxyNodes: [],
      defaultTimeout: 10_000,
      rules: []
    )
    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    let request = socks5ConnectRequest(.ipv4(Data([127, 0, 0, 1]), port: targetPort))
    let proxyServer = try bindTCPProxy(
      group: group,
      core: core,
      shutdownFuture: shutdownPromise.futureResult
    ) { channel in
      channel.pipeline.addHandlers(
        SplitProxyRequest(requestLength: request.count, leadingRequestLengths: [3]),
        delayedWrites
      )
    }
    channels.append(proxyServer)

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let greetingPromise = client.eventLoop.makePromise(of: Data.self)
    let responsesPromise = client.eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(
        expectedByteCount: testSocks5NoAuthentication.count + testSocks5GeneralFailure.count,
        promise: responsesPromise
      )
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)

    var requestAndPayload = request
    requestAndPayload.append(0xAA)
    try writeData(requestAndPayload, to: client)

    XCTAssertEqual(try firstResponsePromise.futureResult.wait(), testSocks5GeneralFailure)
    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    let targetClosed = expectation(
      description: "late SOCKS5 direct wire closes after failure reply wins")
    targetChannel.closeFuture.whenComplete { _ in
      targetClosed.fulfill()
    }
    wait(for: [targetClosed], timeout: 2)

    XCTAssertEqual(try delayedWrites.writeCount().wait(), 2)
    try delayedWrites.release().wait()
    XCTAssertEqual(
      try responsesPromise.futureResult.wait(),
      testSocks5NoAuthentication + testSocks5GeneralFailure
    )
  }
}

extension Socks5ConnectionTests {
  /// 无 DNS 配置时仍可直连 UDP IP 目标，畸形数据包经 control connection 统一报错。
  func testSOCKS5UDPDirectDataPlaneRoundTripsAndRoutesMalformedPacketToControlErrorChain() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    let clientResponsePromise = eventLoop.makePromise(of: Data.self)
    let payload = Data("direct-udp-request".utf8)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let targetServer = try bindTestDatagram(group: group) { context, envelope in
      targetPayloadPromise.succeed(Data(envelope.data.readableBytesView))
      writeTestDatagram(envelope, through: context)
    }
    channels.append(targetServer)
    let core = try makeUDPTestCore(decision: .direct, nodes: [])
    let association = try establishSOCKS5UDPAssociation(
      group: group,
      core: core,
      shutdownFuture: shutdownPromise.futureResult,
      channels: &channels
    )
    let udpClient = try bindTestDatagram(group: group) { _, envelope in
      clientResponsePromise.succeed(Data(envelope.data.readableBytesView))
    }
    channels.append(udpClient)

    let targetAddress = try XCTUnwrap(targetServer.localAddress.flatMap(NetworkAddress.init))
    let request =
      Data([0x00, 0x00, 0x00]) + Socks5Connection.addressBytes(of: targetAddress) + payload
    try writeDatagram(request, from: udpClient, to: association.relayAddress)

    XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), payload)
    XCTAssertEqual(try clientResponsePromise.futureResult.wait(), request)

    let controlClosed = expectation(
      description: "malformed UDP datagram closes its control connection")
    association.controlChannel.closeFuture.whenComplete { _ in
      controlClosed.fulfill()
    }
    var fragmentedRequest = request
    fragmentedRequest[2] = 0x01
    try writeDatagram(fragmentedRequest, from: udpClient, to: association.relayAddress)
    wait(for: [controlClosed], timeout: 2)
  }

  /// 缺少 DNS 地址时拒绝 UDP 直连域名，并通过 control connection 关闭整个 association。
  func testSOCKS5UDPDirectDomainRejectsMissingDNSAddress() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }
    let core = try makeUDPTestCore(decision: .direct, nodes: [])
    let association = try establishSOCKS5UDPAssociation(
      group: group,
      core: core,
      dnsAddress: nil,
      shutdownFuture: shutdownPromise.futureResult,
      channels: &channels
    )
    let udpClient = try bindTestDatagram(group: group) { _, _ in
      XCTFail("A direct domain without DNS must not produce a UDP response")
    }
    channels.append(udpClient)
    let controlClosed = expectation(description: "missing DNS closes the control connection")
    association.controlChannel.closeFuture.whenComplete { _ in
      controlClosed.fulfill()
    }
    let target = NetworkAddress.domain("udp.test.invalid", port: 5353)
    let request = Data([0x00, 0x00, 0x00]) + Socks5Connection.addressBytes(of: target) + Data([1])
    try writeDatagram(request, from: udpClient, to: association.relayAddress)
    wait(for: [controlClosed], timeout: 2)
  }

  /// UDP 直连域名通过单个配置 DNS 解析并完成往返传输。
  func testSOCKS5UDPDirectDomainUsesConfiguredRemoteDNS() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    let clientResponsePromise = eventLoop.makePromise(of: Data.self)
    let payload = Data("direct-domain-udp-request".utf8)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let dnsServer = try bindTestDatagram(group: group) { context, envelope in
      let response = try testDNSResponse(for: Data(envelope.data.readableBytesView))
      var buffer = context.channel.allocator.buffer(capacity: response.count)
      buffer.writeBytes(response)
      writeTestDatagram(
        AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: buffer),
        through: context
      )
    }
    channels.append(dnsServer)
    let targetServer = try bindTestDatagram(group: group) { context, envelope in
      targetPayloadPromise.succeed(Data(envelope.data.readableBytesView))
      writeTestDatagram(envelope, through: context)
    }
    channels.append(targetServer)
    let core = try makeUDPTestCore(decision: .direct, nodes: [])
    let association = try establishSOCKS5UDPAssociation(
      group: group,
      core: core,
      dnsAddress: try XCTUnwrap(dnsServer.localAddress),
      shutdownFuture: shutdownPromise.futureResult,
      channels: &channels
    )
    let udpClient = try bindTestDatagram(group: group) { _, envelope in
      clientResponsePromise.succeed(Data(envelope.data.readableBytesView))
    }
    channels.append(udpClient)

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    let targetAddress = NetworkAddress.domain("udp.test.invalid", port: targetPort)
    let request =
      Data([0x00, 0x00, 0x00]) + Socks5Connection.addressBytes(of: targetAddress) + payload
    try writeDatagram(request, from: udpClient, to: association.relayAddress)

    XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), payload)
    let responseAddress = NetworkAddress.ipv4(Data([127, 0, 0, 1]), port: targetPort)
    let expectedResponse =
      Data([0x00, 0x00, 0x00])
      + Socks5Connection.addressBytes(of: responseAddress)
      + payload
    XCTAssertEqual(try clientResponsePromise.futureResult.wait(), expectedResponse)
    XCTAssertTrue(association.controlChannel.isActive)
  }

  /// IPv4 SOCKS5 relay 使用 IPv6 下游 Channel 访问 IPv6 目标。
  func testSOCKS5UDPIPv4RelayUsesIPv6ChannelForIPv6Target() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    let clientResponsePromise = eventLoop.makePromise(of: Data.self)
    let payload = Data("direct-ipv6-udp-request".utf8)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let targetServer: Channel
    do {
      targetServer = try bindTestDatagram(group: group, host: "::1") { context, envelope in
        targetPayloadPromise.succeed(Data(envelope.data.readableBytesView))
        writeTestDatagram(envelope, through: context)
      }
    } catch {
      throw XCTSkip("IPv6 loopback is unavailable: \(error)")
    }
    channels.append(targetServer)
    let core = try makeUDPTestCore(decision: .direct, nodes: [])
    let association = try establishSOCKS5UDPAssociation(
      group: group,
      core: core,
      shutdownFuture: shutdownPromise.futureResult,
      channels: &channels
    )
    let udpClient = try bindTestDatagram(group: group) { _, envelope in
      clientResponsePromise.succeed(Data(envelope.data.readableBytesView))
    }
    channels.append(udpClient)

    let targetAddress = try XCTUnwrap(targetServer.localAddress.flatMap(NetworkAddress.init))
    let request =
      Data([0x00, 0x00, 0x00]) + Socks5Connection.addressBytes(of: targetAddress) + payload
    try writeDatagram(request, from: udpClient, to: association.relayAddress)

    XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), payload)
    XCTAssertEqual(try clientResponsePromise.futureResult.wait(), request)
    XCTAssertTrue(association.controlChannel.isActive)
  }

  /// UDP 代理域名无需本地 DNS，按节点 Wire 加密请求并解密回包。
  func testSOCKS5UDPShadowsocksDataPlaneEncryptsRoutesAndDecryptsResponse() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let proxyTargetPromise = eventLoop.makePromise(of: NetworkAddress.self)
    let proxyPayloadPromise = eventLoop.makePromise(of: Data.self)
    let clientResponsePromise = eventLoop.makePromise(of: Data.self)
    let requestPayload = Data("proxied-udp-request".utf8)
    let responsePayload = Data("proxied-udp-response".utf8)
    let cipher = ProxyCipher.aes256Gcm
    let password = "udp-test-password"
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let shadowsocksServer = try bindTestDatagram(group: group) { context, envelope in
      guard let address = context.channel.localAddress else {
        throw MagentError.invalidAddress("test Shadowsocks UDP server has no local address")
      }
      let node = ProxyNode(address: address, cipher: cipher, password: password)
      let wire = try ShadowsocksUDPWire(proxyNode: node)
      let decoded = try wire.decodeInbound(Data(envelope.data.readableBytesView))
      proxyTargetPromise.succeed(decoded.address)
      proxyPayloadPromise.succeed(decoded.data)
      let output = try wire.encodeOutbound(responsePayload, address: decoded.address)
      var buffer = context.channel.allocator.buffer(capacity: output.count)
      buffer.writeBytes(output)
      let response = AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: buffer)
      writeTestDatagram(response, through: context)
    }
    channels.append(shadowsocksServer)
    let nodeAddress = try XCTUnwrap(shadowsocksServer.localAddress)
    let proxyNode = ProxyNode(address: nodeAddress, cipher: cipher, password: password)
    let core = try makeUDPTestCore(decision: .proxy(proxyNode.id), nodes: [proxyNode])
    let association = try establishSOCKS5UDPAssociation(
      group: group,
      core: core,
      shutdownFuture: shutdownPromise.futureResult,
      channels: &channels
    )
    let udpClient = try bindTestDatagram(group: group) { _, envelope in
      clientResponsePromise.succeed(Data(envelope.data.readableBytesView))
    }
    channels.append(udpClient)

    let targetAddress = NetworkAddress.domain("udp.example.com", port: 5353)
    let request =
      Data([0x00, 0x00, 0x00])
      + Socks5Connection.addressBytes(of: targetAddress)
      + requestPayload
    try writeDatagram(request, from: udpClient, to: association.relayAddress)

    XCTAssertEqual(try proxyTargetPromise.futureResult.wait(), targetAddress)
    XCTAssertEqual(try proxyPayloadPromise.futureResult.wait(), requestPayload)
    let expectedResponse =
      Data([0x00, 0x00, 0x00])
      + Socks5Connection.addressBytes(of: targetAddress)
      + responsePayload
    XCTAssertEqual(try clientResponsePromise.futureResult.wait(), expectedResponse)
    XCTAssertTrue(association.controlChannel.isActive)
  }
}

extension Socks5ConnectionTests {
  /// 按生产握手流程创建独占 UDP association，并记录待清理的 Channel。
  fileprivate func establishSOCKS5UDPAssociation(
    group: EventLoopGroup,
    core: MagentCore,
    dnsAddress: SocketAddress? = nil,
    shutdownFuture: EventLoopFuture<Void>,
    channels: inout [Channel]
  ) throws -> (controlChannel: Channel, relayAddress: SocketAddress) {
    let proxyServer = try bindTCPProxy(
      group: group,
      core: core,
      dnsAddress: dnsAddress,
      shutdownFuture: shutdownFuture
    )
    channels.append(proxyServer)
    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let greetingPromise = client.eventLoop.makePromise(of: Data.self)
    let responsesPromise = client.eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: 2, promise: greetingPromise),
      TestDataCollector(expectedByteCount: 12, promise: responsesPromise)
    ).wait()

    try writeData(Data([0x05, 0x01, 0x00]), to: client)
    XCTAssertEqual(try greetingPromise.futureResult.wait(), testSocks5NoAuthentication)
    try writeData(Data([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0]), to: client)

    let responses = try responsesPromise.futureResult.wait()
    XCTAssertEqual(responses.prefix(2), testSocks5NoAuthentication)
    let associateResponse = responses.dropFirst(2)
    XCTAssertEqual(associateResponse.prefix(8), Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1]))
    let port =
      Int(associateResponse[associateResponse.index(associateResponse.startIndex, offsetBy: 8)])
      << 8
      | Int(associateResponse[associateResponse.index(associateResponse.startIndex, offsetBy: 9)])
    XCTAssertGreaterThan(port, 0)
    return (client, try SocketAddress(ipAddress: "127.0.0.1", port: port))
  }

  /// 通过指定决策和完整节点列表创建 UDP 路由测试的 Core。
  fileprivate func makeUDPTestCore(decision: Decision, nodes: [ProxyNode]) throws -> MagentCore {
    return try MagentCore(
      defaultDecision: decision,
      proxyNodes: nodes,
      defaultTimeout: 10_000,
      rules: []
    )
  }
}

private final class TestDatagramHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = AddressedEnvelope<ByteBuffer>

  private let receive: @Sendable (ChannelHandlerContext, InboundIn) throws -> Void

  init(receive: @escaping @Sendable (ChannelHandlerContext, InboundIn) throws -> Void) {
    self.receive = receive
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    do {
      try receive(context, unwrapInboundIn(data))
    } catch {
      context.fireErrorCaught(error)
    }
  }

  func errorCaught(context: ChannelHandlerContext, error _: Error) {
    context.close(promise: nil)
  }
}

private func bindTestDatagram(
  group: EventLoopGroup,
  host: String = "127.0.0.1",
  receive: @escaping @Sendable (ChannelHandlerContext, AddressedEnvelope<ByteBuffer>) throws -> Void
) throws -> Channel {
  try DatagramBootstrap(group: group)
    .channelInitializer { channel in
      channel.pipeline.addHandler(TestDatagramHandler(receive: receive))
    }
    .bind(host: host, port: 0)
    .wait()
}

/// Sends a test datagram while keeping context-relative error propagation on its owning EventLoop.
private func writeTestDatagram(
  _ envelope: AddressedEnvelope<ByteBuffer>,
  through context: ChannelHandlerContext
) {
  let loopBoundContext = context.loopBound
  context.channel.writeAndFlush(envelope).whenFailure {
    loopBoundContext.value.fireErrorCaught($0)
  }
}

private func writeDatagram(_ data: Data, from channel: Channel, to address: SocketAddress) throws {
  var buffer = channel.allocator.buffer(capacity: data.count)
  buffer.writeBytes(data)
  try channel.writeAndFlush(AddressedEnvelope(remoteAddress: address, data: buffer)).wait()
}

private func testDNSResponse(for query: Data) throws -> Data {
  guard query.count >= 17 else {
    throw MagentError.malformedRequest("test DNS query is too short")
  }
  var offset = 12
  while offset < query.count {
    let labelLength = Int(query[offset])
    offset += 1
    if labelLength == 0 {
      break
    }
    guard labelLength <= 63, offset + labelLength <= query.count else {
      throw MagentError.malformedRequest("test DNS query has an invalid label")
    }
    offset += labelLength
  }
  guard offset + 4 <= query.count else {
    throw MagentError.malformedRequest("test DNS query has an incomplete question")
  }
  let recordType = query.readBigEndianUInt16(at: offset)
  let questionEnd = offset + 4
  let recordData: Data
  switch recordType {
  case 1:
    recordData = Data([127, 0, 0, 1])
  case 28:
    recordData = Data(repeating: 0, count: 15) + Data([1])
  default:
    throw MagentError.malformedRequest("test DNS query uses an unsupported record type")
  }

  var response = Data(query.prefix(2))
  response.append(contentsOf: [0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
  response.append(query[12..<questionEnd])
  response.append(contentsOf: [0xC0, 0x0C])
  response.append(contentsOf: UInt16(recordType).bigEndianBytes)
  response.append(contentsOf: [0x00, 0x01, 0x00, 0x00, 0x00, 0x3C])
  response.append(contentsOf: UInt16(recordData.count).bigEndianBytes)
  response.append(recordData)
  return response
}

private func socks5ConnectRequest(_ address: NetworkAddress) -> Data {
  Data([0x05, 0x01, 0x00]) + Socks5Connection.addressBytes(of: address)
}

private let testSocks5NoAuthentication = Data([0x05, 0x00])
private let testSocks5GeneralFailure = Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
