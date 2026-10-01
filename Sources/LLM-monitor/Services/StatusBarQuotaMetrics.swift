import Foundation

/// 描述单侧额度弧（周额度 / 5h 额度）的聚合数据。
struct QuotaRingMetrics: Equatable, Sendable {
    /// 是否存在这类额度窗口。缺失窗口只显示底轨，不显示可用额度段。
    var isAvailable: Bool
    /// 所有套餐中的最低可用量（0.0 ... 1.0）。
    var minAvailable: Double
    /// 所有套餐的平均可用量（0.0 ... 1.0），决定连续实线的总长度。
    var avgAvailable: Double

    init(minAvailable: Double, avgAvailable: Double, isAvailable: Bool = true) {
        self.isAvailable = isAvailable
        let clampedMin = min(max(minAvailable, 0.0), 1.0)
        let clampedAvg = min(max(avgAvailable, 0.0), 1.0)
        self.minAvailable = clampedMin
        self.avgAvailable = max(clampedMin, clampedAvg)
    }
}

/// 状态栏动态额度指标快照。
struct StatusBarQuotaMetrics: Equatable, Sendable {
    /// 右弧：周额度（原始物理剩余比例，无时间系数）。
    var weekly: QuotaRingMetrics
    /// 左弧：5 小时额度（原始物理剩余比例，无时间系数）。
    var interval: QuotaRingMetrics
    /// Icon Duo 中心扇形显示的剩余比例：仍有剩余的套餐中「实际可用」的最低值——
    /// 每个套餐按自身存在的窗口取 min(5h 剩余, 周剩余 × 周等效倍率 N)（与卡片
    /// 分段条同口径；仅 5h 按 5h、仅周按 周 × N，均 clamp 到 1.0），已耗尽
    /// （实际可用为 0）的套餐不参与（多套餐接力时中心不被拖到 0），全部套餐
    /// 耗尽时为 0，任何套餐都没有窗口时为 nil。nil 表示暂无额度数据。
    var centerAvailable: Double?
    /// 套餐健康点，已按红 > 黄 > 绿排序并补齐到三个。判定输入来自
    /// `ModelQuota.aggregateHealthLevel`（统一 colorLevel + 高峰 floor）。
    var quotaHealthLevels: [HealthLevel]
    /// 右弧（聚合周弧）颜色的动态黄线输入：所有周窗口套餐
    /// `weeklyTimeRemainingFraction` 的最大值。聚合弧画的是多套餐平均，取最宽的
    /// 剩余时间比例可避免任一临近重置的套餐把整条弧压成黄色；没有任何周窗口
    /// （或全部缺 reset 时间）时为 nil，弧线退回固定 30% 黄线。
    var weeklyTimeFraction: Double?
    /// 左弧（聚合 interval 弧）颜色的动态黄线输入：所有长 interval 窗口（≥24h，
    /// 如 ChatGPT Plan 单主窗口）`intervalTimeRemainingFraction` 的最大值。与右弧
    /// 同理——聚合弧画的是多套餐平均，取最宽的剩余时间比例可避免任一临近重置
    /// 的套餐把整条弧压成黄色，并与中心扇形的动态黄线同向。只有 5h 短窗口
    /// （或全部缺 reset 时间）时为 nil，左弧退回固定 30% 黄线。
    var intervalTimeFraction: Double?
    /// 中心扇形颜色的动态黄线输入：产生中心最小值的套餐在其瓶颈（binding）
    /// 窗口上的剩余时间比例；瓶颈是 5h 短窗口（或缺 reset 时间）时为 nil，
    /// 中心退回固定 30% 黄线。
    var centerTimeFraction: Double?

    init(
        weekly: QuotaRingMetrics,
        interval: QuotaRingMetrics,
        centerAvailable: Double? = nil,
        quotaHealthLevels: [HealthLevel] = Array(repeating: .healthy, count: 3),
        weeklyTimeFraction: Double? = nil,
        centerTimeFraction: Double? = nil,
        intervalTimeFraction: Double? = nil
    ) {
        self.weekly = weekly
        self.interval = interval
        self.centerAvailable = centerAvailable.map { min(max($0, 0.0), 1.0) }
        self.quotaHealthLevels = Self.resolveTopThreeHealthLevels(quotaHealthLevels)
        self.weeklyTimeFraction = weeklyTimeFraction
        self.centerTimeFraction = centerTimeFraction
        self.intervalTimeFraction = intervalTimeFraction
    }

    /// 优先显示红色（.critical），其次黄色（.warning），最后绿色（.healthy）；
    /// 若有 3 个红色，则直接占满 3 个位置，无需显示黄色和绿色。
    static func resolveTopThreeHealthLevels(_ levels: [HealthLevel]) -> [HealthLevel] {
        let sorted = levels.sorted()
        return Array((sorted + Array(repeating: .healthy, count: 3)).prefix(3))
    }

    static let full = StatusBarQuotaMetrics(
        weekly: QuotaRingMetrics(minAvailable: 1.0, avgAvailable: 1.0),
        interval: QuotaRingMetrics(minAvailable: 1.0, avgAvailable: 1.0),
        centerAvailable: 1.0,
        quotaHealthLevels: Array(repeating: .healthy, count: 3)
    )
}
