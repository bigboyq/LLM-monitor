import XCTest
import SQLite3
@testable import LLM_monitor

final class CrossReviewDataTests: XCTestCase {
    func testOpenCodeCutoffUsesTheSameCallsForEveryDailyBucket() throws {
        let fixture = try ReviewDatabase()
        try fixture.execute("CREATE TABLE message(id TEXT, session_id TEXT, time_created INTEGER, data TEXT)")
        try fixture.execute("CREATE TABLE part(message_id TEXT, data TEXT)")
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let cutoff = yesterday.addingTimeInterval(12 * 3600)
        let calls: [(String, Date, String, Int)] = [
            ("excluded", cutoff.addingTimeInterval(-1), "reasoning", 400),
            ("yesterday", cutoff, "text", 100),
            ("today-reason", today.addingTimeInterval(1), "reasoning", 100),
            ("today-native", today.addingTimeInterval(2), "text", 100)
        ]
        for (id, date, kind, output) in calls {
            let native = id == "today-native" ? 25 : 0
            let data = "{\"role\":\"assistant\",\"providerID\":\"minimax\",\"parentID\":\"\(id)\",\"modelID\":\"MiniMax-M3\",\"tokens\":{\"input\":7,\"output\":\(output),\"reasoning\":\(native),\"cache\":{\"read\":3}}}"
            try fixture.execute("INSERT INTO message VALUES ('\(id)', 'session', \(Int64(date.timeIntervalSince1970 * 1000)), '\(data)')")
            try fixture.execute("INSERT INTO part VALUES ('\(id)', '{\"type\":\"\(kind)\",\"text\":\"characters\"}')")
        }
        let reader = try OpencodeDBReader(path: fixture.url)
        defer { reader.close() }
        let result = try reader.aggregate(calendar: calendar, sampleCutoff: cutoff)
        let samples = try XCTUnwrap(result.samples["minimax"])
        XCTAssertEqual(samples.count, 3)
        let daily = try XCTUnwrap(result.perProviderDay["minimax"])
        XCTAssertEqual(daily.count, 2)
        for (day, usage) in daily {
            let calls = samples.filter { calendar.startOfDay(for: $0.completedAt) == day }
            let buckets = calls.reduce(TokenUsageBuckets.zero) { $0 + TokenUsageBuckets.fromSample($1) }
            XCTAssertEqual(usage.inputTokens, buckets.input)
            XCTAssertEqual(usage.cacheReadTokens, buckets.cacheRead)
            XCTAssertEqual(usage.outputTokens, buckets.output)
            XCTAssertEqual(usage.reasoningTokens, buckets.reasoning)
            XCTAssertEqual(usage.totalTokens, buckets.totalTokens)
        }
        XCTAssertEqual(daily[today]?.outputTokens, 100)
        XCTAssertEqual(daily[today]?.reasoningTokens, 125, "Native reasoning is independent; only the other call is reclassified")
    }

