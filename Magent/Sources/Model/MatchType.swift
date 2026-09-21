//
//  MatchType.swift
//  Magent
//
//  Created by MarlinL on 2026/6/20.
//

/// 代理规则的匹配方式。
public enum MatchType: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
  /// 完整域名精确匹配。
  case exactDomain = "EXACT-DOMAIN"

  /// 域名后缀匹配。
  case domainSuffix = "DOMAIN-SUFFIX"

  /// 域名关键字匹配。
  case domainKeyword = "DOMAIN-KEYWORD"

  /// IP CIDR 匹配。
  case ipCIDR = "IP-CIDR"

  /// URL 正则匹配。
  case urlRegex = "URL-REGEX"
}
