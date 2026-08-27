//
//  AclServiceTests.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Unit tests for ACL subscription download and parsing.
//

import Foundation
import Magent
import SwiftData
import Testing
@testable import MagentX

/// `AclService` 下载和解析访问控制订阅的单元测试。
struct AclServiceTests {
    /// 验证下载流程可通过本地 Tiny GFWList fixture 解析出可用访问控制规则。
    @Test func aclServiceDownloadsLocalTinyListAndParsesRules() async throws {
        let fixtureURL = tinyListFixtureURL()

        let accessControlRules = try await AclService.shared.downloadAndParse(from: fixtureURL)

        #expect(accessControlRules.count == 359)
        #expect(accessControlRules.filter { $0.decision == "proxy" }.count == 310)
        #expect(accessControlRules.filter { $0.decision == "direct" }.count == 49)
        #expect(accessControlRules.filter { $0.matchType == .domainSuffix }.count == 326)
        #expect(accessControlRules.filter { $0.matchType == .urlRegex }.count == 19)
        #expect(accessControlRules.filter { $0.matchType == .domainKeyword }.count == 14)
        #expect(accessControlRules.allSatisfy { $0.source == AclService.source })

        let expectedRules: [(index: Int, matchType: Magent.MatchType, matchValue: String, decision: String)] = [
            (0, .urlRegex, #"^https:\/\/fbcdn.*\.akamaihd\.net\/"#, "proxy"),
            (13, .domainSuffix, "facebook.com", "proxy"),
            (71, .domainSuffix, "google.com", "proxy"),
            (112, .domainSuffix, "redirector.gvt1.com", "direct"),
            (177, .domainSuffix, "telegram.org", "proxy"),
            (221, .domainSuffix, "share.dmhy.org", "proxy"),
            (275, .domainSuffix, "shadowsocks.org", "proxy"),
            (313, .domainSuffix, "aliyun.com", "direct"),
            (327, .domainSuffix, "fonts.googleapis.com", "direct"),
            (358, .urlRegex, #"^http:\/\/ime\.baidu\.jp"#, "direct")
        ]

        #expect(accessControlRules.allSatisfy { $0.order == 100 })

        for expectedRule in expectedRules {
            let accessControlRule = accessControlRules[expectedRule.index]
            #expect(accessControlRule.matchType == expectedRule.matchType)
            #expect(accessControlRule.matchValue == expectedRule.matchValue)
            #expect(accessControlRule.decision == expectedRule.decision)
            #expect(accessControlRule.source == AclService.source)
            #expect(accessControlRule.id == AccessControlRule.makeID(
                matchType: expectedRule.matchType,
                matchValue: expectedRule.matchValue
            ))
        }
    }

