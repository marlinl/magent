//
//  MenuBarView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Displays quick actions from the macOS menu bar.
//

import AppKit
import SwiftUI

/// macOS 菜单栏弹出内容，提供打开主窗口、关闭后台运行和退出操作。
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Binding var isMenuBarInserted: Bool
    @ObservedObject private var systemNetworkProxyService = SystemNetworkProxyService.shared

    var body: some View {
        Group {
            Label(
                systemNetworkProxyService.isServiceStarted ? "当前状态：已开启" : "当前状态：已关闭",
                systemImage: systemNetworkProxyService.isServiceStarted ? "checkmark.circle" : "pause.circle"
            )

            Button(systemNetworkProxyService.isServiceStarted ? "关闭代理服务" : "开启代理服务") {
                Task {
                    await systemNetworkProxyService.toggleService()
                }
            }
            .disabled(systemNetworkProxyService.isApplying)

            if let serviceError = systemNetworkProxyService.serviceError {
                Text(serviceError)
            }

            Divider()

            Button("打开 MagentX") {
                openWindow(id: MagentXApp.mainWindowID)
            }

            Divider()

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
        .onAppear {
            systemNetworkProxyService.reloadCurrentSelection()
            Task {
                await systemNetworkProxyService.applyStoredConfigurationIfNeeded()
            }
        }
    }
}
