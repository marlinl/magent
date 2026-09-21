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

/// 代理节点配置（SS server 等 backend 的连接参数）。
public struct ProxyNode: Hashable, Identifiable, Sendable {
  /// 节点 UUID。
  ///
  /// `AccessControlPolicy.decision` 的 `.proxy(UUID)` 通过这个值引用节点。
  public let id: UUID

  /// 节点类型。
  public let type: ProxyNodeType

  /// 已解析的服务器 socket 地址和端口。
  public let address: SocketAddress

  /// 加密方法。
  public let cipher: ProxyCipher

  /// 节点密码。
  public let password: String

  /// 超时时间（秒）。
  public let timeout: TimeInterval

  /// 创建代理节点配置。
  ///
  /// - Parameters:
  ///   - id: 节点 UUID，默认自动生成。
  ///   - type: 节点类型，默认 Shadowsocks。
  ///   - address: 服务器地址和端口。
  ///   - cipher: 加密方法。
  ///   - password: 节点密码。
  ///   - timeout: 超时时间（秒）。
  public init(
    id: UUID = UUID(),
    type: ProxyNodeType = .shadowsocks,
    address: SocketAddress,
    cipher: ProxyCipher,
    password: String,
    timeout: TimeInterval = 30
  ) {
    self.id = id
    self.type = type
    self.address = address
    self.cipher = cipher
    self.password = password
    self.timeout = timeout
  }
}
