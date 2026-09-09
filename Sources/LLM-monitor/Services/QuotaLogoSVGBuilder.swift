import Foundation
import AppKit

/// 描述单条圆环（周额度 / 5h 额度）的指标数据与视觉配置
struct QuotaRingMetrics: Equatable, Sendable {
    /// 最小保底可用量（0.0 ~ 1.0），绘制为实线段
    var minAvailable: Double
    /// 平均可用量（0.0 ~ 1.0），minAvailable 到 avgAvailable 绘制为虚线段
    var avgAvailable: Double
    /// 圆环描边颜色（十六进制字符串，如 "#FB923C"）
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

/// 状态栏动态额度指标快照
struct StatusBarQuotaMetrics: Equatable, Sendable {
    /// 外圈：周额度指标（原始物理剩余比例，无时间系数）
    var weekly: QuotaRingMetrics
    /// 中圈：5小时额度指标（原始物理剩余比例，无时间系数）
    var interval: QuotaRingMetrics
    /// 中心水位健康度等级（绿/黄/红，nil 表示未配置）
    var waterHealth: HealthLevel?

    init(
        weekly: QuotaRingMetrics,
        interval: QuotaRingMetrics,
        waterHealth: HealthLevel? = nil
    ) {
        self.weekly = weekly
        self.interval = interval
        self.waterHealth = waterHealth
    }

    static let full = StatusBarQuotaMetrics(
        weekly: QuotaRingMetrics(minAvailable: 1.0, avgAvailable: 1.0, colorHex: QuotaLogoSVGBuilder.defaultOuterColor),
        interval: QuotaRingMetrics(minAvailable: 1.0, avgAvailable: 1.0, colorHex: QuotaLogoSVGBuilder.defaultMiddleColor),
        waterHealth: nil
    )
}

/// 参数化动态 SVG 构建引擎：负责将外圈、中圈及中心水位渲染为 SVG 矢量图
enum QuotaLogoSVGBuilder {
    static let outerRadius: Double = 320
    static let outerStrokeWidth: Double = 26
    static let middleRadius: Double = 240
    static let middleStrokeWidth: Double = 46

    static let defaultOuterColor = "#FB923C"
    static let defaultMiddleColor = "#2DD4BF"
    static let defaultUnconfiguredColor = "#FB7185"

    /// 构建动态 SVG 文本
    /// - Parameters:
    ///   - outer: 外圈（周额度）指标
    ///   - middle: 中圈（5h 额度）指标
    ///   - waterPercent: 中心水深比例（0.0 ~ 1.0，代表 5h min_available）
    ///   - waterColor: 中心水体填充色 Hex（如 "#34C759"）
    static func buildSVG(
        outer: QuotaRingMetrics,
        middle: QuotaRingMetrics,
        waterPercent: Double,
        waterColor: String
    ) -> String {
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

        let clampedWater = min(max(waterPercent, 0.0), 1.0)
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

    /// 构建 NSImage 产物
    static func buildImage(
        outer: QuotaRingMetrics,
        middle: QuotaRingMetrics,
        waterPercent: Double,
        waterColor: String
    ) -> NSImage? {
        let svg = buildSVG(outer: outer, middle: middle, waterPercent: waterPercent, waterColor: waterColor)
        guard let data = svg.data(using: .utf8) else { return nil }
        return NSImage(data: data)
    }
}
