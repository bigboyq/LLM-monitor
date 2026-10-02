import XCTest
@testable import LLM_monitor

final class DshHarnessFramesTests: XCTestCase {

    private func makeDshProvider(
        dayStart: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        reasoningTokens: Int = 0,
        totalTokens: Int,
        rounds: Int
    ) -> DshProviderUsage {
        let today = DshDailyUsage(
            dayStart: dayStart,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            turns: 1,
            rounds: rounds
        )
        return DshProviderUsage(
            today: today,
            dailyTokenUsage: [],
            sessionCount: 1,
            roundCount: rounds,
            recentSamples: []
        )
    }

    /// 引用点已从 `DshUsageMerger` 迁到 `DshHarnessFrames` + `UsageProjectionKernel`，
    /// 断言语义不变：dsh 帧不声明归属，由内核按 clientBindings 的 dsh 条目解析，
    /// 每张 quota 卡只消费自己那组 provider 别名，另一张卡的数值
    /// （999 / 888 之类）不得混入。`today` + `roundCount` 两个旧字段在新链路上
    /// 合成为 daily 的一行（`UnifiedDailyTokenUsage.input/cacheRead/output/reasoning/rounds`），
    /// 这正是卡片层真正消费的形态。
    func testDshFramesSelectOnlyTheirProviderAliases() throws {
        let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(
            name: String,
            usage: DshLocalUsage,
            quotaProviderID: String,
            inputTokens: Int,
            cacheReadTokens: Int,
            outputTokens: Int,
            reasoningTokens: Int,
            roundCount: Int
        )] = [
            (
                name: "deepseek",
                usage: DshLocalUsage(
                    byProvider: [
                        "deepseek-official": makeDshProvider(
                            dayStart: dayStart,
                            inputTokens: 100,
                            outputTokens: 20,
                            cacheReadTokens: 50,
                            reasoningTokens: 10,
                            totalTokens: 170,
                            rounds: 2
                        ),
                        "minimax-cn": makeDshProvider(
                            dayStart: dayStart,
                            inputTokens: 999,
                            outputTokens: 999,
                            totalTokens: 999,
                            rounds: 1
                        )
                    ],
                    modelsByProvider: ["deepseek-official": ["deepseek-v4-flash"]],
                    sessionsRoot: "/tmp/.dsh/sessions",
                    sessionCount: 2,
                    eventCount: 3,
                    scannedAt: Date()
                ),
                quotaProviderID: QuotaProviderID.deepseek,
                inputTokens: 100,
                cacheReadTokens: 50,
                outputTokens: 20,
                reasoningTokens: 10,
                roundCount: 2
            ),
            (
                name: "glm",
                usage: DshLocalUsage(
                    byProvider: [
                        "zhipuai": makeDshProvider(
                            dayStart: dayStart,
                            inputTokens: 50,
                            outputTokens: 10,
                            cacheReadTokens: 25,
                            reasoningTokens: 5,
                            totalTokens: 80,
                            rounds: 2
                        ),
                        "minimax-cn": makeDshProvider(
                            dayStart: dayStart,
                            inputTokens: 999,
                            outputTokens: 999,
                            totalTokens: 999,
                            rounds: 1
                        )
                    ],
                    modelsByProvider: ["zhipuai": ["GLM-4.5"]],
                    sessionsRoot: "/tmp/.dsh/sessions",
                    sessionCount: 2,
                    eventCount: 3,
                    scannedAt: Date()
                ),
                quotaProviderID: QuotaProviderID.zhipu,
                inputTokens: 50,
                cacheReadTokens: 25,
                outputTokens: 10,
                reasoningTokens: 5,
                roundCount: 2
            ),
            (
                name: "minimax",
                usage: DshLocalUsage(
                    byProvider: [
                        "minimax": makeDshProvider(
                            dayStart: dayStart,
                            inputTokens: 100,
                            outputTokens: 15,
                            cacheReadTokens: 20,
                            reasoningTokens: 5,
                            totalTokens: 130,
                            rounds: 3
                        ),
                        "zhipu": makeDshProvider(
                            dayStart: dayStart,
                            inputTokens: 888,
                            outputTokens: 888,
                            totalTokens: 888,
                            rounds: 1
                        )
                    ],
                    modelsByProvider: ["minimax": ["MiniMax-M3"]],
                    sessionsRoot: "/tmp/.dsh/sessions",
                    sessionCount: 2,
                    eventCount: 4,
                    scannedAt: Date()
                ),
                quotaProviderID: QuotaProviderID.minimax,
                inputTokens: 100,
                cacheReadTokens: 20,
                outputTokens: 15,
                reasoningTokens: 5,
                roundCount: 3
            )
        ]

        for testCase in cases {
            let frames = DshHarnessFrames.frames(from: testCase.usage)
            XCTAssertFalse(frames.isEmpty, testCase.name)
            let projections = UsageProjectionKernel.project(
                frames: frames,
                bindings: AppConfig.defaultClientBindings
            )
            let projection = try XCTUnwrap(
                projections.first { $0.quotaProviderID == testCase.quotaProviderID },
                testCase.name
            )
            XCTAssertEqual(projection.clientID, ClientID.dsh, testCase.name)
            XCTAssertEqual(projection.quotaProviderID, testCase.quotaProviderID, testCase.name)
            let day = try XCTUnwrap(projection.daily.first, testCase.name)
            XCTAssertEqual(day.input, testCase.inputTokens, testCase.name)
            XCTAssertEqual(day.cacheRead, testCase.cacheReadTokens, testCase.name)
            XCTAssertEqual(day.output, testCase.outputTokens, testCase.name)
            XCTAssertEqual(day.reasoning, testCase.reasoningTokens, testCase.name)
            XCTAssertEqual(day.rounds, testCase.roundCount, testCase.name)
        }
    }
}
