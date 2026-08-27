//
//  NodeControllerTests.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Unit tests for proxy node creation and metadata normalization.
//

import Foundation
import SwiftData
import Testing
@testable import MagentX

/// `NodeController` 节点创建和元数据归一化流程的单元测试。
@MainActor
struct NodeControllerTests {
    /// 验证空节点名称会回填为 host，region 会记录解析后的实际地址。
    @Test func addNodeBackfillsEmptyNameWithHostAndResolvesRegion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let controller = NodeController()

        #expect(controller.addNode(
            name: " ",
            address: " 127.0.0.1 ",
            port: 8388,
            password: "password",
            in: context
        ))

        let nodes = try context.fetch(FetchDescriptor<MagentNode>())

        #expect(nodes.count == 1)
        #expect(nodes[0].name == "127.0.0.1")
        #expect(nodes[0].address == "127.0.0.1")
        #expect(nodes[0].region == "127.0.0.1")
    }

    /// 验证编辑节点时空名称继续回填 host，region 会跟随新 host 刷新。
    @Test func updateNodeBackfillsEmptyNameWithHostAndRefreshesRegion() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let controller = NodeController()
        let node = MagentNode(
            name: "Original",
            region: "old-region",
            address: "10.0.0.1",
            port: 8388,
            password: "password"
        )
        context.insert(node)
        try context.save()

        #expect(controller.updateNode(
            node,
            name: "",
            type: node.type,
            address: "127.0.0.1",
            port: node.port,
            cipher: node.cipher,
            password: node.password,
            timeout: node.timeout,
            dnsPolicy: node.dnsPolicy,
            in: context
        ))

        #expect(node.name == "127.0.0.1")
        #expect(node.address == "127.0.0.1")
        #expect(node.region == "127.0.0.1")
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ProxyPolicy.self,
            ProxyPolicyRule.self,
            AccessControlRule.self,
            MagentNode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
