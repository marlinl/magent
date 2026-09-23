import NIOCore

/// 已校验且规范化的逻辑目标。域名保持未解析状态，IP 使用 NIO 的数值端点。
///
/// 构造、比较及读取 host/port 均不执行 DNS；显式转换域名端点时才委托 NIO 解析。
public struct NetworkAddress: Sendable, Hashable {
  /// Core 和 Wire 可以读取地址种类，但只有文本构造入口能写入模型。
  internal enum Address: Sendable, Hashable {
    case domain(String, port: UInt16)
    case ip(SocketAddress)
  }

  internal let address: Address

  /// 接受独立的 ASCII 主机名或 IP 文本，保留域名根点；拒绝 URL、方括号和作用域后缀。
  /// 端口允许 0，是否可作为具体操作的目标由操作入口决定；NIO 解析错误原样传播。
  public init(host: String, port: UInt16) throws {
    // 纯数字、点和十六进制分段不能回退成域名；普通标签使 0xfeed.example 仍可作为域名。
    let isIPv4Candidate =
      !host.contains(":")
      && host.lowercased()
        .split(separator: ".", omittingEmptySubsequences: false)
        .allSatisfy { part in
          if part.hasPrefix("0x") {
            return part.dropFirst(2).utf8.allSatisfy {
              (48...57).contains($0) || (97...102).contains($0)
            }
          }
          return part.utf8.allSatisfy { (48...57).contains($0) }
        }

    switch host {
    case let text where isIPv4Candidate:
      self.address = .ip(try Self.parseIPv4Text(text, port: port))
    case let text where text.contains(":"):
      self.address = .ip(try Self.parseIPv6Text(text, port: port))
    default:
      guard !host.isEmpty,
        host.utf8.allSatisfy({ (33...126).contains($0) }),
        !host.contains("["), !host.contains("]"), !host.contains("%")
      else {
        throw MagentError.invalidAddress(
          "host must be ASCII text without whitespace, brackets or scope")
      }

      let name = host.lowercased()
      let withoutRootDot = name.hasSuffix(".") ? name.dropLast() : name[...]
      guard !withoutRootDot.isEmpty, withoutRootDot.utf8.count <= 253 else {
        throw MagentError.invalidAddress("invalid hostname length")
      }
      for label in withoutRootDot.split(separator: ".", omittingEmptySubsequences: false) {
        let bytes = label.utf8
        guard !bytes.isEmpty, bytes.count <= 63, bytes.first != 45, bytes.last != 45,
          bytes.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) || $0 == 45 })
        else {
          throw MagentError.invalidAddress("invalid hostname label")
        }
      }
      self.address = .domain(name, port: port)
    }
  }

  /// 规范化域名或 NIO 生成的数值 IP 文本，不包含端口、方括号或作用域后缀。
  public var host: String {
    switch address {
    case .domain(let name, _):
      return name
    case .ip(let socket):
      guard let host = socket.ipAddress else {
        preconditionFailure("NetworkAddress only stores numeric IP sockets")
      }
      return host
    }
  }

  /// 从唯一的地址存储读取端口，不以默认值替代缺失或非法端口。
  public var port: UInt16 {
    switch address {
    case .domain(_, let port):
      return port
    case .ip(let socket):
      guard let value = socket.port, let port = UInt16(exactly: value) else {
        preconditionFailure("NetworkAddress always stores a UInt16 port")
      }
      return port
    }
  }

  /// IP 直接返回已存储的端点；域名通过 NIO 执行系统名称解析，解析错误原样传播。
  ///
  /// 域名解析是同步阻塞操作，不得在 NIO EventLoop 上调用。结果不缓存或替换逻辑域名。
  public var socketAddress: SocketAddress {
    get throws {
      switch address {
      case .ip(let socket):
        return socket
      case .domain(let host, let port):
        return try SocketAddress.makeAddressResolvingHost(host, port: Int(port))
      }
    }
  }

  /// 严格检查十进制 IPv4 文本，阻止数字歧义落入域名分支；地址字节由 NIO 解析。
  private static func parseIPv4Text(_ text: String, port: UInt16) throws -> SocketAddress {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4,
      parts.allSatisfy({ part in
        !part.isEmpty && part.count <= 3 && (part.count == 1 || part.first != "0")
          && part.utf8.allSatisfy({ (48...57).contains($0) }) && UInt8(part) != nil
      })
    else {
      throw MagentError.invalidAddress(
        "IPv4 must contain four decimal octets without leading zeroes")
    }
    return try SocketAddress(ipAddress: text, port: Int(port))
  }

  /// 交给 NIO 解析 IPv6；仅补充 IPv4 尾段的词法限制并归一映射地址。
  private static func parseIPv6Text(_ text: String, port: UInt16) throws -> SocketAddress {
    guard !text.isEmpty,
      text.utf8.allSatisfy({ (33...126).contains($0) }),
      !text.contains("["), !text.contains("]"), !text.contains("%")
    else {
      throw MagentError.invalidAddress(
        "host must be ASCII text without whitespace, brackets or scope")
    }

    let name = text.lowercased()
    if name.contains("."), let colon = name.lastIndex(of: ":") {
      _ = try Self.parseIPv4Text(String(name[name.index(after: colon)...]), port: port)
    }

    let socket = try SocketAddress(ipAddress: name, port: Int(port))
    if case .v6(let ipv6) = socket {
      // 只把 ::ffff:0:0/96 归为 IPv4；兼容 IPv6 和 NAT64 地址保持原地址族。
      return try withUnsafeBytes(of: ipv6.address.sin6_addr) { bytes in
        guard bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff
        else {
          return socket
        }
        return try SocketAddress(
          packedIPAddress: ByteBuffer(bytes: bytes.suffix(4)), port: Int(port))
      }
    }
    return socket
  }
}
