import XCTest
@testable import LLM_monitor

/// Codex 额度窗口切分（`makeUsageWindows`）与本地用量摘要
/// （`summarizeLocalUsage`）。
/// 拆自 `CodexLocalUsageTests`，逐字搬移零逻辑变化。
final class CodexUsageWindowTests: XCTestCase {

    private func makeModel(
        intervalReset: Date?,
        intervalWindow: Int?,
        weeklyReset: Date? = nil,
        weeklyWindow: Int? = nil
    ) -> ModelQuota {
        ModelQuota(
            modelName: "chatgpt_plan",
            intervalTotalCount: 1_000,
            intervalUsageCount: 100,
            intervalRemainingPercent: 90,
            intervalStatus: intervalReset == nil ? .absent : .present,
            intervalResetsAt: intervalReset,
            intervalWindowSeconds: intervalWindow,
            weeklyTotalCount: 7_000,
            weeklyUsageCount: 500,
            weeklyRemainingPercent: 90,
            weeklyStatus: weeklyReset == nil ? .absent : .present,
            weeklyResetsAt: weeklyReset,
            weeklyWindowSeconds: weeklyWindow
        )
    }

    func testMakeUsageWindowsUsesServerWindowDurations() throws {
        let reset = Date(timeIntervalSince1970: 10_000)
        let model = makeModel(
            intervalReset: reset,
            intervalWindow: 1_800,
            weeklyReset: reset.addingTimeInterval(10_000),
            weeklyWindow: 7_200
        )

        let windows = CodexFetcher.makeUsageWindows(from: model)
        XCTAssertEqual(windows["primary"]?.startDate, reset.addingTimeInterval(-1_800))
        XCTAssertEqual(windows["primary"]?.resetDate, reset)
        XCTAssertEqual(windows["secondary"]?.startDate, reset.addingTimeInterval(10_000 - 7_200))
    }

    func testMakeUsageWindowsWithNilModelReturnsEmpty() {
        // quota 首胜前没有模型数据：窗口定义缺省，但不阻塞本地扫描
        XCTAssertTrue(CodexFetcher.makeUsageWindows(from: nil).isEmpty)
    }

    /// 回归网：周窗口 present 但 `weeklyResetsAt=nil`（各 fetcher 对缺 reset
    /// 时间透传 nil）时，本地分桶不得为 secondary 窗口合成 reset 边界 ——
    /// 合成边界会把 startDate 钉在本次抓取时刻，把窗口用量压成接近 0 的假数，
    /// 且每次刷新边界前移、数字持续漂移。此时 secondary 窗口整体缺省（诚实
    /// "无数据"），仅 primary 参与聚合。
    func testMakeUsageWindowsSkipsSecondaryWindowWhenWeeklyResetIsMissing() {
        let reset = Date(timeIntervalSince1970: 10_000)
        let model = ModelQuota(
            modelName: "chatgpt_plan",
            intervalTotalCount: 1_000,
            intervalUsageCount: 100,
            intervalRemainingPercent: 90,
            intervalStatus: .present,
            intervalResetsAt: reset,
            intervalWindowSeconds: 1_800,
            weeklyTotalCount: 7_000,
            weeklyUsageCount: 500,
            weeklyRemainingPercent: 90,
            weeklyStatus: .present,
            weeklyResetsAt: nil,
            weeklyWindowSeconds: 7 * 24 * 60 * 60
        )

        let windows = CodexFetcher.makeUsageWindows(from: model)
        XCTAssertEqual(windows["primary"]?.resetDate, reset)
        XCTAssertNil(windows["secondary"], "weeklyResetsAt=nil 时不得合成 secondary 窗口边界")
        XCTAssertEqual(Set(windows.keys), ["primary"], "仅 primary 参与聚合，不产出合成的假数")
    }

