import Foundation
import CoreGraphics

/// 边缘状态窗里的单个圆。粒度 = **provider**，与菜单卡片 1:1。
///
/// 双环结构（与 iconDuo 的左右弧同源，但按 provider 分开展示）：
/// - **外环** = 5 小时（interval）**有效额度** = min(5h 剩余, 周剩余 × 周等效倍率 N)，
///   与状态栏中心扇形同口径（见 `intervalFraction`）
/// - **内环** = 周（weekly）窗口剩余比例（原始百分比，不乘倍率）
/// - **中心** = Provider 品牌图标（`BrandLogoView`）
struct EdgeDockEntry: Identifiable, Equatable, Sendable {
    /// `ProviderStatus.id`（providerID），跨刷新稳定。
    let id: String
    let displayName: String
    /// 用于取品牌图标。`ProviderStatus.kind`。
    let kind: ProviderKind

    /// 外环填充比例 `0...1`，5 小时**有效额度**（min(5h 剩余, 周剩余 × 周等效倍率 N)，
    /// 口径见 `EdgeDockProjection.intervalFraction`）。
    /// nil = 该 provider 没有 5 小时窗口（周窗口型 / 余额型）→ 该环不画弧。
    let intervalFraction: Double?

    /// 原始 5h 窗口剩余比例（未与周折算取 min）。只喂 hover 文案：有效额度低于
    /// 原始 5h 时，caption 把两个数并排亮出来（`5h 90%(30%有效)`），说明环为什么
    /// 比 5h 剩余少——差额来自周瓶颈，不是 5h 本身见底。
    let rawIntervalFraction: Double?

    /// 内环填充比例 `0...1`，周窗口。
    /// nil = 该 provider 没有周窗口（纯 5 小时型）→ 该环不画弧。
    let weeklyFraction: Double?

    /// 综合健康档位。用于「两个环都没有」的兜底渲染与辅助功能朗读。
    /// nil = 无数据，沿用菜单栏状态点语义（灰 ≠ 绿）。
    let health: HealthLevel?

    /// **仅 5 小时窗口**的健康档位，按 5h **有效额度**判定（瓶颈 model 的
    /// `colorLevel(percent:bindingTimeFraction:)`，口径见 `intervalFraction`）。
    /// nil = 没有 5h 窗口。
    ///
    /// 与 `intervalFraction` 同口径、同过滤条件——两者都只看
    /// `activeModels.filter(\.hasIntervalWindow)` 并取同一个有效额度最低的瓶颈，
    /// 所以"有弧"与"有色"永远同步，不会出现外环画了弧却是中性灰。
    let intervalHealth: HealthLevel?

    /// **仅周窗口**的健康档位（同上，取最差档）。nil = 没有周窗口。
    let weeklyHealth: HealthLevel?

    /// 该 provider 是否存在任何可读额度窗口。false 时两个环都不画弧，
    /// 改为压暗满环表示"读得到健康、读不到余量"（余额型 DeepSeek）。
    var hasAnyQuotaWindow: Bool {
        intervalFraction != nil || weeklyFraction != nil
    }
}

/// `[ProviderStatus]` → 边缘窗圆环条目。纯函数，无 AppKit 依赖，可注入固定 `now` 测试。
///
/// 只包含**已启用**监控的 provider —— 这就是「开启监控的」的口径。
///
/// 条目顺序 = **配置文件里 `providerCardOrder` 的顺序**，与菜单卡片逐项一致；
/// 没配过（nil）时退回显示名升序。两处共用 `DisplayOrder` + `ProviderStatus.displayNameAscending`，
/// 所以「设置页里排的顺序」在菜单和 dock 里是同一个顺序，不会各排各的。
///
/// 顺序必须**处处同源**：视图按序渲染圆环，命中判定再拿同一个 `entries[index].id`
/// 去反查 provider（见 `orderRowRects`），两边顺序一旦不同步就是"hover 上面那个圆、
/// 弹出下面那个 provider"。
enum EdgeDockProjection {
    /// - Parameter preferredIDs: 配置里的 provider 顺序（`config.providerCardOrder`），
    ///   元素是 `ProviderKind.quotaProviderID`。缺失 / 重复 / 已不存在的 id 会被忽略，
    ///   新增的 provider 按默认序补在后面——与菜单卡片同一套容错。
    static func entries(
        from statuses: [ProviderStatus],
        preferredIDs: [String]? = nil,
        at now: Date = Date()
    ) -> [EdgeDockEntry] {
        DisplayOrder.ordered(
            statuses.filter(\.isEnabled),
            preferredIDs: preferredIDs,
            id: { $0.kind.quotaProviderID },
            by: ProviderStatus.displayNameAscending
        )
        .map { status in
            EdgeDockEntry(
                id: status.id,
                displayName: status.displayName,
                kind: status.kind,
                intervalFraction: intervalFraction(status, at: now),
                rawIntervalFraction: rawIntervalFraction(status),
                weeklyFraction: weeklyFraction(status, at: now),
                health: status.aggregateHealthLevel(at: now),
                intervalHealth: intervalHealth(status, at: now),
                weeklyHealth: weeklyHealth(status, at: now)
            )
        }
    }

