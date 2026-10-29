import SwiftUI

/// Shared seven-day history section for local providers and fleet projections.
/// It owns only history metric selection and never reads the quota-window segment.
struct SevenDayUsageHistoryView: View {
    let days: [UsageHistoryDay]
    let scannedAt: Date?
    let isScanning: Bool
    let isTruncated: Bool
    let showsHeader: Bool

    @AppStorage(UsageHistoryMetric.storageKey) private var metricRawValue = UsageHistoryMetric.total.rawValue
    @Environment(\.hoverRevealMode) private var revealMode

    init(
        days: [UsageHistoryDay],
        scannedAt: Date?,
        isScanning: Bool,
        isTruncated: Bool = false,
        showsHeader: Bool = true
    ) {
        self.days = days
        self.scannedAt = scannedAt
        self.isScanning = isScanning
        self.isTruncated = isTruncated
        self.showsHeader = showsHeader
    }

    private var selectedMetric: UsageHistoryMetric {
        UsageHistoryMetric(rawValue: metricRawValue) ?? .total
    }

    private var selectedPoints: [Double?] {
        days.map { UsageHistoryNumber.finiteNonnegative($0.value(for: selectedMetric)) }
    }

    private var selectedMaximum: Double {
        let maxVal = selectedPoints.compactMap { $0 }.max() ?? 0
        if selectedMetric.isRate {
            return max(maxVal, 1.0)
        }
        return max(maxVal, 1)
    }