    func testSummarizeLocalUsageWithoutWindowsStillProducesDaily() throws {
        // LocalUsage 与额度解耦：无 reset 时间（windows 为空）时，daily
        // 是纯本地信息照常产出，仅窗口用量（usageSummaries）缺省。
        let base = Date(timeIntervalSince1970: 24_000)
        let fileURL = URL(fileURLWithPath: "/tmp/codex-local-no-window-test.jsonl")
        let events: [CodexSessionEvent] = [
            .taskStarted(timestamp: base, turnID: "turn-a"),
            .tokenCount(
                timestamp: base.addingTimeInterval(10),
                usage: CodexTokenUsageEvent(inputTokens: 10, cachedInputTokens: 2, outputTokens: 5, reasoningOutputTokens: 1)
            ),
            .taskCompleted(timestamp: base.addingTimeInterval(20), turnID: "turn-a")
        ]
        let files = [CodexSessionFileEvents(fileURL: fileURL, events: events)]
        let daily = [CodexFetcher.DailyUsageWindow(
            startDate: base.addingTimeInterval(-1),
            endDate: base.addingTimeInterval(60)
        )]

        let result = CodexFetcher.summarizeLocalUsage(
            windows: [:],
            dailyWindows: daily,
            sessionFiles: files
        )

        XCTAssertTrue(result.usageSummaries.isEmpty)
        XCTAssertEqual(result.dailyTokenUsage.first?.turns, 1)
        XCTAssertEqual(result.dailyTokenUsage.first?.inputTokens, 10)
        XCTAssertEqual(result.scannedFileCount, 1)
    }

    func testSummarizeLocalUsageSplitsQuotaAndDailyWindows() throws {
        let base = Date(timeIntervalSince1970: 20_000)
        let fileURL = URL(fileURLWithPath: "/tmp/codex-local-usage-test.jsonl")
        let events: [CodexSessionEvent] = [
            .taskStarted(timestamp: base, turnID: "turn-1"),
            .tokenCount(
                timestamp: base.addingTimeInterval(10),
                usage: CodexTokenUsageEvent(inputTokens: 10, cachedInputTokens: 2, outputTokens: 5, reasoningOutputTokens: 1)
            ),
            .taskCompleted(timestamp: base.addingTimeInterval(20), turnID: "turn-1"),
            .taskStarted(timestamp: base.addingTimeInterval(30), turnID: "turn-2"),
            .tokenCount(
                timestamp: base.addingTimeInterval(40),
                usage: CodexTokenUsageEvent(inputTokens: 20, cachedInputTokens: 4, outputTokens: 8, reasoningOutputTokens: 2)
            ),
            .taskCompleted(timestamp: base.addingTimeInterval(50), turnID: "turn-2")
        ]
        let files = [CodexSessionFileEvents(fileURL: fileURL, events: events)]
        let windows = [
            "primary": CodexFetcher.ActiveUsageWindow(
                startDate: base.addingTimeInterval(-1),
                resetDate: base.addingTimeInterval(60)
            )
        ]
        let daily = [CodexFetcher.DailyUsageWindow(
            startDate: base.addingTimeInterval(-1),
            endDate: base.addingTimeInterval(60)
        )]

        let result = CodexFetcher.summarizeLocalUsage(
            windows: windows,
            dailyWindows: daily,
            sessionFiles: files
        )

        let summary = try XCTUnwrap(result.usageSummaries["primary"])
        XCTAssertEqual(summary.prompts, 2)
        XCTAssertEqual(summary.rounds, 2)
        XCTAssertEqual(summary.inputTokens, 30)
        XCTAssertEqual(summary.cachedInputTokens, 6)
        XCTAssertEqual(summary.outputTokens, 13)
        XCTAssertEqual(summary.reasoningOutputTokens, 3)
        XCTAssertEqual(result.dailyTokenUsage.first?.turns, 2)
        XCTAssertEqual(result.scannedFileCount, 1)
    }

