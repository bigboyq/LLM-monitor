import XCTest
import SQLite3
@testable import LLM_monitor

final class OpencodeUsageTests: XCTestCase {
    @MainActor
    func testScannerRestoresCachedSnapshotOnInitialization() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-opencode-prefill-\(UUID().uuidString)", isDirectory: true)
        let cacheDir = directory.appendingPathComponent("cache", isDirectory: true)
        let snapshot = OpencodeLocalUsage(
            byProvider: [:],
            modelsByProvider: [:],
            dbPath: "/tmp/opencode.db",
            scannedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let index = OpencodeUsageScanner.CacheIndex(
            version: 2,
            dbMtimeMs: 1,
            dbSizeBytes: 1,
            walMtimeMs: 0,
            walSizeBytes: 0,
            snapshot: snapshot
        )
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try OpencodeUsageScanner.saveIndex(index, cacheDir: cacheDir, fileManager: FileManagerBox())

        let scanner = OpencodeUsageScanner(
            dbURL: directory.appendingPathComponent("missing.db"),
            cacheDir: cacheDir
        )
        XCTAssertEqual(scanner.lastResult, snapshot)
    }

    func testOpencodeMergeDefaultsPreserveGLMCompatibility() throws {
        let oldConfig = try JSONDecoder().decode(
            ProviderConfig.self,
            from: Data(#"{"enabled":true}"#.utf8)
        )

        XCTAssertTrue(oldConfig.shouldMergeOpencodeUsage(for: .glmCodingPlan))
        XCTAssertFalse(oldConfig.shouldMergeOpencodeUsage(for: .minimaxTokenPlan))
        XCTAssertFalse(oldConfig.shouldMergeOpencodeUsage(for: .codexChatGpt))
        XCTAssertFalse(oldConfig.shouldMergeOpencodeUsage(for: .antigravity))

        var explicitlyDisabled = oldConfig
        explicitlyDisabled.mergeOpencodeUsage = false
        XCTAssertFalse(explicitlyDisabled.shouldMergeOpencodeUsage(for: .glmCodingPlan))
    }

    func testMergeAddsDailyFieldsAndNamespacesPrompts() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let nativeSample = LocalTokenUsageSample(
            completedAt: day,
            modelName: "minimax-m2",
            promptID: "same-prompt",
            inputTokens: 10,
            cachedInputTokens: 2,
            outputTokens: 3,
            reasoningOutputTokens: 1
        )
        let openSample = LocalTokenUsageSample(
            completedAt: day.addingTimeInterval(1),
            modelName: "MiniMax-M2.1",
            promptID: "same-prompt",
            inputTokens: 5,
            cachedInputTokens: 4,
            outputTokens: 7,
            reasoningOutputTokens: 2
        )
        let open = OpencodeProviderUsage(
            today: OpencodeDailyUsage(
                dayStart: day,
                inputTokens: 5,
                outputTokens: 7,
                cacheReadTokens: 4,
                reasoningTokens: 2,
                totalTokens: 18,
                turns: 2,
                rounds: 3
            ),
            dailyTokenUsage: [OpencodeDailyUsage(
                dayStart: day,
                inputTokens: 5,
                outputTokens: 7,
                cacheReadTokens: 4,
                reasoningTokens: 2,
                totalTokens: 18,
                turns: 2,
                rounds: 3
            )],
            roundCount: 3,
            cost: 0,
            recentSamples: [openSample]
        )
        let native = MinimaxLocalUsage(
            today: MinimaxDailyUsage(
                dayStart: day,
                inputTokens: 10,
                outputTokens: 3,
                cacheReadTokens: 2,
                reasoningTokens: 1,
                totalTokens: 16,
                turns: 1,
                rounds: 2
            ),
            dailyTokenUsage: [MinimaxDailyUsage(
                dayStart: day,
                inputTokens: 10,
                outputTokens: 3,
                cacheReadTokens: 2,
                reasoningTokens: 1,
                totalTokens: 16,
                turns: 1,
                rounds: 2
            )],
            scannedAt: nil,
            sessionCount: 1,
            eventCount: 2,
            failedSessionCount: 0,
            recentSamples: [nativeSample]
        )

        // 生产路径：usageProjection 按 client 贡献合并（不再走历史 mergeMinimax）。
        var status = ProviderStatus(
            id: "minimax", displayName: "MiniMax", kind: .minimaxTokenPlan,
            iconSystemName: "circle", accentColor: .minimax,
            refreshIntervalSeconds: 300, state: .ready
        )
        status.minimaxLocalUsage = native
        status.opencodeUsage = OpencodeLocalUsage(
            byProvider: [OpencodeLocalUsage.minimaxCodingPlanProviderID: open],
            modelsByProvider: [:], dbPath: nil, scannedAt: nil
        )
        status.mergeOpencodeUsage = true

        let projection = status.usageProjection(for: nil)
        XCTAssertEqual(projection.clientIDs, [ClientID.minimaxCode, ClientID.openCode])
        let mergedDay = try XCTUnwrap(projection.dailyTokenUsage.first)
        XCTAssertEqual(mergedDay.input, 15)
        XCTAssertEqual(mergedDay.cacheRead, 6)
        XCTAssertEqual(mergedDay.output, 10)
        XCTAssertEqual(mergedDay.reasoning, 3)
        XCTAssertEqual(mergedDay.rounds, 5)
        XCTAssertEqual(mergedDay.turns, 3)
        XCTAssertEqual(projection.recentSamples.count, 2)
        XCTAssertTrue(
            projection.recentSamples.contains {
                $0.promptID == "opencode:\(OpencodeLocalUsage.minimaxCodingPlanProviderID):same-prompt"
            },
            "OpenCode sample 必须带命名空间前缀"
        )

        // mergeOpencodeUsage=false 时 OpenCode 贡献整体消失。
        status.mergeOpencodeUsage = false
        let nativeOnly = status.usageProjection(for: nil)
        XCTAssertEqual(nativeOnly.clientIDs, [ClientID.minimaxCode])
        XCTAssertEqual(nativeOnly.dailyTokenUsage.first?.input, 10)

        let summary = LocalUsageSummaryBuilder.summary(
            samples: OpencodeUsageMerger.mergeSamples(
                native: [nativeSample],
                opencode: open,
                providerID: OpencodeLocalUsage.minimaxCodingPlanProviderID
            ),
            providerKind: .minimaxTokenPlan,
            quotaModelName: "general",
            start: nil,
            end: nil
        )
        XCTAssertEqual(summary?.prompts, 2)
        XCTAssertEqual(summary?.rounds, 2)
        XCTAssertEqual(summary?.inputTokens, 15)
        XCTAssertEqual(summary?.cachedInputTokens, 6)
    }

