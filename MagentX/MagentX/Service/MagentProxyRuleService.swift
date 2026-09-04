//
//  MagentProxyRuleService.swift
//  MagentX
//
//  Created by MarlinL on 2026/9/1.
//

import Foundation
import Magent
import SwiftData

/// 代理规则服务，负责在独立 SwiftData 执行器上完成 CRUD 与订阅同步。
@ModelActor
actor MagentProxyRuleService {
    /// 供界面读取的代理规则快照，避免跨执行器传递 SwiftData 模型。
    struct RuleSnapshot: Identifiable, Sendable {
        let id: Int
        let matchType: MatchType
        let matchValue: String
        let decision: RuleDecision
        let order: Int
        let source: String
        let createdAt: Date
        let updatedAt: Date

        /// 从当前模型上下文中的持久化对象生成不可变快照。
        ///
        /// - Parameter proxyRule: 待复制字段的持久化代理规则。
        fileprivate init(proxyRule: MagentProxyRule) {
            id = proxyRule.id
            matchType = proxyRule.matchType
            matchValue = proxyRule.matchValue
            decision = proxyRule.decision
            order = proxyRule.order
            source = proxyRule.source
            createdAt = proxyRule.createdAt
            updatedAt = proxyRule.updatedAt
        }
    }

    /// 代理规则分页查询结果，同时告知界面是否还有下一页。
    struct SearchResult: Sendable {
        let rules: [RuleSnapshot]
        let canLoadMore: Bool
    }

    /// 规则的业务匹配身份，用于在订阅同步时识别同一条数据库记录。
    private struct RuleIdentity: Hashable, Sendable {
        let matchType: MatchType
        let matchValue: String
    }

    private static let source = "rulesUrl"
    private static let importedRuleOrder = 100

    /// 批量新增用户代理规则，去除重复输入并分配最小未占用业务 id。
    ///
    /// - Parameters:
    ///   - matchType: 新规则共用的匹配类型。
    ///   - matchValues: 待清理、去重并持久化的匹配值。
    ///   - decision: 新规则共用的命中动作。
    /// - Throws: 匹配值为空、规则重复或持久化失败时抛出对应错误。
    func add(
        matchType: MatchType,
        matchValues: [String],
        decision: RuleDecision
    ) throws {
        var seenMatchValues = Set<String>()
        let uniqueMatchValues: [String] = matchValues.compactMap { matchValue in
            let normalizedValue = matchValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedValue.isEmpty == false,
                  seenMatchValues.insert(normalizedValue).inserted else {
                return nil
            }
            return normalizedValue
        }
        guard uniqueMatchValues.isEmpty == false else {
            throw MagentXError.emptyProxyRuleMatchValue
        }

        let existingRules = try modelContext.fetch(FetchDescriptor<MagentProxyRule>())
        let existingIdentities = Set(existingRules.map { proxyRule in
            RuleIdentity(matchType: proxyRule.matchType, matchValue: proxyRule.matchValue)
        })
        guard uniqueMatchValues.allSatisfy({ matchValue in
            existingIdentities.contains(RuleIdentity(matchType: matchType, matchValue: matchValue)) == false
        }) else {
            throw MagentXError.duplicateMagentProxyRule
        }

        var usedIDs = Set(existingRules.map(\.id))
        var nextIDCandidate = 0
        let now = Date.now
        for matchValue in uniqueMatchValues {
            while usedIDs.contains(nextIDCandidate) {
                nextIDCandidate += 1
            }
            modelContext.insert(MagentProxyRule(
                id: nextIDCandidate,
                matchType: matchType,
                matchValue: matchValue,
                decision: decision,
                order: 0,
                source: "user",
                createdAt: now,
                updatedAt: now
            ))
            usedIDs.insert(nextIDCandidate)
            nextIDCandidate += 1
        }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// 按业务 id 更新规则的匹配类型和动作，并将来源标记为用户编辑。
    ///
    /// - Parameters:
    ///   - id: 待更新规则的唯一整数业务主键。
    ///   - matchType: 界面提交的新匹配类型。
    ///   - decision: 界面提交的新命中动作。
    /// - Throws: 目标不存在、更新后规则重复或持久化失败时抛出对应错误。
    func update(id: Int, matchType: MatchType, decision: RuleDecision) throws {
        let existingRules = try modelContext.fetch(FetchDescriptor<MagentProxyRule>())
        guard let storedRule = existingRules.first(where: { $0.id == id }) else {
            throw MagentXError.missingMagentProxyRule(id)
        }
        guard existingRules.contains(where: { proxyRule in
            proxyRule.id != id
                && proxyRule.matchType == matchType
                && proxyRule.matchValue == storedRule.matchValue
        }) == false else {
            throw MagentXError.duplicateMagentProxyRule
        }

        storedRule.matchType = matchType
        storedRule.decision = decision
        storedRule.source = "user"
        storedRule.updatedAt = .now

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// 按业务 id 删除一条已持久化代理规则。
    ///
    /// - Parameter id: 待删除规则的唯一整数业务主键。
    /// - Throws: 目标不存在时抛出 `MagentXError.missingMagentProxyRule`；读取或保存失败时抛出原始错误。
    func delete(_ id: Int) throws {
        let descriptor = FetchDescriptor<MagentProxyRule>(
            predicate: #Predicate<MagentProxyRule> { proxyRule in
                proxyRule.id == id
            }
        )
        guard let proxyRule = try modelContext.fetch(descriptor).first else {
            throw MagentXError.missingMagentProxyRule(id)
        }

        modelContext.delete(proxyRule)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// 按关键字和从 `1` 开始的页码读取规则快照。
    ///
    /// - Parameters:
    ///   - keyword: 用于包含匹配 `matchValue` 的关键字；空白值表示全部规则。
    ///   - pageAt: 从 `1` 开始的页码。
    ///   - pageSize: 当页最多返回的规则数。
    /// - Returns: 按顺序和匹配值排序的规则快照，以及是否存在下一页。
    /// - Throws: SwiftData 查询失败时抛出原始错误。
    func search(keyword: String, pageAt: Int = 1, pageSize: Int) throws -> SearchResult {
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
        let rules = fetchedRules.prefix(pageSize).map { proxyRule in
            RuleSnapshot(proxyRule: proxyRule)
        }
        return SearchResult(
            rules: rules,
            canLoadMore: fetchedRules.count > rules.count
        )
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
            responseData = try await MagentXAsyncExecutor.shared.runBlocking {
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

    /// 读取全部持久化代理规则并将生成的 PAC 内容写入应用本地目录。
    ///
    /// - Throws: 读取规则、创建目录或写入 PAC 文件失败时抛出原始错误。
    private func writePACFile() async throws {
        let pacRules = try modelContext.fetch(FetchDescriptor<MagentProxyRule>())
        let pacFileURL = await MainActor.run {
            MagentXApp.localDirectoryURL.appendingPathComponent("pac.json", isDirectory: false)
        }
        let pacBody = PACUtil.makePACBody(rules: pacRules)
        try await MagentXAsyncExecutor.shared.runBlocking {
            try FileManager.default.createDirectory(
                at: pacFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pacBody.write(to: pacFileURL, atomically: true, encoding: .utf8)
        }
    }
}
