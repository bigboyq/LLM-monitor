import XCTest
import Foundation
import AppKit
@testable import LLM_monitor

final class ProviderModelTests: XCTestCase {

    func testClientProviderSummaryUsesAggregateTokensAndCacheHitRate() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = ClientProviderUsageSummary(
            clientID: ClientID.openCode,
            quotaProviderID: QuotaProviderID.openAI,
            providerName: "ChatGPT Plan",
            dailyTokenUsage: [
                UnifiedDailyTokenUsage(dayStart: day, input: 80, cacheRead: 20, output: 30, reasoning: 10)
            ],
            recentSamples: [
                LocalTokenUsageSample(
                    completedAt: day,
                    modelName: "gpt-5.6-sol",
                    promptID: "prompt-1",
                    inputTokens: 100,
                    cachedInputTokens: 20,
                    outputTokens: 30,
                    reasoningOutputTokens: 10
                )
            ],
            scannedAt: day
        )

        XCTAssertEqual(summary.totalTokens, 140)
        XCTAssertEqual(summary.inputTokens, 80)
        XCTAssertEqual(summary.cacheReadTokens, 20)
        XCTAssertEqual(summary.outputTokens, 30)
        XCTAssertEqual(summary.reasoningTokens, 10)
        XCTAssertEqual(summary.cacheHitRate ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(summary.costEstimate.currency, .usd)
        XCTAssertEqual(summary.costEstimate.value ?? -1, 0.001128, accuracy: 0.000001)
        XCTAssertEqual(summary.priceTextByDay[day], "$0.00")
    }

