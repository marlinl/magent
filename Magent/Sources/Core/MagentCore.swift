import Foundation
import NIOCore
import NIOPosix

/// Magent Core 层的 Wire 匹配入口。
/// A service-owned Core instance. Its lifetime is independent from other Magent instances;
/// callers must serialize configuration mutations with the owning service lifecycle.
internal final class MagentCore: @unchecked Sendable {

  private let defaultDecision: Decision
  private let routeCache: MagentCache<Decision>
  private let router: MagentRouter
  internal let defaultTimeout: Int64

  /// 以节点 UUID 为 key 保存当前可用的代理节点；相同 UUID 的新配置覆盖旧配置。
  private var nodes: [UUID: ProxyNode]
  private var addressNodes: [SocketAddress: UUID]
  private var udpWires: [UUID: Wire]

  /// 装载当前运行周期的完整节点和规则；没有规则时不缓存默认决策。
  /// 默认代理节点在完整节点列表装载后校验，确保初始化成功的 Core 可直接使用默认决策。
  internal init(
    defaultDecision: Decision, proxyNodes: [ProxyNode],
    defaultTimeout: Int64, rules: [ProxyRule]
  ) throws {
    self.defaultDecision = defaultDecision
    self.routeCache = MagentCache(capacity: rules.isEmpty ? 0 : 4096)
    self.router = MagentRouter(rules)
    self.defaultTimeout = defaultTimeout
    self.nodes = [:]
    self.addressNodes = [:]
    self.udpWires = [:]
    try putAllProxyNodes(proxyNodes)
    if case .proxy(let nodeID) = defaultDecision, nodes[nodeID] == nil {
      throw MagentError.proxyNodeNotFound(nodeID)
    }
  }

  /// 根据代理节点类型创建对应的 UDP Wire；创建失败时原样向上抛出异常。
  private func createUDPWire(_ node: ProxyNode) throws -> Wire {
    switch node.type {
    case .shadowsocks:
      return try ShadowsocksUDPWire(proxyNode: node)
    }
  }

  private func createTCPWire(_ node: ProxyNode) throws -> Wire {
    switch node.type {
    case .shadowsocks:
      return try ShadowsocksTCPWire(proxyNode: node)
    }
  }

  /// 批量写入代理节点；相同 UUID 按数组顺序覆盖，未包含的已有节点保持不变。
  /// 每个 UDP Wire 都经由 `createUDPWire(_:)` 创建，使节点类型与 Wire 的映射只保留在一个位置。
  internal func putAllProxyNodes(_ proxyNodes: [ProxyNode]) throws {
    for node in proxyNodes {
      if let existingNodeID = addressNodes[node.address], existingNodeID != node.id {
        throw MagentError.invalidPolicy(
          "proxy node address \(node.address) is already used by \(existingNodeID)"
        )
      }

      let udpWire = try createUDPWire(node)
      if let previousNode = nodes[node.id], previousNode.address != node.address {
        addressNodes.removeValue(forKey: previousNode.address)
      }
      nodes[node.id] = node
      addressNodes[node.address] = node.id
      udpWires[node.id] = udpWire
    }
  }

  /// 地址已在模型边界规范化；规则为空或未命中时使用默认决策。
  private func routeDecision(_ address: NetworkAddress) -> Decision {
    let key = Self.routeCacheKey(address)
    if let decision = routeCache.get(key) {
      return decision
    }

    return routeCache.getOrLoad(key) { _ in
      return router.match(address) ?? defaultDecision
    }
  }

  /// 根据目标地址匹配路由决策并获得对应的 TCP Wire。
  ///
  /// 路由决策按地址类型和 host/IP 缓存。
  /// 当前规则不匹配端口，因此 cache key 不包含端口。
  /// 规则为空或没有规则命中时，使用初始化时传入的默认决策。
  internal func routeTCPWire(_ address: NetworkAddress) throws -> Wire? {
    let decision = routeDecision(address)
    switch decision {
    case .direct:
      return nil

    case .proxy(let nodeID):
      guard let node = nodes[nodeID] else {
        throw MagentError.proxyNodeNotFound(nodeID)
      }
      return try createTCPWire(node)
    }
  }

  /// 根据目标地址匹配路由决策并获得对应的 UDP Wire。
  ///
  /// `.direct` 返回 `nil`；`.proxy` 引用不存在的节点时抛出错误，禁止将代理配置错误降级为直连。
  internal func routeUDPWire(_ address: NetworkAddress) throws -> Wire? {
    let decision = routeDecision(address)
    switch decision {
    case .direct:
      return nil

    case .proxy(let nodeID):
      guard nodes[nodeID] != nil, let wire = udpWires[nodeID] else {
        throw MagentError.proxyNodeNotFound(nodeID)
      }
      return wire
    }
  }

