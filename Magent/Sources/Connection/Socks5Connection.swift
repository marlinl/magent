import Atomics
import DNSClient
import Foundation
import NIOCore

/// SOCKS5 代理连接。
///
/// 连接先完成 greeting 和 request 两次交互；CONNECT 成功后进入 tunnel，
/// UDP ASSOCIATE 成功后保持 control connection。
/// TCP tunnel 两端均使用手动读取，每一批数据写入对端成功后才重新读取来源 Channel。
internal final class Socks5Connection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    /// 当前 SOCKS5 TCP control connection 对应的 UDP Channel handler。
    ///
    /// 首个 datagram 的发送方固定为本地 client address；之后来自该地址的数据走 outbound，
    /// 其他数据按远端 SocketAddress 查找对应的 Wire 后走 inbound。
    private final class Socks5UDPConnection: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>

        private weak var connection: Socks5Connection?
        private let dnsServers: [SocketAddress]
        private var wireV4Channel: Channel?
        private var wireV6Channel: Channel?
        private var dnsClients: [DNSClient] = []
        private var sourceAddress: SocketAddress?
        /// 直连域名 B 在当前 control connection 内解析出的最终远端地址。
        private var resolvedAddressMap: [NetworkAddress: SocketAddress] = [:]
        /// key 是 UDP Channel 实际发送到的远端地址：直连时为 B，代理时为 C。
        ///
        /// value 为 `nil` 表示直连 B，非空表示向代理节点 C 收发时使用的 Wire。
        private var wireMap: [SocketAddress: Wire?] = [:]

        init(_ connection: Socks5Connection, dnsServers: [SocketAddress]) {
            self.connection = connection
            self.dnsServers = dnsServers
            connection.proxyChannel.closeFuture.whenComplete { [weak self] _ in
                self?.closeUDPResources()
            }
        }

        /// 安装 association 的两个数据 Channel，并在同一 EventLoop 上创建远端 DNS clients。
        fileprivate func installChannels(v4Channel: Channel, v6Channel: Channel) -> EventLoopFuture<Void> {
            wireV4Channel = v4Channel
            wireV6Channel = v6Channel
            let clients = dnsServers.map {
                DNSClient.connect(on: v4Channel.eventLoop, config: [$0])
            }
            return EventLoopFuture.whenAllComplete(clients, on: v4Channel.eventLoop).flatMapThrowing { results in
                var connectedClients: [DNSClient] = []
                var connectionError: Error?
                for result in results {
                    switch result {
                    case .success(let client):
                        connectedClients.append(client)
                    case .failure(let error):
                        connectionError = connectionError ?? error
                    }
                }
                if let connectionError {
                    for client in connectedClients {
                        _ = client.close()
                    }
                    throw connectionError
                }
                self.dnsClients = connectedClients
            }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let envelope = unwrapInboundIn(data)
            let operation: EventLoopFuture<Void>
            do {
                guard let port = envelope.remoteAddress.port, port > 0 else {
                    throw MagentError.invalidAddress("UDP source address is invalid")
                }
                if sourceAddress == nil {
                    guard context.channel === wireV4Channel else {
                        throw MagentError.invalidAddress("UDP client must use the IPv4 relay channel")
                    }
                    sourceAddress = envelope.remoteAddress
                }

                if envelope.remoteAddress == sourceAddress {
                    operation = try outbound(envelope)
                } else {
                    operation = try inbound(envelope)
                }
            } catch {
                guard let connection = self.connection else {
                    context.close(promise: nil)
                    return
                }
                connection.proxyChannel.pipeline.fireErrorCaught(error)
                return
            }

            operation.whenComplete { result in
                guard let connection = self.connection else {
                    context.close(promise: nil)
                    return
                }
                switch result {
                case .success:
                    guard connection.state != .closed, context.channel.isActive else {
                        return
                    }
                    context.read()
                case .failure(let error):
                    connection.proxyChannel.pipeline.fireErrorCaught(error)
                }
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            if let connection, connection.state != .closed, connection.proxyChannel.isActive {
                connection.proxyChannel.pipeline.fireErrorCaught(MagentError.connectionClosed)
            }
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            guard let connection else {
                context.close(promise: nil)
                return
            }
            connection.proxyChannel.pipeline.fireErrorCaught(error)
        }

        /// 解析来自 A 的 SOCKS5 UDP datagram，按真实目标 B 路由后通过当前 UDP Channel 发往 B 或 C。
        private func outbound(_ envelope: InboundIn) throws -> EventLoopFuture<Void> {
            guard let connection else {
                throw MagentError.connectionClosed
            }
            let outbound = try Socks5Connection.parseUDPRelay(Data(envelope.data.readableBytesView))
            let targetAddress = outbound.target
            let wire = try connection.core.routeUDPWire(targetAddress)
            let output: Data
            if let wire {
                output = try wire.encodeOutbound(outbound.data, address: targetAddress)
                let remoteAddress = wire.getTargetAddress()
                let channel: Channel
                switch remoteAddress {
                case .v4:
                    guard let wireV4Channel else {
                        throw MagentError.connectionClosed
                    }
                    channel = wireV4Channel
                case .v6:
                    guard let wireV6Channel else {
                        throw MagentError.connectionClosed
                    }
                    channel = wireV6Channel
                case .unixDomainSocket:
                    throw MagentError.invalidAddress("UDP remote address must be IPv4 or IPv6")
                }
                if wireMap.index(forKey: remoteAddress) == nil {
                    wireMap.updateValue(wire, forKey: remoteAddress)
                }
                var buffer = channel.allocator.buffer(capacity: output.count)
                buffer.writeBytes(output)
                return channel.writeAndFlush(AddressedEnvelope(remoteAddress: remoteAddress, data: buffer))
            } else {
                output = outbound.data
            }

            return try resolveTargetAddress(targetAddress).flatMap { remoteAddress in
                let channel: Channel
                switch remoteAddress {
                case .v4:
                    guard let wireV4Channel = self.wireV4Channel else {
                        return connection.proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
                    }
                    channel = wireV4Channel
                case .v6:
                    guard let wireV6Channel = self.wireV6Channel else {
                        return connection.proxyChannel.eventLoop.makeFailedFuture(MagentError.connectionClosed)
                    }
                    channel = wireV6Channel
                case .unixDomainSocket:
                    return connection.proxyChannel.eventLoop.makeFailedFuture(
                        MagentError.invalidAddress("UDP remote address must be IPv4 or IPv6")
                    )
                }
                if self.wireMap.index(forKey: remoteAddress) == nil {
                    self.wireMap.updateValue(nil, forKey: remoteAddress)
                }
                var buffer = channel.allocator.buffer(capacity: output.count)
                buffer.writeBytes(output)
                return channel.writeAndFlush(AddressedEnvelope(remoteAddress: remoteAddress, data: buffer))
            }
        }

        /// 接收 B 或 C 的响应；C 的回包使用出站时记录的 Wire 解密，最后统一写回 A。
        private func inbound(_ envelope: InboundIn) throws -> EventLoopFuture<Void> {
            guard let sourceAddress, let wireV4Channel else {
                throw MagentError.connectionClosed
            }
            guard let wire = wireMap[envelope.remoteAddress] else {
                throw MagentError.invalidAddress("UDP inbound source has no outbound route")
            }

            let payload = Data(envelope.data.readableBytesView)
            let response: Data
            if let wire {
                let decoded = try wire.decodeInbound(payload)
                response = Socks5Connection.udpRelayResponse(source: decoded.address, data: decoded.data)
            } else {
                guard let remoteAddress = NetworkAddress(envelope.remoteAddress) else {
                    throw MagentError.invalidAddress("UDP inbound source is invalid")
                }
                response = Socks5Connection.udpRelayResponse(source: remoteAddress, data: payload)
            }

            var buffer = wireV4Channel.allocator.buffer(capacity: response.count)
            buffer.writeBytes(response)
            let responseEnvelope = AddressedEnvelope(remoteAddress: sourceAddress, data: buffer)
            return wireV4Channel.writeAndFlush(responseEnvelope)
        }

        /// IP 目标直接构造 SocketAddress；域名目标只通过配置的远端 DNS 异步解析。
        private func resolveTargetAddress(_ targetAddress: NetworkAddress) throws -> EventLoopFuture<SocketAddress> {
            guard let connection else {
                throw MagentError.connectionClosed
            }
            switch targetAddress {
            case .ipv4, .ipv6:
                do {
                    return connection.proxyChannel.eventLoop.makeSucceededFuture(try targetAddress.socketAddress())
                } catch {
                    return connection.proxyChannel.eventLoop.makeFailedFuture(error)
                }
            case .domain(let host, let port):
                if let cachedAddress = resolvedAddressMap[targetAddress] {
                    return connection.proxyChannel.eventLoop.makeSucceededFuture(cachedAddress)
                }
                guard !dnsClients.isEmpty else {
                    return connection.proxyChannel.eventLoop.makeFailedFuture(
                        MagentError.invalidOptions("DNS servers are required for direct UDP domain targets")
                    )
                }

                @Sendable
                func query(_ index: Int) -> EventLoopFuture<SocketAddress> {
                    guard index < dnsClients.count else {
                        return connection.proxyChannel.eventLoop.makeFailedFuture(
                            MagentError.invalidAddress("DNS returned no address for \(host)")
                        )
                    }
                    let client = dnsClients[index]
                    let timeout = TimeAmount.milliseconds(connection.core.defaultTimeout)
                    let ipv4Query = client.sendQuery(forHost: host, type: .a, timeout: timeout).map { message in
                        message.answers.compactMap { answer -> SocketAddress? in
                            guard case .a(let record) = answer else {
                                return nil
                            }
                            return try? SocketAddress(ipAddress: record.resource.stringAddress, port: port)
                        }
                    }
                    let ipv6Query = client.sendQuery(forHost: host, type: .aaaa, timeout: timeout).map { message in
                        message.answers.compactMap { answer -> SocketAddress? in
                            guard case .aaaa(let record) = answer else {
                                return nil
                            }
                            return try? SocketAddress(ipAddress: record.resource.stringAddress, port: port)
                        }
                    }
                    return ipv4Query
                        .and(ipv6Query)
                        .flatMapThrowing { ipv4Addresses, ipv6Addresses in
                            guard let address = ipv4Addresses.first ?? ipv6Addresses.first else {
                                throw MagentError.invalidAddress("DNS returned no address for \(host)")
                            }
                            self.resolvedAddressMap[targetAddress] = address
                            return address
                        }
                        .flatMapError { _ in query(index + 1) }
                }
                return query(0)
            }
        }

        /// 关闭当前 UDP association 拥有的两个数据 Channel 和所有 DNS client Channel。
        private func closeUDPResources() {
            wireV4Channel?.close(promise: nil)
            wireV6Channel?.close(promise: nil)
            for dnsClient in dnsClients {
                _ = dnsClient.close()
            }
        }
    }

    private enum State {
        case greeting
        case request
        case tunnel
        case idle
        case closed
    }

    private let proxyChannel: Channel
    private let core: MagentCore
    private let dnsServers: [SocketAddress]
    private var wireChannel: Channel?
    private var state: State = .greeting
    private var wire: Wire?
    private var requestBuffer: ByteBuffer
    private var isReadingGreeting = true
    private var isReadingInitialRequest = true
    private var isProxyInputClosed = false
    private let hasRespondedHandshake = ManagedAtomic(false)

    internal init(proxyChannel: Channel, core: MagentCore, dnsServers: [SocketAddress]) {
        self.proxyChannel = proxyChannel
        self.core = core
        self.dnsServers = dnsServers
        self.requestBuffer = proxyChannel.allocator.buffer(capacity: 0)
    }
}

