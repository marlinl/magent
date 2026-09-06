//
//  MagentService.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Owns the Magent core and PAC HTTP service lifecycles for the macOS app.
//

import Darwin
import Foundation
@preconcurrency import Magent
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

/// Magent 运行服务，统一管理核心代理实例和返回 PAC 文件的 HTTP 监听器。
///
/// `Magent.close()` 会回收核心实例自己的 EventLoopGroup；本 actor 会在下一次启动时重建核心实例。
actor MagentService {
    private let pacFileURL = MagentXApp.localDirectoryURL
        .appendingPathComponent("pac.json", isDirectory: false)
    private let localServer = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var state: State = .stopped
    /// 当前 PAC HTTP 监听通道；存在时表示监听端口仍由本服务持有。
    private var localServerChannel: Channel?
    private var pacState: PACState = .stopped

    deinit {
        try? localServer.syncShutdownGracefully()
    }

    /// 使用本地代理监听端点构造默认直连配置并启动 Magent。
    ///
    /// - Parameters:
    ///   - address: 本地代理监听地址。
    ///   - port: 本地代理监听端口。
    func start(address: String, port: Int) async throws {
        let endpoint = try ListenEndpoint(address: address, port: port)
        let placeholderNode = try ProxyNode(
            id: UUID(),
            address: SocketAddress(ipAddress: "127.0.0.1", port: 9),
            cipher: .chacha20IetfPoly1305,
            password: "unused-direct-route"
        )
        let configuration = MagentConfig(
            address: .domain(endpoint.address, port: endpoint.port),
            defaultDecision: .direct,
            defaultProxyNode: placeholderNode,
            enableMatchTable: false
        )
        try await start(configuration)
    }

    /// 使用给定配置启动 Magent；已启动或正在启动时保持幂等。
    func start(_ configuration: MagentConfig) async throws {
        switch state {
        case .stopped:
            let identifier = UUID()
            let task = Task { () throws -> Magent in
                let threadNumber = await MainActor.run {
                    GeneralSettings.load().proxyThreadNumber
                }
                guard threadNumber > 0 else {
                    throw MagentXError.invalidProxyThreadNumber(threadNumber)
                }

                let magent = Magent(threadNumber: threadNumber)
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

    /// 使用最新常规设置启动 PAC HTTP 监听器，对任意请求返回当前 `pac.json`。
    func startPACServer() async throws {
        switch pacState {
        case .stopped:
            let identifier = UUID()
            let localServer = localServer
            let pacFileURL = pacFileURL
            let task = Task { () throws -> Channel in
                let generalSettings = await MainActor.run {
                    GeneralSettings.load()
                }
                let endpoint = try ListenEndpoint(
                    address: generalSettings.pacListenAddress,
                    port: generalSettings.pacListenPort
                )

                do {
                    return try await ServerBootstrap(group: localServer)
                        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                        .childChannelInitializer { channel in
                            channel.pipeline.addHandler(PACHTTPHandler(pacFileURL: pacFileURL))
                        }
                        .bind(host: endpoint.address, port: endpoint.port)
                        .get()
                } catch {
                    throw Self.normalizedPACBindError(error, endpoint: endpoint)
                }
            }
            pacState = .starting(identifier, task)
            try await completePACStartup(identifier: identifier, task: task)
        case .starting(let identifier, let task):
            try await completePACStartup(identifier: identifier, task: task)
        case .running:
            return
        case .stopping(let identifier, let task):
            try await completePACShutdown(identifier: identifier, task: task)
            try await startPACServer()
        }
    }

    /// 关闭 PAC HTTP 监听器；未启动时保持幂等。
    func stopPACServer() async throws {
        switch pacState {
        case .stopped:
            return
        case .starting(let identifier, let task):
            try await completePACStartup(identifier: identifier, task: task)
            try await stopPACServer()
        case .running:
            guard let localServerChannel else {
                pacState = .stopped
                return
            }
            let identifier = UUID()
            let task = Task {
                try await localServerChannel.close().get()
            }
            pacState = .stopping(identifier, task)
            try await completePACShutdown(identifier: identifier, task: task)
        case .stopping(let identifier, let task):
            try await completePACShutdown(identifier: identifier, task: task)
        }
    }

    /// 将 PAC 监听 bind 错误归一化为 app 层可展示错误，非端口占用错误保持原样。
    ///
    /// - Parameters:
    ///   - error: NIO 返回的监听错误。
    ///   - endpoint: 本次绑定使用的已校验端点。
    /// - Returns: 已归一化或原始错误。
    private static func normalizedPACBindError(_ error: Error, endpoint: ListenEndpoint) -> Error {
        guard let ioError = error as? IOError, ioError.errnoCode == EADDRINUSE else {
            return error
        }
        return MagentXError.listenPortUnavailable(endpoint.address, endpoint.port)
    }

    /// 等待启动任务结束，并将仍属于该任务的状态更新为运行中或已停止。
    ///
    /// - Parameters:
    ///   - identifier: 本次启动任务的唯一标识。
    ///   - task: 等待完成的 Magent 启动任务。
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

    /// 等待停止任务结束，并将仍属于该任务的状态更新为已停止。
    ///
    /// - Parameters:
    ///   - identifier: 本次停止任务的唯一标识。
    ///   - task: 等待完成的 Magent 关闭任务。
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

    /// 等待 PAC 启动任务结束，并将仍属于该任务的状态更新为运行中或已停止。
    ///
    /// - Parameters:
    ///   - identifier: 本次 PAC 启动任务的唯一标识。
    ///   - task: 等待完成的 PAC 监听任务。
    private func completePACStartup(
        identifier: UUID,
        task: Task<Channel, Error>
    ) async throws {
        do {
            let channel = try await task.value
            if case .starting(let currentIdentifier, _) = pacState,
               currentIdentifier == identifier {
                localServerChannel = channel
                pacState = .running
            }
        } catch {
            if case .starting(let currentIdentifier, _) = pacState,
               currentIdentifier == identifier {
                pacState = .stopped
            }
            throw error
        }
    }

    /// 等待 PAC 关闭任务结束，并在成功时释放监听通道、失败时保留通道供重试。
    ///
    /// - Parameters:
    ///   - identifier: 本次 PAC 关闭任务的唯一标识。
    ///   - task: 等待完成的 PAC 关闭任务。
    private func completePACShutdown(
        identifier: UUID,
        task: Task<Void, Error>
    ) async throws {
        do {
            try await task.value
            if case .stopping(let currentIdentifier, _) = pacState,
               currentIdentifier == identifier {
                localServerChannel = nil
                pacState = .stopped
            }
        } catch {
            if case .stopping(let currentIdentifier, _) = pacState,
               currentIdentifier == identifier {
                pacState = .running
            }
            throw error
        }
    }

    /// 将 PAC 文件包装为 HTTP 响应的 NIO 处理器。
    private final class PACHTTPHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let pacFileURL: URL

        /// 创建从指定 PAC 文件读取响应内容的 HTTP 通道处理器。
        ///
        /// - Parameter pacFileURL: 当前 PAC 文件的本地路径。
        init(pacFileURL: URL) {
            self.pacFileURL = pacFileURL
        }

        /// 收到请求后在全局 NIO 线程池读取 PAC 文件，响应完成后关闭连接。
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            _ = unwrapInboundIn(data)
            let pacFileURL = pacFileURL
            let loopBoundContext = context.loopBound

            NIOThreadPool.singleton.runIfActive(eventLoop: context.eventLoop) {
                Self.currentPACBody(pacFileURL: pacFileURL)
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

        /// NIO 报错时异步投递日志并关闭 PAC HTTP 连接，避免阻塞 event loop。
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            let message = "PAC HTTP channel failed: \(String(reflecting: error))"
            Task { @MainActor in
                MagentXLogger.warning(message, category: .network)
            }
            context.close(promise: nil)
        }

        /// 从 PAC 文件读取非空响应内容；文件不可用时返回直连的最小 PAC 脚本。
        ///
        /// - Parameter pacFileURL: 要读取的 PAC 文件路径。
        /// - Returns: 可直接写入 HTTP 响应体的 PAC 数据。
        private static func currentPACBody(pacFileURL: URL) -> Data {
            if let data = try? Data(contentsOf: pacFileURL), data.isEmpty == false {
                return data
            }

            return Data("function FindProxyForURL(url, host) { return \"DIRECT\"; }".utf8)
        }

        /// 以给定 PAC 数据生成关闭连接的 HTTP 成功响应。
        ///
        /// - Parameter bodyData: HTTP 响应体中的 PAC 内容。
        /// - Returns: 完整的 HTTP 响应字节。
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

    /// 已校验的本地监听端点。
    private struct ListenEndpoint: Sendable {
        let address: String
        let port: Int

        /// 规范化并校验监听地址和端口。
        ///
        /// - Parameters:
        ///   - address: 待校验的监听地址。
        ///   - port: 待校验的监听端口。
        init(address: String, port: Int) throws {
            let normalizedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedAddress.isEmpty == false else {
                throw MagentXError.invalidListenAddress(address)
            }
            guard (1...65_535).contains(port) else {
                throw MagentXError.invalidListenPort(port)
            }

            self.address = normalizedAddress
            self.port = port
        }
    }

    /// 串行化启动和关闭操作所需的内部生命周期状态。
    private enum State {
        case stopped
        case starting(UUID, Task<Magent, Error>)
        case running(Magent)
        case stopping(UUID, Task<Void, Error>)
    }

    /// 串行化 PAC HTTP 监听器启动和关闭所需的内部生命周期状态。
    private enum PACState {
        case stopped
        case starting(UUID, Task<Channel, Error>)
        case running
        case stopping(UUID, Task<Void, Error>)
    }
}
