//
//  MagentProxyRuleService.swift
//  MagentX
//
//  Created by MarlinL on 2026/9/1.
//

import FactoryKit
import Foundation
import Magent
import SwiftData

/// 代理规则服务，负责在独立 SwiftData 执行器上完成 CRUD 与订阅同步。
@ModelActor
actor MagentProxyRuleService {
    @Injected(\.localExecutor) private var localExecutor

    /// 规则的业务匹配身份，用于在订阅同步时识别同一条数据库记录。
    private struct RuleIdentity: Hashable, Sendable {
        let matchType: MatchType
        let matchValue: String
    }

    private static let source = "rulesUrl"
    private static let importedRuleOrder = 100

    /// 按 `matchType` 和 `matchValue` 批量插入或更新代理规则。
    ///
    /// - Parameter rules: 需要持久化的不可变规则输入；同一批次内相同业务匹配身份仅保留首次出现的规则。
    /// - Throws: SwiftData 保存失败时抛出原始错误。
    func batchInsert(_ rules: [MagentProxyRuleInput]) throws {
        let storedRules = try modelContext.fetch(FetchDescriptor<MagentProxyRule>())
        var rulesByID = Dictionary(uniqueKeysWithValues: storedRules.map { ($0.id, $0) })
        var rulesByIdentity = Dictionary(uniqueKeysWithValues: storedRules.map { proxyRule in
            (
                RuleIdentity(matchType: proxyRule.matchType, matchValue: proxyRule.matchValue),
                proxyRule
            )
        })
        var seenIdentities = Set<RuleIdentity>()
        for rule in rules {
            let identity = RuleIdentity(matchType: rule.matchType, matchValue: rule.matchValue)
            guard seenIdentities.insert(identity).inserted else { continue }
            if let storedRule = rulesByID[rule.id] ?? rulesByIdentity[identity] {
                let originalIdentity = RuleIdentity(
                    matchType: storedRule.matchType,
                    matchValue: storedRule.matchValue
                )
                storedRule.matchType = rule.matchType
                storedRule.matchValue = rule.matchValue
                storedRule.decision = rule.decision
                storedRule.order = rule.order
                storedRule.source = rule.source
                storedRule.updatedAt = rule.updatedAt
                rulesByIdentity.removeValue(forKey: originalIdentity)
                rulesByIdentity[identity] = storedRule
                rulesByID[storedRule.id] = storedRule
                continue
            }

            let storedRule = MagentProxyRule(
                id: rule.id,
                matchType: rule.matchType,
                matchValue: rule.matchValue,
                decision: rule.decision,
                order: rule.order,
                source: rule.source,
                createdAt: rule.createdAt,
                updatedAt: rule.updatedAt
            )
            modelContext.insert(storedRule)
            rulesByID[storedRule.id] = storedRule
            rulesByIdentity[identity] = storedRule
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// 按提交规则的唯一业务 id 直接插入或更新代理规则。
    ///
    /// - Parameter rule: 包含非空整数业务 id 与待保存字段的不可变规则输入。
    /// - Throws: SwiftData 保存失败时抛出原始错误。
    func insert(_ rule: MagentProxyRuleInput) throws {
        let storedRules = try modelContext.fetch(FetchDescriptor<MagentProxyRule>())
        let identity = RuleIdentity(matchType: rule.matchType, matchValue: rule.matchValue)
        if let storedRule = storedRules.first(where: { $0.id == rule.id })
            ?? storedRules.first(where: {
                $0.matchType == identity.matchType && $0.matchValue == identity.matchValue
            }) {
            storedRule.matchType = rule.matchType
            storedRule.matchValue = rule.matchValue
            storedRule.decision = rule.decision
            storedRule.order = rule.order
            storedRule.source = rule.source
            storedRule.updatedAt = rule.updatedAt
        } else {
            modelContext.insert(MagentProxyRule(
                id: rule.id,
                matchType: rule.matchType,
                matchValue: rule.matchValue,
                decision: rule.decision,
                order: rule.order,
                source: rule.source,
                createdAt: rule.createdAt,
                updatedAt: rule.updatedAt
            ))
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// 按业务 id 批量删除已持久化代理规则。
    ///
    /// - Parameter ids: 待删除规则的唯一整数业务主键；空数组不执行删除。
    /// - Throws: SwiftData 批量删除失败时抛出原始错误。
    func delete(_ ids: [Int]) throws {
        guard ids.isEmpty == false else { return }
        try modelContext.delete(
            model: MagentProxyRule.self,
            where: #Predicate<MagentProxyRule> { proxyRule in
                ids.contains(proxyRule.id)
            }
        )
    }

    /// 按关键字和从 `1` 开始的页码读取规则持久化标识。
    ///
    /// - Parameters:
    ///   - keyword: 用于包含匹配 `matchValue` 的关键字；空白值表示全部规则。
    ///   - pageAt: 从 `1` 开始的页码。
    ///   - pageSize: 当页最多返回的规则数。
    /// - Returns: 按顺序和匹配值排序的分页规则持久化标识，以及是否存在下一页。
    /// - Throws: SwiftData 查询失败时抛出原始错误。
    func search(keyword: String, pageAt: Int = 1, pageSize: Int) throws -> ProxyRulesPagingResult {
        precondition(pageAt >= 1, "pageAt must start at 1")
        precondition(pageSize > 0, "pageSize must be greater than 0")

        let normalizedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let sortDescriptors: [SortDescriptor<MagentProxyRule>] = [
            SortDescriptor(\.order),
            SortDescriptor(\.matchValue)
        ]
        var descriptor: FetchDescriptor<MagentProxyRule>
        if normalizedKeyword.isEmpty {
            descriptor = FetchDescriptor<MagentProxyRule>(sortBy: sortDescriptors)
        } else {
            let query = normalizedKeyword
            descriptor = FetchDescriptor<MagentProxyRule>(
                predicate: #Predicate<MagentProxyRule> { proxyRule in
                    proxyRule.matchValue.contains(query)
                },
                sortBy: sortDescriptors
            )
        }
        descriptor.fetchOffset = (pageAt - 1) * pageSize
        descriptor.fetchLimit = pageSize + 1

        let fetchedRules = try modelContext.fetch(descriptor)
        let persistentIdentifiers = fetchedRules.prefix(pageSize).map(\.persistentModelID)
        return ProxyRulesPagingResult(
            persistentIdentifiers: persistentIdentifiers,
            pageAt: pageAt,
            pageSize: pageSize,
            canLoadMore: fetchedRules.count > persistentIdentifiers.count
        )
    }

    /// 同步当前规则订阅并重写本地 PAC 文件。
    ///
    /// - Throws: 下载、解析、持久化或 PAC 写入失败时抛出原始错误。
    func sync() async throws {
        let response = try await downloadFromRuleUrl()
        guard let decodedData = Data(base64Encoded: response, options: [.ignoreUnknownCharacters]) else {
            throw MagentXError.invalidAclBase64Data
        }
        guard let decodedText = String(data: decodedData, encoding: .utf8) else {
            throw MagentXError.invalidAclDecodedText
        }
        let downloadedRules = AdblockUtil.parse(decodedText)
        let existingRules = try modelContext.fetch(FetchDescriptor<MagentProxyRule>())
        var rulesByIdentity: [RuleIdentity: MagentProxyRule] = [:]
        for existingRule in existingRules {
            rulesByIdentity[RuleIdentity(
                matchType: existingRule.matchType,
                matchValue: existingRule.matchValue
            )] = existingRule
        }

        let now = Date.now
        var usedIDs = Set(existingRules.map(\.id))
        var nextIDCandidate = 0
        for downloadedRule in downloadedRules {
            let identity = RuleIdentity(
                matchType: downloadedRule.matchType,
                matchValue: downloadedRule.matchValue
            )
            let decision: RuleDecision = downloadedRule.isException ? .direct : .proxy

            if let existingRule = rulesByIdentity[identity] {
                guard existingRule.source == Self.source else { continue }
                existingRule.matchType = downloadedRule.matchType
                existingRule.matchValue = downloadedRule.matchValue
                existingRule.decision = decision
                existingRule.order = Self.importedRuleOrder
                existingRule.source = Self.source
                existingRule.updatedAt = now
                continue
            }

            while usedIDs.contains(nextIDCandidate) {
                nextIDCandidate += 1
            }
            let proxyRule = MagentProxyRule(
                id: nextIDCandidate,
                matchType: downloadedRule.matchType,
                matchValue: downloadedRule.matchValue,
                decision: decision,
                order: Self.importedRuleOrder,
                source: Self.source,
                createdAt: now,
                updatedAt: now
            )
            usedIDs.insert(nextIDCandidate)
            nextIDCandidate += 1
            modelContext.insert(proxyRule)
            rulesByIdentity[identity] = proxyRule
        }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        try await writePACFile()
    }

    /// 从当前规则订阅 URL 下载完整响应正文，不做 Base64 解码或内容裁剪。
    private func downloadFromRuleUrl() async throws -> String {
        let rulesURLValue = await MainActor.run {
            GeneralSettings.load().rulesURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard rulesURLValue.isEmpty == false else {
            throw MagentXError.missingRulesURL
        }
        guard let rulesURL = URL(string: rulesURLValue), rulesURL.scheme != nil else {
            throw MagentXError.invalidRulesURL(rulesURLValue)
        }

        let responseData: Data
        if rulesURL.isFileURL {
            responseData = try await localExecutor.runBlocking {
                try Data(contentsOf: rulesURL)
            }
        } else {
            let (data, response) = try await URLSession.shared.data(from: rulesURL)
            if let httpResponse = response as? HTTPURLResponse,
               (200..<300).contains(httpResponse.statusCode) == false {
                throw URLError(.badServerResponse)
            }
            responseData = data
        }

        try Task.checkCancellation()
        return String(decoding: responseData, as: UTF8.self)
    }



    /// 读取全部持久化代理规则并将生成的 PAC 内容写入应用本地目录。
    ///
    /// - Throws: 读取规则、创建目录或写入 PAC 文件失败时抛出原始错误。
    private func writePACFile() async throws {
        let storedRules = try modelContext.fetch(FetchDescriptor<MagentProxyRule>())
        let pacFileURL = await MainActor.run {
            MagentXApp.localDirectoryURL.appendingPathComponent("pac.json", isDirectory: false)
        }
        let pacBody = PACUtil.makePACBody(rules: storedRules)
        try await localExecutor.runBlocking {
            try FileManager.default.createDirectory(
                at: pacFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pacBody.write(to: pacFileURL, atomically: true, encoding: .utf8)
        }
    }
}
