import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// `AppState` 的状态派生、统一广播通道、取消误判与多 waiter 失败保留。对应 `AppState`。
final class AppStateTests: StateTestCase {

    // MARK: - AppState 统一 status 广播通道
    /// 验证 `AppState.statusDidChange` 是 `PassthroughSubject<Void, Never>`，
    /// 不带 payload（payload 之前是 antigravity/minimax 局部 usage，UI 端忽略；现在
    /// 统一成 Void，UI 端只挂一个空 .onReceive）。
    @MainActor
    func testAppStateStatusDidChangePublisherShape() {
        // 编译期 + 运行期双重检查
        let state = makeTestAppState()
        let subject: PassthroughSubject<Void, Never> = state.statusDidChange
        let cancellable = subject.sink { _ in }
        // 单纯能创建并订阅就说明类型对了
        cancellable.cancel()
        XCTAssertNotNil(subject)
    }
    // MARK: - 测试 AppState 构造 helper
    /// 构造一个最小可用的 AppState 用于测试：
    /// - 注入临时目录的 ConfigStore，不读取或改写用户配置
    /// - 1 个 antigravity 描述符
    /// - 不启动任何 background task（refreshAll / refreshOne 必须显式调用）
    @MainActor
    func makeTestAppState() -> AppState {
        let configStore = makeIsolatedConfigStore()
        // This helper only tests the status broadcast shape. Disable the
        // provider explicitly so AppState.start() cannot lazily construct the
        // production Antigravity scanner and walk ~/.gemini during the test.
        var config = configStore.config
        config.providers["antigravity"] = ProviderConfig(enabled: false)
        try! configStore.applyAndSave(config)
        let descriptors: [FetcherDescriptor] = [
            FetcherDescriptor(
                id: "antigravity",
                displayName: "Antigravity",
                kind: .antigravity,
                iconSystemName: "paperplane",
                accentColor: .antigravity,
                makeFetcher: { _ in AntigravityFetcher() }
            )
        ]
        let state = AppState(descriptors: descriptors, configStore: configStore)
        // 立刻 stop 避免 background task 抢资源
        state.stop()
        return state
    }
    // MARK: - AppState.deriveState (从 config + auth probe 派生 State)
    /// deriveState 4 个分支 in 1：provider 缺失 / 禁用 / placeholder key / 真实 key。
    /// 共享 setup：构造 FetcherDescriptor + ProviderConfig，验证 state case + reason。
    @MainActor
    func testDeriveStateBranches() {
        // 通用 minimax (apiKey auth) descriptor
        let minimaxDescriptor = FetcherDescriptor(
            id: "minimax_token_plan",
            displayName: "Test",
            kind: .minimaxTokenPlan,
            iconSystemName: "circle",
            accentColor: .minimax,
            makeFetcher: { _ in MinimaxTokenPlanFetcher(apiKey: "k") }
        )
        // 通用 "其他 provider" descriptor (id 不同, 走通用分支)
        let otherDescriptor = FetcherDescriptor(
            id: "other",
            displayName: "Test",
            kind: .minimaxTokenPlan,
            iconSystemName: "circle",
            accentColor: .custom,
            makeFetcher: { _ in MinimaxTokenPlanFetcher(apiKey: "k") }
        )
        // 1. provider 在 config 里完全缺失 → notConfigured("未在 config.json 中配置")
        do {
            let state = AppState.deriveState(
                descriptor: otherDescriptor,
                providerConfig: nil,
                authProber: nil,
                hintProvider: { _, _ in "hint" }
            )
            if case .notConfigured(let reason) = state {
                XCTAssertEqual(reason, "未在 config.json 中配置")
            } else {
                XCTFail("expected .notConfigured('未在 config.json 中配置'), got \(state)")
            }
        }
        // 2. provider 禁用 → notConfigured("已在 config.json 中禁用")
        do {
            let pc = ProviderConfig(enabled: false, apiKey: "any")
            let state = AppState.deriveState(
                descriptor: otherDescriptor,
                providerConfig: pc,
                authProber: nil,
                hintProvider: { _, _ in "hint" }
            )
            if case .notConfigured(let reason) = state {
                XCTAssertEqual(reason, "已在 config.json 中禁用")
            } else {
                XCTFail("expected .notConfigured('已在 config.json 中禁用'), got \(state)")
            }
        }
        // 3. minimax (apiKey auth) + 占位符 key → notConfigured("API Key 未填写")
        do {
            let pc = ProviderConfig(enabled: true, apiKey: "REPLACE-WITH-YOUR-KEY")
            let state = AppState.deriveState(
                descriptor: minimaxDescriptor,
                providerConfig: pc,
                authProber: nil,
                hintProvider: { _, _ in "hint" }
            )
            if case .notConfigured(let reason) = state {
                XCTAssertEqual(reason, "API Key 未填写")
            } else {
                XCTFail("expected .notConfigured('API Key 未填写'), got \(state)")
            }
        }
        // 4. minimax (apiKey auth) + 真实 key → .ready
        do {
            let pc = ProviderConfig(enabled: true, apiKey: "sk-cp-real-key")
            let state = AppState.deriveState(
                descriptor: minimaxDescriptor,
                providerConfig: pc,
                authProber: nil,
                hintProvider: { _, _ in "hint" }
            )
            if case .ready = state {
                // OK
            } else {
                XCTFail("expected .ready, got \(state)")
            }
        }
    }
    // MARK: - R4: Antigravity 离线保留 lastSuccess（类型化 derive reason）
    /// R4：已配置且 auth 文件在，但本地服务探测不可用 → serviceOffline；
    ///     恢复后 → ready；禁用 → notConfigured（必须清空，不是离线）。
    @MainActor
    func testR4DeriveAntigravityServiceOfflineVsDisabled() async throws {
        let fetcher = FakeFetcher(providerID: "antigravity", hasLocalAuth: true, checkLocalAuth: false)
        let descriptor = FetcherDescriptor(
            id: "antigravity",
            displayName: "Antigravity",
            kind: .antigravity,
            iconSystemName: "paperplane",
            accentColor: .antigravity,
            makeFetcher: { _ in fetcher }
        )
        let prober = AuthProber(fetcherProvider: { _ in fetcher }, onChange: { _, _ in })
        prober.scheduleProbe(for: "antigravity")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(prober.isUnavailable("antigravity"), "探测应把 availability 设为 false")

        // 启用 + 服务离线 → serviceOffline
        let enabledPc = ProviderConfig(enabled: true)
        let offline = AppState.deriveProviderState(
            descriptor: descriptor,
            providerConfig: enabledPc,
            authProber: prober,
            hintProvider: { _, _ in "hint" }
        )
        XCTAssertEqual(offline, .serviceOffline(message: "Antigravity 本地服务离线"))

        // 恢复（markAvailable）→ ready
        prober.markAvailable("antigravity")
        XCTAssertFalse(prober.isUnavailable("antigravity"))
        let recovered = AppState.deriveProviderState(
            descriptor: descriptor,
            providerConfig: enabledPc,
            authProber: prober,
            hintProvider: { _, _ in "hint" }
        )
        XCTAssertEqual(recovered, .ready)

        // 禁用 → notConfigured（必须清空，不保留数据）
        let disabledPc = ProviderConfig(enabled: false)
        let disabled = AppState.deriveProviderState(
            descriptor: descriptor,
            providerConfig: disabledPc,
            authProber: prober,
            hintProvider: { _, _ in "hint" }
        )
        if case .notConfigured = disabled {
            // OK
        } else {
            XCTFail("禁用 provider 必须派生为 .notConfigured，got \(disabled)")
        }
    }
    /// R4：serviceOffline 分支保留 lastSuccess——lastSuccessInfo 能从 .ok/.failed/.loading
    /// 正确取出旧 QuotaInfo，rebuildStatuses 用它构造 .failed(message, lastSuccess:)。
    func testR4LastSuccessInfoExtractionFromStates() {
        let info = QuotaInfo(models: [], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: Date())
        XCTAssertEqual(AppState.lastSuccessInfo(from: .ok(info)), info)
        XCTAssertEqual(AppState.lastSuccessInfo(from: .failed(message: "x", lastSuccess: info)), info)
        XCTAssertEqual(AppState.lastSuccessInfo(from: .loading(lastSuccess: info)), info)
        XCTAssertNil(AppState.lastSuccessInfo(from: .loading(lastSuccess: nil)))
        XCTAssertNil(AppState.lastSuccessInfo(from: .ready))
        XCTAssertNil(AppState.lastSuccessInfo(from: .notConfigured(reason: "r")))
    }
    // MARK: - P3.1: AppState 取消误判
    /// 构造测试用 AppState，注入可控 fetcher。使用 Codex 类型避免 AppState.start()
    /// 在测试进程里触发真实用户目录的 minimax 本地数据库扫描。
    @MainActor
    func makeCancellationTestAppState(
        providerID: String = "test_provider",
        fetcher: ErrorThrowingFetcher
    ) -> (AppState, ErrorThrowingFetcher) {
        let configStore = makeIsolatedConfigStore()
        // 给 provider 配一个 enabled block + 隔离的 authPath；测试 fetcher 自己报告 auth 可用。
        var config = configStore.config
        config.providers[providerID] = ProviderConfig(
            enabled: true,
            authPath: configStore.configURL.deletingLastPathComponent()
                .appendingPathComponent("auth.json").path
        )
        try! configStore.applyAndSave(config)

        let descriptors: [FetcherDescriptor] = [
            FetcherDescriptor(
                id: providerID,
                displayName: providerID,
                kind: .codexChatGpt,
                iconSystemName: "star",
                accentColor: .chatgpt,
                makeFetcher: { _ in fetcher }
            )
        ]
        let state = AppState(descriptors: descriptors, configStore: configStore)
        state.stop()
        // state.stop() 会 cancel scheduler 的 background task;
        // refreshOne 走自己的 Task 路径，不受 stop 影响
        return (state, fetcher)
    }
    @MainActor
    func makeRefreshWaitTestAppState(fetcher: BlockingRefreshFetcher) -> AppState {
        let configStore = makeIsolatedConfigStore()
        var config = configStore.config
        config.providers[fetcher.providerID] = ProviderConfig(
            enabled: true,
            authPath: configStore.configURL.deletingLastPathComponent()
                .appendingPathComponent("auth.json").path
        )
        try! configStore.applyAndSave(config)

        let descriptors: [FetcherDescriptor] = [
            FetcherDescriptor(
                id: fetcher.providerID,
                displayName: fetcher.displayName,
                kind: fetcher.kind,
                iconSystemName: "star",
                accentColor: .chatgpt,
                makeFetcher: { _ in fetcher }
            )
        ]
        let state = AppState(descriptors: descriptors, configStore: configStore)
        state.stop()
        return state
    }
    @MainActor
    func testAppStateCancelledFullRefreshWaitDoesNotTriggerSecondFetch() async {
        let fetcher = BlockingRefreshFetcher()
        let state = makeRefreshWaitTestAppState(fetcher: fetcher)
        defer { state.stop() }

        let backgroundTask = Task { @MainActor in
            await state.refreshScheduler.runRefresh(
                fetcher.providerID, mode: .background
            )
        }
        await fetcher.gate.waitUntilReached()

        let manualTask = Task { @MainActor in
            await state.refreshOne(providerID: fetcher.providerID)
        }
        for _ in 0..<100 where state.refreshScheduler.inFlightWaiterCount(
            for: fetcher.providerID
        ) == 0 {
            await Task.yield()
        }
        XCTAssertEqual(
            state.refreshScheduler.inFlightWaiterCount(for: fetcher.providerID),
            1,
            "full refresh 应先注册为 in-flight waiter"
        )

        // 取消仍在等待 background 的 full refresh；释放两次 gate 是为了让旧实现
        // 若错误地继续发起第二次 full fetch，也能安全结束并由调用次数断言捕获。
        manualTask.cancel()
        await fetcher.gate.release()
        _ = await backgroundTask.value
        await fetcher.gate.release()
        _ = await manualTask.value

        let calls = await fetcher.calls.calls
        XCTAssertEqual(calls, 1, "取消等待中的 full refresh 不应触发第二次 fetch")
        XCTAssertNil(state.refreshScheduler.inFlightMode(for: fetcher.providerID))
    }
    @MainActor
    func testAppStateCancellationErrorDoesNotMarkFailed() async {
        // 1. fetcher 抛 CancellationError → 期望 .deferred（不污染 failure 计数）
        let fetcher = ErrorThrowingFetcher(
            providerID: "test_cancel",
            errorToThrow: CancellationError()
        )
        let (state, _) = makeCancellationTestAppState(
            providerID: "test_cancel",
            fetcher: fetcher
        )
        let providerID = "test_cancel"
        let idx = state.statuses.firstIndex(where: { $0.id == providerID })!

        // 触发 refresh（应走 catch 的取消分支，return .deferred，不动 .failed）
        await state.refreshOne(providerID: providerID)

        // 验证：
        // 1. fetcher 真的被调了
        XCTAssertEqual(fetcher.fetchCallCount, 1, "fetcher 至少应被调 1 次")
        // 2. 状态不是 .failed（取消走 .deferred，不进入失败排期）
        if case .failed = state.statuses[idx].state {
            XCTFail("CancellationError 不应导致 .failed 状态，实际：\(state.statuses[idx].state)")
        }
    }
    @MainActor
    func testAppStateURLErrorCancelledDoesNotMarkFailed() async {
        // 2. URLError(.cancelled) 同样走 .deferred
        let fetcher = ErrorThrowingFetcher(
            providerID: "test_url_cancel",
            errorToThrow: URLError(.cancelled)
        )
        let (state, _) = makeCancellationTestAppState(
            providerID: "test_url_cancel",
            fetcher: fetcher
        )
        let providerID = "test_url_cancel"
        let idx = state.statuses.firstIndex(where: { $0.id == providerID })!

        await state.refreshOne(providerID: providerID)

        XCTAssertEqual(fetcher.fetchCallCount, 1)
        if case .failed = state.statuses[idx].state {
            XCTFail("URLError.cancelled 不应导致 .failed 状态")
        }
    }
    @MainActor
    func testAppStateRealNetworkErrorDoesMarkFailed() async {
        // 3. 反例：真实网络错误（不是取消）仍应走 .failed
        struct FakeNetworkError: LocalizedError {
            var errorDescription: String? { "connection timeout" }
        }
        let fetcher = ErrorThrowingFetcher(
            providerID: "test_net_err",
            errorToThrow: FakeNetworkError()
        )
        let (state, _) = makeCancellationTestAppState(
            providerID: "test_net_err",
            fetcher: fetcher
        )
        let providerID = "test_net_err"
        let idx = state.statuses.firstIndex(where: { $0.id == providerID })!

        await state.refreshOne(providerID: providerID)

        XCTAssertEqual(fetcher.fetchCallCount, 1)
        guard case .failed(let message, _) = state.statuses[idx].state else {
            XCTFail("真实网络错误应导致 .failed 状态，实际：\(state.statuses[idx].state)")
            return
        }
        XCTAssertTrue(message.contains("timeout"), "错误消息应包含原始信息")
    }
    @MainActor
    func testAppStateRepeatedCancellationsNeverMarkFailed() async {
        // 4. 多次连续取消 → 每次都走 .deferred（取消不是失败，没有可累积的失败状态）
        let fetcher = ErrorThrowingFetcher(
            providerID: "test_multi_cancel",
            errorToThrow: CancellationError()
        )
        let (state, _) = makeCancellationTestAppState(
            providerID: "test_multi_cancel",
            fetcher: fetcher
        )
        let providerID = "test_multi_cancel"
        let idx = state.statuses.firstIndex(where: { $0.id == providerID })!

        // 连续 3 次取消
        for _ in 0..<3 {
            await state.refreshOne(providerID: providerID)
        }

        XCTAssertEqual(fetcher.fetchCallCount, 3, "每次取消后都应允许再次发起刷新")
        if case .failed = state.statuses[idx].state {
            XCTFail("连续取消也不应导致 .failed 状态")
        }
    }
    // MARK: - P0 #2: AppState 多 waiter / 失败保留 lastSuccess
    /// 多个 `refreshOne` 在同一 background refresh 上挂起时，只有一个 waiter 真正
    /// 补跑 full refresh（`pendingFullRefreshIDs` Set 的"单次 claim"语义），
    /// 其余 waiter 在 background 完成后直接返回，不触发第二次 fetch。
    ///
    /// 验证 `pendingFullRefreshWaiterCounts` 的语义：refcount 正确反映"还有几个
    /// waiter 在挂"，背景完成时只有一个 waiter 抢到 full refresh 名额。
    @MainActor
    func testAppStateMultiplePendingFullRefreshWaitersClaimOnlyOnce() async {
        // background 段使用可控 fetcher：第一次进入 fetch 会立刻 hold 在 gate 上。
        // 这里让它在 hold 期间人为结束（gate.release）模拟"background 完成"。
        // 但更稳的做法是直接 markInFlight 模拟 background，不再起真的 background。
        // 我们用 makeRefreshWaitTestAppState（已有 BlockingRefreshFetcher）的同款配置，
        // 但不启动 background —— 改用 scheduler.markInFlight 注入。
        let fetcher = BlockingRefreshFetcher()
        let state = makeRefreshWaitTestAppState(fetcher: fetcher)
        defer { state.stop() }

        // 1. 注入一个 background 段（fetcher.fetch 已经在 background 路径上调用过，
        //    通过 markInFlight + 模拟"background 进行中"）—— 但更直接的做法是
        //    让 background 段就是 fetcher.fetch 第一次调用。这里我们让第一个
        //    refreshOne 走 background mode：会触发 fetcher.fetch（计数 +1），
        //    然后 hold 在 gate 上。
        let backgroundTask = Task { @MainActor in
            await state.refreshScheduler.runRefresh(
                fetcher.providerID, mode: .background
            )
        }
        await fetcher.gate.waitUntilReached()
        let callsAfterBackground = await fetcher.calls.calls
        XCTAssertEqual(callsAfterBackground, 1, "background 段应已调用 fetcher 一次")

        // 2. 起两个 full refresh waiter。它们在 background 段进行时会挂起等待
        //    waitUntilNotInFlight，并在 background 完成后争抢一个 full refresh 名额。
        let waiter1 = Task { @MainActor in
            await state.refreshOne(providerID: fetcher.providerID)
        }
        let waiter2 = Task { @MainActor in
            await state.refreshOne(providerID: fetcher.providerID)
        }
        // 全局 Manual gate 只允许第一个 Manual 进入；第二个点击必须立即拒绝，
        // 不得再往 in-flight waiter 队列堆积。
        for _ in 0..<200
        where state.refreshScheduler.inFlightWaiterCount(for: fetcher.providerID) < 1 {
            await Task.yield()
        }
        XCTAssertEqual(
            state.refreshScheduler.inFlightWaiterCount(for: fetcher.providerID),
            1,
            "全局 Manual gate 只应保留一个等待中的 Manual"
        )

        // 3. 释放 background —— fetcher.fetch 第一次返回，markNotInFlight 会唤醒
        //    两个 waiter。其中一个 claim 到 full refresh 名额并触发 fetcher.fetch 第二次
        //    调用，第二个 waiter 看到 pendingFullRefreshIDs.remove 返回 nil 后直接 return。
        await fetcher.gate.release()
        _ = await backgroundTask.value

        // 4. 等两个 waiter 决出胜负 + full refresh 段走完。full refresh 段也会
        //    调一次 fetcher.fetch 并 hold 在 gate 上；用第二次 release 放它走。
        for _ in 0..<200 where (await fetcher.calls.calls) < 2 {
            await Task.yield()
        }
        await fetcher.gate.release()

        _ = await waiter1.value
        _ = await waiter2.value

        // 5. 最终断言：fetcher 调了 2 次（1 background + 1 full）。
        //    如果 multi-waiter claim 语义出错，会有第 3 次（两个 waiter 都 claim 成功）。
        let finalCalls = await fetcher.calls.calls
        XCTAssertEqual(
            finalCalls, 2,
            "两个 full refresh waiter 在 background 完成后只应有一个触发第二次 fetch"
        )
        XCTAssertNil(
            state.refreshScheduler.inFlightMode(for: fetcher.providerID),
            "全部完成 in-flight 应清空"
        )
    }
    /// 一次成功的 refresh 留下 `lastSuccess` 后，紧跟一次失败 —— `.failed` 必须
    /// 保留上次的 `lastSuccess`（而不是 nil）。否则用户看到 "刷新失败 + 数据空白"
    /// 会误判为"什么都没抓到"。
    @MainActor
    func testAppStateRefreshFailurePreservesLastSuccessInFailedState() async {
        // fetcher 第一次返回成功，第二次返回真实网络错误。
        // 同一个 fetcher 实例，依次接受两个 mode 的不同结果。
        final class TwoShotFetcher: QuotaFetcher, @unchecked Sendable {
            let providerID = "two_shot"
            let displayName = "two_shot"
            let kind = ProviderKind.codexChatGpt
            let logTag = "[two_shot]"
            private(set) var calls: Int = 0
            func fetch(mode: RefreshMode) async throws -> QuotaInfo {
                calls += 1
                if calls == 1 {
                    return QuotaInfo(
                        models: [ModelQuota(
                            modelName: "chatgpt_plan",
                            intervalTotalCount: 0, intervalUsageCount: 0,
                            intervalRemainingPercent: 60, intervalStatus: .present,
                            intervalResetsAt: nil, intervalWindowSeconds: nil,
                            weeklyTotalCount: 0, weeklyUsageCount: 0,
                            weeklyRemainingPercent: 0, weeklyStatus: .absent,
                            weeklyResetsAt: nil, weeklyWindowSeconds: nil
                        )],
                        resetCredits: nil, planLabel: nil, accountEmail: nil,
                        codexUsageDetails: nil,
                        fetchedAt: Date(timeIntervalSince1970: 1_900_000_000)
                    )
                }
                struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
                throw Boom()
            }
            func hasLocalAuth() -> Bool { true }
            func checkLocalAuth() async -> Bool { true }
        }
        let fetcher = TwoShotFetcher()
        let configStore = makeIsolatedConfigStore()
        var config = configStore.config
        config.providers[fetcher.providerID] = ProviderConfig(
            enabled: true,
            authPath: configStore.configURL.deletingLastPathComponent()
                .appendingPathComponent("auth.json").path
        )
        try! configStore.applyAndSave(config)

        let descriptors: [FetcherDescriptor] = [
            FetcherDescriptor(
                id: fetcher.providerID,
                displayName: fetcher.providerID,
                kind: .codexChatGpt,
                iconSystemName: "star",
                accentColor: .chatgpt,
                makeFetcher: { _ in fetcher }
            )
        ]
        let realState = AppState(descriptors: descriptors, configStore: configStore)
        realState.stop()
        defer { realState.stop() }

        let idx = realState.statuses.firstIndex(where: { $0.id == fetcher.providerID })!
        // 1. 第一次 refresh —— 成功，.ok
        await realState.refreshOne(providerID: fetcher.providerID)
        XCTAssertEqual(fetcher.calls, 1)
        guard case .ok(let firstInfo) = realState.statuses[idx].state else {
            XCTFail("第一次 refresh 应 .ok，实际：\(realState.statuses[idx].state)")
            return
        }
        XCTAssertEqual(firstInfo.models.first?.intervalRemainingPercent, 60)
        XCTAssertNotNil(realState.statuses[idx].lastSuccess, "成功后 lastSuccess 应该有值")

        // 2. 第二次 refresh —— 失败，状态应 .failed(_, lastSuccess: <first>)
        await realState.refreshOne(providerID: fetcher.providerID)
        XCTAssertEqual(fetcher.calls, 2)
        guard case .failed(let message, let lastSuccess) = realState.statuses[idx].state else {
            XCTFail("第二次 refresh 应 .failed，实际：\(realState.statuses[idx].state)")
            return
        }
        XCTAssertEqual(message, "boom", "失败消息应保留原始错误描述")
        XCTAssertNotNil(
            lastSuccess, "失败时 lastSuccess 必须保留前一次成功的数据，不能丢"
        )
        XCTAssertEqual(
            lastSuccess?.models.first?.intervalRemainingPercent, 60,
            "保留的 lastSuccess 字段应跟第一次成功数据一致"
        )
    }
    // MARK: - 单 provider 重锚契约（回归 a287e8d 的 reanchorAllProviders）

