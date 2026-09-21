import SwiftUI
import AppKit

/// 统一管理下拉菜单窗口与菜单栏底边的吸附对齐及尺寸同步
@MainActor
enum MenuWindowAlignment {
    /// 吸收系统 popover 顶部 ~10pt 的透明留白/阴影，使菜单深色 header 严丝合缝贴紧 macOS 菜单栏底边，消除空白缝隙
    static let topOffset: CGFloat = 10.0
    private static var isAligning = false

    /// 精确解析窗口当前所在屏幕（多屏环境下通过窗口位置、相交矩形及鼠标落点稳健识别，杜绝多屏误判）
    static func effectiveScreen(for window: NSWindow) -> NSScreen {
        if let screen = window.screen {
            return screen
        }
        if let screen = NSScreen.screens.first(where: { NSIntersectsRect(window.frame, $0.frame) }) {
            return screen
        }
        let mouseLoc = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    static func align(window: NSWindow, cardsHeight: CGFloat = 0) {
        guard !isAligning else { return }
        let screen = effectiveScreen(for: window)
        isAligning = true
        defer { isAligning = false }

        let visible = screen.visibleFrame
        let targetTopY = visible.maxY + topOffset

        // 卡片尚未就绪时仅做顶部吸附，绝不缩减窗口高度避免卡片坍缩
        guard cardsHeight > 0 else {
            if abs(window.frame.maxY - targetTopY) > 0.5 {
                window.setFrameTopLeftPoint(NSPoint(x: window.frame.origin.x, y: targetTopY))
            }
            return
        }

        // 真实可用高度：从顶部菜单栏到屏幕底部的实际可用垂直空间（解决小屏幕如 MacBook Retina 下 5 张卡片完全能放下却被误判超标的问题）
        let availableScreen = max(visible.height, screen.frame.height - 35)
        let maxHeight70 = MenuPanelHeightBridge.cappedHeight(visible.height)
        let totalNaturalHeight = cardsHeight + MenuPanelHeightBridge.chromeHeight
        let contentFitting = window.contentView?.fittingSize.height ?? 0

        // 逻辑：“如果屏幕能展示就展示，不能展示按屏幕大小 70% 做”
        let targetHeight: CGFloat
        if totalNaturalHeight <= availableScreen {
            if contentFitting > 100 && abs(contentFitting - totalNaturalHeight) < 50 {
                targetHeight = contentFitting
            } else {
                targetHeight = totalNaturalHeight
            }
        } else {
            targetHeight = maxHeight70
        }

        let targetRect = NSRect(
            x: window.frame.origin.x,
            y: targetTopY - targetHeight,
            width: MenuPanelHeightBridge.width,
            height: targetHeight
        )

        if abs(window.frame.height - targetHeight) > 0.5 || abs(window.frame.maxY - targetTopY) > 0.5 {
            window.setFrame(targetRect, display: true)
        }
    }
}

/// 监控 MenuBarExtra 主窗口：
/// 1. 失焦（窗口 resign key / app resign active）立即关闭
/// 2. 连续 30 秒“无交互”关闭：attach 时启动计时；菜单窗口内的
///    mouse move/down、scroll、key down 重置计时（F4 锁定语义）。
/// 3. 每次面板打开（窗口 become key）回调 `onPanelOpen`：MenuBarExtra 的
///    onAppear 只保证首次创建时触发，无法作为「每次打开」的可靠信号，而
///    become key 与关闭路径的 resign key 是对称事件，每次打开必触发。
///
/// 计时状态机抽出到可单测的 `MenuInactivityTimer`，事件监听只在生产 bridge 里安装。
struct MenuWindowAutoCloseBridge: NSViewRepresentable {
    /// 面板每次打开（窗口 become key）时的回调，如「节能」健康灯的即时刷新；默认 nil。
    var onPanelOpen: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.coordinator = context.coordinator
        view.onPanelOpen = onPanelOpen
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.coordinator = context.coordinator
        nsView.onPanelOpen = onPanelOpen
    }

    @MainActor
    final class Coordinator: NSObject {
        private final class ObserverStore: @unchecked Sendable {
            var values: [NSObjectProtocol] = []
            deinit {
                values.forEach(NotificationCenter.default.removeObserver)
            }
        }

        private weak var window: NSWindow?
        private let observerStore = ObserverStore()
        private var localMonitor: Any?
        private let inactivityInterval: TimeInterval
        private let timer: MenuInactivityTimer
        /// 面板每次打开（become key）时的回调；由 TrackingNSView 转发赋值。
        var onPanelOpen: (() -> Void)?

        init(inactivityInterval: TimeInterval = 30,
             scheduler: (any InactivityScheduler)? = nil) {
            self.inactivityInterval = inactivityInterval
            var closure: () -> Void = {}
            // 生产默认 scheduler 在 MainActor 上下文内构造，避免在非隔离的
            // makeCoordinator 默认参数里调用 @MainActor 初始化器。
            self.timer = MenuInactivityTimer(
                interval: inactivityInterval,
                scheduler: scheduler ?? DispatchInactivityScheduler(),
                onClose: { closure() }
            )
            super.init()
            // attach 时用真实 window 绑定实际关闭动作。
            closure = { [weak self] in
                self?.closeMenu(reason: "30s 无交互")
            }
        }

        private var isAligning = false

        func alignToMenuBar(window: NSWindow) {
            guard !isAligning else { return }
            isAligning = true
            MenuWindowAlignment.align(window: window)
            isAligning = false
        }

