import XCTest
@testable import LLM_monitor

final class ScheduledTaskTests: XCTestCase {

    // MARK: - FixedDeadlineTask Tests

    @MainActor
    func testFixedDeadlineTaskIgnoresSubsequentCallsUntilFired() {
        let task = FixedDeadlineTask()
        var fireCount = 0

        XCTAssertFalse(task.isPending)
        task.schedule(delay: 0.1) {
            fireCount += 1
        }
        XCTAssertTrue(task.isPending)

        // 模拟倒计时期间高频重复调用（如 0.08s 巡检）
        for _ in 0..<5 {
            task.schedule(delay: 0.1) {
                fireCount += 100 // 如果重新排期并覆盖，会导致错误
            }
        }
        XCTAssertTrue(task.isPending)

        let exp = expectation(description: "等待固定 deadline 触发")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            XCTAssertEqual(fireCount, 1, "固定 deadline 期间的重复调用应被忽略，到期严格触发一次")
            XCTAssertFalse(task.isPending, "触发完毕后 isPending 自动复位为 false")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    @MainActor
    func testFixedDeadlineTaskCancel() {
        let task = FixedDeadlineTask()
        var fired = false

        task.schedule(delay: 0.05) {
            fired = true
        }
        XCTAssertTrue(task.isPending)
        task.cancel()
        XCTAssertFalse(task.isPending)

        let exp = expectation(description: "验证已取消的任务不会触发")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            XCTAssertFalse(fired)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - KeyedScheduledTask Tests

    @MainActor
    func testKeyedScheduledTaskMaintainsDeadlineToPreventStarvation() {
        let task = KeyedScheduledTask<Int>()
        var firedIndex: Int?

        task.schedule(key: 1, delay: 0.1) {
            firedIndex = 1
        }
        XCTAssertTrue(task.isPending)
        XCTAssertEqual(task.pendingKey, 1)

        // 高频对同一个 key 调度（模拟 20ms 巡检，小于 100ms 延时）
        for _ in 0..<8 {
            task.schedule(key: 1, delay: 0.1) {
                firedIndex = 999
            }
            XCTAssertTrue(task.isPending)
            XCTAssertEqual(task.pendingKey, 1)
        }

        let exp = expectation(description: "等待相同 key 倒计时到期")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            XCTAssertEqual(firedIndex, 1, "相同 key 连续调用不得重排倒计时，应在原 deadline 到期触发")
            XCTAssertFalse(task.isPending)
            XCTAssertNil(task.pendingKey)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    @MainActor
    func testKeyedScheduledTaskResetsTimerWhenKeyChanges() {
        let task = KeyedScheduledTask<String>()
        var executed: [String] = []

        task.schedule(key: "A", delay: 0.1) {
            executed.append("A")
        }
        XCTAssertEqual(task.pendingKey, "A")

        // 50ms 后切换到 key B（小于 0.1s）
        let switchExp = expectation(description: "切换目标 key")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            task.schedule(key: "B", delay: 0.1) {
                executed.append("B")
            }
            XCTAssertEqual(task.pendingKey, "B")
            switchExp.fulfill()
        }
        wait(for: [switchExp], timeout: 0.5)

        // 再过 120ms（从 B 开始算超 100ms，从 A 开始算已超 170ms）
        let finishExp = expectation(description: "等待 B 到期")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            XCTAssertEqual(executed, ["B"], "切换目标 key 后应取消 A 的任务，仅触发 B")
            XCTAssertFalse(task.isPending)
            finishExp.fulfill()
        }
        wait(for: [finishExp], timeout: 0.5)
    }

    // MARK: - DebouncedTask Tests

    @MainActor
    func testDebouncedTaskExtendsDeadlineOnEachCall() {
        let task = DebouncedTask()
        var fireCount = 0

        // 连续防抖调度：每次调用推迟 0.08s
        task.schedule(delay: 0.08) { fireCount += 1 }
        
        let exp = expectation(description: "多次调用后静默触发")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            task.schedule(delay: 0.08) { fireCount += 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            task.schedule(delay: 0.08) { fireCount += 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            XCTAssertEqual(fireCount, 1, "连续防抖调用应合并，静默后仅触发一次")
            XCTAssertFalse(task.isPending)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }
}
