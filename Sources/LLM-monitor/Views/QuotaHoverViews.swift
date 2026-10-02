import SwiftUI

// 额度窗口的 hover 明细视图族（QuotaWindowsHoverView / QuotaUsageWindowsHoverView /
// QuotaUsageWindowColumn / SingleQuotaWindowHoverView / HoverMetricLine /
// QuotaWindowsHoverPresentation）已随 menuLayout 死分支一起删除——它们唯一
// 的构造路径是被删的 QuotaCombinedUsageRow / QuotaSingleUsageRow。

struct UsageMetricHoverSummaryView: View {
    let title: String
    let usage: UsageMetricSummary
    let showPromptCount: Bool

    /// `input` 与 `cached`、`prompts` 与 `rounds` **恒**各占一行。
    ///
    /// 本视图有一处活的卡内宿主（`CombinedQuotaWindowRow.dockBlock` 里的
    /// `OffPeakUsageFootnote`，dock 浮层里确实渲染），另一处宿主
    /// `QuotaUsageWindowColumn` 只从已删除的 `QuotaCombinedUsageRow` /
    /// `QuotaSingleUsageRow` 来、已无渲染方；而两个渲染宿主都注入
    /// `.alwaysVisible`。两条判据已删除，分行固定下来（见 `ProviderCardLayout`）。

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(MenuTypography.hoverRowEmphasis)
                    .foregroundStyle(.primary)
            }

            if showPromptCount {
                // 拆行：prompts 和 rounds 各自一行，rounds 紧跟 prompts。
                metricLine(label: "prompts", value: Formatters.formatGroupedInt(usage.prompts))
                metricLine(label: "rounds", value: Formatters.formatGroupedInt(usage.rounds))
            } else {
                metricLine(label: "rounds", value: Formatters.formatGroupedInt(usage.rounds))
            }

            metricLine(label: "input", value: Formatters.formatTokenCountCompact(usage.uncachedInputTokens))
            metricLine(label: "cached", value: Formatters.formatTokenCountCompact(usage.cachedInputTokens))
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

