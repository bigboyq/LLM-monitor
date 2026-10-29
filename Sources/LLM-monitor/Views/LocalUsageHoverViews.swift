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

/// Compatibility wrapper for existing local provider call sites. All history rendering
/// is delegated to the shared selectable line-chart view.
struct SevenDayTokenUsageHoverView<Daily: LocalUsageDaily>: View {
    let days: [Daily]
    let scannedAt: Date?
    let isScanning: Bool
    /// 来源快照被扫描预算截断（如 DSH 文件数/字节预算挤出最旧 session）时为 true：
    /// 图内数字只是最新优先子集，底部需提示口径（与设置页展开行同一文案常量）。
    let isTruncated: Bool
    private let costByDay: [Date: ModelCostEstimate]
    private let speedStatisticsByDay: [Date: PromptSpeedStatistics]
    private let samplesTruncated: Bool

    init(
        days: [Daily],
        scannedAt: Date?,
        isScanning: Bool,
        isTruncated: Bool = false,
        costByDay: [Date: ModelCostEstimate] = [:],
        speedStatisticsByDay: [Date: PromptSpeedStatistics] = [:],
        samplesTruncated: Bool = false,
        // Ignored compatibility parameters. Cost and speed must enter as numeric values.
        priceByDay: @autoclosure @escaping () -> [Date: String] = [:],
        speedByDay: @autoclosure @escaping () -> [Date: String] = [:],
        lastColumnFollowsSegment: Bool = false
    ) {
        self.days = days
        self.scannedAt = scannedAt
        self.isScanning = isScanning
        self.isTruncated = isTruncated
        self.costByDay = costByDay
        self.speedStatisticsByDay = speedStatisticsByDay
        self.samplesTruncated = samplesTruncated
        _ = priceByDay
        _ = speedByDay
        _ = lastColumnFollowsSegment
    }

    var body: some View {
        SevenDayUsageHistoryView(
            days: UsageHistorySeriesBuilder.build(
                days: days,
                costByDay: costByDay,
                speedByDay: speedStatisticsByDay,
                samplesTruncated: samplesTruncated,
                isTruncated: isTruncated
            ),
            scannedAt: scannedAt,
            isScanning: isScanning,
            isTruncated: isTruncated
        )
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

/// 7 天用量的数据新鲜度状态机：胶囊版与裸文本版共享的**唯一事实来源**。
///
/// 两个宿主要的是逐字一致的文案与相同的空态语义，所以状态判定只在这里做一遍；
/// 皮肤（胶囊 / 裸文本）只决定「怎么包」，不决定「出什么」。
/// 保持 internal（而非 private）：状态级文案断言（裸时间、空态不占位）直接钉在
/// 它身上，同 `HarnessModelRowView` 为排版预算断言保持 internal 的理由。
enum LocalUsageFreshnessState: Equatable {
    /// 在扫描：迷你进度圈 + 「计算中…」
    case scanning
    /// 扫出过：已按 `formatClock` 格式化的时间
    case updated(String)
    /// 既不在扫描、也还没扫出过：空态，整个视图不该渲染
    case absent

    init(scannedAt: Date?, isScanning: Bool) {
        if isScanning {
            self = .scanning
        } else if let scannedAt {
            self = .updated(Formatters.formatClock(scannedAt))
        } else {
            self = .absent
        }
    }

    /// 空态（`absent`）不占位。宿主都把它放在 `HStack` 的 `Spacer` 之后：把 opacity
    /// 压到 0 只是看不见，那一格（文字 + 左右 padding）仍会被布局算进去，于是右侧凭空
    /// 多出空白、标题可用宽度被悄悄吃掉。真正不存在的状态就不该占位。
    var isPresent: Bool { self != .absent }

    @ViewBuilder
    func content() -> some View {
        switch self {
        case .scanning:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("计算中…")
            }
            .font(MenuTypography.badge)
            .foregroundStyle(.secondary)
        case .updated(let clock):
            Text(clock)
                .font(MenuTypography.badge)
                .foregroundStyle(.secondary)
        case .absent:
            EmptyView()
        }
    }
}

/// 7 天用量的数据新鲜度：扫描中 / 裸 `HH:mm`，**胶囊样式**（2026-10-13 起与
/// header 的 `ProviderStateLabel` 统一为裸时间，不再带「更新于」前缀）。
///
/// 两个宿主放的位置不同、内容相同：菜单放在图表自己那行标题的右侧；dock 的详情
/// 浮层把标题提到了卡片外，所以放在组标题「最近7天token用量」那一行的右侧——
/// 与第一张卡片标题右侧的 `ProviderStateLabel` 用同一种胶囊，两行标题的右侧
/// 才读起来是同一类东西。
struct LocalUsageFreshnessBadge: View {
    let scannedAt: Date?
    let isScanning: Bool

