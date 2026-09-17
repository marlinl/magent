//
//  ProxyPolicyViewModel.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Isolates one proxy-policy form transaction from the shared main ModelContext.
//

import Foundation
import SwiftData

/// 代理策略表单的独立 SwiftData 编辑上下文，统一承载新增、修改、保存和取消语义。
@MainActor
struct ProxyPolicyViewModel: Identifiable {
  let policy: MagentProxyPolicy
  let isNew: Bool

  private let modelContext: ModelContext

  var id: Int {
    policy.id
  }

  /// 使用第一个可用代理节点创建尚未持久化的代理策略。
  ///
  /// - Parameter modelContainer: 与应用主上下文共享存储的 SwiftData 容器。
  /// - Throws: 没有代理节点或无法分配策略业务 id 时抛出对应错误。
  init(modelContainer: ModelContainer) throws {
    let modelContext = ModelContext(modelContainer)
    modelContext.autosaveEnabled = false

    var nodeDescriptor = FetchDescriptor<MagentProxyNode>(
      sortBy: [SortDescriptor(\MagentProxyNode.id, order: .forward)]
    )
    nodeDescriptor.fetchLimit = 1
    guard let node = try modelContext.fetch(nodeDescriptor).first else {
      throw MagentXError.invalidParameter(
        String(localized: "Add a proxy node before creating a policy")
      )
    }

    var policyDescriptor = FetchDescriptor<MagentProxyPolicy>(
      sortBy: [SortDescriptor(\MagentProxyPolicy.id, order: .reverse)]
    )
    policyDescriptor.fetchLimit = 1
    let lastPolicyID = try modelContext.fetch(policyDescriptor).first?.id
    guard lastPolicyID != Int.max else {
      throw MagentXError.invalidParameter(
        String(localized: "No available proxy policy identifier")
      )
    }

    let now = Date.now
    let policy = MagentProxyPolicy(
      id: lastPolicyID.map { $0 + 1 } ?? 0,
      name: "",
      nodeID: node.id,
      createdAt: now,
      updatedAt: now
    )
    self.modelContext = modelContext
    self.policy = policy
    isNew = true
  }

  /// 在独立编辑上下文中读取指定的已存储代理策略。
  ///
  /// - Parameters:
  ///   - modelContainer: 与应用主上下文共享存储的 SwiftData 容器。
  ///   - policyID: 需要修改的代理策略业务 id。
  /// - Throws: 读取失败或策略不存在时抛出对应错误。
  init(modelContainer: ModelContainer, policyID: Int) throws {
    let modelContext = ModelContext(modelContainer)
    modelContext.autosaveEnabled = false
    let targetPolicyID = policyID
    let descriptor = FetchDescriptor<MagentProxyPolicy>(
      predicate: #Predicate<MagentProxyPolicy> { policy in
        policy.id == targetPolicyID
      }
    )
    guard let policy = try modelContext.fetch(descriptor).first else {
      throw MagentXError.invalidParameter(
        String(
          format: String(localized: "Proxy policy does not exist: %d"),
          policyID
        )
      )
    }
    self.modelContext = modelContext
    self.policy = policy
    isNew = false
  }

  /// 校验并一次性提交当前表单策略的全部待保存变更。
  ///
  /// - Throws: 字段校验、节点关联或 SwiftData 持久化失败时抛出对应错误。
  func save() throws {
    try validate()

    policy.name = policy.name.trimmingCharacters(in: .whitespacesAndNewlines)
    policy.updatedAt = .now
    let shouldInsert = isNew && policy.modelContext == nil
    if shouldInsert {
      modelContext.insert(policy)
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
    guard policy.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      throw MagentXError.invalidParameter(String(localized: "Name is required"))
    }

    let targetNodeID = policy.nodeID
    let nodeDescriptor = FetchDescriptor<MagentProxyNode>(
      predicate: #Predicate<MagentProxyNode> { node in
        node.id == targetNodeID
      }
    )
    guard try modelContext.fetchCount(nodeDescriptor) == 1 else {
      throw MagentXError.invalidParameter(
        String(localized: "Selected proxy node does not exist")
      )
    }

    let targetPolicyID = policy.id
    let policyDescriptor = FetchDescriptor<MagentProxyPolicy>(
      predicate: #Predicate<MagentProxyPolicy> { storedPolicy in
        storedPolicy.nodeID == targetNodeID && storedPolicy.id != targetPolicyID
      }
    )
    guard try modelContext.fetchCount(policyDescriptor) == 0 else {
      throw MagentXError.invalidParameter(
        String(localized: "Proxy node already belongs to another policy")
      )
    }
  }
}
