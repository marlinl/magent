//
//  MagentNode.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Persisted Magent node configuration model.
//

import Foundation
import Magent
import SwiftData

/// MagentX 持久化节点配置。
///
/// `name` 和 `region` 是 MagentX 展示元数据，核心代理所需字段
/// 会通过 `proxyNode` 转换为 `Magent.ProxyNode`。
@Model
final class MagentNode {
    var id: UUID = UUID()
    var name: String = ""
    var region: String = ""
    var type: Magent.ProxyNodeType
    var address: String
    var port: Int
    var cipher: Magent.ProxyCipher
    var password: String
    var timeout: TimeInterval
    var dnsPolicy: Magent.ProxyDNSPolicy
    @Relationship(deleteRule: .cascade, inverse: \ProxyPolicy.magentNode)
    var proxyPolicies: [ProxyPolicy] = []

    /// 创建一个可持久化的 Magent 节点配置。
    init(
        id: UUID = UUID(),
        name: String = "",
        region: String = "",
        type: Magent.ProxyNodeType = .shadowsocks,
        address: String,
        port: Int,
        cipher: Magent.ProxyCipher = .chacha20IetfPoly1305,
        password: String,
        timeout: TimeInterval = 30,
        dnsPolicy: Magent.ProxyDNSPolicy = .remote
    ) {
        self.id = id
        let normalizedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRegion = region.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = normalizedName.isEmpty ? normalizedAddress : normalizedName
        self.region = normalizedRegion.isEmpty ? normalizedAddress : normalizedRegion
        self.type = type
        self.address = normalizedAddress
        self.port = port
        self.cipher = cipher
        self.password = password
        self.timeout = timeout
        self.dnsPolicy = dnsPolicy
    }

    var networkAddress: Magent.NetworkAddress? {
        Self.networkAddress(host: address, port: port)
    }

    var proxyNode: Magent.ProxyNode? {
        guard let networkAddress else { return nil }
        return Magent.ProxyNode(
            id: id,
            type: type,
            address: networkAddress,
            cipher: cipher,
            password: password,
            timeout: timeout,
            dnsPolicy: dnsPolicy
        )
    }

    var validationErrors: [MagentXError] {
        var errors: [MagentXError] = []
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.emptyAddress)
        }
        if (1...65535).contains(port) == false {
            errors.append(.invalidPort)
        }
        if password.isEmpty {
            errors.append(.emptyPassword)
        }
        if timeout <= 0 {
            errors.append(.invalidTimeout)
        }
        return errors
    }

    var isValid: Bool {
        validationErrors.isEmpty
    }

    /// 从 host/port 构造核心库使用的网络地址，非法输入返回 nil。
    static func networkAddress(host: String, port: Int) -> Magent.NetworkAddress? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedHost.isEmpty == false, (1...65535).contains(port) else {
            return nil
        }
        return .domain(trimmedHost, port: port)
    }

    /// 节点导入导出使用的编码键。
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case region
        case type
        case address
        case port
        case cipher
        case password
        case timeout
        case dnsPolicy
    }

    /// 从外部编码数据恢复节点配置。
    convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let address = try container.decode(String.self, forKey: .address)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? address,
            region: try container.decodeIfPresent(String.self, forKey: .region) ?? address,
            type: try container.decodeIfPresent(Magent.ProxyNodeType.self, forKey: .type) ?? .shadowsocks,
            address: address,
            port: try container.decode(Int.self, forKey: .port),
            cipher: try container.decode(Magent.ProxyCipher.self, forKey: .cipher),
            password: try container.decode(String.self, forKey: .password),
            timeout: try container.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? 30,
            dnsPolicy: try container.decodeIfPresent(Magent.ProxyDNSPolicy.self, forKey: .dnsPolicy) ?? .remote
        )
    }

    /// 将节点配置编码为可持久化或导出的结构。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(region, forKey: .region)
        try container.encode(type, forKey: .type)
        try container.encode(address, forKey: .address)
        try container.encode(port, forKey: .port)
        try container.encode(cipher, forKey: .cipher)
        try container.encode(password, forKey: .password)
        try container.encode(timeout, forKey: .timeout)
        try container.encode(dnsPolicy, forKey: .dnsPolicy)
    }
}

extension MagentNode: Codable {}
