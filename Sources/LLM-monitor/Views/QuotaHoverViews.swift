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
    /// 恒为**并排**，不再按 `hoverRevealMode` 分支。
    ///
    /// 原先这里判 `ProviderCardLayout.laysWindowDetailsSideBySide(mode:)`（`alwaysVisible`
    /// 即并排），但本视图只从 `QuotaCombinedUsageRow` / `QuotaSingleUsageRow` 构造，
    /// 那两个视图只出现在 model 行的 `menuLayout` 里（dock 走的是
    /// `ModelQuotaDockBlock` + `QuotaBarWithMetadata`）——于是 `alwaysVisible` 传不到
    /// 这里，判据恒 false，并排那一支是**跑不到的死分支**，堆叠那一支才是实际行为。
    ///
    /// 现在按产品决定统一成并排：5h 与周讲的是"同一个额度在两个时间尺度上的消耗"，
    /// 并排才能左右对齐、横向比较同一行；堆着的话读者得靠上下位置去对齐找同一栏。
    /// 宽度不是问题——`HoverPanelController` 的面板宽度取
    /// `min(max(fitting.width, 180), …)`，按内容自适应；7 天图表那张 420pt 的 hover
    /// 早就比卡片（360 − 2×12 = 336pt）宽了。

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

            // 5h 与周各占一栏：两栏内容都是"百分比 + 重置时间"的同一形状，
            // 并排后一眼能横向比较，竖排时只能靠上下位置去对齐找同一栏。
            HStack(alignment: .top, spacing: 16) {
                HoverMetricLine(label: primaryLabel, percent: safePrimaryPercent, resetsAt: primaryResetsAt)
                HoverMetricLine(label: secondaryLabel, percent: safeWeeklyPercent, resetsAt: weeklyResetsAt)
            }
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
    /// 恒为**并排**（`hasSecondaryWindow` 为假时单列）。
    ///
    /// 原先这里判 `ProviderCardLayout.laysWindowDetailsSideBySide(mode:)`，但该谓词
    /// 恒为 false（构造链只经过两个 model 行的 `menuLayout`，传不到 dock 的
    /// `.alwaysVisible`），跑的是堆叠分支。现在按产品决定统一成并排。
    ///
    /// 这里比 `QuotaWindowsHoverView` 多一个 `hasSecondaryWindow` 判据、那边没有——
    /// 这个差异原先被死分支掩盖着：并排真正落地才暴露出来"单窗口模型并排会多出
    /// 一栏空位"。现在这一处判据保留（单窗口本来就只有一个窗口），两边从此同构。

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(MenuTypography.hoverRowEmphasis)
            if let weeklyEquivalentMultiplier {
                Text("周倍率：\(weeklyEquivalentMultiplier)（本地会话统计）")
                    .font(MenuTypography.hoverFootnote)
                    .foregroundStyle(.secondary)
            }

            // 5h / 周两栏并排：它们是"同一个额度在两个时间尺度上的消耗"，
            // 并排才能横向对比；竖排时读者要在两段之间来回跳着找同一栏。
            // 单窗口模型（`hasSecondaryWindow` 为假）只有一个窗口，并排会多出一栏
            // 空位——所以这一处保留了判据，恒并排指的是"有两个窗口时"。
            if hasSecondaryWindow {
                HStack(alignment: .top, spacing: 16) {
                    usageSection(
                        label: primaryLabel,
                        usage: primaryUsage,
                        creditUsage: primaryCreditUsage
                    )
                    usageSection(
                        label: secondaryLabel,
                        usage: secondaryUsage,
                        creditUsage: secondaryCreditUsage
                    )
                }
            } else {
                usageSection(label: primaryLabel, usage: primaryUsage, creditUsage: primaryCreditUsage)
            }

            if let offPeakUsage {
                Divider().opacity(0.45)
                OffPeakUsageFootnote(usage: offPeakUsage)
            }
        }
    }

    @ViewBuilder
    private func usageSection(
        label: String,
        usage: UsageMetricSummary?,
        creditUsage: QuotaCountUsage?
    ) -> some View {
        QuotaUsageWindowColumn(
            label: label,
            usage: usage,
            creditUsage: creditUsage,
            missingUsageIsLoading: missingUsageIsLoading
        )
    }
}

/// 一个额度窗口的用量明细：hover 浮层里的一段（菜单与 dock 的浮层共用同一份
/// 渲染）。dock 详情浮层原先也直接铺它，现在那边只留额度条——用量明细在菜单的
/// hover 浮层里看。
struct QuotaUsageWindowColumn: View {
    let label: String
    let usage: UsageMetricSummary?
    let creditUsage: QuotaCountUsage?
    var missingUsageIsLoading: Bool = false

    /// 有数据与空态**共用**的标题。两边必须逐字相同：标题宽度决定正文从哪一行开始，
    /// 一字之差就会让"没数据"读成另一种排版，而不是同一段里的一个空态。
    private var columnTitle: String { "\(label) 本地 token 用量" }

    var body: some View {
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
                    title: columnTitle,
                    usage: usage,
                    showPromptCount: true
                )
            } else {
                // 空态**保留标题**，只把正文换成一句话。
                //
                // 此前空态直接渲染成一句"5h 额度窗口内暂无本地 token 记录"，没有
                // 标题行，于是正文和别人的标题挤在同一高度上，读起来像少了一段，
                // 而不是像"这一段没数据"。
                VStack(alignment: .leading, spacing: 5) {
                    Text(columnTitle)
                        .font(MenuTypography.hoverRowEmphasis)
                        .foregroundStyle(.primary)

                    HStack(spacing: 6) {
                        if missingUsageIsLoading {
                            ProgressView().controlSize(.mini)
                        }
                        Text(missingUsageIsLoading ? "用量生成中…" : "额度窗口内暂无本地数据")
                            .font(MenuTypography.hoverCaption)
                            .foregroundStyle(.secondary)
                    }
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

    /// `input` 与 `cached`、`prompts` 与 `rounds` **恒**各占一行。
    ///
    /// 判据 `ProviderCardLayout.splitsCachedInputRow(mode:)` /
    /// `splitsRoundsRow(mode:)` 在 `.alwaysVisible` 下恒为真：本视图有一处活的
    /// 卡内宿主（`CombinedQuotaWindowRow.dockBlock` 里的 `OffPeakUsageFootnote`，
    /// dock 浮层里确实渲染），另一处宿主 `QuotaUsageWindowColumn` 只从 model 行的
    /// `menuLayout` 那条路来、已无渲染方；而两个渲染宿主都注入 `.alwaysVisible`。
    /// 两条判据已删除，分行固定下来（见 `ProviderCardLayout`）。

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
