import XCTest
import SQLite3
@testable import LLM_monitor

/// ZCode 是多 provider 共享账本：`model_usage` 表里既有智谱系行（进 GLM 卡），
/// 也有用户自带的非智谱行（`minimax` / `deepseek`，按 `ZcodeProviderSlice` 切出
/// 分片并入 MiniMax / DeepSeek 卡）。本文件钉住这条链路：读库 → 分片 → 卡片贡献
/// → 开关关闭后贡献消失，同时锁住 GLM 既有聚合不回归。
final class ZcodeProviderSliceTests: XCTestCase {

    // MARK: - fixture

    /// 本机自然日历。**必须与 SQL 的 `strftime(...,'localtime')` 同口径**：日聚合
    /// 在 SQLite 侧按进程时区归日，Swift 侧再用注入 calendar 解析 `yyyy-MM-dd`
    /// 键。注入 UTC 会让两侧错开一天，非 UTC 时区机器上分片按日查不到。
    private func localCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .autoupdatingCurrent
        return c
    }

    private func ms(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private func makeDatabase() throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("zcode-slice-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw SQLiteConnectionError.openFailed(path: path, code: 0, extendedCode: 0, message: "open failed")
        }
        defer { sqlite3_close(db) }
        // schema 与 ZCode 真实 `model_usage` 表一致（含 part 表：智谱行走 Method A
        // 归类、非智谱分片按字符比例分摊，都经 assistant_message_id JOIN 它）。
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
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteConnectionError.openFailed(path: path, code: 0, extendedCode: 0, message: "create table failed")
        }
        return path
    }

    @discardableResult
    private func insert(
        databaseURL path: String,
        id: String,
        sessionID: String,
        turnID: String?,
        timestamp: Int64,
        input: Int,
        output: Int,
        reasoning: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        status: String = "completed",
        model: String,
        provider: String,
        assistantMessageID: String? = nil
    ) throws -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }
        let sql = """
        INSERT INTO model_usage (id, session_id, turn_id, started_at, status, model_id, provider_id,
            input_tokens, output_tokens, reasoning_tokens, cache_read_input_tokens,
            cache_creation_input_tokens, assistant_message_id)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (sessionID as NSString).utf8String, -1, nil)
        if let turnID { sqlite3_bind_text(stmt, 3, (turnID as NSString).utf8String, -1, nil) }
        else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_int64(stmt, 4, timestamp)
        sqlite3_bind_text(stmt, 5, (status as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (model as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 7, (provider as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 8, Int64(input))
        sqlite3_bind_int64(stmt, 9, Int64(output))
        sqlite3_bind_int64(stmt, 10, Int64(reasoning))
        sqlite3_bind_int64(stmt, 11, Int64(cacheRead))
        sqlite3_bind_int64(stmt, 12, Int64(cacheWrite))
        if let assistantMessageID {
            sqlite3_bind_text(stmt, 13, (assistantMessageID as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 13)
        }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// 写一条 `part`（思考 / 正文 / 工具参数块）。`data` 直接放 JSON 字符串。
    @discardableResult
    private func insertPart(
        databaseURL path: String,
        partID: String,
        messageID: String,
        data: String
    ) throws -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO part (id, message_id, data) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (partID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (messageID as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (data as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func reasoningPartJSON(chars: Int) -> String {
        "{\"type\":\"reasoning\",\"text\":\"\(String(repeating: "x", count: chars))\"}"
    }

    private func textPartJSON(chars: Int) -> String {
        "{\"type\":\"text\",\"text\":\"\(String(repeating: "y", count: chars))\"}"
    }

    private func toolPartJSON(inputChars: Int) -> String {
        "{\"type\":\"tool\",\"state\":{\"input\":\"\(String(repeating: "z", count: inputChars))\"}}"
    }

    /// 写入一份「用户今天真实发生」的混合账本：
    /// - `deepseek` / `deepseek-flash`：2 行，input 合计 23771、output 298、cacheRead 0
    /// - `minimax` / `MiniMax-M3.1-Flash-Preview`：6 行
    /// - 智谱系 3 行（正式 coding-plan / 闲时裸值 / 体验套餐）用于回归校验
    /// - 1 行未完成 + 1 行未登记 provider，必须既不进分片也不进 GLM
    private func makeMixedLedger(today: Date) throws -> String {
        let db = try makeDatabase()
        let ts = ms(today)

        // DeepSeek：2 行，合计 23771 / 298
        try insert(databaseURL: db, id: "ds1", sessionID: "ds-s", turnID: "ds-t1", timestamp: ts,
                   input: 12_000, output: 200, model: "deepseek-flash", provider: "deepseek")
        try insert(databaseURL: db, id: "ds2", sessionID: "ds-s", turnID: "ds-t2", timestamp: ts + 1,
                   input: 11_771, output: 98, model: "deepseek-flash", provider: "deepseek")

        // MiniMax：6 行
        for index in 1...6 {
            try insert(databaseURL: db, id: "mm\(index)", sessionID: "mm-s", turnID: "mm-t\(index)",
                       timestamp: ts + Int64(index),
                       input: 1_000 * index, output: 10 * index,
                       model: "MiniMax-M3.1-Flash-Preview", provider: "minimax")
        }

        // 智谱系（GLM 卡口径）：正式 Coding Plan / 闲时裸值 / 体验套餐
        try insert(databaseURL: db, id: "glm1", sessionID: "glm-s", turnID: "glm-t1", timestamp: ts,
                   input: 100, output: 10, model: "GLM-5.3", provider: "builtin:bigmodel-coding-plan")
        try insert(databaseURL: db, id: "glm2", sessionID: "glm-s", turnID: "glm-t2", timestamp: ts + 1,
                   input: 50, output: 5, model: "GLM-5.3", provider: "offpeak-idle-plan")
        try insert(databaseURL: db, id: "glm3", sessionID: "glm-s", turnID: "glm-t3", timestamp: ts + 2,
                   input: 200, output: 20, model: "GLM-5.3", provider: "account:bigmodel-start-plan")

        // 未完成行：任何来源都不该计入
        try insert(databaseURL: db, id: "ds-running", sessionID: "ds-s", turnID: "ds-t3", timestamp: ts + 5,
                   input: 9_999, output: 9_999, status: "running",
                   model: "deepseek-flash", provider: "deepseek")
        // 未登记 provider：不进 GLM，也不进任何分片
        try insert(databaseURL: db, id: "other1", sessionID: "x", turnID: "x-t1", timestamp: ts,
                   input: 4_242, output: 42, model: "mystery", provider: "openai")
        return db
    }

    // MARK: - reader

    /// 真实数据形态（deepseek 23771/298、minimax 6 行）逐分片落到正确的卡，
    /// 且智谱行的 GLM 聚合不受影响。
    func testZcodeReaderSlicesNonZhipuProvidersWithoutTouchingGlm() throws {
        let db = try makeMixedLedger(today: localCalendar().startOfDay(for: Date()))
        defer { try? FileManager.default.removeItem(atPath: db) }
        let cal = localCalendar()
        let today = cal.startOfDay(for: Date())

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(
            dbPath: URL(fileURLWithPath: db), calendar: cal
        )

        // DeepSeek 分片
        let deepseekDay = try XCTUnwrap(
            aggregate.providerSlices.perSliceDay[ZcodeProviderSlice.deepseek.rawValue]?[today]
        )
        XCTAssertEqual(deepseekDay.inputTokens, 23_771)
        XCTAssertEqual(deepseekDay.outputTokens, 298)
        XCTAssertEqual(deepseekDay.cacheReadTokens, 0)
        XCTAssertEqual(deepseekDay.reasoningTokens, 0)
        XCTAssertEqual(deepseekDay.rounds, 2, "未完成行（status != completed）不计入")
        XCTAssertEqual(aggregate.providerSlices.roundCount[ZcodeProviderSlice.deepseek.rawValue], 2)
        XCTAssertEqual(aggregate.providerSlices.models[ZcodeProviderSlice.deepseek.rawValue], ["deepseek-flash"])

        // MiniMax 分片
        let minimaxDay = try XCTUnwrap(
            aggregate.providerSlices.perSliceDay[ZcodeProviderSlice.minimax.rawValue]?[today]
        )
        XCTAssertEqual(minimaxDay.rounds, 6)
        XCTAssertEqual(minimaxDay.inputTokens, 1_000 + 2_000 + 3_000 + 4_000 + 5_000 + 6_000)
        XCTAssertEqual(aggregate.providerSlices.roundCount[ZcodeProviderSlice.minimax.rawValue], 6)
        XCTAssertEqual(
            aggregate.providerSlices.models[ZcodeProviderSlice.minimax.rawValue],
            ["MiniMax-M3.1-Flash-Preview"]
        )

        // 未登记 provider 两头都不进
        XCTAssertEqual(aggregate.providerSlices.perSliceDay.keys.sorted(), ["deepseek", "minimax"])

        // 样本：modelName 取 model_id，sourceProviderID 保留原始 provider
        let deepseekSamples = try XCTUnwrap(
            aggregate.providerSlices.samples[ZcodeProviderSlice.deepseek.rawValue]
        )
        XCTAssertEqual(deepseekSamples.count, 2)
        XCTAssertEqual(deepseekSamples.map(\.modelName), ["deepseek-flash", "deepseek-flash"])
        XCTAssertEqual(deepseekSamples.map(\.sourceProviderID), ["deepseek", "deepseek"])
        XCTAssertEqual(deepseekSamples.map(\.promptID), ["ds-s:ds-t1", "ds-s:ds-t2"])
        XCTAssertEqual(deepseekSamples.map(\.inputTokens), [12_000, 11_771])

        // GLM 卡既有口径不回归：3 行智谱行照旧全部计入
        let glmDay = try XCTUnwrap(aggregate.perDay[today])
        XCTAssertEqual(glmDay.rounds, 3)
        XCTAssertEqual(glmDay.inputTokens, 350)
        XCTAssertEqual(glmDay.outputTokens, 35)
        XCTAssertEqual(aggregate.roundCount, 3)
        XCTAssertEqual(aggregate.samples.map(\.promptID), ["glm-s:glm-t1", "glm-s:glm-t2", "glm-s:glm-t3"])
    }

    /// ZCode 的 input 是 cache-inclusive：uncached = input - cacheRead，
    /// sample 的 inputTokens 保留完整 input，cacheRead 单独成桶。
    func testZcodeSliceAppliesCacheInclusiveInputAccounting() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let cal = localCalendar()
        let today = cal.startOfDay(for: Date())

        try insert(databaseURL: db, id: "c1", sessionID: "s", turnID: "t1", timestamp: ms(today),
                   input: 1_000, output: 50, reasoning: 20, cacheRead: 400, cacheWrite: 30,
                   model: "deepseek-chat", provider: "deepseek")
        try insert(databaseURL: db, id: "c2", sessionID: "s", turnID: "t2", timestamp: ms(today) + 1,
                   input: 2_000, output: 60, cacheRead: 900,
                   model: "deepseek-chat", provider: "deepseek")

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(
            dbPath: URL(fileURLWithPath: db), calendar: cal
        )
        let day = try XCTUnwrap(aggregate.providerSlices.perSliceDay["deepseek"]?[today])
        XCTAssertEqual(day.cacheReadTokens, 1_300)
        XCTAssertEqual(day.inputTokens, 1_700, "uncached = (1000-400) + (2000-900)")
        XCTAssertEqual(day.cacheWriteTokens, 30, "cacheWrite 只作诊断，不进 total")
        XCTAssertEqual(day.outputTokens, 110)
        XCTAssertEqual(day.reasoningTokens, 20)
        XCTAssertEqual(day.totalTokens, day.inputTokens + day.cacheReadTokens + day.outputTokens + day.reasoningTokens)

        let sample = try XCTUnwrap(aggregate.providerSlices.samples["deepseek"]?.first)
        XCTAssertEqual(sample.inputTokens, 1_000, "sample 保留 cache-inclusive 完整 input")
        XCTAssertEqual(sample.cachedInputTokens, 400)
        let buckets = TokenUsageBuckets.fromSample(sample)
        XCTAssertEqual(buckets.input, 600)
        XCTAssertEqual(buckets.cacheRead, 400)
    }

    /// 样本 cutoff 同样作用于分片（与智谱 native 样本同一条 8 天窗口）。
    func testZcodeSliceSamplesHonorCutoff() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let cal = localCalendar()
        let today = cal.startOfDay(for: Date())
        let oldDay = cal.date(byAdding: .day, value: -10, to: today)!

        try insert(databaseURL: db, id: "old", sessionID: "s", turnID: "t-old", timestamp: ms(oldDay),
                   input: 100, output: 10, model: "deepseek-flash", provider: "deepseek")
        try insert(databaseURL: db, id: "new", sessionID: "s", turnID: "t-new", timestamp: ms(today),
                   input: 200, output: 20, model: "deepseek-flash", provider: "deepseek")

        let cutoff = cal.date(byAdding: .day, value: -8, to: today)!
        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(
            dbPath: URL(fileURLWithPath: db), calendar: cal, sampleCutoff: cutoff
        )
        XCTAssertNil(aggregate.providerSlices.perSliceDay["deepseek"]?[oldDay])
        XCTAssertEqual(aggregate.providerSlices.samples["deepseek"]?.map(\.promptID), ["s:t-new"])
    }

    // MARK: - reasoning 字符分摊

    /// ZCode 账本 `reasoning_tokens` 恒 0，MiniMax 卡必须按 part 表字符比例分摊：
    /// 当日 300 output / 1500 思考字符 / 500 可见字符 → 225 reasoning + 75 output。
    func testZcodeSliceSplitsReasoningFromPartChars() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let cal = localCalendar()
        let today = cal.startOfDay(for: Date())

        for (index, output) in [200, 100].enumerated() {
            let messageID = "mm-msg-\(index)"
            try insert(databaseURL: db, id: "mm\(index)", sessionID: "mm-s", turnID: "mm-t\(index)",
                       timestamp: ms(today) + Int64(index), input: 1_000, output: output,
                       model: "MiniMax-M3.1-Flash-Preview", provider: "minimax",
                       assistantMessageID: messageID)
            try insertPart(databaseURL: db, partID: "p-r-\(index)", messageID: messageID,
                           data: reasoningPartJSON(chars: 750))
            try insertPart(databaseURL: db, partID: "p-t-\(index)", messageID: messageID,
                           data: textPartJSON(chars: 250))
        }

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(
            dbPath: URL(fileURLWithPath: db), calendar: cal
        )
        let day = try XCTUnwrap(aggregate.providerSlices.perSliceDay["minimax"]?[today])
        XCTAssertEqual(day.reasoningTokens, 225, "300 × 1500/2000，day 级分摊")
        XCTAssertEqual(day.outputTokens, 75)
        XCTAssertEqual(day.reasoningTokens + day.outputTokens, 300, "守恒")
        XCTAssertEqual(day.inputTokens, 2_000)
        XCTAssertEqual(
            day.totalTokens,
            day.inputTokens + day.cacheReadTokens + day.outputTokens + day.reasoningTokens
        )

        // 样本是行级分摊（200×0.75 / 100×0.75），合计与 day 级一致。
        let samples = try XCTUnwrap(aggregate.providerSlices.samples["minimax"])
        XCTAssertEqual(samples.map(\.reasoningOutputTokens), [150, 75])
        XCTAssertEqual(samples.map(\.outputTokens), [50, 25])
        XCTAssertEqual(samples.reduce(0) { $0 + $1.reasoningOutputTokens + $1.outputTokens }, 300)
    }

    /// 工具参数也属模型生成输出，计入可见字符分母。
    func testZcodeSliceCountsToolInputAsVisibleChars() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let cal = localCalendar()
        let today = cal.startOfDay(for: Date())

        try insert(databaseURL: db, id: "mm", sessionID: "mm-s", turnID: "mm-t1",
                   timestamp: ms(today), input: 100, output: 200,
                   model: "MiniMax-M3.1-Flash-Preview", provider: "minimax",
                   assistantMessageID: "mm-msg")
        try insertPart(databaseURL: db, partID: "p-r", messageID: "mm-msg",
                       data: reasoningPartJSON(chars: 500))
        try insertPart(databaseURL: db, partID: "p-tool", messageID: "mm-msg",
                       data: toolPartJSON(inputChars: 500))

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(
            dbPath: URL(fileURLWithPath: db), calendar: cal
        )
        let day = try XCTUnwrap(aggregate.providerSlices.perSliceDay["minimax"]?[today])
        XCTAssertEqual(day.reasoningTokens, 100, "思考 500 / (500 + 工具 500) = 50%")
        XCTAssertEqual(day.outputTokens, 100)
    }

    /// 账面已给 `reasoning_tokens` 时原样透传，不再按字符二次分摊。
    func testZcodeSliceKeepsNativeReasoningWithoutReSplitting() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let cal = localCalendar()
        let today = cal.startOfDay(for: Date())

        try insert(databaseURL: db, id: "n1", sessionID: "s", turnID: "t1", timestamp: ms(today),
                   input: 500, output: 200, reasoning: 60, cacheRead: 100,
                   model: "deepseek-reasoner", provider: "deepseek", assistantMessageID: "m1")
        try insertPart(databaseURL: db, partID: "p-r", messageID: "m1", data: reasoningPartJSON(chars: 750))
        try insertPart(databaseURL: db, partID: "p-t", messageID: "m1", data: textPartJSON(chars: 250))

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(
            dbPath: URL(fileURLWithPath: db), calendar: cal
        )
        let day = try XCTUnwrap(aggregate.providerSlices.perSliceDay["deepseek"]?[today])
        XCTAssertEqual(day.reasoningTokens, 60, "native 优先，不二次分摊")
        XCTAssertEqual(day.outputTokens, 200)

        let sample = try XCTUnwrap(aggregate.providerSlices.samples["deepseek"]?.first)
        XCTAssertEqual(sample.reasoningOutputTokens, 60)
        XCTAssertEqual(sample.outputTokens, 200)
    }

    /// 同一套字符分摊对 DeepSeek 分片同样生效（不只 MiniMax）。
    func testZcodeSliceSplitsReasoningForDeepSeekToo() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let cal = localCalendar()
        let today = cal.startOfDay(for: Date())

        try insert(databaseURL: db, id: "d1", sessionID: "ds-s", turnID: "ds-t1", timestamp: ms(today),
                   input: 1_200, output: 300, model: "deepseek-flash", provider: "deepseek",
                   assistantMessageID: "ds-msg")
        try insertPart(databaseURL: db, partID: "p-r", messageID: "ds-msg", data: reasoningPartJSON(chars: 750))
        try insertPart(databaseURL: db, partID: "p-t", messageID: "ds-msg", data: textPartJSON(chars: 250))

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(
            dbPath: URL(fileURLWithPath: db), calendar: cal
        )
        let day = try XCTUnwrap(aggregate.providerSlices.perSliceDay["deepseek"]?[today])
        XCTAssertEqual(day.reasoningTokens, 225)
        XCTAssertEqual(day.outputTokens, 75)

        let sample = try XCTUnwrap(aggregate.providerSlices.samples["deepseek"]?.first)
        XCTAssertEqual(sample.reasoningOutputTokens, 225, "行级分摊")
        XCTAssertEqual(sample.outputTokens, 75)
        XCTAssertEqual(sample.reasoningOutputTokens + sample.outputTokens, 300, "行级也守恒")
    }

    /// 无 `assistant_message_id` 的行没有 part 可 JOIN → reasoning 保持 0，
    /// day 与样本都不凭空生思考。
    func testZcodeSliceWithoutAssistantMessageIDKeepsZeroReasoning() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let cal = localCalendar()
        let today = cal.startOfDay(for: Date())

        try insert(databaseURL: db, id: "x1", sessionID: "s", turnID: "t1", timestamp: ms(today),
                   input: 100, output: 200, model: "MiniMax-M3", provider: "minimax")
        // 同 message_id 下另有 part，但没有任何 model_usage 行关联它。
        try insertPart(databaseURL: db, partID: "p-r", messageID: "orphan", data: reasoningPartJSON(chars: 750))

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(
            dbPath: URL(fileURLWithPath: db), calendar: cal
        )
        let day = try XCTUnwrap(aggregate.providerSlices.perSliceDay["minimax"]?[today])
        XCTAssertEqual(day.reasoningTokens, 0)
        XCTAssertEqual(day.outputTokens, 200)
        XCTAssertEqual(day.totalTokens, day.inputTokens + day.cacheReadTokens + day.outputTokens)

        let sample = try XCTUnwrap(aggregate.providerSlices.samples["minimax"]?.first)
        XCTAssertEqual(sample.reasoningOutputTokens, 0)
        XCTAssertEqual(sample.outputTokens, 200)
    }

    /// 智谱行仍走 Method A 整轮归类，与非智谱字符分摊互不干扰。
    func testZcodeGlmRowsKeepMethodAWhileSlicesSplitByChars() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let cal = localCalendar()
        let today = cal.startOfDay(for: Date())

        try insert(databaseURL: db, id: "glm1", sessionID: "g-s", turnID: "g-t1", timestamp: ms(today),
                   input: 100, output: 200, model: "GLM-5.3",
                   provider: "builtin:bigmodel-coding-plan", assistantMessageID: "g-msg")
        try insertPart(databaseURL: db, partID: "p-r", messageID: "g-msg", data: reasoningPartJSON(chars: 750))
        try insertPart(databaseURL: db, partID: "p-t", messageID: "g-msg", data: textPartJSON(chars: 250))

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(
            dbPath: URL(fileURLWithPath: db), calendar: cal
        )
        let glmDay = try XCTUnwrap(aggregate.perDay[today])
        XCTAssertEqual(glmDay.reasoningTokens, 200, "Method A 整轮归 reasoning，不按字符分摊")
        XCTAssertEqual(glmDay.outputTokens, 0)
        XCTAssertNil(aggregate.providerSlices.perSliceDay["minimax"])
        XCTAssertNil(aggregate.providerSlices.perSliceDay["deepseek"])
    }

    // MARK: - snapshot

    /// 快照把分片压成 7 天窗口并带上 today；rebase 跨午夜时同步滚动窗口。
    func testZcodeSnapshotWindowsProviderSlices() throws {
        let cal = localCalendar()
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let now = cal.date(byAdding: .hour, value: 1, to: today)!

        func day(_ start: Date, input: Int) -> OpencodeDailyUsage {
            OpencodeDailyUsage(dayStart: start, inputTokens: input, outputTokens: 1, turns: 1, rounds: 1)
        }
        let aggregate = ZcodeProviderSliceAggregate(
            perSliceDay: ["deepseek": [today: day(today, input: 10), yesterday: day(yesterday, input: 5)]],
            roundCount: ["deepseek": 2],
            models: ["deepseek": ["deepseek-flash"]],
            samples: ["deepseek": [
                LocalTokenUsageSample(
                    completedAt: now, modelName: "deepseek-flash", promptID: "s:t",
                    inputTokens: 10, cachedInputTokens: 0, outputTokens: 1, reasoningOutputTokens: 0
                )
            ]]
        )
        let slices = GlmZcodeLocalUsageScanner.providerSlices(from: aggregate, calendar: cal, now: now)
        let deepseek = try XCTUnwrap(slices["deepseek"])
        XCTAssertEqual(deepseek.today?.inputTokens, 10)
        XCTAssertEqual(deepseek.dailyTokenUsage.count, 7, "7 天窗口需要补零")
        XCTAssertEqual(deepseek.roundCount, 2)
        XCTAssertEqual(deepseek.recentSamples.count, 1)

        let snapshot = GlmZcodeLocalUsageScanner.buildSnapshot(
            adjustedPerDay: [:], sessionCount: 0, roundCount: 0, samples: [],
            providerSlices: slices, offPeakWindows: [], calendar: cal, now: now
        )
        XCTAssertEqual(snapshot.deepseekSlice?.roundCount, 2)

        // rebase：窗口随 now 前滚，分片样本裁到最近 8 天
        let rebased = GlmZcodeLocalUsageScanner.rebaseCachedSnapshot(snapshot, calendar: cal, now: now)
        XCTAssertEqual(rebased.deepseekSlice?.today?.inputTokens, 10)
        XCTAssertEqual(rebased.minimaxSlice, nil)
    }

    /// 旧缓存快照（没有 providerSlices 字段）仍可解码，rebase 后分片保持 nil。
    func testZcodeSnapshotBackwardCompatibleDecodingWithoutSlices() throws {
        let json = """
        {"today":null,"dailyTokenUsage":[],"scannedAt":1000,"sessionCount":0,"eventCount":0,
         "failedSessionCount":0,"offPeakWindows":[]}
        """
        let decoded = try JSONDecoder().decode(GlmLocalUsage.self, from: Data(json.utf8))
        XCTAssertNil(decoded.providerSlices)
        XCTAssertNil(decoded.deepseekSlice)
        let rebased = GlmZcodeLocalUsageScanner.rebaseCachedSnapshot(decoded, calendar: localCalendar(), now: Date())
        XCTAssertNil(rebased.providerSlices)
    }

    // MARK: - card contributions

    private func makeStatus(kind: ProviderKind) -> ProviderStatus {
        ProviderStatus(
            id: kind.providerID, displayName: kind.rawValue, kind: kind,
            iconSystemName: "circle", accentColor: .minimax,
            refreshIntervalSeconds: 300, state: .ready
        )
    }

    private func sliceFixture() -> GlmLocalUsage {
        let day = Date()
        let deepseekDay = OpencodeDailyUsage(
            dayStart: day, inputTokens: 23_771, outputTokens: 298, turns: 2, rounds: 2
        )
        let minimaxDay = OpencodeDailyUsage(
            dayStart: day, inputTokens: 21_000, outputTokens: 60, turns: 6, rounds: 6
        )
        return GlmLocalUsage(
            today: nil, dailyTokenUsage: [], scannedAt: Date(timeIntervalSince1970: 1_000),
            sessionCount: 1, eventCount: 3, failedSessionCount: 0, recentSamples: [],
            providerSlices: [
                "deepseek": OpencodeProviderUsage(
                    today: deepseekDay, dailyTokenUsage: [deepseekDay], roundCount: 2,
                    recentSamples: [
                        LocalTokenUsageSample(
                            completedAt: day, modelName: "deepseek-flash", promptID: "ds-s:ds-t1",
                            inputTokens: 23_771, cachedInputTokens: 0, outputTokens: 298,
                            reasoningOutputTokens: 0, sourceProviderID: "deepseek"
                        )
                    ]
                ),
                "minimax": OpencodeProviderUsage(
                    today: minimaxDay, dailyTokenUsage: [minimaxDay], roundCount: 6,
                    recentSamples: []
                )
            ]
        )
    }

    /// 默认绑定开启时 MiniMax / DeepSeek 卡各自出现 ZCode 本地数据库用量贡献；
    /// 关闭对应绑定后贡献整体消失，卡片数据回到其它来源。
    func testZcodeSliceContributionsAppearPerCardAndRespectSwitch() throws {
        let usage = sliceFixture()

        var deepseek = makeStatus(kind: .deepseek)
        deepseek.glmLocalUsage = usage
        let deepseekProjection = deepseek.usageProjection(for: nil)
        XCTAssertEqual(deepseekProjection.clientIDs, [ClientID.zcode])
        let deepseekDay = try XCTUnwrap(deepseekProjection.dailyTokenUsage.first)
        XCTAssertEqual(deepseekDay.input, 23_771)
        XCTAssertEqual(deepseekDay.output, 298)
        XCTAssertEqual(
            deepseekProjection.recentSamples.map(\.promptID),
            ["zcode:deepseek:ds-s:ds-t1"],
            "绑定驱动后分片样本前缀仍逐字等于 zcode:<slice>:，避免与其它账本 promptID 撞车"
        )

        var minimax = makeStatus(kind: .minimaxTokenPlan)
        minimax.glmLocalUsage = usage
        let minimaxProjection = minimax.usageProjection(for: nil)
        XCTAssertTrue(minimaxProjection.clientIDs.contains(ClientID.zcode))
        XCTAssertEqual(minimaxProjection.dailyTokenUsage.first?.rounds, 6)

        // 绑定关闭：贡献消失（帧不产出）。
        deepseek.setClientBindingEnabled(
            clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.deepseek, enabled: false
        )
        XCTAssertTrue(deepseek.usageProjection(for: nil).clientIDs.isEmpty)
        XCTAssertFalse(deepseek.usageProjection(for: nil).hasActivity)

        // GLM 卡不消费 zcode 分片（没有 zcode → zhipu 绑定）：无智谱用量时不凭空产生贡献。
        let glm = makeStatus(kind: .glmCodingPlan)
        XCTAssertTrue(glm.usageProjection(for: nil).clientIDs.isEmpty, "无智谱用量时不应凭空产生贡献")
    }

    /// 消费 ZCode 分片的卡片在位时，ZCode 扫描源必须保持 active。
    func testZcodeSourceStaysActiveForSliceConsumers() {
        let base = makeStatus(kind: .glmCodingPlan)
        XCTAssertTrue(
            LocalUsageOrchestration.activeSources(for: [base]).glm,
            "GLM 卡启用时 ZCode 源必须扫描"
        )

        var disabledGLM = base
        disabledGLM.isEnabled = false
        XCTAssertFalse(LocalUsageOrchestration.activeSources(for: [disabledGLM]).glm)

        // 默认绑定已开启 zcode → deepseek，仅启用 DeepSeek 卡也要扫 ZCode。
        let deepseek = makeStatus(kind: .deepseek)
        XCTAssertTrue(
            LocalUsageOrchestration.activeSources(for: [deepseek]).glm,
            "只开 DeepSeek 卡也要扫 ZCode，否则分片永远拿不到数据"
        )

        var disabledDeepseek = deepseek
        disabledDeepseek.isEnabled = false
        XCTAssertFalse(LocalUsageOrchestration.activeSources(for: [disabledDeepseek]).glm)
    }

    // MARK: - config

    /// 默认绑定：zcode → minimax / deepseek 默认开启（与 opencode → deepseek 的
    /// 默认关闭不同：ZCode 里这两路 provider 是用户显式配过的上游）。
    func testDefaultBindingsEnableZcodeSlices() {
        XCTAssertTrue(
            AppConfig.default.isClientBindingEnabled(
                clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.minimax
            )
        )
        XCTAssertTrue(
            AppConfig.default.isClientBindingEnabled(
                clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.deepseek
            )
        )
        XCTAssertFalse(
            AppConfig.default.isClientBindingEnabled(
                clientID: ClientID.openCode, quotaProviderID: QuotaProviderID.deepseek
            ),
            "OpenCode → DeepSeek 的既有默认关闭语义不应被改动"
        )

        var config = AppConfig.default
        config.setClientBindingEnabled(
            clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.deepseek, enabled: false
        )
        XCTAssertFalse(
            config.isClientBindingEnabled(
                clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.deepseek
            )
        )
    }

    func testZcodeDescriptorAdvertisesSliceConsumers() throws {
        let zcode = try XCTUnwrap(ClientDescriptor.all.first { $0.id == ClientID.zcode })
        XCTAssertEqual(
            zcode.supportedQuotaProviderIDs,
            [QuotaProviderID.zhipu, QuotaProviderID.minimax, QuotaProviderID.deepseek]
        )
    }

    /// 分片 provider_id 前缀匹配：大小写不敏感、变体 ID 归入同一分片、
    /// 未登记 provider 返回 nil（不会被任何卡消费）。
    func testZcodeProviderSlicePrefixMatching() {
        XCTAssertEqual(ZcodeProviderSlice(providerID: "minimax"), .minimax)
        XCTAssertEqual(ZcodeProviderSlice(providerID: "MiniMax"), .minimax)
        XCTAssertEqual(ZcodeProviderSlice(providerID: "minimax:cn-coding-plan"), .minimax)
        XCTAssertEqual(ZcodeProviderSlice(providerID: "deepseek"), .deepseek)
        XCTAssertEqual(ZcodeProviderSlice(providerID: "DEEPSEEK-official"), .deepseek)
        XCTAssertNil(ZcodeProviderSlice(providerID: "builtin:bigmodel-coding-plan"))
        XCTAssertNil(ZcodeProviderSlice(providerID: "openai"))
    }
}
