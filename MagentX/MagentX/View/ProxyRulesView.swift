//
//  ProxyRulesView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Displays and directly manages persisted proxy rules.
//

import Foundation
import Magent
import SwiftData
import SwiftUI

/// 代理规则页面，只通过初始化、新增、删除、搜索和更新五类页面操作管理 `MagentProxyRule`。
@MainActor
struct ProxyRulesView: View {
    /// 页面更新操作，统一表达单条规则修改和订阅同步。
    private enum UpdateOperation {
        case decision(MagentProxyRule, RuleDecision)
        case subscription
    }

    @Environment(\.modelContext) private var modelContext
    @State private var proxyRules: [MagentProxyRule] = []
    @State private var searchText = ""
    @State private var loadError: String?
    @State private var canLoadMore = false
    @State private var isRefreshing = false
    @State private var isAddingRules = false
    @State private var fetchLimit = Self.pageSize
    @State private var newMatchType = MatchType.domainSuffix
    @State private var newDecision = RuleDecision.proxy
    @State private var newMatchValuesText = ""
    @Binding var toolbarButtons: [ContentToolbarButton]

    private static let pageSize = 50

    /// 去除首尾空白后的搜索关键字。
    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把新增表单中的非空行转换为匹配值。
    private var newMatchValues: [String] {
        newMatchValuesText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    /// 注入由 `ContentView` 管理的工具栏按钮绑定；环境数据在 View 挂载后由 `search` 首次读取。
    init(toolbarButtons: Binding<[ContentToolbarButton]>) {
        self._toolbarButtons = toolbarButtons
    }

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView(
                    "规则读取失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if proxyRules.isEmpty {
                ContentUnavailableView(
                    trimmedSearchText.isEmpty ? "暂无规则" : "未找到规则",
                    systemImage: trimmedSearchText.isEmpty ? "arrow.triangle.branch" : "magnifyingglass",
                    description: Text(trimmedSearchText.isEmpty ? "MagentProxyRule 会显示在这里" : trimmedSearchText)
                )
            } else {
                Table(proxyRules) {
                    TableColumn("匹配值") { proxyRule in
                        Text(proxyRule.matchValue)
                            .lineLimit(1)
                            .onAppear {
                                guard proxyRule.id == proxyRules.last?.id, canLoadMore else { return }
                                fetchLimit += Self.pageSize
                                search()
                            }
                    }

                    TableColumn("类型") { proxyRule in
                        Text(proxyRule.matchType.rawValue)
                    }

                    TableColumn("顺序") { proxyRule in
                        Text(proxyRule.order, format: .number)
                    }

                    TableColumn("来源") { proxyRule in
                        Text(proxyRule.source.isEmpty ? "-" : proxyRule.source)
                            .lineLimit(1)
                    }

                    TableColumn("动作") { proxyRule in
                        Picker(
                            "动作",
                            selection: Binding(
                                get: { proxyRule.decision },
                                set: { update(.decision(proxyRule, $0)) }
                            )
                        ) {
                            Text("DIRECT").tag(RuleDecision.direct)
                            Text("PROXY").tag(RuleDecision.proxy)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    TableColumn("操作") { proxyRule in
                        Button(role: .destructive) {
                            delete(proxyRule)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索 matchValue")
        .sheet(isPresented: $isAddingRules) {
            Form {
                Section {
                    Picker("匹配类型", selection: $newMatchType) {
                        ForEach(MatchType.allCases, id: \.rawValue) { matchType in
                            Text(matchType.rawValue)
                                .tag(matchType)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("动作", selection: $newDecision) {
                        Text("DIRECT").tag(RuleDecision.direct)
                        Text("PROXY").tag(RuleDecision.proxy)
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("增加规则")
                        .font(.title3.weight(.semibold))
                }

                Section("MatchValue") {
                    TextEditor(text: $newMatchValuesText)
                        .frame(minHeight: 160)
                }

                Section {
                    ControlGroup {
                        Button("取消", role: .cancel) {
                            isAddingRules = false
                        }

                        Button("添加") {
                            if add(
                                matchType: newMatchType,
                                matchValues: newMatchValues,
                                decision: newDecision
                            ) {
                                newMatchValuesText = ""
                                isAddingRules = false
                            }
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newMatchValues.isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(width: 420)
        }
        .onAppear {
            toolbarButtons = [
                ContentToolbarButton(title: "增加规则", systemImage: "plus") {
                    isAddingRules = true
                },
                ContentToolbarButton(
                    title: "同步规则",
                    systemImage: "arrow.clockwise"
                ) {
                    update(.subscription)
                }
            ]
        }
        .onChange(of: searchText) { _, _ in
            fetchLimit = Self.pageSize
            search()
        }
        .task {
            search()
        }
    }

    /// 新增一批手工代理规则，完成输入清理、重复校验、持久化和列表刷新。
    private func add(
        matchType: MatchType,
        matchValues: [String],
        decision: RuleDecision
    ) -> Bool {
        var seenMatchValues = Set<String>()
        let uniqueMatchValues: [String] = matchValues.compactMap { matchValue in
            let normalizedValue = matchValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedValue.isEmpty == false,
                  seenMatchValues.insert(normalizedValue).inserted else {
                return nil
            }
            return normalizedValue
        }
        guard uniqueMatchValues.isEmpty == false else {
            loadError = String(localized: "Match value is required")
            return false
        }

        do {
            let existingRules = try modelContext.fetch(FetchDescriptor<MagentProxyRule>())
            let existingIdentities = Set(existingRules.map {
                "\($0.matchType.rawValue):\($0.matchValue)"
            })
            let newIdentities = uniqueMatchValues.map {
                "\(matchType.rawValue):\($0)"
            }
            guard newIdentities.allSatisfy({ existingIdentities.contains($0) == false }) else {
                loadError = MagentXError.duplicateMagentProxyRule.localizedDescription
                return false
            }

            var usedIDs = Set(existingRules.map(\.id))
            var nextIDCandidate = 0
            let now = Date.now
            for matchValue in uniqueMatchValues {
                while usedIDs.contains(nextIDCandidate) {
                    nextIDCandidate += 1
                }
                let id = nextIDCandidate
                usedIDs.insert(id)
                nextIDCandidate += 1

                modelContext.insert(MagentProxyRule(
                    id: id,
                    matchType: matchType,
                    matchValue: matchValue,
                    decision: decision,
                    order: 0,
                    source: "",
                    createdAt: now,
                    updatedAt: now
                ))
            }

            try modelContext.save()
            search()
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    /// 删除一条代理规则，保存后重新搜索当前页。
    private func delete(_ proxyRule: MagentProxyRule) {
        do {
            modelContext.delete(proxyRule)
            try modelContext.save()
            search()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// 按当前关键字、排序和分页上限读取 `MagentProxyRule`。
    private func search() {
        let sortDescriptors: [SortDescriptor<MagentProxyRule>] = [
            SortDescriptor(\.order),
            SortDescriptor(\.matchValue)
        ]

        var descriptor: FetchDescriptor<MagentProxyRule>
        if trimmedSearchText.isEmpty {
            descriptor = FetchDescriptor<MagentProxyRule>(sortBy: sortDescriptors)
        } else {
            let query = trimmedSearchText
            descriptor = FetchDescriptor<MagentProxyRule>(
                predicate: #Predicate<MagentProxyRule> { proxyRule in
                    proxyRule.matchValue.contains(query)
                },
                sortBy: sortDescriptors
            )
        }
        descriptor.fetchLimit = fetchLimit + 1

        do {
            let fetchedRules = try modelContext.fetch(descriptor)
            proxyRules = Array(fetchedRules.prefix(fetchLimit))
            canLoadMore = fetchedRules.count > proxyRules.count
            loadError = nil
        } catch {
            proxyRules = []
            canLoadMore = false
            loadError = error.localizedDescription
        }
    }

    /// 更新单条规则动作或执行订阅同步，并在操作结束后刷新页面状态。
    private func update(_ operation: UpdateOperation) {
        switch operation {
        case let .decision(proxyRule, decision):
            let previousDecision = proxyRule.decision
            let previousUpdatedAt = proxyRule.updatedAt
            proxyRule.decision = decision
            proxyRule.updatedAt = .now

            do {
                try modelContext.save()
                search()
            } catch {
                proxyRule.decision = previousDecision
                proxyRule.updatedAt = previousUpdatedAt
                loadError = error.localizedDescription
            }

        case .subscription:
            guard isRefreshing == false else { return }
            isRefreshing = true
            toolbarButtons = [
                ContentToolbarButton(title: "增加规则", systemImage: "plus") {
                    isAddingRules = true
                },
                ContentToolbarButton(
                    title: "正在同步规则",
                    systemImage: "hourglass",
                    isLoading: true,
                    isDisabled: true
                ) {
                    update(.subscription)
                }
            ]

            Task {
                defer {
                    isRefreshing = false
                    toolbarButtons = [
                        ContentToolbarButton(title: "增加规则", systemImage: "plus") {
                            isAddingRules = true
                        },
                        ContentToolbarButton(
                            title: "同步规则",
                            systemImage: "arrow.clockwise"
                        ) {
                            update(.subscription)
                        }
                    ]
                }

                do {
                    let settings = GeneralSettings.load()
                    let rulesURLValue = settings.rulesURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard rulesURLValue.isEmpty == false else {
                        throw MagentXError.missingRulesURL
                    }
                    guard let rulesURL = URL(string: rulesURLValue), rulesURL.scheme != nil else {
                        throw MagentXError.invalidRulesURL(rulesURLValue)
                    }

                    let now = Date.now
                    let proxyEndpoint = try PacFileService.ProxyEndpoint(generalSettings: settings)
                    let pacRules = try await AclService.shared.downloadAndImportMagentProxyRules(
                        from: rulesURL,
                        into: modelContext.container,
                        now: now
                    )
                    try PacFileService.writeProxyHostPAC(
                        rules: pacRules,
                        proxyEndpoint: proxyEndpoint,
                        directoryURL: PacFileService.shared.directoryURL
                    )

                    var refreshedSettings = settings
                    refreshedSettings.updatedAt = now
                    refreshedSettings.save()
                    fetchLimit = Self.pageSize
                    search()
                } catch {
                    loadError = error.localizedDescription
                }
            }
        }
    }
}
