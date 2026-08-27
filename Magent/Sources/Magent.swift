//
//  Magent.swift
//  Magent
//
//  Created by MarlinL on 2026/7/14.
//

import Atomics
import NIOCore
import NIOPosix

/// 跨运行周期统计当前 `Magent` 实例仍持有的 accepted TCP connections。
///
/// restart 会在旧 connections 异步关闭期间启动新 listener，因此计数器由服务实例共享，
/// 而不是由单次 runtime 持有。每个成功获取的额度只通过对应 Channel 的 `closeFuture` 归还。
internal final class AcceptedConnectionCounter: @unchecked Sendable {
    private let count = ManagedAtomic<Int>(0)

    /// 在不超过 `maximum` 的前提下原子增加当前连接数。
    internal func tryAcquire(maximum: Int) -> Bool {
        var current = count.load(ordering: .acquiring)
        while current < maximum {
            let result = count.compareExchange(
                expected: current,
                desired: current + 1,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged {
                return true
            }
            current = result.original
        }
        return false
    }

    /// 归还一个已经成功获取的连接额度。
    internal func release() {
        var current = count.load(ordering: .acquiring)
        while true {
            precondition(current > 0, "accepted connection counter underflow")
            let result = count.compareExchange(
                expected: current,
                desired: current - 1,
                ordering: .acquiringAndReleasing
            )
            if result.exchanged {
                return
            }
            current = result.original
        }
    }
}

/// Magent 代理服务的启动配置。
public struct MagentConfig: Sendable {

    /// 本地 TCP listener 的绑定地址。
    public let address: NetworkAddress

    /// 当前 `Magent` 实例允许同时持有的 accepted TCP connection 总数；默认 256。
    ///
    /// 超出额度的 child Channel 会在安装代理 handler 前立即关闭。
    public let maxAcceptedConnections: Int

    /// 直连 TCP channel 和远端 DNS 查询的默认超时时间（毫秒）。
    public let defaultTimeout: Int64

    /// SOCKS5 UDP 直连域名目标使用的远端 DNS 服务器；空数组表示不允许解析直连域名。
    public let dnsServers: [SocketAddress]

    public let defaultDecision: Decision
    public let defaultProxyNode: ProxyNode
    public let enableMatchTable: Bool
    public var rules: [ProxyRule]
    public var proxyNodes: [ProxyNode]

    public init(address: NetworkAddress, defaultDecision: Decision, defaultProxyNode: ProxyNode,
                enableMatchTable: Bool, maxAcceptedConnections: Int = 256,
                defaultTimeout: Int64 = 10_000, rules: [ProxyRule] = [],
                proxyNodes: [ProxyNode] = [], dnsServers: [SocketAddress] = []) {
        self.address = address
        self.maxAcceptedConnections = maxAcceptedConnections
        self.defaultTimeout = defaultTimeout
        self.dnsServers = dnsServers
        self.defaultDecision = defaultDecision
        self.defaultProxyNode = defaultProxyNode
        self.enableMatchTable = enableMatchTable
        self.rules = rules
        self.proxyNodes = proxyNodes
    }
}

/// Magent 本地代理服务。
///
/// `Magent` 拥有 TCP listener、所有已接受的本地连接以及内部 `EventLoopGroup`。
/// `start()` 和 `close()` 是同步的生命周期边界，调用方必须从 NIO EventLoop 之外调用，
/// 避免阻塞 EventLoop。
public actor Magent {

    private enum State {
        case running(tcpChannel: Channel, shutdownPromise: EventLoopPromise<Void>)
        case stop
    }

    private var state = State.stop
    private let group: MultiThreadedEventLoopGroup
    private let acceptedConnections = AcceptedConnectionCounter()


    /// 使用指定配置创建尚未启动的本地代理服务，并初始化该服务实例独有的 Core。
    public init(threadNumber: Int = System.coreCount) {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: threadNumber)
    }

    /// 使用配置地址绑定 TCP listener。
    ///
    /// 已启动时再次调用会抛出异常；运行中切换配置应使用 `restart(_:)`。
    /// `close()` 会关闭 EventLoopGroup，因此当前实例不能再次启动。
    public func start(_ config: MagentConfig) throws {
        guard case .stop = state else {
            throw MagentError.serverFailed("Magent server is already running")
        }
        try validate(config)
        var tcpChannel: Channel?
        let core = try makeCore(config)
        let shutdownPromise = group.next().makePromise(of: Void.self)

        do {
            let startedTCPChannel = try createTCPServerChannel(
                config,
                core: core,
                shutdownFuture: shutdownPromise.futureResult
            )
            tcpChannel = startedTCPChannel
            state = .running(tcpChannel: startedTCPChannel, shutdownPromise: shutdownPromise)
        } catch let startupError {
            shutdownPromise.succeed(())
            try? shutdown(keepEventLoopGroup: false, tcpChannel: tcpChannel)
            throw MagentError.serverFailed(String(describing: startupError))
        }
    }

