import XCTest
import CoreGraphics
@testable import LLM_monitor

/// 当前 Space 的全屏判定。对应 `FullscreenProbe`。
final class EdgeDockFullscreenTests: EdgeDockTestCase {

    // MARK: - 全屏判定：坐标系翻转

    func testCgRectFlipsYAxis() {
        // AppKit（左下原点）→ CGWindowList（主屏左上原点）。
        // 主屏 1080 高时，贴底部的窗口在 CG 坐标系里 y 应该靠近 0。
        let primary: CGFloat = 1080
        let appKitBottom = CGRect(x: 0, y: 0, width: 100, height: 50)
        let cg = FullscreenProbe.cgRect(fromAppKitRect: appKitBottom, primaryScreenHeight: primary)
        XCTAssertEqual(cg.minY, 1030, accuracy: 0.001, "贴 AppKit 底部 = CG 顶部坐标")
        XCTAssertEqual(cg.maxY, 1080, accuracy: 0.001)

        let appKitTop = CGRect(x: 0, y: 1030, width: 100, height: 50)
        let cgTop = FullscreenProbe.cgRect(fromAppKitRect: appKitTop, primaryScreenHeight: primary)
        XCTAssertEqual(cgTop.minY, 0, accuracy: 0.001, "贴 AppKit 顶部 = CG 顶部坐标 0")
    }

    // MARK: - 全屏判定：当前 Space 局部，而非"前台 App"

    /// 这条钉的就是"滑动桌面后 dock 留在全屏里"那个 bug。
    ///
    /// 全屏窗口属于 PID 777，但**前台 App 不是它**——滑动 Space 不触发 App 激活，
    /// 所以前台 PID 仍然是别的进程。旧实现按前台 PID 过滤，整个窗口列表里挑不出
    /// 任何属于前台的窗口 → 判定"没全屏" → dock 留在全屏 Space 上不消失。
    func testFullscreenWindowIsDetectedEvenWhenItIsNotTheFrontmostApp() {
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let entries = [
            window(777, full),                  // 别人家的全屏窗口，就在当前 Space 上
            window(1234, CGRect(x: 10, y: 10, width: 400, height: 300)),  // 前台 App 的普通小窗
        ]
        XCTAssertTrue(
            probe(entries, own: Self.probeOwnPID),
            "只要当前 Space 上有铺满整屏的窗口就该判定全屏——不能因为它不属于前台 App 而漏判"
        )
    }

    func testMaximizedWindowIsNotFullscreen() {
        // 菜单栏可见时最大化窗口被挤在 visibleFrame 里（这里 y=25 留给菜单栏），
        // 盖不满整块显示区。误报防护来自覆盖判据，**不是**进程过滤——
        // 所以去掉进程过滤不会换来"窗口铺满就藏 dock"。
        let maximized = CGRect(x: 0, y: 25, width: 1920, height: 1030)
        XCTAssertFalse(probe([window(777, maximized)]))
    }

    // MARK: - 全屏判定：桌面装饰区分「真全屏」与「缩放」

    /// 单独那条覆盖判据挡不住的误判：菜单栏和 Dock 都设成自动隐藏时
    /// `visibleFrame == frame`，缩放 / 最大化出来的窗口正好盖满 `screen.frame`。
    /// 桌面装饰还在 = 普通 Space，不能算全屏。
    func testZoomedWindowCoveringWholeScreenOnNormalSpaceIsNotFullscreen() {
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let entries = [
            window(777, full),
            window(744, layer: FullscreenProbe.desktopChromeLayer, full),
        ]
        XCTAssertFalse(
            probe(entries),
            "桌面装饰还在，说明这是普通 Space，铺满的窗口只是被缩放到 visibleFrame 的大窗口"
        )
    }

    /// 真全屏 Space 上没有桌面装饰：同样铺满，判定必须为真。
    /// 与上一条一起钉住「覆盖面积 + 桌面装饰」这对判据，缺一条就退化成旧行为。
    func testWholeScreenWindowWithoutDesktopChromeIsFullscreen() {
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(probe([window(777, full)]))
    }

    /// 副屏的桌面装饰不在本屏上，不能压掉本屏的全屏判定。
    func testDesktopChromeOnAnotherScreenDoesNotSuppressFullscreen() {
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let otherScreen = CGRect(x: 0, y: -1200, width: 1920, height: 1200)
        XCTAssertTrue(
            probe([
                window(777, full),
                window(744, layer: FullscreenProbe.desktopChromeLayer, otherScreen),
            ]),
            "桌面装饰必须按目标屏比对，副屏那一份与本屏无关"
        )
    }

    /// 判据必须**精确等于** `kCGDesktopIconWindowLevel`。桌面那一带上还有窗口服务器
    /// 与 WindowManager 的常驻窗口（壁纸后板、Space 切换层等），全屏时它们照样在；
    /// 一旦放宽成"层 <= 桌面图标层"，真全屏就会被判成普通 Space（漏判，dock 留在
    /// 全屏里）。
    func testOnlyTheDesktopIconLevelCountsAsDesktopChrome() {
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let neighbours = [
            FullscreenProbe.desktopChromeLayer - 1,
            FullscreenProbe.desktopChromeLayer + 1,
            Int(CGWindowLevelForKey(.desktopWindow)),
        ]
        for layer in neighbours {
            XCTAssertTrue(
                probe([window(777, full), window(410, layer: layer, full)]),
                "层 \(layer) 不是桌面装饰层，不该压掉全屏判定"
            )
        }
        XCTAssertFalse(
            probe([window(777, full), window(744, layer: FullscreenProbe.desktopChromeLayer, full)]),
            "桌面图标层本身仍必须被认成桌面装饰"
        )
    }

