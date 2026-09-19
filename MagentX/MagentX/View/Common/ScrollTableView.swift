//
//  ScrollTableView.swift
//  MagentX
//
//  Responsibility: 以有限 SwiftData 查询窗口提供原生表格的双向滚动分页。
//

import AppKit
import SwiftData
import SwiftUI

/// 单选原生表格：初始查询一页，随后按滚动方向扩展或移动有限查询窗口。
///
/// 模型只由 @Query 持有；窗口之外的数据仍留在数据库中，淘汰不会删除记录。
@MainActor
struct ScrollTableView<Model, Columns>: View
where
  Model: PersistentModel, Columns: TableColumnContent,
  Columns.TableRowValue == Model
{
  @Environment(\.modelContext) private var modelContext
  @Binding private var selection: Model.ID?
  @State private var window: ScrollTableWindow
  @State private var previousWindow: ScrollTableWindow?
  @State private var loadError: String?
  @State private var reloadID = UUID()

  private let descriptor: FetchDescriptor<Model>
  private let configuration: Configuration
  private let columns: () -> Columns

  /// 查询语义及分页配置共同决定何时重新从第一页开始。
  private struct Configuration: Hashable {
    let queryID: AnyHashable
    let pageSize: Int
    let maximumCachedModelCount: Int
    let preloadProgress: Double
    let baseOffset: Int
    let resultLimit: Int?
  }

  /// 创建必须指定筛选与稳定排序的表格，支持至多选中一条记录。
  ///
  /// - Parameters:
  ///   - selection: 单项模型标识；没有选择时为 nil。
  ///   - descriptor: 基础查询，必须包含稳定排序，最后一项应以唯一字段消除并列。
  ///     原有 fetchOffset 和 fetchLimit 分别作为结果起点和可浏览结果总上限。
  ///   - queryID: 筛选或排序变化时必须同步改变，以重置窗口与选择。
  ///   - pageSize: 初始及每次请求的最大行数，默认 100，实际不超过缓存容量。
  ///   - maximumCachedModelCount: 当前查询最多持有的模型数，默认 1,000。
  ///   - preloadProgress: 末页已进入的比例，范围为 (0, 1)，默认 0.8；
  ///     向上进入首页的前 1 - preloadProgress 部分时对称加载前页。
  ///   - columns: 原生表格列定义。
  init<QueryID: Hashable>(
    selection: Binding<Model.ID?>,
    descriptor: FetchDescriptor<Model>,
    queryID: QueryID,
    pageSize: Int = 100,
    maximumCachedModelCount: Int = 1_000,
    preloadProgress: Double = 0.8,
    @TableColumnBuilder<Model, Never> columns: @escaping () -> Columns
  ) {
    precondition(pageSize > 0 && maximumCachedModelCount > 0)
    precondition(preloadProgress.isFinite && preloadProgress > 0 && preloadProgress < 1)
    precondition(!descriptor.sortBy.isEmpty, "分页查询必须包含稳定排序")
    precondition((descriptor.fetchOffset ?? 0) >= 0)
    precondition(descriptor.fetchLimit == nil || descriptor.fetchLimit! > 0)
    let pageSize = min(pageSize, maximumCachedModelCount)
    _selection = selection
    _window = State(
      initialValue: ScrollTableWindow(
        offset: 0, limit: min(pageSize, descriptor.fetchLimit ?? pageSize))
    )
    self.descriptor = descriptor
    configuration = Configuration(
      queryID: AnyHashable(queryID), pageSize: pageSize,
      maximumCachedModelCount: maximumCachedModelCount, preloadProgress: preloadProgress,
      baseOffset: descriptor.fetchOffset ?? 0, resultLimit: descriptor.fetchLimit
    )
    self.columns = columns
  }

  var body: some View {
    // 配置变化的这一轮布局也不能用旧窗口大小发起超过新容量的查询。
    let queriedWindow = ScrollTableWindow(
      offset: window.offset,
      limit: min(
        window.limit, configuration.maximumCachedModelCount,
        configuration.resultLimit ?? window.limit)
    )
    ScrollTableQueryView(
      selection: $selection, descriptor: descriptor, window: queriedWindow,
      pageSize: configuration.pageSize, preloadProgress: configuration.preloadProgress,
      columns: columns, onPage: loadPage, onResult: acceptQueryResult
    )
    .id(configuration)
    .id(reloadID)
    .onChange(of: configuration) { _, _ in
      resetWindow()
    }
    .alert(
      "加载表格失败",
      isPresented: Binding(
        get: { loadError != nil },
        set: { if !$0 { loadError = nil } }
      )
    ) {
      // 首批查询失败时没有可滚动的行，需要显式重建 @Query 才能重新加载。
      Button("重新加载") {
        loadError = nil
        reloadID = UUID()
      }
      Button("好", role: .cancel) { loadError = nil }
    } message: {
      Text(loadError ?? "")
    }
  }

  /// 按方向请求相邻数据；保留可见行，只有新查询成功后才完成窗口切换。
  ///
  /// 缓存接近一屏时可以少于整页地移动，避免一次淘汰仍可见的行。
  /// 若整份缓存已全部可见，只能在新的用户滚动事件中切换一页。
  /// - Returns: 是否发起了实际窗口切换，供滚动桥接冻结并恢复当前锚点。
  private func loadPage(_ direction: ScrollTableDirection, _ visibleRows: Range<Int>) -> Bool {
    guard previousWindow == nil, loadError == nil else { return false }
    do {
      var countDescriptor = descriptor
      countDescriptor.fetchOffset = nil
      countDescriptor.fetchLimit = nil
      let total = max(0, try modelContext.fetchCount(countDescriptor) - configuration.baseOffset)
      let available = min(total, configuration.resultLimit ?? total)
      let remaining = direction == .forward ? available - window.end : window.offset
      guard remaining > 0 else { return false }

      let free = max(0, configuration.maximumCachedModelCount - window.limit)
      let offscreen =
        direction == .forward
        ? visibleRows.lowerBound : max(0, window.limit - visibleRows.upperBound)
      var amount = min(configuration.pageSize, remaining)
      if offscreen > 0 || free > 0 {
        amount = min(amount, free + offscreen)
      } else if visibleRows.count < window.limit {
        // 极低预加载比例可能在第一页仍可见时触发；没有可淘汰行就继续等待滚动。
        return false
      }
      let nextLimit = min(configuration.maximumCachedModelCount, window.limit + amount)
      let nextOffset =
        direction == .forward
        ? window.offset + amount - (nextLimit - window.limit) : window.offset - amount
      previousWindow = window
      window = ScrollTableWindow(offset: nextOffset, limit: nextLimit)
      return true
    } catch {
      loadError = error.localizedDescription
      return false
    }
  }

  /// 接收真实 @Query 结果；失败回退，成功释放加载锁，并清理已移出窗口的选择。
  private func acceptQueryResult(
    _ resultWindow: ScrollTableWindow, _ identifiers: [Model.ID], _ error: String?
  ) {
    guard resultWindow == window else { return }
    if let error {
      if let previousWindow { window = previousWindow }
      previousWindow = nil
      loadError = error
      return
    }
    previousWindow = nil
    if let selection, !identifiers.contains(selection) { self.selection = nil }
    // 批量删除可能使非首窗口失效；回到第一页，空数据仍交给同一个原生 Table。
    if identifiers.isEmpty, window.offset > 0 { resetWindow() }
  }

  /// 查询或配置变化后重新加载首批数据，同时清除过期选择、错误和未完成切换。
  private func resetWindow() {
    previousWindow = nil
    window = ScrollTableWindow(
      offset: 0,
      limit: min(configuration.pageSize, configuration.resultLimit ?? configuration.pageSize)
    )
    selection = nil
    loadError = nil
  }
}

