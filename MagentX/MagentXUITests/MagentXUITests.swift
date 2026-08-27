//
//  MagentXUITests.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Basic app UI test target.
//


import XCTest

final class MagentXUITests: XCTestCase {

    override func setUpWithError() throws {
        // 在这里编写测试前置代码；每个测试方法执行前都会调用。

        // UI 测试通常在失败时立即停止。
        continueAfterFailure = false

        // UI 测试运行前应设置所需初始状态，例如界面方向；setUp 是合适的位置。
    }

    override func tearDownWithError() throws {
        // 在这里编写测试清理代码；每个测试方法执行后都会调用。
    }

    @MainActor
    func testExample() throws {
        // UI 测试必须启动被测应用。
        let app = XCUIApplication()
        app.launch()

        // 使用 XCTAssert 及相关函数验证测试结果。
        // XCUIAutomation 文档
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testLaunchPerformance() throws {
        // 这里测量应用启动耗时。
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
