import XCTest
import Foundation
@testable import LLM_monitor

/// Provider × Harness 统一投影内核的回归护栏。
///
/// 本文件有两层：
/// 1. **新旧投影 diff**（`LegacyProjector`）：把 P1 改造前的算法
///    （`DshUsageMerger` 的切片 / 逐日合并 / `dsh:<source>:` 命名空间 +
///    四个 contribution 工厂）原样复刻成测试内的参考实现，对同一组
///    `ProviderStatus` 输入逐日、逐桶、逐贡献比对内核输出。参考实现在测试里
///    刻意不复用生产类型，保证它是"改造前"的独立副本而不是自证。
/// 2. **内核契约**：帧分组顺序、当日 max 修补、per-model 四桶、名义价值、
///    截断聚合、promptID 命名空间登记表。
///
/// 唯一允许的差异：DSH sample 的 `dsh:dsh:<provider>:` → `dsh:<provider>:`
/// （旧 Merger 在 scanner 已带 `dsh:` 的 sourceProviderID 上又叠了一层）。
/// diff 用例显式按这条规则归一后再比对，并有独立用例锁死新格式。
final class UsageProjectionKernelTests: XCTestCase {

    // MARK: - fixture

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func sample(
        _ promptID: String,
        day: Date,
        model: String?,
        input: Int,
        cacheRead: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        sourceProviderID: String? = nil,
        offset: TimeInterval = 3600
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: day.addingTimeInterval(offset),
            modelName: model,
            promptID: promptID,
            inputTokens: input + cacheRead,
            cachedInputTokens: cacheRead,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            sourceProviderID: sourceProviderID
        )
    }

    private func openUsage(
        _ promptIDs: [String],
        day: Date,
        model: String,
        input: Int,
        cacheRead: Int = 0,
        output: Int = 0,
        reasoning: Int = 0
    ) -> OpencodeProviderUsage {
        let daily = OpencodeDailyUsage(
            dayStart: day,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: 0,
            reasoningTokens: reasoning,
            totalTokens: input + cacheRead + output + reasoning,
            turns: promptIDs.count,
            rounds: promptIDs.count
        )
        return OpencodeProviderUsage(
            today: daily,
            dailyTokenUsage: [daily],
            roundCount: promptIDs.count,
            cost: 0,
            recentSamples: promptIDs.map {
                sample($0, day: day, model: model, input: input,
                       cacheRead: cacheRead, output: output, reasoning: reasoning)
            }
        )
    }

    private func dshProvider(
        _ key: String,
        day: Date,
        model: String,
        input: Int,
        cacheRead: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        turnIDs: [String]
    ) -> DshProviderUsage {
        let daily = DshDailyUsage(
            dayStart: day,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: 0,
            reasoningTokens: reasoning,
            totalTokens: input + cacheRead + output + reasoning,
            turns: turnIDs.count,
            rounds: turnIDs.count
        )
        return DshProviderUsage(
            today: daily,
            dailyTokenUsage: [daily],
            sessionCount: 1,
            roundCount: turnIDs.count,
            // scanner 原生 promptID 已带 `dsh:`，sourceProviderID 是 `dsh:<provider>`。
            recentSamples: turnIDs.enumerated().map { index, turn in
                sample(
                    "dsh:session-\(key):turn:\(turn)",
                    day: day,
                    model: model,
                    input: input,
                    cacheRead: cacheRead,
                    output: output,
                    reasoning: reasoning,
                    sourceProviderID: "dsh:\(key)",
                    offset: 3600 + TimeInterval(index)
                )
            }
        )
    }

    private func localUsage(
        day: Date,
        model: String?,
        samples: [LocalTokenUsageSample]
    ) -> ProviderLocalUsage {
        let daily = LocalDailyTokenUsage(
            dayStart: day,
            inputTokens: 10,
            outputTokens: 4,
            cacheReadTokens: 2,
            cacheWriteTokens: 0,
            reasoningTokens: 1,
            totalTokens: 17,
            turns: 1,
            rounds: 1
        )
        return ProviderLocalUsage(
            today: daily,
            dailyTokenUsage: [daily],
            scannedAt: day,
            sessionCount: 1,
            eventCount: 1,
            failedSessionCount: 0,
            recentSamples: samples
        )
    }

    /// 一组覆盖全部 5 张卡、全部 6 个 client 的 `ProviderStatus`。
    /// 每张卡都挂满它能消费的所有来源，且 DSH / OpenCode / ZCode 都是
    /// 多 provider 共享账本（多 alias、多分片）。
    private func makeStatuses(now: Date) -> (statuses: [ProviderStatus], info: QuotaInfo?) {
        let day = utcCalendar().startOfDay(for: now)

        // ---- OpenCode 快照：四张卡各一个 provider 分片 + Antigravity 双 alias ----
        let opencode = OpencodeLocalUsage(
            byProvider: [
                OpencodeLocalUsage.openAIProviderID: openUsage(
                    ["codex-turn"], day: day, model: "gpt-5.6-sol", input: 40, cacheRead: 10, output: 4
                ),
                "antigravity": openUsage(
                    ["antigravity-turn"], day: day, model: "gemini-3.6-flash", input: 50, output: 6
                ),
                "google": openUsage(
                    ["google-turn"], day: day, model: "claude-sonnet-4.6", input: 60, cacheRead: 20, output: 8
                ),
                OpencodeLocalUsage.minimaxCodingPlanProviderID: openUsage(
                    ["minimax-turn"], day: day, model: "MiniMax-M3", input: 30, output: 6
                ),
                OpencodeLocalUsage.glmProviderID: openUsage(
                    ["glm-turn"], day: day, model: "GLM-5.3", input: 20, cacheRead: 5, output: 4
                ),
                OpencodeLocalUsage.deepseekProviderID: openUsage(
                    ["deepseek-turn"], day: day, model: "deepseek-v4-flash", input: 70, cacheRead: 30, output: 5
                )
            ],
            modelsByProvider: [:],
            dbPath: "/tmp/opencode.db",
            scannedAt: now
        )

        // ---- DSH 快照：三张卡各 1~2 个 provider 路由 + 一个不相关路由 ----
        var dsh = DshLocalUsage(
            byProvider: [
                "deepseek-official": dshProvider(
                    "deepseek-official", day: day, model: "deepseek-v4-flash",
                    input: 100, cacheRead: 50, output: 20, reasoning: 10, turnIDs: ["1", "2"]
                ),
                "minimax-cn": dshProvider(
                    "minimax-cn", day: day, model: "MiniMax-M3",
                    input: 80, cacheRead: 20, output: 15, reasoning: 5, turnIDs: ["1"]
                ),
                "zhipuai": dshProvider(
                    "zhipuai", day: day, model: "GLM-5.3",
                    input: 50, cacheRead: 25, output: 10, reasoning: 5, turnIDs: ["1", "2"]
                ),
                "openai": dshProvider(
                    "openai", day: day, model: "gpt-5.6-sol",
                    input: 999, output: 999, turnIDs: ["1"]
                )
            ],
            modelsByProvider: [:],
            sessionsRoot: "/tmp/.dsh/sessions",
            sessionCount: 4,
            eventCount: 7,
            scannedAt: now
        )
        dsh.isTruncated = true

        // ---- ZCode 快照：智谱系 native + minimax / deepseek 两个非智谱分片 ----
        let zcodeNativeDay = GlmDailyUsage(
            dayStart: day, inputTokens: 30, outputTokens: 6, cacheReadTokens: 4,
            cacheWriteTokens: 0, reasoningTokens: 2,
            totalTokens: 42, turns: 1, rounds: 1
        )
        let zcode = GlmLocalUsage(
            today: zcodeNativeDay,
            dailyTokenUsage: [zcodeNativeDay],
            scannedAt: now,
            sessionCount: 1,
            eventCount: 1,
            failedSessionCount: 0,
            recentSamples: [
                sample("glm-s:glm-t1", day: day, model: "GLM-5.3", input: 30,
                       cacheRead: 4, output: 6, reasoning: 2,
                       sourceProviderID: "builtin:bigmodel-coding-plan")
            ],
            offPeakWindows: [],
            providerSlices: [
                ZcodeProviderSlice.deepseek.rawValue: openUsage(
                    ["ds-s:ds-t1"], day: day, model: "deepseek-flash", input: 200, output: 40
                ),
                ZcodeProviderSlice.minimax.rawValue: openUsage(
                    ["mm-s:mm-t1", "mm-s:mm-t2"], day: day, model: "MiniMax-M3.1-Flash-Preview",
                    input: 120, output: 20
                )
            ]
        )

        let minimaxNative = localUsage(
            day: day, model: "MiniMax-M3",
            samples: [sample("mm-native:turn-1", day: day, model: "MiniMax-M3",
                             input: 10, cacheRead: 2, output: 4, reasoning: 1)]
        )
        let antigravityNative = localUsage(
            day: day, model: "gemini-3.6-flash",
            samples: [sample("ag-native:turn-1", day: day, model: "gemini-3.6-flash",
                             input: 10, cacheRead: 2, output: 4, reasoning: 1)]
        )

        let codexDaily = [DailyTokenUsage(
            dayStart: day, inputTokens: 30, cachedInputTokens: 10,
            outputTokens: 8, reasoningOutputTokens: 2, rounds: 1, turns: 1
        )]
        let codexInfo = QuotaInfo(
            models: [], resetCredits: nil, planLabel: "Free", accountEmail: nil,
            codexUsageDetails: CodexUsageDetails(
                primary: nil, secondary: nil, lastPrompt: nil,
                dailyTokenUsage: codexDaily,
                recentSamples: [
                    sample("codex:turn-1", day: day, model: "gpt-5.6-sol", input: 30,
                           cacheRead: 10, output: 8, reasoning: 2)
                ],
                scannedAt: now
            ),
            fetchedAt: now,
            balanceDetail: nil
        )

        func makeStatus(
            _ kind: ProviderKind,
            name: String,
            accent: AccentColor
        ) -> ProviderStatus {
            var status = ProviderStatus(
                id: kind.providerID, displayName: name, kind: kind,
                iconSystemName: "circle", accentColor: accent,
                refreshIntervalSeconds: 300, state: .ready
            )
            status.opencodeUsage = opencode
            status.dshUsage = dsh
            status.glmLocalUsage = zcode
            status.mergeOpencodeUsage = true
            status.mergeZcodeUsage = true
            return status
        }

        var codex = makeStatus(.codexChatGpt, name: "ChatGPT Plan", accent: .chatgpt)
        codex.state = .ok(codexInfo)
        var antigravity = makeStatus(.antigravity, name: "Antigravity", accent: .antigravity)
        antigravity.antigravityLocalUsage = antigravityNative
        var minimax = makeStatus(.minimaxTokenPlan, name: "MiniMax Token Plan", accent: .minimax)
        minimax.minimaxLocalUsage = minimaxNative
        let glm = makeStatus(.glmCodingPlan, name: "GLM Coding Plan", accent: .glm)
        let deepseek = makeStatus(.deepseek, name: "DeepSeek", accent: .deepseek)

        return ([codex, antigravity, minimax, glm, deepseek], codexInfo)
    }

    // MARK: - 新旧投影 diff

    /// 逐日、逐桶、逐贡献比对：同一组 `ProviderStatus` 输入，改造后的内核链路
    /// 必须与改造前的参考实现（测试内复刻的 `DshUsageMerger` + 工厂表）等价。
    func testNewProjectionMatchesLegacyReferenceProjection() throws {
        let now = Date()
        let (statuses, codexInfo) = makeStatuses(now: now)

        for status in statuses {
            let legacy = LegacyProjector.projections(
                status: status, info: status.kind == .codexChatGpt ? codexInfo : nil
            )
            let actual = status.usageProjection(for: status.kind == .codexChatGpt ? codexInfo : nil)

            XCTAssertEqual(
                actual.clientIDs, legacy.map(\.clientID),
                "\(status.kind) 贡献 clientID 列表必须与改造前一致"
            )

            for (index, expected) in legacy.enumerated() {
                let got = try XCTUnwrap(actual.contributions.indices.contains(index)
                                       ? actual.contributions[index] : nil, "\(status.kind)[\(index)]")
                XCTAssertEqual(got.displayName, expected.displayName, "\(status.kind)[\(index)] 显示名")
                XCTAssertEqual(
                    got.dailyTokenUsage, expected.daily,
                    "\(status.kind)/\(expected.clientID) 逐日聚合必须逐字段相等"
                )
                XCTAssertEqual(
                    got.scannedAt, expected.scannedAt, "\(status.kind)/\(expected.clientID) scannedAt"
                )
                XCTAssertEqual(
                    got.isTruncated, expected.isTruncated,
                    "\(status.kind)/\(expected.clientID) 截断位"
                )
                XCTAssertEqual(
                    Self.normalizedDSHPromptIDs(got.recentSamples),
                    Self.normalizedDSHPromptIDs(expected.samples),
                    "\(status.kind)/\(expected.clientID) 样本逐条相等（dsh:dsh: 归一后）"
                )
            }

            // 卡片层聚合口径：逐日相加 + 样本拼接 + scannedAt 取最新。
            XCTAssertEqual(
                actual.dailyTokenUsage,
                LegacyProjector.aggregateDaily(legacy),
                "\(status.kind) 卡片级逐日聚合必须与改造前一致"
            )
            XCTAssertEqual(
                actual.scannedAt,
                legacy.compactMap(\.scannedAt).max(),
                "\(status.kind) 卡片级 scannedAt 取最新"
            )
            XCTAssertEqual(
                actual.isTruncated,
                legacy.contains(where: \.isTruncated),
                "\(status.kind) 卡片级截断位：任一来源截断即截断"
            )
        }
    }

    // MARK: - dsh:dsh: 前缀清理

    /// 唯一允许的差异：DSH sample 的 promptID 从
    /// `dsh:dsh:<provider>:<scanner 原生 ID>` 变成 `dsh:<provider>:<scanner 原生 ID>`。
    /// 这里锁死新格式，并确认 sourceProviderID（诊断 / 智谱分类用）不变。
    func testDshSamplesUseSingleLayerPromptNamespace() throws {
        let now = Date()
        let (statuses, _) = makeStatuses(now: now)
        let deepseek = try XCTUnwrap(statuses.first { $0.kind == .deepseek })
        let dsh = try XCTUnwrap(
            deepseek.usageProjection(for: nil).contributions.first { $0.clientID == ClientID.dsh }
        )

        XCTAssertEqual(dsh.recentSamples.count, 2)
        XCTAssertEqual(
            dsh.recentSamples.map(\.promptID),
            [
                "dsh:deepseek-official:dsh:session-deepseek-official:turn:1",
                "dsh:deepseek-official:dsh:session-deepseek-official:turn:2"
            ]
        )
        XCTAssertFalse(
            dsh.recentSamples.contains { $0.promptID.hasPrefix("dsh:dsh:") },
            "旧的 dsh:dsh: 双层前缀必须已清理"
        )
        XCTAssertEqual(
            dsh.recentSamples.map(\.sourceProviderID),
            ["dsh:deepseek-official", "dsh:deepseek-official"],
            "sourceProviderID 是诊断 / 套餐分类的判据，不得随 promptID 一起改"
        )
    }

    // MARK: - 内核契约

    /// 帧顺序 = 组首次出现顺序；同组多帧按日相加、按帧序拼样本。
    func testKernelGroupsFramesInFirstAppearanceOrderAndSumsByDay() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let frames = [
            HarnessUsageFrame(
                clientID: ClientID.dsh, sourceKey: "a", quotaProviderID: QuotaProviderID.deepseek,
                daily: [UnifiedDailyTokenUsage(dayStart: day, input: 1, rounds: 1)],
                scannedAt: day
            ),
            HarnessUsageFrame(
                clientID: ClientID.openCode, sourceKey: "openai",
                quotaProviderID: QuotaProviderID.deepseek,
                daily: [UnifiedDailyTokenUsage(dayStart: day, input: 2, rounds: 1)],
                scannedAt: day.addingTimeInterval(10)
            ),
            HarnessUsageFrame(
                clientID: ClientID.dsh, sourceKey: "b", quotaProviderID: QuotaProviderID.deepseek,
                daily: [UnifiedDailyTokenUsage(dayStart: day, input: 4, rounds: 2)],
                scannedAt: day.addingTimeInterval(20)
            )
        ]

        let projections = UsageProjectionKernel.project(frames: frames)
        XCTAssertEqual(projections.map(\.clientID), [ClientID.dsh, ClientID.openCode])
        XCTAssertEqual(projections[0].daily.first?.input, 5, "同组两帧的同一天必须相加")
        XCTAssertEqual(projections[0].daily.first?.rounds, 3)
        XCTAssertEqual(projections[0].scannedAt, day.addingTimeInterval(20), "同组取最新 scannedAt")
        XCTAssertEqual(projections[1].scannedAt, day.addingTimeInterval(10))
    }

    /// 同一 clientID 的两帧若 quota 归属不同 → 两组（不跨 quota 相加）。
    func testKernelKeepsDistinctQuotaProvidersApart() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let frames = [
            HarnessUsageFrame(
                clientID: ClientID.zcode, sourceKey: "minimax",
                quotaProviderID: QuotaProviderID.minimax,
                daily: [UnifiedDailyTokenUsage(dayStart: day, input: 3)], scannedAt: day
            ),
            HarnessUsageFrame(
                clientID: ClientID.zcode, sourceKey: "deepseek",
                quotaProviderID: QuotaProviderID.deepseek,
                daily: [UnifiedDailyTokenUsage(dayStart: day, input: 5)], scannedAt: day
            )
        ]

        let projections = UsageProjectionKernel.project(frames: frames)
        XCTAssertEqual(
            projections.map(\.quotaProviderID),
            [QuotaProviderID.minimax, QuotaProviderID.deepseek]
        )
        XCTAssertEqual(projections.map { $0.daily.first?.input }, [3, 5])
    }

    /// 当日 max 修补：daily 落后于样本时按 max 补齐（历史锚点语义）。
    func testKernelRepairsCurrentDayFromSamples() {
        let now = Date()
        let today = utcCalendar().startOfDay(for: now)
        let frames = [
            HarnessUsageFrame(
                clientID: ClientID.dsh, sourceKey: "minimax",
                quotaProviderID: QuotaProviderID.minimax,
                daily: [UnifiedDailyTokenUsage(dayStart: today)],
                samples: [
                    sample("dsh:minimax:turn-1", day: today, model: "MiniMax-M3",
                           input: 381_000, cacheRead: 26_000_000, output: 71_000)
                ],
                scannedAt: now
            )
        ]

        let day = try! XCTUnwrap(
            UsageProjectionKernel.project(frames: frames, now: now, calendar: utcCalendar())
                .first?.daily.first
        )
        XCTAssertEqual(day.input, 381_000)
        XCTAssertEqual(day.cacheRead, 26_000_000)
        XCTAssertEqual(day.output, 71_000)
    }

    /// per-model 四桶：桶转换只走 `TokenUsageBuckets.fromSample`，
    /// 各模型桶之和必须等于该 client 的样本总桶。
    func testPerModelBucketsSumToSampleTotals() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            sample("a1", day: day, model: "MiniMax-M3", input: 100, cacheRead: 20, output: 30, reasoning: 5),
            sample("a2", day: day, model: "MiniMax-M3", input: 10, output: 4, reasoning: 1),
            sample("b1", day: day, model: "GLM-5.3", input: 50, cacheRead: 5, output: 6, reasoning: 2),
            sample("c1", day: day, model: nil, input: 7, output: 1)
        ]
        let frames = [HarnessUsageFrame(
            clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.minimax,
            daily: [UnifiedDailyTokenUsage](), samples: samples, scannedAt: day
        )]

        let projection = try! XCTUnwrap(UsageProjectionKernel.project(frames: frames).first)
        XCTAssertEqual(
            Set(projection.perModel.keys),
            ["MiniMax-M3", "GLM-5.3", ProviderHarnessProjection.unknownModelName]
        )
        XCTAssertEqual(projection.perModel["MiniMax-M3"]?.input, 110)
        XCTAssertEqual(projection.perModel["MiniMax-M3"]?.cacheRead, 20)
        XCTAssertEqual(projection.perModel["GLM-5.3"]?.reasoning, 2)
        XCTAssertEqual(projection.perModel[ProviderHarnessProjection.unknownModelName]?.input, 7)

        let summed = projection.perModel.values.reduce(TokenUsageBuckets.zero) { acc, buckets in
            TokenUsageBuckets(
                input: SaturatingArithmetic.add(acc.input, buckets.input),
                cacheRead: SaturatingArithmetic.add(acc.cacheRead, buckets.cacheRead),
                output: SaturatingArithmetic.add(acc.output, buckets.output),
                reasoning: SaturatingArithmetic.add(acc.reasoning, buckets.reasoning)
            )
        }
        let expected = samples.reduce(TokenUsageBuckets.zero) { acc, item in
            let buckets = TokenUsageBuckets.fromSample(item)
            return TokenUsageBuckets(
                input: SaturatingArithmetic.add(acc.input, buckets.input),
                cacheRead: SaturatingArithmetic.add(acc.cacheRead, buckets.cacheRead),
                output: SaturatingArithmetic.add(acc.output, buckets.output),
                reasoning: SaturatingArithmetic.add(acc.reasoning, buckets.reasoning)
            )
        }
        XCTAssertEqual(summed, expected, "per-model 桶之和必须等于样本总桶")
    }

    /// 名义价值：内核直接调 `ModelPricingCatalog.estimate`（含 DeepSeek 峰时倍率）。
    /// 断言"等于目录求值"而不是硬编码金额 —— 峰时倍率随 sample 时间变，
    /// 写死数字只会在改窗口配置时误报。
    func testProjectionValueUsesPricingCatalog() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = [
            sample("s1", day: day, model: "deepseek-v4-flash",
                   input: 1_000_000, cacheRead: 200_000, output: 100_000),
            sample("s2", day: day, model: "unknown-future-model", input: 5_000)
        ]
        let frames = [HarnessUsageFrame(
            clientID: ClientID.openCode, quotaProviderID: QuotaProviderID.deepseek,
            daily: [UnifiedDailyTokenUsage(dayStart: day, input: 1)],
            samples: samples,
            scannedAt: day
        )]

        let projection = try! XCTUnwrap(UsageProjectionKernel.project(frames: frames).first)
        XCTAssertEqual(
            projection.value,
            ModelPricingCatalog.estimate(
                samples: samples,
                quotaProviderID: QuotaProviderID.deepseek,
                deepseekPeakWindow: .defaultWindow
            ),
            "投影的名义价值必须逐字段等于 ModelPricingCatalog.estimate 的结果"
        )
        XCTAssertEqual(projection.value.currency, .cny)
        XCTAssertEqual(projection.value.unpricedModelNames, ["unknown-future-model"])
    }

    /// 截断聚合：任一帧截断即整组截断（快照级口径，不随分片稀释）。
    func testProjectionTruncationIsAnyFrameTruncated() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        func frame(_ key: String, truncated: Bool) -> HarnessUsageFrame {
            HarnessUsageFrame(
                clientID: ClientID.dsh, sourceKey: key,
                quotaProviderID: QuotaProviderID.deepseek,
                daily: [UnifiedDailyTokenUsage(dayStart: day, input: 1)],
                isTruncated: truncated, scannedAt: day
            )
        }
        let cases: [([HarnessUsageFrame], Bool)] = [
            ([frame("a", truncated: false), frame("b", truncated: false)], false),
            ([frame("a", truncated: false), frame("b", truncated: true)], true),
            ([frame("a", truncated: true), frame("b", truncated: false)], true)
        ]
        for (frames, expected) in cases {
            let projection = try! XCTUnwrap(UsageProjectionKernel.project(frames: frames).first)
            XCTAssertEqual(projection.isTruncated, expected)
        }
        XCTAssertTrue(UsageProjectionKernel.anyTruncated([frame("a", truncated: false), frame("b", truncated: true)]))
        XCTAssertFalse(UsageProjectionKernel.anyTruncated([]))
    }

    /// 命名空间登记表：每条规则的字面前缀。
    /// `zcode:<slice>:` 与 `ZcodeProviderSlice.namespacedSamples` 必须一致
    /// （后者仍在 ZcodeProviderSliceTests 里被间接使用，改一处必须改另一处）。
    func testUsageSampleNamespaceRegistryPrefixes() {
        let item = sample("p", day: Date(), model: "m", input: 1)
        XCTAssertNil(UsageSampleNamespace.native.prefix(sourceKey: "x"))
        XCTAssertNil(UsageSampleNamespace.codex.prefix(sourceKey: "x"))
        XCTAssertEqual(UsageSampleNamespace.dsh.prefix(sourceKey: "minimax-cn"), "dsh:minimax-cn:")
        XCTAssertEqual(UsageSampleNamespace.opencode.prefix(sourceKey: "openai"), "opencode:openai:")
        XCTAssertEqual(UsageSampleNamespace.zcodeSlice.prefix(sourceKey: "deepseek"), "zcode:deepseek:")
        XCTAssertEqual(UsageSampleNamespace.dsh.prefix(sourceKey: nil), "dsh:unknown:")

        let zcodeSlice = OpencodeProviderUsage(
            today: nil, dailyTokenUsage: [], roundCount: 0, cost: 0, recentSamples: [item]
        )
        XCTAssertEqual(
            UsageSampleNamespace.zcodeSlice.apply(
                to: [item], sourceKey: ZcodeProviderSlice.deepseek.providerPrefix
            ).map(\.promptID),
            ZcodeProviderSlice.namespacedSamples(zcodeSlice, for: .deepseek).map(\.promptID),
            "内核登记表与 ZcodeProviderSlice 的既有命名空间必须逐字一致"
        )
        XCTAssertEqual(UsageSampleNamespace.native.apply(to: [item]).map(\.promptID), ["p"])
    }

    /// 视图模型只做展示窗口裁剪 + 价值缓存，不再自己算合并规则。
    func testClientProviderUsageSummaryConsumesKernelProjection() throws {
        let now = Date()
        let today = utcCalendar().startOfDay(for: now)
        let frames = [HarnessUsageFrame(
            clientID: ClientID.dsh, sourceKey: "minimax", quotaProviderID: QuotaProviderID.minimax,
            daily: [UnifiedDailyTokenUsage(dayStart: today)],
            samples: [
                sample("dsh:minimax:turn-1", day: today, model: "MiniMax-M3",
                       input: 381_000, cacheRead: 26_000_000, output: 71_000)
            ],
            isTruncated: true,
            scannedAt: now
        )]
        let projection = try XCTUnwrap(UsageProjectionKernel.project(frames: frames, now: now).first)
        let summary = ClientProviderUsageSummary(
            projection: projection,
            providerName: "MiniMax",
            usageGroupID: QuotaProviderID.minimax
        )

        XCTAssertEqual(summary.id, "\(ClientID.dsh):\(QuotaProviderID.minimax):\(QuotaProviderID.minimax)")
        XCTAssertTrue(summary.isTruncated)
        XCTAssertEqual(summary.scannedAt, now)
        XCTAssertEqual(summary.costEstimate, projection.value)
        XCTAssertEqual(
            summary.dailyTokenUsage, projection.daily,
            "daily 必须原样来自内核（含当日 max 修补），视图层不得再改"
        )
    }

    /// 供 diff 归一：把旧 Merger 叠出来的 `dsh:dsh:<provider>:` 双层前缀压成
    /// 单层 `dsh:<provider>:`，让新旧样本在同一条规则下可比。排序后比较，
    /// 因为旧实现的样本顺序来自 Dictionary 迭代顺序（不确定），新实现按
    /// provider 键升序拼接（确定）——顺序不是契约，逐条内容才是。
    private static func normalizedDSHPromptIDs(
        _ samples: [LocalTokenUsageSample]
    ) -> [String] {
        let doubled = "dsh:dsh:"
        return samples.map { item in
            item.promptID.hasPrefix(doubled)
                ? "dsh:" + item.promptID.dropFirst(doubled.count)
                : item.promptID
        }.sorted()
    }
}

