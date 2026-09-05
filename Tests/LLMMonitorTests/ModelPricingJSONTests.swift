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
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "ModelPricing", withExtension: "json"),
            "ModelPricing.json 必须随 target 打包（Package.swift resources 声明）"
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
        XCTAssertEqual(catalog.lastUpdated, "2026-09-05")

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
                    if entry.match == "exact" {
                        XCTAssertEqual(keyword, keyword.lowercased(),
                                       "exact 条目的关键词必须与小写 slug 全等：\(keyword)")
                    }
                }
                for condition in matchAll {
                    XCTAssertFalse(condition.isEmpty, "\(providerID)/\(entry.label) matchAll 含空条件")
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
        XCTAssertEqual(combo?.inputPerMillion, 1.5)
        XCTAssertEqual(combo?.cacheReadPerMillion, 0.05)
        XCTAssertEqual(combo?.outputPerMillion, 4.5)

        // keywords（OR）机制保持：显式 slug 直接命中。
        XCTAssertEqual(
            ModelPricingCatalog.pricing(for: "deepseek-chat", quotaProviderID: QuotaProviderID.deepseek)?.inputPerMillion,
            1.5
        )
        XCTAssertEqual(
            ModelPricingCatalog.pricing(for: "deepseek-reasoner", quotaProviderID: QuotaProviderID.deepseek)?.inputPerMillion,
            1.5
        )

        // pro 组合同样要求 AND。
        let pro = ModelPricingCatalog.pricing(for: "deepseek-v3-pro", quotaProviderID: QuotaProviderID.deepseek)
        XCTAssertEqual(pro?.inputPerMillion, 4.5)
        XCTAssertEqual(pro?.cacheReadPerMillion, 0.15)
        XCTAssertEqual(pro?.outputPerMillion, 13.5)
    }

    // MARK: - minimax highspeed 与非 highspeed 命中不同条目

    func testMinimaxHighspeedAndStandardHitDistinctEntries() {
        let highspeed = ModelPricingCatalog.pricing(for: "MiniMax-M2.5-highspeed", quotaProviderID: QuotaProviderID.minimax)
        XCTAssertEqual(highspeed?.currency, .cny)
        XCTAssertEqual(highspeed?.inputPerMillion, 4.2)
        XCTAssertEqual(highspeed?.cacheReadPerMillion, 0.21)
        XCTAssertEqual(highspeed?.outputPerMillion, 16.8)
        XCTAssertEqual(highspeed?.modelLabel, "MiniMax-M2.5-highspeed")

        // matchAll AND 语义回归：highspeed 只有叠加在 m2.x 家族上才有价，
        // 纯 *highspeed* 模型（旧代码在 m2 分支外直接落到 nil）不得被计价。
        XCTAssertNil(
            ModelPricingCatalog.pricing(for: "minimax-video-highspeed", quotaProviderID: QuotaProviderID.minimax),
            "不含 m2.x 的 *highspeed* 模型必须保持未定价"
        )
        XCTAssertNil(
            ModelPricingCatalog.pricing(for: "highspeed", quotaProviderID: QuotaProviderID.minimax),
            "裸 highspeed 字符串必须保持未定价"
        )

        let m27Highspeed = ModelPricingCatalog.pricing(for: "MiniMax-M2.7-highspeed", quotaProviderID: QuotaProviderID.minimax)
        XCTAssertEqual(m27Highspeed?.inputPerMillion, 4.2)
        XCTAssertEqual(m27Highspeed?.cacheReadPerMillion, 0.21)
        XCTAssertEqual(m27Highspeed?.outputPerMillion, 16.8)

        // 无分隔符变体（"m2.7highspeed"）同样同时包含两个 AND 条件，命中 highspeed 档。
        let noSeparator = ModelPricingCatalog.pricing(for: "minimax-m2.7highspeed", quotaProviderID: QuotaProviderID.minimax)
        XCTAssertEqual(noSeparator?.inputPerMillion, 4.2)
        XCTAssertEqual(noSeparator?.cacheReadPerMillion, 0.21)
        XCTAssertEqual(noSeparator?.outputPerMillion, 16.8)

        let standard = ModelPricingCatalog.pricing(for: "MiniMax-M2.7", quotaProviderID: QuotaProviderID.minimax)
        XCTAssertEqual(standard?.inputPerMillion, 2.1)
        XCTAssertEqual(standard?.cacheReadPerMillion, 0.21)
        XCTAssertEqual(standard?.outputPerMillion, 8.4)

        let standard21 = ModelPricingCatalog.pricing(for: "MiniMax-M2.1", quotaProviderID: QuotaProviderID.minimax)
        XCTAssertEqual(standard21?.inputPerMillion, 2.1)
        XCTAssertEqual(standard21?.cacheReadPerMillion, 0.21)
        XCTAssertEqual(standard21?.outputPerMillion, 8.4)
        XCTAssertEqual(standard21?.modelLabel, "MiniMax-M2.1")

        // 精确匹配 "m2" 单独命中标准档。
        let bare = ModelPricingCatalog.pricing(for: "M2", quotaProviderID: QuotaProviderID.minimax)
        XCTAssertEqual(bare?.inputPerMillion, 2.1)
        XCTAssertEqual(bare?.cacheReadPerMillion, 0.21)
        XCTAssertEqual(bare?.outputPerMillion, 8.4)

        // M3 条目先于 M2 家族求值（顺序敏感），M3 不含 highspeed 语义。
        let m3 = ModelPricingCatalog.pricing(for: "minimax/MiniMax-M3", quotaProviderID: QuotaProviderID.minimax)
        XCTAssertEqual(m3?.inputPerMillion, 2.1)
        XCTAssertEqual(m3?.cacheReadPerMillion, 0.42)
        XCTAssertEqual(m3?.outputPerMillion, 8.4)
    }
}
