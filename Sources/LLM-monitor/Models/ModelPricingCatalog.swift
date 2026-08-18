import Foundation

// 定价子系统 —— 从 ProviderClientModel.swift 拆出的独立文件。
// 依赖方向：ModelPricingCatalog 只消费 LocalTokenUsageSample / TokenUsageBuckets /
// PeakWindow，被 ProviderClientModel / Views / SettingsView 消费。

/// The currencies used by the public API price lists. Values are intentionally
/// kept in their published currency instead of silently applying an exchange
/// rate that could make a cost estimate look more precise than it is.
enum ModelPriceCurrency: String, Equatable, Sendable {
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

/// A small, reviewable snapshot of public model prices used by the settings
/// summary. It is deliberately static: local usage must remain available when
/// offline, and unknown model names are reported instead of guessed.
enum ModelPricingCatalog {
    static let lastUpdated = "2026-08-17"

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
        guard !model.isEmpty else { return nil }

        switch quotaProviderID {
        case QuotaProviderID.minimax:
            if model.contains("m3") {
                // MiniMax-M3 和 minimax/MiniMax-M3 是同一模型。价格为 MiniMax
                // 中文官方公开价（CNY 直接给出，不再用 USD × 汇率换算，避免汇率
                // 漂移让估算值跟官方对不上）。>512K 高价档不参与：本地账本不
                // 保留请求上下文长度。
                return ModelTokenPricing(
                    modelLabel: modelName ?? "MiniMax-M3",
                    currency: .cny,
                    inputPerMillion: 2.1,
                    cacheReadPerMillion: 0.42,
                    outputPerMillion: 8.4
                )
            }
            if model.contains("m2.7") || model.contains("m2.5") || model.contains("m2.1") || model == "m2" {
                let highspeed = model.contains("highspeed")
                return ModelTokenPricing(
                    modelLabel: modelName ?? "MiniMax",
                    currency: .cny,
                    inputPerMillion: highspeed ? 4.2 : 2.1,
                    cacheReadPerMillion: 0.21,
                    outputPerMillion: highspeed ? 16.8 : 8.4
                )
            }

        case QuotaProviderID.openAI:
            if model.contains("gpt-5.5") {
                return ModelTokenPricing(modelLabel: modelName ?? "GPT-5.5", currency: .usd, inputPerMillion: 5, cacheReadPerMillion: 0.5, outputPerMillion: 30)
            }
            if model.contains("gpt-5.6-sol") {
                return ModelTokenPricing(modelLabel: modelName ?? "GPT-5.6 Sol", currency: .usd, inputPerMillion: 5, cacheReadPerMillion: 0.5, outputPerMillion: 30)
            }
            if model.contains("gpt-5.6-terra") {
                return ModelTokenPricing(modelLabel: modelName ?? "GPT-5.6 Terra", currency: .usd, inputPerMillion: 2, cacheReadPerMillion: 0.2, outputPerMillion: 12)
            }
            if model.contains("gpt-5.6-luna") {
                return ModelTokenPricing(modelLabel: modelName ?? "GPT-5.6 Luna", currency: .usd, inputPerMillion: 0.2, cacheReadPerMillion: 0.02, outputPerMillion: 1.2)
            }
        case QuotaProviderID.antigravity:
            if model.contains("gemini-3.7-flash") || model.contains("gemini-3.6-flash") {
                return ModelTokenPricing(modelLabel: modelName ?? "Gemini Flash 3.x", currency: .usd, inputPerMillion: 0.75, cacheReadPerMillion: 0.075, outputPerMillion: 3.75)
            }
            if model.contains("gemini-2.5-pro") {
                return ModelTokenPricing(modelLabel: modelName ?? "Gemini 2.5 Pro", currency: .usd, inputPerMillion: 1.25, cacheReadPerMillion: 0.3125, outputPerMillion: 10)
            }
            if model.contains("gemini-2.5-flash") {
                return ModelTokenPricing(modelLabel: modelName ?? "Gemini 2.5 Flash", currency: .usd, inputPerMillion: 0.3, cacheReadPerMillion: 0.03, outputPerMillion: 2.5)
            }
            if model.contains("claude-opus-4.6") || model.contains("claude-opus-4-6") {
                return ModelTokenPricing(modelLabel: modelName ?? "Claude Opus 4.6", currency: .usd, inputPerMillion: 5, cacheReadPerMillion: 0.5, outputPerMillion: 25)
            }
            if model.contains("claude-sonnet-4.6") || model.contains("claude-sonnet-4-6") {
                return ModelTokenPricing(modelLabel: modelName ?? "Claude Sonnet 4.6", currency: .usd, inputPerMillion: 3, cacheReadPerMillion: 0.3, outputPerMillion: 15)
            }
            let normalizedModel = model.replacingOccurrences(of: "_", with: "-")
            if normalizedModel.contains("gpt-oss-120b") {
                return ModelTokenPricing(modelLabel: modelName ?? "gpt-oss-120b", currency: .usd, inputPerMillion: 0.09, cacheReadPerMillion: 0.009, outputPerMillion: 0.36)
            }
            if model.contains("claude-4") || model.contains("claude-3.7-sonnet") {
                return ModelTokenPricing(modelLabel: modelName ?? "Claude Sonnet", currency: .usd, inputPerMillion: 3, cacheReadPerMillion: 0.3, outputPerMillion: 15)
            }
            if model.contains("claude-3.5-haiku") {
                return ModelTokenPricing(modelLabel: modelName ?? "Claude Haiku", currency: .usd, inputPerMillion: 0.8, cacheReadPerMillion: 0.08, outputPerMillion: 4)
            }
            if model.contains("gpt-4.1") {
                return ModelTokenPricing(modelLabel: modelName ?? "GPT-4.1", currency: .usd, inputPerMillion: 2, cacheReadPerMillion: 0.5, outputPerMillion: 8)
            }

        case QuotaProviderID.zhipu:
            if model.contains("glm-5.2") || model.contains("glm-5.3") {
                return ModelTokenPricing(modelLabel: modelName ?? "GLM-5.2/5.3", currency: .cny, inputPerMillion: 8, cacheReadPerMillion: 2, outputPerMillion: 28)
            }
            if model.contains("glm-4.5") {
                return ModelTokenPricing(modelLabel: modelName ?? "GLM-4.5", currency: .cny, inputPerMillion: 0.8, cacheReadPerMillion: 0, outputPerMillion: 2)
            }
            if model.contains("glm-4.7") {
                return ModelTokenPricing(modelLabel: modelName ?? "GLM-4.7", currency: .cny, inputPerMillion: 0.8, cacheReadPerMillion: 0, outputPerMillion: 2)
            }

        case QuotaProviderID.deepseek:
            // User-specified 2026-08-17 RMB off-peak prices. High-peak samples
            // are multiplied by 2 in pricingMultiplier above.
            if model.contains("deepseek-v4-flash")
                || model.contains("deepseek-chat")
                || model.contains("deepseek-reasoner")
                || (model.contains("deepseek") && model.contains("flash")) {
                return ModelTokenPricing(modelLabel: modelName ?? "DeepSeek Flash", currency: .cny, inputPerMillion: 1.5, cacheReadPerMillion: 0.05, outputPerMillion: 4.5)
            }
            if model.contains("deepseek-v4-pro") || (model.contains("deepseek") && model.contains("pro")) {
                return ModelTokenPricing(modelLabel: modelName ?? "DeepSeek Pro", currency: .cny, inputPerMillion: 4.5, cacheReadPerMillion: 0.15, outputPerMillion: 13.5)
            }

        default:
            break
        }
        return nil
    }
}

