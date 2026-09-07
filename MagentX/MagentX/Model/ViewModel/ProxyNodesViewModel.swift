//
//  ProxyNodesViewModel.swift
//  MagentX
//
//  Created by MarlinL on 2026/9/7.
//

import Foundation
import Magent

/// 代理节点页面使用的完整节点值模型，承载持久化节点的全部业务字段。
struct ProxyNodesViewModel: Identifiable, Sendable {
    let id: UUID
    let name: String?
    let type: ProxyNodeType
    let address: String
    let port: Int
    let cipher: ProxyCipher
    let password: String
    let timeout: TimeInterval
    let createdAt: Date
    let updatedAt: Date

    /// 创建包含当前全部字段、尚未插入 `ModelContext` 的持久化代理节点。
    ///
    /// - Returns: 与当前值模型字段一致的新 `MagentProxyNode` 实例。
    func toMagentProxyNode() -> MagentProxyNode {
        MagentProxyNode(
            id: id,
            name: name,
            type: type.rawValue,
            address: address,
            port: port,
            cipher: cipher.rawValue,
            password: password,
            timeout: timeout,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
