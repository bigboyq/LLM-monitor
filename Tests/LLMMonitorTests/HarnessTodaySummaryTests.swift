import XCTest
@testable import LLM_monitor

/// 状态栏下拉菜单的 Harness 视角数据通路：`HarnessTodaySummary.summarize`。
///
/// 这一层是**纯函数**（输入 `[ProviderStatus]` + `now`/`calendar`，不碰视图与
/// 共享状态），所以这里全部直接构造 status 值来驱动，不经 AppState——菜单读的
/// 就是同一份 `usageProjection`，中间没有第二条通路可以走样。
final class HarnessTodaySummaryTests: XCTestCase {

    private let calendar = Calendar.current

    /// 固定在"今天 12:00"，让样本的今天/昨天判定不随运行时刻漂移（凌晨跑测试
    /// 也不会把 12:00 判成明天）。
    private var now: Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private var today: Date { calendar.startOfDay(for: now) }
    private var yesterday: Date { calendar.date(byAdding: .day, value: -1, to: now) ?? now }

    // MARK: - 今日过滤

    /// 昨天（以及更早）的样本不进入"今天"这一屏。
    ///
    /// 扫描器的 `recentSamples` 刻意多留一天给额度窗口计算（见
    /// `ClientUsageAggregation.samplesInDisplayedWindow` 的注释），菜单直接吃
    /// 未过滤的样本时，昨天烧掉的 token 会混进今天的合计。
    func testOnlyTodaysSamplesAreSummarized() {
        let status = codexStatus(samples: [
            sample(model: "gpt-5.5", at: today, input: 1_000, cached: 0, output: 0),
            sample(model: "gpt-5.5", at: yesterday, input: 9_000_000, cached: 0, output: 0)
        ])

        let summary = HarnessTodaySummary.summarize(statuses: [status], now: now, calendar: calendar)

        XCTAssertEqual(summary.totalTokens, 1_000, "昨天的样本不得进入今日合计")
        XCTAssertEqual(summary.sections.count, 1)
        XCTAssertEqual(summary.sections[0].rows.count, 1)
        XCTAssertEqual(summary.sections[0].rows[0].totalTokens, 1_000)
    }

