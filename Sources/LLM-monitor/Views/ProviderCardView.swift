import SwiftUI
import AppKit

/// 同一张 `ProviderCardView` 的排版规则。
///
/// 菜单内容区已改为 Harness（客户端）视角，**不再渲染 provider 卡**：额度那一面
/// 由边缘状态窗浮层与菜单底部的 provider 兜底行（`ProviderStatusStripView`，hover
/// 弹出的就是这张卡）承担。因此这张卡只剩**一个**渲染宿主形态：`.alwaysVisible`
/// （浮层 `ignoresMouseEvents = true`，折叠区展不开，就地展开是唯一选项）。
///
/// 曾经按 `HoverRevealMode` 分叉的规则至此**全部收敛**，这个类型只剩下面注释里
/// 记录的历史。收敛的判据只有一条：`hoverRevealMode` 的两个注入点
/// （`EdgeDockController.popoverContent`、`HarnessUsageMenuView.cardRevealMode`）
/// **都写死 `.alwaysVisible`**，没有任何渲染宿主会读到 `.onHover`，于是每条以
/// `mode` 为参数的判据在生产路径上都恒为常量。
enum ProviderCardLayout {
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

    // 已删除的四条（连同它们守护的菜单分支）：`hoistsResetCredits`、
    // `hoistsPeakIndicator`、`hidesHeaderStatusDot`、`splitsIntoTwoCards`。
    //
    // 它们的消费方**全在 `ProviderCardView.swift` 内**，而菜单侧那条 `.onHover`
    // 分支已经随 `menuBody` 一起没有渲染方了：重置卡与高峰期倒计时改由卡片层
    // 无条件绘制，标题行的状态点不再画，卡片恒为「两张卡 + 标题在卡外」。
    // 规则还在、却永远只取到 `true`，测试再断言它返回 `true` 就是三方一起给假
    // 信号——这正是当初 `expandsAccountSection` 被拆掉时的同一个组合。

    // 同一轮删掉的另外三条：消费方在 `QuotaViews` / `QuotaHoverViews`，不在本文件
    // 内，所以是**先核实宿主、再就地内联恒定值**，而不是连消费点一起删。逐条结论：
    //
    // 1. `liftsProgressBar(mode:)`（恒 `true`）——消费方四处：
    //    `ChatGPTPlanModelRow.isDockLayout`、`CombinedQuotaWindowRow.isDockLayout`、
    //    `CombinedQuotaMetadataLine.clustersAtTrailingEdge`、
    //    `SingleQuotaMetadataLine.clustersAtTrailingEdge`。前两处的宿主就是本卡片
    //    （`.alwaysVisible`）；后两处既在 dock 的 `QuotaBarWithMetadata` 里（活的），
    //    也在 `QuotaCombinedUsageRow` / `QuotaSingleUsageRow` 里（这两个只出现在 model
    //    行的 `menuLayout`，菜单不渲染 provider 卡后已无宿主）。四处都内联成常量。
    // 2. `splitsCachedInputRow(mode:)` / 3. `splitsRoundsRow(mode:)`（恒 `true`）——
    //    消费方是 `UsageMetricHoverSummaryView`。它有一处**活的**卡内宿主：
    //    `CombinedQuotaWindowRow.dockBlock` 里的 `OffPeakUsageFootnote`（GLM 闲时用量
    //    那条脚注），确实在 dock 浮层里渲染；另一处是
    //    `QuotaUsageWindowColumn`（只从 `menuLayout` 那条路来）。同样内联成常量。
    //
    // 为什么留着一个恒真的分支不继续删：内联之后 `isDockLayout` 恒真，
    // `menuLayout` 成了跑不到的一支，但把它连同 `QuotaCombinedUsageRow` /
    // `QuotaSingleUsageRow` / `QuotaWindowsHoverView` / `LastPromptHoverSummaryView`
    // 这一整族视图一起删掉是一次独立的清理（跨三个文件、几百行），不该挂在这次
    // 收敛上。新的渲染宿主若要换形态，届时是**恢复分支**而不是从死代码里挑。
}

