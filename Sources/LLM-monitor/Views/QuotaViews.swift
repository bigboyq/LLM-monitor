import SwiftUI
import AppKit

// MARK: - ChatGPT Plan 专用行

/// ChatGPT Plan：模型名 hover 看 Last Prompt，各 API 用量窗口 hover 看本地 token 明细
struct ChatGPTPlanModelRow: View {
    let model: ModelQuota
    let usageDetails: CodexUsageDetails?
    let localSamples: [LocalTokenUsageSample]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let lastPrompt {
                HoverInfoRow {
                    QuotaWindowTitle(
                        title: model.displayName,
                        tint: tint,
                        weeklyEquivalentMultiplier: hasPrimaryWindow && hasSecondaryWindow ? 6 : nil,
                        primaryLabel: primaryLabel
                    )
                } detail: {
                    LastPromptHoverSummaryView(lastPrompt: lastPrompt)
                }
            } else {
                QuotaWindowTitle(
                    title: model.displayName,
                    tint: tint,
                    weeklyEquivalentMultiplier: hasPrimaryWindow && hasSecondaryWindow ? 6 : nil,
                    primaryLabel: primaryLabel
                )
            }

            if hasPrimaryWindow && hasSecondaryWindow {
                QuotaCombinedUsageRow(
                    model: model,
                    primaryLabel: primaryLabel,
                    secondaryLabel: secondaryLabel,
                    primaryUsage: primaryUsage,
                    secondaryUsage: secondaryUsage,
                    tint: tint,
                    weeklyEquivalentMultiplier: 6,
                    missingUsageIsLoading: true,
                    primaryCreditUsage: nil,
                    secondaryCreditUsage: nil
                )
            } else if hasPrimaryWindow {
                QuotaSingleUsageRow(
                    title: "ChatGPT Plan",
                    label: primaryLabel,
                    percent: model.intervalRemainingPercent,
                    resetsAt: model.intervalResetsAt,
                    usage: primaryUsage,
                    tint: tint,
                    missingUsageIsLoading: true,
                    creditUsage: nil,
                    timeRemainingFraction: model.intervalTimeRemainingFraction
                )
            } else if hasSecondaryWindow {
                QuotaSingleUsageRow(
                    title: "ChatGPT Plan",
                    label: secondaryLabel,
                    percent: model.weeklyRemainingPercent,
                    resetsAt: model.weeklyResetsAt,
                    usage: secondaryUsage,
                    tint: tint,
                    missingUsageIsLoading: true,
                    creditUsage: nil,
                    timeRemainingFraction: model.weeklyTimeRemainingFraction
                )
            } else {
                Text("额度窗口不可用")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var primaryLabel: String { Formatters.codexWindowLabel(seconds: model.intervalWindowSeconds) }
    private var secondaryLabel: String { Formatters.codexWindowLabel(seconds: model.weeklyWindowSeconds) }
    private var hasPrimaryWindow: Bool { model.hasIntervalWindow }
    private var hasSecondaryWindow: Bool { model.hasWeeklyWindow }

    private var primaryUsage: UsageMetricSummary? {
        let bounds = LocalUsageSummaryBuilder.windowBounds(
            resetsAt: model.intervalResetsAt,
            explicitWindowSeconds: model.intervalWindowSeconds,
            fallbackSeconds: 5 * 60 * 60
        )
        return merge(
            usageDetails?.primary,
            localUsage(start: bounds?.start, end: bounds?.end)
        )
    }

    private var secondaryUsage: UsageMetricSummary? {
        let bounds = LocalUsageSummaryBuilder.windowBounds(
            resetsAt: model.weeklyResetsAt,
            explicitWindowSeconds: model.weeklyWindowSeconds,
            fallbackSeconds: 7 * 24 * 60 * 60
        )
        return merge(
            usageDetails?.secondary,
            localUsage(start: bounds?.start, end: bounds?.end)
        )
    }

    private var lastPrompt: LastPromptUsage? {
        usageDetails?.lastPrompt ?? LocalUsageSummaryBuilder.lastPrompt(
            samples: localSamples,
            providerKind: .codexChatGpt,
            quotaModelName: model.modelName
        )
    }

    private func localUsage(start: Date?, end: Date?) -> UsageMetricSummary? {
        return LocalUsageSummaryBuilder.summary(
            samples: localSamples,
            providerKind: .codexChatGpt,
            quotaModelName: model.modelName,
            start: start,
            end: end
        )
    }

    private func merge(
        _ native: UsageMetricSummary?,
        _ openCode: UsageMetricSummary?
    ) -> UsageMetricSummary? {
        switch (native, openCode) {
        case let (native?, openCode?): return native + openCode
        case let (value?, nil), let (nil, value?): return value
        case (nil, nil): return nil
        }
    }
}

/// ChatGPT 重置卡：默认只显示数量和最早过期时间，hover 再看每张卡
struct CompactResetCreditsRow: View {
    let resets: ResetCreditsInfo
    /// provider 的 background 刷新间隔（秒）。
    var refreshIntervalSeconds: Int = 300

