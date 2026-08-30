//
//  PolicyController.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Coordinates proxy policy group business operations.
//

import Combine
import Foundation
import SwiftData

/// 代理策略业务控制器，负责策略组及其规则关联记录的读取和写入。
@MainActor
final class PolicyController: ObservableObject {
    @Published private(set) var proxyPolicies: [ProxyPolicy] = []
    @Published private(set) var loadError: String?

    /// 加载代理策略组，可按策略组 id 过滤。
    func load(from modelContext: ModelContext, id: UUID? = nil) {
        let descriptor: FetchDescriptor<ProxyPolicy>
        if let id {
            descriptor = FetchDescriptor<ProxyPolicy>(
                predicate: #Predicate<ProxyPolicy> { policy in
                    policy.id == id
                }
            )
        } else {
            descriptor = FetchDescriptor<ProxyPolicy>()
        }

        do {
            proxyPolicies = try modelContext.fetch(descriptor).sorted(by: Self.sortPolicies)
            loadError = nil
        } catch {
            proxyPolicies = []
            loadError = error.localizedDescription
        }
    }

    /// 创建或更新策略组，并同步该组关联的访问规则。
    @discardableResult
    func upsertProxyPolicy(
        id: UUID = UUID(),
        name: String,
        suffixDomain: String = "",
        magentNodeID: UUID? = nil,
        ruleIDs: [UUID],
        in modelContext: ModelContext
    ) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.isEmpty == false else {
            loadError = MagentXError.emptyName.localizedDescription
            return false
        }

        do {
            if let magentNodeID,
               try magentProxyNode(id: magentNodeID, in: modelContext) == nil {
                loadError = MagentXError.missingMagentProxyNode(magentNodeID).localizedDescription
                return false
            }

            let accessControlRules = try loadAccessControlRules(ids: Self.uniqueIDs(ruleIDs), in: modelContext)
            let proxyPolicy: ProxyPolicy
            if let existingPolicy = try existingProxyPolicy(id: id, in: modelContext) {
                existingPolicy.name = normalizedName
                existingPolicy.suffixDomain = suffixDomain.trimmingCharacters(in: .whitespacesAndNewlines)
                existingPolicy.magentNodeID = magentNodeID
                proxyPolicy = existingPolicy
            } else {
                let newPolicy = ProxyPolicy(
                    id: id,
                    name: normalizedName,
                    suffixDomain: suffixDomain,
                    magentNodeID: magentNodeID
                )
                modelContext.insert(newPolicy)
                proxyPolicy = newPolicy
            }

            try syncRules(accessControlRules, for: proxyPolicy, in: modelContext)
            try modelContext.save()
            load(from: modelContext, id: id)
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    /// 删除代理策略组，并通过级联关系清理其规则关联记录。
    func deleteProxyPolicy(_ proxyPolicy: ProxyPolicy, from modelContext: ModelContext) {
        let id = proxyPolicy.id

        do {
            modelContext.delete(proxyPolicy)
            try modelContext.save()
            load(from: modelContext, id: id)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func existingProxyPolicy(id: UUID, in modelContext: ModelContext) throws -> ProxyPolicy? {
        let descriptor = FetchDescriptor<ProxyPolicy>(
            predicate: #Predicate<ProxyPolicy> { proxyPolicy in
                proxyPolicy.id == id
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func accessControlRule(id: UUID, in modelContext: ModelContext) throws -> AccessControlRule? {
        let descriptor = FetchDescriptor<AccessControlRule>(
            predicate: #Predicate<AccessControlRule> { accessControlRule in
                accessControlRule.id == id
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func magentProxyNode(id: UUID, in modelContext: ModelContext) throws -> MagentProxyNode? {
        let descriptor = FetchDescriptor<MagentProxyNode>(
            predicate: #Predicate<MagentProxyNode> { magentProxyNode in
                magentProxyNode.id == id
            }
        )
        return try modelContext.fetch(descriptor).first
    }

    private func loadAccessControlRules(
        ids: [UUID],
        in modelContext: ModelContext
    ) throws -> [AccessControlRule] {
        var accessControlRules: [AccessControlRule] = []
        for id in ids {
            guard let accessControlRule = try accessControlRule(id: id, in: modelContext) else {
                throw MagentXError.missingAccessControlRule(id)
            }
            accessControlRules.append(accessControlRule)
        }
        return accessControlRules
    }

    private func syncRules(
        _ accessControlRules: [AccessControlRule],
        for proxyPolicy: ProxyPolicy,
        in modelContext: ModelContext
    ) throws {
        let policyID = proxyPolicy.id
        let descriptor = FetchDescriptor<ProxyPolicyRule>(
            predicate: #Predicate<ProxyPolicyRule> { proxyPolicyRule in
                proxyPolicyRule.id == policyID
            }
        )
        let existingPolicyRules = try modelContext.fetch(descriptor)
        let desiredRuleIDs = Set(accessControlRules.map(\.id))
        let existingRuleIDs = Set(existingPolicyRules.map(\.ruleID))

        for existingPolicyRule in existingPolicyRules where desiredRuleIDs.contains(existingPolicyRule.ruleID) == false {
            modelContext.delete(existingPolicyRule)
        }

        for accessControlRule in accessControlRules where existingRuleIDs.contains(accessControlRule.id) == false {
            modelContext.insert(ProxyPolicyRule(
                proxyPolicy: proxyPolicy,
                accessControlRule: accessControlRule
            ))
        }
    }

    private static func uniqueIDs(_ ids: [UUID]) -> [UUID] {
        var seenIDs = Set<UUID>()
        var uniqueIDs: [UUID] = []
        for id in ids where seenIDs.insert(id).inserted {
            uniqueIDs.append(id)
        }
        return uniqueIDs
    }

    private static func sortPolicies(_ lhs: ProxyPolicy, _ rhs: ProxyPolicy) -> Bool {
        let leftKey = "\(lhs.name):\(lhs.id.uuidString)"
        let rightKey = "\(rhs.name):\(rhs.id.uuidString)"
        return leftKey.localizedStandardCompare(rightKey) == .orderedAscending
    }
}
