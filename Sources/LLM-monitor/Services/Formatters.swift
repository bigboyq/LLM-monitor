import Foundation

/// 数字 / 时间格式化工具 — 全部 pure function，方便测试
enum Formatters {
    final class FormatterCache: @unchecked Sendable {
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

    static let formatterCache = FormatterCache()

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

    /// 统一的额度剩余百分比格式化：至多一位小数，计算结果是整数则显示整数（绝不带 .0）。
    /// 用于主面板、hover、通知文案、日志摘要等，避免产生视觉抖动。
    /// - Parameter value: 已乘 100 的百分比（如 `80.0` 表示 80%），不是 0-1 的小数。
    static func formatQuotaPercent(_ value: Double) -> String {
        let formatted = String(format: "%.1f%%", value)
        if formatted.hasSuffix(".0%") {
            let intStr = String(format: "%.0f%%", value)
            return intStr == "-0%" ? "0%" : intStr
        }
        return formatted == "-0.0%" ? "0%" : formatted
    }
}
