import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// `ProviderStatus` 的 state model（合并后的 `_lastSuccess`）。对应 `Models/ProviderStatus.swift`。
final class ProviderStatusModelTests: StateTestCase {

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
}
