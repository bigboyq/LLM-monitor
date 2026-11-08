import XCTest
@testable import LLM_monitor

final class UsageHistorySeriesTests: XCTestCase {
    private struct Daily: LocalUsageDaily {
        let dayStart: Date
        let input: Int
        let cacheRead: Int
        let cacheWrite: Int
        let output: Int
        let reasoning: Int
        let turns: Int
        let rounds: Int
        var id: Date { dayStart }
    }

    private let calendar = Calendar(identifier: .gregorian)

    func testRateAxisKeepsMinMaxPrecisionAndProviderBounds() {
        let narrow = UsageHistoryRateAxis.bounds(for: .hit, values: [0.498, 0.502])
        XCTAssertEqual(narrow.lowerBound, 0.498, accuracy: 0.000001)
        XCTAssertEqual(narrow.upperBound, 0.502, accuracy: 0.000001)
        XCTAssertEqual(UsageHistoryRateAxis.label(narrow.lowerBound, bounds: narrow), "49.8%")
        XCTAssertEqual(UsageHistoryRateAxis.label((narrow.lowerBound + narrow.upperBound) / 2, bounds: narrow), "50.0%")
        XCTAssertEqual(UsageHistoryRateAxis.label(narrow.upperBound, bounds: narrow), "50.2%")

        let fullHit = UsageHistoryRateAxis.bounds(for: .hit, values: [1])
        XCTAssertEqual(fullHit.upperBound, 1, accuracy: 0.000001, "hit share cannot exceed 100%")
        let fullThinking = UsageHistoryRateAxis.bounds(for: .thinking, values: [1])
        XCTAssertEqual(fullThinking.upperBound, 1, accuracy: 0.000001, "thinking share cannot exceed 100%")

        for constant in [0.99, 0.9] {
            let bounded = UsageHistoryRateAxis.bounds(for: .hit, values: [constant])
            XCTAssertLessThan(bounded.lowerBound, bounded.upperBound, "bounded constant must retain a drawable range")
            XCTAssertEqual(bounded.upperBound, 1, accuracy: 0.000001, "bounded padding must stop at 100%")
        }
        let slightlyChanging = UsageHistoryRateAxis.bounds(for: .thinking, values: [0.899, 0.901])
        XCTAssertLessThan(slightlyChanging.lowerBound, slightlyChanging.upperBound)
        XCTAssertEqual(slightlyChanging.lowerBound, 0.899, accuracy: 0.000001)
        XCTAssertEqual(slightlyChanging.upperBound, 0.901, accuracy: 0.000001)

        let output = UsageHistoryRateAxis.bounds(for: .outputRatio, values: [1.4, 1.8])
        XCTAssertEqual(output.lowerBound, 1.4, accuracy: 0.000001)
        XCTAssertEqual(output.upperBound, 1.8, accuracy: 0.000001, "output-to-input can exceed 100%")
        XCTAssertEqual(UsageHistoryRateAxis.label(output.upperBound, bounds: output), "180%")
    }

    func testBuildsSevenSlotsAndTotalExcludesCacheWrite() throws {
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let days = [Daily(
            dayStart: yesterday,
            input: 10,
            cacheRead: 20,
            cacheWrite: 999,
            output: 30,
            reasoning: 40,
            turns: 5,
            rounds: 8
        )]

        let series = UsageHistorySeriesBuilder.build(
            days: days,
            costByDay: [:],
            speedByDay: [:],
            samplesTruncated: false,
            calendar: calendar,
            now: today
        )

        XCTAssertEqual(series.count, 7)
        XCTAssertNil(series[0].total, "Missing day must remain a gap, not synthetic zero")
        XCTAssertEqual(series[5].total, 100, "Total is the four accounting buckets and excludes cache-write")
        XCTAssertEqual(series[5].rounds, 8)
        XCTAssertEqual(series[5].turns, 5)
        XCTAssertEqual(try XCTUnwrap(series[5].hitRate), 20.0 / 30.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(series[5].thinkingShare), 40.0 / 70.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(series[5].outputToInputRate), 70.0 / 30.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(series[5].value(for: .hit)), 20.0 / 30.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(series[5].value(for: .thinking)), 40.0 / 70.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(series[5].value(for: .outputRatio)), 70.0 / 30.0, accuracy: 0.0001)
        XCTAssertTrue(series[6].isTodayIncomplete)
        XCTAssertNil(series[6].total)
        XCTAssertNil(series[6].hitRate)
        XCTAssertNil(series[6].thinkingShare)
        XCTAssertNil(series[6].outputToInputRate)
    }

