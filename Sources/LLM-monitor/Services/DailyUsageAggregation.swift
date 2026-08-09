import Foundation

/// 两个 SQLite scanner（minimax / antigravity）共享的 per-day 聚合逻辑。
/// codex 使用不同的聚合路径（in-memory LRU），因此不参与。
///
/// 要求泛型参数 `D` 同时满足：
/// - `init(dayStart:)` — 创建空 day（fillMissingDays 补零用）
/// - `static func +` — 跨 source 合并
/// - `dayStart: Date` — 日期键
enum DailyUsageAggregation {
    /// 把 per-source daily 汇总成全局 daily（按 day key 累加）。
    /// 跨 minimax / antigravity 同构。
    static func computeGlobalDaily<D: DailyUsageAddable>(
        from dailyBySource: [String: [String: D]],
        calendar: Calendar
    ) -> [D] {
        var global: [String: D] = [:]
        for (_, byDay) in dailyBySource {
            for (_, usage) in byDay {
                let normalizedDay = calendar.startOfDay(for: usage.dayStart)
                let key = LocalUsageDayKey.make(normalizedDay, calendar: calendar)
                if let existing = global[key] {
                    global[key] = existing + usage
                } else {
                    global[key] = usage
                }
            }
        }
        return global.values.sorted { $0.dayStart < $1.dayStart }
    }

    /// 保留最近 7 个本地自然日（含 today），补齐缺失的日期。
    /// 恒定返回 7 天（按日升序）的数组。
    static func filterLast7Days<D: DailyUsageAddable>(
        allDaily: [D],
        today: Date,
        calendar: Calendar
    ) -> [D] {
        guard !allDaily.isEmpty else { return [] }
        let byDayKey = Dictionary(
            uniqueKeysWithValues: allDaily.map {
                (LocalUsageDayKey.make($0.dayStart, calendar: calendar), $0)
            }
        )
        return (-6...0).compactMap { offset -> D? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let dayStart = calendar.startOfDay(for: day)
            let key = LocalUsageDayKey.make(dayStart, calendar: calendar)
            if let existing = byDayKey[key] {
                return existing.withDayStart(dayStart)
            } else {
                return D(dayStart: dayStart)
            }
        }
    }

    static func todayCutoff(now: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: now)
    }
}

/// Scanner daily usage 类型需要满足的协议，用于 `DailyUsageAggregation` 泛型约束。
protocol DailyUsageAddable: Sendable {
    var dayStart: Date { get }
    init(dayStart: Date)
    static func + (lhs: Self, rhs: Self) -> Self
    /// 返回一份拷贝，dayStart 替换为指定日期。
    /// filterLast7Days 需要确保 dayStart 与本地 calendar.startOfDay 精度完全一致。
    func withDayStart(_ date: Date) -> Self
}
