import SwiftUI

// MARK: - 进度条 + 等价额度算法

/// 周额度条把同时生效的短周期/周上限编码为分段：第一格是当前窗口实际可用量，
/// 后续格是扣除当前窗口后仍可留给未来窗口的周额度。
///
/// `timeRemainingFraction` 非 nil 时，bar 顶部会画一个红色下指三角 ▼，
/// 位置按 0.0 (即将过期) → 1.0 (刚重置) 映射到条宽。call site 只在画周窗口
/// 进度条时传值，5h 进度条不画（与产品偏好一致）。
struct SegmentedQuotaProgressBar: View {
    let primaryFraction: Double
    let weeklyFraction: Double
    let tint: Color
    let segments: Int
    let height: CGFloat
    let timeRemainingFraction: Double?

    private let triangleSize = CGSize(width: 6, height: 4)
    private let triangleGap: CGFloat = 1
    /// 只有当有时间标记时才在 bar 顶部腾出空间。
    /// 没有标记时（5h-only / weekly 数据缺失）整体高度仍是 8pt，
    /// 不会让 bar 看起来「上半截没了」。
    private var hasMarker: Bool { timeRemainingFraction != nil }
    private var markerHeight: CGFloat { hasMarker ? triangleSize.height + triangleGap : 0 }
    private var totalHeight: CGFloat { height + markerHeight }

    /// 把外部传入的 timeRemainingFraction 限制在 [0, 1]，给 barColor / 三角位置共用。
    private var clampedFraction: Double? {
        timeRemainingFraction.map { min(max($0, 0), 1) }
    }

    var body: some View {
        let segmentFills = EquivalentQuotaAllocation.segmentFills(
            primaryFraction: primaryFraction,
            weeklyFraction: weeklyFraction,
            segments: segments
        )
        let segmentCount = max(segmentFills.count, 1)

        GeometryReader { geo in
            let segmentWidth = geo.size.width / CGFloat(segmentCount)
            ZStack(alignment: .topLeading) {
                if let f = clampedFraction {
                    let halfWidth = triangleSize.width / 2
                    let posX = max(halfWidth, min(geo.size.width - halfWidth, geo.size.width * CGFloat(f)))
                    DownwardTriangle()
                        .fill(Color.red)
                        .frame(width: triangleSize.width, height: triangleSize.height)
                        .position(
                            x: posX,
                            y: triangleSize.height / 2
                        )
                }

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: height)

                    ForEach(0..<segmentCount, id: \.self) { index in
                        let fill = segmentFills[index]
                        if fill > 0 {
                            let color = index == 0 ? intervalSegmentColor : weeklySegmentColor
                            Rectangle()
                                .fill(index == 0 ? color : color.opacity(0.72))
                                .frame(width: segmentWidth * fill, height: height)
                                .offset(x: segmentWidth * CGFloat(index))
                        }
                    }

                    ForEach(1..<segmentCount, id: \.self) { index in
                            Rectangle()
                                .fill(Color.primary.opacity(0.32))
                                .frame(width: 1, height: height + 2)
                                .position(
                                    x: geo.size.width * CGFloat(index) / CGFloat(segmentCount),
                                    y: height / 2
                                )
                    }
                }
                .frame(width: geo.size.width, height: height)
                .clipShape(Capsule())
                .offset(y: markerHeight)
            }
            .frame(width: geo.size.width, height: totalHeight)
        }
        .frame(height: totalHeight)
    }

    /// 第一格（interval / 5h）的颜色。
    /// - combined 模式：只用 primaryLevel，不受 weekly 影响
    /// - singleInterval：只看 primaryLevel
    /// - singleWeekly：降级为 weeklySegmentColor（此时 index 0 就是 weekly 格）
    private var intervalSegmentColor: Color {
        switch windowMode {
        case .singleWeekly:
            return color(for: ModelQuota.colorLevel(percent: weeklyFraction * 100.0, timeFraction: clampedFraction))
        case .singleInterval, .combined:
            return color(for: ModelQuota.colorLevel(percent: primaryFraction * 100.0, timeFraction: nil))
        }
    }

    /// 后续格（weekly 窗口余额）的颜色。
    /// - combined 模式：只用 weekLevel，与 5h 格独立
    /// - singleWeekly：同 intervalSegmentColor
    /// - singleInterval：不应有后续格，兜底到 intervalSegmentColor
    private var weeklySegmentColor: Color {
        color(for: ModelQuota.colorLevel(percent: weeklyFraction * 100.0, timeFraction: clampedFraction))
    }

    private func color(for level: HealthLevel) -> Color {
        switch level {
        case .critical: return .red
        case .warning:  return .yellow
        case .healthy:  return tint
        }
    }

    /// 单窗口 / 组合窗口模式。
    /// - singleWeekly：segments=1 且有时间标记（长窗口 / 周度），只看 weekLevel
    /// - singleInterval：segments=1 且无时间标记（5h），只看 primaryLevel
    /// - combined：segments>1（5h+周 组合条），各格独立着色
    private enum BarWindowMode {
        case singleWeekly
        case singleInterval
        case combined
    }

    private var windowMode: BarWindowMode {
        if segments > 1 { return .combined }
        return timeRemainingFraction != nil ? .singleWeekly : .singleInterval
    }
}

