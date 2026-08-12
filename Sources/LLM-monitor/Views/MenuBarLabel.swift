import SwiftUI
import AppKit

/// 菜单栏图标视图 — 固宽精致图标，动态感知 Provider 健康度与刷新状态
struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @ObservedObject var configStore: ConfigStore
    @State private var statusRevision: UInt = 0

    var body: some View {
        // 分钟脉冲由 AppState 发布。不要在 MenuBarExtra label 内放 TimelineView：
        // 部分 macOS 版本会因此持续重建 status item 图像，导致 CPU/内存失控。
        let iconStyle = configStore.config.effectiveStatusBarIconStyle
        let showsHealthDot = configStore.config.effectiveStatusBarHealthDotEnabled
        let health = state.systemHealthLevel(at: state.healthEvaluationDate)

        mainIconView(iconStyle: iconStyle, health: health, showsHealthDot: showsHealthDot)
            // MenuBarExtra 会缓存 label；显式改变 identity，确保额度变化后重绘。
            .id(statusRevision)
            .frame(width: 22, height: 22)
            .accessibilityLabel(accessibilityTitle(health: health))
            .onReceive(state.statusDidChange) { _ in
                statusRevision &+= 1
            }
    }

    @ViewBuilder
    private func mainIconView(
        iconStyle: StatusBarIconStyle,
        health: HealthLevel?,
        showsHealthDot: Bool
    ) -> some View {
        if state.isRefreshing {
            Image(systemName: "arrow.triangle.2.circlepath")
        } else {
            // MenuBarExtra 对 label 内的 SwiftUI overlay/ZStack 支持不稳定，
            // 先合成为单张原色图，再交给系统状态栏绘制。
            Image(nsImage: Self.composedMenuBarImage(
                iconStyle: iconStyle,
                health: health,
                showsHealthDot: showsHealthDot
            ))
                .renderingMode(.original)
                .accessibilityHidden(true)
        }
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
                // AppKit 坐标原点在左下角，因此 x=18、y=0 对齐右下角。
                NSBezierPath(ovalIn: NSRect(x: 18, y: 0, width: 4, height: 4)).fill()
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
