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

/// 代理策略页面，在规则表格和策略卡片中管理规则归属和代理策略。
@MainActor
struct ProxyPolicyView: View {
  @Environment(\.modelContext) private var modelContext
  @Binding var toolbarButtons: [ContentToolbarButton]
  @State private var searchText = ""
  @FocusState private var isSearchFocused: Bool
  @State private var selectedRuleIDs: Set<Int> = []
  @State private var proxyPolicyViewModel: ProxyPolicyViewModel?
  @State private var formError: String?

  private static let maximumCachedModelCount = 1_000

  var body: some View {
    let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

    let content = GeometryReader { geometry in
      HSplitView {
        ProxyPolicyRulePageView(
          searchText: normalizedSearchText,
          maximumCachedModelCount: Self.maximumCachedModelCount,
          selectedRuleIDs: $selectedRuleIDs
        )
        .frame(width: geometry.size.width * 0.6)
        .frame(maxHeight: .infinity)

        ProxyPolicyGridView(
          maximumCachedModelCount: Self.maximumCachedModelCount
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(.top, 1)
    .overlay(alignment: .top) {
      Divider()
    }

    Group {
      content
        .simultaneousGesture(
          TapGesture()
            .onEnded {
              isSearchFocused = false
            }
        )
        .searchable(
          text: $searchText,
          placement: .toolbar,
          prompt: "搜索规则"
        )
        .searchFocused($isSearchFocused)
    }
    .sheet(item: $proxyPolicyViewModel) { viewModel in
      ProxyPolicyFormView(proxyPolicyViewModel: viewModel)
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

  /// 观察有限规则和策略集合，并将规则表格交给公共原生表格。
  private struct ProxyPolicyRulePageView: View {
    @Query private var policies: [MagentProxyPolicy]
    @Binding private var selectedRuleIDs: Set<Int>
    @State private var associationError: String?

    private let searchText: String
    private let maximumCachedModelCount: Int

    /// 创建按规则 id 稳定排序且数量有上限的 SwiftData 查询。
    init(
      searchText: String,
      maximumCachedModelCount: Int,
      selectedRuleIDs: Binding<Set<Int>>
    ) {
      var policyDescriptor = FetchDescriptor<MagentProxyPolicy>(
        sortBy: [
          SortDescriptor(\MagentProxyPolicy.name, order: .forward),
          SortDescriptor(\MagentProxyPolicy.id, order: .forward),
        ]
      )
      policyDescriptor.fetchLimit = maximumCachedModelCount
      _policies = Query(policyDescriptor)

      _selectedRuleIDs = selectedRuleIDs
      self.searchText = searchText
      self.maximumCachedModelCount = maximumCachedModelCount
    }

    var body: some View {
      let sortDescriptors = [SortDescriptor(\MagentProxyRule.id, order: .forward)]
      let descriptor: FetchDescriptor<MagentProxyRule> = {
        if searchText.isEmpty {
          return FetchDescriptor<MagentProxyRule>(sortBy: sortDescriptors)
        }

        let query = searchText
        return FetchDescriptor<MagentProxyRule>(
          predicate: #Predicate<MagentProxyRule> { rule in
            rule.matchValue.contains(query)
          },
          sortBy: sortDescriptors
        )
      }()

      ScrollTableView(
        selection: $selectedRuleIDs,
        descriptor: descriptor,
        maximumCachedModelCount: maximumCachedModelCount,
      ) {
        ContentUnavailableView(
          searchText.isEmpty ? "暂无规则" : "未找到规则",
          systemImage: searchText.isEmpty
            ? "arrow.triangle.branch"
            : "magnifyingglass",
          description: Text(
            searchText.isEmpty
              ? "添加或同步规则后会显示在这里"
              : searchText
          )
        )
      } columns: {
        TableColumn("匹配值") { rule in
          Text(rule.matchValue)
            .lineLimit(1)
        }
        .width(min: 80, ideal: 140)

        TableColumn("类型") { rule in
          Text(rule.matchType)
            .lineLimit(1)
        }
        .width(56)

        TableColumn("规则") { rule in
          Text(rule.decision)
            .lineLimit(1)
        }
        .width(56)

        TableColumn("策略") { rule in
          ProxyPolicyPickerView(
            ruleID: rule.id,
            policies: policies,
            associationError: $associationError
          )
        }
        .width(min: 80, ideal: 100, max: 120)
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

  /// 以双列卡片网格展示代理策略，并承载卡片内的直接修改。
  private struct ProxyPolicyGridView: View {
    @Query private var policies: [MagentProxyPolicy]
    @Query private var nodes: [MagentProxyNode]
    @State private var actionError: String?

    /// 创建按 id 稳定排序且数量有上限的策略与节点查询。
    init(maximumCachedModelCount: Int) {
      precondition(maximumCachedModelCount > 0, "maximumCachedModelCount must be positive")

      var descriptor = FetchDescriptor<MagentProxyPolicy>(
        sortBy: [SortDescriptor(\MagentProxyPolicy.id, order: .forward)]
      )
      descriptor.fetchLimit = maximumCachedModelCount
      _policies = Query(descriptor)

      var nodeDescriptor = FetchDescriptor<MagentProxyNode>(
        sortBy: [
          SortDescriptor(\MagentProxyNode.name, order: .forward),
          SortDescriptor(\MagentProxyNode.id, order: .forward),
        ]
      )
      nodeDescriptor.fetchLimit = maximumCachedModelCount
      _nodes = Query(nodeDescriptor)
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
          ScrollView {
            LazyVGrid(
              columns: [
                GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top),
                GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top),
              ],
              spacing: 12
            ) {
              ForEach(policies) { policy in
                ProxyPolicyCardView(
                  policy: policy,
                  nodes: nodes,
                  actionError: $actionError
                )
              }
            }
            .padding(12)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .alert(
        "操作代理策略失败",
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

  /// 在标题输入框存在期间监听发生在其原生边界之外的鼠标点击。
  private struct ProxyPolicyNameEditingBoundary: NSViewRepresentable {
    let onClickOutside: () -> Void

    func makeNSView(context: Context) -> ProxyPolicyNameEditingProbeView {
      let probeView = ProxyPolicyNameEditingProbeView()
      probeView.onClickOutside = onClickOutside
      probeView.startMonitoring()
      return probeView
    }

    func updateNSView(_ nsView: ProxyPolicyNameEditingProbeView, context: Context) {
      nsView.onClickOutside = onClickOutside
      nsView.startMonitoring()
    }

    static func dismantleNSView(
      _ nsView: ProxyPolicyNameEditingProbeView,
      coordinator: Void
    ) {
      nsView.stopMonitoring()
    }
  }

  /// 以标题输入框的原生边界判断一次鼠标点击是否发生在输入框外。
  @MainActor
  private final class ProxyPolicyNameEditingProbeView: NSView {
    var onClickOutside: () -> Void = {}
    private var localMouseMonitor: Any?
    private var windowDidResignObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil {
        stopMonitoring()
      } else {
        startMonitoring()
      }
    }

    func startMonitoring() {
      observeWindowResignation()
      guard localMouseMonitor == nil else { return }

      localMouseMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
      ) { [weak self] event in
        guard let self else { return event }

        if let window, event.window === window,
          bounds.contains(convert(event.locationInWindow, from: nil))
        {
          return event
        }

        Task { @MainActor [weak self] in
          self?.onClickOutside()
        }
        return event
      }
    }

    func stopMonitoring() {
      if let localMouseMonitor {
        NSEvent.removeMonitor(localMouseMonitor)
        self.localMouseMonitor = nil
      }
      if let windowDidResignObserver {
        NotificationCenter.default.removeObserver(windowDidResignObserver)
        self.windowDidResignObserver = nil
      }
    }

    private func observeWindowResignation() {
      guard let window, windowDidResignObserver == nil else { return }
      windowDidResignObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.onClickOutside()
        }
      }
    }
  }

  /// 展示一条策略的名称和节点，并在卡片内完成修改与删除。
  private struct ProxyPolicyCardView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var policy: MagentProxyPolicy
    let nodes: [MagentProxyNode]
    @Binding var actionError: String?
    @State private var draftName = ""
    @State private var isEditingName = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
      let finishNameEditing = {
        guard isEditingName else { return }
        defer { isEditingName = false }

        isNameFocused = false
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false else {
          draftName = policy.name
          actionError =
            MagentXError.invalidParameter(
              String(localized: "Name is required")
            ).localizedDescription
          return
        }
        guard name != policy.name else { return }

        policy.name = name
        policy.updatedAt = .now
        do {
          try modelContext.save()
          actionError = nil
        } catch {
          modelContext.rollback()
          draftName = policy.name
          actionError = error.localizedDescription
        }
      }

      let deleteAction = {
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
          modelContext.delete(policy)
          try modelContext.save()
          actionError = nil
        } catch {
          modelContext.rollback()
          actionError = error.localizedDescription
        }
      }

      GroupBox {
        if isEditingName {
          TextField("名称", text: $draftName)
            .focused($isNameFocused)
            .onAppear {
              Task { @MainActor in
                isNameFocused = true
              }
            }
            .background {
              ProxyPolicyNameEditingBoundary(onClickOutside: finishNameEditing)
                .allowsHitTesting(false)
            }
            .onSubmit {
              finishNameEditing()
            }
        } else {
          Button {
            draftName = policy.name
            isEditingName = true
          } label: {
            Text(policy.name)
              .font(.headline)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("点击修改名称")
        }

        Text("代理节点")
          .font(.subheadline.weight(.semibold))
          .frame(maxWidth: .infinity, alignment: .leading)

        Picker(
          "代理节点",
          selection: Binding(
            get: { policy.nodeID },
            set: { nodeID in
              guard nodeID != policy.nodeID else { return }

              do {
                let targetNodeID = nodeID
                let targetPolicyID = policy.id
                let descriptor = FetchDescriptor<MagentProxyPolicy>(
                  predicate: #Predicate<MagentProxyPolicy> { storedPolicy in
                    storedPolicy.nodeID == targetNodeID && storedPolicy.id != targetPolicyID
                  }
                )
                guard try modelContext.fetchCount(descriptor) == 0 else {
                  throw MagentXError.invalidParameter(
                    String(localized: "Proxy node already belongs to another policy")
                  )
                }

                policy.nodeID = nodeID
                policy.updatedAt = .now
                try modelContext.save()
                actionError = nil
              } catch {
                modelContext.rollback()
                actionError = error.localizedDescription
              }
            }
          )
        ) {
          ForEach(nodes) { node in
            Text(node.name)
              .tag(node.id)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)

        Divider()

        if #available(macOS 26.0, *) {
          Button(role: .destructive, action: deleteAction) {
            Label("删除策略", systemImage: "trash")
          }
          .buttonStyle(.glass)
          .tint(.red)
          .help("删除策略")
        } else {
          Button(role: .destructive, action: deleteAction) {
            Label("删除策略", systemImage: "trash")
          }
          .buttonStyle(.bordered)
          .tint(.red)
          .help("删除策略")
        }
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
