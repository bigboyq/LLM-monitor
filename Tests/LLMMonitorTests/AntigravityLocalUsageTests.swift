import XCTest
import SQLite3
@testable import LLM_monitor

final class AntigravityLocalUsageTests: XCTestCase {

    // MARK: - AntigravityLocalUsage 数据模型

    func testAntigravityDailyUsageCacheHitRate() {
        // cacheRead=80, input=20 → 80% hit rate
        let day = AntigravityDailyUsage(
            dayStart: Date(timeIntervalSince1970: 1_700_000_000),
            inputTokens: 20,
            cacheReadTokens: 80
        )
        XCTAssertEqual(day.cacheHitRate ?? 0, 0.8, accuracy: 0.000_001)
    }

    func testAntigravityDailyUsageCacheHitRateNilWhenNoInput() {
        let day = AntigravityDailyUsage(dayStart: Date())
        XCTAssertNil(day.cacheHitRate)
    }

    func testAntigravityDailyUsageReasonRate() {
        // reasoning=30, output=70 → 30%
        let day = AntigravityDailyUsage(
            dayStart: Date(),
            outputTokens: 70,
            reasoningTokens: 30
        )
        XCTAssertEqual(day.reasonRate ?? 0, 0.3, accuracy: 0.000_001)
    }

    func testAntigravityDailyUsagePlus() {
        let a = AntigravityDailyUsage(
            dayStart: Date(timeIntervalSince1970: 1_000_000),
            inputTokens: 100, outputTokens: 50, totalTokens: 150
        )
        let b = AntigravityDailyUsage(
            dayStart: Date(timeIntervalSince1970: 1_000_000),
            inputTokens: 200, outputTokens: 80, reasoningTokens: 10, totalTokens: 290
        )
        let sum = a + b
        XCTAssertEqual(sum.inputTokens, 300)
        XCTAssertEqual(sum.outputTokens, 130)
        XCTAssertEqual(sum.reasoningTokens, 10)
        XCTAssertEqual(sum.totalTokens, 440)
    }

