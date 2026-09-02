//
//  AdblockUtilTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Verifies GFWList and Adblock-style rule parsing independently from services.
//

import Magent
import Testing
@testable import MagentX

/// `AdblockUtil` 语法分支、规范化和去重行为的单元测试。
struct AdblockUtilTests {
    /// 验证常用 GFWList/Adblock 语法被转换为与业务对象无关的匹配结果。
    @Test func parsesSupportedRuleStyles() {
        let rules = AdblockUtil.parse(
            """
            ! comment
            [AutoProxy 0.2.9]
            ||Google.COM^
            @@||apple.com^$script
            .example.org
            10.0.0.0/8
            telegram
            /https?:\\/\\/.*\\.example\\.com/
            foo*bar
            """
        )

        #expect(rules == [
            AdblockUtil.Rule(matchType: .domainSuffix, matchValue: "google.com", isException: false),
            AdblockUtil.Rule(matchType: .domainSuffix, matchValue: "apple.com", isException: true),
            AdblockUtil.Rule(matchType: .domainSuffix, matchValue: "example.org", isException: false),
            AdblockUtil.Rule(matchType: .ipCIDR, matchValue: "10.0.0.0/8", isException: false),
            AdblockUtil.Rule(matchType: .domainKeyword, matchValue: "telegram", isException: false),
            AdblockUtil.Rule(
                matchType: .urlRegex,
                matchValue: #"https?:\/\/.*\.example\.com"#,
                isException: false
            ),
            AdblockUtil.Rule(matchType: .urlRegex, matchValue: "foo.*bar", isException: false)
        ])
    }

    /// 验证同值例外规则优先，且注释、元数据和无效空规则不进入结果。
    @Test func exceptionRuleOverridesDuplicateBlockingRule() {
        let rules = AdblockUtil.parse(
            """
            ||duplicate.com^
            @@||duplicate.com^
            ##element-rule
            #@#element-exception
            @@
            """
        )

        #expect(rules == [
            AdblockUtil.Rule(matchType: .domainSuffix, matchValue: "duplicate.com", isException: true)
        ])
    }

    /// 验证域名规范化会去除外层空白和点并拒绝无效 ASCII 域名。
    @Test func normalizesDomainValues() {
        #expect(AdblockUtil.normalizedDomain("  .Example.COM.  ") == "example.com")
        #expect(AdblockUtil.normalizedDomain("bad..example.com") == nil)
        #expect(AdblockUtil.normalizedDomain("例子.com") == nil)
    }
}
