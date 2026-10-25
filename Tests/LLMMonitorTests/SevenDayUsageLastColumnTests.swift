import XCTest
import SwiftUI
import AppKit
@testable import LLM_monitor

/// 7 天用量表（`SevenDayTokenUsageHoverView`）末列跟随「额度窗口」
/// 「分析 / 用量」segment 的行为。
///
/// - popwindow 路径（`lastColumnFollowsSegment = true`）：分析态画价值（现状渲染）、
///   用量态画速度（当日 tok/s，`speedByDay` 非空才画，单日缺值 `—`）；
/// - Settings 客户端页与 fleet 路径（默认 false）：不受 segment 影响，有
///   `priceByDay` 就永远画价值列，与引入该参数之前逐字一致。
///
/// 列存在性用**视图理想宽**判别：末列（62pt）在场即 `pricedWidth`(420)、
/// 不在场即 `barsWidth`(415)。两种末列同宽，"画的是哪一列"由 priceByDay /
/// speedByDay 的空与非空组合矩阵分辨——某一列的数据为空时，画错列的实现
/// 会多出或少掉一个 62pt 列，宽度随之偏离断言值。
final class SevenDayUsageLastColumnTests: XCTestCase {

    private static let calendar = Calendar.current
    private static let todayStart = calendar.startOfDay(for: Date())

    /// 统一按本地自然日取日首（与 `UnifiedDailyUsageNormalizer` 同一语义）。
    private static func dayStart(_ dayOffset: Int) -> Date {
        calendar.date(byAdding: .day, value: dayOffset, to: todayStart)!
    }

    private static func day(_ dayOffset: Int) -> UnifiedDailyTokenUsage {
        UnifiedDailyTokenUsage(dayStart: dayStart(dayOffset), input: 1_000, output: 500)
    }

    private static func days(_ count: Int) -> [UnifiedDailyTokenUsage] {
        (0..<count).map { day(-$0) }
    }

