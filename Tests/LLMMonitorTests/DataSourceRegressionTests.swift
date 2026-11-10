import XCTest
import SQLite3
@testable import LLM_monitor

final class DataSourceRegressionTests: XCTestCase {
    func testMinimaxResidualRoundingConservesDailyBudgetAcrossSamples() {
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let samples = (0..<3).map {
            LocalTokenUsageSample(completedAt: now, modelName: "MiniMax-M3", promptID: "s:\($0)", inputTokens: 0, cachedInputTokens: 0, outputTokens: 1, reasoningOutputTokens: 0)
        }
        let result = MinimaxLocalUsageScanner.applyReasoningSplit(
            samples: samples, perSampleCallSplits: [],
            rawPerDay: [day: MinimaxDailyUsage(dayStart: day, outputTokens: 3)],
            adjustedPerDay: [day: MinimaxDailyUsage(dayStart: day, outputTokens: 1, reasoningTokens: 2)],
            calendar: .current
        )
        XCTAssertEqual(result.map(\.reasoningOutputTokens).reduce(0, +), 2)
        XCTAssertEqual(result.map(\.outputTokens).reduce(0, +), 1)
        XCTAssertTrue(result.allSatisfy { $0.outputTokens + $0.reasoningOutputTokens == 1 })
    }

    func testMinimaxRejectsOverflowAndPreservesLargeIntegerWithoutDoubleRounding() throws {
        for literal in ["9223372036854775808", "1.5", "-1", "true", #""12""#] {
            let json = "{\"model_remains\":[{\"model_name\":\"general\",\"current_interval_total_count\":\(literal),\"current_interval_remaining_percent\":100}],\"base_resp\":{\"status_code\":0}}"
            XCTAssertThrowsError(try MinimaxTokenPlanFetcher.parse(data: Data(json.utf8)), literal)
        }
        let json = #"{"model_remains":[{"model_name":"general","current_interval_total_count":9007199254740993,"current_interval_remaining_percent":100}],"base_resp":{"status_code":0}}"#
        XCTAssertEqual(try MinimaxTokenPlanFetcher.parse(data: Data(json.utf8)).models.first?.intervalTotalCount, 9_007_199_254_740_993)
    }

