import XCTest
import Foundation
@testable import LLM_monitor

/// 两个 SQLite scanner（minimax / antigravity）共享的 per-day 聚合：
/// `computeGlobalDaily`（跨 source 合并）与 `filterLast7Days`（7 天窗口补零）。
/// 对应 `DailyUsageAggregation.swift`。
///
/// 消费面是 7 天 hover 图表：它**恒定**按 7 个格子渲染，所以 `filterLast7Days`
/// 少返回一天，图上就少一根柱子、且"今天"会落在错误的那一格 —— 这类偏移不会
/// 崩、不会报错，只会安静地画错，因此值得逐条钉死。
final class DailyUsageAggregationTests: XCTestCase {

    /// 固定 UTC 日历：跨时区 / 夏令时会让 startOfDay 与 day key 漂移，测试不该
    /// 依赖运行机器的本地时区。
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private func day(_ today: Date, offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: today))!
    }

    private func usage(
        _ dayStart: Date,
        input: Int = 0,
        output: Int = 0,
        rounds: Int = 0
    ) -> LocalDailyTokenUsage {
        LocalDailyTokenUsage(
            dayStart: dayStart,
            inputTokens: input,
            outputTokens: output,
            totalTokens: input + output,
            rounds: rounds
        )
    }

    // MARK: - filterLast7Days

    /// 输入带缺口（只有两天有数据）时**恒返 7 个元素**，中间缺口补零、按日升序、
    /// 最后一天恒为 today。
    func testFilterLast7DaysFillsGapsAndAlwaysReturnsSevenDays() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let allDaily = [
            usage(day(today, offset: 0), input: 10),
            usage(day(today, offset: -3), input: 40)
        ]

        let seven = DailyUsageAggregation.filterLast7Days(
            allDaily: allDaily, today: today, calendar: calendar
        )

        XCTAssertEqual(seven.count, 7, "7 天窗口必须恒返 7 天，缺口靠补零而不是少一天")
        XCTAssertEqual(
            seven.map(\.dayStart),
            (-6...0).map { day(today, offset: $0) },
            "必须按日升序覆盖 [today-6, today]，today 落在最后一格"
        )
        XCTAssertEqual(seven[6].inputTokens, 10, "today 的数据必须原样出现")
        XCTAssertEqual(seven[3].inputTokens, 40, "today-3 的数据必须落在第 4 格")
        for index in [0, 1, 2, 4, 5] {
            XCTAssertEqual(seven[index].inputTokens, 0, "缺口日 \(index) 必须补零而不是留空")
            XCTAssertEqual(seven[index].rounds, 0)
        }
    }

    /// 窗口外的旧数据不进数组；当天带非零时刻的记录被归一到 `startOfDay`，
    /// 数值一个不少 —— 消费面按 day key 匹配，dayStart 精度不一致会整格落空。
    func testFilterLast7DaysNormalizesDayStartAndDropsOlderDays() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let todayNoon = calendar.date(byAdding: .hour, value: 12, to: day(today, offset: 0))!
        let allDaily = [
            usage(todayNoon, input: 7, output: 3),
            usage(day(today, offset: -9), input: 999)
        ]

        let seven = DailyUsageAggregation.filterLast7Days(
            allDaily: allDaily, today: today, calendar: calendar
        )

        XCTAssertEqual(seven.count, 7)
        XCTAssertEqual(seven[6].dayStart, day(today, offset: 0), "dayStart 必须对齐到本地 0 点")
        XCTAssertEqual(seven[6].inputTokens, 7)
        XCTAssertEqual(seven[6].outputTokens, 3)
        XCTAssertFalse(
            seven.contains { $0.inputTokens == 999 },
            "7 天窗口外的旧数据不得混进来"
        )
    }

    /// 空输入返回空数组（而不是 7 个零）：调用方据此判断"这个来源还没有任何历史"。
    func testFilterLast7DaysReturnsEmptyForEmptyInput() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let allDaily: [LocalDailyTokenUsage] = []
        XCTAssertTrue(
            DailyUsageAggregation.filterLast7Days(allDaily: allDaily, today: today, calendar: calendar).isEmpty
        )
    }

    // MARK: - computeGlobalDaily

    /// 两个 source 的同一天必须**累加**成一条（不是二选一），不同天各占一条，
    /// 结果按日升序。
    func testComputeGlobalDailySumsSourcesOnTheSameDay() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let dailyBySource: [String: [String: LocalDailyTokenUsage]] = [
            "minimax": [
                LocalUsageDayKey.make(day(today, offset: 0), calendar: calendar): usage(day(today, offset: 0), input: 100, output: 10, rounds: 2),
                LocalUsageDayKey.make(day(today, offset: -1), calendar: calendar): usage(day(today, offset: -1), input: 50)
            ],
            "antigravity": [
                LocalUsageDayKey.make(day(today, offset: 0), calendar: calendar): usage(day(today, offset: 0), input: 5, output: 1, rounds: 1)
            ]
        ]

        let global = DailyUsageAggregation.computeGlobalDaily(
            from: dailyBySource, calendar: calendar
        )

        XCTAssertEqual(global.count, 2, "同一天的跨 source 用量必须合并成一条")
        XCTAssertEqual(global[0].dayStart, day(today, offset: -1))
        XCTAssertEqual(global[1].dayStart, day(today, offset: 0), "必须按日升序")
        XCTAssertEqual(global[1].inputTokens, 105, "今天的 input 必须跨 source 相加")
        XCTAssertEqual(global[1].outputTokens, 11)
        XCTAssertEqual(global[1].rounds, 3)
        XCTAssertEqual(global[1].totalTokens, 116, "totalTokens 同样按 source 相加")
    }

    /// 没有任何 source 时返回空数组。
    func testComputeGlobalDailyReturnsEmptyForNoSources() {
        let dailyBySource: [String: [String: LocalDailyTokenUsage]] = [:]
        let global = DailyUsageAggregation.computeGlobalDaily(
            from: dailyBySource, calendar: calendar
        )
        XCTAssertTrue(global.isEmpty)
    }

    // MARK: - todayCutoff

    func testTodayCutoffIsStartOfDay() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cutoff = DailyUsageAggregation.todayCutoff(now: now, calendar: calendar)
        XCTAssertEqual(cutoff, calendar.startOfDay(for: now))
        XCTAssertEqual(LocalUsageDayKey.make(cutoff, calendar: calendar),
                       LocalUsageDayKey.make(now, calendar: calendar))
    }

    // MARK: - LocalUsageDayKey 日期键解析（自 UsableAPIKeyHealthLevelTests 解散归入）

    func testLocalUsageDayKeyRules() {
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertNil(LocalUsageDayKey.parse("not-a-date", calendar: calendar))
        XCTAssertNil(LocalUsageDayKey.parse("", calendar: calendar))
        XCTAssertNil(LocalUsageDayKey.parse("2026-13-99", calendar: calendar))

        let date = LocalUsageDayKey.parse("2026-07-16", calendar: calendar)!
        XCTAssertEqual(calendar.component(.year, from: date), 2026)
        XCTAssertEqual(LocalUsageDayKey.make(date), LocalUsageDayKey.make(date))
    }
}
