import SwiftUI

// MARK: - DeepSeek API 余额专用行

/// DeepSeek API 余额专用展示行：不展示 5h 配额条与 100% 百分比，展示真实资金余额与结构。
struct DeepseekBalanceRow: View {
    let model: ModelQuota
    let planLabel: String?
    /// R7: 余额明细由结构化字段本地格式化，不再解析 accountEmail 预格式化串。
    let balanceDetail: DeepseekBalanceDetail?
    let tint: Color
    let peakWindow: DeepseekPeakWindow
    /// 高峰期倒计时已提到卡片头部时置 false（dock 详情浮层）。
    var showsPeakIndicator: Bool = true
    /// 夹在余额块与下方**本地用量**之间的卡片级信息（重置卡、高峰期倒计时），见
    /// `ModelQuotaDockBlock.between`。DeepSeek 没有额度条块，所以它排在余额块
    /// 正下方——位置等价，"额度概览在上、用量在下"的读法不变。
    var between: AnyView = AnyView(EmptyView())

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            balanceBlock
            between
        }
        .padding(.vertical, 2)
    }

    private var balanceBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                    Text("API 账户余额")
                        .font(MenuTypography.hoverTitle)
                        .foregroundStyle(Color.primaryLabel)
                }

                Spacer()

                if let planLabel {
                    Text(planLabel)
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(planLabel)
                }
            }

            HStack(spacing: 8) {
                if let detail = balanceDetail {
                    let symbol = detail.symbol
                    let toppedUpText = "充值: \(symbol)\(String(format: "%.2f", detail.toppedUp))"
                    let grantedText = "赠金: \(symbol)\(String(format: "%.2f", detail.granted))"
                    // R16: 明细单行截断，hover 看完整文本；layoutPriority 让 PeakIndicator 不被遮挡。
                    HStack(spacing: 8) {
                        Text(toppedUpText)
                            .font(MenuTypography.metricLabel)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(toppedUpText)
                        Text(grantedText)
                            .font(MenuTypography.metricLabel)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(grantedText)
                    }
                    .layoutPriority(-1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                Spacer(minLength: 4)

                if showsPeakIndicator {
                    DeepseekPeakIndicatorView(window: peakWindow)
                        .layoutPriority(1)
                }
            }
        }
    }
}
