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

/// `MagentProxyRuleService` CRUD、分页、下载、解析和数据库合并行为的单元测试。
@MainActor
@Suite(.serialized)
struct MagentProxyRuleServiceTests {
    /// 验证相同匹配身份的再次新增会更新动作，且批次内重复规则仅保留首条。
    @Test func batchInsertUpsertsAndFiltersRulesWithSameMatchIdentity() async throws {
        let container = try makeContainer()
        let service = MagentProxyRuleService(modelContainer: container)
        try await service.batchInsert([MagentProxyRuleInput(
            id: 1, matchType: .domainSuffix, matchValue: "example.com",
            decision: .proxy, order: 0, source: "user"
        )])
        let insertedResult = try await service.search(keyword: "", pageAt: 1, pageSize: 10)
        let insertedRules = rules(for: insertedResult, container: container)
        #expect(insertedRules.count == 1)
        #expect(insertedRules.first?.decision == .proxy)

        try await service.batchInsert([
            MagentProxyRuleInput(
                id: 2, matchType: .domainSuffix, matchValue: "example.com",
                decision: .direct, order: 0, source: "user"
            ),
            MagentProxyRuleInput(
                id: 3, matchType: .domainSuffix, matchValue: "example.com",
                decision: .proxy, order: 0, source: "user"
            )
        ])
        let result = try await service.search(keyword: "", pageAt: 1, pageSize: 10)
        let resultRules = rules(for: result, container: container)
        #expect(resultRules.count == 1)
        #expect(resultRules.first?.decision == .direct)
    }

    /// 验证新增、查询、更新和按业务 id 批量删除都由规则服务完成。
    @Test func batchInsertInsertAndBatchDeleteRules() async throws {
        let container = try makeContainer()
        let service = MagentProxyRuleService(modelContainer: container)
        try await service.batchInsert([
            MagentProxyRuleInput(id: 0, matchType: .domainSuffix, matchValue: "example.com", decision: .proxy, order: 0, source: "user"),
            MagentProxyRuleInput(id: 1, matchType: .domainKeyword, matchValue: "telegram", decision: .direct, order: 0, source: "user"),
            MagentProxyRuleInput(id: 2, matchType: .domainSuffix, matchValue: "apple.com", decision: .proxy, order: 0, source: "user")
        ])

        var searchResult = try await service.search(keyword: "", pageAt: 1, pageSize: 10)
        var searchRules = rules(for: searchResult, container: container)
        #expect(searchRules.count == 3)
        #expect(searchRules.map(\.id) == [2, 0, 1])
        #expect(searchResult.canLoadMore == false)

        try await service.insert(MagentProxyRuleInput(
            id: 0,
            matchType: .urlRegex,
            matchValue: "example.com",
            decision: .direct,
            order: 0,
            source: "user"
        ))

        searchResult = try await service.search(keyword: "example", pageAt: 1, pageSize: 10)
        searchRules = rules(for: searchResult, container: container)
        let updatedRule = try #require(searchRules.first)
        #expect(updatedRule.matchType == .urlRegex)
        #expect(updatedRule.matchValue == "example.com")
        #expect(updatedRule.decision == .direct)
        #expect(updatedRule.order == 0)
        #expect(updatedRule.source == "user")
        #expect(updatedRule.updatedAt >= updatedRule.createdAt)

        try await service.delete([0, 2])

        searchResult = try await service.search(keyword: "", pageAt: 1, pageSize: 10)
        searchRules = rules(for: searchResult, container: container)
        #expect(searchRules.map(\.id) == [1])
    }

