//
//  AccessControlRuleTests.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Unit tests for access-control rule model identity.
//

import Foundation
import Magent
import Testing
@testable import MagentX

/// `AccessControlRule` 模型身份生成规则的单元测试。
struct AccessControlRuleTests {
    /// 验证访问控制规则 id 由 `matchType + matchValue` 稳定派生，而不是随机 UUID。
    @Test func accessControlRuleIDIsStableForSameMatchIdentity() {
        let firstRule = AccessControlRule(
            matchType: .domainSuffix,
            matchValue: "google.com",
            decision: "proxy"
        )
        let secondRule = AccessControlRule(
            matchType: .domainSuffix,
            matchValue: "google.com",
            decision: "direct",
            order: 10,
            source: "manual"
        )
        let differentTypeRule = AccessControlRule(
            matchType: .domainKeyword,
            matchValue: "google.com",
            decision: "proxy"
        )
        let differentValueRule = AccessControlRule(
            matchType: .domainSuffix,
            matchValue: "apple.com",
            decision: "proxy"
        )

        #expect(firstRule.id == UUID(uuidString: "70411c75-ee59-5eff-a2c0-1b7c36742e27")!)
        #expect(firstRule.id == secondRule.id)
        #expect(differentTypeRule.id == UUID(uuidString: "e303dd53-ac27-5db0-a577-6f4c827ffa94")!)
        #expect(differentValueRule.id == UUID(uuidString: "98070875-11c8-5828-a2a0-da801f4bf503")!)
        #expect(firstRule.id != differentTypeRule.id)
        #expect(firstRule.id != differentValueRule.id)
    }
}
