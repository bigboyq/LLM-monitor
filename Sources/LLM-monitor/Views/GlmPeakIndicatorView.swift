import SwiftUI

/// GLM Coding Plan 高峰期提示行。
///
/// 纯本地时间计算（`GlmPeakWindow.status(at:)`），不依赖 GLM API —— 即使 refresh
/// 失败，只要卡片有数据（`.ok`）就照常显示。公共外壳与倒计时格式化复用
/// `PeakIndicatorView`，这里只注入 GLM 专属的文案 / 图标 / 配色。
struct GlmPeakIndicatorView: View {
    let window: GlmPeakWindow

    var body: some View {
        PeakIndicatorView(
            status: { date in
                switch window.status(at: date) {
                case .peak(until: let end): return (true, end)
                case .offPeak(until: let start): return (false, start)
                }
            },
            peakRow: { end in
                // 高峰期：积分按 1× 扣（全价）→ 红色
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(MenuTypography.badge)
                    Text("高峰期 · 还剩 \(formatPeakDuration(end.timeIntervalSinceNow))")
                        .font(MenuTypography.metricValue)
                }
                .foregroundStyle(.red)
            },
            offPeakRow: { start in
                // 非高峰期：积分按 50% 抵扣。距高峰期 < 1 小时 → 橙色（临近）；
                // ≥ 1 小时 → 绿色（余量充足）。
                let secs = start.timeIntervalSinceNow
                let tier: Color = secs < 3600 ? Color.warningTint : .green
                HStack(spacing: 4) {
                    Image(systemName: "snowflake")
                        .font(MenuTypography.badge)
                    Text("距高峰期 \(formatPeakDuration(secs))")
                        .font(MenuTypography.metricLabel)
                    Text("· 非高峰 5 折")
                        .font(MenuTypography.badge)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(tier)
            }
        )
    }
}
