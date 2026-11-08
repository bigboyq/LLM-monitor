import XCTest
import SQLite3
@testable import LLM_monitor

/// 缓存维护：8 天窗口外的日桶裁剪、v9 索引的 encode/decode 保真与旧版本
/// 重置语义（RPC 时代的打击计数/收敛字段已随数据源退役删除）。
final class AntigravityCacheMaintenanceTests: AntigravityScanTestCase {

    // MARK: - 日桶裁剪

    /// 卫生清理：写回 index 前裁剪严格早于 8 天窗口的日桶（与 samples 的
    /// `-LocalUsageRetentionWindow.seconds` 谓词同式）。构造含 10 天前桶的缓存且 session 指纹
    /// 新鲜（不触发读取、日桶不会被重算替换），扫描后旧桶被裁、7 天内的桶与
    /// samples 不受影响、eventCount 不变。
    func testPrunesDailyBucketsOlderThanEightDayWindowOnSave() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sessionID = "prune-session"
        let dbPath = fixture.conversations.appendingPathComponent("\(sessionID).db")
        try Data(repeating: 3, count: 128).write(to: dbPath)
        let values = try dbPath.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let liveMtimeMs = try XCTUnwrap(values.contentModificationDate).timeIntervalSince1970 * 1000
        let liveSizeBytes = try XCTUnwrap(values.fileSize)

        let now = dayStart(0).addingTimeInterval(3_600)
        let oldDayStart = dayStart(-10)
        let recentDayStart = dayStart(-2)
        let oldDayKey = LocalUsageDayKey.make(oldDayStart, calendar: testCalendar)
        let recentDayKey = LocalUsageDayKey.make(recentDayStart, calendar: testCalendar)

        let seededSample = LocalTokenUsageSample(
            completedAt: recentDayStart.addingTimeInterval(3_600),
            modelName: "gemini-3-pro",
            promptID: "\(sessionID):turn-1",
            inputTokens: 11,
            cachedInputTokens: 0,
            outputTokens: 7,
            reasoningOutputTokens: 0
        )
        let index = AntigravityLocalUsageScanner.CacheIndex(
            version: 10,
            lastScannedAt: now.addingTimeInterval(-60),
            sessions: [sessionID: .init(
                mtimeMs: liveMtimeMs,          // 新鲜指纹 → 不 dirty、不读库
                sizeBytes: liveSizeBytes,
                walMtimeMs: 0,
                walSizeBytes: 0,
                fetchedAt: now.addingTimeInterval(-60),
                eventCount: 4
            )],
            dailyBySession: [sessionID: [
                oldDayKey: AntigravityDailyUsage(dayStart: oldDayStart, inputTokens: 100, totalTokens: 100),
                recentDayKey: AntigravityDailyUsage(dayStart: recentDayStart, inputTokens: 200, totalTokens: 200)
            ]],
            samplesBySession: [sessionID: [seededSample]],
            calendarSignature: LocalUsageCalendarSignature.make(testCalendar)
        )
        try saveScanIndex(index, fixture: fixture)

        let result = try await runScan(fixture: fixture, now: now)

        let saved = try loadScanIndex(fixture)
        let byDay = try XCTUnwrap(saved.dailyBySession[sessionID])
        XCTAssertNil(byDay[oldDayKey], "10 天前的日桶必须在写回前被裁剪")
        XCTAssertEqual(byDay[recentDayKey]?.inputTokens, 200, "7 天内的日桶不受影响")
        XCTAssertEqual(
            saved.sessions[sessionID]?.eventCount, 4,
            "eventCount 独立保存在 sessions 条目里，不受日桶裁剪影响"
        )
        XCTAssertEqual(saved.samplesBySession?[sessionID]?.count, 1, "samples 不受日桶裁剪影响")

