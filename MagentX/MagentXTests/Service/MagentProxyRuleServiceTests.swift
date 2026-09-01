//
//  MagentProxyRuleServiceTests.swift
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

/// `MagentProxyRuleService` 下载、解析和数据库合并行为的单元测试。
@MainActor
@Suite(.serialized)
struct MagentProxyRuleServiceTests {
    /// 验证同步会覆盖同来源规则、保留冲突的用户规则，并给新增规则分配未占用 id。
    @Test func syncRuleFromURLMergesDownloadedRules() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let oldDate = Date(timeIntervalSince1970: 100)
        context.insert(MagentProxyRule(
            id: 0,
            matchType: .domainSuffix,
            matchValue: "google.com",
            decision: .proxy,
            order: 0,
            source: "rulesUrl",
            createdAt: oldDate,
            updatedAt: oldDate
        ))
        context.insert(MagentProxyRule(
            id: 1,
            matchType: .domainSuffix,
            matchValue: "example.com",
            decision: .direct,
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

        let service = MagentProxyRuleService(modelContainer: container)
        let future = await service.syncRuleFromUrl()
        let pacRules = try await future.value

        let resultContext = ModelContext(container)
        let storedRules = try resultContext.fetch(FetchDescriptor<MagentProxyRule>())
        let rulesByValue = Dictionary(uniqueKeysWithValues: storedRules.map { ($0.matchValue, $0) })

        #expect(storedRules.count == 6)
        #expect(rulesByValue["google.com"]?.decision == .direct)
        #expect(rulesByValue["google.com"]?.order == 100)
        #expect(rulesByValue["google.com"]?.source == "rulesUrl")
        #expect(rulesByValue["example.com"]?.decision == .direct)
        #expect(rulesByValue["example.com"]?.source == "user")
        #expect(rulesByValue["example.com"]?.updatedAt == oldDate)
        #expect(rulesByValue["apple.com"]?.id == 2)
        #expect(rulesByValue["10.0.0.0/8"]?.matchType == .ipCIDR)
        #expect(rulesByValue["telegram"]?.matchType == .domainKeyword)
        #expect(rulesByValue[#"https?:\/\/.*\.sample\.com"#]?.matchType == .urlRegex)
        #expect(pacRules.count == storedRules.count)
    }

    /// 验证无效 Base64 会通过 Future 原样传播应用层错误，且不会写入规则。
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

        let service = MagentProxyRuleService(modelContainer: container)
        let future = await service.syncRuleFromUrl()

        await #expect(throws: MagentXError.invalidAclBase64Data) {
            try await future.value
        }
        let resultContext = ModelContext(container)
        #expect(try resultContext.fetchCount(FetchDescriptor<MagentProxyRule>()) == 0)
    }

    /// 创建仅包含代理规则模型的内存 SwiftData 容器。
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
