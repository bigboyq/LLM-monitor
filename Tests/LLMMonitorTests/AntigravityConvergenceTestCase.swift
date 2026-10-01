import XCTest
import SQLite3
@testable import LLM_monitor

/// 收敛类测试的共享基类：单 session 夹具（带 last-good 但指纹过期的 v7 index）、
/// metadata 替身与扫描驱动。收敛类三组测试共用，故不住在任何一个测试类里。
class AntigravityConvergenceTestCase: AntigravityTestCase {

    // MARK: - 共享 fixture
    //
    // 同样刻意不是 `private`：收敛类三组测试继承本基类且分布在不同文件。
    // `MetadataStub` / `ConvergenceFixture` 内部的 private 状态不受影响。

    /// RPC 替身：线程安全地记录 (sessionID, offset) 调用并按 handler 返回。
    /// handler 可在扫描轮次之间替换，模拟 server 从"滞后"恢复到"有数据"。
    final class MetadataStub: @unchecked Sendable {
        typealias Page = (events: [AntigravityFetcher.UsageEvent], metadataEntryCount: Int)

        // handler 允许抛错：.failure 分支（传输层失败）没有其他测试接缝。
        private let lock = NSLock()
        private var handler: @Sendable (String, Int) async throws -> Page
        private var calls: [(sessionID: String, offset: Int)] = []

        init(handler: @escaping @Sendable (String, Int) async throws -> Page) {
            self.handler = handler
        }

        func setHandler(_ handler: @escaping @Sendable (String, Int) async throws -> Page) {
            lock.withLock { self.handler = handler }
        }

        func fetch(sessionID: String, offset: Int) async throws -> Page {
            let current = lock.withLock {
                calls.append((sessionID, offset))
                return handler
            }
            return try await current(sessionID, offset)
        }

        var callCount: Int { lock.withLock { calls.count } }

        var lastOffset: Int? { lock.withLock { calls.last?.offset } }
    }

    struct ConvergenceFixture {
        let root: URL
        let conversations: URL
        let cache: URL
        let sessionID: String
        let dbPath: URL
        let liveMtimeMs: Double
        let liveSizeBytes: Int
        let dayKey: String
        let dayStart: Date
        let fm: FileManager
    }

    /// 单 session 收敛测试夹具：non-empty `.db` + 带 last-good（offset/事件数可配、
    /// 当日 daily 桶 input=500、空 samples）但指纹过期的 v7 index。calendarSignature
    /// 默认与 testCalendar 一致（避免触发冷重建全量路径），可注入旧日历签名
    /// 模拟时区变更冷重建。
    func makeConvergenceFixture(
        cachedOffset: Int,
        cachedEventCount: Int,
        seededCalendarSignature: String? = nil
    ) throws -> ConvergenceFixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("antigravity-converge-\(UUID().uuidString)", isDirectory: true)
        let conversations = root.appendingPathComponent("conversations", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: conversations, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)

        let sessionID = "converge-session"
        let dbPath = conversations.appendingPathComponent("\(sessionID).db")
        try Data(repeating: 1, count: 128).write(to: dbPath)
        let values = try dbPath.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let liveMtimeMs = try XCTUnwrap(values.contentModificationDate).timeIntervalSince1970 * 1000
        let liveSizeBytes = try XCTUnwrap(values.fileSize)

        let dayStart = testCalendar.startOfDay(for: Date(timeIntervalSince1970: 1_789_996_800))
        let dayKey = LocalUsageDayKey.make(dayStart, calendar: testCalendar)
        let seededAt = Date(timeIntervalSince1970: 1_789_990_000)
        let index = AntigravityLocalUsageScanner.CacheIndex(
            version: 7,
            lastScannedAt: seededAt,
            sessions: [sessionID: .init(
                mtimeMs: liveMtimeMs - 60_000,              // 过期指纹 → dirty
                sizeBytes: liveSizeBytes - 10,              // 小于当前 → 非 shrink
                walMtimeMs: 0,
                walSizeBytes: 0,
                fetchedAt: seededAt,
                eventCount: cachedEventCount,
                generatorMetadataOffset: cachedOffset
            )],
            dailyBySession: [sessionID: [
                dayKey: AntigravityDailyUsage(dayStart: dayStart, inputTokens: 500, totalTokens: 500)
            ]],
            samplesBySession: [sessionID: []],
            calendarSignature: seededCalendarSignature ?? LocalUsageCalendarSignature.make(testCalendar)
        )
        try AntigravityLocalUsageScanner.saveIndex(index, cacheDir: cache, fileManager: FileManagerBox(fm))

        return ConvergenceFixture(
            root: root,
            conversations: conversations,
            cache: cache,
            sessionID: sessionID,
            dbPath: dbPath,
            liveMtimeMs: liveMtimeMs,
            liveSizeBytes: liveSizeBytes,
            dayKey: dayKey,
            dayStart: dayStart,
            fm: fm
        )
    }

    func runConvergenceScan(
        fixture: ConvergenceFixture,
        now: Date,
        stub: MetadataStub
    ) async throws -> AntigravityLocalUsage {
        try await AntigravityLocalUsageScanner.performScanPureImpl(
            fetcher: AntigravityFetcher(metadataServerDiscovery: {
                // 替身路径不真正出网，但 discovery 必须非空才能进入 fetch 阶段。
                [AntigravityFetcher.ServerInfo(pid: 1, httpsPort: 1, csrfToken: nil, kind: .ide)]
            }),
            conversationsDirs: [fixture.conversations],
            cacheDir: fixture.cache,
            fileManager: FileManagerBox(fixture.fm),
            calendar: testCalendar,
            now: { now },
            shouldSave: true,
            metadataFetch: { sessionID, offset in
                try await stub.fetch(sessionID: sessionID, offset: offset)
            }
        )
    }

    func loadConvergenceIndex(_ fixture: ConvergenceFixture) throws -> AntigravityLocalUsageScanner.CacheIndex {
        try AntigravityLocalUsageScanner.loadIndex(
            cacheDir: fixture.cache,
            fileManager: FileManagerBox(fixture.fm)
        )
    }
}
