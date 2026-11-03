import XCTest
@testable import LLM_monitor

final class SettingsFormDraftTests: XCTestCase {

    func testDraftEqualityAndDirtyCheck() {
        var draftA = SettingsFormDraft()
        let draftB = SettingsFormDraft()
        XCTAssertEqual(draftA, draftB)

        // Modify interval
        draftA.globalInterval = 600
        XCTAssertNotEqual(draftA, draftB)

        // Reset
        draftA.globalInterval = draftB.globalInterval
        XCTAssertEqual(draftA, draftB)

        // Modify periodicFullEveryN
        draftA.periodicFullEveryN = 10
        XCTAssertNotEqual(draftA, draftB)
        draftA.periodicFullEveryN = draftB.periodicFullEveryN
        XCTAssertEqual(draftA, draftB)

        // Modify alert thresholds
        draftA.alertThresholds.apiQuotaWarningPercent = 75
        XCTAssertNotEqual(draftA, draftB)
        draftA.alertThresholds = draftB.alertThresholds
        XCTAssertEqual(draftA, draftB)
    }

    func testDraftInitFromConfig() {
        var config = AppConfig(refreshIntervalSeconds: 420, providers: [:])
        config.alerts = AlertThresholdConfig(
            apiQuotaWarningPercent: 80,
            apiQuotaCriticalPercent: 40,
            deepseekBalanceWarning: 15,
            deepseekBalanceCritical: 5
        )
        let draft = SettingsFormDraft(from: config, descriptors: [])
        XCTAssertEqual(draft.globalInterval, 420)
        XCTAssertEqual(draft.periodicFullEveryN, 20)
        XCTAssertEqual(draft.alertThresholds.apiQuotaWarningPercent, 80)
        XCTAssertEqual(draft.alertThresholds.apiQuotaCriticalPercent, 40)
        XCTAssertEqual(draft.alertThresholds.deepseekBalanceWarning, 15)
        XCTAssertEqual(draft.alertThresholds.deepseekBalanceCritical, 5)

        config.periodicFullEveryN = 8
        let draftCustom = SettingsFormDraft(from: config, descriptors: [])
        XCTAssertEqual(draftCustom.periodicFullEveryN, 8)
    }

    @MainActor
    func testPeriodicFullEveryNSchedulerUpdate() {
        let scheduler = ProviderRefreshScheduler(
            refreshHandler: { _, _ in .deferred },
            intervalProvider: { _ in 300 },
            periodicFullEveryN: 15
        )
        XCTAssertEqual(scheduler.periodicFullEveryN, 15)

        scheduler.updatePeriodicFullEveryN(30)
        XCTAssertEqual(scheduler.periodicFullEveryN, 30)

        // 负数归一化为 0
        scheduler.updatePeriodicFullEveryN(-5)
        XCTAssertEqual(scheduler.periodicFullEveryN, 0)
    }

    func testSecondaryInfoFrequencyNormalizesConfigBeforeEditing() throws {
        for (configured, expected) in [(-1, 1), (0, 1), (1, 1), (30, 30), (31, 30), (100, 30)] {
            let json = """
            {"refreshIntervalSeconds":180,"providers":{},"periodicFullEveryN":\(configured)}
            """
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
            let draft = SettingsFormDraft(from: config, descriptors: [])
            XCTAssertEqual(config.effectivePeriodicFullEveryN, expected)
            XCTAssertEqual(draft.periodicFullEveryN, expected)
        }
    }

    func testSecondaryInfoEstimateUsesProviderOverrideOrDefaultInterval() {
        var draft = SettingsFormDraft()
        draft.globalInterval = 180
        draft.periodicFullEveryN = 2
        XCTAssertEqual(draft.secondaryInfoRefreshInterval(), 360)
        XCTAssertEqual(draft.secondaryInfoRefreshInterval(providerInterval: 60), 120)
        XCTAssertEqual(draft.secondaryInfoRefreshInterval(providerInterval: 0), 360)

        draft.periodicFullEveryN = 1
        XCTAssertEqual(draft.secondaryInfoRefreshInterval(providerInterval: 60), 60)
        XCTAssertEqual(draft.secondaryInfoRefreshInterval(providerInterval: 1), 10)
        XCTAssertEqual(
            draft.secondaryInfoRefreshInterval(providerInterval: Int.max),
            AppConfig.maximumRefreshIntervalSeconds
        )
    }
}
