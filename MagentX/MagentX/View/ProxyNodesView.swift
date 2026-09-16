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
  @State private var proxyNodeViewModel: ProxyNodeViewModel?

  private static let pageSize = 100

  var body: some View {
    ProxyNodePageView(
      pageAt: $pageAt,
      pageSize: Self.pageSize,
      selectedNodeID: $selectedNodeID,
      proxyNodeViewModel: $proxyNodeViewModel
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      toolbarButtons = [
        ContentToolbarButton(title: "添加代理节点", systemImage: "plus") {
          proxyNodeViewModel = ProxyNodeViewModel(
            modelContainer: modelContext.container
          )
        }
      ]
    }
    .sheet(item: $proxyNodeViewModel) { viewModel in
      ProxyNodeFormView(
        proxyNodeViewModel: viewModel,
        onSaved: { nodeID in
          selectedNodeID = nodeID
          if viewModel.isNew,
            let storedNodeCount = try? modelContext.fetchCount(
              FetchDescriptor<MagentProxyNode>()
            )
          {
            pageAt = max(1, (storedNodeCount - 1) / Self.pageSize + 1)
          }
        }
      )
    }
  }

  /// 使用当前页对应的 `FetchDescriptor` 观察并展示最多 100 个代理节点。
  private struct ProxyNodePageView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var nodes: [MagentProxyNode]
    @Binding private var pageAt: Int
    @Binding private var selectedNodeID: UUID?
    @Binding private var proxyNodeViewModel: ProxyNodeViewModel?
    @State private var editError: String?

    private let pageSize: Int

    /// 为指定页创建按节点 id 正序排列的 SwiftData 查询。
    init(
      pageAt: Binding<Int>,
      pageSize: Int,
      selectedNodeID: Binding<UUID?>,
      proxyNodeViewModel: Binding<ProxyNodeViewModel?>
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
      _proxyNodeViewModel = proxyNodeViewModel
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
                node.name,
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
              Menu {
                Button {
                  do {
                    proxyNodeViewModel = try ProxyNodeViewModel(
                      modelContainer: modelContext.container,
                      nodeID: node.id
                    )
                    editError = nil
                  } catch {
                    editError = error.localizedDescription
                  }
                } label: {
                  Label("修改节点", systemImage: "pencil")
                }

                Button(role: .destructive) {
                  if proxyNodeViewModel?.id == node.id {
                    proxyNodeViewModel = nil
                  }
                  if selectedNodeID == node.id {
                    selectedNodeID = nil
                  }
                  modelContext.delete(node)
                } label: {
                  Label("删除节点", systemImage: "trash")
                }
              } label: {
                Label("节点操作", systemImage: "ellipsis.circle")
                  .labelStyle(.iconOnly)
              }
              .help("节点操作")
            }
            .width(min: 100, ideal: 140)
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        if pageAt > 1 || nodes.count > pageSize {
          ControlGroup {
            Button {
              pageAt -= 1
            } label: {
              Label("上一页", systemImage: "chevron.backward")
                .labelStyle(.iconOnly)
            }
            .disabled(pageAt <= 1)
            .help("上一页")

            Button {
              pageAt += 1
            } label: {
              Label("下一页", systemImage: "chevron.forward")
                .labelStyle(.iconOnly)
            }
            .disabled(nodes.count <= pageSize)
            .help("下一页")
          }
          .controlSize(.small)
          .padding(.vertical, 6)
        }
      }
      .alert(
        "读取代理节点失败",
        isPresented: Binding(
          get: { editError != nil },
          set: { isPresented in
            if isPresented == false {
              editError = nil
            }
          }
        )
      ) {
        Button("好", role: .cancel) {
          editError = nil
        }
      } message: {
        Text(editError ?? "")
      }
    }
  }

  /// 直接编辑独立 SwiftData 上下文中的代理节点，并内化保存与取消交互。
  private struct ProxyNodeFormView: View {
    @Environment(\.dismiss) private var dismiss
    let proxyNodeViewModel: ProxyNodeViewModel
    let onSaved: (UUID) -> Void
    @State private var saveError: String?

    private static let portRange = 1...65_535
    private static let timeoutFormatter: NumberFormatter = {
      let formatter = NumberFormatter()
      formatter.numberStyle = .none
      formatter.allowsFloats = false
      formatter.minimum = 1
      return formatter
    }()

    var body: some View {
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
        Section {
          TextField("名称（可选）", text: $node.name)

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
        ToolbarItem(placement: .cancellationAction) {
          Button("取消", role: .cancel) {
            proxyNodeViewModel.rollback()
            dismiss()
          }
          .keyboardShortcut(.cancelAction)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            do {
              try proxyNodeViewModel.save()
              saveError = nil
              onSaved(proxyNodeViewModel.id)
              dismiss()
            } catch {
              saveError = error.localizedDescription
            }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(addressError != nil)
        }
      }
      .onChange(of: node.port) { _, newValue in
        node.port = min(
          max(newValue, Self.portRange.lowerBound),
          Self.portRange.upperBound
        )
      }
      .onChange(of: node.timeout) { _, newValue in
        node.timeout = max(1, newValue)
      }
      .alert(
        "保存代理节点失败",
        isPresented: Binding(
          get: { saveError != nil },
          set: { isPresented in
            if isPresented == false {
              saveError = nil
            }
          }
        )
      ) {
        Button("好", role: .cancel) {
          saveError = nil
        }
      } message: {
        Text(saveError ?? "")
      }
      .onDisappear {
        proxyNodeViewModel.rollback()
      }
    }
  }
}
