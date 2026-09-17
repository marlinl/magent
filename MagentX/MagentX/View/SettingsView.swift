//
//  SettingsView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Displays global app settings.
//

import FactoryKit
import Foundation
import OSLog
import SwiftUI

/// 应用设置页面，展示并保存常规设置、本地代理监听和规则订阅配置。
struct SettingsView: View {
  @Injected(\.launchAtLoginService) private var launchAtLoginService
  @Binding var toolbarButtons: [ContentToolbarButton]
  @Binding var isMenuBarInserted: Bool
  @State private var generalSettings = GeneralSettings.load()
  @State private var launchAtLoginError: String?

  private static let portFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .none
    formatter.allowsFloats = false
    formatter.minimum = 1
    formatter.maximum = 65_535
    return formatter
  }()
  private static let positiveIntegerFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .none
    formatter.allowsFloats = false
    formatter.minimum = 1
    return formatter
  }()

  var body: some View {
    Form {
      Section("常规") {
        Toggle(
          "开机启动",
          isOn: Binding(
            get: { generalSettings.launchAtLogin },
            set: { isEnabled in
              do {
                try launchAtLoginService.setEnabled(isEnabled)
                generalSettings.launchAtLogin = isEnabled
                generalSettings.save()
              } catch {
                AppLog.app.error(
                  "Failed to update launch at login: \(error.localizedDescription, privacy: .public)"
                )
                launchAtLoginError = error.localizedDescription
              }
            }
          )
        )
        Toggle("启用菜单栏", isOn: $generalSettings.enableMenuBar)
      }

      Section("同步") {
        Toggle("启用 iCloud 同步", isOn: $generalSettings.iCloudSyncEnabled)
      }

      Section("规则订阅") {
        TextField("规则订阅 URL", text: $generalSettings.rulesURL)
      }

      Section("代理服务") {
        TextField("代理服务地址", text: $generalSettings.proxyListenAddress)
        TextField(
          "代理服务端口",
          value: $generalSettings.proxyListenPort,
          formatter: Self.portFormatter
        )
        TextField(
          "代理线程数",
          value: $generalSettings.proxyThreadNumber,
          formatter: Self.positiveIntegerFormatter
        )
      }

      Section("PAC") {
        TextField("PAC 地址", text: $generalSettings.pacListenAddress)
        TextField(
          "PAC 端口",
          value: $generalSettings.pacListenPort,
          formatter: Self.portFormatter
        )
      }
    }
    .formStyle(.grouped)
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onAppear {
      toolbarButtons = []
      generalSettings = GeneralSettings.load()
      if generalSettings.launchAtLogin != launchAtLoginService.isEnabled {
        generalSettings.launchAtLogin = launchAtLoginService.isEnabled
        generalSettings.save()
      }
      isMenuBarInserted = generalSettings.enableMenuBar
    }
    .onChange(of: generalSettings.enableMenuBar) { _, isEnabled in
      generalSettings.save()
      isMenuBarInserted = isEnabled
    }
    .onChange(of: generalSettings.iCloudSyncEnabled) { _, _ in
      generalSettings.save()
    }
    .onChange(of: generalSettings.rulesURL) { _, _ in
      generalSettings.save()
    }
    .onChange(of: generalSettings.proxyListenAddress) { _, _ in
      generalSettings.save()
    }
    .onChange(of: generalSettings.proxyListenPort) { _, _ in
      generalSettings.save()
    }
    .onChange(of: generalSettings.proxyThreadNumber) { _, _ in
      generalSettings.save()
    }
    .onChange(of: generalSettings.pacListenAddress) { _, _ in
      generalSettings.save()
    }
    .onChange(of: generalSettings.pacListenPort) { _, _ in
      generalSettings.save()
    }
    .alert(
      "无法更新开机启动",
      isPresented: Binding(
        get: { launchAtLoginError != nil },
        set: { isPresented in
          if isPresented == false {
            launchAtLoginError = nil
          }
        }
      )
    ) {
      Button("好", role: .cancel) {}
    } message: {
      Text(launchAtLoginError ?? "")
    }
  }
}