    /// refreshOne(A) 只重锚 A（回归：旧实现 refreshOne 无条件 reanchorAllProviders，
    /// 会把 B/C/D 的下一拍推后一个完整间隔、清零它们的周期 full 计数与 reset
    /// 补刷新点）。A 自己的常规时间线从 refreshOne 完成时刻重算，周期 full 计数
    /// 归零，reset candidates 按新数据重排。
    @MainActor
    func testRefreshOneReanchorsOnlyRefreshedProvider() async {
        let ids = ["prov_a", "prov_b", "prov_c", "prov_d"]
        let store = makeIsolatedConfigStore()
        var config = store.config
        config.refreshIntervalSeconds = 300
        for id in ids {
            config.providers[id] = ProviderConfig(
                enabled: true,
                authPath: store.configURL.deletingLastPathComponent()
                    .appendingPathComponent("auth.json").path
            )
        }
        try! store.applyAndSave(config)

        let descriptors: [FetcherDescriptor] = ids.map { id in
            FetcherDescriptor(
                id: id,
                displayName: id,
                kind: .codexChatGpt,
                iconSystemName: "star",
                accentColor: .chatgpt,
                makeFetcher: { _ in RefreshOneStubFetcher(providerID: id) }
            )
        }
        let state = AppState(descriptors: descriptors, configStore: store)
        state.localUsage.testReadinessOverride = { _ in false }
        defer { state.stop() }

        let scheduler = state.refreshScheduler!
        // 等 prov_a（错峰 0s）首拍结算：nextRefreshDate 进入未来即已结算。
        for _ in 0..<200 where (scheduler.nextRefreshDate(for: "prov_a") ?? .distantPast) <= Date() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // 把 b/c/d 推到远期，避免 2/4/6 秒错峰首拍干扰基线（用被测方法本身做
        // setup 不影响结论：断言的是 refreshOne 不会再次改动它们）。
        let setupAnchor = Date()
        for id in ids.dropFirst() {
            scheduler.reanchorProvider(id, at: setupAnchor, resetDatesByProvider: [:])
        }
        // 为 b 登记一个 reset candidate 基线（next(b)=setup+302，reset+15=setup+135，
        // 距 next(b) 远大于 30s，candidate 一定成立）。
        scheduler.scheduleMidCycleResetRefreshes(
            for: "prov_b",
            resetsAtDates: [setupAnchor.addingTimeInterval(120)]
        )
        let baseResetsB = scheduler.resetCandidateExecutionDates(for: "prov_b")
        XCTAssertFalse(baseResetsB.isEmpty, "b 应成功登记 reset candidate 基线")
        let baseNext = Dictionary(uniqueKeysWithValues: ids.map { ($0, scheduler.nextRefreshDate(for: $0)!) })
        let baseCounts = Dictionary(uniqueKeysWithValues: ids.map { ($0, scheduler.backgroundsSinceFullCount(for: $0)) })

        let refreshOneStart = Date()
        await state.refreshOne(providerID: "prov_a")

        // A：常规时间线从 refreshOne 完成时刻重算（ ≥ 调用前 + interval），即被重锚。
        let nextA = scheduler.nextRefreshDate(for: "prov_a")
        XCTAssertNotNil(nextA)
        XCTAssertGreaterThan(
            nextA!,
            baseNext["prov_a"]!,
            "a 的常规时间线应从 refreshOne 完成时刻重算"
        )
        XCTAssertGreaterThanOrEqual(
            nextA!,
            refreshOneStart.addingTimeInterval(299),
            "a 的下一拍应落在 refreshOne 完成时刻 + interval 上"
        )
        XCTAssertEqual(
            scheduler.backgroundsSinceFullCount(for: "prov_a"),
            0,
            "a 经 .full 刷新后周期 full 计数归零"
        )
        XCTAssertFalse(
            scheduler.resetCandidateExecutionDates(for: "prov_a").isEmpty,
            "a 的 reset candidates 应按刷新后的数据重排"
        )

        // B/C/D：排期、周期 full 计数、reset candidates 全部不变。
        for id in ids.dropFirst() {
            XCTAssertEqual(
                scheduler.nextRefreshDate(for: id),
                baseNext[id],
                "\(id) 的常规排期不得被 refreshOne(prov_a) 改动"
            )
            XCTAssertEqual(
                scheduler.backgroundsSinceFullCount(for: id),
                baseCounts[id],
                "\(id) 的周期 full 计数不得被 refreshOne(prov_a) 清零"
            )
        }
        XCTAssertEqual(
            scheduler.resetCandidateExecutionDates(for: "prov_b"),
            baseResetsB,
            "b 的 reset candidates 不得被 refreshOne(prov_a) 清除"
        )
    }

