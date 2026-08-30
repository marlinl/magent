//
//  AccessControlRule.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Persisted access-control rule model.
//

import Foundation
import Magent
import CryptoKit
import SwiftData

/// MagentX 持久化访问控制规则。
///
/// 字段参考 Magent 核心库的 `ProxyRule`，但 `decision` 只保存动作字符串；
/// 具体代理节点 id 在转换为 Magent 策略时由调用方提供。
@Model
final class AccessControlRule {
    @Attribute(.unique)
    var id: UUID
    var matchType: MatchType
    var matchValue: String
    var decision: String
    var order: Int
    var source: String
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \ProxyPolicyRule.accessControlRule)
    var proxyPolicyRules: [ProxyPolicyRule] = []

    /// 创建一条可持久化的访问控制规则。
    init(
        matchType: MatchType,
        matchValue: String,
        decision: String,
        order: Int = 0,
        source: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = Self.makeID(matchType: matchType, matchValue: matchValue)
        self.matchType = matchType
        self.matchValue = matchValue
        self.decision = decision
        self.order = order
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 更新规则匹配身份，并同步刷新由 `matchType + matchValue` 派生的稳定 id。
    func updateIdentity(matchType: MatchType, matchValue: String) {
        self.id = Self.makeID(matchType: matchType, matchValue: matchValue)
        self.matchType = matchType
        self.matchValue = matchValue
    }

    /// 根据匹配类型和匹配值生成稳定 UUID，保证相同规则身份得到相同 id。
    static func makeID(matchType: MatchType, matchValue: String) -> UUID {
        let identity = "\(matchType.rawValue):\(matchValue)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// 转换为 Magent 核心库使用的代理规则；无效规则返回 nil。
    func magentProxyRule(proxyNodeID: UUID) -> ProxyRule? {
        let value = matchValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { return nil }

        let magentDecision: Decision
        switch decision {
        case "direct":
            magentDecision = .direct
        case "proxy":
            magentDecision = .proxy(proxyNodeID)
        default:
            return nil
        }

        return try? ProxyRule(
            matchType: matchType,
            matchValue: value,
            decision: magentDecision,
            order: order
        )
    }

}
