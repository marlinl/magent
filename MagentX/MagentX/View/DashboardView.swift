//
//  DashboardView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Displays the proxy dashboard overview.
//

import FactoryKit
import SwiftUI

/// 仪表盘页面，展示代理运行状态入口和概览空态。
struct DashboardView: View {
    @Binding var toolbarButtons: [ContentToolbarButton]
    @InjectedObject(\.systemNetworkSettingService) private var systemNetworkSettingService

    var body: some View {
        ContentUnavailableView(
            "代理服务尚未接入",
            systemImage: "network",
            description: Text("这里会展示本地 SOCKS5/HTTP 服务、当前节点和实时流量。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            Button {
                Task {
                    await systemNetworkSettingService.toggleService()
                }
            } label: {
                Label(
                    systemNetworkSettingService.isApplying
                        ? "正在切换代理服务"
                        : (systemNetworkSettingService.isServiceStarted ? "关闭代理服务" : "启动代理服务"),
                    systemImage: systemNetworkSettingService.isApplying
                        ? "hourglass"
                        : (systemNetworkSettingService.isServiceStarted ? "stop.fill" : "power")
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(systemNetworkSettingService.isServiceStarted ? .red : .accentColor)
            .disabled(systemNetworkSettingService.isApplying)
            .help(
                systemNetworkSettingService.isApplying
                    ? "正在切换代理服务"
                    : (systemNetworkSettingService.isServiceStarted ? "关闭代理服务" : "启动代理服务")
            )
            .accessibilityLabel(
                systemNetworkSettingService.isApplying
                    ? "正在切换代理服务"
                    : (systemNetworkSettingService.isServiceStarted ? "关闭代理服务" : "启动代理服务")
            )
            .padding(24)
        }
        .alert("代理服务操作失败", isPresented: Binding(get: {
            systemNetworkSettingService.serviceError != nil
        }, set: { isPresented in
            if isPresented == false {
                systemNetworkSettingService.clearServiceError()
            }
        })) {
            Button("好") {
                systemNetworkSettingService.clearServiceError()
            }
        } message: {
            Text(systemNetworkSettingService.serviceError ?? "")
        }
        .onAppear {
            toolbarButtons = []
            systemNetworkSettingService.reloadCurrentSelection()
        }
    }
}
