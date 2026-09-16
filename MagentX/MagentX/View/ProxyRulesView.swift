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
  @InjectedObservable(\.syncProxyRulesCoordinator) private var syncProxyRulesCoordinator
  @Binding var toolbarButtons: [ContentToolbarButton]
  @State private var searchText = ""
  @State private var pageAt = 1
  @State private var proxyRuleViewModel: ProxyRuleViewModel?
  @State private var formError: String?

  private static let pageSize = 100

  var body: some View {
    let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    ProxyRulePageView(
      searchText: normalizedSearchText,
      pageAt: $pageAt,
      pageSize: Self.pageSize,
      isRefreshing: syncProxyRulesCoordinator.state == .running,
      proxyRuleViewModel: $proxyRuleViewModel
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
    .sheet(item: $proxyRuleViewModel) { viewModel in
      ProxyRuleFormView(
        proxyRuleViewModel: viewModel,
        onSaved: { _ in
          searchText = ""
          if viewModel.isNew,
            let storedRuleCount = try? modelContext.fetchCount(
              FetchDescriptor<MagentProxyRule>()
            )
          {
            pageAt = max(1, (storedRuleCount - 1) / Self.pageSize + 1)
          }
        }
      )
    }
    .alert(
      "打开规则表单失败",
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
    .alert(
      "规则同步失败",
      isPresented: Binding(
        get: { syncProxyRulesCoordinator.syncError != nil },
        set: { isPresented in
          if isPresented == false {
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
            do {
              proxyRuleViewModel = try ProxyRuleViewModel(
                modelContainer: modelContext.container
              )
              formError = nil
            } catch {
              formError = error.localizedDescription
            }
          },
          ContentToolbarButton(title: "同步规则", systemImage: "arrow.clockwise") {
            syncProxyRulesCoordinator.sync()
          },
        ]
      }
    }
  }

  /// 使用搜索条件和当前页对应的 `FetchDescriptor` 观察并展示最多 100 条代理规则。
  private struct ProxyRulePageView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var rules: [MagentProxyRule]
    @Binding private var pageAt: Int
    @Binding private var proxyRuleViewModel: ProxyRuleViewModel?
    @State private var editError: String?

    private let searchText: String
    private let pageSize: Int
    private let isRefreshing: Bool

    /// 为指定搜索条件和页码创建按规则 id 正序排列的 SwiftData 查询。
    init(
      searchText: String,
      pageAt: Binding<Int>,
      pageSize: Int,
      isRefreshing: Bool,
      proxyRuleViewModel: Binding<ProxyRuleViewModel?>
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
      _proxyRuleViewModel = proxyRuleViewModel
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
              Menu {
                Button {
                  do {
                    proxyRuleViewModel = try ProxyRuleViewModel(
                      modelContainer: modelContext.container,
                      ruleID: rule.id
                    )
                    editError = nil
                  } catch {
                    editError = error.localizedDescription
                  }
                } label: {
                  Label("编辑规则", systemImage: "pencil")
                }

                Button(role: .destructive) {
                  if proxyRuleViewModel?.id == rule.id {
                    proxyRuleViewModel = nil
                  }
                  modelContext.delete(rule)
                } label: {
                  Label("删除规则", systemImage: "trash")
                }
              } label: {
                Label("规则操作", systemImage: "ellipsis.circle")
                  .labelStyle(.iconOnly)
              }
              .help("规则操作")
            }
            .width(min: 72, ideal: 88, max: 96)
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        if pageAt > 1 || rules.count > pageSize {
          ControlGroup {
            Button {
              pageAt -= 1
            } label: {
              Label("上一页", systemImage: "chevron.backward")
                .labelStyle(.iconOnly)
            }
            .disabled(pageAt <= 1)
            .help("上一页")

            Button {
              pageAt += 1
            } label: {
              Label("下一页", systemImage: "chevron.forward")
                .labelStyle(.iconOnly)
            }
            .disabled(rules.count <= pageSize)
            .help("下一页")
          }
          .controlSize(.small)
          .padding(.vertical, 6)
        }
      }
      .alert(
        "读取代理规则失败",
        isPresented: Binding(
          get: { editError != nil },
          set: { isPresented in
            if isPresented == false {
              editError = nil
            }
          }
        )
      ) {
        Button("好", role: .cancel) {
          editError = nil
        }
      } message: {
        Text(editError ?? "")
      }
    }
  }

  /// 直接编辑独立 SwiftData 上下文中的代理规则，并内化保存与取消交互。
  private struct ProxyRuleFormView: View {
    @Environment(\.dismiss) private var dismiss
    let proxyRuleViewModel: ProxyRuleViewModel
    let onSaved: (Int) -> Void
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
          if let matchValueError {
            Label(
              matchValueError.localizedDescription,
              systemImage: "exclamationmark.triangle.fill"
            )
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
        ToolbarItem(placement: .cancellationAction) {
          Button("取消", role: .cancel) {
            proxyRuleViewModel.rollback()
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            do {
              try proxyRuleViewModel.save()
              saveError = nil
              onSaved(proxyRuleViewModel.id)
              dismiss()
            } catch {
              saveError = error.localizedDescription
            }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(matchValueError != nil)
        }
      }
      .alert(
        "保存代理规则失败",
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
        proxyRuleViewModel.rollback()
      }
    }
  }
}