    func testSummarizeLocalUsageClampsCachedWhenCacheExceedsInput() throws {
        // Codex 日志损坏：cached > input（损坏 cache 字段大于真实 input）。
        // `MutableUsageSummary` 在累加时不做 clamp（保留中间值），freeze 时才 clamp
        // 到 `min(cached, input)`，避免下游 cache hit rate > 100%。
        let base = Date(timeIntervalSince1970: 22_000)
        let fileURL = URL(fileURLWithPath: "/tmp/codex-local-cache-clamp-test.jsonl")
        let events: [CodexSessionEvent] = [
            .taskStarted(timestamp: base, turnID: "turn-clamp"),
            // input=50, cached=200（损坏）, output=10, reasoning=2
            .tokenCount(
                timestamp: base.addingTimeInterval(1),
                usage: CodexTokenUsageEvent(
                    inputTokens: 50,
                    cachedInputTokens: 200,
                    outputTokens: 10,
                    reasoningOutputTokens: 2
                )
            ),
            .taskCompleted(timestamp: base.addingTimeInterval(2), turnID: "turn-clamp")
        ]
        let files = [CodexSessionFileEvents(fileURL: fileURL, events: events)]
        let result = CodexFetcher.summarizeLocalUsage(
            windows: ["primary": CodexFetcher.ActiveUsageWindow(
                startDate: base.addingTimeInterval(-1),
                resetDate: base.addingTimeInterval(60)
            )],
            dailyWindows: [CodexFetcher.DailyUsageWindow(
                startDate: base.addingTimeInterval(-1),
                endDate: base.addingTimeInterval(60)
            )],
            sessionFiles: files
        )

        let summary = try XCTUnwrap(result.usageSummaries["primary"])
        // 累加阶段不 clamp（cached=200），freeze 时才 clamp 到 min(cached, input)=50
        XCTAssertEqual(summary.inputTokens, 50)
        XCTAssertEqual(summary.cachedInputTokens, 50, "cached 必须 clamp 到 input，避免 cache hit rate > 100%")
        XCTAssertEqual(summary.outputTokens, 10)
        XCTAssertEqual(summary.reasoningOutputTokens, 2)
    }

    func testSummarizeLocalUsageCarriesCodexModelIntoRecentSamples() throws {
        let base = Date(timeIntervalSince1970: 21_000)
        let fileURL = URL(fileURLWithPath: "/tmp/codex-local-model-test.jsonl")
        let events: [CodexSessionEvent] = [
            .modelContext(timestamp: base, modelName: "gpt-5.6-sol"),
            .taskStarted(timestamp: base.addingTimeInterval(1), turnID: "turn-model"),
            .tokenCount(
                timestamp: base.addingTimeInterval(2),
                usage: CodexTokenUsageEvent(
                    inputTokens: 100,
                    cachedInputTokens: 25,
                    outputTokens: 10,
                    reasoningOutputTokens: 5
                )
            ),
            .taskCompleted(timestamp: base.addingTimeInterval(3), turnID: "turn-model")
        ]

        let result = CodexFetcher.summarizeLocalUsage(
            windows: ["primary": CodexFetcher.ActiveUsageWindow(
                startDate: base.addingTimeInterval(-1),
                resetDate: base.addingTimeInterval(60)
            )],
            dailyWindows: [CodexFetcher.DailyUsageWindow(
                startDate: base.addingTimeInterval(-1),
                endDate: base.addingTimeInterval(60)
            )],
            sessionFiles: [CodexSessionFileEvents(fileURL: fileURL, events: events)]
        )

        let sample = try XCTUnwrap(result.recentSamples.first)
        XCTAssertEqual(sample.modelName, "gpt-5.6-sol")
        XCTAssertEqual(sample.sourceProviderID, QuotaProviderID.openAI)
        XCTAssertEqual(sample.inputTokens, 100)
        XCTAssertEqual(sample.cachedInputTokens, 25)
        XCTAssertEqual(sample.outputTokens, 10)
        XCTAssertEqual(sample.reasoningOutputTokens, 5)
    }

    func testSummarizeLocalUsageKeepsTokenSampleWithoutActiveTurn() throws {
        let base = Date(timeIntervalSince1970: 21_500)
        let fileURL = URL(fileURLWithPath: "/tmp/codex-local-orphan-token-test.jsonl")
        let events: [CodexSessionEvent] = [
            .modelContext(timestamp: base, modelName: "gpt-5.6-terra"),
            .tokenCount(
                timestamp: base.addingTimeInterval(2),
                usage: CodexTokenUsageEvent(
                    inputTokens: 200,
                    cachedInputTokens: 20,
                    outputTokens: 30,
                    reasoningOutputTokens: 5
                )
            )
        ]

        let result = CodexFetcher.summarizeLocalUsage(
            windows: ["primary": CodexFetcher.ActiveUsageWindow(
                startDate: base.addingTimeInterval(-1),
                resetDate: base.addingTimeInterval(60)
            )],
            dailyWindows: [CodexFetcher.DailyUsageWindow(
                startDate: base.addingTimeInterval(-1),
                endDate: base.addingTimeInterval(60)
            )],
            sessionFiles: [CodexSessionFileEvents(fileURL: fileURL, events: events)]
        )

        let sample = try XCTUnwrap(result.recentSamples.first)
        XCTAssertEqual(sample.modelName, "gpt-5.6-terra")
        XCTAssertEqual(sample.inputTokens, 200)
        XCTAssertTrue(sample.promptID.hasPrefix("codex:orphan:"))
    }

