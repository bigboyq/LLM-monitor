import SwiftUI

/// ChatGPT API 赠金用量与周期进度行
struct ChatGPTApiCreditsRow: View {
    let credits: OpenAIApiCreditDetails?
    let tint: Color
    let error: String?
    var keyNumber: Int = 1
    var selectedQuotaSource: StatusBarQuotaSource? = nil
    var onSelectQuotaSource: ((StatusBarQuotaSource) -> Void)? = nil

    @Environment(\.displayDate) private var displayDate

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(titleText)
                    .font(MenuTypography.hoverRowEmphasis)
                    .foregroundStyle(Color.primaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(titleText)

                if let keyID = credits?.keyId, let onSelectQuotaSource {
                    let source = StatusBarQuotaSource.apiCredit(keyID: keyID)
                    StatusBarQuotaSourcePinButton(
                        isSelected: selectedQuotaSource == source,
                        title: titleText
                    ) {
                        onSelectQuotaSource(source)
                    }
                }

                Spacer(minLength: 4)

                Text(organizationText)
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
                        if credits.lastAttemptFailed == true || credits.errorMessage != nil || error != nil {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .accessibilityLabel("API赠金更新失败，显示上次成功的数据")
                        }
                        // 估算标记：边界扣除为错过精准窗口的估算（失败警告优先，二者互斥）
                        if showsCarryEstimateMarker {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .help(carryEstimateNotice)
                                .accessibilityLabel(carryEstimateNotice)
                        }
                        Text("周期至 \(Formatters.formatMonthDayMinute(credits.cycleEnd))（\(expiryCountdownText)）")
                            .font(MenuTypography.resetDate)
                            .foregroundStyle(Color.secondaryLabel)
                            .lineLimit(1)
                    }
                }
                .minimumScaleFactor(0.85)
                .help(credits.lastAttemptFailed == true || credits.errorMessage != nil || error != nil
                    ? failureTooltip
                    : normalTooltip)
            } else {
                Text(error ?? "API赠金暂无数据")
                    .font(MenuTypography.dataLabel)
                    .foregroundStyle(Color.secondaryLabel)
            }
        }
    }

    var titleText: String {
        if let label = credits?.keyLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return "API赠金 · \(label)"
        }
        return "API赠金 · API Key #\(keyNumber)"
    }

    private var organizationText: String {
        if let org = credits?.organizationName, !org.isEmpty {
            return org
        }
        return "未知组织"
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
        let effectiveError = credits?.errorMessage ?? error
        guard let effectiveError, !effectiveError.isEmpty else { return explanation }
        return "\(explanation)：\(effectiveError)"
    }

    /// 估算标记：边界扣除为错过精准窗口的估算，且当前非失败态（失败警告优先显示）
    var showsCarryEstimateMarker: Bool {
        guard let credits, credits.carryApproximate else { return false }
        return !(credits.lastAttemptFailed == true || credits.errorMessage != nil || error != nil)
    }

    /// 估算标记的 tooltip / accessibility 文案
    private var carryEstimateNotice: String {
        "边界扣除为估算（错过重置后 1 小时快照窗口），已用可能偏低，可在设置中手动微调"
    }

    /// 正常态 tooltip：额度明细，边界扣除仅在非零时追加
    var normalTooltip: String {
        guard let credits else { return "" }
        var text = "总额度: $\(formatQuota(credits.totalQuota))，已用: $\(usedAmountText)，剩余: $\(formatNumber(credits.remainingAmount))"
        if credits.carryDeduction != 0 {
            let suffix = credits.carryApproximate ? "（估算）" : ""
            let formattedCarry = credits.carryDeduction < 0
                ? "-$\(String(format: "%.2f", -credits.carryDeduction))"
                : "$\(String(format: "%.2f", credits.carryDeduction))"
            text += "，边界扣除: \(formattedCarry)\(suffix)"
        }
        return text
    }

    private var expiryCountdownText: String {
        guard let credits else { return "—" }
        return Formatters.formatRelativeCountdown(
            credits.cycleEnd.timeIntervalSince(displayDate),
            prefix: "剩余",
            expiredText: "已到期",
            includeHoursWhenDays: false
        )
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
