import AppKit
import SwiftData
import SwiftUI

/// 测试记录使用递增业务标识，便于检查窗口范围、顺序和重复行。
@Model
final class ScrollTableTestRow {
  @Attribute(.unique) var id: Int
  var title: String

  /// 创建可直接通过辅助功能定位的确定性记录。
  init(id: Int) {
    self.id = id
    title = String(format: "Row %05d", id)
  }
}

/// 表格和节点页的测试专用宿主，直接加载产品源文件，不初始化代理和用户数据库。
@main
struct ScrollTableHost: App {
  private let container: ModelContainer
  private let faults = ScrollTableFaults()

  /// 按启动环境准备隔离内存模型；仅故障用例使用可抛错的快照 DataStore。
  init() {
    do {
      if ProcessInfo.processInfo.environment["UI_TEST_VIEW"] == "proxy-nodes"
        || ProcessInfo.processInfo.environment["UI_TEST_VIEW"] == "editable-field"
      {
        container = try ProxyNodesFixture.makeContainer()
        return
      }
      let schema = Schema([ScrollTableTestRow.self])
      let backing = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
      if ProcessInfo.processInfo.environment["TABLE_FAULTS"] == "1" {
        container = try ModelContainer(
          for: schema,
          configurations: [
            ScrollTableFaultConfiguration(schema: schema, faults: faults)
          ])
      } else {
        container = try ModelContainer(for: schema, configurations: backing)
      }
      let count = Int(ProcessInfo.processInfo.environment["TABLE_COUNT"] ?? "2405") ?? 2405
      for id in 0..<count { container.mainContext.insert(ScrollTableTestRow(id: id + 1)) }
      try container.mainContext.save()
      if ProcessInfo.processInfo.environment["TABLE_INITIAL_FAILURE"] == "1" {
        faults.set("initial-query")
      }
    } catch {
      fatalError("测试数据初始化失败：\(error)")
    }
  }

  var body: some Scene {
    WindowGroup("ScrollTable 测试") {
      Group {
        if ProcessInfo.processInfo.environment["UI_TEST_VIEW"] == "proxy-nodes" {
          ProxyNodesFixture()
        } else if ProcessInfo.processInfo.environment["UI_TEST_VIEW"] == "editable-field" {
          EditableFieldFormFixture()
        } else {
          ScrollTableFixture(faults: faults)
        }
      }
      .modelContainer(container)
    }
    .defaultSize(width: 900, height: 640)
  }
}

/// 仅供 UI 测试操作的控制面板，所有数据变更仍经过真实 SwiftData 上下文。
private struct ScrollTableFixture: View {
  @Environment(\.modelContext) private var modelContext
  @State private var selection: Int?
  @State private var otherSelection: Int?
  @State private var search = ""
  @State private var descending = false
  @State private var isVisible = true
  @State private var reducedCapacity = false
  @State private var error: String?
  @State private var bounceReset = 0
  @State private var bounceReport = ""
  let faults: ScrollTableFaults

  private let environment = ProcessInfo.processInfo.environment
  private var pageSize: Int { Int(environment["TABLE_PAGE"] ?? "100") ?? 100 }
  private var maximumCachedModelCount: Int {
    reducedCapacity ? max(pageSize, 150) : (Int(environment["TABLE_CAPACITY"] ?? "1000") ?? 1000)
  }

  var body: some View {
    let text = search
    let descriptor: FetchDescriptor<ScrollTableTestRow> = {
      var value = FetchDescriptor<ScrollTableTestRow>(
        predicate: text.isEmpty ? nil : #Predicate { $0.title.contains(text) },
        sortBy: [SortDescriptor(\ScrollTableTestRow.id, order: descending ? .reverse : .forward)]
      )
      value.fetchOffset = Int(environment["TABLE_OFFSET"] ?? "0") ?? 0
      value.fetchLimit = environment["TABLE_LIMIT"].flatMap(Int.init)
      return value
    }()

    VStack(spacing: 8) {
      HStack {
        TextField("搜索", text: $search).accessibilityIdentifier("filter")
        Toggle("倒序", isOn: $descending).accessibilityIdentifier("reverse")
        Toggle("显示表格", isOn: $isVisible).accessibilityIdentifier("visible")
        Toggle("缩小缓存", isOn: $reducedCapacity).accessibilityIdentifier("capacity")
      }
      HStack {
        Button("删除选中") { mutate(.selected) }.accessibilityIdentifier("delete-selected")
        Button("仅留前50条") { mutate(.tail) }.accessibilityIdentifier("delete-tail")
        Button("清空") { mutate(.all) }.accessibilityIdentifier("delete-all")
        Button("增加25条") { mutate(.append) }.accessibilityIdentifier("append")
        Text("selected:\(selection.map(String.init) ?? "none")")
          .accessibilityIdentifier("selection")
      }
      if environment["TABLE_FAULTS"] == "1" {
        HStack {
          Button("计数失败") { faults.set("count") }.accessibilityIdentifier("fail-count")
          Button("查询失败") { faults.set("query") }.accessibilityIdentifier("fail-query")
          Button("恢复查询") { faults.set("none") }.accessibilityIdentifier("recover")
        }
      }
      if environment["TABLE_BOUNCE"] == "1" {
        HStack {
          Button("重置回弹记录") { bounceReset += 1 }
            .accessibilityIdentifier("reset-bounce")
          Text(bounceReport).accessibilityIdentifier("bounce-report")
        }
      }
      if isVisible {
        HStack {
          ScrollTableView(
            selection: $selection, descriptor: descriptor, queryID: "\(search)|\(descending)",
            pageSize: pageSize, maximumCachedModelCount: maximumCachedModelCount,
            preloadProgress: Double(environment["TABLE_PROGRESS"] ?? "0.8") ?? 0.8
          ) {
            TableColumn("记录") { row in
              Text(row.title).accessibilityIdentifier("record-\(row.id)")
            }
            TableColumn("编号") { row in Text(row.id, format: .number) }
          }
          .accessibilityIdentifier("paged-table")
          .background {
            if environment["TABLE_BOUNCE"] == "1" {
              ScrollTableBounceProbe(reset: bounceReset) { bounceReport = $0 }
            }
          }
          if environment["TABLE_SECOND"] == "1" {
            ScrollTableView(selection: $otherSelection, descriptor: descriptor, queryID: search) {
              TableColumn("另一张表") { row in Text(row.title) }
            }
            .accessibilityIdentifier("other-table")
          }
        }
      }
      if let error { Text(error).accessibilityIdentifier("fixture-error") }
    }
    .padding(12)
    .frame(minWidth: 800, minHeight: 560)
  }