/// provider 卡片 — 一个 provider 的全部信息
///
/// `Equatable`：卡片渲染依赖 `status`（值类型）**和** `@Environment(\.hoverRevealMode)`
/// ——后者由**后代**读（`HoverInfoRow` 决定就地展开还是折叠），本视图自己已经不读了
/// （见 `ProviderCardLayout`：所有按 mode 分叉的排版判据都已收敛成常量）。配合调用点
/// 的 `.equatable()`，任一 provider 的任一状态变化只会重算真正变化的那几张卡，
/// 而不是整屏菜单面板。
///
/// ⚠️ `==` 只比较 `status`，**不**比较 `revealMode` —— 它是 Environment，取不到。
/// 保留这条注释是因为比较仍然只按 `status` 走：菜单里已无 provider 卡，而唯一两个
/// 宿主（dock 浮层、菜单兜底行的 hover 卡）都是每次重建 `rootView` / 直接新建视图，
/// 不走任何跨帧缓存。将来若有人在仍可能出现两种 mode 的地方加 `.equatable()`，
/// 就必须把 `revealMode` 也纳入比较。
struct ProviderCardView: View, Equatable {
    let status: ProviderStatus

    /// 卡片内容层四周的内边距。`EdgeDockTheme.popoverWidth` 推导宽度时要加上
    /// 这一层的两侧，所以提出成常量，避免两处各写一个 12 改一漏一。
    ///
    /// `nonisolated`：View 结构体因 View 协议推断为 @MainActor，而这个常量要被
    /// 非隔离的 `EdgeDockTheme`（几何推导）读。值是编译期字面量、无隔离状态依赖，
    /// 声明成非隔离即可——Swift 6 下原写法只是一条 warning，Swift 7 会变成 error。
    nonisolated static let contentPadding: CGFloat = 12

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
        dockBody(projection: projection)
    }

    /// **两张卡片**，各自的标题画在卡片**外面**的上方。
    ///
    /// 切分点不是新划的：额度那一组是"现在"、7 天用量那一组是"历史"，两者之间
    /// 本来就有 `HoverInfoRow` 的那条分隔线。卡片边界取代它之后，两组各自是一张
    /// 有边界的卡，下半截不会再被读成上半截的附表。
    ///
    /// 这里曾经是 `if splitsIntoTwoCards(mode:) { dockBody } else { menuBody }`。
    /// 菜单改成客户端视角后 `menuBody`（单卡 + 卡内标题 + 账号折叠区）没有任何
    /// 渲染方，判据也随之失去意义——**唯一剩下的形态就是这一种**，所以直接
    /// 渲染，不再假装还有第二种。
    ///
    /// 标题 1 就是卡片头部那一行（品牌图标 + provider 名 + 套餐胶囊，右侧是
    /// 刷新时间/状态），它被提到卡外，于是"第一张卡是什么"由它回答，不再需要
    /// 额外的「额度」小标题。
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
                    quotaWindowUsage(info: info, projection: projection)
                    localUsage(projection: projection, part: .summary)
                }
                dockSectionTitle(projection: projection)
                dockCard {
                    localUsage(projection: projection, part: .detail)
                }
            } else {
                dockCard {
                    // `between` 在这里**同样**要传：重置卡与高峰期倒计时一律由卡片层
                    // 画（`QuotaSummary` 不再自己画）。曾经只在 `.ok` 分支传，
                    // `.loading` / `.failed` 的回退路径忘了——那两种状态下谁也不画，
                    // 两头落空。`.loading` 每次刷新都会短暂出现（`AppState` 在每次
                    // `refreshProviderDirectly` 开头就置位），于是重置卡和倒计时在浮层
                    // 里**每次刷新都闪一下**；`.failed` 则是一直不见。缓存额度还在的
                    // 时候（正是需要看"上次剩多少"的时候）丢信息最亏。
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
    ///
    /// 线**之下**先是「额度窗口用量」区块（见 `quotaWindowUsage`）再是本地用量
    /// footer：前者虽然讲的是额度窗口，数据仍然来自本机扫描，放到线上会把
    /// "额度来自接口" 这条约定作废。
    private var quotaUsageDivider: some View {
        Divider().opacity(0.45).padding(.vertical, 3)
    }

    /// 「额度窗口用量」区块（条 + 每个窗口一行短指标 + 明细）。
    ///
    /// 位置：**额度区之后、本地用量 footer 之前**，紧跟那条分隔线。它与下面
    /// 「今天 / 最近 7 天」的区别是时间尺度——那两处讲"最近 24 小时 / 7 天"，
    /// 这里讲"**当前这一轮额度窗口**"，也就是额度行那条百分比对应的同一段时间。
    /// 放在分隔线**之下**是因为它的数据仍然来自本机会话扫描：那条线的语义是
    /// "上面来自 provider 接口、下面来自本地扫描"，把这个区块放到线上面会让
    /// 读者把本机 token 数当成额度接口返回的数。
    ///
    /// 余额型 provider（DeepSeek，没有额度窗口）整块不画，见
    /// `QuotaWindowUsageSection` 的 `snapshot.isEmpty` 判据；重置卡的逐张明细与
    /// 账号信息搭同一个浮层（见该类型的 `resetCredits` / `account`）。
    ///
    /// **这一处是 `QuotaWindowUsageSection` 唯一的构造点**：`.ok`、`.loading`、
    /// `.failed` 三条路径都走它，所以账号信息只在这里取一次，三条路径自动一致
    /// ——曾经那条 `quotaBetween` 就是漏了回退路径才让重置卡与倒计时在浮层里
    /// 每次刷新闪一下。
    @ViewBuilder
    private func quotaWindowUsage(info: QuotaInfo, projection: ProviderUsageProjection) -> some View {
        let snapshot = quotaWindowUsageSnapshot(info: info, projection: projection)
        // 品牌色与卡片描边（`accentColor`）同源：它本来就是额度那一组的一部分。
        QuotaWindowUsageSection(
            snapshot: snapshot,
            tint: accentColor,
            resetCredits: info.resetCredits,
            // 菜单那张卡的账号折叠区删掉之后，账号从所有 UI 入口消失（整个
            // `AccountHoverViews` 一度没有调用方），现在搭这个浮层。没有账号概念的
            // provider 返回 nil，那一段不画。
            account: QuotaWindowAccountInfo.make(
                providerKind: status.kind,
                accountEmail: info.accountEmail,
                planLabel: info.planLabel
            )
        )
    }

    /// 区块数据：各 active model 的窗口用量按 provider 合计。
    ///
    /// 口径**完全**取自额度行——窗口边界走 `LocalUsageSummaryBuilder.windowBounds`
    /// （同 `CombinedQuotaWindowRow.primaryUsage` / `weeklyUsage`），GLM 闲时排除
    /// 走同一个 `excludeWindows` + `excludeGlmOffPeak`，ChatGPT 走
    /// `ChatGPTPlanModelRow` 的预聚合口径。多 model 求和的理由见
    /// `LocalUsageSummaryBuilder.combineWindowUsage`。
    private func quotaWindowUsageSnapshot(
        info: QuotaInfo,
        projection: ProviderUsageProjection
    ) -> QuotaWindowUsageSnapshot {
        let snapshots = info.activeModels.map { model -> QuotaWindowUsageSnapshot in
            // ChatGPT 的窗口用量由 codexUsageDetails 预聚合（再补 OpenCode 来源），
            // 那些样本已被统计过一次，不能再从 samples 重算一遍。
            let overrides = status.kind == .codexChatGpt
                ? ChatGPTPlanModelRow.windowUsages(
                    model: model,
                    usageDetails: info.codexUsageDetails,
                    samples: projection.recentSamples
                )
                : (interval: nil, weekly: nil)
            return LocalUsageSummaryBuilder.windowUsage(
                model: model,
                providerKind: status.kind,
                samples: projection.recentSamples,
                intervalLabel: QuotaSummary.primaryWindowLabel(providerKind: status.kind, model: model),
                weeklyLabel: QuotaSummary.weeklyWindowLabel(),
                intervalFallbackSeconds: CombinedQuotaWindowRow.primaryFallbackSeconds(
                    providerKind: status.kind,
                    model: model
                ),
                excludeWindows: excludeWindows,
                excludeGlmOffPeak: status.kind == .glmCodingPlan,
                intervalUsageOverride: overrides.interval,
                weeklyUsageOverride: overrides.weekly,
                quotaProviderID: status.kind.quotaProviderID,
                deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
            )
        }
        return LocalUsageSummaryBuilder.combineWindowUsage(snapshots)
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
            resetCreditsRow
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
    /// 只给 dock 的详情浮层用。那条路已经撤掉了——两个宿主（dock 浮层、菜单兜底行
    /// 的 hover 卡）用**同一张卡片**，"卡片长什么样"不该再有一个按调用方分叉的开关。
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

    /// **高峰期倒计时**。只 GLM 与 DeepSeek 有窗口概念。
    ///
    /// 它排在进度条下方（`dockQuotaSummaryRows`）：它回答"现在能不能便宜
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
    /// `revealsDetail: false`——浮层不吃鼠标事件，`HoverInfoRow` 在
    /// `alwaysVisible` 下又总会展开，每张卡的明细会变成常驻；折叠态那一句才是
    /// 该常驻的信息。
    ///
    /// 它只由卡片层画（`dockQuotaSummaryRows`），且是那张卡的第一个元素：卡片
    /// 边界已经在它上方，再画一条分隔线就是卡片顶部悬着一条横线。曾经这里有个
    /// `divides:` 参数给"菜单里紧跟标题行"的那条分隔线，菜单那份渲染方删掉后
    /// 恒为 `false`，参数随之删除。
    @ViewBuilder
    private var resetCreditsRow: some View {
        if let info = status.lastSuccess,
           let resets = info.resetCredits,
           resets.shouldDisplay {
            CompactResetCreditsRow(
                resets: resets,
                refreshIntervalSeconds: status.refreshIntervalSeconds,
                revealsDetail: false
            )
        }
    }

    private var headerContent: some View {
        HStack(spacing: 8) {
            // 标题行不画状态点：它紧挨着品牌图标，两个小圆挤在一起读起来
            // 是"图标带了个绿点"，而状态本身在右侧那颗胶囊里已经写清楚了。
            // （曾经由 `ProviderCardLayout.hidesHeaderStatusDot` 决定，菜单那份
            // 渲染方随 `menuBody` 一起删掉之后判据恒为 true，故一并删除。）
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

    @ViewBuilder
    /// `quotaBetween`：卡片级信息（重置卡 + 高峰期倒计时），由 `dockBody` 组装
    /// 后夹在进度条与用量之间。`.loading` / `.failed` 两条非 `.ok` 分支也必须传，
    /// 否则那两种状态下谁也不画（`.loading` 每次刷新都短暂出现，两头落空会让
    /// 重置卡与倒计时在浮层里**每次刷新闪一下**；`.failed` 则是一直不见）。
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
                    quotaWindowUsage(info: last, projection: projection)
                    localUsage(projection: projection, part: .combined)
                }
            } else {
                placeholder("正在获取…")
            }
        case .ok(let info):
            VStack(alignment: .leading, spacing: 6) {
                quotaSection(info: info, projection: projection, between: quotaBetween)
                quotaWindowUsage(info: info, projection: projection)
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
                        // 与 `.loading` 那一支同源，别漏。重置卡与高峰期倒计时**只**由
                        // 这一格提供（`QuotaSummary` 不再自己画，`quotaSection` 里的
                        // GLM 倒计时这条路也已撤掉）。
                        // 失败时恰恰最该看到它——用户要知道的是"上次还剩多少、
                        // 什么时候回补"，而这条 `lastSuccess` 正是那份数据的来源。
                        betweenBarAndColumns: quotaBetween
                    )
                        .opacity(0.55)
                    quotaWindowUsage(info: last, projection: projection)
                    localUsage(projection: projection, part: .combined)
                }
            }
        }
    }

    /// 「额度」这一段：额度窗口 + GLM 活动套餐余额。
    ///
    /// 抽出来只为一件事：让"卡片把它放进第一张、`.ok` 与否各走各的"这个分叉落在
    /// **这一段的外面**。两种调用各写一遍 `QuotaSummary` 调用，改参数时漏一处不会
    /// 编译报错，只会让某一种状态悄悄少一个参数。
    ///
    /// GLM 闲时峰值倒计时**不在**这里画：它由卡片层无条件提供（`peakIndicator`
    /// 经 `dockQuotaSummaryRows` 夹在进度条下方）。曾经这里有一支
    /// `!hoistsPeakIndicator` 的菜单分支——菜单那份渲染方删掉后它永远为 false，
    /// 于是同一个倒计时会出现两次。
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
            if status.kind == .glmCodingPlan {
                GlmActivityPlanBalancesView(balances: status.glmLocalUsage?.activityPlanBalances)
            }
        }
    }

    /// GLM 闲时任务窗口（仅 `.glmCodingPlan`）。额度窗口 hover 统计排除这些窗口内的 sample，
    /// 本地 token 柱图仍保留。其他 provider 恒为空。
    ///
    /// 必须按 kind 取：ZCode 是一份多 provider 账本，同一份 `glmLocalUsage` 现在也挂在
    /// MiniMax / DeepSeek 卡上（只为了读 `providerSlices`）。闲时窗口只属于智谱任务，
    /// 泄漏到其它卡会让落在窗口内的 MiniMax / DSH 样本被误判成闲时任务而排除。
    private var excludeWindows: [GlmOffPeakWindow] {
        guard status.kind == .glmCodingPlan else { return [] }
        return status.glmLocalUsage?.offPeakWindows ?? []
    }

    /// 所有卡片统一展示 quota provider 关联的客户端 token 汇总；客户端来源
    /// 只保留在 hover 明细中，避免卡片主体出现复杂的多来源信息。
    ///
    /// - Parameter part: 这一块被拆进两张卡片（汇总进上一张、图表进下一张），
    ///   拆法见 `LocalUsagePart`。
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
            isTruncated: projection.isTruncated,
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
        isTruncated: Bool,
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
            isTruncated: isTruncated,
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
            // 「未配置」而不是「未启用」：`.notConfigured` 覆盖五种原因（缺配置块、
            // 缺 Key、缺外部 auth、缺登录……），其中只有一种是"被禁用"。写「未启用」
            // 会让"已启用但还没填 Key"读成"我把它关了"，而同一行下面的原因文案
            // 恰恰说的是缺 Key——同一张卡里两句话互相打架。
            return Presentation(title: "未配置", tone: .secondary)
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

