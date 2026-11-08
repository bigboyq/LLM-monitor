import XCTest
import SQLite3
@testable import LLM_monitor

/// `.db` 直读扫描测试的共享基类（阶段二b）：conversations 目录 + 程序化合成
/// 会话 `.db` + `performScanPureImpl` 驱动。RPC 时代的 metadata 替身
/// （`MetadataStub`）随数据源退役删除——新数据源没有网络请求，测试直接构造
/// 真实 SQLite fixture，不注入任何网络层。
class AntigravityScanTestCase: AntigravityTestCase {

    // MARK: - 共享 fixture

    struct ScanFixture {
        let root: URL
        let conversations: URL
        let cache: URL
        let fm: FileManager
    }

    /// 便于断言的固定时间基点（UTC 日内时刻；具体日期无关紧要，日键由
    /// testCalendar.startOfDay 推得）。
    let fixtureBaseSeconds: UInt64 = 1_789_996_800

    func makeScanFixture() throws -> ScanFixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("antigravity-scan-\(UUID().uuidString)", isDirectory: true)
        let conversations = root.appendingPathComponent("conversations", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try fm.createDirectory(at: conversations, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        return ScanFixture(root: root, conversations: conversations, cache: cache, fm: fm)
    }

    // MARK: - 会话 .db 构造

    /// 一次 LLM call 的 fixture 描述（gen 行 + 连接命中的 step_type=15 行）。
    struct CallSpec {
        /// steps.idx（连接键 = gen.last_step_index + 1 == stepIndex）
        var stepIndex: Int
        var model: String?
        var input: UInt64 = 100
        var cacheRead: UInt64 = 0
        var rawOutput: UInt64 = 30
        var reasoning: UInt64 = 10
        /// steps.metadata field 1（发起，epoch 秒）
        var startSeconds: UInt64
        /// steps.metadata field 7（流式完成，epoch 秒）；nil = 不写 field 7
        var endSeconds: UInt64?
        /// steps.metadata 写 NULL（call 无时间戳 → 排除出日账）
        var nullMetadata: Bool = false
        /// gen 行省略 usage 子消息（整条不产生 Call）
        var omitUsage: Bool = false
    }

    /// 在 fixture 的 conversations 目录下合成一个会话 `.db`：
    /// - `turnStepIndexes`：`step_type=14` 用户轮次边界行
    /// - `calls`：连接命中的 LLM call（gen 行 lsi = stepIndex − 1）
    /// - `at`：覆盖输出路径（如「文件再变化」用例对同一 session 重写内容）
    @discardableResult
    func makeScanSessionDB(
        in fixture: ScanFixture,
        sessionID: String,
        turnStepIndexes: [Int] = [],
        turnStartSeconds: UInt64? = nil,
        calls: [CallSpec],
        at dbURL: URL? = nil
    ) throws -> URL {
        let gen: [GenRow] = calls.map { call in
            GenRow(
                model: call.model,
                usage: call.omitUsage ? nil : (
                    input: call.input,
                    cacheRead: call.cacheRead,
                    rawOutput: call.rawOutput,
                    reasoning: call.reasoning,
                    normalized: call.omitUsage ? nil : call.rawOutput - call.reasoning
                ),
                attributes: [lsi(UInt64(call.stepIndex - 1))]
            )
        }
        var steps: [StepRow] = turnStepIndexes.map { idx in
            StepRow(
                idx: idx,
                type: 14,
                start: turnStartSeconds.map { (seconds: $0, nanos: 0) }
            )
        }
        steps += calls.map { call in
            StepRow(
                idx: call.stepIndex,
                type: 15,
                start: call.nullMetadata ? nil : (seconds: call.startSeconds, nanos: 0),
                end: call.nullMetadata ? nil : call.endSeconds.map { (seconds: $0, nanos: 0) },
                nullMetadata: call.nullMetadata
            )
        }
        return try makeSessionDB(
            gen: gen,
            steps: steps,
            at: dbURL ?? fixture.conversations.appendingPathComponent("\(sessionID).db")
        )
    }

    // MARK: - 扫描驱动

    /// 直跑 scanner pipeline（真实 `.db`，无任何网络注入）。
    func runScan(
        fixture: ScanFixture,
        now: Date,
        calendar: Calendar? = nil,
        forceFull: Bool = false,
        directoryContents: ((URL) throws -> [URL])? = nil
    ) async throws -> AntigravityLocalUsage {
        try await AntigravityLocalUsageScanner.performScanPureImpl(
            conversationsDirs: [fixture.conversations],
            cacheDir: fixture.cache,
            fileManager: FileManagerBox(fixture.fm),
            calendar: calendar ?? testCalendar,
            now: { now },
            shouldSave: true,
            forceFull: forceFull,
            directoryContents: directoryContents
        )
    }

    func loadScanIndex(_ fixture: ScanFixture) throws -> AntigravityLocalUsageScanner.CacheIndex {
        try AntigravityLocalUsageScanner.loadIndex(
            cacheDir: fixture.cache,
            fileManager: FileManagerBox(fixture.fm)
        )
    }

    func saveScanIndex(
        _ index: AntigravityLocalUsageScanner.CacheIndex,
        fixture: ScanFixture
    ) throws {
        try AntigravityLocalUsageScanner.saveIndex(
            index, cacheDir: fixture.cache, fileManager: FileManagerBox(fixture.fm)
        )
    }

    /// 固定基点的 UTC 日起点/日键（第 `dayOffset` 天，0 = 基点所在日）。
    func dayStart(_ dayOffset: Int = 0) -> Date {
        testCalendar.date(
            byAdding: .day,
            value: dayOffset,
            to: testCalendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(fixtureBaseSeconds)))
        )!
    }

    func dayKey(_ dayOffset: Int = 0) -> String {
        LocalUsageDayKey.make(dayStart(dayOffset), calendar: testCalendar)
    }
}
