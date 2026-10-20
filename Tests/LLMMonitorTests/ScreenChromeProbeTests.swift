import XCTest
import CoreGraphics
@testable import LLM_monitor

/// 真实可视区探测（菜单栏 / 系统 Dock 占用扣除）。对应 `ScreenChromeProbe`。
///
/// `ChromeWindow.bounds` 是 **CG 坐标系**（主屏左上原点、y 向下）：主屏 1080 高时，
/// AppKit 贴顶的菜单栏在 CG 里 y=0，贴底的 Dock 在 CG 里 y=1020——每条用例的
/// 注释都给出对应的 AppKit 位置，读的时候别按 AppKit 直觉翻 y。
final class ScreenChromeProbeTests: EdgeDockTestCase {
    private let screen = EdgeDockTestCase.probeScreen // AppKit (0,0,1920,1080)
    private let primary: CGFloat = EdgeDockTestCase.probePrimary

    private func chrome(_ layer: Int, _ bounds: CGRect) -> ScreenChromeProbe.ChromeWindow {
        .init(layer: layer, bounds: bounds)
    }

    private func effective(
        _ windows: [ScreenChromeProbe.ChromeWindow],
        fallback: CGRect = EdgeDockTestCase.probeScreen
    ) -> CGRect {
        ScreenChromeProbe.effectiveVisibleFrame(
            among: windows,
            screenFrame: screen,
            primaryScreenHeight: primary,
            fallback: fallback
        )
    }

    // MARK: - 常规布局：探测结果与 visibleFrame 对齐

    /// 菜单栏（顶部 25）+ 系统 Dock（底部 60）：探测出的可视区必须等于经典
    /// `visibleFrame` fixture（`EdgeDockTestCase.visible`）——普通桌面上两种基准
    /// 应该一致，探测只该在隐藏/侧边场景里产生差异。
    func testMenuBarAndBottomDockReproduceTheClassicVisibleFrame() {
        let menuBarCG = CGRect(x: 0, y: 0, width: 1920, height: 25)      // AppKit 贴顶
        let dockCG = CGRect(x: 0, y: 1020, width: 1920, height: 60)      // AppKit 贴底
        let result = effective([
            chrome(ScreenChromeProbe.mainMenuLayer, menuBarCG),
            chrome(ScreenChromeProbe.dockLayer, dockCG),
        ])
        XCTAssertEqual(result, visible)
    }

    // MARK: - 全屏 / 自动隐藏：占用为空 → 贴物理边缘

    /// 原生全屏 Space 与「菜单栏 + Dock 全自动隐藏」的共同形状：屏上没有菜单栏
    /// /Dock 窗口 → 真实可视区 = 整块屏幕，不再悬空一条预留高度。
    func testEmptyChromeListYieldsTheWholeScreen() {
        XCTAssertEqual(effective([]), screen)
    }

    /// 自动隐藏的系统 Dock 收起时窗口滑出屏外：bounds 与屏幕不相交 → 不占用。
    func testOffscreenAutoHideDockIsNotAnOcclusion() {
        let dockOffscreenCG = CGRect(x: 0, y: 1100, width: 1920, height: 60) // AppKit 屏外下方
        XCTAssertEqual(effective([chrome(ScreenChromeProbe.dockLayer, dockOffscreenCG)]), screen)
    }

    // MARK: - 系统 Dock 在左/右侧

    /// 系统 Dock 在左侧（80pt）：可视区左缘收到 Dock 内沿，贴左边的 dock 避让
    /// 而不是叠上去。
    func testLeftSideSystemDockShrinksTheLeadingEdge() {
        let dockLeftCG = CGRect(x: 0, y: 0, width: 80, height: 1080)
        let result = effective([chrome(ScreenChromeProbe.dockLayer, dockLeftCG)])
        XCTAssertEqual(result.minX, 80, accuracy: 0.001)
        XCTAssertEqual(result.maxX, screen.maxX, accuracy: 0.001)
        XCTAssertEqual(result.height, screen.height, accuracy: 0.001)
    }

    /// 系统 Dock 在右侧（80pt）：可视区右缘收到 1840。
    func testRightSideSystemDockShrinksTheTrailingEdge() {
        let dockRightCG = CGRect(x: 1840, y: 0, width: 80, height: 1080)
        let result = effective([chrome(ScreenChromeProbe.dockLayer, dockRightCG)])
        XCTAssertEqual(result.maxX, 1840, accuracy: 0.001)
        XCTAssertEqual(result.minX, screen.minX, accuracy: 0.001)
    }

    /// 菜单栏自动隐藏但系统 Dock 可见：只收底边，顶部不再预留。
    func testDockVisibleWithMenuBarHiddenOnlyShrinksTheBottom() {
        let dockCG = CGRect(x: 0, y: 1020, width: 1920, height: 60)
        let result = effective([chrome(ScreenChromeProbe.dockLayer, dockCG)])
        XCTAssertEqual(result, CGRect(x: 0, y: 60, width: 1920, height: 1020))
    }

