//
//  ProxyRulesView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Displays and directly manages persisted proxy rules.
//

import AppKit
import Foundation
import Magent
import SwiftData
import SwiftUI

/// 包装原生搜索输入框，在动态加入工具栏后接管键盘焦点并把编辑状态同步回 SwiftUI。
@MainActor
private struct AutoFocusedSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isPresented: Bool
    let onSubmit: (String) -> Void

    /// 创建负责 AppKit 委托与提交动作转发的协调器。
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// 创建原生搜索框；焦点请求会在控件真正进入窗口时执行。
    func makeNSView(context: Context) -> FocusRequestingSearchField {
        let searchField = FocusRequestingSearchField()
        searchField.placeholderString = String(localized: "搜索")
        searchField.sendsWholeSearchString = true
        searchField.delegate = context.coordinator
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.submit(_:))
        searchField.setFocusRequested(isPresented)
        return searchField
    }

    /// 把最新 SwiftUI 文本与展开状态同步到现有 AppKit 搜索框。
    func updateNSView(_ searchField: FocusRequestingSearchField, context: Context) {
        context.coordinator.parent = self
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
        searchField.setFocusRequested(isPresented)
    }

    /// 连接 `NSSearchField` 的输入、失焦和提交事件与 SwiftUI 状态。
    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: AutoFocusedSearchField

        /// 保存当前 representable，以便委托回调写回对应绑定。
        init(parent: AutoFocusedSearchField) {
            self.parent = parent
        }

        /// 输入变化时立即更新 SwiftUI 持有的搜索文本。
        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            parent.text = searchField.stringValue
        }

        /// 编辑结束表示输入框已经失焦，通知页面收回为放大镜按钮。
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            parent.text = searchField.stringValue
            parent.isPresented = false
        }

        /// 用户按下回车或点击搜索图标时提交当前搜索文本。
        @objc func submit(_ searchField: NSSearchField) {
            parent.text = searchField.stringValue
            parent.onSubmit(searchField.stringValue)
        }
    }

    /// 在加入 `NSWindow` 后兑现一次待处理的 first-responder 请求。
    @MainActor
    final class FocusRequestingSearchField: NSSearchField {
        private var isFocusRequested = false

        /// 记录焦点目标；如果控件已进入窗口则立即把它设为 first responder。
        func setFocusRequested(_ isRequested: Bool) {
            isFocusRequested = isRequested
            guard isRequested else { return }
            focusIfPossible()
        }

        /// 控件进入或离开窗口后重新检查尚未兑现的焦点请求。
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard isFocusRequested else { return }
            focusIfPossible()
        }

        /// 在窗口可用且当前尚未编辑时，让原生搜索框接管键盘输入。
        private func focusIfPossible() {
            guard let window else { return }
            if let editor = currentEditor(), window.firstResponder === editor {
                return
            }
            window.makeFirstResponder(self)
        }
    }
}

