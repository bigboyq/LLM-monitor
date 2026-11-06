import XCTest
import Foundation
import CoreGraphics
import AppKit
@testable import LLM_monitor

/// Adversarial empirical challenge suite for Milestone 2:
/// Floating Window Per-Provider Refresh & Hit-Testing Boundaries.
final class EdgeDockRefreshAdversarialTests: StateTestCase {

    // MARK: - Test Doubles

    private final class AdversarialSpyFetcher: QuotaFetcher, @unchecked Sendable {
        let providerID: String
        let displayName: String
        let kind: ProviderKind
        private let lock = NSLock()
        private var _callCount = 0

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _callCount
        }

        private func incrementCallCount() {
            lock.lock()
            _callCount += 1
            lock.unlock()
        }

        init(providerID: String, kind: ProviderKind = .codexChatGpt) {
            self.providerID = providerID
            self.displayName = providerID
            self.kind = kind
        }

        func fetch(mode: RefreshMode) async throws -> QuotaInfo {
            incrementCallCount()

            return QuotaInfo(
                models: [
                    ModelQuota(
                        modelName: "\(providerID)_model",
                        intervalTotalCount: 100,
                        intervalUsageCount: 10,
                        intervalRemainingPercent: 90,
                        intervalStatus: .present,
                        intervalResetsAt: Date().addingTimeInterval(3600),
                        intervalWindowSeconds: 3600,
                        weeklyTotalCount: 500,
                        weeklyUsageCount: 50,
                        weeklyRemainingPercent: 90,
                        weeklyStatus: .present,
                        weeklyResetsAt: Date().addingTimeInterval(86400 * 7),
                        weeklyWindowSeconds: 86400 * 7
                    )
                ],
                resetCredits: nil,
                planLabel: "\(providerID)_plan",
                accountEmail: "\(providerID)@test.com",
                codexUsageDetails: nil,
                fetchedAt: Date()
            )
        }

