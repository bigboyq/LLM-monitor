import SwiftUI

/// 图表使用的单日规范化值。
///
/// Provider 数据通常已经在扫描层归一化，但 view 仍可能收到损坏的缓存值或测试构造值。
/// 在这里再次收口，避免负数柱高、格式化负 token，或 `Int` 求和溢出。
struct LocalUsageChartDayMetrics: Equatable {
    let input: Int
    let cacheRead: Int
    let cacheWrite: Int
    let output: Int
    let reasoning: Int
    let cacheTotal: Int
    let inputTotal: Int
    let outputTotal: Int

    /// 用于绘图的输出分量。正常值与原 token 数相同；当 `output + reasoning`
    /// 超出 `Int.max` 时按比例压缩到饱和总量，确保堆叠柱不超过其总高度。
    let outputChartValue: Double
    let reasoningChartValue: Double

    init<Daily: LocalUsageDaily>(_ day: Daily) {
        let safeInput = SaturatingArithmetic.add(day.input, 0)
        let safeCacheRead = SaturatingArithmetic.add(day.cacheRead, 0)
        let safeCacheWrite = SaturatingArithmetic.add(day.cacheWrite, 0)
        let safeOutput = SaturatingArithmetic.add(day.output, 0)
        let safeReasoning = SaturatingArithmetic.add(day.reasoning, 0)
        let safeOutputTotal = day.outputTotal

        input = safeInput
        cacheRead = safeCacheRead
        cacheWrite = safeCacheWrite
        output = safeOutput
        reasoning = safeReasoning
        // cacheWrite remains available in the raw daily object for diagnostics,
        // but is intentionally excluded from the estimate/chart layer.
        cacheTotal = safeCacheRead
        inputTotal = day.inputTotal
        outputTotal = safeOutputTotal

        let rawOutput = Double(safeOutput)
        let rawReasoning = Double(safeReasoning)
        let rawTotal = rawOutput + rawReasoning
        let representedTotal = Double(safeOutputTotal)
        let scale = rawTotal > representedTotal && rawTotal > 0
            ? representedTotal / rawTotal
            : 1
        outputChartValue = rawOutput * scale
        reasoningChartValue = rawReasoning * scale
    }
}

/// 一次遍历计算图表的三个缩放基准，避免 SwiftUI body 中为每种 token 重复扫描数组。
struct LocalUsageChartScale: Equatable {
    let maxUncached: Double
    let maxCachedWeight: Double
    let maxOutputWeight: Double

    init<Daily: LocalUsageDaily>(days: [Daily]) {
        var maxInput = 0
        var maxCacheWeight = 0.0
        var maxOutput = 0

        for day in days {
            let metrics = LocalUsageChartDayMetrics(day)
            maxInput = max(maxInput, metrics.input)
            maxCacheWeight = max(maxCacheWeight, TokenChartScale.weight(for: metrics.cacheTotal))
            // 必须比较每一天的 output + reasoning；分别取最大值后相加会把不同日期
            // 的峰值错误地组合起来，导致所有输出柱被压矮。
            maxOutput = max(maxOutput, metrics.outputTotal)
        }

        maxUncached = Double(max(maxInput, 1))
        maxCachedWeight = max(maxCacheWeight, 1)
        maxOutputWeight = Double(max(maxOutput, 1))
    }
}

// `SevenDayUsageChartMetrics` 搬到了 Services/LayoutMetrics.swift：Services 侧的
// `EdgeDockTheme.popoverWidth` 要读它，留在本文件会让 Services 反向依赖视图。

