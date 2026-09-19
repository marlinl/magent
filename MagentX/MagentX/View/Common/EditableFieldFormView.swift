//
//  EditableFieldFormView.swift
//  MagentX
//
//  Created by MarlinL on 2026/9/19.
//

import AppKit
import SwiftUI

/// 在调用方提供的展示和编辑组件之间切换；字段绑定、校验和持久化由调用方负责。
///
/// 文本编辑器应将收到的焦点绑定传给 `.focused`。菜单或弹窗编辑器可关闭键盘失焦结束，
/// 并在选择完成后调用 `editor` 收到的结束闭包；点击字段外部仍会结束编辑。
/// 当字段对应的记录变化时，调用方应通过 `.id(record.id)` 重建组件，隔离旧编辑会话。
@MainActor
struct EditableFieldFormView<Display: View, Editor: View>: View {
  private let isEditable: Bool
  private let endsOnFocusLoss: Bool
  private let onEditingBegan: () -> Bool
  private let onEditingEnded: () -> Void
  private let display: () -> Display
  private let editor: (FocusState<Bool>.Binding, @escaping () -> Void) -> Editor

  @State private var editingSession: UUID?
  @FocusState private var isFocused: Bool

  /// 配置字段交互，不读取或创建任何数据上下文。
  ///
  /// - Parameters:
  ///   - isEditable: 是否允许从展示状态进入编辑状态。
  ///   - endsOnFocusLoss: 是否在编辑控件失去键盘焦点时结束，菜单或弹窗可设为 false。
  ///   - onEditingBegan: 进入前准备草稿；返回 false 可阻止进入，例如前一字段校验失败。
  ///   - onEditingEnded: 每次编辑会话结束仅通知一次，由调用方校验、保存及展示错误。
  ///   - display: 非编辑状态的内容，不需要自行包装点击按钮。
  ///   - editor: 编辑内容，接收焦点绑定和可主动结束当前会话的闭包。
  init(
    isEditable: Bool = true,
    endsOnFocusLoss: Bool = true,
    onEditingBegan: @escaping () -> Bool = { true },
    onEditingEnded: @escaping () -> Void = {},
    @ViewBuilder display: @escaping () -> Display,
    @ViewBuilder editor: @escaping (FocusState<Bool>.Binding, @escaping () -> Void) -> Editor
  ) {
    self.isEditable = isEditable
    self.endsOnFocusLoss = endsOnFocusLoss
    self.onEditingBegan = onEditingBegan
    self.onEditingEnded = onEditingEnded
    self.display = display
    self.editor = editor
  }

  var body: some View {
    Group {
      if let session = editingSession {
        editor($isFocused, { finishEditing(session) })
          .onDisappear { finishEditing(session) }
          .task {
            // 等待编辑控件加入原生视图层级后再请求焦点。
            await Task.yield()
            if !Task.isCancelled, endsOnFocusLoss, editingSession == session {
              isFocused = true
            }
          }
          .onSubmit { finishEditing(session) }
          .onChange(of: isFocused) { wasFocused, isFocused in
            if endsOnFocusLoss, wasFocused, !isFocused {
              finishEditing(session)
            }
          }
          .background {
            EditingBoundary { finishEditing(session) }
              .allowsHitTesting(false)
          }
      } else if isEditable {
        Button {
          guard onEditingBegan() else { return }
          editingSession = UUID()
        } label: {
          display()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      } else {
        display()
      }
    }
    .onChange(of: isEditable) { _, isEditable in
      if !isEditable, let session = editingSession {
        finishEditing(session)
      }
    }
  }

  /// 结束指定会话；过期的鼠标或焦点回调不能结束之后开启的新会话。
  private func finishEditing(_ session: UUID) {
    guard editingSession == session else { return }
    editingSession = nil
    isFocused = false
    onEditingEnded()
  }

  /// 补充 macOS 点击空白处不改变键盘焦点的行为，不参与控件的鼠标命中。
  private struct EditingBoundary: NSViewRepresentable {
    let onExit: () -> Void

    /// 创建字段边界探针，监听资源随原生视图的窗口归属管理。
    func makeNSView(context: Context) -> ProbeView {
      let view = ProbeView()
      view.onExit = onExit
      return view
    }

    /// 让原生探针使用当前编辑会话的退出回调。
    func updateNSView(_ view: ProbeView, context: Context) {
      view.onExit = onExit
    }

    /// 在编辑器移除时释放全部监听资源。
    static func dismantleNSView(_ view: ProbeView, coordinator: Void) {
      view.stopMonitoring()
    }
  }

  /// 观察同一窗口中的字段外点击和窗口失焦，不把菜单窗口中的选择误认为字段外点击。
  private final class ProbeView: NSView {
    var onExit: () -> Void = {}
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    private var isTrackingMenu = false

    /// 探针始终透传鼠标事件，由调用方提供的原生控件处理交互。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 窗口发生变化时重新安装监听，离开窗口时释放监听。
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopMonitoring()
      guard let window else { return }

      for (notification, isTracking) in [
        (NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false),
      ] {
        menuObservers.append(
          NotificationCenter.default.addObserver(
            forName: notification, object: nil, queue: .main
          ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isTrackingMenu = isTracking }
          })
      }
      mouseMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
      ) { [weak self] event in
        guard let self, let window = self.window, event.window === window,
          !self.bounds.contains(self.convert(event.locationInWindow, from: nil))
        else { return event }

        // 保留事件发生时的会话，避免排队的旧点击结束新开启的编辑器。
        let onExit = self.onExit
        Task { @MainActor [weak self] in
          guard let self, !self.isTrackingMenu else { return }
          onExit()
        }
        return event
      }
      resignObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: window, queue: .main
      ) { [weak self, weak window] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          let onExit = self.onExit
          Task { @MainActor [weak self, weak window] in
            guard let self, !self.isTrackingMenu, let window, window.attachedSheet == nil,
              NSApp.keyWindow?.parent !== window
            else { return }
            onExit()
          }
        }
      }
    }

    /// 删除鼠标和窗口通知观察器，避免已消失字段继续收到输入事件。
    func stopMonitoring() {
      if let mouseMonitor {
        NSEvent.removeMonitor(mouseMonitor)
        self.mouseMonitor = nil
      }
      if let resignObserver {
        NotificationCenter.default.removeObserver(resignObserver)
        self.resignObserver = nil
      }
      for observer in menuObservers {
        NotificationCenter.default.removeObserver(observer)
      }
      menuObservers.removeAll()
      isTrackingMenu = false
    }
  }
}
