import XCTest
@testable import LLM_monitor

final class QuotaUpdateNotifierTests: XCTestCase {
    private final class SpyNotifier: QuotaUpdateNotifying {
        struct Event {
            let providerID: String
            let providerName: String
            let increases: [QuotaIncrease]
        }

        private(set) var events: [Event] = []

        func notify(providerID: String, providerName: String, increases: [QuotaIncrease]) {
            events.append(.init(
                providerID: providerID,
                providerName: providerName,
                increases: increases
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
        XCTAssertTrue(QuotaIncreaseDetector.detect(current: current, previous: nil).isEmpty)
    }

    func testDetectsOnlyIncreasedWindowsForExistingModels() {
        let previous = info([
            model("general", interval: 10, weekly: 40),
            model("video", interval: 80, weekly: 70),
        ])
        let current = info([
            model("general", interval: 100, weekly: 35),
            model("video", interval: 80, weekly: 90),
            model("new-model", interval: 100, weekly: 100),
        ])

        let changes = QuotaIncreaseDetector.detect(current: current, previous: previous)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].modelName, "general")
        XCTAssertEqual(changes[0].interval, .init(previousPercent: 10, currentPercent: 100))
        XCTAssertNil(changes[0].weekly)
        XCTAssertEqual(changes[1].modelName, "video")
        XCTAssertNil(changes[1].interval)
        XCTAssertEqual(changes[1].weekly, .init(previousPercent: 70, currentPercent: 90))
    }

    func testAbsentOrNewWindowAndFloatingPointNoiseDoNotNotify() {
        let previous = info([
            model("general", interval: 50, weekly: 0, weeklyStatus: .absent),
            model("video", interval: 50, weekly: 50),
        ])
        let current = info([
            model("general", interval: 50, weekly: 100, weeklyStatus: .present),
            model("video", interval: 50.005, weekly: 50),
        ])

        XCTAssertTrue(QuotaIncreaseDetector.detect(current: current, previous: previous).isEmpty)
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
            authPath: directory.appendingPathComponent("auth.json").path
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
        XCTAssertTrue(notifier.events.isEmpty, "首次成功快照不能通知")

        _ = await state.refreshProviderDirectly(providerID: fetcher.providerID, mode: .full)
        XCTAssertEqual(notifier.events.count, 1)
        XCTAssertEqual(notifier.events[0].providerID, fetcher.providerID)
        XCTAssertEqual(notifier.events[0].providerName, "Test Provider")
        XCTAssertEqual(notifier.events[0].increases.count, 1)
        XCTAssertEqual(
            notifier.events[0].increases[0].interval,
            .init(previousPercent: 20, currentPercent: 100)
        )
    }
}
