import SwiftUI

enum QuotaWindowsHoverPresentation {
    static func normalizedPercent(_ percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return min(max(percent, 0), 100)
    }

    /// 根据计算决策结果生成面向用户的提示文案（纯展示层）
    static func bindingConstraintText(
        primaryLabel: String,
        bindingWindow: BindingQuotaWindow,
        weeklyEquivalentMultiplier: Int,
        weeklyLabel: String
    ) -> String {
        switch bindingWindow {
        case .weekly:
            return "主行展示 \(weeklyLabel) 重置倒计时（\(primaryLabel) 尚有余量，但周额度已达上限优先耗尽）。顶部 ▼ 为周重置时间标记"
        case .primary:
            return "主行展示 \(primaryLabel) 重置倒计时（\(primaryLabel) 额度将优先耗尽）。顶部 ▼ 为周重置时间标记"
        }
    }

    /// 便捷重载：兼容布尔入参
    static func bindingConstraintText(
        primaryLabel: String,
        weeklyIsBinding: Bool,
        weeklyEquivalentMultiplier: Int,
        weeklyLabel: String
    ) -> String {
        bindingConstraintText(
            primaryLabel: primaryLabel,
            bindingWindow: weeklyIsBinding ? .weekly : .primary,
            weeklyEquivalentMultiplier: weeklyEquivalentMultiplier,
            weeklyLabel: weeklyLabel
        )
    }
}

struct QuotaWindowsHoverView: View {
    let title: String
    let weeklyEquivalentMultiplier: Int
    let primaryLabel: String
    let primaryPercent: Double
    let primaryResetsAt: Date?
    let weeklyPercent: Double
    let weeklyResetsAt: Date?
    let secondaryLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(MenuTypography.hoverRowEmphasis)
            Text("周倍率：\(weeklyEquivalentMultiplier)（等价额度分段）")
                .font(MenuTypography.hoverFootnote)
                .foregroundStyle(.secondary)
            Text(effectiveAvailabilityText)
                .font(MenuTypography.hoverCaptionEmphasis.monospacedDigit())
                .foregroundStyle(effectivePrimaryPercent < safePrimaryPercent ? Color.warningTint : .secondary)
            Text(
                QuotaWindowsHoverPresentation.bindingConstraintText(
                    primaryLabel: primaryLabel,
                    bindingWindow: bindingWindow,
                    weeklyEquivalentMultiplier: weeklyEquivalentMultiplier,
                    weeklyLabel: secondaryLabel
                )
            )
            .font(MenuTypography.hoverCaption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HoverMetricLine(label: primaryLabel, percent: safePrimaryPercent, resetsAt: primaryResetsAt)
            Divider().opacity(0.45)
            HoverMetricLine(label: secondaryLabel, percent: safeWeeklyPercent, resetsAt: weeklyResetsAt)
        }
    }

    private var safePrimaryPercent: Double {
        QuotaWindowsHoverPresentation.normalizedPercent(primaryPercent)
    }

    private var safeWeeklyPercent: Double {
        QuotaWindowsHoverPresentation.normalizedPercent(weeklyPercent)
    }

    private var bindingWindow: BindingQuotaWindow {
        EquivalentQuotaAllocation.bindingWindow(
            primaryFraction: safePrimaryPercent / 100.0,
            weeklyFraction: safeWeeklyPercent / 100.0,
            segments: weeklyEquivalentMultiplier
        )
    }

    private var weeklyIsBinding: Bool {
        bindingWindow == .weekly
    }

    private var effectivePrimaryPercent: Double {
        EquivalentQuotaAllocation.effectivePrimaryFraction(
            primaryFraction: safePrimaryPercent / 100.0,
            weeklyFraction: safeWeeklyPercent / 100.0,
            segments: weeklyEquivalentMultiplier
        ) * 100
    }

    private var effectiveAvailabilityText: String {
        let percentage = Formatters.formatQuotaPercent(effectivePrimaryPercent)
        if effectivePrimaryPercent < safePrimaryPercent {
            return "当前 \(primaryLabel) 实际可用 \(percentage)（受周额度限制）"
        }
        return "当前 \(primaryLabel) 实际可用 \(percentage)"
    }
}

struct QuotaUsageWindowsHoverView: View {
    let title: String
    let primaryLabel: String
    let primaryUsage: UsageMetricSummary?
    let primaryCreditUsage: QuotaCountUsage?
    let secondaryLabel: String
    let secondaryUsage: UsageMetricSummary?
    let secondaryCreditUsage: QuotaCountUsage?
    let weeklyEquivalentMultiplier: Int?
    let hasSecondaryWindow: Bool
    let missingUsageIsLoading: Bool
    /// GLM 今日闲时（off-peak）任务 token 用量：不消耗积分，单独展示避免混进
    /// 5h / 周额度窗口。非 GLM / 无闲时数据时传 nil。
    var offPeakUsage: UsageMetricSummary? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(MenuTypography.hoverRowEmphasis)
            if let weeklyEquivalentMultiplier {
                Text("周倍率：\(weeklyEquivalentMultiplier)（本地会话统计）")
                    .font(MenuTypography.hoverFootnote)
                    .foregroundStyle(.secondary)
            }

