import SwiftUI

/// 状态栏下拉菜单的 **Harness（客户端）视角**内容：顶部一屏全局今日汇总，
/// 下面按客户端分段、段内按模型一行一条，**最底部一行 provider 兜底状态**。
///
/// 与 `ProviderCardView`（Provider 视角）是**并列**的两套读法，不是替换关系：
/// 悬浮窗（边缘状态窗）仍然按 Provider 卡渲染额度，菜单这里只回答"今天我在哪些
/// 客户端里烧了多少 token、命中率多少、值多少钱"。额度（还能用多少）不再占一整屏，
/// 但**不能从这一屏彻底消失**——否则没开边缘窗的用户在菜单里看不到任何额度信息；
/// 底部的 `ProviderStatusStripView` 一行极简状态元素 + hover 弹出的完整卡片就是
/// 这一层兜底。
///
/// 排版宽度（菜单 360pt，内容区 336pt，见 `MenuPanelHeightBridge.width`）：
/// 模型名 92 + 占比条 ≥40 + Token 40 + 命中 36 + 速度 32 + 价值 56 +
/// 5×6 间距 + scope 行缩进 8pt = 334pt，余量 2pt 留给字体度量误差。数字列全部定宽右对齐 +
/// `monospacedDigit`，刷新时数字变化不会把整行往右顶。段头右侧的数值格组
/// （`SectionHeaderMetricsView`：Token 小计 / 命中占位 / 速度汇总 / 价值）
/// 复用同一批列宽常量与列间距，段头数字与下方模型行逐列对齐。预算由
/// `HarnessUsageMenuViewTests` 钉住。
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
    /// 兜底行单个 provider 的刷新动作（左键点按）。参数是 providerID，
    /// 刷新实现由 `MenuContentView` 注入（它持有 `AppState`）。
    var onRefreshProvider: (String) -> Void = { _ in }

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
                    segments: HarnessTodaySummary.clientSegments(from: summary.sections)
                )
                if summary.sections.isEmpty { emptyTodayState } else {
                    ForEach(summary.sections) { section in
                        HarnessSectionView(
                            section: section,
                            onRefreshSection: onRefreshSection
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
                ForEach(summary.sections) { section in
                    HarnessSectionView(
                        section: section,
                        onRefreshSection: onRefreshSection
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
                let cost = Self.heroCostParts(from: valueText)
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
        if !scopeChoices.isEmpty,
           FleetScopeControlStyle.preferred(choices: scopeChoices) == .segmented {
            FleetScopeSwitcher(
                scope: activeScope,
                choices: scopeChoices,
                onSelect: { onScopeChange($0) },
                style: .segmented
            )
            .help("切换显示范围：全局 / 本机 / 各节点")
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
        segments: [HarnessClientSegment]
    ) -> some View {
        heroOverviewCard(
            headerTitle: label,
            tokensText: Formatters.formatTokenCountCompact(tokens),
            hitRate: hitRate,
            valueText: valueText,
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

/// 最小流式布局：子视图放不进当前行就换到下一行。只服务 `HarnessClientLegend`
/// 的图例 chip（每个 chip `.fixedSize` 自然宽、不拉伸），不是通用布局。
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
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x - bounds.minX + size.width > bounds.width {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
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
            let size = subview.sizeThatFits(.unspecified)
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
}

/// 一个客户端段：段头（名称 + 今日小计 + 段价值）+ 段内模型行。
///
/// **internal 而非 private**：留下测试缝。`HarnessUsageMenuViewTests` 要真的把
/// 一个段布局一遍量高度与自然宽（列宽超预算、单个段撑爆菜单高度都只能这么抓），
/// 改回 private 就得把同样的量测挂在 `HarnessUsageMenuView` 上，量的就不再是
/// 真正被渲染的那棵树了。同一约定见 `SettingsView.clientProviderDisclosure`。
struct HarnessSectionView: View {
    let section: HarnessSection
    /// 段头右键「刷新 <客户端名>」：按本段今日贡献行刷新涉及的 provider 卡。
    var onRefreshSection: (HarnessSection) -> Void = { _ in }

    var body: some View {
        // 行距取行视图自己的常量（比段间距小），"换了个客户端"才比"换了个模型"醒目。
        VStack(alignment: .leading, spacing: HarnessModelRowView.rowSpacing) {
            header
            ForEach(section.rows) { row in
                HarnessModelRowView(row: row)
            }
        }
    }

    /// 段头：一行里同时给出"这是谁"和"今天它花了多少"。
    /// 段价值是 `MixedCurrencyEstimate`——同一个客户端横跨多个 provider 分片时
    /// （OpenCode / DSH / ZCode）必然混币，必须折算成 CNY 总额而不是裸相加。
    ///
    /// 右侧数值格（`SectionHeaderMetricsView`）与模型行**同构**：Token 小计 /
    /// 命中占位 / 速度汇总 / 价值四格全部复用模型行的列宽常量与列间距。token
    /// 小计曾经是自然宽——模型行 2026-10 加「速度」列后，它漂到了速度列上方，
    /// 读起来像速度列的小计；定宽对齐后每个数字都压在自己的列上。
    ///
    /// 右键菜单挂在**段头**（不是整段）：菜单内容区现在是客户端视角，右键一个
    /// 段名才是"针对这些数据"的语义；「刷新 <客户端名>」按本段今日贡献行刷新
    /// 涉及的 provider 卡（`HarnessSection.refreshProviderStatusIDs(in:)`），
    /// 动作实现由 `MenuContentView` 注入。
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: HarnessModelRowView.columnSpacing) {
                Image(systemName: section.iconSystemName)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
                Text(section.displayName)
                    .font(MenuTypography.dataLabel)
                    .foregroundStyle(Color.primaryLabel)
                    .lineLimit(1)
                Spacer(minLength: 6)
                SectionHeaderMetricsView(
                    totalTokens: section.totalTokens,
                    tokensPerSecond: section.tokensPerSecond,
                    valueText: section.valueText
                )
            }
            .padding(.bottom, 1)
            .overlay(alignment: .bottom) {
                MenuHairline.horizontal
            }
            .contextMenu {
                Button("刷新本机 \(section.displayName)") { onRefreshSection(section) }
            }
            // 截断提示只在该段的数据源真的被截断时出现：数字本身仍然是"对"的，
            // 只是"不全"——不说就等于把一份残缺统计当完整统计读。
            if section.isTruncated {
                truncationNotice
            }
        }
    }

    /// 橙色截断提示，**单行**短文案。
    ///
    /// 完整说明是 `ClientUsageTruncationNotice.text`（设置页展开行与 7 天柱图
    /// footer 用的那一句），但那一句二十多个字，在段头底下 336pt 宽的位置要占两行，
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
}

/// 段头右侧的数值格组：Token 小计 / 命中率占位 / 速度汇总 / 价值，四格全部
/// 定宽右对齐，**列宽与列间距复用 `HarnessModelRowView` 的常量**——段头没有
/// 表头行，数字必须与下方模型行的同名列站在同一条竖线上（本地段与 fleet 段
/// 的段头共用这一组，两种形态的段头读法一致）。
///
/// 命中率列由透明占位守住（段头不显示命中率，但没有它 Token 与速度列就会
/// 左移 42pt）：`Color.clear` 没有命中区域、不可交互；高度定 0，不参与行高、
/// 也不影响基线对齐——它只负责把 Token 与速度列的 x 位置撑到与模型行一致。
///
/// 颜色沿用段头现状：Token / 速度汇总是次级（汇总不是行明细），价值保持
/// primary；字体沿用段头的 `metricValue`（与模型行的 `dataValue` 同为
/// 10pt 等宽数字，定宽列装得下同一批文案）。速度文案复用
/// `QuotaWindowUsageSection.speedText` 的分档，口径说明与模型行速度格共用
/// `HarnessModelRowView.speedColumnHelp`。
private struct SectionHeaderMetricsView: View {
    let totalTokens: Int
    /// 段速度汇总。本地段 = `HarnessSection.tokensPerSecond`（该 client 今日
    /// 全部样本的 `windowTokenRate`）；fleet 段没有本地样本，调用方传 nil。
    let tokensPerSecond: Double?
    let valueText: String

    @ViewBuilder
    var body: some View {
        Text(Formatters.formatTokenCountCompact(totalTokens))
            .font(MenuTypography.metricValue)
            .foregroundStyle(Color.secondaryLabel)
            .frame(width: HarnessModelRowView.tokenWidth, alignment: .trailing)
        Color.clear
            .frame(width: HarnessModelRowView.hitRateWidth, height: 0)
        Text(QuotaWindowUsageSection.speedText(tokensPerSecond))
            .font(MenuTypography.metricValue)
            .foregroundStyle(Color.secondaryLabel)
            .frame(width: HarnessModelRowView.speedWidth, alignment: .trailing)
            .help(HarnessModelRowView.speedColumnHelp)
        Text(valueText)
            .font(MenuTypography.metricValue)
            .foregroundStyle(Color.primaryLabel)
            .frame(width: HarnessUsageMenuView.valueWidth, alignment: .trailing)
    }
}

/// 菜单内容区**底部**的 provider 兜底行：一行横排全部已启用 provider 的品牌
/// 图标（用户裁定 2026-10-24：不放更新时间胶囊，也没有 hover 二次弹卡——
/// 额度明细去边缘窗 / 设置页看，这一行只回答「哪些 provider 在场」）。
///
/// 它存在的理由：菜单主体已经改成客户端视角（"今天烧了多少"），**额度**那一面
/// 只剩边缘状态窗与设置页；没开边缘窗的用户在这一屏就彻底看不到额度状态了。
/// 这一行把它兜回来，且**不与 harness 段混淆**——独立一行（无文字标题，图标 +
/// 状态胶囊的序列自解释），不占段头、不进段的行序。
///
/// 每个元素只剩一种交互：**左键点按 → 立即刷新这一个 provider**（连点的安全
/// 性由 `AppState.refreshOne` 的全局在飞闸门兜，UI 侧不做禁用态）。
struct ProviderStatusStripView: View {
    let snapshot: ProviderStatusStrip.Snapshot
    /// hover 卡的 fleet 上下文（scope 分段 / fleet 用量 / 生效额度来源标注）。
    /// 默认恒 nil：未启用联动时 hover 卡与现在完全一致。
    var fleetContext: (ProviderStatus) -> FleetCardContext? = { _ in nil }
    /// 单个 provider 的刷新动作。参数是 providerID，实际刷新路径由
    /// 宿主（`MenuContentView` → `AppState.refreshOne`）决定，这一层不碰网络。
    var onRefreshProvider: (String) -> Void = { _ in }

    /// 左键点按动作的**数据形态**（不含 SwiftUI 视图）。
    ///
    /// 单独提成值类型，是为了让"点下去交出去的是不是这张 provider 的 id"可以被
    /// 单测钉住：`onTapGesture` 在 SwiftUI 里没有可寻址的测试缝，断言只能落在
    /// 喂给它的这份数据与 `perform` 的路由上。
    struct RefreshMenuItem: Identifiable, Equatable, Sendable {
        let providerID: String
        let displayName: String
        var id: String { providerID }
        /// 执行：把 providerID 原样交回宿主。
        func perform(_ onRefresh: (String) -> Void) {
            onRefresh(providerID)
        }
    }

    /// 单个 provider 元素对应的单刷动作。**在场即有**——`.failed` /
    /// `.notConfigured` 的 provider 同样能点，因为"重试"正是它们需要的动作。
    static func refreshMenuItem(for entry: ProviderStatusStrip.Entry) -> RefreshMenuItem {
        RefreshMenuItem(providerID: entry.status.id, displayName: entry.displayName)
    }

    /// 左键点按的动作闭包：只是 `RefreshMenuItem.perform` 的包装——数据形态
    /// （点的是哪个 provider）与执行（交回宿主 → `AppState.refreshOne`）分离，
    /// 让两边都能被单测独立钉住。
    ///
    /// 提成 `static` 是**测试缝**：`onTapGesture` 在 SwiftUI 里没有可寻址的接口，
    /// 「点按交出去的是不是这张 provider 的 id」只能钉在这个闭包上。
    static func tapHandler(
        for item: RefreshMenuItem,
        onRefresh: @escaping (String) -> Void
    ) -> () -> Void {
        { item.perform(onRefresh) }
    }

    /// 元素之间的间距。比模型行的 6pt 紧一档：这一行是**兜底**信息，不该在
    /// 视觉上比正文行还松。
    static let entrySpacing: CGFloat = 4

    /// 品牌图标边长。常规 18pt 在这一行太大：一行要放下
    /// `ProviderStatusStrip.maximumVisibleCount` 个元素，18pt 图标会把时间胶囊
    /// 挤到只剩 30pt。11pt 仍能认出是哪个品牌。
    static let logoSize: CGFloat = 11

    var body: some View {
        if !snapshot.isEmpty {
            // 一行纯品牌图标序列（用户裁定：不放时间胶囊），可见容量核算见
            // `ProviderStatusStrip.maximumVisibleCount`。
            HStack(spacing: Self.entrySpacing) {
                ForEach(snapshot.entries) { entry in
                    entryView(entry)
                }
                // 有 provider 被折叠掉时必须说出来：否则"只显示 3 个"会被读成
                // "只注册了 3 个"。
                if snapshot.hiddenCount > 0 {
                    Text("+\(snapshot.hiddenCount)")
                        .font(MenuTypography.badge)
                        .foregroundStyle(Color.secondaryLabel)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                        .help("还有 \(snapshot.hiddenCount) 个已启用 provider 未显示：额度异常优先占位")
                }
            }
            .padding(.top, 2)
            .overlay(alignment: .top) {
                MenuHairline.horizontal
                    .padding(.bottom, 2)
            }
        }
    }

    /// 单个 provider 的极简元素 + 它的完整卡浮层，以及叠在元素上的两种交互。
    ///
    /// 单刷入口（左键点按）挂在**整个元素**上（不是浮层里的卡）：菜单改版成
    /// 客户端视角后，这一行是菜单里唯一还带 provider 身份的地方，单刷入口必须
    /// 回到这里——旧 provider 卡的「立即刷新」是 3b3538e 随卡片一起下线的。
    ///
    /// 手势的挂载点说明（为什么这样挂不互相破坏）：
    /// - `onTapGesture` 挂在 `HoverInfoRow` **外面**：它加的是 SwiftUI 手势识别，
    ///   而 hover 走的是 `HoverTrackingView` 的 NSView tracking area，两条通道互不
    ///   干涉，hover 弹卡照旧。命中区域直接沿用 `HoverInfoRow` 自己那层
    ///   `contentShape`（6pt 圆角矩形），已经盖住图标与胶囊之间那 3pt 缝。
    /// - **不做 `isRefreshJobActive` 置灰**：重复点按交出去的还是
    ///   同一个 `AppState.refreshOne`，它开头就有全局在飞闸门
    ///   （`refreshScheduler.beginExternalJob()`，在飞则整次忽略并只重锚被刷的
    ///   provider）。UI 再维护一份"这一行点不动"的状态只会和
    ///   `AppState.isRefreshJobActive` 的全局口径漂移，而且用户连点时看到"没反应"
    ///   比看到"已在刷新"更困惑——反馈交给既有状态胶囊自然变化（更新中 → HH:mm）。
    /// 单个 provider 元素：品牌图标 + 单刷点按。不放更新时间胶囊、不挂 hover
    /// 弹卡（用户裁定 2026-10-24）；点击交出去的还是 `RefreshMenuItem`。
    private func entryView(_ entry: ProviderStatusStrip.Entry) -> some View {
        let item = Self.refreshMenuItem(for: entry)
        return BrandLogoView(kind: entry.status.kind, size: Self.logoSize)
            .help("点击刷新 \(entry.displayName)")
            .onTapGesture(perform: Self.tapHandler(for: item, onRefresh: onRefreshProvider))
    }
}

/// 段内单条模型行：模型名 + 三段占比条 + Token / 命中率 / 速度 / 价值。
///
/// 价值是**行级**的 `ModelCostEstimate.displayText` 原样文案（单 provider 单币种
/// 原额）。行级绝不做跨币种相加——同一段里不同 provider 的行金额可能不同币种，
/// 相加必须留到段头 / 全局的 `MixedCurrencyEstimate`。
/// 与 `HarnessSectionView` 同一条理由保持 internal：排版预算断言要直接读它的
/// 定宽列常量。
struct HarnessModelRowView: View {
    let row: HarnessModelRow

    /// 行与行的间距。刻意小于段间距（`sectionSpacing`），让分组层级一眼可辨。
    static let rowSpacing: CGFloat = 3

    /// 行内列间距：六列之间的水平间隔。段头的数值格组
    /// （`SectionHeaderMetricsView`）复用同一常量——两边只要差 1pt，段头的
    /// 数字与下方模型行的同名列就会错开一条肉眼可见的斜线。
    static let columnSpacing: CGFloat = 6

    var body: some View {
        HStack(spacing: Self.columnSpacing) {
            // 模型名**定宽**，不是 `maxWidth`：同行的 `TokenBucketBar` 内部是
            // `GeometryReader`（贪婪填充），不定宽的名字列会被它整列吃掉——实测
            // 模型名会宽到 0pt，整行只剩条和数字。名字定宽 + 条吃剩余，是这里
            // 唯一稳定的分法。展示用压缩名（去品牌前缀，让变体后缀可区分），
            // hover 提示兜底完整原始 ID。
            Text(row.compactDisplayName)
                .font(MenuTypography.modelTitle)
                .foregroundStyle(Color.primaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.displayName)
                .frame(width: HarnessModelRowView.modelNameWidth, alignment: .leading)
            TokenBucketBar(buckets: row.buckets)
                .frame(minWidth: HarnessModelRowView.bucketBarMinWidth, maxWidth: .infinity)
            Text(Formatters.formatTokenCountCompact(row.totalTokens))
                .font(MenuTypography.dataValue)
                .foregroundStyle(Color.secondaryLabel)
                .frame(width: HarnessModelRowView.tokenWidth, alignment: .trailing)
            Text(HarnessModelRowView.percentText(row.cacheHitRate))
                .font(MenuTypography.dataValue)
                .foregroundStyle(Color.secondaryLabel)
                .frame(width: HarnessModelRowView.hitRateWidth, alignment: .trailing)
            // 速度是数值指标，样式跟 Token / 命中率同级（次级色），不跟价值的主色。
            // 文案复用额度窗口区块的同一分档实现，避免两处小数位规则漂移。
            Text(QuotaWindowUsageSection.speedText(row.tokensPerSecond))
                .font(MenuTypography.dataValue)
                .foregroundStyle(Color.secondaryLabel)
                .frame(width: HarnessModelRowView.speedWidth, alignment: .trailing)
                .help(HarnessModelRowView.speedColumnHelp)
            Text(row.costText)
                .font(MenuTypography.dataValue)
                .foregroundStyle(Color.primaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: HarnessModelRowView.valueWidth, alignment: .trailing)
        }
        // 与 fleet/节点视图的模型行同缩进（用户裁定：三种 scope 统一）。
        .padding(.leading, 8)
    }

    // MARK: - 排版常量

    /// 模型名列定宽。长模型名（`claude-sonnet-4-5-20250929-thinking`）走 tail
    /// 截断，保留最有辨识度的前缀。
    ///
    /// 六列合计 92 + 40 + 40 + 36 + 32 + 56 = 296pt，加 5 段 6pt 间距和 8pt scope 缩进
    /// = 334pt，在 336pt 内容区里留 2pt 余量给字体度量误差——数字列都是定宽右对齐，
    /// 余量被吃掉也只是让占比条窄一点，不会串列。
    static let modelNameWidth: CGFloat = 92
    /// 占比条下限：模型名列再长也要留住能看出三段比例的宽度。
    ///
    /// 曾经是 72：2026-10 模型行加「速度」列后原五列放不下六列，优先压这里
    /// （模型名截断损失更大，三个数字列的定宽都比它更不可让），40pt 仍能
    /// 分辨三段的相对长短。
    static let bucketBarMinWidth: CGFloat = 40
    /// Token 列定宽。`formatTokenCountCompact` 的最宽形态是五字符的 `9,999`
    /// （≥10000 走 `10K` / `1.2M` 阶梯），10pt 等宽数字下 40pt 够。
    static let tokenWidth: CGFloat = 40
    /// 命中率列定宽。`100%` 是最宽形态。
    static let hitRateWidth: CGFloat = 36
    /// 速度列定宽。最宽形态是四字符——`99.9`（<100 档一位小数）或 `1234`
    /// （≥100 档整数；万位 tok/s 不现实），`—` 更窄；10pt 等宽数字下 32pt 够。
    static let speedWidth: CGFloat = 32
    /// 价值列定宽。`$1234.56`（八字符，实测最宽的常见形态）走定宽；
    /// `（部分计价）` 之类更长的文案走 middle 截断，而不是把整行往左挤。
    static let valueWidth: CGFloat = 56

    /// 命中率文案复用汇总块的同一实现，避免两处小数位规则漂移。
    static func percentText(_ rate: Double?) -> String {
        HarnessUsageMenuView.hitRateText(rate)
    }

    /// 速度格的 hover 说明：模型行没有表头，口径只能挂在格子上。与额度窗口
    /// 区块那处（`QuotaWindowUsageSection.speedColumnHelp`）只差时间口径词——
    /// 这里的分母是「今日」的调用时长。
    static let speedColumnHelp = "今日 (Output+Reason) ÷ 调用时长，tok/s；时长未知的调用不参与"
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

    /// 该形态有没有段头右键刷新项。节点视图恒为 false：节点分支不传
    /// `onRefreshClient`（刷的是**本机**数据，对单节点视图无意义，§10.2）。
    var hasRefreshMenu: Bool { onRefreshClient != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: HarnessModelRowView.rowSpacing) {
            header
            ForEach(section.mergedModels) { model in
                FleetModelRowView(row: model)
            }
        }
    }

    /// 段头右键项的标题。文案由 spec §10.2 定：「刷新本机 <客户端名>」——
    /// 「本机」二字说明刷的是本机数据，不是 fleet 合计。
    static func refreshMenuTitle(displayName: String) -> String {
        "刷新本机 \(displayName)"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: HarnessModelRowView.columnSpacing) {
                Image(systemName: section.iconSystemName)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
                Text(section.displayName)
                    .font(MenuTypography.dataLabel)
                    .foregroundStyle(Color.primaryLabel)
                    .lineLimit(1)
                Spacer(minLength: 6)
                // fleet 段没有本地样本：fleet 同步只有聚合桶，没有单次调用时长，
                // 速度汇总无从算起——恒传 nil，速度格显示「—」（不是 0）。
                // 列形状与本地段头一致，两种形态切换时数字列不跳动。
                SectionHeaderMetricsView(
                    totalTokens: section.totalTokens,
                    tokensPerSecond: nil,
                    valueText: section.costText
                )
            }
            .padding(.bottom, 1)
            .overlay(alignment: .bottom) {
                MenuHairline.horizontal
            }
            .contextMenu {
                if let onRefreshClient {
                    Button(Self.refreshMenuTitle(displayName: section.displayName)) {
                        onRefreshClient(section.clientID)
                    }
                }
            }
        }
    }
}

/// 一个节点组：全宽节点行（名称 + 本机/离线标记 + 该节点合计）+ 该节点的模型行。
struct FleetNodeGroupView: View {
    let node: FleetMenuSummary.NodeRow
    let models: [FleetMenuSummary.ModelRow]

    var body: some View {
        VStack(alignment: .leading, spacing: HarnessModelRowView.rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("── \(node.nodeName)\(node.isLocal ? "（本机）" : "")")
                    .font(MenuTypography.dataLabel)
                    .foregroundStyle(Color.secondaryLabel)
                    .lineLimit(1)
                if node.stale {
                    Text("离线")
                        .font(MenuTypography.hint)
                        .foregroundStyle(Color.orange)
                }
                Spacer(minLength: 6)
                Text(Formatters.formatTokenCountCompact(node.totalTokens))
                    .font(MenuTypography.dataValue)
                    .foregroundStyle(Color.secondaryLabel)
                Text(node.costText)
                    .font(MenuTypography.dataValue)
                    .foregroundStyle(Color.primaryLabel)
                    .frame(width: HarnessUsageMenuView.valueWidth, alignment: .trailing)
            }
            ForEach(models) { model in
                FleetModelRowView(row: model)
            }
        }
    }
}