extension Socks5Connection {
    /// 接收 proxy channel 的 greeting、request 或 tunnel payload。
    func upstream(context: ChannelHandlerContext, data: NIOAny) {
        var input = unwrapInboundIn(data)
        guard input.readableBytes > 0 else {
            switch state {
            case .greeting, .request, .tunnel, .idle:
                context.read()
            case .closed:
                break
            }
            return
        }

        switch state {
        case .greeting:
            do {
                guard isReadingGreeting else {
                    throw MagentError.malformedRequest("SOCKS5 request received before greeting response")
                }
                requestBuffer.writeBuffer(&input)
                try greeting(context)
            } catch {
                isReadingGreeting = false
                state = .closed
                respondProxyChannel(Self.noAcceptableMethods).whenComplete { _ in
                    self.proxyChannel.pipeline.fireErrorCaught(error)
                }
            }

        case .request:
            do {
                guard isReadingInitialRequest else {
                    throw MagentError.malformedRequest("SOCKS5 payload received before response")
                }

                requestBuffer.writeBuffer(&input)
                guard let requestLength = try Self.paserLength(requestBuffer) else {
                    context.read()
                    return
                }
                try checkInitalData(requestLength)
                let (command, address) = try Self.paserSocks5(requestBuffer)

                requestBuffer = proxyChannel.allocator.buffer(capacity: 0)
                isReadingInitialRequest = false
                try installWireChannel(command: command, address: address)
                context.read()
            } catch {
                isReadingInitialRequest = false
                let responseFuture = respondProxyChannelOnce(Self.reply(Self.replyCode(for: error)))
                    ?? proxyChannel.eventLoop.makeSucceededFuture(())
                responseFuture.whenComplete { _ in
                    self.proxyChannel.pipeline.fireErrorCaught(error)
                }
            }

        case .tunnel:
            do {
                try outbound(input)
            } catch {
                proxyChannel.pipeline.fireErrorCaught(error)
            }
        case .idle:
            context.read()
        case .closed:
            return
        }
    }

