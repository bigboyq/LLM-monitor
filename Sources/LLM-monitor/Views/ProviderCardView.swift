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

/// 同一张 `ProviderCardView` 在两种宿主下的排版规则。
///
/// 两个宿主的信息密度诉求相反：主菜单一屏要放下所有 provider，卡片必须靠
/// hover 折叠细节；dock 详情浮层只有一张卡、且不接受鼠标事件，折叠区展不开，
/// 只能全部就地展开——于是同一份内容在浮层里明显更高、容易超出屏幕。
///
/// 四条规则都只由 `HoverRevealMode` 决定，但**含义各不相同**，调用点直接写
/// `mode == .alwaysVisible` 会丢掉"这一处到底在改什么"，所以各自命名。
enum ProviderCardLayout {
    /// 单个 model 的进度条提到**标题上方**（dock）。
    ///
    /// 标题回答"这是哪个套餐"、条回答"还剩多少"，浮层里先看条更直接；
    /// 菜单保持标题在上——那是这行的名字，条是它的修饰。
    static func liftsProgressBar(mode: HoverRevealMode) -> Bool {
        mode == .alwaysVisible
    }

    /// 5h 与周两个窗口的明细**横向并排**（dock）。
    ///
    /// 竖排时读者要在两段之间来回跳着找同一栏；并排才能横向对比。
    /// 菜单那侧是按内容自然宽度测量的 hover 浮层，宽度敏感，维持竖排。
    static func laysWindowDetailsSideBySide(mode: HoverRevealMode) -> Bool {
        mode == .alwaysVisible
    }

    /// 账号折叠区（邮箱 / 数据来源）就地展开（菜单侧为 hover）。
    ///
    /// dock 详情浮层**不**展开它：整体 `ignoresMouseEvents`，没有人能悬停，
    /// 就地展开只会把低频信息塞进最抢眼的位置。菜单那侧保留 hover。
    static func expandsAccountSection(mode: HoverRevealMode) -> Bool {
        mode == .alwaysVisible
    }

    /// 高峰期倒计时画在**卡片头部**而非额度区（dock）。
    ///
    /// 它回答"现在能不能便宜用"，属于一眼要看的东西；留在额度区会被一堆
    /// 百分比和明细挤到下面。头部那行本来就常驻状态，新用户第一眼就会看到。
    static func showsPeakIndicatorInHeader(mode: HoverRevealMode) -> Bool {
        mode == .alwaysVisible
    }

    /// `input` 与 `cached` 拆成两行（dock）。
    ///
    /// 原本是 `input: 1.2M (+860K cached)`——cached 藏在括号里，扫一眼
    /// 只会读到 input，而 cache 命中率恰恰是判断"这次调用贵不贵"的关键数字。
    /// 浮层里一行只放一件事，行高是横向空间换来的。
    static func splitsCachedInputRow(mode: HoverRevealMode) -> Bool {
        mode == .alwaysVisible
    }

    /// `prompts` 与 `rounds` 拆成两行，`rounds` 跟在 `prompts` 下面（dock）。
    ///
    /// 原本挤在一行 `prompts: 42 (128 rounds)`。三列并排时每列只有约 140pt，
    /// 挤在一行必然换行或截断；拆开后每个数字都有自己完整的一行。
    static func splitsRoundsRow(mode: HoverRevealMode) -> Bool {
        mode == .alwaysVisible
    }
}

/// provider 卡片 — 一个 provider 的全部信息
///
/// `Equatable`：卡片渲染只依赖 `status`（值类型）。配合调用点的 `.equatable()`，
/// 任一 provider 的任一状态变化只会重算真正变化的那几张卡，而不是整个菜单面板。
struct ProviderCardView: View, Equatable {
    let status: ProviderStatus

    /// 卡片自身表面的画法。
    ///
    /// - `.system`：菜单里的默认样子（半透明控件底色 + 品牌描边）。
    /// - `.transparent`：不画表面，让**调用方**的背景透上来。
    ///   边缘状态窗的浮层用这个：背板已经是纯黑，卡片再叠一层半透明白/黑
    ///   会糊成灰块，而直接改共享视图的默认样式会连带改掉主菜单。
    enum Surface {
        case system
        case transparent
    }

    var surface: Surface = .system

    /// 宿主决定详情是折叠（主菜单 hover 浮层）还是就地展开（dock 详情浮层）。
    /// 两种形态的排版差别都挂在这个值上，见 `header` / `content`。
    @Environment(\.hoverRevealMode) private var revealMode

    /// 卡片内容层四周的内边距。`EdgeDockTheme.popoverWidth` 推导宽度时要加上
    /// 这一层的两侧，所以提出成常量，避免两处各写一个 12 改一漏一。
    static let contentPadding: CGFloat = 12

