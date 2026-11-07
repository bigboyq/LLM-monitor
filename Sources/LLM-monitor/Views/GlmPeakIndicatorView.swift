import SwiftUI

/// GLM Coding Plan 高峰期提示行。
///
/// 纯北京时间计算（`GlmPeakWindow.status(at:calendar:holidays:)`，显式传
/// `PeakWindow.beijingCalendar`，与 DeepSeek 判定形状统一），不依赖 GLM API ——
/// 即使 refresh 失败，只要卡片有数据（`.ok`）就照常显示。公共外壳与倒计时格式化复用
/// `PeakIndicatorView`，这里只注入 GLM 专属的文案 / 图标 / 配色。
struct GlmPeakIndicatorView: View {
    let window: GlmPeakWindow

    var body: some View {
        PeakIndicatorView(
            status: { date in
                switch window.status(at: date, calendar: PeakWindow.beijingCalendar) {
                case .peak(until: let end): return (true, end)
                case .offPeak(until: let start): return (false, start)
                }
            },
            peakRow: { end in
                // 倍率相对于非高峰期，默认 2×。
                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(MenuTypography.badge)
                    Text("高峰期 \(window.multiplierLabel) · 还剩 \(formatPeakDuration(end.timeIntervalSinceNow))")
                        .font(MenuTypography.metricValue)
                }
                .foregroundStyle(.red)
            },
            offPeakRow: { start in
                // 距高峰期 < 1 小时 → 橙色（临近）；≥ 1 小时 → 绿色。
                // 默认价格（1×）不标注倍率；倍率只在偏离 1× 时展示（高峰行、未来的闲时折扣行）。
                let secs = start.timeIntervalSinceNow
                let tier: Color = secs < 3600 ? Color.warningTint : .healthyTint
                HStack(spacing: 4) {
                    Image(systemName: "snowflake")
                        .font(MenuTypography.badge)
                    Text("距高峰期 \(formatPeakDuration(secs))")
                        .font(MenuTypography.metricLabel)
                }
                .foregroundStyle(tier)
            }
        )
    }
}
