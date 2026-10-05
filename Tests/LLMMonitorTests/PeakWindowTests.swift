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

    // MARK: - 法定节假日（Rule A：周一–周五 ∧ 非法定节假日，`HolidayCalendar` 注入）

    /// 节假日内的周一–周五判非高峰（DeepSeek 双窗口 + fixture 注入）：
    /// 2026-08-05（周三）整日标记为节假日，10:00 落在 9–12 slot 内也必须 offPeak，
    /// 下一高峰顺延到次日（周四 08-06）09:00。
    func testHolidayWeekdayIsOffPeakWithFixtureHolidays() {
        let holidays = HolidayCalendar.make(holidays: ["2026-08-05"])
        // 同一时刻：无节假日表 → peak；标记节假日 → offPeak（对照断言钉住注入生效）。
        let now = makeBeijingDate(year: 2026, month: 8, day: 5, hour: 10, minute: 15)
        if case .peak = DeepseekPeakWindow.defaultWindow.status(at: now, calendar: PeakWindow.beijingCalendar, holidays: .empty) {} else {
            XCTFail("周三 10:15 在无节假日表下应为 peak")
        }
        if case .offPeak(until: let start) = DeepseekPeakWindow.defaultWindow.status(at: now, calendar: PeakWindow.beijingCalendar, holidays: holidays) {
            let expected = makeBeijingDate(year: 2026, month: 8, day: 6, hour: 9, minute: 0)
            XCTAssertEqual(start, expected, "节假日周三的下一高峰应为次日（周四）09:00")
        } else {
            XCTFail("节假日周三 10:15 应为 offPeak")
        }
    }

    /// 节假日日期键的半开语义（按自然日）：节假日首日 00:00 已生效（非高峰），
    /// 假后首日 00:00 已恢复（当天 09:00 起为高峰）。
    func testHolidayDayBoundaryAtMidnight() {
        let holidays = HolidayCalendar.make(holidays: ["2026-08-05"])
        let window = DeepseekPeakWindow.defaultWindow

        let holidayMidnight = makeBeijingDate(year: 2026, month: 8, day: 5, hour: 0, minute: 0)
        if case .offPeak(until: let start) = window.status(at: holidayMidnight, calendar: PeakWindow.beijingCalendar, holidays: holidays) {
            XCTAssertEqual(start, makeBeijingDate(year: 2026, month: 8, day: 6, hour: 9, minute: 0))
        } else {
            XCTFail("节假日首日 00:00 应为 offPeak")
        }

        let recoveredMidnight = makeBeijingDate(year: 2026, month: 8, day: 6, hour: 0, minute: 0)
        if case .offPeak(until: let start) = window.status(at: recoveredMidnight, calendar: PeakWindow.beijingCalendar, holidays: holidays) {
            XCTAssertEqual(start, makeBeijingDate(year: 2026, month: 8, day: 6, hour: 9, minute: 0),
                           "假后首日 00:00 已恢复工作日，当天 09:00 即高峰")
        } else {
            XCTFail("假后首日 00:00 应为 offPeak（尚未到 slot 开始）")
        }
    }

    /// GLM 单窗口 + 节假日：周三 15:00（14–18 slot 内）标记节假日后判非高峰，
    /// 下一高峰 = 次日 14:00。
    func testGlmHolidayWeekdayAfternoonIsOffPeak() {
        let holidays = HolidayCalendar.make(holidays: ["2026-08-05"])
        let window = GlmPeakWindow(startHour: 14, endHour: 18, weekdaysOnly: true)
        let now = makeBeijingDate(year: 2026, month: 8, day: 5, hour: 15, minute: 0)
        if case .offPeak(until: let start) = window.status(at: now, calendar: PeakWindow.beijingCalendar, holidays: holidays) {
            XCTAssertEqual(start, makeBeijingDate(year: 2026, month: 8, day: 6, hour: 14, minute: 0))
        } else {
            XCTFail("节假日周三 15:00（GLM 14–18 slot 内）应为 offPeak")
        }
    }

    /// 长假（春节 fixture）后 `nextPeakStart` 跳到假后第一个工作日：
    /// 2026-02-13（周五）–2026-02-22（周日）连续 10 天非高峰（法定假 + 相邻周末），
    /// now = 02-13 10:00 → 下一高峰 02-23（周一）09:00。命中偏移 10 > 旧 8 天
    /// 预算 —— 15 天窗口正是为此扩的。
    func testNextPeakStartSkipsLongSpringFestivalFixture() {
        let holidays = HolidayCalendar.make(holidays: [
            "2026-02-13", "2026-02-14", "2026-02-15", "2026-02-16", "2026-02-17",
            "2026-02-18", "2026-02-19", "2026-02-20", "2026-02-21", "2026-02-22"
        ])
        let now = makeBeijingDate(year: 2026, month: 2, day: 13, hour: 10, minute: 0)
        if case .offPeak(until: let start) = DeepseekPeakWindow.defaultWindow.status(at: now, calendar: PeakWindow.beijingCalendar, holidays: holidays) {
            XCTAssertEqual(start, makeBeijingDate(year: 2026, month: 2, day: 23, hour: 9, minute: 0),
                           "10 天连续非高峰后应命中假后第一个工作日（周一）09:00")
        } else {
            XCTFail("春节长假期间应为 offPeak")
        }
    }

    /// 扫描预算 15 天足够覆盖最长空档：春节 9 天法定假（02-15 周日 – 02-23 周一）
    /// + 首部紧邻周末（02-14 周六）→ 连续非高峰日最长 ~11 天。
    /// now = 02-13（周五）20:00 → 下一高峰 02-24（周二）09:00，偏移 11 < 15。
    func testNextPeakStartScanBudgetCoversLongestHolidayGap() {
        let holidays = HolidayCalendar.make(holidays: [
            "2026-02-14", "2026-02-15", "2026-02-16", "2026-02-17", "2026-02-18",
            "2026-02-19", "2026-02-20", "2026-02-21", "2026-02-22", "2026-02-23"
        ])
        let now = makeBeijingDate(year: 2026, month: 2, day: 13, hour: 20, minute: 0)
        if case .offPeak(until: let start) = DeepseekPeakWindow.defaultWindow.status(at: now, calendar: PeakWindow.beijingCalendar, holidays: holidays) {
            XCTAssertEqual(start, makeBeijingDate(year: 2026, month: 2, day: 24, hour: 9, minute: 0),
                           "最长空档（~11 天）必须落在 15 天扫描预算内")
        } else {
            XCTFail("春节长假期间应为 offPeak")
        }
    }

    /// 时区统一回归（谓词层）：同一固定时刻 —— 北京时间周三 15:00（GLM 14–18
    /// 高峰内）vs 纽约时间周二 03:00（非高峰）—— GLM 判定必须随传入 Calendar 走，
    /// 调用方显式传 `beijingCalendar` 后与本机时区无关。
    func testGlmJudgmentIsBeijingTimeRegardlessOfMachineTimezone() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!

        // 北京 2026-08-05（周三）15:00 == 纽约 2026-08-04（周二）03:00（EDT, UTC-4）
        let instant = makeBeijingDate(year: 2026, month: 8, day: 5, hour: 15, minute: 0)
        let window = GlmPeakWindow.zhipuDefault

        if case .peak = window.status(at: instant, calendar: PeakWindow.beijingCalendar) {} else {
            XCTFail("北京时间周三 15:00 应为 peak（GLM 14–18）")
        }
        if case .offPeak = window.status(at: instant, calendar: newYork) {} else {
            XCTFail("同一时刻按纽约日历（周二 03:00）应为 offPeak —— 证明判定随传入 Calendar 而非绝对 UTC 小时")
        }
    }

    /// GLM 判定链路回归（`ProviderStatus.aggregateHealthLevel`）：健康套餐
    /// （80% 绿）在 GLM 高峰内保底 .warning —— 该判定点显式传
    /// `PeakWindow.beijingCalendar`（本机为非中国时区时，若误用本地时区此用例变红）。
    func testGlmAggregateHealthLevelPeakFloorUsesBeijingCalendar() {
        let beijing = PeakWindow.beijingCalendar
        let info = QuotaInfo(
            models: [ModelQuota(
                modelName: "glm_coding_plan",
                intervalTotalCount: 100,
                intervalUsageCount: 20,
                intervalRemainingPercent: 80.0,
                intervalStatus: .present,
                intervalResetsAt: beijing.date(byAdding: .hour, value: 1, to: makeBeijingDate(year: 2026, month: 8, day: 5, hour: 15, minute: 0))!,
                intervalWindowSeconds: 18000,
                weeklyTotalCount: 0,
                weeklyUsageCount: 0,
                weeklyRemainingPercent: 0,
                weeklyStatus: .absent,
                weeklyResetsAt: nil,
                weeklyWindowSeconds: nil
            )],
            resetCredits: nil,
            planLabel: "Lite",
            accountEmail: nil,
            codexUsageDetails: nil,
            fetchedAt: makeBeijingDate(year: 2026, month: 8, day: 5, hour: 10, minute: 0)
        )
        var status = ProviderStatus(
            id: "glm",
            displayName: "GLM Coding Plan",
            kind: .glmCodingPlan,
            iconSystemName: "c",
            accentColor: .glm,
            refreshIntervalSeconds: 300,
            state: .ok(info)
        )
        status.glmPeakWindow = .zhipuDefault

        // 北京时间周三 15:00：GLM 高峰内 → healthy 被 floor 到 .warning。
        XCTAssertEqual(
            status.aggregateHealthLevel(at: makeBeijingDate(year: 2026, month: 8, day: 5, hour: 15, minute: 0)),
            .warning,
            "GLM 高峰内健康套餐必须保底 .warning（判定链路必须用北京时间）"
        )
        // 北京时间周三 13:00（slot 之外）：非高峰 → 维持 .healthy。
        XCTAssertEqual(
            status.aggregateHealthLevel(at: makeBeijingDate(year: 2026, month: 8, day: 5, hour: 13, minute: 0)),
            .healthy
        )
    }
}
