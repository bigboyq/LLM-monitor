import SwiftUI
import AppKit

/// 把 Settings 窗口从 menu-bar app 的 `.accessory` 政策里拽出来、置前并抢焦点。
/// 仅在首次进入窗口或窗口失去 key 状态后重新激活，避免 SwiftUI 重绘导致焦点跳动。
struct SettingsWindowFocusBridge: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in
            coordinator.focusIfNeeded(view: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak nsView] in
            coordinator.focusIfNeeded(view: nsView)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var activatedWindow: NSWindow?

        func focusIfNeeded(view: NSView?) {
            guard let view, let window = view.window else { return }
            guard Self.shouldActivate(window: window, previouslyActivated: activatedWindow) else { return }
            activate(window: window)
        }

        static func shouldActivate(window: NSWindow, previouslyActivated: NSWindow?) -> Bool {
            if window === previouslyActivated, window.isKeyWindow { return false }
            return true
        }

        private func activate(window: NSWindow) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.level = .normal
            window.orderFrontRegardless()
            window.makeMain()
            window.makeKeyAndOrderFront(nil)
            activatedWindow = window
            logDebug("SettingsWindowFocusBridge: focused settings window")
        }
    }
}

struct SettingsPaneHeader: View {
    let tab: SettingsView.SettingsTab

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let brandKind = tab.brandKind {
                    BrandLogoView(kind: brandKind)
                } else {
                    Image(systemName: tab.iconSystemName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 34, height: 34)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(tab.displayTitle)
                    .font(.system(size: 20, weight: .bold))
                Text(tab.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String?
    let footer: String?
    let content: Content

    init(title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .padding(.bottom, 2)
            }

            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.32))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(NSColor.separatorColor).opacity(0.24), lineWidth: 0.5)
            )

            if let footer {
                Text(footer)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .lineSpacing(2)
            }
        }
    }
}