    func testOwnProcessWindowsNeverCountAsFullscreen() {
        // 自己铺满屏幕的任何窗口都不能触发隐藏，否则边缘窗会自己把自己藏掉，
        // 而且没有任何手段把它弄回来。
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertFalse(
            probe([window(Self.probeOwnPID, full)]),
            "本进程窗口铺满屏幕时必须返回 false"
        )
        XCTAssertTrue(
            probe([window(Self.probeOwnPID, full), window(777, full)], own: Self.probeOwnPID),
            "本进程有满屏窗口时，仍然要看别人的"
        )
    }

    func testNonNormalWindowLayersNeverCountAsFullscreen() {
        // 菜单 / tooltip / 阴影层铺满屏幕不代表全屏。
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        for layer in [1, 2, 3, -1] {
            XCTAssertFalse(probe([window(777, layer: layer, full)]), "layer \(layer) 不该被判成全屏")
        }
        XCTAssertTrue(probe([window(777, layer: 0, full)]))
    }

    func testEmptyWindowListIsNotFullscreen() {
        XCTAssertFalse(probe([]), "探测不到任何窗口时必须 fail-open（返回 false，窗口照常显示）")
    }

    /// 副屏排在主屏**上方**时，翻转出来的 CG 原点是**负 y**——这是正确的全局坐标，
    /// 不是 bug。
    ///
    /// 这一条存在的原因是它极易被"修"坏：判据拿窗口坐标和 `screen.frame` 翻转后的
    /// 坐标比对，而两者不同源时覆盖判据会恒假；恒假的表现和"窗口没被报出来"一样，
    /// 于是很可能有人看到负 y 就加一次取绝对值 / 改成主屏高度当偏移。那样多屏布置
    /// 在主屏上方或左侧的机器上会静默失效，而单屏开发机永远复现不出来。
    ///
    /// 真实数据（本机，主屏 1440×900、上方副屏 1920×1080）：副屏窗口的
    /// `kCGWindowBounds` 是 `y = -1080`，对应 AppKit 的 `y = 900...1980`。
    func testCgRectFlipIsCorrectForScreensAboveAndBelowThePrimary() {
        let primary: CGFloat = 900

        // 主屏上方：AppKit y 从主屏高度往上长 → CG y 为负。
        let above = FullscreenProbe.cgRect(
            fromAppKitRect: CGRect(x: 0, y: 900, width: 1920, height: 1080),
            primaryScreenHeight: primary
        )
        XCTAssertEqual(above, CGRect(x: 0, y: -1080, width: 1920, height: 1080), "主屏上方的副屏必须是负 CG y")

        // 主屏下方：AppKit y 为负 → CG y 大于主屏高度。
        let below = FullscreenProbe.cgRect(
            fromAppKitRect: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            primaryScreenHeight: primary
        )
        XCTAssertEqual(below, CGRect(x: 0, y: 900, width: 1920, height: 1080), "主屏下方的副屏从主屏高度往下算")

        // 且判定用得起来：副屏自己的全屏窗口（哪怕位于负 y）必须被认出来。
        let entries = [window(777, above)]
        XCTAssertTrue(
            FullscreenProbe.containsFullscreenWindow(
                among: entries,
                screenFrame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
                primaryScreenHeight: primary,
                ownProcessIdentifier: Self.probeOwnPID
            ),
            "副屏在负 y 区域时覆盖判据不能恒假"
        )
    }

    func testCgRectFlipPreservesSizeAndIsInvolutive() {
        let primary: CGFloat = 1080
        let original = CGRect(x: 100, y: 200, width: 1920, height: 995)
        let flipped = FullscreenProbe.cgRect(fromAppKitRect: original, primaryScreenHeight: primary)
        XCTAssertEqual(flipped.width, original.width)
        XCTAssertEqual(flipped.height, original.height)
        XCTAssertEqual(flipped.origin.x, original.origin.x, accuracy: 0.001, "只翻 y")

        let back = FullscreenProbe.cgRect(fromAppKitRect: flipped, primaryScreenHeight: primary)
        XCTAssertEqual(back.origin.x, original.origin.x, accuracy: 0.001)
        XCTAssertEqual(back.origin.y, original.origin.y, accuracy: 0.001, "翻两次必须回到原点")
    }

    func testCoverageToleranceAbsorbsRounding() {
        // 铺满判定留 2pt 容差：macOS 自己的边框内缩不该被当成"没铺满"。
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let insetByOne = screen.insetBy(dx: 1, dy: 1)
        XCTAssertTrue(insetByOne.insetBy(dx: -FullscreenProbe.coverageTolerance, dy: -FullscreenProbe.coverageTolerance).contains(screen))

        let waySmaller = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertFalse(waySmaller.insetBy(dx: -FullscreenProbe.coverageTolerance, dy: -FullscreenProbe.coverageTolerance).contains(screen))
    }
}
