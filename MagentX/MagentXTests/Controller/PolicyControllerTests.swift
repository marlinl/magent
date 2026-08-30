//
//  PolicyControllerTests.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Unit tests for proxy policy groups and rule joins.
//

import Foundation
import Magent
import SwiftData
import Testing
@testable import MagentX

/// `ProxyPolicy`、`ProxyPolicyRule` 模型和 `PolicyController` 写入流程的单元测试。
@MainActor
struct PolicyControllerTests {
    /// 验证代理策略组只保存自身 id、名称和代理节点外键。
    @Test func proxyPolicyStoresGroupIdentityAndNodeReference() {
        let policyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let magentNodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        let policy = ProxyPolicy(
            id: policyID,
            name: "  Streaming  ",
            suffixDomain: "  youtube.com  ",
            magentNodeID: magentNodeID
        )

        #expect(policy.id == policyID)
        #expect(policy.name == "Streaming")
        #expect(policy.suffixDomain == "youtube.com")
        #expect(policy.magentNodeID == magentNodeID)
    }

    /// 验证策略规则关联的 `id` 字段保存的是代理策略组 id。
    @Test func proxyPolicyRuleUsesPolicyIDAsIDForeignKey() {
        let policyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let ruleID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let policyRule = ProxyPolicyRule(id: policyID, ruleID: ruleID)

        #expect(policyRule.id == policyID)
        #expect(policyRule.ruleID == ruleID)
    }

    /// 验证 upsert 会写入一条策略组，并为每条规则写入 join 表记录。
    @Test func upsertProxyPolicyCreatesGroupAndPolicyRules() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let controller = PolicyController()
        let policyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let (rules, magentNode) = try makeReferencedModels(in: context)

        #expect(controller.upsertProxyPolicy(
            id: policyID,
            name: "Default Proxy",
            suffixDomain: "google.com",
            magentNodeID: magentNode.id,
            ruleIDs: rules.map(\.id),
            in: context
        ))

        let policies = try context.fetch(FetchDescriptor<ProxyPolicy>())
        let policyRules = try context.fetch(FetchDescriptor<ProxyPolicyRule>())

        #expect(policies.count == 1)
        #expect(policies[0].id == policyID)
        #expect(policies[0].name == "Default Proxy")
        #expect(policies[0].suffixDomain == "google.com")
        #expect(policies[0].magentNodeID == magentNode.id)
        #expect(Set(policyRules.map(\.id)) == [policyID])
        #expect(Set(policyRules.map(\.ruleID)) == Set(rules.map(\.id)))
    }

    /// 验证策略组允许不绑定 Magent 节点。
    @Test func upsertProxyPolicyAllowsEmptyMagentNodeID() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let controller = PolicyController()
        let policyID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let (rules, _) = try makeReferencedModels(in: context)

        #expect(controller.upsertProxyPolicy(
            id: policyID,
            name: "Unbound Policy",
            suffixDomain: "example.com",
            ruleIDs: [rules[0].id],
            in: context
        ))

        let policies = try context.fetch(FetchDescriptor<ProxyPolicy>())
        let policyRules = try context.fetch(FetchDescriptor<ProxyPolicyRule>())

        #expect(policies.count == 1)
        #expect(policies[0].magentNodeID == nil)
        #expect(policyRules.count == 1)
        #expect(policyRules[0].id == policyID)
    }

    /// 验证重复 upsert 同一策略组会更新组表字段并同步规则集合。
    @Test func upsertProxyPolicyUpdatesGroupAndSynchronizesPolicyRules() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let controller = PolicyController()
        let policyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let (rules, magentNode) = try makeReferencedModels(in: context)

        #expect(controller.upsertProxyPolicy(
            id: policyID,
            name: "Default Proxy",
            suffixDomain: "google.com",
            magentNodeID: magentNode.id,
            ruleIDs: rules.map(\.id),
            in: context
        ))
        #expect(controller.upsertProxyPolicy(
            id: policyID,
            name: "Streaming",
            suffixDomain: "  youtube.com  ",
            magentNodeID: magentNode.id,
            ruleIDs: [rules[0].id],
            in: context
        ))

        let policies = try context.fetch(FetchDescriptor<ProxyPolicy>())
        let policyRules = try context.fetch(FetchDescriptor<ProxyPolicyRule>())

        #expect(policies.count == 1)
        #expect(policies[0].name == "Streaming")
        #expect(policies[0].suffixDomain == "youtube.com")
        #expect(policyRules.count == 1)
        #expect(policyRules[0].id == policyID)
        #expect(policyRules[0].ruleID == rules[0].id)
    }

    /// 验证缺少被引用的访问规则或节点时不会写入孤儿策略。
    @Test func upsertProxyPolicyRejectsMissingReferences() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let controller = PolicyController()
        let policyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let accessControlRuleID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let magentNodeID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        #expect(controller.upsertProxyPolicy(
            id: policyID,
            name: "Default Proxy",
            magentNodeID: magentNodeID,
            ruleIDs: [accessControlRuleID],
            in: context
        ) == false)

        let policies = try context.fetch(FetchDescriptor<ProxyPolicy>())
        let policyRules = try context.fetch(FetchDescriptor<ProxyPolicyRule>())

        #expect(policies.isEmpty)
        #expect(policyRules.isEmpty)
    }

    /// 验证删除访问规则时只清理策略规则关联，不删除策略组。
    @Test func deletingAccessControlRuleDeletesProxyPolicyRules() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let policyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let (rules, magentNode) = try makeReferencedModels(in: context)

        #expect(PolicyController().upsertProxyPolicy(
            id: policyID,
            name: "Default Proxy",
            magentNodeID: magentNode.id,
            ruleIDs: rules.map(\.id),
            in: context
        ))

        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        RuleController(
            pacFileService: PacFileService(directoryURL: directoryURL),
            generalSettingsProvider: {
                GeneralSettings(proxyListenAddress: "127.0.0.1", proxyListenPort: 1086)
            }
        )
        .deleteAccessControl(rules[0], from: context)

        let policies = try context.fetch(FetchDescriptor<ProxyPolicy>())
        let policyRules = try context.fetch(FetchDescriptor<ProxyPolicyRule>())

        #expect(policies.count == 1)
        #expect(policyRules.count == 1)
        #expect(policyRules[0].ruleID == rules[1].id)
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ProxyPolicy.self,
            ProxyPolicyRule.self,
            AccessControlRule.self,
            MagentProxyNode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PolicyControllerTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeReferencedModels(in context: ModelContext) throws -> ([AccessControlRule], MagentProxyNode) {
        let firstRule = AccessControlRule(
            matchType: .domainSuffix,
            matchValue: "google.com",
            decision: "proxy"
        )
        let secondRule = AccessControlRule(
            matchType: .domainSuffix,
            matchValue: "youtube.com",
            decision: "proxy"
        )
        let magentNode = MagentProxyNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Test Node",
            address: "127.0.0.1",
            port: 8388,
            cipher: .chacha20IetfPoly1305,
            password: "password"
        )

        context.insert(firstRule)
        context.insert(secondRule)
        context.insert(magentNode)
        try context.save()

        return ([firstRule, secondRule], magentNode)
    }
}
