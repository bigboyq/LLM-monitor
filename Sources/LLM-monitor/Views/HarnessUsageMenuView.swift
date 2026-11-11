import SwiftUI

/// 状态栏下拉菜单的 **Harness（客户端）视角**内容：顶部今日汇总，下面按客户端
/// 分段；模型细节可折叠。额度由同文件的紧凑 Provider 视图提供。
///
/// 与 `ProviderCardView`（Provider 视角）是**并列**的两套读法，不是替换关系：
/// 用量页回答"今天我在哪些客户端里烧了多少 token、命中率多少、值多少钱"。
/// 额度页独立回答"各 Provider 还剩多少"，不依赖边缘状态窗。
///
/// 用量客户端段按紧凑两行摘要呈现；展开模型行后展示 Prompt 速度范围。
/// 宽度与多行自然高度由 `HarnessUsageMenuViewTests` 覆盖。
struct HarnessUsageMenuView: View {
    let summary: HarnessTodaySummary
    /// fleet 汇总（§10.2）。nil（未启用联动）或单节点（`multiNode == false`）时
    /// 整棵树保持今天的单行形态——老用户看到的界面与现在逐字一致（§10.6 L）。
    var fleetSummary: FleetMenuSummary? = nil
    /// 当前 scope（全局/本机/节点）。scope 切换控件在**标题栏**（>4 项时是
    /// 「label + ellipsis」下拉）与**内容区第一行**（≤4 项时是分段控件，
    /// 见 `scopeRow`），本视图只按 scope 选内容。
    var activeScope: FleetScope = .local
    /// 远端节点选项（scope 切换控件的选项源）。空 = 未启用联动。
    var scopeChoices: [FleetNodeChoice] = []
    /// scope 切换回调（宿主注入：写 `AppState.fleetScope`）。
    var onScopeChange: (FleetScope) -> Void = { _ in }
    /// 当前 scope 为具体节点时的菜单汇总（宿主注入；nil 时该节点无数据）。
    var nodeSummary: FleetMenuSummary? = nil
    /// 段头右键「刷新 <客户端名>」：按该段今日贡献行刷新涉及的 provider 卡。
    /// 动作实现由 `MenuContentView` 注入（它持有 `AppState`）。
    var onRefreshSection: (HarnessSection) -> Void = { _ in }
    /// fleet 汇总可用且多于一个节点时启用双行 + 节点分组形态。
    private var fleetMenuActive: Bool { fleetSummary?.multiNode == true }

