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

/// 代理规则页面，在原生表格和详情区域中提供直接的 SwiftData CRUD 交互。
@MainActor
struct ProxyRulesView: View {
  @Environment(\.modelContext) private var modelContext
  @InjectedObservable(\.syncProxyRulesCoordinator) private var syncProxyRulesCoordinator
  @Binding var toolbarButtons: [ContentToolbarButton]
  @State private var searchText = ""
  @FocusState private var isSearchFocused: Bool
  @State private var selectedRule: MagentProxyRule?
  @State private var proxyRuleViewModel: ProxyRuleViewModel?
  @State private var actionError: String?

  private static let maximumCachedModelCount = 1_000

  var body: some View {
    let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let sortDescriptors = [SortDescriptor(\MagentProxyRule.id, order: .forward)]
    let descriptor: FetchDescriptor<MagentProxyRule> = {
      if normalizedSearchText.isEmpty {
        return FetchDescriptor<MagentProxyRule>(sortBy: sortDescriptors)
      }

      let query = normalizedSearchText
      return FetchDescriptor<MagentProxyRule>(
        predicate: #Predicate<MagentProxyRule> { rule in
          rule.matchValue.contains(query)
        },
        sortBy: sortDescriptors
      )
    }()
    let content = GeometryReader { geometry in
      HSplitView {
        ScrollTableView(
          selection: Binding(
            get: { selectedRule?.id },
            set: { ruleID in
              guard ruleID != selectedRule?.id else { return }
              guard let ruleID else {
                selectedRule = nil
                return
              }

              do {
                var descriptor = FetchDescriptor<MagentProxyRule>(
                  predicate: #Predicate { $0.id == ruleID }
                )
                descriptor.fetchLimit = 1
                guard let rule = try modelContext.fetch(descriptor).first else {
                  throw MagentXError.missingMagentProxyRule(ruleID)
                }
                selectedRule = rule
                actionError = nil
              } catch {
                actionError = error.localizedDescription
              }
            }
          ),
          descriptor: descriptor,
          queryID: normalizedSearchText,
          maximumCachedModelCount: Self.maximumCachedModelCount,
        ) {
          TableColumn("匹配值") { rule in
            Text(rule.matchValue)
              .lineLimit(1)
          }
          // 首列吸收表格剩余宽度，避免最后一列右侧出现无法使用的空白区域。
          .width(min: 72, ideal: 140)

          TableColumn("类型") { rule in
            switch MatchType(rawValue: rule.matchType) {
            case .exactDomain:
              Text("精确域名")
            case .domainSuffix:
              Text("域名后缀")
            case .domainKeyword:
              Text("域名关键字")
            case .ipCIDR:
              Text("IP 网段")
            case .urlRegex:
              Text("URL 正则")
            case .none:
              Text(rule.matchType)
            }
          }
          .width(min: 50, ideal: 64, max: 76)

          TableColumn("顺序") { rule in
            Text(rule.order, format: .number)
              .lineLimit(1)
          }
          .width(min: 34, ideal: 44, max: 52)

          TableColumn("规则") { rule in
            Text(rule.decision.uppercased())
              .lineLimit(1)
          }
          .width(min: 40, ideal: 52, max: 60)
        }
        .accessibilityIdentifier("proxy-rules-table")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(width: geometry.size.width * 0.55)
        .frame(maxHeight: .infinity)

        Group {
          if let proxyRuleViewModel, proxyRuleViewModel.isNew {
            ProxyRuleFormView(
              proxyRuleViewModel: proxyRuleViewModel,
              onSaved: { ruleID in
                do {
                  let descriptor = FetchDescriptor<MagentProxyRule>(
                    predicate: #Predicate<MagentProxyRule> { rule in rule.id == ruleID }
                  )
                  guard let savedRule = try modelContext.fetch(descriptor).first else {
                    throw MagentXError.missingMagentProxyRule(ruleID)
                  }
                  selectedRule = savedRule
                  self.proxyRuleViewModel = nil
                  actionError = nil
                } catch {
                  actionError = error.localizedDescription
                }
              },
              onCancelled: {
                proxyRuleViewModel.rollback()
                self.proxyRuleViewModel = nil
                actionError = nil
              }
            )
          } else if let selectedRule {
            ProxyRuleDetailView(rule: selectedRule, actionError: $actionError) {
              delete(selectedRule)
            }
            .id(selectedRule.id)
          } else {
            ContentUnavailableView(
              "选择代理规则",
              systemImage: "list.bullet.rectangle",
              description: Text("从左侧表格选择规则以查看详情，或添加一条新规则")
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
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索规则")
        .searchFocused($isSearchFocused)
    }
    .alert(
      "代理规则操作失败",
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
    .alert(
      "规则同步失败",
      isPresented: Binding(
        get: { syncProxyRulesCoordinator.syncError != nil },
        set: { isPresented in
          if !isPresented {
            syncProxyRulesCoordinator.syncError = nil
          }
        }
      )
    ) {
      Button("好", role: .cancel) {
        syncProxyRulesCoordinator.syncError = nil
      }
    } message: {
      Text(syncProxyRulesCoordinator.syncError ?? "")
    }
    .task(id: syncProxyRulesCoordinator.state) {
      if syncProxyRulesCoordinator.state == .running {
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
          ) {},
        ]
      } else {
        toolbarButtons = [
          ContentToolbarButton(title: "增加规则", systemImage: "plus") {
            add()
          },
          ContentToolbarButton(title: "同步规则", systemImage: "arrow.clockwise") {
            syncProxyRulesCoordinator.sync()
          },
        ]
      }
    }
    .onDisappear {
      if let proxyRuleViewModel, proxyRuleViewModel.isNew {
        proxyRuleViewModel.rollback()
        self.proxyRuleViewModel = nil
      }
    }
  }

  /// 打开使用独立上下文的新规则表单，支持保存前取消。
  private func add() {
    proxyRuleViewModel?.rollback()
    do {
      proxyRuleViewModel = try ProxyRuleViewModel(modelContainer: modelContext.container)
      actionError = nil
    } catch {
      actionError = error.localizedDescription
    }
  }

  /// 删除当前详情中的规则，并清理表格选择。
  private func delete(_ rule: MagentProxyRule) {
    do {
      modelContext.delete(rule)
      try modelContext.save()
      selectedRule = nil
      actionError = nil
    } catch {
      if rule.isDeleted {
        modelContext.rollback()
      }
      actionError = error.localizedDescription
    }
  }

  /// 新建规则的独立 SwiftData 表单，在保存或取消前不修改主上下文。
  private struct ProxyRuleFormView: View {
    let proxyRuleViewModel: ProxyRuleViewModel
    let onSaved: (Int) -> Void
    let onCancelled: () -> Void
    @State private var saveError: String?

    var body: some View {
      @Bindable var rule = proxyRuleViewModel.rule
      let matchValueError: MagentXError? =
        if rule.matchValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          .invalidParameter(String(localized: "Match value is required"))
        } else {
          nil
        }

      Form {
        Section("规则配置") {
          Picker("匹配类型", selection: $rule.matchType) {
            Text("精确域名").tag(MatchType.exactDomain.rawValue)
            Text("域名后缀").tag(MatchType.domainSuffix.rawValue)
            Text("域名关键字").tag(MatchType.domainKeyword.rawValue)
            Text("IP 网段").tag(MatchType.ipCIDR.rawValue)
            Text("URL 正则").tag(MatchType.urlRegex.rawValue)
          }
          .pickerStyle(.menu)

          Picker("动作", selection: $rule.decision) {
            Text("DIRECT").tag("direct")
            Text("PROXY").tag("proxy")
          }
          .pickerStyle(.menu)

          TextField("匹配值", text: $rule.matchValue)
            .accessibilityIdentifier("new-rule-match-value")
          if let matchValueError {
            Label(
              matchValueError.localizedDescription,
              systemImage: "exclamationmark.triangle.fill"
            )
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
              try proxyRuleViewModel.save()
              saveError = nil
              onSaved(proxyRuleViewModel.id)
            } catch {
              saveError = error.localizedDescription
            }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(matchValueError != nil)
        }
        .padding()
        .background(.bar)
      }
      .alert(
        "保存代理规则失败",
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
        proxyRuleViewModel.rollback()
      }
    }
  }
}

/// 单条已存规则的详情区域，使用字段草稿确保无效输入不会写入持久化模型。
@MainActor
private struct ProxyRuleDetailView: View {
  @Environment(\.modelContext) private var modelContext
  let rule: MagentProxyRule
  @Binding var actionError: String?
  let onDelete: () -> Void
  @State private var matchTypeDraft: String
  @State private var decisionDraft: String
  @State private var orderDraft: String
  @State private var matchValueDraft: String