    // MARK: - 别的屏的装饰不算本屏的

    /// 菜单栏每屏一条：副屏（主屏右侧，CG x 从 1920 起）的菜单栏窗口与主屏
    /// 不相交，不能把主屏的可视区也收掉。
    func testAnotherScreensMenuBarDoesNotAffectThisScreen() {
        let secondScreenMenuBarCG = CGRect(x: 1920, y: 0, width: 1920, height: 25)
        XCTAssertEqual(
            effective([chrome(ScreenChromeProbe.mainMenuLayer, secondScreenMenuBarCG)]),
            screen
        )
    }

    // MARK: - 异常形状防护

    /// 方块形的 dock 层窗口（两轴都厚，如全屏窗口）不是菜单栏/Dock 的细长条
    /// 形状：跳过，可视区不塌。
    func testEdgeToEdgeDockLayerWindowIsSkipped() {
        let spanningCG = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(effective([chrome(ScreenChromeProbe.dockLayer, spanningCG)]), screen)
    }

    /// 不贴任何一条边的 dock 层窗口挡不住任何边缘：跳过。
    func testFloatingDockLayerWindowIsSkipped() {
        let floatingCG = CGRect(x: 500, y: 400, width: 400, height: 300)
        XCTAssertEqual(effective([chrome(ScreenChromeProbe.dockLayer, floatingCG)]), screen)
    }

    /// 第二条占用把可视区收缩成非法形状（高 0）时只丢弃那一条，保留先前结果
    /// 而不是整题回退——部分信息好过没有。
    func testCollapsingShrinkIsDroppedButEarlierShrinkIsKept() {
        let menuBarCG = CGRect(x: 0, y: 0, width: 1920, height: 540)   // AppKit 上半屏
        let dockCG = CGRect(x: 0, y: 540, width: 1920, height: 540)    // AppKit 下半屏
        let result = effective([
            chrome(ScreenChromeProbe.mainMenuLayer, menuBarCG),
            chrome(ScreenChromeProbe.dockLayer, dockCG),
        ])
        XCTAssertEqual(result, CGRect(x: 0, y: 0, width: 1920, height: 540))
    }

    // MARK: - fail-open

    /// 屏 frame 退化（无屏瞬态）→ 返回 fallback，绝不做除法/负矩形。
    func testDegenerateScreenFrameReturnsFallback() {
        let sentinel = CGRect(x: 3, y: 7, width: 11, height: 13)
        let result = ScreenChromeProbe.effectiveVisibleFrame(
            among: [chrome(ScreenChromeProbe.mainMenuLayer, CGRect(x: 0, y: 0, width: 100, height: 25))],
            screenFrame: .zero,
            primaryScreenHeight: primary,
            fallback: sentinel
        )
        XCTAssertEqual(result, sentinel)
    }

    // MARK: - 与 EdgeDockGeometry 的组合行为

    /// 全屏探测结果喂给贴边几何：右缘吸附必须齐物理屏幕边（旧基准会悬空一条
    /// visibleFrame 预留）。
    func testFullscreenProbeResultMakesDockFlushWithPhysicalRightEdge() {
        let size = EdgeDockGeometry.dockSize(entryCount: 3, edge: .right)
        let frame = EdgeDockGeometry.frame(
            visibleFrame: effective([]),
            edge: .right,
            size: size,
            offset: 0.5
        )
        XCTAssertEqual(frame.maxX, screen.maxX, accuracy: 0.001)
        XCTAssertTrue(screen.contains(frame))
    }

    /// 系统 Dock 在右侧时贴右边的 dock 落在 Dock 内沿——避让而不是叠上去。
    func testRightSideSystemDockPushesDockedInward() {
        let dockRightCG = CGRect(x: 1840, y: 0, width: 80, height: 1080)
        let effectiveFrame = effective([chrome(ScreenChromeProbe.dockLayer, dockRightCG)])
        let frame = EdgeDockGeometry.frame(
            visibleFrame: effectiveFrame,
            edge: .right,
            size: EdgeDockGeometry.dockSize(entryCount: 3, edge: .right),
            offset: 0.5
        )
        XCTAssertEqual(frame.maxX, 1840, accuracy: 0.001)
        XCTAssertTrue(effectiveFrame.contains(frame))
    }

    // MARK: - 层常量

    /// 层常量必须来自公开 API 且互不相同：写死数字会随系统版本漂移
    /// （与 FullscreenProbe.desktopChromeLayer 的取值纪律同一理由）。
    func testLayerConstantsComeFromPublicAPIAndDiffer() {
        XCTAssertNotEqual(ScreenChromeProbe.mainMenuLayer, ScreenChromeProbe.dockLayer)
        XCTAssertNotEqual(ScreenChromeProbe.mainMenuLayer, FullscreenProbe.desktopChromeLayer)
    }
}