/// 只观察当前窗口，并把查询结果直接交给原生 Table，不另外缓存模型数组。
@MainActor
private struct ScrollTableQueryView<Model, Columns>: View
where
  Model: PersistentModel, Columns: TableColumnContent,
  Columns.TableRowValue == Model
{
  @Query private var models: [Model]
  @Binding private var selection: Model.ID?
  private let window: ScrollTableWindow
  private let pageSize: Int
  private let preloadProgress: Double
  private let columns: () -> Columns
  private let onPage: (ScrollTableDirection, Range<Int>) -> Bool
  private let onResult: (ScrollTableWindow, [Model.ID], String?) -> Void

  /// 将相对窗口叠加到调用方的基础偏移，始终在数据库查询中限制模型数量。
  init(
    selection: Binding<Model.ID?>, descriptor: FetchDescriptor<Model>, window: ScrollTableWindow,
    pageSize: Int, preloadProgress: Double,
    @TableColumnBuilder<Model, Never> columns: @escaping () -> Columns,
    onPage: @escaping (ScrollTableDirection, Range<Int>) -> Bool,
    onResult: @escaping (ScrollTableWindow, [Model.ID], String?) -> Void
  ) {
    var descriptor = descriptor
    descriptor.fetchOffset = (descriptor.fetchOffset ?? 0) + window.offset
    descriptor.fetchLimit = window.limit
    _models = Query(descriptor)
    _selection = selection
    self.window = window
    self.pageSize = pageSize
    self.preloadProgress = preloadProgress
    self.columns = columns
    self.onPage = onPage
    self.onResult = onResult
  }

  var body: some View {
    let identifiers = models.map(\.id)
    let error = _models.fetchError?.localizedDescription
    Table(models, selection: $selection, columns: columns)
      .background {
        ScrollTableScrollObserver(
          identifiers: identifiers.map(AnyHashable.init), window: window,
          pageSize: pageSize, preloadProgress: preloadProgress, onPage: onPage
        )
      }
      // 每次触顶、触底都保留纵向系统回弹，包括不足一屏的列表，不改变横向滚动策略。
      .scrollBounceBehavior(.always, axes: .vertical)
      .task(id: ResultIdentity(window: window, identifiers: identifiers, error: error)) {
        guard !Task.isCancelled else { return }
        onResult(window, identifiers, error)
      }
  }

  /// 窗口、记录或查询错误变化时都必须交付结果，包括记录数不变的换页。
  private struct ResultIdentity: Equatable {
    let window: ScrollTableWindow
    let identifiers: [Model.ID]
    let error: String?
  }
}