/// 额度摘要：每个 model 一组。**重置卡与高峰期倒计时不在这里**——它们是
/// provider 级的信息，一律由卡片层画（`ProviderCardView.dockQuotaSummaryRows`），
/// 经 `betweenBarAndColumns` 夹在第一个 model 行的进度条下方。
struct QuotaSummary: View {
    let info: QuotaInfo
    let providerKind: ProviderKind
    let accentColor: AccentColor
    let localSamples: [LocalTokenUsageSample]
    /// R3: reset credits 过期判定用到的刷新间隔（秒）。卡片层那张重置卡自己也会
    /// 传同一个值（`ProviderCardView.resetCreditsRow`）。
    var refreshIntervalSeconds: Int = 300
    /// 额度窗口 hover 统计需要排除的时间窗口（GLM 闲时任务不消耗积分）。
    /// 本地 token 柱图不走这条路径，仍包含闲时任务。
    var excludeWindows: [GlmOffPeakWindow] = []
    /// DeepSeek 高峰期窗口（仅 `.deepseek` 用到；其余 provider 用默认值占位）。
    var deepseekPeakWindow: DeepseekPeakWindow = .defaultWindow
    /// 夹在「进度条块」与「本地用量」之间的卡片级信息（重置卡、高峰期），
    /// 由 `ProviderCardView.dockBody` 组装。
    var betweenBarAndColumns: AnyView = AnyView(EmptyView())

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
                        // 高峰期倒计时一律由卡片层画，余额行里不再重复。
                        // 曾经是 `!hoistsPeakIndicator`，菜单那份渲染方删掉后恒为 false。
                        showsPeakIndicator: false,
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
            // `index == 0` 上的——它会跟着一起消失。那块（重置卡 + 高峰期）是
            // "这个 provider 还剩多少、什么时候回补"的**唯一**出处，丢了就只剩
            // 一张空卡。
            if displayedModels.isEmpty {
                betweenBarAndColumns
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
