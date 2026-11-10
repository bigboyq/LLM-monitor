import AppKit
import XCTest
@testable import LLM_monitor

@MainActor
final class CrossReviewUITests: StateTestCase {
    private func holidayFixture() throws -> (directory: URL, source: URL, cache: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cross-review-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.json")
        let document = HolidayCalendar.CacheDocument(
            source: "fixture", fetchedAt: "2026-11-10", holidays: ["2026-11-11"]
        )
        try JSONEncoder().encode(document).write(to: source)
        return (directory, source, directory.appendingPathComponent("cache.json"))
    }

    func testHolidayCacheWriteFailureDoesNotSuppressReturningToCommittedSource() async throws {
        let original = HolidayCalendar.shared
        defer { HolidayCalendar.applyResolved(original) }
        let fixture = try holidayFixture()
        // rename(file, existing directory) deterministically fails even for privileged users.
        try FileManager.default.createDirectory(at: fixture.cache, withIntermediateDirectories: true)
        var applied = 0
        let service = HolidayCalendarService(cacheURL: fixture.cache, onCalendarApplied: { applied += 1 })
        service.adoptSource(fixture.source.path)
        let message = await service.refreshNow(source: fixture.source.path)
        XCTAssertTrue(message.hasPrefix("更新成功"), "缓存写入失败仍必须应用取到的新表")
        XCTAssertEqual(HolidayCalendar.shared.source, fixture.source.path)

        service.handleConfigChange(source: "")
        let bundledApplied = await waitUntil { applied == 2 }
        XCTAssertTrue(bundledApplied)
        XCTAssertEqual(HolidayCalendar.shared, HolidayCalendar.loadBundled())
        service.handleConfigChange(source: fixture.source.path)
        let sourceRestored = await waitUntil { applied == 4 }
        XCTAssertTrue(sourceRestored, "缓存写入失败不能让本会话去重阻止恢复已保存的源")
        XCTAssertEqual(HolidayCalendar.shared.source, fixture.source.path)
        XCTAssertFalse(service.isRefreshing)
    }

    func testHolidayMissingCorruptOrEmptyCacheIsFetchedAgainAfterSourceRoundTrip() async throws {
        let original = HolidayCalendar.shared
        defer { HolidayCalendar.applyResolved(original) }
        for invalidation in ["missing", "corrupt", "empty"] {
            let fixture = try holidayFixture()
            var applied = 0
            let service = HolidayCalendarService(cacheURL: fixture.cache, onCalendarApplied: { applied += 1 })
            service.adoptSource(fixture.source.path)
            _ = await service.refreshNow(source: fixture.source.path)
            switch invalidation {
            case "missing": try FileManager.default.removeItem(at: fixture.cache)
            case "corrupt": try Data("invalid JSON".utf8).write(to: fixture.cache)
            default:
                let empty = HolidayCalendar.CacheDocument(
                    source: fixture.source.path, fetchedAt: HolidayCalendar.beijingDateString(), holidays: []
                )
                try JSONEncoder().encode(empty).write(to: fixture.cache)
            }
            service.handleConfigChange(source: "")
            let bundledApplied = await waitUntil { applied == 2 }
            XCTAssertTrue(bundledApplied, invalidation)
            service.handleConfigChange(source: fixture.source.path)
            let sourceRestored = await waitUntil { applied == 4 }
            XCTAssertTrue(sourceRestored, invalidation)
            XCTAssertEqual(HolidayCalendar.shared.source, fixture.source.path, invalidation)
            let restored = try JSONDecoder().decode(
                HolidayCalendar.CacheDocument.self, from: Data(contentsOf: fixture.cache)
            )
            XCTAssertEqual(restored.holidays, ["2026-11-11"], invalidation)
        }
    }

