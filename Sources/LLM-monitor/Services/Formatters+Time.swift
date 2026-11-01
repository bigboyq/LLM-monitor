import Foundation

extension Formatters {
    // MARK: - 相对时间与倒计时

    /// "5 分钟后" / "2 天 3 小时后" / "刚刚"
    ///
    /// `now` 必填：相对时间的数值由调用方决定——视图层必须传宿主注入的展示时钟
    /// （`\.displayDate`，随宿主显隐起停），不允许渲染时现取墙钟。
    static func formatRelativeShort(from date: Date, now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        if delta <= 0 { return "已过期" }
        return "约 \(formatDuration(delta)) 后"
    }

    /// 紧凑的英文短单位倒计时，专门给 reset time 后面的 () 用。
    /// 阶梯压缩：3d+ 只显示 d；1d+ 显示 d+h；5h+ 只显示 h；1h+ 显示 h+m；否则 m。
    /// 边界 inclusive（>=），避免 1d → "24h"、5h → "5h00m" 这种丢掉单位的尴尬。
    /// - 3d5h       → "3d"
    /// - 2d5h       → "2d5h"
    /// - 1d5h       → "1d5h"
    /// - 5h         → "5h"
    /// - 1h23m      → "1h23m"
    /// - 4h05m      → "4h05m"
    /// - 23m        → "23m"
    /// - 0 / 负数    → "已过期"
    ///
    /// `now` 必填：同 `formatRelativeShort`——倒计时数值取宿主注入的展示时钟，
    /// 不取渲染时的墙钟。
    static func formatResetSuffix(from date: Date, now: Date) -> String {
        let delta = date.timeIntervalSince(now)
        if delta <= 0 { return "已过期" }
        let total = Int(delta)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 2 { return "\(days)d" }
        if days >= 1 { return "\(days)d\(hours)h" }
        if hours >= 5 { return "\(hours)h" }
        if hours >= 1 { return "\(hours)h\(String(format: "%02d", minutes))m" }
        return "\(max(minutes, 1))m"
    }

    /// 紧凑中文倒计时："2天8小时" / "1小时30分" / "1小时" / "30分"。
    /// GLM / DeepSeek 两个高峰提示行共用，避免两份逐字复制后漂移。
    static func formatPeakDuration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return "\(days)天\(hours)小时" }
        if hours > 0 { return minutes > 0 ? "\(hours)小时\(minutes)分" : "\(hours)小时" }
        return "\(max(minutes, 1))分"
    }

    /// 紧凑账单周期剩余中文倒计时："12天8小时后" / "12天后" / "2小时15分后" / "2小时后" / "25分后" / "已到期"。
    static func formatBillingRemainingDuration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "已到期" }
        let total = Int(seconds.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            return hours > 0 ? "\(days)天\(hours)小时后" : "\(days)天后"
        } else if hours > 0 {
            return minutes > 0 ? "\(hours)小时\(minutes)分后" : "\(hours)小时后"
        } else {
            return "\(max(minutes, 1))分后"
        }
    }

    /// 数字时钟时长展示：超过 1 小时为 `h:mm:ss`，否则 `mm:ss`。
    /// 负数与 0 统一下限钳位为 "00:00"。
    static func formatDigitalDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return "\(minutes) 分" }
        return "\(max(total, 1)) 秒"
    }

    // MARK: - 时钟与绝对时间戳

    /// 时间戳显示 "HH:MM" / "MM-dd HH:MM"
    static func formatClock(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, equalTo: now, toGranularity: .day) {
            return formatterCache.date(date, format: "HH:mm")
        } else {
            return formatterCache.date(date, format: "MM-dd HH:mm")
        }
    }

    /// 时钟胶囊专用：恒定 "HH:mm"，**跨天不退化**。Provider 兜底行的宽度预算按
    /// 5 字符胶囊钉死（5 元素 × 54pt，spec/ui/menu-and-cards.md §Provider fallback
    /// strip），`MM-dd HH:mm` 的 11 字符会把整行撑变形——跨天的「哪一天」信息由
    /// 胶囊的新鲜度颜色承担，不靠加宽时间文本。
    static func formatTimeOfDay(_ date: Date) -> String {
        formatterCache.date(date, format: "HH:mm")
    }

    /// 紧凑绝对时间，适合菜单内默认摘要
    static func formatMonthDayMinute(_ date: Date) -> String {
        formatterCache.date(date, format: "MM-dd HH:mm")
    }

    /// 月日标签，适合按自然日聚合的图表横轴。
    static func formatMonthDay(_ date: Date) -> String {
        formatterCache.date(date, format: "MM-dd")
    }

    /// 绝对时间，对齐 codex.py 的 "YYYY-MM-DD HH:MM:SS ±HHMM" 格式
    /// 例如 "2026-07-08 12:00:00 +0800"
    static func formatAbsolute(_ date: Date) -> String {
        formatterCache.date(date, format: "yyyy-MM-dd HH:mm:ss Z")
    }

    // MARK: - Codex 窗口标签

    /// 把 Codex / ChatGPT Plan 的 `limit_window_seconds` 转成可读窗口名：
    /// 7 天 → "周"；3 天 → "3天"；1 小时 → "1小时"；60 秒 → "1分钟"；
    /// `nil` / 0 / 无法整除 → "主额度"。
    static func codexWindowLabel(seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "主额度" }
        if seconds == 7 * 86_400 { return "周" }
        if seconds % 86_400 == 0 { return "\(seconds / 86_400)天" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600)小时" }
        if seconds % 60 == 0 { return "\(seconds / 60)分钟" }
        return "\(seconds)秒"
    }

    // MARK: - 间隔（用于刷新频率显示）

    /// 把秒数格式化成 "10 秒" / "30 秒" / "2 分钟" / "1 小时"。
    /// 之前 SettingsView 用 `max(1, value / 60)` 描述 `< 60s` 的值会得到"约 1 分钟"，
    /// 但实际是 10 / 30 秒，误导用户。
    static func formatInterval(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        if seconds < 3600 {
            let minutes = seconds / 60
            let remainder = seconds % 60
            if remainder == 0 { return "\(minutes) 分钟" }
            return "\(minutes) 分 \(remainder) 秒"
        }
        let hours = seconds / 3600
        let remainderMin = (seconds % 3600) / 60
        if remainderMin == 0 { return "\(hours) 小时" }
        return "\(hours) 小时 \(remainderMin) 分"
    }
}