  /// 用当前规则值初始化详情草稿，避免切换规则时显示上一条记录的编辑状态。
  init(
    rule: MagentProxyRule,
    actionError: Binding<String?>,
    onDelete: @escaping () -> Void
  ) {
    self.rule = rule
    _actionError = actionError
    self.onDelete = onDelete
    _matchTypeDraft = State(initialValue: rule.matchType)
    _decisionDraft = State(initialValue: rule.decision)
    _orderDraft = State(initialValue: String(rule.order))
    _matchValueDraft = State(initialValue: rule.matchValue)
  }

  var body: some View {
    Form {
      Section("规则详情") {
        LabeledContent("匹配类型") {
          Picker("匹配类型", selection: $matchTypeDraft) {
            Text("精确域名").tag(MatchType.exactDomain.rawValue)
            Text("域名后缀").tag(MatchType.domainSuffix.rawValue)
            Text("域名关键字").tag(MatchType.domainKeyword.rawValue)
            Text("IP 网段").tag(MatchType.ipCIDR.rawValue)
            Text("URL 正则").tag(MatchType.urlRegex.rawValue)
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .onChange(of: matchTypeDraft) { _, matchType in
            save(
              { rule.matchType = matchType },
              resetDraft: { matchTypeDraft = rule.matchType }
            )
          }
          .accessibilityIdentifier("rule-match-type")
        }

        LabeledContent("动作") {
          Picker("动作", selection: $decisionDraft) {
            Text("DIRECT").tag("direct")
            Text("PROXY").tag("proxy")
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .onChange(of: decisionDraft) { _, decision in
            save(
              { rule.decision = decision },
              resetDraft: { decisionDraft = rule.decision }
            )
          }
          .accessibilityIdentifier("rule-decision")
        }

        LabeledContent("顺序") {
          EditableFieldFormView(
            onEditingBegan: {
              orderDraft = String(rule.order)
              return true
            },
            onEditingEnded: {
              save(
                {
                  let value = orderDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                  guard let order = Int(value) else {
                    throw MagentXError.invalidParameter(
                      String(localized: "Order must be an integer")
                    )
                  }
                  rule.order = order
                },
                resetDraft: { orderDraft = String(rule.order) }
              )
            }
          ) {
            Text(rule.order, format: .number.grouping(.never))
              .frame(maxWidth: .infinity, alignment: .trailing)
          } editor: { focus, _ in
            TextField("顺序", text: $orderDraft)
              .labelsHidden()
              .focused(focus)
              .multilineTextAlignment(.trailing)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          .help("点击修改顺序")
          .accessibilityIdentifier("rule-order")
        }

        LabeledContent("匹配值") {
          EditableFieldFormView(
            onEditingBegan: {
              matchValueDraft = rule.matchValue
              return true
            },
            onEditingEnded: {
              save(
                {
                  let matchValue = matchValueDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  )
                  guard !matchValue.isEmpty else {
                    throw MagentXError.invalidParameter(
                      String(localized: "Match value is required")
                    )
                  }
                  rule.matchValue = matchValue
                },
                resetDraft: { matchValueDraft = rule.matchValue }
              )
            }
          ) {
            Text(rule.matchValue)
              .frame(maxWidth: .infinity, alignment: .trailing)
          } editor: { focus, _ in
            TextField("匹配值", text: $matchValueDraft)
              .labelsHidden()
              .focused(focus)
              .multilineTextAlignment(.trailing)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          .help("点击修改匹配值")
          .accessibilityIdentifier("rule-match-value")
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
            Label("删除规则", systemImage: "trash")
              .foregroundStyle(.red)
              .padding(5)
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.glass(.clear.tint(.red)))
          .controlSize(.large)
          .buttonBorderShape(.circle)
          .help("删除规则")
          .accessibilityLabel("删除规则")
        } else {
          Button(role: .destructive, action: onDelete) {
            Label("删除规则", systemImage: "trash")
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.bordered)
          .controlSize(.large)
          .buttonBorderShape(.circle)
          .tint(.red)
          .help("删除规则")
          .accessibilityLabel("删除规则")
        }
      }
      .padding()
      .background(.bar)
    }
  }

  /// 校验并保存一个详情字段的修改；失败时恢复模型和对应草稿的原始值。
  private func save(
    _ changes: () throws -> Void,
    resetDraft: () -> Void
  ) {
    // 删除后旧编辑控件的失焦通知不能再次读取或修改已删除的规则。
    guard rule.modelContext != nil, !rule.isDeleted else { return }
    let previousMatchType = rule.matchType
    let previousDecision = rule.decision
    let previousOrder = rule.order
    let previousMatchValue = rule.matchValue
    let previousSource = rule.source
    let previousUpdatedAt = rule.updatedAt

    do {
      try changes()
      let rules = try modelContext.fetch(FetchDescriptor<MagentProxyRule>())
      if let validationError = rule.validationError(in: rules) {
        throw validationError
      }
      guard modelContext.hasChanges else { return }
      rule.source = "user"
      rule.updatedAt = .now
      try modelContext.save()
      actionError = nil
    } catch {
      rule.matchType = previousMatchType
      rule.decision = previousDecision
      rule.order = previousOrder
      rule.matchValue = previousMatchValue
      rule.source = previousSource
      rule.updatedAt = previousUpdatedAt
      resetDraft()
      actionError = error.localizedDescription
    }
  }
}
