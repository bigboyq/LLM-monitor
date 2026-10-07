import SwiftUI

/// 1px 细分隔线：卡片内**模块之间**的既有分隔样式（与 7 天图表表格上方那条、
/// 旧展开浮层里的分隔线同一份样式）。模块是同一件事的几个侧面，不该用重线
/// 把它们切成几张卡。`QuotaWindowUsageSection` 内部与卡片段1 / 段2 之间共用。
struct QuotaModuleSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}

/// 「额度窗口用量」区块的**模块标题**（「额度分析 / 额度详情 / 重置卡详情」）。
///
/// 10pt secondary 但 **semibold**（第四轮改版；`MenuTypography.metricLabel`
/// 加重一档）左对齐——它是模块的名字，字号仍在正文同级、层级要压在内容之下，
/// 但和正文拉开字重：段落标题（`ProviderCardView.planSectionTitle`，11pt
/// semibold primary）> 模块标题（这里，10pt semibold secondary）> 模块正文。
/// 标题住在**模块内部**：模块按数据可用性显隐时标题跟着一起走，分隔线之下、
/// 内容之上——无数据的模块不会悬一个没有下文的标题。
struct QuotaModuleTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(MenuTypography.metricLabel.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// 额度窗口内四个 token 桶的绝对值，以及由它们算出的三个比率。
/// **为什么不用 `UsageMetricSummary` 现成的 `cacheHitRate` / `reasonRate`**：
/// 卡片上这三个数字要和「用量」态里的
/// 四桶绝对值**读起来是同一份数据**——
/// 表格写 `input`（未缓存）/`cached`/`output`/`reason`，比率就必须按这四个桶现算，
/// 否则读者拿表格里的数去验比率会对不上（`cacheHitRate` 的分母是 cache-inclusive
/// 的 `inputTokens`，与"未缓存 input + cached"这个可视口径差一个减法）。
struct QuotaWindowUsageMetrics: Equatable, Sendable {
    /// 未缓存输入（明细里的 `input` 桶）。
    let input: Int
    /// 缓存命中输入。
    let cachedInput: Int
    /// 不含思考的输出。
    let output: Int
    /// 思考 token。
    let reasoning: Int

    init(usage: UsageMetricSummary?) {
        input = max(usage?.uncachedInputTokens ?? 0, 0)
        cachedInput = max(usage.map { max($0.cachedInputTokens, 0) } ?? 0, 0)
        output = max(usage.map { max($0.outputTokens, 0) } ?? 0, 0)
        reasoning = max(usage.map { max($0.reasoningOutputTokens, 0) } ?? 0, 0)
    }

    init(input: Int, cachedInput: Int, output: Int, reasoning: Int) {
        self.input = max(input, 0)
        self.cachedInput = max(cachedInput, 0)
        self.output = max(output, 0)
        self.reasoning = max(reasoning, 0)
    }

    /// 窗口内本地 token 总量（进度条的满条宽度与那一行的数字都用它）。
    var totalTokens: Int {
        SaturatingArithmetic.sum([input, cachedInput, output, reasoning])
    }

    /// 输入侧总量：`未缓存 input + cached`。
    private var inputSideTokens: Double {
        Double(input) + Double(cachedInput)
    }

    /// 缓存命中率 = `cached / (input + cached)`。分母 0（窗口内没有任何输入）
    /// 时返回 nil，UI 显示 `—`——0/0 不是一个"0%"。
    var cacheHitRate: Double? {
        guard inputSideTokens > 0 else { return nil }
        return Double(cachedInput) / inputSideTokens
    }

    /// 出/入比 = `(reasoning + output) / (input + cached)`。分母 0 → nil。
    var outputToInputRate: Double? {
        guard inputSideTokens > 0 else { return nil }
        return (Double(reasoning) + Double(output)) / inputSideTokens
    }

    /// 思考占比 = `reasoning / (reasoning + output)`。分母 0（模型不产出输出）
    /// 时返回 nil。
    var reasoningShare: Double? {
        let total = Double(reasoning) + Double(output)
        guard total > 0 else { return nil }
        return Double(reasoning) / total
    }
}

/// 「额度窗口」卡片内的显示模式：分析（默认）与用量。
enum QuotaWindowUsageSegment: String, CaseIterable, Sendable {
    case analysis = "analysis"
    case usage = "usage"

    var title: String {
        switch self {
        case .analysis: return "分析"
        case .usage: return "用量"
        }
    }
}

/// 自绘 capsule 双段切换控件（挂在「额度窗口」模块标题行右侧）。
/// 高约 16pt，字号 MenuTypography.badge（9pt semibold），选中段带 accent 高亮。
struct QuotaWindowUsageSegmentControl: View {
    @Binding var selectedSegment: QuotaWindowUsageSegment
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 0) {
            segmentButton(.analysis)
            segmentButton(.usage)
        }
        .padding(1.5)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .frame(height: 16)
    }

    private func segmentButton(_ segment: QuotaWindowUsageSegment) -> some View {
        let isSelected = selectedSegment == segment
        return Button {
            selectedSegment = segment
        } label: {
            Text(segment.title)
                .font(MenuTypography.badge)
                .foregroundStyle(isSelected ? tint : .secondary)
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                .background(
                    isSelected
                        ? AnyView(Capsule().fill(tint.opacity(0.18)))
                        : AnyView(EmptyView())
                )
        }
        .buttonStyle(.plain)
    }
}

