import Atomics
import Foundation
import NIOCore
import NIOHTTP1

/// NIOHTTP1 握手阶段的临时 handler；移除 decoder 后，accepted channel 恢复传递 `ByteBuffer`。
private final class HTTPConnectHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler,
        @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart

    weak var connection: HttpConnectConnection?
    var decoder: ByteToMessageHandler<HTTPRequestDecoder>?
    var address: NetworkAddress?
    var hasFailed = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let connection, connection.state != .closed else {
            return
        }
        guard connection.isReadingInitialRequest else {
            errorCaught(
                context: context,
                error: MagentError.malformedRequest("HTTP CONNECT payload received before established")
            )
            return
        }

        do {
            switch unwrapInboundIn(data) {
            case .head(let request):
                guard address == nil else {
                    throw MagentError.malformedRequest("HTTP CONNECT request head is duplicated")
                }
                guard request.headers["Content-Length"].isEmpty,
                      request.headers["Transfer-Encoding"].isEmpty else {
                    throw MagentError.malformedRequest("HTTP CONNECT request body framing is not supported")
                }
                let request = HttpProtocol(
                    address: try HttpProtocol.parseAuthority(request.uri),
                    version: "HTTP/\(request.version.major).\(request.version.minor)",
                    headers: request.headers.map { ($0.name, $0.value) }
                )
                try request.checkConnect()
                address = request.address

            case .body:
                throw MagentError.malformedRequest("HTTP CONNECT request body is not supported")

            case .end(let trailers):
                guard trailers?.isEmpty != false, let address else {
                    throw MagentError.malformedRequest("HTTP CONNECT request is incomplete")
                }
                let loopBoundContext = context.loopBound
                connection.isReadingInitialRequest = false
                // 等当前 decode 调用处理完同一输入缓冲区，再移除 decoder，才能可靠识别紧随 request 的字节。
                context.eventLoop.submit {}.flatMap {
                    guard let decoder = self.decoder else {
                        return loopBoundContext.value.eventLoop.makeFailedFuture(MagentError.connectionClosed)
                    }
                    return loopBoundContext.value.pipeline.syncOperations.removeHandler(decoder)
                }.flatMap {
                    loopBoundContext.value.pipeline.syncOperations.removeHandler(self)
                }.flatMapThrowing {
                    guard !self.hasFailed else {
                        throw MagentError.connectionClosed
                    }
                    try connection.installWireChannel(address: address)
                }.whenFailure { error in
                    self.errorCaught(context: loopBoundContext.value, error: error)
                }
            }
        } catch {
            errorCaught(context: context, error: error)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard let connection, connection.state != .closed, !hasFailed else {
            return
        }
        hasFailed = true
        connection.isReadingInitialRequest = false

        let response: Data
        switch error {
        case MagentError.malformedRequest, MagentError.invalidAddress,
             is HTTPParserError, is ByteToMessageDecoderError:
            response = HttpProtocol.badRequest
        default:
            response = HttpProtocol.badGateway
        }
        let responseFuture = connection.respondProxyChannelOnce(response)
            ?? connection.proxyChannel.eventLoop.makeSucceededFuture(())
        responseFuture.whenComplete { _ in
            connection.proxyChannel.pipeline.fireErrorCaught(error)
        }
    }
}

