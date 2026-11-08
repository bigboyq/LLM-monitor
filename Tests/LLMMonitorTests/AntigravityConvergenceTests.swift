import XCTest
import SQLite3
@testable import LLM_monitor

/// 阶段二b `.db` 直读扫描的行为契约：日归属与 7 天窗口、turns/rounds 直计、
/// cacheWrite 恒 0、无时间戳 Call 排除、v8 缓存被 v9 丢弃重建、`.pb` 忽略、
/// probe 失败计一次失败且扫描继续、指纹短路不开库、全程无网络请求。
final class AntigravityDBSourceScanTests: AntigravityScanTestCase {

    // MARK: - 日归属与 7 天窗口

    func testScanAttributesCallsToLocalDaysAndSevenDayWindow() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // 两个本地日各有调用；跨日轮次（turn 边界在 day0，最后一条 call 在 day1）。
        try makeScanSessionDB(
            in: fixture,
            sessionID: "days-session",
            turnStepIndexes: [1, 40],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 10, cacheRead: 5,
                         rawOutput: 8, reasoning: 3, startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 2),
                CallSpec(stepIndex: 3, model: fixtureFlashModel, input: 20, cacheRead: 6,
                         rawOutput: 9, reasoning: 4, startSeconds: fixtureBaseSeconds + 60, endSeconds: fixtureBaseSeconds + 61),
                CallSpec(stepIndex: 41, model: fixtureArgonModel, input: 30, cacheRead: 7,
                         rawOutput: 10, reasoning: 5,
                         startSeconds: fixtureBaseSeconds + 86_400 + 60,
                         endSeconds: fixtureBaseSeconds + 86_400 + 62),
            ]
        )

        let now = dayStart(1).addingTimeInterval(3_600)
        let result = try await runScan(fixture: fixture, now: now)

        XCTAssertEqual(result.failedSessionCount, 0)
        XCTAssertEqual(result.sessionCount, 1)
        XCTAssertEqual(result.eventCount, 3)

        let index = try loadScanIndex(fixture)
        let byDay = try XCTUnwrap(index.dailyBySession["days-session"])
        XCTAssertEqual(byDay[dayKey(0)]?.inputTokens, 30, "day0 = 10 + 20（uncached input 桶）")
        XCTAssertEqual(byDay[dayKey(1)]?.inputTokens, 30, "day1 = 30")
        XCTAssertEqual(byDay[dayKey(0)]?.rounds, 2)
        XCTAssertEqual(byDay[dayKey(1)]?.rounds, 1)

        // 7 天窗口：恒 7 天、按日升序、today 收尾；两天的数据都在窗口内。
        XCTAssertEqual(result.dailyTokenUsage.count, 7)
        XCTAssertEqual(result.dailyTokenUsage.first?.dayStart, dayStart(-5), "today = dayStart(1)，窗口首日 = today − 6")
        XCTAssertEqual(result.dailyTokenUsage.last?.dayStart, dayStart(1) /* today */)
        XCTAssertTrue(result.dailyTokenUsage.contains { $0.dayStart == dayStart(0) && $0.inputTokens == 30 })
        XCTAssertTrue(result.dailyTokenUsage.contains { $0.dayStart == dayStart(1) && $0.inputTokens == 30 })
        XCTAssertEqual(result.today?.inputTokens, 30)
    }

    // MARK: - turns / rounds 直计

    func testTurnsCountedFromStep14AndRoundsFromConnectedCalls() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // 2 个用户轮（step_type=14 @1/@40）：turn-1 含 3 条 call（step 2..4），
        // turn-2 含 2 条 call（step 41..42）。
        try makeScanSessionDB(
            in: fixture,
            sessionID: "turns-session",
            turnStepIndexes: [1, 40],
            turnStartSeconds: fixtureBaseSeconds,
            calls: (0..<5).map { offset in
                let stepIndex = offset < 3 ? 2 + offset : 41 + offset - 3
                return CallSpec(
                    stepIndex: stepIndex,
                    model: fixtureFlashModel,
                    input: UInt64(10 + offset),
                    rawOutput: 8,
                    reasoning: 3,
                    startSeconds: fixtureBaseSeconds + UInt64(offset * 10),
                    endSeconds: fixtureBaseSeconds + UInt64(offset * 10 + 2)
                )
            }
        )

        let now = dayStart(0).addingTimeInterval(86_400 - 60)
        let result = try await runScan(fixture: fixture, now: now)

        XCTAssertEqual(result.failedSessionCount, 0)
        let index = try loadScanIndex(fixture)
        let day = try XCTUnwrap(index.dailyBySession["turns-session"]?[dayKey(0)])
        XCTAssertEqual(day.turns, 2, "turns = step_type=14 直计（旧 stepIndices 间隙推断虚高已退役）")
        XCTAssertEqual(day.rounds, 5, "rounds = 连接命中的 Call 数")
        XCTAssertEqual(index.sessions["turns-session"]?.eventCount, 5)

        let samples = try XCTUnwrap(index.samplesBySession?["turns-session"])
        XCTAssertEqual(samples.count, 5)
        XCTAssertEqual(samples.prefix(3).map { $0.promptID },
                       Array(repeating: "turns-session:turn-1", count: 3),
                       "promptID 轮序 = idx 小于该 call stepIndex 的 step14 行数")
        XCTAssertEqual(samples.suffix(2).map { $0.promptID },
                       Array(repeating: "turns-session:turn-2", count: 2))
        // gen idx 升序 = 时间序：轮序在样本序列中单调不减。
        XCTAssertEqual(
            samples.map(\.promptID),
            samples.sorted { $0.completedAt < $1.completedAt }.map(\.promptID)
        )
    }

    func testTurnNumberCountsOnlyEarlierTurnRows() {
        // 纯函数口径：轮序 N = idx 小于 call stepIndex 的 step14 行数。
        let turnIndexes = [1, 40, 80]
        XCTAssertEqual(AntigravityLocalUsageScanner.turnNumber(forCallStepIndex: 0, userTurnStepIndexes: turnIndexes), 0)
        XCTAssertEqual(AntigravityLocalUsageScanner.turnNumber(forCallStepIndex: 1, userTurnStepIndexes: turnIndexes), 0)
        XCTAssertEqual(AntigravityLocalUsageScanner.turnNumber(forCallStepIndex: 2, userTurnStepIndexes: turnIndexes), 1)
        XCTAssertEqual(AntigravityLocalUsageScanner.turnNumber(forCallStepIndex: 41, userTurnStepIndexes: turnIndexes), 2)
        XCTAssertEqual(AntigravityLocalUsageScanner.turnNumber(forCallStepIndex: 999, userTurnStepIndexes: turnIndexes), 3)
        // 克隆/后台会话没有 USER_INPUT（无 step14 行）：全部 call 落 turn-0。
        XCTAssertEqual(AntigravityLocalUsageScanner.turnNumber(forCallStepIndex: 5, userTurnStepIndexes: []), 0)
    }

    // MARK: - turns：turn-0 背景调用不开轮

    /// 0 个 step_type=14 行的会话（克隆/后台会话）：turns == 0（spec 口径），
    /// rounds / token 正常入账；样本 promptID 维持 `turn-0` 标签（语义 = 背景调用）。
    func testSessionWithoutUserTurnRowsCountsZeroTurns() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try makeScanSessionDB(
            in: fixture,
            sessionID: "clone-session",
            turnStepIndexes: [],
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 10,
                         rawOutput: 6, reasoning: 2,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 2),
                CallSpec(stepIndex: 3, model: fixtureFlashModel, input: 20,
                         rawOutput: 8, reasoning: 3,
                         startSeconds: fixtureBaseSeconds + 60, endSeconds: fixtureBaseSeconds + 62),
            ]
        )

        let now = dayStart(0).addingTimeInterval(3_600)
        let result = try await runScan(fixture: fixture, now: now)
        XCTAssertEqual(result.failedSessionCount, 0)
        let index = try loadScanIndex(fixture)
        let day = try XCTUnwrap(index.dailyBySession["clone-session"]?[dayKey(0)])
        XCTAssertEqual(day.turns, 0, "0 个 step14 行 → turns == 0（turn-0 背景调用不开轮）")
        XCTAssertEqual(day.rounds, 2, "turn-0 call 照常计 rounds")
        XCTAssertEqual(day.inputTokens, 30, "turn-0 call 的 token 照常入日桶")
        XCTAssertEqual(day.outputTokens, 9, "Output = raw − reasoning（6−2 + 8−3）")
        XCTAssertEqual(day.totalTokens, 30 + 9 + 5, "total = 四桶和")

        let samples = try XCTUnwrap(index.samplesBySession?["clone-session"])
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(
            samples.map(\.promptID),
            Array(repeating: "clone-session:turn-0", count: 2),
            "promptID 维持 turn-0 标签（背景调用，仅样本命名空间）"
        )
    }

    /// 首条用户输入（step14）之前存在后台/副调用：该调用落 turn-0、不开轮，
    /// 真实轮数不被虚增（1 个真实轮不得计成 2）。
    func testBackgroundCallBeforeFirstUserInputDoesNotInflateTurns() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try makeScanSessionDB(
            in: fixture,
            sessionID: "bg-first-session",
            turnStepIndexes: [40],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 10,
                         rawOutput: 6, reasoning: 2,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 2),
                CallSpec(stepIndex: 41, model: fixtureArgonModel, input: 20,
                         rawOutput: 8, reasoning: 3,
                         startSeconds: fixtureBaseSeconds + 60, endSeconds: fixtureBaseSeconds + 62),
            ]
        )

        let now = dayStart(0).addingTimeInterval(3_600)
        let result = try await runScan(fixture: fixture, now: now)
        XCTAssertEqual(result.failedSessionCount, 0)
        let index = try loadScanIndex(fixture)
        let day = try XCTUnwrap(index.dailyBySession["bg-first-session"]?[dayKey(0)])
        XCTAssertEqual(day.turns, 1, "首输入前的后台调用（turn-0）不开轮，1 个真实轮")
        XCTAssertEqual(day.rounds, 2)
        XCTAssertEqual(day.inputTokens, 30, "turn-0 call 的 token 照常入日桶")

        let samples = try XCTUnwrap(index.samplesBySession?["bg-first-session"])
        XCTAssertEqual(samples.map(\.promptID), ["bg-first-session:turn-0", "bg-first-session:turn-1"])
    }

    // MARK: - cacheWrite 恒 0 与样本口径

    func testCacheWriteAlwaysZeroAndSampleCalibers() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try makeScanSessionDB(
            in: fixture,
            sessionID: "caliber-session",
            turnStepIndexes: [1],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 100, cacheRead: 9_000,
                         rawOutput: 500, reasoning: 200,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 12)
            ]
        )

        let now = dayStart(0).addingTimeInterval(3_600)
        _ = try await runScan(fixture: fixture, now: now)

        let index = try loadScanIndex(fixture)
        let day = try XCTUnwrap(index.dailyBySession["caliber-session"]?[dayKey(0)])
        // .db 的 usage 子消息不提供 cacheWrite：四桶不受影响、诊断桶恒 0
        // （本就排除在 total 外，仅诊断可见性损失，有意接受）。
        XCTAssertEqual(day.cacheWriteTokens, 0)
        XCTAssertEqual(day.inputTokens, 100, "daily input = uncached 桶")
        XCTAssertEqual(day.cacheReadTokens, 9_000)
        // raw output 含思考：catalog 规范化 Output = 500 − 200 = 300。
        XCTAssertEqual(day.outputTokens, 300)
        XCTAssertEqual(day.reasoningTokens, 200)
        XCTAssertEqual(day.totalTokens, 100 + 9_000 + 300 + 200, "total = 四桶和（不含 cacheWrite）")

        let sample = try XCTUnwrap(index.samplesBySession?["caliber-session"]?.first)
        XCTAssertEqual(sample.inputTokens, 100 + 9_000, "sample input = cache-inclusive 兼容口径")
        XCTAssertEqual(sample.cachedInputTokens, 9_000)
        XCTAssertEqual(sample.outputTokens, 300)
        XCTAssertEqual(sample.reasoningOutputTokens, 200)
        XCTAssertEqual(sample.modelName, fixtureFlashModel)
        XCTAssertEqual(sample.durationSeconds ?? 0, 12, accuracy: 0.000_001, "durationSeconds = f7 − f1")
    }

    // MARK: - 无时间戳 Call 排除

    func testTimestamplessCallExcludedFromAllAggregates() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // step 3 的 metadata 为 NULL → call 无 completedAt；同一轮的其他 call
        // 有时间戳。turn 边界仍由 step14 直计。
        try makeScanSessionDB(
            in: fixture,
            sessionID: "timestampless-session",
            turnStepIndexes: [1],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 10,
                         rawOutput: 8, reasoning: 3,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 2),
                CallSpec(stepIndex: 3, model: fixtureFlashModel, input: 999,
                         rawOutput: 999, reasoning: 999, startSeconds: 0, endSeconds: nil,
                         nullMetadata: true),
                CallSpec(stepIndex: 4, model: fixtureFlashModel, input: 20,
                         rawOutput: 9, reasoning: 4,
                         startSeconds: fixtureBaseSeconds + 60, endSeconds: fixtureBaseSeconds + 61),
            ]
        )

        let now = dayStart(0).addingTimeInterval(3_600)
        let result = try await runScan(fixture: fixture, now: now)

        XCTAssertEqual(result.failedSessionCount, 0)
        let index = try loadScanIndex(fixture)
        let day = try XCTUnwrap(index.dailyBySession["timestampless-session"]?[dayKey(0)])
        XCTAssertEqual(day.inputTokens, 30, "无时间戳 call 的 token 不进日桶")
        XCTAssertEqual(day.rounds, 2, "rounds 只计带时间戳的 call")
        XCTAssertEqual(day.turns, 1)
        XCTAssertEqual(index.sessions["timestampless-session"]?.eventCount, 2, "eventCount = 入账口径")
        let samples = try XCTUnwrap(index.samplesBySession?["timestampless-session"])
        XCTAssertEqual(samples.count, 2, "无时间戳 call 不产样本")
    }

    // MARK: - v8 缓存被 v9 丢弃重建

    func testV8CacheDroppedAndRebuiltAsV9() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try makeScanSessionDB(
            in: fixture,
            sessionID: "v8-session",
            turnStepIndexes: [1],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 42, cacheRead: 7,
                         rawOutput: 20, reasoning: 8,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 3)
            ]
        )

        // 预置一份 v8（RPC 时代）index：旧口径 daily（input=500）与旧 samples。
        let staleDay = dayStart(0)
        let v8Index = AntigravityLocalUsageScanner.CacheIndex(
            version: 8,
            lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sessions: ["v8-session": .init(
                mtimeMs: 1, sizeBytes: 2, walMtimeMs: 0, walSizeBytes: 0,
                fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
                eventCount: 9
            )],
            dailyBySession: ["v8-session": [dayKey(0): AntigravityDailyUsage(
                dayStart: staleDay, inputTokens: 500, totalTokens: 500
            )]],
            samplesBySession: ["v8-session": [LocalTokenUsageSample(
                completedAt: staleDay,
                modelName: "gemini-2.5-pro",
                promptID: "v8-session:turn-1",
                inputTokens: 1,
                cachedInputTokens: 0,
                outputTokens: 1,
                reasoningOutputTokens: 0
            )]],
            calendarSignature: LocalUsageCalendarSignature.make(testCalendar)
        )
        try saveScanIndex(v8Index, fixture: fixture)

        let now = dayStart(0).addingTimeInterval(3_600)
        let result = try await runScan(fixture: fixture, now: now)

        XCTAssertEqual(result.failedSessionCount, 0)
        XCTAssertEqual(result.eventCount, 1, "v8 计数不继承，eventCount 来自 v9 直读重建")
        let index = try loadScanIndex(fixture)
        XCTAssertEqual(index.version, 9)
        XCTAssertEqual(index.sessions["v8-session"]?.eventCount, 1)
        XCTAssertEqual(
            index.dailyBySession["v8-session"]?[dayKey(0)]?.inputTokens, 42,
            "v8 旧口径 daily 被直读重建整体替换"
        )
        let samples = try XCTUnwrap(index.samplesBySession?["v8-session"])
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.inputTokens, 49, "样本按 .db 直读口径重建（42 + 7）")

        // 冷启动恢复走同一 loadIndex 路径：v8 缓存同样不可恢复（按空缓存重建）。
        let restored = AntigravityLocalUsageScanner.loadCachedResult(
            cacheDir: fixture.cache,
            fileManager: FileManagerBox(fixture.fm),
            calendar: testCalendar,
            now: now
        )
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.eventCount, 1)
    }

    // MARK: - .pb 完全忽略

    func testPbFilesIgnoredAndOnlyDbAccepted() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try makeScanSessionDB(
            in: fixture,
            sessionID: "db-session",
            turnStepIndexes: [1],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 5,
                         rawOutput: 3, reasoning: 1,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 1)
            ]
        )
        // .pb 会话（旧包装格式，无 gen_metadata）：内容无关紧要，直接忽略。
        try Data(repeating: 0xAB, count: 64).write(
            to: fixture.conversations.appendingPathComponent("pb-session.pb")
        )
        // 周边文件与无关文件不进 session 集。
        try Data(repeating: 0, count: 8).write(to: fixture.conversations.appendingPathComponent("db-session.db-wal"))
        try Data(repeating: 0, count: 8).write(to: fixture.conversations.appendingPathComponent("db-session.db-shm"))
        try Data(repeating: 0, count: 8).write(to: fixture.conversations.appendingPathComponent("notes.txt"))

        let listing = AntigravityLocalUsageScanner.listDBFilesWithStatus(
            conversationsDirs: [fixture.conversations],
            fileManager: FileManagerBox(fixture.fm)
        )
        XCTAssertEqual(listing.files.count, 1, "会话枚举只收 .db")
        XCTAssertEqual(listing.files["db-session"]?.url.pathExtension, "db")
        XCTAssertNil(listing.files["pb-session"])

        let now = dayStart(0).addingTimeInterval(3_600)
        let result = try await runScan(fixture: fixture, now: now)
        XCTAssertEqual(result.sessionCount, 1, ".pb 不进扫描 session 集")
        XCTAssertEqual(result.failedSessionCount, 0, ".pb 内容不参与 probe，不会计失败")
        XCTAssertEqual(result.eventCount, 1)
    }

    // MARK: - probe 失败：计一次失败，扫描继续

    func testIncompatibleSessionCountsOneFailureAndScanContinues() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try makeScanSessionDB(
            in: fixture,
            sessionID: "good-session",
            turnStepIndexes: [1],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 11,
                         rawOutput: 6, reasoning: 2,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 2)
            ]
        )
        // 旧版/损坏 .db：非 SQLite 字节 → probe .incompatible（sqlite: 前缀原因）。
        let badPath = fixture.conversations.appendingPathComponent("bad-session.db")
        try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01]).write(to: badPath)

        let now = dayStart(0).addingTimeInterval(3_600)
        let scan1 = try await runScan(fixture: fixture, now: now)

        XCTAssertEqual(scan1.failedSessionCount, 1, "probe .incompatible 的 session 记一次失败")
        XCTAssertEqual(scan1.sessionCount, 2, "失败 session 不影响 sessionCount")
        XCTAssertEqual(scan1.eventCount, 1, "继续扫其余 session")

        let index = try loadScanIndex(fixture)
        XCTAssertEqual(index.dailyBySession["good-session"]?[dayKey(0)]?.inputTokens, 11)
        let bad = try XCTUnwrap(index.sessions["bad-session"])
        XCTAssertEqual(bad.eventCount, 0)
        let badValues = try badPath.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        XCTAssertEqual(bad.sizeBytes, badValues.fileSize, "失败 session 采纳当前文件指纹（下一轮不再重读同一份字节）")
        XCTAssertEqual(bad.mtimeMs, (try XCTUnwrap(badValues.contentModificationDate)).timeIntervalSince1970 * 1000)
        XCTAssertEqual(index.samplesBySession?["bad-session"]?.count, 0, "补写空 samples，避免缺缓存分支反复重读")

        // 第 2 轮：指纹已匹配 → 不再重读 → 不再计失败；签名照常推进。
        let scan2 = try await runScan(fixture: fixture, now: now.addingTimeInterval(60))
        XCTAssertEqual(scan2.failedSessionCount, 0)
        let index2 = try loadScanIndex(fixture)
        XCTAssertEqual(
            index2.calendarSignature, LocalUsageCalendarSignature.make(testCalendar),
            "全部 session 成功/收敛后签名推进"
        )
        XCTAssertEqual(index2.dailyBySession["bad-session"], nil, "无 last-good 的失败 session 保持空账")

        // 文件再变化（IDE 升级重写为可用库）→ 重新 dirty 并正常入账。
        try makeSessionDB(
            gen: [GenRow(
                model: fixtureFlashModel,
                usage: (input: 21, cacheRead: 0, rawOutput: 9, reasoning: 3, normalized: 6),
                attributes: [lsi(1)]
            )],
            steps: [
                StepRow(idx: 1, type: 14, start: (seconds: fixtureBaseSeconds, nanos: 0)),
                StepRow(idx: 2, type: 15, start: (seconds: fixtureBaseSeconds, nanos: 0),
                        end: (seconds: fixtureBaseSeconds + 4, nanos: 0)),
            ],
            at: badPath
        )
        let scan3 = try await runScan(fixture: fixture, now: now.addingTimeInterval(120))
        XCTAssertEqual(scan3.failedSessionCount, 0)
        XCTAssertEqual(scan3.eventCount, 2, "复活 session 与好 session 一起入账")
        let index3 = try loadScanIndex(fixture)
        XCTAssertEqual(index3.dailyBySession["bad-session"]?[dayKey(0)]?.inputTokens, 21)
    }

    func testIncompatibleSessionKeepsLastGoodHistory() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sessionID = "degraded-session"
        let dbPath = fixture.conversations.appendingPathComponent("\(sessionID).db")

        // 先用可读 fixture 建立一次 last-good（daily + samples + eventCount）。
        try makeScanSessionDB(
            in: fixture,
            sessionID: sessionID,
            turnStepIndexes: [1],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 77,
                         rawOutput: 30, reasoning: 10,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 5)
            ]
        )
        let now = dayStart(0).addingTimeInterval(3_600)
        _ = try await runScan(fixture: fixture, now: now)

        // 损坏（版本指纹失效形态：非 SQLite 字节），指纹随之变化 → dirty → probe 失败。
        try Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]).write(to: dbPath)

        let scan2 = try await runScan(fixture: fixture, now: now.addingTimeInterval(60))
        XCTAssertEqual(scan2.failedSessionCount, 1)
        let index = try loadScanIndex(fixture)
        XCTAssertEqual(
            index.dailyBySession[sessionID]?[dayKey(0)]?.inputTokens, 77,
            "读失败绝不清空 last-good daily"
        )
        XCTAssertEqual(index.sessions[sessionID]?.eventCount, 1, "last-good eventCount 保留")
        XCTAssertEqual(index.samplesBySession?[sessionID]?.count, 1, "last-good samples 保留")
        XCTAssertEqual(
            index.sessions[sessionID]?.sizeBytes, 8,
            "指纹采纳当前文件，下一轮不再重读同一份坏字节"
        )

        let scan3 = try await runScan(fixture: fixture, now: now.addingTimeInterval(120))
        XCTAssertEqual(scan3.failedSessionCount, 0, "收敛轮不再计失败")
    }

    // MARK: - 可重试读失败：不采纳指纹、下一轮重试（两路收敛语义）

    /// 撤销 db 读权限再恢复（mtime/size 语义下的瞬时 I/O 故障）：可重试失败轮
    /// 不采纳当前指纹（修复前会立即收敛 → 下一轮跳过读取、事件数停在 last-good），
    /// 恢复后自然重读、数据读回、计数清零。
    func testRetryableReadFailureKeepsDirtyAndRecoversAfterPermissionRestore() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sessionID = "retryable-session"
        let dbPath = try makeScanSessionDB(
            in: fixture,
            sessionID: sessionID,
            turnStepIndexes: [1],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 33,
                         rawOutput: 12, reasoning: 4,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 2)
            ]
        )
        let now = dayStart(0).addingTimeInterval(3_600)
        _ = try await runScan(fixture: fixture, now: now)
        let index1 = try loadScanIndex(fixture)
        XCTAssertEqual(index1.sessions[sessionID]?.eventCount, 1)
        XCTAssertNil(index1.sessions[sessionID]?.consecutiveReadFailures)

        // 撤销读权限 + 推进 mtime 强制 dirty（先 touch 后 chmod；probe 拿不到库
        // → SQLite CANTOPEN → /tmp 拷贝同样 EACCES → probe .retryable）。
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(30)],
            ofItemAtPath: dbPath.path
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dbPath.path)

        let scan2 = try await runScan(fixture: fixture, now: now.addingTimeInterval(60))
        XCTAssertEqual(scan2.failedSessionCount, 1, "可重试读失败当轮记一次失败")
        XCTAssertEqual(scan2.eventCount, 1, "last-good 数据保持")
        let index2 = try loadScanIndex(fixture)
        XCTAssertEqual(index2.sessions[sessionID]?.consecutiveReadFailures, 1, "streak 计数落盘")
        XCTAssertEqual(
            index2.sessions[sessionID]?.mtimeMs, index1.sessions[sessionID]?.mtimeMs,
            "可重试失败不采纳当前文件指纹（旧指纹保留，下轮重试）"
        )
        XCTAssertEqual(index2.dailyBySession[sessionID]?[dayKey(0)]?.inputTokens, 33, "last-good daily 保留")

        // 恢复读权限（文件 mtime 未再变化）：修复前该轮会因指纹已收敛而跳过
        // 读取；现在旧指纹仍不匹配 → 重读成功、fetchedAt 前进、计数清零。
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbPath.path)
        let scan3 = try await runScan(fixture: fixture, now: now.addingTimeInterval(120))
        XCTAssertEqual(scan3.failedSessionCount, 0)
        XCTAssertEqual(scan3.eventCount, 1, "瞬时 I/O 故障恢复后数据读回")
        let index3 = try loadScanIndex(fixture)
        XCTAssertNil(index3.sessions[sessionID]?.consecutiveReadFailures, "成功清零")
        XCTAssertEqual(index3.dailyBySession[sessionID]?[dayKey(0)]?.inputTokens, 33)
        XCTAssertEqual(
            index3.sessions[sessionID]?.fetchedAt, now.addingTimeInterval(120),
            "重读确实发生（fetchedAt 前进到恢复轮）"
        )
    }

    /// 永久性可重试故障的有界收敛：连续 3 次失败后按不兼容同款策略采纳当前
    /// 指纹并保留 last-good（失败轮数有界，不再每轮重读同一份字节）；文件再
    /// 变化时重新 dirty、正常入账。
    func testRetryableReadFailureConvergesAfterThreeStrikes() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sessionID = "bounded-session"
        let dbPath = try makeScanSessionDB(
            in: fixture,
            sessionID: sessionID,
            turnStepIndexes: [1],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 33,
                         rawOutput: 12, reasoning: 4,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 2)
            ]
        )
        let now = dayStart(0).addingTimeInterval(3_600)
        _ = try await runScan(fixture: fixture, now: now)

        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(30)],
            ofItemAtPath: dbPath.path
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dbPath.path)

        let scan2 = try await runScan(fixture: fixture, now: now.addingTimeInterval(60))
        XCTAssertEqual(scan2.failedSessionCount, 1)
        var index = try loadScanIndex(fixture)
        XCTAssertEqual(index.sessions[sessionID]?.consecutiveReadFailures, 1)
        let fingerprintBeforeFailures = index.sessions[sessionID]?.mtimeMs

        let scan3 = try await runScan(fixture: fixture, now: now.addingTimeInterval(120))
        XCTAssertEqual(scan3.failedSessionCount, 1, "streak=1 < 3：保持 dirty 重试")
        index = try loadScanIndex(fixture)
        XCTAssertEqual(index.sessions[sessionID]?.consecutiveReadFailures, 2)

        let scan4 = try await runScan(fixture: fixture, now: now.addingTimeInterval(180))
        XCTAssertEqual(scan4.failedSessionCount, 1, "第 3 次失败当轮仍计一次失败")
        index = try loadScanIndex(fixture)
        XCTAssertNil(index.sessions[sessionID]?.consecutiveReadFailures, "有界收敛即清零")
        let touchedMtime = try XCTUnwrap(
            try dbPath.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        XCTAssertEqual(
            index.sessions[sessionID]?.mtimeMs ?? 0,
            touchedMtime.timeIntervalSince1970 * 1000,
            accuracy: 1,
            "收敛采纳当前（被 touch 的）文件指纹"
        )
        XCTAssertNotEqual(
            index.sessions[sessionID]?.mtimeMs, fingerprintBeforeFailures,
            "采纳的是 touch 后的新指纹，不是失败前的旧指纹"
        )
        XCTAssertEqual(index.dailyBySession[sessionID]?[dayKey(0)]?.inputTokens, 33, "收敛保留 last-good daily")

        // 收敛后指纹已匹配：不再重读、不再计失败。
        let scan5 = try await runScan(fixture: fixture, now: now.addingTimeInterval(240))
        XCTAssertEqual(scan5.failedSessionCount, 0, "永久故障的失败轮数有界（≤ 3 轮）")

        // 文件再变化（权限恢复 + 内容重写）→ 重新 dirty、正常入账。
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbPath.path)
        try makeScanSessionDB(
            in: fixture,
            sessionID: sessionID,
            turnStepIndexes: [1],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 55,
                         rawOutput: 20, reasoning: 5,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 3)
            ],
            at: dbPath
        )
        let scan6 = try await runScan(fixture: fixture, now: now.addingTimeInterval(300))
        XCTAssertEqual(scan6.failedSessionCount, 0)
        XCTAssertEqual(scan6.eventCount, 1)
        index = try loadScanIndex(fixture)
        XCTAssertEqual(index.dailyBySession[sessionID]?[dayKey(0)]?.inputTokens, 55,
                       "文件再变化后按新内容重新入账")
        XCTAssertNil(index.sessions[sessionID]?.consecutiveReadFailures)
    }

    /// 首读即失败的新 session：写「当前指纹 + streak 计数」条目，重试由 streak
    /// 条件驱动（指纹已匹配、无该条件则计数永无机会累计、永久故障每轮重读）。
    func testRetryableReadFailureOnNewSessionRetriesByStreakCounter() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sessionID = "fresh-session"
        let dbPath = try makeScanSessionDB(
            in: fixture,
            sessionID: sessionID,
            turnStepIndexes: [1],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 21,
                         rawOutput: 9, reasoning: 3,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 2)
            ]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dbPath.path)

        let now = dayStart(0).addingTimeInterval(3_600)
        let scan1 = try await runScan(fixture: fixture, now: now)
        XCTAssertEqual(scan1.failedSessionCount, 1)
        var index = try loadScanIndex(fixture)
        let entry1 = try XCTUnwrap(index.sessions[sessionID])
        XCTAssertEqual(entry1.consecutiveReadFailures, 1, "首读失败的新 session 也写条目记录 streak")
        XCTAssertEqual(entry1.eventCount, 0)
        let currentMtime = try XCTUnwrap(
            try dbPath.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        XCTAssertEqual(entry1.mtimeMs, currentMtime.timeIntervalSince1970 * 1000, accuracy: 1,
                       "无 last-good 的新 session 写当前指纹")

        // 文件未变化（指纹已匹配）：streak 条件驱动重试。
        let scan2 = try await runScan(fixture: fixture, now: now.addingTimeInterval(60))
        XCTAssertEqual(scan2.failedSessionCount, 1, "streak 驱动重读（指纹未变也要重试）")
        index = try loadScanIndex(fixture)
        XCTAssertEqual(index.sessions[sessionID]?.consecutiveReadFailures, 2)

        // 恢复 → 重读成功、计数清零。
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbPath.path)
        let scan3 = try await runScan(fixture: fixture, now: now.addingTimeInterval(120))
        XCTAssertEqual(scan3.failedSessionCount, 0)
        XCTAssertEqual(scan3.eventCount, 1)
        index = try loadScanIndex(fixture)
        XCTAssertNil(index.sessions[sessionID]?.consecutiveReadFailures)
        XCTAssertEqual(index.dailyBySession[sessionID]?[dayKey(0)]?.inputTokens, 21)
    }

    // MARK: - 指纹短路：未变化的 session 不开库

    func testFingerprintShortCircuitSkipsUnchangedSession() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sessionID = "shortcircuit-session"
        let dbPath = try makeScanSessionDB(
            in: fixture,
            sessionID: sessionID,
            turnStepIndexes: [1],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 33,
                         rawOutput: 12, reasoning: 4,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 2)
            ]
        )
        let now = dayStart(0).addingTimeInterval(3_600)
        _ = try await runScan(fixture: fixture, now: now)
        let index1 = try loadScanIndex(fixture)
        XCTAssertEqual(index1.sessions[sessionID]?.eventCount, 1)

        // 摘掉读权限（chmod 只动 ctime，mtime/size 指纹不变）：若 scanner 违反
        // 短路开了库，open/读取会失败 → failedSessionCount ≥ 1。chmod 之后
        // 恢复，避免影响枚举（stat 不需要读权限，listing 不受影响）。
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: dbPath.path
        )
        let scan2 = try await runScan(fixture: fixture, now: now.addingTimeInterval(60))
        XCTAssertEqual(scan2.failedSessionCount, 0, "指纹未变不得开库（开库即读取失败）")
        XCTAssertEqual(scan2.eventCount, 1, "last-good 数据保持")
        let index2 = try loadScanIndex(fixture)
        XCTAssertEqual(index2.dailyBySession[sessionID]?[dayKey(0)]?.inputTokens, 33)
        XCTAssertEqual(index2.sessions[sessionID]?.fetchedAt, index1.sessions[sessionID]?.fetchedAt,
                       "未重读：fetchedAt 不更新")

        // 恢复读权限后，显式 hardFull 仍能重新读取并重建。
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: dbPath.path
        )
        let scan3 = try await runScan(fixture: fixture, now: now.addingTimeInterval(120), forceFull: true)
        XCTAssertEqual(scan3.failedSessionCount, 0)
        XCTAssertEqual(scan3.eventCount, 1)
    }

    // MARK: - 全程无网络请求

    /// scanner 的数据源是本地 `.db` 直读，整个 pipeline 没有任何网络注入点：
    /// - `performScanPureImpl` / `performScanPure` 已无 fetcher / metadataFetch
    ///   参数（编译期保证，本测试能调用即证明）；
    /// - 运行时断言：scanner 实例的存储属性里不存在任何 Fetcher / HTTP 依赖，
    ///   且零配置扫描合成 `.db` 全程成功。
    @MainActor
    func testScannerHasNoNetworkDependency() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try makeScanSessionDB(
            in: fixture,
            sessionID: "offline-session",
            turnStepIndexes: [1],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 9,
                         rawOutput: 4, reasoning: 1,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 1)
            ]
        )

        let scanner = AntigravityLocalUsageScanner(
            conversationsDirs: [fixture.conversations],
            cacheDir: fixture.cache,
            fileManager: FileManagerBox(fixture.fm),
            calendar: testCalendar,
            now: { self.dayStart(0).addingTimeInterval(3_600) }
        )
        var mirror: Mirror? = Mirror(reflecting: scanner)
        while let current = mirror {
            for child in current.children {
                let typeDescription = String(describing: type(of: child.value))
                XCTAssertFalse(
                    typeDescription.contains("Fetcher") || typeDescription.contains("URLSession"),
                    "scanner 存储属性不得持有网络依赖: \(child.label ?? "?") → \(typeDescription)"
                )
            }
            mirror = current.superclassMirror
        }

        let result = try await AntigravityLocalUsageScanner.performScanPure(
            conversationsDirs: [fixture.conversations],
            cacheDir: fixture.cache,
            fileManager: FileManagerBox(fixture.fm),
            calendar: testCalendar,
            now: { self.dayStart(0).addingTimeInterval(3_600) },
            startedGeneration: 1,
            scanner: scanner
        )
        XCTAssertEqual(result.failedSessionCount, 0)
        XCTAssertEqual(result.eventCount, 1, "零网络配置下直读成功（无 RPC、无进程发现）")
    }

    // MARK: - 0 字节 placeholder 自愈

    func testEmptyPlaceholderHealsLocallyWithPrivateCacheDir() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // Antigravity 会留下 0 字节 placeholder cascade：mtime 可能被 IDE
        // housekeeping 移动，但没有任何可读数据，只更新指纹、不读取。
        try Data().write(to: fixture.conversations.appendingPathComponent("placeholder.db"))

        let now = dayStart(0).addingTimeInterval(3_600)
        let result = try await runScan(fixture: fixture, now: now, forceFull: true)
        XCTAssertEqual(result.failedSessionCount, 0, "placeholder 不参与 probe")
        XCTAssertEqual(result.sessionCount, 1)

        let index = try loadScanIndex(fixture)
        XCTAssertEqual(index.sessions["placeholder"]?.eventCount, 0)
        XCTAssertEqual(index.samplesBySession?["placeholder"]?.count, 0)

        // 缓存目录权限与遗留物清理契约（自 AntigravityMetadataFetchTests 移入）。
        let cachePermissions = try fixture.fm.attributesOfItem(atPath: fixture.cache.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(cachePermissions?.intValue, 0o700, "Antigravity cache 根目录必须是 owner-only")
        XCTAssertFalse(
            fixture.fm.fileExists(atPath: fixture.cache.appendingPathComponent("rpc-cache").path),
            "正式 cache 只保留 index.json，不再创建未读取的 per-session JSONL 目录"
        )
    }

    // MARK: - 指纹正常变化的再入账

    func testFingerprintChangeTriggersFullReread() async throws {
        let fixture = try makeScanFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sessionID = "growing-session"
        let dbPath = try makeScanSessionDB(
            in: fixture,
            sessionID: sessionID,
            turnStepIndexes: [1],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 10,
                         rawOutput: 5, reasoning: 2,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 1)
            ]
        )
        let now = dayStart(0).addingTimeInterval(3_600)
        _ = try await runScan(fixture: fixture, now: now)

        // 懒刷新：IDE 关闭/切换会话时才把新 steps 落盘（文件增长 + WAL）。
        try makeScanSessionDB(
            in: fixture,
            sessionID: sessionID,
            turnStepIndexes: [1, 40],
            turnStartSeconds: fixtureBaseSeconds,
            calls: [
                CallSpec(stepIndex: 2, model: fixtureFlashModel, input: 10,
                         rawOutput: 5, reasoning: 2,
                         startSeconds: fixtureBaseSeconds, endSeconds: fixtureBaseSeconds + 1),
                CallSpec(stepIndex: 3, model: fixtureFlashModel, input: 15,
                         rawOutput: 6, reasoning: 2,
                         startSeconds: fixtureBaseSeconds + 30, endSeconds: fixtureBaseSeconds + 32),
                CallSpec(stepIndex: 41, model: fixtureArgonModel, input: 20,
                         rawOutput: 7, reasoning: 3,
                         startSeconds: fixtureBaseSeconds + 3_600, endSeconds: fixtureBaseSeconds + 3_662),
            ],
            at: dbPath
        )

        let scan2 = try await runScan(fixture: fixture, now: now.addingTimeInterval(60))
        XCTAssertEqual(scan2.failedSessionCount, 0)
        let index = try loadScanIndex(fixture)
        let day = try XCTUnwrap(index.dailyBySession[sessionID]?[dayKey(0)])
        XCTAssertEqual(day.inputTokens, 45, "全量重读整体替换日桶（10 → 10+15+20）")
        XCTAssertEqual(day.turns, 2)
        XCTAssertEqual(day.rounds, 3)
        XCTAssertEqual(index.sessions[sessionID]?.eventCount, 3)
    }
}