/// 「额度窗口」区块：将原「额度分析」与「额度详情」合并为单一可切换模块。
/// 标题行右侧带「分析 / 用量」双段 capsule 切换控件，两态共用同一套 7 列 Grid 骨架与列宽预算，
/// 切换零回流；下方常驻挂载多额度池合计脚注与重置卡详情模块。
struct QuotaWindowUsageSection: View {
    let snapshot: QuotaWindowUsageSnapshot
    var tint: Color = .primary
    /// 「今」行（当天本地用量聚合；第五轮改版标签从「今日」缩成「今」）。
    /// `nil` = 当天无本地数据，该行不画。数据由宿主取
    /// （`ProviderCardView.todayUsageRow`），当天四桶合计为 0 时照常传入，由 `visibleRows` 统一跳过。
    var today: Row?
    /// 「闲」行（GLM 今日闲时任务用量；从额度条下方的独立闲时脚注迁入表格）。
    /// `nil` = 非 GLM provider 或当天无闲时数据，该行不画。数据由宿主取
    /// （`ProviderCardDerivedValues.offPeakUsageRow`），四桶合计为 0 时照常传入，
    /// 由 `visibleRows` 统一跳过。
    var offPeak: Row?
    /// 重置卡信息；`availableCount == 0` 或 `nil` 时重置卡模块整块不画。
    var resetCredits: ResetCreditsInfo?
    /// 重置卡折叠行的过期判定用刷新周期（秒），透传给 `CompactResetCreditsRow`。
    var refreshIntervalSeconds: Int = 300
    /// 显式覆盖 segment（供单元测试等直接指定态，不覆盖时走持久化状态）。
    var segmentOverride: QuotaWindowUsageSegment? = nil

    @AppStorage(QuotaWindowUsageSection.segmentStorageKey) private var segmentRawValue: String = QuotaWindowUsageSegment.analysis.rawValue
    @Environment(\.quotaWindowSegmentEditable) private var isSegmentEditable
    /// 重置日期格倒计时的取值来源：宿主注入的展示时钟（随浮层显隐起停），
    /// 与卡内其它消费者（高峰倒计时、新鲜度胶囊）同一个 now。
    @Environment(\.displayDate) private var displayDate

    var activeSegment: QuotaWindowUsageSegment {
        segmentOverride ?? (QuotaWindowUsageSegment(rawValue: segmentRawValue) ?? .analysis)
    }

    /// 一行短指标的取数：类型格放窗口标签，用量格放 token 数，比率与价值三格只放数值。
    /// `today` 行由宿主构造后塞进 `rows`，同一组件同一格式。
    struct Row: Equatable {
        let label: String
        let metrics: QuotaWindowUsageMetrics
        let cost: ModelCostEstimate?
        let resetsAt: Date?

        init(label: String, metrics: QuotaWindowUsageMetrics, cost: ModelCostEstimate?, resetsAt: Date? = nil) {
            self.label = label
            self.metrics = metrics
            self.cost = cost
            self.resetsAt = resetsAt
        }
    }

    /// 模块标题文案（合并改版）。
    static let windowUsageTitle = "额度窗口"
    static let statsTitle = windowUsageTitle
    static let rawTableTitle = windowUsageTitle
    static let resetCreditsTitle = "重置卡详情"

