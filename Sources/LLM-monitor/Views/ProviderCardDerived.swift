import Foundation

/// 卡片 body 一次要用的三个派生产物：provider-neutral 投影、额度窗口用量快照、
/// 「今」行。三者都只由 `status`（+ 两个"今天"）决定，所以一起算、一起缓存。
///
/// 为什么要打包成一个值：它们共享同一个失效条件集合（见
/// `ProviderCardDerivedValues.Key`），分成三个 memo 只会把同一份 O(samples)
/// 的键比较做三遍。
struct ProviderCardDerived: Equatable {
    let projection: ProviderUsageProjection
    let windowUsageSnapshot: QuotaWindowUsageSnapshot
    let todayUsageRow: QuotaWindowUsageSection.Row?
}

/// `ProviderCardView.body` 的唯一派生值入口（`ProviderCardView` 仍是 thin
/// coordinator：算值在这里，渲染仍在卡片各段）。
///
/// **为什么需要它**：`ProviderCardView` 挂在 `DisplayClockScope` 里，展示时钟
/// **每秒** tick 一次就重 eval 整个 body；而 `make` 里的三件事全是 O(samples)：
/// 投影要 per-model 归桶 + 逐条计价（DeepSeek 还要逐条按北京时间判峰谷 ×2），
/// 窗口快照要对全部样本按 model / 时间窗各筛一遍再逐条计价，「今」行要再筛一遍
/// 当天样本。DSH 账本的 `recentSamples` 上限 65536，于是「数据一秒没变」也要把
/// 这些万级迭代重跑一遍 —— 浮层可见期间就是主线程每秒一次的卡顿。
/// memo 之后：只有**输入真的变了**才重算，纯展示时钟 tick 直接复用上次的值。
/// （每 tick 的键比较本身便宜：`ProviderStatus ==` 在样本数组那层走 `Array ==` 的
/// COW buffer identity 快路径（生产路径两次状态共享同一 buffer），实测 ~0.16 µs/次。）
///
/// 缓存键（`Key`）的每个字段都对应一类会影响结果的输入：
///
/// | 字段 | 覆盖的输入 |
/// |---|---|
/// | `status`（**全值相等**） | status 的所有字段：`state`/`lastSuccess`（额度、model、codex 预聚合）、各本地账本快照（`dshUsage` / `glmLocalUsage` / `opencodeUsage` / `antigravityLocalUsage` / `agyUsage` / `minimaxLocalUsage` 的 daily 与 samples）、`clientBindings`、`deepseekPeakWindow` / `glmPeakWindow` / 闲时窗口、`kind`、`isScanningLocalUsage` / `localUsageFreshness`、`lastRefreshedAt` |
/// | `wallClockDay` | 投影里的"当日 max 修补"（`UnifiedDailyUsageNormalizer.includingCurrentDay`）只按**墙钟自然日**取整，跨自然日必须重算 |
/// | `displayDay` | 「今」行按展示时钟的当天取（`\.displayDate`），跨自然日必须重算 |
/// | `holidayRevision` | `HolidayCalendar.shared` 的版本号：节假日表在运行期会被解析链换掉，换表后 DeepSeek 峰谷判定结果变 |
/// | `timeZoneIdentifier` | `Calendar.current` 不是编译期常量：系统时区变了，自然日边界就变 |
///
/// 键里放的是**值**而不是"数据源有没有广播变化"：前者不可能漏（任何输入变化都
/// 让 `==` 为假），后者漏一次就是静默显示过期数字。
enum ProviderCardDerivedValues {
    /// memo 键。槽位按 `status.id` 分（见 `DerivedValueMemo`），条目数 = 卡片数。
    struct Key: Equatable {
        let status: ProviderStatus
        let wallClockDay: Date
        let displayDay: Date
        let holidayRevision: Int
        /// `Calendar.current` 不是编译期常量：系统时区变了，日界就变。键里钉住
        /// 时区标识，时区一切换即失效（正常情况下 `wallClockDay` 本身也会变，
        /// 这一栏是给"换到日界恰好相同的时区"兜底）。
        let timeZoneIdentifier: String
    }

