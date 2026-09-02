//
//  AdblockUtil.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Parses GFWList and Adblock-style rules without application persistence concerns.
//

import Foundation
import Magent

/// GFWList/Adblock 规则解析工具，负责把文本语法转换为与业务持久化无关的匹配结果。
enum AdblockUtil {
    /// 一条已解析的 GFWList/Adblock 规则。
    struct Rule: Equatable, Sendable {
        let matchType: MatchType
        let matchValue: String
        let isException: Bool
    }

    /// 解析 GFWList/Adblock 文本，过滤注释和元数据，并使例外规则覆盖同值的普通规则。
    nonisolated static func parse(_ text: String) -> [Rule] {
        var rules: [Rule] = []
        var indexesByMatchValue: [String: Int] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let rule = parseLine(String(rawLine)) else { continue }

            if let existingIndex = indexesByMatchValue[rule.matchValue] {
                if rule.isException && rules[existingIndex].isException == false {
                    rules[existingIndex] = rule
                }
                continue
            }

            indexesByMatchValue[rule.matchValue] = rules.count
            rules.append(rule)
        }

        return rules
    }

    /// 规范化规则或 PSL 中的 ASCII 域名；无效域名返回 `nil`。
    nonisolated static func normalizedDomain(_ value: String) -> String? {
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

    private nonisolated static func parseLine(_ rawLine: String) -> Rule? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.isEmpty == false,
              line.hasPrefix("!") == false,
              line.hasPrefix("[") == false,
              line.hasPrefix("#") == false,
              line.contains("##") == false,
              line.contains("#@#") == false
        else {
            return nil
        }

        let isException = line.hasPrefix("@@")
        if isException {
            line.removeFirst(2)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let optionIndex = line.firstIndex(of: "$") {
            line = String(line[..<optionIndex])
        }

        if let cidrRule = makeCIDRRule(line, isException: isException) {
            return cidrRule
        }

        if line.hasPrefix("||"),
           let domain = domainAfterDoublePipe(line) {
            return Rule(matchType: .domainSuffix, matchValue: domain, isException: isException)
        }

        if line.hasPrefix("."),
           let domain = normalizedDomain(String(line.dropFirst())) {
            return Rule(matchType: .domainSuffix, matchValue: domain, isException: isException)
        }

        if line.hasPrefix("/"),
           line.hasSuffix("/"),
           line.count > 2 {
            return Rule(
                matchType: .urlRegex,
                matchValue: String(line.dropFirst().dropLast()),
                isException: isException
            )
        }

        if line.hasPrefix("|") || line.contains("*") || line.contains("^") || line.contains("://") {
            return Rule(
                matchType: .urlRegex,
                matchValue: wildcardURLRegex(from: line),
                isException: isException
            )
        }

        if let domain = normalizedDomain(line), domain.contains(".") {
            return Rule(matchType: .domainSuffix, matchValue: domain, isException: isException)
        }

        let keyword = line.lowercased()
        guard keyword.isEmpty == false else { return nil }
        return Rule(matchType: .domainKeyword, matchValue: keyword, isException: isException)
    }

    private nonisolated static func makeCIDRRule(_ value: String, isException: Bool) -> Rule? {
        let parts = value.split(separator: "/")
        guard parts.count == 2,
              isIPv4Address(String(parts[0])),
              let prefixLength = Int(parts[1]),
              (0...32).contains(prefixLength)
        else {
            return nil
        }

        return Rule(matchType: .ipCIDR, matchValue: value, isException: isException)
    }

    private nonisolated static func domainAfterDoublePipe(_ value: String) -> String? {
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

    private nonisolated static func isIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
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
