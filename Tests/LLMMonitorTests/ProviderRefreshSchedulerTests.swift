import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// 刷新排期 / dedup / 取消，以及 `waitUntilNotInFlight` 的 cancel-after-resume 竞态。对应 `ProviderRefreshScheduler`。
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
}
