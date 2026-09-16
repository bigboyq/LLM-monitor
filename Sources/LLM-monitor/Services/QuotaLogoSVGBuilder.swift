import Foundation
import AppKit

/// 描述单侧额度弧（周额度 / 5h 额度）的聚合数据。
struct QuotaRingMetrics: Equatable, Sendable {
    /// 所有套餐中的最低可用量（0.0 ... 1.0），红色短线标记这个位置。
    var minAvailable: Double
    /// 所有套餐的平均可用量（0.0 ... 1.0），决定连续实线的总长度。
    var avgAvailable: Double
    /// 兼容旧配置与调用方保留的强调色；新版仪表统一使用健康色绘制额度弧。
    var colorHex: String

    init(minAvailable: Double, avgAvailable: Double, colorHex: String) {
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
    /// 所有有效套餐、所有有效窗口中的最低剩余比例；nil 表示暂无额度数据。
    var lowestAvailable: Double?
    /// 套餐健康点，已按红 > 黄 > 绿排序并补齐到三个。
    var quotaHealthLevels: [HealthLevel]
    /// 兼容旧调用方保留的综合状态；新版图标用它作为弧线健康色。
    var waterHealth: HealthLevel?

    init(
        weekly: QuotaRingMetrics,
        interval: QuotaRingMetrics,
        lowestAvailable: Double? = nil,
        quotaHealthLevels: [HealthLevel] = Array(repeating: .healthy, count: 3),
        waterHealth: HealthLevel? = nil
    ) {
        self.weekly = weekly
        self.interval = interval
        self.lowestAvailable = lowestAvailable.map { min(max($0, 0.0), 1.0) }
        self.quotaHealthLevels = Self.resolveTopThreeHealthLevels(quotaHealthLevels)
        self.waterHealth = waterHealth
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
        lowestAvailable: 1.0,
        quotaHealthLevels: Array(repeating: .healthy, count: 3),
        waterHealth: .healthy
    )
}

/// 22pt 菜单栏额度仪表 SVG 构建器。
///
/// 正圆几何构图：
/// - 左弧显示 5h，右弧显示周额度，从底部沿圆弧向上充盈；深灰色底槽与健康色填充弧平滑贴合。
/// - 左弧颜色由 5h 平均剩余量根据统一标准决定；右弧颜色由周平均剩余量决定。
/// - 顶部为节能模式状态圆点（半径放大为 r=48，红/黄/绿显示）。
/// - 底部 3 个状态点沿圆弧轨迹排布（115°、90°、65°，半径 r=36），汇总各套餐健康度（红 > 黄 > 绿优先）。
/// - 中心为扇形圆，满额度为 360° 正圆，随着额度消耗从 6 点钟（底端）向左右对称打开；
///   剩余面积保留在 12 点钟（顶端）；50% 额度时呈现 180° 上半圆；额度耗尽时呈现红色空心圆环。
enum QuotaLogoSVGBuilder {
    static let defaultOuterColor = "#FB923C"
    static let defaultMiddleColor = "#2DD4BF"
    static let defaultUnconfiguredColor = "#8E8E93"

    private static let center = 352.0
    private static let outerRadius = 270.0
    /// 翻倍后的线段宽度（56px），确保在 22pt 菜单栏 Retina 屏上清晰醒目。
    private static let strokeWidth = 56.0
    private static let innerRadius = 135.0

    private static func point(degree: Double, radius: Double) -> (x: Double, y: Double) {
        let rad = degree * Double.pi / 180.0
        return (
            center + radius * cos(rad),
            center + radius * sin(rad)
        )
    }

