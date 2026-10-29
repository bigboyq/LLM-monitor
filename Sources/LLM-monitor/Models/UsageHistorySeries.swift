import Foundation

/// The nine independently selectable measures in the seven-day local history.
/// This preference intentionally does not share the quota-window segment key.
enum UsageHistoryMetric: String, CaseIterable, Identifiable {
    case total, rounds, turns, value, speed
    case input, cache, reason, output

    static let storageKey = "usageHistoryMetric"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .total: "总量"
        case .rounds: "Rounds"
        case .turns: "Turns"
        case .value: "价值"
        case .speed: "速度"
        case .input: "Input"
        case .cache: "Cache"
        case .reason: "Reason"
        case .output: "Output"
        }
    }

    var unit: String {
        switch self {
        case .total, .input, .cache, .reason, .output: "Token"
        case .rounds: "Rounds"
        case .turns: "Turns"
        case .value: "价值"
        case .speed: "tok/s"
        }
    }

    static let groups: [[UsageHistoryMetric]] = [
        [.total, .rounds, .turns, .value, .speed],
        [.input, .cache, .reason, .output],
    ]
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
    let input: Double?
    let cache: Double?
    let reason: Double?
    let output: Double?
    let isTodayIncomplete: Bool

    var id: Date { dayStart }

    var hasAnyData: Bool {
        total != nil || rounds != nil || turns != nil || value != nil || speed != nil
            || input != nil || cache != nil || reason != nil || output != nil
    }

    func value(for metric: UsageHistoryMetric) -> Double? {
        switch metric {
        case .total: total
        case .rounds: rounds
        case .turns: turns
        case .value: value
        case .speed: speed
        case .input: input
        case .cache: cache
        case .reason: reason
        case .output: output
        }
    }

}

/// Builds chart values from authoritative daily buckets plus sample-derived
/// estimates. Cache-write is deliberately absent from Total.
enum UsageHistorySeriesBuilder {
    static func build<Daily: LocalUsageDaily>(
        days: [Daily],
        costByDay: [Date: ModelCostEstimate],
        speedByDay: [Date: PromptSpeedStatistics],
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
                    || (speedStats.map { $0.validPromptCount < $0.totalPromptCount } ?? false),
                input: daily.map { Double(max($0.input, 0)) },
                cache: daily.map { Double(max($0.cacheRead, 0)) },
                reason: daily.map { Double(max($0.reasoning, 0)) },
                output: daily.map { Double(max($0.output, 0)) },
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
