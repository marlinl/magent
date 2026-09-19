//
//  MenuBarView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Displays quick actions from the macOS menu bar.
//

import AppKit
import FactoryKit
import SwiftUI

/// macOS 菜单栏弹出内容，提供打开主窗口、关闭后台运行和退出操作。
struct MenuBarView: View {
  @Environment(\.openWindow) private var openWindow
  @InjectedObject(\.systemNetworkChangeListsner) private var systemNetworkChangeListsner
  @Binding var isMenuBarInserted: Bool

  var body: some View {
    Group {
      Label(
        systemNetworkChangeListsner.isServiceStarted ? "当前状态：已开启" : "当前状态：已关闭",
        systemImage: systemNetworkChangeListsner.isServiceStarted
          ? "checkmark.circle" : "pause.circle"
      )

      Button(systemNetworkChangeListsner.isServiceStarted ? "关闭代理服务" : "开启代理服务") {
        Task {
          await systemNetworkChangeListsner.toggleService()
        }
      }
      .disabled(systemNetworkChangeListsner.isApplying)

      if let serviceError = systemNetworkChangeListsner.serviceError {
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
  }
}
