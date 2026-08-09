import Foundation

/// Async-aware 互斥锁。Swift 5.10 stdlib 没原生 async mutex（`Mutex` 6.0+ 才有），
/// 也不像 `NSLock` 那样 "unlock() in async context" 在 Swift 6 mode 报错。
///
/// 用 `actor` 串行化 acquire/release：actor 保证同一时间只有一个方法在 actor 的
/// executor 上跑（直到 await），多个 worker 调 `withLock` 排队，互不干扰。
///
/// ## 为什么不用 `NSLock` 跨 await
///
/// 之前 scanner 的 `scanLock` 是 NSLock，在 `performScanPure` 入口 lock()、defer
/// unlock()。整个 pipeline (load → RPC → SQL → save) 都持锁。问题:
/// - Swift 6 警告: `unlock() is unavailable from asynchronous contexts`
/// - RPC 期间长期持锁，阻塞其他 worker
///
/// AsyncMutex 方案: 整个 performScanPure 在 `await mutex.withLock { ... }` 里
/// 跑，锁跨 await 是设计内的（async-aware），Swift 6 mode 也允许。
///
/// ## 实现方式：actor + continuation FIFO
///
/// actor 只负责串行保护 `locked` 与 `waiters` 状态；等待锁的任务仍由显式
/// `CheckedContinuation` FIFO 队列挂起。`release()` 把所有权交给队首，取消则按
/// waiter id 从队列移除。这样等待任务不会同步阻塞 cooperative thread。
///
/// ## Cancellation 语义（cancellation-aware）
///
/// `acquire()` 用 `withTaskCancellationHandler` + `withCheckedThrowingContinuation`
/// 包装：caller 在 waiters 队列里被 `Task.cancel()` 时，**立即抛 CancellationError
/// 退出**（不拿锁、不跑 work）。
///
/// 关键 race 处理：cancel 和 release 都想 resume 同一个 continuation，
/// 双方都通过 actor 隔离操作 `waiters` 列表：
/// - `cancelWaiter(id)`: 找到 waiter 移除 + resume throw（找不到说明 release 已经
///   处理了这个 waiter，cancel 啥也不做）
/// - `release()`: 取队首移除 + resume returning；无等待者时清除 `locked`
///
/// 双方通过 actor 串行化保证**只**一个 resume：
/// - cancel 先到：waiter 被 cancel 移除 + resume throw，release 取下一个 waiter
/// - release 先到：waiter 被 release 移除 + resume returning，cancel handler 后到
///   找不到 waiter，啥也不做
///
/// ## 用法
///
/// ```swift
/// static let pipelineMutex = AsyncMutex()
///
/// static func performScanPure(...) async throws -> Usage {
///     return try await pipelineMutex.withLock {
///         // 这里跑整个 pipeline, 包括 await RPC / SQL
///         // 多个 worker 调 performScanPure 会自动排队, 互不干扰
///         return try performScanPureImpl(...)
///     }
/// }
/// ```
actor AsyncMutex {
    private var locked: Bool = false
    /// 等锁的 worker 队列（FIFO）。每个元素是 `Waiter(id, continuation)`，
    /// `release()` 时 resume 队首；被 cancel 时按 id 移除并 resume throw。
    private var waiters: [Waiter] = []

    /// 一个等待锁的 waiter：`id` 用于 cancel handler 精准移除（防止 cancel 到错的 waiter），
    /// `continuation` 用于 `acquire()` resume 或 cancel handler resume throw。
    /// 状态机由 actor 串行化保护：resume 只能由 cancel 或 release 二选一触发。
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    /// 跑 work, 互斥保证同一时间只有一个 work 在跑 (跨 await 持锁).
    ///
    /// 该锁不可重入：持锁的 work 再次调用同一个 `AsyncMutex.withLock` 会等待
    /// 自己释放锁，形成永久等待。需要嵌套逻辑时，应把内层 work 合并到外层临界区。
    /// work 可以 await, 不会释放锁 —— 跟 NSLock 行为一致, 但 async-safe.
    /// 拿锁期间 caller 被 cancel 也会抛 CancellationError（不会偷偷跑 work）。
    func withLock<T: Sendable>(
        _ work: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        // defer release 不能跨 await (跟 NSLock defer 一样问题),
        // 用 do-catch 显式 try/catch 保证 release 在抛错时也跑.
        do {
            // release/cancel race 中，release 可能已经把锁所有权传给这个任务，
            // 随后 cancellation handler 因 waiter 已出队而无法再取消 continuation。
            // 在进入 work 前重新检查；若已取消，catch 会释放已经接手的锁。
            try Task.checkCancellation()
            let result = try await work()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    /// 等锁. 已持锁则挂起到 waiters 队列, 队首被 release 时唤醒.
    /// 期间 caller 被 cancel → 立即抛 CancellationError（不拿锁）.
    private func acquire() async throws {
        // cancellation handler 只覆盖排队路径；快速路径必须在拿锁前单独检查，
        // 避免一个调用前就已取消的任务直接取得空闲锁。
        try Task.checkCancellation()
        if !locked {
            locked = true
            return
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                // 注册 waiter 到队列。actor 隔离保护 waiters 数组不被并发改。
                waiters.append(Waiter(id: waiterID, continuation: cont))
            }
        } onCancel: {
            // cancel handler 同步触发：被 cancel 时**立即**让 caller 抛 CancellationError。
            // 走 Task { await ... } 切到 actor 隔离的 `cancelWaiter` —— 不能直接
            // await actor（cancel handler 不能 await），但 spawn 出去的 Task 立刻调度。
            // 这个 fire-and-forget 是 Swift 5+ 标准的 cancellation propagation 模式。
            let id = waiterID
            Task { await self.cancelWaiter(id: id) }
        }
        // 被 release 唤醒后, 锁已经传递给我们 (release 不清 locked, 只 resume 队首)
    }

    /// 取消一个 waiter：从队列移除 + resume throw。
    /// 找不到 waiter（已经被 release 处理）就什么也不做 —— 这是 cancel / release
    /// race 的兜底。actor 串行化保证不会两个 resume 同一 waiter。
    private func cancelWaiter(id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else {
            // waiter 已被 release 移除（race 输给 release）—— 不做事。
            return
        }
        let waiter = waiters.remove(at: idx)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// 放锁. 如果有等待者, 把锁传递给它 (locked 保持 true); 否则清 locked.
    /// resume 走的是 `waiter.continuation`（CheckedContinuation<Void, Error>），
    /// 用 `returning: ()` 不会抛错 —— 出错路径（cancel）已经在 `cancelWaiter` 走。
    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.continuation.resume(returning: ())
            // locked 保持 true, 锁"传递给"下一个 worker
        } else {
            locked = false
        }
    }

    /// 测试同步点：等待显式 FIFO 中至少出现指定数量的 waiter。
    /// `Task.yield()` 让 actor 可重入处理正在到达的 acquire，不依赖墙钟 sleep 猜时序。
    func waitUntilQueuedWaiterCountForTesting(_ minimumCount: Int) async {
        precondition(minimumCount >= 0)
        while waiters.count < minimumCount {
            await Task.yield()
        }
    }
}
