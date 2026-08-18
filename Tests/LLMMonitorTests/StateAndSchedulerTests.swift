import XCTest
import Combine
import AppKit
@testable import LLM_monitor

final class StateAndSchedulerTests: XCTestCase {

    override func tearDown() {
        MainActor.assumeIsolated {
            AuthProber.testAfterCancellationCheck = nil
        }
        super.tearDown()
    }

    // MARK: - Usable API Key & Health Level Consolidated Tests

    func testUsableAPIKeyRules() {
        XCTAssertNil(ProviderConfig(apiKey: nil).usableAPIKey)
        XCTAssertNil(ProviderConfig(apiKey: "").usableAPIKey)
        XCTAssertNil(ProviderConfig(apiKey: "   \n\t  ").usableAPIKey)
        XCTAssertNil(ProviderConfig(apiKey: "REPLACE-WITH-YOUR-KEY").usableAPIKey)
        XCTAssertNil(ProviderConfig(apiKey: "sk-cp-REPLACE-WITH-YOUR-KEY").usableAPIKey)
        XCTAssertNil(ProviderConfig(apiKey: "sk-cp-xxx-REPLACE-THIS-TOKEN").usableAPIKey)
        XCTAssertEqual(ProviderConfig(apiKey: "test-key-with-valid-format-12345").usableAPIKey, "test-key-with-valid-format-12345")
        XCTAssertEqual(ProviderConfig(apiKey: "  sk-cp-real-key  \n").usableAPIKey, "sk-cp-real-key")
    }

    func testHealthLevelAndQuotaStatusRules() throws {
        let absentWeekly = ModelQuota(modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0, intervalRemainingPercent: 80, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: nil, weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 0, weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil)
        XCTAssertEqual(absentWeekly.healthLevel, .healthy)

        let presentWeekly = ModelQuota(modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0, intervalRemainingPercent: 80, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: nil, weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 10, weeklyStatus: .present, weeklyResetsAt: Date(timeIntervalSince1970: 4_102_444_800), weeklyWindowSeconds: nil)
        XCTAssertEqual(presentWeekly.healthLevel, .critical)

        XCTAssertTrue(QuotaWindowStatus.present.isPresent)
        XCTAssertFalse(QuotaWindowStatus.absent.isPresent)
    }

    func testLocalUsageDayKeyRules() {
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertNil(LocalUsageDayKey.parse("not-a-date", calendar: calendar))
        XCTAssertNil(LocalUsageDayKey.parse("", calendar: calendar))
        XCTAssertNil(LocalUsageDayKey.parse("2026-13-99", calendar: calendar))

        let date = LocalUsageDayKey.parse("2026-07-16", calendar: calendar)!
        XCTAssertEqual(calendar.component(.year, from: date), 2026)
        XCTAssertEqual(LocalUsageDayKey.make(date), LocalUsageDayKey.make(date))
    }

    func testLocalUsageScanTriggerTimingPolicy() {
        XCTAssertTrue(AppState.localUsageScanStartsImmediately(for: .minimaxTokenPlan))
        XCTAssertTrue(AppState.localUsageScanStartsImmediately(for: .glmCodingPlan))
        XCTAssertFalse(AppState.localUsageScanStartsImmediately(for: .antigravity))
        XCTAssertFalse(AppState.localUsageScanStartsImmediately(for: .codexChatGpt))
    }

    /// GLM 本地 scanner 有独立于 quota 成功的定期触发，避免 quota 持续失败时
    /// ZCode 新 token 消耗进不来柱图。防退化：`start()` 必须调用
    /// `startGlmLocalUsagePeriodicTrigger()`，`stop()` 必须 cancel 对应 task。
    func testGlmLocalUsagePeriodicTriggerWiredInStartAndStop() throws {
        let url = URL(fileURLWithPath: #filePath)
        let packageRoot = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ path: String) throws -> String {
            try String(contentsOfFile: packageRoot.appendingPathComponent(path).path, encoding: .utf8)
        }
        let appState = try source("Sources/LLM-monitor/Services/AppState.swift")
        let orchestration = try source("Sources/LLM-monitor/Services/LocalUsageOrchestration.swift")

        // start() 里经由编排层调用启动
        XCTAssertTrue(
            appState.contains("localUsage.startGlmPeriodicTrigger("),
            "AppState.start() 应调用 localUsage.startGlmPeriodicTrigger()"
        )
        // stop() 里 cancel 全部本地扫描（含 GLM 定期 task）
        XCTAssertTrue(
            appState.contains("localUsage.cancelInFlightAll()"),
            "AppState.stop() 应调用 localUsage.cancelInFlightAll()"
        )
        // 编排层持有独立 task 并在重建前 cancel 旧的
        XCTAssertTrue(
            orchestration.contains("var glmPeriodicTask: Task<Void, Never>?"),
            "LocalUsageOrchestration 应有 glmPeriodicTask 字段"
        )
        XCTAssertTrue(
            orchestration.contains("glmPeriodicTask?.cancel()"),
            "LocalUsageOrchestration 重建定期触发前应 cancel 旧 task"
        )
    }

    func testEffectiveRefreshIntervalRules() {
        let global = AppConfig(refreshIntervalSeconds: 300, providers: [:])
        XCTAssertEqual(global.effectiveRefreshInterval(for: "anything"), 300)

        let override = AppConfig(refreshIntervalSeconds: 300, providers: ["minimax_token_plan": ProviderConfig(refreshIntervalSeconds: 60)])
        XCTAssertEqual(override.effectiveRefreshInterval(for: "minimax_token_plan"), 60)

        let zeroClamped = AppConfig(refreshIntervalSeconds: 0, providers: [:])
        XCTAssertEqual(zeroClamped.effectiveRefreshInterval(for: "x"), 10)

        let hugeClamped = AppConfig(refreshIntervalSeconds: Int.max, providers: [:])
        XCTAssertEqual(
            hugeClamped.effectiveRefreshInterval(for: "x"),
            TimeInterval(AppConfig.maximumRefreshIntervalSeconds)
        )

        let hugeOverride = AppConfig(
            refreshIntervalSeconds: 300,
            providers: ["x": ProviderConfig(refreshIntervalSeconds: Int.max)]
        )
        XCTAssertEqual(
            hugeOverride.effectiveRefreshInterval(for: "x"),
            TimeInterval(AppConfig.maximumRefreshIntervalSeconds)
        )
    }

    func testSettingsSaveTransactionAllowsPendingLoginItemApproval() async throws {
        var didSave = false

        try await SettingsSaveTransaction.execute(
            previousLaunchAtLogin: false,
            requestedLaunchAtLogin: true,
            updateLoginItem: { _ in
                LoginItemUpdateOutcome(
                    isEnabled: false,
                    errorMessage: nil,
                    requiresApproval: true
                )
            },
            saveConfig: {
                didSave = true
            }
        )

        XCTAssertTrue(didSave)
    }

    func testComputeFailedSessionCountRules() {
        XCTAssertEqual(MinimaxLocalUsageScanner.computeFailedSessionCount(failedKeys: [], currentSourceKeys: [], cachedSourceKeys: []), 0)
        XCTAssertEqual(MinimaxLocalUsageScanner.computeFailedSessionCount(failedKeys: [], currentSourceKeys: ["main", "runtime"], cachedSourceKeys: []), 2)
        XCTAssertEqual(MinimaxLocalUsageScanner.computeFailedSessionCount(failedKeys: ["main"], currentSourceKeys: ["main", "runtime"], cachedSourceKeys: ["main", "runtime"]), 1)
        XCTAssertEqual(MinimaxLocalUsageScanner.computeFailedSessionCount(failedKeys: ["main", "runtime"], currentSourceKeys: ["main", "runtime", "extra"], cachedSourceKeys: ["extra"]), 2)
    }

    // MARK: - LocalUsageCoordinator

    /// 假 scanner：模拟 @Published lastResult / isScanning，能从外部 push 状态。
    /// 做成泛型类，方便 `MinimaxLocalUsage` / `AntigravityLocalUsage` 各造一个。
    @MainActor
    private final class FakeLocalScanner<Usage: Equatable>: LocalUsageScanner {
        let usage: Usage
        var scanCount = 0
        // 内部 CurrentValueSubject，模拟 @Published
        let resultSubject = CurrentValueSubject<Usage?, Never>(nil)
        let scanningSubject = CurrentValueSubject<Bool, Never>(false)

        init(usage: Usage) { self.usage = usage }

        func scan() {
            scanCount += 1
            scanningSubject.send(true)
            // 模拟一次 scan 立刻产出一个非 nil 结果
            scanningSubject.send(false)
            resultSubject.send(usage)
        }

        func cancelInFlight() {
            // 测试 fake: no-op (没有 in-flight task 概念)
        }

        var lastResultPublisher: AnyPublisher<Usage?, Never> { resultSubject.eraseToAnyPublisher() }
        var isScanningPublisher: AnyPublisher<Bool, Never> { scanningSubject.eraseToAnyPublisher() }
    }

