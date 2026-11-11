import XCTest
@testable import LLM_monitor

final class SevenDayUsageHistoryMetricTests: XCTestCase {
    private let calendar = Calendar.current

    private func dayStart(_ offset: Int) -> Date {
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: offset, to: today)!
    }

    private func sample(
        promptID: String,
        dayOffset: Int = 0,
        hour: Int,
        output: Int,
        duration: Double?,
        ttft: Double? = nil
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: calendar.date(bySettingHour: hour, minute: 15, second: 0, of: dayStart(dayOffset))!,
            modelName: "gpt-6-luna",
            promptID: promptID,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: output,
            reasoningOutputTokens: 0,
            durationSeconds: duration,
            ttftSeconds: ttft
        )
    }

    func testHistoryMetricSelectionHasIndependentPersistenceKey() {
        XCTAssertNotEqual(UsageHistoryMetric.storageKey, QuotaWindowUsageSection.segmentStorageKey)
        XCTAssertEqual(UsageHistoryMetric.allCases.count, 8)
        XCTAssertEqual(
            UsageHistoryMetric.allCases,
            [.total, .rounds, .value, .thinking, .outputRatio, .hit, .ttft, .speed]
        )
        XCTAssertEqual(UsageHistoryMetric.groups.flatMap { $0 }, UsageHistoryMetric.allCases)
        XCTAssertEqual(UsageHistoryMetric.ttft.title, "TTFT")
        XCTAssertEqual(UsageHistoryMetric.ttft.unit, "s")
        XCTAssertFalse(UsageHistoryMetric.ttft.isRate, "TTFT 是秒值，不走比率轴")
        XCTAssertFalse(UsageHistoryMetric.ttft.isBoundedRate)
    }

    func testDailySpeedUsesCallP50AndSkipsInvalidCallsWithoutDisqualifyingSiblings() {
        let day = dayStart(0)
        let samples = [
            // Same turn with two independent valid calls: 100 and 200 tok/s.
            sample(promptID: "prompt-1", hour: 10, output: 200, duration: 2),
            sample(promptID: "prompt-1", hour: 10, output: 400, duration: 2),
            sample(promptID: "prompt-2", hour: 11, output: 300, duration: 2),
            // Newest turn mixes a valid streaming call (250 tok/s) and a nil-duration tool call.
            // Only the nil-duration call is skipped; sibling valid call remains included.
            sample(promptID: "prompt-3", hour: 12, output: 500, duration: 2),
            sample(promptID: "prompt-3", hour: 12, output: 100, duration: nil),
        ]

        let statistics = LocalUsageSpeedByDay.statistics(dayStarts: [day], recentSamples: samples)

        XCTAssertEqual(statistics[day]?.p50 ?? -1, 175, accuracy: 1e-9)
        XCTAssertEqual(statistics[day]?.validCallCount, 4)
        XCTAssertEqual(statistics[day]?.totalCallCount, 5)
        XCTAssertNil(statistics[day]?.latest, "Newest invalid call must not fall back to an older speed")
    }

    func testFleetWithoutSamplesHasNoSpeedStatistics() {
        XCTAssertTrue(LocalUsageSpeedByDay.statistics(dayStarts: [dayStart(0)], recentSamples: []).isEmpty)
    }

    /// 每日调用级 TTFT 统计：统计单位均为**单次调用**，
    /// 有效样本排序取中位；memo key `"call-ttft"` 与速度的 `"call-speed"` 分开。
    func testDailyTTFTUsesCallLevelP50() {
        let day = dayStart(0)
        let samples = [
            sample(promptID: "prompt-1", hour: 10, output: 100, duration: 1, ttft: 0.9),
            sample(promptID: "prompt-1", hour: 10, output: 100, duration: 1, ttft: 0.1),
            // 无 TTFT 的调用不参与（0.9 / 0.1 的中位 = 0.5 不受它影响）。
            sample(promptID: "prompt-2", hour: 11, output: 300, duration: 3, ttft: nil),
            // MiniMax Code 显式写的 0 是合法值，正常参与。
            sample(promptID: "prompt-3", hour: 12, output: 100, duration: 1, ttft: 0),
        ]

        let statistics = LocalUsageTTFTByDay.ttftStatistics(dayStarts: [day], recentSamples: samples)

        XCTAssertEqual(statistics[day]?.p50 ?? -1, 0.1, accuracy: 1e-9, "调用级 P50：0, 0.1, 0.9 的中位 = 0.1")
        XCTAssertEqual(statistics[day]?.validCallCount, 3)
        XCTAssertEqual(statistics[day]?.totalCallCount, 4)
        XCTAssertEqual(statistics[day], LocalUsageSummaryBuilder.callTTFTStatistics(samples: samples))

        // 空样本集合 → 空表（fleet / 旧缓存路径零改动）。
        XCTAssertTrue(LocalUsageTTFTByDay.ttftStatistics(dayStarts: [day], recentSamples: []).isEmpty)
    }

    /// builder 的 `ttftByDay` 默认 `[:]`（fleet / 既有调用点零改动）；
    /// 传入时逐日取 `CallTTFTStatistics.p50` 秒值写入 `UsageHistoryDay.ttft`，
    /// `value(for: .ttft)` 接通；无样本日保持缺口。
    func testBuildMapsTTFTByDayIntoDailyValues() throws {
        let today = calendar.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let dayBefore = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))

        let series = UsageHistorySeriesBuilder.build(
            days: [] as [LocalUsageDailyEmpty],
            costByDay: [:],
            speedByDay: [:],
            ttftByDay: [
                yesterday: CallTTFTStatistics(p50: 0.86, validCallCount: 5, totalCallCount: 5)
            ],
            samplesTruncated: false,
            calendar: calendar,
            now: today
        )

        XCTAssertEqual(series.count, 7)
        XCTAssertNil(series[4].ttft, "无统计的日保持缺口")
        XCTAssertEqual(try XCTUnwrap(series[5].value(for: .ttft)), 0.86, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(series[5].ttft), 0.86, accuracy: 1e-9)
        XCTAssertNil(series[6].ttft)
        XCTAssertTrue(series.contains(where: \.hasAnyData), "只有 TTFT 有值时图表也应有内容")
    }
}

/// `LocalUsageDaily` 的空实现：仅验证 builder 的 ttftByDay 装配，不需要日桶。
private struct LocalUsageDailyEmpty: LocalUsageDaily {
    var dayStart: Date { Date() }
    var id: Date { dayStart }
    var input: Int { 0 }
    var cacheRead: Int { 0 }
    var cacheWrite: Int { 0 }
    var output: Int { 0 }
    var reasoning: Int { 0 }
    var turns: Int { 0 }
    var rounds: Int { 0 }
}
