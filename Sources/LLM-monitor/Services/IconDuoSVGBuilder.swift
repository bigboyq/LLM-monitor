import Foundation
import AppKit
import CoreText

/// 「Icon Duo」额度仪表盘 SVG 构建器（原 quotaLogo 重写版，1.9.0 起的布局）。
///
/// 正圆几何构图：
/// - 左弧显示 5h / interval，右弧显示周额度，从底部沿圆弧向上充盈；深灰色底槽与健康色填充弧平滑贴合。
/// - 左弧颜色由 interval 平均剩余量按 `colorLevel` 决定（5h 短窗口固定 30% 黄线；
///   ≥24h 长 interval 窗口按最宽剩余时间比例走动态黄线 min(time%, 50)）；右弧颜色
///   由周平均剩余量 + 全部周窗口中最宽的剩余时间比例（动态黄线 min(time%, 50)）决定。
/// - 顶部为节能模式状态圆点（半径放大为 r=48，红/黄/绿显示）。
/// - 底部 3 个状态点沿圆弧轨迹排布（115°、90°、65°，半径 r=36），按统一
///   `colorLevel`（实际可用口径）汇总各套餐健康度（红 > 黄 > 绿优先）；GLM 高峰期
///   对应套餐保底黄色，floor 只作用于底部三点与卡片头部点，弧线与中心不参与。
/// - 中心为有效 5h 额度数字，0...99 原样显示，100 显示 00；字形轮廓整体居中。
enum IconDuoSVGBuilder {
    private static let defaultUnconfiguredColor = "#8E8E93"

    private static let center = 352.0
    private static let outerRadius = 270.0
    /// 翻倍后的线段宽度（56px），确保在 22pt 菜单栏 Retina 屏上清晰醒目。
    private static let strokeWidth = 56.0

    /// Net space between the lamp's edge and each round arc cap is 0.75 lamp diameters.
    /// Both centers lie on the same circle, so convert their required chord distance to an angle.
    private static func energyHalfGapDegrees(lampRadius: Double) -> Double {
        let clearance = 0.75 * 2 * lampRadius
        let chord = lampRadius + strokeWidth / 2 + clearance
        return 2 * asin(chord / (2 * outerRadius)) * 180 / .pi
    }

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
        if let singleQuota = metrics.singleQuota {
            return buildSingleQuotaSVG(
                singleQuota,
                healthColors: healthColors,
                energyHealth: energyHealth,
                alertThresholds: metrics.alertThresholds
            )
        }

        let trackColor = "#48484A"
        // 统一时间感知 colorLevel 判定：左弧（interval / 5h avg）与右弧（周 avg）
        // 均以最宽剩余时间比例作为 timeFraction 输入（分母 = 100% * timeFraction，
        // < criticalPercent 红色，< warningPercent 黄色，否则绿色）。弧线不参与高峰 floor——高峰只
        // 作用于底部三点与卡片头部点（见 `ModelQuota.aggregateHealthLevel`）。
        let leftQuotaLevel = metrics.alertThresholds.colorLevel(
            percent: metrics.interval.avgAvailable * 100,
            timeFraction: metrics.intervalTimeFraction
        )
        let rightQuotaLevel = metrics.alertThresholds.colorLevel(
            percent: metrics.weekly.avgAvailable * 100,
            timeFraction: metrics.weeklyTimeFraction
        )
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

        // 2. 左弧（5h 额度）：顶部端点为灯与圆端帽预留统一净空。
        let halfGap = energyHalfGapDegrees(lampRadius: 48)
        let quotaArcSpan = 270 - halfGap - 140
        let leftTrackStart = point(degree: 140, radius: outerRadius)
        let leftTrackEnd = point(degree: 270 - halfGap, radius: outerRadius)
        let leftTrack = String(
            format: "<path id=\"interval-track\" d=\"M %.2f %.2f A %.2f %.2f 0 0 1 %.2f %.2f\" fill=\"none\" stroke=\"%@\" stroke-width=\"%.2f\" stroke-linecap=\"round\"/>",
            leftTrackStart.x, leftTrackStart.y, outerRadius, outerRadius, leftTrackEnd.x, leftTrackEnd.y, trackColor, strokeWidth
        )

