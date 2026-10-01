import XCTest
import SQLite3
@testable import LLM_monitor

/// `AntigravityFetcher.parseUsageEvent` 的解析口径，以及 F1：scanner 成功分支的
/// turns/rounds 不得因预计算计数而双倍计数。
final class AntigravityUsageEventParseTests: AntigravityTestCase {

    // MARK: - 共享 fixture

    /// decode + parse 的小工具, 11 个原测试都重复同一行, 抽出来减少 noise
    private func parseUsageEvent(_ json: String) throws -> AntigravityFetcher.UsageEvent? {
        let wrapped = try JSONDecoder().decode(AnyJSON.self, from: Data(json.utf8))
        return AntigravityFetcher.parseUsageEventForTest(wrapped)
    }

    // MARK: - 测试

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
            version: 5,
            lastScannedAt: now,
            sessions: ["session-1": AntigravityLocalUsageScanner.SessionIndexEntry(
                mtimeMs: 1, sizeBytes: 2, fetchedAt: now, eventCount: 2
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

    /// 正常解析 5 种 case：完整 payload / 嵌套结构 / snake_case / placeholder model / timestamp 三种格式
    func testParseUsageEventHappyPath() throws {
        // 1. 完整 payload (顶层 camelCase) → 5 类 token + total = sum - cacheWrite
        do {
            let json = """
            {
              "timestamp": "2026-07-15T10:30:00Z",
              "model": "gemini-2.5-pro",
              "inputTokens": 100, "outputTokens": 50,
              "cacheReadTokens": 20, "cacheWriteTokens": 5, "reasoningTokens": 10,
              "totalTokens": 185
            }
            """
            let event = try parseUsageEvent(json)
            XCTAssertEqual(event?.inputTokens, 100)
            XCTAssertEqual(event?.outputTokens, 50)
            XCTAssertEqual(event?.cacheReadTokens, 20)
            XCTAssertEqual(event?.cacheWriteTokens, 5)
            XCTAssertEqual(event?.reasoningTokens, 10)
            XCTAssertEqual(event?.model, "gemini-2.5-pro")
        }
        // 2. 嵌套结构 (ddarkr 看到的实际格式) → 字段都能从深处找到
        do {
            let json = """
            {
              "metadata": {
                "timestamp": "2026-07-15T10:30:00Z",
                "chatModel": {
                  "model": "claude-sonnet-4.5",
                  "usage": {
                    "input_tokens": 100, "output_tokens": 50,
                    "cacheReadTokens": 20, "reasoningTokens": 10
                  }
                }
              }
            }
            """
            let event = try parseUsageEvent(json)
            XCTAssertNotNil(event)
            XCTAssertGreaterThan(event?.inputTokens ?? 0, 0)
            XCTAssertGreaterThan(event?.outputTokens ?? 0, 0)
            XCTAssertGreaterThan(event?.cacheReadTokens ?? 0, 0)
            XCTAssertGreaterThan(event?.reasoningTokens ?? 0, 0)
            XCTAssertEqual(event?.model, "claude-sonnet-4.5")
        }
        // 3. snake_case (旧版本 Antigravity) → 兼容
        do {
            let json = """
            {
              "timestamp": "2026-07-15T10:30:00Z",
              "input_tokens": 100, "output_tokens": 50,
              "cache_read_tokens": 20, "cache_write_tokens": 5,
              "reasoning_tokens": 10, "total_tokens": 185
            }
            """
            let event = try parseUsageEvent(json)
            XCTAssertEqual(event?.inputTokens, 100)
            XCTAssertEqual(event?.outputTokens, 50)
            XCTAssertEqual(event?.cacheReadTokens, 20)
            XCTAssertEqual(event?.cacheWriteTokens, 5)
            XCTAssertEqual(event?.reasoningTokens, 10)
        }
        // 4. placeholder model → model 字段被丢弃, 其他 token 字段保留
        do {
            let json = """
            {
              "timestamp": "2026-07-15T10:30:00Z",
              "model": "MODEL_PLACEHOLDER_M9",
              "inputTokens": 100
            }
            """
            let event = try parseUsageEvent(json)
            XCTAssertNil(event?.model, "placeholder model 名应被丢弃")
            XCTAssertEqual(event?.inputTokens, 100)
        }
        // 5. timestamp 三种格式 (ISO8601 / epoch seconds / epoch millis), 嵌套层也都吃
        do {
            // ISO8601 嵌套
            let iso = try parseUsageEvent(#"{"metadata":{"timestamp":"2026-07-15T10:30:00Z"},"inputTokens":100}"#)
            XCTAssertNotNil(iso?.timestamp, "嵌套层 ISO8601 应被提取")
            // epoch seconds 嵌套
            let sec = try parseUsageEvent(#"{"wrapper":{"created":1721034600},"inputTokens":50}"#)
            XCTAssertEqual(sec?.timestamp?.timeIntervalSince1970 ?? 0, 1721034600, accuracy: 0.001)
            // `time` 字段 (legacy fallback)
            let legacy = try parseUsageEvent(#"{"time":1721034600,"inputTokens":100}"#)
            XCTAssertEqual(legacy?.timestamp?.timeIntervalSince1970 ?? 0, 1721034600, accuracy: 0.001)
        }
    }

    func testParseUsageEventCapsRecursiveDepth() throws {
        var json = #"{"timestamp":"2026-07-15T10:30:00Z","inputTokens":1}"#
        for _ in 0..<40 {
            json = "{\"nested\":\(json)}"
        }

        // R11: AnyJSON 在解码阶段统一限制嵌套深度 32；40 层 payload 应在解码阶段
        // 被拒绝（抛 DecodingError），不再走到 visit 层的 depth cap。visit(depth<32)
        // 保留为第二层防御。这里断言“不崩溃、被拒绝”。
        XCTAssertThrowsError(try parseUsageEvent(json), "超过递归深度的嵌套 payload 应在解码阶段被拒绝") { error in
            guard error is DecodingError else {
                XCTFail("应为 DecodingError，got \(error)")
                return
            }
        }
    }

    /// Timestamp fallback chain 5 个边界：duration 字段不能 preempt / 零 / 负数 / 过早 / 过晚
    func testParseUsageEventTimestampHandling() throws {
        let expected = try XCTUnwrap(DateParser.parse("2026-07-15T10:30:00Z"))
        // 1. duration 字段 (time_to_first_token / generation_time_ms) 不能 preempt real timestamp
        do {
            let durationFirst = """
            {
              "time_to_first_token": 123, "generation_time_ms": 456,
              "time": 1721034600, "created": 1721034700,
              "timestamp": "2026-07-15T10:30:00Z",
              "inputTokens": 100
            }
            """
            let event = try parseUsageEvent(durationFirst)
            XCTAssertEqual(event?.timestamp, expected, "duration 字段不能覆盖 real timestamp")
        }
        // 2. zero / 负数 epoch → fallback (不作为 timestamp)
        do {
            let zero = try parseUsageEvent(#"{"time":0,"inputTokens":100}"#)
            XCTAssertNil(zero?.timestamp, "epoch=0 应被拒绝")
            let negative = try parseUsageEvent(#"{"time":-1,"inputTokens":100}"#)
            XCTAssertNil(negative?.timestamp, "epoch=-1 应被拒绝")
        }
        // 3. epoch 过早 (2000-01-01 之前) / 过晚 (2100-01-01 之后) → 拒绝
        do {
            let tooEarly = try parseUsageEvent(#"{"timestamp":946684799,"inputTokens":100}"#)
            XCTAssertNil(tooEarly?.timestamp, "epoch<2000 应被拒绝")
            let tooLate = try parseUsageEvent(#"{"timestamp":4102444800000,"inputTokens":100}"#)
            XCTAssertNil(tooLate?.timestamp, "epoch>2100 应被拒绝")
        }
        // 4. 多个 timestamp 字段, 都无效 → fallback 到合法 epoch 字段
        do {
            let json = """
            { "timestamp": 123, "created": 1721034600000, "inputTokens": 100 }
            """
            let event = try parseUsageEvent(json)
            XCTAssertEqual(event?.timestamp?.timeIntervalSince1970 ?? 0, 1721034600, accuracy: 0.001,
                           "无效 timestamp 应 fallback 到合法 created 字段")
        }
    }

    /// 拒绝场景 3 in 1：空 payload / 无 token 字段 / 所有 token = 0
    func testParseUsageEventRejection() throws {
        // 1. 完全没有 token 字段 → 整个事件被丢弃
        let noTokens = try parseUsageEvent("""
        {
          "timestamp": "2026-07-15T10:30:00Z",
          "model": "gemini-2.5-pro"
        }
        """)
        XCTAssertNil(noTokens)
        // 2. 所有 token 都是 0 → 整个事件被丢弃 (不算有效用量)
        let allZero = try parseUsageEvent("""
        {
          "timestamp": "2026-07-15T10:30:00Z",
          "model": "gemini-2.5-pro",
          "inputTokens": 0, "outputTokens": 0, "reasoningTokens": 0
        }
        """)
        XCTAssertNil(allZero, "所有 token=0 的事件应被丢弃")
        // 3. 顶层 timestamp 字段缺失, 其他字段也没带 → 无效
        let noTimestamp = try parseUsageEvent(#"{"inputTokens":100,"model":"x"}"#)
        XCTAssertNotNil(noTimestamp, "无 timestamp 不应让事件无效 (其他字段有效)")
        XCTAssertNil(noTimestamp?.timestamp)
    }

    func testComputeTurnRoundDetailsSingleDay() {
        let day = testCalendar.startOfDay(for: Date())
        let ts = testCalendar.date(bySettingHour: 10, minute: 0, second: 0, of: day)!
        // 模拟 2 个 turn（Prompt 1: idx 2..3, Prompt 2: idx 6..7 Gap>1），共 4 个 rounds
        let stepIdxs: [[Int]] = [[2, 3], [3, 4], [6, 7], [7, 8]]
        let events: [AntigravityFetcher.UsageEvent] = (0..<4).map { i in
            AntigravityFetcher.UsageEvent(
                timestamp: ts,
                model: "test",
                inputTokens: 100, outputTokens: 50,
                cacheReadTokens: 0, cacheWriteTokens: 0,
                reasoningTokens: 0, totalTokens: 150,
                stepIndices: stepIdxs[i]
            )
        }

        let details = AntigravityLocalUsageScanner.computeTurnRoundDetails(
            sessionID: "test-session",
            events: events,
            calendar: testCalendar
        )

        XCTAssertEqual(details.counts.totalRounds, 4)
        XCTAssertEqual(details.counts.totalTurns, 2)
        XCTAssertEqual(details.counts.perDay[day]?.rounds, 4)
        XCTAssertEqual(details.counts.perDay[day]?.turns, 2)
        XCTAssertEqual(details.samples.count, 4)
    }

    func testComputeTurnRoundDetailsSpansMultipleDays() {
        let day14 = testCalendar.date(from: DateComponents(year: 2026, month: 7, day: 14))!
        let day15 = testCalendar.date(from: DateComponents(year: 2026, month: 7, day: 15))!
        let day14Ts = testCalendar.date(bySettingHour: 10, minute: 0, second: 0, of: day14)!
        let day15Ts = testCalendar.date(bySettingHour: 10, minute: 0, second: 0, of: day15)!

        let stepIdxs: [[Int]] = [[2, 3], [3, 4], [6, 7], [7, 8], [10, 11], [11, 12]]
        let events: [AntigravityFetcher.UsageEvent] = (0..<6).map { i in
            AntigravityFetcher.UsageEvent(
                timestamp: i < 4 ? day14Ts : day15Ts,
                model: "test",
                inputTokens: 100, outputTokens: 50,
                cacheReadTokens: 0, cacheWriteTokens: 0,
                reasoningTokens: 0, totalTokens: 150,
                stepIndices: stepIdxs[i]
            )
        }

        let details = AntigravityLocalUsageScanner.computeTurnRoundDetails(
            sessionID: "multi-day-session",
            events: events,
            calendar: testCalendar
        )

        XCTAssertEqual(details.counts.perDay[day14]?.rounds, 4)
        XCTAssertEqual(details.counts.perDay[day15]?.rounds, 2)
        XCTAssertEqual(details.counts.perDay[day14]?.turns, 2)
        XCTAssertEqual(details.counts.perDay[day15]?.turns, 1)
        XCTAssertEqual(details.counts.totalRounds, 6)
        XCTAssertEqual(details.counts.totalTurns, 3)
    }

    func testAntigravityDailyUsageIncludesTurnsAndRounds() {
        let day = Date()
        let usage = AntigravityDailyUsage(
            dayStart: day,
            inputTokens: 100, outputTokens: 50, totalTokens: 150,
            turns: 5, rounds: 25
        )
        XCTAssertEqual(usage.turns, 5)
        XCTAssertEqual(usage.rounds, 25)

        let combined = usage + AntigravityDailyUsage(
            dayStart: day,
            inputTokens: 200, outputTokens: 100, totalTokens: 300,
            turns: 3, rounds: 10
        )
        XCTAssertEqual(combined.turns, 8)
        XCTAssertEqual(combined.rounds, 35)
        XCTAssertEqual(combined.inputTokens, 300)
    }

    /// F1 回归：scanner 成功分支现在等价于
    ///   let details = computeTurnRoundDetails(...)
    ///   let newDaily = aggregateDaily(events:calendar:counts: details.counts)
    ///   let newSamples = details.samples
    /// 这里直接验证该路径：传入预计算 counts 后，turns/rounds 必须等于 details，
    /// 而不是旧实现叠加出的 2 倍；token 仍按饱和加法正确累加。
    func testF1AggregateDailyWithPrecomputedCountsDoesNotDoubleCount() {
        let day = testCalendar.startOfDay(for: Date())
        let ts = testCalendar.date(bySettingHour: 10, minute: 0, second: 0, of: day)!
        // 2 个 turn（idx 2..3/3..4 与 6..7/7..8，gap>1），共 4 个 rounds
        let stepIdxs: [[Int]] = [[2, 3], [3, 4], [6, 7], [7, 8]]
        let events: [AntigravityFetcher.UsageEvent] = (0..<4).map { i in
            AntigravityFetcher.UsageEvent(
                timestamp: ts,
                model: "test",
                inputTokens: 100, outputTokens: 50,
                cacheReadTokens: 10, cacheWriteTokens: 0,
                reasoningTokens: 5, totalTokens: 150,
                stepIndices: stepIdxs[i]
            )
        }

        let details = AntigravityLocalUsageScanner.computeTurnRoundDetails(
            sessionID: "f1-session",
            events: events,
            calendar: testCalendar
        )
        // 这正是 scanner 成功分支现在调用的聚合路径
        let byDay = AntigravityLocalUsageScanner.aggregateDaily(
            events: events,
            calendar: testCalendar,
            counts: details.counts
        )

        let key = LocalUsageDayKey.make(day, calendar: testCalendar)
        let usage = byDay[key]
        XCTAssertNotNil(usage)
        // turns/rounds 必须等于 details，不是 2 倍（旧 bug 在这里会得到 4/8）
        XCTAssertEqual(usage?.turns, details.counts.perDay[day]?.turns)
        XCTAssertEqual(usage?.rounds, details.counts.perDay[day]?.rounds)
        XCTAssertEqual(usage?.turns, 2)
        XCTAssertEqual(usage?.rounds, 4)
        // token 仍按饱和加法正确累加
        XCTAssertEqual(usage?.inputTokens, 400)
        XCTAssertEqual(usage?.outputTokens, 200)
        XCTAssertEqual(usage?.cacheReadTokens, 40)
        XCTAssertEqual(usage?.reasoningTokens, 20)
        XCTAssertEqual(usage?.totalTokens, 600)
    }

    /// F1：跨日 events 经 scanner 聚合路径后，每天 turns/rounds 等于 details，不翻倍。
    func testF1AggregateDailyCrossDayWithPrecomputedCounts() {
        let day14 = testCalendar.date(from: DateComponents(year: 2026, month: 7, day: 14))!
        let day15 = testCalendar.date(from: DateComponents(year: 2026, month: 7, day: 15))!
        let day14Ts = testCalendar.date(bySettingHour: 10, minute: 0, second: 0, of: day14)!
        let day15Ts = testCalendar.date(bySettingHour: 10, minute: 0, second: 0, of: day15)!

        let stepIdxs: [[Int]] = [[2, 3], [3, 4], [6, 7], [7, 8], [10, 11], [11, 12]]
        let events: [AntigravityFetcher.UsageEvent] = (0..<6).map { i in
            AntigravityFetcher.UsageEvent(
                timestamp: i < 4 ? day14Ts : day15Ts,
                model: "test",
                inputTokens: 100, outputTokens: 50,
                cacheReadTokens: 0, cacheWriteTokens: 0,
                reasoningTokens: 0, totalTokens: 150,
                stepIndices: stepIdxs[i]
            )
        }

        let details = AntigravityLocalUsageScanner.computeTurnRoundDetails(
            sessionID: "f1-cross-day",
            events: events,
            calendar: testCalendar
        )
        let byDay = AntigravityLocalUsageScanner.aggregateDaily(
            events: events,
            calendar: testCalendar,
            counts: details.counts
        )

        let key14 = LocalUsageDayKey.make(day14, calendar: testCalendar)
        let key15 = LocalUsageDayKey.make(day15, calendar: testCalendar)
        XCTAssertEqual(byDay[key14]?.turns, details.counts.perDay[day14]?.turns)
        XCTAssertEqual(byDay[key14]?.rounds, details.counts.perDay[day14]?.rounds)
        XCTAssertEqual(byDay[key15]?.turns, details.counts.perDay[day15]?.turns)
        XCTAssertEqual(byDay[key15]?.rounds, details.counts.perDay[day15]?.rounds)
        // day14: 2 turns / 4 rounds；day15: 1 turn / 2 rounds
        XCTAssertEqual(byDay[key14]?.turns, 2)
        XCTAssertEqual(byDay[key14]?.rounds, 4)
        XCTAssertEqual(byDay[key15]?.turns, 1)
        XCTAssertEqual(byDay[key15]?.rounds, 2)
    }

    /// F1：无 stepIndices 的事件，每个 event 计为 1 round，scanner 聚合路径不翻倍。
    func testF1AggregateDailyNoStepIndicesWithPrecomputedCounts() {
        let day = testCalendar.startOfDay(for: Date())
        let ts = testCalendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        let events: [AntigravityFetcher.UsageEvent] = (0..<3).map { _ in
            AntigravityFetcher.UsageEvent(
                timestamp: ts,
                model: "test",
                inputTokens: 50, outputTokens: 10,
                cacheReadTokens: 0, cacheWriteTokens: 0,
                reasoningTokens: 0, totalTokens: 60,
                stepIndices: nil
            )
        }

        let details = AntigravityLocalUsageScanner.computeTurnRoundDetails(
            sessionID: "f1-no-idx",
            events: events,
            calendar: testCalendar
        )
        let byDay = AntigravityLocalUsageScanner.aggregateDaily(
            events: events,
            calendar: testCalendar,
            counts: details.counts
        )

        let key = LocalUsageDayKey.make(day, calendar: testCalendar)
        // 无 stepIndices 时 prevMaxStepIndex 永不更新，按现有规则每个 event 各开一个 turn；
        // 这里只验证 F1：聚合后等于 details，而不是 2 倍。
        XCTAssertEqual(byDay[key]?.turns, details.counts.perDay[day]?.turns)
        XCTAssertEqual(byDay[key]?.rounds, details.counts.perDay[day]?.rounds)
        XCTAssertEqual(byDay[key]?.turns, 3)
        XCTAssertEqual(byDay[key]?.rounds, 3)
    }

    /// F1：默认调用（不传 counts）仍保持原有契约——等价于内部自行 computeTurnRoundCounts，
    /// 不得因为新增参数改变既有行为。
    func testF1AggregateDailyDefaultContractUnchanged() {
        let day = testCalendar.startOfDay(for: Date())
        let ts = testCalendar.date(bySettingHour: 11, minute: 0, second: 0, of: day)!
        let events: [AntigravityFetcher.UsageEvent] = [
            AntigravityFetcher.UsageEvent(
                timestamp: ts, model: "m",
                inputTokens: 100, outputTokens: 50,
                cacheReadTokens: 0, cacheWriteTokens: 0,
                reasoningTokens: 0, totalTokens: 150,
                stepIndices: [0, 1]
            ),
            AntigravityFetcher.UsageEvent(
                timestamp: ts, model: "m",
                inputTokens: 20, outputTokens: 5,
                cacheReadTokens: 0, cacheWriteTokens: 0,
                reasoningTokens: 0, totalTokens: 25,
                stepIndices: [1, 2]
            ),
        ]

        let withCounts = AntigravityLocalUsageScanner.aggregateDaily(
            events: events, calendar: testCalendar,
            counts: AntigravityLocalUsageScanner.computeTurnRoundCounts(
                sessionID: "", events: events, calendar: testCalendar
            )
        )
        let defaultAggregated = AntigravityLocalUsageScanner.aggregateDaily(
            events: events, calendar: testCalendar
        )

        XCTAssertEqual(defaultAggregated, withCounts, "未传 counts 时应与传入预算 counts 完全一致")
    }
}
