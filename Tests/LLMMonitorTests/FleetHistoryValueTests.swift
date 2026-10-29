import XCTest
@testable import LLM_monitor

final class FleetHistoryValueTests: XCTestCase {
    private func bucket(
        values: [String: Double]?, entries: [FleetUsageEntry] = [], partial: Bool = false
    ) -> FleetDailyBucket {
        FleetDailyBucket(
            dayKey: "2026-10-29", totals: .zero, clientProviders: [], entries: entries,
            totalsComplete: true, modelDetailsComplete: true, sourceTruncated: false,
            valueByCurrency: values, costPartial: partial
        )
    }

    func testHistoryUsesRawBucketValueBeforeEntryFallback() throws {
        let entry = FleetUsageEntry(
            clientID: "codex", quotaProviderID: "openai", modelName: "model",
            input: 1, cacheRead: 0, output: 1, reasoning: 0,
            value: 999, currency: .cny, coverage: .full, truncated: false
        )
        let day = bucket(values: ["USD": 2], entries: [entry])
        let estimate = try XCTUnwrap(FleetUsageProjection.bucketCostEstimate(day))
        XCTAssertEqual(estimate.value, 2)
        XCTAssertEqual(estimate.currency, .usd)
        XCTAssertFalse(FleetUsageProjection.bucketCostIsPartial(day))
    }

    func testMixedCurrencyHistoryUsesExistingCNYConversionAndKeepsPartialFlag() throws {
        let day = bucket(values: ["USD": 2, "CNY": 3], partial: true)
        let estimate = try XCTUnwrap(FleetUsageProjection.bucketCostEstimate(day))
        XCTAssertEqual(estimate.value, 17)
        XCTAssertEqual(estimate.currency, .cny)
        XCTAssertTrue(FleetUsageProjection.bucketCostIsPartial(day))
    }

    func testLegacyEntryValuesRemainNumericAndPartial() throws {
        let entry = FleetUsageEntry(
            clientID: "codex", quotaProviderID: "openai", modelName: "model",
            input: 1, cacheRead: 0, output: 1, reasoning: 0,
            value: 1.25, currency: .usd, coverage: .partial, truncated: false
        )
        let day = bucket(values: nil, entries: [entry])
        XCTAssertEqual(try XCTUnwrap(FleetUsageProjection.bucketCostEstimate(day)).value, 1.25)
        XCTAssertTrue(FleetUsageProjection.bucketCostIsPartial(day))
    }

    func testUnavailableValueIsNotZero() {
        XCTAssertNil(FleetUsageProjection.bucketCostEstimate(bucket(values: [:])))
        let unsupported = bucket(values: ["EUR": 10])
        XCTAssertNil(FleetUsageProjection.bucketCostEstimate(unsupported))
        XCTAssertTrue(FleetUsageProjection.bucketCostIsPartial(unsupported))
    }
}
