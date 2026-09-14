//
//  SyncProxyRulesCoordinator.swift
//  MagentX
//
//  Created by MarlinL on 2026/9/9.
//

import FactoryKit
import Foundation
import Magent
import Observation
import OSLog
import SwiftData

/// 在应用进程内统一维护代理规则同步任务及其界面可观察状态。
@MainActor
@Observable
final class SyncProxyRulesCoordinator {
    /// 代理规则同步任务的可观察执行状态。
    enum State: Equatable, Sendable {
        case idle
        case running
    }

    /// 当前代理规则同步任务的执行状态。
    private(set) var state = State.idle
    /// 最近一次代理规则同步失败的错误说明。
    var syncError: String?

    @ObservationIgnored
    @Injected(\.localExecutor) private var localExecutor
    @ObservationIgnored
    private let modelContainer: ModelContainer

    /// 规则的业务匹配身份，用于在订阅同步时识别同一条数据库记录。
    private nonisolated struct RuleIdentity: Hashable, Sendable {
        let matchType: String
        let matchValue: String
    }

    private nonisolated static let source = "rulesUrl"
    private nonisolated static let importedRuleOrder = 100

    /// 创建绑定指定 SwiftData 容器、由 Factory 管理生命周期的代理规则同步协调器。
    ///
    /// - Parameter modelContainer: 同步完成后写入代理规则的 SwiftData 容器。
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// 启动一次代理规则同步；已有同步任务时保持当前任务，不重复提交。
    func sync() {
        guard state == .idle else { return }

        let syncStartedAt = Date.now
        let modelContainer = self.modelContainer
        state = .running
        syncError = nil
        AppLog.rules.info("Starting proxy rule synchronization")

        localExecutor.submit(
            priority: .utility,
            operation: {
                // 1. 从当前规则订阅地址下载完整文件内容。
                let response = try await self.downloadFromRuleURL()

                // 2. 对文件内容进行 Base64 解码，并解析为规则数组 [AdblockUtil.Rule]。
                guard let decodedData = Data(
                    base64Encoded: response,
                    options: [.ignoreUnknownCharacters]
                ) else {
                    throw MagentXError.invalidAclBase64Data
                }
                guard let decodedText = String(data: decodedData, encoding: .utf8) else {
                    throw MagentXError.invalidAclDecodedText
                }
                let downloadedRules = AdblockUtil.parsePACRules(decodedText)

                // 3. 批量组建待写入的 [MagentProxyRule]，已有规则复用 id 和创建时间。
                let modelContext = ModelContext(modelContainer)
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
                    await MainActor.run {
                        AppLog.database.error("Failed to save synchronized proxy rules")
                    }
                    throw error
                }
            },
            completion: { result in
                self.state = .idle
                switch result {
                case .success:
                    var refreshedSettings = GeneralSettings.load()
                    refreshedSettings.updatedAt = syncStartedAt
                    refreshedSettings.save()
                    AppLog.rules.info("Completed proxy rule synchronization")
                case .failure(let error):
                    self.syncError = error.localizedDescription
                }
            }
        )
    }

    /// 从当前规则订阅 URL 下载完整响应正文，不做 Base64 解码或内容裁剪。
    private func downloadFromRuleURL() async throws -> String {
        let rulesURLValue = GeneralSettings.load().rulesURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