    /// 单刷的**网络侧与 UI 侧**隔离：refreshOne(A) 只应给 A 的 fetcher 多发一次
    /// 请求、只应让 A 的 `lastRefreshedAt` 前移。
    ///
    /// 与 `testRefreshOneReanchorsOnlyRefreshedProvider` 的分工：那条盯的是调度
    /// 状态（next / 周期 full 计数 / reset candidates），这条盯的是"请求真的只发
    /// 给了 A"和"只有 A 的卡片变新鲜"。有一类改法（顺手 refreshAll、或把
    /// refreshProviderFully 换成遍历所有 provider）会让调度状态那条照样绿——
    /// 只有请求计数与新鲜度这两条能抓住。
    @MainActor
    func testRefreshOneOnlyFetchesAndTouchesTheTargetProvider() async {
        let ids = ["prov_a", "prov_b"]
        let store = makeIsolatedConfigStore()
        var config = store.config
        config.refreshIntervalSeconds = 300
        for id in ids {
            config.providers[id] = ProviderConfig(
                enabled: true,
                authPath: store.configURL.deletingLastPathComponent()
                    .appendingPathComponent("auth.json").path
            )
        }
        try! store.applyAndSave(config)

        let counters = FetchCallCounters()
        let descriptors: [FetcherDescriptor] = ids.map { id in
            FetcherDescriptor(
                id: id,
                displayName: id,
                kind: .codexChatGpt,
                iconSystemName: "star",
                accentColor: .chatgpt,
                makeFetcher: { _ in RefreshOneStubFetcher(providerID: id, counters: counters) }
            )
        }
        let state = AppState(descriptors: descriptors, configStore: store)
        state.localUsage.testReadinessOverride = { _ in false }
        defer { state.stop() }

        let scheduler = state.refreshScheduler!
        // 等 a（错峰 0s）首拍结算。
        for _ in 0..<200 where (scheduler.nextRefreshDate(for: "prov_a") ?? .distantPast) <= Date() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // 把 b 推到远期：b 的 2 秒错峰首拍不能混进本用例的基线。
        scheduler.reanchorProvider("prov_b", at: Date(), resetDatesByProvider: [:])

        let baseCountA = await counters.count(for: "prov_a")
        let baseCountB = await counters.count(for: "prov_b")
        let baseRefreshedA = state.statuses.first { $0.id == "prov_a" }?.lastRefreshedAt
        let baseRefreshedB = state.statuses.first { $0.id == "prov_b" }?.lastRefreshedAt
        XCTAssertEqual(baseCountA, 1, "前提不成立：a 的首拍应已完成一次 fetch")
        XCTAssertEqual(baseCountB, 0, "前提不成立：b 被推到远期，此刻不应发过请求")
        XCTAssertNotNil(baseRefreshedA, "前提不成立：a 首拍成功后 lastRefreshedAt 应有值")
        XCTAssertNil(baseRefreshedB, "前提不成立：b 没刷过就不该有新鲜度")

        await state.refreshOne(providerID: "prov_a")

        let afterCountA = await counters.count(for: "prov_a")
        let afterCountB = await counters.count(for: "prov_b")
        XCTAssertEqual(afterCountA, baseCountA + 1, "refreshOne(A) 应只给 A 多发一次请求")
        XCTAssertEqual(afterCountB, baseCountB, "refreshOne(A) 绝不能替 B 发请求")

        let refreshedA = state.statuses.first { $0.id == "prov_a" }?.lastRefreshedAt
        let refreshedB = state.statuses.first { $0.id == "prov_b" }?.lastRefreshedAt
        XCTAssertNotEqual(refreshedA, baseRefreshedA, "A 的 lastRefreshedAt 必须前移")
        XCTAssertGreaterThanOrEqual(refreshedA ?? .distantPast, baseRefreshedA ?? .distantFuture)
        XCTAssertEqual(refreshedB, baseRefreshedB, "B 的 lastRefreshedAt 不得被 refreshOne(A) 改动")
    }

