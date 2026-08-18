import SwiftUI
import AppKit

/// 菜单栏图标视图 — 固宽精致图标，动态感知 Provider 健康度与刷新状态
///
/// 重绘协议：`MenuBarExtra` 对 label 内的 `@Published` 观察不可靠（实测 body 不会
/// 重 eval），但 `@State` 变化一定能强制重绘——这是 `statusRevision` bump 生效的
/// 原理。之前的实现每次 `statusDidChange` 都无条件 bump + 重合成 NSImage；现在
/// 只有"可见输入签名"（图标样式 / 健康度 / 圆点开关 / 刷新中 / 外观）真正变化时
/// 才重合成 + bump，其余状态变化零开销。
struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @ObservedObject var configStore: ConfigStore
    @Environment(\.colorScheme) private var colorScheme
    /// 改变 `.id()` 强制 MenuBarExtra 丢弃缓存的 label 内容。
    @State private var statusRevision: UInt = 0
    /// 上次合成图像时的可见输入签名。
    @State private var renderedSignature: RenderSignature?
    /// 缓存的合成图像。`.id(statusRevision)` 只作用在内容子视图上，这两个
    /// @State 存在于本 view，不会随子视图 identity 变化被重置。
    @State private var cachedImage: NSImage?

    /// 决定菜单栏图像内容的全部输入。任一变化才需要重合成 NSImage。
    struct RenderSignature: Equatable {
        let iconStyle: StatusBarIconStyle
        let health: HealthLevel?
        let showsHealthDot: Bool
        let isRefreshing: Bool
        let colorScheme: ColorScheme
    }

    var body: some View {
        // 分钟脉冲由 AppState 发布。不要在 MenuBarExtra label 内放 TimelineView：
        // 部分 macOS 版本会因此持续重建 status item 图像，导致 CPU/内存失控。
        let iconStyle = configStore.config.effectiveStatusBarIconStyle
        let showsHealthDot = configStore.config.effectiveStatusBarHealthDotEnabled
        let health = state.systemHealthLevel(at: state.healthEvaluationDate)

        content(iconStyle: iconStyle, health: health, showsHealthDot: showsHealthDot)
            .frame(width: 22, height: 22)
            .accessibilityLabel(accessibilityTitle(health: health))
            .onAppear {
                rerenderIfNeeded()
            }
            .onReceive(state.statusDidChange) { _ in
                rerenderIfNeeded()
            }
            .onReceive(configStore.$config.dropFirst()) { _ in
                rerenderIfNeeded()
            }
    }

    @ViewBuilder
    private func content(
        iconStyle: StatusBarIconStyle,
        health: HealthLevel?,
        showsHealthDot: Bool
    ) -> some View {
        if state.isRefreshing {
            Image(systemName: "arrow.triangle.2.circlepath")
                .id(statusRevision)
        } else if let cachedImage {
            // MenuBarExtra 对 label 内的 SwiftUI overlay/ZStack 支持不稳定，
            // 先合成为单张原色图，再交给系统状态栏绘制。
            Image(nsImage: cachedImage)
                .renderingMode(.original)
                .accessibilityHidden(true)
                .id(statusRevision)
        } else {
            // onAppear 前的首帧；随后 rerenderIfNeeded 会缓存并接管。
            Image(nsImage: Self.composedMenuBarImage(
                iconStyle: iconStyle,
                health: health,
                showsHealthDot: showsHealthDot
            ))
                .renderingMode(.original)
                .accessibilityHidden(true)
        }
    }

    private func rerenderIfNeeded() {
        let signature = RenderSignature(
            iconStyle: configStore.config.effectiveStatusBarIconStyle,
            health: state.systemHealthLevel(at: state.healthEvaluationDate),
            showsHealthDot: configStore.config.effectiveStatusBarHealthDotEnabled,
            isRefreshing: state.isRefreshing,
            colorScheme: colorScheme
        )
        guard cachedImage == nil || renderedSignature != signature else { return }
        renderedSignature = signature
        cachedImage = Self.composedMenuBarImage(
            iconStyle: signature.iconStyle,
            health: signature.health,
            showsHealthDot: signature.showsHealthDot
        )
        statusRevision &+= 1
    }

    static func composedMenuBarImage(
        iconStyle: StatusBarIconStyle,
        health: HealthLevel?,
        showsHealthDot: Bool = true
    ) -> NSImage {
        let canvasSize = NSSize(width: 22, height: 22)
        let baseConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
        let baseImage = NSImage(
            systemSymbolName: iconStyle.systemImageName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(baseConfiguration)

        let image = NSImage(size: canvasSize, flipped: false) { _ in
            baseImage?.draw(in: NSRect(x: 1, y: 1, width: 20, height: 20))

            if showsHealthDot, let dotColor = statusDotColor(for: health) {
                dotColor.setFill()
                // AppKit 坐标原点在左下角，因此 x=16、y=0 对齐右下角。
                NSBezierPath(ovalIn: NSRect(x: 16, y: 0, width: 6, height: 6)).fill()
            }
            return true
        }
        // 保留状态圆点颜色；主图标只使用动态 labelColor。
        image.isTemplate = false
        return image
    }

    static func statusDotColor(for health: HealthLevel?) -> NSColor? {
        switch health {
        case .healthy:
            return .systemGreen
        case .warning:
            return .systemOrange
        case .critical:
            return .systemRed
        case nil:
            return nil
        }
    }

    private func accessibilityTitle(health: HealthLevel?) -> String {
        var title = "LLM Monitor"
        if state.isRefreshing {
            title += " - 刷新中"
        } else if let health {
            switch health {
            case .healthy:
                title += " - 正常"
            case .warning:
                title += " - 额度预警/高峰期"
            case .critical:
                title += " - 服务异常"
            }
        }
        return title
    }
}
