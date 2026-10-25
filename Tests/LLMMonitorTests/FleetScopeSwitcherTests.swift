import XCTest
import Foundation
import AppKit
@testable import LLM_monitor

/// scope 切换控件（`FleetScopeSwitcher` / `FleetScopeMenu`）的形态选择与文案截断。
///
/// 截断是**按文本自身宽度**做的纯计算，不依赖 SwiftUI 排版——macOS 的
/// `Menu` label 走 AppKit `NSButton` 映射，label 内的宽度限制不生效，
/// 限宽 frame 挂到 Menu 外面又会被 HStack 当弹性视图撑开。
final class FleetScopeSwitcherTests: XCTestCase {

    /// 文字可用宽度 = 整组上限 − 标记预留（与实现同口径）。
    private var textMaxWidth: CGFloat {
        FleetScopeMenu.maxLabelWidth - FleetScopeMenu.glyphReserve
    }

    private let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    private func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    func testShortLabelIsKeptVerbatim() {
        XCTAssertEqual(FleetScopeMenu.truncated("本机", maxWidth: textMaxWidth), "本机")
        XCTAssertEqual(FleetScopeMenu.truncated("全局", maxWidth: textMaxWidth), "全局")
    }

    func testLongLabelIsTruncatedWithEllipsis() {
        let source = "MacBook-Pro-16-inch-本机节点"
        let result = FleetScopeMenu.truncated(source, maxWidth: textMaxWidth)
        XCTAssertNotEqual(result, source)
        XCTAssertTrue(result.hasSuffix("…"), "截断结果必须带省略号，实际：\(result)")
        XCTAssertTrue(
            source.hasPrefix(String(result.dropLast())),
            "截断必须只砍尾部，实际：\(result)"
        )
    }

    func testTruncatedResultAlwaysFitsWithinLimit() {
        let samples = [
            "a",
            "MacBOOK P",
            "MacBook-Pro-16-inch-本机节点",
            "超长节点名称超长节点名称超长节点名称超长节点名称",
            "a超长节点名称超长节点名称超长节点名称超长节点名称"
        ]
        for sample in samples {
            let result = FleetScopeMenu.truncated(sample, maxWidth: textMaxWidth)
            XCTAssertLessThanOrEqual(
                width(result),
                textMaxWidth + 0.5,
                "「\(sample)」截断后仍超宽：\(result)"
            )
        }
    }

    func testEmptyAndDegenerateInputs() {
        XCTAssertEqual(FleetScopeMenu.truncated("", maxWidth: textMaxWidth), "")
        // 宽度上限极小时退化为单个省略号，而不是空串。
        XCTAssertEqual(FleetScopeMenu.truncated("本机", maxWidth: 1), "…")
    }

    /// 形态分界：选项总数（全局 + 本机 + 远端节点）≤4 走分段，>4 走下拉。
    func testPreferredStyleSwitchesAtFourOptions() {
        XCTAssertEqual(FleetScopeControlStyle.preferred(optionCount: 2), .segmented)
        XCTAssertEqual(FleetScopeControlStyle.preferred(optionCount: 3), .segmented)
        XCTAssertEqual(FleetScopeControlStyle.preferred(optionCount: 4), .segmented)
        XCTAssertEqual(FleetScopeControlStyle.preferred(optionCount: 5), .dropdown)
        XCTAssertEqual(FleetScopeControlStyle.preferred(optionCount: 9), .dropdown)
    }

    /// 远端节点 2 个 → 总项 4（全局 + 本机 + 2）→ 分段；远端 3 个 → 总项 5 → 下拉。
    func testPreferredStyleCountsGlobalAndLocalInTheTotal() {
        let twoRemote = 2
        let threeRemote = 3
        XCTAssertEqual(
            FleetScopeControlStyle.preferred(optionCount: twoRemote + 2),
            .segmented
        )
        XCTAssertEqual(
            FleetScopeControlStyle.preferred(optionCount: threeRemote + 2),
            .dropdown
        )
    }

    /// scope → 文案：全局 / 本机是固定词，节点取选项里的名字。
    func testLabelTextResolvesScopeNames() {
        let id = UUID()
        let choices = [FleetNodeChoice(id: id, name: "MacBook-Pro", stale: false)]
        XCTAssertEqual(FleetScopeMenu.labelText(.fleet, choices: choices), "全局")
        XCTAssertEqual(FleetScopeMenu.labelText(.local, choices: choices), "本机")
        XCTAssertEqual(FleetScopeMenu.labelText(.node(id), choices: choices), "MacBook-Pro")
        // 节点已经不在列表里（快照刷新后失效）→ 退化文案，不是空串。
        XCTAssertEqual(FleetScopeMenu.labelText(.node(UUID()), choices: choices), "节点")
    }

    /// 整组（文字 + 空格 + ellipsis 标记）不超过 `maxLabelWidth`。
    func testWholeGroupStaysWithinWidthCap() {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let symbol = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let glyphWidth = symbol?.size.width ?? 0
        XCTAssertGreaterThan(glyphWidth, 0, "取不到 ellipsis 符号宽度，测试失去意义")

        let samples = [
            "本机",
            "全局",
            "MacBOOK P",
            "MacBook-Pro-16-inch-本机节点超长名称超长名称"
        ]
        for sample in samples {
            let text = FleetScopeMenu.truncated(sample, maxWidth: textMaxWidth)
            let groupWidth = width(text) + width(" ") + glyphWidth
            XCTAssertLessThanOrEqual(
                groupWidth,
                FleetScopeMenu.maxLabelWidth + 0.5,
                "「\(sample)」整组超宽：\(text)（\(groupWidth)pt）"
            )
        }
    }
}
