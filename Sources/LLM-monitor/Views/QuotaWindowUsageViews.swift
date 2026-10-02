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
/// 卡片上这三个数字要和下面那张原始值表格（`QuotaWindowUsageRawTable`）里的
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

/// 额度窗口用量条：**时间构成**，不是桶构成。
///
/// 满条 = 周额度窗口（上次重置 → 下次重置）内实际发生的本地 token 总量；
/// 左段实色 = 其中最近 5h 窗口的量，右段半透明 = 5h 之外、周窗口之内的量。
/// 底槽是灰的，零用量的窗口只剩底槽。
///
/// 刻意**不复用 `TokenBucketBar`**：那条的四段是 input / cache / output 组成，
/// 讲的是"这批 token 是什么"；这条的两段是 5h 与"5h 以外"，讲的是"这批 token
/// 什么时候烧的"。两种语义叠在同一条上，读者读不出任何一件事。
struct QuotaWindowTimeShareBar: View {
    /// 实色段 = 主窗口（优先 5h）占满条的比例。
    let primaryFraction: Double
    /// 半透明段 = 其余（主窗口之外、仍在周窗口内）的比例。
    let remainderFraction: Double
    var height: CGFloat = QuotaWindowTimeShareBar.standardHeight
    var tint: Color = .primary

    /// 6pt：这是一条"构成提示"，不是额度余量条（那类有精确百分比语义，
    /// 见 `SegmentedQuotaProgressBar` 的 8pt）。两条读法混同尺寸会让人以为
    /// 它也在表达"还剩多少"。
    static let standardHeight: CGFloat = 6
    /// 右段的不透明度。**必须与实色段拉开**：两段同色时 0.42 在浅色卡片上只差
    /// 一层薄雾，真机渲图自查过——几乎看不出分段，而"5h 之外还有一截"正是这条
    /// 条唯一要说的事情。
    static let remainderOpacity: Double = 0.28

    /// 两段比例。分母取**周窗口总量**（单窗口时取该窗口自身），负值按 0 处理，
    /// 总量为 0 → 两段全 0（纯灰底槽）。
    ///
    /// 主窗口比周窗口还大时（两个 reset 时刻不同步的极端情况）实色段被钳到 1，
    /// 不产生溢出宽度或 NaN——那种数据本身自相矛盾，条只需要不崩、不骗人。
    static func fractions(
        intervalTokens: Int?,
        weeklyTokens: Int?
    ) -> (primary: Double, remainder: Double) {
        let interval = Double(max(intervalTokens ?? 0, 0))
        let weekly = Double(max(weeklyTokens ?? 0, 0))
        let total = max(weekly, interval)
        guard total > 0 else { return (0, 0) }
        return (
            min(interval / total, 1),
            max(0, total - interval) / total
        )
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(tint)
                        .frame(width: width * CGFloat(primaryFraction))
                    Rectangle()
                        .fill(tint.opacity(Self.remainderOpacity))
                        .frame(width: width * CGFloat(remainderFraction))
                }
            }
            .frame(width: width, height: height)
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

/// 「额度窗口用量」区块：一条时间构成条 + 每窗口一行短指标 + 原始值表 + 重置卡，
/// **全部常驻**。曾经包在 `HoverInfoRow` 里的展开明细（`QuotaWindowUsageHoverView`
/// 的四桶两栏 + 重置卡清单 + 账号段）已按第二轮改版拆走：四桶绝对值上提成本区块
/// 的常驻表格（`QuotaWindowUsageRawTable`），重置卡逐张清单落到本区块末尾的常驻
/// 模块，账号段上提成卡片第一段的「Account Info」行。宿主两个（dock 浮层、菜单
/// 兜底行的 hover 卡）都不吃鼠标事件，折叠态等于不存在——常驻是唯一可达形态。
///
/// 位置由宿主决定（`ProviderCardView` 放在额度区之后、7 天用量卡之前）：
/// 它回答的是"这一轮额度里本机烧了多少"，与下面那张卡的"最近 7 天"是两件事。
///
/// 模块按数据可用性显隐，模块之间用既有细分隔线；第三轮改版起每个模块头顶有
/// 一个模块标题（`QuotaModuleTitle`，住在模块内部，随模块一起显隐）。**全零行
/// 整行跳过**（第五轮改版，见 `visibleRows`）：过滤后没有剩余行时模块（连标题
/// 一起）整体不渲染；过滤后**什么都不剩**时整块不渲染（余额型 DeepSeek：没有
/// 额度窗口、今行也不该出现在这里——它的窗口区块本来就是空的），而不是画一条
/// 永远空的条。
struct QuotaWindowUsageSection: View {
    let snapshot: QuotaWindowUsageSnapshot
    var tint: Color = .primary
    /// 「今」行（当天本地用量聚合；第五轮改版标签从「今日」缩成「今」）。
    /// `nil` = 当天无本地数据，该行不画。数据由宿主取
    /// （`ProviderCardView.todayUsageRow`），与额度窗口无关，也不参与时间构成条
    /// 的比例；当天四桶合计为 0 时照常传入，由 `visibleRows` 统一跳过。
    var today: Row?
    /// 重置卡信息；`availableCount == 0` 或 `nil` 时重置卡模块整块不画。
    var resetCredits: ResetCreditsInfo?
    /// 重置卡折叠行的过期判定用刷新周期（秒），透传给 `CompactResetCreditsRow`。
    var refreshIntervalSeconds: Int = 300