    var body: some View {
        VStack(alignment: .leading, spacing: HarnessUsageMenuView.sectionSpacing) {
            // scope 切换的分段形态：选项 ≤4（全局 + 本机 + 远端节点）时，
            // 标题栏放不下四段分段控件，改在这里占一整行——「今日」卡片上方，
            // 宽度与那张卡片一致。>4 项时它在标题栏右侧（下拉形态），本行不出现。
            scopeRow
            if fleetMenuActive, activeScope == .fleet, let fleet = fleetSummary {
                if Self.isUnavailableFleetSelection(scope: activeScope, summary: fleet) {
                    unavailableScopeOverview(label: "今日", notice: fleet.dailyNotice)
                } else {
                    scopeOverview(
                        label: "今日",
                        tokens: fleet.fleetTotals.tokens,
                        hitRate: fleet.fleetTotals.hitRate,
                        valueText: fleet.fleetTotals.valueText,
                        segments: fleet.sections.map(HarnessClientSegment.init(clientSection:))
                    )
                    if let notice = fleet.dailyNotice { fleetNotice(notice) }
                    if fleet.sections.isEmpty { emptyTodayState } else {
                        ForEach(fleet.sections) { section in
                            FleetClientSectionView(
                                section: section,
                                onRefreshClient: { clientID in onRefreshSectionForClient(clientID) }
                            )
                        }
                    }
                }
            } else if fleetMenuActive, activeScope == .local, fleetSummary != nil {
                scopeOverview(
                    label: "今日",
                    tokens: summary.totalTokens,
                    hitRate: summary.cacheHitRate,
                    valueText: summary.valueText,
                    costParts: summary.heroParts,
                    segments: HarnessTodaySummary.clientSegments(from: summary.sections)
                )
                if summary.sections.isEmpty { emptyTodayState } else {
                    HarnessMetricColumns.columnHeader
                    ForEach(summary.sections) { section in
                        HarnessSectionView(
                            section: section,
                            onRefreshSection: onRefreshSection,
                            updateTime: summary.localUsageScannedAt
                        )
                    }
                }
            } else if fleetMenuActive, case .node = activeScope, let node = nodeSummary {
                if node.hasDailyData {
                    scopeOverview(
                        label: "今日",
                        tokens: node.fleetTotals.tokens,
                        hitRate: node.fleetTotals.hitRate,
                        valueText: node.fleetTotals.valueText,
                        segments: node.sections.map(HarnessClientSegment.init(clientSection:))
                    )
                    if let notice = node.dailyNotice { fleetNotice(notice) }
                    if node.sections.isEmpty { emptyTodayState } else {
                        ForEach(node.sections) { section in
                            FleetClientSectionView(section: section)
                        }
                    }
                } else {
                    unavailableScopeOverview(label: "今日", notice: node.dailyNotice)
                }
            } else if Self.isMissingNodeSelection(scope: activeScope, nodeSummary: nodeSummary) {
                Text("所选节点已不在当前同步快照中")
                    .font(MenuTypography.metricLabel)
                    .foregroundStyle(Color.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else if summary.sections.isEmpty {
                todayOverview
                emptyTodayState
            } else {
                // 联动关闭 / 只有本机节点时保持传统客户端视图，并保留顶部总览。
                todayOverview
                HarnessMetricColumns.columnHeader
                ForEach(summary.sections) { section in
                    HarnessSectionView(
                        section: section,
                        onRefreshSection: onRefreshSection,
                        updateTime: summary.localUsageScannedAt
                    )
                }
            }
        }
    }

    // MARK: - 全局今日汇总

    private static let dayMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    /// 将金额文本解析为主展示额与副标题（处理多币种混合情况）。
    /// 单一币种："¥385.0" -> primary: "¥385.0", subtitle: "今日花费"
    /// 混合币种："385.0（含$47.6）" -> primary: "¥385.0", subtitle: "折合总额（含$47.6）"
    /// 缺失："—" -> primary: "—", subtitle: "今日花费"
    static func heroCostParts(from valueText: String) -> (primary: String, subtitle: String) {
        if valueText == "—" {
            return ("—", "今日花费")
        }
        if let parenRange = valueText.range(of: "（含") {
            let rawPrimary = String(valueText[..<parenRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let breakdown = String(valueText[parenRange.lowerBound...])
            let primary = rawPrimary.hasPrefix("¥") || rawPrimary.hasPrefix("$") ? rawPrimary : "¥" + rawPrimary
            let subtitle = "折合总额" + breakdown
            return (primary, subtitle)
        }
        return (valueText, "今日花费")
    }

    private func hitRateBadge(_ hitRate: Double?) -> some View {
        HStack(spacing: 3) {
            Text("命中")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.secondaryLabel)
            Text(Self.hitRateText(hitRate))
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.primaryLabel)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    /// 统一的双焦点 Hero 今日汇总卡片：
    /// 顶栏（标题 + 命中率胶囊）+ 核心行（大号 Token 与大号金额）+ 客户端占比条与图例。
    private func heroOverviewCard(
        headerTitle: String,
        tokensText: String,
        hitRate: Double?,
        valueText: String,
        costParts: (primary: String, subtitle: String)? = nil,
        segments: [HarnessClientSegment]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(headerTitle)
                    .font(MenuTypography.metricLabel)
                    .foregroundStyle(Color.secondaryLabel)
                Spacer()
                hitRateBadge(hitRate)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tokensText)
                        .font(MenuTypography.todayHeroValue)
                        .foregroundStyle(Color.primaryLabel)
                        .lineLimit(1)
                    Text("今日总 Token")
                        .font(MenuTypography.todayHeroSubtitle)
                        .foregroundStyle(Color.secondaryLabel)
                }
                Spacer(minLength: 12)
                let cost = costParts ?? Self.heroCostParts(from: valueText)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(cost.primary)
                        .font(MenuTypography.todayHeroValue)
                        .foregroundStyle(Color.primaryLabel)
                        .lineLimit(1)
                    Text(cost.subtitle)
                        .font(MenuTypography.todayHeroSubtitle)
                        .foregroundStyle(Color.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            clientComposition(segments: segments)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
        )
    }

    private var todayHeaderTitle: String {
        let date = Self.dayMonthFormatter.string(from: summary.dayStart)
        return "今日 \(date)"
    }

    private var todayOverview: some View {
        heroOverviewCard(
            headerTitle: todayHeaderTitle,
            tokensText: Formatters.formatTokenCountCompact(summary.totalTokens),
            hitRate: summary.cacheHitRate,
            valueText: summary.valueText,
            costParts: summary.heroParts,
            segments: HarnessTodaySummary.clientSegments(from: summary.sections)
        )
    }

    /// 总览卡的构成部分：占比条 + 图例。三个 scope 共用；零活动（无段）时只剩
    /// 纯灰底槽，图例整行不画。
    @ViewBuilder
    private func clientComposition(segments: [HarnessClientSegment]) -> some View {
        HarnessClientProportionBar(segments: segments)
        if !segments.isEmpty {
            HarnessClientLegend(
                segments: segments,
                totalTokens: segments.reduce(0) { $0 + max(0, $1.totalTokens) }
            )
        }
    }

    /// 客户端有本地账本、只是今天还没跑过模型时的占位。与上面"没注册 provider"
    /// 的两级空态是不同层级：数据在，只是今天为空。
    private var emptyTodayState: some View {
        Text("今日暂无 Token 用量")
            .font(MenuTypography.metricLabel)
            .foregroundStyle(Color.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
    }

    // MARK: - 排版常量

    /// scope 切换的**分段形态**一行：选项 ≤4 时占一整行，位于「今日」卡片上方。
    ///
    /// 宽度与那张卡片一致：下面的「今日」块是 `padding(.horizontal, 8)` **之后**
    /// 才画背景的，所以它的圆角矩形铺满内容区整宽（padding 在背景里面）；这一行
    /// 因此**不能再加这 8pt 内缩**——加了就比卡片窄一截，两边对不齐。
    @ViewBuilder
    private var scopeRow: some View {
        if fleetMenuActive,
           FleetScopeControlStyle.preferred(choices: scopeChoices) == .segmented {
            FleetScopeSwitcher(
                scope: activeScope,
                choices: scopeChoices,
                onSelect: { onScopeChange($0) },
                style: .segmented
            )
            .help(scopeChoices.isEmpty
                ? "切换显示范围：全局 / 本机"
                : "切换显示范围：全局 / 本机 / 各节点")
            .frame(maxWidth: .infinity)
        }
    }

    /// 统一的总览块：双焦点大字卡 + 客户端占比条 + 图例。
    /// 三个 scope 共用同一实现——样式、列宽、留白天然一致。段数据来自所选
    /// scope 的客户端段（本机 = 本地段；全局 / 节点 = fleet 合并段）。
    private func scopeOverview(
        label: String,
        tokens: Int,
        hitRate: Double?,
        valueText: String,
        costParts: (primary: String, subtitle: String)? = nil,
        segments: [HarnessClientSegment]
    ) -> some View {
        heroOverviewCard(
            headerTitle: label,
            tokensText: Formatters.formatTokenCountCompact(tokens),
            hitRate: hitRate,
            valueText: valueText,
            costParts: costParts,
            segments: segments
        )
    }

    /// Missing daily data has a distinct visual state. In particular, zero is not
    /// shown as a completed total when the fleet has not supplied today's bucket.
    private func unavailableScopeOverview(label: String, notice: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(label)
                    .font(MenuTypography.metricLabel)
                    .foregroundStyle(Color.secondaryLabel)
                Spacer()
                hitRateBadge(nil)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("—")
                        .font(MenuTypography.todayHeroValue)
                        .foregroundStyle(Color.secondaryLabel)
                    Text("今日总 Token")
                        .font(MenuTypography.todayHeroSubtitle)
                        .foregroundStyle(Color.secondaryLabel)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("—")
                        .font(MenuTypography.todayHeroValue)
                        .foregroundStyle(Color.secondaryLabel)
                    Text("今日花费")
                        .font(MenuTypography.todayHeroSubtitle)
                        .foregroundStyle(Color.secondaryLabel)
                }
            }
            fleetNotice(notice ?? "今日用量尚未同步")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
        )
    }

    private func fleetNotice(_ text: String) -> some View {
        Text(text)
            .font(MenuTypography.hint)
            .foregroundStyle(Color.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }

    /// 段头右键刷新按 clientID 路由到本机段（仅全局形态段头有右键）。
    private func onRefreshSectionForClient(_ clientID: String) {
        Self.refreshLocalSection(
            clientID: clientID,
            sections: summary.sections,
            onRefreshSection: onRefreshSection
        )
    }

    /// fleet 段头右键「刷新 <客户端名>」的路由（§10.2）。
    ///
    /// fleet 段头给的是 **clientID**，刷的是**本机**这一段：先把 clientID 翻译
    /// 成**本机**的段（`HarnessSection`，取自 `summary.sections`），再交回宿主的
    /// `onRefreshSection`——`MenuContentView.refreshSectionFromMenu` 按本段今日
    /// 贡献行刷新涉及的 provider 卡（`HarnessSection.refreshProviderStatusIDs`），
    /// 因此只动这个客户端的卡，不惊动别的 provider，也不去刷远端节点的数据。
    ///
    /// 本机没有这一段（该客户端今天只有远端数据）→ 什么都不做：不改刷别的段，
    /// 不崩。
    ///
    /// 提成 `static` 是**测试缝**：`.contextMenu` 里的按钮没有可寻址的测试缝，
    /// 只能钉住"交出去给宿主的到底是哪一段"。
    static func refreshLocalSection(
        clientID: String,
        sections: [HarnessSection],
        onRefreshSection: (HarnessSection) -> Void
    ) {
        guard let section = sections.first(where: { $0.clientID == clientID }) else { return }
        onRefreshSection(section)
    }

    /// 命中率文案：分母为 0（没有 input / cacheRead）显示「—」。
    static func hitRateText(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return String(format: "%.0f%%", rate * 100)
    }

    /// 已选节点已从快照移除时不可回退显示本机数据。
    static func isMissingNodeSelection(
        scope: FleetScope,
        nodeSummary: FleetMenuSummary?
    ) -> Bool {
        if case .node = scope { return nodeSummary == nil }
        return false
    }

    static func isUnavailableFleetSelection(
        scope: FleetScope,
        summary: FleetMenuSummary
    ) -> Bool {
        scope == .fleet && summary.multiNode && !summary.hasDailyData
    }

    /// 段与段之间的间距。段内行距更紧（`HarnessModelRowView.rowSpacing`），
    /// 让"换了一个客户端"在视觉上比"换了一个模型"更明显。
    static let sectionSpacing: CGFloat = 10
    /// 今日总 token 列定宽。`1,041M`（六字符）是最宽的常见形态。
    static let totalWidth: CGFloat = 56
    /// 命中率列定宽（今日合计行的**裸值**）。`100%` 实测自然宽 30pt，留 2pt 余量。
    static let hitRateWidth: CGFloat = 32
    /// 段价值列定宽。与模型行的价值列同宽，两个"价值"数字右对齐成一条竖线。
    static let valueWidth: CGFloat = 56
}

/// 「今日合计」卡里的**客户端占比条**：一段一个今天有 token 活动的 harness，
/// 段宽 = 该客户端今日 token 占全部客户端的比例，段色 = 主力 quota provider 的
/// 卡 accent 色（`AccentColor.cardAccentColor`，与 provider 卡描边 / 进度条同源）。
///
/// 颜色取「主力」provider（今日 token 最大的一路）而不是按 provider 细分：一个
/// ZCode 段可能同时含智谱 / minimax / deepseek 分片，段内再切色会把占比条变成
/// 二维矩阵，读不回来。多 provider 构成在段下方的客户端段里有明细。
///
/// 取代了总览里原来的全局 input / cacheRead / output 三段条（`TokenBucketBar`
/// 仍在模型行上承担该职责）。零活动（无段）时只剩纯灰底槽。
///
/// 归一化口径与 `TokenBucketBar` 一致：负值按 0、Double 累加做分母、总量 ≤ 0
/// 全 0——保证任何输入（含总量 0 的 0/0 除法）不产生 NaN 或负宽。每段挂
/// `.help`：「MiniMax Code 355M（77%）」。
struct HarnessClientProportionBar: View {
    let segments: [HarnessClientSegment]

