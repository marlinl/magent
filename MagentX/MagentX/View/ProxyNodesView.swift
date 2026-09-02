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

/// 代理节点管理页面，通过 `body`、`add`、`update` 和 `delete` 管理节点。
@MainActor
struct ProxyNodesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [
        SortDescriptor(\MagentProxyNode.updatedAt, order: .reverse),
        SortDescriptor(\MagentProxyNode.createdAt, order: .reverse),
        SortDescriptor(\MagentProxyNode.address)
    ]) private var nodes: [MagentProxyNode]
    @Binding var toolbarButtons: [ContentToolbarButton]
    @State private var selectedNodeID: UUID?
    @State private var isEditorPresented = false
    @State private var editingNodeID: UUID?
    @State private var editorName = ""
    @State private var editorType = ProxyNodeType.shadowsocks
    @State private var editorAddress = ""
    @State private var editorPort = 8388
    @State private var editorCipher = ProxyCipher.chacha20IetfPoly1305
    @State private var editorPassword = ""
    @State private var editorTimeout = 30
    @State private var editorError: String?
    @State private var deleteError: String?

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

    var body: some View {
        Group {
            if nodes.isEmpty {
                ContentUnavailableView(
                    "暂无代理节点",
                    systemImage: "server.rack",
                    description: Text("添加代理节点后会显示在这里")
                )
            } else {
                List(selection: $selectedNodeID) {
                    ForEach(nodes, id: \.id) { node in
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, alignment: .center)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.displayName)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)

                                Text("\(node.address):\(node.port) - \(node.type.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button {
                                editingNodeID = node.id
                                editorName = node.name ?? ""
                                editorType = node.type
                                editorAddress = node.address
                                editorPort = node.port
                                editorCipher = node.cipher
                                editorPassword = node.password
                                editorTimeout = max(1, Int(node.timeout.rounded()))
                                editorError = nil
                                isEditorPresented = true
                            } label: {
                                Image(systemName: "pencil")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .help("修改节点")

                            Button(role: .destructive) {
                                delete(node)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help("删除节点")
                        }
                        .padding(.vertical, 4)
                        .tag(node.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            toolbarButtons = [
                ContentToolbarButton(title: "添加代理节点", systemImage: "plus") {
                    editingNodeID = nil
                    editorName = ""
                    editorType = .shadowsocks
                    editorAddress = ""
                    editorPort = 8388
                    editorCipher = .chacha20IetfPoly1305
                    editorPassword = ""
                    editorTimeout = 30
                    editorError = nil
                    isEditorPresented = true
                }
            ]
        }
        .sheet(isPresented: $isEditorPresented) {
            Form {
                Section {
                    TextField("名称（可选）", text: $editorName)

                    Picker("类型", selection: $editorType) {
                        ForEach(ProxyNodeType.allCases, id: \.rawValue) { type in
                            Text(type.rawValue)
                                .tag(type)
                        }
                    }
                    .pickerStyle(.menu)

                    TextField("地址", text: $editorAddress)
                    TextField("端口", value: $editorPort, formatter: Self.portFormatter)

                    Picker("加密", selection: $editorCipher) {
                        ForEach(ProxyCipher.allCases, id: \.rawValue) { cipher in
                            Text(cipher.rawValue)
                                .tag(cipher)
                        }
                    }
                    .pickerStyle(.menu)

                    SecureField("密码", text: $editorPassword)
                    TextField("超时", value: $editorTimeout, formatter: Self.timeoutFormatter)
                } header: {
                    Text(LocalizedStringKey(editingNodeID == nil ? "添加节点" : "修改节点"))
                        .font(.title3.weight(.semibold))
                }

                if let editorError {
                    Section {
                        Text(editorError)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    ControlGroup {
                        Button("取消", role: .cancel) {
                            isEditorPresented = false
                        }
                        .buttonStyle(.glass)

                        Button {
                            let didSave = editingNodeID == nil ? add() : update()
                            if didSave {
                                isEditorPresented = false
                            }
                        } label: {
                            Text(LocalizedStringKey(editingNodeID == nil ? "添加" : "保存"))
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(MagentProxyNode.validationErrors(
                            address: editorAddress,
                            port: editorPort,
                            password: editorPassword,
                            timeout: TimeInterval(editorTimeout)
                        ).isEmpty == false)
                        .buttonStyle(.glassProminent)
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(width: 360)
            .onChange(of: editorPort) { _, newValue in
                editorPort = min(max(newValue, Self.portRange.lowerBound), Self.portRange.upperBound)
            }
            .onChange(of: editorTimeout) { _, newValue in
                editorTimeout = max(1, newValue)
            }
        }
        .alert(
            "代理节点",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { isPresented in
                    if isPresented == false {
                        deleteError = nil
                    }
                }
            )
        ) {
            Button("好", role: .cancel) {
                deleteError = nil
            }
        } message: {
            Text(deleteError ?? "")
        }
    }

    /// 新增表单当前填写的代理节点，保存成功后选择新节点。
    ///
    /// - Returns: 节点通过校验并成功写入 SwiftData 时返回 `true`。
    private func add() -> Bool {
        let validationErrors = MagentProxyNode.validationErrors(
            address: editorAddress,
            port: editorPort,
            password: editorPassword,
            timeout: TimeInterval(editorTimeout)
        )
        guard let validationError = validationErrors.first else {
            let node = MagentProxyNode(
                name: editorName,
                type: editorType,
                address: editorAddress,
                port: editorPort,
                cipher: editorCipher,
                password: editorPassword,
                timeout: TimeInterval(editorTimeout)
            )
            modelContext.insert(node)

            do {
                try modelContext.save()
                selectedNodeID = node.id
                editorError = nil
                return true
            } catch {
                modelContext.rollback()
                editorError = error.localizedDescription
                return false
            }
        }

        editorError = validationError.localizedDescription
        return false
    }

    /// 按业务 id 更新表单对应节点的可编辑字段，保存成功后保持该节点选中。
    ///
    /// - Returns: 找到节点、通过校验并成功写入 SwiftData 时返回 `true`。
    private func update() -> Bool {
        guard let editingNodeID,
              let node = nodes.first(where: { $0.id == editingNodeID }) else {
            if let editingNodeID {
                editorError = MagentXError.missingMagentProxyNode(editingNodeID).localizedDescription
            }
            return false
        }

        let validationErrors = MagentProxyNode.validationErrors(
            address: editorAddress,
            port: editorPort,
            password: editorPassword,
            timeout: TimeInterval(editorTimeout)
        )
        guard let validationError = validationErrors.first else {
            node.update(
                name: editorName,
                type: editorType,
                address: editorAddress,
                port: editorPort,
                cipher: editorCipher,
                password: editorPassword,
                timeout: TimeInterval(editorTimeout)
            )

            do {
                try modelContext.save()
                selectedNodeID = node.id
                editorError = nil
                return true
            } catch {
                modelContext.rollback()
                editorError = error.localizedDescription
                return false
            }
        }

        editorError = validationError.localizedDescription
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
                deleteError = MagentXError.proxyNodeInUse(node.id).localizedDescription
                return
            }

            modelContext.delete(node)
            try modelContext.save()
            if selectedNodeID == node.id {
                selectedNodeID = nil
            }
            deleteError = nil
        } catch {
            modelContext.rollback()
            deleteError = error.localizedDescription
        }
    }
}