    private var lineColor: Color {
        switch selectedMetric {
        case .total: Color.tokenOutputTint
        case .rounds: Color.purple
        case .value: Color.orange
        case .speed: Color.cyan
        case .hit: Color.tokenCacheReadTint
        case .thinking: Color(red: 0.90, green: 0.46, blue: 0.16)
        case .outputRatio: Color.tokenInputTint
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if showsHeader, revealMode != .alwaysVisible {
                HStack(alignment: .firstTextBaseline) {
                    Text("最近7天使用历史")
                        .font(MenuTypography.hoverTitle)
                    Spacer()
                    LocalUsageFreshnessBadge(scannedAt: scannedAt, isScanning: isScanning)
                }
            }

            if days.contains(where: \.hasAnyData) {
                metricPicker
                chart
                Divider().opacity(0.45)
                dailyTable

                Text("总量 = Input + Cache + Output + Reason；Cache write 不计入。R/T = Rounds / Turns。速度为每日 Prompt P50。今天数据尚未结束；缺失日期以断线显示。")
                    .font(MenuTypography.hint)
                    .foregroundStyle(.tertiary)

                if isTruncated {
                    Text(ClientUsageTruncationNotice.text)
                        .font(MenuTypography.hoverFootnote)
                        .foregroundStyle(.orange)
                }
            } else {
                HStack(spacing: 6) {
                    if isScanning {
                        ProgressView().controlSize(.mini).scaleEffect(0.65)
                    } else {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(.quaternary)
                    }
                    Text(isScanning ? "正在扫描本地用量…" : "暂无七天历史数据")
                        .font(MenuTypography.hint)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: SevenDayUsageChartMetrics.pricedWidth, alignment: .leading)
    }

    private var metricPicker: some View {
        HStack(spacing: 5) {
            ForEach(UsageHistoryMetric.allCases) { metric in
                Button {
                    metricRawValue = metric.rawValue
                } label: {
                    Text(metric.title)
                        .font(selectedMetric == metric ? MenuTypography.dataLabel : MenuTypography.metricLabel)
                        .foregroundStyle(selectedMetric == metric ? Color.primary : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            selectedMetric == metric ? lineColor.opacity(0.20) : Color.secondary.opacity(0.08),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedMetric == metric ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(selectedMetric.title) · \(axisUnit)")
                    .font(MenuTypography.metricLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                if selectedMetric == .value, let currency = days.compactMap(\.currency).first {
                    Text(currency.rawValue)
                        .font(MenuTypography.footerNumber)
                        .foregroundStyle(.secondary)
                }
                if selectedMetric == .value, days.contains(where: \.valueIsPartial) {
                    Text("部分")
                        .font(MenuTypography.footer)
                        .foregroundStyle(.orange)
                }
                if selectedMetric == .speed, days.contains(where: \.speedIsPartial) {
                    Text("部分样本")
                        .font(MenuTypography.footer)
                        .foregroundStyle(.orange)
                }
            }

            let hasValues = selectedPoints.contains(where: { $0 != nil })
            HStack(alignment: .top, spacing: 4) {
                if hasValues {
                    axisLabels
                } else {
                    Color.clear.frame(width: 38, height: 72)
                }
                VStack(spacing: 3) {
                    if hasValues {
                        plot
                    } else {
                        Text(unavailableMetricText)
                            .font(MenuTypography.hint)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                    }
                    dateLabels
                }
            }
        }
    }

    private var axisLabels: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(axisText(selectedMaximum))
            Spacer(minLength: 0)
            Text(axisText(selectedMaximum / 2))
            Spacer(minLength: 0)
            Text(selectedMetric.isRate ? "0%" : "0")
        }
        .font(MenuTypography.badge)
        .foregroundStyle(.tertiary)
        .frame(width: 38, height: 72)
    }

    private var plot: some View {
        GeometryReader { geometry in
            let points = chartPoints(in: geometry.size)
            ZStack {
                Path { path in
                    for y in [CGFloat(3), geometry.size.height / 2, geometry.size.height - 1] {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                }
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)

                path(for: points)
                    .stroke(lineColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    if let point {
                        Circle()
                            .fill(lineColor)
                            .frame(width: 6, height: 6)
                            .position(point)
                            .accessibilityLabel(pointAccessibility(at: index))
                            .help(pointAccessibility(at: index))
                    }
                }
            }
        }
        .frame(height: 72)
    }

    /// Date labels occupy exactly the plot width. Their centers use the same seven-slot
    /// coordinates as the points, leaving half a slot at each edge for the marker radius.
    private var dateLabels: some View {
        HStack(spacing: 0) {
            ForEach(days) { day in
                Text(Calendar.current.isDateInToday(day.dayStart) ? "今天*" : Formatters.formatMonthDay(day.dayStart))
                    .font(MenuTypography.footer)
                    .foregroundStyle(day.isTodayIncomplete ? .primary : .tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var dailyTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                header("日期", width: 34, alignment: .leading)
                header("R/T", width: 54)
                header("Input", width: 46)
                header("Cache", width: 46)
                header("Reason", width: 46)
                header("Output", width: 46)
                selectedDynamicHeader
            }

            ForEach(days) { day in
                GridRow {
                    Text(Formatters.formatMonthDay(day.dayStart))
                        .font(MenuTypography.metricValue)
                        .foregroundStyle(day.isTodayIncomplete ? .primary : .secondary)
                        .frame(width: 34, alignment: .leading)
                    Text(roundsTurns(day))
                        .font(MenuTypography.metricValue)
                        .foregroundStyle(day.rounds != nil || day.turns != nil ? .primary : .secondary)
                        .frame(width: 54, alignment: .trailing)
                    token(day.input, color: .tokenInputTint, width: 46)
                    token(day.cache, color: .tokenCacheReadTint, width: 46)
                    token(day.reason, color: Color(red: 0.90, green: 0.46, blue: 0.16), width: 46)
                    token(day.output, color: .tokenOutputTint, width: 46)
                    selectedDynamicCell(day, width: 58)
                }
            }
        }
    }

    @ViewBuilder
    private var selectedDynamicHeader: some View {
        switch selectedMetric {
        case .total:
            header("总量", width: 58).help("每日四桶 Token 合计")
        case .rounds:
            header("Rounds", width: 58).help("每日模型调用次数")
        case .value:
            header("价值", width: 58).help("每日预估消耗金额")
        case .thinking:
            header("思考", width: 58).help("思考占比 = Reason / (Output + Reason)")
        case .outputRatio:
            header("产出", width: 58).help("产出比 = (Output + Reason) / (Input + Cache)")
        case .hit:
            header("命中", width: 58).help("Cache 命中率 = Cache / (Input + Cache)")
        case .speed:
            header("速度", width: 58).help("每日 Prompt 速度 P50，tok/s")
        }
    }

    @ViewBuilder
    private func selectedDynamicCell(_ day: UsageHistoryDay, width: CGFloat = 58) -> some View {
        switch selectedMetric {
        case .total:
            token(day.total, color: .tokenOutputTint, width: width)
        case .rounds:
            Text(UsageHistoryNumber.integer(day.rounds).map(Formatters.formatGroupedInt) ?? "—")
                .font(MenuTypography.metricValue)
                .foregroundStyle(day.rounds != nil ? Color.purple : Color.secondary)
                .frame(width: width, alignment: .trailing)
        case .value:
            selectedValue(day, width: width)
        case .thinking:
            rate(day.thinkingShare, digits: 0, color: Color(red: 0.90, green: 0.46, blue: 0.16), width: width)
        case .outputRatio:
            outputRate(day.outputToInputRate, color: .tokenInputTint, width: width)
        case .hit:
            rate(day.hitRate, digits: 1, color: .tokenCacheReadTint, width: width)
        case .speed:
            selectedSpeed(day, width: width)
        }
    }

    private func roundsTurns(_ day: UsageHistoryDay) -> String {
        let roundsText = UsageHistoryNumber.integer(day.rounds).map(Formatters.formatGroupedInt)
        let turnsText = UsageHistoryNumber.integer(day.turns).map(Formatters.formatGroupedInt)
        if let roundsText, let turnsText {
            return "\(roundsText)/\(turnsText)"
        }
        return roundsText ?? turnsText ?? "—"
    }

    private var axisUnit: String {
        switch selectedMetric {
        case .total: "tokens"
        case .rounds: "rounds"
        case .value: "金额"
        case .speed: "tok/s"
        case .hit, .thinking, .outputRatio: "%"
        }
    }

    private var unavailableMetricText: String {
        switch selectedMetric {
        case .value: "暂无可计价数据"
        case .speed: "暂无有效 Prompt 时长"
        case .hit, .outputRatio: "暂无输入数据"
        case .thinking: "暂无输出数据"
        default: "暂无该指标的历史数据"
        }
    }

    private func axisText(_ value: Double) -> String {
        switch selectedMetric {
        case .total, .rounds:
            return UsageHistoryNumber.integer(value).map(Formatters.formatTokenCountCompact) ?? "—"
        case .value:
            guard let currency = days.compactMap(\.currency).first else { return String(format: "%.2g", value) }
            return "\(currency.symbol)\(String(format: "%.2g", value))"
        case .speed:
            return Formatters.formatSpeed(value)
        case .hit, .thinking:
            return Formatters.formatPercent(value, digits: 0)
        case .outputRatio:
            return QuotaWindowUsageSection.outputInputRateText(value)
        }
    }

    private func header(_ title: String, width: CGFloat, alignment: Alignment = .trailing) -> some View {
        Text(title)
            .font(MenuTypography.dataLabel)
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }

    private func rate(_ value: Double?, digits: Int, color: Color, width: CGFloat) -> some View {
        Text(value.map { Formatters.formatPercent($0, digits: digits) } ?? "—")
            .font(MenuTypography.metricValue)
            .foregroundStyle(value == nil ? Color.secondary : color)
            .frame(width: width, alignment: .trailing)
    }

    private func outputRate(_ value: Double?, color: Color, width: CGFloat) -> some View {
        Text(value.map(QuotaWindowUsageSection.outputInputRateText) ?? "—")
            .font(MenuTypography.metricValue)
            .foregroundStyle(value == nil ? Color.secondary : color)
            .frame(width: width, alignment: .trailing)
    }

    private func token(_ value: Double?, color: Color, width: CGFloat = 58) -> some View {
        Text(UsageHistoryNumber.integer(value).map(Formatters.formatTokenCountCompact) ?? "—")
            .font(MenuTypography.metricValue)
            .foregroundStyle(UsageHistoryNumber.finiteNonnegative(value) == nil ? Color.secondary : color)
            .frame(width: width, alignment: .trailing)
    }

    private func selectedValue(_ day: UsageHistoryDay, width: CGFloat = 58) -> some View {
        Text(UsageHistoryNumber.finiteNonnegative(day.value).flatMap { value in
            day.currency.map { "\($0.symbol)\(String(format: "%.2f", value))" }
        } ?? "—")
            .font(MenuTypography.metricValue)
            .foregroundStyle(day.valueIsPartial ? Color.orange : Color.secondary)
            .frame(width: width, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .help(day.valueIsPartial ? "部分计价或样本被截断" : "")
    }

    private func selectedSpeed(_ day: UsageHistoryDay, width: CGFloat = 58) -> some View {
        Text(Formatters.formatSpeed(day.speed))
            .font(MenuTypography.metricValue)
            .foregroundStyle(day.speedIsPartial ? Color.orange : Color.secondary)
            .frame(width: width, alignment: .trailing)
            .help(day.speedIsPartial ? "部分样本：有 Prompt 缺少有效时长，或本地样本被截断；P50 仅统计完整 Prompt" : "")
    }

    private func chartPoints(in size: CGSize) -> [CGPoint?] {
        let available = selectedPoints
        let maximum = selectedMaximum
        let slots = max(available.count, 1)
        return available.enumerated().map { index, value in
            guard let value else { return nil }
            // A center for each fixed slot keeps dots aligned with dates and leaves
            // enough inset for a 6pt point at both ends of the plot.
            let x = size.width * (CGFloat(index) + 0.5) / CGFloat(slots)
            let y = size.height - CGFloat(value / maximum) * (size.height - 7) - 3
            return CGPoint(x: x, y: y)
        }
    }

    private func path(for points: [CGPoint?]) -> Path {
        var path = Path()
        var hasOpenSegment = false
        for point in points {
            guard let point else {
                hasOpenSegment = false
                continue
            }
            if hasOpenSegment {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                hasOpenSegment = true
            }
        }
        return path
    }

    private func pointAccessibility(at index: Int) -> String {
        guard days.indices.contains(index),
              let value = UsageHistoryNumber.finiteNonnegative(days[index].value(for: selectedMetric)) else { return "" }
        let partial = selectedMetric == .value && days[index].valueIsPartial
        let speedPartial = selectedMetric == .speed && days[index].speedIsPartial
        let amount = axisText(value)
        let note = partial
            ? "，部分估算"
            : speedPartial ? "，部分样本：缺少有效时长或样本截断" : ""
        return "\(Formatters.formatMonthDay(days[index].dayStart))，\(selectedMetric.title)：\(amount)\(note)"
    }
}
