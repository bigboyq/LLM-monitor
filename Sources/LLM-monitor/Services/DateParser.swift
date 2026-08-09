import Foundation
import CoreFoundation

/// 通用日期解析 — Codex / Antigravity / minimax 都用同一套。
///
/// 真实 schema 各种各样：
/// - ISO8601 带/不带小数秒："2026-07-18T00:47:58.918242Z" / "2026-07-18T00:47:58Z"
/// - 整数 / 浮点 unix timestamp（`Int` / `Double` / `NSNumber`）
/// - 数字字符串："1783234800000" / "1234567890"
///
/// `parse(_:)` 自动判断单位（> `1_000_000_000_000` 视为毫秒），`parseMsTimestamp(_:)`
/// 强制毫秒（`minimax` 的所有时间字段都是毫秒，旧 `parseMsTimestamp` 一直按毫秒处理，
/// 切到 `parse` 会让小毫秒值被误读为秒，所以单独留接口）。
enum DateParser {
    /// Foundation formatter 是引用类型；把共享实例和锁封装在一个明确
    /// `@unchecked Sendable` 的容器中，避免每解析一条 JSONL 都重新构造 formatter。
    private final class ISO8601Parser: @unchecked Sendable {
        private let lock = NSLock()
        private let fractional: ISO8601DateFormatter
        private let plain: ISO8601DateFormatter

        init() {
            fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
        }

        func parse(_ value: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return fractional.date(from: value) ?? plain.date(from: value)
        }
    }

    private static let iso8601Parser = ISO8601Parser()
    private static let maximumUnixSeconds = 253_402_300_799.0 // 9999-12-31T23:59:59Z
    private static let minimumUnixSeconds = -62_135_596_800.0 // 0001-01-01T00:00:00Z

    /// Any → Date?。
    /// - String：先尝试 ISO8601（带/不带小数秒），再尝试 `Double(s)` 自动判断单位。
    /// - 数字（`Int` / `Double` / `NSNumber`）：> `1_000_000_000_000` 视为毫秒，否则秒。
    /// 失败返回 nil，调用方决定兜底。
    static func parse(_ raw: Any?) -> Date? {
        switch raw {
        case let s as String:           return parseString(s)
        case let n as NSNumber:
            guard !isBoolean(n) else { return nil }
            return parseNumberAutoUnit(n.doubleValue)
        case let d as Double:           return parseNumberAutoUnit(d)
        case let i as Int:              return parseNumberAutoUnit(Double(i))
        default:                        return nil
        }
    }

    /// 毫秒时间戳专用。`minimax` 的所有时间字段都是毫秒，单位固定。
    /// 跟 `parse` 的关键区别：
    /// - 数字部分**始终**按毫秒处理（不被 `1_000_000_000_000` 阈值误读）
    /// - String 支持 `Double(s) → 毫秒`（旧 `MinimaxTokenPlanFetcher.parseMsTimestamp` 行为）
    /// 失败返回 nil。
    static func parseMsTimestamp(_ raw: Any?) -> Date? {
        switch raw {
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // 1. 数字字符串直接当 ms（minimax 旧行为）
            if let ms = Double(trimmed) {
                return makeDate(seconds: ms / 1000.0)
            }
            // 2. 否则按 ISO8601 解析
            let normalized = trimmed.replacingOccurrences(of: "Z", with: "+00:00")
            return iso8601Parser.parse(normalized)
        case let n as NSNumber:
            guard !isBoolean(n) else { return nil }
            return makeDate(seconds: n.doubleValue / 1000.0)
        case let d as Double:
            return makeDate(seconds: d / 1000.0)
        case let i as Int:
            return makeDate(seconds: Double(i) / 1000.0)
        default:
            return nil
        }
    }

    private static func parseString(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: "Z", with: "+00:00")
        if let date = iso8601Parser.parse(normalized) { return date }
        // 数字字符串和数值走同一套单位判断，避免毫秒字符串被当成 unix 秒。
        if let value = Double(trimmed) {
            return parseNumberAutoUnit(value)
        }
        return nil
    }

    /// 绝对值超过 `1_000_000_000_000` 的 epoch 数按现代毫秒时间戳处理。
    private static func parseNumberAutoUnit(_ value: Double) -> Date? {
        let seconds = abs(value) > 1_000_000_000_000 ? value / 1000.0 : value
        return makeDate(seconds: seconds)
    }

    private static func makeDate(seconds: Double) -> Date? {
        guard seconds.isFinite,
              seconds >= minimumUnixSeconds,
              seconds <= maximumUnixSeconds else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    /// JSONSerialization bridges both numbers and booleans to NSNumber; use the
    /// CoreFoundation type ID when strict numeric validation is required.
    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
