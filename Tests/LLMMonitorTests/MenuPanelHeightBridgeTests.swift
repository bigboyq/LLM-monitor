import XCTest
import AppKit
@testable import LLM_monitor

/// F4: 菜单高度封顶的核心算式 + 常量。
/// `MenuPanelHeightBridge.cappedHeight(_:)` / `heightCapFraction` / `width` 在 1.4.2
/// review 中被抽出为 `static`，正是为了让这一组行为可以在不需要 fake
/// `NSWindow` / `NSScreen` 的情况下被钉死。`HeightProbeView.applyMaxSize()`
/// 是带 NSWindow 副作用的 side-effect-only path（lastMaxHeight 去重、guard window
/// 早返、contentMaxSize 写入），留给 UI 集成验证。
@MainActor
final class MenuPanelHeightBridgeTests: XCTestCase {

    // MARK: - 算式

    func testCappedHeightRoundsDownBy70Percent() {
        XCTAssertEqual(MenuPanelHeightBridge.cappedHeight(1000), 700)
        XCTAssertEqual(MenuPanelHeightBridge.cappedHeight(900), 630)
        XCTAssertEqual(MenuPanelHeightBridge.cappedHeight(800), 560)
    }

    func testCappedHeightFloorsFractionalResults() {
        // floor(100.5 × 0.70) = floor(70.35) = 70
        XCTAssertEqual(MenuPanelHeightBridge.cappedHeight(100.5), 70)
        // floor(1 × 0.70) = floor(0.7) = 0
        XCTAssertEqual(MenuPanelHeightBridge.cappedHeight(1), 0)
        // 边界 0
        XCTAssertEqual(MenuPanelHeightBridge.cappedHeight(0), 0)
        // 算式对负数不鲁棒（floor(-100 × 0.70) = -70），但 visibleFrame 不会为负，
        // caller `applyMaxSize` 假定 `screen.visibleFrame.height >= 0`，所以这个
        // 行为不算 bug——只是 caller 必须保证前提。如果未来需要鲁棒性，
        // 在 `applyMaxSize` 加 `max(0, ...)` 即可，不在算式里硬塞 clamp。
    }

    func testCappedHeightScalesLinearly() {
        // cappedHeight(2 × h) == 2 × cappedHeight(h)（在 floor 不切边的范围内）
        XCTAssertEqual(
            MenuPanelHeightBridge.cappedHeight(2000),
            MenuPanelHeightBridge.cappedHeight(1000) * 2
        )
    }

    // MARK: - 常量

    /// 70% 是 F4 的设计判断。这里锁死 [0.5, 0.85] 区间：
    /// - 下限 0.5：避免 4-5 张卡片就频繁触发 ScrollView
    /// - 上限 0.85：避免菜单贴顶/贴 Dock
    /// 具体 0.70 是 7859f2d 的视觉评估值。如果未来要改，单独 review commit。
    func testHeightCapFractionWithinSafeRange() {
        let f = MenuPanelHeightBridge.heightCapFraction
        XCTAssertGreaterThan(f, 0.5, "高度上限 < 50% 会让菜单频繁卡在 ScrollView")
        XCTAssertLessThan(f, 0.85, "高度上限 > 85% 会贴顶/贴 Dock 风险")
    }

    /// 用量页与额度页共享宽度，容纳紧凑四指标摘要。
    func testUsageWidthFitsCompactSummary() {
        XCTAssertEqual(MenuPanelHeightBridge.width, 484, "用量页宽度应与额度页共享")
        XCTAssertEqual(MenuPanelHeightBridge.width(for: .usage), 484)
    }

    /// 额度页按共享 Plan 图表的 420pt 内容宽度推导，并覆盖卡片、菜单行和菜单列内边距。
    /// 同一额度宽度用于空态与展开态，避免 DisclosureGroup 行数改变时菜单横向跳动。
    func testQuotaPageWidthFitsSharedPlanModulesAndDoesNotDependOnExpansion() {
        let expected = SevenDayUsageChartMetrics.pricedWidth
            + LayoutMetrics.cardContentPadding * 2
            + 8 * 2
            + LayoutMetrics.cardColumnHorizontalPadding * 2
        XCTAssertEqual(MenuPanelHeightBridge.quotaWidth, expected)
        XCTAssertEqual(MenuPanelHeightBridge.quotaWidth, 484)
        XCTAssertEqual(MenuPanelHeightBridge.width(for: .quota), 484)
    }

    func testWidthTransitionKeepsRightEdgeAnchoredAndClampsFrameToVisibleScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let usageFrame = CGRect(x: 956, y: 200, width: 484, height: 500)
        let widenedX = MenuWindowAlignment.alignedOriginX(
            currentFrame: usageFrame,
            targetWidth: MenuPanelHeightBridge.quotaWidth,
            visibleFrame: visible
        )
        XCTAssertEqual(widenedX, 956, "页面切换保持右边缘")

        let quotaFrame = CGRect(x: widenedX, y: 200, width: 484, height: 500)
        let narrowedX = MenuWindowAlignment.alignedOriginX(
            currentFrame: quotaFrame,
            targetWidth: MenuPanelHeightBridge.width,
            visibleFrame: visible
        )
        XCTAssertEqual(narrowedX, 956, "页面切换不累积横向漂移")

        let overflowFrame = CGRect(x: 1200, y: 200, width: 484, height: 500)
        let clampedX = MenuWindowAlignment.alignedOriginX(
            currentFrame: overflowFrame,
            targetWidth: MenuPanelHeightBridge.quotaWidth,
            visibleFrame: visible
        )
        XCTAssertEqual(clampedX + MenuPanelHeightBridge.quotaWidth, visible.maxX)

        let leftOverflowX = MenuWindowAlignment.alignedOriginX(
            currentFrame: CGRect(x: -20, y: 200, width: 484, height: 500),
            targetWidth: MenuPanelHeightBridge.quotaWidth,
            visibleFrame: visible
        )
        XCTAssertEqual(leftOverflowX, visible.minX)
    }
}
