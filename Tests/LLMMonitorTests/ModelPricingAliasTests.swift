import XCTest
import Foundation
@testable import LLM_monitor

final class ModelPricingAliasTests: XCTestCase {

    func testUnknownModelIsNotAssignedAnEstimatedPrice() {
        let sample = LocalTokenUsageSample(
            completedAt: Date(),
            modelName: "future-model",
            promptID: "prompt-1",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 30,
            reasoningOutputTokens: 0
        )

        let estimate = ModelPricingCatalog.estimate(
            samples: [sample],
            quotaProviderID: QuotaProviderID.openAI
        )
        XCTAssertNil(estimate.value)
        XCTAssertNil(estimate.currency)
        XCTAssertEqual(estimate.unpricedModelNames, ["future-model"])
    }

    /// UI-002：计价覆盖度必须可区分。金额只覆盖已计价 sample；
    /// 部分计价时 displayText 必须带“（部分计价）”标记，避免误读为全部成本。
    func testCostEstimateCoverageAndDisplayText() {
        func sample(_ model: String?, input: Int = 100) -> LocalTokenUsageSample {
            LocalTokenUsageSample(
                completedAt: Date(),
                modelName: model,
                promptID: "p-\(model ?? "nil")",
                inputTokens: input,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0
            )
        }

        // 1. 全部计价：两个已定价 openai 模型（同币种）→ fullyPriced，无标记。
        let fullyPriced = ModelPricingCatalog.estimate(
            samples: [sample("gpt-5.5"), sample("gpt-5.6-luna")],
            quotaProviderID: QuotaProviderID.openAI
        )
        XCTAssertEqual(fullyPriced.coverage, .fullyPriced)
        XCTAssertEqual(fullyPriced.unpricedModelNames, [])
        XCTAssertFalse(fullyPriced.displayText.contains("部分计价"))
        XCTAssertTrue(fullyPriced.displayText.hasPrefix("$"))

        // 2. 部分计价：已定价模型 + 未知模型 → 金额只覆盖已定价部分。
        let partial = ModelPricingCatalog.estimate(
            samples: [sample("gpt-5.5", input: 1_000_000), sample("future-model", input: 1_000_000)],
            quotaProviderID: QuotaProviderID.openAI
        )
        XCTAssertEqual(partial.coverage, .partiallyPriced)
        XCTAssertEqual(partial.pricedModelNames, ["gpt-5.5"])
        XCTAssertEqual(partial.unpricedModelNames, ["future-model"])
        XCTAssertEqual(partial.displayText, "$5.00（部分计价）", "金额只覆盖已计价 sample，且必须带部分计价标记")

        // 3. 模型名缺失：nil 与空串都归入“未知模型”，同样算未计价。
        let missingName = ModelPricingCatalog.estimate(
            samples: [sample(nil), sample("")],
            quotaProviderID: QuotaProviderID.openAI
        )
        XCTAssertEqual(missingName.coverage, .noPricedSamples)
        XCTAssertEqual(missingName.unpricedModelNames, ["未知模型"])
        XCTAssertEqual(missingName.displayText, "未定价")

        // 4. 全部未知 → 无可计价 sample。
        let nonePriced = ModelPricingCatalog.estimate(
            samples: [sample("mystery")],
            quotaProviderID: QuotaProviderID.openAI
        )
        XCTAssertEqual(nonePriced.coverage, .noPricedSamples)
        XCTAssertEqual(nonePriced.displayText, "未定价")

        // 5. 同 provider 混合币种当前不可达（目录中每个 provider 只有一种币种）；
        //    estimate 的冲突分支把冲突模型计入 unpricedModels 并停止相加，
        //    语义等价于部分计价 —— 见 ProviderClientModel.estimate 里的注释。
        let minimaxCNY = ModelPricingCatalog.estimate(
            samples: [sample("MiniMax-M3")],
            quotaProviderID: QuotaProviderID.minimax
        )
        XCTAssertEqual(minimaxCNY.coverage, .fullyPriced)
        XCTAssertTrue(minimaxCNY.displayText.hasPrefix("¥"))
    }

