import SwiftUI

/// 额度窗口内四个 token 桶的绝对值，以及由它们算出的三个比率。
///
/// **为什么不用 `UsageMetricSummary` 现成的 `cacheHitRate` / `reasonRate`**：
/// 卡片上这三个数字要和下面那张 hover 明细里的四桶绝对值**读起来是同一份数据**——
/// 明细写 `input`（未缓存）/`cached`/`output`/`reason`，比率就必须按这四个桶现算，
/// 否则读者拿明细里的数去验比率会对不上（`cacheHitRate` 的分母是 cache-inclusive
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

/// 「额度窗口用量」区块：一条时间构成条 + 每个窗口一行短指标。
///
/// 位置由宿主决定（`ProviderCardView` 放在额度区之后、本地用量 footer 之前）：
/// 它回答的是"这一轮额度里本机烧了多少"，与下面那张卡的"今天 / 最近 7 天"是两件事。
///
/// **整个区块是时间构成，不是桶构成**：满条 = 周窗口内本地 token 总量，两段只把
/// 其中"最近 5h"与"5h 之外"分开。要看四个桶的绝对值，hover（或浮层里就地展开）
/// 下面的明细。
///
/// 余额型 provider（DeepSeek，没有额度窗口）整块不画——`snapshot.isEmpty` 时调用方
/// 什么都不渲染，而不是画一条永远空的条。
///
/// `resetCredits` 是**搭车**进来的：重置卡在额度区里只显示折叠态那一句（总数 +
/// 最近到期），逐张明细挂在 `HoverInfoRow` 上，而两个宿主都在
/// `ignoresMouseEvents = true` 的浮层里，纯 hover 展不开——明细等于不存在。
/// 与其再找第二个展开入口（这张卡里没有第二处可展），不如并到这个浮层：
/// 它本来就是"这一轮额度的补充信息"，明细与四桶绝对值回答的是同一个问题。
struct QuotaWindowUsageSection: View {
    let snapshot: QuotaWindowUsageSnapshot
    var tint: Color = .primary
    var resetCredits: ResetCreditsInfo?

    var body: some View {
        if !snapshot.isEmpty || resetCredits != nil {
            HoverInfoRow {
                summary
            } detail: {
                QuotaWindowUsageHoverView(snapshot: snapshot, resetCredits: resetCredits)
            }
        }
    }

    /// 常驻内容：条 + 每个窗口一行。空快照（只有重置卡可展示）时这块不画。
    @ViewBuilder
    private var summary: some View {
        if !snapshot.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                QuotaWindowTimeShareBar(
                    primaryFraction: barFractions.primary,
                    remainderFraction: barFractions.remainder,
                    tint: tint
                )
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows, id: \.label) { row in
                        QuotaWindowUsageMetricRow(
                            label: row.label,
                            metrics: row.metrics,
                            cost: row.cost
                        )
                    }
                }
            }
        }
    }

    /// `5h 173M · 命中 97.8% · 出/入 12% · 思考 41% · ¥12.34` 里的五段。
    private struct Row: Equatable {
        let label: String
        let metrics: QuotaWindowUsageMetrics
        let cost: ModelCostEstimate?
    }

    /// 只有**有窗口**的那几行；窗口存在但本地零用量仍然出一行（0 / `—`），
    /// 因为"这一轮还没开始用"和"根本没有这个窗口"是两件事。
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
        return result
    }

    private var barFractions: (primary: Double, remainder: Double) {
        QuotaWindowTimeShareBar.fractions(
            intervalTokens: snapshot.interval.map { QuotaWindowUsageMetrics(usage: $0.usage).totalTokens },
            weeklyTokens: snapshot.weekly.map { QuotaWindowUsageMetrics(usage: $0.usage).totalTokens }
        )
    }
}

