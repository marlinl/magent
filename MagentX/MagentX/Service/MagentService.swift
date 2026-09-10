//
//  MagentService.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Owns the Magent core proxy lifecycle for the macOS app.
//

import Foundation
import OSLog
@preconcurrency import Magent
@preconcurrency import NIOCore

/// Magent 运行服务，统一管理核心代理实例的生命周期。
///
/// `Magent.close()` 会回收核心实例自己的 EventLoopGroup；本 actor 会在下一次启动时重建核心实例。
actor MagentService {
    /// Magent 核心服务的当前运行状态。
    enum State: Equatable, Sendable {
        case running
        case idle
    }

    /// 当前 Magent 核心服务的运行状态。
    private(set) var state = State.idle
    private var magent: Magent?
    private var lifecycleOperation: LifecycleOperation?

    /// 标识当前启动或关闭操作，用于在 actor 重入时复用同一个任务。
    private struct LifecycleOperation {
        let identifier: UUID
        let task: Task<Void, Error>
    }

    /// 使用本地代理监听端点构造默认直连配置并启动 Magent。
    ///
    /// - Parameters:
    ///   - address: 本地代理监听地址。
    ///   - port: 本地代理监听端口。
    func start(address: String, port: Int) async throws {
        let normalizedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedAddress.isEmpty == false else {
            throw MagentXError.invalidListenAddress(address)
        }
        guard (1...65_535).contains(port) else {
            throw MagentXError.invalidListenPort(port)
        }
        let placeholderNode = try ProxyNode(
            id: UUID(),
            address: SocketAddress(ipAddress: "127.0.0.1", port: 9),
            cipher: .chacha20IetfPoly1305,
            password: "unused-direct-route"
        )
        let configuration = MagentConfig(
            address: .domain(normalizedAddress, port: port),
            defaultDecision: .direct,
            defaultProxyNode: placeholderNode,
            enableMatchTable: false
        )
        try await start(configuration)
    }

    /// 使用给定配置启动 Magent；已启动或正在启动时保持幂等。
    ///
    /// 副作用：创建并启动 Magent 核心监听器，并向系统日志写入生命周期事件。
    func start(_ configuration: MagentConfig) async throws {
        switch state {
        case .idle:
            if let lifecycleOperation, let magent {
                try await completeShutdown(magent: magent, operation: lifecycleOperation)
                try await start(configuration)
                return
            }

            AppLog.proxy.info("Starting Magent core service")
            let threadNumber = await MainActor.run {
                GeneralSettings.load().proxyThreadNumber
            }
            guard threadNumber > 0 else {
                throw MagentXError.invalidProxyThreadNumber(threadNumber)
            }

            let magent = Magent(threadNumber: threadNumber)
            let operation = LifecycleOperation(
                identifier: UUID(),
                task: Task {
                    try await magent.start(configuration)
                }
            )
            self.magent = magent
            state = .running
            lifecycleOperation = operation
            try await completeStartup(magent: magent, operation: operation)
        case .running:
            if let lifecycleOperation, let magent {
                try await completeStartup(magent: magent, operation: lifecycleOperation)
            } else {
                AppLog.proxy.debug("Magent core service is already running")
            }
        }
    }

    /// 关闭当前 Magent 实例；未启动或正在关闭时保持幂等。
    ///
    /// 副作用：关闭 Magent 核心监听器，并向系统日志写入生命周期事件。
    func stop() async throws {
        switch state {
        case .idle:
            if let lifecycleOperation, let magent {
                try await completeShutdown(magent: magent, operation: lifecycleOperation)
            } else {
                AppLog.proxy.debug("Magent core service is already stopped")
            }
        case .running:
            guard let magent else {
                state = .idle
                return
            }
            if let lifecycleOperation {
                try await completeStartup(magent: magent, operation: lifecycleOperation)
                try await stop()
                return
            }

            AppLog.proxy.info("Stopping Magent core service")
            let operation = LifecycleOperation(
                identifier: UUID(),
                task: Task {
                    try await magent.close()
                }
            )
            state = .idle
            lifecycleOperation = operation
            try await completeShutdown(magent: magent, operation: operation)
        }
    }

    /// 等待启动任务结束，并将仍属于该任务的失败状态恢复为空闲。
    ///
    /// - Parameters:
    ///   - magent: 本次启动创建的 Magent 实例。
    ///   - operation: 本次启动操作。
    private func completeStartup(
        magent: Magent,
        operation: LifecycleOperation
    ) async throws {
        do {
            try await operation.task.value
            if lifecycleOperation?.identifier == operation.identifier {
                lifecycleOperation = nil
                AppLog.proxy.info("Magent core service started")
            }
        } catch {
            if lifecycleOperation?.identifier == operation.identifier {
                lifecycleOperation = nil
                if self.magent === magent {
                    self.magent = nil
                    state = .idle
                }
            }
            AppLog.proxy.error("Magent core service failed to start")
            throw error
        }
    }

    /// 等待关闭任务结束，并释放已关闭的 Magent 实例。
    ///
    /// - Parameters:
    ///   - magent: 本次关闭的 Magent 实例。
    ///   - operation: 本次关闭操作。
    private func completeShutdown(
        magent: Magent,
        operation: LifecycleOperation
    ) async throws {
        do {
            try await operation.task.value
            if lifecycleOperation?.identifier == operation.identifier {
                lifecycleOperation = nil
                if self.magent === magent {
                    self.magent = nil
                }
                AppLog.proxy.info("Magent core service stopped")
            }
        } catch {
            if lifecycleOperation?.identifier == operation.identifier {
                lifecycleOperation = nil
                if self.magent === magent {
                    state = .running
                }
            }
            AppLog.proxy.error("Magent core service failed to stop")
            throw error
        }
    }
}
