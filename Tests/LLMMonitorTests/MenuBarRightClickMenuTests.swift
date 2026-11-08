import AppKit
import XCTest
@testable import LLM_monitor

/// 2.5.2 回归：右键菜单的「设置」必须是普通 NSMenuItem（target/action），
/// 不能回退到 view 宿主 SettingsLink——NSHostingView 在 popUp 出来的 NSMenu
/// 里不渲染，2.5.1 之前该条目长期隐形（用户只看到 刷新/打开配置文件/退出）。
@MainActor
final class MenuBarRightClickMenuTests: XCTestCase {
    func testMenuContainsRefreshSettingsQuitInOrder() {
        let menu = MenuBarRightClickHandler().makeRightClickMenu()
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, ["刷新", "设置", "退出"])
    }

    func testSettingsItemUsesTargetActionInsteadOfHostingView() {
        // handler 必须由本测试持有强引用：NSMenuItem.target 是 unretained，
        // 临时对象在断言前释放会让 target 变 nil（假阳性）。
        let handler = MenuBarRightClickHandler()
        let menu = handler.makeRightClickMenu()
        let settings = menu.items.first { $0.title == "设置" }
        let settingsItem = try! XCTUnwrap(settings)
        XCTAssertNil(settingsItem.view, "设置条目必须是普通条目，view 宿主在弹出菜单里不渲染")
        XCTAssertIdentical(settingsItem.target as? MenuBarRightClickHandler, handler)
        XCTAssertEqual(settingsItem.action, #selector(MenuBarRightClickHandler.settingsClicked))
    }

    func testSettingsClickedInvokesInjectedOpener() {
        let handler = MenuBarRightClickHandler()
        var called = false
        handler.settingsOpener = { called = true }
        handler.settingsClicked()
        XCTAssertTrue(called, "settingsClicked 应调用注入的 openSettings 动作")
    }
}
