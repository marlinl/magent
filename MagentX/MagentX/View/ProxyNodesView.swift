//
//  ProxyNodesView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Provides the proxy node list, add/edit sheets, and node CRUD UI.
//

import Magent
import SwiftUI
import SwiftData

/// 代理节点管理页面，负责节点列表、选择持久化和新增/编辑入口。
struct ProxyNodesView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var controller = NodeController()
    @State private var isAddingNode = false
    @State private var editingNodeID: UUID?
    @Binding var toolbarButtons: [ContentToolbarButton]

    private var editingNode: MagentNode? {
        guard let editingNodeID else { return nil }
        return controller.nodes.first { $0.id == editingNodeID }
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
                controller.loadFirstPage(from: modelContext)
            }
            .sheet(isPresented: $isAddingNode) {
                NodeFormSheet(controller: controller)
                    .environment(\.modelContext, modelContext)
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
                    NodeFormSheet(controller: controller, node: editingNode)
                        .environment(\.modelContext, modelContext)
                }
            }
    }

    @ViewBuilder
    private var nodeList: some View {
        if let loadError = controller.loadError {
            ContentUnavailableView(
                "节点读取失败",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else if controller.nodes.isEmpty {
            ContentUnavailableView(
                "暂无代理节点",
                systemImage: "server.rack",
                description: Text("添加 MagentNode 后会显示在这里")
            )
        } else {
            List(selection: $controller.selectedNodeID) {
                ForEach(controller.nodes, id: \.id) { node in
                    NodeListRow(
                        node: node,
                        onEdit: {
                            editingNodeID = node.id
                        },
                        onDelete: {
                            controller.deleteNode(node, from: modelContext)
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

    private func loadMoreNodesIfNeeded(currentNode node: MagentNode) {
        guard node.id == controller.nodes.last?.id else { return }
        controller.loadNextPage(from: modelContext)
    }
}

/// 节点新增和编辑表单 sheet。
private struct NodeFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var controller: NodeController
    private let node: MagentNode?
    @State private var name: String
    @State private var type: Magent.ProxyNodeType
    @State private var address: String
    @State private var port: Int
    @State private var cipher: Magent.ProxyCipher
    @State private var password: String
    @State private var timeout: Int
    @State private var dnsPolicy: Magent.ProxyDNSPolicy
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
    init(controller: NodeController, node: MagentNode? = nil) {
        self.controller = controller
        self.node = node
        _name = State(initialValue: node?.name ?? "")
        _type = State(initialValue: node?.type ?? .shadowsocks)
        _address = State(initialValue: node?.address ?? "")
        _port = State(initialValue: node?.port ?? 8388)
        _cipher = State(initialValue: node?.cipher ?? .chacha20IetfPoly1305)
        _password = State(initialValue: node?.password ?? "")
        _timeout = State(initialValue: node.map { max(1, Int($0.timeout.rounded())) } ?? 30)
        _dnsPolicy = State(initialValue: node?.dnsPolicy ?? .remote)
    }

    private var title: LocalizedStringKey {
        LocalizedStringKey(node == nil ? "添加节点" : "修改节点")
    }

    private var actionTitle: LocalizedStringKey {
        LocalizedStringKey(node == nil ? "添加" : "保存")
    }

    private var canAdd: Bool {
        address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && password.isEmpty == false
            && Self.portRange.contains(port)
            && timeout > 0
    }

    var body: some View {
        Form {
            Section {
                TextField("名称（可选）", text: $name)

                Picker("类型", selection: $type) {
                    ForEach(Magent.ProxyNodeType.allCases, id: \.rawValue) { type in
                        Text(type.rawValue)
                            .tag(type)
                    }
                }
                .pickerStyle(.menu)

                TextField("地址", text: $address)
                TextField("端口", value: $port, formatter: Self.portFormatter)

                Picker("加密", selection: $cipher) {
                    ForEach(Magent.ProxyCipher.allCases, id: \.rawValue) { cipher in
                        Text(cipher.rawValue)
                            .tag(cipher)
                    }
                }
                .pickerStyle(.menu)

                SecureField("密码", text: $password)
                TextField("超时", value: $timeout, formatter: Self.timeoutFormatter)

                Picker("DNS", selection: $dnsPolicy) {
                    ForEach(Magent.ProxyDNSPolicy.allCases, id: \.rawValue) { policy in
                        Text(policy.rawValue)
                            .tag(policy)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text(title)
                    .font(.title3.weight(.semibold))
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
                    .disabled(canAdd == false)
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
        guard canAdd else {
            return
        }

        let didSave: Bool
        if let node {
            didSave = controller.updateNode(
                node,
                name: name,
                type: type,
                address: address,
                port: port,
                cipher: cipher,
                password: password,
                timeout: TimeInterval(timeout),
                dnsPolicy: dnsPolicy,
                in: modelContext
            )
        } else {
            didSave = controller.addNode(
                name: name,
                type: type,
                address: address,
                port: port,
                cipher: cipher,
                password: password,
                timeout: TimeInterval(timeout),
                dnsPolicy: dnsPolicy,
                in: modelContext
            )
        }

        if didSave {
            dismiss()
        }
    }
}

/// 节点列表中的单行展示和操作按钮。
private struct NodeListRow: View {
    let node: MagentNode
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var endpoint: String {
        "\(node.address):\(node.port)"
    }

    private var metadata: String {
        let type = node.type.rawValue
        let region = node.region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard region.isEmpty == false, region != node.address else {
            return "\(endpoint) - \(type)"
        }
        return "\(endpoint) - \(region) - \(type)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
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
