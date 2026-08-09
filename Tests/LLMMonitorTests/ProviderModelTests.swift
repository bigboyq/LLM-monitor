import XCTest
import Foundation
import AppKit
@testable import LLM_monitor

final class ProviderModelTests: XCTestCase {

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

    func testModelQuotaTimeRemainingFraction() {
        let futureDate = Date().addingTimeInterval(3.5 * 24 * 60 * 60) // 3.5 days in future

        // 1. ChatGPT Plan single primary window (7 days / 604800s)
        let chatgptQuota = ModelQuota(
            modelName: "chatgpt_plan",
            intervalTotalCount: 0,
            intervalUsageCount: 0,
            intervalRemainingPercent: 97,
            intervalStatus: .present,
            intervalResetsAt: futureDate,
            intervalWindowSeconds: 7 * 24 * 60 * 60,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 0,
            weeklyStatus: .absent,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
        XCTAssertNotNil(chatgptQuota.intervalTimeRemainingFraction)
        if let fraction = chatgptQuota.intervalTimeRemainingFraction {
            XCTAssertGreaterThan(fraction, 0.45)
            XCTAssertLessThan(fraction, 0.55)
        }

        // 2. 5h short interval window (18000s) -> should return nil for intervalTimeRemainingFraction
        let shortQuota = ModelQuota(
            modelName: "general",
            intervalTotalCount: 0,
            intervalUsageCount: 0,
            intervalRemainingPercent: 50,
            intervalStatus: .present,
            intervalResetsAt: futureDate,
            intervalWindowSeconds: 5 * 60 * 60,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 50,
            weeklyStatus: .present,
            weeklyResetsAt: futureDate,
            weeklyWindowSeconds: 7 * 24 * 60 * 60
        )
        XCTAssertNil(shortQuota.intervalTimeRemainingFraction)
        XCTAssertNotNil(shortQuota.weeklyTimeRemainingFraction)
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

    // MARK: - ProviderKind Consistency & Unified Quota Hover Tests

    @MainActor
    func testProviderKindConsistencyAndHoverRules() {
        for kind in ProviderKind.allCases {
            XCTAssertFalse(kind.providerID.isEmpty)
            XCTAssertFalse(kind.logTag.isEmpty)
            XCTAssertFalse(kind.logTag.contains("_"))
        }

        let ids = ProviderKind.allCases.map(\.providerID)
        XCTAssertEqual(Set(ids).count, ids.count)

        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(300)
        let samples = [
            LocalTokenUsageSample(completedAt: start, modelName: "MiniMax-M3", promptID: "p1", inputTokens: 10, cachedInputTokens: 4, outputTokens: 3, reasoningOutputTokens: 0),
            LocalTokenUsageSample(completedAt: start.addingTimeInterval(1), modelName: "MiniMax-M3", promptID: "p1", inputTokens: 20, cachedInputTokens: 5, outputTokens: 7, reasoningOutputTokens: 0)
        ]
        let summary = LocalUsageSummaryBuilder.summary(samples: samples, providerKind: .minimaxTokenPlan, quotaModelName: "general", start: start, end: end)
        XCTAssertEqual(summary?.rounds, 2)
        XCTAssertEqual(summary?.inputTokens, 30)
    }

    func testLocalUsageWindowBoundsUseFallbackWhenResetTimeIsMissing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let bounds = LocalUsageSummaryBuilder.windowBounds(
            resetsAt: nil,
            explicitWindowSeconds: nil,
            fallbackSeconds: 5 * 60 * 60,
            now: now
        )

        XCTAssertEqual(bounds?.start, now)
        XCTAssertEqual(bounds?.end, now.addingTimeInterval(5 * 60 * 60))
    }

    func testLocalUsageWindowBoundsPreferServerResetTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(90 * 60)
        let bounds = LocalUsageSummaryBuilder.windowBounds(
            resetsAt: reset,
            explicitWindowSeconds: 60 * 60,
            fallbackSeconds: 5 * 60 * 60,
            now: now
        )

        XCTAssertEqual(bounds?.end, reset)
        XCTAssertEqual(bounds?.start, reset.addingTimeInterval(-60 * 60))
    }

    // MARK: - ModelQuota.colorLevel (barColor / healthLevel / summaryColor 共享阈值)