    /// 停止接受新连接，关闭当前运行周期，并回收 Magent 自己创建的 EventLoopGroup。
    ///
    /// 停止状态调用会抛出异常。
    public func close() throws {
        guard case .running(let tcpChannel, _) = state else {
            throw MagentError.serverFailed("Magent server is not running")
        }
        try shutdown(keepEventLoopGroup: false, tcpChannel: tcpChannel)
    }

    public func restart(_ config: MagentConfig) throws {
        guard case .running(let oldTCPChannel, _) = state else {
            throw MagentError.serverFailed("Magent server is not running")
        }
        try validate(config)

        let newCore = try makeCore(config)
        let shutdownPromise = group.next().makePromise(of: Void.self)

        // 结束旧运行周期及其 accepted connections，保留 EventLoopGroup 创建新 listener。
        try shutdown(keepEventLoopGroup: true, tcpChannel: oldTCPChannel)

        var tcpChannel: Channel?
        do {
            let startedTCPChannel = try createTCPServerChannel(
                config,
                core: newCore,
                shutdownFuture: shutdownPromise.futureResult
            )
            tcpChannel = startedTCPChannel
            state = .running(tcpChannel: startedTCPChannel, shutdownPromise: shutdownPromise)
        } catch let startupError {
            // 新运行周期绑定失败时完成 promise，关闭已接受的 child 和新 listener；EventLoopGroup 保留供再次启动。
            shutdownPromise.succeed(())
            try? tcpChannel?.close().wait()
            throw MagentError.serverFailed(String(describing: startupError))
        }
    }

    private func createTCPServerChannel(_ config: MagentConfig, core: MagentCore,
            shutdownFuture: EventLoopFuture<Void>) throws -> Channel {
        let acceptedConnections = acceptedConnections
        let maxAcceptedConnections = config.maxAcceptedConnections
        return try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                guard acceptedConnections.tryAcquire(maximum: maxAcceptedConnections) else {
                    return channel.close()
                }
                channel.closeFuture.whenComplete { _ in
                    acceptedConnections.release()
                }
                let initialization = channel.pipeline.addHandler(
                    MagentTCPConnection(
                        channel,
                        core: core,
                        dnsServers: config.dnsServers,
                        shutdownFuture: shutdownFuture
                    )
                )
                initialization.whenFailure { _ in
                    channel.close(promise: nil)
                }
                return initialization
            }
            .bind(host: config.address.host, port: config.address.port)
            .wait()
    }

    private func validate(_ config: MagentConfig) throws {
        guard !config.address.host.isEmpty, (1...65_535).contains(config.address.port) else {
            throw MagentError.invalidAddress("invalid Magent listen address")
        }
        guard config.defaultTimeout > 0 else {
            throw MagentError.invalidOptions("default timeout must be greater than zero")
        }
        guard config.maxAcceptedConnections > 0 else {
            throw MagentError.invalidOptions("maximum accepted connections must be greater than zero")
        }
        for dnsServer in config.dnsServers {
            guard dnsServer.port.map({ (1...65_535).contains($0) }) == true else {
                throw MagentError.invalidAddress("invalid DNS server address")
            }
            if case .unixDomainSocket = dnsServer {
                throw MagentError.invalidAddress("DNS server must be an IPv4 or IPv6 address")
            }
        }
    }

    private func makeCore(_ config: MagentConfig) throws -> MagentCore {
        let core = try MagentCore(
            defaultDecision: config.defaultDecision,
            defaultProxyNode: config.defaultProxyNode,
            enableMatchTable: config.enableMatchTable,
            defaultTimeout: config.defaultTimeout,
            rules: config.rules
        )
        try core.putAllProxyNodes(config.proxyNodes)
        return core
    }

    private func shutdown(keepEventLoopGroup: Bool, tcpChannel: Channel?) throws {
        defer { state = .stop }
        var error: MagentError?
        let tcpClose = tcpChannel?.close()
        do {
            try tcpClose?.wait()
        } catch let cause {
            error = .serverFailed(String(describing: cause))
        }

        if case .running(_, let shutdownPromise) = state { shutdownPromise.succeed(()) }

        if keepEventLoopGroup {
            if let error {
                throw error
            }
            return
        }
        do {
            try group.syncShutdownGracefully()
        } catch let cause {
            error = error ?? .serverFailed(String(describing: cause))
        }
        if let error {
            throw error
        }
    }
}
