//
//  Socks4Connection.swift
//  Magent
//
//  Created by MarlinL on 2026/6/20.
//

import Atomics
import Foundation
import NIOCore

/// SOCKS4/SOCKS4a 代理连接。
///
/// 握手阶段等待完整 request，解析目标并创建 wire channel；握手成功后进入 tunnel，
/// proxy channel 和 wire channel 的后续数据分别通过 `outbound`、`inbound` 双向转发。
/// tunnel 两端均使用手动读取，每一批数据写入对端成功后才重新读取来源 Channel。
internal final class Socks4Connection: ChannelInboundHandler, ProxyConnection, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private enum State {
        case handshake
        case tunnel
        case closed
    }

    private let proxyChannel: Channel
    private let core: MagentCore
    private var wireChannel: Channel?
    private var state: State = .handshake
    private var wire: Wire?
    private var isReadingInitialRequest = true
    private var isProxyInputClosed = false
    private var initalBuffer: ByteBuffer
    private let hasRespondedHandshake = ManagedAtomic(false)

    internal init(proxyChannel: Channel, core: MagentCore) {
        self.proxyChannel = proxyChannel
        self.core = core
        self.initalBuffer = proxyChannel.allocator.buffer(capacity: 0)
    }

    /// 接收 proxy channel 的 SOCKS4 request 或 tunnel payload。
    func upstream(context: ChannelHandlerContext, data: NIOAny) {
        var input = unwrapInboundIn(data)
        guard input.readableBytes > 0 else {
            if state != .closed {
                context.read()
            }
            return
        }

        switch state {
        case .handshake:
            do {
                guard isReadingInitialRequest else {
                    throw MagentError.malformedRequest("SOCKS4 payload received before granted")
                }

                initalBuffer.writeBuffer(&input)
                guard let requestLength = try Self.paserLength(initalBuffer) else {
                    context.read()
                    return
                }
                try checkInitalData(requestLength)
                let (command, address) = try Self.paserSocks4(initalBuffer)

                initalBuffer = proxyChannel.allocator.buffer(capacity: 0)
                isReadingInitialRequest = false
                try installWireChannel(command: command, address: address)
                context.read()
            } catch {
                isReadingInitialRequest = false
                let responseFuture = respondProxyChannelOnce(Self.rejected)
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

    private func checkInitalData(_ requestLength: Int) throws {
        guard requestLength == initalBuffer.readableBytes else {
            throw MagentError.malformedRequest("SOCKS4 payload received before granted")
        }
    }

    private func installWireChannel(command: Socks4Command, address: NetworkAddress) throws {
        guard command == .connect else {
            throw MagentError.invalidOptions("SOCKS4 command is not supported")
        }
        guard !address.host.isEmpty, (1...65535).contains(address.port) else {
            throw MagentError.invalidAddress("invalid SOCKS4 destination")
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
                let responseFuture = self.respondProxyChannelOnce(Self.rejected)
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
            let responseFuture = self.respondProxyChannelOnce(Self.rejected)
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

    /// wire 准备完成后先发送 granted，响应写入成功才进入 tunnel 并启动双向读取。
    private func startTunnel(_ channel: Channel?) -> EventLoopFuture<Void> {
        guard let channel,
              state != .closed,
              proxyChannel.isActive else {
            channel?.close(promise: nil)
            return proxyChannel.eventLoop.makeSucceededFuture(())
        }
        guard let responseFuture = respondProxyChannelOnce(Self.granted) else {
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

    /// 将 SOCKS4 response 或 tunnel 数据写回 proxy channel，并返回可排序的写入完成状态。
    private func respondProxyChannel(_ data: Data) -> EventLoopFuture<Void> {
        var output = proxyChannel.allocator.buffer(capacity: data.count)
        output.writeBytes(data)
        return proxyChannel.writeAndFlush(output)
    }

    /// 每条 SOCKS4 连接最多发送一次握手响应；后续状态转换和错误处理由调用点负责。
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

    private static func paserLength(_ input: ByteBuffer) throws -> Int? {
        let data = input.readableBytesView
        guard data.count <= maximumRequestSize else {
            throw MagentError.malformedRequest("SOCKS4 request is too large")
        }
        guard data.count >= 8 else {
            return nil
        }

        let userIDStart = data.index(data.startIndex, offsetBy: 8)
        guard let userIDEnd = data[userIDStart...].firstIndex(of: 0x00) else {
            return nil
        }

        let ipStart = data.index(data.startIndex, offsetBy: 4)
        let isSocks4a = data[ipStart] == 0x00
            && data[data.index(ipStart, offsetBy: 1)] == 0x00
            && data[data.index(ipStart, offsetBy: 2)] == 0x00
            && data[data.index(ipStart, offsetBy: 3)] != 0x00

        guard isSocks4a else {
            return data.distance(from: data.startIndex, to: data.index(after: userIDEnd))
        }

        let domainStart = data.index(after: userIDEnd)
        guard domainStart < data.endIndex, let domainEnd = data[domainStart...].firstIndex(of: 0x00) else {
            return nil
        }
        return data.distance(from: data.startIndex, to: data.index(after: domainEnd))
    }

    private static func paserSocks4(_ input: ByteBuffer)
        throws -> (command: Socks4Command, address: NetworkAddress) {
        let data = Data(input.readableBytesView)
        guard !data.isEmpty else {
            throw MagentError.malformedRequest("empty SOCKS4 request")
        }
        guard data[0] == 0x04 else {
            throw MagentError.malformedRequest("invalid SOCKS4 version")
        }
        guard data.count >= 8 else {
            throw MagentError.malformedRequest("incomplete SOCKS4 request")
        }
        guard let command = Socks4Command(rawValue: data[1]) else {
            throw MagentError.malformedRequest("unknown SOCKS4 command")
        }
        // 当前采用 no-auth SOCKS4 profile；USERID 仅用于确定请求边界，不执行 identd 校验。
        guard let userIDEnd = data[8...].firstIndex(of: 0x00) else {
            throw MagentError.malformedRequest("incomplete SOCKS4 request")
        }

        let isSocks4a = data[4] == 0x00
            && data[5] == 0x00
            && data[6] == 0x00
            && data[7] != 0x00

        let port = Int(data.readBigEndianUInt16(at: 2))
        guard port > 0 else {
            throw MagentError.invalidAddress("invalid SOCKS4 port")
        }

        if isSocks4a {
            let domainStart = data.index(after: userIDEnd)
            guard domainStart < data.endIndex, let domainEnd = data[domainStart...].firstIndex(of: 0x00) else {
                throw MagentError.malformedRequest("incomplete SOCKS4a request")
            }
            guard domainStart < domainEnd,
                  let domain = String(data: data[domainStart..<domainEnd], encoding: .utf8)
            else {
                throw MagentError.invalidAddress("invalid SOCKS4a domain")
            }

            return (command, .domain(domain, port: port))
        }

        return (command, .ipv4(Data(data[4..<8]), port: port))
    }

    private static let maximumRequestSize = 64 * 1024

    private static let granted = Data([
        0x00, 0x5A,
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])

    private static let rejected = Data([
        0x00, 0x5B,
        0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    ])
}

internal enum Socks4Command: UInt8 {
    case connect = 0x01
    case bind = 0x02
}