    /// 标准槽高：与 `TokenBucketBar` 同一根槽线（同一张卡里的条高不齐会很难看）。
    static let standardHeight: CGFloat = TokenBucketBar.standardHeight

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                HStack(spacing: 0) {
                    ForEach(Array(segmentFractions.enumerated()), id: \.offset) { pair in
                        Rectangle()
                            .fill(Self.tint(forQuotaProviderID: segments[pair.offset].dominantQuotaProviderID))
                            .frame(width: width * pair.element)
                            .help(Self.tooltipText(
                                for: segments[pair.offset],
                                totalTokens: segments.reduce(0) { $0 + $1.totalTokens }
                            ))
                    }
                }
                .frame(width: width, height: Self.standardHeight)
                .clipShape(Capsule())
            }
            .frame(width: width, height: Self.standardHeight)
        }
        .frame(height: Self.standardHeight)
    }

    /// 各段宽度占比（0...1），与 `segments` 同序。internal（非 private）：
    /// 纯计算、无渲染依赖，测试直接断言占比数学。
    var segmentFractions: [Double] {
        Self.fractions(for: segments)
    }

    /// 占比归一化：负值按 0，分母 Double 累加（多段 Int 饱和和会互相挤占，
    /// Double 对常规量级既不溢出也不产生 NaN），总量 ≤ 0 时全 0（纯灰底）。
    static func fractions(for segments: [HarnessClientSegment]) -> [Double] {
        let tokens = segments.map { max(0, $0.totalTokens) }
        let total = tokens.reduce(0.0) { $0 + Double($1) }
        guard total > 0 else { return Array(repeating: 0, count: segments.count) }
        return tokens.map { Double($0) / total }
    }

    /// 段色 = 主力 provider 的卡 accent 色。未知 / 缺失的 providerID 回退灰
    /// （与 `.custom` 同款——「不知道是谁」不该被读成某个品牌）。
    static func tint(forQuotaProviderID id: String?) -> Color {
        accent(forQuotaProviderID: id)?.cardAccentColor ?? .gray
    }

    /// quotaProviderID → AccentColor（纯函数，不带 UI 色，测试直接断言）。
    static func accent(forQuotaProviderID id: String?) -> AccentColor? {
        switch id {
        case QuotaProviderID.minimax: return .minimax
        case QuotaProviderID.openAI: return .chatgpt
        case QuotaProviderID.antigravity: return .antigravity
        case QuotaProviderID.zhipu: return .glm
        case QuotaProviderID.deepseek: return .deepseek
        default: return nil
        }
    }

    /// 段的 hover 文案：「MiniMax Code 355M（77%）」。总量为 0（空条）时退回
    /// 只有 token 数——0 做分母的占比没有意义。
    static func tooltipText(for segment: HarnessClientSegment, totalTokens: Int) -> String {
        let tokens = Formatters.formatTokenCountCompact(segment.totalTokens)
        let total = max(0, totalTokens)
        guard total > 0, segment.totalTokens > 0 else {
            return "\(segment.displayName) \(tokens)"
        }
        let percent = Formatters.formatPercent(Double(segment.totalTokens) / Double(total))
        return "\(segment.displayName) \(tokens)（\(percent)）"
    }
}

/// 占比条下的图例行：`<着色图标> MiniMax Code  <着色图标> Codex …`。图标即颜色
/// 载体（`tint(forQuotaProviderID:)` 与占比条段色同源），回答「哪种颜色是谁」——
/// 占比太小的段窄到点不到 tooltip，图例是那批客户端唯一的可读出口。
///
/// token 不进图例：下方每个客户端段的段头就有今日小计，图例只负责把颜色
/// 翻译回身份。chip 超出行宽**换行**（`WrapLayout`）而不是截断：被截掉的恰是
/// 占比最小的客户端，名字别处没有。最多 7 个注册客户端，两行内必然放得下。
struct HarnessClientLegend: View {
    let segments: [HarnessClientSegment]
    /// 全部段的今日合计（tooltip 占比文案的分母）。
    let totalTokens: Int

    var body: some View {
        WrapLayout(horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(segments) { segment in
                chip(segment)
            }
        }
    }

    private func chip(_ segment: HarnessClientSegment) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ClientDescriptor.iconSystemName(forClientID: segment.clientID))
                .font(.system(size: 10))
                .foregroundStyle(
                    HarnessClientProportionBar.tint(forQuotaProviderID: segment.dominantQuotaProviderID)
                )
            Text(segment.displayName)
                .font(MenuTypography.metricLabel)
                .foregroundStyle(Color.secondaryLabel)
                .lineLimit(1)
            if segment.totalTokens > 0 {
                Text(Formatters.formatTokenCountCompact(segment.totalTokens))
                    .font(MenuTypography.footerNumber)
                    .foregroundStyle(Color.secondaryLabel.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .help(HarnessClientProportionBar.tooltipText(for: segment, totalTokens: totalTokens))
    }
}

