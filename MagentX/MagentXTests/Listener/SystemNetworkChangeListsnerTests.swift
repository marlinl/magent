//
//  SystemNetworkChangeListsnerTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Verifies observable proxy service state transitions and persistence transactions.
//

import Testing

@testable import MagentX

/// `SystemNetworkChangeListsner` 在服务应用成功或失败时的状态事务测试。
@Suite @MainActor
struct SystemNetworkChangeListsnerTests {
  /// 验证启动成功后才发布并持久化启动状态。
  @Test func startServicePublishesAndPersistsSelectionAfterSuccessfulApply() async {
    var persistedSelection = CurrentSelection(state: .stop, mode: .pac)
    var appliedSelection: CurrentSelection?
    let listener = SystemNetworkChangeListsner(
      stateApplier: { selection, _ in
        appliedSelection = selection
      },
      loadCurrentSelection: { persistedSelection },
      saveCurrentSelection: { persistedSelection = $0 }
    )

    await listener.startService()

    #expect(appliedSelection?.state == .start)
    #expect(listener.currentSelection.state == .start)
    #expect(persistedSelection.state == .start)
    #expect(listener.serviceError == nil)
    #expect(listener.isApplying == false)
  }

  /// 验证启动应用失败时回滚可观察状态、保持原有持久化选择并暴露错误反馈。
  @Test func startServiceDoesNotPersistSelectionWhenApplyFails() async {
    var persistedSelection = CurrentSelection(state: .stop, mode: .pac)
    let listener = SystemNetworkChangeListsner(
      stateApplier: { _, _ in
        throw SystemNetworkChangeListsnerTestError.expected
      },
      loadCurrentSelection: { persistedSelection },
      saveCurrentSelection: { persistedSelection = $0 }
    )

    await listener.startService()

    #expect(listener.currentSelection.state == .stop)
    #expect(persistedSelection.state == .stop)
    #expect(listener.serviceError != nil)
    #expect(listener.isApplying == false)
  }

  /// 验证停止 PAC 失败时仍会停止 Magent，并向普通停止调用方保留 PAC 的原始错误。
  @Test func stopServiceAttemptsMagentCleanupWhenPACCleanupFails() async {
    var persistedSelection = CurrentSelection(state: .start, mode: .pac)
    var operations: [String] = []
    let listener = SystemNetworkChangeListsner(
      loadCurrentSelection: { persistedSelection },
      saveCurrentSelection: { persistedSelection = $0 },
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
        currentSelection: CurrentSelection(state: .stop, mode: .pac),
        generalSettings: GeneralSettings.load()
      )
      Issue.record("Expected PAC cleanup error")
    } catch SystemNetworkChangeListsnerTestError.expected {
      // The original PAC cleanup error must reach regular stop callers.
    } catch {
      Issue.record("Unexpected cleanup error: \(error)")
    }

    #expect(operations == ["pac", "magent"])
  }

  /// 验证启动失败时即使 PAC 清理失败，仍清理 Magent 并原样抛回启动错误。
  @Test func startupFailureAttemptsBothCleanupsAndPreservesStartupError() async {
    var operations: [String] = []
    let listener = SystemNetworkChangeListsner(
      disableMagentProxyOperation: {},
      shudownServerOperation: {
        operations.append("pac")
        throw SystemNetworkChangeListsnerTestError.expected
      },
      stopMagentOperation: {
        operations.append("magent")
        throw SystemNetworkChangeListsnerTestError.expected
      }
    )

    do {
      try await listener.apply(
        currentSelection: CurrentSelection(state: .start, mode: .tunnel),
        generalSettings: GeneralSettings.load()
      )
      Issue.record("Expected startup error")
    } catch MagentXError.tunnelModeNotImplemented {
      // Cleanup failures must not replace the startup error.
    } catch {
      Issue.record("Unexpected startup error: \(error)")
    }

    #expect(operations == ["pac", "magent"])
  }
}

/// 定向验证监听器状态事务失败路径的测试错误。
private enum SystemNetworkChangeListsnerTestError: Error {
  case expected
}
