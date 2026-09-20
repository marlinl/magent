//
//  MagentService.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Owns the Magent core proxy lifecycle for the macOS app.
//

import Foundation
@preconcurrency import Magent
@preconcurrency import NIOCore
import SwiftData

/// Magent 运行服务，统一管理核心代理实例和运行配置。
actor MagentService {
  /// Magent 核心服务的当前运行状态。
  enum State: Equatable, Sendable {
    case running
    case idle
  }

  /// 当前 Magent 核心服务的运行状态。
  private(set) var state = State.idle
  private var magent: Magent

  /// 根据应用设置初始化非空的 Magent 核心实例。
  ///
  /// - Parameter appSettings: 提供核心服务线程数的应用设置。
  @MainActor init(appSettings: AppSettings = AppSettings.load()) {
    magent = Magent(threadNumber: appSettings.serviceThreadNumber)
  }

  /// 启动 Magent 核心服务。
  func start(
    modelContainer: ModelContainer,
    appSettings: AppSettings,
    generalSettings: GeneralSettings
  ) async throws {
  }

  /// 关闭 Magent 核心服务。
  func close() async throws {
  }

  /// 读取持久化的 Magent 模型并构建核心运行配置。
  ///
  /// - Parameters:
  ///   - modelContainer: 存储 Magent 节点、规则、策略及关联记录的模型容器。
  ///   - appSettings: 提供当前代理模式的应用设置。
  ///   - generalSettings: 提供本地代理监听地址和端口的常规设置。
  /// - Returns: 包含可用节点的运行配置；仅策略模式带匹配规则，无节点时采用直连。
  func getConfig(
    modelContainer: ModelContainer,
    appSettings: AppSettings,
    generalSettings: GeneralSettings
  ) throws -> MagentConfig {
    let modelContext = ModelContext(modelContainer)

    // 1. 查询全部已启用的代理策略。
    let enabledPolicies = try modelContext.fetch(
      FetchDescriptor<MagentProxyPolicy>(
        predicate: #Predicate { $0.enable },
        sortBy: [SortDescriptor(\MagentProxyPolicy.id, order: .forward)]
      )
    )
    let nodeIDByPolicyID = Dictionary(
      uniqueKeysWithValues: enabledPolicies.map { ($0.id, $0.nodeID) }
    )

    // 2. 根据已启用策略的 nodeID 查询并构建全部代理节点。
    let proxyNodes = queryNodeList(
      enabledPolicies.map(\.nodeID),
      modelContext: modelContext
    )
    let proxyNodesByID = Dictionary(uniqueKeysWithValues: proxyNodes.map { ($0.id, $0) })
    let policyProxyNode = enabledPolicies.lazy.compactMap {
      proxyNodesByID[$0.nodeID]
    }.first

    // 3. 仅策略模式装载匹配规则；全局和直连模式只使用默认决策。
    let defaultDecision: Decision
    let rules: [ProxyRule]
    switch appSettings.proxyMode {
    case .policy:
      defaultDecision = .direct
      rules = queryRuleList(
        enabledPolicies.map(\.id),
        nodeIDByPolicyID: nodeIDByPolicyID,
        modelContext: modelContext
      )
    case .global:
      defaultDecision = policyProxyNode.map { .proxy($0.id) } ?? .direct
      rules = []
    case .direct:
      defaultDecision = .direct
      rules = []
    }

    return MagentConfig(
      address: .domain(
        generalSettings.proxyListenAddress,
        port: generalSettings.proxyListenPort
      ),
      defaultDecision: defaultDecision,
      rules: rules,
      proxyNodes: proxyNodes
    )
  }

  /// 根据节点 ID 列表查询持久化节点，并转换为 Magent 代理节点。
  private func queryNodeList(
    _ nodeIDList: [UUID],
    modelContext: ModelContext
  ) -> [ProxyNode] {
    guard nodeIDList.isEmpty == false else { return [] }

    guard
      let storedNodes = try? modelContext.fetch(
        FetchDescriptor<MagentProxyNode>(
          predicate: #Predicate { nodeIDList.contains($0.id) },
          sortBy: [
            SortDescriptor(\MagentProxyNode.createdAt, order: .forward),
            SortDescriptor(\MagentProxyNode.id, order: .forward),
          ]
        )
      )
    else { return [] }

    return storedNodes.compactMap { storedNode in
      guard let type = ProxyNodeType(rawValue: storedNode.type),
        let cipher = ProxyCipher(rawValue: storedNode.cipher),
        let address = try? SocketAddress.makeAddressResolvingHost(
          storedNode.address,
          port: storedNode.port
        )
      else { return nil }

      return ProxyNode(
        id: storedNode.id,
        type: type,
        address: address,
        cipher: cipher,
        password: storedNode.password,
        timeout: storedNode.timeout
      )
    }
  }

  /// 根据策略 ID 列表查询关联规则，并转换为 Magent 代理规则。
  private func queryRuleList(
    _ policyIDList: [Int],
    nodeIDByPolicyID: [Int: UUID],
    modelContext: ModelContext
  ) -> [ProxyRule] {
    guard policyIDList.isEmpty == false else { return [] }

    guard
      let policyRules = try? modelContext.fetch(
        FetchDescriptor<MagentProxyPolicyRule>(
          predicate: #Predicate { policyIDList.contains($0.policyID) },
          sortBy: [
            SortDescriptor(\MagentProxyPolicyRule.policyID, order: .forward),
            SortDescriptor(\MagentProxyPolicyRule.ruleID, order: .forward),
          ]
        )
      )
    else { return [] }
    let associatedRuleIDs = policyRules.map(\.ruleID)
    guard associatedRuleIDs.isEmpty == false else { return [] }

    guard
      let storedRules = try? modelContext.fetch(
        FetchDescriptor<MagentProxyRule>(
          predicate: #Predicate { associatedRuleIDs.contains($0.id) },
          sortBy: [
            SortDescriptor(\MagentProxyRule.order, order: .forward),
            SortDescriptor(\MagentProxyRule.id, order: .forward),
          ]
        )
      )
    else { return [] }

    let policyIDByRuleID = Dictionary(
      uniqueKeysWithValues: policyRules.map { ($0.ruleID, $0.policyID) }
    )
    return storedRules.compactMap { storedRule in
      guard let policyID = policyIDByRuleID[storedRule.id],
        let nodeID = nodeIDByPolicyID[policyID],
        let matchType = MatchType(rawValue: storedRule.matchType),
        matchType != .urlRegex
      else { return nil }

      let decision: Decision
      switch storedRule.decision {
      case "direct":
        decision = .direct
      case "proxy":
        decision = .proxy(nodeID)
      default:
        return nil
      }

      return try? ProxyRule(
        matchType: matchType,
        matchValue: storedRule.matchValue,
        decision: decision,
        order: storedRule.order
      )
    }
  }
}
