import XCTest

/// 对应 View/Common/ScrollTableView，通过内存夹具覆盖双向分页与查询生命周期。
@MainActor
final class ScrollTableViewUITests: XCTestCase {
  private var app: XCUIApplication!
  private var table: XCUIElement!
  private var rowType = XCUIElement.ElementType.outlineRow
  private var maximumCachedModelCount = 1000

  // SwiftUI Table 在 macOS 上可暴露为 Outline，按公开 AX 行类型兼容两种实现。
  private var rows: XCUIElementQuery {
    table.children(matching: rowType)
  }

  /// 失败后立即停止当前用例，保留最接近问题的屏幕与辅助功能证据。
  override func setUpWithError() throws { continueAfterFailure = false }

  /// 每个用例结束后关闭测试宿主，验证重新启动时没有残留分页状态。
  override func tearDown() async throws { app?.terminate() }

  // MARK: - 初始化与查询范围

  /// 初始滚动内容严格限制为100条，等待布局完成也不会自行继续加载。
  func testInitialPageDoesNotLoadWithoutInput() {
    launch()
    XCTAssertEqual(rows.count, 100)
    XCTAssertTrue(row(1).exists)
    XCTAssertFalse(row(101).exists)
    assertStableRows(100)
  }

  /// 空结果保留表头；插入后同一表格立即显示数据。
  func testEmptyTableAndInsertion() {
    launch(count: 0)
    XCTAssertEqual(rows.count, 0)
    app.buttons["append"].click()
    waitForRows(25)
    XCTAssertTrue(row(1).exists)
  }

  /// 不满一页时展示全部数据，多次触底仍保持最后的真实行数。
  func testShortResultStopsAtEnd() {
    launch(count: 7)
    scroll(-500)
    assertStableRows(7)
    XCTAssertTrue(row(7).exists)
  }

  /// 基础描述符的偏移和总上限都必须得到保留。
  func testDescriptorOffsetAndLimit() {
    launch(offset: 250, limit: 125)
    XCTAssertTrue(row(251).exists)
    reach(375)
    scroll(-2000)
    XCTAssertEqual(rows.count, 125)
    XCTAssertFalse(row(250).exists)
    XCTAssertFalse(row(376).exists)
  }

  /// 初始偏移超过结果总量时显示空表，而不是自动跳出调用方的查询范围。
  func testDescriptorOffsetBeyondResults() {
    launch(count: 50, offset: 80)
    scroll(-500)
    assertStableRows(0)
  }

  /// 调用方结果上限小于页大小时，首批与后续滚动都不能超出该上限。
  func testResultLimitSmallerThanPage() {
    launch(limit: 17)
    scroll(-1000)
    assertStableRows(17)
    XCTAssertTrue(row(17).exists)
    XCTAssertFalse(row(18).exists)
  }

  // MARK: - 双向分页与缓冲上限

  /// 向下滚动以追加方式扩展查询，已有行不会在缓存未满时被淘汰。
  func testForwardAppend() {
    launch()
    reach(200)
    XCTAssertTrue(row(1).exists)
    XCTAssertGreaterThanOrEqual(rows.count, 200)
    XCTAssertLessThanOrEqual(rows.count, 1000)
  }

  /// 跨过2000条后反向回到第一页，整个过程中最多观察1000条记录。
  func testRoundTripBeyondTwoThousandRows() {
    launch()
    let filter = app.textFields["filter"]
    filter.click()
    filter.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
    // End/Home 仍驱动原生表格滚动；分批检查容量，不读取尚未生成的离屏单元格。
    for _ in 0..<6 {
      for _ in 0..<5 { app.typeKey(XCUIKeyboardKey.end.rawValue, modifierFlags: []) }
      XCTAssertLessThanOrEqual(rows.count, 1000)
    }
    XCTAssertEqual(rows.count, 1000)
    XCTAssertTrue(row(2405).isHittable, table.debugDescription)
    for _ in 0..<6 {
      for _ in 0..<5 { app.typeKey(XCUIKeyboardKey.home.rawValue, modifierFlags: []) }
      XCTAssertLessThanOrEqual(rows.count, 1000)
    }
    XCTAssertTrue(row(1).isHittable)
    XCTAssertEqual(rows.count, 1000)
  }