    private static let memo = DerivedValueMemo<String, Key, ProviderCardDerived>()

    /// 真正算过几次（测试口径）。
    static var computeCount: Int { memo.computeCount }
    /// 当前占用的槽数（测试口径：缓存有界）。
    static var slotCount: Int { memo.slotCount }
    /// 清空（测试用；生产路径不手动失效）。
    static func reset() { memo.reset() }

    /// 卡片 body 的唯一读入口。命中即原样返回上次的值，未命中才真算。
    ///
    /// - Parameters:
    ///   - displayDate: 宿主注入的展示时钟（「今」行与倒计时同一个 now）。
    ///   - now: 墙钟（投影的当日修补用）。默认取渲染时刻。
    static func resolve(
        status: ProviderStatus,
        displayDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ProviderCardDerived {
        let key = Key(
            status: status,
            wallClockDay: calendar.startOfDay(for: now),
            displayDay: calendar.startOfDay(for: displayDate),
            holidayRevision: HolidayCalendar.sharedRevision,
            timeZoneIdentifier: calendar.timeZone.identifier
        )
        return memo.value(for: status.id, key: key) {
            make(status: status, displayDate: displayDate, now: now, calendar: calendar)
        }
    }

    /// 未走 memo 的直算路径。`resolve` 的 `compute` 与测试的"逐字不变"对照都走它，
    /// 因此 memo 命中时返回的值与现算值是同一个函数的产物（不是两份实现）。
    static func make(
        status: ProviderStatus,
        displayDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ProviderCardDerived {
        let projection = status.usageProjection(for: status.lastSuccess, now: now)
        return ProviderCardDerived(
            projection: projection,
            windowUsageSnapshot: windowUsageSnapshot(status: status, projection: projection),
            todayUsageRow: todayUsageRow(
                status: status,
                projection: projection,
                displayDate: displayDate,
                calendar: calendar
            )
        )
    }

    // MARK: - 「今」行

    /// 「今」行：当天本地用量聚合，与第一张卡底部曾经的「今日使用情况」汇总行
    /// （后被移除的旧汇总行）**同源同口径**：当天 token 四桶 + 当天样本计价。
    /// token 四桶取 `dailyTokenUsage` 的今天那一条（与"今天 X tokens / 命中率"
    /// 同一份数据，比率公式也同一个：出/入 = (reasoning+output)/(input+cached)、
    /// 思考 = reasoning/(reasoning+output)、命中为缓存占比）；
    /// 价值取当天样本逐条计价。
    ///
    /// 当天无本地数据 → 返回 `nil`，今行整个不画。它不是额度窗口，只是
    /// `QuotaWindowUsageSection` 的同一份 `Row` 格式（行首标签「今」，第五轮
    /// 改版从「今日」缩成「今」，与「5h」「周」同一长度档）；合并改版后重置
    /// 日期格 `—`、并参与所在态的全零列判定。当天四桶合计为 0 时照常返回
    /// `Row`，由 `QuotaWindowUsageSection.visibleRows` 统一跳过。
    ///
    /// 取值只依赖 `displayDate` 所在的自然日（`Key.displayDay`），因此同一自然日
    /// 内展示时钟每 tick 一次都命中 memo。
    static func todayUsageRow(
        status: ProviderStatus,
        projection: ProviderUsageProjection,
        displayDate: Date,
        calendar: Calendar = .current
    ) -> QuotaWindowUsageSection.Row? {
        // 「今天」以展示时钟为准（与下面的 startOfDay 同一个 now，别用两个来源）。
        guard let today = projection.dailyTokenUsage.last(where: {
            calendar.isDate($0.dayStart, inSameDayAs: displayDate)
        }) else {
            return nil
        }
        let metrics = QuotaWindowUsageMetrics(
            input: today.input,
            cachedInput: today.cacheRead,
            output: today.output,
            reasoning: today.reasoning
        )
        let todayStart = calendar.startOfDay(for: displayDate)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            return nil
        }
        let todaySamples = projection.recentSamples.filter {
            $0.completedAt >= todayStart && $0.completedAt < tomorrow
        }
        let cost: ModelCostEstimate? = todaySamples.isEmpty
            ? nil
            : ModelPricingCatalog.estimate(
                samples: todaySamples,
                quotaProviderID: status.kind.quotaProviderID,
                deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
            )
        return QuotaWindowUsageSection.Row(
            label: ProviderCardView.todayRowLabel,
            metrics: metrics,
            cost: cost
        )
    }

    // MARK: - 额度窗口用量快照

    /// 区块数据：各 active model 的窗口用量按 provider 合计。
    ///
    /// 口径**完全**取自额度行——窗口边界走 `LocalUsageSummaryBuilder.windowBounds`
    /// （同 `CombinedQuotaWindowRow.primaryUsage` / `weeklyUsage`），GLM 闲时排除
    /// 走同一个 `excludeWindows` + `excludeGlmOffPeak`，ChatGPT 走
    /// `ChatGPTPlanModelRow` 的预聚合口径。多 model 求和的理由见
    /// `LocalUsageSummaryBuilder.combineWindowUsage`。
    /// 额度 model 取 `status.lastSuccess`：`.ok` / `.loading` / `.failed` 三条路径
    /// 画这一块时手里那份 `QuotaInfo` 都**就是** `status.lastSuccess`（状态机把
    /// "上次成功数据"挂在 case 上，见 `ProviderStatus.State`），所以一个 memo 值
    /// 三条路径通用。
    static func windowUsageSnapshot(
        status: ProviderStatus,
        projection: ProviderUsageProjection
    ) -> QuotaWindowUsageSnapshot {
        let quotaInfo = status.lastSuccess
        let models = quotaInfo?.activeModels ?? []
        let snapshots = models.map { model -> QuotaWindowUsageSnapshot in
            // ChatGPT 的窗口用量由 codexUsageDetails 预聚合（再补 OpenCode 来源），
            // 那些样本已被统计过一次，不能再从 samples 重算一遍。
            let overrides = status.kind == .codexChatGpt
                ? ChatGPTPlanModelRow.windowUsages(
                    model: model,
                    usageDetails: quotaInfo?.codexUsageDetails,
                    samples: projection.recentSamples
                )
                : (interval: nil, weekly: nil)
            return LocalUsageSummaryBuilder.windowUsage(
                model: model,
                providerKind: status.kind,
                samples: projection.recentSamples,
                intervalLabel: QuotaSummary.primaryWindowLabel(providerKind: status.kind, model: model),
                weeklyLabel: QuotaSummary.weeklyWindowLabel(),
                intervalFallbackSeconds: CombinedQuotaWindowRow.primaryFallbackSeconds(
                    providerKind: status.kind, model: model
                ),
                excludeWindows: offPeakWindows(status: status),
                excludeGlmOffPeak: status.kind == .glmCodingPlan,
                intervalUsageOverride: overrides.interval,
                weeklyUsageOverride: overrides.weekly,
                quotaProviderID: status.kind.quotaProviderID,
                deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
            )
        }
        return LocalUsageSummaryBuilder.combineWindowUsage(snapshots)
    }

    /// GLM 闲时任务窗口（仅 `.glmCodingPlan`）。额度窗口 hover 统计排除这些窗口内的
    /// sample，本地 token 柱图仍保留。其他 provider 恒为空。
    ///
    /// 必须按 kind 取：ZCode 是一份多 provider 账本，同一份 `glmLocalUsage` 现在也挂在
    /// MiniMax / DeepSeek 卡上（只为了读 `providerSlices`）。闲时窗口只属于智谱任务，
    /// 泄漏到其它卡会让落在窗口内的 MiniMax / DSH 样本被误判成闲时任务而排除。
    static func offPeakWindows(status: ProviderStatus) -> [GlmOffPeakWindow] {
        guard status.kind == .glmCodingPlan else { return [] }
        return status.glmOffPeakWindows
    }
}