    /// 一行短指标的取数：类型格放窗口标签，用量格放 `formatTokenCountCompact`
    /// 的 token 数，比率与价值三格只放数值（列名在表头，`statsHeaders`）。
    /// `today` 行由宿主构造后塞进 `rows`，同一组件同一格式。
    struct Row: Equatable {
        let label: String
        let metrics: QuotaWindowUsageMetrics
        let cost: ModelCostEstimate?
    }

    /// 模块标题文案（第三轮改版）。测试直接引用这些常量，文案漂移会编译报错。
    static let statsTitle = "额度分析"
    static let rawTableTitle = "额度详情"
    static let resetCreditsTitle = "重置卡详情"

    /// 「额度分析」**表头行**文案（第五轮改版，与「额度详情」表头同款风格）。
    /// 测试直接引用，文案漂移会编译报错。「产出比」即原出/入列——表头出现后
    /// 数据格不再重复文字标签，列名只在表头说一次。
    static let statsHeaders = (
        type: "类型", usage: "用量", hit: "命中",
        outputInput: "产出比", think: "思考", value: "价值"
    )

    /// 「额度分析」的列显隐（第四轮改版，**模块内跨行判定**）：「命中」「思考」
    /// 两列各自在**所有可见行**（5h/周/今）的合计为 0 时整列隐藏（表头随数据格
    /// 一起消失，第五轮起有表头行）——某一行的比率是 `—` 不足以免掉一列，只有
    /// 模块内没有任何行产出该桶才藏。产出比、价值与类型、用量两列恒在，不参与
    /// 判定。调用方传**过滤后**的行（`visibleRows`；全零行本来就对任何桶都无
    /// 贡献，传过滤前行结果相同，但口径统一在过滤后）。纯函数，测试直接引用。
    static func statsColumnVisibility(rows: [QuotaWindowUsageMetrics]) -> (hit: Bool, think: Bool) {
        (rows.contains { $0.cachedInput > 0 }, rows.contains { $0.reasoning > 0 })
    }

    /// **全零行跳过**（第五轮改版）后的可见行集：某行（5h/周/今）四个桶 token
    /// 合计为 0（`totalTokens == 0`）时整行跳过，「额度分析」与「额度详情」两个
    /// 模块都不出现该行——"这一轮还没开始用"不再出 `0 / —` 行，取代第四轮前
    /// "窗口存在但本地零用量仍然出一行"的旧规则。stats rows 与 raw table 的
    /// `tableRows` 各自从这份口径过滤（同一取数、同一判定，行集一致），宿主的
    /// 整块显隐（`hasVisibleContent`）也用它。纯函数，测试直接引用。
    static func visibleRows(snapshot: QuotaWindowUsageSnapshot, today: Row?) -> [Row] {
        var result: [Row] = []
        if let interval = snapshot.interval {
            result.append(Row(
                label: interval.label,
                metrics: QuotaWindowUsageMetrics(usage: interval.usage),
                cost: interval.cost
            ))
        }
        if let weekly = snapshot.weekly {
            result.append(Row(
                label: weekly.label,
                metrics: QuotaWindowUsageMetrics(usage: weekly.usage),
                cost: weekly.cost
            ))
        }
        if let today {
            result.append(today)
        }
        return result.filter { $0.metrics.totalTokens > 0 }
    }

    /// 过滤后是否还有任何可见内容：可见行非空，或重置卡可用。宿主
    /// （`ProviderCardView`）用它决定分隔线与整块区块的显隐——行全被跳过时
    /// 分隔线不能悬在一个空区块上面。纯函数，测试直接引用。
    static func hasVisibleContent(
        snapshot: QuotaWindowUsageSnapshot,
        today: Row?,
        resetCredits: ResetCreditsInfo?
    ) -> Bool {
        !visibleRows(snapshot: snapshot, today: today).isEmpty
            || (resetCredits?.availableCount ?? 0) > 0
    }

