import XCTest
@testable import LLM_monitor

/// F4：MenuInactivityTimer 计时状态机的 start/reset/cancel 自动化测试。
/// 真实的 30 秒关闭、持续滚动不关闭、失焦立即关闭需在 Release app 上手工 QA。
@MainActor
final class MenuAutoCloseTests: XCTestCase {

    /// 记录式 fake 调度器：捕获安排的延时闭包，测试可手动触发或取消。
    private final class FakeScheduler: InactivityScheduler {
        private(set) var scheduledDelays: [TimeInterval] = []
        private(set) var handles: [FakeHandle] = []

        func schedule(
            after delay: TimeInterval,
            _ block: @escaping @MainActor @Sendable () -> Void
        ) -> any InactivityHandle {
            let handle = FakeHandle(block: block)
            scheduledDelays.append(delay)
            handles.append(handle)
            return handle
        }
    }

    private final class FakeHandle: InactivityHandle {
        let block: @MainActor @Sendable () -> Void
        private(set) var isCancelled = false

        init(block: @escaping @MainActor @Sendable () -> Void) {
            self.block = block
        }

        func cancel() {
            isCancelled = true
        }

        @MainActor
        func fire() {
            block()
        }
    }

    func testInactivityTimerFiresAfterInterval() {
        let scheduler = FakeScheduler()
        var closeCallCount = 0
        let timer = MenuInactivityTimer(
            interval: 30,
            scheduler: scheduler,
            onClose: { closeCallCount += 1 }
        )
        timer.startOrReset()

        XCTAssertEqual(scheduler.scheduledDelays, [30], "startOrReset 应安排一次 interval 后触发")
        XCTAssertEqual(scheduler.handles.count, 1)

        // 触发安排的闭包 → close 被调用一次
        scheduler.handles[0].fire()
        XCTAssertEqual(timer.fireCount, 1)
        XCTAssertEqual(closeCallCount, 1)
    }

    func testInactivityTimerResetCancelsOldFire() {
        let scheduler = FakeScheduler()
        var closeCallCount = 0
        let timer = MenuInactivityTimer(
            interval: 30,
            scheduler: scheduler,
            onClose: { closeCallCount += 1 }
        )
        timer.startOrReset()
        // 交互事件触发 reset：旧 handle 被取消并替换为新 handle
        timer.startOrReset()

        XCTAssertEqual(scheduler.handles.count, 2)
        XCTAssertTrue(scheduler.handles[0].isCancelled, "reset 应取消旧 handle")

        // 旧的 handle 即使 fire 也不应触发 close（token 已失效）
        scheduler.handles[0].fire()
        XCTAssertEqual(closeCallCount, 0, "被 reset 替换的旧计时不应触发 close")
        XCTAssertEqual(timer.fireCount, 0)

        // 最新的 handle fire 才触发
        scheduler.handles[1].fire()
        XCTAssertEqual(closeCallCount, 1)
        XCTAssertEqual(timer.fireCount, 1)
    }

    func testInactivityTimerCancelPreventsFire() {
        let scheduler = FakeScheduler()
        var closeCallCount = 0
        let timer = MenuInactivityTimer(
            interval: 30,
            scheduler: scheduler,
            onClose: { closeCallCount += 1 }
        )
        timer.startOrReset()
        timer.cancel()

        XCTAssertTrue(scheduler.handles[0].isCancelled, "cancel 应取消当前 handle")
        // cancel 后即便 fire 也不触发 close（token 已轮换）
        scheduler.handles[0].fire()
        XCTAssertEqual(closeCallCount, 0)
        XCTAssertEqual(timer.fireCount, 0)
    }

    func testInactivityTimerStartOrResetReplacesPrevious() {
        let scheduler = FakeScheduler()
        let timer = MenuInactivityTimer(
            interval: 30,
            scheduler: scheduler,
            onClose: {}
        )
        timer.startOrReset()
        timer.startOrReset()
        timer.startOrReset()
        // 三次 startOrReset 安排三次，前两次被取消
        XCTAssertEqual(scheduler.handles.count, 3)
        XCTAssertTrue(scheduler.handles[0].isCancelled)
        XCTAssertTrue(scheduler.handles[1].isCancelled)
        XCTAssertFalse(scheduler.handles[2].isCancelled, "最新 handle 不应被取消")
    }
}
