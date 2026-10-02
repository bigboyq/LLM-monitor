import XCTest
import Foundation
@testable import LLM_monitor

final class StatusBarConfigTests: XCTestCase {

    func testStatusBarConfigEncodingAndDecoding() throws {
        var config = AppConfig.default
        XCTAssertEqual(config.effectiveStatusBarIconStyle, .chartBar)
        XCTAssertTrue(config.effectiveStatusBarHealthDotEnabled)

        config.statusBarIconStyle = .sparkles
        config.statusBarHealthDotEnabled = false
        config.statusBarHealthColors = StatusBarHealthColors(
            healthyHex: "#123456",
            warningHex: "#ABCDEF",
            criticalHex: "#654321"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AppConfig.self, from: data)

        XCTAssertEqual(decoded.statusBarIconStyle, .sparkles)
        XCTAssertEqual(decoded.statusBarHealthDotEnabled, false)
        XCTAssertEqual(decoded.statusBarHealthColors, config.statusBarHealthColors)
        XCTAssertEqual(decoded.effectiveStatusBarIconStyle, .sparkles)
        XCTAssertFalse(decoded.effectiveStatusBarHealthDotEnabled)
        XCTAssertEqual(decoded.effectiveStatusBarHealthColors, config.statusBarHealthColors)
    }

    /// 设置页 picker 与主面板 header 使用的 App 图标设计稿必须能从资源包加载；
    /// 加载失败会静默回退，这里钉住资源打包不回退。
    func testQuotaLogoPickerPreviewUsesDesignAsset() {
        let design = MenuBarLabel.appIconDesignImage
        XCTAssertNotNil(design, "设计稿 SVG 未打入资源包，picker 与 header 将回退")
        // 菜单栏侧的中间产物：裁掉留白后归一到 22pt 画布（drawRect 再从中收窄）。
        XCTAssertEqual(design?.size.width, 22)
        XCTAssertEqual(design?.size.height, 22)
        // picker 侧拿到的是**按目标边长烘焙过的副本**，不再是这张 22pt 图本身。
        let preview = SettingsView.previewImage(for: .quotaLogo)
        XCTAssertEqual(preview.size.width, SettingsView.previewIconSide(for: .quotaLogo))
        XCTAssertNotEqual(
            preview.tiffRepresentation, design?.tiffRepresentation,
            "picker 若直接复用 22pt 的设计稿，AppKit 绘制菜单行时会按 intrinsic size 画成 22pt"
        )
    }
}
