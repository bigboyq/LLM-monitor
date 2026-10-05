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
    // 后续（独立的一次清理）：上面 1. 的前两处 `isDockLayout` 连同恒假的 `else`
    // 分支（`menuLayout`）一起删除，两个 model 行的 body 直接渲染 dock；随之删除的
    // 独占子视图是 `QuotaCombinedUsageRow` / `QuotaSingleUsageRow` /
    // `QuotaWindowTitle` / `LastPromptHoverSummaryView`。
    // `QuotaWindowsHoverView` / `QuotaUsageWindowsHoverView` /
    // `QuotaUsageWindowColumn` / `SingleQuotaWindowHoverView` 同样失去了渲染宿主，
    // `QuotaWindowsHoverView` 族（连同量宽测试）已随后续清理一并删除，
    // 故**保守保留整族**（见 `QuotaViews.swift` 的对应注释）。新的渲染宿主若要换
    // 形态，届时是**恢复分支**而不是从死代码里挑。
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

    /// 「今」行取哪一天：宿主注入的展示时钟（随浮层显隐起停），与卡内其它
    /// 倒计时/新鲜度消费者同一个 now，不取渲染时的墙钟。
    @Environment(\.displayDate) private var displayDate

    // 卡片内容层四周的内边距搬到了 `LayoutMetrics.cardContentPadding`：
    // `EdgeDockTheme.popoverWidth` 推导宽度时也要读它，声明留在这个 View 里会
    // 让 Services 反向依赖视图层。

    // nonisolated：View 结构体因 View 协议推断为 @MainActor，而 Equatable 的 ==
    //  witnesses 必须可从任意隔离域调用；status 是 Sendable 值类型，非隔离比较安全。
    nonisolated static func == (lhs: ProviderCardView, rhs: ProviderCardView) -> Bool {
        lhs.status == rhs.status
    }

    var body: some View {
        // 派生值（投影 / 额度窗口快照 / 「今」行）由 `ProviderCardDerivedValues`
        // 统一算：它们只由 `status` 与两个"今天"决定，而 body 在展示时钟的 1s
        // tick 里每秒重 eval —— 每次都真算就是把 O(samples) 的归桶 + 逐条计价
        // （DeepSeek 还要逐条判北京时间峰谷）在 DSH 的数万条样本上重跑一遍。
        // memo 之后只有输入真的变了才重算，数值与口径一字未改。
        let derived = ProviderCardDerivedValues.resolve(status: status, displayDate: displayDate)
        dockBody(derived: derived)
    }

    /// **三段式**：段1「Account Info」行 → 段2「Plan详情」+ 四个模块 →
    /// 段3「最近7天token用量」卡。前两段住第一张卡，段3 独立成卡。
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
    /// 标题体系（第三轮改版）：标题 1 就是卡片头部那一行（品牌图标 + provider 名，
    /// 右侧是刷新时间/状态），套餐 pill 已从 header 挪进段1 的账号行
    /// （`QuotaWindowAccountInfoRow`）；**账号行本身不加标题**。段2 的段落标题
    /// 「Plan详情」画在卡内（`planModules` 开头）；标题 2 是段3 的
    /// 「最近7天token用量」，右侧同一行放数据新鲜度（更新于 / 计算中…）——
    /// 段3 标题在卡外，段2 标题在卡内，两者都是 13pt 卡片标题级或 11pt 段落级，
    /// 压过模块标题（10pt secondary）。
    ///
    /// 段2 的四个模块（进度条 / token用量统计值 / token用量原始值 / 重置卡）由
    /// `planModules` 组装，各模块按数据可用性显隐；`.loading` / `.failed` 的回退
    /// 路径走 `content`，**同样**要拼出账号行与这四个模块——`.loading` 每次刷新
    /// 都会短暂出现，漏掉任何一段都会让它在浮层里**每次刷新闪一下**。
    ///
    /// 非 `.ok` 状态（读取中 / 失败 / 未配置）没有第二张卡可切，退回单卡：硬拆会
    /// 得到"第二张卡片只有一个占位提示"的空壳。
    @ViewBuilder
    private func dockBody(derived: ProviderCardDerived) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            headerContent
            if case .ok(let info) = status.state {
                dockCard {
                    accountInfoRow(info: info)
                    planModules(info: info, derived: derived)
                }
                dockSectionTitle(projection: derived.projection)
                dockCard {
                    localUsage(projection: derived.projection, part: .detail)
                }
            } else {
                dockCard {
                    content(derived: derived)
                }
            }
        }
    }

    /// 段1「Account Info」：账号名 + 账号级别 pill 的一行，无段落标题。
    ///
    /// 可见性判定**只在** `QuotaWindowAccountInfo.make`：codexChatGPT / antigravity
    /// 有邮箱（+ 套餐），glmCodingPlan 仅套餐档位，deepseek / minimaxTokenPlan
    /// 返回 nil → 整行不画。行后面跟一条细分隔线，把"账号是谁"与"额度还剩多少"
    /// 分成两段；整行隐藏时分隔线跟着消失，卡顶不会悬一条没有上文的线。
    /// `.failed` 没有缓存数据（`lastSuccess == nil`）时同样整行不画。
    @ViewBuilder
    private func accountInfoRow(info: QuotaInfo?) -> some View {
        if let account = info.flatMap({
            QuotaWindowAccountInfo.make(
                providerKind: status.kind,
                accountEmail: $0.accountEmail,
                planLabel: $0.planLabel
            )
        }) {
            QuotaWindowAccountInfoRow(info: account)
            QuotaModuleSeparator()
        }
    }

    /// 段2「Plan Info」的四个模块，按序：
    /// 0. **段落标题「Plan详情」**——账号行分隔线之后、进度条区之前。三段里只有
    ///    账号行不配标题（它本来就是一行）；这个标题与段3 的「最近7天token用量」
    ///    同为段落级，但住在卡内（段3 的标题在卡外），层级压过模块标题：
    ///    11pt semibold（`hoverRowEmphasis`）对 10pt semibold secondary（`QuotaModuleTitle`，
    ///    第四轮起模块标题也加重字重，但字号与颜色仍在段落标题之下）。
    /// 1. **进度条**——每模型配额行原样（元信息行、分段条、GLM 闲时脚注、
    ///    ChatGPT / DeepSeek 专属行）；高峰期倒计时仍由 `between` 夹在第一个
    ///    model 行的进度条下方。曾经挂在同一位置的 `CompactResetCreditsRow`
    ///    已摘走，挪到模块4。
    /// 2. **额度窗口（分析/用量可切换）** + 3. **重置卡信息**——
    ///    都在 `quotaWindowUsage` 的「额度窗口用量」区块里，与额度区之间隔着
    ///    `quotaUsageDivider`；模块标题（额度窗口 / 重置卡详情）由 `QuotaWindowUsageSection` 内部画。
    @ViewBuilder
    private func planModules(info: QuotaInfo, derived: ProviderCardDerived) -> some View {
        planSectionTitle
        quotaSection(info: info, derived: derived, between: AnyView(peakIndicator))
        quotaWindowUsage(info: info, derived: derived)
    }

    /// 段2 的段落标题。文案常量给测试引用；样式是段落级：11pt semibold、主色。
    static let planSectionTitleText = "Plan详情"

    private var planSectionTitle: some View {
        Text(Self.planSectionTitleText)
            .font(MenuTypography.hoverRowEmphasis)
            .foregroundStyle(Color.primaryLabel)
    }

    /// 第一张卡片里，"额度"与"额度窗口用量区块"之间的那条线。
    ///
    /// 两条线两侧的数据源不同：额度条来自 provider 接口，窗口用量来自本机会话
    /// 扫描。没有这条线，`5h 173M · 命中 …` 会被读成额度的延续。
    ///
    /// 它画在**卡片层**而不是每个 model 块里：三列明细撤掉后块内只剩额度本身，
    /// 而这条线要横跨所有 model（Antigravity 有两个），每块各画一条会在两个块
    /// 之间叠成两条挨着的线。样式与 7 天图表下方那条同款（同色、同不透明度、
    /// 整行宽、不额外缩进），上下间距 6 + 3 = 9pt，两条线在屏幕上读起来是同一条。
    ///
    /// 只在「额度窗口用量」区块至少有一个模块可见时才画（判定在
    /// `quotaWindowUsage`）：整块隐藏时不能在卡里悬一条没有下文的线。
    private var quotaUsageDivider: some View {
        Divider().opacity(0.45).padding(.vertical, 3)
    }

    /// 「额度窗口用量」区块（统计值 / 原始值表 / 重置卡三个模块，全部常驻）。
    ///
    /// 位置：**额度区之后、7 天用量卡之前**，紧跟 `quotaUsageDivider`。它与下面
    /// 「最近 7 天」的区别是时间尺度——那里讲"最近 7 天"，这里讲"**当前这一轮
    /// 额度窗口**"，也就是额度行那条百分比对应的同一段时间。放在分隔线**之下**
    /// 是因为它的数据仍然来自本机会话扫描：那条线的语义是"上面来自 provider
    /// 接口、下面来自本地扫描"（重置卡虽来自接口，但它是额度条的补充，跟着区块走）。
    ///
    /// 各模块按数据可用性显隐；过滤后**什么都不剩**时整块（连同上面的分隔线）
    /// 不渲染——余额型 DeepSeek 没有额度窗口、没有重置卡，今行也不属于窗口区块
    /// （判定走 `QuotaWindowUsageSection.hasVisibleContent`：全零行跳过之后还有
    /// 可见行、或重置卡可用，分隔线才画）。
    ///
    /// **这一处是 `QuotaWindowUsageSection` 唯一的构造点**：`.ok`、`.loading`、
    /// `.failed` 三条路径都走它，所以今行与重置卡只在这里取一次，三条路径自动
    /// 一致——曾经那条 `quotaBetween` 就是漏了回退路径才让重置卡与倒计时在浮层里
    /// 每次刷新闪一下。
    @ViewBuilder
    private func quotaWindowUsage(info: QuotaInfo, derived: ProviderCardDerived) -> some View {
        let snapshot = derived.windowUsageSnapshot
        let today = derived.todayUsageRow
        let hasUsageModules = QuotaWindowUsageSection.hasVisibleContent(
            snapshot: snapshot,
            today: today,
            resetCredits: info.resetCredits
        )
        if hasUsageModules {
            quotaUsageDivider
            // 品牌色与卡片描边（`accentColor`）同源：它本来就是额度那一组的一部分。
            QuotaWindowUsageSection(
                snapshot: snapshot,
                tint: accentColor,
                today: today,
                resetCredits: info.resetCredits,
                refreshIntervalSeconds: status.refreshIntervalSeconds
            )
        }
    }

    /// 今行的行标签（第五轮改版从「今日」缩成「今」，与「5h」「周」同一长度档）。
    /// 测试钉住，改文案必须连测试一起改。行本身由 `ProviderCardDerivedValues`
    /// 产出（与投影是同一个 memo 值）。
    static let todayRowLabel = "今"

    /// **高峰期倒计时**。只 GLM 与 DeepSeek 有窗口概念。
    ///
    /// 它排在进度条下方（经 `planModules` 的 `between` 夹进第一个 model 行）：
    /// 它回答"现在能不能便宜用"，属于这一屏的额度概览，而不是卡片标题的一部分。
    /// 曾经与它并列的 `CompactResetCreditsRow`（重置卡折叠行）已摘走，挪进
    /// 「额度窗口用量」区块的重置卡模块（`QuotaWindowUsageSection`）。
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

    /// 一张卡片：内容 + 内边距 + 表面 + 描边。两张卡片共用同一份实现，
    /// 否则"两张卡长得不一样"这种偏差只能靠肉眼发现。
    ///
    /// `maxWidth: .infinity`：两张卡各自按内容宽度收缩时宽度会不一样（第二张
    /// 只有图表），堆在一起就是两块对齐不上的底；撑满浮层宽度才对齐。
    private func dockCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(LayoutMetrics.cardContentPadding)
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

    /// 卡片头部：品牌图标 + provider 名 + 右侧刷新状态。
    ///
    /// 套餐 pill **已从这里移除**（第二轮改版）：它挪进了卡片第一段「Account Info」
    /// 行（`QuotaWindowAccountInfoRow`），与账号邮箱组成同一行——账号是谁、
    /// 什么级别，本来就是同一个问题的两半。
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

    /// 卡片标题。一律走 `status.displayName`（provider 名）；套餐级别现在住在
    /// 段1「Account Info」行的 pill 里（见 `QuotaWindowAccountInfo.make`）。
    private var displayTitle: String {
        status.displayName
    }

    @ViewBuilder
    /// 非 `.ok` 状态（`.loading` / `.failed`）的回退卡内容。结构与 `.ok` 分支的
    /// 第一张卡一致：段1 账号行 → 段2 四个模块（额度条压暗示弱）→ 7 天图表。
    /// 曾经这里是 `quotaBetween` 参数从 `dockBody` 传进来的——重置卡与倒计时漏传
    /// 会在浮层里每次刷新闪一下；现在回退卡与 `.ok` 走同一批构造点
    /// （`accountInfoRow` / `quotaWindowUsage` / `peakIndicator`），不存在"另一条
    /// 路径忘了传"的缝隙。
    private func content(derived: ProviderCardDerived) -> some View {
        let projection = derived.projection
        switch status.state {
        case .notConfigured(let reason):
            notConfiguredView(reason: reason)
        case .ready:
            placeholder("准备就绪…")
        case .loading(let lastSuccess):
            if let last = lastSuccess {
                VStack(alignment: .leading, spacing: 6) {
                    accountInfoRow(info: last)
                    // 段2 标题与 `.ok` 路径同源：回退卡少一段，浮层每次刷新都会闪。
                    planSectionTitle
                    QuotaSummary(
                        info: last,
                        providerKind: status.kind,
                        accentColor: status.accentColor,
                        localSamples: projection.recentSamples,
                        refreshIntervalSeconds: status.refreshIntervalSeconds,
                        excludeWindows: excludeWindows,
                        deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow,
                        betweenBarAndColumns: AnyView(peakIndicator)
                    )
                    .opacity(0.5)
                    quotaWindowUsage(info: last, derived: derived)
                    localUsage(projection: projection, part: .detail)
                }
            } else {
                placeholder("正在获取…")
            }
        case .ok(let info):
            VStack(alignment: .leading, spacing: 6) {
                accountInfoRow(info: info)
                planModules(info: info, derived: derived)
                localUsage(projection: projection, part: .detail)
            }
        case .failed(let message, let lastSuccess):
            VStack(alignment: .leading, spacing: 6) {
                accountInfoRow(info: lastSuccess)
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
                    // 与 `.loading` 同理：段2 标题随额度段一起走，别在刷新时闪。
                    planSectionTitle
                    QuotaSummary(
                        info: last,
                        providerKind: status.kind,
                        accentColor: status.accentColor,
                        localSamples: projection.recentSamples,
                        refreshIntervalSeconds: status.refreshIntervalSeconds,
                        excludeWindows: excludeWindows,
                        deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow,
                        // 与 `.loading` 那一支同源，别漏。高峰期倒计时**只**由这一格
                        // 提供（`QuotaSummary` 不再自己画，`quotaSection` 里的 GLM
                        // 倒计时这条路也已撤掉）。失败时恰恰最该看到它。
                        betweenBarAndColumns: AnyView(peakIndicator)
                    )
                        .opacity(0.55)
                    quotaWindowUsage(info: last, derived: derived)
                    localUsage(projection: projection, part: .detail)
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
    /// GLM 闲时峰值倒计时**不在**这里画：它由卡片层提供（`peakIndicator` 经
    /// `between` 夹在进度条下方）。曾经这里有一支
    /// `!hoistsPeakIndicator` 的菜单分支——菜单那份渲染方删掉后它永远为 false，
    /// 于是同一个倒计时会出现两次。
    @ViewBuilder
    private func quotaSection(
        info: QuotaInfo,
        derived: ProviderCardDerived,
        between: AnyView = AnyView(EmptyView())
    ) -> some View {
        let projection = derived.projection
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
                GlmActivityPlanBalancesView(balances: status.glmActivityPlanBalances)
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
        ProviderCardDerivedValues.offPeakWindows(status: status)
    }

    /// 所有卡片统一展示 quota provider 关联的客户端 token 汇总；客户端来源
    /// 只保留在 hover 明细中，避免卡片主体出现复杂的多来源信息。
    ///
    /// 第二轮改版后卡片上只剩 `.detail`（段3 的图表）——曾经的 `.summary`
    /// 「今日使用情况」汇总行已摘除，其内容上移为「额度窗口用量」区块统计值里的
    /// 「今」行（`todayUsageRow`，同源同口径）。
    ///
    /// - Parameter part: 现在生产路径只传 `.detail`；其余 case 是
    ///   `LocalUsagePart` 的历史形态，见该类型的说明。
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
    /// 菜单打开期间由共享 DisplayClock 每秒 tick，确保不会跨过阈值却仍保留旧颜色。
    nonisolated static let timelineIntervalSeconds: TimeInterval = 1

    let status: ProviderStatus
    @Environment(\.displayDate) private var displayDate

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
        case .red: return .criticalTint
        }
    }
}

/// 额度摘要：每个 model 一组。**高峰期倒计时不在这里**——它是 provider 级的
/// 信息，由卡片层画（`ProviderCardView.peakIndicator`），经 `betweenBarAndColumns`
/// 夹在第一个 model 行的进度条下方。曾经与它并列的重置卡已挪进「额度窗口用量」
/// 区块的重置卡模块，`between` 现在只夹倒计时。
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
    /// 夹在进度条块下方的**卡片级**信息（高峰期倒计时），由
    /// `ProviderCardView.planModules` 组装。
    var betweenBarAndColumns: AnyView = AnyView(EmptyView())

    private var displayedModels: [ModelQuota] {
        info.activeModels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(displayedModels.enumerated()), id: \.offset) { index, model in
                // 卡片级信息（高峰期倒计时）只在**第一个** model 行上出现一次：
                // 它讲的是这个 provider 的整体情况，不是每个 model 一份；跟着每个
                // model 重复一次会读成"每个 model 各有一组倒计时"。
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
            // `index == 0` 上的——它会跟着一起消失。那块（高峰期倒计时）是
            // "现在能不能便宜用"的唯一出处，丢了就只剩一张空卡。
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
