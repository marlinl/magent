//
//  GeneralSettingsTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Unit tests for persisted app configuration.
//

import Foundation
import Testing

@testable import MagentX

/// `GeneralSettings` 与 `AppSettings` 的 UserDefaults 持久化行为测试。
@MainActor
struct GeneralSettingsTests {
  /// 验证未保存代理模式时默认使用直连模式。
  @Test func loadUsesDefaultProxyMode() {
    let suiteName = "GeneralSettingsTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    defer {
      userDefaults.removePersistentDomain(forName: suiteName)
    }

    let settings = AppSettings.load(userDefaults: userDefaults)

    #expect(settings.proxyMode == .direct)
  }

  /// 验证代理模式会随应用设置保存并重新读取。
  @Test func savePersistsProxyMode() {
    let suiteName = "GeneralSettingsTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    defer {
      userDefaults.removePersistentDomain(forName: suiteName)
    }
    let settings = AppSettings(proxyMode: .global)

    settings.save(userDefaults: userDefaults)
    let loadedSettings = AppSettings.load(userDefaults: userDefaults)

    #expect(loadedSettings.proxyMode == .global)
  }

  /// 验证无法识别的持久化代理模式不会破坏设置加载。
  @Test func loadUsesDefaultProxyModeForUnknownStoredValue() {
    let suiteName = "GeneralSettingsTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    defer {
      userDefaults.removePersistentDomain(forName: suiteName)
    }
    userDefaults.set("unsupported", forKey: "app.settings.proxyMode")

    let settings = AppSettings.load(userDefaults: userDefaults)

    #expect(settings.proxyMode == .direct)
  }

  /// 验证缺失持久化字段时服务线程数使用默认值 2。
  @Test func loadUsesDefaultServiceThreadNumber() {
    let suiteName = "GeneralSettingsTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    defer {
      userDefaults.removePersistentDomain(forName: suiteName)
    }

    let settings = AppSettings.load(userDefaults: userDefaults)

    #expect(settings.serviceThreadNumber == 2)
  }

  /// 验证服务线程数会随应用设置保存并重新读取。
  @Test func savePersistsServiceThreadNumber() {
    let suiteName = "GeneralSettingsTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    defer {
      userDefaults.removePersistentDomain(forName: suiteName)
    }
    let settings = AppSettings(serviceThreadNumber: 4)

    settings.save(userDefaults: userDefaults)
    let loadedSettings = AppSettings.load(userDefaults: userDefaults)

    #expect(loadedSettings.serviceThreadNumber == 4)
  }

  /// 验证规则订阅地址在未保存设置时默认使用 GFWList 官方地址。
  @Test func loadUsesDefaultRulesURL() {
    let suiteName = "GeneralSettingsTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    defer {
      userDefaults.removePersistentDomain(forName: suiteName)
    }

    let settings = GeneralSettings.load(userDefaults: userDefaults)

    #expect(
      settings.rulesURL == "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt")
  }

}
