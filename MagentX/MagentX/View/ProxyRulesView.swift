//
//  ProxyRulesView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Displays the proxy rule management surface.
//

import Magent
import SwiftUI
import SwiftData

/// 代理规则页面，展示访问规则并触发 GFWList 刷新。
struct ProxyRulesView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var controller = RuleController()
    @State private var searchText = ""
    @State private var isAddingRules = false
    @Binding var toolbarButtons: [ContentToolbarButton]

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ruleList
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .searchable(text: $searchText, placement: .toolbar, prompt: "搜索 matchValue")
            .sheet(isPresented: $isAddingRules) {
                AddAccessControlRulesSheet(controller: controller)
                    .environment(\.modelContext, modelContext)
            }
            .onAppear {
                publishToolbarButtons()
            }
            .onChange(of: controller.isRefreshing) { _, _ in
                publishToolbarButtons()
            }
            .onChange(of: searchText) { _, searchText in
                controller.loadFirstPage(from: modelContext, matching: searchText)
            }
            .task {
                controller.loadFirstPage(from: modelContext, matching: searchText)
            }
    }

    private func publishToolbarButtons() {
        toolbarButtons = [
            ContentToolbarButton(title: "增加规则", systemImage: "plus") {
                isAddingRules = true
            },
            ContentToolbarButton(
                title: controller.isRefreshing ? "正在同步规则" : "同步规则",
                systemImage: controller.isRefreshing ? "hourglass" : "arrow.clockwise",
                isLoading: controller.isRefreshing,
                isDisabled: controller.isRefreshing
            ) {
                refreshRules()
            }
        ]
    }

    private func refreshRules() {
        Task {
            await controller.refreshRuleList(from: modelContext, matching: searchText)
        }
    }

    @ViewBuilder
    private var ruleList: some View {
        if let loadError = controller.loadError {
            ContentUnavailableView(
                "规则读取失败",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else if controller.accessControlRules.isEmpty {
            ContentUnavailableView(
                trimmedSearchText.isEmpty ? "暂无规则" : "未找到规则",
                systemImage: trimmedSearchText.isEmpty ? "arrow.triangle.branch" : "magnifyingglass",
                description: Text(trimmedSearchText.isEmpty ? "AccessControlRule 会显示在这里" : trimmedSearchText)
            )
        } else {
            Table(controller.accessControlRules) {
                TableColumn("匹配值") { accessControlRule in
                    Text(accessControlRule.matchValue)
                        .lineLimit(1)
                        .onAppear {
                            loadMoreRulesIfNeeded(currentRule: accessControlRule)
                        }
                }

                TableColumn("类型") { accessControlRule in
                    Text(accessControlRule.matchType.rawValue)
                }

                TableColumn("顺序") { accessControlRule in
                    Text(accessControlRule.order, format: .number)
                }

                TableColumn("来源") { accessControlRule in
                    Text(accessControlRule.source.isEmpty ? "-" : accessControlRule.source)
                        .lineLimit(1)
                }

                TableColumn("动作") { accessControlRule in
                    Picker("动作", selection: decisionBinding(for: accessControlRule)) {
                        Text("DIRECT").tag("direct")
                        Text("PROXY").tag("proxy")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                TableColumn("操作") { accessControlRule in
                    Button(role: .destructive) {
                        controller.deleteAccessControl(accessControlRule, from: modelContext)
                    } label: {
                        Label("删除规则", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("删除规则")
                }
            }
        }
    }

    private func decisionBinding(for accessControlRule: AccessControlRule) -> Binding<String> {
        Binding(
            get: { accessControlRule.decision },
            set: { decision in
                controller.updateDecision(decision, for: accessControlRule, in: modelContext)
            }
        )
    }

    private func loadMoreRulesIfNeeded(currentRule accessControlRule: AccessControlRule) {
        guard accessControlRule.id == controller.accessControlRules.last?.id else { return }
        controller.loadNextPage(from: modelContext, matching: searchText)
    }
}

/// 批量新增访问规则的原生表单 sheet。
private struct AddAccessControlRulesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var controller: RuleController
    @State private var matchType = Magent.MatchType.domainSuffix
    @State private var decision = "proxy"
    @State private var matchValuesText = ""

    private var matchValues: [String] {
        matchValuesText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private var canAdd: Bool {
        matchValues.isEmpty == false
    }

    var body: some View {
        Form {
            Section {
                Picker("匹配类型", selection: $matchType) {
                    ForEach(Magent.MatchType.allCases, id: \.rawValue) { matchType in
                        Text(matchType.rawValue)
                            .tag(matchType)
                    }
                }
                .pickerStyle(.menu)

                Picker("动作", selection: $decision) {
                    Text("DIRECT").tag("direct")
                    Text("PROXY").tag("proxy")
                }
                .pickerStyle(.menu)
            } header: {
                Text("增加规则")
                    .font(.title3.weight(.semibold))
            }

            Section("MatchValue") {
                TextEditor(text: $matchValuesText)
                    .frame(minHeight: 160)
            }

            Section {
                ControlGroup {
                    Button("取消", role: .cancel) {
                        dismiss()
                    }

                    Button("添加") {
                        addRules()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(canAdd == false)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 420)
    }

    private func addRules() {
        let didAdd = controller.addAccessControls(
            matchType: matchType,
            matchValues: matchValues,
            decision: decision,
            in: modelContext
        )
        if didAdd {
            dismiss()
        }
    }
}
