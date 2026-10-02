import XCTest
import SwiftUI
import AppKit
@testable import LLM_monitor

/// 「额度窗口用量」区块的**价值**那一格，以及重置卡明细的可达性。
///
/// 单独一个文件而不是并进 `QuotaWindowUsageTests`：这里测的是两条**可达性**性质
/// （金额有没有真的算、五指标行会不会换行、重置卡逐张明细能不能被看到），与那份
/// 文件里的「窗口口径/比率/时间构成条」是两批断言，混在一个文件里会互相淹没。
final class QuotaWindowUsageValueTests: XCTestCase {

    // MARK: - 价值估算

    /// 金额走 `ModelPricingCatalog`，**原币种**显示（智谱 ¥、OpenAI/Antigravity $），
    /// 不用本地货币换算——本地用量那条链（`ClientProviderUsageSummary`）也是原币种，
    /// 同一张卡上出现两个币种才是问题。
    func testWindowValueUsesThePricingCatalogInOriginalCurrency() {
        let now = Date()
        let sample = Self.sample(
            at: now.addingTimeInterval(-600),
            prompt: "p1",
            model: "glm-5.3"
        )
        let snapshot = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "glm_coding_plan", interval: true, weekly: true, now: now),
            providerKind: .glmCodingPlan,
            samples: [sample],
            intervalLabel: "5h",
            weeklyLabel: "周",
            quotaProviderID: QuotaProviderID.zhipu
        )

        let cost = try? XCTUnwrap(snapshot.interval?.cost)
        XCTAssertNotNil(cost, "窗口内有样本就必须有金额（哪怕是『未定价』也有值对象）")
        XCTAssertEqual(snapshot.interval?.cost?.currency, .cny, "智谱的价目表是人民币，不能被换算成别的币种")
        XCTAssertTrue(
            QuotaWindowUsageMetricRow.costText(snapshot.interval?.cost).hasPrefix("¥"),
            "金额文案必须是原币种符号开头（现在是 \(QuotaWindowUsageMetricRow.costText(snapshot.interval?.cost))）"
        )
        XCTAssertGreaterThan(snapshot.interval?.cost?.value ?? 0, 0)

        // 金额必须与"同一批样本单独估价"完全一致——区块的金额不是另算的一套。
        let direct = ModelPricingCatalog.estimate(
            samples: [sample],
            quotaProviderID: QuotaProviderID.zhipu
        )
        XCTAssertEqual(
            snapshot.interval?.cost?.value ?? 0, direct.value ?? 0, accuracy: 1e-9,
            "区块金额与定价目录对同一批样本的估价必须逐分一致"
        )
    }

    /// 窗口里没有本地样本 → `—`；有样本但查不到价 → `未定价`。两者含义不同。
    func testEmptyWindowAndUnpricedWindowReadDifferently() {
        let now = Date()
        let model = Self.model(name: "glm_coding_plan", interval: true, weekly: true, now: now)

        let empty = LocalUsageSummaryBuilder.windowUsage(
            model: model,
            providerKind: .glmCodingPlan,
            samples: [],
            intervalLabel: "5h",
            weeklyLabel: "周",
            quotaProviderID: QuotaProviderID.zhipu
        )
        XCTAssertNil(empty.interval?.cost, "没有样本就没有金额（不是 0 元）")
        XCTAssertEqual(QuotaWindowUsageMetricRow.costText(empty.interval?.cost), "—")

        // 有样本但查不到价：`openAI` 价目表没有兜底条目（智谱有 `GLM-5.3-Flash(兜底)`，
        // 拿它当"未定价"的例子会永远命中兜底价，测出来是个假的 0）。
        let unpriced = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "chatgpt_plan", interval: true, weekly: true, now: now),
            providerKind: .codexChatGpt,
            samples: [Self.sample(at: now.addingTimeInterval(-600), prompt: "p1", model: "some-unknown-model-2099")],
            intervalLabel: "5h",
            weeklyLabel: "周",
            quotaProviderID: QuotaProviderID.openAI
        )
        XCTAssertEqual(
            QuotaWindowUsageMetricRow.costText(unpriced.interval?.cost), "未定价",
            "有样本但全部查不到价要说『未定价』，不能退回 —（会被读成『没花过钱』）"
        )
    }

    /// DeepSeek 高峰 ×2 是**按每条样本的时刻**判的，不是整窗统一乘。
    ///
    /// 窗口横跨 10:00（高峰）与 13:00（非高峰）两个小时，两条样本用同一个模型与
    /// 同样的 token 数。整窗 ×2 的实现会让 13:00 那条也多算一倍，金额直接翻倍；
    /// 逐条判的实现等于"两条各自单算再相加"。断言的是后者。
    func testDeepSeekValueAppliesThePeakMultiplierPerSample() {
        let peakAt = Self.beijingDate(hour: 10, minute: 0)
        let offPeakAt = Self.beijingDate(hour: 13, minute: 0)
        // 5h 窗口覆盖 09:00–14:00，两条样本都在里面。
        let resetsAt = Self.beijingDate(hour: 14, minute: 0)
        let model = Self.model(
            name: "deepseek_balance",
            interval: true,
            weekly: false,
            now: peakAt,
            intervalResetsAt: resetsAt,
            intervalWindowSeconds: 5 * 3600
        )
        let peakSample = Self.sample(at: peakAt, prompt: "peak", model: "deepseek-chat")
        let offPeakSample = Self.sample(at: offPeakAt, prompt: "offpeak", model: "deepseek-chat")

        let snapshot = LocalUsageSummaryBuilder.windowUsage(
            model: model,
            providerKind: .deepseek,
            samples: [peakSample, offPeakSample],
            intervalLabel: "5h",
            weeklyLabel: "周",
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .defaultWindow
        )

        let peakOnly = ModelPricingCatalog.estimate(
            samples: [peakSample],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .defaultWindow
        )
        let offPeakOnly = ModelPricingCatalog.estimate(
            samples: [offPeakSample],
            quotaProviderID: QuotaProviderID.deepseek,
            deepseekPeakWindow: .defaultWindow
        )
        XCTAssertEqual(snapshot.interval?.usage?.rounds, 2, "两条样本都要在窗口里")
        XCTAssertEqual(
            snapshot.interval?.cost?.value ?? 0, (peakOnly.value ?? 0) + (offPeakOnly.value ?? 0), accuracy: 1e-9,
            "跨峰谷的窗口必须逐条判倍率"
        )
        // 前置条件：高峰确实 ×2（否则上面那条断言恒成立、挡不住回归）。
        XCTAssertEqual(
            (peakOnly.value ?? 0) / max(offPeakOnly.value ?? 0, .leastNonzeroMagnitude), 2, accuracy: 1e-6,
            "前提不成立：10:00 那条应当按 2× 计价"
        )
    }

    /// `deepseekPeakWindow` 真的接进这条路径：换一份窗口配置，金额跟着变。
    ///
    /// 只断言"值不同"就够——它证明调用点没有把 `status.deepseekPeakWindow` 吞掉
    /// 换成写死的 `.defaultWindow`。
    func testDeepSeekValueFollowsTheProvidedPeakWindow() {
        let at = Self.beijingDate(hour: 13, minute: 0)
        let snapshotWith = { (window: DeepseekPeakWindow) in
            LocalUsageSummaryBuilder.windowUsage(
                model: Self.model(
                    name: "deepseek_balance",
                    interval: true,
                    weekly: false,
                    now: at,
                    intervalResetsAt: Self.beijingDate(hour: 14, minute: 0),
                    intervalWindowSeconds: 5 * 3600
                ),
                providerKind: .deepseek,
                samples: [Self.sample(at: at, prompt: "p", model: "deepseek-chat")],
                intervalLabel: "5h",
                weeklyLabel: "周",
                quotaProviderID: QuotaProviderID.deepseek,
                deepseekPeakWindow: window
            )
        }
        let offPeak = snapshotWith(.defaultWindow)
        // 把 12:00–14:00 也登记成高峰：官方口径下 13:00 是平价，这份配置下是 ×2。
        let onPeak = snapshotWith(.init(
            slots: [
                .init(startHour: 9, endHour: 12),
                .init(startHour: 12, endHour: 14),
                .init(startHour: 14, endHour: 18)
            ],
            weekdaysOnly: true
        ))
        XCTAssertNotEqual(
            offPeak.interval?.cost?.value, onPeak.interval?.cost?.value,
            "深搜高峰窗口必须随调用方给的值求值，不能写死默认口径"
        )
    }

    /// 多额度池合计时金额相加；币种不一致则**拒绝**给数（跨币种相加是编造）。
    func testCombinedPoolsSumMoneyAndRefuseMixedCurrency() {
        let now = Date()
        let first = QuotaWindowUsageSnapshot(
            interval: .init(
                label: "5h",
                usage: nil,
                resetsAt: now,
                cost: ModelCostEstimate(
                    value: 1.5, currency: .cny, pricedModelNames: ["a"], unpricedModelNames: []
                )
            ),
            weekly: nil,
            poolCount: 1
        )
        let second = QuotaWindowUsageSnapshot(
            interval: .init(
                label: "5h",
                usage: nil,
                resetsAt: now,
                cost: ModelCostEstimate(
                    value: 2.0, currency: .cny, pricedModelNames: ["b"], unpricedModelNames: []
                )
            ),
            weekly: nil,
            poolCount: 1
        )
        let dollars = QuotaWindowUsageSnapshot(
            interval: .init(
                label: "5h",
                usage: nil,
                resetsAt: now,
                cost: ModelCostEstimate(
                    value: 9.0, currency: .usd, pricedModelNames: ["c"], unpricedModelNames: []
                )
            ),
            weekly: nil,
            poolCount: 1
        )

        let sameCurrency = LocalUsageSummaryBuilder.combineWindowUsage([first, second])
        XCTAssertEqual(sameCurrency.interval?.cost?.value ?? 0, 3.5, accuracy: 1e-9)
        XCTAssertEqual(sameCurrency.interval?.cost?.currency, .cny)
        XCTAssertEqual(
            sameCurrency.interval?.cost?.pricedModelNames, ["a", "b"],
            "合并后已计价模型名要去重合并，否则 hover 明细会重复列"
        )

        let mixed = LocalUsageSummaryBuilder.combineWindowUsage([first, dollars])
        XCTAssertNil(
            mixed.interval?.cost,
            "跨币种相加会得到一个没有意义的数，宁可显示 —"
        )
    }

    // MARK: - 五个指标不换行

    /// 一行五个指标在 336pt 卡片的内容宽（336 − 2×12 = 312pt）里必须**一行**。
    ///
    /// 换行是最难在代码评审里发现的排版回归：视图不报错、数字都对，只是第二段
    /// 掉到下一行，读者会把 `¥12.34` 当成另一件事。断言方式是"限宽下的高度 == 不限
    /// 宽下的高度"——不等就说明它折了。
    @MainActor
    func testMetricRowStaysOnOneLineInsideTheCardContentWidth() {
        let contentWidth = 336.0 - 2 * ProviderCardView.contentPadding
        let singleLine = self.measuredHeight(of: Self.row(of: Self.row(named: "典型值")), width: 1_000)
        XCTAssertGreaterThan(singleLine, 0, "前提不成立：这一行必须真的排得出来")

        for name in ["典型值", "部分计价", "超长金额"] {
            let constrained = self.measuredHeight(
                of: Self.row(of: Self.row(named: name)),
                width: contentWidth
            )
            XCTAssertEqual(
                constrained, singleLine, accuracy: 0.5,
                "\(name) 这一行在 \(Int(contentWidth))pt 里折行了（\(constrained)pt vs 单行 \(singleLine)pt）"
            )
        }
    }

    /// 降级顺序：宽度不够时先压标签（`出比` / `思`），数值一个都不压。
    func testCompactLabelsOnlyShortenTheTwoLongestOnes() {
        let full = QuotaWindowUsageMetricRow.labels(compact: false)
        let compact = QuotaWindowUsageMetricRow.labels(compact: true)
        XCTAssertEqual(full.outIn, "出/入")
        XCTAssertEqual(full.think, "思考")
        XCTAssertEqual(compact.outIn, "出比")
        XCTAssertEqual(compact.think, "思")
        XCTAssertEqual(compact.hit, full.hit, "『命中』最短，缩了就认不出，不参与压缩")
    }

    // MARK: - 重置卡逐张明细的可达性

    /// dock 浮层 `ignoresMouseEvents = true` → 重置卡那行 `revealsDetail: false`，
    /// 纯 hover 展不开。逐张明细因此**必须**并到「额度窗口用量」区块的浮层里，
    /// 否则它就是一个只有总数、看不到明细的死角。
    ///
    /// 断言方式是"逐张明细真的进了常展树"：按 dock 的 `.alwaysVisible` 量一次高度，
    /// 条数越多高度越高，且比"只有折叠态摘要"高得多。
    @MainActor
    func testResetCreditsListIsReachableInTheAlwaysVisibleSection() {
        let snapshot = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "deepseek_balance", interval: false, weekly: false, now: Date()),
            providerKind: .deepseek,
            samples: [],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        XCTAssertTrue(snapshot.isEmpty, "前提不成立：这里用的是没有额度窗口的快照")

        let withCredits = self.measuredHeight(
            of: Self.dockHosted(
                QuotaWindowUsageSection(snapshot: snapshot, resetCredits: Self.resetCredits(count: 3))
            ),
            width: 312
        )
        let withMoreCredits = self.measuredHeight(
            of: Self.dockHosted(
                QuotaWindowUsageSection(snapshot: snapshot, resetCredits: Self.resetCredits(count: 6))
            ),
            width: 312
        )
        let withoutCredits = self.measuredHeight(
            of: Self.dockHosted(QuotaWindowUsageSection(snapshot: snapshot)),
            width: 312
        )

        XCTAssertEqual(withoutCredits, 0, "没有窗口也没有重置卡时整块不渲染")
        XCTAssertGreaterThan(
            withCredits, withoutCredits,
            "有重置卡就必须渲染出明细（否则逐张清单在 dock 上不可达）"
        )
        XCTAssertGreaterThan(
            withMoreCredits, withCredits,
            "明细是**逐张**列的：多三张卡必须多出三行，固定高度说明画的是总数不是清单"
        )
    }

    /// 清单只列 `available`，按到期日升序；两个消费面（重置卡 hover、区块浮层）
    /// 走的是同一个 `ResetCreditsDetailList.availableEntries(in:)`。
    func testResetCreditsListSortsAvailableEntriesByExpiry() {
        let resets = ResetCreditsInfo(
            entries: [
                Self.credit(id: "late", status: "available", expiresAt: Self.beijingDate(hour: 20, minute: 0).addingTimeInterval(86_400)),
                Self.credit(id: "soon", status: "available", expiresAt: Self.beijingDate(hour: 20, minute: 0)),
                Self.credit(id: "used", status: "used", expiresAt: Self.beijingDate(hour: 20, minute: 0)),
                Self.credit(id: "no-date", status: "available", expiresAt: nil)
            ],
            serverAvailableCount: nil,
            totalEarnedCount: nil
        )
        XCTAssertEqual(
            ResetCreditsDetailList.availableEntries(in: resets).map(\.id),
            ["soon", "late", "no-date"],
            "只列 available，按到期日升序，没有日期的排最后"
        )
        XCTAssertEqual(resets.availableCount, 3, "折叠态那句『重置卡数量』与清单长度必须一致")
    }

    // MARK: - helpers

    @MainActor
    private func measuredHeight<V: View>(of view: V, width: CGFloat) -> CGFloat {
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: width)))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 10_000)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private struct RowFixture {
        let label: String
        let metrics: QuotaWindowUsageMetrics
        let cost: ModelCostEstimate?
    }

    /// 三档宽度：常规 / 部分计价（多 6 个字）/ 超长金额。行宽不能被最长的那档撑破，
    /// 也不能被常规那档顶到第二行。
    private static func row(named name: String) -> RowFixture {
        switch name {
        case "部分计价":
            return RowFixture(
                label: "周",
                metrics: QuotaWindowUsageMetrics(
                    input: 1_234_567, cachedInput: 987_654_321, output: 12_345_678, reasoning: 45_678_901
                ),
                cost: ModelCostEstimate(
                    value: 1234.56,
                    currency: .cny,
                    pricedModelNames: ["a"],
                    unpricedModelNames: ["b"]
                )
            )
        case "超长金额":
            return RowFixture(
                label: "日",
                metrics: QuotaWindowUsageMetrics(
                    input: 1_234_567, cachedInput: 987_654_321, output: 12_345_678, reasoning: 45_678_901
                ),
                cost: ModelCostEstimate(
                    value: 1_234_567.89,
                    currency: .cny,
                    pricedModelNames: ["a"],
                    unpricedModelNames: ["b", "c", "d", "e", "f"]
                )
            )
        default:
            return RowFixture(
                label: "5h",
                metrics: QuotaWindowUsageMetrics(
                    input: 1_000, cachedInput: 9_000, output: 1_000, reasoning: 2_000
                ),
                cost: ModelCostEstimate(
                    value: 12.34,
                    currency: .cny,
                    pricedModelNames: ["a"],
                    unpricedModelNames: []
                )
            )
        }
    }

    @MainActor
    private static func row(of fixture: RowFixture) -> QuotaWindowUsageMetricRow {
        QuotaWindowUsageMetricRow(
            label: fixture.label,
            metrics: fixture.metrics,
            cost: fixture.cost
        )
    }

    /// 按 dock 浮层的形态渲染（就地展开，hover 拿不到任何东西）。
    @MainActor
    private static func dockHosted<V: View>(_ view: V) -> some View {
        view.environment(\.hoverRevealMode, .alwaysVisible)
    }

    private static func model(
        name: String,
        interval: Bool,
        weekly: Bool,
        now: Date,
        intervalResetsAt: Date? = nil,
        intervalWindowSeconds: Int? = nil
    ) -> ModelQuota {
        ModelQuota(
            modelName: name,
            intervalTotalCount: 100,
            intervalUsageCount: 40,
            intervalRemainingPercent: 60,
            intervalStatus: interval ? .present : .absent,
            intervalResetsAt: interval ? (intervalResetsAt ?? now.addingTimeInterval(2 * 3600)) : nil,
            intervalWindowSeconds: interval ? (intervalWindowSeconds ?? 5 * 3600) : nil,
            weeklyTotalCount: 700,
            weeklyUsageCount: 300,
            weeklyRemainingPercent: weekly ? 60 : 0,
            weeklyStatus: weekly ? .present : .absent,
            weeklyResetsAt: weekly ? now.addingTimeInterval(3 * 86400) : nil,
            weeklyWindowSeconds: weekly ? 7 * 24 * 3600 : nil
        )
    }

    private static func sample(
        at date: Date,
        prompt: String,
        model: String
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: date,
            modelName: model,
            promptID: prompt,
            inputTokens: 1_000,
            cachedInputTokens: 9_000,
            outputTokens: 1_000,
            reasoningOutputTokens: 2_000,
            sourceProviderID: nil
        )
    }

    private static func credit(id: String, status: String, expiresAt: Date?) -> ResetCreditEntry {
        ResetCreditEntry(
            id: id,
            status: status,
            expiresAt: expiresAt,
            grantedAt: nil,
            resetType: "codex_rate_limits",
            title: nil,
            description: nil
        )
    }

    private static func resetCredits(count: Int) -> ResetCreditsInfo {
        ResetCreditsInfo(
            entries: (0..<count).map { index in
                credit(
                    id: "c\(index)",
                    status: "available",
                    expiresAt: beijingDate(hour: 20, minute: 0).addingTimeInterval(Double(index) * 86_400)
                )
            },
            serverAvailableCount: count,
            totalEarnedCount: count
        )
    }

    /// 北京时间当天（周一）的某个整点。
    private static func beijingDate(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 5
        components.hour = hour
        components.minute = minute
        components.second = 0
        return PeakWindow.beijingCalendar.date(from: components)!
    }
}
