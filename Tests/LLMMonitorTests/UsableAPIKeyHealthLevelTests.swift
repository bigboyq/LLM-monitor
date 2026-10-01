import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// 可用 API Key 判定与三色健康度档位的合并口径测试。
final class UsableAPIKeyHealthLevelTests: StateTestCase {

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
}
