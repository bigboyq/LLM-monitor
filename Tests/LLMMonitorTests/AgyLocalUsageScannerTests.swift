import XCTest
import SQLite3
@testable import LLM_monitor

/// agy（Antigravity CLI 分支）本地 transcript scanner 的回归护栏。
///
/// 全部用临时目录 fixture，禁止依赖本机真实 `~/.gemini` 数据。覆盖：
/// MODEL 行解析（thinking 分摊守恒）、模型名 join（log 命中 / 兜底）、
/// 主文件与分块去重、非 DONE 行跳过、fingerprint 缓存短路、预算截断、
/// 单次调用时长（方案 A conversations .db 真值 / 方案 B GENERIC 后继降级），
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
        content: String? = "answer",
        toolCalls: [[String: Any]]? = nil
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
        if let toolCalls { object["tool_calls"] = toolCalls }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - 时长 fixture（方案 A .db / 方案 B GENERIC）

    /// t0 = 2026-03-15T10:00:00Z（与缺省扫描时刻同一天，7 天窗口内）。
    private let t0 = Date(timeIntervalSince1970: 1_773_568_800)

    private func varintBytes(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    /// steps.metadata protobuf 信封：field 1 = 发起 Timestamp、field 7 = 流式
    /// 完成 Timestamp（field 1 键 0x0A、field 7 键 0x3A；与
    /// `AntigravityStepTimestampTests` 同一款 varint 构造）。
    private func stepMetadata(
        startSeconds: UInt64,
        startNanos: UInt64 = 0,
        endSeconds: UInt64,
        endNanos: UInt64 = 0
    ) -> Data {
        func timestamp(_ seconds: UInt64, _ nanos: UInt64) -> [UInt8] {
            [0x08] + varintBytes(seconds) + [0x10] + varintBytes(nanos)
        }
        let start = timestamp(startSeconds, startNanos)
        let end = timestamp(endSeconds, endNanos)
        return Data([0x0A, UInt8(start.count)] + start + [0x3A, UInt8(end.count)] + end)
    }

    /// 建一个 `conversations/<sessionID>.db`（steps 表形态与真实 schema 的读取
    /// 面一致：idx / step_type / metadata BLOB）。
    @discardableResult
    private func writeConversationDB(
        _ fixture: Fixture,
        sessionID: String,
        steps: [(idx: Int, stepType: Int, metadata: Data?)]
    ) throws -> URL {
        let conversations = fixture.brainRoot.deletingLastPathComponent()
            .appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        let dbURL = conversations.appendingPathComponent("\(sessionID).db")

        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                dbURL.path,
                &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                nil
            ),
            SQLITE_OK
        )
        guard let database else {
            XCTFail("failed to create SQLite fixture")
            return dbURL
        }
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE TABLE steps (idx INTEGER PRIMARY KEY, step_type INTEGER, metadata BLOB);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(database, "INSERT INTO steps VALUES (?, ?, ?);", -1, &statement, nil),
            SQLITE_OK
        )
        guard let statement else {
            XCTFail("failed to prepare SQLite fixture insert")
            return dbURL
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(Int(-1), to: sqlite3_destructor_type.self)
        for step in steps {
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, Int64(step.idx))
            sqlite3_bind_int64(statement, 2, Int64(step.stepType))
            if let metadata = step.metadata {
                metadata.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(metadata.count), transient)
                }
            } else {
                sqlite3_bind_null(statement, 3)
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
        return dbURL
    }

    private func sample(_ result: AgyLocalUsage, _ promptID: String) throws -> LocalTokenUsageSample {
        try XCTUnwrap(result.recentSamples.first { $0.promptID == promptID }, "缺少样本 \(promptID)")
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

    // MARK: - 单次调用时长（方案 A .db 真值 + 方案 B GENERIC 后继降级）

    /// reader 层：steps.metadata 双 Timestamp（field 1 发起 / field 7 流式完成）
    /// 的纳秒差解析。
    func testStepTimestampReaderParsesStreamDurationFields() {
        let metadata = stepMetadata(startSeconds: UInt64(t0.timeIntervalSince1970), endSeconds: UInt64(t0.timeIntervalSince1970) + 12, endNanos: 250_000_000)
        let nanos = AntigravityStepTimestampReader.streamDurationNanosForTest(from: metadata)
        XCTAssertEqual(nanos ?? 0, 12_250_000_000, accuracy: 0)

        // field 7 缺失（旧 schema 只有发起时刻）→ nil，不产出时长。
        let startMessage: [UInt8] = [0x08] + varintBytes(UInt64(t0.timeIntervalSince1970))
        let startOnly = Data([0x0A, UInt8(startMessage.count)] + startMessage)
        XCTAssertNil(AntigravityStepTimestampReader.streamDurationNanosForTest(from: startOnly))
        // 坏 blob → nil。
        XCTAssertNil(AntigravityStepTimestampReader.streamDurationNanosForTest(from: Data([0x08, 0x01])))
    }

    /// 方案 A：conversations/<session>.db 的 (step_type=15, idx==step_index) 映射
    /// 直接给出真值时长，且优先于方案 B（同 step 存在 GENERIC 标记也不覆盖）；
    /// .db 无匹配 idx 的计量行保持 nil。
    func testConversationDBProvidesStepDurationAndTakesPrecedence() throws {
        let fixture = makeFixture()
        let epoch = UInt64(t0.timeIntervalSince1970)
        writeSession(fixture, sessionID: "session-a", mainLines: [
            agyLine(
                type: "PLANNER_RESPONSE", createdAt: iso(t0), stepIndex: 1,
                input: 10, cacheRead: 0, output: 5,
                toolCalls: [["name": "read_file", "args": "{}"]]
            ),
            // 方案 B 标记（若被误用会得到 99s）：GENERIC 子工具步骤创建行。
            agyLine(type: "GENERIC", status: "RUNNING", createdAt: iso(t0.addingTimeInterval(99)), stepIndex: 2, input: nil, cacheRead: nil, output: nil, content: nil),
            // 纯文本终答：.db 无 idx=4 行、也无 tool_calls → 时长 nil。
            agyLine(type: "PLANNER_RESPONSE", createdAt: iso(t0.addingTimeInterval(120)), stepIndex: 4, input: 7, cacheRead: 0, output: 1, content: "done")
        ])
        try writeConversationDB(fixture, sessionID: "session-a", steps: [
            // 真值：f7 − f1 = 12.25s（纳秒精度）。
            (idx: 1, stepType: 15, metadata: stepMetadata(startSeconds: epoch, endSeconds: epoch + 12, endNanos: 250_000_000)),
            // 噪声：step_type 不是 15，查询必须过滤。
            (idx: 2, stepType: 99, metadata: stepMetadata(startSeconds: epoch, endSeconds: epoch + 999)),
            // 坏 metadata（缺 field 7）→ 不进映射。
            (idx: 5, stepType: 15, metadata: Data([0x0A, 0x05, 0x08] + varintBytes(epoch)))
        ])

        let result = try scan(fixture)

        let withDB = try sample(result, "session-a:step:1")
        XCTAssertEqual(withDB.durationSeconds ?? 0, 12.25, accuracy: 0.0001, "方案 A 真值优先于方案 B")
        let unmapped = try sample(result, "session-a:step:4")
        XCTAssertNil(unmapped.durationSeconds, ".db 无匹配 idx 且无 tool_calls → 保持 nil")
        XCTAssertEqual(result.eventCount, 2)
    }

    /// 方案 A 时长出 (0, 3600] 有效域 → 视为无效，落回方案 B 或保持 nil。
    func testPlanADurationValidityDomain() throws {
        let fixture = makeFixture()
        let epoch = UInt64(t0.timeIntervalSince1970)
        writeSession(fixture, sessionID: "session-a", mainLines: [
            agyLine(type: "PLANNER_RESPONSE", createdAt: iso(t0), stepIndex: 1, input: 1, cacheRead: 0, output: 1),
            agyLine(type: "PLANNER_RESPONSE", createdAt: iso(t0.addingTimeInterval(60)), stepIndex: 2, input: 1, cacheRead: 0, output: 1)
        ])
        try writeConversationDB(fixture, sessionID: "session-a", steps: [
            // 恰好 3600s：闭区间上界，有效。
            (idx: 1, stepType: 15, metadata: stepMetadata(startSeconds: epoch, endSeconds: epoch + 3_600)),
            // 3600s + 1ns：超界，无效。
            (idx: 2, stepType: 15, metadata: stepMetadata(startSeconds: epoch, endSeconds: epoch + 3_600, endNanos: 1))
        ])

        let result = try scan(fixture)

        XCTAssertEqual(
            try sample(result, "session-a:step:1").durationSeconds ?? 0, 3_600, accuracy: 0.0001,
            "(0, 3600] 闭区间上界有效"
        )
        XCTAssertNil(
            try sample(result, "session-a:step:2").durationSeconds,
            "超出 3600s 的 .db 时长必须被丢弃"
        )
    }

    /// 方案 B：.db 缺失时带 tool_calls 的 PLANNER_RESPONSE 用同会话首个
    /// step_index 更大的 MODEL:GENERIC 行结算（近似真值）；纯文本终答
    /// （无 tool_calls）不结算，保持 nil。
    func testMissingConversationDBUsesGenericSuccessorFallback() throws {
        let fixture = makeFixture()
        writeSession(fixture, sessionID: "session-a", mainLines: [
            agyLine(
                type: "PLANNER_RESPONSE", createdAt: iso(t0), stepIndex: 1,
                input: 10, cacheRead: 0, output: 5,
                toolCalls: [["name": "edit_file", "args": "{\"path\":\"a.swift\"}"]]
            ),
            // 子工具步骤创建行（无 token 字段、中间态）。
            agyLine(type: "GENERIC", status: "RUNNING", createdAt: iso(t0.addingTimeInterval(7)), stepIndex: 2, input: nil, cacheRead: nil, output: nil, content: nil),
            // 纯文本终答（无 tool_calls）：即便后面有下一轮的 GENERIC 行也不结算。
            agyLine(type: "PLANNER_RESPONSE", createdAt: iso(t0.addingTimeInterval(60)), stepIndex: 3, input: 7, cacheRead: 0, output: 1, content: "final"),
            agyLine(type: "GENERIC", status: "RUNNING", createdAt: iso(t0.addingTimeInterval(69)), stepIndex: 4, input: nil, cacheRead: nil, output: nil, content: nil)
        ])

        let result = try scan(fixture)

        XCTAssertEqual(
            try sample(result, "session-a:step:1").durationSeconds ?? 0, 7, accuracy: 0.0001,
            "GENERIC.created_at − planner.created_at（秒级近似）"
        )
        XCTAssertNil(
            try sample(result, "session-a:step:3").durationSeconds,
            "纯文本终答无 tool_calls，不产生 GENERIC 后继结算，保持 nil"
        )
        XCTAssertEqual(result.eventCount, 2)
    }

    /// 方案 B 只认 MODEL:GENERIC 标记行：下一轮 USER_INPUT 行与同 source 的
    /// 非 GENERIC MODEL 行都不得用于结算。
    func testNonGenericRowsDoNotSettlePlannerDuration() throws {
        let fixture = makeFixture()
        writeSession(fixture, sessionID: "session-a", mainLines: [
            agyLine(
                type: "PLANNER_RESPONSE", createdAt: iso(t0), stepIndex: 1,
                input: 10, cacheRead: 0, output: 5,
                toolCalls: [["name": "grep", "args": "{}"]]
            ),
            // 下一轮 USER_INPUT 行（字节级预过滤就进不了 consumeLine）。
            agyLine(source: "USER", type: "USER_INPUT", createdAt: iso(t0.addingTimeInterval(100)), stepIndex: 2, input: nil, cacheRead: nil, output: nil),
            // 带 "source":"MODEL" 但 type 不是 GENERIC 的行：不得当作标记。
            agyLine(type: "PLANNER_RESPONSE", status: "RUNNING", createdAt: iso(t0.addingTimeInterval(200)), stepIndex: 3, input: nil, cacheRead: nil, output: nil, content: nil)
        ])

        let result = try scan(fixture)

        XCTAssertNil(
            try sample(result, "session-a:step:1").durationSeconds,
            "USER_INPUT 与非 GENERIC 的 MODEL 行都不能结算时长"
        )
        XCTAssertEqual(result.eventCount, 1)
    }

    /// 方案 B 跨文件：planner 与其 GENERIC 后继被轮转拆到主文件 / 分块两侧
    /// （主文件先于 chunks 解析）时仍正确配对——结算与文件处理顺序无关。
    func testGenericSuccessorAcrossMainAndChunkFiles() throws {
        let fixture = makeFixture()
        // 主文件（新行）：GENERIC 标记 + 其后的新计量行。
        writeSession(
            fixture,
            sessionID: "session-a",
            mainLines: [
                agyLine(type: "GENERIC", status: "RUNNING", createdAt: iso(t0.addingTimeInterval(7)), stepIndex: 2, input: nil, cacheRead: nil, output: nil, content: nil),
                agyLine(type: "PLANNER_RESPONSE", createdAt: iso(t0.addingTimeInterval(60)), stepIndex: 3, input: 7, cacheRead: 0, output: 1, content: "next")
            ],
            // 分块（旧行）：planner 计量行在轮转边界被切进分块。
            chunkLines: [
                agyLine(
                    type: "PLANNER_RESPONSE", createdAt: iso(t0), stepIndex: 1,
                    input: 10, cacheRead: 0, output: 5,
                    toolCalls: [["name": "read_file", "args": "{}"]]
                )
            ]
        )

        // 顺序约定：同一会话内主文件先于 chunks。
        let urls = try AgyLocalUsageScanner.transcriptFileURLs(
            in: fixture.brainRoot,
            fileManager: FileManagerBox()
        )
        let snapshots = try urls.map { try AgyLogFileSnapshot(url: $0, fileManager: FileManagerBox()) }
        let ordered = AgyLocalUsageScanner.orderedSessionFiles(snapshots)
        XCTAssertEqual(
            ordered.map(\.url.lastPathComponent),
            ["transcript.jsonl", "00000000.jsonl"],
            "主文件必须先于 chunks（路径排序下 chunks 在前，需要显式重排）"
        )

        let result = try scan(fixture)

        XCTAssertEqual(
            try sample(result, "session-a:step:1").durationSeconds ?? 0, 7, accuracy: 0.0001,
            "标记先于 planner 被解析（主文件在前）也必须在会话结算期回配"
        )
        XCTAssertNil(try sample(result, "session-a:step:3").durationSeconds)
    }

    /// 方案 B 的 (0, 3600] 有效域：同秒（0）与超一小时（3601）不产出时长，
    /// 1s 与恰好 3600s 有效。
    func testFallbackDurationValidityDomain() throws {
        let fixture = makeFixture()
        func planner(_ step: Int, at time: Date, toolCalls: Bool) -> String {
            agyLine(
                type: "PLANNER_RESPONSE", createdAt: iso(time), stepIndex: step,
                input: 1, cacheRead: 0, output: 1,
                toolCalls: toolCalls ? [["name": "t", "args": "{}"]] : nil
            )
        }
        func marker(_ step: Int, at time: Date) -> String {
            agyLine(type: "GENERIC", status: "RUNNING", createdAt: iso(time), stepIndex: step, input: nil, cacheRead: nil, output: nil, content: nil)
        }
        writeSession(fixture, sessionID: "session-a", mainLines: [
            planner(10, at: t0, toolCalls: true), marker(11, at: t0.addingTimeInterval(1)),
            planner(20, at: t0, toolCalls: true), marker(21, at: t0),
            planner(30, at: t0, toolCalls: true), marker(31, at: t0.addingTimeInterval(3_600)),
            planner(40, at: t0, toolCalls: true), marker(41, at: t0.addingTimeInterval(3_601))
        ])

        let result = try scan(fixture)

        XCTAssertEqual(try sample(result, "session-a:step:10").durationSeconds ?? 0, 1, accuracy: 0.0001)
        XCTAssertNil(try sample(result, "session-a:step:20").durationSeconds, "同秒差为 0：无效域")
        XCTAssertEqual(try sample(result, "session-a:step:30").durationSeconds ?? 0, 3_600, accuracy: 0.0001)
        XCTAssertNil(try sample(result, "session-a:step:40").durationSeconds, "3601s 超界：无效域")
    }

    /// 缓存失效：v2 旧索引（无样本时长）必须被版本守卫一次性拒绝并全量重建，
    /// 重建后的索引以 v3 落盘。
    func testCacheVersionBumpRebuildsStaleV2Index() throws {
        let fixture = makeFixture()
        writeSession(
            fixture,
            sessionID: "session-a",
            mainLines: [agyLine(createdAt: iso(t0), input: 10, cacheRead: 0, output: 5)]
        )
        // 手写一份 v2 旧格式索引（content 与真实文件集不符，若被采纳会短路出 99 个事件）。
        let stale = AgyLocalUsage(
            dailyTokenUsage: [],
            models: [],
            recentSamples: [],
            sessionsRoot: "/stale",
            sessionCount: 42,
            eventCount: 99,
            scannedAt: t0
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshotJSON = try JSONSerialization.jsonObject(with: encoder.encode(stale))
        let legacyIndex: [String: Any] = [
            "version": 2,
            "files": [] as [[String: Any]],
            "snapshot": snapshotJSON,
            "calendarSignature": LocalUsageCalendarSignature.make(fixture.calendar)
        ]
        try JSONSerialization.data(withJSONObject: legacyIndex).write(to: fixture.cacheDir, options: .atomic)

        let result = try scan(fixture)

        XCTAssertEqual(result.eventCount, 1, "v2 索引必须被拒绝，按真实文件重新聚合")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cacheDir)) as? [String: Any]
        XCTAssertEqual(saved?["version"] as? Int, 3, "重建后的索引以 v3 落盘")
        let rebuilt = try sample(result, "session-a:step:1")
        XCTAssertNil(rebuilt.durationSeconds, "无 .db、无 GENERIC 标记的行时长保持 nil（重建路径不炸）")
    }
}
