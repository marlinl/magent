//
//  ProxyNodeViewModel.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Isolates one proxy-node form transaction from the shared main ModelContext.
//

import Foundation
import Magent
import SwiftData

/// 代理节点表单的独立 SwiftData 编辑上下文，统一承载新增、修改、保存和取消语义。
@MainActor
struct ProxyNodeViewModel: Identifiable {
  let node: MagentProxyNode
  let isNew: Bool

  private let modelContext: ModelContext

  var id: UUID {
    node.id
  }

  /// 在独立编辑上下文中创建尚未持久化的默认代理节点。
  ///
  /// - Parameter modelContainer: 与应用主上下文共享存储的 SwiftData 容器。
  init(modelContainer: ModelContainer) {
    let modelContext = ModelContext(modelContainer)
    modelContext.autosaveEnabled = false
    let now = Date.now
    let node = MagentProxyNode(
      id: MagentProxyNode.makeUUIDVersion7(at: now),
      name: "",
      type: ProxyNodeType.shadowsocks.rawValue,
      address: "",
      port: 8388,
      cipher: ProxyCipher.chacha20IetfPoly1305.rawValue,
      password: "",
      timeout: 30,
      createdAt: now,
      updatedAt: now
    )
    self.modelContext = modelContext
    self.node = node
    isNew = true
  }

  /// 在独立编辑上下文中读取指定的已存储代理节点。
  ///
  /// - Parameters:
  ///   - modelContainer: 与应用主上下文共享存储的 SwiftData 容器。
  ///   - nodeID: 需要修改的代理节点业务 id。
  /// - Throws: 读取失败或节点不存在时抛出原始错误或 `MagentXError.missingMagentProxyNode`。
  init(modelContainer: ModelContainer, nodeID: UUID) throws {
    let modelContext = ModelContext(modelContainer)
    modelContext.autosaveEnabled = false
    let targetNodeID = nodeID
    let descriptor = FetchDescriptor<MagentProxyNode>(
      predicate: #Predicate<MagentProxyNode> { node in
        node.id == targetNodeID
      }
    )
    guard let node = try modelContext.fetch(descriptor).first else {
      throw MagentXError.missingMagentProxyNode(nodeID)
    }
    self.modelContext = modelContext
    self.node = node
    isNew = false
  }

  /// 校验并一次性提交当前表单节点的全部待保存变更。
  ///
  /// - Throws: 字段校验或 SwiftData 持久化失败时抛出对应错误。
  func save() throws {
    try validate()

    if node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      node.name = "\(node.address):\(node.port)"
    }
    node.updatedAt = .now
    let shouldInsert = isNew && node.modelContext == nil
    if shouldInsert {
      modelContext.insert(node)
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
    let normalizedAddress = node.address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedAddress.isEmpty == false else {
      throw MagentXError.invalidParameter(String(localized: "Address is required"))
    }
    guard MagentProxyNode.isValidAddress(node.address) else {
      throw MagentXError.invalidParameter(
        String(localized: "Address must be a hostname, IPv4 address, or IPv6 address")
      )
    }
    guard (1...65_535).contains(node.port) else {
      throw MagentXError.invalidParameter(
        String(localized: "Port must be an integer from 1 to 65535")
      )
    }
    guard ProxyNodeType(rawValue: node.type) != nil else {
      throw MagentXError.invalidParameter(
        String(format: String(localized: "Proxy node type is invalid: %@"), node.type)
      )
    }
    guard ProxyCipher(rawValue: node.cipher) != nil else {
      throw MagentXError.invalidParameter(
        String(format: String(localized: "Proxy cipher is invalid: %@"), node.cipher)
      )
    }
    guard node.password.isEmpty == false else {
      throw MagentXError.invalidParameter(String(localized: "Password is required"))
    }
    guard node.timeout.isFinite, node.timeout >= 1 else {
      throw MagentXError.invalidParameter(String(localized: "Timeout must be a positive integer"))
    }
  }
}