        let leftSpan = quotaArcSpan * metrics.interval.avgAvailable
        let leftAvail: String
        if metrics.interval.isAvailable && leftSpan > 0.5 {
            let leftAvailEnd = point(degree: 140.0 + leftSpan, radius: outerRadius)
            leftAvail = String(
                format: "\n  <path id=\"interval-available\" d=\"M %.2f %.2f A %.2f %.2f 0 0 1 %.2f %.2f\" fill=\"none\" stroke=\"%@\" stroke-width=\"%.2f\" stroke-linecap=\"round\"/>",
                leftTrackStart.x, leftTrackStart.y, outerRadius, outerRadius, leftAvailEnd.x, leftAvailEnd.y, leftColor, strokeWidth
            )
        } else {
            leftAvail = ""
        }

        // 3. 右弧（周额度）：与左弧镜像，保持相同灯边净空。
        let rightTrackStart = point(degree: 40, radius: outerRadius)
        let rightTrackEnd = point(degree: 270 + halfGap, radius: outerRadius)
        let rightTrack = String(
            format: "<path id=\"weekly-track\" d=\"M %.2f %.2f A %.2f %.2f 0 0 0 %.2f %.2f\" fill=\"none\" stroke=\"%@\" stroke-width=\"%.2f\" stroke-linecap=\"round\"/>",
            rightTrackStart.x, rightTrackStart.y, outerRadius, outerRadius, rightTrackEnd.x, rightTrackEnd.y, trackColor, strokeWidth
        )

