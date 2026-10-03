import AppKit
import SwiftUI
import XCTest
@testable import LLM_monitor

/// 设置页「客户端」切换条（`ClientSegmentedControl`，原生 `NSSegmentedControl`）的行为。
final class ClientSegmentedControlTests: XCTestCase {

    private func item(_ id: String, _ title: String, badge: Int = 0, subtitle: String = "") -> ClientSegmentedControl.Item {
        ClientSegmentedControl.Item(id: id, title: title, badge: badge, subtitle: subtitle)
    }

    // MARK: - 段标签

    func testLabelAppendsCountInParenthesesOnlyWhenPositive() {
        // 0 是"没扫到 Provider"，不是"有 0 个"——显示一个 0 只会让人以为程序坏了。
        // 括号是刻意的：空格分隔的"DSH 2"分不清是 Provider 数还是版本号。
        XCTAssertEqual(item("a", "Antigravity").label, "Antigravity")
        XCTAssertEqual(item("a", "Antigravity", badge: 1).label, "Antigravity (1)")
        XCTAssertEqual(item("a", "MiniMax Code", badge: 12).label, "MiniMax Code (12)")
    }

    func testToolTipExplainsWhatTheCountMeans() {
        // 纯文本标签里那个数字和名字挨着（"DSH 2"），光看标签分不清是 Provider 数
        // 还是版本号，所以 tooltip 必须把话说全。
        XCTAssertEqual(
            item("a", "DSH", badge: 2, subtitle: "多 Provider session token 账本").toolTip,
            "DSH · 2 个 Provider · 多 Provider session token 账本"
        )
        XCTAssertEqual(
            item("a", "DSH", badge: 2).toolTip,
            "DSH · 2 个 Provider"
        )
        XCTAssertEqual(
            item("a", "OpenCode", subtitle: "多 Provider 本地 token 账本").toolTip,
            "多 Provider 本地 token 账本"
        )
    }

    // MARK: - 选中回写

    @MainActor
    func testSelectingASegmentWritesBackTheMatchingClientID() {
        var value = "a"
        let binding = Binding(get: { value }, set: { value = $0 })
        let coordinator = ClientSegmentedControl.Coordinator(
            selection: binding,
            segmentIDs: ["a", "b", "c"]
        )
        let control = NSSegmentedControl()
        control.segmentCount = 3

        control.selectedSegment = 2
        coordinator.handleChange(control)
        XCTAssertEqual(value, "c", "第 3 段应当回写第 3 个客户端的 id")
    }

    @MainActor
    func testStaleSegmentIndexDoesNotWriteBackABogusID() {
        // 竞态：点击那一瞬间 items 变少（比如某个客户端的用量行被扫没了），
        // 控件还剩旧段数，而 segmentIDs 已经更短。此时下标越界必须被忽略，
        // 不能把一个不存在的 id 写进 selectedClientID——那会让下面的 Provider 列表
        // 跟着空掉。`selectedSegment` 本身越界是 AppKit 的 NSRangeException，
        // 在我们这层之前就抛了，所以这里只测"控件下标合法、映射表更短"这一种。
        var value = "a"
        let binding = Binding(get: { value }, set: { value = $0 })
        let coordinator = ClientSegmentedControl.Coordinator(selection: binding, segmentIDs: ["a"])
        let control = NSSegmentedControl()
        control.segmentCount = 3

        control.selectedSegment = 2
        coordinator.handleChange(control)
        XCTAssertEqual(value, "a", "越界的段下标必须被忽略")
    }

    @MainActor
    func testReclickingTheCurrentSegmentDoesNotWriteBack() {
        // 回写会触发 SwiftUI 重渲染（onChange → 重新扫描/排序），点当前段不该付这个代价。
        var writes = 0
        var value = "b"
        let binding = Binding(get: { value }, set: { value = $0; writes += 1 })
        let coordinator = ClientSegmentedControl.Coordinator(selection: binding, segmentIDs: ["a", "b"])
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.selectedSegment = 1

        coordinator.handleChange(control)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(value, "b")

        control.selectedSegment = 0
        coordinator.handleChange(control)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(value, "a")
    }

    // MARK: - 宽度测量

    @MainActor
    func testSegmentWidthIsTextWidthPlusTheCalibratedPadding() {
        // 段宽是自己量的（不能用 width(forSegment:)，对未进窗口的控件恒为 0）。
        // 这里钉住"文字宽 + 24.5"这个公式：内边距是标定值，偏小会把标签切掉。
        let font = NSFont.systemFont(ofSize: 13)
        for label in ["DSH", "Codex", "Antigravity", "MiniMax Code", "MiniMax Code 12"] {
            let text = (label as NSString).size(withAttributes: [.font: font]).width
            let width = ClientSegmentedControl.segmentWidth(for: label, font: font)
            XCTAssertEqual(width, ceil(text) + 24.5, accuracy: 0.001, "\(label)")
            XCTAssertGreaterThan(width, text, "\(label)：段宽必须比文字宽，否则标签被切")
        }
    }

