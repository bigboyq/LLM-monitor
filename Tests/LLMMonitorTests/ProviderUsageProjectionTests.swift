import XCTest
import Foundation
@testable import LLM_monitor

final class ProviderUsageProjectionTests: XCTestCase {

    func testProviderUsageProjectionAggregatesMultipleClientsByDay() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let first = ClientUsageContribution(
            clientID: ClientID.openCode,
            displayName: "OpenCode",
            dailyTokenUsage: [
                UnifiedDailyTokenUsage(dayStart: day, input: 100, cacheRead: 20, output: 30, reasoning: 10, rounds: 2)
            ],
            scannedAt: day
        )
        let second = ClientUsageContribution(
            clientID: ClientID.dsh,
            displayName: "DSH",
            dailyTokenUsage: [
                UnifiedDailyTokenUsage(dayStart: day, input: 40, cacheRead: 5, output: 15, reasoning: 5, rounds: 1)
            ],
            scannedAt: day.addingTimeInterval(10)
        )

        let projection = ProviderUsageProjection(contributions: [first, second])
        let total = try! XCTUnwrap(projection.dailyTokenUsage.first)
        XCTAssertEqual(total.input, 140)
        XCTAssertEqual(total.cacheRead, 25)
        XCTAssertEqual(total.output, 45)
        XCTAssertEqual(total.reasoning, 15)
        XCTAssertEqual(total.totalTokens, 225)
        XCTAssertEqual(projection.clientIDs, [ClientID.openCode, ClientID.dsh])
        XCTAssertEqual(projection.scannedAt, day.addingTimeInterval(10))
    }

    func testCurrentDayUsesSamplesWhenDailyAggregateIsBehind() {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let sample = LocalTokenUsageSample(
            completedAt: now,
            modelName: "MiniMax-M3",
            promptID: "dsh:turn-1",
            inputTokens: 381_000 + 26_000_000,
            cachedInputTokens: 26_000_000,
            outputTokens: 71_000,
            reasoningOutputTokens: 0,
            sourceProviderID: "dsh:minimax"
        )

        let summary = ClientProviderUsageSummary(
            clientID: ClientID.dsh,
            quotaProviderID: QuotaProviderID.minimax,
            providerName: "MiniMax",
            dailyTokenUsage: [UnifiedDailyTokenUsage(dayStart: today)],
            recentSamples: [sample],
            scannedAt: now
        )

        let day = try! XCTUnwrap(summary.dailyTokenUsage.first)
        XCTAssertEqual(day.input, 381_000)
        XCTAssertEqual(day.cacheRead, 26_000_000)
        XCTAssertEqual(day.output, 71_000)
        XCTAssertEqual(summary.priceTextByDay[today], "¥12.32")
    }

    func testDeepseekDshPricingKeepsSeparateCacheReadBucket() {
        let sample = LocalTokenUsageSample(
            completedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modelName: "deepseek-v4-flash",
            promptID: "dsh-sample",
            inputTokens: 698_000 + 39_000_000,
            cachedInputTokens: 39_000_000,
            outputTokens: 71_000,
            reasoningOutputTokens: 0,
            sourceProviderID: "dsh:deepseek-official"
        )

        let estimate = ModelPricingCatalog.estimate(
            samples: [sample],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: DeepseekPeakWindow(slots: [], weekdaysOnly: true)
        )

        XCTAssertEqual(estimate.value ?? -1, 1.762, accuracy: 0.000001)
        XCTAssertEqual(estimate.currency, .cny)
    }

    func testMiniMaxDshM3PricingKeepsSeparateCacheReadBucket() {
        let sample = LocalTokenUsageSample(
            completedAt: Date(timeIntervalSince1970: 1_700_000_000),
            modelName: "MiniMax-M3",
            promptID: "dsh-minimax-sample",
            inputTokens: 381_000 + 26_000_000,
            cachedInputTokens: 26_000_000,
            outputTokens: 71_000,
            reasoningOutputTokens: 0,
            sourceProviderID: "dsh:minimax"
        )

        let estimate = ModelPricingCatalog.estimate(
            samples: [sample],
            quotaProviderID: QuotaProviderID.minimax
        )

        XCTAssertEqual(estimate.value ?? -1, 12.3165, accuracy: 0.000001)
        XCTAssertEqual(estimate.currency, .cny)
    }
}