    func testMiniMaxNativePairedAndFallbackCallsShareOneResidualBudget() throws {
        let fixture = try ReviewDatabase()
        try fixture.execute("""
            CREATE TABLE local_runtime_token_usage(session_id TEXT, turn_id TEXT, ts INTEGER,
                input_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER,
                cache_read_tokens INTEGER, cache_write_tokens INTEGER, raw TEXT, model TEXT)
            """)
        try fixture.execute("""
            CREATE TABLE local_runtime_message_rows(id INTEGER, session_id TEXT, turn_id TEXT,
                created_at_ms INTEGER, role TEXT, data_json TEXT)
            """)
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        for (index, name) in ["native", "paired", "fallback"].enumerated() {
            // ScannerIndexIO's existing ISO8601 cache contract stores whole
            // seconds. Keep this split/cache comparison fixture on that grid
            // rather than introducing unrelated timestamp precision loss.
            let timestampMs = ms + Int64(index) * 1000
            let native = name == "native" ? 20 : 0
            try fixture.execute("INSERT INTO local_runtime_token_usage VALUES ('s', '\(name)', \(timestampMs), 0, 100, \(native), 0, 0, '{}', 'MiniMax-M3')")
            let thinking = name == "native" ? 20 : name == "paired" ? 80 : 100
            let visible = 100 - thinking
            let turn = name == "fallback" ? "NULL" : "'\(name)'"
            let data = "{\"thinking_content\":\"\(String(repeating: "r", count: thinking))\",\"msg_content\":\"\(String(repeating: "v", count: visible))\",\"usage\":{\"input_tokens\":0,\"output_tokens\":100,\"request_duration_ms\":1000,\"decode_duration_ms\":500}}"
            try fixture.execute("INSERT INTO local_runtime_message_rows VALUES (\(index), 's', \(turn), \(timestampMs), 'assistant', '\(data)')")
        }
        let snapshot = try MinimaxLocalUsageScanner.performScanPureImpl(
            runtimeDBURL: fixture.url, cacheDir: fixture.root.appendingPathComponent("cache"),
            fileManager: FileManagerBox(), calendar: .current, now: { now }, shouldSave: true
        )
        let calls = try XCTUnwrap(snapshot.recentSamples)
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.map(\.reasoningOutputTokens), [20, 80, 100])
        XCTAssertEqual(calls.map(\.outputTokens), [80, 20, 0])
        XCTAssertEqual(snapshot.today?.reasoningTokens, 200)
        XCTAssertEqual(snapshot.today?.outputTokens, 100)
        XCTAssertEqual(snapshot.today?.totalTokens, 300)
        let warm = try MinimaxLocalUsageScanner.performScanPureImpl(
            runtimeDBURL: fixture.url, cacheDir: fixture.root.appendingPathComponent("cache"),
            fileManager: FileManagerBox(), calendar: .current, now: { now }, shouldSave: true
        )
        XCTAssertEqual(warm, snapshot, "The warm fingerprint path must preserve the same split")
    }

    func testAgyKnownExclusionsAndMissingTimingUseDifferentFallbackPaths() {
        let now = Date()
        let raw = AgyRawModelRow(createdAt: now, stepIndex: 1, inputTokens: 0,
            cacheReadTokens: 0, outputTokens: 100, thinkingChars: 0, visibleChars: 100,
            rowType: "PLANNER_RESPONSE", hasToolCalls: true)
        for timing in [
            AntigravityStepTimestampReader.LLMCallTiming(ttftSeconds: 1, streamingSeconds: 10, isToolCall: true),
            AntigravityStepTimestampReader.LLMCallTiming(ttftSeconds: 1, streamingSeconds: 0.1, isToolCall: false)
        ] {
            var context = AgyLocalUsageAggregation.AgySessionDurationContext(planATimings: [1: timing])
            context.recordMeteredRow(raw)
            context.recordGenericMarker(stepIndex: 2, createdAt: now.addingTimeInterval(20))
            var usages = [AgyLocalUsageAggregation.makeUsage(raw: raw, sessionID: "s", modelName: "gemini", planATiming: timing)]
            AgyLocalUsageAggregation.settleFallbackDurations(into: &usages, context: context)
            XCTAssertNil(usages[0].durationSeconds)
        }
        var context = AgyLocalUsageAggregation.AgySessionDurationContext()
        context.recordMeteredRow(raw)
        context.recordGenericMarker(stepIndex: 2, createdAt: now.addingTimeInterval(20))
        var usages = [AgyLocalUsageAggregation.makeUsage(raw: raw, sessionID: "s", modelName: "gemini")]
        AgyLocalUsageAggregation.settleFallbackDurations(into: &usages, context: context)
        XCTAssertEqual(usages[0].durationSeconds, 20)
    }

    func testMiniMaxAllCountFieldsKeepIntegerBoundsWithoutFloatingPoint() throws {
        let keys = ["current_interval_total_count", "current_interval_usage_count", "current_weekly_total_count", "current_weekly_usage_count"]
        for key in keys {
            for value in ["-9223372036854775808", "9223372036854775808", "1.25", "true", "\"3\""] {
                let data = Data("{\"model_name\":\"general\",\"\(key)\":\(value)}".utf8)
                XCTAssertThrowsError(try JSONDecoder().decode(MinimaxModelRemain.self, from: data), "\(key)=\(value)")
            }
            let data = Data("{\"model_name\":\"general\",\"\(key)\":9223372036854775807}".utf8)
            let decoded = try JSONDecoder().decode(MinimaxModelRemain.self, from: data)
            let values = [decoded.intervalTotalCount, decoded.intervalUsageCount, decoded.weeklyTotalCount, decoded.weeklyUsageCount]
            XCTAssertEqual(values.compactMap { $0 }, [Int.max])
        }
    }

    func testAgyDatabaseDisappearanceInvalidatesPreviouslyEnhancedCache() throws {
        let fixture = try ReviewDatabase(fileName: "session.db")
        try fixture.execute("CREATE TABLE steps(idx INTEGER, step_type INTEGER, metadata BLOB, step_payload BLOB)")
        try fixture.execute("CREATE TABLE gen_metadata(idx INTEGER, data BLOB)")
        let usage: [UInt8] = [0x18, 100, 0x48, 80, 0x50, 20]
        let key = Array("last_step_index".utf8)
        let attribute: [UInt8] = [0x0a, UInt8(key.count)] + key + [0x12, 1, 0x30]
        let event: [UInt8] = [0x22, UInt8(usage.count)] + usage + [0xa2, 1, UInt8(attribute.count)] + attribute
        let blob: [UInt8] = [0x0a, UInt8(event.count)] + event
        let hex = blob.map { String(format: "%02x", $0) }.joined()
        try fixture.execute("INSERT INTO gen_metadata VALUES (0, X'\(hex)')")
        let brain = fixture.root.appendingPathComponent("brain")
        let transcript = brain.appendingPathComponent("session/.system_generated/logs/transcript.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        let row = "{\"source\":\"MODEL\",\"status\":\"DONE\",\"created_at\":\"\(timestamp)\",\"step_index\":1,\"input_tokens\":1,\"cache_read_tokens\":0,\"output_tokens\":100,\"content\":\"visible\"}\n"
        try Data(row.utf8).write(to: transcript)
        func scan() throws -> AgyLocalUsage {
            try AgyLocalUsageScanner.performScanPure(brainRoot: brain, logDirectory: fixture.root.appendingPathComponent("logs"),
                cacheDir: fixture.root.appendingPathComponent("cache"), fileManager: FileManagerBox(),
                calendar: .current, now: { now }, conversationsDirectory: fixture.root)
        }
        XCTAssertEqual(try scan().recentSamples.first?.reasoningOutputTokens, 80)
        XCTAssertEqual(try scan().recentSamples.first?.reasoningOutputTokens, 80)
        try FileManager.default.removeItem(at: fixture.url)
        XCTAssertEqual(try scan().recentSamples.first?.reasoningOutputTokens, 0,
                       "A removed DB must not leave native usage frozen in the fingerprint cache")
        XCTAssertEqual(try scan().recentSamples.first?.reasoningOutputTokens, 0)
    }

    func testGLMExtremeNonnegativeUsedValuesRemainArithmeticSafe() throws {
        let overdrawn = Data("{\"code\":200,\"data\":{\"limits\":[{\"type\":\"CREDIT_LIMIT\",\"unit\":3,\"number\":5,\"usage\":1,\"currentValue\":9223372036854775807}]}}".utf8)
        XCTAssertEqual(try GlmCodingPlanFetcher.parse(data: overdrawn).models.first?.intervalRemainingPercent, 0)
        for remaining in ["-9223372036854775808", "9223372036854775807"] {
            let data = Data("{\"code\":200,\"data\":{\"limits\":[{\"type\":\"CREDIT_LIMIT\",\"usage\":1,\"currentValue\":0,\"remaining\":\(remaining)}]}}".utf8)
            XCTAssertThrowsError(try GlmCodingPlanFetcher.parse(data: data))
        }
    }

    func testProcessTimeoutCoversPipeHeldByExitedProcessesDescendant() throws {
        let fixture = try ReviewDatabase()
        let started = Date()
        XCTAssertThrowsError(try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "(/bin/sleep 2; /usr/bin/printf late) & /usr/bin/printf head"],
            timeout: 0.15, standardOutputFile: fixture.root.appendingPathComponent("output"), maximumOutputBytes: 128)) { error in
            guard let runner = error as? ProcessRunner.RunnerError, case .timedOut = runner else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "EOF waiting is part of the timeout, even after the direct child exits")
    }

    func testProcessCancellationCoversPipeHeldAfterParentExit() async throws {
        let fixture = try ReviewDatabase()
        let ready = fixture.root.appendingPathComponent("ready")
        let output = fixture.root.appendingPathComponent("output")
        let task = Task.detached {
            try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "(/bin/sleep 2; /usr/bin/printf late) & /usr/bin/printf ready > '\(ready.path)'"],
                timeout: 5, standardOutputFile: output, maximumOutputBytes: 128)
        }
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let cancelled = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled pipe collection must throw") }
        catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 1)
    }

    func testProcessCollectsFinalStdoutAndStderrWithoutLosingLastChunk() throws {
        let result = try ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/usr/bin/printf stdout; /usr/bin/printf stderr >&2"], timeout: 2)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput, "stdout")
        XCTAssertEqual(result.standardError, "stderr")
    }
}

private final class ReviewDatabase {
    let root: URL
    let url: URL
    private var handle: OpaquePointer?
    init(fileName: String = "ledger.sqlite") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cross-review-data-\(UUID().uuidString)")
        url = root.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw NSError(domain: "ReviewDatabase", code: 1) }
    }
    deinit { sqlite3_close(handle); try? FileManager.default.removeItem(at: root) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "ReviewDatabase", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
        }
    }
}
