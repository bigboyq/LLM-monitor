import SwiftUI

/// ChatGPT API 赠金用量与周期进度行
struct ChatGPTApiCreditsRow: View {
    let credits: OpenAIApiCreditDetails
    let tint: Color

    @Environment(\.displayDate) private var displayDate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: 标题 + 空间/组织名称
            HStack {
                Text("API赠金")
                    .font(MenuTypography.hoverRowEmphasis)
                    .foregroundStyle(Color.primaryLabel)

                Spacer()

                Text(credits.organizationName ?? "Personal")
                    .font(MenuTypography.dataLabel)
                    .foregroundStyle(Color.secondaryLabel)
            }

            // Row 2: 剩余额度: + 分段进度条 + 额度标签
            HStack(spacing: 8) {
                Text("剩余额度:")
                    .font(MenuTypography.dataLabel)
                    .foregroundStyle(Color.secondaryLabel)
                    .frame(width: 52, alignment: .leading)

                SegmentedQuotaProgressBar(
                    primaryFraction: credits.remainingPercent / 100.0,
                    weeklyFraction: credits.remainingPercent / 100.0,
                    tint: tint,
                    segments: 1,
                    height: 8,
                    timeRemainingFraction: credits.timeRemainingFraction(at: displayDate)
                )

                Text(totalQuotaText)
                    .font(MenuTypography.dataValue)
                    .foregroundStyle(Color.primaryLabel)
                    .frame(minWidth: 32, alignment: .trailing)
                    .help("总额度: \(totalQuotaText)，剩余: \(remainingAmountText)")
            }

            // Row 3: 已用金额 + 有效期与倒计时
            HStack {
                Text("已用：\(usedAmountText)")
                    .font(MenuTypography.dataValue)
                    .foregroundStyle(Color.secondaryLabel)

                Spacer()

                Text("有效期：\(Formatters.formatMonthDayMinute(credits.cycleEnd)) (\(expiryCountdownText))")
                    .font(MenuTypography.resetDate)
                    .foregroundStyle(Color.secondaryLabel)
            }
        }
    }

    private var totalQuotaText: String {
        if credits.totalQuota.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "$%.0f", credits.totalQuota)
        } else {
            return String(format: "$%.2f", credits.totalQuota)
        }
    }

    private var remainingAmountText: String {
        if credits.remainingAmount.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "$%.0f", credits.remainingAmount)
        } else {
            return String(format: "$%.2f", credits.remainingAmount)
        }
    }

    private var usedAmountText: String {
        String(format: "$%.2f", credits.usedAmount)
    }

    private var expiryCountdownText: String {
        Formatters.formatBillingRemainingDuration(credits.cycleEnd.timeIntervalSince(displayDate))
    }
}