  /// 为路由决策缓存构造稳定 key，并区分域名、IPv4 和 IPv6 地址。
  private static func routeCacheKey(_ address: NetworkAddress) -> String {
    switch address.address {
    case .domain(let host, _):
      return "domain:\(host.hasSuffix(".") ? String(host.dropLast()) : host)"
    case .ip(.v4):
      return "ipv4:\(address.host)"
    case .ip(.v6):
      return "ipv6:\(address.host)"
    case .ip(.unixDomainSocket):
      preconditionFailure("NetworkAddress only stores numeric IP sockets")
    }
  }

  /// 使用指定 EventLoopGroup 创建下游 TCP client Channel。
  ///
  /// handler 在 Channel 激活前安装，避免连接成功后先收到数据再补装 handler。
  /// 返回的 Channel 关闭自动读取、允许远端 half-close，且每次显式读取最多产生一条消息，
  /// 由具体协议连接在下游写入完成后发起下一次读取并处理输入方向关闭。
  internal func createTCPClientChannel(
    group: EventLoopGroup, address: NetworkAddress, timeout: Int64,
    handler: ChannelHandler & Sendable
  ) -> EventLoopFuture<Channel> {
    guard !address.host.isEmpty, (1...65535).contains(address.port) else {
      return group.next().makeFailedFuture(MagentError.invalidAddress("Invalid TCP destination"))
    }
    guard timeout > 0 else {
      return group.next().makeFailedFuture(
        MagentError.invalidOptions("TCP connection timeout must be greater than zero")
      )
    }

    let bootstrap = ClientBootstrap(group: group)
      .connectTimeout(.milliseconds(timeout))
      .channelOption(ChannelOptions.autoRead, value: false)
      .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
      .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .channelInitializer { channel in
        channel.pipeline.addHandler(handler)
      }
    let connection: EventLoopFuture<Channel>
    switch address.address {
    case .ip(let socket):
      // 数值目标直接使用已存储端点，禁止重新进入主机名解析。
      connection = bootstrap.connect(to: socket)
    case .domain(let host, let port):
      connection = bootstrap.connect(host: host, port: Int(port))
    }
    return connection.flatMapErrorThrowing { error in
      if let channelError = error as? ChannelError, case .connectTimeout = channelError {
        throw MagentError.channelConnectionTimedOut
      }
      throw MagentError.channelCreationFailed(String(describing: error))
    }
  }

  /// 使用已经解析完成的 NIO SocketAddress 创建下游 TCP client Channel。
  ///
  /// Wire 的目标地址已经是 SocketAddress，直接使用 `connect(to:)`，
  /// 避免重新转换成 NetworkAddress。
  /// 返回的 Channel 使用和 NetworkAddress 重载相同的手动读取约束。
  internal func createTCPClientChannel(
    group: EventLoopGroup, address: SocketAddress, timeout: Int64,
    handler: ChannelHandler & Sendable
  ) -> EventLoopFuture<Channel> {
    if let port = address.port, !(1...65535).contains(port) {
      return group.next().makeFailedFuture(MagentError.invalidAddress("Invalid TCP destination"))
    }
    guard timeout > 0 else {
      return group.next().makeFailedFuture(
        MagentError.invalidOptions("TCP connection timeout must be greater than zero")
      )
    }

    return ClientBootstrap(group: group)
      .connectTimeout(.milliseconds(timeout))
      .channelOption(ChannelOptions.autoRead, value: false)
      .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
      .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .channelInitializer { channel in
        channel.pipeline.addHandler(handler)
      }
      .connect(to: address)
      .flatMapErrorThrowing { error in
        if let channelError = error as? ChannelError, case .connectTimeout = channelError {
          throw MagentError.channelConnectionTimedOut
        }
        throw MagentError.channelCreationFailed(String(describing: error))
      }
  }

  /// 使用指定 EventLoopGroup 和本地 SocketAddress 绑定 UDP Channel。
  internal func createUDPClientChannel(
    group: EventLoopGroup, address: SocketAddress,
    handler: ChannelHandler & Sendable
  ) -> EventLoopFuture<Channel> {
    return DatagramBootstrap(group: group)
      .channelOption(ChannelOptions.autoRead, value: false)
      .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
      .channelOption(
        ChannelOptions.recvAllocator,
        value: FixedSizeRecvByteBufferAllocator(capacity: 65_535)
      )
      .channelInitializer { channel in
        channel.pipeline.addHandler(handler)
      }
      .bind(to: address)
      .flatMapErrorThrowing { error in
        throw MagentError.channelCreationFailed(String(describing: error))
      }
  }
}

// MARK: - MagentRouter

