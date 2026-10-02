import Foundation
import CoreGraphics

/// 边缘状态窗里的单个圆。粒度 = **provider**，与菜单卡片 1:1。
///
/// 双环结构（与 iconDuo 的左右弧同源，但按 provider 分开展示）：
/// - **外环** = 5 小时（interval）窗口剩余比例
/// - **内环** = 周（weekly）窗口剩余比例
/// - **中心** = Provider 品牌图标（`BrandLogoView`）
struct EdgeDockEntry: Identifiable, Equatable, Sendable {
    /// `ProviderStatus.id`（providerID），跨刷新稳定。
    let id: String
    let displayName: String
    /// 用于取品牌图标。`ProviderStatus.kind`。
    let kind: ProviderKind

    /// 外环填充比例 `0...1`，5 小时窗口。
    /// nil = 该 provider 没有 5 小时窗口（周窗口型 / 余额型）→ 该环不画弧。
    let intervalFraction: Double?

    /// 内环填充比例 `0...1`，周窗口。
    /// nil = 该 provider 没有周窗口（纯 5 小时型）→ 该环不画弧。
    let weeklyFraction: Double?

    /// 综合健康档位。用于「两个环都没有」的兜底渲染与辅助功能朗读。
    /// nil = 无数据，沿用菜单栏状态点语义（灰 ≠ 绿）。
    let health: HealthLevel?

    /// **仅 5 小时窗口**的健康档位（该 provider 下所有含 5h 窗口的 model 里最差的一档）。
    /// nil = 没有 5h 窗口。
    ///
    /// 与 `intervalFraction` 同口径、同过滤条件——两者都只看
    /// `activeModels.filter(\.hasIntervalWindow)`，所以"有弧"与"有色"永远同步，
    /// 不会出现外环画了弧却是中性灰。
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
                weeklyFraction: weeklyFraction(status, at: now),
                health: status.aggregateHealthLevel(at: now),
                intervalHealth: intervalHealth(status, at: now),
                weeklyHealth: weeklyHealth(status, at: now)
            )
        }
    }

    /// 5 小时窗口剩余比例：取该 provider 所有含 5h 窗口 model 的**最低**值。
    ///
    /// 与 iconDuo 弧线的"平均"口径有意不同：iconDuo 是**所有 provider 挤在一个图标里**，
    /// 只能取聚合值；而边缘窗一个圆就是一个 provider，取最低值才回答得了
    /// "这家是不是快用完了"。颜色也走同一条 `aggregateHealthLevel`，长度和颜色不打架。
    static func intervalFraction(_ status: ProviderStatus, at now: Date) -> Double? {
        worstFraction(status.lastSuccess?.activeModels.filter(\.hasIntervalWindow)) {
            $0.intervalRemainingPercent
        }
    }

    /// 周窗口剩余比例：取该 provider 所有含周窗口 model 的**最低**值。
    ///
    /// 用**原始**剩余百分比，不乘 `weeklyEquivalentMultiplier` —— 内环表达的是
    /// "周额度本身还剩多少"，乘等效倍率会把它变成与 5h 同量纲的换算值，
    /// 读出来就不再是周额度了（等效倍率只用于跨窗口的「实际可用」合成）。
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

    // MARK: - 逐窗口色档

    /// 5 小时窗口的健康档位：取该 provider 所有含 5h 窗口 model 里**最差**的一档。
    ///
    /// 与 `intervalFraction` 的"最低值"是同一个聚合口径：颜色必须和弧长指向同一个
    /// 瓶颈，否则会出现"最紧的那个 model 决定了弧长、另一个更闲的 model 决定了颜色"。
    ///
    /// 阈值走 `ModelQuota.colorLevel`（与卡片分段条同一份），时间比例传 `nil`——
    /// 即固定 30% 黄线。动态黄线（`min(time%, 50)`）是**长窗口**规则：5h 窗口
    /// 本来就每 5 小时重置一次，"周还剩多少"对它没有意义。
    static func intervalHealth(_ status: ProviderStatus, at now: Date) -> HealthLevel? {
        worstHealth(
            status.lastSuccess?.activeModels.filter(\.hasIntervalWindow),
            percent: { $0.intervalRemainingPercent },
            timeFraction: { _ in nil }
        )
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
