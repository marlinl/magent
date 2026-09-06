//
//  ProxyRulesPagingResult.swift
//  MagentX
//
//  Created by MarlinL on 2026/9/6.
//

import SwiftData

/// 代理规则分页查询结果，承载规则持久化标识、当前页信息与下一页可用性。
struct ProxyRulesPagingResult: Sendable {
    let persistentIdentifiers: [PersistentIdentifier]
    let pageAt: Int
    let pageSize: Int
    let canLoadMore: Bool
}