    /// 验证查询使用从 `1` 开始的页码，并通过额外读取一条正确标记下一页。
    @Test func searchUsesOneBasedPagination() async throws {
        let container = try makeContainer()
        let service = MagentProxyRuleService(modelContainer: container)
        try await service.batchInsert([
            MagentProxyRuleInput(id: 0, matchType: .domainSuffix, matchValue: "b.example", decision: .proxy, order: 0, source: "user"),
            MagentProxyRuleInput(id: 1, matchType: .domainSuffix, matchValue: "a.example", decision: .proxy, order: 0, source: "user"),
            MagentProxyRuleInput(id: 2, matchType: .domainSuffix, matchValue: "c.example", decision: .proxy, order: 0, source: "user")
        ])

        let firstPage = try await service.search(keyword: "example", pageAt: 1, pageSize: 2)
        let firstPageRules = rules(for: firstPage, container: container)
        #expect(firstPageRules.map(\.matchValue) == ["a.example", "b.example"])
        #expect(firstPage.pageAt == 1)
        #expect(firstPage.pageSize == 2)
        #expect(firstPage.canLoadMore)

        let secondPage = try await service.search(keyword: "example", pageAt: 2, pageSize: 2)
        let secondPageRules = rules(for: secondPage, container: container)
        #expect(secondPageRules.map(\.matchValue) == ["c.example"])
        #expect(secondPage.pageAt == 2)
        #expect(secondPage.pageSize == 2)
        #expect(secondPage.canLoadMore == false)
    }

    /// 验证空业务 id 数组不会删除现有规则。
    @Test func deleteWithEmptyIDsDoesNothing() async throws {
        let container = try makeContainer()
        let service = MagentProxyRuleService(modelContainer: container)
        try await service.insert(MagentProxyRuleInput(
            id: 99,
            matchType: .domainSuffix,
            matchValue: "example.com",
            decision: .proxy,
            order: 0,
            source: "user"
        ))

        try await service.delete([])

        let result = try await service.search(keyword: "", pageAt: 1, pageSize: 10)
        #expect(rules(for: result, container: container).map(\.id) == [99])
    }

    /// 验证同步会覆盖同来源规则、保留冲突的用户规则，并给新增规则分配未占用 id。
    @Test func syncRuleFromURLMergesDownloadedRules() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let pacFileURL = MagentXApp.localDirectoryURL
            .appendingPathComponent("pac.json", isDirectory: false)
        let originalPACData = try? Data(contentsOf: pacFileURL)
        defer {
            if let originalPACData {
                try? originalPACData.write(to: pacFileURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: pacFileURL)
            }
        }
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
        try await service.sync()

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

        let pac = try String(contentsOf: pacFileURL, encoding: .utf8)
        #expect(pacFileURL.lastPathComponent == "pac.json")
        #expect(pac.contains("function FindProxyForURL(url, host)"))
        #expect(pac.contains(#"{ type: "domainSuffix", value: "google.com", decision: "direct" }"#))
        #expect(pac.contains(#"{ type: "ipCIDR", value: "10.0.0.0", mask: "255.0.0.0", decision: "proxy" }"#))
    }

    /// 验证无效 Base64 会传播原始应用错误，且不会写入规则。
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
        await #expect(throws: MagentXError.invalidAclBase64Data) {
            try await service.sync()
        }
        let resultContext = ModelContext(container)
        #expect(try resultContext.fetchCount(FetchDescriptor<MagentProxyRule>()) == 0)
    }

    /// 创建仅包含代理规则存储记录的内存 SwiftData 容器。
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: MagentProxyRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// 在测试主 actor 的模型上下文中按查询结果的持久化标识重新读取规则。
    ///
    /// - Parameters:
    ///   - result: 规则服务返回的分页结果。
    ///   - container: 承载被测规则的内存模型容器。
    /// - Returns: 与分页结果顺序相同且可供断言的持久化规则。
    private func rules(
        for result: ProxyRulesPagingResult,
        container: ModelContainer
    ) -> [MagentProxyRule] {
        let modelContext = ModelContext(container)
        return result.persistentIdentifiers.compactMap { persistentIdentifier in
            modelContext.model(for: persistentIdentifier) as? MagentProxyRule
        }
    }

    /// 创建包含 Base64 GFWList 文本的唯一临时文件。
    private func makeEncodedListFile(_ text: String) throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-rules-\(UUID().uuidString).txt", isDirectory: false)
        try Data(text.utf8).base64EncodedData().write(to: fileURL)
        return fileURL
    }
}