    /// 「闲」行的行标签（GLM 今日闲时任务用量，从独立脚注迁入表格）。
    /// 行本身由 `ProviderCardDerivedValues` 产出；与「5h」「周」「今」同一长度档。
    /// 测试钉住，改文案必须连测试一起改。
    static let offPeakRowLabel = "闲"

    /// segment 持久化 key。
    static let segmentStorageKey = "quotaWindowUsageSegment"

    /// 「分析」态表头行文案（七列）。
    static let statsHeaders = (
        type: "类型", usage: "用量", hit: "命中",
        outputInput: "产出比", think: "思考", value: "价值", resetDate: "重置日期"
    )

    /// 「用量」态表头行文案（七列）。
    static let rawTableHeaders = (
        type: "类型", input: "Input", cached: "Cached",
        output: "Output", reason: "Reason", value: "价值", resetDate: "重置日期"
    )

    // MARK: - 列宽预算与排版常量（卡内容宽 420pt 约束）
    static let horizontalSpacing: CGFloat = 8
    static let middleColumnWidth: CGFloat = 42
    static let valueColumnWidth: CGFloat = 58
    static let resetDateColumnLeadingGap: CGFloat = 9
    static let resetDateColumnWidth: CGFloat = 126

    /// 「分析」态的列显隐（模块内跨行判定）：「命中」「思考」两列各自在所有可见行的合计为 0 时整列隐藏。
    static func statsColumnVisibility(rows: [QuotaWindowUsageMetrics]) -> (hit: Bool, think: Bool) {
        (rows.contains { $0.cachedInput > 0 }, rows.contains { $0.reasoning > 0 })
    }

    /// 「用量」态的列显隐（模块内跨行判定）：四个数值列各自在所有可见行合计为 0 时整列隐藏。
    static func numericColumnVisibility(rows: [QuotaWindowUsageMetrics])
        -> (input: Bool, cached: Bool, output: Bool, reason: Bool) {
        (
            rows.contains { $0.input > 0 },
            rows.contains { $0.cachedInput > 0 },
            rows.contains { $0.output > 0 },
            rows.contains { $0.reasoning > 0 }
        )
    }

    /// **全零行跳过**后的可见行集：某行（5h/周/今/闲）四个桶 token 合计为 0 时整行跳过，两态都不出现该行。
    /// 行序固定 5h → 周 → 今 → 闲；今 / 闲两行的重置日期格强制 `nil`（渲染 `—`）。
    static func visibleRows(snapshot: QuotaWindowUsageSnapshot, today: Row?, offPeak: Row?) -> [Row] {
        var result: [Row] = []
        if let interval = snapshot.interval {
            result.append(Row(
                label: interval.label,
                metrics: QuotaWindowUsageMetrics(usage: interval.usage),
                cost: interval.cost,
                resetsAt: interval.resetsAt
            ))
        }
        if let weekly = snapshot.weekly {
            result.append(Row(
                label: weekly.label,
                metrics: QuotaWindowUsageMetrics(usage: weekly.usage),
                cost: weekly.cost,
                resetsAt: weekly.resetsAt
            ))
        }
        if let today {
            result.append(Row(
                label: today.label,
                metrics: today.metrics,
                cost: today.cost,
                resetsAt: nil
            ))
        }
        if let offPeak {
            result.append(Row(
                label: offPeak.label,
                metrics: offPeak.metrics,
                cost: offPeak.cost,
                resetsAt: nil
            ))
        }
        return result.filter { $0.metrics.totalTokens > 0 }
    }

    /// 过滤后是否还有任何可见内容：可见行非空，或重置卡可用。宿主
    /// （`ProviderCardView`）用它决定分隔线与整块区块的显隐——行全被跳过时
    /// 分隔线不能悬在一个空区块上面。纯函数，测试直接引用。
    static func hasVisibleContent(
        snapshot: QuotaWindowUsageSnapshot,
        today: Row?,
        offPeak: Row?,
        resetCredits: ResetCreditsInfo?
    ) -> Bool {
        !visibleRows(snapshot: snapshot, today: today, offPeak: offPeak).isEmpty
            || (resetCredits?.availableCount ?? 0) > 0
    }

    // MARK: - 比率与金额格式化（从原 MetricRow 迁移）

    /// 分母为 0 的比率显示 `—`，不显示 `0%`：前者是"这个比率算不出来"，
    /// 后者会被读成"这个比率确实是 0"。
    static func rateText(_ rate: Double?, digits: Int) -> String {
        guard let rate else { return "—" }
        return Formatters.formatPercent(rate, digits: digits)
    }