    /// `dayStart` 归一到自然日零点，段与全局共用同一个口径。
    func testDayStartIsNormalizedToStartOfDay() {
        let summary = HarnessTodaySummary.summarize(
            statuses: [codexStatus(samples: [sample(model: "gpt-5.5", at: now, input: 10)])],
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(summary.dayStart, today)
        XCTAssertEqual(summary.sections.first?.rows.first?.dayStart, today)
    }

    // MARK: - 三桶数学与命中率

    /// 三桶来自 `UnifiedTokenUsageAggregator.day`：`inputTokens` 是 cache-inclusive
    /// 的历史语义，先扣掉 cached 才得到 uncached input；reasoning 单独成桶，
    /// 计费时才并入 output（`billableOutput`）。
    func testBucketsSplitCacheInclusiveInputAndKeepReasoningSeparate() {
        // inputTokens 1,000,000 含 600,000 cached → uncached 400,000。
        let status = codexStatus(samples: [
            sample(model: "gpt-5.5", at: now, input: 1_000_000, cached: 600_000, output: 200_000, reasoning: 100_000)
        ])

        let row = try! XCTUnwrap(
            HarnessTodaySummary.summarize(statuses: [status], now: now, calendar: calendar)
                .sections.first?.rows.first
        )

        XCTAssertEqual(row.buckets, TokenUsageBuckets(input: 400_000, cacheRead: 600_000, output: 200_000, reasoning: 100_000))
        XCTAssertEqual(row.totalTokens, 1_300_000, "总量是四桶之和（含 reasoning）")
        XCTAssertEqual(row.buckets.billableOutput, 300_000, "计费口径把 reasoning 并入 output")
    }

    /// 命中率 = cacheRead / (input + cacheRead)，且汇总块与行同口径。
    func testCacheHitRateUsesUncachedInputPlusCacheRead() {
        let status = codexStatus(samples: [
            sample(model: "gpt-5.5", at: now, input: 1_000_000, cached: 600_000, output: 0)
        ])
        let summary = HarnessTodaySummary.summarize(statuses: [status], now: now, calendar: calendar)

        XCTAssertEqual(summary.cacheHitRate ?? 0, 0.6, accuracy: 1e-12)
        XCTAssertEqual(summary.sections[0].cacheHitRate ?? 0, 0.6, accuracy: 1e-12)
        XCTAssertEqual(summary.sections[0].rows[0].cacheHitRate ?? 0, 0.6, accuracy: 1e-12)
    }

    /// 全是 output 的行没有 input / cacheRead 分母：命中率是 nil（UI 显示「—」），
    /// 不能退化成 0%（"0% 命中"和"没得命中"是两件事）。
    func testHitRateIsNilWithoutInputOrCacheBuckets() {
        let status = codexStatus(samples: [
            sample(model: "gpt-5.5", at: now, input: 0, cached: 0, output: 5_000)
        ])
        let summary = HarnessTodaySummary.summarize(statuses: [status], now: now, calendar: calendar)

        XCTAssertNil(summary.cacheHitRate)
        XCTAssertNil(summary.sections[0].rows[0].cacheHitRate)
    }

    // MARK: - 跨币种段价值

    /// 一个客户端横跨两个 provider 分片时（OpenCode 的 openai 分片 + 智谱分片），
    /// 段价值必须折算成 CNY 总额并保留 USD 原额，而不是把 `11.30` 和 `33.00` 裸相加。
    func testSectionValueFoldsMixedCurrenciesIntoCNY() {
        let openAIStatus = opencodeStatus(
            kind: .codexChatGpt,
            providerID: OpencodeLocalUsage.openAIProviderID,
            samples: [sample(model: "gpt-5.5", at: now, input: 1_000_000, cached: 600_000, output: 200_000, reasoning: 100_000)]
        )
        let zhipuStatus = opencodeStatus(
            kind: .glmCodingPlan,
            providerID: OpencodeLocalUsage.glmProviderID,
            samples: [sample(model: "GLM-5.3", at: now, input: 1_000_000, cached: 500_000, output: 1_000_000, reasoning: 0)]
        )

        let summary = HarnessTodaySummary.summarize(
            statuses: [openAIStatus, zhipuStatus],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(summary.sections.count, 1, "两个分片属于同一个客户端，必须合成一段")
        let section = summary.sections[0]
        XCTAssertEqual(section.clientID, ClientID.openCode)
        XCTAssertEqual(section.rows.count, 2)
        // 行级保留各自原币种：$11.30（USD）/ ¥33.00（CNY）。
        let byCurrency = Dictionary(uniqueKeysWithValues: section.rows.map {
            ($0.costEstimate.currency, $0)
        })
        XCTAssertEqual(byCurrency[.usd]?.costText, "$11.30")
        XCTAssertEqual(byCurrency[.cny]?.costText, "¥33.00")
        // 段级：33 CNY + 11.3 USD × 7 = 112.1 CNY 总额，USD 原额保留在文案里。
        XCTAssertEqual(section.value.usdTotal, Decimal(string: "11.3"))
        XCTAssertEqual(section.value.cnyTotal, Decimal(33))
        XCTAssertEqual(section.value.cnyEquivalentTotal, Decimal(string: "112.1"))
        // 混合形态文案是「CNY 折算总额（含 USD 原额）」；精确字面量由
        // `MixedCurrencyEstimateTests` 守门，这里断言的是菜单拿到的是它而不是
        // 另一套数。USD 原额 11.3 × 7 = 79.1，加 CNY 33 = 112.1。
        XCTAssertEqual(section.valueText, "112.1（含$11.3）")
        XCTAssertEqual(summary.valueText, section.valueText, "全局汇总是各段金额的归集，不该是另一套数")
    }

    /// 纯单币种的客户端段走 `MixedCurrencyEstimate` 的定长两位小数形态。
    func testSingleCurrencySectionKeepsPlainAmountText() {
        let status = opencodeStatus(
            kind: .codexChatGpt,
            providerID: OpencodeLocalUsage.openAIProviderID,
            samples: [sample(model: "gpt-5.5", at: now, input: 1_000_000, cached: 0, output: 0)]
        )
        let summary = HarnessTodaySummary.summarize(statuses: [status], now: now, calendar: calendar)
        XCTAssertEqual(summary.valueText, "$5.00")
    }

    // MARK: - 行价值与 DeepSeek 峰时倍率

    /// DeepSeek 行的价值要带上高峰 2× 倍率，且倍率由**该行来源 status** 携带的
    /// 窗口决定。同一批样本在"默认高峰窗口"和"从不高峰"两张卡上必须是两倍关系
    /// ——少了这条，行价值会在非高峰时段被算成高峰价。
    ///
    /// 时刻固定成**北京时间的周一 10:00**（DeepSeek 高峰按北京时间判定，见
    /// `ModelPricingCatalog.pricingMultiplier`），并用同一个北京日历定义"今天"，
    /// 这样这条断言不随运行机器的时区变化。
    func testDeepSeekRowValueAppliesPeakWindowMultiplier() throws {
        let beijing = PeakWindow.beijingCalendar
        let weekdayMorning = try XCTUnwrap(
            beijing.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 10))
        )
        XCTAssertTrue(
            (2...6).contains(beijing.component(.weekday, from: weekdayMorning)),
            "前提不成立：样本必须落在工作日，否则高峰窗口按 weekendsOnly 直接跳过"
        )

        let peak = deepseekStatus(window: .deepseekDefault, at: weekdayMorning)
        let flat = deepseekStatus(
            window: PeakWindow(slots: [], weekdaysOnly: false),
            at: weekdayMorning
        )

        let peakRow = try XCTUnwrap(
            HarnessTodaySummary.summarize(statuses: [peak], now: weekdayMorning, calendar: beijing)
                .sections.first?.rows.first
        )
        let flatRow = try XCTUnwrap(
            HarnessTodaySummary.summarize(statuses: [flat], now: weekdayMorning, calendar: beijing)
                .sections.first?.rows.first
        )

        // deepseek-chat 命中 DeepSeek Flash（¥1 / 1M uncached input，谷价）。
        XCTAssertEqual(flatRow.costText, "¥1.00")
        XCTAssertEqual(peakRow.costText, "¥2.00", "高峰时段按 2× 计价")
        XCTAssertEqual(peakRow.totalTokens, flatRow.totalTokens, "倍率只影响价值，不影响 token")
    }

