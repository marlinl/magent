//
//  MagentXUITestsLaunchTests.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Launch performance and startup UI tests.
//


import XCTest

final class MagentXUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // 在这里加入应用启动后、截图前需要执行的步骤，
        // 例如登录测试账号或导航到应用中的某个位置
        // XCUIAutomation 文档
        // https://developer.apple.com/documentation/xcuiautomation

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
