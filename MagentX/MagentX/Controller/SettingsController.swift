//
//  SettingsController.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Coordinates persisted app settings with app-level UI behavior.
//

import Foundation

/// 设置业务控制器，负责默认设置记录、持久化和菜单栏后台行为同步。
@MainActor
final class SettingsController {
    /// 保存常规设置，并立即应用菜单栏入口的显示状态。
    func save(_ settings: GeneralSettings) -> GeneralSettings {
        var settings = settings
        settings.updatedAt = .now
        applyBackgroundMode(settings.enableMenuBar)
        settings.save()
        applyProxyConfigurationIfNeeded()
        return settings
    }

    /// 设置是否启用菜单栏后台运行，并持久化到默认常规设置。
    func setMenuBarEnabled(_ isEnabled: Bool) -> GeneralSettings {
        var settings = GeneralSettings.load()
        settings.enableMenuBar = isEnabled
        return save(settings)
    }

    private func applyBackgroundMode(_ isEnabled: Bool) {
        // 菜单栏入口开启时，关闭最后一个窗口后继续保留后台进程。
        MagentXAppDelegate.applyBackgroundPreference(isEnabled)
    }

    private func applyProxyConfigurationIfNeeded() {
        guard CurrentSelection.load().state == .start else { return }
        Task { @MainActor in
            do {
                try await SystemNetworkProxyService.shared.applyStoredConfiguration()
            } catch {
                MagentXLogger.error(
                    error,
                    category: .systemProxy,
                    message: "Failed to reapply proxy configuration after settings change"
                )
            }
        }
    }
}
