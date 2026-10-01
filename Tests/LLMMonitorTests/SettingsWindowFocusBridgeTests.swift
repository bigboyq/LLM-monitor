import XCTest
import Combine
import AppKit
@testable import LLM_monitor

/// 设置窗口焦点门控。对应 `SettingsWindowFocusBridge`。
final class SettingsWindowFocusBridgeTests: StateTestCase {

    // MARK: - SettingsWindowFocusBridge: 焦点门控
    @MainActor
    func testSettingsWindowKeepsMenuBarAccessoryPolicy() {
        XCTAssertEqual(
            MenuBarAppActivation.policy,
            .accessory,
            "设置窗口可激活并抢焦点，但菜单栏 App 不得切到会显示 Dock 图标的 regular policy"
        )
    }
    /// 验证 `shouldActivate` 不会在用户已经在 Settings 窗口内交互时再激活一次。
    /// 模拟 SwiftUI 每次重绘都触发 updateNSView 的场景，确保不会再走 NSApp.activate。
    @MainActor
    func testSettingsFocusBridgeSkipsWhenSameWindowIsKey() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // 模拟“当前 window 已是 key”的状态：未显式 resign 的窗口在 isKeyWindow 上
        // 可能为 false，但 `previouslyActivated` 为 nil 时 `shouldActivate` 也应返回 true
        // （首启场景）。这里用 nil 验证首启 → 激活。
        XCTAssertTrue(
            SettingsWindowFocusBridge.Coordinator.shouldActivate(
                window: window,
                previouslyActivated: nil
            ),
            "首次进入新窗口应激活"
        )

        // 直接构造两个不同实例，模拟“同一个 window 在 shouldActivate 调用之间保持 key 状态”。
        // 由于 `isKeyWindow` 需要真实 window-server 状态，这里把判定收敛到
        // “window === previouslyActivated && window.isKeyWindow”这一行。
        // 把 NSWindow 子类化覆盖 isKeyWindow 不优雅，改成测“同实例 + isKeyWindow=true”的分支。
        let keyWindow = KeyWindowStub()
        XCTAssertFalse(
            SettingsWindowFocusBridge.Coordinator.shouldActivate(
                window: keyWindow,
                previouslyActivated: keyWindow
            ),
            "同一个 key 窗口二次调用应跳过，避免输入时焦点跳动"
        )
        XCTAssertTrue(
            SettingsWindowFocusBridge.Coordinator.shouldActivate(
                window: keyWindow,
                previouslyActivated: nil
            ),
            "首启 + key 窗口应激活"
        )
        let otherKeyWindow = KeyWindowStub()
        XCTAssertTrue(
            SettingsWindowFocusBridge.Coordinator.shouldActivate(
                window: otherKeyWindow,
                previouslyActivated: keyWindow
            ),
            "换到新窗口（即使都 key）应重新激活"
        )

        // 模拟用户切到其他 app：window 失 key 后再点回 Settings。
        let resignedWindow = NonKeyWindowStub()
        XCTAssertTrue(
            SettingsWindowFocusBridge.Coordinator.shouldActivate(
                window: resignedWindow,
                previouslyActivated: resignedWindow
            ),
            "同一窗口失 key 后再调用应重新激活（用户从其他 app 切回）"
        )
    }
/// 让 NSWindow 在测试里能伪造 isKeyWindow。`NSWindow` 的 isKeyWindow 是
/// 只读且依赖 window-server，常规方式改不了；子类化 override 是 XCTest 里常用
/// 手法。注意：必须放在主 actor 上（NSWindow 本身在 main 上）。
@MainActor
final class KeyWindowStub: NSWindow {
    override var isKeyWindow: Bool { true }
}
@MainActor
final class NonKeyWindowStub: NSWindow {
    override var isKeyWindow: Bool { false }
}
}
