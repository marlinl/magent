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

    /// 异步下载、解析并合并规则订阅；失败时向调用方传播原始错误。
    func syncRuleFromUrl() async throws {
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

    private func writePACFile() async throws {
        let pacRules = try modelContext.fetch(FetchDescriptor<MagentProxyRule>()).map { proxyRule in
            PACUtil.Rule(
                matchType: proxyRule.matchType,
                matchValue: proxyRule.matchValue,
                decision: proxyRule.decision,
                order: proxyRule.order
            )
        }
        let (proxyEndpoint, pacFileURL) = try await MainActor.run {
            let generalSettings = GeneralSettings.load()
            return (
                try PACUtil.ProxyEndpoint(
                    address: generalSettings.proxyListenAddress,
                    port: generalSettings.proxyListenPort
                ),
                MagentXApp.localDirectoryURL.appendingPathComponent("pac.json", isDirectory: false)
            )
        }
        let pacBody = PACUtil.makePACBody(rules: pacRules, proxyEndpoint: proxyEndpoint)

        try await MagentXAsyncExecutor.shared.runBlocking {
            try FileManager.default.createDirectory(
                at: pacFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try pacBody.write(to: pacFileURL, atomically: true, encoding: .utf8)
        }
    }
}