/// 7-day token 用量 hover 图表（泛型）—— 4 类 provider 数据共用。
///
/// 取代了原来 3 个几乎一样的 view，并接入 OpenCode daily 数据：
/// - `AntigravitySevenDayHoverView`（原 ProviderCardView 内，行号随多次重构失效）
/// - `SevenDayTokenUsageHoverView`（原 codex 侧，同上）
/// - `MinimaxSevenDayHoverView` (我刚加的)
///
/// 视觉完全等价：相同的 4 色（input 蓝 / cache 青 / output 绿 / reason 橙）、
/// 相同的柱高算法（25.6 input + 38.4 cache + 64.0 output）、
/// 相同的 R/T 表格 + 相同的 390pt 宽度限制。
///
/// 字段访问通过 `LocalUsageDaily` 协议统一（见 `Models/LocalUsageDaily.swift`）：
/// antigravity / codex / minimax 各自 computed property adapter。
struct SevenDayTokenUsageHoverView<Daily: LocalUsageDaily>: View {
    let days: [Daily]
    let scannedAt: Date?
    let isScanning: Bool
    /// 来源快照被扫描预算截断（如 DSH 文件数/字节预算挤出最旧 session）时为 true：
    /// 图内数字只是最新优先子集，底部需提示口径（与设置页展开行同一文案常量）。
    let isTruncated: Bool
    /// Optional per-day cost text. Client settings passes this so the table
    /// reads `Reason → 价值`; provider cards keep the historical 6-column view.
    ///
    /// `@autoclosure`：`HoverInfoRow` 在 init 时就会求值 detail 闭包，若这里直接
    /// 收 `[Date: String]`，卡片 footer 的每次 body 重算都会白跑一遍
    /// `ModelPricingCatalog` 定价估算——即使 hover 图从未打开。收闭包并只在
    /// 本 view 的 body 内调用，定价计算才真正惰性化。
    private let priceByDayProvider: () -> [Date: String]

    /// 宿主形态：dock 详情浮层的 `.alwaysVisible` 里，标题与新鲜度徽章都被提到了
    /// 卡片外面（见 `ProviderCardView.dockSectionTitle`），这里不能再画一遍。
    @Environment(\.hoverRevealMode) private var revealMode

    init(
        days: [Daily],
        scannedAt: Date?,
        isScanning: Bool,
        isTruncated: Bool = false,
        priceByDay: @autoclosure @escaping () -> [Date: String] = [:]
    ) {
        self.days = days
        self.scannedAt = scannedAt
        self.isScanning = isScanning
        self.isTruncated = isTruncated
        self.priceByDayProvider = priceByDay
    }

    private let inputColor = Color.tokenInputTint
    private let cacheColor = Color.tokenCacheReadTint
    private let outputColor = Color.tokenOutputTint
    private let reasonColor = Color(red: 0.90, green: 0.46, blue: 0.16)

