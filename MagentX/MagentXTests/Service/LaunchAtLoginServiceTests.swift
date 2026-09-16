//
//  LaunchAtLoginServiceTests.swift
//  MagentXTests
//
//  Responsibility: Verifies macOS login-item registration state transitions.
//

import ServiceManagement
import Testing

@testable import MagentX

/// `LaunchAtLoginService` 的幂等注册、取消注册和错误传播测试。
@MainActor
struct LaunchAtLoginServiceTests {
  /// 已启用时再次开启不会重复注册。
  @Test func enabledRegistrationIsIdempotent() throws {
    var registerCount = 0
    let service = LaunchAtLoginService(
      statusProvider: { .enabled },
      registerOperation: { registerCount += 1 }
    )

    try service.setEnabled(true)

    #expect(service.isEnabled)
    #expect(registerCount == 0)
  }

  /// 尚未注册时开启会调用系统注册操作。
  @Test func enablingRegistersMainApp() throws {
    var registerCount = 0
    let service = LaunchAtLoginService(
      statusProvider: { .notRegistered },
      registerOperation: { registerCount += 1 }
    )

    try service.setEnabled(true)

    #expect(registerCount == 1)
  }

  /// 已启用时关闭会调用系统取消注册操作。
  @Test func disablingUnregistersMainApp() throws {
    var unregisterCount = 0
    let service = LaunchAtLoginService(
      statusProvider: { .enabled },
      unregisterOperation: { unregisterCount += 1 }
    )

    try service.setEnabled(false)

    #expect(unregisterCount == 1)
  }

  /// 尚未注册时关闭不会重复取消注册。
  @Test func disabledRegistrationIsIdempotent() throws {
    var unregisterCount = 0
    let service = LaunchAtLoginService(
      statusProvider: { .notRegistered },
      unregisterOperation: { unregisterCount += 1 }
    )

    try service.setEnabled(false)

    #expect(unregisterCount == 0)
  }

  /// 系统注册失败时向调用边界传播原始错误。
  @Test func registrationPropagatesOriginalError() {
    let expectedError = MagentXError.invalidParameter(String(localized: "Invalid URL"))
    let service = LaunchAtLoginService(
      statusProvider: { .notRegistered },
      registerOperation: { throw expectedError }
    )

    #expect(throws: expectedError) {
      try service.setEnabled(true)
    }
  }
}
