//
//  ProxyRuleDraft.swift
//  MagentX
//
//  Responsibility: Stores uncommitted proxy-rule form values.
//

import Foundation
import Magent

/// 代理规则新增或编辑期间使用的表单草稿，避免取消操作影响持久化实体。
struct ProxyRuleDraft: Identifiable {
    let id = UUID()
    let editingRuleID: Int?
    var matchType: MatchType
    var matchValuesText: String
    var decision: RuleDecision

    /// 把批量输入中的非空行转换为待新增的匹配值。
    var matchValues: [String] {
        matchValuesText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }
}
