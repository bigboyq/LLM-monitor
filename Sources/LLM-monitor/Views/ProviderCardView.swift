import SwiftUI
import AppKit

/// 状态指示点 — 健康 / 警告 / 危险
struct StatusIndicator: View {
    let level: HealthLevel?
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Group {
                    if level != nil {
                        Circle()
                            .stroke(color.opacity(0.25), lineWidth: size * 0.5)
                            .blur(radius: size * 0.3)
                    }
                }
            )
            .animation(.easeInOut(duration: 0.2), value: level)
    }

    private var color: Color {
        guard let level else { return .secondary.opacity(0.5) }
        switch level {
        case .healthy:  return .green
        case .warning:  return .orange
        case .critical: return .red
        }
    }
}

/// provider 卡片 — 一个 provider 的全部信息
struct ProviderCardView: View {
    let status: ProviderStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                // 卡片属于内容层，使用更稳定的系统控件底色，减少透出外层玻璃的折射。
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.60))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accentColor.opacity(0.25), lineWidth: 1)
        )
    }

    private var accentColor: Color {
        switch status.accentColor {
        case .minimax:     return .purple
        case .chatgpt:     return .green
        case .antigravity: return .blue
        case .glm:         return .glmBrand
        case .deepseek:    return .cyan
        case .custom:      return .gray
        }
    }

    @ViewBuilder
    private var header: some View {
        if status.kind == .antigravity {
            HoverInfoRow {
                headerContent
            } detail: {
                AntigravityAccountHoverView(
                    planLabel: planLabel,
                    accountEmail: accountEmail
                )
            }
        } else if status.kind == .codexChatGpt {
            HoverInfoRow {
                headerContent
            } detail: {
                ChatGPTAccountHoverView(
                    planLabel: planLabel,
                    accountEmail: accountEmail
                )
            }
        } else if status.kind == .deepseek {
            HoverInfoRow {
                headerContent
            } detail: {
                DeepseekAccountHoverView(
                    planLabel: planLabel,
                    balanceDetail: status.lastSuccess?.balanceDetail
                )
            }
        } else {
            headerContent
        }
    }

    private var headerContent: some View {
        HStack(spacing: 8) {
            StatusIndicator(level: status.healthLevel)
            BrandLogoView(kind: status.kind)
            Text(displayTitle)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.primaryLabel)
                // R15: 长 displayName 不撑破 360pt 宽度，单行尾部截断，hover 看完整文本。
                .lineLimit(1)
                .truncationMode(.tail)
                .help(displayTitle)
            if let pillLabel {
                Text(pillLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            Spacer()
            if case .loading = status.state {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 14, height: 14)
            } else {
                ProviderStateLabel(status: status)
            }
        }
    }

    /// 卡片标题。一律走 `status.displayName`（provider 名），
    /// 套餐名（如果有）放进 `pillLabel` 跟 ChatGPT 的 `Team` 节奏保持一致。
    private var displayTitle: String {
        status.displayName
    }

    /// 标题右侧的小 pill 文本。Antigravity 会剥掉 `Google ` / `Antigravity ` 前缀
    /// （见 `QuotaSummary.planPillLabel`），让 `Google AI Pro` → `AI Pro` 跟 ChatGPT 的 `Team` 短一致。
    private var pillLabel: String? {
        QuotaSummary.planPillLabel(providerKind: status.kind, planLabel: planLabel)
    }

    private var planLabel: String? {
        status.lastSuccess?.planLabel
    }

    private var accountEmail: String? {
        status.lastSuccess?.accountEmail
    }

    @ViewBuilder
    private var content: some View {
        switch status.state {
        case .notConfigured(let reason):
            notConfiguredView(reason: reason)
        case .ready:
            placeholder("准备就绪…")
        case .loading(let lastSuccess):
            if let last = lastSuccess {
                VStack(alignment: .leading, spacing: 6) {
                    QuotaSummary(
                        info: last,
                        providerKind: status.kind,
                        accentColor: status.accentColor,
                        localSamples: localUsageSamples,
                        refreshIntervalSeconds: status.refreshIntervalSeconds,
                        excludeWindows: excludeWindows,
                        deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
                    )
                    .opacity(0.5)
                    localUsageFooter(for: last)
                }
            } else {
                placeholder("正在获取…")
            }
        case .ok(let info):
            VStack(alignment: .leading, spacing: 6) {
                QuotaSummary(
                    info: info,
                    providerKind: status.kind,
                    accentColor: status.accentColor,
                    localSamples: localUsageSamples,
                refreshIntervalSeconds: status.refreshIntervalSeconds,
                excludeWindows: excludeWindows,
                deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
                )
                if status.kind == .glmCodingPlan, let peak = status.glmPeakWindow {
                    GlmPeakIndicatorView(window: peak)
                }
                localUsageFooter(for: info)
            }
        case .failed(let message, let lastSuccess):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if let last = lastSuccess {
                    Text("上次成功：\(Formatters.formatClock(last.fetchedAt))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    QuotaSummary(
                        info: last,
                        providerKind: status.kind,
                        accentColor: status.accentColor,
                        localSamples: localUsageSamples,
                        refreshIntervalSeconds: status.refreshIntervalSeconds,
                        excludeWindows: excludeWindows,
                        deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
                    )
                        .opacity(0.55)
                        localUsageFooter(for: last)
                }
            }
        }
    }

    /// GLM 闲时任务窗口（仅 `.glmCodingPlan`）。额度窗口 hover 统计排除这些窗口内的 sample，
    /// 本地 token 柱图仍保留。其他 provider 恒为空。
    private var excludeWindows: [GlmOffPeakWindow] {
        status.glmLocalUsage?.offPeakWindows ?? []
    }

    private var localUsageSamples: [LocalTokenUsageSample] {
        status.usageProjection(for: status.lastSuccess).recentSamples
    }

    /// 所有卡片统一展示 quota provider 关联的客户端 token 汇总；客户端来源
    /// 只保留在 hover 明细中，避免卡片主体出现复杂的多来源信息。
    @ViewBuilder
    private func localUsageFooter(for info: QuotaInfo) -> some View {
        let projection = status.usageProjection(for: info)
        makeLocalUsageFooter(
            dailyTokenUsage: projection.dailyTokenUsage,
            scannedAt: projection.scannedAt,
            isReady: projection.hasActivity
                && (status.kind != .codexChatGpt || projection.dailyTokenUsage.count == 7),
            emptyHint: emptyUsageHint
        )
    }

    private var emptyUsageHint: String {
        switch status.kind {
        case .codexChatGpt: return "本地 token 用量扫描尚未完成"
        case .antigravity: return "本机未发现 Antigravity 会话数据"
        case .minimaxTokenPlan: return "本机未发现 MiniMax Code / DSH 会话数据"
        case .glmCodingPlan: return "本机未发现 ZCode / DSH 会话数据"
        case .deepseek: return "暂无 DSH / OpenCode 的 DeepSeek Token 消耗历史"
        }
    }

    @ViewBuilder
    private func makeLocalUsageFooter<Daily: LocalUsageDaily>(
        dailyTokenUsage: [Daily],
        scannedAt: Date?,
        isReady: Bool,
        emptyHint: String
    ) -> some View {
        LocalUsageFooterView(
            dailyTokenUsage: dailyTokenUsage,
            scannedAt: scannedAt,
            isScanning: status.isScanningLocalUsage,
            isReady: isReady,
            emptyHint: emptyHint
        )
    }

    private func notConfiguredView(reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.badge.gearshape")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("编辑 config.json 启用")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}

struct ProviderStateLabel: View {
    enum Tone: Equatable, Sendable {
        case secondary
        case green
        case yellow
        case red
    }

    struct Presentation: Equatable, Sendable {
        let title: String
        let tone: Tone
    }

    /// 最小刷新间隔为 10 秒，其中第一个新鲜度阈值只有 3 秒。
    /// 每秒 tick 可确保菜单持续打开时不会跨过阈值却仍保留旧颜色。
    nonisolated static let timelineIntervalSeconds: TimeInterval = 1

    let status: ProviderStatus

    /// 给定时刻的纯展示模型，既让 `TimelineView` 驱动实时更新，也方便精确验证边界。
    nonisolated func presentation(at now: Date) -> Presentation {
        switch status.state {
        case .notConfigured:
            return Presentation(title: "未启用", tone: .secondary)
        case .ready:
            return Presentation(title: "待更新", tone: .secondary)
        case .loading:
            return Presentation(title: "更新中", tone: .secondary)
        case .failed:
            return Presentation(title: "需重试", tone: .red)
        case .ok:
            if let lastRefreshedAt = status.lastRefreshedAt {
                let elapsed = now.timeIntervalSince(lastRefreshedAt)
                let interval = Double(status.refreshIntervalSeconds)
                let r = interval > 0 ? (elapsed / interval) : 0.0

                let timeString = Formatters.formatClock(lastRefreshedAt, now: now)
                let tone: Tone
                if r <= 0.3 {
                    tone = .green
                } else if r <= 0.8 {
                    tone = .secondary
                } else if r <= 1.0 {
                    tone = .yellow
                } else {
                    tone = .red
                }
                return Presentation(title: timeString, tone: tone)
            } else {
                return Presentation(title: "已更新", tone: .green)
            }
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.timelineIntervalSeconds)) { context in
            let presentation = presentation(at: context.date)
            let color = color(for: presentation.tone)

            Text(presentation.title)
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(color.opacity(0.1), in: Capsule())
        }
    }

    private func color(for tone: Tone) -> Color {
        switch tone {
        case .secondary: return .secondary
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        }
    }
}

