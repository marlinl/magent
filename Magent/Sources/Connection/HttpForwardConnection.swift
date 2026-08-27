import Atomics
import Foundation
import NIOCore
import NIOHTTP1

/// NIOHTTP1 只解析当前连接唯一的一条 HTTP forward request；完成后立即从 pipeline 移除。
private final class HTTPForwardRequestHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart

    weak var connection: HttpForwardConnection?
    var decoder: ByteToMessageHandler<HTTPRequestDecoder>?
    var requestHead: HTTPRequestHead?
    var requestBody: ByteBuffer
    var hasFailed = false

    init(connection: HttpForwardConnection, decoder: ByteToMessageHandler<HTTPRequestDecoder>) {
        self.connection = connection
        self.decoder = decoder
        self.requestBody = connection.proxyChannel.allocator.buffer(capacity: 0)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let connection, connection.state != .closed else {
            return
        }

        do {
            guard connection.isReadingInitialRequest else {
                throw MagentError.invalidOptions("HTTP forward only supports one request")
            }

            switch unwrapInboundIn(data) {
            case .head(let request):
                guard requestHead == nil else {
                    throw MagentError.invalidOptions("HTTP forward pipelining is not supported")
                }
                guard request.version == .http1_0 || request.version == .http1_1 else {
                    throw MagentError.malformedRequest("HTTP forward only supports HTTP/1.0 and HTTP/1.1")
                }
                guard request.headers["Transfer-Encoding"].isEmpty else {
                    throw MagentError.invalidOptions("HTTP forward Transfer-Encoding is not supported")
                }
                guard request.headers["Content-Length"].count <= 1 else {
                    throw MagentError.malformedRequest("HTTP forward has multiple Content-Length headers")
                }
                guard request.headers["Host"].count <= 1 else {
                    throw MagentError.malformedRequest("HTTP forward has multiple Host headers")
                }
                guard request.headers["Expect"].isEmpty else {
                    throw MagentError.invalidOptions("HTTP forward Expect is not supported")
                }
                guard request.headers["Upgrade"].isEmpty else {
                    throw MagentError.invalidOptions("HTTP forward Upgrade is not supported")
                }
                requestHead = request

            case .body(var body):
                guard requestHead != nil else {
                    throw MagentError.malformedRequest("HTTP forward request head is missing")
                }
                requestBody.writeBuffer(&body)

            case .end(let trailers):
                guard trailers?.isEmpty != false,
                      let requestHead,
                      let decoder else {
                    throw MagentError.malformedRequest("HTTP forward request is incomplete")
                }
                let request = try HttpForwardConnection.buildRequest(
                    head: requestHead,
                    body: Data(requestBody.readableBytesView)
                )
                let loopBoundContext = context.loopBound
                connection.isReadingInitialRequest = false
                context.pipeline.syncOperations.removeHandler(decoder).flatMap {
                    loopBoundContext.value.pipeline.syncOperations.removeHandler(self)
                }.flatMapThrowing {
                    guard !self.hasFailed, connection.state != .closed else {
                        throw MagentError.connectionClosed
                    }
                    connection.requestHandler = nil
                    try connection.installWireChannel(address: request.target, payload: request.payload)
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

        let responseFuture = connection.respondFailureProxyChannelOnce(HttpForwardConnection.badRequest)
            ?? connection.proxyChannel.eventLoop.makeSucceededFuture(())
        responseFuture.whenComplete { _ in
            connection.proxyChannel.pipeline.fireErrorCaught(error)
        }
    }
}

/// HTTP forward 代理连接。
///
/// request 阶段等待完整 HTTP request，解析并改写后创建 wire channel；请求发出后进入 forward，
/// wire channel 的 HTTP response 通过 `inbound` 写回 proxy channel。
internal final class HttpForwardConnection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    fileprivate enum State {
        case request
        case forward
        case closed
    }

    fileprivate let proxyChannel: Channel
    private let core: MagentCore
    private var wireChannel: Channel?
    fileprivate var state: State = .request
    private var wire: Wire?
    fileprivate var isReadingInitialRequest = true
    private var isProxyInputClosed = false
    private var initialRequestByteCount = 0
    fileprivate var requestHandler: HTTPForwardRequestHandler?
    private let hasRespondedFailure = ManagedAtomic(false)

    internal init(proxyChannel: Channel, core: MagentCore) {
        self.proxyChannel = proxyChannel
        self.core = core
    }

    /// 接收 proxy channel 的首个 HTTP forward request。
    func upstream(context: ChannelHandlerContext, data: NIOAny) {
        let input = unwrapInboundIn(data)
        guard input.readableBytes > 0 else {
            context.read()
            return
        }

        switch state {
        case .request:
            do {
                guard isReadingInitialRequest else {
                    throw MagentError.malformedRequest("HTTP forward payload received before request was forwarded")
                }

                if requestHandler == nil {
                    let decoder = ByteToMessageHandler(
                        HTTPRequestDecoder(leftOverBytesStrategy: .fireError)
                    )
                    let handler = HTTPForwardRequestHandler(connection: self, decoder: decoder)
                    requestHandler = handler
                    try context.pipeline.syncOperations.addHandlers(decoder, handler)
                }

                let (requestByteCount, overflow) = initialRequestByteCount.addingReportingOverflow(
                    input.readableBytes
                )
                guard !overflow, requestByteCount <= Self.maximumRequestSize else {
                    throw MagentError.malformedRequest("HTTP forward request is too large")
                }
                initialRequestByteCount = requestByteCount
                context.fireChannelRead(data)
                if isReadingInitialRequest {
                    context.read()
                }
            } catch {
                requestHandler?.errorCaught(context: context, error: error)
            }

        case .forward:
            proxyChannel.pipeline.fireErrorCaught(
                MagentError.invalidOptions("HTTP forward pipelining is not supported")
            )

        case .closed:
            return
        }
    }

    /// proxy 输入方向关闭后，只关闭 wire 的输出方向，保留服务端 response 返回通路。
    func proxyInputClosed(context: ChannelHandlerContext) {
        guard !isProxyInputClosed else {
            return
        }
        isProxyInputClosed = true

        switch state {
        case .request:
            guard !isReadingInitialRequest else {
                isReadingInitialRequest = false
                proxyChannel.pipeline.fireErrorCaught(MagentError.connectionClosed)
                return
            }
        case .forward:
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

    /// 接收 wire channel 的 HTTP response。
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let input = unwrapInboundIn(data)
        guard input.readableBytes > 0 else {
            if state == .forward {
                context.read()
            }
            return
        }

        switch state {
        case .request:
            return
        case .forward:
            do {
                try inbound(input)
            } catch {
                proxyChannel.pipeline.fireErrorCaught(error)
            }
        case .closed:
            return
        }
    }

    /// wire 输入方向关闭后，只关闭 proxy 的输出方向，继续保留已完成的 proxy 输入状态。
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed else {
            context.fireUserInboundEventTriggered(event)
            return
        }

        switch state {
        case .request:
            proxyChannel.pipeline.fireErrorCaught(MagentError.connectionClosed)
        case .forward:
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

    fileprivate func installWireChannel(address: NetworkAddress, payload: Data) throws {
        guard !address.host.isEmpty, (1...65535).contains(address.port) else {
            throw MagentError.invalidAddress("invalid HTTP forward destination")
        }

        let channelFuture: EventLoopFuture<Channel?>
        if let wire = try core.routeTCPWire(address) {
            self.wire = wire
            channelFuture = core.createTCPClientChannel(
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
                    let handshake = try wire.start(handshake: address)
                    let request = try wire.encodeOutbound(payload, address: nil)
                    if let handshake, !handshake.isEmpty {
                        return self.requestWireChannel(handshake).flatMap {
                            self.requestWireChannel(request)
                        }.map { Optional(channel) }
                    }
                    return self.requestWireChannel(request).map { Optional(channel) }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        } else {
            channelFuture = core.createTCPClientChannel(
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
                return self.requestWireChannel(payload).map { Optional(channel) }
            }
        }

        channelFuture.flatMapError { error -> EventLoopFuture<Channel?> in
            let response: Data
            switch error {
            case MagentError.channelConnectionTimedOut:
                response = Self.gatewayTimeout
            default:
                response = Self.badGateway
            }
            let responseFuture = self.respondFailureProxyChannelOnce(response)
                ?? self.proxyChannel.eventLoop.makeSucceededFuture(())
            responseFuture.whenComplete { _ in
                self.proxyChannel.pipeline.fireErrorCaught(error)
            }
            return self.proxyChannel.eventLoop.makeSucceededFuture(nil)
        }.flatMap { channel -> EventLoopFuture<Void> in
            guard let channel,
                  self.state != .closed,
                  self.proxyChannel.isActive,
                  channel.isActive else {
                channel?.close(promise: nil)
                return self.proxyChannel.eventLoop.makeSucceededFuture(())
            }
            self.state = .forward
            if self.isProxyInputClosed {
                channel.close(mode: .output).whenFailure { error in
                    self.proxyChannel.pipeline.fireErrorCaught(error)
                }
            } else {
                self.proxyChannel.read()
            }
            channel.read()
            return self.proxyChannel.eventLoop.makeSucceededFuture(())
        }.whenFailure { error in
            self.proxyChannel.pipeline.fireErrorCaught(error)
        }
    }

    /// 将 wire channel 的 HTTP response 解码后写回 proxy channel。
    private func inbound(_ data: ByteBuffer) throws {
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

    /// 写入当前下游 channel，并把完成状态交给调用阶段决定后续状态与读取顺序。
    private func requestWireChannel(_ data: Data) -> EventLoopFuture<Void> {
        guard let wireChannel else {
            return proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
        }
        var output = wireChannel.allocator.buffer(capacity: data.count)
        output.writeBytes(data)
        return wireChannel.writeAndFlush(output)
    }

    /// 将 HTTP response 写回 proxy channel，并返回可排序的写入完成状态。
    private func respondProxyChannel(_ data: Data) -> EventLoopFuture<Void> {
        var output = proxyChannel.allocator.buffer(capacity: data.count)
        output.writeBytes(data)
        return proxyChannel.writeAndFlush(output)
    }

    /// HTTP forward 在建连失败时最多发送一次本地失败响应。
    fileprivate func respondFailureProxyChannelOnce(_ data: Data) -> EventLoopFuture<Void>? {
        guard hasRespondedFailure.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged else {
            return nil
        }
        return respondProxyChannel(data)
    }

    private static let maximumRequestSize = 64 * 1024

    // MARK: - HTTP request rewriting

    /// 将 NIOHTTP1 已验证的 request parts 重建为发往目标服务器的 origin-form request。
    internal static func buildRequest(head: HTTPRequestHead, body: Data)
        throws -> (target: NetworkAddress, payload: Data) {
        let resolved = try resolveTarget(head.uri, headers: head.headers)
        if head.uri == "*", head.method != .OPTIONS {
            throw MagentError.malformedRequest("HTTP forward asterisk-form is only valid for OPTIONS")
        }
        return (
            resolved.address,
            buildPayload(head: head, originForm: resolved.originForm, target: resolved.address, body: body)
        )
    }

    private static func resolveTarget(
        _ requestTarget: String,
        headers: HTTPHeaders
    ) throws -> (address: NetworkAddress, originForm: String) {
        if let absolute = try parseAbsoluteTarget(requestTarget) {
            return absolute
        }
        guard requestTarget == "*" || requestTarget.hasPrefix("/") else {
            throw MagentError.malformedRequest("HTTP forward request-target is invalid")
        }
        let hostHeaders = headers["Host"]
        guard hostHeaders.count == 1, let hostHeader = hostHeaders.first, !hostHeader.isEmpty else {
            throw MagentError.malformedRequest("HTTP forward request is missing Host header")
        }
        return (try parseHostHeader(hostHeader), requestTarget)
    }

    private static func buildPayload(
        head: HTTPRequestHead,
        originForm: String,
        target: NetworkAddress,
        body: Data
    ) -> Data {
        let connectionTokens = Set(
            head.headers[canonicalForm: "Connection"]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )

        let fixedHopByHop = Set([
            "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
            "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade", "host",
        ])

        let version = "HTTP/\(head.version.major).\(head.version.minor)"
        var payload = Data("\(head.method.rawValue) \(originForm) \(version)\r\n".utf8)
        payload.append(Data("Host: \(hostValue(for: target))\r\n".utf8))

        for header in head.headers {
            let lowercasedName = header.name.lowercased()
            guard fixedHopByHop.contains(lowercasedName) == false,
                  connectionTokens.contains(lowercasedName) == false else {
                continue
            }
            payload.append(Data("\(header.name): \(header.value)\r\n".utf8))
        }
        payload.append(Data("Connection: close\r\n\r\n".utf8))
        payload.append(body)
        return payload
    }

    private static func parseAbsoluteTarget(_ value: String) throws -> (address: NetworkAddress, originForm: String)? {
        guard let url = URLComponents(string: value), let scheme = url.scheme else {
            return nil
        }
        guard scheme.lowercased() == "http",
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              let urlHost = url.host else {
            throw MagentError.malformedRequest("HTTP forward absolute-form URI is invalid")
        }

        let port = url.port ?? 80
        guard (1...65535).contains(port) else {
            throw MagentError.invalidAddress("invalid HTTP forward destination")
        }
        let host = urlHost.hasPrefix("[") && urlHost.hasSuffix("]")
            ? String(urlHost.dropFirst().dropLast())
            : urlHost
        let path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
        let originForm = url.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
        if let socketAddress = try? SocketAddress(ipAddress: host, port: port),
           let address = NetworkAddress(socketAddress) {
            return (address, originForm)
        }
        return (.domain(host, port: port), originForm)
    }

    /// 与 CONNECT authority 看似相近但语义不同：Host 允许省略端口并默认 80，
    /// CONNECT 必须显式提供端口，因此两者不共享同一个宽松 parser。
    private static func parseHostHeader(_ value: String) throws -> NetworkAddress {
        let host: String
        let port: Int
        let isBracketedIPv6 = value.hasPrefix("[")

        if isBracketedIPv6 {
            guard let end = value.firstIndex(of: "]") else {
                throw MagentError.invalidAddress("invalid HTTP Host header")
            }
            host = String(value[value.index(after: value.startIndex)..<end])
            let rest = value[value.index(after: end)...]
            if rest.isEmpty {
                port = 80
            } else if rest.first == ":",
                      rest.dropFirst().utf8.allSatisfy({ (48...57).contains($0) }),
                      let parsed = Int(rest.dropFirst()) {
                port = parsed
            } else {
                throw MagentError.invalidAddress("invalid HTTP Host header")
            }
        } else if let colon = value.lastIndex(of: ":"), value[..<colon].contains(":") == false {
            host = String(value[..<colon])
            let portText = value[value.index(after: colon)...]
            guard !portText.isEmpty,
                  portText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Int(portText) else {
                throw MagentError.invalidAddress("invalid HTTP Host header")
            }
            port = parsed
        } else {
            host = value
            port = 80
        }

        guard host.isEmpty == false, (1...65535).contains(port) else {
            throw MagentError.invalidAddress("invalid HTTP Host header")
        }
        if let socketAddress = try? SocketAddress(ipAddress: host, port: port),
           let address = NetworkAddress(socketAddress) {
            if isBracketedIPv6, case .ipv6 = address {
                return address
            }
            if !isBracketedIPv6, case .ipv4 = address {
                return address
            }
        }
        guard !isBracketedIPv6, !host.contains(":") else {
            throw MagentError.invalidAddress("invalid HTTP Host header")
        }
        return .domain(host, port: port)
    }

    private static func hostValue(for target: NetworkAddress) -> String {
        switch target {
        case .ipv6(_, let port):
            return "[\(target.host)]:\(port)"
        case .ipv4, .domain:
            return target.port == 80 ? target.host : "\(target.host):\(target.port)"
        }
    }

    static let badRequest = Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8)
    static let badGateway = Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8)
    static let gatewayTimeout = Data("HTTP/1.1 504 Gateway Timeout\r\nConnection: close\r\n\r\n".utf8)
}
