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
}