    var body: some View {
        let chartScale = LocalUsageChartScale(days: days)
        let priceByDay = priceByDayProvider()

        VStack(alignment: .leading, spacing: 9) {
            // dock 详情浮层里整行标题都被提到了卡片外面（标题是「最近7天token用量」，
            // 右侧是同一个新鲜度徽章，见 `ProviderCardView.dockSectionTitle`），
            // 这里再画一遍就是同一行出现两次。菜单侧没有那一行，必须保留。
            if revealMode != .alwaysVisible {
                HStack(alignment: .firstTextBaseline) {
                    Text("最近 7 天 Token 用量")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    LocalUsageFreshnessBadge(scannedAt: scannedAt, isScanning: isScanning)
                }
            }

            HStack(spacing: 10) {
                LocalUsageLegendDot(color: inputColor, title: "Input")
                LocalUsageLegendDot(color: cacheColor, title: "Cache")
                LocalUsageLegendDot(color: outputColor, title: "Output")
                LocalUsageLegendDot(color: reasonColor, title: "Reason")
            }

            HStack(alignment: .bottom, spacing: 5) {
                ForEach(days) { day in
                    let metrics = LocalUsageChartDayMetrics(day)
                    let uncachedHeight = CGFloat(25.6 * (Double(metrics.input) / chartScale.maxUncached))
                    let cachedHeight = CGFloat(
                        38.4 * (TokenChartScale.weight(for: metrics.cacheTotal) / chartScale.maxCachedWeight)
                    )
                    let outputHeight = CGFloat(64.0 * (metrics.outputChartValue / chartScale.maxOutputWeight))
                    let reasoningHeight = CGFloat(64.0 * (metrics.reasoningChartValue / chartScale.maxOutputWeight))

                    LocalUsageDayBar(
                        day: day,
                        uncachedHeight: uncachedHeight,
                        cachedHeight: cachedHeight,
                        outputHeight: outputHeight,
                        reasoningHeight: reasoningHeight,
                        inputColor: inputColor,
                        cacheColor: cacheColor,
                        outputColor: outputColor,
                        reasonColor: reasonColor
                    )
                }
            }
            .frame(maxWidth: .infinity)

            Divider().opacity(0.45)

            Grid(alignment: .leading, horizontalSpacing: 3, verticalSpacing: 4) {
                GridRow {
                    tableHeader("日期", width: 34, alignment: .leading)
                    tableHeader("R/T", width: 48, alignment: .trailing)
                    tableHeader("Input", width: 58, alignment: .trailing)
                    tableHeader("Cache", width: 58, alignment: .trailing)
                    tableHeader("Output", width: 58, alignment: .trailing)
                    tableHeader("Reason", width: 58, alignment: .trailing)
                    if priceByDay.isEmpty == false {
                        tableHeader("价值", width: 62, alignment: .trailing)
                    }
                }
                ForEach(days) { day in
                    let metrics = LocalUsageChartDayMetrics(day)
                    GridRow {
                        Text(Formatters.formatMonthDay(day.dayStart))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .leading)
                        roundsTurnsValue(day, width: 48)
                        tokenValue(metrics.input, color: inputColor, width: 58)
                        tokenValue(metrics.cacheTotal, color: cacheColor, width: 58)
                        tokenValue(metrics.output, color: outputColor, width: 58)
                        tokenValue(metrics.reasoning, color: reasonColor, width: 58)
                        if priceByDay.isEmpty == false {
                            priceValue(priceByDay[day.dayStart] ?? "—", width: 62)
                        }
                    }
                }
            }

            Text("输入：Uncached 线性缩放（占最大高度 40%），Cache 按 Token^0.3 缩放（占最大高度 60%）；输出线性缩放。R/T = rounds / turns。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            if isTruncated {
                Text(ClientUsageTruncationNotice.text)
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
            }
        }
        // 宽度必须装下柱区（415）：旧的 390 会让首尾两天的柱溢出 frame 被浮层裁掉。
        .frame(
            width: priceByDay.isEmpty
                ? SevenDayUsageChartMetrics.barsWidth
                : SevenDayUsageChartMetrics.pricedWidth,
            alignment: .leading
        )
    }

    private func tableHeader(_ title: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }

    private func tokenValue(_ value: Int, color: Color, width: CGFloat) -> some View {
        Text(Formatters.formatTokenCountCompact(value))
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(color)
            .frame(width: width, alignment: .trailing)
    }

    private func priceValue(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(
                value == "未定价" || value.contains("部分计价") ? .orange : .secondary
            )
            .frame(width: width, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
    }

    private func roundsTurnsValue(_ day: Daily, width: CGFloat) -> some View {
        let hasActivity = day.rounds > 0 || day.turns > 0
        let text = hasActivity
            ? "\(Formatters.formatGroupedInt(day.rounds))/\(Formatters.formatGroupedInt(day.turns))"
            : "—"
        return Text(text)
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(hasActivity ? .primary : .secondary)
            .frame(width: width, alignment: .trailing)
    }
}

