import XCTest
import Foundation
@testable import LLM_monitor

/// `Formatters` 的数字 / 百分比 / 时间格式化规则。对应 `Formatters`。
final class FormattersTests: XCTestCase {

    func testSpeedFormattingKeepsThreeCharacterNumericBodyAcrossRoundingBoundaries() {
        let examples: [(Double?, String)] = [
            (nil, "—"), (-1, "—"), (.nan, "—"), (.infinity, "—"),
            (-0.0, "0.0"), (0.04, "0.0"), (8.64, "8.6"), (9.94, "9.9"),
            (9.96, "10"), (50.14, "50"), (99.96, "100"), (245.7, "246"),
            (999.4, "999"), (999.5, "1.0K"), (12_345, "12K"), (999_500, "1.0M"),
        ]
        for (rate, expected) in examples {
            XCTAssertEqual(Formatters.formatSpeed(rate), expected, "rate=\(String(describing: rate))")
        }
    }

    // MARK: - Formatters

    /// 数字格式化 2 in 1：formatTokenCountCompact (K/M) + formatPercent (% / 小数位)
    func testFormattersTokenAndPercent() {
        // formatTokenCountCompact: 999 / 3,000 / 30K / 1,234K / 3,000K / 30M / 1,234M
        XCTAssertEqual(Formatters.formatTokenCountCompact(999), "999")
        XCTAssertEqual(Formatters.formatTokenCountCompact(3_000), "3,000")
        XCTAssertEqual(Formatters.formatTokenCountCompact(30_000), "30K")
        XCTAssertEqual(Formatters.formatTokenCountCompact(1_234_567), "1,234K")
        XCTAssertEqual(Formatters.formatTokenCountCompact(3_000_000), "3,000K")
        XCTAssertEqual(Formatters.formatTokenCountCompact(30_000_000), "30M")
        XCTAssertEqual(Formatters.formatTokenCountCompact(1_234_567_890), "1,234M")
        // formatPercent: 默认整数 / digits=1 一位小数
        XCTAssertEqual(Formatters.formatPercent(0.44), "44%")
        XCTAssertEqual(Formatters.formatPercent(0.6432, digits: 1), "64.3%")
    }

    /// formatQuotaPercent：至多一位小数，计算结果是整数则显示整数（绝不带 .0）。
    /// 取代原本主面板 / hover / 通知 / 日志四处各不相同的舍入语义。
    func testFormattersQuotaPercent() {
        // 整数：直接输出整数
        XCTAssertEqual(Formatters.formatQuotaPercent(92.0), "92%")
        XCTAssertEqual(Formatters.formatQuotaPercent(100.0), "100%")
        XCTAssertEqual(Formatters.formatQuotaPercent(0.0), "0%")
        XCTAssertEqual(Formatters.formatQuotaPercent(80.0), "80%")

        // 整数附近进位与 xx.0% 泄漏防回归：
        XCTAssertEqual(Formatters.formatQuotaPercent(91.95), "92%", "91.95 四舍五入到 92.0 后必须剥离为 92%，不能泄漏 92.0%")
        XCTAssertEqual(Formatters.formatQuotaPercent(92.04), "92%")
        XCTAssertEqual(Formatters.formatQuotaPercent(80.04), "80%")
        XCTAssertEqual(Formatters.formatQuotaPercent(79.96), "80%")
        XCTAssertEqual(Formatters.formatQuotaPercent(0.04), "0%")
        XCTAssertEqual(Formatters.formatQuotaPercent(99.96), "100%", "99.96 四舍五入到 100.0 后必须剥离为 100%")

        // 一位小数：
        XCTAssertEqual(Formatters.formatQuotaPercent(94.3), "94.3%")
        XCTAssertEqual(Formatters.formatQuotaPercent(4.71), "4.7%")
        XCTAssertEqual(Formatters.formatQuotaPercent(80.4), "80.4%")
        XCTAssertEqual(Formatters.formatQuotaPercent(79.6), "79.6%")
        XCTAssertEqual(Formatters.formatQuotaPercent(99.9), "99.9%")
        XCTAssertEqual(Formatters.formatQuotaPercent(33.33), "33.3%")
        XCTAssertEqual(Formatters.formatQuotaPercent(79.5), "79.5%")

        // 数值 > 100：和原行为一致，不做 clamp
        XCTAssertEqual(Formatters.formatQuotaPercent(100.4), "100.4%")

        // 负数与负零防回归：
        XCTAssertEqual(Formatters.formatQuotaPercent(-0.0), "0%")
        XCTAssertEqual(Formatters.formatQuotaPercent(-0.04), "0%")
    }

