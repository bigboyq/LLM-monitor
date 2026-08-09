import Foundation

/// 数字 / 时间格式化工具 — 全部 pure function，方便测试
enum Formatters {
    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private let groupedInteger: NumberFormatter
        private var decimalFormatters: [Int: NumberFormatter] = [:]
        private var dateFormatters: [String: DateFormatter] = [:]

        init() {
            groupedInteger = NumberFormatter()
            groupedInteger.numberStyle = .decimal
            groupedInteger.groupingSeparator = ","
            groupedInteger.maximumFractionDigits = 0
        }

        func grouped(_ value: Int) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return groupedInteger.string(from: NSNumber(value: value))
        }

        func decimal(_ value: Double, maximumFractionDigits: Int) -> String? {
            lock.lock()
            defer { lock.unlock() }
            let digits = max(maximumFractionDigits, 0)
            let formatter: NumberFormatter
            if let cached = decimalFormatters[digits] {
                formatter = cached
            } else {
                let created = NumberFormatter()
                created.minimumFractionDigits = 0
                created.maximumFractionDigits = digits
                created.usesGroupingSeparator = false
                created.decimalSeparator = "."
                decimalFormatters[digits] = created
                formatter = created
            }
            return formatter.string(from: NSNumber(value: value))
        }

        func date(_ value: Date, format: String) -> String {
            lock.lock()
            defer { lock.unlock() }
            let formatter: DateFormatter
            if let cached = dateFormatters[format] {
                formatter = cached
            } else {
                let created = DateFormatter()
                created.locale = Locale(identifier: "en_US_POSIX")
                created.calendar = .autoupdatingCurrent
                created.timeZone = .autoupdatingCurrent
                created.dateFormat = format
                dateFormatters[format] = created
                formatter = created
            }
            return formatter.string(from: value)
        }
    }

    private static let formatterCache = FormatterCache()

    // MARK: - Tokens 格式化

    /// 使用最多四位数字的阶梯压缩：3,000 → 3,000；30,000 → 30K；
    /// 3,000,000 → 3,000K；30,000,000 → 30M。
    static func formatTokenCountCompact(_ value: Int) -> String {
        let abs = Swift.abs(value)
        // 单位在当前显示值将超过四位时才升级：10,000 → 10K，
        // 10,000K (10M) → 10M，依此类推。
        if abs >= 10_000_000_000 {
            return "\(formatGroupedInt(value / 1_000_000_000))G"
        }
        if abs >= 10_000_000 {
            return "\(formatGroupedInt(value / 1_000_000))M"
        }
        if abs >= 10_000 {
            return "\(formatGroupedInt(value / 1_000))K"
        }
        return formatGroupedInt(value)
    }

    static func formatGroupedInt(_ value: Int) -> String {
        formatterCache.grouped(value) ?? "\(value)"
    }

    // MARK: - 百分比

    static func formatPercent(_ fraction: Double, digits: Int = 0) -> String {
        let pct = fraction * 100
        return (formatterCache.decimal(pct, maximumFractionDigits: digits) ?? "\(Int(pct))") + "%"
    }

    // MARK: - 相对时间
    //
    // 金额格式化链路暂不保留；未来需要展示余额时再同步增加币种字段。

    /// "5 分钟后" / "2 天 3 小时后" / "刚刚"
    static func formatRelativeShort(from date: Date, now: Date = Date()) -> String {
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
    static func formatResetSuffix(from date: Date, now: Date = Date()) -> String {
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

    /// 时间戳显示 "HH:MM" / "MM-dd HH:MM"
    static func formatClock(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, equalTo: now, toGranularity: .day) {
            return formatterCache.date(date, format: "HH:mm")
        } else {
            return formatterCache.date(date, format: "MM-dd HH:mm")
        }
    }

    /// 紧凑绝对时间，适合菜单内默认摘要
    static func formatMonthDayMinute(_ date: Date) -> String {
        formatterCache.date(date, format: "MM-dd HH:mm")
    }

    /// 月日标签，适合按自然日聚合的图表横轴。
    static func formatMonthDay(_ date: Date) -> String {
        formatterCache.date(date, format: "MM-dd")
    }

    /// 分钟级绝对时间，适合 hover / tooltip 细节
    static func formatYearMonthDayMinute(_ date: Date) -> String {
        formatterCache.date(date, format: "yyyy-MM-dd HH:mm")
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
