import XCTest
@testable import LLM_monitor

/// 落盘前「保留窗口」的统一口径契约（`LocalUsageRetentionWindow`）。
///
/// 背景：五个本地 scanner（Antigravity / Minimax / GLM-Zcode / OpenCode / DSH）
/// 各自把「最近 8 天」之外的日聚合 / 样本裁掉再写缓存，这 8 天原先在每个文件里
/// 各写一遍裸字面量，口径漂移无从察觉。现在统一引用常量，本文件锁定：
/// - 常量本身仍是 8 天（防手滑改口径）；
/// - 每个 scanner 的裁剪入口对同一组时间戳给出同一裁决。
///
/// **与展示层的 7 天窗口无关**：`DailyUsageAggregation.filterLast7Days` 是 UI
/// 只画最近 7 天；这里是落盘保留范围（8 = 7 展示 + 1 采样余量）。
final class ScannerRetentionContractTests: XCTestCase {

    // MARK: - fixture

    /// 基准时刻：UTC 2026-03-15 12:00。选正午是为了让 `startOfDay` 派生的两个
    /// 桶在「按秒的 cutoff（now - 8 天）」和「按日历天的 cutoff（今 0 点 - 7 天）」
    /// 两种实现下都落在同一侧，两种口径可以共用同一组 fixture。
    private static let now = Date(timeIntervalSince1970: 1_773_576_000)

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    /// 窗口内的一天（距 now 7.5 天）：所有裁剪入口都必须保留。
    private var insideDayStart: Date {
        calendar.startOfDay(for: Self.now.addingTimeInterval(-6.5 * 24 * 60 * 60))
    }

    /// 窗口外的一天（距 now 9.5 天）：所有裁剪入口都必须裁掉。
    private var outsideDayStart: Date {
        calendar.startOfDay(for: Self.now.addingTimeInterval(-9.5 * 24 * 60 * 60))
    }

    private func dayKey(_ dayStart: Date) -> String {
        LocalUsageDayKey.make(dayStart, calendar: calendar)
    }

