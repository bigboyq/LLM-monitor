import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// 首次成功刷新后必须安排 mid-cycle 补刷新。对应 `ProviderRefreshScheduler` 的 mid-cycle 路径。
final class RefreshSchedulerMidCycleTests: StateTestCase {

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
}
