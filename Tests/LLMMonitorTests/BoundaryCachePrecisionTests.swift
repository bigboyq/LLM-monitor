import Foundation
import XCTest
@testable import LLM_monitor

final class BoundaryCachePrecisionTests: XCTestCase {
    private struct Index: Codable {
        var version: Int
        var dates: [Date]
    }

    private func cacheURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("boundary-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("index.json")
    }

    func testISODateRoundTripKeepsMillisecondsAndStringShape() throws {
        let cache = try cacheURL()
        let milliseconds: [Int64] = [1_800_000_000_001, 1_800_000_000_273, 1_800_000_000_999, -1]
        let original = Index(version: 1, dates: milliseconds.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        try ScannerIndexIO.saveIndex(original, cacheDir: cache, fileManager: FileManagerBox())
        let loaded: Index = try ScannerIndexIO.loadIndex(
            cacheDir: cache, fileManager: FileManagerBox(), currentVersion: 1,
            empty: Index(version: 1, dates: []), version: { $0.version }, logTag: "[precision-test]"
        )
        XCTAssertEqual(loaded.dates.count, original.dates.count)
        for (a, b) in zip(loaded.dates, original.dates) {
            XCTAssertEqual(a.timeIntervalSinceReferenceDate, b.timeIntervalSinceReferenceDate)
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        let strings = try XCTUnwrap(object["dates"] as? [String])
        XCTAssertTrue(strings.allSatisfy { $0.contains(".") && $0.hasSuffix("Z") })
    }

    func testNanosecondSourceDatesKeepTheirActualFloatingPointRepresentation() throws {
        let cache = try cacheURL()
        // Same construction as Antigravity protobuf Timestamp, on realistic
        // recent dates. Double already limits the original timestamp precision;
        // the cache must not lose any further representable Date bits.
        let nanos = [1, 7, 1_001, 123_456_789, 273_000_001, 999_999_999]
        let dates = nanos.map { Date(timeIntervalSince1970: 1_800_000_000 + Double($0) / 1_000_000_000) }
        try ScannerIndexIO.saveIndex(Index(version: 1, dates: dates), cacheDir: cache, fileManager: FileManagerBox())
        let loaded: Index = try ScannerIndexIO.loadIndex(
            cacheDir: cache, fileManager: FileManagerBox(), currentVersion: 1,
            empty: Index(version: 1, dates: []), version: { $0.version }, logTag: "[precision-test]"
        )
        XCTAssertEqual(loaded.dates, dates)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        let strings = try XCTUnwrap(object["dates"] as? [String])
        XCTAssertTrue(strings.allSatisfy { $0.split(separator: ".").last?.dropLast().count == 9 })
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let nativeDifferences = zip(strings, dates).filter { string, date in
            (try? style.parse(string)) != date
        }.count
        print("[cache-codec] Foundation 9-digit parser differences: \(nativeDifferences)/\(dates.count)")
    }

    func testFractionRoundingCarriesIntoTheNextSecond() throws {
        let cache = try cacheURL()
        // Artificial reference-epoch boundary exercises decimal rounding carry;
        // production contemporary Date precision is coarser than a nanosecond.
        let date = Date(timeIntervalSinceReferenceDate: 0.999_999_999_6)
        try ScannerIndexIO.saveIndex(Index(version: 1, dates: [date]), cacheDir: cache, fileManager: FileManagerBox())
        let loaded: Index = try ScannerIndexIO.loadIndex(
            cacheDir: cache, fileManager: FileManagerBox(), currentVersion: 1,
            empty: Index(version: 1, dates: []), version: { $0.version }, logTag: "[precision-test]"
        )
        XCTAssertEqual(loaded.dates.first?.timeIntervalSinceReferenceDate, 1)
        let text = try String(contentsOf: cache, encoding: .utf8)
        XCTAssertTrue(text.contains("2001-01-01T00:00:01.000000000Z"))
    }

    func testTenThousandSampleCacheReadWriteObservation() throws {
        struct SampleIndex: Codable {
            var version: Int
            var samples: [LocalTokenUsageSample]
        }
        let cache = try cacheURL()
        let samples = (0..<10_000).map { index in
            LocalTokenUsageSample(
                completedAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index) / 1_000_000),
                modelName: "gemini-3-pro", promptID: "sample-\(index)", inputTokens: 100,
                cachedInputTokens: 20, outputTokens: 50, reasoningOutputTokens: 10
            )
        }
        let start = ProcessInfo.processInfo.systemUptime
        try ScannerIndexIO.saveIndex(SampleIndex(version: 1, samples: samples), cacheDir: cache, fileManager: FileManagerBox())
        let written = ProcessInfo.processInfo.systemUptime
        let loaded: SampleIndex = try ScannerIndexIO.loadIndex(
            cacheDir: cache, fileManager: FileManagerBox(), currentVersion: 1,
            empty: SampleIndex(version: 1, samples: []), version: { $0.version }, logTag: "[precision-test]"
        )
        let read = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(loaded.samples, samples)
        print("[cache-codec] 10000 samples write=\(written - start)s read=\(read - written)s")
    }