    func testModelQuotaColorLevelShortWindow() {
        // timeFraction=nil: 5h 短窗口，固定 30% 黄阈值
        XCTAssertEqual(ModelQuota.colorLevel(percent: 0, timeFraction: nil), .critical)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 14.9, timeFraction: nil), .critical)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 15, timeFraction: nil), .warning)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 29.9, timeFraction: nil), .warning)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 30, timeFraction: nil), .healthy)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 100, timeFraction: nil), .healthy)
    }

    func testModelQuotaColorLevelLongWindowTimeAware() {
        // timeFraction!=nil: 长窗口，黄阈值 = min(time% * 100, 50)
        // 还剩 100% 时间 → 阈值 50%
        XCTAssertEqual(ModelQuota.colorLevel(percent: 49, timeFraction: 1.0), .warning)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 50, timeFraction: 1.0), .healthy)
        // 还剩 20% 时间 → 阈值 20%
        XCTAssertEqual(ModelQuota.colorLevel(percent: 19, timeFraction: 0.2), .warning)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 20, timeFraction: 0.2), .healthy)
        // 临界永远是 15%
        XCTAssertEqual(ModelQuota.colorLevel(percent: 14.9, timeFraction: 0.2), .critical)
    }

    func testIntervalTimeRemainingFractionDropsModelNameHack() {
        // modelName 不再决定 fallback：必须显式有 intervalWindowSeconds
        let q = ModelQuota(
            modelName: "chatgpt_plan",
            intervalTotalCount: 0, intervalUsageCount: 0,
            intervalRemainingPercent: 100, intervalStatus: .present,
            intervalResetsAt: Date().addingTimeInterval(7 * 24 * 60 * 60),
            intervalWindowSeconds: nil,  // 显式 nil
            weeklyTotalCount: 0, weeklyUsageCount: 0,
            weeklyRemainingPercent: 0, weeklyStatus: .absent,
            weeklyResetsAt: nil, weeklyWindowSeconds: nil
        )
        XCTAssertNil(q.intervalTimeRemainingFraction, "没有 intervalWindowSeconds 就不能 fallback 到 modelName=chatgpt_plan")
    }

    func testBindingConstraintTextBothBranches() {
        let weeklyBindingText = QuotaWindowsHoverPresentation.bindingConstraintText(
            primaryLabel: "5h", weeklyIsBinding: true, weeklyEquivalentMultiplier: 5, weeklyLabel: "周额度"
        )
        XCTAssertTrue(weeklyBindingText.contains("取周额度"))
        XCTAssertTrue(weeklyBindingText.contains("5h还有余量但周额度已先耗尽"))
        XCTAssertFalse(weeklyBindingText.contains("取5h是 binding constraint"))

        let primaryBindingText = QuotaWindowsHoverPresentation.bindingConstraintText(
            primaryLabel: "5h", weeklyIsBinding: false, weeklyEquivalentMultiplier: 5, weeklyLabel: "周"
        )
        XCTAssertTrue(primaryBindingText.contains("取5h窗口"))
        XCTAssertTrue(primaryBindingText.contains("5h是 binding constraint"))
    }

    func testEquivalentQuotaAllocationSegmentFillsBoundaryConditions() {
        // 0% weekly units -> 0 fills
        let zeroFills = EquivalentQuotaAllocation.segmentFills(
            primaryFraction: 0, weeklyFraction: 0, segments: 5
        )
        XCTAssertEqual(zeroFills, [0, 0, 0, 0, 0])

        // 100% (weeklyUnits = 5) -> [1, 1, 1, 1, 1]
        let fullFills = EquivalentQuotaAllocation.segmentFills(
            primaryFraction: 1.0, weeklyFraction: 1.0, segments: 5
        )
        XCTAssertEqual(fullFills, [1.0, 1.0, 1.0, 1.0, 1.0])

        // Exact tie (weeklyUnits == normalizedPrimary = 0.5) -> [0.5, 0, 0, 0, 0]
        let tieFills = EquivalentQuotaAllocation.segmentFills(
            primaryFraction: 0.5, weeklyFraction: 0.1, segments: 5
        )
        XCTAssertEqual(tieFills, [0.5, 0.0, 0.0, 0.0, 0.0])
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
            dayStart: day, inputTokens: 10, cacheReadTokens: 20,
            cacheWriteTokens: 30, outputTokens: 40, reasoningTokens: 50,
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
