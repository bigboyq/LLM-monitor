import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// 额度循环 / 本地用量循环的双循环架构回归（前半）：reconcile 档位、并发合并、排队与 teardown。
final class DualLoopReconcileTests: StateTestCase {

    // MARK: - 双循环架构回归测试
    /// 循环 A 条目级隔离：在同一 tick 到期的两个 provider，provider A 失败，provider B 依然正常成功完成
    @MainActor
    func testLoopAProviderIsolationBatchRefresh() async {
        var completed: [String: Bool] = [:]
        let sched = ProviderRefreshScheduler(
            refreshHandler: { providerID, mode in
                if providerID == "fail_provider" {
                    completed[providerID] = false
                    return .completed(success: false)
                } else {
                    completed[providerID] = true
                    return .completed(success: true)
                }
            },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {},
            sleep: { _ in }
        )

        sched.schedule(for: "fail_provider")
        sched.schedule(for: "success_provider")

        // 等待并发 batch 执行完成
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(completed["fail_provider"], false, "A 应该失败")
        XCTAssertEqual(completed["success_provider"], true, "B 应该成功，不受 A 失败影响")

        // 失败也按 baseInterval 排下一拍（不退避）：取消成功 provider 后，
        // earliest 就是失败 provider 的排期，应 ≈ now + baseInterval(60s)。
        try? await Task.sleep(nanoseconds: 100_000_000)  // 确保 batch 完全结算
        let baseline = Date()
        sched.cancel(providerID: "success_provider")
        let failNext = sched.earliestNextRefresh
        sched.cancelAll()

        guard let failNext else {
            XCTFail("失败 provider 也必须有下一次刷新排期")
            return
        }
        let failOffset = failNext.timeIntervalSince(baseline)
        XCTAssertGreaterThanOrEqual(failOffset, 55, "失败 provider 仍按 baseInterval(60s) 排下次刷新，不退避")
        XCTAssertLessThanOrEqual(failOffset, 65, "失败 provider 的下次刷新不应晚于 baseInterval")
    }
    /// LocalUsage reconcile 的客户端 readiness 探测与去噪：readiness 仅驱动诊断日志，
    /// 状态变动时正确识别。扫描本身由其他临时目录测试覆盖；本测试不应因验证
    /// readiness 而构造生产路径 scanner。
    @MainActor
    func testReconcileReadinessLoggingDeduplication() async {
        final class DummyWriter: LocalUsageStatusWriting {
            func providerID(for kind: ProviderKind) -> String? { "test" }
            func setScanningState(_ isScanning: Bool, for providerID: String) {}
            func applyAntigravityLocalUsage(_ usage: AntigravityLocalUsage?) {}
            func applyMinimaxLocalUsage(_ usage: ProviderLocalUsage?) {}
            func applyGlmLocalUsage(_ usage: GlmLocalUsage?) {}
            func applyOpencodeUsage(_ usage: OpencodeLocalUsage?) {}
            func applyDshUsage(_ usage: DshLocalUsage?) {}
            func codexEnrichmentTarget() -> (providerID: String, authPath: String?, model: ModelQuota?, fetchedAt: Date, generation: Int)? { nil }
            func codexConfiguredAuthPath() -> String? { nil }
            func applyCodexUsageDetails(_ details: CodexUsageDetails?, providerID: String, fetchedAt: Date, configurationGeneration: Int) {}
        }

        let writer = DummyWriter()
        let orchestration = LocalUsageOrchestration(writer: writer)

        var readyState = false
        orchestration.testReadinessOverride = { _ in readyState }

        // 首次扫描（未就绪）：正常跳过，不崩溃
        await orchestration.scanAllClients()
        XCTAssertFalse(orchestration.checkClientReadiness("minimax_code"))

        // 第二次扫描（依然未就绪）：去噪跳过
        await orchestration.scanAllClients()

        // 状态转为就绪
        readyState = true
        XCTAssertTrue(orchestration.checkClientReadiness("minimax_code"))

        orchestration.cancelInFlightAll()
    }
    /// codex readiness 走 CodexFetcher 的解析链（config authPath → CODEX_HOME →
    /// ~/.codex）：配置了自定义 authPath 时按该路径判定，而不是硬编码 ~/.codex
    @MainActor
    func testCodexReadinessResolvesConfiguredAuthPath() async throws {
        final class PathWriter: LocalUsageStatusWriting {
            var authPath: String?
            func providerID(for kind: ProviderKind) -> String? { "test" }
            func setScanningState(_ isScanning: Bool, for providerID: String) {}
            func applyAntigravityLocalUsage(_ usage: AntigravityLocalUsage?) {}
            func applyMinimaxLocalUsage(_ usage: ProviderLocalUsage?) {}
            func applyGlmLocalUsage(_ usage: GlmLocalUsage?) {}
            func applyOpencodeUsage(_ usage: OpencodeLocalUsage?) {}
            func applyDshUsage(_ usage: DshLocalUsage?) {}
            func codexEnrichmentTarget() -> (providerID: String, authPath: String?, model: ModelQuota?, fetchedAt: Date, generation: Int)? { nil }
            func codexConfiguredAuthPath() -> String? { authPath }
            func applyCodexUsageDetails(_ details: CodexUsageDetails?, providerID: String, fetchedAt: Date, configurationGeneration: Int) {}
        }

        let writer = PathWriter()
        let orchestration = LocalUsageOrchestration(writer: writer)
        defer { orchestration.cancelInFlightAll() }

        let customHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-readiness-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: customHome) }

        // 自定义 authPath 指向的目录不存在 → 未就绪（旧实现硬编码 ~/.codex，
        // 在有 ~/.codex 的机器上会误判为就绪）
        writer.authPath = customHome.path
        XCTAssertFalse(orchestration.checkClientReadiness("codex"))

        // 目录创建后 → 就绪
        try FileManager.default.createDirectory(at: customHome, withIntermediateDirectories: false)
        XCTAssertTrue(orchestration.checkClientReadiness("codex"))

        // authPath 是文件路径时按其所在目录判定（与 loadUsageDetailsAsync 一致）
        writer.authPath = customHome.appendingPathComponent("auth.json").path
        XCTAssertTrue(orchestration.checkClientReadiness("codex"))
    }
    @MainActor
    func testLocalUsageReconcileTransitionsFromFullToDirty() async {
        let orchestration = LocalUsageOrchestration(writer: ReconcileNoopWriter())
        orchestration.testReadinessOverride = { _ in false }

        XCTAssertEqual(orchestration.nextReconcileMode, .full)
        await orchestration.reconcile()
        XCTAssertEqual(
            orchestration.nextReconcileMode,
            .dirty,
            "首次 Full Scan 完成后，后续 reconcile 应只消费 dirty source"
        )
        orchestration.cancelInFlightAll()
    }
    @MainActor
    func testManualAndDayBoundaryReconcileReuseDirtyModeAfterStartupFull() async {
        var modes: [LocalUsageScanMode] = []
        let orchestration = LocalUsageOrchestration(writer: ReconcileNoopWriter())
        orchestration.testReconcilePass = { mode in
            modes.append(mode)
        }
        defer { orchestration.cancelInFlightAll() }

        await orchestration.triggerStartupFullScanAll()
        await orchestration.triggerImmediateScanAll()

        XCTAssertEqual(
            modes,
            [.full, .dirty],
            "启动首拍保留 full；手工及日切后的普通 reconcile 应复用 dirty/offset 路径"
        )
        XCTAssertEqual(orchestration.nextReconcileMode, .dirty)
    }
    @MainActor
    func testReconcileModesKeepCacheAssistedFullSeparateFromHardFull() {
        XCTAssertFalse(
            LocalUsageScanMode.full.bypassesProviderCache,
            "startup full must let each Provider validate and reuse its own cache"
        )
        XCTAssertFalse(LocalUsageScanMode.dirty.bypassesProviderCache)
        XCTAssertTrue(
            LocalUsageScanMode.hardFull.bypassesProviderCache,
            "only explicit hard-full invalidates Provider caches"
        )
        XCTAssertEqual(LocalUsageScanMode.full.displayName, "cache-assisted-full")
        XCTAssertEqual(LocalUsageScanMode.dirty.displayName, "dirty-reconcile")
        XCTAssertEqual(LocalUsageScanMode.hardFull.displayName, "hard-full")
        XCTAssertEqual(LocalUsageScanMode.merged(.dirty, .full), .full)
        XCTAssertEqual(LocalUsageScanMode.merged(.full, .hardFull), .hardFull)
        XCTAssertEqual(LocalUsageScanMode.merged(.hardFull, .dirty), .hardFull)
    }
    @MainActor
    func testAppStateSchedulesSleepHealthRefreshOnSharedDeadlineDriver() {
        let store = makeIsolatedConfigStore()
        let state = AppState(descriptors: [], configStore: store)
        defer { state.stop() }

        let deadline = state.refreshScheduler.scheduledHealthBoundary
        XCTAssertNotNil(deadline)
        XCTAssertGreaterThan(deadline ?? .distantPast, Date())
        XCTAssertLessThanOrEqual(
            deadline?.timeIntervalSinceNow ?? .infinity,
            5 * 60 + 1,
            "睡眠健康度应复用共享 deadline driver 周期刷新"
        )
    }
    @MainActor
    func testLocalUsageScheduleReconcileRequeuesPendingBatch() async {
        let probe = ReconcilePassProbe()
        let orchestration = LocalUsageOrchestration(writer: ReconcileNoopWriter())
        orchestration.testReconcilePass = { mode in
            await probe.run(mode)
        }
        defer { orchestration.cancelInFlightAll() }

        orchestration.scheduleReconcile()
        await probe.waitForFirstStart()
        orchestration.scheduleReconcile()
        await probe.releaseFirst()
        await probe.waitForCount(2)

        let modes = await probe.snapshot()
        XCTAssertEqual(modes, [.full, .dirty])
    }
    @MainActor
    func testLocalUsageExplicitFullReconcileIsNotDowngradedByActiveSchedule() async {
        let probe = ReconcilePassProbe()
        let orchestration = LocalUsageOrchestration(writer: ReconcileNoopWriter())
        orchestration.testReconcilePass = { mode in
            await probe.run(mode)
        }
        defer { orchestration.cancelInFlightAll() }

        orchestration.scheduleReconcile()
        await probe.waitForFirstStart()
        let explicitFull = Task { @MainActor in
            await orchestration.reconcile(mode: .full)
        }
        await Task.yield()
        await Task.yield()
        await probe.releaseFirst()
        await explicitFull.value
        await probe.waitForCount(2)

        let modes = await probe.snapshot()
        XCTAssertEqual(modes, [.full, .full])
    }
    @MainActor
    func testAwaitedReconcileWaitsForCoalescedFollowUpToFinish() async {
        let probe = ReconcilePassProbe()
        await probe.setBlockSecondPass(true)
        let orchestration = LocalUsageOrchestration(writer: ReconcileNoopWriter())
        orchestration.testReconcilePass = { mode in
            await probe.run(mode)
        }
        defer { orchestration.cancelInFlightAll() }

        orchestration.scheduleReconcile()
        await probe.waitForFirstStart()
        let explicitFull = Task { @MainActor in
            await orchestration.reconcile(mode: .full)
        }
        await probe.releaseFirst()
        await probe.waitForSecondStart()

        var explicitReturned = false
        let observer = Task { @MainActor in
            await explicitFull.value
            explicitReturned = true
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(explicitReturned)

        await probe.releaseSecond()
        await explicitFull.value
        await observer.value
        XCTAssertTrue(explicitReturned)
        let finalModes = await probe.snapshot()
        XCTAssertEqual(finalModes, [.full, .full])
    }
    @MainActor
    func testConcurrentSynchronousReconcilesShareOneCompletionChain() async {
        let probe = ReconcilePassProbe()
        await probe.setBlockSecondPass(true)
        let orchestration = LocalUsageOrchestration(writer: ReconcileNoopWriter())
        orchestration.testReconcilePass = { mode in
            await probe.run(mode)
        }
        defer { orchestration.cancelInFlightAll() }

        let first = Task { @MainActor in
            await orchestration.reconcile(mode: .full)
        }
        await probe.waitForFirstStart()
        let second = Task { @MainActor in
            await orchestration.reconcile(mode: .full)
        }
        await probe.releaseFirst()
        await probe.waitForSecondStart()

        var firstReturned = false
        var secondReturned = false
        let firstObserver = Task { @MainActor in
            await first.value
            firstReturned = true
        }
        let secondObserver = Task { @MainActor in
            await second.value
            secondReturned = true
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(firstReturned)
        XCTAssertFalse(secondReturned)

        await probe.releaseSecond()
        await first.value
        await second.value
        await firstObserver.value
        await secondObserver.value
        XCTAssertTrue(firstReturned)
        XCTAssertTrue(secondReturned)
    }
    @MainActor
    func testReconcileTeardownConsumesRequestQueuedBeforeOwnerRelease() async {
        var modes: [LocalUsageScanMode] = []
        var injected = false
        var orchestration: LocalUsageOrchestration!
        orchestration = LocalUsageOrchestration(writer: ReconcileNoopWriter())
        orchestration.testReconcilePass = { mode in
            modes.append(mode)
        }
        orchestration.testReconcileChainTeardownHook = {
            guard !injected else { return }
            injected = true
            orchestration.scheduleReconcile(mode: .dirty)
        }
        defer { orchestration.cancelInFlightAll() }

        await orchestration.reconcile(mode: .full)

        XCTAssertEqual(
            modes,
            [.full, .dirty],
            "请求在 chain 收尾时到达也必须被后续 pass 消费，不能因 owner 清理而丢失"
        )
    }
}