// MARK: - 改造前算法参考实现（测试内独立副本）

/// P1 改造**之前**的投影链路复刻：`DshUsageMerger` 的 provider 切片 / 逐日合并 /
/// `dsh:<source>:` 命名空间，加上 `ProviderStatus.usageContributionFactories`
/// 的四个工厂。刻意不复用任何被删/被改的生产类型，作为独立的"旧"一侧。
private enum LegacyProjector {
    struct Contribution: Equatable {
        let clientID: String
        let displayName: String
        let daily: [UnifiedDailyTokenUsage]
        let samples: [LocalTokenUsageSample]
        let scannedAt: Date?
        let isTruncated: Bool
    }

    // MARK: DshUsageMerger 复刻

    static let deepseekProviderIDs = ["deepseek", "deepseek-official", "deepseek-cn", "deepseek-v4"]
    static let minimaxProviderIDs = ["minimax", "minimax-cn", "minimax-cn-coding-plan"]
    static let glmProviderIDs = ["glm", "zhipu", "zhipuai", "bigmodel", "builtin:bigmodel-coding-plan", "account:bigmodel-individual-coding-plan"]

    static func dshSlice(_ usage: DshLocalUsage?, matching aliases: [String]) -> DshProviderUsage? {
        guard let usage else { return nil }
        let selected = usage.byProvider.filter { matches($0.key, aliases: aliases) }
        guard selected.isEmpty == false else { return nil }
        var daily: [Date: DshDailyUsage] = [:]
        var sessionCount = 0
        var samples: [LocalTokenUsageSample] = []
        var roundCount = 0
        for (_, value) in selected {
            if let today = value.today,
               value.dailyTokenUsage.contains(where: { $0.dayStart == today.dayStart }) == false {
                daily[today.dayStart] = today
            }
            for day in value.dailyTokenUsage {
                daily[day.dayStart] = daily[day.dayStart].map { $0 + day } ?? day
            }
            sessionCount = SaturatingArithmetic.add(sessionCount, value.sessionCount)
            samples.append(contentsOf: value.recentSamples)
            roundCount = SaturatingArithmetic.add(roundCount, value.roundCount)
        }
        let sortedDaily = daily.values.sorted { $0.dayStart < $1.dayStart }
        return DshProviderUsage(
            today: sortedDaily.last.flatMap { $0.hasActivity ? $0 : nil },
            dailyTokenUsage: sortedDaily,
            sessionCount: sessionCount,
            roundCount: roundCount,
            recentSamples: samples
        )
    }

