//
//  AclServiceMagentProxyRuleTests.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Unit tests for MagentProxyRule subscription imports.
//

import Foundation
import Magent
import SwiftData
import Testing
@testable import MagentX

/// `AclService` 导入 `MagentProxyRule` 的单元测试。
@MainActor
struct AclServiceMagentProxyRuleTests {
    /// 验证解析后的订阅规则会写入 `MagentProxyRule` 并生成 PAC 快照。
    @Test func importRulesInsertsMagentProxyRules() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let importedRules = [
            AccessControlRuleImport(matchType: .domainSuffix, matchValue: "google.com", decision: "proxy", order: 2, source: AclService.source),
            AccessControlRuleImport(matchType: .domainSuffix, matchValue: "apple.com", decision: "direct", order: 3, source: AclService.source),
            AccessControlRuleImport(matchType: .ipCIDR, matchValue: "10.0.0.0/8", decision: "proxy", order: 4, source: AclService.source),
            AccessControlRuleImport(matchType: .domainKeyword, matchValue: "telegram", decision: "proxy", order: 5, source: AclService.source),
            AccessControlRuleImport(matchType: .urlRegex, matchValue: #"https?:\/\/.*\.example\.com"#, decision: "proxy", order: 6, source: AclService.source)
        ]

        let pacRules = try AclService.importMagentProxyRules(importedRules, into: context, now: .now)
        let proxyRules = try context.fetch(FetchDescriptor<MagentProxyRule>(
            sortBy: [SortDescriptor(\.order)]
        ))

        #expect(proxyRules.map(\.matchValue) == [
            "google.com",
            "apple.com",
            "10.0.0.0/8",
            "telegram",
            #"https?:\/\/.*\.example\.com"#
        ])
        #expect(proxyRules.map(\.decision) == [.proxy, .direct, .proxy, .proxy, .proxy])
        #expect(proxyRules.allSatisfy { $0.source == AclService.source })
        #expect(pacRules.count == importedRules.count)
    }

    /// 验证同来源订阅规则会刷新，而与手工规则冲突的订阅项会被跳过。
    @Test func importRulesRefreshesSubscriptionRulesAndSkipsManualConflicts() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let oldDate = Date(timeIntervalSince1970: 100)
        let subscriptionRule = MagentProxyRule(
            id: 0,
            matchType: .domainSuffix,
            matchValue: "google.com",
            decision: .proxy,
            order: 0,
            source: AclService.source,
            createdAt: oldDate,
            updatedAt: oldDate
        )
        let manualRule = MagentProxyRule(
            id: 1,
            matchType: .domainSuffix,
            matchValue: "example.com",
            decision: .direct,
            order: 0,
            source: "user",
            createdAt: oldDate,
            updatedAt: oldDate
        )
        context.insert(subscriptionRule)
        context.insert(manualRule)

        let importedRules = [
            AccessControlRuleImport(matchType: .domainSuffix, matchValue: "google.com", decision: "direct", order: 100, source: AclService.source),
            AccessControlRuleImport(matchType: .domainSuffix, matchValue: "example.com", decision: "proxy", order: 100, source: AclService.source),
            AccessControlRuleImport(matchType: .domainSuffix, matchValue: "apple.com", decision: "proxy", order: 100, source: AclService.source)
        ]

        _ = try AclService.importMagentProxyRules(importedRules, into: context, now: .now)
        let proxyRules = try context.fetch(FetchDescriptor<MagentProxyRule>())
        let appleRule = proxyRules.first { $0.matchValue == "apple.com" }

        #expect(proxyRules.count == 3)
        #expect(subscriptionRule.decision == .direct)
        #expect(subscriptionRule.order == 100)
        #expect(subscriptionRule.updatedAt > oldDate)
        #expect(manualRule.decision == .direct)
        #expect(manualRule.source == "user")
        #expect(manualRule.updatedAt == oldDate)
        #expect(appleRule?.decision == .proxy)
        #expect(appleRule?.source == AclService.source)
    }

    /// 验证导入返回的快照可以保持原有规则内容生成 PAC 文件。
    @Test func importedRulesGenerateProxyHostPACFile() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let importedRules = [
            AccessControlRuleImport(
                matchType: .domainSuffix,
                matchValue: "google.com",
                decision: "proxy",
                order: 100,
                source: AclService.source
            )
        ]
        let pacRules = try AclService.importMagentProxyRules(importedRules, into: context, now: .now)
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = try PacFileService.writeProxyHostPAC(
            rules: pacRules,
            proxyEndpoint: try PacFileService.ProxyEndpoint(address: "127.0.0.1", port: 1086),
            directoryURL: directoryURL
        )
        let pac = try String(contentsOf: fileURL, encoding: .utf8)

        #expect(pac.contains(#"var proxy = "SOCKS5 127.0.0.1:1086; DIRECT";"#))
        #expect(pac.contains(#"{ type: "domainSuffix", value: "google.com", decision: "proxy" }"#))
    }

    /// 创建仅包含代理规则模型的内存 SwiftData 容器。
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: MagentProxyRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// 创建供 PAC 文件测试使用的唯一临时目录地址。
    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AclServiceMagentProxyRuleTests-\(UUID().uuidString)", isDirectory: true)
    }
}