  /// 缓存不是页大小的整数倍时仍守住容量，且能双向恢复记录。
  func testCustomNonMultipleCapacity() {
    launch(capacity: 175)
    reach(400)
    XCTAssertEqual(rows.count, 175)
    for _ in 0..<20 {
      if rowNumber(at: 0) == 1 { break }
      scroll(1500)
    }
    XCTAssertTrue(row(1).exists)
    XCTAssertLessThanOrEqual(rows.count, 175)
  }

  /// 一页缓存小于可见区域时，静止不会连翻；显式滚动仍可以前进并返回。
  func testViewportLargerThanBuffer() {
    launch(count: 100, page: 10, capacity: 10)
    assertStableRows(10)
    scroll(-20)
    XCTAssertFalse(row(1).exists)
    let last = rows.element(boundBy: 9).label
    assertStableRows(10)
    XCTAssertEqual(rows.element(boundBy: 9).label, last)
    scroll(20)
    XCTAssertTrue(row(1).exists)
  }

  /// 到达部分尾页后追加记录，下一次滚动可继续读取，不能缓存过期的触底状态。
  func testPartialLastPageAndAppendAfterEnd() {
    launch(count: 237, capacity: 175)
    reach(237)
    scroll(-2000)
    XCTAssertTrue(row(237).exists)
    XCTAssertFalse(row(238).exists)
    app.buttons["append"].click()
    reach(262)
    XCTAssertLessThanOrEqual(rows.count, 175)
  }

  /// 结果刚好整页结束时不额外产生空窗口。
  func testExactLastPage() {
    launch(count: 200)
    reach(200)
    scroll(-2000)
    assertStableRows(200)
  }

  /// 反复改变滚动方向不应卡住加载锁、重复数据或突破容量。
  func testRepeatedDirectionChanges() {
    launch(count: 500, capacity: 175)
    for _ in 0..<4 {
      reach(300)
      for _ in 0..<8 {
        if rowNumber(at: 0) == 1 { break }
        scroll(2000)
      }
      XCTAssertTrue(row(1).exists)
      XCTAssertLessThanOrEqual(rows.count, 175)
    }
  }

  /// 只缩小缓存、不指定页大小时自动收紧每次查询，最小一行缓存也不能跳过数据。
  func testSingleRowBufferClampsDefaultPageSize() {
    launch(count: 5, capacity: 1)
    XCTAssertTrue(row(1).exists)
    scroll(-20)
    waitForRows(1)
    XCTAssertTrue(row(2).exists)
    XCTAssertFalse(row(3).exists)
    scroll(20)
    XCTAssertTrue(row(1).exists)
  }

  /// 第一页向上越界不会请求负偏移，也不会改变首批内容。
  func testTopBoundaryKeepsFirstPage() {
    launch()
    scroll(2000)
    assertStableRows(100)
    XCTAssertTrue(row(1).exists)
  }

  /// 短列表不应因为内容不足一屏而禁用回弹，连续三次触顶和触底均保留原生弹性。
  func testRepeatedBounceWithShortContent() {
    launch(count: 7, bounce: true)
    for _ in 0..<3 {
      assertBounce(edge: "top")
      assertBounce(edge: "bottom")
      XCTAssertEqual(rows.count, 7)
    }
  }

  /// 内容可滚动时，连续触顶触底也必须发生越界位移，并且不产生空页。
  func testRepeatedBounceAtBothBoundaries() {
    launch(count: 100, bounce: true)
    for _ in 0..<3 { assertBounce(edge: "top") }
    scroll(-4000)
    XCTAssertTrue(row(100).isHittable)
    for _ in 0..<3 { assertBounce(edge: "bottom") }
    XCTAssertEqual(rows.count, 100)
  }

  /// 空表也保留原生纵向回弹，多次触边不能自动制造数据或丢掉表格。
  func testRepeatedBounceWithEmptyContent() {
    launch(count: 0, bounce: true)
    for _ in 0..<3 {
      assertBounce(edge: "top")
      assertBounce(edge: "bottom")
      XCTAssertEqual(rows.count, 0)
    }
  }

