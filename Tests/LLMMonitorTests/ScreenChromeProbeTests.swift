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

    // MARK: - Space 形态与四边解耦选边

    /// 全屏模式：状态栏不出现，顶边必须贴齐物理屏幕上边缘（消除 25pt 悬空）；
    /// 同时严格保持对 Dock 的避让（60pt），底边不与 Dock 重叠。
    func testFullscreenSpaceUsesTopEdgeWhilePreservingDockClearance() {
        let expected = CGRect(x: 0, y: 60, width: 1920, height: 1020)
        XCTAssertEqual(effective(isFullscreenSpace: true), expected)
        XCTAssertEqual(effective(isFullscreenSpace: true).maxY, screen.maxY, "顶边吸附物理上沿")
        XCTAssertEqual(effective(isFullscreenSpace: true).minY, 60, "底边保留 Dock 避让，不与 Dock 重叠")
    }

    /// 在无 Dock 的屏幕（如副屏）上全屏：顶边与底边均贴齐物理屏幕。
    func testFullscreenSpaceWithoutDockUsesEntirePhysicalScreen() {
        let noDockVisible = CGRect(x: 0, y: 0, width: 1920, height: 1055) // 仅顶部 25pt 菜单栏，无底部 Dock
        let result = ScreenChromeProbe.effectiveVisibleFrame(
            screenFrame: screen,
            visibleFrame: noDockVisible,
            isFullscreenSpace: true
        )
        XCTAssertEqual(result, screen, "无 Dock 且全屏时完全贴合物理屏幕")
    }

    /// 非全屏：visibleFrame 的预留此刻真实（菜单栏/Dock 在屏，侧边 Dock 的
    /// 机器 AppKit 也已算好水平预留）→ 照用，不激进地贴物理边缘。
    func testNonFullscreenKeepsTheVisibleFrameReservation() {
        XCTAssertEqual(effective(isFullscreenSpace: false), visible)
        XCTAssertNotEqual(effective(isFullscreenSpace: false), screen)
    }

    // MARK: - Dock 位于左侧与右侧的避让测试

    /// Dock 在左侧：悬浮窗无论全屏与否都避让左侧 Dock，全屏时顶边贴物理顶边。
    func testDockOnLeftEdgeClearance() {
        let dockWidth: CGFloat = 70
        let leftDockVisible = CGRect(x: dockWidth, y: 0, width: 1920 - dockWidth, height: 1055)
        let nonFs = ScreenChromeProbe.effectiveVisibleFrame(
            screenFrame: screen,
            visibleFrame: leftDockVisible,
            isFullscreenSpace: false
        )
        XCTAssertEqual(nonFs.minX, dockWidth, "非全屏避让左侧 Dock")
        XCTAssertEqual(nonFs.maxY, 1055, "非全屏预留顶部状态栏")

        let fs = ScreenChromeProbe.effectiveVisibleFrame(
            screenFrame: screen,
            visibleFrame: leftDockVisible,
            isFullscreenSpace: true
        )
        XCTAssertEqual(fs.minX, dockWidth, "全屏时仍避让左侧 Dock，不重叠")
        XCTAssertEqual(fs.maxY, screen.maxY, "全屏时顶边吸附物理上沿")
    }

    /// Dock 在右侧：悬浮窗无论全屏与否都避让右侧 Dock，全屏时顶边贴物理顶边。
    func testDockOnRightEdgeClearance() {
        let dockWidth: CGFloat = 80
        let rightDockVisible = CGRect(x: 0, y: 0, width: 1920 - dockWidth, height: 1055)
        let fs = ScreenChromeProbe.effectiveVisibleFrame(
            screenFrame: screen,
            visibleFrame: rightDockVisible,
            isFullscreenSpace: true
        )
        XCTAssertEqual(fs.maxX, screen.maxX - dockWidth, "全屏时避让右侧 Dock，不重叠")
        XCTAssertEqual(fs.maxY, screen.maxY, "全屏时顶边吸附物理上沿")
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

    // MARK: - 状态栏可见性判定与四边 Insets

    func testEffectiveInsetsCalculation() {
        let insets = ScreenChromeProbe.effectiveInsets(
            screenFrame: screen,
            visibleFrame: visible, // top: 25, bottom: 60
            isMenuBarVisible: false,
            keepDockClearance: true
        )
        XCTAssertEqual(insets.top, 0, "状态栏不可见时 top inset 为 0")
        XCTAssertEqual(insets.bottom, 60, "底边保持 60pt Dock 避让")
        XCTAssertEqual(insets.left, 0)
        XCTAssertEqual(insets.right, 0)

        let visibleInsets = ScreenChromeProbe.effectiveInsets(
            screenFrame: screen,
            visibleFrame: visible,
            isMenuBarVisible: true,
            keepDockClearance: true
        )
        XCTAssertEqual(visibleInsets.top, 25, "状态栏可见时预留 25pt")
        XCTAssertEqual(visibleInsets.bottom, 60)
    }

    func testIsPrimaryScreen() {
        let primary = NSScreen.screens.first ?? NSScreen()
        XCTAssertTrue(ScreenChromeProbe.isPrimaryScreen(primary))
    }

    func testHasMenuBarWindowDetection() {
        let mainMenuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
        let primaryScreen = NSScreen.screens.first ?? NSScreen()
        
        // 主屏菜单栏窗口 (0, 0, 1512, 33)
        let primaryMenu = FullscreenProbe.WindowEntry(
            ownerPID: 420,
            layer: mainMenuLayer,
            bounds: CGRect(x: 0, y: 0, width: 1512, height: 33)
        )
        // 副屏没有菜单栏
        let secondaryScreen = NSScreen.screens.count > 1 ? NSScreen.screens[1] : NSScreen()

        let hasPrimary = ScreenChromeProbe.hasMenuBarWindow(on: primaryScreen, customEntries: [primaryMenu])
        XCTAssertEqual(hasPrimary, true, "主屏有横跨自身的菜单栏窗口")

        if NSScreen.screens.count > 1 {
            let hasSecondary = ScreenChromeProbe.hasMenuBarWindow(on: secondaryScreen, customEntries: [primaryMenu])
            XCTAssertEqual(hasSecondary, false, "副屏区间未覆盖该菜单栏窗口，判定无菜单栏")
        }
    }
}
