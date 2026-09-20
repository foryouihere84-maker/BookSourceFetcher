//
//  AsyncSemaphore.swift
//  BookSourceFetcher
//
//  固定许可数的异步信号量：限制同时进行的请求数，实现"做完一个补一个"的持续限流，
//  替代分批 barrier（chunks）造成槽位空等的问题。支持任务取消，取消的等待者不残留。
//

import Foundation

/// 固定许可数的异步信号量。
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Error>] = []

    init(permits: Int) {
        self.available = max(1, permits)
    }

    /// 获取一个许可；无可用许可时挂起直到有许可释放。任务取消时抛出 CancellationError。
    func acquire() async throws {
        if available > 0 {
            available -= 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                waiters.append(cont)
            }
        } onCancel: {
            Task { await self.cancelWaiter() }
        }
    }

    /// 释放一个许可：优先唤醒最早等待者，否则归还计数。
    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            available += 1
        }
    }

    /// 在持有许可期间执行 body，随后自动释放。任务取消（acquire 失败）时返回 nil。
    /// - Returns: body 的返回值；若因取消未执行 body，返回 nil。
    func withPermit<T>(_ body: @Sendable () async -> T) async -> T? {
        do {
            try await acquire()
        } catch {
            return nil
        }
        defer {
            // release 在 actor 上串行执行；用 detached 避免继承已取消的上下文导致许可不归还。
            Task.detached { [weak self] in await self?.release() }
        }
        return await body()
    }

    private func cancelWaiter() {
        guard !waiters.isEmpty else { return }
        // 取消场景下所有等待者都会被逐一取消；此处移除队首并恢复其 task，
        // 使其抛 CancellationError（与 withPermit 的 catch 配合返回 nil）。
        let waiter = waiters.removeFirst()
        waiter.resume(throwing: CancellationError())
    }
}
