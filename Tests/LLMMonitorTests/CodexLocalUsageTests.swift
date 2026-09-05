import XCTest
@testable import LLM_monitor

final class CodexLocalUsageTests: XCTestCase {
    func testChatGPTPlanRowPrefersPreaggregatedDetailsWithoutDoubleCounting() {
        // CodexUsageDetails.primary 与 localSamples 都来自同一批 session 文件。
        // 例如 183M 未缓存输入 + 369M cached = 552M 原始 input；旧实现会把
        // details 和 samples 相加，错误显示成 366M 未缓存 + 738M cached。
        let preaggregated = UsageMetricSummary(
            prompts: 3,
            rounds: 30,
            inputTokens: 552_000_000,
            cachedInputTokens: 369_000_000,
            outputTokens: 12_000_000,
            reasoningOutputTokens: 4_000_000
        )
        var fallbackEvaluated = false

        func makeFallback() -> UsageMetricSummary? {
            fallbackEvaluated = true
            return preaggregated
        }

        let resolved = ChatGPTPlanModelRow.preferUsageDetails(preaggregated, makeFallback())

        XCTAssertEqual(resolved, preaggregated)
        XCTAssertEqual(resolved?.uncachedInputTokens, 183_000_000)
        XCTAssertEqual(resolved?.cachedInputTokens, 369_000_000)
        XCTAssertFalse(fallbackEvaluated, "详情已存在时不应再次聚合同一批 local samples")
    }

    func testChatGPTPlanRowFallsBackToLocalSamplesWhenDetailsAreMissing() {
        let fallback = UsageMetricSummary(
            prompts: 1,
            rounds: 2,
            inputTokens: 100,
            cachedInputTokens: 40,
            outputTokens: 20,
            reasoningOutputTokens: 5
        )

        XCTAssertEqual(
            ChatGPTPlanModelRow.preferUsageDetails(nil, fallback),
            fallback
        )
    }

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

    func testSummarizeLocalUsageWithoutWindowsStillProducesDailyAndLastPrompt() throws {
        // 循环 B 与额度解耦：无 reset 时间（windows 为空）时，daily 与 Last Prompt
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
        XCTAssertEqual(result.latestPromptTurnID, "turn-a")
        XCTAssertEqual(result.scannedFileCount, 1)
    }

    // MARK: - 生命周期 append-only 增量解析

