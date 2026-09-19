//
//  ProxyNodesView.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Provides the proxy node list and direct SwiftData CRUD UI.
//

import AppKit
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
  @State private var draftValue = ""
  @State private var editingNodeID: UUID?
  @State private var editingField: ProxyNodeEditableField?
  @FocusState private var isFieldFocused: Bool

  private static let maximumCachedModelCount = 300

  var body: some View {
    HSplitView {
      ProxyNodeTableView(
        maximumCachedModelCount: Self.maximumCachedModelCount,
        selectedNodeID: selectedNode?.id
      ) { nodeID in
        guard update() else { return }
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
          actionError = nil
        } catch {
          actionError = error.localizedDescription
        }
      }
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

              Picker("类型", selection: $node.type) {
                ForEach(ProxyNodeType.allCases, id: \.rawValue) { type in
                  Text(type.rawValue)
                    .tag(type.rawValue)
                }
              }
              .pickerStyle(.menu)

              TextField("地址", text: $node.address)
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
          let formattedTimeout = selectedNode.timeout.formatted(
            .number.grouping(.never).precision(.fractionLength(0...3))
          )

          Form {
            Section("节点详情") {
              LabeledContent("名称") {
                if editingField == .name {
                  TextField("名称", text: $draftValue)
                    .accessibilityIdentifier("node-name")
                    .labelsHidden()
                    .focused($isFieldFocused)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onAppear {
                      Task { @MainActor in
                        isFieldFocused = true
                      }
                    }
                    .background {
                      ProxyNodeFieldEditingBoundary(onClickOutside: {
                        if editingField == .name {
                          _ = update()
                        }
                      })
                      .allowsHitTesting(false)
                    }
                    .onSubmit {
                      _ = update()
                    }
                    .onChange(of: isFieldFocused) { _, isFocused in
                      if isFocused == false {
                        _ = update()
                      }
                    }
                } else {
                  Button {
                    if update() {
                      draftValue = selectedNode.name
                      editingNodeID = selectedNode.id
                      editingField = .name
                    }
                  } label: {
                    Text(selectedNode.name)
                      .frame(maxWidth: .infinity, alignment: .trailing)
                      .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                  .help("点击修改名称")
                  .accessibilityIdentifier("node-name")
                }
              }

              LabeledContent("类型") {
                Picker(
                  "类型",
                  selection: Binding(
                    get: { selectedNode.type },
                    set: { type in
                      guard type != selectedNode.type, update() else { return }
                      draftValue = type
                      editingNodeID = selectedNode.id
                      editingField = .type
                      _ = update()
                    }
                  )
                ) {
                  ForEach(ProxyNodeType.allCases, id: \.rawValue) { type in
                    Text(type.rawValue)
                      .tag(type.rawValue)
                  }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .trailing)
              }
            }

            Section("连接") {
              LabeledContent("地址") {
                if editingField == .address {
                  TextField("地址", text: $draftValue)
                    .labelsHidden()
                    .focused($isFieldFocused)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onAppear {
                      Task { @MainActor in
                        isFieldFocused = true
                      }
                    }
                    .background {
                      ProxyNodeFieldEditingBoundary(onClickOutside: {
                        if editingField == .address {
                          _ = update()
                        }
                      })
                      .allowsHitTesting(false)
                    }
                    .onSubmit {
                      _ = update()
                    }
                    .onChange(of: isFieldFocused) { _, isFocused in
                      if isFocused == false {
                        _ = update()
                      }
                    }
                } else {
                  Button {
                    if update() {
                      draftValue = selectedNode.address
                      editingNodeID = selectedNode.id
                      editingField = .address
                    }
                  } label: {
                    Text(selectedNode.address)
                      .frame(maxWidth: .infinity, alignment: .trailing)
                      .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                  .help("点击修改地址")
                }
              }

              LabeledContent("端口") {
                if editingField == .port {
                  TextField("端口", text: $draftValue)
                    .accessibilityIdentifier("node-port")
                    .labelsHidden()
                    .focused($isFieldFocused)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onAppear {
                      Task { @MainActor in
                        isFieldFocused = true
                      }
                    }
                    .background {
                      ProxyNodeFieldEditingBoundary(onClickOutside: {
                        if editingField == .port {
                          _ = update()
                        }
                      })
                      .allowsHitTesting(false)
                    }
                    .onSubmit {
                      _ = update()
                    }
                    .onChange(of: isFieldFocused) { _, isFocused in
                      if isFocused == false {
                        _ = update()
                      }
                    }
                } else {
                  Button {
                    if update() {
                      draftValue = String(selectedNode.port)
                      editingNodeID = selectedNode.id
                      editingField = .port
                    }
                  } label: {
                    Text(verbatim: String(selectedNode.port))
                      .frame(maxWidth: .infinity, alignment: .trailing)
                      .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                  .help("点击修改端口")
                  .accessibilityIdentifier("node-port")
                }
              }
              LabeledContent("加密方法") {
                Picker(
                  "加密方法",
                  selection: Binding(
                    get: { selectedNode.cipher },
                    set: { cipher in
                      guard cipher != selectedNode.cipher, update() else { return }
                      draftValue = cipher
                      editingNodeID = selectedNode.id
                      editingField = .cipher
                      _ = update()
                    }
                  )
                ) {
                  ForEach(ProxyCipher.allCases, id: \.rawValue) { cipher in
                    Text(cipher.rawValue)
                      .tag(cipher.rawValue)
                  }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .trailing)
              }
              LabeledContent("密码") {
                if editingField == .password {
                  SecureField("密码", text: $draftValue)
                    .labelsHidden()
                    .focused($isFieldFocused)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onAppear {
                      Task { @MainActor in
                        isFieldFocused = true
                      }
                    }
                    .background {
                      ProxyNodeFieldEditingBoundary(onClickOutside: {
                        if editingField == .password {
                          _ = update()
                        }
                      })
                      .allowsHitTesting(false)
                    }
                    .onSubmit {
                      _ = update()
                    }
                    .onChange(of: isFieldFocused) { _, isFocused in
                      if isFocused == false {
                        _ = update()
                      }
                    }
                } else {
                  Button {
                    if update() {
                      draftValue = selectedNode.password
                      editingNodeID = selectedNode.id
                      editingField = .password
                    }
                  } label: {
                    Text("••••••••")
                      .frame(maxWidth: .infinity, alignment: .trailing)
                      .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                  .help("点击修改密码")
                }
              }
              LabeledContent("超时") {
                if editingField == .timeout {
                  TextField("超时", text: $draftValue)
                    .labelsHidden()
                    .focused($isFieldFocused)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onAppear {
                      Task { @MainActor in
                        isFieldFocused = true
                      }
                    }
                    .background {
                      ProxyNodeFieldEditingBoundary(onClickOutside: {
                        if editingField == .timeout {
                          _ = update()
                        }
                      })
                      .allowsHitTesting(false)
                    }
                    .onSubmit {
                      _ = update()
                    }
                    .onChange(of: isFieldFocused) { _, isFocused in
                      if isFocused == false {
                        _ = update()
                      }
                    }
                } else {
                  Button {
                    if update() {
                      draftValue = formattedTimeout
                      editingNodeID = selectedNode.id
                      editingField = .timeout
                    }
                  } label: {
                    Text("\(formattedTimeout) 秒")
                      .frame(maxWidth: .infinity, alignment: .trailing)
                      .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                  .help("点击修改超时")
                }
              }
            }
          }
          .formStyle(.grouped)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .safeAreaInset(edge: .bottom) {
            HStack {
              Spacer()

              if #available(macOS 26.0, *) {
                Button(role: .destructive) {
                  if update() {
                    delete(selectedNode)
                  }
                } label: {
                  Label("删除节点", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .controlSize(.small)
                .buttonBorderShape(.circle)
                .tint(.red)
                .help("删除节点")
                .accessibilityLabel("删除节点")
              } else {
                Button(role: .destructive) {
                  if update() {
                    delete(selectedNode)
                  }
                } label: {
                  Label("删除节点", systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .buttonBorderShape(.circle)
                .tint(.red)
                .help("删除节点")
                .accessibilityLabel("删除节点")
              }
            }
            .padding()
            .background(.bar)
          }
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

  /// 打开右侧的新节点表单，并在进入前提交正在编辑的节点字段。
  private func add() {
    guard update() else { return }

    proxyNodeViewModel?.rollback()
    proxyNodeViewModel = ProxyNodeViewModel(modelContainer: modelContext.container)
    actionError = nil
  }

  /// 提交稳定编辑标识对应节点字段的修改，并在持久化失败时恢复原有节点数据。
  ///
  /// - Returns: 未编辑或提交成功时返回 true；查找或保存失败时返回 false。
  private func update() -> Bool {
    guard let editingNodeID, let editingField else { return true }
    defer {
      self.editingNodeID = nil
      self.editingField = nil
      isFieldFocused = false
    }

    do {
      let targetNodeID = editingNodeID
      let descriptor = FetchDescriptor<MagentProxyNode>(
        predicate: #Predicate<MagentProxyNode> { node in
          node.id == targetNodeID
        }
      )
      guard let editingNode = try modelContext.fetch(descriptor).first else {
        throw MagentXError.missingMagentProxyNode(editingNodeID)
      }

      let value =
        if editingField == .password {
          draftValue
        } else {
          draftValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
      switch editingField {
      case .name:
        let resolvedName = value.isEmpty ? "\(editingNode.address):\(editingNode.port)" : value
        guard resolvedName != editingNode.name else { return true }
        editingNode.name = resolvedName
      case .address:
        guard value.isEmpty == false, MagentProxyNode.isValidAddress(value) else {
          throw MagentXError.invalidParameter(
            String(localized: "Address must be a hostname, IPv4 address, or IPv6 address")
          )
        }
        guard value != editingNode.address else { return true }
        editingNode.address = value
      case .type:
        guard ProxyNodeType(rawValue: value) != nil else {
          throw MagentXError.invalidParameter(
            String(format: String(localized: "Proxy node type is invalid: %@"), value)
          )
        }
        guard value != editingNode.type else { return true }
        editingNode.type = value
      case .port:
        guard let port = Int(value), (1...65_535).contains(port) else {
          throw MagentXError.invalidParameter(
            String(localized: "Port must be an integer from 1 to 65535")
          )
        }
        guard port != editingNode.port else { return true }
        editingNode.port = port
      case .cipher:
        guard ProxyCipher(rawValue: value) != nil else {
          throw MagentXError.invalidParameter(
            String(format: String(localized: "Proxy cipher is invalid: %@"), value)
          )
        }
        guard value != editingNode.cipher else { return true }
        editingNode.cipher = value
      case .password:
        guard value.isEmpty == false else {
          throw MagentXError.invalidParameter(String(localized: "Password is required"))
        }
        guard value != editingNode.password else { return true }
        editingNode.password = value
      case .timeout:
        guard let timeout = TimeInterval(value), timeout.isFinite, timeout >= 1 else {
          throw MagentXError.invalidParameter(
            String(localized: "Timeout must be a positive integer")
          )
        }
        guard timeout != editingNode.timeout else { return true }
        editingNode.timeout = timeout
      }
      editingNode.updatedAt = .now
      try modelContext.save()
      draftValue =
        switch editingField {
        case .name:
          editingNode.name
        case .address:
          editingNode.address
        case .type:
          editingNode.type
        case .port:
          String(editingNode.port)
        case .cipher:
          editingNode.cipher
        case .password:
          editingNode.password
        case .timeout:
          editingNode.timeout.formatted(
            .number.grouping(.never).precision(.fractionLength(0...3))
          )
        }
      actionError = nil
      return true
    } catch {
      modelContext.rollback()
      draftValue = ""
      actionError = error.localizedDescription
      return false
    }
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
      editingNodeID = nil
      editingField = nil
      actionError = nil
    } catch {
      modelContext.rollback()
      actionError = error.localizedDescription
    }
  }

  /// 标识当前右侧详情中正在以内联控件修改的节点字段。
  private enum ProxyNodeEditableField {
    case name
    case address
    case type
    case port
    case cipher
    case password
    case timeout
  }

  /// 以有限查询窗口双向浏览节点，并将单项选择交给父级详情区域。
  private struct ProxyNodeTableView: View {
    let maximumCachedModelCount: Int
    let selectedNodeID: UUID?
    let onSelectionChange: (UUID?) -> Void

    var body: some View {
      ScrollTableView(
        selection: Binding(
          get: { selectedNodeID },
          set: { nodeID in
            guard nodeID != selectedNodeID else { return }
            onSelectionChange(nodeID)
          }
        ),
        // id 排序保持不变；300 只限制缓存，不能作为可浏览结果的总上限。
        descriptor: FetchDescriptor<MagentProxyNode>(
          sortBy: [SortDescriptor(\MagentProxyNode.id, order: .forward)]
        ),
        queryID: "proxy-nodes",
        maximumCachedModelCount: maximumCachedModelCount
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
    }
  }

  /// 在节点字段输入框存在期间监听发生在其原生边界之外的鼠标点击。
  private struct ProxyNodeFieldEditingBoundary: NSViewRepresentable {
    let onClickOutside: () -> Void

    /// 创建并启动原生点击探针。
    func makeNSView(context: Context) -> ProxyNodeFieldEditingProbeView {
      let probeView = ProxyNodeFieldEditingProbeView()
      probeView.onClickOutside = onClickOutside
      probeView.startMonitoring()
      return probeView
    }

    /// 更新点击回调，确保重建后的 SwiftUI 闭包仍被调用。
    func updateNSView(_ nsView: ProxyNodeFieldEditingProbeView, context: Context) {
      nsView.onClickOutside = onClickOutside
      nsView.startMonitoring()
    }

    /// 在输入框移除时释放本地鼠标与窗口焦点监听。
    static func dismantleNSView(
      _ nsView: ProxyNodeFieldEditingProbeView,
      coordinator: Void
    ) {
      nsView.stopMonitoring()
    }
  }

  /// 以节点字段输入框的原生边界判断一次鼠标点击是否发生在输入框外。
  @MainActor
  private final class ProxyNodeFieldEditingProbeView: NSView {
    var onClickOutside: () -> Void = {}
    private var localMouseMonitor: Any?
    private var windowDidResignObserver: NSObjectProtocol?

    /// 在视图加入或移出窗口时同步点击监听的生命周期。
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil {
        stopMonitoring()
      } else {
        startMonitoring()
      }
    }

    /// 开始监听同一窗口外的鼠标按下和窗口失焦事件。
    func startMonitoring() {
      observeWindowResignation()
      guard localMouseMonitor == nil else { return }

      localMouseMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
      ) { [weak self] event in
        guard let self else { return event }

        if let window, event.window === window,
          bounds.contains(convert(event.locationInWindow, from: nil))
        {
          return event
        }

        Task { @MainActor [weak self] in
          self?.onClickOutside()
        }
        return event
      }
    }

    /// 停止鼠标与窗口失焦监听并释放关联资源。
    func stopMonitoring() {
      if let localMouseMonitor {
        NSEvent.removeMonitor(localMouseMonitor)
        self.localMouseMonitor = nil
      }
      if let windowDidResignObserver {
        NotificationCenter.default.removeObserver(windowDidResignObserver)
        self.windowDidResignObserver = nil
      }
    }

    /// 观察宿主窗口失去键盘焦点并提交字段编辑。
    private func observeWindowResignation() {
      guard let window, windowDidResignObserver == nil else { return }
      windowDidResignObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.onClickOutside()
        }
      }
    }
  }
}
