import XCTest
import SQLite3
@testable import LLM_monitor

/// trajectory metadata 的请求编码与流式解码、server discovery、零 event 缓存的修复，
/// 以及「空 RPC / 空占位文件不算可信成功」这一组 RPC 跳过判定。
final class AntigravityMetadataFetchTests: AntigravityTestCase {

    // MARK: - 共享 fixture

    @MainActor
    private func awaitScan(
        fetcher: AntigravityFetcher,
        conversationsDirs: [URL],
        cacheDir: URL,
        scanner: AntigravityLocalUsageScanner,
        fileManager: FileManager,
        forceFull: Bool = false
    ) throws -> AntigravityLocalUsage {
        let expectation = XCTestExpectation(description: "empty placeholder scan completes")
        var result: AntigravityLocalUsage?
        Task {
            result = try? await AntigravityLocalUsageScanner.performScanPure(
                fetcher: fetcher,
                conversationsDirs: conversationsDirs,
                cacheDir: cacheDir,
                fileManager: FileManagerBox(fileManager),
                calendar: .current,
                now: { Date() },
                startedGeneration: 1,
                scanner: scanner,
                forceFull: forceFull
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)
        return try XCTUnwrap(result)
    }

    // MARK: - 测试

    func testTrajectoryMetadataRequestEncoding() throws {
        let request = TrajectoryMetadataRequest(cascadeId: "test-session-123", includeMessages: false)
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["cascadeId"] as? String, "test-session-123")
        XCTAssertEqual(json["includeMessages"] as? Bool, false)
        XCTAssertNil(json["generatorMetadataOffset"])
    }

    func testTrajectoryMetadataRequestEncodingWithOffset() throws {
        let request = TrajectoryMetadataRequest(cascadeId: "test-session-123", includeMessages: false, generatorMetadataOffset: 42)
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["cascadeId"] as? String, "test-session-123")
        XCTAssertEqual(json["includeMessages"] as? Bool, false)
        XCTAssertEqual(json["generatorMetadataOffset"] as? Int, 42)
    }

    func testTrajectoryMetadataStreamDecoderDoesNotRequireEnvelopeArrayMaterialization() throws {
        let data = Data(#"{"ignored":{"x":[1,2,3]},"generatorMetadata":[{"timestamp":"2026-09-22T00:00:00Z","model":"gemini-2.5-pro","inputTokens":10,"outputTokens":5},{"timestamp":"2026-09-22T00:01:00Z","model":"gemini-2.5-pro","inputTokens":20,"outputTokens":7}],"tail":true}"#.utf8)
        let page = try AntigravityFetcher.decodeTrajectoryMetadataForTest(data)
        XCTAssertEqual(page.metadataEntryCount, 2)
        XCTAssertEqual(page.events.count, 2)
        XCTAssertEqual(page.events.map(\.inputTokens), [10, 20])
        XCTAssertEqual(page.events.map(\.outputTokens), [5, 7])
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

    @MainActor
    func testEmptyPlaceholderFingerprintChangeSkipsRPCUntilFileGrows() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("antigravity-empty-placeholder-\(UUID().uuidString)", isDirectory: true)
        let conversations = root.appendingPathComponent("conversations", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: conversations, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)

        let sessionID = "empty-placeholder"
        try Data().write(to: conversations.appendingPathComponent("\(sessionID).db"))
        let index = AntigravityLocalUsageScanner.CacheIndex(
            version: 7,
            lastScannedAt: Date(),
            sessions: [sessionID: .init(
                mtimeMs: 1,
                sizeBytes: 0,
                walMtimeMs: 1,
                walSizeBytes: 0,
                fetchedAt: Date(),
                eventCount: 0,
                generatorMetadataOffset: 0
            )],
            dailyBySession: [:],
            samplesBySession: [sessionID: []]
        )
        try AntigravityLocalUsageScanner.saveIndex(index, cacheDir: cache, fileManager: FileManagerBox(fm))

        let fetcher = AntigravityFetcher(metadataServerDiscovery: { [] })
        let scanner = AntigravityLocalUsageScanner(
            fetcher: fetcher,
            conversationsDirs: [conversations],
            cacheDir: cache,
            fileManager: FileManagerBox(fm)
        )
        let result = try awaitScan(
            fetcher: fetcher,
            conversationsDirs: [conversations],
            cacheDir: cache,
            scanner: scanner,
            fileManager: fm
        )
        XCTAssertEqual(result.failedSessionCount, 0)
        XCTAssertEqual(result.sessionCount, 1)
    }

    @MainActor
    func testNewEmptyPlaceholderSkipsStartupFullRPC() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("antigravity-new-empty-placeholder-\(UUID().uuidString)", isDirectory: true)
        let conversations = root.appendingPathComponent("conversations", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: conversations, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data().write(to: conversations.appendingPathComponent("new-empty.db"))

        let fetcher = AntigravityFetcher(metadataServerDiscovery: { [] })
        let scanner = AntigravityLocalUsageScanner(
            fetcher: fetcher,
            conversationsDirs: [conversations],
            cacheDir: cache,
            fileManager: FileManagerBox(fm)
        )
        let result = try awaitScan(
            fetcher: fetcher,
            conversationsDirs: [conversations],
            cacheDir: cache,
            scanner: scanner,
            fileManager: fm,
            forceFull: true
        )
        XCTAssertEqual(result.failedSessionCount, 0)
        XCTAssertEqual(result.sessionCount, 1)
        let index = try AntigravityLocalUsageScanner.loadIndex(
            cacheDir: cache,
            fileManager: FileManagerBox(fm)
        )
        XCTAssertEqual(index.sessions["new-empty"]?.eventCount, 0)
    }

    func testRawMetadataCountAdvancesOffsetEvenWhenEventsAreFiltered() {
        XCTAssertTrue(
            AntigravityLocalUsageScanner.isTrustworthyRPCResult(
                [],
                metadataEntryCount: 3
            ),
            "有原始 metadata 条目但没有可入账 UsageEvent 时，仍应消费该 RPC page"
        )
        XCTAssertEqual(
            AntigravityLocalUsageScanner.advanceGeneratorMetadataOffset(10, by: 3),
            13,
            "offset 必须按原始 metadata 条目数推进，而不是按 parsed events 数量推进"
        )
        XCTAssertEqual(
            AntigravityLocalUsageScanner.advanceGeneratorMetadataOffset(10, by: 0),
            10
        )
    }
}
