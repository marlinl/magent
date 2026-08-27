//
//  MagentServiceController.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Coordinates proxy service lifecycle actions for shared UI entry points.
//

import Combine
import Foundation

/// 代理服务生命周期控制器，统一处理后台服务状态切换、持久化和系统代理应用。
@MainActor
final class MagentServiceController: ObservableObject {
    @Published private(set) var currentSelection: CurrentSelection
    @Published private(set) var serviceError: String?
    @Published private(set) var isApplying = false

    private let systemNetworkProxyService: SystemNetworkProxyService

    /// 创建代理服务生命周期控制器，并读取持久化的当前服务选择。
    init() {
        self.currentSelection = CurrentSelection.load()
        self.systemNetworkProxyService = SystemNetworkProxyService.shared
    }

    var isServiceStarted: Bool {
        currentSelection.state == .start
    }

    /// 从 KV 存储重新读取当前服务选择。
    func reloadCurrentSelection() {
        currentSelection = CurrentSelection.load()
    }

    /// 按持久化状态恢复已开启的代理服务；关闭状态不会修改本地监听或系统代理。
    func applyStoredConfigurationIfNeeded() async {
        reloadCurrentSelection()
        guard currentSelection.state == .start else { return }
        guard isApplying == false else { return }

        isApplying = true
        defer { isApplying = false }

        do {
            try await systemNetworkProxyService.applyStoredConfiguration()
            serviceError = nil
            reloadCurrentSelection()
        } catch {
            MagentXLogger.error(
                error,
                category: .service,
                message: "Failed to apply stored proxy service configuration",
                metadata: [
                    "state": currentSelection.state.rawValue,
                    "mode": currentSelection.mode.rawValue
                ]
            )
            serviceError = error.localizedDescription
        }
    }

    /// 启动代理服务，并在成功后把当前选择状态持久化为 `start`。
    func startService() async {
        await applyServiceState(.start)
    }

    /// 停止代理服务，并在成功后把当前选择状态持久化为 `stop`。
    func stopService() async {
        await applyServiceState(.stop)
    }

    /// 在 `start` 和 `stop` 之间切换代理服务状态。
    func toggleService() async {
        await applyServiceState(isServiceStarted ? .stop : .start)
    }

    /// 清除最近一次服务状态切换产生的错误提示。
    func clearServiceError() {
        serviceError = nil
    }

    private func applyServiceState(_ state: BackgroundServiceState) async {
        guard isApplying == false else { return }

        isApplying = true
        defer { isApplying = false }

        var nextSelection = CurrentSelection.load()
        nextSelection.state = state

        do {
            try await systemNetworkProxyService.apply(
                currentSelection: nextSelection,
                generalSettings: GeneralSettings.load()
            )
            nextSelection.save()
            currentSelection = nextSelection
            serviceError = nil
        } catch {
            currentSelection = CurrentSelection.load()
            MagentXLogger.error(
                error,
                category: .service,
                message: "Failed to apply proxy service state",
                metadata: [
                    "requestedState": state.rawValue,
                    "currentState": currentSelection.state.rawValue,
                    "mode": currentSelection.mode.rawValue
                ]
            )
            serviceError = error.localizedDescription
        }
    }
}
