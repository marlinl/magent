import Foundation
import NIOCore
import XCTest

@testable import Magent

/// MODELS_SPEC PR-01/02/04–09/13/16/18：构造、规范化存储、导入和整值身份。
/// 集合覆盖、匹配、优先级与默认决策通过 MagentCoreTests 的真实路由入口验证。
final class ProxyRuleTests: XCTestCase {
  func testMatchTypeRawValuesAndCodableRoundTrip() throws {
    let cases: [(MatchType, String)] = [
      (.exactDomain, "EXACT-DOMAIN"), (.domainSuffix, "DOMAIN-SUFFIX"),
      (.domainKeyword, "DOMAIN-KEYWORD"), (.ipCIDR, "IP-CIDR"),
    ]
    XCTAssertEqual(MatchType.allCases.count, 4)
    for (type, text) in cases {
      XCTAssertEqual(type.rawValue, text)
      XCTAssertEqual(MatchType(rawValue: text), type)
      XCTAssertEqual(String(decoding: try JSONEncoder().encode(type), as: UTF8.self), "\"\(text)\"")
      XCTAssertEqual(try JSONDecoder().decode(MatchType.self, from: Data("\"\(text)\"".utf8)), type)
    }
    for text in ["URL-REGEX", "REJECT", "exact-domain", " EXACT-DOMAIN", ""] {
      XCTAssertNil(MatchType(rawValue: text), text)
      XCTAssertThrowsError(try JSONDecoder().decode(MatchType.self, from: Data("\"\(text)\"".utf8)))
    }
  }

  func testDomainNormalizationAndStorage() throws {
    for type in [MatchType.exactDomain, .domainSuffix] {
      for text in ["EXAMPLE.COM", "Example.Com.", "example.com"] {
        let rule = try ProxyRule(matchType: type, matchValue: text, decision: .direct, order: -7)
        XCTAssertEqual(rule.matchType, type)
        XCTAssertEqual(rule.matchValue, "example.com")
        XCTAssertEqual(
          rule.match,
          type == .exactDomain ? .exactDomain("example.com") : .domainSuffix("example.com"))
        XCTAssertEqual(rule.decision, .direct)
        XCTAssertEqual(rule.order, -7)
      }
      XCTAssertEqual(
        try makeRule(type, "XN--BCHER-KVA.Example.").matchValue, "xn--bcher-kva.example")
      XCTAssertEqual(try makeRule(type, "0xfeed.Example").matchValue, "0xfeed.example")
    }
  }

  func testRejectsDomainRepairAndInvalidCharacters() {
    let invalid = [
      "", ".", " example.com", "example.com ", "\nexample.com", "example.com\t",
      ".example.com", "example.com..", "..example.com..", "a..b", "-a.example", "a-.example",
      "*.example.com", "https://example.com", "example.com:443", "a_b.example", "a/b", "a\\b",
      "a@b", "a%b", "a[b", "a]b", "a\u{0}b", "你好.example", "K.example",
    ]
    for type in [MatchType.exactDomain, .domainSuffix] {
      for text in invalid { assertInvalid(type, text) }
    }
  }

  func testDomainByteLengthBoundaries() throws {
    let longest = [63, 63, 63, 61].map { String(repeating: "a", count: $0) }.joined(separator: ".")
    XCTAssertEqual(longest.utf8.count, 253)
    for type in [MatchType.exactDomain, .domainSuffix] {
      XCTAssertEqual(try makeRule(type, "a").matchValue, "a")
      XCTAssertEqual(
        try makeRule(type, String(repeating: "a", count: 63)).matchValue.utf8.count, 63)
      XCTAssertEqual(try makeRule(type, longest).matchValue, longest)
      XCTAssertEqual(try makeRule(type, longest + ".").matchValue, longest)
      for text in [String(repeating: "a", count: 64), longest + "a", longest + "a."] {
        assertInvalid(type, text)
      }
    }
  }

  func testExactDomainRejectsNumericAddressesAndAmbiguousText() {
    for text in [
      "192.0.2.1", "192.0.2.1.", "127.1", "2130706433", "0177.0.0.1", "0x7f000001",
      "0X7F.0.0.1", "0x", "256.0.0.1", "0.1", "123", "::1", "::ffff:192.0.2.1",
    ] {
      assertInvalid(.exactDomain, text)
    }
    for text in ["192.0.2.1", "::1", "::ffff:192.0.2.1"] {
      XCTAssertThrowsError(try makeRule(.exactDomain, text)) { error in
        XCTAssertEqual(
          error as? MagentError, .invalidPolicy("numeric exact domain must use IP-CIDR: \(text)"))
      }
    }
  }

  func testSuffixAcceptsNumericLabels() throws {
    for text in ["0.1", "192.0.2.1", "123", "0xfeed"] {
      let rule = try makeRule(.domainSuffix, text)
      XCTAssertEqual(rule.match, .domainSuffix(text))
      XCTAssertEqual(rule.matchValue, text)
    }
  }

