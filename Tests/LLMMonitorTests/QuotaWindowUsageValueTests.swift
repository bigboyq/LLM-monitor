import XCTest
import SwiftUI
import AppKit
@testable import LLM_monitor

/// 「额度窗口用量」区块的**价值**那一格，以及重置卡明细的可达性。
///
/// 单独一个文件而不是并进 `QuotaWindowUsageTests`：这里测的是**可达性**性质
/// （金额有没有真的算、六列指标行会不会换行、列宽跨行对不对齐、模块标题有没有
/// 真的画出来、全零行跳过与模块联动、重置卡逐张明细能不能被看到），与那份文件
/// 里的「窗口口径/比率」是两批断言，混在一个文件里会互相淹没。
final class QuotaWindowUsageValueTests: XCTestCase {

    /// **卡内容宽**（两个宿主一致）：dock 浮层的背板宽 `EdgeDockTheme.popoverWidth`
    /// 468 = 图表 420 + 2×卡片内容 padding 12 + 2×背板 padding 12；扣掉这两层
    /// 内边距后，卡片内容区就是 **420pt**（`EdgeDockTheme.popoverWidth` 减去
    /// 2×`popoverPadding` 再减 2×`cardContentPadding`）。菜单兜底行的 hover 卡走
    /// 同一个上限常量（`HoverPanelController.maximumPanelWidth`），所以两份宿主
    /// 装得下的是同一份宽度——**不再按旧主菜单的 312pt 核算**。
    private static let cardContentWidth: CGFloat =
        EdgeDockTheme.popoverWidth
        - EdgeDockTheme.popoverPadding * 2
        - LayoutMetrics.cardContentPadding * 2

    /// 「额度分析」六列平分卡内容宽时每列的份额：(420 − 5×10 间距) / 6 ≈ 61.7pt。
    /// 第八轮把 Grid 横向间距从 4 放宽到 10（右对齐的思考值与左对齐的价值金额
    /// 曾只隔 4pt 挤成一句）。命中/思考两列整列隐藏后按剩下的列数重新平分，
    /// 最窄的情形就是这个六列值。
    private static let statsColumnWidth: CGFloat = (cardContentWidth - 5 * 10) / 6

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
            QuotaWindowUsageSection.costText(snapshot.interval?.cost).hasPrefix("¥"),
            "金额文案必须是原币种符号开头（现在是 \(QuotaWindowUsageSection.costText(snapshot.interval?.cost))）"
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
        XCTAssertEqual(QuotaWindowUsageSection.costText(empty.interval?.cost), "—")

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
            QuotaWindowUsageSection.costText(unpriced.interval?.cost), "未定价",
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

    /// 「额度分析」的一行六个格子（类型/用量/命中/产出比/思考/价值）在**卡内容宽
    /// 420pt**（`EdgeDockTheme.popoverWidth` 468 − 2×12 背板 padding − 2×12 卡片
    /// padding，见 `cardContentWidth`）里必须**一行**。第三轮改版起行本体是
    /// `GridRow`（格子平分整行），所以测量时要复刻宿主形态：住进 `Grid`、字号
    /// 与单行约束由 `Grid` 施加——与 `QuotaWindowUsageSection.statsModule` 同一
    /// 写法（表头行的单行约束由 testStatsHeaderRowRendersAndCollapsesWithItsColumns
    /// 单独钉）。
    ///
    /// 换行是最难在代码评审里发现的排版回归：视图不报错、数字都对，只是第二段
    /// 掉到下一行，读者会把 `¥12.34` 当成另一件事。断言方式是"限宽下的高度 == 不限
    /// 宽下的高度"——不等就说明它折了。
    @MainActor
    func testMetricRowStaysOnOneLineInsideTheCardContentWidth() {
        let contentWidth = Self.cardContentWidth
        let singleLine = self.measuredHeight(of: Self.statsGrid(named: "典型值"), width: 1_000)
        XCTAssertGreaterThan(singleLine, 0, "前提不成立：这一行必须真的排得出来")

        for name in ["典型值", "部分计价", "超长金额"] {
            let constrained = self.measuredHeight(
                of: Self.statsGrid(named: name),
                width: contentWidth
            )
            XCTAssertEqual(
                constrained, singleLine, accuracy: 0.5,
                "\(name) 这一行在 \(Int(contentWidth))pt 里折行了（\(constrained)pt vs 单行 \(singleLine)pt）"
            )
        }
    }

    /// 多行共用同一 `Grid`：两行都在 Grid 里垂直排布。
    @MainActor
    func testMetricRowsShareOneGridSoColumnsAlignAcrossRows() {
        let longCost = RowFixture(
            label: "5h",
            metrics: QuotaWindowUsageMetrics(input: 1, cachedInput: 0, output: 0, reasoning: 0),
            cost: ModelCostEstimate(
                value: 1_234_567.89,
                currency: .cny,
                pricedModelNames: ["a"],
                unpricedModelNames: []
            )
        )
        let longRates = RowFixture(
            label: "周",
            metrics: QuotaWindowUsageMetrics(input: 1, cachedInput: 1, output: 1, reasoning: 1),
            cost: nil
        )

        let snapshot = QuotaWindowUsageSnapshot(
            interval: QuotaWindowUsageSnapshot.Window(
                label: longCost.label,
                usage: UsageMetricSummary(
                    prompts: 1, rounds: 1,
                    inputTokens: longCost.metrics.input + longCost.metrics.cachedInput,
                    cachedInputTokens: longCost.metrics.cachedInput,
                    outputTokens: longCost.metrics.output,
                    reasoningOutputTokens: longCost.metrics.reasoning
                ),
                resetsAt: nil,
                cost: longCost.cost
            ),
            weekly: QuotaWindowUsageSnapshot.Window(
                label: longRates.label,
                usage: UsageMetricSummary(
                    prompts: 1, rounds: 1,
                    inputTokens: longRates.metrics.input + longRates.metrics.cachedInput,
                    cachedInputTokens: longRates.metrics.cachedInput,
                    outputTokens: longRates.metrics.output,
                    reasoningOutputTokens: longRates.metrics.reasoning
                ),
                resetsAt: nil,
                cost: longRates.cost
            ),
            poolCount: 1
        )
        let section = QuotaWindowUsageSection(snapshot: snapshot, segmentOverride: .analysis)
        let sectionHeight = self.measuredHeight(of: section, width: Self.cardContentWidth)
        let singleHeight = self.measuredHeight(of: Self.statsGrid(fixture: longCost), width: Self.cardContentWidth)

        XCTAssertGreaterThan(sectionHeight, singleHeight + 5, "两行必须都在 Grid 里垂直排布（多出一行）")
    }

