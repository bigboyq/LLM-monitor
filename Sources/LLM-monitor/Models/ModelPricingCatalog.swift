import Foundation

// 定价子系统 —— 从 ProviderClientModel.swift 拆出的独立文件。
// 依赖方向：ModelPricingCatalog 只消费 LocalTokenUsageSample / TokenUsageBuckets /
// PeakWindow，被 ProviderClientModel / Views / SettingsView 消费。
// 价格数据全部来自随 app 打包的 Resources/ModelPricing.json（Package.swift 以
// process resource 声明）：调价 / 新增 / 退休模型只改 JSON，并同步测试与 spec；
// 本文件只保留匹配引擎、zhipu 兜底顺序与 DeepSeek 高峰倍率逻辑。

/// The currencies used by the public API price lists. Values are intentionally
/// kept in their published currency instead of silently applying an exchange
/// rate that could make a cost estimate look more precise than it is.
/// Codable 供 ModelPricing.json 反序列化使用（rawValue 即 JSON 中的币种字符串）。
enum ModelPriceCurrency: String, Codable, Equatable, Sendable {
    case usd = "USD"
    case cny = "CNY"

    var symbol: String {
        switch self {
        case .usd: return "$"
        case .cny: return "¥"
        }
    }
}

struct ModelTokenPricing: Equatable, Sendable {
    let modelLabel: String
    let currency: ModelPriceCurrency
    let inputPerMillion: Double
    let cacheReadPerMillion: Double
    let outputPerMillion: Double
}

/// 估算的计价覆盖度。金额只覆盖 `pricedModelNames` 的 sample；
/// `partiallyPriced` 时 UI 必须提示“部分计价”，避免把金额误读为全部 Token 的成本。
enum CostCoverage: Equatable, Sendable {
    /// 没有任何 sample 被计价（未知模型 / 模型名缺失 / 币种冲突吞掉全部）。
    case noPricedSamples
    /// 一部分 sample 已计价，另一部分未计价；`value` 只覆盖已计价部分。
    case partiallyPriced
    /// 全部 sample 都已按同一币种计价。
    case fullyPriced
}

struct ModelCostEstimate: Equatable, Sendable {
    let value: Double?
    let currency: ModelPriceCurrency?
    let pricedModelNames: [String]
    let unpricedModelNames: [String]

    var hasPrice: Bool { value != nil && currency != nil }

    var coverage: CostCoverage {
        if value == nil || currency == nil {
            return .noPricedSamples
        }
        return unpricedModelNames.isEmpty ? .fullyPriced : .partiallyPriced
    }

    /// 菜单 / 7 天表格共用的金额文案：
    /// - 全部计价 → `¥1.23`
    /// - 部分计价 → `¥1.23（部分计价）`，金额只覆盖已计价模型
    /// - 无可计价 sample → `未定价`
    var displayText: String {
        guard let value, let currency else { return "未定价" }
        let amount = String(format: "%@%.2f", currency.symbol, value)
        if case .partiallyPriced = coverage {
            return amount + "（部分计价）"
        }
        return amount
    }
}

/// 未定价模型的实际用量明细，供客户端设置页解释“未知模型”的影响范围。
struct UnpricedModelUsage: Equatable, Sendable, Identifiable {
    let modelName: String
    let totalTokens: Int
    let sampleCount: Int

    var id: String { modelName }
}

// MARK: - ModelPricing.json 反序列化模型（随 app 打包的唯一价格数据源）

/// ModelPricing.json 的顶层结构；`providers` 以 QuotaProviderID 字符串为 key。
private struct PricingCatalogDocument: Decodable, Sendable {
    let lastUpdated: String
    let providers: [String: ProviderPricing]
}

/// 单个 provider 的价目。
private struct ProviderPricing: Decodable, Sendable {
    /// 条目数组顺序即求值顺序，首条命中即返回（zhipu Flash 先于 GLM-5.3、
    /// minimax M3 先于 M2.x 的顺序敏感语义依赖这一点）。
    let models: [PricingEntry]
    /// 匹配前把模型名中的 `_` 替换为 `-`（antigravity 的 gpt_oss_120b 需要）。
    let normalizeUnderscores: Bool?
    /// 兜底价：条目全部未命中时返回（zhipu 的"GLM-5.3-Flash(兜底)"）。
    let fallback: PricingEntry?
}

