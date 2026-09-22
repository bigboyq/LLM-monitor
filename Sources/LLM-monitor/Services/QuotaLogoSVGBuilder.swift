import Foundation
import AppKit

/// 描述单侧额度弧（周额度 / 5h 额度）的聚合数据。
struct QuotaRingMetrics: Equatable, Sendable {
    /// 是否存在这类额度窗口。缺失窗口只显示底轨，不显示可用额度段。
    var isAvailable: Bool
    /// 所有套餐中的最低可用量（0.0 ... 1.0）。
    var minAvailable: Double
    /// 所有套餐的平均可用量（0.0 ... 1.0），决定连续实线的总长度。
    var avgAvailable: Double
    /// 兼容旧配置与调用方保留的强调色；新版仪表统一使用健康色绘制额度弧。
    var colorHex: String

    init(minAvailable: Double, avgAvailable: Double, colorHex: String, isAvailable: Bool = true) {
        self.isAvailable = isAvailable
        let clampedMin = min(max(minAvailable, 0.0), 1.0)
        let clampedAvg = min(max(avgAvailable, 0.0), 1.0)
        self.minAvailable = clampedMin
        self.avgAvailable = max(clampedMin, clampedAvg)
        self.colorHex = colorHex
    }

    static func `default`(minAvailable: Double, avgAvailable: Double, defaultColor: String) -> Self {
        Self(minAvailable: minAvailable, avgAvailable: avgAvailable, colorHex: defaultColor)
    }
}

/// 状态栏动态额度指标快照。
struct StatusBarQuotaMetrics: Equatable, Sendable {
    /// 右弧：周额度（原始物理剩余比例，无时间系数）。
    var weekly: QuotaRingMetrics
    /// 左弧：5 小时额度（原始物理剩余比例，无时间系数）。
    var interval: QuotaRingMetrics
    /// Icon Duo 中心扇形显示的剩余比例：所有有效套餐「实际可用」的最低值——
    /// 每个套餐按自身存在的窗口取 min(5h 剩余, 周剩余 × 周等效倍率 N)（与卡片
    /// 分段条同口径；仅 5h 按 5h、仅周按 周 × N，均 clamp 到 1.0），任何套餐
    /// 都没有窗口时为 nil。nil 表示暂无额度数据。
    var centerAvailable: Double?
    /// 套餐健康点，已按红 > 黄 > 绿排序并补齐到三个。判定输入来自
    /// `ModelQuota.aggregateHealthLevel`（统一 colorLevel + 高峰 floor）。
    var quotaHealthLevels: [HealthLevel]
    /// 右弧（聚合周弧）颜色的动态黄线输入：所有周窗口套餐
    /// `weeklyTimeRemainingFraction` 的最大值。聚合弧画的是多套餐平均，取最宽的
    /// 剩余时间比例可避免任一临近重置的套餐把整条弧压成黄色；没有任何周窗口
    /// （或全部缺 reset 时间）时为 nil，弧线退回固定 30% 黄线。
    var weeklyTimeFraction: Double?
    /// 中心扇形颜色的动态黄线输入：产生中心最小值的套餐在其瓶颈（binding）
    /// 窗口上的剩余时间比例；瓶颈是 5h 短窗口（或缺 reset 时间）时为 nil，
    /// 中心退回固定 30% 黄线。
    var centerTimeFraction: Double?
    /// 经典 App 图标中心水位的综合健康状态；Icon Duo 的各部件按统一 colorLevel
    /// 规则自行取色，不消费该值。
    var waterHealth: HealthLevel?

    init(
        weekly: QuotaRingMetrics,
        interval: QuotaRingMetrics,
        centerAvailable: Double? = nil,
        quotaHealthLevels: [HealthLevel] = Array(repeating: .healthy, count: 3),
        waterHealth: HealthLevel? = nil,
        weeklyTimeFraction: Double? = nil,
        centerTimeFraction: Double? = nil
    ) {
        self.weekly = weekly
        self.interval = interval
        self.centerAvailable = centerAvailable.map { min(max($0, 0.0), 1.0) }
        self.quotaHealthLevels = Self.resolveTopThreeHealthLevels(quotaHealthLevels)
        self.waterHealth = waterHealth
        self.weeklyTimeFraction = weeklyTimeFraction
        self.centerTimeFraction = centerTimeFraction
    }

    /// 优先显示红色（.critical），其次黄色（.warning），最后绿色（.healthy）；
    /// 若有 3 个红色，则直接占满 3 个位置，无需显示黄色和绿色。
    static func resolveTopThreeHealthLevels(_ levels: [HealthLevel]) -> [HealthLevel] {
        let sorted = levels.sorted()
        return Array((sorted + Array(repeating: .healthy, count: 3)).prefix(3))
    }

    static let full = StatusBarQuotaMetrics(
        weekly: QuotaRingMetrics(minAvailable: 1.0, avgAvailable: 1.0, colorHex: QuotaLogoSVGBuilder.defaultOuterColor),
        interval: QuotaRingMetrics(minAvailable: 1.0, avgAvailable: 1.0, colorHex: QuotaLogoSVGBuilder.defaultMiddleColor),
        centerAvailable: 1.0,
        quotaHealthLevels: Array(repeating: .healthy, count: 3),
        waterHealth: .healthy
    )
}

/// 经典「App 图标」SVG 构建器（1.6.0–1.8.x 样式）：
///
/// - 外环显示周额度、内环显示 5 小时额度，均从 12 点钟方向逆时针充盈：
///   实线段画到最低剩余量，最低到平均之间为 2-4 像素刻度虚线段。
/// - 中心为「水位杯」：水位高度映射 5h 最低剩余量，水体颜色由 waterHealth
///   （无值时回退整体健康度）决定。
/// - 缺失窗口沿用上一版语义，按满环 / 满水位呈现（isAvailable=false → 1.0），
///   与当前仪表盘「只画灰色底轨」的缺失语义不同。
enum QuotaLogoSVGBuilder {
    static let outerRadius: Double = 320
    static let outerStrokeWidth: Double = 26
    static let middleRadius: Double = 240
    static let middleStrokeWidth: Double = 46

