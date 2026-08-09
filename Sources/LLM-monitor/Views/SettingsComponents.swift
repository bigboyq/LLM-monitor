import SwiftUI
import AppKit

/// 设置窗口统一字体角色。业务视图只选择语义，不再自行决定字号。
enum SettingsTypography {
    static let paneTitle = Font.system(size: 20, weight: .bold)
    static let paneSubtitle = Font.subheadline
    static let sectionTitle = Font.caption.weight(.semibold)
    static let sectionFooter = Font.caption
    static let rowLabel = Font.body
    static let rowEmphasis = Font.body.weight(.semibold)
    static let supporting = Font.subheadline
    static let status = Font.footnote
    static let metadata = Font.caption
    static let metadataMonospaced = Font.caption.monospaced()
    static let numericValue = Font.caption.monospacedDigit()
    static let rowValueMonospaced = Font.system(.body, design: .monospaced)

    static func sidebarItem(isSelected: Bool) -> Font {
        Font.body.weight(isSelected ? .semibold : .regular)
    }
}

/// 设置项统一采用“左侧标签、右侧控件或值”的横向布局。
struct SettingsControlRow<Control: View>: View {
    let label: String
    let alignment: VerticalAlignment
    let control: Control

    init(
        _ label: String,
        alignment: VerticalAlignment = .center,
        @ViewBuilder control: () -> Control
    ) {
        self.label = label
        self.alignment = alignment
        self.control = control()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: 16) {
            Text(label)
                .font(SettingsTypography.rowLabel)
            Spacer(minLength: 20)
            control
        }
        .frame(maxWidth: .infinity)
    }
}

/// macOS 默认 Toggle 可能呈现 checkbox；设置页的布尔项统一为右侧 switch。
struct SettingsToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsControlRow(label) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

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
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let brandAsset = tab.brandAsset {
                    BrandLogoView(asset: brandAsset)
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
                    .font(SettingsTypography.paneTitle)
                Text(tab.subtitle)
                    .font(SettingsTypography.paneSubtitle)
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
                    .font(SettingsTypography.sectionTitle)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .padding(.bottom, 2)
            }

            VStack(alignment: .leading, spacing: 16) {
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
                    .font(SettingsTypography.sectionFooter)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .lineSpacing(2)
            }
        }
    }
}
