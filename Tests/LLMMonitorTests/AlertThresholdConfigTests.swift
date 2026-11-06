import XCTest
@testable import LLM_monitor

final class AlertThresholdConfigTests: XCTestCase {

    func testDefaultValues() {
        let config = AlertThresholdConfig.default
        XCTAssertEqual(config.apiQuotaWarningPercent, 60.0)
        XCTAssertEqual(config.apiQuotaCriticalPercent, 30.0)
        XCTAssertEqual(config.deepseekBalanceWarning, 10.0)
        XCTAssertEqual(config.deepseekBalanceCritical, 3.0)
    }

    func testClampingAndOrderGuarantee() {
        // Critical must not exceed warning
        let clamped = AlertThresholdConfig(
            apiQuotaWarningPercent: 40.0,
            apiQuotaCriticalPercent: 50.0, // should clamp critical to warning = 40.0
            deepseekBalanceWarning: 5.0,
            deepseekBalanceCritical: 10.0 // should clamp critical to warning = 5.0
        )
        XCTAssertEqual(clamped.apiQuotaWarningPercent, 40.0)
        XCTAssertEqual(clamped.apiQuotaCriticalPercent, 40.0)
        XCTAssertEqual(clamped.deepseekBalanceWarning, 5.0)
        XCTAssertEqual(clamped.deepseekBalanceCritical, 5.0)
    }

    func testNormalizedProperty() {
        var unnormalized = AlertThresholdConfig.default
        unnormalized.apiQuotaWarningPercent = 30.0
        unnormalized.apiQuotaCriticalPercent = 50.0
        unnormalized.deepseekBalanceWarning = 2.0
        unnormalized.deepseekBalanceCritical = 5.0

        let normalized = unnormalized.normalized
        XCTAssertEqual(normalized.apiQuotaWarningPercent, 30.0)
        XCTAssertEqual(normalized.apiQuotaCriticalPercent, 30.0)
        XCTAssertEqual(normalized.deepseekBalanceWarning, 2.0)
        XCTAssertEqual(normalized.deepseekBalanceCritical, 2.0)
    }

    func testCodableRoundTrip() throws {
        let custom = AlertThresholdConfig(
            apiQuotaWarningPercent: 75.0,
            apiQuotaCriticalPercent: 25.0,
            deepseekBalanceWarning: 20.0,
            deepseekBalanceCritical: 5.0
        )
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(AlertThresholdConfig.self, from: data)
        XCTAssertEqual(decoded, custom)
    }

    func testTolerantDecodingOfEmptyObject() throws {
        let json = "{}"
        let decoded = try JSONDecoder().decode(AlertThresholdConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, AlertThresholdConfig.default)
    }

    func testCustomThresholdsOnModelQuotaColorLevel() {
        let custom = AlertThresholdConfig(
            apiQuotaWarningPercent: 70.0,
            apiQuotaCriticalPercent: 40.0,
            deepseekBalanceWarning: 10.0,
            deepseekBalanceCritical: 3.0
        )

        // With timeFraction = nil:
        // >= 70% is healthy
        XCTAssertEqual(custom.colorLevel(percent: 75.0, timeFraction: nil), .healthy)
        // < 70% and >= 40% is warning
        XCTAssertEqual(custom.colorLevel(percent: 50.0, timeFraction: nil), .warning)
        // < 40% is critical
        XCTAssertEqual(custom.colorLevel(percent: 35.0, timeFraction: nil), .critical)
    }

    func testDeepSeekBalanceAlertHealthLevel() {
        let thresholds = AlertThresholdConfig(
            apiQuotaWarningPercent: 60.0,
            apiQuotaCriticalPercent: 30.0,
            deepseekBalanceWarning: 10.0,
            deepseekBalanceCritical: 3.0
        )

        func makeDeepSeekStatus(totalBalance: Double) -> ProviderStatus {
            let balance = DeepseekBalanceDetail(
                currency: "CNY",
                total: totalBalance,
                toppedUp: totalBalance,
                granted: 0
            )
            return ProviderStatus(
                id: "deepseek",
                displayName: "DeepSeek",
                kind: .deepseek,
                iconSystemName: "brain",
                accentColor: .deepseek,
                refreshIntervalSeconds: 60,
                state: .ok(QuotaInfo(
                    models: [],
                    resetCredits: nil,
                    planLabel: nil,
                    accountEmail: nil,
                    codexUsageDetails: nil,
                    fetchedAt: Date(),
                    balanceDetail: balance
                ))
            )
        }

        let healthyStatus = makeDeepSeekStatus(totalBalance: 25.0)
        XCTAssertEqual(healthyStatus.aggregateHealthLevel(alertThresholds: thresholds), .healthy)

        let warningStatus = makeDeepSeekStatus(totalBalance: 8.5)
        XCTAssertEqual(warningStatus.aggregateHealthLevel(alertThresholds: thresholds), .warning)

        let criticalStatus = makeDeepSeekStatus(totalBalance: 2.0)
        XCTAssertEqual(criticalStatus.aggregateHealthLevel(alertThresholds: thresholds), .critical)
    }

    func testDeepseekHealthLevelDirectMethod() {
        let thresholds = AlertThresholdConfig.default
        XCTAssertEqual(thresholds.deepseekHealthLevel(balance: nil), .critical)
        XCTAssertEqual(thresholds.deepseekHealthLevel(balance: -1.0), .critical)
        XCTAssertEqual(thresholds.deepseekHealthLevel(balance: 0.0), .critical)
        XCTAssertEqual(thresholds.deepseekHealthLevel(balance: 2.5), .critical)
        XCTAssertEqual(thresholds.deepseekHealthLevel(balance: 5.0), .warning)
        XCTAssertEqual(thresholds.deepseekHealthLevel(balance: 15.0), .healthy)
    }
}
