import XCTest
import SQLite3
@testable import LLM_monitor

final class MinimaxV2UsageTests: XCTestCase {
    private let transientDestructor = unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)

    func testMinimaxRestoresCachedUsageOnColdStart() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-prefill-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManagerBox()
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: now)
        let usage = MinimaxDailyUsage(
            dayStart: day, inputTokens: 10, outputTokens: 5,
            cacheReadTokens: 2, reasoningTokens: 1, totalTokens: 18,
            turns: 1, rounds: 2
        )
        let index = MinimaxLocalUsageScanner.CacheIndex(
            version: 14,
            lastScannedAt: now,
            sources: ["runtime": MinimaxLocalUsageScanner.SourceIndexEntry(
                mtimeMs: 1, sizeBytes: 2, walMtimeMs: 0, walSizeBytes: 0,
                scannedAt: now, eventCount: 2, sessionCount: 1
            )],
            dailyBySource: ["runtime": [LocalUsageDayKey.make(day, calendar: calendar): usage]],
            samplesBySource: nil
        )
        try MinimaxLocalUsageScanner.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let restored = try XCTUnwrap(
            MinimaxLocalUsageScanner.loadCachedResult(
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

    private struct TokenRow {
        let sessionID: String
        let turnID: String?
        let timestampMs: Int64
        let input: Int
        let output: Int
        let reasoning: Int
        let cacheRead: Int
        let cacheWrite: Int
        let raw: String?
        let model: String?

        init(
            sessionID: String,
            turnID: String?,
            timestampMs: Int64,
            input: Int,
            output: Int,
            reasoning: Int,
            cacheRead: Int,
            cacheWrite: Int,
            raw: String?,
            model: String? = nil
        ) {
            self.sessionID = sessionID
            self.turnID = turnID
            self.timestampMs = timestampMs
            self.input = input
            self.output = output
            self.reasoning = reasoning
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.raw = raw
            self.model = model
        }
    }

    private struct SessionModelRow {
        let sessionID: String
        let effectiveModel: String
    }

    private struct MessageRow {
        let sessionID: String
        let messageID: String
        let timestampMs: Int64
        let data: String
    }

    private func makeV2Database(
        at url: URL? = nil,
        tokenRows: [TokenRow],
        messageRows: [MessageRow] = [],
        sessionModels: [SessionModelRow] = []
    ) throws -> URL {
        let databaseURL = url ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-v2-\(UUID().uuidString).sqlite")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK, let database else {
            throw NSError(domain: "MinimaxV2UsageTests", code: 1)
        }
        defer { sqlite3_close(database) }

        try execute(
            """
            CREATE TABLE local_runtime_token_usage (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                agent_name TEXT,
                framework_type TEXT,
                turn_id TEXT,
                model TEXT,
                ts INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL DEFAULT 0,
                output_tokens INTEGER NOT NULL DEFAULT 0,
                reasoning_tokens INTEGER NOT NULL DEFAULT 0,
                cache_read_tokens INTEGER NOT NULL DEFAULT 0,
                cache_write_tokens INTEGER NOT NULL DEFAULT 0,
                cost_usd REAL,
                raw TEXT
            );
            CREATE TABLE local_runtime_message_rows (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                msg_id TEXT NOT NULL,
                role TEXT,
                turn_id TEXT,
                created_at_ms INTEGER NOT NULL,
                data_json TEXT NOT NULL
            );
            """,
            database: database
        )
        if !sessionModels.isEmpty {
            try execute(
                """
                CREATE TABLE local_runtime_sessions (
                    session_id TEXT PRIMARY KEY,
                    record_json TEXT NOT NULL
                );
                """,
                database: database
            )
        }

        for row in tokenRows {
            let sql = """
            INSERT INTO local_runtime_token_usage
              (session_id, turn_id, model, ts, input_tokens, output_tokens, reasoning_tokens,
               cache_read_tokens, cache_write_tokens, raw)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw NSError(domain: "MinimaxV2UsageTests", code: 2)
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, row.sessionID, -1, transientDestructor)
            if let turnID = row.turnID {
                sqlite3_bind_text(statement, 2, turnID, -1, transientDestructor)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            if let model = row.model {
                sqlite3_bind_text(statement, 3, model, -1, transientDestructor)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            sqlite3_bind_int64(statement, 4, row.timestampMs)
            sqlite3_bind_int64(statement, 5, Int64(row.input))
            sqlite3_bind_int64(statement, 6, Int64(row.output))
            sqlite3_bind_int64(statement, 7, Int64(row.reasoning))
            sqlite3_bind_int64(statement, 8, Int64(row.cacheRead))
            sqlite3_bind_int64(statement, 9, Int64(row.cacheWrite))
            if let raw = row.raw {
                sqlite3_bind_text(statement, 10, raw, -1, transientDestructor)
            } else {
                sqlite3_bind_null(statement, 10)
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }

        for row in sessionModels {
            let sql = "INSERT INTO local_runtime_sessions (session_id, record_json) VALUES (?, ?)"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw NSError(domain: "MinimaxV2UsageTests", code: 5)
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, row.sessionID, -1, transientDestructor)
            let record = "{\"effectiveModel\":\(jsonString(row.effectiveModel))}"
            sqlite3_bind_text(statement, 2, record, -1, transientDestructor)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }

        for row in messageRows {
            let sql = """
            INSERT INTO local_runtime_message_rows
              (session_id, msg_id, role, created_at_ms, data_json)
            VALUES (?, ?, 'assistant', ?, ?)
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw NSError(domain: "MinimaxV2UsageTests", code: 3)
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, row.sessionID, -1, transientDestructor)
            sqlite3_bind_text(statement, 2, row.messageID, -1, transientDestructor)
            sqlite3_bind_int64(statement, 3, row.timestampMs)
            sqlite3_bind_text(statement, 4, row.data, -1, transientDestructor)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        return databaseURL
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQL failed"
            if let errorMessage { sqlite3_free(errorMessage) }
            throw NSError(
                domain: "MinimaxV2UsageTests",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func jsonString(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func testV2ReaderAggregatesRowsSessionsTurnsAndSamples() throws {
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        let databaseURL = try makeV2Database(tokenRows: [
            TokenRow(sessionID: "s1", turnID: "t1", timestampMs: base,
                     input: 100, output: 50, reasoning: 0, cacheRead: 10, cacheWrite: 2, raw: nil),
            TokenRow(sessionID: "s1", turnID: "t1", timestampMs: base + 1_000,
                     input: 200, output: 80, reasoning: 0, cacheRead: 20, cacheWrite: 3, raw: nil),
            TokenRow(sessionID: "s2", turnID: "t2", timestampMs: base + 2_000,
                     input: 300, output: 120, reasoning: 0, cacheRead: 30, cacheWrite: 4, raw: nil),
        ])
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let reader = try MinimaxDBReader(path: databaseURL)
        defer { reader.close() }
        let aggregate = try reader.aggregate(calendar: .current)
        let day = try XCTUnwrap(aggregate.perDay.values.first)

        XCTAssertEqual(aggregate.eventCount, 3)
        XCTAssertEqual(aggregate.sessionCount, 2)
        XCTAssertEqual(aggregate.turnCount, 2)
        XCTAssertEqual(day.rounds, 3)
        XCTAssertEqual(day.turns, 2)
        XCTAssertEqual(day.inputTokens, 600)
        XCTAssertEqual(day.outputTokens, 250)
        XCTAssertEqual(day.cacheReadTokens, 60)
        XCTAssertEqual(day.cacheWriteTokens, 9)
        XCTAssertEqual(day.totalTokens, 910)
        XCTAssertEqual(aggregate.samples.count, 3)
    }

    func testV2ReaderRecoversMissingModelFromSessionAndUniqueLedgerModel() throws {
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        let databaseURL = try makeV2Database(
            tokenRows: [
                TokenRow(sessionID: "session-model", turnID: "t1", timestampMs: base,
                         input: 10, output: 1, reasoning: 0, cacheRead: 0, cacheWrite: 0,
                         raw: nil),
                TokenRow(sessionID: "ledger-model", turnID: "t2", timestampMs: base + 1_000,
                         input: 10, output: 1, reasoning: 0, cacheRead: 0, cacheWrite: 0,
                         raw: nil, model: "minimax/MiniMax-M3"),
                TokenRow(sessionID: "unique-model", turnID: "t3", timestampMs: base + 2_000,
                         input: 10, output: 1, reasoning: 0, cacheRead: 0, cacheWrite: 0,
                         raw: nil),
            ],
            sessionModels: [
                SessionModelRow(sessionID: "session-model", effectiveModel: "minimax/MiniMax-M3")
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let reader = try MinimaxDBReader(path: databaseURL)
        defer { reader.close() }
        let aggregate = try reader.aggregate(calendar: .current)

        XCTAssertEqual(
            aggregate.samples.map(\.modelName),
            ["minimax/MiniMax-M3", "minimax/MiniMax-M3", "minimax/MiniMax-M3"]
        )
    }

    func testV2ReaderDoesNotGuessWhenLedgerContainsMultipleModels() throws {
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        let databaseURL = try makeV2Database(tokenRows: [
            TokenRow(sessionID: "m3", turnID: "t1", timestampMs: base,
                     input: 10, output: 1, reasoning: 0, cacheRead: 0, cacheWrite: 0,
                     raw: nil, model: "minimax/MiniMax-M3"),
            TokenRow(sessionID: "m27", turnID: "t2", timestampMs: base + 1_000,
                     input: 10, output: 1, reasoning: 0, cacheRead: 0, cacheWrite: 0,
                     raw: nil, model: "MiniMax-M2.7"),
            TokenRow(sessionID: "missing", turnID: "t3", timestampMs: base + 2_000,
                     input: 10, output: 1, reasoning: 0, cacheRead: 0, cacheWrite: 0,
                     raw: nil),
        ])
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let reader = try MinimaxDBReader(path: databaseURL)
        defer { reader.close() }
        let aggregate = try reader.aggregate(calendar: .current)

        XCTAssertNil(aggregate.samples.last?.modelName)
    }

    func testV2ReaderClampsNegativeValuesAndUsesPerRowReasoningMaximum() throws {
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        let databaseURL = try makeV2Database(tokenRows: [
            TokenRow(sessionID: "s", turnID: "negative", timestampMs: base,
                     input: -10, output: -20, reasoning: -5, cacheRead: -30, cacheWrite: -40,
                     raw: "{malformed"),
            TokenRow(sessionID: "s", turnID: "native", timestampMs: base + 1_000,
                     input: 10, output: 1000, reasoning: 100, cacheRead: 5, cacheWrite: 1,
                     raw: #"{"reasoning":0}"#),
            TokenRow(sessionID: "s", turnID: "raw", timestampMs: base + 2_000,
                     input: 20, output: 1000, reasoning: 0, cacheRead: 6, cacheWrite: 1,
                     raw: #"{"reasoning":200}"#),
        ])
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let reader = try MinimaxDBReader(path: databaseURL)
        defer { reader.close() }
        let aggregate = try reader.aggregate(calendar: .current)
        let day = try XCTUnwrap(aggregate.perDay.values.first)

        XCTAssertEqual(day.inputTokens, 30)
        XCTAssertEqual(day.outputTokens, 2000)
        XCTAssertEqual(day.reasoningTokens, 300, "每行取 max(reasoning_tokens, raw.reasoning) 后再求和")
        XCTAssertEqual(day.cacheReadTokens, 11)
        XCTAssertEqual(day.cacheWriteTokens, 2)
    }

    func testV2CharacterAggregationUsesToolArgsExcludesResultsAndPreservesOutput() throws {
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        let toolCalls = "[{\"tool_call_args\":"
            + jsonString(String(repeating: "a", count: 100))
            + ",\"tool_call_result_data\":"
            + jsonString(String(repeating: "r", count: 5000))
            + "}]"
        let validData = "{\"thinking_content\":"
            + jsonString(String(repeating: "t", count: 8000))
            + ",\"msg_content\":"
            + jsonString(String(repeating: "c", count: 2000))
            + ",\"tool_calls\":"
            + toolCalls
            + "}"
        let databaseURL = try makeV2Database(
            tokenRows: [TokenRow(sessionID: "s", turnID: "uuid-turn", timestampMs: base,
                                 input: 0, output: 1000, reasoning: 0, cacheRead: 0, cacheWrite: 0, raw: nil)],
            messageRows: [
                MessageRow(sessionID: "s", messageID: "bad", timestampMs: base, data: "{malformed"),
                MessageRow(sessionID: "s", messageID: "msg", timestampMs: base + 100, data: validData),
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let reader = try MinimaxDBReader(path: databaseURL)
        defer { reader.close() }
        let aggregate = try reader.aggregate(calendar: .current)
        let day = try XCTUnwrap(aggregate.perDay.values.first)
        let chars = try XCTUnwrap(aggregate.perDayChars[day.dayStart])
        XCTAssertEqual(chars.messageCount, 2)
        XCTAssertEqual(chars.reason, 8000)
        XCTAssertEqual(chars.output, 2100, "msg_content + tool_call_args；不包含 tool_call_result_data")

        let adjusted = try XCTUnwrap(
            MinimaxLocalUsageScanner.applyReasoningSplit(
                perDay: aggregate.perDay,
                perDayChars: aggregate.perDayChars
            )[day.dayStart]
        )
        XCTAssertEqual(adjusted.reasoningTokens, 792)
        XCTAssertEqual(adjusted.outputTokens, 208)
        XCTAssertEqual(adjusted.reasoningTokens + adjusted.outputTokens, 1000)
        XCTAssertEqual(adjusted.totalTokens, 1000)
    }

    /// 把 message 表替换成缺 `data_json` 列的坏 schema，让字符聚合 SQL 确定性失败。
    private func breakMessageTableSchema(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "MinimaxV2UsageTests", code: 6)
        }
        defer { sqlite3_close(database) }
        try execute(
            """
            DROP TABLE local_runtime_message_rows;
            CREATE TABLE local_runtime_message_rows (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                msg_id TEXT NOT NULL,
                role TEXT,
                turn_id TEXT,
                created_at_ms INTEGER NOT NULL
            );
            """,
            database: database
        )
    }

    /// 修复 message 表 schema 并写入一条 assistant 字符数据（reason 30 / output 10）。
    private func repairMessageTableWithCharData(at url: URL, timestampMs: Int64) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "MinimaxV2UsageTests", code: 7)
        }
        defer { sqlite3_close(database) }
        try execute(
            "ALTER TABLE local_runtime_message_rows ADD COLUMN data_json TEXT NOT NULL DEFAULT '{}'",
            database: database
        )
        let sql = """
        INSERT INTO local_runtime_message_rows
          (session_id, msg_id, role, created_at_ms, data_json)
        VALUES ('s', 'msg-fixed', 'assistant', ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "MinimaxV2UsageTests", code: 8)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, timestampMs)
        let data = "{\"thinking_content\":\"\(String(repeating: "r", count: 30))\",\"msg_content\":\"\(String(repeating: "o", count: 10))\"}"
        sqlite3_bind_text(statement, 2, data, -1, transientDestructor)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    func testV2CharSQLFailureKeepsTokenLedgerAndMarksDegradedForRetry() throws {
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        let databaseURL = try makeV2Database(
            tokenRows: [TokenRow(sessionID: "s", turnID: "uuid-turn", timestampMs: base,
                                 input: 100, output: 1000, reasoning: 0, cacheRead: 20, cacheWrite: 0, raw: nil)]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        try breakMessageTableSchema(at: databaseURL)

        let reader = try MinimaxDBReader(path: databaseURL)
        defer { reader.close() }
        let aggregate = try reader.aggregate(calendar: .current)

        // 主 token 账本必须保留。
        let day = try XCTUnwrap(aggregate.perDay.values.first)
        XCTAssertEqual(day.inputTokens, 100)
        XCTAssertEqual(day.outputTokens, 1000)
        XCTAssertEqual(day.cacheReadTokens, 20)
        // 字符数据为空 + degraded 标记，Reason 走 0。
        XCTAssertTrue(aggregate.perDayChars.isEmpty)
        XCTAssertTrue(aggregate.charAggregationDegraded, "字符 SQL 失败必须显式标记 degraded，不得静默")

        let adjusted = MinimaxLocalUsageScanner.applyReasoningSplit(
            perDay: aggregate.perDay,
            perDayChars: aggregate.perDayChars
        )
        XCTAssertEqual(adjusted[day.dayStart]?.reasoningTokens, 0, "无字符数据时 Reason 必须为 0，不能猜")
    }

    func testV2DegradedSourceIsRetriedAndRecovers() throws {
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        let databaseURL = try makeV2Database(
            tokenRows: [TokenRow(sessionID: "s", turnID: "uuid-turn", timestampMs: base,
                                 input: 100, output: 1000, reasoning: 0, cacheRead: 0, cacheWrite: 0, raw: nil)]
        )
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-v2-degraded-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: cacheDir)
        }
        try breakMessageTableSchema(at: databaseURL)

        let calendar = Calendar.current
        let fileManager = FileManagerBox()
        let scanOnce: () throws -> MinimaxLocalUsage = {
            try MinimaxLocalUsageScanner.performScanPureImpl(
                runtimeDBURL: databaseURL,
                cacheDir: cacheDir,
                fileManager: fileManager,
                calendar: calendar,
                now: { Date() },
                shouldSave: true
            )
        }

        #if DEBUG
        MinimaxDBReader.testCharAggregateAttempts = 0
        #endif
        _ = try scanOnce()

        // 第一次扫描：degraded 状态写入缓存指纹。
        let index1 = try MinimaxLocalUsageScanner.loadIndex(cacheDir: cacheDir, fileManager: fileManager)
        let entry1 = try XCTUnwrap(index1.sources["runtime"])
        XCTAssertEqual(entry1.charSplitDegraded, true, "degraded 必须写入 source entry 供下次重试判定")
        XCTAssertEqual(entry1.eventCount, 1, "主账本成功，event 数不丢")

        // db 完全不变：degraded source 仍必须强制重扫（重试语义）。
        _ = try scanOnce()
        #if DEBUG
        XCTAssertEqual(
            MinimaxDBReader.testCharAggregateAttempts, 2,
            "指纹未变化的 degraded source 也要重新尝试字符聚合"
        )
        #endif

        // 修复 schema（db mtime 变化）：重扫后恢复字符分摊并清除 degraded 标记。
        try repairMessageTableWithCharData(at: databaseURL, timestampMs: base)
        _ = try scanOnce()
        let index3 = try MinimaxLocalUsageScanner.loadIndex(cacheDir: cacheDir, fileManager: fileManager)
        let entry3 = try XCTUnwrap(index3.sources["runtime"])
        XCTAssertNotEqual(entry3.charSplitDegraded, true, "成功重聚合并完成字符分摊后必须清除 degraded 标记")

        let adjustedDay = try XCTUnwrap(index3.dailyBySource["runtime"]?.values.first)
        XCTAssertEqual(adjustedDay.reasoningTokens, 750, "30/(30+10) × 1000")
        XCTAssertEqual(adjustedDay.outputTokens, 250)
    }

    func testV2UnsafeCharacterRatioDropsOnlyMisalignedDay() {
        let day = Calendar.current.startOfDay(for: Date())
        let usage = MinimaxDailyUsage(dayStart: day, outputTokens: 100, rounds: 1)
        let aggregate = MinimaxDBAggregate(
            perDay: [day: usage],
            perDayChars: [day: MinimaxCharCounts(reason: 10, output: 10, messageCount: 3)],
            sessionCount: 1,
            eventCount: 1,
            turnCount: 1
        )

        let safe = MinimaxLocalUsageScanner.filterUnsafeV2CharCounts(
            aggregate: aggregate,
            ratioThreshold: 2
        )
        XCTAssertTrue(safe.isEmpty, "messageCount / rounds > 2 时必须跳过字符分摊")

        let aligned = MinimaxDBAggregate(
            perDay: [day: usage],
            perDayChars: [day: MinimaxCharCounts(reason: 10, output: 10, messageCount: 2)],
            sessionCount: 1,
            eventCount: 1,
            turnCount: 1
        )
        XCTAssertNotNil(
            MinimaxLocalUsageScanner.filterUnsafeV2CharCounts(
                aggregate: aligned,
                ratioThreshold: 2
            )[day]
        )
    }

    func testV2CacheMigrationResetsLegacySourceData() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-v2-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let day = Calendar.current.startOfDay(for: Date())
        let old = MinimaxLocalUsageScanner.CacheIndex(
            version: 11,
            lastScannedAt: day,
            sources: [:],
            dailyBySource: ["main": ["legacy": MinimaxDailyUsage(dayStart: day, inputTokens: 999)]],
            samplesBySource: nil
        )
        try ScannerIndexIO.saveIndex(old, cacheDir: cacheDir, fileManager: FileManagerBox())

        let current = try MinimaxLocalUsageScanner.loadIndex(
            cacheDir: cacheDir,
            fileManager: FileManagerBox()
        )
        XCTAssertEqual(current.version, 14)
        XCTAssertTrue(current.sources.isEmpty)
        XCTAssertTrue(current.dailyBySource.isEmpty)
        XCTAssertEqual(current.samplesBySource, [:])
    }

    func testScannerReadsOnlyRuntimeDatabaseEvenWhenSiblingLegacyDatabaseExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-v2-only-\(UUID().uuidString)", isDirectory: true)
        let runtimeURL = root.appendingPathComponent("v2/runtime-state.sqlite")
        let legacyURL = root.appendingPathComponent("sqlite.db")
        let cacheDir = root.appendingPathComponent("cache")
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        let runtime = try makeV2Database(
            at: runtimeURL,
            tokenRows: [TokenRow(sessionID: "runtime", turnID: "t", timestampMs: base,
                                 input: 7, output: 11, reasoning: 0, cacheRead: 0, cacheWrite: 0, raw: nil)]
        )
        defer {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(at: legacyURL)
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var legacyDatabase: OpaquePointer?
        XCTAssertEqual(sqlite3_open(legacyURL.path, &legacyDatabase), SQLITE_OK)
        if let legacyDatabase {
            defer { sqlite3_close(legacyDatabase) }
            try execute(
                "CREATE TABLE token_usage (session_id TEXT, turn_id TEXT, ts INTEGER, input_tokens INTEGER, output_tokens INTEGER); INSERT INTO token_usage VALUES ('legacy', 'legacy-turn', "
                    + String(base)
                    + ", 999999, 999999);",
                database: legacyDatabase
            )
        }

        let result = try MinimaxLocalUsageScanner.performScanPureImpl(
            runtimeDBURL: runtimeURL,
            cacheDir: cacheDir,
            fileManager: FileManagerBox(),
            calendar: .current,
            now: { Date(timeIntervalSince1970: Double(base) / 1000) },
            shouldSave: true
        )
        XCTAssertEqual(result.eventCount, 1)
        XCTAssertEqual(result.sessionCount, 1)
        XCTAssertEqual(result.today?.inputTokens, 7)
        XCTAssertNotEqual(result.today?.inputTokens, 999999)
    }

    func testPerRowReasoningExprTakesMaxOfNativeAndRaw() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-dual-reasoning-\(UUID().uuidString).sqlite")
        let db = try makeV2Database(
            at: dbURL,
            tokenRows: [
                TokenRow(
                    sessionID: "s1", turnID: "t1", timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
                    input: 10, output: 20, reasoning: 50, cacheRead: 0, cacheWrite: 0,
                    raw: "{\"reasoning\": 100}" // reasoning_tokens=50, raw.reasoning=100 -> MAX is 100
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: db) }

        let reader = try MinimaxDBReader(path: dbURL, readOnly: true)
        let aggregate = try reader.aggregate()
        let daily = aggregate.perDay.values.first
        XCTAssertEqual(daily?.reasoningTokens, 100, "单行同时有 native(50) + raw(100) 时，SQL perRowReasoningExpr 应取 MAX (100)")
    }
}
