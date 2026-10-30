import XCTest
import Foundation
@testable import LLM_monitor

final class ModelQuotaWindowBoundsTests: XCTestCase {

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
        // 可注入时间版本与计算属性一致（聚合口径用同一份 now）。
        if let viaVar = chatgptQuota.intervalTimeRemainingFraction,
           let viaAt = chatgptQuota.intervalTimeRemainingFraction(at: Date()) {
            XCTAssertEqual(viaVar, viaAt, accuracy: 0.001)
        } else {
            XCTFail("ChatGPT Plan 单 7d 窗口应能取到 interval 剩余时间比例")
        }

        // 2. 5h short interval window (18000s) -> now participates in intervalTimeRemainingFraction
        let now = Date()
        let halfWindowDate = now.addingTimeInterval(2.5 * 3600)
        let shortQuota = ModelQuota(
            modelName: "general",
            intervalTotalCount: 0,
            intervalUsageCount: 0,
            intervalRemainingPercent: 50,
            intervalStatus: .present,
            intervalResetsAt: halfWindowDate,
            intervalWindowSeconds: 5 * 60 * 60,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 50,
            weeklyStatus: .present,
            weeklyResetsAt: futureDate,
            weeklyWindowSeconds: 7 * 24 * 60 * 60
        )
        XCTAssertNotNil(shortQuota.intervalTimeRemainingFraction)
        if let fraction = shortQuota.intervalTimeRemainingFraction(at: now) {
            XCTAssertEqual(fraction, 0.5, accuracy: 0.01)
        }
        XCTAssertNotNil(shortQuota.weeklyTimeRemainingFraction)
    }

    /// M1 消费面防御回归网：周窗口 present 但 `weeklyResetsAt` 缺失（服务端
    /// schema 漂移 / 旧缓存样本等防御路径）时，`weeklyTimeRemainingFraction`
    /// 降级返回 nil（固定 30% 黄线），不再在 Debug(-Onone) 构建断言 trap
    /// 菜单栏 App。注意：本用例在修复前的 Debug 测试下会直接 crash。
    func testWeeklyTimeRemainingFractionDegradesGracefullyWhenResetMissing() {
        let degraded = ModelQuota(
            modelName: "general",
            intervalTotalCount: 0,
            intervalUsageCount: 0,
            intervalRemainingPercent: 50,
            intervalStatus: .absent,
            intervalResetsAt: nil,
            intervalWindowSeconds: nil,
            weeklyTotalCount: 0,
            weeklyUsageCount: 0,
            weeklyRemainingPercent: 50,
            weeklyStatus: .present,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: nil
        )
        XCTAssertTrue(degraded.hasWeeklyWindow)
        // 降级为 nil（固定 30% 黄线），而不是 trap
        XCTAssertNil(degraded.weeklyTimeRemainingFraction)
        XCTAssertNil(degraded.weeklyTimeRemainingFraction(at: Date(timeIntervalSince1970: 1_800_000_000)))
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

    func testModelQuotaColorLevelNilTimeFraction() {
        // timeFraction=nil: 无重置时间/无窗口，基线分母 100%：< 30% 红，< 60% 黄，>= 60% 绿
        XCTAssertEqual(ModelQuota.colorLevel(percent: 0, timeFraction: nil), .critical)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 29.9, timeFraction: nil), .critical)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 30, timeFraction: nil), .warning)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 59.9, timeFraction: nil), .warning)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 60, timeFraction: nil), .healthy)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 100, timeFraction: nil), .healthy)
    }

    func testModelQuotaColorLevelTimeAware() {
        // 周额度与 5h 额度统一的时间感知标色算法：
        // 分母 = 100% * 剩余时间百分比%
        // < 30% 红色，< 60% 黄色，>= 60% 绿色

        // 1. 还剩 100% 时间 (刚重置，t=1.0) → 分母 100%
        XCTAssertEqual(ModelQuota.colorLevel(percent: 0, timeFraction: 1.0), .critical)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 29.9, timeFraction: 1.0), .critical)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 30, timeFraction: 1.0), .warning)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 59.9, timeFraction: 1.0), .warning)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 60, timeFraction: 1.0), .healthy)

        // 2. 还剩 50% 时间 (t=0.5) → 分母 50%
        // 临界 = 30% * 0.5 = 15%，预警 = 60% * 0.5 = 30%
        XCTAssertEqual(ModelQuota.colorLevel(percent: 14.9, timeFraction: 0.5), .critical)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 15, timeFraction: 0.5), .warning)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 29.9, timeFraction: 0.5), .warning)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 30, timeFraction: 0.5), .healthy)

        // 3. 用户经典诉求场景：5h 窗口还剩 5 分钟 (t = 5/300 = 1/60 ≈ 0.0167)
        // 额度剩余 15%：明明够用，绝对不是红色，也不是黄色，而是健康（绿色）！
        let fiveMinutesInFiveHours = 5.0 / 300.0
        XCTAssertEqual(ModelQuota.colorLevel(percent: 15, timeFraction: fiveMinutesInFiveHours), .healthy)
        // 即使只剩 1.5% 额度，对于 5 分钟（1.0% 预警线）而言也是健康的
        XCTAssertEqual(ModelQuota.colorLevel(percent: 1.5, timeFraction: fiveMinutesInFiveHours), .healthy)
        // 临界线 = 30% * (1/60) = 0.5%，剩 0.3% 时才标红
        XCTAssertEqual(ModelQuota.colorLevel(percent: 0.3, timeFraction: fiveMinutesInFiveHours), .critical)
        // 预警线 = 60% * (1/60) = 1.0%，剩 0.7% 时标黄
        XCTAssertEqual(ModelQuota.colorLevel(percent: 0.7, timeFraction: fiveMinutesInFiveHours), .warning)

        // 4. 重置时刻已到或已过 (t <= 0)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 15, timeFraction: 0.0), .healthy)
        XCTAssertEqual(ModelQuota.colorLevel(percent: 0, timeFraction: 0.0), .critical)
    }

    func testIntervalTimeRemainingFractionNilWhenResetMissing() {
        let q = ModelQuota(
            modelName: "general",
            intervalTotalCount: 0, intervalUsageCount: 0,
            intervalRemainingPercent: 100, intervalStatus: .present,
            intervalResetsAt: nil,  // 缺 reset 时间
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: 0, weeklyUsageCount: 0,
            weeklyRemainingPercent: 0, weeklyStatus: .absent,
            weeklyResetsAt: nil, weeklyWindowSeconds: nil
        )
        XCTAssertNil(q.intervalTimeRemainingFraction, "没有 intervalResetsAt 就降级为 nil")
    }
}
