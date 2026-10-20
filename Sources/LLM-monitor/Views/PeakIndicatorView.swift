import SwiftUI

/// 高峰期倒计时行的公共组件。
///
/// GLM / DeepSeek 两个 provider 都有"高峰期提示"这一行，结构完全一致：
/// 菜单共享时钟每秒推进，消费者按峰 / 非峰渲染一行倒计时。这里把公共外壳 +
/// 倒计时格式化 `formatDuration` 收成一份，各 provider 只
/// 注入自己的文案 / 图标 / 配色差异，避免两份逐字复制后维护漂移。
struct PeakIndicatorView<Peak: View, OffPeak: View>: View {
    /// 计算 `now` 时刻的高峰状态：`(是否高峰, 下一个边界时刻)`。
    let status: (Date) -> (isPeak: Bool, boundary: Date)
    let peakRow: (Date) -> Peak
    let offPeakRow: (Date) -> OffPeak
    @Environment(\.displayDate) private var displayDate

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
        let s = status(displayDate)
        if s.isPeak {
            peakRow(s.boundary)
        } else {
            offPeakRow(s.boundary)
        }
    }
}

/// 紧凑倒计时："2天8小时" / "1小时30分" / "1小时" / "30分"。
/// 统一转发至 `Formatters.formatPeakDuration`，保留本方法以兼容调用点。
func formatPeakDuration(_ seconds: TimeInterval) -> String {
    Formatters.formatPeakDuration(seconds)
}