    /// 产出比（出/入比）自适应百分位格式化（纯函数）：
    /// - 值 ≥ 10 → 整数百分比（`12%`、`100%`）
    /// - 1 ≤ 值 < 10 → 1 位小数（`1.2%`、`9.9%`）
    /// - 值 < 1 → 2 位小数（`0.12%`、`0.00%`）
    /// 分档按原始值判定（先分档再格式化，不是舍入后再分档）。分母为 0（nil）显示 `—`。
    static func outputInputRateText(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        let percent = rate * 100
        if percent >= 10.0 {
            return String(format: "%.0f%%", percent)
        } else if percent >= 1.0 {
            return String(format: "%.1f%%", percent)
        } else {
            return String(format: "%.2f%%", percent)
        }
    }

    /// 产出比格子的 hover 说明：格子里只有一个百分比或一个 `—`，
    /// 光标停上去才说得出代表什么——`—` 尤其需要，它不是 0%。
    static let outputInputRateHelp = "产出比 =（思考 + 输出）/（未缓存输入 + 缓存输入）"
    /// `—` 时的说明：分母是输入侧总量，会话没有输入 token 时这个比率算不出来。
    static let outputInputRateHelpUnavailable = "会话无输入 token 时产出比无法计算，显示为 —"
    /// 「闲」行类型格的 hover 说明（原独立闲时脚注的说明句，逐字保留）：
    /// 格子里只有一个「闲」字，光标停上去才说得出这一行的口径。挂在类型格
    /// 而不是整行——产出比格有自己的 `.help`，不能互相打架。
    static let offPeakRowHelp = "ZCode 闲时任务真实消耗；不影响 5h / 周积分余额"

    /// 金额超长时的紧凑单位起点：10 万。
    static let costCompactThreshold: Double = 100_000
    /// 十亿档。
    static let costCompactBillionThreshold: Double = 1_000_000_000

    /// 金额文案：常规档直接用 `ModelCostEstimate.displayText`；
    /// 只有超长金额（≥ `costCompactThreshold`）换紧凑单位。
    static func costText(_ cost: ModelCostEstimate?) -> String {
        guard let cost else { return "—" }
        guard let value = cost.value, let currency = cost.currency else {
            return cost.displayText
        }
        guard let compact = compactAmountText(value, symbol: currency.symbol) else {
            return cost.displayText
        }
        if case .partiallyPriced = cost.coverage {
            return compact + "（部分计价）"
        }
        return compact
    }

    /// 超长金额的紧凑形态：`¥123,456.78` → `¥123.5K`、`¥1,234,567.89` → `¥1.23M`、
    /// `$1,234,567,890` → `$1.23B`；低于阈值返回 nil。
    static func compactAmountText(_ value: Double, symbol: String) -> String? {
        let magnitude = abs(value)
        let divisor: Double
        let suffix: String
        let format: String
        if magnitude >= costCompactBillionThreshold {
            divisor = 1_000_000_000
            suffix = "B"
            format = "%.2f"
        } else if magnitude >= costCompactThreshold * 10 {
            divisor = 1_000_000
            suffix = "M"
            format = "%.2f"
        } else if magnitude >= costCompactThreshold {
            divisor = 1_000
            suffix = "K"
            format = "%.1f"
        } else {
            return nil
        }
        return "\(symbol)\(String(format: format, value / divisor))\(suffix)"
    }

    /// 重置日期格文案：`MM-dd HH:mm (倒计时)`，没有重置时刻写 `—`。
    /// 倒计时取 `now`（宿主注入的展示时钟），不取渲染时的墙钟。
    static func formatResetDateText(_ resetsAt: Date?, now: Date) -> String {
        guard let resetsAt else { return "—" }
        return "\(Formatters.formatMonthDayMinute(resetsAt)) (\(Formatters.formatResetSuffix(from: resetsAt, now: now)))"
    }

    var body: some View {
        let hasRows = !rows.isEmpty
        let showResets = (resetCredits?.availableCount ?? 0) > 0
        if hasRows || showResets {
            VStack(alignment: .leading, spacing: 6) {
                if hasRows {
                    windowUsageModule
                }
                if hasRows && showResets {
                    moduleSeparator
                }
                if showResets {
                    resetCreditsModule
                }
            }
        }
    }

