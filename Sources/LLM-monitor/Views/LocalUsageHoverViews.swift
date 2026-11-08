import SwiftUI

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

    private static let estimateMemo = DerivedValueMemo<String, Key, [Date: ModelCostEstimate]>()

    /// 真正算过几次（测试口径）。
    static var computeCount: Int { estimateMemo.computeCount }
    /// 清空（测试用）。
    static func reset() {
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
}

/// 7 天用量的**每日调用级 TTFT 分布**（`[dayStart: CallTTFTStatistics]`）——7 天
/// 表动态列 TTFT（每日 P50）的数据源，与 `LocalUsageSpeedByDay`（速度列）同一
/// 分工：按日分组后逐日调 `LocalUsageSummaryBuilder.callTTFTStatistics`（统计
/// 单位是单次调用，与 prompt 级速度不同），memo key 用 `"call-ttft"` 与速度的
/// `"prompt-speed"` 分开。
///
/// 分组口径与 `LocalUsageSpeedByDay` 一致（`Calendar.current` 的
/// `startOfDay(for: completedAt)`）；有样本但全部 TTFT 无效的日保留空统计
/// （p50 = nil → 图表断线），与「无样本日」同为缺口。空样本集合直接返回空表。
enum LocalUsageTTFTByDay {
    private struct StatisticsKey: Equatable {
        let dayStarts: [Date]
        let recentSamples: [LocalTokenUsageSample]
        let timeZoneIdentifier: String
    }

    private static let statisticsMemo = DerivedValueMemo<String, StatisticsKey, [Date: CallTTFTStatistics]>()

    /// Daily call-level TTFT distribution for the selectable history chart.
    /// No sample means no key; a sampled day with no valid TTFT retains an empty
    /// statistic so the chart can tell "no data" from a plotted zero.
    static func ttftStatistics(
        dayStarts: [Date],
        recentSamples: [LocalTokenUsageSample]
    ) -> [Date: CallTTFTStatistics] {
        guard !recentSamples.isEmpty else { return [:] }
        let key = StatisticsKey(
            dayStarts: dayStarts,
            recentSamples: recentSamples,
            timeZoneIdentifier: Calendar.current.timeZone.identifier
        )
        return statisticsMemo.value(for: "call-ttft", key: key) {
            computeTTFTStatistics(dayStarts: dayStarts, recentSamples: recentSamples)
        }
    }

    private static func computeTTFTStatistics(
        dayStarts: [Date],
        recentSamples: [LocalTokenUsageSample]
    ) -> [Date: CallTTFTStatistics] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: recentSamples) {
            calendar.startOfDay(for: $0.completedAt)
        }
        return Dictionary(uniqueKeysWithValues: dayStarts.compactMap { dayStart in
            let key = calendar.startOfDay(for: dayStart)
            guard let samples = grouped[key] else { return nil }
            return (key, LocalUsageSummaryBuilder.callTTFTStatistics(samples: samples))
        })
    }
}
