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
        case .healthy:  return .healthyTint
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

    /// 高峰期倒计时由**卡片**画（dock），不在额度行里。
    ///
    /// 它回答"现在能不能便宜用"，是这一屏额度概览的一部分；留在额度行里会被
    /// 一堆百分比和明细挤到下面。dock 侧它跟重置卡一起排在进度条下方、统计表
    /// 上方（见 `ProviderCardView.dockQuotaSummaryRows`）。
    static func hoistsPeakIndicator(mode: HoverRevealMode) -> Bool {
        mode == .alwaysVisible
    }

    /// 标题行不画状态点（dock）。
    ///
    /// 它紧挨着品牌图标，两个小圆挤在一起读起来是"图标带了个绿点"；状态本身在
    /// 同一行右侧那颗胶囊里已经写清楚了。菜单侧保留：那里没有右侧胶囊的替代。
    static func hidesHeaderStatusDot(mode: HoverRevealMode) -> Bool {
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

    /// dock 详情浮层把内容拆成**两张卡片**，各自的标题画在卡片**外面**的上方。
    ///
    /// 切分点不是新划的：额度那一组是"现在"、7 天用量那一组是"历史"，两者之间
    /// 本来就有 `HoverInfoRow` 的那条分隔线。卡片边界取代它之后，两组各自是一张
    /// 有边界的卡，下半截不会再被读成上半截的附表。
    ///
    /// 菜单侧不拆：主菜单卡片是折叠的，每张卡都很矮，拆成两张只会让整列菜单
    /// 多出一倍的卡片间距与标题行。菜单靠 `hoverRevealMode` 默认值保持原样。
    static func splitsIntoTwoCards(mode: HoverRevealMode) -> Bool {
        mode == .alwaysVisible
    }
}

/// provider 卡片 — 一个 provider 的全部信息
///
/// `Equatable`：卡片渲染只依赖 `status`（值类型）。配合调用点的 `.equatable()`，
/// 任一 provider 的任一状态变化只会重算真正变化的那几张卡，而不是整个菜单面板。
struct ProviderCardView: View, Equatable {
    let status: ProviderStatus

    /// 宿主决定详情是折叠（主菜单 hover 浮层）还是就地展开（dock 详情浮层）。
    /// 两种形态的排版差别都挂在这个值上，见 `header` / `content`。
    @Environment(\.hoverRevealMode) private var revealMode

    /// 卡片内容层四周的内边距。`EdgeDockTheme.popoverWidth` 推导宽度时要加上
    /// 这一层的两侧，所以提出成常量，避免两处各写一个 12 改一漏一。
    static let contentPadding: CGFloat = 12

    /// 转发给 `QuotaSummary` 的两个可选项，语义见那里的注释。菜单侧为 nil。
    var expandedDetailGroups: Binding<Set<Int>>? = nil
    var onMeasureDisclosure: ((Int, CGRect) -> Void)? = nil


    // nonisolated：View 结构体因 View 协议推断为 @MainActor，而 Equatable 的 ==
    //  witnesses 必须可从任意隔离域调用；status 是 Sendable 值类型，非隔离比较安全。
    nonisolated static func == (lhs: ProviderCardView, rhs: ProviderCardView) -> Bool {
        lhs.status == rhs.status
    }

    var body: some View {
        // A single card render used to rebuild the same provider-neutral
        // projection once for QuotaSummary and again for the local-usage
        // footer. The projection is derived only from `status`, so compute it
        // once and pass the value down to both consumers.
        let projection = status.usageProjection(for: status.lastSuccess)

        if ProviderCardLayout.splitsIntoTwoCards(mode: revealMode) {
            dockBody(projection: projection)
        } else {
            menuBody(projection: projection)
        }
    }