/// 最小流式布局：子视图放不进当前行就换到下一行。用于客户端图例 chip 与模型指标；
/// 普通项保持自然宽，只有单项本身宽过容器时才按容器宽度重测。
private struct WrapLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = Self.rowHeights(
            subviews: subviews, maxWidth: maxWidth, spacing: horizontalSpacing
        )
        let totalHeight = rows.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        let width = maxWidth.isFinite ? maxWidth : 0
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let item = Self.itemLayout(subview, maxWidth: bounds.width)
            let size = item.size
            if x > bounds.minX, x - bounds.minX + size.width > bounds.width {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: item.proposal)
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    /// 每行的行高（换行判定与 `placeSubviews` 同一条规则），供求总高。
    private static func rowHeights(
        subviews: Subviews, maxWidth: CGFloat, spacing: CGFloat
    ) -> [CGFloat] {
        var rows: [CGFloat] = []
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = itemLayout(subview, maxWidth: maxWidth).size
            if x > 0, x + size.width > maxWidth {
                rows.append(rowHeight)
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        if x > 0 { rows.append(rowHeight) }
        return rows
    }

    /// 普通项保持自然尺寸；只有比容器还宽的单项才按容器宽度重测与放置。
    /// 这让长模型名可以在首项内截断，同时不会把普通图例 chip 拉伸到整行。
    private static func itemLayout(
        _ subview: LayoutSubview,
        maxWidth: CGFloat
    ) -> (size: CGSize, proposal: ProposedViewSize) {
        let naturalSize = subview.sizeThatFits(.unspecified)
        guard maxWidth.isFinite, maxWidth > 0, naturalSize.width > maxWidth else {
            return (naturalSize, .unspecified)
        }
        let proposal = ProposedViewSize(width: maxWidth, height: nil)
        let proposedSize = subview.sizeThatFits(proposal)
        return (CGSize(width: min(proposedSize.width, maxWidth), height: proposedSize.height), proposal)
    }
}

/// 汇总行与模型行**共用**的字段级对齐指标簇（2026-11-07 用户裁定）。
///
/// 列宽固定、数值右对齐，harness 行与模型行共用同一组列 → 跨行字段对齐。
/// 列序与英文标题（2026-11-07 裁定，2026-11-08 加 TTFT；同日裁定 TTFT 与 Speed
/// 换位，TTFT 在前）：**Turns Token Hit Think TTFT Speed Value Update**。
/// 实测内容区 460pt（484 面板 − 2×12 内边距）装得下**并集**，按裁定取并集——量测锚见
/// `HarnessUsageMenuViewTests.testMetricClusterUsesUnionWithinBudget`。
/// 数值全部自带量纲（数量级后缀 / 货币符号 / % / tok/s），不再带字段标签；
/// 口径解释挂每格 `.help` 与表头。
enum HarnessMetricColumns {
    static let prompts: CGFloat = 30
    static let token: CGFloat = 38
    static let value: CGFloat = 46
    static let hitRate: CGFloat = 28
    static let thinking: CGFloat = 28
    /// TTFT 列（调用首字延迟 P50，秒）：数值 ≤ 4 字符（`0.86` / `12.5` / `124`），
    /// 34pt 放得下；宽度预算见 `clusterWidth` 与并集量测锚测试。
    /// 声明顺序即列序：在 Speed 之前（2026-11-08 换位裁定）。
    static let ttft: CGFloat = 34
    static let speed: CGFloat = 58
    static let spacing: CGFloat = 6
    /// harness 行右侧「Update」列（扫描时间）；模型行留空同宽，保证簇列跨行对齐。
    /// 宽度以放下表头标题「Update」为准（6 字符 ≈ 35pt）。
    static let timeSlot: CGFloat = 38
    static var clusterWidth: CGFloat {
        prompts + token + value + hitRate + thinking + ttft + speed + spacing * 6
    }

    /// Speed 格的 hover 文案：给**这一行的实际分布值**（Min / P50 / P95 / Max，
    /// 统一走 `Formatters.formatSpeed` 紧凑格式）；无有效样本时退回口径说明。
    /// 有效样本不全时追加「（valid/total 次调用有有效时长）」披露残缺统计——
    /// 与 `speedIsPartial` 同一披露语义。
    static func speedDistributionHelp(_ stats: CallSpeedStatistics) -> String {
        guard let p50 = stats.p50 else { return "单次有效调用解码速度 P50，单位 tok/s" }
        var text = "Min: \(Formatters.formatSpeed(stats.minimum))"
            + " · P50: \(Formatters.formatSpeed(p50))"
            + " · P95: \(Formatters.formatSpeed(stats.p95))"
            + " · Max: \(Formatters.formatSpeed(stats.maximum)) tok/s"
        if stats.validCallCount < stats.totalCallCount {
            text += "（\(stats.validCallCount)/\(stats.totalCallCount) 次调用有有效时长）"
        }
        return text
    }

    /// 并集七格。文本由调用方格式化；宽度固定保证跨行对齐。
    static func cluster(prompts: String, token: String, hitRate: String,
                        thinking: String, ttft: String, speed: String,
                        speedHelp: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            Text(prompts)
                .frame(width: Self.prompts, alignment: .trailing)
                .help("今日已记录 Prompt 数（含无有效时长的样本）")
            Text(token)
                .frame(width: Self.token, alignment: .trailing)
                .help("今日 Token（规范化四桶合计）")
            Text(hitRate)
                .frame(width: Self.hitRate, alignment: .trailing)
                .help("缓存命中率 = cacheRead / (input + cacheRead)")
            Text(thinking)
                .frame(width: Self.thinking, alignment: .trailing)
                .help("思考占比 = reasoning / (output + reasoning)")
            Text(ttft)
                .frame(width: Self.ttft, alignment: .trailing)
                .help("调用首字延迟 P50，单位秒")
            Text(speed)
                .frame(width: Self.speed, alignment: .trailing)
                .help(speedHelp)
            Text(value)
                .frame(width: Self.value, alignment: .trailing)
                .help("今日价值（行内单币种原额 / 汇总为混合币种折合）")
        }
        .font(MenuTypography.hint)
        .monospacedDigit()
        .foregroundStyle(Color.secondaryLabel)
        .lineLimit(1)
    }

    /// 数值列标题行：列宽与 `cluster` 一一对应（右对齐），插在客户端段列表
    /// 上方整表一次；去标签数值行靠它读懂列义。名称列留空占位。
    static var columnHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            // 名称列占位（与数据行的弹性名称列同构）——把标题簇推到与数据
            // 相同的右侧位置，否则表头会挤在行首、数据贴右缘，两相错位。
            Color.clear
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("Turns")
                .frame(width: prompts, alignment: .trailing)
                .help("今日已记录 Prompt 数（含无有效时长的样本）")
            Text("Token")
                .frame(width: token, alignment: .trailing)
                .help("今日 Token（规范化四桶合计）")
            Text("Hit")
                .frame(width: hitRate, alignment: .trailing)
                .help("缓存命中率 = cacheRead / (input + cacheRead)")
            Text("Think")
                .frame(width: thinking, alignment: .trailing)
                .help("思考占比 = reasoning / (output + reasoning)")
            Text("TTFT")
                .frame(width: ttft, alignment: .trailing)
                .help("调用首字延迟 P50，单位秒")
            Text("Speed")
                .frame(width: speed, alignment: .trailing)
                .help("单次有效调用解码速度 P50，单位 tok/s")
            Text("Value")
                .frame(width: value, alignment: .trailing)
                .help("今日价值（行内单币种原额 / 汇总为混合币种折合）")
            Text("Update")
                .frame(width: timeSlot, alignment: .trailing)
                .help("本地用量更新时间")
        }
        .font(MenuTypography.hint)
        .foregroundStyle(Color.secondaryLabel.opacity(0.72))
        .lineLimit(1)
        .padding(.leading, HarnessSectionView.treeIndent)
    }
}

