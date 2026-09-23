import XCTest
import Foundation
@testable import LLM_monitor

// ModelPricing.json 资源与数据完整性守门测试。
// 价格数据已脱离 Swift 代码：这里用独立于 ModelPricingCatalog 的本地解码模型
// 直接校验随 app 打包的 JSON，保证未来只改 JSON 时 schema 不会被破坏；
// 匹配语义（首条命中 / 精确匹配 / 兜底 / 下划线归一化 / matchAll AND）另设
// 边界断言，防止引擎行为随迁移漂移。
final class ModelPricingJSONTests: XCTestCase {

    // MARK: - 独立解码模型（与 app 内私有 Decodable 结构解耦，避免同义反复）

    private struct CatalogProbe: Decodable {
        let lastUpdated: String
        let providers: [String: ProviderProbe]
    }

    private struct ProviderProbe: Decodable {
        let models: [EntryProbe]
        let fallback: EntryProbe?
    }

    private struct EntryProbe: Decodable {
        let match: String?
        let keywords: [String]?
        let matchAll: [String]?
        let label: String
        let currency: String
        let inputPerMillion: Double
        let cacheReadPerMillion: Double
        let outputPerMillion: Double
    }

    private func loadPricingJSON() throws -> CatalogProbe {
        // 测试 target 没有自己的 resource bundle accessor：这里的 Bundle.module
        // 经 @testable import LLM_monitor 解析到 app target 生成的 accessor，
        // 因此实际校验的是 ModelPricing.json 随 app target 打包（Package.swift
        // 的 resources 声明），而不是测试 target 自己的资源。
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "ModelPricing", withExtension: "json"),
            "ModelPricing.json 必须随 app target 打包（Package.swift resources 声明）"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CatalogProbe.self, from: data)
    }

    // MARK: - 资源打包

    /// Package.swift 资源声明的守门：Bundle.module 必须能取到 ModelPricing.json。
    func testPricingJSONIsBundledAndParsable() throws {
        let catalog = try loadPricingJSON()
        XCTAssertFalse(catalog.providers.isEmpty)
        XCTAssertEqual(ModelPricingCatalog.lastUpdated, catalog.lastUpdated,
                       "静态 lastUpdated 必须来自 JSON，而不是 Swift 常量")
    }

    // MARK: - 数据完整性

    func testPricingJSONIntegrity() throws {
        let catalog = try loadPricingJSON()
        XCTAssertEqual(catalog.lastUpdated, "2026-09-23")

        let requiredProviders = ["minimax", "openai", "antigravity", "zhipu", "deepseek"]
        for providerID in requiredProviders {
            XCTAssertNotNil(catalog.providers[providerID], "价目表缺少 provider \(providerID)")
        }

        for (providerID, provider) in catalog.providers {
            var seenKeywords = Set<String>()
            for entry in provider.models {
                XCTAssertFalse(entry.label.isEmpty, "\(providerID) 条目 label 不能为空")
                for (name, price) in [("input", entry.inputPerMillion),
                                      ("cacheRead", entry.cacheReadPerMillion),
                                      ("output", entry.outputPerMillion)] {
                    XCTAssertGreaterThan(price, 0, "\(providerID)/\(entry.label) 的 \(name) 价必须 > 0")
                }
                XCTAssertTrue(["USD", "CNY"].contains(entry.currency),
                              "\(providerID)/\(entry.label) 币种非法：\(entry.currency)")

                // 匹配机制：keywords（OR）与 matchAll（AND）至少一个非空；
                // 两者同时提供时不得互相重复，否则 AND / OR 语义纠缠难以推理。
                let keywords = entry.keywords ?? []
                let matchAll = entry.matchAll ?? []
                XCTAssertFalse(
                    keywords.isEmpty && matchAll.isEmpty,
                    "\(providerID)/\(entry.label) keywords 与 matchAll 不能同时为空"
                )
                if !keywords.isEmpty && !matchAll.isEmpty {
                    let matchAllSet = Set(matchAll.map { $0.lowercased() })
                    for keyword in keywords where matchAllSet.contains(keyword.lowercased()) {
                        XCTFail("\(providerID)/\(entry.label) keyword \(keyword) 与 matchAll 重复")
                    }
                }
                for keyword in keywords {
                    // 同 provider 内 keyword 重复会因"首条命中"顺序产生遮蔽，属数据错误。
                    XCTAssertTrue(
                        seenKeywords.insert(keyword.lowercased()).inserted,
                        "\(providerID) 内 keyword \(keyword) 重复"
                    )
                    // 引擎统一在小写域匹配：大写 contains 关键词永远命中不了（死条目），
                    // 大写 exact 关键词更会直接失配，因此所有 keywords 都必须是小写 slug。
                    XCTAssertEqual(keyword, keyword.lowercased(),
                                   "\(providerID)/\(entry.label) keyword 必须是小写 slug：\(keyword)")
                }
                if entry.match == "exact" {
                    XCTAssertEqual(
                        keywords.count, 1,
                        "\(providerID)/\(entry.label) exact 条目只应携带一个全等关键词"
                    )
                }
                // 已知盲区（有意为之）：matchAll 组合关键词暂不参与跨条目去重检测 ——
                // 不同条目的 matchAll 条件之间、matchAll 与其他条目 keywords 之间的
                // 跨条目重复不在本测试覆盖范围内。
                for condition in matchAll {
                    XCTAssertFalse(condition.isEmpty, "\(providerID)/\(entry.label) matchAll 含空条件")
                    // 与 keywords 同理：matchAll 也在小写域求值，大写条件是死条件。
                    XCTAssertEqual(condition, condition.lowercased(),
                                   "\(providerID)/\(entry.label) matchAll 条件必须是小写 slug：\(condition)")
                }
            }

            if let fallback = provider.fallback {
                XCTAssertFalse(fallback.label.isEmpty, "\(providerID) 兜底 label 不能为空")
                for (name, price) in [("input", fallback.inputPerMillion),
                                      ("cacheRead", fallback.cacheReadPerMillion),
                                      ("output", fallback.outputPerMillion)] {
                    XCTAssertGreaterThan(price, 0, "\(providerID) 兜底 \(name) 价必须 > 0")
                }
                XCTAssertTrue(["USD", "CNY"].contains(fallback.currency), "\(providerID) 兜底币种非法")
            }
        }
    }

    // MARK: - 新增模型：Gemini 3.8 Flash（与 3.7 同价，introductory 至 2026-12-31）

    func testGemini38FlashPricingMatches37() {
        for modelName in ["gemini-3.8-flash", "GEMINI-3.8-Flash", "google_gemini_3.8_flash"] {
            let pricing = ModelPricingCatalog.pricing(for: modelName, quotaProviderID: QuotaProviderID.antigravity)
            XCTAssertNotNil(pricing, modelName)
            XCTAssertEqual(pricing?.currency, .usd, modelName)
            XCTAssertEqual(pricing?.inputPerMillion, 0.75, modelName)
            XCTAssertEqual(pricing?.cacheReadPerMillion, 0.075, modelName)
            XCTAssertEqual(pricing?.outputPerMillion, 3.75, modelName)
            XCTAssertEqual(pricing?.modelLabel, modelName, "modelLabel 必须保留样本原始模型名")
        }

        let flash38 = ModelPricingCatalog.pricing(for: "gemini-3.8-flash", quotaProviderID: QuotaProviderID.antigravity)
        let flash37 = ModelPricingCatalog.pricing(for: "gemini-3.7-flash", quotaProviderID: QuotaProviderID.antigravity)
        XCTAssertEqual(flash38?.inputPerMillion, flash37?.inputPerMillion)
        XCTAssertEqual(flash38?.cacheReadPerMillion, flash37?.cacheReadPerMillion)
        XCTAssertEqual(flash38?.outputPerMillion, flash37?.outputPerMillion)
    }

    // MARK: - zhipu 兜底：模型名缺失 / 未知仍永远有价

    func testZhipuFallbackCoversMissingAndUnknownModelNames() {
        // 未知模型：兜底价 + 原始模型名作为 label。
        let unknown = ModelPricingCatalog.pricing(for: "brand-new-glm-9", quotaProviderID: QuotaProviderID.zhipu)
        XCTAssertEqual(unknown?.currency, .cny)
        XCTAssertEqual(unknown?.inputPerMillion, 0.8)
        XCTAssertEqual(unknown?.cacheReadPerMillion, 0.23)
        XCTAssertEqual(unknown?.outputPerMillion, 2.8)
        XCTAssertEqual(unknown?.modelLabel, "brand-new-glm-9")

        // 模型名缺失：兜底价 + JSON 兜底 label。
        let missing = ModelPricingCatalog.pricing(for: nil, quotaProviderID: QuotaProviderID.zhipu)
        XCTAssertEqual(missing?.inputPerMillion, 0.8)
        XCTAssertEqual(missing?.cacheReadPerMillion, 0.23)
        XCTAssertEqual(missing?.outputPerMillion, 2.8)
        XCTAssertEqual(missing?.modelLabel, "GLM-5.3-Flash(兜底)")

        // estimate 口径：zhipu 永远全覆盖，不出现"部分计价"。
        let sample = LocalTokenUsageSample(
            completedAt: Date(),
            modelName: nil,
            promptID: "missing-name",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0
        )
        let estimate = ModelPricingCatalog.estimate(samples: [sample], quotaProviderID: QuotaProviderID.zhipu)
        XCTAssertEqual(estimate.coverage, .fullyPriced)
        XCTAssertNotNil(estimate.value)
    }

    // MARK: - antigravity 下划线归一化

    func testAntigravityUnderscoreNormalizationStillApplies() {
        let enumStyle = ModelPricingCatalog.pricing(
            for: "MODEL_OPENAI_GPT_OSS_120B_MEDIUM", quotaProviderID: QuotaProviderID.antigravity
        )
        XCTAssertEqual(enumStyle?.inputPerMillion, 0.09)
        XCTAssertEqual(enumStyle?.cacheReadPerMillion, 0.009)
        XCTAssertEqual(enumStyle?.outputPerMillion, 0.36)

        let plain = ModelPricingCatalog.pricing(for: "gpt_oss_120b", quotaProviderID: QuotaProviderID.antigravity)
        XCTAssertEqual(plain?.inputPerMillion, 0.09)
        XCTAssertEqual(plain?.modelLabel, "gpt_oss_120b")
    }

    // MARK: - deepseek matchAll AND 语义

    func testDeepseekMatchAllKeepsAndSemantics() {
        // matchAll 是 AND：单独的 "flash" / "pro" 不含 deepseek，不能命中
        // （验证 AND 没有退化成 OR）。
        XCTAssertNil(ModelPricingCatalog.pricing(for: "flash", quotaProviderID: QuotaProviderID.deepseek))
        XCTAssertNil(ModelPricingCatalog.pricing(for: "pro", quotaProviderID: QuotaProviderID.deepseek))
        XCTAssertNil(ModelPricingCatalog.pricing(for: "deepseek", quotaProviderID: QuotaProviderID.deepseek))

        // 同时含 deepseek 与 flash 的组合命中 Flash 档。
        let combo = ModelPricingCatalog.pricing(for: "deepseek-lake-flash", quotaProviderID: QuotaProviderID.deepseek)
        XCTAssertEqual(combo?.currency, .cny)
        XCTAssertEqual(combo?.inputPerMillion, 1)
        XCTAssertEqual(combo?.cacheReadPerMillion, 0.02)
        XCTAssertEqual(combo?.outputPerMillion, 4)

        // keywords（OR）机制保持：显式 slug 直接命中。
        XCTAssertEqual(
            ModelPricingCatalog.pricing(for: "deepseek-chat", quotaProviderID: QuotaProviderID.deepseek)?.inputPerMillion,
            1
        )
        XCTAssertEqual(
            ModelPricingCatalog.pricing(for: "deepseek-reasoner", quotaProviderID: QuotaProviderID.deepseek)?.inputPerMillion,
            1
        )

        // pro 组合同样要求 AND。
        let pro = ModelPricingCatalog.pricing(for: "deepseek-v3-pro", quotaProviderID: QuotaProviderID.deepseek)
        XCTAssertEqual(pro?.inputPerMillion, 4.5)
        XCTAssertEqual(pro?.cacheReadPerMillion, 0.15)
        XCTAssertEqual(pro?.outputPerMillion, 13.5)
    }

    // MARK: - DeepSeek 条目顺序：flash 条目先于 pro 条目

    /// `deepseek-pro-flash` 同时满足 Flash 与 Pro 两组 matchAll 条件；JSON 中
    /// flash 条目先于 pro 条目，"首条命中"语义必须让它落在 Flash 价（1/0.02/4）。
    /// 若调换 JSON 中两条目的顺序，本测试必须变红。
    func testDeepseekProFlashHitsFlashPriceByEntryOrder() {
        let pricing = ModelPricingCatalog.pricing(for: "deepseek-pro-flash", quotaProviderID: QuotaProviderID.deepseek)
        XCTAssertNotNil(pricing, "deepseek-pro-flash 必须命中 Flash 条目（数组顺序敏感）")
        XCTAssertEqual(pricing?.currency, .cny)
        XCTAssertEqual(pricing?.inputPerMillion, 1)
        XCTAssertEqual(pricing?.cacheReadPerMillion, 0.02)
        XCTAssertEqual(pricing?.outputPerMillion, 4)
    }

    // MARK: - minimax 只保留 M3：M2 系列退休（历史用量显示未定价，有意行为）

    func testMinimaxRetiredM2SeriesAreUnpricedAndM3StillPriced() {
        // M2 系列已退休：highspeed / 标准 / 精确 "m2" 一律不再有价。
        // matchAll AND 语义（highspeed 只有叠加在 m2.x 家族上才有价）由
        // testDeepseekMatchAllKeepsAndSemantics 继续守门。
        for retired in ["MiniMax-M2.7-highspeed", "MiniMax-M2.5-highspeed", "MiniMax-M2.1-highspeed",
                        "MiniMax-M2.7", "MiniMax-M2.5", "MiniMax-M2.1", "M2"] {
            XCTAssertNil(
                ModelPricingCatalog.pricing(for: retired, quotaProviderID: QuotaProviderID.minimax),
                "\(retired) 已退休，必须保持未定价"
            )
        }

        // M3 条目仍在（含 "minimax/" 前缀的原始模型名也能 contains 命中）。
        let m3 = ModelPricingCatalog.pricing(for: "minimax/MiniMax-M3", quotaProviderID: QuotaProviderID.minimax)
        XCTAssertEqual(m3?.inputPerMillion, 2.1)
        XCTAssertEqual(m3?.cacheReadPerMillion, 0.42)
        XCTAssertEqual(m3?.outputPerMillion, 8.4)
    }

    // MARK: - 新增模型：Gemini 3.1 Pro；Gemini 2.5 系列退休

    func testAntigravityGemini31ProPricingAndRetiredGemini25Series() {
        let pro = ModelPricingCatalog.pricing(for: "gemini-3.1-pro", quotaProviderID: QuotaProviderID.antigravity)
        XCTAssertEqual(pro?.currency, .usd)
        XCTAssertEqual(pro?.inputPerMillion, 2)
        XCTAssertEqual(pro?.cacheReadPerMillion, 0.2)
        XCTAssertEqual(pro?.outputPerMillion, 12)
        XCTAssertEqual(pro?.modelLabel, "gemini-3.1-pro", "modelLabel 必须保留样本原始模型名")

        // 引擎在小写域匹配，大写写法同样命中同一条目。
        let upper = ModelPricingCatalog.pricing(for: "GEMINI-3.1-Pro", quotaProviderID: QuotaProviderID.antigravity)
        XCTAssertEqual(upper?.inputPerMillion, 2)

        // Gemini 2.5 系列已退休：历史用量显示未定价（有意行为），含下划线变体。
        for retired in ["gemini-2.5-pro", "gemini-2.5-flash", "google_gemini_2_5_flash"] {
            XCTAssertNil(
                ModelPricingCatalog.pricing(for: retired, quotaProviderID: QuotaProviderID.antigravity),
                "\(retired) 已退休，必须保持未定价"
            )
        }
    }

    // MARK: - 新增模型：GPT-6 Sol 与 GPT-6 Luna

    func testOpenAIGPT6SolAndLunaPricing() {
        let sol = ModelPricingCatalog.pricing(for: "gpt-6-sol", quotaProviderID: QuotaProviderID.openAI)
        XCTAssertEqual(sol?.currency, .usd)
        XCTAssertEqual(sol?.inputPerMillion, 2)
        XCTAssertEqual(sol?.cacheReadPerMillion, 0.2)
        XCTAssertEqual(sol?.outputPerMillion, 10)
        XCTAssertEqual(sol?.modelLabel, "gpt-6-sol")

        let luna = ModelPricingCatalog.pricing(for: "gpt-6-luna", quotaProviderID: QuotaProviderID.openAI)
        XCTAssertEqual(luna?.currency, .usd)
        XCTAssertEqual(luna?.inputPerMillion, 0.1)
        XCTAssertEqual(luna?.cacheReadPerMillion, 0.01)
        XCTAssertEqual(luna?.outputPerMillion, 0.5)
        XCTAssertEqual(luna?.modelLabel, "gpt-6-luna")
    }
}
