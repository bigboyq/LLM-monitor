import Foundation

/// 本地自然日 day key (`yyyy-MM-dd`)，3 个 SQLite scanner (antigravity / minimax / opencode)
/// 共享 —— codex 用 `DailyTokenUsage.dayStart: Date` 不需要 yyyy-MM-dd 字符串。
/// 保证 Swift 端和 SQLite 端用同一种时区（`en_US_POSIX` + `current` TZ + Gregorian
/// 日历），避免跨夜边界 / 时区漂移 bug。
enum LocalUsageDayKey {
    /// Date → "yyyy-MM-dd"。显式接受 calendar，避免测试/时区切换时偷偷使用
    /// 首次访问时捕获的 `TimeZone.current`。
    static func make(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return ""
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// "yyyy-MM-dd" → Date?（按本地时区，0 点）。失败返回 nil——
    /// 之前的 `parse(_:calendar:)` 失败时返回 `Date()`，会让错误日期静默落到"今天"，
    /// 污染 daily 聚合。调用方需要决定兜底（一般是 skip 而非 silent-today）。
    static func parse(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let parsed = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: parsed)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            return nil
        }
        return calendar.startOfDay(for: parsed)
    }
}