    /// `AntigravityLocalUsage` 自定义 `==` 排除 `scannedAt`：
    /// 业务字段全等 + scannedAt 不同时 == 应当返回 true（让 AppState no-op 检查生效）。
    /// 修前：自动合成 Equatable 因 scannedAt 永远 != 而 false，no-op 形同虚设。
    func testAntigravityLocalUsageEqualityIgnoresScannedAt() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let today = AntigravityDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, totalTokens: 150)
        let days = [AntigravityDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, totalTokens: 150)]
        let lhs = AntigravityLocalUsage(
            today: today,
            dailyTokenUsage: days,
            scannedAt: Date(timeIntervalSince1970: 1_000_000),
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        let rhs = AntigravityLocalUsage(
            today: today,
            dailyTokenUsage: days,
            scannedAt: Date(timeIntervalSince1970: 9_999_999),  // 不同的 scannedAt
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        XCTAssertEqual(lhs, rhs, "业务字段相同 + scannedAt 不同 → == 应当 true (no-op 生效)")
    }

    /// 业务字段不同时 == 必须 false（不能让 no-op 误判命中）。
    func testAntigravityLocalUsageEqualityDetectsBusinessFieldChanges() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let base = AntigravityLocalUsage(
            today: AntigravityDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, totalTokens: 150),
            dailyTokenUsage: [AntigravityDailyUsage(dayStart: day, inputTokens: 100, outputTokens: 50, totalTokens: 150)],
            scannedAt: Date(timeIntervalSince1970: 1_000_000),
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        // sessionCount 变 → !=
        let sessionCountChanged = AntigravityLocalUsage(
            today: base.today,
            dailyTokenUsage: base.dailyTokenUsage,
            scannedAt: base.scannedAt,
            sessionCount: 6,
            eventCount: 50,
            failedSessionCount: 0
        )
        XCTAssertNotEqual(base, sessionCountChanged)
        // eventCount 变 → !=
        let eventCountChanged = AntigravityLocalUsage(
            today: base.today,
            dailyTokenUsage: base.dailyTokenUsage,
            scannedAt: base.scannedAt,
            sessionCount: 5,
            eventCount: 51,
            failedSessionCount: 0
        )
        XCTAssertNotEqual(base, eventCountChanged)
        // dailyTokenUsage 内容变 → !=
        let dayChanged = AntigravityDailyUsage(dayStart: day, inputTokens: 999, outputTokens: 50, totalTokens: 1049)
        let dailyChanged = AntigravityLocalUsage(
            today: base.today,
            dailyTokenUsage: [dayChanged],
            scannedAt: base.scannedAt,
            sessionCount: 5,
            eventCount: 50,
            failedSessionCount: 0
        )
        XCTAssertNotEqual(base, dailyChanged)
    }

    // MARK: - AntigravityLocalUsageScanner: 纯函数

    private func makeEvent(
        timestamp: Date?,
        model: String? = nil,
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int = 0,
        total: Int = 0
    ) -> AntigravityFetcher.UsageEvent {
        AntigravityFetcher.UsageEvent(
            timestamp: timestamp,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            reasoningTokens: reasoning,
            totalTokens: total
        )
    }

    private var testCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testAggregateDailyGroupsByLocalDay() {
        // 三个事件：两个在"今天"，一个在"昨天"
        let now = Date()
        let today = testCalendar.startOfDay(for: now)
        let yesterday = testCalendar.date(byAdding: .day, value: -1, to: today)!

        let events = [
            makeEvent(timestamp: now, input: 10, output: 5, total: 15),
            makeEvent(timestamp: today.addingTimeInterval(3600), input: 20, output: 8, total: 28),
            makeEvent(timestamp: yesterday, input: 30, output: 12, total: 42),
        ]
        let byDay = AntigravityLocalUsageScanner.aggregateDaily(events: events, calendar: testCalendar)

        XCTAssertEqual(byDay.count, 2)
        let todayKey = LocalUsageDayKey.make(today)
        let yesterdayKey = LocalUsageDayKey.make(yesterday)

        XCTAssertEqual(byDay[todayKey]?.inputTokens, 30)   // 10 + 20
        XCTAssertEqual(byDay[todayKey]?.outputTokens, 13)  // 5 + 8
        XCTAssertEqual(byDay[yesterdayKey]?.inputTokens, 30)
    }

    func testAggregateDailySkipsEventsWithoutTimestamp() {
        let now = Date()
        let events = [
            makeEvent(timestamp: nil, input: 100, total: 100),  // 无 timestamp 跳过
            makeEvent(timestamp: now, input: 5, total: 5),
        ]
        let byDay = AntigravityLocalUsageScanner.aggregateDaily(events: events, calendar: testCalendar)
        XCTAssertEqual(byDay.count, 1)
        let todayKey = LocalUsageDayKey.make(testCalendar.startOfDay(for: now))
        XCTAssertEqual(byDay[todayKey]?.inputTokens, 5)
    }



    func testComputeGlobalDailySumsAcrossSessions() {
        let now = Date()
        let today = testCalendar.startOfDay(for: now)
        let todayKey = LocalUsageDayKey.make(today)

        let bySession: [String: [String: AntigravityDailyUsage]] = [
            "s1": [todayKey: AntigravityDailyUsage(dayStart: today, inputTokens: 100, totalTokens: 100)],
            "s2": [todayKey: AntigravityDailyUsage(dayStart: today, inputTokens: 200, outputTokens: 50, totalTokens: 250)],
        ]
        let global = AntigravityLocalUsageScanner.computeGlobalDaily(from: bySession, calendar: testCalendar)
        XCTAssertEqual(global.count, 1)
        XCTAssertEqual(global[0].inputTokens, 300)
        XCTAssertEqual(global[0].outputTokens, 50)
        XCTAssertEqual(global[0].totalTokens, 350)
    }

    func testFilterLast7DaysIncludesToday() {
        let now = Date()
        let today = testCalendar.startOfDay(for: now)
        let days = (0..<10).map { offset in
            AntigravityDailyUsage(
                dayStart: testCalendar.date(byAdding: .day, value: -offset, to: today)!,
                totalTokens: offset
            )
        }
        let recent = AntigravityLocalUsageScanner.filterLast7Days(allDaily: days, today: today)
        XCTAssertEqual(recent.count, 7)
        // 应该按日升序；6 天前 total=6，今天 total=0
        XCTAssertEqual(recent.first?.totalTokens, 6)
        XCTAssertEqual(recent.last?.totalTokens, 0)
    }

    func testFilterLast7DaysEmptyWhenNoData() {
        let now = Date()
        let today = testCalendar.startOfDay(for: now)
        let recent = AntigravityLocalUsageScanner.filterLast7Days(allDaily: [], today: today)
        XCTAssertTrue(recent.isEmpty)
    }

    func testIsoDayKeyFormat() {
        let date = testCalendar.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 7, day: 15))!
        let key = LocalUsageDayKey.make(date)
        XCTAssertEqual(key, "2026-07-15")
    }

    // MARK: - SessionStoreFormat (扩展名 → 格式)

    func testSessionStoreFormatFromFileExtension() {
        XCTAssertEqual(SessionStoreFormat(fileExtension: "db"), .sqlite)
        XCTAssertEqual(SessionStoreFormat(fileExtension: "DB"), .sqlite)
        XCTAssertEqual(SessionStoreFormat(fileExtension: "pb"), .protobuf)
        XCTAssertEqual(SessionStoreFormat(fileExtension: "PB"), .protobuf)
        XCTAssertNil(SessionStoreFormat(fileExtension: "txt"))
        XCTAssertNil(SessionStoreFormat(fileExtension: "db-wal"))  // SQLite 周边文件，不当作 session
        XCTAssertNil(SessionStoreFormat(fileExtension: "db-shm"))
        XCTAssertNil(SessionStoreFormat(fileExtension: ""))
    }

    // MARK: - AntigravityLocalUsageScanner: defaultConversationsDirs 候选路径

    func testDefaultConversationsDirsContainsBothIDEInstalls() {
        let dirs = AntigravityLocalUsageScanner.defaultConversationsDirs
        XCTAssertEqual(dirs.count, 2)
        // 新版 Antigravity IDE.app 优先
        XCTAssertTrue(dirs[0].path.contains(".gemini/antigravity-ide/conversations"),
                      "新版 IDE 目录必须排第一: \(dirs[0].path)")
        // 旧版 Antigravity.app 兜底
        XCTAssertTrue(dirs[1].path.contains(".gemini/antigravity/conversations"),
                      "旧版 IDE 目录必须兜底: \(dirs[1].path)")
    }

    // MARK: - AntigravityLocalUsageScanner: listDBFiles 多目录 + 多格式

    /// listDBFiles 发现 3 in 1：扩展名 (.db / .pb) / 周边文件过滤 / 多目录 dedup / 真实 IDE 路径
    func testListDBFilesDiscoveryAndDedup() throws {
        let fm = FileManager.default
        // 1. 扩展名 + 周边文件过滤
        do {
            let tmp = fm.temporaryDirectory.appendingPathComponent("llm-monitor-ext-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            try Data().write(to: tmp.appendingPathComponent("sess-1.db"))
            try Data().write(to: tmp.appendingPathComponent("sess-2.pb"))
            // 不应被接受：周边文件
            try Data().write(to: tmp.appendingPathComponent("sess-1.db-wal"))
            try Data().write(to: tmp.appendingPathComponent("sess-1.db-shm"))
            try Data().write(to: tmp.appendingPathComponent("notes.txt"))

            let result = AntigravityLocalUsageScanner.listDBFilesWithStatus(
                conversationsDirs: [tmp],
                fileManager: FileManagerBox(fm)
            ).files
            XCTAssertEqual(result.count, 2, "应接受 .db 和 .pb 两个 session")
            XCTAssertEqual(result["sess-1"]?.format, .sqlite)
            XCTAssertEqual(result["sess-2"]?.format, .protobuf)
            XCTAssertNil(result["sess-1.db-wal"], "周边文件应被过滤")
            XCTAssertNil(result["sess-1.db-shm"])
            XCTAssertNil(result["notes"])
        }
        // 2. 多目录 dedup（同一 sessionId 在两个目录都出现, 第一个赢）
        do {
            let tmp1 = fm.temporaryDirectory.appendingPathComponent("llm-monitor-new-\(UUID().uuidString)", isDirectory: true)
            let tmp2 = fm.temporaryDirectory.appendingPathComponent("llm-monitor-old-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmp1, withIntermediateDirectories: true)
            try fm.createDirectory(at: tmp2, withIntermediateDirectories: true)
            defer {
                try? fm.removeItem(at: tmp1)
                try? fm.removeItem(at: tmp2)
            }

            try Data(repeating: 1, count: 100).write(to: tmp1.appendingPathComponent("shared.pb"))
            try Data(repeating: 2, count: 200).write(to: tmp2.appendingPathComponent("shared.pb"))
            try Data().write(to: tmp1.appendingPathComponent("only-new.db"))
            try Data().write(to: tmp2.appendingPathComponent("only-old.db"))

            let result = AntigravityLocalUsageScanner.listDBFilesWithStatus(
                conversationsDirs: [tmp1, tmp2],
                fileManager: FileManagerBox(fm)
            ).files
            XCTAssertEqual(result.count, 3)
            XCTAssertEqual(result["shared"]?.url.standardizedFileURL,
                           tmp1.appendingPathComponent("shared.pb").standardizedFileURL,
                           "同 sessionId 优先用第一个目录（新版 IDE）")
            XCTAssertEqual(result["only-new"]?.format, .sqlite)
            XCTAssertEqual(result["only-old"]?.format, .sqlite)
        }
        // 3. 真实 IDE 路径（antigravity-ide + antigravity 双目录）
        do {
            let tmp = fm.temporaryDirectory.appendingPathComponent("llm-monitor-real-\(UUID().uuidString)", isDirectory: true)
            let ideDir = tmp.appendingPathComponent("antigravity-ide/conversations", isDirectory: true)
            let oldDir = tmp.appendingPathComponent("antigravity/conversations", isDirectory: true)
            try fm.createDirectory(at: ideDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            try Data().write(to: ideDir.appendingPathComponent("ide-session-1.db"))
            try Data().write(to: ideDir.appendingPathComponent("ide-session-2.db"))
            try Data().write(to: ideDir.appendingPathComponent("ide-session-3.pb"))
            try Data().write(to: oldDir.appendingPathComponent("old-session-1.pb"))
            try Data().write(to: oldDir.appendingPathComponent("old-session-2.pb"))
            try Data().write(to: oldDir.appendingPathComponent("old-session-3.pb"))

            let result = AntigravityLocalUsageScanner.listDBFilesWithStatus(
                conversationsDirs: [ideDir, oldDir],
                fileManager: FileManagerBox(fm)
            ).files
            XCTAssertEqual(result.count, 6, "两个目录的 session 都要被收录")
            XCTAssertEqual(result["ide-session-1"]?.format, .sqlite)
            XCTAssertEqual(result["old-session-1"]?.format, .protobuf)
        }
    }

    /// 错误处理 3 in 1：missing 目录跳过 / missing vs unreadable 区分 / attribute 失败保留 cache
    func testListDBFilesMissingUnreadablePreservation() throws {
        let fm = FileManager.default
        // 1. 整个 conversationsDir 不存在 → 静默跳过, 现有目录仍正常扫描
        do {
            let existing = fm.temporaryDirectory.appendingPathComponent("llm-monitor-exist-\(UUID().uuidString)", isDirectory: true)
            let missing = fm.temporaryDirectory.appendingPathComponent("llm-monitor-miss-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: existing, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: existing) }
            try Data().write(to: existing.appendingPathComponent("s1.db"))

            let result = AntigravityLocalUsageScanner.listDBFilesWithStatus(
                conversationsDirs: [missing, existing],
                fileManager: FileManagerBox(fm)
            ).files
            XCTAssertEqual(result.count, 1, "missing 目录静默跳过, existing 仍被收录")
            XCTAssertEqual(result["s1"]?.format, .sqlite)
        }
        // 2. missing vs unreadable 区分：missing → 视为空(可删), unreadable → 不可删 last-good cache
        do {
            let existing = fm.temporaryDirectory
                .appendingPathComponent("llm-monitor-listing-\(UUID().uuidString)", isDirectory: true)
            let missing = existing.appendingPathComponent("missing", isDirectory: true)
            let unreadable = existing.appendingPathComponent("unreadable", isDirectory: true)
            try fm.createDirectory(at: existing, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: existing) }
            try Data().write(to: existing.appendingPathComponent("visible.db"))

            let listing = AntigravityLocalUsageScanner.listDBFilesWithStatus(
                conversationsDirs: [missing, existing, unreadable],
                fileManager: FileManagerBox(fm),
                directoryContents: { url in
                    if url == missing { throw CocoaError(.fileReadNoSuchFile) }
                    if url == unreadable { throw CocoaError(.fileReadNoPermission) }
                    return try fm.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                    )
                }
            )
            XCTAssertEqual(listing.files.count, 1)
            XCTAssertFalse(listing.isComplete, "unreadable 必须标记枚举不完整")
            XCTAssertTrue(
                AntigravityLocalUsageScanner.confirmedRemovedSessionIDs(
                    cachedIds: ["visible", "cached-in-unreadable-root"],
                    listing: listing
                ).isEmpty,
                "任一 root 不可读时不得删除 last-good session"
            )
        }
        // 3. WAL / 文件属性暂时不可读时保留 last-good cache
        do {
            let root = fm.temporaryDirectory
                .appendingPathComponent("llm-monitor-attr-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }
            try Data([0]).write(to: root.appendingPathComponent("unreadable.db"))

            let listing = AntigravityLocalUsageScanner.listDBFilesWithStatus(
                conversationsDirs: [root],
                fileManager: FileManagerBox(fm),
                fileAttributes: { _ in throw CocoaError(.fileReadNoPermission) }
            )
            XCTAssertFalse(listing.isComplete)
            XCTAssertNil(listing.files["unreadable"])
            XCTAssertTrue(
                AntigravityLocalUsageScanner.confirmedRemovedSessionIDs(
                    cachedIds: ["unreadable"], listing: listing
                ).isEmpty,
                "WAL/文件属性暂时不可读时不得删除 last-good cache"
            )
        }
    }

    /// confirmedRemovedSessionIDs 纯函数：listing.isComplete=true 时, 不在 listing 的 cached 视为已删
    func testListDBFilesConfirmedRemovedSessionIDs() {
        let current = AntigravityDBFileInfo(
            url: URL(fileURLWithPath: "/tmp/current.db"),
            sizeBytes: 1, mtimeMs: 1, walSizeBytes: 0, walMtimeMs: 0, format: .sqlite
        )
        let listing = AntigravityDBFileListing(files: ["current": current], isComplete: true)
        XCTAssertEqual(
            AntigravityLocalUsageScanner.confirmedRemovedSessionIDs(
                cachedIds: ["current", "deleted"], listing: listing
            ),
            ["deleted"]
        )
    }

    func testDiscoverServersDoesNotCrash() {
        // 单元测试不读取用户机器上的真实进程表；进程执行器与分类器分别测试。
        let expected = AntigravityFetcher.ServerInfo(
            pid: 123,
            httpsPort: 456,
            csrfToken: "test-token",
            kind: .ide
        )
        let servers = AntigravityFetcher(
            metadataServerDiscovery: { [expected] }
        ).discoverMetadataServers()
        for server in servers {
            XCTAssertGreaterThan(server.pid, 0)
            XCTAssertGreaterThan(server.httpsPort, 0)
        }
    }

    @MainActor
    func testListDBFilesHealsZeroEventCachedSessions() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("llm-monitor-test-healing-\(UUID().uuidString)", isDirectory: true)
        let conversationsDir = tmp.appendingPathComponent("conversations", isDirectory: true)
        let cacheDir = tmp.appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: conversationsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let sessionId = "session-to-heal"
        let dbPath = conversationsDir.appendingPathComponent("\(sessionId).db")

        // 小于旧版 2KB 启发式阈值，eventCount=0 仍必须重试。
        let fakeDBData = Data(repeating: 0, count: 128)
        try fakeDBData.write(to: dbPath)

        // 写入 index.json，把这个 session 缓存为 eventCount: 0，但 mtime/size 和当前一致
        let values = try dbPath.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values.fileSize ?? 0
        let mtime = values.contentModificationDate ?? Date()

        let indexEntry = AntigravityLocalUsageScanner.SessionIndexEntry(
            mtimeMs: mtime.timeIntervalSince1970 * 1000,
            sizeBytes: size,
            fetchedAt: Date(),
            eventCount: 0  // 缓存为 0，触发生命周期自愈
        )
        let index = AntigravityLocalUsageScanner.CacheIndex(
            version: 2,
            lastScannedAt: Date(),
            sessions: [sessionId: indexEntry],
            dailyBySession: [:]
        )
        try AntigravityLocalUsageScanner.saveIndex(index, cacheDir: cacheDir, fileManager: FileManagerBox(fm))

        // 单元测试不探测/请求用户机器上真实运行的 Antigravity 服务。
        let fetcher = AntigravityFetcher(metadataServerDiscovery: { [] })
        let scanner = AntigravityLocalUsageScanner(
            fetcher: fetcher,
            conversationsDirs: [conversationsDir],
            cacheDir: cacheDir,
            fileManager: FileManagerBox(fm)
        )

        // 触发扫描
        let expectation = XCTestExpectation(description: "scan completes")
        var scanResult: AntigravityLocalUsage?
        Task {
            scanResult = try? await AntigravityLocalUsageScanner.performScanPure(
                fetcher: fetcher,
                conversationsDirs: [conversationsDir],
                cacheDir: cacheDir,
                fileManager: FileManagerBox(fm),
                calendar: .current,
                now: { Date() },
                startedGeneration: 1,
                scanner: scanner
            )
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)

        XCTAssertEqual(scanResult?.failedSessionCount, 1, "RPC 失败应计入 failedSessionCount，下一次扫描仍可重试")

        let cachePermissions = try fm.attributesOfItem(atPath: cacheDir.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(cachePermissions?.intValue, 0o700, "Antigravity cache 根目录必须是 owner-only")
        XCTAssertFalse(
            fm.fileExists(atPath: cacheDir.appendingPathComponent("rpc-cache").path),
            "正式 cache 只保留 index.json，不再创建未读取的 per-session JSONL 目录"
        )
    }

    func testEmptyRPCEventsAreNotTrustworthySuccess() {
        XCTAssertFalse(
            AntigravityLocalUsageScanner.isTrustworthyRPCResult([]),
            "空响应不得更新成功指纹，否则文件不变时会永久缓存空用量"
        )
        XCTAssertTrue(
            AntigravityLocalUsageScanner.isTrustworthyRPCResult([
                makeEvent(
                    timestamp: Date(timeIntervalSince1970: 1_721_034_600),
                    input: 1,
                    total: 1
                )
            ])
        )
    }

    func testEventCountCountsOnlyTimestampedEventsLikeDaily() {
        // 语义统一：eventCount = 成功进入日统计（有 timestamp）的 event 数。
        // 无 timestamp 的 event 不进 daily/turns/rounds/samples，也不得计入
        // eventCount，否则“事件数”与 Token 日汇总口径互相矛盾。
        let now = Date()
        let events = [
            makeEvent(timestamp: nil, input: 100, total: 100),
            makeEvent(timestamp: now, input: 5, total: 5),
            makeEvent(timestamp: now.addingTimeInterval(60), input: 7, total: 7),
            makeEvent(timestamp: nil, input: 200, total: 200),
        ]

        let stats = AntigravityLocalUsageScanner.accountedEventStats(events)
        XCTAssertEqual(stats.accounted, 2)
        XCTAssertEqual(stats.droppedTimestampless, 2)

        // 与 aggregateDaily 的一致性：daily 的 token 总量只来自 accounted 事件。
        let byDay = AntigravityLocalUsageScanner.aggregateDaily(events: events, calendar: testCalendar)
        let dailyInput = byDay.values.reduce(0) { $0 + $1.inputTokens }
        XCTAssertEqual(dailyInput, 12)
        XCTAssertEqual(stats.accounted, 2, "eventCount 与 daily 计入的事件数一致")

        // 全部有 timestamp：不丢弃。
        let allStamped = [
            makeEvent(timestamp: now, input: 1, total: 1),
            makeEvent(timestamp: now, input: 2, total: 2),
        ]
        let allStats = AntigravityLocalUsageScanner.accountedEventStats(allStamped)
        XCTAssertEqual(allStats.accounted, 2)
        XCTAssertEqual(allStats.droppedTimestampless, 0)
    }

    func testCacheInitializationRemovesLegacyPerSessionArtifacts() throws {
        let fm = FileManager.default
        let cacheDir = fm.temporaryDirectory
            .appendingPathComponent("antigravity-cache-\(UUID().uuidString)", isDirectory: true)
        let legacySessionDir = cacheDir
            .appendingPathComponent("rpc-cache/v1/legacy-session", isDirectory: true)
        try fm.createDirectory(at: legacySessionDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: cacheDir) }
        try Data("historical token detail".utf8).write(
            to: legacySessionDir.appendingPathComponent("usage.jsonl")
        )

        try AntigravityLocalUsageScanner.ensureCacheDirectoriesExist(
            cacheDir: cacheDir,
            fileManager: FileManagerBox(fm)
        )

        XCTAssertTrue(fm.fileExists(atPath: cacheDir.path))
        XCTAssertFalse(
            fm.fileExists(atPath: cacheDir.appendingPathComponent("rpc-cache").path),
            "升级后应清理生产从不读取的历史 per-session 明细"
        )
    }

    // MARK: - AntigravityLocalUsageScanner: computeTurnRoundCounts Pure RPC

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

    // MARK: - AntigravityLocalUsageScanner: index.json round-trip

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

        XCTAssertEqual(migrated.version, 6)
        XCTAssertEqual(migrated.sessions.count, 1)
        XCTAssertTrue(migrated.samplesBySession?.isEmpty == true,
                      "v5 的逐次调用缓存必须清空，确保现有 session 重新走纯 RPC")
        XCTAssertEqual(migrated.dailyBySession["session-1"]?.first?.value.turns, 1,
                       "旧 daily 数据保留，RPC 失败时可作为 last-good fallback")
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

    // MARK: - AntigravityFetcher: parseUsageEvent

    /// decode + parse 的小工具, 11 个原测试都重复同一行, 抽出来减少 noise
    private func parseUsageEvent(_ json: String) throws -> AntigravityFetcher.UsageEvent? {
        let wrapped = try JSONDecoder().decode(AnyJSON.self, from: Data(json.utf8))
        return AntigravityFetcher.parseUsageEventForTest(wrapped)
    }

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
            dayStart: day, inputTokens: 11, cacheReadTokens: 3,
            cacheWriteTokens: 0, outputTokens: 6, reasoningTokens: 1, totalTokens: 21,
            turns: 1, rounds: 2
        )
        let index = AntigravityLocalUsageScanner.CacheIndex(
            version: 5,
            lastScannedAt: now,
            sessions: ["session-1": AntigravityLocalUsageScanner.SessionIndexEntry(
                mtimeMs: 1, sizeBytes: 2, fetchedAt: now, eventCount: 2
            )],
            dailyBySession: ["session-1": [LocalUsageDayKey.make(day, calendar: calendar): usage]],
            samplesBySession: nil
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

    // MARK: - Pure RPC Turn/Round Aggregation Tests

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

    // MARK: - F1: scanner 成功分支 turns/rounds 不得双倍计数

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

    // MARK: - Antigravity SQLite Remediation Tests

    func testAnyJSONRejectsNonFiniteAndOutOfRangeIntegers() throws {
        let huge = try JSONDecoder().decode(AnyJSON.self, from: Data("1e100".utf8))
        XCTAssertNil(huge.intValue)
        XCTAssertNil(AnyJSON.number(.infinity).intValue)
        XCTAssertNil(AnyJSON.number(.nan).intValue)
        XCTAssertNil(AnyJSON.number(1.5).intValue)
        XCTAssertEqual(AnyJSON.number(42).intValue, 42)
    }

    func testUsageParserDoesNotDoubleCountNestedRepresentationsAndExcludesCacheWrite() throws {
        let data = Data(
            """
            {
              "inputTokens": 100,
              "outputTokens": 50,
              "cacheReadTokens": 20,
              "cacheWriteTokens": 5,
              "reasoningTokens": 10,
              "totalTokens": 185
            }
            """.utf8
        )
        let json = try JSONDecoder().decode(AnyJSON.self, from: data)
        let event = try XCTUnwrap(AntigravityFetcher.parseUsageEventForTest(json))

        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.outputTokens, 50)
        XCTAssertEqual(event.cacheReadTokens, 20)
        XCTAssertEqual(event.cacheWriteTokens, 5)
        XCTAssertEqual(event.reasoningTokens, 10)
        XCTAssertEqual(event.totalTokens, 180, "total 不应重复计数，也不包含 cacheWrite")
    }

    func testMissingQuotaBucketHasInactiveStatus() throws {
        let data = Data(
            """
            {
              "groups": [{
                "displayName": "Gemini",
                "buckets": [{
                  "bucketId": "weekly-model",
                  "window": "weekly",
                  "remainingFraction": 0.75
                }]
              }]
            }
            """.utf8
        )
        let model = try XCTUnwrap(AntigravityFetcher.parseQuotaModelsForTest(data).first)
        XCTAssertEqual(model.intervalStatus, .absent)
        XCTAssertEqual(model.weeklyStatus, .present)
        XCTAssertEqual(model.weeklyRemainingPercent, 75)
    }

    func testExhaustedQuotaBucketRemainsPresent() throws {
        let data = Data(
            """
            {
              "groups": [{
                "displayName": "Gemini",
                "buckets": [{
                  "bucketId": "gemini-5h",
                  "window": "5h",
                  "remainingFraction": 0
                }]
              }]
            }
            """.utf8
        )
        let model = try XCTUnwrap(AntigravityFetcher.parseQuotaModelsForTest(data).first)
        XCTAssertEqual(model.intervalStatus, .present)
        XCTAssertEqual(model.intervalRemainingPercent, 0)
        XCTAssertTrue(model.hasIntervalWindow)
        XCTAssertEqual(model.healthLevel, .critical)
    }

    func testIDEWithoutCSRFIsNotAUsableServerCandidate() {
        let tokenlessIDE = AntigravityFetcher.ProcessMatch(pid: 10, command: "/Applications/Antigravity.app/Contents/Resources/bin/language_server --app_data_dir antigravity", kind: .ide)
        let authenticatedIDE = AntigravityFetcher.ProcessMatch(pid: 11, command: "/Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token test-token", kind: .ide)
        let cli = AntigravityFetcher.ProcessMatch(pid: 12, command: "/usr/local/bin/agy", kind: .cli)
        XCTAssertFalse(AntigravityFetcher.isUsableProcessCandidate(tokenlessIDE))
        XCTAssertTrue(AntigravityFetcher.isUsableProcessCandidate(authenticatedIDE))
        XCTAssertTrue(AntigravityFetcher.isUsableProcessCandidate(cli))
    }

    func testListDBFilesIncludesWALFingerprint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("antigravity-wal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let db = root.appendingPathComponent("session.db")
        let wal = URL(fileURLWithPath: db.path + "-wal")
        try Data(repeating: 1, count: 20).write(to: db)
        try Data(repeating: 2, count: 37).write(to: wal)

        let files = AntigravityLocalUsageScanner.listDBFilesWithStatus(conversationsDirs: [root], fileManager: FileManagerBox()).files
        let info = try XCTUnwrap(files["session"])
        XCTAssertEqual(info.walSizeBytes, 37)
        XCTAssertGreaterThan(info.walMtimeMs, 0)
    }

    func testSevenDayFilterUsesInjectedCalendarTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 29)))
        let usage = AntigravityDailyUsage(dayStart: today, totalTokens: 99)

        let result = AntigravityLocalUsageScanner.filterLast7Days(allDaily: [usage], today: today, calendar: calendar)
        XCTAssertEqual(result.count, 7)
        XCTAssertEqual(result.last?.dayStart, today)
        XCTAssertEqual(result.last?.totalTokens, 99)
    }
}
