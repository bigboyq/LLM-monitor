import SwiftUI

/// 菜单栏图标视图 — 固宽精致图标，动态感知 Provider 健康度与刷新状态
struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @ObservedObject var configStore: ConfigStore

    var body: some View {
        // 高峰健康度是时间派生状态；即使 provider 没有发布新数据，也要在跨越
        // GLM / DeepSeek 高峰边界时主动重算。分钟级刷新与卡片倒计时保持一致。
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let iconStyle = configStore.config.effectiveStatusBarIconStyle
            let indicatorMode = configStore.config.effectiveStatusBarIndicatorMode
            let health = state.systemHealthLevel(at: timeline.date)

            mainIconView(iconStyle: iconStyle, indicatorMode: indicatorMode, health: health)
                .frame(width: 18, height: 18)
                .accessibilityLabel(accessibilityTitle(health: health))
                .onReceive(state.statusDidChange) { _ in
                    // 观察状态变更广播
                }
            }
    }

    @ViewBuilder
    private func mainIconView(
        iconStyle: StatusBarIconStyle,
        indicatorMode: StatusBarIndicatorMode,
        health: HealthLevel?
    ) -> some View {
        if state.isRefreshing {
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(indicatorMode == .colored ? Color.accentColor : Color.primary)
        } else if case .critical = health {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(indicatorMode == .colored ? Color.red : Color.primary)
        } else {
            let imageName = iconStyle.systemImageName
            Image(systemName: imageName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor(indicatorMode: indicatorMode, health: health))
        }
    }

    private func iconColor(indicatorMode: StatusBarIndicatorMode, health: HealthLevel?) -> Color {
        guard indicatorMode == .colored else { return .primary }
        switch health {
        case .healthy:
            return .green
        case .warning:
            return .orange
        case .critical:
            return .red
        case nil:
            return .primary
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