    /// 旧 `DshUsageMerger.dshSamples`：在 scanner 已带 `dsh:` 的 sourceProviderID
    /// 上再叠一层 `dsh:<source>:`（本阶段清理掉的 `dsh:dsh:` 双层前缀）。
    static func dshSamples(_ usage: DshProviderUsage?) -> [LocalTokenUsageSample] {
        guard let usage else { return [] }
        return usage.recentSamples.map { item in
            item.withPromptIDPrefix("dsh:\(item.sourceProviderID ?? "unknown"):")
        }
    }

    static func legacyIsTruncated(_ usages: DshLocalUsage?...) -> Bool {
        usages.contains { $0?.isTruncated == true }
    }

    static func merge(
        native: OpencodeProviderUsage?,
        dshSlice: DshProviderUsage?,
        opencode: OpencodeProviderUsage?
    ) -> OpencodeProviderUsage? {
        guard native != nil || dshSlice != nil || opencode != nil else { return nil }
        var byDay: [Date: OpencodeDailyUsage] = [:]
        for day in native?.dailyTokenUsage ?? [] {
            byDay[day.dayStart] = byDay[day.dayStart].map { $0 + day } ?? day
        }
        for day in dshSlice?.dailyTokenUsage ?? [] {
            byDay[day.dayStart] = byDay[day.dayStart].map { $0 + opencodeDay(day) } ?? opencodeDay(day)
        }
        for day in opencode?.dailyTokenUsage ?? [] {
            byDay[day.dayStart] = byDay[day.dayStart].map { $0 + day } ?? day
        }
        return OpencodeProviderUsage(
            today: nil,
            dailyTokenUsage: byDay.values.sorted { $0.dayStart < $1.dayStart },
            roundCount: SaturatingArithmetic.sum(
                native?.roundCount ?? 0, dshSlice?.roundCount ?? 0, opencode?.roundCount ?? 0
            ),
            cost: (native?.cost ?? 0) + (opencode?.cost ?? 0),
            recentSamples: (native?.recentSamples ?? [])
                + dshSamples(dshSlice)
                + opencodeSamples(opencode, providerID: "opencode")
        )
    }

