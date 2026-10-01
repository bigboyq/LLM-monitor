import XCTest
import SQLite3
@testable import LLM_monitor

/// `listDBFiles` 的发现与去重、不可读文件的 last-good 保留、日历签名不推进，以及
/// 已移除 / 仅记打击的 session ID 追踪。
final class AntigravityListDBFilesTests: AntigravityTestCase {

    // MARK: - 测试

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
                           "同 sessionId 优先用第一个目录")
            XCTAssertEqual(result["only-new"]?.format, .sqlite)
            XCTAssertEqual(result["only-old"]?.format, .sqlite)
        }
        // 3. 多目录扫描（注入两个 conversations root，全部 session 都要被收录；目录名仅为 fixture）
        do {
            let tmp = fm.temporaryDirectory.appendingPathComponent("llm-monitor-real-\(UUID().uuidString)", isDirectory: true)
            let dirA = tmp.appendingPathComponent("root-a/conversations", isDirectory: true)
            let dirB = tmp.appendingPathComponent("root-b/conversations", isDirectory: true)
            try fm.createDirectory(at: dirA, withIntermediateDirectories: true)
            try fm.createDirectory(at: dirB, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            try Data().write(to: dirA.appendingPathComponent("a-session-1.db"))
            try Data().write(to: dirA.appendingPathComponent("a-session-2.db"))
            try Data().write(to: dirA.appendingPathComponent("a-session-3.pb"))
            try Data().write(to: dirB.appendingPathComponent("b-session-1.pb"))
            try Data().write(to: dirB.appendingPathComponent("b-session-2.pb"))
            try Data().write(to: dirB.appendingPathComponent("b-session-3.pb"))

            let result = AntigravityLocalUsageScanner.listDBFilesWithStatus(
                conversationsDirs: [dirA, dirB],
                fileManager: FileManagerBox(fm)
            ).files
            XCTAssertEqual(result.count, 6, "两个目录的 session 都要被收录")
            XCTAssertEqual(result["a-session-1"]?.format, .sqlite)
            XCTAssertEqual(result["b-session-1"]?.format, .protobuf)
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

    func testCalendarMismatchWithUnreadableRootStaysIncompleteAndDoesNotAdvanceSignature() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("antigravity-calendar-unreadable-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let unreadable = root.appendingPathComponent("unreadable", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try fm.createDirectory(at: unreadable, withIntermediateDirectories: true)

        var oldCalendar = Calendar(identifier: .gregorian)
        oldCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var newCalendar = oldCalendar
        newCalendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let oldSignature = LocalUsageCalendarSignature.make(oldCalendar)
        let index = AntigravityLocalUsageScanner.CacheIndex(
            version: 7,
            lastScannedAt: Date(),
            sessions: ["cached-session": .init(
                mtimeMs: 1,
                sizeBytes: 1,
                fetchedAt: Date(),
                eventCount: 10
            )],
            dailyBySession: [:],
            samplesBySession: ["cached-session": []],
            calendarSignature: oldSignature
        )
        try AntigravityLocalUsageScanner.saveIndex(index, cacheDir: cache, fileManager: FileManagerBox(fm))

        let result = try await AntigravityLocalUsageScanner.performScanPureImpl(
            fetcher: AntigravityFetcher(metadataServerDiscovery: { [] }),
            conversationsDirs: [unreadable],
            cacheDir: cache,
            fileManager: FileManagerBox(fm),
            calendar: newCalendar,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            shouldSave: true,
            forceFull: true,
            directoryContents: { _ in throw CocoaError(.fileReadNoPermission) }
        )

        XCTAssertEqual(result.failedSessionCount, 1)
        XCTAssertEqual(
            try AntigravityLocalUsageScanner.loadIndex(cacheDir: cache, fileManager: FileManagerBox(fm)).calendarSignature,
            oldSignature,
            "calendar mismatch plus incomplete enumeration must not advance the new signature"
        )
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

    /// 仅有打击计数、没有 `sessions` 条目的 session 也必须算「被跟踪」。
    ///
    /// 全新 session 首轮就返回 0 条 metadata 时，打击计数先于 `sessions` 条目落盘
    /// （`continue` 发生在建条目之前）。若删除判定只看 `sessions.keys`，这类 id
    /// 永远进不了 removedIds → 打击计数永久残留在 index.json → 同 sessionId 复活
    /// 时从残留值续算，1~2 轮即提前收敛成「空终结条目」，静默丢弃该指纹周期的数据。
    func testTrackedSessionIDsIncludesStrikeOnlySessions() {
        var index = AntigravityLocalUsageScanner.CacheIndex(
            version: 7,
            lastScannedAt: Date(),
            sessions: [:],
            dailyBySession: [:]
        )
        index.emptyFullStrikesBySession = ["strikeOnly": 1]
        index.zeroAccountedFullStrikesBySession = ["zeroOnly": 2]
        index.offsetRegressionStrikesBySession = ["offsetOnly": 1]
        index.partialHitWarnedBySession = ["partialOnly": ["input"]]
        index.calendarRebuildPendingSessions = ["pendingOnly"]

        let expected: Set<String> = [
            "strikeOnly", "zeroOnly", "offsetOnly", "partialOnly", "pendingOnly"
        ]
        XCTAssertEqual(
            AntigravityLocalUsageScanner.trackedSessionIDs(in: index),
            expected,
            "各类 per-session 状态字段的键都必须进入被跟踪集合"
        )

        // listing 完整且不含这些文件（= 已删除）时，它们必须进入删除清理集合，
        // 否则残留计数会跨 sessionId 复活泄漏。
        let listing = AntigravityDBFileListing(files: [:], isComplete: true)
        XCTAssertEqual(
            AntigravityLocalUsageScanner.confirmedRemovedSessionIDs(
                cachedIds: AntigravityLocalUsageScanner.trackedSessionIDs(in: index),
                listing: listing
            ),
            expected,
            "仅有打击计数的 session 消失后必须被判为已删除从而被清理"
        )
    }

    /// fetcher 是按需构造的轻量 struct；带 delegate 的 URLSession 会被系统强持有
    /// 到进程退出，多次构造必须复用同一个进程级 session，否则每次构造都泄漏一套
    /// session + delegate（内存持续增长的回归点）。
    func testFetcherConstructionsShareOneSession() {
        XCTAssertTrue(
            AntigravityFetcher().sessionForTest === AntigravityFetcher().sessionForTest,
            "AntigravityFetcher 每次构造不得新建 URLSession"
        )
    }
}
