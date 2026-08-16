import XCTest
@testable import LLM_monitor

final class CodexLocalUsageTests: XCTestCase {
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
        let limits = CodexLocalScanLimits(
            maxSessionFiles: 8, maxEventsPerFile: 100, maxTotalParsedBytes: 64 * 1024 * 1024,
            maxJSONLLineBytes: 8 * 1024 * 1024, readChunkBytes: 32
        )
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
}
