//
//  MagentProxyRuleService.swift
//  MagentX
//
//  Created by MarlinL on 2026/9/1.
//

import FactoryKit
import Foundation
import Magent
import OSLog
import SwiftData

/// 代理规则服务，负责在独立 SwiftData 执行器上完成订阅同步。
@ModelActor
actor MagentProxyRuleService {
    @Injected(\.localExecutor) private var localExecutor

    /// 规则的业务匹配身份，用于在订阅同步时识别同一条数据库记录。
    private struct RuleIdentity: Hashable, Sendable {
        let matchType: String
        let matchValue: String
    }

    private static let source = "rulesUrl"
    private static let importedRuleOrder = 100

    /// 下载并解析当前规则订阅，将规则批量写入 SwiftData。
    ///
    /// 副作用：下载规则文件、解析规则并通过业务唯一键批量 upsert 后保存 SwiftData。
    /// - Throws: 下载、解析或持久化失败时抛出原始错误。
    func sync() async throws {
        AppLog.rules.info("Starting proxy rule synchronization")

        // 1. 从当前规则订阅地址下载完整文件内容。
        let response = try await downloadFromRuleUrl()

        // 2. 对文件内容进行 Base64 解码，并解析为规则数组 [AdblockUtil.Rule]。
        guard let decodedData = Data(base64Encoded: response, options: [.ignoreUnknownCharacters]) else {
            throw MagentXError.invalidAclBase64Data
        }
        guard let decodedText = String(data: decodedData, encoding: .utf8) else {
            throw MagentXError.invalidAclDecodedText
        }
        let downloadedRules = AdblockUtil.parsePACRules(decodedText)

        // 3. 批量组建待写入的 [MagentProxyRule]，已有规则复用 id 和创建时间。
        let existingRules = try modelContext.fetch(FetchDescriptor<MagentProxyRule>())
        let rulesByIdentity = Dictionary(uniqueKeysWithValues: existingRules.map { existingRule in
            (RuleIdentity(
                matchType: existingRule.matchType,
                matchValue: existingRule.matchValue
            ), existingRule)
        })
        var usedIDs = Set(existingRules.map(\.id))
        var nextIDCandidate = 0
        let now = Date.now
        let proxyRules = downloadedRules.map { downloadedRule in
            let identity = RuleIdentity(
                matchType: downloadedRule.matchType.rawValue,
                matchValue: downloadedRule.matchValue
            )
            let existingRule = rulesByIdentity[identity]
            let id: Int
            if let existingRule {
                id = existingRule.id
            } else {
                while usedIDs.contains(nextIDCandidate) {
                    nextIDCandidate += 1
                }
                id = nextIDCandidate
                usedIDs.insert(nextIDCandidate)
                nextIDCandidate += 1
            }

            return MagentProxyRule(
                id: id,
                matchType: downloadedRule.matchType.rawValue,
                matchValue: downloadedRule.matchValue,
                decision: downloadedRule.isException ? "direct" : "proxy",
                order: Self.importedRuleOrder,
                source: Self.source,
                createdAt: existingRule?.createdAt ?? now,
                updatedAt: now
            )
        }

        // 4. 利用 (matchType, matchValue) 业务唯一键批量 upsert，并统一保存。
        for proxyRule in proxyRules {
            modelContext.insert(proxyRule)
        }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            AppLog.database.error("Failed to save synchronized proxy rules")
            throw error
        }

        AppLog.rules.info("Completed proxy rule synchronization")
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
}
