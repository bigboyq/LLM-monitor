import SwiftUI
import AppKit

// MARK: - ChatGPT Plan 专用行

/// ChatGPT Plan：模型名 hover 看 Last Prompt，各 API 用量窗口 hover 看本地 token 明细
struct ChatGPTPlanModelRow: View {
    let model: ModelQuota
    let usageDetails: CodexUsageDetails?
    let localSamples: [LocalTokenUsageSample]
    let tint: Color
    /// dock 详情浮层把进度条提到标题上方；菜单保持原顺序（见 `CombinedQuotaWindowRow`）。
    @Environment(\.hoverRevealMode) private var revealMode

    private var liftsProgressBar: Bool {
        ProviderCardLayout.liftsProgressBar(mode: revealMode)
    }

    var body: some View {
        if isDockLayout {
            dockBlock
        } else {
            menuLayout
        }
    }

    private var isDockLayout: Bool {
        ProviderCardLayout.liftsProgressBar(mode: revealMode)
    }

    // MARK: dock：条 → 元信息行 → 标题 → 三列明细（与通用 model 行同构）

    /// dock 侧没有标题行（见 `CombinedQuotaWindowRow.dockBlock` 的理由）：
    /// 条 + 三列已经自解释，模型名是冗余的。菜单侧仍然用它当那行的名字。
    @ViewBuilder
    private var dockBlock: some View {
        if hasPrimaryWindow && hasSecondaryWindow {
            ModelQuotaDockBlock(
                bar: QuotaBarWithMetadata(
                    model: model,
                    primaryLabel: primaryLabel,
                    secondaryLabel: secondaryLabel,
                    weeklyEquivalentMultiplier: 6,
                    tint: tint
                ),
                columns: QuotaDetailColumns(
                    lastPrompt: lastPrompt,
                    primaryLabel: primaryLabel,
                    primaryUsage: primaryUsage,
                    primaryCreditUsage: nil,
                    secondaryLabel: secondaryLabel,
                    secondaryUsage: secondaryUsage,
                    secondaryCreditUsage: nil,
                    hasSecondaryWindow: true,
                    missingUsageIsLoading: true
                ),
                footnote: EmptyView()
            )
        } else if hasPrimaryWindow {
            ModelQuotaDockBlock(
                bar: QuotaBarWithMetadata(
                    model: model,
                    primaryLabel: primaryLabel,
                    secondaryLabel: "",
                    weeklyEquivalentMultiplier: 6,
                    tint: tint
                ),
                columns: QuotaDetailColumns(
                    lastPrompt: lastPrompt,
                    primaryLabel: primaryLabel,
                    primaryUsage: primaryUsage,
                    primaryCreditUsage: nil,
                    secondaryLabel: "",
                    secondaryUsage: nil,
                    secondaryCreditUsage: nil,
                    hasSecondaryWindow: false,
                    missingUsageIsLoading: true
                ),
                footnote: EmptyView()
            )
        } else if hasSecondaryWindow {
            ModelQuotaDockBlock(
                bar: QuotaBarWithMetadata(
                    model: model,
                    primaryLabel: secondaryLabel,
                    secondaryLabel: "",
                    weeklyEquivalentMultiplier: 6,
                    tint: tint
                ),
                columns: QuotaDetailColumns(
                    lastPrompt: lastPrompt,
                    primaryLabel: secondaryLabel,
                    primaryUsage: secondaryUsage,
                    primaryCreditUsage: nil,
                    secondaryLabel: "",
                    secondaryUsage: nil,
                    secondaryCreditUsage: nil,
                    hasSecondaryWindow: false,
                    missingUsageIsLoading: true
                ),
                footnote: EmptyView()
            )
        } else {
            Text("额度窗口不可用")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var title: some View {
        QuotaWindowTitle(
            title: model.displayName,
            tint: tint,
            weeklyEquivalentMultiplier: hasPrimaryWindow && hasSecondaryWindow ? 6 : nil,
            primaryLabel: primaryLabel
        )
    }

    // MARK: 菜单：标题在上，条与元信息行各自 hover

    @ViewBuilder
    private var menuLayout: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let lastPrompt {
                HoverInfoRow {
                    title
                } detail: {
                    LastPromptHoverSummaryView(lastPrompt: lastPrompt)
                }
            } else {
                title
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
        return Self.preferUsageDetails(
            usageDetails?.primary,
            localUsage(start: bounds?.start, end: bounds?.end),
            externalUsage: openCodeUsage(start: bounds?.start, end: bounds?.end)
        )
    }

    private var secondaryUsage: UsageMetricSummary? {
        let bounds = LocalUsageSummaryBuilder.windowBounds(
            resetsAt: model.weeklyResetsAt,
            explicitWindowSeconds: model.weeklyWindowSeconds,
            fallbackSeconds: 7 * 24 * 60 * 60
        )
        return Self.preferUsageDetails(
            usageDetails?.secondary,
            localUsage(start: bounds?.start, end: bounds?.end),
            externalUsage: openCodeUsage(start: bounds?.start, end: bounds?.end)
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

    private func openCodeUsage(start: Date?, end: Date?) -> UsageMetricSummary? {
        Self.openCodeUsageSummary(
            samples: localSamples,
            quotaModelName: model.modelName,
            start: start,
            end: end
        )
    }

    static func openCodeUsageSummary(
        samples: [LocalTokenUsageSample],
        quotaModelName: String,
        start: Date?,
        end: Date?
    ) -> UsageMetricSummary? {
        let prefix = "opencode:\(OpencodeLocalUsage.openAIProviderID):"
        let openCodeSamples = samples.filter { $0.promptID.hasPrefix(prefix) }
        guard openCodeSamples.isEmpty == false else { return nil }
        return LocalUsageSummaryBuilder.summary(
            samples: openCodeSamples,
            providerKind: .codexChatGpt,
            quotaModelName: quotaModelName,
            start: start,
            end: end
        )
    }

    /// `usageDetails` 已由同一批 Codex session samples 聚合而来；不能再与
    /// `localUsage` 相加，否则窗口内的 input/cache/output 会全部重复计算。
    /// 有详情时仅追加已启用的 OpenCode 来源；详情尚未生成时从合并 samples 回退。
    static func preferUsageDetails(
        _ usageDetails: UsageMetricSummary?,
        _ localFallback: @autoclosure () -> UsageMetricSummary?,
        externalUsage: @autoclosure () -> UsageMetricSummary? = nil
    ) -> UsageMetricSummary? {
        guard let usageDetails else { return localFallback() }
        guard let externalUsage = externalUsage() else { return usageDetails }
        return usageDetails + externalUsage
    }
}

/// ChatGPT 重置卡：默认只显示数量和最早过期时间，hover 再看每张卡
struct CompactResetCreditsRow: View {
    let resets: ResetCreditsInfo
    /// provider 的 background 刷新间隔（秒）。
    var refreshIntervalSeconds: Int = 300
    /// 是否把"每张卡"的明细挂在 hover 上。
    ///
    /// dock 详情浮层传 false：那个浮层**不接受鼠标事件**，`HoverInfoRow` 在
    /// `alwaysVisible` 下又总会展开，于是每张卡的明细变成常驻——既占高度
    /// 又把折叠态真正该给的信息（总数 + 最近一张到期时间）挤成了两行里
    /// 夹着六行明细。传 false 就只留折叠态那一句，与菜单形态一致。
    var revealsDetail: Bool = true

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
        if revealsDetail {
            HoverInfoRow {
                summary
            } detail: {
                detail
            }
        } else {
            summary
        }
    }

    /// 折叠态：总数 + 最近一张的到期时间（外加过期提示）。
    private var summary: some View {
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
    }

    /// 展开态：每张卡的明细。菜单侧 hover 出来，dock 侧不画（见 `revealsDetail`）。
    private var detail: some View {
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
    /// dock 详情浮层把进度条提到标题上方；菜单保持原顺序。
    @Environment(\.hoverRevealMode) private var revealMode

    private var liftsProgressBar: Bool {
        ProviderCardLayout.liftsProgressBar(mode: revealMode)
    }

    var body: some View {
        if isDockLayout {
            dockBlock
        } else {
            menuLayout
        }
    }

    private var isDockLayout: Bool {
        ProviderCardLayout.liftsProgressBar(mode: revealMode)
    }

    // MARK: dock：条 + 元信息行 → 三列明细

    /// 这里**没有标题行**。原来有 `QuotaWindowTitle`（模型名 + 周倍率），
    /// 但条下面紧跟着的三列第一列标题就是"5h 本地 token 用量"、第三列就是
    /// "周 本地 token 用量"——哪个 model 谁的条，读者靠位置就已经知道了，
    /// 再加一行名称只是把同样的信息多写一遍。
    ///
    /// 元信息行（`5h 100% 周 …`）也只出现一次：它此前在额度行本身和
    /// `QuotaWindowsHoverView` 展开后的窗口指标行各一份，dock 侧两处都在屏上。
    @ViewBuilder
    private var dockBlock: some View {
        if model.hasIntervalWindow, model.hasWeeklyWindow {
            ModelQuotaDockBlock(
                bar: QuotaBarWithMetadata(
                    model: model,
                    primaryLabel: primaryLabel,
                    secondaryLabel: "周",
                    weeklyEquivalentMultiplier: weeklyEquivalentMultiplier,
                    tint: tint
                ),
                columns: QuotaDetailColumns(
                    lastPrompt: dockLastPrompt,
                    primaryLabel: primaryLabel,
                    primaryUsage: primaryUsage,
                    primaryCreditUsage: intervalCreditUsage,
                    secondaryLabel: "周",
                    secondaryUsage: weeklyUsage,
                    secondaryCreditUsage: weeklyCreditUsage,
                    hasSecondaryWindow: true,
                    missingUsageIsLoading: false
                ),
                footnote: offPeakFootnote
            )
        } else if model.hasIntervalWindow {
            ModelQuotaDockBlock(
                bar: QuotaBarWithMetadata(
                    model: model,
                    primaryLabel: primaryLabel,
                    secondaryLabel: "",
                    weeklyEquivalentMultiplier: weeklyEquivalentMultiplier,
                    tint: tint
                ),
                columns: QuotaDetailColumns(
                    lastPrompt: dockLastPrompt,
                    primaryLabel: primaryLabel,
                    primaryUsage: primaryUsage,
                    primaryCreditUsage: intervalCreditUsage,
                    secondaryLabel: "",
                    secondaryUsage: nil,
                    secondaryCreditUsage: nil,
                    hasSecondaryWindow: false,
                    missingUsageIsLoading: false
                ),
                footnote: offPeakFootnote
            )
        } else if model.hasWeeklyWindow {
            ModelQuotaDockBlock(
                bar: QuotaBarWithMetadata(
                    model: model,
                    primaryLabel: "周",
                    secondaryLabel: "",
                    weeklyEquivalentMultiplier: weeklyEquivalentMultiplier,
                    tint: tint
                ),
                columns: QuotaDetailColumns(
                    lastPrompt: dockLastPrompt,
                    primaryLabel: "周",
                    primaryUsage: weeklyUsage,
                    primaryCreditUsage: weeklyCreditUsage,
                    secondaryLabel: "",
                    secondaryUsage: nil,
                    secondaryCreditUsage: nil,
                    hasSecondaryWindow: false,
                    missingUsageIsLoading: false
                ),
                footnote: offPeakFootnote
            )
        } else {
            Text("额度窗口不可用")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    /// GLM 闲时用量：只有真有数据才占一行，没有就整个不渲染。
    @ViewBuilder
    private var offPeakFootnote: some View {
        if let todayOffPeakUsage {
            OffPeakUsageFootnote(usage: todayOffPeakUsage)
        }
    }

    /// 三列里的 Last Prompt。与菜单侧同一套门槛：不是每个 model 都值得挂一条。
    private var dockLastPrompt: LastPromptUsage? {
        shouldShowLastPrompt ? lastPrompt : nil
    }

    /// 重置倒计时取"先耗尽的那个"窗口的时间——与菜单那条元信息行同源。
    // MARK: 菜单：标题在上，条与元信息行各自 hover

    @ViewBuilder
    private var menuLayout: some View {
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
                .font(MenuTypography.dataLabel)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)

            Text(Formatters.formatQuotaPercent(percent))
                .font(MenuTypography.dataValue)
                .foregroundStyle(summaryColor(for: percent))
                .frame(width: 40, alignment: .leading)

            if let resetsAt {
                Text(Formatters.formatMonthDayMinute(resetsAt))
                    .font(MenuTypography.resetDate)
                    .foregroundStyle(.primary)

                Text(Formatters.formatRelativeShort(from: resetsAt))
                    .font(MenuTypography.timeSuffix)
                    .foregroundStyle(.secondary)
            } else {
                Text("重置时间 —")
                    .font(MenuTypography.hint)
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
                .font(MenuTypography.modelTitle)
                .foregroundStyle(tint)
            Spacer(minLength: 0)
            if let weeklyEquivalentMultiplier {
                Text("周倍率：\(weeklyEquivalentMultiplier)")
                    .font(MenuTypography.multiplier)
                    .foregroundStyle(.secondary)
                    .help(multiplierTooltipText(weeklyEquivalentMultiplier))
            }
        }
    }

    /// 解释"周倍率 N"的含义：精炼为面向普通用户的自然语言
    private func multiplierTooltipText(_ n: Int) -> String {
        let segments = max(n, 1)
        if segments <= 1 {
            return "周倍率：1（仅单窗口，无分段）"
        }
        return "额度结构：当前 \(primaryLabel) + 等价周额度（共 \(segments) 等份配额池）"
    }
}

/// 数据列宽度：双窗口数据列定宽 152pt 确保对齐，单窗口紧凑定宽 80pt 避免留白过大
private let quotaCombinedDataColumnWidth: CGFloat = 152
private let quotaSingleDataColumnWidth: CGFloat = 80

// MARK: - 进度条（裸视图）与它的 hover 明细

/// 双窗口 model 的分段进度条本体。
///
/// 与 hover 明细拆开是因为**排版权在父级**：dock 详情浮层里这条要排在
/// model 标题**之上**，而它的明细（5h / 周用量）在那边又被并进三列布局——
/// 菜单那条"条 + hover 弹明细"的结构整块搬不过去。
struct CombinedQuotaBar: View {
    let model: ModelQuota
    let tint: Color
    let weeklyEquivalentMultiplier: Int

    var body: some View {
        SegmentedQuotaProgressBar(
            primaryFraction: model.intervalRemainingPercent / 100.0,
            weeklyFraction: model.weeklyRemainingPercent / 100.0,
            tint: tint,
            segments: weeklyEquivalentMultiplier,
            height: 8,
            timeRemainingFraction: model.weeklyTimeRemainingFraction
        )
        .frame(maxWidth: .infinity)
        .help(QuotaBarTooltip.text(
            segments: weeklyEquivalentMultiplier,
            hasTriangle: model.weeklyTimeRemainingFraction != nil
        ))
    }
}

/// 单窗口 model 的进度条本体。
struct SingleQuotaBar: View {
    let percent: Double
    let tint: Color
    /// 顶部红三角位置 (0=即将过期, 1=刚重置)。nil = 不画。
    let timeRemainingFraction: Double?

    var body: some View {
        SegmentedQuotaProgressBar(
            primaryFraction: percent / 100.0,
            weeklyFraction: percent / 100.0,
            tint: tint,
            segments: 1,
            height: 8,
            timeRemainingFraction: timeRemainingFraction
        )
        .frame(maxWidth: .infinity)
    }
}

// MARK: - dock 详情浮层的 model 块

/// dock 详情浮层里一个 model 的整块：进度条 → 元信息行 → 标题 → 三列明细。
///
/// 菜单形态不走这里：那边是 `HoverInfoRow` 逐块折叠的原有结构（条在标题下、
/// 每块各自 hover）。这里把"全部就地展开"**收敛到一个视图**——条的次序、
/// 元信息行只留一份、三列的左右顺序，这些规则不该在两个 model 行里各写一遍，
/// 否则改一处漏一处，而漏了既不崩也不报错，只是浮层悄悄变高一截。
struct ModelQuotaDockBlock<Bar: View, Columns: View, Footnote: View>: View {
    let bar: Bar
    let columns: Columns
    /// 整行宽度的补充信息（GLM 今日闲时用量）。只有 GLM 传，ChatGPT 传 `EmptyView()`。
    ///
    /// 不给默认值：Swift 无法从默认属性值反推泛型参数，调用点漏写就成了
    /// "generic parameter could not be inferred" 这种与意图无关的编译错误。
    var footnote: Footnote

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            bar
            columns
            footnote
        }
    }
}

/// 一个 model 的「进度条 + 元信息行」。两者是同一份数字的两种画法（条是图形、
/// 行是文字），所以合成一个视图，必须贴在一起。
///
/// 它就坐在**该 model 自己的**三列明细正上方，不提到卡片头部：Antigravity 有
/// 两个 model，把两条条并到头部就得给每条加一个名称 label 才知道谁是谁，
/// 而有了 label 它和下面那行模型名就重了；各归各的则"条 ↔ 下面的三列"是紧邻的
/// 同一块，读者不用回头找对应关系。
struct QuotaBarWithMetadata: View {
    let model: ModelQuota
    let primaryLabel: String
    let secondaryLabel: String
    let weeklyEquivalentMultiplier: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if model.hasIntervalWindow, model.hasWeeklyWindow {
                CombinedQuotaBar(
                    model: model,
                    tint: tint,
                    weeklyEquivalentMultiplier: weeklyEquivalentMultiplier
                )
                CombinedQuotaMetadataLine(
                    primaryLabel: primaryLabel,
                    primaryPercent: model.intervalRemainingPercent,
                    primaryTimeFraction: model.intervalTimeRemainingFraction,
                    secondaryLabel: secondaryLabel,
                    secondaryPercent: model.weeklyRemainingPercent,
                    secondaryTimeFraction: model.weeklyTimeRemainingFraction,
                    resetsAt: EquivalentQuotaAllocation.bindingResetDate(
                        primaryFraction: model.intervalRemainingPercent / 100.0,
                        weeklyFraction: model.weeklyRemainingPercent / 100.0,
                        primaryResetsAt: model.intervalResetsAt,
                        weeklyResetsAt: model.weeklyResetsAt,
                        segments: weeklyEquivalentMultiplier
                    )
                )
            } else if model.hasIntervalWindow {
                SingleQuotaBar(
                    percent: model.intervalRemainingPercent,
                    tint: tint,
                    timeRemainingFraction: nil
                )
                SingleQuotaMetadataLine(
                    label: primaryLabel,
                    percent: model.intervalRemainingPercent,
                    resetsAt: model.intervalResetsAt
                )
            } else if model.hasWeeklyWindow {
                SingleQuotaBar(
                    percent: model.weeklyRemainingPercent,
                    tint: tint,
                    timeRemainingFraction: model.weeklyTimeRemainingFraction
                )
                SingleQuotaMetadataLine(
                    label: secondaryLabel,
                    percent: model.weeklyRemainingPercent,
                    resetsAt: model.weeklyResetsAt
                )
            }
        }
    }
}

/// 三列明细：**Last Prompt | 5h | 周**。
///
/// 三列等宽、顶端对齐。Last Prompt 和两个额度窗口是同一形状的东西——一段
/// 时间 + 一组 token 指标——横排才能横向对比（"这次 prompt 花了多少，比这周
/// 窗口多还是少"）；上下堆着时读者只能在三段之间来回跳。
///
/// 没有 Last Prompt 时三列变两列，剩下两列平分宽度（`maxWidth: .infinity`）。
struct QuotaDetailColumns: View {
    let lastPrompt: LastPromptUsage?
    let primaryLabel: String
    let primaryUsage: UsageMetricSummary?
    let primaryCreditUsage: QuotaCountUsage?
    let secondaryLabel: String
    let secondaryUsage: UsageMetricSummary?
    let secondaryCreditUsage: QuotaCountUsage?
    let hasSecondaryWindow: Bool
    let missingUsageIsLoading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let lastPrompt {
                LastPromptHoverSummaryView(lastPrompt: lastPrompt)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            QuotaUsageWindowColumn(
                label: primaryLabel,
                usage: primaryUsage,
                creditUsage: primaryCreditUsage,
                missingUsageIsLoading: missingUsageIsLoading
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if hasSecondaryWindow {
                QuotaUsageWindowColumn(
                    label: secondaryLabel,
                    usage: secondaryUsage,
                    creditUsage: secondaryCreditUsage,
                    missingUsageIsLoading: missingUsageIsLoading
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// GLM 今日闲时（off-peak）任务 token 用量：整行宽度，排在三列**下方**。
///
/// 闲时任务真实消耗但不消耗 Coding Plan 积分，混进 5h / 周两列会让那两列
/// 的数字对不上额度，所以它必须是独立的一行而不是第三列。
struct OffPeakUsageFootnote: View {
    let usage: UsageMetricSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            UsageMetricHoverSummaryView(
                title: "今日闲时（不消耗积分）",
                usage: usage,
                showPromptCount: true
            )
            Text("ZCode 闲时任务真实消耗；不影响 5h / 周积分余额")
                .font(MenuTypography.hoverFootnote)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 菜单形态的额度行

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
                CombinedQuotaBar(
                    model: model,
                    tint: tint,
                    weeklyEquivalentMultiplier: weeklyEquivalentMultiplier
                )
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
                SingleQuotaBar(
                    percent: percent,
                    tint: tint,
                    timeRemainingFraction: timeRemainingFraction
                )
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
            .frame(width: quotaCombinedDataColumnWidth, alignment: .leading)
            ResetTimeSummary(resetsAt: resetsAt)
        }
    }

    private func quotaValue(label: String, percent: Double, timeFraction: Double?) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(MenuTypography.dataLabel)
                .foregroundStyle(Color.primaryLabel)
            Text(Formatters.formatQuotaPercent(percent))
                .font(MenuTypography.dataValue)
                .foregroundStyle(summaryColor(for: percent, timeFraction: timeFraction))
                .frame(width: 40, alignment: .trailing)
        }
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
                    .font(MenuTypography.dataLabel)
                    .foregroundStyle(Color.primaryLabel)
                Text(Formatters.formatQuotaPercent(percent))
                    .font(MenuTypography.dataValue)
                    .foregroundStyle(summaryColor(for: percent))
                    .frame(width: 40, alignment: .trailing)
            }
            .frame(width: quotaSingleDataColumnWidth, alignment: .leading)
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
                    .font(MenuTypography.resetDate)
                    .lineLimit(1)
                Text("(\(Formatters.formatResetSuffix(from: resetsAt)))")
                    .font(MenuTypography.timeSuffix)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.primaryLabel)
        } else {
            Text("—")
                .font(MenuTypography.hint)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Tooltip helpers

/// 进度条 hover 说明。抽成命名空间是因为进度条现在可能被**父级**画
/// （dock 把条提到 model 标题之上），文案不能再是某个 view 里的自由函数。
enum QuotaBarTooltip {
    /// 精炼为清晰的配额与重置时间解释
    static func text(segments: Int, hasTriangle: Bool) -> String {
        let n = max(segments, 1)
        let parts: String
        if n == 1 {
            parts = "单一窗口可用进度"
        } else {
            parts = "第 1 格为当前窗口余量；后续 \(n - 1) 格为等价周额度余量"
        }
        let triangle: String
        if hasTriangle {
            triangle = "\n顶部 ▼ 标记周重置时间进度（左侧即将重置，右侧刚重置）"
        } else {
            triangle = ""
        }
        return "分段额度：\n\(parts)。\(triangle)"
    }
}

/// 兼容入口：菜单与卡片里的旧调用点仍按自由函数调用。
func segmentedBarTooltipText(segments: Int, hasTriangle: Bool) -> String {
    QuotaBarTooltip.text(segments: segments, hasTriangle: hasTriangle)
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
    /// 高峰期倒计时已提到卡片头部时置 false（dock 详情浮层）。
    var showsPeakIndicator: Bool = true

    var body: some View {
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
        .padding(.vertical, 2)
    }
}
