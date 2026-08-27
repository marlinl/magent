//
//  MagentTCPConnection.swift
//  Magent
//
//  Created by MarlinL on 2026/7/14.
//

import Foundation
import NIOCore

/// 本地 TCP 首包的代理协议探测结果。
internal enum ProxyProbe: Sendable, Equatable {
    case incomplete
    case unsupported
    case httpForward
    case httpConnect
    case socks4
    case socks5

    /// 从当前已经收到的首包字节识别协议。
    static func detect(_ data: Data) -> ProxyProbe {
        guard let first = data.first else {
            return .incomplete
        }

        switch first {
        case 0x04:
            return .socks4
        case 0x05:
            return .socks5
        default:
            break
        }

        let connectMethod = Data("CONNECT ".utf8)
        if data.starts(with: connectMethod) {
            return .httpConnect
        }
        if connectMethod.starts(with: data) {
            return .incomplete
        }

        let isHTTPToken: (UInt8) -> Bool = { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A,
                 0x21, 0x23...0x27, 0x2A, 0x2B, 0x2D, 0x2E,
                 0x5E, 0x5F, 0x60, 0x7C, 0x7E:
                return true
            default:
                return false
            }
        }
        guard let space = data.firstIndex(of: 0x20) else {
            return data.count <= 32 && data.allSatisfy(isHTTPToken) ? .incomplete : .unsupported
        }

        let method = data[..<space]
        guard !method.isEmpty, method.count <= 32, method.allSatisfy(isHTTPToken) else {
            return .unsupported
        }
        let target = data[data.index(after: space)...]
        guard let firstTargetByte = target.first else {
            return .incomplete
        }
        if firstTargetByte == 0x2F || firstTargetByte == 0x2A {
            return .httpForward
        }

        guard let targetPrefix = String(bytes: target.prefix(8), encoding: .utf8)?.lowercased() else {
            return .unsupported
        }
        if targetPrefix.hasPrefix("http://") || targetPrefix.hasPrefix("https://") {
            return .httpForward
        }
        if "http://".hasPrefix(targetPrefix) || "https://".hasPrefix(targetPrefix) {
            return .incomplete
        }
        return .unsupported
    }
}

/// 主连接识别本地代理协议后创建的具体代理连接。
///
/// 每个实现对应一种已经确定的本地代理协议，例如 SOCKS4。`MagentTCPConnection` 持有当前
/// `ProxyConnection`，并把 server channel 收到的完整首包以及后续数据持续交给它。
///
/// `ProxyConnection` 负责接管协议识别之后的业务，包括解析本地代理请求、创建并持有
/// wire channel、把 server channel 数据转换后写入 wire channel，以及把 wire channel
/// 返回的数据转换后写回 server channel。它同时维护具体协议连接的状态和生命周期，
/// 并在 server channel 断开或连接发生错误时释放对应的 wire 资源。
///
/// 该协议描述的是完整的代理连接职责，不只是 NIO handler。具体实现可以同时作为 wire
/// channel 的 handler，但 handler 只是其接收 wire 数据的一种方式。
internal protocol ProxyConnection: AnyObject {
    /// 接收 server channel 的下一段数据。
    ///
    /// 第一次调用包含 `MagentTCPConnection` 在探测阶段累计的完整数据；后续调用包含同一条
    /// server channel 上继续收到的数据。具体实现负责根据自己的协议状态判断数据属于
    /// 握手请求还是已经建立连接后的转发 payload。使用手动读取的实现还负责在当前批次
    /// 消费完成后发起下一次读取。
    func upstream(context: ChannelHandlerContext, data: NIOAny)

    /// 上游 `MagentTCPConnection` 关闭具体代理连接持有的下游 channel、任务和协议状态。
    ///
    /// 此方法只供 `MagentTCPConnection` 在 accepted proxy channel 结束或出错时调用。
    /// 具体协议连接不得用它执行自我关闭，也不得在此关闭 accepted proxy channel。
    /// `error` 为空表示 accepted channel 正常结束，非空表示发生了错误。
    func closeConnection(error: Error?)