/// 额度摘要：每个 model 一组 + reset credits
struct QuotaSummary: View {
    let info: QuotaInfo
    let providerKind: ProviderKind
    let accentColor: AccentColor
    let localSamples: [LocalTokenUsageSample]
    /// R3: reset credits 过期判定用到的刷新间隔（秒）。
    var refreshIntervalSeconds: Int = 300
    /// 额度窗口 hover 统计需要排除的时间窗口（GLM 闲时任务不消耗积分）。
    /// 本地 token 柱图不走这条路径，仍包含闲时任务。
    var excludeWindows: [GlmOffPeakWindow] = []
    /// DeepSeek 高峰期窗口（仅 `.deepseek` 用到；其余 provider 用默认值占位）。
    var deepseekPeakWindow: DeepseekPeakWindow = .defaultWindow

    private var displayedModels: [ModelQuota] {
        info.activeModels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(displayedModels.enumerated()), id: \.offset) { index, model in
                if Self.shouldUseChatGPTPlanRow(providerKind: providerKind, model: model) {
                    ChatGPTPlanModelRow(
                        model: model,
                        usageDetails: info.codexUsageDetails,
                        localSamples: localSamples,
                        tint: accentColor(for: model)
                    )
                } else if Self.shouldUseDeepseekBalanceRow(providerKind: providerKind, model: model) {
                    DeepseekBalanceRow(
                        model: model,
                        planLabel: info.planLabel,
                        balanceDetail: info.balanceDetail,
                        tint: accentColor(for: model),
                        peakWindow: deepseekPeakWindow
                    )
                } else {
                    CombinedQuotaWindowRow(
                        model: model,
                        primaryLabel: Self.primaryWindowLabel(providerKind: providerKind, model: model),
                        tint: accentColor(for: model),
                        weeklyEquivalentMultiplier: Self.weeklyEquivalentMultiplier(providerKind: providerKind, model: model),
                        providerKind: providerKind,
                        localSamples: localSamples,
                        excludeWindows: excludeWindows
                    )
                }

                if index < displayedModels.count - 1 {
                    Divider().opacity(0.3)
                }
            }