/// 一个窗口的短指标行。五个短指标同字号、等宽数字，段间用间距分开。
///
/// `5h 173M · 命中 97.8% · 出/入 12% · 思考 41% · ¥12.34`——一行装完，
/// **不许换行**：换行之后读者会把第二段当成"另一件事"，而这里五个数讲的是同一件
/// 事（这一轮窗口烧了多少）。宽度不够时的降级顺序写在 `labels` 里：先压标签
/// （`出比` / `思`），再压间隔——数值本身一个都不压，压了就失去可比性。
struct QuotaWindowUsageMetricRow: View {
    let label: String
    let metrics: QuotaWindowUsageMetrics
    /// 该窗口内本地 token 的名义价值。`nil` 时显示 `—`（窗口内没有本地样本）。
    let cost: ModelCostEstimate?
    /// 是否用压缩标签（`出比` / `思`）。只有宽度真的不够时才为 true。
    var compactLabels: Bool = false

    /// 标签集。完整版先试，放不下再压两个最长的（`出/入`、`思考`）——它们各带一个
    /// 斜杠/双字，缩写后省出的 20pt 恰好够，不动 `命中`（最短，且缩了就认不出）。
    static func labels(compact: Bool) -> (hit: String, outIn: String, think: String) {
        compact ? ("命中", "出比", "思") : ("命中", "出/入", "思考")
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
        .font(MenuTypography.dataValue)
        .lineLimit(1)
    }

