import XCTest
@testable import LLM_monitor

final class GlmOffPeakTests: GlmTestCase {

    // MARK: - GLM Peak Window Tests

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private let peakWindow = GlmPeakWindow.zhipuDefault

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: 0, second: 0))!
    }

    func testGlmPeakWindowStatusRules() {
        XCTAssertEqual(peakWindow.status(at: date(2026, 7, 31, 15), calendar: cal), .peak(until: date(2026, 7, 31, 18)))
        XCTAssertEqual(peakWindow.status(at: date(2026, 7, 31, 10), calendar: cal), .offPeak(until: date(2026, 7, 31, 14)))
        XCTAssertEqual(peakWindow.status(at: date(2026, 8, 1, 15), calendar: cal), .offPeak(until: date(2026, 8, 3, 14)))

        // GLM 窗口已固定为官方口径（不再从 config 派生）：rebuildStatuses 一律挂
        // `zhipuDefault`；旧配置残留的 peak* 键由 JSONDecoder 静默忽略。
        XCTAssertEqual(peakWindow, GlmPeakWindow(startHour: 14, endHour: 18, weekdaysOnly: true))
    }

    // MARK: - GLM Off-Peak (闲时任务) Tests

    /// 闲时窗口的 contains 边界：闭区间 + 2 秒容差。off_peak.ended_at 与最后一轮
    /// model_usage.completed_at 实测差 ~1 秒，容差确保边界 round 不被误判。
    func testGlmOffPeakWindowContainsWithTolerance() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 2_000)
        let window = GlmOffPeakWindow(startedAt: start, endedAt: end)

        // 窗口内
        XCTAssertTrue(window.contains(Date(timeIntervalSince1970: 1_500)))
        // 闭区间边界
        XCTAssertTrue(window.contains(start))
        XCTAssertTrue(window.contains(end))
        // 容差内（ended + 1.5s）
        XCTAssertTrue(window.contains(end.addingTimeInterval(1.5)))
        // 容差外（ended + 3s）
        XCTAssertFalse(window.contains(end.addingTimeInterval(3)))
        // 容差下沿（start - 1.5s，容差内）
        XCTAssertTrue(window.contains(start.addingTimeInterval(-1.5)))
        // 窗口前（start - 3s，超出容差）
        XCTAssertFalse(window.contains(start.addingTimeInterval(-3)))
    }

    /// 额度窗口 summary 排除落在闲时窗口内的 sample；本地柱图（不走 summary）仍保留。
    func testGlmSummaryExcludesOffPeakWindows() {
        let peakStart = Date(timeIntervalSince1970: 1_000)
        let peakEnd = Date(timeIntervalSince1970: 1_100)
        let offPeak = GlmOffPeakWindow(startedAt: peakStart, endedAt: peakEnd)

        // 3 个 GLM sample：闲时前 / 闲时内 / 闲时后
        let before = LocalTokenUsageSample(
            completedAt: Date(timeIntervalSince1970: 900),
            modelName: "GLM-5.2", promptID: "p1",
            inputTokens: 100, cachedInputTokens: 0, outputTokens: 10, reasoningOutputTokens: 0
        )
        let during = LocalTokenUsageSample(
            completedAt: Date(timeIntervalSince1970: 1_050),
            modelName: "GLM-5.2", promptID: "p2",
            inputTokens: 500, cachedInputTokens: 0, outputTokens: 50, reasoningOutputTokens: 0
        )
        let after = LocalTokenUsageSample(
            completedAt: Date(timeIntervalSince1970: 1_200),
            modelName: "GLM-5.2", promptID: "p3",
            inputTokens: 200, cachedInputTokens: 0, outputTokens: 20, reasoningOutputTokens: 0
        )

        // 不排除 → 3 个 sample 全算
        let allSummary = LocalUsageSummaryBuilder.summary(
            samples: [before, during, after],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: nil, end: nil
        )
        XCTAssertEqual(allSummary?.rounds, 3)
        XCTAssertEqual(allSummary?.inputTokens, 800)

        // 排除闲时窗口 → 只剩 before + after（during 被过滤）
        let filteredSummary = LocalUsageSummaryBuilder.summary(
            samples: [before, during, after],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: nil, end: nil,
            excludeWindows: [offPeak]
        )
        XCTAssertEqual(filteredSummary?.rounds, 2)
        XCTAssertEqual(filteredSummary?.inputTokens, 300)  // 100 + 200，不含 500
    }

    /// 正常 coding-plan 请求可以与后台闲时任务并发。provider 身份已知时必须优先
    /// 使用身份分类，不能把同一时间窗口内的正常请求或 OpenCode 合并请求排除。
    func testGlmSummaryUsesProviderIdentityBeforeOffPeakTimeWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 1_100)
        let window = GlmOffPeakWindow(startedAt: start, endedAt: end)

        func sample(_ providerID: String?, promptID: String, input: Int) -> LocalTokenUsageSample {
            LocalTokenUsageSample(
                completedAt: Date(timeIntervalSince1970: 1_050),
                modelName: "GLM-5.2",
                promptID: promptID,
                inputTokens: input,
                cachedInputTokens: 0,
                outputTokens: 1,
                reasoningOutputTokens: 0,
                sourceProviderID: providerID
            )
        }

        let normal = sample("builtin:bigmodel-coding-plan", promptID: "normal:t1", input: 100)
        let idle = sample("offpeak-idle-plan", promptID: "idle:t1", input: 500)
        let opencode = sample(nil, promptID: "opencode:zhipuai-coding-plan:p1", input: 200)

        let summary = LocalUsageSummaryBuilder.summary(
            samples: [normal, idle, opencode],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: nil,
            end: nil,
            excludeWindows: [window]
        )
        XCTAssertEqual(summary?.rounds, 2)
        XCTAssertEqual(summary?.inputTokens, 300, "只排除明确标记为 offpeak-idle-plan 的样本")

        let summaryWithoutTaskWindows = LocalUsageSummaryBuilder.summary(
            samples: [normal, idle, opencode],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: nil,
            end: nil,
            excludeGlmOffPeak: true
        )
        XCTAssertEqual(summaryWithoutTaskWindows?.rounds, 2)
        XCTAssertEqual(
            summaryWithoutTaskWindows?.inputTokens,
            300,
            "任务库不可读时仍应按 provider 身份排除闲时样本"
        )

        let idleSummary = LocalUsageSummaryBuilder.offPeakTodaySummary(
            samples: [normal, idle, opencode],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            offPeakWindows: [window],
            now: Date(timeIntervalSince1970: 1_050),
            calendar: utcCalendar()
        )
        XCTAssertEqual(idleSummary?.rounds, 1)
        XCTAssertEqual(idleSummary?.inputTokens, 500)
    }

    /// 「其他」智谱套餐（`builtin:bigmodel-` 前缀但非 coding-plan，如体验套餐
    /// `builtin:bigmodel-start-plan`）不消耗 Coding Plan 积分：额度窗口统计必须
    /// 排除，且不能误伤同期的正常任务 / OpenCode / DSH 合并样本。
    func testGlmSummaryExcludesOtherBigmodelPlans() {
        func sample(_ providerID: String?, promptID: String, input: Int) -> LocalTokenUsageSample {
            LocalTokenUsageSample(
                completedAt: Date(timeIntervalSince1970: 1_050),
                modelName: "GLM-5.3-Flash",
                promptID: promptID,
                inputTokens: input,
                cachedInputTokens: 0,
                outputTokens: 1,
                reasoningOutputTokens: 0,
                sourceProviderID: providerID
            )
        }

        let normal = sample("builtin:bigmodel-coding-plan", promptID: "normal:t1", input: 100)
        let trial = sample("builtin:bigmodel-start-plan", promptID: "trial:t1", input: 500)
        let future = sample("builtin:bigmodel-weekend-plan", promptID: "future:t1", input: 700)
        let opencode = sample("dsh:zhipuai-coding-plan", promptID: "opencode:zhipuai-coding-plan:p1", input: 200)
        // 0020_provider_model_selection 迁移后的 account: 前缀形态
        let accountNormal = sample("account:bigmodel-individual-coding-plan", promptID: "account:t1", input: 300)
        let accountTrial = sample("account:bigmodel-start-plan", promptID: "account-trial:t1", input: 400)
        // 0020 迁移后的账号化闲时 ID：带智谱前缀但必须归闲时，不得落「其他」
        let accountOffPeak = sample("account:bigmodel-offpeak-idle-plan", promptID: "account-idle:t1", input: 600)

        XCTAssertTrue(LocalUsageSummaryBuilder.isGlmOtherPlanSample(trial))
        XCTAssertTrue(LocalUsageSummaryBuilder.isGlmOtherPlanSample(future))
        XCTAssertTrue(LocalUsageSummaryBuilder.isGlmOtherPlanSample(accountTrial))
        XCTAssertFalse(LocalUsageSummaryBuilder.isGlmOtherPlanSample(normal))
        XCTAssertFalse(LocalUsageSummaryBuilder.isGlmOtherPlanSample(accountNormal))
        XCTAssertFalse(LocalUsageSummaryBuilder.isGlmOtherPlanSample(opencode))
        // 三桶互斥：账号化闲时 ID 不是「其他」，且能按 provider 身份识别为闲时
        XCTAssertFalse(LocalUsageSummaryBuilder.isGlmOtherPlanSample(accountOffPeak))
        XCTAssertTrue(LocalUsageSummaryBuilder.isGlmOffPeakSample(accountOffPeak, fallbackWindows: []))
        // 旧缓存没有来源标记 → 保持时间窗口回退语义，不算「其他」
        XCTAssertFalse(
            LocalUsageSummaryBuilder.isGlmOtherPlanSample(sample(nil, promptID: "legacy:t1", input: 1))
        )

        let summary = LocalUsageSummaryBuilder.summary(
            samples: [normal, trial, future, opencode],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: nil,
            end: nil,
            excludeGlmOffPeak: true
        )
        XCTAssertEqual(summary?.rounds, 2)
        XCTAssertEqual(summary?.inputTokens, 300, "start-plan 等其他智谱套餐不计入额度窗口")

        // 无排除口径时全部计入（与闲时任务的柱图口径一致）
        let allSummary = LocalUsageSummaryBuilder.summary(
            samples: [normal, trial, future, opencode],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            start: nil,
            end: nil
        )
        XCTAssertEqual(allSummary?.rounds, 4)
        XCTAssertEqual(allSummary?.inputTokens, 1_500)
    }

    /// DB reader 按智谱前缀通配覆盖历史 / 账号化 / 未知新套餐（体验套餐等）：
    /// 这些行的 token 计入柱图聚合、样本保留 provider 身份；非智谱 provider
    /// （不带前缀）即使模型名带 glm 也不能进 GLM 卡。
    func testGlmZcodeDBReaderIncludesBigmodelPrefixPlans() throws {
        let db = try makeDatabase()
        defer { try? FileManager.default.removeItem(atPath: db) }
        let day = Self.todayMidnight(calendar: utcCalendar())
        let ts = ms(day)
        let cal = utcCalendar()

        try insert(databaseURL: db, id: "cp", sessionID: "s1", turnID: "t1", timestamp: ts,
                   input: 100, output: 10, model: "GLM-5.3", provider: "builtin:bigmodel-coding-plan")
        try insert(databaseURL: db, id: "trial", sessionID: "s2", turnID: "t2", timestamp: ts + 1,
                   input: 500, output: 20, model: "GLM-5.3-Flash", provider: "builtin:bigmodel-start-plan")
        try insert(databaseURL: db, id: "future", sessionID: "s3", turnID: "t3", timestamp: ts + 2,
                   input: 700, output: 30, model: "GLM-6", provider: "builtin:bigmodel-future-plan")
        try insert(databaseURL: db, id: "offpeak", sessionID: "s4", turnID: "t4", timestamp: ts + 3,
                   input: 900, output: 40, model: "GLM-5.3", provider: "offpeak-idle-plan")
        try insert(databaseURL: db, id: "foreign", sessionID: "s5", turnID: "t5", timestamp: ts + 4,
                   input: 5_000, output: 50, model: "GLM-5.3", provider: "some-other-provider")
        // 0020 迁移后账号化 ID：zai 族 normal / offpeak，以及未登记的
        // `*-coding-plan` 变体（读进来但归「其他」，不再通配成 normal）
        try insert(databaseURL: db, id: "zai", sessionID: "s6", turnID: "t6", timestamp: ts + 5,
                   input: 1_100, output: 60, model: "GLM-5.3", provider: "account:zai-individual-coding-plan")
        try insert(databaseURL: db, id: "zaiop", sessionID: "s7", turnID: "t7", timestamp: ts + 6,
                   input: 1_300, output: 70, model: "GLM-5.3", provider: "account:zai-offpeak-idle-plan")
        try insert(databaseURL: db, id: "max", sessionID: "s8", turnID: "t8", timestamp: ts + 7,
                   input: 1_500, output: 80, model: "GLM-5.3", provider: "account:bigmodel-max-coding-plan")

        let aggregate = try GlmZcodeLocalUsageScanner.aggregateFromDB(dbPath: URL(fileURLWithPath: db), calendar: cal)
        let today = try XCTUnwrap(aggregate.perDay[day])

        // 柱图口径：coding-plan + start-plan + future-plan + offpeak + zai 三行全部计入，foreign 排除
        XCTAssertEqual(today.inputTokens, 100 + 500 + 700 + 900 + 1_100 + 1_300 + 1_500)
        XCTAssertEqual(aggregate.roundCount, 7)
        XCTAssertEqual(aggregate.sessionCount, 7)

        // 样本保留 provider 身份，供额度窗口白名单判定
        let providerIDs = Set(aggregate.samples.map { $0.sourceProviderID ?? "nil" })
        XCTAssertEqual(
            providerIDs,
            [
                "builtin:bigmodel-coding-plan",
                "builtin:bigmodel-start-plan",
                "builtin:bigmodel-future-plan",
                "offpeak-idle-plan",
                "account:zai-individual-coding-plan",
                "account:zai-offpeak-idle-plan",
                "account:bigmodel-max-coding-plan"
            ]
        )

        // 样本层分类：zai normal / offpeak 按显式枚举归桶，未登记变体落「其他」
        let samplesByProvider = Dictionary(aggregate.samples.map { ($0.sourceProviderID ?? "", $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(GlmUsageCategory.classify(samplesByProvider["account:zai-individual-coding-plan"]!), .normal)
        XCTAssertEqual(GlmUsageCategory.classify(samplesByProvider["account:zai-offpeak-idle-plan"]!), .offPeak)
        XCTAssertEqual(GlmUsageCategory.classify(samplesByProvider["account:bigmodel-max-coding-plan"]!), .other)
    }

    /// "今日闲时" 单独展示：只取今日落在 off_peak 窗口内的 native 样本；
    /// 非今日 / 窗口外 / OpenCode 合并样本都不算闲时。
    func testGlmOffPeakTodaySummary() {
        let cal = utcCalendar()
        let today = Self.todayMidnight(calendar: cal)
        let window = GlmOffPeakWindow(startedAt: today.addingTimeInterval(3600),
                                      endedAt: today.addingTimeInterval(7200))

        func sample(_ seconds: TimeInterval, input: Int, promptID: String) -> LocalTokenUsageSample {
            LocalTokenUsageSample(
                completedAt: today.addingTimeInterval(seconds),
                modelName: "GLM-5.2", promptID: promptID,
                inputTokens: input, cachedInputTokens: 0, outputTokens: 1, reasoningOutputTokens: 0
            )
        }
        let inWindow = sample(5400, input: 500, promptID: "s1:t1")   // 窗口内，今日 → 闲时
        let outsideWindow = sample(9000, input: 300, promptID: "s1:t2") // 今日但窗口外 → 不算
        let opencode = sample(5400, input: 700, promptID: "opencode:zhipuai-coding-plan:p1") // 窗口内但是 OpenCode → 不算
        let yesterday = sample(-86_400 + 5400, input: 200, promptID: "s2:t1") // 窗口内但昨天 → 不算

        let summary = LocalUsageSummaryBuilder.offPeakTodaySummary(
            samples: [inWindow, outsideWindow, opencode, yesterday],
            providerKind: .glmCodingPlan,
            quotaModelName: "glm_coding_plan",
            offPeakWindows: [window],
            now: today.addingTimeInterval(10_000),
            calendar: cal
        )
        XCTAssertEqual(summary?.rounds, 1, "只有窗口内 + 今日 + native 的样本计入")
        XCTAssertEqual(summary?.inputTokens, 500)
        XCTAssertEqual(summary?.prompts, 1)

        // 无闲时窗口 → nil
        XCTAssertNil(
            LocalUsageSummaryBuilder.offPeakTodaySummary(
                samples: [inWindow],
                providerKind: .glmCodingPlan,
                quotaModelName: "glm_coding_plan",
                offPeakWindows: [],
                now: today.addingTimeInterval(10_000),
                calendar: cal
            )
        )
    }

    /// 闲时窗口语义（旧 mergeGlm 测试的迁移）：offPeakWindows 只属于 native
    /// ZCode 源，卡片直接从 `status.glmLocalUsage` 读取（ProviderCardView），
    /// `usageProjection` 不携带也不修改它 —— 合并路径无法再影响闲时窗口。
    func testGlmOffPeakWindowsStayOnNativeUsageOutsideProjection() {
        let day = Self.todayMidnight(calendar: .current)
        let native = GlmLocalUsage(
            today: GlmDailyUsage(dayStart: day, inputTokens: 10, rounds: 1),
            dailyTokenUsage: [GlmDailyUsage(dayStart: day, inputTokens: 10, rounds: 1)],
            scannedAt: day, sessionCount: 1, eventCount: 1, failedSessionCount: 0,
            recentSamples: [],
            offPeakWindows: [GlmOffPeakWindow(
                startedAt: day, endedAt: day.addingTimeInterval(600)
            )]
        )

        var status = ProviderStatus(
            id: "glm", displayName: "GLM", kind: .glmCodingPlan,
            iconSystemName: "circle", accentColor: .glm,
            refreshIntervalSeconds: 300, state: .ready
        )
        status.glmLocalUsage = native

        // 卡片读取闲时窗口的唯一入口仍是 native usage。
        XCTAssertEqual(status.glmLocalUsage?.offPeakWindows.count, 1)
        // projection 只表达 token 用量，闲时窗口不参与、也不受合并影响。
        _ = status.usageProjection(for: nil)
        XCTAssertEqual(status.glmLocalUsage?.offPeakWindows.count, 1)
    }
}