    func testMergeAntigravityAddsDailyFieldsAndNamespacesPrompts() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let openSample = LocalTokenUsageSample(
            completedAt: day.addingTimeInterval(1),
            modelName: "gemini-pro",
            promptID: "same-prompt",
            inputTokens: 5,
            cachedInputTokens: 4,
            outputTokens: 7,
            reasoningOutputTokens: 2
        )
        let open = OpencodeProviderUsage(
            today: OpencodeDailyUsage(
                dayStart: day,
                inputTokens: 5,
                outputTokens: 7,
                cacheReadTokens: 4,
                cacheWriteTokens: 1,
                reasoningTokens: 2,
                totalTokens: 18,
                turns: 2,
                rounds: 3
            ),
            dailyTokenUsage: [OpencodeDailyUsage(
                dayStart: day,
                inputTokens: 5,
                outputTokens: 7,
                cacheReadTokens: 4,
                cacheWriteTokens: 1,
                reasoningTokens: 2,
                totalTokens: 18,
                turns: 2,
                rounds: 3
            )],
            roundCount: 3,
            cost: 0,
            recentSamples: [openSample]
        )
        let native = AntigravityLocalUsage(
            today: AntigravityDailyUsage(
                dayStart: day,
                inputTokens: 10,
                cacheReadTokens: 2,
                cacheWriteTokens: 3,
                outputTokens: 3,
                reasoningTokens: 1,
                totalTokens: 16,
                turns: 1,
                rounds: 2
            ),
            dailyTokenUsage: [AntigravityDailyUsage(
                dayStart: day,
                inputTokens: 10,
                cacheReadTokens: 2,
                cacheWriteTokens: 3,
                outputTokens: 3,
                reasoningTokens: 1,
                totalTokens: 16,
                turns: 1,
                rounds: 2
            )],
            scannedAt: nil,
            sessionCount: 1,
            eventCount: 2,
            failedSessionCount: 0,
            recentSamples: []
        )