    private func codexJSONLine(timestamp: String, type: String, payload: [String: Any]) -> String {
        let object: [String: Any] = ["timestamp": timestamp, "type": type, "payload": payload]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func codexTurnLines(
        baseSeconds: Double,
        turnID: String,
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int
    ) -> String {
        func iso(_ seconds: Double) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date(timeIntervalSince1970: seconds))
        }
        return [
            codexJSONLine(timestamp: iso(baseSeconds), type: "turn_context", payload: ["model": model]),
            codexJSONLine(timestamp: iso(baseSeconds + 1), type: "event_msg", payload: ["type": "task_started", "turn_id": turnID]),
            codexJSONLine(
                timestamp: iso(baseSeconds + 2),
                type: "event_msg",
                payload: ["type": "token_count", "info": ["last_token_usage": [
                    "input_tokens": inputTokens,
                    "cached_input_tokens": cachedInputTokens,
                    "output_tokens": outputTokens,
                    "reasoning_output_tokens": reasoningOutputTokens,
                ]]]
            ),
            codexJSONLine(timestamp: iso(baseSeconds + 3), type: "event_msg", payload: ["type": "task_complete", "turn_id": turnID]),
        ]
        .joined(separator: "\n")
        .appending("\n")
    }

    private func makeIncrementalTestLimits() -> CodexLocalScanLimits {
        // 小 readChunkBytes 强制跨分块行拼接路径也被覆盖
        CodexLocalScanLimits(
            maxSessionFiles: 16,
            maxEventsPerFile: 1_000,
            maxTotalParsedBytes: 4 * 1024 * 1024,
            maxJSONLLineBytes: 1024 * 1024,
            readChunkBytes: 64
        )
    }

    private func makeTempJSONLFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-incr-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private func rewrite(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func snapshotFor(_ url: URL) throws -> CodexSessionFileSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return CodexSessionFileSnapshot(
            fileURL: url,
            modifiedAt: attributes[.modificationDate] as! Date,
            fileSize: attributes[.size] as! Int
        )
    }

    private func modelNames(in events: [CodexSessionEvent]) -> [String] {
        events.compactMap { event in
            if case .modelContext(_, let modelName) = event { return modelName }
            return nil
        }
    }

    func testIncrementalAppendMatchesFullRescan() async throws {
        let limits = makeIncrementalTestLimits()
        let url = makeTempJSONLFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try rewrite(codexTurnLines(baseSeconds: 24_000, turnID: "turn-a", model: "gpt-5.6-terra", inputTokens: 10, cachedInputTokens: 2, outputTokens: 5, reasoningOutputTokens: 1), to: url)

        let first = await CodexFetcher.resolveSessionEvents(
            for: try snapshotFor(url), parsingFingerprint: "test", limits: limits, remainingByteBudget: 4 * 1024 * 1024
        )
        XCTAssertTrue(first.didParse)
        XCTAssertEqual(first.events.count, 4)

        // append-only 增长：新 turn 切换模型
        try append(codexTurnLines(baseSeconds: 24_100, turnID: "turn-b", model: "gpt-5.6-luna", inputTokens: 20, cachedInputTokens: 4, outputTokens: 8, reasoningOutputTokens: 2), to: url)

        let incremental = await CodexFetcher.resolveSessionEvents(
            for: try snapshotFor(url), parsingFingerprint: "test", limits: limits, remainingByteBudget: 4 * 1024 * 1024
        )
        XCTAssertTrue(incremental.didParse)

        // 未变化的文件：完全复用，不再解析（须在指纹被全量重扫覆盖前断言）
        let unchanged = await CodexFetcher.resolveSessionEvents(
            for: try snapshotFor(url), parsingFingerprint: "test", limits: limits, remainingByteBudget: 4 * 1024 * 1024
        )
        XCTAssertFalse(unchanged.didParse)
        XCTAssertEqual(unchanged.events, incremental.events)

        // 全量重扫（新 parsingFingerprint 强制冷解析）作为等价性基准
        let fullFingerprint = "test-full-\(UUID().uuidString)"
        let full = await CodexFetcher.resolveSessionEvents(
            for: try snapshotFor(url), parsingFingerprint: fullFingerprint, limits: limits, remainingByteBudget: 4 * 1024 * 1024
        )

        XCTAssertEqual(incremental.events, full.events, "增量结果必须与全新全量解析逐事件一致")
        XCTAssertEqual(modelNames(in: incremental.events), ["gpt-5.6-terra", "gpt-5.6-luna"])
        XCTAssertEqual(incremental.events.count, 8)

        // 同指纹再次调用：命中全量重扫写入的缓存，完全复用
        let reusedAfterFull = await CodexFetcher.resolveSessionEvents(
            for: try snapshotFor(url), parsingFingerprint: fullFingerprint, limits: limits, remainingByteBudget: 4 * 1024 * 1024
        )
        XCTAssertFalse(reusedAfterFull.didParse)
        XCTAssertEqual(reusedAfterFull.events, full.events)
    }

    func testTruncatedFileTriggersFullRescan() async throws {
        let limits = makeIncrementalTestLimits()
        let url = makeTempJSONLFile()
        defer { try? FileManager.default.removeItem(at: url) }

        try rewrite(codexTurnLines(baseSeconds: 25_000, turnID: "turn-a", model: "gpt-5.6-terra", inputTokens: 10, cachedInputTokens: 2, outputTokens: 5, reasoningOutputTokens: 1)
                    + codexTurnLines(baseSeconds: 25_100, turnID: "turn-b", model: "gpt-5.6-luna", inputTokens: 20, cachedInputTokens: 4, outputTokens: 8, reasoningOutputTokens: 2), to: url)
        let initial = await CodexFetcher.resolveSessionEvents(
            for: try snapshotFor(url), parsingFingerprint: "test", limits: limits, remainingByteBudget: 4 * 1024 * 1024
        )
        XCTAssertEqual(initial.events.count, 8)

        // 截断：文件被整体替换为更短的新内容
        try rewrite(codexTurnLines(baseSeconds: 26_000, turnID: "turn-c", model: "gpt-5.6-terra", inputTokens: 30, cachedInputTokens: 6, outputTokens: 9, reasoningOutputTokens: 3), to: url)
        let after = await CodexFetcher.resolveSessionEvents(
            for: try snapshotFor(url), parsingFingerprint: "test", limits: limits, remainingByteBudget: 4 * 1024 * 1024
        )
        XCTAssertTrue(after.didParse)
        XCTAssertEqual(after.events.count, 4, "截断后必须整体重扫，不得残留旧事件")
        XCTAssertEqual(modelNames(in: after.events), ["gpt-5.6-terra"])
    }

    func testPartialTailLineParsedExactlyOnceAfterCompletion() async throws {
        let limits = makeIncrementalTestLimits()
        let url = makeTempJSONLFile()
        defer { try? FileManager.default.removeItem(at: url) }

        // turn-a 完整 + turn-b 的前两行完整 + token_count 行只有前半段（无换行）
        let turnA = codexTurnLines(baseSeconds: 27_000, turnID: "turn-a", model: "gpt-5.6-terra", inputTokens: 10, cachedInputTokens: 2, outputTokens: 5, reasoningOutputTokens: 1)
        let turnBHead =
            codexJSONLine(timestamp: "2026-09-05T03:10:00.000Z", type: "turn_context", payload: ["model": "gpt-5.6-luna"]) + "\n"
            + codexJSONLine(timestamp: "2026-09-05T03:10:01.000Z", type: "event_msg", payload: ["type": "task_started", "turn_id": "turn-b"]) + "\n"
        let partialTokenLine = "{\"timestamp\":\"2026-09-05T03:10:02.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\""
        try rewrite(turnA + turnBHead + partialTokenLine, to: url)

        let first = await CodexFetcher.resolveSessionEvents(
            for: try snapshotFor(url), parsingFingerprint: "test", limits: limits, remainingByteBudget: 4 * 1024 * 1024
        )
        XCTAssertEqual(first.events.count, 6, "残行必须整行跳过，不得产出半个事件")

        // 补全残行并追加 task_complete
        let remainder = ",\"info\":{\"last_token_usage\":{\"input_tokens\":20,\"cached_input_tokens\":4,\"output_tokens\":8,\"reasoning_output_tokens\":2}}}}\n"
            + codexJSONLine(timestamp: "2026-09-05T03:10:03.000Z", type: "event_msg", payload: ["type": "task_complete", "turn_id": "turn-b"]) + "\n"
        try append(remainder, to: url)

        let second = await CodexFetcher.resolveSessionEvents(
            for: try snapshotFor(url), parsingFingerprint: "test", limits: limits, remainingByteBudget: 4 * 1024 * 1024
        )
        XCTAssertTrue(second.didParse)
        // turn-a 4 个事件 + turn-b 4 个事件（modelContext/taskStarted 在首拍，
        // tokenCount/taskComplete 在残行补全后的增量拍）
        XCTAssertEqual(second.events.count, 8, "补全后恰好解析一次，不得重复")
        let tokenCounts = second.events.filter { if case .tokenCount = $0 { return true }; return false }
        XCTAssertEqual(tokenCounts.count, 2)

        // 无变化：完全复用，事件不增不减
        let third = await CodexFetcher.resolveSessionEvents(
            for: try snapshotFor(url), parsingFingerprint: "test", limits: limits, remainingByteBudget: 4 * 1024 * 1024
        )
        XCTAssertFalse(third.didParse)
        XCTAssertEqual(third.events, second.events)
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
        XCTAssertEqual(result.latestPromptTurnID, "turn-2")
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

    func testLatestPromptUsageOnlyIncludesRoundsOfSelectedTurn() throws {
        let base = Date(timeIntervalSince1970: 30_000)
        let fileURL = URL(fileURLWithPath: "/tmp/codex-latest-prompt-test.jsonl")
        let completedAt = base.addingTimeInterval(50)
        let files = [CodexSessionFileEvents(
            fileURL: fileURL,
            events: [
                .tokenCount(
                    timestamp: base.addingTimeInterval(1),
                    usage: CodexTokenUsageEvent(inputTokens: 99, cachedInputTokens: 0, outputTokens: 99, reasoningOutputTokens: 0)
                ),
                .taskStarted(timestamp: base.addingTimeInterval(10), turnID: "turn-2"),
                .tokenCount(
                    timestamp: base.addingTimeInterval(20),
                    usage: CodexTokenUsageEvent(inputTokens: 10, cachedInputTokens: 2, outputTokens: 5, reasoningOutputTokens: 1)
                ),
                .tokenCount(
                    timestamp: base.addingTimeInterval(30),
                    usage: CodexTokenUsageEvent(inputTokens: 20, cachedInputTokens: 3, outputTokens: 6, reasoningOutputTokens: 2)
                ),
                .taskCompleted(timestamp: completedAt, turnID: "turn-2"),
                .tokenCount(
                    timestamp: base.addingTimeInterval(60),
                    usage: CodexTokenUsageEvent(inputTokens: 88, cachedInputTokens: 0, outputTokens: 88, reasoningOutputTokens: 0)
                )
            ]
        )]

        let result = try XCTUnwrap(CodexFetcher.latestPromptUsage(
            sessionFiles: files,
            fileURL: fileURL,
            turnID: "turn-2",
            completedAt: completedAt
        ))

        XCTAssertEqual(result.usage.rounds, 2)
        XCTAssertEqual(result.usage.inputTokens, 30)
        XCTAssertEqual(result.usage.cachedInputTokens, 5)
        XCTAssertEqual(result.usage.outputTokens, 11)
        XCTAssertEqual(result.usage.reasoningOutputTokens, 3)
        XCTAssertEqual(result.completedAt, completedAt)
    }

    // MARK: - F2: 超预算时读取文件尾部并保留近期事件

    /// 单位长度、可识别的 token_count 行：input_tokens = k（k 为单个数字，保证每行字节数一致）。
    private func f2EventLine(k: Int) -> String {
        let ts = "2026-08-12T00:00:0\(k)Z"
        return "{\"type\":\"event_msg\",\"timestamp\":\"\(ts)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":\(k),\"cached_input_tokens\":0,\"output_tokens\":0,\"reasoning_output_tokens\":0}}}}\n"
    }

    /// 写入 count 条单位长度 token_count 事件，返回文件 URL、总字节数和单行字节数（含换行）。
    private func f2WriteUniformEvents(count: Int) throws -> (url: URL, totalBytes: Int, lineBytes: Int) {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("codex-f2-\(UUID().uuidString).jsonl")
        var content = ""
        for k in 0..<count {
            content += f2EventLine(k: k)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        let total = content.utf8.count
        return (url, total, total / count)
    }

    private func f2InputTokens(from files: [CodexSessionFileEvents]) -> [Int] {
        guard let events = files.first?.events else { return [] }
        return events.compactMap { event -> Int? in
            if case .tokenCount(_, let usage) = event { return usage.inputTokens }
            return nil
        }
    }

    private func f2MakeSnapshot(url: URL, fileSize: Int, modifiedAt: Date = Date()) -> CodexSessionFileSnapshot {
        CodexSessionFileSnapshot(fileURL: url, modifiedAt: modifiedAt, fileSize: fileSize)
    }

    /// 完整文件读取：byteLimit ≥ 文件长度时，所有事件按序返回。
    func testF2FullFileReadReturnsAllEvents() async throws {
        let (url, total, _) = try f2WriteUniformEvents(count: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let snap = f2MakeSnapshot(url: url, fileSize: total)
        let limits = CodexLocalScanLimits(
            maxSessionFiles: 8, maxEventsPerFile: 100, maxTotalParsedBytes: 64 * 1024 * 1024,
            maxJSONLLineBytes: 8 * 1024 * 1024, readChunkBytes: 64
        )
        let files = await CodexFetcher.cachedSessionEvents(for: [snap], limits: limits)
        XCTAssertEqual(f2InputTokens(from: files), [0, 1, 2, 3, 4, 5])
    }

    /// 小 byte limit 只保留尾部事件：旧实现从文件头读会保留最旧事件，这里断言保留的是近期事件。
    func testF2SmallByteLimitReturnsOnlyTailEvents() async throws {
        let (url, total, lineBytes) = try f2WriteUniformEvents(count: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        // 预算覆盖最后约 2.5 行：startOffset = 6T - 2.5T = 3.5T 落在第 3 行中间，
        // 第 3 行残行被丢弃，保留第 4、5 行（input_tokens = 4、5）。
        let byteLimit = 2 * lineBytes + lineBytes / 2
        let snap = f2MakeSnapshot(url: url, fileSize: total)
        // 注入小 byteLimit：直接走解析路径，用一个超大总预算但限制单文件预算。
        // cachedSessionEvents 用 perFileByteLimit = min(fileSize, remainingBudget)。
        // 为精确控制单文件预算，把 maxTotalParsedBytes 设为 byteLimit。
        let preciseLimits = CodexLocalScanLimits(
            maxSessionFiles: 8, maxEventsPerFile: 100, maxTotalParsedBytes: byteLimit,
            maxJSONLLineBytes: 8 * 1024 * 1024, readChunkBytes: 32
        )
        let files = await CodexFetcher.cachedSessionEvents(for: [snap], limits: preciseLimits)
        let tokens = f2InputTokens(from: files)
        XCTAssertEqual(tokens, [4, 5], "小预算应只保留尾部近期事件，而不是文件头的最旧事件")
    }

    /// 起点恰好在换行符上：换行符后的完整行不应被错误丢弃。
    func testF2StartOffsetAtNewlineKeepsFollowingLines() async throws {
        let (url, total, lineBytes) = try f2WriteUniformEvents(count: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        // startOffset = 4T - 1（第 3 行末尾的换行符字节位置）→ 第一个读到的字节是 \n，
        // 首段为空，不丢失任何完整行；保留第 4、5 行。
        let startOffset = 4 * lineBytes - 1
        let byteLimit = total - startOffset
        let snap = f2MakeSnapshot(url: url, fileSize: total)
        let limits = CodexLocalScanLimits(
            maxSessionFiles: 8, maxEventsPerFile: 100, maxTotalParsedBytes: byteLimit,
            maxJSONLLineBytes: 8 * 1024 * 1024, readChunkBytes: 32
        )
        let files = await CodexFetcher.cachedSessionEvents(for: [snap], limits: limits)
        XCTAssertEqual(f2InputTokens(from: files), [4, 5])
    }

    /// 起点位于行中间：跨边界的残行被丢弃，其后完整行正常解析。
    func testF2StartOffsetMidLineDiscardsPartialLine() async throws {
        let (url, total, lineBytes) = try f2WriteUniformEvents(count: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        // startOffset = 3T + T/2（第 3 行中间）→ 第 3 行残行被丢弃，保留第 4、5 行。
        let startOffset = 3 * lineBytes + lineBytes / 2
        let byteLimit = total - startOffset
        let snap = f2MakeSnapshot(url: url, fileSize: total)
        let limits = CodexLocalScanLimits(
            maxSessionFiles: 8, maxEventsPerFile: 100, maxTotalParsedBytes: byteLimit,
            maxJSONLLineBytes: 8 * 1024 * 1024, readChunkBytes: 32
        )
        let files = await CodexFetcher.cachedSessionEvents(for: [snap], limits: limits)
        XCTAssertEqual(f2InputTokens(from: files), [4, 5])
    }

    /// 尾部含超过 maxEventsPerFile 个相关事件时，结果严格为最后 N 个（按序）。
    func testF2BoundedBufferKeepsLastNEvents() async throws {
        let (url, total, _) = try f2WriteUniformEvents(count: 8)
        defer { try? FileManager.default.removeItem(at: url) }
        let snap = f2MakeSnapshot(url: url, fileSize: total)
        let limits = CodexLocalScanLimits(
            maxSessionFiles: 8, maxEventsPerFile: 3, maxTotalParsedBytes: 64 * 1024 * 1024,
            maxJSONLLineBytes: 8 * 1024 * 1024, readChunkBytes: 32
        )
        let files = await CodexFetcher.cachedSessionEvents(for: [snap], limits: limits)
        // 旧实现读取头部时会在收集到 3 个事件时停止，保留最旧 3 个 [0,1,2]；
        // 新实现读尾部并用有界缓冲，保留最后 3 个 [5,6,7]。
        XCTAssertEqual(f2InputTokens(from: files), [5, 6, 7])
    }

    /// 文件在 snapshot 之后增长：读取以 handle 实测长度为准，仍读到真正的尾部。
    func testF2FileGrowthReadsActualTail() async throws {
        let (url, total, _) = try f2WriteUniformEvents(count: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        // snapshot 在增长前拍摄（fileSize 较小）
        let snap = f2MakeSnapshot(url: url, fileSize: total)
        // 随后向文件追加 2 个更新事件
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        try handle.write(contentsOf: Data(f2EventLine(k: 4).utf8))
        try handle.write(contentsOf: Data(f2EventLine(k: 5).utf8))
        try handle.close()
        // 用覆盖原始 snapshot 的预算读取，仍应拿到真正的尾部（含追加的事件）。
        // 注意 perFileByteLimit 受 snapshot.fileSize（增长前的较小值）限制，因此
        // 读取的是真正的文件尾部而不是全部内容；关键是断言到达了新增的事件 5。
        let limits = CodexLocalScanLimits(
            maxSessionFiles: 8, maxEventsPerFile: 100, maxTotalParsedBytes: 64 * 1024 * 1024,
            maxJSONLLineBytes: 8 * 1024 * 1024, readChunkBytes: 32
        )
        let files = await CodexFetcher.cachedSessionEvents(for: [snap], limits: limits)
        let tokens = f2InputTokens(from: files)
        XCTAssertEqual(tokens.last, 5, "文件增长后应以实测长度读取真正的尾部，能到达新增的事件 5")
    }

    /// 超长行（超过 maxJSONLLineBytes）被跳过，其后的合法行正常解析。
    func testF2OversizedLineSkipped() async throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("codex-f2-over-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(at: url) }
        var content = f2EventLine(k: 0)
        // 一行合法但单行字节数超过 maxJSONLLineBytes(=256)：300 字节的非事件填充行
        content += String(repeating: "x", count: 300) + "\n"
        content += f2EventLine(k: 2)
        try content.write(to: url, atomically: true, encoding: .utf8)
        let snap = f2MakeSnapshot(url: url, fileSize: content.utf8.count)
        let limits = CodexLocalScanLimits(
            maxSessionFiles: 8, maxEventsPerFile: 100, maxTotalParsedBytes: 64 * 1024 * 1024,
            maxJSONLLineBytes: 256, readChunkBytes: 64
        )
        let files = await CodexFetcher.cachedSessionEvents(for: [snap], limits: limits)
        // 超长行被跳过，只保留 k=0 和 k=2 两个 token_count 事件
        XCTAssertEqual(f2InputTokens(from: files), [0, 2])
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

    // MARK: - 字节级一级过滤与行级过滤等价

    /// 混合行文本下的一级过滤等价性：含 marker 的正常事件行全部产出事件；
    /// marker 只出现在 JSON 字符串值中的行允许进入解析（误命中只是多解析一行）
    /// 但不得产出事件；无 marker 的行与空行不产出事件。配合极小 readChunkBytes
    /// 让每行跨多个读取分块，验证字节缓冲跨块拼接后 marker 仍可命中（不会漏判）。
    func testByteLevelPrefilterMatchesLineFilterSemantics() async throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory
            .appendingPathComponent("codex-prefilter-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(at: url) }

        var content = ""
        content += "{\"type\":\"session_meta\",\"payload\":{\"id\":\"s1\"}}\n"
        content += "\n"
        // marker 只出现在字符串值中：进入解析但不产出事件
        content += "{\"type\":\"response_item\",\"timestamp\":\"2026-08-12T00:00:00Z\",\"payload\":{\"text\":\"讨论了 event_msg 与 turn_context 的处理\"}}\n"
        // 多字节 UTF-8 内容且不含 marker：字节层直接跳过
        content += "{\"type\":\"response_item\",\"timestamp\":\"2026-08-12T00:00:00Z\",\"payload\":{\"text\":\"普通会话内容，不含任何标记\"}}\n"
        content += "{\"type\":\"turn_context\",\"timestamp\":\"2026-08-12T00:00:01Z\",\"payload\":{\"model\":\"gpt-5.6-pf\"}}\n"
        content += "{\"type\":\"event_msg\",\"timestamp\":\"2026-08-12T00:00:02Z\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-pf\"}}\n"
        content += "{\"type\":\"event_msg\",\"timestamp\":\"2026-08-12T00:00:03Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":7,\"cached_input_tokens\":2,\"output_tokens\":3,\"reasoning_output_tokens\":1}}}}\n"
        // 末行不带换行符
        content += "{\"type\":\"event_msg\",\"timestamp\":\"2026-08-12T00:00:04Z\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-pf\"}}"

        try content.write(to: url, atomically: true, encoding: .utf8)
        let snap = f2MakeSnapshot(url: url, fileSize: content.utf8.count)
        let limits = CodexLocalScanLimits(
            maxSessionFiles: 8, maxEventsPerFile: 100, maxTotalParsedBytes: 64 * 1024 * 1024,
            maxJSONLLineBytes: 8 * 1024 * 1024, readChunkBytes: 24
        )
        let files = await CodexFetcher.cachedSessionEvents(for: [snap], limits: limits)
        let events = files.first?.events ?? []

        var models: [String] = []
        var turns: [String] = []
        var usages: [CodexTokenUsageEvent] = []
        for event in events {
            switch event {
            case .modelContext(_, let modelName):
                models.append(modelName)
            case .taskStarted(_, let turnID):
                turns.append("start:\(turnID)")
            case .taskCompleted(_, let turnID):
                turns.append("complete:\(turnID)")
            case .tokenCount(_, let usage):
                usages.append(usage)
            }
        }

        XCTAssertEqual(models, ["gpt-5.6-pf"], "只有真正的 turn_context 行产出 modelContext")
        XCTAssertEqual(turns, ["start:turn-pf", "complete:turn-pf"], "task_started/task_complete 按序产出，无尾换行的末行不丢失")
        XCTAssertEqual(usages.count, 1, "只有真正的 token_count 行产出用量事件")
        XCTAssertEqual(usages.first?.inputTokens, 7)
        XCTAssertEqual(usages.first?.cachedInputTokens, 2)
        XCTAssertEqual(usages.first?.outputTokens, 3)
        XCTAssertEqual(usages.first?.reasoningOutputTokens, 1)
        XCTAssertEqual(events.count, 4, "marker 出现在字符串值中的行、无 marker 行与空行都不得产出事件")
    }
}
