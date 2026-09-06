import Foundation
import Magent

/// 代理规则页面的临时表单状态，避免取消新增或编辑时直接修改持久化规则。
struct ProxyRuleDraft: Identifiable {
    let id = UUID()
    let editingRule: MagentProxyRule?
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
