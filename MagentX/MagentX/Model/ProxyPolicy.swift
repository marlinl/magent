//
//  ProxyPolicy.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Persisted proxy policy group model.
//

import Foundation
import SwiftData

/// 代理策略组，保存组身份、展示名称、后缀域名以及可选的代理节点。
@Model
final class ProxyPolicy {
    @Attribute(.unique)
    var id: UUID
    var name: String
    var suffixDomain: String = ""
    var magentNodeID: UUID?
    var magentNode: MagentNode?
    @Relationship(deleteRule: .cascade, inverse: \ProxyPolicyRule.proxyPolicy)
    var proxyPolicyRules: [ProxyPolicyRule] = []

    /// 创建一个可持久化的代理策略组。
    init(
        id: UUID = UUID(),
        name: String,
        suffixDomain: String = "",
        magentNodeID: UUID? = nil,
        magentNode: MagentNode? = nil
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.suffixDomain = suffixDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        self.magentNodeID = magentNodeID
        self.magentNode = magentNode
    }
}