/// 一个客户端段：树形层级（引导线树，2026-11-07 起取代原「方块卡片」）。
///
/// 第一级 = harness 行（▸/▾ 三角 + 图标 + 名称 + **同行汇总簇**……扫描时间，
/// 右键挂「刷新 <客户端名>」）；折叠即一行。截断提示独占缩进行；展开后
/// 第二级 = 模型行，每行带 ├─ 式短横刻线，与 harness 行共用 `HarnessMetricColumns`
/// 并集簇（字段级对齐），整块左侧一条竖引导线贯穿（底部截短约半行，近似 └ 形收尾）。
/// 同一模型落在多个 harness 时仍按数据结构各自在所属 harness 下展开
/// （`HarnessSection.rows` 本就按段嵌套）。
///
/// **internal 而非 private**：留下测试缝。`HarnessUsageMenuViewTests` 要真的把
/// 一个段布局一遍量高度与自然宽（列宽超预算、单个段撑爆菜单高度都只能这么抓），
/// 改回 private 就得把同样的量测挂在 `HarnessUsageMenuView` 上，量的就不再是
/// 真正被渲染的那棵树了。同一约定见 `SettingsView.clientProviderDisclosure`。
struct HarnessSectionView: View {
    let section: HarnessSection
    /// 段头右键「刷新 <客户端名>」：按本段今日贡献行刷新涉及的 provider 卡。
    var onRefreshSection: (HarnessSection) -> Void = { _ in }
    var updateTime: Date? = nil
    @State private var isExpanded = false

    // MARK: 树形几何常量（测试锚点，改动需同步 `HarnessUsageMenuViewTests`）

    /// 竖引导线的水平位置（≈ 展开三角形中轴）。
    static let guideX: CGFloat = 4
    /// 缩进块（今日摘要 / 截断提示 / 模型行）的左缩进。
    static let treeIndent: CGFloat = 14
    /// 模型行的 ├─ 短横刻线宽度。
    static let tickWidth: CGFloat = 7
    /// 引导线 / 刻线透明度（比 `MenuHairline` 的 8% 略深，缩进对照下要立得住）。
    static let guideOpacity: Double = 0.14
    /// 引导线底部收尾余量（≈ 半行高，画出 └ 形留白）。
    static let guideTailTrim: CGFloat = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { isExpanded.toggle() } label: {
                harnessRow
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("刷新本机 \(section.displayName)") { onRefreshSection(section) }
            }

            VStack(alignment: .leading, spacing: 2) {
                // 截断提示只在该段的数据源真的被截断时出现：数字本身仍然是"对"的，
                // 只是"不全"——不说就等于把一份残缺统计当完整统计读。
                if section.isTruncated {
                    truncationNotice
                } else if section.hasIncompleteSamples {
                    samplesTruncationNotice
                }
                if isExpanded {
                    if section.rows.isEmpty {
                        Text(section.sampleIntegrityNotice ?? "暂无模型明细")
                            .font(MenuTypography.hint)
                            .foregroundStyle(Color.secondaryLabel)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 2)
                    } else {
                        ForEach(section.rows) { row in
                            HarnessModelRowView(row: row)
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.primary.opacity(Self.guideOpacity))
                                        .frame(width: Self.tickWidth, height: MenuHairline.thickness)
                                        .padding(.leading, Self.guideX)
                                }
                        }
                        if let notice = section.sampleIntegrityNotice {
                            Text(notice)
                                .font(MenuTypography.hint)
                                .foregroundStyle(Color.secondaryLabel)
                                .padding(.top, 2)
                                .padding(.horizontal, 2)
                        }
                    }
                }
            }
            .padding(.leading, Self.treeIndent)
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.primary.opacity(Self.guideOpacity))
                    .frame(width: MenuHairline.thickness)
                    .padding(.leading, Self.guideX)
                    .padding(.bottom, isExpanded && !section.rows.isEmpty ? Self.guideTailTrim : 0)
            }
        }
        .padding(.vertical, 2)
    }

    /// 第一级 harness 行：展开三角 + 客户端图标 + 名称 + **同行汇总簇**……扫描时间。
    ///
    /// 汇总与模型行共用 `HarnessMetricColumns.cluster`（字段级对齐）；扫描时间
    /// 占固定尾槽，模型行留空同宽，两级行的列因此跨行对齐。右键菜单挂在
    /// **这一行**（不是整段）：菜单内容区现在是客户端视角，右键一个段名才是
    /// "针对这些数据"的语义；「刷新 <客户端名>」按本段今日贡献行刷新涉及的
    /// provider 卡（`HarnessSection.refreshProviderStatusIDs(in:)`），动作实现由
    /// `MenuContentView` 注入。
    private var harnessRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(MenuTypography.hint)
                .foregroundStyle(Color.secondaryLabel)
            Image(systemName: section.iconSystemName)
                .font(.system(size: 9))
                .foregroundStyle(Color.accentColor)
            Text(section.displayName)
                .font(MenuTypography.dataLabel)
                .foregroundStyle(Color.primaryLabel)
                .lineLimit(1)
                .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
            HarnessMetricColumns.cluster(
                prompts: "\(section.turnCount)",
                token: Formatters.formatTokenCountCompact(section.totalTokens),
                hitRate: HarnessUsageMenuView.hitRateText(section.cacheHitRate),
                thinking: HarnessModelRowView.thinkingPercent(section.buckets) ?? "—",
                ttft: Formatters.formatTTFT(section.ttftSeconds),
                speed: Formatters.speedText(section.callSpeedStatistics.p50),
                speedHelp: HarnessMetricColumns.speedDistributionHelp(section.callSpeedStatistics),
                value: section.valueText
            )
            Group {
                if let updateTime {
                    Text(Formatters.formatTimeOfDay(updateTime))
                        .help("本地用量更新时间")
                } else {
                    Color.clear
                }
            }
            .font(MenuTypography.hint)
            .foregroundStyle(Color.secondaryLabel)
            .monospacedDigit()
            .frame(width: HarnessMetricColumns.timeSlot, alignment: .trailing)
        }
    }

    /// 橙色截断提示，**单行**短文案。
    ///
    /// 完整说明是 `ClientUsageTruncationNotice.text`（设置页展开行与 7 天柱图
    /// footer 用的那一句），
    /// 而菜单里这一行的读者只需要知道"数字不全"——具体怎么截断的，鼠标悬停
    /// （`.help`）再看。
    static let truncationShortText = "部分较早会话未计入"

    private var truncationNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 8))
                .foregroundStyle(Color.orange)
            Text(Self.truncationShortText)
                .font(MenuTypography.hint)
                .foregroundStyle(Color.orange)
                .lineLimit(1)
                .help(ClientUsageTruncationNotice.text)
        }
    }

    static let samplesTruncationShortText = "明细采样已达上限"

    private var samplesTruncationNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "info.circle")
                .font(.system(size: 8))
                .foregroundStyle(Color.secondaryLabel)
            Text(Self.samplesTruncationShortText)
                .font(MenuTypography.hint)
                .foregroundStyle(Color.secondaryLabel)
                .lineLimit(1)
                .help("近 24h 抽样明细受容量限制截断，今日累计 Token 仍按完整总量统计")
        }
    }
}

enum MenuContentMode: String {
    case usage
    case quota
}

enum MenuQuotaEmptyState: Equatable {
    case noProviders
    case noEnabledProviders
}