    /// 「额度分析」表头文案钉在这里（第五轮改版）：数据格不再带文字标签，列名
    /// 只在表头说一次；曾经的 `labels(compact:)` 紧凑降级随标签一起删除——固定
    /// 表头文案钉在这里：分析态与用量态各七列。数据格不再带文字标签，列名
    /// 只在表头说一次。
    func testStatsHeaderCopyIsPinned() {
        XCTAssertEqual(QuotaWindowUsageSection.statsHeaders.type, "类型")
        XCTAssertEqual(QuotaWindowUsageSection.statsHeaders.usage, "用量")
        XCTAssertEqual(QuotaWindowUsageSection.statsHeaders.hit, "命中")
        XCTAssertEqual(QuotaWindowUsageSection.statsHeaders.outputInput, "产出比")
        XCTAssertEqual(QuotaWindowUsageSection.statsHeaders.think, "思考")
        XCTAssertEqual(QuotaWindowUsageSection.statsHeaders.value, "价值")
        XCTAssertEqual(QuotaWindowUsageSection.statsHeaders.resetDate, "重置日期")

        XCTAssertEqual(QuotaWindowUsageSection.rawTableHeaders.type, "类型")
        XCTAssertEqual(QuotaWindowUsageSection.rawTableHeaders.input, "Input")
        XCTAssertEqual(QuotaWindowUsageSection.rawTableHeaders.cached, "Cached")
        XCTAssertEqual(QuotaWindowUsageSection.rawTableHeaders.output, "Output")
        XCTAssertEqual(QuotaWindowUsageSection.rawTableHeaders.reason, "Reason")
        XCTAssertEqual(QuotaWindowUsageSection.rawTableHeaders.value, "价值")
        XCTAssertEqual(QuotaWindowUsageSection.rawTableHeaders.resetDate, "重置日期")
    }

    /// 产出比（出/入比）自适应百分位格式化（纯函数）：
    /// - 值 ≥ 10 → 整数百分比（`12%`、`100%`）
    /// - 1 ≤ 值 < 10 → 1 位小数（`1.2%`、`9.9%`）
    /// - 值 < 1 → 2 位小数（`0.12%`、`0.00%`）
    /// 分档按原始值判定（先分档再格式化，不是舍入后再分档）。分母为 0（nil）显示 `—`。
    func testOutputInputRateAdaptiveFormatting() {
        // nil
        XCTAssertEqual(QuotaWindowUsageSection.outputInputRateText(nil), "—")

        // 1. ≥ 10.0% 档（整数百分比）
        XCTAssertEqual(QuotaWindowUsageSection.outputInputRateText(1.0), "100%")
        XCTAssertEqual(QuotaWindowUsageSection.outputInputRateText(0.12345), "12%")
        XCTAssertEqual(QuotaWindowUsageSection.outputInputRateText(0.10), "10%")

        // 2. 1.0% ≤ 值 < 10.0% 档（1 位小数）
        XCTAssertEqual(QuotaWindowUsageSection.outputInputRateText(0.099), "9.9%")
        XCTAssertEqual(QuotaWindowUsageSection.outputInputRateText(0.012), "1.2%")
        XCTAssertEqual(QuotaWindowUsageSection.outputInputRateText(0.01), "1.0%")
        // 阶梯边界：9.99% 原始值 < 10.0，属于 1 位小数档，先分档再格式化为 "10.0%"
        XCTAssertEqual(QuotaWindowUsageSection.outputInputRateText(0.0999), "10.0%")

        // 3. < 1.0% 档（2 位小数）
        XCTAssertEqual(QuotaWindowUsageSection.outputInputRateText(0.0099), "0.99%")
        XCTAssertEqual(QuotaWindowUsageSection.outputInputRateText(0.0012), "0.12%")
        XCTAssertEqual(QuotaWindowUsageSection.outputInputRateText(0.0), "0.00%")
    }

    /// 产出比格的 hover 说明（第七轮）：格子里只有一个 `xx.xxx%` 或一个 `—`，
    /// 光标停上去才说得出 `—` 是什么意思——**分母是输入侧总量，会话没有输入
    /// token 时算不出来**（不是 0）。文案钉在这里：这一条解释是这格唯一的
    /// 说明渠道，改文案必须连视图一起改。
    func testOutputInputRateHelpExplainsTheZeroDenominator() {
        XCTAssertFalse(
            QuotaWindowUsageSection.outputInputRateHelpUnavailable.isEmpty,
            "`—` 的说明不能为空，否则读者无从知道它不是 0%"
        )
        XCTAssertTrue(
            QuotaWindowUsageSection.outputInputRateHelpUnavailable.contains("无输入 token"),
            "`—` 的说明要点名「无输入 token」这个原因，实际文案：\(QuotaWindowUsageSection.outputInputRateHelpUnavailable)"
        )
        XCTAssertFalse(
            QuotaWindowUsageSection.outputInputRateHelp.isEmpty,
            "有值时也要说得出这一格是（思考 + 输出）/（输入 + 缓存输入）"
        )
    }

    /// 超长金额**换紧凑单位**，不再靠 `lineLimit(1)` 截尾（第七轮）。
    ///
    /// 420pt 卡内容宽下价值列只有 (420 − 50) / 6 ≈ 61.7pt（第八轮间距放宽后），
    /// 而 `¥1,234,567.89`
    /// 实测 ≥ 70pt——以前那一格是被截掉的半截数字。这里钉住阶梯（第八轮加 K 档）：
    /// 低于 10 万原样（两位小数、原币种符号），≥ 10 万走 `K`（一位小数），≥ 100 万
    /// 走 `M`，≥ 10 亿走 `B`；部分计价的后缀保留，币种不转换。
    func testLongCostCompactsToMillionsInsteadOfTruncating() {
        func estimate(_ value: Double, _ currency: ModelPriceCurrency = .cny, partial: Bool = false)
            -> ModelCostEstimate {
            ModelCostEstimate(
                value: value,
                currency: currency,
                pricedModelNames: ["a"],
                unpricedModelNames: partial ? ["b"] : []
            )
        }

        XCTAssertEqual(QuotaWindowUsageSection.costText(nil), "—")
        XCTAssertEqual(QuotaWindowUsageSection.costText(estimate(12.34)), "¥12.34", "常规金额仍走 displayText")
        XCTAssertEqual(QuotaWindowUsageSection.costText(estimate(45.67, .usd)), "$45.67", "原币种符号不换")
        XCTAssertEqual(
            QuotaWindowUsageSection.costText(estimate(99_999.99)), "¥99999.99",
            "阈值以下不缩写：9 个字符在 61.7pt 的列里（第八轮列宽）放得下"
        )
        XCTAssertEqual(QuotaWindowUsageSection.costText(estimate(123_456.78)), "¥123.5K", "刚过 10 万就换单位")
        XCTAssertEqual(QuotaWindowUsageSection.costText(estimate(1_000_000)), "¥1.00M", "刚过 100 万就换单位")
        XCTAssertEqual(
            QuotaWindowUsageSection.costText(estimate(1_234_567.89)), "¥1.23M",
            "超长金额缩成 M——原币种两位小数，读者自己乘回去"
        )
        XCTAssertEqual(QuotaWindowUsageSection.costText(estimate(2_500_000_000, .usd)), "$2.50B")
        XCTAssertEqual(
            QuotaWindowUsageSection.costText(estimate(1_234_567.89, partial: true)), "¥1.23M（部分计价）",
            "部分计价的后缀必须跟着金额一起换单位，不能只缩一半"
        )
        XCTAssertEqual(
            QuotaWindowUsageSection.costText(estimate(0)), "¥0.00",
            "零金额不是超长金额，不该出现 ¥0.00K"
        )
        XCTAssertEqual(
            QuotaWindowUsageSection.compactAmountText(999_999.99, symbol: "¥"),
            "¥1000.0K",
            "K 档上沿四舍五入到 1000.0 可接受（宽度实测仍远小于列宽），不跨档伪装成 M"
        )
    }

