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
    private var state: State = .stopped

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
        case .stopped:
            AppLog.proxy.info("Starting Magent core service")
            let identifier = UUID()
            let task = Task { () throws -> Magent in
                let threadNumber = await MainActor.run {
                    GeneralSettings.load().proxyThreadNumber
                }
                guard threadNumber > 0 else {
                    throw MagentXError.invalidProxyThreadNumber(threadNumber)
                }

                let magent = Magent(threadNumber: threadNumber)
                try await magent.start(configuration)
                return magent
            }
            state = .starting(identifier, task)
            try await completeStartup(identifier: identifier, task: task)
        case .starting(let identifier, let task):
            try await completeStartup(identifier: identifier, task: task)
        case .running:
            AppLog.proxy.debug("Magent core service is already running")
            return
        case .stopping(let identifier, let task):
            try await completeShutdown(identifier: identifier, task: task)
            try await start(configuration)
        }
    }

    /// 关闭当前 Magent 实例；未启动或正在关闭时保持幂等。
    ///
    /// 副作用：关闭 Magent 核心监听器，并向系统日志写入生命周期事件。
    func stop() async throws {
        switch state {
        case .stopped:
            AppLog.proxy.debug("Magent core service is already stopped")
            return
        case .starting(let identifier, let task):
            try await completeStartup(identifier: identifier, task: task)
            try await stop()
        case .running(let magent):
            AppLog.proxy.info("Stopping Magent core service")
            let identifier = UUID()
            let task = Task {
                try await magent.close()
            }
            state = .stopping(identifier, task)
            try await completeShutdown(identifier: identifier, task: task)
        case .stopping(let identifier, let task):
            try await completeShutdown(identifier: identifier, task: task)
        }
    }

    /// 等待启动任务结束，并将仍属于该任务的状态更新为运行中或已停止。
    ///
    /// - Parameters:
    ///   - identifier: 本次启动任务的唯一标识。
    ///   - task: 等待完成的 Magent 启动任务。
    private func completeStartup(
        identifier: UUID,
        task: Task<Magent, Error>
    ) async throws {
        do {
            let magent = try await task.value
            if case .starting(let currentIdentifier, _) = state,
               currentIdentifier == identifier {
                state = .running(magent)
                AppLog.proxy.info("Magent core service started")
            }
        } catch {
            if case .starting(let currentIdentifier, _) = state,
               currentIdentifier == identifier {
                state = .stopped
            }
            AppLog.proxy.error("Magent core service failed to start")
            throw error
        }
    }

    /// 等待停止任务结束，并将仍属于该任务的状态更新为已停止。
    ///
    /// - Parameters:
    ///   - identifier: 本次停止任务的唯一标识。
    ///   - task: 等待完成的 Magent 关闭任务。
    private func completeShutdown(
        identifier: UUID,
        task: Task<Void, Error>
    ) async throws {
        do {
            try await task.value
            if case .stopping(let currentIdentifier, _) = state,
               currentIdentifier == identifier {
                state = .stopped
                AppLog.proxy.info("Magent core service stopped")
            }
        } catch {
            if case .stopping(let currentIdentifier, _) = state,
               currentIdentifier == identifier {
                state = .stopped
            }
            AppLog.proxy.error("Magent core service failed to stop")
            throw error
        }
    }

    /// 串行化启动和关闭操作所需的内部生命周期状态。
    private enum State {
        case stopped
        case starting(UUID, Task<Magent, Error>)
        case running(Magent)
        case stopping(UUID, Task<Void, Error>)
    }
}