    var body: some View {
        // 两个模块消费同一份过滤后的行集（stats rows 与 `tableRows` 同取数同
        // 判定），所以一个非空判定同时给两处当显隐开关。
        let showStats = !rows.isEmpty
        let showTable = !rows.isEmpty
        let showResets = (resetCredits?.availableCount ?? 0) > 0
        if showStats || showTable || showResets {
            VStack(alignment: .leading, spacing: 6) {
                if showStats {
                    statsModule
                }
                if showStats && (showTable || showResets) {
                    moduleSeparator
                }
                if showTable {
                    QuotaWindowUsageRawTable(snapshot: snapshot, today: today)
                }
                if showTable && showResets {
                    moduleSeparator
                }
                if showResets {
                    resetCreditsModule
                }
            }
        }
    }

    /// 模块2「token用量统计值」：标题 + 时间构成条 + 表头行 + 每窗口一行（5h、周，再接今）。
    ///
    /// 标题「额度分析」在**时间构成条之上**（标题属于模块，条只是模块的第一件内容）。
    /// 条只在**过滤后仍有窗口行**（5h/周）可见时画（第五轮改版）：全零窗口的全灰
    /// 条没有信息量，只剩今行时也一样——条讲的是"5h 占周窗口的比例"。
    ///
    /// **表头行**（第五轮改版，`QuotaWindowUsageStatsHeader`）：`类型 | 用量 |
    /// 命中 | 产出比 | 思考 | 价值`，样式与「额度详情」表头一致（10pt secondary）。
    /// 表头出现后数据格不再重复文字标签，列名只在表头说一次。
    ///
    /// 表头与数据行共用**同一个** `Grid`（见 `QuotaWindowUsageMetricRow`）：六列
    /// 平分整行宽度、跨行对齐。「命中」「思考」两列的显隐是**模块级**的
    /// （`statsColumnVisibility` 基于过滤后的行跨行判定一次，表头与每一行拿到
    /// 同一对值），列才能整列消失而不是参差。字号与单行约束由 `Grid` 统一施加
    /// （与下方 `QuotaWindowUsageRawTable` 同一写法），行本体不再自带字号。
    @ViewBuilder
    private var statsModule: some View {
        QuotaModuleTitle(text: Self.statsTitle)
        if showsTimeShareBar {
            QuotaWindowTimeShareBar(
                primaryFraction: barFractions.primary,
                remainderFraction: barFractions.remainder,
                tint: tint
            )
        }
        Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 3) {
            let visibility = Self.statsColumnVisibility(rows: rows.map(\.metrics))
            QuotaWindowUsageStatsHeader(
                showsHitColumn: visibility.hit,
                showsThinkingColumn: visibility.think
            )
            ForEach(rows, id: \.label) { row in
                QuotaWindowUsageMetricRow(
                    label: row.label,
                    metrics: row.metrics,
                    cost: row.cost,
                    showsHitColumn: visibility.hit,
                    showsThinkingColumn: visibility.think
                )
            }
        }
        .font(MenuTypography.dataValue)
        .lineLimit(1)
    }

    /// 模块4「重置卡信息」：标题 + 折叠态一行（重置卡数量：N + 最近到期）+ 逐张详情行。
    ///
    /// 逐张清单**直接接在折叠行下面**（第七轮：`CompactResetCreditsRow` 不再挂
    /// hover 展开分支，视图只渲染折叠态那一句）：N 张可用的卡 = N + 1 行。清单
    /// 不带头部「可用重置卡 N 张」——数量已经在第一行里了，再报一遍就是同一屏
    /// 两份总数。0 张（或没有数据）整块不画（标题跟着一起），由 `body` 的
    /// `showResets` 与这里的双重判定兜住。
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

    /// 模块之间的细分隔线：见 `QuotaModuleSeparator`。
    private var moduleSeparator: some View {
        QuotaModuleSeparator()
    }

    /// 条之下的**可见**行序：**5h、周、今**（全零行已跳过，见 `visibleRows`）。
    /// 前两行来自额度窗口快照；今行排最后：它不是额度窗口，只是同格式的补充。
    private var rows: [Row] {
        Self.visibleRows(snapshot: snapshot, today: today)
    }

    /// 时间构成条的显隐（第五轮改版）：只在**过滤后仍有窗口行**（5h/周）可见时
    /// 画——全零窗口的全灰条没有信息量；只剩今行时也不画（今行不是额度窗口，
    /// 不讲"5h 占周窗口的比例"）。判定与 `visibleRows` 同一口径
    /// （四桶合计 > 0），而不是"窗口存在就画"。
    private var showsTimeShareBar: Bool {
        [snapshot.interval, snapshot.weekly].contains { window in
            guard let window else { return false }
            return QuotaWindowUsageMetrics(usage: window.usage).totalTokens > 0
        }
    }

    private var barFractions: (primary: Double, remainder: Double) {
        QuotaWindowTimeShareBar.fractions(
            intervalTokens: snapshot.interval.map { QuotaWindowUsageMetrics(usage: $0.usage).totalTokens },
            weeklyTokens: snapshot.weekly.map { QuotaWindowUsageMetrics(usage: $0.usage).totalTokens }
        )
    }
}

