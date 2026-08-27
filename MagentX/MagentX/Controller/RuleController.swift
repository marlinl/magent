//
//  RuleController.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Coordinates access rule business operations.
//

import Combine
import Foundation
import Magent
import SwiftData

/// 规则订阅刷新结果摘要，用于展示或测试本次导入的处理数量。
struct RuleListRefreshSummary: Equatable, Sendable {
    var parsedRuleCount: Int
    var insertedRuleCount: Int
    var refreshedRuleCount: Int
    var skippedRuleCount: Int
}

/// 访问规则业务控制器，负责规则分页、手工编辑和 GFWList 刷新导入。
@MainActor
final class RuleController: ObservableObject {
    @Published private(set) var accessControlRules: [AccessControlRule] = []
    @Published private(set) var loadError: String?
    @Published private(set) var canLoadMore = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshSummary: RuleListRefreshSummary?

    private let aclService: AclService
    private let pacFileService: PacFileService
    private let generalSettingsProvider: () -> GeneralSettings
    private let pageSize = 50
    private var fetchLimit = 50
    private var currentSearchText = ""

    /// 创建规则控制器，并注入 ACL 订阅服务和 PAC 文件服务。
    init(
        aclService: AclService = .shared,
        pacFileService: PacFileService = .shared,
        generalSettingsProvider: @escaping () -> GeneralSettings = { GeneralSettings.load() }
    ) {
        self.aclService = aclService
        self.pacFileService = pacFileService
        self.generalSettingsProvider = generalSettingsProvider
    }

    /// 重置分页状态并加载第一页访问规则。
    func loadFirstPage(from modelContext: ModelContext, matching searchText: String = "") {
        currentSearchText = searchText
        fetchLimit = pageSize
        load(from: modelContext)
    }

    /// 在还有更多记录时扩大读取上限并加载下一页访问规则。
    func loadNextPage(from modelContext: ModelContext, matching searchText: String = "") {
        guard canLoadMore else { return }
        currentSearchText = searchText
        fetchLimit += pageSize
        load(from: modelContext)
    }

    /// 从常规设置读取订阅 URL，等待 `AclService` 下载解析后导入 SwiftData。
    func refreshRuleList(from modelContext: ModelContext, matching searchText: String = "") async {
        guard isRefreshing == false else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let settings = generalSettingsProvider()
            let url = try rulesURL(from: settings)
            let now = Date.now
            let proxyEndpoint = try PacFileService.ProxyEndpoint(generalSettings: settings)
            let downloadedAccessControlRules = try await aclService.downloadAndParse(from: url)
            refreshSummary = try await Self.importRuleListInBackground(
                downloadedAccessControlRules,
                into: modelContext.container,
                now: now,
                pacFileDirectoryURL: pacFileService.directoryURL,
                proxyEndpoint: proxyEndpoint
            )
            var refreshedSettings = settings
            refreshedSettings.updatedAt = now
            refreshedSettings.save()
            loadFirstPage(from: modelContext, matching: searchText)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func load(from modelContext: ModelContext) {
        let query = currentSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sortDescriptors: [SortDescriptor<AccessControlRule>] = [
            SortDescriptor(\.order),
            SortDescriptor(\.matchValue)
        ]

        var descriptor: FetchDescriptor<AccessControlRule>
        if query.isEmpty {
            descriptor = FetchDescriptor<AccessControlRule>(sortBy: sortDescriptors)
        } else {
            descriptor = FetchDescriptor<AccessControlRule>(
                predicate: #Predicate<AccessControlRule> { accessControlRule in
                    accessControlRule.matchValue.contains(query)
                },
                sortBy: sortDescriptors
            )
        }
        descriptor.fetchLimit = fetchLimit + 1

        do {
            let fetchedAccessControlRules = try modelContext.fetch(descriptor)
            accessControlRules = Array(fetchedAccessControlRules.prefix(fetchLimit))
            loadError = nil
            canLoadMore = fetchedAccessControlRules.count > accessControlRules.count
        } catch {
            accessControlRules = []
            loadError = error.localizedDescription
            canLoadMore = false
        }
    }

