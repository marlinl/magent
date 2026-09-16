//
//  ProxyRuleViewModelTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Verifies isolated proxy-rule form save and rollback behavior.
//

import Foundation
import Magent
import SwiftData
import Testing

@testable import MagentX

/// `ProxyRuleViewModel` 新增与修改事务的显式保存、取消和校验测试。
@MainActor
struct ProxyRuleViewModelTests {
  /// 验证新增表单对象在保存前不属于任何上下文，避免被共享 `@Query` 提前发布。
  @Test func addKeepsNewRuleDetachedUntilSave() throws {
    let container = try makeContainer()
    let viewModel = try ProxyRuleViewModel(modelContainer: container)

    #expect(viewModel.rule.modelContext == nil)

    viewModel.rule.matchValue = "detached.example.com"
    try viewModel.save()

    #expect(viewModel.rule.modelContext != nil)
  }

  /// 验证新增规则只有在显式保存后才会进入共享存储。
  @Test func addPersistsOnlyAfterSave() throws {
    let container = try makeContainer()
    let viewModel = try ProxyRuleViewModel(modelContainer: container)
    viewModel.rule.matchValue = "new.example.com"

    let beforeSaveContext = ModelContext(container)
    #expect(try beforeSaveContext.fetchCount(FetchDescriptor<MagentProxyRule>()) == 0)

    try viewModel.save()

    let afterSaveContext = ModelContext(container)
    let storedRule = try #require(
      afterSaveContext.fetch(FetchDescriptor<MagentProxyRule>()).first
    )
    #expect(storedRule.id == viewModel.id)
    #expect(storedRule.matchType == MatchType.domainSuffix.rawValue)
    #expect(storedRule.matchValue == "new.example.com")
    #expect(storedRule.decision == "proxy")
    #expect(storedRule.source == "user")
  }

  /// 验证新增规则重复保存不会再次插入同一个模型。
  @Test func addSaveDoesNotDuplicateRule() throws {
    let container = try makeContainer()
    let viewModel = try ProxyRuleViewModel(modelContainer: container)
    viewModel.rule.matchValue = "single.example.com"

    try viewModel.save()
    try viewModel.save()

    let verificationContext = ModelContext(container)
    #expect(try verificationContext.fetchCount(FetchDescriptor<MagentProxyRule>()) == 1)
  }

  /// 验证保存后的唯一规则由列表上下文读取并删除时可以正常清空存储。
  @Test func savedRuleCanBeDeletedAsOnlyListRow() throws {
    let container = try makeContainer()
    let viewModel = try ProxyRuleViewModel(modelContainer: container)
    viewModel.rule.matchValue = "delete.example.com"
    try viewModel.save()

    let listContext = ModelContext(container)
    let storedRule = try #require(
      listContext.fetch(FetchDescriptor<MagentProxyRule>()).first
    )
    #expect(storedRule.modelContext === listContext)

    listContext.delete(storedRule)
    try listContext.save()

    let verificationContext = ModelContext(container)
    #expect(try verificationContext.fetchCount(FetchDescriptor<MagentProxyRule>()) == 0)
  }

  /// 验证修改规则在显式保存前不会更改共享存储中的原值。
  @Test func editPersistsOnlyAfterSave() throws {
    let container = try makeContainer()
    let ruleID = try insertStoredRule(into: container)
    let viewModel = try ProxyRuleViewModel(modelContainer: container, ruleID: ruleID)
    viewModel.rule.matchValue = "changed.example.com"
    viewModel.rule.decision = "direct"

    let beforeSaveContext = ModelContext(container)
    let beforeSaveRule = try #require(
      beforeSaveContext.fetch(FetchDescriptor<MagentProxyRule>()).first
    )
    #expect(beforeSaveRule.matchValue == "stored.example.com")
    #expect(beforeSaveRule.decision == "proxy")

    try viewModel.save()

    let afterSaveContext = ModelContext(container)
    let afterSaveRule = try #require(
      afterSaveContext.fetch(FetchDescriptor<MagentProxyRule>()).first
    )
    #expect(afterSaveRule.matchValue == "changed.example.com")
    #expect(afterSaveRule.decision == "direct")
    #expect(afterSaveRule.source == "user")
    #expect(afterSaveRule.updatedAt > Date(timeIntervalSince1970: 0))
  }

  /// 验证取消新增会丢弃独立上下文中的待插入规则。
  @Test func addRollbackDiscardsPendingRule() throws {
    let container = try makeContainer()
    let viewModel = try ProxyRuleViewModel(modelContainer: container)
    viewModel.rule.matchValue = "cancelled.example.com"

    viewModel.rollback()

    let verificationContext = ModelContext(container)
    #expect(try verificationContext.fetchCount(FetchDescriptor<MagentProxyRule>()) == 0)
  }

  /// 验证取消修改会恢复独立上下文的原值，且不会更改共享存储。
  @Test func editRollbackRestoresStoredRule() throws {
    let container = try makeContainer()
    let ruleID = try insertStoredRule(into: container)
    let viewModel = try ProxyRuleViewModel(modelContainer: container, ruleID: ruleID)
    viewModel.rule.matchValue = "cancelled.example.com"

    viewModel.rollback()

    #expect(viewModel.rule.matchValue == "stored.example.com")
    let verificationContext = ModelContext(container)
    let storedRule = try #require(
      verificationContext.fetch(FetchDescriptor<MagentProxyRule>()).first
    )
    #expect(storedRule.matchValue == "stored.example.com")
  }

  /// 验证保存入口拒绝空匹配值、非法匹配类型和非法动作。
  @Test func saveRejectsInvalidPersistentValues() throws {
    let container = try makeContainer()
    let viewModel = try ProxyRuleViewModel(modelContainer: container)

    #expect(throws: MagentXError.invalidParameter(String(localized: "Match value is required"))) {
      try viewModel.save()
    }

    viewModel.rule.matchValue = "validation.example.com"
    viewModel.rule.matchType = "unsupported"
    #expect(
      throws: MagentXError.invalidParameter(
        String(
          format: String(localized: "Proxy rule match type is invalid: %@"),
          "unsupported"
        )
      )
    ) {
      try viewModel.save()
    }

    viewModel.rule.matchType = MatchType.domainSuffix.rawValue
    viewModel.rule.decision = "unsupported"
    #expect(
      throws: MagentXError.invalidParameter(
        String(localized: "Decision must be direct or proxy")
      )
    ) {
      try viewModel.save()
    }

    let verificationContext = ModelContext(container)
    #expect(try verificationContext.fetchCount(FetchDescriptor<MagentProxyRule>()) == 0)
  }

  /// 验证保存入口按匹配类型和匹配值组合拒绝重复规则。
  @Test func saveRejectsDuplicateBusinessIdentity() throws {
    let container = try makeContainer()
    _ = try insertStoredRule(into: container)
    let viewModel = try ProxyRuleViewModel(modelContainer: container)
    viewModel.rule.matchValue = "stored.example.com"

    #expect(throws: MagentXError.duplicateMagentProxyRule) {
      try viewModel.save()
    }

    let verificationContext = ModelContext(container)
    #expect(try verificationContext.fetchCount(FetchDescriptor<MagentProxyRule>()) == 1)
  }

  /// 验证业务 id 已达到上限时不会创建溢出的新规则。
  @Test func addRejectsIdentifierOverflow() throws {
    let container = try makeContainer()
    let modelContext = ModelContext(container)
    modelContext.insert(
      MagentProxyRule(
        id: Int.max,
        matchType: MatchType.domainSuffix.rawValue,
        matchValue: "maximum.example.com",
        decision: "proxy",
        order: 0,
        source: "user"
      )
    )
    try modelContext.save()

    #expect(
      throws: MagentXError.invalidParameter(
        String(localized: "No available proxy rule identifier")
      )
    ) {
      _ = try ProxyRuleViewModel(modelContainer: container)
    }
  }

  private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
      for: MagentProxyRule.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
  }

  private func insertStoredRule(into container: ModelContainer) throws -> Int {
    let modelContext = ModelContext(container)
    let rule = MagentProxyRule(
      id: 1,
      matchType: MatchType.domainSuffix.rawValue,
      matchValue: "stored.example.com",
      decision: "proxy",
      order: 100,
      source: "subscription",
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 0)
    )
    modelContext.insert(rule)
    try modelContext.save()
    return rule.id
  }
}
