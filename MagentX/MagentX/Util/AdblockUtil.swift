import Foundation
import Magent

/// 一条保留 Adblock 原始语义的规则数据，供存储、展示或后续匹配引擎使用。
struct AdblockRule: Hashable, Sendable {
    /// 规则的语义类别。
    enum Kind: Hashable, Sendable {
        /// 作用于网络请求。
        case network

        /// 作用于页面元素。
        case cosmetic(CosmeticKind)
    }

    /// Cosmetic 规则分隔符的语义。
    enum CosmeticKind: String, Hashable, Sendable {
        /// 隐藏元素。
        case hide = "##"

        /// 允许元素。
        case allow = "#@#"

        /// 扩展 selector。
        case extended = "#?#"

        /// 样式规则。
        case style = "#$#"

        /// Scriptlet 规则。
        case scriptlet = "#%#"
    }

    /// Cosmetic 规则的域名条件。
    struct Domain: Hashable, Sendable {
        /// 不带排除前缀的域名文本。
        let value: String

        /// 是否排除该域名。
        let excluded: Bool
    }

    /// Network 规则的未解释选项。
    struct Option: Hashable, Sendable {
        /// 已小写化的名称。
        let name: String

        /// 等号后的可选值。
        let value: String?

        /// 是否否定该选项。
        let negated: Bool
    }

    /// 规范化后的原始规则。
    let raw: String

    /// 规则类别。
    let kind: Kind

    /// 是否为例外规则。
    let isException: Bool

    /// Cosmetic 域名条件；network 的 domain 选项保持在 options。
    let domains: [Domain]

    /// Network pattern 或 cosmetic selector。
    let pattern: String

    /// Network 选项；cosmetic 规则为空。
    let options: [Option]
}

/// 无状态 Adblock 文本解析器，只负责将行语法转换为结构化 DTO。
enum AdblockRuleParser {
    /// 解析多行规则，忽略空行、注释和元数据行。
    ///
    /// - Parameter text: 含有 Adblock 规则的文本。
    /// - Returns: 按输入顺序返回的规则，不执行去重或匹配转换。
    nonisolated static func parse(_ text: String) -> [AdblockRule] {
        var result: [AdblockRule] = []
        text.enumerateLines { line, _ in
            guard let rule = parseLine(line) else { return }
            result.append(rule)
        }

        return result
    }

    /// 规范化并解析单行文本。
    ///
    /// - Parameter source: 未规范化的单行文本。
    /// - Returns: 结构化规则；非规则行返回 nil。
    private nonisolated static func parseLine(_ source: String) -> AdblockRule? {
        var line = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.first == "\u{FEFF}" {
            line.removeFirst()
        }

        guard !line.isEmpty,
              !line.hasPrefix("!"),
              !(line.hasPrefix("[") && line.hasSuffix("]"))
        else {
            return nil
        }

        return parseCosmetic(line) ?? parseNetwork(line)
    }

