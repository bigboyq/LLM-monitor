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
    let multiplier: Double
    let height: CGFloat
    let timeRemainingFraction: Double?
    let primaryTimeRemainingFraction: Double?

    var segments: Int {
        Int(multiplier.rounded())
    }

    init(
        primaryFraction: Double,
        weeklyFraction: Double,
        tint: Color,
        multiplier: Double,
        height: CGFloat,
        timeRemainingFraction: Double?,
        primaryTimeRemainingFraction: Double? = nil
    ) {
        self.primaryFraction = primaryFraction
        self.weeklyFraction = weeklyFraction
        self.tint = tint
        self.multiplier = multiplier
        self.height = height
        self.timeRemainingFraction = timeRemainingFraction
        self.primaryTimeRemainingFraction = primaryTimeRemainingFraction
    }

    init(
        primaryFraction: Double,
        weeklyFraction: Double,
        tint: Color,
        segments: Int,
        height: CGFloat,
        timeRemainingFraction: Double?,
        primaryTimeRemainingFraction: Double? = nil
    ) {
        self.init(
            primaryFraction: primaryFraction,
            weeklyFraction: weeklyFraction,
            tint: tint,
            multiplier: Double(segments),
            height: height,
            timeRemainingFraction: timeRemainingFraction,
            primaryTimeRemainingFraction: primaryTimeRemainingFraction
        )
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

    /// 各段自适应栅格数：以 100 个数据栅格为全满基准，
    /// 确保 0～100 精确对应；多出来的 ~10 个点当量作为分段间隔（呼吸留白）。
    static func ticksPerSegment(for segmentCount: Int) -> Int {
        let count = max(segmentCount, 1)
        switch count {
        case 1:  return 100
        case 2:  return 50
        case 5:  return 20
        case 6:  return 17
        case 7:  return 14
        case 10: return 10
        default:
            return max(1, Int((100.0 / Double(count)).rounded()))
        }
    }

    /// 各段栅格分配：对于等宽整段保持自适应栅格；
    /// 对于非整数倍率（如 3.33），以 100 格为基准按容量权重分配各段栅格（如 30、30、30、10）。
    static func ticksForSegment(capacity: Double, totalCapacity: Double, segmentCount: Int) -> Int {
        if totalCapacity.truncatingRemainder(dividingBy: 1.0) < 0.001 {
            return ticksPerSegment(for: segmentCount)
        }
        let ratio = capacity / totalCapacity
        return max(1, Int((100.0 * ratio).rounded()))
    }

    /// 根据当前段 fill 比例计算点亮的栅格数。
    /// 规则（Half-Down 最近邻吸附）：
    /// - 贴近最近的整数刻度点；
    /// - 若遇到两边距离相等（小数部分恰为 0.5），则选择小的那个（向下吸附，保守估计余量）。
    /// 例如在 10 块区间中：44.9% 选 4 块 (40%)，45.1% 选 5 块 (50%)，45.0% 选 4 块 (40%)。
    static func activeTickCount(fill: Double, totalTicks: Int) -> Int {
        guard totalTicks > 0 else { return 0 }
        let clamped = min(max(fill, 0.0), 1.0)
        if clamped <= 0 { return 0 }
        if clamped >= 1.0 { return totalTicks }

        let raw = clamped * Double(totalTicks)
        let floorVal = floor(raw)
        let remainder = raw - floorVal
        // 浮点比较容差：遇中点 0.5（或因精度略小于等于 0.5000001）选择小的 floorVal
        let selected: Int
        if remainder <= 0.5 + 1e-9 {
            selected = Int(floorVal)
        } else {
            selected = Int(floorVal) + 1
        }
        return min(max(selected, 0), totalTicks)
    }

    var body: some View {
        let capacities = EquivalentQuotaAllocation.segmentCapacities(multiplier: multiplier)
        let segmentFills = EquivalentQuotaAllocation.segmentFills(
            primaryFraction: primaryFraction,
            weeklyFraction: weeklyFraction,
            multiplier: multiplier
        )
        let segmentCount = max(capacities.count, 1)
        let totalCapacity = max(capacities.reduce(0, +), 1.0)

        GeometryReader { geo in
            let totalWidth = geo.size.width
            let gapCount = max(segmentCount - 1, 0)
            // 多出来的 ~10 个点作为分割空间存在：
            // 当存在多个分段时，以 110 槽（100 数据槽 + 10 间隙槽）为基准模数；单窗口为 100 槽。
            let nominalSlots: Double = segmentCount > 1 ? 110.0 : 100.0
            let slotPitch = max(totalWidth / CGFloat(nominalSlots), 2.0)
            let macroGap: CGFloat = gapCount > 0 ? CGFloat((10.0 / Double(gapCount))) * slotPitch : 0
            let totalGaps = CGFloat(gapCount) * macroGap
            let availableWidth = max(0, totalWidth - totalGaps)

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
                            let cap = capacities[segIndex]
                            let segmentWidth = availableWidth * CGFloat(cap / totalCapacity)
                            let fill = segmentFills[segIndex]
                            let numTicks = Self.ticksForSegment(
                                capacity: cap,
                                totalCapacity: totalCapacity,
                                segmentCount: segmentCount
                            )
                            let activeTicks = Self.activeTickCount(fill: fill, totalTicks: numTicks)
                            let segColor = segIndex == 0 ? intervalSegmentColor : weeklySegmentColor.opacity(0.68)
                            let tickGap: CGFloat = 1.3
                            let totalTickGaps = CGFloat(max(numTicks - 1, 0)) * tickGap
                            let tickWidth = max(1.2, (segmentWidth - totalTickGaps) / CGFloat(numTicks))

                            HStack(spacing: tickGap) {
                                ForEach(0..<numTicks, id: \.self) { tickIndex in
                                    let isActive = tickIndex < activeTicks
                                    RoundedRectangle(cornerRadius: 1.0)
                                        .fill(isActive ? segColor : Color.primary.opacity(0.10))
                                        .frame(width: tickWidth, height: height)
                                }
                            }
                            .frame(width: segmentWidth, height: height)
                        }
                    }

                    if segmentCount > 1 {
                        let seg0Width = availableWidth * CGFloat(capacities[0] / totalCapacity)
                        let dividerX = seg0Width + macroGap / 2
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
            let tf = primaryTimeRemainingFraction ?? (multiplier <= 1.001 ? clampedFraction : nil)
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
    /// - singleWeekly：multiplier<=1 且有时间标记（长窗口 / 周度），只看 weekLevel
    /// - singleInterval：multiplier<=1 且无时间标记（5h），只看 primaryLevel
    /// - combined：multiplier>1（5h+周 组合条），各格独立着色
    private enum BarWindowMode {
        case singleWeekly
        case singleInterval
        case combined
    }

    private var windowMode: BarWindowMode {
        if multiplier > 1.001 { return .combined }
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
    /// 计算每个分段的容量权重。整段容量为 1.0；尾段容量为余数。
    static func segmentCapacities(multiplier: Double) -> [Double] {
        let m = max(multiplier, 1.0)
        let fullSegments = Int(m.rounded(.down))
        let remainder = m - Double(fullSegments)
        var capacities = Array(repeating: 1.0, count: max(fullSegments, 1))
        if remainder > 0.001 {
            capacities.append(remainder)
        }
        return capacities
    }

    static func effectivePrimaryFraction(primaryFraction: Double,
                                         weeklyFraction: Double,
                                         multiplier: Double) -> Double {
        let m = max(multiplier, 1.0)
        let normalizedPrimary = min(max(primaryFraction, 0), 1)
        let weeklyUnits = min(max(weeklyFraction, 0), 1) * m
        return min(normalizedPrimary, weeklyUnits)
    }

    static func effectivePrimaryFraction(primaryFraction: Double,
                                         weeklyFraction: Double,
                                         segments: Int) -> Double {
        effectivePrimaryFraction(
            primaryFraction: primaryFraction,
            weeklyFraction: weeklyFraction,
            multiplier: Double(segments)
        )
    }

    /// 核心决策逻辑：判定哪一个窗口是约束瓶颈（Binding Window）。
    /// - min(5h, wk × N)；
    /// - 5h 更小 → .primary（主短周期额度先耗尽）
    /// - wk × N 更小 → .weekly（周额度先耗尽）
    /// - 相等时约定落到 .primary（与 min 在并列时取前值的约定一致）。
    static func bindingWindow(
        primaryFraction: Double,
        weeklyFraction: Double,
        multiplier: Double
    ) -> BindingQuotaWindow {
        let m = max(multiplier, 1.0)
        let normalizedPrimary = min(max(primaryFraction, 0), 1)
        let weeklyUnits = min(max(weeklyFraction, 0), 1) * m
        return weeklyUnits < normalizedPrimary ? .weekly : .primary
    }

    static func bindingWindow(
        primaryFraction: Double,
        weeklyFraction: Double,
        segments: Int
    ) -> BindingQuotaWindow {
        bindingWindow(
            primaryFraction: primaryFraction,
            weeklyFraction: weeklyFraction,
            multiplier: Double(segments)
        )
    }

    /// 根据决策结果获取重置时间，另一个窗口作为缺失兜底。
    static func bindingResetDate(primaryFraction: Double,
                                 weeklyFraction: Double,
                                 primaryResetsAt: Date?,
                                 weeklyResetsAt: Date?,
                                 multiplier: Double) -> Date? {
        let binding = bindingWindow(
            primaryFraction: primaryFraction,
            weeklyFraction: weeklyFraction,
            multiplier: multiplier
        )
        let primaryChoice = primaryResetsAt ?? weeklyResetsAt
        let weeklyChoice = weeklyResetsAt ?? primaryResetsAt
        return binding == .weekly ? weeklyChoice : primaryChoice
    }

    static func bindingResetDate(primaryFraction: Double,
                                 weeklyFraction: Double,
                                 primaryResetsAt: Date?,
                                 weeklyResetsAt: Date?,
                                 segments: Int) -> Date? {
        bindingResetDate(
            primaryFraction: primaryFraction,
            weeklyFraction: weeklyFraction,
            primaryResetsAt: primaryResetsAt,
            weeklyResetsAt: weeklyResetsAt,
            multiplier: Double(segments)
        )
    }

    static func segmentFills(primaryFraction: Double,
                             weeklyFraction: Double,
                             multiplier: Double) -> [Double] {
        let capacities = segmentCapacities(multiplier: multiplier)
        let totalCapacity = max(capacities.reduce(0, +), 1.0)
        let weeklyUnits = min(max(weeklyFraction, 0), 1) * totalCapacity
        let currentWindowFill = effectivePrimaryFraction(
            primaryFraction: primaryFraction,
            weeklyFraction: weeklyFraction,
            multiplier: multiplier
        )
        guard weeklyUnits > currentWindowFill else {
            var fills = [capacities.isEmpty ? currentWindowFill : currentWindowFill / capacities[0]]
            if capacities.count > 1 {
                fills.append(contentsOf: repeatElement(0.0, count: capacities.count - 1))
            }
            return fills
        }

        var remainingFutureUnits = weeklyUnits - currentWindowFill
        var fills = [currentWindowFill / capacities[0]]

        for cap in capacities.dropFirst() {
            let allocated = min(remainingFutureUnits, cap)
            fills.append(allocated / cap)
            remainingFutureUnits = max(0, remainingFutureUnits - allocated)
        }
        return fills
    }

    static func segmentFills(primaryFraction: Double,
                             weeklyFraction: Double,
                             segments: Int) -> [Double] {
        segmentFills(
            primaryFraction: primaryFraction,
            weeklyFraction: weeklyFraction,
            multiplier: Double(segments)
        )
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