    private static func sample(
        _ dayOffset: Int,
        hour: Int = 10,
        output: Int,
        reasoning: Int = 0,
        duration: Double?
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: calendar.date(bySettingHour: hour, minute: 15, second: 0, of: dayStart(dayOffset))!,
            modelName: "glm-5.3",
            promptID: "p-\(dayOffset)-\(hour)-\(output)",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            sourceProviderID: "test",
            durationSeconds: duration
        )
    }

    private static func priced(_ days: [UnifiedDailyTokenUsage]) -> [Date: String] {
        Dictionary(uniqueKeysWithValues: days.map { ($0.dayStart, "$1.23") })
    }

    private static func speeds(_ days: [UnifiedDailyTokenUsage]) -> [Date: String] {
        Dictionary(uniqueKeysWithValues: days.map { ($0.dayStart, "246") })
    }

    /// 惰性计数：断言 autoclosure 只在 7 天卡 body 展开时才求值。
    private static var speedEvalCount = 0
    private static func countedSpeeds(_ days: [UnifiedDailyTokenUsage]) -> [Date: String] {
        speedEvalCount += 1
        return speeds(days)
    }

    @MainActor
    private func measuredWidth<V: View>(of view: V) -> CGFloat {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = CGRect(x: 0, y: 0, width: 10_000, height: 100)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.width
    }

    /// 注入 segment 持久化值（同 `QuotaWindowUsageValueTests` 的既有模式：
    /// 存旧值 → 设新值 → defer 还原），`nil` = 删 key（回落默认 analysis）。
    private func withSegmentState<T>(_ rawValue: String?, _ body: () throws -> T) rethrows -> T {
        let key = QuotaWindowUsageSection.segmentStorageKey
        let prev = UserDefaults.standard.string(forKey: key)
        defer {
            if let prev {
                UserDefaults.standard.set(prev, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let rawValue {
            UserDefaults.standard.set(rawValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return try body()
    }

    // MARK: - LocalUsageSpeedByDay（速度数据）

    /// 没有样本 = 没有任何速度数据 → 空字典（usage 段据此不画末列）。
    func testSpeedTextsAreEmptyWithoutSamples() {
        XCTAssertEqual(
            LocalUsageSpeedByDay.texts(dayStarts: [Self.dayStart(0), Self.dayStart(-1)], recentSamples: []),
            [:]
        )
    }

    /// 逐日分组 + 唯一速率口径：当天速率 = `windowTokenRate`（Σ(Output+Reason) ÷
    /// Σ时长），文案与「额度窗口」用量态的速度格同分档（`speedText`）；
    /// 当天只有时长未知的样本、或当天没有样本 → `—`。
    func testSpeedTextsFollowTheWindowRatePerLocalDay() {
        let dayA = Self.dayStart(0)
        let dayB = Self.dayStart(-1)
        let dayC = Self.dayStart(-2)
        let a1 = Self.sample(0, output: 1_000, reasoning: 500, duration: 10)
        let a2 = Self.sample(0, hour: 15, output: 500, duration: 5)
        let b1 = Self.sample(-1, output: 50, reasoning: 200, duration: nil)

        let texts = LocalUsageSpeedByDay.texts(dayStarts: [dayA, dayB, dayC], recentSamples: [a1, a2, b1])

        XCTAssertEqual(texts[dayA], "133", "(1000+500+500) ÷ (10+5) ≈ 133.3 → ≥100 档整数")
        XCTAssertEqual(
            texts[dayA],
            QuotaWindowUsageSection.speedText(LocalUsageSummaryBuilder.windowTokenRate(samples: [a1, a2])),
            "逐日文案必须与对同批样本直接调 windowTokenRate 逐字一致"
        )
        XCTAssertEqual(texts[dayB], "—", "当天只有时长未知的样本 → —（不是 0）")
        XCTAssertEqual(texts[dayC], "—", "当天没有样本 → —")
        XCTAssertEqual(Set(texts.keys), [dayA, dayB, dayC], "key 必须就是 days 的 dayStart")
    }

    // MARK: - 默认路径（Settings / fleet，lastColumnFollowsSegment = false）

    /// Settings 路径零变化：有 priceByDay 就画价值列（pricedWidth），segment 与
    /// speedByDay 都影响不到它；priceByDay 为空时没有末列（barsWidth）——
    /// 没有任何宿主会经默认路径画出速度列。
    @MainActor
    func testDefaultPathKeepsTheValueColumnRegardlessOfSegmentAndSpeed() {
        let days = Self.days(7)

        withSegmentState(QuotaWindowUsageSegment.usage.rawValue) {
            // priceByDay 非空：价值列照画，哪怕 segment=usage 且 speedByDay 也有值。
            let withPrice = SevenDayTokenUsageHoverView(
                days: days,
                scannedAt: nil,
                isScanning: false,
                priceByDay: Self.priced(days),
                speedByDay: Self.speeds(days),
                lastColumnFollowsSegment: false
            )
            XCTAssertEqual(
                self.measuredWidth(of: withPrice), SevenDayUsageChartMetrics.pricedWidth, accuracy: 0.5,
                "默认路径必须与现状逐字一致：价值列照画"
            )

            // priceByDay 为空：无末列（速度列不因 speedByDay 非空而泄漏进默认路径）。
            let withoutPrice = SevenDayTokenUsageHoverView(
                days: days,
                scannedAt: nil,
                isScanning: false,
                priceByDay: [:],
                speedByDay: Self.speeds(days),
                lastColumnFollowsSegment: false
            )
            XCTAssertEqual(
                self.measuredWidth(of: withoutPrice), SevenDayUsageChartMetrics.barsWidth, accuracy: 0.5,
                "默认路径下 speedByDay 非空也不得画出速度列"
            )
        }
    }

    /// 惰性纪律：默认路径（不跟 segment）的 body 求值**绝不**调 speedByDay 闭包；
    /// 对照组（跟随 segment + usage 态）才会真正求值。
    @MainActor
    func testSpeedByDayStaysLazyUnlessTheHostFollowsTheUsageSegment() {
        let days = Self.days(7)
        let key = QuotaWindowUsageSection.segmentStorageKey
        let prev = UserDefaults.standard.string(forKey: key)
        defer {
            if let prev {
                UserDefaults.standard.set(prev, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // 默认路径：body 展开后计数仍为 0。
        UserDefaults.standard.set(QuotaWindowUsageSegment.usage.rawValue, forKey: key)
        Self.speedEvalCount = 0
        _ = self.measuredWidth(of: SevenDayTokenUsageHoverView(
            days: days,
            scannedAt: nil,
            isScanning: false,
            priceByDay: Self.priced(days),
            speedByDay: Self.countedSpeeds(days),
            lastColumnFollowsSegment: false
        ))
        XCTAssertEqual(Self.speedEvalCount, 0, "不跟随 segment 时 speedByDay 闭包一次都不能被调")

        // 对照组：跟随 segment + usage 态 → 真正求值（列才画得出来）。
        Self.speedEvalCount = 0
        _ = self.measuredWidth(of: SevenDayTokenUsageHoverView(
            days: days,
            scannedAt: nil,
            isScanning: false,
            priceByDay: Self.priced(days),
            speedByDay: Self.countedSpeeds(days),
            lastColumnFollowsSegment: true
        ))
        XCTAssertGreaterThanOrEqual(Self.speedEvalCount, 1, "用量态下 speedByDay 必须真的被求值")
    }

    // MARK: - popwindow 路径（lastColumnFollowsSegment = true）

    /// 分析态：价值列照画（现状渲染），速度列不因 speedByDay 非空而出现；
    /// priceByDay 为空时分析态无末列。
    @MainActor
    func testFollowingViewShowsTheValueColumnInTheAnalysisSegment() {
        let days = Self.days(7)

        withSegmentState(QuotaWindowUsageSegment.analysis.rawValue) {
            let withPrice = SevenDayTokenUsageHoverView(
                days: days,
                scannedAt: nil,
                isScanning: false,
                priceByDay: Self.priced(days),
                speedByDay: Self.speeds(days),
                lastColumnFollowsSegment: true
            )
            XCTAssertEqual(
                self.measuredWidth(of: withPrice), SevenDayUsageChartMetrics.pricedWidth, accuracy: 0.5,
                "分析态画价值列（现状渲染），不画速度列"
            )

            let withoutPrice = SevenDayTokenUsageHoverView(
                days: days,
                scannedAt: nil,
                isScanning: false,
                priceByDay: [:],
                speedByDay: Self.speeds(days),
                lastColumnFollowsSegment: true
            )
            XCTAssertEqual(
                self.measuredWidth(of: withoutPrice), SevenDayUsageChartMetrics.barsWidth, accuracy: 0.5,
                "分析态下 speedByDay 非空也不得画出速度列"
            )
        }
    }

    /// 用量态：speedByDay 非空才画速度列（priceByDay 不再画）；speedByDay 空
    /// （或用默认值）→ 无末列。priceByDay 空 + speedByDay 非空 → 列只能来自
    /// 速度数据，宽度仍为 pricedWidth。
    @MainActor
    func testFollowingViewShowsTheSpeedColumnInTheUsageSegment() {
        let days = Self.days(7)

        withSegmentState(QuotaWindowUsageSegment.usage.rawValue) {
            // 速度列在场（priceByDay 故意为空：列只能来自 speedByDay）。
            let speedOnly = SevenDayTokenUsageHoverView(
                days: days,
                scannedAt: nil,
                isScanning: false,
                priceByDay: [:],
                speedByDay: Self.speeds(days),
                lastColumnFollowsSegment: true
            )
            XCTAssertEqual(
                self.measuredWidth(of: speedOnly), SevenDayUsageChartMetrics.pricedWidth, accuracy: 0.5,
                "用量态 + speedByDay 非空 → 速度列在场"
            )

            // 用量态不画价值列：priceByDay 非空但 speedByDay 空 → 无末列。
            let priceSuppressed = SevenDayTokenUsageHoverView(
                days: days,
                scannedAt: nil,
                isScanning: false,
                priceByDay: Self.priced(days),
                speedByDay: [:],
                lastColumnFollowsSegment: true
            )
            XCTAssertEqual(
                self.measuredWidth(of: priceSuppressed), SevenDayUsageChartMetrics.barsWidth, accuracy: 0.5,
                "用量态下价值列必须让位：speedByDay 空时无末列"
            )
        }
    }

    // MARK: - LocalUsageFooterView（popwindow / fleet 的中间层）

    /// footer 透传：follows=true + 用量态 + speedByDay 空 → 价值列被让位、
    /// 无末列（barsWidth）；follows=true + 用量态 + speedByDay 非空 → 速度列在场。
    @MainActor
    func testFooterForwardsSegmentFollowingToTheChart() {
        let days = Self.days(7)

        withSegmentState(QuotaWindowUsageSegment.usage.rawValue) {
            let withEmptySpeed = LocalUsageFooterView(
                dailyTokenUsage: days,
                scannedAt: nil,
                isScanning: false,
                isTruncated: false,
                speedByDay: [:],
                lastColumnFollowsSegment: true,
                isReady: true,
                emptyHint: "test"
            )
            XCTAssertEqual(
                self.measuredWidth(of: withEmptySpeed), SevenDayUsageChartMetrics.barsWidth, accuracy: 0.5,
                "footer 必须把 lastColumnFollowsSegment 透传给 7 天卡：用量态价值列让位、无速度数据无末列"
            )

            let withSpeed = LocalUsageFooterView(
                dailyTokenUsage: days,
                scannedAt: nil,
                isScanning: false,
                isTruncated: false,
                speedByDay: Self.speeds(days),
                lastColumnFollowsSegment: true,
                isReady: true,
                emptyHint: "test"
            )
            XCTAssertEqual(
                self.measuredWidth(of: withSpeed), SevenDayUsageChartMetrics.pricedWidth, accuracy: 0.5,
                "footer 透传 speedByDay：用量态速度列在场"
            )
        }
    }

    /// fleet 形态（footer 默认参数：无 speedByDay、不跟 segment）不受本次改版影响：
    /// 用量态下价值列照旧在场（本地无样本的 fleet 快照逐日显示 `—`），不 crash、
    /// 不出现假速度。
    @MainActor
    func testFleetShapeFooterKeepsTheValueColumn() {
        let days = Self.days(7)

        withSegmentState(QuotaWindowUsageSegment.usage.rawValue) {
            let fleetShape = LocalUsageFooterView(
                dailyTokenUsage: days,
                scannedAt: nil,
                isScanning: false,
                isReady: true,
                emptyHint: "test"
            )
            XCTAssertEqual(
                self.measuredWidth(of: fleetShape), SevenDayUsageChartMetrics.pricedWidth, accuracy: 0.5,
                "fleet 形态（默认参数）价值列行为不变：segment=usage 仍画价值列"
            )
        }
    }
}