    private func greeting(_ context: ChannelHandlerContext) throws {
        guard let greetingLength = Self.paserGreetingLength(requestBuffer) else {
            context.read()
            return
        }
        try checkInitalData(greetingLength)
        try Self.paserGreeting(requestBuffer)

        requestBuffer = proxyChannel.allocator.buffer(capacity: 0)
        isReadingGreeting = false
        respondProxyChannel(Self.noAuthenticationRequired).map {
            guard self.state == .greeting else {
                return
            }
            if self.isProxyInputClosed {
                self.proxyChannel.pipeline.fireErrorCaught(MagentError.connectionClosed)
                return
            }
            self.state = .request
            self.proxyChannel.read()
        }.whenFailure { error in
            self.proxyChannel.pipeline.fireErrorCaught(error)
        }
    }

    /// proxy 输入方向关闭后，TCP tunnel 只关闭 wire 输出；UDP control connection 直接结束。
    func proxyInputClosed(context: ChannelHandlerContext) {
        guard !isProxyInputClosed else {
            return
        }
        isProxyInputClosed = true

        switch state {
        case .greeting:
            guard !isReadingGreeting else {
                isReadingGreeting = false
                proxyChannel.pipeline.fireErrorCaught(MagentError.connectionClosed)
                return
            }
        case .request:
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
        case .idle:
            context.close(promise: nil)
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
        case .tunnel:
            do {
                try inbound(input)
            } catch {
                proxyChannel.pipeline.fireErrorCaught(error)
            }
        case .greeting, .request, .idle, .closed:
            return
        }
    }

