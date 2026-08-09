import SwiftUI

/// DeepSeek API 高峰期提示行（支持内联嵌入第二行右侧）。
///
/// 基于北京时间倒计时计算（`DeepseekPeakWindow.status(at:)`），不依赖 API 响应。
/// 公共外壳与倒计时格式化复用 `PeakIndicatorView`，这里只注入 DeepSeek 专属的
/// 文案 / 图标 / 配色 / pill 背景。
struct DeepseekPeakIndicatorView: View {
    let window: DeepseekPeakWindow

    init(window: DeepseekPeakWindow = .defaultWindow) {
        self.window = window
    }

    var body: some View {
        PeakIndicatorView(
            status: { date in
                switch window.status(at: date) {
                case .peak(until: let end): return (true, end)
                case .offPeak(until: let start): return (false, start)
                }
            },
            peakRow: { end in
                // 高峰期：价格为平时 2 倍 → 红色高亮提示
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 8))
                    Text("高峰 2× · 还剩 \(formatPeakDuration(end.timeIntervalSinceNow))")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            },
            offPeakRow: { start in
                // 非高峰期：平时 1× 价格。距下一轮高峰 < 1 小时 → 橙色（临近）；≥ 1 小时 → 绿色（余量充足）。
                let secs = start.timeIntervalSinceNow
                let tier: Color = secs < 3600 ? .orange : .green
                HStack(spacing: 3) {
                    Image(systemName: "snowflake")
                        .font(.system(size: 8))
                    Text("距高峰 \(formatPeakDuration(secs))")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(tier)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(tier.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        )
    }
}
