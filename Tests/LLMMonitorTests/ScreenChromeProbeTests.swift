import XCTest
import CoreGraphics
@testable import LLM_monitor

/// 真实可视区选边（全屏 Space → 物理边缘；非全屏 → visibleFrame 预留）。
/// 对应 `ScreenChromeProbe`。
///
/// CGWindowList 装饰条带路线在 macOS 26 上被实测否决（菜单栏不作为独立窗口
/// 暴露；系统 Dock 主窗口 bounds 是整屏方块）——这组用例钉住的是替代信号：
/// Space 形态选边。`EdgeDockTestCase.visible` = 主屏 1920x1080、菜单栏 25、
/// 底部 Dock 60 的经典预留。
final class ScreenChromeProbeTests: EdgeDockTestCase {
    private let screen = EdgeDockTestCase.probeScreen // AppKit (0,0,1920,1080)

    private func effective(isFullscreenSpace: Bool) -> CGRect {
        ScreenChromeProbe.effectiveVisibleFrame(
            screenFrame: screen,
            visibleFrame: visible,
            isFullscreenSpace: isFullscreenSpace
        )
    }

    // MARK: - Space 形态选边

    /// 全屏 Space：菜单栏与系统 Dock 被系统保证隐藏，visibleFrame 的预留是
    /// 假的 → 必须贴物理屏幕边缘（经典 bug：贴上边的 dock 悬空一条菜单栏）。
    func testFullscreenSpaceUsesThePhysicalScreenFrame() {
        XCTAssertEqual(effective(isFullscreenSpace: true), screen)
    }

    /// 非全屏：visibleFrame 的预留此刻真实（菜单栏/Dock 在屏，侧边 Dock 的
    /// 机器 AppKit 也已算好水平预留）→ 照用，不激进地贴物理边缘。
    func testNonFullscreenKeepsTheVisibleFrameReservation() {
        XCTAssertEqual(effective(isFullscreenSpace: false), visible)
        XCTAssertNotEqual(effective(isFullscreenSpace: false), screen)
    }

    // MARK: - fail-open：选中来源退化时回退另一个

    /// 全屏但 screenFrame 退化（无屏瞬态的兜底 NSScreen()）→ 回 visibleFrame。
    func testFullscreenWithDegenerateScreenFrameFallsBackToVisibleFrame() {
        let result = ScreenChromeProbe.effectiveVisibleFrame(
            screenFrame: .zero,
            visibleFrame: visible,
            isFullscreenSpace: true
        )
        XCTAssertEqual(result, visible)
    }

    /// 非全屏但 visibleFrame 退化 → 回 screenFrame，绝不输出零矩形。
    func testNonFullscreenWithDegenerateVisibleFrameFallsBackToScreenFrame() {
        let result = ScreenChromeProbe.effectiveVisibleFrame(
            screenFrame: screen,
            visibleFrame: .zero,
            isFullscreenSpace: false
        )
        XCTAssertEqual(result, screen)
    }

    /// 两者皆退化：放行 .zero（下游 EdgeDockGeometry.frame 有自己的零保护）。
    func testBothDegenerateYieldsZero() {
        let result = ScreenChromeProbe.effectiveVisibleFrame(
            screenFrame: .zero,
            visibleFrame: .zero,
            isFullscreenSpace: true
        )
        XCTAssertTrue(result.isNull || result == .zero)
    }

    // MARK: - 与 EdgeDockGeometry 的组合行为

    /// 全屏选边喂给贴边几何：右缘吸附齐物理屏幕边，顶缘吸附齐物理顶
    /// （旧基准分别悬空 Dock/菜单栏的预留）。
    func testFullscreenSelectionSnapsFlushToPhysicalEdges() {
        let size = EdgeDockGeometry.dockSize(entryCount: 3, edge: .right)
        let right = EdgeDockGeometry.frame(
            visibleFrame: effective(isFullscreenSpace: true),
            edge: .right, size: size, offset: 0.5
        )
        XCTAssertEqual(right.maxX, screen.maxX, accuracy: 0.001)

        let top = EdgeDockGeometry.frame(
            visibleFrame: effective(isFullscreenSpace: true),
            edge: .top, size: size, offset: 0.5
        )
        XCTAssertEqual(top.maxY, screen.maxY, accuracy: 0.001)
        XCTAssertTrue(screen.contains(top))
    }

    /// 非全屏选边喂给贴边几何：底缘吸附落在系统 Dock 上沿（60pt），不再与
    /// 系统 Dock 重合。
    func testNonFullscreenSelectionKeepsTheSystemDockClearance() {
        let bottom = EdgeDockGeometry.frame(
            visibleFrame: effective(isFullscreenSpace: false),
            edge: .bottom,
            size: EdgeDockGeometry.dockSize(entryCount: 3, edge: .bottom),
            offset: 0.5
        )
        XCTAssertEqual(bottom.minY, visible.minY, accuracy: 0.001)
        XCTAssertEqual(bottom.minY, 60, accuracy: 0.001)
        XCTAssertTrue(visible.contains(bottom))
    }
}
