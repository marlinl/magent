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

    /// 验证节点可按页面使用的排序和 offset/limit 方式分批读取。
    @Test func fetchesNodesInPages() throws {
        let container = try ModelContainer(
            for: MagentProxyNode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let baseDate = Date(timeIntervalSince1970: 1_000)

        for index in 0..<55 {
            let date = baseDate.addingTimeInterval(TimeInterval(index))
            context.insert(MagentProxyNode(
                name: "Node \(index)",
                address: "127.0.0.1",
                port: 8_000 + index,
                cipher: .chacha20IetfPoly1305,
                password: "password",
                createdAt: date,
                updatedAt: date
            ))
        }
        try context.save()

        var firstPageDescriptor = FetchDescriptor<MagentProxyNode>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        firstPageDescriptor.fetchLimit = 51
        let firstPage = try context.fetch(firstPageDescriptor)

        var secondPageDescriptor = firstPageDescriptor
        secondPageDescriptor.fetchOffset = 50
        let secondPage = try context.fetch(secondPageDescriptor)

        #expect(firstPage.count == 51)
        #expect(secondPage.count == 5)
        #expect(firstPage[0].name == "Node 54")
        #expect(secondPage[0].name == "Node 4")
    }
}
