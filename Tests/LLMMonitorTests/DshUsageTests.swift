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

    func testDshCacheWriteIsReportedSeparatelyAndExcludedFromTotal() throws {
        // spec/providers/dsh.md 明示：cacheWrite 单独成桶，不计入 totalTokens。
        // 这条测试构造一行同时含 cacheWrite 的 assistant/message，验证
        // 1) cacheWriteTokens 字段被正确保留；2) totalTokens 只 sum input + cacheRead + output + reasoning。
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = makeUTCGregorianCalendar()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-dsh-cache-write-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent(".token-monitor", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines: [String] = [
            #"{"type":"session","version":0,"id":"session-cachewrite","createdAt":1700000000000,"cwd":"/tmp","delegationDepth":0}"#,
            #"{"type":"request/context","seq":1,"time":1700000000000,"data":{"provider":"deepseek-official","model":"deepseek-v4-flash","contextWindow":1000000}}"#,
            // cacheWrite = 777，理论应被 totalTokens 排除但保留到 cacheWriteTokens 字段。
            #"{"type":"assistant/message","seq":2,"time":1700000001000,"data":{"turn":1,"step":0,"usage":{"inputTokens":100,"cacheReadTokens":50,"cacheWriteTokens":777,"outputTokens":30,"reasoningTokens":10}}}"#
        ]
        try writeSessionLog(
            root: root.appendingPathComponent("sessions", isDirectory: true),
            sessionID: "session-cachewrite",
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

        let deepseek = try XCTUnwrap(snapshot.byProvider["deepseek-official"])
        let today = try XCTUnwrap(deepseek.today)
        XCTAssertEqual(today.inputTokens, 100)
        XCTAssertEqual(today.cacheReadTokens, 50)
        XCTAssertEqual(today.cacheWriteTokens, 777, "cacheWrite 必须保留到独立字段，不能丢弃")
        XCTAssertEqual(today.outputTokens, 20, "output = 30 - reasoning 10")
        XCTAssertEqual(today.reasoningTokens, 10)
        // totalTokens = input + cacheRead + output + reasoning = 100 + 50 + 20 + 10 = 180，
        // 不应包含 cacheWrite (777)。
        XCTAssertEqual(today.totalTokens, 180)
    }

    func testDshMergerSelectsGlmSliceAndAddsOpencode() throws {
        // 与 deepseek 分片测试对称：构造同时含 glm 和 minimax provider 的 DSH snapshot，
        // 验证 mergeGlm 只合并 glm 别名集合里的 provider，并保留 roundCount。
        // merger 的 slice() 直接采纳 scanner 已算好的 today 字段（scanner 内部已把
        // visibleOutput = output - reasoning 处理过），所以这里的 outputTokens 就是 UI 值。
        let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
        let dshUsage = DshLocalUsage(
            byProvider: [
                "zhipuai": DshProviderUsage(
                    today: DshDailyUsage(
                        dayStart: dayStart,
                        inputTokens: 50,
                        cacheReadTokens: 25,
                        outputTokens: 10,
                        reasoningTokens: 5,
                        totalTokens: 80,
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
                        inputTokens: 999, // 故意放大，验证不会泄漏进 glm 分片
                        outputTokens: 999,
                        totalTokens: 999,
                        turns: 1,
                        rounds: 1
                    ),
                    dailyTokenUsage: [],
                    sessionCount: 1,
                    roundCount: 1,
                    recentSamples: []
                )
            ],
            modelsByProvider: ["zhipuai": ["GLM-4.5"]],
            sessionsRoot: "/tmp/.dsh/sessions",
            sessionCount: 2,
            eventCount: 3,
            scannedAt: Date()
        )

        let merged = try XCTUnwrap(DshUsageMerger.mergeGlm(dsh: dshUsage))
        XCTAssertEqual(merged.roundCount, 2)
        let today = try XCTUnwrap(merged.today)
        XCTAssertEqual(today.inputTokens, 50)
        XCTAssertEqual(today.cacheReadTokens, 25)
        XCTAssertEqual(today.outputTokens, 10)
        XCTAssertEqual(today.reasoningTokens, 5)
        // minimax-cn 的 999 不能漏进 glm 卡片
        XCTAssertNotEqual(today.inputTokens, 999)
    }

    func testDshMergerSelectsMinimaxSliceAndAddsOpencode() throws {
        // 验证 mergeMinimax 只合并 minimax alias 集合，并排除 glm provider。
        let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
        let dshUsage = DshLocalUsage(
            byProvider: [
                "minimax": DshProviderUsage(
                    today: DshDailyUsage(
                        dayStart: dayStart,
                        inputTokens: 100,
                        cacheReadTokens: 20,
                        outputTokens: 15,
                        reasoningTokens: 5,
                        totalTokens: 130,
                        turns: 1,
                        rounds: 3
                    ),
                    dailyTokenUsage: [],
                    sessionCount: 1,
                    roundCount: 3,
                    recentSamples: []
                ),
                "zhipu": DshProviderUsage(
                    today: DshDailyUsage(
                        dayStart: dayStart,
                        inputTokens: 888,
                        outputTokens: 888,
                        totalTokens: 888,
                        turns: 1,
                        rounds: 1
                    ),
                    dailyTokenUsage: [],
                    sessionCount: 1,
                    roundCount: 1,
                    recentSamples: []
                )
            ],
            modelsByProvider: ["minimax": ["MiniMax-M3"]],
            sessionsRoot: "/tmp/.dsh/sessions",
            sessionCount: 2,
            eventCount: 4,
            scannedAt: Date()
        )

        let merged = try XCTUnwrap(DshUsageMerger.mergeMinimax(dsh: dshUsage))
        XCTAssertEqual(merged.roundCount, 3)
        let today = try XCTUnwrap(merged.today)
        XCTAssertEqual(today.inputTokens, 100)
        XCTAssertEqual(today.cacheReadTokens, 20)
        XCTAssertEqual(today.outputTokens, 15)
        XCTAssertEqual(today.reasoningTokens, 5)
        XCTAssertNotEqual(today.inputTokens, 888)
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

    func testDshSampleHasTotalInputTokensAndProducesCorrectUncachedSummary() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = makeUTCGregorianCalendar()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-dsh-sample-test-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent(".token-monitor", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines: [String] = [
            #"{"type":"session","version":0,"id":"session-1","createdAt":1700000000000,"cwd":"/tmp","delegationDepth":0}"#,
            #"{"type":"request/context","seq":1,"time":1700000000000,"data":{"provider":"minimax","model":"MiniMax-M3"}}"#,
            #"{"type":"assistant/message","seq":2,"time":1700000001000,"data":{"turn":1,"step":0,"usage":{"inputTokens":584000,"cacheReadTokens":100000,"outputTokens":5000,"reasoningTokens":0}}}"#
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

        let minimax = try XCTUnwrap(snapshot.byProvider["minimax"])
        let sample = try XCTUnwrap(minimax.recentSamples.first)
        // inputTokens is total (uncached 584k + cached 100k) = 684k
        XCTAssertEqual(sample.inputTokens, 684_000)
        XCTAssertEqual(sample.cachedInputTokens, 100_000)

        // Summary in hover window:
        let summary = LocalUsageSummaryBuilder.summary(
            samples: minimax.recentSamples,
            providerKind: .minimaxTokenPlan,
            quotaModelName: "general",
            start: base.addingTimeInterval(-10),
            end: base.addingTimeInterval(60)
        )
        let unwrappedSummary = try XCTUnwrap(summary)
        XCTAssertEqual(unwrappedSummary.uncachedInputTokens, 584_000, "Uncached input in current window must match 584k, not 0")
        XCTAssertEqual(unwrappedSummary.cachedInputTokens, 100_000)
    }
}
