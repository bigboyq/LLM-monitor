import AppKit
import Foundation

/// 拦截菜单栏图标的右键点击事件，显示“刷新”和“退出”菜单。
@MainActor
final class MenuBarRightClickHandler: NSObject, NSMenuDelegate {
    private var statusButton: NSButton?
    private var state: AppState?
    /// `NSEvent.addLocalMonitorForEvents` 返回的 monitor handle 是 `Any` token。
    /// Swift 6 mode 下 `Any` 不是 `Sendable`，无法从 `nonisolated deinit`
    /// 访问——这里标 `nonisolated(unsafe)` 是为了在 app 退出时同步清理 monitor，
    /// handle 由同一 actor 路径在 `attachRightClickMonitor` / deinit 中读写，
    /// 不跨 actor 共享。
    private nonisolated(unsafe) var eventMonitor: Any?

    func setup(state: AppState) {
        self.state = state
        // SwiftUI 的 MenuBarExtra 在 init() 返回后才创建 status bar button，
        // 立即找经常是 nil。改成"立即找一次 + 200ms 间隔重试 5 次"，通常立刻命中
        // （按钮在 init 之后几十 ms 就到位），最差 1s 后放弃——跟之前的 1s 延迟等价，
        // 但常见情况下是 0 等待。
        attemptAttach(retry: 0)
    }

    private func attemptAttach(retry: Int) {
        if let button = findStatusButton() {
            attachRightClickMonitor(to: button)
            return
        }
        guard retry < 5 else {
            logWarn("RightClickHandler: 5 次重试后仍找不到状态栏按钮")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.attemptAttach(retry: retry + 1)
        }
    }

    private func attachRightClickMonitor(to button: NSButton) {
        self.statusButton = button
        logInfo("RightClickHandler: 成功绑定状态栏按钮 (\(String(describing: type(of: button))))")

        // 监听本地事件以拦截右键点击
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self = self,
                  let button = self.statusButton,
                  let window = button.window,
                  event.window == window else {
                return event
            }

            // 消费该事件并展示自定义右键菜单
            self.showRightClickMenu(sender: button)
            return nil
        }
        self.eventMonitor = monitor
    }
    
    private func findStatusButton() -> NSButton? {
        // 方案 1: 在 app 的所有窗口中寻找类型包含 "StatusBarWindow" 的窗口，并查找其内部的 NSButton (即 NSStatusBarButton)
        for window in NSApplication.shared.windows {
            let className = String(describing: type(of: window))
            if className.contains("StatusBarWindow") || className.contains("StatusItem") {
                if let button = findButton(in: window.contentView) {
                    return button
                }
            }
        }
        
        // 方案 2: 作为备用，通过 KVC 获取系统状态栏的 items (如果在沙盒环境或系统升级后不可用，会回退到此并记录 warning)
        if let items = NSStatusBar.system.value(forKey: "items") as? [NSStatusItem] {
            if let item = items.first(where: { $0.button != nil }),
               let button = item.button {
                return button
            }
        } else {
            logWarn("RightClickHandler: 方案 1 与 KVC 备用方案均未成功获取到 status items")
        }
        
        return nil
    }
    
    private func findButton(in view: NSView?) -> NSButton? {
        guard let view = view else { return nil }
        if let button = view as? NSButton {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(in: subview) {
                return found
            }
        }
        return nil
    }
    
    private func showRightClickMenu(sender: NSButton) {
        let menu = NSMenu()
        menu.delegate = self
        
        let refreshItem = NSMenuItem(title: "刷新", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        // 使用非弃用 API 将菜单显示在状态栏按钮的正下方
        let buttonFrame = sender.frame
        let position = NSPoint(x: 0, y: buttonFrame.height)
        menu.popUp(positioning: nil, at: position, in: sender)
    }
    
    @objc private func refreshClicked() {
        logInfo("RightClickHandler: 触发右键菜单手动刷新")
        Task {
            await state?.refreshAll()
        }
    }
    
    @objc private func quitClicked() {
        logInfo("RightClickHandler: 触发右键退出应用")
        NSApplication.shared.terminate(nil)
    }
    
    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
