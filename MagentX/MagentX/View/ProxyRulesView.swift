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
}

/// 在加入 `NSWindow` 后兑现一次待处理的 first-responder 请求。
@MainActor
private final class FocusRequestingSearchField: NSSearchField {
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
    @State private var isAddingRules = false
    @State private var fetchLimit = Self.pageSize
    @State private var newMatchType = MatchType.domainSuffix
    @State private var newDecision = RuleDecision.proxy
    @State private var newMatchValuesText = ""
    @State private var isEditingRule = false
    @State private var editingRuleID = 0
    @State private var editingMatchType = MatchType.domainSuffix
    @State private var editingDecision = RuleDecision.proxy
    @Binding var toolbarButtons: [ContentToolbarButton]

    private static let pageSize = 50

    /// 去除首尾空白后的搜索关键字。
    private var trimmedSearchText: String {
        submittedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
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
        .sheet(isPresented: $isAddingRules) {
            addRulesSheet
        }
        .sheet(isPresented: $isEditingRule) {
            editRuleSheet
        }
        .onAppear {
            toolbarButtons = [
                ContentToolbarButton(title: "增加规则", systemImage: "plus") {
                    isSearchPresented = false
                    isAddingRules = true
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
            .width(min: 180, ideal: 300)

            TableColumn("类型") { proxyRule in
                Text(proxyRule.matchType.rawValue)
            }
            .width(min: 80, ideal: 100)

            TableColumn("顺序") { proxyRule in
                Text(proxyRule.order, format: .number)
            }
            .width(min: 60, ideal: 100)

            TableColumn("来源") { proxyRule in
                Text(proxyRule.source.isEmpty ? "-" : proxyRule.source)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 100)

            TableColumn("规则") { proxyRule in
                Text(proxyRule.decision.rawValue.uppercased())
            }
            .width(min: 70, ideal: 100)

            TableColumn("操作") { proxyRule in
                ControlGroup {
                    Button {
                        editingRuleID = proxyRule.id
                        editingMatchType = proxyRule.matchType
                        editingDecision = proxyRule.decision
                        isEditingRule = true
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
            .width(min: 120, ideal: 200)
        }
    }

    /// 展示批量新增规则表单，并在提交成功后清空输入并关闭 Sheet。
    private var addRulesSheet: some View {
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
                    .buttonStyle(.glass)

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
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 420)
    }

    /// 展示规则编辑表单，并用规则 id 提交匹配类型和动作。
    private var editRuleSheet: some View {
        Form {
            Section {
                Picker("匹配类型", selection: $editingMatchType) {
                    ForEach(MatchType.allCases, id: \.rawValue) { matchType in
                        Text(matchType.rawValue)
                            .tag(matchType)
                    }
                }
                .pickerStyle(.menu)

                Picker("动作", selection: $editingDecision) {
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
                    Button("取消", role: .cancel) {
                        isEditingRule = false
                    }
                    .buttonStyle(.glass)

                    Button("保存") {
                        if update(
                            id: editingRuleID,
                            matchType: editingMatchType,
                            decision: editingDecision
                        ) {
                            isEditingRule = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 420)
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
    private func update(
        id: Int,
        matchType: MatchType,
        decision: RuleDecision
    ) -> Bool {
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
        isRefreshing = true
        toolbarButtons = [
            ContentToolbarButton(title: "增加规则", systemImage: "plus") {
                isSearchPresented = false
                isAddingRules = true
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

        Task {
            defer {
                isRefreshing = false
                toolbarButtons = [
                    ContentToolbarButton(title: "增加规则", systemImage: "plus") {
                        isSearchPresented = false
                        isAddingRules = true
                    },
                    ContentToolbarButton(
                        title: "同步规则",
                        systemImage: "arrow.clockwise"
                    ) {
                        sync()
                    }
                ]
            }

            do {
                let settings = GeneralSettings.load()
                let now = Date.now
                let proxyEndpoint = try PacFileService.ProxyEndpoint(generalSettings: settings)
                let modelContainer = modelContext.container
                let ruleService = MagentProxyRuleService(modelContainer: modelContainer)
                guard await ruleService.syncRuleFromUrl() else {
                    throw MagentXError.proxyRuleSynchronizationFailed
                }
                let pacDirectoryURL = PacFileService.shared.directoryURL
                _ = try await Task.detached(priority: .utility) {
                    let pacModelContext = ModelContext(modelContainer)
                    let proxyRules = try pacModelContext.fetch(FetchDescriptor<MagentProxyRule>())
                    let pacRules = proxyRules.map { proxyRule in
                        PacFileService.Rule(
                            matchType: proxyRule.matchType,
                            matchValue: proxyRule.matchValue,
                            decision: proxyRule.decision.rawValue,
                            order: proxyRule.order
                        )
                    }
                    try PacFileService.writeProxyHostPAC(
                        rules: pacRules,
                        proxyEndpoint: proxyEndpoint,
                        directoryURL: pacDirectoryURL
                    )
                }.value

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