    @MainActor
    func testSegmentWidthsNeverCollapseToZero() {
        // 曾经的真实事故：`width(forSegment:)` 对没进窗口的控件返回 0，被直接
        // setWidth 回去，整个切换条宽度归零、图标全不见。现在段宽只依赖文字测量。
        let items = ClientDescriptor.all.map { item($0.id, $0.displayName) }
        let control = NSSegmentedControl()
        ClientSegmentedControl.applySegments(items, to: control)
        for index in 0..<control.segmentCount {
            XCTAssertGreaterThan(
                control.width(forSegment: index), 20,
                "第 \(index) 段宽度 \(control.width(forSegment: index))pt：控件没进窗口就退化成不可见"
            )
        }
    }

    @MainActor
    func testRegisteredClientsStillFitTheSettingsContentWidth() {
        // 客户端数会增长（现在 7 个）。超过内容区宽度时外层横向滚动，功能不受影响，
        // 但值得先知道，免得"加个客户端名"悄悄把切换条挤出视野。
        // 660pt 是 6 客户端时代的内容区口径；Agy 加入后（"Agy (12)" 一段约 50pt）
        // 切换条按设计超出并由外层滚动兜底，预算放宽到 720pt 继续守门：
        // 再涨就该考虑折叠计数或换布局了。
        let items = ClientDescriptor.all.map {
            item($0.id, $0.displayName, badge: 12, subtitle: $0.subtitle)
        }
        let font = NSFont.systemFont(ofSize: 13)
        let total = items.reduce(0) { $0 + ClientSegmentedControl.segmentWidth(for: $1.label, font: font) }
        print("\(ClientDescriptor.all.count) 个客户端（名称 + 两位计数）总宽 = \(Int(total))pt")
        XCTAssertLessThan(total, 720, "切换条总宽超出滚动兜底可接受的口径；再宽就该考虑折叠计数或换布局了")
    }

    @MainActor
    func testApplyingAnEmptyClientListKeepsOneHarmlessSegment() {
        // `NSSegmentedControl.segmentCount = 0` 抛的是 NSException（不是 Swift
        // 错误，catch 不住，只会让整个测试进程 SIGABRT），所以空列表必须降级成
        // 1 个空段。这里直接走生产用的那条路径。
        let control = NSSegmentedControl()
        ClientSegmentedControl.applySegments([], to: control)
        XCTAssertEqual(control.segmentCount, 1)
        ClientSegmentedControl.syncSelection("", items: [], onto: control)
        XCTAssertLessThan(control.selectedSegment, control.segmentCount, "选中下标不能越界")
    }

    @MainActor
    func testSegmentCountChangesInvalidateThePreviousWidths() {
        // 段数变少时残留的旧段宽会让新控件宽出一截（空白段），变多时新段又会继承
        // 上一次的宽度。两次 apply 之间必须重新测量。
        let control = NSSegmentedControl()
        let wide = [item("a", "MiniMax Code", badge: 12)]
        ClientSegmentedControl.applySegments(wide, to: control)
        let wideWidth = control.width(forSegment: 0)

        let narrow = [item("a", "DSH"), item("b", "ZCode"), item("c", "Codex")]
        ClientSegmentedControl.applySegments(narrow, to: control)
        XCTAssertEqual(control.segmentCount, 3)
        for index in 0..<3 {
            XCTAssertLessThan(control.width(forSegment: index), wideWidth,
                              "第 \(index) 段还留着上一个宽标签的段宽")
        }
    }

    @MainActor
    func testSyncSelectionMovesTheHighlightAndLeavesUnknownIDsAlone() {
        let items = [item("a", "Antigravity"), item("b", "Codex"), item("c", "DSH")]
        let control = NSSegmentedControl()
        ClientSegmentedControl.applySegments(items, to: control)
        control.selectedSegment = 0

        ClientSegmentedControl.syncSelection("c", items: items, onto: control)
        XCTAssertEqual(control.selectedSegment, 2)

        // 未知 id：不动控件。onAppear 会在下一轮渲染纠正它，这里不该抢先替用户选。
        ClientSegmentedControl.syncSelection("已卸载的客户端", items: items, onto: control)
        XCTAssertEqual(control.selectedSegment, 2, "未知 id 不该改变选中段")
    }
}