/// HTTP CONNECT 代理连接。
///
/// 握手阶段等待完整 request，解析目标并创建 wire channel；握手成功后进入 tunnel，
/// proxy channel 和 wire channel 的后续数据分别通过 `outbound`、`inbound` 双向转发。
/// tunnel 两端均使用手动读取，每一批数据写入对端成功后才重新读取来源 Channel。
internal final class HttpConnectConnection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    fileprivate enum State {
        case handshake
        case tunnel
        case closed
    }

    fileprivate let proxyChannel: Channel
    private let core: MagentCore
    private var wireChannel: Channel?
    fileprivate var state: State = .handshake
    private var wire: Wire?
    fileprivate var isReadingInitialRequest = true
    private var isProxyInputClosed = false
    private var initialRequestByteCount = 0
    private var handshakeHandler: HTTPConnectHandshakeHandler?
    private let hasRespondedHandshake = ManagedAtomic(false)

    internal init(proxyChannel: Channel, core: MagentCore) {
        self.proxyChannel = proxyChannel
        self.core = core
    }

    /// 接收 proxy channel 的 HTTP CONNECT request 或 tunnel payload。
    func upstream(context: ChannelHandlerContext, data: NIOAny) {
        let input = unwrapInboundIn(data)
        guard input.readableBytes > 0 else {
            context.read()
            return
        }

        switch state {
        case .handshake:
            do {
                guard isReadingInitialRequest else {
                    throw MagentError.malformedRequest("HTTP CONNECT payload received before established")
                }
                if handshakeHandler == nil {
                    let decoder = ByteToMessageHandler(
                        HTTPRequestDecoder(leftOverBytesStrategy: .fireError)
                    )
                    let handler = HTTPConnectHandshakeHandler()
                    handler.connection = self
                    handler.decoder = decoder
                    handshakeHandler = handler
                    try context.pipeline.syncOperations.addHandlers(decoder, handler)
                }

                let (requestByteCount, overflow) = initialRequestByteCount.addingReportingOverflow(
                    input.readableBytes
                )
                guard !overflow, requestByteCount <= Self.maximumRequestSize else {
                    throw MagentError.malformedRequest("HTTP CONNECT request is too large")
                }
                initialRequestByteCount = requestByteCount
                context.fireChannelRead(data)
                if isReadingInitialRequest {
                    context.read()
                }
            } catch {
                handshakeHandler?.errorCaught(context: context, error: error)
            }
        case .tunnel:
            do {
                try outbound(input)
            } catch {
                proxyChannel.pipeline.fireErrorCaught(error)
            }
        case .closed:
            return
        }
    }

    /// proxy 输入方向关闭后，只关闭 wire 的输出方向，保留 wire 返回数据的通路。
    func proxyInputClosed(context: ChannelHandlerContext) {
        guard !isProxyInputClosed else {
            return
        }
        isProxyInputClosed = true

        switch state {
        case .handshake:
            guard !isReadingInitialRequest else {
                isReadingInitialRequest = false
                proxyChannel.pipeline.fireErrorCaught(MagentError.connectionClosed)
                return
            }
        case .tunnel:
            guard let wireChannel else {
                proxyChannel.pipeline.fireErrorCaught(MagentError.connectionClosed)
                return
            }
            wireChannel.close(mode: .output).whenFailure { error in
                self.proxyChannel.pipeline.fireErrorCaught(error)
            }
        case .closed:
            return
        }
    }

    /// 接收 wire channel 数据。
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let input = unwrapInboundIn(data)
        guard input.readableBytes > 0 else {
            if state == .tunnel {
                context.read()
            }
            return
        }

        switch state {
        case .handshake:
            return
        case .tunnel:
            do {
                try inbound(input)
            } catch {
                proxyChannel.pipeline.fireErrorCaught(error)
            }
        case .closed:
            return
        }
    }

    /// wire 输入方向关闭后，只关闭 proxy 的输出方向，继续接收 proxy 发往 wire 的数据。
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed else {
            context.fireUserInboundEventTriggered(event)
            return
        }

        switch state {
        case .handshake:
            proxyChannel.pipeline.fireErrorCaught(MagentError.connectionClosed)
        case .tunnel:
            proxyChannel.close(mode: .output).whenFailure { error in
                self.proxyChannel.pipeline.fireErrorCaught(error)
            }
        case .closed:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    /// wire channel 关闭时同步结束 proxy channel。
    func channelInactive(context: ChannelHandlerContext) {
        guard state != .closed else {
            context.fireChannelInactive()
            return
        }
        wireChannel = nil
        proxyChannel.pipeline.fireErrorCaught(MagentError.connectionClosed)
        context.fireChannelInactive()
    }

    /// wire channel 出错时通知上游 proxy pipeline，由 `MagentTCPConnection` 统一关闭两端。
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard state != .closed else {
            return
        }
        proxyChannel.pipeline.fireErrorCaught(error)
    }

    /// 仅供上游 `MagentTCPConnection` 释放下游 wire channel；本连接不得用它执行自我关闭。
    func closeConnection(error: Error?) {
        guard state != .closed else {
            return
        }
        state = .closed
        self.wireChannel?.close(promise: nil)
        self.wireChannel = nil
    }

    fileprivate func installWireChannel(address: NetworkAddress) throws {
        guard !address.host.isEmpty, (1...65535).contains(address.port) else {
            throw MagentError.invalidAddress("invalid HTTP CONNECT destination")
        }

        if let wire = try core.routeTCPWire(address) {
            self.wire = wire
            core.createTCPClientChannel(
                group: proxyChannel.eventLoop,
                address: wire.getTargetAddress(),
                timeout: wire.getTimeout(),
                handler: self
            ).flatMap { channel -> EventLoopFuture<Channel?> in
                guard self.state != .closed,
                      self.proxyChannel.isActive else {
                    channel.close(promise: nil)
                    return channel.eventLoop.makeSucceededFuture(nil)
                }
                self.wireChannel = channel
                do {
                    guard let wire = self.wire else {
                        throw MagentError.connectionClosed
                    }
                    guard let data = try wire.start(handshake: address), !data.isEmpty else {
                        return channel.eventLoop.makeSucceededFuture(Optional(channel))
                    }
                    return self.requestWireChannel(data).map { Optional(channel) }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }.flatMapError { error -> EventLoopFuture<Channel?> in
                let response: Data
                switch error {
                case MagentError.channelConnectionTimedOut:
                    response = HttpProtocol.gatewayTimeout
                default:
                    response = HttpProtocol.badGateway
                }
                let responseFuture = self.respondProxyChannelOnce(response)
                    ?? self.proxyChannel.eventLoop.makeSucceededFuture(())
                responseFuture.whenComplete { _ in
                    self.proxyChannel.pipeline.fireErrorCaught(error)
                }
                return self.proxyChannel.eventLoop.makeSucceededFuture(nil)
            }.flatMap { channel in
                self.startTunnel(channel)
            }.whenFailure { error in
                self.proxyChannel.pipeline.fireErrorCaught(error)
            }
            return
        }

        core.createTCPClientChannel(
            group: proxyChannel.eventLoop,
            address: address,
            timeout: core.defaultTimeout,
            handler: self
        ).flatMap { channel -> EventLoopFuture<Channel?> in
            guard self.state != .closed,
                  self.proxyChannel.isActive else {
                channel.close(promise: nil)
                return channel.eventLoop.makeSucceededFuture(nil)
            }
            self.wireChannel = channel
            return channel.eventLoop.makeSucceededFuture(Optional(channel))
        }.flatMapError { error -> EventLoopFuture<Channel?> in
            let response: Data
            switch error {
            case MagentError.channelConnectionTimedOut:
                response = HttpProtocol.gatewayTimeout
            default:
                response = HttpProtocol.badGateway
            }
            let responseFuture = self.respondProxyChannelOnce(response)
                ?? self.proxyChannel.eventLoop.makeSucceededFuture(())
            responseFuture.whenComplete { _ in
                self.proxyChannel.pipeline.fireErrorCaught(error)
            }
            return self.proxyChannel.eventLoop.makeSucceededFuture(nil)
        }.flatMap { channel in
            self.startTunnel(channel)
        }.whenFailure { error in
            self.proxyChannel.pipeline.fireErrorCaught(error)
        }
    }

    /// wire 准备完成后先发送 established，响应写入成功才进入 tunnel 并启动双向读取。
    private func startTunnel(_ channel: Channel?) -> EventLoopFuture<Void> {
        guard let channel,
              state != .closed,
              proxyChannel.isActive else {
            channel?.close(promise: nil)
            return proxyChannel.eventLoop.makeSucceededFuture(())
        }
        guard let responseFuture = respondProxyChannelOnce(HttpProtocol.established) else {
            channel.close(promise: nil)
            return proxyChannel.eventLoop.makeSucceededFuture(())
        }
        return responseFuture.map {
            guard self.state != .closed,
                  self.proxyChannel.isActive,
                  channel.isActive else {
                channel.close(promise: nil)
                return
            }
            self.state = .tunnel
            self.handshakeHandler = nil
            if self.isProxyInputClosed {
                channel.close(mode: .output).whenFailure { error in
                    self.proxyChannel.pipeline.fireErrorCaught(error)
                }
            } else {
                self.proxyChannel.read()
            }
            channel.read()
        }
    }

    /// 将 tunnel payload 编码后写入 wire channel。
    private func outbound(_ data: ByteBuffer) throws {
        guard state == .tunnel, data.readableBytes > 0 else {
            return
        }

        let data = Data(data.readableBytesView)
        let outbound: Data
        if let wire {
            outbound = try wire.encodeOutbound(data, address: nil)
        } else {
            outbound = data
        }
        requestWireChannel(outbound).map {
            self.proxyChannel.read()
        }.whenFailure { error in
            self.proxyChannel.pipeline.fireErrorCaught(error)
        }
    }

    /// 将 wire channel 数据解码后写回 proxy channel。
    private func inbound(_ data: ByteBuffer) throws {
        guard state == .tunnel, data.readableBytes > 0 else {
            return
        }

        let data = Data(data.readableBytesView)
        let inbound: Data
        if let wire {
            inbound = try wire.decodeInbound(data).data
        } else {
            inbound = data
        }

        guard !inbound.isEmpty else {
            wireChannel?.read()
            return
        }
        respondProxyChannel(inbound).map {
            self.wireChannel?.read()
        }.whenFailure { error in
            self.proxyChannel.pipeline.fireErrorCaught(error)
        }
    }

    /// 写入当前下游 channel，并把完成状态交给调用阶段决定后续响应或关闭顺序。
    private func requestWireChannel(_ data: Data) -> EventLoopFuture<Void> {
        guard let wireChannel else {
            return proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
        }
        var output = wireChannel.allocator.buffer(capacity: data.count)
        output.writeBytes(data)
        return wireChannel.writeAndFlush(output)
    }

    /// 将 HTTP CONNECT response 或 tunnel 数据写回 proxy channel，并返回可排序的写入完成状态。
    private func respondProxyChannel(_ data: Data) -> EventLoopFuture<Void> {
        var output = proxyChannel.allocator.buffer(capacity: data.count)
        output.writeBytes(data)
        return proxyChannel.writeAndFlush(output)
    }

    /// HTTP CONNECT 每条连接最多发送一次握手响应；后续状态和错误由调用点处理。
    fileprivate func respondProxyChannelOnce(_ data: Data) -> EventLoopFuture<Void>? {
        guard hasRespondedHandshake.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged else {
            return nil
        }
        return respondProxyChannel(data)
    }

    private static let maximumRequestSize = 64 * 1024
}