/// fleet 模型行：与本地模型行同一套列宽与层级（§10.2 K：只相对段头缩进一级）。
struct FleetModelRowView: View {
    let row: FleetMenuSummary.ModelRow

    var body: some View {
        HStack(spacing: HarnessModelRowView.columnSpacing) {
            // 压缩名与本机行同口径（去供应商命名空间/品牌前缀）：
            // 原始名过长时尾截断会把 "-Flash" 截没，被误读成不同模型被合并。
            Text(HarnessModelRow.compactedDisplayName(for: row.modelName))
                .font(MenuTypography.modelTitle)
                .foregroundStyle(row.stale ? Color.secondaryLabel : Color.primaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.modelName)
                .frame(width: HarnessModelRowView.modelNameWidth, alignment: .leading)
            TokenBucketBar(buckets: row.buckets)
                .frame(minWidth: HarnessModelRowView.bucketBarMinWidth, maxWidth: .infinity)
            Text(Formatters.formatTokenCountCompact(row.totalTokens))
                .font(MenuTypography.dataValue)
                .foregroundStyle(Color.secondaryLabel)
                .frame(width: HarnessModelRowView.tokenWidth, alignment: .trailing)
            Text(HarnessModelRowView.percentText(row.hitRate))
                .font(MenuTypography.dataValue)
                .foregroundStyle(Color.secondaryLabel)
                .frame(width: HarnessModelRowView.hitRateWidth, alignment: .trailing)
            Text(row.costText)
                .font(MenuTypography.dataValue)
                .foregroundStyle(Color.primaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: HarnessModelRowView.valueWidth, alignment: .trailing)
        }
        .padding(.leading, 8)
    }
}
