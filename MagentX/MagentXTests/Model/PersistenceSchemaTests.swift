//
//  PersistenceSchemaTests.swift
//  MagentXTests
//
//  Responsibility: Verifies all documented schema entities can be persisted together.
//

import Foundation
import Magent
import SwiftData
import Testing
@testable import MagentX

/// 验证 SwiftData 持久化实体与 `docs/database/schema.sql` 的表和业务键约束一致。
@MainActor
struct PersistenceSchemaTests {
    /// 验证应用容器注册节点、规则、策略和策略规则关联四种持久化实体。
    @Test func persistsAllSchemaEntities() throws {
        let container = try MagentXApp.makeModelContainer(isStoredInMemoryOnly: true)
        let modelContext = ModelContext(container)
        let node = MagentProxyNode(
            address: "127.0.0.1",
            port: 8388,
            cipher: .chacha20IetfPoly1305,
            password: "password"
        )
        let rule = MagentProxyRule(
            id: 1,
            matchType: .domainSuffix,
            matchValue: "example.com",
            decision: .proxy,
            order: 100,
            source: "user"
        )
        let policy = MagentProxyPolicy(id: 1, name: "Default", nodeID: node.id)
        let policyRule = MagentProxyPolicyRule(policyID: policy.id, ruleID: rule.id)

        modelContext.insert(node)
        modelContext.insert(rule)
        modelContext.insert(policy)
        modelContext.insert(policyRule)
        try modelContext.save()

        #expect(try modelContext.fetchCount(FetchDescriptor<MagentProxyNode>()) == 1)
        #expect(try modelContext.fetchCount(FetchDescriptor<MagentProxyRule>()) == 1)
        #expect(try modelContext.fetchCount(FetchDescriptor<MagentProxyPolicy>()) == 1)
        #expect(try modelContext.fetchCount(FetchDescriptor<MagentProxyPolicyRule>()) == 1)
    }
}