enum MenuQuotaPresentation {
    static func emptyState(for statuses: [ProviderStatus]) -> MenuQuotaEmptyState {
        statuses.isEmpty ? .noProviders : .noEnabledProviders
    }

    static func summary(
        providerKind: ProviderKind,
        models: [ModelQuota],
        balance: DeepseekBalanceDetail?,
        now: Date = Date()
    ) -> String {
        if providerKind == .deepseek {
            guard let balance else { return "余额暂无数据" }
            let total = "余额 \(balance.symbol)\(String(format: "%.2f", balance.total))"
            let grant = "赠金 \(balance.symbol)\(String(format: "%.2f", balance.granted))"
            return "\(total) · \(grant)"
        }
        let intervals = models.filter(\.hasIntervalWindow)
        let weeks = models.filter(\.hasWeeklyWindow)
        var pieces: [String] = []
        if let interval = intervals.min(by: { $0.intervalRemainingPercent < $1.intervalRemainingPercent }) {
            pieces.append("5h \(Formatters.formatQuotaPercent(interval.intervalRemainingPercent)) · \(resetText(interval.intervalResetsAt, now: now))")
        }
        if let weekly = weeks.min(by: { $0.weeklyRemainingPercent < $1.weeklyRemainingPercent }) {
            pieces.append("周 \(Formatters.formatQuotaPercent(weekly.weeklyRemainingPercent)) · \(resetText(weekly.weeklyResetsAt, now: now))")
        }
        if !pieces.isEmpty { return pieces.joined(separator: " · ") }
        return "暂无窗口额度"
    }

    private static func resetText(_ date: Date?, now: Date) -> String {
        guard let date else { return "重置时间未知" }
        guard date > now else { return "待更新" }
        return "\(Formatters.formatResetSuffix(from: date, now: now))后重置"
    }
}

/// 菜单里的紧凑额度视图。数据仍来自 ProviderStatus / fleet effective quota，
/// 不复制额度计算，也不依赖 edge dock 是否可见。
struct MenuQuotaOverviewView: View {
    @ObservedObject var state: AppState
    let onRefreshProvider: CardQuotaRefreshAction
    let onOpenSettings: (ProviderKind) -> Void
    let onOpenDetails: (String) -> Void
    @State private var revision: UInt64 = 0

    private var orderedStatuses: [ProviderStatus] {
        _ = revision
        let statuses = state.fleetQuotaEffectiveStatuses()
        return DisplayOrder.ordered(
            statuses,
            preferredIDs: state.configStore.config.providerCardOrder,
            id: { $0.kind.quotaProviderID },
            by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        )
    }

    var body: some View {
        VStack(spacing: 6) {
            if let fleetContext = state.fleetCardContext(for: orderedStatuses.first?.kind ?? .codexChatGpt),
               fleetContext.multiNode {
                Text("当前用量范围：\(scopeLabel(fleetContext.scope, choices: fleetContext.nodeChoices))；额度显示本机优先的全局有效值")
                    .font(MenuTypography.hint)
                    .foregroundStyle(Color.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("额度按本机优先的全局有效额度显示；当前用量范围：\(scopeLabel(fleetContext.scope, choices: fleetContext.nodeChoices))")
            }
            ForEach(orderedStatuses) { status in
                MenuQuotaProviderRow(
                    status: status,
                    localStatus: state.statuses.first { $0.kind == status.kind } ?? status,
                    fleet: state.fleetCardContext(for: status.kind),
                    selectedStatusBarSource: state.configStore.config.statusBarQuotaSelection.flatMap {
                        $0.providerID == status.id ? $0.source : nil
                    },
                    statusBarQuotaOptions: state.statusBarQuotaOptions(providerID: status.id),
                    configStore: state.configStore,
                    onTogglePin: { state.toggleStatusBarPinnedProvider(status.id) },
                    onSelectStatusBarQuota: { source in
                        state.setStatusBarQuotaSelection(StatusBarQuotaSelection(providerID: status.id, source: source))
                    },
                    onRefresh: { onRefreshProvider(status.id) },
                    onUsageRefresh: { Task { await state.triggerLocalUsageRescan() } },
                    onSettings: { onOpenSettings(status.kind) },
                    onOpenDetails: { onOpenDetails(status.id) }
                )
            }
        }
        .onReceive(state.statusDidChange) { _ in revision &+= 1 }
        .onReceive(state.fleetDidChange) { _ in revision &+= 1 }
    }

    private func scopeLabel(_ scope: FleetScope, choices: [FleetNodeChoice]) -> String {
        switch scope {
        case .local: return "本机"
        case .fleet: return "全局"
        case .node(let id): return choices.first { $0.id == id }?.name ?? "所选节点（已不在快照中）"
        }
    }
}

struct MenuQuotaProviderRow: View {
    let status: ProviderStatus
    let localStatus: ProviderStatus
    let fleet: FleetCardContext?
    var selectedStatusBarSource: StatusBarQuotaSource? = nil
    var statusBarQuotaOptions: [StatusBarQuotaOption] = []
    var configStore: ConfigStore? = nil
    var onTogglePin: (() -> Void)? = nil
    var onSelectStatusBarQuota: (@MainActor @Sendable (StatusBarQuotaSource) -> Void)? = nil
    let onRefresh: CardUsageRefreshAction
    let onUsageRefresh: CardUsageRefreshAction
    let onSettings: () -> Void
    let onOpenDetails: () -> Void
    @State private var isPlanExpanded = false
    @State private var isHistoryExpanded = false
    @Environment(\.displayDate) private var displayDate

    private var effective: FleetEffectiveQuota? { fleet?.effectiveQuota }
    private var quota: QuotaInfo? { effective?.quota ?? status.lastSuccess }
    private var models: [ModelQuota] {
        quota?.aggregateQuotaModels(providerKind: status.kind) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                BrandLogoView(kind: status.kind, size: 16)
                Text(status.displayName)
                    .font(MenuTypography.dataLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(status.displayName)
                if let event = peakHeaderEvent {
                    Text(event.title)
                        .font(MenuTypography.hint)
                        .foregroundStyle(event.color)
                        .lineLimit(1)
                }
                if let event = resetCreditHeaderEvent {
                    Text(event.title)
                        .font(MenuTypography.hint)
                        .foregroundStyle(event.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let fetchedAt = quota?.fetchedAt {
                    Text(Formatters.formatTimeOfDay(fetchedAt))
                        .font(MenuTypography.hint)
                        .foregroundStyle(Color.secondaryLabel)
                        .monospacedDigit()
                        .help("额度数据更新时间；\(status.displayName)额度请求时间，不代表本机用量更新时间")
                }
                if ProviderKind.windowedKinds.contains(status.kind), let onTogglePin {
                    StatusBarQuotaSelector(
                        selectedSource: selectedStatusBarSource,
                        options: statusBarQuotaOptions,
                        iconSize: 10,
                        horizontalPadding: 4,
                        verticalPadding: 2,
                        onToggle: onTogglePin,
                        onSelect: { onSelectStatusBarQuota?($0) }
                    )
                }
                if case .loading = localStatus.state {
                    ProgressView()
                        .controlSize(.mini)
                        .help("正在刷新 \(status.displayName) 额度")
                        .accessibilityLabel("正在刷新 \(status.displayName) 额度")
                } else {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(MenuTypography.headerAction)
                    }
                    .buttonStyle(.plain)
                    .help("刷新 \(status.displayName) 额度；仅重新读取此 provider")
                    .accessibilityLabel("刷新 \(status.displayName) 额度")
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    quotaSummaryLabel
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    quotaActions
                }
                VStack(alignment: .leading, spacing: 5) {
                    quotaSummaryLabel
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer(minLength: 0)
                        quotaActions
                    }
                }
            }

            if let source = effective?.sourceTagText {
                Text(effective?.isStale == true ? "\(source) · 已过期" : source)
                    .font(MenuTypography.hint)
                    .foregroundStyle(effective?.isStale == true ? Color.warningTint : Color.secondaryLabel)
                    .lineLimit(1)
                    .help(effective?.isStale == true ? "此额度来自其他节点，快照已过期" : "此额度来自其他节点")
            }

            if case .notConfigured(let reason) = localStatus.state {
                HStack {
                    Text("未配置 · \(reason)")
                        .font(MenuTypography.hint)
                        .foregroundStyle(Color.secondaryLabel)
                        .lineLimit(2)
                    Spacer()
                    Button("完成设置", action: onSettings)
                        .font(MenuTypography.hint)
                        .buttonStyle(.link)
                }
            } else if case .ready = localStatus.state, quota == nil {
                Text("等待首次额度数据")
                    .font(MenuTypography.hint)
                    .foregroundStyle(Color.secondaryLabel)
            }

            if case .failed(let message, _) = localStatus.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(MenuTypography.hint)
                    .foregroundStyle(Color.criticalTint)
                    .lineLimit(2)
                    .help(message)
            }

