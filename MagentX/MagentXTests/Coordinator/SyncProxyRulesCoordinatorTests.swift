//
//  SyncProxyRulesCoordinatorTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Unit tests for background GFWList synchronization into MagentProxyRule.
//

import Foundation
import Magent
import SwiftData
import Testing
@testable import MagentX

/// `SyncProxyRulesCoordinator` 下载、解析、数据库合并和可观察状态的单元测试。
@MainActor
@Suite(.serialized)
struct SyncProxyRulesCoordinatorTests {
    /// 验证同步会批量 upsert 规则、复用已有 id，并给新增规则分配未占用 id。
    @Test func syncRuleFromURLMergesDownloadedRules() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let oldDate = Date(timeIntervalSince1970: 100)
        context.insert(MagentProxyRule(
            id: 0,
            matchType: MatchType.domainSuffix.rawValue,
            matchValue: "google.com",
            decision: "proxy",
            order: 0,
            source: "rulesUrl",
            createdAt: oldDate,
            updatedAt: oldDate
        ))
        context.insert(MagentProxyRule(
            id: 1,
            matchType: MatchType.domainSuffix.rawValue,
            matchValue: "example.com",
            decision: "direct",
            order: 0,
            source: "user",
            createdAt: oldDate,
            updatedAt: oldDate
        ))
        try context.save()

        let fileURL = try makeEncodedListFile(
            """
            ! comment
            ||google.com
            @@||google.com
            ||example.com
            ||apple.com
            10.0.0.0/8
            telegram
            /https?:\\/\\/.*\\.sample\\.com/
            """
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let defaults = UserDefaults.standard
        let rulesURLKey = "general.rulesURL"
        let originalRulesURL = defaults.object(forKey: rulesURLKey)
        defaults.set(fileURL.absoluteString, forKey: rulesURLKey)
        defer {
            if let originalRulesURL {
                defaults.set(originalRulesURL, forKey: rulesURLKey)
            } else {
                defaults.removeObject(forKey: rulesURLKey)
            }
        }

        let coordinator = SyncProxyRulesCoordinator(modelContainer: container)
        #expect(coordinator.state == .idle)
        coordinator.sync()
        #expect(coordinator.state == .running)
        await waitForSyncCompletion(coordinator)
        #expect(coordinator.state == .idle)
        #expect(coordinator.syncError == nil)

        coordinator.sync()
        #expect(coordinator.state == .running)
        await waitForSyncCompletion(coordinator)
        #expect(coordinator.state == .idle)
        #expect(coordinator.syncError == nil)

        let resultContext = ModelContext(container)
        let storedRules = try resultContext.fetch(FetchDescriptor<MagentProxyRule>())
        let rulesByValue = Dictionary(uniqueKeysWithValues: storedRules.map { ($0.matchValue, $0) })

        #expect(storedRules.count == 6)
        #expect(rulesByValue["google.com"]?.decision == "direct")
        #expect(rulesByValue["google.com"]?.order == 100)
        #expect(rulesByValue["google.com"]?.source == "rulesUrl")
        #expect(rulesByValue["example.com"]?.decision == "proxy")
        #expect(rulesByValue["example.com"]?.source == "rulesUrl")
        #expect(rulesByValue["example.com"]?.id == 1)
        #expect(rulesByValue["example.com"]?.createdAt == oldDate)
        #expect(rulesByValue["example.com"]?.updatedAt != oldDate)
        #expect(rulesByValue["apple.com"]?.id == 2)
        #expect(rulesByValue["10.0.0.0/8"]?.matchType == MatchType.ipCIDR.rawValue)
        #expect(rulesByValue["telegram"]?.matchType == MatchType.domainKeyword.rawValue)
        #expect(rulesByValue[#"https?:\/\/.*\.sample\.com"#]?.matchType == MatchType.urlRegex.rawValue)
    }

    /// 验证无效 Base64 会写入可观察错误状态，且不会写入规则。
    @Test func syncRuleFromURLPropagatesInvalidBase64Error() async throws {
        let container = try makeContainer()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid-rules-\(UUID().uuidString).txt", isDirectory: false)
        try Data("A".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let defaults = UserDefaults.standard
        let rulesURLKey = "general.rulesURL"
        let originalRulesURL = defaults.object(forKey: rulesURLKey)
        defaults.set(fileURL.absoluteString, forKey: rulesURLKey)
        defer {
            if let originalRulesURL {
                defaults.set(originalRulesURL, forKey: rulesURLKey)
            } else {
                defaults.removeObject(forKey: rulesURLKey)
            }
        }

        let coordinator = SyncProxyRulesCoordinator(modelContainer: container)
        coordinator.sync()
        #expect(coordinator.state == .running)
        await waitForSyncCompletion(coordinator)

        #expect(coordinator.state == .idle)
        #expect(coordinator.syncError == MagentXError.invalidAclBase64Data.localizedDescription)
        let resultContext = ModelContext(container)
        #expect(try resultContext.fetchCount(FetchDescriptor<MagentProxyRule>()) == 0)
    }

    /// 等待协调器结束当前同步任务，并在合理时间内未完成时记录测试失败。
    private func waitForSyncCompletion(_ coordinator: SyncProxyRulesCoordinator) async {
        for _ in 0..<500 {
            if coordinator.state == .idle {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Proxy rule synchronization did not finish in time")
    }

    /// 创建仅包含代理规则存储记录的内存 SwiftData 容器。
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: MagentProxyRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// 创建包含 Base64 GFWList 文本的唯一临时文件。
    private func makeEncodedListFile(_ text: String) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-rules-\(UUID().uuidString).txt", isDirectory: false)
        try Data(text.utf8).base64EncodedData().write(to: fileURL)
        return fileURL
    }
}
