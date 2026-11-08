import XCTest
@testable import LLM_monitor

final class PromptSpeedStatisticsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(
        _ promptID: String,
        seconds: Double?,
        output: Int,
        reasoning: Int = 0,
        completedAtOffset: TimeInterval = 0,
        ttft: Double? = nil
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: base.addingTimeInterval(completedAtOffset),
            modelName: "model",
            promptID: promptID,
            inputTokens: 0,
            cachedInputTokens: 0,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            durationSeconds: seconds,
            ttftSeconds: ttft
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

    /// P95 就近秩法（奇数个）：⌈0.95 × 5⌉ = 5 → 取升序第 5 个（即最大值）。
    func testP95OnOddCountUsesNearestRank() {
        let stats = LocalUsageSummaryBuilder.promptSpeedStatistics(samples: [
            sample("a", seconds: 1, output: 10),
            sample("b", seconds: 1, output: 20),
            sample("c", seconds: 1, output: 30),
            sample("d", seconds: 1, output: 40),
            sample("e", seconds: 1, output: 50)
        ])

        XCTAssertEqual(stats.p50 ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(stats.p95 ?? 0, 50, accuracy: 1e-9)
    }

    /// P95 就近秩法（均匀分布）：20 个等差样本 ⌈0.95 × 20⌉ = 19 → 第 19 个，
    /// 不是最大值——钉住它不是「取最大」的别名。
    func testP95OnUniformSamplesIsSecondLargestNotMaximum() {
        let samples = (1...20).map { index in
            sample("p\(index)", seconds: 1, output: index, completedAtOffset: TimeInterval(index))
        }
        let stats = LocalUsageSummaryBuilder.promptSpeedStatistics(samples: samples)

        XCTAssertEqual(stats.p50 ?? 0, 10.5, accuracy: 1e-9)
        XCTAssertEqual(stats.p95 ?? 0, 19, accuracy: 1e-9)
        XCTAssertEqual(stats.maximum ?? 0, 20, accuracy: 1e-9)
    }

    /// 单元素：⌈0.95 × 1⌉ = 1 → 唯一样本，P95 与 min / max / P50 重合。
    func testP95FallsBackToTheSingleSample() {
        let stats = LocalUsageSummaryBuilder.promptSpeedStatistics(samples: [
            sample("only", seconds: 2, output: 200)
        ])

        XCTAssertEqual(stats.p50 ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(stats.p95 ?? 0, 100, accuracy: 1e-9)
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
        XCTAssertNil(invalid.p95)
        XCTAssertNil(invalid.latest)
        XCTAssertEqual(invalid.validPromptCount, 0)
        XCTAssertEqual(invalid.totalPromptCount, 2)
    }

    /// 速度分母是**解码时长**：prompt 内多条调用按各自解码时长合计——带 TTFT 的
    /// 调用扣掉首字延迟（10 − 2 = 8s），无 TTFT 的调用按时长全额（5s）。
    func testPromptRateSumsDecodeDurationsAcrossMixedTTFTCalls() {
        let stats = LocalUsageSummaryBuilder.promptSpeedStatistics(samples: [
            sample("mixed", seconds: 10, output: 100, ttft: 2),
            sample("mixed", seconds: 5, output: 150),
        ])

        XCTAssertEqual(stats.p50 ?? 0, 250.0 / 13.0, accuracy: 1e-9, "解码时长 = 8s（扣 TTFT）+ 5s（全额）")
        XCTAssertEqual(stats.validPromptCount, 1)
        XCTAssertEqual(stats.totalPromptCount, 1)
    }

    /// prompt 内任一调用 `ttft ≥ duration`（解码时长非正，账本异常）→ 整组剔除：
    /// 分布、validPromptCount 都不含，latest 落在剩下的最新完整 prompt 上。
    func testPromptWithAnyCallCoveredByTTFTIsExcludedAsAWhole() {
        let stats = LocalUsageSummaryBuilder.promptSpeedStatistics(samples: [
            sample("anomaly", seconds: 10, output: 200, ttft: 10),
            sample("complete", seconds: 2, output: 400, completedAtOffset: 1)
        ])

        XCTAssertEqual(stats.p50 ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(stats.validPromptCount, 1)
        XCTAssertEqual(stats.totalPromptCount, 2)
        XCTAssertEqual(stats.latest ?? 0, 200, accuracy: 1e-9, "异常组整条剔除，latest 不回退到更旧的 prompt")
    }
}
