import XCTest
import AppKit
import Foundation
@testable import LLM_monitor

final class AppIconDrawingTests: XCTestCase {

    /// 主面板 header 使用的完整 App 图标（icon-master.png）必须能从资源包加载。
    func testHeaderAppIconMasterImageLoads() {
        let master = MenuBarLabel.appIconMasterImage
        XCTAssertNotNil(master, "icon-master.png 未打入资源包，header 将回退到系统符号")
        XCTAssertEqual(master?.size.width, 22)
        XCTAssertEqual(master?.size.height, 22)
    }

    // MARK: - App 图标设计稿：载入时裁掉透明留白 + 菜单栏绘制边长

    /// 光栅化一张图并返回其不透明像素的包围盒（归一化到 0...1）。
    @MainActor
    private func opaqueBounds(of image: NSImage, edge: Int = 256) -> CGRect? {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: edge, pixelsHigh: edge, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: edge, height: edge))
        NSGraphicsContext.restoreGraphicsState()
        // NSBitmapImageRep 的像素在 restore 之前就写好了，直接读 bitmapData。
        let bytes = bitmap.bitmapData!
        let bytesPerRow = bitmap.bytesPerRow
        var minX = edge, maxX = -1, minY = edge, maxY = -1
        for y in 0..<edge {
            for x in 0..<edge where bytes[y * bytesPerRow + x * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: CGFloat(minX) / CGFloat(edge), y: CGFloat(minY) / CGFloat(edge),
            width: CGFloat(maxX - minX + 1) / CGFloat(edge),
            height: CGFloat(maxY - minY + 1) / CGFloat(edge)
        )
    }

    @MainActor
    func testDesignAssetIsLoadedAlreadyCropped() {
        // 设计稿原始画布里图形只占约 59%，其余是透明留白；载入时必须裁掉，菜单栏与
        // 设置页 picker 两个消费方才都拿到"图形本身"，谁再按原画布缩放都不会小 41%。
        //
        // 判据是**包围盒贴住四条边**，不是"不透明像素占比高"：这张图是个环，环心
        // 天生是透明的，裁干净之后覆盖率也只有 54%——用覆盖率判会把裁好的图判成没裁。
        //
        // 这条断言同时钉住一个静默失效的坑：包围盒靠"光栅化后扫描 alpha"算，
        // 而 `CGContext.makeImage()` 快照的是上下文的**当前**内容，先取 image 再
        // 绘制会得到全透明图，扫不到不透明像素 → 退回整幅画布：图标还是那么小，
        // 却不报错不崩溃。顺序写反时只有这条会红。
        let image = try? XCTUnwrap(MenuBarLabel.appIconDesignImage)
        XCTAssertNotNil(image)
        guard let design = image else { return }
        let bounds = try? XCTUnwrap(opaqueBounds(of: design))
        XCTAssertNotNil(bounds)
        guard let box = bounds else { return }
        for (name, value) in [("minX", box.minX), ("minY", box.minY),
                              ("maxX", 1 - box.maxX), ("maxY", 1 - box.maxY)] {
            XCTAssertLessThan(value, 0.02, "内容与 \(name) 侧之间还有 \(value * 100)% 的留白没裁掉")
        }
        XCTAssertEqual(box.width, box.height, accuracy: 0.02, "裁剪保宽高比，这张设计稿是正方形")
    }

    func testBaseDrawRectSizesTheAppIconToEighteenPoints() {
        // 「App 图标」是这张表里唯一单独定边长的：细描边环比实心字形看着小，
        // 但铺满 22pt 画布又偏大，18pt 是菜单栏里不抢戏也不显小的那一档。
        let rect = MenuBarLabel.baseDrawRect(for: .quotaLogo, canvas: 22)
        XCTAssertEqual(rect.width, 18, accuracy: 0.001)
        XCTAssertEqual(rect.height, 18, accuracy: 0.001)
        XCTAssertEqual(rect.midX, 11, accuracy: 0.001, "必须居中，否则图标偏在一侧")
        XCTAssertEqual(rect.midY, 11, accuracy: 0.001)
    }

    func testBaseDrawRectKeepsTheInsetBoxForEveryOtherStyle() {
        // 其余样式一律 1pt 边距的 20pt 框：SF Symbol 自带内边距、Icon Duo 是紧凑
        // 画布，靠这个框把视觉尺寸压到 15~17pt。别顺手把它们也改成 18pt。
        for style in [StatusBarIconStyle.chartBar, .sparkles, .brain, .cpu, .iconDuo] {
            let rect = MenuBarLabel.baseDrawRect(for: style, canvas: 22)
            XCTAssertEqual(rect, CGRect(x: 1, y: 1, width: 20, height: 20), "\(style.displayName)")
        }
    }

    func testBaseDrawRectNeverExceedsTheCanvas() {
        // 画布被改小（比如以后跟随外观调整）时，绘制框不能溢出画布。
        for canvas in [CGFloat(22), 18, 16] {
            for style in StatusBarIconStyle.allCases {
                let rect = MenuBarLabel.baseDrawRect(for: style, canvas: canvas)
                XCTAssertLessThanOrEqual(rect.width, canvas, "\(style.rawValue) @ \(canvas)")
                XCTAssertGreaterThanOrEqual(rect.minX, 0, "\(style.rawValue) @ \(canvas)")
            }
        }
    }
}
