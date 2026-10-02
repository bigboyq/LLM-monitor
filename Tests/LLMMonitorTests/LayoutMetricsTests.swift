import XCTest
import SwiftUI
import AppKit
@testable import LLM_monitor

/// dock 详情浮层的高度天花板（"排版别再变高"契约）。对应 `LayoutMetrics`
/// 与 `ProviderCardView` 的实际排版结果。
///
/// 卡片 fixture（`HoverRevealModeTests` 的 ChatGPT 卡：双窗口 + 满 7 天本地用量）
/// 刻意单点复用：上限数字是照那张卡的实测高度定的，复制一份就等于改了这张卡，
/// 两个数字同时失去意义。
final class LayoutMetricsTests: XCTestCase {

    // MARK: - dock 详情浮层高度上限

    @MainActor
    func testDockDetailStaysUnderTheRearrangedCeiling() {
        let height = measuredHeight(mode: .alwaysVisible, status: HoverRevealModeTests.makeChatGPTStatus())
        XCTAssertGreaterThan(height, 0, "必须能布局出高度，否则这条断言没有意义")
        XCTAssertLessThan(
            height, 800,
            "dock 详情浮层比重排前更高了（现在 \(height)pt，全展开时是 1188pt）"
        )
    }

    @MainActor
    func testDockDetailWithTheFullestQuotaWindowSectionStaysUnderTheSameCeiling() {
        let now = Date()
        let status = HoverRevealModeTests.makeChatGPTStatus(
            state: .ok,
            resetCredits: true,
            recentSamples: (0..<3).map { index in
                LocalTokenUsageSample(
                    completedAt: now.addingTimeInterval(TimeInterval(-600 * (index + 1))),
                    modelName: "gpt-5.5",
                    promptID: "p\(index)",
                    inputTokens: 1_000,
                    cachedInputTokens: 9_000,
                    outputTokens: 1_000,
                    reasoningOutputTokens: 2_000
                )
            }
        )
        let height = measuredHeight(mode: .alwaysVisible, status: status)
        let bare = measuredHeight(mode: .alwaysVisible, status: HoverRevealModeTests.makeChatGPTStatus())
        XCTAssertGreaterThan(
            height, bare,
            "前提不成立：带重置卡与样本的这一格必须比最轻的那格高（否则量的不是同一张卡）"
        )
        XCTAssertLessThan(
            height, 900,
            "真实形态（金额行 + 逐张重置卡清单 + 账号段）的 dock 浮层高度（现在 \(height)pt）"
                + "不该越过 900pt；超了先量一下，ScrollView 会兜底但那是一屏看不全"
        )
    }

    // MARK: - helpers

    /// dock 浮层里卡片内容区的宽度（`EdgeDockTheme.popoverWidth` 减去两侧背板内边距）。
    private var cardContentWidth: CGFloat {
        EdgeDockTheme.popoverWidth - EdgeDockTheme.popoverPadding * 2
    }

    @MainActor
    private func measuredHeight(mode: HoverRevealMode, status: ProviderStatus) -> CGFloat {
        let root = ProviderCardView(status: status)
            .environment(\.hoverRevealMode, mode)
            .frame(width: cardContentWidth)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(x: 0, y: 0, width: cardContentWidth, height: 10_000)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }
}