    /// 5 小时**有效额度**：逐 model 取 min(5h 剩余, 周剩余 × 周等效倍率 N)
    /// （`ModelQuota.aggregateActualAvailable`），再取所有含 5h 窗口 model 里的最低值。
    ///
    /// 与状态栏中心扇形（`AppState.statusBarQuotaMetrics`）同一真源：周额度折算后
    /// 可能比 5h 剩余更紧（典型：antigravity Claude/GPT 组 N=1，2026-10 从 3 下调），
    /// 外环若直接读原始 5h 百分比就会高估可用额度——周更紧时外环随之收缩。
    ///
    /// 与 iconDuo 弧线的"平均"聚合口径有意不同：iconDuo 是**所有 provider 挤在一个
    /// 图标里**，只能取聚合值；而边缘窗一个圆就是一个 provider，取最低值才回答得了
    /// "这家是不是快用完了"。颜色与弧长共用同一个瓶颈（见 `intervalHealth`），
    /// 长度和颜色不打架。nil 条件不变：没有任何含 5h 窗口的 model（周窗口型 / 余额型）。
    static func intervalFraction(_ status: ProviderStatus, at now: Date) -> Double? {
        worstEffectiveReading(status, at: now).map { $0.percent / 100 }
    }

    /// 原始 5h 剩余比例（取所有含 5h 窗口 model 的最低值，不与周折算取 min）。
    ///
    /// 保留切换前的旧口径，**只喂 hover 文案**做对照（`intervalCaption`）：外环读
    /// 有效额度之后，只亮有效值会让人误以为 5h 真的只剩这么多，把原始值并排给出
    /// 才能看出差额来自周瓶颈。画环 / 取色 / 常驻数值一律不读它。
    static func rawIntervalFraction(_ status: ProviderStatus) -> Double? {
        worstFraction(status.lastSuccess?.activeModels.filter(\.hasIntervalWindow)) {
            $0.intervalRemainingPercent
        }
    }

    /// 周窗口剩余比例：取该 provider 所有含周窗口 model 的**最低**值。
    ///
    /// 用**原始**剩余百分比，不乘 `weeklyEquivalentMultiplier` —— 内环表达的是
    /// "周额度本身还剩多少"，乘等效倍率会把它变成与 5h 同量纲的换算值，
    /// 读出来就不再是周额度了（倍率只参与外环的 5h 有效额度合成，内环保持原始）。
    static func weeklyFraction(_ status: ProviderStatus, at now: Date) -> Double? {
        worstFraction(status.lastSuccess?.activeModels.filter(\.hasWeeklyWindow)) {
            $0.weeklyRemainingPercent
        }
    }

    private static func worstFraction(
        _ models: [ModelQuota]?,
        _ percent: (ModelQuota) -> Double
    ) -> Double? {
        guard let models, !models.isEmpty else { return nil }
        let values = models.map { min(max(percent($0), 0), 100) }
        guard let worst = values.min() else { return nil }
        return worst / 100
    }

    /// 「5h 有效额度」读数：逐 model 取 min(5h 剩余, 周剩余 × 周等效倍率 N)
    /// （`aggregateActualAvailable`，与状态栏中心扇形 / `aggregateHealthLevel` 同一真源），
    /// 再取该 provider 所有含 5h 窗口 model 里 percent 最低的一个。
    /// 返回瓶颈 model 的 (percent, bindingTimeFraction)，弧长与颜色共用同一瓶颈。
    private static func worstEffectiveReading(
        _ status: ProviderStatus,
        at now: Date
    ) -> (percent: Double, bindingTimeFraction: Double?)? {
        let models = status.lastSuccess?.activeModels.filter(\.hasIntervalWindow)
        guard let models, !models.isEmpty else { return nil }
        return models
            .compactMap { $0.aggregateActualAvailable(providerKind: status.kind, at: now) }
            .min(by: { $0.percent < $1.percent })
    }

    // MARK: - 逐窗口色档