    /// 创建一条手工访问规则，校验通过后写入 SwiftData。
    @discardableResult
    func addAccessControl(
        matchType: Magent.MatchType,
        matchValue: String,
        decision: String,
        order: Int = 0,
        source: String = "",
        in modelContext: ModelContext
    ) -> Bool {
        let now = Date.now
        let accessControlRule = AccessControlRule(
            matchType: matchType,
            matchValue: matchValue,
            decision: decision,
            order: order,
            source: source,
            createdAt: now,
            updatedAt: now
        )

        guard validate(accessControlRule) else { return false }

        do {
            guard try existingAccessControlRule(
                matchType: matchType,
                matchValue: matchValue,
                in: modelContext
            ) == nil else {
                loadError = MagentXError.duplicateAccessControlRule.localizedDescription
                return false
            }

            modelContext.insert(accessControlRule)
            try modelContext.save()
            let didRewritePAC = rewriteProxyHostPACAfterSave(from: modelContext)
            load(from: modelContext)
            return didRewritePAC
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    /// 批量创建手工访问规则，所有匹配值共享同一个匹配类型和命中动作。
    @discardableResult
    func addAccessControls(
        matchType: Magent.MatchType,
        matchValues: [String],
        decision: String,
        order: Int = 0,
        source: String = "",
        in modelContext: ModelContext
    ) -> Bool {
        var seenRuleIDs = Set<UUID>()
        let uniqueMatchValues = matchValues.compactMap { matchValue -> String? in
            let trimmedMatchValue = matchValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedMatchValue.isEmpty == false else { return nil }
            let ruleID = AccessControlRule.makeID(matchType: matchType, matchValue: trimmedMatchValue)
            guard seenRuleIDs.insert(ruleID).inserted else { return nil }
            return trimmedMatchValue
        }

        guard uniqueMatchValues.isEmpty == false else {
            loadError = String(localized: "Match value is required")
            return false
        }

        guard decision == "direct" || decision == "proxy" else {
            loadError = String(localized: "Decision must be direct or proxy")
            return false
        }

        do {
            for matchValue in uniqueMatchValues {
                guard try existingAccessControlRule(
                    matchType: matchType,
                    matchValue: matchValue,
                    in: modelContext
                ) == nil else {
                    loadError = MagentXError.duplicateAccessControlRule.localizedDescription
                    return false
                }
            }

            let now = Date.now
            let accessControlRules = uniqueMatchValues.map { matchValue in
                AccessControlRule(
                    matchType: matchType,
                    matchValue: matchValue,
                    decision: decision,
                    order: order,
                    source: source,
                    createdAt: now,
                    updatedAt: now
                )
            }

            for accessControlRule in accessControlRules {
                modelContext.insert(accessControlRule)
            }

            try modelContext.save()
            let didRewritePAC = rewriteProxyHostPACAfterSave(from: modelContext)
            load(from: modelContext)
            return didRewritePAC
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    /// 更新规则命中后的动作，并保存到 SwiftData。
    func updateDecision(
        _ decision: String,
        for accessControlRule: AccessControlRule,
        in modelContext: ModelContext
    ) {
        let previousDecision = accessControlRule.decision
        let previousUpdatedAt = accessControlRule.updatedAt

        accessControlRule.decision = decision
        accessControlRule.updatedAt = .now

        guard validate(accessControlRule) else {
            accessControlRule.decision = previousDecision
            accessControlRule.updatedAt = previousUpdatedAt
            return
        }
        do {
            try modelContext.save()
            _ = rewriteProxyHostPACAfterSave(from: modelContext)
            load(from: modelContext)
        } catch {
            accessControlRule.decision = previousDecision
            accessControlRule.updatedAt = previousUpdatedAt
            loadError = error.localizedDescription
        }
    }

    /// 更新访问规则的完整字段，校验或保存失败时回滚原值。
    @discardableResult
    func updateAccessControl(
        _ accessControlRule: AccessControlRule,
        matchType: Magent.MatchType,
        matchValue: String,
        decision: String,
        order: Int,
        source: String,
        in modelContext: ModelContext
    ) -> Bool {
        let previousMatchType = accessControlRule.matchType
        let previousMatchValue = accessControlRule.matchValue
        let previousDecision = accessControlRule.decision
        let previousOrder = accessControlRule.order
        let previousSource = accessControlRule.source
        let previousUpdatedAt = accessControlRule.updatedAt

        guard validate(matchValue: matchValue, decision: decision) else { return false }

        do {
            if try existingAccessControlRule(
                matchType: matchType,
                matchValue: matchValue,
                excludingID: accessControlRule.id,
                in: modelContext
            ) != nil {
                rollback(
                    accessControlRule,
                    matchType: previousMatchType,
                    matchValue: previousMatchValue,
                    decision: previousDecision,
                    order: previousOrder,
                    source: previousSource,
                    updatedAt: previousUpdatedAt
                )
                loadError = MagentXError.duplicateAccessControlRule.localizedDescription
                return false
            }
        } catch {
            rollback(
                accessControlRule,
                matchType: previousMatchType,
                matchValue: previousMatchValue,
                decision: previousDecision,
                order: previousOrder,
                source: previousSource,
                updatedAt: previousUpdatedAt
            )
            loadError = error.localizedDescription
            return false
        }

        accessControlRule.updateIdentity(matchType: matchType, matchValue: matchValue)
        accessControlRule.decision = decision
        accessControlRule.order = order
        accessControlRule.source = source
        accessControlRule.updatedAt = .now

        do {
            try modelContext.save()
            let didRewritePAC = rewriteProxyHostPACAfterSave(from: modelContext)
            load(from: modelContext)
            return didRewritePAC
        } catch {
            rollback(
                accessControlRule,
                matchType: previousMatchType,
                matchValue: previousMatchValue,
                decision: previousDecision,
                order: previousOrder,
                source: previousSource,
                updatedAt: previousUpdatedAt
            )
            loadError = error.localizedDescription
            return false
        }
    }

    /// 删除指定访问规则，并刷新当前分页列表。
    func deleteAccessControl(_ accessControlRule: AccessControlRule, from modelContext: ModelContext) {
        do {
            try deleteProxyPolicyRules(ruleID: accessControlRule.id, from: modelContext)
            modelContext.delete(accessControlRule)
            try modelContext.save()
            _ = rewriteProxyHostPACAfterSave(from: modelContext)
            load(from: modelContext)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// 导入下载得到的访问规则，刷新已有订阅规则并跳过手工规则冲突。
    @discardableResult
    func importRuleList(
        _ downloadedAccessControlRules: [AccessControlRuleImport],
        into modelContext: ModelContext,
        settings: GeneralSettings?,
        now: Date = .now
    ) throws -> RuleListRefreshSummary {
        let summary = try Self.performRuleListImport(
            downloadedAccessControlRules,
            into: modelContext,
            now: now,
            pacFileDirectoryURL: settings == nil ? nil : pacFileService.directoryURL,
            proxyEndpoint: settings.map { try PacFileService.ProxyEndpoint(generalSettings: $0) }
        )

        if var settings {
            settings.updatedAt = now
            settings.save()
        }
        loadError = nil
        return summary
    }

    private nonisolated static func importRuleListInBackground(
        _ downloadedAccessControlRules: [AccessControlRuleImport],
        into modelContainer: ModelContainer,
        now: Date,
        pacFileDirectoryURL: URL,
        proxyEndpoint: PacFileService.ProxyEndpoint
    ) async throws -> RuleListRefreshSummary {
        try await Task.detached(priority: .userInitiated) {
            let modelContext = ModelContext(modelContainer)
            return try Self.performRuleListImport(
                downloadedAccessControlRules,
                into: modelContext,
                now: now,
                pacFileDirectoryURL: pacFileDirectoryURL,
                proxyEndpoint: proxyEndpoint
            )
        }.value
    }

    private nonisolated static func performRuleListImport(
        _ downloadedAccessControlRules: [AccessControlRuleImport],
        into modelContext: ModelContext,
        now: Date,
        pacFileDirectoryURL: URL?,
        proxyEndpoint: PacFileService.ProxyEndpoint?
    ) throws -> RuleListRefreshSummary {
        var insertedCount = 0
        var refreshedCount = 0
        var skippedCount = 0
        let existingAccessControlRules = try modelContext.fetch(FetchDescriptor<AccessControlRule>())
        var existingAccessControlRulesByID = Dictionary(
            uniqueKeysWithValues: existingAccessControlRules.map { ($0.id, $0) }
        )

        for downloadedAccessControlRule in downloadedAccessControlRules {
            let ruleID = AccessControlRule.makeID(
                matchType: downloadedAccessControlRule.matchType,
                matchValue: downloadedAccessControlRule.matchValue
            )

            if let existingAccessControlRule = existingAccessControlRulesByID[ruleID] {
                if existingAccessControlRule.source == downloadedAccessControlRule.source {
                    existingAccessControlRule.updateIdentity(
                        matchType: downloadedAccessControlRule.matchType,
                        matchValue: downloadedAccessControlRule.matchValue
                    )
                    existingAccessControlRule.decision = downloadedAccessControlRule.decision
                    existingAccessControlRule.order = downloadedAccessControlRule.order
                    existingAccessControlRule.source = downloadedAccessControlRule.source
                    existingAccessControlRule.updatedAt = now
                    refreshedCount += 1
                } else {
                    skippedCount += 1
                }
                continue
            }

            let accessControlRule = AccessControlRule(
                matchType: downloadedAccessControlRule.matchType,
                matchValue: downloadedAccessControlRule.matchValue,
                decision: downloadedAccessControlRule.decision,
                order: downloadedAccessControlRule.order,
                source: downloadedAccessControlRule.source,
                createdAt: now,
                updatedAt: now
            )
            modelContext.insert(accessControlRule)
            existingAccessControlRulesByID[accessControlRule.id] = accessControlRule
            insertedCount += 1
        }

        try modelContext.save()
        if let pacFileDirectoryURL, let proxyEndpoint {
            let pacRules = existingAccessControlRulesByID.values.map(PacFileService.Rule.init(accessControlRule:))
            try PacFileService.writeProxyHostPAC(
                rules: pacRules,
                proxyEndpoint: proxyEndpoint,
                directoryURL: pacFileDirectoryURL
            )
        }

        return RuleListRefreshSummary(
            parsedRuleCount: downloadedAccessControlRules.count,
            insertedRuleCount: insertedCount,
            refreshedRuleCount: refreshedCount,
            skippedRuleCount: skippedCount
        )
    }

    private func rulesURL(from settings: GeneralSettings) throws -> URL {
        let value = settings.rulesURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else {
            throw MagentXError.missingRulesURL
        }
        guard let url = URL(string: value), url.scheme != nil else {
            throw MagentXError.invalidRulesURL(value)
        }
        return url
    }

    private func existingAccessControlRule(
        matchType: Magent.MatchType,
        matchValue: String,
        excludingID: UUID? = nil,
        in modelContext: ModelContext
    ) throws -> AccessControlRule? {
        let descriptor = FetchDescriptor<AccessControlRule>(
            predicate: #Predicate { accessControlRule in
                accessControlRule.matchValue == matchValue
            }
        )
        return try modelContext.fetch(descriptor).first { accessControlRule in
            guard accessControlRule.matchType == matchType else { return false }
            guard let excludingID else { return true }
            return accessControlRule.id != excludingID
        }
    }

    private func rewriteProxyHostPACAfterSave(from modelContext: ModelContext) -> Bool {
        do {
            try pacFileService.rewriteProxyHostPAC(
                from: modelContext,
                generalSettings: generalSettingsProvider()
            )
            loadError = nil
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    private func validate(_ accessControlRule: AccessControlRule) -> Bool {
        validate(matchValue: accessControlRule.matchValue, decision: accessControlRule.decision)
    }

    private func validate(matchValue: String, decision: String) -> Bool {
        guard matchValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            loadError = String(localized: "Match value is required")
            return false
        }

        guard decision == "direct" || decision == "proxy" else {
            loadError = String(localized: "Decision must be direct or proxy")
            return false
        }

        loadError = nil
        return true
    }

    private func rollback(
        _ accessControlRule: AccessControlRule,
        matchType: Magent.MatchType,
        matchValue: String,
        decision: String,
        order: Int,
        source: String,
        updatedAt: Date
    ) {
        accessControlRule.updateIdentity(matchType: matchType, matchValue: matchValue)
        accessControlRule.decision = decision
        accessControlRule.order = order
        accessControlRule.source = source
        accessControlRule.updatedAt = updatedAt
    }

    private func deleteProxyPolicyRules(ruleID: UUID, from modelContext: ModelContext) throws {
        let descriptor = FetchDescriptor<ProxyPolicyRule>(
            predicate: #Predicate<ProxyPolicyRule> { policyRule in
                policyRule.ruleID == ruleID
            }
        )
        for policyRule in try modelContext.fetch(descriptor) {
            modelContext.delete(policyRule)
        }
    }
}