    static let defaultOuterColor = "#FB923C"
    static let defaultMiddleColor = "#2DD4BF"
    /// waterHealth 与整体健康度都缺失时的水体回退色。
    static let defaultUnconfiguredColor = "#FB7185"

    /// 构建动态 SVG 文本。
    static func buildSVG(
        metrics: StatusBarQuotaMetrics,
        fallbackHealth: HealthLevel? = nil,
        healthColors: StatusBarHealthColors = .default
    ) -> String {
        let outer = legacyEffective(metrics.weekly)
        let middle = legacyEffective(metrics.interval)

        let healthLevel = metrics.waterHealth ?? fallbackHealth
        let waterColor = resolvedHex(for: healthLevel, colors: healthColors)

        let outerSolid = arcSegment(
            radius: outerRadius,
            start: 0.0,
            end: outer.minAvailable,
            isDashed: false,
            color: outer.colorHex,
            strokeWidth: outerStrokeWidth
        )
        let outerDashed = arcSegment(
            radius: outerRadius,
            start: outer.minAvailable,
            end: outer.avgAvailable,
            isDashed: true,
            color: outer.colorHex,
            strokeWidth: outerStrokeWidth
        )

        let middleSolid = arcSegment(
            radius: middleRadius,
            start: 0.0,
            end: middle.minAvailable,
            isDashed: false,
            color: middle.colorHex,
            strokeWidth: middleStrokeWidth
        )
        let middleDashed = arcSegment(
            radius: middleRadius,
            start: middle.minAvailable,
            end: middle.avgAvailable,
            isDashed: true,
            color: middle.colorHex,
            strokeWidth: middleStrokeWidth
        )

        let clampedWater = min(max(middle.minAvailable, 0.0), 1.0)
        let waterHeight = 310.0 * clampedWater
        let waterY = 702.0 - waterHeight

        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="160 160 704 704" role="img" aria-label="LLM quota monitor">
          <defs>
            <clipPath id="cup">
              <path d="M 364.69080 392.00000 H 659.30920 A 190 190 0 1 1 364.69080 392.00000 Z"/>
            </clipPath>
          </defs>
          \(outerSolid)
          \(outerDashed)
          \(middleSolid)
          \(middleDashed)
          <rect x="330" y="\(String(format: "%.2f", waterY))" width="365" height="\(String(format: "%.2f", waterHeight))" fill="\(waterColor)" clip-path="url(#cup)"/>
        </svg>
        """
    }

    /// 构建 NSImage 产物。
    static func buildImage(
        metrics: StatusBarQuotaMetrics,
        fallbackHealth: HealthLevel? = nil,
        healthColors: StatusBarHealthColors = .default
    ) -> NSImage? {
        let svg = buildSVG(metrics: metrics, fallbackHealth: fallbackHealth, healthColors: healthColors)
        guard let data = svg.data(using: .utf8) else { return nil }
        return NSImage(data: data)
    }

    /// 上一版缺失数据语义：没有该类窗口时按满环呈现，避免无数据被画成空环。
    private static func legacyEffective(_ ring: QuotaRingMetrics) -> QuotaRingMetrics {
        ring.isAvailable
            ? ring
            : QuotaRingMetrics(minAvailable: 1.0, avgAvailable: 1.0, colorHex: ring.colorHex)
    }

    /// 单段圆弧/圆环绘制
    private static func arcSegment(
        radius: Double,
        start: Double,
        end: Double,
        isDashed: Bool,
        color: String,
        strokeWidth: Double
    ) -> String {
        let span = end - start
        guard span > 0.005 else { return "" }

        // 32 64 对应 Retina @2x (44px) 屏上的“实线 2 像素、空白 4 像素”模式（32/16 = 2px, 64/16 = 4px），
        // 从而形成呼吸感极佳、颗粒度清晰的刻度虚线效果。
        let dashAttr = isDashed ? " stroke-dasharray=\"32 64\" stroke-linecap=\"butt\"" : " stroke-linecap=\"round\""

        if span >= 0.999 {
            return "<circle cx=\"512\" cy=\"512\" r=\"\(radius)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(strokeWidth)\"\(dashAttr)/>"
        }

        // 逆时针绘制：0.0 对应 12 点钟方向 (-π/2)，逆时针旋转（实线在左侧，虚线与空白在右侧）
        let a1 = -Double.pi / 2.0 - start * 2.0 * Double.pi
        let a2 = -Double.pi / 2.0 - end * 2.0 * Double.pi

        let x1 = 512.0 + radius * cos(a1)
        let y1 = 512.0 + radius * sin(a1)
        let x2 = 512.0 + radius * cos(a2)
        let y2 = 512.0 + radius * sin(a2)

        let largeArc = span > 0.5 ? 1 : 0
        let d = String(format: "M %.2f %.2f A %.0f %.0f 0 %d 0 %.2f %.2f", x1, y1, radius, radius, largeArc, x2, y2)
        return "<path d=\"\(d)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(strokeWidth)\"\(dashAttr)/>"
    }

    private static func resolvedHex(
        for level: HealthLevel?,
        colors: StatusBarHealthColors
    ) -> String {
        level.flatMap { colors.hexValue(for: $0) }
            ?? level.flatMap { StatusBarHealthColors.default.hexValue(for: $0) }
            ?? defaultUnconfiguredColor
    }
}
