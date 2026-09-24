//
//  Decision.swift
//  Magent
//
//  Created by MarlinL on 2026/6/20.
//
import Foundation

/// 代理规则命中后的动作。
public enum Decision: Sendable, Hashable {
  /// 使用指定 UUID 的代理节点。
  case proxy(UUID)

  /// 直连目标地址。
  case direct
}