    /// 验证本地 Base64 订阅文件会经由公开下载入口覆盖主要规则解析分支。
    @Test func downloadAndParseLocalFileParsesRuleBranchesAsAccessControlRules() async throws {
        let fileURL = try makeEncodedListFile("""
        ! comment
        [AutoProxy 0.2.9]
        # comment
        ||google.com^
        @@||apple.com^
        .example.org
        10.0.0.0/8
        telegram
        /https?:\\/\\/.*\\.example\\.com/
        foo*bar
        plain.example.io
        ||duplicate.com^
        @@||duplicate.com^
        ||option.example.com^$script
        @@plain-direct.example.net
        """)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let accessControlRules = try await AclService.shared.downloadAndParse(from: fileURL)

        #expect(accessControlRules.count == 11)
        #expect(accessControlRules.map(\.matchValue) == [
            "google.com",
            "apple.com",
            "example.org",
            "10.0.0.0/8",
            "telegram",
            #"https?:\/\/.*\.example\.com"#,
            "foo.*bar",
            "plain.example.io",
            "duplicate.com",
            "option.example.com",
            "plain-direct.example.net"
        ])
        #expect(accessControlRules.map(\.matchType) == [
            .domainSuffix,
            .domainSuffix,
            .domainSuffix,
            .ipCIDR,
            .domainKeyword,
            .urlRegex,
            .urlRegex,
            .domainSuffix,
            .domainSuffix,
            .domainSuffix,
            .domainSuffix
        ])
        #expect(accessControlRules.map(\.decision) == [
            "proxy",
            "direct",
            "proxy",
            "proxy",
            "proxy",
            "proxy",
            "proxy",
            "proxy",
            "direct",
            "proxy",
            "direct"
        ])
        #expect(accessControlRules.allSatisfy { $0.source == AclService.source })
        #expect(accessControlRules.allSatisfy { $0.order == 100 })
    }

    /// 验证 PSL 下载会写入 AclService 配置目录下固定的 `PSL.dat` 文件。
    @Test func downloadPSLStoresFileInConfiguredDirectory() async throws {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let sourceURL = try makeTextFile(
            """
            // PSL test data
            com
            co.uk
            """,
            name: "source-PSL.dat",
            in: directoryURL
        )
        let storageDirectoryURL = directoryURL.appendingPathComponent("MagentX", isDirectory: true)
        let aclService = AclService(storageDirectoryURL: storageDirectoryURL)

        let storedURL = try await aclService.downloadPSL(from: sourceURL)

        #expect(storedURL == storageDirectoryURL.appendingPathComponent(AclService.publicSuffixListFileName))
        #expect(try String(contentsOf: storedURL, encoding: .utf8).contains("co.uk"))
    }

    /// 验证 AccessControlRule 会通过 PSL 找到 suffix domain，并补齐所有命中策略组的关联记录。
    @Test func parseAccessControlRuleCreatesPolicyRulesForMatchingPSLSuffixPolicies() throws {
        let directoryURL = temporaryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let pslFileURL = try makeTextFile(
            """
            // PSL test data
            com
            co.uk
            *.ck
            !www.ck
            """,
            name: AclService.publicSuffixListFileName,
            in: directoryURL
        )
        let container = try makeContainer()
        let context = ModelContext(container)
        let rule = AccessControlRule(
            matchType: .domainSuffix,
            matchValue: "api.news.bbc.co.uk",
            decision: "proxy"
        )
        let firstNode = makeNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            port: 8388
        )
        let secondNode = makeNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            port: 8389
        )
        let unrelatedNode = makeNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
            port: 8390
        )
        let firstPolicy = ProxyPolicy(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            name: "bbc.co.uk",
            magentNodeID: firstNode.id,
            magentNode: firstNode
        )
        let secondPolicy = ProxyPolicy(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            name: "  BBC.CO.UK  ",
            magentNodeID: secondNode.id,
            magentNode: secondNode
        )
        let unrelatedPolicy = ProxyPolicy(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!,
            name: "google.com",
            magentNodeID: unrelatedNode.id,
            magentNode: unrelatedNode
        )

        context.insert(rule)
        context.insert(firstNode)
        context.insert(secondNode)
        context.insert(unrelatedNode)
        context.insert(firstPolicy)
        context.insert(secondPolicy)
        context.insert(unrelatedPolicy)
        try context.save()

        let policyRules = try AclService.parseAccessControlRule(
            rule,
            in: context,
            publicSuffixListFileURL: pslFileURL
        )
        let repeatedPolicyRules = try AclService.parseAccessControlRule(
            rule,
            in: context,
            publicSuffixListFileURL: pslFileURL
        )
        let storedPolicyRules = try context.fetch(FetchDescriptor<ProxyPolicyRule>())

        #expect(Set(policyRules.map(\.id)) == [firstPolicy.id, secondPolicy.id])
        #expect(Set(policyRules.map(\.ruleID)) == [rule.id])
        #expect(Set(repeatedPolicyRules.map(\.id)) == [firstPolicy.id, secondPolicy.id])
        #expect(storedPolicyRules.count == 2)
        #expect(storedPolicyRules.allSatisfy { $0.ruleID == rule.id })
    }

    private func makeEncodedListFile(_ text: String) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-test-\(UUID().uuidString).txt")
        try Data(text.utf8).base64EncodedData().write(to: fileURL)
        return fileURL
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: AccessControlRule.self,
            ProxyPolicy.self,
            ProxyPolicyRule.self,
            MagentNode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeNode(id: UUID, port: Int) -> MagentNode {
        MagentNode(
            id: id,
            name: "Node \(port)",
            address: "127.0.0.1",
            port: port,
            password: "password"
        )
    }

    private func makeTextFile(_ text: String, name: String, in directoryURL: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent(name, isDirectory: false)
        try Data(text.utf8).write(to: fileURL)
        return fileURL
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AclServiceTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func tinyListFixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("tinylist.txt", isDirectory: false)
    }
}
