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
  @FocusState private var isSearchFocused: Bool
  @State private var selectedRuleID: Int?
  @State private var proxyRuleViewModel: ProxyRuleViewModel?
  @State private var formError: String?

  private static let maximumCachedModelCount = 1_000

  var body: some View {
    let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let content = ProxyRuleTableView(
      searchText: normalizedSearchText,
      maximumCachedModelCount: Self.maximumCachedModelCount,
      selectedRuleID: $selectedRuleID,
      proxyRuleViewModel: $proxyRuleViewModel
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索规则")
        .searchFocused($isSearchFocused)
    }
    .sheet(item: $proxyRuleViewModel) { viewModel in
      ProxyRuleFormView(
        proxyRuleViewModel: viewModel,
        onSaved: { ruleID in
          selectedRuleID = ruleID
          searchText = ""
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

  /// 观察有数量上限的代理规则模型，并由系统表格管理可见行及缓冲区。
  private struct ProxyRuleTableView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding private var selectedRuleID: Int?
    @Binding private var proxyRuleViewModel: ProxyRuleViewModel?
    @State private var editError: String?

    private let searchText: String
    private let maximumCachedModelCount: Int

    /// 接收规则页面持有的选择和编辑绑定，并将查询条件交给公共表格。
    init(
      searchText: String,
      maximumCachedModelCount: Int,
      selectedRuleID: Binding<Int?>,
      proxyRuleViewModel: Binding<ProxyRuleViewModel?>
    ) {
      _selectedRuleID = selectedRuleID
      _proxyRuleViewModel = proxyRuleViewModel
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
        selection: $selectedRuleID,
        descriptor: descriptor,
        queryID: searchText,
        maximumCachedModelCount: maximumCachedModelCount,
      ) {
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
              if selectedRuleID == rule.id { selectedRuleID = nil }
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
