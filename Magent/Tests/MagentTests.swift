import Foundation
@testable import Magent
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest

/// `Magent` 启动、重启和关闭生命周期测试。
final class MagentTests: XCTestCase {
    /// 原子额度在并发竞争下不能超过上限，归还后必须可以完整复用。
    func testAcceptedConnectionCounterEnforcesLimitAndReusesCapacity() async {
        let counter = AcceptedConnectionCounter()
        let maximum = 8
        let acquired = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<128 {
                group.addTask {
                    counter.tryAcquire(maximum: maximum)
                }
            }

            var count = 0
            for await result in group where result {
                count += 1
            }
            return count
        }

        XCTAssertEqual(acquired, maximum)
        XCTAssertFalse(counter.tryAcquire(maximum: maximum))

        for _ in 0..<acquired {
            counter.release()
        }
        for _ in 0..<maximum {
            XCTAssertTrue(counter.tryAcquire(maximum: maximum))
        }
        XCTAssertFalse(counter.tryAcquire(maximum: maximum))
        for _ in 0..<maximum {
            counter.release()
        }
    }

    /// 未显式配置时使用 256 条 accepted connections。
    func testMagentConfigDefaultsAcceptedConnectionLimit() throws {
        let config = MagentConfig(
            address: .domain("127.0.0.1", port: 1080),
            defaultDecision: .direct,
            defaultProxyNode: ProxyNode(
                address: try SocketAddress(ipAddress: "192.0.2.31", port: 8388),
                cipher: .aes256Gcm,
                password: "test"
            ),
            enableMatchTable: false
        )

        XCTAssertEqual(config.maxAcceptedConnections, 256)
    }

    /// accepted connection 达到上限后立即关闭新 Channel；已有 Channel 结束和 restart 后额度均可复用。
    func testMagentLimitsAcceptedConnectionsAcrossRestart() async throws {
        let supportGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let portProbe = try await ServerBootstrap(group: supportGroup)
            .childChannelInitializer { channel in channel.pipeline.addHandler(TestInboundHandler()) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = try XCTUnwrap(portProbe.localAddress?.port)
        try await portProbe.close().get()

        let defaultNode = ProxyNode(
            address: try SocketAddress(ipAddress: "192.0.2.31", port: 8388),
            cipher: .aes256Gcm,
            password: "test"
        )
        let config: (Int) -> MagentConfig = { maximum in
            MagentConfig(
                address: .domain("127.0.0.1", port: port),
                defaultDecision: .direct,
                defaultProxyNode: defaultNode,
                enableMatchTable: false,
                maxAcceptedConnections: maximum
            )
        }

        let magent = Magent(threadNumber: 2)
        var clients: [Channel] = []
        var testError: Error?

        do {
            do {
                try await magent.start(config(0))
                XCTFail("start should reject a non-positive accepted connection limit")
            } catch {
                XCTAssertEqual(
                    error as? MagentError,
                    .invalidOptions("maximum accepted connections must be greater than zero")
                )
            }

            try await magent.start(config(1))

            let (firstClient, firstGreeting) = try await connectSOCKS5Client(
                group: supportGroup,
                port: port
            )
            clients.append(firstClient)
            let firstGreetingData = try await firstGreeting.get()
            XCTAssertEqual(firstGreetingData, Data([0x05, 0x00]))

            do {
                let rejectedClient = try await ClientBootstrap(group: supportGroup)
                    .connect(host: "127.0.0.1", port: port)
                    .get()
                clients.append(rejectedClient)
                let rejectedClosed = expectation(description: "connection above the limit is closed")
                rejectedClient.closeFuture.whenComplete { _ in
                    rejectedClosed.fulfill()
                }
                try? await writeData(Data([0x05, 0x01, 0x00]), to: rejectedClient)
                await fulfillment(of: [rejectedClosed], timeout: 2)
            } catch {
                // listener 可以在 connect Future 完成前关闭超额 Channel；这同样是正确的拒绝结果。
            }

            let firstClosed = expectation(description: "first accepted connection is closed")
            firstClient.closeFuture.whenComplete { _ in
                firstClosed.fulfill()
            }
            try await writeData(
                Data([0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1, 0, 80]),
                to: firstClient
            )
            await fulfillment(of: [firstClosed], timeout: 2)

            let (reusedClient, reusedGreeting) = try await connectSOCKS5Client(
                group: supportGroup,
                port: port
            )
            clients.append(reusedClient)
            let reusedGreetingData = try await reusedGreeting.get()
            XCTAssertEqual(reusedGreetingData, Data([0x05, 0x00]))

            let oldRuntimeClosed = expectation(description: "restart closes the old runtime connection")
            reusedClient.closeFuture.whenComplete { _ in
                oldRuntimeClosed.fulfill()
            }
            try await magent.restart(config(1))
            await fulfillment(of: [oldRuntimeClosed], timeout: 2)

            let (restartedClient, restartedGreeting) = try await connectSOCKS5Client(
                group: supportGroup,
                port: port
            )
            clients.append(restartedClient)
            let restartedGreetingData = try await restartedGreeting.get()
            XCTAssertEqual(restartedGreetingData, Data([0x05, 0x00]))

            try await magent.close()
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
        let defaultNode = ProxyNode(
            address: try SocketAddress(ipAddress: "192.0.2.31", port: 8388),
            cipher: .aes256Gcm,
            password: "test"
        )
        let config: (Int) -> MagentConfig = { port in
            MagentConfig(
                address: .domain("127.0.0.1", port: port),
                defaultDecision: .direct,
                defaultProxyNode: defaultNode,
                enableMatchTable: false
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
