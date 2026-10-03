import XCTest
@testable import LLM_monitor

/// agy（Antigravity CLI 分支）本地 transcript scanner 的回归护栏。
///
/// 全部用临时目录 fixture，禁止依赖本机真实 `~/.gemini` 数据。覆盖：
/// MODEL 行解析（thinking 分摊守恒）、模型名 join（log 命中 / 兜底）、
/// 主文件与分块去重、非 DONE 行跳过、fingerprint 缓存短路、预算截断，
/// 以及 agy 帧投影到 `.antigravity` 卡的命名空间。
final class AgyLocalUsageScannerTests: XCTestCase {

    // MARK: - fixture

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-scan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private struct Fixture {
        let brainRoot: URL
        let logDirectory: URL
        let cacheDir: URL
        let calendar: Calendar
        let limits: AgyLocalUsageScanLimits
    }

    private func makeFixture() -> Fixture {
        let root = makeTempDirectory()
        return Fixture(
            brainRoot: root.appendingPathComponent("brain", isDirectory: true),
            logDirectory: root.appendingPathComponent("log", isDirectory: true),
            cacheDir: root.appendingPathComponent("agy.json"),
            calendar: utcCalendar,
            limits: AgyLocalUsageScanLimits(
                maxSessionFiles: 64,
                maxTotalRawBytes: 16 * 1024 * 1024,
                maxJSONLLineBytes: 1024 * 1024,
                maxRecentSamples: 1_000,
                maxLogBytes: 1024 * 1024,
                readChunkBytes: 64 * 1024
            )
        )
    }

