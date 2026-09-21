//
//  ProxyCipher.swift
//  Magent
//
//  Created by MarlinL on 2026/6/20.
//

/// 代理节点加密方法。
public enum ProxyCipher: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
  /// AES-128-GCM。
  case aes128Gcm = "aes-128-gcm"

  /// AES-256-GCM。
  case aes256Gcm = "aes-256-gcm"

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