/// 当前 Core 生命周期内不可变的路由表；直接索引模型的解析结果，不重复验证规则。
private struct MagentRouter: Sendable {
  /// 按最后出现的位置保留规则，数组顺序就是相同优先级和具体性时的决胜顺序。
  private let rules: [ProxyRule]
  private let exactDomains: [String: Int]
  private let domainSuffixes: [String: Int]
  private let domainKeywords: [String: Int]
  private let ipRanges: [Int]

  /// 覆盖身份只包含 Match；最后一条的动作、优先级和输入位置一起生效。
  fileprivate init(_ sourceRules: [ProxyRule]) {
    var lastPositions: [ProxyRule.Match: Int] = [:]
    for (position, rule) in sourceRules.enumerated() {
      lastPositions[rule.match] = position
    }
    let retainedRules = sourceRules.enumerated()
      .filter { lastPositions[$0.element.match] == $0.offset }
      .map(\.element)
    var exactDomains: [String: Int] = [:]
    var domainSuffixes: [String: Int] = [:]
    var domainKeywords: [String: Int] = [:]
    var ipRanges: [Int] = []
    for (index, rule) in retainedRules.enumerated() {
      switch rule.match {
      case .exactDomain(let name): exactDomains[name] = index
      case .domainSuffix(let name): domainSuffixes[name] = index
      case .domainKeyword(let keyword): domainKeywords[keyword] = index
      case .ipCIDR: ipRanges.append(index)
      }
    }
    self.rules = retainedRules
    self.exactDomains = exactDomains
    self.domainSuffixes = domainSuffixes
    self.domainKeywords = domainKeywords
    self.ipRanges = ipRanges
  }

  /// 所有命中候选统一比较 order、具体性和保留位置；精确索引命中不能提前返回。
  /// 域名只取匹配视图，保留原目标根点供后续解析和 Wire 使用；IP 不执行 DNS。
  fileprivate func match(_ address: NetworkAddress) -> Decision? {
    var bestIndex: Int?
    func consider(_ candidate: Int?) {
      guard let candidate else { return }
      if let current = bestIndex, !isPreferred(candidate, over: current) { return }
      bestIndex = candidate
    }

    switch address.address {
    case .domain(let host, _):
      let name = host.hasSuffix(".") ? String(host.dropLast()) : host
      consider(exactDomains[name])
      var suffix = name[...]
      while true {
        consider(domainSuffixes[String(suffix)])
        guard let dot = suffix.firstIndex(of: ".") else { break }
        suffix = suffix[suffix.index(after: dot)...]
      }
      for (keyword, index) in domainKeywords where name.contains(keyword) {
        consider(index)
      }

    case .ip(let socket):
      let bytes: [UInt8]
      switch socket {
      case .v4(let ipv4):
        bytes = withUnsafeBytes(of: ipv4.address.sin_addr) { Array($0) }
      case .v6(let ipv6):
        bytes = withUnsafeBytes(of: ipv6.address.sin6_addr) { Array($0) }
      case .unixDomainSocket:
        preconditionFailure("NetworkAddress only stores numeric IP sockets")
      }
      for index in ipRanges {
        guard case .ipCIDR(let network, let prefixLength) = rules[index].match,
          network.count == bytes.count
        else { continue }
        let fullBytes = Int(prefixLength) / 8
        guard bytes.prefix(fullBytes).elementsEqual(network.prefix(fullBytes)) else { continue }
        let remainingBits = prefixLength % 8
        if remainingBits > 0 {
          let mask = UInt8.max << (8 - remainingBits)
          guard bytes[fullBytes] & mask == network[fullBytes] else { continue }
        }
        consider(index)
      }
    }
    return bestIndex.map { rules[$0].decision }
  }

  /// 具体性以明确类型关系及各类型自己的长度比较，不以相减或跨类型分数排序。
  private func isPreferred(_ candidate: Int, over current: Int) -> Bool {
    let lhs = rules[candidate]
    let rhs = rules[current]
    if lhs.order != rhs.order { return lhs.order < rhs.order }
    switch (lhs.match, rhs.match) {
    case (.domainSuffix(let left), .domainSuffix(let right)):
      let leftDepth = left.split(separator: ".").count
      let rightDepth = right.split(separator: ".").count
      if leftDepth != rightDepth { return leftDepth > rightDepth }
    case (.domainKeyword(let left), .domainKeyword(let right)):
      if left.utf8.count != right.utf8.count { return left.utf8.count > right.utf8.count }
    case (.ipCIDR(_, let left), .ipCIDR(_, let right)):
      if left != right { return left > right }
    case (.exactDomain, .domainSuffix), (.exactDomain, .domainKeyword),
      (.domainSuffix, .domainKeyword):
      return true
    case (.domainSuffix, .exactDomain), (.domainKeyword, .exactDomain),
      (.domainKeyword, .domainSuffix):
      return false
    default:
      // 精确同值已去重；域名与 IP 以及不同 IP 族不会成为同一目标的候选。
      break
    }
    return candidate < current
  }
}
