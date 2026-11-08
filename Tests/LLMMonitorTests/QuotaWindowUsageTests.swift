import XCTest
import SwiftUI
import AppKit
@testable import LLM_monitor

/// 「额度窗口用量」区块：窗口聚合口径、三个比率、以及截断短文案。
///
/// 这个区块的数据**不是**新算的——窗口边界与闲时排除都取自额度行同一份
/// `LocalUsageSummaryBuilder`。所以这里钉的不是"聚合算得对不对"（那是
/// `LocalUsageSummaryBuilder` 自己的测试），而是**这条消费路径有没有换口径**：
/// 一旦有人在这个区块里另推一套 5h 起点、或忘了排 GLM 闲时任务，条与数字
/// 就会和上面额度行的 hover 明细对不上——这种漂移不崩不报错，只能靠断言挡住。
final class QuotaWindowUsageTests: XCTestCase {

    // MARK: - 窗口聚合口径

    /// 5h / 周两个窗口各取各的区间，且 GLM 闲时任务不进额度窗口。
    ///
    /// 四条样本各占一格：5h 内、周内但 5h 外、两个窗口都外、闲时（真实消耗但不
    /// 消耗积分）。少放任何一条，这个测试都会"看起来对"——因为漏掉的样本恰好
    /// 落在两个窗口的公共部分或交集之外。
    func testWindowUsageRespectsBothWindowsAndExcludesGlmOffPeak() {
        let now = Date()
        let model = Self.glmModel(now: now)
        let samples = [
            // 5h 与周的交集内
            Self.sample(at: now.addingTimeInterval(-3600), prompt: "in-both", source: "builtin:bigmodel-coding-plan"),
            // 周窗口内、5h 之外
            Self.sample(at: now.addingTimeInterval(-6 * 3600), prompt: "weekly-only", source: "builtin:bigmodel-coding-plan"),
            // 两个窗口都之外
            Self.sample(at: now.addingTimeInterval(-5 * 86400), prompt: "too-old", source: "builtin:bigmodel-coding-plan"),
            // 闲时任务：真实消耗，但不消耗 Coding Plan 积分
            Self.sample(at: now.addingTimeInterval(-1800), prompt: "offpeak", source: "offpeak-idle-plan"),
        ]

        let snapshot = LocalUsageSummaryBuilder.windowUsage(
            model: model,
            providerKind: .glmCodingPlan,
            samples: samples,
            intervalLabel: "5h",
            weeklyLabel: "周",
            excludeGlmOffPeak: true
        )

        XCTAssertEqual(snapshot.interval?.usage?.rounds, 1, "5h 窗口只该算交集内那一条（闲时被排除）")
        XCTAssertEqual(snapshot.weekly?.usage?.rounds, 2, "周窗口应含 5h 内 + 5h 外两条（闲时被排除）")
        XCTAssertEqual(snapshot.interval?.resetsAt, model.intervalResetsAt)
        XCTAssertEqual(snapshot.weekly?.resetsAt, model.weeklyResetsAt)
        XCTAssertEqual(snapshot.interval?.label, "5h")
        XCTAssertEqual(snapshot.weekly?.label, "周")
    }

    /// 不传 `excludeGlmOffPeak` 时闲时样本照常计入——这条断言是为了说明"排除"
    /// 确实是这个调用方（GLM 卡）开的，而不是 `summary` 无条件排除。
    func testOffPeakIsOnlyExcludedWhenTheCallerAsks() {
        let now = Date()
        let model = Self.glmModel(now: now)
        let samples = [
            Self.sample(at: now.addingTimeInterval(-600), prompt: "normal", source: "builtin:bigmodel-coding-plan"),
            Self.sample(at: now.addingTimeInterval(-500), prompt: "offpeak", source: "offpeak-idle-plan"),
        ]
        let kept = LocalUsageSummaryBuilder.windowUsage(
            model: model,
            providerKind: .glmCodingPlan,
            samples: samples,
            intervalLabel: "5h",
            weeklyLabel: "周",
            excludeGlmOffPeak: false
        )
        let excluded = LocalUsageSummaryBuilder.windowUsage(
            model: model,
            providerKind: .glmCodingPlan,
            samples: samples,
            intervalLabel: "5h",
            weeklyLabel: "周",
            excludeGlmOffPeak: true
        )
        XCTAssertEqual(kept.interval?.usage?.rounds, 2)
        XCTAssertEqual(excluded.interval?.usage?.rounds, 1)
    }