    func testKnownEmptyDailyRowIsZeroAndNumericCostPartialIsPreserved() throws {
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29)))
        let cnyEstimate = ModelCostEstimate(
            value: 1.25,
            currency: ModelPriceCurrency.cny,
            pricedModelNames: ["model"],
            unpricedModelNames: []
        )
        let row = Daily(
            dayStart: today,
            input: 0,
            cacheRead: 0,
            cacheWrite: 0,
            output: 0,
            reasoning: 0,
            turns: 0,
            rounds: 0
        )

        let series = UsageHistorySeriesBuilder.build(
            days: [row],
            costByDay: [today: cnyEstimate],
            speedByDay: [:],
            samplesTruncated: false,
            partialCostDays: [today],
            calendar: calendar,
            now: today
        )

        XCTAssertEqual(series[6].total, 0)
        XCTAssertEqual(series[6].value, 1.25)
        XCTAssertEqual(series[6].currency, ModelPriceCurrency.cny)
        XCTAssertTrue(series[6].valueIsPartial)
    }

    func testMixedDailyCurrenciesShareCNYAxis() throws {
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29)))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let costs = [
            today: ModelCostEstimate(value: 2, currency: ModelPriceCurrency.usd, pricedModelNames: [], unpricedModelNames: []),
            yesterday: ModelCostEstimate(value: 3, currency: ModelPriceCurrency.cny, pricedModelNames: [], unpricedModelNames: []),
        ]

        let series = UsageHistorySeriesBuilder.build(
            days: [Daily](),
            costByDay: costs,
            speedByDay: [:],
            samplesTruncated: false,
            calendar: calendar,
            now: today
        )

        XCTAssertEqual(series[5].value, 3)
        XCTAssertEqual(series[5].currency, ModelPriceCurrency.cny)
        XCTAssertEqual(series[6].value, 14)
        XCTAssertEqual(series[6].currency, ModelPriceCurrency.cny)
    }

    func testCurrencyOutsideVisibleWindowDoesNotChangeTheSevenDayAxis() throws {
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29)))
        let outsideWindow = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: today))
        let costs = [
            today: ModelCostEstimate(value: 2, currency: ModelPriceCurrency.usd, pricedModelNames: [], unpricedModelNames: []),
            outsideWindow: ModelCostEstimate(value: 3, currency: ModelPriceCurrency.cny, pricedModelNames: [], unpricedModelNames: []),
        ]

        let series = UsageHistorySeriesBuilder.build(
            days: [Daily](),
            costByDay: costs,
            speedByDay: [:],
            samplesTruncated: false,
            calendar: calendar,
            now: today
        )

        XCTAssertEqual(series[6].value, 2)
        XCTAssertEqual(series[6].currency, ModelPriceCurrency.usd)
    }

    func testSpeedUsesPromptP50AndRemainsUnavailableWithoutSamples() throws {
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29)))
        let stat = PromptSpeedStatistics(
            minimum: 10,
            maximum: 80,
            p50: 40,
            p95: 70,
            latest: 80,
            validPromptCount: 2,
            totalPromptCount: 2
        )
        let series = UsageHistorySeriesBuilder.build(
            days: [Daily](),
            costByDay: [:],
            speedByDay: [today: stat],
            samplesTruncated: false,
            calendar: calendar,
            now: today
        )

        XCTAssertNil(series[5].speed)
        XCTAssertEqual(series[6].speed, 40)
        XCTAssertFalse(series[6].speedIsPartial)
    }

    func testSpeedMarksCoveragePartialWhenPromptsLackValidDurations() throws {
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29)))
        let stat = PromptSpeedStatistics(
            minimum: 10,
            maximum: 80,
            p50: 40,
            p95: 70,
            latest: 80,
            validPromptCount: 2,
            totalPromptCount: 3
        )

        let series = UsageHistorySeriesBuilder.build(
            days: [Daily](),
            costByDay: [:],
            speedByDay: [today: stat],
            samplesTruncated: false,
            calendar: calendar,
            now: today
        )

        XCTAssertTrue(series[6].speedIsPartial)
    }

    func testNonFiniteRawEstimatesAreUnavailableAndIntegerConversionSaturates() throws {
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 29)))
        let badCost = ModelCostEstimate(
            value: .infinity,
            currency: ModelPriceCurrency.usd,
            pricedModelNames: ["model"],
            unpricedModelNames: []
        )
        let badSpeed = PromptSpeedStatistics(
            minimum: 1,
            maximum: 1,
            p50: .nan,
            p95: 1,
            latest: 1,
            validPromptCount: 1,
            totalPromptCount: 1
        )
        let series = UsageHistorySeriesBuilder.build(
            days: [Daily](),
            costByDay: [today: badCost],
            speedByDay: [today: badSpeed],
            samplesTruncated: false,
            calendar: calendar,
            now: today
        )

        XCTAssertNil(series[6].value)
        XCTAssertNil(series[6].currency)
        XCTAssertNil(series[6].speed)
        XCTAssertEqual(UsageHistoryNumber.integer(Double(Int.max)), Int.max)
        XCTAssertNil(UsageHistoryNumber.integer(.infinity))
        XCTAssertNil(UsageHistoryNumber.integer(-1))
    }
}
