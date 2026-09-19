import XCTest

/// 对应正式 View/ProxyNodesView，验证公共滚动表格接入后的布局、详情及 CRUD 行为。
@MainActor
final class ProxyNodesViewUITests: XCTestCase {
  private var app: XCUIApplication!
  private var table: XCUIElement!
  private var rowType = XCUIElement.ElementType.outlineRow

  private var rows: XCUIElementQuery { table.children(matching: rowType) }

  /// 失败时立即保留现场，避免后续点击掩盖第一个回归问题。
  override func setUpWithError() throws { continueAfterFailure = false }

  /// 关闭内存宿主；每个用例重新创建模型，不依赖真实用户节点和代理服务。
  override func tearDown() async throws { app?.terminate() }

  // MARK: - 布局与分页

  /// 保留三列和左右分栏，首批仅查询100条；选择节点后详情仍位于表格右侧。
  func testInitialPageAndDetailLayout() {
    launch()
    XCTAssertEqual(rows.count, 100)
    for title in ["名称", "地址", "类型"] {
      XCTAssertTrue(table.descendants(matching: .any)[title].exists)
    }
    XCTAssertGreaterThanOrEqual(table.frame.width, 240)
    XCTAssertLessThanOrEqual(table.frame.width, 440)
    cell("Node 00001").click()
    let name = app.buttons["node-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 3))
    XCTAssertGreaterThanOrEqual(name.frame.minX, table.frame.maxX)
    XCTAssertTrue(app.buttons["删除节点"].isHittable)
    XCTAssertTrue(app.buttons["添加代理节点"].isHittable)
    XCTAssertEqual(rows.matching(NSPredicate(format: "selected == true")).count, 1)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "原生三列表格与右侧节点详情"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  /// 记录超过原300条上限时能够继续浏览，淘汰清理详情，反向滚动可重新选中首行。
  func testPagingBeyondCapacityAndReturningToFirstNode() {
    launch()
    cell("Node 00001").click()
    reach("Node 00425", delta: -2000)
    XCTAssertEqual(rows.count, 300)
    XCTAssertFalse(app.buttons["删除节点"].exists)
    cell("Node 00425").click()
    XCTAssertTrue(app.buttons["node-name"].waitForExistence(timeout: 3))
    table.scroll(byDeltaX: 0, deltaY: -2000)
    XCTAssertTrue(cell("Node 00425").isHittable)
    reach("Node 00001", delta: 2000)
    cell("Node 00001").click()
    XCTAssertTrue(app.buttons["删除节点"].isHittable)
    XCTAssertEqual(rows.matching(NSPredicate(format: "selected == true")).count, 1)
  }

  /// Command及Shift点击都不能将组件的单选变成多选。
  func testSelectionRemainsSingleWithModifiers() {
    launch(count: 3)
    cell("Node 00001").click()
    XCUIElement.perform(withKeyModifiers: .command) { cell("Node 00002").click() }
    XCTAssertEqual(rows.matching(NSPredicate(format: "selected == true")).count, 1)
    XCUIElement.perform(withKeyModifiers: .shift) { cell("Node 00003").click() }
    XCTAssertEqual(rows.matching(NSPredicate(format: "selected == true")).count, 1)
    XCTAssertTrue(app.buttons["删除节点"].isHittable)
  }

  // MARK: - 新建与取消

  /// 空数据仍显示三列表格；取消右侧新建表单不产生记录。
  func testEmptyTableAndCancelCreation() {
    launch(count: 0)
    for title in ["名称", "地址", "类型"] {
      XCTAssertTrue(table.descendants(matching: .any)[title].exists)
    }
    app.buttons["添加代理节点"].click()
    XCTAssertTrue(app.textFields["名称（可选）"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.buttons["保存"].isEnabled)
    app.buttons["取消"].click()
    XCTAssertFalse(app.textFields["名称（可选）"].exists)
    XCTAssertEqual(rows.count, 0)
  }

  /// 新建、自动选中和删除仍通过正式页面完成，最后一条删除后恢复空表。
  func testCreateSelectAndDeleteNode() {
    launch(count: 0)
    app.buttons["添加代理节点"].click()
    replace(app.textFields["名称（可选）"], with: "731")
    replace(app.textFields["地址"], with: "127.0.0.1")
    replace(app.secureTextFields["密码"], with: "123456")
    app.buttons["保存"].click()
    waitForRows(1)
    XCTAssertTrue(cell("731").exists)
    XCTAssertTrue(app.buttons["node-name"].waitForExistence(timeout: 3))
    app.buttons["删除节点"].click()
    waitForRows(0)
    XCTAssertFalse(app.buttons["删除节点"].exists)
  }

  // MARK: - 编辑与删除保护

  /// 切换选择前提交原节点草稿，不把旧草稿写进新选中的节点。
  func testEditingCommitsToOriginalNodeOnSelectionChange() {
    launch(count: 3)
    cell("Node 00001").click()
    app.buttons["node-name"].click()
    replace(app.textFields["node-name"], with: "731")
    cell("Node 00002").click()
    XCTAssertTrue(cell("731").waitForExistence(timeout: 3))
    XCTAssertTrue(cell("Node 00002").exists)
    XCTAssertFalse(cell("Node 00001").exists)
    cell("731").click()
    app.buttons["node-name"].click()
    XCTAssertEqual(app.textFields["node-name"].value as? String, "731")
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    cell("Node 00002").click()
    app.buttons["node-name"].click()
    XCTAssertEqual(app.textFields["node-name"].value as? String, "Node 00002")
  }

  /// 无效端口提示原错误并保留存储值，关闭错误后仍可切换到其他节点。
  func testInvalidEditDoesNotCorruptEitherNode() {
    launch(count: 3)
    cell("Node 00001").click()
    app.buttons["node-port"].click()
    replace(app.textFields["node-port"], with: "0")
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))
    app.sheets.buttons["好"].click()
    XCTAssertTrue(cell("node00001.example:8388").exists)
    cell("Node 00002").click()
    XCTAssertTrue(cell("node00002.example:8388").exists)
    XCTAssertTrue(app.buttons["删除节点"].isHittable)
  }

  /// 策略引用仍阻止删除；切换节点后可以正常删除未被引用的另一条节点。
  func testPolicyReferenceStillPreventsDeletion() {
    launch(count: 3, inUse: true)
    cell("Node 00001").click()
    app.buttons["删除节点"].click()
    XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))
    app.sheets.buttons["好"].click()
    XCTAssertEqual(rows.count, 3)
    XCTAssertTrue(cell("Node 00001").exists)
    cell("Node 00002").click()
    app.buttons["删除节点"].click()
    waitForRows(2)
    XCTAssertTrue(cell("Node 00001").exists)
    XCTAssertFalse(cell("Node 00002").exists)
  }

  // MARK: - 宿主与原生交互辅助

  /// 从当前测试产物启动内存节点场景，不通过 LaunchServices 打开其他版本或正式应用。
  private func launch(count: Int = 425, inUse: Bool = false) {
    let hostURL = Bundle.main.bundleURL.deletingLastPathComponent()
      .appendingPathComponent("ScrollTableHost.app")
    XCTAssertTrue(FileManager.default.fileExists(atPath: hostURL.path), "测试宿主尚未构建")
    app = XCUIApplication(url: hostURL)
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
    ]
    app.launchEnvironment = [
      "UI_TEST_VIEW": "proxy-nodes", "NODE_COUNT": String(count),
      "NODE_IN_USE": inUse ? "1" : "0",
    ]
    app.launch()
    table = app.outlines["proxy-nodes-table"]
    rowType = .outlineRow
    if !table.waitForExistence(timeout: 2) {
      table = app.tables["proxy-nodes-table"]
      rowType = .tableRow
      XCTAssertTrue(table.waitForExistence(timeout: 8))
    }
    waitForRows(min(count, 100))
  }

  /// 按原生文本值查找单元格，不依赖SwiftUI是否将文本同时映射为辅助功能标签。
  private func cell(_ value: String) -> XCUIElement {
    table.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", value, value))
      .firstMatch
  }

  /// 以真实滚轮输入双向翻页，每一步都验证查询没有突破节点页的300条上限。
  private func reach(_ value: String, delta: CGFloat) {
    for _ in 0..<30 {
      XCTAssertLessThanOrEqual(rows.count, 300)
      if cell(value).isHittable { return }
      table.scroll(byDeltaX: 0, deltaY: delta)
    }
    XCTFail("未能滚动至节点：\(value)")
  }

  /// 替换字段内容；切换节点的用例故意不提交，以覆盖失焦提交路径。
  private func replace(_ field: XCUIElement, with value: String) {
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    field.click()
    field.typeKey("a", modifierFlags: .command)
    field.typeText(value)
  }

  /// 等待SwiftData查询驱动原生行数更新，不用固定睡眠代替结果断言。
  private func waitForRows(_ count: Int) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate { [weak self] _, _ in self?.rows.count == count }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
  }
}
