import SwiftUI

enum QuotaWindowsHoverPresentation {
    static func normalizedPercent(_ percent: Double) -> Double {
        guard percent.isFinite else { return 0 }
        return min(max(percent, 0), 100)
    }

    static func bindingConstraintText(
        primaryLabel: String,
        weeklyIsBinding: Bool,
        weeklyEquivalentMultiplier: Int,
        weeklyLabel: String
    ) -> String {
        if weeklyIsBinding {
            return "主行 reset time 取\(weeklyLabel)（\(primaryLabel)还有余量但周额度已先耗尽）。顶部红三角 ▼ = 周 reset 进度,与主行 reset 含义不同"
        }
        return "主行 reset time 取\(primaryLabel)窗口（\(primaryLabel)是 binding constraint,比周额度先耗尽）。顶部红三角 ▼ = 周 reset 进度,仅作时间标记"
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
                .font(.system(size: 11, weight: .semibold))
            Text("周倍率：\(weeklyEquivalentMultiplier)（等价额度分段）")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(effectiveAvailabilityText)
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(effectivePrimaryPercent < safePrimaryPercent ? .orange : .secondary)
            Text(
                QuotaWindowsHoverPresentation.bindingConstraintText(
                    primaryLabel: primaryLabel,
                    weeklyIsBinding: weeklyIsBinding,
                    weeklyEquivalentMultiplier: weeklyEquivalentMultiplier,
                    weeklyLabel: secondaryLabel
                )
            )
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
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

    private var weeklyIsBinding: Bool {
        let weeklyUnits = (safeWeeklyPercent / 100.0) * Double(max(weeklyEquivalentMultiplier, 1))
        return weeklyUnits < (safePrimaryPercent / 100.0)
    }

    private var effectivePrimaryPercent: Double {
        EquivalentQuotaAllocation.effectivePrimaryFraction(
            primaryFraction: safePrimaryPercent / 100.0,
            weeklyFraction: safeWeeklyPercent / 100.0,
            segments: weeklyEquivalentMultiplier
        ) * 100
    }

    private var effectiveAvailabilityText: String {
        let percentage = Int(effectivePrimaryPercent.rounded())
        if effectivePrimaryPercent < safePrimaryPercent {
            return "当前 \(primaryLabel) 实际可用 \(percentage)%（受周额度限制）"
        }
        return "当前 \(primaryLabel) 实际可用 \(percentage)%"
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
                .font(.system(size: 11, weight: .semibold))
            if let weeklyEquivalentMultiplier {
                Text("周倍率：\(weeklyEquivalentMultiplier)（本地会话统计）")
                    .font(.system(size: 9))
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
                        .font(.system(size: 9))
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
                .font(.system(size: 11).monospacedDigit())
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
                    .font(.system(size: 10))
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
                .font(.system(size: 11, weight: .semibold))
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
                    .font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 11).monospacedDigit())
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
        .font(.system(size: 11).monospacedDigit())
    }
}

struct LastPromptHoverSummaryView: View {
    let lastPrompt: LastPromptUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last Prompt")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)

            Text(Formatters.formatYearMonthDayMinute(lastPrompt.completedAt))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)

            UsageMetricHoverSummaryView(
                title: "",
                usage: lastPrompt.usage,
                showPromptCount: false
            )
        }
    }
}
