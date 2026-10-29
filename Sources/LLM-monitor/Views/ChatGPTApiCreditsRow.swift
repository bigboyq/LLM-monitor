import SwiftUI

/// ChatGPT API 赠金用量与周期进度行
struct ChatGPTApiCreditsRow: View {
    let credits: OpenAIApiCreditDetails?
    let tint: Color
    let error: String?

    @Environment(\.displayDate) private var displayDate

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("API赠金 · USD")
                    .font(MenuTypography.hoverRowEmphasis)
                    .foregroundStyle(Color.primaryLabel)

                Spacer(minLength: 4)

                Text(credits?.organizationName ?? "未知组织")
                    .font(MenuTypography.dataLabel)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let credits {
                SegmentedQuotaProgressBar(
                    primaryFraction: credits.remainingPercent / 100.0,
                    weeklyFraction: credits.remainingPercent / 100.0,
                    tint: tint,
                    segments: 1,
                    height: 8,
                    timeRemainingFraction: credits.timeRemainingFraction(at: displayDate)
                )
                .frame(maxWidth: .infinity)

                HStack(spacing: 6) {
                    Text("已用 \(usedAmountText) 剩余：\(remainingQuotaText)")
                        .font(MenuTypography.dataValue)
                        .foregroundStyle(Color.secondaryLabel)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    HStack(spacing: 3) {
                        if credits.lastAttemptFailed == true || error != nil {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .accessibilityLabel("API赠金更新失败，显示上次成功的数据")
                        }
                        Text("周期至 \(Formatters.formatMonthDayMinute(credits.cycleEnd))（\(expiryCountdownText)）")
                            .font(MenuTypography.resetDate)
                            .foregroundStyle(Color.secondaryLabel)
                            .lineLimit(1)
                    }
                }
                .minimumScaleFactor(0.85)
                .help(credits.lastAttemptFailed == true || error != nil
                    ? failureTooltip
                    : "总额度: $\(formatQuota(credits.totalQuota))，已用: $\(usedAmountText)，剩余: $\(formatNumber(credits.remainingAmount))")
            } else {
                Text(error ?? "API赠金暂无数据")
                    .font(MenuTypography.dataLabel)
                    .foregroundStyle(Color.secondaryLabel)
            }
        }
    }

    private var usedAmountText: String {
        guard let credits else { return "—" }
        return String(format: "%.2f", credits.usedAmount)
    }

    private var remainingQuotaText: String {
        guard let credits else { return "—" }
        return "\(formatNumber(credits.remainingAmount))/\(formatQuota(credits.totalQuota))"
    }

    private var failureTooltip: String {
        let explanation = "API赠金更新失败，显示上次成功的数据"
        guard let error, !error.isEmpty else { return explanation }
        return "\(explanation)：\(error)"
    }

    private var expiryCountdownText: String {
        guard let credits else { return "—" }
        let delta = credits.cycleEnd.timeIntervalSince(displayDate)
        guard delta > 0 else { return "已到期" }
        let total = Int(delta.rounded())
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 {
            return "剩余\(days)天"
        } else if hours > 0 {
            return minutes > 0 ? "剩余\(hours)小时\(minutes)分" : "剩余\(hours)小时"
        } else {
            return "剩余\(max(minutes, 1))分"
        }
    }

    private func formatNumber(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }

    private func formatQuota(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }
}
