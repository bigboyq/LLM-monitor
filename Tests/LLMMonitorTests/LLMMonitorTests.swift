import XCTest
import SQLite3
import Combine
import AppKit
@testable import LLM_monitor

final class LLMMonitorTests: XCTestCase {

    @MainActor
    func testMenuDisplayClockStartIsIdempotentAndStopCancels() async {
        let clock = MenuDisplayClock(tickIntervalNanoseconds: 1_000_000)
        clock.start()
        clock.start()
        XCTAssertTrue(clock.isRunning)
        XCTAssertEqual(clock.startCount, 1, "重复 start 不应创建第二个 display task")

        // Let at least one tick happen, then ensure cancellation prevents any
        // later ticks after the menu lifecycle ends.
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertGreaterThan(clock.tickCount, 0)
        clock.stop()
        XCTAssertFalse(clock.isRunning)
        let ticksAfterStop = clock.tickCount
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(clock.tickCount, ticksAfterStop)
    }

    func testBuiltInProviderIDsAreStableConfigurationKeys() {
        XCTAssertEqual(ProviderKind.minimaxTokenPlan.providerID, "minimax_token_plan")
        XCTAssertEqual(ProviderKind.codexChatGpt.providerID, "codex_chatgpt")
        XCTAssertEqual(ProviderKind.antigravity.providerID, "antigravity")
        XCTAssertEqual(ProviderKind.glmCodingPlan.providerID, "glm_coding_plan")
    }

    // MARK: - Binding Reset Date & Window Label Consolidation Tests

    func testBindingResetDateRules() {
        let primary = Date(timeIntervalSince1970: 1_000_000)
        let weekly = Date(timeIntervalSince1970: 2_000_000)

        // 1. Weekly is binding when weekly fraction * segments < primary fraction
        XCTAssertEqual(EquivalentQuotaAllocation.bindingResetDate(primaryFraction: 0.80, weeklyFraction: 0.12, primaryResetsAt: primary, weeklyResetsAt: weekly, segments: 6), weekly)

        // 2. Primary is binding when primary fraction < weekly fraction * segments
        XCTAssertEqual(EquivalentQuotaAllocation.bindingResetDate(primaryFraction: 0.08, weeklyFraction: 0.10, primaryResetsAt: primary, weeklyResetsAt: weekly, segments: 6), primary)

        // 3. Fallbacks when reset dates are missing
        XCTAssertEqual(EquivalentQuotaAllocation.bindingResetDate(primaryFraction: 0.80, weeklyFraction: 0.10, primaryResetsAt: primary, weeklyResetsAt: nil, segments: 6), primary)
        XCTAssertEqual(EquivalentQuotaAllocation.bindingResetDate(primaryFraction: 0.05, weeklyFraction: 0.50, primaryResetsAt: nil, weeklyResetsAt: weekly, segments: 6), weekly)
        XCTAssertNil(EquivalentQuotaAllocation.bindingResetDate(primaryFraction: 0.10, weeklyFraction: 0.50, primaryResetsAt: nil, weeklyResetsAt: nil, segments: 6))
        XCTAssertEqual(EquivalentQuotaAllocation.bindingResetDate(primaryFraction: 0.50, weeklyFraction: 0.10, primaryResetsAt: primary, weeklyResetsAt: weekly, segments: 3), weekly)
    }

    private func makeModel(name: String) -> ModelQuota {
        ModelQuota(
            modelName: name,
            intervalTotalCount: 0, intervalUsageCount: 0, intervalRemainingPercent: 50, intervalStatus: .present, intervalResetsAt: nil, intervalWindowSeconds: nil,
            weeklyTotalCount: 0, weeklyUsageCount: 0, weeklyRemainingPercent: 50, weeklyStatus: .present, weeklyResetsAt: Date(timeIntervalSince1970: 4_102_444_800), weeklyWindowSeconds: nil
        )
    }

