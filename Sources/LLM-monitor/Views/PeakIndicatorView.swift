import SwiftUI

/// 高峰期倒计时行的公共组件。
///
/// GLM / DeepSeek 两个 provider 都有"高峰期提示"这一行，结构完全一致：
/// `TimelineView(.periodic(by: 60))` 每分钟重算当前高峰状态 → 按峰 / 非峰渲染一行
/// 倒计时。这里把公共外壳 + 倒计时格式化 `formatDuration` 收成一份，各 provider 只
/// 注入自己的文案 / 图标 / 配色差异，避免两份逐字复制后维护漂移。
struct PeakIndicatorView<Peak: View, OffPeak: View>: View {
    /// 计算 `now` 时刻的高峰状态：`(是否高峰, 下一个边界时刻)`。
    let status: (Date) -> (isPeak: Bool, boundary: Date)
    let peakRow: (Date) -> Peak
    let offPeakRow: (Date) -> OffPeak

    init(
        status: @escaping (Date) -> (isPeak: Bool, boundary: Date),
        @ViewBuilder peakRow: @escaping (Date) -> Peak,
        @ViewBuilder offPeakRow: @escaping (Date) -> OffPeak
    ) {
        self.status = status
        self.peakRow = peakRow
        self.offPeakRow = offPeakRow
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let s = status(timeline.date)
            if s.isPeak {
                peakRow(s.boundary)
            } else {
                offPeakRow(s.boundary)
            }
        }
    }
}

/// 紧凑倒计时："2天8小时" / "1小时30分" / "1小时" / "30分"。
/// GLM / DeepSeek 两个高峰提示行共用，避免两份逐字复制后漂移。
func formatPeakDuration(_ seconds: TimeInterval) -> String {
    let total = max(Int(seconds.rounded()), 0)
    let days = total / 86_400
    let hours = (total % 86_400) / 3_600
    let minutes = (total % 3_600) / 60
    if days > 0 { return "\(days)天\(hours)小时" }
    if hours > 0 { return minutes > 0 ? "\(hours)小时\(minutes)分" : "\(hours)小时" }
    return "\(max(minutes, 1))分"
}
