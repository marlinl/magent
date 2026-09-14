//
//  MagentProxyNodeTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Verifies proxy-node persistence, address validation, and UUIDv7 generation.
//

import Foundation
import Magent
import SwiftData
import Testing
@testable import MagentX

/// `MagentProxyNode` 字段持久化、地址校验与 UUIDv7 生成测试。
@MainActor
struct MagentProxyNodeTests {
    /// 验证节点的字符串枚举值和基础连接字段可以写入 SwiftData。
    @Test func persistsNodeFields() throws {
        let container = try ModelContainer(
            for: MagentProxyNode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let modelContext = ModelContext(container)
        let identifier = try #require(UUID(uuidString: "018f0000-0000-7000-8000-000000000001"))
        let createdAt = Date(timeIntervalSince1970: 1)
        let updatedAt = Date(timeIntervalSince1970: 2)
        let node = MagentProxyNode(
            id: identifier,
            name: "Example",
            type: ProxyNodeType.shadowsocks.rawValue,
            address: "127.0.0.1",
            port: 8388,
            cipher: ProxyCipher.chacha20IetfPoly1305.rawValue,
            password: "password",
            timeout: 30,
            createdAt: createdAt,
            updatedAt: updatedAt
        )

        modelContext.insert(node)
        try modelContext.save()

        let storedNode = try #require(modelContext.fetch(FetchDescriptor<MagentProxyNode>()).first)
        #expect(storedNode.id == identifier)
        #expect(storedNode.name == "Example")
        #expect(storedNode.type == ProxyNodeType.shadowsocks.rawValue)
        #expect(storedNode.address == "127.0.0.1")
        #expect(storedNode.port == 8388)
        #expect(storedNode.cipher == ProxyCipher.chacha20IetfPoly1305.rawValue)
        #expect(storedNode.password == "password")
        #expect(storedNode.timeout == 30)
        #expect(storedNode.createdAt == createdAt)
        #expect(storedNode.updatedAt == updatedAt)
    }

    /// 验证节点地址接受 DNS 主机名、规范 IPv4 和 IPv6。
    @Test func acceptsHostnameAndIPAddresses() {
        let validAddresses = [
            "localhost",
            "proxy.example.com",
            "proxy.example.com.",
            "127.0.0.1",
            "2001:db8::1",
            "fe80::1%en0"
        ]

        for address in validAddresses {
            #expect(MagentProxyNode.isValidAddress(address))
        }
    }

    /// 验证节点地址拒绝空白、URL、端口、非法主机名和非规范 IP 表示。
    @Test func rejectsInvalidAddresses() {
        let invalidAddresses = [
            "",
            " proxy.example.com",
            "https://proxy.example.com",
            "proxy.example.com:8388",
            "bad host",
            "bad_host.example.com",
            "-proxy.example.com",
            "proxy-.example.com",
            "proxy..example.com",
            "256.1.1.1",
            "127.1",
            "[2001:db8::1]",
            "2001:db8::g"
        ]

        for address in invalidAddresses {
            #expect(MagentProxyNode.isValidAddress(address) == false)
        }
    }

    /// 验证节点生成器写入 UUIDv7 版本位、标准 variant 位和给定毫秒时间戳。
    @Test func generatesUUIDVersion7WithTimestamp() {
        let date = Date(timeIntervalSince1970: 1_725_000_000.123)
        let identifier = MagentProxyNode.makeUUIDVersion7(at: date)
        let bytes = withUnsafeBytes(of: identifier.uuid) { Array($0) }
        let timestamp = bytes.prefix(6).reduce(UInt64.zero) { partialResult, byte in
            (partialResult << 8) | UInt64(byte)
        }

        #expect(bytes[6] >> 4 == 7)
        #expect(bytes[8] >> 6 == 2)
        #expect(timestamp == UInt64(date.timeIntervalSince1970 * 1_000))
    }

    /// 验证节点模型未显式传入 id 时默认生成 UUIDv7。
    @Test func defaultsToUUIDVersion7ID() {
        let node = MagentProxyNode(
            name: "Example",
            type: ProxyNodeType.shadowsocks.rawValue,
            address: "127.0.0.1",
            port: 8388,
            cipher: ProxyCipher.chacha20IetfPoly1305.rawValue,
            password: "password",
            timeout: 30,
            createdAt: .now,
            updatedAt: .now
        )
        let bytes = withUnsafeBytes(of: node.id.uuid) { Array($0) }

        #expect(bytes[6] >> 4 == 7)
        #expect(bytes[8] >> 6 == 2)
    }

    /// 验证不同毫秒生成的 UUIDv7 按字符串正序保持时间先后关系。
    @Test func uuidVersion7SortsByTimestamp() {
        let earlier = MagentProxyNode.makeUUIDVersion7(
            at: Date(timeIntervalSince1970: 1_725_000_000.123)
        )
        let later = MagentProxyNode.makeUUIDVersion7(
            at: Date(timeIntervalSince1970: 1_725_000_000.124)
        )

        #expect(earlier.uuidString < later.uuidString)
    }
}
