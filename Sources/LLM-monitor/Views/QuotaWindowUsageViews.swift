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
/// 一个模块标题（`QuotaModuleTitle`，住在模块内部，随模块一起显隐）；**全部**
/// 无数据时整块不渲染（余额型 DeepSeek：没有额度窗口、今日行也不该出现在这里
/// ——它的窗口区块本来就是空的），而不是画一条永远空的条。
struct QuotaWindowUsageSection: View {
    let snapshot: QuotaWindowUsageSnapshot
    var tint: Color = .primary
    /// 「今日」行（当天本地用量聚合）。`nil` = 当天无本地数据，该行不画。
    /// 数据由宿主取（`ProviderCardView.todayUsageRow`），与额度窗口无关，
    /// 也不参与时间构成条的比例。
    var today: Row?
    /// 重置卡信息；`availableCount == 0` 或 `nil` 时重置卡模块整块不画。
    var resetCredits: ResetCreditsInfo?
    /// 重置卡折叠行的过期判定用刷新周期（秒），透传给 `CompactResetCreditsRow`。
    var refreshIntervalSeconds: Int = 300

    /// 一行短指标：`5h 173M · 命中 97.8% · 出/入 12.345% · 思考 41% · ¥12.34`。
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

    /// 「额度分析」的列显隐（第四轮改版，**模块内跨行判定**）：「命中」「思考」
    /// 两列各自在**所有可见行**（5h/周/今日）的合计为 0 时整列隐藏——某一行的
    /// 比率是 `—` 不足以免掉一列，只有模块内没有任何行产出该桶才藏。出/入、
    /// 价值与首列（标签+token）恒在，不参与判定。纯函数，测试直接引用。
    static func statsColumnVisibility(rows: [QuotaWindowUsageMetrics]) -> (hit: Bool, think: Bool) {
        (rows.contains { $0.cachedInput > 0 }, rows.contains { $0.reasoning > 0 })
    }

