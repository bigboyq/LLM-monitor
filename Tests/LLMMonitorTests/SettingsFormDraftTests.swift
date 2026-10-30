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

        // Modify alert thresholds
        draftA.alertThresholds.apiQuotaWarningPercent = 75
        XCTAssertNotEqual(draftA, draftB)
        draftA.alertThresholds = draftB.alertThresholds
        XCTAssertEqual(draftA, draftB)

        // Modify client bindings
        if !draftA.clientBindings.isEmpty {
            draftA.clientBindings[0].enabled.toggle()
            XCTAssertNotEqual(draftA, draftB)
            draftA.clientBindings[0].enabled.toggle()
            XCTAssertEqual(draftA, draftB)
        }
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
        XCTAssertEqual(draft.alertThresholds.apiQuotaWarningPercent, 80)
        XCTAssertEqual(draft.alertThresholds.apiQuotaCriticalPercent, 40)
        XCTAssertEqual(draft.alertThresholds.deepseekBalanceWarning, 15)
        XCTAssertEqual(draft.alertThresholds.deepseekBalanceCritical, 5)
    }
}