    @ViewBuilder
    var body: some View {
        if state.isPresent {
            capsule {
                state.content()
            }
        }
    }

    private var state: LocalUsageFreshnessState {
        .init(scannedAt: scannedAt, isScanning: isScanning)
    }

    private func capsule<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 5, content: content)
            .font(MenuTypography.badge)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("本地用量更新时间")
            .help("本地用量更新时间")
    }
}

/// `LocalUsageFreshnessBadge` 的**裸文本**变体：状态机与颜色语义与胶囊版完全一致
/// （扫描中 → 迷你进度圈 + 「计算中…」；扫出过 → `formatClock` 时间；从没扫过 →
/// 整个视图不渲染），只是**去掉**胶囊底色（2026-10-13 起徽章同样不带「更新于」
/// 前缀，两个皮肤只剩包装上的差别）。
///
/// 存在的理由：菜单今日合计的数字行里四段数字全是定宽或撑满（见
/// `HarnessUsageMenuView.todayOverview`），行尾那格只有放**时间本身**的预算——
/// 胶囊两侧 12pt padding 会把混币价值挤到折行。悬浮窗 7 天卡等既有宿主
/// 仍用胶囊版（`LocalUsageFreshnessBadge`），两边互不影响。
struct LocalUsageFreshnessText: View {
    let scannedAt: Date?
    let isScanning: Bool

    @ViewBuilder
    var body: some View {
        if state.isPresent {
            state.content()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("本地用量更新时间")
                .help("本地用量更新时间")
        }
    }

    private var state: LocalUsageFreshnessState {
        .init(scannedAt: scannedAt, isScanning: isScanning)
    }
}