    static func buildSVG(
        metrics: StatusBarQuotaMetrics,
        healthColors: StatusBarHealthColors = .default,
        energyHealth: HealthLevel? = nil
    ) -> String {
        let trackColor = "#48484A"
        // 统一标准：左弧颜色由 5h avg 决定，右弧颜色由周 avg 决定
        let leftQuotaLevel = HealthLevel.standard(forFraction: metrics.interval.avgAvailable)
        let rightQuotaLevel = HealthLevel.standard(forFraction: metrics.weekly.avgAvailable)
        let leftColor = resolvedHex(for: leftQuotaLevel, colors: healthColors)
        let rightColor = resolvedHex(for: rightQuotaLevel, colors: healthColors)
        let energyColor = energyHealth.map { resolvedHex(for: $0, colors: healthColors) }
            ?? defaultUnconfiguredColor

        // 1. 顶部节能模式状态点（半径 r=48，红黄绿显示）
        let topEnergyPoint = point(degree: 270.0, radius: outerRadius)
        let energyDot = String(
            format: "<circle id=\"energy-dot\" cx=\"%.2f\" cy=\"%.2f\" r=\"48\" fill=\"%@\"/>",
            topEnergyPoint.x, topEnergyPoint.y, energyColor
        )

        // 2. 左弧（5h 额度）：从 140° (底) 到 244° (顶)，顺时针跨度 104°
        let leftTrackStart = point(degree: 140, radius: outerRadius)
        let leftTrackEnd = point(degree: 244, radius: outerRadius)
        let leftTrack = String(
            format: "<path id=\"interval-track\" d=\"M %.2f %.2f A %.2f %.2f 0 0 1 %.2f %.2f\" fill=\"none\" stroke=\"%@\" stroke-width=\"%.2f\" stroke-linecap=\"round\"/>",
            leftTrackStart.x, leftTrackStart.y, outerRadius, outerRadius, leftTrackEnd.x, leftTrackEnd.y, trackColor, strokeWidth
        )

        let leftSpan = 104.0 * metrics.interval.avgAvailable
        let leftAvail: String
        if leftSpan > 0.5 {
            let leftAvailEnd = point(degree: 140.0 + leftSpan, radius: outerRadius)
            leftAvail = String(
                format: "\n  <path id=\"interval-available\" d=\"M %.2f %.2f A %.2f %.2f 0 0 1 %.2f %.2f\" fill=\"none\" stroke=\"%@\" stroke-width=\"%.2f\" stroke-linecap=\"round\"/>",
                leftTrackStart.x, leftTrackStart.y, outerRadius, outerRadius, leftAvailEnd.x, leftAvailEnd.y, leftColor, strokeWidth
            )
        } else {
            leftAvail = ""
        }

        // 3. 右弧（周额度）：从 40° (底) 到 296° (顶)，逆时针跨度 104°
        let rightTrackStart = point(degree: 40, radius: outerRadius)
        let rightTrackEnd = point(degree: 296, radius: outerRadius)
        let rightTrack = String(
            format: "<path id=\"weekly-track\" d=\"M %.2f %.2f A %.2f %.2f 0 0 0 %.2f %.2f\" fill=\"none\" stroke=\"%@\" stroke-width=\"%.2f\" stroke-linecap=\"round\"/>",
            rightTrackStart.x, rightTrackStart.y, outerRadius, outerRadius, rightTrackEnd.x, rightTrackEnd.y, trackColor, strokeWidth
        )

        let rightSpan = 104.0 * metrics.weekly.avgAvailable
        let rightAvail: String
        if rightSpan > 0.5 {
            let rightAvailEnd = point(degree: 40.0 - rightSpan, radius: outerRadius)
            rightAvail = String(
                format: "\n  <path id=\"weekly-available\" d=\"M %.2f %.2f A %.2f %.2f 0 0 0 %.2f %.2f\" fill=\"none\" stroke=\"%@\" stroke-width=\"%.2f\" stroke-linecap=\"round\"/>",
                rightTrackStart.x, rightTrackStart.y, outerRadius, outerRadius, rightAvailEnd.x, rightAvailEnd.y, rightColor, strokeWidth
            )
        } else {
            rightAvail = ""
        }

        // 4. 底部 3 个沿圆弧排布的状态点（半径放大为 r=36，分布在 115°、90°、65°）
        let dotAngles = [115.0, 90.0, 65.0]
        var dots: [String] = []
        for (index, angle) in dotAngles.enumerated() {
            let p = point(degree: angle, radius: outerRadius)
            let level = index < metrics.quotaHealthLevels.count ? metrics.quotaHealthLevels[index] : .healthy
            let color = resolvedHex(for: level, colors: healthColors)
            dots.append(String(
                format: "<circle id=\"quota-dot-%d\" cx=\"%.2f\" cy=\"%.2f\" r=\"36\" fill=\"%@\"/>",
                index, p.x, p.y, color
            ))
        }
        let dotsStr = dots.joined(separator: "\n  ")

        // 5. 中心扇形圆：以 12 点钟为顶，从 6 点钟底端向左右对称打开
        let centerSVG = buildCenterSectorSVG(
            lowestAvailable: metrics.lowestAvailable,
            healthColors: healthColors
        )

        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 704 704" role="img" aria-label="LLM quota monitor">
          \(energyDot)
          \(leftTrack)\(leftAvail)
          \(rightTrack)\(rightAvail)
          \(centerSVG)
          \(dotsStr)
        </svg>
        """
    }

    private static func buildCenterSectorSVG(
        lowestAvailable: Double?,
        healthColors: StatusBarHealthColors
    ) -> String {
        let bgDisc = "<circle id=\"center-track\" cx=\"352\" cy=\"352\" r=\"135\" fill=\"#2C2C2E\" fill-opacity=\"0.6\"/>"
        guard let pRaw = lowestAvailable else {
            let emptyColor = defaultUnconfiguredColor
            return """
            \(bgDisc)
              <circle id=\"center-sector\" cx=\"352\" cy=\"352\" r=\"135\" fill=\"none\" stroke=\"\(emptyColor)\" stroke-width=\"8\"/>
            """
        }

        let p = min(max(pRaw, 0.0), 1.0)
        let healthLevel = HealthLevel.standard(forFraction: p)
        let sectorColor = resolvedHex(for: healthLevel, colors: healthColors)
        let percentValue = Int((p * 100).rounded())

        if p >= 0.999 {
            return """
            \(bgDisc)
              <circle id=\"center-sector\" data-value=\"\(percentValue)\" cx=\"352\" cy=\"352\" r=\"135\" fill=\"\(sectorColor)\"/>
            """
        } else if p <= 0.005 {
            return """
            \(bgDisc)
              <circle id=\"center-sector\" data-value=\"0\" cx=\"352\" cy=\"352\" r=\"135\" fill=\"none\" stroke=\"\(sectorColor)\" stroke-width=\"8\"/>
            """
        } else {
            // 锚定 12 点钟（3π/2），随着额度消耗从 6 点钟（底端）向左右对称打开
            let alpha = Double.pi * p
            let a1 = 3.0 * Double.pi / 2.0 - alpha
            let a2 = 3.0 * Double.pi / 2.0 + alpha
            let x1 = center + innerRadius * cos(a1)
            let y1 = center + innerRadius * sin(a1)
            let x2 = center + innerRadius * cos(a2)
            let y2 = center + innerRadius * sin(a2)
            let largeArc = p > 0.5 ? 1 : 0
            let path = String(
                format: "<path id=\"center-sector\" data-value=\"%d\" d=\"M %.2f %.2f L %.2f %.2f A %.2f %.2f 0 %d 1 %.2f %.2f Z\" fill=\"%@\"/>",
                percentValue, center, center, x1, y1, innerRadius, innerRadius, largeArc, x2, y2, sectorColor
            )
            return """
            \(bgDisc)
              \(path)
            """
        }
    }

    private static func resolvedHex(
        for level: HealthLevel,
        colors: StatusBarHealthColors
    ) -> String {
        colors.hexValue(for: level)
            ?? StatusBarHealthColors.default.hexValue(for: level)
            ?? defaultUnconfiguredColor
    }

    static func buildImage(
        metrics: StatusBarQuotaMetrics,
        healthColors: StatusBarHealthColors = .default,
        energyHealth: HealthLevel? = nil
    ) -> NSImage? {
        let svg = buildSVG(metrics: metrics, healthColors: healthColors, energyHealth: energyHealth)
        guard let data = svg.data(using: .utf8) else { return nil }
        return NSImage(data: data)
    }
}