/// 本文件两张表（`QuotaWindowUsageStatsHeader` 与 `QuotaWindowUsageRawTable`）
/// 列表头的**唯一**实现：同字体（`MenuTypography.metricLabel` 10pt）同色
/// （secondary），差别只在**列的几何**——参与平分剩余宽度的列（`alignment`
/// 分支）与按内容自然宽取宽的列（`anchor` 分支）。
///
/// 三个调用点原本各写一份 `Text(...).font(...).foregroundStyle(...)`（同字体同色
/// 只差对齐/锚点），改字号或颜色时很容易只改到其中一处；合成一个之后字体与颜色
/// 只有这一处可改，列宽策略仍由两个可选参数表达，观感不变。
fileprivate struct QuotaTableHeaderCell: View {
    let title: String
    /// 平分宽度列的列内对齐（左对齐/右对齐）。非 nil 时走 `frame` 分支。
    var alignment: Alignment?
    /// 自然宽列的列内锚点（`gridCellAnchor` 只收 `UnitPoint`/`Anchor<UnitPoint>`，
    /// 没有 `Alignment` 重载）。`alignment == nil` 时走这一支。
    var anchor: UnitPoint?

    var body: some View {
        if let alignment {
            text.frame(maxWidth: .infinity, alignment: alignment)
        } else {
            text.gridCellAnchor(anchor ?? .leading)
        }
    }

    private var text: some View {
        Text(title)
            .font(MenuTypography.metricLabel)
            .foregroundStyle(.secondary)
    }
}

/// 「额度分析」的**表头行**（第五轮改版，本体是 `GridRow`）：
/// `类型 | 用量 | 命中 | 产出比 | 思考 | 价值`。
///
/// 样式与「额度详情」的表头一致（`metricLabel` 10pt secondary），**全列左对齐**
/// （第六轮起数据格的用量/命中/产出比/思考四列改右对齐，表头不跟随、仍从列
/// 起点读起——列名是文字不是数值）。表头出现后数据格不再重复文字标签，
/// 列名只在表头说一次（见 `QuotaWindowUsageMetricRow`）。命中/思考两列的表头
/// 随模块级列显隐一起消失；类型/用量/产出比/价值四列表头恒在。表头住进与数据行
/// 同一个 `Grid`，六列才能跨行对齐。文案钉在
/// `QuotaWindowUsageSection.statsHeaders`，测试直接引用。
struct QuotaWindowUsageStatsHeader: View {
    /// 「命中」列表头是否保留，与数据格同一份模块级判定。
    var showsHitColumn: Bool = true
    /// 「思考」列表头是否保留，与数据格同一份模块级判定。
    var showsThinkingColumn: Bool = true

    var body: some View {
        let copy = QuotaWindowUsageSection.statsHeaders
        return GridRow {
            headerCell(copy.type)
            headerCell(copy.usage)
            if showsHitColumn {
                headerCell(copy.hit)
            }
            headerCell(copy.outputInput)
            if showsThinkingColumn {
                headerCell(copy.think)
            }
            headerCell(copy.value)
        }
    }

    /// 平分宽度、左对齐（表头不跟随数据格的右对齐——列名是文字不是数值）。
    private func headerCell(_ title: String) -> some View {
        QuotaTableHeaderCell(title: title, alignment: .leading)
    }
}

