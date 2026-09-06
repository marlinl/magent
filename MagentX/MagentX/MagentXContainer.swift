//
//  MagentXContainer.swift
//  MagentX
//
//  Created by MarlinL on 2026/9/4.
//

import FactoryKit
import Foundation
@preconcurrency import NIOPosix

/// 应用内异步执行器，统一保活异步流程，并把同步阻塞工作分派给 SwiftNIO 线程池。
nonisolated final class LocalExecutor: @unchecked Sendable {
    private let blockingThreadPool: NIOThreadPool
    private let taskLock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// 使用 SwiftNIO 进程级线程池创建执行器。
    fileprivate init(blockingThreadPool: NIOThreadPool = .singleton) {
        self.blockingThreadPool = blockingThreadPool
    }

    /// 提交异步操作并持有其生命周期，完成后在主 actor 返回成功结果或原始错误。
    ///
    /// - Parameters:
    ///   - priority: 异步任务的调度优先级。
    ///   - operation: 要执行的异步业务操作。
    ///   - completion: 操作结束后在主 actor 执行的结果处理。
    func submit<Output: Sendable>(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async throws -> Output,
        completion: @escaping @MainActor @Sendable (Result<Output, Error>) -> Void
    ) {
        let identifier = UUID()
        taskLock.lock()
        let task = Task(priority: priority) { [weak self] in
            defer {
                self?.removeTask(identifier)
            }

            let result: Result<Output, Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }

            await completion(result)
        }
        tasks[identifier] = task
        taskLock.unlock()
    }

    /// 将同步阻塞操作提交到 SwiftNIO 线程池，并异步返回其结果。
    ///
    /// - Parameter operation: 不得占用主 actor 的同步阻塞操作。
    /// - Returns: 阻塞操作的结果。
    /// - Throws: 线程池不可用或操作本身失败时抛出原始错误。
    func runBlocking<Output: Sendable>(
        _ operation: @escaping @Sendable () throws -> Output
    ) async throws -> Output {
        try await blockingThreadPool.runIfActive(operation)
    }

    /// 在异步流程结束后移除其保活引用。
    ///
    /// - Parameter identifier: 已完成流程的唯一标识。
    private func removeTask(_ identifier: UUID) {
        taskLock.lock()
        tasks[identifier] = nil
        taskLock.unlock()
    }
}

extension Container {
    /// 提供进程内唯一的异步执行器，统一调度业务异步流程和阻塞工作。
    var localExecutor: Factory<LocalExecutor> {
        self {
            LocalExecutor()
        }
        .cached
    }

    /// 提供进程内唯一的 Magent 核心运行服务，由服务自身重建已关闭的底层运行时。
    @MainActor
    var magentService: Factory<MagentService> {
        self {
            MagentService()
        }
        .cached
    }

    /// 提供绑定当前 SwiftData 容器的代理规则服务；应用启动时必须先注册实际实例。
    @MainActor
    var magentProxyRuleService: Factory<MagentProxyRuleService> {
        self {
            preconditionFailure("MagentProxyRuleService must be registered during application startup")
        }
        .onPreview {
            do {
                let modelContainer = try MagentXApp.makeModelContainer(isStoredInMemoryOnly: true)
                return MagentProxyRuleService(modelContainer: modelContainer)
            } catch {
                preconditionFailure("Failed to create preview model container: \(error.localizedDescription)")
            }
        }
        .cached
    }
}
