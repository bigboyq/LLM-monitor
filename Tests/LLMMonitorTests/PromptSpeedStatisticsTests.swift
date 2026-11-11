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

    func testTreatsEachCallIndependentlyWithinSamePromptAndUsesBillableOutput() {
        let stats = LocalUsageSummaryBuilder.callSpeedStatistics(samples: [
            sample("multi", seconds: 2, output: 200, reasoning: 100),
            sample("multi", seconds: 3, output: 300),
            sample("single", seconds: 2, output: 160, completedAtOffset: 1)
        ])

        XCTAssertEqual(stats.minimum ?? 0, 80, accuracy: 1e-9)
        XCTAssertEqual(stats.maximum ?? 0, 150, accuracy: 1e-9)
        XCTAssertEqual(stats.p50 ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(stats.p95 ?? 0, 150, accuracy: 1e-9)
        XCTAssertEqual(stats.latest ?? 0, 80, accuracy: 1e-9)
        XCTAssertEqual(stats.validCallCount, 3)
        XCTAssertEqual(stats.totalCallCount, 3)
    }

    func testOddAndEvenCallCountsComputeP50FromSortedValidCallRates() {
        let oddStats = LocalUsageSummaryBuilder.callSpeedStatistics(samples: [
            sample("slow", seconds: 2, output: 20),
            sample("middle", seconds: 2, output: 40),
            sample("fast", seconds: 2, output: 60)
        ])

        XCTAssertEqual(oddStats.minimum ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(oddStats.maximum ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(oddStats.p50 ?? 0, 20, accuracy: 1e-9)

        let evenStats = LocalUsageSummaryBuilder.callSpeedStatistics(samples: [
            sample("a", seconds: 2, output: 20),
            sample("b", seconds: 2, output: 40),
            sample("c", seconds: 2, output: 80),
            sample("d", seconds: 2, output: 120)
        ])

        XCTAssertEqual(evenStats.p50 ?? 0, 30, accuracy: 1e-9)
    }

    /// P95 就近秩法（奇数个）：⌈0.95 × 5⌉ = 5 → 取升序第 5 个（即最大值）。
    func testP95OnOddCountUsesNearestRank() {
        let stats = LocalUsageSummaryBuilder.callSpeedStatistics(samples: [
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
        let stats = LocalUsageSummaryBuilder.callSpeedStatistics(samples: samples)

        XCTAssertEqual(stats.p50 ?? 0, 10.5, accuracy: 1e-9)
        XCTAssertEqual(stats.p95 ?? 0, 19, accuracy: 1e-9)
        XCTAssertEqual(stats.maximum ?? 0, 20, accuracy: 1e-9)
    }

    /// 单元素：⌈0.95 × 1⌉ = 1 → 唯一样本，P95 与 min / max / P50 重合。
    func testP95FallsBackToTheSingleSample() {
        let stats = LocalUsageSummaryBuilder.callSpeedStatistics(samples: [
            sample("only", seconds: 2, output: 200)
        ])

        XCTAssertEqual(stats.p50 ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(stats.p95 ?? 0, 100, accuracy: 1e-9)
    }

    func testLatestCallTieBreaksByPromptIDAscendingThenArrayIndexDescending() {
        let promptTie = LocalUsageSummaryBuilder.callSpeedStatistics(samples: [
            sample("b", seconds: 2, output: 180),
            sample("a", seconds: 2, output: 100)
        ])
        XCTAssertEqual(promptTie.latest ?? 0, 50, accuracy: 1e-9)

        let indexTieValid = LocalUsageSummaryBuilder.callSpeedStatistics(samples: [
            sample("same", seconds: 2, output: 100),
            sample("same", seconds: 2, output: 300)
        ])
        XCTAssertEqual(indexTieValid.latest ?? 0, 150, accuracy: 1e-9)

        let indexTieInvalid = LocalUsageSummaryBuilder.callSpeedStatistics(samples: [
            sample("same", seconds: 2, output: 100),
            sample("same", seconds: nil, output: 300)
        ])
        XCTAssertNil(indexTieInvalid.latest, "相同时间戳与 promptID 时末位无效调用不得回退到前一条调用")
        XCTAssertEqual(indexTieInvalid.p50 ?? 0, 50, accuracy: 1e-9)
        XCTAssertEqual(indexTieInvalid.validCallCount, 1)
        XCTAssertEqual(indexTieInvalid.totalCallCount, 2)
    }

    func testZeroOutputIsAValidZeroSpeed() {
        let stats = LocalUsageSummaryBuilder.callSpeedStatistics(samples: [
            sample("zero", seconds: 1, output: 0, completedAtOffset: 1)
        ])

        XCTAssertEqual(stats.minimum ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(stats.maximum ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(stats.p50 ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(stats.latest ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(stats.validCallCount, 1)
        XCTAssertEqual(stats.totalCallCount, 1)
    }

    /// 回归：同一 Turn（`promptID`）内混杂无时长工具调用（Option B）、超短批复
    /// 或 `ttft ≥ duration` 异常调用时，只跳过无效调用本身，不连坐同 turn 内的有效流式调用。
    func testInvalidCallInMultiCallTurnDoesNotDisqualifySiblingValidCalls() {
        let stats = LocalUsageSummaryBuilder.callSpeedStatistics(samples: [
            sample("turn-1", seconds: nil, output: 800, completedAtOffset: 0),
            sample("turn-1", seconds: 0.1, output: 500, completedAtOffset: 1),
            sample("turn-1", seconds: 10, output: 200, completedAtOffset: 2, ttft: 10),
            sample("turn-1", seconds: 2, output: 200, completedAtOffset: 3),
            sample("turn-1", seconds: 10, output: 100, reasoning: 100, completedAtOffset: 4, ttft: 2),
            sample("turn-2", seconds: 2, output: 400, completedAtOffset: 5)
        ])

        XCTAssertEqual(stats.minimum ?? 0, 25, accuracy: 1e-9)
        XCTAssertEqual(stats.p50 ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(stats.p95 ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(stats.maximum ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(stats.latest ?? 0, 200, accuracy: 1e-9)
        XCTAssertEqual(stats.validCallCount, 3)
        XCTAssertEqual(stats.totalCallCount, 6)
    }

    func testLatestInvalidCallDoesNotBackfillAnOlderSpeed() {
        let subThresholdLatest = LocalUsageSummaryBuilder.callSpeedStatistics(samples: [
            sample("older", seconds: 2, output: 200),
            sample("latest", seconds: 0.1, output: 900, completedAtOffset: 1)
        ])

        XCTAssertEqual(subThresholdLatest.p50 ?? 0, 100, accuracy: 1e-9)
        XCTAssertNil(subThresholdLatest.latest)
        XCTAssertEqual(subThresholdLatest.validCallCount, 1)
        XCTAssertEqual(subThresholdLatest.totalCallCount, 2)

        let ttftCoveredLatest = LocalUsageSummaryBuilder.callSpeedStatistics(samples: [
            sample("older", seconds: 2, output: 200),
            sample("latest", seconds: 10, output: 900, completedAtOffset: 1, ttft: 10)
        ])

        XCTAssertEqual(ttftCoveredLatest.p50 ?? 0, 100, accuracy: 1e-9)
        XCTAssertNil(ttftCoveredLatest.latest, "最新单次调用解码时长非正时 latest 为 nil，不回退旧调用")
        XCTAssertEqual(ttftCoveredLatest.validCallCount, 1)
        XCTAssertEqual(ttftCoveredLatest.totalCallCount, 2)
    }

    func testEmptyAndAllInvalidInputsKeepCountsAndNilRates() {
        XCTAssertEqual(
            LocalUsageSummaryBuilder.callSpeedStatistics(samples: []),
            .empty
        )

        let invalid = LocalUsageSummaryBuilder.callSpeedStatistics(samples: [
            sample("a", seconds: .nan, output: 10),
            sample("b", seconds: 3601, output: 20),
            sample("c", seconds: nil, output: 30),
            sample("d", seconds: 5, output: 40, ttft: 5)
        ])
        XCTAssertNil(invalid.minimum)
        XCTAssertNil(invalid.maximum)
        XCTAssertNil(invalid.p50)
        XCTAssertNil(invalid.p95)
        XCTAssertNil(invalid.latest)
        XCTAssertEqual(invalid.validCallCount, 0)
        XCTAssertEqual(invalid.totalCallCount, 4)
    }

    /// 速度分母是**单次调用解码时长**：带 TTFT 的调用扣掉首字延迟（10 − 2 = 8s），
    /// 无 TTFT 的调用按时长全额（5s），同一 Turn 内多次有效调用各自独立计入分布。
    func testCallRateSubtractsTTFTPerCallWithoutSummingAcrossCalls() {
        let stats = LocalUsageSummaryBuilder.callSpeedStatistics(samples: [
            sample("mixed", seconds: 10, output: 160, ttft: 2),
            sample("mixed", seconds: 5, output: 200, completedAtOffset: 1)
        ])

        XCTAssertEqual(stats.minimum ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(stats.maximum ?? 0, 40, accuracy: 1e-9)
        XCTAssertEqual(stats.p50 ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(stats.latest ?? 0, 40, accuracy: 1e-9)
        XCTAssertEqual(stats.validCallCount, 2)
        XCTAssertEqual(stats.totalCallCount, 2)
    }

    func testDurationBoundariesInclude0Point2And3600Seconds() {
        let stats = LocalUsageSummaryBuilder.callSpeedStatistics(samples: [
            sample("min-bound", seconds: 0.2, output: 20),
            sample("max-bound", seconds: 3600, output: 36000, completedAtOffset: 1)
        ])

        XCTAssertEqual(stats.minimum ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(stats.maximum ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(stats.p50 ?? 0, 55, accuracy: 1e-9)
        XCTAssertEqual(stats.validCallCount, 2)
        XCTAssertEqual(stats.totalCallCount, 2)
    }
}