/// 代理规则页面，通过初始化、新增、删除、搜索、更新和同步六类页面操作管理 `MagentProxyRule`。
@MainActor
struct ProxyRulesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var proxyRules: [MagentProxyRule] = []
    @State private var searchText = ""
    @State private var submittedSearchText = ""
    @State private var isSearchPresented = false
    @State private var loadError: String?
    @State private var canLoadMore = false
    @State private var isRefreshing = false
    @State private var draft: ProxyRuleDraft?
    @State private var fetchLimit = Self.pageSize
    @Binding var toolbarButtons: [ContentToolbarButton]

    private static let pageSize = 50

    /// 去除首尾空白后的搜索关键字。
    private var trimmedSearchText: String {
        submittedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
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
                rulesTable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                guard isSearchPresented else { return }
                isSearchPresented = false
            }
        )
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, isSearchPresented else { return }
            isSearchPresented = false
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isSearchPresented {
                    AutoFocusedSearchField(
                        text: $searchText,
                        isPresented: $isSearchPresented
                    ) { submittedText in
                        submittedSearchText = submittedText
                        fetchLimit = Self.pageSize
                        search()
                    }
                        .controlSize(.regular)
                        .frame(width: 220)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button {
                        isSearchPresented = true
                    } label: {
                        Label("搜索规则", systemImage: "magnifyingglass")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .help("搜索规则")
                }
            }
        }
        .sheet(item: $draft) { draft in
            if draft.editingRuleID == nil {
                AddProxyRuleFormView(
                    draft: draft,
                    onCancel: {
                        self.draft = nil
                    },
                    onSave: { draft in
                        if add(draft) {
                            self.draft = nil
                        }
                    }
                )
            } else {
                UpdateProxyRuleFormView(
                    draft: draft,
                    onCancel: {
                        self.draft = nil
                    },
                    onSave: { draft in
                        if update(draft) {
                            self.draft = nil
                        }
                    }
                )
            }
        }
        .onAppear {
            toolbarButtons = [
                ContentToolbarButton(title: "增加规则", systemImage: "plus") {
                    isSearchPresented = false
                    draft = ProxyRuleDraft(
                        editingRuleID: nil,
                        matchType: .domainSuffix,
                        matchValuesText: "",
                        decision: .proxy
                    )
                },
                ContentToolbarButton(
                    title: "同步规则",
                    systemImage: "arrow.clockwise"
                ) {
                    sync()
                }
            ]
        }
        .task {
            search()
        }
    }

    /// 展示规则列表，并在末行出现时继续加载下一页。
    private var rulesTable: some View {
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
            .width(min: 64, ideal: 280)

            TableColumn("类型") { proxyRule in
                Text(proxyRule.matchType.rawValue)
                    .lineLimit(1)
            }
            .width(min: 44, ideal: 80, max: 110)

            TableColumn("顺序") { proxyRule in
                Text(proxyRule.order, format: .number)
                    .lineLimit(1)
            }
            .width(min: 40, ideal: 56, max: 72)

            TableColumn("来源") { proxyRule in
                Text(proxyRule.source.isEmpty ? "-" : proxyRule.source)
                    .lineLimit(1)
            }
            .width(min: 44, ideal: 76, max: 100)

            TableColumn("规则") { proxyRule in
                Text(proxyRule.decision.rawValue.uppercased())
                    .lineLimit(1)
            }
            .width(min: 44, ideal: 64, max: 84)

            TableColumn("操作") { proxyRule in
                ControlGroup {
                    Button {
                        draft = ProxyRuleDraft(
                            editingRuleID: proxyRule.id,
                            matchType: proxyRule.matchType,
                            matchValuesText: proxyRule.matchValue,
                            decision: proxyRule.decision
                        )
                    } label: {
                        Label("编辑规则", systemImage: "pencil")
                            .labelStyle(.iconOnly)
                    }
                    .help("编辑规则")
                    .buttonStyle(.glass)

                    Button(role: .destructive) {
                        delete(proxyRule)
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
    }

    /// 新增一批手工代理规则，完成输入清理、重复校验、持久化和列表刷新。
    private func add(_ draft: ProxyRuleDraft) -> Bool {
        guard draft.editingRuleID == nil else { return false }
        let matchType = draft.matchType
        let decision = draft.decision
        var seenMatchValues = Set<String>()
        let uniqueMatchValues: [String] = draft.matchValues.compactMap { matchValue in
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
                    source: "user",
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

    /// 按业务 id 更新规则的匹配类型和动作，并把界面修改来源标记为 `user`。
    private func update(_ draft: ProxyRuleDraft) -> Bool {
        guard let id = draft.editingRuleID else { return false }
        let matchType = draft.matchType
        let decision = draft.decision
        do {
            let existingRules = try modelContext.fetch(FetchDescriptor<MagentProxyRule>())
            guard let proxyRule = existingRules.first(where: { $0.id == id }) else {
                throw MagentXError.missingMagentProxyRule(id)
            }
            guard existingRules.contains(where: {
                $0.id != id && $0.matchType == matchType && $0.matchValue == proxyRule.matchValue
            }) == false else {
                throw MagentXError.duplicateMagentProxyRule
            }

            let previousMatchType = proxyRule.matchType
            let previousDecision = proxyRule.decision
            let previousSource = proxyRule.source
            let previousUpdatedAt = proxyRule.updatedAt
            proxyRule.matchType = matchType
            proxyRule.decision = decision
            proxyRule.source = "user"
            proxyRule.updatedAt = .now

            do {
                try modelContext.save()
            } catch {
                proxyRule.matchType = previousMatchType
                proxyRule.decision = previousDecision
                proxyRule.source = previousSource
                proxyRule.updatedAt = previousUpdatedAt
                throw error
            }

            search()
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    /// 下载订阅规则、合并数据库并重写 PAC，期间同步主窗口工具栏状态。
    private func sync() {
        guard isRefreshing == false else { return }
        isSearchPresented = false

        let now = Date.now
        let modelContainer = modelContext.container
        let executor = MagentXAsyncExecutor.shared

        isRefreshing = true
        toolbarButtons = [
            ContentToolbarButton(title: "增加规则", systemImage: "plus") {
                isSearchPresented = false
                draft = ProxyRuleDraft(
                    editingRuleID: nil,
                    matchType: .domainSuffix,
                    matchValuesText: "",
                    decision: .proxy
                )
            },
            ContentToolbarButton(
                title: "正在同步规则",
                systemImage: "hourglass",
                isLoading: true,
                isDisabled: true
            ) {
                sync()
            }
        ]

        executor.submit(
            priority: .utility,
            operation: {
                let ruleService = MagentProxyRuleService(modelContainer: modelContainer)
                try await ruleService.syncRuleFromUrl()
            },
            completion: { result in
                isRefreshing = false
                toolbarButtons = [
                    ContentToolbarButton(title: "增加规则", systemImage: "plus") {
                        isSearchPresented = false
                        draft = ProxyRuleDraft(
                            editingRuleID: nil,
                            matchType: .domainSuffix,
                            matchValuesText: "",
                            decision: .proxy
                        )
                    },
                    ContentToolbarButton(
                        title: "同步规则",
                        systemImage: "arrow.clockwise"
                    ) {
                        sync()
                    }
                ]

                switch result {
                case .success:
                    var refreshedSettings = GeneralSettings.load()
                    refreshedSettings.updatedAt = now
                    refreshedSettings.save()
                    fetchLimit = Self.pageSize
                    search()
                case .failure(let error):
                    loadError = error.localizedDescription
                }
            }
        )
    }
}

/// 新增代理规则表单，使用本地草稿编辑批量匹配值并在确认后提交。
private struct AddProxyRuleFormView: View {
    @State var draft: ProxyRuleDraft
    let onCancel: () -> Void
    let onSave: (ProxyRuleDraft) -> Void

    var body: some View {
        Form {
            Section {
                Picker("匹配类型", selection: $draft.matchType) {
                    ForEach(MatchType.allCases, id: \.rawValue) { matchType in
                        Text(matchType.rawValue)
                            .tag(matchType)
                    }
                }
                .pickerStyle(.menu)

                Picker("动作", selection: $draft.decision) {
                    Text("DIRECT").tag(RuleDecision.direct)
                    Text("PROXY").tag(RuleDecision.proxy)
                }
                .pickerStyle(.menu)
            } header: {
                Text("增加规则")
                    .font(.title3.weight(.semibold))
            }

            Section("MatchValue") {
                TextEditor(text: $draft.matchValuesText)
                    .frame(minHeight: 160)
            }

            Section {
                ControlGroup {
                    Button("取消", role: .cancel, action: onCancel)
                        .buttonStyle(.glass)

                    Button("添加") {
                        onSave(draft)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.matchValues.isEmpty)
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// 编辑代理规则表单，使用本地草稿修改匹配类型和动作并在确认后提交。
private struct UpdateProxyRuleFormView: View {
    @State var draft: ProxyRuleDraft
    let onCancel: () -> Void
    let onSave: (ProxyRuleDraft) -> Void

    var body: some View {
        Form {
            Section {
                Picker("匹配类型", selection: $draft.matchType) {
                    ForEach(MatchType.allCases, id: \.rawValue) { matchType in
                        Text(matchType.rawValue)
                            .tag(matchType)
                    }
                }
                .pickerStyle(.menu)

                Picker("动作", selection: $draft.decision) {
                    Text("DIRECT").tag(RuleDecision.direct)
                    Text("PROXY").tag(RuleDecision.proxy)
                }
                .pickerStyle(.menu)
            } header: {
                Text("编辑规则")
                    .font(.title3.weight(.semibold))
            }

            Section {
                ControlGroup {
                    Button("取消", role: .cancel, action: onCancel)
                        .buttonStyle(.glass)

                    Button("保存") {
                        onSave(draft)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .formStyle(.grouped)
    }
}