    /// R3: reset credits 的实际刷新周期。reset credits 只在 .full 抓取，而 scheduler
    /// 每 N 个 background 才补一次 full，所以真实周期 = N × background 间隔。
    /// 过期判定基于这个周期（3×），否则会在两次 full 之间持续误报。
    private var resetCreditsRefreshPeriod: TimeInterval {
        TimeInterval(refreshIntervalSeconds) * TimeInterval(ProviderRefreshScheduler.periodicFullEveryNDefault)
    }

    private var isStale: Bool {
        resets.isStale(now: Date(), refreshIntervalSeconds: resetCreditsRefreshPeriod)
    }

    var body: some View {
        HoverInfoRow {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(summaryColor)

                    Text("重置卡数量：\(resets.availableCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(summaryColor)
                }

                Spacer(minLength: 8)

                if isStale {
                    // R3: reset credits 子接口失败或数据过旧，显示过期提示（不只靠透明度/颜色）。
                    HStack(spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(staleText)
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .lineLimit(1)
                    }
                    .foregroundStyle(.orange)
                    .help(staleHelp)
                }

                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(expiryText)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 2)
        } detail: {
            VStack(alignment: .leading, spacing: 8) {
                Text("可用重置卡")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)

                if availableEntries.isEmpty {
                    Text("暂无可用重置卡")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(availableEntries.enumerated()), id: \.offset) { _, entry in
                        CreditEntryRow(entry: entry)
                    }
                }
            }
        }
    }

    private var availableEntries: [ResetCreditEntry] {
        resets.entries
            .filter { $0.status.lowercased() == "available" }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (l?, r?):
                    return l < r
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.id < rhs.id
                }
            }
    }

    private var expiryText: String {
        guard let nearestExpiry = resets.nearestExpiry else { return "—" }
        return Formatters.formatMonthDayMinute(nearestExpiry)
    }

    /// R3: 过期文案——"可能过期 · 上次更新 HH:mm"；无 fetchedAt 时不带时间。
    private var staleText: String {
        if let fetchedAt = resets.fetchedAt {
            return "可能过期 · 上次更新 \(Formatters.formatClock(fetchedAt))"
        }
        return "可能过期"
    }

    private var staleHelp: String {
        if resets.lastAttemptFailed {
            return "最近一次抓取 reset credits 失败，显示的是上次成功的数据"
        }
        return "reset credits 数据已较久未更新，可能已过期"
    }

    private var summaryColor: Color {
        if resets.availableCount == 0 { return .red }
        if resets.availableCount == 1 { return .orange }
        return .green
    }
}

