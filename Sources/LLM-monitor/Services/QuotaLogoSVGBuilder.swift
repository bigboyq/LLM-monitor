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
    /// 套餐健康点，已按红 > 黄 > 绿排序并补齐到四个。
    var quotaHealthLevels: [HealthLevel]
    /// 兼容旧调用方保留的综合状态；新版图标用它作为弧线健康色。
    var waterHealth: HealthLevel?

    init(
        weekly: QuotaRingMetrics,
        interval: QuotaRingMetrics,
        lowestAvailable: Double? = nil,
        quotaHealthLevels: [HealthLevel] = Array(repeating: .healthy, count: 4),
        waterHealth: HealthLevel? = nil
    ) {
        self.weekly = weekly
        self.interval = interval
        self.lowestAvailable = lowestAvailable.map { min(max($0, 0.0), 1.0) }
        self.quotaHealthLevels = Array(
            (quotaHealthLevels.sorted() + Array(repeating: .healthy, count: 4)).prefix(4)
        )
        self.waterHealth = waterHealth
    }

    static let full = StatusBarQuotaMetrics(
        weekly: QuotaRingMetrics(minAvailable: 1.0, avgAvailable: 1.0, colorHex: QuotaLogoSVGBuilder.defaultOuterColor),
        interval: QuotaRingMetrics(minAvailable: 1.0, avgAvailable: 1.0, colorHex: QuotaLogoSVGBuilder.defaultMiddleColor),
        lowestAvailable: 1.0,
        quotaHealthLevels: Array(repeating: .healthy, count: 4),
        waterHealth: .healthy
    )
}

/// 22pt 菜单栏额度仪表 SVG 构建器。
///
/// 左弧显示 5h，右弧显示周额度。每条弧从底部向顶部增长：连续实线长度代表
/// 平均剩余量，固定 2px 的红色短段标出最低剩余量，之后的灰色轨道代表空量。
/// 中间是全局最低剩余百分比，底部四点汇总套餐健康度，顶部闪电显示节能状态。
enum QuotaLogoSVGBuilder {
    static let defaultOuterColor = "#FB923C"
    static let defaultMiddleColor = "#2DD4BF"
    static let defaultUnconfiguredColor = "#8E8E93"

    private static let strokeWidth = 54.0
    /// 704 SVG units / 22pt / 2 Retina pixels-per-point = 16 units per pixel。
    private static let dividerLength = 32.0

    private struct Point {
        var x: Double
        var y: Double
    }

    private struct CubicCurve {
        let start: Point
        let control1: Point
        let control2: Point
        let end: Point

        var pathData: String {
            String(
                format: "M %.2f %.2f C %.2f %.2f %.2f %.2f %.2f %.2f",
                start.x, start.y,
                control1.x, control1.y,
                control2.x, control2.y,
                end.x, end.y
            )
        }

        func point(at rawT: Double) -> Point {
            let t = min(max(rawT, 0), 1)
            let u = 1 - t
            let x = u * u * u * start.x
                + 3 * u * u * t * control1.x
                + 3 * u * t * t * control2.x
                + t * t * t * end.x
            let y = u * u * u * start.y
                + 3 * u * u * t * control1.y
                + 3 * u * t * t * control2.y
                + t * t * t * end.y
            return Point(x: x, y: y)
        }

        func tangent(at rawT: Double) -> Point {
            let t = min(max(rawT, 0), 1)
            let u = 1 - t
            return Point(
                x: 3 * u * u * (control1.x - start.x)
                    + 6 * u * t * (control2.x - control1.x)
                    + 3 * t * t * (end.x - control2.x),
                y: 3 * u * u * (control1.y - start.y)
                    + 6 * u * t * (control2.y - control1.y)
                    + 3 * t * t * (end.y - control2.y)
            )
        }
    }

    private static let intervalCurve = CubicCurve(
        start: Point(x: 154, y: 526),
        control1: Point(x: 142, y: 368),
        control2: Point(x: 205, y: 208),
        end: Point(x: 306, y: 158)
    )

    private static let weeklyCurve = CubicCurve(
        start: Point(x: 550, y: 526),
        control1: Point(x: 562, y: 368),
        control2: Point(x: 499, y: 208),
        end: Point(x: 398, y: 158)
    )

