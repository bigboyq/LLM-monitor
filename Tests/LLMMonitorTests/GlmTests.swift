import XCTest
import SQLite3
@testable import LLM_monitor

final class GlmTests: XCTestCase {

    // MARK: - GLM Coding Plan Fetcher Tests

    private let successJSON = #"""
    {
      "code": 200,
      "msg": "Operation successful",
      "success": true,
      "data": {
        "level": "lite",
        "limits": [
          {
            "type": "CREDIT_LIMIT", "unit": 3, "number": 5,
            "usage": 2000, "currentValue": 114, "remaining": 1885,
            "percentage": 5, "nextResetTime": 1785486276273
          },
          {
            "type": "CREDIT_LIMIT", "unit": 6, "number": 1,
            "usage": 10000, "currentValue": 114, "remaining": 9885,
            "percentage": 1, "nextResetTime": 1786072666998
          }
        ]
      }
    }
    """#

    func testGlmCodingPlanFetcherParsingAndWindows() throws {
        let info = try GlmCodingPlanFetcher.parse(data: Data(successJSON.utf8))
        XCTAssertEqual(info.models.count, 1)
        let model = try XCTUnwrap(info.models.first)
        XCTAssertEqual(model.modelName, "glm_coding_plan")
        XCTAssertEqual(model.displayName, "GLM Coding Plan")
        XCTAssertEqual(model.intervalTotalCount, 2000)
        XCTAssertEqual(model.weeklyTotalCount, 10_000)

        // Classify limits by metadata
        let customJSON = #"""
        { "code": 200, "success": true, "data": { "level": "pro", "limits": [
          { "type":"CREDIT_LIMIT", "unit":6, "number":1, "usage":60000, "currentValue":12000, "remaining":48000, "nextResetTime": 1111111111111 },
          { "type":"CREDIT_LIMIT", "unit":3, "number":5, "usage":12000, "currentValue":12000, "remaining":0, "nextResetTime": 9999999999999 }
        ]}}
        """#
        let model2 = try XCTUnwrap(try GlmCodingPlanFetcher.parse(data: Data(customJSON.utf8)).models.first)
        XCTAssertEqual(model2.intervalTotalCount, 12_000)
        XCTAssertEqual(model2.weeklyTotalCount, 60_000)
    }

    func testGlmFetcherErrorHandling() throws {
        let authFailure = #"{"code":1000,"msg":"身份验证失败。","success":false}"#
        XCTAssertThrowsError(try GlmCodingPlanFetcher.parse(data: Data(authFailure.utf8)))
        XCTAssertThrowsError(try GlmCodingPlanFetcher.parse(data: Data(#"{"code":200,"success":true,"data":{"level":"lite","limits":[]}}"#.utf8)))
    }

    func testGlmMissingIntervalResetUsesFiveHourFallback() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let json = #"""
        {
          "code": 200,
          "success": true,
          "data": {
            "level": "lite",
            "limits": [
              { "type": "CREDIT_LIMIT", "unit": 3, "number": 5,
                "usage": 2000, "currentValue": 0, "remaining": 2000 },
              { "type": "CREDIT_LIMIT", "unit": 6, "number": 1,
                "usage": 10000, "currentValue": 0, "remaining": 10000,
                "nextResetTime": 1800600000000 }
            ]
          }
        }
        """#

        let model = try XCTUnwrap(
            try GlmCodingPlanFetcher.parse(data: Data(json.utf8), now: now).models.first
        )
        XCTAssertEqual(model.intervalResetsAt, now.addingTimeInterval(5 * 3600))
        XCTAssertEqual(model.weeklyResetsAt, Date(timeIntervalSince1970: 1_800_600_000))
    }

    // MARK: - GLM Peak Window Tests

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    private let peakWindow = GlmPeakWindow.zhipuDefault

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: 0, second: 0))!
    }

    func testGlmPeakWindowStatusRules() {
        XCTAssertEqual(peakWindow.status(at: date(2026, 7, 31, 15), calendar: cal), .peak(until: date(2026, 7, 31, 18)))
        XCTAssertEqual(peakWindow.status(at: date(2026, 7, 31, 10), calendar: cal), .offPeak(until: date(2026, 7, 31, 14)))
        XCTAssertEqual(peakWindow.status(at: date(2026, 8, 1, 15), calendar: cal), .offPeak(until: date(2026, 8, 3, 14)))

        let pc = ProviderConfig(enabled: true, apiKey: "k", peakStartHour: 9, peakEndHour: 12, peakWeekdaysOnly: false)
        XCTAssertEqual(pc.glmPeakWindow, GlmPeakWindow(startHour: 9, endHour: 12, weekdaysOnly: false))
    }

    // MARK: - GLM ZCode Local Usage Scanner Tests

    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private static func todayMidnight(calendar: Calendar) -> Date {
        calendar.startOfDay(for: Date())
    }

    private func ms(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private func makeDatabase() throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("glm-zcode-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw SQLiteConnectionError.openFailed(path: path, code: 0, extendedCode: 0, message: "open failed") }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE model_usage (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, turn_id TEXT,
            started_at INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'completed',
            model_id TEXT NOT NULL, provider_id TEXT NOT NULL DEFAULT 'builtin:bigmodel-coding-plan',
            input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0, cache_read_input_tokens INTEGER NOT NULL DEFAULT 0,
            cache_creation_input_tokens INTEGER NOT NULL DEFAULT 0, assistant_message_id TEXT
        );
        CREATE TABLE part (
            id TEXT PRIMARY KEY, message_id TEXT, data TEXT
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SQLiteConnectionError.openFailed(path: path, code: 0, extendedCode: 0, message: "create table failed") }
        return path
    }

    private func insert(databaseURL path: String, id: String, sessionID: String, turnID: String?, timestamp: Int64, input: Int, output: Int, reasoning: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, status: String = "completed", model: String = "GLM-5.2", provider: String = "builtin:bigmodel-coding-plan", assistantMessageID: String? = nil) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO model_usage (id, session_id, turn_id, started_at, status, model_id, provider_id, input_tokens, output_tokens, reasoning_tokens, cache_read_input_tokens, cache_creation_input_tokens, assistant_message_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (sessionID as NSString).utf8String, -1, nil)
        if let turnID { sqlite3_bind_text(stmt, 3, (turnID as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_int64(stmt, 4, timestamp)
        sqlite3_bind_text(stmt, 5, (status as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (model as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 7, (provider as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 8, Int32(input))
        sqlite3_bind_int(stmt, 9, Int32(output))
        sqlite3_bind_int(stmt, 10, Int32(reasoning))
        sqlite3_bind_int(stmt, 11, Int32(cacheRead))
        sqlite3_bind_int(stmt, 12, Int32(cacheWrite))
        if let assistantMessageID { sqlite3_bind_text(stmt, 13, (assistantMessageID as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 13) }
        sqlite3_step(stmt)
    }

    /// 插入一个 `part` 行。`data` 是 JSON 字符串（type='reasoning' / 'text' / 故意坏的 JSON）。
    private func insertPart(databaseURL path: String, id: String, messageID: String, jsonData: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO part (id, message_id, data) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (messageID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (jsonData as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    /// 合并测试：Method A 分类 + assistant_message_id NULL + 字符分摊 part 关联 + malformed JSON。
    /// 6 行 model_usage 覆盖所有 reasoning 路径（优先级：native > reasoning part > text only > NULL > malformed），
    /// 一天内聚合结果应严格符合 Method A 规则。
    func testGlmZcodeDBReaderMethodAClassification() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let day = Self.todayMidnight(calendar: utcCalendar())
        let ts = ms(day)
        let cal = utcCalendar()

        // R1: 账单层直接给 reasoning_tokens=20 → 优先级路径
        try insert(databaseURL: db, id: "r1", sessionID: "s", turnID: "t1", timestamp: ts,
                   input: 100, output: 30, reasoning: 20, assistantMessageID: "msg_r1")
        // R2: assistant_message_id + text part（无 reasoning part）→ output 保持
        try insertPart(databaseURL: db, id: "p_text", messageID: "msg_text", jsonData: #"{"type":"text","text":"hello"}"#)
        try insert(databaseURL: db, id: "r2", sessionID: "s", turnID: "t2", timestamp: ts + 1,
                   input: 100, output: 30, assistantMessageID: "msg_text")
        // R3: assistant_message_id + reasoning part → 整轮 output 归 reasoning
        try insertPart(databaseURL: db, id: "p_reason", messageID: "msg_reason", jsonData: #"{"type":"reasoning","text":"thinking..."}"#)
        try insert(databaseURL: db, id: "r3", sessionID: "s", turnID: "t3", timestamp: ts + 2,
                   input: 100, output: 30, assistantMessageID: "msg_reason")
        // R4: assistant_message_id + 同时有 reasoning 和 text parts → 走 Method A（EXISTS 命中 reasoning）
        try insertPart(databaseURL: db, id: "p_both_reason", messageID: "msg_both", jsonData: #"{"type":"reasoning","text":"think"}"#)
        try insertPart(databaseURL: db, id: "p_both_text", messageID: "msg_both", jsonData: #"{"type":"text","text":"answer"}"#)
        try insert(databaseURL: db, id: "r4", sessionID: "s", turnID: "t4", timestamp: ts + 3,
                   input: 100, output: 30, assistantMessageID: "msg_both")
        // R5: assistant_message_id + 损坏 JSON → json_valid fallback 到 {} → 走 output
        try insertPart(databaseURL: db, id: "p_bad_json", messageID: "msg_bad_json", jsonData: "{invalid")
        try insert(databaseURL: db, id: "r5", sessionID: "s", turnID: "t5", timestamp: ts + 4,
                   input: 100, output: 30, assistantMessageID: "msg_bad_json")
        // R6: assistant_message_id = NULL → 没 part 可 join → output 保持
        try insert(databaseURL: db, id: "r6", sessionID: "s", turnID: "t6", timestamp: ts + 5,
                   input: 100, output: 30, assistantMessageID: nil)
        // R7: native reasoning 与 reasoning part 同时命中 → native priority wins
        try insertPart(databaseURL: db, id: "p_priority", messageID: "msg_priority", jsonData: #"{"type":"reasoning","text":"thinking"}"#)
        try insert(databaseURL: db, id: "r7", sessionID: "s", turnID: "t7", timestamp: ts + 6,
                   input: 100, output: 30, reasoning: 25, assistantMessageID: "msg_priority")

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)
        let today = try XCTUnwrap(aggregate.perDay[day])

        // 7 行 input 累计 700; cacheRead 0
        XCTAssertEqual(today.inputTokens, 700)
        // tout = R1(30) + R2(30) + R3(0) + R4(0) + R5(30) + R6(30) + R7(30) = 150
        XCTAssertEqual(today.outputTokens, 150)
        // trsn = R1(20) + R2(0) + R3(30) + R4(30) + R5(0) + R6(0) + R7(25) = 105
        XCTAssertEqual(today.reasoningTokens, 105)
        XCTAssertEqual(today.rounds, 7)
        XCTAssertEqual(today.turns, 7)

        // 守恒: total = uncached input + cacheRead + tout + trsn
        XCTAssertEqual(today.totalTokens, today.inputTokens + today.cacheReadTokens + today.outputTokens + today.reasoningTokens)
    }

    /// R9: 单行负 token 不能抵消其他行的合法正值；所有公开字段保持 0...Int.max。
    /// 混合行（input=-100, output=200，WHERE 求和=100>0 被纳入）的负 input 按 0 计。
    func testR9GlmNegativeTokensDoNotCancelPositives() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let day = Self.todayMidnight(calendar: utcCalendar())
        let ts = ms(day)
        let cal = utcCalendar()

        // 正行：input=100, output=50
        try insert(databaseURL: db, id: "pos", sessionID: "s", turnID: "t1", timestamp: ts,
                   input: 100, output: 50)
        // 混合行：input=-100, output=200（input+output=100>0，被纳入）
        try insert(databaseURL: db, id: "neg", sessionID: "s", turnID: "t2", timestamp: ts + 1,
                   input: -100, output: 200)

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)
        let today = try XCTUnwrap(aggregate.perDay[day])

        // input = max(100,0) + max(-100,0) = 100（不是 0）；cacheRead=0
        XCTAssertEqual(today.inputTokens, 100, "负 input 不得抵消正 input")
        // output = 50 + 200 = 250
        XCTAssertEqual(today.outputTokens, 250)
        // 所有字段非负
        XCTAssertGreaterThanOrEqual(today.inputTokens, 0)
        XCTAssertGreaterThanOrEqual(today.outputTokens, 0)
        XCTAssertGreaterThanOrEqual(today.totalTokens, 0)
    }

    /// 2026-09-17 Zcode `0020_provider_model_selection` 迁移：登录账号套餐改写
    /// `account:bigmodel-` 前缀。同一天新旧前缀混写（真实迁移日的形态）时，
    /// 聚合 / totals / 样本都必须把两种前缀的智谱行都算进来，非智谱行仍排除；
    /// `account:bigmodel-*-coding-plan` 归日常任务，`account:` 体验套餐归其他。
    func testGlmZcodeReaderIncludesAccountPrefixAfterMigration() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let day = Self.todayMidnight(calendar: utcCalendar())
        let ts = ms(day)
        let cal = utcCalendar()

        // 迁移前后各 2 行正式 Coding Plan（builtin: / account:）
        try insert(databaseURL: db, id: "b1", sessionID: "s1", turnID: "t1", timestamp: ts,
                   input: 100, output: 10, provider: "builtin:bigmodel-coding-plan")
        try insert(databaseURL: db, id: "b2", sessionID: "s1", turnID: "t2", timestamp: ts + 1,
                   input: 100, output: 10, provider: "builtin:bigmodel-coding-plan")
        try insert(databaseURL: db, id: "a1", sessionID: "s2", turnID: "t3", timestamp: ts + 2,
                   input: 200, output: 20, provider: "account:bigmodel-individual-coding-plan")
        try insert(databaseURL: db, id: "a2", sessionID: "s2", turnID: "t4", timestamp: ts + 3,
                   input: 200, output: 20, provider: "account:bigmodel-individual-coding-plan")
        // account: 前缀的体验套餐 → 柱图计入，额度窗口归「其他」
        try insert(databaseURL: db, id: "a3", sessionID: "s3", turnID: "t5", timestamp: ts + 4,
                   input: 1000, output: 5, provider: "account:bigmodel-start-plan")
        // 闲时任务照旧精确匹配
        try insert(databaseURL: db, id: "o1", sessionID: "s3", turnID: "t6", timestamp: ts + 5,
                   input: 500, output: 5, provider: "offpeak-idle-plan")
        // 非智谱 provider 不得进入 GLM 卡
        try insert(databaseURL: db, id: "x1", sessionID: "s4", turnID: "t7", timestamp: ts + 6,
                   input: 999, output: 99, provider: "builtin:other-provider")

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)
        let today = try XCTUnwrap(aggregate.perDay[day])

        // 6 行智谱全计入（x1 排除）：rounds / input / output
        XCTAssertEqual(today.rounds, 6, "account: 前缀的行不得被漏采")
        XCTAssertEqual(today.inputTokens, 100 + 100 + 200 + 200 + 1000 + 500)
        XCTAssertEqual(today.outputTokens, 10 + 10 + 20 + 20 + 5 + 5)
        // totals 同口径：roundCount 含 account: 行，session 去重 s1/s2/s3
        XCTAssertEqual(aggregate.roundCount, 6)
        XCTAssertEqual(aggregate.sessionCount, 3)

        // 样本层分类：account coding-plan 归日常，account 体验套餐归其他
        let samplesByProvider = Dictionary(aggregate.samples.map { ($0.sourceProviderID ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(GlmUsageCategory.classify(samplesByProvider["account:bigmodel-individual-coding-plan"]!), .normal)
        XCTAssertEqual(GlmUsageCategory.classify(samplesByProvider["account:bigmodel-start-plan"]!), .other)
        XCTAssertEqual(GlmUsageCategory.classify(samplesByProvider["builtin:bigmodel-coding-plan"]!), .normal)
        XCTAssertEqual(GlmUsageCategory.classify(samplesByProvider["offpeak-idle-plan"]!), .offPeak)
        XCTAssertNil(samplesByProvider["builtin:other-provider"], "非智谱 provider 不应产出样本")
    }

    /// 合并测试：native reasoning 聚合 + sample 分配 + snapshot 7 天 padding。
    /// 覆盖：账单层 reasoning_tokens 优先级（per-day + samples 同步）、promptID 命名（turn vs event fallback）、
    /// buildSnapshot 7 天窗口、today 挑选、recentSamples 保留。
    func testGlmZcodeDBReaderNativeAndSnapshot() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let day = Self.todayMidnight(calendar: utcCalendar())
        let cal = utcCalendar()

        // 3 行同 session 同 turn + 1 行 turn=NULL（测 event-id fallback）+ 1 行其他 turn
        try insert(databaseURL: db, id: "u1", sessionID: "s1", turnID: "t1", timestamp: ms(day),
                   input: 300, output: 10, reasoning: 5, cacheRead: 200, cacheWrite: 30)
        try insert(databaseURL: db, id: "u2", sessionID: "s1", turnID: "t1", timestamp: ms(day) + 1000,
                   input: 200, output: 8, reasoning: 2, cacheRead: 150)
        try insert(databaseURL: db, id: "u3", sessionID: "s1", turnID: "t2", timestamp: ms(day) + 2000,
                   input: 60, output: 4, reasoning: 1, cacheRead: 40)
        // 没有 assistant_message_id → 也不会被归为 reasoning,仍走 native 路径
        try insert(databaseURL: db, id: "u4", sessionID: "s2", turnID: nil, timestamp: ms(day) + 3000,
                   input: 100, output: 6, reasoning: 3, cacheRead: 50)

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)
        let today = try XCTUnwrap(aggregate.perDay[day])

        // uncached input = max(SUM(input_tokens) - SUM(cache_read_input_tokens), 0) = max(660-440, 0) = 220
        XCTAssertEqual(today.inputTokens, 220)
        // native path (reasoning_tokens > 0): tout = output_tokens 原值, trsn = reasoning_tokens 原值（独立加总, 不做"重分类"）
        XCTAssertEqual(today.outputTokens, 28, "10+8+4+6")
        XCTAssertEqual(today.reasoningTokens, 11, "5+2+1+3")
        XCTAssertEqual(today.cacheReadTokens, 440)
        XCTAssertEqual(today.cacheWriteTokens, 30)
        XCTAssertEqual(today.rounds, 4)
        // COUNT(DISTINCT turn_id) 排除 NULL: u1+u2 共 t1, u3=t2, u4=NULL → 2 distinct (t1, t2)
        XCTAssertEqual(today.turns, 2)

        // Sample 分配: 4 条 sample,promptID 命名 (turn 存在 → session:turn; null → session:event-id)
        XCTAssertEqual(aggregate.samples.count, 4)
        let promptIDs = Set(aggregate.samples.map(\.promptID))
        XCTAssertTrue(promptIDs.contains("s1:t1"))
        XCTAssertTrue(promptIDs.contains("s1:t2"))
        XCTAssertTrue(promptIDs.contains("s2:event-u4"), "turn=NULL fallback to event-<id>")
        // samples 按 started_at 升序
        XCTAssertEqual(aggregate.samples.map(\.outputTokens), [10, 8, 4, 6])

        // Snapshot 7 天 padding + today 挑选 + recentSamples 保留
        let snapshot = GlmZcodeLocalUsageScanner.buildSnapshot(
            adjustedPerDay: aggregate.perDay,
            sessionCount: 2, roundCount: 4, samples: aggregate.samples,
            offPeakWindows: [],
            calendar: cal, now: day
        )
        XCTAssertEqual(snapshot.dailyTokenUsage.count, 7)
        XCTAssertEqual(snapshot.today?.dayStart, day)
        XCTAssertEqual(snapshot.recentSamples?.count, 4)
        XCTAssertEqual(snapshot.eventCount, 4)
        XCTAssertEqual(snapshot.sessionCount, 2)
    }

    /// 回归：ZCode 闲时任务的 `model_usage` 行落在独立的 `offpeak-idle-plan` provider，
    /// 不是 `builtin:bigmodel-coding-plan`。scanner 必须两个 provider 都读，才能让
    /// 今日 / 7 天柱图包含闲时任务的真实 token 消耗；额度窗口 hover 靠 `excludeWindows`
    /// 按 off_peak 时间窗口把它们排除（不消耗 Coding Plan 积分）。
    func testGlmZcodeDBReaderIncludesOffPeakProviderRows() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let day = Self.todayMidnight(calendar: utcCalendar())
        let cal = utcCalendar()
        let offPeakStart = day.addingTimeInterval(3600)
        let offPeakEnd = day.addingTimeInterval(7200)

        // 2 行 coding-plan（正常交互）：input=100+200, cacheRead=50+50
        try insert(databaseURL: db, id: "c1", sessionID: "s1", turnID: "t1", timestamp: ms(day),
                   input: 100, output: 10, cacheRead: 50)
        try insert(databaseURL: db, id: "c2", sessionID: "s1", turnID: "t2", timestamp: ms(day) + 1000,
                   input: 200, output: 20, cacheRead: 50)
        // 1 行闲时任务（offpeak-idle-plan）：落在 off_peak 窗口内,大额 cacheRead
        try insert(databaseURL: db, id: "o1", sessionID: "s2", turnID: "t1",
                   timestamp: ms(offPeakStart) + 500,
                   input: 1000, output: 100, cacheRead: 900,
                   provider: OpencodeLocalUsage.zcodeOffPeakProviderID)

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)
        let today = try XCTUnwrap(aggregate.perDay[day])

        // 今日柱图包含闲时任务：uncached input = max(1300 - 1000, 0) = 300, cacheRead = 1000
        XCTAssertEqual(today.inputTokens, 300, "coding-plan 300 + off-peak 1000 → uncached = max(1300-1000,0) = 300")
        XCTAssertEqual(today.cacheReadTokens, 1000, "50+50+900，闲时任务的 cacheRead 进入柱图")
        XCTAssertEqual(today.rounds, 3)

        // recentSamples 也包含闲时任务行
        XCTAssertEqual(aggregate.samples.count, 3)

        // 额度窗口 summary：提供 excludeWindows 时排除闲时任务行，只留 2 行 coding-plan
        let window = GlmOffPeakWindow(startedAt: offPeakStart, endedAt: offPeakEnd)
        let summary = LocalUsageSummaryBuilder.summary(
            samples: aggregate.samples,
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: day, end: day.addingTimeInterval(86400),
            excludeWindows: [window]
        )
        XCTAssertEqual(summary?.rounds, 2)
        XCTAssertEqual(summary?.cachedInputTokens, 100, "闲时任务 cacheRead 900 被排除")

        // 不带 excludeWindows → 闲时任务也会进入窗口统计（防御：若未来去掉排除要留意图层）
        let rawSummary = LocalUsageSummaryBuilder.summary(
            samples: aggregate.samples,
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: day, end: day.addingTimeInterval(86400)
        )
        XCTAssertEqual(rawSummary?.rounds, 3)
    }

    func testGlmCachedSnapshotRebaseRefreshesTimestampAndUsesOnlyActiveToday() {
        let cal = utcCalendar()
        let yesterday = cal.date(byAdding: .day, value: -1, to: Self.todayMidnight(calendar: cal))!
        let now = cal.date(byAdding: .hour, value: 1, to: Self.todayMidnight(calendar: cal))!
        let oldScan = now.addingTimeInterval(-3600)
        let previousDay = GlmDailyUsage(
            dayStart: yesterday, inputTokens: 10, outputTokens: 5,
            cacheReadTokens: 0, cacheWriteTokens: 0, reasoningTokens: 0,
            totalTokens: 15, turns: 1, rounds: 1
        )
        let snapshot = GlmLocalUsage(
            today: previousDay,
            dailyTokenUsage: [previousDay],
            scannedAt: oldScan,
            sessionCount: 1,
            eventCount: 1,
            failedSessionCount: 0,
            recentSamples: []
        )

        let rebased = GlmZcodeLocalUsageScanner.rebaseCachedSnapshot(snapshot, calendar: cal, now: now)

        XCTAssertEqual(rebased.scannedAt, now)
        XCTAssertNil(rebased.today, "空的今天不应伪装成有活动的 today 快照")
        XCTAssertEqual(rebased.dailyTokenUsage.count, 7)
    }

    func testGlmReaderAppliesRecentCutoffToDailyAggregation() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let cal = utcCalendar()
        let today = Self.todayMidnight(calendar: cal)
        let oldDay = cal.date(byAdding: .day, value: -10, to: today)!

        try insert(databaseURL: db, id: "old", sessionID: "s-old", turnID: "t-old", timestamp: ms(oldDay),
                   input: 100, output: 10)
        try insert(databaseURL: db, id: "recent", sessionID: "s-recent", turnID: "t-recent", timestamp: ms(today),
                   input: 200, output: 20)

        let cutoff = cal.date(byAdding: .day, value: -8, to: today)!
        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(
            dbPath: URL(fileURLWithPath: db), calendar: cal, sampleCutoff: cutoff
        )

        XCTAssertNil(aggregate.perDay[oldDay], "日聚合不应为窗口外历史数据做全表分组")
        XCTAssertNotNil(aggregate.perDay[today])
        XCTAssertEqual(aggregate.samples.map(\.promptID), ["s-recent:t-recent"])
    }

    func testGlmUsageProjectionCombinesZcodeAndOpencode() {
        let day = Self.todayMidnight(calendar: .current)
        let nativeDay = GlmDailyUsage(
            dayStart: day, inputTokens: 100, outputTokens: 50,
            cacheReadTokens: 30, cacheWriteTokens: 10, reasoningTokens: 20,
            totalTokens: 200, turns: 2, rounds: 3
        )
        let sample1 = LocalTokenUsageSample(
            completedAt: Date(), modelName: "glm-4", promptID: "native:1",
            inputTokens: 100, cachedInputTokens: 0, outputTokens: 50, reasoningOutputTokens: 0
        )
        let native = GlmLocalUsage(
            today: nativeDay, dailyTokenUsage: [nativeDay], scannedAt: Date(timeIntervalSince1970: 1000),
            sessionCount: 2, eventCount: 3, failedSessionCount: 0,
            recentSamples: [sample1]
        )

        let openDay = OpencodeDailyUsage(
            dayStart: day, inputTokens: 200, outputTokens: 80,
            cacheReadTokens: 40, cacheWriteTokens: 15, reasoningTokens: 30,
            turns: 3, rounds: 4
        )
        let sample2 = LocalTokenUsageSample(
            completedAt: Date(), modelName: "glm-4", promptID: "p1",
            inputTokens: 200, cachedInputTokens: 0, outputTokens: 80, reasoningOutputTokens: 0
        )
        let opencode = OpencodeProviderUsage(
            today: openDay, dailyTokenUsage: [openDay], roundCount: 4, cost: 0.0,
            recentSamples: [sample2]
        )

        // 生产路径：usageProjection 把 ZCode native 与 OpenCode glm 分片按日相加。
        var status = ProviderStatus(
            id: "glm", displayName: "GLM", kind: .glmCodingPlan,
            iconSystemName: "circle", accentColor: .glm,
            refreshIntervalSeconds: 300, state: .ready
        )
        status.glmLocalUsage = native
        status.opencodeUsage = OpencodeLocalUsage(
            byProvider: [OpencodeLocalUsage.glmProviderID: opencode],
            modelsByProvider: [:], dbPath: nil, scannedAt: nil
        )
        status.mergeOpencodeUsage = true

        let projection = status.usageProjection(for: nil)
        XCTAssertEqual(projection.clientIDs, [ClientID.zcode, ClientID.openCode])
        let mergedToday = try! XCTUnwrap(projection.dailyTokenUsage.first)
        XCTAssertEqual(mergedToday.input, 300)
        XCTAssertEqual(mergedToday.output, 130)
        XCTAssertEqual(mergedToday.cacheRead, 70)
        XCTAssertEqual(mergedToday.cacheWrite, 25)
        XCTAssertEqual(mergedToday.reasoning, 50)

        // Verify recentSamples promptID namespacing
        let sampleIDs = projection.recentSamples.map { $0.promptID }
        XCTAssertTrue(sampleIDs.contains("native:1"))
        XCTAssertTrue(sampleIDs.contains("opencode:\(OpencodeLocalUsage.glmProviderID):p1"))
    }

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

    func testGlmCodingPlanFetcherErrorPaths() {
        let invalidCountJSON = #"""
        {
          "code": 200, "success": true,
          "data": {
            "level": "lite",
            "limits": [
              { "type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 100, "remaining": 150, "total": 100 }
            ]
          }
        }
        """#
        XCTAssertThrowsError(try GlmCodingPlanFetcher.parse(data: Data(invalidCountJSON.utf8)))
    }

    func testGlmRestoresCachedUsageOnColdStart() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-prefill-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManagerBox()
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = GlmLocalUsage(
            today: GlmDailyUsage(dayStart: day, inputTokens: 7, outputTokens: 4, rounds: 1),
            dailyTokenUsage: [GlmDailyUsage(dayStart: day, inputTokens: 7, outputTokens: 4, rounds: 1)],
            scannedAt: day, sessionCount: 1, eventCount: 1, failedSessionCount: 0,
            recentSamples: []
        )
        let index = GlmZcodeLocalUsageScanner.CacheIndex(
            // 引用当前版本常量：升版后旧缓存必须被拒读（触发重扫），冷启动恢复
            // 只对当前版本的缓存生效。
            version: GlmZcodeLocalUsageScanner.cacheIndexVersion,
            dbMtimeMs: 1,
            dbSizeBytes: 2,
            walMtimeMs: 0,
            walSizeBytes: 0,
            snapshot: snapshot,
            calendarSignature: LocalUsageCalendarSignature.make(.autoupdatingCurrent)
        )
        try GlmZcodeLocalUsageScanner.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        XCTAssertEqual(
            GlmZcodeLocalUsageScanner.loadCachedResult(
                cacheDir: cacheDir, fileManager: fileManager
            ),
            snapshot
        )
    }

    // MARK: - GLM Off-Peak (闲时任务) Tests

    /// 闲时窗口的 contains 边界：闭区间 + 2 秒容差。off_peak.ended_at 与最后一轮
    /// model_usage.completed_at 实测差 ~1 秒，容差确保边界 round 不被误判。
    func testGlmOffPeakWindowContainsWithTolerance() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)
        let window = GlmOffPeakWindow(startedAt: start, endedAt: end)

        // 窗口内
        XCTAssertTrue(window.contains(Date(timeIntervalSince1970: 1_500)))
        // 闭区间边界
        XCTAssertTrue(window.contains(start))
        XCTAssertTrue(window.contains(end))
        // 容差内（ended + 1.5s）
        XCTAssertTrue(window.contains(end.addingTimeInterval(1.5)))
        // 容差外（ended + 3s）
        XCTAssertFalse(window.contains(end.addingTimeInterval(3)))
        // 容差下沿（start - 1.5s，容差内）
        XCTAssertTrue(window.contains(start.addingTimeInterval(-1.5)))
        // 窗口前（start - 3s，超出容差）
        XCTAssertFalse(window.contains(start.addingTimeInterval(-3)))
    }

    /// 额度窗口 summary 排除落在闲时窗口内的 sample；本地柱图（不走 summary）仍保留。
    func testGlmSummaryExcludesOffPeakWindows() {
        let peakStart = Date(timeIntervalSince1970: 1_000)
        let peakEnd = Date(timeIntervalSince1970: 1_100)
        let offPeak = GlmOffPeakWindow(startedAt: peakStart, endedAt: peakEnd)

        // 3 个 GLM sample：闲时前 / 闲时内 / 闲时后
        let before = LocalTokenUsageSample(
            completedAt: Date(timeIntervalSince1970: 900),
            modelName: "GLM-5.2", promptID: "p1",
            inputTokens: 100, cachedInputTokens: 0, outputTokens: 10, reasoningOutputTokens: 0
        )
        let during = LocalTokenUsageSample(
            completedAt: Date(timeIntervalSince1970: 1_050),
            modelName: "GLM-5.2", promptID: "p2",
            inputTokens: 500, cachedInputTokens: 0, outputTokens: 50, reasoningOutputTokens: 0
        )
        let after = LocalTokenUsageSample(
            completedAt: Date(timeIntervalSince1970: 1_200),
            modelName: "GLM-5.2", promptID: "p3",
            inputTokens: 200, cachedInputTokens: 0, outputTokens: 20, reasoningOutputTokens: 0
        )

        // 不排除 → 3 个 sample 全算
        let allSummary = LocalUsageSummaryBuilder.summary(
            samples: [before, during, after],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: nil, end: nil
        )
        XCTAssertEqual(allSummary?.rounds, 3)
        XCTAssertEqual(allSummary?.inputTokens, 800)

        // 排除闲时窗口 → 只剩 before + after（during 被过滤）
        let filteredSummary = LocalUsageSummaryBuilder.summary(
            samples: [before, during, after],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: nil, end: nil,
            excludeWindows: [offPeak]
        )
        XCTAssertEqual(filteredSummary?.rounds, 2)
        XCTAssertEqual(filteredSummary?.inputTokens, 300)  // 100 + 200，不含 500
    }

    /// 正常 coding-plan 请求可以与后台闲时任务并发。provider 身份已知时必须优先
    /// 使用身份分类，不能把同一时间窗口内的正常请求或 OpenCode 合并请求排除。
    func testGlmSummaryUsesProviderIdentityBeforeOffPeakTimeWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 1_100)
        let window = GlmOffPeakWindow(startedAt: start, endedAt: end)

        func sample(_ providerID: String?, promptID: String, input: Int) -> LocalTokenUsageSample {
            LocalTokenUsageSample(
                completedAt: Date(timeIntervalSince1970: 1_050),
                modelName: "GLM-5.2",
                promptID: promptID,
                inputTokens: input,
                cachedInputTokens: 0,
                outputTokens: 1,
                reasoningOutputTokens: 0,
                sourceProviderID: providerID
            )
        }

        let normal = sample(OpencodeLocalUsage.zcodeGlmProviderID, promptID: "normal:t1", input: 100)
        let idle = sample(OpencodeLocalUsage.zcodeOffPeakProviderID, promptID: "idle:t1", input: 500)
        let opencode = sample(nil, promptID: "opencode:zhipuai-coding-plan:p1", input: 200)

        let summary = LocalUsageSummaryBuilder.summary(
            samples: [normal, idle, opencode],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: nil,
            end: nil,
            excludeWindows: [window]
        )
        XCTAssertEqual(summary?.rounds, 2)
        XCTAssertEqual(summary?.inputTokens, 300, "只排除明确标记为 offpeak-idle-plan 的样本")

        let summaryWithoutTaskWindows = LocalUsageSummaryBuilder.summary(
            samples: [normal, idle, opencode],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: nil,
            end: nil,
            excludeGlmOffPeak: true
        )
        XCTAssertEqual(summaryWithoutTaskWindows?.rounds, 2)
        XCTAssertEqual(
            summaryWithoutTaskWindows?.inputTokens,
            300,
            "任务库不可读时仍应按 provider 身份排除闲时样本"
        )

        let idleSummary = LocalUsageSummaryBuilder.offPeakTodaySummary(
            samples: [normal, idle, opencode],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            offPeakWindows: [window],
            now: Date(timeIntervalSince1970: 1_050),
            calendar: utcCalendar()
        )
        XCTAssertEqual(idleSummary?.rounds, 1)
        XCTAssertEqual(idleSummary?.inputTokens, 500)
    }

    /// 「其他」智谱套餐（`builtin:bigmodel-` 前缀但非 coding-plan，如体验套餐
    /// `builtin:bigmodel-start-plan`）不消耗 Coding Plan 积分：额度窗口统计必须
    /// 排除，且不能误伤同期的正常任务 / OpenCode / DSH 合并样本。
    func testGlmSummaryExcludesOtherBigmodelPlans() {
        func sample(_ providerID: String?, promptID: String, input: Int) -> LocalTokenUsageSample {
            LocalTokenUsageSample(
                completedAt: Date(timeIntervalSince1970: 1_050),
                modelName: "GLM-5.3-Flash",
                promptID: promptID,
                inputTokens: input,
                cachedInputTokens: 0,
                outputTokens: 1,
                reasoningOutputTokens: 0,
                sourceProviderID: providerID
            )
        }

        let normal = sample(OpencodeLocalUsage.zcodeGlmProviderID, promptID: "normal:t1", input: 100)
        let trial = sample("builtin:bigmodel-start-plan", promptID: "trial:t1", input: 500)
        let future = sample("builtin:bigmodel-weekend-plan", promptID: "future:t1", input: 700)
        let opencode = sample("dsh:zhipuai-coding-plan", promptID: "opencode:zhipuai-coding-plan:p1", input: 200)
        // 0020_provider_model_selection 迁移后的 account: 前缀形态
        let accountNormal = sample("account:bigmodel-individual-coding-plan", promptID: "account:t1", input: 300)
        let accountTrial = sample("account:bigmodel-start-plan", promptID: "account-trial:t1", input: 400)

        XCTAssertTrue(LocalUsageSummaryBuilder.isGlmOtherPlanSample(trial))
        XCTAssertTrue(LocalUsageSummaryBuilder.isGlmOtherPlanSample(future))
        XCTAssertTrue(LocalUsageSummaryBuilder.isGlmOtherPlanSample(accountTrial))
        XCTAssertFalse(LocalUsageSummaryBuilder.isGlmOtherPlanSample(normal))
        XCTAssertFalse(LocalUsageSummaryBuilder.isGlmOtherPlanSample(accountNormal))
        XCTAssertFalse(LocalUsageSummaryBuilder.isGlmOtherPlanSample(opencode))
        // 旧缓存没有来源标记 → 保持时间窗口回退语义，不算「其他」
        XCTAssertFalse(
            LocalUsageSummaryBuilder.isGlmOtherPlanSample(sample(nil, promptID: "legacy:t1", input: 1))
        )

        let summary = LocalUsageSummaryBuilder.summary(
            samples: [normal, trial, future, opencode],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: nil,
            end: nil,
            excludeGlmOffPeak: true
        )
        XCTAssertEqual(summary?.rounds, 2)
        XCTAssertEqual(summary?.inputTokens, 300, "start-plan 等其他智谱套餐不计入额度窗口")

        // 无排除口径时全部计入（与闲时任务的柱图口径一致）
        let allSummary = LocalUsageSummaryBuilder.summary(
            samples: [normal, trial, future, opencode],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: nil,
            end: nil
        )
        XCTAssertEqual(allSummary?.rounds, 4)
        XCTAssertEqual(allSummary?.inputTokens, 1_500)
    }

    /// DB reader 按 `builtin:bigmodel-%` 前缀通配覆盖未来智谱套餐（体验套餐等）：
    /// 这些行的 token 计入柱图聚合、样本保留 provider 身份；非智谱 provider
    /// （不带前缀）即使模型名带 glm 也不能进 GLM 卡。
    func testGlmZcodeDBReaderIncludesBigmodelPrefixPlans() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let day = Self.todayMidnight(calendar: utcCalendar())
        let ts = ms(day)
        let cal = utcCalendar()

        try insert(databaseURL: db, id: "cp", sessionID: "s1", turnID: "t1", timestamp: ts,
                   input: 100, output: 10, model: "GLM-5.3", provider: "builtin:bigmodel-coding-plan")
        try insert(databaseURL: db, id: "trial", sessionID: "s2", turnID: "t2", timestamp: ts + 1,
                   input: 500, output: 20, model: "GLM-5.3-Flash", provider: "builtin:bigmodel-start-plan")
        try insert(databaseURL: db, id: "future", sessionID: "s3", turnID: "t3", timestamp: ts + 2,
                   input: 700, output: 30, model: "GLM-6", provider: "builtin:bigmodel-future-plan")
        try insert(databaseURL: db, id: "offpeak", sessionID: "s4", turnID: "t4", timestamp: ts + 3,
                   input: 900, output: 40, model: "GLM-5.3", provider: "offpeak-idle-plan")
        try insert(databaseURL: db, id: "foreign", sessionID: "s5", turnID: "t5", timestamp: ts + 4,
                   input: 5_000, output: 50, model: "GLM-5.3", provider: "some-other-provider")

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)
        let today = try XCTUnwrap(aggregate.perDay[day])

        // 柱图口径：coding-plan + start-plan + future-plan + offpeak 全部计入，foreign 排除
        XCTAssertEqual(today.inputTokens, 100 + 500 + 700 + 900)
        XCTAssertEqual(aggregate.roundCount, 4)
        XCTAssertEqual(aggregate.sessionCount, 4)

        // 样本保留 provider 身份，供额度窗口白名单判定
        let providerIDs = Set(aggregate.samples.map { $0.sourceProviderID ?? "nil" })
        XCTAssertEqual(
            providerIDs,
            [
                "builtin:bigmodel-coding-plan",
                "builtin:bigmodel-start-plan",
                "builtin:bigmodel-future-plan",
                "offpeak-idle-plan"
            ]
        )
    }

    /// "今日闲时" 单独展示：只取今日落在 off_peak 窗口内的 native 样本；
    /// 非今日 / 窗口外 / OpenCode 合并样本都不算闲时。
    func testGlmOffPeakTodaySummary() {
        let cal = utcCalendar()
        let today = Self.todayMidnight(calendar: cal)
        let window = GlmOffPeakWindow(startedAt: today.addingTimeInterval(3600),
                                      endedAt: today.addingTimeInterval(7200))

        func sample(_ seconds: TimeInterval, input: Int, promptID: String) -> LocalTokenUsageSample {
            LocalTokenUsageSample(
                completedAt: today.addingTimeInterval(seconds),
                modelName: "GLM-5.2", promptID: promptID,
                inputTokens: input, cachedInputTokens: 0, outputTokens: 1, reasoningOutputTokens: 0
            )
        }
        let inWindow = sample(5400, input: 500, promptID: "s1:t1")   // 窗口内，今日 → 闲时
        let outsideWindow = sample(9000, input: 300, promptID: "s1:t2") // 今日但窗口外 → 不算
        let opencode = sample(5400, input: 700, promptID: "opencode:zhipuai-coding-plan:p1") // 窗口内但是 OpenCode → 不算
        let yesterday = sample(-86_400 + 5400, input: 200, promptID: "s2:t1") // 窗口内但昨天 → 不算

        let summary = LocalUsageSummaryBuilder.offPeakTodaySummary(
            samples: [inWindow, outsideWindow, opencode, yesterday],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            offPeakWindows: [window],
            now: today.addingTimeInterval(10_000),
            calendar: cal
        )
        XCTAssertEqual(summary?.rounds, 1, "只有窗口内 + 今日 + native 的样本计入")
        XCTAssertEqual(summary?.inputTokens, 500)
        XCTAssertEqual(summary?.prompts, 1)

        // 无闲时窗口 → nil
        XCTAssertNil(
            LocalUsageSummaryBuilder.offPeakTodaySummary(
                samples: [inWindow],
                providerKind: .glmCodingPlan,
                quotaModelName: "glm_coding_plan",
                offPeakWindows: [],
                now: today.addingTimeInterval(10_000),
                calendar: cal
            )
        )
    }

    /// 闲时窗口语义（旧 mergeGlm 测试的迁移）：offPeakWindows 只属于 native
    /// ZCode 源，卡片直接从 `status.glmLocalUsage` 读取（ProviderCardView），
    /// `usageProjection` 不携带也不修改它 —— 合并路径无法再影响闲时窗口。
    func testGlmOffPeakWindowsStayOnNativeUsageOutsideProjection() {
        let day = Self.todayMidnight(calendar: .current)
        let native = GlmLocalUsage(
            today: GlmDailyUsage(dayStart: day, inputTokens: 10, rounds: 1),
            dailyTokenUsage: [GlmDailyUsage(dayStart: day, inputTokens: 10, rounds: 1)],
            scannedAt: day, sessionCount: 1, eventCount: 1, failedSessionCount: 0,
            recentSamples: [],
            offPeakWindows: [GlmOffPeakWindow(
                startedAt: day, endedAt: day.addingTimeInterval(600)
            )]
        )

        var status = ProviderStatus(
            id: "glm", displayName: "GLM", kind: .glmCodingPlan,
            iconSystemName: "circle", accentColor: .glm,
            refreshIntervalSeconds: 300, state: .ready
        )
        status.glmLocalUsage = native

        // 卡片读取闲时窗口的唯一入口仍是 native usage。
        XCTAssertEqual(status.glmLocalUsage?.offPeakWindows.count, 1)
        // projection 只表达 token 用量，闲时窗口不参与、也不受合并影响。
        _ = status.usageProjection(for: nil)
        XCTAssertEqual(status.glmLocalUsage?.offPeakWindows.count, 1)
    }

    // MARK: - GLM 活动套餐余额日志解析 Tests

    /// 构造一条 `billing/balance 请求完成` 日志行。时间戳全部动态计算，
    /// 保证测试不随真实日期过期。
    private func makeBalanceLine(
        entitlementID: String = "ent_wk_test",
        observedAt: String = "2026-01-01 12:00:00.000",
        expiresAt: Int
    ) -> String {
        let json = """
        {"balanceCount":1,"code":0,"msg":"","payload":{"code":0,"msg":"","data":{"server_time":\(expiresAt),"plans":[{"plan_id":"zcode-test-plan","name":"ZCode Test Build","status":"active"}],"balances":[{"plan_id":"zcode-test-plan","entitlement_id":"\(entitlementID)","show_name":"GLM-5.3-Flash","capabilities":["model:glm-5.3-flash"],"total_units":300000000,"used_units":1000,"remaining_units":299999000,"expires_at":\(expiresAt)}]}},"success":true}
        """
        return "[\(observedAt)] [info] [usage-stats] billing/balance 请求完成 \(json)"
    }

    func testGlmBalanceLogReaderParsesBillingLine() throws {
        let now = Date()
        let expiresAt = Int(now.timeIntervalSince1970) + 86_400
        let balances = GlmZcodeBalanceLogReader.parseBalanceLine(
            makeBalanceLine(expiresAt: expiresAt), now: now
        )
        XCTAssertEqual(balances?.count, 1)
        let balance = try XCTUnwrap(balances?.first)
        XCTAssertEqual(balance.planID, "zcode-test-plan")
        XCTAssertEqual(balance.planName, "ZCode Test Build")
        XCTAssertEqual(balance.entitlementID, "ent_wk_test")
        XCTAssertEqual(balance.showName, "GLM-5.3-Flash")
        XCTAssertEqual(balance.modelNames, ["glm-5.3-flash"])
        XCTAssertEqual(balance.totalUnits, 300_000_000)
        XCTAssertEqual(balance.usedUnits, 1_000)
        XCTAssertEqual(balance.remainingUnits, 299_999_000)
        XCTAssertEqual(balance.expiresAt, Date(timeIntervalSince1970: Double(expiresAt)))
        XCTAssertNotNil(balance.observedAt, "日志行时间戳应被解析为快照观测时间")
    }

    func testGlmBalanceLogReaderPicksLastLineAndDropsExpired() {
        let now = Date()
        let expired = Int(now.timeIntervalSince1970) - 60
        let active = Int(now.timeIntervalSince1970) + 86_400
        let text = """
        noise line without marker
        \(makeBalanceLine(entitlementID: "ent_old", observedAt: "2026-01-01 11:00:00.000", expiresAt: expired))
        \(makeBalanceLine(entitlementID: "ent_new", observedAt: "2026-01-01 12:00:00.000", expiresAt: active))
        """
        // 取最后一条匹配行,且过期条目被剔除
        let balances = GlmZcodeBalanceLogReader.latestBalances(inLogText: text, now: now)
        XCTAssertEqual(balances?.map(\.entitlementID), ["ent_new"])

        // 只有已过期条目 → 解析成功但为空
        let onlyExpired = GlmZcodeBalanceLogReader.latestBalances(
            inLogText: makeBalanceLine(entitlementID: "ent_old", expiresAt: expired), now: now
        )
        XCTAssertEqual(onlyExpired, [])

        // 无标记行 → nil（无法解析,与"解析成功但为空"语义区分）
        XCTAssertNil(GlmZcodeBalanceLogReader.latestBalances(inLogText: "nothing here", now: now))
    }

    func testGlmBalanceLogReaderFallsBackToYesterdayFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-balance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date()
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        let active = Int(now.timeIntervalSince1970) + 86_400

        // 今天日志存在但没有任何 billing/balance 行 → 应回退到昨天的文件
        let todayURL = dir.appendingPathComponent(dayFormatter.string(from: now)).appendingPathExtension("log")
        try "startup noise\nno balance lines".write(to: todayURL, atomically: true, encoding: .utf8)
        let yesterdayURL = dir
            .appendingPathComponent(dayFormatter.string(from: now.addingTimeInterval(-86_400)))
            .appendingPathExtension("log")
        try makeBalanceLine(expiresAt: active)
            .write(to: yesterdayURL, atomically: true, encoding: .utf8)

        let balances = GlmZcodeBalanceLogReader.latestBalances(logDirectory: dir, now: now)
        XCTAssertEqual(balances?.first?.entitlementID, "ent_wk_test")

        // 两天都没有标记行 → nil
        try "nothing".write(to: todayURL, atomically: true, encoding: .utf8)
        try "nothing".write(to: yesterdayURL, atomically: true, encoding: .utf8)
        XCTAssertNil(GlmZcodeBalanceLogReader.latestBalances(logDirectory: dir, now: now))
    }

    @MainActor
    func testGlmScannerBalanceLogGating() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        try insert(databaseURL: db, id: "r1", sessionID: "s", turnID: "t1", timestamp: ms(Date()),
                   input: 10, output: 1)

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-scan-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glm-scan-logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logDir) }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        let logURL = logDir.appendingPathComponent(dayFormatter.string(from: Date()))
            .appendingPathExtension("log")
        let expiresAt = Int(Date().timeIntervalSince1970) + 86_400
        try makeBalanceLine(expiresAt: expiresAt).write(to: logURL, atomically: true, encoding: .utf8)

        func makeScanner() -> GlmZcodeLocalUsageScanner {
            GlmZcodeLocalUsageScanner(
                dbURL: URL(fileURLWithPath: db),
                tasksDBURL: URL(fileURLWithPath: "/nonexistent-tasks-\(UUID().uuidString)"),
                cacheDir: cacheDir,
                balanceLogDirectory: logDir
            )
        }

        // 开关关闭（默认）→ 不读日志,快照不带活动套餐
        let disabled = makeScanner()
        let disabledSnapshot = try disabled.buildSnapshot(now: Date())
        XCTAssertNil(disabledSnapshot.activityPlanBalances)

        // 开关打开 → 快照携带解析出的余额
        let enabled = makeScanner()
        enabled.setBalanceLogParsingEnabled(true)
        let enabledSnapshot = try enabled.buildSnapshot(now: Date())
        XCTAssertEqual(enabledSnapshot.activityPlanBalances?.first?.entitlementID, "ent_wk_test")
    }

    func testGlmLocalUsageBalancesCodableBackwardCompatible() throws {
        // 旧快照 JSON 没有 activityPlanBalances 字段 → 解码为 nil,不破坏缓存
        let legacyJSON = #"{"dailyTokenUsage":[],"sessionCount":0,"eventCount":0,"failedSessionCount":0,"offPeakWindows":[]}"#
        let legacy = try JSONDecoder().decode(GlmLocalUsage.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(legacy.activityPlanBalances)

        // 含余额的新快照 round trip
        let balance = GlmActivityPlanBalance(
            planID: "zcode-test-plan", planName: "ZCode Test Build",
            entitlementID: "ent_wk_test", showName: "GLM-5.3-Flash",
            modelNames: ["glm-5.3-flash"], totalUnits: 300_000_000,
            usedUnits: 1_000, remainingUnits: 299_999_000,
            expiresAt: Date(timeIntervalSince1970: 1_788_138_000),
            observedAt: Date(timeIntervalSince1970: 1_787_922_023)
        )
        let usage = GlmLocalUsage(
            today: nil, dailyTokenUsage: [], scannedAt: nil, sessionCount: 0,
            eventCount: 0, failedSessionCount: 0, activityPlanBalances: [balance]
        )
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(GlmLocalUsage.self, from: data)
        XCTAssertEqual(decoded, usage)
    }

    func testProviderConfigParseZcodeBalanceLogDefaultsOff() throws {
        // 字段缺失 = 关闭（nil）,不写回配置文件
        let json = #"{"enabled":true}"#
        let config = try JSONDecoder().decode(ProviderConfig.self, from: Data(json.utf8))
        XCTAssertNil(config.parseZcodeBalanceLog)

        // 开启时显式写 true 并可往返
        let encoded = try JSONEncoder().encode(
            ProviderConfig(enabled: true, parseZcodeBalanceLog: true)
        )
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: encoded)
        XCTAssertEqual(decoded.parseZcodeBalanceLog, true)
    }

    /// 设置 → 客户端 → ZCode 的三分类拆行依据：provider 身份 → 日常 / 闲时 / 其他。
    /// 与额度窗口白名单同一判定来源,无来源标记与 OpenCode / DSH 合并样本归日常。
    func testGlmUsageCategoryClassify() {
        func sample(_ providerID: String?, promptID: String = "s:t1") -> LocalTokenUsageSample {
            LocalTokenUsageSample(
                completedAt: Date(), modelName: "GLM-5.3-Flash", promptID: promptID,
                inputTokens: 1, cachedInputTokens: 0, outputTokens: 1, reasoningOutputTokens: 0,
                sourceProviderID: providerID
            )
        }

        XCTAssertEqual(GlmUsageCategory.classify(sample(OpencodeLocalUsage.zcodeGlmProviderID)), .normal)
        XCTAssertEqual(GlmUsageCategory.classify(sample(OpencodeLocalUsage.zcodeOffPeakProviderID)), .offPeak)
        XCTAssertEqual(GlmUsageCategory.classify(sample("builtin:bigmodel-start-plan")), .other)
        XCTAssertEqual(GlmUsageCategory.classify(sample("builtin:bigmodel-future-plan")), .other)
        // 0020_provider_model_selection 迁移后的 account: 前缀：
        // 账号套餐 *-coding-plan 归日常，体验套餐归其他
        XCTAssertEqual(GlmUsageCategory.classify(sample("account:bigmodel-individual-coding-plan")), .normal)
        XCTAssertEqual(GlmUsageCategory.classify(sample("account:bigmodel-team-coding-plan")), .normal)
        XCTAssertEqual(GlmUsageCategory.classify(sample("account:bigmodel-start-plan")), .other)
        // OpenCode / DSH 合并样本与旧缓存无标记样本 → 日常
        XCTAssertEqual(GlmUsageCategory.classify(sample("dsh:zhipuai-coding-plan")), .normal)
        XCTAssertEqual(GlmUsageCategory.classify(sample(nil, promptID: "opencode:zhipuai-coding-plan:p1")), .normal)
        XCTAssertEqual(GlmUsageCategory.classify(sample(nil)), .normal)

        XCTAssertEqual(GlmUsageCategory.allCases.map(\.displayName), ["日常任务", "闲时任务", "其他任务"])
    }
}
