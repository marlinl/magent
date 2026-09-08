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

    /// 同步当前规则订阅并重写本地 PAC 文件。
    ///
    /// 副作用：下载并合并规则、保存 SwiftData、更新 PAC 文件，以及写入不含规则内容的系统日志。
    /// - Throws: 下载、解析、持久化或 PAC 写入失败时抛出原始错误。
    func sync() async throws {
        AppLog.rules.info("Starting proxy rule synchronization")
        let response = try await downloadFromRuleUrl()
        guard let decodedData = Data(base64Encoded: response, options: [.ignoreUnknownCharacters]) else {
            throw MagentXError.invalidAclBase64Data
        }
        guard let decodedText = String(data: decodedData, encoding: .utf8) else {
            throw MagentXError.invalidAclDecodedText
        }
        let downloadedRules = AdblockUtil.parsePACRules(decodedText)
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
                matchType: downloadedRule.matchType.rawValue,
                matchValue: downloadedRule.matchValue
            )
            let decision = downloadedRule.isException ? "direct" : "proxy"

            if let existingRule = rulesByIdentity[identity] {
                guard existingRule.source == Self.source else { continue }
                existingRule.matchType = downloadedRule.matchType.rawValue
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
                matchType: downloadedRule.matchType.rawValue,
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
            AppLog.database.error("Failed to save synchronized proxy rules")
            throw error
        }

        try await writePACFile()
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



    /// 读取全部持久化代理规则并将生成的 PAC 内容写入应用本地目录。
    ///
    /// 副作用：读取 SwiftData 并覆盖应用本地 PAC 文件，不记录规则正文或存储路径。
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
