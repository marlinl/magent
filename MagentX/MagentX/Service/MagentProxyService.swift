//
//  MagentProxyService.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Coordinates local proxy and PAC background network listeners.
//

import Darwin
import Foundation
@preconcurrency import Magent
@preconcurrency import NIOCore
@preconcurrency import NIOPosix

/// MagentX 后台代理网络协调服务，负责按 `GeneralSettings` 编排本地代理入口和 PAC 入口。
actor MagentProxyService {
    private var configuration: Configuration
    private var eventLoopGroup: MultiThreadedEventLoopGroup
    private var proxyService: ProxyService
    private var isProxyServerRunning = false
    private var isPacServerRunning = false

    /// 使用持久化的常规设置创建代理网络服务实例。
    @MainActor
    init(generalSettings: GeneralSettings) throws {
        let configuration = try Configuration(generalSettings: generalSettings)
        try self.init(configuration: configuration)
    }

    private init(configuration: Configuration) throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: configuration.proxyThreadNumber)

        self.configuration = configuration
        self.eventLoopGroup = eventLoopGroup
        self.proxyService = ProxyService(
            endpoint: configuration.proxyEndpoint,
            pacEndpoint: configuration.pacEndpoint,
            eventLoopGroup: eventLoopGroup,
            threadNumber: configuration.proxyThreadNumber
        )
    }

    deinit {
        try? eventLoopGroup.syncShutdownGracefully()
    }

    // MARK: - Proxy Server

    /// 重新加载持久化常规设置；监听已启动时会使用新配置重启对应服务。
    func reload(generalSettings: GeneralSettings) async throws {
        let configuration = try await MainActor.run {
            try Configuration(generalSettings: generalSettings)
        }
        guard hasDifferentEndpoint(from: configuration) else {
            return
        }
        MagentXLogger.info(
            "Reloading local proxy runtime",
            category: .service,
            metadata: [
                "proxyEndpoint": "\(configuration.proxyEndpoint.address):\(configuration.proxyEndpoint.port)",
                "pacEndpoint": "\(configuration.pacEndpoint.address):\(configuration.pacEndpoint.port)",
                "threadNumber": "\(configuration.proxyThreadNumber)"
            ]
        )
        try await applyConfiguration(configuration)
    }

    /// 启动本地 HTTP/SOCKS 代理监听服务，监听地址和端口来自 `GeneralSettings`。
    func startProxyServer() async throws {
        guard isProxyServerRunning == false else { return }
        try await proxyService.start()
        isProxyServerRunning = true
        MagentXLogger.info(
            "Started local proxy listener",
            category: .service,
            metadata: ["endpoint": "\(configuration.proxyEndpoint.address):\(configuration.proxyEndpoint.port)"]
        )
    }

    /// 停止本地代理监听服务。未启动时保持幂等。
    func stopProxyServer() async throws {
        guard isProxyServerRunning else { return }
        try await proxyService.stop()
        isProxyServerRunning = false
        MagentXLogger.info("Stopped local proxy listener", category: .service)
    }

    // MARK: - PAC Server

    /// 启动 PAC 文件 HTTP 监听服务，监听地址和端口来自 `GeneralSettings`。
    func startPacServer() async throws {
        guard isPacServerRunning == false else { return }
        try await proxyService.startPACServer(proxyEndpoint: configuration.proxyEndpoint)
        isPacServerRunning = true
        MagentXLogger.info(
            "Started PAC listener",
            category: .service,
            metadata: ["endpoint": "\(configuration.pacEndpoint.address):\(configuration.pacEndpoint.port)"]
        )
    }

    /// 停止 PAC 文件 HTTP 监听服务。未启动时保持幂等。
    func stopPacServer() async throws {
        guard isPacServerRunning else { return }
        try await proxyService.stopPACServer()
        isPacServerRunning = false
        MagentXLogger.info("Stopped PAC listener", category: .service)
    }

    private func applyConfiguration(_ configuration: Configuration) async throws {
        let wasProxyRunning = isProxyServerRunning
        let wasPacRunning = isPacServerRunning

        if wasPacRunning {
            try await stopPacServer()
        }
        if wasProxyRunning {
            try await stopProxyServer()
        }

        try rebuildRuntime(configuration: configuration)

        if wasProxyRunning {
            try await startProxyServer()
        }
        if wasPacRunning {
            try await startPacServer()
        }
    }

    private func hasDifferentEndpoint(from configuration: Configuration) -> Bool {
        configuration.proxyEndpoint.address != self.configuration.proxyEndpoint.address ||
            configuration.proxyEndpoint.port != self.configuration.proxyEndpoint.port ||
            configuration.pacEndpoint.address != self.configuration.pacEndpoint.address ||
            configuration.pacEndpoint.port != self.configuration.pacEndpoint.port ||
            configuration.proxyThreadNumber != self.configuration.proxyThreadNumber
    }

    private func rebuildRuntime(configuration: Configuration) throws {
        try eventLoopGroup.syncShutdownGracefully()

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: configuration.proxyThreadNumber)

        self.configuration = configuration
        self.eventLoopGroup = eventLoopGroup
        proxyService = ProxyService(
            endpoint: configuration.proxyEndpoint,
            pacEndpoint: configuration.pacEndpoint,
            eventLoopGroup: eventLoopGroup,
            threadNumber: configuration.proxyThreadNumber
        )
    }

    /// 本地代理和 PAC 监听配置快照。
    fileprivate struct Configuration: Sendable {
        let proxyEndpoint: ListenEndpoint
        let pacEndpoint: ListenEndpoint
        let proxyThreadNumber: Int

        init(generalSettings: GeneralSettings) throws {
            self.proxyEndpoint = try ListenEndpoint(
                address: generalSettings.proxyListenAddress,
                port: generalSettings.proxyListenPort
            )
            self.pacEndpoint = try ListenEndpoint(
                address: generalSettings.pacListenAddress,
                port: generalSettings.pacListenPort
            )
            guard generalSettings.proxyThreadNumber > 0 else {
                throw MagentXError.invalidProxyThreadNumber(generalSettings.proxyThreadNumber)
            }
            self.proxyThreadNumber = generalSettings.proxyThreadNumber
        }
    }

    /// 已校验的本地监听端点。
    struct ListenEndpoint: Sendable {
        let address: String
        let port: Int

        nonisolated init(address: String, port: Int) throws {
            let normalizedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedAddress.isEmpty == false else {
                throw MagentXError.invalidListenAddress(address)
            }
            guard (1...65535).contains(port) else {
                throw MagentXError.invalidListenPort(port)
            }

            self.address = normalizedAddress
            self.port = port
        }
    }
}