    /// TCP wire 输入方向关闭后，只关闭 proxy 的输出方向，继续接收 proxy 发往 wire 的数据。
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed else {
            context.fireUserInboundEventTriggered(event)
            return
        }

        switch state {
        case .tunnel:
            proxyChannel.close(mode: .output).whenFailure { error in
                self.proxyChannel.pipeline.fireErrorCaught(error)
            }
        case .greeting, .request:
            proxyChannel.pipeline.fireErrorCaught(MagentError.connectionClosed)
        case .idle, .closed:
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

    private func checkInitalData(_ requestLength: Int) throws {
        guard requestBuffer.readableBytes <= Self.maximumRequestSize else {
            throw MagentError.malformedRequest("SOCKS5 request is too large")
        }
        guard requestLength == requestBuffer.readableBytes else {
            throw MagentError.malformedRequest("SOCKS5 payload received before response")
        }
    }

    private func installWireChannel(command: Socks5Command, address: NetworkAddress) throws {
        switch command {
        case .udpAssociate:
            try installUDPAssociate()
            return

        case .bind:
            throw MagentError.invalidOptions("SOCKS5 BIND command is not supported")

        case .connect:
            try installTCPBind(address)
        }
    }

    private func installTCPBind(_ address: NetworkAddress) throws {
        guard !address.host.isEmpty, (1...65535).contains(address.port) else {
            throw MagentError.invalidAddress("invalid SOCKS5 destination")
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
                let responseFuture = self.respondProxyChannelOnce(Self.reply(Self.replyCode(for: error)))
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
            let responseFuture = self.respondProxyChannelOnce(Self.reply(Self.replyCode(for: error)))
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

    private func installUDPAssociate() throws {
        guard let proxyAddress = proxyChannel.localAddress.flatMap(NetworkAddress.init) else {
            throw MagentError.invalidAddress("SOCKS5 TCP Channel has no local IP address")
        }
        guard case .ipv4(let proxyIP, _) = proxyAddress else {
            throw MagentError.invalidAddress("SOCKS5 UDP relay requires an IPv4 control connection")
        }
        let v4BindAddress = try SocketAddress(ipAddress: "0.0.0.0", port: 0)
        let v6BindAddress = try SocketAddress(ipAddress: "::", port: 0)
        let handler = Socks5UDPConnection(self, dnsServers: dnsServers)
        _ = core.createUDPClientChannel(
            group: proxyChannel.eventLoop,
            address: v4BindAddress,
            handler: handler
        ).flatMap { v4Channel -> EventLoopFuture<(Channel, Channel)> in
            return self.core.createUDPClientChannel(
                group: self.proxyChannel.eventLoop,
                address: v6BindAddress,
                handler: handler
            ).map { v6Channel in
                return (v4Channel, v6Channel)
            }.flatMapError { error in
                v4Channel.close(promise: nil)
                return v4Channel.eventLoop.makeFailedFuture(error)
            }
        }.flatMap { channels -> EventLoopFuture<(Channel, Channel)> in
            let (v4Channel, v6Channel) = channels
            return handler.installChannels(v4Channel: v4Channel, v6Channel: v6Channel).map { channels }
        }.flatMap { channels -> EventLoopFuture<Void> in
            let (v4Channel, v6Channel) = channels
            guard self.state != .closed, self.proxyChannel.isActive else {
                v4Channel.close(promise: nil)
                v6Channel.close(promise: nil)
                return v4Channel.eventLoop.makeSucceededFuture(())
            }
            guard let relayPort = v4Channel.localAddress?.port, relayPort > 0 else {
                v4Channel.close(promise: nil)
                v6Channel.close(promise: nil)
                return v4Channel.eventLoop.makeFailedFuture(
                    MagentError.invalidAddress("SOCKS5 UDP Channel has no local address")
                )
            }
            let boundAddress = NetworkAddress.ipv4(proxyIP, port: relayPort)
            guard let responseFuture = self.respondProxyChannelOnce(
                Self.reply(.succeeded, boundAddress: boundAddress)
            ) else {
                v4Channel.close(promise: nil)
                v6Channel.close(promise: nil)
                return v4Channel.eventLoop.makeSucceededFuture(())
            }
            return responseFuture.map {
                guard self.state == .request,
                      self.proxyChannel.isActive,
                      v4Channel.isActive,
                      v6Channel.isActive else {
                    v4Channel.close(promise: nil)
                    v6Channel.close(promise: nil)
                    return
                }
                self.state = .idle
                if self.isProxyInputClosed {
                    self.proxyChannel.close(promise: nil)
                } else {
                    self.proxyChannel.read()
                }
                v4Channel.read()
                v6Channel.read()
            }
        }.flatMapError { error -> EventLoopFuture<Void> in
            let responseFuture = self.respondProxyChannelOnce(Self.reply(Self.replyCode(for: error)))
                ?? self.proxyChannel.eventLoop.makeSucceededFuture(())
            responseFuture.whenComplete { _ in
                self.proxyChannel.pipeline.fireErrorCaught(error)
            }
            return self.proxyChannel.eventLoop.makeSucceededFuture(())
        }
    }

    /// TCP wire 准备完成后先发送 succeeded，reply 写入成功才进入 tunnel 并启动双向读取。
    private func startTunnel(_ channel: Channel?) -> EventLoopFuture<Void> {
        guard let channel,
              state != .closed,
              proxyChannel.isActive else {
            channel?.close(promise: nil)
            return proxyChannel.eventLoop.makeSucceededFuture(())
        }
        let boundAddress = channel.localAddress.flatMap(NetworkAddress.init)
        guard let responseFuture = respondProxyChannelOnce(Self.reply(.succeeded, boundAddress: boundAddress)) else {
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

    /// 将 proxy channel 的 tunnel payload 编码后写入 wire channel。
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

    /// 将 TCP wire channel 数据解码后写回 proxy channel。
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

    /// 将 SOCKS5 response 或 tunnel 数据写回 proxy channel，并返回可排序的写入完成状态。
    private func respondProxyChannel(_ data: Data) -> EventLoopFuture<Void> {
        var output = proxyChannel.allocator.buffer(capacity: data.count)
        output.writeBytes(data)
        return proxyChannel.writeAndFlush(output)
    }

    /// 每条 SOCKS5 request 最多发送一次 reply；后续状态转换和错误处理由调用点负责。
    private func respondProxyChannelOnce(_ data: Data) -> EventLoopFuture<Void>? {
        guard hasRespondedHandshake.compareExchange(
            expected: false,
            desired: true,
            ordering: .acquiringAndReleasing
        ).exchanged else {
            return nil
        }
        return respondProxyChannel(data)
    }
}

// MARK: - SOCKS5 Protocol Codec

extension Socks5Connection {
    private enum ReplyCode: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case networkUnreachable = 0x03
        case hostUnreachable = 0x04
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08
    }

    /// greeting 完整时返回它的协议长度。
    private static func paserGreetingLength(_ input: ByteBuffer) -> Int? {
        let data = input.readableBytesView
        guard data.count >= 2 else { return nil }
        let greetingLength = 2 + Int(data[data.index(after: data.startIndex)])
        guard data.count >= greetingLength else { return nil }
        return greetingLength
    }

    /// 验证完整 greeting 的版本和 no-auth method。
    private static func paserGreeting(_ input: ByteBuffer) throws {
        let data = Data(input.readableBytesView)
        guard data.count >= 2 else {
            throw MagentError.malformedRequest("incomplete SOCKS5 greeting")
        }
        guard data[0] == 0x05 else {
            throw MagentError.malformedRequest("invalid SOCKS5 greeting version")
        }
        guard data[2...].contains(0x00) else {
            throw MagentError.invalidOptions("SOCKS5 no-auth method is unavailable")
        }
    }

    /// request 完整时返回它的协议长度。
    private static func paserLength(_ input: ByteBuffer) throws -> Int? {
        let data = input.readableBytesView
        guard data.count >= 4 else {
            return nil
        }

        let addressTypeIndex = data.index(data.startIndex, offsetBy: 3)
        let requestLength: Int
        switch data[addressTypeIndex] {
        case 0x01:
            requestLength = 10
        case 0x03:
            let lengthIndex = data.index(after: addressTypeIndex)
            guard lengthIndex < data.endIndex else {
                return nil
            }
            requestLength = 7 + Int(data[lengthIndex])
        case 0x04:
            requestLength = 22
        default:
            throw MagentError.invalidAddress("unsupported SOCKS5 address type")
        }
        guard data.count >= requestLength else { return nil }
        return requestLength
    }

    /// 解析完整 SOCKS5 request 的 command 和目标地址。
    private static func paserSocks5(_ input: ByteBuffer) throws -> (command: Socks5Command, address: NetworkAddress) {
        let data = Data(input.readableBytesView)
        guard data.count >= 4 else {
            throw MagentError.malformedRequest("incomplete SOCKS5 request")
        }
        guard data[0] == 0x05, data[2] == 0x00 else {
            throw MagentError.malformedRequest("invalid SOCKS5 request header")
        }
        guard let command = Socks5Command(rawValue: data[1]) else {
            throw MagentError.invalidOptions("unsupported SOCKS5 command")
        }
        guard let (address, _) = try parseAddress(data, offset: 3, zeroPort: command == .udpAssociate) else {
            throw MagentError.malformedRequest("incomplete SOCKS5 address")
        }
        return (command, address)
    }

    /// 解析本地 client 发往 UDP relay 的独立 SOCKS5 datagram。
    private static func parseUDPRelay(_ data: Data) throws -> (target: NetworkAddress, data: Data) {
        guard data.count >= 4 else {
            throw MagentError.malformedRequest("SOCKS5 UDP relay packet too short")
        }
        guard data[0] == 0x00, data[1] == 0x00 else {
            throw MagentError.malformedRequest("invalid SOCKS5 UDP reserved bytes")
        }
        guard data[2] == 0x00 else {
            throw MagentError.invalidOptions("SOCKS5 UDP fragmentation is not supported")
        }
        guard let (address, consumed) = try parseAddress(data, offset: 3, zeroPort: false) else {
            throw MagentError.malformedRequest("SOCKS5 UDP address is incomplete")
        }
        return (target: address, data: Data(data.dropFirst(consumed)))
    }

    /// 将真实远端来源地址和 payload 编码成 SOCKS5 UDP response。
    private static func udpRelayResponse(source: NetworkAddress, data: Data) -> Data {
        Data([0x00, 0x00, 0x00]) + addressBytes(of: source) + data
    }

    internal static func addressBytes(of address: NetworkAddress?) -> Data {
        guard let address else {
            return Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        }

        switch address {
        case .ipv4(let bytes, let port):
            return Data([0x01]) + bytes + UInt16(port).bigEndianBytes
        case .ipv6(let bytes, let port):
            return Data([0x04]) + bytes + UInt16(port).bigEndianBytes
        case .domain(let host, let port):
            let name = Data(host.utf8)
            guard name.count <= 255 else {
                return Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
            }
            return Data([0x03, UInt8(name.count)]) + name + UInt16(port).bigEndianBytes
        }
    }

    private static func reply(_ code: ReplyCode, boundAddress: NetworkAddress? = nil) -> Data {
        Data([0x05, code.rawValue, 0x00]) + addressBytes(of: boundAddress)
    }

    private static func replyCode(for error: Error) -> ReplyCode {
        switch error {
        case MagentError.invalidAddress:
            return .addressTypeNotSupported
        case MagentError.invalidOptions:
            return .commandNotSupported
        case MagentError.channelConnectionTimedOut:
            return .hostUnreachable
        case MagentError.proxyNodeNotFound, MagentError.invalidPolicy:
            return .networkUnreachable
        default:
            return .generalFailure
        }
    }

    private static let maximumRequestSize = 64 * 1024
    private static let noAuthenticationRequired = Data([0x05, 0x00])
    private static let noAcceptableMethods = Data([0x05, 0xFF])

    private static func parseAddress(_ data: Data, offset: Int, zeroPort: Bool) throws -> (NetworkAddress, Int)? {
        guard data.count > offset else { return nil }

        switch data[offset] {
        case 0x01:
            let start = offset + 1
            let portStart = start + 4
            guard data.count >= portStart + 2 else { return nil }
            let port = Int(data.readBigEndianUInt16(at: portStart))
            guard zeroPort || port > 0 else {
                throw MagentError.invalidAddress("invalid SOCKS5 port")
            }
            return (.ipv4(Data(data[start..<portStart]), port: port), portStart + 2)

        case 0x03:
            let lengthOffset = offset + 1
            guard data.count > lengthOffset else { return nil }
            let start = lengthOffset + 1
            let end = start + Int(data[lengthOffset])
            guard data.count >= end + 2 else { return nil }
            guard let host = String(data: data[start..<end], encoding: .utf8),
                  host.isEmpty == false else {
                throw MagentError.malformedRequest("invalid SOCKS5 domain")
            }
            let port = Int(data.readBigEndianUInt16(at: end))
            guard zeroPort || port > 0 else {
                throw MagentError.invalidAddress("invalid SOCKS5 port")
            }
            return (.domain(host, port: port), end + 2)

        case 0x04:
            let start = offset + 1
            let portStart = start + 16
            guard data.count >= portStart + 2 else { return nil }
            let port = Int(data.readBigEndianUInt16(at: portStart))
            guard zeroPort || port > 0 else {
                throw MagentError.invalidAddress("invalid SOCKS5 port")
            }
            return (.ipv6(Data(data[start..<portStart]), port: port), portStart + 2)

        default:
            throw MagentError.invalidAddress("unsupported SOCKS5 address type")
        }
    }
}

/// SOCKS5 request 中客户端请求的连接方式。
internal enum Socks5Command: UInt8, Sendable {
    case connect = 0x01
    case bind = 0x02
    case udpAssociate = 0x03
}
