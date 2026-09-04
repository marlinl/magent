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
    /// 验证生成结果包含固定本地代理和按顺序排列的规则。
    @Test func makePACBodyReturnsRuleText() {
        let pacBody = PACUtil.makePACBody(rules: [
            MagentProxyRule(
                id: 1,
                matchType: .domainSuffix,
                matchValue: "example.com",
                decision: .proxy,
                order: 10,
                source: "user"
            )
        ])

        #expect(pacBody.contains(#"var proxy = "SOCKS5 127.0.0.1:1086; DIRECT";"#))
        #expect(pacBody.contains(#"{ type: "domainSuffix", value: "example.com", decision: "proxy" }"#))
    }
}