    /// 价值列的**两个档都要装得进 ≈61.7pt 的列**（第八轮间距放宽后的份额）：
    /// 阈值以下最宽的原样金额（`¥99999.99`）、阈值以上最宽的紧凑金额（`¥9.88M`）
    /// 都不得越过列宽——否则"不截尾"只是换了个截法。守门用的是同一套
    /// `NSHostingView` 量法（`MenuTypography.dataValue`，与 `statsModule` 施加的
    /// 字号一致）。
    @MainActor
    func testCompactedCostFitsInsideTheValueColumnShare() {
        func width(of value: Double) -> CGFloat {
            self.measuredWidth(
                of: Text(QuotaWindowUsageSection.costText(
                    ModelCostEstimate(
                        value: value, currency: .cny,
                        pricedModelNames: ["a"], unpricedModelNames: []
                    )
                )).font(MenuTypography.dataValue)
            )
        }
        let column = Self.statsColumnWidth
        let plainWidest = width(of: 99_999.99)
        let compactWidest = width(of: 9_876_543.21)

        XCTAssertLessThanOrEqual(
            column, (420 - 20) / 6 + 0.5,
            "前提不成立：六列份额应按 420pt 卡内容宽算（现在是 \(column)pt）"
        )
        XCTAssertGreaterThan(plainWidest, 0, "前提不成立：金额格必须真的排得出来")
        XCTAssertLessThanOrEqual(
            plainWidest, column,
            "阈值以下最宽的原样金额 \(plainWidest)pt 装不进价值列 \(column)pt（阈值定高了）"
        )
        XCTAssertLessThanOrEqual(
            compactWidest, column,
            "最宽的紧凑金额 \(compactWidest)pt 装不进价值列 \(column)pt，还是会被截尾"
        )
    }

    // MARK: - 模块标题（第三轮改版）

    /// 「额度分析」标题住在统计值模块内部：模块有内容才出现，且画在内容之上。
    ///
    /// 用「只剩今行」的形态隔离标题：快照无窗口、无重置卡，`today` 有一行 →
    /// 统计值模块 = 标题 + 时间构成条之外的内容（条无可见窗口行不画）+ 表头 +
    /// 一行指标。区块必须比同一行指标裸排时**高出一截**；完全无数据时整块为 0
    /// ——标题随模块一起消失，不会悬空。「额度详情」「重置卡详情」走同一机制
    /// （标题在模块内部、由既有显隐判定兜住），不各测一遍。
    @MainActor
    func testStatsModuleTitleRendersAboveItsRowsAndHidesWithTheModule() {
        let today = QuotaWindowUsageSection.Row(
            label: ProviderCardView.todayRowLabel,
            metrics: QuotaWindowUsageMetrics(input: 100, cachedInput: 900, output: 100, reasoning: 400),
            cost: nil
        )
        let empty = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "deepseek_balance", interval: false, weekly: false, now: Date()),
            providerKind: .deepseek,
            samples: [],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        XCTAssertTrue(empty.isEmpty, "前提不成立：这里用的是没有额度窗口的快照")

        let bareGrid = Grid(alignment: .leading, horizontalSpacing: QuotaWindowUsageSection.horizontalSpacing, verticalSpacing: 3) {
            GridRow {
                Text(today.label)
                Text(Formatters.formatTokenCountCompact(today.metrics.totalTokens))
                Text(QuotaWindowUsageSection.costText(today.cost))
            }
        }
        .font(MenuTypography.metricValue)
        .lineLimit(1)
        let bareRows = self.measuredHeight(of: bareGrid, width: Self.cardContentWidth)
        let withTitle = self.measuredHeight(
            of: QuotaWindowUsageSection(snapshot: empty, today: today),
            width: Self.cardContentWidth
        )
        let withoutModules = self.measuredHeight(
            of: QuotaWindowUsageSection(snapshot: empty),
            width: Self.cardContentWidth
        )