  /// 缓存淘汰、尾页补齐和搜索重置后，原生弹性不能被后续布局重新关闭。
  func testRepeatedBounceAfterPagingAndSearchReset() {
    launch(count: 237, capacity: 175, bounce: true)
    reach(237)
    scroll(-3000)
    XCTAssertTrue(row(237).isHittable)
    for _ in 0..<3 { assertBounce(edge: "bottom") }
    XCTAssertEqual(rows.count, 175)
    let filter = app.textFields["filter"]
    filter.click()
    filter.typeText("00001\n")
    waitForRows(1)
    for _ in 0..<3 {
      assertBounce(edge: "top")
      assertBounce(edge: "bottom")
    }
    XCTAssertTrue(row(1).exists)
  }

  /// 一行缓存触顶或触底后，回弹的反向归位都不能被误当成反向翻页。
  func testRepeatedBounceAtBoundariesWithSingleRowBuffer() {
    launch(count: 5, capacity: 1, bounce: true)
    reach(5)
    for _ in 0..<3 {
      assertBounce(edge: "bottom")
      XCTAssertTrue(row(5).exists)
      XCTAssertEqual(rows.count, 1)
    }
    for _ in 0..<5 { scroll(2000) }
    XCTAssertTrue(row(1).exists)
    for _ in 0..<3 {
      assertBounce(edge: "top")
      XCTAssertTrue(row(1).exists)
      XCTAssertEqual(rows.count, 1)
    }
  }

  // MARK: - 预加载配置与查询重置

  /// 同样滚动距离下，较低预加载比例应更早追加下一页。
  func testConfigurablePreloadProgress() {
    launch(progress: 0.95)
    scroll(-1000)
    let lateCount = rows.count
    app.terminate()
    launch(progress: 0.3)
    scroll(-1000)
    XCTAssertGreaterThan(rows.count, lateCount)
  }

  /// 极低预加载比例不能在缓存没有空位、且仍有未读行时跳过当前内容。
  func testEarlyPreloadDoesNotEvictVisibleRows() {
    launch(count: 237, capacity: 100, progress: 0.01)
    scroll(-1)
    XCTAssertTrue(row(1).exists)
    XCTAssertTrue(row(100).exists)
    XCTAssertFalse(row(101).exists)
    reach(237)
    scroll(-10_000)
    let first = rowNumber(at: 0)
    scroll(1)
    XCTAssertEqual(rowNumber(at: 0), first)
    XCTAssertTrue(row(237).exists)
  }

  /// 运行时降低缓存后重新加载首批，之后任何分页都不能突破新上限。
  func testCapacityChangeResetsWindow() {
    launch(capacity: 175)
    reach(400)
    app.checkBoxes["capacity"].click()
    maximumCachedModelCount = 150
    waitForRows(100)
    XCTAssertTrue(row(1).exists)
    reach(400)
    XCTAssertLessThanOrEqual(rows.count, 150)
  }

  /// 搜索与排序在深处改变时必须重新从新结果的第一批开始。
  func testFilterAndSortResetWindow() {
    launch(capacity: 175)
    reach(400)
    let filter = app.textFields["filter"]
    filter.click()
    filter.typeText("020")
    filter.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    waitForRows(100)
    XCTAssertTrue(row(20).exists)
    app.checkBoxes["reverse"].click()
    XCTAssertTrue(row(2099).exists)
    filter.click()
    filter.typeKey("a", modifierFlags: .command)
    filter.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
    XCTAssertTrue(row(2405).waitForExistence(timeout: 3))
    XCTAssertEqual(rows.count, 100)
  }

  /// 无匹配结果仍是可见空表格，清除筛选后回到第一批。
  func testEmptySearchAndRecovery() {
    launch()
    let filter = app.textFields["filter"]
    filter.click()
    filter.typeText("no-match")
    filter.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    waitForRows(0)
    XCTAssertTrue(table.exists)
    filter.typeKey("a", modifierFlags: .command)
    filter.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
    waitForRows(100)
    XCTAssertTrue(row(1).exists)
  }

  /// 批量删除使当前偏移失效时恢复首批，删除全部后仍显示空表格。
  func testDeletionInvalidatesWindow() {
    launch(capacity: 175)
    reach(400)
    app.buttons["delete-tail"].click()
    waitForRows(50)
    XCTAssertTrue(row(1).exists)
    app.buttons["delete-all"].click()
    waitForRows(0)
    XCTAssertTrue(table.exists)
  }