/// 「额度分析」里一个窗口行的**六个格子**（本体是 `GridRow`）：
/// `[5h] [173M] [97.8%] [12.345%] [41%] [¥12.34]`。
///
/// 表头行（`QuotaWindowUsageStatsHeader`）与数据行住在**同一个** `Grid` 里
/// （`statsModule`），六列平分整行宽度、**跨行对齐**。第五轮改版起首列由
/// 「标签+token 合并格」拆成类型（行标签）与用量（token 数）两列、`GridRow`
/// 由五列变六列；表头出现后**数据格不再带文字标签**——曾经每格「命中 97.8%」
/// 式的「标签+数值」连同 `ViewThatFits` 紧凑降级（`出比` / `思`）一起删除：
/// 列名只在表头说一次，格子只放数值。
///
/// **不降级的宽度核算**（第七轮起按两个宿主共同的 **420pt 卡内容宽**，不再是旧
/// 主菜单的 312pt）：`EdgeDockTheme.popoverWidth` 468 − 2×背板 padding 12 −
/// 2×卡片内容 padding 12 = 420pt。六列平分时每列 = (420 − 5×4 间距) / 6 =
/// **66.7pt**（命中/思考两列整列隐藏后按剩下的列数重新平分：4 列各 102pt）。
/// 表头最宽「产出比」三字 ≈ 31pt，数据格常规最宽「12.345%」≈ 42pt、命中率
/// 「97.8%」与价值「¥12.34」≈ 33pt，都在列宽内。价值列的超长金额（如
/// 「¥1,234,567.89」实测 ≥ 70pt）**不再靠 `lineLimit(1)` 截尾**：金额自己换紧凑单位
/// （`¥1.23M`，实测 ≈ 40pt，见 `costText` / `compactAmountText`），截尾只剩
/// `lineLimit` 这层结构保险。行高恒一格，
/// `testMetricRowStaysOnOneLineInsideTheCardContentWidth` 与表头单行断言钉住。
/// 表头层不做紧凑降级：固定三字文案在最窄列也装得下。
///
/// 「命中」「思考」两列可以**整列隐藏**（第四轮改版）：显隐是模块级判定
/// （`QuotaWindowUsageSection.statsColumnVisibility`，该列在所有可见行（过滤后）
/// 的桶合计为 0 时藏），宿主判定一次、表头与每一行拿到同一对 `showsHitColumn` /
/// `showsThinkingColumn`——判定在行外，行本体只照办，同一 Grid 里的格子才会
/// 一起消失。产出比、价值与类型、用量两列恒在。
///
/// 10pt 等宽数字、单行不折行的既有约束不变：字号与 `lineLimit` 由宿主的 `Grid`
/// 统一施加（`statsModule`），修饰符包在 `GridRow` 外会让它失去网格语义。
///
/// **对齐规则**（第六轮改版）：类型与价值是"从行首读起的文字/金额"，数据格
/// 左对齐；用量/命中/产出比/思考是等宽数字，数据格**右对齐**——同一列的数字
/// 沿右缘（个位）对齐才可比。表头不跟随，仍全列左对齐（见
/// `QuotaWindowUsageStatsHeader`）。
struct QuotaWindowUsageMetricRow: View {
    let label: String
    let metrics: QuotaWindowUsageMetrics
    /// 该窗口内本地 token 的名义价值。`nil` 时显示 `—`（窗口内没有本地样本）。
    let cost: ModelCostEstimate?
    /// 「命中」列是否保留。模块内所有可见行的 cached 合计为 0 时由宿主传 `false`。
    var showsHitColumn: Bool = true
    /// 「思考」列是否保留。模块内所有可见行的 reasoning 合计为 0 时由宿主传 `false`。
    var showsThinkingColumn: Bool = true