/// 本地代理监听服务，负责准备启动配置并委托 `MagentService` 管理核心生命周期。
nonisolated private final class ProxyService {
    private let endpoint: MagentProxyService.ListenEndpoint
    private let eventLoopGroup: EventLoopGroup
    private let magentService: MagentService

    init(
        endpoint: MagentProxyService.ListenEndpoint,
        pacEndpoint: MagentProxyService.ListenEndpoint,
        eventLoopGroup: EventLoopGroup,
        threadNumber: Int
    ) {
        self.endpoint = endpoint
        self.eventLoopGroup = eventLoopGroup
        self.magentService = MagentService(
            threadNumber: threadNumber,
            eventLoopGroup: eventLoopGroup,
            pacEndpoint: pacEndpoint
        )
    }

    /// 打开本地 HTTP/SOCKS 代理监听端口；重复调用保持幂等。
    func start() async throws {
        try await ListenPortAvailabilityProbe(endpoint: endpoint, eventLoopGroup: eventLoopGroup).validate()

        let placeholderNode = try ProxyNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            address: SocketAddress(ipAddress: "127.0.0.1", port: 9),
            cipher: .chacha20IetfPoly1305,
            password: "unused-direct-route"
        )
        let config = MagentConfig(
            address: .domain(endpoint.address, port: endpoint.port),
            defaultDecision: .direct,
            defaultProxyNode: placeholderNode,
            enableMatchTable: false
        )

        try await magentService.start(config)
    }

    /// 关闭本地代理监听端口；未启动时保持幂等。
    func stop() async throws {
        try await magentService.stop()
    }

    /// 打开由 `MagentService` 管理的 PAC HTTP 监听端口。
    func startPACServer(proxyEndpoint: MagentProxyService.ListenEndpoint) async throws {
        try await magentService.startPACServer(proxyEndpoint: proxyEndpoint)
    }

    /// 关闭由 `MagentService` 管理的 PAC HTTP 监听端口。
    func stopPACServer() async throws {
        try await magentService.stopPACServer()
    }
}

/// 本地监听端口可用性探针，用一次短生命周期 bind 预检端口占用并归一化最终绑定错误。
nonisolated struct ListenPortAvailabilityProbe {
    private let endpoint: MagentProxyService.ListenEndpoint
    private let eventLoopGroup: EventLoopGroup

    /// 创建绑定到指定 endpoint 和 event loop group 的端口探针。
    init(endpoint: MagentProxyService.ListenEndpoint, eventLoopGroup: EventLoopGroup) {
        self.endpoint = endpoint
        self.eventLoopGroup = eventLoopGroup
    }

    /// 通过短生命周期监听验证端口当前可用；占用时抛出统一的 MagentX 错误。
    func validate() async throws {
        do {
            let channel = try await ServerBootstrap(group: eventLoopGroup)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeSucceededFuture(())
                }
                .bind(host: endpoint.address, port: endpoint.port)
                .get()
            try await channel.close().get()
        } catch {
            throw Self.normalizedBindError(error, endpoint: endpoint)
        }
    }

    /// 将底层 NIO 绑定错误归一化为 app 层可展示错误，非端口占用错误保持原样。
    static func normalizedBindError(
        _ error: Error,
        endpoint: MagentProxyService.ListenEndpoint
    ) -> Error {
        guard let ioError = error as? IOError, ioError.errnoCode == EADDRINUSE else {
            return error
        }
        return MagentXError.listenPortUnavailable(endpoint.address, endpoint.port)
    }
}
