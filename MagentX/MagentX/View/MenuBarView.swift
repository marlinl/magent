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
    @StateObject private var serviceController = MagentServiceController()

    private var currentState: BackgroundServiceState {
        serviceController.currentSelection.state
    }

    var body: some View {
        Group {
            Label(
                currentState == .start ? "当前状态：已开启" : "当前状态：已关闭",
                systemImage: currentState == .start ? "checkmark.circle" : "pause.circle"
            )

            Button(currentState == .start ? "关闭代理服务" : "开启代理服务") {
                Task {
                    await serviceController.toggleService()
                }
            }
            .disabled(serviceController.isApplying)

            if let serviceError = serviceController.serviceError {
                Text(serviceError)
            }

            Divider()

            Button("打开 MagentX") {
                MagentXAppDelegate.prepareMainWindowPresentation()
                openWindow(id: MagentXApp.mainWindowID)
            }

            Divider()

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
        .onAppear {
            serviceController.reloadCurrentSelection()
            Task {
                await serviceController.applyStoredConfigurationIfNeeded()
            }
        }
    }
}
