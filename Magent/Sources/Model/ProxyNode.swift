//
//  ProxyNode.swift
//  Magent
//
//  Created by MarlinL on 2026/6/20.
//
import Foundation
import NIOCore

// MARK: - ProxyNodeType

/// 代理节点类型。
public enum ProxyNodeType: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
  /// Shadowsocks（AEAD）
  case shadowsocks
}

// MARK: - ProxyNode

/// 已通过本地校验的出站代理节点配置，不执行 DNS、密码派生或网络连接。
public struct ProxyNode: Identifiable, Sendable, CustomStringConvertible {
  /// 节点 UUID。
  ///
  /// `Decision.proxy(UUID)` 通过这个值引用节点；更新配置时应保留原 UUID。
  public let id: UUID

  /// 节点类型。
  public let type: ProxyNodeType

  /// 实际 IPv4 / IPv6 服务器端点，保留地址族及 IPv6 作用域。
  public let address: SocketAddress

  /// 加密方法。
  public let cipher: ProxyCipher

  /// 非空节点密码，原样保留 UTF-8 字节，不做空白清理或 Unicode 规范化。
  public let password: String

  /// 连接节点的超时时间（毫秒），可精确转换为正的 Int64 纳秒。
  public let timeoutMilliseconds: Int64

  /// 仅显示节点身份，避免默认模型描述将密码写入日志。
  public var description: String { "ProxyNode(id: \(id))" }

  /// 创建代理节点配置。
  ///
  /// - Parameters:
  ///   - id: 节点 UUID，默认自动生成。
  ///   - type: 节点类型，默认 Shadowsocks。
  ///   - address: IPv4 / IPv6 服务器端点，端口为 `1...65535`。
  ///   - cipher: 加密方法。
  ///   - password: 非空节点密码。
  ///   - timeoutMilliseconds: 连接超时（毫秒），范围为 `1...9_223_372_036_854`。
  /// - Throws: `MagentError.invalidPolicy`，表示端点、密码或超时无效。
  public init(
    id: UUID = UUID(),
    type: ProxyNodeType = .shadowsocks,
    address: SocketAddress,
    cipher: ProxyCipher,
    password: String,
    timeoutMilliseconds: Int64 = 30_000
  ) throws {
    guard let port = address.port, (1...65535).contains(port) else {
      throw MagentError.invalidPolicy(
        "proxy node address must be an IPv4 or IPv6 endpoint with port in 1...65535")
    }
    guard !password.utf8.isEmpty else {
      throw MagentError.invalidPolicy("proxy node password must not be empty")
    }
    // NIO converts milliseconds to Int64 nanoseconds; reject values that would saturate.
    guard (1...(Int64.max / 1_000_000)).contains(timeoutMilliseconds) else {
      throw MagentError.invalidPolicy(
        "proxy node timeoutMilliseconds must be in 1...9223372036854")
    }

    self.id = id
    self.type = type
    self.address = address
    self.cipher = cipher
    self.password = password
    self.timeoutMilliseconds = timeoutMilliseconds
  }
}