/// 将同时生效的短周期、周配额投影到等价短周期格。首格专属当前窗口；若周额度更高，
/// 周剩余的余数格紧随其后，再接整格，避免截断周余额。
enum EquivalentQuotaAllocation {
    static func effectivePrimaryFraction(primaryFraction: Double,
                                         weeklyFraction: Double,
                                         segments: Int) -> Double {
        let segmentCount = max(segments, 1)
        let normalizedPrimary = min(max(primaryFraction, 0), 1)
        let weeklyUnits = min(max(weeklyFraction, 0), 1) * Double(segmentCount)
        return min(normalizedPrimary, weeklyUnits)
    }

    /// 哪个窗口是 binding constraint：min(5h, wk × N)。
    /// 返回该窗口的 reset time，另一个窗口作为兜底。
    /// - 5h 更小 → 显示 5h reset（5h 即将重置，醒来就能继续用）
    /// - wk × N 更小 → 显示 wk reset（不管 5h 还剩多少，wk 撑死了没法用）
    /// - 相等时按约定落到 5h（与 effectivePrimaryFraction 的 min 在并列时取前值的实现一致）。
    static func bindingResetDate(primaryFraction: Double,
                                 weeklyFraction: Double,
                                 primaryResetsAt: Date?,
                                 weeklyResetsAt: Date?,
                                 segments: Int) -> Date? {
        let segmentCount = max(segments, 1)
        let normalizedPrimary = min(max(primaryFraction, 0), 1)
        let weeklyUnits = min(max(weeklyFraction, 0), 1) * Double(segmentCount)
        let weeklyIsBinding = weeklyUnits < normalizedPrimary
        return (weeklyIsBinding ? weeklyResetsAt : primaryResetsAt)
            ?? (weeklyIsBinding ? primaryResetsAt : weeklyResetsAt)
    }

    static func segmentFills(primaryFraction: Double,
                             weeklyFraction: Double,
                             segments: Int) -> [Double] {
        let segmentCount = max(segments, 1)
        let weeklyUnits = min(max(weeklyFraction, 0), 1) * Double(segmentCount)
        let currentWindowFill = effectivePrimaryFraction(
            primaryFraction: primaryFraction,
            weeklyFraction: weeklyFraction,
            segments: segmentCount
        )
        guard weeklyUnits > currentWindowFill else {
            var fills = [currentWindowFill]
            if segmentCount > 1 {
                fills.append(contentsOf: repeatElement(0.0, count: segmentCount - 1))
            }
            return fills
        }

        // 第一格始终代表当前窗口，因此未来额度最多只能占剩下的 N-1 格。
        // 例如 primary=0 / weekly=100% 时，旧实现会返回 N+1 个元素。
        let futureWeeklyUnits = min(
            weeklyUnits - currentWindowFill,
            Double(max(segmentCount - 1, 0))
        )
        let fullFutureCount = Int(futureWeeklyUnits.rounded(.down))
        let partialFutureFill = futureWeeklyUnits.truncatingRemainder(dividingBy: 1)
        var fills = [currentWindowFill]

        fills.append(contentsOf: repeatElement(1.0, count: fullFutureCount))
        if partialFutureFill > 0.000_001 {
            fills.append(partialFutureFill)
        }

        if fills.count < segmentCount {
            fills.append(contentsOf: repeatElement(0.0, count: segmentCount - fills.count))
        }
        return Array(fills.prefix(segmentCount))
    }
}

func summaryColor(for percent: Double, timeFraction: Double? = nil) -> Color {
    switch ModelQuota.colorLevel(percent: percent, timeFraction: timeFraction) {
    case .critical: return .red
    case .warning:  return .yellow
    case .healthy:
        // summary 没有 tint 上下文，用 primary 当基线；> 80% 额外加绿色信号
        return percent > 80 ? .green : .primary
    }
}

/// 向下指的实心三角 ▼。rect.maxY 是尖端，rect.minY 是顶边两端。
struct DownwardTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
