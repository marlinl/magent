//
//  GeneralSettingsTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Unit tests for persisted general app settings.
//

import Foundation
import Testing
@testable import MagentX

/// `GeneralSettings` 的 UserDefaults 持久化行为测试。
struct GeneralSettingsTests {
    /// 验证缺失持久化字段时代理线程数使用默认值 2。
    @Test func loadUsesDefaultProxyThreadNumber() {
        let suiteName = "GeneralSettingsTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let settings = GeneralSettings.load(userDefaults: userDefaults)

        #expect(settings.proxyThreadNumber == 2)
    }

    /// 验证代理线程数会随常规设置保存并重新读取。
    @Test func savePersistsProxyThreadNumber() {
        let suiteName = "GeneralSettingsTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let settings = GeneralSettings(proxyThreadNumber: 4)

        settings.save(userDefaults: userDefaults)
        let loadedSettings = GeneralSettings.load(userDefaults: userDefaults)

        #expect(loadedSettings.proxyThreadNumber == 4)
    }

    /// 验证规则订阅地址在未保存设置时默认使用 GFWList 官方地址。
    @Test func loadUsesDefaultRulesURL() {
        let suiteName = "GeneralSettingsTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let settings = GeneralSettings.load(userDefaults: userDefaults)

        #expect(settings.rulesURL == "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt")
    }

}