    /// 解析 cosmetic 的域名和 selector。
    ///
    /// - Parameter line: 已过滤的规则行。
    /// - Returns: Cosmetic 规则；不包含有效分隔符时返回 nil。
    private nonisolated static func parseCosmetic(_ line: String) -> AdblockRule? {
        guard let separator = cosmeticSeparator(in: line) else {
            return nil
        }

        let selector = String(line[separator.range.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty else {
            return nil
        }

        return .init(
            raw: line,
            kind: .cosmetic(separator.kind),
            isException: separator.kind == .allow,
            domains: domains(String(line[..<separator.range.lowerBound])),
            pattern: selector,
            options: []
        )
    }

    /// 找到最先出现的 cosmetic 分隔符。
    ///
    /// - Parameter line: 已规范化规则行。
    /// - Returns: 分隔符范围及类别；未找到时返回 nil。
    private nonisolated static func cosmeticSeparator(
        in line: String
    ) -> (range: Range<String.Index>, kind: AdblockRule.CosmeticKind)? {
        let tokens: [(String, AdblockRule.CosmeticKind)] = [
            ("#@#", .allow),
            ("#?#", .extended),
            ("#$#", .style),
            ("#%#", .scriptlet),
            ("##", .hide)
        ]
        var found: (range: Range<String.Index>, kind: AdblockRule.CosmeticKind)?

        for (token, kind) in tokens {
            guard let range = line.range(of: token) else { continue }
            if found == nil || range.lowerBound < found!.range.lowerBound {
                found = (range, kind)
            }
        }

        return found
    }

    /// 拆分 cosmetic 域名条件并保留排除标记。
    ///
    /// - Parameter text: 分隔符前的逗号分隔文本。
    /// - Returns: 忽略空项的域名条件。
    private nonisolated static func domains(_ text: String) -> [AdblockRule.Domain] {
        text.split(separator: ",").compactMap {
            var value = $0.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }

            let excluded = value.hasPrefix("~")
            if excluded {
                value.removeFirst()
            }

            return value.isEmpty ? nil : .init(value: value, excluded: excluded)
        }
    }

    /// 解析 network 模式、例外和选项。
    ///
    /// - Parameter line: 不含 cosmetic 分隔符的规则行。
    /// - Returns: Network DTO；没有模式时返回 nil。
    private nonisolated static func parseNetwork(_ line: String) -> AdblockRule? {
        let exception = line.hasPrefix("@@")
        let body = exception ? String(line.dropFirst(2)) : line
        guard !body.isEmpty else {
            return nil
        }

        let parts = splitNetwork(body)
        guard !parts.pattern.isEmpty else {
            return nil
        }

        return .init(
            raw: line,
            kind: .network,
            isException: exception,
            domains: [],
            pattern: parts.pattern,
            options: options(parts.options)
        )
    }

    /// 分离 network 模式与选项，避免误切 regex 内的美元符。
    ///
    /// - Parameter body: 删除例外前缀后的规则。
    /// - Returns: 模式与可选选项。
    private nonisolated static func splitNetwork(
        _ body: String
    ) -> (pattern: String, options: String?) {
        if body.hasPrefix("/"),
           let close = body.lastIndex(of: "/"),
           close != body.startIndex {
            let after = body.index(after: close)
            guard after < body.endIndex, body[after] == "$" else {
                return (body, nil)
            }

            return (String(body[...close]), String(body[body.index(after: after)...]))
        }

        guard let dollar = body.firstIndex(of: "$") else {
            return (body, nil)
        }

        return (String(body[..<dollar]), String(body[body.index(after: dollar)...]))
    }

    /// 拆分 network 选项，不解释选项含义。
    ///
    /// - Parameter text: 美元符后的逗号分隔文本。
    /// - Returns: 非空结构化选项。
    private nonisolated static func options(_ text: String?) -> [AdblockRule.Option] {
        guard let text, !text.isEmpty else {
            return []
        }

        return text.split(separator: ",").compactMap {
            var option = $0.trimmingCharacters(in: .whitespaces)
            guard !option.isEmpty else { return nil }

            let negated = option.hasPrefix("~")
            if negated {
                option.removeFirst()
            }

            let parts = option.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard let name = parts.first, !name.isEmpty else { return nil }

            let value = parts.count == 2 && !parts[1].isEmpty
                ? String(parts[1])
                : nil
            return .init(
                name: name.lowercased(),
                value: value,
                negated: negated
            )
        }
    }
}

/// GFWList PAC 导入兼容工具，只投影现有 PAC 可表达的 network 规则。
enum AdblockUtil {
    /// 旧 PAC 导入结果，与现有持久化字段兼容。
    struct Rule: Equatable, Sendable {
        /// PAC 匹配方式。
        let matchType: MatchType

        /// 匹配值。
        let matchValue: String

        /// 是否直连。
        let isException: Bool
    }
    /// 将可表达的 network DTO 投影为旧 PAC 结果。
    ///
    /// - Parameter text: GFWList 或 Adblock 文本。
    /// - Returns: 例外覆盖同值普通规则的 PAC 导入结果。
    nonisolated static func parsePACRules(_ text: String) -> [Rule] {
        var result: [Rule] = []
        var indices: [String: Int] = [:]

        for parsed in AdblockRuleParser.parse(text) {
            guard let rule = pacRule(parsed) else { continue }

            if let index = indices[rule.matchValue] {
                if rule.isException && !result[index].isException {
                    result[index] = rule
                }
            } else {
                indices[rule.matchValue] = result.count
                result.append(rule)
            }
        }

        return result
    }