  // MARK: - 原生滚动输入与位置保持

  /// 首次淘汰和向前补页只补偿窗口变化，不能把正在阅读的记录跳到别处。
  func testPixelAnchorAcrossEvictionAndPrepend() {
    launch(capacity: 100)
    scroll(-1200)
    let before = row(65).frame.minY
    scroll(-240)
    XCTAssertTrue(row(1).waitForNonExistence(timeout: 3))
    XCTAssertEqual(row(65).frame.minY, before - 240, accuracy: 3)
    let after = row(65).frame.minY
    scroll(1)
    XCTAssertTrue(row(1).waitForExistence(timeout: 3))
    XCTAssertEqual(row(65).frame.minY, after, accuracy: 3)
  }

  /// 键盘翻屏同样走原生滚动后的分页路径。
  func testKeyboardPaging() {
    launch()
    row(1).click()
    XCTAssertEqual(app.staticTexts["selection"].value as? String, "selected:1")
    // 点击文字不一定赋予键盘焦点；使用系统 Tab 导航进入表格。
    app.textFields["filter"].click()
    app.textFields["filter"].typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
    table.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
    XCTAssertEqual(app.staticTexts["selection"].value as? String, "selected:2")
    for _ in 0..<6 {
      table.typeKey(XCUIKeyboardKey.pageDown.rawValue, modifierFlags: [])
    }
    XCTAssertGreaterThanOrEqual(rows.count, 200)
  }

  /// 只按一次 End 即可在原生滚动完成后加载下一页，不要求再按一次键。
  func testSingleEndKeyLoadsNextPage() {
    launch()
    let filter = app.textFields["filter"]
    filter.click()
    filter.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
    table.typeKey(XCUIKeyboardKey.end.rawValue, modifierFlags: [])
    waitForRows(200)
  }

  /// 文本框中的键盘输入不能翻页；一行缓存收到按下和抬起也只能移动一行。
  func testKeyboardFocusAndSingleRowBuffer() {
    launch(count: 5, capacity: 1)
    let filter = app.textFields["filter"]
    filter.click()
    filter.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
    XCTAssertTrue(row(1).exists)
    filter.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
    table.typeKey(XCUIKeyboardKey.pageDown.rawValue, modifierFlags: [])
    XCTAssertTrue(row(2).exists)
    XCTAssertFalse(row(3).exists)
    table.typeKey(XCUIKeyboardKey.pageUp.rawValue, modifierFlags: [])
    XCTAssertTrue(row(1).exists)
  }

  /// 拖动系统滚动条也触发加载，不只支持触控板和滚轮。
  func testScrollbarPaging() {
    launch(scrollbars: true)
    let bar = app.scrollBars.firstMatch
    XCTAssertTrue(bar.waitForExistence(timeout: 3))
    let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
    let end = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
    start.click(forDuration: 0.1, thenDragTo: end)
    XCTAssertGreaterThanOrEqual(rows.count, 200)
  }

  /// 在缓存中段删除可见行时，相邻记录不会跳回缓存顶部。
  func testDeleteVisibleRowKeepsReadingPosition() {
    launch()
    scroll(-1200)
    row(51).click()
    let before = row(52).frame.minY
    app.buttons["delete-selected"].click()
    XCTAssertTrue(row(51).waitForNonExistence(timeout: 3))
    XCTAssertLessThanOrEqual(abs(row(52).frame.minY - before), 25)
  }

  // MARK: - 单选与选择失效

  /// 普通点击、Command 和 Shift 点击都不能形成多项选择。
  func testSingleSelectionWithModifiers() {
    launch()
    row(1).click()
    XCTAssertEqual(app.staticTexts["selection"].value as? String, "selected:1")
    XCUIElement.perform(withKeyModifiers: .command) { row(2).click() }
    XCTAssertLessThanOrEqual(rows.matching(NSPredicate(format: "selected == true")).count, 1)
    XCUIElement.perform(withKeyModifiers: .shift) { row(5).click() }
    XCTAssertLessThanOrEqual(rows.matching(NSPredicate(format: "selected == true")).count, 1)
    XCTAssertEqual(app.staticTexts["selection"].value as? String, "selected:5")
  }