    func testModelContextUpdatesBetweenTokenCountsInSameTurn() throws {
        // 验证 modelContext 在 turn 中间出现时，后面的 tokenCount 用新 model：
        // turn 1 内先有 modelContext("gpt-5.6-sol") → tokenCount(input 100)；
        // 然后 modelContext("gpt-5.6-terra") → tokenCount(input 200)。
        // 这条测试覆盖 activeTurnID 已经存在、但 currentModelName 在 turn 中被替换的边界，
        // 避免 sample 在切换 model 之前/之后错拿旧 model。
        let base = Date(timeIntervalSince1970: 22_000)
        let fileURL = URL(fileURLWithPath: "/tmp/codex-local-model-mid-turn-test.jsonl")
        let events: [CodexSessionEvent] = [
            .modelContext(timestamp: base, modelName: "gpt-5.6-sol"),
            .taskStarted(timestamp: base.addingTimeInterval(1), turnID: "turn-mid"),
            .tokenCount(
                timestamp: base.addingTimeInterval(2),
                usage: CodexTokenUsageEvent(inputTokens: 100, cachedInputTokens: 0, outputTokens: 10, reasoningOutputTokens: 0)
            ),
            .modelContext(timestamp: base.addingTimeInterval(3), modelName: "gpt-5.6-terra"),
            .tokenCount(
                timestamp: base.addingTimeInterval(4),
                usage: CodexTokenUsageEvent(inputTokens: 200, cachedInputTokens: 0, outputTokens: 20, reasoningOutputTokens: 0)
            ),
            .taskCompleted(timestamp: base.addingTimeInterval(5), turnID: "turn-mid")
        ]

        let result = CodexFetcher.summarizeLocalUsage(
            windows: ["primary": CodexFetcher.ActiveUsageWindow(
                startDate: base.addingTimeInterval(-1),
                resetDate: base.addingTimeInterval(60)
            )],
            dailyWindows: [CodexFetcher.DailyUsageWindow(
                startDate: base.addingTimeInterval(-1),
                endDate: base.addingTimeInterval(60)
            )],
            sessionFiles: [CodexSessionFileEvents(fileURL: fileURL, events: events)]
        )

        // recentSamples 包含两个 sample，按 completedAt 排序（见 P1-7）。
        XCTAssertEqual(result.recentSamples.count, 2)
        let firstSample = try XCTUnwrap(result.recentSamples.first)
        XCTAssertEqual(firstSample.inputTokens, 100)
        XCTAssertEqual(firstSample.modelName, "gpt-5.6-sol")
        let secondSample = try XCTUnwrap(result.recentSamples.last)
        XCTAssertEqual(secondSample.inputTokens, 200)
        XCTAssertEqual(secondSample.modelName, "gpt-5.6-terra", "turn 中途切 model 后，第二条 sample 必须用新 model")
    }

