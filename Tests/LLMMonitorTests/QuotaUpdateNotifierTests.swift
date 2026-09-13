import XCTest
@testable import LLM_monitor

final class QuotaUpdateNotifierTests: XCTestCase {
    @MainActor
    private final class SpyNotifier: QuotaUpdateNotifying {
        struct Event {
            let providerID: String
            let providerName: String
            let events: [QuotaEvent]
            let channels: QuotaNotifyChannels
        }

        private(set) var recorded: [Event] = []

        func notify(
            providerID: String,
            providerName: String,
            events: [QuotaEvent],
            channels: QuotaNotifyChannels
        ) {
            recorded.append(.init(
                providerID: providerID,
                providerName: providerName,
                events: events,
                channels: channels
            ))
        }
    }

    private func model(
        _ name: String,
        interval: Double,
        weekly: Double,
        intervalStatus: QuotaWindowStatus = .present,
        weeklyStatus: QuotaWindowStatus = .present
    ) -> ModelQuota {
        ModelQuota(
            modelName: name,
            intervalTotalCount: 100,
            intervalUsageCount: Int(100 - interval),
            intervalRemainingPercent: interval,
            intervalStatus: intervalStatus,
            intervalResetsAt: nil,
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: 100,
            weeklyUsageCount: Int(100 - weekly),
            weeklyRemainingPercent: weekly,
            weeklyStatus: weeklyStatus,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: 7 * 24 * 3600
        )
    }

    private func info(_ models: [ModelQuota]) -> QuotaInfo {
        QuotaInfo(
            models: models,
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: Date()
        )
    }

    func testSystemNotifierConstructionDoesNotAccessNotificationCenterEarly() {
        // SwiftUI App.init 阶段只能构造依赖，不能提前访问 UNUserNotificationCenter.current()。
        _ = SystemQuotaUpdateNotifier()
    }

    func testFirstSnapshotDoesNotNotify() {
        let current = info([model("general", interval: 100, weekly: 100)])
        XCTAssertTrue(QuotaEventDetector.detect(current: current, previous: nil).isEmpty)
    }

