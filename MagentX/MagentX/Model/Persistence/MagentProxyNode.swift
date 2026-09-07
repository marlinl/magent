//
//  MagentProxyNode.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Persisted proxy node model aligned with Magent.ProxyNode.
//

import Foundation
import Network
import SwiftData

/// MagentX 持久化的代理节点，对应 `magent_proxy_nodes` 的基础数据列。
@Model
final class MagentProxyNode {
    @Attribute(.unique)
    var id: UUID
    var name: String?
    var type: String
    var address: String
    var port: Int
    var cipher: String
    var password: String
    var timeout: TimeInterval
    var createdAt: Date
    var updatedAt: Date

    /// 创建一个可持久化的代理节点。
    ///
    /// - Parameters:
    ///   - id: 节点唯一业务主键，默认生成 UUIDv7。
    ///   - name: 可选的节点名称。
    ///   - type: 与 `magent_proxy_nodes.type` 对应的节点类型字符串。
    ///   - address: 代理服务器主机名或 IP 地址。
    ///   - port: 代理服务器端口。
    ///   - cipher: 与 `magent_proxy_nodes.cipher` 对应的加密方法字符串。
    ///   - password: 节点密码。
    ///   - timeout: 超时时间（秒）。
    ///   - createdAt: 创建时间。
    ///   - updatedAt: 最后更新时间。
    init(
        id: UUID = MagentProxyNode.makeUUIDVersion7(),
        name: String?,
        type: String,
        address: String,
        port: Int,
        cipher: String,
        password: String,
        timeout: TimeInterval,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.address = address
        self.port = port
        self.cipher = cipher
        self.password = password
        self.timeout = timeout
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 判断地址是否可以作为不含端口的代理服务器主机地址。
    static func isValidAddress(_ address: String) -> Bool {
        let normalizedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedAddress == address, normalizedAddress.isEmpty == false else {
            return false
        }

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

    /// 生成以 Unix 毫秒时间戳作为高 48 位的 RFC 9562 UUIDv7 节点 id。
    ///
    /// - Parameter date: 写入 UUIDv7 时间戳的时间，默认使用当前时间。
    /// - Returns: 版本位为 7、variant 位为 RFC 4122/9562 的时间有序 UUID。
    static func makeUUIDVersion7(at date: Date = .now) -> UUID {
        let millisecondsSince1970 = date.timeIntervalSince1970 * 1_000
        precondition(
            millisecondsSince1970.isFinite &&
                millisecondsSince1970 >= 0 &&
                millisecondsSince1970 <= Double(0xFFFF_FFFF_FFFF),
            "UUIDv7 timestamp must fit in 48 unsigned bits"
        )
        let milliseconds = UInt64(millisecondsSince1970)

        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = UInt8(truncatingIfNeeded: milliseconds >> 40)
        bytes[1] = UInt8(truncatingIfNeeded: milliseconds >> 32)
        bytes[2] = UInt8(truncatingIfNeeded: milliseconds >> 24)
        bytes[3] = UInt8(truncatingIfNeeded: milliseconds >> 16)
        bytes[4] = UInt8(truncatingIfNeeded: milliseconds >> 8)
        bytes[5] = UInt8(truncatingIfNeeded: milliseconds)

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
