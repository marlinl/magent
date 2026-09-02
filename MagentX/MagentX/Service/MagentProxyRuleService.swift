//
//  MagentProxyRuleService.swift
//  MagentX
//
//  Created by MarlinL on 2026/9/1.
//

import Foundation
import Magent
import SwiftData

/// 代理规则订阅服务，负责在独立 SwiftData 执行器上下载、解析并合并 GFWList 规则。
@ModelActor
actor MagentProxyRuleService {
    /// 规则的业务匹配身份，用于在订阅同步时识别同一条数据库记录。
    private struct RuleIdentity: Hashable, Sendable {
        let matchType: MatchType
        let matchValue: String
    }

    private static let source = "rulesUrl"
    private static let importedRuleOrder = 100

    /// 从当前规则订阅 URL 下载完整响应正文，不做 Base64 解码或内容裁剪。
    func downloadFromRuleUrl() async throws -> String {
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
            responseData = try Data(contentsOf: rulesURL)
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

    /// 启动规则订阅同步并返回可等待的任务；任务完成值是生成 PAC 所需的规则快照。
    ///
    /// 网络等待、Base64 解码、规则解析和 SwiftData 合并都在服务执行器上完成，调用方可等待
    /// `Task.value`，并在恢复到主执行器后更新界面。
    func syncRuleFromUrl() -> Task<[PacFileService.Rule], Error> {
        Task(priority: .userInitiated) {
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

            try modelContext.save()
            return rulesByIdentity.values.map { proxyRule in
                PacFileService.Rule(
                    matchType: proxyRule.matchType,
                    matchValue: proxyRule.matchValue,
                    decision: proxyRule.decision.rawValue,
                    order: proxyRule.order
                )
            }
        }
    }

}