    func testDetectsOnlyChangedWindowsForExistingModels() {
        let previous = info([
            model("general", interval: 10, weekly: 40),
            model("video", interval: 80, weekly: 70),
        ])
        let current = info([
            model("general", interval: 100, weekly: 35),
            model("video", interval: 80, weekly: 90),
            model("new-model", interval: 100, weekly: 100),
        ])

        let changes = QuotaEventDetector.detect(current: current, previous: previous)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].kind, .intervalRestored)
        XCTAssertEqual(changes[0].previousPercent, 10)
        XCTAssertEqual(changes[0].currentPercent, 100)
        XCTAssertEqual(changes[1].kind, .weeklyRestored)
        XCTAssertEqual(changes[1].previousPercent, 70)
        XCTAssertEqual(changes[1].currentPercent, 90)
    }

    func testDetectsExhaustedWindows() {
        let previous = info([model("general", interval: 5, weekly: 12)])
        let current = info([model("general", interval: 0, weekly: 0)])

        let events = QuotaEventDetector.detect(current: current, previous: previous)
        XCTAssertEqual(Set(events.map(\.kind)), [.intervalExhausted, .weeklyExhausted])
    }

    func testStaysExhaustedWithoutRepeatAndAbsentOrNewWindowDoNotNotify() {
        // 已经耗尽（两次都是 0）不重复通知。
        let exhaustedTwice = QuotaEventDetector.detect(
            current: info([model("general", interval: 0, weekly: 0)]),
            previous: info([model("general", interval: 0, weekly: 0)])
        )
        XCTAssertTrue(exhaustedTwice.isEmpty)

        // 窗口缺席 / 浮点噪声不产生事件。
        let previous = info([
            model("general", interval: 50, weekly: 0, weeklyStatus: .absent),
            model("video", interval: 50, weekly: 50),
        ])
        let current = info([
            model("general", interval: 50, weekly: 100, weeklyStatus: .present),
            model("video", interval: 50.005, weekly: 50),
        ])
        XCTAssertTrue(QuotaEventDetector.detect(current: current, previous: previous).isEmpty)
    }

    func testRestoredRuleFollowsConfiguredThresholds() {
        // 2026-09-13 裁定：恢复 = 回升 > 5pp，或回到 98% 以上且严格回升。
        func detect(_ old: Double, _ new: Double) -> [QuotaEvent] {
            QuotaEventDetector.detect(
                current: info([model("g", interval: new, weekly: 0, weeklyStatus: .absent)]),
                previous: info([model("g", interval: old, weekly: 0, weeklyStatus: .absent)])
            )
        }
        // 0 → 3：小幅回升（3 < 98 且 +3 ≤ 5），不报。
        XCTAssertTrue(detect(0, 3).isEmpty)
        // 50 → 54：+4 ≤ 5 且 54 < 98，不报。
        XCTAssertTrue(detect(50, 54).isEmpty)
        // 10 → 20：+10 > 5，报。
        XCTAssertEqual(detect(10, 20).first?.kind, .intervalRestored)
        // 96 → 100：+4 但回到 98+ 且严格回升，报。
        XCTAssertEqual(detect(96, 100).first?.kind, .intervalRestored)
        // 99 → 100：98+ 区间内的回升，按字面公式报。
        XCTAssertEqual(detect(99, 100).first?.kind, .intervalRestored)
        // 100 → 100：parked（没有回升），不报——否则闲置 provider 每刷必响。
        XCTAssertTrue(detect(100, 100).isEmpty)
    }

    func testSystemNotificationTitleReflectsEventKinds() {
        func event(_ kind: QuotaNotificationKind) -> QuotaEvent {
            QuotaEvent(
                modelName: "general", displayName: "general", kind: kind,
                previousPercent: 10,
                currentPercent: kind == .intervalExhausted || kind == .weeklyExhausted ? 0 : 100
            )
        }
        XCTAssertEqual(
            SystemQuotaUpdateNotifier.notificationTitle(providerName: "Codex", events: [event(.intervalExhausted)]),
            "Codex 额度已用完"
        )
        XCTAssertEqual(
            SystemQuotaUpdateNotifier.notificationTitle(
                providerName: "Codex", events: [event(.intervalRestored), event(.weeklyRestored)]
            ),
            "Codex 额度已恢复"
        )
        XCTAssertEqual(
            SystemQuotaUpdateNotifier.notificationTitle(
                providerName: "Codex", events: [event(.intervalExhausted), event(.weeklyRestored)]
            ),
            "Codex 额度提醒"
        )
    }

    func testChannelDefaultsPreserveLegacyBehavior() {
        // 默认渠道：恢复 → 系统通知，耗尽 → 不通知（与历史行为一致）。
        let defaults = QuotaNotifyChannels()
        XCTAssertEqual(defaults.channel(for: .intervalRestored), .system)
        XCTAssertEqual(defaults.channel(for: .weeklyRestored), .system)
        XCTAssertEqual(defaults.channel(for: .intervalExhausted), .none)
        XCTAssertEqual(defaults.channel(for: .weeklyExhausted), .none)
    }

    func testSystemThreadIdentifierIncludesProvider() {
        // R3: 不同 Provider 的同名模型不能共享 macOS 通知线程。
        let minimax = SystemQuotaUpdateNotifier.threadIdentifier(
            providerID: "minimax_token_plan", modelName: "general"
        )
        let antigravity = SystemQuotaUpdateNotifier.threadIdentifier(
            providerID: "antigravity", modelName: "general"
        )
        XCTAssertEqual(minimax, "quota-update-minimax_token_plan-general")
        XCTAssertNotEqual(minimax, antigravity)
    }

    func testSystemNotificationCooldownSuppressesRapidRepeat() {
        // D2: 同一模型 60s 冷却窗口内的重复系统通知被抑制；不同模型不受影响。
        var lastNotified: [String: Date] = [:]
        let group = QuotaEventBatch.ModelGroup(
            modelName: "general",
            displayName: "general",
            systemEvents: [],
            barkEvents: [],
            barkNotificationID: "llmmonitor-p-general"
        )
        let other = QuotaEventBatch.ModelGroup(
            modelName: "video",
            displayName: "video",
            systemEvents: [],
            barkEvents: [],
            barkNotificationID: "llmmonitor-p-video"
        )

        let first = SystemQuotaUpdateNotifier.groupsAfterCooldown(
            [group], providerID: "p", now: Date(timeIntervalSince1970: 1000),
            lastNotifiedAt: &lastNotified
        )
        XCTAssertEqual(first.count, 1)

        let tooSoon = SystemQuotaUpdateNotifier.groupsAfterCooldown(
            [group], providerID: "p", now: Date(timeIntervalSince1970: 1030),
            lastNotifiedAt: &lastNotified
        )
        XCTAssertTrue(tooSoon.isEmpty, "冷却窗口内的重复通知应被过滤")

        let afterWindow = SystemQuotaUpdateNotifier.groupsAfterCooldown(
            [group], providerID: "p", now: Date(timeIntervalSince1970: 1061),
            lastNotifiedAt: &lastNotified
        )
        XCTAssertEqual(afterWindow.count, 1, "冷却窗口过后应恢复通知")

        let otherModel = SystemQuotaUpdateNotifier.groupsAfterCooldown(
            [other], providerID: "p", now: Date(timeIntervalSince1970: 1030),
            lastNotifiedAt: &lastNotified
        )
        XCTAssertEqual(otherModel.count, 1, "其它模型不受同 provider 冷却影响")
    }

    @MainActor
    func testSetNotifyChannelNormalizesDefaultsToNil() {
        // O2: 与默认渠道一致时归一化为 nil，默认值唯一来源是 QuotaNotifyChannels。
        var pc = ProviderConfig(enabled: true)
        pc.setNotifyChannel(.system, for: .intervalRestored)
        XCTAssertNil(pc.notifyIntervalRestored)
        pc.setNotifyChannel(.barkAndSystem, for: .intervalRestored)
        XCTAssertEqual(pc.notifyIntervalRestored, .barkAndSystem)
        pc.setNotifyChannel(.none, for: .weeklyExhausted)
        XCTAssertNil(pc.notifyWeeklyExhausted)
        pc.setNotifyChannel(.system, for: .weeklyExhausted)
        XCTAssertEqual(pc.notifyWeeklyExhausted, .system)
    }

    @MainActor
    func testAppStateNotifiesAfterSecondSuccessfulRefreshIncreasesQuota() async throws {
        final class TwoSnapshotFetcher: QuotaFetcher, @unchecked Sendable {
            let providerID = "quota_notification_test"
            let displayName = "Quota Notification Test"
            let kind = ProviderKind.codexChatGpt
            let logTag = "[quota-notification-test]"
            var snapshots: [QuotaInfo]

            init(snapshots: [QuotaInfo]) {
                self.snapshots = snapshots
            }

            func fetch(mode: RefreshMode) async throws -> QuotaInfo {
                snapshots.removeFirst()
            }

            func hasLocalAuth() -> Bool { true }
            func checkLocalAuth() async -> Bool { true }
        }

        let fetcher = TwoSnapshotFetcher(snapshots: [
            info([model("chatgpt_plan", interval: 20, weekly: 40)]),
            info([model("chatgpt_plan", interval: 100, weekly: 40)]),
        ])
        let notifier = SpyNotifier()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-quota-notifier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configStore = ConfigStore(configURL: directory.appendingPathComponent("config.json"))
        var config = configStore.config
        config.providers[fetcher.providerID] = ProviderConfig(
            enabled: true,
            authPath: directory.appendingPathComponent("auth.json").path,
            // 恢复走 Bark+系统、耗尽走 Bark：验证 AppState 会把配置传给通知器。
            notifyIntervalRestored: .barkAndSystem,
            notifyIntervalExhausted: .barkAndSystem
        )
        try configStore.applyAndSave(config)

        let descriptor = FetcherDescriptor(
            id: fetcher.providerID,
            displayName: "Test Provider",
            kind: .codexChatGpt,
            iconSystemName: "star",
            accentColor: .chatgpt,
            makeFetcher: { _ in fetcher }
        )
        let state = AppState(
            descriptors: [descriptor],
            configStore: configStore,
            quotaUpdateNotifier: notifier
        )
        state.stop()
        defer { state.stop() }

        _ = await state.refreshProviderDirectly(providerID: fetcher.providerID, mode: .full)
        XCTAssertTrue(notifier.recorded.isEmpty, "首次成功快照不能通知")

        _ = await state.refreshProviderDirectly(providerID: fetcher.providerID, mode: .full)
        XCTAssertEqual(notifier.recorded.count, 1)
        XCTAssertEqual(notifier.recorded[0].providerID, fetcher.providerID)
        XCTAssertEqual(notifier.recorded[0].providerName, "Test Provider")
        XCTAssertEqual(notifier.recorded[0].events.count, 1)
        XCTAssertEqual(notifier.recorded[0].events[0].kind, .intervalRestored)
        XCTAssertEqual(notifier.recorded[0].channels.channel(for: .intervalRestored), .barkAndSystem)
        XCTAssertEqual(notifier.recorded[0].channels.channel(for: .weeklyRestored), .system)
    }

    /// 按调用顺序吐出预设快照的 fetcher（多快照集成测试共用）。
    private final class ScriptedQuotaFetcher: QuotaFetcher, @unchecked Sendable {
        let providerID: String
        let displayName = "Notify Test"
        let kind: ProviderKind
        let logTag = "[notify-test]"
        private var snapshots: [QuotaInfo]

        init(providerID: String, kind: ProviderKind, snapshots: [QuotaInfo]) {
            self.providerID = providerID
            self.kind = kind
            self.snapshots = snapshots
        }

        func fetch(mode: RefreshMode) async throws -> QuotaInfo {
            guard !snapshots.isEmpty else { throw QuotaError.invalidResponse }
            return snapshots.removeFirst()
        }

        func hasLocalAuth() -> Bool { true }
        func checkLocalAuth() async -> Bool { true }
    }

    @MainActor
    private func makeScriptedState(
        fetcher: ScriptedQuotaFetcher,
        notifier: SpyNotifier,
        apiKey: String
    ) throws -> (state: AppState, configStore: ConfigStore, store: TriggerStateStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-notify-trigger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.json")
        // 注入 store：测试直接观察基线，不依赖调度器行为（配置变更会触发
        // rescheduleAll 自动刷新，消耗脚本快照造成非确定时序）。
        let store = TriggerStateStore(configURL: configURL)
        let configStore = ConfigStore(configURL: configURL)
        var config = configStore.config
        config.providers[fetcher.providerID] = ProviderConfig(enabled: true, apiKey: apiKey)
        try configStore.applyAndSave(config)

        let descriptor = FetcherDescriptor(
            id: fetcher.providerID,
            displayName: "Notify Test",
            kind: fetcher.kind,
            iconSystemName: "star",
            accentColor: .minimax,
            makeFetcher: { _ in fetcher }
        )
        let state = AppState(
            descriptors: [descriptor],
            configStore: configStore,
            quotaUpdateNotifier: notifier,
            triggerStateStore: store
        )
        return (state, configStore, store, directory)
    }

    @MainActor
    func testBaselineResetWhenProviderBecomesNotConfigured() async throws {
        // 缺口①：provider 转入 .notConfigured（API Key 清空）时 rebuildStatuses
        // 必须清掉持久化基线；重新配置后回到"首帧只建基线"语义，下一刷重建。
        let fetcher = ScriptedQuotaFetcher(providerID: "minimax_notify_test", kind: .minimaxTokenPlan, snapshots: [
            info([model("general", interval: 10, weekly: 40)]),
        ])
        let notifier = SpyNotifier()
        let (state, configStore, store, directory) = try makeScriptedState(
            fetcher: fetcher, notifier: notifier, apiKey: "sk-notify-test-key"
        )
        state.stop()
        defer {
            state.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        _ = await state.refreshProviderDirectly(providerID: fetcher.providerID, mode: .full)
        XCTAssertTrue(notifier.recorded.isEmpty, "首帧只建基线")
        let baseline = try XCTUnwrap(store.snapshot(for: fetcher.providerID))
        XCTAssertEqual(baseline.models["general"]?.intervalRemainingPercent, 10)

        // API Key 清空 → .notConfigured → rebuildStatuses 触发基线 reset。
        var config = configStore.config
        config.providers[fetcher.providerID]?.apiKey = ""
        try configStore.applyAndSave(config)
        state.rebuildStatuses()
        XCTAssertNil(store.snapshot(for: fetcher.providerID), "notConfigured 时基线应被清空")

        // 重新配置：基线保持为空，回到"首帧只建基线"语义（首帧行为已由
        // testFirstSnapshotDoesNotNotify 与集成测试覆盖）。此处不断言重配后
        // 的刷新：applyAndSave 的 RunLoop sink 会递增 configurationGeneration
        // 并触发调度器自动刷新，显式刷新的 fetch 结果会被当作陈旧丢弃——
        // 这是生产行为的正确设计，测试里时序不可确定。
        config = configStore.config
        config.providers[fetcher.providerID]?.apiKey = "sk-notify-test-key"
        try configStore.applyAndSave(config)
        state.rebuildStatuses()
        XCTAssertNil(store.snapshot(for: fetcher.providerID))
    }

    @MainActor
    func testNonWindowedProviderDoesNotEmitQuotaEvents() async throws {
        // 缺口②：DeepSeek 等余额类 provider（windowedKinds 门控之外）不产生
        // 窗口事件。其余额口径被二值化为 0/100，若未门控，余额耗尽
        // （100 → 0）会误报「5 小时额度已耗尽」。
        let fetcher = ScriptedQuotaFetcher(providerID: "deepseek_test", kind: .deepseek, snapshots: [
            info([model("deepseek_balance", interval: 100, weekly: 0, weeklyStatus: .absent)]),
            info([model("deepseek_balance", interval: 0, weekly: 0, weeklyStatus: .absent)]),
        ])
        let notifier = SpyNotifier()
        let (state, _, _, directory) = try makeScriptedState(
            fetcher: fetcher, notifier: notifier, apiKey: "sk-notify-test-key"
        )
        state.stop()
        defer {
            state.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        _ = await state.refreshProviderDirectly(providerID: fetcher.providerID, mode: .full)
        _ = await state.refreshProviderDirectly(providerID: fetcher.providerID, mode: .full)
        XCTAssertTrue(notifier.recorded.isEmpty, "非窗口类 provider 任何情况下都不发额度事件")
    }
}