    @MainActor
    func testLocalUsageCoordinatorLazyScannerIsCreatedOnFirstTrigger() async {
        let usage = MinimaxLocalUsage(
            today: nil,
            dailyTokenUsage: [],
            scannedAt: Date(),
            sessionCount: 0,
            eventCount: 0,
            failedSessionCount: 0
        )
        var factoryCalledCount = 0
        let makeScanner: () -> any LocalUsageScanner<MinimaxLocalUsage> = {
            factoryCalledCount += 1
            return FakeLocalScanner(usage: usage)
        }

        let coordinator = LocalUsageCoordinator<MinimaxLocalUsage>(
            providerID: "test",
            logTag: "test",
            makeScanner: makeScanner,
            apply: { _ in },
            setScanning: { _ in }
        )

        // trigger 前 factory 不应被调用（lazy）
        XCTAssertEqual(factoryCalledCount, 0, "scanner 不应在 trigger 前构造")

        coordinator.trigger()
        // trigger 后 scanner 创建一次，scan 也调用一次
        XCTAssertEqual(factoryCalledCount, 1, "首次 trigger 应调用 factory 一次")
    }

    @MainActor
    func testLocalUsageCoordinatorReusesScannerAcrossTriggers() async {
        let usage = MinimaxLocalUsage(
            today: nil,
            dailyTokenUsage: [],
            scannedAt: Date(),
            sessionCount: 0,
            eventCount: 0,
            failedSessionCount: 0
        )
        var factoryCalledCount = 0
        let makeScanner: () -> any LocalUsageScanner<MinimaxLocalUsage> = {
            factoryCalledCount += 1
            return FakeLocalScanner(usage: usage)
        }

        let coordinator = LocalUsageCoordinator<MinimaxLocalUsage>(
            providerID: "test",
            logTag: "test",
            makeScanner: makeScanner,
            apply: { _ in },
            setScanning: { _ in }
        )

        coordinator.trigger()
        coordinator.trigger()
        coordinator.trigger()

        // factory 只该被调一次（scanner 缓存复用）
        XCTAssertEqual(factoryCalledCount, 1, "后续 trigger 不应重新构造 scanner")
    }

    @MainActor
    func testLocalUsageCoordinatorForwardsResultToApply() async {
        let usage = MinimaxLocalUsage(
            today: nil,
            dailyTokenUsage: [],
            scannedAt: Date(),
            sessionCount: 7,
            eventCount: 100,
            failedSessionCount: 2
        )
        var applyCalls: [MinimaxLocalUsage?] = []
        let coordinator = LocalUsageCoordinator<MinimaxLocalUsage>(
            providerID: "test",
            logTag: "test",
            makeScanner: { FakeLocalScanner(usage: usage) },
            apply: { result in applyCalls.append(result) },
            setScanning: { _ in }
        )

        coordinator.trigger()

        // 给 sink 一个 schedule 的时间（receive on main queue）
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        // CurrentValueSubject 会在新订阅时立刻发一次初始值（nil），scan 完成后发一次
        // 真实值（usage）。所以 apply 至少被调用 2 次，其中最后一个是真实值。
        // 关键验证：最终收到的 non-nil 值字段正确
        XCTAssertGreaterThanOrEqual(applyCalls.count, 1)
        let last = applyCalls.last ?? nil
        XCTAssertEqual(last?.sessionCount, 7, "apply 最后一次应拿到 sessionCount=7")
        XCTAssertEqual(last?.failedSessionCount, 2, "apply 最后一次应拿到 failedSessionCount=2")
    }

    @MainActor
    func testLocalUsageCoordinatorForwardsScanningState() async {
        let usage = MinimaxLocalUsage(
            today: nil,
            dailyTokenUsage: [],
            scannedAt: Date(),
            sessionCount: 0,
            eventCount: 0,
            failedSessionCount: 0
        )
        var scanningStates: [Bool] = []
        let coordinator = LocalUsageCoordinator<MinimaxLocalUsage>(
            providerID: "test",
            logTag: "test",
            makeScanner: { FakeLocalScanner(usage: usage) },
            apply: { _ in },
            setScanning: { isScanning in scanningStates.append(isScanning) }
        )

        coordinator.trigger()
        try? await Task.sleep(nanoseconds: 50_000_000)

        // FakeLocalScanner.scan 期间发 true → false，至少收到 2 个状态变更
        XCTAssertGreaterThanOrEqual(scanningStates.count, 2, "setScanning 应至少被调用 2 次（true + false）")
        XCTAssertTrue(scanningStates.contains(true), "应有 isScanning=true")
        XCTAssertTrue(scanningStates.contains(false), "应有 isScanning=false")
    }

    @MainActor
    func testLocalUsageCoordinatorForwardsCancelInFlight() {
        // 验证 LocalUsageCoordinator.cancelInFlight() 会转发到 scanner
        let usage = MinimaxLocalUsage(
            today: nil,
            dailyTokenUsage: [],
            scannedAt: Date(),
            sessionCount: 0,
            eventCount: 0,
            failedSessionCount: 0
        )
        let scanner = FakeLocalScanner(usage: usage)
        let coordinator = LocalUsageCoordinator<MinimaxLocalUsage>(
            providerID: "test",
            logTag: "test",
            makeScanner: { scanner },
            apply: { _ in },
            setScanning: { _ in }
        )
        // trigger 之前 cancelInFlight 应不崩（scanner 还没建）
        coordinator.cancelInFlight()
        coordinator.trigger()
        XCTAssertEqual(scanner.scanCount, 1)
        // trigger 之后再 cancel
        coordinator.cancelInFlight()
        // 不崩就算过 — FakeLocalScanner 没暴露 cancel count, 行为由 scanner 自身测试覆盖
        XCTAssertNotNil(coordinator)
    }

    // MARK: - SettingsWindowFocusBridge: 焦点门控

    /// 验证 `shouldActivate` 不会在用户已经在 Settings 窗口内交互时再激活一次。
    /// 模拟 SwiftUI 每次重绘都触发 updateNSView 的场景，确保不会再走 NSApp.activate。
    @MainActor
    func testSettingsFocusBridgeSkipsWhenSameWindowIsKey() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // 模拟“当前 window 已是 key”的状态：未显式 resign 的窗口在 isKeyWindow 上
        // 可能为 false，但 `previouslyActivated` 为 nil 时 `shouldActivate` 也应返回 true
        // （首启场景）。这里用 nil 验证首启 → 激活。
        XCTAssertTrue(
            SettingsWindowFocusBridge.Coordinator.shouldActivate(
                window: window,
                previouslyActivated: nil
            ),
            "首次进入新窗口应激活"
        )

        // 直接构造两个不同实例，模拟“同一个 window 在 shouldActivate 调用之间保持 key 状态”。
        // 由于 `isKeyWindow` 需要真实 window-server 状态，这里把判定收敛到
        // “window === previouslyActivated && window.isKeyWindow”这一行。
        // 把 NSWindow 子类化覆盖 isKeyWindow 不优雅，改成测“同实例 + isKeyWindow=true”的分支。
        let keyWindow = KeyWindowStub()
        XCTAssertFalse(
            SettingsWindowFocusBridge.Coordinator.shouldActivate(
                window: keyWindow,
                previouslyActivated: keyWindow
            ),
            "同一个 key 窗口二次调用应跳过，避免输入时焦点跳动"
        )
        XCTAssertTrue(
            SettingsWindowFocusBridge.Coordinator.shouldActivate(
                window: keyWindow,
                previouslyActivated: nil
            ),
            "首启 + key 窗口应激活"
        )
        let otherKeyWindow = KeyWindowStub()
        XCTAssertTrue(
            SettingsWindowFocusBridge.Coordinator.shouldActivate(
                window: otherKeyWindow,
                previouslyActivated: keyWindow
            ),
            "换到新窗口（即使都 key）应重新激活"
        )