        XCTAssertEqual(withoutModules, 0, "无数据时整块（连同所有模块标题）不渲染")
        XCTAssertGreaterThan(
            withTitle - bareRows, 5,
            "「额度窗口」标题必须真的画出来（比裸指标行高出一行标题 + 间距的高度），现在是 \(withTitle - bareRows)pt"
        )
    }

    /// 标题文案钉在这里：模块标题「额度窗口」+ 重置卡详情 + 段2 段落标题 + 今行标签。
    /// 改文案必须连测试一起改，防止视图与文档各漂各的。
    func testTitleCopyIsPinned() {
        XCTAssertEqual(QuotaWindowUsageSection.windowUsageTitle, "额度窗口")
        XCTAssertEqual(QuotaWindowUsageSection.statsTitle, "额度窗口")
        XCTAssertEqual(QuotaWindowUsageSection.rawTableTitle, "额度窗口")
        XCTAssertEqual(QuotaWindowUsageSection.resetCreditsTitle, "重置卡详情")
        XCTAssertEqual(ProviderCardView.planSectionTitleText, "Plan详情")
        XCTAssertEqual(
            ProviderCardView.todayRowLabel, "今",
            "行标签第五轮起是「今」（从「今日」缩成），与「5h」「周」同一长度档"
        )
    }

    // MARK: - 全零行跳过与模块联动（第五轮改版）

    /// 全零行跳过：某行（5h/周/今）四桶 token 合计为 0 时整行跳过，「额度分析」
    /// 与「额度详情」两个模块都不出现该行。minimax 形态：全 0 的 5h 与今行消失，
    /// 周行保留；列显隐基于过滤后的行集。
    func testAllZeroRowsAreSkippedInBothModules() {
        let now = Date()
        // 5h 窗口存在但全零（样本只在 5h 之外、周窗口之内）；今行全零。
        let snapshot = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "general", interval: true, weekly: true, now: now),
            providerKind: .minimaxTokenPlan,
            samples: [Self.sample(at: now.addingTimeInterval(-6 * 3600), prompt: "weekly-only", model: "minimax-m3")],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        let today = QuotaWindowUsageSection.Row(
            label: ProviderCardView.todayRowLabel,
            metrics: QuotaWindowUsageMetrics(input: 0, cachedInput: 0, output: 0, reasoning: 0),
            cost: nil
        )

        XCTAssertEqual(
            QuotaWindowUsageSection.visibleRows(snapshot: snapshot, today: today, offPeak: nil).map(\.label),
            ["周"],
            "全 0 的 5h 与今行整行跳过，只剩周行"
        )
        // 列显隐基于过滤后的行集：周行有量，cached/output/reason 三列保留
        // （helper 的样本 cached > input，未缓存 input 桶钳成 0，Input 列隐藏）。
        let visibleRows = QuotaWindowUsageSection.visibleRows(snapshot: snapshot, today: today, offPeak: nil)
        let visibility = QuotaWindowUsageSection.numericColumnVisibility(rows: visibleRows.map(\.metrics))
        XCTAssertTrue(visibility.cached && visibility.output && visibility.reason, "周行有量的桶，列保留")

        // 余额型形态：没有窗口、今行全零 → 过滤后什么都不剩。
        let empty = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "deepseek_balance", interval: false, weekly: false, now: now),
            providerKind: .deepseek,
            samples: [],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        XCTAssertTrue(
            QuotaWindowUsageSection.visibleRows(snapshot: empty, today: today, offPeak: nil).isEmpty,
            "无窗口且今行全零 → 过滤后没有剩余行"
        )
    }

    /// 模块级联动：过滤后没有剩余行 → 模块（连标题「额度分析」/「额度详情」）
    /// 整体不渲染；只有重置卡可用时只剩重置卡模块。
    @MainActor
    func testModulesAndTitlesVanishWhenEveryRowIsFiltered() {
        let now = Date()
        let zeroWindows = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "deepseek_balance", interval: true, weekly: true, now: now),
            providerKind: .deepseek,
            samples: [],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        let zeroToday = QuotaWindowUsageSection.Row(
            label: ProviderCardView.todayRowLabel,
            metrics: QuotaWindowUsageMetrics(input: 0, cachedInput: 0, output: 0, reasoning: 0),
            cost: nil
        )

        XCTAssertEqual(
            self.measuredHeight(
                of: QuotaWindowUsageSection(snapshot: zeroWindows, today: zeroToday),
                width: Self.cardContentWidth
            ),
            0,
            "窗口全零 + 今行全零：额度分析/额度详情连标题一起消失，整块零高度"
        )
        XCTAssertGreaterThan(
            self.measuredHeight(
                of: QuotaWindowUsageSection(
                    snapshot: zeroWindows,
                    today: zeroToday,
                    resetCredits: Self.resetCredits(count: 2)
                ),
                width: Self.cardContentWidth
            ),
            0,
            "行全被跳过但重置卡可用：只剩重置卡模块（连同标题）"
        )
        XCTAssertGreaterThan(
            self.measuredHeight(
                of: QuotaWindowUsageSection(
                    snapshot: zeroWindows,
                    today: QuotaWindowUsageSection.Row(
                        label: ProviderCardView.todayRowLabel,
                        metrics: QuotaWindowUsageMetrics(input: 100, cachedInput: 900, output: 100, reasoning: 400),
                        cost: nil
                    )
                ),
                width: Self.cardContentWidth
            ),
            0,
            "今行有量时行集非空，两个模块随今行渲染"
        )
    }

    // MARK: - 两态共享骨架、宽度预算、持久化与宿主行为（合并改版）

    /// 「分析」与「用量」两态共用同一套 7 列 Grid 骨架与列宽预算，两态切换零回流。
    @MainActor
    func testTwoStatesShareSkeletonAndZeroReflow() {
        let now = Date()
        let snapshot = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "general", interval: true, weekly: true, now: now),
            providerKind: .minimaxTokenPlan,
            samples: [Self.sample(at: now.addingTimeInterval(-600), prompt: "p1", model: "minimax-m3")],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        let today = QuotaWindowUsageSection.Row(
            label: ProviderCardView.todayRowLabel,
            metrics: QuotaWindowUsageMetrics(input: 100, cachedInput: 900, output: 100, reasoning: 400),
            cost: ModelCostEstimate(value: 12.34, currency: .cny, pricedModelNames: ["a"], unpricedModelNames: [])
        )

        // 验证中间 4 列等宽常量
        XCTAssertEqual(QuotaWindowUsageSection.middleColumnWidth, 42)
        XCTAssertEqual(QuotaWindowUsageSection.valueColumnWidth, 58)
        XCTAssertEqual(QuotaWindowUsageSection.resetDateColumnWidth, 126)
        XCTAssertEqual(QuotaWindowUsageSection.resetDateColumnLeadingGap, 9)
        XCTAssertEqual(QuotaWindowUsageSection.horizontalSpacing, 8)

        // 验证两态下 visibleRows 相同
        let visibleRows = QuotaWindowUsageSection.visibleRows(snapshot: snapshot, today: today, offPeak: nil)
        XCTAssertEqual(visibleRows.count, 3)

        // 验证两态渲染高度与排版稳定性（在固定卡内容宽 420pt 下，两态高度必须完全一致）
        let analysisHeight = self.measuredHeight(
            of: QuotaWindowUsageSection(snapshot: snapshot, today: today, segmentOverride: .analysis),
            width: Self.cardContentWidth
        )
        let usageHeight = self.measuredHeight(
            of: QuotaWindowUsageSection(snapshot: snapshot, today: today, segmentOverride: .usage),
            width: Self.cardContentWidth
        )
        XCTAssertGreaterThan(analysisHeight, 0)
        XCTAssertEqual(analysisHeight, usageHeight, accuracy: 0.5, "两态共用同高度 Grid 骨架，切换零回流")
    }

    /// 420pt 卡内容宽的列宽预算 guardrail：
    /// 类型 natural (~20pt) + 4×42pt (168pt) + 58pt (价值) + 126pt (重置日期) + 6×8pt 间距 (48pt) = 420pt ≤ 420pt。
    @MainActor
    func testTotalWidthBudgetGuardrail() {
        let typeWidth = self.measuredWidth(of: Text("类型").font(MenuTypography.metricLabel))
        let middleColWidth = QuotaWindowUsageSection.middleColumnWidth
        let valueWidth = QuotaWindowUsageSection.valueColumnWidth
        let resetDateWidth = QuotaWindowUsageSection.resetDateColumnWidth
        let spacing = QuotaWindowUsageSection.horizontalSpacing

        let totalBudget = typeWidth + (middleColWidth * 4) + valueWidth + resetDateWidth + (spacing * 6)

        XCTAssertLessThanOrEqual(
            totalBudget,
            Self.cardContentWidth,
            "7 列总预算（\(totalBudget)pt）必须小于等于卡内容宽 420pt"
        )

        // 验证中间列 42pt 能装下两态所有单元格的最宽自然宽
        // 表头最宽：Cached (38pt)、Reason (37pt)；数值最宽：自适应比率 (40pt)、Token 紧凑计数 (39pt)
        let widestCachedHeader = self.measuredWidth(of: Text("Cached").font(MenuTypography.metricLabel))
        let widestReasonHeader = self.measuredWidth(of: Text("Reason").font(MenuTypography.metricLabel))
        let widestRate = self.measuredWidth(of: Text("100.0%").font(MenuTypography.metricValue))
        let widestToken = self.measuredWidth(of: Text("12.34M").font(MenuTypography.metricValue))
        let widestMiddleCell = max(widestCachedHeader, widestReasonHeader, widestRate, widestToken)
        XCTAssertLessThanOrEqual(
            widestMiddleCell,
            middleColWidth,
            "中间列宽度（\(middleColWidth)pt）必须容纳最宽自然宽单元格（\(widestMiddleCell)pt）"
        )
    }

    /// 中间 4 列宽度护栏：
    /// middleColumnWidth 必须严格大于所有 compact token 现实最宽形态（至少 +2pt 余量），
    /// 确保 1.22M、12.3M、99.9K、999K、999M、12.34M 全部不发生单行截断（lineLimit(1) 截尾）。
    @MainActor
    func testMiddleColumnsAccommodateCompactTokenRepresentations() {
        let middleColWidth = QuotaWindowUsageSection.middleColumnWidth
        let tokenCandidates = [
            "1.22M", "12.3M", "99.9K", "999K", "999M", "12.34M"
        ]
        var maxTokenWidth: CGFloat = 0
        for token in tokenCandidates {
            let width = self.measuredWidth(of: Text(token).font(MenuTypography.metricValue))
            maxTokenWidth = max(maxTokenWidth, width)
            XCTAssertLessThanOrEqual(
                width + 2,
                middleColWidth,
                "token 形态 \(token)（\(width)pt）必须比中间列宽 \(middleColWidth)pt 小至少 2pt 余量"
            )
        }
        XCTAssertGreaterThan(maxTokenWidth, 0)
        XCTAssertGreaterThanOrEqual(
            middleColWidth - maxTokenWidth, 2,
            "中间列宽（\(middleColWidth)pt）对最宽 token 形态（\(maxTokenWidth)pt）必须留有至少 2pt 余量"
        )
    }

    /// segment 持久化：默认 "analysis"，支持读写 "usage"。
    func testSegmentStoragePersistenceAndDefault() {
        let key = QuotaWindowUsageSection.segmentStorageKey
        XCTAssertEqual(key, "quotaWindowUsageSegment")

        let prev = UserDefaults.standard.string(forKey: key)
        defer {
            if let prev {
                UserDefaults.standard.set(prev, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        let resolvedDefault = QuotaWindowUsageSegment(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .analysis
        XCTAssertEqual(resolvedDefault, .analysis, "持久化默认值必须是 analysis")

        UserDefaults.standard.set(QuotaWindowUsageSegment.usage.rawValue, forKey: key)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "usage")

        UserDefaults.standard.set(QuotaWindowUsageSegment.analysis.rawValue, forKey: key)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "analysis")
    }

    /// dock popover 开启鼠标事件，菜单 strip hover 宿主注入 quotaWindowSegmentEditable: false 不渲染 segment 控件。
    @MainActor
    func testPopoverMouseEventsAndMenuHidesSegment() {
        // 1. dock popover 面板 ignoresMouseEvents == false
        let (popover, _) = EdgeDockController.shared.ensurePopoverPanel()
        XCTAssertFalse(popover.ignoresMouseEvents, "dock popover 必须开启鼠标事件（ignoresMouseEvents == false）")

        // 2. 环境默认值
        let defaultEditable = EnvironmentValues().quotaWindowSegmentEditable
        XCTAssertFalse(defaultEditable, "quotaWindowSegmentEditable 默认值必须为 false，保护菜单宿主")

        // 3. 菜单宿主 quotaWindowSegmentEditable == false 下不渲染 segment 控件
        let now = Date()
        let snapshot = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "general", interval: true, weekly: true, now: now),
            providerKind: .minimaxTokenPlan,
            samples: [Self.sample(at: now.addingTimeInterval(-600), prompt: "p1", model: "minimax-m3")],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        let viewWithoutSegment = QuotaWindowUsageSection(snapshot: snapshot)
            .environment(\.quotaWindowSegmentEditable, false)
        let viewWithSegment = QuotaWindowUsageSection(snapshot: snapshot)
            .environment(\.quotaWindowSegmentEditable, true)

        let h1 = self.measuredHeight(of: viewWithoutSegment, width: Self.cardContentWidth)
        let h2 = self.measuredHeight(of: viewWithSegment, width: Self.cardContentWidth)
        XCTAssertGreaterThan(h1, 0)
        XCTAssertGreaterThan(h2, 0)
    }

    /// 各态列显隐与全零规则判定：
    /// - 分析态：命中/思考按各自行合计是否为 0 判定
    /// - 用量态：Input/Cached/Output/Reason 按各自行合计是否为 0 判定
    /// - 类型、价值、重置日期恒在
    func testColumnVisibilityPerState() {
        let zero = QuotaWindowUsageMetrics(input: 0, cachedInput: 0, output: 0, reasoning: 0)
        let inputOnly = QuotaWindowUsageMetrics(input: 10, cachedInput: 0, output: 0, reasoning: 0)
        let outputOnly = QuotaWindowUsageMetrics(input: 0, cachedInput: 0, output: 10, reasoning: 0)

        // 分析态
        let statsVis1 = QuotaWindowUsageSection.statsColumnVisibility(rows: [zero, inputOnly])
        XCTAssertFalse(statsVis1.hit)
        XCTAssertFalse(statsVis1.think)

        let statsVis2 = QuotaWindowUsageSection.statsColumnVisibility(rows: [
            QuotaWindowUsageMetrics(input: 10, cachedInput: 20, output: 10, reasoning: 30)
        ])
        XCTAssertTrue(statsVis2.hit)
        XCTAssertTrue(statsVis2.think)

        // 用量态
        let rawVis1 = QuotaWindowUsageSection.numericColumnVisibility(rows: [inputOnly])
        XCTAssertTrue(rawVis1.input)
        XCTAssertFalse(rawVis1.cached)
        XCTAssertFalse(rawVis1.output)
        XCTAssertFalse(rawVis1.reason)

        let rawVis2 = QuotaWindowUsageSection.numericColumnVisibility(rows: [outputOnly])
        XCTAssertFalse(rawVis2.input)
        XCTAssertFalse(rawVis2.cached)
        XCTAssertTrue(rawVis2.output)
        XCTAssertFalse(rawVis2.reason)
    }

    /// 重置日期数据格**左对齐 + 前置间隙**（第五轮左对齐、第六轮加 12pt 间隙）：
    /// 固定宽列的数据格锚在"列首 + `resetDateColumnLeadingGap`"处，不仿数值列
    /// 锚右缘。渲染成位图找墨迹位置——墨迹应恰落在间隙之后（明显小于说明间隙
    /// 丢了，明显大于说明又锚去右缘了），判据留足余量防字体度量抖动。
    @MainActor
    func testResetDateColumnAlignsLeading() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let width = QuotaWindowUsageSection.resetDateColumnWidth
        let dateView = Text(QuotaWindowUsageSection.formatResetDateText(now.addingTimeInterval(3600), now: now))
            .font(MenuTypography.metricValue)
            .padding(.leading, QuotaWindowUsageSection.resetDateColumnLeadingGap)
            .frame(width: width, alignment: .leading)
        let hosting = NSHostingView(rootView: AnyView(dateView))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 100)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("拿不到位图缓存")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width

        // 前提自检：列右缘上方必须是空白（左对齐时数据最长形态之后还留有 ~23pt）。
        // 若整张位图都不透明，下面的墨迹判定会恒真——先在这里红掉。
        XCTAssertLessThan(
            rep.colorAt(x: rep.pixelsWide - 2, y: 1)?.alphaComponent ?? 1,
            0.1,
            "位图右缘应为透明背景；不透明说明渲染方式变了，墨迹判定失效"
        )

        // 重置日期列固定宽：
        let columnStart: CGFloat = 0
        var minInkX: CGFloat?
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.1 {
                minInkX = CGFloat(x) / scale
                break
            }
            if minInkX != nil { break }
        }
        guard let minInkX else {
            return XCTFail("重置日期列里必须真的画出了内容")
        }
        // 第六轮起内容带前置间隙：墨迹应锚在"列首 + 间隙"处。
        let gap = QuotaWindowUsageSection.resetDateColumnLeadingGap
        XCTAssertGreaterThanOrEqual(
            minInkX - columnStart, gap - 2,
            "重置日期内容与列首之间必须保住 \(Int(gap))pt 前置间隙，现在距列左缘 \(minInkX - columnStart)pt"
        )
        XCTAssertLessThan(
            minInkX - columnStart, gap + 6,
            "重置日期内容必须锚在列首 + 间隙处（左对齐），现在距列左缘 \(minInkX - columnStart)pt"
        )
    }

    // MARK: - 全零行跳过、全零列隐藏与今行（第四/五轮改版）

    /// 「额度分析」的「命中」「思考」列只在**没有任何可见行**产出对应桶时隐藏：
    /// 模块内跨行判定，不是单行判定——某一行的比率是 `—` 不足以藏掉一列。
    func testStatsColumnsHideOnlyWhenNoVisibleRowProducesTheBucket() {
        let zero = QuotaWindowUsageMetrics(input: 0, cachedInput: 0, output: 0, reasoning: 0)
        let cachedOnly = QuotaWindowUsageMetrics(input: 1, cachedInput: 9, output: 1, reasoning: 0)
        let reasoningOnly = QuotaWindowUsageMetrics(input: 1, cachedInput: 0, output: 1, reasoning: 2)

        let allZero = QuotaWindowUsageSection.statsColumnVisibility(rows: [zero, zero])
        XCTAssertFalse(allZero.hit, "所有行的 cached 合计为 0 → 命中列整列隐藏")
        XCTAssertFalse(allZero.think, "所有行的 reasoning 合计为 0 → 思考列整列隐藏")

        XCTAssertTrue(
            QuotaWindowUsageSection.statsColumnVisibility(rows: [zero, cachedOnly]).hit,
            "只要有一行产出 cached 就保住命中列（跨行判定，不是单行判定）"
        )
        XCTAssertTrue(
            QuotaWindowUsageSection.statsColumnVisibility(rows: [zero, reasoningOnly]).think,
            "只要有一行产出 reasoning 就保住思考列"
        )
        XCTAssertFalse(
            QuotaWindowUsageSection.statsColumnVisibility(rows: [zero, cachedOnly]).think,
            "cached 不救思考列：两列各判各的"
        )
    }

    /// 行本体照办宿主给的列显隐：两列全关的行必须真的更窄（整列消失，不只是
    /// 比率显示成 `—`）。宿主形态同上：行本体是 `GridRow`，要住进 `Grid` 再量。
    @MainActor
    func testStatsColumnFlagsCollapseTheWholeColumn() {
        let allMetrics = QuotaWindowUsageMetrics(input: 1_000, cachedInput: 1_000, output: 1_000, reasoning: 1_000)
        let collapsedMetrics = QuotaWindowUsageMetrics(input: 1_000, cachedInput: 0, output: 1_000, reasoning: 0)
        let cost = ModelCostEstimate(value: 12.34, currency: .cny, pricedModelNames: ["a"], unpricedModelNames: [])

        func section(metrics: QuotaWindowUsageMetrics) -> QuotaWindowUsageSection {
            let snapshot = QuotaWindowUsageSnapshot(
                interval: QuotaWindowUsageSnapshot.Window(
                    label: "5h",
                    usage: UsageMetricSummary(
                        prompts: 1,
                        rounds: 1,
                        inputTokens: metrics.input + metrics.cachedInput,
                        cachedInputTokens: metrics.cachedInput,
                        outputTokens: metrics.output,
                        reasoningOutputTokens: metrics.reasoning
                    ),
                    resetsAt: nil,
                    cost: cost
                ),
                weekly: nil,
                poolCount: 1
            )
            return QuotaWindowUsageSection(snapshot: snapshot, segmentOverride: .analysis)
        }

        let allShown = self.measuredWidth(of: section(metrics: allMetrics))
        let collapsed = self.measuredWidth(of: section(metrics: collapsedMetrics))

        XCTAssertGreaterThan(allShown, 0, "前提不成立：行必须真的排得出来")
        XCTAssertGreaterThan(allShown, collapsed + 5, "命中/思考两列关掉后必须真的更窄（整列消失）")
    }

    /// 「额度窗口」用量态四个数值列在**所有可见行**合计为 0 时整列隐藏——**含表头**；
    /// 且全零行本身整行跳过（第五轮改版），所以全零快照的表格整块不渲染。桶非零时列原样保留。
    @MainActor
    func testRawTableHidesAllZeroNumericColumnsWithTheirHeaders() {
        let now = Date()
        let zero = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "deepseek_balance", interval: true, weekly: true, now: now),
            providerKind: .deepseek,
            samples: [],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        let full = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "deepseek_balance", interval: true, weekly: true, now: now),
            providerKind: .deepseek,
            // 四桶都非零的样本（共用 helper 的 cached > input 会让未缓存 input 钳成 0）。
            samples: [LocalTokenUsageSample(
                completedAt: now.addingTimeInterval(-600),
                modelName: "deepseek-chat",
                promptID: "p",
                inputTokens: 10_000,
                cachedInputTokens: 9_000,
                outputTokens: 1_000,
                reasoningOutputTokens: 2_000,
                sourceProviderID: nil
            )],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        let hidden = Self.numericVisibility(of: zero)
        XCTAssertFalse(
            hidden.input || hidden.cached || hidden.output || hidden.reason,
            "前提不成立：空样本快照四桶应全零"
        )
        let kept = Self.numericVisibility(of: full)
        XCTAssertTrue(kept.input && kept.cached && kept.output && kept.reason, "前提不成立：有样本的快照四桶应都非零")

        // 全零行已整行跳过：全零快照整块隐藏（宽度为 0）
        let hiddenTableWidth = self.measuredWidth(of: QuotaWindowUsageSection(snapshot: zero, segmentOverride: .usage))
        let fullTableWidth = self.measuredWidth(of: QuotaWindowUsageSection(snapshot: full, segmentOverride: .usage))

        XCTAssertEqual(hiddenTableWidth, 0, "全零时行全被跳过，整块模块隐藏")
        XCTAssertGreaterThan(
            fullTableWidth, 100,
            "桶非零时四列原样保留（表格必须比全零态更宽）"
        )
    }

    /// 「今」行进表（排在 5h/周 之后，重置日期格 `—`），并且**参与全零列判定**：
    /// 窗口全零（那些行被跳过）+ 今有 cached 时，Cached 列要因今而被保住。
    @MainActor
    func testTodayRowEntersTheRawTableAndJoinsTheColumnVisibility() {
        let now = Date()
        let zero = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "deepseek_balance", interval: true, weekly: true, now: now),
            providerKind: .deepseek,
            samples: [],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        let today = QuotaWindowUsageSection.Row(
            label: ProviderCardView.todayRowLabel,
            metrics: QuotaWindowUsageMetrics(input: 0, cachedInput: 9_000, output: 0, reasoning: 0),
            cost: nil
        )
        XCTAssertTrue(
            Self.numericVisibility(of: zero, today: today).cached,
            "前提不成立：今行有 cached 时 Cached 列应保留"
        )
        XCTAssertEqual(
            QuotaWindowUsageSection.visibleRows(snapshot: zero, today: today, offPeak: nil).map(\.label),
            [ProviderCardView.todayRowLabel],
            "前提不成立：窗口行全零被跳过，表里应只剩今行"
        )

        let withoutToday = QuotaWindowUsageSection(snapshot: zero, segmentOverride: .usage)
        let withToday = QuotaWindowUsageSection(snapshot: zero, today: today, segmentOverride: .usage)

        XCTAssertGreaterThan(
            self.measuredHeight(of: withToday, width: Self.cardContentWidth),
            self.measuredHeight(of: withoutToday, width: Self.cardContentWidth),
            "今行必须真的多出一行（进表）"
        )
        XCTAssertGreaterThan(
            self.measuredWidth(of: withToday), self.measuredWidth(of: withoutToday) + 8,
            "今有 cached 时 Cached 列要保住：今行参与全零列判定，不是只多一行"
        )
    }

    // MARK: - 「闲」行（原独立闲时脚注并入表格）

    /// 行序固定 5h → 周 → 今 → 闲；全零的闲行整行跳过（与今行同一机制）；
    /// 闲行的重置日期格强制 `—`（闲时不占积分余额，没有"重置"一说）；
    /// 并参与 `hasVisibleContent` 的整块显隐判定。
    func testVisibleRowOrderPutsOffPeakAfterTodayAndSkipsItsAllZeroRow() {
        let now = Date()
        let snapshot = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "glm_coding_plan", interval: true, weekly: true, now: now),
            providerKind: .glmCodingPlan,
            samples: [Self.sample(at: now.addingTimeInterval(-600), prompt: "p1", model: "glm-4.6")],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        func row(_ label: String, metrics: QuotaWindowUsageMetrics) -> QuotaWindowUsageSection.Row {
            QuotaWindowUsageSection.Row(label: label, metrics: metrics, cost: nil)
        }
        let today = row(
            ProviderCardView.todayRowLabel,
            metrics: QuotaWindowUsageMetrics(input: 10, cachedInput: 0, output: 5, reasoning: 0)
        )
        let offPeak = row(
            QuotaWindowUsageSection.offPeakRowLabel,
            metrics: QuotaWindowUsageMetrics(input: 20, cachedInput: 0, output: 5, reasoning: 0)
        )
        let zeroOffPeak = row(
            QuotaWindowUsageSection.offPeakRowLabel,
            metrics: QuotaWindowUsageMetrics(input: 0, cachedInput: 0, output: 0, reasoning: 0)
        )

        XCTAssertEqual(
            QuotaWindowUsageSection.visibleRows(snapshot: snapshot, today: today, offPeak: offPeak).map(\.label),
            ["5h", "周", ProviderCardView.todayRowLabel, QuotaWindowUsageSection.offPeakRowLabel],
            "行序固定 5h → 周 → 今 → 闲"
        )
        XCTAssertNil(
            QuotaWindowUsageSection.visibleRows(snapshot: snapshot, today: today, offPeak: offPeak).last?.resetsAt,
            "闲行重置日期格强制 nil（渲染 —），与今行同一机制"
        )
        XCTAssertEqual(
            QuotaWindowUsageSection.visibleRows(snapshot: snapshot, today: today, offPeak: zeroOffPeak).map(\.label),
            ["5h", "周", ProviderCardView.todayRowLabel],
            "全零闲行整行跳过"
        )

        // 整块显隐判定：闲行有量时区块可见；全零闲行不能独自点亮区块。
        let empty = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "deepseek_balance", interval: false, weekly: false, now: now),
            providerKind: .deepseek,
            samples: [],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        XCTAssertTrue(
            QuotaWindowUsageSection.hasVisibleContent(snapshot: empty, today: nil, offPeak: offPeak, resetCredits: nil),
            "闲行有量时区块可见"
        )
        XCTAssertFalse(
            QuotaWindowUsageSection.hasVisibleContent(snapshot: empty, today: nil, offPeak: zeroOffPeak, resetCredits: nil),
            "全零闲行不能独自点亮区块"
        )
    }

    /// 「闲」行文案钉在这里：行标签与类型格 hover 说明句（原独立闲时脚注的说明句，
    /// 逐字保留，挂在类型格上——产出比格有自己的 `.help`，不能互相打架）。
    /// 改文案必须连测试一起改。
    func testOffPeakRowCopyIsPinned() {
        XCTAssertEqual(
            QuotaWindowUsageSection.offPeakRowLabel, "闲",
            "行标签与「5h」「周」「今」同一长度档"
        )
        XCTAssertEqual(
            QuotaWindowUsageSection.offPeakRowHelp,
            "ZCode 闲时任务真实消耗；不影响 5h / 周积分余额"
        )
    }

    /// 重置日期列固定宽常量里**刨去前置间隙**的文字空间必须 ≥ 最长形态的自然宽
    /// （`MM-dd HH:mm (23h59m)`，`formatResetSuffix` 最宽的后缀——比 `2d23h`/
    /// `已过期`/`365d` 都宽），也别宽得离谱（×1.2 的本意）。第七轮起常量含
    /// 9pt 前置间隙（126 − 9 = 117pt 零冗余），口径为「常量 − 间隙」。系统字体度量变了先红
    /// 在这里。
    @MainActor
    func testResetDateColumnWidthCoversTheLongestForm() {
        let longest = self.measuredWidth(
            of: Text("09-30 15:07 (23h59m)").font(MenuTypography.metricValue)
        )
        let textSpace = QuotaWindowUsageSection.resetDateColumnWidth
            - QuotaWindowUsageSection.resetDateColumnLeadingGap
        XCTAssertGreaterThan(longest, 0, "前提不成立：最长形态必须真的排得出来")
        XCTAssertGreaterThanOrEqual(
            textSpace, longest,
            "固定宽常量刨去前置间隙（\(textSpace)pt）容不下最长形态自然宽（\(longest)pt）"
        )
        XCTAssertLessThan(
            textSpace, longest * 1.5,
            "文字空间应约为最长形态自然宽 × 1.2：宽出 50% 说明量法或倍率写错了"
        )
    }

    // MARK: - 重置卡逐张明细的可达性

    /// 重置卡模块是**常驻**的：折叠行（重置卡数量：N + 最近到期）下面直接接逐张
    /// 清单，N 张可用 = N + 1 行；0 张（或没有数据）整块不画。曾经逐张明细挂在
    /// `HoverInfoRow` 的展开态上，而两个宿主都不吃鼠标事件——折叠态等于不存在。
    ///
    /// 断言方式是量高度：条数越多高度越高，且比"没有重置数据"高得多。
    @MainActor
    func testResetCreditsModuleRendersThePerCardListInline() {
        let snapshot = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "deepseek_balance", interval: false, weekly: false, now: Date()),
            providerKind: .deepseek,
            samples: [],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        XCTAssertTrue(snapshot.isEmpty, "前提不成立：这里用的是没有额度窗口的快照")

        let withCredits = self.measuredHeight(
            of: QuotaWindowUsageSection(snapshot: snapshot, resetCredits: Self.resetCredits(count: 3)),
            width: Self.cardContentWidth
        )
        let withMoreCredits = self.measuredHeight(
            of: QuotaWindowUsageSection(snapshot: snapshot, resetCredits: Self.resetCredits(count: 6)),
            width: Self.cardContentWidth
        )
        let withoutCredits = self.measuredHeight(
            of: QuotaWindowUsageSection(snapshot: snapshot),
            width: Self.cardContentWidth
        )

        XCTAssertEqual(withoutCredits, 0, "没有窗口也没有重置卡时整块不渲染")
        XCTAssertGreaterThan(
            withCredits, withoutCredits,
            "有重置卡就必须渲染出折叠行 + 逐张清单（否则明细不可达）"
        )
        XCTAssertGreaterThan(
            withMoreCredits, withCredits,
            "明细是**逐张**列的：多三张卡必须多出三行，固定高度说明画的是总数不是清单"
        )
    }

    /// 0 张可用 → 整个模块不显示（产品规则），哪怕 entries 非空。
    @MainActor
    func testResetCreditsModuleHidesWhenNothingIsAvailable() {
        let snapshot = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "deepseek_balance", interval: false, weekly: false, now: Date()),
            providerKind: .deepseek,
            samples: [],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        let allUsed = ResetCreditsInfo(
            entries: [
                Self.credit(id: "used", status: "used", expiresAt: nil)
            ],
            serverAvailableCount: 0,
            totalEarnedCount: 1
        )
        let height = self.measuredHeight(
            of: QuotaWindowUsageSection(snapshot: snapshot, resetCredits: allUsed),
            width: Self.cardContentWidth
        )
        XCTAssertEqual(height, 0, "0 张可用重置卡时整个模块不显示，不能只剩一句『重置卡数量：0』")
    }

    /// 清单只列 `available`，按到期日升序；两个消费面（重置卡 hover 展开态、
    /// 常驻模块）走的是同一个 `ResetCreditsDetailList.availableEntries(in:)`。
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

    // MARK: - 账号行的可见性（段1 Account Info）

    /// 账号行可见性的**唯一判定来源**是 `QuotaWindowAccountInfo.make`：
    /// 有真实账号名或真实级别其一即显示（有啥显示啥），两者皆无整行不画。
    ///
    /// - codexChatGPT / antigravity：邮箱 + 套餐（antigravity 沿用 pill 的前缀剥离）。
    /// - glmCodingPlan：API Key 没有邮箱，但 `planLabel` 是套餐档位 → **仅等级也显示**。
    /// - deepseek：`planLabel` 是余额串（`¥xx.xx`），不是账号级别 → 视为不可得，
    ///   传了余额也返回 nil（余额由 `DeepseekBalanceRow` 展示，不在这里重复）。
    /// - minimaxTokenPlan：两者皆不可得。
    func testAccountVisibilityRulesPerProvider() {
        let codex = QuotaWindowAccountInfo.make(
            providerKind: .codexChatGpt,
            accountEmail: "someone@example.com",
            planLabel: "Team"
        )
        XCTAssertEqual(codex?.accountEmail, "someone@example.com")
        XCTAssertEqual(codex?.planLabel, "Team")

        // antigravity 沿用 pill 文案的前缀剥离（与它曾经住在 header 里那颗一致）。
        let antigravity = QuotaWindowAccountInfo.make(
            providerKind: .antigravity,
            accountEmail: "someone@example.com",
            planLabel: "Google AI Pro"
        )
        XCTAssertEqual(antigravity?.planLabel, "AI Pro")

        // GLM：仅等级也显示，邮箱位保持空。
        let glm = QuotaWindowAccountInfo.make(
            providerKind: .glmCodingPlan,
            accountEmail: nil,
            planLabel: "Pro"
        )
        XCTAssertNotNil(glm, "glmCodingPlan 有套餐档位，仅等级也要显示账号行")
        XCTAssertNil(glm?.accountEmail)
        XCTAssertEqual(glm?.planLabel, "Pro")

        // GLM 连等级都没有 → 整行不画。
        XCTAssertNil(
            QuotaWindowAccountInfo.make(providerKind: .glmCodingPlan, accountEmail: nil, planLabel: nil)
        )

        // DeepSeek 的 planLabel 是余额，不算级别；minimax 两者皆 nil。
        XCTAssertNil(
            QuotaWindowAccountInfo.make(providerKind: .deepseek, accountEmail: nil, planLabel: "¥12.34"),
            "余额串不能被当成账号级别画进账号行"
        )
        XCTAssertNil(
            QuotaWindowAccountInfo.make(providerKind: .minimaxTokenPlan, accountEmail: nil, planLabel: nil)
        )

        // 有啥显示啥：codex 只有其一也显示。
        XCTAssertNotNil(
            QuotaWindowAccountInfo.make(providerKind: .codexChatGpt, accountEmail: "a@b.c", planLabel: nil)
        )
        XCTAssertNotNil(
            QuotaWindowAccountInfo.make(providerKind: .codexChatGpt, accountEmail: nil, planLabel: "Team")
        )

        // 空串 / 纯空白按不可得处理（首次刷新前的空字段不该把整行"点亮"）。
        XCTAssertNil(
            QuotaWindowAccountInfo.make(providerKind: .codexChatGpt, accountEmail: "  ", planLabel: "")
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

    /// 理想宽度：不限宽时视图自己的自然宽。给「三行共用同一 Grid」的对齐判据用。
    @MainActor
    private func measuredWidth<V: View>(of view: V) -> CGFloat {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = CGRect(x: 0, y: 0, width: 10_000, height: 100)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.width
    }

    /// 复刻「额度窗口」分析态的宿主形态：单行住进统一 Grid，字号与单行约束由 Grid 施加。
    @MainActor
    private static func statsGrid(fixture: RowFixture) -> some View {
        let snapshot = QuotaWindowUsageSnapshot(
            interval: QuotaWindowUsageSnapshot.Window(
                label: fixture.label,
                usage: UsageMetricSummary(
                    prompts: 1,
                    rounds: 1,
                    inputTokens: fixture.metrics.input + fixture.metrics.cachedInput,
                    cachedInputTokens: fixture.metrics.cachedInput,
                    outputTokens: fixture.metrics.output,
                    reasoningOutputTokens: fixture.metrics.reasoning
                ),
                resetsAt: nil,
                cost: fixture.cost
            ),
            weekly: nil,
            poolCount: 1
        )
        return QuotaWindowUsageSection(snapshot: snapshot, segmentOverride: .analysis)
    }

    @MainActor
    private static func statsGrid(named name: String) -> some View {
        Self.statsGrid(fixture: Self.row(named: name))
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

    /// 快照（+今行/闲行）的四数值列显隐——给上面的显隐断言当取数口：与视图同一份
    /// `visibleRows`（全零行跳过后）→ `numericColumnVisibility` 链路，测的才是
    /// 表格实际用的判定。
    private static func numericVisibility(
        of snapshot: QuotaWindowUsageSnapshot,
        today: QuotaWindowUsageSection.Row? = nil,
        offPeak: QuotaWindowUsageSection.Row? = nil
    ) -> (input: Bool, cached: Bool, output: Bool, reason: Bool) {
        let rows = QuotaWindowUsageSection.visibleRows(snapshot: snapshot, today: today, offPeak: offPeak)
        return QuotaWindowUsageSection.numericColumnVisibility(rows: rows.map(\.metrics))
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
