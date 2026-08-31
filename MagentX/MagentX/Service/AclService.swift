//
//  AclService.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Downloads and parses access-control subscription lists.
//

import Foundation
import Magent
import SwiftData

/// 订阅列表解析出的轻量访问规则导入项，供规则订阅服务写入 SwiftData。
struct AccessControlRuleImport: Equatable, Sendable {
    let matchType: MatchType
    let matchValue: String
    let decision: String
    let order: Int
    let source: String

    var id: UUID {
        AccessControlRule.makeID(matchType: matchType, matchValue: matchValue)
    }
}

/// 访问控制列表服务，负责下载 GFWList 风格订阅并解析为导入项。
actor AclService {
    /// 订阅规则的匹配身份，用于合并刷新时识别同一条代理规则。
    private struct ProxyRuleIdentity: Hashable, Sendable {
        let matchType: MatchType
        let matchValue: String
    }

    static let shared = AclService()
    nonisolated static let source = "rulesUrl"
    nonisolated static let defaultStorageDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".MagentX", isDirectory: true)
    nonisolated static let gfwlistFileName = "gfwlist.txt"
    nonisolated static let publicSuffixListFileName = "PSL.dat"
    nonisolated static let gfwlistFileURL = defaultStorageDirectoryURL.appendingPathComponent(gfwlistFileName, isDirectory: false)
    nonisolated static let publicSuffixListFileURL = defaultStorageDirectoryURL
        .appendingPathComponent(publicSuffixListFileName, isDirectory: false)
    private nonisolated static let defaultImportedRuleOrder = 100

    private let fileManager = FileManager.default
    private let storageDirectoryURL: URL
    private let gfwlistFileURL: URL
    private let publicSuffixListFileURL: URL

    /// 创建访问控制列表服务，默认把下载文件缓存到 `~/.MagentX`。
    init(storageDirectoryURL: URL = AclService.defaultStorageDirectoryURL) {
        self.storageDirectoryURL = storageDirectoryURL
        self.gfwlistFileURL = storageDirectoryURL.appendingPathComponent(Self.gfwlistFileName, isDirectory: false)
        self.publicSuffixListFileURL = storageDirectoryURL.appendingPathComponent(
            Self.publicSuffixListFileName,
            isDirectory: false
        )
    }

    // MARK: - Public API

    /// 下载订阅列表并解析为使用 `AclService.source` 标记的访问控制规则。
    func downloadAndParse(from url: URL) async throws -> [AccessControlRuleImport] {
        if url.isFileURL {
            return try parseListFile(url)
        }

        let (temporaryURL, _) = try await URLSession.shared.download(from: url)
        let fileURL = try replaceStoredFile(at: gfwlistFileURL, with: temporaryURL, shouldMoveSource: true)
        return try parseListFile(fileURL)
    }

    /// 下载订阅并在后台上下文合并为 `MagentProxyRule`，返回生成 PAC 所需的规则快照。
    func downloadAndImportMagentProxyRules(
        from url: URL,
        into modelContainer: ModelContainer,
        now: Date
    ) async throws -> [PacFileService.Rule] {
        let downloadedRules = try await downloadAndParse(from: url)
        return try await Task.detached(priority: .userInitiated) {
            let modelContext = ModelContext(modelContainer)
            return try Self.importMagentProxyRules(
                downloadedRules,
                into: modelContext,
                now: now
            )
        }.value
    }

    /// 把订阅规则合并到 `MagentProxyRule`，同来源规则会刷新，手工冲突规则会跳过。
    nonisolated static func importMagentProxyRules(
        _ downloadedRules: [AccessControlRuleImport],
        into modelContext: ModelContext,
        now: Date
    ) throws -> [PacFileService.Rule] {
        let existingRules = try modelContext.fetch(FetchDescriptor<MagentProxyRule>())
        var rulesByIdentity: [ProxyRuleIdentity: MagentProxyRule] = [:]
        for existingRule in existingRules {
            let identity = ProxyRuleIdentity(
                matchType: existingRule.matchType,
                matchValue: existingRule.matchValue
            )
            rulesByIdentity[identity] = existingRule
        }

        var usedIDs = Set(existingRules.map(\.id))
        var nextIDCandidate = 0
        for downloadedRule in downloadedRules {
            guard let decision = RuleDecision(rawValue: downloadedRule.decision) else { continue }
            let identity = ProxyRuleIdentity(
                matchType: downloadedRule.matchType,
                matchValue: downloadedRule.matchValue
            )

            if let existingRule = rulesByIdentity[identity] {
                guard existingRule.source == downloadedRule.source else { continue }
                existingRule.matchType = downloadedRule.matchType
                existingRule.matchValue = downloadedRule.matchValue
                existingRule.decision = decision
                existingRule.order = downloadedRule.order
                existingRule.source = downloadedRule.source
                existingRule.updatedAt = now
                continue
            }

            while usedIDs.contains(nextIDCandidate) {
                nextIDCandidate += 1
            }
            let id = nextIDCandidate
            usedIDs.insert(id)
            nextIDCandidate += 1

            let proxyRule = MagentProxyRule(
                id: id,
                matchType: downloadedRule.matchType,
                matchValue: downloadedRule.matchValue,
                decision: decision,
                order: downloadedRule.order,
                source: downloadedRule.source,
                createdAt: now,
                updatedAt: now
            )
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

    /// 下载 Public Suffix List，并保存为 `~/.MagentX/PSL.dat` 供后续规则解析使用。
    @discardableResult
    func downloadPSL(from url: URL) async throws -> URL {
        if url.isFileURL {
            return try replaceStoredFile(at: publicSuffixListFileURL, with: url, shouldMoveSource: false)
        }

        let (temporaryURL, _) = try await URLSession.shared.download(from: url)
        return try replaceStoredFile(at: publicSuffixListFileURL, with: temporaryURL, shouldMoveSource: true)
    }

    private func parseListFile(_ fileURL: URL) throws -> [AccessControlRuleImport] {
        let encodedData = try Data(contentsOf: fileURL)
        guard let decodedData = Data(base64Encoded: encodedData, options: [.ignoreUnknownCharacters]) else {
            throw MagentXError.invalidAclBase64Data
        }
        guard let text = String(data: decodedData, encoding: .utf8) else {
            throw MagentXError.invalidAclDecodedText
        }
        return Self.parseRulesText(text)
    }

    /// 解析一条访问控制规则的可注册 suffix domain，并补齐命中策略组的 `ProxyPolicyRule` 关联。
    ///
    /// 当前 `ProxyPolicy` 没有独立 domain 字段，因此使用策略组 `name` 与 PSL 解析出的 suffix domain
    /// 做精确匹配；同名策略组可能有多条，所以会返回该规则命中的全部关联记录。
    nonisolated static func parseAccessControlRule(
        _ accessControlRule: AccessControlRule,
        in modelContext: ModelContext,
        publicSuffixListFileURL: URL = AclService.publicSuffixListFileURL
    ) throws -> [ProxyPolicyRule] {
        guard let suffixDomain = try suffixDomain(for: accessControlRule, publicSuffixListFileURL: publicSuffixListFileURL) else {
            return []
        }

        let proxyPolicies = try modelContext.fetch(FetchDescriptor<ProxyPolicy>())
            .filter { proxyPolicy in
                AclService.normalizedDomain(proxyPolicy.name) == suffixDomain
            }
        guard proxyPolicies.isEmpty == false else { return [] }

        let ruleID = accessControlRule.id
        var proxyPolicyRules: [ProxyPolicyRule] = []
        var didInsert = false

        for proxyPolicy in proxyPolicies {
            if let existingPolicyRule = try existingProxyPolicyRule(
                proxyPolicyID: proxyPolicy.id,
                ruleID: ruleID,
                in: modelContext
            ) {
                proxyPolicyRules.append(existingPolicyRule)
                continue
            }

            let proxyPolicyRule = ProxyPolicyRule(
                proxyPolicy: proxyPolicy,
                accessControlRule: accessControlRule
            )
            modelContext.insert(proxyPolicyRule)
            proxyPolicyRules.append(proxyPolicyRule)
            didInsert = true
        }

        if didInsert {
            try modelContext.save()
        }
        return proxyPolicyRules.sorted(by: sortPolicyRules)
    }

    private func replaceStoredFile(
        at destinationURL: URL,
        with sourceURL: URL,
        shouldMoveSource: Bool
    ) throws -> URL {
        try fileManager.createDirectory(
            at: storageDirectoryURL,
            withIntermediateDirectories: true
        )

        guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else {
            return destinationURL
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        if shouldMoveSource {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } else {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
        return destinationURL
    }

    private nonisolated static func suffixDomain(
        for accessControlRule: AccessControlRule,
        publicSuffixListFileURL: URL
    ) throws -> String? {
        guard accessControlRule.matchType == .exactDomain || accessControlRule.matchType == .domainSuffix,
              let domain = AclService.normalizedDomain(accessControlRule.matchValue)
        else {
            return nil
        }

        return try PublicSuffixList.registrableDomain(for: domain, fileURL: publicSuffixListFileURL)
    }

    private nonisolated static func existingProxyPolicyRule(
        proxyPolicyID: UUID,
        ruleID: UUID,
        in modelContext: ModelContext
    ) throws -> ProxyPolicyRule? {
        let descriptor = FetchDescriptor<ProxyPolicyRule>(
            predicate: #Predicate<ProxyPolicyRule> { proxyPolicyRule in
                proxyPolicyRule.id == proxyPolicyID
            }
        )
        return try modelContext.fetch(descriptor).first { proxyPolicyRule in
            proxyPolicyRule.ruleID == ruleID
        }
    }

    private nonisolated static func sortPolicyRules(_ lhs: ProxyPolicyRule, _ rhs: ProxyPolicyRule) -> Bool {
        let leftKey = "\(lhs.proxyPolicy?.name ?? ""):\(lhs.id.uuidString):\(lhs.ruleID.uuidString)"
        let rightKey = "\(rhs.proxyPolicy?.name ?? ""):\(rhs.id.uuidString):\(rhs.ruleID.uuidString)"
        return leftKey.localizedStandardCompare(rightKey) == .orderedAscending
    }

    /// Public Suffix List 的内存索引，用于从 host 计算可注册 suffix domain。
    private struct PublicSuffixList {
        private let exactRules: Set<String>
        private let wildcardRules: Set<String>
        private let exceptionRules: Set<String>

        /// 从 PSL 文件计算 host 的可注册 suffix domain。
        static func registrableDomain(for domain: String, fileURL: URL) throws -> String? {
            let publicSuffixList = try PublicSuffixList(fileURL: fileURL)
            return publicSuffixList.registrableDomain(for: domain)
        }

        private init(fileURL: URL) throws {
            let data = try Data(contentsOf: fileURL)
            let text = String(decoding: data, as: UTF8.self)
            self.init(text: text)
        }

        private init(text: String) {
            var exactRules = Set<String>()
            var wildcardRules = Set<String>()
            var exceptionRules = Set<String>()

            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.isEmpty == false, line.hasPrefix("//") == false else { continue }

                if line.hasPrefix("!") {
                    guard let normalizedRule = AclService.normalizedDomain(String(line.dropFirst())) else { continue }
                    exceptionRules.insert(normalizedRule)
                } else if line.hasPrefix("*.") {
                    guard let wildcardSuffix = AclService.normalizedDomain(String(line.dropFirst(2))) else { continue }
                    wildcardRules.insert(wildcardSuffix)
                } else {
                    guard let normalizedRule = AclService.normalizedDomain(line) else { continue }
                    exactRules.insert(normalizedRule)
                }
            }

            self.exactRules = exactRules
            self.wildcardRules = wildcardRules
            self.exceptionRules = exceptionRules
        }

        private func registrableDomain(for domain: String) -> String? {
            guard let normalizedDomain = AclService.normalizedDomain(domain) else { return nil }
            let labels = normalizedDomain.split(separator: ".").map(String.init)
            guard labels.count > 1 else { return nil }

            let publicSuffixLabelCount: Int
            if let exceptionLabelCount = matchingExceptionRuleLabelCount(labels: labels) {
                publicSuffixLabelCount = max(exceptionLabelCount - 1, 1)
            } else {
                publicSuffixLabelCount = max(
                    longestExactRuleLabelCount(labels: labels) ?? 1,
                    longestWildcardRuleLabelCount(labels: labels) ?? 1
                )
            }

            let registrableLabelCount = publicSuffixLabelCount + 1
            guard labels.count >= registrableLabelCount else { return nil }
            return labels.suffix(registrableLabelCount).joined(separator: ".")
        }

        private func matchingExceptionRuleLabelCount(labels: [String]) -> Int? {
            for labelCount in stride(from: labels.count, through: 1, by: -1) {
                let candidate = labels.suffix(labelCount).joined(separator: ".")
                if exceptionRules.contains(candidate) {
                    return labelCount
                }
            }
            return nil
        }

        private func longestExactRuleLabelCount(labels: [String]) -> Int? {
            for labelCount in stride(from: labels.count, through: 1, by: -1) {
                let candidate = labels.suffix(labelCount).joined(separator: ".")
                if exactRules.contains(candidate) {
                    return labelCount
                }
            }
            return nil
        }

        private func longestWildcardRuleLabelCount(labels: [String]) -> Int? {
            guard labels.count >= 2 else { return nil }

            for labelCount in stride(from: labels.count, through: 2, by: -1) {
                let candidateSuffix = labels.suffix(labelCount - 1).joined(separator: ".")
                if wildcardRules.contains(candidateSuffix) {
                    return labelCount
                }
            }
            return nil
        }
    }

    // MARK: - Line Parsing

    private nonisolated static func parseRulesText(_ text: String) -> [AccessControlRuleImport] {
        var rules: [AccessControlRuleImport] = []
        var indexesByMatchValue: [String: Int] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let rule = parseRulesLine(String(rawLine), order: defaultImportedRuleOrder) else { continue }

            if let existingIndex = indexesByMatchValue[rule.matchValue] {
                if rule.decision == "direct" && rules[existingIndex].decision != "direct" {
                    rules[existingIndex] = rule
                }
                continue
            }

            indexesByMatchValue[rule.matchValue] = rules.count
            rules.append(rule)
        }

        return rules
    }

    private nonisolated static func parseRulesLine(_ rawLine: String, order: Int) -> AccessControlRuleImport? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.isEmpty == false else { return nil }
        guard line.hasPrefix("!") == false,
              line.hasPrefix("[") == false,
              line.hasPrefix("#") == false,
              line.contains("##") == false,
              line.contains("#@#") == false
        else {
            return nil
        }

        let decision: String
        if line.hasPrefix("@@") {
            decision = "direct"
            line.removeFirst(2)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            decision = "proxy"
        }

        if let optionIndex = line.firstIndex(of: "$") {
            line = String(line[..<optionIndex])
        }

        if let cidrRule = makeCIDRRule(line, decision: decision, order: order) {
            return cidrRule
        }

        if line.hasPrefix("||"),
           let domain = domainAfterDoublePipe(line) {
            return AccessControlRuleImport(
                matchType: .domainSuffix,
                matchValue: domain,
                decision: decision,
                order: order,
                source: source
            )
        }

        if line.hasPrefix("."),
           let domain = normalizedDomain(String(line.dropFirst())) {
            return AccessControlRuleImport(
                matchType: .domainSuffix,
                matchValue: domain,
                decision: decision,
                order: order,
                source: source
            )
        }

        if line.hasPrefix("/"),
           line.hasSuffix("/"),
           line.count > 2 {
            return AccessControlRuleImport(
                matchType: .urlRegex,
                matchValue: String(line.dropFirst().dropLast()),
                decision: decision,
                order: order,
                source: source
            )
        }

        if line.hasPrefix("|") || line.contains("*") || line.contains("^") || line.contains("://") {
            return AccessControlRuleImport(
                matchType: .urlRegex,
                matchValue: wildcardURLRegex(from: line),
                decision: decision,
                order: order,
                source: source
            )
        }

        if let domain = normalizedDomain(line), domain.contains(".") {
            return AccessControlRuleImport(
                matchType: .domainSuffix,
                matchValue: domain,
                decision: decision,
                order: order,
                source: source
            )
        }

        let keyword = line.lowercased()
        guard keyword.isEmpty == false else { return nil }
        return AccessControlRuleImport(
            matchType: .domainKeyword,
            matchValue: keyword,
            decision: decision,
            order: order,
            source: source
        )
    }

    // MARK: - Rule Helpers

    private nonisolated static func makeCIDRRule(
        _ value: String,
        decision: String,
        order: Int
    ) -> AccessControlRuleImport? {
        let parts = value.split(separator: "/")
        guard parts.count == 2,
              isIPv4Address(String(parts[0])),
              let prefixLength = Int(parts[1]),
              (0...32).contains(prefixLength)
        else {
            return nil
        }

        return AccessControlRuleImport(
            matchType: .ipCIDR,
            matchValue: value,
            decision: decision,
            order: order,
            source: source
        )
    }

    private nonisolated static func domainAfterDoublePipe(_ value: String) -> String? {
        let domainCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        let startIndex = value.index(value.startIndex, offsetBy: 2)
        var endIndex = startIndex

        while endIndex < value.endIndex {
            let character = value[endIndex]
            guard String(character).rangeOfCharacter(from: domainCharacters) != nil else {
                break
            }
            endIndex = value.index(after: endIndex)
        }

        guard endIndex > startIndex else { return nil }
        return normalizedDomain(String(value[startIndex..<endIndex]))
    }

    private nonisolated static func normalizedDomain(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        guard normalized.isEmpty == false,
              normalized.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil,
              normalized.contains("..") == false
        else {
            return nil
        }

        return normalized
    }

    private nonisolated static func isIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { UInt8($0) != nil }
    }

    private nonisolated static func wildcardURLRegex(from value: String) -> String {
        var pattern = ""

        for character in value {
            switch character {
            case "*":
                pattern += ".*"
            case "^":
                pattern += #"[^A-Za-z0-9_\-.%]"#
            case "|":
                pattern += "^"
            default:
                pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
        }

        return pattern
    }
}
