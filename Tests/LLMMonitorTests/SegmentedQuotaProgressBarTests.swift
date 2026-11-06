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
    /// {.criticalTint, .warningTint, tint} 三种，排除另外两种即可唯一锁定 warning 档。
    private func assertIsWarningTier(_ color: Color, line: UInt = #line) {
        XCTAssertNotEqual(color, Color.criticalTint, line: line)
        XCTAssertNotEqual(color, tint, line: line)
    }

    // MARK: - singleInterval（segments=1 且无时间标记，5h 条）

    /// singleInterval 模式第一格只看 primaryFraction（固定 30% 黄阈值），
    /// 不受 weeklyFraction 与时间标记影响
    func testSingleIntervalColorsFollowPrimaryFractionOnly() {
        let critical = makeBar(primary: 0.05, weekly: 0.9, segments: 1)
        XCTAssertEqual(critical.intervalSegmentColor, Color.criticalTint)

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
        XCTAssertEqual(critical.intervalSegmentColor, Color.criticalTint)

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
        XCTAssertEqual(bar.weeklySegmentColor, Color.criticalTint)

        let flipped = makeBar(primary: 0.05, weekly: 0.9, segments: 3, timeRemaining: 0.5)
        XCTAssertEqual(flipped.intervalSegmentColor, Color.criticalTint)
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

    /// summaryColor：critical → criticalTint（systemRed，随外观变化），warning 档（动态橙色），
    /// healthy 基线 primary，>80% 额外给一个"健康"色信号。
    ///
    /// 绿色信号钉的是 `Color.healthyTint`（`systemGreen`）而不是 SwiftUI 的
    /// `.green`：后者是**固定色**，不随外观变化，在浅色卡片上刺眼。这里顺带把
    /// "不能退回固定绿"钉住——它正是这个 bug 重新长出来的入口。红色同理钉
    /// `Color.criticalTint`，不退回固定 `.red`。
    func testSummaryColorMappingIncludesGreenBoostAbove80() {
        XCTAssertEqual(summaryColor(for: 5), Color.criticalTint)
        XCTAssertEqual(summaryColor(for: 70), Color.primary)
        XCTAssertEqual(summaryColor(for: 80), Color.primary, "80% 是边界，不含 > 80 的加成")
        XCTAssertEqual(summaryColor(for: 90), Color.healthyTint)
        XCTAssertNotEqual(
            summaryColor(for: 90), Color.green,
            "健康色必须走随外观变化的 healthyTint，不能退回固定 .green"
        )

        // 40% + 无时间系数 → 60% 固定黄阈值，30% 红阈值 → warning 档
        //（排除 criticalTint / primary / healthyTint 唯一锁定 warningTint）
        let warning = summaryColor(for: 40)
        XCTAssertNotEqual(warning, Color.criticalTint)
        XCTAssertNotEqual(warning, Color.primary)
        XCTAssertNotEqual(warning, Color.healthyTint)
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

    // MARK: - 微栅格自适应与点亮算法（约 100 槽微栅格体系）

    func testTicksPerSegmentAdaptation() {
        XCTAssertEqual(SegmentedQuotaProgressBar.ticksPerSegment(for: 1), 100)
        XCTAssertEqual(SegmentedQuotaProgressBar.ticksPerSegment(for: 2), 50)
        XCTAssertEqual(SegmentedQuotaProgressBar.ticksPerSegment(for: 3), 33)
        XCTAssertEqual(SegmentedQuotaProgressBar.ticksPerSegment(for: 4), 25)
        XCTAssertEqual(SegmentedQuotaProgressBar.ticksPerSegment(for: 5), 20)
        XCTAssertEqual(SegmentedQuotaProgressBar.ticksPerSegment(for: 6), 16)
        XCTAssertEqual(SegmentedQuotaProgressBar.ticksPerSegment(for: 7), 14)
        XCTAssertEqual(SegmentedQuotaProgressBar.ticksPerSegment(for: 10), 10)
    }

    func testTicksForSegmentWithFractionalCapacity() {
        // 非整数倍率（如假设的 3.33 倍率：总容量 3.33，前 3 段为 1.0，尾段为 0.33）
        let ticksStandard = SegmentedQuotaProgressBar.ticksForSegment(
            capacity: 1.0,
            totalCapacity: 3.33,
            segmentCount: 4
        )
        let ticksTail = SegmentedQuotaProgressBar.ticksForSegment(
            capacity: 0.33,
            totalCapacity: 3.33,
            segmentCount: 4
        )
        XCTAssertEqual(ticksStandard, 30, "整段应分得 30 格")
        XCTAssertEqual(ticksTail, 10, "尾段应分得 10 格")
        XCTAssertEqual(ticksStandard * 3 + ticksTail, 100, "四段合计精确为 100 格")

        // 整倍率 4.0：各段等宽 25 格（通用整数分段行为）。
        let ticksInteger4 = SegmentedQuotaProgressBar.ticksForSegment(
            capacity: 1.0,
            totalCapacity: 4.0,
            segmentCount: 4
        )
        XCTAssertEqual(ticksInteger4, 25, "4 倍率整段应分得 25 格")
    }

    func testActiveTickCountRoundingAndFloor() {
        // 0% -> 0 格，溢出 clamp
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.0, totalTicks: 10), 0)
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: -0.1, totalTicks: 10), 0)
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 1.0, totalTicks: 10), 10)
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 1.5, totalTicks: 10), 10)

        // 核心规则验证（以 10 块区间为例）：
        // 贴近最近邻刻度，两边距离相等（中点 .5）向小取整：
        // 44.9% -> 选 4 块 (40%)
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.449, totalTicks: 10), 4)
        // 45.1% -> 选 5 块 (50%)
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.451, totalTicks: 10), 5)
        // 45.0% -> 两边距离相等，选较小者 4 块 (40%)
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.450, totalTicks: 10), 4)

        // 100 块区间（单窗口基准 / 1% 分辨率）：
        // 45.0% -> 45 块
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.450, totalTicks: 100), 45)
        // 45.5% -> 45.5 选 45 块 (平局选小)
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.455, totalTicks: 100), 45)
        // 45.6% -> 选 46 块
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.456, totalTicks: 100), 46)

        // 16 块区间（ChatGPT 6 段，每段 16 块）：
        // 50.0% -> 8 块
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.50, totalTicks: 16), 8)
        // 45.0% -> 7.2 选 7 块
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.45, totalTicks: 16), 7)
        // 46.875% -> 7.5 选 7 块 (平局选小)
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.46875, totalTicks: 16), 7)
        // 47.0% -> 7.52 选 8 块
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.470, totalTicks: 16), 8)

        // 20 块区间（GLM 5 段，每段 20 块）：
        // 50.0% -> 10 块
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.50, totalTicks: 20), 10)
        // 47.5% -> 9.5 选 9 块 (平局选小)
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.475, totalTicks: 20), 9)

        // 25 块区间（Gemini 4 段，每段 25 块）：
        // 50.0% -> 12.5 选 12 块 (平局选小)
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.50, totalTicks: 25), 12)
        // 46.0% -> 11.5 选 11 块 (平局选小)
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.46, totalTicks: 25), 11)
        // 48.0% -> 12 块
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.48, totalTicks: 25), 12)

        // 30 块区间：
        // 50.0% -> 15 块
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.50, totalTicks: 30), 15)
        // 45.0% -> 13.5 选 13 块 (平局选小)
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.45, totalTicks: 30), 13)
        // 46.0% -> 13.8 选 14 块
        XCTAssertEqual(SegmentedQuotaProgressBar.activeTickCount(fill: 0.46, totalTicks: 30), 14)
    }
}
