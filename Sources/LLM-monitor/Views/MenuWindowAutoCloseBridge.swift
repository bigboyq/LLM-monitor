import SwiftUI
import AppKit

/// 监控 MenuBarExtra 主窗口：
/// 1. 失焦立即关闭
/// 2. 鼠标移出后 30 秒自动关闭
struct MenuWindowAutoCloseBridge: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        nsView.coordinator = context.coordinator
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
        private var closeWorkItem: DispatchWorkItem?

        func attach(window: NSWindow?) {
            guard let window, self.window !== window else { return }
            self.window = window
            cancelScheduledClose()
            removeObservers()

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
                    self?.cancelScheduledClose()
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
        }

        func mouseEntered() {
            cancelScheduledClose()
        }

        func mouseExited() {
            cancelScheduledClose()
            let workItem = DispatchWorkItem { [weak self] in
                self?.closeMenu(reason: "mouse left for 30s")
            }
            closeWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: workItem)
        }

        func cancelScheduledClose() {
            closeWorkItem?.cancel()
            closeWorkItem = nil
        }

        private func removeObservers() {
            observerStore.values.forEach(NotificationCenter.default.removeObserver)
            observerStore.values.removeAll()
        }

        private func closeMenu(reason: String) {
            cancelScheduledClose()
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
        private var trackingAreaRef: NSTrackingArea?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(window: window)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingAreaRef {
                coordinator?.cancelScheduledClose()
                removeTrackingArea(trackingAreaRef)
            }

            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .activeAlways,
                .inVisibleRect,
            ]
            let trackingAreaRef = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
            addTrackingArea(trackingAreaRef)
            self.trackingAreaRef = trackingAreaRef
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func mouseEntered(with event: NSEvent) {
            coordinator?.mouseEntered()
        }

        override func mouseExited(with event: NSEvent) {
            coordinator?.mouseExited()
        }
    }
}