/// 价目条目：`keywords`（OR 语义，`match` 决定 contains / exact）与可选
/// `matchAll`（AND 语义 contains 数组）两组匹配机制并存，任一命中即匹配。
private struct PricingEntry: Decodable, Sendable {
    enum MatchMode: String, Decodable, Sendable {
        case exact
        case contains
    }

    let match: MatchMode?
    let keywords: [String]?
    let matchAll: [String]?
    let label: String
    let currency: ModelPriceCurrency
    let inputPerMillion: Double
    let cacheReadPerMillion: Double
    let outputPerMillion: Double

    /// 在已 lowercased（必要时已做下划线归一化）的模型名上求值。
    /// keywords 比较统一在小写域进行，因此 JSON 中 keywords 必须是小写 slug。
    func matches(lowercasedModel: String) -> Bool {
        let mode = match ?? .contains
        if let keywords, !keywords.isEmpty,
           keywords.contains(where: { mode == .exact ? lowercasedModel == $0 : lowercasedModel.contains($0) }) {
            return true
        }
        if let matchAll, !matchAll.isEmpty,
           matchAll.allSatisfy({ lowercasedModel.contains($0) }) {
            return true
        }
        return false
    }
}

/// A small, reviewable snapshot of public model prices used by the settings
/// summary. Prices live in the bundled `ModelPricing.json` so that price
/// changes, new or retired models only touch that file (plus tests and spec
/// docs); local usage must remain available when offline, and unknown model
/// names are reported instead of guessed.
enum ModelPricingCatalog {
    /// 解析失败策略：bundle 内 JSON 是开发者受控资源且有测试守门
    /// （ModelPricingJSONTests 校验可解析性与 schema 完整性），解析失败属于
    /// 打包 / 数据错误而非运行环境问题，因此直接崩溃暴露问题，而不是静默
    /// 降级成"全部未定价"——那会让所有 provider 显示未定价并掩盖真正的错误。
    private static let catalog: PricingCatalogDocument = loadCatalog()

    static let lastUpdated = catalog.lastUpdated

    private static func loadCatalog() -> PricingCatalogDocument {
        guard let url = Bundle.module.url(forResource: "ModelPricing", withExtension: "json") else {
            preconditionFailure("ModelPricing.json 缺失：Bundle.module 中找不到定价目录资源，请检查 Package.swift 的 resources 声明")
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(PricingCatalogDocument.self, from: data)
        } catch {
            preconditionFailure("ModelPricing.json 解析失败：\(error)。定价 JSON 随 app 打包、由测试守门，解析失败说明数据或 schema 损坏；直接崩溃暴露问题，不做静默降级")
        }
    }

    static func estimate(
        samples: [LocalTokenUsageSample],
        quotaProviderID: String,
        deepseekPeakWindow: DeepseekPeakWindow = .defaultWindow
    ) -> ModelCostEstimate {
        var value = 0.0
        var currency: ModelPriceCurrency?
        var pricedModels = Set<String>()
        var unpricedModels = Set<String>()

        for sample in samples {
            let modelName = sample.modelName?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pricing = pricing(for: modelName, quotaProviderID: quotaProviderID) else {
                unpricedModels.insert(modelName.flatMap { $0.isEmpty ? nil : $0 } ?? "未知模型")
                continue
            }

            if let currency, currency != pricing.currency {
                // A single provider should normally have one currency. If a
                // future provider mixes currencies, do not add incompatible
                // amounts together: the conflicting model lands in
                // unpricedModels, so the estimate reports partial coverage
                // (CostCoverage.partiallyPriced) instead of a fake total.
                // 当前价格目录中每个 provider 只有一种币种，此分支为防御性设计；
                // 一旦有 provider 真的开始混币种，coverage 会自动提示部分计价。
                unpricedModels.insert(pricing.modelLabel)
                continue
            }
            currency = pricing.currency
            pricedModels.insert(pricing.modelLabel)

            let components = tokenComponents(for: sample)
            let multiplier = pricingMultiplier(
                quotaProviderID: quotaProviderID,
                at: sample.completedAt,
                deepseekPeakWindow: deepseekPeakWindow
            )
            value += Double(components.uncached) * pricing.inputPerMillion * multiplier / 1_000_000
            value += Double(components.cached) * pricing.cacheReadPerMillion * multiplier / 1_000_000
            value += Double(components.output) * pricing.outputPerMillion * multiplier / 1_000_000
        }

        return ModelCostEstimate(
            value: currency == nil ? nil : value,
            currency: currency,
            pricedModelNames: pricedModels.sorted(),
            unpricedModelNames: unpricedModels.sorted()
        )
    }

