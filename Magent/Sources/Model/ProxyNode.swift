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

// MARK: - ProxyCipher

/// 代理节点加密方法。
public enum ProxyCipher: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// AES-128-GCM。
    case aes128Gcm            = "aes-128-gcm"

    /// AES-256-GCM。
    case aes256Gcm            = "aes-256-gcm"

    /// ChaCha20-IETF-Poly1305。
    case chacha20IetfPoly1305 = "chacha20-ietf-poly1305"

    /// XChaCha20-IETF-Poly1305。
    case xchacha20IetfPoly1305 = "xchacha20-ietf-poly1305"

    /// 主密钥长度（字节）。
    public var keySize: Int {
        switch self {
        case .aes128Gcm: return 16
        case .aes256Gcm, .chacha20IetfPoly1305, .xchacha20IetfPoly1305: return 32
        }
    }

    /// 盐长度（字节），等于 `keySize`。
    public var saltSize: Int { keySize }

    /// Nonce 长度（字节）。
    public var nonceSize: Int {
        switch self {
        case .aes128Gcm, .aes256Gcm, .chacha20IetfPoly1305: return 12
        case .xchacha20IetfPoly1305: return 24
        }
    }

    /// 认证 tag 长度（字节），固定为 16。
    public var tagSize: Int { 16 }
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
