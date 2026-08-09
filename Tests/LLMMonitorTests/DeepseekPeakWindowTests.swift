import XCTest
import Foundation
@testable import LLM_monitor

final class DeepseekPeakWindowTests: XCTestCase {

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
        let status = window.status(at: now)

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
        let status = window.status(at: now)

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
        let status = window.status(at: now)

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
        let status = window.status(at: now)

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
        let status = window.status(at: now)

        if case .offPeak(until: let start) = status {
            let expectedStart = makeBeijingDate(year: 2026, month: 8, day: 6, hour: 9, minute: 0)
            XCTAssertEqual(start, expectedStart)
        } else {
            XCTFail("20:00 should be offPeak")
        }
    }

    // MARK: - 周末平价（weekdaysOnly）

    func testDeepseekWeekendSaturdayIsOffPeakByDefault() {
        let window = DeepseekPeakWindow.defaultWindow   // weekdaysOnly = true
        // 北京时间 2026-08-08（周六）10:15 —— 本应落在第一高峰 slot(9–12)
        let now = makeBeijingDate(year: 2026, month: 8, day: 8, hour: 10, minute: 15)
        let status = window.status(at: now)

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
        let status = window.status(at: now)

        if case .offPeak(until: let start) = status {
            // 下一高峰为下周一(2026-08-10) 9:00
            let expectedStart = makeBeijingDate(year: 2026, month: 8, day: 10, hour: 9, minute: 0)
            XCTAssertEqual(start, expectedStart)
        } else {
            XCTFail("Sunday 16:30 should be offPeak when weekdaysOnly")
        }
    }

    func testDeepseekWeekendSaturdayIsPeakWhenWeekdaysOnlyFalse() {
        // 关闭周末平价：每天（含周末）都执行高峰时段（即现状）
        let window = DeepseekPeakWindow(slots: DeepseekPeakWindow.defaultWindow.slots, weekdaysOnly: false)
        // 北京时间 2026-08-08（周六）10:15 —— 落在第一高峰 slot(9–12)
        let now = makeBeijingDate(year: 2026, month: 8, day: 8, hour: 10, minute: 15)
        let status = window.status(at: now)

        if case .peak(until: let end) = status {
            let expectedEnd = makeBeijingDate(year: 2026, month: 8, day: 8, hour: 12, minute: 0)
            XCTAssertEqual(end, expectedEnd)
        } else {
            XCTFail("Saturday 10:15 should be peak when weekdaysOnly=false")
        }
    }
}
