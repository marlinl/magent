import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest

@testable import Magent

/// `Magent` 启动、重启和关闭生命周期测试。
final class MagentTests: XCTestCase {
  /// 超过原 256 条上限的连接仍可握手，restart 和 close 必须关闭所属运行周期的连接。
  func testMagentAcceptsMoreThan256ConnectionsAcrossRestart() async throws {
    let supportGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let portProbe = try await ServerBootstrap(group: supportGroup)
      .childChannelInitializer { channel in channel.pipeline.addHandler(TestInboundHandler()) }
      .bind(host: "127.0.0.1", port: 0)
      .get()
    let port = try XCTUnwrap(portProbe.localAddress?.port)
    try await portProbe.close().get()

    let config = MagentConfig(
      address: .domain("127.0.0.1", port: port)
    )
    let magent = Magent(threadNumber: 2)
    var clients: [Channel] = []
    var testError: Error?

    do {
      try await magent.start(config)

      for _ in 0..<257 {
        let (client, greeting) = try await connectSOCKS5Client(group: supportGroup, port: port)
        clients.append(client)
        let greetingData = try await greeting.get()
        XCTAssertEqual(greetingData, Data([0x05, 0x00]))
      }
      XCTAssertTrue(clients.allSatisfy { $0.isActive })

      let oldRuntimeClosed = expectation(description: "restart closes all old runtime connections")
      oldRuntimeClosed.expectedFulfillmentCount = clients.count
      for client in clients {
        client.closeFuture.whenComplete { _ in
          oldRuntimeClosed.fulfill()
        }
      }
      try await magent.restart(config)
      await fulfillment(of: [oldRuntimeClosed], timeout: 5)

      let (restartedClient, restartedGreeting) = try await connectSOCKS5Client(
        group: supportGroup,
        port: port
      )
      clients.append(restartedClient)
      let restartedGreetingData = try await restartedGreeting.get()
      XCTAssertEqual(restartedGreetingData, Data([0x05, 0x00]))

      let currentRuntimeClosed = expectation(description: "close ends the current runtime connection")
      restartedClient.closeFuture.whenComplete { _ in
        currentRuntimeClosed.fulfill()
      }
      try await magent.close()
      await fulfillment(of: [currentRuntimeClosed], timeout: 5)
    } catch {
      try? await magent.close()
      testError = error
    }

    for client in clients {
      try? await client.close().get()
    }
    try await supportGroup.shutdownGracefully()
    if let testError {
      throw testError
    }
  }

  /// restart 的 TCP bind 失败后仍可再次启动，UDP 端口占用不影响只绑定 TCP 的服务。
  func testMagentCanStartAfterRestartTCPBindFailureAndIgnoresUDPPortOccupancy() async throws {
    let supportGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    var supportChannels: [Channel] = []
    let config: (Int) -> MagentConfig = { port in
      MagentConfig(
        address: .domain("127.0.0.1", port: port)
      )
    }
    let magent = Magent(threadNumber: 1)
    var testError: Error?

    do {
      let initialTCPProbe = try await ServerBootstrap(group: supportGroup)
        .childChannelInitializer { channel in channel.pipeline.addHandler(TestInboundHandler()) }
        .bind(host: "127.0.0.1", port: 0)
        .get()
      supportChannels.append(initialTCPProbe)
      let initialPort = try XCTUnwrap(initialTCPProbe.localAddress?.port)
      try await initialTCPProbe.close().get()

      let blockedTCPChannel = try await ServerBootstrap(group: supportGroup)
        .childChannelInitializer { channel in channel.pipeline.addHandler(TestInboundHandler()) }
        .bind(host: "127.0.0.1", port: 0)
        .get()
      supportChannels.append(blockedTCPChannel)
      let blockedTCPPort = try XCTUnwrap(blockedTCPChannel.localAddress?.port)

      let blockedUDPChannel = try await DatagramBootstrap(group: supportGroup)
        .channelInitializer { channel in channel.pipeline.addHandler(TestInboundHandler()) }
        .bind(host: "127.0.0.1", port: 0)
        .get()
      supportChannels.append(blockedUDPChannel)
      let blockedPort = try XCTUnwrap(blockedUDPChannel.localAddress?.port)
      let blockedTCPProbe = try await ServerBootstrap(group: supportGroup)
        .childChannelInitializer { channel in channel.pipeline.addHandler(TestInboundHandler()) }
        .bind(host: "127.0.0.1", port: blockedPort)
        .get()
      supportChannels.append(blockedTCPProbe)
      try await blockedTCPProbe.close().get()

      try await magent.start(config(initialPort))

      do {
        try await magent.restart(config(blockedTCPPort))
        XCTFail("restart should fail when the TCP port is already bound")
      } catch {
        XCTAssertNotNil(error as? MagentError)
      }

      try await blockedTCPChannel.close().get()
      try await magent.start(config(blockedTCPPort))

      try await magent.restart(config(blockedPort))
      try await magent.close()
    } catch {
      try? await magent.close()
      testError = error
    }

    for channel in supportChannels {
      try? await channel.close().get()
    }
    try await supportGroup.shutdownGracefully()
    if let testError {
      throw testError
    }
  }
}

private func connectSOCKS5Client(
  group: EventLoopGroup,
  port: Int
) async throws -> (Channel, EventLoopFuture<Data>) {
  let greeting = group.next().makePromise(of: Data.self)
  let client = try await ClientBootstrap(group: group)
    .channelInitializer { channel in
      channel.pipeline.addHandler(TestDataCollector(expectedByteCount: 2, promise: greeting))
    }
    .connect(host: "127.0.0.1", port: port)
    .get()
  try await writeData(Data([0x05, 0x01, 0x00]), to: client)
  return (client, greeting.futureResult)
}

private func writeData(_ data: Data, to channel: Channel) async throws {
  var buffer = channel.allocator.buffer(capacity: data.count)
  buffer.writeBytes(data)
  try await channel.writeAndFlush(buffer).get()
}
