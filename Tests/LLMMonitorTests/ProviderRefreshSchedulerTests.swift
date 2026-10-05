import XCTest
import Combine
import AppKit
import os
@testable import LLM_monitor

/// 刷新排期 / dedup / 取消，以及 `waitUntilNotInFlight` 的 cancel-after-resume 竞态。
/// 对应 `ProviderRefreshScheduler`。
///
/// 合并自 `RefreshSchedulerMidCycleTests`（mid-cycle 补刷新）与
/// `RefreshBalanceRegressionTests`（刷新余额回归），逐字搬移零逻辑变化。
final class ProviderRefreshSchedulerTests: StateTestCase {

    /// 该 provider 的常规排期是否已由一次真实 batch 结算。
    ///
    /// `schedule(for:)` 会立刻写入 provisional `now()`，所以"非 nil"不等于"已结算"；
    /// 结算后写入的是 `settledAt + interval`，必然落在未来。用"落在未来"当收敛信号，
    /// 既无竞态（结算写入与 runningProviders 清理之间的代码不再 await），也无需固定
    /// sleep 去等一个纯内存的调度状态。
    @MainActor
    private static func hasSettledRegularDate(
        _ scheduler: ProviderRefreshScheduler,
        _ providerID: String,
        now: Date = Date()
    ) -> Bool {
        guard let date = scheduler.nextRefreshDate(for: providerID) else { return false }
        return date > now
    }

