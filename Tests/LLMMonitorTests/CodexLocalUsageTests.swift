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
}