  func testKeywordUsesASCIIFragmentSyntax() throws {
    for (input, expected) in [
      ("API", "api"), ("Api.", "api."), ("-API-", "-api-"), ("..", ".."), (".", "."),
      ("0.1", "0.1"),
    ] {
      let rule = try makeRule(.domainKeyword, input)
      XCTAssertEqual(rule.match, .domainKeyword(expected))
      XCTAssertEqual(rule.matchType, .domainKeyword)
      XCTAssertEqual(rule.matchValue, expected)
    }
    let longest = String(repeating: "A", count: 253)
    XCTAssertEqual(
      try makeRule(.domainKeyword, longest).matchValue, String(repeating: "a", count: 253))
    assertInvalid(.domainKeyword, longest + "a")
  }

  func testRejectsInvalidKeywordWithoutTrimmingOrUnicodeFolding() {
    for text in [
      "", " api", "api ", "a b", "a\tb", "a\nb", "a\u{0}b", "K", "你好", "a/b", "a:b", "a?b", "a#b",
      "a@b", "a\\b", "a_b", "a*b", "a+b", "[api]", "^api$",
    ] {
      assertInvalid(.domainKeyword, text)
    }
  }

  func testIPv4NetworkStorageAndCanonicalText() throws {
    let cases: [(String, String, [UInt8], UInt8)] = [
      ("192.0.2.129/24", "192.0.2.0/24", [192, 0, 2, 0], 24),
      ("192.0.2.129", "192.0.2.129/32", [192, 0, 2, 129], 32),
      ("192.0.2.129/0", "0.0.0.0/0", [0, 0, 0, 0], 0),
      ("192.0.2.129/025", "192.0.2.128/25", [192, 0, 2, 128], 25),
      ("192.0.2.129/31", "192.0.2.128/31", [192, 0, 2, 128], 31),
      ("255.255.255.255/1", "128.0.0.0/1", [128, 0, 0, 0], 1),
      ("255.255.255.255/32", "255.255.255.255/32", [255, 255, 255, 255], 32),
    ]
    for (input, text, bytes, prefix) in cases {
      let rule = try makeRule(.ipCIDR, input)
      XCTAssertEqual(rule.matchType, .ipCIDR)
      XCTAssertEqual(rule.matchValue, text, input)
      XCTAssertEqual(rule.match, .ipCIDR(network: bytes, prefixLength: prefix), input)
    }
  }

