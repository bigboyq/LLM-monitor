import XCTest
import SQLite3
@testable import LLM_monitor

/// v2 本地用量扫描器（`MinimaxLocalUsageScanner`）：缓存恢复、日桶裁剪、degraded
/// 重试与恢复、字符分摊的安全过滤、缓存迁移、只读 v2 库与失败会话计数。
///
/// 拆自 `MinimaxV2UsageTests`（去版本号改名），逐字搬移零逻辑变化。
/// v2 DB 的构造 fixture 在 `MinimaxDBReaderTests.swift` 的文件作用域（同模块可见）。
final class MinimaxLocalUsageScannerTests: XCTestCase {

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
            samplesBySource: nil,
            calendarSignature: LocalUsageCalendarSignature.make(calendar)
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

    /// 卫生清理：写回 index 前裁剪严格早于 8 天窗口的日桶（与 samples 的
    /// `-8 * 24 * 60 * 60` 谓词同式）。构造含 10 天前桶的缓存且 source 指纹
    /// 新鲜（不 dirty、不走 SQL 聚合，dailyBySource 不会被整体替换），扫描后
    /// 旧桶被裁、7 天内的桶与 samples 不受影响、eventCount 不变。
    func testPrunesDailyBucketsOlderThanEightDayWindowOnSave() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-prune-\(UUID().uuidString)", isDirectory: true)
        let runtimeURL = root.appendingPathComponent("v2/runtime-state.sqlite")
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtimeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try Data(repeating: 4, count: 64).write(to: runtimeURL)
        defer { try? FileManager.default.removeItem(at: root) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let attributes = try FileManager.default.attributesOfItem(atPath: runtimeURL.path)
        let modifiedAt = try XCTUnwrap(attributes[.modificationDate] as? Date)
        let mtimeMs = modifiedAt.timeIntervalSince1970 * 1000
        let sizeBytes = try XCTUnwrap((attributes[.size] as? NSNumber)?.intValue)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDayStart = try XCTUnwrap(
            calendar.date(byAdding: .day, value: -10, to: now).map { calendar.startOfDay(for: $0) }
        )
        let recentDayStart = try XCTUnwrap(
            calendar.date(byAdding: .day, value: -2, to: now).map { calendar.startOfDay(for: $0) }
        )
        let oldDayKey = LocalUsageDayKey.make(oldDayStart, calendar: calendar)
        let recentDayKey = LocalUsageDayKey.make(recentDayStart, calendar: calendar)

        let seededSample = LocalTokenUsageSample(
            completedAt: recentDayStart.addingTimeInterval(3_600),
            modelName: "MiniMax-M3",
            promptID: "runtime:turn-1",
            inputTokens: 9,
            cachedInputTokens: 0,
            outputTokens: 5,
            reasoningOutputTokens: 0
        )
        let index = MinimaxLocalUsageScanner.CacheIndex(
            version: 14,
            lastScannedAt: now.addingTimeInterval(-60),
            sources: ["runtime": MinimaxLocalUsageScanner.SourceIndexEntry(
                mtimeMs: mtimeMs,              // 新鲜指纹 → 不 dirty、不走 SQL
                sizeBytes: sizeBytes,
                walMtimeMs: 0,
                walSizeBytes: 0,
                scannedAt: now.addingTimeInterval(-60),
                eventCount: 3,
                sessionCount: 1
            )],
            dailyBySource: ["runtime": [
                oldDayKey: MinimaxDailyUsage(
                    dayStart: oldDayStart, inputTokens: 100, outputTokens: 50,
                    cacheReadTokens: 2, reasoningTokens: 1, totalTokens: 153,
                    turns: 2, rounds: 4
                ),
                recentDayKey: MinimaxDailyUsage(
                    dayStart: recentDayStart, inputTokens: 10, outputTokens: 5,
                    cacheReadTokens: 2, reasoningTokens: 1, totalTokens: 18,
                    turns: 1, rounds: 2
                )
            ]],
            samplesBySource: ["runtime": [seededSample]],
            calendarSignature: LocalUsageCalendarSignature.make(calendar)
        )
        try MinimaxLocalUsageScanner.saveIndex(index, cacheDir: cacheDir, fileManager: FileManagerBox())

        let result = try MinimaxLocalUsageScanner.performScanPureImpl(
            runtimeDBURL: runtimeURL,
            cacheDir: cacheDir,
            fileManager: FileManagerBox(),
            calendar: calendar,
            now: { now },
            shouldSave: true
        )

        let saved = try MinimaxLocalUsageScanner.loadIndex(cacheDir: cacheDir, fileManager: FileManagerBox())
        let byDay = try XCTUnwrap(saved.dailyBySource["runtime"])
        XCTAssertNil(byDay[oldDayKey], "10 天前的日桶必须在写回前被裁剪")
        XCTAssertEqual(byDay[recentDayKey]?.inputTokens, 10, "7 天内的日桶不受影响")
        XCTAssertEqual(
            saved.sources["runtime"]?.eventCount, 3,
            "eventCount 独立保存在 sources 条目里，不受日桶裁剪影响"
        )
        XCTAssertEqual(saved.samplesBySource?["runtime"]?.count, 1, "samples 不受日桶裁剪影响")

        // 消费面不受影响：7 天窗口仍包含保留桶，eventCount / samples 原样输出。
        XCTAssertEqual(result.failedSessionCount, 0)
        XCTAssertEqual(result.eventCount, 3)
        XCTAssertTrue(
            result.dailyTokenUsage.contains { $0.dayStart == recentDayStart && $0.inputTokens == 10 },
            "7 天窗口聚合必须保留未裁剪桶的数据"
        )
        XCTAssertEqual(result.recentSamples?.count, 1)
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

    // MARK: - 失败会话计数（自 UsableAPIKeyHealthLevelTests 解散归入）

    func testComputeFailedSessionCountRules() {
        XCTAssertEqual(MinimaxLocalUsageScanner.computeFailedSessionCount(failedKeys: [], currentSourceKeys: [], cachedSourceKeys: []), 0)
        XCTAssertEqual(MinimaxLocalUsageScanner.computeFailedSessionCount(failedKeys: [], currentSourceKeys: ["main", "runtime"], cachedSourceKeys: []), 2)
        XCTAssertEqual(MinimaxLocalUsageScanner.computeFailedSessionCount(failedKeys: ["main"], currentSourceKeys: ["main", "runtime"], cachedSourceKeys: ["main", "runtime"]), 1)
        XCTAssertEqual(MinimaxLocalUsageScanner.computeFailedSessionCount(failedKeys: ["main", "runtime"], currentSourceKeys: ["main", "runtime", "extra"], cachedSourceKeys: ["extra"]), 2)
    }
}