    /// 时间格式化 2 in 1：formatResetSuffix (5 阶梯压缩) + formatClock (跨日切月日)
    func testFormattersTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // formatResetSuffix 5 阶梯: 3d / 1d5h / 5h / 1h23m / 23m / 已过期
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(3 * 86400), now: now), "3d")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(7 * 86400 + 3600), now: now), "7d")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(1 * 86400 + 5 * 3600), now: now), "1d5h")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(2 * 86400), now: now), "2d0h")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(5 * 3600), now: now), "5h")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(1 * 3600 + 23 * 60), now: now), "1h23m")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(1 * 3600), now: now), "1h00m")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(23 * 60), now: now), "23m")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(1 * 60), now: now), "1m")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now, now: now), "已过期")
        XCTAssertEqual(Formatters.formatResetSuffix(from: now.addingTimeInterval(-3600), now: now), "已过期")
        // formatClock: 同日只显示 HH:MM, 跨日显示 MM-DD HH:MM
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let baseTime = formatter.date(from: "2026-07-08 12:00:00")!
        let sameDay = formatter.date(from: "2026-07-08 21:32:00")!
        let diffDay = formatter.date(from: "2026-07-09 21:32:00")!
        XCTAssertEqual(Formatters.formatClock(sameDay, now: baseTime), "21:32")
        XCTAssertEqual(Formatters.formatClock(diffDay, now: baseTime), "07-09 21:32")
        // formatTimeOfDay: 恒定 HH:mm，跨天**不**退化——兜底行胶囊宽度预算按 5 字符钉死
        XCTAssertEqual(Formatters.formatTimeOfDay(sameDay), "21:32")
        XCTAssertEqual(Formatters.formatTimeOfDay(diffDay), "21:32")
    }

    /// 高峰倒计时 formatPeakDuration 与数字时钟 formatDigitalDuration
    func testPeakAndDigitalDurations() {
        // formatPeakDuration: 紧凑中文
        XCTAssertEqual(Formatters.formatPeakDuration(2 * 86_400 + 8 * 3_600), "2天8小时")
        XCTAssertEqual(Formatters.formatPeakDuration(1 * 3_600 + 30 * 60), "1小时30分")
        XCTAssertEqual(Formatters.formatPeakDuration(1 * 3_600), "1小时")
        XCTAssertEqual(Formatters.formatPeakDuration(30 * 60), "30分")
        XCTAssertEqual(Formatters.formatPeakDuration(0), "1分")
        XCTAssertEqual(Formatters.formatPeakDuration(-100), "1分")

        // formatDigitalDuration: 数字时钟
        XCTAssertEqual(Formatters.formatDigitalDuration(0), "00:00")
        XCTAssertEqual(Formatters.formatDigitalDuration(-5), "00:00")
        XCTAssertEqual(Formatters.formatDigitalDuration(59), "00:59")
        XCTAssertEqual(Formatters.formatDigitalDuration(65), "01:05")
        XCTAssertEqual(Formatters.formatDigitalDuration(3600), "1:00:00")
        XCTAssertEqual(Formatters.formatDigitalDuration(3665), "1:01:05")
    }

    /// formatDuration 与 formatInterval 与 codexWindowLabel
    func testDurationAndIntervalFormatters() {
        // formatDuration
        XCTAssertEqual(Formatters.formatDuration(2 * 86400 + 3 * 3600), "2 天 3 小时")
        XCTAssertEqual(Formatters.formatDuration(3 * 3600 + 20 * 60), "3 小时 20 分")
        XCTAssertEqual(Formatters.formatDuration(25 * 60), "25 分")
        XCTAssertEqual(Formatters.formatDuration(42), "42 秒")

        // formatInterval
        XCTAssertEqual(Formatters.formatInterval(seconds: 10), "10 秒")
        XCTAssertEqual(Formatters.formatInterval(seconds: 120), "2 分钟")
        XCTAssertEqual(Formatters.formatInterval(seconds: 150), "2 分 30 秒")
        XCTAssertEqual(Formatters.formatInterval(seconds: 3600), "1 小时")
        XCTAssertEqual(Formatters.formatInterval(seconds: 3660), "1 小时 1 分")

        // codexWindowLabel
        XCTAssertEqual(Formatters.codexWindowLabel(seconds: 7 * 86_400), "周")
        XCTAssertEqual(Formatters.codexWindowLabel(seconds: 3 * 86_400), "3天")
        XCTAssertEqual(Formatters.codexWindowLabel(seconds: 3_600), "1小时")
        XCTAssertEqual(Formatters.codexWindowLabel(seconds: 60), "1分钟")
        XCTAssertEqual(Formatters.codexWindowLabel(seconds: nil), "主额度")
    }
}