    /// 菜单：**一整张卡片**，标题（`header`）在卡片里面，和主菜单的信息密度一致。
    private func menuBody(projection: ProviderUsageProjection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content(projection: projection)
        }
        .padding(Self.contentPadding)
        .background(cardBackground)
        .overlay(cardBorder)
    }

    /// dock 详情浮层：**两张卡片**，各自的标题画在卡片**外面**的上方。
    ///
    /// 标题 1 就是卡片头部那一行（状态点 + 品牌图标 + provider 名 + 套餐胶囊，
    /// 右侧是刷新时间/状态），它被提到卡外，于是"第一张卡是什么"由它回答，
    /// 不再需要额外的「额度」小标题。
    ///
    /// 标题 2 是「最近7天token用量」，右侧同一行放数据新鲜度（更新于 / 计算中…），
    /// 因此图表自己那行标题在 dock 形态下不画（见 `SevenDayTokenUsageHoverView`）。
    ///
    /// 非 `.ok` 状态（读取中 / 失败 / 未配置）没有这两组可切，退回单卡：硬拆会
    /// 得到"第二张卡片只有一个占位提示"的空壳。
    @ViewBuilder
    private func dockBody(projection: ProviderUsageProjection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            headerContent
            if case .ok(let info) = status.state {
                dockCard {
                    quotaSection(info: info, projection: projection, between: AnyView(dockQuotaSummaryRows))
                    localUsage(projection: projection, part: .summary)
                }
                dockSectionTitle(projection: projection)
                dockCard {
                    localUsage(projection: projection, part: .detail)
                }
            } else {
                dockCard {
                    content(projection: projection)
                }
            }
        }
    }

    /// 夹在「元信息行 + 进度条」与「三列统计」之间的卡片级信息（dock）。
    ///
    /// 顺序是这一屏的读法：先看还剩多少（条），再看这批额度什么时候重置、现在
    /// 是不是高峰期，最后才是 Last Prompt / 5h / 周的明细。它们此前排在进度条
    /// **上方**，等于让人先读脚注再看正文。
    ///
    /// 这两行之所以要"夹进去"而不是留在卡片顶层：顶层只能排在整块额度内容之前
    /// 或之后，而它们的位置在中间（条之下、统计之上），只有交给 model 行去摆。
    @ViewBuilder
    private var dockQuotaSummaryRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            resetCreditsRow(divides: false)
            peakIndicator
        }
    }

    /// 一张卡片：内容 + 内边距 + 表面 + 描边。两张卡片共用同一份实现，
    /// 否则"两张卡长得不一样"这种偏差只能靠肉眼发现。
    ///
    /// `maxWidth: .infinity`：两张卡各自按内容宽度收缩时宽度会不一样（第二张
    /// 只有图表），堆在一起就是两块对齐不上的底；撑满浮层宽度才对齐。
    private func dockCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(Self.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(cardBorder)
    }

    /// 第二张卡片的标题行：标题 + 同一行右侧的数据新鲜度胶囊。
    ///
    /// **两个标题行同一套字体与样式**（`MenuTypography.cardTitle` + `primaryLabel`）：
    /// 它们是同一层级的东西——各自那张卡的名字。第二张曾经用更小的 `dataLabel`
    /// 加次要色，读起来像正文里的一句小标题，而不是与第一张并列的卡片标题。
    private func dockSectionTitle(projection: ProviderUsageProjection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("最近7天token用量")
                .font(MenuTypography.cardTitle)
                .foregroundStyle(Color.primaryLabel)
            Spacer(minLength: 8)
            LocalUsageFreshnessBadge(
                scannedAt: projection.scannedAt,
                isScanning: status.isScanningLocalUsage || projection.localUsageFreshness == .scanning
            )
        }
        .padding(.top, 4)
    }

    /// 卡片表面：半透明系统控件底色 + 品牌色描边。
    ///
    /// 曾经有第二套画法（`.transparent`：不画表面，直接坐在宿主的材质上），
    /// 只给 dock 的详情浮层用。那条路已经撤掉了——dock 浮层现在和菜单弹出用
    /// **同一张卡片**，"卡片长什么样"不该再有一个按调用方分叉的开关。
    @ViewBuilder
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            // 卡片属于内容层，使用更稳定的系统控件底色，减少透出外层玻璃的折射。
            .fill(Color(NSColor.controlBackgroundColor).opacity(0.60))
    }

    @ViewBuilder
    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(accentColor.opacity(0.25), lineWidth: 1)
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

    /// 菜单卡片的头部：标题行 + 账号信息的 hover 折叠区。
    ///
    /// dock 详情浮层不走这里——它的标题行直接用 `headerContent`，账号折叠区因为
    /// 面板 `ignoresMouseEvents` 永远展不开，所以干脆不画（见 `dockBody`）。
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

    /// **高峰期倒计时**。只 GLM 与 DeepSeek 有窗口概念。
    ///
    /// dock 里它排在进度条下方（`dockQuotaSummaryRows`）：它回答"现在能不能便宜
    /// 用"，属于这一屏的额度概览，而不是卡片标题的一部分。
    @ViewBuilder
    private var peakIndicator: some View {
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

    /// **重置卡**，折叠态：只总数 + 最近一张到期时间。
    ///
    /// 与菜单同一行组件，但 `revealsDetail: false`——那个浮层不吃鼠标事件，
    /// `HoverInfoRow` 在 `alwaysVisible` 下又总会展开，每张卡的明细会变成常驻。
    /// 折叠态那一句才是该常驻的信息。
    ///
    /// - Parameter divides: 是否在前面画一条分隔线。菜单里它紧跟在标题行后面，
    ///   需要那条线；dock 的第一张卡片里它是**卡片的第一个元素**，卡片边界已经
    ///   在分隔，再画一条线就是卡片顶部悬着一条横线。
    @ViewBuilder
    private func resetCreditsRow(divides: Bool) -> some View {
        if let info = status.lastSuccess,
           let resets = info.resetCredits,
           resets.shouldDisplay {
            if divides { Divider().opacity(0.3) }
            CompactResetCreditsRow(
                resets: resets,
                refreshIntervalSeconds: status.refreshIntervalSeconds,
                revealsDetail: false
            )
        }
    }

    private var headerContent: some View {
        HStack(spacing: 8) {
            // dock 的标题行不画状态点：它紧挨着品牌图标，两个小圆挤在一起读起来
            // 是"图标带了个绿点"，而状态本身在右侧那颗胶囊里已经写清楚了。
            if !ProviderCardLayout.hidesHeaderStatusDot(mode: revealMode) {
                StatusIndicator(level: status.aggregateHealthLevel())
            }
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
                    localUsage(projection: projection, part: .combined)
                }
            } else {
                placeholder("正在获取…")
            }
        case .ok(let info):
            VStack(alignment: .leading, spacing: 6) {
                quotaSection(info: info, projection: projection)
                localUsage(projection: projection, part: .combined)
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
                        localUsage(projection: projection, part: .combined)
                }
            }
        }
    }

    /// 「额度」这一段：额度窗口 + GLM 闲时峰值 + GLM 活动套餐余额。
    ///
    /// 抽出来只为一件事：让"dock 把它放进第一张卡片、菜单放进唯一那张卡片"这个
    /// 分叉落在**这一段的外面**。两种排版各写一遍 `QuotaSummary` 调用，改参数时
    /// 漏一处不会编译报错，只会让某一种形态悄悄少一个参数。
    ///
    /// `.loading` / `.failed` 两条分支不用它：它们各自要在额度行前面加状态说明
    /// （"正在获取…" / 红色错误行 + 上次成功时间），且失败态整块压 0.55 透明度，
    /// 硬套进来反而要在这段里再分支。
    @ViewBuilder
    private func quotaSection(
        info: QuotaInfo,
        projection: ProviderUsageProjection,
        between: AnyView = AnyView(EmptyView())
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            QuotaSummary(
                info: info,
                providerKind: status.kind,
                accentColor: status.accentColor,
                localSamples: projection.recentSamples,
                refreshIntervalSeconds: status.refreshIntervalSeconds,
                excludeWindows: excludeWindows,
                deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow,
                betweenBarAndColumns: between
            )
            if status.kind == .glmCodingPlan,
               let peak = status.glmPeakWindow,
               !ProviderCardLayout.hoistsPeakIndicator(mode: revealMode) {
                // dock 里它已经排到进度条下方（见 `dockQuotaSummaryRows`），
                // 这里再画一遍就是同一个倒计时出现两次。
                GlmPeakIndicatorView(window: peak)
            }
            if status.kind == .glmCodingPlan {
                GlmActivityPlanBalancesView(balances: status.glmLocalUsage?.activityPlanBalances)
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
    ///
    /// - Parameter part: dock 把这一块拆进两张卡片（汇总进上一张、图表进下一张），
    ///   菜单侧走 `.combined`。拆法见 `LocalUsagePart`。
    @ViewBuilder
    private func localUsage(projection: ProviderUsageProjection, part: LocalUsagePart) -> some View {
        makeLocalUsageFooter(
            dailyTokenUsage: projection.dailyTokenUsage,
            recentSamples: projection.recentSamples,
            quotaProviderID: status.kind.quotaProviderID,
            deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow,
            scannedAt: projection.scannedAt,
            isReady: projection.hasActivity
                && (status.kind != .codexChatGpt || projection.dailyTokenUsage.count == 7),
            freshness: projection.localUsageFreshness,
            emptyHint: emptyUsageHint,
            part: part
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
        emptyHint: String,
        part: LocalUsagePart
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
            emptyHint: emptyHint,
            part: part
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
        case .green: return .healthyTint
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
    /// dock：夹在「进度条块」与「三列统计」之间的卡片级信息（重置卡、高峰期），
    /// 由 `ProviderCardView.dockBody` 组装。菜单不传，默认空。
    var betweenBarAndColumns: AnyView = AnyView(EmptyView())
    /// dock 详情浮层里已展开的 model 分组。展开状态由 `EdgeDockController` 持有：
    /// 那一侧是**控制器**在判点击（浮层是完全穿透的窗口，视图收不到点击），
    /// 菜单侧没有这个概念，默认 nil 让菜单那边一行都不用改。
    var expandedDetailGroups: Binding<Set<Int>>? = nil
    /// 折叠头的实测矩形上报。浮层是 `.nonactivatingPanel`，点击不激活 app，
    /// SwiftUI 自己的 Button 按不动，只能把矩形交回控制器做命中判定。
    var onMeasureDisclosure: ((Int, CGRect) -> Void)? = nil
    /// dock 详情浮层把高峰期倒计时提到卡片头部；菜单保持它在余额行里。
    @Environment(\.hoverRevealMode) private var revealMode

    /// 重置卡是否画在这一块。dock 侧画在卡片头部（`ProviderCardView.resetCreditsRow`），
    /// 两处都画就是同一张卡出现两次。
    private var showsResetCredits: Bool {
        !ProviderCardLayout.expandsAccountSection(mode: revealMode)
    }

    private var showsPeakIndicator: Bool {
        !ProviderCardLayout.hoistsPeakIndicator(mode: revealMode)
    }

    private var displayedModels: [ModelQuota] {
        info.activeModels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(displayedModels.enumerated()), id: \.offset) { index, model in
                // 卡片级信息（重置卡、高峰期）只在**第一个** model 行上出现一次：
                // 它讲的是这个 provider 的整体情况，不是每个 model 一份；跟着每个
                // model 重复一次会读成"每个 model 各有一组重置卡"。
                let between = index == 0 ? betweenBarAndColumns : AnyView(EmptyView())
                // 第一个 model 行的明细常展开（它和条、重置卡是同一组信息的两面）；
                // 第二个及以后默认折叠，否则 Antigravity 这类双条 provider 会把
                // 浮层顶到上百 pt 之外、必须滚动才看得全。
                let collapsibleGroupIndex: Int? = index > 0 ? index : nil
                if Self.shouldUseChatGPTPlanRow(providerKind: providerKind, model: model) {
                    ChatGPTPlanModelRow(
                        model: model,
                        usageDetails: info.codexUsageDetails,
                        localSamples: localSamples,
                        tint: accentColor(for: model),
                        between: between,
                        collapsibleGroupIndex: collapsibleGroupIndex,
                        expandedGroups: expandedDetailGroups,
                        onMeasureDisclosure: onMeasureDisclosure
                    )
                } else if Self.shouldUseDeepseekBalanceRow(providerKind: providerKind, model: model) {
                    DeepseekBalanceRow(
                        model: model,
                        planLabel: info.planLabel,
                        balanceDetail: info.balanceDetail,
                        tint: accentColor(for: model),
                        peakWindow: deepseekPeakWindow,
                        showsPeakIndicator: showsPeakIndicator,
                        between: between
                    )
                } else {
                    CombinedQuotaWindowRow(
                        model: model,
                        primaryLabel: Self.primaryWindowLabel(providerKind: providerKind, model: model),
                        tint: accentColor(for: model),
                        weeklyEquivalentMultiplier: Self.weeklyEquivalentMultiplier(providerKind: providerKind, model: model),
                        providerKind: providerKind,
                        localSamples: localSamples,
                        excludeWindows: excludeWindows,
                        between: between,
                        collapsibleGroupIndex: collapsibleGroupIndex,
                        expandedGroups: expandedDetailGroups,
                        onMeasureDisclosure: onMeasureDisclosure
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