    private func sample(_ completedAt: Date, id: String) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: completedAt,
            modelName: "model",
            promptID: id,
            inputTokens: 1,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0
        )
    }

    // MARK: - 常量本身

    /// 口径锁：改成 7（与展示窗口混同）或 9（无谓扩大缓存）都会红。
    func testRetentionWindowConstantLocksEightDays() {
        XCTAssertEqual(LocalUsageRetentionWindow.days, 8, "落盘保留窗口必须是 8 天（7 天展示 + 1 天采样余量）")
        XCTAssertEqual(
            LocalUsageRetentionWindow.seconds, 8 * 24 * 60 * 60,
            "seconds 换算必须与 days 一致"
        )
    }

    // MARK: - 逐 scanner：日桶裁剪入口

    /// Antigravity：写回 index 前裁 `dailyBySession` 里早于窗口的日桶。
    func testAntigravityDailyBucketPruneMatchesRetentionWindow() {
        var index = AntigravityLocalUsageScanner.CacheIndex(
            version: 7,
            lastScannedAt: Self.now,
            sessions: ["s": .init(
                mtimeMs: 0, sizeBytes: 0, walMtimeMs: 0, walSizeBytes: 0,
                fetchedAt: Self.now, eventCount: 1, generatorMetadataOffset: 0
            )],
            dailyBySession: ["s": [
                dayKey(insideDayStart): AntigravityDailyUsage(dayStart: insideDayStart, inputTokens: 10, totalTokens: 10),
                dayKey(outsideDayStart): AntigravityDailyUsage(dayStart: outsideDayStart, inputTokens: 20, totalTokens: 20)
            ]],
            samplesBySession: nil
        )

        AntigravityLocalUsageScanner.pruneStaleDailyBuckets(index: &index, now: Self.now)

        let kept = try? XCTUnwrap(index.dailyBySession["s"])
        XCTAssertNotNil(kept?[dayKey(insideDayStart)], "8 天内的日桶必须保留")
        XCTAssertNil(kept?[dayKey(outsideDayStart)], "9 天前的日桶必须裁掉")
    }

    /// Minimax：同上，裁 `dailyBySource`。
    func testMinimaxDailyBucketPruneMatchesRetentionWindow() {
        var index = MinimaxLocalUsageScanner.CacheIndex(
            version: 14,
            lastScannedAt: Self.now,
            sources: ["runtime": MinimaxLocalUsageScanner.SourceIndexEntry(
                mtimeMs: 0, sizeBytes: 0, walMtimeMs: 0, walSizeBytes: 0,
                scannedAt: Self.now, eventCount: 1, sessionCount: 1
            )],
            dailyBySource: ["runtime": [
                dayKey(insideDayStart): MinimaxDailyUsage(dayStart: insideDayStart, inputTokens: 10, totalTokens: 10),
                dayKey(outsideDayStart): MinimaxDailyUsage(dayStart: outsideDayStart, inputTokens: 20, totalTokens: 20)
            ]],
            samplesBySource: nil
        )

        MinimaxLocalUsageScanner.pruneStaleDailyBuckets(index: &index, now: Self.now)

        let kept = try? XCTUnwrap(index.dailyBySource["runtime"])
        XCTAssertNotNil(kept?[dayKey(insideDayStart)], "8 天内的日桶必须保留")
        XCTAssertNil(kept?[dayKey(outsideDayStart)], "9 天前的日桶必须裁掉")
    }

    // MARK: - 逐 scanner：样本裁剪入口

    /// DSH：全量扫描与 rebase 共用的 `boundedRecentSamples`（按日历天，规避 DST）。
    func testDshRecentSampleWindowMatchesRetentionWindow() throws {
        let bounded = DshLocalUsageScanner.boundedRecentSamples(
            [
                sample(insideDayStart, id: "inside"),
                sample(outsideDayStart, id: "outside")
            ],
            calendar: calendar,
            now: Self.now,
            maxCount: 100
        )

        XCTAssertEqual(bounded.map(\.promptID), ["inside"], "8 天内的样本保留，9 天前的裁掉")
    }

    /// OpenCode：跨午夜 rebase 时把样本窗口向前滚动。
    func testOpencodeRebaseSampleWindowMatchesRetentionWindow() {
        let snapshot = OpencodeLocalUsage(
            byProvider: ["p": OpencodeProviderUsage(
                today: nil,
                dailyTokenUsage: [],
                roundCount: 0,
                recentSamples: [
                    sample(insideDayStart, id: "inside"),
                    sample(outsideDayStart, id: "outside")
                ]
            )],
            modelsByProvider: [:],
            dbPath: nil,
            scannedAt: Self.now
        )

        let rebased = OpencodeUsageScanner.rebaseCachedSnapshot(
            snapshot, calendar: calendar, now: Self.now
        )

        XCTAssertEqual(
            rebased.byProvider["p"]?.recentSamples.map(\.promptID), ["inside"],
            "8 天内的样本保留，9 天前的裁掉"
        )
    }

    /// GLM-Zcode：主快照的样本窗口。
    func testGlmZcodeRebaseSampleWindowMatchesRetentionWindow() {
        let snapshot = GlmLocalUsage(
            today: nil,
            dailyTokenUsage: [],
            scannedAt: Self.now,
            sessionCount: 0,
            eventCount: 0,
            failedSessionCount: 0,
            recentSamples: [
                sample(insideDayStart, id: "inside"),
                sample(outsideDayStart, id: "outside")
            ]
        )

        let rebased = GlmZcodeLocalUsageScanner.rebaseCachedSnapshot(
            snapshot, calendar: calendar, now: Self.now
        )

        XCTAssertEqual(
            rebased.recentSamples?.map(\.promptID), ["inside"],
            "8 天内的样本保留，9 天前的裁掉"
        )
    }

    /// GLM-Zcode：非智谱 provider 分片（minimax / deepseek）的样本窗口与主快照同口径。
    func testGlmZcodeProviderSliceSampleWindowMatchesRetentionWindow() throws {
        let rebased = GlmZcodeLocalUsageScanner.rebaseProviderSlices(
            ["deepseek": OpencodeProviderUsage(
                today: nil,
                dailyTokenUsage: [],
                roundCount: 0,
                recentSamples: [
                    sample(insideDayStart, id: "inside"),
                    sample(outsideDayStart, id: "outside")
                ]
            )],
            calendar: calendar,
            now: Self.now
        )

        let slice = try XCTUnwrap(rebased?["deepseek"])
        XCTAssertEqual(slice.recentSamples.map(\.promptID), ["inside"], "8 天内的样本保留，9 天前的裁掉")
    }

    // MARK: - 共享语义：所有入口对同一组时间戳给出同一裁决

    /// 参数化汇总：把同一组 fixture 喂给全部 7 个裁剪入口，任一入口改口径
    /// （或退回裸字面量 8 却与常量脱钩）都会在这条上暴露。
    func testEveryScannerCutoffAgreesOnTheSameTwoTimestamps() throws {
        let verdicts: [(scanner: String, keptInside: Bool, keptOutside: Bool)] = [
            ("Antigravity.pruneStaleDailyBuckets",
             antigravityKeepsInside(), antigravityKeepsOutside()),
            ("Minimax.pruneStaleDailyBuckets",
             minimaxKeepsInside(), minimaxKeepsOutside()),
            ("Dsh.boundedRecentSamples",
             dshKeepsInside(), dshKeepsOutside()),
            ("OpenCode.rebaseCachedSnapshot",
             opencodeKeepsInside(), opencodeKeepsOutside()),
            ("GlmZcode.rebaseCachedSnapshot",
             glmKeepsInside(), glmKeepsOutside()),
            ("GlmZcode.rebaseProviderSlices",
             glmSliceKeepsInside(), glmSliceKeepsOutside())
        ]

        for verdict in verdicts {
            XCTAssertTrue(verdict.keptInside, "\(verdict.scanner)：8 天内的数据必须保留")
            XCTAssertFalse(verdict.keptOutside, "\(verdict.scanner)：9 天前的数据必须裁掉")
        }
    }

    private func antigravityKeepsInside() -> Bool { antigravityKeeps(insideDayStart) }
    private func antigravityKeepsOutside() -> Bool { antigravityKeeps(outsideDayStart) }

    private func antigravityKeeps(_ dayStart: Date) -> Bool {
        var index = AntigravityLocalUsageScanner.CacheIndex(
            version: 7,
            lastScannedAt: Self.now,
            sessions: [:],
            dailyBySession: ["s": [dayKey(dayStart): AntigravityDailyUsage(dayStart: dayStart)]],
            samplesBySession: nil
        )
        AntigravityLocalUsageScanner.pruneStaleDailyBuckets(index: &index, now: Self.now)
        return index.dailyBySession["s"]?[dayKey(dayStart)] != nil
    }

    private func minimaxKeepsInside() -> Bool { minimaxKeeps(insideDayStart) }
    private func minimaxKeepsOutside() -> Bool { minimaxKeeps(outsideDayStart) }

    private func minimaxKeeps(_ dayStart: Date) -> Bool {
        var index = MinimaxLocalUsageScanner.CacheIndex(
            version: 14,
            lastScannedAt: Self.now,
            sources: [:],
            dailyBySource: ["runtime": [dayKey(dayStart): MinimaxDailyUsage(dayStart: dayStart)]],
            samplesBySource: nil
        )
        MinimaxLocalUsageScanner.pruneStaleDailyBuckets(index: &index, now: Self.now)
        return index.dailyBySource["runtime"]?[dayKey(dayStart)] != nil
    }

    private func dshKeepsInside() -> Bool { dshKeeps(insideDayStart) }
    private func dshKeepsOutside() -> Bool { dshKeeps(outsideDayStart) }

    private func dshKeeps(_ dayStart: Date) -> Bool {
        DshLocalUsageScanner.boundedRecentSamples(
            [sample(dayStart, id: "probe")], calendar: calendar, now: Self.now, maxCount: 10
        ).count == 1
    }

    private func opencodeKeepsInside() -> Bool { opencodeKeeps(insideDayStart) }
    private func opencodeKeepsOutside() -> Bool { opencodeKeeps(outsideDayStart) }

    private func opencodeKeeps(_ dayStart: Date) -> Bool {
        let snapshot = OpencodeLocalUsage(
            byProvider: ["p": OpencodeProviderUsage(
                today: nil, dailyTokenUsage: [], roundCount: 0,
                recentSamples: [sample(dayStart, id: "probe")]
            )],
            modelsByProvider: [:], dbPath: nil, scannedAt: Self.now
        )
        return OpencodeUsageScanner.rebaseCachedSnapshot(snapshot, calendar: calendar, now: Self.now)
            .byProvider["p"]?.recentSamples.count == 1
    }

    private func glmKeepsInside() -> Bool { glmKeeps(insideDayStart) }
    private func glmKeepsOutside() -> Bool { glmKeeps(outsideDayStart) }

    private func glmKeeps(_ dayStart: Date) -> Bool {
        let snapshot = GlmLocalUsage(
            today: nil, dailyTokenUsage: [], scannedAt: Self.now,
            sessionCount: 0, eventCount: 0, failedSessionCount: 0,
            recentSamples: [sample(dayStart, id: "probe")]
        )
        return GlmZcodeLocalUsageScanner.rebaseCachedSnapshot(snapshot, calendar: calendar, now: Self.now)
            .recentSamples?.count == 1
    }

    private func glmSliceKeepsInside() -> Bool { glmSliceKeeps(insideDayStart) }
    private func glmSliceKeepsOutside() -> Bool { glmSliceKeeps(outsideDayStart) }

    private func glmSliceKeeps(_ dayStart: Date) -> Bool {
        let slices: [String: OpencodeProviderUsage] = [
            "deepseek": OpencodeProviderUsage(
                today: nil, dailyTokenUsage: [], roundCount: 0,
                recentSamples: [sample(dayStart, id: "probe")]
            )
        ]
        return GlmZcodeLocalUsageScanner.rebaseProviderSlices(slices, calendar: calendar, now: Self.now)?
            .values.first?.recentSamples.count == 1
    }
}