    func testDeepseekPricingUsesOffPeakBaseAndDoublesAtPeak() {
        let calendar = DeepseekPeakWindow.beijingCalendar
        // 2026-08-05 是周三：10:00 落在工作日 9–12 高峰 slot，13:00 是工作日非高峰。
        let day = calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 10))!
        let peak = day
        let offPeak = day.addingTimeInterval(3 * 60 * 60)
        let sample = LocalTokenUsageSample(
            completedAt: peak,
            modelName: "deepseek-v4-flash",
            promptID: "p1",
            inputTokens: 1_000_000,
            cachedInputTokens: 200_000,
            outputTokens: 100_000,
            reasoningOutputTokens: 0
        )

        let peakEstimate = ModelPricingCatalog.estimate(
            samples: [sample],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .defaultWindow
        )
        XCTAssertEqual(peakEstimate.value ?? -1, 2.408, accuracy: 0.000001)

        let offPeakSample = LocalTokenUsageSample(
            completedAt: offPeak,
            modelName: "deepseek-v4-flash",
            promptID: "p2",
            inputTokens: 1_000_000,
            cachedInputTokens: 200_000,
            outputTokens: 100_000,
            reasoningOutputTokens: 0
        )
        let offPeakEstimate = ModelPricingCatalog.estimate(
            samples: [offPeakSample],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .defaultWindow
        )
        XCTAssertEqual(offPeakEstimate.value ?? -1, 1.204, accuracy: 0.000001)

        // 官方口径：高峰永不含周末 —— 周六（2026-08-08）/ 周日（2026-08-09）
        // 落在北京时间 9–12 窗口内也按平价 1× 计价。
        for (weekday, dayOffset) in [("周六", 8), ("周日", 9)] {
            let weekend = calendar.date(from: DateComponents(year: 2026, month: 8, day: dayOffset, hour: 10))!
            let weekendSample = LocalTokenUsageSample(
                completedAt: weekend,
                modelName: "deepseek-v4-flash",
                promptID: "weekend-\(weekday)",
                inputTokens: 1_000_000,
                cachedInputTokens: 200_000,
                outputTokens: 100_000,
                reasoningOutputTokens: 0
            )
            let weekendEstimate = ModelPricingCatalog.estimate(
                samples: [weekendSample],
                quotaProviderID: QuotaProviderID.deepseek,
                deepseekPeakWindow: .defaultWindow
            )
            XCTAssertEqual(weekendEstimate.value ?? -1, 1.204, accuracy: 0.000001,
                           "\(weekday) 高峰 slot 内必须按平价（1×）计价")
        }
    }

    func testDisplayOrderHonorsKnownIDsAndAppendsNewItemsByDefaultOrder() {
        let items = ["zeta", "alpha", "beta"]
        let ordered = DisplayOrder.ordered(
            items,
            preferredIDs: ["beta", "missing", "beta", "alpha"],
            id: { $0 },
            by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        )

        XCTAssertEqual(ordered, ["beta", "alpha", "zeta"])
    }

    func testProviderCardOrderRoundTripsAndRemainsOptionalByDefault() throws {
        var config = AppConfig.default
        XCTAssertNil(config.providerCardOrder)

        config.providerCardOrder = [
            QuotaProviderID.deepseek,
            QuotaProviderID.minimax
        ]
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)

        XCTAssertEqual(decoded.providerCardOrder, config.providerCardOrder)
    }

    // MARK: - QuotaInfo: accountEmail

    func testQuotaInfoAccountEmailRoundTrip() throws {
        let info = QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: "Free",
            accountEmail: "eve@example.com",
            codexUsageDetails: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(info)
        let decoded = try JSONDecoder().decode(QuotaInfo.self, from: data)
        XCTAssertEqual(decoded.accountEmail, "eve@example.com")
        XCTAssertEqual(decoded.planLabel, "Free")
    }

    func testShouldUseDeepseekBalanceRowForDeepseekProvider() {
        let model = ModelQuota(
            modelName: "deepseek_balance",
            intervalTotalCount: 0,
            intervalUsageCount: 0,
            intervalRemainingPercent: 100,
            intervalStatus: .present,
            intervalResetsAt: nil,
            intervalWindowSeconds: nil,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 100,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
        XCTAssertTrue(QuotaSummary.shouldUseDeepseekBalanceRow(providerKind: .deepseek, model: model))
        XCTAssertFalse(QuotaSummary.shouldUseDeepseekBalanceRow(providerKind: .minimaxTokenPlan, model: model))
    }

    func testQuotaInfoAccountEmailBackwardCompatibility() throws {
        // 旧版 JSON 没有 accountEmail 字段 → 应 decode 成 nil 而不是崩
        let json = """
        {
          "models": [],
          "resetCredits": null,
          "planLabel": "Free",
          "codexUsageDetails": null,
          "fetchedAt": "2026-07-15T00:00:00Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let info = try decoder.decode(QuotaInfo.self, from: json)
        XCTAssertEqual(info.planLabel, "Free")
        XCTAssertNil(info.accountEmail)
    }

    func testMenuShowsSetupGuideOnlyWhenAllProvidersAreNotConfigured() {
        let makeStatus: (ProviderStatus.State) -> ProviderStatus = { state in
            ProviderStatus(
                id: UUID().uuidString,
                displayName: "test",
                kind: .minimaxTokenPlan,
                iconSystemName: "circle",
                accentColor: .minimax,
                refreshIntervalSeconds: 300,
                state: state
            )
        }

        XCTAssertFalse(MenuContentView.shouldShowSetupGuide(for: []))
        XCTAssertTrue(MenuContentView.shouldShowSetupGuide(for: [
            makeStatus(.notConfigured(reason: "API Key 未填写")),
            makeStatus(.notConfigured(reason: "已禁用"))
        ]))
        XCTAssertFalse(MenuContentView.shouldShowSetupGuide(for: [
            makeStatus(.ready),
            makeStatus(.notConfigured(reason: "已禁用"))
        ]))
        XCTAssertFalse(MenuContentView.shouldShowSetupGuide(for: [
            makeStatus(.failed(message: "error", lastSuccess: nil))
        ]))
    }

    // MARK: - ProviderConfig: serverPath removed

    func testProviderConfigDecodeIgnoresServerPath() throws {
        // 旧版 config.json 可能还残留 serverPath 字段，应被忽略而非报错
        let json = """
        {
          "enabled": true,
          "serverPath": "/Applications/Antigravity.app",
          "refreshIntervalSeconds": 60
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(ProviderConfig.self, from: json)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.refreshIntervalSeconds, 60)
        XCTAssertNil(config.apiKey)
    }

    func testProviderConfigEncodeOmitsServerPath() throws {
        let config = ProviderConfig(enabled: true, refreshIntervalSeconds: 60)
        let data = try JSONEncoder().encode(config)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("serverPath"), "encode 不应写出已删除字段: \(json)")
        XCTAssertTrue(json.contains("\"enabled\""))
    }

    func testProviderConfigDecodeIgnoresDeepseekPeakWeekdaysOnly() throws {
        // DeepSeek「仅工作日」开关已移除（高峰永不含周末为官方固定口径）：
        // 旧版 config.json 残留的 deepseekPeakWeekdaysOnly 字段应被忽略而非报错，
        // 也不会再被写回。
        let json = """
        {
          "enabled": true,
          "deepseekPeakWeekdaysOnly": false,
          "refreshIntervalSeconds": 60
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(ProviderConfig.self, from: json)
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.refreshIntervalSeconds, 60)

        let data = try JSONEncoder().encode(config)
        let encoded = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("deepseekPeakWeekdaysOnly"), "encode 不应写出已删除字段: \(encoded)")
    }

    func testMinimaxLocalUsageEqualityIgnoresScannedAt() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let today = MinimaxDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, turns: 3, rounds: 10)
        let days = [MinimaxDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, turns: 3, rounds: 10)]
        let lhs = MinimaxLocalUsage(
            today: today,
            dailyTokenUsage: days,
            scannedAt: Date(timeIntervalSince1970: 1_000_000),
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        let rhs = MinimaxLocalUsage(
            today: today,
            dailyTokenUsage: days,
            scannedAt: Date(timeIntervalSince1970: 9_999_999),  // 不同的 scannedAt
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        XCTAssertEqual(lhs, rhs, "业务字段相同 + scannedAt 不同 → == 应当 true (no-op 生效)")
    }

    /// 业务字段不同时 == 必须 false（不能让 no-op 误判命中）。
    func testMinimaxLocalUsageEqualityDetectsBusinessFieldChanges() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let base = MinimaxLocalUsage(
            today: MinimaxDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, turns: 3, rounds: 10),
            dailyTokenUsage: [MinimaxDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, turns: 3, rounds: 10)],
            scannedAt: Date(timeIntervalSince1970: 1_000_000),
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        // sessionCount 变 → !=
        let sessionCountChanged = MinimaxLocalUsage(
            today: base.today,
            dailyTokenUsage: base.dailyTokenUsage,
            scannedAt: base.scannedAt,
            sessionCount: 6,
            eventCount: 50,
            failedSessionCount: 0
        )
        XCTAssertNotEqual(base, sessionCountChanged)
        // eventCount 变 → !=
        let eventCountChanged = MinimaxLocalUsage(
            today: base.today,
            dailyTokenUsage: base.dailyTokenUsage,
            scannedAt: base.scannedAt,
            sessionCount: 5,
            eventCount: 51,
            failedSessionCount: 0
        )
        XCTAssertNotEqual(base, eventCountChanged)
        // dailyTokenUsage 内容变 → !=
        let dayChanged = MinimaxDailyUsage(dayStart: day, inputTokens: 999, outputTokens: 50, turns: 3, rounds: 10)
        let dailyChanged = MinimaxLocalUsage(
            today: base.today,
            dailyTokenUsage: [dayChanged],
            scannedAt: base.scannedAt,
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        XCTAssertNotEqual(base, dailyChanged)
    }

    func testHealthLevelNewThresholds() {
        let futureDate = Date().addingTimeInterval(3.5 * 24 * 60 * 60) // 50% time remaining (~3.5d of 7d)

        // 1. 5h window: 14% -> critical (red)
        let c1 = ModelQuota(
            modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0,
            intervalRemainingPercent: 14, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: 18000,
            weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 100, weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil
        )
        XCTAssertEqual(c1.healthLevel, .critical)

        // 2. 5h window: 25% -> warning (yellow)
        let w1 = ModelQuota(
            modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0,
            intervalRemainingPercent: 25, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: 18000,
            weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 100, weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil
        )
        XCTAssertEqual(w1.healthLevel, .warning)

        // 3. 5h window: 30% -> healthy (green)
        let h1 = ModelQuota(
            modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0,
            intervalRemainingPercent: 30, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: 18000,
            weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 100, weeklyStatus: .absent, weeklyResetsAt: nil, weeklyWindowSeconds: nil
        )
        XCTAssertEqual(h1.healthLevel, .healthy)

        // 4. Week window with 80% time remaining -> yellow threshold is min(80, 50) = 50%
        // weeklyRemaining = 45% -> warning (yellow)
        let farFutureDate = Date().addingTimeInterval(5.6 * 24 * 60 * 60)
        let w2 = ModelQuota(
            modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0,
            intervalRemainingPercent: 100, intervalStatus: .absent, intervalResetsAt: nil, intervalWindowSeconds: nil,
            weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 45, weeklyStatus: .present, weeklyResetsAt: farFutureDate, weeklyWindowSeconds: 7 * 24 * 60 * 60
        )
        XCTAssertEqual(w2.healthLevel, .warning)

        // 5. Week window with 20% time remaining (1.4d in future) -> yellow threshold is min(20, 50) = 20%
        // weeklyRemaining = 25% (>= 20%) -> healthy (green)
        let nearExpiryDate = Date().addingTimeInterval(1.4 * 24 * 60 * 60)
        let h2 = ModelQuota(
            modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0,
            intervalRemainingPercent: 100, intervalStatus: .absent, intervalResetsAt: nil, intervalWindowSeconds: nil,
            weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 25, weeklyStatus: .present, weeklyResetsAt: nearExpiryDate, weeklyWindowSeconds: 7 * 24 * 60 * 60
        )
        XCTAssertEqual(h2.healthLevel, .healthy)

        // 6. Dual window: 5h is 20% (warning), week is 10% (critical) -> min is critical (red)
        let combo = ModelQuota(
            modelName: "general", intervalTotalCount: 0, intervalUsageCount: 0,
            intervalRemainingPercent: 20, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: 18000,
            weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 10, weeklyStatus: .present, weeklyResetsAt: futureDate, weeklyWindowSeconds: 7 * 24 * 60 * 60
        )
        XCTAssertEqual(combo.healthLevel, .critical)
    }

    private struct MockDailyUsage: LocalUsageDaily {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
        let reasoningTokens: Int
        let turns: Int
        let rounds: Int

        var id: Date { dayStart }
        var dayStart: Date { Date() }
        var input: Int { inputTokens }
        var cacheRead: Int { cacheReadTokens }
        var cacheWrite: Int { cacheWriteTokens }
        var output: Int { outputTokens }
        var reasoning: Int { reasoningTokens }
        var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens }
    }

    func testAllDailyUsageTypesConformToLocalUsageDaily() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let antigravity = AntigravityDailyUsage(
            dayStart: day, inputTokens: 10,
 outputTokens: 40,
 cacheReadTokens: 20,
 cacheWriteTokens: 30, reasoningTokens: 50,
            turns: 6, rounds: 7
        )
        let minimax = MinimaxDailyUsage(
            dayStart: day, inputTokens: 10, outputTokens: 40,
            cacheReadTokens: 20, cacheWriteTokens: 30, reasoningTokens: 50,
            turns: 6, rounds: 7
        )
        let opencode = OpencodeDailyUsage(
            dayStart: day, inputTokens: 10, outputTokens: 40,
            cacheReadTokens: 20, cacheWriteTokens: 30, reasoningTokens: 50,
            turns: 6, rounds: 7
        )
        let glm = GlmDailyUsage(
            dayStart: day, inputTokens: 10, outputTokens: 40,
            cacheReadTokens: 20, cacheWriteTokens: 30, reasoningTokens: 50,
            turns: 6, rounds: 7
        )
        let codex = DailyTokenUsage(
            dayStart: day, inputTokens: 30, cachedInputTokens: 20,
            outputTokens: 40, reasoningOutputTokens: 50, rounds: 7, turns: 6
        )

        let dailyValues: [any LocalUsageDaily] = [antigravity, minimax, opencode, glm, codex]
        XCTAssertEqual(dailyValues.map(\.input), [10, 10, 10, 10, 10])
        XCTAssertEqual(dailyValues.map(\.cacheRead), [20, 20, 20, 20, 20])
        XCTAssertEqual(dailyValues.map(\.cacheWrite), [30, 30, 30, 30, 0])
        XCTAssertEqual(dailyValues.map(\.output), [40, 40, 40, 40, 40])
        XCTAssertEqual(dailyValues.map(\.reasoning), [50, 50, 50, 50, 50])
        XCTAssertEqual(dailyValues.map(\.turns), [6, 6, 6, 6, 6])
        XCTAssertEqual(dailyValues.map(\.rounds), [7, 7, 7, 7, 7])
    }

    func testLocalUsageChartScaleCrossDayMax() {
        // Day 1: high output (1000), low reasoning (10)
        let day1 = MockDailyUsage(inputTokens: 100, outputTokens: 1000, cacheReadTokens: 50, cacheWriteTokens: 0, reasoningTokens: 10, turns: 1, rounds: 1)
        // Day 2: low output (10), high reasoning (1000)
        let day2 = MockDailyUsage(inputTokens: 200, outputTokens: 10, cacheReadTokens: 100, cacheWriteTokens: 0, reasoningTokens: 1000, turns: 1, rounds: 1)

        let scale = LocalUsageChartScale(days: [day1, day2])
        // Output total for Day 1 is 1010, Day 2 is 1010. Max output total across days should be 1010.
        XCTAssertEqual(scale.maxOutputWeight, 1010)
        XCTAssertEqual(scale.maxUncached, 200)
    }
}
