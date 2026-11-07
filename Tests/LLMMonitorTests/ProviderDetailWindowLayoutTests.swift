import XCTest
import CoreGraphics
@testable import LLM_monitor

/// Provider 详情独立窗口的宽度契约。对应 `ProviderDetailWindowView.minimumWindowWidth`
/// 与 `SevenDayUsageChartMetrics` 的 expanded 表格常量。
///
/// 曾经窗口宽 468pt（dock popover 的推导），而 `.expanded` 的 7 天历史表格列宽
/// 合计 466pt，卡内可用只有 420pt——最后一列被窗口右缘裁掉。窗口最小宽必须由
/// 表格常量推导，改列宽而没跟窗口，这里立刻红。
final class ProviderDetailWindowLayoutTests: XCTestCase {

    // MARK: - expanded 表格常量

    func testExpandedTableWidthTracksColumnBudget() {
        // 总宽常量必须等于实际列预算：日期 42 + R/T 66 + 分桶 56×4 + 动态 74
        // + 间距 10×6 = 466。写成表达式便于逐项核对，改列必须连这里一起改。
        XCTAssertEqual(
            SevenDayUsageChartMetrics.expandedTableWidth,
            SevenDayUsageChartMetrics.expandedDateColumnWidth
                + SevenDayUsageChartMetrics.expandedRTColumnWidth
                + SevenDayUsageChartMetrics.expandedBucketColumnWidth * 4
                + SevenDayUsageChartMetrics.expandedDynamicColumnWidth
                + SevenDayUsageChartMetrics.expandedTableSpacing * 6
        )
        XCTAssertEqual(SevenDayUsageChartMetrics.expandedTableWidth, 466)
    }

    // MARK: - 窗口最小宽装得下 expanded 表格

    func testMinimumWindowWidthFitsExpandedTable() {
        XCTAssertEqual(
            ProviderDetailWindowView.minimumWindowWidth,
            SevenDayUsageChartMetrics.expandedTableWidth
                + LayoutMetrics.cardColumnHorizontalPadding * 2
                + LayoutMetrics.cardContentPadding * 2,
            "最小宽 = 表格 466 + 外层 padding 12×2 + 卡片内 padding 12×2 = 514"
        )
        XCTAssertGreaterThanOrEqual(
            ProviderDetailWindowView.minimumWindowWidth,
            SevenDayUsageChartMetrics.expandedTableWidth
                + LayoutMetrics.cardColumnHorizontalPadding * 2
                + LayoutMetrics.cardContentPadding * 2
        )
    }

    func testWindowCardContentAreaFitsExpandedTable() {
        // 卡内容区（窗口最小宽 - 外层 padding 12×2 - 卡片内 padding 12×2）
        // 必须完整装下 expanded 表格，否则最后一列被窗口右缘裁掉。
        let inner = ProviderDetailWindowView.minimumWindowWidth
            - LayoutMetrics.cardColumnHorizontalPadding * 2
            - LayoutMetrics.cardContentPadding * 2
        XCTAssertGreaterThanOrEqual(inner, SevenDayUsageChartMetrics.expandedTableWidth)
    }
}
