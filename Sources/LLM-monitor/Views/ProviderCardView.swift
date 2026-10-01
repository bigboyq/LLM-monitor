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
/// 每条规则都只由 `HoverRevealMode` 决定，但**含义各不相同**，调用点直接写
/// `mode == .alwaysVisible` 会丢掉"这一处到底在改什么"，所以各自命名。
enum ProviderCardLayout {
    /// 单个 model 的进度条提到**标题上方**（dock）。
    ///
    /// 标题回答"这是哪个套餐"、条回答"还剩多少"，浮层里先看条更直接；
    /// 菜单保持标题在上——那是这行的名字，条是它的修饰。
    static func liftsProgressBar(mode: HoverRevealMode) -> Bool {
        mode == .alwaysVisible
    }

    // 曾有 `laysWindowDetailsSideBySide(mode:)`（`alwaysVisible` 即并排），已删除。
    //
    // 它唯一的消费者是 `QuotaWindowsHoverView` / `QuotaUsageWindowsHoverView` 里的
    // 并排分支，而那两个视图只从 `QuotaCombinedUsageRow` / `QuotaSingleUsageRow`
    // 构造，后者只出现在 model 行的 `menuLayout` 里——dock 的额度块早已重排成
    // `ModelQuotaDockBlock` + `QuotaBarWithMetadata`，不再经过它们。于是判据恒为
    // false，**并排那一支跑不到，堆叠那一支才是实际行为**：一个看着已实现、实际
    // 从未生效的开关。
    //
    // 现在按产品决定统一成并排，并把判据内联到那两个视图里（单窗口仍单列）。
    // dock 侧的"两列"是另一回事：`QuotaBarWithMetadata` 的元信息行本来就是
    // `5h 62%  周 80%` 一行并排，不需要任何谓词。

