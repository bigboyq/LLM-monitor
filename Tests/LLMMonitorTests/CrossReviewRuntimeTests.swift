import Combine
import XCTest
@testable import LLM_monitor

final class CrossReviewRuntimeTests: StateTestCase {
    private struct CountingFetcher: QuotaFetcher {
        let providerID: String
        let displayName = "Cross review"
        let kind = ProviderKind.minimaxTokenPlan
        let calls: CallCounter

        func hasLocalAuth() -> Bool { true }
        func fetch(mode: RefreshMode) async throws -> QuotaInfo {
            await calls.tickCalled(mode: mode)
            return QuotaInfo(models: [], resetCredits: nil, planLabel: nil,
                             accountEmail: nil, codexUsageDetails: nil, fetchedAt: Date())
        }
    }

    @MainActor
    func testQueuedConfigPublicationCannotRestartStoppedServicesAndRestartUsesLatestConfig() async throws {
        let store = makeIsolatedConfigStore()
        let providerID = "cross-review-lifecycle"
        var config = store.config
        config.providers = [providerID: ProviderConfig(enabled: false, apiKey: "review-key")]
        try store.applyAndSave(config)
        let calls = CallCounter()
        let descriptor = FetcherDescriptor(
            id: providerID, displayName: "Cross review", kind: .minimaxTokenPlan,
            iconSystemName: "circle", accentColor: .minimax,
            makeFetcher: { _ in CountingFetcher(providerID: providerID, calls: calls) }
        )
        let state = AppState(descriptors: [descriptor], configStore: store)
        defer { state.stop() }
        state.localUsage.testReconcilePass = { _ in }

        config.providers[providerID]?.enabled = true
        try store.applyAndSave(config)
        // The Combine delivery is queued on RunLoop.main; stop wins before it runs.
        state.stop()
        try await Task.sleep(for: .milliseconds(100))
        let stoppedCalls = await calls.calls
        XCTAssertEqual(stoppedCalls, 0)
        XCTAssertNil(state.nextRefreshAt)
        XCTAssertFalse(state.isRefreshJobActive)

        // Its watcher must also stay stopped: a later external write is not loaded.
        var diskConfig = config
        diskConfig.refreshIntervalSeconds = 1_234
        try JSONEncoder().encode(diskConfig).write(to: store.configURL, options: .atomic)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.config.refreshIntervalSeconds, config.refreshIntervalSeconds)

