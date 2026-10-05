import Foundation

/// 高峰期时段窗口配置 + 时间判定（参数化：任意 slots × 任意 Calendar × 任意节假日表）。
///
/// 取代原先平行实现、约 80% 重复的 `GlmPeakWindow`（单窗口）与
/// `DeepseekPeakWindow`（双窗口）；两家的高峰形状已统一（固定窗口 + 北京时间 +
/// Rule A 工作日口径），只差 slots 数量：
/// - GLM：`PeakWindow(startHour: 14, endHour: 18, weekdaysOnly: true)` + 北京时间
///   —— 智谱官方规则：周一至周五 14:00–18:00 高峰按基础积分，其余时段 50% 抵扣
/// - DeepSeek：`PeakWindow(slots: [9–12, 14–18], weekdaysOnly: true)` + 北京时间
///   —— 官方规则：高峰 2× 定价，周末平价
///
/// 判定全程基于传入 `Calendar`（GLM / DeepSeek 调用方都显式传
/// `PeakWindow.beijingCalendar`），不依赖任何 API 返回 —— 高峰提示是纯本地
/// 时间计算，refresh 失败也能正常显示。`weekdaysOnly` 时工作日 = 周一–周五 ∧
/// 非法定节假日（Rule A，见 `HolidayCalendar`）。
struct PeakWindow: Equatable, Sendable, Codable {
    /// 高峰时间段（小时半开区间：[start, end)）
    struct Slot: Equatable, Sendable, Codable {
        let startHour: Int
        let endHour: Int

        init(startHour: Int, endHour: Int) {
            self.startHour = startHour
            self.endHour = endHour
        }
    }

    let slots: [Slot]
    /// `true` = 仅工作日（周一–周五）执行高峰时段；`false` = 每天
    let weekdaysOnly: Bool

    /// 智谱官方默认：Mon–Fri 14:00–18:00（北京时间，与 DeepSeek 判定形状统一）
    static let zhipuDefault = PeakWindow(startHour: 14, endHour: 18, weekdaysOnly: true)

    /// DeepSeek 官方口径：周一至周五 9:00–12:00 & 14:00–18:00（北京时间）为高峰，
    /// 周六、周日全天平价 —— 高峰永不含周末，`weekdaysOnly` 固定为 true 且无
    /// 用户可调开关。
    static let deepseekDefault = PeakWindow(
        slots: [
            Slot(startHour: 9, endHour: 12),
            Slot(startHour: 14, endHour: 18)
        ],
        weekdaysOnly: true
    )

    /// 单窗口便捷构造（GLM 形态）
    init(startHour: Int, endHour: Int, weekdaysOnly: Bool) {
        self.init(slots: [Slot(startHour: startHour, endHour: endHour)], weekdaysOnly: weekdaysOnly)
    }

    init(slots: [Slot], weekdaysOnly: Bool) {
        self.slots = slots
        self.weekdaysOnly = weekdaysOnly
    }

    /// 单窗口（GLM 形态）便捷访问：首个 slot 的边界。多窗口（DeepSeek）语义
    /// 下不应使用。
    var startHour: Int { slots.first?.startHour ?? 0 }
    var endHour: Int { slots.first?.endHour ?? 0 }

    /// 北京时间 Calendar（Asia/Shanghai 或 UTC+8 兜底）。DeepSeek 官方规则
    /// 固定按北京时间换算，无论用户处于何种时区。
    static var beijingCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        return cal
    }

    enum Status: Equatable, Sendable {
        /// 当前正处于高峰期，`until` 为本轮高峰结束时刻
        case peak(until: Date)
        /// 当前正处于非高峰期，`until` 为下一轮高峰开始时刻
        case offPeak(until: Date)
    }

    /// 计算 `now` 时刻对应的高峰期状态。
    /// `holidays` 默认取 `HolidayCalendar.shared`（打包快照），既有多数调用点
    /// 零改动即生效；测试可注入 fixture 实例。
    func status(
        at now: Date,
        calendar: Calendar = .current,
        holidays: HolidayCalendar = HolidayCalendar.shared
    ) -> Status {
        let cal = calendar

        // 非高峰日（周末/法定节假日 且 weekdaysOnly）直接走 offPeak 分支
        guard isPeakDay(now, calendar: cal, holidays: holidays) else {
            let nextStart = nextPeakStart(after: now, calendar: cal, holidays: holidays) ?? now
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
        let nextStart = nextPeakStart(after: now, calendar: cal, holidays: holidays) ?? now
        return .offPeak(until: nextStart)
    }

    /// 当前配置下，`date` 所在日是否可能是高峰日（不看具体时辰）。
    /// `weekdaysOnly` 为 false → 每天都是高峰日；否则周一–周五 ∧ 非法定节假日
    /// （Rule A：调休上班的周六/周日本来就不满足"周一–周五"，天然不算高峰，
    /// 无需例外规则；调休放假日落在周一–周五，由 `HolidayCalendar` 排除）。
    private func isPeakDay(_ date: Date, calendar: Calendar, holidays: HolidayCalendar) -> Bool {
        guard weekdaysOnly else { return true }
        // Calendar.weekday: 1 = Sunday … 7 = Saturday；周一–周五 = 2…6
        guard (2...6).contains(calendar.component(.weekday, from: date)) else { return false }
        return !holidays.isHoliday(date, calendar: calendar)
    }

    /// 从 `now` 开始搜索下一个高峰 Slot 的开始时刻。无命中返回 nil。
    ///
    /// 扫描 15 天：`weekdaysOnly` 时最长连续非高峰日 ≈ 春节法定假 8 天 + 首尾
    /// 紧邻周末最多再顺延 2–3 天（假期起点/终点落在周五或周六时与周末连成一片）
    /// ≈ 11 天（调休上班的周末按 Rule A 不算高峰，只会拉长空档）。旧值 8 天
    /// 只够覆盖普通周末，节假日口径下会漏扫；15 天留足余量。
    private func nextPeakStart(after now: Date, calendar: Calendar, holidays: HolidayCalendar) -> Date? {
        for dayOffset in 0..<15 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            guard isPeakDay(day, calendar: calendar, holidays: holidays) else { continue }
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

// MARK: - 历史类型名（保留原名，调用方与测试零改动）

typealias GlmPeakWindow = PeakWindow
typealias DeepseekPeakWindow = PeakWindow

extension PeakWindow {
    /// DeepSeek 默认窗口的历史别名。
    static var defaultWindow: PeakWindow { .deepseekDefault }
}
