//
//  ProxyNodeViewModelTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Verifies isolated proxy-node form save and rollback behavior.
//

import Foundation
import Magent
import SwiftData
import Testing

@testable import MagentX

/// `ProxyNodeViewModel` 新增与修改事务的显式保存和取消测试。
@MainActor
struct ProxyNodeViewModelTests {
  /// 验证新增表单对象在保存前不属于任何上下文，避免被共享 `@Query` 提前发布。
  @Test func addKeepsNewNodeDetachedUntilSave() throws {
    let container = try makeContainer()
    let viewModel = ProxyNodeViewModel(modelContainer: container)

    #expect(viewModel.node.modelContext == nil)

    viewModel.node.address = "detached.example.com"
    viewModel.node.password = "password"
    try viewModel.save()

    #expect(viewModel.node.modelContext != nil)
  }

  /// 验证新增节点只有在显式保存后才会进入共享存储。
  @Test func addPersistsOnlyAfterSave() throws {
    let container = try makeContainer()
    let viewModel = ProxyNodeViewModel(modelContainer: container)
    viewModel.node.address = "new.example.com"
    viewModel.node.password = "password"

    let beforeSaveContext = ModelContext(container)
    #expect(try beforeSaveContext.fetchCount(FetchDescriptor<MagentProxyNode>()) == 0)

    try viewModel.save()

    let afterSaveContext = ModelContext(container)
    let storedNode = try #require(
      afterSaveContext.fetch(FetchDescriptor<MagentProxyNode>()).first
    )
    #expect(storedNode.id == viewModel.node.id)
    #expect(storedNode.address == "new.example.com")
    #expect(storedNode.name == "new.example.com:8388")
  }

  /// 验证新增节点重复保存不会再次插入同一个模型。
  @Test func addSaveDoesNotDuplicateNode() throws {
    let container = try makeContainer()
    let viewModel = ProxyNodeViewModel(modelContainer: container)
    viewModel.node.address = "single.example.com"
    viewModel.node.password = "password"

    try viewModel.save()
    try viewModel.save()

    let verificationContext = ModelContext(container)
    #expect(try verificationContext.fetchCount(FetchDescriptor<MagentProxyNode>()) == 1)
  }

  /// 验证保存后的唯一节点由列表上下文读取并删除时可以正常清空存储。
  @Test func savedNodeCanBeDeletedAsOnlyListRow() throws {
    let container = try makeContainer()
    let viewModel = ProxyNodeViewModel(modelContainer: container)
    viewModel.node.address = "delete.example.com"
    viewModel.node.password = "password"
    try viewModel.save()

    let listContext = ModelContext(container)
    let storedNode = try #require(
      listContext.fetch(FetchDescriptor<MagentProxyNode>()).first
    )
    #expect(storedNode.modelContext === listContext)

    listContext.delete(storedNode)
    try listContext.save()

    let verificationContext = ModelContext(container)
    #expect(try verificationContext.fetchCount(FetchDescriptor<MagentProxyNode>()) == 0)
  }

  /// 验证修改节点在显式保存前不会更改共享存储中的原值。
  @Test func editPersistsOnlyAfterSave() throws {
    let container = try makeContainer()
    let nodeID = try insertStoredNode(into: container)
    let viewModel = try ProxyNodeViewModel(modelContainer: container, nodeID: nodeID)
    viewModel.node.address = "changed.example.com"

    let beforeSaveContext = ModelContext(container)
    let beforeSaveNode = try #require(
      beforeSaveContext.fetch(FetchDescriptor<MagentProxyNode>()).first
    )
    #expect(beforeSaveNode.address == "stored.example.com")

    try viewModel.save()

    let afterSaveContext = ModelContext(container)
    let afterSaveNode = try #require(
      afterSaveContext.fetch(FetchDescriptor<MagentProxyNode>()).first
    )
    #expect(afterSaveNode.address == "changed.example.com")
  }

  /// 验证仅包含空白字符的名称会在保存时替换为地址与端口组合。
  @Test func saveGeneratesNameFromAddressAndPort() throws {
    let container = try makeContainer()
    let viewModel = ProxyNodeViewModel(modelContainer: container)
    viewModel.node.name = "  "
    viewModel.node.address = "named.example.com"
    viewModel.node.port = 443
    viewModel.node.password = "password"

    try viewModel.save()

    let verificationContext = ModelContext(container)
    let storedNode = try #require(
      verificationContext.fetch(FetchDescriptor<MagentProxyNode>()).first
    )
    #expect(storedNode.name == "named.example.com:443")
  }

  /// 验证保存入口拒绝无法由表单 Picker 或数字输入产生的非法持久化值。
  @Test func saveRejectsInvalidPersistentValues() throws {
    let container = try makeContainer()
    let viewModel = ProxyNodeViewModel(modelContainer: container)

    #expect(throws: MagentXError.invalidParameter(String(localized: "Address is required"))) {
      try viewModel.save()
    }

    viewModel.node.address = "bad host"
    #expect(
      throws: MagentXError.invalidParameter(
        String(localized: "Address must be a hostname, IPv4 address, or IPv6 address")
      )
    ) {
      try viewModel.save()
    }

    viewModel.node.address = "validation.example.com"
    viewModel.node.port = 0
    #expect(
      throws: MagentXError.invalidParameter(
        String(localized: "Port must be an integer from 1 to 65535")
      )
    ) {
      try viewModel.save()
    }

    viewModel.node.port = 8388
    #expect(throws: MagentXError.invalidParameter(String(localized: "Password is required"))) {
      try viewModel.save()
    }

    viewModel.node.password = "password"
    viewModel.node.type = "unsupported"
    #expect(
      throws: MagentXError.invalidParameter(
        String(format: String(localized: "Proxy node type is invalid: %@"), "unsupported")
      )
    ) {
      try viewModel.save()
    }

    viewModel.node.type = ProxyNodeType.shadowsocks.rawValue
    viewModel.node.cipher = "unsupported"
    #expect(
      throws: MagentXError.invalidParameter(
        String(format: String(localized: "Proxy cipher is invalid: %@"), "unsupported")
      )
    ) {
      try viewModel.save()
    }

    viewModel.node.cipher = ProxyCipher.chacha20IetfPoly1305.rawValue
    viewModel.node.timeout = .infinity
    #expect(
      throws: MagentXError.invalidParameter(
        String(localized: "Timeout must be a positive integer")
      )
    ) {
      try viewModel.save()
    }

    let verificationContext = ModelContext(container)
    #expect(try verificationContext.fetchCount(FetchDescriptor<MagentProxyNode>()) == 0)
  }

  /// 验证取消新增会丢弃独立上下文中的待插入节点。
  @Test func addRollbackDiscardsPendingNode() throws {
    let container = try makeContainer()
    let viewModel = ProxyNodeViewModel(modelContainer: container)
    viewModel.node.address = "cancelled.example.com"

    viewModel.rollback()

    let verificationContext = ModelContext(container)
    #expect(try verificationContext.fetchCount(FetchDescriptor<MagentProxyNode>()) == 0)
  }

  /// 验证取消修改会恢复独立上下文的原值，且不会更改共享存储。
  @Test func editRollbackRestoresStoredNode() throws {
    let container = try makeContainer()
    let nodeID = try insertStoredNode(into: container)
    let viewModel = try ProxyNodeViewModel(modelContainer: container, nodeID: nodeID)
    viewModel.node.address = "cancelled.example.com"

    viewModel.rollback()

    #expect(viewModel.node.address == "stored.example.com")
    let verificationContext = ModelContext(container)
    let storedNode = try #require(
      verificationContext.fetch(FetchDescriptor<MagentProxyNode>()).first
    )
    #expect(storedNode.address == "stored.example.com")
  }

  private func makeContainer() throws -> ModelContainer {
    try ModelContainer(
      for: MagentProxyNode.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
  }

  private func insertStoredNode(into container: ModelContainer) throws -> UUID {
    let modelContext = ModelContext(container)
    let node = MagentProxyNode(
      name: "Stored",
      type: ProxyNodeType.shadowsocks.rawValue,
      address: "stored.example.com",
      port: 8388,
      cipher: ProxyCipher.chacha20IetfPoly1305.rawValue,
      password: "password",
      timeout: 30,
      createdAt: .now,
      updatedAt: .now
    )
    modelContext.insert(node)
    try modelContext.save()
    return node.id
  }
}
