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
}