    /// 合并后的「额度窗口」模块：标题行（含可选 segment）+ 统一 7 列 Grid + 多池披露。
    @ViewBuilder
    private var windowUsageModule: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleRow
            Grid(alignment: .leading, horizontalSpacing: Self.horizontalSpacing, verticalSpacing: 3) {
                gridHeader
                ForEach(rows, id: \.label) { row in
                    gridDataRow(row)
                }
            }
            .font(MenuTypography.metricValue)
            .lineLimit(1)

            if snapshot.poolCount > 1 {
                Text("本 provider 有 \(snapshot.poolCount) 个额度池，以上为合计；重置时间取最早的那个。")
                    .font(MenuTypography.hoverFootnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            QuotaModuleTitle(text: Self.windowUsageTitle)
            Spacer()
            if isSegmentEditable {
                QuotaWindowUsageSegmentControl(
                    selectedSegment: Binding(
                        get: { activeSegment },
                        set: { segmentRawValue = $0.rawValue }
                    ),
                    tint: tint
                )
            }
        }
    }

    @ViewBuilder
    private var gridHeader: some View {
        switch activeSegment {
        case .analysis:
            let visibility = Self.statsColumnVisibility(rows: rows.map(\.metrics))
            GridRow {
                headerCell(Self.statsHeaders.type, width: nil, alignment: .leading)
                headerCell(Self.statsHeaders.usage, width: Self.middleColumnWidth, alignment: .trailing)
                if visibility.hit {
                    headerCell(Self.statsHeaders.hit, width: Self.middleColumnWidth, alignment: .trailing)
                }
                headerCell(Self.statsHeaders.outputInput, width: Self.middleColumnWidth, alignment: .trailing)
                if visibility.think {
                    headerCell(Self.statsHeaders.think, width: Self.middleColumnWidth, alignment: .trailing)
                }
                headerCell(Self.statsHeaders.value, width: Self.valueColumnWidth, alignment: .leading)
                resetDateHeader
            }
        case .usage:
            let visibility = Self.numericColumnVisibility(rows: rows.map(\.metrics))
            GridRow {
                headerCell(Self.rawTableHeaders.type, width: nil, alignment: .leading)
                if visibility.input {
                    headerCell(Self.rawTableHeaders.input, width: Self.middleColumnWidth, alignment: .trailing)
                }
                if visibility.cached {
                    headerCell(Self.rawTableHeaders.cached, width: Self.middleColumnWidth, alignment: .trailing)
                }
                if visibility.output {
                    headerCell(Self.rawTableHeaders.output, width: Self.middleColumnWidth, alignment: .trailing)
                }
                if visibility.reason {
                    headerCell(Self.rawTableHeaders.reason, width: Self.middleColumnWidth, alignment: .trailing)
                }
                headerCell(Self.rawTableHeaders.value, width: Self.valueColumnWidth, alignment: .leading)
                resetDateHeader
            }
        }
    }

    private var resetDateHeader: some View {
        Text("重置日期")
            .font(MenuTypography.metricLabel)
            .foregroundStyle(.secondary)
            .padding(.leading, Self.resetDateColumnLeadingGap)
            .frame(width: Self.resetDateColumnWidth, alignment: .center)
    }

    @ViewBuilder
    private func gridDataRow(_ row: Row) -> some View {
        // 「闲」行的类型格挂说明句（格子的 Grid 身份就是 label，与 ForEach 的
        // `id: \.label` 同一口径）；其余行的类型格不带 `.help`，避免和产出比格
        // 自己的说明打架。
        let typeHelp = row.label == Self.offPeakRowLabel ? Self.offPeakRowHelp : nil
        switch activeSegment {
        case .analysis:
            let visibility = Self.statsColumnVisibility(rows: rows.map(\.metrics))
            GridRow {
                typeCell(row.label, help: typeHelp)
                cell(Formatters.formatTokenCountCompact(row.metrics.totalTokens), width: Self.middleColumnWidth)
                if visibility.hit {
                    rateCell(Self.rateText(row.metrics.cacheHitRate, digits: 1), width: Self.middleColumnWidth)
                }
                rateCell(
                    Self.outputInputRateText(row.metrics.outputToInputRate),
                    width: Self.middleColumnWidth,
                    help: row.metrics.outputToInputRate == nil
                        ? Self.outputInputRateHelpUnavailable
                        : Self.outputInputRateHelp
                )
                if visibility.think {
                    rateCell(Self.rateText(row.metrics.reasoningShare, digits: 0), width: Self.middleColumnWidth)
                }
                valueCell(row.cost)
                resetDateCell(row.resetsAt)
            }
        case .usage:
            let visibility = Self.numericColumnVisibility(rows: rows.map(\.metrics))
            GridRow {
                typeCell(row.label, help: typeHelp)
                if visibility.input {
                    cell(Formatters.formatTokenCountCompact(row.metrics.input), width: Self.middleColumnWidth)
                }
                if visibility.cached {
                    cell(Formatters.formatTokenCountCompact(row.metrics.cachedInput), width: Self.middleColumnWidth)
                }
                if visibility.output {
                    cell(Formatters.formatTokenCountCompact(row.metrics.output), width: Self.middleColumnWidth)
                }
                if visibility.reason {
                    cell(Formatters.formatTokenCountCompact(row.metrics.reasoning), width: Self.middleColumnWidth)
                }
                valueCell(row.cost)
                resetDateCell(row.resetsAt)
            }
        }
    }

