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
    @StateObject private var serviceController = MagentServiceController()

    var body: some View {
        ContentUnavailableView(
            "代理服务尚未接入",
            systemImage: "network",
            description: Text("这里会展示本地 SOCKS5/HTTP 服务、当前节点和实时流量。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            serviceActionOverlay
                .padding(24)
        }
        .alert("代理服务操作失败", isPresented: serviceErrorPresented) {
            Button("好") {
                serviceController.clearServiceError()
            }
        } message: {
            Text(serviceController.serviceError ?? "")
        }
        .onAppear {
            toolbarButtons = []
            serviceController.reloadCurrentSelection()
        }
    }

    private var serviceErrorPresented: Binding<Bool> {
        Binding(get: {
            serviceController.serviceError != nil
        }, set: { isPresented in
            if isPresented == false {
                serviceController.clearServiceError()
            }
        })
    }

    private var serviceActionOverlay: some View {
        Button {
            Task {
                await serviceController.toggleService()
            }
        } label: {
            Label(serviceActionTitle, systemImage: serviceActionSystemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .tint(serviceController.isServiceStarted ? .red : .accentColor)
        .disabled(serviceController.isApplying)
        .help(serviceActionTitle)
        .accessibilityLabel(serviceActionTitle)
    }

    private var serviceActionTitle: String {
        if serviceController.isApplying {
            return "正在切换代理服务"
        }

        return serviceController.isServiceStarted ? "关闭代理服务" : "启动代理服务"
    }

    private var serviceActionSystemImage: String {
        if serviceController.isApplying {
            return "hourglass"
        }

        return serviceController.isServiceStarted ? "stop.fill" : "power"
    }
}