    /// accepted proxy channel 的输入方向已经关闭。
    ///
    /// 支持 half-close 的具体协议负责把 FIN 传播给下游输出方向；其他协议沿用完整关闭。
    func proxyInputClosed(context: ChannelHandlerContext)
}

extension ProxyConnection {
    func proxyInputClosed(context: ChannelHandlerContext) {
        context.close(promise: nil)
    }
}

/// App accepted channel 上的协议探针和连接生命周期所有者。
///
/// accepted Channel 默认关闭自动读取；本类型启动首读并在协议探测数据不足时续读。
/// 识别出具体协议后，读取许可由具体 `ProxyConnection` 的流控规则接管。
internal final class MagentTCPConnection: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private enum State {
        case detecting
        case active
        case closed
    }

    private let serverChannel: Channel
    private let core: MagentCore
    private let dnsServers: [SocketAddress]
    private var detectBuffer: ByteBuffer
    private var state: State = .detecting
    private var proxyConnection: ProxyConnection?

    internal init(_ serverChannel: Channel, core: MagentCore, dnsServers: [SocketAddress],
                  shutdownFuture: EventLoopFuture<Void>) {
        self.serverChannel = serverChannel
        self.core = core
        self.dnsServers = dnsServers
        self.detectBuffer = serverChannel.allocator.buffer(capacity: 0)
        shutdownFuture.whenComplete { [weak serverChannel] _ in
            serverChannel?.close(promise: nil)
        }
    }

    /// accepted Channel 激活后发出第一次手动读取，启动协议探测。
    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch state {
        case .detecting:
            var input = unwrapInboundIn(data)
            detectBuffer.writeBuffer(&input)
            let proxy = detectProxyProtocol()
            guard proxy != .incomplete else {
                context.read()
                return
            }
            installProxyConnection(proxy, context: context)
        case .active:
            proxyConnection?.upstream(context: context, data: data)
        case .closed:
            return
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Accepted TCP channel 已经被动失效；这不一定是异常，因此不附带错误。
        guard state != .closed else {
            context.fireChannelInactive()
            return
        }
        state = .closed
        proxyConnection?.closeConnection(error: nil)
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed else {
            context.fireUserInboundEventTriggered(event)
            return
        }

        switch state {
        case .detecting:
            context.close(promise: nil)
        case .active:
            if let proxyConnection {
                proxyConnection.proxyInputClosed(context: context)
            } else {
                context.close(promise: nil)
            }
        case .closed:
            return
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Pipeline 出错时先让具体协议连接清理下游资源，再关闭 accepted channel。
        guard state != .closed else {
            context.close(promise: nil)
            return
        }
        state = .closed
        proxyConnection?.closeConnection(error: error)
        context.close(promise: nil)
    }

    private func detectProxyProtocol() -> ProxyProbe {
        ProxyProbe.detect(Data(detectBuffer.readableBytesView))
    }

    private func installProxyConnection(_ proxy: ProxyProbe, context: ChannelHandlerContext) {
        switch proxy {
        case .socks4:
            let connection = Socks4Connection(proxyChannel: serverChannel, core: core)
            proxyConnection = connection
            state = .active

            let initialData = detectBuffer
            detectBuffer.clear()
            connection.upstream(context: context, data: NIOAny(initialData))
        case .socks5:
            let connection = Socks5Connection(proxyChannel: serverChannel, core: core, dnsServers: dnsServers)
            proxyConnection = connection
            state = .active

            let initialData = detectBuffer
            detectBuffer.clear()
            connection.upstream(context: context, data: NIOAny(initialData))
        case .httpConnect:
            let connection = HttpConnectConnection(proxyChannel: serverChannel, core: core)
            proxyConnection = connection
            state = .active

            let initialData = detectBuffer
            detectBuffer.clear()
            connection.upstream(context: context, data: NIOAny(initialData))
        case .httpForward:
            let connection = HttpForwardConnection(proxyChannel: serverChannel, core: core)
            proxyConnection = connection
            state = .active

            let initialData = detectBuffer
            detectBuffer.clear()
            connection.upstream(context: context, data: NIOAny(initialData))
        case .unsupported:
            serverChannel.pipeline.fireErrorCaught(MagentError.invalidOptions("\(proxy) is not supported yet"))
        case .incomplete:
            return
        }
    }
}