    /// 行级价值是**单 provider 单币种**的原额。未定价模型行显示「未定价」，
    /// 不进金额归集（`MixedCurrencyEstimate` 只累加有 value/currency 的 estimate）。
    func testUnpricedModelRowSaysUnpricedAndDoesNotInflateSectionValue() {
        let priced = opencodeStatus(
            kind: .codexChatGpt,
            providerID: OpencodeLocalUsage.openAIProviderID,
            samples: [sample(model: "gpt-5.5", at: now, input: 1_000_000, cached: 0, output: 0)]
        )
        let unknown = opencodeStatus(
            kind: .codexChatGpt,
            providerID: OpencodeLocalUsage.openAIProviderID,
            samples: [sample(model: "some-unlisted-model", at: now, input: 5_000_000, cached: 0, output: 0)]
        )

        let section = try! XCTUnwrap(
            HarnessTodaySummary.summarize(statuses: [priced, unknown], now: now, calendar: calendar)
                .sections.first
        )
        let byName = Dictionary(uniqueKeysWithValues: section.rows.map { ($0.displayName, $0) })
        XCTAssertEqual(byName["some-unlisted-model"]?.costText, "未定价")
        XCTAssertEqual(section.valueText, "$5.00", "未定价行不得折出金额")
    }

    /// 模型名缺失（nil / 纯空白）的样本归一到同一行「模型名缺失」，不会因为
    /// `nil` 与 `""` 是两个 key 而在同一段里出现两行。
    func testMissingModelNameCollapsesIntoOneRow() {
        let status = codexStatus(samples: [
            sample(model: nil, at: now, input: 1_000, cached: 0, output: 0, promptID: "a"),
            sample(model: "   ", at: now, input: 2_000, cached: 0, output: 0, promptID: "b")
        ])

        let rows = HarnessTodaySummary.summarize(statuses: [status], now: now, calendar: calendar)
            .sections[0].rows

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].displayName, HarnessTodaySummary.missingModelNameText)
        XCTAssertEqual(rows[0].totalTokens, 3_000)
        XCTAssertNil(rows[0].modelName)
    }

    // MARK: - 空贡献跳过

    /// 三种"没有今日活动"都不该产生段：完全没样本的 provider、只有昨天的样本、
    /// 贡献本身无任何活动（`hasActivity` 为 false，与设置页同一口径）。
    func testContributionsWithoutTodayActivityProduceNoSections() {
        let empty = codexStatus(samples: [])
        let onlyYesterday = codexStatus(samples: [
            sample(model: "gpt-5.5", at: yesterday, input: 1_000, cached: 0, output: 0)
        ])

        XCTAssertTrue(
            HarnessTodaySummary.summarize(statuses: [empty], now: now, calendar: calendar).isEmpty,
            "没有样本的 provider 不该造出空段"
        )
        XCTAssertTrue(
            HarnessTodaySummary.summarize(statuses: [onlyYesterday], now: now, calendar: calendar).isEmpty,
            "只有昨天活动的客户端整段隐藏"
        )
        XCTAssertTrue(
            HarnessTodaySummary.summarize(statuses: [], now: now, calendar: calendar).isEmpty
        )
    }

    /// 没有今日活动时汇总块仍然是合法零值（而不是崩或 NaN）——菜单要照常渲染
    /// "今天合计 0 / 命中 — / ¥0.00"，段列表另走空态。
    func testEmptySummaryStillHasZeroedTotals() {
        let summary = HarnessTodaySummary.summarize(statuses: [], now: now, calendar: calendar)
        XCTAssertEqual(summary.totalTokens, 0)
        XCTAssertNil(summary.cacheHitRate)
        XCTAssertTrue(summary.value.isEmpty)
        XCTAssertEqual(summary.valueText, "¥0.00")
    }

    // MARK: - 排序

    /// 段按今日 token 降序；同段内行也按今日 token 降序，同量时「模型名缺失」沉底。
    func testSectionsAndRowsAreOrderedByTodayTokensDescending() {
        let small = codexStatus(samples: [sample(model: "gpt-5.5", at: now, input: 1_000)])
        let big = opencodeStatus(
            kind: .glmCodingPlan,
            providerID: OpencodeLocalUsage.glmProviderID,
            samples: [
                sample(model: "GLM-5.3", at: now, input: 90_000, cached: 0, output: 0, promptID: "big-1"),
                sample(model: "GLM-5.2", at: now, input: 40_000, cached: 0, output: 0, promptID: "big-2")
            ]
        )

        let summary = HarnessTodaySummary.summarize(statuses: [small, big], now: now, calendar: calendar)

        XCTAssertEqual(summary.sections.map(\.clientID), [ClientID.openCode, ClientID.codex])
        XCTAssertEqual(summary.sections[0].displayName, "OpenCode", "段名取 ClientDescriptor 的注册名")
        XCTAssertEqual(summary.sections[0].rows.map(\.displayName), ["GLM-5.3", "GLM-5.2"])
        XCTAssertEqual(summary.sections[0].totalTokens, 130_000, "段小计是段内各行之和")
    }

    /// 同一个客户端在两张卡上命中同一个行键时合并成一行（而不是同一段出现两行）。
    func testSameRowKeyAcrossStatusesMergesIntoOneRow() {
        let a = opencodeStatus(
            kind: .codexChatGpt,
            providerID: OpencodeLocalUsage.openAIProviderID,
            samples: [sample(model: "gpt-5.5", at: now, input: 1_000, cached: 0, output: 0, promptID: "x")]
        )
        let b = opencodeStatus(
            kind: .codexChatGpt,
            providerID: OpencodeLocalUsage.openAIProviderID,
            samples: [sample(model: "gpt-5.5", at: now, input: 2_000, cached: 0, output: 0, promptID: "y")]
        )

        let rows = HarnessTodaySummary.summarize(statuses: [a, b], now: now, calendar: calendar)
            .sections[0].rows

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].totalTokens, 3_000)
    }

    // MARK: - 饱和加法

    /// 三桶同时 `Int.max` 时段小计 / 总量饱和封顶而不是翻负（`TokenBucketBar`
    /// 的占比把负桶按 0 处理，两者叠加不能产出负宽度）。
    func testSaturatedBucketsDoNotOverflowIntoNegativeTotals() {
        let huge = codexStatus(samples: [
            sample(model: "gpt-5.5", at: now, input: Int.max, cached: 0, output: Int.max, reasoning: Int.max)
        ])
        let summary = HarnessTodaySummary.summarize(statuses: [huge], now: now, calendar: calendar)

        XCTAssertEqual(summary.totalTokens, Int.max)
        XCTAssertEqual(summary.sections[0].totalTokens, Int.max)
        XCTAssertGreaterThanOrEqual(summary.sections[0].rows[0].buckets.billableOutput, 0)
    }

    // MARK: - fixtures

    private func sample(
        model: String?,
        at date: Date,
        input: Int,
        cached: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        promptID: String = "p1"
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: date,
            modelName: model,
            promptID: promptID,
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningOutputTokens: reasoning
        )
    }

    /// ChatGPT / Codex 卡：`codexUsageDetails.recentSamples` 走原生贡献。
    private func codexStatus(samples: [LocalTokenUsageSample]) -> ProviderStatus {
        let info = QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: CodexUsageDetails(
                primary: nil,
                secondary: nil,
                lastPrompt: nil,
                dailyTokenUsage: [DailyTokenUsage(
                    dayStart: today,
                    inputTokens: samples.map(\.inputTokens).reduce(0, +),
                    cachedInputTokens: samples.map(\.cachedInputTokens).reduce(0, +),
                    outputTokens: samples.map(\.outputTokens).reduce(0, +),
                    reasoningOutputTokens: samples.map(\.reasoningOutputTokens).reduce(0, +)
                )],
                recentSamples: samples,
                scannedAt: now
            ),
            fetchedAt: now
        )
        return ProviderStatus(
            id: "codex_chatgpt",
            displayName: "ChatGPT Plan",
            kind: .codexChatGpt,
            iconSystemName: "sparkles",
            accentColor: .chatgpt,
            refreshIntervalSeconds: 300,
            state: .ok(info)
        )
    }

    /// OpenCode 分片挂在任意一张卡上：贡献身份恒为 `ClientID.openCode`，
    /// 计价身份恒为该卡的 `kind.quotaProviderID`。
    private func opencodeStatus(
        kind: ProviderKind,
        providerID: String,
        samples: [LocalTokenUsageSample]
    ) -> ProviderStatus {
        let usage = OpencodeProviderUsage(
            today: nil,
            dailyTokenUsage: [],
            roundCount: samples.count,
            cost: 0,
            recentSamples: samples
        )
        return ProviderStatus(
            id: kind.providerID,
            displayName: kind == .glmCodingPlan ? "GLM Coding Plan" : "ChatGPT Plan",
            kind: kind,
            iconSystemName: "circle",
            accentColor: .minimax,
            refreshIntervalSeconds: 300,
            state: .notConfigured(reason: "test"),
            mergeOpencodeUsage: true,
            opencodeUsage: OpencodeLocalUsage(
                byProvider: [providerID: usage],
                modelsByProvider: [:],
                dbPath: nil,
                scannedAt: now
            )
        )
    }

    /// DeepSeek 卡：DSH 来源 + 一条高峰窗口（行价值按窗口取倍率）。
    private func deepseekStatus(window: DeepseekPeakWindow, at date: Date) -> ProviderStatus {
        let samples = [sample(model: "deepseek-chat", at: date, input: 1_000_000, cached: 0, output: 0)]
        let usage = DshLocalUsage(
            byProvider: ["deepseek": DshProviderUsage(
                today: nil,
                dailyTokenUsage: [],
                sessionCount: 1,
                roundCount: samples.count,
                recentSamples: samples
            )],
            modelsByProvider: ["deepseek": ["deepseek-chat"]],
            sessionsRoot: nil,
            sessionCount: 1,
            eventCount: samples.count,
            scannedAt: date
        )
        return ProviderStatus(
            id: "deepseek",
            displayName: "DeepSeek",
            kind: .deepseek,
            iconSystemName: "circle",
            accentColor: .deepseek,
            refreshIntervalSeconds: 300,
            state: .notConfigured(reason: "test"),
            dshUsage: usage,
            deepseekPeakWindow: window
        )
    }
}
