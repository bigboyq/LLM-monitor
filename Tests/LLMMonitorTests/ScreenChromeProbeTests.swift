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

    /// 全屏模式：无常驻 Dock 也无常驻状态栏，悬浮窗直接贴齐物理屏幕四边缘（消除 Dock/菜单栏悬空）。
    func testFullscreenSpaceSnapsToPhysicalEdgesWithoutDockClearance() {
        XCTAssertEqual(effective(isFullscreenSpace: true), screen)
        XCTAssertEqual(effective(isFullscreenSpace: true).maxY, screen.maxY, "顶边吸附物理上沿")
        XCTAssertEqual(effective(isFullscreenSpace: true).minY, 0, "全屏页无常驻 Dock，底边直接吸附物理下沿")
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

    // MARK: - Dock 位于左侧、右侧与底部的避让测试

    /// Dock 在左侧：窗口时避让左侧 Dock，吸附在 Dock 上；全屏页无常驻 Dock，吸附在屏幕左物理边。
    func testDockOnLeftEdgeClearance() {
        let dockWidth: CGFloat = 70
        let leftDockVisible = CGRect(x: dockWidth, y: 0, width: 1920 - dockWidth, height: 1055)
        let nonFs = ScreenChromeProbe.effectiveVisibleFrame(
            screenFrame: screen,
            visibleFrame: leftDockVisible,
            isFullscreenSpace: false
        )
        XCTAssertEqual(nonFs.minX, dockWidth, "非全屏窗口模式避让左侧 Dock，吸附在 Dock 上")
        XCTAssertEqual(nonFs.maxY, 1055, "非全屏预留顶部状态栏")

        let fs = ScreenChromeProbe.effectiveVisibleFrame(
            screenFrame: screen,
            visibleFrame: leftDockVisible,
            isFullscreenSpace: true
        )
        XCTAssertEqual(fs.minX, 0, "全屏页无 Dock，直接吸附在屏幕物理左边缘")
        XCTAssertEqual(fs.maxY, screen.maxY, "全屏时顶边吸附物理上沿")
    }

    /// Dock 在右侧：窗口时避让右侧 Dock，吸附在 Dock 上；全屏页无常驻 Dock，吸附在屏幕右物理边。
    func testDockOnRightEdgeClearance() {
        let dockWidth: CGFloat = 80
        let rightDockVisible = CGRect(x: 0, y: 0, width: 1920 - dockWidth, height: 1055)
        let nonFs = ScreenChromeProbe.effectiveVisibleFrame(
            screenFrame: screen,
            visibleFrame: rightDockVisible,
            isFullscreenSpace: false
        )
        XCTAssertEqual(nonFs.maxX, screen.maxX - dockWidth, "非全屏窗口模式避让右侧 Dock，吸附在 Dock 上")

        let fs = ScreenChromeProbe.effectiveVisibleFrame(
            screenFrame: screen,
            visibleFrame: rightDockVisible,
            isFullscreenSpace: true
        )
        XCTAssertEqual(fs.maxX, screen.maxX, "全屏页无 Dock，直接吸附在屏幕物理右边缘")
        XCTAssertEqual(fs.maxY, screen.maxY, "全屏时顶边吸附物理上沿")
    }

    /// Dock 在底部：窗口时吸附在底部 Dock 上；全屏页无常驻 Dock，吸附在屏幕底边。
    func testDockOnBottomEdgeClearance() {
        let dockHeight: CGFloat = 65
        let bottomDockVisible = CGRect(x: 0, y: dockHeight, width: 1920, height: 1080 - dockHeight - 25)
        let nonFs = ScreenChromeProbe.effectiveVisibleFrame(
            screenFrame: screen,
            visibleFrame: bottomDockVisible,
            isFullscreenSpace: false
        )
        XCTAssertEqual(nonFs.minY, dockHeight, "非全屏窗口模式吸附在 Dock 上")

        let fs = ScreenChromeProbe.effectiveVisibleFrame(
            screenFrame: screen,
            visibleFrame: bottomDockVisible,
            isFullscreenSpace: true
        )
        XCTAssertEqual(fs.minY, 0, "全屏页无 Dock，直接吸附在屏幕物理底边")
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

            // 当副屏动态唤出菜单栏时（例如用户鼠标滑至副屏顶端）
            let secondaryMenu = FullscreenProbe.WindowEntry(
                ownerPID: 420,
                layer: mainMenuLayer,
                bounds: CGRect(x: secondaryScreen.frame.minX, y: 0, width: secondaryScreen.frame.width, height: 30)
            )
            let secondaryState = ScreenChromeProbe.menuBarState(
                on: secondaryScreen,
                isFullscreenSpace: false,
                windowEntries: [secondaryMenu]
            )
            XCTAssertEqual(secondaryState.isVisible, true, "副屏检测到自身菜单栏窗口，判定状态栏可见")
            XCTAssertEqual(secondaryState.height, 30, "副屏状态栏实测高度为 30pt")

            let dynamicInsets = ScreenChromeProbe.effectiveInsets(
                screenFrame: secondaryScreen.frame,
                visibleFrame: secondaryScreen.visibleFrame,
                isMenuBarVisible: secondaryState.isVisible,
                menuBarHeight: secondaryState.height
            )
            XCTAssertEqual(dynamicInsets.top, 30, "动态避让 30pt 状态栏")
        }
    }
}
