import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest

@testable import Magent

/// `Socks4Connection` 请求、隧道、背压和 half-close 测试。
final class Socks4ConnectionTests: XCTestCase {
  func testMagentTCPConnectionBuffersFragmentedSOCKS4BindBeforeRejectingIt() throws {
    let channel = try makeConnectionChannel()
    defer { XCTAssertNoThrow(try channel.finish(acceptAlreadyClosed: true)) }
    try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 0)).wait()
    let request = Data([0x04, 0x02, 0x01, 0xBB, 127, 0, 0, 1, 0x00])

    try writeInbound(Data(request.prefix(4)), to: channel)
    XCTAssertNil(try readOutboundData(from: channel))
    try writeInbound(Data(request.dropFirst(4)), to: channel)

    XCTAssertEqual(try readOutboundData(from: channel), Data([0x00, 0x5B, 0, 0, 0, 0, 0, 0]))
    XCTAssertFalse(channel.isActive)
  }

  /// 直连成功后只发送一次 SOCKS4 成功响应。
  func testMagentTCPConnectionGrantsSOCKS4DirectConnectOnce() throws {
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
      TestDataCollector(expectedByteCount: 8, promise: responsePromise)
    ).wait()

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(socks4ConnectRequest(ipv4: [127, 0, 0, 1], port: targetPort), to: client)

    XCTAssertEqual(try responsePromise.futureResult.wait(), testSocks4Granted)
    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    XCTAssertTrue(targetChannel.isActive)
  }

  /// 通过 SOCKS4a 域名请求建立直连并转发数据。
  func testMagentTCPConnectionConnectsSOCKS4aDomain() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let payload = Data("socks4a-domain".utf8)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let targetServer = try ServerBootstrap(group: group)
      .childChannelInitializer { channel in
        targetAcceptedPromise.succeed(channel)
        return channel.pipeline.addHandler(
          TestDataCollector(expectedByteCount: payload.count, promise: targetPayloadPromise)
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

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let responsePromise = client.eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandler(
      TestDataCollector(expectedByteCount: testSocks4Granted.count, promise: responsePromise)
    ).wait()

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(socks4aConnectRequest(domain: "localhost", port: targetPort), to: client)

    XCTAssertEqual(try responsePromise.futureResult.wait(), testSocks4Granted)
    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)

    try writeData(payload, to: client)
    XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), payload)
  }

  /// SOCKS4 隧道两个方向均按手动读取许可转发。
  func testMagentTCPConnectionPullsSOCKS4TunnelInBothDirections() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let proxyPayload = Data("proxy-to-wire".utf8)
    let wirePayload = Data("wire-to-proxy".utf8)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    var channels: [Channel] = []
    defer {
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let targetServer = try ServerBootstrap(group: group)
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

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let responsePromise = client.eventLoop.makePromise(of: Data.self)
    let tunnelPayloadPromise = client.eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: testSocks4Granted.count, promise: responsePromise),
      TestDataCollector(
        expectedByteCount: testSocks4Granted.count + wirePayload.count,
        promise: tunnelPayloadPromise
      )
    ).wait()

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(socks4ConnectRequest(ipv4: [127, 0, 0, 1], port: targetPort), to: client)
    XCTAssertEqual(try responsePromise.futureResult.wait(), testSocks4Granted)

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    try writeData(proxyPayload, to: client)
    XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), proxyPayload)

    try writeData(wirePayload, to: targetChannel)
    XCTAssertEqual(try tunnelPayloadPromise.futureResult.wait(), testSocks4Granted + wirePayload)
  }

  /// 向客户端写入完成后才读取下一批 SOCKS4 下游数据。
  func testSOCKS4WaitsForProxyWriteFutureBeforeReadingNextWirePayload() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let firstTunnelWritePromise = eventLoop.makePromise(of: Data.self)
    let delayedWrites = DelayedTestWrites(
      eventLoop: eventLoop,
      firstWritePromise: firstTunnelWritePromise,
      writesBeforeDelay: 1
    )
    let firstPayload = Data("first-wire-payload".utf8)
    let secondPayload = Data("second-wire-payload".utf8)
    var channels: [Channel] = []
    defer {
      _ = try? delayedWrites.release().wait()
      shutdownPromise.succeed(())
      shutdownTestChannels(channels, group: group)
    }

    let targetServer = try ServerBootstrap(group: group)
      .childChannelInitializer { channel in
        targetAcceptedPromise.succeed(channel)
        return channel.eventLoop.makeSucceededFuture(())
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
      channel.pipeline.addHandler(delayedWrites)
    }
    channels.append(proxyServer)

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let grantedPromise = eventLoop.makePromise(of: Data.self)
    let tunnelPayloadsPromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: testSocks4Granted.count, promise: grantedPromise),
      TestDataCollector(
        expectedByteCount: testSocks4Granted.count + firstPayload.count + secondPayload.count,
        promise: tunnelPayloadsPromise
      )
    ).wait()

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(socks4ConnectRequest(ipv4: [127, 0, 0, 1], port: targetPort), to: client)
    XCTAssertEqual(try grantedPromise.futureResult.wait(), testSocks4Granted)

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    try writeData(firstPayload, to: targetChannel)
    XCTAssertEqual(try firstTunnelWritePromise.futureResult.wait(), firstPayload)

    try writeData(secondPayload, to: targetChannel)
    XCTAssertEqual(try delayedWrites.writeCount().wait(), 2)

    try delayedWrites.release().wait()
    XCTAssertEqual(
      try tunnelPayloadsPromise.futureResult.wait(),
      testSocks4Granted + firstPayload + secondPayload
    )
    XCTAssertEqual(try delayedWrites.writeCount().wait(), 3)
  }

  /// 向下游写入完成后才读取下一批 SOCKS4 客户端数据。
  func testSOCKS4WaitsForWireWriteFutureBeforeReadingNextProxyPayload() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let firstPayload = Data(repeating: 0xA5, count: 8 * 1024 * 1024)
    let secondPayload = Data("second-proxy-payload".utf8)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    let manualReads = ManualTestReads(eventLoop: eventLoop)
    var channels: [Channel] = []
    defer {
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
            expectedByteCount: firstPayload.count + secondPayload.count,
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
      channel.pipeline.addHandler(manualReads)
    }
    channels.append(proxyServer)

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let grantedPromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandler(
      TestDataCollector(expectedByteCount: testSocks4Granted.count, promise: grantedPromise)
    ).wait()

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try manualReads.enqueue([socks4ConnectRequest(ipv4: [127, 0, 0, 1], port: targetPort)]).wait()
    XCTAssertEqual(try grantedPromise.futureResult.wait(), testSocks4Granted)

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    try manualReads.enqueue([firstPayload, secondPayload]).wait()

    XCTAssertEqual(try manualReads.deliveredCount().wait(), 2)

    try targetChannel.setOption(ChannelOptions.autoRead, value: true).wait()
    let receivedPayload = try targetPayloadPromise.futureResult.wait()
    XCTAssertEqual(receivedPayload.count, firstPayload.count + secondPayload.count)
    XCTAssertEqual(receivedPayload.suffix(secondPayload.count), secondPayload)
    XCTAssertEqual(try manualReads.deliveredCount().wait(), 3)
  }

  /// SOCKS4 客户端半关闭前的最后一批数据必须先于下游 FIN 转发。
  func testSOCKS4ProxyHalfCloseForwardsFinalPayloadBeforeWireFIN() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let proxyPayload = Data("final-proxy-payload".utf8)
    let wireResponse = Data("response-after-proxy-fin".utf8)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    let targetInputClosed = expectation(
      description: "target receives FIN after final proxy payload")
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
    let grantedPromise = eventLoop.makePromise(of: Data.self)
    let responsePromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: testSocks4Granted.count, promise: grantedPromise),
      TestDataCollector(
        expectedByteCount: testSocks4Granted.count + wireResponse.count,
        promise: responsePromise
      )
    ).wait()

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(socks4ConnectRequest(ipv4: [127, 0, 0, 1], port: targetPort), to: client)
    XCTAssertEqual(try grantedPromise.futureResult.wait(), testSocks4Granted)

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    try writeData(proxyPayload, to: client)
    try client.close(mode: .output).wait()

    wait(for: [targetInputClosed], timeout: 2)
    XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), proxyPayload)
    XCTAssertTrue(targetChannel.isActive)

    try writeData(wireResponse, to: targetChannel)
    XCTAssertEqual(try responsePromise.futureResult.wait(), testSocks4Granted + wireResponse)
  }

  /// SOCKS4 建连期间收到半关闭时等待隧道建立后再传播。
  func testSOCKS4DefersProxyHalfCloseUntilTunnelIsEstablished() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let wireResponse = Data("response-after-handshake-fin".utf8)
    let targetInputClosed = expectation(description: "target receives deferred proxy FIN")
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
        expectedByteCount: testSocks4Granted.count + wireResponse.count,
        promise: responsePromise
      )
    ).wait()

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(socks4ConnectRequest(ipv4: [127, 0, 0, 1], port: targetPort), to: client)
    try client.close(mode: .output).wait()

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    wait(for: [targetInputClosed], timeout: 2)
    XCTAssertTrue(targetChannel.isActive)

    try writeData(wireResponse, to: targetChannel)
    XCTAssertEqual(try responsePromise.futureResult.wait(), testSocks4Granted + wireResponse)
  }

  /// SOCKS4 下游半关闭后保留客户端向下游的写入方向。
  func testSOCKS4WireHalfCloseKeepsProxyToWireDirectionOpen() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let proxyPayload = Data("payload-after-wire-fin".utf8)
    let targetPayloadPromise = eventLoop.makePromise(of: Data.self)
    let clientInputClosed = expectation(description: "client receives wire FIN")
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
    let grantedPromise = eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandlers(
      TestDataCollector(expectedByteCount: testSocks4Granted.count, promise: grantedPromise),
      TestInputClosedRecorder(expectation: clientInputClosed)
    ).wait()

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    try writeData(socks4ConnectRequest(ipv4: [127, 0, 0, 1], port: targetPort), to: client)
    XCTAssertEqual(try grantedPromise.futureResult.wait(), testSocks4Granted)

    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    try targetChannel.close(mode: .output).wait()

    wait(for: [clientInputClosed], timeout: 2)
    XCTAssertTrue(client.isActive)
    XCTAssertTrue(targetChannel.isActive)

    try writeData(proxyPayload, to: client)
    XCTAssertEqual(try targetPayloadPromise.futureResult.wait(), proxyPayload)
  }

  /// SOCKS4 未完整握手便半关闭时回收连接。
  func testSOCKS4ClosesIncompleteRequestWhenProxyHalfCloses() throws {
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
    let clientClosed = expectation(
      description: "incomplete SOCKS4 request closes without a rejected response")
    client.closeFuture.whenComplete { _ in
      clientClosed.fulfill()
    }

    try writeData(Data([0x04, 0x01, 0x01, 0xBB]), to: client)
    try client.close(mode: .output).wait()

    wait(for: [clientClosed], timeout: 2)
  }

  /// 通过节点列表选中的 Shadowsocks Wire 建连后完成 SOCKS4 握手。
  func testMagentTCPConnectionWritesShadowsocksHandshakeAndGrantsSOCKS4Connect() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let proxyNodeAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let cipher = ProxyCipher.aes256Gcm
    let shadowsocksAddressLength = 1 + 4 + 2
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
      TestDataCollector(expectedByteCount: 8, promise: responsePromise)
    ).wait()

    try writeData(socks4ConnectRequest(ipv4: [203, 0, 113, 10], port: 443), to: client)

    XCTAssertEqual(try responsePromise.futureResult.wait(), testSocks4Granted)
    XCTAssertEqual(try handshakePromise.futureResult.wait().count, expectedHandshakeLength)
    channels.append(try proxyNodeAcceptedPromise.futureResult.wait())
  }

  /// SOCKS4 直连迟到完成时不得重复发送失败响应。
  func testMagentTCPConnectionSendsSingleSOCKS4RejectedWhenDirectConnectCompletesLate() throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let eventLoop = group.next()
    let shutdownPromise = eventLoop.makePromise(of: Void.self)
    let targetAcceptedPromise = eventLoop.makePromise(of: Channel.self)
    let firstResponsePromise = eventLoop.makePromise(of: Data.self)
    let delayedWrites = DelayedTestWrites(
      eventLoop: eventLoop, firstWritePromise: firstResponsePromise)
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
    let proxyServer = try bindTCPProxy(
      group: group,
      core: core,
      shutdownFuture: shutdownPromise.futureResult
    ) { channel in
      channel.pipeline.addHandlers(
        SplitProxyRequest(requestLength: 9),
        delayedWrites
      )
    }
    channels.append(proxyServer)

    let client = try ClientBootstrap(group: group).connect(to: XCTUnwrap(proxyServer.localAddress))
      .wait()
    channels.append(client)
    let clientResponsePromise = client.eventLoop.makePromise(of: Data.self)
    try client.pipeline.addHandler(
      TestDataCollector(expectedByteCount: 8, promise: clientResponsePromise)
    ).wait()

    let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
    var requestAndPayload = socks4ConnectRequest(ipv4: [127, 0, 0, 1], port: targetPort)
    requestAndPayload.append(0xAA)
    try writeData(requestAndPayload, to: client)

    XCTAssertEqual(try firstResponsePromise.futureResult.wait(), testSocks4Rejected)
    let targetChannel = try targetAcceptedPromise.futureResult.wait()
    channels.append(targetChannel)
    let targetClosed = expectation(
      description: "late SOCKS4 direct wire closes after rejected wins")
    targetChannel.closeFuture.whenComplete { _ in
      targetClosed.fulfill()
    }
    wait(for: [targetClosed], timeout: 2)

    XCTAssertEqual(try delayedWrites.writeCount().wait(), 1)
    try delayedWrites.release().wait()
    XCTAssertEqual(try clientResponsePromise.futureResult.wait(), testSocks4Rejected)
  }
}

private func socks4ConnectRequest(ipv4: [UInt8], port: Int) -> Data {
  precondition(ipv4.count == 4)
  precondition((1...65535).contains(port))
  return Data([
    0x04,
    0x01,
    UInt8(port >> 8),
    UInt8(port & 0xFF),
    ipv4[0],
    ipv4[1],
    ipv4[2],
    ipv4[3],
    0x00,
  ])
}

private func socks4aConnectRequest(domain: String, port: Int) -> Data {
  precondition(!domain.isEmpty)
  precondition((1...65535).contains(port))
  return Data([
    0x04,
    0x01,
    UInt8(port >> 8),
    UInt8(port & 0xFF),
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
  ]) + Data(domain.utf8) + Data([0x00])
}

private let testSocks4Granted = Data([0x00, 0x5A, 0, 0, 0, 0, 0, 0])
private let testSocks4Rejected = Data([0x00, 0x5B, 0, 0, 0, 0, 0, 0])
