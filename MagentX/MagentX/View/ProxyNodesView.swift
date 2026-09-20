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

/// 代理节点管理页面，在原生表格和详情区域中提供直接的 SwiftData CRUD 交互。
@MainActor
struct ProxyNodesView: View {
  @Environment(\.modelContext) private var modelContext
  @Binding var toolbarButtons: [ContentToolbarButton]
  @State private var selectedNode: MagentProxyNode?
  @State private var proxyNodeViewModel: ProxyNodeViewModel?
  @State private var actionError: String?

  private static let maximumCachedModelCount = 300

  var body: some View {
    HSplitView {
      ScrollTableView(
        selection: Binding(
          get: { selectedNode?.id },
          set: { nodeID in
            guard nodeID != selectedNode?.id else { return }
            guard let nodeID else {
              selectedNode = nil
              return
            }
            do {
              // 表格只暴露单选标识；详情按需读取一条，不再保留第二份节点列表。
              var descriptor = FetchDescriptor<MagentProxyNode>(
                predicate: #Predicate { $0.id == nodeID }
              )
              descriptor.fetchLimit = 1
              guard let node = try modelContext.fetch(descriptor).first else {
                throw MagentXError.missingMagentProxyNode(nodeID)
              }
              selectedNode = node
            } catch {
              actionError = error.localizedDescription
            }
          }
        ),
        // id 排序保持不变；300 只限制缓存，不能作为可浏览结果的总上限。
        descriptor: FetchDescriptor<MagentProxyNode>(
          sortBy: [SortDescriptor(\MagentProxyNode.id, order: .forward)]
        ),
        queryID: "proxy-nodes",
        maximumCachedModelCount: Self.maximumCachedModelCount
      ) {
        TableColumn("名称") { node in
          Label(node.name, systemImage: "server.rack")
            .lineLimit(1)
        }
        .width(min: 90, ideal: 140, max: 180)

        TableColumn("地址") { node in
          Text(verbatim: "\(node.address):\(node.port)")
            .lineLimit(1)
        }
        .width(min: 100, ideal: 160, max: 200)

        TableColumn("类型") { node in
          Text(node.type)
            .lineLimit(1)
        }
        .width(min: 64, ideal: 90, max: 120)
      }
      .accessibilityIdentifier("proxy-nodes-table")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .frame(minWidth: 240, idealWidth: 432, maxWidth: 440, maxHeight: .infinity)

      Group {
        if let proxyNodeViewModel, proxyNodeViewModel.isNew {
          @Bindable var node = proxyNodeViewModel.node
          let normalizedAddress = node.address.trimmingCharacters(in: .whitespacesAndNewlines)
          let addressError: MagentXError? =
            if normalizedAddress.isEmpty {
              .invalidParameter(String(localized: "Address is required"))
            } else if MagentProxyNode.isValidAddress(node.address) {
              nil
            } else {
              .invalidParameter(
                String(localized: "Address must be a hostname, IPv4 address, or IPv6 address")
              )
            }

          Form {
            Section("节点配置") {
              TextField("名称（可选）", text: $node.name)
                .accessibilityIdentifier("new-node-name")

              Picker("类型", selection: $node.type) {
                ForEach(ProxyNodeType.allCases, id: \.rawValue) { type in
                  Text(type.rawValue)
                    .tag(type.rawValue)
                }
              }
              .pickerStyle(.menu)

              TextField("地址", text: $node.address)
                .accessibilityIdentifier("new-node-address")
              if let addressError {
                Label(
                  addressError.localizedDescription,
                  systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
              }

              TextField("端口", value: $node.port, format: .number.grouping(.never))

              Picker("加密方法", selection: $node.cipher) {
                ForEach(ProxyCipher.allCases, id: \.rawValue) { cipher in
                  Text(cipher.rawValue)
                    .tag(cipher.rawValue)
                }
              }
              .pickerStyle(.menu)

              SecureField("密码", text: $node.password)
                .accessibilityIdentifier("new-node-password")
              TextField("超时", value: $node.timeout, format: .number.grouping(.never))
            }
          }
          .formStyle(.grouped)
          .onChange(of: node.port) { _, newValue in
            node.port = min(max(newValue, 1), 65_535)
          }
          .onChange(of: node.timeout) { _, newValue in
            node.timeout = max(1, newValue)
          }
          .safeAreaInset(edge: .bottom) {
            HStack {
              if #available(macOS 26.0, *) {
                Button(role: .cancel) {
                  proxyNodeViewModel.rollback()
                  self.proxyNodeViewModel = nil
                  actionError = nil
                } label: {
                  Label("取消", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("取消")
                .accessibilityLabel("取消")
                .keyboardShortcut(.cancelAction)
              } else {
                Button(role: .cancel) {
                  proxyNodeViewModel.rollback()
                  self.proxyNodeViewModel = nil
                  actionError = nil
                } label: {
                  Label("取消", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .help("取消")
                .accessibilityLabel("取消")
                .keyboardShortcut(.cancelAction)
              }

              Spacer()

              if #available(macOS 26.0, *) {
                Button {
                  do {
                    try proxyNodeViewModel.save()
                    let nodeID = proxyNodeViewModel.id
                    let descriptor = FetchDescriptor<MagentProxyNode>(
                      predicate: #Predicate<MagentProxyNode> { node in
                        node.id == nodeID
                      }
                    )
                    guard let savedNode = try modelContext.fetch(descriptor).first else {
                      throw MagentXError.missingMagentProxyNode(nodeID)
                    }
                    selectedNode = savedNode
                    self.proxyNodeViewModel = nil
                    actionError = nil
                  } catch {
                    actionError = error.localizedDescription
                  }
                } label: {
                  Label("保存", systemImage: "checkmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .help("保存")
                .accessibilityLabel("保存")
                .keyboardShortcut(.defaultAction)
                .disabled(addressError != nil)
              } else {
                Button {
                  do {
                    try proxyNodeViewModel.save()
                    let nodeID = proxyNodeViewModel.id
                    let descriptor = FetchDescriptor<MagentProxyNode>(
                      predicate: #Predicate<MagentProxyNode> { node in
                        node.id == nodeID
                      }
                    )
                    guard let savedNode = try modelContext.fetch(descriptor).first else {
                      throw MagentXError.missingMagentProxyNode(nodeID)
                    }
                    selectedNode = savedNode
                    self.proxyNodeViewModel = nil
                    actionError = nil
                  } catch {
                    actionError = error.localizedDescription
                  }
                } label: {
                  Label("保存", systemImage: "checkmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .help("保存")
                .accessibilityLabel("保存")
                .keyboardShortcut(.defaultAction)
                .disabled(addressError != nil)
              }
            }
            .padding()
            .background(.bar)
          }
        } else if let selectedNode {
          ProxyNodeDetailView(node: selectedNode, actionError: $actionError) {
            delete(selectedNode)
          }
          .id(selectedNode.id)
        } else {
          ContentUnavailableView(
            "选择代理节点",
            systemImage: "server.rack",
            description: Text("从左侧表格选择节点以查看详情，或添加一个新节点")
          )
        }
      }
      .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.top, 1)
    .overlay(alignment: .top) {
      Divider()
    }
    .alert(
      "代理节点操作失败",
      isPresented: Binding(
        get: { actionError != nil },
        set: { isPresented in
          if isPresented == false {
            actionError = nil
          }
        }
      )
    ) {
      Button("好", role: .cancel) {
        actionError = nil
      }
    } message: {
      Text(actionError ?? "")
    }
    .onAppear {
      toolbarButtons = [
        ContentToolbarButton(title: "添加代理节点", systemImage: "plus") {
          add()
        }
      ]
    }
    .onDisappear {
      if let proxyNodeViewModel, proxyNodeViewModel.isNew {
        proxyNodeViewModel.rollback()
        self.proxyNodeViewModel = nil
      }
    }
  }

  /// 打开使用独立 context 的新节点表单，支持保存前取消。
  private func add() {
    proxyNodeViewModel?.rollback()
    proxyNodeViewModel = ProxyNodeViewModel(modelContainer: modelContext.container)
    actionError = nil
  }

  /// 删除未被策略引用的节点；若节点仍被引用则保留数据并报告原有保护错误。
  private func delete(_ node: MagentProxyNode) {
    do {
      let targetNodeID = node.id
      let descriptor = FetchDescriptor<MagentProxyPolicy>(
        predicate: #Predicate<MagentProxyPolicy> { policy in
          policy.nodeID == targetNodeID
        }
      )
      guard try modelContext.fetchCount(descriptor) == 0 else {
        throw MagentXError.invalidParameter(
          String(localized: "Proxy node is in use by a policy")
        )
      }

      modelContext.delete(node)
      try modelContext.save()
      selectedNode = nil
      actionError = nil
    } catch {
      if node.isDeleted {
        modelContext.rollback()
      }
      actionError = error.localizedDescription
    }
  }
}

/// 单个已有节点的绑定详情；仅需要校验的字段持有草稿，状态随节点标识重建。
@MainActor
private struct ProxyNodeDetailView: View {
  @Environment(\.modelContext) private var modelContext
  @Bindable var node: MagentProxyNode
  @Binding var actionError: String?
  let onDelete: () -> Void
  @State private var addressDraft = ""
  @State private var portDraft = ""
  @State private var passwordDraft = ""
  @State private var timeoutDraft = ""

  var body: some View {
    Form {
      Section("节点详情") {
        LabeledContent("名称") {
          EditableFieldFormView(
            onEditingEnded: {
              save {
                let trimmedName = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = trimmedName.isEmpty ? "\(node.address):\(node.port)" : trimmedName
                if node.name != name {
                  node.name = name
                  node.updatedAt = .now
                }
              }
            }
          ) {
            Text(node.name)
              .frame(maxWidth: .infinity, alignment: .trailing)
          } editor: { focus, _ in
            TextField("名称", text: $node.name)
              .labelsHidden()
              .focused(focus)
              .multilineTextAlignment(.trailing)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          .onChange(of: node.name) { _, _ in
            guard node.modelContext != nil, !node.isDeleted else { return }
            node.updatedAt = .now
          }
          .help("点击修改名称")
          .accessibilityIdentifier("node-name")
        }

        LabeledContent("类型") {
          Picker("类型", selection: $node.type) {
            ForEach(ProxyNodeType.allCases, id: \.rawValue) { type in
              Text(type.rawValue)
                .tag(type.rawValue)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .onChange(of: node.type) { _, _ in
            save { node.updatedAt = .now }
          }
          .accessibilityIdentifier("node-type")
        }
      }

      Section("连接") {
        LabeledContent("地址") {
          EditableFieldFormView(
            onEditingBegan: {
              addressDraft = node.address
              return true
            },
            onEditingEnded: {
              save {
                let address = addressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !address.isEmpty, MagentProxyNode.isValidAddress(address) else {
                  throw MagentXError.invalidParameter(
                    String(localized: "Address must be a hostname, IPv4 address, or IPv6 address")
                  )
                }
                guard node.address != address else { return }
                node.address = address
                node.updatedAt = .now
              }
            }
          ) {
            Text(node.address)
              .frame(maxWidth: .infinity, alignment: .trailing)
          } editor: { focus, _ in
            TextField("地址", text: $addressDraft)
              .labelsHidden()
              .focused(focus)
              .multilineTextAlignment(.trailing)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          .help("点击修改地址")
          .accessibilityIdentifier("node-address")
        }

        LabeledContent("端口") {
          EditableFieldFormView(
            onEditingBegan: {
              portDraft = String(node.port)
              return true
            },
            onEditingEnded: {
              save {
                let value = portDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let port = Int(value), (1...65_535).contains(port) else {
                  throw MagentXError.invalidParameter(
                    String(localized: "Port must be an integer from 1 to 65535")
                  )
                }
                guard node.port != port else { return }
                node.port = port
                node.updatedAt = .now
              }
            }
          ) {
            Text(verbatim: String(node.port))
              .frame(maxWidth: .infinity, alignment: .trailing)
          } editor: { focus, _ in
            TextField("端口", text: $portDraft)
              .labelsHidden()
              .focused(focus)
              .multilineTextAlignment(.trailing)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          .help("点击修改端口")
          .accessibilityIdentifier("node-port")
        }

        LabeledContent("加密方法") {
          Picker("加密方法", selection: $node.cipher) {
            ForEach(ProxyCipher.allCases, id: \.rawValue) { cipher in
              Text(cipher.rawValue)
                .tag(cipher.rawValue)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .onChange(of: node.cipher) { _, _ in
            save { node.updatedAt = .now }
          }
          .accessibilityIdentifier("node-cipher")
        }

        LabeledContent("密码") {
          EditableFieldFormView(
            onEditingBegan: {
              passwordDraft = node.password
              return true
            },
            onEditingEnded: {
              save {
                guard !passwordDraft.isEmpty else {
                  throw MagentXError.invalidParameter(String(localized: "Password is required"))
                }
                guard node.password != passwordDraft else { return }
                node.password = passwordDraft
                node.updatedAt = .now
              }
            }
          ) {
            Text("••••••••")
              .frame(maxWidth: .infinity, alignment: .trailing)
          } editor: { focus, _ in
            SecureField("密码", text: $passwordDraft)
              .labelsHidden()
              .focused(focus)
              .multilineTextAlignment(.trailing)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          .help("点击修改密码")
          .accessibilityIdentifier("node-password")
        }

        LabeledContent("超时") {
          EditableFieldFormView(
            onEditingBegan: {
              timeoutDraft = String(node.timeout)
              return true
            },
            onEditingEnded: {
              save {
                let value = timeoutDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let timeout = TimeInterval(value), timeout.isFinite, timeout >= 1 else {
                  throw MagentXError.invalidParameter(
                    String(localized: "Timeout must be a positive integer")
                  )
                }
                guard node.timeout != timeout else { return }
                node.timeout = timeout
                node.updatedAt = .now
              }
            }
          ) {
            Text(
              "\(node.timeout.formatted(.number.grouping(.never).precision(.fractionLength(0...3)))) 秒"
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
          } editor: { focus, _ in
            TextField("超时", text: $timeoutDraft)
              .labelsHidden()
              .focused(focus)
              .multilineTextAlignment(.trailing)
              .frame(maxWidth: .infinity, alignment: .trailing)
          }
          .help("点击修改超时")
          .accessibilityIdentifier("node-timeout")
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .safeAreaInset(edge: .bottom) {
      HStack {
        Spacer()

        if #available(macOS 26.0, *) {
          Button(role: .destructive, action: onDelete) {
            Label("删除节点", systemImage: "trash")
              .foregroundStyle(.red)
              .padding(5)
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.glass(.clear.tint(.red)))
          .controlSize(.large)
          .buttonBorderShape(.circle)
          .help("删除节点")
          .accessibilityLabel("删除节点")
        } else {
          Button(role: .destructive, action: onDelete) {
            Label("删除节点", systemImage: "trash")
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.bordered)
          .controlSize(.large)
          .buttonBorderShape(.circle)
          .tint(.red)
          .help("删除节点")
          .accessibilityLabel("删除节点")
        }
      }
      .padding()
      .background(.bar)
    }
  }

  /// 在当前详情的保存边界执行字段校验和提交，错误交给页面展示，保留其他已绑定修改。
  private func save(_ changes: () throws -> Void) {
    // 删除后可能仍有旧编辑控件的失焦通知；先检查生命周期再读取或修改模型字段。
    guard node.modelContext != nil, !node.isDeleted else { return }
    do {
      try changes()
      if modelContext.hasChanges {
        try modelContext.save()
      }
    } catch {
      actionError = error.localizedDescription
    }
  }
}
