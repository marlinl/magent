//
//  Magent.swift
//  Magent
//
//  Created by MarlinL on 2026/7/14.
//

import NIOCore
import NIOPosix

/// Magent 代理服务的启动配置。
public struct MagentConfig: Sendable {

  /// 本地 TCP listener 的绑定地址。
  public let listener: NetworkAddress

  /// 直连 TCP channel 和远端 DNS 查询的默认超时时间（毫秒）。
  public let defaultTimeout: Int64

  /// SOCKS5 UDP 直连域名使用的 DNS 地址；nil 表示不支持 UDP 直连域名解析。
  public let dnsListener: SocketAddress?

  /// 规则未命中时采用的路由决策。
  public let defaultDecision: Decision

  /// 本次运行参与匹配的规则；空数组表示所有目标使用默认决策。
  public var rules: [ProxyRule]

  /// 所有可用代理节点，包含默认决策和规则引用的节点。
  public var proxyNodes: [ProxyNode]

  /// 创建监听、路由和 DNS 配置；服务不设置已接入连接数上限。
  public init(
    listener: NetworkAddress, defaultDecision: Decision = .direct, rules: [ProxyRule] = [],
    proxyNodes: [ProxyNode] = [], defaultTimeout: Int64 = 10_000,
    dnsListener: SocketAddress? = nil
  ) {
    self.listener = listener
    self.defaultTimeout = defaultTimeout
    self.dnsListener = dnsListener
    self.defaultDecision = defaultDecision
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
    let core = try MagentCore(
      defaultDecision: config.defaultDecision,
      proxyNodes: config.proxyNodes,
      defaultTimeout: config.defaultTimeout,
      rules: config.rules
    )
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

    let newCore = try MagentCore(
      defaultDecision: config.defaultDecision,
      proxyNodes: config.proxyNodes,
      defaultTimeout: config.defaultTimeout,
      rules: config.rules
    )
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

  /// 创建 listener，为每条接入连接安装协议 handler，并在安装失败时关闭该连接。
  private func createTCPServerChannel(
    _ config: MagentConfig, core: MagentCore,
    shutdownFuture: EventLoopFuture<Void>
  ) throws -> Channel {
    return try ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 256)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(ChannelOptions.autoRead, value: false)
      .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
      .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .childChannelInitializer { channel in
        let initialization = channel.pipeline.addHandler(
          MagentTCPConnection(
            channel,
            core: core,
            dnsAddress: config.dnsListener,
            shutdownFuture: shutdownFuture
          )
        )
        initialization.whenFailure { _ in
          channel.close(promise: nil)
        }
        return initialization
      }
      .bind(host: config.listener.host, port: config.listener.port)
      .wait()
  }

  /// 在创建运行周期前校验监听地址、超时和 DNS 服务器配置。
  private func validate(_ config: MagentConfig) throws {
    guard !config.listener.host.isEmpty, (1...65_535).contains(config.listener.port) else {
      throw MagentError.invalidAddress("invalid Magent listen address")
    }
    guard config.defaultTimeout > 0 else {
      throw MagentError.invalidOptions("default timeout must be greater than zero")
    }
    if let dnsListener = config.dnsListener {
      guard dnsListener.port.map({ (1...65_535).contains($0) }) == true else {
        throw MagentError.invalidAddress("invalid DNS server address")
      }
      if case .unixDomainSocket = dnsListener {
        throw MagentError.invalidAddress("DNS server must be an IPv4 or IPv6 address")
      }
    }
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
