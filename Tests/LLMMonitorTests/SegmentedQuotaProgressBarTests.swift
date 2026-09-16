import XCTest
import SwiftUI
@testable import LLM_monitor

/// `SegmentedQuotaProgressBar` 视图本体的纯逻辑面测试：
/// 各窗口模式（singleInterval / singleWeekly / combined）的取色输入选择、
/// 时间比例 clamp、summaryColor 映射与三角标记几何。
/// 算法核心 `EquivalentQuotaAllocation` 已在 ProviderModelTests 覆盖，
/// GeometryReader 内的分段布局依赖渲染上下文，不在此硬造。
final class SegmentedQuotaProgressBarTests: XCTestCase {

    private let tint = Color.blue

    private func makeBar(
        primary: Double,
        weekly: Double,
        segments: Int,
        timeRemaining: Double? = nil
    ) -> SegmentedQuotaProgressBar {
        SegmentedQuotaProgressBar(
            primaryFraction: primary,
            weeklyFraction: weekly,
            tint: tint,
            segments: segments,
            height: 8,
            timeRemainingFraction: timeRemaining
        )
    }

    /// warning 档的颜色是 `Color.warningTint`（动态 NSColor 包装），
    /// 两次构造的 Color 相等性不可靠；`color(for:)` 只会输出
    /// {.red, .warningTint, tint} 三种，排除另外两种即可唯一锁定 warning 档。
    private func assertIsWarningTier(_ color: Color, line: UInt = #line) {
        XCTAssertNotEqual(color, Color.red, line: line)
        XCTAssertNotEqual(color, tint, line: line)
    }

    // MARK: - singleInterval（segments=1 且无时间标记，5h 条）

    /// singleInterval 模式第一格只看 primaryFraction（固定 30% 黄阈值），
    /// 不受 weeklyFraction 与时间标记影响
    func testSingleIntervalColorsFollowPrimaryFractionOnly() {
        let critical = makeBar(primary: 0.05, weekly: 0.9, segments: 1)
        XCTAssertEqual(critical.intervalSegmentColor, Color.red)

        let healthy = makeBar(primary: 0.9, weekly: 0.05, segments: 1)
        XCTAssertEqual(healthy.intervalSegmentColor, tint)
    }

    // MARK: - singleWeekly（segments=1 且有时间标记，长窗口条）

    /// singleWeekly 模式 index 0 就是 weekly 格：取色跟随 weeklyFraction，
    /// 黄阈值走时间感知逻辑 min(time% × 100, 50)，不看 primaryFraction
    func testSingleWeeklyColorsFollowWeeklyFractionWithTimeAwareThreshold() {
        // 90% 周余额 + 剩余 50% 时间 → 阈值 50 → healthy（若误用 primary=5% 会得到红色）
        let healthy = makeBar(primary: 0.05, weekly: 0.9, segments: 1, timeRemaining: 0.5)
        XCTAssertEqual(healthy.intervalSegmentColor, tint)
        XCTAssertEqual(healthy.weeklySegmentColor, tint)

        // 5% 周余额 → critical（若误用 primary=90% 会得到 tint）
        let critical = makeBar(primary: 0.9, weekly: 0.05, segments: 1, timeRemaining: 0.5)
        XCTAssertEqual(critical.intervalSegmentColor, Color.red)

        // 40% 周余额：剩余 20% 时间 → 阈值 20 → healthy；
        // 剩余 90% 时间 → 阈值 50 → warning
        let timeTight = makeBar(primary: 0.9, weekly: 0.4, segments: 1, timeRemaining: 0.2)
        XCTAssertEqual(timeTight.weeklySegmentColor, tint)
        let timeLoose = makeBar(primary: 0.9, weekly: 0.4, segments: 1, timeRemaining: 0.9)
        assertIsWarningTier(timeLoose.weeklySegmentColor)
    }

    // MARK: - combined（segments>1，5h + 周组合条）

    /// combined 模式两格独立着色：第一格只看 primaryFraction（且不带时间系数，
    /// 即使画了时间标记三角），后续格看 weeklyFraction（时间感知）
    func testCombinedModeColorsEachWindowIndependently() {
        let bar = makeBar(primary: 0.9, weekly: 0.05, segments: 3, timeRemaining: 0.5)
        XCTAssertEqual(bar.intervalSegmentColor, tint, "第一格应只由 primary 决定，不受 weekly 拖累")
        XCTAssertEqual(bar.weeklySegmentColor, Color.red)

        let flipped = makeBar(primary: 0.05, weekly: 0.9, segments: 3, timeRemaining: 0.5)
        XCTAssertEqual(flipped.intervalSegmentColor, Color.red)
        XCTAssertEqual(flipped.weeklySegmentColor, tint, "weekly 格不应被 primary 的 critical 拖累")
    }

    /// 传入越界的 timeRemainingFraction 时按 [0, 1] clamp 后再参与黄阈值计算
    func testWeeklyColorClampsOutOfRangeTimeFraction() {
        // 40% 周余额：time=2.0 → clamp 1.0 → 阈值 50 → warning
        let overflow = makeBar(primary: 0.9, weekly: 0.4, segments: 1, timeRemaining: 2.0)
        assertIsWarningTier(overflow.weeklySegmentColor)

        // time=-3 → clamp 0 → 阈值 0 → healthy（不因负数误判 warning）
        let underflow = makeBar(primary: 0.9, weekly: 0.4, segments: 1, timeRemaining: -3)
        XCTAssertEqual(underflow.weeklySegmentColor, tint)
    }

    // MARK: - summaryColor

    /// summaryColor：critical → 红，warning 档（动态橙色），healthy 基线 primary，
    /// >80% 额外给绿色信号
    func testSummaryColorMappingIncludesGreenBoostAbove80() {
        XCTAssertEqual(summaryColor(for: 5), Color.red)
        XCTAssertEqual(summaryColor(for: 50), Color.primary)
        XCTAssertEqual(summaryColor(for: 80), Color.primary, "80% 是边界，不含 > 80 的绿色加成")
        XCTAssertEqual(summaryColor(for: 90), Color.green)

        // 20% + 无时间系数 → 30% 固定黄阈值 → warning 档
        //（排除 red / primary / green 唯一锁定 warningTint）
        let warning = summaryColor(for: 20)
        XCTAssertNotEqual(warning, Color.red)
        XCTAssertNotEqual(warning, Color.primary)
        XCTAssertNotEqual(warning, Color.green)
    }

    // MARK: - 三角标记几何

    /// ▼ 尖端在底边中点，顶边两端在左上 / 右上
    func testDownwardTrianglePathGeometry() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 6)
        let path = DownwardTriangle().path(in: rect)

        var expected = Path()
        expected.move(to: CGPoint(x: 5, y: 6))
        expected.addLine(to: CGPoint(x: 0, y: 0))
        expected.addLine(to: CGPoint(x: 10, y: 0))
        expected.closeSubpath()

        XCTAssertEqual(path, expected)
    }

    /// 槽位固定高度契约：8pt 进度条 + 4pt 三角 + 1pt 间距，
    /// 相邻卡片行高不随单窗口缺标记而晃动
    func testStandardSlotHeightContract() {
        XCTAssertEqual(SegmentedQuotaProgressBar.standardSlotHeight, 13)
    }
}
