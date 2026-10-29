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
                Text("API赠金")
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

                Text("剩余 \(amount(credits.remainingAmount)) / 总\(amount(credits.totalQuota)) · 已用 \(usedAmountText)")
                    .font(MenuTypography.dataValue)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                HStack(spacing: 4) {
                    Text("周期至 \(Formatters.formatMonthDayMinute(credits.cycleEnd)) (\(expiryCountdownText))")
                    Spacer(minLength: 4)
                    Text(updateStatusText(for: credits))
                }
                .font(MenuTypography.resetDate)
                .foregroundStyle(Color.secondaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .help(error ?? (credits.lastAttemptFailed == true ? "最近一次 API 赠金抓取失败，显示上次成功的数据" : ""))
            } else {
                Text(error ?? "API赠金暂无数据")
                    .font(MenuTypography.dataLabel)
                    .foregroundStyle(Color.secondaryLabel)
            }
        }
    }

    private var usedAmountText: String {
        guard let credits else { return "—" }
        return amount(credits.usedAmount)
    }

    private var expiryCountdownText: String {
        guard let credits else { return "—" }
        return Formatters.formatBillingRemainingDuration(credits.cycleEnd.timeIntervalSince(displayDate))
    }

    private func updateStatusText(for credits: OpenAIApiCreditDetails) -> String {
        let updatedAt = credits.fetchedAt.map { Formatters.formatClock($0) }
        if credits.lastAttemptFailed == true || error != nil {
            return "更新失败" + (updatedAt.map { " · 上次 \($0)" } ?? "")
        }
        return updatedAt.map { "更新 \($0)" } ?? "已更新"
    }

    private func amount(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "$%.0f", value)
        }
        return String(format: "$%.2f", value)
    }
}