    // nonisolated：View 结构体因 View 协议推断为 @MainActor，而 Equatable 的 ==
    //  witnesses 必须可从任意隔离域调用；status 是 Sendable 值类型，非隔离比较安全。
    nonisolated static func == (lhs: ProviderCardView, rhs: ProviderCardView) -> Bool {
        lhs.status == rhs.status && lhs.surface == rhs.surface
    }

    var body: some View {
        // A single card render used to rebuild the same provider-neutral
        // projection once for QuotaSummary and again for the local-usage
        // footer. The projection is derived only from `status`, so compute it
        // once and pass the value down to both consumers.
        let projection = status.usageProjection(for: status.lastSuccess)

        VStack(alignment: .leading, spacing: 8) {
            header
            content(projection: projection)
        }
        .padding(Self.contentPadding)
        .background(cardBackground)
        .overlay(cardBorder)
    }

    @ViewBuilder
    private var cardBackground: some View {
        switch surface {
        case .system:
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                // 卡片属于内容层，使用更稳定的系统控件底色，减少透出外层玻璃的折射。
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.60))
        case .transparent:
            Color.clear
        }
    }

    @ViewBuilder
    private var cardBorder: some View {
        if surface == .system {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(accentColor.opacity(0.25), lineWidth: 1)
        }
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
        if ProviderCardLayout.expandsAccountSection(mode: revealMode) {
            // dock 详情浮层：不展开账号折叠区。那里是"悬停标题看账号"的细节，
            // 而这个浮层整体不接受鼠标事件（`ignoresMouseEvents`），没有人会去
            // 悬停它——就地展开只会把邮箱 / 数据来源这类低频信息塞进最抢眼的位置。
            // 往上提的是两样"一眼要看"的东西：
            //   高峰期倒计时 —— "现在能不能便宜用"。
            //   重置卡       —— 总数 + 最近一张到期时间；每张卡的明细同样因为不吃
            //                   鼠标事件而保持折叠。
            // 额度条**不**提到头部：Antigravity 有两个 model，提到一起就得给每条
            // 加名称 label 才分得清谁是谁，而那个 label 和下面原本那行模型名重了。
            // 进度条留在各自分块里、紧贴自己的三列，对应关系靠位置就够。
            VStack(alignment: .leading, spacing: 6) {
                headerContent
                headerPeakIndicator
                headerResetCredits
            }
        } else if status.kind == .antigravity {
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

    /// dock 详情浮层头部下方的**高峰期倒计时**。只 GLM 与 DeepSeek 有窗口概念。
    @ViewBuilder
    private var headerPeakIndicator: some View {
        switch status.kind {
        case .glmCodingPlan:
            if let peak = status.glmPeakWindow {
                GlmPeakIndicatorView(window: peak)
            }
        case .deepseek:
            DeepseekPeakIndicatorView(window: status.deepseekPeakWindow ?? .defaultWindow)
        default:
            EmptyView()
        }
    }

    /// dock 详情浮层头部的**重置卡**，折叠态：只总数 + 最近一张到期时间。
    ///
    /// 与菜单同一行组件，但 `revealsDetail: false`——那个浮层不吃鼠标事件，
    /// `HoverInfoRow` 在 `alwaysVisible` 下又总会展开，每张卡的明细会变成常驻。
    /// 折叠态那一句才是该常驻的信息。
    @ViewBuilder
    private var headerResetCredits: some View {
        if let info = status.lastSuccess,
           let resets = info.resetCredits,
           resets.shouldDisplay {
            Divider().opacity(0.3)
            CompactResetCreditsRow(
                resets: resets,
                refreshIntervalSeconds: status.refreshIntervalSeconds,
                revealsDetail: false
            )
        }
    }

    private var headerContent: some View {
        HStack(spacing: 8) {
            StatusIndicator(level: status.aggregateHealthLevel())
            BrandLogoView(kind: status.kind)
            Text(displayTitle)
                .font(MenuTypography.cardTitle)
                .foregroundStyle(Color.primaryLabel)
                // R15: 长 displayName 不撑破 360pt 宽度，单行尾部截断，hover 看完整文本。
                .lineLimit(1)
                .truncationMode(.tail)
                .help(displayTitle)
            if let pillLabel {
                Text(pillLabel)
                    .font(MenuTypography.pill)
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
    private func content(projection: ProviderUsageProjection) -> some View {
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
                        localSamples: projection.recentSamples,
                        refreshIntervalSeconds: status.refreshIntervalSeconds,
                        excludeWindows: excludeWindows,
                        deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
                    )
                    .opacity(0.5)
                    localUsageFooter(projection: projection)
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
                        localSamples: projection.recentSamples,
                refreshIntervalSeconds: status.refreshIntervalSeconds,
                excludeWindows: excludeWindows,
                deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
                )
                if status.kind == .glmCodingPlan,
                   let peak = status.glmPeakWindow,
                   !ProviderCardLayout.showsPeakIndicatorInHeader(mode: revealMode) {
                    // dock 详情浮层里它已经升到头部（见 `headerPeakIndicator`），
                    // 这里再画一遍就是同一个倒计时出现两次。
                    GlmPeakIndicatorView(window: peak)
                }
                if status.kind == .glmCodingPlan {
                    GlmActivityPlanBalancesView(balances: status.glmLocalUsage?.activityPlanBalances)
                }
                localUsageFooter(projection: projection)
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
                        localSamples: projection.recentSamples,
                        refreshIntervalSeconds: status.refreshIntervalSeconds,
                        excludeWindows: excludeWindows,
                        deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
                    )
                        .opacity(0.55)
                        localUsageFooter(projection: projection)
                }
            }
        }
    }

    /// GLM 闲时任务窗口（仅 `.glmCodingPlan`）。额度窗口 hover 统计排除这些窗口内的 sample，
    /// 本地 token 柱图仍保留。其他 provider 恒为空。
    private var excludeWindows: [GlmOffPeakWindow] {
        status.glmLocalUsage?.offPeakWindows ?? []
    }

    /// 所有卡片统一展示 quota provider 关联的客户端 token 汇总；客户端来源
    /// 只保留在 hover 明细中，避免卡片主体出现复杂的多来源信息。
    @ViewBuilder
    private func localUsageFooter(projection: ProviderUsageProjection) -> some View {
        makeLocalUsageFooter(
            dailyTokenUsage: projection.dailyTokenUsage,
            recentSamples: projection.recentSamples,
            quotaProviderID: status.kind.quotaProviderID,
            deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow,
            scannedAt: projection.scannedAt,
            isReady: projection.hasActivity
                && (status.kind != .codexChatGpt || projection.dailyTokenUsage.count == 7),
            freshness: projection.localUsageFreshness,
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
        recentSamples: [LocalTokenUsageSample],
        quotaProviderID: String,
        deepseekPeakWindow: DeepseekPeakWindow,
        scannedAt: Date?,
        isReady: Bool,
        freshness: LocalUsageFreshness,
        emptyHint: String
    ) -> some View {
        LocalUsageFooterView(
            dailyTokenUsage: dailyTokenUsage,
            recentSamples: recentSamples,
            quotaProviderID: quotaProviderID,
            deepseekPeakWindow: deepseekPeakWindow,
            scannedAt: scannedAt,
            isScanning: status.isScanningLocalUsage || freshness == .scanning,
            freshness: freshness,
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
                    .font(MenuTypography.caption)
                    .foregroundStyle(.secondary)
                Text("前往设置启用并配置")
                    .font(MenuTypography.hint)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(MenuTypography.caption)
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
    /// 菜单打开期间由共享 MenuDisplayClock 每秒 tick，确保不会跨过阈值却仍保留旧颜色。
    nonisolated static let timelineIntervalSeconds: TimeInterval = 1

    let status: ProviderStatus
    @Environment(\.menuDisplayDate) private var displayDate

    /// 给定时刻的纯展示模型，方便精确验证边界；实际时钟由菜单共享注入。
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
        let presentation = presentation(at: displayDate)
        let color = color(for: presentation.tone)

        Text(presentation.title)
            .font(MenuTypography.badge)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }

    private func color(for tone: Tone) -> Color {
        switch tone {
        case .secondary: return .secondary
        case .green: return .green
        case .yellow: return .warningTint
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
    /// dock 详情浮层把高峰期倒计时提到卡片头部；菜单保持它在余额行里。
    @Environment(\.hoverRevealMode) private var revealMode

    /// 重置卡是否画在这一块。dock 侧画在卡片头部（`ProviderCardView.headerResetCredits`），
    /// 两处都画就是同一张卡出现两次。
    private var showsResetCredits: Bool {
        !ProviderCardLayout.expandsAccountSection(mode: revealMode)
    }

    private var showsPeakIndicator: Bool {
        !ProviderCardLayout.showsPeakIndicatorInHeader(mode: revealMode)
    }

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
                        peakWindow: deepseekPeakWindow,
                        showsPeakIndicator: showsPeakIndicator
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

            if let resets = info.resetCredits, resets.shouldDisplay, showsResetCredits {
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

    /// 视图层兼容入口：倍率映射已下沉到 `ModelQuota`，让卡片分段条与状态栏
    /// 聚合（中心扇形的 min(5h, 周 × N)）共用同一份逻辑，现有调用点保持不动。
    nonisolated static func weeklyEquivalentMultiplier(providerKind: ProviderKind, model: ModelQuota) -> Int {
        ModelQuota.weeklyEquivalentMultiplier(providerKind: providerKind, model: model)
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
