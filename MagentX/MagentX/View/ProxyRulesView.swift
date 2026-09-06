//
//  ProxyRulesView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Displays and directly manages persisted proxy rules.
//

import AppKit
import FactoryKit
import Foundation
import Magent
import SwiftData
import SwiftUI

/// 包装原生搜索输入框，在动态加入工具栏后接管键盘焦点并把编辑状态同步回 SwiftUI。
@MainActor
private struct AutoFocusedSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isPresented: Bool
    let onSubmit: () -> Void

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
            parent.onSubmit()
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

/// 代理规则页面，通过初始化、新增、搜索和同步四类页面操作管理规则。
@MainActor
struct ProxyRulesView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Injected(\.localExecutor) private var localExecutor
    @Injected(\.magentProxyRuleService) private var magentProxyRuleService
    @State private var loadError: String?
    @State private var searchQuery = SearchQuery()
    @State private var isRefreshing = false
    @State private var draft: ProxyRuleDraft?
    @State private var pagingResult = ProxyRulesPagingResult(
        persistentIdentifiers: [],
        pageAt: 1,
        pageSize: Self.pageSize,
        canLoadMore: false
    )
    @Binding var toolbarButtons: [ContentToolbarButton]

    private static let pageSize = 50

    /// 表示规则搜索的关键字与工具栏输入框的呈现状态。
    private struct SearchQuery {
        var text = ""
        var isPresented = false

        /// 返回去除首尾空白后的搜索关键字，供查询与空状态文案使用。
        var trimmedSearchText: String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 注入由 `ContentView` 管理的工具栏按钮绑定；规则服务由 Factory 提供并在页面出现时首次查询。
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
            } else {
                RulesTableView(
                    searchQuery: searchQuery.trimmedSearchText,
                    proxyRulesPagingResult: $pagingResult,
                    isRefreshing: $isRefreshing
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                guard searchQuery.isPresented else { return }
                searchQuery.isPresented = false
            }
        )
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, searchQuery.isPresented else { return }
            searchQuery.isPresented = false
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if searchQuery.isPresented {
                    AutoFocusedSearchField(
                        text: $searchQuery.text,
                        isPresented: $searchQuery.isPresented
                    ) {
                        search()
                    }
                        .controlSize(.regular)
                        .frame(width: 220)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button {
                        searchQuery.isPresented = true
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
            if draft.editingRule == nil {
                AddProxyRuleFormView(
                    magentProxyRuleService: magentProxyRuleService,
                    draft: draft,
                    loadError: $loadError,
                    onCancel: {
                        self.draft = nil
                    },
                    onAdded: {
                        self.draft = nil
                        search()
                    }
                )
            } else {
                UpdateProxyRuleFormView(
                    magentProxyRuleService: magentProxyRuleService,
                    draft: draft,
                    loadError: $loadError,
                    onCancel: {
                        self.draft = nil
                    },
                    onUpdated: {
                        self.draft = nil
                        search()
                    }
                )
            }
        }
        .onAppear {
            toolbarButtons = [
                ContentToolbarButton(title: "增加规则", systemImage: "plus") {
                    searchQuery.isPresented = false
                    draft = ProxyRuleDraft(
                        editingRule: nil,
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
        .onAppear {
            search()
        }
    }

    /// 下载订阅规则、合并数据库并重写 PAC，期间同步主窗口工具栏状态。
    private func sync() {
        guard isRefreshing == false else { return }
        searchQuery.isPresented = false

        let now = Date.now
        let magentProxyRuleService = self.magentProxyRuleService
        isRefreshing = true
        toolbarButtons = [
            ContentToolbarButton(title: "增加规则", systemImage: "plus") {
                searchQuery.isPresented = false
                    draft = ProxyRuleDraft(
                        editingRule: nil,
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
                    search()
                case .failure(let error):
                    loadError = error.localizedDescription
                }
                toolbarButtons = [
                    ContentToolbarButton(title: "增加规则", systemImage: "plus") {
                        searchQuery.isPresented = false
                        draft = ProxyRuleDraft(
                            editingRule: nil,
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
        )
    }

    /// 按当前关键字读取第一页规则，或在滚动到表格末尾时读取并追加下一页。
    ///
    /// - Parameter loadMore: 为 `true` 时读取下一页并追加结果；否则从第一页重新开始。
    private func search(loadMore: Bool = false) {
        guard isRefreshing == false,
              loadMore == false || pagingResult.canLoadMore else {
            return
        }

        let keyword = searchQuery.trimmedSearchText
        let pageAt = loadMore ? pagingResult.pageAt + 1 : 1
        let pageSize = Self.pageSize
        let existingPersistentIdentifiers = pagingResult.persistentIdentifiers
        let magentProxyRuleService = self.magentProxyRuleService
        isRefreshing = true
        loadError = nil

        localExecutor.submit(
            priority: .userInitiated,
            operation: {
                try await magentProxyRuleService.search(
                    keyword: keyword,
                    pageAt: pageAt,
                    pageSize: pageSize
                )
            },
            completion: { result in
                isRefreshing = false

                switch result {
                case .success(let searchResult):
                    pagingResult = loadMore
                        ? ProxyRulesPagingResult(
                            persistentIdentifiers: existingPersistentIdentifiers + searchResult.persistentIdentifiers,
                            pageAt: searchResult.pageAt,
                            pageSize: searchResult.pageSize,
                            canLoadMore: searchResult.canLoadMore
                        )
                        : searchResult
                case .failure(let error):
                    if loadMore == false {
                        pagingResult = ProxyRulesPagingResult(
                            persistentIdentifiers: [],
                            pageAt: 1,
                            pageSize: Self.pageSize,
                            canLoadMore: false
                        )
                    }
                    loadError = error.localizedDescription
                }
            }
        )
    }
}

/// 代理规则表格，负责分页展示、编辑和删除当前查询结果。
@MainActor
private struct RulesTableView: View {
    @Environment(\.modelContext) private var modelContext
    @Injected(\.localExecutor) private var localExecutor
    @Injected(\.magentProxyRuleService) private var magentProxyRuleService
    let searchQuery: String
    @Binding var proxyRulesPagingResult: ProxyRulesPagingResult
    @Binding var isRefreshing: Bool
    @State private var loadError: String?
    @State private var draft: ProxyRuleDraft?

    var body: some View {
        let rules = proxyRulesPagingResult.persistentIdentifiers.compactMap { persistentIdentifier in
            modelContext.model(for: persistentIdentifier) as? MagentProxyRule
        }

        Group {
            if isRefreshing, rules.isEmpty {
                ProgressView("正在读取规则")
            } else if let loadError {
                ContentUnavailableView(
                    "规则读取失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if rules.isEmpty {
                ContentUnavailableView(
                    searchQuery.isEmpty ? "暂无规则" : "未找到规则",
                    systemImage: searchQuery.isEmpty ? "arrow.triangle.branch" : "magnifyingglass",
                    description: Text(searchQuery.isEmpty ? "MagentProxyRule 会显示在这里" : searchQuery)
                )
            } else {
                Table(rules) {
                    TableColumn("匹配值") { proxyRule in
                        Text(proxyRule.matchValue)
                            .lineLimit(1)
                            .onAppear {
                                guard proxyRule.id == rules.last?.id,
                                      proxyRulesPagingResult.canLoadMore else {
                                    return
                                }
                                search(loadMore: true)
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
                                    editingRule: proxyRule,
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
                                delete([proxyRule.id])
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $draft) { draft in
            UpdateProxyRuleFormView(
                magentProxyRuleService: magentProxyRuleService,
                draft: draft,
                loadError: $loadError,
                onCancel: {
                    self.draft = nil
                },
                onUpdated: {
                    self.draft = nil
                    search()
                }
            )
        }
    }

    /// 删除指定业务 id 的规则；成功后重新读取当前关键字的第一页。
    ///
    /// - Parameter ids: 待删除规则的唯一整数业务主键。
    private func delete(_ ids: [Int]) {
        guard isRefreshing == false else { return }
        let magentProxyRuleService = self.magentProxyRuleService
        isRefreshing = true
        localExecutor.submit(
            operation: {
                try await magentProxyRuleService.delete(ids)
            },
            completion: { result in
                isRefreshing = false
                switch result {
                case .success:
                    search()
                case .failure(let error):
                    loadError = error.localizedDescription
                }
            }
        )
    }

    /// 按当前搜索关键字读取第一页，或读取下一页并追加其持久化标识。
    ///
    /// - Parameter loadMore: 为 `true` 时读取下一页；否则从第一页重新开始。
    private func search(loadMore: Bool = false) {
        guard isRefreshing == false,
              loadMore == false || proxyRulesPagingResult.canLoadMore else {
            return
        }

        let pageAt = loadMore ? proxyRulesPagingResult.pageAt + 1 : 1
        let pageSize = proxyRulesPagingResult.pageSize
        let existingPersistentIdentifiers = proxyRulesPagingResult.persistentIdentifiers
        let magentProxyRuleService = self.magentProxyRuleService
        isRefreshing = true
        loadError = nil

        localExecutor.submit(
            priority: .userInitiated,
            operation: {
                try await magentProxyRuleService.search(
                    keyword: searchQuery,
                    pageAt: pageAt,
                    pageSize: pageSize
                )
            },
            completion: { result in
                isRefreshing = false

                switch result {
                case .success(let searchResult):
                    proxyRulesPagingResult = loadMore
                        ? ProxyRulesPagingResult(
                            persistentIdentifiers: existingPersistentIdentifiers + searchResult.persistentIdentifiers,
                            pageAt: searchResult.pageAt,
                            pageSize: searchResult.pageSize,
                            canLoadMore: searchResult.canLoadMore
                        )
                        : searchResult
                case .failure(let error):
                    if loadMore == false {
                        proxyRulesPagingResult = ProxyRulesPagingResult(
                            persistentIdentifiers: [],
                            pageAt: 1,
                            pageSize: pageSize,
                            canLoadMore: false
                        )
                    }
                    loadError = error.localizedDescription
                }
            }
        )
    }
}

/// 新增代理规则表单，使用本地草稿创建批量规则并在成功后通知父页面刷新。
@MainActor
private struct AddProxyRuleFormView: View {
    @Injected(\.localExecutor) private var localExecutor
    let magentProxyRuleService: MagentProxyRuleService
    @State var draft: ProxyRuleDraft
    @Binding var loadError: String?
    let onCancel: () -> Void
    let onAdded: () -> Void

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

                    Button("添加", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.matchValues.isEmpty)
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 将当前新增草稿提交给规则服务；成功时通知父页面结束表单，失败时写入页面错误状态。
    private func add() {
        guard draft.editingRule == nil else { return }
        let now = Date.now
        let firstID = Int(now.timeIntervalSince1970 * 1_000_000)
        let rules = draft.matchValues.enumerated().map { offset, matchValue in
            MagentProxyRuleInput(
                id: firstID + offset,
                matchType: draft.matchType,
                matchValue: matchValue,
                decision: draft.decision,
                order: 0,
                source: "user",
                createdAt: now,
                updatedAt: now
            )
        }
        let magentProxyRuleService = self.magentProxyRuleService
        localExecutor.submit(
            operation: {
                try await magentProxyRuleService.batchInsert(rules)
            },
            completion: { result in
                switch result {
                case .success:
                    onAdded()
                case .failure(let error):
                    loadError = error.localizedDescription
                }
            }
        )
    }
}

/// 编辑代理规则表单，使用本地草稿修改匹配类型和动作并在确认后提交。
@MainActor
private struct UpdateProxyRuleFormView: View {
    @Injected(\.localExecutor) private var localExecutor
    let magentProxyRuleService: MagentProxyRuleService
    @State var draft: ProxyRuleDraft
    @Binding var loadError: String?
    let onCancel: () -> Void
    let onUpdated: () -> Void

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

                    Button("保存", action: update)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 将编辑后的草稿直接提交给规则服务；成功后通知父页面刷新，失败时写入页面错误状态。
    private func update() {
        guard let editingRule = draft.editingRule else { return }
        let rule = MagentProxyRuleInput(
            id: editingRule.id,
            matchType: draft.matchType,
            matchValue: editingRule.matchValue,
            decision: draft.decision,
            order: editingRule.order,
            source: "user",
            createdAt: editingRule.createdAt
        )
        let magentProxyRuleService = self.magentProxyRuleService
        localExecutor.submit(
            operation: {
                try await magentProxyRuleService.insert(rule)
            },
            completion: { result in
                switch result {
                case .success:
                    onUpdated()
                case .failure(let error):
                    loadError = error.localizedDescription
                }
            }
        )
    }
}
