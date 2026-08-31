//
//  MagentProxyRule.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Persisted proxy rule model aligned with Magent.ProxyRule.
//

import Foundation
import Magent
import SwiftData

/// MagentX 代理规则动作，以字符串形式持久化。
nonisolated enum RuleDecision: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// 使用代理转发。
    case proxy

    /// 直接连接。
    case direct
}

/// MagentX 持久化的代理规则，保存匹配规则、动作和创建更新时间。
@Model
final class MagentProxyRule {
    @Attribute(.unique)
    var id: Int
    var matchType: MatchType
    var matchValue: String
    var decision: RuleDecision
    var order: Int
    var source: String
    var createdAt: Date
    var updatedAt: Date

    /// 创建一条可持久化的代理规则。
    ///
    /// - Parameters:
    ///   - id: 规则的唯一整数业务主键。
    ///   - matchType: 匹配方式。
    ///   - matchValue: 匹配值。
    ///   - decision: 规则命中后的动作。
    ///   - order: 规则顺序，数值越小优先级越高。
    ///   - source: 规则来源。
    ///   - createdAt: 创建时间。
    ///   - updatedAt: 最后更新时间。
    init(
        id: Int,
        matchType: MatchType,
        matchValue: String,
        decision: RuleDecision,
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
}