    private func headerCell(_ title: String, width: CGFloat?, alignment: Alignment) -> some View {
        Group {
            if let width {
                Text(title)
                    .font(MenuTypography.metricLabel)
                    .foregroundStyle(.secondary)
                    .frame(width: width, alignment: alignment)
            } else {
                Text(title)
                    .font(MenuTypography.metricLabel)
                    .foregroundStyle(.secondary)
                    .gridCellAnchor(alignment == .trailing ? .trailing : .leading)
            }
        }
    }

    private func typeCell(_ label: String, help: String? = nil) -> some View {
        Text(label)
            .foregroundStyle(Color.primaryLabel)
            .gridCellAnchor(.leading)
            .help(help ?? "")
    }

    private func cell(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .trailing)
    }

    private func rateCell(_ value: String, width: CGFloat, help: String? = nil) -> some View {
        Text(value)
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: .trailing)
            .help(help ?? "")
    }

    private func valueCell(_ cost: ModelCostEstimate?) -> some View {
        Text(Self.costText(cost))
            .foregroundStyle(.secondary)
            .frame(width: Self.valueColumnWidth, alignment: .leading)
    }

    private func resetDateCell(_ resetsAt: Date?) -> some View {
        Group {
            if let resetsAt {
                Text(Self.formatResetDateText(resetsAt, now: displayDate))
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, Self.resetDateColumnLeadingGap)
        .gridCellAnchor(.leading)
    }

    @ViewBuilder
    private var resetCreditsModule: some View {
        if let resetCredits, resetCredits.availableCount > 0 {
            VStack(alignment: .leading, spacing: 5) {
                QuotaModuleTitle(text: Self.resetCreditsTitle)
                CompactResetCreditsRow(
                    resets: resetCredits,
                    refreshIntervalSeconds: refreshIntervalSeconds
                )
                ResetCreditsDetailList(resets: resetCredits)
            }
        }
    }

    private var moduleSeparator: some View {
        QuotaModuleSeparator()
    }

    private var rows: [Row] {
        Self.visibleRows(snapshot: snapshot, today: today, offPeak: offPeak)
    }
}



/// 可用重置卡的**逐张清单**：每张的到期日。
///
/// 唯一消费面是 `QuotaWindowUsageSection` 的重置卡模块（常驻，紧接折叠行下面）。
/// 第七轮删掉了 `showsHeader`：头部「可用重置卡 N 张」在那个入口永远画不出来
/// （折叠行第一行已经写了「重置卡数量：N」，再报一遍是同一屏两份总数），而
/// 「暂无可用重置卡」的空态也一并删掉——常驻入口被 `availableCount > 0` 双重
/// 把门，进来时清单必非空，留在代码里只会让读者以为"没有卡"时也会画点什么。
struct ResetCreditsDetailList: View {
    let resets: ResetCreditsInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(availableEntries.enumerated()), id: \.offset) { _, entry in
                CreditEntryRow(entry: entry)
            }
        }
    }

    /// 只列 `available`，按到期日升序（越早到期越靠前，没有日期的排后面，
    /// 再没有就按 id 稳定排序——否则同一份数据每次渲染顺序都可能不一样）。
    static func availableEntries(in resets: ResetCreditsInfo) -> [ResetCreditEntry] {
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

    private var availableEntries: [ResetCreditEntry] {
        Self.availableEntries(in: resets)
    }
}