    var body: some View {
        return GridRow {
            Text(label)
                .foregroundStyle(Color.primaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Formatters.formatTokenCountCompact(metrics.totalTokens))
                .foregroundStyle(Color.primaryLabel)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if showsHitColumn {
                rateCell(Self.rateText(metrics.cacheHitRate, digits: 1))
            }
            rateCell(
                Self.outputInputRateText(metrics.outputToInputRate),
                help: metrics.outputToInputRate == nil
                    ? Self.outputInputRateHelpUnavailable
                    : Self.outputInputRateHelp
            )
            if showsThinkingColumn {
                rateCell(Self.rateText(metrics.reasoningShare, digits: 0))
            }
            Text(Self.costText(cost))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 比率数值格：只有数值、**右对齐**（第六轮改版；第四轮为左对齐），标签在
    /// 表头（第五轮）。`help` 非空时挂上 hover 说明（见 `outputInputRateHelp`）。
    private func rateCell(_ value: String, help: String? = nil) -> some View {
        Text(value)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(help ?? "")
    }

    /// 分母为 0 的比率显示 `—`，不显示 `0%`：前者是"这个比率算不出来"，
    /// 后者会被读成"这个比率确实是 0"。
    static func rateText(_ rate: Double?, digits: Int) -> String {
        guard let rate else { return "—" }
        return Formatters.formatPercent(rate, digits: digits)
    }

    /// 产出比（出/入比）文案：**固定 3 位小数**（`xx.xxx%`）。出/入比通常只有
    /// 百分之几十以内，0 位小数会把 12.4% 与 11.6% 压成同一个 "12%"——同一
    /// provider 的 5h / 周 / 今三行并排时就失去可比性；固定（而不是至多）3 位还
    /// 让这一段保持等宽。分母为 0 仍是 `—`，与其它比率同一个语义。
    static func outputInputRateText(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return String(format: "%.3f%%", rate * 100)
    }

    /// 产出比格子的 hover 说明（第七轮）：格子里只有一个 `xx.xxx%` 或一个 `—`，
    /// 光标停上去才说得出这两串字符各自代表什么——`—` 尤其需要，它不是 0%。
    static let outputInputRateHelp = "产出比 =（思考 + 输出）/（未缓存输入 + 缓存输入）"
    /// `—` 时的说明：分母是**输入侧**总量，会话没有输入 token 时这个比率
    /// 算不出来（而不是等于 0）。
    static let outputInputRateHelpUnavailable = "会话无输入 token 时产出比无法计算，显示为 —"

    /// 金额超长时的紧凑单位起点：**100 万**。分界线是量出来的：420pt 卡内容宽
    /// 下价值列 66.7pt，而 `¥999999.99`（阈值以下最长的原样形态）实测 **64pt**
    /// 刚好装得下，再长一格（`¥1000000.00` ≈ 77pt）就越过列宽；`¥9.88M` 实测
    /// **40pt**，离列宽还有一半余量。
    static let costCompactThreshold: Double = 1_000_000
    /// 十亿档：token 成本是名义价值，实际到不了这一档，但格式化不该在某个
    /// 数量级上突然失去单位（`¥1234567890.12` 会把列撑爆）。
    static let costCompactBillionThreshold: Double = 1_000_000_000

    /// 金额文案：常规档直接用 `ModelCostEstimate.displayText`（与 7 天图表、
    /// 客户端汇总同一句），`¥12.34` / `$45.67` 原币种显示，部分计价自带后缀，
    /// 不在这里另造一套；**只有超长金额**（≥ `costCompactThreshold`）换紧凑
    /// 单位，不再依赖 `lineLimit(1)` 截尾。没有本地样本是 `—`，与"有样本但
    /// 都查不到价"（`未定价`）区分开。
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

    /// 超长金额的紧凑形态：`¥1,234,567.89` → `¥1.23M`、`$1,234,567,890` →
    /// `$1.23B`；**低于阈值返回 nil**（由调用点回落到 `displayText` 的原币种
    /// 两位小数形态）。
    ///
    /// **为什么是 K/M/B 而不是「万」**（第七轮）：① 这一列的表头是「价值」，
    /// 同一行左边「用量」列已经在用 K/M 阶梯（`Formatters.formatTokenCountCompact`
    ///：`30K` / `3M`），读者在这一格里已经解码过这套单位了，`¥1.23M` 与它
    /// 读起来是同一种语言，而「¥123.4万」是另一套；②「万」只对人民币成立，
    /// 这一列原币种显示，`$123.4万` 是错的。单位在 10 亿 / 100 万两档升级，
    /// 与 token 那套的阶梯口径一致。
    static func compactAmountText(_ value: Double, symbol: String) -> String? {
        let magnitude = abs(value)
        let divisor: Double
        let suffix: String
        if magnitude >= costCompactBillionThreshold {
            divisor = 1_000_000_000
            suffix = "B"
        } else if magnitude >= costCompactThreshold {
            divisor = 1_000_000
            suffix = "M"
        } else {
            return nil
        }
        return "\(symbol)\(String(format: "%.2f", value / divisor))\(suffix)"
    }
}

/// 「token用量原始值」表：各额度窗口四个桶的**绝对值** + 各自的重置时刻，常驻。
///
/// 取代了旧版挂在 hover 上的 `QuotaWindowUsageHoverView` 两栏明细（该视图已删除）：
/// 同样的取数与格式化，只是从"展开后才看得到"变成常驻——两个宿主都不吃鼠标
/// 事件，折叠态等于不存在，绝对值要一直在屏上才回答得了"这些 token 都是什么"。
///
/// 表头 `类型 | Input | Cached | Output | Reason | 重置日期`，下面每个**存在且
/// 非全零**的额度窗口一行（`5h` / `周`；某窗口不存在、或四桶合计为 0 时省略该行
/// ——第五轮改版的**全零行跳过**，与「额度分析」同一规则），末尾再接**今**行
/// （第四轮改版：宿主传入的当天本地聚合，重置日期格写 `—`——今没有窗口重置
/// 概念；当天无本地数据不追加，当天全零同样被跳过）。数值与旧两栏一样走
/// `formatTokenCountCompact`；重置日期是 `MM-dd HH:mm (倒计时)`，与额度行元信息
/// 行尾的重置时刻同一套格式化。
///
/// **全零列隐藏**（第四轮改版）：Input / Cached / Output / Reason 四列各自在
/// **所有可见行**（5h/周/今，全零行跳过之后）合计为 0 时整列隐藏——表头跟着
/// 数据格一起消失（「如果整列都跳过，那么标题也跳过」说的是列表头；模块标题
/// 「额度详情」只随模块整体显隐）。类型、重置日期两列恒在。判定是
/// `numericColumnVisibility` 一次跨行算出，表头与每一行数据格拿同一份结果。
///
/// 列宽**不均分**（第三轮起）：类型列按内容自然宽；重置日期列取**固定宽**
/// （`resetDateColumnWidth` = 最长形态自然宽 × 1.2 + 前置间隙 12pt）——第三轮的
/// 自然宽在真机上仍被四个数值列挤到缩字，固定宽之后四个数值列平分的是**剩余**
/// 宽度，重置日期完整显示、不 `minimumScaleFactor`。数值列右对齐、表头跟随的
/// 现状保持；重置日期数据格**左对齐**（第五轮改版，日期文字不是数值，与类型列
/// 同一"从列起点读起"的读法，不锚右缘仿数值列），第六轮起格子与列表头各带
/// `resetDateColumnLeadingGap` 前置间隙与 Reason 列拉开可见间距，表头改在固定
/// 宽内**居中**（它标注的是整列，不是列起点），数据格仍锚在间隙之后。
///
/// 宽度口径与「额度分析」一致：两个宿主的卡内容宽都是 **420pt**
/// （`EdgeDockTheme.popoverWidth` 468 − 2×背板 padding 12 − 2×卡片内容 padding
/// 12）。四列都可见时数值列各 (420 − 152.4 固定宽 − 5×4 间距) / 4 = **61.9pt**，
/// 装得下最宽的 `formatTokenCountCompact` 形态（如 `987M` ≈ 30pt）。
struct QuotaWindowUsageRawTable: View {
    let snapshot: QuotaWindowUsageSnapshot
    /// 「今」行：宿主传入的当天本地聚合（`ProviderCardView.todayUsageRow`，
    /// 标签「今」），排在 5h/周 之后；`nil` = 当天无本地数据，不追加该行。它
    /// **参与全零列判定**——今有 cached 就保住 Cached 列，与「额度分析」的今行
    /// 同一份数据；四桶合计为 0 时同样被 `tableRows` 跳过。
    var today: QuotaWindowUsageSection.Row?

    /// 重置日期列与 Reason 列之间的**前置间隙**（第六轮改版）：重置日期不再贴着
    /// Reason 列，两侧拉开一拍可见间距。列表头（frame 内边距）与数据格（格子
    /// 前导 padding）各带这份间隙，列的固定宽把它一并算进去。
    static let resetDateColumnLeadingGap: CGFloat = 12

    /// 重置日期列的**固定宽度**（第四轮改版；第六轮起含前置间隙）。
    ///
    /// 量法：与 `QuotaWindowUsageValueTests` 量宽同一手法——`NSHostingView` 承载
    /// `Text(形态).font(MenuTypography.metricValue)`（10pt medium monospacedDigit，
    /// 本表格的既有字号），不限宽测 `fittingSize.width`。最长形态是
    /// `09-30 15:07 (23h59m)`（`formatResetSuffix` 最宽的后缀，比 `2d23h`、
    /// `已过期`、`365d` 都宽），2026-10-03 实测自然宽 **117pt**，× 1.2 取 140.4pt，
    /// 再加前置间隙 12pt 得 152.4pt——刨去间隙后文字空间与第四轮相同。测试钉住
    /// 「常量 − 间隙 ≥ 最长形态自然宽」，系统字体度量变了会先红在这里。
    static let resetDateColumnWidth: CGFloat = 117 * 1.2 + resetDateColumnLeadingGap

    /// 表内一行（`ForEach` 的元素）：`id` 是行序——标签（`5h`/`周`/`今`）理论上
    /// 不重复，但行序才是这张表真正的身份。
    struct TableRow: Identifiable {
        let id: Int
        let label: String
        let metrics: QuotaWindowUsageMetrics
        let resetsAt: Date?
    }

    /// 表内可见行：5h、周，再接今，**全零行已跳过**（第五轮改版，与
    /// `QuotaWindowUsageSection.visibleRows` 同一取数、同一判定——四桶合计为 0
    /// 的行整行不出）。列显隐与行渲染都从这一份取数，「今参与全零列判定」才
    /// 不会与行序漂移，列显隐也天然基于过滤后的行。
    var tableRows: [TableRow] {
        var result: [TableRow] = []
        if let interval = snapshot.interval {
            result.append(TableRow(
                id: result.count,
                label: interval.label,
                metrics: QuotaWindowUsageMetrics(usage: interval.usage),
                resetsAt: interval.resetsAt
            ))
        }
        if let weekly = snapshot.weekly {
            result.append(TableRow(
                id: result.count,
                label: weekly.label,
                metrics: QuotaWindowUsageMetrics(usage: weekly.usage),
                resetsAt: weekly.resetsAt
            ))
        }
        if let today {
            result.append(TableRow(
                id: result.count,
                label: today.label,
                metrics: today.metrics,
                resetsAt: nil
            ))
        }
        return result.filter { $0.metrics.totalTokens > 0 }
    }

    /// 四个数值列的显隐（第四轮改版，**模块内跨行判定**）：某列在所有可见行
    /// （5h/周/今，全零行跳过之后）合计为 0 时整列隐藏（含表头）。类型、重置
    /// 日期两列恒在。纯函数，测试直接引用。
    static func numericColumnVisibility(rows: [QuotaWindowUsageMetrics])
        -> (input: Bool, cached: Bool, output: Bool, reason: Bool) {
        (
            rows.contains { $0.input > 0 },
            rows.contains { $0.cachedInput > 0 },
            rows.contains { $0.output > 0 },
            rows.contains { $0.reasoning > 0 }
        )
    }

    var body: some View {
        let visibility = Self.numericColumnVisibility(rows: tableRows.map(\.metrics))
        VStack(alignment: .leading, spacing: 5) {
            QuotaModuleTitle(text: QuotaWindowUsageSection.rawTableTitle)
            Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    naturalHeader("类型", anchor: .leading)
                    if visibility.input { header("Input", alignment: .trailing) }
                    if visibility.cached { header("Cached", alignment: .trailing) }
                    if visibility.output { header("Output", alignment: .trailing) }
                    if visibility.reason { header("Reason", alignment: .trailing) }
                    resetDateHeader
                }
                ForEach(tableRows) { row in
                    dataRow(
                        label: row.label,
                        metrics: row.metrics,
                        resetsAt: row.resetsAt,
                        visibility: visibility
                    )
                }
            }
            .font(MenuTypography.metricValue)
            .lineLimit(1)

            if snapshot.poolCount > 1 {
                // 多额度池合计的口径披露：合计数 + 最早重置，不加这句会被读成
                // "这个 provider 只重置一次"。（旧 hover 明细里就有，随常驻表格保留。）
                Text("本 provider 有 \(snapshot.poolCount) 个额度池，以上为合计；重置时间取最早的那个。")
                    .font(MenuTypography.hoverFootnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 数值列表头（Input / Cached / Output / Reason）：参与平分剩余宽度，
    /// 对齐方式跟随数值格（右对齐）。
    private func header(_ title: String, alignment: Alignment) -> some View {
        QuotaTableHeaderCell(title: title, alignment: alignment)
    }

    /// 自然宽列表头（类型）：按内容取宽，`anchor` 是列内锚点（见
    /// `QuotaTableHeaderCell.anchor`）。
    private func naturalHeader(_ title: String, anchor: UnitPoint) -> some View {
        QuotaTableHeaderCell(title: title, anchor: anchor)
    }

    /// 重置日期列表头：**固定宽**（`resetDateColumnWidth`），不参与数值列的平分
    /// ——四个数值列平分的是刨去它之后的剩余宽度。**居中**（第六轮改版）：表头
    /// 标注的是整列，不再锚列起点。间隙放在 frame **之内**（padding 先于
    /// frame），刨去间隙后标题的文字空间不变。数据格仍左对齐（见 `resetCell`）。
    private var resetDateHeader: some View {
        Text("重置日期")
            .font(MenuTypography.metricLabel)
            .foregroundStyle(.secondary)
            .padding(.leading, Self.resetDateColumnLeadingGap)
            .frame(width: Self.resetDateColumnWidth, alignment: .center)
    }

    /// 表内一行：窗口行（5h/周）与今行共用——差别只在标签来源与重置时刻
    /// （今恒 `nil` → 重置日期格 `—`）。格子按 `visibility` 逐列给出，与表头
    /// 同一份判定。
    private func dataRow(
        label: String,
        metrics: QuotaWindowUsageMetrics,
        resetsAt: Date?,
        visibility: (input: Bool, cached: Bool, output: Bool, reason: Bool)
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(Color.primaryLabel)
                .gridCellAnchor(.leading)
            if visibility.input { cell(Formatters.formatTokenCountCompact(metrics.input)) }
            if visibility.cached { cell(Formatters.formatTokenCountCompact(metrics.cachedInput)) }
            if visibility.output { cell(Formatters.formatTokenCountCompact(metrics.output)) }
            if visibility.reason { cell(Formatters.formatTokenCountCompact(metrics.reasoning)) }
            resetCell(resetsAt)
        }
    }

    /// 数值格：等宽数字、次要色——它们是"原始值"，主角是行首的窗口标签。
    private func cell(_ value: String) -> some View {
        Text(value)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// 重置日期 = `MM-dd HH:mm (倒计时)`，取数与格式化与旧 hover 的重置行同一套
    /// （`formatMonthDayMinute` + `formatResetSuffix`）。没有重置时刻写 `—`
    /// （不猜服务端时间；今行恒走这一格）。固定宽列：按最长形态完整显示，不
    /// `minimumScaleFactor` 压缩；**左对齐**（第五轮改版，日期文字不是数值，
    /// 不跟随数值列的右对齐；第六轮起表头另改居中），带 `resetDateColumnLeadingGap`
    /// 前置间隙与 Reason 列拉开——padding 在 anchor 之内，锚的仍是"间隙之后"
    /// 的格首。
    private func resetCell(_ resetsAt: Date?) -> some View {
        Group {
            if let resetsAt {
                Text("\(Formatters.formatMonthDayMinute(resetsAt)) (\(Formatters.formatResetSuffix(from: resetsAt)))")
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, Self.resetDateColumnLeadingGap)
        .gridCellAnchor(.leading)
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
