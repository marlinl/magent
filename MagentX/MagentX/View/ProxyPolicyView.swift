//
//  ProxyPolicyView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Manages proxy policies and optional rule-policy associations.
//

import AppKit
import SwiftData
import SwiftUI

/// 代理策略页面，在自适应双列表格中管理规则归属和代理策略。
@MainActor
struct ProxyPolicyView: View {
  @Environment(\.modelContext) private var modelContext
  @Binding var toolbarButtons: [ContentToolbarButton]
  @State private var searchText = ""
  @State private var pageAt = 1
  @State private var selectedRuleIDs: Set<Int> = []
  @State private var selectedPolicyIDs: Set<Int> = []
  @State private var proxyPolicyViewModel: ProxyPolicyViewModel?
  @State private var formError: String?

  private static let pageSize = 100
  private static let maximumCachedModelCount = pageSize + 1

  var body: some View {
    let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

    HSplitView {
      ProxyPolicyRulePageView(
        searchText: normalizedSearchText,
        pageAt: $pageAt,
        pageSize: Self.pageSize,
        maximumCachedModelCount: Self.maximumCachedModelCount,
        selectedRuleIDs: $selectedRuleIDs
      )
      .id(normalizedSearchText)
      .frame(
        minWidth: 520,
        idealWidth: 760,
        maxWidth: .infinity,
        maxHeight: .infinity
      )
      .layoutPriority(2)

      ProxyPolicyTableView(
        maximumCachedModelCount: Self.maximumCachedModelCount,
        selectedPolicyIDs: $selectedPolicyIDs,
        proxyPolicyViewModel: $proxyPolicyViewModel
      )
      .frame(
        minWidth: 280,
        idealWidth: 360,
        maxWidth: .infinity,
        maxHeight: .infinity
      )
      .layoutPriority(1)
    }
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
    .sheet(item: $proxyPolicyViewModel) { viewModel in
      ProxyPolicyFormView(
        proxyPolicyViewModel: viewModel,
        onSaved: { policyID in
          selectedPolicyIDs.insert(policyID)
        }
      )
    }
    .alert(
      "打开策略表单失败",
      isPresented: Binding(
        get: { formError != nil },
        set: { isPresented in
          if isPresented == false {
            formError = nil
          }
        }
      )
    ) {
      Button("好", role: .cancel) {
        formError = nil
      }
    } message: {
      Text(formError ?? "")
    }
    .onAppear {
      toolbarButtons = [
        ContentToolbarButton(title: "增加策略", systemImage: "plus") {
          do {
            proxyPolicyViewModel = try ProxyPolicyViewModel(
              modelContainer: modelContext.container
            )
            formError = nil
          } catch {
            formError = error.localizedDescription
          }
        }
      ]
    }
  }

  /// 观察当前规则页和策略集合，并提供平台对应的分页交互。
  private struct ProxyPolicyRulePageView: View {
    @Query private var rules: [MagentProxyRule]
    @Query private var policies: [MagentProxyPolicy]
    @Binding private var pageAt: Int
    @Binding private var selectedRuleIDs: Set<Int>
    @State private var associationError: String?

    private let searchText: String
    private let pageSize: Int

    /// 创建按规则 id 分页、按策略名称排序且数量有上限的 SwiftData 查询。
    init(
      searchText: String,
      pageAt: Binding<Int>,
      pageSize: Int,
      maximumCachedModelCount: Int,
      selectedRuleIDs: Binding<Set<Int>>
    ) {
      precondition(pageAt.wrappedValue >= 1, "pageAt must start at 1")
      precondition(pageSize > 0, "pageSize must be greater than 0")
      precondition(
        maximumCachedModelCount == pageSize + 1,
        "maximumCachedModelCount must include one lookahead model"
      )

      let ruleSortDescriptors = [SortDescriptor(\MagentProxyRule.id, order: .forward)]
      var ruleDescriptor: FetchDescriptor<MagentProxyRule>
      if searchText.isEmpty {
        ruleDescriptor = FetchDescriptor<MagentProxyRule>(sortBy: ruleSortDescriptors)
      } else {
        let query = searchText
        ruleDescriptor = FetchDescriptor<MagentProxyRule>(
          predicate: #Predicate<MagentProxyRule> { rule in
            rule.matchValue.contains(query)
          },
          sortBy: ruleSortDescriptors
        )
      }
      ruleDescriptor.fetchLimit = maximumCachedModelCount
      ruleDescriptor.fetchOffset = (pageAt.wrappedValue - 1) * pageSize
      _rules = Query(ruleDescriptor)