/// 一条可用 reset credit：过期时间 + 剩余时间
struct CreditEntryRow: View {
    let entry: ResetCreditEntry

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 5, height: 5)

            if let expiresAt = entry.expiresAt {
                Text(Formatters.formatYearMonthDayMinute(expiresAt))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)

                Text(Formatters.formatRelativeShort(from: expiresAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("过期时间未知")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - 通用 quota 行

/// 将短周期与周额度收进同一条：分段只表达等价配额比例，不把两种窗口的百分比相加。
struct CombinedQuotaWindowRow: View {
    let model: ModelQuota
    let primaryLabel: String
    let tint: Color
    let weeklyEquivalentMultiplier: Int
    let providerKind: ProviderKind
    let localSamples: [LocalTokenUsageSample]
    /// 额度窗口 hover 统计排除的时间窗口（GLM 闲时任务不消耗积分）。
    var excludeWindows: [GlmOffPeakWindow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let lastPrompt, shouldShowLastPrompt {
                HoverInfoRow {
                    title
                } detail: {
                    LastPromptHoverSummaryView(lastPrompt: lastPrompt)
                }
            } else {
                title
            }

            if model.hasIntervalWindow, model.hasWeeklyWindow {
                QuotaCombinedUsageRow(
                    model: model,
                    primaryLabel: primaryLabel,
                    secondaryLabel: "周",
                    primaryUsage: primaryUsage,
                    secondaryUsage: weeklyUsage,
                    tint: tint,
                    weeklyEquivalentMultiplier: weeklyEquivalentMultiplier,
                    missingUsageIsLoading: false,
                    primaryCreditUsage: intervalCreditUsage,
                    secondaryCreditUsage: weeklyCreditUsage,
                    offPeakUsage: todayOffPeakUsage
                )
            } else if model.hasIntervalWindow {
                QuotaSingleUsageRow(
                    title: model.displayName,
                    label: primaryLabel,
                    percent: model.intervalRemainingPercent,
                    resetsAt: model.intervalResetsAt,
                    usage: primaryUsage,
                    tint: tint,
                    missingUsageIsLoading: false,
                    creditUsage: intervalCreditUsage,
                    timeRemainingFraction: nil
                )
            } else if model.hasWeeklyWindow {
                QuotaSingleUsageRow(
                    title: model.displayName,
                    label: "周",
                    percent: model.weeklyRemainingPercent,
                    resetsAt: model.weeklyResetsAt,
                    usage: weeklyUsage,
                    tint: tint,
                    missingUsageIsLoading: false,
                    creditUsage: weeklyCreditUsage,
                    timeRemainingFraction: model.weeklyTimeRemainingFraction
                )
            } else {
                Text("额度窗口不可用")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: some View {
        QuotaWindowTitle(
            title: model.displayName,
            tint: tint,
            weeklyEquivalentMultiplier: model.hasIntervalWindow && model.hasWeeklyWindow
                ? weeklyEquivalentMultiplier
                : nil,
            primaryLabel: primaryLabel
        )
    }

    private var shouldShowLastPrompt: Bool {
        let name = model.modelName.lowercased()
        let antigravityGroupNames = Set(AntigravityModelKind.allCases.map(\.rawValue))
        return (providerKind == .minimaxTokenPlan && name == "general")
            || (providerKind == .antigravity && antigravityGroupNames.contains(name))
    }

    /// GLM 今日闲时（off-peak）任务 token 用量，单独展示在额度窗口 hover 底部。
    /// 只取**今日**明确属于 offpeak provider 的 native ZCode 样本；旧缓存缺少来源
    /// 字段时回退到 `excludeWindows`。闲时任务真实消耗但不消耗 Coding Plan 积分，
    /// 所以 5h / 周窗口统计排除它，这里单独列出。
    /// OpenCode 合并样本（promptID 带 `opencode:` 前缀）是正常消耗，不算闲时。
    private var todayOffPeakUsage: UsageMetricSummary? {
        LocalUsageSummaryBuilder.offPeakTodaySummary(
            samples: localSamples,
            providerKind: providerKind,
            quotaModelName: model.modelName,
            offPeakWindows: excludeWindows
        )
    }

    private var lastPrompt: LastPromptUsage? {
        LocalUsageSummaryBuilder.lastPrompt(
            samples: localSamples,
            providerKind: providerKind,
            quotaModelName: model.modelName
        )
    }

    private var primaryUsage: UsageMetricSummary? {
        let bounds = LocalUsageSummaryBuilder.windowBounds(
            resetsAt: model.intervalResetsAt,
            explicitWindowSeconds: model.intervalWindowSeconds,
            fallbackSeconds: primaryFallbackSeconds
        )
        return LocalUsageSummaryBuilder.summary(
            samples: localSamples,
            providerKind: providerKind,
            quotaModelName: model.modelName,
            start: bounds?.start,
            end: bounds?.end,
            excludeWindows: excludeWindows,
            excludeGlmOffPeak: providerKind == .glmCodingPlan
        )
    }

    private var weeklyUsage: UsageMetricSummary? {
        let bounds = LocalUsageSummaryBuilder.windowBounds(
            resetsAt: model.weeklyResetsAt,
            explicitWindowSeconds: model.weeklyWindowSeconds,
            fallbackSeconds: 7 * 24 * 60 * 60
        )
        return LocalUsageSummaryBuilder.summary(
            samples: localSamples,
            providerKind: providerKind,
            quotaModelName: model.modelName,
            start: bounds?.start,
            end: bounds?.end,
            excludeWindows: excludeWindows,
            excludeGlmOffPeak: providerKind == .glmCodingPlan
        )
    }

    private var primaryFallbackSeconds: TimeInterval {
        providerKind == .minimaxTokenPlan && model.modelName.lowercased() == "video"
            ? 24 * 60 * 60
            : 5 * 60 * 60
    }

    private var intervalCreditUsage: QuotaCountUsage? {
        creditUsage(total: model.intervalTotalCount, used: model.intervalUsageCount, status: model.intervalStatus)
    }

    private var weeklyCreditUsage: QuotaCountUsage? {
        creditUsage(total: model.weeklyTotalCount, used: model.weeklyUsageCount, status: model.weeklyStatus)
    }

    private func creditUsage(total: Int, used: Int, status: QuotaWindowStatus) -> QuotaCountUsage? {
        guard providerKind == .glmCodingPlan, status.isPresent, total > 0 else { return nil }
        return QuotaCountUsage(used: max(used, 0), total: total)
    }
}

/// Hover 详情里的单行窗口信息
struct HoverMetricLine: View {
    let label: String
    let percent: Double
    let resetsAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)

            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(summaryColor(for: percent))
                .frame(width: 40, alignment: .leading)

            if let resetsAt {
                Text(Formatters.formatMonthDayMinute(resetsAt))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.primary)

                Text(Formatters.formatRelativeShort(from: resetsAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("重置时间 —")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
    }
}

struct QuotaWindowTitle: View {
    let title: String
    let tint: Color
    let weeklyEquivalentMultiplier: Int?
    var primaryLabel: String = "5h"

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Spacer(minLength: 0)
            if let weeklyEquivalentMultiplier {
                Text("周倍率：\(weeklyEquivalentMultiplier)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(multiplierTooltipText(weeklyEquivalentMultiplier))
            }
        }
    }

    /// 解释"周倍率 N"的含义：N 段额度格 = "1 段当前主窗口 + (N-1) 段等价的周额度"，
    /// 方便用户理解"为什么是 5 段 / 6 段 / 10 段"。
    private func multiplierTooltipText(_ n: Int) -> String {
        let segments = max(n, 1)
        if segments <= 1 {
            return "周倍率：1（仅 1 个窗口,无分段）"
        }
        return "周倍率：\(segments)（分段条按 1 段当前\(primaryLabel) + \(segments - 1) 段等价的周额度渲染）"
    }
}

/// 数据列固定宽度，让所有重置时间从同一 x 位置开始。
private let quotaDataColumnWidth: CGFloat = 160

/// 统一的双窗口交互：
/// - 额度条 hover：额度窗口内 token 用量
/// - 百分比 + 重置时间行 hover：每个窗口的精确重置时间
struct QuotaCombinedUsageRow: View {
    let model: ModelQuota
    let primaryLabel: String
    let secondaryLabel: String
    let primaryUsage: UsageMetricSummary?
    let secondaryUsage: UsageMetricSummary?
    let tint: Color
    let weeklyEquivalentMultiplier: Int
    let missingUsageIsLoading: Bool
    let primaryCreditUsage: QuotaCountUsage?
    let secondaryCreditUsage: QuotaCountUsage?
    /// GLM 今日闲时（off-peak）任务 token 用量（不消耗积分）。非 GLM 传 nil。
    var offPeakUsage: UsageMetricSummary? = nil

    var body: some View {
        let bindingReset = EquivalentQuotaAllocation.bindingResetDate(
            primaryFraction: model.intervalRemainingPercent / 100.0,
            weeklyFraction: model.weeklyRemainingPercent / 100.0,
            primaryResetsAt: model.intervalResetsAt,
            weeklyResetsAt: model.weeklyResetsAt,
            segments: weeklyEquivalentMultiplier
        )

        VStack(alignment: .leading, spacing: 6) {
            HoverInfoRow {
                SegmentedQuotaProgressBar(
                    primaryFraction: model.intervalRemainingPercent / 100.0,
                    weeklyFraction: model.weeklyRemainingPercent / 100.0,
                    tint: tint,
                    segments: weeklyEquivalentMultiplier,
                    height: 8,
                    timeRemainingFraction: model.weeklyTimeRemainingFraction
                )
                .frame(maxWidth: .infinity)
                .help(segmentedBarTooltipText(segments: weeklyEquivalentMultiplier, hasTriangle: model.weeklyTimeRemainingFraction != nil))
            } detail: {
                QuotaUsageWindowsHoverView(
                    title: "\(model.displayName) 额度窗口用量",
                    primaryLabel: primaryLabel,
                    primaryUsage: primaryUsage,
                    primaryCreditUsage: primaryCreditUsage,
                    secondaryLabel: secondaryLabel,
                    secondaryUsage: secondaryUsage,
                    secondaryCreditUsage: secondaryCreditUsage,
                    weeklyEquivalentMultiplier: weeklyEquivalentMultiplier,
                    hasSecondaryWindow: true,
                    missingUsageIsLoading: missingUsageIsLoading,
                    offPeakUsage: offPeakUsage
                )
            }

            HoverInfoRow {
                CombinedQuotaMetadataLine(
                    primaryLabel: primaryLabel,
                    primaryPercent: model.intervalRemainingPercent,
                    primaryTimeFraction: model.intervalTimeRemainingFraction,
                    secondaryLabel: secondaryLabel,
                    secondaryPercent: model.weeklyRemainingPercent,
                    secondaryTimeFraction: model.weeklyTimeRemainingFraction,
                    resetsAt: bindingReset
                )
            } detail: {
                QuotaWindowsHoverView(
                    title: model.displayName,
                    weeklyEquivalentMultiplier: weeklyEquivalentMultiplier,
                    primaryLabel: primaryLabel,
                    primaryPercent: model.intervalRemainingPercent,
                    primaryResetsAt: model.intervalResetsAt,
                    weeklyPercent: model.weeklyRemainingPercent,
                    weeklyResetsAt: model.weeklyResetsAt,
                    secondaryLabel: secondaryLabel
                )
            }
        }
    }
}

struct QuotaSingleUsageRow: View {
    let title: String
    let label: String
    let percent: Double
    let resetsAt: Date?
    let usage: UsageMetricSummary?
    let tint: Color
    let missingUsageIsLoading: Bool
    let creditUsage: QuotaCountUsage?
    /// 顶部红三角位置 (0=即将过期, 1=刚重置)。nil = 不画。5h 窗口不传。
    let timeRemainingFraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HoverInfoRow {
                SegmentedQuotaProgressBar(
                    primaryFraction: percent / 100.0,
                    weeklyFraction: percent / 100.0,
                    tint: tint,
                    segments: 1,
                    height: 8,
                    timeRemainingFraction: timeRemainingFraction
                )
                .frame(maxWidth: .infinity)
            } detail: {
                QuotaUsageWindowsHoverView(
                    title: "\(title) 额度窗口用量",
                    primaryLabel: label,
                    primaryUsage: usage,
                    primaryCreditUsage: creditUsage,
                    secondaryLabel: "",
                    secondaryUsage: nil,
                    secondaryCreditUsage: nil,
                    weeklyEquivalentMultiplier: nil,
                    hasSecondaryWindow: false,
                    missingUsageIsLoading: missingUsageIsLoading
                )
            }

            HoverInfoRow {
                SingleQuotaMetadataLine(
                    label: label,
                    percent: percent,
                    resetsAt: resetsAt
                )
            } detail: {
                SingleQuotaWindowHoverView(
                    title: title,
                    label: label,
                    percent: percent,
                    resetsAt: resetsAt
                )
            }
        }
    }
}

private struct CombinedQuotaMetadataLine: View {
    let primaryLabel: String
    let primaryPercent: Double
    let primaryTimeFraction: Double?
    let secondaryLabel: String
    let secondaryPercent: Double
    let secondaryTimeFraction: Double?
    let resetsAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                quotaValue(label: primaryLabel, percent: primaryPercent, timeFraction: primaryTimeFraction)
                quotaValue(label: secondaryLabel, percent: secondaryPercent, timeFraction: secondaryTimeFraction)
            }
            .frame(width: quotaDataColumnWidth, alignment: .leading)
            ResetTimeSummary(resetsAt: resetsAt)
        }
    }

    private func quotaValue(label: String, percent: Double, timeFraction: Double?) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(Color.primaryLabel)
            Text("\(Int(percent.rounded()))%")
                .foregroundStyle(summaryColor(for: percent, timeFraction: timeFraction))
                .frame(width: 32, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold).monospacedDigit())
    }
}

