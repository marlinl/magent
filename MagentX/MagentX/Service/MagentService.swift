//
//  MagentService.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Owns the Magent core and PAC HTTP service lifecycles for the macOS app.
//

import Foundation
@preconcurrency import Magent
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

/// Magent 运行服务，统一管理核心代理实例和返回 PAC 文件的 HTTP 监听器。
///
/// `Magent.close()` 会回收实例自己的 EventLoopGroup，因此停止后再次启动时会创建新实例。
actor MagentService {
    private let threadNumber: Int
    private let eventLoopGroup: EventLoopGroup
    private let pacEndpoint: MagentProxyService.ListenEndpoint
    private let pacFileURL: URL
    private var state: State = .stopped
    private var pacChannel: Channel?

    /// 创建尚未启动的核心代理与 PAC HTTP 服务。
    init(
        threadNumber: Int,
        eventLoopGroup: EventLoopGroup,
        pacEndpoint: MagentProxyService.ListenEndpoint,
        pacFileURL: URL = PacFileService.proxyHostPACURL(in: PacFileService.defaultDirectoryURL())
    ) {
        self.threadNumber = threadNumber
        self.eventLoopGroup = eventLoopGroup
        self.pacEndpoint = pacEndpoint
        self.pacFileURL = pacFileURL
    }

    /// 使用给定配置启动 Magent；已启动或正在启动时保持幂等。
    func start(_ configuration: MagentConfig) async throws {
        switch state {
        case .stopped:
            guard threadNumber > 0 else {
                throw MagentXError.invalidProxyThreadNumber(threadNumber)
            }

            let identifier = UUID()
            let magent = Magent(threadNumber: threadNumber)
            let task = Task { () throws -> Magent in
                try await magent.start(configuration)
                return magent
            }
            state = .starting(identifier, task)
            try await completeStartup(identifier: identifier, task: task)
        case .starting(let identifier, let task):
            try await completeStartup(identifier: identifier, task: task)
        case .running:
            return
        case .stopping(let identifier, let task):
            try await completeShutdown(identifier: identifier, task: task)
            try await start(configuration)
        }
    }

    /// 关闭当前 Magent 实例；未启动或正在关闭时保持幂等。
    func stop() async throws {
        switch state {
        case .stopped:
            return
        case .starting(let identifier, let task):
            try await completeStartup(identifier: identifier, task: task)
            try await stop()
        case .running(let magent):
            let identifier = UUID()
            let task = Task {
                try await magent.close()
            }
            state = .stopping(identifier, task)
            try await completeShutdown(identifier: identifier, task: task)
        case .stopping(let identifier, let task):
            try await completeShutdown(identifier: identifier, task: task)
        }
    }

    /// 启动 PAC HTTP 监听器，对任意请求返回当前 `proxy.pac` 内容。
    func startPACServer(proxyEndpoint: MagentProxyService.ListenEndpoint) async throws {
        guard pacChannel == nil else { return }
        let pacEndpoint = pacEndpoint
        let pacFileURL = pacFileURL

        try await ListenPortAvailabilityProbe(
            endpoint: pacEndpoint,
            eventLoopGroup: eventLoopGroup
        ).validate()

        do {
            pacChannel = try await ServerBootstrap(group: eventLoopGroup)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(
                        PACHTTPHandler(
                            proxyEndpoint: proxyEndpoint,
                            pacFileURL: pacFileURL
                        )
                    )
                }
                .bind(host: pacEndpoint.address, port: pacEndpoint.port)
                .get()
        } catch {
            throw ListenPortAvailabilityProbe.normalizedBindError(error, endpoint: pacEndpoint)
        }
    }

    /// 关闭 PAC HTTP 监听器；未启动时保持幂等。
    func stopPACServer() async throws {
        guard let pacChannel else { return }
        self.pacChannel = nil
        try await pacChannel.close().get()
    }

    private func completeStartup(
        identifier: UUID,
        task: Task<Magent, Error>
    ) async throws {
        do {
            let magent = try await task.value
            if case .starting(let currentIdentifier, _) = state,
               currentIdentifier == identifier {
                state = .running(magent)
            }
        } catch {
            if case .starting(let currentIdentifier, _) = state,
               currentIdentifier == identifier {
                state = .stopped
            }
            throw error
        }
    }

    private func completeShutdown(
        identifier: UUID,
        task: Task<Void, Error>
    ) async throws {
        do {
            try await task.value
            if case .stopping(let currentIdentifier, _) = state,
               currentIdentifier == identifier {
                state = .stopped
            }
        } catch {
            if case .stopping(let currentIdentifier, _) = state,
               currentIdentifier == identifier {
                state = .stopped
            }
            throw error
        }
    }

    /// 将 PAC 文件包装为 HTTP 响应的 NIO 处理器。
    private final class PACHTTPHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let proxyEndpoint: MagentProxyService.ListenEndpoint
        private let pacFileURL: URL

        init(proxyEndpoint: MagentProxyService.ListenEndpoint, pacFileURL: URL) {
            self.proxyEndpoint = proxyEndpoint
            self.pacFileURL = pacFileURL
        }

        /// 收到请求后在全局 NIO 线程池读取 PAC 文件，响应完成后关闭连接。
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            _ = unwrapInboundIn(data)
            let proxyEndpoint = proxyEndpoint
            let pacFileURL = pacFileURL
            let loopBoundContext = context.loopBound

            NIOThreadPool.singleton.runIfActive(eventLoop: context.eventLoop) {
                Self.currentPACBody(proxyEndpoint: proxyEndpoint, pacFileURL: pacFileURL)
            }.whenComplete { result in
                let context = loopBoundContext.value
                switch result {
                case .success(let bodyData):
                    let responseData = Self.makeResponse(bodyData: bodyData)
                    var buffer = context.channel.allocator.buffer(capacity: responseData.count)
                    buffer.writeBytes(responseData)
                    context.writeAndFlush(NIOAny(buffer)).whenComplete { _ in
                        loopBoundContext.value.close(promise: nil)
                    }
                case .failure(let error):
                    MagentXLogger.error(
                        error,
                        category: .network,
                        message: "PAC file read failed"
                    )
                    context.close(promise: nil)
                }
            }
        }

        /// NIO 报错时关闭 PAC HTTP 连接。
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            MagentXLogger.error(
                error,
                category: .network,
                message: "PAC HTTP channel failed"
            )
            context.close(promise: nil)
        }

        private static func currentPACBody(
            proxyEndpoint: MagentProxyService.ListenEndpoint,
            pacFileURL: URL
        ) -> Data {
            if let data = try? Data(contentsOf: pacFileURL), data.isEmpty == false {
                return data
            }

            do {
                let endpoint = try PacFileService.ProxyEndpoint(
                    address: proxyEndpoint.address,
                    port: proxyEndpoint.port
                )
                return Data(PacFileService.makeProxyHostPAC(rules: [], proxyEndpoint: endpoint).utf8)
            } catch {
                return Data("function FindProxyForURL(url, host) { return \"DIRECT\"; }".utf8)
            }
        }

        private static func makeResponse(bodyData: Data) -> Data {
            let header = [
                "HTTP/1.1 200 OK",
                "Content-Type: application/x-ns-proxy-autoconfig; charset=utf-8",
                "Content-Length: \(bodyData.count)",
                "Connection: close",
                "",
                ""
            ].joined(separator: "\r\n")

            var response = Data(header.utf8)
            response.append(bodyData)
            return response
        }
    }

    /// 串行化启动和关闭操作所需的内部生命周期状态。
    private enum State {
        case stopped
        case starting(UUID, Task<Magent, Error>)
        case running(Magent)
        case stopping(UUID, Task<Void, Error>)
    }
}