/// 单日柱图（泛型）—— 4 类 provider 数据共用，取代原来的 AntigravityDayBar /
/// DailyTokenUsageBarGroup / MinimaxDayBar。复用 ProviderCardView 里已有的
/// `StackedTokenBar` + `TokenBarSegment` 基础组件（无需重写柱体渲染）。
struct LocalUsageDayBar<Daily: LocalUsageDaily>: View {
    let day: Daily
    let uncachedHeight: CGFloat
    let cachedHeight: CGFloat
    let outputHeight: CGFloat
    let reasoningHeight: CGFloat
    let inputColor: Color
    let cacheColor: Color
    let outputColor: Color
    let reasonColor: Color

    var body: some View {
        let metrics = LocalUsageChartDayMetrics(day)

        VStack(spacing: 3) {
            Text(Calendar.current.isDateInToday(day.dayStart) ? "今天" : Formatters.formatMonthDay(day.dayStart))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .bottom, spacing: 4) {
                StackedTokenBar(
                    segments: [
                        TokenBarSegment(height: uncachedHeight, color: inputColor),
                        TokenBarSegment(height: cachedHeight, color: cacheColor),
                    ]
                )
                StackedTokenBar(
                    segments: [
                        TokenBarSegment(height: outputHeight, color: outputColor),
                        TokenBarSegment(height: reasoningHeight, color: reasonColor),
                    ]
                )
            }
            .frame(height: 64)

            VStack(spacing: 0) {
                Text("I \(Formatters.formatTokenCountCompact(metrics.inputTotal))")
                Text("O \(Formatters.formatTokenCountCompact(metrics.outputTotal))")
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .frame(width: 55)
    }
}

/// hover 图表里的图例点（无泛型，4 色 legend 通用）
struct LocalUsageLegendDot: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// 7 天用量的数据新鲜度：扫描中 / 更新于 `HH:mm`，**胶囊样式**。
///
/// 两个宿主放的位置不同、内容相同：菜单放在图表自己那行标题的右侧；dock 的详情
/// 浮层把标题提到了卡片外，所以放在组标题「最近7天token用量」那一行的右侧——
/// 与第一张卡片标题右侧的 `ProviderStateLabel` 用同一种胶囊，两行标题的右侧
/// 才读起来是同一类东西。
struct LocalUsageFreshnessBadge: View {
    let scannedAt: Date?
    let isScanning: Bool

    /// 空态（既不在扫描、也还没扫出过）时**整个视图不渲染**，而不是渲染一个空胶囊。
    ///
    /// 两个宿主都把它放在 `HStack` 的 `Spacer` 之后：把 opacity 压到 0 只是看不见，
    /// 那一格（文字 + 左右 6pt padding）仍会被布局算进去，于是右侧凭空多出约 20pt
    /// 的空白、标题可用宽度被悄悄吃掉。真正不存在的状态就不该占位。
    @ViewBuilder
    var body: some View {
        if isScanning {
            capsule {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("计算中…")
            }
        } else if let scannedAt {
            capsule {
                Text("更新于 \(Formatters.formatClock(scannedAt))")
            }
        }
    }

    private func capsule<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 5, content: content)
            .font(MenuTypography.badge)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1), in: Capsule())
    }
}

/// `LocalUsageFreshnessBadge` 的**裸文本**变体：状态机与颜色语义与胶囊版完全一致
/// （扫描中 → 迷你进度圈 + 「计算中…」；扫出过 → `formatClock` 时间；从没扫过 →
/// 整个视图不渲染），只是**去掉**「更新于」前缀与胶囊底色。
///
/// 存在的理由：菜单今日合计的数字行里四段数字全是定宽或撑满（见
/// `HarnessUsageMenuView.todayOverview`），行尾那格只有放**时间本身**的预算——
/// 胶囊两侧 12pt padding 加前缀会把混币价值挤到折行。悬浮窗 7 天卡等既有宿主
/// 仍用胶囊版（`LocalUsageFreshnessBadge`），两边互不影响。
struct LocalUsageFreshnessText: View {
    let scannedAt: Date?
    let isScanning: Bool

