import XCTest
@testable import LLM_monitor

final class TokenAccountingTests: XCTestCase {
    func testDshSplitsReasoningIncludedOutputAndExcludesCacheWrite() {
        let buckets = TokenAccountingCatalog.dsh.normalizedBuckets(
            rawInput: 100,
            cacheRead: 50,
            rawOutput: 30,
            rawReasoning: 10
        )

        XCTAssertEqual(buckets.input, 100)
        XCTAssertEqual(buckets.cacheRead, 50)
        XCTAssertEqual(buckets.output, 20)
        XCTAssertEqual(buckets.reasoning, 10)
        XCTAssertEqual(buckets.totalTokens, 180)
        XCTAssertEqual(buckets.billableOutput, 30)
        XCTAssertFalse(TokenAccountingCatalog.dsh.includesCacheWriteInEstimate)
    }

    func testReasoningIncludedSourceKeepsRawOutputWhenReasonIsUnavailable() {
        let buckets = TokenAccountingCatalog.dsh.normalizedBuckets(
            rawInput: 100,
            cacheRead: 20,
            rawOutput: 30,
            rawReasoning: 0
        )

        XCTAssertEqual(buckets.output, 30)
        XCTAssertEqual(buckets.reasoning, 0)
        XCTAssertEqual(buckets.billableOutput, 30)
    }

    func testCacheInclusiveInputIsNormalizedOnlyAtAccountingBoundary() {
        let buckets = TokenAccountingCatalog.codex.normalizedBuckets(
            rawInput: 100,
            cacheRead: 25,
            rawOutput: 30,
            rawReasoning: 10
        )

        XCTAssertEqual(buckets.input, 75)
        XCTAssertEqual(buckets.cacheRead, 25)
        XCTAssertEqual(buckets.output, 30)
        XCTAssertEqual(buckets.reasoning, 10)
        XCTAssertEqual(buckets.totalTokens, 140)
    }

    func testPersistedSampleConvertsToDisjointPricingBuckets() {
        let sample = LocalTokenUsageSample(
            completedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modelName: "example",
            promptID: "prompt-1",
            inputTokens: 150,
            cachedInputTokens: 50,
            outputTokens: 20,
            reasoningOutputTokens: 10
        )

        let buckets = TokenUsageBuckets.fromSample(sample)
        XCTAssertEqual(buckets, TokenUsageBuckets(input: 100, cacheRead: 50, output: 20, reasoning: 10))
        XCTAssertEqual(ModelPricingCatalog.tokenComponents(for: sample).output, 30)
    }

    func testDailyEstimateIgnoresCacheWrite() {
        let day = UnifiedDailyTokenUsage(
            dayStart: Date(timeIntervalSince1970: 1_700_000_000),
            input: 100,
            cacheRead: 50,
            cacheWrite: 777,
            output: 20,
            reasoning: 10
        )

        XCTAssertEqual(day.totalTokens, 180)
        XCTAssertEqual(day.inputTotal, 150)
        XCTAssertEqual(day.outputTotal, 30)
    }

    func testNegativeAndOverlappingCacheValuesAreSaturated() {
        let buckets = TokenAccountingCatalog.codex.normalizedBuckets(
            rawInput: -10,
            cacheRead: 100,
            rawOutput: -20,
            rawReasoning: 50
        )

        XCTAssertEqual(buckets, TokenUsageBuckets(input: 0, cacheRead: 0, output: 0, reasoning: 50))
    }

    // MARK: - Harness 全量定义（合并自 TokenAccountingHarnessTests）

    func testAllHarnessDefinitionsProduceDisjointNormalizedBuckets() {
        let cases: [(String, TokenAccountingDefinition, Int, Int, Int, Int, TokenUsageBuckets)] = [
            (
                "DSH",
                TokenAccountingCatalog.dsh,
                100, 50, 30, 10,
                TokenUsageBuckets(input: 100, cacheRead: 50, output: 20, reasoning: 10)
            ),
            (
                "MiniMax Code",
                TokenAccountingCatalog.minimax,
                100, 50, 30, 0,
                TokenUsageBuckets(input: 100, cacheRead: 50, output: 30, reasoning: 0)
            ),
            (
                "Codex",
                TokenAccountingCatalog.codex,
                150, 50, 30, 10,
                TokenUsageBuckets(input: 100, cacheRead: 50, output: 30, reasoning: 10)
            ),
            (
                "Antigravity",
                TokenAccountingCatalog.antigravity,
                100, 50, 30, 10,
                TokenUsageBuckets(input: 100, cacheRead: 50, output: 30, reasoning: 10)
            ),
            (
                "OpenCode",
                TokenAccountingCatalog.opencode,
                100, 50, 30, 10,
                TokenUsageBuckets(input: 100, cacheRead: 50, output: 30, reasoning: 10)
            ),
            (
                "ZCode",
                TokenAccountingCatalog.zcode,
                150, 50, 30, 10,
                TokenUsageBuckets(input: 100, cacheRead: 50, output: 30, reasoning: 10)
            )
        ]

        for (name, definition, rawInput, cacheRead, rawOutput, rawReasoning, expected) in cases {
            XCTAssertEqual(
                definition.normalizedBuckets(
                    rawInput: rawInput,
                    cacheRead: cacheRead,
                    rawOutput: rawOutput,
                    rawReasoning: rawReasoning
                ),
                expected,
                name
            )
            XCTAssertEqual(
                expected.totalTokens,
                expected.input + expected.cacheRead + expected.output + expected.reasoning,
                name
            )
        }
    }

    func testUnifiedSampleAggregatorMatchesPricingBuckets() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            LocalTokenUsageSample(
                completedAt: day,
                modelName: "MiniMax-M3",
                promptID: "prompt-1",
                inputTokens: 150,
                cachedInputTokens: 50,
                outputTokens: 20,
                reasoningOutputTokens: 10
            ),
            LocalTokenUsageSample(
                completedAt: day.addingTimeInterval(1),
                modelName: "MiniMax-M3",
                promptID: "prompt-1",
                inputTokens: 80,
                cachedInputTokens: 30,
                outputTokens: 5,
                reasoningOutputTokens: 0
            )
        ]

        let usage = UnifiedTokenUsageAggregator.day(from: samples, dayStart: day)
        XCTAssertEqual(usage.input, 150)
        XCTAssertEqual(usage.cacheRead, 80)
        XCTAssertEqual(usage.output, 25)
        XCTAssertEqual(usage.reasoning, 10)
        XCTAssertEqual(usage.totalTokens, 265)
        XCTAssertEqual(usage.turns, 1)
        XCTAssertEqual(usage.rounds, 2)
    }
}