  /// 明确区分删除、批量失效和追加三类会影响查询窗口的操作。
  private enum Mutation { case selected, tail, all, append }

  /// 修改内存数据库并显式保存，使 UI 测试覆盖 @Query 的实时更新行为。
  private func mutate(_ mutation: Mutation) {
    do {
      let rows = try modelContext.fetch(
        FetchDescriptor<ScrollTableTestRow>(
          sortBy: [SortDescriptor(\ScrollTableTestRow.id)]))
      switch mutation {
      case .selected:
        if let row = rows.first(where: { $0.id == selection }) { modelContext.delete(row) }
      case .tail:
        for row in rows where row.id > 50 { modelContext.delete(row) }
      case .all:
        for row in rows { modelContext.delete(row) }
      case .append:
        let last = rows.last?.id ?? 0
        for id in (last + 1)...(last + 25) { modelContext.insert(ScrollTableTestRow(id: id)) }
      }
      try modelContext.save()
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// 测试专用的只读原生探针，记录系统弹性设置及每次手势的最大越界位移。
/// 不设置弹性、不移动内容、不拦截输入，避免由夹具自身制造回弹通过结果。
private struct ScrollTableBounceProbe: NSViewRepresentable {
  let reset: Int
  let onReport: (String) -> Void

  /// 创建不参与命中的观测视图。
  func makeNSView(context: Context) -> Probe { Probe() }

  /// 更新结果回调，并在测试请求时重新开始测量。
  func updateNSView(_ view: Probe, context: Context) {
    view.onReport = onReport
    if view.reset != reset {
      view.reset = reset
      view.top = 0
      view.bottom = 0
    }
    DispatchQueue.main.async { [weak view] in view?.connect() }
  }

  /// 随宿主卸载移除全部通知监听。
  static func dismantleNSView(_ view: Probe, coordinator: ()) {
    NotificationCenter.default.removeObserver(view)
  }

  /// 仅通过公开的 NSScrollView 和 NSClipView API 观测原生回弹。
  final class Probe: NSView {
    var reset = -1
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    var onReport: ((String) -> Void)?
    private weak var scrollView: NSScrollView?
    private var report = ""

    /// 所有鼠标和滚轮事件继续由正式表格处理。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 初始布局完成后连接原生滚动视图。
    override func layout() {
      super.layout()
      if scrollView == nil { connect() }
    }

    /// 查找当前夹具表格并订阅边界变化，不访问正式观察器的私有状态。
    func connect() {
      if scrollView == nil {
        var ancestor = superview
        while let current = ancestor {
          if let table = findTable(in: current), let scrollView = table.enclosingScrollView {
            self.scrollView = scrollView
            NotificationCenter.default.addObserver(
              self, selector: #selector(record), name: NSView.boundsDidChangeNotification,
              object: scrollView.contentView)
            break
          }
          ancestor = current.superview
        }
      }
      record()
    }

    /// 递归定位探针所在可视区域的原生表格，避免连接到另一张表格。
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

    /// 采样越界峰值，供 XCTest 在系统动画结束后确认这一轮确实发生了回弹。
    @objc private func record() {
      guard let scrollView, let document = scrollView.documentView else { return }
      let clip = scrollView.contentView
      // 原生合法范围包含 Table 表头 inset，不能把表头偏移误判成回弹。
      let distance = max(document.frame.height, clip.bounds.height) + 1_000
      var proposed = clip.bounds
      proposed.origin.y = -distance
      let minimum = clip.constrainBoundsRect(proposed).minY
      proposed.origin.y = distance
      let maximum = clip.constrainBoundsRect(proposed).minY
      top = max(top, minimum - clip.bounds.minY)
      bottom = max(bottom, clip.bounds.minY - maximum)
      let next =
        "elasticity:\(scrollView.verticalScrollElasticity.rawValue)"
        + ";top:\(Int(top.rounded(.up)));bottom:\(Int(bottom.rounded(.up)))"
      guard next != report else { return }
      report = next
      DispatchQueue.main.async { [weak self] in self?.onReport?(next) }
    }
  }
}
