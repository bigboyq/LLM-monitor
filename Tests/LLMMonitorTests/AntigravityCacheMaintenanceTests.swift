import XCTest
import SQLite3
@testable import LLM_monitor

/// 全量页 offset 回归防护、旧日历重建的待办标记与再激活，以及 8 天窗口外的日桶裁剪、
/// 部分命中告警去重、收敛字段的向后兼容解码。
final class AntigravityCacheMaintenanceTests: AntigravityConvergenceTestCase {

    // MARK: - 测试

    /// cachedOffset=5 的 session，全量页返回 count=3（< offset，server 丢数据/
    /// 截断/连错 workspace）：不得照常全量替换覆盖 last-good——offset 保留 5、
    /// eventCount/daily 不变，计失败并记回归打击（即使页内 events 可解析）；
    /// 连续 3 轮后按成功收敛（采用当前指纹、offset 绝不回退到 3、不计失败）；
    /// 随后 server 恢复（count=7 ≥ offset）→ 正常全量替换、回归计数清空。
    func testFullPageOffsetRegressionKeepsLastGoodAndConvergesAfterThreeStrikes() async throws {
        let fixture = try makeConvergenceFixture(cachedOffset: 5, cachedEventCount: 5)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // 移除 samples 缓存 → 每轮都走 full plan（cachedOffset=5 > 0 且无日历
        // 变更时的唯一 full plan 入口）。
        var seeded = try loadConvergenceIndex(fixture)
        seeded.samplesBySession?[fixture.sessionID] = nil
        try AntigravityLocalUsageScanner.saveIndex(
            seeded, cacheDir: fixture.cache, fileManager: FileManagerBox(fixture.fm)
        )

        // 回归页的 events 完全可解析——即便如此也必须拒绝覆盖 last-good。
        let truncatedEvents = [
            makeEvent(timestamp: fixture.dayStart.addingTimeInterval(3_600), input: 10, total: 10)
        ]
        let stub = MetadataStub { _, _ in
            (events: truncatedEvents, metadataEntryCount: 3)
        }
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        // 第 1、2 轮：回归页计失败、last-good 完整保留（offset 5、旧指纹）。
        let scan1 = try await runConvergenceScan(fixture: fixture, now: base, stub: stub)
        XCTAssertEqual(scan1.failedSessionCount, 1)
        var index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(index.offsetRegressionStrikesBySession?[fixture.sessionID], 1)
        XCTAssertEqual(index.sessions[fixture.sessionID]?.generatorMetadataOffset, 5, "回归页不得回退/覆盖 last-good offset")
        XCTAssertEqual(index.sessions[fixture.sessionID]?.eventCount, 5, "last-good eventCount 保留")
        XCTAssertEqual(index.sessions[fixture.sessionID]?.mtimeMs, fixture.liveMtimeMs - 60_000, "打击期内不得采用当前文件指纹")
        XCTAssertEqual(
            index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 500,
            "last-good daily 保留"
        )
        XCTAssertNil(index.zeroAccountedFullStrikesBySession, "可解析的回归页不进零可计账打击计数")
        XCTAssertNil(index.emptyFullStrikesBySession, "count 非零不进零 metadata 打击计数")

        _ = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(60), stub: stub)
        index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(index.offsetRegressionStrikesBySession?[fixture.sessionID], 2)