            if isPlanExpanded {
                planCard
                        .equatable()
                        .environment(\.hoverRevealMode, .alwaysVisible)
                        .environment(\.displayDate, displayDate)
                        .environment(\.quotaWindowSegmentEditable, true)
                        .environment(\.cardQuotaRefreshAction, { _ in onRefresh() })
                        .environment(\.cardSelectStatusBarQuota, { @MainActor @Sendable _, source in
                            selectPlanQuotaSource(source)
                        })
            }
            if isHistoryExpanded {
                ProviderCardView(status: status, fleet: fleet, presentation: .history, configStore: configStore)
                    .equatable()
                    .environment(\.hoverRevealMode, .alwaysVisible)
                    .environment(\.displayDate, displayDate)
                    .environment(\.quotaWindowSegmentEditable, true)
                    .environment(\.cardUsageRefreshAction, onUsageRefresh)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.045))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.07), lineWidth: 1))
        )
    }

    /// 菜单中的共享 Plan 卡与外层 Provider 行使用同一来源状态和动作。
    var planCard: ProviderCardView {
        ProviderCardView(
            status: status,
            fleet: fleet,
            selectedStatusBarSource: selectedStatusBarSource,
            presentation: .plan,
            configStore: configStore
        )
    }

    func selectPlanQuotaSource(_ source: StatusBarQuotaSource) {
        onSelectStatusBarQuota?(source)
    }

    private func summary(now: Date) -> String {
        MenuQuotaPresentation.summary(
            providerKind: status.kind,
            models: models,
            balance: quota?.balanceDetail,
            now: now
        )
    }

    @ViewBuilder
    private var quotaSummaryLabel: some View {
        if !models.isEmpty || (status.kind == .deepseek && quota?.balanceDetail != nil) {
            Text(summary(now: displayDate))
                .font(MenuTypography.dataValue)
                .foregroundStyle(Color.primaryLabel)
        } else if case .loading = localStatus.state {
            Text("正在获取套餐额度")
                .font(MenuTypography.hint)
                .foregroundStyle(Color.secondaryLabel)
        }
    }

    private var quotaActions: some View {
        HStack(spacing: 7) {
            Button {
                isPlanExpanded.toggle()
            } label: {
                Label("套餐详情", systemImage: isPlanExpanded ? "chevron.up" : "chevron.down")
            }
            .font(MenuTypography.hint)
            .buttonStyle(.plain)
            .accessibilityLabel(isPlanExpanded ? "收起 \(status.displayName) 套餐详情" : "展开 \(status.displayName) 套餐详情")
            Button {
                isHistoryExpanded.toggle()
            } label: {
                Label("用量历史", systemImage: isHistoryExpanded ? "chevron.up" : "chevron.down")
            }
            .font(MenuTypography.hint)
            .buttonStyle(.plain)
            .accessibilityLabel(isHistoryExpanded ? "收起 \(status.displayName) 用量历史" : "展开 \(status.displayName) 用量历史")
            Button("独立窗口") { onOpenDetails() }
                .font(MenuTypography.hint)
                .buttonStyle(.link)
                .help("在独立窗口查看 \(status.displayName) 的完整详情")
                .accessibilityLabel("在独立窗口打开 \(status.displayName) 详情")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var peakHeaderEvent: (title: String, color: Color)? {
        let window: PeakWindow?
        switch status.kind {
        case .glmCodingPlan: window = status.glmPeakWindow
        case .deepseek: window = status.deepseekPeakWindow
        default: window = nil
        }
        guard let window else { return nil }
        switch window.status(at: displayDate, calendar: PeakWindow.beijingCalendar) {
        case .peak:
            return ("高峰中", .criticalTint)
        case .offPeak(until: let start) where start.timeIntervalSince(displayDate) < 3600:
            return ("即将高峰", .warningTint)
        case .offPeak:
            return nil
        }
    }

    private var resetCreditHeaderEvent: (title: String, color: Color)? {
        guard let resets = quota?.resetCredits,
              resets.availableCount > 0,
              let expiry = resets.nearestExpiry else { return nil }
        let remaining = expiry.timeIntervalSince(displayDate)
        guard remaining <= 48 * 3600 else { return nil }
        let color = CreditEntryRow.dotColor(for: expiry, now: displayDate)
        let title = remaining <= 0
            ? "重置卡已过期"
            : "重置卡临期 \(Formatters.formatRelativeShort(from: expiry, now: displayDate))"
        return (title, color)
    }
}

/// 本地段内单条模型行：模型名 + 共用交集指标簇（单行，与 harness 行字段级对齐）。
///
/// 价值是**行级**的 `ModelCostEstimate.displayText` 原样文案（单 provider 单币种
/// 原额）。行级绝不做跨币种相加——同一段里不同 provider 的行金额可能不同币种，
/// 相加必须留到段头 / 全局的 `MixedCurrencyEstimate`。
/// 簇取并集 {Pmt, Token, 价值, 命中, 思考, 速度, TTFT}（`HarnessMetricColumns`，
/// 2026-11-07 用户裁定同线 + 字段对齐，460pt 实测装得下并集；TTFT 列 2026-11-08
/// 加入，同日换位到 Speed 之前）。
/// Prompt 速度范围线已于同日移除（用户裁定：占位大），速度只保留 P50 文本。
struct HarnessModelRowView: View {
    let row: HarnessModelRow

    /// 行与行的间距。刻意小于段间距（`sectionSpacing`），让分组层级一眼可辨。
    static let rowSpacing: CGFloat = 3

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(row.compactDisplayName)
                .font(MenuTypography.modelTitle)
                .foregroundStyle(Color.primaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.displayName)
                .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
            HarnessMetricColumns.cluster(
                prompts: "\(row.turnCount)",
                token: Formatters.formatTokenCountCompact(row.totalTokens),
                hitRate: Self.percentText(row.cacheHitRate),
                thinking: Self.thinkingPercent(row.buckets) ?? "—",
                ttft: Formatters.formatTTFT(row.ttftSeconds),
                speed: Formatters.speedText(row.callSpeedStatistics.p50),
                speedHelp: HarnessMetricColumns.speedDistributionHelp(row.callSpeedStatistics),
                value: row.costText
            )
            Color.clear
                .frame(width: HarnessMetricColumns.timeSlot, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityMetrics(for: row))
    }

    static func thinkingPercent(_ buckets: TokenUsageBuckets) -> String? {
        let output = max(0, buckets.output)
        let reasoning = max(0, buckets.reasoning)
        let denominator = SaturatingArithmetic.add(output, reasoning)
        guard denominator > 0 else { return nil }
        return Formatters.formatPercent(Double(reasoning) / Double(denominator))
    }

    private static func accessibilityMetrics(for row: HarnessModelRow) -> String {
        "\(row.compactDisplayName)；Prompt \(row.turnCount)；Token \(Formatters.formatTokenCountCompact(row.totalTokens))；价值 \(row.costText)；命中率 \(percentText(row.cacheHitRate))；思考 \(thinkingPercent(row.buckets) ?? "—")；首字延迟 P50 \(Formatters.formatTTFT(row.ttftSeconds)) 秒；速度 P50 \(Formatters.speedText(row.callSpeedStatistics.p50))"
    }

    /// 命中率文案复用汇总块的同一实现。
    static func percentText(_ rate: Double?) -> String {
        HarnessUsageMenuView.hitRateText(rate)
    }

}


