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

    /// 多 model provider（Antigravity 两组）按 provider 合计，重置时刻取最早。
    func testCombineSumsModelPoolsAndTakesTheEarliestReset() {
        let now = Date()
        let gemini = LocalUsageSummaryBuilder.windowUsage(
            model: Self.antigravityModel(
                name: AntigravityModelKind.geminiModels.rawValue,
                intervalResetsAt: now.addingTimeInterval(2 * 3600),
                weeklyResetsAt: now.addingTimeInterval(3 * 86400)
            ),
            providerKind: .antigravity,
            samples: [Self.sample(at: now.addingTimeInterval(-600), prompt: "gemini", model: "gemini-3-pro")],
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
            samples: [Self.sample(at: now.addingTimeInterval(-300), prompt: "claude", model: "claude-sonnet-4-5")],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )

        let merged = LocalUsageSummaryBuilder.combineWindowUsage([gemini, claude])
        XCTAssertEqual(merged.interval?.usage?.rounds, 2, "两个额度池的用量必须相加，不能只留一个")
        XCTAssertEqual(merged.weekly?.usage?.rounds, 2)
        XCTAssertEqual(merged.interval?.resetsAt, now.addingTimeInterval(1 * 3600), "重置时刻取最早的那个")
        XCTAssertEqual(merged.weekly?.resetsAt, now.addingTimeInterval(3 * 86400))
        XCTAssertEqual(merged.poolCount, 2, "poolCount > 0 时 UI 必须说明这是合计")
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
            QuotaWindowUsageSection.visibleRows(snapshot: snapshot, today: nil).isEmpty,
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
}
