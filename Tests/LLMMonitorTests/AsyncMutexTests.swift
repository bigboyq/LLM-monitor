import XCTest
@testable import LLM_monitor

/// `Services/Infra/AsyncMutex.swift` 的 cancellation-aware acquire 规则。
/// 拆自 `ScannerAndLoggingTests`，逐字搬移零逻辑变化。
final class AsyncMutexTests: XCTestCase {

    /// AsyncMutex 取消规则 2 in 1（cancellation-aware acquire 的两条文档化路径）：
    /// - 快速路径：任务在 acquire 前已被取消 → 不得取得空闲锁，抛 CancellationError
    /// - 排队路径：任务挂进 waiters 队列后被取消 → 立即抛 CancellationError，不拿锁
    /// 旧版直接 `task.cancel()` 后断言：无竞争 withLock 可能在 cancel 落地前就
    /// 跑完，断言退化为掷硬币（套件里实测出现过偶发 fail）。现在用确定性构造：
    /// ScanGate 保证 cancel 先于 withLock；持锁 fixture 保证任务无法在取消前
    /// 完成 acquire（先入队被 cancelWaiter 唤醒、或 fast path 检查点抛出，二者
    /// 都返回 true）。
    func testAsyncMutexAcquireCancellationRules() async throws {
        // 1. 快速路径：先取消、后 acquire
        do {
            let mutex = AsyncMutex()
            let gate = ScanGate()
            let task = Task<Bool, Never> { @Sendable in
                do {
                    await gate.enter()
                    _ = try await mutex.withLock { true }
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }
            await gate.waitUntilStarted()
            task.cancel()
            await gate.release()
            let wasCancelled = await task.value
            XCTAssertTrue(wasCancelled, "已取消任务不得取得空闲锁（fast path checkCancellation）")
        }
        // 2. 排队路径：锁被 holder 持有，任务在 waiters 队列中被取消
        do {
            let mutex = AsyncMutex()
            let holder = Task<Bool, Never> { @Sendable in
                do {
                    return try await mutex.withLock {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        return true
                    }
                } catch {
                    return false
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000) // holder 稳定持锁
            let task = Task<Bool, Never> { @Sendable in
                do {
                    _ = try await mutex.withLock { true }
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000) // task 已挂进 waiters
            task.cancel()
            let wasCancelled = await task.value
            XCTAssertTrue(wasCancelled, "排队中的 waiter 被取消应立即抛 CancellationError")
            let holderKept = await holder.value
            XCTAssertTrue(holderKept, "fixture: holder 应成功持有并释放锁")
        }
    }
}
