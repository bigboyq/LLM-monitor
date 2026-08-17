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

    func testMiniMaxM3EstimatesReasoningFromSameMessageContent() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = makeUTCGregorianCalendar()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-dsh-m3-reasoning-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent(".token-monitor", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines: [String] = [
            #"{"type":"session","version":0,"id":"session-m3","createdAt":1700000000000,"cwd":"/tmp","delegationDepth":0}"#,
            #"{"type":"request/context","seq":1,"time":1700000000000,"data":{"provider":"minimax-cn","model":"MiniMax-M3","contextWindow":1000000}}"#,
            // reasoning chars = 10; visible chars = text(5) + tool args(5),
            // so the 100 raw output tokens split evenly.
            #"{"type":"assistant/message","seq":2,"time":1700000001000,"data":{"turn":1,"step":0,"usage":{"inputTokens":100,"cacheReadTokens":50,"outputTokens":100},"message":{"role":"assistant","content":[{"type":"reasoning","text":"1234567890"},{"type":"text","text":"12345"},{"type":"tool-call","name":"run","id":"call-1","arguments":"12345"}]}}}"#,
            // A native reasoning value wins over the character estimate.
            #"{"type":"assistant/message","seq":3,"time":1700000002000,"data":{"turn":1,"step":1,"usage":{"inputTokens":100,"cacheReadTokens":0,"outputTokens":100,"reasoningTokens":20},"message":{"role":"assistant","content":[{"type":"reasoning","text":"12345678901234567890"},{"type":"text","text":"1"}]}}}"#
        ]
        try writeSessionLog(
            root: root.appendingPathComponent("sessions", isDirectory: true),
            sessionID: "session-m3",
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

        let minimax = try XCTUnwrap(snapshot.byProvider["minimax-cn"])
        let today = try XCTUnwrap(minimax.today)
        XCTAssertEqual(today.outputTokens, 130)
        XCTAssertEqual(today.reasoningTokens, 70)
        XCTAssertEqual(today.totalTokens, 450)
        XCTAssertEqual(minimax.recentSamples.map(\.reasoningOutputTokens), [50, 20])
        XCTAssertEqual(minimax.recentSamples.map(\.outputTokens), [50, 80])
    }

    func testMiniMaxM3ReasoningEstimateDoesNotApplyToOtherDshModels() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = makeUTCGregorianCalendar()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-dsh-non-m3-reasoning-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent(".token-monitor", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines: [String] = [
            #"{"type":"session","version":0,"id":"session-other","createdAt":1700000000000,"cwd":"/tmp","delegationDepth":0}"#,
            #"{"type":"request/context","seq":1,"time":1700000000000,"data":{"provider":"minimax-cn","model":"MiniMax-M2.7","contextWindow":1000000}}"#,
            #"{"type":"assistant/message","seq":2,"time":1700000001000,"data":{"turn":1,"step":0,"usage":{"inputTokens":100,"outputTokens":100},"message":{"role":"assistant","content":[{"type":"reasoning","text":"1234567890"},{"type":"text","text":"12345"}]}}}"#
        ]
        try writeSessionLog(
            root: root.appendingPathComponent("sessions", isDirectory: true),
            sessionID: "session-other",
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

        let minimax = try XCTUnwrap(snapshot.byProvider["minimax-cn"])
        let today = try XCTUnwrap(minimax.today)
        XCTAssertEqual(today.outputTokens, 100)
        XCTAssertEqual(today.reasoningTokens, 0)
        XCTAssertEqual(minimax.recentSamples.first?.outputTokens, 100)
        XCTAssertEqual(minimax.recentSamples.first?.reasoningOutputTokens, 0)
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
        // totalTokens = input + cacheRead + rawOutput（含 reasoning）= 100 + 50 + 30 = 180，
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

    @discardableResult
    private func writeRawSessionArtifact(
        root: URL,
        sessionID: String,
        fileName: String,
        body: Data
    ) throws -> URL {
        let directory = root
            .appendingPathComponent("--Project--", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try body.write(to: url)
        return url
    }

    private struct DshDecompressorCallCounter {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            var value: Int {
                lock.lock(); defer { lock.unlock() }
                return count
            }
            func increment() {
                lock.lock(); defer { lock.unlock() }
                count += 1
            }
        }

        struct DecompressError: LocalizedError {
            var errorDescription: String? { "模拟的 zstd 解压失败" }
        }
    }

    func testCorruptZstdSessionFileIsSkippedWhileGoodFilesStillAggregate() throws {
        // spec/providers/dsh.md Scanner behavior：坏文件跳过、不中断整扫。
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = makeUTCGregorianCalendar()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-dsh-corrupt-mixed-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cache = root.appendingPathComponent(".token-monitor", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let goodLines = [
            #"{"type":"request/context","seq":1,"time":1700000000000,"data":{"provider":"deepseek-official","model":"deepseek-v4-flash"}}"#,
            #"{"type":"assistant/message","seq":2,"time":1700000001000,"data":{"turn":1,"step":0,"usage":{"inputTokens":100,"cacheReadTokens":50,"outputTokens":30,"reasoningTokens":10}}}"#
        ]
        try writeSessionLog(
            root: sessionsRoot,
            sessionID: "session-good",
            body: goodLines.joined(separator: "\n") + "\n"
        )
        try writeRawSessionArtifact(
            root: sessionsRoot,
            sessionID: "session-bad",
            fileName: "session.jsonl.zst",
            body: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )

        // 坏 .zst 抛错时整个扫描必须仍然成功，且好文件数据保留。
        let snapshot = try DshLocalUsageScanner.performScanPure(
            sessionsRoot: sessionsRoot,
            cacheDir: cache,
            fileManager: FileManagerBox(),
            calendar: calendar,
            now: { base },
            decompressor: { _ in throw DshDecompressorCallCounter.DecompressError() },
            limits: DshLocalUsageScanLimits.production
        )

        XCTAssertEqual(snapshot.sessionCount, 1, "坏文件必须被隔离，好 session 仍要聚合")
        XCTAssertEqual(snapshot.eventCount, 1)
        let deepseek = try XCTUnwrap(snapshot.byProvider["deepseek-official"])
        XCTAssertEqual(deepseek.today?.inputTokens, 100)
        XCTAssertEqual(deepseek.recentSamples.count, 1)
    }

    func testAllCorruptSessionFilesProduceEmptySnapshotWithoutThrowing() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = makeUTCGregorianCalendar()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-dsh-corrupt-all-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cache = root.appendingPathComponent(".token-monitor", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeRawSessionArtifact(
            root: sessionsRoot,
            sessionID: "session-bad-1",
            fileName: "session.jsonl.zst",
            body: Data([0xDE, 0xAD])
        )
        try writeRawSessionArtifact(
            root: sessionsRoot,
            sessionID: "session-bad-2",
            fileName: "session.jsonl.zstd",
            body: Data([0xBE, 0xEF])
        )

        let snapshot = try DshLocalUsageScanner.performScanPure(
            sessionsRoot: sessionsRoot,
            cacheDir: cache,
            fileManager: FileManagerBox(),
            calendar: calendar,
            now: { base },
            decompressor: { _ in throw DshDecompressorCallCounter.DecompressError() },
            limits: DshLocalUsageScanLimits.production
        )

        // 全部文件失败：不抛错（目录枚举和缓存写入本身没有失败），
        // 结果为空快照，坏文件不计入 session/event。
        XCTAssertEqual(snapshot.sessionCount, 0)
        XCTAssertEqual(snapshot.eventCount, 0)
        XCTAssertTrue(snapshot.byProvider.isEmpty)
    }

    func testFailedSessionFileIsNotInSuccessFingerprintAndIsRetriedNextScan() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = makeUTCGregorianCalendar()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-dsh-corrupt-retry-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        let cache = root.appendingPathComponent(".token-monitor", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let goodLines = [
            #"{"type":"request/context","seq":1,"time":1700000000000,"data":{"provider":"deepseek-official","model":"deepseek-v4-flash"}}"#,
            #"{"type":"assistant/message","seq":2,"time":1700000001000,"data":{"turn":1,"step":0,"usage":{"inputTokens":100,"outputTokens":30}}}"#
        ]
        try writeSessionLog(
            root: sessionsRoot,
            sessionID: "session-good",
            body: goodLines.joined(separator: "\n") + "\n"
        )
        let badURL = try writeRawSessionArtifact(
            root: sessionsRoot,
            sessionID: "session-bad",
            fileName: "session.jsonl.zst",
            body: Data([0xDE, 0xAD])
        )

        let counter = DshDecompressorCallCounter.Box()
        let failingDecompressor: DshLocalUsageScanner.Decompressor = { _ in
            counter.increment()
            throw DshDecompressorCallCounter.DecompressError()
        }

        _ = try DshLocalUsageScanner.performScanPure(
            sessionsRoot: sessionsRoot,
            cacheDir: cache,
            fileManager: FileManagerBox(),
            calendar: calendar,
            now: { base },
            decompressor: failingDecompressor,
            limits: DshLocalUsageScanLimits.production
        )
        XCTAssertEqual(counter.value, 1)

        // 坏文件不能进入“成功指纹”：index.json 里不得出现坏文件路径。
        let indexJSON = try XCTUnwrap(String(
            data: Data(contentsOf: cache.appendingPathComponent("index.json")),
            encoding: .utf8
        ))
        XCTAssertFalse(
            indexJSON.contains(badURL.path),
            "失败文件不得写入成功指纹，否则下一轮缓存命中会跳过重试"
        )

        // 文件无任何变化时的第二次扫描必须再次尝试坏文件（缓存不得命中）。
        let second = try DshLocalUsageScanner.performScanPure(
            sessionsRoot: sessionsRoot,
            cacheDir: cache,
            fileManager: FileManagerBox(),
            calendar: calendar,
            now: { base },
            decompressor: failingDecompressor,
            limits: DshLocalUsageScanLimits.production
        )
        XCTAssertEqual(counter.value, 2, "坏文件在下一轮扫描必须被重试")
        XCTAssertEqual(second.eventCount, 1, "好文件数据在重试轮次仍要保留")
    }

    func testDshSelectionPrefersNewestFilesWhenOverFileLimit() throws {
        // spec：文件数超限时必须按 mtime 最新优先，而不是路径字典序截断。
        let calendar = makeUTCGregorianCalendar()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-dsh-select-mtime-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 三个 session，inputTokens 与 mtime 一一对应：old=100, mid=200, new=300。
        let spec: [(sessionID: String, tokens: Int, mtime: Date)] = [
            ("session-old", 100, Date(timeIntervalSince1970: 1_600_000_000)),
            ("session-mid", 200, Date(timeIntervalSince1970: 1_650_000_000)),
            ("session-new", 300, Date(timeIntervalSince1970: 1_700_000_000))
        ]
        for entry in spec {
            let body = [
                #"{"type":"request/context","seq":1,"time":1700000000000,"data":{"provider":"deepseek-official","model":"deepseek-v4-flash"}}"#,
                #"{"type":"assistant/message","seq":2,"time":1700000001000,"data":{"turn":1,"step":0,"usage":{"inputTokens":\#(entry.tokens),"outputTokens":10}}}"#
            ].joined(separator: "\n") + "\n"
            let url = try writeSessionLog(root: sessionsRoot, sessionID: entry.sessionID, body: body)
            try FileManager.default.setAttributes(
                [.modificationDate: entry.mtime],
                ofItemAtPath: url.path
            )
        }

        let limits = DshLocalUsageScanLimits(
            maxSessionFiles: 2,
            maxTotalRawBytes: 1024 * 1024,
            maxJSONLLineBytes: 8 * 1024 * 1024,
            maxRecentSamples: 65_536
        )
        let selection = try DshLocalUsageScanner.selectSessionSnapshots(
            filePaths: try FileManagerBox().sessionFileURLs(in: sessionsRoot),
            fileManager: FileManagerBox(),
            limits: limits
        )

        XCTAssertEqual(selection.availableCount, 3)
        XCTAssertEqual(selection.snapshots.count, 2)
        XCTAssertEqual(
            selection.snapshots.map({ $0.url.deletingLastPathComponent().lastPathComponent }),
            ["session-new", "session-mid"],
            "超限时应保留 mtime 最新的文件"
        )
        XCTAssertFalse(selection.byteLimited)
    }

    func testDshSelectionAppliesByteCapAfterMtimeOrdering() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-dsh-select-bytes-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let spec: [(sessionID: String, mtime: Date)] = [
            ("session-old", Date(timeIntervalSince1970: 1_600_000_000)),
            ("session-new", Date(timeIntervalSince1970: 1_700_000_000))
        ]
        for entry in spec {
            let body = "{\"pad\":\"\(String(repeating: "x", count: 400))\"}\n"
            let url = try writeSessionLog(root: sessionsRoot, sessionID: entry.sessionID, body: body)
            try FileManager.default.setAttributes(
                [.modificationDate: entry.mtime],
                ofItemAtPath: url.path
            )
        }

        // 每个文件约 420 字节；字节上限设为 1 个文件的大小，
        // 只有最新的文件应当入选。
        let newSize = try FileManager.default.attributesOfItem(
            atPath: sessionsRoot.appendingPathComponent("--Project--/session-new/session.jsonl").path
        )[.size] as! Int
        let limits = DshLocalUsageScanLimits(
            maxSessionFiles: 100,
            maxTotalRawBytes: newSize,
            maxJSONLLineBytes: 8 * 1024 * 1024,
            maxRecentSamples: 65_536
        )
        let selection = try DshLocalUsageScanner.selectSessionSnapshots(
            filePaths: try FileManagerBox().sessionFileURLs(in: sessionsRoot),
            fileManager: FileManagerBox(),
            limits: limits
        )

        XCTAssertEqual(selection.availableCount, 2)
        XCTAssertEqual(selection.snapshots.count, 1)
        XCTAssertEqual(
            selection.snapshots.first?.url.deletingLastPathComponent().lastPathComponent,
            "session-new",
            "字节上限也应按 mtime 顺序截断，保留最新文件"
        )
        XCTAssertTrue(selection.byteLimited)
    }

    func testDshSelectionBreaksMtimeTiesByPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-dsh-select-tie-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sameTime = Date(timeIntervalSince1970: 1_700_000_000)
        for sessionID in ["session-b", "session-a", "session-c"] {
            let url = try writeSessionLog(root: sessionsRoot, sessionID: sessionID, body: "{\"x\":1}\n")
            try FileManager.default.setAttributes(
                [.modificationDate: sameTime],
                ofItemAtPath: url.path
            )
        }

        let limits = DshLocalUsageScanLimits(
            maxSessionFiles: 2,
            maxTotalRawBytes: 1024 * 1024,
            maxJSONLLineBytes: 8 * 1024 * 1024,
            maxRecentSamples: 65_536
        )
        let selection = try DshLocalUsageScanner.selectSessionSnapshots(
            filePaths: try FileManagerBox().sessionFileURLs(in: sessionsRoot),
            fileManager: FileManagerBox(),
            limits: limits
        )

        XCTAssertEqual(
            selection.snapshots.map({ $0.url.deletingLastPathComponent().lastPathComponent }),
            ["session-a", "session-b"],
            "同 mtime 时以路径升序作为稳定 tie-breaker"
        )
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
