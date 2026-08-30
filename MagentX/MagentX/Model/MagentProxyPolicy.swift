//
//  MagentProxyPolicy.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Persisted proxy policy and policy-rule association models.
//

import Foundation
import SwiftData

/// 代理策略记录，通过唯一的节点 UUID 关联一个代理节点。
@Model
final class MagentProxyPolicy {
    @Attribute(.unique)
    var id: Int
    var name: String
    @Attribute(.unique)
    var nodeID: UUID
    var createdAt: Date
    var updatedAt: Date

    /// 创建代理策略关联记录。
    ///
    /// - Parameters:
    ///   - id: 策略的唯一整数业务主键。
    ///   - name: 策略名称。
    ///   - nodeID: 关联代理节点的 UUID；一个节点只能属于一个策略。
    ///   - createdAt: 创建时间。
    ///   - updatedAt: 最后更新时间。
    init(
        id: Int,
        name: String,
        nodeID: UUID,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.nodeID = nodeID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// 代理策略与规则的关联记录，一个规则只能对应一条关联记录。
@Model
final class MagentProxyPolicyRule {
    #Unique<MagentProxyPolicyRule>([\.policyID, \.ruleID])

    var policyID: Int
    @Attribute(.unique)
    var ruleID: Int
    var createdAt: Date
    var updatedAt: Date

    /// 创建策略和规则之间的关联记录。
    ///
    /// - Parameters:
    ///   - policyID: 关联策略的整数业务主键。
    ///   - ruleID: 关联规则的整数业务主键；该字段全局唯一。
    ///   - createdAt: 创建时间。
    ///   - updatedAt: 最后更新时间。
    init(
        policyID: Int,
        ruleID: Int,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.policyID = policyID
        self.ruleID = ruleID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