      var policyDescriptor = FetchDescriptor<MagentProxyPolicy>(
        sortBy: [
          SortDescriptor(\MagentProxyPolicy.name, order: .forward),
          SortDescriptor(\MagentProxyPolicy.id, order: .forward),
        ]
      )
      policyDescriptor.fetchLimit = maximumCachedModelCount
      _policies = Query(policyDescriptor)

      _pageAt = pageAt
      _selectedRuleIDs = selectedRuleIDs
      self.searchText = searchText
      self.pageSize = pageSize
    }

    var body: some View {
      Group {
        if rules.isEmpty {
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
          ProxyPolicyScrollingRuleTable(
            rules: rules,
            policies: policies,
            pageAt: $pageAt,
            pageSize: pageSize,
            selectedRuleIDs: $selectedRuleIDs,
            associationError: $associationError
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .alert(
        "更新代理策略失败",
        isPresented: Binding(
          get: { associationError != nil },
          set: { isPresented in
            if isPresented == false {
              associationError = nil
            }
          }
        )
      ) {
        Button("好", role: .cancel) {
          associationError = nil
        }
      } message: {
        Text(associationError ?? "")
      }
    }
  }

  /// 通过原生表格滚动到顶部或底部切换规则页。
  private struct ProxyPolicyScrollingRuleTable: View {
    let rules: [MagentProxyRule]
    let policies: [MagentProxyPolicy]
    @Binding var pageAt: Int
    let pageSize: Int
    @Binding var selectedRuleIDs: Set<Int>
    @Binding var associationError: String?
    @State private var requestedPageAt: Int?
    @State private var requestedScrollEdge: ProxyPolicyTableScrollEdge?
    @State private var scrollRequest: ProxyPolicyTableScrollRequest?
    @State private var canUnlockRequestedPage = false

    var body: some View {
      let visibleRules = Array(rules.prefix(pageSize))

      Table(visibleRules, selection: $selectedRuleIDs) {
        TableColumn("匹配值") { rule in
          Text(rule.matchValue)
            .lineLimit(1)
        }
        .width(min: 120, ideal: 300)

        TableColumn("类型") { rule in
          Text(rule.matchType)
            .lineLimit(1)
        }
        .width(min: 80, ideal: 120, max: 160)

        TableColumn("规则") { rule in
          Text(rule.decision)
            .lineLimit(1)
        }
        .width(min: 70, ideal: 90, max: 120)

        TableColumn("策略") { rule in
          ProxyPolicyPickerView(
            ruleID: rule.id,
            policies: policies,
            associationError: $associationError
          )
        }
        .width(min: 140, ideal: 220)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background {
        ProxyPolicyTableScrollObserver(scrollRequest: scrollRequest) { boundary in
          if requestedPageAt != nil {
            if canUnlockRequestedPage, boundary == .middle {
              requestedPageAt = nil
              requestedScrollEdge = nil
              canUnlockRequestedPage = false
            }
            return
          }

          switch boundary {
          case .top where pageAt > 1:
            let targetPageAt = pageAt - 1
            canUnlockRequestedPage = false
            requestedPageAt = targetPageAt
            requestedScrollEdge = .bottom
            pageAt = targetPageAt
          case .bottom where rules.count > pageSize:
            let targetPageAt = pageAt + 1
            canUnlockRequestedPage = false
            requestedPageAt = targetPageAt
            requestedScrollEdge = .top
            pageAt = targetPageAt
          default:
            break
          }
        }
      }
      .onChange(of: rules.first?.id) { _, _ in
        guard let requestedScrollEdge else { return }
        scrollRequest = ProxyPolicyTableScrollRequest(
          pageAt: pageAt,
          edge: requestedScrollEdge
        )
        let targetPageAt = requestedPageAt
        Task { @MainActor in
          do {
            try await Task.sleep(for: .milliseconds(350))
          } catch {
            return
          }
          guard self.requestedPageAt == targetPageAt else { return }
          canUnlockRequestedPage = true
        }
      }
    }
  }

  private enum ProxyPolicyTableScrollBoundary: Equatable {
    case top
    case middle
    case bottom
  }

  private enum ProxyPolicyTableScrollEdge: Equatable {
    case top
    case bottom
  }

  private struct ProxyPolicyTableScrollRequest: Equatable {
    let pageAt: Int
    let edge: ProxyPolicyTableScrollEdge
  }

  /// 观察 SwiftUI Table 内部原生滚动区，并在分页后恢复到指定边界。
  private struct ProxyPolicyTableScrollObserver: NSViewRepresentable {
    let scrollRequest: ProxyPolicyTableScrollRequest?
    let onBoundary: (ProxyPolicyTableScrollBoundary) -> Void

    func makeCoordinator() -> Coordinator {
      Coordinator(onBoundary: onBoundary)
    }

    func makeNSView(context: Context) -> ProbeView {
      let view = ProbeView()
      view.coordinator = context.coordinator
      return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
      context.coordinator.onBoundary = onBoundary
      context.coordinator.scrollRequest = scrollRequest
      context.coordinator.attach(from: nsView)
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: Coordinator) {
      coordinator.stopObserving()
    }

    final class ProbeView: NSView {
      weak var coordinator: Coordinator?

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.attach(from: self)
      }

      override func layout() {
        super.layout()
        coordinator?.attach(from: self)
      }
    }

    @MainActor
    final class Coordinator: NSObject {
      var onBoundary: (ProxyPolicyTableScrollBoundary) -> Void
      var scrollRequest: ProxyPolicyTableScrollRequest? {
        didSet {
          applyScrollRequestIfNeeded()
        }
      }

      private weak var scrollView: NSScrollView?
      private var appliedScrollRequest: ProxyPolicyTableScrollRequest?
      private var reportedBoundary: ProxyPolicyTableScrollBoundary?

      init(onBoundary: @escaping (ProxyPolicyTableScrollBoundary) -> Void) {
        self.onBoundary = onBoundary
      }

      func attach(from probeView: NSView) {
        guard let candidate = findTableScrollView(containing: probeView) else { return }
        if scrollView !== candidate {
          stopObserving()
          scrollView = candidate
          candidate.contentView.postsBoundsChangedNotifications = true
          NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: candidate.contentView
          )
        }
        applyScrollRequestIfNeeded()
      }

      func stopObserving() {
        NotificationCenter.default.removeObserver(
          self,
          name: NSView.boundsDidChangeNotification,
          object: scrollView?.contentView
        )
        scrollView = nil
        reportedBoundary = nil
      }

      @objc private func scrollBoundsDidChange(_ notification: Notification) {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentBounds = documentView.bounds
        let boundary: ProxyPolicyTableScrollBoundary

        if visibleRect.minY <= documentBounds.minY + 1 {
          boundary = .top
        } else if visibleRect.maxY >= documentBounds.maxY - 1 {
          boundary = .bottom
        } else {
          boundary = .middle
        }
        guard boundary != reportedBoundary else { return }
        reportedBoundary = boundary
        onBoundary(boundary)
      }

      private func applyScrollRequestIfNeeded() {
        guard let scrollRequest, scrollRequest != appliedScrollRequest,
          let scrollView, scrollView.documentView != nil
        else {
          return
        }
        appliedScrollRequest = scrollRequest

        Task { @MainActor [weak self] in
          do {
            try await Task.sleep(for: .milliseconds(50))
          } catch {
            return
          }
          guard self?.appliedScrollRequest == scrollRequest else { return }
          self?.scroll(to: scrollRequest)
        }
      }

      private func scroll(to scrollRequest: ProxyPolicyTableScrollRequest) {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        let documentBounds = documentView.bounds
        let targetRect: NSRect =
          switch scrollRequest.edge {
          case .top:
            NSRect(
              x: documentBounds.minX,
              y: documentBounds.minY,
              width: 1,
              height: 1
            )
          case .bottom:
            NSRect(
              x: documentBounds.minX,
              y: max(documentBounds.minY, documentBounds.maxY - 1),
              width: 1,
              height: 1
            )
          }
        documentView.scrollToVisible(targetRect)
        scrollView.reflectScrolledClipView(scrollView.contentView)
      }

      private func findTableScrollView(containing probeView: NSView) -> NSScrollView? {
        guard let contentView = probeView.window?.contentView else { return nil }
        let probeCenter = probeView.convert(
          NSPoint(x: probeView.bounds.midX, y: probeView.bounds.midY),
          to: nil
        )
        var candidates: [NSScrollView] = []

        func collectCandidates(in view: NSView) {
          if let scrollView = view as? NSScrollView,
            scrollView.documentView != nil,
            scrollView.convert(scrollView.bounds, to: nil).contains(probeCenter)
          {
            candidates.append(scrollView)
          }
          for subview in view.subviews {
            collectCandidates(in: subview)
          }
        }

        collectCandidates(in: contentView)
        return candidates.min { lhs, rhs in
          lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
        }
      }
    }
  }

  /// 观察单条规则的可选策略关联，并在用户选择时持久化关系。
  private struct ProxyPolicyPickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var policyRules: [MagentProxyPolicyRule]
    let policies: [MagentProxyPolicy]
    @Binding var associationError: String?
    private let ruleID: Int

    /// 创建只观察指定规则关联记录的 SwiftData 查询。
    init(
      ruleID: Int,
      policies: [MagentProxyPolicy],
      associationError: Binding<String?>
    ) {
      let targetRuleID = ruleID
      var descriptor = FetchDescriptor<MagentProxyPolicyRule>(
        predicate: #Predicate<MagentProxyPolicyRule> { policyRule in
          policyRule.ruleID == targetRuleID
        }
      )
      descriptor.fetchLimit = 1
      _policyRules = Query(descriptor)
      self.policies = policies
      _associationError = associationError
      self.ruleID = ruleID
    }

