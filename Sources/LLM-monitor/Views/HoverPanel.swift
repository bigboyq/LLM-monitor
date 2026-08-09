import SwiftUI
import AppKit

/// Hover 即显的轻量浮层。只读展示，不接收点击，避免把菜单交互复杂化。
/// 三个 provider 的 footer / card 全部走 `HoverInfoRow` 统一触发，详情 view 由调用方传入。
struct HoverInfoRow<Content: View, Detail: View>: View {
    let content: Content
    let detail: Detail

    init(@ViewBuilder content: () -> Content,
         @ViewBuilder detail: () -> Detail) {
        self.content = content()
        self.detail = detail()
    }

    var body: some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("悬停查看详细信息")
            .accessibilityHint("悬停查看详细信息")
            .background(
                HoverTrackingView(
                    detail: AnyView(detail),
                    onHover: { sample in
                        HoverPanelController.shared.hoverMoved(
                            detail: AnyView(detail),
                            sample: sample,
                            delay: 0.15
                        )
                    },
                    onExit: {
                        HoverPanelController.shared.hide()
                    }
                )
            )
    }
}

struct HoverSample {
    let screenPoint: CGPoint
    let visibleFrame: CGRect
    let hostWindow: NSWindow?
}

private struct HoverTrackingView: NSViewRepresentable {
    let detail: AnyView
    let onHover: (HoverSample) -> Void
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onHover: onHover, onExit: onExit)
    }

    func makeNSView(context: Context) -> TrackingNSView {
        let view = TrackingNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: TrackingNSView, context: Context) {
        context.coordinator.onHover = onHover
        context.coordinator.onExit = onExit
        nsView.coordinator = context.coordinator

        if context.coordinator.isCurrentlyHovered {
            let d = detail
            DispatchQueue.main.async {
                HoverPanelController.shared.updateContent(detail: d)
            }
        }
    }

    final class Coordinator: NSObject {
        var onHover: (HoverSample) -> Void
        var onExit: () -> Void
        weak var ownerWindow: NSWindow?
        var isCurrentlyHovered = false

        init(onHover: @escaping (HoverSample) -> Void,
             onExit: @escaping () -> Void) {
            self.onHover = onHover
            self.onExit = onExit
        }

        func handleHover(screenPoint: CGPoint) {
            isCurrentlyHovered = true
            let visibleFrame = NSScreen.screens
                .first(where: { NSMouseInRect(screenPoint, $0.frame, false) })?
                .visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? .zero

            onHover(HoverSample(
                screenPoint: screenPoint,
                visibleFrame: visibleFrame,
                hostWindow: ownerWindow
            ))
        }

        func handleExit() {
            isCurrentlyHovered = false
            onExit()
        }
    }
}

private final class TrackingNSView: NSView {
    weak var coordinator: HoverTrackingView.Coordinator?
    private var trackingAreaRef: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.ownerWindow = window
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
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
        reportHover(event)
    }

    override func mouseMoved(with event: NSEvent) {
        reportHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.handleExit()
    }

    private func reportHover(_ event: NSEvent) {
        _ = convert(event.locationInWindow, from: nil)
        coordinator?.handleHover(screenPoint: NSEvent.mouseLocation)
    }
}

@MainActor
final class HoverPanelController {
    static let shared = HoverPanelController()
    private let cursorGap: CGFloat = 6
    private let maximumPanelWidth: CGFloat = 420

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var pendingDetail: AnyView?
    private var pendingSample: HoverSample?
    private var showWorkItem: DispatchWorkItem?

    private init() {}

    func hoverMoved(detail: AnyView, sample: HoverSample, delay: TimeInterval) {
        pendingDetail = detail
        pendingSample = sample

        if panel?.isVisible == true {
            present(detail: detail, sample: sample)
            return
        }

        if showWorkItem == nil {
            let item = DispatchWorkItem { [weak self] in
                self?.showWorkItem = nil
                guard let detail = self?.pendingDetail,
                      let sample = self?.pendingSample else { return }
                self?.present(detail: detail, sample: sample)
            }
            showWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    func hide() {
        showWorkItem?.cancel()
        showWorkItem = nil
        pendingDetail = nil
        pendingSample = nil
        panel?.orderOut(nil)
    }

    func updateContent(detail: AnyView) {
        if panel?.isVisible == true {
            pendingDetail = detail
            if let sample = pendingSample {
                present(detail: detail, sample: sample)
            }
        }
    }

    private func present(detail: AnyView, sample: HoverSample) {
        let panel = ensurePanel()
        let hostingView = ensureHostingView()

        hostingView.rootView = AnyView(
            detail
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(NSColor.windowBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
                // NSHostingView 会以当前 panel 的宽度参与 fittingSize 计算；
                // 保持详情的固有宽度，避免较长的 token 数在测量阶段被省略。
                .fixedSize(horizontal: true, vertical: false)
        )

        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let size = CGSize(
            width: min(
                max(fitting.width, 180),
                min(maximumPanelWidth, max(sample.visibleFrame.width - cursorGap * 2, 180))
            ),
            height: max(fitting.height, 44)
        )

        let frame = frameForPanel(size: size, sample: sample)
        attachPanel(panel, to: sample.hostWindow)
        panel.setContentSize(size)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: .init(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true

        self.panel = panel
        return panel
    }

    private func ensureHostingView() -> NSHostingView<AnyView> {
        if let hostingView { return hostingView }
        let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        panel?.contentView = hostingView
        self.hostingView = hostingView
        return hostingView
    }

    private func frameForPanel(size: CGSize, sample: HoverSample) -> CGRect {
        let visible = sample.visibleFrame
        guard visible.width > 0, visible.height > 0 else {
            return CGRect(
                origin: CGPoint(x: sample.screenPoint.x + cursorGap, y: sample.screenPoint.y - size.height - cursorGap),
                size: size
            )
        }

        let originX: CGFloat
        if sample.screenPoint.x + cursorGap + size.width <= visible.maxX {
            originX = sample.screenPoint.x + cursorGap
        } else {
            originX = max(visible.minX, sample.screenPoint.x - size.width - cursorGap)
        }

        let preferredY = sample.screenPoint.y + cursorGap
        let originY: CGFloat
        if preferredY + size.height <= visible.maxY {
            originY = preferredY
        } else {
            // 屏幕下方空间不足 → 翻转到 mouse 上方
            originY = max(visible.minY, sample.screenPoint.y - size.height - cursorGap)
        }

        return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }

    private func attachPanel(_ panel: NSPanel, to hostWindow: NSWindow?) {
        if let currentParent = panel.parent, currentParent !== hostWindow {
            currentParent.removeChildWindow(panel)
        }
        if let hostWindow, panel.parent !== hostWindow {
            hostWindow.addChildWindow(panel, ordered: .above)
        }
    }
}
