import XCTest
@testable import LLM_monitor

final class DshUsageTests: XCTestCase {
    private func makeUTCGregorianCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @discardableResult
    private func writeSessionLog(
        root: URL,
        sessionID: String,
        project: String = "Project",
        body: String
    ) throws -> URL {
        let directory = root
            .appendingPathComponent("--\(project)--", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("session.jsonl")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testScannerAggregatesExactUsageFromPlainJSONL() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = makeUTCGregorianCalendar()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-dsh-scan-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent(".token-monitor", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines: [String] = [
            #"{"type":"session","version":0,"id":"session-1","createdAt":1700000000000,"cwd":"/tmp","delegationDepth":0}"#,
            #"{"type":"request/context","seq":1,"time":1700000000000,"data":{"provider":"deepseek-official","model":"deepseek-v4-flash","contextWindow":1000000}}"#,
            #"{"type":"assistant/message","seq":2,"time":1700000001000,"data":{"turn":1,"step":0,"usage":{"inputTokens":100,"cacheReadTokens":50,"outputTokens":30,"reasoningTokens":10}}}"#,
            #"{"type":"assistant/message","seq":3,"time":1700000002000,"data":{"turn":1,"step":1,"usage":{"inputTokens":200,"cacheReadTokens":0,"outputTokens":10,"reasoningTokens":0}}}"#,
            #"{"type":"assistant/message","seq":4,"time":1700000003000,"data":{"turn":2,"step":0,"usage":{"inputTokens":10,"cacheReadTokens":20,"outputTokens":5,"reasoningTokens":5}}}"#,
            #"{"type":"turn/end","seq":5,"time":1700000004000,"data":{"turn":2,"reason":{"kind":"completed"}}}"#
        ]
        try writeSessionLog(
            root: root.appendingPathComponent("sessions", isDirectory: true),
            sessionID: "session-1",
            body: lines.joined(separator: "\n") + "\n"
        )

        let snapshot = try DshLocalUsageScanner.performScanPure(
            sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true),
            cacheDir: cache,
            fileManager: FileManagerBox(),
            calendar: calendar,
            now: { base },
            decompressor: { $0 },
            limits: DshLocalUsageScanLimits.production
        )

        XCTAssertEqual(snapshot.sessionCount, 1)
        XCTAssertEqual(snapshot.eventCount, 3)
        let deepseek = try XCTUnwrap(snapshot.byProvider["deepseek-official"])
        XCTAssertEqual(deepseek.roundCount, 3)
        XCTAssertEqual(deepseek.sessionCount, 1)
        XCTAssertEqual(deepseek.dailyTokenUsage.count, 7)
        let today = try XCTUnwrap(deepseek.today)
        XCTAssertEqual(today.inputTokens, 310)
        XCTAssertEqual(today.cacheReadTokens, 70)
        // raw output 30+10+5=45; reasoning 10+0+5=15; visible output 30.
        XCTAssertEqual(today.outputTokens, 30)
        XCTAssertEqual(today.reasoningTokens, 15)
        XCTAssertEqual(today.totalTokens, 425)
        XCTAssertEqual(today.turns, 2)
        XCTAssertEqual(today.rounds, 3)
        XCTAssertEqual(deepseek.recentSamples.count, 3)
        XCTAssertTrue(deepseek.recentSamples.allSatisfy {
            $0.sourceProviderID?.hasPrefix("dsh:") == true
        })
    }

    func testDshMergerSelectsDeepSeekSliceAndAddsOpencode() throws {
        let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
        let dshUsage = DshLocalUsage(
            byProvider: [
                "deepseek-official": DshProviderUsage(
                    today: DshDailyUsage(
                        dayStart: dayStart,
                        inputTokens: 100,
                        cacheReadTokens: 50,
                        outputTokens: 20,
                        reasoningTokens: 10,
                        totalTokens: 170,
                        turns: 1,
                        rounds: 2
                    ),
                    dailyTokenUsage: [],
                    sessionCount: 1,
                    roundCount: 2,
                    recentSamples: []
                ),
                "minimax-cn": DshProviderUsage(
                    today: DshDailyUsage(
                        dayStart: dayStart,
                        inputTokens: 10,
                        outputTokens: 5,
                        totalTokens: 15,
                        turns: 1,
                        rounds: 1
                    ),
                    dailyTokenUsage: [],
                    sessionCount: 1,
                    roundCount: 1,
                    recentSamples: []
                )
            ],
            modelsByProvider: ["deepseek-official": ["deepseek-v4-flash"]],
            sessionsRoot: "/tmp/.dsh/sessions",
            sessionCount: 2,
            eventCount: 3,
            scannedAt: Date()
        )

        let merged = try XCTUnwrap(DshUsageMerger.mergeDeepseek(dsh: dshUsage, opencode: nil))
        XCTAssertEqual(merged.roundCount, 2)
        let today = try XCTUnwrap(merged.today)
        XCTAssertEqual(today.inputTokens, 100)
        XCTAssertEqual(today.outputTokens, 20)
        XCTAssertEqual(today.reasoningTokens, 10)
    }

    func testDshLocalUsageEqualityIgnoresScannedAt() {
        let a = DshLocalUsage(
            byProvider: [:],
            modelsByProvider: [:],
            sessionsRoot: "/tmp/.dsh/sessions",
            sessionCount: 0,
            eventCount: 0,
            scannedAt: Date(timeIntervalSince1970: 1)
        )
        let b = DshLocalUsage(
            byProvider: [:],
            modelsByProvider: [:],
            sessionsRoot: "/tmp/.dsh/sessions",
            sessionCount: 0,
            eventCount: 0,
            scannedAt: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(a, b)
    }
}
