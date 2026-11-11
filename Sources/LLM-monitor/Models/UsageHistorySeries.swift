import Foundation

/// The eight independently selectable measures in the seven-day local history.
/// This preference intentionally does not share the quota-window segment key.
enum UsageHistoryMetric: String, CaseIterable, Identifiable {
    case total, rounds, value, thinking, outputRatio, hit, ttft, speed

    static let storageKey = "usageHistoryMetric"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .total: "总量"
        case .rounds: "Rounds"
        case .value: "价值"
        case .thinking: "思考"
        case .outputRatio: "产出"
        case .hit: "命中"
        case .ttft: "TTFT"
        case .speed: "速度"
        }
    }

    var unit: String {
        switch self {
        case .total: "Token"
        case .rounds: "Rounds"
        case .value: "价值"
        case .ttft: "s"
        case .speed: "tok/s"
        case .hit, .thinking, .outputRatio: "%"
        }
    }

    var isRate: Bool {
        switch self {
        case .hit, .thinking, .outputRatio: true
        default: false
        }
    }

    /// Hit and thinking are shares by definition; output-to-input can exceed 100%.
    var isBoundedRate: Bool {
        self == .hit || self == .thinking
    }

    static let groups: [[UsageHistoryMetric]] = [
        [.total, .rounds, .value, .thinking, .outputRatio, .hit, .ttft, .speed]
    ]
}

/// The shared min/max scale and labels for rate charts. Values are fractions; labels
/// are percentages. Keeping this arithmetic outside SwiftUI makes the scale auditable.
enum UsageHistoryRateAxis {
    static func bounds(for metric: UsageHistoryMetric, values: [Double]) -> ClosedRange<Double> {
        let finiteValues = values.filter { $0.isFinite && $0 >= 0 }
        guard let minimum = finiteValues.min(), let maximum = finiteValues.max() else {
            return 0...1
        }

        let cappedMaximum = metric.isBoundedRate ? min(maximum, 1) : maximum
        let cappedMinimum = metric.isBoundedRate ? min(minimum, 1) : minimum
        if cappedMinimum == cappedMaximum {
            if metric.isBoundedRate, cappedMaximum == 1 {
                return 0.8...1
            }
            let lower = max(0, cappedMinimum * 0.8)
            let expandedUpper = cappedMaximum == 0 ? 1 : cappedMaximum * 1.2
            let upper = metric.isBoundedRate ? min(expandedUpper, 1) : expandedUpper
            return lower...max(lower.nextUp, upper)
        }
        return cappedMinimum...cappedMaximum
    }

    static func label(_ value: Double, bounds: ClosedRange<Double>) -> String {
        let spanInPercentagePoints = (bounds.upperBound - bounds.lowerBound) * 100
        let decimalPlaces = min(max(Int(ceil(-log10(max(spanInPercentagePoints / 2, 0.000001)))), 0), 6)
        return String(format: "%.*f%%", decimalPlaces, value * 100)
    }
}

enum UsageHistoryNumber {
    static func finiteNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func integer(_ value: Double?) -> Int? {
        guard let value = finiteNonnegative(value) else { return nil }
        // Double(Int.max) rounds up to 2^63 on 64-bit systems. Clamp before
        // conversion so the saturating accounting boundary cannot trap.
        if value >= Double(Int.max) { return Int.max }
        return Int(value)
    }
}

/// Numeric and provenance-bearing daily values for the history chart.
/// Missing data stays nil so the chart can render a real gap; a present daily row
/// with zero tokens remains a plotted zero.
struct UsageHistoryDay: Equatable, Identifiable {
    let dayStart: Date
    let total: Double?
    let rounds: Double?
    let turns: Double?
    let value: Double?
    let currency: ModelPriceCurrency?
    let valueIsPartial: Bool
    let speed: Double?
    let speedIsPartial: Bool
    /// 每日调用级首字延迟 P50（秒）；nil = 当日没有 TTFT 有效的样本（图表断线）。
    let ttft: Double?
    let input: Double?
    let cache: Double?
    let reason: Double?
    let output: Double?
    let hitRate: Double?
    let thinkingShare: Double?
    let outputToInputRate: Double?
    let isTodayIncomplete: Bool

    var id: Date { dayStart }

    var hasAnyData: Bool {
        total != nil || rounds != nil || value != nil || speed != nil || ttft != nil
            || hitRate != nil || thinkingShare != nil || outputToInputRate != nil
            || input != nil || cache != nil || reason != nil || output != nil || turns != nil
    }

    func value(for metric: UsageHistoryMetric) -> Double? {
        switch metric {
        case .total: total
        case .rounds: rounds
        case .value: value
        case .speed: speed
        case .ttft: ttft
        case .hit: hitRate
        case .thinking: thinkingShare
        case .outputRatio: outputToInputRate
        }
    }

}

