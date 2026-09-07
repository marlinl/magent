//
//  MagentProxyRule.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Persisted proxy rule model aligned with Magent.ProxyRule.
//

import Foundation
import SwiftData

/// MagentX 持久化的代理规则，对应 `magent_proxy_rules` 的基础数据列和业务唯一键。
@Model
final class MagentProxyRule {
    #Unique<MagentProxyRule>([\.matchType, \.matchValue])

    @Attribute(.unique)
    var id: Int
    var matchType: String
    var matchValue: String
    var decision: String
    var order: Int
    var source: String
    var createdAt: Date
    var updatedAt: Date

    /// 创建一条可持久化的代理规则。
    ///
    /// - Parameters:
    ///   - id: 规则的唯一整数业务主键。
    ///   - matchType: 与 `magent_proxy_rules.match_type` 对应的匹配方式字符串。
    ///   - matchValue: 匹配值。
    ///   - decision: 与 `magent_proxy_rules.decision` 对应的规则动作字符串。
    ///   - order: 规则顺序，数值越小优先级越高。
    ///   - source: 规则来源。
    ///   - createdAt: 创建时间。
    ///   - updatedAt: 最后更新时间。
    init(
        id: Int,
        matchType: String,
        matchValue: String,
        decision: String,
        order: Int,
        source: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.matchType = matchType
        self.matchValue = matchValue
        self.decision = decision
        self.order = order
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 返回当前规则相对于已有规则的首个持久化校验错误。
    ///
    /// - Parameter rules: 同一 SwiftData 容器内用于检查业务唯一键的规则。
    /// - Returns: 匹配值为空或业务唯一键重复时返回对应错误，否则返回 `nil`。
    func validationError(in rules: [MagentProxyRule]) -> MagentXError? {
        guard matchValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .emptyProxyRuleMatchValue
        }

        let isDuplicate = rules.contains { storedRule in
            storedRule.id != id &&
                storedRule.matchType == matchType &&
                storedRule.matchValue == matchValue
        }
        return isDuplicate ? .duplicateMagentProxyRule : nil
    }

}
