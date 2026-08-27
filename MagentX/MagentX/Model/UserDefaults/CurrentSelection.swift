//
//  CurrentSelection.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Persisted current selection configuration.
//

import Foundation

/// 后台代理服务开关状态。
enum BackgroundServiceState: String, Codable, CaseIterable, Identifiable, Sendable {
    case start
    case stop

    /// SwiftUI 列表和选择器使用的稳定身份。
    var id: String { rawValue }
}

/// 系统代理接管模式。
enum SystemProxyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case pac
    case global
    case tunnel

    /// SwiftUI 列表和选择器使用的稳定身份。
    var id: String { rawValue }
}

/// 当前后台代理服务配置。
///
/// KV 模型，只保存服务开关状态和系统代理模式。
struct CurrentSelection {
    static let stateStorageKey = "currentSelection.state"

    var state: BackgroundServiceState = BackgroundServiceState.stop
    var mode: SystemProxyMode = SystemProxyMode.pac

    /// 创建当前选择状态记录。
    init(
        state: BackgroundServiceState = BackgroundServiceState.stop,
        mode: SystemProxyMode = SystemProxyMode.pac
    ) {
        self.state = state
        self.mode = mode
    }

    /// 从 KV 存储读取当前选择，缺失字段使用默认关闭和 PAC 模式。
    static func load(userDefaults: UserDefaults = .standard) -> CurrentSelection {
        CurrentSelection(
            state: BackgroundServiceState(rawValue: userDefaults.string(forKey: stateStorageKey) ?? "") ?? .stop,
            mode: SystemProxyMode(rawValue: userDefaults.string(forKey: "currentSelection.mode") ?? "") ?? .pac
        )
    }

    /// 写入 KV 存储；新增字段只需增加新的 key，不需要迁移 SQLite schema。
    func save(userDefaults: UserDefaults = .standard) {
        userDefaults.set(state.rawValue, forKey: Self.stateStorageKey)
        userDefaults.set(mode.rawValue, forKey: "currentSelection.mode")
    }
}
