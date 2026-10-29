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
        duration: Double?
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: calendar.date(bySettingHour: hour, minute: 15, second: 0, of: dayStart(dayOffset))!,
            modelName: "gpt-6-luna",
            promptID: promptID,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: output,
            reasoningOutputTokens: 0,
            durationSeconds: duration
        )
    }

    func testHistoryMetricSelectionHasIndependentPersistenceKey() {
        XCTAssertNotEqual(UsageHistoryMetric.storageKey, QuotaWindowUsageSection.segmentStorageKey)
        XCTAssertEqual(UsageHistoryMetric.allCases.count, 9)
    }

    func testDailySpeedUsesPromptP50AndExcludesIncompletePrompts() {
        let day = dayStart(0)
        let samples = [
            // Two calls are one prompt: (100 + 100) / (1 + 1) = 100 tok/s.
            sample(promptID: "prompt-1", hour: 10, output: 100, duration: 1),
            sample(promptID: "prompt-1", hour: 10, output: 100, duration: 1),
            sample(promptID: "prompt-2", hour: 11, output: 300, duration: 3),
            // This newest prompt is omitted in full because one call has no duration.
            sample(promptID: "prompt-3", hour: 12, output: 100, duration: 1),
            sample(promptID: "prompt-3", hour: 12, output: 100, duration: nil),
        ]

        let statistics = LocalUsageSpeedByDay.statistics(dayStarts: [day], recentSamples: samples)

        XCTAssertEqual(statistics[day]?.p50, 100)
        XCTAssertEqual(statistics[day]?.validPromptCount, 2)
        XCTAssertEqual(statistics[day]?.totalPromptCount, 3)
        XCTAssertNil(statistics[day]?.latest, "Newest incomplete prompt must not fall back to an older speed")
    }

    func testFleetWithoutPromptSamplesHasNoSpeedStatistics() {
        XCTAssertTrue(LocalUsageSpeedByDay.statistics(dayStarts: [dayStart(0)], recentSamples: []).isEmpty)
    }
}