    var body: some View {
        let showStats = !snapshot.isEmpty || today != nil
        let showTable = !snapshot.isEmpty
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

    /// 模块2「token用量统计值」：标题 + 时间构成条 + 每窗口一行（5h、周，再接今日）。
    ///
    /// 标题「额度分析」在**时间构成条之上**（标题属于模块，条只是模块的第一件内容）。
    /// 条只在**有额度窗口**时画：它讲的是"5h 占周窗口的比例"，没有窗口（只剩
    /// 今日行）时一条全灰的槽什么都没说。
    ///
    /// 三行指标共用**同一个** `Grid`（见 `QuotaWindowUsageMetricRow`）：五列
    /// 平分整行宽度、跨行对齐。「命中」「思考」两列的显隐是**模块级**的
    /// （`statsColumnVisibility` 跨行判定一次，每一行拿到同一对值），列才能整列
    /// 消失而不是参差。字号与单行约束由 `Grid` 统一施加（与下方
    /// `QuotaWindowUsageRawTable` 同一写法），行本体不再自带字号。
    @ViewBuilder
    private var statsModule: some View {
        QuotaModuleTitle(text: Self.statsTitle)
        if !snapshot.isEmpty {
            QuotaWindowTimeShareBar(
                primaryFraction: barFractions.primary,
                remainderFraction: barFractions.remainder,
                tint: tint
            )
        }
        Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 3) {
            let visibility = Self.statsColumnVisibility(rows: rows.map(\.metrics))
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
    /// 逐张清单不再挂 hover（`CompactResetCreditsRow` 传 `revealsDetail: false`），
    /// 直接接在折叠行下面：N 张可用的卡 = N + 1 行。清单不带头部「可用重置卡 N 张」
    /// ——数量已经在第一行里了，再报一遍就是同一屏两份总数。0 张（或没有数据）
    /// 整块不画（标题跟着一起），由 `body` 的 `showResets` 与这里的双重判定兜住。
    @ViewBuilder
    private var resetCreditsModule: some View {
        if let resetCredits, resetCredits.availableCount > 0 {
            VStack(alignment: .leading, spacing: 5) {
                QuotaModuleTitle(text: Self.resetCreditsTitle)
                CompactResetCreditsRow(
                    resets: resetCredits,
                    refreshIntervalSeconds: refreshIntervalSeconds,
                    revealsDetail: false
                )
                ResetCreditsDetailList(resets: resetCredits, showsHeader: false)
            }
        }
    }

    /// 模块之间的细分隔线：见 `QuotaModuleSeparator`。
    private var moduleSeparator: some View {
        QuotaModuleSeparator()
    }

    /// 条之下的行序：**5h、周、今日**。前两行来自额度窗口快照；窗口存在但本地
    /// 零用量仍然出一行（0 / `—`），因为"这一轮还没开始用"和"根本没有这个窗口"
    /// 是两件事。今日行排最后：它不是额度窗口，只是同格式的补充。
    private var rows: [Row] {
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
        return result
    }

    private var barFractions: (primary: Double, remainder: Double) {
        QuotaWindowTimeShareBar.fractions(
            intervalTokens: snapshot.interval.map { QuotaWindowUsageMetrics(usage: $0.usage).totalTokens },
            weeklyTokens: snapshot.weekly.map { QuotaWindowUsageMetrics(usage: $0.usage).totalTokens }
        )
    }
}

/// 「额度分析」里一个窗口行的**五个格子**（本体是 `GridRow`）：
/// `[5h 173M] [命中 97.8%] [出/入 12.345%] [思考 41%] [¥12.34]`。
///
/// 三行（5h / 周 / 今日）住在**同一个** `Grid` 里（`statsModule`），所以这五列
/// 平分整行宽度、**跨行对齐**——曾经五个指标挤在行首、段间用小圆点分开，右侧
/// 整段留白，三行各自的段落起点还互相参差。第四轮改版起五列**全部左对齐**：
/// 右对齐的价值列在三行之间参差（`¥12.34` 与 `$45.67` 宽度不同，右缘对不齐），
/// 左对齐让每行的五个指标都从各自的列起点开始读，跨行扫一列时视线是直的。
///
/// 「命中」「思考」两列可以**整列隐藏**（第四轮改版）：显隐是模块级判定
/// （`QuotaWindowUsageSection.statsColumnVisibility`，该列在所有可见行的桶合计
/// 为 0 时藏），宿主判定一次、每一行拿到同一对 `showsHitColumn` /
/// `showsThinkingColumn`——判定在行外，行本体只照办，同一 Grid 里的格子才会
/// 一起消失。出/入、价值与首列恒在。
///
/// 10pt 等宽数字、单行不折行的既有约束不变：字号与 `lineLimit` 由宿主的 `Grid`
/// 统一施加（`statsModule`），行本体不携带——修饰符包在 `GridRow` 外会让它失去
/// 网格语义。宽度不够时的降级改为**列内**的 `ViewThatFits`：`出/入` / `思考`
/// 先压成 `出比` / `思`，数值本身一个都不压。
struct QuotaWindowUsageMetricRow: View {
    let label: String
    let metrics: QuotaWindowUsageMetrics
    /// 该窗口内本地 token 的名义价值。`nil` 时显示 `—`（窗口内没有本地样本）。
    let cost: ModelCostEstimate?
    /// 「命中」列是否保留。模块内所有可见行的 cached 合计为 0 时由宿主传 `false`。
    var showsHitColumn: Bool = true
    /// 「思考」列是否保留。模块内所有可见行的 reasoning 合计为 0 时由宿主传 `false`。
    var showsThinkingColumn: Bool = true

    /// 标签集。完整版先试，放不下再压两个最长的（`出/入`、`思考`）——它们各带一个
    /// 斜杠/双字，缩写后省出的 20pt 恰好够，不动 `命中`（最短，且缩了就认不出）。
    static func labels(compact: Bool) -> (hit: String, outIn: String, think: String) {
        compact ? ("命中", "出比", "思") : ("命中", "出/入", "思考")
    }

    var body: some View {
        let names = Self.labels(compact: false)
        let compactNames = Self.labels(compact: true)
        return GridRow {
            HStack(spacing: 4) {
                Text(label)
                Text(Formatters.formatTokenCountCompact(metrics.totalTokens))
            }
            .foregroundStyle(Color.primaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsHitColumn {
                pairCell(names.hit, compactNames.hit, Self.rateText(metrics.cacheHitRate, digits: 1))
            }
            pairCell(names.outIn, compactNames.outIn, Self.outputInputRateText(metrics.outputToInputRate))
            if showsThinkingColumn {
                pairCell(names.think, compactNames.think, Self.rateText(metrics.reasoningShare, digits: 0))
            }

            Text(Self.costText(cost))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 一个「标签 + 数值」格，左对齐（第四轮改版，五列统一）。标签列内放不下时由
    /// `ViewThatFits` 降级成紧凑写法；标签只有一个写法时（`命中`）直接画，不空转
    /// 一遍降级。
    private func pairCell(_ fullLabel: String, _ compactLabel: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            if fullLabel == compactLabel {
                Text(fullLabel)
                    .foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    Text(fullLabel)
                    Text(compactLabel)
                }
                .foregroundStyle(.secondary)
            }
            Text(value)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 分母为 0 的比率显示 `—`，不显示 `0%`：前者是"这个比率算不出来"，
    /// 后者会被读成"这个比率确实是 0"。
    static func rateText(_ rate: Double?, digits: Int) -> String {
        guard let rate else { return "—" }
        return Formatters.formatPercent(rate, digits: digits)
    }

    /// 出/入比文案：**固定 3 位小数**（`xx.xxx%`）。出/入比通常只有百分之几十以内，
    /// 0 位小数会把 12.4% 与 11.6% 压成同一个 "12%"——同一 provider 的 5h / 周 /
    /// 今日三行并排时就失去可比性；固定（而不是至多）3 位还让这一段保持等宽。
    /// 分母为 0 仍是 `—`，与其它比率同一个语义。
    static func outputInputRateText(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return String(format: "%.3f%%", rate * 100)
    }

    /// 金额文案直接用 `ModelCostEstimate.displayText`（与 7 天图表、客户端汇总
    /// 同一句），`¥12.34` / `$45.67` 原币种显示，部分计价自带后缀，不在这里另造
    /// 一套。没有本地样本是 `—`，与"有样本但都查不到价"（`未定价`）区分开。
    static func costText(_ cost: ModelCostEstimate?) -> String {
        guard let cost else { return "—" }
        return cost.displayText
    }
}

/// 「token用量原始值」表：各额度窗口四个桶的**绝对值** + 各自的重置时刻，常驻。
///
/// 取代了旧版挂在 hover 上的 `QuotaWindowUsageHoverView` 两栏明细（该视图已删除）：
/// 同样的取数与格式化，只是从"展开后才看得到"变成常驻——两个宿主都不吃鼠标
/// 事件，折叠态等于不存在，绝对值要一直在屏上才回答得了"这些 token 都是什么"。
///
/// 表头 `类型 | Input | Cached | Output | Reason | 重置日期`，下面每个**存在**的
/// 额度窗口一行（`5h` / `周`；某窗口不存在就省略该行），末尾再接**今日**行
/// （第四轮改版：宿主传入的当天本地聚合，重置日期格写 `—`——今日没有窗口重置
/// 概念；当天无本地数据则不追加）。数值与旧两栏一样走 `formatTokenCountCompact`；
/// 重置日期是 `MM-dd HH:mm (倒计时)`，与额度行元信息行尾的重置时刻同一套格式化。
///
/// **全零列隐藏**（第四轮改版）：Input / Cached / Output / Reason 四列各自在
/// **所有可见行**（5h/周/今日）合计为 0 时整列隐藏——表头跟着数据格一起消失
/// （「如果整列都跳过，那么标题也跳过」说的是列表头；模块标题「额度详情」只随
/// 模块整体显隐）。类型、重置日期两列恒在。判定是 `numericColumnVisibility`
/// 一次跨行算出，表头与每一行数据格拿同一份结果。
///
/// 列宽**不均分**（第三轮起）：类型列按内容自然宽；重置日期列取**固定宽**
/// （`resetDateColumnWidth` = 最长形态自然宽 × 1.2）——第三轮的自然宽在真机上
/// 仍被四个数值列挤到缩字，固定宽之后四个数值列平分的是**剩余**宽度，重置日期
/// 完整显示、不 `minimumScaleFactor`。数值列右对齐、表头跟随其对齐方式的现状
/// 保持；重置日期列内较短的格用 `gridCellAnchor` 锚到右缘（与数值列右对齐同一
/// 读法），类型左缘对齐。
struct QuotaWindowUsageRawTable: View {
    let snapshot: QuotaWindowUsageSnapshot
    /// 「今日」行：宿主传入的当天本地聚合（`ProviderCardView.todayUsageRow`），
    /// 排在 5h/周 之后；`nil` = 当天无本地数据，不追加该行。它**参与全零列判定**
    /// ——今日有 cached 就保住 Cached 列，与「额度分析」的今日行同一份数据。
    var today: QuotaWindowUsageSection.Row?

    /// 重置日期列的**固定宽度**（第四轮改版）。
    ///
    /// 量法：与 `QuotaWindowUsageValueTests` 量宽同一手法——`NSHostingView` 承载
    /// `Text(形态).font(MenuTypography.metricValue)`（10pt medium monospacedDigit，
    /// 本表格的既有字号），不限宽测 `fittingSize.width`。最长形态是
    /// `09-30 15:07 (23h59m)`（`formatResetSuffix` 最宽的后缀，比 `2d23h`、
    /// `已过期`、`365d` 都宽），2026-10-03 实测自然宽 **117pt**，× 1.2 取
    /// 140.4pt。测试钉住「常量 ≥ 最长形态自然宽」，系统字体度量变了会先红在这里。
    static let resetDateColumnWidth: CGFloat = 117 * 1.2

    /// 表内一行（`ForEach` 的元素）：`id` 是行序——标签（`5h`/`周`/`今日`）理论上
    /// 不重复，但行序才是这张表真正的身份。
    struct TableRow: Identifiable {
        let id: Int
        let label: String
        let metrics: QuotaWindowUsageMetrics
        let resetsAt: Date?
    }

    /// 表内可见行：5h、周，再接今日（第四轮改版）。列显隐与行渲染都从这一份
    /// 取数，「今日参与全零列判定」才不会与行序漂移。
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
        return result
    }

    /// 四个数值列的显隐（第四轮改版，**模块内跨行判定**）：某列在所有可见行
    /// （5h/周/今日）合计为 0 时整列隐藏（含表头）。类型、重置日期两列恒在。
    /// 纯函数，测试直接引用。
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
        Text(title)
            .font(MenuTypography.metricLabel)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    /// 自然宽列表头（类型）：按内容取宽，`anchor` 是列内锚点（`gridCellAnchor`
    /// 只收 `UnitPoint`/`Anchor<UnitPoint>`，没有 `Alignment` 重载——`Alignment`
    /// 版本的对齐留给上面的 `frame` 分支）。
    private func naturalHeader(_ title: String, anchor: UnitPoint) -> some View {
        Text(title)
            .font(MenuTypography.metricLabel)
            .foregroundStyle(.secondary)
            .gridCellAnchor(anchor)
    }

    /// 重置日期列表头：**固定宽**（`resetDateColumnWidth`），不参与数值列的平分
    /// ——四个数值列平分的是刨去它之后的剩余宽度。右缘对齐，与数值格同一读法。
    private var resetDateHeader: some View {
        Text("重置日期")
            .font(MenuTypography.metricLabel)
            .foregroundStyle(.secondary)
            .frame(width: Self.resetDateColumnWidth, alignment: .trailing)
    }

    /// 表内一行：窗口行（5h/周）与今日行共用——差别只在标签来源与重置时刻
    /// （今日恒 `nil` → 重置日期格 `—`）。格子按 `visibility` 逐列给出，与表头
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
    /// （不猜服务端时间；今日行恒走这一格）。固定宽列：按最长形态完整显示，不
    /// `minimumScaleFactor` 压缩；较短的格锚到列右缘，与数值列的右对齐读法一致。
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
        .gridCellAnchor(.trailing)
    }
}

/// 可用重置卡的**逐张清单**：总数 + 每张的到期日。
///
/// 两处消费：`QuotaWindowUsageSection` 的重置卡模块（常驻，`showsHeader: false`）
/// 与 `CompactResetCreditsRow` 的 hover 展开态（`showsHeader: true`）。写法提出来
/// 是因为两边必须给出**同一份**清单——用户从重置卡 hover 看到的两张卡，和常驻
/// 模块里看到的，不能是两条不同的排序。
struct ResetCreditsDetailList: View {
    let resets: ResetCreditsInfo
    /// 是否画头部「可用重置卡 N 张」。常驻模块不画：折叠行第一行已经写了
    /// 「重置卡数量：N」，再报一遍就是同一屏两份总数。
    var showsHeader: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showsHeader {
                Text("可用重置卡 \(resets.availableCount) 张")
                    .font(MenuTypography.hoverRowEmphasis)
                    .foregroundStyle(.primary)
            }

            if availableEntries.isEmpty {
                Text("暂无可用重置卡")
                    .font(MenuTypography.metricValue)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(availableEntries.enumerated()), id: \.offset) { _, entry in
                    CreditEntryRow(entry: entry)
                }
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
