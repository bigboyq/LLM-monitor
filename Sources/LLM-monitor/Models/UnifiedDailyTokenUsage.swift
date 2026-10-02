import Foundation

/// Provider-neutral daily token data used by the card and settings UI.
/// Scanner-specific daily structs are converted here before they reach views.
struct UnifiedDailyTokenUsage: Equatable, Codable, Sendable, Identifiable, LocalUsageDaily {
    let dayStart: Date
    let input: Int
    let cacheRead: Int
    let cacheWrite: Int
    let output: Int
    let reasoning: Int
    let turns: Int
    let rounds: Int

    var id: Date { dayStart }

    init<Daily: LocalUsageDaily>(_ day: Daily) {
        self.dayStart = day.dayStart
        self.input = day.input
        self.cacheRead = day.cacheRead
        self.cacheWrite = day.cacheWrite
        self.output = day.output
        self.reasoning = day.reasoning
        self.turns = day.turns
        self.rounds = day.rounds
    }

    init(
        dayStart: Date,
        input: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        turns: Int = 0,
        rounds: Int = 0
    ) {
        self.dayStart = dayStart
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
        self.reasoning = reasoning
        self.turns = turns
        self.rounds = rounds
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            dayStart: lhs.dayStart,
            input: SaturatingArithmetic.add(lhs.input, rhs.input),
            cacheRead: SaturatingArithmetic.add(lhs.cacheRead, rhs.cacheRead),
            cacheWrite: SaturatingArithmetic.add(lhs.cacheWrite, rhs.cacheWrite),
            output: SaturatingArithmetic.add(lhs.output, rhs.output),
            reasoning: SaturatingArithmetic.add(lhs.reasoning, rhs.reasoning),
            turns: SaturatingArithmetic.add(lhs.turns, rhs.turns),
            rounds: SaturatingArithmetic.add(lhs.rounds, rhs.rounds)
        )
    }
}

/// Keep the current day complete when a scanner's persisted daily aggregate is
/// one scan behind its per-request samples. This can happen while a local DB
/// is being written: the sample is already visible, but the cached daily row
/// has not been rebuilt yet.
enum UnifiedDailyUsageNormalizer {
    static func includingCurrentDay(
        dailyTokenUsage: [UnifiedDailyTokenUsage],
        samples: [LocalTokenUsageSample],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [UnifiedDailyTokenUsage] {
        guard samples.isEmpty == false else { return dailyTokenUsage }

        let todayStart = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            return dailyTokenUsage
        }
        let todaySamples = samples.filter {
            $0.completedAt >= todayStart && $0.completedAt < tomorrow
        }
        guard todaySamples.isEmpty == false else {
            return dailyTokenUsage
        }

        let sampleToday = UnifiedTokenUsageAggregator.day(
            from: todaySamples,
            dayStart: todayStart,
            calendar: calendar
        )

        var byDay = Dictionary(
            uniqueKeysWithValues: normalized(dailyTokenUsage, calendar: calendar).map {
                ($0.dayStart, $0)
            }
        )
        if let existing = byDay[todayStart] {
            // Daily data remains authoritative for values it already contains;
            // max() fills a stale current-day row without double-counting the
            // same samples when both sources contain the same requests.
            byDay[todayStart] = UnifiedDailyTokenUsage(
                dayStart: todayStart,
                input: max(existing.input, sampleToday.input),
                cacheRead: max(existing.cacheRead, sampleToday.cacheRead),
                cacheWrite: existing.cacheWrite,
                output: max(existing.output, sampleToday.output),
                reasoning: max(existing.reasoning, sampleToday.reasoning),
                turns: max(existing.turns, sampleToday.turns),
                rounds: max(existing.rounds, sampleToday.rounds)
            )
        } else {
            byDay[todayStart] = sampleToday
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    private static func normalized(
        _ dailyTokenUsage: [UnifiedDailyTokenUsage],
        calendar: Calendar
    ) -> [UnifiedDailyTokenUsage] {
        var byDay: [Date: UnifiedDailyTokenUsage] = [:]
        for day in dailyTokenUsage {
            let dayStart = calendar.startOfDay(for: day.dayStart)
            let normalizedDay = UnifiedDailyTokenUsage(
                dayStart: dayStart,
                input: day.input,
                cacheRead: day.cacheRead,
                cacheWrite: day.cacheWrite,
                output: day.output,
                reasoning: day.reasoning,
                turns: day.turns,
                rounds: day.rounds
            )
            byDay[dayStart] = byDay[dayStart].map { $0 + normalizedDay } ?? normalizedDay
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }
}
