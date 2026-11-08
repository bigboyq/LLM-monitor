import XCTest
import SQLite3
@testable import LLM_monitor

/// 聚合契约（数据源无关层）：`aggregateDaily` 的日桶切分与预计算计数防双倍、
/// `accountedEventStats` 入账口径、`accountCalls` 的 turns/rounds 直计映射，
/// 以及冷启动恢复（RPC 时代的 `parseUsageEvent` 系列测试随该解析器退役删除）。
final class AntigravityUsageEventParseTests: AntigravityTestCase {

    // MARK: - 冷启动恢复

    func testAntigravityRestoresCachedUsageOnColdStart() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-prefill-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManagerBox()
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: now)
        let usage = AntigravityDailyUsage(
            dayStart: day, inputTokens: 11,
            outputTokens: 6,
            cacheReadTokens: 3,
            cacheWriteTokens: 0, reasoningTokens: 1, totalTokens: 21,
            turns: 1, rounds: 2
        )
        let index = AntigravityLocalUsageScanner.CacheIndex(
            version: 12,
            lastScannedAt: now,
            sessions: ["session-1": AntigravityLocalUsageScanner.SessionIndexEntry(
                mtimeMs: 1, sizeBytes: 2, walMtimeMs: 0, walSizeBytes: 0,
                fetchedAt: now, eventCount: 2
            )],
            dailyBySession: ["session-1": [LocalUsageDayKey.make(day, calendar: calendar): usage]],
            samplesBySession: nil,
            calendarSignature: LocalUsageCalendarSignature.make(calendar)
        )
        try AntigravityLocalUsageScanner.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let restored = try XCTUnwrap(
            AntigravityLocalUsageScanner.loadCachedResult(
                cacheDir: cacheDir,
                fileManager: fileManager,
                calendar: calendar,
                now: now
            )
        )
        XCTAssertEqual(restored.today, usage)
        XCTAssertEqual(restored.dailyTokenUsage.count, 7)
        XCTAssertEqual(restored.dailyTokenUsage.last, usage)
        XCTAssertEqual(restored.eventCount, 2)
        XCTAssertEqual(restored.sessionCount, 1)
        XCTAssertEqual(restored.scannedAt, now)
    }

    // MARK: - aggregateDaily（makeSample/aggregateDaily 入口契约不变）

    func testAggregateDailyGroupsByLocalDay() {
        // 三个事件：两个在"今天"，一个在"昨天"
        let now = Date()
        let today = testCalendar.startOfDay(for: now)
        let yesterday = testCalendar.date(byAdding: .day, value: -1, to: today)!

        let events = [
            makeEvent(timestamp: now, input: 10, output: 8, reasoning: 3),
            makeEvent(timestamp: today.addingTimeInterval(3600), input: 20, output: 8),
            makeEvent(timestamp: yesterday, input: 30, output: 12),
        ]
        let byDay = AntigravityLocalUsageScanner.aggregateDaily(events: events, calendar: testCalendar)

        XCTAssertEqual(byDay.count, 2)
        // 日键必须与聚合同一个 calendar（默认 `.current` 会与 testCalendar 错开）
        let todayKey = LocalUsageDayKey.make(today, calendar: testCalendar)
        let yesterdayKey = LocalUsageDayKey.make(yesterday, calendar: testCalendar)

        XCTAssertEqual(byDay[todayKey]?.inputTokens, 30)   // 10 + 20
        // raw output 含思考：catalog 规范化 Output = raw − reasoning。
        XCTAssertEqual(byDay[todayKey]?.outputTokens, 13)  // (8−3) + 8
        XCTAssertEqual(byDay[yesterdayKey]?.inputTokens, 30)
    }

    func testAggregateDailySkipsEventsWithoutTimestamp() {
        let now = Date()
        let events = [
            makeEvent(timestamp: nil, input: 100, output: 10),
            makeEvent(timestamp: now, input: 5, output: 2),
        ]
        let byDay = AntigravityLocalUsageScanner.aggregateDaily(events: events, calendar: testCalendar)
        XCTAssertEqual(byDay.count, 1)
        let todayKey = LocalUsageDayKey.make(testCalendar.startOfDay(for: now), calendar: testCalendar)
        XCTAssertEqual(byDay[todayKey]?.inputTokens, 5)
    }

    /// F1：scanner 成功路径传入预计算的 per-day counts 时，聚合不得把同一份
    /// turns/rounds 再叠加一次（`accountCalls` 的路径）。
    func testAggregateDailyWithPrecomputedCountsDoesNotDoubleCount() {
        let now = Date()
        let today = testCalendar.startOfDay(for: now)
        let counts = AntigravityTurnRoundCounts(perDay: [
            today: DailyTurnRound(turns: 2, rounds: 3)
        ])
        let events = [
            makeEvent(timestamp: now, input: 10, output: 5),
            makeEvent(timestamp: now.addingTimeInterval(60), input: 20, output: 8),
        ]
        let byDay = AntigravityLocalUsageScanner.aggregateDaily(
            events: events, calendar: testCalendar, counts: counts
        )
        let key = LocalUsageDayKey.make(today, calendar: testCalendar)
        XCTAssertEqual(byDay[key]?.turns, 2)
        XCTAssertEqual(byDay[key]?.rounds, 3, "预计算计数原样落到日桶，不随事件数叠加")
        XCTAssertEqual(byDay[key]?.inputTokens, 30)
    }

    func testAggregateDailyCrossDayWithPrecomputedCounts() {
        let now = Date()
        let today = testCalendar.startOfDay(for: now)
        let yesterday = testCalendar.date(byAdding: .day, value: -1, to: today)!
        let counts = AntigravityTurnRoundCounts(perDay: [
            today: DailyTurnRound(turns: 1, rounds: 1),
            yesterday: DailyTurnRound(turns: 3, rounds: 4),
        ])
        let events = [
            makeEvent(timestamp: now, input: 10, output: 5),
            makeEvent(timestamp: yesterday, input: 30, output: 12),
        ]
        let byDay = AntigravityLocalUsageScanner.aggregateDaily(
            events: events, calendar: testCalendar, counts: counts
        )
        XCTAssertEqual(byDay[LocalUsageDayKey.make(today, calendar: testCalendar)]?.turns, 1)
        XCTAssertEqual(byDay[LocalUsageDayKey.make(yesterday, calendar: testCalendar)]?.rounds, 4)
    }

    // MARK: - 入账口径

    func testEventCountCountsOnlyTimestampedEventsLikeDaily() {
        // 语义统一：eventCount = 成功进入日统计（有 timestamp）的 event 数。
        // 无 timestamp 的 event 不进 daily/turns/rounds/samples，也不得计入
        // eventCount，否则“事件数”与 Token 日汇总口径互相矛盾。
        let now = Date()
        let events = [
            makeEvent(timestamp: nil, input: 100, output: 10),
            makeEvent(timestamp: now, input: 5, output: 2),
            makeEvent(timestamp: now.addingTimeInterval(60), input: 7, output: 3),
            makeEvent(timestamp: nil, input: 200, output: 20),
        ]

        let stats = AntigravityLocalUsageScanner.accountedEventStats(events)
        XCTAssertEqual(stats.accounted, 2)
        XCTAssertEqual(stats.droppedTimestampless, 2)

        // 与 aggregateDaily 的一致性：daily 的 token 总量只来自 accounted 事件。
        let byDay = AntigravityLocalUsageScanner.aggregateDaily(events: events, calendar: testCalendar)
        let dailyInput = byDay.values.reduce(0) { $0 + $1.inputTokens }
        XCTAssertEqual(dailyInput, 12)
        XCTAssertEqual(stats.accounted, 2, "eventCount 与 daily 计入的事件数一致")

        // 全部有 timestamp：不丢弃。
        let allStamped = [
            makeEvent(timestamp: now, input: 1, output: 1),
            makeEvent(timestamp: now, input: 2, output: 2),
        ]
        let allStats = AntigravityLocalUsageScanner.accountedEventStats(allStamped)
        XCTAssertEqual(allStats.accounted, 2)
        XCTAssertEqual(allStats.droppedTimestampless, 0)
    }

    // MARK: - accountCalls（turns 直计 / rounds / promptID / 时长）

    func testAccountCallsMapsTurnsRoundsSamplesAndDuration() throws {
        let base = Date(timeIntervalSince1970: 1_789_996_800)
        let day = testCalendar.startOfDay(for: base)
        let nextDay = testCalendar.date(byAdding: .day, value: 1, to: day)!

        func call(stepIndex: Int, completedAt: Date?, model: String = "m") -> AntigravitySessionDBReader.Call {
            AntigravitySessionDBReader.Call(
                sessionID: "sess",
                genIndex: stepIndex,
                stepIndex: stepIndex,
                modelName: model,
                uncachedInputTokens: 10,
                cacheReadTokens: 5,
                rawOutputTokens: 8,
                reasoningTokens: 3,
                startedAt: completedAt.map { $0.addingTimeInterval(-2) },
                completedAt: completedAt,
                durationSeconds: completedAt == nil ? nil : 2
            )
        }

        let accounting = AntigravityLocalUsageScanner.accountCalls(
            sessionID: "sess",
            calls: [
                call(stepIndex: 5, completedAt: base.addingTimeInterval(60)),
                call(stepIndex: 6, completedAt: base.addingTimeInterval(120)),
                call(stepIndex: 45, completedAt: nextDay.addingTimeInterval(60)),
                call(stepIndex: 7, completedAt: nil),  // 无时间戳：整条排除
            ],
            turnStepIndexes: [1, 40],
            calendar: testCalendar
        )

        XCTAssertEqual(accounting.accountedEventCount, 3)
        XCTAssertEqual(accounting.droppedTimestamplessCount, 1)
        XCTAssertEqual(accounting.counts.totalTurns, 2, "轮 1（step<40 的 2 条 call）+ 轮 2（step 45）")
        XCTAssertEqual(accounting.counts.totalRounds, 3)
        XCTAssertEqual(accounting.counts.perDay[day]?.turns, 1, "轮 1 的第一条 call 决定其日归属")
        XCTAssertEqual(accounting.counts.perDay[day]?.rounds, 2)
        XCTAssertEqual(accounting.counts.perDay[nextDay]?.turns, 1, "轮 2 归属其第一条 call 的日子")
        XCTAssertEqual(accounting.counts.perDay[nextDay]?.rounds, 1)

        XCTAssertEqual(accounting.samples.map(\.promptID), [
            "sess:turn-1", "sess:turn-1", "sess:turn-2",
        ], "轮序 = idx 小于该 call stepIndex 的 step14 行数")
        let first = try XCTUnwrap(accounting.samples.first)
        XCTAssertEqual(first.inputTokens, 15, "sample input = uncached + cacheRead")
        XCTAssertEqual(first.cachedInputTokens, 5)
        XCTAssertEqual(first.outputTokens, 5, "Output = raw(8) − reasoning(3)")
        XCTAssertEqual(first.reasoningOutputTokens, 3)
        XCTAssertEqual(first.durationSeconds ?? 0, 2, accuracy: 0.000_001)
        // Antigravity 不采集 TTFT：gen blob f1.f11 经 2026-11-08 实测评议证伪
        //（其值 ≈ 整段调用时长，不是首字延迟），样本 ttftSeconds 恒 nil。
        XCTAssertNil(first.ttftSeconds, "antigravity 样本不携带 TTFT")
        XCTAssertNil(accounting.samples[1].ttftSeconds, "antigravity 样本不携带 TTFT")

        let dayKey = LocalUsageDayKey.make(day, calendar: testCalendar)
        let nextDayKey = LocalUsageDayKey.make(nextDay, calendar: testCalendar)
        XCTAssertEqual(accounting.daily[dayKey]?.inputTokens, 20, "day 桶 = 轮 1 的两条 call（10 × 2）")
        XCTAssertEqual(accounting.daily[dayKey]?.cacheWriteTokens, 0, "cacheWrite 恒 0（db 不提供）")
        XCTAssertEqual(accounting.daily[nextDayKey]?.inputTokens, 10)
    }
}
