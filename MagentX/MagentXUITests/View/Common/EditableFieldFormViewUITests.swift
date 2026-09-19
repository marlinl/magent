import XCTest

/// 从真实鼠标、键盘和原生菜单验证公共字段；夹具承担绑定和 SwiftData 保存。
@MainActor
final class EditableFieldFormViewUITests: XCTestCase {
  private var app: XCUIApplication!

  /// 失败时停止当前场景，保留第一个错误的界面状态。
  override func setUpWithError() throws { continueAfterFailure = false }

  /// 在主线程为每个用例启动隔离内存宿主，不接触正式应用的数据或代理服务。
  private func launch() {
    let hostURL = Bundle.main.bundleURL.deletingLastPathComponent()
      .appendingPathComponent("ScrollTableHost.app")
    XCTAssertTrue(FileManager.default.fileExists(atPath: hostURL.path))
    app = XCUIApplication(url: hostURL)
    app.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
    ]
    app.launchEnvironment = ["UI_TEST_VIEW": "editable-field", "NODE_COUNT": "1"]
    app.launch()
    XCTAssertTrue(app.buttons["editable-name"].waitForExistence(timeout: 5))
  }

  /// 释放测试窗口，防止上一用例的焦点和菜单影响下一用例。
  override func tearDown() async throws { app?.terminate() }

  /// 不可编辑字段保持调用方的 Label，不产生编辑按钮或文本输入框。
  func testReadOnlyFieldKeepsCallerDisplay() {
    launch()
    app.staticTexts["Read only"].firstMatch.click()
    XCTAssertFalse(app.textFields["readonly-editor"].exists)
    XCTAssertFalse(app.buttons["readonly-display"].exists)
    assertCommitState("commits:0|stored:Node 00001")
  }

  /// 点击后自动获得输入焦点；点击非聚焦文本也结束编辑，由调用方保存到自己的上下文。
  func testOutsideClickRestoresDisplayAndSavesCallerContextOnce() {
    launch()
    app.buttons["editable-name"].click()
    XCTAssertTrue(app.textFields["editable-name"].waitForExistence(timeout: 3))
    // 不再点击输入框，直接输入以检查自动聚焦。
    app.typeKey("a", modifierFlags: .command)
    app.typeText("731")
    XCTAssertEqual(app.textFields["editable-name"].value as? String, "731")
    assertCommitState("commits:0|stored:Node 00001")
    app.staticTexts["outside"].click()
    XCTAssertTrue(app.buttons["editable-name"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.textFields["editable-name"].exists)
    assertCommitState("commits:1|stored:731")
    app.staticTexts["outside"].click()
    assertCommitState("commits:1|stored:731")
  }

  /// 回车及随后移除输入框产生的失焦事件，只结束一次编辑；之后仍可重新进入。
  func testReturnCommitsOnceAndAllowsReentry() {
    launch()
    app.buttons["editable-name"].click()
    replace(app.textFields["editable-name"], with: "732")
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    XCTAssertTrue(app.buttons["editable-name"].waitForExistence(timeout: 3))
    assertCommitState("commits:1|stored:732")
    app.buttons["editable-name"].click()
    replace(app.textFields["editable-name"], with: "733")
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    assertCommitState("commits:2|stored:733")
  }

  /// 切换到不同类型的编辑器时旧字段结束，密码编辑结束后恢复调用方的掩码展示。
  func testSwitchToSecureFieldFinishesPreviousEditor() {
    launch()
    app.buttons["editable-name"].click()
    replace(app.textFields["editable-name"], with: "734")
    app.buttons["editable-password"].click()
    XCTAssertTrue(app.secureTextFields["editable-password"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.textFields["editable-name"].exists)
    assertCommitState("commits:1|stored:734")
    replace(app.secureTextFields["editable-password"], with: "987654")
    app.staticTexts["outside"].click()
    XCTAssertTrue(app.buttons["editable-password"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.staticTexts["987654"].exists)
  }

  /// 自定义菜单在弹出期间保持编辑状态，选择后通过调用方的结束闭包恢复展示。
  func testMenuEditorCompletesAfterSelection() {
    launch()
    app.buttons["editable-choice"].click()
    let picker = app.popUpButtons["editable-choice"]
    XCTAssertTrue(picker.waitForExistence(timeout: 3))
    picker.click()
    let option = app.menuItems["Option 2"]
    XCTAssertTrue(option.waitForExistence(timeout: 3))
    option.click()
    XCTAssertTrue(app.buttons["editable-choice"].waitForExistence(timeout: 3))
    XCTAssertEqual(app.buttons["editable-choice"].label, "Choice 2")
    XCTAssertFalse(picker.exists)
  }

  /// 进入前可拒绝编辑；动态撤销编辑权限会结束当前会话并恢复只读内容。
  func testCallerCanRejectEntryAndRevokePermission() {
    launch()
    app.checkBoxes["allow-begin"].click()
    app.buttons["editable-name"].click()
    XCTAssertFalse(app.textFields["editable-name"].exists)
    assertCommitState("commits:0|stored:Node 00001")
    app.checkBoxes["allow-begin"].click()
    app.buttons["editable-name"].click()
    replace(app.textFields["editable-name"], with: "735")
    app.checkBoxes["allow-edit"].click()
    XCTAssertFalse(app.textFields["editable-name"].exists)
    XCTAssertFalse(app.buttons["editable-name"].exists)
    assertCommitState("commits:1|stored:735")
  }

  /// 纯键盘焦点移动也结束编辑，不依赖字段外鼠标监听。
  func testTabEndsEditingAndSaves() {
    launch()
    app.buttons["editable-name"].click()
    replace(app.textFields["editable-name"], with: "737")
    app.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
    XCTAssertTrue(app.buttons["editable-name"].waitForExistence(timeout: 3))
    assertCommitState("commits:1|stored:737")
  }

  /// 通过可见结果等待调用方的保存完成，不依赖固定延时或组件内部状态。
  private func assertCommitState(_ value: String) {
    let label = app.staticTexts["commit-state"]
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@ OR label == %@", value, value), object: label)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: 3), .completed,
      "实际保存状态：\(label.value ?? label.label)")
  }

  /// 替换调用方提供的原生文本或安全文本编辑器中的内容。
  private func replace(_ field: XCUIElement, with value: String) {
    XCTAssertTrue(field.waitForExistence(timeout: 3))
    field.click()
    field.typeKey("a", modifierFlags: .command)
    field.typeText(value)
  }
}