    func testClientSummaryMarksPartialPricingInSevenDayTable() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            LocalTokenUsageSample(
                completedAt: day,
                modelName: "gpt-5.5",
                promptID: "priced",
                inputTokens: 1_000_000,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0
            ),
            LocalTokenUsageSample(
                completedAt: day.addingTimeInterval(1),
                modelName: "future-model",
                promptID: "unpriced",
                inputTokens: 1_000_000,
                cachedInputTokens: 0,
                outputTokens: 0,
                reasoningOutputTokens: 0
            )
        ]
        let summary = ClientProviderUsageSummary(
            clientID: ClientID.codex,
            quotaProviderID: QuotaProviderID.openAI,
            providerName: "ChatGPT Plan",
            dailyTokenUsage: [UnifiedDailyTokenUsage(dayStart: day, input: 2_000_000)],
            recentSamples: samples,
            scannedAt: day
        )

        XCTAssertEqual(summary.costEstimate.coverage, .partiallyPriced)
        XCTAssertEqual(summary.priceTextByDay[day], "$5.00（部分计价）")
    }

    func testClientSummaryExplainsUnpricedModelTokenImpact() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = ClientProviderUsageSummary(
            clientID: ClientID.minimaxCode,
            quotaProviderID: QuotaProviderID.minimax,
            providerName: "MiniMax",
            dailyTokenUsage: [
                UnifiedDailyTokenUsage(dayStart: day, input: 80, cacheRead: 20, output: 30, reasoning: 10)
            ],
            recentSamples: [
                LocalTokenUsageSample(
                    completedAt: day,
                    modelName: nil,
                    promptID: "unknown-model",
                    inputTokens: 100,
                    cachedInputTokens: 20,
                    outputTokens: 30,
                    reasoningOutputTokens: 10
                )
            ],
            scannedAt: day
        )

        XCTAssertEqual(summary.unpricedModelUsage.count, 1)
        XCTAssertEqual(summary.unpricedModelUsage.first?.modelName, "模型名缺失")
        XCTAssertEqual(summary.unpricedModelUsage.first?.totalTokens, 140)
        XCTAssertEqual(summary.unpricedModelUsage.first?.sampleCount, 1)
    }

    func testPricingAliasesAndPriceSnapshot() {
        let codexPrices = [
            ModelPricingCatalog.pricing(for: "gpt-5.5", quotaProviderID: QuotaProviderID.openAI),
            ModelPricingCatalog.pricing(for: "gpt-5.6-sol", quotaProviderID: QuotaProviderID.openAI),
            ModelPricingCatalog.pricing(for: "gpt-5.6-terra", quotaProviderID: QuotaProviderID.openAI),
            ModelPricingCatalog.pricing(for: "gpt-5.6-luna", quotaProviderID: QuotaProviderID.openAI),
            ModelPricingCatalog.pricing(for: "gpt-6-sol", quotaProviderID: QuotaProviderID.openAI),
            ModelPricingCatalog.pricing(for: "gpt-6-luna", quotaProviderID: QuotaProviderID.openAI),
            ModelPricingCatalog.pricing(for: "gpt-6-astra", quotaProviderID: QuotaProviderID.openAI)
        ].compactMap { $0 }
        XCTAssertEqual(codexPrices.map(\.inputPerMillion), [5, 4, 2, 0.2, 2, 0.1, 10])
        XCTAssertEqual(codexPrices.map(\.cacheReadPerMillion), [0.5, 0.4, 0.2, 0.02, 0.2, 0.01, 1])
        XCTAssertEqual(codexPrices.map(\.outputPerMillion), [30, 20, 12, 1.2, 10, 0.5, 50])

        // 精确匹配回归：带变体后缀的 slug 不再被 contains 误吞，
        // 必须显式加入目录后才会被计价。
        XCTAssertNil(
            ModelPricingCatalog.pricing(for: "gpt-5.6-sol-codex", quotaProviderID: QuotaProviderID.openAI)
        )
        XCTAssertNil(
            ModelPricingCatalog.pricing(for: "gpt-6-sol-preview", quotaProviderID: QuotaProviderID.openAI)
        )
        XCTAssertNil(
            ModelPricingCatalog.pricing(for: "gpt-6-luna-mini", quotaProviderID: QuotaProviderID.openAI)
        )
        XCTAssertNil(
            ModelPricingCatalog.pricing(for: "gpt-6-astra-beta", quotaProviderID: QuotaProviderID.openAI)
        )

        for legacyModel in ["gpt-4", "gpt-4.1", "gpt-4o", "o1", "o1-mini", "o3", "o3-mini", "gpt-5", "gpt-5-mini"] {
            XCTAssertNil(
                ModelPricingCatalog.pricing(for: legacyModel, quotaProviderID: QuotaProviderID.openAI),
                "OpenAI/Codex should not price removed legacy model \(legacyModel)"
            )
        }

        // Antigravity owns a separate GPT pricing namespace; its GPT-4.1 rule is
        // intentionally unaffected by the OpenAI/Codex cleanup above.
        XCTAssertNotNil(
            ModelPricingCatalog.pricing(for: "gpt-4.1", quotaProviderID: QuotaProviderID.antigravity)
        )

        let gemini36 = ModelPricingCatalog.pricing(
            for: "gemini-3.6-flash", quotaProviderID: QuotaProviderID.antigravity
        )
        let gemini37 = ModelPricingCatalog.pricing(
            for: "gemini-3.7-flash", quotaProviderID: QuotaProviderID.antigravity
        )
        XCTAssertEqual(gemini36?.currency, gemini37?.currency)
        XCTAssertEqual(gemini36?.inputPerMillion, gemini37?.inputPerMillion)
        XCTAssertEqual(gemini36?.cacheReadPerMillion, gemini37?.cacheReadPerMillion)
        XCTAssertEqual(gemini36?.outputPerMillion, gemini37?.outputPerMillion)

        let minimax = ModelPricingCatalog.pricing(
            for: "minimax/MiniMax-M3", quotaProviderID: QuotaProviderID.minimax
        )
        XCTAssertEqual(minimax?.inputPerMillion, 2.1)
        XCTAssertEqual(minimax?.cacheReadPerMillion, 0.42)
        XCTAssertEqual(minimax?.outputPerMillion, 8.4)

        let opus = ModelPricingCatalog.pricing(
            for: "claude-opus-4-6", quotaProviderID: QuotaProviderID.antigravity
        )
        XCTAssertEqual(opus?.inputPerMillion, 5)
        XCTAssertEqual(opus?.cacheReadPerMillion, 0.5)
        XCTAssertEqual(opus?.outputPerMillion, 25)

        let sonnet = ModelPricingCatalog.pricing(
            for: "claude-sonnet-4.6", quotaProviderID: QuotaProviderID.antigravity
        )
        XCTAssertEqual(sonnet?.inputPerMillion, 3)
        XCTAssertEqual(sonnet?.cacheReadPerMillion, 0.3)
        XCTAssertEqual(sonnet?.outputPerMillion, 15)

        let gptOSS = ModelPricingCatalog.pricing(
            for: "MODEL_OPENAI_GPT_OSS_120B_MEDIUM", quotaProviderID: QuotaProviderID.antigravity
        )
        XCTAssertEqual(gptOSS?.inputPerMillion, 0.09)
        XCTAssertEqual(gptOSS?.cacheReadPerMillion, 0.009)
        XCTAssertEqual(gptOSS?.outputPerMillion, 0.36)
        XCTAssertEqual(AntigravityUsageGroup.classify(modelName: "gemini-3.6-flash"), .gemini)
        XCTAssertEqual(AntigravityUsageGroup.classify(modelName: "claude-opus-4-6"), .claudeAndGPT)
        XCTAssertEqual(AntigravityUsageGroup.classify(modelName: "gpt-oss-120b"), .claudeAndGPT)

        // GLM-5.3 保留独立高价（8/2/28）；GLM-5.2 与 5.3 拆开后不再共用条目。
        let glm53 = ModelPricingCatalog.pricing(for: "GLM-5.3", quotaProviderID: QuotaProviderID.zhipu)
        XCTAssertEqual(glm53?.currency, .cny)
        XCTAssertEqual(glm53?.inputPerMillion, 8)
        XCTAssertEqual(glm53?.cacheReadPerMillion, 2)
        XCTAssertEqual(glm53?.outputPerMillion, 28)
        XCTAssertEqual(glm53?.modelLabel, "GLM-5.3")

        // GLM-5.2 及以下已退休：历史模型与未来未知模型统一按 GLM-5.3-Flash 兜底。
        for retired in ["GLM-5.2", "GLM-4.5", "GLM-4.7", "GLM-6-future"] {
            let pricing = ModelPricingCatalog.pricing(for: retired, quotaProviderID: QuotaProviderID.zhipu)
            XCTAssertEqual(pricing?.currency, .cny, retired)
            XCTAssertEqual(pricing?.inputPerMillion, 0.8, retired)
            XCTAssertEqual(pricing?.cacheReadPerMillion, 0.23, retired)
            XCTAssertEqual(pricing?.outputPerMillion, 2.8, retired)
            XCTAssertEqual(pricing?.modelLabel, retired, retired)
        }
        // 模型名缺失（未知模型）同样走 Flash 兜底，zhipu 分支永远有价。
        let unknownGlm = ModelPricingCatalog.pricing(for: nil, quotaProviderID: QuotaProviderID.zhipu)
        XCTAssertEqual(unknownGlm?.currency, .cny)
        XCTAssertEqual(unknownGlm?.inputPerMillion, 0.8)
        XCTAssertEqual(unknownGlm?.cacheReadPerMillion, 0.23)
        XCTAssertEqual(unknownGlm?.outputPerMillion, 2.8)
        XCTAssertEqual(unknownGlm?.modelLabel, "GLM-5.3-Flash(兜底)")

        let glm53Flash = ModelPricingCatalog.pricing(for: "GLM-5.3-Flash", quotaProviderID: QuotaProviderID.zhipu)
        XCTAssertEqual(glm53Flash?.currency, .cny)
        XCTAssertEqual(glm53Flash?.inputPerMillion, 0.8)
        XCTAssertEqual(glm53Flash?.cacheReadPerMillion, 0.23)
        XCTAssertEqual(glm53Flash?.outputPerMillion, 2.8)

        let deepseekFlash = ModelPricingCatalog.pricing(
            for: "deepseek-v4-flash", quotaProviderID: QuotaProviderID.deepseek
        )
        let deepseekPro = ModelPricingCatalog.pricing(
            for: "deepseek-v4-pro", quotaProviderID: QuotaProviderID.deepseek
        )
        XCTAssertEqual(deepseekFlash?.currency, .cny)
        XCTAssertEqual(deepseekFlash?.inputPerMillion, 1)
        XCTAssertEqual(deepseekFlash?.cacheReadPerMillion, 0.02)
        XCTAssertEqual(deepseekFlash?.outputPerMillion, 4)
        XCTAssertEqual(deepseekPro?.currency, .cny)
        XCTAssertEqual(deepseekPro?.inputPerMillion, 4.5)
        XCTAssertEqual(deepseekPro?.cacheReadPerMillion, 0.15)
        XCTAssertEqual(deepseekPro?.outputPerMillion, 13.5)
        XCTAssertEqual(ModelPricingCatalog.lastUpdated, "2026-10-01",
                       "与 ModelPricingJSONTests.testPricingJSONIntegrity 保持一致：改定价目录要同步改这两处")
    }
}