  func testIPv6NetworkStorageAndCanonicalText() throws {
    let cases: [(String, String, [UInt8], UInt8)] = [
      (
        "2001:0DB8::1234/64", "2001:db8::/64",
        [32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 64
      ),
      (
        "2001:db8::1", "2001:db8::1/128", [32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1], 128
      ),
      ("2001:db8::1/0", "::/0", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 0),
      (
        "2001:db8:ffff:ffff:ffff:ffff:ffff:ffff/33", "2001:db8:8000::/33",
        [32, 1, 13, 184, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 33
      ),
      (
        "2001:db8::ffff/127", "2001:db8::fffe/127",
        [32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 254], 127
      ),
    ]
    for (input, text, bytes, prefix) in cases {
      let rule = try makeRule(.ipCIDR, input)
      XCTAssertEqual(rule.matchValue, text, input)
      XCTAssertEqual(rule.match, .ipCIDR(network: bytes, prefixLength: prefix), input)
    }
  }

  func testMappedIPv6UsesIPv4StorageAndAdjustedPrefix() throws {
    let cases: [(String, String, [UInt8], UInt8)] = [
      ("::ffff:192.0.2.129/96", "0.0.0.0/0", [0, 0, 0, 0], 0),
      ("::ffff:192.0.2.129/120", "192.0.2.0/24", [192, 0, 2, 0], 24),
      ("::ffff:192.0.2.129/128", "192.0.2.129/32", [192, 0, 2, 129], 32),
      ("::ffff:192.0.2.129", "192.0.2.129/32", [192, 0, 2, 129], 32),
      ("0:0:0:0:0:FFFF:C000:0281/121", "192.0.2.128/25", [192, 0, 2, 128], 25),
    ]
    for (input, text, bytes, prefix) in cases {
      let rule = try makeRule(.ipCIDR, input)
      XCTAssertEqual(rule.matchValue, text)
      XCTAssertEqual(rule.match, .ipCIDR(network: bytes, prefixLength: prefix))
    }
    for prefix in ["0", "64", "95", "129"] {
      assertInvalid(.ipCIDR, "::ffff:192.0.2.129/" + prefix)
    }
  }

  func testNativeIPv6RetainsFamilyEvenWhenRangeCoversMappedBytes() throws {
    for text in ["::/0", "::192.0.2.129/120", "64:ff9b::192.0.2.129/120"] {
      let rule = try makeRule(.ipCIDR, text)
      guard case .ipCIDR(let bytes, _) = rule.match else { return XCTFail("Expected CIDR") }
      XCTAssertEqual(bytes.count, 16)
    }
  }

  func testRejectsCIDRPrefixSyntaxAndOverflow() {
    for text in [
      "192.0.2.1/33", "::1/129", "192.0.2.1/-1", "192.0.2.1/+24", "::1/-0",
      "192.0.2.1/", "192.0.2.1/ 24", "192.0.2.1/24 ", "192.0.2.1/2 4",
      "192.0.2.1/24/1", "192.0.2.1//24", "192.0.2.1/24.0", "192.0.2.1/２４",
      "192.0.2.1/18446744073709551616", "::1/256", "::1/999999999999999999999999999999999",
    ] { assertInvalid(.ipCIDR, text) }
  }

  func testRejectsNonNumericMalformedAndScopedCIDR() {
    for text in [
      "", "/24", "example.invalid/24", "localhost", "192.0.2.1 ", " 192.0.2.1/24",
      "127.1", "2130706433", "0177.0.0.1", "0x7f000001", "256.0.0.1", "192.0.2.1.",
      "[::1]/128", "fe80::1%en0/64", "2001:::1", "::ffff:192.000.2.1/120",
      "::192.000.2.1", "192.0.2.1\u{0}/24", "::1\n", "https://192.0.2.1/24",
    ] { assertInvalid(.ipCIDR, text) }
  }

  func testCanonicalRoundTripIsIdempotent() throws {
    let cases: [(MatchType, String)] = [
      (.exactDomain, "EXAMPLE.COM."), (.domainSuffix, "0.1."), (.domainKeyword, "API."),
      (.ipCIDR, "192.0.2.129/024"), (.ipCIDR, "2001:db8::ffff/65"),
      (.ipCIDR, "::ffff:c000:281/120"),
    ]
    for (type, text) in cases {
      let rule = try makeRule(type, text)
      let imported = try makeRule(rule.matchType, rule.matchValue)
      XCTAssertEqual(imported, rule)
      XCTAssertEqual(imported.match, rule.match)
      XCTAssertEqual(imported.matchValue, rule.matchValue)
    }
  }

  func testEqualityAndHashingUseNormalizedMatchDecisionAndOrder() throws {
    let nodeID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    let otherID = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
    let rule = try makeRule(.exactDomain, "example.com")
    let variant = try makeRule(.exactDomain, "EXAMPLE.COM.")
    XCTAssertEqual(rule, variant)
    XCTAssertEqual(Set([rule, variant]).count, 1)
    let alternatives = try [
      ProxyRule(matchType: .domainSuffix, matchValue: "example.com", decision: .direct, order: 0),
      ProxyRule(matchType: .exactDomain, matchValue: "other.example", decision: .direct, order: 0),
      ProxyRule(matchType: .exactDomain, matchValue: "example.com", decision: .direct, order: 1),
      ProxyRule(
        matchType: .exactDomain, matchValue: "example.com", decision: .proxy(nodeID), order: 0),
      ProxyRule(
        matchType: .exactDomain, matchValue: "example.com", decision: .proxy(otherID), order: 0),
    ]
    for alternative in alternatives { XCTAssertNotEqual(rule, alternative) }
    XCTAssertEqual(Set([rule, variant] + alternatives).count, 6)
    XCTAssertEqual(alternatives[2].match, rule.match)
    XCTAssertEqual(alternatives[3].match, rule.match)
    let equivalentCIDRs = try ["192.0.2.129/24", "192.0.2.0/24", "::ffff:c000:281/120"].map {
      try makeRule(.ipCIDR, $0)
    }
    XCTAssertEqual(Set(equivalentCIDRs).count, 1)
    XCTAssertNotEqual(try makeRule(.ipCIDR, "192.0.2.0/24"), try makeRule(.ipCIDR, "192.0.2.0/25"))
  }

  func testDecisionsAndEntireOrderRangeNeedNoNodeLookupOrDNS() throws {
    let zeroID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    let otherID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    XCTAssertEqual(
      Set([Decision.direct, .proxy(zeroID), .proxy(otherID), .proxy(zeroID)]).count, 3)
    for order in [Int.min, -1, 0, 1, Int.max] {
      let rule = try ProxyRule(
        matchType: .exactDomain, matchValue: "does-not-exist.invalid", decision: .proxy(zeroID),
        order: order)
      XCTAssertEqual(rule.decision, .proxy(zeroID))
      XCTAssertEqual(rule.order, order)
      XCTAssertEqual(rule.matchValue, "does-not-exist.invalid")
    }
  }

  // MARK: - Helpers

  private func makeRule(_ type: MatchType, _ value: String) throws -> ProxyRule {
    try ProxyRule(matchType: type, matchValue: value, decision: .direct, order: 0)
  }

  private func assertInvalid(
    _ type: MatchType, _ text: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try makeRule(type, text), text, file: file, line: line) { error in
      guard case MagentError.invalidPolicy = error else {
        return XCTFail("Expected invalidPolicy for \(text), got \(error)", file: file, line: line)
      }
    }
  }
}