    @ViewBuilder
    var body: some View {
        if isScanning {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("计算中…")
            }
            .font(MenuTypography.badge)
            .foregroundStyle(.secondary)
        } else if let scannedAt {
            Text(Formatters.formatClock(scannedAt))
                .font(MenuTypography.badge)
                .foregroundStyle(.secondary)
        }
    }
}

/// dock 详情浮层把 7 天用量拆进两张卡片，这里决定 `LocalUsageFooterView` 出哪一半。
///
/// - `.combined`：菜单用，汇总行 + 分隔线 + 图表，一个 `HoverInfoRow` 原地展开
/// - `.summary`：进上一张卡片的"今天 …"汇总行
/// - `.detail`：下一张卡片的图表 + 用量表 + 脚注
///
/// 切分点是 `HoverInfoRow` 本来就有的那条分隔线——汇总与明细的分界，不是新划的。
enum LocalUsagePart: Equatable {
    case combined
    case summary
    case detail
}

/// provider 卡片底部的"今日 token 用量"行（泛型）—— 4 类 provider 数据共用。
///
/// 取代了原来 3 个几乎一样的 view，并接入 OpenCode daily 数据：
/// - `AntigravityLocalUsageFooterView`
/// - `ChatGPTPlanLocalUsageFooterView`
/// - `MinimaxLocalUsageFooterView`（我刚加的）
///
/// 三个 provider 的 footer 差异只在 placeholder 文案 + "ready" 判断上：
/// - antigravity / minimax：`ready = dailyTokenUsage 非空`（任意一天有数据就能 hover）
/// - codex：`ready = dailyTokenUsage.count == 7`（必须 7 天满才能 hover，少于 7 天显示积累中）
/// 所以拆成：
/// - 共享的内联文案 + hover 触发（这里）
/// - provider 特定的 `emptyHint`（扫描完毕但 0 session 的提示）
/// - provider 特定的 `isReady`（caller 传 Bool 决定是否进 hover 模式）
struct LocalUsageFooterView<Daily: LocalUsageDaily>: View {
    let dailyTokenUsage: [Daily]
    let recentSamples: [LocalTokenUsageSample]
    let quotaProviderID: String
    let deepseekPeakWindow: DeepseekPeakWindow
    let scannedAt: Date?
    let isScanning: Bool
    let freshness: LocalUsageFreshness
    /// 来源快照被扫描预算截断时为 true，透传给 7 天柱图 hover 提示口径。
    let isTruncated: Bool
    let isReady: Bool
    /// "本机无 Antigravity 会话数据（~/.gemini/antigravity/conversations 为空）" 等
    /// provider 特定的"扫描完毕但还没数据"提示
    let emptyHint: String
    /// 出哪一半（见 `LocalUsagePart`）。默认整个 `HoverInfoRow`，即菜单形态。
    let part: LocalUsagePart

    init(
        dailyTokenUsage: [Daily],
        recentSamples: [LocalTokenUsageSample] = [],
        quotaProviderID: String = "",
        deepseekPeakWindow: DeepseekPeakWindow = .defaultWindow,
        scannedAt: Date?,
        isScanning: Bool,
        freshness: LocalUsageFreshness = .clean,
        isTruncated: Bool = false,
        isReady: Bool,
        emptyHint: String,
        part: LocalUsagePart = .combined
    ) {
        self.dailyTokenUsage = dailyTokenUsage
        self.recentSamples = recentSamples
        self.quotaProviderID = quotaProviderID
        self.deepseekPeakWindow = deepseekPeakWindow
        self.scannedAt = scannedAt
        self.isScanning = isScanning
        self.freshness = freshness
        self.isTruncated = isTruncated
        self.isReady = isReady
        self.emptyHint = emptyHint
        self.part = part
    }

    /// 不把数组顺序当作“今天”的依据；扫描器正常返回升序，但缓存或合并器
    /// 变化时仍应只展示当前自然日的数据。
    private var today: Daily? {
        dailyTokenUsage.last { Calendar.current.isDateInToday($0.dayStart) }
    }