        func attach(window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window
            timer.cancel()
            removeObservers()
            removeLocalMonitor()

            // 鼠标移动事件默认只对有 tracking area 的视图投递；开启后 local monitor
            // 才能收到 mouseMoved，用于“持续滚动/移动不关闭”。
            window.acceptsMouseMovedEvents = true

            // 附着并立即执行顶部菜单栏底边吸附，确保不会掉入屏幕居中位置
            alignToMenuBar(window: window)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.alignToMenuBar(window: window)
            }

            observerStore.values.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                Task { @MainActor [weak self] in
                    if let window {
                        self?.alignToMenuBar(window: window)
                    }
                    self?.onPanelOpen?()
                }
            })

            observerStore.values.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                Task { @MainActor [weak self] in
                    if let window {
                        self?.alignToMenuBar(window: window)
                    }
                }
            })

            observerStore.values.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                Task { @MainActor [weak self] in
                    if let window {
                        self?.alignToMenuBar(window: window)
                    }
                }
            })

            observerStore.values.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.closeMenu(reason: "window resigned key")
                }
            })

            observerStore.values.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.detach()
                }
            })

            observerStore.values.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.closeMenu(reason: "app resigned active")
                }
            })

            installLocalMonitor(for: window)
            // attach 时启动 30 秒无交互计时。
            timer.startOrReset()
        }

        /// 注入交互事件：菜单窗口内的 mouseMoved/leftMouseDown/rightMouseDown/
        /// scrollWheel/keyDown 重置 30 秒计时。
        private func installLocalMonitor(for targetWindow: NSWindow) {
            let mask: NSEvent.EventTypeMask = [
                .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown,
            ]
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
                [weak self, weak target = targetWindow] event in
                // 只重置属于本菜单窗口的事件，避免其他窗口的交互影响本菜单计时。
                if let target, event.window === target {
                    Task { @MainActor [weak self] in
                        self?.timer.startOrReset()
                    }
                }
                return event
            }
        }

        private func removeLocalMonitor() {
            if let localMonitor {
                NSEvent.removeMonitor(localMonitor)
                self.localMonitor = nil
            }
        }

        private func removeObservers() {
            observerStore.values.forEach(NotificationCenter.default.removeObserver)
            observerStore.values.removeAll()
        }

        private func detach() {
            timer.cancel()
            removeLocalMonitor()
            removeObservers()
        }

        private func closeMenu(reason: String) {
            timer.cancel()
            guard let window else { return }
            Task { @MainActor in
                HoverPanelController.shared.hide()
                logInfo("MenuWindowAutoCloseBridge: closing menu (\(reason))")
                window.orderOut(nil)
            }
        }
    }
}

extension MenuWindowAutoCloseBridge {
    final class TrackingNSView: NSView {
        weak var coordinator: Coordinator?
        /// 透传 bridge 的面板打开回调；updateNSView 时刷新，窗口附着后生效。
        var onPanelOpen: (() -> Void)? {
            didSet { coordinator?.onPanelOpen = onPanelOpen }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(window: window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

// MARK: - Inactivity timer (testable)

/// 可注入的“延时执行”句柄；生产用 DispatchWorkItem，测试可注入受控实现。
@MainActor
protocol InactivityHandle: AnyObject {
    func cancel()
}

/// 可注入的调度器；生产用 `DispatchQueue.main.asyncAfter`，测试可注入立即/受控触发。
@MainActor
protocol InactivityScheduler: AnyObject {
    func schedule(
        after delay: TimeInterval,
        _ block: @escaping @MainActor @Sendable () -> Void
    ) -> any InactivityHandle
}

/// 30 秒“无交互”关闭的计时状态机。可注入调度器，便于在单元测试中验证
/// start / reset / cancel，无需等待真实 30 秒。
@MainActor
final class MenuInactivityTimer {
    private let interval: TimeInterval
    private let scheduler: any InactivityScheduler
    private let onClose: () -> Void
    private var currentHandle: (any InactivityHandle)?
    /// 每次 startOrReset 生成新 token；过期 fire（被 reset 替换的旧计时）不会触发 close。
    private var currentToken = UUID()
    /// 测试观察：close 触发次数。
    private(set) var fireCount = 0

    init(
        interval: TimeInterval,
        scheduler: any InactivityScheduler,
        onClose: @escaping () -> Void
    ) {
        self.interval = interval
        self.scheduler = scheduler
        self.onClose = onClose
    }

    /// 启动或重置：取消旧计时，安排新的 interval 后触发。
    func startOrReset() {
        cancel()
        let token = UUID()
        currentToken = token
        currentHandle = scheduler.schedule(after: interval) { [weak self] in
            guard let self, self.currentToken == token else { return }
            self.fireCount += 1
            self.onClose()
        }
    }

    func cancel() {
        currentHandle?.cancel()
        currentHandle = nil
        // 让任何在途的 fire 因为 token 不匹配而失效。
        currentToken = UUID()
    }
}

// MARK: - Production scheduler

/// 生产调度器：DispatchQueue.main.asyncAfter + 可取消的 DispatchWorkItem。
@MainActor
final class DispatchInactivityScheduler: InactivityScheduler {
    func schedule(
        after delay: TimeInterval,
        _ block: @escaping @MainActor @Sendable () -> Void
    ) -> any InactivityHandle {
        let handle = DispatchHandle()
        let workItem = DispatchWorkItem { [weak handle] in
            handle?.fire(block)
        }
        handle.workItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return handle
    }

    private final class DispatchHandle: InactivityHandle {
        var workItem: DispatchWorkItem?
        func cancel() {
            workItem?.cancel()
            workItem = nil
        }
        @MainActor
        func fire(_ block: @escaping @MainActor @Sendable () -> Void) {
            guard workItem != nil else { return }  // 已取消则不触发
            block()
        }
    }
}