        state.start()
        let restarted = await waitUntil { await calls.calls > 0 }
        XCTAssertTrue(restarted, "Explicit restart must rebuild enabled statuses from the current stored config")
        let reloaded = await waitUntil { store.config.refreshIntervalSeconds == diskConfig.refreshIntervalSeconds }
        XCTAssertTrue(reloaded, "Explicit restart also restores config watching")
    }

    @MainActor
    func testStoppingInvalidatesSuccessfulFetcherThatIgnoresCancellation() async throws {
        try await assertLateSuccessIgnored(stopState: true)
    }

    @MainActor
    func testInitialConstructionDoesNotFetchHolidaysButRestartAppliesChangedSource() async throws {
        let originalCalendar = HolidayCalendar.shared
        let store = makeIsolatedConfigStore()
        let state = AppState(descriptors: [], configStore: store)
        defer { state.stop(); HolidayCalendar.applyResolved(originalCalendar) }
        state.localUsage.testReconcilePass = { _ in }
        let service = state.holidayCalendarService
        XCTAssertFalse(service.isRefreshing)
        XCTAssertNil(service.lastRefreshMessage)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(service.isRefreshing, "Initial AppState.start must only compare its seeded source")
        XCTAssertNil(service.lastRefreshMessage, "App entry, not AppState construction, owns initial holiday fetching")

        state.stop()
        let sourceURL = store.configURL.deletingLastPathComponent().appendingPathComponent("restart-holidays.json")
        let year = PeakWindow.beijingCalendar.component(.year, from: Date())
        let document = HolidayCalendar.CacheDocument(source: "fixture", fetchedAt: "2026-01-01",
                                                    holidays: ["\(year)-10-01"])
        try JSONEncoder().encode(document).write(to: sourceURL)
        var config = store.config
        config.holidaySource = sourceURL.path
        try store.applyAndSave(config)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(service.lastRefreshMessage, "Stopped config publication must not start a holiday refresh")
        state.start()
        let applied = await waitUntil { HolidayCalendar.shared.source == sourceURL.path }
        XCTAssertTrue(applied, "Restart must apply the changed holiday source, not only rebuild provider statuses")
        XCTAssertTrue(service.lastRefreshMessage?.hasPrefix("更新成功") == true)
    }

    @MainActor
    func testQueuedStartupReconcileCannotCrossStopAndRestart() async throws {
        let state = AppState(descriptors: [], configStore: makeIsolatedConfigStore())
        defer { state.stop() }
        var passes = 0
        state.localUsage.testReconcilePass = { _ in passes += 1 }
        // This schedules the empty-barrier helper without yielding to it.
        state.rescheduleAll()
        state.stop()
        state.start()
        let settled = await waitUntil { passes > 0 && !state.isRefreshJobActive }
        XCTAssertTrue(settled)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(passes, 1, "An old queued helper must not run before the new scheduler's initial empty batch")
    }

    @MainActor
    func testCancelledRefreshCannotPublishSuccessfulFetcherResult() async throws {
        try await assertLateSuccessIgnored(stopState: false)
    }

    @MainActor
    private func assertLateSuccessIgnored(stopState: Bool) async throws {
        let store = makeIsolatedConfigStore()
        let providerID = "cross-review-late-success"
        var config = store.config
        config.providers = [providerID: ProviderConfig(enabled: true, apiKey: "review-key")]
        try store.applyAndSave(config)
        let fetcher = BlockingRefreshFetcher()
        let descriptor = FetcherDescriptor(
            id: providerID, displayName: "Cross review", kind: .minimaxTokenPlan,
            iconSystemName: "circle", accentColor: .minimax, makeFetcher: { _ in fetcher }
        )
        let state = AppState(descriptors: [descriptor], configStore: store)
        state.stop() // Freeze the automatic scheduler; direct seam exercises the owned fetch.
        defer { state.stop() }
        let previous = QuotaInfo(models: [], resetCredits: nil, planLabel: "previous",
            accountEmail: nil, codexUsageDetails: nil, fetchedAt: Date(timeIntervalSince1970: 123))
        state.mutateStatus(for: providerID) { $0.state = .ok(previous) }
        let task = Task { await state.refreshProviderDirectly(providerID: providerID, mode: .full) }
        await fetcher.gate.waitUntilReached()
        if stopState { state.stop() } else { task.cancel() }
        await fetcher.gate.release()
        let outcome = await task.value
        XCTAssertEqual(outcome, .deferred)
        XCTAssertEqual(state.statuses.first?.lastSuccess, previous)
        XCTAssertNil(state.nextRefreshAt)
    }

    @MainActor
    private final class GenerationProbe {
        var generation: UInt64 = 1
        var reads = 0
        var publications = 0
        var cancellation: Task<Void, Never>?

        func read() -> UInt64 {
            reads += 1
            if reads == 2 {
                // On the old two-hop path this MainActor job ran before apply.
                // On the fixed path validation and apply finish in the same turn.
                cancellation = Task { @MainActor in self.generation += 1 }
            }
            return generation
        }

        func published() {
            XCTAssertEqual(generation, 1, "Final generation validation and publication must be atomic on MainActor")
            publications += 1
        }
    }

    private struct ScanFailure: LocalizedError {
        var errorDescription: String? { "controlled scan failure" }
    }

    @MainActor
    private final class PartialScanner: LocalUsageScannerBase<Int>, @unchecked Sendable {
        init() { super.init(logTag: "[cross-review-partial]", cachedResult: 10) }
        override func makeWork(startedGeneration: UInt64) -> @Sendable () async throws -> Int {
            { 5 }
        }
        override nonisolated func scanResultIsComplete(_ result: Int) -> Bool { false }
    }

    @MainActor
    func testPartialResultIsAlreadyUnavailableWhenCoordinatorPublishesItInline() async throws {
        let scanner = PartialScanner()
        var freshness = LocalUsageFreshness.clean
        var partialPublicationFreshness: LocalUsageFreshness?
        var validations = 0
        let coordinator = LocalUsageCoordinator<Int>(
            providerID: "partial", logTag: "cross-review", makeScanner: { scanner },
            apply: { result in
                if result == 5 { partialPublicationFreshness = freshness }
            },
            onDirty: { freshness = .dirty }, onFresh: { freshness = .clean },
            onFailed: { freshness = .failed }, onValidatedResult: { validations += 1 }
        )
        defer { coordinator.cancelInFlight() }
        coordinator.trigger(mode: .dirty, markDirty: false)
        try await coordinator.waitUntilSettled()
        XCTAssertEqual(partialPublicationFreshness, .failed,
                       "A synchronous status/Fleet observer must never read a partial snapshot tagged healthy")
        XCTAssertEqual(validations, 0)
        XCTAssertEqual(freshness, .failed)
    }

    @MainActor
    func testScannerResultValidationAndPublicationShareOneActorTurn() async {
        let probe = GenerationProbe()
        await LocalUsageScanRunner.run(
            logTag: "[cross-review]", startedGeneration: 1,
            latestGeneration: { probe.read() }, work: { 42 },
            applyResult: { _ in probe.published() }, applyError: { _ in XCTFail("Unexpected error") }
        )
        await probe.cancellation?.value
        XCTAssertEqual(probe.publications, 1)
        XCTAssertEqual(probe.generation, 2)
    }

    @MainActor
    func testScannerErrorValidationAndPublicationShareOneActorTurn() async {
        let probe = GenerationProbe()
        await LocalUsageScanRunner.run(
            logTag: "[cross-review]", startedGeneration: 1,
            latestGeneration: { probe.read() }, work: { () async throws -> Int in throw ScanFailure() },
            applyResult: { _ in XCTFail("Unexpected result") }, applyError: { _ in probe.published() }
        )
        await probe.cancellation?.value
        XCTAssertEqual(probe.publications, 1)
        XCTAssertEqual(probe.generation, 2)
    }
}
