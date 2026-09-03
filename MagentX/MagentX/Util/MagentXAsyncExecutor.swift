//
//  MagentXAsyncExecutor.swift
//  MagentX
//
//  Author: MarlinL
//  Responsibility: Owns app-wide asynchronous operation submission and blocking work dispatch.
//

import Foundation
@preconcurrency import NIOPosix

/// MagentX 全局异步执行入口，统一持有非结构化任务，并把阻塞工作调度到 SwiftNIO 共享线程池。
@MainActor
final class MagentXAsyncExecutor {
    static let shared = MagentXAsyncExecutor()

    private let blockingThreadPool: NIOThreadPool
    private var tasks: [UUID: Task<Void, Never>] = [:]

    private init(blockingThreadPool: NIOThreadPool = .singleton) {
        self.blockingThreadPool = blockingThreadPool
    }

    /// 提交一个异步操作，持有其生命周期直至完成，并在主 actor 返回成功或原始错误。
    func submit<Output: Sendable>(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async throws -> Output,
        completion: @escaping @MainActor (Result<Output, Error>) -> Void
    ) {
        let identifier = UUID()
        let task = Task(priority: priority) { [weak self] in
            let result: Result<Output, Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }

            completion(result)
            self?.tasks[identifier] = nil
        }
        tasks[identifier] = task
    }

    /// 在 SwiftNIO 的进程级共享阻塞线程池中执行同步工作，并异步返回结果。
    func runBlocking<Output: Sendable>(
        _ operation: @escaping @Sendable () throws -> Output
    ) async throws -> Output {
        try await blockingThreadPool.runIfActive(operation)
    }
}
