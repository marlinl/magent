//
//  PACUtilTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Unit tests for PAC text generation.
//

import Magent
import Testing
@testable import MagentX

/// `PACUtil` 规则到 PAC 文本转换行为的单元测试。
struct PACUtilTests {
    /// 验证生成结果包含固定本地代理及各类规则对应的 PAC 字面量。
    @Test func makePACBodyReturnsRuleText() {
        let pacBody = PACUtil.makePACBody(rules: [
            MagentProxyRule(
                id: 1,
                matchType: .domainSuffix,
                matchValue: "example.com",
                decision: .proxy,
                order: 100,
                source: "user"
            ),
            MagentProxyRule(
                id: 2,
                matchType: .domainKeyword,
                matchValue: "telegram",
                decision: .direct,
                order: 100,
                source: "user"
            ),
            MagentProxyRule(
                id: 3,
                matchType: .ipCIDR,
                matchValue: "10.0.0.0/8",
                decision: .direct,
                order: 100,
                source: "user"
            ),
            MagentProxyRule(
                id: 4,
                matchType: .urlRegex,
                matchValue: #"https?:\/\/.*\.example\.com"#,
                decision: .proxy,
                order: 100,
                source: "user"
            )
        ])

        #expect(pacBody.contains(#"var proxy = "SOCKS5 127.0.0.1:1086; DIRECT";"#))
        #expect(pacBody.contains(#"{ type: "domainSuffix", value: "example.com", decision: "proxy" }"#))
        #expect(pacBody.contains(#"{ type: "domainKeyword", value: "telegram", decision: "direct" }"#))
        #expect(pacBody.contains(#"{ type: "ipCIDR", value: "10.0.0.0", mask: "255.0.0.0", decision: "direct" }"#))
        #expect(pacBody.contains(#"{ type: "urlRegex", value: "https?:\\/\\/.*\\.example\\.com", decision: "proxy" }"#))
    }
}
