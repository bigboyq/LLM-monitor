import XCTest
@testable import LLM_monitor

final class CodexCachePersistenceTests: XCTestCase {

    func testCodexScannerIndexCodableRoundTrip() throws {
        let usage = CodexTokenUsageEvent(
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 50,
            reasoningOutputTokens: 10
        )
        let event = CodexSessionEvent.tokenCount(
            timestamp: Date(timeIntervalSince1970: 1700000000),
            usage: usage
        )
        let entry = CodexSessionEventCache.Entry(
            parsingFingerprint: "fp-123",
            lastModifiedAt: Date(timeIntervalSince1970: 1700000001),
            parsedFileSize: 1024,
            resumeOffset: 1024,
            events: [event],
            reachedEOF: true
        )
        let index = CodexScannerIndex(
            version: 1,
            entries: ["session-a": entry]
        )

        let data = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(CodexScannerIndex.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertEqual(decoded.entries["session-a"]?.parsedFileSize, 1024)
        XCTAssertEqual(decoded.entries["session-a"]?.events.count, 1)
        XCTAssertEqual(decoded.entries["session-a"]?.events.first, event)
    }

    func testScannerIndexIOPersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let indexURL = tempDir.appendingPathComponent("codex.json")
        let fileManager = FileManagerBox()

        let entry = CodexSessionEventCache.Entry(
            parsingFingerprint: "fp-test",
            lastModifiedAt: Date(timeIntervalSince1970: 1700000000),
            parsedFileSize: 2048,
            resumeOffset: 2048,
            events: [],
            reachedEOF: true
        )
        let original = CodexScannerIndex(version: 1, entries: ["s1": entry])

        try ScannerIndexIO.saveIndex(original, cacheDir: indexURL, fileManager: fileManager)

        let loaded: CodexScannerIndex = try ScannerIndexIO.loadIndex(
            cacheDir: indexURL,
            fileManager: fileManager,
            currentVersion: 1,
            empty: CodexScannerIndex(),
            version: { $0.version },
            logTag: "[test]"
        )
        XCTAssertEqual(loaded.entries["s1"]?.parsedFileSize, 2048)
    }

    func testCodexSessionEventCacheCapacityAndDirtyTracking() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let indexURL = tempDir.appendingPathComponent("codex.json")
        let fileManager = FileManagerBox()

        // Create 300 entries on disk (exceeding initial 256)
        var entries: [String: CodexSessionEventCache.Entry] = [:]
        for i in 0..<300 {
            entries["/path/\(i).jsonl"] = CodexSessionEventCache.Entry(
                parsingFingerprint: "fp",
                lastModifiedAt: Date(timeIntervalSince1970: 1000),
                parsedFileSize: 100,
                resumeOffset: 100,
                events: [],
                reachedEOF: true
            )
        }
        let index = CodexScannerIndex(version: 1, entries: entries)
        try ScannerIndexIO.saveIndex(index, cacheDir: indexURL, fileManager: fileManager)

        let cache = CodexSessionEventCache(cacheFileURL: indexURL, fileManager: fileManager)
        await cache.loadIfNeeded()

        // Check that an entry is found (not evicted due to initial capacity 64 or 256)
        let found = await cache.state(for: URL(fileURLWithPath: "/path/0.jsonl"), parsingFingerprint: "fp")
        XCTAssertNotNil(found, "Cache capacity should expand to accommodate loaded entries")

        // removeAll(except:) with existing keys does not change count, so should not mark dirty
        let allKeys = Set((0..<300).map { "/path/\($0).jsonl" })
        await cache.removeAll(except: allKeys)
        // persistToDisk should be a no-op because isDirty is false
        await cache.persistToDisk()
    }
}
