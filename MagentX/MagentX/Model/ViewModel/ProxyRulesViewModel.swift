import Foundation
import Magent

/// 代理规则页面使用的完整规则值模型，承载持久化规则的全部业务字段。
struct ProxyRulesViewModel: Identifiable, Sendable {
    /// 代理规则页面可选的动作类型，用于编辑界面与规则值模型。
    nonisolated enum RuleDecision: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
        /// 使用代理转发。
        case proxy

        /// 直接连接。
        case direct
    }

    let id: Int
    let matchType: MatchType
    let matchValue: String
    let decision: RuleDecision
    let order: Int
    let source: String
    let createdAt: Date
    let updatedAt: Date

    /// 创建包含当前全部字段、尚未插入 `ModelContext` 的持久化代理规则。
    ///
    /// - Returns: 与当前值模型字段一致的新 `MagentProxyRule` 实例。
    func toMagentProxyRule() -> MagentProxyRule {
        MagentProxyRule(
            id: id,
            matchType: matchType.rawValue,
            matchValue: matchValue,
            decision: decision.rawValue,
            order: order,
            source: source,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