            usageSection(label: primaryLabel, usage: primaryUsage, creditUsage: primaryCreditUsage)

            if hasSecondaryWindow {
                Divider().opacity(0.45)
                usageSection(label: secondaryLabel, usage: secondaryUsage, creditUsage: secondaryCreditUsage)
            }

            if let offPeakUsage {
                Divider().opacity(0.45)
                VStack(alignment: .leading, spacing: 5) {
                    UsageMetricHoverSummaryView(
                        title: "今日闲时（不消耗积分）",
                        usage: offPeakUsage,
                        showPromptCount: true
                    )
                    Text("ZCode 闲时任务真实消耗；不影响 5h / 周积分余额")
                        .font(MenuTypography.hoverFootnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func usageSection(
        label: String,
        usage: UsageMetricSummary?,
        creditUsage: QuotaCountUsage?
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let creditUsage {
                HStack(spacing: 4) {
                    Text("积分")
                        .foregroundStyle(.secondary)
                    Text("\(Formatters.formatGroupedInt(max(creditUsage.used, 0)))/\(Formatters.formatGroupedInt(creditUsage.total))")
                        .foregroundStyle(.primary)
                }
                .font(MenuTypography.hoverBodyMonospaced)
            }

            if let usage {
                UsageMetricHoverSummaryView(
                    title: "\(label) 本地 token 用量",
                    usage: usage,
                    showPromptCount: true
                )
            } else {
                HStack(spacing: 6) {
                    if missingUsageIsLoading {
                        ProgressView().controlSize(.mini)
                    }
                    Text(
                        missingUsageIsLoading
                            ? "\(label) 用量生成中…"
                            : "\(label) 额度窗口内暂无本地 token 记录"
                    )
                    .font(MenuTypography.hoverCaption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SingleQuotaWindowHoverView: View {
    let title: String
    let label: String
    let percent: Double
    let resetsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) 重置时间")
                .font(MenuTypography.hoverRowEmphasis)
            HoverMetricLine(
                label: label,
                percent: QuotaWindowsHoverPresentation.normalizedPercent(percent),
                resetsAt: resetsAt
            )
        }
    }
}

struct UsageMetricHoverSummaryView: View {
    let title: String
    let usage: UsageMetricSummary
    let showPromptCount: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(MenuTypography.hoverRowEmphasis)
                    .foregroundStyle(.primary)
            }

            if showPromptCount {
                HStack(spacing: 0) {
                    Text("prompts: ")
                        .foregroundStyle(.secondary)
                    Text("\(Formatters.formatGroupedInt(usage.prompts))")
                        .foregroundStyle(.primary)
                    Text(" (\(Formatters.formatGroupedInt(usage.rounds)) rounds)")
                        .foregroundStyle(.secondary)
                }
                .font(MenuTypography.hoverBodyMonospaced)
            } else {
                metricLine(label: "rounds", value: Formatters.formatGroupedInt(usage.rounds))
            }

            metricLine(
                label: "input",
                value: "\(Formatters.formatTokenCountCompact(usage.uncachedInputTokens)) (+\(Formatters.formatTokenCountCompact(usage.cachedInputTokens)) cached)"
            )
            if let cacheHitRate = usage.cacheHitRate {
                metricLine(label: "cache hit", value: Formatters.formatPercent(cacheHitRate, digits: 0))
            }
            metricLine(label: "output", value: Formatters.formatTokenCountCompact(usage.outputTokens))

            if usage.hasReasoningOutput {
                metricLine(label: "reason", value: Formatters.formatTokenCountCompact(usage.reasoningOutputTokens))
            }
            if let reasonRate = usage.reasonRate {
                metricLine(label: "reason rate", value: Formatters.formatPercent(reasonRate, digits: 0))
            }
        }
    }

    @ViewBuilder
    private func metricLine(label: String, value: String) -> some View {
        HStack(spacing: 0) {
            Text("\(label): ")
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
        }
        .font(MenuTypography.hoverBodyMonospaced)
    }
}

struct LastPromptHoverSummaryView: View {
    let lastPrompt: LastPromptUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last Prompt")
                .font(MenuTypography.hoverRowEmphasis)
                .foregroundStyle(.primary)

            Text(Formatters.formatYearMonthDayMinute(lastPrompt.completedAt))
                .font(MenuTypography.hoverCaptionEmphasis.monospacedDigit())
                .foregroundStyle(.secondary)

            UsageMetricHoverSummaryView(
                title: "",
                usage: lastPrompt.usage,
                showPromptCount: false
            )
        }
    }
}
