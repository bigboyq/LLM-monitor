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
    let primaryTimeRemainingFraction: Double?

    init(
        primaryFraction: Double,
        weeklyFraction: Double,
        tint: Color,
        segments: Int,
        height: CGFloat,
        timeRemainingFraction: Double?,
        primaryTimeRemainingFraction: Double? = nil
    ) {
        self.primaryFraction = primaryFraction
        self.weeklyFraction = weeklyFraction
        self.tint = tint
        self.segments = segments
        self.height = height
        self.timeRemainingFraction = timeRemainingFraction
        self.primaryTimeRemainingFraction = primaryTimeRemainingFraction
    }

    private let triangleSize = CGSize(width: 6, height: 4)
    private let triangleGap: CGFloat = 1
    /// 槽位统一固定高度（8pt 进度条 + 4pt 标记三角 + 1pt 间距），
    /// 避免因单窗口无时间标记导致相邻卡片行高在 8pt 与 13pt 之间晃动。
    static let standardSlotHeight: CGFloat = 13
    private var markerHeight: CGFloat { triangleSize.height + triangleGap }
    private var totalHeight: CGFloat { Self.standardSlotHeight }

    /// 把外部传入的 timeRemainingFraction 限制在 [0, 1]，给 barColor / 三角位置共用。
    private var clampedFraction: Double? {
        timeRemainingFraction.map { min(max($0, 0), 1) }
    }

    /// 各段自适应栅格数：使得整条宽度上总栅格数始终保持在 35~42 格左右，
    /// 视觉间距与宽度极其均匀。
    static func ticksPerSegment(for segmentCount: Int) -> Int {
        let count = max(segmentCount, 1)
        switch count {
        case 1:  return 40
        case 2:  return 20
        case 5:  return 7
        case 6:  return 7
        case 7:  return 6
        case 10: return 4
        default:
            return max(3, min(40, Int((40.0 / Double(count)).rounded())))
        }
    }

    /// 根据当前段 fill 比例计算点亮的栅格数。
    /// 当 fill > 0 时向上取整并保底点亮至少 1 格，避免小额配额在视觉上显现全空。
    static func activeTickCount(fill: Double, totalTicks: Int) -> Int {
        guard totalTicks > 0 else { return 0 }
        let clamped = min(max(fill, 0.0), 1.0)
        if clamped <= 0 { return 0 }
        return max(1, min(totalTicks, Int((clamped * Double(totalTicks)).rounded(.up))))
    }

    var body: some View {
        let segmentFills = EquivalentQuotaAllocation.segmentFills(
            primaryFraction: primaryFraction,
            weeklyFraction: weeklyFraction,
            segments: segments
        )
        let segmentCount = max(segmentFills.count, 1)

        GeometryReader { geo in
            let totalWidth = geo.size.width
            let macroGap: CGFloat = segmentCount > 1 ? 4 : 0
            let totalGaps = CGFloat(segmentCount - 1) * macroGap
            let segmentWidth = max(0, (totalWidth - totalGaps) / CGFloat(segmentCount))
            let numTicks = Self.ticksPerSegment(for: segmentCount)
            let tickGap: CGFloat = 1.5
            let totalTickGaps = CGFloat(max(numTicks - 1, 0)) * tickGap
            let tickWidth = max(1.5, (segmentWidth - totalTickGaps) / CGFloat(numTicks))

            ZStack(alignment: .topLeading) {
                if let f = clampedFraction {
                    let halfWidth = triangleSize.width / 2
                    let posX = max(halfWidth, min(totalWidth - halfWidth, totalWidth * CGFloat(f)))
                    DownwardTriangle()
                        .fill(Color.red)
                        .frame(width: triangleSize.width, height: triangleSize.height)
                        .position(
                            x: posX,
                            y: triangleSize.height / 2
                        )
                }

                ZStack(alignment: .leading) {
                    HStack(spacing: macroGap) {
                        ForEach(0..<segmentCount, id: \.self) { segIndex in
                            let fill = segmentFills[segIndex]
                            let activeTicks = Self.activeTickCount(fill: fill, totalTicks: numTicks)
                            let segColor = segIndex == 0 ? intervalSegmentColor : weeklySegmentColor.opacity(0.68)

                            HStack(spacing: tickGap) {
                                ForEach(0..<numTicks, id: \.self) { tickIndex in
                                    let isActive = tickIndex < activeTicks
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(isActive ? segColor : Color.primary.opacity(0.10))
                                        .frame(width: tickWidth, height: height)
                                }
                            }
                            .frame(width: segmentWidth, height: height)
                        }
                    }

                    if segmentCount > 1 {
                        let dividerX = segmentWidth + macroGap / 2
                        RoundedRectangle(cornerRadius: 0.75)
                            .fill(Color.primary.opacity(0.28))
                            .frame(width: 1.5, height: height + 2)
                            .position(x: dividerX, y: height / 2)
                    }
                }
                .frame(width: totalWidth, height: height)
                .offset(y: markerHeight)
            }
            .frame(width: totalWidth, height: totalHeight)
        }
        .frame(height: totalHeight)
    }

    /// 第一格（interval / 5h）的颜色。
    /// - combined 模式：只用 primaryLevel，不受 weekly 影响
    /// - singleInterval：只看 primaryLevel
    /// - singleWeekly：降级为 weeklySegmentColor（此时 index 0 就是 weekly 格）
    ///
    /// `internal`（非 `private`）：纯计算、无渲染依赖，让测试能直接断言
    /// 各窗口模式的取色输入选择。
    var intervalSegmentColor: Color {
        switch windowMode {
        case .singleWeekly:
            return color(for: ModelQuota.colorLevel(percent: weeklyFraction * 100.0, timeFraction: clampedFraction))
        case .singleInterval, .combined:
            let tf = primaryTimeRemainingFraction ?? (segments == 1 ? clampedFraction : nil)
            return color(for: ModelQuota.colorLevel(percent: primaryFraction * 100.0, timeFraction: tf))
        }
    }

    /// 后续格（weekly 窗口余额）的颜色。
    /// - combined 模式：只用 weekLevel，与 5h 格独立
    /// - singleWeekly：同 intervalSegmentColor
    /// - singleInterval：不应有后续格，兜底到 intervalSegmentColor
    var weeklySegmentColor: Color {
        color(for: ModelQuota.colorLevel(percent: weeklyFraction * 100.0, timeFraction: clampedFraction))
    }

    private func color(for level: HealthLevel) -> Color {
        switch level {
        case .critical: return .criticalTint
        case .warning:  return .warningTint
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

/// 额度窗口瓶颈判定结果：指示哪个时间窗口的配额将优先耗尽
enum BindingQuotaWindow: Equatable, Sendable {
    /// 主短周期窗口（如 5h、日）为瓶颈
    case primary
    /// 周周期窗口为瓶颈
    case weekly
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

    /// 核心决策逻辑：判定哪一个窗口是约束瓶颈（Binding Window）。
    /// - min(5h, wk × N)；
    /// - 5h 更小 → .primary（主短周期额度先耗尽）
    /// - wk × N 更小 → .weekly（周额度先耗尽）
    /// - 相等时约定落到 .primary（与 min 在并列时取前值的约定一致）。
    static func bindingWindow(
        primaryFraction: Double,
        weeklyFraction: Double,
        segments: Int
    ) -> BindingQuotaWindow {
        let segmentCount = max(segments, 1)
        let normalizedPrimary = min(max(primaryFraction, 0), 1)
        let weeklyUnits = min(max(weeklyFraction, 0), 1) * Double(segmentCount)
        return weeklyUnits < normalizedPrimary ? .weekly : .primary
    }

    /// 根据决策结果获取重置时间，另一个窗口作为缺失兜底。
    static func bindingResetDate(primaryFraction: Double,
                                 weeklyFraction: Double,
                                 primaryResetsAt: Date?,
                                 weeklyResetsAt: Date?,
                                 segments: Int) -> Date? {
        let binding = bindingWindow(
            primaryFraction: primaryFraction,
            weeklyFraction: weeklyFraction,
            segments: segments
        )
        let primaryChoice = primaryResetsAt ?? weeklyResetsAt
        let weeklyChoice = weeklyResetsAt ?? primaryResetsAt
        return binding == .weekly ? weeklyChoice : primaryChoice
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
    case .critical: return .criticalTint
    case .warning:  return .warningTint
    case .healthy:
        // summary 没有 tint 上下文，用 primary 当基线；> 80% 额外加绿色信号
        return percent > 80 ? .healthyTint : .primary
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
