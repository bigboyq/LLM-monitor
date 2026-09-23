import XCTest
@testable import LLM_monitor

final class UIUsageRegressionTests: XCTestCase {
    @MainActor
    func testSettingsGroupingUsesOnlySevenDisplayedDays() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-monitor-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ConfigStore(configURL: root.appendingPathComponent("config.json"))
        let state = AppState(descriptors: [], configStore: store)
        defer { state.stop() }
        let view = SettingsView(
            configStore: store,
            loginItemService: LoginItemService(),
            state: state,
            descriptors: []
        )

        var calendar = Calendar.current
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let template = (0..<7).map { offset in
            UnifiedDailyTokenUsage(
                dayStart: calendar.date(byAdding: .day, value: -offset, to: today)!,
                input: 0
            )
        }
        let inWindow = (0..<7).map { offset in
            LocalTokenUsageSample(
                completedAt: calendar.date(byAdding: .day, value: -offset, to: today)!
                    .addingTimeInterval(3600),
                modelName: "gemini-2.5-pro",
                promptID: "in-\(offset)",
                inputTokens: 100,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0
            )
        }
        let outsideWindow = LocalTokenUsageSample(
            completedAt: calendar.date(byAdding: .day, value: -7, to: today)!
                .addingTimeInterval(3600),
            modelName: "claude-sonnet",
            promptID: "outside",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0
        )
        let samples = inWindow + [outsideWindow]

        let daily = view.dailyUsage(for: samples, matching: template)
        XCTAssertEqual(daily.count, 7)
        XCTAssertEqual(daily.reduce(0) { $0 + $1.totalTokens }, 700)

        let contribution = ClientUsageContribution(
            clientID: ClientID.antigravity,
            displayName: "Antigravity",
            dailyTokenUsage: template,
            recentSamples: samples
        )
        let status = ProviderStatus(
            id: "antigravity",
            displayName: "Antigravity",
            kind: .antigravity,
            iconSystemName: "circle",
            accentColor: .antigravity,
            refreshIntervalSeconds: 300,
            state: .ready
        )
        let rows = view.antigravityUsageRows(status: status, contribution: contribution)
        XCTAssertEqual(rows.map(\.usageGroupID), [AntigravityUsageGroup.gemini.rawValue])
        XCTAssertEqual(rows.first?.totalTokens, 700)

        let oldOnly = ClientUsageContribution(
            clientID: ClientID.antigravity, displayName: "Antigravity",
            dailyTokenUsage: template, recentSamples: [outsideWindow]
        )
        XCTAssertTrue(view.antigravityUsageRows(status: status, contribution: oldOnly).isEmpty)

        var glmSamples = inWindow
        for index in glmSamples.indices {
            glmSamples[index].sourceProviderID = "builtin:bigmodel-coding-plan"
        }
        var oldOffPeak = outsideWindow
        oldOffPeak.sourceProviderID = "offpeak-idle-plan"
        let glmContribution = ClientUsageContribution(
            clientID: ClientID.zcode, displayName: "ZCode",
            dailyTokenUsage: template, recentSamples: glmSamples + [oldOffPeak]
        )
        let glmStatus = ProviderStatus(
            id: "glm", displayName: "GLM", kind: .glmCodingPlan,
            iconSystemName: "circle", accentColor: .glm,
            refreshIntervalSeconds: 300, state: .ready
        )
        let glmRows = view.glmUsageRows(status: glmStatus, contribution: glmContribution)
        XCTAssertEqual(glmRows.count, 1, "窗口外闲时样本不能创建额外分组")
        XCTAssertEqual(glmRows.first?.totalTokens, 700)
        XCTAssertEqual(glmRows.first?.recentSamples.count, 7)
    }

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