    /// 旧 `DshUsageMerger.opencodeProvider(_ native:)`：native 快照 → card 形态。
    static func nativeAsOpencode(_ snapshot: ProviderLocalUsage) -> OpencodeProviderUsage {
        OpencodeProviderUsage(
            today: nil,
            dailyTokenUsage: snapshot.dailyTokenUsage,
            roundCount: snapshot.eventCount,
            cost: 0,
            recentSamples: snapshot.recentSamples ?? []
        )
    }

    /// 旧 `OpencodeUsageMerger.opencodeSamples`。
    static func opencodeSamples(
        _ usage: OpencodeProviderUsage?,
        providerID: String
    ) -> [LocalTokenUsageSample] {
        guard let usage else { return [] }
        return usage.recentSamples.map { $0.withPromptIDPrefix("opencode:\(providerID):") }
    }

    private static func matches(_ providerID: String, aliases: [String]) -> Bool {
        let value = providerID.lowercased()
        return aliases.contains { alias in
            let needle = alias.lowercased()
            return value == needle || value.contains(needle)
        }
    }

    private static func opencodeDay(_ day: DshDailyUsage) -> OpencodeDailyUsage {
        OpencodeDailyUsage(
            dayStart: day.dayStart, inputTokens: day.inputTokens, outputTokens: day.outputTokens,
            cacheReadTokens: day.cacheReadTokens, cacheWriteTokens: day.cacheWriteTokens,
            reasoningTokens: day.reasoningTokens, totalTokens: day.totalTokens,
            turns: day.turns, rounds: day.rounds
        )
    }

