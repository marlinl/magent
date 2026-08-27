//
//  ProxyPolicyRule.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Persisted join model between proxy policy groups and access-control rules.
//

import Foundation
import SwiftData

/// 代理策略组和访问控制规则的关联记录。
///
/// `id` 保存 `ProxyPolicy.id`，`ruleID` 保存 `AccessControlRule.id`，
/// 二者共同表达一条规则属于哪个代理策略组。
@Model
final class ProxyPolicyRule {
    #Unique<ProxyPolicyRule>([\.id, \.ruleID])

    var id: UUID
    var ruleID: UUID
    var proxyPolicy: ProxyPolicy?
    var accessControlRule: AccessControlRule?

    /// 创建策略组和访问规则之间的关联记录。
    init(
        id: UUID,
        ruleID: UUID,
        proxyPolicy: ProxyPolicy? = nil,
        accessControlRule: AccessControlRule? = nil
    ) {
        self.id = id
        self.ruleID = ruleID
        self.proxyPolicy = proxyPolicy
        self.accessControlRule = accessControlRule
    }

    /// 创建带 SwiftData 关系引用的策略规则关联记录。
    convenience init(proxyPolicy: ProxyPolicy, accessControlRule: AccessControlRule) {
        self.init(
            id: proxyPolicy.id,
            ruleID: accessControlRule.id,
            proxyPolicy: proxyPolicy,
            accessControlRule: accessControlRule
        )
    }
}
