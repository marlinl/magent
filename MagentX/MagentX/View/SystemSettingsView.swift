//
//  SystemSettingsView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Displays global app settings.
//

import SwiftUI

/// 系统设置页面，展示并保存常规设置、本地代理监听和规则订阅配置。
struct SystemSettingsView: View {
    @Binding var toolbarButtons: [ContentToolbarButton]
    @Binding var isMenuBarInserted: Bool
    @State private var generalSettings = GeneralSettings.load()
    private let settingsController = SettingsController()

    var body: some View {
        SystemSettingsForm(
            generalSettings: $generalSettings,
            onGeneralChange: save
        )
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            toolbarButtons = []
            generalSettings = GeneralSettings.load()
            isMenuBarInserted = generalSettings.enableMenuBar
        }
    }

    private func save() {
        generalSettings = settingsController.save(generalSettings)
        isMenuBarInserted = generalSettings.enableMenuBar
    }
}

/// 系统设置页面中的 KV 偏好绑定表单。
private struct SystemSettingsForm: View {
    @Binding var generalSettings: GeneralSettings
    let onGeneralChange: () -> Void

    private var proxyListenPortText: Binding<String> {
        portText(
            get: { generalSettings.proxyListenPort },
            set: { generalSettings.proxyListenPort = $0 }
        )
    }

    private var pacListenPortText: Binding<String> {
        portText(
            get: { generalSettings.pacListenPort },
            set: { generalSettings.pacListenPort = $0 }
        )
    }

    private var proxyThreadNumberText: Binding<String> {
        positiveIntegerText(
            get: { generalSettings.proxyThreadNumber },
            set: { generalSettings.proxyThreadNumber = $0 }
        )
    }

    var body: some View {
        Form {
            Section("常规") {
                Toggle("开机启动", isOn: $generalSettings.launchAtLogin)
                Toggle("启用菜单栏", isOn: $generalSettings.enableMenuBar)
            }

            Section("同步") {
                Toggle("启用 iCloud 同步", isOn: $generalSettings.iCloudSyncEnabled)
            }

            Section("规则订阅") {
                TextField("规则订阅 URL", text: $generalSettings.rulesURL)
                TextField("PSL 下载 URL", text: $generalSettings.publicSuffixListURL)
            }

            Section("代理服务") {
                TextField("代理服务地址", text: $generalSettings.proxyListenAddress)
                TextField("代理服务端口", text: proxyListenPortText)
                TextField("代理线程数", text: proxyThreadNumberText)
            }

            Section("PAC") {
                TextField("PAC 地址", text: $generalSettings.pacListenAddress)
                TextField("PAC 端口", text: pacListenPortText)
            }

        }
        .formStyle(.grouped)
        .onChange(of: generalSettings.launchAtLogin) { _, _ in onGeneralChange() }
        .onChange(of: generalSettings.enableMenuBar) { _, _ in onGeneralChange() }
        .onChange(of: generalSettings.iCloudSyncEnabled) { _, _ in onGeneralChange() }
        .onChange(of: generalSettings.rulesURL) { _, _ in onGeneralChange() }
        .onChange(of: generalSettings.publicSuffixListURL) { _, _ in onGeneralChange() }
        .onChange(of: generalSettings.proxyListenAddress) { _, _ in onGeneralChange() }
        .onChange(of: generalSettings.proxyListenPort) { _, _ in onGeneralChange() }
        .onChange(of: generalSettings.proxyThreadNumber) { _, _ in onGeneralChange() }
        .onChange(of: generalSettings.pacListenAddress) { _, _ in onGeneralChange() }
        .onChange(of: generalSettings.pacListenPort) { _, _ in onGeneralChange() }
    }

    private func portText(
        get: @escaping () -> Int,
        set: @escaping (Int) -> Void
    ) -> Binding<String> {
        Binding(
            get: {
                String(get())
            },
            set: { newValue in
                let digits = newValue.filter { $0.isNumber }
                guard let port = Int(digits), (1...65535).contains(port) else {
                    return
                }
                set(port)
            }
        )
    }

    private func positiveIntegerText(
        get: @escaping () -> Int,
        set: @escaping (Int) -> Void
    ) -> Binding<String> {
        Binding(
            get: {
                String(get())
            },
            set: { newValue in
                let digits = newValue.filter { $0.isNumber }
                guard let number = Int(digits), number > 0 else {
                    return
                }
                set(number)
            }
        )
    }
}
