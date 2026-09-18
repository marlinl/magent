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
  @InjectedObject(\.systemNetworkChangeListsner) private var systemNetworkChangeListsner

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
          await systemNetworkChangeListsner.toggleService()
        }
      } label: {
        Label(
          systemNetworkChangeListsner.isApplying
            ? "正在切换代理服务"
            : (systemNetworkChangeListsner.isServiceStarted ? "关闭代理服务" : "启动代理服务"),
          systemImage: systemNetworkChangeListsner.isApplying
            ? "hourglass"
            : (systemNetworkChangeListsner.isServiceStarted ? "stop.fill" : "power")
        )
        .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.circle)
      .controlSize(.large)
      .tint(systemNetworkChangeListsner.isServiceStarted ? .red : .accentColor)
      .disabled(systemNetworkChangeListsner.isApplying)
      .help(
        systemNetworkChangeListsner.isApplying
          ? "正在切换代理服务"
          : (systemNetworkChangeListsner.isServiceStarted ? "关闭代理服务" : "启动代理服务")
      )
      .accessibilityLabel(
        systemNetworkChangeListsner.isApplying
          ? "正在切换代理服务"
          : (systemNetworkChangeListsner.isServiceStarted ? "关闭代理服务" : "启动代理服务")
      )
      .padding(24)
    }
    .alert(
      "代理服务操作失败",
      isPresented: Binding(
        get: {
          systemNetworkChangeListsner.serviceError != nil
        },
        set: { isPresented in
          if isPresented == false {
            systemNetworkChangeListsner.clearServiceError()
          }
        })
    ) {
      Button("好") {
        systemNetworkChangeListsner.clearServiceError()
      }
    } message: {
      Text(systemNetworkChangeListsner.serviceError ?? "")
    }
    .onAppear {
      toolbarButtons = []
      systemNetworkChangeListsner.reloadCurrentSelection()
    }
  }
}