        // 消费面不受影响：7 天窗口仍包含保留桶，eventCount / samples 原样输出。
        XCTAssertEqual(result.failedSessionCount, 0)
        XCTAssertEqual(result.eventCount, 4)
        XCTAssertTrue(
            result.dailyTokenUsage.contains { $0.dayStart == recentDayStart && $0.inputTokens == 200 },
            "7 天窗口聚合必须保留未裁剪桶的数据"
        )
        XCTAssertEqual(result.recentSamples?.count, 1)
    }

    // MARK: - v9 索引编解码与旧版本重置

    /// v9 条目只含指纹 + eventCount；encode/decode 保真，且 RPC 时代的
    /// offset/strikes 字段不再出现（多余 JSON 键被忽略，向后无包袱）。
    func testV9SessionIndexEntryRoundTripIgnoresLegacyFields() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // 旧 v8 条目形态（带 offset / suffix 状态字段）：v9 解码器按 v9 键集
        // 解码，旧键静默丢弃——但整份 v8 索引在 loadIndex 处整体重置，见下。
        let legacyJSON = """
        {"mtimeMs":1.0,"sizeBytes":2,"walMtimeMs":0.0,"walSizeBytes":0,"eventCount":5,\
        "generatorMetadataOffset":5,"consecutiveEmptySuffixes":2,"lastEmptySuffixAt":"2026-09-22T00:00:00Z"}
        """
        let entry = try decoder.decode(
            AntigravityLocalUsageScanner.SessionIndexEntry.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(entry.eventCount, 5)
        XCTAssertEqual(entry.sizeBytes, 2)
        XCTAssertNil(entry.consecutiveReadFailures, "旧 v9 缓存无此键：decodeIfPresent 兼容")

        let now = Date()
        let v9 = AntigravityLocalUsageScanner.SessionIndexEntry(
            mtimeMs: 1234567890.0,
            sizeBytes: 8421376,
            walMtimeMs: 1234567895.0,
            walSizeBytes: 4096,
            fetchedAt: now,
            eventCount: 50
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(v9)
        let decoded = try decoder.decode(
            AntigravityLocalUsageScanner.SessionIndexEntry.self,
            from: data
        )
        XCTAssertEqual(decoded.mtimeMs, v9.mtimeMs)
        XCTAssertEqual(decoded.sizeBytes, v9.sizeBytes)
        XCTAssertEqual(decoded.walMtimeMs, v9.walMtimeMs)
        XCTAssertEqual(decoded.walSizeBytes, v9.walSizeBytes)
        XCTAssertEqual(decoded.eventCount, v9.eventCount)
        // ISO8601 策略只保留整秒。
        let decodedFetchedAt = try XCTUnwrap(decoded.fetchedAt)
        XCTAssertEqual(decodedFetchedAt.timeIntervalSince(v9.fetchedAt!), 0.0, accuracy: 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["generatorMetadataOffset"], "v9 不再写 RPC 增量状态字段")
        XCTAssertNil(json["consecutiveEmptySuffixes"])
        XCTAssertNil(json["lastMaxStepIndex"])
    }

    /// v9 schema 内演进：`consecutiveReadFailures`（可重试读失败有界收敛计数）
    /// encode/decode 保真；健康态 nil 不落盘（合成 Codable 对 Optional 走
    /// `encodeIfPresent`）。
    func testConsecutiveReadFailuresRoundTrip() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let streaked = AntigravityLocalUsageScanner.SessionIndexEntry(
            mtimeMs: 1.0, sizeBytes: 2, walMtimeMs: 0, walSizeBytes: 0,
            fetchedAt: nil, eventCount: 3, consecutiveReadFailures: 2
        )
        let decoded = try decoder.decode(
            AntigravityLocalUsageScanner.SessionIndexEntry.self,
            from: try encoder.encode(streaked)
        )
        XCTAssertEqual(decoded.consecutiveReadFailures, 2)
        XCTAssertEqual(decoded.eventCount, 3)

        let healthyData = try encoder.encode(AntigravityLocalUsageScanner.SessionIndexEntry(
            mtimeMs: 1.0, sizeBytes: 2, walMtimeMs: 0, walSizeBytes: 0,
            fetchedAt: nil, eventCount: 3
        ))
        let healthyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: healthyData) as? [String: Any]
        )
        XCTAssertNil(healthyJSON["consecutiveReadFailures"], "健康态（nil）不落盘")
    }

    /// v8 及更早索引加载即重置为空缓存（log 一行说明，由 ScannerIndexIO 打出）：
    /// sessions/daily/samples 全清，首轮扫描对全部 session 全量重读重建。
    func testLoadIndexResetsV8AndEarlierToEmpty() throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stale = AntigravityLocalUsageScanner.CacheIndex(
            version: 8,
            lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessions: ["legacy": .init(
                mtimeMs: 1, sizeBytes: 2, walMtimeMs: 0, walSizeBytes: 0,
                fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
                eventCount: 9
            )],
            dailyBySession: ["legacy": [dayKey(0): AntigravityDailyUsage(
                dayStart: dayStart(0), inputTokens: 500, totalTokens: 500
            )]],
            samplesBySession: ["legacy": []],
            calendarSignature: LocalUsageCalendarSignature.make(testCalendar)
        )
        try saveScanIndex(stale, fixture: fixture)

        let loaded = try loadScanIndex(fixture)
        XCTAssertEqual(loaded.version, 10)
        XCTAssertTrue(loaded.sessions.isEmpty, "v8 session 条目不继承")
        XCTAssertTrue(loaded.dailyBySession.isEmpty, "v8 daily 全清")
        XCTAssertTrue(loaded.samplesBySession?.isEmpty == true, "v8 samples 全清")
        XCTAssertNil(loaded.calendarSignature, "签名随重置清空，等待当前日历重建")
        XCTAssertEqual(loaded.lastScannedAt, Date(timeIntervalSince1970: 0))
    }

    /// v9 完整索引 round-trip（sessions / daily / samples / 签名）。
    func testV9CacheIndexRoundTrip() throws {
        let now = Date()
        let entry = AntigravityLocalUsageScanner.SessionIndexEntry(
            mtimeMs: 1234567890.0,
            sizeBytes: 8421376,
            fetchedAt: now,
            eventCount: 50
        )
        let dayUsage = AntigravityDailyUsage(
            dayStart: now, inputTokens: 100, outputTokens: 50, totalTokens: 150
        )
        let index = AntigravityLocalUsageScanner.CacheIndex(
            version: 10,
            lastScannedAt: now,
            sessions: ["session-1": entry],
            dailyBySession: ["session-1": [LocalUsageDayKey.make(now): dayUsage]],
            samplesBySession: ["session-1": []],
            calendarSignature: "gregorian|UTC"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(index)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AntigravityLocalUsageScanner.CacheIndex.self, from: data)

        XCTAssertEqual(decoded.version, 10)
        XCTAssertEqual(decoded.sessions["session-1"]?.mtimeMs, 1234567890.0)
        XCTAssertEqual(decoded.sessions["session-1"]?.eventCount, 50)
        XCTAssertEqual(decoded.dailyBySession["session-1"]?.count, 1)
        XCTAssertEqual(decoded.calendarSignature, "gregorian|UTC")
    }
}
