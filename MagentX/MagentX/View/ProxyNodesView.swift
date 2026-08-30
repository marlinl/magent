//
//  ProxyNodesView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Provides the proxy node list, direct SwiftData pagination, and node CRUD UI.
//

import Magent
import SwiftData
import SwiftUI

/// 代理节点管理页面，直接通过 SwiftData 完成分页查询、选择和增删改。
struct ProxyNodesView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var toolbarButtons: [ContentToolbarButton]
    @State private var nodes: [MagentProxyNode] = []
    @State private var selectedNodeID: UUID?
    @State private var loadError: String?
    @State private var canLoadMore = true
    @State private var isLoading = false
    @State private var isAddingNode = false
    @State private var editingNodeID: UUID?

    private static let pageSize = 50

    private var editingNode: MagentProxyNode? {
        guard let editingNodeID else { return nil }
        return nodes.first { $0.id == editingNodeID }
    }

    var body: some View {
        nodeList
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                toolbarButtons = [
                    ContentToolbarButton(title: "添加代理节点", systemImage: "plus") {
                        isAddingNode = true
                    }
                ]
            }
            .task {
                loadFirstPage()
            }
            .sheet(isPresented: $isAddingNode) {
                NodeFormSheet { nodeID in
                    loadFirstPage(preferredSelectedNodeID: nodeID)
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { editingNodeID != nil },
                    set: { isPresented in
                        if isPresented == false {
                            editingNodeID = nil
                        }
                    }
                )
            ) {
                if let editingNode {
                    NodeFormSheet(node: editingNode) { nodeID in
                        editingNodeID = nil
                        loadFirstPage(preferredSelectedNodeID: nodeID)
                    }
                }
            }
    }

    @ViewBuilder
    private var nodeList: some View {
        if let loadError {
            ContentUnavailableView(
                "节点读取失败",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else if nodes.isEmpty {
            ContentUnavailableView(
                "暂无代理节点",
                systemImage: "server.rack",
                description: Text("添加代理节点后会显示在这里")
            )
        } else {
            List(selection: $selectedNodeID) {
                ForEach(nodes, id: \.id) { node in
                    NodeListRow(
                        node: node,
                        onEdit: {
                            editingNodeID = node.id
                        },
                        onDelete: {
                            deleteNode(node)
                        }
                    )
                    .tag(node.id)
                    .onAppear {
                        loadMoreNodesIfNeeded(currentNode: node)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func loadFirstPage(preferredSelectedNodeID: UUID? = nil) {
        nodes = []
        canLoadMore = true
        loadNextPage(preferredSelectedNodeID: preferredSelectedNodeID)
    }

    private func loadNextPage(preferredSelectedNodeID: UUID? = nil) {
        guard canLoadMore, isLoading == false else { return }

        isLoading = true
        defer { isLoading = false }

        var descriptor = FetchDescriptor<MagentProxyNode>(
            sortBy: [
                SortDescriptor(\.updatedAt, order: .reverse),
                SortDescriptor(\.createdAt, order: .reverse),
                SortDescriptor(\.address)
            ]
        )
        descriptor.fetchOffset = nodes.count
        descriptor.fetchLimit = Self.pageSize + 1

        do {
            let fetchedNodes = try modelContext.fetch(descriptor)
            nodes.append(contentsOf: fetchedNodes.prefix(Self.pageSize))
            canLoadMore = fetchedNodes.count > Self.pageSize
            loadError = nil

            let desiredNodeID = preferredSelectedNodeID ?? selectedNodeID
            if let desiredNodeID, nodes.contains(where: { $0.id == desiredNodeID }) {
                selectedNodeID = desiredNodeID
            } else if selectedNodeID == nil || nodes.contains(where: { $0.id == selectedNodeID }) == false {
                selectedNodeID = nodes.first?.id
            }
        } catch {
            canLoadMore = false
            loadError = error.localizedDescription
        }
    }

    private func loadMoreNodesIfNeeded(currentNode node: MagentProxyNode) {
        guard node.id == nodes.last?.id else { return }
        loadNextPage()
    }

    private func deleteNode(_ node: MagentProxyNode) {
        let targetNodeID: UUID? = node.id
        let policyDescriptor = FetchDescriptor<ProxyPolicy>(
            predicate: #Predicate<ProxyPolicy> { policy in
                policy.magentNodeID == targetNodeID
            }
        )

        do {
            guard try modelContext.fetchCount(policyDescriptor) == 0 else {
                loadError = MagentXError.proxyNodeInUse(node.id).localizedDescription
                return
            }

            modelContext.delete(node)
            try modelContext.save()
            if selectedNodeID == node.id {
                selectedNodeID = nil
            }
            loadFirstPage()
        } catch {
            modelContext.rollback()
            loadError = error.localizedDescription
        }
    }
}

/// 节点新增和编辑表单 sheet，直接将 `MagentProxyNode` 写入 SwiftData。
private struct NodeFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    private let node: MagentProxyNode?
    private let onSave: (UUID) -> Void
    @State private var name: String
    @State private var type: ProxyNodeType
    @State private var address: String
    @State private var port: Int
    @State private var cipher: ProxyCipher
    @State private var password: String
    @State private var timeout: Int
    @State private var saveError: String?

    private static let portRange = 1...65535
    private static let portFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: portRange.lowerBound)
        formatter.maximum = NSNumber(value: portRange.upperBound)
        return formatter
    }()
    private static let timeoutFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 1
        return formatter
    }()

    /// 创建节点新增或编辑表单，并用已有节点填充默认值。
    init(node: MagentProxyNode? = nil, onSave: @escaping (UUID) -> Void) {
        self.node = node
        self.onSave = onSave
        _name = State(initialValue: node?.name ?? "")
        _type = State(initialValue: node?.type ?? .shadowsocks)
        _address = State(initialValue: node?.address ?? "")
        _port = State(initialValue: node?.port ?? 8388)
        _cipher = State(initialValue: node?.cipher ?? .chacha20IetfPoly1305)
        _password = State(initialValue: node?.password ?? "")
        _timeout = State(initialValue: node.map { max(1, Int($0.timeout.rounded())) } ?? 30)
    }

    private var title: LocalizedStringKey {
        LocalizedStringKey(node == nil ? "添加节点" : "修改节点")
    }

    private var actionTitle: LocalizedStringKey {
        LocalizedStringKey(node == nil ? "添加" : "保存")
    }

    private var canSave: Bool {
        MagentProxyNode.validationErrors(
            address: address,
            port: port,
            password: password,
            timeout: TimeInterval(timeout)
        ).isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("名称（可选）", text: $name)

                Picker("类型", selection: $type) {
                    ForEach(ProxyNodeType.allCases, id: \.rawValue) { type in
                        Text(type.rawValue)
                            .tag(type)
                    }
                }
                .pickerStyle(.menu)

                TextField("地址", text: $address)
                TextField("端口", value: $port, formatter: Self.portFormatter)

                Picker("加密", selection: $cipher) {
                    ForEach(ProxyCipher.allCases, id: \.rawValue) { cipher in
                        Text(cipher.rawValue)
                            .tag(cipher)
                    }
                }
                .pickerStyle(.menu)

                SecureField("密码", text: $password)
                TextField("超时", value: $timeout, formatter: Self.timeoutFormatter)
            } header: {
                Text(title)
                    .font(.title3.weight(.semibold))
            }

            if let saveError {
                Section {
                    Text(saveError)
                        .foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    Spacer()

                    Button("取消") {
                        dismiss()
                    }

                    Button {
                        saveNode()
                    } label: {
                        Text(actionTitle)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(canSave == false)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 360)
        .onChange(of: port) { _, newValue in
            port = min(max(newValue, Self.portRange.lowerBound), Self.portRange.upperBound)
        }
        .onChange(of: timeout) { _, newValue in
            timeout = max(1, newValue)
        }
    }

    private func saveNode() {
        guard canSave else { return }

        let savedNode: MagentProxyNode
        if let node {
            node.update(
                name: name,
                type: type,
                address: address,
                port: port,
                cipher: cipher,
                password: password,
                timeout: TimeInterval(timeout)
            )
            savedNode = node
        } else {
            let newNode = MagentProxyNode(
                name: name,
                type: type,
                address: address,
                port: port,
                cipher: cipher,
                password: password,
                timeout: TimeInterval(timeout)
            )
            modelContext.insert(newNode)
            savedNode = newNode
        }

        do {
            try modelContext.save()
            onSave(savedNode.id)
            dismiss()
        } catch {
            modelContext.rollback()
            saveError = error.localizedDescription
        }
    }
}

/// 节点列表中的单行展示和操作按钮。
private struct NodeListRow: View {
    let node: MagentProxyNode
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var endpoint: String {
        "\(node.address):\(node.port)"
    }

    private var metadata: String {
        "\(endpoint) - \(node.type.rawValue)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("修改节点")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("删除节点")
        }
        .padding(.vertical, 4)
    }
}