/// Builds chart values from authoritative daily buckets plus sample-derived
/// estimates. Cache-write is deliberately absent from Total.
enum UsageHistorySeriesBuilder {
    static func build<Daily: LocalUsageDaily>(
        days: [Daily],
        costByDay: [Date: ModelCostEstimate],
        speedByDay: [Date: CallSpeedStatistics],
        ttftByDay: [Date: CallTTFTStatistics] = [:],
        samplesTruncated: Bool,
        isTruncated: Bool = false,
        partialCostDays: Set<Date> = [],
        calendar: Calendar = .current,
        now: Date = .now
    ) -> [UsageHistoryDay] {
        let today = calendar.startOfDay(for: now)
        let partialCostStarts = Set(partialCostDays.map { calendar.startOfDay(for: $0) })
        let dailyByStart = Dictionary(grouping: days) {
            calendar.startOfDay(for: $0.dayStart)
        }
        let visibleDays = (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset - 6, to: today)
        }
        let normalizedCosts = normalizedCostsByDay(
            costByDay,
            visibleDayStarts: Set(visibleDays),
            calendar: calendar
        )
        return visibleDays.map { dayStart in
            let daily = dailyByStart[dayStart]?.first
            let sourceCost = normalizedCosts[dayStart]
            let costValue = UsageHistoryNumber.finiteNonnegative(sourceCost?.value)
            let cost = sourceCost.map {
                ModelCostEstimate(
                    value: costValue,
                    currency: costValue == nil ? nil : $0.currency,
                    pricedModelNames: $0.pricedModelNames,
                    unpricedModelNames: $0.unpricedModelNames
                )
            }
            let speedStats = speedByDay[dayStart]
            let costPartial: Bool
            if partialCostStarts.contains(dayStart) {
                costPartial = true
            } else if let cost, case .partiallyPriced = cost.coverage {
                costPartial = true
            } else {
                costPartial = samplesTruncated || isTruncated
            }

            let inputTokens = daily.map { Double(max($0.input, 0)) }
            let cacheTokens = daily.map { Double(max($0.cacheRead, 0)) }
            let reasonTokens = daily.map { Double(max($0.reasoning, 0)) }
            let outputTokens = daily.map { Double(max($0.output, 0)) }

            let inputSide = (inputTokens ?? 0) + (cacheTokens ?? 0)
            let outputSide = (reasonTokens ?? 0) + (outputTokens ?? 0)

            let hitRate: Double? = (daily != nil && inputSide > 0) ? ((cacheTokens ?? 0) / inputSide) : nil
            let thinkingShare: Double? = (daily != nil && outputSide > 0) ? ((reasonTokens ?? 0) / outputSide) : nil
            let outputToInputRate: Double? = (daily != nil && inputSide > 0) ? (outputSide / inputSide) : nil

            return UsageHistoryDay(
                dayStart: dayStart,
                total: daily.map { Double($0.totalTokens) },
                rounds: daily.map { Double(max($0.rounds, 0)) },
                turns: daily.map { Double(max($0.turns, 0)) },
                value: cost?.value,
                currency: cost?.currency,
                valueIsPartial: costPartial,
                speed: UsageHistoryNumber.finiteNonnegative(speedStats?.p50),
                speedIsPartial: samplesTruncated || isTruncated
                    || (speedStats.map { $0.validCallCount < $0.totalCallCount } ?? false),
                ttft: UsageHistoryNumber.finiteNonnegative(ttftByDay[dayStart]?.p50),
                input: inputTokens,
                cache: cacheTokens,
                reason: reasonTokens,
                output: outputTokens,
                hitRate: hitRate,
                thinkingShare: thinkingShare,
                outputToInputRate: outputToInputRate,
                isTodayIncomplete: dayStart == today
            )
        }
    }

    private static func normalizedCostsByDay(
        _ costs: [Date: ModelCostEstimate],
        visibleDayStarts: Set<Date>,
        calendar: Calendar
    ) -> [Date: ModelCostEstimate] {
        let normalized = costs.reduce(into: [Date: ModelCostEstimate]()) { result, entry in
            let dayStart = calendar.startOfDay(for: entry.key)
            if visibleDayStarts.contains(dayStart) {
                result[dayStart] = entry.value
            }
        }
        let currencies = Set(normalized.values.compactMap(\.currency))
        guard currencies.count > 1 else {
            return normalized
        }
        return normalized.mapValues { estimate in
            guard let amount = estimate.value, let currency = estimate.currency else {
                return estimate
            }
            let cnyValue: Double
            switch currency {
            case .cny: cnyValue = amount
            case .usd: cnyValue = amount * NSDecimalNumber(decimal: MixedCurrencyEstimate.usdToCNYRate).doubleValue
            }
            return ModelCostEstimate(
                value: cnyValue,
                currency: .cny,
                pricedModelNames: estimate.pricedModelNames,
                unpricedModelNames: estimate.unpricedModelNames
            )
        }
    }
}
