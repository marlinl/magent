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

    /// 启动规则订阅同步并返回可等待的任务；任务完成值是生成 PAC 所需的规则快照。
    ///
    /// 网络等待、Base64 解码、规则解析和 SwiftData 合并都在服务执行器上完成，调用方可等待
    /// `Task.value`，并在恢复到主执行器后更新界面。
    func syncRuleFromUrl() -> Task<[PacFileService.Rule], Error> {
        Task(priority: .userInitiated) {
            let settings = GeneralSettings.load()
            let rulesURLValue = settings.rulesURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard rulesURLValue.isEmpty == false else {
                throw MagentXError.missingRulesURL
            }
            guard let rulesURL = URL(string: rulesURLValue), rulesURL.scheme != nil else {
                throw MagentXError.invalidRulesURL(rulesURLValue)
            }

            let encodedData: Data
            if rulesURL.isFileURL {
                encodedData = try Data(contentsOf: rulesURL)
            } else {
                let (data, response) = try await URLSession.shared.data(from: rulesURL)
                if let httpResponse = response as? HTTPURLResponse,
                   (200..<300).contains(httpResponse.statusCode) == false {
                    throw URLError(.badServerResponse)
                }
                encodedData = data
            }

            try Task.checkCancellation()
            guard let decodedData = Data(base64Encoded: encodedData, options: [.ignoreUnknownCharacters]) else {
                throw MagentXError.invalidAclBase64Data
            }
            guard let decodedText = String(data: decodedData, encoding: .utf8) else {
                throw MagentXError.invalidAclDecodedText
            }

            let downloadedRules = parseGFWRule(text: decodedText)
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

                if let existingRule = rulesByIdentity[identity] {
                    guard existingRule.source == Self.source else { continue }
                    existingRule.matchType = downloadedRule.matchType
                    existingRule.matchValue = downloadedRule.matchValue
                    existingRule.decision = downloadedRule.decision
                    existingRule.order = downloadedRule.order
                    existingRule.source = downloadedRule.source
                    existingRule.updatedAt = now
                    continue
                }

                while usedIDs.contains(nextIDCandidate) {
                    nextIDCandidate += 1
                }
                downloadedRule.id = nextIDCandidate
                downloadedRule.createdAt = now
                downloadedRule.updatedAt = now
                usedIDs.insert(nextIDCandidate)
                nextIDCandidate += 1
                modelContext.insert(downloadedRule)
                rulesByIdentity[identity] = downloadedRule
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

    private func parseGFWRule(text: String) -> [MagentProxyRule] {
        let normalizedDomain: (String) -> String? = { value in
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
        let isIPv4Address: (String) -> Bool = { value in
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
        }
        let wildcardURLRegex: (String) -> String = { value in
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
        let domainAfterDoublePipe: (String) -> String? = { value in
            let domainCharacters = CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-"
            )
            let startIndex = value.index(value.startIndex, offsetBy: 2)
            var endIndex = startIndex
            while endIndex < value.endIndex {
                let character = value[endIndex]
                guard String(character).rangeOfCharacter(from: domainCharacters) != nil else { break }
                endIndex = value.index(after: endIndex)
            }
            guard endIndex > startIndex else { return nil }
            return normalizedDomain(String(value[startIndex..<endIndex]))
        }

        let now = Date.now
        var rules: [MagentProxyRule] = []
        var indexesByMatchValue: [String: Int] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false,
                  line.hasPrefix("!") == false,
                  line.hasPrefix("[") == false,
                  line.hasPrefix("#") == false,
                  line.contains("##") == false,
                  line.contains("#@#") == false
            else {
                continue
            }

            let decision: RuleDecision
            if line.hasPrefix("@@") {
                decision = .direct
                line.removeFirst(2)
                line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                decision = .proxy
            }

            if let optionIndex = line.firstIndex(of: "$") {
                line = String(line[..<optionIndex])
            }

            let matchType: MatchType
            let matchValue: String
            let cidrParts = line.split(separator: "/")
            if cidrParts.count == 2,
               isIPv4Address(String(cidrParts[0])),
               let prefixLength = Int(cidrParts[1]),
               (0...32).contains(prefixLength) {
                matchType = .ipCIDR
                matchValue = line
            } else if line.hasPrefix("||"),
                      let domain = domainAfterDoublePipe(line) {
                matchType = .domainSuffix
                matchValue = domain
            } else if line.hasPrefix("."),
                      let domain = normalizedDomain(String(line.dropFirst())) {
                matchType = .domainSuffix
                matchValue = domain
            } else if line.hasPrefix("/"),
                      line.hasSuffix("/"),
                      line.count > 2 {
                matchType = .urlRegex
                matchValue = String(line.dropFirst().dropLast())
            } else if line.hasPrefix("|") || line.contains("*") || line.contains("^") || line.contains("://") {
                matchType = .urlRegex
                matchValue = wildcardURLRegex(line)
            } else if let domain = normalizedDomain(line), domain.contains(".") {
                matchType = .domainSuffix
                matchValue = domain
            } else {
                let keyword = line.lowercased()
                guard keyword.isEmpty == false else { continue }
                matchType = .domainKeyword
                matchValue = keyword
            }

            let rule = MagentProxyRule(
                id: rules.count,
                matchType: matchType,
                matchValue: matchValue,
                decision: decision,
                order: Self.importedRuleOrder,
                source: Self.source,
                createdAt: now,
                updatedAt: now
            )
            if let existingIndex = indexesByMatchValue[matchValue] {
                if decision == .direct && rules[existingIndex].decision != .direct {
                    rule.id = rules[existingIndex].id
                    rules[existingIndex] = rule
                }
                continue
            }

            indexesByMatchValue[matchValue] = rules.count
            rules.append(rule)
        }
        return rules
    }
}
