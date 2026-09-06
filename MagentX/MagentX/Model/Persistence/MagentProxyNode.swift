//
//  MagentProxyNode.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Persisted proxy node model aligned with Magent.ProxyNode.
//

import Foundation
import Magent
import Network
import SwiftData

/// MagentX 持久化的代理节点，字段语义与 Magent 核心库的 `ProxyNode` 对齐。
///
/// 核心库使用 `SocketAddress` 同时表达主机和端口；SwiftData 模型将其拆分为
/// `address` 与 `port`。`type` 和 `cipher` 保持 Magent 枚举类型，并由
/// SwiftData 使用枚举的字符串原始值完成持久化和反序列化。
@Model
final class MagentProxyNode {
    @Attribute(.unique)
    var id: UUID
    var name: String?
    var type: ProxyNodeType
    var address: String
    var port: Int
    var cipher: ProxyCipher
    var password: String
    var timeout: TimeInterval
    var createdAt: Date
    var updatedAt: Date

    /// 创建一个可持久化的代理节点。
    ///
    /// - Parameters:
    ///   - id: 节点业务主键，默认生成按毫秒时间排序的 UUIDv7。
    ///   - name: 可选的节点名称。
    ///   - type: 节点类型，默认 Shadowsocks。
    ///   - address: 代理服务器主机名或 IP 地址。
    ///   - port: 代理服务器端口。
    ///   - cipher: 加密方法。
    ///   - password: 节点密码。
    ///   - timeout: 超时时间（秒）。
    ///   - createdAt: 创建时间。
    ///   - updatedAt: 最后更新时间。
    init(
        id: UUID = MagentProxyNode.makeUUIDVersion7(),
        name: String? = nil,
        type: ProxyNodeType = .shadowsocks,
        address: String,
        port: Int,
        cipher: ProxyCipher,
        password: String,
        timeout: TimeInterval = 30,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = Self.normalizedName(name)
        self.type = type
        self.address = Self.normalizedAddress(address)
        self.port = port
        self.cipher = cipher
        self.password = password
        self.timeout = timeout
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 节点列表使用的显示名称；未设置名称时回退到节点地址。
    var displayName: String {
        name ?? address
    }

    /// 当前节点字段违反的应用层校验规则。
    var validationErrors: [MagentXError] {
        Self.validationErrors(
            address: address,
            port: port,
            password: password,
            timeout: timeout
        )
    }

    /// 当前节点是否满足写入要求。
    var isValid: Bool {
        validationErrors.isEmpty
    }

    /// 更新代理节点的可编辑字段，并刷新最后更新时间。
    func update(
        name: String?,
        type: ProxyNodeType,
        address: String,
        port: Int,
        cipher: ProxyCipher,
        password: String,
        timeout: TimeInterval,
        updatedAt: Date = .now
    ) {
        self.name = Self.normalizedName(name)
        self.type = type
        self.address = Self.normalizedAddress(address)
        self.port = port
        self.cipher = cipher
        self.password = password
        self.timeout = timeout
        self.updatedAt = updatedAt
    }

    /// 校验准备写入节点表的必要连接字段。
    static func validationErrors(
        address: String,
        port: Int,
        password: String,
        timeout: TimeInterval
    ) -> [MagentXError] {
        var errors: [MagentXError] = []
        let normalizedAddress = normalizedAddress(address)
        if normalizedAddress.isEmpty {
            errors.append(.emptyAddress)
        } else if isValidAddress(normalizedAddress) == false {
            errors.append(.invalidAddress)
        }
        if (1...65535).contains(port) == false {
            errors.append(.invalidPort)
        }
        if password.isEmpty {
            errors.append(.emptyPassword)
        }
        if timeout <= 0 || Int(exactly: timeout) == nil {
            errors.append(.invalidTimeout)
        }
        return errors
    }

    private static func normalizedName(_ name: String?) -> String? {
        guard let name else { return nil }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedName.isEmpty ? nil : normalizedName
    }

    private static func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isValidAddress(_ address: String) -> Bool {
        if let ipv4Address = IPv4Address(address) {
            return String(describing: ipv4Address) == address
        }
        if IPv6Address(address) != nil {
            return true
        }
        if address.allSatisfy({ $0.isNumber || $0 == "." }) {
            return false
        }

        let hostname = address.last == "." ? address.dropLast() : address[...]
        guard hostname.isEmpty == false, hostname.utf8.count <= 253 else {
            return false
        }

        return hostname.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard (1...63).contains(label.utf8.count),
                  label.first != "-",
                  label.last != "-"
            else {
                return false
            }
            return label.utf8.allSatisfy { character in
                character == 45 ||
                    (48...57).contains(character) ||
                    (65...90).contains(character) ||
                    (97...122).contains(character)
            }
        }
    }

    private static func makeUUIDVersion7() -> UUID {
        let timestamp = UInt64(Date.now.timeIntervalSince1970 * 1_000)
        var bytes = [UInt8](repeating: 0, count: 16)

        bytes[0] = UInt8(truncatingIfNeeded: timestamp >> 40)
        bytes[1] = UInt8(truncatingIfNeeded: timestamp >> 32)
        bytes[2] = UInt8(truncatingIfNeeded: timestamp >> 24)
        bytes[3] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[4] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[5] = UInt8(truncatingIfNeeded: timestamp)

        for index in 6..<bytes.count {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
