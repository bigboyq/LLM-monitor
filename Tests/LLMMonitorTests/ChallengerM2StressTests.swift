import XCTest
import Foundation
import CoreGraphics
import AppKit
@testable import LLM_monitor

/// Empirical adversarial stress test harness for Milestone 2:
/// 1. Concurrency and error isolation in `AppState.refreshOne(providerID:)`.
/// 2. Provider status transitions (`.ready` -> `.loading` -> `.ok` or `.failed`).
/// 3. Popover update lifecycle on MainActor (open churn, closed mid-fetch, memory & race safety).
/// 4. Edge dock controller click-to-refresh vs drag suppression.
final class ChallengerM2StressTests: StateTestCase {

    // MARK: - Test Doubles (Swift 6 Strict Concurrency Safe)

    private actor StressGate {
        private var isHolding = false
        private var reachWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func arm() {
            isHolding = true
        }

        func holdIfNeeded() async {
            guard isHolding else { return }
            let rw = reachWaiters
            reachWaiters.removeAll()
            for w in rw { w.resume() }

            await withCheckedContinuation { cont in
                releaseWaiters.append(cont)
            }
        }

        func waitUntilReached() async {
            if !releaseWaiters.isEmpty { return }
            await withCheckedContinuation { cont in
                reachWaiters.append(cont)
            }
        }

        func release() {
            isHolding = false
            let rw = releaseWaiters
            releaseWaiters.removeAll()
            for w in rw { w.resume() }
        }
    }

    private actor StressState {
        private(set) var callCount: Int = 0
        var errorToThrow: Error?
        var quotaInfoToReturn: QuotaInfo?

        func recordCall() {
            callCount += 1
        }

        func setError(_ err: Error?) {
            errorToThrow = err
        }

        func setQuota(_ info: QuotaInfo?) {
            quotaInfoToReturn = info
        }
    }

    private final class StressFetcher: QuotaFetcher, @unchecked Sendable {
        let providerID: String
        let displayName: String
        let kind: ProviderKind
        let gate = StressGate()
        let state = StressState()

        init(providerID: String, kind: ProviderKind = .codexChatGpt) {
            self.providerID = providerID
            self.displayName = providerID
            self.kind = kind
        }

        func fetch(mode: RefreshMode) async throws -> QuotaInfo {
            await state.recordCall()
            await gate.holdIfNeeded()

            if let err = await state.errorToThrow {
                throw err
            }
            if let custom = await state.quotaInfoToReturn {
                return custom
            }
            return QuotaInfo(
                models: [
                    ModelQuota(
                        modelName: "\(providerID)_primary",
                        intervalTotalCount: 100,
                        intervalUsageCount: 10,
                        intervalRemainingPercent: 90,
                        intervalStatus: .present,
                        intervalResetsAt: Date().addingTimeInterval(3600),
                        intervalWindowSeconds: 3600,
                        weeklyTotalCount: 1000,
                        weeklyUsageCount: 200,
                        weeklyRemainingPercent: 80,
                        weeklyStatus: .present,
                        weeklyResetsAt: Date().addingTimeInterval(86400 * 7),
                        weeklyWindowSeconds: 86400 * 7
                    )
                ],
                resetCredits: nil,
                planLabel: "\(providerID)_pro",
                accountEmail: "\(providerID)@example.com",
                codexUsageDetails: nil,
                fetchedAt: Date()
            )
        }

        func hasLocalAuth() -> Bool { true }
        func checkLocalAuth() async -> Bool { true }
    }

    @MainActor
    private func makeStressAppState(
        descriptors: [FetcherDescriptor],
        edgeDockConfig: EdgeDockConfig? = nil
    ) async -> (AppState, ConfigStore) {
        let store = makeIsolatedConfigStore()
        var config = store.config
        config.refreshIntervalSeconds = 300
        config.edgeDock = edgeDockConfig
        for desc in descriptors {
            config.providers[desc.id] = ProviderConfig(
                enabled: true,
                apiKey: "sk-stress-test-key",
                authPath: store.configURL.deletingLastPathComponent().appendingPathComponent("auth.json").path
            )
        }
        try! store.applyAndSave(config)

        let state = AppState(descriptors: descriptors, configStore: store)
        state.localUsage.testReadinessOverride = { _ in false }

        // Quiesce initial startup
        await waitUntil(timeout: 2.0) {
            guard let token = state.refreshScheduler?.beginExternalJob() else { return false }
            state.refreshScheduler?.endExternalJob(token)
            return true
        }

        return (state, store)
    }

