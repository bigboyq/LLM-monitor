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

    /// 禁用 provider 的本地用量不计入今日合计与列表。
    func testDisabledProviderIsFilteredOutFromTodaySummary() {
        var disabled = codexStatus(samples: [sample(model: "gpt-5.5", at: now, input: 1_000)])
        disabled.isEnabled = false
        let enabled = opencodeStatus(
            kind: .glmCodingPlan,
            providerID: OpencodeLocalUsage.glmProviderID,
            samples: [sample(model: "glm-4", at: now, input: 500)]
        )

        let summary = HarnessTodaySummary.summarize(statuses: [disabled, enabled], now: now, calendar: calendar)

        XCTAssertEqual(summary.totalTokens, 500, "已禁用的 provider 不得进入今日合计")
        XCTAssertEqual(summary.sections.count, 1)
        XCTAssertEqual(summary.sections.first?.rows.first?.totalTokens, 500)
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

    // MARK: - 行速度（tok/s）

    /// 行速度 = Σ(Output+Reason) ÷ Σ调用时长（`windowTokenRate` 的 Σ/Σ 加权口径，
    /// 不是各样本速率的算术平均），与行价值同源同批今日样本。
    func testRowTokensPerSecondIsTheDurationWeightedQuotient() {
        let status = codexStatus(samples: [
            // 600 billable tokens / 2s = 300 tok/s
            sample(model: "gpt-5.5", at: now, input: 1_000, output: 400, reasoning: 200, promptID: "a", duration: 2),
            // 300 billable tokens / 3s = 100 tok/s
            sample(model: "gpt-5.5", at: now, input: 1_000, output: 300, promptID: "b", duration: 3)
        ])

        let row = try! XCTUnwrap(
            HarnessTodaySummary.summarize(statuses: [status], now: now, calendar: calendar)
                .sections.first?.rows.first
        )

        // Σ/Σ = 900 / 5 = 180；算术平均会是 (300 + 100) / 2 = 200。
        XCTAssertEqual(row.tokensPerSecond ?? 0, 180, accuracy: 1e-9)
    }

    /// 时长未知的调用不参与：全行都没有有效时长时行速度是 nil（UI 显示「—」，
    /// 是"没得算"而不是 0）；混入 nil 样本时速率只由带时长的样本决定。
    func testRowTokensPerSecondIgnoresSamplesWithoutValidDuration() {
        let allNil = HarnessTodaySummary.summarize(
            statuses: [codexStatus(samples: [
                sample(model: "gpt-5.5", at: now, input: 1_000, output: 5_000, promptID: "a"),
                sample(model: "gpt-5.5", at: now, input: 1_000, output: 5_000, promptID: "b")
            ])],
            now: now, calendar: calendar
        ).sections[0].rows[0]
        XCTAssertNil(allNil.tokensPerSecond, "全行都没有时长 →「—」（没得算），不是 0")

        let mixed = HarnessTodaySummary.summarize(
            statuses: [codexStatus(samples: [
                sample(model: "gpt-5.5", at: now, input: 1_000, output: 999_000, promptID: "a"),
                sample(model: "gpt-5.5", at: now, input: 1_000, output: 400, promptID: "b", duration: 2)
            ])],
            now: now, calendar: calendar
        ).sections[0].rows[0]
        XCTAssertEqual(
            mixed.tokensPerSecond ?? 0, 200, accuracy: 1e-9,
            "时长未知的调用不参与，速率只由带时长的样本决定"
        )
    }

    // MARK: - 段速度（tok/s）

    /// 段速度 = 该 client **今日全部样本**的 Σ/Σ（`windowTokenRate` 唯一口径），
    /// 不是各行速率的算术平均：样本全集 = 段内各行分组样本的并集。
    /// 单 provider 客户段由此与 popwindow「额度窗口」表格「今」行的速度同值
    /// （同一批今日样本、同一函数）。
    func testSectionTokensPerSecondIsTheQuotientOverAllClientSamples() {
        // 两行不同模型：600 billable/2s 与 300/3s。段速度 Σ/Σ = 900/5 = 180；
        // 若误用各行速率的算术平均会得到 (300 + 100) / 2 = 200。
        let status = codexStatus(samples: [
            sample(model: "gpt-5.5", at: now, input: 1_000, output: 400, reasoning: 200, promptID: "a", duration: 2),
            sample(model: "gpt-5.2", at: now, input: 1_000, output: 300, promptID: "b", duration: 3)
        ])

        let section = HarnessTodaySummary.summarize(statuses: [status], now: now, calendar: calendar)
            .sections[0]

        XCTAssertEqual(section.rows.count, 2, "前提：两个模型各占一行，段速度聚合在行之上")
        XCTAssertEqual(section.tokensPerSecond ?? 0, 180, accuracy: 1e-9, "Σ/Σ = 900/5 = 180")
    }

    /// 段速度的样本全集横跨同一段里的多个 provider 分片：OpenCode 段在两张卡上
    /// 各有一份贡献，段速度在两份样本的**并集**上算 Σ/Σ，而不是任一分片的速率
    /// （单分片速率分别是 300 与 100，都 ≠ 180）。
    func testSectionTokensPerSecondMergesSamplesAcrossProviderShards() {
        let openAI = opencodeStatus(
            kind: .codexChatGpt,
            providerID: OpencodeLocalUsage.openAIProviderID,
            samples: [sample(model: "gpt-5.5", at: now, input: 1_000, output: 400, reasoning: 200, promptID: "a", duration: 2)]
        )
        let zhipu = opencodeStatus(
            kind: .glmCodingPlan,
            providerID: OpencodeLocalUsage.glmProviderID,
            samples: [sample(model: "GLM-5.3", at: now, input: 1_000, output: 300, promptID: "b", duration: 3)]
        )

        let summary = HarnessTodaySummary.summarize(statuses: [openAI, zhipu], now: now, calendar: calendar)

        XCTAssertEqual(summary.sections.count, 1)
        let section = summary.sections[0]
        XCTAssertEqual(section.clientID, ClientID.openCode)
        XCTAssertEqual(section.rows.count, 2)
        XCTAssertEqual(
            section.tokensPerSecond ?? 0, 180, accuracy: 1e-9,
            "跨分片并集 Σ/Σ = 900/5 = 180，不是任一单分片的 300 或 100"
        )
    }

    /// 该 client 今日样本全都没有有效时长 → 段速度 nil（UI 显示「—」，是
    /// "没得算"而不是 0）。
    func testSectionTokensPerSecondIsNilWhenNoSampleHasValidDuration() {
        let status = codexStatus(samples: [
            sample(model: "gpt-5.5", at: now, input: 1_000, output: 5_000, promptID: "a"),
            sample(model: "gpt-5.2", at: now, input: 1_000, output: 5_000, promptID: "b")
        ])

        let section = HarnessTodaySummary.summarize(statuses: [status], now: now, calendar: calendar)
            .sections[0]

        XCTAssertEqual(section.rows.count, 2)
        XCTAssertNil(section.tokensPerSecond, "全段都没有时长 →「—」（没得算），不是 0")
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

    /// 压缩名只去掉超长品牌前缀、让变体后缀可区分；分组键与统计仍用原始 ID。
    func testCompactDisplayNameStripsOnlyLongBrandPrefixes() {
        func row(named model: String?) -> HarnessModelRow {
            HarnessModelRow(
                dayStart: now, clientID: "antigravity", quotaProviderID: "antigravity",
                modelName: model,
                samples: [sample(model: model, at: now, input: 100, cached: 0, output: 10, promptID: "p")],
                calendar: calendar
            )
        }
        // 变体后缀在定宽列里可区分（这是压缩的唯一目的）
        XCTAssertEqual(row(named: "gemini-3.8-flash-n").compactDisplayName, "3.8-flash-n")
        XCTAssertEqual(row(named: "gemini-3.8-flash-tiered").compactDisplayName, "3.8-flash-tiered")
        XCTAssertEqual(row(named: "claude-opus-4-6-thinking").compactDisplayName, "opus-4-6-thinking")
        // 短前缀 / 无前缀 / 其他品牌不压：裸 `flash` 在多 provider 段里反而难归属
        XCTAssertEqual(row(named: "deepseek-flash").compactDisplayName, "deepseek-flash")
        XCTAssertEqual(row(named: "GLM-5.3").compactDisplayName, "GLM-5.3")
        XCTAssertEqual(row(named: "gpt-5.2-codex").compactDisplayName, "gpt-5.2-codex")
        // 分组键（modelName）不受展示压缩影响
        XCTAssertEqual(row(named: "gemini-3.8-flash-n").modelName, "gemini-3.8-flash-n")
    }

    /// MiniMax 系各种真实形态都要归一成**同一个模型名**：供应商命名空间
    /// (`minimax/`) 不该占展示列的宽度，M3.1 家族的变体后缀
    /// (`-Flash` / `-Flash-Preview`) 也不该——它们是同一个模型、同一份价目。
    ///
    /// 真实账本里的写法：MiniMax Code 记 `minimax/MiniMax-M3`（旧泛化标签）与
    /// `MiniMax-M3.1-Flash`（session 目录里的真实模型）、ZCode 记
    /// `MiniMax-M3.1-Flash-Preview`、DSH 记 `Minimax-M3.1-flash-preview`
    /// （首字母小写）。
    func testCompactDisplayNameNormalizesMinimaxFamily() {
        func row(named model: String) -> HarnessModelRow {
            HarnessModelRow(
                dayStart: now, clientID: "minimax-code", quotaProviderID: "minimax",
                modelName: model,
                samples: [sample(model: model, at: now, input: 100, cached: 0, output: 10, promptID: "p")],
                calendar: calendar
            )
        }
        XCTAssertEqual(row(named: "minimax/MiniMax-M3").compactDisplayName, "MiniMax-M3")
        XCTAssertEqual(row(named: "MiniMax-M3").compactDisplayName, "MiniMax-M3")
        XCTAssertEqual(row(named: "MiniMax-M3.1-Flash-Preview").compactDisplayName, "MiniMax-M3.1")
        XCTAssertEqual(row(named: "MiniMax-M3.1-Flash").compactDisplayName, "MiniMax-M3.1")
        // 大小写不敏感：DSH 的写法首字母小写
        XCTAssertEqual(row(named: "Minimax-M3.1-flash-preview").compactDisplayName, "MiniMax-M3.1")
        // 展示压缩不改动原始 ID：分组键与定价统计仍用原名
        XCTAssertEqual(row(named: "minimax/MiniMax-M3").modelName, "minimax/MiniMax-M3")
        XCTAssertEqual(row(named: "minimax/MiniMax-M3").displayName, "minimax/MiniMax-M3")
    }

    /// 变体后缀只在 MiniMax 家族内剥：gemini 的 `-flash` 是变体标识
    /// （`3.8-flash-n` / `3.8-flash-tiered` 靠它区分），砍掉就不可分辨了。
    func testCompactDisplayNameKeepsGeminiFlashVariant() {
        XCTAssertEqual(HarnessModelRow.compactedDisplayName(for: "gemini-3.8-flash-n"), "3.8-flash-n")
        XCTAssertEqual(HarnessModelRow.compactedDisplayName(for: "gemini-3.8-flash-tiered"), "3.8-flash-tiered")
        XCTAssertEqual(HarnessModelRow.compactedDisplayName(for: "gemini-3.8-flash"), "3.8-flash")
    }

    /// 命名空间剥离不能把展示名剥成空白：原始 ID 形如 `/` 时保留原名。
    func testCompactDisplayNameKeepsNonEmptyResult() {
        XCTAssertEqual(HarnessModelRow.compactedDisplayName(for: "/"), "/")
        XCTAssertEqual(HarnessModelRow.compactedDisplayName(for: "minimax/"), "minimax/")
        XCTAssertEqual(HarnessModelRow.compactedDisplayName(for: "minimax/MiniMax-M3"), "MiniMax-M3")
    }

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

    // MARK: - 截断与新鲜度（菜单那两枚提示的数据源）

    /// 段截断位是**段级**聚合：DSH 来源被预算截断 → 那一段（DSH 客户端）的段头
    /// 出现橙色提示；同一份汇总里的 Codex 段不受影响（它的来源没有被截断）。
    func testTruncatedSourceMarksOnlyItsOwnSection() {
        let codex = codexStatus(samples: [sample(model: "gpt-5.5", at: now, input: 1_000, promptID: "c")])
        let truncatedDSH = dshStatus(
            samples: [sample(model: "deepseek-chat", at: now, input: 2_000, promptID: "d")],
            isTruncated: true
        )

        let summary = HarnessTodaySummary.summarize(
            statuses: [codex, truncatedDSH], now: now, calendar: calendar
        )
        let byClient = Dictionary(uniqueKeysWithValues: summary.sections.map { ($0.clientID, $0) })
        XCTAssertEqual(byClient[ClientID.codex]?.isTruncated, false, "未截断的来源不该被提示")
        XCTAssertEqual(
            byClient[ClientID.dsh]?.isTruncated, true,
            "DSH 快照被截断 → DSH 段必须提示（否则一份残缺统计被当完整统计读）"
        )
    }

    /// 没有截断来源时整份汇总都不带截断位（提示不该无差别出现）。
    func testNoTruncationMeansNoNoticeAnywhere() {
        let summary = HarnessTodaySummary.summarize(
            statuses: [codexStatus(samples: [sample(model: "gpt-5.5", at: now, input: 1_000)])],
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(summary.sections.allSatisfy { $0.isTruncated == false })
    }

    // MARK: - 权威日桶汇总与抽样样本差异契约

    /// 当样本因容量限制被截断或滚动淘汰时，今日汇总（全局 4 桶、总 Token、命中率、段总 Token 与比例条）
    /// 必须权威地来自 dailyTokenUsage，而模型细分行显示实际留存的样本子集，并带有独立完整性提示。
    func testDailyTotalsAreAuthoritativeWhenRecentSamplesArePrunedOrTruncated() throws {
        let sampleItem = sample(model: "deepseek-chat", at: now, input: 1_400, cached: 600, output: 400, reasoning: 200)
        // sampleItem 对应 4 桶：uncached 800, cacheRead 600, output 400, reasoning 200 = 2,000 total.
        // 而权威 dailyTokenUsage 记录的是今日完整 10,000 Token：
        let dailyUsage = DshDailyUsage(
            dayStart: today,
            inputTokens: 4_000,
            outputTokens: 2_000,
            cacheReadTokens: 3_000,
            reasoningTokens: 1_000,
            totalTokens: 10_000,
            turns: 10,
            rounds: 20
        )
        let dsh = ProviderStatus(
            id: "deepseek",
            displayName: "DeepSeek",
            kind: .deepseek,
            iconSystemName: "circle",
            accentColor: .deepseek,
            refreshIntervalSeconds: 300,
            state: .notConfigured(reason: "test"),
            dshUsage: DshLocalUsage(
                byProvider: ["deepseek": DshProviderUsage(
                    today: dailyUsage,
                    dailyTokenUsage: [dailyUsage],
                    sessionCount: 5,
                    roundCount: 20,
                    recentSamples: [sampleItem],
                    recentSamplesTruncated: true
                )],
                modelsByProvider: ["deepseek": ["deepseek-chat"]],
                sessionsRoot: nil,
                sessionCount: 5,
                eventCount: 20,
                scannedAt: now,
                isTruncated: false
            )
        )

        let summary = HarnessTodaySummary.summarize(statuses: [dsh], now: now, calendar: calendar)

        // 权威日桶合计：10,000 Token
        XCTAssertEqual(summary.totalTokens, 10_000, "全局总 Token 必须来自权威 dailyTokenUsage，而非被截断的 2,000 样本")
        // 命中率 = 3,000 / (4,000 + 3,000) = 3/7
        XCTAssertEqual(summary.cacheHitRate ?? 0, 3_000.0 / 7_000.0, accuracy: 1e-6)

        XCTAssertEqual(summary.sections.count, 1)
        let section = summary.sections[0]
        XCTAssertEqual(section.clientID, ClientID.dsh)
        XCTAssertEqual(section.totalTokens, 10_000)
        XCTAssertEqual(section.buckets, TokenUsageBuckets(input: 4_000, cacheRead: 3_000, output: 2_000, reasoning: 1_000))
        XCTAssertTrue(section.samplesTruncated, "section 必须继承 samplesTruncated 状态")
        XCTAssertEqual(section.rows.count, 1)
        XCTAssertEqual(section.rows[0].totalTokens, 2_000, "模型行仍展示留存样本子集的 2,000 Token")

        let notice: String = try XCTUnwrap(section.sampleIntegrityNotice)
        XCTAssertTrue(notice.contains("清理") || notice.contains("留存样本"))

        let segments = HarnessTodaySummary.clientSegments(from: summary.sections)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].totalTokens, 10_000)
    }

    /// 当客户端今天有日桶用量但抽样明细为 0 时（如旧会话滚动清除），该客户端依然必须展示，
    /// 价值文本显示为 "—"（而非伪装成 0 元），模型行展开显示清晰说明，且不将差异随意分摊给任何模型。
    func testClientWithDailyTotalsButNoSamplesIsStillDisplayed() throws {
        let dailyUsage = DshDailyUsage(
            dayStart: today,
            inputTokens: 3_000,
            outputTokens: 1_000,
            cacheReadTokens: 1_000,
            reasoningTokens: 0,
            totalTokens: 5_000,
            turns: 2,
            rounds: 5
        )
        let dsh = ProviderStatus(
            id: "deepseek",
            displayName: "DeepSeek",
            kind: .deepseek,
            iconSystemName: "circle",
            accentColor: .deepseek,
            refreshIntervalSeconds: 300,
            state: .notConfigured(reason: "test"),
            dshUsage: DshLocalUsage(
                byProvider: ["deepseek": DshProviderUsage(
                    today: dailyUsage,
                    dailyTokenUsage: [dailyUsage],
                    sessionCount: 1,
                    roundCount: 5,
                    recentSamples: [],
                    recentSamplesTruncated: false
                )],
                modelsByProvider: ["deepseek": ["deepseek-chat"]],
                sessionsRoot: nil,
                sessionCount: 1,
                eventCount: 5,
                scannedAt: now,
                isTruncated: false
            )
        )

        let summary = HarnessTodaySummary.summarize(statuses: [dsh], now: now, calendar: calendar)

        XCTAssertEqual(summary.totalTokens, 5_000)
        XCTAssertEqual(summary.valueText, "—", "缺少模型明细时全局价值显示为 —，不得伪装成 0")
        XCTAssertEqual(summary.heroParts.primary, "—")
        XCTAssertEqual(summary.heroParts.subtitle, "今日花费")
        XCTAssertEqual(summary.sections.count, 1)
        let section = summary.sections[0]
        XCTAssertEqual(section.totalTokens, 5_000)
        XCTAssertTrue(section.rows.isEmpty, "没有样本时模型明细行应为空")
        XCTAssertEqual(section.valueText, "—", "缺少模型明细时价值显示为 —，不得伪装成 0")
        let notice: String = try XCTUnwrap(section.sampleIntegrityNotice)
        XCTAssertTrue(notice.contains("暂无") || notice.contains("单次调用模型明细"))

        let segments = HarnessTodaySummary.clientSegments(from: summary.sections)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].totalTokens, 5_000)
    }

    /// 当样本量小于日桶但未显式置位 samplesTruncated 时，hasIncompleteSamples 仍为 true 并输出清理说明。
    func testHasIncompleteSamplesDetectsEvictedSamplesWithoutExplicitFlag() throws {
        let sampleItem = sample(model: "gpt-5.5", at: now, input: 1_000)
        let codex = codexStatus(samples: [sampleItem])
        // codexStatus 默认用 samples 算 daily，此时 rowsTotalTokens == totalTokens，hasIncompleteSamples == false
        let completeSummary = HarnessTodaySummary.summarize(statuses: [codex], now: now, calendar: calendar)
        XCTAssertFalse(completeSummary.sections[0].hasIncompleteSamples)
        XCTAssertNil(completeSummary.sections[0].sampleIntegrityNotice)

        // 构造日桶 5,000 但只有 1,000 样本且 samplesTruncated = false（样本被时间窗口淘汰场景）
        let dsh = ProviderStatus(
            id: "dsh_test",
            displayName: "DSH",
            kind: .deepseek,
            iconSystemName: "terminal",
            accentColor: .chatgpt,
            refreshIntervalSeconds: 300,
            state: .notConfigured(reason: "test"),
            dshUsage: DshLocalUsage(
                byProvider: ["deepseek": DshProviderUsage(
                    today: DshDailyUsage(
                        dayStart: today, inputTokens: 4_000, outputTokens: 1_000,
                        cacheReadTokens: 0, reasoningTokens: 0, totalTokens: 5_000,
                        turns: 1, rounds: 1
                    ),
                    dailyTokenUsage: [DshDailyUsage(
                        dayStart: today, inputTokens: 4_000, outputTokens: 1_000,
                        cacheReadTokens: 0, reasoningTokens: 0, totalTokens: 5_000,
                        turns: 1, rounds: 1
                    )],
                    sessionCount: 1,
                    roundCount: 1,
                    recentSamples: [sampleItem],
                    recentSamplesTruncated: false
                )],
                modelsByProvider: ["deepseek": ["gpt-5.5"]],
                sessionsRoot: nil,
                sessionCount: 1,
                eventCount: 1,
                scannedAt: now,
                isTruncated: false
            )
        )
        let prunedSummary = HarnessTodaySummary.summarize(statuses: [dsh], now: now, calendar: calendar)
        let prunedSection = prunedSummary.sections[0]
        XCTAssertEqual(prunedSection.totalTokens, 5_000)
        XCTAssertEqual(prunedSection.rowsTotalTokens, 1_000)
        XCTAssertTrue(prunedSection.hasIncompleteSamples, "样本总和小于日桶时即便无 explicit flag 也应判定为 incomplete")
        XCTAssertEqual(prunedSection.sampleIntegrityNotice, "部分早期样本已被清理，模型明细仅覆盖留存样本")
    }

    /// 全局新鲜度：任一启用数据源在扫 → 「计算中…」；全 idle → 「更新于 HH:mm」
    /// （取各卡扫描时间的最大值）。两个状态都由 `summarize` 顺带算出，视图端
    /// 不再自己去遍历 statuses。
    func testGlobalFreshnessReportsScanningAndTheLatestScanTime() {
        let idle = HarnessTodaySummary.summarize(
            statuses: [codexStatus(samples: [sample(model: "gpt-5.5", at: now, input: 1)])],
            now: now, calendar: calendar
        )
        XCTAssertFalse(idle.isScanningLocalUsage)
        XCTAssertEqual(idle.localUsageScannedAt, now, "idle 时显示最近一次扫描时间")

        let scanning = HarnessTodaySummary.summarize(
            statuses: [codexStatus(
                samples: [sample(model: "gpt-5.5", at: now, input: 1)],
                isScanning: true
            )],
            now: now, calendar: calendar
        )
        XCTAssertTrue(scanning.isScanningLocalUsage, "任一来源在扫就必须显示「计算中…」")
    }

    /// 一个来源都没扫过时**不显示**时间（而不是显示一个空胶囊或"更新于 1970"）。
    func testFreshnessIsAbsentWhenNothingWasEverScanned() {
        let summary = HarnessTodaySummary.summarize(statuses: [], now: now, calendar: calendar)
        XCTAssertFalse(summary.isScanningLocalUsage)
        XCTAssertNil(summary.localUsageScannedAt)
    }

    // MARK: - 段头右键的刷新目标（refreshProviderStatusIDs）

    /// 段头右键「刷新 <客户端名>」要刷的 provider 卡：本段行涉及的
    /// `quotaProviderID` → 匹配的 status.id，**输出顺序跟随传入 statuses**、
    /// 按 status.id 去重、段里没贡献的 provider 忽略。
    ///
    /// ZCode 段是关键场景：GLM / minimax / deepseek 三张卡的分片行同段共存，
    /// 一次右键必须刷齐三张且只刷这三张；段的行序（按今日 token 排）与卡序
    /// （用户配置的展示序）没有关联，输出必须以 statuses 为准。
    func testRefreshProviderStatusIDsFollowsStatusOrderAndSkipsUnrelated() {
        func row(quotaProviderID: String, modelName: String) -> HarnessModelRow {
            HarnessModelRow(
                dayStart: today,
                clientID: ClientID.zcode,
                quotaProviderID: quotaProviderID,
                modelName: modelName,
                samples: [sample(model: modelName, at: now, input: 100, promptID: modelName)],
                calendar: calendar
            )
        }
        let section = HarnessSection(
            clientID: ClientID.zcode,
            displayName: "ZCode",
            iconSystemName: "chevron.left.forwardslash.chevron.right",
            buckets: TokenUsageBuckets.zero,
            tokensPerSecond: nil,
            value: MixedCurrencyEstimate(usd: 0, cny: 0),
            rows: [
                row(quotaProviderID: QuotaProviderID.zhipu, modelName: "GLM-5.3"),
                row(quotaProviderID: QuotaProviderID.minimax, modelName: "minimax-m2"),
                row(quotaProviderID: QuotaProviderID.minimax, modelName: "minimax-m1"),
                row(quotaProviderID: QuotaProviderID.deepseek, modelName: "deepseek-chat")
            ],
            isTruncated: false
        )
        // statuses 顺序故意与段内行序不同，且把段里没贡献的 codex 卡排最前。
        let statuses = [
            minimalStatus(id: "codex_chatgpt", kind: .codexChatGpt),
            minimalStatus(id: "deepseek", kind: .deepseek),
            minimalStatus(id: "glm_coding_plan", kind: .glmCodingPlan),
            minimalStatus(id: "minimax_token_plan", kind: .minimaxTokenPlan)
        ]

        XCTAssertEqual(
            section.refreshProviderStatusIDs(in: statuses),
            ["deepseek", "glm_coding_plan", "minimax_token_plan"],
            "顺序跟随 statuses；未贡献的 codex 卡被忽略；两行 minimax 分片只映射一卡"
        )

        // 列表里一个匹配的 provider 都没有（如该段贡献的卡全部不在场）→ 空列表，
        // 调用方不必发起任何刷新任务。
        XCTAssertTrue(
            section.refreshProviderStatusIDs(
                in: [minimalStatus(id: "codex_chatgpt", kind: .codexChatGpt)]
            ).isEmpty
        )
    }

    // MARK: - fixtures

    /// 最小可用 `ProviderStatus`：只有 id 与 kind 是有效信息（右键刷新目标的
    /// 映射只看 `kind.quotaProviderID` 与 `id`），状态一律未配置即可。
    private func minimalStatus(id: String, kind: ProviderKind) -> ProviderStatus {
        ProviderStatus(
            id: id,
            displayName: id,
            kind: kind,
            iconSystemName: "circle",
            accentColor: .chatgpt,
            refreshIntervalSeconds: 300,
            state: .notConfigured(reason: "test")
        )
    }

    private func sample(
        model: String?,
        at date: Date,
        input: Int,
        cached: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        promptID: String = "p1",
        duration: Double? = nil
    ) -> LocalTokenUsageSample {
        LocalTokenUsageSample(
            completedAt: date,
            modelName: model,
            promptID: promptID,
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            durationSeconds: duration
        )
    }

    /// ChatGPT / Codex 卡：`codexUsageDetails.recentSamples` 走原生贡献。
    /// `isScanning` 用来驱动全局新鲜度那一格（菜单「计算中…」的数据源）。
    private func codexStatus(
        samples: [LocalTokenUsageSample],
        isScanning: Bool = false
    ) -> ProviderStatus {
        let grouped = Dictionary(grouping: samples, by: { calendar.startOfDay(for: $0.completedAt) })
        let daily = grouped.map { day, daySamples in
            DailyTokenUsage(
                dayStart: day,
                inputTokens: daySamples.map(\.inputTokens).reduce(0, +),
                cachedInputTokens: daySamples.map(\.cachedInputTokens).reduce(0, +),
                outputTokens: daySamples.map(\.outputTokens).reduce(0, +),
                reasoningOutputTokens: daySamples.map(\.reasoningOutputTokens).reduce(0, +)
            )
        }
        let info = QuotaInfo(
            models: [],
            resetCredits: nil,
            planLabel: nil,
            accountEmail: nil,
            codexUsageDetails: CodexUsageDetails(
                primary: nil,
                secondary: nil,
                dailyTokenUsage: daily,
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
            state: .ok(info),
            isScanningLocalUsage: isScanning
        )
    }

    /// DeepSeek 卡 + DSH 来源。`isTruncated` 是快照级截断位（文件数/字节预算挤出
    /// 最旧 session），不随 provider 分片稀释——段头那枚提示就是读它。
    private func dshStatus(
        samples: [LocalTokenUsageSample],
        isTruncated: Bool
    ) -> ProviderStatus {
        return ProviderStatus(
            id: "deepseek",
            displayName: "DeepSeek",
            kind: .deepseek,
            iconSystemName: "circle",
            accentColor: .deepseek,
            refreshIntervalSeconds: 300,
            state: .notConfigured(reason: "test"),
            dshUsage: DshLocalUsage(
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
                scannedAt: now,
                isTruncated: isTruncated
            )
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
            clientBindings: ProviderStatus.allClientBindingsEnabled(),
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