    func testDshStreamingOutputStopsAtBudgetWithoutTryingAnotherDecoder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-output-cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = root.appendingPathComponent("writer")
        try Data("#!/bin/sh\nexec /usr/bin/yes x\n".utf8).write(to: writer)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: writer.path)
        for decoder in ["zstd", "node"] {
            let output = root.appendingPathComponent(decoder + ".output")
            var located: [String] = []
            let started = Date()
            XCTAssertThrowsError(try DshLogDecoder.decompressToFile(
                input: root.appendingPathComponent("unused-input"), output: output,
                fileManager: FileManagerBox(), maximumOutputBytes: 128,
                executableLocator: { name, _ in
                    located.append(name)
                    return name == decoder ? writer : nil
                }
            )) { error in
                guard let decoderError = error as? DshLogDecoder.DecoderError,
                      case .outputTooLarge = decoderError else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
            let bytes = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber
            XCTAssertEqual(bytes?.intValue, 128, "实际落盘不得越过预算")
            XCTAssertEqual(located, decoder == "zstd" ? ["zstd"] : ["zstd", "node"], "超限不得换解压器重试")
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, "无限输出必须提前终止，不能等30秒超时")
        }
    }

    func testDshStreamingOutputAcceptsExactBudgetAndKeepsPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-output-exact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = root.appendingPathComponent("writer")
        try Data("#!/bin/sh\nexec /usr/bin/printf abcdefgh\n".utf8).write(to: writer)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: writer.path)
        let output = root.appendingPathComponent("output")
        try DshLogDecoder.decompressToFile(
            input: root.appendingPathComponent("unused-input"), output: output,
            fileManager: FileManagerBox(), maximumOutputBytes: 8,
            executableLocator: { name, _ in name == "zstd" ? writer : nil }
        )
        XCTAssertEqual(try Data(contentsOf: output), Data("abcdefgh".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAgyDatabaseOnlyChangesInvalidateCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agy-data-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let brain = root.appendingPathComponent("brain")
        let logs = root.appendingPathComponent("log")
        let cache = root.appendingPathComponent("cache")
        let conversations = root.appendingPathComponent("conversations")
        let transcript = brain.appendingPathComponent("session/.system_generated/logs/transcript.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now)
        let row = "{\"source\":\"MODEL\",\"status\":\"DONE\",\"created_at\":\"\(iso)\",\"step_index\":1,\"input_tokens\":1,\"cache_read_tokens\":0,\"output_tokens\":100,\"content\":\"visible\"}\n"
        try Data(row.utf8).write(to: transcript)
        let first = try AgyLocalUsageScanner.performScanPure(brainRoot: brain, logDirectory: logs, cacheDir: cache, fileManager: FileManagerBox(), calendar: .current, now: { now })
        XCTAssertEqual(first.recentSamples.first?.reasoningOutputTokens, 0)
        func varint(_ n: UInt64) -> [UInt8] {
            var value = n
            var bytes: [UInt8] = []
            repeat { let low = UInt8(value & 127); value >>= 7; bytes.append(low | (value > 0 ? 128 : 0)) } while value > 0
            return bytes
        }
        func bytesField(_ n: UInt64, _ bytes: [UInt8]) -> [UInt8] { varint(n * 8 + 2) + varint(UInt64(bytes.count)) + bytes }
        func intField(_ n: UInt64, _ value: UInt64) -> [UInt8] { varint(n * 8) + varint(value) }
        let usage = intField(3, 100) + intField(9, 80) + intField(10, 20)
        let attr = bytesField(1, Array("last_step_index".utf8)) + bytesField(2, Array("0".utf8))
        let blob = bytesField(1, bytesField(4, usage) + bytesField(20, attr))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(conversations.appendingPathComponent("session.db").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE steps(idx INTEGER, step_type INTEGER, metadata BLOB, step_payload BLOB)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE gen_metadata(idx INTEGER, data BLOB)", nil, nil, nil), SQLITE_OK)
        let hex = blob.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO gen_metadata VALUES (0, X'\(hex)')", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let normal = try AgyLocalUsageScanner.performScanPure(brainRoot: brain, logDirectory: logs, cacheDir: cache, fileManager: FileManagerBox(), calendar: .current, now: { now })
        let full = try AgyLocalUsageScanner.performScanPure(brainRoot: brain, logDirectory: logs, cacheDir: cache, fileManager: FileManagerBox(), calendar: .current, now: { now }, forceFull: true)
        XCTAssertEqual(full.recentSamples.first?.reasoningOutputTokens, 80)
        XCTAssertEqual(normal.recentSamples.first?.reasoningOutputTokens, 80)

        // 写进程保持连接，后续 usage 更新只进入 WAL；主库指纹不变也必须重算。
        let dbURL = conversations.appendingPathComponent("session.db")
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        _ = try AgyLocalUsageScanner.performScanPure(brainRoot: brain, logDirectory: logs, cacheDir: cache, fileManager: FileManagerBox(), calendar: .current, now: { now })
        let before = try LogFileSnapshot(url: dbURL, fileManager: FileManagerBox()).fingerprint
        let updatedUsage = intField(3, 100) + intField(9, 40) + intField(10, 60)
        let updatedBlob = bytesField(1, bytesField(4, updatedUsage) + bytesField(20, attr))
        let updatedHex = updatedBlob.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(sqlite3_exec(db, "UPDATE gen_metadata SET data = X'\(updatedHex)'", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try LogFileSnapshot(url: dbURL, fileManager: FileManagerBox()).fingerprint, before)
        let walUpdated = try AgyLocalUsageScanner.performScanPure(brainRoot: brain, logDirectory: logs, cacheDir: cache, fileManager: FileManagerBox(), calendar: .current, now: { now })
        XCTAssertEqual(walUpdated.recentSamples.first?.reasoningOutputTokens, 40)
    }

    func testAgyKnownToolCallDoesNotRegainStreamingDuration() throws {
        let now = Date()
        let raw = AgyRawModelRow(createdAt: now, stepIndex: 1, inputTokens: 1, cacheReadTokens: 0, outputTokens: 100, thinkingChars: 0, visibleChars: 100, rowType: "PLANNER_RESPONSE", hasToolCalls: true)
        let timing = AntigravityStepTimestampReader.LLMCallTiming(ttftSeconds: 1, streamingSeconds: 10, isToolCall: true)
        var context = AgyLocalUsageAggregation.AgySessionDurationContext(planATimings: [1: timing])
        context.recordMeteredRow(raw)
        context.recordGenericMarker(stepIndex: 2, createdAt: now.addingTimeInterval(20))
        var usages = [AgyLocalUsageAggregation.makeUsage(raw: raw, sessionID: "session", modelName: "gemini", planATiming: timing)]
        XCTAssertNil(usages[0].durationSeconds)
        AgyLocalUsageAggregation.settleFallbackDurations(into: &usages, context: context)
        XCTAssertNil(usages[0].durationSeconds)
    }

    func testOpenCodeDailyAndSamplesConserveToday() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("data-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("db.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "DataAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
        }
        try exec("CREATE TABLE message(id TEXT, session_id TEXT, time_created INTEGER, data TEXT)")
        try exec("CREATE TABLE part(message_id TEXT, data TEXT)")
        let now = Date()
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        for id in ["one", "two"] {
            try exec("INSERT INTO message VALUES ('\(id)', 'session', \(ms), '{\"role\":\"assistant\",\"providerID\":\"minimax-cn-coding-plan\",\"parentID\":\"\(id)\",\"modelID\":\"MiniMax-M3\",\"tokens\":{\"input\":0,\"output\":100,\"reasoning\":0}}')")
        }
        try exec("INSERT INTO part VALUES ('one', '{\"type\":\"reasoning\",\"text\":\"\(String(repeating: "r", count: 100))\"}')")
        try exec("INSERT INTO part VALUES ('two', '{\"type\":\"text\",\"text\":\"\(String(repeating: "v", count: 1000))\"}')")
        let reader = try OpencodeDBReader(path: path)
        defer { reader.close() }
        let result = try reader.aggregate(calendar: .current)
        let provider = "minimax-cn-coding-plan"
        let daily = Array(try XCTUnwrap(result.perProviderDay[provider]).values)
        let samples = try XCTUnwrap(result.samples[provider])
        let projected = UnifiedDailyUsageNormalizer.includingCurrentDay(dailyTokenUsage: daily.map(UnifiedDailyTokenUsage.init), samples: samples, now: now)
        let today = try XCTUnwrap(projected.first { Calendar.current.isDate($0.dayStart, inSameDayAs: now) })
        XCTAssertEqual(today.totalTokens, 200)
    }

    func testMinimaxMixedPairedAndFallbackConserveToday() throws {
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let raw = MinimaxDailyUsage(dayStart: day, outputTokens: 200, totalTokens: 200, rounds: 2)
        let paired = MinimaxPairedSplitDay(reasonTokens: 100, outputTokens: 0, thinkingChars: 100, visibleChars: 0)
        let adjusted = MinimaxLocalUsageScanner.applyReasoningSplit(perDay: [day: raw], perDayChars: [day: MinimaxCharCounts(reason: 100, output: 100, messageCount: 2)], pairedSplits: [day: paired])
        let samples = ["one", "two"].map { LocalTokenUsageSample(completedAt: now, modelName: "MiniMax-M3", promptID: $0, inputTokens: 0, cachedInputTokens: 0, outputTokens: 100, reasoningOutputTokens: 0) }
        let split = MinimaxLocalUsageScanner.applyReasoningSplit(samples: samples, perSampleCallSplits: [MinimaxCallSplit(reasoningTokens: 100, outputTokens: 0), nil], rawPerDay: [day: raw], adjustedPerDay: adjusted, calendar: .current)
        let projected = UnifiedDailyUsageNormalizer.includingCurrentDay(dailyTokenUsage: adjusted.values.map(UnifiedDailyTokenUsage.init), samples: split, now: now)
        let today = try XCTUnwrap(projected.first)
        XCTAssertEqual(today.totalTokens, 200)
    }

    func testMinimaxCountAtIntMaxIsExact() throws {
        let json = #"{"model_remains":[{"model_name":"general","current_interval_total_count":9223372036854775807,"current_interval_usage_count":0,"current_interval_remaining_percent":100}],"base_resp":{"status_code":0}}"#
        let info = try MinimaxTokenPlanFetcher.parse(data: Data(json.utf8))
        XCTAssertEqual(info.models.first?.intervalTotalCount, Int.max)
    }

    func testGlmRejectsNegativeUsedBeforeSubtraction() throws {
        let json = #"{"code":200,"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":-9223372036854775808}]}}"#
        XCTAssertThrowsError(try GlmCodingPlanFetcher.parse(data: Data(json.utf8)))
    }
}