/// dock 详情浮层把 7 天用量拆进两张卡片，这里决定 `LocalUsageFooterView` 出哪一半。
///
/// - `.detail`：下一张卡片的图表 + 用量表 + 脚注
///
/// 切分点是 `HoverInfoRow` 本来就有的那条分隔线——汇总与明细的分界，不是新划的。
enum LocalUsagePart: Equatable {
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
    /// Recent prompt samples can be truncated independently of authoritative daily buckets.
    let samplesTruncated: Bool
    let isReady: Bool
    /// "本机无 Antigravity 会话数据（~/.gemini/antigravity/conversations 为空）" 等
    /// provider 特定的"扫描完毕但还没数据"提示
    let emptyHint: String
    /// 出哪一半（见 `LocalUsagePart`）。生产路径恒为 `.detail`。
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
        samplesTruncated: Bool = false,
        // Ignored compatibility parameters; the shared history view owns its own
        // metric selection and receives numeric prompt-speed statistics.
        speedByDay: @autoclosure @escaping () -> [Date: String] = [:],
        lastColumnFollowsSegment: Bool = false,
        isReady: Bool,
        emptyHint: String,
        part: LocalUsagePart = .detail
    ) {
        self.dailyTokenUsage = dailyTokenUsage
        self.recentSamples = recentSamples
        self.quotaProviderID = quotaProviderID
        self.deepseekPeakWindow = deepseekPeakWindow
        self.scannedAt = scannedAt
        self.isScanning = isScanning
        self.freshness = freshness
        self.isTruncated = isTruncated
        self.samplesTruncated = samplesTruncated
        _ = speedByDay
        _ = lastColumnFollowsSegment
        self.isReady = isReady
        self.emptyHint = emptyHint
        self.part = part
    }

    var body: some View {
        if isReady, !dailyTokenUsage.isEmpty {
            detailView
        } else {
            // "没有本地用量"这句话属于图表那半张卡片。
            placeholder
        }
    }

    /// 明细：共享历史折线图与指标表。标题与新鲜度徽章由宿主画在卡片外。
    private var detailView: some View {
        SevenDayTokenUsageHoverView(
            days: dailyTokenUsage,
            scannedAt: scannedAt,
            isScanning: isScanning,
            isTruncated: isTruncated,
            costByDay: LocalUsagePriceByDay.estimates(
                dayStarts: dailyTokenUsage.map(\.dayStart),
                recentSamples: recentSamples,
                quotaProviderID: quotaProviderID,
                deepseekPeakWindow: deepseekPeakWindow
            ),
            speedStatisticsByDay: LocalUsageSpeedByDay.statistics(
                dayStarts: dailyTokenUsage.map(\.dayStart),
                recentSamples: recentSamples
            ),
            samplesTruncated: samplesTruncated
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

/// 7 天金额文案（`LocalUsageFooterView.priceByDay`）的 memo。
///
/// 与 `ProviderCardDerivedValues` 同一个理由：这个 footer 挂在 provider 卡片
/// 段3 里，而卡片 body 由 `DisplayClock` **每秒**重 eval；`estimateByDay` 要把
/// **全部** `recentSamples` 按自然日分组后逐条计价（DeepSeek 还要逐条按北京
/// 时间判峰谷 ×2），DSH 的样本上限 65536 ——「数据一秒没变」也是一次万级迭代。
/// （memo 命中后键比较同样走 COW identity 快路径、~0.16 µs/次；省下的是逐条计价本身。）
///
/// 键覆盖的输入：样本集合与内容、计价用的 quota provider、高峰窗口、节假日表
/// 版本（`HolidayCalendar.shared` 换表后峰谷判定会变）、以及**要显示哪几天**
/// （金额只由 samples + 计价参数决定，daily 各桶的数值不参与，所以键里只放
/// 日首）。daily 的桶值变化由上层卡片 memo 的 `status` 键一并覆盖。
enum LocalUsagePriceByDay {
    struct Key: Equatable {
        let dayStarts: [Date]
        let recentSamples: [LocalTokenUsageSample]
        let quotaProviderID: String
        let deepseekPeakWindow: DeepseekPeakWindow
        let holidayRevision: Int
        /// `Calendar.current` 不是编译期常量：系统时区变了，按日分组的边界就变。
        let timeZoneIdentifier: String
    }

    private static let memo = DerivedValueMemo<String, Key, [Date: String]>()
    private static let estimateMemo = DerivedValueMemo<String, Key, [Date: ModelCostEstimate]>()

    /// 真正算过几次（测试口径）。
    static var computeCount: Int { memo.computeCount }
    /// 清空（测试用）。
    static func reset() {
        memo.reset()
        estimateMemo.reset()
    }

    /// Raw numeric estimates for history charts. Keep `value` and `currency` intact;
    /// callers must never recover either field from `displayText`.
    static func estimates(
        dayStarts: [Date],
        recentSamples: [LocalTokenUsageSample],
        quotaProviderID: String,
        deepseekPeakWindow: DeepseekPeakWindow
    ) -> [Date: ModelCostEstimate] {
        let key = Key(
            dayStarts: dayStarts,
            recentSamples: recentSamples,
            quotaProviderID: quotaProviderID,
            deepseekPeakWindow: deepseekPeakWindow,
            holidayRevision: HolidayCalendar.sharedRevision,
            timeZoneIdentifier: Calendar.current.timeZone.identifier
        )
        return estimateMemo.value(for: quotaProviderID, key: key) {
            ModelPricingCatalog.estimateByDay(
                samples: recentSamples,
                quotaProviderID: quotaProviderID,
                deepseekPeakWindow: deepseekPeakWindow
            )
        }
    }

    /// 未走 memo 的直算路径（`values` 的 `compute`，测试的"逐字不变"对照也用它）。
    static func compute(
        dayStarts: [Date],
        recentSamples: [LocalTokenUsageSample],
        quotaProviderID: String,
        deepseekPeakWindow: DeepseekPeakWindow
    ) -> [Date: String] {
        let estimates = ModelPricingCatalog.estimateByDay(
            samples: recentSamples,
            quotaProviderID: quotaProviderID,
            deepseekPeakWindow: deepseekPeakWindow
        )
        return Dictionary(uniqueKeysWithValues: dayStarts.map { dayStart in
            let key = Calendar.current.startOfDay(for: dayStart)
            let text: String
            if let estimate = estimates[key] {
                text = estimate.displayText
            } else {
                text = "—"
            }
            return (dayStart, text)
        })
    }

    static func values(
        dayStarts: [Date],
        recentSamples: [LocalTokenUsageSample],
        quotaProviderID: String,
        deepseekPeakWindow: DeepseekPeakWindow
    ) -> [Date: String] {
        let key = Key(
            dayStarts: dayStarts,
            recentSamples: recentSamples,
            quotaProviderID: quotaProviderID,
            deepseekPeakWindow: deepseekPeakWindow,
            holidayRevision: HolidayCalendar.sharedRevision,
            timeZoneIdentifier: Calendar.current.timeZone.identifier
        )
        return memo.value(for: quotaProviderID, key: key) {
            compute(
                dayStarts: dayStarts,
                recentSamples: recentSamples,
                quotaProviderID: quotaProviderID,
                deepseekPeakWindow: deepseekPeakWindow
            )
        }
    }
}

/// 7 天用量的**当日速度文案**（`[dayStart: tok/s 文案]`）——「用量」segment 下
/// 7 天表末列（速度）的数据源，与 `LocalUsagePriceByDay`（价值列）同一分工：
/// 调用方在构造点以 autoclosure 携带，7 天卡的 body 真正展开时才算。
///
/// 分组口径与 `ModelPricingCatalog.estimateByDay` 一致（`Calendar.current` 的
/// `startOfDay(for: completedAt)`），产物 key 用 days 的 `dayStart`（构造链里
/// 已按同一 calendar 归一，见 `UnifiedDailyUsageNormalizer`），速率口径唯一
/// 实现在 `LocalUsageSummaryBuilder.windowTokenRate`（Σ(Output+Reason) ÷ Σ
/// 调用时长），文案统一走 `QuotaWindowUsageSection.speedText`（与「额度窗口」
/// 用量态的速度格同分档）。
///
/// 不像 priceByDay 那样上 memo：这里只有一次按日分组 + 逐日一次 `windowTokenRate`
/// 线性 pass，没有逐样本定价表查询与节假日/峰谷判定，单秒重算的成本比定价链路
/// 低一个量级；若 profile 显示有热，再按同一 Key 模式补 memo。
enum LocalUsageSpeedByDay {
    private struct StatisticsKey: Equatable {
        let dayStarts: [Date]
        let recentSamples: [LocalTokenUsageSample]
        let timeZoneIdentifier: String
    }

    private static let statisticsMemo = DerivedValueMemo<String, StatisticsKey, [Date: PromptSpeedStatistics]>()

    /// Daily Prompt-level speed distribution for the selectable history chart.
    /// No sample means unavailable (no key); a sampled day with no valid durations
    /// retains an empty statistic so it is distinguishable from known zero speed.
    static func statistics(
        dayStarts: [Date],
        recentSamples: [LocalTokenUsageSample]
    ) -> [Date: PromptSpeedStatistics] {
        guard !recentSamples.isEmpty else { return [:] }
        let key = StatisticsKey(
            dayStarts: dayStarts,
            recentSamples: recentSamples,
            timeZoneIdentifier: Calendar.current.timeZone.identifier
        )
        return statisticsMemo.value(for: "prompt-speed", key: key) {
            computeStatistics(dayStarts: dayStarts, recentSamples: recentSamples)
        }
    }

    private static func computeStatistics(
        dayStarts: [Date],
        recentSamples: [LocalTokenUsageSample]
    ) -> [Date: PromptSpeedStatistics] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: recentSamples) {
            calendar.startOfDay(for: $0.completedAt)
        }
        return Dictionary(uniqueKeysWithValues: dayStarts.compactMap { dayStart in
            let key = calendar.startOfDay(for: dayStart)
            guard let samples = grouped[key] else { return nil }
            return (key, LocalUsageSummaryBuilder.promptSpeedStatistics(samples: samples))
        })
    }

    /// `recentSamples` 为空 = 没有任何速度数据 → 空字典（usage 段不画末列）；
    /// 有样本但某天没有时长有效的样本（或那天根本没样本）→ 该天 `—`。
    static func texts(
        dayStarts: [Date],
        recentSamples: [LocalTokenUsageSample]
    ) -> [Date: String] {
        guard recentSamples.isEmpty == false else { return [:] }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: recentSamples) {
            calendar.startOfDay(for: $0.completedAt)
        }
        return Dictionary(uniqueKeysWithValues: dayStarts.map { dayStart in
            let rate: Double?
            if let samples = grouped[calendar.startOfDay(for: dayStart)] {
                rate = LocalUsageSummaryBuilder.windowTokenRate(samples: samples)
            } else {
                rate = nil
            }
            return (dayStart, QuotaWindowUsageSection.speedText(rate))
        })
    }
}