  /// 删除选中记录会清除选择；数据补入后不保留失效标识。
  func testDeleteSelectedRow() {
    launch()
    row(1).click()
    app.buttons["delete-selected"].click()
    XCTAssertTrue(row(1).waitForNonExistence(timeout: 3))
    XCTAssertEqual(app.staticTexts["selection"].value as? String, "selected:none")
    XCTAssertTrue(row(101).exists)
  }

  /// 追加时保留仍在窗口内的单选，淘汰选中记录时才清除选择。
  func testSelectionSurvivesAppendAndClearsOnEviction() {
    launch(capacity: 175)
    scroll(-1200)
    row(65).click()
    reach(200)
    XCTAssertEqual(app.staticTexts["selection"].value as? String, "selected:65")
    reach(400)
    XCTAssertEqual(app.staticTexts["selection"].value as? String, "selected:none")
  }

  // MARK: - 生命周期与多表隔离

  /// 离开后重新挂载表格，旧输入监视器不能重复发出分页请求。
  func testUnmountAndRemount() {
    launch()
    reach(400)
    app.checkBoxes["visible"].click()
    XCTAssertTrue(table.waitForNonExistence(timeout: 3))
    app.checkBoxes["visible"].click()
    waitForRows(100)
    assertStableRows(100)
    reach(200)
    XCTAssertLessThanOrEqual(rows.count, 300)
  }

  /// 同一窗口的两张表必须独立处理输入，不能误接到旁边的原生 Table。
  func testMultipleTablesKeepIndependentWindows() {
    launch(secondTable: true)
    reach(200)
    let other = rowType == .outlineRow ? app.outlines["other-table"] : app.tables["other-table"]
    XCTAssertEqual(other.children(matching: rowType).count, 100)
    let mainCount = rows.count
    other.scroll(byDeltaX: 0, deltaY: -2000)
    XCTAssertGreaterThan(other.children(matching: rowType).count, 100)
    XCTAssertEqual(rows.count, mainCount)
  }

  // MARK: - 查询失败与恢复