            if let resets = info.resetCredits, resets.shouldDisplay {
                if !displayedModels.isEmpty {
                    Divider().opacity(0.3)
                }
                CompactResetCreditsRow(resets: resets, refreshIntervalSeconds: refreshIntervalSeconds)
            }
        }
    }

    nonisolated static func shouldUseChatGPTPlanRow(providerKind: ProviderKind, model: ModelQuota) -> Bool {
        providerKind == .codexChatGpt && model.modelName.lowercased() == "chatgpt_plan"
    }

    nonisolated static func shouldUseDeepseekBalanceRow(providerKind: ProviderKind, model: ModelQuota) -> Bool {
        providerKind == .deepseek
    }

    /// 主窗口显示标签：minimax video 用的是"日"窗口，其他 minimax 模型都是"5h"。
    /// ChatGPT / Antigravity 由 ChatGPTPlanModelRow 用 `codexWindowLabel` 自己算，
    /// 不走这里。
    nonisolated static func primaryWindowLabel(providerKind: ProviderKind, model: ModelQuota) -> String {
        if providerKind == .minimaxTokenPlan && model.modelName.lowercased() == "video" {
            return "日"
        }
        return "5h"
    }

    /// 套餐名 pill 文本。
    /// - Antigravity：剥掉 `Google ` / `Antigravity ` 前缀，让 `Google AI Pro` → `AI Pro`
    ///   跟 ChatGPT 的 `Team` 一样短，跟 provider 名 (`Google Antigravity`) 互补。
    /// - 其他 provider：原样返回。
    /// - nil / 空 → nil。
    nonisolated static func planPillLabel(providerKind: ProviderKind, planLabel: String?) -> String? {
        guard let planLabel, !planLabel.isEmpty else { return nil }
        if providerKind == .antigravity {
            let stripped = planLabel
                .replacingOccurrences(of: "Google ", with: "")
                .replacingOccurrences(of: "Antigravity ", with: "")
            return stripped.isEmpty ? planLabel : stripped
        }
        return planLabel
    }

    nonisolated static func weeklyEquivalentMultiplier(providerKind: ProviderKind, model: ModelQuota) -> Int {
        switch providerKind {
        case .minimaxTokenPlan:
            // video 用日窗口 → 1 天 ≈ 1/7 周；其他模型（general 等）走 5h 窗口 → 1/10 周
            return model.modelName.lowercased() == "video" ? 7 : 10
        case .codexChatGpt:
            return 6
        case .antigravity:
            return model.modelName.lowercased() == AntigravityModelKind.claudeAndGptModels.rawValue ? 3 : 6
        case .glmCodingPlan:
            // GLM Coding Plan：5h 积分 × 5 = 周积分（Lite 2000/10000、Pro 12000/60000、Max 28000/140000）
            return 5
        case .deepseek:
            return 1
        }
    }

    private func accentColor(for model: ModelQuota) -> Color {
        switch accentColor {
        case .minimax:
            return .minimaxBrand
        case .chatgpt:
            return .chatgptBrand
        case .antigravity:
            if model.modelName.lowercased() == AntigravityModelKind.claudeAndGptModels.rawValue {
                return .antigravityClaude
            }
            return .antigravityGemini
        case .glm:
            return .glmBrand
        case .deepseek:
            return .cyan
        case .custom:
            return .gray
        }
    }
}