    func testLegacyWholeSecondAndFractionalDatesDecodeTogether() throws {
        let cache = try cacheURL()
        try Data(#"{"version":1,"dates":["2026-11-10T00:00:00Z","2026-11-10T00:00:00.273Z"]}"#.utf8).write(to: cache)
        let loaded: Index = try ScannerIndexIO.loadIndex(
            cacheDir: cache, fileManager: FileManagerBox(), currentVersion: 1,
            empty: Index(version: 1, dates: []), version: { $0.version }, logTag: "[precision-test]"
        )
        XCTAssertEqual(loaded.dates.count, 2)
        guard loaded.dates.count == 2 else { return }
        XCTAssertEqual(loaded.dates[1].timeIntervalSince(loaded.dates[0]), 0.273, accuracy: 0.000_001)
    }

    func testMalformedDateStillResetsCache() throws {
        let cache = try cacheURL()
        try Data(#"{"version":1,"dates":["invalid-date"]}"#.utf8).write(to: cache)
        let loaded: Index = try ScannerIndexIO.loadIndex(
            cacheDir: cache, fileManager: FileManagerBox(), currentVersion: 1,
            empty: Index(version: 1, dates: []), version: { $0.version }, logTag: "[precision-test]"
        )
        XCTAssertTrue(loaded.dates.isEmpty)
    }

    func testPreviousAntigravityMinimaxAndZcodeVersionsAreRejected() throws {
        let cache = try cacheURL()
        let files = FileManagerBox()
        var antigravity = AntigravityLocalUsageScanner.CacheIndex.empty
        antigravity.version = 12
        antigravity.sessions["stale"] = .init(mtimeMs: 0, sizeBytes: 0, fetchedAt: nil, eventCount: 1)
        try ScannerIndexIO.saveIndex(antigravity, cacheDir: cache, fileManager: files)
        let ag = try AntigravityLocalUsageScanner.loadIndex(cacheDir: cache, fileManager: files)
        XCTAssertEqual(ag.version, 13)
        XCTAssertTrue(ag.sessions.isEmpty)

        var minimax = MinimaxLocalUsageScanner.CacheIndex.empty
        minimax.version = 21
        minimax.dailyBySource["stale"] = [:]
        try ScannerIndexIO.saveIndex(minimax, cacheDir: cache, fileManager: files)
        let mm = try MinimaxLocalUsageScanner.loadIndex(cacheDir: cache, fileManager: files)
        XCTAssertEqual(mm.version, 22)
        XCTAssertTrue(mm.dailyBySource.isEmpty)

        let zcode = GlmZcodeLocalUsageScanner.CacheIndex(
            version: 14, dbMtimeMs: 0, dbSizeBytes: 0, walMtimeMs: 0, walSizeBytes: 0,
            snapshot: .empty, calendarSignature: LocalUsageCalendarSignature.make(.autoupdatingCurrent)
        )
        try ScannerIndexIO.saveIndex(zcode, cacheDir: cache, fileManager: files)
        XCTAssertNil(GlmZcodeLocalUsageScanner.loadCachedResult(cacheDir: cache, fileManager: files))
    }

    func testPreviousCodexVersionCannotReuseTruncatedEvents() async throws {
        let cache = try cacheURL()
        let eventCache = CodexSessionEventCache(cacheFileURL: cache, fileManager: FileManagerBox())
        let entry = CodexSessionEventCache.Entry(
            parsingFingerprint: "stale", lastModifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            parsedFileSize: 1, resumeOffset: 1, events: [], reachedEOF: true
        )
        try ScannerIndexIO.saveIndex(
            CodexScannerIndex(version: 2, entries: ["/controlled/session": entry]),
            cacheDir: cache, fileManager: FileManagerBox()
        )
        await eventCache.loadIfNeeded()
        let restored = await eventCache.state(for: URL(fileURLWithPath: "/controlled/session"), parsingFingerprint: "stale")
        XCTAssertNil(restored)
    }
}
