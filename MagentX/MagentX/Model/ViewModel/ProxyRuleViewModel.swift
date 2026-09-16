//
//  ProxyRuleViewModel.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Isolates one proxy-rule form transaction from the shared main ModelContext.
//

import Foundation
import Magent
import SwiftData

/// 代理规则表单的独立 SwiftData 编辑上下文，统一承载新增、修改、保存和取消语义。
@MainActor
struct ProxyRuleViewModel: Identifiable {
  let rule: MagentProxyRule
  let isNew: Bool

  private let modelContext: ModelContext

  var id: Int {
    rule.id
  }

  /// 在独立编辑上下文中创建尚未持久化的默认代理规则。
  ///
  /// - Parameter modelContainer: 与应用主上下文共享存储的 SwiftData 容器。
  /// - Throws: 读取已存储规则或分配业务 id 失败时抛出对应错误。
  init(modelContainer: ModelContainer) throws {
    let modelContext = ModelContext(modelContainer)
    modelContext.autosaveEnabled = false

    var descriptor = FetchDescriptor<MagentProxyRule>(
      sortBy: [SortDescriptor(\MagentProxyRule.id, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    let lastRuleID = try modelContext.fetch(descriptor).first?.id
    guard lastRuleID != Int.max else {
      throw MagentXError.invalidParameter(
        String(localized: "No available proxy rule identifier")
      )
    }

    let now = Date.now
    let rule = MagentProxyRule(
      id: lastRuleID.map { $0 + 1 } ?? 0,
      matchType: MatchType.domainSuffix.rawValue,
      matchValue: "",
      decision: "proxy",
      order: 0,
      source: "user",
      createdAt: now,
      updatedAt: now
    )
    self.modelContext = modelContext
    self.rule = rule
    isNew = true
  }

  /// 在独立编辑上下文中读取指定的已存储代理规则。
  ///
  /// - Parameters:
  ///   - modelContainer: 与应用主上下文共享存储的 SwiftData 容器。
  ///   - ruleID: 需要修改的代理规则业务 id。
  /// - Throws: 读取失败或规则不存在时抛出原始错误或 `MagentXError.missingMagentProxyRule`。
  init(modelContainer: ModelContainer, ruleID: Int) throws {
    let modelContext = ModelContext(modelContainer)
    modelContext.autosaveEnabled = false
    let targetRuleID = ruleID
    let descriptor = FetchDescriptor<MagentProxyRule>(
      predicate: #Predicate<MagentProxyRule> { rule in
        rule.id == targetRuleID
      }
    )
    guard let rule = try modelContext.fetch(descriptor).first else {
      throw MagentXError.missingMagentProxyRule(ruleID)
    }
    self.modelContext = modelContext
    self.rule = rule
    isNew = false
  }

  /// 校验并一次性提交当前表单规则的全部待保存变更。
  ///
  /// - Throws: 字段校验或 SwiftData 持久化失败时抛出对应错误。
  func save() throws {
    try validate()

    rule.source = "user"
    rule.updatedAt = .now
    let shouldInsert = isNew && rule.modelContext == nil
    if shouldInsert {
      modelContext.insert(rule)
    }
    do {
      try modelContext.save()
    } catch {
      if shouldInsert {
        modelContext.rollback()
      }
      throw error
    }
  }

  /// 撤销当前表单上下文中尚未保存的新增或修改。
  func rollback() {
    guard modelContext.hasChanges else { return }
    modelContext.rollback()
  }

  private func validate() throws {
    guard MatchType(rawValue: rule.matchType) != nil else {
      throw MagentXError.invalidParameter(
        String(format: String(localized: "Proxy rule match type is invalid: %@"), rule.matchType)
      )
    }
    guard ["direct", "proxy"].contains(rule.decision) else {
      throw MagentXError.invalidParameter(String(localized: "Decision must be direct or proxy"))
    }

    let rules = try modelContext.fetch(FetchDescriptor<MagentProxyRule>())
    if let validationError = rule.validationError(in: rules) {
      throw validationError
    }
  }
}
