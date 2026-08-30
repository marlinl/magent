//
//  RuleControllerTests.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Unit tests for access-control rule import handling.
//

import Foundation
import Magent
import SwiftData
import Testing
@testable import MagentX

/// `RuleController` 访问控制规则导入流程的单元测试。
@MainActor
struct RuleControllerTests {
    /// 验证解析后的访问控制规则会被导入到 SwiftData。
    @Test func importRuleListInsertsAccessControlRules() throws {
        let container = try ModelContainer(
            for: MagentProxyNode.self,
            AccessControlRule.self,
            ProxyPolicy.self,
            ProxyPolicyRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let controller = RuleController()

        let parsedAccessControlRules = [
            AccessControlRuleImport(matchType: .domainSuffix, matchValue: "google.com", decision: "proxy", order: 2, source: AclService.source),
            AccessControlRuleImport(matchType: .domainSuffix, matchValue: "apple.com", decision: "direct", order: 3, source: AclService.source),
            AccessControlRuleImport(matchType: .ipCIDR, matchValue: "10.0.0.0/8", decision: "proxy", order: 4, source: AclService.source),
            AccessControlRuleImport(matchType: .domainKeyword, matchValue: "telegram", decision: "proxy", order: 5, source: AclService.source),
            AccessControlRuleImport(matchType: .urlRegex, matchValue: #"https?:\/\/.*\.example\.com"#, decision: "proxy", order: 6, source: AclService.source)
        ]

        let summary = try controller.importRuleList(parsedAccessControlRules, into: context, settings: nil)
        let accessControlRules = try context.fetch(FetchDescriptor<AccessControlRule>(
            sortBy: [SortDescriptor(\.order)]
        ))

        #expect(summary.parsedRuleCount == 5)
        #expect(summary.insertedRuleCount == 5)
        #expect(accessControlRules.map(\.matchValue) == [
            "google.com",
            "apple.com",
            "10.0.0.0/8",
            "telegram",
            #"https?:\/\/.*\.example\.com"#
        ])
        #expect(accessControlRules.map(\.matchType) == [
            .domainSuffix,
            .domainSuffix,
            .ipCIDR,
            .domainKeyword,
            .urlRegex
        ])
        #expect(accessControlRules[1].decision == "direct")
        #expect(accessControlRules.allSatisfy { $0.source == AclService.source })
    }

    /// 验证 GFWList 规则会刷新，手工规则冲突会被跳过。
    @Test func importRuleListRefreshesGfwlistRulesAndSkipsManualConflicts() throws {
        let container = try ModelContainer(
            for: MagentProxyNode.self,
            AccessControlRule.self,
            ProxyPolicy.self,
            ProxyPolicyRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let oldDate = Date(timeIntervalSince1970: 100)
        let gfwlistAccessControlRule = AccessControlRule(
            matchType: .domainSuffix,
            matchValue: "google.com",
            decision: "proxy",
            source: AclService.source,
            createdAt: oldDate,
            updatedAt: oldDate
        )
        let manualAccessControlRule = AccessControlRule(
            matchType: .domainSuffix,
            matchValue: "example.com",
            decision: "direct",
            source: "manual",
            createdAt: oldDate,
            updatedAt: oldDate
        )

        context.insert(gfwlistAccessControlRule)
        context.insert(manualAccessControlRule)

        let parsedAccessControlRules = [
            AccessControlRuleImport(matchType: .domainSuffix, matchValue: "google.com", decision: "proxy", order: 100, source: AclService.source),
            AccessControlRuleImport(matchType: .domainSuffix, matchValue: "example.com", decision: "proxy", order: 100, source: AclService.source),
            AccessControlRuleImport(matchType: .domainSuffix, matchValue: "apple.com", decision: "direct", order: 100, source: AclService.source)
        ]
        let controller = RuleController()

        let summary = try controller.importRuleList(parsedAccessControlRules, into: context, settings: nil)
        let accessControlRules = try context.fetch(FetchDescriptor<AccessControlRule>(
            sortBy: [SortDescriptor(\.matchValue)]
        ))
        let appleAccessControlRule = accessControlRules.first { $0.matchValue == "apple.com" }

        #expect(summary.parsedRuleCount == 3)
        #expect(summary.insertedRuleCount == 1)
        #expect(summary.refreshedRuleCount == 1)
        #expect(summary.skippedRuleCount == 1)
        #expect(gfwlistAccessControlRule.updatedAt > oldDate)
        #expect(manualAccessControlRule.updatedAt == oldDate)
        #expect(appleAccessControlRule?.decision == "direct")
        #expect(appleAccessControlRule?.source == AclService.source)
    }

    /// 验证修改访问规则后会重写 proxy host PAC 文件。
    @Test func updateDecisionRewritesProxyHostPACFile() throws {
        let container = try ModelContainer(
            for: MagentProxyNode.self,
            AccessControlRule.self,
            ProxyPolicy.self,
            ProxyPolicyRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let controller = RuleController(
            pacFileService: PacFileService(directoryURL: directoryURL),
            generalSettingsProvider: {
                GeneralSettings(proxyListenAddress: "127.0.0.1", proxyListenPort: 1086)
            }
        )
        let accessControlRule = AccessControlRule(
            matchType: .domainSuffix,
            matchValue: "google.com",
            decision: "direct",
            order: 100
        )
        context.insert(accessControlRule)
        try context.save()

        controller.updateDecision("proxy", for: accessControlRule, in: context)

        let fileURL = PacFileService.proxyHostPACURL(in: directoryURL)
        let pac = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(pac.contains(#"var proxy = "SOCKS5 127.0.0.1:1086; DIRECT";"#))
        #expect(pac.contains(#"{ type: "domainSuffix", value: "google.com", decision: "proxy" }"#))
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RuleControllerTests-\(UUID().uuidString)", isDirectory: true)
    }
}
