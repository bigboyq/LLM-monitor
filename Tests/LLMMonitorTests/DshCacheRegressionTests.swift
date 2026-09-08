import XCTest
@testable import LLM_monitor

final class DshCacheRegressionTests: XCTestCase {
    private struct ParseCounter {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0

            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }

            func increment() {
                lock.lock()
                count += 1
                lock.unlock()
            }
        }
    }

    private func makeUTCGregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func usageBody(
        sequence: Int = 2,
        turn: Int = 1,
        inputTokens: Int = 10
    ) -> String {
        [
            #"{"type":"request/context","seq":1,"time":1700000000000,"data":{"provider":"deepseek-official","model":"deepseek-v4-flash"}}"#,
            #"{"type":"assistant/message","seq":\#(sequence),"time":1700000001000,"data":{"turn":\#(turn),"step":0,"usage":{"inputTokens":\#(inputTokens),"cacheReadTokens":2,"outputTokens":3,"reasoningTokens":1}}}"#
        ].joined(separator: "\n") + "\n"
    }

    private func writeCompressedSession(
        sessionsRoot: URL,
        sessionID: String,
        body: String,
        modifiedAt: Date
    ) throws -> URL {
        let directory = sessionsRoot
            .appendingPathComponent("--Project--", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("session.jsonl.zst")
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }

    func testChangingOneOf257SessionsDoesNotReparseProtectedHotSet() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = makeUTCGregorianCalendar()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-dsh-cache-regression-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var sessionURLs: [URL] = []
        for index in 0..<257 {
            sessionURLs.append(
                try writeCompressedSession(
                    sessionsRoot: sessionsRoot,
                    sessionID: "session-\(index)",
                    body: usageBody(),
                    modifiedAt: base.addingTimeInterval(Double(-index))
                )
            )
        }

        let counter = ParseCounter.Box()
        let decompressor: DshLocalUsageScanner.Decompressor = { data in
            counter.increment()
            return data
        }
        let first = try DshLocalUsageScanner.performScanPure(
            sessionsRoot: sessionsRoot,
            cacheDir: cacheDir,
            fileManager: FileManagerBox(),
            calendar: calendar,
            now: { base },
            decompressor: decompressor
        )
        XCTAssertEqual(counter.value, 257)
        XCTAssertEqual(first.sessionCount, 257)
        XCTAssertEqual(first.eventCount, 257)
        XCTAssertEqual(first.byProvider["deepseek-official"]?.today?.totalTokens, 257 * 15)

        // Append a replay with a new seq. It changes the fingerprint and is a
        // valid usage record, but the existing turn/step identity keeps the
        // aggregate unchanged. The newest file remains in the protected hot set.
        try Data((usageBody() + usageBody(sequence: 3, inputTokens: 999)).utf8).write(to: sessionURLs[0])
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(1)],
            ofItemAtPath: sessionURLs[0].path
        )

        let second = try DshLocalUsageScanner.performScanPure(
            sessionsRoot: sessionsRoot,
            cacheDir: cacheDir,
            fileManager: FileManagerBox(),
            calendar: calendar,
            now: { base },
            decompressor: decompressor
        )
        // The changed hot file and the one capacity-external file are parsed;
        // the latter is intentionally not cached and cannot evict the hot set.
        XCTAssertEqual(counter.value, 259, "only the changed hot file and cold overflow should be reparsed")
        XCTAssertEqual(second, first, "replayed usage must preserve the aggregate result")
    }

    func testAddingNewestSessionDoesNotReparseTheWholeHistory() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = makeUTCGregorianCalendar()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-dsh-cache-newest-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<256 {
            _ = try writeCompressedSession(
                sessionsRoot: sessionsRoot,
                sessionID: "session-\(index)",
                body: usageBody(),
                modifiedAt: base.addingTimeInterval(Double(-index))
            )
        }

        let counter = ParseCounter.Box()
        let decompressor: DshLocalUsageScanner.Decompressor = { data in
            counter.increment()
            return data
        }
        let first = try DshLocalUsageScanner.performScanPure(
            sessionsRoot: sessionsRoot,
            cacheDir: cacheDir,
            fileManager: FileManagerBox(),
            calendar: calendar,
            now: { base },
            decompressor: decompressor
        )
        XCTAssertEqual(counter.value, 256)
        XCTAssertEqual(first.sessionCount, 256)

        _ = try writeCompressedSession(
            sessionsRoot: sessionsRoot,
            sessionID: "session-newest",
            body: usageBody(turn: 2),
            modifiedAt: base.addingTimeInterval(1)
        )
        let second = try DshLocalUsageScanner.performScanPure(
            sessionsRoot: sessionsRoot,
            cacheDir: cacheDir,
            fileManager: FileManagerBox(),
            calendar: calendar,
            now: { base },
            decompressor: decompressor
        )
        XCTAssertEqual(counter.value, 258, "adding a newest file should not reparse all history")
        XCTAssertEqual(second.sessionCount, 257)
        XCTAssertEqual(second.eventCount, 257)
        XCTAssertEqual(second.byProvider["deepseek-official"]?.today?.totalTokens, 257 * 15)
    }

    func testUnchangedFilesWithinHotSetAreReusedWhenAnotherFileChanges() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = makeUTCGregorianCalendar()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-dsh-cache-hot-set-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = try writeCompressedSession(
            sessionsRoot: sessionsRoot,
            sessionID: "session-first",
            body: usageBody(inputTokens: 10),
            modifiedAt: base
        )
        _ = try writeCompressedSession(
            sessionsRoot: sessionsRoot,
            sessionID: "session-second",
            body: usageBody(turn: 2, inputTokens: 20),
            modifiedAt: base.addingTimeInterval(-1)
        )

        let counter = ParseCounter.Box()
        let decompressor: DshLocalUsageScanner.Decompressor = { data in
            counter.increment()
            return data
        }
        _ = try DshLocalUsageScanner.performScanPure(
            sessionsRoot: sessionsRoot,
            cacheDir: cacheDir,
            fileManager: FileManagerBox(),
            calendar: calendar,
            now: { base },
            decompressor: decompressor
        )
        XCTAssertEqual(counter.value, 2)

        try Data((usageBody(inputTokens: 10) + usageBody(sequence: 3, inputTokens: 999)).utf8).write(to: firstURL)
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(1)],
            ofItemAtPath: firstURL.path
        )
        _ = try DshLocalUsageScanner.performScanPure(
            sessionsRoot: sessionsRoot,
            cacheDir: cacheDir,
            fileManager: FileManagerBox(),
            calendar: calendar,
            now: { base },
            decompressor: decompressor
        )
        XCTAssertEqual(counter.value, 3, "unchanged files in the hot set should remain reusable")
    }
}