    private func row(compact: Bool) -> some View {
        let names = Self.labels(compact: compact)
        return HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(Color.primaryLabel)
            Text(Formatters.formatTokenCountCompact(metrics.totalTokens))
                .foregroundStyle(Color.primaryLabel)
            dot
            metric(names.hit, QuotaWindowUsageMetricRow.rateText(metrics.cacheHitRate, digits: 1))
            dot
            metric(names.outIn, QuotaWindowUsageMetricRow.rateText(metrics.outputToInputRate, digits: 0))
            dot
            metric(names.think, QuotaWindowUsageMetricRow.rateText(metrics.reasoningShare, digits: 0))
            dot
            metric("", QuotaWindowUsageMetricRow.costText(cost))
        }
    }

    /// 段间的 `·`。不是装饰：这一行是"同一件事的五个数"（这一轮窗口烧了多少），
    /// 靠 `·` 提示"往下读还是同一句"，而空格间距在 10pt 下和字距几乎分不开，
    /// 读者会把 `命中 97.8% 出/入 12%` 读成两段互不相干的话。
    private var dot: some View {
        Text("·")
            .foregroundStyle(.tertiary)
    }

    private func metric(_ name: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            if !name.isEmpty {
                Text(name)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    /// 分母为 0 的比率显示 `—`，不显示 `0%`：前者是"这个比率算不出来"，
    /// 后者会被读成"这个比率确实是 0"。
    static func rateText(_ rate: Double?, digits: Int) -> String {
        guard let rate else { return "—" }
        return Formatters.formatPercent(rate, digits: digits)
    }

    /// 金额文案直接用 `ModelCostEstimate.displayText`（与 7 天图表、客户端汇总
    /// 同一句），`¥12.34` / `$45.67` 原币种显示，部分计价自带后缀，不在这里另造
    /// 一套。没有本地样本是 `—`，与"有样本但都查不到价"（`未定价`）区分开。
    static func costText(_ cost: ModelCostEstimate?) -> String {
        guard let cost else { return "—" }
        return cost.displayText
    }
}

/// 额度窗口用量的明细：两个窗口各自的四桶绝对值 + 各自的重置时刻。
///
/// 排版照抄 `QuotaUsageWindowsHoverView` / `QuotaUsageWindowColumn` 那一套
/// （`label: value` 两段、10pt 等宽数字、**两个窗口并排各占一栏**），只是
/// **只留四个桶**：prompts / rounds / cache hit / reason rate 在上面的短指标行与
/// 7 天图表里已经各有一份，这里再列一遍就是同一屏里三份同样的数。
///
/// 也**不再画一行"额度窗口用量"标题**：它就挂在 `HoverInfoRow` 的分隔线上方，
/// 上面两行已经写着 `5h` / `周`，再写一遍标题只是多占一行高度（这张卡的高度
/// 上限见 `HoverRevealModeTests.testDockDetailStaysUnderTheRearrangedCeiling`）。
///
/// 并排还有一个实用理由：两栏的四行是同一组桶，横向对齐才看得出"周比 5h 多了
/// 哪一部分"；竖着堆只能靠上下位置去对齐找同一栏。
struct QuotaWindowUsageHoverView: View {
    let snapshot: QuotaWindowUsageSnapshot
    /// 额度区那张重置卡；非 nil 时本浮层末尾附逐张明细（可达性见
    /// `QuotaWindowUsageSection.resetCredits`）。
    var resetCredits: ResetCreditsInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !snapshot.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    if let interval = snapshot.interval {
                        column(interval)
                    }
                    if let weekly = snapshot.weekly {
                        column(weekly)
                    }
                }

                if snapshot.poolCount > 1 {
                    Text("本 provider 有 \(snapshot.poolCount) 个额度池，以上为合计；重置时间取最早的那个。")
                        .font(MenuTypography.hoverFootnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let resetCredits {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                ResetCreditsDetailList(resets: resetCredits)
            }
        }
    }

    private func column(_ window: QuotaWindowUsageSnapshot.Window) -> some View {
        let metrics = QuotaWindowUsageMetrics(usage: window.usage)
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(window.label) 本地 token 用量")
                .font(MenuTypography.hoverRowEmphasis)
                .foregroundStyle(.primary)
            bucket("input", metrics.input)
            bucket("cached", metrics.cachedInput)
            bucket("output", metrics.output)
            bucket("reason", metrics.reasoning)
            costRow(window.cost)
            resetRow(window.resetsAt)
        }
        // 单窗口时这一栏独占整行，不能让它按内容宽度缩到左边——两栏并排是
        // 常态，单栏要占满，否则它会读成"还有一栏空着"。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bucket(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 0) {
            Text("\(label): ")
                .foregroundStyle(.secondary)
            Text(Formatters.formatTokenCountCompact(value))
                .foregroundStyle(.primary)
        }
        .font(MenuTypography.metricValue)
    }

    /// 金额那一行与上面四行同格式。短指标行里已经有金额，这里补的是"这个金额
    /// 覆盖了哪些模型"——部分计价时短行会带后缀，展开后能看清是哪几个模型没查到
    /// 价（`ModelCostEstimate.unpricedModelNames`），否则后缀只是一句免责。
    @ViewBuilder
    private func costRow(_ cost: ModelCostEstimate?) -> some View {
        if let cost {
            HStack(spacing: 0) {
                Text("价值: ")
                    .foregroundStyle(.secondary)
                Text(cost.displayText)
                    .foregroundStyle(.primary)
            }
            .font(MenuTypography.metricValue)

            if !cost.unpricedModelNames.isEmpty {
                Text("未定价模型：" + cost.unpricedModelNames.joined(separator: "、"))
                    .font(MenuTypography.hoverFootnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 重置时刻：有就写时刻 + 倒计时，没有就写 `—`（不猜服务端时间）。
    private func resetRow(_ resetsAt: Date?) -> some View {
        HStack(spacing: 4) {
            if let resetsAt {
                Text("重置 ")
                    .foregroundStyle(.secondary)
                Text(Formatters.formatMonthDayMinute(resetsAt))
                    .foregroundStyle(.primary)
                Text("(\(Formatters.formatResetSuffix(from: resetsAt)))")
                    .foregroundStyle(.secondary)
            } else {
                Text("重置 —")
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .font(MenuTypography.metricValue)
        .lineLimit(1)
    }
}

/// 可用重置卡的**逐张清单**：总数 + 每张的到期日。
///
/// 两处消费：`QuotaWindowUsageHoverView`（dock / 菜单兜底卡的浮层，这是唯一可达
/// 路径，见 `QuotaWindowUsageSection.resetCredits`）与 `CompactResetCreditsRow`
/// 的 hover 展开态。写法提出来是因为两边必须给出**同一份**清单——用户从菜单
/// hover 看到的两张卡，和从 dock 浮层看到的，不能是两条不同的排序。
struct ResetCreditsDetailList: View {
    let resets: ResetCreditsInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("可用重置卡 \(resets.availableCount) 张")
                .font(MenuTypography.hoverRowEmphasis)
                .foregroundStyle(.primary)

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
