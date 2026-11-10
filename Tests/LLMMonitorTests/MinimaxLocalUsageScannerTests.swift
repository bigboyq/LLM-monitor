import XCTest
import SQLite3
@testable import LLM_monitor

/// v2 本地用量扫描器（`MinimaxLocalUsageScanner`）：缓存恢复、日桶裁剪、degraded
/// 重试与恢复、字符分摊的安全过滤、缓存迁移、只读 v2 库与失败会话计数。
///
/// 拆自 `MinimaxV2UsageTests`（去版本号改名），逐字搬移零逻辑变化。
/// v2 DB 的构造 fixture 在 `MinimaxDBReaderTests.swift` 的文件作用域（同模块可见）。
final class MinimaxLocalUsageScannerTests: XCTestCase {

    func testMinimaxRestoresCachedUsageOnColdStart() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-prefill-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManagerBox()
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: now)
        let usage = MinimaxDailyUsage(
            dayStart: day, inputTokens: 10, outputTokens: 5,
            cacheReadTokens: 2, reasoningTokens: 1, totalTokens: 18,
            turns: 1, rounds: 2
        )
        let index = MinimaxLocalUsageScanner.CacheIndex(
            version: 21,
            lastScannedAt: now,
            sources: ["runtime": MinimaxLocalUsageScanner.SourceIndexEntry(
                mtimeMs: 1, sizeBytes: 2, walMtimeMs: 0, walSizeBytes: 0,
                scannedAt: now, eventCount: 2, sessionCount: 1
            )],
            dailyBySource: ["runtime": [LocalUsageDayKey.make(day, calendar: calendar): usage]],
            samplesBySource: nil,
            calendarSignature: LocalUsageCalendarSignature.make(calendar)
        )
        try MinimaxLocalUsageScanner.saveIndex(index, cacheDir: cacheDir, fileManager: fileManager)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let restored = try XCTUnwrap(
            MinimaxLocalUsageScanner.loadCachedResult(
                cacheDir: cacheDir,
                fileManager: fileManager,
                calendar: calendar,
                now: now
            )
        )
        XCTAssertEqual(restored.today, usage)
        XCTAssertEqual(restored.dailyTokenUsage.count, 7)
        XCTAssertEqual(restored.dailyTokenUsage.last, usage)
        XCTAssertEqual(restored.eventCount, 2)
        XCTAssertEqual(restored.sessionCount, 1)
        XCTAssertEqual(restored.scannedAt, now)
    }

    /// 卫生清理：写回 index 前裁剪严格早于 8 天窗口的日桶（与 samples 的
    /// `-LocalUsageRetentionWindow.seconds` 谓词同式）。构造含 10 天前桶的缓存且 source 指纹
    /// 新鲜（不 dirty、不走 SQL 聚合，dailyBySource 不会被整体替换），扫描后
    /// 旧桶被裁、7 天内的桶与 samples 不受影响、eventCount 不变。
    func testPrunesDailyBucketsOlderThanEightDayWindowOnSave() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-prune-\(UUID().uuidString)", isDirectory: true)
        let runtimeURL = root.appendingPathComponent("v2/runtime-state.sqlite")
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtimeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try Data(repeating: 4, count: 64).write(to: runtimeURL)
        defer { try? FileManager.default.removeItem(at: root) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let attributes = try FileManager.default.attributesOfItem(atPath: runtimeURL.path)
        let modifiedAt = try XCTUnwrap(attributes[.modificationDate] as? Date)
        let mtimeMs = modifiedAt.timeIntervalSince1970 * 1000
        let sizeBytes = try XCTUnwrap((attributes[.size] as? NSNumber)?.intValue)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldDayStart = try XCTUnwrap(
            calendar.date(byAdding: .day, value: -10, to: now).map { calendar.startOfDay(for: $0) }
        )
        let recentDayStart = try XCTUnwrap(
            calendar.date(byAdding: .day, value: -2, to: now).map { calendar.startOfDay(for: $0) }
        )
        let oldDayKey = LocalUsageDayKey.make(oldDayStart, calendar: calendar)
        let recentDayKey = LocalUsageDayKey.make(recentDayStart, calendar: calendar)

        let seededSample = LocalTokenUsageSample(
            completedAt: recentDayStart.addingTimeInterval(3_600),
            modelName: "MiniMax-M3",
            promptID: "runtime:turn-1",
            inputTokens: 9,
            cachedInputTokens: 0,
            outputTokens: 5,
            reasoningOutputTokens: 0
        )
        let index = MinimaxLocalUsageScanner.CacheIndex(
            version: 21,
            lastScannedAt: now.addingTimeInterval(-60),
            sources: ["runtime": MinimaxLocalUsageScanner.SourceIndexEntry(
                mtimeMs: mtimeMs,              // 新鲜指纹 → 不 dirty、不走 SQL
                sizeBytes: sizeBytes,
                walMtimeMs: 0,
                walSizeBytes: 0,
                scannedAt: now.addingTimeInterval(-60),
                eventCount: 3,
                sessionCount: 1
            )],
            dailyBySource: ["runtime": [
                oldDayKey: MinimaxDailyUsage(
                    dayStart: oldDayStart, inputTokens: 100, outputTokens: 50,
                    cacheReadTokens: 2, reasoningTokens: 1, totalTokens: 153,
                    turns: 2, rounds: 4
                ),
                recentDayKey: MinimaxDailyUsage(
                    dayStart: recentDayStart, inputTokens: 10, outputTokens: 5,
                    cacheReadTokens: 2, reasoningTokens: 1, totalTokens: 18,
                    turns: 1, rounds: 2
                )
            ]],
            samplesBySource: ["runtime": [seededSample]],
            calendarSignature: LocalUsageCalendarSignature.make(calendar)
        )
        try MinimaxLocalUsageScanner.saveIndex(index, cacheDir: cacheDir, fileManager: FileManagerBox())

        let result = try MinimaxLocalUsageScanner.performScanPureImpl(
            runtimeDBURL: runtimeURL,
            cacheDir: cacheDir,
            fileManager: FileManagerBox(),
            calendar: calendar,
            now: { now },
            shouldSave: true
        )

        let saved = try MinimaxLocalUsageScanner.loadIndex(cacheDir: cacheDir, fileManager: FileManagerBox())
        let byDay = try XCTUnwrap(saved.dailyBySource["runtime"])
        XCTAssertNil(byDay[oldDayKey], "10 天前的日桶必须在写回前被裁剪")
        XCTAssertEqual(byDay[recentDayKey]?.inputTokens, 10, "7 天内的日桶不受影响")
        XCTAssertEqual(
            saved.sources["runtime"]?.eventCount, 3,
            "eventCount 独立保存在 sources 条目里，不受日桶裁剪影响"
        )
        XCTAssertEqual(saved.samplesBySource?["runtime"]?.count, 1, "samples 不受日桶裁剪影响")

        // 消费面不受影响：7 天窗口仍包含保留桶，eventCount / samples 原样输出。
        XCTAssertEqual(result.failedSessionCount, 0)
        XCTAssertEqual(result.eventCount, 3)
        XCTAssertTrue(
            result.dailyTokenUsage.contains { $0.dayStart == recentDayStart && $0.inputTokens == 10 },
            "7 天窗口聚合必须保留未裁剪桶的数据"
        )
        XCTAssertEqual(result.recentSamples?.count, 1)
    }

    func testV2DegradedSourceIsRetriedAndRecovers() throws {
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        let databaseURL = try makeV2Database(
            tokenRows: [TokenRow(sessionID: "s", turnID: "uuid-turn", timestampMs: base,
                                 input: 100, output: 1000, reasoning: 0, cacheRead: 0, cacheWrite: 0, raw: nil)]
        )
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-v2-degraded-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: cacheDir)
        }
        try breakMessageTableSchema(at: databaseURL)

        let calendar = Calendar.current
        let fileManager = FileManagerBox()
        let scanOnce: () throws -> MinimaxLocalUsage = {
            try MinimaxLocalUsageScanner.performScanPureImpl(
                runtimeDBURL: databaseURL,
                cacheDir: cacheDir,
                fileManager: fileManager,
                calendar: calendar,
                now: { Date() },
                shouldSave: true
            )
        }

        #if DEBUG
        MinimaxDBReader.testCharAggregateAttempts = 0
        #endif
        _ = try scanOnce()

        // 第一次扫描：degraded 状态写入缓存指纹。
        let index1 = try MinimaxLocalUsageScanner.loadIndex(cacheDir: cacheDir, fileManager: fileManager)
        let entry1 = try XCTUnwrap(index1.sources["runtime"])
        XCTAssertEqual(entry1.charSplitDegraded, true, "degraded 必须写入 source entry 供下次重试判定")
        XCTAssertEqual(entry1.eventCount, 1, "主账本成功，event 数不丢")

        // db 完全不变：degraded source 仍必须强制重扫（重试语义）。
        _ = try scanOnce()
        #if DEBUG
        XCTAssertEqual(
            MinimaxDBReader.testCharAggregateAttempts, 2,
            "指纹未变化的 degraded source 也要重新尝试字符聚合"
        )
        #endif

        // 修复 schema（db mtime 变化）：重扫后恢复字符分摊并清除 degraded 标记。
        try repairMessageTableWithCharData(at: databaseURL, timestampMs: base)
        _ = try scanOnce()
        let index3 = try MinimaxLocalUsageScanner.loadIndex(cacheDir: cacheDir, fileManager: fileManager)
        let entry3 = try XCTUnwrap(index3.sources["runtime"])
        XCTAssertNotEqual(entry3.charSplitDegraded, true, "成功重聚合并完成字符分摊后必须清除 degraded 标记")

        let adjustedDay = try XCTUnwrap(index3.dailyBySource["runtime"]?.values.first)
        XCTAssertEqual(adjustedDay.reasoningTokens, 750, "30/(30+10) × 1000")
        XCTAssertEqual(adjustedDay.outputTokens, 250)
    }

    func testV2UnsafeCharacterRatioDropsOnlyMisalignedDay() {
        let day = Calendar.current.startOfDay(for: Date())
        let usage = MinimaxDailyUsage(dayStart: day, outputTokens: 100, rounds: 1)
        let aggregate = MinimaxDBAggregate(
            perDay: [day: usage],
            perDayChars: [day: MinimaxCharCounts(reason: 10, output: 10, messageCount: 3)],
            sessionCount: 1,
            eventCount: 1,
            turnCount: 1
        )

        let safe = MinimaxLocalUsageScanner.filterUnsafeV2CharCounts(
            aggregate: aggregate,
            ratioThreshold: 2
        )
        XCTAssertTrue(safe.isEmpty, "messageCount / rounds > 2 时必须跳过字符分摊")

        let aligned = MinimaxDBAggregate(
            perDay: [day: usage],
            perDayChars: [day: MinimaxCharCounts(reason: 10, output: 10, messageCount: 2)],
            sessionCount: 1,
            eventCount: 1,
            turnCount: 1
        )
        XCTAssertNotNil(
            MinimaxLocalUsageScanner.filterUnsafeV2CharCounts(
                aggregate: aligned,
                ratioThreshold: 2
            )[day]
        )
    }

    /// `applyReasoningSplit(samples:)` 重建 sample 时必须原样带回 durationSeconds
    /// / ttftSeconds：丢了会退化成 nil，该样本在窗口 tok/s / TTFT 统计的分子分母
    /// 里都不计，分母被算小。
    func testApplyReasoningSplitPreservesDurationSeconds() {
        let day = Calendar.current.startOfDay(for: Date())
        let sample = LocalTokenUsageSample(
            completedAt: day.addingTimeInterval(3_600),
            modelName: "MiniMax-M3",
            promptID: "s:turn-1",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 1000,
            reasoningOutputTokens: 0,
            durationSeconds: 12.5,
            ttftSeconds: 3.25
        )
        let rawPerDay = [day: MinimaxDailyUsage(dayStart: day, outputTokens: 1000)]
        let adjustedPerDay = [day: MinimaxDailyUsage(
            dayStart: day, outputTokens: 250, reasoningTokens: 750
        )]

        let split = MinimaxLocalUsageScanner.applyReasoningSplit(
            samples: [sample],
            perSampleCallSplits: [],
            rawPerDay: rawPerDay,
            adjustedPerDay: adjustedPerDay,
            calendar: .current
        )

        XCTAssertEqual(split.count, 1)
        XCTAssertEqual(split[0].reasoningOutputTokens, 750, "分摊比例按 per-day 750/1000")
        XCTAssertEqual(split[0].outputTokens, 250)
        XCTAssertEqual(split[0].durationSeconds, 12.5, "durationSeconds 必须原样保留")
        XCTAssertEqual(split[0].ttftSeconds, 3.25, "ttftSeconds 必须原样保留（reader 差分推导值，不再写 0）")
    }

    /// v19 调用级拆分：配对样本（`perSampleCallSplits` 非 nil）直接采用调用级
    /// 结果（不再吃日级大锅饭），未配对样本（nil）维持日级比例路径；诊断字段
    /// 两条路径都原样透传。
    func testApplyReasoningSplitSamplesUsesCallLevelSplitForPairedSamples() {
        let day = Calendar.current.startOfDay(for: Date())
        func sample(promptID: String, output: Int, duration: Double?) -> LocalTokenUsageSample {
            LocalTokenUsageSample(
                completedAt: day.addingTimeInterval(3_600),
                modelName: "MiniMax-M3",
                promptID: promptID,
                inputTokens: 100,
                cachedInputTokens: 0,
                outputTokens: output,
                reasoningOutputTokens: 0,
                durationSeconds: duration,
                ttftSeconds: 1.5
            )
        }
        let samples = [
            sample(promptID: "s:turn-a", output: 1000, duration: 12.5), // 配对
            sample(promptID: "s:turn-b", output: 400, duration: nil),   // 未配对
        ]
        let rawPerDay = [day: MinimaxDailyUsage(dayStart: day, outputTokens: 1400)]
        let adjustedPerDay = [day: MinimaxDailyUsage(
            dayStart: day, outputTokens: 650, reasoningTokens: 750
        )]

        let split = MinimaxLocalUsageScanner.applyReasoningSplit(
            samples: samples,
            perSampleCallSplits: [
                MinimaxCallSplit(reasoningTokens: 750, outputTokens: 250),
                nil,
            ],
            rawPerDay: rawPerDay,
            adjustedPerDay: adjustedPerDay,
            calendar: .current
        )

        XCTAssertEqual(split[0].reasoningOutputTokens, 750, "配对样本用调用级结果，不走日级比例")
        XCTAssertEqual(split[0].outputTokens, 250)
        XCTAssertEqual(split[0].durationSeconds, 12.5, "调用级重建同样必须原样保留 durationSeconds")
        XCTAssertEqual(split[0].ttftSeconds, 1.5)
        // 当天 reasoning 已全部分配给配对调用，未配对残余不再二次分配。
        XCTAssertEqual(split[1].reasoningOutputTokens, 0, "配对 reasoning 必须先从当日预算扣除")
        XCTAssertEqual(split[1].outputTokens, 400)
        XCTAssertNil(split[1].durationSeconds)
        XCTAssertEqual(split[1].ttftSeconds, 1.5)
    }

    /// daily = Σ 调用级 + 未配对残余（残余字符 = 日级字符 − 配对字符），守恒
    /// reason + output == 当天 raw output；totalTokens 同步重算保持字段和一致。
    func testApplyReasoningSplitDailyCombinesCallLevelAndResidualWithConservation() throws {
        let day = Calendar.current.startOfDay(for: Date())
        let usage = MinimaxDailyUsage(
            dayStart: day, inputTokens: 100, outputTokens: 1500,
            cacheReadTokens: 20, totalTokens: 1620, turns: 2, rounds: 2
        )
        // 日级字符含未配对行：残余 = (4000−3000, 2000−1000) = (1000, 1000)。
        let chars = MinimaxCharCounts(reason: 4000, output: 2000, messageCount: 2)
        // 配对调用覆盖账面 output 1000（reason 750 / output 250），字符 3000/1000。
        let paired = MinimaxPairedSplitDay(
            reasonTokens: 750, outputTokens: 250, thinkingChars: 3000, visibleChars: 1000
        )

        let adjusted = try XCTUnwrap(
            MinimaxLocalUsageScanner.applyReasoningSplit(
                perDay: [day: usage],
                perDayChars: [day: chars],
                pairedSplits: [day: paired]
            )[day]
        )

        // 残余 raw 500 × 50% → reason 250 / output 250；合计 750+250 / 250+250。
        XCTAssertEqual(adjusted.reasoningTokens, 1000)
        XCTAssertEqual(adjusted.outputTokens, 500)
        XCTAssertEqual(adjusted.reasoningTokens + adjusted.outputTokens, 1500, "守恒：== 当天 raw output")
        XCTAssertEqual(adjusted.totalTokens, 1620, "input 100 + cacheRead 20 + 500 + 1000")
    }

    /// 无字符数据（degraded / 被 P1-1 守门过滤）→ 残余分量记 0：reason 只含
    /// Σ 配对 reason，残余 raw 全记可见输出，仍然守恒。
    func testApplyReasoningSplitDailyResidualWithoutCharsKeepsPairedReasonOnly() throws {
        let day = Calendar.current.startOfDay(for: Date())
        let usage = MinimaxDailyUsage(dayStart: day, outputTokens: 1500, rounds: 2)
        let paired = MinimaxPairedSplitDay(
            reasonTokens: 750, outputTokens: 250, thinkingChars: 3000, visibleChars: 1000
        )

        let adjusted = try XCTUnwrap(
            MinimaxLocalUsageScanner.applyReasoningSplit(
                perDay: [day: usage],
                perDayChars: [:],
                pairedSplits: [day: paired]
            )[day]
        )

        XCTAssertEqual(adjusted.reasoningTokens, 750, "无残余字符 → 残余 reason 记 0，不猜")
        XCTAssertEqual(adjusted.outputTokens, 750)
        XCTAssertEqual(adjusted.reasoningTokens + adjusted.outputTokens, 1500, "守恒：== 当天 raw output")
    }

    /// 整天完全无配对 → 回退既有日级行为（与 v18 的纯日级字符路径逐字段一致）。
    func testApplyReasoningSplitDailyFallsBackToLegacyDayLevelWithoutPairedCalls() throws {
        let day = Calendar.current.startOfDay(for: Date())
        let usage = MinimaxDailyUsage(dayStart: day, outputTokens: 1000, rounds: 1)
        let chars = MinimaxCharCounts(reason: 3000, output: 1000, messageCount: 1)

        let adjusted = try XCTUnwrap(
            MinimaxLocalUsageScanner.applyReasoningSplit(
                perDay: [day: usage],
                perDayChars: [day: chars],
                pairedSplits: [:]
            )[day]
        )

        XCTAssertEqual(adjusted.reasoningTokens, 750, "3000/(3000+1000) × 1000，与旧日级行为一致")
        XCTAssertEqual(adjusted.outputTokens, 250)
        XCTAssertEqual(adjusted.reasoningTokens + adjusted.outputTokens, 1000)
    }

    /// 端到端：同一天里配对调用走调用级拆分、usage 核对不上的调用走未配对残余
    /// （日级字符差减），daily 守恒；samples 两路并存、时长只跟随配对样本。
    func testV2ScanSplitsReasoningAtCallLevelWithDayLevelResidual() throws {
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        let databaseURL = try makeV2Database(
            tokenRows: [
                TokenRow(sessionID: "s1", turnID: "turn-a", timestampMs: base,
                         input: 100, output: 1000, reasoning: 0, cacheRead: 0, cacheWrite: 0, raw: nil),
                TokenRow(sessionID: "s1", turnID: "turn-b", timestampMs: base + 1_000,
                         input: 100, output: 500, reasoning: 0, cacheRead: 0, cacheWrite: 0, raw: nil),
            ],
            messageRows: [
                // turn-a 配对成功：thinking 3000 / msg 1000 → reason 750 / output 250。
                MessageRow(sessionID: "s1", messageID: "m1", timestampMs: base + 10,
                           data: assistantUsageJSON(input: 100, output: 1000, durationMs: 5_000,
                                                    thinkingChars: 3000, msgChars: 1000),
                           turnID: "turn-a"),
                // turn-b usage 核对不上（999/999）→ 未配对；其字符 1000/1000 留在
                // 日级聚合，成为残余的字符侧输入。
                MessageRow(sessionID: "s1", messageID: "m2", timestampMs: base + 1_010,
                           data: assistantUsageJSON(input: 999, output: 999, durationMs: 6_000,
                                                    thinkingChars: 1000, msgChars: 1000),
                           turnID: "turn-b"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-callsplit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let result = try MinimaxLocalUsageScanner.performScanPureImpl(
            runtimeDBURL: databaseURL,
            cacheDir: cacheDir,
            fileManager: FileManagerBox(),
            calendar: .current,
            now: { Date(timeIntervalSince1970: Double(base) / 1000) },
            shouldSave: true
        )

        // daily：paired (750/250) + 残余 raw 500 × 字符 (1000,1000) 的 50% = (250/250)
        // → reason 1000 / output 500，守恒 1000 + 500 == raw 1500。
        let today = try XCTUnwrap(result.today)
        XCTAssertEqual(today.reasoningTokens, 1000)
        XCTAssertEqual(today.outputTokens, 500)
        XCTAssertEqual(today.inputTokens, 200)
        XCTAssertEqual(today.totalTokens, 1700, "input 200 + output 500 + reason 1000")

        // samples：turn-a 调用级精确；turn-b 只分配残余 reasoning250。
        let samples = try XCTUnwrap(result.recentSamples)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].reasoningOutputTokens, 750)
        XCTAssertEqual(samples[0].outputTokens, 250)
        XCTAssertEqual(samples[0].durationSeconds, 5.0, "调用级重建不丢时长")
        XCTAssertEqual(samples[1].reasoningOutputTokens, 250, "未配对样本使用扣除配对调用后的残余预算")
        XCTAssertEqual(samples[1].outputTokens, 250)
        XCTAssertNil(samples[1].durationSeconds, "未配对 → 无时长")
    }

    /// MiniMax Code 的 TTFT 由 `$.usage` 的 `request_duration_ms −
    /// decode_duration_ms` 差分推导（总耗时减纯解码 = 首字等待），与
    /// durationSeconds 走同一套 FIFO 配对 + token 核对；decode 缺失或差值为
    /// 负 → nil（不再显式写 0），字符分摊重建不丢该字段，缓存版本钉 19。
    func testMiniMaxSamplesCarryDifferentialTTFT() throws {
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        let databaseURL = try makeV2Database(
            tokenRows: [
                TokenRow(sessionID: "s-ttft", turnID: "turn-ok", timestampMs: base,
                         input: 100, output: 50, reasoning: 0, cacheRead: 0, cacheWrite: 0, raw: nil),
                TokenRow(sessionID: "s-ttft", turnID: "turn-nodecode", timestampMs: base + 1_000,
                         input: 200, output: 80, reasoning: 0, cacheRead: 0, cacheWrite: 0, raw: nil),
            ],
            messageRows: [
                // 正常差分：12345 − 4567 = 7778ms → 7.778s。
                MessageRow(sessionID: "s-ttft", messageID: "m1", timestampMs: base + 10,
                           data: assistantUsageJSON(input: 100, output: 50, durationMs: 12_345, decodeMs: 4_567),
                           turnID: "turn-ok"),
                // decode_duration_ms 缺失 → nil。
                MessageRow(sessionID: "s-ttft", messageID: "m2", timestampMs: base + 1_010,
                           data: assistantUsageJSON(input: 200, output: 80, durationMs: 9_000),
                           turnID: "turn-nodecode"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-ttft-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let result = try MinimaxLocalUsageScanner.performScanPureImpl(
            runtimeDBURL: databaseURL,
            cacheDir: cacheDir,
            fileManager: FileManagerBox(),
            calendar: .current,
            now: { Date(timeIntervalSince1970: Double(base) / 1000) },
            shouldSave: true
        )
        let samples = try XCTUnwrap(result.recentSamples)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].ttftSeconds, 7.778, "reader 构造点差分推导：(12345 − 4567) / 1000")
        XCTAssertNil(samples[1].ttftSeconds, "decode_duration_ms 缺失 → nil（不再写 0）")

        // 字符分摊重建构造点：ttftSeconds 与 durationSeconds 一样原样透传。
        let day = Calendar.current.startOfDay(for: samples[0].completedAt)
        let rebuilt = MinimaxLocalUsageScanner.applyReasoningSplit(
            samples: samples,
            perSampleCallSplits: [],
            rawPerDay: [day: MinimaxDailyUsage(dayStart: day, outputTokens: 130)],
            adjustedPerDay: [day: MinimaxDailyUsage(dayStart: day, outputTokens: 100, reasoningTokens: 30)],
            calendar: .current
        )
        XCTAssertEqual(rebuilt.count, 2)
        XCTAssertEqual(rebuilt[0].ttftSeconds, 7.778, "重建样本 ttftSeconds 原样保留")
        XCTAssertNil(rebuilt[1].ttftSeconds, "重建样本 ttftSeconds 的 nil 同样保留")

        // 缓存版本钉 21：修复残余 reasoning 分配后必须让旧缓存全量重建。
        let saved = try MinimaxLocalUsageScanner.loadIndex(cacheDir: cacheDir, fileManager: FileManagerBox())
        XCTAssertEqual(saved.version, 21)
    }

    func testV2CacheMigrationResetsLegacySourceData() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-v2-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let day = Calendar.current.startOfDay(for: Date())
        let old = MinimaxLocalUsageScanner.CacheIndex(
            version: 11,
            lastScannedAt: day,
            sources: [:],
            dailyBySource: ["main": ["legacy": MinimaxDailyUsage(dayStart: day, inputTokens: 999)]],
            samplesBySource: nil
        )
        try ScannerIndexIO.saveIndex(old, cacheDir: cacheDir, fileManager: FileManagerBox())

        let current = try MinimaxLocalUsageScanner.loadIndex(
            cacheDir: cacheDir,
            fileManager: FileManagerBox()
        )
        XCTAssertEqual(current.version, 21)
        XCTAssertTrue(current.sources.isEmpty)
        XCTAssertTrue(current.dailyBySource.isEmpty)
        XCTAssertEqual(current.samplesBySource, [:])
    }

    func testScannerReadsOnlyRuntimeDatabaseEvenWhenSiblingLegacyDatabaseExists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("minimax-v2-only-\(UUID().uuidString)", isDirectory: true)
        let runtimeURL = root.appendingPathComponent("v2/runtime-state.sqlite")
        let legacyURL = root.appendingPathComponent("sqlite.db")
        let cacheDir = root.appendingPathComponent("cache")
        let base = Int64(Date().timeIntervalSince1970 * 1000)
        let runtime = try makeV2Database(
            at: runtimeURL,
            tokenRows: [TokenRow(sessionID: "runtime", turnID: "t", timestampMs: base,
                                 input: 7, output: 11, reasoning: 0, cacheRead: 0, cacheWrite: 0, raw: nil)]
        )
        defer {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(at: legacyURL)
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var legacyDatabase: OpaquePointer?
        XCTAssertEqual(sqlite3_open(legacyURL.path, &legacyDatabase), SQLITE_OK)
        if let legacyDatabase {
            defer { sqlite3_close(legacyDatabase) }
            try execute(
                "CREATE TABLE token_usage (session_id TEXT, turn_id TEXT, ts INTEGER, input_tokens INTEGER, output_tokens INTEGER); INSERT INTO token_usage VALUES ('legacy', 'legacy-turn', "
                    + String(base)
                    + ", 999999, 999999);",
                database: legacyDatabase
            )
        }

        let result = try MinimaxLocalUsageScanner.performScanPureImpl(
            runtimeDBURL: runtimeURL,
            cacheDir: cacheDir,
            fileManager: FileManagerBox(),
            calendar: .current,
            now: { Date(timeIntervalSince1970: Double(base) / 1000) },
            shouldSave: true
        )
        XCTAssertEqual(result.eventCount, 1)
        XCTAssertEqual(result.sessionCount, 1)
        XCTAssertEqual(result.today?.inputTokens, 7)
        XCTAssertNotEqual(result.today?.inputTokens, 999999)
    }

    // MARK: - 失败会话计数（自 UsableAPIKeyHealthLevelTests 解散归入）

    func testComputeFailedSessionCountRules() {
        XCTAssertEqual(MinimaxLocalUsageScanner.computeFailedSessionCount(failedKeys: [], currentSourceKeys: [], cachedSourceKeys: []), 0)
        XCTAssertEqual(MinimaxLocalUsageScanner.computeFailedSessionCount(failedKeys: [], currentSourceKeys: ["main", "runtime"], cachedSourceKeys: []), 2)
        XCTAssertEqual(MinimaxLocalUsageScanner.computeFailedSessionCount(failedKeys: ["main"], currentSourceKeys: ["main", "runtime"], cachedSourceKeys: ["main", "runtime"]), 1)
        XCTAssertEqual(MinimaxLocalUsageScanner.computeFailedSessionCount(failedKeys: ["main", "runtime"], currentSourceKeys: ["main", "runtime", "extra"], cachedSourceKeys: ["extra"]), 2)
    }
}