    private var todaySamples: [LocalTokenUsageSample] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            return []
        }
        return recentSamples.filter {
            $0.completedAt >= todayStart && $0.completedAt < tomorrow
        }
    }

    private var todayCostText: String {
        guard !todaySamples.isEmpty else { return "—" }
        let estimate = ModelPricingCatalog.estimate(
            samples: todaySamples,
            quotaProviderID: quotaProviderID,
            deepseekPeakWindow: deepseekPeakWindow
        )
        // displayText 统一处理“未定价 / 部分计价 / 全部计价”三种覆盖度。
        return estimate.displayText
    }

    private var priceByDay: [Date: String] {
        let estimates = ModelPricingCatalog.estimateByDay(
            samples: recentSamples,
            quotaProviderID: quotaProviderID,
            deepseekPeakWindow: deepseekPeakWindow
        )
        return Dictionary(uniqueKeysWithValues: dailyTokenUsage.map { day in
            let key = Calendar.current.startOfDay(for: day.dayStart)
            let text: String
            if let estimate = estimates[key] {
                text = estimate.displayText
            } else {
                text = "—"
            }
            return (day.dayStart, text)
        })
    }

    @ViewBuilder
    private var todayMetrics: some View {
        if let today {
            HStack(spacing: 12) {
                todayMetric(label: "今天", value: "\(Formatters.formatTokenCountCompact(today.totalTokens)) tokens")
                todayMetric(label: "命中率", value: today.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                todayMetric(label: "价值", value: todayCostText)
            }
        } else {
            Text("今日暂无 Token 活动")
                .font(MenuTypography.hint)
                .foregroundStyle(.secondary)
        }
    }

    private func todayMetric(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(metricValueColor)
        }
        .font(MenuTypography.metricValue)
        .lineLimit(1)
    }

    private var metricValueColor: Color {
        switch freshness {
        case .clean:
            return Color.secondaryLabel
        case .dirty, .scanning:
            return .yellow
        case .failed:
            return .red
        }
    }

    var body: some View {
        if isReady, !dailyTokenUsage.isEmpty {
            switch part {
            case .combined:
                HoverInfoRow {
                    summaryRow
                } detail: {
                    detailView
                }
            case .summary:
                summaryRow
            case .detail:
                detailView
            }
        } else {
            // 拆成两张卡片时，"没有本地用量"这句话属于下面那张卡片（图表的位置），
            // 不是额度卡片的收尾——汇总行此时整行不存在，留个空 HStack 会把卡片的
            // 底边垫高。
            if part == .summary {
                EmptyView()
            } else {
                placeholder
            }
        }
    }

    /// 汇总行：`📈 今天 173M tokens 命中率 97.8% 价值 $20.48`。
    private var summaryRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(MenuTypography.footer)
                .foregroundStyle(.secondary)
            todayMetrics
        }
    }

    /// 明细：图例 + 柱图 + 用量表 + 脚注。标题与新鲜度徽章由宿主画在卡片外。
    private var detailView: some View {
        SevenDayTokenUsageHoverView(
            days: dailyTokenUsage,
            scannedAt: scannedAt,
            isScanning: isScanning,
            isTruncated: isTruncated,
            priceByDay: priceByDay
        )
    }

    @ViewBuilder
    private var placeholder: some View {
        HStack(spacing: 5) {
            if isScanning {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
            } else {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(MenuTypography.footer)
                    .foregroundStyle(.quaternary)
            }
            Text(placeholderText)
                .font(MenuTypography.hint)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var placeholderText: String {
        if isScanning { return "正在扫描本地 token 用量…" }
        if dailyTokenUsage.isEmpty {
            return emptyHint
        }
        // codex 在数据未满 7 天时走这里（isReady=false 但已有部分数据）
        return "本地 token 用量数据积累中（\(dailyTokenUsage.count) / 7 天）"
    }
}
