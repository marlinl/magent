//
//  ProxyPolicyView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Manages proxy policies in a native list-detail interface.
//

import SwiftData
import SwiftUI

/// 代理策略页面，在原生策略表格和详情区域中提供直接的 SwiftData CRUD 交互。
@MainActor
struct ProxyPolicyView: View {
  @Environment(\.modelContext) private var modelContext
  @Binding var toolbarButtons: [ContentToolbarButton]
  @State private var searchText = ""
  @FocusState private var isSearchFocused: Bool
  @State private var selectedPolicy: MagentProxyPolicy?
  @State private var proxyPolicyViewModel: ProxyPolicyViewModel?
  @State private var actionError: String?

  private static let maximumCachedModelCount = 1_000

  var body: some View {
    let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let sortDescriptors = [SortDescriptor(\MagentProxyPolicy.id, order: .forward)]
    let descriptor: FetchDescriptor<MagentProxyPolicy> = {
      if normalizedSearchText.isEmpty {
        return FetchDescriptor<MagentProxyPolicy>(sortBy: sortDescriptors)
      }

      let query = normalizedSearchText
      return FetchDescriptor<MagentProxyPolicy>(
        predicate: #Predicate<MagentProxyPolicy> { policy in
          policy.name.contains(query)
        },
        sortBy: sortDescriptors
      )
    }()
    let content = GeometryReader { geometry in
      HSplitView {
        ScrollTableView(
          selection: Binding(
            get: { selectedPolicy?.id },
            set: { policyID in
              guard policyID != selectedPolicy?.id else { return }
              guard let policyID else {
                selectedPolicy = nil
                return
              }

              do {
                var descriptor = FetchDescriptor<MagentProxyPolicy>(
                  predicate: #Predicate { $0.id == policyID }
                )
                descriptor.fetchLimit = 1
                guard let policy = try modelContext.fetch(descriptor).first else {
                  throw MagentXError.invalidParameter(
                    String(
                      format: String(localized: "Proxy policy does not exist: %d"),
                      policyID
                    )
                  )
                }
                selectedPolicy = policy
                actionError = nil
              } catch {
                actionError = error.localizedDescription
              }
            }
          ),
          descriptor: descriptor,
          queryID: normalizedSearchText,
          maximumCachedModelCount: Self.maximumCachedModelCount
        ) {
          TableColumn("名称") { policy in
            Text(policy.name)
              .lineLimit(1)
          }
          .width(min: 90, ideal: 160)

          TableColumn("规则总数") { policy in
            ProxyPolicyRuleCountView(policyID: policy.id, actionError: $actionError)
          }
          .width(min: 64, ideal: 72, max: 88)
        }
        .accessibilityIdentifier("proxy-policies-table")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(width: geometry.size.width * 0.3)
        .frame(maxHeight: .infinity)

        Group {
          if let proxyPolicyViewModel, proxyPolicyViewModel.isNew {
            ProxyPolicyFormView(
              proxyPolicyViewModel: proxyPolicyViewModel,
              onSaved: { policyID in
                do {
                  var descriptor = FetchDescriptor<MagentProxyPolicy>(
                    predicate: #Predicate<MagentProxyPolicy> { policy in
                      policy.id == policyID
                    }
                  )
                  descriptor.fetchLimit = 1
                  guard let savedPolicy = try modelContext.fetch(descriptor).first else {
                    throw MagentXError.invalidParameter(
                      String(
                        format: String(localized: "Proxy policy does not exist: %d"),
                        policyID
                      )
                    )
                  }
                  selectedPolicy = savedPolicy
                  self.proxyPolicyViewModel = nil
                  actionError = nil
                } catch {
                  actionError = error.localizedDescription
                }
              },
              onCancelled: {
                proxyPolicyViewModel.rollback()
                self.proxyPolicyViewModel = nil
                actionError = nil
              }
            )
          } else if let selectedPolicy {
            ProxyPolicyDetailView(policy: selectedPolicy, actionError: $actionError) {
              delete(selectedPolicy)
            }
            .id(selectedPolicy.id)
          } else {
            ContentUnavailableView(
              "选择代理策略",
              systemImage: "arrow.triangle.branch",
              description: Text("从左侧表格选择策略以查看详情，或添加一个新策略")
            )
          }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
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
          TapGesture().onEnded {
            isSearchFocused = false
          }
        )
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索策略")
        .searchFocused($isSearchFocused)
    }
    .alert(
      "代理策略操作失败",
      isPresented: Binding(
        get: { actionError != nil },
        set: { isPresented in
          if !isPresented {
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
    .onAppear {
      toolbarButtons = [
        ContentToolbarButton(title: "增加策略", systemImage: "plus") {
          add()
        }
      ]
    }
    .onDisappear {
      if let proxyPolicyViewModel, proxyPolicyViewModel.isNew {
        proxyPolicyViewModel.rollback()
        self.proxyPolicyViewModel = nil
      }
    }
  }

  /// 打开使用独立上下文的新策略表单，支持保存前取消。
  private func add() {
    proxyPolicyViewModel?.rollback()
    do {
      proxyPolicyViewModel = try ProxyPolicyViewModel(modelContainer: modelContext.container)
      actionError = nil
    } catch {
      actionError = error.localizedDescription
    }
  }

  /// 删除当前详情中的策略及其规则关联，并清理表格选择。
  private func delete(_ policy: MagentProxyPolicy) {
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
      selectedPolicy = nil
      actionError = nil
    } catch {
      if policy.isDeleted {
        modelContext.rollback()
      }
      actionError = error.localizedDescription
    }
  }

  /// 新建策略的独立 SwiftData 表单，在保存或取消前不修改主上下文。
  private struct ProxyPolicyFormView: View {
    @Query(
      sort: [
        SortDescriptor(\MagentProxyNode.name, order: .forward),
        SortDescriptor(\MagentProxyNode.id, order: .forward),
      ]
    ) private var nodes: [MagentProxyNode]
    let proxyPolicyViewModel: ProxyPolicyViewModel
    let onSaved: (Int) -> Void
    let onCancelled: () -> Void
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
        Section("策略配置") {
          TextField("名称", text: $policy.name)
            .accessibilityIdentifier("new-policy-name")

          Toggle("启用", isOn: $policy.enable)
            .accessibilityIdentifier("new-policy-enable")

          Picker("代理节点", selection: $policy.nodeID) {
            ForEach(nodes) { node in
              Text(node.name)
                .tag(node.id)
            }
          }
          .pickerStyle(.menu)
          .accessibilityIdentifier("new-policy-node")

          if let nameError {
            Label(nameError.localizedDescription, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .safeAreaInset(edge: .bottom) {
        HStack {
          Button("取消", role: .cancel, action: onCancelled)
            .keyboardShortcut(.cancelAction)

          Spacer()

          Button("保存") {
            do {
              try proxyPolicyViewModel.save()
              saveError = nil
              onSaved(proxyPolicyViewModel.id)
            } catch {
              saveError = error.localizedDescription
            }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(nameError != nil || nodes.isEmpty)
        }
        .padding()
        .background(.bar)
      }
      .alert(
        "保存代理策略失败",
        isPresented: Binding(
          get: { saveError != nil },
          set: { isPresented in
            if !isPresented {
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

/// 单个策略的规则关联总数单元格，通过计数查询避免加载完整关联模型集合。
@MainActor
private struct ProxyPolicyRuleCountView: View {
  @Environment(\.modelContext) private var modelContext
  let policyID: Int
  @Binding var actionError: String?
  @State private var ruleCount: Int?

  var body: some View {
    Group {
      if let ruleCount {
        Text(ruleCount, format: .number)
      } else {
        Text("—")
      }
    }
    .lineLimit(1)
    .task(id: policyID) {
      do {
        let targetPolicyID = policyID
        let descriptor = FetchDescriptor<MagentProxyPolicyRule>(
          predicate: #Predicate<MagentProxyPolicyRule> { policyRule in
            policyRule.policyID == targetPolicyID
          }
        )
        ruleCount = try modelContext.fetchCount(descriptor)
      } catch {
        actionError = error.localizedDescription
      }
    }
  }
}

/// 单个已有策略的绑定详情，字段修改在验证后直接提交到主 SwiftData 上下文。
@MainActor
private struct ProxyPolicyDetailView: View {
  @Environment(\.modelContext) private var modelContext
  @Query(
    sort: [
      SortDescriptor(\MagentProxyNode.name, order: .forward),
      SortDescriptor(\MagentProxyNode.id, order: .forward),
    ]
  ) private var nodes: [MagentProxyNode]
  let policy: MagentProxyPolicy
  @Binding var actionError: String?
  let onDelete: () -> Void
  @State private var nameDraft = ""

  var body: some View {
    Form {
      Section("策略详情") {
        LabeledContent("名称") {
          EditableFieldFormView(
            onEditingBegan: {
              nameDraft = policy.name
              return true
            },
            onEditingEnded: {
              save {
                let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                  throw MagentXError.invalidParameter(String(localized: "Name is required"))
                }
                policy.name = name
              }
              nameDraft = policy.name
            }
          ) {
            Text(policy.name)
              .frame(maxWidth: .infinity, alignment: .trailing)
          } editor: { focus, _ in
            TextField("名称", text: $nameDraft)
              .labelsHidden()
              .focused(focus)
              .multilineTextAlignment(.trailing)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          .help("点击修改名称")
          .accessibilityIdentifier("policy-name")
        }

        Toggle(
          "启用",
          isOn: Binding(
            get: { policy.enable },
            set: { enable in
              guard enable != policy.enable else { return }
              save {
                policy.enable = enable
              }
            }
          )
        )
        .accessibilityIdentifier("policy-enable")

        LabeledContent("代理节点") {
          Picker(
            "代理节点",
            selection: Binding(
              get: { policy.nodeID },
              set: { nodeID in
                guard nodeID != policy.nodeID else { return }
                save {
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
                }
              }
            )
          ) {
            ForEach(nodes) { node in
              Text(node.name)
                .tag(node.id)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .accessibilityIdentifier("policy-node")
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .safeAreaInset(edge: .bottom) {
      HStack {
        Spacer()

        if #available(macOS 26.0, *) {
          Button(role: .destructive, action: onDelete) {
            Label("删除策略", systemImage: "trash")
              .foregroundStyle(.red)
              .padding(5)
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.glass(.clear.tint(.red)))
          .controlSize(.large)
          .buttonBorderShape(.circle)
          .help("删除策略")
          .accessibilityLabel("删除策略")
        } else {
          Button(role: .destructive, action: onDelete) {
            Label("删除策略", systemImage: "trash")
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.bordered)
          .controlSize(.large)
          .buttonBorderShape(.circle)
          .tint(.red)
          .help("删除策略")
          .accessibilityLabel("删除策略")
        }
      }
      .padding()
      .background(.bar)
    }
  }

  /// 校验并保存一个详情字段的修改；失败时恢复策略原值并交给页面展示错误。
  private func save(_ changes: () throws -> Void) {
    guard policy.modelContext != nil, !policy.isDeleted else { return }
    let previousName = policy.name
    let previousEnable = policy.enable
    let previousNodeID = policy.nodeID
    let previousUpdatedAt = policy.updatedAt

    do {
      try changes()
      guard modelContext.hasChanges else { return }
      policy.updatedAt = .now
      try modelContext.save()
      actionError = nil
    } catch {
      policy.name = previousName
      policy.enable = previousEnable
      policy.nodeID = previousNodeID
      policy.updatedAt = previousUpdatedAt
      actionError = error.localizedDescription
    }
  }
}
