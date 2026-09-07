//
//  ProxyRulesView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Displays and directly manages persisted proxy rules.
//

import FactoryKit
import Foundation
import Magent
import SwiftData
import SwiftUI

/// 代理规则页面，直接观察 SwiftData 规则并提供新增、修改、删除和同步交互。
@MainActor
struct ProxyRulesView: View {
    @Environment(\.modelContext) private var modelContext
    @Injected(\.localExecutor) private var localExecutor
    @Injected(\.magentProxyRuleService) private var magentProxyRuleService
    @Binding var toolbarButtons: [ContentToolbarButton]
    @State private var searchText = ""
    @State private var pageAt = 1
    @State private var isRefreshing = false
    @State private var editingRule: MagentProxyRule?
    @State private var syncError: String?

    private static let pageSize = 100

    var body: some View {
        let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        ProxyRulePageView(
            searchText: normalizedSearchText,
            pageAt: $pageAt,
            pageSize: Self.pageSize,
            isRefreshing: isRefreshing,
            editingRule: $editingRule
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(
            text: Binding(
                get: { searchText },
                set: { newValue in
                    searchText = newValue
                    pageAt = 1
                }
            ),
            placement: .toolbar,
            prompt: "搜索规则"
        )
        .sheet(item: $editingRule) { rule in
            ProxyRuleFormView(rule: rule)
                .presentationSizing(.form)
        }
        .alert(
            "规则同步失败",
            isPresented: Binding(
                get: { syncError != nil },
                set: { isPresented in
                    if isPresented == false {
                        syncError = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {
                syncError = nil
            }
        } message: {
            Text(syncError ?? "")
        }
        .task(id: isRefreshing) {
            if isRefreshing {
                toolbarButtons = [
                    ContentToolbarButton(
                        title: "增加规则",
                        systemImage: "plus",
                        isDisabled: true
                    ) {},
                    ContentToolbarButton(
                        title: "正在同步规则",
                        systemImage: "hourglass",
                        isLoading: true,
                        isDisabled: true
                    ) {}
                ]
            } else {
                toolbarButtons = [
                    ContentToolbarButton(title: "增加规则", systemImage: "plus") {
                        var unfinishedRuleDescriptor = FetchDescriptor<MagentProxyRule>(
                            predicate: #Predicate<MagentProxyRule> { rule in
                                rule.matchValue == ""
                            }
                        )
                        unfinishedRuleDescriptor.fetchLimit = 1
                        if let unfinishedRule = try? modelContext.fetch(unfinishedRuleDescriptor).first {
                            editingRule = unfinishedRule
                            return
                        }

                        var lastRuleDescriptor = FetchDescriptor<MagentProxyRule>(
                            sortBy: [SortDescriptor(\.id, order: .reverse)]
                        )
                        lastRuleDescriptor.fetchLimit = 1
                        guard let storedRules = try? modelContext.fetch(lastRuleDescriptor),
                              storedRules.first?.id != Int.max
                        else {
                            return
                        }

                        let existingRuleCount = (try? modelContext.fetchCount(
                            FetchDescriptor<MagentProxyRule>()
                        )) ?? 0
                        let nextID = storedRules.first.map { $0.id + 1 } ?? 0
                        let now = Date.now
                        let rule = MagentProxyRule(
                            id: nextID,
                            matchType: MatchType.domainSuffix.rawValue,
                            matchValue: "",
                            decision: "proxy",
                            order: 0,
                            source: "user",
                            createdAt: now,
                            updatedAt: now
                        )
                        modelContext.insert(rule)
                        searchText = ""
                        pageAt = existingRuleCount / Self.pageSize + 1
                        editingRule = rule
                    },
                    ContentToolbarButton(title: "同步规则", systemImage: "arrow.clockwise") {
                        sync()
                    }
                ]
            }
        }
    }

    /// 下载订阅规则、合并数据库并重写 PAC，期间同步主窗口工具栏状态。
    private func sync() {
        guard isRefreshing == false else { return }

        let now = Date.now
        let magentProxyRuleService = self.magentProxyRuleService
        isRefreshing = true
        syncError = nil

        localExecutor.submit(
            priority: .utility,
            operation: {
                try await magentProxyRuleService.sync()
            },
            completion: { result in
                isRefreshing = false
                switch result {
                case .success:
                    var refreshedSettings = GeneralSettings.load()
                    refreshedSettings.updatedAt = now
                    refreshedSettings.save()
                case .failure(let error):
                    syncError = error.localizedDescription
                }
            }
        )
    }

    /// 使用搜索条件和当前页对应的 `FetchDescriptor` 观察并展示最多 100 条代理规则。
    private struct ProxyRulePageView: View {
        @Environment(\.modelContext) private var modelContext
        @Query private var rules: [MagentProxyRule]
        @Binding private var pageAt: Int
        @Binding private var editingRule: MagentProxyRule?
        @State private var scrollPosition = ScrollPosition(edge: .top)

        private let searchText: String
        private let pageSize: Int
        private let isRefreshing: Bool

        /// 为指定搜索条件和页码创建按规则 id 正序排列的 SwiftData 查询。
        init(
            searchText: String,
            pageAt: Binding<Int>,
            pageSize: Int,
            isRefreshing: Bool,
            editingRule: Binding<MagentProxyRule?>
        ) {
            precondition(pageAt.wrappedValue >= 1, "pageAt must start at 1")
            precondition(pageSize > 0, "pageSize must be greater than 0")

            let sortDescriptors = [SortDescriptor(\MagentProxyRule.id, order: .forward)]
            var descriptor: FetchDescriptor<MagentProxyRule>
            if searchText.isEmpty {
                descriptor = FetchDescriptor<MagentProxyRule>(sortBy: sortDescriptors)
            } else {
                let query = searchText
                descriptor = FetchDescriptor<MagentProxyRule>(
                    predicate: #Predicate<MagentProxyRule> { rule in
                        rule.matchValue.contains(query)
                    },
                    sortBy: sortDescriptors
                )
            }
            descriptor.fetchLimit = pageSize + 1
            descriptor.fetchOffset = (pageAt.wrappedValue - 1) * pageSize
            _rules = Query(descriptor)
            _pageAt = pageAt
            _editingRule = editingRule
            self.searchText = searchText
            self.pageSize = pageSize
            self.isRefreshing = isRefreshing
        }

        var body: some View {
            Group {
                if isRefreshing, rules.isEmpty {
                    ProgressView("正在同步规则")
                } else if rules.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "暂无规则" : "未找到规则",
                        systemImage: searchText.isEmpty
                            ? "arrow.triangle.branch"
                            : "magnifyingglass",
                        description: Text(
                            searchText.isEmpty
                                ? (pageAt == 1 ? "添加或同步规则后会显示在这里" : "当前页没有规则")
                                : searchText
                        )
                    )
                } else {
                    Table(Array(rules.prefix(pageSize))) {
                        TableColumn("匹配值") { rule in
                            Text(rule.matchValue)
                                .lineLimit(1)
                        }
                        .width(min: 64, ideal: 280)

                        TableColumn("类型") { rule in
                            Text(rule.matchType)
                                .lineLimit(1)
                        }
                        .width(min: 44, ideal: 80, max: 110)

                        TableColumn("顺序") { rule in
                            Text(rule.order, format: .number)
                                .lineLimit(1)
                        }
                        .width(min: 40, ideal: 56, max: 72)

                        TableColumn("来源") { rule in
                            Text(rule.source.isEmpty ? "-" : rule.source)
                                .lineLimit(1)
                        }
                        .width(min: 44, ideal: 76, max: 100)

                        TableColumn("规则") { rule in
                            Text(rule.decision.uppercased())
                                .lineLimit(1)
                        }
                        .width(min: 44, ideal: 64, max: 84)

                        TableColumn("操作") { rule in
                            ControlGroup {
                                Button {
                                    editingRule = rule
                                } label: {
                                    Label("编辑规则", systemImage: "pencil")
                                        .labelStyle(.iconOnly)
                                }
                                .help("编辑规则")
                                .buttonStyle(.glass)

                                Button(role: .destructive) {
                                    if editingRule?.id == rule.id {
                                        editingRule = nil
                                    }
                                    modelContext.delete(rule)
                                } label: {
                                    Label("删除规则", systemImage: "trash")
                                        .labelStyle(.iconOnly)
                                }
                                .help("删除规则")
                                .buttonStyle(.glass)
                            }
                            .controlSize(.small)
                        }
                        .width(min: 72, ideal: 88, max: 96)
                    }
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: ScrollGeometry.self) { geometry in
                        geometry
                    } action: { oldGeometry, newGeometry in
                        guard scrollPosition.isPositionedByUser else { return }

                        if newGeometry.visibleRect.minY < oldGeometry.visibleRect.minY,
                           newGeometry.visibleRect.minY <= 0,
                           pageAt > 1 {
                            pageAt -= 1
                            scrollPosition.scrollTo(edge: .bottom)
                        } else if newGeometry.visibleRect.maxY > oldGeometry.visibleRect.maxY,
                                  newGeometry.visibleRect.maxY >= newGeometry.contentSize.height,
                                  rules.count > pageSize {
                            pageAt += 1
                            scrollPosition.scrollTo(edge: .top)
                        }
                    }
                }
            }
            .onChange(of: searchText) { _, _ in
                scrollPosition.scrollTo(edge: .top)
            }
        }
    }

    /// 直接编辑 SwiftData 代理规则的原生表单页面。
    private struct ProxyRuleFormView: View {
        @Environment(\.dismiss) private var dismiss
        @Query private var rules: [MagentProxyRule]
        @Bindable var rule: MagentProxyRule

        var body: some View {
            let formError = rule.validationError(in: rules)

            Form {
                Section {
                    Picker("匹配类型", selection: $rule.matchType) {
                        ForEach(MatchType.allCases, id: \.rawValue) { matchType in
                            Text(matchType.rawValue)
                                .tag(matchType.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("动作", selection: $rule.decision) {
                        Text("DIRECT").tag("direct")
                        Text("PROXY").tag("proxy")
                    }
                    .pickerStyle(.menu)

                    TextField("匹配值", text: $rule.matchValue)
                    if let formError {
                        Label(formError.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("规则配置")
                        .font(.title3.weight(.semibold))
                }
            }
            .formStyle(.grouped)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .disabled(formError != nil)
                }
            }
            .interactiveDismissDisabled(formError != nil)
            .onChange(of: rule.matchType) { _, _ in
                rule.source = "user"
                rule.updatedAt = .now
            }
            .onChange(of: rule.decision) { _, _ in
                rule.source = "user"
                rule.updatedAt = .now
            }
            .onChange(of: rule.matchValue) { _, _ in
                rule.source = "user"
                rule.updatedAt = .now
            }
        }
    }
}