    /// handleSystemWake 恢复 refreshForSystemWake 合并协议后：唤醒刷新不得重锚
    /// 其他 provider 的排期（回归 a287e8d 结尾的 reanchorAllProviders）；合并
    /// 窗口内的 provider 不重复发 full。
    @MainActor
    func testHandleSystemWakeDoesNotReanchorOtherProviders() async {
        let store = makeIsolatedConfigStore()
        var config = store.config
        config.refreshIntervalSeconds = 300
        for id in ["wake_a", "wake_b"] {
            config.providers[id] = ProviderConfig(
                enabled: true,
                authPath: store.configURL.deletingLastPathComponent()
                    .appendingPathComponent("auth.json").path
            )
        }
        try! store.applyAndSave(config)

        let descriptors: [FetcherDescriptor] = ["wake_a", "wake_b"].map { id in
            FetcherDescriptor(
                id: id,
                displayName: id,
                kind: .codexChatGpt,
                iconSystemName: "star",
                accentColor: .chatgpt,
                makeFetcher: { _ in RefreshOneStubFetcher(providerID: id) }
            )
        }
        let state = AppState(descriptors: descriptors, configStore: store)
        state.localUsage.testReadinessOverride = { _ in false }
        defer { state.stop() }

        let scheduler = state.refreshScheduler!
        // 等 wake_a（错峰 0s）首拍结算。
        for _ in 0..<200 where (scheduler.nextRefreshDate(for: "wake_a") ?? .distantPast) <= Date() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // 把 wake_b 推到远期，避免 2 秒错峰首拍干扰基线。
        scheduler.reanchorProvider("wake_b", at: Date(), resetDatesByProvider: [:])
        let baseNextA = scheduler.nextRefreshDate(for: "wake_a")!
        let baseNextB = scheduler.nextRefreshDate(for: "wake_b")!
        let baseCountB = scheduler.backgroundsSinceFullCount(for: "wake_b")

        await state.handleSystemWake()

        XCTAssertEqual(
            scheduler.nextRefreshDate(for: "wake_a"),
            baseNextA,
            "唤醒合并（活动窗口内）后 wake_a 的常规排期不变"
        )
        XCTAssertEqual(
            scheduler.nextRefreshDate(for: "wake_b"),
            baseNextB,
            "唤醒刷新不得重排其他 provider 的常规排期"
        )
        XCTAssertEqual(
            scheduler.backgroundsSinceFullCount(for: "wake_b"),
            baseCountB,
            "唤醒刷新不得清零其他 provider 的周期 full 计数"
        )
    }
}

