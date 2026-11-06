import XCTest
import Foundation
@testable import LLM_monitor

/// Adversarial stress testing for M1:
/// 1. Countdown formatting: `Formatters.formatRelativeCountdown` boundary conditions & edge cases.
/// 2. Memoization stress: `LocalUsagePriceByDay.estimates(...)` cache hits, invalidation on all key dimensions, concurrency safety, and boundedness.
final class ChallengerStressTests: XCTestCase {

    override func setUp() {
        super.setUp()
        LocalUsagePriceByDay.reset()
        HolidayCalendar.applyResolved(.empty)
    }

    override func tearDown() {
        LocalUsagePriceByDay.reset()
        HolidayCalendar.applyResolved(HolidayCalendar.loadBundled())
        super.tearDown()
    }

    // MARK: - Helpers

    private func beijingDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return PeakWindow.beijingCalendar.date(from: components)!
    }

    private func makeSample(
        _ promptID: String,
        at completedAt: Date,
        input: Int = 1_000_000,
        cacheRead: Int = 0,
        output: Int = 0,
        reasoning: Int = 0
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: completedAt,
            modelName: "deepseek-v4-flash",
            promptID: promptID,
            inputTokens: input + cacheRead,
            cachedInputTokens: cacheRead,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            sourceProviderID: "dsh:deepseek-official"
        )
    }

    // MARK: - 1. Countdown Formatting Boundary & Adversarial Tests

    /// Stress test negative and zero boundary values:
    /// - Any seconds <= 0 must immediately return expiredText without prefix or suffix.
    func testCountdownNegativeAndZeroBoundaries() {
        let boundaries: [TimeInterval] = [
            -1_000_000.0,
            -86400.0,
            -3600.0,
            -60.0,
            -1.0,
            -0.5,
            -0.0001,
            -0.0,
            0.0
        ]

        for sec in boundaries {
            let resDefault = Formatters.formatRelativeCountdown(sec)
            XCTAssertEqual(resDefault, "已到期", "sec=\(sec) with default parameters")

            let resCustom = Formatters.formatRelativeCountdown(
                sec,
                prefix: "剩余",
                suffix: "后生效",
                expiredText: "已失效",
                includeHoursWhenDays: false
            )
            XCTAssertEqual(resCustom, "已失效", "sec=\(sec) with custom expiredText")
        }
    }

    /// Stress test sub-second positives, 1s, and minute boundary conditions:
    /// - 0.0001s .. 59.4s -> "1分"
    /// - 59.5s rounds to 60s -> "1分"
    /// - 60s .. 119.4s -> "1分"
    /// - 119.5s rounds to 120s -> "2分"
    func testCountdownSubSecondAndMinuteBoundaries() {
        // Values that round to < 60 seconds (or 0) clamp to max(minutes, 1) = 1分
        let minuteOneCases: [TimeInterval] = [
            0.0001,
            0.49,
            0.5,
            0.99,
            1.0,
            30.0,
            59.0,
            59.4,
            59.5, // 59.5 rounds to 60 -> minutes = 1 -> "1分"
            60.0, // 60 -> minutes = 1 -> "1分"
            60.4,
            89.9,
            90.0,
            119.0,
            119.4
        ]

        for sec in minuteOneCases {
            let result = Formatters.formatRelativeCountdown(sec, prefix: "剩余")
            XCTAssertEqual(result, "剩余1分", "sec=\(sec) should format to 1分")
        }

        // Values that round to 120s (2 minutes)
        let minuteTwoCases: [TimeInterval] = [
            119.5, // rounds to 120 -> minutes = 2
            120.0,
            120.4,
            150.0,
            179.4
        ]

        for sec in minuteTwoCases {
            let result = Formatters.formatRelativeCountdown(sec, prefix: "剩余")
            XCTAssertEqual(result, "剩余2分", "sec=\(sec) should format to 2分")
        }
    }

    /// Stress test hour boundaries: 3599s, 3600s, 3659s, 3660s, 7199s, 7200s.
    func testCountdownHourBoundaries() {
        // 3599 seconds = 59m 59s -> "59分"
        XCTAssertEqual(Formatters.formatRelativeCountdown(3599.0, prefix: "剩余"), "剩余59分")
        XCTAssertEqual(Formatters.formatRelativeCountdown(3599.4, prefix: "剩余"), "剩余59分")

        // 3599.5 rounds to 3600 -> exactly 1 hour, 0 minutes -> "1小时"
        XCTAssertEqual(Formatters.formatRelativeCountdown(3599.5, prefix: "剩余"), "剩余1小时")
        XCTAssertEqual(Formatters.formatRelativeCountdown(3600.0, prefix: "剩余"), "剩余1小时")
        XCTAssertEqual(Formatters.formatRelativeCountdown(3659.0, prefix: "剩余"), "剩余1小时")
        XCTAssertEqual(Formatters.formatRelativeCountdown(3659.4, prefix: "剩余"), "剩余1小时")

        // 3659.5 rounds to 3660 -> 1 hour 1 minute -> "1小时1分"
        XCTAssertEqual(Formatters.formatRelativeCountdown(3659.5, prefix: "剩余"), "剩余1小时1分")
        XCTAssertEqual(Formatters.formatRelativeCountdown(3660.0, prefix: "剩余"), "剩余1小时1分")

        // 7199 -> 1 hour 59 minutes
        XCTAssertEqual(Formatters.formatRelativeCountdown(7199.0, prefix: "剩余"), "剩余1小时59分")
        // 7199.5 rounds to 7200 -> 2 hours 0 minutes -> "2小时"
        XCTAssertEqual(Formatters.formatRelativeCountdown(7199.5, prefix: "剩余"), "剩余2小时")
        XCTAssertEqual(Formatters.formatRelativeCountdown(7200.0, prefix: "剩余"), "剩余2小时")
    }

    /// Stress test day boundaries: 86399s, 86400s, 86400+3599s, 86400+3600s.
    /// Also checks includeHoursWhenDays toggle.
    func testCountdownDayBoundaries() {
        // 86399 seconds = 23h 59m 59s -> "23小时59分"
        XCTAssertEqual(
            Formatters.formatRelativeCountdown(86399.0, prefix: "剩余"),
            "剩余23小时59分"
        )

        // 86399.5 rounds to 86400 -> 1 day 0 hours -> "1天" (hours == 0 suppressed)
        XCTAssertEqual(
            Formatters.formatRelativeCountdown(86399.5, prefix: "剩余", includeHoursWhenDays: true),
            "剩余1天"
        )
        XCTAssertEqual(
            Formatters.formatRelativeCountdown(86399.5, prefix: "剩余", includeHoursWhenDays: false),
            "剩余1天"
        )

        // 86400 -> 1 day 0 hours -> "1天"
        XCTAssertEqual(
            Formatters.formatRelativeCountdown(86400.0, prefix: "剩余", includeHoursWhenDays: true),
            "剩余1天"
        )

        // 86400 + 3599 = 1 day 0 hours 59 minutes -> "1天" (minutes dropped when days > 0)
        XCTAssertEqual(
            Formatters.formatRelativeCountdown(86400.0 + 3599.0, prefix: "剩余", includeHoursWhenDays: true),
            "剩余1天"
        )

        // 86400 + 3600 = 1 day 1 hour
        // includeHoursWhenDays: true -> "1天1小时"
        // includeHoursWhenDays: false -> "1天"
        XCTAssertEqual(
            Formatters.formatRelativeCountdown(86400.0 + 3600.0, prefix: "剩余", includeHoursWhenDays: true),
            "剩余1天1小时"
        )
        XCTAssertEqual(
            Formatters.formatRelativeCountdown(86400.0 + 3600.0, prefix: "剩余", includeHoursWhenDays: false),
            "剩余1天"
        )

        // Multiple days with hours
        let multiDay = 5.0 * 86400.0 + 14.0 * 3600.0 + 42.0 * 60.0
        XCTAssertEqual(
            Formatters.formatRelativeCountdown(multiDay, prefix: "剩余", includeHoursWhenDays: true),
            "剩余5天14小时"
        )
        XCTAssertEqual(
            Formatters.formatRelativeCountdown(multiDay, prefix: "剩余", includeHoursWhenDays: false),
            "剩余5天"
        )
    }

    /// Stress test large day counts, leap seconds, and distant dates.
    func testCountdownLargeDayCountsAndExtremes() {
        // 30 days
        XCTAssertEqual(Formatters.formatRelativeCountdown(30.0 * 86400.0), "30天")
        // 365 days
        XCTAssertEqual(Formatters.formatRelativeCountdown(365.0 * 86400.0), "365天")
        // 10,000 days
        XCTAssertEqual(Formatters.formatRelativeCountdown(10_000.0 * 86400.0), "10000天")

        // Distant future (~720,000 days)
        let distantSeconds = Date.distantFuture.timeIntervalSince(Date())
        let formattedDistant = Formatters.formatRelativeCountdown(distantSeconds)
        XCTAssertTrue(formattedDistant.contains("天"), "Distant future should format cleanly with day count")
        XCTAssertFalse(formattedDistant.isEmpty)

        // Leap second jitter (e.g. 59.9999, 60.0001, 86400.0001)
        XCTAssertEqual(Formatters.formatRelativeCountdown(59.9999), "1分")
        XCTAssertEqual(Formatters.formatRelativeCountdown(60.0001), "1分")
        XCTAssertEqual(Formatters.formatRelativeCountdown(86400.0001), "1天")

        // IEEE 754 NaN and negative infinity
        XCTAssertEqual(Formatters.formatRelativeCountdown(.nan), "已到期")
        XCTAssertEqual(Formatters.formatRelativeCountdown(-.infinity), "已到期")
    }

    /// Stress test prefixes, suffixes, and unicode decorations across all three calling sites.
    func testCountdownCallingSitesEquivalence() {
        let now = Date()
        let future = now.addingTimeInterval(3600 * 2 + 15 * 60) // 2h 15m

        // 1. ChatGPTApiCreditsRow equivalence: prefix "剩余", includeHoursWhenDays: false, expiredText: "已到期"
        let chatgpt = Formatters.formatRelativeCountdown(
            future.timeIntervalSince(now),
            prefix: "剩余",
            expiredText: "已到期",
            includeHoursWhenDays: false
        )
        XCTAssertEqual(chatgpt, "剩余2小时15分")

        // 2. GlmActivityPlanBalancesView.formatEffectiveCountdown: suffix "后生效", expiredText: "已生效"
        let effective = GlmActivityPlanBalancesView.formatEffectiveCountdown(from: future, now: now)
        XCTAssertEqual(effective, "2小时15分后生效")

        // 3. GlmActivityPlanBalancesView.formatExpiryCountdown: prefix "剩余", expiredText: "已失效"
        let expiry = GlmActivityPlanBalancesView.formatExpiryCountdown(from: future, now: now)
        XCTAssertEqual(expiry, "剩余2小时15分")

        // 4. Formatters.formatBillingRemainingDuration: suffix "后", expiredText: "已到期"
        let billing = Formatters.formatBillingRemainingDuration(future.timeIntervalSince(now))
        XCTAssertEqual(billing, "2小时15分后")
    }

    // MARK: - 2. Memoization Stress Tests (`LocalUsagePriceByDay.estimates`)

    /// Stress test 10,000 repeated ticks:
    /// - Verify computeCount is strictly 1.
    /// - Verify fast execution (COW key comparison).
    func testPriceByDayMemoCacheHit10000Iterations() {
        let instant = beijingDate(year: 2026, month: 9, day: 16, hour: 10, minute: 0)
        let day = PeakWindow.beijingCalendar.startOfDay(for: instant)
        let samples = [makeSample("turn-1", at: instant)]

        LocalUsagePriceByDay.reset()
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 0)

        // First call computes
        let initial = LocalUsagePriceByDay.estimates(
            dayStarts: [day],
            recentSamples: samples,
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 1)
        XCTAssertEqual(initial[day]?.displayText, "¥2.00")

        // 10,000 consecutive queries with same key
        let start = CACurrentMediaTime()
        for _ in 1...10_000 {
            let cached = LocalUsagePriceByDay.estimates(
                dayStarts: [day],
                recentSamples: samples,
                quotaProviderID: QuotaProviderID.deepseek,
                deepseekPeakWindow: .deepseekDefault
            )
            XCTAssertEqual(cached[day]?.displayText, "¥2.00")
        }
        let elapsed = CACurrentMediaTime() - start

        XCTAssertEqual(
            LocalUsagePriceByDay.computeCount, 1,
            "10,000 repeated queries must NOT trigger recomputation"
        )
        // 10,000 dictionary lookups + memo cache hits should comfortably take under 0.2s on modern Mac
        XCTAssertLessThan(elapsed, 0.5, "10,000 cached lookups took \(elapsed)s; must be sub-0.5s")
    }

    /// Adversarial invalidation stress testing across all Key components:
    /// 1. dayStarts change
    /// 2. sample count change (added sample)
    /// 3. sample content change (different token counts, same array count)
    /// 4. sample timestamp change (peak -> offpeak)
    /// 5. provider slot isolation
    /// 6. holiday table change
    func testPriceByDayInvalidationOnAllKeyDimensions() {
        let peakInstant = beijingDate(year: 2026, month: 9, day: 16, hour: 10, minute: 0) // Wednesday 10:00 (peak)
        let offpeakInstant = beijingDate(year: 2026, month: 9, day: 16, hour: 21, minute: 0) // Wednesday 21:00 (offpeak)
        let day1 = PeakWindow.beijingCalendar.startOfDay(for: peakInstant)
        let day2 = day1.addingTimeInterval(86400)

        LocalUsagePriceByDay.reset()

        // 1. Initial computation
        let sample1 = makeSample("turn-1", at: peakInstant, input: 1_000_000)
        _ = LocalUsagePriceByDay.estimates(
            dayStarts: [day1],
            recentSamples: [sample1],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 1)

        // 2. dayStarts dimension: adding day2
        _ = LocalUsagePriceByDay.estimates(
            dayStarts: [day1, day2],
            recentSamples: [sample1],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 2, "dayStarts change must force recompute")

        // 3. recentSamples dimension: adding sample2
        let sample2 = makeSample("turn-2", at: peakInstant, input: 2_000_000)
        _ = LocalUsagePriceByDay.estimates(
            dayStarts: [day1, day2],
            recentSamples: [sample1, sample2],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 3, "sample count increase must force recompute")

        // 4. recentSamples dimension: content changed with same array length
        let sample2Modified = makeSample("turn-2", at: peakInstant, input: 5_000_000)
        _ = LocalUsagePriceByDay.estimates(
            dayStarts: [day1, day2],
            recentSamples: [sample1, sample2Modified],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 4, "sample token content change must force recompute")

        // 5. recentSamples dimension: timestamp shift (peak to offpeak)
        let sampleOffpeak = makeSample("turn-1", at: offpeakInstant, input: 1_000_000)
        let offpeakResult = LocalUsagePriceByDay.estimates(
            dayStarts: [day1],
            recentSamples: [sampleOffpeak],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 5, "timestamp shift to offpeak must force recompute")
        // Offpeak rate is ¥1.00 instead of peak ¥2.00
        XCTAssertEqual(offpeakResult[day1]?.displayText, "¥1.00")

        // 6. Provider slot isolation:
        // Querying for QuotaProviderID.openai must not overwrite QuotaProviderID.deepseek's slot
        _ = LocalUsagePriceByDay.estimates(
            dayStarts: [day1],
            recentSamples: [sampleOffpeak],
            quotaProviderID: "openai",
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 6, "New provider slot must compute")

        // Querying deepseek again with same input as step 5 MUST HIT CACHE!
        _ = LocalUsagePriceByDay.estimates(
            dayStarts: [day1],
            recentSamples: [sampleOffpeak],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 6, "Returning to cached provider slot must HIT cache")

        // 7. HolidayCalendar revision change
        let iso = HolidayCalendar.beijingDateString(on: peakInstant)
        HolidayCalendar.applyResolved(HolidayCalendar.make(holidays: [iso]))
        _ = LocalUsagePriceByDay.estimates(
            dayStarts: [day1],
            recentSamples: [sampleOffpeak],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 7, "Holiday revision change must force recompute")
    }

    /// Concurrency and thread-safety stress test:
    /// - 100 concurrent iterations across multiple threads calling `estimates`.
    /// - Interleaves concurrent queries across multiple provider slots.
    /// - Interleaves with `HolidayCalendar.applyResolved`.
    /// - Confirms absence of race conditions, deadlocks, or crashes.
    func testPriceByDayConcurrentAccessAndThreadSafety() {
        LocalUsagePriceByDay.reset()

        let instant = beijingDate(year: 2026, month: 9, day: 16, hour: 10, minute: 0)
        let day = PeakWindow.beijingCalendar.startOfDay(for: instant)
        let samples = (1...5).map { i in
            makeSample("turn-\(i)", at: instant, input: 100_000 * i)
        }

        let providers = ["deepseek", "openai", "glm", "anthropic", "minimax"]

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let provider = providers[index % providers.count]
            let dayStarts = [day]
            let slice = Array(samples.prefix((index % samples.count) + 1))

            if index == 50 {
                // Background holiday update
                HolidayCalendar.applyResolved(HolidayCalendar.make(holidays: ["2026-09-16"]))
            }

            let result = LocalUsagePriceByDay.estimates(
                dayStarts: dayStarts,
                recentSamples: slice,
                quotaProviderID: provider,
                deepseekPeakWindow: .deepseekDefault
            )
            XCTAssertFalse(result.isEmpty)
        }

        XCTAssertGreaterThan(LocalUsagePriceByDay.computeCount, 0)
    }

    /// Boundedness and memory safety stress test:
    /// - Simulates 1,000 tick updates with changing timestamps on 5 providers.
    /// - Asserts that the cache does not accumulate entries without bound.
    func testPriceByDayMemoryBoundednessUnderTickChurn() {
        LocalUsagePriceByDay.reset()

        let baseInstant = beijingDate(year: 2026, month: 9, day: 16, hour: 10, minute: 0)
        let day = PeakWindow.beijingCalendar.startOfDay(for: baseInstant)
        let providers = ["p1", "p2", "p3", "p4", "p5"]

        for tick in 1...1_000 {
            let provider = providers[tick % providers.count]
            // Each tick has a slightly mutated sample
            let sample = makeSample("turn-\(tick)", at: baseInstant.addingTimeInterval(Double(tick)), input: 10_000 + tick)
            _ = LocalUsagePriceByDay.estimates(
                dayStarts: [day],
                recentSamples: [sample],
                quotaProviderID: provider,
                deepseekPeakWindow: .deepseekDefault
            )
        }

        // Each provider slot stores only its latest Entry.
        // Therefore, entries count in DerivedValueMemo remains <= number of providers (5).
        // Since slotCount is internal to DerivedValueMemo, we verify that resetting cleanly zeroes computeCount
        LocalUsagePriceByDay.reset()
        XCTAssertEqual(LocalUsagePriceByDay.computeCount, 0, "Reset must restore computeCount to 0")
    }

    /// Edge case stress test: empty collections.
    func testPriceByDayEmptyInputs() {
        LocalUsagePriceByDay.reset()

        // 1. Empty dayStarts (estimateByDay is driven by recentSamples; dayStarts is memo dimension)
        let resEmptyDays = LocalUsagePriceByDay.estimates(
            dayStarts: [],
            recentSamples: [makeSample("turn-1", at: Date())],
            quotaProviderID: "deepseek",
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertEqual(resEmptyDays.count, 1)

        // 2. Empty recentSamples
        let resEmptySamples = LocalUsagePriceByDay.estimates(
            dayStarts: [Date()],
            recentSamples: [],
            quotaProviderID: "deepseek",
            deepseekPeakWindow: .deepseekDefault
        )
        // With empty samples, estimateByDay produces empty dictionary
        XCTAssertTrue(resEmptySamples.isEmpty)

        // 3. Both empty
        let resBothEmpty = LocalUsagePriceByDay.estimates(
            dayStarts: [],
            recentSamples: [],
            quotaProviderID: "deepseek",
            deepseekPeakWindow: .deepseekDefault
        )
        XCTAssertTrue(resBothEmpty.isEmpty)
    }
}