    // MARK: - ProviderRefreshScheduler: 排期 / dedup / 取消
    @MainActor
    func testSchedulerInFlightDedup() {
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .deferred },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {}
        )
        XCTAssertTrue(scheduler.markInFlight("a"), "首次 markInFlight 应返回 true")
        XCTAssertFalse(scheduler.markInFlight("a"), "同 provider 二次 markInFlight 应返回 false")
        XCTAssertEqual(scheduler.inFlightProviderIDs, ["a"])
        scheduler.markNotInFlight("a")
        XCTAssertTrue(scheduler.markInFlight("a"), "markNotInFlight 后应能重新加入")
        XCTAssertEqual(scheduler.inFlightProviderIDs, ["a"])
    }
    @MainActor
    func testSchedulerSystemWakeCoalescesInFlightAndRecentRefresh() async {
        var calls = 0
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in
                calls += 1
                return .completed(success: true)
            },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {},
            systemWakeCoalesceWindow: 0.2
        )

        // A wake waiting on an existing request must not register a manual gate
        // or issue a parallel second request; once that request settles without
        // fresh activity the wake still issues exactly one full, so the wake
        // refresh is never silently dropped.
        XCTAssertTrue(scheduler.markInFlight("p"))
        let waitingWake = Task { @MainActor in
            await scheduler.refreshForSystemWake("p")
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
        scheduler.markNotInFlight("p")
        await waitingWake.value
        XCTAssertEqual(calls, 1, "在飞请求结算后唤醒必须补发一次 full，不得静默丢弃")

        // A wake immediately following a completed request is satisfied by
        // that request; after the injectable collision window it runs one full.
        _ = await scheduler.runRefresh("p", mode: .background)
        XCTAssertEqual(calls, 2)
        await scheduler.refreshForSystemWake("p")
        XCTAssertEqual(calls, 2)
        try? await Task.sleep(nanoseconds: 250_000_000)
        await scheduler.refreshForSystemWake("p")
        XCTAssertEqual(calls, 3)
        scheduler.cancelAll()
    }
    @MainActor
    func testSchedulerWakeFirstSatisfiesAlreadyDueRegularDeadline() async {
        var calls = 0
        var releaseWake = false
        var nextRefreshChanges = 0
        var settledBatches = 0
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in
                calls += 1
                if calls == 2 {
                    while !releaseWake {
                        try? await Task.sleep(nanoseconds: 1_000_000)
                    }
                }
                return .completed(success: true)
            },
            intervalProvider: { _ in 0.15 },
            onNextRefreshChange: { nextRefreshChanges += 1 },
            onBatchSettled: { settledBatches += 1 }
        )
        scheduler.schedule(for: "p")
        for _ in 0..<100 where calls < 1 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(calls, 1)
        try? await Task.sleep(nanoseconds: 10_000_000)
        let baselineNextRefreshChanges = nextRefreshChanges
        let baselineSettledBatches = settledBatches
        let previousNextRefresh = scheduler.earliestNextRefresh

        // Start wake before the regular deadline. The regular driver will see
        // the wake request in flight when its deadline arrives and must settle
        // it, rather than dispatching a deferred third request.
        try? await Task.sleep(nanoseconds: 30_000_000)
        let wake = Task { @MainActor in
            await scheduler.refreshForSystemWake("p")
        }
        for _ in 0..<100 where calls < 2 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(calls, 2)
        try? await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertEqual(calls, 2, "wake 与 regular deadline 碰撞时只能有一次实际 fetch")
        releaseWake = true
        await wake.value
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(nextRefreshChanges, baselineNextRefreshChanges + 1)
        XCTAssertEqual(settledBatches, baselineSettledBatches + 1)
        XCTAssertGreaterThan(
            scheduler.earliestNextRefresh ?? .distantPast,
            previousNextRefresh ?? .distantPast,
            "外部请求结算 regular deadline 后必须推进 next refresh"
        )
        scheduler.cancelAll()
    }
    @MainActor
    func testSchedulerWakeCoalescesBeforeScheduledHandlerMarksInFlight() async {
        var calls = 0
        var releaseInitial = false
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in
                calls += 1
                while !releaseInitial {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                return .completed(success: true)
            },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {}
        )
        scheduler.schedule(for: "p")
        for _ in 0..<100 where scheduler.runningProviderIDs.isEmpty {
            await Task.yield()
        }
        XCTAssertTrue(
            scheduler.runningProviderIDs.contains("p"),
            "deadline driver 应在投递 batch 前登记 running provider"
        )

        let wake = Task { @MainActor in
            await scheduler.refreshForSystemWake("p")
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(calls, 1, "wake 应等待已投递 batch，而不是再开一个请求")
        releaseInitial = true
        await wake.value
        XCTAssertEqual(calls, 1)
        scheduler.cancelAll()
    }
    @MainActor
    func testSchedulerCancellingRunningWakeWaiterDoesNotHang() async {
        var releaseInitial = false
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in
                while !releaseInitial {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                return .completed(success: true)
            },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {}
        )
        scheduler.schedule(for: "p")
        for _ in 0..<100 where scheduler.runningProviderIDs.isEmpty {
            await Task.yield()
        }

        let wake = Task { @MainActor in
            await scheduler.refreshForSystemWake("p")
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        scheduler.cancel(providerID: "p")
        releaseInitial = true

        // If cancel failed to resume the running continuation this await would
        // hang indefinitely; the bounded task gives the assertion a clear
        // failure instead.
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                await wake.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 200_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        XCTAssertTrue(finished)
        scheduler.cancelAll()
    }
    @MainActor
    func testSchedulerResetDueDuringLongRequestIsSettledOnceAfterwards() async {
        var calls = 0
        var releaseInitial = false
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in
                calls += 1
                if calls == 1 {
                    while !releaseInitial {
                        try? await Task.sleep(nanoseconds: 1_000_000)
                    }
                }
                return .completed(success: true)
            },
            intervalProvider: { _ in 300 },
            onNextRefreshChange: {},
            midCycleResetDelay: 0.05
        )
        scheduler.schedule(for: "p")
        for _ in 0..<100 where calls < 1 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(calls, 1)

        // 新规则要求 reset executionAt 距上次 Interval 完成严格超过 30 秒。
        // 首次 Interval 尚未完成时，过期/临近 reset 直接跳过，不得补发请求。
        scheduler.scheduleMidCycleResetRefreshes(
            for: "p", resetsAtDates: [Date().addingTimeInterval(-0.04)]
        )
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(calls, 1, "running provider 的过期 reset 不应重复派发或 busy-loop")

        releaseInitial = true
        for _ in 0..<200 where calls < 1 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(calls, 1, "不满足前置 30 秒窗口的 reset 必须跳过")
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls, 1)
        scheduler.cancelAll()
    }
    /// 失败不指数退避：连续失败 8 轮（突破旧退避的封顶 5）再到成功，每一拍的
    /// 排期都精确落在上一拍 + baseInterval 上——失败与成功的排期完全一致。
    /// 近零 sleep 让 deadline driver 借 lastCompletedTargetWakeDate 立即续拍，
    /// 而 nextRefreshDates 仍按真实时钟写入，可精确断言排期偏移量。
    @MainActor
    func testSchedulerFailureDoesNotStretchInterval() async {
        var callDates: [Date] = []
        /// 每拍入口读到的"上一拍写下的排期"相对上一拍调用时刻的偏移
        var scheduledGaps: [TimeInterval] = []
        let holder = WeakSchedulerHolder()
        let sched = ProviderRefreshScheduler(
            refreshHandler: { _, _ in
                if let previous = callDates.last, let next = holder.sched?.earliestNextRefresh {
                    scheduledGaps.append(next.timeIntervalSince(previous))
                }
                callDates.append(Date())
                if callDates.count >= 12 { holder.sched?.cancelAll() }
                // 前 8 次失败，之后成功：失败→成功的过渡排期必须无差别
                return callDates.count > 8 ? .completed(success: true) : .completed(success: false)
            },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {},
            sleep: { _ in try? await Task.sleep(nanoseconds: 1) }
        )
        holder.sched = sched
        sched.schedule(for: "a")
        // 条件等待：handler 跑满 12 轮即满足（正常 <10ms），timeout 只作安全网。
        let reachedTwelve = await waitUntil { callDates.count >= 12 }
        XCTAssertTrue(reachedTwelve, "12 轮刷新应在超时前跑完")
        sched.cancelAll()

        XCTAssertEqual(callDates.count, 12, "应正好跑 12 轮后自行 cancel，实际 \(callDates.count)")
        XCTAssertEqual(scheduledGaps.count, 11)
        for (index, gap) in scheduledGaps.enumerated() {
            XCTAssertEqual(
                gap, 60, accuracy: 1.0,
                "第 \(index + 1) 拍的排期必须恒为 baseInterval(60s)，不允许 2^n 退避"
            )
        }
    }
    @MainActor
    func testSchedulerCancelProviderClearsNextRefresh() async {
        // schedule 一次让 nextRefreshDates 有内容（注意：我们用真 task 来测 cancel，
        // 但 task 第一次进 refreshHandler 会立刻返回 .deferred → 1s 重试。这里只验证
        // 取消能让 nextRefreshDates 立即清空，不验证 task 取消后的副作用）。
        let counter = CallCounter()
        let schedWithHandler = ProviderRefreshScheduler(
            refreshHandler: { _, mode in
                await counter.tickCalled(mode: mode)
                return .deferred
            },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {}
        )
        schedWithHandler.schedule(for: "a")
        // 等第一次 handler 触发（.deferred → 1s sleep 期间 cancel）
        try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s 让 task 起来
        let callsAfterStart = await counter.calls
        XCTAssertGreaterThanOrEqual(callsAfterStart, 1, "handler 至少应被调 1 次（首次 .full）")
        // 立即 cancel：nextRefreshDates 应清空
        schedWithHandler.cancel(providerID: "a")
        XCTAssertNil(schedWithHandler.earliestNextRefresh, "cancel 后 nextRefreshDates 应清空")
    }
    @MainActor
    func testSchedulerCancelAllClearsEverything() {
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .deferred },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {}
        )
        // 直接灌数据：markInFlight 模拟两个 provider 有活动
        scheduler.markInFlight("a")
        scheduler.markInFlight("b")
        XCTAssertEqual(scheduler.inFlightProviderIDs, ["a", "b"])

        scheduler.cancelAll()
        // cancelAll 清的是 timer 相关状态（tasks / nextRefreshDates）。
        // inFlightIDs 由各 request 的 `defer { markNotInFlight }` 自然清空——
        // 让 in-flight 完成的请求继续标记自己为未在飞，避免请求被吞但 set 状态错乱。
        XCTAssertEqual(scheduler.inFlightProviderIDs, ["a", "b"], "cancelAll 不应清 in-flight 集合")
        XCTAssertNil(scheduler.earliestNextRefresh, "cancelAll 应清空 nextRefreshDates")

        // 模拟各 in-flight 请求的 defer 触发
        scheduler.markNotInFlight("a")
        scheduler.markNotInFlight("b")
        XCTAssertTrue(scheduler.inFlightProviderIDs.isEmpty, "各 defer 触发后 in-flight 集合应清空")
    }
    @MainActor
    func testSchedulerEmitsSettledForInitialEmptyProviderPass() async throws {
        var settledCount = 0
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .completed(success: true) },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {},
            onBatchSettled: { settledCount += 1 },
            sleep: { _ in try await Task.sleep(nanoseconds: 10_000_000) }
        )
        scheduler.start()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(settledCount, 1, "空 Provider 集合也必须完成一次初始 pass")
        scheduler.cancelAll()
    }
    @MainActor
    func testSchedulerEmitsSettledAfterAllProviderOutcomes() async throws {
        var outcomes: [String] = []
        var settledCount = 0
        var outcomeCountsAtSettlement: [Int] = []
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { providerID, _ in
                outcomes.append(providerID)
                return providerID == "failed" ? .completed(success: false) : .completed(success: true)
            },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {},
            onBatchSettled: {
                settledCount += 1
                outcomeCountsAtSettlement.append(outcomes.count)
            },
            sleep: { _ in try await Task.sleep(nanoseconds: 10_000_000) }
        )
        scheduler.schedule(for: "failed")
        scheduler.schedule(for: "success")
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(Set(outcomes), ["failed", "success"])
        XCTAssertGreaterThanOrEqual(settledCount, 1)
        XCTAssertTrue(
            outcomeCountsAtSettlement.contains(2),
            "成功/失败 outcome 全部处理后必须通知 batch settled，实际 (outcomeCountsAtSettlement)"
        )
        scheduler.cancelAll()
    }
    @MainActor
    func testSchedulerScheduleMidCycleResetRefreshesSchedulesExtraFillInRefresh() async {
        var refreshCount = 0
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in
                refreshCount += 1
                return .completed(success: true)
            },
            intervalProvider: { _ in 300 }, // 5 分钟 (300s) 常规节奏
            onNextRefreshChange: {}
        )

        scheduler.schedule(for: "test")
        // 等待首次常规刷新完成
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(refreshCount, 1, "应完成首次常规刷新")

        let initialNextRefresh = scheduler.earliestNextRefresh
        XCTAssertNotNil(initialNextRefresh)

        // 构造一个 resetTime：距下一次常规刷新（~300s）大于 60s
        let resetTime = Date().addingTimeInterval(0.1)
        scheduler.scheduleMidCycleResetRefreshes(for: "test", resetsAtDates: [resetTime])

        // 验证常规刷新节奏（initialNextRefresh）没有被改变 / 重置
        XCTAssertEqual(scheduler.earliestNextRefresh, initialNextRefresh, "补刷新调度不应改变/重置下一次常规刷新时间")

        scheduler.cancelAll()
    }
    // MARK: - P1: ProviderRefreshScheduler waitUntilNotInFlight cancel-after-resume race
    /// `waitUntilNotInFlight` 的 cancel 回调通过 `Task { @MainActor in ... }` 投递。
    /// 如果取消投递在请求完成 + resume 之后才落到主 actor 上，cancel path
    /// 会找不到对应的 waiter（因为 resume path 已经把它移走了）并 early return。
    ///
    /// race 之前如果谁先动到 `continuation.resume(throwing:)` 都会触发
    /// `Continuation was never resumed` / `continuation resumed twice` 崩溃。
    /// 这个测试钉死"先 resume 成功 / 后 cancel 无害"。
    @MainActor
    func testProviderRefreshSchedulerWaitUntilNotInFlightCancelAfterResumeDoesNotCrash() async {
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .deferred },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {}
        )
        scheduler.markInFlight("x", mode: .background)

        // 1. 启动一个 waiter，挂在 continuation 上
        let task = Task<Void, Error> { @MainActor in
            try await scheduler.waitUntilNotInFlight("x")
        }
        // 2. 等 waiter 真的挂到 inFlightWaiters 里
        for _ in 0..<200 where scheduler.inFlightWaiterCount(for: "x") == 0 {
            await Task.yield()
        }
        XCTAssertEqual(scheduler.inFlightWaiterCount(for: "x"), 1, "waiter 已挂上")

        // 3. 先完成 in-flight 请求，再取消 waiter。两次操作都发生在当前
        // MainActor turn 内：markNotInFlight 会先移除并 resume continuation，
        // waiter task 尚未获得执行机会；随后 cancel 会把取消回调排到 actor 上。
        // 这正是“resume 先到、cancel 后到”的竞态窗口。
        scheduler.markNotInFlight("x")
        task.cancel()

        // 4. 等 task 退出。resume 先到时，waitUntilNotInFlight 末尾的
        // Task.checkCancellation() 应把取消传播给调用方；无论取消回调何时执行，
        // 都不能再次 resume 已经移除的 continuation。
        do {
            try await task.value
            XCTFail("waiter 应该抛 CancellationError 而不是正常返回")
        } catch is CancellationError {
            // 期望路径
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(
            scheduler.inFlightWaiterCount(for: "x"), 0,
            "cancel 后 waiter 应被移出队列"
        )

        // 5. 关键 race：取消回调此时可能仍在 actor mailbox 中，但 waiter 已经
        // 被完成路径移走；再次执行 markNotInFlight 必须安全无害。
        scheduler.markNotInFlight("x")
        XCTAssertTrue(scheduler.inFlightProviderIDs.isEmpty, "markNotInFlight 后 inFlight 应清空")

        // 6. 再起一个 waiter —— 这次没人在飞，waitUntilNotInFlight 应直接返回
        //    （验证 cancel-resume 之后 scheduler 状态仍可正常使用）。
        let secondTask = Task<Void, Error> { @MainActor in
            try await scheduler.waitUntilNotInFlight("x")
        }
        do {
            try await secondTask.value
            // 期望：waiter 立即返回（没有 in-flight 等）
        } catch {
            XCTFail("无 in-flight 时 waitUntilNotInFlight 应直接返回，不应抛错: \(error)")
        }
    }
    // MARK: - 单 provider 重锚 / 系统唤醒合并（回归 a287e8d 的 reanchorAllProviders）

    /// 生产路径的在飞请求都经 runRefresh 登记：唤醒等待其结算，而刚结算的
    /// 请求自带新鲜活动记录，唤醒自动合并、不补发第二个 full。
    @MainActor
    func testSchedulerSystemWakeMergesIntoFreshInFlightRequest() async {
        var calls = 0
        var releaseRequest = false
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in
                calls += 1
                while !releaseRequest {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                return .completed(success: true)
            },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {}
        )

        let request = Task { @MainActor in
            _ = await scheduler.runRefresh("p", mode: .background)
        }
        for _ in 0..<100 where scheduler.inFlightMode(for: "p") == nil {
            await Task.yield()
        }
        XCTAssertEqual(calls, 1)

        let wake = Task { @MainActor in
            await scheduler.refreshForSystemWake("p")
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(calls, 1, "唤醒应等待在飞请求，而不是并发补发")
        releaseRequest = true
        await request.value
        await wake.value
        XCTAssertEqual(calls, 1, "结算后请求活动新鲜，唤醒合并不再补发 full")
        scheduler.cancelAll()
    }

    /// 唤醒刷新只结算被刷新 provider 自己的时间线：未到期 provider 的常规
    /// 排期与周期 full 计数必须原样保留（回归 a287e8d 的 reanchorAllProviders）。
    @MainActor
    func testSchedulerSystemWakeRefreshDoesNotDisturbOtherProviderSchedule() async {
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .completed(success: true) },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {},
            systemWakeCoalesceWindow: 0
        )
        scheduler.schedule(for: "a")
        scheduler.schedule(for: "b")
        // 条件等待：两个 provider 的首拍都结算完（排期落到未来 = settledAt + interval；
        // schedule(for:) 刚写入的 provisional 是 now()，落在过去）即满足。
        let bothSettled = await waitUntil {
            Self.hasSettledRegularDate(scheduler, "a") && Self.hasSettledRegularDate(scheduler, "b")
        }
        XCTAssertTrue(bothSettled, "两个 provider 的首拍应在超时前结算")
        let baseA = scheduler.nextRefreshDate(for: "a")
        let baseB = scheduler.nextRefreshDate(for: "b")
        let baseCountA = scheduler.backgroundsSinceFullCount(for: "a")
        let baseCountB = scheduler.backgroundsSinceFullCount(for: "b")
        XCTAssertNotNil(baseA)
        XCTAssertNotNil(baseB)

        await scheduler.refreshForSystemWake("a")

        XCTAssertEqual(
            scheduler.nextRefreshDate(for: "a"),
            baseA,
            "未到期 provider 的唤醒 full 不得重排它自己的常规时间线"
        )
        XCTAssertEqual(
            scheduler.nextRefreshDate(for: "b"),
            baseB,
            "唤醒刷新不得重排其他 provider 的常规排期"
        )
        XCTAssertEqual(scheduler.backgroundsSinceFullCount(for: "b"), baseCountB)
        XCTAssertEqual(scheduler.backgroundsSinceFullCount(for: "a"), 0, "唤醒 full 结算后 a 的周期计数归零")
        scheduler.cancelAll()
    }

    /// reanchorProvider 只重锚目标 provider：其他 provider 的常规排期与
    /// reset candidates 必须原样保留。
    @MainActor
    func testReanchorProviderTouchesOnlyTargetProvider() async {
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .completed(success: true) },
            intervalProvider: { _ in 120 },
            onNextRefreshChange: {}
        )
        scheduler.schedule(for: "a")
        scheduler.schedule(for: "b")
        // 条件等待：两个 provider 的首拍都结算完（排期落到未来 = settledAt + interval；
        // schedule(for:) 刚写入的 provisional 是 now()，落在过去）即满足。
        let bothSettled = await waitUntil {
            Self.hasSettledRegularDate(scheduler, "a") && Self.hasSettledRegularDate(scheduler, "b")
        }
        XCTAssertTrue(bothSettled, "两个 provider 的首拍应在超时前结算")
        let baseA = scheduler.nextRefreshDate(for: "a")
        let baseB = scheduler.nextRefreshDate(for: "b")
        XCTAssertNotNil(baseA)
        XCTAssertNotNil(baseB)

        // 为 b 造一个 mid-cycle reset 补刷新点；a 保持没有。
        scheduler.scheduleMidCycleResetRefreshes(for: "b", resetsAtDates: [Date()])
        let baseResetB = scheduler.resetCandidateExecutionDates(for: "b")
        XCTAssertFalse(baseResetB.isEmpty, "b 应成功登记 reset candidate")
        XCTAssertTrue(scheduler.resetCandidateExecutionDates(for: "a").isEmpty)

        scheduler.reanchorProvider("b", at: Date(), resetDatesByProvider: [:])

        XCTAssertEqual(
            scheduler.nextRefreshDate(for: "a"),
            baseA,
            "单 provider 重锚不得影响其他 provider 的常规排期"
        )
        XCTAssertTrue(scheduler.resetCandidateExecutionDates(for: "a").isEmpty)
        XCTAssertTrue(
            scheduler.resetCandidateExecutionDates(for: "b").isEmpty,
            "目标 provider 的旧 reset candidates 应被清除（resetDatesByProvider 为空则不重排）"
        )
        XCTAssertNotEqual(scheduler.nextRefreshDate(for: "b"), baseB, "目标 provider 的常规时间线应被重锚")
        XCTAssertGreaterThan(scheduler.nextRefreshDate(for: "b") ?? .distantPast, baseB ?? .distantPast)
        XCTAssertEqual(scheduler.backgroundsSinceFullCount(for: "a"), 0)
        scheduler.cancelAll()
    }

    /// reanchorProvider 清零目标 provider 的周期 full 计数：N=3 期望无重锚时
    /// 第 5 拍进入 periodic full；在第 4 拍结算前重锚则第 5 拍仍是 background。
    @MainActor
    func testReanchorProviderResetsPeriodicFullCount() async {
        let log = ModeLog()
        let holder = WeakSchedulerHolder()
        let sched = ProviderRefreshScheduler(
            refreshHandler: { _, mode in
                let n = await log.record(mode)
                if n == 4 {
                    await holder.sched?.reanchorProvider("p", at: Date(), resetDatesByProvider: [:])
                }
                return .completed(success: true)
            },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {},
            periodicFullEveryN: 3,
            sleep: { _ in try? await Task.sleep(nanoseconds: 1) }
        )
        holder.sched = sched
        sched.schedule(for: "p")
        // 条件等待：与 testSchedulerPeriodicFullEveryNBackgrounds 相同的虚拟时间
        // 节奏（注入 1ns sleep 让 deadline driver 立即续拍），记满 6 拍即可断言。
        let reachedSix = await waitUntil { await log.snapshot().count >= 6 }
        XCTAssertTrue(reachedSix, "应至少在超时前跑满 6 拍")
        sched.cancelAll()

        let seq = await log.snapshot()
        XCTAssertGreaterThanOrEqual(seq.count, 6, "应至少跑满 6 拍，实际 \(seq.count)")
        XCTAssertEqual(
            Array(seq.prefix(5)),
            [.full, .background, .background, .background, .background],
            "第 4 拍结算前重锚应清零周期 full 计数：第 5 拍仍是 background 而不是 full"
        )
    }

    // MARK: - Mid-cycle 补刷新（合并自 RefreshSchedulerMidCycleTests）

    // MARK: - F3: 首次成功刷新必须安排 mid-cycle 补刷新
    /// F3 核心回归：首次刷新时 nextRefreshDates 尚未写入，旧实现的 guard 直接 return，
    /// 导致首次成功的 reset+15s 补刷新被丢弃。新实现用 now+interval 作为 provisional
    /// deadline，并在 reset+delay 后实际触发一次 .background。
    @MainActor
    func testF3FirstRefreshSchedulesMidCycleFillIn() async {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        var invokedModes: [RefreshMode] = []
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, mode in
                invokedModes.append(mode)
                return .completed(success: true)
            },
            intervalProvider: { _ in 300 },
            onNextRefreshChange: {},
            now: { fixedNow },
            midCycleResetDelay: 15,
            sleep: { _ in }  // 立即返回，不等待真实 15 秒
        )
        // 首次刷新场景：nextRefreshDates 为空。provisional deadline = now + 300。
        // resetTime = now + 200，差距 100s > 60s → 应安排补刷新。
        let resetTime = fixedNow.addingTimeInterval(200)
        scheduler.scheduleMidCycleResetRefreshes(for: "first", resetsAtDates: [resetTime])

        // provisional deadline 不得写回 nextRefreshDates（仍由 handler 返回后的正式流程决定）
        XCTAssertNil(scheduler.earliestNextRefresh, "provisional deadline 不得写回 nextRefreshDates")

        // 让 mid-cycle task 跑完（注入的 sleep 立即返回）
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(invokedModes.contains(.background), "首次成功后应实际触发一次 .background 补刷新")

        scheduler.cancelAll()
    }
    /// reset 与常规刷新差距 ≤60 秒时不安排补刷新。
    @MainActor
    func testF3NoMidCycleWhenResetWithinSixtySeconds() async {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        var invokedModes: [RefreshMode] = []
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, mode in
                invokedModes.append(mode)
                return .completed(success: true)
            },
            intervalProvider: { _ in 300 },
            onNextRefreshChange: {},
            now: { fixedNow },
            midCycleResetDelay: 15,
            sleep: { _ in }
        )
        // provisional deadline = now + 300。resetTime = now + 280，差距 20s ≤ 60s → 不安排。
        let resetTime = fixedNow.addingTimeInterval(280)
        scheduler.scheduleMidCycleResetRefreshes(for: "p", resetsAtDates: [resetTime])
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(invokedModes.contains(.background), "差距 ≤60s 时不应安排补刷新")
        scheduler.cancelAll()
    }
    /// Reset 的 prev 侧边界：30 秒以内不丢弃，而是把执行点钳到 prev+30s。
    @MainActor
    func testResetWindowUsesStrictThirtySecondBoundary() async {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

        func run(resetExecutionOffset: TimeInterval) async -> Bool {
            var modes: [RefreshMode] = []
            let scheduler = ProviderRefreshScheduler(
                refreshHandler: { _, mode in
                    modes.append(mode)
                    return .completed(success: true)
                },
                intervalProvider: { _ in 300 },
                onNextRefreshChange: {},
                now: { fixedNow },
                midCycleResetDelay: 0,
                sleep: { _ in }
            )
            scheduler.scheduleMidCycleResetRefreshes(
                for: "p",
                resetsAtDates: [fixedNow.addingTimeInterval(resetExecutionOffset)]
            )
            try? await Task.sleep(nanoseconds: 50_000_000)
            scheduler.cancelAll()
            return modes.contains(.background)
        }

        let belowBoundary = await run(resetExecutionOffset: 29.999)
        let atBoundary = await run(resetExecutionOffset: 30.0)
        let aboveBoundary = await run(resetExecutionOffset: 30.001)
        XCTAssertTrue(belowBoundary)
        XCTAssertTrue(atBoundary)
        XCTAssertTrue(aboveBoundary)
    }
    @MainActor
    func testStaggeredStartPointsSeparateInitialProviderRefreshes() async {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        var order: [String] = []
        var scheduler: ProviderRefreshScheduler!
        scheduler = ProviderRefreshScheduler(
            refreshHandler: { providerID, _ in
                order.append(providerID)
                if order.count == 2 { scheduler.cancelAll() }
                return .completed(success: true)
            },
            intervalProvider: { _ in 300 },
            onNextRefreshChange: {},
            now: { fixedNow },
            sleep: { _ in }
        )
        scheduler.schedule(for: "a")
        scheduler.schedule(for: "b")
        scheduler.staggerInitialRefreshes(at: fixedNow)
        scheduler.start()
        for _ in 0..<100 where order.count < 2 {
            await Task.yield()
        }
        XCTAssertEqual(order, ["a", "b"])
    }
    @MainActor
    func testResetNextIntervalBoundaryUsesStrictLessThan() async {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

        func run(resetExecutionOffset: TimeInterval) async -> Bool {
            var modes: [RefreshMode] = []
            let scheduler = ProviderRefreshScheduler(
                refreshHandler: { _, mode in
                    modes.append(mode)
                    return .completed(success: true)
                },
                intervalProvider: { _ in 300 },
                onNextRefreshChange: {},
                now: { fixedNow },
                midCycleResetDelay: 0,
                sleep: { _ in }
            )
            scheduler.scheduleMidCycleResetRefreshes(
                for: "p",
                resetsAtDates: [fixedNow.addingTimeInterval(resetExecutionOffset)]
            )
            try? await Task.sleep(nanoseconds: 50_000_000)
            scheduler.cancelAll()
            return modes.contains(.background)
        }

        let belowNextBoundary = await run(resetExecutionOffset: 270.001)
        let atNextBoundary = await run(resetExecutionOffset: 270.0)
        let aboveNextBoundary = await run(resetExecutionOffset: 269.999)
        XCTAssertFalse(belowNextBoundary)
        XCTAssertTrue(atNextBoundary)
        XCTAssertTrue(aboveNextBoundary)
    }
    @MainActor
    func testResetIsSkippedWhenProviderIntervalIsAtMostSixtySeconds() async {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        var modes: [RefreshMode] = []
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, mode in
                modes.append(mode)
                return .completed(success: true)
            },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {},
            now: { fixedNow },
            midCycleResetDelay: 0,
            sleep: { _ in }
        )
        scheduler.scheduleMidCycleResetRefreshes(
            for: "p",
            resetsAtDates: [fixedNow.addingTimeInterval(45)]
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(modes.contains(.background))
        scheduler.cancelAll()
    }
    @MainActor
    func testExternalJobBlocksAutomaticBatchUntilItEnds() async {
        var refreshCount = 0
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in
                refreshCount += 1
                return .completed(success: true)
            },
            intervalProvider: { _ in 300 },
            onNextRefreshChange: {}
        )
        scheduler.schedule(for: "p")
        let token = scheduler.beginExternalJob()
        XCTAssertNotNil(token)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(refreshCount, 0)
        XCTAssertNil(scheduler.beginExternalJob())
        if let token { scheduler.endExternalJob(token) }
        for _ in 0..<100 where refreshCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(refreshCount, 1)
        scheduler.cancelAll()
    }
    @MainActor
    func testStaleExternalJobTokenCannotReleaseNewGeneration() {
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .completed(success: true) },
            intervalProvider: { _ in 300 },
            onNextRefreshChange: {}
        )
        guard let staleToken = scheduler.beginExternalJob() else {
            XCTFail("初始 external job 应成功获取 token")
            return
        }
        scheduler.cancelAll()
        guard let currentToken = scheduler.beginExternalJob() else {
            XCTFail("cancelAll 后新 generation 应允许创建 external job")
            return
        }

        scheduler.endExternalJob(staleToken)
        XCTAssertNil(
            scheduler.beginExternalJob(),
            "旧 token 不得释放新 generation 的 job"
        )
        scheduler.endExternalJob(currentToken)
        XCTAssertNotNil(scheduler.beginExternalJob())
        scheduler.cancelAll()
    }
    @MainActor
    func testRegularIntervalStartsAfterBatchReconcileCompletes() async {
        let initialNow = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = SchedulerTestClock(date: initialNow)
        var settled = 0
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .completed(success: true) },
            intervalProvider: { _ in 300 },
            onNextRefreshChange: {},
            onBatchSettledAsync: { _ in
                clock.advance(by: 100)
                settled += 1
            },
            now: { clock.date }
        )
        scheduler.schedule(for: "p")
        scheduler.start()
        for _ in 0..<100 where settled == 0 {
            await Task.yield()
        }

        XCTAssertEqual(
            scheduler.earliestNextRefresh?.timeIntervalSince(clock.date) ?? .nan,
            300,
            accuracy: 0.001,
            "下一次 Interval 必须从 quota + local reconcile 完成时间开始"
        )
        scheduler.cancelAll()
    }
    /// 已过期的 reset time（targetDate ≤ now）不安排补刷新。
    @MainActor
    func testF3NoMidCycleForPastReset() async {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        var invokedModes: [RefreshMode] = []
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, mode in
                invokedModes.append(mode)
                return .completed(success: true)
            },
            intervalProvider: { _ in 300 },
            onNextRefreshChange: {},
            now: { fixedNow },
            sleep: { _ in }
        )
        // resetTime 已在现在之前，targetDate = resetTime + 15 ≤ now → 不安排。
        scheduler.scheduleMidCycleResetRefreshes(
            for: "p", resetsAtDates: [fixedNow.addingTimeInterval(-100)]
        )
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(invokedModes.contains(.background))
        scheduler.cancelAll()
    }
    /// 重复 reset（同一 resetTime 多次出现）只安排一个补刷新；reschedule 取消旧 task。
    @MainActor
    func testF3RescheduleCancelsOldMidCycleTasks() async {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        var backgroundCount = 0
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, mode in
                if mode == .background { backgroundCount += 1 }
                return .completed(success: true)
            },
            intervalProvider: { _ in 300 },
            onNextRefreshChange: {},
            now: { fixedNow },
            midCycleResetDelay: 15,
            sleep: { _ in try await Task.sleep(nanoseconds: 100_000_000) }  // 短延迟，让 reschedule 有机会 cancel
        )
        let resetTime = fixedNow.addingTimeInterval(200)
        // 第一次安排
        scheduler.scheduleMidCycleResetRefreshes(for: "p", resetsAtDates: [resetTime])
        // 立即重新安排（同一 resetTime），应取消第一个 task 并重建
        scheduler.scheduleMidCycleResetRefreshes(for: "p", resetsAtDates: [resetTime])
        try? await Task.sleep(nanoseconds: 400_000_000)
        // 即便两次都触发，sleep 100ms + cancel 语义下至多一次成功 .background；这里只断言
        // 没有重复风暴（远小于多次），且至少能完成 reschedule 不崩溃。
        XCTAssertLessThanOrEqual(backgroundCount, 1, "reschedule 应取消旧 mid-cycle task")
        scheduler.cancelAll()
    }
    /// cancel 立即取消已安排的 mid-cycle task，不触发 .background。
    @MainActor
    func testF3CancelStopsMidCycleTask() async {
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        var invokedModes: [RefreshMode] = []
        // sleep 跑满 300ms 后翻标志：cancel 会取消 sleepTask，这里用 `try?` 吞掉
        // 取消错误，保证"这一次 sleep 走到了尽头"始终可观测（原 600ms 固定等待的锚点）。
        let sleepFinished = AsyncFlag()
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, mode in
                invokedModes.append(mode)
                return .completed(success: true)
            },
            intervalProvider: { _ in 300 },
            onNextRefreshChange: {},
            now: { fixedNow },
            sleep: { _ in
                try? await Task.sleep(nanoseconds: 300_000_000)
                await sleepFinished.set()
            }
        )
        scheduler.scheduleMidCycleResetRefreshes(
            for: "p", resetsAtDates: [fixedNow.addingTimeInterval(200)]
        )
        scheduler.cancel(providerID: "p")  // 在 sleep 完成前取消
        // 条件等待：注入的 sleep 一旦走完就立刻断言，不必再睡满 600ms。
        let slept = await waitUntil { await sleepFinished.isSet }
        XCTAssertTrue(slept, "注入的 sleep 应在超时前走完（否则下面的否定断言不成立）")
        XCTAssertFalse(invokedModes.contains(.background), "cancel 后 mid-cycle task 不应触发")
    }
    @MainActor
    func testSchedulerPeriodicFullEveryNBackgrounds() async {
        // R3/C: scheduler 每 N 次 background 补一次 .full，让 reset credits 等只在
        // full 抓取的字段也能周期性更新。N=3 期望 mode 序列：
        // full(首次), bg, bg, bg, full, bg, bg, bg, full ...
        // 用 actor 记录 mode + 弱引用 holder 在记满 9 个后自行 cancelAll，确定性收尾。
        let log = ModeLog()
        let holder = WeakSchedulerHolder()
        let sched = ProviderRefreshScheduler(
            refreshHandler: { _, mode in
                let n = await log.record(mode)
                if n >= 9 { holder.sched?.cancelAll() }
                return .completed(success: true)
            },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {},
            periodicFullEveryN: 3,
            sleep: { _ in try? await Task.sleep(nanoseconds: 1) }
        )
        holder.sched = sched
        sched.schedule(for: "p")
        // 条件等待：mode log 记满 9 轮即满足（正常 <10ms）；timeout 只作安全网。
        let reachedNine = await waitUntil { await log.snapshot().count >= 9 }
        XCTAssertTrue(reachedNine, "9 轮周期 full 应在超时前跑完")
        sched.cancelAll()

        let seq = await log.snapshot()
        XCTAssertEqual(seq.count, 9, "应正好跑 9 轮后自行 cancel，实际 \(seq.count)")
        let expected: [RefreshMode] = [.full, .background, .background, .background,
                                       .full, .background, .background, .background, .full]
        XCTAssertEqual(seq, expected, "mode 序列应为 full,bg,bg,bg,full,bg,bg,bg,full")
        XCTAssertEqual(seq.filter { $0 == .full }.count, 3)
    }
    @MainActor
    func testSchedulerEarliestNextRefreshPicksMin() async {
        // 用一个会立刻成功的 refreshHandler 跑满一个 cycle：成功后 nextRefreshDates
        // 会被 set 成 Date()+60s（+jitter）。跑两个 provider，验证 min 选小的。
        let sched = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .completed(success: true) },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {}
        )
        sched.schedule(for: "a")
        sched.schedule(for: "b")
        // 等两个 task 都跑过第一个 cycle（每次 .completed → 60s sleep 之前会设 nextRefreshDates）
        try? await Task.sleep(nanoseconds: 300_000_000)  // 0.3s
        let earliest = sched.earliestNextRefresh
        XCTAssertNotNil(earliest, "earliestNextRefresh 应在两个 provider 都跑过一个 cycle 后有值")
        // 验证：取消 a 后 earliest 仍是 b 的
        sched.cancel(providerID: "a")
        XCTAssertNotNil(sched.earliestNextRefresh, "取消一个 provider 后另一个仍有 nextRefreshDates")
        sched.cancelAll()
    }
    @MainActor
    func testSchedulerDeferredOutcomeUsesNormalIntervalWithoutStorm() async {
        // refreshHandler 一直返回 .deferred → 不得进入 1s 重试风暴，按正常 Interval 排期。
        let counter = CallCounter()
        let sched = ProviderRefreshScheduler(
            refreshHandler: { _, mode in
                await counter.tickCalled(mode: mode)
                return .deferred
            },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {}
        )
        sched.schedule(for: "a")
        // 等 ~1.2s：只应完成首次请求，下一次应在 60s 后。
        // 这条必须是真时钟 —— 它验证的正是"1s 内不会重试风暴"，条件等待会把它掏空。
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        sched.cancel(providerID: "a")
        // 验证：没有每秒重复调用。
        let calls = await counter.calls
        XCTAssertEqual(calls, 1, "deferred 不应触发 1s 重试风暴")
    }
    @MainActor
    func testSchedulerDifferentProvidersIndependent() async {
        // A 持续失败、B 成功：失败没有独立退避状态，两者的下次排期都仍是
        // baseInterval，互不影响。
        var results: [String: Bool] = [:]
        let sched = ProviderRefreshScheduler(
            refreshHandler: { providerID, _ in
                let success = providerID != "fail_provider"
                results[providerID] = success
                return .completed(success: success)
            },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {}
        )
        sched.schedule(for: "fail_provider")
        sched.schedule(for: "success_provider")
        // 等第一批 batch 结算（两个 provider 各完成一次刷新）
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(results["fail_provider"], false, "A 应该失败")
        XCTAssertEqual(results["success_provider"], true, "B 应该成功")

        // 取消 B 后 earliest 就是失败 provider 的排期：仍按 baseInterval 排（不退避）；
        // B 存在时 earliest 一直覆盖成功 provider 的同节奏排期（min ≈ now + 60）。
        let baseline = Date()
        sched.cancel(providerID: "success_provider")
        let failNext = sched.earliestNextRefresh
        sched.cancel(providerID: "fail_provider")
        XCTAssertNil(sched.earliestNextRefresh, "两个 provider 都取消后不应再有排期")

        guard let failNext else {
            XCTFail("失败 provider 也必须有下一次刷新排期")
            return
        }
        let failOffset = failNext.timeIntervalSince(baseline)
        XCTAssertGreaterThanOrEqual(failOffset, 55, "失败 provider 仍按 baseInterval(60s) 排下次刷新，不退避")
        XCTAssertLessThanOrEqual(failOffset, 65, "失败 provider 的下次刷新不应晚于 baseInterval")
    }
    @MainActor
    func testSchedulerOnNextRefreshChangeCallbackFires() {
        var fired = 0
        let sched = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .deferred },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: { fired += 1 }
        )
        // 手动灌数据后 cancel/cancelAll 应触发 callback
        sched.markInFlight("a")
        // 直接 cancel：cancel 一定会触发 onChange（因为 nextRefreshDates.remove）。
        sched.cancel(providerID: "a")
        XCTAssertEqual(fired, 1, "cancel 应触发一次 onNextRefreshChange")
        sched.cancelAll()
        XCTAssertEqual(fired, 2, "cancelAll 应再触发一次 onNextRefreshChange")
    }

    // MARK: - 刷新余额回归（合并自 RefreshBalanceRegressionTests）

    private actor SleepProbe {
        private var durations: [TimeInterval] = []

        func record(_ duration: TimeInterval) {
            durations.append(duration)
        }

        func allDurations() -> [TimeInterval] {
            durations
        }
    }

    /// The scheduler invokes the refresh handler before processOutcome records
    /// the regular next date.  That real path must still schedule reset+15s,
    /// rather than comparing the reset against the just-fired date.
    @MainActor
    func testRegularRefreshSchedulesMidCycleAtResetPlusDelay() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sleepProbe = SleepProbe()
        var modes: [RefreshMode] = []
        var scheduler: ProviderRefreshScheduler?

        scheduler = ProviderRefreshScheduler(
            refreshHandler: { providerID, mode in
                modes.append(mode)
                if mode == .full {
                    scheduler?.scheduleMidCycleResetRefreshes(
                        for: providerID,
                        resetsAtDates: [now.addingTimeInterval(120)]
                    )
                } else if mode == .background {
                    scheduler?.cancelAll()
                }
                return .completed(success: true)
            },
            intervalProvider: { _ in 300 },
            now: { now },
            midCycleResetDelay: 15,
            sleep: { seconds in
                await sleepProbe.record(seconds)
                if seconds >= 200 {
                    // Keep the regular cycle asleep while the mid-cycle task
                    // wakes immediately in this deterministic test.
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        )

        scheduler?.schedule(for: "glm")
        for _ in 0..<100 where !modes.contains(.background) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertEqual(modes, [.full, .background])
        let durations = await sleepProbe.allDurations()
        XCTAssertTrue(
            durations.contains { abs($0 - 135) < 0.001 },
            "expected reset+15s sleep; got \(durations)"
        )
        scheduler?.cancelAll()
    }

    /// A manual reschedule with a still-future regular deadline must retain
    /// that deadline when deciding whether a reset deserves a fill-in refresh.
    @MainActor
    func testManualMidCycleScheduleKeepsFutureRegularDeadline() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = OSAllocatedUnfairLock(initialState: now)
        let sleepProbe = SleepProbe()
        var scheduler: ProviderRefreshScheduler?
        scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .completed(success: true) },
            intervalProvider: { _ in 300 },
            now: { clock.withLock { $0 } },
            sleep: { seconds in
                await sleepProbe.record(seconds)
                if seconds >= 200 {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        )
        defer { scheduler?.cancelAll() }

        scheduler?.schedule(for: "glm")
        for _ in 0..<100 {
            if let next = scheduler?.earliestNextRefresh, next > now {
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(scheduler?.earliestNextRefresh, now.addingTimeInterval(300))
        // 半个周期后手动刷新。reset距原截止仅30s，不该因为重新从now算300s
        // 而误补刷新：原截止仍是base+300，不是base+450。
        clock.withLock { $0 = now.addingTimeInterval(150) }
        scheduler?.scheduleMidCycleResetRefreshes(
            for: "glm", resetsAtDates: [now.addingTimeInterval(270)]
        )
        try? await Task.sleep(nanoseconds: 30_000_000)

        let durations = await sleepProbe.allDurations()
        XCTAssertFalse(durations.contains { abs($0 - 135) < 0.001 }, "got \(durations)")
    }

    // MARK: - 配置重载的差异化重排（reconfigure）

    /// 跨闭包共享的可变状态（虚拟时钟 / interval / 已发生的刷新模式 / publish 次数）。
    private final class ConfigReloadProbeState: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        var intervals: [String: TimeInterval] = [:]
        var modes: [String: [RefreshMode]] = [:]
        var nextRefreshChanges = 0
    }

    /// 冻结虚拟时钟 + 睡到天荒地老。
    ///
    /// 两个注入缺一不可：`now` 冻结让排期完全由注入值决定（可以逐字断言
    /// deadline）；`sleep` 睡满一整轮让 driver 停在"没有 deadline 到期"的状态——
    /// 如果 sleep 立即返回，driver 会把 `lastCompletedTargetWakeDate` 一路推到下一个
    /// 截止时刻并连拍，测到的就不是"配置重载有没有让未变 provider 重抓"。
    @MainActor
    private func makeConfigReloadScheduler(
        _ box: ConfigReloadProbeState
    ) -> ProviderRefreshScheduler {
        ProviderRefreshScheduler(
            refreshHandler: { id, mode in
                box.modes[id, default: []].append(mode)
                return .completed(success: true)
            },
            intervalProvider: { id in box.intervals[id] ?? 300 },
            onNextRefreshChange: { box.nextRefreshChanges += 1 },
            now: { box.now },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
    }

    /// 启动并跑到"首拍已结算"：此后 deadline = `now + interval` 且不再变动。
    @MainActor
    private func startAndSettle(
        _ scheduler: ProviderRefreshScheduler,
        _ box: ConfigReloadProbeState,
        providerIDs: [String]
    ) async {
        for id in providerIDs { scheduler.schedule(for: id) }
        scheduler.staggerInitialRefreshes(at: box.now)
        // 启动错峰会把第 i 个 provider 推后 i×2s，而虚拟时钟不会自己走：必须手动
        // 推过最大错峰，否则 index≥1 的 provider 永远等不到第一拍，"配置重载不该
        // 让它退回 .full" 这条断言就没有可比的基线。
        box.now = box.now.addingTimeInterval(TimeInterval(providerIDs.count * 2) + 1)
        scheduler.start()
        // 等"首拍已结算"而不是"handler 已被调用"：handler 在 settleRegularIntervals
        // 之前就被记录，只等 handler 会读到还没结算的 deadline。
        await waitUntilReached {
            providerIDs.allSatisfy { (scheduler.nextRefreshDate(for: $0) ?? .distantPast) > box.now }
        }
    }

    @MainActor
    private func waitUntilReached(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        for _ in 0..<50 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// **配置写盘不等于冷启动**：未变 provider 的 `nextRefreshDates` 不能被重置
    /// 为 now，也不能因此立刻重抓一次。
    @MainActor
    func testReconfigureKeepsUnchangedProviderDeadlineAndSkipsImmediateRefetch() async {
        let box = ConfigReloadProbeState()
        box.intervals = ["a": 300]
        let scheduler = makeConfigReloadScheduler(box)
        await startAndSettle(scheduler, box, providerIDs: ["a"])
        let settledDeadline = scheduler.nextRefreshDate(for: "a")
        XCTAssertEqual(settledDeadline, box.now.addingTimeInterval(300), "首拍结算后应落在 now + 300s")
        let callsBefore = box.modes["a"]?.count ?? 0

        // 配置重载：只有 b 是新增，a 未变。
        box.intervals["b"] = 300
        let changed = scheduler.reconfigure(managed: ["a", "b"])
        // 先逐字断言（同步段内 driver 改不到排期），再等新增 provider 的第一拍。
        XCTAssertEqual(scheduler.nextRefreshDate(for: "b"), box.now, "新增 provider 走初始排期（now）")
        await waitUntilReached { box.modes["b"] != nil }

        XCTAssertTrue(changed, "新增 provider 必须算作排期变化")
        XCTAssertEqual(
            scheduler.nextRefreshDate(for: "a"),
            settledDeadline,
            "配置变更后未变 provider 的 nextRefreshDates 不得被重置"
        )
        XCTAssertEqual(
            box.modes["a"]?.count, callsBefore,
            "配置变更不得让未变 provider 立即重抓"
        )
        XCTAssertEqual(box.modes["b"], [.full], "新增 provider 的第一拍走 .full")
        scheduler.cancelAll()
    }

    /// 间隔**变化**的 provider 按新间隔重锚，未变的保持原 deadline。
    @MainActor
    func testReconfigureReanchorsOnlyProvidersWhoseIntervalChanged() async {
        let box = ConfigReloadProbeState()
        box.intervals = ["a": 300, "b": 300]
        let scheduler = makeConfigReloadScheduler(box)
        await startAndSettle(scheduler, box, providerIDs: ["a", "b"])
        let deadlineA = scheduler.nextRefreshDate(for: "a")
        let deadlineB = scheduler.nextRefreshDate(for: "b")
        let callsBefore = box.modes["a"]?.count ?? 0

        // 只把 b 的间隔从 300 改成 600。
        box.intervals["b"] = 600
        scheduler.reconfigure(managed: ["a", "b"])
        XCTAssertEqual(scheduler.nextRefreshDate(for: "b"), box.now, "间隔变化的 provider 被重锚到 now")
        await waitUntilReached { (scheduler.nextRefreshDate(for: "b") ?? .distantPast) > box.now }

        XCTAssertEqual(scheduler.nextRefreshDate(for: "a"), deadlineA, "间隔未变的 provider 保持既有 deadline")
        XCTAssertEqual(box.modes["a"]?.count, callsBefore, "间隔未变的 provider 不因配置重载立即重抓")
        XCTAssertEqual(scheduler.nextRefreshDate(for: "b"), box.now.addingTimeInterval(600),
                       "间隔变化的 provider 按新间隔重锚")
        XCTAssertNotEqual(deadlineB, scheduler.nextRefreshDate(for: "b"))
        XCTAssertEqual(box.modes["b"], [.full, .background],
                       "间隔变化的 provider 重锚后那一拍沿用已完成首刷（.background）")
        scheduler.cancelAll()
    }

    /// 停用的 provider 走与 `cancel(providerID:)` 相同的清理，其余不动。
    @MainActor
    func testReconfigureDropsProvidersNoLongerEnabled() async {
        let box = ConfigReloadProbeState()
        box.intervals = ["a": 300, "b": 300]
        let scheduler = makeConfigReloadScheduler(box)
        await startAndSettle(scheduler, box, providerIDs: ["a", "b"])
        let deadlineA = scheduler.nextRefreshDate(for: "a")

        scheduler.reconfigure(managed: ["a"])
        XCTAssertNil(scheduler.nextRefreshDate(for: "b"), "停用的 provider 应退出额度循环")
        XCTAssertEqual(scheduler.nextRefreshDate(for: "a"), deadlineA, "留下的 provider 不应被动到")
        scheduler.cancelAll()
    }

    /// 重锚后的首拍必须沿用"已完成首次刷新"的状态走 `.background`——旧实现
    /// （cancelAll + 逐个 schedule）会清掉 `hasDoneFirstRefresh`，让配置改动后的
    /// 重抓一律退化成更贵的 `.full`。
    @MainActor
    func testReanchorAfterIntervalChangeKeepsFirstRefreshState() async {
        let box = ConfigReloadProbeState()
        box.intervals = ["a": 300]
        let scheduler = makeConfigReloadScheduler(box)
        await startAndSettle(scheduler, box, providerIDs: ["a"])
        XCTAssertEqual(box.modes["a"], [.full], "启动第一拍是 .full")

        box.intervals["a"] = 600
        scheduler.reconfigure(managed: ["a"])
        await waitUntilReached { (box.modes["a"]?.count ?? 0) > 1 }

        XCTAssertEqual(
            box.modes["a"], [.full, .background],
            "重锚后的首拍必须沿用已完成的首次刷新状态（.background），不能退回 .full"
        )
        scheduler.cancelAll()
    }

    /// 什么都没有变时不应唤醒 driver（返回 false 且不重复 publish nextRefreshAt）。
    @MainActor
    func testReconfigureWithNoDeltaReportsNoChange() async {
        let box = ConfigReloadProbeState()
        box.intervals = ["a": 300]
        let scheduler = makeConfigReloadScheduler(box)
        await startAndSettle(scheduler, box, providerIDs: ["a"])
        let deadline = scheduler.nextRefreshDate(for: "a")
        let changesBefore = box.nextRefreshChanges

        let changed = scheduler.reconfigure(managed: ["a"])
        XCTAssertFalse(changed, "受管集合与间隔都没变时不算变化")
        XCTAssertEqual(scheduler.nextRefreshDate(for: "a"), deadline)
        XCTAssertEqual(box.nextRefreshChanges, changesBefore, "无变化时不应再 publish 一次 nextRefreshAt")
        scheduler.cancelAll()
    }
}