        // 生产路径：usageProjection 合并 Antigravity native 与 OpenCode 分片。
        var status = ProviderStatus(
            id: "antigravity", displayName: "Antigravity", kind: .antigravity,
            iconSystemName: "circle", accentColor: .antigravity,
            refreshIntervalSeconds: 300, state: .ready
        )
        status.antigravityLocalUsage = native
        status.opencodeUsage = OpencodeLocalUsage(
            byProvider: [OpencodeLocalUsage.antigravityProviderIDs[0]: open],
            modelsByProvider: [:], dbPath: nil, scannedAt: nil
        )
        status.mergeOpencodeUsage = true

        let projection = status.usageProjection(for: nil)
        XCTAssertEqual(projection.clientIDs, [ClientID.antigravity, ClientID.openCode])
        let mergedDay = try XCTUnwrap(projection.dailyTokenUsage.first)
        XCTAssertEqual(mergedDay.input, 15)
        XCTAssertEqual(mergedDay.cacheRead, 6)
        XCTAssertEqual(mergedDay.cacheWrite, 4)
        XCTAssertEqual(mergedDay.output, 10)
        XCTAssertEqual(mergedDay.reasoning, 3)
        XCTAssertEqual(mergedDay.rounds, 5)
        XCTAssertEqual(mergedDay.turns, 3)
        XCTAssertEqual(
            projection.recentSamples.first?.promptID,
            "opencode:\(OpencodeLocalUsage.antigravityProviderIDs.first!):same-prompt"
        )
    }

    func testAntigravityAliasMergeDeduplicatesRecentSamples() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let sample = LocalTokenUsageSample(
            completedAt: day,
            modelName: "gemini-pro",
            promptID: "shared-prompt",
            inputTokens: 5,
            cachedInputTokens: 1,
            outputTokens: 2,
            reasoningOutputTokens: 0
        )
        let usage = OpencodeProviderUsage(
            today: nil,
            dailyTokenUsage: [],
            roundCount: 1,
            cost: 0,
            recentSamples: [sample]
        )
        let snapshot = OpencodeLocalUsage(
            byProvider: [
                "antigravity": usage,
                "google": usage,
            ],
            modelsByProvider: [:],
            dbPath: nil,
            scannedAt: nil
        )

        let merged = try XCTUnwrap(snapshot.antigravitySlice)
        XCTAssertEqual(merged.recentSamples.count, 1)
        let summary = try XCTUnwrap(
            LocalUsageSummaryBuilder.summary(
                samples: merged.recentSamples,
                providerKind: .antigravity,
                quotaModelName: AntigravityModelKind.geminiModels.rawValue,
                start: nil,
                end: nil
            )
        )
        XCTAssertEqual(summary.prompts, 1)
        XCTAssertEqual(summary.rounds, 1)
    }

    func testAntigravityAliasMergeKeepsDistinctSamplesAndPrefixesThem() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(_ promptID: String) -> LocalTokenUsageSample {
            LocalTokenUsageSample(
                completedAt: day,
                modelName: "gemini-pro",
                promptID: promptID,
                inputTokens: 1,
                cachedInputTokens: 0,
                outputTokens: 1,
                reasoningOutputTokens: 0
            )
        }
        let first = OpencodeProviderUsage(
            today: nil, dailyTokenUsage: [], roundCount: 1, cost: 0,
            recentSamples: [sample("prompt-a")]
        )
        let second = OpencodeProviderUsage(
            today: nil, dailyTokenUsage: [], roundCount: 1, cost: 0,
            recentSamples: [sample("prompt-b")]
        )
        let snapshot = OpencodeLocalUsage(
            byProvider: ["antigravity": first, "google": second],
            modelsByProvider: [:], dbPath: nil, scannedAt: nil
        )

        let slice = try XCTUnwrap(snapshot.antigravitySlice)
        XCTAssertEqual(
            Set(slice.recentSamples.map(\.promptID)),
            ["prompt-a", "opencode:alias1:prompt-b"]
        )

        let namespaced = OpencodeUsageMerger.mergeSamples(
            native: [], opencode: slice, providerID: "google"
        )
        XCTAssertEqual(
            Set(namespaced.map(\.promptID)),
            [
                "opencode:google:prompt-a",
                "opencode:google:opencode:alias1:prompt-b"
            ]
        )
    }

    func testUsageProjectionCombinesClientsIndependentlyWithOneOpencodeSnapshot() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)

        func openUsage(input: Int, promptID: String) -> OpencodeProviderUsage {
            let daily = OpencodeDailyUsage(
                dayStart: day,
                inputTokens: input,
                outputTokens: input,
                cacheReadTokens: input,
                reasoningTokens: 1,
                totalTokens: input * 3 + 1,
                turns: 1,
                rounds: 1
            )
            let sample = LocalTokenUsageSample(
                completedAt: day,
                modelName: "model-\(input)",
                promptID: promptID,
                inputTokens: input,
                cachedInputTokens: input,
                outputTokens: input,
                reasoningOutputTokens: 1
            )
            return OpencodeProviderUsage(
                today: daily,
                dailyTokenUsage: [daily],
                roundCount: 1,
                cost: 0,
                recentSamples: [sample]
            )
        }

        let snapshot = OpencodeLocalUsage(
            byProvider: [
                OpencodeLocalUsage.glmProviderID: openUsage(input: 20, promptID: "glm"),
                OpencodeLocalUsage.minimaxCodingPlanProviderID: openUsage(input: 30, promptID: "minimax"),
                OpencodeLocalUsage.openAIProviderID: openUsage(input: 40, promptID: "codex"),
                "google": openUsage(input: 50, promptID: "antigravity")
            ],
            modelsByProvider: [:],
            dbPath: "/tmp/opencode.db",
            scannedAt: day
        )

        let minimax = MinimaxLocalUsage(
            today: nil,
            dailyTokenUsage: [MinimaxDailyUsage(dayStart: day, inputTokens: 1, outputTokens: 1)],
            scannedAt: day, sessionCount: 1, eventCount: 1, failedSessionCount: 0,
            recentSamples: []
        )
        let antigravity = AntigravityLocalUsage(
            today: nil,
            dailyTokenUsage: [AntigravityDailyUsage(dayStart: day, inputTokens: 2, outputTokens: 2)],
            scannedAt: day, sessionCount: 1, eventCount: 1, failedSessionCount: 0,
            recentSamples: []
        )
        let glm = GlmLocalUsage(
            today: nil,
            dailyTokenUsage: [GlmDailyUsage(dayStart: day, inputTokens: 3, outputTokens: 3)],
            scannedAt: day, sessionCount: 1, eventCount: 1, failedSessionCount: 0,
            recentSamples: []
        )
        let codex = [DailyTokenUsage(
            dayStart: day, inputTokens: 4, cachedInputTokens: 0,
            outputTokens: 4, reasoningOutputTokens: 0, rounds: 1, turns: 1
        )]

        func makeStatus(
            id: String,
            kind: ProviderKind,
            accent: AccentColor
        ) -> ProviderStatus {
            var status = ProviderStatus(
                id: id, displayName: id, kind: kind,
                iconSystemName: "circle", accentColor: accent,
                refreshIntervalSeconds: 300, state: .ready
            )
            status.opencodeUsage = snapshot
            status.mergeOpencodeUsage = true
            return status
        }

        // Minimax Token Plan：native MiniMax Code + OpenCode。
        var minimaxStatus = makeStatus(id: "minimax", kind: .minimaxTokenPlan, accent: .minimax)
        minimaxStatus.minimaxLocalUsage = minimax
        let projectionMinimax = minimaxStatus.usageProjection(for: nil)
        XCTAssertEqual(projectionMinimax.clientIDs, [ClientID.minimaxCode, ClientID.openCode])
        XCTAssertEqual(projectionMinimax.dailyTokenUsage.first?.input, 31)
        XCTAssertEqual(projectionMinimax.recentSamples.count, 1)

        // Antigravity：native + OpenCode（google 别名分片）。
        var antigravityStatus = makeStatus(id: "antigravity", kind: .antigravity, accent: .antigravity)
        antigravityStatus.antigravityLocalUsage = antigravity
        let projectionAntigravity = antigravityStatus.usageProjection(for: nil)
        XCTAssertEqual(projectionAntigravity.clientIDs, [ClientID.antigravity, ClientID.openCode])
        XCTAssertEqual(projectionAntigravity.dailyTokenUsage.first?.input, 52)
        XCTAssertEqual(projectionAntigravity.recentSamples.count, 1)

        // GLM Coding Plan：native ZCode + OpenCode。
        var glmStatus = makeStatus(id: "glm", kind: .glmCodingPlan, accent: .glm)
        glmStatus.glmLocalUsage = glm
        let projectionGlm = glmStatus.usageProjection(for: nil)
        XCTAssertEqual(projectionGlm.clientIDs, [ClientID.zcode, ClientID.openCode])
        XCTAssertEqual(projectionGlm.dailyTokenUsage.first?.input, 23)
        XCTAssertEqual(projectionGlm.recentSamples.count, 1)

        // Codex：codexUsageDetails（cache-inclusive input）+ OpenCode openAI 分片。
        // 统一化在 LocalUsageDaily 边界完成：native input 归一为 uncached 4，
        // OpenCode 贡献 input 40；cacheRead 0 + 40。
        let codexInfo = QuotaInfo(
            models: [], resetCredits: nil, planLabel: nil, accountEmail: nil,
            codexUsageDetails: CodexUsageDetails(
                primary: nil, secondary: nil, lastPrompt: nil,
                dailyTokenUsage: codex, recentSamples: [], scannedAt: day
            ),
            fetchedAt: day
        )
        var codexStatus = makeStatus(id: "codex", kind: .codexChatGpt, accent: .chatgpt)
        codexStatus.state = .ok(codexInfo)
        let projectionCodex = codexStatus.usageProjection(for: codexInfo)
        XCTAssertEqual(projectionCodex.clientIDs, [ClientID.codex, ClientID.openCode])
        XCTAssertEqual(projectionCodex.dailyTokenUsage.first?.input, 44)
        XCTAssertEqual(projectionCodex.dailyTokenUsage.first?.cacheRead, 40)
        XCTAssertEqual(projectionCodex.recentSamples.count, 1)
    }

    func testUsageProjectionNormalizesCodexAndOpencodeCacheInputAtBoundary() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let native = DailyTokenUsage(
            dayStart: day,
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 10,
            reasoningOutputTokens: 5,
            rounds: 2,
            turns: 1
        )
        let open = OpencodeProviderUsage(
            today: nil,
            dailyTokenUsage: [OpencodeDailyUsage(
                dayStart: day,
                inputTokens: 30,
                outputTokens: 6,
                cacheReadTokens: 40,
                reasoningTokens: 2,
                turns: 2,
                rounds: 3
            )],
            roundCount: 3,
            cost: 0,
            recentSamples: []
        )

        // 生产路径：统一模型在 LocalUsageDaily 边界归一 cache-inclusive input。
        // native 100（含 cache 20）→ uncached 80 + cacheRead 20；OpenCode 30 + 40。
        let info = QuotaInfo(
            models: [], resetCredits: nil, planLabel: nil, accountEmail: nil,
            codexUsageDetails: CodexUsageDetails(
                primary: nil, secondary: nil, lastPrompt: nil,
                dailyTokenUsage: [native], recentSamples: [], scannedAt: day
            ),
            fetchedAt: day
        )
        var status = ProviderStatus(
            id: "codex", displayName: "Codex", kind: .codexChatGpt,
            iconSystemName: "circle", accentColor: .chatgpt,
            refreshIntervalSeconds: 300, state: .ok(info)
        )
        status.opencodeUsage = OpencodeLocalUsage(
            byProvider: [OpencodeLocalUsage.openAIProviderID: open],
            modelsByProvider: [:], dbPath: nil, scannedAt: nil
        )
        status.mergeOpencodeUsage = true

        let projection = status.usageProjection(for: info)
        let mergedDay = try XCTUnwrap(projection.dailyTokenUsage.first)
        // uncached: 80 + 30；cacheRead: 20 + 40；cache-inclusive 仍是 170。
        XCTAssertEqual(mergedDay.input, 110)
        XCTAssertEqual(mergedDay.cacheRead, 60)
        XCTAssertEqual(mergedDay.input + mergedDay.cacheRead, 170)
        XCTAssertEqual(mergedDay.output, 16)
        XCTAssertEqual(mergedDay.reasoning, 7)
        XCTAssertEqual(mergedDay.rounds, 5)
        XCTAssertEqual(mergedDay.turns, 3)
    }

    func testReaderCountsTokenizedRoundsAndDistinctTurns() throws {
        let databaseURL = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let firstTimestamp: Int64 = 1_800_000_000_000
        try insert(
            databaseURL: databaseURL,
            id: "a1",
            sessionID: "session-1",
            timestamp: firstTimestamp,
            payload: payload(parent: "user-1", input: 10, output: 4, reasoning: 2, cacheRead: 30, cacheWrite: 3)
        )
        try insert(
            databaseURL: databaseURL,
            id: "a2",
            sessionID: "session-1",
            timestamp: firstTimestamp + 1_000,
            payload: payload(parent: "user-1", input: 5, output: 2, reasoning: 1, cacheRead: 10)
        )
        try insert(
            databaseURL: databaseURL,
            id: "a3",
            sessionID: "session-1",
            timestamp: firstTimestamp + 86_400_000,
            payload: payload(parent: "user-2", input: 20, output: 5)
        )
        try insert(
            databaseURL: databaseURL,
            id: "zero",
            sessionID: "session-1",
            timestamp: firstTimestamp + 2_000,
            payload: payload(parent: "user-zero", input: 0, output: 0, reasoning: 0, cacheRead: 0)
        )
        try insert(
            databaseURL: databaseURL,
            id: "user-message",
            sessionID: "session-1",
            timestamp: firstTimestamp + 3_000,
            payload: #"{"role":"user","providerID":"zhipuai-coding-plan"}"#
        )

        let calendar = Calendar(identifier: .gregorian)
        let reader = try OpencodeDBReader(path: databaseURL)
        defer { reader.close() }
        let aggregate = try reader.aggregate(calendar: calendar)

        XCTAssertEqual(aggregate.roundCount["zhipuai-coding-plan"], 3)
        XCTAssertEqual(aggregate.samples["zhipuai-coding-plan"]?.count, 3)
        XCTAssertEqual(aggregate.samples["zhipuai-coding-plan"]?.first?.inputTokens, 40)
        XCTAssertEqual(aggregate.samples["zhipuai-coding-plan"]?.first?.promptID, "session-1:user-1")

        let daily = try XCTUnwrap(aggregate.perProviderDay["zhipuai-coding-plan"])
            .values
            .sorted { $0.dayStart < $1.dayStart }
        XCTAssertEqual(daily.count, 2)
        XCTAssertEqual(daily[0].rounds, 2)
        XCTAssertEqual(daily[0].turns, 1)
        XCTAssertEqual(daily[0].totalTokens, 64)
        XCTAssertEqual(daily[0].cacheWriteTokens, 3)
        XCTAssertEqual(daily[1].rounds, 1)
        XCTAssertEqual(daily[1].turns, 1)
        XCTAssertEqual(daily[1].totalTokens, 25)
    }

    func testGLMOpencodeSamplesMatchQuotaModel() {
        XCTAssertTrue(
            LocalUsageSummaryBuilder.modelMatches(
                providerKind: .glmCodingPlan,
                quotaModelName: "glm_coding_plan",
                sampleModelName: "glm-5.2"
            )
        )
        XCTAssertFalse(
            LocalUsageSummaryBuilder.modelMatches(
                providerKind: .glmCodingPlan,
                quotaModelName: "glm_coding_plan",
                sampleModelName: "gpt-5"
            )
        )
    }

    func testSnapshotPadsSevenDaysAndRebasesAfterMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2027, month: 1, day: 10))
        )
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let usage = OpencodeDailyUsage(
            dayStart: today,
            inputTokens: 10,
            outputTokens: 5,
            totalTokens: 15,
            turns: 1,
            rounds: 2
        )
        let previous = OpencodeDailyUsage(
            dayStart: yesterday,
            inputTokens: 20,
            turns: 1,
            rounds: 1
        )
        let aggregate = OpencodeDBAggregate(
            perProviderDay: ["zhipuai-coding-plan": [yesterday: previous, today: usage]],
            roundCount: ["zhipuai-coding-plan": 3],
            cost: [:],
            models: ["zhipuai-coding-plan": ["glm-5.2"]],
            samples: [:]
        )

        let snapshot = OpencodeUsageScanner.buildSnapshot(
            from: aggregate,
            dbPath: "/tmp/opencode.db",
            calendar: calendar,
            now: today.addingTimeInterval(10 * 60 * 60)
        )
        let slice = try XCTUnwrap(snapshot.glmSlice)
        XCTAssertEqual(slice.dailyTokenUsage.count, 7)
        XCTAssertEqual(slice.dailyTokenUsage.last?.rounds, 2)
        XCTAssertEqual(slice.today?.totalTokens, 15)

        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let rebased = OpencodeUsageScanner.rebaseCachedSnapshot(
            snapshot,
            calendar: calendar,
            now: tomorrow.addingTimeInterval(60)
        )
        XCTAssertEqual(rebased.glmSlice?.dailyTokenUsage.count, 7)
        XCTAssertEqual(rebased.glmSlice?.dailyTokenUsage.last?.rounds, 0)
        XCTAssertNil(rebased.glmSlice?.today)
    }

    private func makeDatabase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-opencode-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "OpencodeUsageTests", code: 1)
        }
        defer { sqlite3_close(db) }
        try exec(
            db: db,
            sql: """
            CREATE TABLE message (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              time_created INTEGER NOT NULL,
              time_updated INTEGER NOT NULL,
              data TEXT NOT NULL
            )
            """
        )
        return url
    }

    private func insert(
        databaseURL: URL,
        id: String,
        sessionID: String,
        timestamp: Int64,
        payload: String
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "OpencodeUsageTests", code: 2)
        }
        defer { sqlite3_close(db) }
        let escapedPayload = payload.replacingOccurrences(of: "'", with: "''")
        let sql = """
        INSERT INTO message (id, session_id, time_created, time_updated, data)
        VALUES ('\(id)', '\(sessionID)', \(timestamp), \(timestamp), '\(escapedPayload)')
        """
        try exec(db: db, sql: sql)
    }

    private func payload(
        parent: String,
        input: Int,
        output: Int,
        reasoning: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0
    ) -> String {
        """
        {"role":"assistant","providerID":"zhipuai-coding-plan","modelID":"glm-5.2","parentID":"\(parent)","tokens":{"input":\(input),"output":\(output),"reasoning":\(reasoning),"cache":{"read":\(cacheRead),"write":\(cacheWrite)}}}
        """
    }

    private func exec(db: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        defer {
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
        }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "sqlite error \(result)"
            throw NSError(
                domain: "OpencodeUsageTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