    var body: some View {
      let policyRule = policyRules.first
      let policyIDs = Set(policies.map(\.id))

      Picker(
        "策略",
        selection: Binding<Int?>(
          get: {
            guard let policyRule, policyIDs.contains(policyRule.policyID) else {
              return nil
            }
            return policyRule.policyID
          },
          set: { policyID in
            if policyRule?.policyID == policyID {
              return
            }

            do {
              switch (policyRule, policyID) {
              case (.some(let policyRule), .some(let policyID)):
                policyRule.policyID = policyID
                policyRule.updatedAt = .now
              case (.some(let policyRule), .none):
                modelContext.delete(policyRule)
              case (.none, .some(let policyID)):
                modelContext.insert(
                  MagentProxyPolicyRule(policyID: policyID, ruleID: ruleID)
                )
              case (.none, .none):
                return
              }

              try modelContext.save()
              associationError = nil
            } catch {
              modelContext.rollback()
              associationError = error.localizedDescription
            }
          }
        )
      ) {
        Text("未选择")
          .tag(nil as Int?)

        ForEach(policies) { policy in
          Text(policy.name)
            .tag(policy.id as Int?)
        }
      }
      .labelsHidden()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// 展示现有代理策略，并提供修改和级联删除操作。
  private struct ProxyPolicyTableView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var policies: [MagentProxyPolicy]
    @Binding private var selectedPolicyIDs: Set<Int>
    @Binding private var proxyPolicyViewModel: ProxyPolicyViewModel?
    @State private var actionError: String?

    /// 创建按名称和 id 稳定排序且数量有上限的策略查询。
    init(
      maximumCachedModelCount: Int,
      selectedPolicyIDs: Binding<Set<Int>>,
      proxyPolicyViewModel: Binding<ProxyPolicyViewModel?>
    ) {
      precondition(maximumCachedModelCount > 0, "maximumCachedModelCount must be positive")

      var descriptor = FetchDescriptor<MagentProxyPolicy>(
        sortBy: [
          SortDescriptor(\MagentProxyPolicy.name, order: .forward),
          SortDescriptor(\MagentProxyPolicy.id, order: .forward),
        ]
      )
      descriptor.fetchLimit = maximumCachedModelCount
      _policies = Query(descriptor)
      _selectedPolicyIDs = selectedPolicyIDs
      _proxyPolicyViewModel = proxyPolicyViewModel
    }

    var body: some View {
      Group {
        if policies.isEmpty {
          ContentUnavailableView(
            "暂无代理策略",
            systemImage: "arrow.triangle.branch",
            description: Text("点击工具栏的增加策略按钮后会显示在这里")
          )
        } else {
          Table(policies, selection: $selectedPolicyIDs) {
            TableColumn("名称") { policy in
              Text(policy.name)
                .lineLimit(1)
            }
            .width(min: 100, ideal: 160)

            TableColumn("节点 ID") { policy in
              Text(policy.nodeID.uuidString)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .width(min: 120, ideal: 220)

            TableColumn("操作") { policy in
              Menu {
                Button {
                  do {
                    proxyPolicyViewModel = try ProxyPolicyViewModel(
                      modelContainer: modelContext.container,
                      policyID: policy.id
                    )
                    actionError = nil
                  } catch {
                    actionError = error.localizedDescription
                  }
                } label: {
                  Label("编辑策略", systemImage: "pencil")
                }

                Button(role: .destructive) {
                  do {
                    let targetPolicyID = policy.id
                    let descriptor = FetchDescriptor<MagentProxyPolicyRule>(
                      predicate: #Predicate<MagentProxyPolicyRule> { policyRule in
                        policyRule.policyID == targetPolicyID
                      }
                    )
                    for policyRule in try modelContext.fetch(descriptor) {
                      modelContext.delete(policyRule)
                    }
                    if proxyPolicyViewModel?.id == policy.id {
                      proxyPolicyViewModel = nil
                    }
                    selectedPolicyIDs.remove(policy.id)
                    modelContext.delete(policy)
                    try modelContext.save()
                    actionError = nil
                  } catch {
                    modelContext.rollback()
                    actionError = error.localizedDescription
                  }
                } label: {
                  Label("删除策略", systemImage: "trash")
                }
              } label: {
                Label("策略操作", systemImage: "ellipsis.circle")
                  .labelStyle(.iconOnly)
              }
              .help("策略操作")
            }
            .width(min: 72, ideal: 88, max: 96)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .alert(
        "读取代理策略失败",
        isPresented: Binding(
          get: { actionError != nil },
          set: { isPresented in
            if isPresented == false {
              actionError = nil
            }
          }
        )
      ) {
        Button("好", role: .cancel) {
          actionError = nil
        }
      } message: {
        Text(actionError ?? "")
      }
    }
  }

  /// 在独立 SwiftData 上下文中编辑代理策略，并提供原生表单保存和取消语义。
  private struct ProxyPolicyFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(
      sort: [
        SortDescriptor(\MagentProxyNode.name, order: .forward),
        SortDescriptor(\MagentProxyNode.id, order: .forward),
      ]
    ) private var nodes: [MagentProxyNode]
    let proxyPolicyViewModel: ProxyPolicyViewModel
    let onSaved: (Int) -> Void
    @State private var saveError: String?

    var body: some View {
      @Bindable var policy = proxyPolicyViewModel.policy
      let nameError: MagentXError? =
        if policy.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          .invalidParameter(String(localized: "Name is required"))
        } else {
          nil
        }

      Form {
        Section {
          TextField("名称", text: $policy.name)

          Picker("代理节点", selection: $policy.nodeID) {
            ForEach(nodes) { node in
              Text(node.name)
                .tag(node.id)
            }
          }
          .pickerStyle(.menu)

          if let nameError {
            Label(nameError.localizedDescription, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
          }
        } header: {
          Text("策略配置")
            .font(.title3.weight(.semibold))
        }
      }
      .formStyle(.grouped)
      .frame(minWidth: 420, minHeight: 260)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消", role: .cancel) {
            proxyPolicyViewModel.rollback()
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            do {
              try proxyPolicyViewModel.save()
              saveError = nil
              onSaved(proxyPolicyViewModel.id)
              dismiss()
            } catch {
              saveError = error.localizedDescription
            }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(nameError != nil || nodes.isEmpty)
        }
      }
      .alert(
        "保存代理策略失败",
        isPresented: Binding(
          get: { saveError != nil },
          set: { isPresented in
            if isPresented == false {
              saveError = nil
            }
          }
        )
      ) {
        Button("好", role: .cancel) {
          saveError = nil
        }
      } message: {
        Text(saveError ?? "")
      }
      .onDisappear {
        proxyPolicyViewModel.rollback()
      }
    }
  }
}
