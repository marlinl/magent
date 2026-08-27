//
//  ProxyRule.swift
//  Magent
//
//  Created by MarlinL on 2026/6/20.
//
import Foundation
import NIOCore

// MARK: - MatchType

/// 代理规则的匹配方式。
public enum MatchType: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    /// 完整域名精确匹配。
    case exactDomain

    /// 域名后缀匹配。
    case domainSuffix

    /// 域名关键字匹配。
    case domainKeyword

    /// IP CIDR 匹配。
    case ipCIDR

    /// URL 正则匹配。
    case urlRegex

}

// MARK: - Decision

/// 代理规则命中后的动作。
public enum Decision: Sendable, Equatable {
    /// 使用指定 UUID 的代理节点。
    case proxy(UUID)

    /// 直连目标地址。
    case direct
}

// MARK: - ProxyRule

/// 一条访问控制匹配规则。
public struct ProxyRule: Sendable {
    /// 匹配方式。
    public let matchType: MatchType

    /// 已根据 `matchType` 校验和规范化的匹配值。
    public let matchValue: String

    /// 规则命中后的动作。
    public let decision: Decision

    /// 规则顺序，数值越小优先级越高。
    public let order: Int

    /// 创建访问控制匹配规则。
    ///
    /// - Parameters:
    ///   - matchType: 匹配方式。
    ///   - matchValue: 原始匹配值；构造成功后会保存为规范化形式。
    ///   - decision: 规则命中后的动作。
    ///   - order: 规则顺序。
    /// - Throws: `MagentError.invalidPolicy`，表示匹配值不符合对应类型的格式要求。
    public init(
        matchType: MatchType,
        matchValue: String,
        decision: Decision,
        order: Int
    ) throws {
        let normalizedValue: String

        switch matchType {
        case .exactDomain, .domainSuffix:
            normalizedValue = try Self.normalizedDomain(matchValue)

        case .domainKeyword:
            normalizedValue = matchValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalizedValue.isEmpty == false else {
                throw MagentError.invalidPolicy("domain keyword must not be empty")
            }

        case .ipCIDR:
            normalizedValue = try Self.normalizedCIDR(matchValue)

        case .urlRegex:
            normalizedValue = matchValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedValue.isEmpty == false else {
                throw MagentError.invalidPolicy("URL regular expression must not be empty")
            }
            guard (try? NSRegularExpression(pattern: normalizedValue)) != nil else {
                throw MagentError.invalidPolicy("invalid URL regular expression: \(matchValue)")
            }
        }

        self.matchType = matchType
        self.matchValue = normalizedValue
        self.decision = decision
        self.order = order
    }

    /// 规范化 DNS 域名，并校验总长度、标签长度和允许字符。
    private static func normalizedDomain(_ value: String) throws -> String {
        let domain = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)

        guard domain.isEmpty == false, domain.utf8.count <= 253 else {
            throw MagentError.invalidPolicy("invalid domain: \(value)")
        }

        for label in labels {
            let bytes = label.utf8
            let hasValidLength = bytes.isEmpty == false && bytes.count <= 63
            let hasValidEdges = bytes.first != 45 && bytes.last != 45
            let hasValidCharacters = bytes.allSatisfy { byte in
                (48...57).contains(byte) || (97...122).contains(byte) || byte == 45
            }

            guard hasValidLength, hasValidEdges, hasValidCharacters else {
                throw MagentError.invalidPolicy("invalid domain: \(value)")
            }
        }

        return domain
    }

    /// 规范化 CIDR 文本，并清零网络前缀之外的主机位。
    private static func normalizedCIDR(_ value: String) throws -> String {
        let cidr = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)

        guard (1...2).contains(parts.count) else {
            throw MagentError.invalidPolicy("invalid CIDR: \(value)")
        }

        let ipLiteral = String(parts[0])
        guard ipLiteral.contains("%") == false,
              let socketAddress = try? SocketAddress(ipAddress: ipLiteral, port: 0) else {
            throw MagentError.invalidPolicy("invalid CIDR address: \(value)")
        }

        let addressBytes: Data
        switch socketAddress {
        case .v4(let ipv4):
            addressBytes = withUnsafeBytes(of: ipv4.address.sin_addr) { Data($0) }

        case .v6(let ipv6):
            addressBytes = withUnsafeBytes(of: ipv6.address.sin6_addr) { Data($0) }

        case .unixDomainSocket:
            throw MagentError.invalidPolicy("invalid CIDR address: \(value)")
        }

        let prefixLength: Int
        if parts.count == 2 {
            guard let prefix = Int(parts[1]), (0...(addressBytes.count * 8)).contains(prefix) else {
                throw MagentError.invalidPolicy("invalid CIDR prefix: \(value)")
            }
            prefixLength = prefix
        } else {
            prefixLength = addressBytes.count * 8
        }

        var networkBytes = addressBytes
        for index in networkBytes.indices {
            let byteStartBit = index * 8
            if byteStartBit + 8 <= prefixLength {
                continue
            }

            if byteStartBit >= prefixLength {
                networkBytes[index] = 0
                continue
            }

            let retainedBitCount = prefixLength - byteStartBit
            networkBytes[index] &= UInt8.max << UInt8(8 - retainedBitCount)
        }

        var buffer = ByteBufferAllocator().buffer(capacity: networkBytes.count)
        buffer.writeBytes(networkBytes)
        guard let networkAddress = try? SocketAddress(packedIPAddress: buffer, port: 0),
              let normalizedAddress = networkAddress.ipAddress else {
            throw MagentError.invalidPolicy("invalid CIDR address: \(value)")
        }

        return "\(normalizedAddress)/\(prefixLength)"
    }
}