    func testHolidayFreshSameSourceCacheStillAvoidsAnotherFetch() async throws {
        let original = HolidayCalendar.shared
        defer { HolidayCalendar.applyResolved(original) }
        let fixture = try holidayFixture()
        var applied = 0
        let service = HolidayCalendarService(cacheURL: fixture.cache, onCalendarApplied: { applied += 1 })
        service.adoptSource(fixture.source.path)
        _ = await service.refreshNow(source: fixture.source.path)
        // A fresh cache must restore the source without attempting this now missing input.
        try FileManager.default.removeItem(at: fixture.source)
        service.handleConfigChange(source: "")
        let bundledApplied = await waitUntil { applied == 2 }
        XCTAssertTrue(bundledApplied)
        service.handleConfigChange(source: fixture.source.path)
        let cacheApplied = await waitUntil { applied == 3 }
        XCTAssertTrue(cacheApplied)
        XCTAssertEqual(HolidayCalendar.shared.source, fixture.source.path)
        XCTAssertNil(service.lastRefreshMessage, "新鲜缓存命中不应尝试取数而报源文件缺失")
    }

    func testSettingsConsumptionKeepsNewRequestQueuedDuringSelection() {
        let store = makeIsolatedConfigStore()
        let state = AppState(descriptors: [], configStore: store)
        state.stop()
        defer { state.stop() }
        state.pendingSettingsTab = .energy
        SettingsView.consumeSettingsTabRequest(.energy, state: state) { tab in
            XCTAssertEqual(tab.id, SettingsTab.energy.id)
            state.pendingSettingsTab = .sync
        }
        XCTAssertEqual(state.pendingSettingsTab?.id, SettingsTab.sync.id)
        SettingsView.consumeSettingsTabRequest(state.pendingSettingsTab, state: state) { tab in
            XCTAssertEqual(tab.id, SettingsTab.sync.id)
        }
        XCTAssertNil(state.pendingSettingsTab)
    }

    func testPlanCardEqualityChangesForEachIndependentQuotaSource() {
        let status = ProviderStatus(
            id: "codex_chatgpt", displayName: "ChatGPT", kind: .codexChatGpt,
            iconSystemName: "star", accentColor: .chatgpt, refreshIntervalSeconds: 300, state: .ready
        )
        let sources: [StatusBarQuotaSource] = [
            .plan, .apiCredit(keyID: "key-a"), .apiCredit(keyID: "key-b"),
            .activityPlan(planID: "plan-a", entitlementID: "grant-a"),
            .activityPlan(planID: "plan-a", entitlementID: "grant-b"),
        ]
        for source in sources {
            let selected = ProviderCardView(status: status, selectedStatusBarSource: source, presentation: .plan)
            XCTAssertNotEqual(selected, ProviderCardView(status: status, presentation: .plan))
            for other in sources where other != source {
                XCTAssertNotEqual(selected, ProviderCardView(
                    status: status, selectedStatusBarSource: other, presentation: .plan
                ))
            }
        }
    }

    func testDockPendingHoverCannotSelectReplacementProviderAtSameIndex() async {
        let store = makeIsolatedConfigStore()
        let state = AppState(descriptors: [], configStore: store)
        state.stop()
        let controller = EdgeDockController.shared
        controller.teardown()
        defer { controller.teardown(); state.stop() }
        controller.state = state
        controller.hasFinishedLaunching = true
        controller.applyRuntimeConfig { $0.mode = .statusWindow; $0.screenUUID = nil }
        controller.panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        // Keep layout/show out of this identity-state test; selection still uses production scheduling.
        controller.isDragging = true
        let entries = ["A", "B"].map { id in
            EdgeDockEntry(
                id: id, displayName: id, kind: .codexChatGpt, balanceAvailable: nil,
                intervalFraction: nil, rawIntervalFraction: nil, weeklyFraction: nil,
                health: nil, intervalHealth: nil, weeklyHealth: nil
            )
        }
        controller.cachedOrderedEntries = entries
        controller.hoveredIndex = 0
        controller.scheduleSelection(0)
        controller.cachedOrderedEntries = Array(entries.reversed())
        controller.reconcile(animated: false)
        let oldHoverFinished = await waitUntil { !controller.selectionTask.isPending }
        XCTAssertTrue(oldHoverFinished)
        XCTAssertNil(controller.selectedProviderID, "A 的挂起 hover 不能因为重排就选择同下标的 B")

        controller.scheduleSelection(0)
        let newHoverFinished = await waitUntil { controller.selectedProviderID == "B" }
        XCTAssertTrue(newHoverFinished, "重排后的新 hover 仍能选择当前真实 provider")
        XCTAssertEqual(controller.selectedIndex, 0)
    }
}
