//
//  NodeController.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Coordinates proxy node business operations between SwiftData and node management views.
//

import Combine
import Darwin
import Foundation
import Magent
import SwiftData

/// 代理节点业务控制器，负责节点列表读取、增删改和当前选择维护。
@MainActor
final class NodeController: ObservableObject {
    @Published private(set) var nodes: [MagentNode] = []
    @Published private(set) var loadError: String?
    @Published private(set) var canLoadMore = false
    @Published var selectedNodeID: UUID?

    private let pageSize = 50
    private var fetchLimit = 50

    /// 重置分页状态并加载第一页代理节点。
    func loadFirstPage(from modelContext: ModelContext, preferredSelectedNodeID: UUID? = nil) {
        fetchLimit = pageSize
        load(from: modelContext, preferredSelectedNodeID: preferredSelectedNodeID)
    }

    /// 在还有更多记录时扩大读取上限并加载下一页代理节点。
    func loadNextPage(from modelContext: ModelContext) {
        guard canLoadMore else { return }
        fetchLimit += pageSize
        load(from: modelContext)
    }

    /// 在节点变更后重新加载列表，确保 SwiftUI 列表状态与 SwiftData 存储一致，
    /// 并保证当前选中的节点仍然有效。
    func load(from modelContext: ModelContext, preferredSelectedNodeID: UUID? = nil) {
        let descriptor = FetchDescriptor<MagentNode>()

        do {
            let fetchedNodes = try modelContext.fetch(descriptor)
            backfillMissingNodeMetadata(in: fetchedNodes, modelContext: modelContext)
            let sortedNodes = fetchedNodes.sorted(by: Self.sortNodes)
            let desiredID = preferredSelectedNodeID ?? selectedNodeID
            if let desiredID,
               let selectedIndex = sortedNodes.firstIndex(where: { $0.id == desiredID }) {
                fetchLimit = max(fetchLimit, selectedIndex + 1)
            }
            nodes = Array(sortedNodes.prefix(fetchLimit))
            canLoadMore = sortedNodes.count > nodes.count
            loadError = nil
            if let desiredID, nodes.contains(where: { $0.id == desiredID }) {
                selectedNodeID = desiredID
            } else {
                selectedNodeID = nodes.first?.id
            }
        } catch {
            nodes = []
            selectedNodeID = nil
            canLoadMore = false
            loadError = error.localizedDescription
        }
    }

