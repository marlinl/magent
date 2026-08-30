//
//  MagentService.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Owns the Magent core service lifecycle for the macOS app.
//

import Foundation
import Magent

/// Magent 核心服务适配器，负责创建、启动和关闭单个 `Magent` 运行实例。
///
/// `Magent.close()` 会回收实例自己的 EventLoopGroup，因此停止后再次启动时会创建新实例。
actor MagentService {
    private let threadNumber: Int
    private var state: State = .stopped

    /// 创建一个尚未启动的核心服务，线程数会在首次启动前校验。
    init(threadNumber: Int) {
        self.threadNumber = threadNumber
    }

    /// 使用给定配置启动 Magent；已启动或正在启动时保持幂等。
    func start(_ configuration: MagentConfig) async throws {
        switch state {
        case .stopped:
            guard threadNumber > 0 else {
                throw MagentXError.invalidProxyThreadNumber(threadNumber)
            }

            let identifier = UUID()
            let magent = Magent(threadNumber: threadNumber)
            let task = Task { () throws -> Magent in
                try await magent.start(configuration)
                return magent
            }
            state = .starting(identifier, task)
            try await completeStartup(identifier: identifier, task: task)
        case .starting(let identifier, let task):
            try await completeStartup(identifier: identifier, task: task)
        case .running:
            return
        case .stopping(let identifier, let task):
            try await completeShutdown(identifier: identifier, task: task)
            try await start(configuration)
        }
    }

    /// 关闭当前 Magent 实例；未启动或正在关闭时保持幂等。
    func stop() async throws {
        switch state {
        case .stopped:
            return
        case .starting(let identifier, let task):
            try await completeStartup(identifier: identifier, task: task)
            try await stop()
        case .running(let magent):
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

    private func completeStartup(
        identifier: UUID,
        task: Task<Magent, Error>
    ) async throws {
        do {
            let magent = try await task.value
            if case .starting(let currentIdentifier, _) = state,
               currentIdentifier == identifier {
                state = .running(magent)
            }
        } catch {
            if case .starting(let currentIdentifier, _) = state,
               currentIdentifier == identifier {
                state = .stopped
            }
            throw error
        }
    }

    private func completeShutdown(
        identifier: UUID,
        task: Task<Void, Error>
    ) async throws {
        do {
            try await task.value
            if case .stopping(let currentIdentifier, _) = state,
               currentIdentifier == identifier {
                state = .stopped
            }
        } catch {
            if case .stopping(let currentIdentifier, _) = state,
               currentIdentifier == identifier {
                state = .stopped
            }
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
