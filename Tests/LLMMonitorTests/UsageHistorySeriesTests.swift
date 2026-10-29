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
        XCTAssertTrue(series[6].isTodayIncomplete)
        XCTAssertNil(series[6].total)
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