/// 当前查询相对于基础 FetchDescriptor 的有限范围。
private struct ScrollTableWindow: Equatable {
  let offset: Int
  let limit: Int
  var end: Int { offset + limit }
}

/// 用户滚动触发的查询窗口移动方向。
private enum ScrollTableDirection {
  case backward
  case forward
}

/// SwiftUI Table 不回传 ScrollView 的几何与锚点事件，使用原生表格补齐这两项能力。
///
/// 不接管表格的数据源、代理、列、选择或绘制；只保留行标识和一个像素级滚动锚点。
private struct ScrollTableScrollObserver: NSViewRepresentable {
  let identifiers: [AnyHashable]
  let window: ScrollTableWindow
  let pageSize: Int
  let preloadProgress: Double
  let onPage: (ScrollTableDirection, Range<Int>) -> Bool

  /// 创建不参与鼠标命中的滚动观察视图。
  func makeNSView(context: Context) -> Probe { Probe() }

  /// 更新行标识及配置，查询变化后的滚动补偿由原生布局完成后执行。
  func updateNSView(_ view: Probe, context: Context) {
    view.update(
      identifiers: identifiers, window: window, pageSize: pageSize,
      preloadProgress: preloadProgress, onPage: onPage
    )
  }

  /// 随 SwiftUI 视图销毁移除事件观察，避免残留监视器持有回调和查询窗口。
  static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stopMonitoring() }

  /// 观察自身所属的原生 Table，仅在真实输入事件之后发出分页请求。
  final class Probe: NSView {
    private weak var table: NSTableView?
    private var eventMonitor: Any?
    private var identifiers: [AnyHashable] = []
    private var queryWindow: ScrollTableWindow?
    private var pageSize = 100
    private var preloadProgress = 0.8
    private var onPage: ((ScrollTableDirection, Range<Int>) -> Bool)?
    private var anchor: (id: AnyHashable, row: Int, inset: CGFloat)?
    private var pendingDirection: ScrollTableDirection?
    private var updateGeneration = 0
    private var isRestoring = false
    private var isAwaitingKeyboardScroll = false
    private var lastScrollOrigin: CGFloat = 0

    /// 背景观察器始终让原生表格接收点击、选择和滚动事件。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 挂载窗口时建立观察，离开窗口时立即释放全部原生资源。
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil {
        stopMonitoring()
      } else {
        DispatchQueue.main.async { [weak self] in self?.startMonitoring() }
      }
    }

    /// 等背景取得实际尺寸后再匹配表格，避免初次零尺寸布局误连同窗口的其他表格。
    override func layout() {
      super.layout()
      if eventMonitor == nil { startMonitoring() }
    }

    /// 接收查询结果；窗口或行集变化时冻结输入直到锚点补偿完成。
    func update(
      identifiers: [AnyHashable], window: ScrollTableWindow, pageSize: Int,
      preloadProgress: Double, onPage: @escaping (ScrollTableDirection, Range<Int>) -> Bool
    ) {
      self.pageSize = pageSize
      self.preloadProgress = preloadProgress
      self.onPage = onPage
      guard self.identifiers != identifiers || queryWindow != window else { return }
      isAwaitingKeyboardScroll = false
      if identifiers.isEmpty { anchor = nil }
      self.identifiers = identifiers
      queryWindow = window
      updateGeneration += 1
      let generation = updateGeneration
      isRestoring = true
      DispatchQueue.main.async { [weak self] in
        guard let self, generation == self.updateGeneration else { return }
        self.startMonitoring()
        self.restorePosition()
      }
    }

    /// 从最近的公共祖先定位自身表格，并安装只作用于该表格的输入监视器。
    private func startMonitoring() {
      guard window != nil else { return }
      if table == nil {
        var ancestor = superview
        while let current = ancestor {
          if let found = findTable(in: current) {
            table = found
            break
          }
          ancestor = current.superview
        }
      }
      guard let scrollView = table?.enclosingScrollView, eventMonitor == nil else { return }
      lastScrollOrigin = scrollView.contentView.bounds.minY
      NotificationCenter.default.addObserver(
        self, selector: #selector(didScroll), name: NSScrollView.didLiveScrollNotification,
        object: scrollView)
      NotificationCenter.default.addObserver(
        self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification,
        object: scrollView.contentView)
      eventMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.scrollWheel, .keyDown, .leftMouseDown]
      ) { [weak self] event in
        self?.observeInput(event)
        return event
      }
    }

    /// 递归查找公开的 NSTableView，不依赖 SwiftUI 私有类名或层级深度。
    private func findTable(in view: NSView) -> NSTableView? {
      if let table = view as? NSTableView, let scrollView = table.enclosingScrollView,
        bounds.width > 0, bounds.height > 0,
        scrollView.convert(scrollView.bounds, to: self).contains(
          NSPoint(x: bounds.midX, y: bounds.midY))
      {
        return table
      }
      for child in view.subviews {
        if let table = findTable(in: child) { return table }
      }
      return nil
    }

    /// 跟随合法范围内的滚动与翻屏键动画，排除弹性越界及归位，避免误判反向翻页。
    @objc private func didScroll(_ notification: Notification) {
      guard let scrollView = table?.enclosingScrollView, !isRestoring, pendingDirection == nil
      else { return }
      let isKeyboardScroll = notification.name == NSView.boundsDidChangeNotification
      guard !isKeyboardScroll || isAwaitingKeyboardScroll else { return }
      let clip = scrollView.contentView
      var previousBounds = clip.bounds
      previousBounds.origin.y = lastScrollOrigin
      // 只归一化用于方向判断的坐标，不移动内容或干预原生回弹动画。
      let delta =
        clip.constrainBoundsRect(clip.bounds).minY
        - clip.constrainBoundsRect(previousBounds).minY
      guard delta != 0 else { return }
      let generation = updateGeneration
      DispatchQueue.main.async { [weak self] in
        guard let self, generation == self.updateGeneration else { return }
        self.requestPageIfNeeded(delta > 0 ? .forward : .backward)
      }
    }

    /// 在真实输入后检查边缘；未发生位移的小缓存和末端滚动也能请求相邻数据。
    private func observeInput(_ event: NSEvent) {
      guard let table, event.window === window, let scrollView = table.enclosingScrollView,
        !isRestoring, pendingDirection == nil
      else { return }
      // 新输入结束上一轮键盘跟踪，包括移到别的控件、点击标题栏或调整窗口。
      isAwaitingKeyboardScroll = false
      if event.type == .keyDown {
        guard let responder = window?.firstResponder as? NSView,
          responder === table || responder.isDescendant(of: scrollView)
        else { return }
      } else {
        let point = scrollView.convert(event.locationInWindow, from: nil)
        guard scrollView.bounds.contains(point) else { return }
      }
      var direction: ScrollTableDirection?
      if event.type == .scrollWheel, event.scrollingDeltaY != 0 {
        direction = event.scrollingDeltaY < 0 ? .forward : .backward
      } else if event.type == .keyDown {
        switch event.specialKey {
        case .downArrow: direction = .forward
        case .upArrow: direction = .backward
        case .pageDown, .end:
          direction = .forward
          isAwaitingKeyboardScroll = true
        case .pageUp, .home:
          direction = .backward
          isAwaitingKeyboardScroll = true
        default: break
        }
      }
      let generation = updateGeneration
      let inputDirection = direction
      DispatchQueue.main.async { [weak self] in
        guard let self, generation == self.updateGeneration else { return }
        if let inputDirection {
          self.requestPageIfNeeded(inputDirection)
        } else {
          self.captureAnchor()
        }
      }
    }

    /// 以实际可见行判断是否进入边缘页预加载区域，并冻结一次尚未完成的请求。
    private func requestPageIfNeeded(_ direction: ScrollTableDirection) {
      guard let table, !isRestoring, pendingDirection == nil,
        table.numberOfRows == identifiers.count, !identifiers.isEmpty
      else { return }
      captureAnchor()
      let range = table.rows(in: table.visibleRect)
      guard range.location != NSNotFound, range.length > 0 else { return }
      let visible = range.location..<min(NSMaxRange(range), identifiers.count)
      let margin = max(
        1, Int(ceil(Double(min(pageSize, identifiers.count)) * (1 - preloadProgress))))
      let shouldLoad =
        direction == .forward
        ? visible.upperBound >= identifiers.count - margin : visible.lowerBound <= margin
      guard shouldLoad else { return }
      isAwaitingKeyboardScroll = false
      pendingDirection = direction
      if onPage?(direction, visible) != true { pendingDirection = nil }
    }

    /// 记录首个可见行的业务标识与行内像素偏移，不持有任何 SwiftData 模型。
    private func captureAnchor() {
      guard let table, table.numberOfRows == identifiers.count else { return }
      let row = table.rows(in: table.visibleRect).location
      guard row != NSNotFound, identifiers.indices.contains(row) else { return }
      let origin = table.enclosingScrollView?.contentView.bounds.minY ?? table.visibleRect.minY
      lastScrollOrigin = origin
      anchor = (identifiers[row], row, origin - table.rect(ofRow: row).minY)
    }

    /// 查询回填后恢复同一记录和像素位置；缓存小于一屏时按滚动方向落在新窗口边缘。
    private func restorePosition() {
      guard let table, let scrollView = table.enclosingScrollView else {
        isRestoring = false
        pendingDirection = nil
        return
      }
      table.layoutSubtreeIfNeeded()
      let clip = scrollView.contentView
      // 查询切换前仍可能收到滚轮的后续事件，恢复时不能覆盖请求之后新增的真实位移。
      let pendingScrollDelta = pendingDirection == nil ? 0 : clip.bounds.minY - lastScrollOrigin
      // 首次布局保留系统的负向表头 inset；强制归零会把第一行藏到悬浮表头下面。
      var y = clip.bounds.minY
      if let anchor, let row = identifiers.firstIndex(of: anchor.id), row < table.numberOfRows {
        y = table.rect(ofRow: row).minY + anchor.inset + pendingScrollDelta
      } else if let anchor, pendingDirection == nil, table.numberOfRows > 0 {
        // 可见首行被删除时由相邻行接替，不能突然回到整个缓存的顶部。
        y = table.rect(ofRow: min(anchor.row, table.numberOfRows - 1)).minY + anchor.inset
      } else if pendingDirection == .backward {
        y = table.bounds.height - clip.bounds.height + clip.contentInsets.bottom
      } else if pendingDirection == .forward {
        y = -clip.contentInsets.top
      }
      var proposedBounds = clip.bounds
      proposedBounds.origin.y = y
      clip.scroll(to: clip.constrainBoundsRect(proposedBounds).origin)
      scrollView.reflectScrolledClipView(clip)
      pendingDirection = nil
      isRestoring = false
      captureAnchor()
    }

    /// 移除监视器并失效尚未执行的布局补偿，离开页面后不再处理输入。
    func stopMonitoring() {
      NotificationCenter.default.removeObserver(self)
      if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
      eventMonitor = nil
      table = nil
      updateGeneration += 1
      pendingDirection = nil
      isRestoring = false
      isAwaitingKeyboardScroll = false
    }
  }
}
