//
//  SystemNetworkProxyServiceTests.swift
//  MagentXTests
//
//  Author: MarlinL
//  Responsibility: Verifies observable proxy service state transitions and persistence transactions.
//

import Testing
@testable import MagentX

/// `SystemNetworkProxyService` 在服务应用成功或失败时的状态事务测试。
@Suite @MainActor
struct SystemNetworkProxyServiceTests {
    /// 验证启动成功后才发布并持久化启动状态。
    @Test func startServicePublishesAndPersistsSelectionAfterSuccessfulApply() async {
        var persistedSelection = CurrentSelection(state: .stop, mode: .pac)
        var appliedSelection: CurrentSelection?
        let service = SystemNetworkProxyService(
            stateApplier: { selection, _ in
                appliedSelection = selection
            },
            loadCurrentSelection: { persistedSelection },
            saveCurrentSelection: { persistedSelection = $0 }
        )

        await service.startService()

        #expect(appliedSelection?.state == .start)
        #expect(service.currentSelection.state == .start)
        #expect(persistedSelection.state == .start)
        #expect(service.serviceError == nil)
        #expect(service.isApplying == false)
    }

    /// 验证启动应用失败时回滚可观察状态、保持原有持久化选择并暴露错误反馈。
    @Test func startServiceDoesNotPersistSelectionWhenApplyFails() async {
        var persistedSelection = CurrentSelection(state: .stop, mode: .pac)
        let service = SystemNetworkProxyService(
            stateApplier: { _, _ in
                throw SystemNetworkProxyServiceTestError.expected
            },
            loadCurrentSelection: { persistedSelection },
            saveCurrentSelection: { persistedSelection = $0 }
        )

        await service.startService()

        #expect(service.currentSelection.state == .stop)
        #expect(persistedSelection.state == .stop)
        #expect(service.serviceError != nil)
        #expect(service.isApplying == false)
    }

    /// 验证停止 PAC 失败时仍会停止 Magent，并向普通停止调用方保留 PAC 的原始错误。
    @Test func stopServiceAttemptsMagentCleanupWhenPACCleanupFails() async {
        var persistedSelection = CurrentSelection(state: .start, mode: .pac)
        var operations: [String] = []
        let service = SystemNetworkProxyService(
            loadCurrentSelection: { persistedSelection },
            saveCurrentSelection: { persistedSelection = $0 },
            disableMagentProxyOperation: {},
            stopPACServerOperation: {
                operations.append("pac")
                throw SystemNetworkProxyServiceTestError.expected
            },
            stopMagentOperation: {
                operations.append("magent")
            }
        )

        do {
            try await service.apply(
                currentSelection: CurrentSelection(state: .stop, mode: .pac),
                generalSettings: GeneralSettings.load()
            )
            Issue.record("Expected PAC cleanup error")
        } catch SystemNetworkProxyServiceTestError.expected {
            // The original PAC cleanup error must reach regular stop callers.
        } catch {
            Issue.record("Unexpected cleanup error: \(error)")
        }

        #expect(operations == ["pac", "magent"])
    }

    /// 验证启动失败时即使 PAC 清理失败，仍清理 Magent 并原样抛回启动错误。
    @Test func startupFailureAttemptsBothCleanupsAndPreservesStartupError() async {
        var operations: [String] = []
        let service = SystemNetworkProxyService(
            disableMagentProxyOperation: {},
            stopPACServerOperation: {
                operations.append("pac")
                throw SystemNetworkProxyServiceTestError.expected
            },
            stopMagentOperation: {
                operations.append("magent")
                throw SystemNetworkProxyServiceTestError.expected
            }
        )

        do {
            try await service.apply(
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

/// 定向验证服务状态事务失败路径的测试错误。
private enum SystemNetworkProxyServiceTestError: Error {
    case expected
}
