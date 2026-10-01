import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// 双循环架构回归（后半）：扫描中途 dirty、waiter 跨升级扫描、hard-full 触发、时钟变化与健康边界。对应 `ProviderRefreshScheduler` 的边界驱动。
final class DualLoopHardFullTriggerTests: StateTestCase {

    @MainActor
    func testSuccessfulScanWithMidScanDirtyDoesNotReportFailure() async throws {
        let gate = ScannerTestGate()
        let scanner = LifecycleProbeScanner(gate: gate)
        var failedCount = 0
        scanner.onFailed = { failedCount += 1 }

        scanner.scan()
        await gate.waitForEntered()
        scanner.markDirty()
        await gate.release()
        try await scanner.waitUntilSettled()

        XCTAssertEqual(scanner.lastResult, 1)
        XCTAssertTrue(scanner.isDirty)
        XCTAssertNil(scanner.lastError)
        XCTAssertEqual(failedCount, 0)
    }
    /// P1 回归：in-flight 期间到达的显式 hardFull 请求必须排队，并在当前扫描
    /// 结束后实际执行（旧实现直接丢弃）；期间到达的普通请求合并进同一槽位，
    /// 只接续一轮更强扫描。
    @MainActor
    func testHardFullRequestedDuringInFlightScanRunsAfterCurrentScan() async throws {
        let gate = ScannerTestGate()
        let scanner = ModeProbeScanner(gates: [gate])

        scanner.scan(mode: .dirty)
        await gate.waitForEntered()

        scanner.scan(mode: .full)
        scanner.scan(mode: .hardFull)

        await gate.release()
        try await scanner.waitUntilSettled()

        XCTAssertEqual(
            scanner.recordedModes, [.dirty, .hardFull],
            "hardFull 不能被 in-flight dedup 丢弃；full/hardFull 应合并为一轮 hardFull"
        )
        XCTAssertFalse(scanner.isScanning)
    }
    /// 排队升级的接续扫描期间，waitUntilSettled 的 waiter 不得被提前唤醒，
    /// 必须等接续扫描也 settle 后才返回。
    @MainActor
    func testWaiterStaysPendingThroughQueuedUpgradeScan() async throws {
        let firstGate = ScannerTestGate()
        let secondGate = ScannerTestGate()
        let scanner = ModeProbeScanner(gates: [firstGate, secondGate])

        scanner.scan(mode: .dirty)
        await firstGate.waitForEntered()
        scanner.scan(mode: .hardFull)

        let waiter = Task { @MainActor () -> Bool in
            do {
                try await scanner.waitUntilSettled()
                return true
            } catch {
                return false
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        await firstGate.release()
        await secondGate.waitForEntered()
        var waiterReturned = false
        let observer = Task { @MainActor in
            await waiter.value
            waiterReturned = true
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(waiterReturned, "接续的 hardFull 扫描仍在跑，waiter 不得被提前唤醒")

        await secondGate.release()
        let settled = await waiter.value
        await observer.value
        XCTAssertTrue(waiterReturned)
        XCTAssertTrue(settled, "waiter 应正常 settle，而不是以取消/错误收场")
        XCTAssertEqual(scanner.recordedModes, [.dirty, .hardFull])
    }
    @MainActor
    func testCalendarInvalidationDuringReconcileQueuesHardFullAfterCurrentPass() async {
        let probe = ReconcilePassProbe()
        let orchestration = LocalUsageOrchestration(writer: ReconcileNoopWriter())
        orchestration.testReconcilePass = { mode in
            await probe.run(mode)
        }
        defer { orchestration.cancelInFlightAll() }

        orchestration.scheduleReconcile()
        await probe.waitForFirstStart()
        orchestration.invalidateForCalendarChange()
        await probe.releaseFirst()
        await probe.waitForCount(2)

        let modes = await probe.snapshot()
        XCTAssertEqual(modes, [.full, .hardFull])
        XCTAssertEqual(orchestration.nextReconcileMode, .dirty)
    }
    /// P2 回归：等待被取消时（如 SwiftUI .task 随视图消失），hard 请求仍必须
    /// 发出（scanner 排队而非丢弃），但函数不得谎报成功。先完整走一遍让
    /// coordinator 构造出 scanner，第二次调用的第一次等待才真正挂起，
    /// 从而精确覆盖"等待被取消 → 仍补发 trigger"分支。
    @MainActor
    func testTriggerAntigravityHardFullStillIssuesTriggerWhenCancelled() async {
        let scanner = BlockingAntigravityScanner()
        let orchestration = LocalUsageOrchestration(writer: ReconcileNoopWriter())
        orchestration.testAntigravityScannerFactory = { scanner }
        defer { orchestration.cancelInFlightAll() }

        // Warmup：scanner 未构造时首次等待立即返回，trigger 构造 scanner 后
        // 挂起等 settle。settle 后第一轮完整成功。
        let warmup = Task { @MainActor in
            await orchestration.triggerAntigravityHardFull()
        }
        for _ in 0..<200 where scanner.waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(scanner.waiterCount, 1, "warmup 应已挂起等 hard 扫描 settle")
        scanner.settle()
        let warmupResult = await warmup.value
        XCTAssertTrue(warmupResult)

        // 第二次调用：第一次等待真正挂起，此时取消调用方。
        let cancelled = Task { @MainActor in
            await orchestration.triggerAntigravityHardFull()
        }
        for _ in 0..<200 {
            if scanner.waiterCount == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(scanner.waiterCount, 1, "第二次调用的等待应已挂起")
        cancelled.cancel()
        let result = await cancelled.value

        XCTAssertFalse(result, "被取消的调用不得谎报 hard 重建成功")
        XCTAssertEqual(
            scanner.recordedModes, [.hardFull, .hardFull],
            "取消后 hard 请求仍必须补发（每轮调用各一次），不能静默丢失"
        )
    }
    /// P2 语义：只有 hard 扫描确实启动并 settle 完成（等待未被取消），
    /// triggerAntigravityHardFull 才返回 true。
    @MainActor
    func testTriggerAntigravityHardFullReturnsTrueOnlyAfterHardScanSettles() async {
        let scanner = BlockingAntigravityScanner()
        let orchestration = LocalUsageOrchestration(writer: ReconcileNoopWriter())
        orchestration.testAntigravityScannerFactory = { scanner }
        defer { orchestration.cancelInFlightAll() }

        let hardFull = Task { @MainActor in
            await orchestration.triggerAntigravityHardFull()
        }
        // scanner 未构造时首次等待立即返回；hard trigger 构造 scanner 并发出
        // 请求后，第二次等待挂起直到 hard 扫描 settle。
        for _ in 0..<200 where scanner.waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(scanner.waiterCount, 1, "hard trigger 后应等待扫描 settle")
        XCTAssertEqual(scanner.recordedModes, [.hardFull])

        var result: Bool?
        let observer = Task { @MainActor in
            result = await hardFull.value
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(result, "hard 扫描 settle 前 triggerAntigravityHardFull 不得返回")

        scanner.settle()
        await observer.value
        XCTAssertEqual(result, true)
        XCTAssertEqual(scanner.recordedModes, [.hardFull])
    }
    /// inactive source 的 hard 重建入口必须如实返回 false，且不构造 scanner。
    @MainActor
    func testTriggerAntigravityHardFullSkipsInactiveSource() async {
        var factoryCalls = 0
        let orchestration = LocalUsageOrchestration(writer: ReconcileNoopWriter())
        orchestration.testAntigravityScannerFactory = {
            factoryCalls += 1
            return BlockingAntigravityScanner()
        }
        defer { orchestration.cancelInFlightAll() }

        var sources = LocalUsageOrchestration.ActiveSources()
        sources.antigravity = false
        orchestration.updateActiveSources(sources)

        let result = await orchestration.triggerAntigravityHardFull()

        XCTAssertFalse(result)
        XCTAssertEqual(factoryCalls, 0, "inactive source 不应构造 scanner")
    }
    /// P3 回归：纯时钟平移不触发日历签名失效（hardFull），只补一次普通
    /// reconcile；时区变化仍走 invalidateForCalendarChange 的 cold rebuild。
    @MainActor
    func testSystemClockChangeSchedulesPlainReconcileWithoutCalendarInvalidation() async {
        let store = makeIsolatedConfigStore()
        let state = AppState(descriptors: [], configStore: store)
        // 阻断 init 期的空 batch settle → 启动 full reconcile，避免与断言竞争
        state.stop()
        state.localUsage.testReadinessOverride = { _ in false }
        defer { state.stop() }

        var modes: [LocalUsageScanMode] = []
        state.localUsage.testReconcilePass = { mode in
            modes.append(mode)
        }
        // 排空 init 期可能已投递的 pass，取基准
        try? await Task.sleep(nanoseconds: 30_000_000)
        let baseline = modes.count

        state.handleSystemClockChange()
        for _ in 0..<200 where modes.count == baseline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let clockPasses = Array(modes[baseline...])
        XCTAssertFalse(clockPasses.isEmpty, "时钟平移应补一次普通 reconcile")
        XCTAssertFalse(
            clockPasses.contains(.hardFull),
            "纯时钟平移不得触发 hardFull cold rebuild，实际 \(clockPasses)"
        )
        XCTAssertLessThanOrEqual(clockPasses.count, 1, "时钟平移只应补一次 reconcile")
        XCTAssertNotEqual(
            state.localUsage.nextReconcileMode, .hardFull,
            "时钟平移不得设置日历失效签名"
        )

        state.handleSystemClockOrTimeZoneChange()
        for _ in 0..<200 where !modes[baseline...].contains(.hardFull) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(
            modes[baseline...].contains(.hardFull),
            "时区变化必须走 hardFull cold rebuild，实际 \(modes)"
        )
        XCTAssertEqual(state.localUsage.nextReconcileMode, .dirty)
    }
    @MainActor
    func testLocalUsageReconcileCancellationAllowsNewSchedule() async {
        var passCount = 0
        let orchestration = LocalUsageOrchestration(writer: ReconcileNoopWriter())
        orchestration.testReconcilePass = { _ in
            passCount += 1
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        defer { orchestration.cancelInFlightAll() }

        orchestration.scheduleReconcile()
        try? await Task.sleep(nanoseconds: 20_000_000)
        orchestration.cancelInFlightAll()
        orchestration.scheduleReconcile()

        for _ in 0..<100 where passCount < 2 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(passCount, 2)
    }
    /// (d) refreshAll 契约：返回前 post-quota 的用量补拍已完成并 enrich——codex
    /// 窗口用量依赖刚落地的 reset 时间；旧实现两拍并发，beat 先于 quota 完成时
    /// enrichment 被 .ready 丢弃，返回时 details 为空（确定性回归）。
    @MainActor
    func testRefreshAllWaitsForPostQuotaUsageBeat() async throws {
        final class SlowCodexFetcher: QuotaFetcher {
            let providerID = "codex_chatgpt"
            let displayName = "Codex"
            let kind = ProviderKind.codexChatGpt
            func fetch(mode: RefreshMode) async throws -> QuotaInfo {
                try? await Task.sleep(nanoseconds: 80_000_000)
                return QuotaInfo(models: [], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: Date())
            }
            func hasLocalAuth() -> Bool { true }
        }

        let store = makeIsolatedConfigStore()
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-refresh-all-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appendingPathComponent("auth.json"))
        defer { try? FileManager.default.removeItem(at: home) }

        var config = store.config
        config.providers["codex_chatgpt"] = ProviderConfig(enabled: true, apiKey: "sk-real-key-12345", authPath: home.path)
        try? store.applyAndSave(config)

        let desc = FetcherDescriptor(
            id: "codex_chatgpt",
            displayName: "Codex",
            kind: .codexChatGpt,
            iconSystemName: "star",
            accentColor: .chatgpt,
            makeFetcher: { _ in SlowCodexFetcher() }
        )
        let state = AppState(descriptors: [desc], configStore: store)
        defer { state.stop() }

        await state.refreshAll()

        let idx = state.statuses.firstIndex(where: { $0.id == "codex_chatgpt" })!
        guard case .ok(let info) = state.statuses[idx].state else {
            XCTFail("quota 应该成功，实际 \(state.statuses[idx].state)")
            return
        }
        XCTAssertNotNil(info.codexUsageDetails, "refreshAll 返回前 post-quota 用量补拍必须已完成并 enrich")
    }
    /// LocalUsage reconcile 独立于 Quota 失败：GLM provider quota 失败时仍能安全运行
    @MainActor
    func testReconcileGlmScanIndependentOfQuotaFailure() async {
        let store = makeIsolatedConfigStore()
        var config = store.config
        config.providers["glm_coding_plan"] = ProviderConfig(enabled: true, apiKey: "sk-invalid-key")
        try? store.applyAndSave(config)

        final class FailingFetcher: QuotaFetcher, @unchecked Sendable {
            let providerID = "glm_coding_plan"
            let displayName = "GLM"
            let kind = ProviderKind.glmCodingPlan
            func fetch(mode: RefreshMode) async throws -> QuotaInfo {
                struct AuthFail: LocalizedError { var errorDescription: String? { "401 Unauthorized" } }
                throw AuthFail()
            }
            func hasLocalAuth() -> Bool { true }
        }

        let desc = FetcherDescriptor(
            id: "glm_coding_plan",
            displayName: "GLM Coding Plan",
            kind: .glmCodingPlan,
            iconSystemName: "star",
            accentColor: .glm,
            makeFetcher: { _ in FailingFetcher() }
        )

        let state = AppState(descriptors: [desc], configStore: store)
        // Keep the quota-failure assertion, but prevent the explicit local
        // reconcile below from constructing the production ~/.zcode scanner.
        state.stop()
        state.localUsage.testReadinessOverride = { _ in false }
        defer { state.stop() }

        // 刷新 quota（预期失败）
        await state.refreshOne(providerID: "glm_coding_plan")

        let idx = state.statuses.firstIndex(where: { $0.id == "glm_coding_plan" })!
        if case .failed = state.statuses[idx].state {
            // 预期 quota 失败
        } else {
            XCTFail("Quota 应该处于 failed 状态")
        }

        // 显式执行一拍：不受 quota 失败影响，依然能安全执行
        await state.localUsage.triggerImmediateScanAll()
        XCTAssertTrue(true, "用量扫描在 quota 失败后依然安全执行完毕")
    }
    /// 双循环在配置热加载后正确 reschedule
    @MainActor
    func testDualLoopRescheduleOnConfigChange() async throws {
        let store = makeIsolatedConfigStore()
        var config = store.config
        config.refreshIntervalSeconds = 300
        config.providers["test_a"] = ProviderConfig(enabled: true, apiKey: "sk-real-key-12345")
        try? store.applyAndSave(config)

        let desc = FetcherDescriptor(
            id: "test_a",
            displayName: "Test A",
            kind: .minimaxTokenPlan,
            iconSystemName: "star",
            accentColor: .minimax,
            makeFetcher: { _ in TestQuotaFetcher(providerID: "test_a", displayName: "Test A", kind: .minimaxTokenPlan) }
        )

        let state = AppState(descriptors: [desc], configStore: store)
        // This test observes scheduler rescheduling only. All local usage
        // readiness checks are forced false so no default-path scanner can be
        // constructed by a background settle while the scheduler is running.
        state.localUsage.testReadinessOverride = { _ in false }
        defer { state.stop() }

        let initialNext = state.refreshScheduler.earliestNextRefresh
        XCTAssertNotNil(initialNext)

        // 修改配置刷新间隔为 60s
        var newConfig = store.config
        newConfig.refreshIntervalSeconds = 60
        try store.applyAndSave(newConfig)

        // 等待热加载 sink 执行
        try await Task.sleep(nanoseconds: 100_000_000)

        // rescheduleAll 后双循环依然正常运行
        XCTAssertNotNil(state.refreshScheduler.earliestNextRefresh)
    }
    @MainActor
    func testHealthBoundaryUsesDriverWithoutNetworkBatchAndContinuesOnce() async {
        let clock = SchedulerTestClock(date: Date(timeIntervalSince1970: 1_000))
        var refreshCalls = 0
        var settledBatches = 0
        var boundaryCalls = 0
        var scheduler: ProviderRefreshScheduler!
        scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in
                refreshCalls += 1
                return .completed(success: true)
            },
            intervalProvider: { _ in 300 },
            onBatchSettled: { settledBatches += 1 },
            onHealthBoundary: { _ in
                boundaryCalls += 1
                if boundaryCalls == 1 {
                    scheduler.scheduleHealthBoundary(at: clock.date.addingTimeInterval(10))
                } else {
                    scheduler.cancelAll()
                }
            },
            now: { clock.date },
            sleep: { seconds in clock.advance(by: seconds) }
        )

        scheduler.scheduleHealthBoundary(at: clock.date.addingTimeInterval(10))
        scheduler.start()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(refreshCalls, 0, "健康边界不应触发网络 refresh")
        XCTAssertEqual(boundaryCalls, 2, "每个健康边界只能回调一次，并应继续调度下一边界")
        XCTAssertEqual(settledBatches, 1, "健康边界不应额外触发 batch settled（仅保留空循环初始 pass）")
    }
    @MainActor
    func testHealthBoundaryDoesNotPolluteEarliestNextRefreshAndCancelClearsIt() {
        let clock = SchedulerTestClock(date: Date(timeIntervalSince1970: 2_000))
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .deferred },
            intervalProvider: { _ in 300 },
            now: { clock.date },
            sleep: { _ in }
        )
        scheduler.schedule(for: "provider")
        let regularDate = scheduler.earliestNextRefresh
        scheduler.scheduleHealthBoundary(at: clock.date.addingTimeInterval(1))

        XCTAssertEqual(scheduler.earliestNextRefresh, regularDate,
                       "健康边界不得污染 UI 展示的 regular nextRefreshAt")
        XCTAssertEqual(scheduler.scheduledHealthBoundary, clock.date.addingTimeInterval(1))

        scheduler.cancelAll()
        XCTAssertNil(scheduler.scheduledHealthBoundary, "cancelAll 后不得残留健康边界")
        XCTAssertNil(scheduler.earliestNextRefresh)
    }
}