        func hasLocalAuth() -> Bool { true }
        func checkLocalAuth() async -> Bool { true }
    }

    @MainActor
    private func makeAdversarialState(
        fetchers: [AdversarialSpyFetcher]
    ) async -> (AppState, ConfigStore) {
        let store = makeIsolatedConfigStore()
        var config = store.config
        config.refreshIntervalSeconds = 300
        for f in fetchers {
            config.providers[f.providerID] = ProviderConfig(
                enabled: true,
                apiKey: "sk-adv-test-key",
                authPath: store.configURL.deletingLastPathComponent().appendingPathComponent("auth.json").path
            )
        }
        try! store.applyAndSave(config)

        let descriptors = fetchers.map { f in
            FetcherDescriptor(
                id: f.providerID,
                displayName: f.displayName,
                kind: f.kind,
                iconSystemName: "star",
                accentColor: .chatgpt,
                makeFetcher: { _ in f }
            )
        }

        let state = AppState(descriptors: descriptors, configStore: store)
        state.localUsage.testReadinessOverride = { _ in false }

        // Quiesce initial startup
        await waitUntil(timeout: 3.0) {
            fetchers.allSatisfy { $0.callCount >= 1 }
        }
        await waitUntil(timeout: 3.0) {
            guard let token = state.refreshScheduler?.beginExternalJob() else { return false }
            state.refreshScheduler?.endExternalJob(token)
            return true
        }

        return (state, store)
    }

    // MARK: - Task 1: Drag Threshold Boundary (<4pt triggers refresh, >=4pt repositions)

    @MainActor
    func testSubThresholdDisplacementsTriggerRefreshAndResetDragState() async {
        let fetcherA = AdversarialSpyFetcher(providerID: "prov_sub_a")
        let fetcherB = AdversarialSpyFetcher(providerID: "prov_sub_b")
        let (state, store) = await makeAdversarialState(fetchers: [fetcherA, fetcherB])
        defer { state.stop() }

        let controller = EdgeDockController.shared
        controller.attach(state: state, configStore: store)
        controller.applyRuntimeConfig {
            $0.mode = .statusWindow
            $0.edge = .right
        }
        let entries = [
            EdgeDockEntry(id: "prov_sub_a", displayName: "A", kind: .codexChatGpt, balanceAvailable: nil, intervalFraction: 0.5, rawIntervalFraction: 0.5, weeklyFraction: 0.5, health: .healthy, intervalHealth: .healthy, weeklyHealth: .healthy),
            EdgeDockEntry(id: "prov_sub_b", displayName: "B", kind: .codexChatGpt, balanceAvailable: nil, intervalFraction: 0.5, rawIntervalFraction: 0.5, weeklyFraction: 0.5, health: .healthy, intervalHealth: .healthy, weeklyHealth: .healthy)
        ]
        controller.cachedOrderedEntries = entries

        let panel = NSPanel()
        panel.setContentSize(CGSize(width: 46, height: 160))
        panel.setFrame(CGRect(x: 1800, y: 500, width: 46, height: 160), display: false)
        controller.panel = panel
        defer {
            controller.hidePopover()
            controller.selectedIndex = nil
            controller.hoveredIndex = nil
            controller.cachedOrderedEntries = nil
            controller.panel = nil
        }

        let circles = EdgeDockGeometry.circleRects(dockFrame: panel.frame, edge: .right, entryCount: 2)
        XCTAssertEqual(circles.count, 2)
        let centerA = CGPoint(x: circles[0].midX, y: circles[0].midY)

        // Helper to wait until external job completes
        func waitJobSettled() async {
            await waitUntil(timeout: 2.0) {
                guard let token = state.refreshScheduler?.beginExternalJob() else { return false }
                state.refreshScheduler?.endExternalJob(token)
                return true
            }
        }

        // 1. Sub-threshold: 0.0pt displacement (pure click on circle center)
        var baselineA = fetcherA.callCount
        controller.isDragging = true
        controller.pressBecameDrag = false
        controller.pressScreenLocation = centerA
        controller.dragMoved(at: centerA) // hypot = 0.0 < 4.0
        XCTAssertFalse(controller.pressBecameDrag, "0pt displacement must not become drag")
        controller.finishPressOrDrag(at: centerA)
        XCTAssertFalse(controller.isDragging, "Drag state must be cancelled")
        XCTAssertNil(controller.dragOffset, "dragOffset must be nil")

        await waitUntil(timeout: 2.0) { fetcherA.callCount == baselineA + 1 }
        XCTAssertEqual(fetcherA.callCount, baselineA + 1, "0pt click must trigger refresh")
        await waitJobSettled()

        // 2. Sub-threshold: 1.0pt displacement
        baselineA = fetcherA.callCount
        let pt1 = CGPoint(x: centerA.x + 1.0, y: centerA.y)
        controller.isDragging = true
        controller.pressBecameDrag = false
        controller.pressScreenLocation = centerA
        controller.dragMoved(at: pt1) // hypot = 1.0 < 4.0
        XCTAssertFalse(controller.pressBecameDrag, "1.0pt displacement must not become drag")
        controller.finishPressOrDrag(at: pt1)
        XCTAssertFalse(controller.isDragging)
        XCTAssertNil(controller.dragOffset)

        await waitUntil(timeout: 2.0) { fetcherA.callCount == baselineA + 1 }
        XCTAssertEqual(fetcherA.callCount, baselineA + 1, "1.0pt displacement click must trigger refresh")
        await waitJobSettled()

        // 3. Sub-threshold: 3.9pt displacement
        baselineA = fetcherA.callCount
        let pt39 = CGPoint(x: centerA.x, y: centerA.y + 3.9)
        controller.isDragging = true
        controller.pressBecameDrag = false
        controller.pressScreenLocation = centerA
        controller.dragMoved(at: pt39) // hypot = 3.9 < 4.0
        XCTAssertFalse(controller.pressBecameDrag, "3.9pt displacement must not become drag")
        controller.finishPressOrDrag(at: pt39)
        XCTAssertFalse(controller.isDragging)
        XCTAssertNil(controller.dragOffset)

        await waitUntil(timeout: 2.0) { fetcherA.callCount == baselineA + 1 }
        XCTAssertEqual(fetcherA.callCount, baselineA + 1, "3.9pt displacement click must trigger refresh")
        await waitJobSettled()

        // 4. Sub-threshold: 3.999pt displacement (tight lower boundary)
        baselineA = fetcherA.callCount
        let pt3999 = CGPoint(x: centerA.x + 3.999, y: centerA.y)
        controller.isDragging = true
        controller.pressBecameDrag = false
        controller.pressScreenLocation = centerA
        controller.dragMoved(at: pt3999) // hypot = 3.999 < 4.0
        XCTAssertFalse(controller.pressBecameDrag, "3.999pt displacement must not become drag")
        controller.finishPressOrDrag(at: pt3999)
        XCTAssertFalse(controller.isDragging)
        XCTAssertNil(controller.dragOffset)

        await waitUntil(timeout: 2.0) { fetcherA.callCount == baselineA + 1 }
        XCTAssertEqual(fetcherA.callCount, baselineA + 1, "3.999pt displacement click must trigger refresh")
        await waitJobSettled()
    }

    @MainActor
    func testThresholdAndSuperThresholdDisplacementsStrictlyRepositionWithoutRefresh() async {
        let fetcherA = AdversarialSpyFetcher(providerID: "prov_sup_a")
        let fetcherB = AdversarialSpyFetcher(providerID: "prov_sup_b")
        let (state, store) = await makeAdversarialState(fetchers: [fetcherA, fetcherB])
        defer { state.stop() }

        let controller = EdgeDockController.shared
        controller.attach(state: state, configStore: store)
        controller.applyRuntimeConfig {
            $0.mode = .statusWindow
            $0.edge = .right
        }
        let entries = [
            EdgeDockEntry(id: "prov_sup_a", displayName: "A", kind: .codexChatGpt, balanceAvailable: nil, intervalFraction: 0.5, rawIntervalFraction: 0.5, weeklyFraction: 0.5, health: .healthy, intervalHealth: .healthy, weeklyHealth: .healthy),
            EdgeDockEntry(id: "prov_sup_b", displayName: "B", kind: .codexChatGpt, balanceAvailable: nil, intervalFraction: 0.5, rawIntervalFraction: 0.5, weeklyFraction: 0.5, health: .healthy, intervalHealth: .healthy, weeklyHealth: .healthy)
        ]
        controller.cachedOrderedEntries = entries
        let panel = NSPanel()
        panel.setContentSize(CGSize(width: 46, height: 160))
        panel.setFrame(CGRect(x: 1800, y: 500, width: 46, height: 160), display: false)
        controller.panel = panel
        defer {
            controller.hidePopover()
            controller.selectedIndex = nil
            controller.hoveredIndex = nil
            controller.cachedOrderedEntries = nil
            controller.panel = nil
        }

        let circles = EdgeDockGeometry.circleRects(dockFrame: panel.frame, edge: .right, entryCount: 2)
        let centerA = CGPoint(x: circles[0].midX, y: circles[0].midY)
        let baselineA = fetcherA.callCount
        let baselineB = fetcherB.callCount

        // 1. Boundary: Exactly 4.0pt displacement (hypot == 4.0 >= dragThreshold)
        let pt40 = CGPoint(x: centerA.x + 4.0, y: centerA.y)
        controller.isDragging = true
        controller.pressBecameDrag = false
        controller.pressScreenLocation = centerA
        controller.dragMoved(at: pt40)
        XCTAssertTrue(controller.pressBecameDrag, "4.0pt displacement must become drag")
        XCTAssertNotNil(controller.dragOffset, "dragOffset must be populated")

        controller.finishPressOrDrag(at: pt40)
        XCTAssertFalse(controller.isDragging, "Drag state must be cleared")
        XCTAssertNil(controller.dragOffset, "dragOffset must be reset to nil")

        // Wait to ensure no delayed task executed
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fetcherA.callCount, baselineA, "4.0pt drag must NOT trigger targeted refresh")
        XCTAssertEqual(fetcherB.callCount, baselineB, "Other providers must NOT be refreshed")

        // 2. Boundary: 4.001pt displacement
        let pt4001 = CGPoint(x: centerA.x, y: centerA.y + 4.001)
        controller.isDragging = true
        controller.pressBecameDrag = false
        controller.pressScreenLocation = centerA
        controller.dragMoved(at: pt4001)
        XCTAssertTrue(controller.pressBecameDrag)
        XCTAssertNotNil(controller.dragOffset)

        controller.finishPressOrDrag(at: pt4001)
        XCTAssertFalse(controller.isDragging)
        XCTAssertNil(controller.dragOffset)

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fetcherA.callCount, baselineA, "4.001pt drag must NOT trigger targeted refresh")

        // 3. Super-threshold: 20.0pt displacement
        let pt20 = CGPoint(x: centerA.x, y: centerA.y - 20.0)
        controller.isDragging = true
        controller.pressBecameDrag = false
        controller.pressScreenLocation = centerA
        controller.dragMoved(at: pt20)
        XCTAssertTrue(controller.pressBecameDrag)
        XCTAssertNotNil(controller.dragOffset)

        controller.finishPressOrDrag(at: pt20)
        XCTAssertFalse(controller.isDragging)
        XCTAssertNil(controller.dragOffset)

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fetcherA.callCount, baselineA, "20pt drag must NOT trigger targeted refresh")

        // 4. Drag-and-return gesture: dragged 20pt away, then returned to centerA before mouse up
        controller.isDragging = true
        controller.pressBecameDrag = false
        controller.pressScreenLocation = centerA
        controller.dragMoved(at: pt20) // hypot = 20.0 -> becomes drag
        XCTAssertTrue(controller.pressBecameDrag)
        controller.dragMoved(at: centerA) // returned to start, but pressBecameDrag remains true
        XCTAssertTrue(controller.pressBecameDrag)

        controller.finishPressOrDrag(at: centerA)
        XCTAssertFalse(controller.isDragging)
        XCTAssertNil(controller.dragOffset)

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fetcherA.callCount, baselineA, "Drag-and-return must NOT trigger refresh")
    }

    // MARK: - Task 2: Hit-Testing on Edge Dock (Center, Boundary, Tolerance, Padding, Labels)

    func testHitTestingPrecision_Center_Boundary_Tolerance_Labels_Gaps_Padding() {
        let dock = CGRect(x: 1800, y: 500, width: 46, height: 210)
        let circles = EdgeDockGeometry.circleRects(dockFrame: dock, edge: .right, entryCount: 3)
        XCTAssertEqual(circles.count, 3)

        let center0 = CGPoint(x: circles[0].midX, y: circles[0].midY)
        let radius = circles[0].width / 2 // 19.0pt

        // 1. Center click
        XCTAssertEqual(EdgeDockController.circleIndex(at: center0, circles: circles), 0)

        // 2. Interior clicks
        let innerPoint = CGPoint(x: center0.x + 10, y: center0.y - 10)
        XCTAssertEqual(EdgeDockController.circleIndex(at: innerPoint, circles: circles), 0)

        // 3. Exact boundary (radius = 19.0pt)
        let exactBoundaryPoint = CGPoint(x: center0.x + radius, y: center0.y)
        XCTAssertEqual(EdgeDockController.circleIndex(at: exactBoundaryPoint, circles: circles), 0)

        // 4. Within 0.5pt tolerance (radius + 0.49pt = 19.49pt)
        let withinTolerancePoint = CGPoint(x: center0.x, y: center0.y + radius + 0.49)
        XCTAssertEqual(EdgeDockController.circleIndex(at: withinTolerancePoint, circles: circles), 0)

        // 5. Outside tolerance (radius + 0.51pt = 19.51pt)
        let outsideTolerancePoint = CGPoint(x: center0.x, y: center0.y + radius + 0.51)
        XCTAssertNil(EdgeDockController.circleIndex(at: outsideTolerancePoint, circles: circles), "Point beyond tolerance must return nil")

        // 6. Hover scale expansion (1.10x hoverScale)
        // With hoverScale 1.10x, radius expands to 19.0 * 1.10 = 20.9pt (+ 0.5 tolerance = 21.4pt)
        let hoverScalePoint = CGPoint(x: center0.x + 20.5, y: center0.y)
        // Without hover state: nil
        XCTAssertNil(EdgeDockController.circleIndex(at: hoverScalePoint, circles: circles, currentHovered: nil))
        // With hover state on circle 0: hits 0
        XCTAssertEqual(EdgeDockController.circleIndex(at: hoverScalePoint, circles: circles, currentHovered: 0), 0)
        // With hover state on circle 1: nil
        XCTAssertNil(EdgeDockController.circleIndex(at: hoverScalePoint, circles: circles, currentHovered: 1))

        // 7. Rejection: Numerical percentage label below circle (distance 26pt)
        let labelPoint = CGPoint(x: center0.x, y: center0.y - 26)
        XCTAssertNil(EdgeDockController.circleIndex(at: labelPoint, circles: circles), "Label below circle must NOT hit circle")

        // 8. Rejection: Midpoint gap between circle 0 and circle 1
        let center1 = CGPoint(x: circles[1].midX, y: circles[1].midY)
        let midGap = CGPoint(x: dock.midX, y: (center0.y + center1.y) / 2)
        XCTAssertNil(EdgeDockController.circleIndex(at: midGap, circles: circles), "Gap between circles must NOT hit circle")

        // 9. Rejection: Dock padding / margin
        let topPadding = CGPoint(x: dock.midX, y: dock.maxY - 2)
        XCTAssertNil(EdgeDockController.circleIndex(at: topPadding, circles: circles), "Top padding must NOT hit circle")
        let bottomPadding = CGPoint(x: dock.midX, y: dock.minY + 2)
        XCTAssertNil(EdgeDockController.circleIndex(at: bottomPadding, circles: circles), "Bottom padding must NOT hit circle")
        let sideMargin = CGPoint(x: dock.minX + 2, y: center0.y)
        XCTAssertNil(EdgeDockController.circleIndex(at: sideMargin, circles: circles), "Side margin must NOT hit circle")
    }

    func testCompactModeHitTestingHonoursMinimumRadiusExpansion() {
        for size in EdgeDockCompactSize.allCases {
            let m = EdgeDockGeometry.compactMetrics(for: size)
            let compactDock = EdgeDockGeometry.dockSize(entryCount: 3, edge: .right, appearance: .compact, compactSize: size)
            let dockFrame = CGRect(x: 1800, y: 500, width: compactDock.width, height: compactDock.height)
            let step = EdgeDockGeometry.compactRowStep(for: size)
            let circles: [CGRect] = (0..<3).map { index in
                let center = CGPoint(
                    x: dockFrame.midX,
                    y: dockFrame.maxY - m.padding - m.diameter / 2 - CGFloat(index) * step
                )
                return CGRect(
                    x: center.x - m.diameter / 2,
                    y: center.y - m.diameter / 2,
                    width: m.diameter,
                    height: m.diameter
                )
            }

            let minRadius = step / 2
            let circleRadius = m.diameter / 2
            // Point outside natural circle by 1.2pt:
            let testPoint = CGPoint(x: circles[1].midX + circleRadius + 1.2, y: circles[1].midY)

            // Without minimumRadius: rejected (nil)
            XCTAssertNil(
                EdgeDockController.circleIndex(at: testPoint, circles: circles, minimumRadius: 0),
                "\(size) Without minimumRadius, point outside natural circle must be rejected"
            )

            // With minimumRadius: accepted as circle 1
            XCTAssertEqual(
                EdgeDockController.circleIndex(at: testPoint, circles: circles, minimumRadius: minRadius),
                1,
                "\(size) With minimumRadius=\(minRadius)pt, near-miss point must hit circle 1"
            )

            // Equidistant partition: point slightly closer to circle 0 vs circle 1
            let slightlyCloserTo0 = CGPoint(x: circles[0].midX, y: circles[0].midY - (step / 2 - 1.5))
            XCTAssertEqual(
                EdgeDockController.circleIndex(at: slightlyCloserTo0, circles: circles, minimumRadius: minRadius),
                0,
                "\(size) Point closer to circle 0 must hit circle 0"
            )
            let slightlyCloserTo1 = CGPoint(x: circles[1].midX, y: circles[1].midY + (step / 2 - 1.5))
            XCTAssertEqual(
                EdgeDockController.circleIndex(at: slightlyCloserTo1, circles: circles, minimumRadius: minRadius),
                1,
                "\(size) Point closer to circle 1 must hit circle 1"
            )
        }
    }

    // MARK: - Task 3: ProviderCardView (arrow.clockwise, ProgressView gating, Timestamp button)

    func testProviderStatusIsLoadingPermutations() {
        let dummyInfo = QuotaInfo(
            models: [], resetCredits: nil, planLabel: "Plan", accountEmail: "u@test.com", codexUsageDetails: nil, fetchedAt: Date()
        )

        var status = ProviderStatus(
            id: "p_test", displayName: "Test", kind: .codexChatGpt, iconSystemName: "circle", accentColor: .chatgpt, refreshIntervalSeconds: 300, state: .ready
        )
        XCTAssertFalse(status.isLoading, ".ready is not loading")

        status.state = .notConfigured(reason: "missing")
        XCTAssertFalse(status.isLoading, ".notConfigured is not loading")

        status.state = .ok(dummyInfo)
        XCTAssertFalse(status.isLoading, ".ok is not loading")

        status.state = .failed(message: "err", lastSuccess: dummyInfo)
        XCTAssertFalse(status.isLoading, ".failed is not loading")

        status.state = .loading(lastSuccess: nil)
        XCTAssertTrue(status.isLoading, ".loading(nil) is loading")

        status.state = .loading(lastSuccess: dummyInfo)
        XCTAssertTrue(status.isLoading, ".loading(info) is loading")
    }

    @MainActor
    func testConcurrentRefreshOneRapidClicksGatedByExternalJobToken() async {
        let fetcher = AdversarialSpyFetcher(providerID: "p_gate_test")
        let (state, _) = await makeAdversarialState(fetchers: [fetcher])
        defer { state.stop() }

        // Start job 1 which acquires external job token
        guard let token = state.refreshScheduler?.beginExternalJob() else {
            XCTFail("Should acquire initial job token")
            return
        }

        // While token is held, simulate 20 rapid clicks on refreshOne
        let baselineCalls = fetcher.callCount
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { @MainActor in
                    await state.refreshOne(providerID: "p_gate_test")
                }
            }
        }

        // All 20 rapid clicks were dropped by beginExternalJob()
        XCTAssertEqual(fetcher.callCount, baselineCalls, "Rapid clicks while job in-flight must be completely dropped")

        // Release job 1
        state.refreshScheduler?.endExternalJob(token)

        // Now next call to refreshOne succeeds
        await state.refreshOne(providerID: "p_gate_test")
        XCTAssertEqual(fetcher.callCount, baselineCalls + 1, "Subsequent refresh after release must succeed")
    }
}