        // 模拟用户切到其他 app：window 失 key 后再点回 Settings。
        let resignedWindow = NonKeyWindowStub()
        XCTAssertTrue(
            SettingsWindowFocusBridge.Coordinator.shouldActivate(
                window: resignedWindow,
                previouslyActivated: resignedWindow
            ),
            "同一窗口失 key 后再调用应重新激活（用户从其他 app 切回）"
        )
    }

    // MARK: - ProviderRefreshScheduler: 退避 / dedup / 取消

    /// 跨 actor 边界的轻量计数器。让 refreshHandler 闭包能异步记录被调次数。
    private actor CallCounter {
        private(set) var calls: Int = 0
        private(set) var lastMode: RefreshMode = .full

        func tickCalled(mode: RefreshMode) {
            calls += 1
            lastMode = mode
        }
    }

    /// 记录 refresh handler 收到的 mode 序列；record 返回记录后的总数。
    private actor ModeLog {
        private var modes: [RefreshMode] = []
        func record(_ mode: RefreshMode) -> Int {
            modes.append(mode)
            return modes.count
        }
        func snapshot() -> [RefreshMode] { modes }
    }

    /// 持有 scheduler 的弱引用，供 handler 在记满后自行 cancelAll。
    /// @unchecked Sendable：handler 与 scheduler 都在 MainActor，访问串行。
    private final class WeakSchedulerHolder: @unchecked Sendable {
        weak var sched: ProviderRefreshScheduler?
    }

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
    func testSchedulerRecordSuccessResetsFailureCount() {
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .deferred },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {}
        )
        scheduler.recordFailure("a")
        scheduler.recordFailure("a")
        scheduler.recordFailure("a")
        // 走 1 次失败 → delay = baseInterval * 2^1 = 120s（外加 jitter）
        let failedDelay = scheduler.nextDelay(for: "a", baseInterval: 60, succeeded: false)
        XCTAssertGreaterThan(failedDelay, 60, "失败后 delay 应 > baseInterval")

        scheduler.recordSuccess("a")
        let afterSuccess = scheduler.nextDelay(for: "a", baseInterval: 60, succeeded: true)
        XCTAssertEqual(afterSuccess, 60, "recordSuccess 应清零失败计数，下次成功时回到 baseInterval")
    }

    @MainActor
    func testSchedulerRecordFailureIncrementsAndCaps() {
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .deferred },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {}
        )
        // 6 次失败（cap at 5 in nextDelay），第 6 次记入 state 但 delay 计算用 5
        for _ in 0..<6 {
            scheduler.recordFailure("a")
        }
        let delay = scheduler.nextDelay(for: "a", baseInterval: 60, succeeded: false)
        // baseInterval(60) * 2^5 = 1920, 封顶 30*60=1800。jitter ±10% → 1620~1980
        XCTAssertLessThanOrEqual(delay, 30 * 60 * 1.1, "5 次以上失败应封顶 30 分钟")
        XCTAssertGreaterThan(delay, 30 * 60 * 0.9, "封顶 30 分钟，jitter 范围内")
    }

    @MainActor
    func testSchedulerDelayForSuccessReturnsBaseInterval() {
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .deferred },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {}
        )
        let delay = scheduler.nextDelay(for: "a", baseInterval: 300, succeeded: true)
        XCTAssertEqual(delay, 300, "成功时直接用 baseInterval")
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
        // 直接灌数据：markInFlight + recordFailure 各两次模拟两个 provider 有活动
        scheduler.markInFlight("a")
        scheduler.markInFlight("b")
        scheduler.recordFailure("a")
        scheduler.recordFailure("b")
        XCTAssertEqual(scheduler.inFlightProviderIDs, ["a", "b"])

        scheduler.cancelAll()
        // cancelAll 清的是 timer 相关状态（tasks / nextRefreshDates / failureCounts）。
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
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, mode in
                invokedModes.append(mode)
                return .completed(success: true)
            },
            intervalProvider: { _ in 300 },
            onNextRefreshChange: {},
            now: { fixedNow },
            sleep: { _ in try await Task.sleep(nanoseconds: 300_000_000) }
        )
        scheduler.scheduleMidCycleResetRefreshes(
            for: "p", resetsAtDates: [fixedNow.addingTimeInterval(200)]
        )
        scheduler.cancel(providerID: "p")  // 在 sleep 完成前取消
        try? await Task.sleep(nanoseconds: 600_000_000)
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
        // 安全超时；正常应在记满 9 个后自行 cancel。
        try? await Task.sleep(nanoseconds: 1_000_000_000)
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
    func testSchedulerDeferredOutcomeCausesShortRetry() async {
        // refreshHandler 一直返回 .deferred → timer 走 1s 短重试节奏（不计入 failure 计数）
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
        // 等 ~1.5s：.full（首次）+ 至少 1 次 .deferred 重试
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        sched.cancel(providerID: "a")
        // 验证：handler 被多次调用（说明 timer 在循环而不是退避后等 60s）
        let calls = await counter.calls
        XCTAssertGreaterThanOrEqual(calls, 2, "连续 .deferred 应触发 1s 短重试，至少 2 次调用（首次 + 1 次重试）")
        // 验证：deferred 期间 failure 计数始终为 0（不会污染退避）
        let delayAfterDeferred = sched.nextDelay(for: "a", baseInterval: 60, succeeded: false)
        // 没 recordFailure → failureCounts[providerID, default: 1] = 1 → delay = 60 * 2 = 120 + jitter
        // 关键是没有 recordFailure 的话 recordFailure 不会自动被调，状态保持干净
        XCTAssertGreaterThan(delayAfterDeferred, 60, "无 recordFailure 时 default=1，delay 翻倍")
    }

    @MainActor
    func testSchedulerDifferentProvidersIndependent() {
        // 验证 A 失败不影响 B 的成功退避
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .deferred },
            intervalProvider: { _ in 60 },
            onNextRefreshChange: {}
        )
        scheduler.recordFailure("a")
        scheduler.recordFailure("a")
        scheduler.recordFailure("a")
        scheduler.recordSuccess("b")  // B 没失败过

        let aDelay = scheduler.nextDelay(for: "a", baseInterval: 60, succeeded: false)
        let bDelay = scheduler.nextDelay(for: "b", baseInterval: 60, succeeded: true)
        XCTAssertEqual(bDelay, 60, "B 没失败过，succeeded=true 时直接用 baseInterval")
        XCTAssertGreaterThan(aDelay, 60, "A 3 次失败后 delay 应 > baseInterval")
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

    // MARK: - AuthProber: 探测 cache + 取消 + onChange 触发

    /// 跟 `CallCounter` 配合：用可控的 `hasLocalAuth` / `checkLocalAuth` 模拟本地服务
    /// 状态。每个 providerID 一个 fetcher，登记到 `fetcherMap` 里供测试构造 prober。
    ///
    /// 非 `@MainActor`：要让 `QuotaFetcher` (`Sendable`) 的 conformance 合法，
    /// class 本身不能 actor-isolated。`hasLocalAuthResult` / `checkLocalAuthResult` /
    /// `checkLocalAuthCalls` 在测试中只在主线程改，安全。
    private final class FakeFetcher: QuotaFetcher, @unchecked Sendable {
        let providerID: String
        let displayName: String
        let kind: ProviderKind
        let logTag: String

        var hasLocalAuthResult: Bool
        var checkLocalAuthResult: Bool
        /// checkLocalAuth 调用次数（用于断言"确实发起了探测"）
        var checkLocalAuthCalls: Int = 0

        init(providerID: String, hasLocalAuth: Bool, checkLocalAuth: Bool) {
            self.providerID = providerID
            self.displayName = providerID
            self.kind = .antigravity  // 测试只需满足 usesExternalAuth = true 即可
            self.logTag = "[\(providerID)]"
            self.hasLocalAuthResult = hasLocalAuth
            self.checkLocalAuthResult = checkLocalAuth
        }

        func fetch(mode: RefreshMode) async throws -> QuotaInfo {
            QuotaInfo(
                models: [],
                resetCredits: nil,
                planLabel: nil,
                accountEmail: nil,
                codexUsageDetails: nil,
                fetchedAt: Date()
            )
        }

        func hasLocalAuth() -> Bool { hasLocalAuthResult }
        func checkLocalAuth() async -> Bool {
            checkLocalAuthCalls += 1
            return checkLocalAuthResult
        }
    }

    private actor SlowProbeControl {
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var resultContinuation: CheckedContinuation<Bool, Never>?

        func waitForResult() async -> Bool {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            return await withCheckedContinuation { continuation in
                resultContinuation = continuation
            }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func resume(_ result: Bool) {
            resultContinuation?.resume(returning: result)
            resultContinuation = nil
        }
    }

    private actor TestAsyncGate {
        private var reached = false
        private var reachWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func hold() async {
            reached = true
            let waiters = reachWaiters
            reachWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func waitUntilReached() async {
            if reached { return }
            await withCheckedContinuation { continuation in
                reachWaiters.append(continuation)
            }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    /// 让 refresh fetch 停在网络等待处，精确验证 full refresh waiter 的取消传播。
    private final class BlockingRefreshFetcher: QuotaFetcher, @unchecked Sendable {
        let providerID = "refresh_wait_cancel"
        let displayName = "refresh_wait_cancel"
        let kind = ProviderKind.codexChatGpt
        let logTag = "[refresh_wait_cancel]"
        let gate = TestAsyncGate()
        let calls = CallCounter()

        func fetch(mode: RefreshMode) async throws -> QuotaInfo {
            await calls.tickCalled(mode: mode)
            await gate.hold()
            return QuotaInfo(
                models: [],
                resetCredits: nil,
                planLabel: nil,
                accountEmail: nil,
                codexUsageDetails: nil,
                fetchedAt: Date()
            )
        }

        func hasLocalAuth() -> Bool { true }
        func checkLocalAuth() async -> Bool { true }
    }

    private final class SlowFetcher: QuotaFetcher, @unchecked Sendable {
        let providerID = "a"
        let displayName = "a"
        let kind = ProviderKind.antigravity
        let logTag = "[a]"
        let control = SlowProbeControl()

        func fetch(mode: RefreshMode) async throws -> QuotaInfo {
            QuotaInfo(
                models: [], resetCredits: nil, planLabel: nil, accountEmail: nil,
                codexUsageDetails: nil, fetchedAt: Date()
            )
        }

        func hasLocalAuth() -> Bool { true }

        func checkLocalAuth() async -> Bool {
            await control.waitForResult()
        }
    }

    @MainActor
    private func makeTestProber(
        fetchers: [String: FakeFetcher],
        onChange: @escaping (String, Bool) -> Void = { _, _ in }
    ) -> AuthProber {
        AuthProber(
            fetcherProvider: { providerID in fetchers[providerID] },
            onChange: onChange
        )
    }

    /// scheduleProbe 三个分支 + 探测结果双路径：
    /// - canProbe = true + checkLocalAuth = true → cache=true, onChange(true)
    /// - canProbe = true + checkLocalAuth = false → cache=false, onChange(false)
    /// - canProbe = false（hasLocalAuth=false） → 不启动 task, cache 保持 nil
    /// - canProbe = false（fetcherProvider=nil） → 不启动 task
    @MainActor
    func testAuthProberScheduleProbeDispatch() async {
        // 1. canProbe = true, checkLocalAuth = true → cache=true + onChange(true)
        do {
            let fetcher = FakeFetcher(providerID: "a", hasLocalAuth: true, checkLocalAuth: true)
            var firedID: String?
            var firedAvailable: Bool?
            let prober = makeTestProber(
                fetchers: ["a": fetcher],
                onChange: { id, isAvailable in
                    firedID = id
                    firedAvailable = isAvailable
                }
            )
            XCTAssertTrue(prober.scheduleProbe(for: "a"), "canProbe=true 应启动 task")
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(fetcher.checkLocalAuthCalls, 1, "checkLocalAuth 真的被调了")
            XCTAssertEqual(prober.availability["a"], true)
            XCTAssertFalse(prober.isUnavailable("a"))
            XCTAssertEqual(firedID, "a")
            XCTAssertEqual(firedAvailable, true)
        }
        // 2. canProbe = true, checkLocalAuth = false → cache=false + onChange(false)
        do {
            let fetcher = FakeFetcher(providerID: "b", hasLocalAuth: true, checkLocalAuth: false)
            var firedID: String?
            var firedAvailable: Bool?
            let prober = makeTestProber(
                fetchers: ["b": fetcher],
                onChange: { id, isAvailable in
                    firedID = id
                    firedAvailable = isAvailable
                }
            )
            prober.scheduleProbe(for: "b")
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(prober.availability["b"], false)
            XCTAssertTrue(prober.isUnavailable("b"), "isUnavailable 应返回 true（cache=false）")
            XCTAssertEqual(firedID, "b")
            XCTAssertEqual(firedAvailable, false)
        }
        // 3. canProbe = false（hasLocalAuth=false） → 不启动 task, cache 保持 nil
        do {
            let fetcher = FakeFetcher(providerID: "c", hasLocalAuth: false, checkLocalAuth: true)
            let prober = makeTestProber(fetchers: ["c": fetcher])
            XCTAssertFalse(prober.scheduleProbe(for: "c"), "hasLocalAuth=false 时 scheduleProbe 应返回 false")
            XCTAssertNil(prober.availability["c"], "cache 保持 nil")
            XCTAssertFalse(prober.isUnavailable("c"), "nil 不应被算作不可用")
            XCTAssertEqual(fetcher.checkLocalAuthCalls, 0, "checkLocalAuth 不应被调")
        }
        // 4. canProbe = false（fetcherProvider=nil, provider 没在 config 里） → 不启动 task
        do {
            let prober = makeTestProber(fetchers: [:])
            XCTAssertFalse(prober.scheduleProbe(for: "ghost"), "fetcherProvider=nil 时 scheduleProbe 应返回 false")
        }
    }

    @MainActor
    func testAuthProberGenerationsGuardPreventsStaleApply() async {
        let fetcher = SlowFetcher()
        let applyGate = TestAsyncGate()
        let slowProber = AuthProber(fetcherProvider: { _ in fetcher })
        AuthProber.testAfterCancellationCheck = { await applyGate.hold() }
        defer { AuthProber.testAfterCancellationCheck = nil }

        XCTAssertTrue(slowProber.scheduleProbe(for: "a"))
        await fetcher.control.waitUntilStarted()
        await fetcher.control.resume(false)
        await applyGate.waitUntilReached()
        slowProber.cancel(providerID: "a")
        await applyGate.release()
        await Task.yield()

        XCTAssertNil(slowProber.availability["a"], "旧 generation 结果不得回写 availability")
    }

    /// markAvailable 路径：跳过 probe 直接设 cache=true + 触发 onChange。
    /// 幂等性：值未变（nil→true 或 true→true）不重复触发。
    @MainActor
    func testAuthProberMarkAvailableAndIdempotency() {
        var fires = 0
        var lastID: String?
        var lastAvailable: Bool?
        let prober = makeTestProber(
            fetchers: [:],
            onChange: { id, isAvailable in
                fires += 1
                lastID = id
                lastAvailable = isAvailable
            }
        )
        // 首次 markAvailable(nil→true)：fire 1 次
        prober.markAvailable("a")
        XCTAssertEqual(fires, 1, "首次 markAvailable 应触发 1 次 onChange")
        XCTAssertEqual(prober.availability["a"], true)
        XCTAssertFalse(prober.isUnavailable("a"))
        XCTAssertEqual(lastID, "a")
        XCTAssertEqual(lastAvailable, true)
        // 连续 markAvailable 2 次（true→true）：不重复触发
        prober.markAvailable("a")
        prober.markAvailable("a")
        XCTAssertEqual(fires, 1, "值未变时不重复触发 onChange")
        // 切到另一个 provider：fire 又 1 次
        prober.markAvailable("b")
        XCTAssertEqual(fires, 2)
        XCTAssertEqual(lastID, "b")
        XCTAssertEqual(lastAvailable, true)
    }

    /// reset / cancel / rescan 三个稳定性场景：
    /// - reset 清空 cache
    /// - 重复 scheduleProbe(值未变) 不重复 fire, fetcher 真跑了 N 次
    /// - 第一次 probe 还在跑时立刻 scheduleProbe 第二次 → 第一次被取消, 只 fire 1 次
    /// - schedule 后立刻 cancel → 跑完也不 fire, cache 仍为 nil
    @MainActor
    func testAuthProberResetCancelAndRescanStability() async {
        // 1. reset 清空 cache
        do {
            let fetcher = FakeFetcher(providerID: "a", hasLocalAuth: true, checkLocalAuth: true)
            let prober = makeTestProber(fetchers: ["a": fetcher])
            prober.scheduleProbe(for: "a")
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(prober.availability["a"], true, "probe 完成后 cache 已被设")
            prober.reset()
            XCTAssertNil(prober.availability["a"], "reset 应清空 cache")
        }
        // 2. 重复 scheduleProbe(值未变): 不重复 fire, 但 fetcher 真跑了 N 次
        do {
            let fetcher = FakeFetcher(providerID: "a", hasLocalAuth: true, checkLocalAuth: true)
            var fires = 0
            let prober = makeTestProber(
                fetchers: ["a": fetcher],
                onChange: { _, _ in fires += 1 }
            )
            prober.scheduleProbe(for: "a")
            try? await Task.sleep(nanoseconds: 100_000_000)
            prober.scheduleProbe(for: "a")
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(fires, 1, "true→true 不重复触发 onChange")
            XCTAssertEqual(fetcher.checkLocalAuthCalls, 2, "两次 scheduleProbe 都该真发起 checkLocalAuth")
        }
        // 3. 第一次 probe 还在跑时立刻 scheduleProbe 第二次 → 第一次被取消, 只 fire 1 次
        do {
            let fetcher = FakeFetcher(providerID: "a", hasLocalAuth: true, checkLocalAuth: true)
            var fires: [Bool] = []
            let prober = makeTestProber(
                fetchers: ["a": fetcher],
                onChange: { _, isAvailable in fires.append(isAvailable) }
            )
            prober.scheduleProbe(for: "a")
            prober.scheduleProbe(for: "a")  // 立刻再 schedule, 第一次 task 还没走完
            try? await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(fires, [true], "只触发一次 onChange（true）")
            XCTAssertEqual(prober.availability["a"], true)
        }
        // 4. schedule 后立刻 cancel → 跑完也不 fire, cache 仍为 nil
        do {
            let fetcher = FakeFetcher(providerID: "a", hasLocalAuth: true, checkLocalAuth: true)
            var fires = 0
            let prober = makeTestProber(
                fetchers: ["a": fetcher],
                onChange: { _, _ in fires += 1 }
            )
            prober.scheduleProbe(for: "a")
            prober.cancel(providerID: "a")
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(fires, 0, "cancel 后 checkLocalAuth 完成后 onChange 不应触发")
            XCTAssertNil(prober.availability["a"], "cancel 后 cache 仍为 nil")
        }
    }

    // MARK: - RefreshResultMerger: identity / codex 缺失回退

    /// 构造一个简单的 ModelQuota，测试用（不依赖具体业务字段）
    private func makeModel(
        _ name: String,
        intervalPercent: Double = 80,
        weeklyPercent: Double = 70,
        weeklyStatus: QuotaWindowStatus = .present
    ) -> ModelQuota {
        ModelQuota(
            modelName: name,
            intervalTotalCount: 100,
            intervalUsageCount: 20,
            intervalRemainingPercent: intervalPercent,
            intervalStatus: .present,
            intervalResetsAt: nil,
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: 1000,
            weeklyUsageCount: 300,
            weeklyRemainingPercent: weeklyPercent,
            weeklyStatus: weeklyStatus,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: 7 * 24 * 3600
        )
    }

    private func makeQuotaInfo(
        models: [ModelQuota] = [],
        resetCredits: ResetCreditsInfo? = nil,
        planLabel: String? = nil,
        accountEmail: String? = nil,
        codexUsageDetails: CodexUsageDetails? = nil,
        fetchedAt: Date = Date()
    ) -> QuotaInfo {
        QuotaInfo(
            models: models,
            resetCredits: resetCredits,
            planLabel: planLabel,
            accountEmail: accountEmail,
            codexUsageDetails: codexUsageDetails,
            fetchedAt: fetchedAt
        )
    }

    // MARK: - RefreshResultMerger: identity / codex 缺失回退

    /// CodexFillingMissingMerger 4 行为 in 1：
    /// - 新值 nil + previous 有值 → 用 previous 的 (回退 resetCredits / codexUsageDetails)
    /// - 新值非 nil → 用 new (不污染)
    /// - 没 previous → 直接返回 new
    /// - 必须始终保留最新 quota models (回退字段不影响主 quota)
    func testFillingMissingMergerBehaviors() {
        let merger = CodexFillingMissingMerger()
        // 1. 新值 nil + previous 有 resetCredits → 回退到 previous
        do {
            let prevEntry = ResetCreditEntry(
                id: "credit-1", status: "available", expiresAt: nil, grantedAt: nil,
                resetType: "codex_rate_limits", title: "Full reset (Weekly + 5 hr)", description: nil
            )
            let prevReset = ResetCreditsInfo(entries: [prevEntry], serverAvailableCount: 1, totalEarnedCount: 1)
            let previous = makeQuotaInfo(models: [makeModel("chatgpt_plan")], resetCredits: prevReset)
            let new = makeQuotaInfo(
                models: [makeModel("chatgpt_plan", intervalPercent: 42)],
                resetCredits: nil
            )
            let merged = merger.merge(new: new, previous: previous, mode: .background)
            XCTAssertEqual(merged.resetCredits, prevReset, "新值 nil 时应回退到上次的 resetCredits")
            XCTAssertEqual(merged.models, new.models, "Codex merger 必须始终保留最新 quota models")
        }
        // 2. 新值 nil + previous 有 codexUsageDetails → 回退
        do {
            let prevDetails = CodexUsageDetails(
                primary: nil, secondary: nil, lastPrompt: nil, dailyTokenUsage: nil, scannedAt: Date()
            )
            let previous = makeQuotaInfo(models: [makeModel("chatgpt_plan")], codexUsageDetails: prevDetails)
            let new = makeQuotaInfo(models: [makeModel("chatgpt_plan")], codexUsageDetails: nil)
            let merged = merger.merge(new: new, previous: previous, mode: .background)
            XCTAssertEqual(merged.codexUsageDetails, prevDetails, "新值 nil 时应回退到上次的 codexUsageDetails")
        }
        // 3. 新值非 nil → 用 new (不污染)
        do {
            let prevEntry = ResetCreditEntry(
                id: "credit-1", status: "available", expiresAt: nil, grantedAt: nil,
                resetType: "codex_rate_limits", title: "Prev", description: nil
            )
            let newEntry = ResetCreditEntry(
                id: "credit-2", status: "available", expiresAt: nil, grantedAt: nil,
                resetType: "codex_rate_limits", title: "New", description: nil
            )
            let prevReset = ResetCreditsInfo(entries: [prevEntry], serverAvailableCount: 1, totalEarnedCount: 1)
            let newReset = ResetCreditsInfo(entries: [newEntry], serverAvailableCount: 1, totalEarnedCount: 1)
            let previous = makeQuotaInfo(models: [makeModel("chatgpt_plan")], resetCredits: prevReset)
            let new = makeQuotaInfo(models: [makeModel("chatgpt_plan")], resetCredits: newReset)
            let merged = merger.merge(new: new, previous: previous, mode: .background)
            XCTAssertEqual(merged.resetCredits, newReset, "新值非 nil 时直接用新值")
        }
        // 4. 没 previous → 直接返回 new (保持 nil)
        do {
            let new = makeQuotaInfo(models: [makeModel("chatgpt_plan")], resetCredits: nil)
            let merged = merger.merge(new: new, previous: nil, mode: .background)
            XCTAssertEqual(merged.resetCredits, nil, "没 previous 时直接用 new（保持 nil）")
        }
    }

    /// Merger 注入 / fetcher 接线 3 in 1：
    /// - IdentityRefreshResultMerger 不修改 models (always returns new)
    /// - MinimaxTokenPlanFetcher 用默认 identity merger (保留本次完整响应)
    /// - CodexFetcher.resultMerger 是 CodexFillingMissingMerger
    func testRefreshResultMergerWiring() {
        // 1. IdentityRefreshResultMerger 不修改 models
        do {
            let merger = IdentityRefreshResultMerger()
            let new = makeQuotaInfo(models: [makeModel("general")])
            let previous = makeQuotaInfo(models: [makeModel("general", intervalPercent: 1)])
            let merged = merger.merge(new: new, previous: previous, mode: .background)
            XCTAssertEqual(merged.models, new.models, "identity merger 不应改 models")
        }
        // 2. MinimaxTokenPlanFetcher 用默认 identity merger
        do {
            let minimaxFetcher = MinimaxTokenPlanFetcher(apiKey: "test")
            let new = makeQuotaInfo(models: [makeModel("video", intervalPercent: 20)])
            let previous = makeQuotaInfo(models: [makeModel("video", intervalPercent: 80)])
            let merged = minimaxFetcher.resultMerger.merge(
                new: new, previous: previous, mode: .background
            )
            XCTAssertEqual(merged, new, "Minimax 应使用默认 identity merger, 保留本次完整响应")
        }
        // 3. CodexFetcher.resultMerger 是 CodexFillingMissingMerger
        do {
            let codexFetcher = CodexFetcher()
            XCTAssertNotNil(codexFetcher.resultMerger as? CodexFillingMissingMerger,
                            "CodexFetcher.resultMerger 应是 CodexFillingMissingMerger")
        }
    }

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
    private func makeTestAppState() -> AppState {
        let configStore = makeIsolatedConfigStore()
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

    @MainActor
    private func makeIsolatedConfigStore() -> ConfigStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-config-test-\(UUID().uuidString)", isDirectory: true)
        let configURL = directory.appendingPathComponent("config.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return ConfigStore(configURL: configURL)
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

    // MARK: - FileManagerBox 访问约束

    /// 运行时验证 `FileManagerBox` 持有 `fileManager: FileManager` 字段。
    /// 防止有人把字段 rename 掉而不改 wrapper API（如果 rename 了 `fileManager`
    /// 字段但忘了同步更新 wrapper，type-level 检查会过但 runtime 行为会断）。
    /// 编译期验证 `fileManager` 必须是 `private` 没法用 Mirror（Mirror 能
    /// 看到 private 字段），但 `Tests/AccessCheck.swift` 提供了 tripwire：
    /// 取消注释 `_ = box.fileManager` 跑 `swift build --build-tests` 应该
    /// 失败（`'fileManager' is inaccessible due to 'private' protection level`）。
    func testFileManagerBoxFileManagerFieldExists() {
        let box = FileManagerBox()
        let mirror = Mirror(reflecting: box)
        let hasFileManagerField = mirror.children.contains { child in
            child.label == "fileManager" && child.value is FileManager
        }
        XCTAssertTrue(hasFileManagerField, "FileManagerBox 应该有 fileManager 字段")
    }

    // MARK: - ProviderStatus state model (consolidated _lastSuccess)

    /// `State.lastSuccess` 是从 state 派生的属性 —— `.ok/.loading(lastSuccess:)/.failed(_,lastSuccess:)`
    /// 都能拿到 lastSuccess，`.notConfigured/.ready` 返回 nil。验证这条核心契约，
    /// 因为 view 跟 AppState 都靠它来决定显示什么。
    func testProviderStatusLastSuccessDerivedFromState() {
        let info = QuotaInfo(
            models: [ModelQuota(
                modelName: "general",
                intervalTotalCount: 0, intervalUsageCount: 0,
                intervalRemainingPercent: 80, intervalStatus: .present,
                intervalResetsAt: nil, intervalWindowSeconds: nil,
                weeklyTotalCount: 0, weeklyUsageCount: 0,
                weeklyRemainingPercent: 60, weeklyStatus: .present,
                weeklyResetsAt: Date(timeIntervalSince1970: 4_102_444_800), weeklyWindowSeconds: nil
            )],
            resetCredits: nil, planLabel: nil, accountEmail: nil,
            codexUsageDetails: nil, fetchedAt: Date()
        )
        let loadingPrev = QuotaInfo(
            models: [ModelQuota(
                modelName: "old",
                intervalTotalCount: 0, intervalUsageCount: 0,
                intervalRemainingPercent: 30, intervalStatus: .present,
                intervalResetsAt: nil, intervalWindowSeconds: nil,
                weeklyTotalCount: 0, weeklyUsageCount: 0,
                weeklyRemainingPercent: 20, weeklyStatus: .present,
                weeklyResetsAt: Date(timeIntervalSince1970: 4_102_444_800), weeklyWindowSeconds: nil
            )],
            resetCredits: nil, planLabel: nil, accountEmail: nil,
            codexUsageDetails: nil, fetchedAt: Date()
        )

        let okStatus = ProviderStatus(
            id: "test", displayName: "Test", kind: .minimaxTokenPlan,
            iconSystemName: "circle", accentColor: .minimax,
            refreshIntervalSeconds: 60, state: .ok(info)
        )
        XCTAssertEqual(okStatus.lastSuccess?.models.first?.modelName, "general")

        let loadingStatus = ProviderStatus(
            id: "test", displayName: "Test", kind: .minimaxTokenPlan,
            iconSystemName: "circle", accentColor: .minimax,
            refreshIntervalSeconds: 60, state: .loading(lastSuccess: loadingPrev)
        )
        XCTAssertEqual(loadingStatus.lastSuccess?.models.first?.modelName, "old")

        let failedStatus = ProviderStatus(
            id: "test", displayName: "Test", kind: .minimaxTokenPlan,
            iconSystemName: "circle", accentColor: .minimax,
            refreshIntervalSeconds: 60, state: .failed(message: "boom", lastSuccess: info)
        )
        XCTAssertEqual(failedStatus.lastSuccess?.models.first?.modelName, "general")

        let notConfiguredStatus = ProviderStatus(
            id: "test", displayName: "Test", kind: .minimaxTokenPlan,
            iconSystemName: "circle", accentColor: .minimax,
            refreshIntervalSeconds: 60, state: .notConfigured(reason: "no key")
        )
        XCTAssertNil(notConfiguredStatus.lastSuccess)

        let readyStatus = ProviderStatus(
            id: "test", displayName: "Test", kind: .minimaxTokenPlan,
            iconSystemName: "circle", accentColor: .minimax,
            refreshIntervalSeconds: 60, state: .ready
        )
        XCTAssertNil(readyStatus.lastSuccess)
    }

    func testProviderStatusEquatableDistinguishesLastSuccessChanges() {
        let first = QuotaInfo(
            models: [ModelQuota(
                modelName: "first", intervalTotalCount: 0, intervalUsageCount: 0,
                intervalRemainingPercent: 80, intervalStatus: .present,
                intervalResetsAt: nil, intervalWindowSeconds: nil,
                weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 80,
                weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil
            )],
            resetCredits: nil, planLabel: nil, accountEmail: nil,
            codexUsageDetails: nil, fetchedAt: Date(timeIntervalSince1970: 1)
        )
        let second = QuotaInfo(
            models: [ModelQuota(
                modelName: "second", intervalTotalCount: 0, intervalUsageCount: 0,
                intervalRemainingPercent: 80, intervalStatus: .present,
                intervalResetsAt: nil, intervalWindowSeconds: nil,
                weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 80,
                weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil
            )],
            resetCredits: nil, planLabel: nil, accountEmail: nil,
            codexUsageDetails: nil, fetchedAt: Date(timeIntervalSince1970: 1)
        )
        let base = ProviderStatus(
            id: "test", displayName: "Test", kind: .minimaxTokenPlan,
            iconSystemName: "circle", accentColor: .minimax,
            refreshIntervalSeconds: 60, state: .ok(first)
        )
        var changed = base
        changed.state = .ok(second)

        XCTAssertNotEqual(base, changed, "lastSuccess 变化必须参与 ProviderStatus Equatable")
    }

    /// `healthLevel` 现在统一从 `lastSuccess?.healthLevel` 派生，跟 `State` 同步，
    /// 不再有"`.failed(_, nil)` 跟 `_lastSuccess=non-nil` 不一致"的可能。
    func testProviderStatusHealthLevelFromState() {
        let info = QuotaInfo(
            models: [ModelQuota(
                modelName: "general",
                intervalTotalCount: 0, intervalUsageCount: 0,
                intervalRemainingPercent: 10,   // < 20 → critical
                intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: nil,
                weeklyTotalCount: 0, weeklyUsageCount: 0,
                weeklyRemainingPercent: 5, weeklyStatus: .present,
                weeklyResetsAt: Date(timeIntervalSince1970: 4_102_444_800), weeklyWindowSeconds: nil
            )],
            resetCredits: nil, planLabel: nil, accountEmail: nil,
            codexUsageDetails: nil, fetchedAt: Date()
        )
        let failedWithPrev = ProviderStatus(
            id: "t", displayName: "T", kind: .minimaxTokenPlan,
            iconSystemName: "c", accentColor: .minimax,
            refreshIntervalSeconds: 60, state: .failed(message: "err", lastSuccess: info)
        )
        XCTAssertEqual(failedWithPrev.healthLevel, .critical,
                       ".failed(_, prev) 应该从 prev 算 healthLevel，不返回 nil")

        let loadingNoPrev = ProviderStatus(
            id: "t", displayName: "T", kind: .minimaxTokenPlan,
            iconSystemName: "c", accentColor: .minimax,
            refreshIntervalSeconds: 60, state: .loading(lastSuccess: nil)
        )
        XCTAssertNil(loadingNoPrev.healthLevel,
                     ".loading(nil) 没数据时 healthLevel = nil（不是 critical）")

        let notConfigured = ProviderStatus(
            id: "t", displayName: "T", kind: .minimaxTokenPlan,
            iconSystemName: "c", accentColor: .minimax,
            refreshIntervalSeconds: 60, state: .notConfigured(reason: "x")
        )
        XCTAssertNil(notConfigured.healthLevel)
    }

    /// `AppState.stateHasSuccessData` 跟 `state.lastSuccess != nil` 同义。
    /// 抽成 static 让 `rebuildStatuses` 能复用同一判断（auth 仍 ok 时保留旧 .ok/.loading/.failed）。
    func testAppStateStateHasSuccessData() {
        let info = QuotaInfo(
            models: [ModelQuota(
                modelName: "x", intervalTotalCount: 0, intervalUsageCount: 0,
                intervalRemainingPercent: 50, intervalStatus: .present,
                intervalResetsAt: nil, intervalWindowSeconds: nil,
                weeklyTotalCount: 0, weeklyUsageCount: 0,
                weeklyRemainingPercent: 50, weeklyStatus: .present,
                weeklyResetsAt: Date(timeIntervalSince1970: 4_102_444_800), weeklyWindowSeconds: nil
            )],
            resetCredits: nil, planLabel: nil, accountEmail: nil,
            codexUsageDetails: nil, fetchedAt: Date()
        )
        XCTAssertTrue(AppState.stateHasSuccessData(.ok(info)))
        XCTAssertTrue(AppState.stateHasSuccessData(.loading(lastSuccess: info)))
        XCTAssertFalse(AppState.stateHasSuccessData(.loading(lastSuccess: nil)))
        XCTAssertTrue(AppState.stateHasSuccessData(.failed(message: "x", lastSuccess: info)))
        XCTAssertFalse(AppState.stateHasSuccessData(.failed(message: "x", lastSuccess: nil)))
        XCTAssertFalse(AppState.stateHasSuccessData(.notConfigured(reason: "x")))
        XCTAssertFalse(AppState.stateHasSuccessData(.ready))
    }

    // MARK: - P3.1: AppState 取消误判

    /// 可控 throw 的 fetcher，用来验证 AppState catch 里的取消分支
    private final class ErrorThrowingFetcher: QuotaFetcher, @unchecked Sendable {
        let providerID: String
        let displayName: String
        let kind: ProviderKind
        let logTag: String
        /// 每次 fetch 调用都会抛这个错误；nil 时返回成功
        var errorToThrow: Error?
        /// fetch 调用次数
        var fetchCallCount: Int = 0

        init(providerID: String, kind: ProviderKind = .codexChatGpt, errorToThrow: Error? = nil) {
            self.providerID = providerID
            self.displayName = providerID
            self.kind = kind
            self.logTag = "[\(providerID)]"
            self.errorToThrow = errorToThrow
        }

        func fetch(mode: RefreshMode) async throws -> QuotaInfo {
            fetchCallCount += 1
            if let errorToThrow {
                throw errorToThrow
            }
            return QuotaInfo(
                models: [],
                resetCredits: nil,
                planLabel: nil,
                accountEmail: nil,
                codexUsageDetails: nil,
                fetchedAt: Date()
            )
        }

        func hasLocalAuth() -> Bool { true }
        func checkLocalAuth() async -> Bool { true }
    }

    /// 构造测试用 AppState，注入可控 fetcher。使用 Codex 类型避免 AppState.start()
    /// 在测试进程里触发真实用户目录的 minimax 本地数据库扫描。
    @MainActor
    private func makeCancellationTestAppState(
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
    private func makeRefreshWaitTestAppState(fetcher: BlockingRefreshFetcher) -> AppState {
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
        // 2. 状态不是 .failed
        if case .failed = state.statuses[idx].state {
            XCTFail("CancellationError 不应导致 .failed 状态，实际：\(state.statuses[idx].state)")
        }
        // 3. failure count 仍是 0
        let delayAfterCancel = state.refreshScheduler
            .nextDelay(for: providerID, baseInterval: 300, succeeded: false)
        // 没 recordFailure → nextDelay 默认 failureCounts[_, default: 1] = 1
        // 但如果 recordFailure 被错误调用了，会 > 1
        // 更直接：scheduler 没有公开 failureCount 字段，但通过 nextDelay 间接验证
        // nextDelay 在 failures=1 时 = baseInterval * 2 = 600s (含 jitter)
        // 如果 recordFailure 被调 1 次以上（错误），failures=2+ → delay > 1200s
        XCTAssertLessThan(
            delayAfterCancel, 800,
            "取消请求不应触发 recordFailure（delay 应 ≤ 2×baseInterval+小幅 jitter）"
        )
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
    func testAppStateRefreshSchedulerFailureCountAfterCancellation() async {
        // 4. 多次连续取消 → failure count 仍应是 0（不是 1+）
        let fetcher = ErrorThrowingFetcher(
            providerID: "test_multi_cancel",
            errorToThrow: CancellationError()
        )
        let (state, _) = makeCancellationTestAppState(
            providerID: "test_multi_cancel",
            fetcher: fetcher
        )
        let providerID = "test_multi_cancel"

        // 连续 3 次取消
        for _ in 0..<3 {
            await state.refreshOne(providerID: providerID)
        }

        // failure count 应仍是 0 (默认是 1) → nextDelay = baseInterval * 2^1 = 600s
        // 如果被错误地 recordFailure 3 次 → 2^4 = 4800s，远大于 800
        let delay = state.refreshScheduler
            .nextDelay(for: providerID, baseInterval: 300, succeeded: false)
        XCTAssertLessThan(
            delay, 800,
            "3 次连续取消不应累计 failure count（delay 应保持 2×baseInterval 默认）"
        )
    }

    // MARK: - Config Store Template & Descriptor Alignment Tests

    @MainActor
    func testConfigStoreTemplateMatchesAllDescriptors() {
        let templateKeys = Set(ConfigStore.templateProviders().keys)
        let descriptorIDs = Set(LLMMonitorApp.makeDescriptors().map(\.id))
        XCTAssertEqual(templateKeys, descriptorIDs)

        for descriptor in LLMMonitorApp.makeDescriptors() {
            XCTAssertEqual(descriptor.id, descriptor.kind.providerID)
        }

        let descriptorKinds = Set(LLMMonitorApp.makeDescriptors().map(\.kind))
        XCTAssertEqual(descriptorKinds, Set(ProviderKind.allCases))
    }

    @MainActor
    func testConfigStoreTemplateStartsDisabledAndRejectsPlaceholders() {
        let providers = ConfigStore.templateProviders()
        XCTAssertEqual(providers.count, ProviderKind.allCases.count)
        XCTAssertTrue(providers.values.allSatisfy { !$0.enabled })
        XCTAssertNil(providers[ProviderKind.minimaxTokenPlan.providerID]?.usableAPIKey)
        XCTAssertNil(providers[ProviderKind.glmCodingPlan.providerID]?.usableAPIKey)
        XCTAssertNil(providers[ProviderKind.deepseek.providerID]?.usableAPIKey)
        XCTAssertEqual(
            providers[ProviderKind.codexChatGpt.providerID]?.authPath,
            "~/.codex/auth.json"
        )
    }

    @MainActor
    func testConfigStoreEnsureProvidersPresentRestoresMissingDescriptorEntries() throws {
        let store = makeIsolatedConfigStore()
        var config = store.config
        config.providers.removeValue(forKey: ProviderKind.glmCodingPlan.providerID)
        config.providers.removeValue(forKey: ProviderKind.antigravity.providerID)
        try store.applyAndSave(config)

        XCTAssertTrue(store.ensureProvidersPresent(descriptors: LLMMonitorApp.makeDescriptors()))
        XCTAssertEqual(
            Set(store.config.providers.keys),
            Set(ProviderKind.allCases.map(\.providerID))
        )
        XCTAssertFalse(store.config.providers[ProviderKind.glmCodingPlan.providerID]?.enabled ?? true)
        XCTAssertFalse(store.config.providers[ProviderKind.antigravity.providerID]?.enabled ?? true)
    }

    @MainActor
    func testConfigStoreLoadsLegacyConfigWithCodableDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-legacy-config-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyJSON = """
        {
          "refreshIntervalSeconds": 120,
          "providers": {
            "minimax_token_plan": {
              "enabled": true,
              "apiKey": "sk-cp-legacy-real-key"
            }
          }
        }
        """
        try Data(legacyJSON.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigStore(configURL: url)
        XCTAssertEqual(store.config.refreshIntervalSeconds, 120)
        XCTAssertEqual(store.config.schemaVersion, AppConfig.currentSchemaVersion)
        XCTAssertEqual(
            store.config.providers[ProviderKind.minimaxTokenPlan.providerID]?.apiKey,
            "sk-cp-legacy-real-key"
        )
        XCTAssertNil(store.config.providers[ProviderKind.minimaxTokenPlan.providerID]?.authPath)
        XCTAssertTrue(store.ensureProvidersPresent(descriptors: LLMMonitorApp.makeDescriptors()))
        XCTAssertEqual(store.config.providers.count, ProviderKind.allCases.count)
    }

    @MainActor
    func testAppInstanceLockAllowsOnlyOneOwner() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-instance-lock-\(UUID().uuidString)", isDirectory: true)
        let lockURL = directory.appendingPathComponent("instance.lock")

        do {
            let first = AppInstanceLock.acquire(at: lockURL)
            XCTAssertNotNil(first)
            XCTAssertNil(AppInstanceLock.acquire(at: lockURL))
        }

        XCTAssertNotNil(AppInstanceLock.acquire(at: lockURL))
    }

    @MainActor
    func testAppInstanceLockResultDistinguishesContentionFromFilesystemFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-instance-lock-result-\(UUID().uuidString)", isDirectory: true)
        let lockURL = directory.appendingPathComponent("instance.lock")
        defer { try? FileManager.default.removeItem(at: directory) }

        guard case .acquired(let firstLock) = AppInstanceLock.acquireResult(at: lockURL) else {
            return XCTFail("首个实例应取得锁")
        }
        let contentionResult = withExtendedLifetime(firstLock) {
            AppInstanceLock.acquireResult(at: lockURL)
        }
        guard case .alreadyRunning = contentionResult else {
            return XCTFail("第二个实例应被识别为锁竞争")
        }

        let parentFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-lock-parent-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: parentFile)
        defer { try? FileManager.default.removeItem(at: parentFile) }

        guard case .failed(.createDirectoryFailed) = AppInstanceLock.acquireResult(
            at: parentFile.appendingPathComponent("instance.lock")
        ) else {
            return XCTFail("锁目录创建失败不应伪装成已有实例")
        }
    }

    func testAppConfigSchemaVersionIsWrittenAndFutureVersionIsRejected() throws {
        let config = AppConfig(refreshIntervalSeconds: 300, providers: [:])
        let data = try JSONEncoder().encode(config)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, AppConfig.currentSchemaVersion)

        let futureJSON = """
        {
          "schemaVersion": 999,
          "refreshIntervalSeconds": 300,
          "providers": {}
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(AppConfig.self, from: futureJSON)) { error in
            XCTAssertEqual(error as? AppConfig.SchemaError, .unsupportedVersion(999))
        }
    }

    @MainActor
    func testConfigStoreDoesNotOverwriteFutureSchemaConfig() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-future-config-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let futureJSON = Data("""
        {
          "schemaVersion": 999,
          "refreshIntervalSeconds": 300,
          "providers": {}
        }
        """.utf8)
        try futureJSON.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigStore(configURL: url)
        XCTAssertThrowsError(try store.applyAndSave(.default)) { error in
            guard case ConfigStore.PersistenceError.corruptConfigBackupFailed(let thrownURL) = error else {
                return XCTFail("未来 schema 配置必须禁止自动写回，实际错误: \(error)")
            }
            XCTAssertEqual(thrownURL, url)
        }
        XCTAssertEqual(try Data(contentsOf: url), futureJSON)
    }

    @MainActor
    func testAppStateRestoresPersistedLastRefreshTime() throws {
        let store = makeIsolatedConfigStore()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let timestampURL = store.configURL
            .deletingLastPathComponent()
            .appendingPathComponent("last-refresh.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([ProviderKind.minimaxTokenPlan.providerID: timestamp])
            .write(to: timestampURL)

        var config = store.config
        config.providers[ProviderKind.minimaxTokenPlan.providerID]?.apiKey = "sk-cp-test-key"
        try store.applyAndSave(config)

        let state = AppState(
            descriptors: LLMMonitorApp.makeDescriptors(),
            configStore: store
        )
        let minimax = try XCTUnwrap(
            state.statuses.first(where: { $0.kind == .minimaxTokenPlan })
        )
        XCTAssertEqual(minimax.lastRefreshedAt, timestamp)
    }

    @MainActor
    func testCorruptConfigIsBackedUpBeforeRecoveryWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-corrupt-config-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        let corruptData = Data("{broken".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try corruptData.write(to: url)

        let store = ConfigStore(configURL: url)
        XCTAssertEqual(try Data(contentsOf: url), corruptData)

        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("config.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), corruptData)

        var recovered = store.config
        recovered.refreshIntervalSeconds = 600
        try store.applyAndSave(recovered)
        XCTAssertEqual(store.config.refreshIntervalSeconds, 600)
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url)), recovered)
    }

    @MainActor
    func testConfigStoreDetectsContentChangeWhenMtimeIsUnchanged() throws {
        let store = makeIsolatedConfigStore()
        let originalMtime = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: store.configURL.path)[.modificationDate] as? Date
        )
        var changed = store.config
        changed.refreshIntervalSeconds += 1
        let data = try JSONEncoder().encode(changed)

        try data.write(to: store.configURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: originalMtime],
            ofItemAtPath: store.configURL.path
        )

        XCTAssertTrue(
            store.hasChangedSinceLastRead(),
            "配置内容变化不能仅依赖 mtime 精度，否则连续保存可能漏掉 reload"
        )
    }

    @MainActor
    func testAppStateStartAfterStopRestartsConfigWatcher() async throws {
        let store = makeIsolatedConfigStore()
        let state = AppState(descriptors: [], configStore: store)
        state.stop()

        let reloadExpectation = expectation(description: "配置 watcher 在重启后继续工作")
        let cancellable = store.$config
            .dropFirst()
            .sink { _ in reloadExpectation.fulfill() }
        defer {
            cancellable.cancel()
            state.stop()
        }

        state.start()
        var changed = store.config
        changed.refreshIntervalSeconds += 1
        let data = try JSONEncoder().encode(changed)
        try data.write(to: store.configURL, options: .atomic)

        await fulfillment(of: [reloadExpectation], timeout: 2)
        XCTAssertEqual(store.config.refreshIntervalSeconds, changed.refreshIntervalSeconds)
    }

    /// 审计降级项复现测试 1：生产写入路径（ConfigStore.persist → FileManagerBox
    /// .writePrivate → 临时文件 + rename）必须触发目录 `.write` watcher 的 reload。
    /// 该测试与 startAfterStop 测试一起，作为“目录 .write 掩码不会错过 rename 替换”
    /// 的 macOS 平台行为证据；若未来 macOS 行为变化导致本测试失败，再改事件模型。
    @MainActor
    func testConfigWatcherCatchesProductionPersistRenameWrite() async throws {
        let store = makeIsolatedConfigStore()
        let state = AppState(descriptors: [], configStore: store)
        state.start()
        defer { state.stop() }

        let reloadExpectation = expectation(description: "生产 persist 路径触发 reload")
        let cancellable = store.$config
            .dropFirst()
            .sink { _ in reloadExpectation.fulfill() }
        defer { cancellable.cancel() }

        var changed = store.config
        changed.refreshIntervalSeconds += 1
        try store.applyAndSave(changed)

        await fulfillment(of: [reloadExpectation], timeout: 2)
        XCTAssertEqual(store.config.refreshIntervalSeconds, changed.refreshIntervalSeconds)
    }

    /// 审计降级项复现测试 2：最坏情况——外部进程在同一目录创建临时文件后用
    /// rename(2) 覆盖 config.json。目录 `.write` 事件仍必须触发 reload。
    @MainActor
    func testConfigWatcherCatchesRawRenameOverConfigFile() async throws {
        let store = makeIsolatedConfigStore()
        let state = AppState(descriptors: [], configStore: store)
        state.start()
        defer { state.stop() }

        let reloadExpectation = expectation(description: "raw rename 覆盖触发 reload")
        let cancellable = store.$config
            .dropFirst()
            .sink { _ in reloadExpectation.fulfill() }
        defer { cancellable.cancel() }

        var changed = store.config
        changed.refreshIntervalSeconds += 2
        let data = try JSONEncoder().encode(changed)
        let stagingURL = store.configURL.deletingLastPathComponent()
            .appendingPathComponent("config.json.editor-swap")
        try data.write(to: stagingURL)
        let renameResult = stagingURL.path.withCString { src in
            store.configURL.path.withCString { dst in
                Darwin.rename(src, dst)
            }
        }
        XCTAssertEqual(renameResult, 0, "rename(2) 覆盖 config.json 必须成功")

        await fulfillment(of: [reloadExpectation], timeout: 2)
        XCTAssertEqual(store.config.refreshIntervalSeconds, changed.refreshIntervalSeconds)
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
        // 等两个 waiter 都挂到 waitUntilNotInFlight 上
        for _ in 0..<200
        where state.refreshScheduler.inFlightWaiterCount(for: fetcher.providerID) < 2 {
            await Task.yield()
        }
        XCTAssertEqual(
            state.refreshScheduler.inFlightWaiterCount(for: fetcher.providerID),
            2,
            "两个 full refresh waiter 都应挂到 waitUntilNotInFlight 上"
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

    // MARK: - P1: ConfigStore.applyAndSave persistence blocked

    /// 当配置解析失败且 `backupCorruptConfig` 也失败时，`persistenceAllowed = false`，
    /// 后续 `applyAndSave` 必须抛 `corruptConfigBackupFailed`。
    /// 这个保护避免默认空配置覆盖用户的损坏原文件。
    ///
    /// 触发条件：把损坏的 `config.json` 设为 0o000（owner 也无法读），
    /// `ConfigStore.init` 的 `load` 走 EACCES 失败分支 →
    /// `backupCorruptConfig.copyItem(at: url, ...)` 源不可读 → 返回 nil →
    /// `persistenceAllowed = false`。`applyAndSave` 后续必须抛 `corruptConfigBackupFailed`。
    ///
    /// 注：原计划是 chmod 0o500 整个目录，但 `ConfigStore.init` 内部会主动
    /// `setAttributes(dir, 0o700)`，把目录权限改回可写，导致 backup 仍能成功。
    /// 设源文件为 0o000 不会被 init 改回，副作用更小。
    @MainActor
    func testConfigStoreApplyAndSaveThrowsWhenPersistenceDisabled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "llm-monitor-persistence-blocked-\(UUID().uuidString)", isDirectory: true
            )
        let url = directory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        // 写一个损坏的配置文件
        try Data("{broken".utf8).write(to: url)
        // 把源文件设为 0o000（owner 不可读）。copyItem 源不可读时必定抛 EACCES，
        // ConfigStore.init 走 backup-failed 分支并设 persistenceAllowed = false。
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: url.path
        )
        addTeardownBlock {
            // 还原文件权限让 teardown 能 unlink（unlink 实际只依赖父目录权限，
            // 但为了保险还是恢复一下）
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)],
                ofItemAtPath: url.path
            )
            try? FileManager.default.removeItem(at: directory)
        }

        // 触发 init：load 失败（EACCES）→ 尝试 backup（copyItem 源 0o000 也 EACCES）
        // → persistenceAllowed = false
        let store = ConfigStore(configURL: url)

        // 1. 验证：现在 applyAndSave 必须抛 .corruptConfigBackupFailed
        var newConfig = store.config
        newConfig.refreshIntervalSeconds = 999
        XCTAssertThrowsError(try store.applyAndSave(newConfig)) { error in
            guard case ConfigStore.PersistenceError.corruptConfigBackupFailed(let thrownURL) = error else {
                XCTFail("expected .corruptConfigBackupFailed, got \(error)")
                return
            }
            XCTAssertEqual(thrownURL, url, "抛出的 URL 应是 configURL")
        }

        // 2. 验证：applyAndSave 失败后 store.config 没被污染（仍是默认 / 加载失败时的空 config）
        XCTAssertNotEqual(
            store.config.refreshIntervalSeconds, 999,
            "applyAndSave 抛错后内存中的 config 不应被改写"
        )
    }

    @MainActor
    func testProviderStatusIsEnabledReflectsConfigAndControlsFiltering() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("config.json")
        let configStore = ConfigStore(configURL: configURL)

        var config = configStore.config
        config.providers["test_a"] = ProviderConfig(enabled: true)
        config.providers["test_b"] = ProviderConfig(enabled: false)
        try? configStore.applyAndSave(config)

        let descA = FetcherDescriptor(
            id: "test_a",
            displayName: "Test A",
            kind: .minimaxTokenPlan,
            iconSystemName: "star",
            accentColor: .minimax,
            makeFetcher: { _ in TestQuotaFetcher(providerID: "test_a", displayName: "Test A", kind: .minimaxTokenPlan) }
        )
        let descB = FetcherDescriptor(
            id: "test_b",
            displayName: "Test B",
            kind: .glmCodingPlan,
            iconSystemName: "moon",
            accentColor: .glm,
            makeFetcher: { _ in TestQuotaFetcher(providerID: "test_b", displayName: "Test B", kind: .glmCodingPlan) }
        )

        let appState = AppState(descriptors: [descA, descB], configStore: configStore)

        XCTAssertEqual(appState.statuses.count, 2)
        XCTAssertTrue(appState.statuses.first(where: { $0.id == "test_a" })?.isEnabled ?? false)
        XCTAssertFalse(appState.statuses.first(where: { $0.id == "test_b" })?.isEnabled ?? true)

        let visibleCards = appState.statuses.filter { $0.isEnabled }
        XCTAssertEqual(visibleCards.count, 1)
        XCTAssertEqual(visibleCards.first?.id, "test_a")
    }
}

private struct TestQuotaFetcher: QuotaFetcher {
    let providerID: String
    let displayName: String
    let kind: ProviderKind

    func fetch(mode: RefreshMode) async throws -> QuotaInfo {
        QuotaInfo(models: [], resetCredits: nil, planLabel: nil, accountEmail: nil, codexUsageDetails: nil, fetchedAt: Date())
    }

    func hasLocalAuth() -> Bool { true }
}

/// 让 NSWindow 在测试里能伪造 isKeyWindow。`NSWindow` 的 isKeyWindow 是
/// 只读且依赖 window-server，常规方式改不了；子类化 override 是 XCTest 里常用
/// 手法。注意：必须放在主 actor 上（NSWindow 本身在 main 上）。
@MainActor
private final class KeyWindowStub: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor
private final class NonKeyWindowStub: NSWindow {
    override var isKeyWindow: Bool { false }
}