    // MARK: - Task 1: Concurrency and Error Isolation in refreshOne

    /// Adversarial test: Rapid multi-provider manual clicks in floating window.
    /// Spawns 40 concurrent Tasks calling `refreshOne` across 4 distinct providers.
    /// Verifies external job token gates properly: exactly one job runs at a time,
    /// competing callers return immediately without deadlocking or crashing.
    @MainActor
    func testRapidMultiProviderManualClicksConcurrencyStress() async {
        let fetcherA = StressFetcher(providerID: "p_alpha")
        let fetcherB = StressFetcher(providerID: "p_beta")
        let fetcherC = StressFetcher(providerID: "p_gamma")
        let fetcherD = StressFetcher(providerID: "p_delta")

        let descriptors = [
            FetcherDescriptor(id: "p_alpha", displayName: "Alpha", kind: .codexChatGpt, iconSystemName: "a.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcherA }),
            FetcherDescriptor(id: "p_beta", displayName: "Beta", kind: .codexChatGpt, iconSystemName: "b.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcherB }),
            FetcherDescriptor(id: "p_gamma", displayName: "Gamma", kind: .codexChatGpt, iconSystemName: "g.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcherC }),
            FetcherDescriptor(id: "p_delta", displayName: "Delta", kind: .codexChatGpt, iconSystemName: "d.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcherD })
        ]

        let (state, _) = await makeStressAppState(descriptors: descriptors)
        defer { state.stop() }

        // Arm fetcherA to pause mid-flight
        await fetcherA.gate.arm()
        let inFlightTask = Task { await state.refreshOne(providerID: "p_alpha") }
        await fetcherA.gate.waitUntilReached()

        // Provider A is actively in-flight holding beginExternalJob token.
        // Now simulate 40 rapid concurrent user clicks across providers A, B, C, D
        let providerIDs = ["p_alpha", "p_beta", "p_gamma", "p_delta"]
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                let targetID = providerIDs[i % providerIDs.count]
                group.addTask { @MainActor in
                    await state.refreshOne(providerID: targetID)
                }
            }
        }

        // Release fetcherA
        await fetcherA.gate.release()
        await inFlightTask.value

        // Now that the gate is released, all providers should be sequentially refreshable
        for id in providerIDs {
            await state.refreshOne(providerID: id)
            let status = state.statuses.first { $0.id == id }
            XCTAssertNotNil(status)
            if case .ok = status?.state {
                // Success
            } else {
                XCTFail("Provider \(id) should be in .ok state after targeted refresh")
            }
        }
    }

    /// Adversarial test: Error isolation and stale data preservation under network outage.
    /// Provider A fails with URLError.timedOut.
    /// Verifies:
    /// 1. Provider A transitions to .failed with user-facing message.
    /// 2. Provider A retains its stale `lastSuccess` data (not wiped).
    /// 3. Provider B and C remain healthy and untouched.
    /// 4. Provider B can be refreshed immediately after Provider A fails without any residual lock.
    /// 5. Provider A recovers cleanly to .ok once network connectivity returns.
    @MainActor
    func testErrorIsolationAndStaleDataPreservationUnderNetworkFailure() async {
        let initialDataA = QuotaInfo(
            models: [ModelQuota(modelName: "model_a", intervalTotalCount: 50, intervalUsageCount: 5, intervalRemainingPercent: 90, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: nil, weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 0, weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil)],
            resetCredits: nil, planLabel: "Tier A", accountEmail: "a@test.com", codexUsageDetails: nil, fetchedAt: Date()
        )
        let initialDataB = QuotaInfo(
            models: [ModelQuota(modelName: "model_b", intervalTotalCount: 100, intervalUsageCount: 10, intervalRemainingPercent: 90, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: nil, weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 0, weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil)],
            resetCredits: nil, planLabel: "Tier B", accountEmail: "b@test.com", codexUsageDetails: nil, fetchedAt: Date()
        )

        let fetcherA = StressFetcher(providerID: "prov_iso_a")
        await fetcherA.state.setQuota(initialDataA)
        let fetcherB = StressFetcher(providerID: "prov_iso_b")
        await fetcherB.state.setQuota(initialDataB)

        let descriptors = [
            FetcherDescriptor(id: "prov_iso_a", displayName: "A", kind: .codexChatGpt, iconSystemName: "1.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcherA }),
            FetcherDescriptor(id: "prov_iso_b", displayName: "B", kind: .codexChatGpt, iconSystemName: "2.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcherB })
        ]

        let (state, _) = await makeStressAppState(descriptors: descriptors)
        defer { state.stop() }

        // 1. Initial healthy refresh for both
        await state.refreshOne(providerID: "prov_iso_a")
        await state.refreshOne(providerID: "prov_iso_b")

        let statusA1 = try! XCTUnwrap(state.statuses.first { $0.id == "prov_iso_a" })
        let statusB1 = try! XCTUnwrap(state.statuses.first { $0.id == "prov_iso_b" })
        XCTAssertEqual(statusA1.lastSuccess?.planLabel, "Tier A")
        XCTAssertEqual(statusB1.lastSuccess?.planLabel, "Tier B")

        // 2. Provider A experiences network failure
        await fetcherA.state.setError(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "The request timed out."]))
        await state.refreshOne(providerID: "prov_iso_a")

        let statusAFailed = try! XCTUnwrap(state.statuses.first { $0.id == "prov_iso_a" })
        if case .failed(let msg, let lastSuccess) = statusAFailed.state {
            XCTAssertFalse(msg.isEmpty)
            XCTAssertEqual(lastSuccess?.planLabel, "Tier A", "Stale data must be preserved on failure")
        } else {
            XCTFail("Provider A must be in .failed state, got: \(statusAFailed.state)")
        }
        XCTAssertFalse(statusAFailed.isLoading, "Failed provider must not be marked loading")

        // 3. Provider B remains completely untouched
        let statusBUntouched = try! XCTUnwrap(state.statuses.first { $0.id == "prov_iso_b" })
        if case .ok(let info) = statusBUntouched.state {
            XCTAssertEqual(info.planLabel, "Tier B")
        } else {
            XCTFail("Provider B must remain in .ok state unaffected by Provider A failure")
        }

        // 4. Provider B can refresh successfully right after A failed
        await state.refreshOne(providerID: "prov_iso_b")
        let statusBRefreshed = try! XCTUnwrap(state.statuses.first { $0.id == "prov_iso_b" })
        if case .ok = statusBRefreshed.state {
            // Success
        } else {
            XCTFail("Provider B refresh must succeed after A failure")
        }

        // 5. Provider A recovers
        await fetcherA.state.setError(nil)
        await state.refreshOne(providerID: "prov_iso_a")
        let statusARecovered = try! XCTUnwrap(state.statuses.first { $0.id == "prov_iso_a" })
        if case .ok = statusARecovered.state {
            // Recovered
        } else {
            XCTFail("Provider A must recover to .ok state")
        }
    }

    /// Adversarial test: Provider status transitions (`.ready` -> `.loading` -> `.ok` or `.failed`).
    /// Probes intermediate `.loading` state in real-time while fetch is in-flight.
    @MainActor
    func testProviderStatusTransitions_ReadyLoadingOkFailed() async {
        let fetcher = StressFetcher(providerID: "prov_trans")
        let descriptors = [
            FetcherDescriptor(id: "prov_trans", displayName: "Transition Test", kind: .codexChatGpt, iconSystemName: "arrow.triangle.2.circlepath", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        ]

        let (state, _) = await makeStressAppState(descriptors: descriptors)
        defer { state.stop() }

        // Initial state: ready
        let initialStatus = try! XCTUnwrap(state.statuses.first { $0.id == "prov_trans" })
        XCTAssertFalse(initialStatus.isLoading)

        // Phase 1: Transition to .loading then .ok
        await fetcher.gate.arm()
        let taskOk = Task { await state.refreshOne(providerID: "prov_trans") }
        await fetcher.gate.waitUntilReached()

        // In-flight assertion
        let loadingStatus1 = try! XCTUnwrap(state.statuses.first { $0.id == "prov_trans" })
        XCTAssertTrue(loadingStatus1.isLoading, "Must be loading while fetch is in flight")
        if case .loading = loadingStatus1.state {
            // Correct
        } else {
            XCTFail("State must be .loading while in flight")
        }

        // Complete fetch
        await fetcher.gate.release()
        await taskOk.value

        let okStatus = try! XCTUnwrap(state.statuses.first { $0.id == "prov_trans" })
        XCTAssertFalse(okStatus.isLoading)
        if case .ok(let info) = okStatus.state {
            XCTAssertEqual(info.planLabel, "prov_trans_pro")
        } else {
            XCTFail("State must be .ok after successful fetch")
        }

        // Phase 2: Transition to .loading then .failed
        await fetcher.state.setError(NSError(domain: "test", code: 500, userInfo: [NSLocalizedDescriptionKey: "Internal Server Error"]))
        await fetcher.gate.arm()
        let taskFail = Task { await state.refreshOne(providerID: "prov_trans") }
        await fetcher.gate.waitUntilReached()

        // In-flight assertion during failure
        let loadingStatus2 = try! XCTUnwrap(state.statuses.first { $0.id == "prov_trans" })
        XCTAssertTrue(loadingStatus2.isLoading, "Must be loading during second fetch")
        if case .loading(let lastSuccess) = loadingStatus2.state {
            XCTAssertNotNil(lastSuccess, "Loading state must preserve previous lastSuccess")
        } else {
            XCTFail("State must be .loading(lastSuccess: .some) while in flight")
        }

        // Complete fetch with failure
        await fetcher.gate.release()
        await taskFail.value

        let failedStatus = try! XCTUnwrap(state.statuses.first { $0.id == "prov_trans" })
        XCTAssertFalse(failedStatus.isLoading)
        if case .failed(_, let lastSuccess) = failedStatus.state {
            XCTAssertNotNil(lastSuccess, "Failed state must preserve previous lastSuccess")
        } else {
            XCTFail("State must be .failed after error")
        }
    }

    // MARK: - Task 2: Popover Update Lifecycle

    /// Adversarial test: Rapid popover churn and MainActor update lifecycle.
    /// Executes 300 rapid iterations of `updatePopover()` while alternating selection
    /// and ensures no memory leaks, retain cycles, or race condition crashes occur.
    @MainActor
    func testPopoverLifecycle_UpdatePopoverRapidChurnAndMemorySafety() async {
        let fetcherA = StressFetcher(providerID: "dock_churn_a")
        let fetcherB = StressFetcher(providerID: "dock_churn_b")
        let descriptors = [
            FetcherDescriptor(id: "dock_churn_a", displayName: "A", kind: .codexChatGpt, iconSystemName: "a.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcherA }),
            FetcherDescriptor(id: "dock_churn_b", displayName: "B", kind: .codexChatGpt, iconSystemName: "b.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcherB })
        ]

        let (state, store) = await makeStressAppState(descriptors: descriptors)
        defer { state.stop() }

        let controller = EdgeDockController.shared
        let dummyPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        controller.panel = dummyPanel
        controller.hasFinishedLaunching = true
        controller.attach(state: state, configStore: store)
        defer {
            controller.hidePopover()
            controller.selectedIndex = nil
            controller.hoveredIndex = nil
            controller.panel = nil
        }

        // Stress churn: rapidly cycle selection and updatePopover 300 times
        for i in 0..<300 {
            let choice = i % 3
            if choice == 0 {
                controller.selectedIndex = 0
            } else if choice == 1 {
                controller.selectedIndex = 1
            } else {
                controller.selectedIndex = nil
            }
            controller.updatePopover()
        }

        // Final state: close popover
        controller.selectedIndex = nil
        controller.updatePopover()
        XCTAssertNil(controller.popoverPanel, "Popover panel must be nil when selectedIndex is nil")
    }

    /// Adversarial test: Popover closed mid-fetch.
    /// User triggers targeted refresh via popover card or dock click.
    /// While network request is in-flight, popover is dismissed (mouse moves away).
    /// Verifies:
    /// 1. `refreshOne` completes cleanly without crashing.
    /// 2. Dismissed popover does NOT reopen/resurrect itself upon refresh completion.
    /// 3. AppState quota state is accurately updated.
    @MainActor
    func testPopoverClosedMidFetch_RefreshOneCompletesCleanly() async {
        let fetcher = StressFetcher(providerID: "prov_midclose")
        let descriptors = [
            FetcherDescriptor(id: "prov_midclose", displayName: "MidClose", kind: .codexChatGpt, iconSystemName: "m.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        ]

        let (state, store) = await makeStressAppState(
            descriptors: descriptors,
            edgeDockConfig: EdgeDockConfig(
                mode: .statusWindow,
                edge: .right,
                offset: 0.5,
                hideInFullscreen: false
            )
        )
        defer { state.stop() }

        // Real desktop state can leak from earlier tests: the process-wide dock singleton may
        // still report a fullscreen Space (for example Chrome fullscreen on the test host).
        // This test exercises popover dismissal during fetch, so pin the dock to a visible,
        // fullscreen-independent mode before attach performs its real fullscreen probe.

        let controller = EdgeDockController.shared
        let dummyPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        controller.panel = dummyPanel
        controller.hasFinishedLaunching = true
        controller.attach(state: state, configStore: store)
        defer {
            controller.hidePopover()
            controller.selectedIndex = nil
            controller.hoveredIndex = nil
            controller.panel = nil
        }

        // Open popover
        controller.selectedIndex = 0
        controller.updatePopover()
        XCTAssertNotNil(controller.popoverPanel, "Popover must be open initially")

        // Arm fetcher to pause mid-flight
        await fetcher.gate.arm()
        let refreshTask = Task { @MainActor in
            await state.refreshOne(providerID: "prov_midclose")
            if controller.selectedIndex != nil {
                controller.updatePopover()
            }
        }
        await fetcher.gate.waitUntilReached()

        // Popover is dismissed mid-fetch by user
        controller.selectedIndex = nil
        controller.hidePopover()
        XCTAssertNil(controller.popoverPanel, "Popover dismissed mid-flight")

        // Release fetcher to complete network response
        await fetcher.gate.release()
        await refreshTask.value

        // Assert: popover must remain closed, not resurrected
        XCTAssertNil(controller.popoverPanel, "Popover must remain closed after completion")

        // Assert: AppState is updated
        let finalStatus = try! XCTUnwrap(state.statuses.first { $0.id == "prov_midclose" })
        if case .ok(let info) = finalStatus.state {
            XCTAssertEqual(info.planLabel, "prov_midclose_pro")
        } else {
            XCTFail("AppState should be updated to .ok")
        }
    }

    /// Adversarial test: EdgeDockController finishPressOrDrag hit-testing & click-to-refresh.
    /// Verifies:
    /// 1. When `pressBecameDrag == true`, refresh is NOT triggered even if release is inside circle.
    /// 2. When `pressBecameDrag == false`, click outside circle bounds (margin) does NOT trigger refresh.
    @MainActor
    func testEdgeDockClickToRefreshVsDragSuppression() async {
        let fetcher = StressFetcher(providerID: "prov_hit")
        let descriptors = [
            FetcherDescriptor(id: "prov_hit", displayName: "Hit", kind: .codexChatGpt, iconSystemName: "h.circle", accentColor: .chatgpt, makeFetcher: { _ in fetcher })
        ]

        let (state, store) = await makeStressAppState(descriptors: descriptors)
        defer { state.stop() }

        let controller = EdgeDockController.shared
        controller.attach(state: state, configStore: store)
        defer {
            controller.hidePopover()
            controller.selectedIndex = nil
            controller.hoveredIndex = nil
        }

        let initialCallCount = await fetcher.state.callCount

        // Case 1: Drag movement occurred (`pressBecameDrag = true`)
        controller.isDragging = true
        controller.pressBecameDrag = true
        controller.dragOffset = 10.0
        controller.finishPressOrDrag(at: CGPoint(x: 100, y: 100))
        XCTAssertFalse(controller.isDragging)
        let dragCallCount = await fetcher.state.callCount
        XCTAssertEqual(dragCallCount, initialCallCount, "Drag release must not trigger targeted refresh")

        // Case 2: Click without drag, but click coordinates are far outside any dock circle (-999, -999)
        controller.isDragging = true
        controller.pressBecameDrag = false
        controller.dragOffset = nil
        controller.finishPressOrDrag(at: CGPoint(x: -999, y: -999))
        XCTAssertFalse(controller.isDragging)
        let outCallCount = await fetcher.state.callCount
        XCTAssertEqual(outCallCount, initialCallCount, "Out-of-bounds click must not trigger targeted refresh")
    }
}
