import XCTest
@testable import LLM_monitor

final class PromptSpeedStatisticsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(
        _ promptID: String,
        seconds: Double?,
        output: Int,
        reasoning: Int = 0,
        completedAtOffset: TimeInterval = 0
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: base.addingTimeInterval(completedAtOffset),
            modelName: "model",
            promptID: promptID,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            durationSeconds: seconds
        )
    }

    func testGroupsCallsIntoOnePromptAndUsesBillableOutput() {
        let stats = LocalUsageSummaryBuilder.promptSpeedStatistics(samples: [
            sample("multi", seconds: 2, output: 200, reasoning: 100),
            sample("multi", seconds: 3, output: 300),
            sample("single", seconds: 2, output: 200, completedAtOffset: 1)
        ])

        XCTAssertEqual(stats.minimum ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(stats.maximum ?? 0, 120, accuracy: 1e-9)
        XCTAssertEqual(stats.p50 ?? 0, 110, accuracy: 1e-9)
        XCTAssertEqual(stats.latest ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(stats.validPromptCount, 2)
        XCTAssertEqual(stats.totalPromptCount, 2)
    }

    func testOddPromptCountUsesMiddleRateAsP50() {
        let stats = LocalUsageSummaryBuilder.promptSpeedStatistics(samples: [
            sample("slow", seconds: 2, output: 20),
            sample("middle", seconds: 2, output: 40),
            sample("fast", seconds: 2, output: 60)
        ])

        XCTAssertEqual(stats.minimum ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(stats.maximum ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(stats.p50 ?? 0, 20, accuracy: 1e-9)
    }

    func testLatestPromptTimestampTieBreaksByPromptIDAscending() {
        let stats = LocalUsageSummaryBuilder.promptSpeedStatistics(samples: [
            sample("b", seconds: 2, output: 180),
            sample("a", seconds: 2, output: 100)
        ])

        XCTAssertEqual(stats.latest ?? 0, 50, accuracy: 1e-9)
    }

    func testZeroOutputIsAValidZeroSpeed() {
        let stats = LocalUsageSummaryBuilder.promptSpeedStatistics(samples: [
            sample("zero", seconds: 1, output: 0, completedAtOffset: 1)
        ])

        XCTAssertEqual(stats.minimum ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(stats.maximum ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(stats.p50 ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(stats.latest ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(stats.validPromptCount, 1)
    }

    func testPromptWithAnyInvalidCallIsExcludedAsAWhole() {
        let stats = LocalUsageSummaryBuilder.promptSpeedStatistics(samples: [
            sample("partial", seconds: 2, output: 200),
            sample("partial", seconds: nil, output: 800),
            sample("complete", seconds: 2, output: 400, completedAtOffset: 1)
        ])

        XCTAssertEqual(stats.minimum ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(stats.maximum ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(stats.p50 ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(stats.validPromptCount, 1)
        XCTAssertEqual(stats.totalPromptCount, 2)
    }

    func testLatestIncompletePromptDoesNotBackfillAnOlderSpeed() {
        let stats = LocalUsageSummaryBuilder.promptSpeedStatistics(samples: [
            sample("older", seconds: 2, output: 200),
            sample("latest", seconds: 0.1, output: 900, completedAtOffset: 1)
        ])

        XCTAssertEqual(stats.p50 ?? 0, 100, accuracy: 1e-9)
        XCTAssertNil(stats.latest)
        XCTAssertEqual(stats.validPromptCount, 1)
        XCTAssertEqual(stats.totalPromptCount, 2)
    }

    func testEmptyAndAllInvalidInputsKeepCountsAndNilRates() {
        XCTAssertEqual(
            LocalUsageSummaryBuilder.promptSpeedStatistics(samples: []),
            .empty
        )

        let invalid = LocalUsageSummaryBuilder.promptSpeedStatistics(samples: [
            sample("a", seconds: .nan, output: 10),
            sample("b", seconds: 3601, output: 20)
        ])
        XCTAssertNil(invalid.minimum)
        XCTAssertNil(invalid.maximum)
        XCTAssertNil(invalid.p50)
        XCTAssertNil(invalid.latest)
        XCTAssertEqual(invalid.validPromptCount, 0)
        XCTAssertEqual(invalid.totalPromptCount, 2)
    }
}