// MARK: - Fleet 菜单形态（§10.2）

extension HarnessUsageMenuView {

    private func fleetOverviewRow(
        label: String,
        tokens: Int,
        hitRate: Double?,
        valueText: String
    ) -> some View {
        fleetOverviewRow(
            label: label,
            tokensText: Formatters.formatTokenCountCompact(tokens),
            hitRateText: HarnessUsageMenuView.hitRateText(hitRate),
            valueText: valueText
        )
    }

    private func fleetOverviewRow(
        label: String,
        tokensText: String,
        hitRateText: String,
        valueText: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(MenuTypography.metricLabel)
                .foregroundStyle(Color.secondaryLabel)
            Text(tokensText)
                .font(MenuTypography.metricValue)
                .foregroundStyle(Color.primaryLabel)
                .frame(width: HarnessUsageMenuView.totalWidth, alignment: .leading)
            Spacer(minLength: 4)
            Text(hitRateText)
                .font(MenuTypography.metricValue)
                .foregroundStyle(Color.secondaryLabel)
                .frame(width: HarnessUsageMenuView.hitRateWidth, alignment: .trailing)
            Text(valueText)
                .font(MenuTypography.metricValue)
                .foregroundStyle(Color.primaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// fleet 形态的客户端段：段头 = 该 client 的 fleet 权威日合计；段内节点行全宽
/// 不缩进（细分隔线 + 次要色节点名做分组，§10.6 K），模型行只缩进一级。
struct FleetClientSectionView: View {
    let section: FleetMenuSummary.ClientSection
    /// 段头右键「刷新 <客户端名>」：按 clientID 回宿主（与本地形态
    /// `HarnessSectionView` 的段头右键同一语义，fleet 段头不能丢）。
    /// nil（节点视图）时不出右键菜单：刷新的是本机数据，对单节点视图无意义。
    var onRefreshClient: ((String) -> Void)? = nil
    @State private var isExpanded = false

    /// 该形态有没有段头右键刷新项。节点视图恒为 false：节点分支不传
    /// `onRefreshClient`（刷的是**本机**数据，对单节点视图无意义，§10.2）。
    var hasRefreshMenu: Bool { onRefreshClient != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { isExpanded.toggle() } label: {
                header
            }
            .buttonStyle(.plain)
            .contextMenu {
                if let onRefreshClient {
                    Button(Self.refreshMenuTitle(displayName: section.displayName)) {
                        onRefreshClient(section.clientID)
                    }
                }
            }
            if isExpanded {
                ForEach(section.mergedModels) { model in
                    FleetModelRowView(row: model)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.045))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.07), lineWidth: 1))
        )
    }

    /// 段头右键项的标题。文案由 spec §10.2 定：「刷新本机 <客户端名>」——
    /// 「本机」二字说明刷的是本机数据，不是 fleet 合计。
    static func refreshMenuTitle(displayName: String) -> String {
        "刷新本机 \(displayName)"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: section.iconSystemName)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
                Text(section.displayName)
                    .font(MenuTypography.dataLabel)
                    .foregroundStyle(Color.primaryLabel)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(MenuTypography.hint)
                    .foregroundStyle(Color.secondaryLabel)
            }
            .overlay(alignment: .bottom) {
                MenuHairline.horizontal
            }
            ViewThatFits(in: .horizontal) {
                fleetSummaryLine
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text("今日 Token: \(Formatters.formatTokenCountCompact(section.totalTokens))")
                        Text("价值: \(section.costText)")
                    }
                    HStack(spacing: 7) {
                        Text("命中率: \(HarnessUsageMenuView.hitRateText(HarnessTodaySummary.cacheHitRate(for: section.buckets)))")
                        Text("速度: —")
                            .help("Fleet 未同步调用时长，速度不可用")
                    }
                }
                .font(MenuTypography.hint)
                .foregroundStyle(Color.secondaryLabel)
            }
            if section.isTruncated {
                Text(HarnessSectionView.truncationShortText)
                    .font(MenuTypography.hint)
                    .foregroundStyle(Color.orange)
                    .help(ClientUsageTruncationNotice.text)
            }
        }
    }

    private var fleetSummaryLine: some View {
        HStack(spacing: 7) {
            Text("今日 Token: \(Formatters.formatTokenCountCompact(section.totalTokens))")
            Text("价值: \(section.costText)")
            Text("命中率: \(HarnessUsageMenuView.hitRateText(HarnessTodaySummary.cacheHitRate(for: section.buckets)))")
            Text("速度: —")
                .help("Fleet 未同步调用时长，速度不可用")
        }
        .font(MenuTypography.hint)
        .foregroundStyle(Color.secondaryLabel)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// fleet 模型行：与本地模型行同一套列宽与层级（§10.2 K：只相对段头缩进一级）。
struct FleetModelRowView: View {
    let row: FleetMenuSummary.ModelRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 压缩名与本机行同口径（去供应商命名空间/品牌前缀）：
            // 原始名过长时尾截断会把 "-Flash" 截没，被误读成不同模型被合并。
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(HarnessModelRow.compactedDisplayName(for: row.modelName))
                    .font(MenuTypography.modelTitle)
                    .foregroundStyle(row.stale ? Color.secondaryLabel : Color.primaryLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.modelName)
                    .frame(minWidth: 80, maxWidth: .infinity, alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline))
                Text("Token: \(Formatters.formatTokenCountCompact(row.totalTokens))")
                Text("价值: \(row.costText)")
                Text("命中: \(HarnessModelRowView.percentText(row.hitRate))")
                Text("思考: \(HarnessModelRowView.thinkingPercent(row.buckets) ?? "—")")
                Text("速度: —")
                    .help("Fleet 未同步调用时长，速度不可用")
            }
            .font(MenuTypography.hint)
            .foregroundStyle(Color.secondaryLabel)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .accessibilityElement(children: .combine)
            Text("速度范围 —（节点同步不含调用时长）")
                .font(MenuTypography.hint)
                .foregroundStyle(Color.secondaryLabel)
        }
        .padding(.leading, 8)
    }
}