  /// 计数失败时保持原有行集，恢复存储后可重试同一方向。
  func testCountFailureAndRetry() {
    launch(faults: true)
    app.buttons["fail-count"].click()
    scroll(-2000)
    XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 4))
    XCTAssertEqual(rows.count, 100)
    app.sheets.buttons["好"].click()
    app.buttons["recover"].click()
    reach(200)
  }

  /// 实际 @Query 失败时回退旧窗口，并在错误解除后正确继续分页。
  func testQueryFailureRollsBackAndRetries() {
    launch(faults: true)
    app.buttons["fail-query"].click()
    scroll(-2000)
    XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 4))
    XCTAssertEqual(rows.count, 100)
    XCTAssertTrue(row(1).exists)
    app.sheets.buttons["好"].click()
    app.buttons["recover"].click()
    reach(200)
  }

  /// 首批查询失败仍保留空原生表格，并可在没有滚动行的情况下显式重新加载。
  func testInitialQueryFailureCanReload() {
    launch(faults: true, initialFailure: true)
    XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 4))
    XCTAssertEqual(rows.count, 0)
    app.sheets.buttons["重新加载"].click()
    waitForRows(100)
    XCTAssertTrue(row(1).exists)
    reach(200)
  }

  // MARK: - 测试启动与断言辅助

  /// 启动同一工程构建的内存夹具，不启动默认的 MagentX 代理应用。
  private func launch(
    count: Int = 2405, page: Int = 100, capacity: Int = 1000, progress: Double = 0.8,
    offset: Int = 0, limit: Int? = nil, faults: Bool = false, secondTable: Bool = false,
    scrollbars: Bool = false, initialFailure: Bool = false, bounce: Bool = false
  ) {
    let hostURL = Bundle.main.bundleURL.deletingLastPathComponent()
      .appendingPathComponent("ScrollTableHost.app")
    XCTAssertTrue(FileManager.default.fileExists(atPath: hostURL.path), "测试宿主尚未构建")
    app = XCUIApplication(url: hostURL)
    maximumCachedModelCount = capacity
    // 测试进程不恢复上次退出时的窗口集合，避免批量运行变成仅有菜单栏的宿主。
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
    ]
    if scrollbars { app.launchArguments += ["-AppleShowScrollBars", "Always"] }
    app.launchEnvironment = [
      "TABLE_COUNT": String(count), "TABLE_PAGE": String(page),
      "TABLE_CAPACITY": String(capacity), "TABLE_PROGRESS": String(progress),
      "TABLE_OFFSET": String(offset), "TABLE_FAULTS": faults ? "1" : "0",
      "TABLE_SECOND": secondTable ? "1" : "0",
      "TABLE_INITIAL_FAILURE": initialFailure ? "1" : "0",
      "TABLE_BOUNCE": bounce ? "1" : "0",
    ]
    if let limit { app.launchEnvironment["TABLE_LIMIT"] = String(limit) }
    app.launch()
    table = app.outlines["paged-table"]
    rowType = .outlineRow
    if !table.waitForExistence(timeout: 2) {
      table = app.tables["paged-table"]
      rowType = .tableRow
      XCTAssertTrue(table.waitForExistence(timeout: 8))
    }
    waitForRows(initialFailure ? 0 : min(max(0, count - offset), page, capacity, limit ?? count))
  }

  /// 使用业务编号定位原生 Table 中真实的文本单元格。
  private func row(_ id: Int) -> XCUIElement { table.staticTexts["record-\(id)"] }

  /// 发送实际滚轮输入；XCTest 会等待宿主处理事件和后续布局。
  private func scroll(_ delta: CGFloat) { table.scroll(byDeltaX: 0, deltaY: delta) }

  /// 每次重置采样器并发出触控板式滑动；离散滚轮事件本身不会启动系统弹性动画。
  private func assertBounce(edge: String) {
    app.buttons["reset-bounce"].click()
    let report = app.staticTexts["bounce-report"]
    XCTAssertTrue(report.waitForExistence(timeout: 3))
    let initialValue = report.value as? String ?? ""
    XCTAssertTrue(initialValue.contains("elasticity:2"), initialValue)
    XCTAssertTrue(initialValue.contains(";top:0;bottom:0"), initialValue)
    if edge == "top" {
      table.swipeDown(velocity: .slow)
    } else {
      table.swipeUp(velocity: .slow)
    }
    let value = report.value as? String ?? ""
    XCTAssertTrue(value.contains("elasticity:2"), value)
    let sample = value.split(separator: ";").first { $0.hasPrefix("\(edge):") }
    let displacement = sample?.split(separator: ":").last.flatMap { Int($0) } ?? 0
    XCTAssertGreaterThan(displacement, 1, "本轮没有\(edge)回弹：\(value)")
  }

  /// 持续向下滚动到指定记录已进入查询窗口，每次检查缓存容量。
  private func reach(_ id: Int, file: StaticString = #filePath, line: UInt = #line) {
    for _ in 0..<90 {
      let count = rows.count
      XCTAssertLessThanOrEqual(count, maximumCachedModelCount, file: file, line: line)
      if count > 0, rowNumber(at: count - 1) >= id {
        XCTAssertLessThanOrEqual(rowNumber(at: 0), id, "目标行被跳过", file: file, line: line)
        return
      }
      scroll(-2000)
    }
    XCTFail("未能滚动加载记录 \(id)", file: file, line: line)
  }

  /// 只读取指定原生行的单元格，避免为了不存在的标识遍历整份千行辅助功能树。
  private func rowNumber(at index: Int) -> Int {
    let text = rows.element(boundBy: index).staticTexts.firstMatch.value as? String ?? ""
    guard let number = text.split(separator: " ").last.flatMap({ Int($0) }) else {
      XCTFail("原生表格行缺少记录编号：\(text)")
      return -1
    }
    return number
  }

  /// 等待查询结果应用到辅助功能树，不用固定长时间睡眠掩盖时序问题。
  private func waitForRows(_ count: Int) {
    let predicate = NSPredicate { [weak self] _, _ in self?.rows.count == count }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, app.debugDescription)
  }

  /// 留出多个布局周期，确认没有用户输入时不会继续改变查询大小。
  private func assertStableRows(_ count: Int) {
    let changed = XCTNSPredicateExpectation(
      predicate: NSPredicate { [weak self] _, _ in self?.rows.count != count }, object: nil)
    changed.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 0.8), .completed)
  }
}
