//
//  MagentProxyRuleTests.swift
//  MagentXTests
//
//  Responsibility: Verifies proxy-rule business identity validation in SwiftData.
//

import Magent
import Testing

@testable import MagentX

/// `MagentProxyRule` 的复合业务唯一键校验测试。
@MainActor
struct MagentProxyRuleTests {
  /// 验证相同匹配类型与匹配值会被识别为重复规则。
  @Test func validationRejectsDuplicateBusinessIdentity() {
    let storedRule = MagentProxyRule(
      id: 1,
      matchType: MatchType.domainSuffix.rawValue,
      matchValue: "example.com",
      decision: "proxy",
      order: 100,
      source: "user"
    )
    let candidate = MagentProxyRule(
      id: 2,
      matchType: MatchType.domainSuffix.rawValue,
      matchValue: "example.com",
      decision: "direct",
      order: 0,
      source: "user"
    )

    #expect(candidate.validationError(in: [storedRule, candidate]) == .duplicateMagentProxyRule)
  }

  /// 验证相同匹配值使用不同匹配类型时仍可作为不同规则保存。
  @Test func validationAllowsSameValueForDifferentMatchTypes() {
    let storedRule = MagentProxyRule(
      id: 1,
      matchType: MatchType.domainSuffix.rawValue,
      matchValue: "example.com",
      decision: "proxy",
      order: 100,
      source: "user"
    )
    let candidate = MagentProxyRule(
      id: 2,
      matchType: MatchType.exactDomain.rawValue,
      matchValue: "example.com",
      decision: "proxy",
      order: 100,
      source: "user"
    )

    #expect(candidate.validationError(in: [storedRule, candidate]) == nil)
  }
}