    func testWeeklyMultiplierAndWindowLabelRules() {
        // Multipliers
        XCTAssertEqual(QuotaSummary.weeklyEquivalentMultiplier(providerKind: .minimaxTokenPlan, model: makeModel(name: "video")), 7)
        for name in ["general", "image", "speech", "music", "tts", "Video", "VIDEO"] {
            let expected = name.lowercased() == "video" ? 7 : 10
            XCTAssertEqual(QuotaSummary.weeklyEquivalentMultiplier(providerKind: .minimaxTokenPlan, model: makeModel(name: name)), expected)
        }
        XCTAssertEqual(QuotaSummary.weeklyEquivalentMultiplier(providerKind: .codexChatGpt, model: makeModel(name: "chatgpt_plan")), 6)
        XCTAssertEqual(QuotaSummary.weeklyEquivalentMultiplier(providerKind: .antigravity, model: makeModel(name: "gemini_models")), 6)
        XCTAssertEqual(QuotaSummary.weeklyEquivalentMultiplier(providerKind: .antigravity, model: makeModel(name: "claude_and_gpt_models")), 3)

        // Window labels
        XCTAssertEqual(QuotaSummary.primaryWindowLabel(providerKind: .minimaxTokenPlan, model: makeModel(name: "video")), "日")
        XCTAssertEqual(QuotaSummary.primaryWindowLabel(providerKind: .minimaxTokenPlan, model: makeModel(name: "general")), "5h")
        XCTAssertEqual(QuotaSummary.primaryWindowLabel(providerKind: .codexChatGpt, model: makeModel(name: "chatgpt_plan")), "5h")
    }

    // MARK: - ChatGPT Plan Row & Pill Label Consolidated Tests

    func testChatGPTPlanRowAndPillLabelRules() {
        // ChatGPT plan row rules
        XCTAssertTrue(QuotaSummary.shouldUseChatGPTPlanRow(providerKind: .codexChatGpt, model: makeModel(name: "chatgpt_plan")))
        XCTAssertTrue(QuotaSummary.shouldUseChatGPTPlanRow(providerKind: .codexChatGpt, model: makeModel(name: "ChatGPT_Plan")))
        XCTAssertFalse(QuotaSummary.shouldUseChatGPTPlanRow(providerKind: .minimaxTokenPlan, model: makeModel(name: "general")))
        XCTAssertFalse(QuotaSummary.shouldUseChatGPTPlanRow(providerKind: .codexChatGpt, model: makeModel(name: "gpt-4")))

        // Plan pill label rules
        XCTAssertEqual(QuotaSummary.planPillLabel(providerKind: .antigravity, planLabel: "Google AI Pro"), "AI Pro")
        XCTAssertEqual(QuotaSummary.planPillLabel(providerKind: .antigravity, planLabel: "Antigravity Pro"), "Pro")
        XCTAssertEqual(QuotaSummary.planPillLabel(providerKind: .antigravity, planLabel: "Free"), "Free")
        XCTAssertNil(QuotaSummary.planPillLabel(providerKind: .antigravity, planLabel: nil))
        XCTAssertNil(QuotaSummary.planPillLabel(providerKind: .antigravity, planLabel: ""))
        XCTAssertEqual(QuotaSummary.planPillLabel(providerKind: .codexChatGpt, planLabel: "Team"), "Team")
        XCTAssertNil(QuotaSummary.planPillLabel(providerKind: .codexChatGpt, planLabel: nil))
    }

    // MARK: - User Account Parsing & String Utilities

    func testParseAccountAndDateParserRules() {
        // User account parsing
        let statusUserTierWins = UserStatus(email: "alice@example.com", userTier: UserTier(name: "Free"), planStatus: PlanStatus(planInfo: PlanInfo(planDisplayName: "Pro Max")))
        let acc1 = AntigravityFetcher.parseAccount(userStatus: statusUserTierWins, fallbackTier: nil)
        XCTAssertEqual(acc1.planLabel, "Free")
        XCTAssertEqual(acc1.accountEmail, "alice@example.com")

        let statusFallback = UserStatus(email: "carol@example.com", userTier: nil, planStatus: nil)
        let acc2 = AntigravityFetcher.parseAccount(userStatus: statusFallback, fallbackTier: "Antigravity Free")
        XCTAssertEqual(acc2.planLabel, "Antigravity Free")

        let accNil = AntigravityFetcher.parseAccount(userStatus: nil, fallbackTier: nil)
        XCTAssertNil(accNil.planLabel)

        // String utilities
        XCTAssertEqual(StringUtilities.trimmedOrNil("  Free  "), "Free")
        XCTAssertNil(StringUtilities.trimmedOrNil("   "))
        XCTAssertEqual(StringUtilities.firstTrimmed(nil, "", "  ", "Pro"), "Pro")

        // DateParser ms & ISO8601
        let msDate = DateParser.parseMsTimestamp("1783234800000")
        XCTAssertNotNil(msDate)
        XCTAssertNotNil(DateParser.parseMsTimestamp(500.0))
    }
}
