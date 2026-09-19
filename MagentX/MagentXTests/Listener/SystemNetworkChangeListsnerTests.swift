//
//  SystemNetworkChangeListsnerTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Verifies observable proxy service state transitions and cleanup behavior.
//

import Testing

@testable import MagentX

/// `SystemNetworkChangeListsner` 在服务应用成功或失败时的运行状态测试。
@Suite @MainActor
struct SystemNetworkChangeListsnerTests {
  /// 验证启动成功后才发布运行状态。
  @Test func startServicePublishesStateAfterSuccessfulApply() async {
    var appliedState: Bool?
    let listener = SystemNetworkChangeListsner(
      stateApplier: { isServiceStarted, _, _ in
        appliedState = isServiceStarted
      }
    )

    await listener.startService()

    #expect(appliedState == true)
    #expect(listener.isServiceStarted)
    #expect(listener.serviceError == nil)
    #expect(listener.isApplying == false)
  }

  /// 验证启动应用失败时保持原有运行状态并暴露错误反馈。
  @Test func startServicePreservesStateWhenApplyFails() async {
    let listener = SystemNetworkChangeListsner(
      stateApplier: { _, _, _ in
        throw SystemNetworkChangeListsnerTestError.expected
      }
    )

    await listener.startService()

    #expect(listener.isServiceStarted == false)
    #expect(listener.serviceError != nil)
    #expect(listener.isApplying == false)
  }

  /// 验证停止 PAC 失败时仍会停止 Magent，并向普通停止调用方保留 PAC 的原始错误。
  @Test func stopServiceAttemptsMagentCleanupWhenPACCleanupFails() async {
    var operations: [String] = []
    let listener = SystemNetworkChangeListsner(
      disableMagentProxyOperation: {},
      shudownServerOperation: {
        operations.append("pac")
        throw SystemNetworkChangeListsnerTestError.expected
      },
      stopMagentOperation: {
        operations.append("magent")
      }
    )

    do {
      try await listener.apply(
        isServiceStarted: false,
        generalSettings: GeneralSettings.load(),
        appSettings: AppSettings()
      )
      Issue.record("Expected PAC cleanup error")
    } catch SystemNetworkChangeListsnerTestError.expected {
      // The original PAC cleanup error must reach regular stop callers.
    } catch {
      Issue.record("Unexpected cleanup error: \(error)")
    }

    #expect(operations == ["pac", "magent"])
  }
}

/// 定向验证监听器状态事务失败路径的测试错误。
private enum SystemNetworkChangeListsnerTestError: Error {
  case expected
}
