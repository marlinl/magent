//
//  AppSettings.swift
//  MagentX
//
//  Created by MarlinL on 2026/9/17.
//

import Foundation

/// 应用代理模式，决定应用偏好中保存的默认代理行为。
enum ProxyMode: String, Sendable {
  case policy
  case global
  case direct
}

/// 应用代理偏好，使用 macOS 沙盒内 `UserDefaults` 保存代理模式和服务线程数。
struct AppSettings {
  static let defaultServiceThreadNumber = 2
  private static let proxyModeStorageKey = "app.settings.proxyMode"
  private static let serviceThreadNumberStorageKey = "app.settings.serviceThreadNumber"

  var proxyMode: ProxyMode = .direct
  var serviceThreadNumber: Int = AppSettings.defaultServiceThreadNumber

  /// 从 KV 存储读取代理模式和服务线程数，缺失字段使用当前默认值。
  static func load(userDefaults: UserDefaults = .standard) -> AppSettings {
    AppSettings(
      proxyMode: ProxyMode(
        rawValue: userDefaults.string(forKey: proxyModeStorageKey) ?? ""
      ) ?? .direct,
      serviceThreadNumber: userDefaults.object(forKey: serviceThreadNumberStorageKey) as? Int
        ?? defaultServiceThreadNumber
    )
  }

  /// 将代理模式和服务线程数写入各自的 KV 存储键。
  func save(userDefaults: UserDefaults = .standard) {
    userDefaults.set(proxyMode.rawValue, forKey: Self.proxyModeStorageKey)
    userDefaults.set(serviceThreadNumber, forKey: Self.serviceThreadNumberStorageKey)
  }
}
