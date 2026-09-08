//
//  PacService.swift
//  MagentX
//
//  Responsibility: Owns the local PAC HTTP listener and its NIO runtime.
//

import Darwin
import Foundation
import OSLog
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

/// PAC 服务，负责本地 PAC 文件的内存加载和 HTTP 监听器生命周期。
///
/// 服务停止时只关闭监听通道，以便后续重启复用 NIO 运行时；运行时仅在析构时关闭。
actor PacService {
    private let pacFileURL = MagentXApp.localDirectoryURL
        .appendingPathComponent("pac.json", isDirectory: false)
    private let pacGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var pacState = State.stop
    private var pacResponse = Data()

    private enum State {
        case running(tcpChannel: Channel, shutdownPromise: EventLoopPromise<Void>)
        case stop
    }

    /// 处理 PAC 服务单个客户端连接上的 HTTP 请求与响应。
    private final class PacHTTPHandler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let pacFileContents: Data
        private var requestedPACFile = false

        /// 使用当前已加载的 PAC 内容创建单连接 HTTP handler。
        init(pacFileContents: Data) {
            self.pacFileContents = pacFileContents
        }

        /// 读取 HTTP 请求，并在请求结束时返回 PAC 文件或 404 响应。
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let requestHead):
                requestedPACFile = String(requestHead.uri.prefix { $0 != "?" }) == "/proxy.pac"
            case .body:
                break
            case .end:
                let bodyData = requestedPACFile ? pacFileContents : Data()
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: String(bodyData.count))
                headers.add(name: "Connection", value: "close")
                if requestedPACFile {
                    headers.add(
                        name: "Content-Type",
                        value: "application/x-ns-proxy-autoconfig; charset=utf-8"
                    )
                }
                let responseHead = HTTPResponseHead(
                    version: .http1_1,
                    status: requestedPACFile ? .ok : .notFound,
                    headers: headers
                )
                context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
                if bodyData.isEmpty == false {
                    var bodyBuffer = context.channel.allocator.buffer(capacity: bodyData.count)
                    bodyBuffer.writeBytes(bodyData)
                    context.write(wrapOutboundOut(.body(.byteBuffer(bodyBuffer))), promise: nil)
                }
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                    context.close(promise: nil)
                }
            }
        }

        /// 连接处理失败时关闭当前客户端通道。
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            context.close(promise: nil)
        }
    }

    deinit {
        try? pacGroup.syncShutdownGracefully()
    }

    /// 从本地 PAC 文件刷新内存响应内容。
    ///
    /// 文件读取失败时保留已有的有效内存内容，避免影响已运行服务的响应。
    private func loadPacFile() {
        if let contents = FileManager.default.contents(atPath: pacFileURL.path) {
            pacResponse = contents
        }
    }

    /// 启动本地 PAC HTTP 服务，并在绑定前完整加载当前 PAC 文件到内存。
    ///
    /// 服务仅响应 `/proxy.pac`，监听地址和端口取自当前 `GeneralSettings`。
    func startServer() async {
        if case .running = pacState {
            return
        }

        let generalSettings = await MainActor.run {
            GeneralSettings.load()
        }
        let address = generalSettings.pacListenAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.isEmpty == false else {
            let error = MagentXError.invalidListenAddress(generalSettings.pacListenAddress)
            AppLog.proxy.error(
                "Failed to start PAC HTTP service: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        let port = generalSettings.pacListenPort
        guard (1...65_535).contains(port) else {
            let error = MagentXError.invalidListenPort(port)
            AppLog.proxy.error(
                "Failed to start PAC HTTP service: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        loadPacFile()
        let pacFileContents = pacResponse

        do {
            let tcpChannel = try await ServerBootstrap(group: pacGroup)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(PacHTTPHandler(pacFileContents: pacFileContents))
                    }
                }
                .bind(
                    host: address,
                    port: port
                )
                .get()
            let shutdownPromise = tcpChannel.eventLoop.makePromise(of: Void.self)
            pacState = .running(tcpChannel: tcpChannel, shutdownPromise: shutdownPromise)
            AppLog.proxy.info(
                "PAC HTTP service started on \(address):\(port)"
            )
        } catch {
            let loggedError: Error
            if let ioError = error as? IOError, ioError.errnoCode == EADDRINUSE {
                loggedError = MagentXError.listenPortUnavailable(
                    address,
                    port
                )
            } else {
                loggedError = error
            }
            AppLog.proxy.error(
                "Failed to start PAC HTTP service: \(loggedError.localizedDescription, privacy: .public)"
            )
        }
    }


    /// 关闭本地 PAC HTTP 服务监听通道，但保留 NIO EventLoopGroup 供后续重启。
    ///
    func shudownServer() async {
        guard case .running(let tcpChannel, let shutdownPromise) = pacState else {
            return
        }

        pacState = .stop
        do {
            try await tcpChannel.close().get()
            shutdownPromise.succeed(())
            AppLog.proxy.info("PAC HTTP service listener closed")
        } catch {
            if case .stop = pacState {
                pacState = .running(tcpChannel: tcpChannel, shutdownPromise: shutdownPromise)
            }
            AppLog.proxy.error(
                "Failed to close PAC HTTP service listener: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
