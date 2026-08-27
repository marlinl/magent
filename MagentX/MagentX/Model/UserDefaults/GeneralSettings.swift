//
//  GeneralSettings.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Persisted global app preferences for startup, proxy listening, menu bar, iCloud sync, and rule refresh options.
//

import Foundation

/// 单记录常规偏好，使用 macOS 沙盒内 `UserDefaults` 作为 KV 存储。
struct GeneralSettings {
    static let localhostAddress = "127.0.0.1"
    static let defaultProxyListenPort = 1086
    static let defaultPacListenPort = 10080
    static let defaultProxyThreadNumber = 2
    static let defaultPublicSuffixListURL = "https://publicsuffix.org/list/public_suffix_list.dat"

    var launchAtLogin: Bool = false
    var enableMenuBar: Bool = true
    var iCloudSyncEnabled: Bool = false
    var rulesURL: String = ""
    var publicSuffixListURL: String = GeneralSettings.defaultPublicSuffixListURL
    var proxyListenAddress: String = GeneralSettings.localhostAddress
    var proxyListenPort: Int = GeneralSettings.defaultProxyListenPort
    var proxyThreadNumber: Int = GeneralSettings.defaultProxyThreadNumber
    var pacListenAddress: String = GeneralSettings.localhostAddress
    var pacListenPort: Int = GeneralSettings.defaultPacListenPort
    var updatedAt: Date = Date.now

    /// 创建默认或自定义的全局设置记录。
    init(
        launchAtLogin: Bool = false,
        enableMenuBar: Bool = true,
        iCloudSyncEnabled: Bool = false,
        rulesURL: String = "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt",
        publicSuffixListURL: String = GeneralSettings.defaultPublicSuffixListURL,
        proxyListenAddress: String = GeneralSettings.localhostAddress,
        proxyListenPort: Int = GeneralSettings.defaultProxyListenPort,
        proxyThreadNumber: Int = GeneralSettings.defaultProxyThreadNumber,
        pacListenAddress: String = GeneralSettings.localhostAddress,
        pacListenPort: Int = GeneralSettings.defaultPacListenPort,
        updatedAt: Date = .now
    ) {
        self.launchAtLogin = launchAtLogin
        self.enableMenuBar = enableMenuBar
        self.iCloudSyncEnabled = iCloudSyncEnabled
        self.rulesURL = rulesURL
        self.publicSuffixListURL = publicSuffixListURL
        self.proxyListenAddress = proxyListenAddress
        self.proxyListenPort = proxyListenPort
        self.proxyThreadNumber = proxyThreadNumber
        self.pacListenAddress = pacListenAddress
        self.pacListenPort = pacListenPort
        self.updatedAt = updatedAt
    }

    /// 从 KV 存储读取常规设置，缺失字段使用当前默认值。
    static func load(userDefaults: UserDefaults = .standard) -> GeneralSettings {
        GeneralSettings(
            launchAtLogin: userDefaults.object(forKey: "general.launchAtLogin") as? Bool ?? false,
            enableMenuBar: userDefaults.object(forKey: "general.enableMenuBar") as? Bool ?? true,
            iCloudSyncEnabled: userDefaults.object(forKey: "general.iCloudSyncEnabled") as? Bool ?? false,
            rulesURL: userDefaults.string(forKey: "general.rulesURL") ?? "",
            publicSuffixListURL: userDefaults.string(forKey: "general.publicSuffixListURL") ?? defaultPublicSuffixListURL,
            proxyListenAddress: userDefaults.string(forKey: "general.proxyListenAddress") ?? localhostAddress,
            proxyListenPort: userDefaults.object(forKey: "general.proxyListenPort") as? Int ?? defaultProxyListenPort,
            proxyThreadNumber: userDefaults.object(forKey: "general.proxyThreadNumber") as? Int ?? defaultProxyThreadNumber,
            pacListenAddress: userDefaults.string(forKey: "general.pacListenAddress") ?? localhostAddress,
            pacListenPort: userDefaults.object(forKey: "general.pacListenPort") as? Int ?? defaultPacListenPort,
            updatedAt: userDefaults.object(forKey: "general.updatedAt") as? Date ?? .now
        )
    }

    /// 写入 KV 存储；新增字段只需增加新的 key，不需要迁移 SQLite schema。
    func save(userDefaults: UserDefaults = .standard) {
        userDefaults.set(launchAtLogin, forKey: "general.launchAtLogin")
        userDefaults.set(enableMenuBar, forKey: "general.enableMenuBar")
        userDefaults.set(iCloudSyncEnabled, forKey: "general.iCloudSyncEnabled")
        userDefaults.set(rulesURL, forKey: "general.rulesURL")
        userDefaults.set(publicSuffixListURL, forKey: "general.publicSuffixListURL")
        userDefaults.set(proxyListenAddress, forKey: "general.proxyListenAddress")
        userDefaults.set(proxyListenPort, forKey: "general.proxyListenPort")
        userDefaults.set(proxyThreadNumber, forKey: "general.proxyThreadNumber")
        userDefaults.set(pacListenAddress, forKey: "general.pacListenAddress")
        userDefaults.set(pacListenPort, forKey: "general.pacListenPort")
        userDefaults.set(updatedAt, forKey: "general.updatedAt")
    }
}
