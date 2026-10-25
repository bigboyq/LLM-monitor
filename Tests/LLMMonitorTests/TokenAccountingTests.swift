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

    /// Antigravity 的 raw `outputTokens` 已含思考（实测 100% 满足
    /// `outputTokens == thinkingOutputTokens + responseOutputTokens`），catalog
    /// 因此走 `.reasoningIncluded`：Output = rawOutput − thinking、Reason =
    /// thinking、Output+Reason == rawOutput，四桶守恒（此前 `.independent` 把
    /// 思考算两遍，Output+Reason 虚高）。
    func testAntigravitySplitsThinkingOutOfRawOutputAndConserves() {
        let buckets = TokenAccountingCatalog.antigravity.normalizedBuckets(
            rawInput: 100,
            cacheRead: 20,
            rawOutput: 50,
            rawReasoning: 30
        )

        XCTAssertEqual(buckets.input, 100)
        XCTAssertEqual(buckets.cacheRead, 20)
        XCTAssertEqual(buckets.output, 20, "Output = rawOutput − thinking")
        XCTAssertEqual(buckets.reasoning, 30, "Reason = thinking")
        XCTAssertEqual(buckets.billableOutput, 50, "Output + Reason == rawOutput（不虚高）")
        XCTAssertEqual(buckets.totalTokens, 170, "四桶守恒：input + cacheRead + output + reasoning = 100+20+20+30")
        XCTAssertEqual(
            TokenAccountingCatalog.antigravity.output,
            .reasoningIncluded,
            "口径锁：antigravity 必须声明 raw output 含 reasoning 子集"
        )
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
                TokenUsageBuckets(input: 100, cacheRead: 50, output: 20, reasoning: 10)
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

    // MARK: - 样本 Codable 兼容

    /// 旧缓存 JSON 不含 `durationSeconds` key（与 `sourceProviderID` 同一后加可选
    /// 字段先例）：合成 Codable 对可选字段 decodeIfPresent，缺 key 得 nil，缓存不炸。
    func testSampleDecodingWithoutDurationKeyStaysBackwardCompatible() throws {
        let legacyJSON = """
        {"completedAt":1000000000,"modelName":"glm-4.6","promptID":"p1","inputTokens":10,
         "cachedInputTokens":0,"outputTokens":5,"reasoningOutputTokens":2}
        """
        let legacy = try JSONDecoder().decode(LocalTokenUsageSample.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.durationSeconds, "缺 key 的旧缓存必须解码成 nil")
        XCTAssertNil(legacy.sourceProviderID)

        var sample = legacy
        sample.durationSeconds = 12.5
        let roundTrip = try JSONDecoder().decode(
            LocalTokenUsageSample.self,
            from: JSONEncoder().encode(sample)
        )
        XCTAssertEqual(roundTrip.durationSeconds, 12.5, "新写入的时长 round-trip 不丢")
    }
}
