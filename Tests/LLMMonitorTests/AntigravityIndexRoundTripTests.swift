import XCTest
import SQLite3
@testable import LLM_monitor

/// `index.json` 的 round-trip、v5 / v6 迁移，以及增量 turn/round 明细与 samples。
final class AntigravityIndexRoundTripTests: AntigravityTestCase {

    // MARK: - 测试

    func testComputeTurnRoundCountsPureRPC() throws {
        let events: [AntigravityFetcher.UsageEvent] = [
            makeEvent(timestamp: Date(timeIntervalSince1970: 1_700_000_000), input: 100, output: 50, total: 150)
        ]
        let counts = AntigravityLocalUsageScanner.computeTurnRoundCounts(
            sessionID: "fake-session",
            events: events,
            calendar: .current
        )
        XCTAssertEqual(counts.perDay.count, 1, "纯 RPC 模式下计算 1 天的 R/T")
        XCTAssertEqual(counts.totalTurns, 1)
        XCTAssertEqual(counts.totalRounds, 1)
    }

    func testCacheIndexRoundTrip() throws {
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
            version: 1,
            lastScannedAt: now,
            sessions: ["session-1": entry],
            dailyBySession: ["session-1": [LocalUsageDayKey.make(now): dayUsage]]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(index)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AntigravityLocalUsageScanner.CacheIndex.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.sessions["session-1"]?.mtimeMs, 1234567890.0)
        XCTAssertEqual(decoded.sessions["session-1"]?.eventCount, 50)
        XCTAssertEqual(decoded.dailyBySession["session-1"]?.count, 1)
    }

    func testCacheIndexV5MigrationForcesPureRPCRescan() throws {
        let fm = FileManager.default
        let cacheDir = fm.temporaryDirectory
            .appendingPathComponent("antigravity-cache-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: cacheDir) }
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let now = Date()
        let sample = LocalTokenUsageSample(
            completedAt: now,
            modelName: "gemini-2.5-pro",
            promptID: "session-1:turn-0",
            inputTokens: 10,
            cachedInputTokens: 0,
            outputTokens: 5,
            reasoningOutputTokens: 0
        )
        let index = AntigravityLocalUsageScanner.CacheIndex(
            version: 5,
            lastScannedAt: now,
            sessions: ["session-1": AntigravityLocalUsageScanner.SessionIndexEntry(
                mtimeMs: 1,
                sizeBytes: 2,
                fetchedAt: now,
                eventCount: 1
            )],
            dailyBySession: ["session-1": [
                "2026-08-04": AntigravityDailyUsage(dayStart: now, turns: 1, rounds: 1)
            ]],
            samplesBySession: ["session-1": [sample]]
        )
        try AntigravityLocalUsageScanner.saveIndex(index, cacheDir: cacheDir, fileManager: FileManagerBox(fm))

        let migrated = try AntigravityLocalUsageScanner.loadIndex(
            cacheDir: cacheDir,
            fileManager: FileManagerBox(fm)
        )

        XCTAssertEqual(migrated.version, 7)
        XCTAssertEqual(migrated.sessions.count, 1)
        XCTAssertTrue(migrated.samplesBySession?.isEmpty == true,
                      "v5 的逐次调用缓存必须清空，确保现有 session 重新走纯 RPC")
        XCTAssertEqual(migrated.dailyBySession["session-1"]?.first?.value.turns, 1,
                       "旧 daily 数据保留，RPC 失败时可作为 last-good fallback")
    }

    func testSessionIndexEntryOffsetRoundTrip() throws {
        let now = Date()
        let entry = AntigravityLocalUsageScanner.SessionIndexEntry(
            mtimeMs: 1234567890.0,
            sizeBytes: 8421376,
            walMtimeMs: 1234567895.0,
            walSizeBytes: 4096,
            fetchedAt: now,
            eventCount: 50,
            generatorMetadataOffset: 52,
            lastMaxStepIndex: 120,
            lastTurnIndex: 15
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AntigravityLocalUsageScanner.SessionIndexEntry.self, from: data)
        XCTAssertEqual(decoded.generatorMetadataOffset, 52)
        XCTAssertEqual(decoded.lastMaxStepIndex, 120)
        XCTAssertEqual(decoded.lastTurnIndex, 15)
        XCTAssertEqual(decoded.eventCount, 50)
    }

    func testCacheIndexV6MigrationPreservesSamplesAndUpgradesToV7() throws {
        let fm = FileManager.default
        let cacheDir = fm.temporaryDirectory
            .appendingPathComponent("antigravity-cache-v6-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: cacheDir) }
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let now = Date()
        let sample = LocalTokenUsageSample(
            completedAt: now,
            modelName: "gemini-2.5-pro",
            promptID: "session-1:turn-0",
            inputTokens: 10,
            cachedInputTokens: 0,
            outputTokens: 5,
            reasoningOutputTokens: 0
        )
        let index = AntigravityLocalUsageScanner.CacheIndex(
            version: 6,
            lastScannedAt: now,
            sessions: ["session-1": AntigravityLocalUsageScanner.SessionIndexEntry(
                mtimeMs: 1,
                sizeBytes: 2,
                fetchedAt: now,
                eventCount: 1
            )],
            dailyBySession: ["session-1": [
                "2026-08-04": AntigravityDailyUsage(dayStart: now, turns: 1, rounds: 1)
            ]],
            samplesBySession: ["session-1": [sample]]
        )
        try AntigravityLocalUsageScanner.saveIndex(index, cacheDir: cacheDir, fileManager: FileManagerBox(fm))

        let migrated = try AntigravityLocalUsageScanner.loadIndex(
            cacheDir: cacheDir,
            fileManager: FileManagerBox(fm)
        )

        XCTAssertEqual(migrated.version, 7)
        XCTAssertEqual(migrated.sessions.count, 1)
        XCTAssertEqual(migrated.sessions["session-1"]?.generatorMetadataOffset, 0, "旧版本未存 offset 时安全默认 0")
        XCTAssertEqual(migrated.samplesBySession?["session-1"]?.count, 1, "v6 升级到 v7 应保留已有 samples")
        XCTAssertEqual(migrated.dailyBySession["session-1"]?.first?.value.turns, 1)
    }

    func testMergeDaily() {
        let day1 = "2026-09-22"
        let day2 = "2026-09-23"
        let date1 = Date(timeIntervalSince1970: 1_700_000_000)
        let date2 = Date(timeIntervalSince1970: 1_700_086_400)

        let existing: [String: AntigravityDailyUsage] = [
            day1: AntigravityDailyUsage(dayStart: date1, inputTokens: 100, outputTokens: 50, turns: 2, rounds: 3)
        ]
        let incremental: [String: AntigravityDailyUsage] = [
            day1: AntigravityDailyUsage(dayStart: date1, inputTokens: 40, outputTokens: 20, turns: 1, rounds: 1),
            day2: AntigravityDailyUsage(dayStart: date2, inputTokens: 200, outputTokens: 80, turns: 1, rounds: 2)
        ]

        let merged = AntigravityLocalUsageScanner.mergeDaily(existing: existing, incremental: incremental)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[day1]?.inputTokens, 140)
        XCTAssertEqual(merged[day1]?.outputTokens, 70)
        XCTAssertEqual(merged[day1]?.turns, 3)
        XCTAssertEqual(merged[day1]?.rounds, 4)
        XCTAssertEqual(merged[day2]?.inputTokens, 200)
        XCTAssertEqual(merged[day2]?.turns, 1)
        XCTAssertEqual(merged[day2]?.rounds, 2)
    }

    func testIncrementalTurnRoundDetailsAndSamples() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        // 第一批事件（从 0 开始）：
        let event1 = makeEvent(
            timestamp: baseDate,
            model: "gemini-2.5-pro",
            input: 10,
            output: 5,
            total: 15,
            stepIndices: [1, 2]
        )
        let details1 = AntigravityLocalUsageScanner.computeTurnRoundDetails(
            sessionID: "test-sess",
            events: [event1],
            calendar: calendar
        )
        XCTAssertEqual(details1.counts.totalTurns, 1)
        XCTAssertEqual(details1.counts.totalRounds, 1)
        XCTAssertEqual(details1.lastMaxStepIndex, 2)
        XCTAssertEqual(details1.lastTurnIndex, 1)
        XCTAssertEqual(details1.samples.first?.promptID, "test-sess:turn-1")

        // 增量事件 A：同一 Turn 的后续 LLM 调用（stepIndex 紧邻，minIdx = 3 <= prevMax(2) + 1）
        let event2 = makeEvent(
            timestamp: baseDate.addingTimeInterval(10),
            model: "gemini-2.5-pro",
            input: 20,
            output: 10,
            total: 30,
            stepIndices: [3]
        )
        let details2 = AntigravityLocalUsageScanner.computeTurnRoundDetails(
            sessionID: "test-sess",
            events: [event2],
            calendar: calendar,
            initialPrevMaxStepIndex: details1.lastMaxStepIndex,
            initialTurnIndex: details1.lastTurnIndex
        )
        XCTAssertEqual(details2.counts.totalTurns, 0, "同一轮的后续调用不应增加 turns")
        XCTAssertEqual(details2.counts.totalRounds, 1)
        XCTAssertEqual(details2.lastMaxStepIndex, 3)
        XCTAssertEqual(details2.lastTurnIndex, 1)
        XCTAssertEqual(details2.samples.first?.promptID, "test-sess:turn-1")

        // 增量事件 B：新的一轮（stepIndex 存在空隙，minIdx = 6 > prevMax(3) + 1）
        let event3 = makeEvent(
            timestamp: baseDate.addingTimeInterval(20),
            model: "gemini-2.5-pro",
            input: 30,
            output: 15,
            total: 45,
            stepIndices: [6]
        )
        let details3 = AntigravityLocalUsageScanner.computeTurnRoundDetails(
            sessionID: "test-sess",
            events: [event3],
            calendar: calendar,
            initialPrevMaxStepIndex: details2.lastMaxStepIndex,
            initialTurnIndex: details2.lastTurnIndex
        )
        XCTAssertEqual(details3.counts.totalTurns, 1, "跨 step 间隙的新 Prompt 应识别为新 Turn")
        XCTAssertEqual(details3.counts.totalRounds, 1)
        XCTAssertEqual(details3.lastMaxStepIndex, 6)
        XCTAssertEqual(details3.lastTurnIndex, 2)
        XCTAssertEqual(details3.samples.first?.promptID, "test-sess:turn-2")
    }

    func testFileManagerBoxPrivateStoragePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-storage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileManager = FileManagerBox()
        try fileManager.createPrivateDirectory(at: root)
        let directoryPermissions = try fileManager.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)

        let file = root.appendingPathComponent("secret.json")
        try fileManager.writePrivate(Data("secret".utf8), to: file)
        let filePermissions = try fileManager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(filePermissions?.intValue, 0o600)
    }
}