    /// 重置额度卡由**卡片**画（dock），不在 model 列表尾部（菜单）。
    ///
    /// 它讲的是"这个 provider 的额度什么时候回补"，是整张卡的一个属性而不是某个
    /// model 的属性。dock 侧跟高峰期倒计时一起夹在进度条下方（见
    /// `ProviderCardView.dockQuotaSummaryRows`）；菜单侧留在 model 列表末尾。
    static func hoistsResetCredits(mode: HoverRevealMode) -> Bool {
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
    /// 原本挤在一行 `prompts: 42 (128 rounds)`。当初是三列并排逼出来的——每列只有
    /// 约 140pt，挤一行必然换行或截断。三列撤掉后触发条件没了，但 dock 侧的行是
    /// 整行宽的，一行一个数字仍然更好读，留着不拆反而像半途而废。
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
/// `Equatable`：卡片渲染依赖 `status`（值类型）**和** `@Environment(\.hoverRevealMode)`
/// （排版形态，见 `ProviderCardLayout`）。配合调用点的 `.equatable()`，任一 provider
/// 的任一状态变化只会重算真正变化的那几张卡，而不是整个菜单面板。
///
/// ⚠️ `==` 只比较 `status`，**不**比较 `revealMode` —— 它是 Environment，取不到。
/// 当前安全：唯一的 `.equatable()` 调用点在 `MenuContentView` 里，而那里
/// `revealMode` 恒为默认的 `.onHover`；dock 浮层是每次 `updatePopover` 重建整棵
/// `rootView`，不走这个缓存。将来若有人在两个 mode 都可能出现的地方加
/// `.equatable()`，就必须把 `revealMode` 也纳入比较。
struct ProviderCardView: View, Equatable {
    let status: ProviderStatus

    /// 宿主决定详情是折叠（主菜单 hover 浮层）还是就地展开（dock 详情浮层）。
    /// 两种形态的排版差别都挂在这个值上，见 `header` / `content`。
    @Environment(\.hoverRevealMode) private var revealMode

    /// 卡片内容层四周的内边距。`EdgeDockTheme.popoverWidth` 推导宽度时要加上
    /// 这一层的两侧，所以提出成常量，避免两处各写一个 12 改一漏一。
    static let contentPadding: CGFloat = 12

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
                    quotaUsageDivider
                    localUsage(projection: projection, part: .summary)
                }
                dockSectionTitle(projection: projection)
                dockCard {
                    localUsage(projection: projection, part: .detail)
                }
            } else {
                dockCard {
                    // `between` 在这里**同样**要传：dock 形态下重置卡与高峰期倒计时
                    // 是由卡片层画的（`QuotaSummary` 会因为 `hoistsResetCredits` /
                    // `hoistsPeakIndicator` 为 true 而不再自己画）。曾经只在 `.ok`
                    // 分支传，`.loading` / `.failed` 的回退路径忘了——那两种状态下
                    // 谁也不画，两头落空。`.loading` 每次刷新都会短暂出现（`AppState`
                    // 在每次 `refreshProviderDirectly` 开头就置位），于是重置卡和
                    // 倒计时在 dock 里**每次刷新都闪一下**；`.failed` 则是一直不见。
                    // 缓存额度还在的时候（正是需要看"上次剩多少"的时候）丢信息最亏。
                    content(projection: projection, quotaBetween: AnyView(dockQuotaSummaryRows))
                }
            }
        }
    }

    /// 第一张卡片里，"额度"与"本地用量"之间的那条线。
    ///
    /// 两条线两侧的数据源不同：额度来自 provider 接口，用量来自本机会话扫描。
    /// 没有这条线，`📈 今天 …` 会被读成额度的延续（尤其是它为空时的"扫描尚未
    /// 完成"，看上去就像在解释上一行为什么没数字）。
    ///
    /// 它画在**卡片层**而不是每个 model 块里：三列明细撤掉后块内只剩额度本身，
    /// 而这条线要横跨所有 model（Antigravity 有两个），每块各画一条会在两个块
    /// 之间叠成两条挨着的线。样式与 7 天图表下方那条同款（同色、同不透明度、
    /// 整行宽、不额外缩进），上下间距 6 + 3 = 9pt，两条线在屏幕上读起来是同一条。
    private var quotaUsageDivider: some View {
        Divider().opacity(0.45).padding(.vertical, 3)
    }

    /// 夹在「元信息行 + 进度条」与下方「本地用量」之间的卡片级信息（dock）。
    ///
    /// 顺序是这一屏的读法：先看还剩多少（条），再看这批额度什么时候重置、现在
    /// 是不是高峰期。三列明细（Last Prompt / 5h / 周）已撤掉，条之下第一件
    /// 补充信息就是用量，两者都排在额度之后——它们此前排在进度条**上方**，等于
    /// 让人先读脚注再看正文。
    ///
    /// 这两行之所以要"夹进去"而不是留在卡片顶层：顶层只能排在整块额度内容之前
    /// 或之后，而它们的位置在中间（条之下、用量之上），只有交给 model 行去摆。
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
    /// **dock 侧不是靠某个 mode 谓词把这里关掉的，而是根本不调用这个属性**：
    /// `dockBody` 的标题行直接用 `headerContent`。这就是"dock 不画账号折叠区"的
    /// 全部实现——一个 `ProviderCardLayout.expandsAccountSection` 之类的谓词放在那里
    /// 只会制造"规则存在 ⇒ 有地方在用"的错觉：谓词返回 true 而没有任何消费方，
    /// 测试再断言它返回 true，三方一起给假信号（这个组合本分支真出现过一次，
    /// `hoistsResetCredits` 就是从它身上拆下来的）。
    ///
    /// 折叠区在 dock 里本来就展不开（面板 `ignoresMouseEvents = true`），所以就地
    /// 展开不是选项，是唯一选项——但既然浮层不收鼠标事件，低频的邮箱/数据来源
    /// 塞在最抢眼的位置也没有意义，直接不画。
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
    /// `quotaBetween`：dock 形态下夹在进度条与用量之间的卡片级内容（重置卡 + 高峰期）。
    /// 菜单侧不传（默认空）——菜单由 `QuotaSummary` 自己画那两样。
    private func content(
        projection: ProviderUsageProjection,
        quotaBetween: AnyView = AnyView(EmptyView())
    ) -> some View {
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
                        deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow,
                        betweenBarAndColumns: quotaBetween
                    )
                    .opacity(0.5)
                    localUsage(projection: projection, part: .combined)
                }
            } else {
                placeholder("正在获取…")
            }
        case .ok(let info):
            VStack(alignment: .leading, spacing: 6) {
                quotaSection(info: info, projection: projection, between: quotaBetween)
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
                        deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow,
                        // 与 `.loading` 那一支同源，别漏。dock 形态下重置卡与高峰期
                        // 倒计时**只**由这一格提供（`QuotaSummary` 会因
                        // `hoistsResetCredits` / `hoistsPeakIndicator` 为 true 而不再
                        // 自己画，`quotaSection` 里的 GLM 倒计时这条路也走不到）。
                        // 失败时恰恰最该看到它——用户要知道的是"上次还剩多少、
                        // 什么时候回补"，而这条 `lastSuccess` 正是那份数据的来源。
                        betweenBarAndColumns: quotaBetween
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
    /// dock：夹在「进度条块」与「本地用量」之间的卡片级信息（重置卡、高峰期），
    /// 由 `ProviderCardView.dockBody` 组装。菜单不传，默认空。
    var betweenBarAndColumns: AnyView = AnyView(EmptyView())
    /// dock 详情浮层把高峰期倒计时提到卡片头部；菜单保持它在余额行里。
    @Environment(\.hoverRevealMode) private var revealMode

    /// 重置卡是否画在这一块（model 列表尾部）。dock 侧画在卡片头部
    /// （`ProviderCardView.resetCreditsRow`），两处都画就是同一张卡出现两次。
    private var showsResetCredits: Bool {
        !ProviderCardLayout.hoistsResetCredits(mode: revealMode)
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
                if Self.shouldUseChatGPTPlanRow(providerKind: providerKind, model: model) {
                    ChatGPTPlanModelRow(
                        model: model,
                        usageDetails: info.codexUsageDetails,
                        localSamples: localSamples,
                        tint: accentColor(for: model),
                        between: between
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
                        between: between
                    )
                }

                if index < displayedModels.count - 1 {
                    Divider().opacity(0.3)
                }
            }

            // 一个 model 都没有时 `ForEach` 不产出任何行，而卡片级信息是挂在
            // `index == 0` 上的——它会跟着一起消失。dock 浮层里这块（重置卡 +
            // 高峰期）是"这个 provider 还剩多少、什么时候回补"的**唯一**出处，
            // 丢了就只剩一张空卡。菜单侧 `betweenBarAndColumns` 恒为空，所以这
            // 条分支对菜单是 no-op。
            if displayedModels.isEmpty {
                betweenBarAndColumns
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
    /// 周窗口的标签。**中央定义**：`QuotaViews` 里四个调用点都写死过"周"，
    /// 而同层的 `primaryWindowLabel` 是中央化的——minimax 的 video 模型短周期窗口
    /// 其实是"日"，周标签迟早要跟着一起调，四个副本只会改漏其中几个。
    nonisolated static func weeklyWindowLabel() -> String { "周" }

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