        // 第 3 轮：收敛——不计失败、指纹采用、offset 仍 5（绝不回退到 3）。
        let scan3 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(120), stub: stub)
        XCTAssertEqual(scan3.failedSessionCount, 0, "收敛不计失败")
        index = try loadConvergenceIndex(fixture)
        XCTAssertNil(index.offsetRegressionStrikesBySession, "收敛后回归计数清空")
        let converged = try XCTUnwrap(index.sessions[fixture.sessionID])
        XCTAssertEqual(converged.mtimeMs, fixture.liveMtimeMs, "收敛采用当前文件指纹")
        XCTAssertEqual(converged.generatorMetadataOffset, 5, "offset 保留 5，绝不回退")
        XCTAssertEqual(converged.eventCount, 5)
        XCTAssertEqual(index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 500)
        XCTAssertEqual(
            index.calendarSignature, LocalUsageCalendarSignature.make(testCalendar),
            "收敛后签名照常推进"
        )

        // 第 4 轮：server 恢复（count=7 ≥ offset）。缩小文件触发 shrink →
        // full plan（offset=0），7 >= 5 无回归 → 正常全量替换、计数清空。
        try Data(repeating: 3, count: 64).write(to: fixture.dbPath)
        let recoveredEvents = (0..<7).map {
            makeEvent(
                timestamp: fixture.dayStart.addingTimeInterval(3_600 + Double($0 * 60)),
                input: 1,
                total: 1
            )
        }
        await stub.setHandler { _, _ in
            (events: recoveredEvents, metadataEntryCount: 7)
        }
        let scan4 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(180), stub: stub)
        XCTAssertEqual(scan4.failedSessionCount, 0)
        index = try loadConvergenceIndex(fixture)
        let recovered = try XCTUnwrap(index.sessions[fixture.sessionID])
        XCTAssertEqual(recovered.generatorMetadataOffset, 7, "server 恢复后正常全量替换按 raw 总数重置 offset")
        XCTAssertEqual(recovered.eventCount, 7)
        XCTAssertEqual(
            index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 7,
            "server 恢复后全量重算整体替换日桶"
        )
        XCTAssertEqual(index.samplesBySession?[fixture.sessionID]?.count, 7)
        XCTAssertNil(index.offsetRegressionStrikesBySession, "无回归页清空回归计数")
        XCTAssertNil(index.emptyFullStrikesBySession)
        XCTAssertNil(index.zeroAccountedFullStrikesBySession)
    }

    /// 修复 2：时区/日历变更冷重建中连续 3 轮零 metadata 收敛的 session——
    /// 打旧日历待重建标记、签名照常推进、旧日历 daily 保留、文件不变不发
    /// RPC；随后文件重新活跃（指纹变化）时排一次 offset=0 full，按当前
    /// 日历重建日桶并清除标记（而非增量合并造成新旧日历混桶）。
    func testCalendarRebuildConvergenceMarksPendingAndRebuildsOnReactivation() async throws {
        let oldSignature = "gregorian|Asia/Shanghai"
        let fixture = try makeConvergenceFixture(
            cachedOffset: 5,
            cachedEventCount: 5,
            seededCalendarSignature: oldSignature
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let stub = MetadataStub { _, _ in
            (events: [], metadataEntryCount: 0)
        }
        let base = Date(timeIntervalSince1970: 1_790_000_000)

        // 第 1、2 轮：冷重建全量返回零 metadata → 打击计数递增、计失败、
        // 签名停在旧值、last-good 保留、未收敛不打标记。
        let scan1 = try await runConvergenceScan(fixture: fixture, now: base, stub: stub)
        XCTAssertEqual(scan1.failedSessionCount, 1)
        var index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(index.calendarSignature, oldSignature, "未收敛前签名不得推进")
        XCTAssertEqual(index.emptyFullStrikesBySession?[fixture.sessionID], 1)
        XCTAssertNil(index.calendarRebuildPendingSessions)

        _ = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(60), stub: stub)
        index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(index.calendarSignature, oldSignature)
        XCTAssertEqual(index.emptyFullStrikesBySession?[fixture.sessionID], 2)

        // 第 3 轮：收敛——签名照常推进、旧日历 daily 保留、打待重建标记。
        let scan3 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(120), stub: stub)
        XCTAssertEqual(scan3.failedSessionCount, 0, "收敛不计失败")
        index = try loadConvergenceIndex(fixture)
        XCTAssertEqual(
            index.calendarSignature, LocalUsageCalendarSignature.make(testCalendar),
            "收敛后签名照常推进（不 hammering 设计）"
        )
        XCTAssertNil(index.emptyFullStrikesBySession)
        XCTAssertEqual(
            index.calendarRebuildPendingSessions, [fixture.sessionID],
            "旧日历 session 必须打待重建标记"
        )
        let converged = try XCTUnwrap(index.sessions[fixture.sessionID])
        XCTAssertEqual(converged.mtimeMs, fixture.liveMtimeMs, "收敛采用当前文件指纹")
        XCTAssertEqual(converged.generatorMetadataOffset, 5, "收敛保留 last-good offset")
        XCTAssertEqual(converged.eventCount, 5)
        XCTAssertEqual(
            index.dailyBySession[fixture.sessionID]?[fixture.dayKey]?.inputTokens, 500,
            "旧日历 daily 保留"
        )

        // 第 4 轮：文件不变 → 不发 RPC（标记不引发额外扫描，保持"不 hammering"）。
        let callsAfterConverge = stub.callCount
        let scan4 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(180), stub: stub)
        XCTAssertEqual(stub.callCount, callsAfterConverge)
        XCTAssertEqual(scan4.failedSessionCount, 0)

        // 第 5 轮：文件重新活跃且 metadata 恢复 → 带标记 session 排 offset=0
        // full（而非增量合并），按当前日历重建日桶并清除标记。
        try Data(repeating: 2, count: 256).write(to: fixture.dbPath)
        let nextDayEventDate = fixture.dayStart.addingTimeInterval(86_400 + 3_600)
        let nextDayKey = LocalUsageDayKey.make(
            testCalendar.startOfDay(for: nextDayEventDate),
            calendar: testCalendar
        )
        let recoveredEvents = [makeEvent(timestamp: nextDayEventDate, input: 700, total: 700)]
        await stub.setHandler { _, _ in
            (events: recoveredEvents, metadataEntryCount: 9)
        }
        let scan5 = try await runConvergenceScan(fixture: fixture, now: base.addingTimeInterval(240), stub: stub)
        XCTAssertEqual(scan5.failedSessionCount, 0)
        XCTAssertEqual(stub.lastOffset, 0, "带标记 session 重新活跃必须排 offset=0 full")
        index = try loadConvergenceIndex(fixture)
        let rebuilt = try XCTUnwrap(index.sessions[fixture.sessionID])
        XCTAssertEqual(rebuilt.generatorMetadataOffset, 9, "full 重算按 raw 总数重置 offset")
        XCTAssertEqual(rebuilt.eventCount, 1, "full 重算整体替换（而非 5+1 增量合并）")
        XCTAssertNil(index.dailyBySession[fixture.sessionID]?[fixture.dayKey], "旧日历日桶被重建替换")
        XCTAssertEqual(
            index.dailyBySession[fixture.sessionID]?[nextDayKey]?.inputTokens, 700,
            "新日历日桶按当前日历重建"
        )
        XCTAssertNil(index.calendarRebuildPendingSessions, "full 成功后标记清除")
    }

    /// 卫生清理：写回 index 前裁剪严格早于 8 天窗口的日桶（与 samples 的
    /// `-LocalUsageRetentionWindow.seconds` 谓词同式）。构造含 10 天前桶的缓存且 session 指纹
    /// 新鲜（不触发 RPC、日桶不会被重算替换），扫描后旧桶被裁、7 天内的桶与
    /// samples 不受影响、eventCount 不变。
    func testPrunesDailyBucketsOlderThanEightDayWindowOnSave() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("antigravity-prune-\(UUID().uuidString)", isDirectory: true)
        let conversations = root.appendingPathComponent("conversations", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: conversations, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let sessionID = "prune-session"
        let dbPath = conversations.appendingPathComponent("\(sessionID).db")
        try Data(repeating: 3, count: 128).write(to: dbPath)
        let values = try dbPath.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let liveMtimeMs = try XCTUnwrap(values.contentModificationDate).timeIntervalSince1970 * 1000
        let liveSizeBytes = try XCTUnwrap(values.fileSize)

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let oldDayStart = try XCTUnwrap(
            testCalendar.date(byAdding: .day, value: -10, to: now).map { testCalendar.startOfDay(for: $0) }
        )
        let recentDayStart = try XCTUnwrap(
            testCalendar.date(byAdding: .day, value: -2, to: now).map { testCalendar.startOfDay(for: $0) }
        )
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
            version: 7,
            lastScannedAt: now.addingTimeInterval(-60),
            sessions: [sessionID: .init(
                mtimeMs: liveMtimeMs,          // 新鲜指纹 → 不 dirty、不发 RPC
                sizeBytes: liveSizeBytes,
                walMtimeMs: 0,
                walSizeBytes: 0,
                fetchedAt: now.addingTimeInterval(-60),
                eventCount: 4,
                generatorMetadataOffset: 5
            )],
            dailyBySession: [sessionID: [
                oldDayKey: AntigravityDailyUsage(dayStart: oldDayStart, inputTokens: 100, totalTokens: 100),
                recentDayKey: AntigravityDailyUsage(dayStart: recentDayStart, inputTokens: 200, totalTokens: 200)
            ]],
            samplesBySession: [sessionID: [seededSample]],
            calendarSignature: LocalUsageCalendarSignature.make(testCalendar)
        )
        try AntigravityLocalUsageScanner.saveIndex(index, cacheDir: cache, fileManager: FileManagerBox(fm))

        let result = try await AntigravityLocalUsageScanner.performScanPureImpl(
            fetcher: AntigravityFetcher(metadataServerDiscovery: { [] }),
            conversationsDirs: [conversations],
            cacheDir: cache,
            fileManager: FileManagerBox(fm),
            calendar: testCalendar,
            now: { now },
            shouldSave: true,
            metadataFetch: { _, _ in (events: [], metadataEntryCount: 0) }
        )

        let saved = try AntigravityLocalUsageScanner.loadIndex(cacheDir: cache, fileManager: FileManagerBox(fm))
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

    /// 部分命中分量告警去重：`parseUsageEvent` 不再逐事件 logWarn，scanner 聚合
    /// 点按 session 记录本页观测到的未命中分量集合（`partialHitWarnedBySession`），
    /// 集合不变不重复告警、集合变化才再记；total 口径（server 权威值）不受影响。
    func testPartialHitWarningDedupStateRecordedPerSessionAndUpdatedOnSetChange() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("antigravity-partial-hit-\(UUID().uuidString)", isDirectory: true)
        let conversations = root.appendingPathComponent("conversations", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: conversations, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let sessionID = "partial-hit-session"
        let dbPath = conversations.appendingPathComponent("\(sessionID).db")
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        // 只有 cacheRead 命中：total 采用 server 权威值，未命中分量随事件带回调用方
        let cacheReadOnly = [makeEvent(
            timestamp: now,
            cacheRead: 300,
            total: 99_999,
            missingComponents: ["input", "output", "reasoning"]
        )]
        // server 修复 input/output 后仅剩 reasoning 未命中：观测集合变化
        let reasoningOnlyMissing = [makeEvent(
            timestamp: now,
            input: 40,
            total: 500,
            missingComponents: ["reasoning"]
        )]

        func runScan(bytes: Int, events: [AntigravityFetcher.UsageEvent]) async throws {
            // 变更指纹（size 参与比较）→ session 重新 dirty → 聚合点重新执行
            try Data(repeating: 7, count: bytes).write(to: dbPath)
            _ = try await AntigravityLocalUsageScanner.performScanPureImpl(
                fetcher: AntigravityFetcher(metadataServerDiscovery: {
                    // 非空 server 列表让 fetchAll 通过前置检查；RPC 由
                    // metadataFetch 替身接管，不出网。
                    [AntigravityFetcher.ServerInfo(pid: 1, httpsPort: 1, csrfToken: nil, kind: .ide)]
                }),
                conversationsDirs: [conversations],
                cacheDir: cache,
                fileManager: FileManagerBox(fm),
                calendar: testCalendar,
                now: { now },
                shouldSave: true,
                metadataFetch: { _, _ in (events: events, metadataEntryCount: 1) }
            )
        }

        try await runScan(bytes: 128, events: cacheReadOnly)
        var saved = try AntigravityLocalUsageScanner.loadIndex(cacheDir: cache, fileManager: FileManagerBox(fm))
        XCTAssertEqual(
            saved.partialHitWarnedBySession,
            [sessionID: ["input", "output", "reasoning"]],
            "首次部分命中：记录该 session 观测到的未命中分量集合"
        )
        let dayKey = LocalUsageDayKey.make(testCalendar.startOfDay(for: now), calendar: testCalendar)
        XCTAssertEqual(
            saved.dailyBySession[sessionID]?[dayKey]?.totalTokens, 99_999,
            "去重不改口径：total 仍采用 server 权威值"
        )

        // 集合不变（重新扫描同一形态的部分命中事件）：去重状态保持，不再重复告警
        try await runScan(bytes: 256, events: cacheReadOnly)
        saved = try AntigravityLocalUsageScanner.loadIndex(cacheDir: cache, fileManager: FileManagerBox(fm))
        XCTAssertEqual(
            saved.partialHitWarnedBySession,
            [sessionID: ["input", "output", "reasoning"]],
            "未命中分量集合不变时去重状态保持，不再重复告警"
        )

        // 集合变化：更新状态并再记一次
        try await runScan(bytes: 384, events: reasoningOnlyMissing)
        saved = try AntigravityLocalUsageScanner.loadIndex(cacheDir: cache, fileManager: FileManagerBox(fm))
        XCTAssertEqual(
            saved.partialHitWarnedBySession,
            [sessionID: ["reasoning"]],
            "未命中分量集合变化时更新状态并再记一次"
        )
    }

    /// 缓存向后兼容（验收约束 5）：旧 v7 index（无收敛字段）可被新代码读取，
    /// 新字段 decodeIfPresent 提供默认值；新字段写入后 encode/decode 保真。
    func testConvergenceFieldsDecodeWithBackwardCompatibility() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entryJSON = """
        {"mtimeMs":1.0,"sizeBytes":2,"walMtimeMs":0.0,"walSizeBytes":0,"eventCount":5,"generatorMetadataOffset":5}
        """
        let entry = try decoder.decode(
            AntigravityLocalUsageScanner.SessionIndexEntry.self,
            from: Data(entryJSON.utf8)
        )
        XCTAssertEqual(entry.consecutiveEmptySuffixes, 0, "旧缓存无空 suffix 计数字段时默认 0")
        XCTAssertNil(entry.lastEmptySuffixAt)

        let indexJSON = """
        {"version":7,"lastScannedAt":"2026-09-22T00:00:00Z","sessions":{},"dailyBySession":{}}
        """
        let index = try decoder.decode(
            AntigravityLocalUsageScanner.CacheIndex.self,
            from: Data(indexJSON.utf8)
        )
        XCTAssertNil(index.emptyFullStrikesBySession, "旧缓存无打击计数字段时默认 nil")
        XCTAssertNil(index.calendarRebuildPendingSessions, "旧缓存无旧日历标记字段时默认 nil")
        XCTAssertNil(index.zeroAccountedFullStrikesBySession, "旧缓存无零可计账打击计数字段时默认 nil")
        XCTAssertNil(index.partialHitWarnedBySession, "旧缓存无部分命中告警去重字段时默认 nil")

        var withStrikes = index
        withStrikes.emptyFullStrikesBySession = ["s1": 2]
        withStrikes.calendarRebuildPendingSessions = ["s1"]
        withStrikes.zeroAccountedFullStrikesBySession = ["s1": 1]
        withStrikes.partialHitWarnedBySession = ["s1": ["reasoning"]]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let redecoded = try decoder.decode(
            AntigravityLocalUsageScanner.CacheIndex.self,
            from: try encoder.encode(withStrikes)
        )
        XCTAssertEqual(redecoded.emptyFullStrikesBySession?["s1"], 2, "新字段 round-trip 保真")
        XCTAssertEqual(
            redecoded.calendarRebuildPendingSessions, ["s1"],
            "旧日历标记字段 round-trip 保真"
        )
        XCTAssertEqual(
            redecoded.zeroAccountedFullStrikesBySession?["s1"], 1,
            "零可计账打击计数字段 round-trip 保真"
        )
        XCTAssertEqual(
            redecoded.partialHitWarnedBySession?["s1"], ["reasoning"],
            "部分命中告警去重字段 round-trip 保真"
        )
        let withCounter = try decoder.decode(
            AntigravityLocalUsageScanner.SessionIndexEntry.self,
            from: try encoder.encode(entry)
        )
        XCTAssertEqual(withCounter.consecutiveEmptySuffixes, 0)
    }
}