private struct SingleQuotaMetadataLine: View {
    let label: String
    let percent: Double
    let resetsAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(label)
                    .foregroundStyle(Color.primaryLabel)
                Text("\(Int(percent.rounded()))%")
                    .foregroundStyle(summaryColor(for: percent))
                    .frame(width: 32, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .frame(width: quotaDataColumnWidth, alignment: .leading)
            ResetTimeSummary(resetsAt: resetsAt)
        }
    }
}

private struct ResetTimeSummary: View {
    let resetsAt: Date?

    var body: some View {
        if let resetsAt {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                Text(Formatters.formatMonthDayMinute(resetsAt))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                Text("(\(Formatters.formatResetSuffix(from: resetsAt)))")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.primaryLabel)
        } else {
            Text("—")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Tooltip helpers

/// 进度条 hover 说明：分段构成 + 红三角语义。
///
/// - 第一格（亮色）= 当前 5h 窗口剩余
/// - 后续 N-1 格（72% 不透明）= 等价的周额度剩余
/// - 顶部红三角 ▼ = 周 reset 进度（0 = 即将过期, 1 = 刚重置）,5h 进度条不画
func segmentedBarTooltipText(segments: Int, hasTriangle: Bool) -> String {
    let n = max(segments, 1)
    let parts: String
    if n == 1 {
        parts = "单一窗口进度"
    } else {
        parts = "第 1 格 = 当前 5h 剩余;后续 \(n - 1) 格 = 等价的周额度剩余"
    }
    let triangle: String
    if hasTriangle {
        triangle = "\n顶部 ▼ = 周 reset 进度（0 = 即将过期, 1 = 刚重置）"
    } else {
        triangle = ""
    }
    return "分段条:\n\(parts)。\(triangle)"
}

// MARK: - DeepSeek API 余额专用行

/// DeepSeek API 余额专用展示行：不展示 5h 配额条与 100% 百分比，展示真实资金余额与结构。
struct DeepseekBalanceRow: View {
    let model: ModelQuota
    let planLabel: String?
    /// R7: 余额明细由结构化字段本地格式化，不再解析 accountEmail 预格式化串。
    let balanceDetail: DeepseekBalanceDetail?
    let tint: Color
    let peakWindow: DeepseekPeakWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                    Text("API 账户余额")
                        .font(.system(size: 12, weight: .semibold))
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
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(toppedUpText)
                        Text(grantedText)
                            .font(.system(size: 10, weight: .medium))
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

                DeepseekPeakIndicatorView(window: peakWindow)
                    .layoutPriority(1)
            }
        }
        .padding(.vertical, 2)
    }
}
