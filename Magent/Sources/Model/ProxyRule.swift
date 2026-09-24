import Foundation
import NIOCore

/// 已校验且规范化的路由规则；构造只解析匹配条件，不查询节点、DNS 或创建 Wire。
public struct ProxyRule: Sendable, Hashable {
  /// 唯一的匹配存储，同时作为 Core 的覆盖键；CIDR 在构造时清零主机位。
  internal enum Match: Sendable, Hashable {
    case exactDomain(String)
    case domainSuffix(String)
    case domainKeyword(String)
    case ipCIDR(network: [UInt8], prefixLength: UInt8)
  }

  internal let match: Match

  /// 命中后的动作；代理节点是否存在由 Core 在实际路由时检查。
  public let decision: Decision

  /// 数值越小越优先，允许完整 Int 范围。
  public let order: Int

  /// 从已校验的匹配存储读取配置类型。
  public var matchType: MatchType {
    switch match {
    case .exactDomain: return .exactDomain
    case .domainSuffix: return .domainSuffix
    case .domainKeyword: return .domainKeyword
    case .ipCIDR: return .ipCIDR
    }
  }

  /// 规范化配置文本；CIDR 由网络字节生成，不保留另一份文本状态。
  public var matchValue: String {
    switch match {
    case .exactDomain(let value), .domainSuffix(let value), .domainKeyword(let value):
      return value
    case .ipCIDR(let network, let prefixLength):
      // 唯一构造入口保证网络恰好为 4 或 16 字节，NIO 只负责数值格式化。
      guard let socket = try? SocketAddress(packedIPAddress: ByteBuffer(bytes: network), port: 0),
        let host = socket.ipAddress
      else { preconditionFailure("ProxyRule stores only validated IP networks") }
      return "\(host)/\(prefixLength)"
    }
  }

  /// 解析严格的匹配文本；不修剪空白、前导点或多余根点。
  ///
  /// - Throws: `MagentError.invalidPolicy`，匹配文本不满足对应类型的语法或范围约束。
  public init(matchType: MatchType, matchValue: String, decision: Decision, order: Int) throws {
    switch matchType {
    case .exactDomain, .domainSuffix:
      if matchType == .exactDomain,
        NetworkAddress.isIPv4Candidate(matchValue) || matchValue.contains(":")
      {
        throw MagentError.invalidPolicy("numeric exact domain must use IP-CIDR: \(matchValue)")
      }
      guard let domain = NetworkAddress.normalizedDomainName(matchValue) else {
        throw MagentError.invalidPolicy("invalid domain: \(matchValue)")
      }
      let name = domain.hasSuffix(".") ? String(domain.dropLast()) : domain
      match = matchType == .exactDomain ? .exactDomain(name) : .domainSuffix(name)

    case .domainKeyword:
      guard (1...253).contains(matchValue.utf8.count),
        matchValue.utf8.allSatisfy({
          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            || $0 == 45 || $0 == 46
        })
      else {
        throw MagentError.invalidPolicy("invalid domain keyword: \(matchValue)")
      }
      match = .domainKeyword(matchValue.lowercased())

    case .ipCIDR:
      match = try Self.parseCIDR(matchValue)
    }
    self.decision = decision
    self.order = order
  }

  /// 保留输入 IP 的位宽校验前缀，随后把映射 IPv6 归入 IPv4 并清零主机位。
  /// 这里的 NIO 解析只接受数值字面量，失败由拥有规则输入的边界报告为 invalidPolicy。
  private static func parseCIDR(_ value: String) throws -> Match {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count) else {
      throw MagentError.invalidPolicy("invalid CIDR: \(value)")
    }
    let host = String(parts[0])
    guard NetworkAddress.isValidHostText(host) else {
      throw MagentError.invalidPolicy("invalid CIDR address: \(value)")
    }
    if host.contains(":") {
      if host.contains("."), let colon = host.lastIndex(of: ":"),
        !NetworkAddress.isValidIPv4Text(String(host[host.index(after: colon)...]))
      {
        throw MagentError.invalidPolicy("invalid CIDR address: \(value)")
      }
    } else if !NetworkAddress.isValidIPv4Text(host) {
      throw MagentError.invalidPolicy("invalid CIDR address: \(value)")
    }
    guard let socket = try? SocketAddress(ipAddress: host, port: 0) else {
      throw MagentError.invalidPolicy("invalid CIDR address: \(value)")
    }
    var network: [UInt8]
    switch socket {
    case .v4(let ipv4):
      network = withUnsafeBytes(of: ipv4.address.sin_addr) { Array($0) }
    case .v6(let ipv6):
      network = withUnsafeBytes(of: ipv6.address.sin6_addr) { Array($0) }
    case .unixDomainSocket:
      preconditionFailure("numeric IP parser cannot produce a Unix socket")
    }
    var prefixLength = network.count * 8
    if parts.count == 2 {
      guard !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
        let prefix = Int(parts[1]), (0...prefixLength).contains(prefix)
      else { throw MagentError.invalidPolicy("invalid CIDR prefix: \(value)") }
      prefixLength = prefix
    }
    if network.count == 16, network.prefix(10).allSatisfy({ $0 == 0 }),
      network[10] == 0xff, network[11] == 0xff
    {
      guard prefixLength >= 96 else {
        throw MagentError.invalidPolicy("mapped IPv6 CIDR prefix must be in 96...128: \(value)")
      }
      network = Array(network.suffix(4))
      prefixLength -= 96
    }
    for index in network.indices {
      let retainedBits = prefixLength - index * 8
      if retainedBits <= 0 {
        network[index] = 0
      } else if retainedBits < 8 {
        network[index] &= UInt8.max << UInt8(8 - retainedBits)
      }
    }
    return .ipCIDR(network: network, prefixLength: UInt8(prefixLength))
  }
}
