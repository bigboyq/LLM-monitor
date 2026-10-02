import XCTest
import SwiftUI
import AppKit
@testable import LLM_monitor

/// 「额度窗口用量」区块的**价值**那一格，以及重置卡明细的可达性。
///
/// 单独一个文件而不是并进 `QuotaWindowUsageTests`：这里测的是**可达性**性质
/// （金额有没有真的算、六列指标行会不会换行、列宽跨行对不对齐、模块标题有没有
/// 真的画出来、全零行跳过与模块联动、重置卡逐张明细能不能被看到），与那份文件
/// 里的「窗口口径/比率/时间构成条」是两批断言，混在一个文件里会互相淹没。
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

    /// 「额度分析」的一行六个格子（类型/用量/命中/产出比/思考/价值）在 336pt
    /// 卡片的内容宽（336 − 2×12 = 312pt）里必须**一行**。第三轮改版起行本体是
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
        let contentWidth = 336.0 - 2 * LayoutMetrics.cardContentPadding
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

    /// 五列共用同一 `Grid`：列宽**跨行对齐**（第三轮改版的 5 列铺满）。
    ///
    /// 判据来自布局语义：三行真的住在同一个 Grid 里时，每列宽 = 各行该列的最大
    /// 内容宽，Grid 总宽必然**大于**任一单行自己的总宽；若 `GridRow` 失去网格
    /// 语义（被当成普通 cell），Grid 退化成一列，总宽就**等于**最宽那一行的总宽。
    /// 让长内容错开在不同列——一行的长处在价值列（比率全是 `—`），另一行的长处
    /// 在比率列（价值是 `—`）——两种结构的理想宽度就分得开。
    @MainActor
    func testMetricRowsShareOneGridSoColumnsAlignAcrossRows() {
        // 比率全 `—`（四桶全 0），只有价值长。
        let longCost = RowFixture(
            label: "5h",
            metrics: QuotaWindowUsageMetrics(input: 0, cachedInput: 0, output: 0, reasoning: 0),
            cost: ModelCostEstimate(
                value: 1_234_567.89,
                currency: .cny,
                pricedModelNames: ["a"],
                unpricedModelNames: []
            )
        )
        // 价值是 `—`，三个比率都是宽形态（100.000% 一类）。
        let longRates = RowFixture(
            label: "周",
            metrics: QuotaWindowUsageMetrics(input: 1, cachedInput: 1, output: 1, reasoning: 1),
            cost: nil
        )

        let grid = Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 3) {
            Self.row(of: longCost)
            Self.row(of: longRates)
        }
        .font(MenuTypography.dataValue)
        .lineLimit(1)
        let gridWidth = self.measuredWidth(of: grid)
        let longCostWidth = self.measuredWidth(of: Self.statsGrid(fixture: longCost))
        let longRatesWidth = self.measuredWidth(of: Self.statsGrid(fixture: longRates))

        XCTAssertGreaterThan(longCostWidth, 0, "前提不成立：两行都得真的排得出来")
        XCTAssertGreaterThan(longRatesWidth, 0, "前提不成立：两行都得真的排得出来")
        XCTAssertGreaterThan(
            gridWidth, max(longCostWidth, longRatesWidth) + 1,
            "三行必须共用同一 Grid（列宽跨行对齐）：Grid 总宽应大于任一单行的总宽"
        )
    }

    /// 「额度分析」表头文案钉在这里（第五轮改版）：数据格不再带文字标签，列名
    /// 只在表头说一次；曾经的 `labels(compact:)` 紧凑降级随标签一起删除——固定
    /// 三字文案在最窄列也装得下（宽度核算见 `QuotaWindowUsageMetricRow` 文档），
    /// 表头层不再需要第二套写法。
    func testStatsHeaderCopyIsPinned() {
        XCTAssertEqual(QuotaWindowUsageSection.statsHeaders.type, "类型")
        XCTAssertEqual(QuotaWindowUsageSection.statsHeaders.usage, "用量")
        XCTAssertEqual(QuotaWindowUsageSection.statsHeaders.hit, "命中")
        XCTAssertEqual(QuotaWindowUsageSection.statsHeaders.outputInput, "产出比")
        XCTAssertEqual(QuotaWindowUsageSection.statsHeaders.think, "思考")
        XCTAssertEqual(QuotaWindowUsageSection.statsHeaders.value, "价值")
    }

    /// 表头行真的画出来，且随模块级列显隐整列消失（第五轮改版）：六列表头齐全时
    /// 比「命中/思考」两列表头关掉时更宽；固定文案在 312pt 卡片内容宽里单行
    /// 不折行（不做紧凑降级）。
    @MainActor
    func testStatsHeaderRowRendersAndCollapsesWithItsColumns() {
        func headerGrid(showsHit: Bool, showsThink: Bool) -> some View {
            Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 3) {
                QuotaWindowUsageStatsHeader(
                    showsHitColumn: showsHit,
                    showsThinkingColumn: showsThink
                )
            }
            .font(MenuTypography.dataValue)
            .lineLimit(1)
        }
        let allShown = self.measuredWidth(of: headerGrid(showsHit: true, showsThink: true))
        let collapsed = self.measuredWidth(of: headerGrid(showsHit: false, showsThink: false))
        let height = self.measuredHeight(of: headerGrid(showsHit: true, showsThink: true), width: 312)
        let unconstrained = self.measuredHeight(of: headerGrid(showsHit: true, showsThink: true), width: 1_000)

        XCTAssertGreaterThan(allShown, 0, "前提不成立：表头行必须真的排得出来")
        XCTAssertGreaterThan(allShown, collapsed + 5, "命中/思考两列表头关掉后必须真的更窄（表头随列一起消失）")
        XCTAssertEqual(height, unconstrained, accuracy: 0.5, "表头在 312pt 内容宽里必须单行不折行（固定文案不降级）")
    }

    /// 出/入比文案**固定 3 位小数**（`xx.xxx%`）：0 位小数会把 12.4% 与 11.6% 压成
    /// 同一个 "12%"，5h / 周 / 今三行并排时就失去可比性。固定（而非至多）3 位
    /// 还让这一段等宽。分母为 0（`nil`）仍是 `—`。
    func testOutputInputRateTextFormatsThreeDecimalPlaces() {
        XCTAssertEqual(QuotaWindowUsageMetricRow.outputInputRateText(0.12345), "12.345%")
        XCTAssertEqual(QuotaWindowUsageMetricRow.outputInputRateText(0.1), "10.000%", "不足 3 位补零，保持等宽")
        XCTAssertEqual(QuotaWindowUsageMetricRow.outputInputRateText(0), "0.000%")
        XCTAssertEqual(QuotaWindowUsageMetricRow.outputInputRateText(1), "100.000%")
        XCTAssertEqual(QuotaWindowUsageMetricRow.outputInputRateText(nil), "—")
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

        let bareRows = self.measuredHeight(
            of: Self.statsGrid(
                fixture: RowFixture(label: today.label, metrics: today.metrics, cost: today.cost)
            ),
            width: 312
        )
        let withTitle = self.measuredHeight(
            of: QuotaWindowUsageSection(snapshot: empty, today: today),
            width: 312
        )
        let withoutModules = self.measuredHeight(
            of: QuotaWindowUsageSection(snapshot: empty),
            width: 312
        )

        XCTAssertEqual(withoutModules, 0, "无数据时整块（连同所有模块标题）不渲染")
        XCTAssertGreaterThan(
            withTitle - bareRows, 5,
            "「额度分析」标题必须真的画出来（比裸指标行高出一行标题 + 间距的高度），现在是 \(withTitle - bareRows)pt"
        )
    }

    /// 标题文案钉在这里：三块模块标题 + 段2 段落标题 + 今行标签。改文案必须连
    /// 测试一起改，防止视图与文档各漂各的。
    func testTitleCopyIsPinned() {
        XCTAssertEqual(QuotaWindowUsageSection.statsTitle, "额度分析")
        XCTAssertEqual(QuotaWindowUsageSection.rawTableTitle, "额度详情")
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
            QuotaWindowUsageSection.visibleRows(snapshot: snapshot, today: today).map(\.label),
            ["周"],
            "全 0 的 5h 与今行整行跳过，「额度分析」只剩周行"
        )
        let table = QuotaWindowUsageRawTable(snapshot: snapshot, today: today)
        XCTAssertEqual(
            table.tableRows.map(\.label), ["周"],
            "「额度详情」同一规则：全 0 的 5h 与今行不进表"
        )
        // 列显隐基于过滤后的行集：周行有量，cached/output/reason 三列保留
        // （helper 的样本 cached > input，未缓存 input 桶钳成 0，Input 列隐藏）。
        let visibility = QuotaWindowUsageRawTable.numericColumnVisibility(rows: table.tableRows.map(\.metrics))
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
            QuotaWindowUsageSection.visibleRows(snapshot: empty, today: today).isEmpty,
            "无窗口且今行全零 → 过滤后没有剩余行"
        )
        XCTAssertTrue(QuotaWindowUsageRawTable(snapshot: empty, today: today).tableRows.isEmpty)
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
                width: 312
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
                width: 312
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
                width: 312
            ),
            0,
            "今行有量时行集非空，两个模块随今行渲染"
        )
    }

    /// 时间构成条只在**过滤后仍有窗口行**（5h/周）可见时画：只剩今行、或窗口
    /// 全零（行被跳过）只剩今行时，条都不画——全灰条没有信息量。
    @MainActor
    func testTimeShareBarOnlyDrawsWhenAWindowRowSurvivesFiltering() {
        let now = Date()
        // 周窗口有量、无 5h 窗口：stats = 标题 + 条 + 表头 + 周行。
        let weeklyOnly = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "general", interval: false, weekly: true, now: now),
            providerKind: .minimaxTokenPlan,
            samples: [Self.sample(at: now.addingTimeInterval(-600), prompt: "p1", model: "minimax-m3")],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        // 无窗口、今行有量：同构但少一条时间构成条。
        let noWindows = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "deepseek_balance", interval: false, weekly: false, now: now),
            providerKind: .deepseek,
            samples: [],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        // 窗口存在但全零、今行有量：与「无窗口 + 今行」同高——条也不画。
        let zeroWindows = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "deepseek_balance", interval: true, weekly: true, now: now),
            providerKind: .deepseek,
            samples: [],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        let today = QuotaWindowUsageSection.Row(
            label: ProviderCardView.todayRowLabel,
            metrics: QuotaWindowUsageMetrics(input: 100, cachedInput: 900, output: 100, reasoning: 400),
            cost: nil
        )

        let withBar = self.measuredHeight(of: QuotaWindowUsageSection(snapshot: weeklyOnly, today: today), width: 312)
        let withoutBar = self.measuredHeight(of: QuotaWindowUsageSection(snapshot: noWindows, today: today), width: 312)
        let zeroWindowsHeight = self.measuredHeight(of: QuotaWindowUsageSection(snapshot: zeroWindows, today: today), width: 312)

        XCTAssertGreaterThan(
            withBar, withoutBar + 5,
            "有可见窗口行时 stats 模块必须多出一条时间构成条"
        )
        XCTAssertEqual(
            zeroWindowsHeight, withoutBar, accuracy: 0.5,
            "窗口全零（行被跳过）时不画条——条需要的是可见窗口行，不是存在的窗口"
        )
    }

    /// 重置日期列**左对齐**（第五轮改版）：固定宽列（表头与数据格）锚在列首，
    /// 不再仿数值列锚右缘。渲染成位图找墨迹位置——左对齐时墨迹紧贴列左缘
    /// （旧态右对齐会距左缘约一个列宽减文本宽），判据留足余量防字体度量抖动。
    @MainActor
    func testResetDateColumnAlignsLeading() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let snapshot = LocalUsageSummaryBuilder.windowUsage(
            model: Self.model(name: "deepseek_balance", interval: true, weekly: false, now: now),
            providerKind: .deepseek,
            samples: [Self.sample(at: now.addingTimeInterval(-600), prompt: "p1", model: "deepseek-chat")],
            intervalLabel: "5h",
            weeklyLabel: "周"
        )
        let width: CGFloat = 420
        let hosting = NSHostingView(rootView: AnyView(QuotaWindowUsageRawTable(snapshot: snapshot).frame(width: width)))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 500)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("拿不到位图缓存")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width

        // 前提自检：列右缘上方必须是空白（左对齐时数据最长形态也留有 ~20pt）。
        // 若整张位图都不透明，下面的墨迹判定会恒真——先在这里红掉。
        XCTAssertLessThan(
            rep.colorAt(x: rep.pixelsWide - 2, y: 1)?.alphaComponent ?? 1,
            0.1,
            "位图右缘应为透明背景；不透明说明渲染方式变了，墨迹判定失效"
        )

        // 重置日期列固定宽且是最后一列：取最右 resetDateColumnWidth 的一条竖带。
        let columnStart = width - QuotaWindowUsageRawTable.resetDateColumnWidth
        var minInkX: CGFloat?
        for x in Int(columnStart * scale)..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.1 {
                minInkX = CGFloat(x) / scale
                break
            }
            if minInkX != nil { break }
        }
        guard let minInkX else {
            return XCTFail("重置日期列里必须真的画出了内容")
        }
        XCTAssertLessThan(
            minInkX - columnStart, 12,
            "重置日期内容必须锚在列首（左对齐），现在距列左缘 \(minInkX - columnStart)pt"
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
        let metrics = QuotaWindowUsageMetrics(input: 1_000, cachedInput: 0, output: 1_000, reasoning: 0)
        let cost = ModelCostEstimate(value: 12.34, currency: .cny, pricedModelNames: ["a"], unpricedModelNames: [])
        func grid(showsHit: Bool, showsThink: Bool) -> some View {
            Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 3) {
                QuotaWindowUsageMetricRow(
                    label: "5h",
                    metrics: metrics,
                    cost: cost,
                    showsHitColumn: showsHit,
                    showsThinkingColumn: showsThink
                )
            }
            .font(MenuTypography.dataValue)
            .lineLimit(1)
        }
        let allShown = self.measuredWidth(of: grid(showsHit: true, showsThink: true))
        let collapsed = self.measuredWidth(of: grid(showsHit: false, showsThink: false))

        XCTAssertGreaterThan(allShown, 0, "前提不成立：行必须真的排得出来")
        XCTAssertGreaterThan(allShown, collapsed + 5, "命中/思考两列关掉后必须真的更窄（整列消失）")
    }

    /// 「额度详情」四个数值列在**所有可见行**合计为 0 时整列隐藏——**含表头**；
    /// 且全零行本身整行跳过（第五轮改版），所以全零快照的表格只剩标题 + 「类型 +
    /// 重置日期」两个表头，没有任何数值列表头。桶非零时列原样保留。
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

        // 全零行已整行跳过：剩下的宽度上界钉「没有任何数值列表头幸存」——
        // 类型表头自然宽 + 一个列距 + 重置日期固定宽，再多任何一个数值表头
        // 都要宽出 ~35pt。
        let typeHeaderWidth = self.measuredWidth(of: Text("类型").font(MenuTypography.metricLabel))
        let hiddenTableWidth = self.measuredWidth(of: QuotaWindowUsageRawTable(snapshot: zero))
        let fullTableWidth = self.measuredWidth(of: QuotaWindowUsageRawTable(snapshot: full))

        XCTAssertLessThanOrEqual(
            hiddenTableWidth,
            typeHeaderWidth + 4 + QuotaWindowUsageRawTable.resetDateColumnWidth + 8,
            "全零时行全被跳过，数值列表头必须一起消失，不能留一个孤零零的表头"
        )
        XCTAssertGreaterThan(
            fullTableWidth, hiddenTableWidth + 8,
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
            QuotaWindowUsageRawTable(snapshot: zero, today: today).tableRows.map(\.label),
            [ProviderCardView.todayRowLabel],
            "前提不成立：窗口行全零被跳过，表里应只剩今行"
        )

        let withoutToday = QuotaWindowUsageRawTable(snapshot: zero)
        let withToday = QuotaWindowUsageRawTable(snapshot: zero, today: today)

        XCTAssertGreaterThan(
            self.measuredHeight(of: withToday, width: 312),
            self.measuredHeight(of: withoutToday, width: 312),
            "今行必须真的多出一行（进表）"
        )
        XCTAssertGreaterThan(
            self.measuredWidth(of: withToday), self.measuredWidth(of: withoutToday) + 8,
            "今有 cached 时 Cached 列要保住：今行参与全零列判定，不是只多一行"
        )
    }

    /// 重置日期列的固定宽常量必须 ≥ 最长形态的自然宽（`MM-dd HH:mm (23h59m)`，
    /// `formatResetSuffix` 最宽的后缀——比 `2d23h`/`已过期`/`365d` 都宽），也别宽得
    /// 离谱（×1.2 的本意）。系统字体度量变了先红在这里。
    @MainActor
    func testResetDateColumnWidthCoversTheLongestForm() {
        let longest = self.measuredWidth(
            of: Text("09-30 15:07 (23h59m)").font(MenuTypography.metricValue)
        )
        XCTAssertGreaterThan(longest, 0, "前提不成立：最长形态必须真的排得出来")
        XCTAssertGreaterThanOrEqual(
            QuotaWindowUsageRawTable.resetDateColumnWidth, longest,
            "固定宽常量（\(QuotaWindowUsageRawTable.resetDateColumnWidth)pt）容不下最长形态自然宽（\(longest)pt）"
        )
        XCTAssertLessThan(
            QuotaWindowUsageRawTable.resetDateColumnWidth, longest * 1.5,
            "常量应约为最长形态自然宽 × 1.2：宽出 50% 说明量法或倍率写错了"
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
            width: 312
        )
        let withMoreCredits = self.measuredHeight(
            of: QuotaWindowUsageSection(snapshot: snapshot, resetCredits: Self.resetCredits(count: 6)),
            width: 312
        )
        let withoutCredits = self.measuredHeight(
            of: QuotaWindowUsageSection(snapshot: snapshot),
            width: 312
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
            width: 312
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

    /// 复刻 `QuotaWindowUsageSection.statsModule` 的宿主形态：行本体是 `GridRow`，
    /// 必须住进 `Grid`，字号与单行约束由 `Grid` 施加。
    @MainActor
    private static func statsGrid(fixture: RowFixture) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 3) {
            Self.row(of: fixture)
        }
        .font(MenuTypography.dataValue)
        .lineLimit(1)
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

    @MainActor
    private static func row(of fixture: RowFixture) -> QuotaWindowUsageMetricRow {
        QuotaWindowUsageMetricRow(
            label: fixture.label,
            metrics: fixture.metrics,
            cost: fixture.cost
        )
    }

    /// 快照（+今行）的四数值列显隐——给上面的显隐断言当取数口：与视图同一份
    /// `tableRows`（全零行跳过后）→ `numericColumnVisibility` 链路，测的才是
    /// 表格实际用的判定。
    private static func numericVisibility(
        of snapshot: QuotaWindowUsageSnapshot,
        today: QuotaWindowUsageSection.Row? = nil
    ) -> (input: Bool, cached: Bool, output: Bool, reason: Bool) {
        let table = QuotaWindowUsageRawTable(snapshot: snapshot, today: today)
        return QuotaWindowUsageRawTable.numericColumnVisibility(rows: table.tableRows.map(\.metrics))
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
