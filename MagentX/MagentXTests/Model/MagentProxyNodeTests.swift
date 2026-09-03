//
//  MagentProxyNodeTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Verifies proxy-node normalization, validation, and paged SwiftData reads.
//

import Foundation
import Magent
import SwiftData
import Testing
@testable import MagentX

/// `MagentProxyNode` 字段归一化、校验与分页读取测试。
@MainActor
struct MagentProxyNodeTests {
    /// 验证可选名称和地址会按节点模型规则完成归一化。
    @Test func normalizesOptionalNameAndAddress() {
        let node = MagentProxyNode(
            name: "   ",
            address: " 127.0.0.1 ",
            port: 8388,
            cipher: .chacha20IetfPoly1305,
            password: "password"
        )

        #expect(node.name == nil)
        #expect(node.displayName == "127.0.0.1")
        #expect(node.address == "127.0.0.1")
        #expect(node.isValid)
    }

    /// 验证更新节点会刷新字段、更新时间和校验结果。
    @Test func updateRefreshesFieldsAndValidation() {
        let oldDate = Date(timeIntervalSince1970: 1)
        let newDate = Date(timeIntervalSince1970: 2)
        let node = MagentProxyNode(
            name: "Old",
            address: "127.0.0.1",
            port: 8388,
            cipher: .aes128Gcm,
            password: "password",
            updatedAt: oldDate
        )

        node.update(
            name: " New ",
            type: .shadowsocks,
            address: " 10.0.0.1 ",
            port: 0,
            cipher: .aes256Gcm,
            password: "",
            timeout: 0,
            updatedAt: newDate
        )

        #expect(node.name == "New")
        #expect(node.address == "10.0.0.1")
        #expect(node.updatedAt == newDate)
        #expect(node.validationErrors == [.invalidPort, .emptyPassword, .invalidTimeout])
    }

    /// 验证节点地址接受 DNS 主机名、IPv4 和 IPv6。
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
            let errors = MagentProxyNode.validationErrors(
                address: address,
                port: 8388,
                password: "password",
                timeout: 30
            )
            #expect(errors.isEmpty)
        }
    }

    /// 验证节点地址拒绝 URL、端口、非法主机名和非法 IP 表示。
    @Test func rejectsInvalidAddresses() {
        let invalidAddresses = [
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
            let errors = MagentProxyNode.validationErrors(
                address: address,
                port: 8388,
                password: "password",
                timeout: 30
            )
            #expect(errors == [.invalidAddress])
        }
    }

    /// 验证超时时间只能使用大于零且可由 `Int` 精确表示的秒数。
    @Test func requiresPositiveIntegerTimeout() {
        let invalidTimeouts = [
            TimeInterval.zero,
            -1,
            1.5,
            .infinity,
            .nan
        ]

        for timeout in invalidTimeouts {
            let errors = MagentProxyNode.validationErrors(
                address: "proxy.example.com",
                port: 8388,
                password: "password",
                timeout: timeout
            )
            #expect(errors == [.invalidTimeout])
        }

        #expect(MagentProxyNode.validationErrors(
            address: "proxy.example.com",
            port: 8388,
            password: "password",
            timeout: 30
        ).isEmpty)
    }

    /// 验证节点可按 UUIDv7 业务 id 倒序和 offset/limit 方式分批读取。
    @Test func fetchesNodesInPages() throws {
        let container = try ModelContainer(
            for: MagentProxyNode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        for index in 0..<55 {
            context.insert(MagentProxyNode(
                id: try #require(UUID(uuidString: String(
                    format: "018f0000-0000-7000-8000-%012llx",
                    UInt64(index)
                ))),
                name: "Node \(index)",
                address: "127.0.0.1",
                port: 8_000 + index,
                cipher: .chacha20IetfPoly1305,
                password: "password"
            ))
        }
        try context.save()

        var firstPageDescriptor = FetchDescriptor<MagentProxyNode>(
            sortBy: [SortDescriptor(\.id, order: .reverse)]
        )
        firstPageDescriptor.fetchLimit = 51
        let firstPageWithLookahead = try context.fetch(firstPageDescriptor)
        let firstPage = Array(firstPageWithLookahead.prefix(50))

        var secondPageDescriptor = firstPageDescriptor
        secondPageDescriptor.fetchOffset = 50
        let secondPageWithLookahead = try context.fetch(secondPageDescriptor)
        let secondPage = Array(secondPageWithLookahead.prefix(50))

        #expect(firstPageWithLookahead.count == 51)
        #expect(firstPage.count == 50)
        #expect(secondPage.count == 5)
        #expect(secondPageWithLookahead.count == secondPage.count)
        #expect(firstPage[0].name == "Node 54")
        #expect(secondPage[0].name == "Node 4")
    }
}
