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
/// 允许的差异只有 promptID 命名空间两处，都由 `normalizedPromptIDs` 显式归一后
/// 再比：DSH 的 `dsh:dsh:<provider>:` → `dsh:<provider>:`（旧 Merger 在 scanner
/// 已带 `dsh:` 的 sourceProviderID 上又叠了一层）、以及 A4 起三个 native 账本在
/// 投影层补的 `antigravity:` / `minimax-code:` / `zcode:` 前缀。两侧各有独立用例
/// 锁死新格式（`testDshSamplesUseSingleLayerPromptNamespace` /
/// `testNativeFrameSamplesAreNamespacedOncePerRequest`）。
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
                primary: nil, secondary: nil,
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
            status.clientBindings = ProviderStatus.allClientBindingsEnabled()
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
                status: status,
                info: status.kind == .codexChatGpt ? codexInfo : nil,
                // 旧实现里 merge 开关是入参；P2 起从 status 携带的绑定注册表取值。
                merges: LegacyProjector.legacyMergeFlags(of: status)
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
                    Self.normalizedPromptIDs(got.recentSamples, kind: status.kind),
                    Self.normalizedPromptIDs(expected.samples, kind: status.kind),
                    "\(status.kind)/\(expected.clientID) 样本逐条相等（dsh:dsh: 与 A4 native 前缀归一后）"
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
    /// zcode 分片规则迁移为「绑定驱动后样本前缀仍逐字等于 `zcode:<slice>:`」：
    /// 端到端断言在 ZcodeProviderSliceTests（走 zcodeSliceFrames → 内核的
    /// 生产链路），这里锁登记表的字面量与 passthrough 透传。
    func testUsageSampleNamespaceRegistryPrefixes() {
        let item = sample("p", day: Date(), model: "m", input: 1)
        XCTAssertNil(UsageSampleNamespace.passthrough.prefix(sourceKey: "x"))
        XCTAssertNil(UsageSampleNamespace.codex.prefix(sourceKey: "x"))
        XCTAssertEqual(UsageSampleNamespace.dsh.prefix(sourceKey: "minimax-cn"), "dsh:minimax-cn:")
        XCTAssertEqual(UsageSampleNamespace.opencode.prefix(sourceKey: "openai"), "opencode:openai:")
        XCTAssertEqual(UsageSampleNamespace.zcodeSlice.prefix(sourceKey: "deepseek"), "zcode:deepseek:")
        XCTAssertEqual(UsageSampleNamespace.dsh.prefix(sourceKey: nil), "dsh:unknown:")
        XCTAssertEqual(UsageSampleNamespace.passthrough.apply(to: [item]).map(\.promptID), ["p"])
    }

    /// A4：三个 native（单源）账本的裸 `session:turn` 在投影层各补一层固定前缀。
    ///
    /// 登记表的字面量（前缀常量集中定义在 `UsageSampleNamespace.Prefix`）：
    /// antigravity → `antigravity:`、minimax code → `minimax-code:`、
    /// zcode 智谱 → `zcode:`。`sourceKey` 对这三个来源无意义（单源账本），传什么都
    /// 不影响结果。
    func testNativeNamespacesUseFixedClientPrefixes() {
        let item = sample("session-1:turn-2", day: Date(), model: "m", input: 1)
        for key in [nil, "ignored", ""] as [String?] {
            XCTAssertEqual(
                UsageSampleNamespace.antigravityNative.prefix(sourceKey: key),
                UsageSampleNamespace.Prefix.antigravityNative
            )
            XCTAssertEqual(
                UsageSampleNamespace.minimaxNative.prefix(sourceKey: key),
                UsageSampleNamespace.Prefix.minimaxNative
            )
            XCTAssertEqual(
                UsageSampleNamespace.zcodeNative.prefix(sourceKey: key),
                UsageSampleNamespace.Prefix.zcodeNative
            )
        }
        XCTAssertEqual(
            UsageSampleNamespace.antigravityNative.apply(to: [item]).map(\.promptID),
            ["antigravity:session-1:turn-2"]
        )
        XCTAssertEqual(
            UsageSampleNamespace.minimaxNative.apply(to: [item]).map(\.promptID),
            ["minimax-code:session-1:turn-2"]
        )
        XCTAssertEqual(
            UsageSampleNamespace.zcodeNative.apply(to: [item]).map(\.promptID),
            ["zcode:session-1:turn-2"]
        )
        // 三个来源的原始 ID 完全同构（都是裸 session:turn），必须映射到互不相同的
        // 终态 ID，否则跨 harness 去重会把它们算成同一次请求。
        XCTAssertEqual(
            Set([UsageSampleNamespace.antigravityNative,
                 .minimaxNative, .zcodeNative]
                .map { $0.apply(to: [item]).first?.promptID }).count,
            3
        )
        // apply 幂等：已经是终态 ID 的样本再过一次内核不得叠出 `zcode:zcode:`。
        XCTAssertEqual(
            UsageSampleNamespace.zcodeNative.apply(
                to: UsageSampleNamespace.zcodeNative.apply(to: [item])
            ).map(\.promptID),
            ["zcode:session-1:turn-2"]
        )
    }

    /// A4 端到端：三个 native 帧的裸样本经**生产链路**（帧抽取器 → 内核）后带上
    /// 各自前缀；且旧缓存里的裸 ID 与今天新写入的裸 ID 落到同一个终态 ID
    /// —— 这就是"零缓存迁移、零 turn 双计"的证明：同一请求不会因为前缀的存在
    /// 而被计成两次（去重集合 `Set(promptID)` 仍只收一条）。
    func testNativeFrameSamplesAreNamespacedOncePerRequest() throws {
        let now = Date()
        let (statuses, _) = makeStatuses(now: now)

        func promptIDs(_ kind: ProviderKind, _ clientID: String) throws -> [String] {
            let status = try XCTUnwrap(statuses.first { $0.kind == kind })
            let contribution = try XCTUnwrap(
                status.usageProjection(for: nil).contributions.first { $0.clientID == clientID },
                "\(kind)/\(clientID) 缺贡献"
            )
            return contribution.recentSamples.map(\.promptID)
        }

        let antigravity = try promptIDs(.antigravity, ClientID.antigravity)
        let minimax = try promptIDs(.minimaxTokenPlan, ClientID.minimaxCode)
        let zcode = try promptIDs(.glmCodingPlan, ClientID.zcode)
        XCTAssertEqual(antigravity, ["antigravity:ag-native:turn-1"])
        XCTAssertEqual(minimax, ["minimax-code:mm-native:turn-1"])
        XCTAssertEqual(zcode, ["zcode:glm-s:glm-t1"])

        // 同一次请求（裸 ID 相同）无论来自旧缓存还是本次新扫描，终态 ID 唯一。
        let bare = sample("shared-session:turn-1", day: now, model: "m", input: 1)
        func antigravityFramePromptIDs(_ snapshot: ProviderLocalUsage) -> [String] {
            var status = ProviderStatus(
                id: ProviderKind.antigravity.providerID, displayName: "Antigravity",
                kind: .antigravity, iconSystemName: "circle", accentColor: .antigravity,
                refreshIntervalSeconds: 300, state: .ready
            )
            status.antigravityLocalUsage = snapshot
            let extractors = ProviderStatus.usageFrameExtractors[.antigravity] ?? []
            return extractors
                .flatMap { $0(status, nil) }
                .flatMap(\.samples)
                .map(\.promptID)
        }
        func bareSnapshot() -> ProviderLocalUsage {
            // 旧缓存快照：磁盘上的形态就是裸 promptID（命名空间只在投影层施加）。
            ProviderLocalUsage(
                today: nil,
                dailyTokenUsage: [],
                scannedAt: now,
                sessionCount: 1,
                eventCount: 1,
                failedSessionCount: 0,
                recentSamples: [bare]
            )
        }
        let cachedIDs = antigravityFramePromptIDs(bareSnapshot())
        let freshIDs = antigravityFramePromptIDs(bareSnapshot())
        XCTAssertEqual(cachedIDs, ["antigravity:shared-session:turn-1"])
        XCTAssertEqual(freshIDs, cachedIDs, "旧缓存与新扫描的同一请求必须得到同一个终态 ID")
        XCTAssertEqual(Set(cachedIDs + freshIDs).count, 1, "拼接后仍只算一次请求（无 turn 双计）")
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

    // MARK: - 帧抽取注册表的顺序契约

    /// 注册表必须覆盖每一张卡：新增 `ProviderKind` case 却忘了在
    /// `usageFrameExtractors` 里追一个抽取器时，该卡会静默无数据，这里立刻爆掉。
    func testFrameExtractorRegistryCoversEveryProviderKind() {
        XCTAssertEqual(
            Set(ProviderStatus.usageFrameExtractors.keys),
            Set(ProviderKind.allCases),
            "每一张 quota 卡都必须在帧抽取注册表里登记抽取器数组"
        )
    }

    /// 注册表里**数组顺序**是展示契约（`usageFrameExtractors` 注释：帧的顺序即
    /// 贡献顺序，内核按首次出现的分组顺序输出）。这里对每个 `ProviderKind` 用
    /// 全量挂载的 status 跑一遍抽取器，把产出的帧压成
    /// `clientID|sourceKey|quotaProviderID` 指纹并逐条比对字面量期望：
    /// 任何一卡新增 / 删除 / 调序抽取器都必须同步本用例的期望。
    ///
    /// 夹具让每个抽取器都产帧（native 快照、dsh 全键账本、zcode 两个非智谱分片、
    /// opencode 各分片、codex 详情全在），所以"某个抽取器被悄悄挪位"不会漏检。
    func testFrameExtractorOrderIsTheDisplayContract() throws {
        let now = Date()
        let (statuses, codexInfo) = makeStatuses(now: now)

        func fingerprint(
            _ clientID: String, _ sourceKey: String?, _ quotaProviderID: String
        ) -> String {
            "\(clientID)|\(sourceKey ?? "-")|\(quotaProviderID)"
        }
        // dsh 抽取器一次吐出账本全部键（键名升序），帧不声明 quota 归属。
        func dshFingerprints() -> [String] {
            ["deepseek-official", "minimax-cn", "openai", "zhipuai"].map {
                fingerprint(ClientID.dsh, $0, "")
            }
        }

        let expected: [ProviderKind: [String]] = [
            .codexChatGpt: [
                fingerprint(ClientID.codex, nil, QuotaProviderID.openAI),
                fingerprint(ClientID.openCode, OpencodeLocalUsage.openAIProviderID, QuotaProviderID.openAI)
            ],
            .antigravity: [
                fingerprint(ClientID.antigravity, nil, QuotaProviderID.antigravity),
                fingerprint(
                    ClientID.openCode, OpencodeLocalUsage.antigravitySourceProviderID,
                    QuotaProviderID.antigravity
                )
            ],
            .minimaxTokenPlan:
                [fingerprint(ClientID.minimaxCode, nil, QuotaProviderID.minimax)]
                + dshFingerprints()
                + [
                    fingerprint(
                        ClientID.zcode, ZcodeProviderSlice.minimax.providerPrefix,
                        QuotaProviderID.minimax
                    ),
                    fingerprint(
                        ClientID.openCode, OpencodeLocalUsage.minimaxCodingPlanProviderID,
                        QuotaProviderID.minimax
                    )
                ],
            .glmCodingPlan:
                [fingerprint(ClientID.zcode, nil, QuotaProviderID.zhipu)]
                + dshFingerprints()
                + [
                    fingerprint(
                        ClientID.openCode, OpencodeLocalUsage.glmProviderID,
                        QuotaProviderID.zhipu
                    )
                ],
            .deepseek:
                dshFingerprints()
                + [
                    fingerprint(
                        ClientID.zcode, ZcodeProviderSlice.deepseek.providerPrefix,
                        QuotaProviderID.deepseek
                    ),
                    fingerprint(
                        ClientID.openCode, OpencodeLocalUsage.deepseekProviderID,
                        QuotaProviderID.deepseek
                    )
                ]
        ]

        for kind in ProviderKind.allCases {
            let status = try XCTUnwrap(statuses.first { $0.kind == kind })
            let extractors = try XCTUnwrap(
                ProviderStatus.usageFrameExtractors[kind], "\(kind) 未登记帧抽取器"
            )
            let fingerprints = extractors
                .flatMap { $0(status, kind == .codexChatGpt ? codexInfo : nil) }
                .map { fingerprint($0.clientID, $0.sourceKey, $0.quotaProviderID) }
            XCTAssertEqual(
                fingerprints, try XCTUnwrap(expected[kind], "\(kind) 缺期望"),
                "\(kind) 的帧顺序即贡献顺序，改动抽取器顺序必须同步本用例"
            )
        }
    }

    // MARK: - P2 绑定显式化验收

    /// 绑定关闭时对应切片帧不产出：zcode → minimax = false 后 MiniMax 卡不再有
    /// ZCode 贡献，且同卡的 opencode 贡献与 DeepSeek 卡的 zcode 分片不受牵连。
    /// 语义迁移自旧 mergeZcodeUsage 直改的开关用例。
    func testBindingDisabledDropsZcodeSliceContribution() throws {
        let now = Date()
        let (statuses, _) = makeStatuses(now: now)

        var minimax = try XCTUnwrap(statuses.first { $0.kind == .minimaxTokenPlan })
        minimax.setClientBindingEnabled(
            clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.minimax, enabled: false
        )
        XCTAssertNil(
            minimax.usageProjection(for: nil).contributions.first { $0.clientID == ClientID.zcode },
            "zcode → minimax 绑定关闭后 MiniMax 卡不得再有 ZCode 贡献"
        )
        XCTAssertNotNil(
            minimax.usageProjection(for: nil).contributions.first { $0.clientID == ClientID.openCode },
            "同卡的 opencode 绑定不受 zcode 绑定关闭影响"
        )

        var deepseek = try XCTUnwrap(statuses.first { $0.kind == .deepseek })
        deepseek.setClientBindingEnabled(
            clientID: ClientID.zcode, quotaProviderID: QuotaProviderID.minimax, enabled: false
        )
        XCTAssertNotNil(
            deepseek.usageProjection(for: nil).contributions.first { $0.clientID == ClientID.zcode },
            "关闭 minimax 侧绑定不影响 deepseek 侧的 zcode 分片"
        )
    }

    /// dsh 帧不声明归属：内核用 clientBindings 的 dsh 条目按别名解析 quota；
    /// 未被任何启用绑定认领的键落空串组，由卡片侧按本卡 quota 过滤。
    func testDshFramesResolveQuotaThroughBindingsAndDropUnclaimedKeys() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = DshLocalUsage(
            byProvider: [
                "deepseek-official": dshProvider(
                    "deepseek-official", day: day, model: "deepseek-v4-flash",
                    input: 100, turnIDs: ["1"]
                ),
                "minimax-cn": dshProvider(
                    "minimax-cn", day: day, model: "MiniMax-M3", input: 80, turnIDs: ["1"]
                ),
                "mystery-router": dshProvider(
                    "mystery-router", day: day, model: "mystery", input: 999, turnIDs: ["1"]
                )
            ],
            modelsByProvider: [:], sessionsRoot: "/tmp/.dsh/sessions",
            sessionCount: 3, eventCount: 3, scannedAt: day
        )

        // 内核层：被绑定认领的键解析到对应 quota，未认领的键落空串组。
        let frames = DshHarnessFrames.frames(from: usage)
        let projections = UsageProjectionKernel.project(
            frames: frames, bindings: AppConfig.defaultClientBindings
        )
        XCTAssertEqual(
            projections.map(\.quotaProviderID).sorted(),
            ["", QuotaProviderID.deepseek, QuotaProviderID.minimax],
            "dsh 帧的归属来自绑定别名解析，未认领键落空串组"
        )

        // 卡片层：DeepSeek 卡只呈现本卡 quota 的 DSH 贡献，mystery-router 不并入。
        var status = ProviderStatus(
            id: "deepseek", displayName: "DeepSeek", kind: .deepseek,
            iconSystemName: "circle", accentColor: .deepseek,
            refreshIntervalSeconds: 300, state: .ready
        )
        status.dshUsage = usage
        let projection = status.usageProjection(for: nil)
        XCTAssertEqual(projection.clientIDs, [ClientID.dsh])
        XCTAssertEqual(projection.dailyTokenUsage.first?.input, 100)
    }

    /// 别名单一事实源：默认绑定数组里的字面量是唯一来源，两处历史硬编码
    /// （OpencodeLocalUsage 常量表、DshHarnessFrames 路由表）都从绑定导出且
    /// 与既有字面量逐字一致（写错即漏采，漂移必须在这里爆掉）。
    func testAliasesAreExportedFromDefaultBindings() {
        XCTAssertEqual(OpencodeLocalUsage.glmProviderID, "zhipuai-coding-plan")
        XCTAssertEqual(OpencodeLocalUsage.minimaxCodingPlanProviderID, "minimax-cn-coding-plan")
        XCTAssertEqual(OpencodeLocalUsage.openAIProviderID, "openai")
        XCTAssertEqual(OpencodeLocalUsage.deepseekProviderID, "deepseek")
        XCTAssertEqual(
            OpencodeLocalUsage.antigravityProviderIDs,
            ["antigravity", "google-antigravity", "google-vertex", "google"]
        )
        XCTAssertEqual(OpencodeLocalUsage.antigravitySourceProviderID, "antigravity")
        XCTAssertEqual(
            ClientProviderBinding.defaultSourceProviderAliases(
                clientID: ClientID.openCode, quotaProviderID: QuotaProviderID.zhipu
            ).first,
            OpencodeLocalUsage.glmProviderID,
            "opencode 常量必须与默认绑定导出的首选别名同源"
        )

        XCTAssertEqual(
            ClientProviderBinding.defaultSourceProviderAliases(
                clientID: ClientID.dsh, quotaProviderID: QuotaProviderID.deepseek
            ),
            ["deepseek", "deepseek-official", "deepseek-cn", "deepseek-v4"]
        )
        XCTAssertEqual(
            ClientProviderBinding.defaultSourceProviderAliases(
                clientID: ClientID.dsh, quotaProviderID: QuotaProviderID.minimax
            ),
            ["minimax", "minimax-cn", "minimax-cn-coding-plan"]
        )
        XCTAssertEqual(
            ClientProviderBinding.defaultSourceProviderAliases(
                clientID: ClientID.dsh, quotaProviderID: QuotaProviderID.zhipu
            ),
            ["glm", "zhipu", "zhipuai", "bigmodel",
             "builtin:bigmodel-coding-plan", "account:bigmodel-individual-coding-plan"]
        )
        // dsh 三条默认启用（与 DSH 历史上不受任何开关控制一致）。
        for quota in [QuotaProviderID.deepseek, QuotaProviderID.minimax, QuotaProviderID.zhipu] {
            XCTAssertTrue(
                AppConfig.default.isClientBindingEnabled(clientID: ClientID.dsh, quotaProviderID: quota),
                "dsh → \(quota) 默认绑定应启用"
            )
        }
    }

    /// logWarn 判定路径（纯函数部分）：账本键没被任何 dsh 绑定别名认领时返回
    /// 该键，供 AppState.applyDshUsage 打告警（含 unmatched 键与已登记别名）。
    /// 被认领（含显式停用）的键不算异常。
    func testUnclaimedProviderKeysDetectAliasMismatch() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = DshLocalUsage(
            byProvider: [
                "deepseek-official": dshProvider(
                    "deepseek-official", day: day, model: "m", input: 1, turnIDs: ["1"]
                ),
                "mystery-router": dshProvider(
                    "mystery-router", day: day, model: "m", input: 1, turnIDs: ["1"]
                )
            ],
            modelsByProvider: [:], sessionsRoot: nil, sessionCount: 2, eventCount: 2, scannedAt: day
        )

        XCTAssertEqual(
            DshHarnessFrames.unclaimedProviderKeys(
                in: usage, bindings: AppConfig.defaultClientBindings
            ),
            ["mystery-router"],
            "默认绑定下只有未登记路由是未认领键"
        )

        // 用户手改 config 写错别名（deepseek → deepseak）：真实键变成未认领，
        // 这正是静默漏采需要告警的形态。
        let typoBindings = AppConfig.defaultClientBindings.map { binding in
            guard binding.clientID == ClientID.dsh,
                  binding.quotaProviderID == QuotaProviderID.deepseek else { return binding }
            return ClientProviderBinding(
                clientID: binding.clientID,
                quotaProviderID: binding.quotaProviderID,
                sourceProviderAliases: ["deepseak"],
                enabled: binding.enabled
            )
        }
        XCTAssertEqual(
            DshHarnessFrames.unclaimedProviderKeys(in: usage, bindings: typoBindings),
            ["deepseek-official", "mystery-router"]
        )
        XCTAssertEqual(
            DshHarnessFrames.registeredAliases(bindings: typoBindings).contains("deepseak"),
            true,
            "告警日志里的「期望形态」应来自当前绑定注册表"
        )

        // 显式停用的绑定仍算"被认领"：是刻意关闭，不是别名失配。
        let disabledBindings = AppConfig.defaultClientBindings.toggled(
            clientID: ClientID.dsh, quotaProviderID: QuotaProviderID.deepseek, enabled: false
        )
        XCTAssertEqual(
            DshHarnessFrames.unclaimedProviderKeys(in: usage, bindings: disabledBindings),
            ["mystery-router"]
        )

        XCTAssertEqual(
            DshHarnessFrames.unclaimedProviderKeys(in: nil, bindings: AppConfig.defaultClientBindings),
            []
        )
    }

    /// 供 diff 归一：两处**已声明的允许差异**，都只动 promptID 字面量。
    ///
    /// 1. DSH：旧 Merger 叠出来的 `dsh:dsh:<provider>:` 双层前缀压成单层
    ///    `dsh:<provider>:`（P1 起清理，见 `testDshSamplesUseSingleLayerPromptNamespace`）。
    /// 2. A4：三个 native 账本的裸 `session:turn` 起在投影层补固定前缀
    ///    （`antigravity:` / `minimax-code:` / `zcode:`），而 `LegacyProjector`
    ///    复刻的正是改造前的裸 ID。这里按**卡**剥掉该卡对应的那一条 —— zcode 分片
    ///    （`zcode:<slice>:`，改造前后一致）不在剥离范围内，否则两侧同被削首段、
    ///    反而掩盖真实差异。
    ///
    /// 逐条内容（而非顺序）才是契约：旧实现的样本顺序来自 Dictionary 迭代顺序
    /// （不确定），新实现按 provider 键升序拼接（确定）。其余字段两侧同源。
    private static func normalizedPromptIDs(
        _ samples: [LocalTokenUsageSample],
        kind: ProviderKind
    ) -> [String] {
        samples.map { Self.normalizedPromptID($0.promptID, kind: kind) }.sorted()
    }

    private static func normalizedPromptID(_ promptID: String, kind: ProviderKind) -> String {
        let doubled = "dsh:dsh:"
        if promptID.hasPrefix(doubled) { return "dsh:" + promptID.dropFirst(doubled.count) }
        let nativePrefix: String?
        switch kind {
        case .antigravity:
            nativePrefix = UsageSampleNamespace.Prefix.antigravityNative
        case .minimaxTokenPlan:
            nativePrefix = UsageSampleNamespace.Prefix.minimaxNative
        case .glmCodingPlan:
            nativePrefix = UsageSampleNamespace.Prefix.zcodeNative
        case .codexChatGpt, .deepseek:
            nativePrefix = nil
        }
        guard let nativePrefix, promptID.hasPrefix(nativePrefix) else { return promptID }
        return String(promptID.dropFirst(nativePrefix.count))
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

    /// 旧 `ZcodeProviderSlice.namespacedSamples` 的等价内联复刻（该 API 已删除，
    /// 规则收口在内核 `UsageSampleNamespace.zcodeSlice`）：样本加 `zcode:<slice>:`
    /// 前缀，避免 ZCode 账本与 native / dsh / OpenCode 账本撞 promptID。
    static func zcodeSliceSamples(
        _ usage: OpencodeProviderUsage,
        for slice: ZcodeProviderSlice
    ) -> [LocalTokenUsageSample] {
        usage.recentSamples.map { $0.withPromptIDPrefix("zcode:\(slice.providerPrefix):") }
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

    /// 旧实现把 merge 开关当入参；这里从 status 携带的绑定注册表取同源值，
    /// 保证 diff 两侧的"开关输入"一致。
    static func legacyMergeFlags(
        of status: ProviderStatus
    ) -> (opencode: Bool, zcode: Bool) {
        (
            opencode: status.isClientBindingEnabled(
                clientID: ClientID.openCode,
                quotaProviderID: status.kind.quotaProviderID
            ),
            zcode: status.isClientBindingEnabled(
                clientID: ClientID.zcode,
                quotaProviderID: status.kind.quotaProviderID
            )
        )
    }

    static func projections(
        status: ProviderStatus,
        info: QuotaInfo?,
        merges: (opencode: Bool, zcode: Bool)
    ) -> [Contribution] {
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
            if merges.opencode, let usage = status.opencodeUsage?.openAISlice {
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
            if merges.opencode, let usage = status.opencodeUsage?.antigravitySlice {
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
            if merges.zcode, let usage = status.glmLocalUsage?.minimaxSlice {
                result.append(contribution(
                    clientID: ClientID.zcode, displayName: "ZCode",
                    daily: usage.dailyTokenUsage,
                    samples: LegacyProjector.zcodeSliceSamples(usage, for: .minimax),
                    scannedAt: status.glmLocalUsage?.scannedAt, isTruncated: false
                ))
            }
            if merges.opencode, let usage = status.opencodeUsage?.minimaxCodingPlanSlice {
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
            if merges.opencode, let usage = status.opencodeUsage?.glmSlice {
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
            if merges.zcode, let usage = status.glmLocalUsage?.deepseekSlice {
                result.append(contribution(
                    clientID: ClientID.zcode, displayName: "ZCode",
                    daily: usage.dailyTokenUsage,
                    samples: LegacyProjector.zcodeSliceSamples(usage, for: .deepseek),
                    scannedAt: status.glmLocalUsage?.scannedAt, isTruncated: false
                ))
            }
            if merges.opencode, let usage = status.opencodeUsage?.deepseekSlice {
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

// MARK: - 跨测试文件共享的绑定夹具助手（P2）

extension ClientProviderBinding {
    /// enabled 改为指定值的副本。
    func withEnabled(_ value: Bool) -> ClientProviderBinding {
        ClientProviderBinding(
            clientID: clientID,
            quotaProviderID: quotaProviderID,
            sourceProviderAliases: sourceProviderAliases,
            enabled: value
        )
    }
}

extension Array where Element == ClientProviderBinding {
    /// 返回把指定 (clientID, quotaProviderID) 绑定的 enabled 翻到目标值的副本；
    /// 不存在该组合时原样返回（与 `AppConfig.setClientBindingEnabled` 的补齐语义
    /// 无关，这里只做夹具内翻转）。
    func toggled(
        clientID: String,
        quotaProviderID: String,
        enabled: Bool
    ) -> [ClientProviderBinding] {
        map { binding in
            binding.clientID == clientID && binding.quotaProviderID == quotaProviderID
                ? binding.withEnabled(enabled)
                : binding
        }
    }
}

extension ProviderStatus {
    /// 把本 status 携带的绑定里某一条开/关（镜像 `AppConfig.setClientBindingEnabled`
    /// 的更新路径；测试用它替代旧的 `mergeXxx = false` 直改）。
    mutating func setClientBindingEnabled(
        clientID: String,
        quotaProviderID: String,
        enabled: Bool
    ) {
        clientBindings = clientBindings.toggled(
            clientID: clientID,
            quotaProviderID: quotaProviderID,
            enabled: enabled
        )
    }

    /// 全量启用版默认绑定：5 条 opencode + 2 条 zcode + 3 条 dsh 全部 enabled。
    /// 对应旧测试夹具里 `mergeOpencodeUsage = true` + `mergeZcodeUsage = true` 的
    /// "全部打开"语义。
    static func allClientBindingsEnabled() -> [ClientProviderBinding] {
        AppConfig.defaultClientBindings.map { $0.withEnabled(true) }
    }
}
