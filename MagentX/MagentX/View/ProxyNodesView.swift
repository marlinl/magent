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

/// 代理节点管理页面，直接观察 SwiftData 节点并提供新增、修改和删除交互。
@MainActor
struct ProxyNodesView: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var toolbarButtons: [ContentToolbarButton]
    @State private var pageAt = 1
    @State private var selectedNodeID: UUID?
    @State private var editingNode: MagentProxyNode?

    private static let pageSize = 100

    var body: some View {
        ProxyNodePageView(
            pageAt: $pageAt,
            pageSize: Self.pageSize,
            selectedNodeID: $selectedNodeID,
            editingNode: $editingNode
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            toolbarButtons = [
                ContentToolbarButton(title: "添加代理节点", systemImage: "plus") {
                    let existingNodeCount = (try? modelContext.fetchCount(
                        FetchDescriptor<MagentProxyNode>()
                    )) ?? 0
                    let now = Date.now
                    let node = MagentProxyNode(
                        id: MagentProxyNode.makeUUIDVersion7(at: now),
                        name: nil,
                        type: ProxyNodeType.shadowsocks.rawValue,
                        address: "",
                        port: 8388,
                        cipher: ProxyCipher.chacha20IetfPoly1305.rawValue,
                        password: "",
                        timeout: 30,
                        createdAt: now,
                        updatedAt: now
                    )
                    modelContext.insert(node)
                    pageAt = existingNodeCount / Self.pageSize + 1
                    selectedNodeID = node.id
                    editingNode = node
                }
            ]
        }
        .sheet(item: $editingNode) { node in
            ProxyNodeFormView(node: node)
            .presentationSizing(.form)
        }
    }

    /// 使用当前页对应的 `FetchDescriptor` 观察并展示最多 100 个代理节点。
    private struct ProxyNodePageView: View {
        @Environment(\.modelContext) private var modelContext
        @Query private var nodes: [MagentProxyNode]
        @Binding private var pageAt: Int
        @Binding private var selectedNodeID: UUID?
        @Binding private var editingNode: MagentProxyNode?
        @State private var scrollPosition = ScrollPosition(edge: .top)

        private let pageSize: Int

        /// 为指定页创建按节点 id 正序排列的 SwiftData 查询。
        init(
            pageAt: Binding<Int>,
            pageSize: Int,
            selectedNodeID: Binding<UUID?>,
            editingNode: Binding<MagentProxyNode?>
        ) {
            precondition(pageAt.wrappedValue >= 1, "pageAt must start at 1")
            precondition(pageSize > 0, "pageSize must be greater than 0")

            var descriptor = FetchDescriptor<MagentProxyNode>(
                sortBy: [SortDescriptor(\.id, order: .forward)]
            )
            descriptor.fetchLimit = pageSize + 1
            descriptor.fetchOffset = (pageAt.wrappedValue - 1) * pageSize
            _nodes = Query(descriptor)
            _pageAt = pageAt
            _selectedNodeID = selectedNodeID
            _editingNode = editingNode
            self.pageSize = pageSize
        }

        var body: some View {
            Group {
                if nodes.isEmpty {
                    ContentUnavailableView(
                        "暂无代理节点",
                        systemImage: "server.rack",
                        description: Text(pageAt == 1 ? "添加代理节点后会显示在这里" : "当前页没有节点")
                    )
                } else {
                    Table(Array(nodes.prefix(pageSize)), selection: $selectedNodeID) {
                        TableColumn("名称") { node in
                            Label(
                                node.name.flatMap { name in
                                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? nil
                                        : name
                                } ?? node.address,
                                systemImage: "server.rack"
                            )
                                .lineLimit(1)
                        }
                        .width(min: 140, ideal: 220)

                        TableColumn("地址") { node in
                            Text(verbatim: "\(node.address):\(node.port)")
                                .lineLimit(1)
                        }
                        .width(min: 160, ideal: 240)

                        TableColumn("类型") { node in
                            Text(node.type)
                        }
                        .width(min: 100, ideal: 140)

                        TableColumn("操作") { node in
                            ControlGroup {
                                Button {
                                    editingNode = node
                                } label: {
                                    Label("修改节点", systemImage: "pencil")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.glass)
                                .help("修改节点")

                                Button(role: .destructive) {
                                    if editingNode?.id == node.id {
                                        editingNode = nil
                                    }
                                    if selectedNodeID == node.id {
                                        selectedNodeID = nil
                                    }
                                    modelContext.delete(node)
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
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: ScrollGeometry.self) { geometry in
                        geometry
                    } action: { oldGeometry, newGeometry in
                        guard scrollPosition.isPositionedByUser else { return }

                        if newGeometry.visibleRect.minY < oldGeometry.visibleRect.minY,
                           newGeometry.visibleRect.minY <= 0,
                           pageAt > 1 {
                            pageAt -= 1
                            scrollPosition.scrollTo(edge: .bottom)
                        } else if newGeometry.visibleRect.maxY > oldGeometry.visibleRect.maxY,
                                  newGeometry.visibleRect.maxY >= newGeometry.contentSize.height,
                                  nodes.count > pageSize {
                            pageAt += 1
                            scrollPosition.scrollTo(edge: .top)
                        }
                    }
                }
            }
        }
    }

    /// 直接编辑 SwiftData 代理节点的原生表单页面。
    private struct ProxyNodeFormView: View {
        @Environment(\.dismiss) private var dismiss
        @Bindable var node: MagentProxyNode

        private static let portRange = 1...65_535
        private static let timeoutFormatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .none
            formatter.allowsFloats = false
            formatter.minimum = 1
            return formatter
        }()

        var body: some View {
            let normalizedAddress = node.address.trimmingCharacters(in: .whitespacesAndNewlines)
            let addressError: MagentXError? = if normalizedAddress.isEmpty {
                .emptyAddress
            } else if MagentProxyNode.isValidAddress(node.address) {
                nil
            } else {
                .invalidAddress
            }

            Form {
                Section {
                    TextField(
                        "名称（可选）",
                        text: Binding(
                            get: { node.name ?? "" },
                            set: { newValue in
                                node.name = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? node.address
                                    : newValue
                            }
                        )
                    )

                    Picker("类型", selection: $node.type) {
                        ForEach(ProxyNodeType.allCases, id: \.rawValue) { type in
                            Text(type.rawValue)
                                .tag(type.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    TextField("地址", text: $node.address)
                    if let addressError {
                        Label(addressError.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    TextField(
                        "端口",
                        value: $node.port,
                        format: .number.grouping(.never)
                    )

                    Picker("加密", selection: $node.cipher) {
                        ForEach(ProxyCipher.allCases, id: \.rawValue) { cipher in
                            Text(cipher.rawValue)
                                .tag(cipher.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    SecureField("密码", text: $node.password)
                    TextField("超时", value: $node.timeout, formatter: Self.timeoutFormatter)
                } header: {
                    Text("节点配置")
                        .font(.title3.weight(.semibold))
                }
            }
            .formStyle(.grouped)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .disabled(addressError != nil)
                }
            }
            .interactiveDismissDisabled(addressError != nil)
            .onAppear {
                if node.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    node.name = node.address
                }
            }
            .onChange(of: node.name) { _, _ in
                node.updatedAt = .now
            }
            .onChange(of: node.type) { _, _ in
                node.updatedAt = .now
            }
            .onChange(of: node.address) { oldValue, newValue in
                if node.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ||
                    node.name == oldValue {
                    node.name = newValue
                }
                node.updatedAt = .now
            }
            .onChange(of: node.port) { _, newValue in
                node.port = min(
                    max(newValue, Self.portRange.lowerBound),
                    Self.portRange.upperBound
                )
                node.updatedAt = .now
            }
            .onChange(of: node.cipher) { _, _ in
                node.updatedAt = .now
            }
            .onChange(of: node.password) { _, _ in
                node.updatedAt = .now
            }
            .onChange(of: node.timeout) { _, newValue in
                node.timeout = max(1, newValue)
                node.updatedAt = .now
            }
        }
    }
}
