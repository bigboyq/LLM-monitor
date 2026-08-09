import Foundation

/// GLM Coding Plan 高峰期窗口配置 + 时间判定。
///
/// 智谱官方规则（默认）：**每周一至周五 14:00–18:00**（按用户本地时区）为高峰时段，
/// 高峰期模型调用按基础积分消耗，非高峰期按 50% 抵扣（省一半）。窗口可配置，
/// 便于官方规则调整或用户自定义。
///
/// 判定全程基于传入 `Calendar`（默认 `Calendar.current`，即用户本地时区），
/// 不依赖 GLM API 返回 —— 高峰提示是纯本地时间计算，refresh 失败也能正常显示。
struct GlmPeakWindow: Equatable, Sendable, Codable {
    /// 高峰开始小时（24h 制，0–23）
    let startHour: Int
    /// 高峰结束小时（24h 制，半开区间，必须 > `startHour`）
    let endHour: Int
    /// `true` = 仅工作日（周一–周五）；`false` = 每天
    let weekdaysOnly: Bool

    /// 智谱官方默认：Mon–Fri 14:00–18:00
    static let zhipuDefault = GlmPeakWindow(startHour: 14, endHour: 18, weekdaysOnly: true)

    enum Status: Equatable, Sendable {
        /// 当前处于高峰期，`until` 为本轮结束时刻
        case peak(until: Date)
        /// 当前处于非高峰期，`until` 为下一次高峰开始时刻
        case offPeak(until: Date)
    }

    /// 判定 `now` 所处的高峰状态。
    func status(at now: Date, calendar: Calendar = .current) -> Status {
        let cal = calendar
        // 当前正在高峰期内：peak day 且 now ∈ [startHour:00, endHour:00)
        if isPeakDay(now, calendar: cal),
           let start = cal.date(bySettingHour: startHour, minute: 0, second: 0, of: now),
           let end = cal.date(bySettingHour: endHour, minute: 0, second: 0, of: now),
           now >= start, now < end {
            return .peak(until: end)
        }
        // 否则非高峰：定位下一次高峰开始
        let nextStart = nextPeakStart(after: now, calendar: cal) ?? now
        return .offPeak(until: nextStart)
    }

    /// 当前配置下，`date` 所在日是否可能是高峰日（不看具体时辰）。
    private func isPeakDay(_ date: Date, calendar: Calendar) -> Bool {
        guard weekdaysOnly else { return true }
        // Calendar.weekday: 1 = Sunday … 7 = Saturday；周一–周五 = 2…6
        let weekday = calendar.component(.weekday, from: date)
        return (2...6).contains(weekday)
    }

    /// 从 `now` 起向后找下一个高峰开始时刻。
    /// 同一天若 `startHour:00` 还没到则取今天，否则逐日扫描（最多 7 天，覆盖周末）。
    private func nextPeakStart(after now: Date, calendar: Calendar) -> Date? {
        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            guard isPeakDay(day, calendar: calendar) else { continue }
            guard let candidate = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: day) else { continue }
            if candidate > now {
                return candidate
            }
        }
        return nil
    }
}
