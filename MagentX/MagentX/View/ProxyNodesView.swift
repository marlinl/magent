//
//  ProxyNodesView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Provides the proxy node list and direct SwiftData CRUD UI.
//

import Magent
import SwiftData
import SwiftUI

/// 代理节点管理页面，通过新增、修改、删除和分页查询管理节点。
@MainActor
struct ProxyNodesView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var toolbarButtons: [ContentToolbarButton]
    @State private var selectedNodeID: UUID?
    @State private var draft: ProxyNodeDraft?
    @State private var operationError: String?
    @State private var queryResult = ProxyNodeQueryResult()

    private static let pageSize = 50

    var body: some View {
        Group {
            if let loadError = queryResult.error {
                ContentUnavailableView(
                    "节点读取失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if queryResult.items.isEmpty {
                ContentUnavailableView(
                    "暂无代理节点",
                    systemImage: "server.rack",
                    description: Text("添加代理节点后会显示在这里")
                )
            } else {
                ProxyNodeTable(
                    nodes: queryResult.items,
                    selectedNodeID: $selectedNodeID,
                    canLoadMore: queryResult.canLoadMore,
                    onLoadMore: {
                        query(
                            pageAt: queryResult.pageAt + 1,
                            pageSize: Self.pageSize
                        )
                    },
                    onEdit: { node in
                        draft = ProxyNodeDraft(
                            editingNodeID: node.id,
                            name: node.name ?? "",
                            type: node.type,
                            address: node.address,
                            port: node.port,
                            cipher: node.cipher,
                            password: node.password,
                            timeout: max(1, Int(node.timeout.rounded()))
                        )
                    },
                    onDelete: { node in
                        delete(node)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            toolbarButtons = [
                ContentToolbarButton(title: "添加代理节点", systemImage: "plus") {
                    draft = ProxyNodeDraft(
                        editingNodeID: nil,
                        name: "",
                        type: .shadowsocks,
                        address: "",
                        port: 8388,
                        cipher: .chacha20IetfPoly1305,
                        password: "",
                        timeout: 30
                    )
                }
            ]
        }
        .task {
            query(pageAt: 1, pageSize: Self.pageSize)
        }
        .sheet(item: $draft) { draft in
            ProxyNodeFormView(
                draft: draft,
                onCancel: {
                    self.draft = nil
                },
                onSave: { draft in
                    let didSave = draft.editingNodeID == nil ? add(draft) : update(draft)
                    if didSave {
                        self.draft = nil
                    }
                }
            )
            .presentationSizing(.form)
        }
        .alert(
            "代理节点操作失败",
            isPresented: Binding(
                get: { operationError != nil },
                set: { isPresented in
                    if isPresented == false {
                        operationError = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {
                operationError = nil
            }
        } message: {
            Text(operationError ?? "")
        }
    }

    /// 新增表单当前填写的代理节点，保存成功后选择新节点。
    ///
    /// - Parameter draft: 已完成编辑、准备校验并保存的节点草稿。
    /// - Returns: 节点通过校验并成功写入 SwiftData 时返回 `true`。
    private func add(_ draft: ProxyNodeDraft) -> Bool {
        let validationErrors = MagentProxyNode.validationErrors(
            address: draft.address,
            port: draft.port,
            password: draft.password,
            timeout: TimeInterval(draft.timeout)
        )
        guard let validationError = validationErrors.first else {
            let node = MagentProxyNode(
                name: draft.name,
                type: draft.type,
                address: draft.address,
                port: draft.port,
                cipher: draft.cipher,
                password: draft.password,
                timeout: TimeInterval(draft.timeout)
            )
            modelContext.insert(node)

            do {
                try modelContext.save()
                selectedNodeID = node.id
                operationError = nil
                query(pageAt: 1, pageSize: Self.pageSize)
                return true
            } catch {
                modelContext.rollback()
                operationError = "添加节点失败：\(error.localizedDescription)"
                return false
            }
        }

        operationError = "添加节点失败：\(validationError.localizedDescription)"
        return false
    }

    /// 按业务 id 更新表单对应节点的可编辑字段，保存成功后保持该节点选中。
    ///
    /// - Parameter draft: 带有目标节点 id 和最新字段值的节点草稿。
    /// - Returns: 找到节点、通过校验并成功写入 SwiftData 时返回 `true`。
    private func update(_ draft: ProxyNodeDraft) -> Bool {
        guard let editingNodeID = draft.editingNodeID else { return false }

        let validationErrors = MagentProxyNode.validationErrors(
            address: draft.address,
            port: draft.port,
            password: draft.password,
            timeout: TimeInterval(draft.timeout)
        )
        guard let validationError = validationErrors.first else {
            let targetNodeID = editingNodeID
            let descriptor = FetchDescriptor<MagentProxyNode>(
                predicate: #Predicate<MagentProxyNode> { node in
                    node.id == targetNodeID
                }
            )

            do {
                guard let node = try modelContext.fetch(descriptor).first else {
                    throw MagentXError.missingMagentProxyNode(editingNodeID)
                }
                node.update(
                    name: draft.name,
                    type: draft.type,
                    address: draft.address,
                    port: draft.port,
                    cipher: draft.cipher,
                    password: draft.password,
                    timeout: TimeInterval(draft.timeout)
                )
                try modelContext.save()
                selectedNodeID = node.id
                operationError = nil
                query(pageAt: 1, pageSize: Self.pageSize)
                return true
            } catch {
                modelContext.rollback()
                operationError = "修改节点失败：\(error.localizedDescription)"
                return false
            }
        }

        operationError = "修改节点失败：\(validationError.localizedDescription)"
        return false
    }

    /// 删除指定节点；节点仍被策略引用时拒绝删除并保留原数据。
    ///
    /// - Parameter node: 准备从 SwiftData 删除的代理节点。
    private func delete(_ node: MagentProxyNode) {
        let targetNodeID: UUID? = node.id
        let policyDescriptor = FetchDescriptor<ProxyPolicy>(
            predicate: #Predicate<ProxyPolicy> { policy in
                policy.magentNodeID == targetNodeID
            }
        )

        do {
            guard try modelContext.fetchCount(policyDescriptor) == 0 else {
                let error = MagentXError.proxyNodeInUse(node.id)
                operationError = "删除节点失败：\(error.localizedDescription)"
                return
            }

            modelContext.delete(node)
            try modelContext.save()
            if selectedNodeID == node.id {
                selectedNodeID = nil
            }
            operationError = nil
            query(pageAt: 1, pageSize: Self.pageSize)
        } catch {
            modelContext.rollback()
            operationError = "删除节点失败：\(error.localizedDescription)"
        }
    }

    /// 按页读取代理节点，并仅使用具有时间顺序的 UUIDv7 业务 id 倒序排列。
    ///
    /// - Parameters:
    ///   - pageAt: 从 `1` 开始的页码。
    ///   - pageSize: 每页最多展示的节点数量。
    private func query(pageAt: Int, pageSize: Int) {
        guard pageAt >= 1, pageSize > 0 else { return }
        guard pageAt == 1 || pageAt == queryResult.pageAt + 1 else { return }

        var descriptor = FetchDescriptor<MagentProxyNode>(
            sortBy: [SortDescriptor(\.id, order: .reverse)]
        )
        descriptor.fetchOffset = (pageAt - 1) * pageSize
        descriptor.fetchLimit = pageSize + 1

        do {
            let fetchedNodes = try modelContext.fetch(descriptor)
            let pageItems = Array(fetchedNodes.prefix(pageSize))
            if pageAt == 1 {
                queryResult.items = pageItems
            } else {
                queryResult.items.append(contentsOf: pageItems)
            }
            queryResult.pageAt = pageAt
            queryResult.canLoadMore = fetchedNodes.count > pageItems.count
            queryResult.error = nil
        } catch {
            if pageAt == 1 {
                queryResult.items = []
            }
            queryResult.canLoadMore = false
            queryResult.error = error.localizedDescription
        }
    }

    /// 使用原生表格展示代理节点，并发布编辑、删除和续页操作。
    private struct ProxyNodeTable: View {
        let nodes: [MagentProxyNode]
        @Binding var selectedNodeID: UUID?
        let canLoadMore: Bool
        let onLoadMore: () -> Void
        let onEdit: (MagentProxyNode) -> Void
        let onDelete: (MagentProxyNode) -> Void

        var body: some View {
            Table(nodes, selection: $selectedNodeID) {
                TableColumn("名称") { node in
                    Label(node.displayName, systemImage: "server.rack")
                        .lineLimit(1)
                        .onAppear {
                            guard node.id == nodes.last?.id, canLoadMore else { return }
                            onLoadMore()
                        }
                }
                .width(min: 140, ideal: 220)

                TableColumn("地址") { node in
                    Text(verbatim: "\(node.address):\(node.port)")
                        .lineLimit(1)
                }
                .width(min: 160, ideal: 240)

                TableColumn("类型") { node in
                    Text(node.type.rawValue)
                }
                .width(min: 100, ideal: 140)

                TableColumn("操作") { node in
                    ControlGroup {
                        Button {
                            onEdit(node)
                        } label: {
                            Label("修改节点", systemImage: "pencil")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.glass)
                        .help("修改节点")

                        Button(role: .destructive) {
                            onDelete(node)
                        } label: {
                            Label("删除节点", systemImage: "trash")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.glass)
                        .help("删除节点")
                    }
                    .controlSize(.small)
                }
                .width(min: 100, ideal: 140)
            }
        }
    }

    /// 添加和修改代理节点共用的原生表单页面。
    private struct ProxyNodeFormView: View {
        @State var draft: ProxyNodeDraft
        let onCancel: () -> Void
        let onSave: (ProxyNodeDraft) -> Void

        private static let portRange = 1...65535
        private static let timeoutFormatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .none
            formatter.allowsFloats = false
            formatter.minimum = 1
            return formatter
        }()

        var body: some View {
            Form {
                Section {
                    TextField("名称（可选）", text: $draft.name)

                    Picker("类型", selection: $draft.type) {
                        ForEach(ProxyNodeType.allCases, id: \.rawValue) { type in
                            Text(type.rawValue)
                                .tag(type)
                        }
                    }
                    .pickerStyle(.menu)

                    TextField("地址", text: $draft.address)
                    TextField(
                        "端口",
                        value: $draft.port,
                        format: .number.grouping(.never)
                    )

                    Picker("加密", selection: $draft.cipher) {
                        ForEach(ProxyCipher.allCases, id: \.rawValue) { cipher in
                            Text(cipher.rawValue)
                                .tag(cipher)
                        }
                    }
                    .pickerStyle(.menu)

                    SecureField("密码", text: $draft.password)
                    TextField("超时", value: $draft.timeout, formatter: Self.timeoutFormatter)
                } header: {
                    Text(LocalizedStringKey(
                        draft.editingNodeID == nil ? "添加节点" : "修改节点"
                    ))
                    .font(.title3.weight(.semibold))
                }

                Section {
                    ControlGroup {
                        Button("取消", role: .cancel, action: onCancel)
                            .buttonStyle(.glass)

                        Button(draft.editingNodeID == nil ? "添加" : "保存") {
                            onSave(draft)
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(MagentProxyNode.validationErrors(
                            address: draft.address,
                            port: draft.port,
                            password: draft.password,
                            timeout: TimeInterval(draft.timeout)
                        ).isEmpty == false)
                        .buttonStyle(.glassProminent)
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: draft.port) { _, newValue in
                draft.port = min(
                    max(newValue, Self.portRange.lowerBound),
                    Self.portRange.upperBound
                )
            }
            .onChange(of: draft.timeout) { _, newValue in
                draft.timeout = max(1, newValue)
            }
        }
    }
}

/// 代理节点添加或修改期间使用的表单草稿，避免取消编辑时直接改动 SwiftData 模型。
private struct ProxyNodeDraft: Identifiable {
    let id = UUID()
    let editingNodeID: UUID?
    var name: String
    var type: ProxyNodeType
    var address: String
    var port: Int
    var cipher: ProxyCipher
    var password: String
    var timeout: Int
}

/// 代理节点分页查询状态，集中保存当前列表、页码、续页标记和读取错误。
private struct ProxyNodeQueryResult {
    var items: [MagentProxyNode] = []
    var pageAt = 1
    var canLoadMore = false
    var error: String?
}