    static func estimateByDay(
        samples: [LocalTokenUsageSample],
        quotaProviderID: String,
        calendar: Calendar = .current,
        deepseekPeakWindow: DeepseekPeakWindow = .defaultWindow
    ) -> [Date: ModelCostEstimate] {
        let grouped = Dictionary(grouping: samples) {
            calendar.startOfDay(for: $0.completedAt)
        }
        return grouped.mapValues {
            estimate(
                samples: $0,
                quotaProviderID: quotaProviderID,
                deepseekPeakWindow: deepseekPeakWindow
            )
        }
    }

    /// 用户给定的是非高峰价；现有 DeepSeek 高峰窗口规则规定高峰统一乘 2。
    private static func pricingMultiplier(
        quotaProviderID: String,
        at date: Date,
        deepseekPeakWindow: DeepseekPeakWindow
    ) -> Double {
        guard quotaProviderID == QuotaProviderID.deepseek else { return 1 }
        if case .peak = deepseekPeakWindow.status(at: date, calendar: PeakWindow.beijingCalendar) {
            return 2
        }
        return 1
    }

    /// Split the persisted sample into the normalized estimate buckets.
    /// `TokenUsageBuckets` is the accounting boundary: samples retain their
    /// historical cache-inclusive input field, while pricing sees uncached
    /// input, cache-read, output, and reasoning as disjoint buckets.
    static func tokenComponents(
        for sample: LocalTokenUsageSample
    ) -> (uncached: Int, cached: Int, output: Int) {
        let buckets = TokenUsageBuckets.fromSample(sample)
        return (buckets.input, buckets.cacheRead, buckets.billableOutput)
    }

    static func pricing(
        for modelName: String?,
        quotaProviderID: String
    ) -> ModelTokenPricing? {
        let model = modelName?.lowercased() ?? ""
        // zhipu 分支永远有价（GLM-5.2 及以下已退休，未知模型也按 Flash 兜底），
        // 包括模型名缺失的样本 —— 必须放在通用 empty guard 之前。
        if quotaProviderID == QuotaProviderID.zhipu {
            return resolvedPricing(
                provider: catalog.providers[QuotaProviderID.zhipu],
                model: model,
                modelName: modelName
            )
        }
        guard !model.isEmpty else { return nil }
        return resolvedPricing(provider: catalog.providers[quotaProviderID], model: model, modelName: modelName)
    }

    /// 按条目数组顺序求值，首条命中即返回；条目全部未命中时回退 provider 级
    /// 兜底价。普通条目的 modelLabel 用样本原始模型名（保留大小写），兜底条目
    /// 在模型名缺失 / 为空时才用 JSON 兜底 label。
    private static func resolvedPricing(
        provider: ProviderPricing?,
        model: String,
        modelName: String?
    ) -> ModelTokenPricing? {
        guard let provider else { return nil }
        let normalizedModel = provider.normalizeUnderscores == true
            ? model.replacingOccurrences(of: "_", with: "-")
            : model
        for entry in provider.models where entry.matches(lowercasedModel: normalizedModel) {
            return ModelTokenPricing(
                modelLabel: modelName ?? entry.label,
                currency: entry.currency,
                inputPerMillion: entry.inputPerMillion,
                cacheReadPerMillion: entry.cacheReadPerMillion,
                outputPerMillion: entry.outputPerMillion
            )
        }
        guard let fallback = provider.fallback else { return nil }
        return ModelTokenPricing(
            modelLabel: modelName.flatMap { $0.isEmpty ? nil : $0 } ?? fallback.label,
            currency: fallback.currency,
            inputPerMillion: fallback.inputPerMillion,
            cacheReadPerMillion: fallback.cacheReadPerMillion,
            outputPerMillion: fallback.outputPerMillion
        )
    }
}