        let rightSpan = quotaArcSpan * metrics.weekly.avgAvailable
        let rightAvail: String
        if metrics.weekly.isAvailable && rightSpan > 0.5 {
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

        // 5. 中心数字沿用有效 5h 口径，周额度耗尽时仍约束为 0。
        let centerSVG = buildValueSVG(
            id: "center-quota-value",
            fraction: metrics.centerAvailable,
            timeFraction: metrics.centerTimeFraction,
            alertThresholds: metrics.alertThresholds,
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

    /// One selected pool gets one near-complete circular gauge. The small break at
    /// 12 o'clock gives the sleep indicator its own space; the value remains centered.
    private static func buildSingleQuotaSVG(
        _ quota: StatusBarSingleQuota,
        healthColors: StatusBarHealthColors,
        energyHealth: HealthLevel?,
        alertThresholds: AlertThresholdConfig
    ) -> String {
        let ringRadius = outerRadius
        let ringWidth = strokeWidth
        // The lamp replaces part of the ring on the same circumference; include
        // its radius and the round cap when reserving 0.75 lamp diameters per side.
        let halfGap = energyHalfGapDegrees(lampRadius: ringWidth / 2)
        let startDegrees = -90 + halfGap
        let trackEndDegrees = 270 - halfGap
        let trackSpan = trackEndDegrees - startDegrees
        let trackStart = point(degree: startDegrees, radius: ringRadius)
        let trackEnd = point(degree: trackEndDegrees, radius: ringRadius)
        let track = String(
            format: "<path id=\"single-quota-track\" d=\"M %.2f %.2f A %.2f %.2f 0 1 1 %.2f %.2f\" fill=\"none\" stroke=\"#48484A\" stroke-width=\"%.2f\" stroke-linecap=\"round\"/>",
            trackStart.x, trackStart.y, ringRadius, ringRadius, trackEnd.x, trackEnd.y, ringWidth
        )

        let quotaColor: String
        let available: String
        let valueMarkup = buildValueSVG(
            id: "single-quota-value", fraction: quota.remainingFraction,
            timeFraction: quota.timeRemainingFraction,
            alertThresholds: alertThresholds, healthColors: healthColors
        )
        if let fraction = quota.remainingFraction {
            let clamped = min(max(fraction, 0), 1)
            let percent = clamped * 100
            quotaColor = resolvedHex(
                for: alertThresholds.colorLevel(
                    percent: percent,
                    timeFraction: quota.timeRemainingFraction
                ),
                colors: healthColors
            )
            let displayedPercent = Int(percent.rounded())
            if clamped > 0 {
                let end = point(degree: startDegrees + trackSpan * clamped, radius: ringRadius)
                let largeArc = clamped * trackSpan > 180 ? 1 : 0
                available = String(
                    format: "<path id=\"single-quota-available\" data-value=\"%d\" d=\"M %.2f %.2f A %.2f %.2f 0 %d 1 %.2f %.2f\" fill=\"none\" stroke=\"%@\" stroke-width=\"%.2f\" stroke-linecap=\"round\"/>",
                    displayedPercent, trackStart.x, trackStart.y, ringRadius, ringRadius,
                    largeArc, end.x, end.y, quotaColor, ringWidth
                )
            } else {
                available = ""
            }
        } else {
            quotaColor = defaultUnconfiguredColor
            available = ""
        }

        let energyColor = energyHealth.map { resolvedHex(for: $0, colors: healthColors) }
            ?? defaultUnconfiguredColor
        let energyPoint = point(degree: 270, radius: ringRadius)
        let energyDot = String(
            format: "<circle id=\"energy-dot\" cx=\"%.2f\" cy=\"%.2f\" r=\"%.2f\" fill=\"%@\"/>",
            energyPoint.x, energyPoint.y, ringWidth / 2, energyColor
        )
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 704 704" role="img" aria-label="Selected quota">
          \(track)
          \(available)
          \(valueMarkup)
          \(energyDot)
        </svg>
        """
    }

    private static func buildValueSVG(
        id: String,
        fraction: Double?,
        timeFraction: Double?,
        alertThresholds: AlertThresholdConfig,
        healthColors: StatusBarHealthColors
    ) -> String {
        let display: String
        let value: String
        let color: String
        let fontSize: CGFloat
        if let fraction {
            let percent = min(max(fraction, 0), 1) * 100
            let rounded = Int(percent.rounded())
            display = rounded == 100 ? "00" : String(rounded)
            value = "\(rounded)%"
            color = resolvedHex(
                for: alertThresholds.colorLevel(percent: percent, timeFraction: timeFraction),
                colors: healthColors
            )
            fontSize = 280
        } else {
            display = "—"
            value = "—"
            color = defaultUnconfiguredColor
            fontSize = 190
        }
        let path = centeredValuePath(display, fontSize: fontSize)
        var commands: [String] = []
        path.applyWithBlock { element in
            let points = element.pointee.points
            func pointString(_ index: Int) -> String {
                String(format: "%.3f %.3f", points[index].x, points[index].y)
            }
            switch element.pointee.type {
            case .moveToPoint: commands.append("M \(pointString(0))")
            case .addLineToPoint: commands.append("L \(pointString(0))")
            case .addQuadCurveToPoint: commands.append("Q \(pointString(0)) \(pointString(1))")
            case .addCurveToPoint: commands.append("C \(pointString(0)) \(pointString(1)) \(pointString(2))")
            case .closeSubpath: commands.append("Z")
            @unknown default: break
            }
        }
        return """
        <g id="\(id)" data-value="\(value)" data-display="\(display)" aria-label="\(value)" font-size="\(Int(fontSize))"><path d="\(commands.joined(separator: " "))" fill="\(color)"/></g>
        """
    }

    /// Center the actual ink, not the font's advance box. SVG text-anchor can leave
    /// asymmetric side bearings (notably 51) looking off-center in AppKit's renderer.
    static func centeredValuePath(_ text: String, fontSize: CGFloat = 280) -> CGPath {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold) as CTFont
        let characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        let path = CGMutablePath()
        var x: CGFloat = 0
        for (index, glyph) in glyphs.enumerated() {
            if let outline = CTFontCreatePathForGlyph(font, glyph, nil) {
                path.addPath(outline, transform: CGAffineTransform(translationX: x, y: 0))
            }
            x += advances[index].width
        }
        let bounds = path.boundingBoxOfPath
        let transform = CGAffineTransform(
            a: 1, b: 0, c: 0, d: -1,
            tx: center - bounds.midX, ty: center + bounds.midY
        )
        let centered = CGMutablePath()
        centered.addPath(path, transform: transform)
        return centered
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
