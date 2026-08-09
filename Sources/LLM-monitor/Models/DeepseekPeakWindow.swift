import Foundation

/// DeepSeek API 高峰期窗口配置与基于北京时间 (UTC+8) 的倒计时计算。
///
/// 规则：
/// - 适用时段：北京时间 (Asia/Shanghai / UTC+8) 每日 9:00–12:00 以及 14:00–18:00。
/// - 高峰定价：高峰期内价格为平时价格的 2 倍（适用所有计费项）。
/// - 周末平价：`weekdaysOnly` 为 true（默认）时，周六、周日全天按平价（1×）计费，
///   与 GLM 的「仅工作日」开关语义一致。用户可在设置中关闭以恢复「每天执行高峰时段」。
/// - 计算逻辑：判定全程基于北京时间 Calendar，无论用户处于全球何种时区，均可准确换算。
struct DeepseekPeakWindow: Equatable, Sendable, Codable {
    /// 高峰时间段列表（小时半开区间：[start, end)）
    struct Slot: Equatable, Sendable, Codable {
        let startHour: Int
        let endHour: Int
    }

    let slots: [Slot]
    /// `true` = 仅工作日（周一–周五）执行高峰时段，周末全天平价；`false` = 每天
    let weekdaysOnly: Bool

    /// 官方默认定义：每日 9:00–12:00 & 14:00–18:00，默认周末平价（仅工作日）
    static let defaultWindow = DeepseekPeakWindow(
        slots: [
            Slot(startHour: 9, endHour: 12),
            Slot(startHour: 14, endHour: 18)
        ],
        weekdaysOnly: true
    )

    enum Status: Equatable, Sendable {
        /// 当前正处于高峰期，`until` 为本轮高峰结束时刻
        case peak(until: Date)
        /// 当前正处于非高峰期，`until` 为下一轮高峰开始时刻
        case offPeak(until: Date)
    }

    /// 获取北京时间 Calendar（Asia/Shanghai 或 UTC+8 兜底）
    static var beijingCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        return cal
    }

    /// 计算 `now` 时刻对应的高峰期状态。
    func status(at now: Date, calendar: Calendar = DeepseekPeakWindow.beijingCalendar) -> Status {
        let cal = calendar

        // 周末平价：非高峰日（周末且 weekdaysOnly）直接走 offPeak 分支
        guard isPeakDay(now, calendar: cal) else {
            let nextStart = nextPeakStart(after: now, calendar: cal) ?? now
            return .offPeak(until: nextStart)
        }

        // 1. 检查 `now` 是否落在当天的某个高峰 Slot 内
        for slot in slots {
            if let start = cal.date(bySettingHour: slot.startHour, minute: 0, second: 0, of: now),
               let end = cal.date(bySettingHour: slot.endHour, minute: 0, second: 0, of: now),
               now >= start, now < end {
                return .peak(until: end)
            }
        }

        // 2. 当前处于非高峰：寻找从 `now` 往后的下一个高峰 Slot 开始时刻
        let nextStart = nextPeakStart(after: now, calendar: cal) ?? now
        return .offPeak(until: nextStart)
    }

    /// 当前配置下，`date` 所在日是否可能是高峰日（不看具体时辰）。
    /// `weekdaysOnly` 为 false → 每天都是高峰日；否则仅周一–周五。
    private func isPeakDay(_ date: Date, calendar: Calendar) -> Bool {
        guard weekdaysOnly else { return true }
        // Calendar.weekday: 1 = Sunday … 7 = Saturday；周一–周五 = 2…6
        let weekday = calendar.component(.weekday, from: date)
        return (2...6).contains(weekday)
    }

    /// 从 `now` 开始搜索下一个高峰 Slot 的开始时刻
    private func nextPeakStart(after now: Date, calendar: Calendar) -> Date? {
        // 扫描 8 天，覆盖周末（开启周末平价后，周五晚可直接跳到下周一）
        for dayOffset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            guard isPeakDay(day, calendar: calendar) else { continue }
            for slot in slots {
                guard let candidate = calendar.date(bySettingHour: slot.startHour, minute: 0, second: 0, of: day) else { continue }
                if candidate > now {
                    return candidate
                }
            }
        }
        return nil
    }
}