    /// 多 model provider（Antigravity 三组）按 provider 合计，重置时刻取最早，且 Argon 样本与 Gemini 普通样本互斥不重算。
    func testCombineSumsModelPoolsAndTakesTheEarliestReset() {
        let now = Date()
        let allSamples = [
            Self.sample(at: now.addingTimeInterval(-600), prompt: "gemini", model: "gemini-3.8-flash-high"),
            Self.sample(at: now.addingTimeInterval(-450), prompt: "argon", model: "gemini-4-argon-low"),
            Self.sample(at: now.addingTimeInterval(-300), prompt: "claude", model: "claude-sonnet-5-5-medium")
        ]
        let gemini = LocalUsageSummaryBuilder.windowUsage(
            model: Self.antigravityModel(
                name: AntigravityModelKind.geminiModels.rawValue,
                intervalResetsAt: now.addingTimeInterval(2 * 3600),
                weeklyResetsAt: now.addingTimeInterval(3 * 86400)
            ),
            providerKind: .antigravity,
            samples: allSamples,
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        let argon = LocalUsageSummaryBuilder.windowUsage(
            model: ModelQuota(
                modelName: AntigravityModelKind.geminiArgon.rawValue,
                intervalTotalCount: 0,
                intervalUsageCount: 0,
                intervalRemainingPercent: 0,
                intervalStatus: .absent,
                intervalResetsAt: nil,
                intervalWindowSeconds: nil,
                weeklyTotalCount: 0,
                weeklyUsageCount: 0,
                weeklyRemainingPercent: 85,
                weeklyStatus: .present,
                weeklyResetsAt: now.addingTimeInterval(4 * 86400),
                weeklyWindowSeconds: nil
            ),
            providerKind: .antigravity,
            samples: allSamples,
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        let claude = LocalUsageSummaryBuilder.windowUsage(
            model: Self.antigravityModel(
                name: AntigravityModelKind.claudeAndGptModels.rawValue,
                intervalResetsAt: now.addingTimeInterval(1 * 3600),
                weeklyResetsAt: now.addingTimeInterval(5 * 86400)
            ),
            providerKind: .antigravity,
            samples: allSamples,
            intervalLabel: "5h",
            weeklyLabel: "周"
        )

        XCTAssertEqual(gemini.weekly?.usage?.rounds, 1, "gemini_models 仅匹配非 Argon 的 Gemini 样本")
        XCTAssertEqual(argon.weekly?.usage?.rounds, 1, "gemini_argon 仅匹配 Argon 样本")
        XCTAssertEqual(claude.weekly?.usage?.rounds, 1, "claude_and_gpt_models 仅匹配 3P 样本")

        let merged = LocalUsageSummaryBuilder.combineWindowUsage([gemini, argon, claude])
        XCTAssertEqual(merged.interval?.usage?.rounds, 2, "有 5h 窗口的两个池（Gemini + Claude）相加")
        XCTAssertEqual(merged.weekly?.usage?.rounds, 3, "三个周窗口池互斥相加，不重不漏")
        XCTAssertEqual(merged.interval?.resetsAt, now.addingTimeInterval(1 * 3600), "重置时刻取最早的那个")
        XCTAssertEqual(merged.weekly?.resetsAt, now.addingTimeInterval(3 * 86400))
        XCTAssertEqual(merged.poolCount, 3, "poolCount > 0 时 UI 必须说明这是合计")
    }

    /// 窗口在、但本地零用量：数据上仍记录"窗口存在、usage 为 nil"（与窗口不存
    /// 在区分开），但 UI 上全零行整行跳过（第五轮改版）——不再出 `0 / —` 行，
    /// 取代"窗口存在但本地零用量仍然出一行"的旧规则。
    func testWindowWithoutLocalUsageIsSkippedAsAnAllZeroRow() {
        let now = Date()
        let snapshot = LocalUsageSummaryBuilder.windowUsage(
            model: Self.glmModel(now: now),
            providerKind: .glmCodingPlan,
            samples: [],
            intervalLabel: "5h",
            weeklyLabel: "周",
            excludeGlmOffPeak: true
        )
        XCTAssertNotNil(snapshot.interval, "窗口存在这件事在数据层仍要记录")
        XCTAssertNil(snapshot.interval?.usage, "本地零用量时 usage 是 nil（与'窗口不存在'区分开）")
        let metrics = QuotaWindowUsageMetrics(usage: snapshot.interval?.usage)
        XCTAssertEqual(metrics.totalTokens, 0, "四桶合计为 0 → 触发全零行跳过")
        XCTAssertNil(metrics.cacheHitRate, "分母为 0 的比率必须是 nil（显示 —），不是 0%")
        XCTAssertTrue(
            QuotaWindowUsageSection.visibleRows(snapshot: snapshot, today: nil, offPeak: nil).isEmpty,
            "全零行整行跳过：「额度分析」「额度详情」两个模块都不出这一行"
        )
    }

    // MARK: - 退化：单窗口 / 余额型

    /// 只有 5h 的 provider：只出 `interval` 一侧，周那一侧整个不存在。
    func testSingleWindowProviderKeepsOnlyThatSide() {
        let now = Date()
        let snapshot = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "general", interval: true, weekly: false, now: now),
            providerKind: .minimaxTokenPlan,
            samples: [Self.sample(at: now.addingTimeInterval(-600), prompt: "p1", model: "minimax-m3")],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        XCTAssertNotNil(snapshot.interval)
        XCTAssertNil(snapshot.weekly, "没有周窗口就不能凭空造一行「周」")
        XCTAssertFalse(snapshot.isEmpty)
    }

    /// 余额型 provider（DeepSeek API 余额）没有额度窗口 → 整块不显示。
    ///
    /// 断言两件事：数据上是空快照，渲染上是**零高度**（不是"画了但看不见"——
    /// 那会在余额行下面留一段空白）。
    @MainActor
    func testBalanceOnlyProviderRendersNoBlockAtAll() {
        let now = Date()
        let snapshot = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "deepseek_balance", interval: false, weekly: false, now: now),
            providerKind: .deepseek,
            samples: [Self.sample(at: now.addingTimeInterval(-600), prompt: "p1", model: "deepseek-chat")],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        XCTAssertTrue(snapshot.isEmpty, "余额型 provider 没有额度窗口，区块不该有任何数据")

        let height = measuredHeight(
            of: QuotaWindowUsageSection(snapshot: snapshot),
            width: 420
        )
        XCTAssertEqual(height, 0, "空快照必须整块不渲染（零高度），否则余额行下面会多出一段空白")

        let withWindows = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "general", interval: true, weekly: true, now: now),
            providerKind: .minimaxTokenPlan,
            samples: [Self.sample(at: now.addingTimeInterval(-600), prompt: "p1", model: "minimax-m3")],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        XCTAssertGreaterThan(
            measuredHeight(of: QuotaWindowUsageSection(snapshot: withWindows), width: 420), 0,
            "前提不成立：有窗口时区块必须真的画出来"
        )
    }

    // MARK: - minimax 贴日边界的 4h/5h 窗口

    /// minimax 的 5h 窗口贴固定日边界 00/05/10/15/20，最后一段 20:00→24:00 只有
    /// 4 小时。end 落在次日 0 点时，`windowBounds` 用真实长度 14400 反推
    /// start = 当日 20:00，不再退回 5h 兜底把起点错推到 19:00。
    ///
    /// 时区固定 Asia/Shanghai 构造（`windowBounds` 本身不做时区运算，边界就是
    /// 纯 `end − 长度`），断言在任意宿主时区下一致。
    func testWindowBoundsPinnedToRealStartWhenMinimaxEndsAtMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 21))!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 1, day: 16, hour: 0))!
        let windowStart = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 20))!

        let bounds = LocalUsageSummaryBuilder.windowBounds(
            resetsAt: midnight,
            explicitWindowSeconds: 4 * 60 * 60,
            fallbackSeconds: 5 * 60 * 60,
            now: evening
        )
        XCTAssertEqual(bounds?.end, midnight, "end 取服务端 reset 时刻（次日 0 点）")
        XCTAssertEqual(bounds?.start, windowStart, "4h 真实长度反推起点 = 当日 20:00，不回退 5h 兜底错推的 19:00")
    }

    /// windowUsage 级钉住修复前后的分界：20:00–24:00 段里，带真实 4h 长度的
    /// minimax model 只算 20:00 之后的样本；`intervalWindowSeconds` 为 nil 的
    /// model 退回 5h 兜底，把上一窗口 19:00–20:00 的样本也多算进来（修复前的
    /// 行为，作对照组）。4h/5h 均 < 86400，`intervalTimeRemainingFraction` 的
    /// 长窗口门禁不激活、仍为 nil。
    func testMinimaxShortWindowUsageExcludesPreviousWindowWhenLengthIsKnown() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: hour, minute: minute))!
        }
        let midnight = at(16, 0, 0)  // 次日 0 点：20:00→24:00 段的 end

        let samples = [
            // 上一窗口 19:00–20:00 内：4h 口径必须排除
            Self.sample(at: at(15, 19, 30), prompt: "prev-window", model: "minimax-m3"),
            // 当前 4h 段内：两种口径都该算
            Self.sample(at: at(15, 20, 30), prompt: "this-window", model: "minimax-m3"),
        ]

        let fixedModel = Self.minimaxModel(
            intervalWindowSeconds: 4 * 60 * 60,
            intervalResetsAt: midnight,
            weeklyResetsAt: calendar.date(byAdding: .day, value: 2, to: midnight)!
        )
        let fixed = LocalUsageSummaryBuilder.windowUsage(
            model: fixedModel,
            providerKind: .minimaxTokenPlan,
            samples: samples,
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        XCTAssertEqual(fixed.interval?.usage?.rounds, 1, "4h 真实长度：只算 20:30 那条，19:30 属于上一窗口")
        XCTAssertEqual(fixed.interval?.resetsAt, midnight)

        let legacyModel = Self.minimaxModel(
            intervalWindowSeconds: nil,
            intervalResetsAt: midnight,
            weeklyResetsAt: calendar.date(byAdding: .day, value: 2, to: midnight)!
        )
        let legacy = LocalUsageSummaryBuilder.windowUsage(
            model: legacyModel,
            providerKind: .minimaxTokenPlan,
            samples: samples,
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        XCTAssertEqual(legacy.interval?.usage?.rounds, 2, "无 windowSeconds 退回 5h 兜底：19:30 被多算 1 条（修复前行为，对照组）")

        // 统一时间感知算法下，4h/5h 短窗口均产生准确的时间比例
        let twoHoursBeforeMidnight = at(15, 22, 0)
        XCTAssertEqual(fixedModel.intervalTimeRemainingFraction(at: twoHoursBeforeMidnight), 0.5, "4h 窗口距 0 点剩 2 小时为 50%")
        XCTAssertEqual(legacyModel.intervalTimeRemainingFraction(at: twoHoursBeforeMidnight), 0.4, "5h 兜底窗口距 0 点剩 2 小时为 40%")
    }

    // MARK: - 三个比率

    /// 命中 = `cached / (input + cached)`、出/入 = `(reason + output) / (input + cached)`、
    /// 思考 = `reason / (reason + output)`。
    ///
    /// 三个分母各不相同，所以这条必须**分别**取对：一个公式用错分母时，另外两个
    /// 照样"看着合理"。
    func testRatiosUseTheFourBuckets() {
        let metrics = QuotaWindowUsageMetrics(
            input: 100, cachedInput: 900, output: 100, reasoning: 400
        )
        XCTAssertEqual(metrics.cacheHitRate ?? 0, 0.9, accuracy: 1e-9, "命中 = cached / (input + cached)")
        XCTAssertEqual(metrics.outputToInputRate ?? 0, 0.5, accuracy: 1e-9, "出/入 = (reason + output) / (input + cached)")
        XCTAssertEqual(metrics.reasoningShare ?? 0, 0.8, accuracy: 1e-9, "思考 = reason / (reason + output)")
        XCTAssertEqual(metrics.totalTokens, 1500)
    }

    /// `input` 桶是**未缓存**输入（明细里 `input` 那一行），不是 cache-inclusive
    /// 的 `inputTokens`——否则同一个窗口会同时出现"命中 90%"和"input 1,000"两种
    /// 互相矛盾的口径。
    func testInputBucketIsTheUncachedOne() {
        let usage = UsageMetricSummary(
            prompts: 1, rounds: 1,
            inputTokens: 1_000, cachedInputTokens: 900,
            outputTokens: 0, reasoningOutputTokens: 0
        )
        let metrics = QuotaWindowUsageMetrics(usage: usage)
        XCTAssertEqual(metrics.input, 100, "input 桶 = inputTokens − cachedInputTokens")
        XCTAssertEqual(metrics.cachedInput, 900)
    }

    /// 分母为 0 → nil（UI 显示 `—`）。
    func testRatiosAreNilWhenTheirDenominatorIsZero() {
        let empty = QuotaWindowUsageMetrics(usage: nil)
        XCTAssertNil(empty.cacheHitRate)
        XCTAssertNil(empty.outputToInputRate)
        XCTAssertNil(empty.reasoningShare)
        XCTAssertEqual(empty.totalTokens, 0)

        // 有输出、没有输入：思考占比算得出，前两个算不出。
        let outputOnly = QuotaWindowUsageMetrics(input: 0, cachedInput: 0, output: 50, reasoning: 50)
        XCTAssertNil(outputOnly.cacheHitRate, "没有任何输入时命中率没有意义")
        XCTAssertNil(outputOnly.outputToInputRate)
        XCTAssertEqual(outputOnly.reasoningShare ?? 0, 0.5, accuracy: 1e-9)

        // 有输入、没有输出：命中与出/入算得出，思考占比分母为 0。
        let inputOnly = QuotaWindowUsageMetrics(input: 100, cachedInput: 0, output: 0, reasoning: 0)
        XCTAssertEqual(inputOnly.cacheHitRate ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(inputOnly.outputToInputRate ?? -1, 0, accuracy: 1e-9)
        XCTAssertNil(inputOnly.reasoningShare, "没有输出时分母为 0，必须是 nil 而不是 0%")

        XCTAssertEqual(QuotaWindowUsageSection.rateText(nil, digits: 1), "—")
        XCTAssertEqual(QuotaWindowUsageSection.rateText(0.978, digits: 1), "97.8%")
        XCTAssertEqual(QuotaWindowUsageSection.rateText(0.41, digits: 0), "41%")
    }

    // MARK: - token 速度（tok/s）

    /// `windowTokenRate` 是 Σ(Output+Reason) ÷ Σ时长的**加权**聚合：
    /// (150 + 300) / (10 + 30) = 11.25 tok/s，而不是各样本速率 (15 + 10) / 2 = 12.5
    /// 的算术平均——慢请求时长权重大，才是"这一窗每秒烧了多少 token"的真值。
    func testWindowTokenRateWeightsBySummedTokensOverSummedDurations() throws {
        let now = Date()
        let samples = [
            Self.timedSample(at: now, prompt: "fast", output: 100, reasoning: 50, duration: 10),
            Self.timedSample(at: now, prompt: "slow", output: 200, reasoning: 100, duration: 30),
        ]
        let rate = try XCTUnwrap(LocalUsageSummaryBuilder.windowTokenRate(samples: samples))
        XCTAssertEqual(rate, 450.0 / 40.0, accuracy: 1e-9, "必须是 Σ/Σ 加权")
        XCTAssertNotEqual(rate, 12.5, accuracy: 1e-9, "前提不成立：两样本速率不同才挡得住算术平均回归")
    }

    /// `durationSeconds == nil`（账本未提供时长）的样本分子分母都不计——它的
    /// token 数若被记进分子，速率会被系统性高估。
    func testWindowTokenRateSkipsSamplesWithoutDuration() throws {
        let now = Date()
        let rate = try XCTUnwrap(LocalUsageSummaryBuilder.windowTokenRate(samples: [
            Self.timedSample(at: now, prompt: "known", output: 100, reasoning: 50, duration: 10),
            Self.timedSample(at: now, prompt: "unknown", output: 9_000, reasoning: 0, duration: nil),
        ]))
        XCTAssertEqual(rate, 150.0 / 10.0, accuracy: 1e-9, "只有时长已知的那条参与分子分母")
    }

    /// 有效性过滤 `duration ∈ [0.2, 3600]`：两端都是闭区间，界外剔除。
    func testWindowTokenRateFiltersDurationsOutsideTheValidityRange() throws {
        let now = Date()
        let rate = try XCTUnwrap(LocalUsageSummaryBuilder.windowTokenRate(samples: [
            Self.timedSample(at: now, prompt: "too-fast", output: 10_000, reasoning: 0, duration: 0.1),
            Self.timedSample(at: now, prompt: "lower-bound", output: 20, reasoning: 0, duration: 0.2),
            Self.timedSample(at: now, prompt: "upper-bound", output: 300, reasoning: 0, duration: 3600),
            Self.timedSample(at: now, prompt: "too-slow", output: 40_000, reasoning: 0, duration: 3600.1),
        ]))
        XCTAssertEqual(rate, 320.0 / 3600.2, accuracy: 1e-9, "0.2s 与 3600s 参与运算，0.1s 与 3600.1s 剔除")
    }

    /// 空数组与全无效样本都返回 nil（UI 显示 `—`），不是 0。
    func testWindowTokenRateReturnsNilWithoutValidSamples() {
        XCTAssertNil(LocalUsageSummaryBuilder.windowTokenRate(samples: []))
        let now = Date()
        XCTAssertNil(LocalUsageSummaryBuilder.windowTokenRate(samples: [
            Self.timedSample(at: now, prompt: "no-duration", output: 10, reasoning: 0, duration: nil),
        ]), "时长全未知的样本集合没有速率")
        XCTAssertNil(LocalUsageSummaryBuilder.windowTokenRate(samples: [
            Self.timedSample(at: now, prompt: "out-of-range", output: 10, reasoning: 0, duration: 7200),
        ]), "全被有效性过滤剔除时同样没有速率")
    }

    /// 速度分母是**解码时长**（调用时长 − 首字延迟）：10s 时长 + 2s TTFT +
    /// 100 token → 100 ÷ (10 − 2) = 12.5 tok/s，而不是 100 ÷ 10。
    func testWindowTokenRateSubtractsTTFTFromTheDenominator() throws {
        let now = Date()
        let rate = try XCTUnwrap(LocalUsageSummaryBuilder.windowTokenRate(samples: [
            Self.timedSample(at: now, prompt: "decode", output: 80, reasoning: 20, duration: 10, ttft: 2),
        ]))
        XCTAssertEqual(rate, 100.0 / 8.0, accuracy: 1e-9, "分母扣除 TTFT：duration − ttft = 8s")
    }

    /// 无 TTFT（nil，旧缓存 / OpenCode）的调用按时长**全额**计入：与带 TTFT 的
    /// 调用混合时 Σ/Σ 各取各的解码时长（8s 扣减 + 5s 全额）。
    func testWindowTokenRateCountsFullDurationWhenTTFTIsMissing() throws {
        let now = Date()
        let rate = try XCTUnwrap(LocalUsageSummaryBuilder.windowTokenRate(samples: [
            Self.timedSample(at: now, prompt: "with-ttft", output: 100, reasoning: 0, duration: 10, ttft: 2),
            Self.timedSample(at: now, prompt: "without-ttft", output: 150, reasoning: 0, duration: 5),
        ]))
        XCTAssertEqual(rate, 250.0 / 13.0, accuracy: 1e-9, "解码时长 = (10 − 2)s + 5s 全额")
    }

    /// `ttft ≥ duration` 视为账本异常：该调用整条剔除（分子分母都不计），
    /// 全部异常时没有速率（nil，不是 0）。
    func testWindowTokenRateExcludesCallsWhereTTFTCoversTheDuration() throws {
        let now = Date()
        let rate = try XCTUnwrap(LocalUsageSummaryBuilder.windowTokenRate(samples: [
            Self.timedSample(at: now, prompt: "valid", output: 100, reasoning: 0, duration: 10, ttft: 2),
            Self.timedSample(at: now, prompt: "anomaly-equal", output: 9_000, reasoning: 0, duration: 10, ttft: 10),
            Self.timedSample(at: now, prompt: "anomaly-over", output: 9_000, reasoning: 0, duration: 10, ttft: 12),
        ]))
        XCTAssertEqual(rate, 100.0 / 8.0, accuracy: 1e-9, "ttft ≥ duration 的两条异常调用不参与")

        XCTAssertNil(LocalUsageSummaryBuilder.windowTokenRate(samples: [
            Self.timedSample(at: now, prompt: "only-anomaly", output: 10, reasoning: 0, duration: 10, ttft: 10),
        ]), "全部调用 ttft ≥ duration 时没有速率（nil，不是 0）")
    }

    /// `windowUsage` 把速率写进产物：与 cost 同源（同一批 windowSamples），
    /// 分子分母一并带出供 `combineWindowUsage` 合并；时长全未知的窗口三元组全 nil。
    func testWindowUsageCarriesTokenRateWithMergeInputs() {
        let now = Date()
        let snapshot = LocalUsageSummaryBuilder.windowUsage(
            model: Self.glmModel(now: now),
            providerKind: .glmCodingPlan,
            samples: [
                Self.timedSample(at: now.addingTimeInterval(-600), prompt: "p1", output: 100, reasoning: 50, duration: 10),
                Self.timedSample(at: now.addingTimeInterval(-300), prompt: "p2", output: 0, reasoning: 0, duration: nil),
            ],
            intervalLabel: "5h",
            weeklyLabel: "周",
            excludeGlmOffPeak: true
        )
        XCTAssertEqual(snapshot.interval?.tokensPerSecond ?? 0, 150.0 / 10.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.interval?.rateNumerator ?? 0, 150, accuracy: 1e-9)
        XCTAssertEqual(snapshot.interval?.rateDenominator ?? 0, 10, accuracy: 1e-9)

        let withoutDurations = LocalUsageSummaryBuilder.windowUsage(
            model: Self.glmModel(now: now),
            providerKind: .glmCodingPlan,
            samples: [Self.sample(at: now.addingTimeInterval(-600), prompt: "legacy")],
            intervalLabel: "5h",
            weeklyLabel: "周",
            excludeGlmOffPeak: true
        )
        XCTAssertNil(withoutDurations.interval?.tokensPerSecond, "时长全未知的窗口没有速率（不是 0）")
        XCTAssertNil(withoutDurations.interval?.rateNumerator)
        XCTAssertNil(withoutDurations.interval?.rateDenominator)
    }

    /// 多池速率合并是 Σ分子 ÷ Σ时长：(150 + 300) / (10 + 30) = 11.25，不是
    /// (15 + 10) / 2 = 12.5 的各池速率平均——与单池 Σ/Σ 同口径。合并产物仍带
    /// 分子分母，可继续参与上层合并不丢精度；缺中间量的窗口缺席，不出假平均。
    func testCombineWindowUsageMergesTokenRatesBySummedNumeratorAndDenominator() throws {
        let now = Date()
        func pool(prompt: String, output: Int, reasoning: Int, duration: Double?) -> QuotaWindowUsageSnapshot {
            LocalUsageSummaryBuilder.windowUsage(
                model: Self.glmModel(now: now),
                providerKind: .glmCodingPlan,
                samples: [Self.timedSample(
                    at: now.addingTimeInterval(-600),
                    prompt: prompt,
                    output: output,
                    reasoning: reasoning,
                    duration: duration
                )],
                intervalLabel: "5h",
                weeklyLabel: "周",
                excludeGlmOffPeak: true
            )
        }
        let fast = pool(prompt: "fast", output: 100, reasoning: 50, duration: 10)   // 15 tok/s
        let slow = pool(prompt: "slow", output: 200, reasoning: 100, duration: 30)  // 10 tok/s
        XCTAssertEqual(fast.interval?.tokensPerSecond ?? 0, 15, accuracy: 1e-9, "前提：单池速率")
        XCTAssertEqual(slow.interval?.tokensPerSecond ?? 0, 10, accuracy: 1e-9)

        let merged = LocalUsageSummaryBuilder.combineWindowUsage([fast, slow])
        let rate = try XCTUnwrap(merged.interval?.tokensPerSecond)
        XCTAssertEqual(rate, 450.0 / 40.0, accuracy: 1e-9, "合并 = Σ分子 ÷ Σ时长")
        XCTAssertNotEqual(rate, 12.5, accuracy: 1e-9, "前提不成立：两池速率不同才挡得住假平均")
        XCTAssertEqual(merged.interval?.rateNumerator ?? 0, 450, accuracy: 1e-9)
        XCTAssertEqual(merged.interval?.rateDenominator ?? 0, 40, accuracy: 1e-9)

        // 一侧时长全未知：合并 = 另一侧自己的速率（缺中间量的窗口缺席）。
        let unknown = pool(prompt: "unknown", output: 9_000, reasoning: 0, duration: nil)
        XCTAssertNil(unknown.interval?.tokensPerSecond)
        let mergedWithUnknown = LocalUsageSummaryBuilder.combineWindowUsage([fast, unknown])
        XCTAssertEqual(mergedWithUnknown.interval?.tokensPerSecond ?? 0, 15, accuracy: 1e-9)
    }


    // MARK: - 文案

    /// 段截断提示是**单行**短文案，完整说明留在 `.help` 里。
    func testTruncationNoticeIsASingleShortLine() {
        XCTAssertFalse(
            HarnessSectionView.truncationShortText.contains("\n"),
            "菜单里的截断提示必须是单行"
        )
        XCTAssertLessThanOrEqual(
            HarnessSectionView.truncationShortText.count, 12,
            "短文案要在一行里放得下（336pt 内容区）"
        )
        XCTAssertTrue(
            HarnessSectionView.truncationShortText.count < ClientUsageTruncationNotice.text.count,
            "短文案必须比完整说明短——完整说明仍在 `.help` 里"
        )
    }

    // MARK: - helpers

    @MainActor
    private func measuredHeight<V: View>(of view: V, width: CGFloat) -> CGFloat {
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: width)))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 10_000)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private static func model(
        name: String,
        interval: Bool,
        weekly: Bool,
        now: Date
    ) -> ModelQuota {
        ModelQuota(
            modelName: name,
            intervalTotalCount: 100,
            intervalUsageCount: 40,
            intervalRemainingPercent: 60,
            intervalStatus: interval ? .present : .absent,
            intervalResetsAt: interval ? now.addingTimeInterval(2 * 3600) : nil,
            intervalWindowSeconds: interval ? 5 * 3600 : nil,
            weeklyTotalCount: 700,
            weeklyUsageCount: 300,
            weeklyRemainingPercent: weekly ? 60 : 0,
            weeklyStatus: weekly ? .present : .absent,
            weeklyResetsAt: weekly ? now.addingTimeInterval(3 * 86400) : nil,
            weeklyWindowSeconds: weekly ? 7 * 24 * 3600 : nil
        )
    }

    private static func glmModel(now: Date) -> ModelQuota {
        model(name: "glm_coding_plan", interval: true, weekly: true, now: now)
    }

    private static func antigravityModel(
        name: String,
        intervalResetsAt: Date,
        weeklyResetsAt: Date
    ) -> ModelQuota {
        ModelQuota(
            modelName: name,
            intervalTotalCount: 100,
            intervalUsageCount: 40,
            intervalRemainingPercent: 60,
            intervalStatus: .present,
            intervalResetsAt: intervalResetsAt,
            intervalWindowSeconds: 5 * 3600,
            weeklyTotalCount: 700,
            weeklyUsageCount: 300,
            weeklyRemainingPercent: 60,
            weeklyStatus: .present,
            weeklyResetsAt: weeklyResetsAt,
            weeklyWindowSeconds: 7 * 24 * 3600
        )
    }

    /// minimax `general` 额度池：窗口长度（4h/5h/nil）与 reset 时刻由用例给。
    private static func minimaxModel(
        intervalWindowSeconds: Int?,
        intervalResetsAt: Date,
        weeklyResetsAt: Date
    ) -> ModelQuota {
        ModelQuota(
            modelName: "general",
            intervalTotalCount: 100,
            intervalUsageCount: 40,
            intervalRemainingPercent: 60,
            intervalStatus: .present,
            intervalResetsAt: intervalResetsAt,
            intervalWindowSeconds: intervalWindowSeconds,
            weeklyTotalCount: 700,
            weeklyUsageCount: 300,
            weeklyRemainingPercent: 60,
            weeklyStatus: .present,
            weeklyResetsAt: weeklyResetsAt,
            weeklyWindowSeconds: 7 * 24 * 3600
        )
    }

    private static func sample(
        at date: Date,
        prompt: String,
        source: String? = nil,
        model: String? = "glm-4.6"
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: date,
            modelName: model,
            promptID: prompt,
            inputTokens: 1_000,
            cachedInputTokens: 9_000,
            outputTokens: 1_000,
            reasoningOutputTokens: 2_000,
            sourceProviderID: source
        )
    }

    /// 带单次调用时长的样本（token 速度用例专用）：分子 = output + reason。
    private static func timedSample(
        at date: Date,
        prompt: String,
        output: Int,
        reasoning: Int,
        duration: Double?,
        ttft: Double? = nil
    ) -> LocalTokenUsageSample {
        var sample = LocalTokenUsageSample(
            completedAt: date,
            modelName: "glm-4.6",
            promptID: prompt,
            inputTokens: 1_000,
            cachedInputTokens: 0,
            outputTokens: output,
            reasoningOutputTokens: reasoning
        )
        sample.durationSeconds = duration
        sample.ttftSeconds = ttft
        return sample
    }
}