/// refreshOne 的单 provider fetch stub：返回带未来 reset 时间的窗口数据，
/// 让 reanchor 后的 mid-cycle reset 重排有真实输入。
///
/// `counters` 非 nil 时顺带按 provider 记一次 fetch 次数（"单刷只发给了 A"那条用例用）。
private final class RefreshOneStubFetcher: QuotaFetcher, @unchecked Sendable {
    let providerID: String
    let displayName: String
    let kind = ProviderKind.codexChatGpt
    private let counters: FetchCallCounters?
    init(providerID: String, counters: FetchCallCounters? = nil) {
        self.providerID = providerID
        self.displayName = providerID
        self.counters = counters
    }
    func fetch(mode: RefreshMode) async throws -> QuotaInfo {
        await counters?.bump(providerID)
        let model = ModelQuota(
            modelName: "chatgpt_plan",
            intervalTotalCount: 100,
            intervalUsageCount: 0,
            intervalRemainingPercent: 100,
            intervalStatus: .present,
            intervalResetsAt: Date().addingTimeInterval(120),
            intervalWindowSeconds: 7 * 24 * 3600,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 0,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
        return QuotaInfo(
            models: [model],
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date()
        )
    }
    func hasLocalAuth() -> Bool { true }
}

/// 按 provider 记 fetch 次数。跨 actor 边界，所以用 actor 而不是裸 var。
private actor FetchCallCounters {
    private var counts: [String: Int] = [:]

    func bump(_ providerID: String) {
        counts[providerID, default: 0] += 1
    }

    func count(for providerID: String) -> Int {
        counts[providerID] ?? 0
    }
}
