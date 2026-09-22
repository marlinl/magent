//
//  NetworkAddress.swift
//  Magent
//
//  Created by MarlinL on 2026/6/20.
//
import Foundation
import NIOCore

/// SOCKS 协议端口字段使用 network byte order，即 big-endian。
extension UInt16 {
  var bigEndianBytes: Data {
    var value = self.bigEndian
    return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
  }
}

/// 读取 SOCKS 地址中的 2 字节网络序端口；调用方先完成边界检查。
extension Data {
  func readBigEndianUInt16(at offset: Int) -> UInt16 {
    guard offset >= 0, offset + 2 <= count else { return 0 }
    return UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
  }
}

// MARK: - NetworkAddress

/// 网络地址。
///
/// 这是 Transport、Core、Wire 共享的地址表示，不属于 HTTP/SOCKS，
/// 也不属于某个具体节点协议。出站请求和 UDP 入站响应都可以携带它。
public enum NetworkAddress: Sendable, Equatable, Hashable, Codable {
  /// IPv4 地址。
  ///
  /// `Data` 必须是 4 字节，`port` 通常使用 `1...65535`；绑定时 `0` 表示由系统分配端口。
  case ipv4(Data, port: Int)

  /// IPv6 地址。
  ///
  /// `Data` 必须是 16 字节，`port` 使用普通网络端口范围 `1...65535`。
  case ipv6(Data, port: Int)

  /// 域名地址。
  ///
  /// 具体节点协议决定是否远端解析域名。
  case domain(String, port: Int)

  /// IPv4 未指定地址和系统分配端口，用于绑定 `0.0.0.0:0`。
  public static let unspecifiedIPv4 = Self.ipv4(Data(repeating: 0, count: 4), port: 0)

  /// 可展示或用于建立连接的 host 字符串。
  public var host: String {
    switch self {
    case .ipv4(let data, _):
      return data.map(String.init).joined(separator: ".")

    case .ipv6(let data, _):
      guard data.count == 16 else { return "" }
      return stride(from: 0, to: 16, by: 2)
        .map { index in
          let high = UInt16(data[index]) << 8
          let low = UInt16(data[index + 1])
          return String(format: "%x", high | low)
        }
        .joined(separator: ":")

    case .domain(let host, _):
      return host
    }
  }

  /// 网络端口。
  public var port: Int {
    switch self {
    case .ipv4(_, let port),
      .ipv6(_, let port),
      .domain(_, let port):
      return port
    }
  }

  /// 纯语法规范化；在目标路由、转发和 IP 比较前使用，不执行 DNS。
  ///
  /// mapped IPv6 和严格 dotted-quad 使用同一种 IPv4 表示，避免绕过 CIDR。
  /// 域名只接受 ASCII 主机名语法并小写化；显式根点保留给转发层。
  /// 这里只检查 A-label 的 ASCII 外形，完整 IDNA 有效性仍由独立校验负责。
  internal func normalized() throws -> NetworkAddress {
    switch self {
    case .ipv4(let bytes, _):
      guard bytes.count == 4 else {
        throw MagentError.invalidAddress("IPv4 address must contain 4 bytes")
      }
      return self

    case .ipv6(let bytes, let port):
      guard bytes.count == 16 else {
        throw MagentError.invalidAddress("IPv6 address must contain 16 bytes")
      }
      if bytes.prefix(12) == Data(repeating: 0, count: 10) + Data([0xFF, 0xFF]) {
        return .ipv4(Data(bytes.suffix(4)), port: port)
      }
      return self

    case .domain(let host, let port):
      guard !host.isEmpty, host.utf8.allSatisfy({ $0 < 128 }) else {
        throw MagentError.invalidAddress("domain must be an ASCII hostname")
      }
      let name = host.lowercased()
      let parts = name.split(separator: ".", omittingEmptySubsequences: false)
      // Decimal/dotted and inet_aton-style hexadecimal components must never reach
      // a permissive resolver. A name such as 0xfeed.example remains a hostname.
      let numeric = parts.allSatisfy { part in
        if part.hasPrefix("0x") {
          return part.dropFirst(2).utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
          }
        }
        return part.utf8.allSatisfy { (48...57).contains($0) }
      }
      if numeric {
        guard parts.count == 4 else {
          throw MagentError.invalidAddress("invalid IPv4 domain expression")
        }
        var bytes = Data()
        for part in parts {
          guard !part.isEmpty, part.count <= 3,
            part.count == 1 || part.first != "0",
            part.utf8.allSatisfy({ (48...57).contains($0) }), let byte = UInt8(part)
          else {
            throw MagentError.invalidAddress("invalid IPv4 domain expression")
          }
          bytes.append(byte)
        }
        return .ipv4(bytes, port: port)
      }

      let matchName = name.hasSuffix(".") ? String(name.dropLast()) : name
      guard !matchName.isEmpty, matchName.utf8.count <= 253 else {
        throw MagentError.invalidAddress("invalid hostname length")
      }
      for label in matchName.split(separator: ".", omittingEmptySubsequences: false) {
        let bytes = label.utf8
        guard !bytes.isEmpty, bytes.count <= 63, bytes.first != 45, bytes.last != 45,
          bytes.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 })
        else {
          throw MagentError.invalidAddress("invalid hostname label")
        }
      }
      return .domain(name, port: port)
    }
  }

  /// 已规范化地址的匹配视图；只去掉域名的单个根点，不裁剪空白或前导点。
  /// 路由和缓存共享此视图，而 Wire/DNS 继续使用保留显式根点的 `host`。
  internal var hostForMatching: String {
    if case .domain(let name, _) = self, name.hasSuffix(".") {
      return String(name.dropLast())
    }
    return host
  }

  /// 从 NIO `SocketAddress` 构造。
  ///
  /// `SocketAddress.IPv4Address.address` 是 `sockaddr_in`，IP 在 `.sin_addr`；IPv6 在
  /// `sockaddr_in6.sin6_addr`。两者在内存里都是网络序字节，`withUnsafeBytes` 直接取
  /// 原始字节，不依赖宿主机字节序。端口取 `SocketAddress.port`（`Int?`）。
  /// unix domain socket 没有 IP 表示，返回 nil。
  internal init?(_ address: SocketAddress) {
    let port = address.port ?? 0
    switch address {
    case .v4(let ipv4):
      let bytes = withUnsafeBytes(of: ipv4.address.sin_addr) { Data($0) }
      self = .ipv4(bytes, port: port)

    case .v6(let ipv6):
      let bytes = withUnsafeBytes(of: ipv6.address.sin6_addr) { Data($0) }
      self = .ipv6(bytes, port: port)

    case .unixDomainSocket:
      return nil
    }
  }

  /// 构造 NIO 可写入的 socket address。
  internal func socketAddress() throws -> SocketAddress {
    switch self {
    case .ipv4, .ipv6:
      return try SocketAddress(ipAddress: host, port: port)
    case .domain(let host, let port):
      return try SocketAddress.makeAddressResolvingHost(host, port: port)
    }
  }
}