    /// 5 小时窗口的健康档位：与 `intervalFraction` 共用同一个瓶颈（5h **有效额度**
    /// 最低的那个 model），颜色必须和弧长指向同一个瓶颈，否则会出现"最紧的那个
    /// model 决定了弧长、另一个更闲的 model 决定了颜色"。
    ///
    /// 时间比例**随瓶颈窗口走**（`aggregateActualAvailable` 的 `bindingTimeFraction`）：
    /// 瓶颈是 5h 短窗口时为 nil → 固定 30% 黄线（动态黄线 `min(time%, 50)` 是
    /// **长窗口**规则：5h 窗口本来就每 5 小时重置一次，"周还剩多少"对它没有意义）；
    /// 瓶颈是周窗口（周 × N 比 5h 更紧）时为周剩余时间比例 → 长窗口动态黄线，
    /// 与 `aggregateHealthLevel` 同口径。
    static func intervalHealth(_ status: ProviderStatus, at now: Date) -> HealthLevel? {
        worstEffectiveReading(status, at: now).map {
            ModelQuota.colorLevel(percent: $0.percent, timeFraction: $0.bindingTimeFraction)
        }
    }

    /// 周窗口的健康档位：同样取最差档，阈值按**剩余时间**收紧
    /// （`weeklyTimeRemainingFraction(at: now)`）。
    ///
    /// 用**原始**周剩余百分比，不乘 `weeklyEquivalentMultiplier` —— 与
    /// `weeklyFraction` 同一个理由：内环表达的是"周额度本身还剩多少"。
    static func weeklyHealth(_ status: ProviderStatus, at now: Date) -> HealthLevel? {
        worstHealth(
            status.lastSuccess?.activeModels.filter(\.hasWeeklyWindow),
            percent: { $0.weeklyRemainingPercent },
            timeFraction: { $0.weeklyTimeRemainingFraction(at: now) }
        )
    }

    /// 逐窗口最差色档。`HealthLevel` 的 `Comparable` 方向是"rank 越小越差"，
    /// 所以 `min` 正好是最差档；空集合返回 nil（该窗口不存在，而不是"很健康"）。
    private static func worstHealth(
        _ models: [ModelQuota]?,
        percent: (ModelQuota) -> Double,
        timeFraction: (ModelQuota) -> Double?
    ) -> HealthLevel? {
        guard let models, !models.isEmpty else { return nil }
        return models
            .map { ModelQuota.colorLevel(percent: percent($0), timeFraction: timeFraction($0)) }
            .min()
    }

    // MARK: - hover 文案

    /// hover 文案的 5h 段：周折算不构成瓶颈（有效 == 原始）时维持单数值；
    /// 有效 < 原始时并排显示两个数，先原始后有效（`5h 90%(30%有效)`）。
    /// 逐 model 有效 ≤ 原始，各取 min 后仍 ≤，不会出现「括号里更大」的展示。
    static func intervalCaption(effective: Double, raw: Double?) -> String {
        let percent = { (fraction: Double) in "\(Int((fraction * 100).rounded()))%" }
        guard let raw, raw > effective else { return "5h \(percent(effective))" }
        return "5h \(percent(raw))(\(percent(effective))有效)"
    }

    // MARK: - 行矩形排序

    /// 还没量到 / 量丢了的行用的占位矩形：放到屏幕坐标系够不着的地方。
    ///
    /// 不能用 `.zero`——那是真实屏幕坐标里的一个点，鼠标恰好经过时会被当成命中。
    static let unmeasuredRow = CGRect(x: -10_000, y: -10_000, width: 0, height: 0)

    /// 把视图上报的「id → 行矩形」重排成**与 `entries` 严格同序**的下标数组。
    ///
    /// 这一步是 hover 正确性的关键，不是洁癖：命中下标会被拿去反查
    /// `entries[index].id` 决定 popover 显示谁，所以「第 i 个矩形」必须就是
    /// 「第 i 个条目」。而 SwiftUI 的 `PreferenceKey.reduce` **不保证**兄弟视图的
    /// 上报顺序等于 `ForEach` 源顺序，直接拿上报顺序当下标，就会稳定复现
    /// "hover 上面那个圆、弹出下面那个 provider"。
    ///
    /// 缺 id 时填 `unmeasuredRow` 而不是跳过：跳过一格会让后面所有行整体前移一位，
    /// 又变成一种更隐蔽的下标错位。保持长度不变、该行不可命中，才是对齐。
    static func orderRowRects(entries: [EdgeDockEntry], reported: [String: CGRect]) -> [CGRect] {
        entries.map { reported[$0.id] ?? unmeasuredRow }
    }
}