    static func buildSVG(
        metrics: StatusBarQuotaMetrics,
        healthColors: StatusBarHealthColors = .default,
        energyHealth: HealthLevel? = nil
    ) -> String {
        let trackColor = "#5A5A5F"
        // 两侧额度弧始终用正常色；红色只承担 min/avg 分界，保证低额度时
        // 分割线也不会和整条弧融成同色。
        let quotaColor = resolvedHex(for: .healthy, colors: healthColors)
        let dividerColor = resolvedHex(for: .critical, colors: healthColors)
        let centerText = metrics.lowestAvailable.map {
            String(Int(($0 * 100.0).rounded()))
        } ?? "--"
        let energyColor = energyHealth.map { resolvedHex(for: $0, colors: healthColors) }
            ?? defaultUnconfiguredColor
        let dots = metrics.quotaHealthLevels.enumerated().map { index, level in
            let x = 250 + index * 68
            let color = resolvedHex(for: level, colors: healthColors)
            return "<circle cx=\"\(x)\" cy=\"622\" r=\"18\" fill=\"\(color)\"/>"
        }.joined(separator: "\n  ")

        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 704 704" role="img" aria-label="LLM quota monitor">
          <path d="M 360 10 L 334 50 H 351 L 342 104 L 378 45 H 360 L 368 10 Z" fill="\(energyColor)"/>
          \(arcSVG(curve: intervalCurve, metrics: metrics.interval, trackColor: trackColor, quotaColor: quotaColor, dividerColor: dividerColor, id: "interval"))
          \(arcSVG(curve: weeklyCurve, metrics: metrics.weekly, trackColor: trackColor, quotaColor: quotaColor, dividerColor: dividerColor, id: "weekly"))
          \(bitmapValueSVG(centerText))
          \(dots)
        </svg>
        """
    }

    /// 3×5 像素字模比 5pt 文本在 22pt 的最终 1x NSImage 中更清晰，避免双位数
    /// 被字体抗锯齿糊成一块。菜单栏在 Retina 屏上仍会自然获得 2x 插值。
    private static func bitmapValueSVG(_ value: String) -> String {
        let glyphs: [Character: [String]] = [
            "0": ["111", "101", "101", "101", "111"],
            "1": ["010", "110", "010", "010", "111"],
            "2": ["111", "001", "111", "100", "111"],
            "3": ["111", "001", "111", "001", "111"],
            "4": ["101", "101", "111", "001", "001"],
            "5": ["111", "100", "111", "001", "111"],
            "6": ["111", "100", "111", "101", "111"],
            "7": ["111", "001", "010", "010", "010"],
            "8": ["111", "101", "111", "101", "111"],
            "9": ["111", "101", "111", "001", "111"],
            "-": ["000", "000", "111", "000", "000"]
        ]
        let characters = Array(value)
        let pixelSize = 28
        let cellStep = 32
        let glyphWidth = 92
        let glyphGap = 12
        let totalWidth = characters.count * glyphWidth + max(characters.count - 1, 0) * glyphGap
        let originX = 352 - totalWidth / 2
        let originY = 302
        var pixels: [String] = []

        for (glyphIndex, character) in characters.enumerated() {
            guard let rows = glyphs[character] else { continue }
            let glyphX = originX + glyphIndex * (glyphWidth + glyphGap)
            for (row, pattern) in rows.enumerated() {
                for (column, bit) in pattern.enumerated() where bit == "1" {
                    pixels.append(
                        "<rect x=\"\(glyphX + column * cellStep)\" y=\"\(originY + row * cellStep)\" width=\"\(pixelSize)\" height=\"\(pixelSize)\" rx=\"3\"/>"
                    )
                }
            }
        }

        return """
        <g id="minimum-value" data-value="\(value)" fill="#F2F2F7">
            \(pixels.joined(separator: "\n    "))
          </g>
        """
    }

    private static func resolvedHex(
        for level: HealthLevel,
        colors: StatusBarHealthColors
    ) -> String {
        colors.hexValue(for: level)
            ?? StatusBarHealthColors.default.hexValue(for: level)
            ?? defaultUnconfiguredColor
    }

    private static func arcSVG(
        curve: CubicCurve,
        metrics: QuotaRingMetrics,
        trackColor: String,
        quotaColor: String,
        dividerColor: String,
        id: String
    ) -> String {
        let filledLength = metrics.avgAvailable * 1000.0
        var elements = """
        <path id="\(id)-track" d="\(curve.pathData)" pathLength="1000" fill="none" stroke="\(trackColor)" stroke-opacity="0.72" stroke-width="\(strokeWidth)" stroke-linecap="round"/>
          <path id="\(id)-available" d="\(curve.pathData)" pathLength="1000" fill="none" stroke="\(quotaColor)" stroke-width="\(strokeWidth)" stroke-linecap="round" stroke-dasharray="\(String(format: "%.2f", filledLength)) 1000"/>
        """

        if metrics.avgAvailable - metrics.minAvailable > 0.005 {
            let point = curve.point(at: metrics.minAvailable)
            let tangent = curve.tangent(at: metrics.minAvailable)
            let magnitude = max(hypot(tangent.x, tangent.y), 0.001)
            let dx = tangent.x / magnitude * dividerLength / 2
            let dy = tangent.y / magnitude * dividerLength / 2
            elements += """

              <line id="\(id)-minimum" data-divider-length="32" x1="\(String(format: "%.2f", point.x - dx))" y1="\(String(format: "%.2f", point.y - dy))" x2="\(String(format: "%.2f", point.x + dx))" y2="\(String(format: "%.2f", point.y + dy))" stroke="\(dividerColor)" stroke-width="\(strokeWidth)" stroke-linecap="butt"/>
            """
        }
        return elements
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