    // MARK: 工厂表复刻

    static func projections(status: ProviderStatus, info: QuotaInfo?) -> [Contribution] {
        var result: [Contribution] = []

        func appendMerged(
            clientID: String,
            displayName: String,
            _ make: () -> OpencodeProviderUsage?,
            scannedAt: @autoclosure () -> Date?,
            isTruncated: Bool = false
        ) {
            guard let usage = make() else { return }
            result.append(contribution(
                clientID: clientID, displayName: displayName,
                daily: usage.dailyTokenUsage, samples: usage.recentSamples,
                scannedAt: scannedAt(), isTruncated: isTruncated
            ))
        }

        switch status.kind {
        case .codexChatGpt:
            if let details = info?.codexUsageDetails, let daily = details.dailyTokenUsage {
                result.append(contribution(
                    clientID: ClientID.codex, displayName: "Codex",
                    daily: daily, samples: details.recentSamples ?? [],
                    scannedAt: details.scannedAt, isTruncated: false
                ))
            }
            if status.mergeOpencodeUsage, let usage = status.opencodeUsage?.openAISlice {
                result.append(contribution(
                    clientID: ClientID.openCode, displayName: "OpenCode",
                    daily: usage.dailyTokenUsage,
                    samples: opencodeSamples(usage, providerID: OpencodeLocalUsage.openAIProviderID),
                    scannedAt: status.opencodeUsage?.scannedAt, isTruncated: false
                ))
            }

        case .antigravity:
            if let snapshot = status.antigravityLocalUsage {
                result.append(contribution(
                    clientID: ClientID.antigravity, displayName: "Antigravity",
                    daily: snapshot.dailyTokenUsage, samples: snapshot.recentSamples ?? [],
                    scannedAt: snapshot.scannedAt, isTruncated: false
                ))
            }
            if status.mergeOpencodeUsage, let usage = status.opencodeUsage?.antigravitySlice {
                result.append(contribution(
                    clientID: ClientID.openCode, displayName: "OpenCode",
                    daily: usage.dailyTokenUsage,
                    samples: opencodeSamples(usage, providerID: "antigravity"),
                    scannedAt: status.opencodeUsage?.scannedAt, isTruncated: false
                ))
            }

        case .minimaxTokenPlan:
            appendMerged(
                clientID: ClientID.minimaxCode, displayName: "MiniMax Code",
                { status.minimaxLocalUsage.map(nativeAsOpencode) },
                scannedAt: status.minimaxLocalUsage?.scannedAt
            )
            appendMerged(
                clientID: ClientID.dsh, displayName: "DSH",
                { merge(native: nil, dshSlice: dshSlice(status.dshUsage, matching: minimaxProviderIDs), opencode: nil) },
                scannedAt: status.dshUsage?.scannedAt,
                isTruncated: legacyIsTruncated(status.dshUsage)
            )
            if status.mergeZcodeUsage, let usage = status.glmLocalUsage?.minimaxSlice {
                result.append(contribution(
                    clientID: ClientID.zcode, displayName: "ZCode",
                    daily: usage.dailyTokenUsage,
                    samples: ZcodeProviderSlice.namespacedSamples(usage, for: .minimax),
                    scannedAt: status.glmLocalUsage?.scannedAt, isTruncated: false
                ))
            }
            if status.mergeOpencodeUsage, let usage = status.opencodeUsage?.minimaxCodingPlanSlice {
                result.append(contribution(
                    clientID: ClientID.openCode, displayName: "OpenCode",
                    daily: usage.dailyTokenUsage,
                    samples: opencodeSamples(usage, providerID: OpencodeLocalUsage.minimaxCodingPlanProviderID),
                    scannedAt: status.opencodeUsage?.scannedAt, isTruncated: false
                ))
            }

        case .glmCodingPlan:
            if let snapshot = status.glmLocalUsage {
                result.append(contribution(
                    clientID: ClientID.zcode, displayName: "ZCode",
                    daily: snapshot.dailyTokenUsage, samples: snapshot.recentSamples ?? [],
                    scannedAt: snapshot.scannedAt, isTruncated: false
                ))
            }
            appendMerged(
                clientID: ClientID.dsh, displayName: "DSH",
                { merge(native: nil, dshSlice: dshSlice(status.dshUsage, matching: glmProviderIDs), opencode: nil) },
                scannedAt: status.dshUsage?.scannedAt,
                isTruncated: legacyIsTruncated(status.dshUsage)
            )
            if status.mergeOpencodeUsage, let usage = status.opencodeUsage?.glmSlice {
                result.append(contribution(
                    clientID: ClientID.openCode, displayName: "OpenCode",
                    daily: usage.dailyTokenUsage,
                    samples: opencodeSamples(usage, providerID: OpencodeLocalUsage.glmProviderID),
                    scannedAt: status.opencodeUsage?.scannedAt, isTruncated: false
                ))
            }

        case .deepseek:
            appendMerged(
                clientID: ClientID.dsh, displayName: "DSH",
                { merge(native: nil, dshSlice: dshSlice(status.dshUsage, matching: deepseekProviderIDs), opencode: nil) },
                scannedAt: status.dshUsage?.scannedAt,
                isTruncated: legacyIsTruncated(status.dshUsage)
            )
            if status.mergeZcodeUsage, let usage = status.glmLocalUsage?.deepseekSlice {
                result.append(contribution(
                    clientID: ClientID.zcode, displayName: "ZCode",
                    daily: usage.dailyTokenUsage,
                    samples: ZcodeProviderSlice.namespacedSamples(usage, for: .deepseek),
                    scannedAt: status.glmLocalUsage?.scannedAt, isTruncated: false
                ))
            }
            if status.mergeOpencodeUsage, let usage = status.opencodeUsage?.deepseekSlice {
                result.append(contribution(
                    clientID: ClientID.openCode, displayName: "OpenCode",
                    daily: usage.dailyTokenUsage,
                    samples: opencodeSamples(usage, providerID: OpencodeLocalUsage.deepseekProviderID),
                    scannedAt: status.opencodeUsage?.scannedAt, isTruncated: false
                ))
            }
        }

        return result
    }

    /// 旧 `ClientUsageContribution.init`：先转 unified，再做当日 max 修补。
    private static func contribution<Daily: LocalUsageDaily>(
        clientID: String,
        displayName: String,
        daily: [Daily],
        samples: [LocalTokenUsageSample],
        scannedAt: Date?,
        isTruncated: Bool
    ) -> Contribution {
        Contribution(
            clientID: clientID,
            displayName: displayName,
            daily: UnifiedDailyUsageNormalizer.includingCurrentDay(
                dailyTokenUsage: daily.map { UnifiedDailyTokenUsage($0) },
                samples: samples
            ),
            samples: samples,
            scannedAt: scannedAt,
            isTruncated: isTruncated
        )
    }

    /// 旧 `ProviderUsageProjection.init` 的逐日相加。
    static func aggregateDaily(_ contributions: [Contribution]) -> [UnifiedDailyTokenUsage] {
        var byDay: [Date: UnifiedDailyTokenUsage] = [:]
        for item in contributions {
            for day in item.daily {
                byDay[day.dayStart] = byDay[day.dayStart].map { $0 + day } ?? day
            }
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }
}