    /// 规范化 PAC 可识别的 ASCII 域名。
    ///
    /// - Parameter value: 原始域名。
    /// - Returns: 小写域名；无效时返回 nil。
    nonisolated static func normalizedDomain(_ value: String) -> String? {
        let value = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: .init(charactersIn: "."))
        guard !value.isEmpty,
              !value.contains(".."),
              value.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil
        else {
            return nil
        }

        return value
    }

    /// 将单条 DTO 投影为旧 PAC 匹配模型。
    ///
    /// - Parameter rule: 结构化规则。
    /// - Returns: PAC 规则；cosmetic 规则返回 nil。
    private nonisolated static func pacRule(_ rule: AdblockRule) -> Rule? {
        guard case .network = rule.kind else {
            return nil
        }

        let value = rule.pattern
        if let cidr = cidr(value, rule.isException) {
            return cidr
        }
        if value.hasPrefix("||"), let domain = doublePipeDomain(value) {
            return .init(
                matchType: .domainSuffix,
                matchValue: domain,
                isException: rule.isException
            )
        }
        if value.hasPrefix("."), let domain = normalizedDomain(String(value.dropFirst())) {
            return .init(
                matchType: .domainSuffix,
                matchValue: domain,
                isException: rule.isException
            )
        }
        if value.hasPrefix("/"), value.hasSuffix("/"), value.count > 2 {
            return .init(
                matchType: .urlRegex,
                matchValue: String(value.dropFirst().dropLast()),
                isException: rule.isException
            )
        }
        if value.hasPrefix("|") || value.contains("*") || value.contains("^") || value.contains("://") {
            return .init(
                matchType: .urlRegex,
                matchValue: regex(value),
                isException: rule.isException
            )
        }
        if let domain = normalizedDomain(value), domain.contains(".") {
            return .init(
                matchType: .domainSuffix,
                matchValue: domain,
                isException: rule.isException
            )
        }
        guard !value.isEmpty else {
            return nil
        }

        return .init(
            matchType: .domainKeyword,
            matchValue: value.lowercased(),
            isException: rule.isException
        )
    }

    /// 识别 IPv4 CIDR。
    ///
    /// - Parameters:
    ///   - value: 模式文本。
    ///   - exception: 例外标记。
    /// - Returns: CIDR PAC 规则；无效时返回 nil。
    private nonisolated static func cidr(
        _ value: String,
        _ exception: Bool
    ) -> Rule? {
        let parts = value.split(separator: "/")
        guard parts.count == 2,
              ipv4(String(parts[0])),
              let length = Int(parts[1]),
              (0...32).contains(length)
        else {
            return nil
        }

        return .init(matchType: .ipCIDR, matchValue: value, isException: exception)
    }

    /// 提取双竖线模式中的域名。
    ///
    /// - Parameter value: 双竖线模式。
    /// - Returns: 规范化域名；无效时返回 nil。
    private nonisolated static func doublePipeDomain(_ value: String) -> String? {
        let characters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-"
        )
        let start = value.index(value.startIndex, offsetBy: 2)
        var end = start

        while end < value.endIndex,
              String(value[end]).rangeOfCharacter(from: characters) != nil {
            end = value.index(after: end)
        }

        guard end > start else {
            return nil
        }

        return normalizedDomain(String(value[start..<end]))
    }

    /// 验证 IPv4 地址。
    ///
    /// - Parameter value: 地址文本。
    /// - Returns: 每段都可转为 UInt8 时为 true。
    private nonisolated static func ipv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// 将有限通配规则转换为 PAC 正则表达式。
    ///
    /// - Parameter value: Adblock 模式。
    /// - Returns: 正则表达式文本。
    private nonisolated static func regex(_ value: String) -> String {
        value.reduce(into: "") { result, character in
            switch character {
            case "*":
                result += ".*"
            case "^":
                result += #"[^A-Za-z0-9_\-.%]"#
            case "|":
                result += "^"
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
    }
}