    /// 创建并持久化一个新的代理节点，成功后刷新列表并选中新节点。
    @discardableResult
    func addNode(
        name: String,
        type: Magent.ProxyNodeType = .shadowsocks,
        address: String,
        port: Int,
        cipher: Magent.ProxyCipher = .chacha20IetfPoly1305,
        password: String,
        timeout: TimeInterval = 30,
        dnsPolicy: Magent.ProxyDNSPolicy = .remote,
        in modelContext: ModelContext
    ) -> Bool {
        let host = Self.normalizedHost(from: address)
        let node = MagentNode(
            name: name,
            region: Self.resolvedRegion(for: host),
            type: type,
            address: host,
            port: port,
            cipher: cipher,
            password: password,
            timeout: timeout,
            dnsPolicy: dnsPolicy
        )

        // 先校验再写入，避免非法节点进入 SwiftData。
        guard node.isValid else {
            loadError = node.validationErrors
                .compactMap(\.errorDescription)
                .joined(separator: "\n")
            return false
        }

        do {
            modelContext.insert(node)
            try modelContext.save()
            load(from: modelContext, preferredSelectedNodeID: node.id)
            selectedNodeID = node.id
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }

    /// 更新已有代理节点，校验或保存失败时回滚内存对象到原始值。
    @discardableResult
    func updateNode(
        _ node: MagentNode,
        name: String,
        type: Magent.ProxyNodeType,
        address: String,
        port: Int,
        cipher: Magent.ProxyCipher,
        password: String,
        timeout: TimeInterval,
        dnsPolicy: Magent.ProxyDNSPolicy,
        in modelContext: ModelContext
    ) -> Bool {
        let previousName = node.name
        let previousType = node.type
        let previousAddress = node.address
        let previousPort = node.port
        let previousRegion = node.region
        let previousCipher = node.cipher
        let previousPassword = node.password
        let previousTimeout = node.timeout
        let previousDNSPolicy = node.dnsPolicy

        let host = Self.normalizedHost(from: address)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        node.name = normalizedName.isEmpty ? host : normalizedName
        node.type = type
        node.address = host
        node.port = port
        node.region = Self.resolvedRegion(for: host)
        node.cipher = cipher
        node.password = password
        node.timeout = timeout
        node.dnsPolicy = dnsPolicy

        // SwiftData 模型是引用类型，赋值后会立即反映到对象上；
        // 因此校验或保存失败时需要手动回滚内存对象。
        guard node.isValid else {
            node.name = previousName
            node.type = previousType
            node.address = previousAddress
            node.port = previousPort
            node.region = previousRegion
            node.cipher = previousCipher
            node.password = previousPassword
            node.timeout = previousTimeout
            node.dnsPolicy = previousDNSPolicy
            loadError = node.validationErrors
                .compactMap(\.errorDescription)
                .joined(separator: "\n")
            return false
        }

        do {
            try modelContext.save()
            load(from: modelContext, preferredSelectedNodeID: node.id)
            selectedNodeID = node.id
            return true
        } catch {
            node.name = previousName
            node.type = previousType
            node.address = previousAddress
            node.port = previousPort
            node.region = previousRegion
            node.cipher = previousCipher
            node.password = previousPassword
            node.timeout = previousTimeout
            node.dnsPolicy = previousDNSPolicy
            loadError = error.localizedDescription
            return false
        }
    }

    /// 删除指定代理节点，并在必要时清空当前选中节点。
    func deleteNode(_ node: MagentNode, from modelContext: ModelContext) {
        let deletedID = node.id

        do {
            try deleteProxyPolicies(magentNodeID: deletedID, from: modelContext)
            modelContext.delete(node)
            try modelContext.save()
            if selectedNodeID == deletedID {
                selectedNodeID = nil
            }
            load(from: modelContext)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private static func sortNodes(_ lhs: MagentNode, _ rhs: MagentNode) -> Bool {
        let leftKey = "\(lhs.name):\(lhs.address):\(lhs.port)"
        let rightKey = "\(rhs.name):\(rhs.address):\(rhs.port)"
        return leftKey.localizedStandardCompare(rightKey) == .orderedAscending
    }

    private func backfillMissingNodeMetadata(in nodes: [MagentNode], modelContext: ModelContext) {
        var didUpdate = false
        for node in nodes where node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            node.name = node.address
            didUpdate = true
        }
        for node in nodes where node.region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            node.region = node.address
            didUpdate = true
        }

        if didUpdate {
            try? modelContext.save()
        }
    }

    private func deleteProxyPolicies(magentNodeID: UUID, from modelContext: ModelContext) throws {
        let targetMagentNodeID: UUID? = magentNodeID
        let descriptor = FetchDescriptor<ProxyPolicy>(
            predicate: #Predicate<ProxyPolicy> { policy in
                policy.magentNodeID == targetMagentNodeID
            }
        )
        for policy in try modelContext.fetch(descriptor) {
            modelContext.delete(policy)
        }
    }

    private static func normalizedHost(from address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolvedRegion(for host: String) -> String {
        guard host.isEmpty == false else { return host }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let firstResult = result else {
            return host
        }
        defer { freeaddrinfo(firstResult) }

        var addressBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            firstResult.pointee.ai_addr,
            firstResult.pointee.ai_addrlen,
            &addressBuffer,
            socklen_t(addressBuffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )

        guard status == 0 else { return host }
        return String(cString: addressBuffer)
    }
}