    func testSummarizeLocalUsageRetainsNewestSamplesWhenExceedingLimit() throws {
        let base = Date(timeIntervalSince1970: 100_000)
        let olderDate = base.addingTimeInterval(-86400 * 3) // 3 days ago
        let newerDate = base // today

        let olderFile = URL(fileURLWithPath: "/tmp/codex-older.jsonl")
        let newerFile = URL(fileURLWithPath: "/tmp/codex-newer.jsonl")

        let olderEvents: [CodexSessionEvent] = [
            .modelContext(timestamp: olderDate, modelName: "gpt-5.6-sol"),
            .tokenCount(
                timestamp: olderDate,
                usage: CodexTokenUsageEvent(inputTokens: 100, cachedInputTokens: 10, outputTokens: 50, reasoningOutputTokens: 0)
            )
        ]
        let newerEvents: [CodexSessionEvent] = [
            .modelContext(timestamp: newerDate, modelName: "gpt-5.6-terra"),
            .tokenCount(
                timestamp: newerDate,
                usage: CodexTokenUsageEvent(inputTokens: 200, cachedInputTokens: 20, outputTokens: 60, reasoningOutputTokens: 0)
            )
        ]

        // cachedSessionEvents returns files in newest-first order (newerFile first)
        let sessionFiles = [
            CodexSessionFileEvents(fileURL: newerFile, events: newerEvents),
            CodexSessionFileEvents(fileURL: olderFile, events: olderEvents)
        ]

        let dailyWindows = [
            CodexFetcher.DailyUsageWindow(startDate: olderDate.addingTimeInterval(-10), endDate: olderDate.addingTimeInterval(86400)),
            CodexFetcher.DailyUsageWindow(startDate: newerDate.addingTimeInterval(-10), endDate: newerDate.addingTimeInterval(86400))
        ]

        let limits = CodexLocalScanLimits(
            maxSessionFiles: 10,
            maxEventsPerFile: 100,
            maxTotalParsedBytes: 1024 * 1024,
            maxJSONLLineBytes: 1024,
            maxRecentSamples: 1 // Only retain 1 sample
        )

        let windows = [
            "primary": CodexFetcher.ActiveUsageWindow(
                startDate: base.addingTimeInterval(-86400 * 10),
                resetDate: base.addingTimeInterval(86400)
            )
        ]

        let result = CodexFetcher.summarizeLocalUsage(
            windows: windows,
            dailyWindows: dailyWindows,
            sessionFiles: sessionFiles,
            limits: limits
        )

        XCTAssertEqual(result.recentSamples.count, 1)
        let sample = try XCTUnwrap(result.recentSamples.first)
        // Must retain the NEWER sample (gpt-5.6-terra from newerDate), NOT the older one
        XCTAssertEqual(sample.modelName, "gpt-5.6-terra")
        XCTAssertEqual(sample.completedAt, newerDate)
    }

    // MARK: - ChatGPT 行用量（合并自 UIUsageRegressionTests）

    @MainActor
    func testChatGPTDetailsKeepNativeTotalsAndAppendOnlyOpenCode() {
        let native = UsageMetricSummary(
            prompts: 1,
            rounds: 1,
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 10,
            reasoningOutputTokens: 2
        )
        let openCode = UsageMetricSummary(
            prompts: 1,
            rounds: 1,
            inputTokens: 40,
            cachedInputTokens: 0,
            outputTokens: 5,
            reasoningOutputTokens: 1
        )

        let displayed = ChatGPTPlanModelRow.preferUsageDetails(
            native,
            native + openCode,
            externalUsage: openCode
        )

        XCTAssertEqual(displayed, native + openCode)
        XCTAssertEqual(displayed?.inputTokens, 140)
        XCTAssertEqual(displayed?.cachedInputTokens, 20)
        XCTAssertEqual(displayed?.outputTokens, 15)
        XCTAssertEqual(displayed?.reasoningOutputTokens, 3)
    }

    @MainActor
    func testChatGPTOpenCodeSelectionAndFallbackDoNotDoubleCount() {
        let now = Date()
        func sample(_ promptID: String, input: Int, date: Date? = nil) -> LocalTokenUsageSample {
            LocalTokenUsageSample(
                completedAt: date ?? now, modelName: "gpt-5.6-sol", promptID: promptID,
                inputTokens: input, cachedInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0
            )
        }
        let samples = [
            sample("native-turn", input: 100),
            sample("opencode:openai:turn", input: 40),
            sample("opencode:openai:old", input: 70, date: now.addingTimeInterval(-7200))
        ]
        let start = now.addingTimeInterval(-3600)
        let end = now.addingTimeInterval(3600)
        let external = ChatGPTPlanModelRow.openCodeUsageSummary(
            samples: samples, quotaModelName: "chatgpt_plan", start: start, end: end
        )
        XCTAssertEqual(external?.inputTokens, 40)
        XCTAssertNil(ChatGPTPlanModelRow.openCodeUsageSummary(
            samples: [samples[0]], quotaModelName: "chatgpt_plan", start: start, end: end
        ), "绑定关闭时投影只含原生样本，不应追加贡献")
        let combined = LocalUsageSummaryBuilder.summary(
            samples: samples, providerKind: .codexChatGpt, quotaModelName: "chatgpt_plan", start: start, end: end
        )
        var externalEvaluated = false
        func extra() -> UsageMetricSummary? { externalEvaluated = true; return external }
        let fallback = ChatGPTPlanModelRow.preferUsageDetails(nil, combined, externalUsage: extra())
        XCTAssertEqual(fallback?.inputTokens, 140)
        XCTAssertFalse(externalEvaluated, "无原生详情时直接用合并样本，不再额外聚合OpenCode")
    }
}
