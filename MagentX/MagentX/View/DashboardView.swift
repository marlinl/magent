//
//  DashboardView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Displays the proxy dashboard overview.
//

import SwiftUI

/// 仪表盘页面，展示代理运行状态入口和概览空态。
struct DashboardView: View {
    @Binding var toolbarButtons: [ContentToolbarButton]
    @ObservedObject private var systemNetworkProxyService = SystemNetworkProxyService.shared

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
                    await systemNetworkProxyService.toggleService()
                }
            } label: {
                Label(
                    systemNetworkProxyService.isApplying
                        ? "正在切换代理服务"
                        : (systemNetworkProxyService.isServiceStarted ? "关闭代理服务" : "启动代理服务"),
                    systemImage: systemNetworkProxyService.isApplying
                        ? "hourglass"
                        : (systemNetworkProxyService.isServiceStarted ? "stop.fill" : "power")
                )
                .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .tint(systemNetworkProxyService.isServiceStarted ? .red : .accentColor)
            .disabled(systemNetworkProxyService.isApplying)
            .help(
                systemNetworkProxyService.isApplying
                    ? "正在切换代理服务"
                    : (systemNetworkProxyService.isServiceStarted ? "关闭代理服务" : "启动代理服务")
            )
            .accessibilityLabel(
                systemNetworkProxyService.isApplying
                    ? "正在切换代理服务"
                    : (systemNetworkProxyService.isServiceStarted ? "关闭代理服务" : "启动代理服务")
            )
            .padding(24)
        }
        .alert("代理服务操作失败", isPresented: Binding(get: {
            systemNetworkProxyService.serviceError != nil
        }, set: { isPresented in
            if isPresented == false {
                systemNetworkProxyService.clearServiceError()
            }
        })) {
            Button("好") {
                systemNetworkProxyService.clearServiceError()
            }
        } message: {
            Text(systemNetworkProxyService.serviceError ?? "")
        }
        .onAppear {
            toolbarButtons = []
            systemNetworkProxyService.reloadCurrentSelection()
        }
    }
}
