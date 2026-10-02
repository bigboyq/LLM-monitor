import XCTest
@testable import LLM_monitor

/// Codex 计划行的用量明细合并（`ChatGPTPlanModelRow.preferUsageDetails`）。
/// 窗口切分 / 摘要见 `CodexUsageWindowTests`，扫描器增量与 F2 见
/// `CodexLocalUsageScannerTests`（均拆自本文件，逐字搬移零逻辑变化）。
final class CodexLocalUsageTests: XCTestCase {
    func testChatGPTPlanRowPrefersPreaggregatedDetailsWithoutDoubleCounting() {
        // CodexUsageDetails.primary 与 localSamples 都来自同一批 session 文件。
        // 例如 183M 未缓存输入 + 369M cached = 552M 原始 input；旧实现会把
        // details 和 samples 相加，错误显示成 366M 未缓存 + 738M cached。
        let preaggregated = UsageMetricSummary(
            prompts: 3,
            rounds: 30,
            inputTokens: 552_000_000,
            cachedInputTokens: 369_000_000,
            outputTokens: 12_000_000,
            reasoningOutputTokens: 4_000_000
        )
        var fallbackEvaluated = false

        func makeFallback() -> UsageMetricSummary? {
            fallbackEvaluated = true
            return preaggregated
        }

        let resolved = ChatGPTPlanModelRow.preferUsageDetails(preaggregated, makeFallback())

        XCTAssertEqual(resolved, preaggregated)
        XCTAssertEqual(resolved?.uncachedInputTokens, 183_000_000)
        XCTAssertEqual(resolved?.cachedInputTokens, 369_000_000)
        XCTAssertFalse(fallbackEvaluated, "详情已存在时不应再次聚合同一批 local samples")
    }

    func testChatGPTPlanRowFallsBackToLocalSamplesWhenDetailsAreMissing() {
        let fallback = UsageMetricSummary(
            prompts: 1,
            rounds: 2,
            inputTokens: 100,
            cachedInputTokens: 40,
            outputTokens: 20,
            reasoningOutputTokens: 5
        )

        XCTAssertEqual(
            ChatGPTPlanModelRow.preferUsageDetails(nil, fallback),
            fallback
        )
    }
}