    private func writeSession(
        _ fixture: Fixture,
        sessionID: String,
        mainLines: [String],
        chunkLines: [String] = [],
        modifiedAt: Date = Date(timeIntervalSince1970: 1_773_576_000)
    ) {
        let logsDir = fixture.brainRoot
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent(".system_generated", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logsDir.appendingPathComponent("chunks/transcript", isDirectory: true),
            withIntermediateDirectories: true
        )
        write(lines: mainLines, to: logsDir.appendingPathComponent("transcript.jsonl"))
        if !chunkLines.isEmpty {
            write(lines: chunkLines, to: logsDir.appendingPathComponent("chunks/transcript/00000000.jsonl"))
        }
        try? FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: logsDir.appendingPathComponent("transcript.jsonl").path
        )
    }

    private func write(lines: [String], to url: URL) {
        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    /// 构造一条 agy transcript 行（紧凑 JSON，与真实落盘格式一致）。
    private func agyLine(
        source: String = "MODEL",
        type: String = "GENERIC",
        status: String = "DONE",
        createdAt: String,
        stepIndex: Int? = 1,
        input: Int? = 100,
        cacheRead: Int? = 20,
        output: Int? = 50,
        thinking: String? = nil,
        content: String? = "answer"
    ) -> String {
        var object: [String: Any] = [
            "source": source,
            "type": type,
            "status": status,
            "created_at": createdAt
        ]
        if let stepIndex { object["step_index"] = stepIndex }
        if let input { object["input_tokens"] = input }
        if let cacheRead { object["cache_read_tokens"] = cacheRead }
        if let output { object["output_tokens"] = output }
        if let thinking { object["thinking"] = thinking }
        if let content { object["content"] = content }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func scan(
        _ fixture: Fixture,
        forceFull: Bool = false,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_773_576_000) },
        snapshotReader: ((URL) throws -> AgyLogFileSnapshot)? = nil
    ) throws -> AgyLocalUsage {
        try AgyLocalUsageScanner.performScanPure(
            brainRoot: fixture.brainRoot,
            logDirectory: fixture.logDirectory,
            cacheDir: fixture.cacheDir,
            fileManager: FileManagerBox(),
            calendar: fixture.calendar,
            // 缺省 2026-03-15 12:00 UTC：与 fixture 行同一天（7 天窗口的最后
            // 一天），断言取 dailyTokenUsage.last 即活动日桶。
            now: now,
            limits: fixture.limits,
            forceFull: forceFull,
            snapshotReader: snapshotReader
        )
    }

    /// 在同一临时目录上替换预算（Fixture 字段为 let，用拷贝重建）。
    private func withLimits(_ base: Fixture, _ limits: AgyLocalUsageScanLimits) -> Fixture {
        Fixture(
            brainRoot: base.brainRoot,
            logDirectory: base.logDirectory,
            cacheDir: base.cacheDir,
            calendar: base.calendar,
            limits: limits
        )
    }

    /// 本地时区的 cli log 文件名（join 测试与机器时区无关）。
    private func writeCliLog(
        _ fixture: Fixture,
        startedAt: Date,
        model: String
    ) {
        try? FileManager.default.createDirectory(
            at: fixture.logDirectory,
            withIntermediateDirectories: true
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "cli-\(formatter.string(from: startedAt)).log"
        let body = """
        I1004 00:00:00.000000       1 server.go:1612] Starting language server process with pid 1
        I1004 00:00:01.000000       1 model_resolver.go:93] Resolving model \(model)
        """
        try? Data(body.utf8).write(
            to: fixture.logDirectory.appendingPathComponent(name),
            options: .atomic
        )
    }

    // MARK: - MODEL 行解析与 thinking 分摊守恒

    func testModelRowWithThinkingSplitsOutputConservatively() throws {
        let fixture = makeFixture()
        // output=100，thinking 300 字符 / 可见 100 字符 → reasoning 占 75%。
        writeSession(
            fixture,
            sessionID: "session-a",
            mainLines: [
                agyLine(
                    createdAt: "2026-03-15T10:00:00Z",
                    input: 1_000,
                    cacheRead: 200,
                    output: 100,
                    thinking: String(repeating: "思", count: 300),
                    content: String(repeating: "答", count: 100)
                )
            ]
        )

        let result = try scan(fixture)

        XCTAssertEqual(result.eventCount, 1)
        XCTAssertEqual(result.sessionCount, 1)
        let sample = try XCTUnwrap(result.recentSamples.first)
        // 守恒：reasoning + output == 账面 output_tokens。
        XCTAssertEqual(
            sample.reasoningOutputTokens + sample.outputTokens, 100,
            "分摊必须守恒：reasoning + output == 原始 output_tokens"
        )
        XCTAssertEqual(sample.reasoningOutputTokens, 75)
        XCTAssertEqual(sample.outputTokens, 25)
        // sample 层语义：inputTokens 是 cache-inclusive 总输入。
        XCTAssertEqual(sample.inputTokens, 1_200)
        XCTAssertEqual(sample.cachedInputTokens, 200)
        XCTAssertEqual(sample.promptID, "session-a:step:1")
        // 日聚合同样守恒，input 桶是未缓存输入。
        let day = try XCTUnwrap(result.dailyTokenUsage.last)
        XCTAssertEqual(day.inputTokens, 1_000)
        XCTAssertEqual(day.cacheReadTokens, 200)
        XCTAssertEqual(day.outputTokens, 25)
        XCTAssertEqual(day.reasoningTokens, 75)
        XCTAssertEqual(day.totalTokens, 1_300)
        XCTAssertEqual(day.rounds, 1)
        XCTAssertEqual(day.turns, 1)
        XCTAssertTrue(sample.promptID.hasPrefix("session-a"), "scanner 落盘裸 promptID，agy: 前缀由帧构造施加")
    }

    func testRowWithoutThinkingRecordsAllOutput() throws {
        let fixture = makeFixture()
        writeSession(
            fixture,
            sessionID: "session-a",
            mainLines: [
                agyLine(createdAt: "2026-03-15T10:00:00Z", input: 10, cacheRead: 0, output: 50, thinking: nil)
            ]
        )

        let result = try scan(fixture)

        let sample = try XCTUnwrap(result.recentSamples.first)
        XCTAssertEqual(sample.outputTokens, 50, "无 thinking 时 output 全额入可见输出")
        XCTAssertEqual(sample.reasoningOutputTokens, 0)
        let day = try XCTUnwrap(result.dailyTokenUsage.last)
        XCTAssertEqual(day.outputTokens, 50)
        XCTAssertEqual(day.reasoningTokens, 0)
    }

    // MARK: - 非 DONE / 未计量行

    func testNonDoneAndTokenlessRowsAreSkipped() throws {
        let fixture = makeFixture()
        writeSession(
            fixture,
            sessionID: "session-a",
            mainLines: [
                agyLine(status: "RUNNING", createdAt: "2026-03-15T10:00:00Z"),
                // DONE 但无 token 字段：未计量响应，整行跳过。
                agyLine(createdAt: "2026-03-15T10:00:01Z", input: nil, cacheRead: nil, output: nil),
                agyLine(createdAt: "2026-03-15T10:00:02Z", input: 10, cacheRead: 0, output: 5)
            ]
        )

        let result = try scan(fixture)

        XCTAssertEqual(result.eventCount, 1, "只有带 token 的 DONE MODEL 行产出样本")
        XCTAssertEqual(result.dailyTokenUsage.last?.rounds, 1)
    }

    // MARK: - 主文件与分块去重

    func testChunksAndMainFileRowsDedupe() throws {
        let fixture = makeFixture()
        let shared = agyLine(createdAt: "2026-03-15T10:00:00Z", stepIndex: 1, input: 10, cacheRead: 0, output: 5)
        writeSession(
            fixture,
            sessionID: "session-a",
            mainLines: [
                agyLine(createdAt: "2026-03-15T10:00:00Z", stepIndex: 1, input: 10, cacheRead: 0, output: 5),
                agyLine(createdAt: "2026-03-15T10:00:01Z", stepIndex: 2, input: 10, cacheRead: 0, output: 5)
            ],
            // 分块与主文件重叠一行（轮转镜像）+ 一行独有（轮转后旧行只在分块）。
            chunkLines: [
                agyLine(createdAt: "2026-03-15T10:00:00Z", stepIndex: 1, input: 10, cacheRead: 0, output: 5),
                agyLine(createdAt: "2026-03-15T10:00:02Z", stepIndex: 3, input: 10, cacheRead: 0, output: 5)
            ]
        )

        let result = try scan(fixture)

        XCTAssertEqual(
            result.eventCount, 3,
            "主文件 + 分块的并集去重后应恰好 3 个样本，不重不漏"
        )
        XCTAssertEqual(result.dailyTokenUsage.last?.rounds, 3)
        XCTAssertEqual(result.dailyTokenUsage.last?.totalTokens, 3 * 15)
    }

    // MARK: - 模型名 join

    func testModelJoinUsesLatestLogStartedBeforeRow() throws {
        let fixture = makeFixture()
        // T0 < T1 < T2 < T3（UTC）。log 文件名是本地时间，由 Date 派生保证
        // 与机器时区无关。
        let t0 = Date(timeIntervalSince1970: 1_773_540_000)
        let t1 = t0.addingTimeInterval(3_600)
        let t2 = t1.addingTimeInterval(3_600)
        let t3 = t2.addingTimeInterval(3_600)
        writeCliLog(fixture, startedAt: t1, model: "gemini-3-pro")
        writeCliLog(fixture, startedAt: t2, model: "gemini-3.1-pro-high")
        writeSession(fixture, sessionID: "session-a", mainLines: [
            agyLine(createdAt: iso(t0), stepIndex: 1, input: 1, cacheRead: 0, output: 1),
            agyLine(createdAt: iso(Date(timeIntervalSince1970: t1.timeIntervalSince1970 + 60)), stepIndex: 2, input: 1, cacheRead: 0, output: 1),
            agyLine(createdAt: iso(Date(timeIntervalSince1970: t2.timeIntervalSince1970 + 60)), stepIndex: 3, input: 1, cacheRead: 0, output: 1)
        ])
        // t3 之后的第二会话行：命中 t2 的 log。
        writeSession(fixture, sessionID: "session-b", mainLines: [
            agyLine(createdAt: iso(t3), stepIndex: 1, input: 1, cacheRead: 0, output: 1)
        ])

        let result = try scan(fixture)

        let modelsBySession = Dictionary(grouping: result.recentSamples) { sample in
            String(sample.promptID.split(separator: ":").first ?? "")
        }
        XCTAssertEqual(
            modelsBySession["session-a"]?.first { $0.promptID == "session-a:step:1" }?.modelName,
            "gemini-3-pro",
            "早于全部 log 的行走最早已知模型兜底"
        )
        XCTAssertEqual(
            modelsBySession["session-a"]?.first { $0.promptID == "session-a:step:2" }?.modelName,
            "gemini-3-pro",
            "取开始时间 ≤ created_at 的最近一个 log"
        )
        XCTAssertEqual(
            modelsBySession["session-a"]?.first { $0.promptID == "session-a:step:3" }?.modelName,
            "gemini-3.1-pro-high"
        )
        XCTAssertEqual(
            modelsBySession["session-b"]?.first?.modelName,
            "gemini-3.1-pro-high"
        )
        XCTAssertEqual(result.models.sorted(), ["gemini-3-pro", "gemini-3.1-pro-high"])
    }

    func testMissingLogDirectoryFallsBackToMissingModelName() throws {
        let fixture = makeFixture()
        writeSession(
            fixture,
            sessionID: "session-a",
            mainLines: [agyLine(createdAt: "2026-03-15T10:00:00Z", input: 1, cacheRead: 0, output: 1)]
        )

        let result = try scan(fixture)

        XCTAssertNil(result.recentSamples.first?.modelName, "log 目录缺失时全部走兜底，扫描不失败")
        XCTAssertTrue(result.models.isEmpty)
        XCTAssertNil(result.isPartial)
    }

    // MARK: - fingerprint 缓存短路

    func testUnchangedFingerprintsShortCircuitToCachedSnapshot() throws {
        let fixture = makeFixture()
        writeSession(
            fixture,
            sessionID: "session-a",
            mainLines: [agyLine(createdAt: "2026-03-15T10:00:00Z", input: 10, cacheRead: 0, output: 5)]
        )
        let first = try scan(fixture)

        // 文件内容被改写，但注入的 snapshotReader 仍返回原指纹 → 必须命中缓存，
        // 不重新解析（改写后的行不会出现在结果里）。
        let snapshots = try AgyLocalUsageScanner.transcriptFileURLs(
            in: fixture.brainRoot,
            fileManager: FileManagerBox()
        ).map { try AgyLogFileSnapshot(url: $0, fileManager: FileManagerBox()) }
        write(lines: [agyLine(createdAt: "2026-03-15T11:00:00Z", stepIndex: 9, input: 999, cacheRead: 0, output: 999)],
              to: fixture.brainRoot
                .appendingPathComponent("session-a/.system_generated/logs/transcript.jsonl"))
        let second = try scan(fixture) { _ in
            try XCTUnwrap(snapshots.first)
        }

        XCTAssertNil(second.isPartial)
        XCTAssertEqual(second, first, "指纹未变时复用缓存快照，不受文件内容变化影响")
        XCTAssertEqual(second.eventCount, 1)
    }

    // MARK: - stat 失败兜底（last-good + 窗口重算）

    func testStatFailureKeepsLastGoodRebasesWindowAndAdvancesScannedAt() throws {
        let fixture = makeFixture()
        writeSession(
            fixture,
            sessionID: "session-a",
            mainLines: [agyLine(createdAt: "2026-03-15T10:00:00Z", input: 10, cacheRead: 0, output: 5)]
        )
        // 第一拍（2026-03-15 12:00 UTC）用真实 snapshotReader 落缓存。
        let base = Date(timeIntervalSince1970: 1_773_576_000)
        let first = try scan(fixture, now: { base })
        let committed = try Data(contentsOf: fixture.cacheDir)

        // 跨两个午夜重扫（03-17，数据日仍在 7 天窗口内）：全部 stat 失败 →
        // 返回 partial，last-good 日桶保留且窗口已按当前时间重算，不被冻结。
        let later = base.addingTimeInterval(2 * 86_400)
        let second = try scan(
            fixture,
            now: { later },
            snapshotReader: { _ in throw CocoaError(.fileReadNoPermission) }
        )

        XCTAssertNil(first.isPartial)
        XCTAssertEqual(second.isPartial, true, "stat 失败必须按 partial 暴露")
        // 活动日桶按 dayStart 定位（窗口内每天有补零桶，last 不一定是活动日）。
        let activityDay = base.addingTimeInterval(-43_200) // 2026-03-15 00:00 UTC startOfDay
        let firstBucket = try XCTUnwrap(first.dailyTokenUsage.first { $0.dayStart == activityDay })
        let secondBucket = try XCTUnwrap(second.dailyTokenUsage.first { $0.dayStart == activityDay })
        XCTAssertEqual(
            secondBucket, firstBucket,
            "last-good 活动日桶保留（兜底路径已 rebase 到当前 7 天窗口，数据日仍在窗口内）"
        )
        // 窗口平移的可观测证据：filterLast7Days 为窗口内每天补零值桶，窗口
        // 起点随扫掠时间推进 2 天，证明兜底视图确实重算了窗口而非原样返回
        // 冻结快照（修复前跨午夜日桶会被冻结）。
        let firstWindowStart = try XCTUnwrap(first.dailyTokenUsage.first?.dayStart)
        let secondWindowStart = try XCTUnwrap(second.dailyTokenUsage.first?.dayStart)
        XCTAssertEqual(
            secondWindowStart.timeIntervalSince(firstWindowStart), 2 * 86_400,
            "7 天窗口起点必须随当前时间平移（窗口重算）"
        )
        XCTAssertEqual(second.scannedAt, later, "兜底视图的 scannedAt 推进到本轮扫描时刻")
        XCTAssertEqual(
            try Data(contentsOf: fixture.cacheDir), committed,
            "partial 永不入盘：index 字节保持不变"
        )
    }

    // MARK: - log-only 变化解除指纹短路

    func testLogOnlyChangeRebuildsCacheAndJoinsModelNames() throws {
        let fixture = makeFixture()
        writeSession(
            fixture,
            sessionID: "session-a",
            mainLines: [agyLine(createdAt: "2026-03-15T10:00:00Z", input: 1, cacheRead: 0, output: 1)]
        )
        let first = try scan(fixture)
        XCTAssertNil(first.recentSamples.first?.modelName, "无 log 时模型名缺失")
        XCTAssertTrue(first.models.isEmpty)

        // transcript 指纹不变，只新增 cli log：时间线签名变化必须使指纹短路
        // 失效，重聚合后模型名 join 成功（否则旧缓存永久吞掉模型名）。
        writeCliLog(fixture, startedAt: Date(timeIntervalSince1970: 1_773_500_000), model: "gemini-3-pro")
        let second = try scan(fixture)

        XCTAssertNil(second.isPartial)
        XCTAssertEqual(second.recentSamples.first?.modelName, "gemini-3-pro", "log-only 变化触发重聚合，模型名刷新")
        XCTAssertEqual(second.models, ["gemini-3-pro"])
        XCTAssertEqual(second.eventCount, 1)
        // 缓存被重建：index 落盘非空时间线签名，供后续无变化扫描继续短路。
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cacheDir)) as? [String: Any]
        XCTAssertNotNil(index?["timelineSignature"] as? String, "时间线签名必须写入缓存 index")
    }

    // MARK: - 预算截断

    func testSessionFileBudgetTruncatesOldestAndMarksTruncated() throws {
        var fixture = makeFixture()
        fixture = Fixture(
            brainRoot: fixture.brainRoot,
            logDirectory: fixture.logDirectory,
            cacheDir: fixture.cacheDir,
            calendar: fixture.calendar,
            limits: AgyLocalUsageScanLimits(
                maxSessionFiles: 1,
                maxTotalRawBytes: 16 * 1024 * 1024,
                maxJSONLLineBytes: 1024 * 1024,
                maxRecentSamples: 1_000,
                maxLogBytes: 1024 * 1024
            )
        )
        let base = Date(timeIntervalSince1970: 1_773_576_000)
        writeSession(
            fixture, sessionID: "session-old",
            mainLines: [agyLine(createdAt: "2026-03-15T10:00:00Z", input: 10, cacheRead: 0, output: 5)],
            modifiedAt: base
        )
        writeSession(
            fixture, sessionID: "session-new",
            mainLines: [agyLine(createdAt: "2026-03-15T10:00:01Z", input: 20, cacheRead: 0, output: 10)],
            modifiedAt: base.addingTimeInterval(60)
        )

        let result = try scan(fixture)

        XCTAssertEqual(result.isTruncated, true, "文件数预算挤出最旧 session 时必须置位 isTruncated")
        XCTAssertEqual(result.sessionCount, 1)
        XCTAssertEqual(result.eventCount, 1)
        XCTAssertEqual(result.dailyTokenUsage.last?.totalTokens, 30, "保留的是 mtime 最新的 session")
    }

    func testByteBudgetTruncatesKeepsNewestFileData() throws {
        // 每个文件约 480 字节（含 300 字节 ASCII content）：600 字节预算
        // 容得下 1 个、容不下 2 个文件。
        let fixture = withLimits(
            makeFixture(),
            AgyLocalUsageScanLimits(
                maxSessionFiles: 64,
                maxTotalRawBytes: 600,
                maxJSONLLineBytes: 1024 * 1024,
                maxRecentSamples: 1_000,
                maxLogBytes: 1024 * 1024
            )
        )
        let mtime = Date(timeIntervalSince1970: 1_773_576_000)
        writeSession(
            fixture, sessionID: "session-old",
            mainLines: [agyLine(createdAt: "2026-03-15T10:00:00Z", input: 10, cacheRead: 0, output: 5, content: String(repeating: "a", count: 300))],
            modifiedAt: mtime
        )
        writeSession(
            fixture, sessionID: "session-new",
            mainLines: [agyLine(createdAt: "2026-03-15T10:00:01Z", input: 20, cacheRead: 0, output: 10, content: String(repeating: "b", count: 300))],
            modifiedAt: mtime.addingTimeInterval(60)
        )

        let result = try scan(fixture)

        XCTAssertEqual(result.isTruncated, true, "字节预算挤出旧文件时必须置位 isTruncated")
        XCTAssertEqual(result.sessionCount, 1)
        XCTAssertEqual(result.eventCount, 1)
        XCTAssertEqual(result.dailyTokenUsage.last?.totalTokens, 30, "只保留 mtime 最新的文件数据")
    }

    // MARK: - 行数熔断

    func testLineBudgetBreachIsolatesFileAndKeepsFingerprintOutOfCache() throws {
        // maxSessionFiles=1 → 单文件行预算 10_000 行。
        let fixture = withLimits(
            makeFixture(),
            AgyLocalUsageScanLimits(
                maxSessionFiles: 1,
                maxTotalRawBytes: 16 * 1024 * 1024,
                maxJSONLLineBytes: 1024 * 1024,
                maxRecentSamples: 1_000,
                maxLogBytes: 1024 * 1024
            )
        )
        var lines: [String] = []
        for index in 0..<5 {
            lines.append(agyLine(
                createdAt: iso(Date(timeIntervalSince1970: 1_773_576_000 - 600 + TimeInterval(index))),
                stepIndex: index + 1,
                input: 7,
                cacheRead: 0,
                output: 1
            ))
        }
        // 预算线之后还有大量 filler 行：熔断必须把文件按失败隔离，而不是
        // 静默把前半截结果当完整数据连同完整指纹写入缓存。
        lines.append(contentsOf: Array(repeating: #"{"source":"USER","note":"filler"}"#, count: 10_020))
        writeSession(fixture, sessionID: "session-a", mainLines: lines)

        let first = try scan(fixture)

        XCTAssertEqual(first.isPartial, true, "行数熔断的文件必须按失败隔离（partial）")
        XCTAssertEqual(
            first.eventCount, 0,
            "熔断抛错后整文件隔离、前缀样本随之丢弃：半结果既不进视图也不进缓存，下一轮整体重试"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.cacheDir.path),
            "失败文件指纹不入缓存：index 整体不落盘"
        )

        // 第二拍无缓存可短路 → 必须重新聚合该文件（仍 partial，指纹依旧不入缓存）。
        let second = try scan(fixture)
        XCTAssertEqual(second.isPartial, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheDir.path))
    }

    // MARK: - 超长行丢弃与恢复

    func testOversizedModelLineDroppedAndFollowingNormalLineParses() throws {
        let fixture = withLimits(
            makeFixture(),
            AgyLocalUsageScanLimits(
                maxSessionFiles: 64,
                maxTotalRawBytes: 16 * 1024 * 1024,
                maxJSONLLineBytes: 256,
                maxRecentSamples: 1_000,
                maxLogBytes: 1024 * 1024
            )
        )
        writeSession(
            fixture, sessionID: "session-a",
            mainLines: [
                // > 256 字节且带 MODEL 标记：整行丢弃，不产出样本。
                agyLine(createdAt: "2026-03-15T10:00:00Z", input: 999, cacheRead: 0, output: 999, content: String(repeating: "x", count: 600)),
                // 其后的正常 MODEL 行（< 256 字节）仍解析成功。
                agyLine(createdAt: "2026-03-15T10:00:01Z", stepIndex: 2, input: 7, cacheRead: 0, output: 1)
            ]
        )

        let result = try scan(fixture)

        XCTAssertEqual(result.eventCount, 1, "超长 MODEL 行被丢弃，其后的正常行恢复解析")
        let sample = try XCTUnwrap(result.recentSamples.first)
        XCTAssertEqual(sample.inputTokens, 7, "解析成功的是超长行之后的那条正常行")
        XCTAssertEqual(sample.outputTokens, 1)
        XCTAssertEqual(result.dailyTokenUsage.last?.totalTokens, 8)
    }

    // MARK: - 结果相等语义

    func testEqualityExcludesScanMetadataButIncludesTruncation() throws {
        let day = Date(timeIntervalSince1970: 1_773_576_000)
        func make(scannedAt: Date?, isPartial: Bool?, isTruncated: Bool?) -> AgyLocalUsage {
            AgyLocalUsage(
                dailyTokenUsage: [AgyDailyUsage(
                    dayStart: day, inputTokens: 1, outputTokens: 1,
                    cacheReadTokens: 0, cacheWriteTokens: 0,
                    reasoningTokens: 0, totalTokens: 2, turns: 1, rounds: 1
                )],
                models: ["gemini-3-pro"],
                recentSamples: [],
                sessionsRoot: "/tmp/brain",
                sessionCount: 1,
                eventCount: 1,
                scannedAt: scannedAt,
                isPartial: isPartial,
                isTruncated: isTruncated
            )
        }
        let base = make(scannedAt: day, isPartial: nil, isTruncated: nil)

        XCTAssertEqual(
            base,
            make(scannedAt: day.addingTimeInterval(60), isPartial: true, isTruncated: nil),
            "scannedAt 与 isPartial 出相等（扫描元数据走 freshness 旁路通道）"
        )
        XCTAssertNotEqual(
            base,
            make(scannedAt: day, isPartial: nil, isTruncated: true),
            "isTruncated 入相等（截断改变数字口径，必须能重新发布 UI）"
        )
    }

    // MARK: - 投影接入（.antigravity 卡 + agy 命名空间）

    func testAgyFramesProjectOntoAntigravityCardWithNamespace() throws {
        let day = Date(timeIntervalSince1970: 1_773_576_000)
        let daily = AgyDailyUsage(
            dayStart: day, inputTokens: 1_000, outputTokens: 60,
            cacheReadTokens: 200, cacheWriteTokens: 0,
            reasoningTokens: 40, totalTokens: 1_300, turns: 2, rounds: 2
        )
        let sample = LocalTokenUsageSample(
            completedAt: day.addingTimeInterval(3_600),
            modelName: "gemini-3.1-pro-high",
            promptID: "session-a:step:1",
            inputTokens: 1_200,
            cachedInputTokens: 200,
            outputTokens: 30,
            reasoningOutputTokens: 30,
            sourceProviderID: ClientID.agy
        )
        var status = ProviderStatus(
            id: ProviderKind.antigravity.providerID, displayName: "Antigravity",
            kind: .antigravity, iconSystemName: "circle", accentColor: .antigravity,
            refreshIntervalSeconds: 300, state: .ready
        )
        status.agyUsage = AgyLocalUsage(
            dailyTokenUsage: [daily],
            models: ["gemini-3.1-pro-high"],
            recentSamples: [sample],
            sessionsRoot: "/tmp/brain",
            sessionCount: 1,
            eventCount: 1,
            scannedAt: day
        )

        let projection = status.usageProjection(for: nil)
        let agy = try XCTUnwrap(
            projection.contributions.first { $0.clientID == ClientID.agy },
            "agy 快照必须成为 .antigravity 卡的独立贡献行"
        )
        XCTAssertEqual(agy.dailyTokenUsage.first?.input, 1_000, "daily input 桶是未缓存输入")
        XCTAssertEqual(agy.dailyTokenUsage.first?.reasoning, 40)
        XCTAssertEqual(agy.recentSamples.first?.promptID, "agy:session-a:step:1", "投影层补单层 agy: 命名空间")
        XCTAssertNil(
            projection.contributions.first { $0.clientID == ClientID.antigravity },
            "未提供 antigravity native 快照时不产生该客户端的贡献行"
        )
        // per-model 四桶由内核按样本模型名分组；这里只锁 agy 贡献行在位。
        XCTAssertTrue(agy.hasActivity)
    }

    func testUnknownModelNameBucketsUnderProjectionConstant() throws {
        let day = Date(timeIntervalSince1970: 1_773_576_000)
        let sample = LocalTokenUsageSample(
            completedAt: day,
            modelName: nil,
            promptID: "session-a:step:1",
            inputTokens: 10,
            cachedInputTokens: 0,
            outputTokens: 5,
            reasoningOutputTokens: 0
        )
        var status = ProviderStatus(
            id: ProviderKind.antigravity.providerID, displayName: "Antigravity",
            kind: .antigravity, iconSystemName: "circle", accentColor: .antigravity,
            refreshIntervalSeconds: 300, state: .ready
        )
        status.agyUsage = AgyLocalUsage(
            dailyTokenUsage: [],
            models: [],
            recentSamples: [sample],
            sessionsRoot: "/tmp/brain",
            sessionCount: 1,
            eventCount: 1,
            scannedAt: day
        )

        let frames = try XCTUnwrap(ProviderStatus.usageFrameExtractors[.antigravity])
            .flatMap { $0(status, nil) }
        let agyFrame = try XCTUnwrap(frames.first { $0.clientID == ClientID.agy })
        XCTAssertEqual(agyFrame.quotaProviderID, QuotaProviderID.antigravity, "agy 帧自带 .antigravity 归属")
        let projections = UsageProjectionKernel.project(frames: frames, bindings: status.clientBindings)
        let projection = try XCTUnwrap(projections.first { $0.clientID == ClientID.agy })
        XCTAssertTrue(
            projection.perModel.keys.contains(ProviderHarnessProjection.unknownModelName),
            "无模型名的样本按 unknownModelName 分组（与现有兜底口径一致）"
        )
    }
}
