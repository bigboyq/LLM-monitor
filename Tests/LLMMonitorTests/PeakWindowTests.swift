import XCTest
import Foundation
@testable import LLM_monitor

/// 高峰窗口（`PeakWindow` / `DeepseekPeakWindow` / `GlmPeakWindow`）的状态判定：
/// slot 边界、跨日顺延、周末平价与自定义窗口。
///
/// 合并自 `DeepseekPeakWindowTests` 与 `GlmOffPeakTests` 的
/// `testGlmPeakWindowBoundaryAndWeekdaysOnly`，逐字搬移零逻辑变化。
final class PeakWindowTests: XCTestCase {

    private func makeBeijingDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        return cal.date(from: components)!
    }

    func testDeepseekPeakWindowStatusBeforeFirstPeakSlot() {
        let window = DeepseekPeakWindow.defaultWindow
        // 北京时间 8:30 (非高峰，距 9:00 高峰开还剩 30 分钟)
        let now = makeBeijingDate(year: 2026, month: 8, day: 5, hour: 8, minute: 30)
        let status = window.status(at: now, calendar: PeakWindow.beijingCalendar)

        if case .offPeak(until: let start) = status {
            let expectedStart = makeBeijingDate(year: 2026, month: 8, day: 5, hour: 9, minute: 0)
            XCTAssertEqual(start, expectedStart)
        } else {
            XCTFail("8:30 should be offPeak")
        }
    }

    func testDeepseekPeakWindowStatusInFirstPeakSlot() {
        let window = DeepseekPeakWindow.defaultWindow
        // 北京时间 10:15 (高峰 1，距 12:00 结束还剩 1 小时 45 分)
        let now = makeBeijingDate(year: 2026, month: 8, day: 5, hour: 10, minute: 15)
        let status = window.status(at: now, calendar: PeakWindow.beijingCalendar)

        if case .peak(until: let end) = status {
            let expectedEnd = makeBeijingDate(year: 2026, month: 8, day: 5, hour: 12, minute: 0)
            XCTAssertEqual(end, expectedEnd)
        } else {
            XCTFail("10:15 should be peak")
        }
    }

    func testDeepseekPeakWindowStatusBetweenPeakSlots() {
        let window = DeepseekPeakWindow.defaultWindow
        // 北京时间 13:00 (非高峰，距 14:00 高峰二开始还剩 1 小时)
        let now = makeBeijingDate(year: 2026, month: 8, day: 5, hour: 13, minute: 0)
        let status = window.status(at: now, calendar: PeakWindow.beijingCalendar)

        if case .offPeak(until: let start) = status {
            let expectedStart = makeBeijingDate(year: 2026, month: 8, day: 5, hour: 14, minute: 0)
            XCTAssertEqual(start, expectedStart)
        } else {
            XCTFail("13:00 should be offPeak")
        }
    }

    func testDeepseekPeakWindowStatusInSecondPeakSlot() {
        let window = DeepseekPeakWindow.defaultWindow
        // 北京时间 16:30 (高峰 2，距 18:00 结束还剩 1 小时 30 分)
        let now = makeBeijingDate(year: 2026, month: 8, day: 5, hour: 16, minute: 30)
        let status = window.status(at: now, calendar: PeakWindow.beijingCalendar)

        if case .peak(until: let end) = status {
            let expectedEnd = makeBeijingDate(year: 2026, month: 8, day: 5, hour: 18, minute: 0)
            XCTAssertEqual(end, expectedEnd)
        } else {
            XCTFail("16:30 should be peak")
        }
    }

    func testDeepseekPeakWindowStatusAfterSecondPeakSlot() {
        let window = DeepseekPeakWindow.defaultWindow
        // 北京时间 20:00 (非高峰，距次日 9:00 高峰一开始还剩 13 小时)
        let now = makeBeijingDate(year: 2026, month: 8, day: 5, hour: 20, minute: 0)
        let status = window.status(at: now, calendar: PeakWindow.beijingCalendar)

        if case .offPeak(until: let start) = status {
            let expectedStart = makeBeijingDate(year: 2026, month: 8, day: 6, hour: 9, minute: 0)
            XCTAssertEqual(start, expectedStart)
        } else {
            XCTFail("20:00 should be offPeak")
        }
    }

    // MARK: - 周末平价（官方口径：高峰永不含周末，weekdaysOnly 固定 true）

    func testDeepseekWeekendSaturdayIsOffPeakByDefault() {
        let window = DeepseekPeakWindow.defaultWindow   // weekdaysOnly = true
        // 北京时间 2026-08-08（周六）10:15 —— 本应落在第一高峰 slot(9–12)
        let now = makeBeijingDate(year: 2026, month: 8, day: 8, hour: 10, minute: 15)
        let status = window.status(at: now, calendar: PeakWindow.beijingCalendar)

        if case .offPeak(until: let start) = status {
            // 下一高峰为下周一(2026-08-10) 9:00
            let expectedStart = makeBeijingDate(year: 2026, month: 8, day: 10, hour: 9, minute: 0)
            XCTAssertEqual(start, expectedStart)
        } else {
            XCTFail("Saturday 10:15 should be offPeak when weekdaysOnly")
        }
    }

    func testDeepseekWeekendSundayIsOffPeakByDefault() {
        let window = DeepseekPeakWindow.defaultWindow   // weekdaysOnly = true
        // 北京时间 2026-08-09（周日）16:30 —— 本应落在第二高峰 slot(14–18)
        let now = makeBeijingDate(year: 2026, month: 8, day: 9, hour: 16, minute: 30)
        let status = window.status(at: now, calendar: PeakWindow.beijingCalendar)

        if case .offPeak(until: let start) = status {
            // 下一高峰为下周一(2026-08-10) 9:00
            let expectedStart = makeBeijingDate(year: 2026, month: 8, day: 10, hour: 9, minute: 0)
            XCTAssertEqual(start, expectedStart)
        } else {
            XCTFail("Sunday 16:30 should be offPeak when weekdaysOnly")
        }
    }

    // MARK: - GLM 自定义高峰窗口（合并自 GlmOffPeakTests）

    func testGlmPeakWindowBoundaryAndWeekdaysOnly() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        // Peak window: 10:00 - 18:00 UTC
        let window = GlmPeakWindow(startHour: 10, endHour: 18, weekdaysOnly: true)

        // Monday (2026-08-03)
        var comps = DateComponents(year: 2026, month: 8, day: 3, hour: 10, minute: 0, second: 0)
        let startBound = cal.date(from: comps)!
        comps.hour = 17
        comps.minute = 59
        let insidePeak = cal.date(from: comps)!
        comps.hour = 18
        comps.minute = 0
        let endBound = cal.date(from: comps)! // half-open: 18:00 is off-peak

        if case .peak = window.status(at: startBound, calendar: cal) {} else { XCTFail("startBound should be peak") }
        if case .peak = window.status(at: insidePeak, calendar: cal) {} else { XCTFail("insidePeak should be peak") }
        if case .offPeak = window.status(at: endBound, calendar: cal) {} else { XCTFail("endBound should be off-peak") }

        // Sunday (2026-08-02): weekdaysOnly = true -> off-peak on weekends
        comps = DateComponents(year: 2026, month: 8, day: 2, hour: 12, minute: 0, second: 0)
        let sundayNoon = cal.date(from: comps)!
        if case .offPeak = window.status(at: sundayNoon, calendar: cal) {} else { XCTFail("Sunday should be off-peak") }

        // weekdaysOnly = false -> Sunday noon is peak
        let everydayWindow = GlmPeakWindow(startHour: 10, endHour: 18, weekdaysOnly: false)
        if case .peak = everydayWindow.status(at: sundayNoon, calendar: cal) {} else { XCTFail("Everyday Sunday noon should be peak") }
    }
}
