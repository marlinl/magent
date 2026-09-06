//
//  ContentView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Defines the macOS navigation shell and routes sections to page views.
//

import SwiftData
import SwiftUI

/// 主导航中的页面分区。
enum AppSection: String, CaseIterable, Identifiable {
    case dashboard
    case proxyPolicy
    case proxyNodes
    case proxyRules
    case settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .dashboard: "仪表盘"
        case .proxyNodes: "代理节点"
        case .proxyRules: "代理规则"
        case .proxyPolicy: "代理策略"
        case .settings: "应用设置"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .dashboard: "代理运行状态和链路概览"
        case .proxyNodes: "代理节点管理与测速"
        case .proxyRules: "代理规则匹配与开关"
        case .proxyPolicy: "代理策略编排与选择"
        case .settings: "应用设置和启动偏好"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .proxyNodes: "point.3.connected.trianglepath.dotted"
        case .proxyRules: "list.bullet.rectangle"
        case .proxyPolicy: "arrow.triangle.branch"
        case .settings: "gearshape.fill"
        }
    }
}

/// 页面向 `ContentView` 发布的窗口工具栏按钮描述。
struct ContentToolbarButton: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let systemImage: String
    let role: ButtonRole?
    let isLoading: Bool
    let isDisabled: Bool
    let action: () -> Void

    /// 创建一个可发布到主窗口工具栏的按钮描述。
    init(
        id: String? = nil,
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.id = id ?? title
        self.title = LocalizedStringKey(title)
        self.systemImage = systemImage
        self.role = role
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.action = action
    }
}

/// 主窗口布局常量。
private enum ContentMetrics {
    static let sidebarWidth: CGFloat = 220
    static let detailMinimumWidth: CGFloat = 360
    static let detailIdealWidth: CGFloat = 600
}

/// MagentX 主窗口导航壳，负责侧边栏选择、页面路由和页面级工具栏。
struct ContentView: View {

    @Binding var isMenuBarInserted: Bool
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selectedSection: AppSection? = .dashboard
    @State private var toolbarButtons: [ContentToolbarButton] = []

    private var currentSection: AppSection {
        selectedSection ?? .dashboard
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(ContentMetrics.sidebarWidth)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(
                    min: ContentMetrics.detailMinimumWidth,
                    ideal: ContentMetrics.detailIdealWidth
                )
        }
        .navigationTitle(currentSection.title)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            ToolbarSpacer(.flexible)

            if !toolbarButtons.isEmpty {
                ToolbarItemGroup(placement: .primaryAction) {
                    ForEach(toolbarButtons) { button in
                        toolbarButton(button)
                    }
                }
            }
        }
        .onChange(of: currentSection) { _, _ in
            toolbarButtons = []
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSection) {
            Section {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var detail: some View {
        detailContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolbarButton(_ button: ContentToolbarButton) -> some View {
        Button(role: button.role, action: button.action) {
            if button.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(button.title, systemImage: button.systemImage)
                    .labelStyle(.iconOnly)
            }
        }
        .disabled(button.isDisabled)
        .help(button.title)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch currentSection {
        case .dashboard:
            DashboardView(toolbarButtons: $toolbarButtons)
        case .proxyNodes:
            ProxyNodesView(toolbarButtons: $toolbarButtons)
        case .proxyRules:
            ProxyRulesView(toolbarButtons: $toolbarButtons)
        case .proxyPolicy:
            ProxyPolicyView(toolbarButtons: $toolbarButtons)
        case .settings:
            AppSettingsView(
                toolbarButtons: $toolbarButtons,
                isMenuBarInserted: $isMenuBarInserted
            )
        }
    }
}

#Preview {
    ContentView(isMenuBarInserted: .constant(true))
        .modelContainer(for: [
            MagentProxyNode.self,
            MagentProxyRule.self,
            MagentProxyPolicy.self,
            MagentProxyPolicyRule.self
        ], inMemory: true)
        .frame(width: 1184, height: 760)
}
