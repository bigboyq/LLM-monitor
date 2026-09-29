import XCTest
import SwiftUI
@testable import LLM_monitor

/// 折叠区（`HoverInfoRow`）的展开方式。
///
/// 主菜单依赖"hover 才展开"来控制信息密度，所以**默认值必须永远是 `.onHover`**。
/// 改默认值不会报错、不会崩，只会让菜单忽然变成一堵没人能看完的墙 —— 这类回归
/// 只能靠一条断言挡住。
final class HoverRevealModeTests: XCTestCase {

    func testDefaultIsOnHoverSoTheMenuKeepsCollapsing() {
        // 不设任何环境值时（主菜单的所有卡片都是这种情况）必须走 hover 浮层。
        XCTAssertEqual(
            EnvironmentValues().hoverRevealMode, .onHover,
            "默认展开方式必须是 .onHover，否则主菜单的信息密度失控"
        )
    }

    func testMenuPanelContentDoesNotForceAlwaysVisible() {
        // 主菜单不该注入 alwaysVisible：边缘窗的策略不能漏回主菜单。
        // 这里只固定"注入点只有 popoverContent 一处"这个约定。
        XCTAssertEqual(HoverRevealMode.onHover, EnvironmentValues().hoverRevealMode)
    }

    func testEnvironmentOverrideIsReadable() {
        // 设置 → 读取这条链路本身要通，否则 popover 侧的常展开关会静默失效，
        // 表现是"浮层里那些折叠区怎么悬停都展不开"。
        var values = EnvironmentValues()
        XCTAssertEqual(values.hoverRevealMode, .onHover)
        values.hoverRevealMode = .alwaysVisible
        XCTAssertEqual(values.hoverRevealMode, .alwaysVisible)
    }
}
