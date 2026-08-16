import Foundation

/// Stable IDs for the billing/quota side of the application.
///
/// These IDs intentionally do not describe where a token was generated. A
/// client can contribute usage to more than one quota provider.
enum QuotaProviderID {
    static let minimax = "minimax"
    static let openAI = "openai"
    static let antigravity = "antigravity"
    static let zhipu = "zhipu"
    static let deepseek = "deepseek"
}

/// Stable IDs for local applications that produce token usage.
enum ClientID {
    static let codex = "codex"
    static let antigravity = "antigravity"
    static let zcode = "zcode"
    static let openCode = "opencode"
    static let dsh = "dsh"
    static let minimaxCode = "minimax_code"
}

/// A client-to-quota relationship. The source aliases are normalized at the
/// scanner boundary; this type exists so the relationship is explicit instead
/// of being encoded as provider-specific `merge...` booleans.
struct ClientProviderBinding: Codable, Equatable, Identifiable, Sendable {
    let clientID: String
    let quotaProviderID: String
    var sourceProviderAliases: [String]
    var enabled: Bool

    var id: String { "(clientID):(quotaProviderID)" }

    init(
        clientID: String,
        quotaProviderID: String,
        sourceProviderAliases: [String] = [],
        enabled: Bool = true
    ) {
        self.clientID = clientID
        self.quotaProviderID = quotaProviderID
        self.sourceProviderAliases = sourceProviderAliases
        self.enabled = enabled
    }
}

/// Registry metadata for a local client. This is deliberately independent of
/// `FetcherDescriptor`, which describes remote quota fetchers.
struct ClientDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let iconSystemName: String
    let supportedQuotaProviderIDs: [String]
    let subtitle: String

    static let all: [ClientDescriptor] = [
        ClientDescriptor(
            id: ClientID.codex,
            displayName: "Codex",
            iconSystemName: "terminal",
            supportedQuotaProviderIDs: [QuotaProviderID.openAI, QuotaProviderID.deepseek, QuotaProviderID.minimax],
            subtitle: "Codex 本地会话与 token 用量"
        ),
        ClientDescriptor(
            id: ClientID.antigravity,
            displayName: "Antigravity",
            iconSystemName: "paperplane.circle.fill",
            supportedQuotaProviderIDs: [QuotaProviderID.antigravity],
            subtitle: "Antigravity 本地会话与 token 用量"
        ),
        ClientDescriptor(
            id: ClientID.zcode,
            displayName: "ZCode",
            iconSystemName: "chevron.left.forwardslash.chevron.right",
            supportedQuotaProviderIDs: [QuotaProviderID.zhipu],
            subtitle: "ZCode 本地数据库用量"
        ),
        ClientDescriptor(
            id: ClientID.openCode,
            displayName: "OpenCode",
            iconSystemName: "terminal",
            supportedQuotaProviderIDs: [
                QuotaProviderID.openAI,
                QuotaProviderID.antigravity,
                QuotaProviderID.zhipu,
                QuotaProviderID.minimax,
                QuotaProviderID.deepseek
            ],
            subtitle: "多 Provider 本地 token 账本"
        ),
        ClientDescriptor(
            id: ClientID.dsh,
            displayName: "DSH",
            iconSystemName: "terminal.fill",
            supportedQuotaProviderIDs: [QuotaProviderID.deepseek, QuotaProviderID.minimax, QuotaProviderID.zhipu],
            subtitle: "多 Provider session token 账本"
        ),
        ClientDescriptor(
            id: ClientID.minimaxCode,
            displayName: "MiniMax Code",
            iconSystemName: "bubble.left.and.text.bubble.right.fill",
            supportedQuotaProviderIDs: [QuotaProviderID.minimax, QuotaProviderID.openAI, QuotaProviderID.deepseek],
            subtitle: "MiniMax Code 本地用量"
        )
    ]
}

/// Provider-neutral daily token data used by the card and settings UI.
/// Scanner-specific daily structs are converted here before they reach views.
struct UnifiedDailyTokenUsage: Equatable, Codable, Sendable, Identifiable, LocalUsageDaily {
    let dayStart: Date
    let input: Int
    let cacheRead: Int
    let cacheWrite: Int
    let output: Int
    let reasoning: Int
    let turns: Int
    let rounds: Int

    var id: Date { dayStart }

    init<Daily: LocalUsageDaily>(_ day: Daily) {
        self.dayStart = day.dayStart
        self.input = day.input
        self.cacheRead = day.cacheRead
        self.cacheWrite = day.cacheWrite
        self.output = day.output
        self.reasoning = day.reasoning
        self.turns = day.turns
        self.rounds = day.rounds
    }

    init(
        dayStart: Date,
        input: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        output: Int = 0,
        reasoning: Int = 0,
        turns: Int = 0,
        rounds: Int = 0
    ) {
        self.dayStart = dayStart
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
        self.reasoning = reasoning
        self.turns = turns
        self.rounds = rounds
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            dayStart: lhs.dayStart,
            input: SaturatingArithmetic.add(lhs.input, rhs.input),
            cacheRead: SaturatingArithmetic.add(lhs.cacheRead, rhs.cacheRead),
            cacheWrite: SaturatingArithmetic.add(lhs.cacheWrite, rhs.cacheWrite),
            output: SaturatingArithmetic.add(lhs.output, rhs.output),
            reasoning: SaturatingArithmetic.add(lhs.reasoning, rhs.reasoning),
            turns: SaturatingArithmetic.add(lhs.turns, rhs.turns),
            rounds: SaturatingArithmetic.add(lhs.rounds, rhs.rounds)
        )
    }
}

/// One client's contribution to a quota card.
struct ClientUsageContribution: Equatable, Sendable {
    let clientID: String
    let displayName: String
    let dailyTokenUsage: [UnifiedDailyTokenUsage]
    let recentSamples: [LocalTokenUsageSample]
    let scannedAt: Date?

    var hasActivity: Bool {
        dailyTokenUsage.contains {
            $0.totalTokens > 0 || $0.turns > 0 || $0.rounds > 0
        } || !recentSamples.isEmpty
    }

    init<Daily: LocalUsageDaily>(
        clientID: String,
        displayName: String,
        dailyTokenUsage: [Daily],
        recentSamples: [LocalTokenUsageSample] = [],
        scannedAt: Date? = nil
    ) {
        self.clientID = clientID
        self.displayName = displayName
        self.dailyTokenUsage = dailyTokenUsage.map(UnifiedDailyTokenUsage.init)
        self.recentSamples = recentSamples
        self.scannedAt = scannedAt
    }
}

/// The UI-facing projection for one quota card. It intentionally exposes a
/// single aggregate token history while retaining contribution metadata for a
/// future details view.
struct ProviderUsageProjection: Equatable, Sendable {
    let contributions: [ClientUsageContribution]
    let dailyTokenUsage: [UnifiedDailyTokenUsage]
    let recentSamples: [LocalTokenUsageSample]
    let scannedAt: Date?

    var clientIDs: [String] { contributions.map(\.clientID) }
    var hasActivity: Bool {
        dailyTokenUsage.contains {
            $0.totalTokens > 0 || $0.turns > 0 || $0.rounds > 0
        } || !recentSamples.isEmpty
    }

    init(contributions: [ClientUsageContribution]) {
        self.contributions = contributions

        var dailyByDate: [Date: UnifiedDailyTokenUsage] = [:]
        for contribution in contributions {
            for day in contribution.dailyTokenUsage {
                dailyByDate[day.dayStart] = dailyByDate[day.dayStart].map { $0 + day } ?? day
            }
        }
        self.dailyTokenUsage = dailyByDate.values.sorted { $0.dayStart < $1.dayStart }
        self.recentSamples = contributions.flatMap(\.recentSamples)
        self.scannedAt = contributions.compactMap(\.scannedAt).max()
    }
}

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

struct ModelCostEstimate: Equatable, Sendable {
    let value: Double?
    let currency: ModelPriceCurrency?
    let pricedModelNames: [String]
    let unpricedModelNames: [String]

    var hasPrice: Bool { value != nil && currency != nil }
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
                // amounts together.
                unpricedModels.insert(pricing.modelLabel)
                continue
            }
            currency = pricing.currency
            pricedModels.insert(pricing.modelLabel)

            let input = max(0, sample.inputTokens)
            let cached = min(max(0, sample.cachedInputTokens), input)
            let uncached = input - cached
            let output = SaturatingArithmetic.sum(
                max(0, sample.outputTokens),
                max(0, sample.reasoningOutputTokens)
            )
            let multiplier = pricingMultiplier(
                quotaProviderID: quotaProviderID,
                at: sample.completedAt,
                deepseekPeakWindow: deepseekPeakWindow
            )
            value += Double(uncached) * pricing.inputPerMillion * multiplier / 1_000_000
            value += Double(cached) * pricing.cacheReadPerMillion * multiplier / 1_000_000
            value += Double(output) * pricing.outputPerMillion * multiplier / 1_000_000
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
        if case .peak = deepseekPeakWindow.status(at: date) {
            return 2
        }
        return 1
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
                // MiniMax-M3 and minimax/MiniMax-M3 are the same model. The
                // standard <=512K public price is used because the local
                // ledger does not retain the request context length.
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
            if model.contains("gpt-5.6-sol") {
                return ModelTokenPricing(modelLabel: modelName ?? "GPT-5.6 Sol", currency: .usd, inputPerMillion: 5, cacheReadPerMillion: 0.5, outputPerMillion: 30)
            }
            if model.contains("gpt-5.6-terra") {
                return ModelTokenPricing(modelLabel: modelName ?? "GPT-5.6 Terra", currency: .usd, inputPerMillion: 2, cacheReadPerMillion: 0.2, outputPerMillion: 12)
            }
            if model.contains("gpt-5.6-luna") {
                return ModelTokenPricing(modelLabel: modelName ?? "GPT-5.6 Luna", currency: .usd, inputPerMillion: 0.2, cacheReadPerMillion: 0.02, outputPerMillion: 1.2)
            }
            if model.contains("gpt-4.1-mini") {
                return ModelTokenPricing(modelLabel: modelName ?? "GPT-4.1 mini", currency: .usd, inputPerMillion: 0.4, cacheReadPerMillion: 0.1, outputPerMillion: 1.6)
            }
            if model.contains("gpt-4.1-nano") {
                return ModelTokenPricing(modelLabel: modelName ?? "GPT-4.1 nano", currency: .usd, inputPerMillion: 0.1, cacheReadPerMillion: 0.025, outputPerMillion: 0.4)
            }
            if model.contains("gpt-4.1") {
                return ModelTokenPricing(modelLabel: modelName ?? "GPT-4.1", currency: .usd, inputPerMillion: 2, cacheReadPerMillion: 0.5, outputPerMillion: 8)
            }
            if model.contains("gpt-5-mini") {
                return ModelTokenPricing(modelLabel: modelName ?? "GPT-5 mini", currency: .usd, inputPerMillion: 0.25, cacheReadPerMillion: 0.025, outputPerMillion: 2)
            }
            if model.contains("gpt-5") {
                return ModelTokenPricing(modelLabel: modelName ?? "GPT-5", currency: .usd, inputPerMillion: 1.25, cacheReadPerMillion: 0.125, outputPerMillion: 10)
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

/// One expandable row in a client tab: a real quota provider with observed
/// local activity. Empty configured providers never reach the view.
struct ClientProviderUsageSummary: Identifiable, Equatable, Sendable {
    let clientID: String
    let quotaProviderID: String
    let providerName: String
    let dailyTokenUsage: [UnifiedDailyTokenUsage]
    let recentSamples: [LocalTokenUsageSample]
    let scannedAt: Date?
    let deepseekPeakWindow: DeepseekPeakWindow

    var id: String { "\(clientID):\(quotaProviderID)" }

    init(
        clientID: String,
        quotaProviderID: String,
        providerName: String,
        dailyTokenUsage: [UnifiedDailyTokenUsage],
        recentSamples: [LocalTokenUsageSample],
        scannedAt: Date?,
        deepseekPeakWindow: DeepseekPeakWindow = .defaultWindow
    ) {
        self.clientID = clientID
        self.quotaProviderID = quotaProviderID
        self.providerName = providerName
        self.dailyTokenUsage = dailyTokenUsage
        self.recentSamples = recentSamples
        self.scannedAt = scannedAt
        self.deepseekPeakWindow = deepseekPeakWindow
    }

    var totalTokens: Int {
        SaturatingArithmetic.sum(dailyTokenUsage.lazy.map(\.totalTokens))
    }

    var cacheHitRate: Double? {
        let input = SaturatingArithmetic.sum(dailyTokenUsage.lazy.map(\.input))
        let cache = SaturatingArithmetic.sum(dailyTokenUsage.lazy.map(\.cacheRead))
        let denominator = Double(max(0, input)) + Double(max(0, cache))
        guard denominator > 0 else { return nil }
        return Double(max(0, cache)) / denominator
    }

    var inputTokens: Int {
        SaturatingArithmetic.sum(dailyTokenUsage.lazy.map(\.input))
    }

    var cacheReadTokens: Int {
        SaturatingArithmetic.sum(dailyTokenUsage.lazy.map(\.cacheRead))
    }

    var outputTokens: Int {
        SaturatingArithmetic.sum(dailyTokenUsage.lazy.map(\.output))
    }

    var reasoningTokens: Int {
        SaturatingArithmetic.sum(dailyTokenUsage.lazy.map(\.reasoning))
    }

    var costEstimate: ModelCostEstimate {
        let samples = samplesInDisplayedWindow
        return ModelPricingCatalog.estimate(
            samples: samples,
            quotaProviderID: quotaProviderID,
            deepseekPeakWindow: deepseekPeakWindow
        )
    }

    var priceTextByDay: [Date: String] {
        let estimates = ModelPricingCatalog.estimateByDay(
            samples: samplesInDisplayedWindow,
            quotaProviderID: quotaProviderID,
            deepseekPeakWindow: deepseekPeakWindow
        )
        return Dictionary(uniqueKeysWithValues: dailyTokenUsage.map { day in
            let text: String
            if let estimate = estimates[Calendar.current.startOfDay(for: day.dayStart)] {
                if let value = estimate.value, let currency = estimate.currency {
                    text = String(format: "%@%.2f", currency.symbol, value)
                } else {
                    text = "未定价"
                }
            } else {
                text = "—"
            }
            return (day.dayStart, text)
        })
    }

    var unpricedModelUsage: [UnpricedModelUsage] {
        var grouped: [String: (totalTokens: Int, sampleCount: Int)] = [:]
        for sample in samplesInDisplayedWindow {
            guard ModelPricingCatalog.pricing(
                for: sample.modelName,
                quotaProviderID: quotaProviderID
            ) == nil else { continue }

            let name: String
            if let rawName = sample.modelName?.trimmingCharacters(in: .whitespacesAndNewlines),
               rawName.isEmpty == false {
                name = rawName
            } else {
                name = "模型名缺失"
            }
            let input = max(sample.inputTokens, 0)
            let cached = min(max(sample.cachedInputTokens, 0), input)
            let sampleTokens = SaturatingArithmetic.sum(
                input - cached,
                cached,
                max(sample.outputTokens, 0),
                max(sample.reasoningOutputTokens, 0)
            )
            let previous = grouped[name] ?? (totalTokens: 0, sampleCount: 0)
            grouped[name] = (
                totalTokens: SaturatingArithmetic.add(previous.totalTokens, sampleTokens),
                sampleCount: SaturatingArithmetic.add(previous.sampleCount, 1)
            )
        }

        return grouped.map { name, value in
            UnpricedModelUsage(
                modelName: name,
                totalTokens: value.totalTokens,
                sampleCount: value.sampleCount
            )
        }
        .sorted {
            if $0.totalTokens != $1.totalTokens {
                return $0.totalTokens > $1.totalTokens
            }
            return $0.modelName.localizedCaseInsensitiveCompare($1.modelName) == .orderedAscending
        }
    }

    private var samplesInDisplayedWindow: [LocalTokenUsageSample] {
        guard let start = dailyTokenUsage.map(\.dayStart).min(),
              let last = dailyTokenUsage.map(\.dayStart).max(),
              let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else {
            return recentSamples
        }
        return recentSamples.filter {
            $0.completedAt >= start && $0.completedAt < end
        }
    }
}

extension ProviderKind {
    /// Canonical quota-side identity. `ProviderKind` remains as a compatibility
    /// enum for the existing fetchers while the client side moves to `ClientID`.
    var quotaProviderID: String {
        switch self {
        case .minimaxTokenPlan: return QuotaProviderID.minimax
        case .codexChatGpt: return QuotaProviderID.openAI
        case .antigravity: return QuotaProviderID.antigravity
        case .glmCodingPlan: return QuotaProviderID.zhipu
        case .deepseek: return QuotaProviderID.deepseek
        }
    }
}

extension ProviderStatus {
    /// Convert the currently available scanner snapshots into one provider-
    /// neutral projection for the card. The scanner-specific models remain
    /// useful to diagnostics, but views no longer need to know every client.
    func usageProjection(for info: QuotaInfo?) -> ProviderUsageProjection {
        var contributions: [ClientUsageContribution] = []

        switch kind {
        case .codexChatGpt:
            if let details = info?.codexUsageDetails,
               let daily = details.dailyTokenUsage {
                contributions.append(
                    ClientUsageContribution(
                        clientID: ClientID.codex,
                        displayName: "Codex",
                        dailyTokenUsage: daily,
                        recentSamples: details.recentSamples ?? [],
                        scannedAt: details.scannedAt
                    )
                )
            }
            if mergeOpencodeUsage, let usage = opencodeUsage?.openAISlice {
                contributions.append(
                    Self.contribution(
                        clientID: ClientID.openCode,
                        displayName: "OpenCode",
                        usage: usage,
                        sourceProviderID: OpencodeLocalUsage.openAIProviderID,
                        scannedAt: opencodeUsage?.scannedAt
                    )
                )
            }

        case .antigravity:
            if let usage = antigravityLocalUsage {
                contributions.append(
                    ClientUsageContribution(
                        clientID: ClientID.antigravity,
                        displayName: "Antigravity",
                        dailyTokenUsage: usage.dailyTokenUsage,
                        recentSamples: usage.recentSamples ?? [],
                        scannedAt: usage.scannedAt
                    )
                )
            }
            if mergeOpencodeUsage, let usage = opencodeUsage?.antigravitySlice {
                contributions.append(
                    Self.contribution(
                        clientID: ClientID.openCode,
                        displayName: "OpenCode",
                        usage: usage,
                        sourceProviderID: "antigravity",
                        scannedAt: opencodeUsage?.scannedAt
                    )
                )
            }

        case .minimaxTokenPlan:
            if let usage = DshUsageMerger.mergeMinimax(native: minimaxLocalUsage) {
                contributions.append(
                    Self.contribution(
                        clientID: ClientID.minimaxCode,
                        displayName: "MiniMax Code",
                        usage: usage,
                        scannedAt: minimaxLocalUsage?.scannedAt
                    )
                )
            }
            if let usage = DshUsageMerger.mergeMinimax(dsh: dshUsage) {
                contributions.append(
                    Self.contribution(
                        clientID: ClientID.dsh,
                        displayName: "DSH",
                        usage: usage,
                        scannedAt: dshUsage?.scannedAt
                    )
                )
            }
            if mergeOpencodeUsage, let usage = opencodeUsage?.minimaxCodingPlanSlice {
                contributions.append(
                    Self.contribution(
                        clientID: ClientID.openCode,
                        displayName: "OpenCode",
                        usage: usage,
                        sourceProviderID: OpencodeLocalUsage.minimaxCodingPlanProviderID,
                        scannedAt: opencodeUsage?.scannedAt
                    )
                )
            }

        case .glmCodingPlan:
            if let usage = DshUsageMerger.mergeGlm(native: glmLocalUsage) {
                contributions.append(
                    Self.contribution(
                        clientID: ClientID.zcode,
                        displayName: "ZCode",
                        usage: usage,
                        scannedAt: glmLocalUsage?.scannedAt
                    )
                )
            }
            if let usage = DshUsageMerger.mergeGlm(dsh: dshUsage) {
                contributions.append(
                    Self.contribution(
                        clientID: ClientID.dsh,
                        displayName: "DSH",
                        usage: usage,
                        scannedAt: dshUsage?.scannedAt
                    )
                )
            }
            if mergeOpencodeUsage, let usage = opencodeUsage?.glmSlice {
                contributions.append(
                    Self.contribution(
                        clientID: ClientID.openCode,
                        displayName: "OpenCode",
                        usage: usage,
                        sourceProviderID: OpencodeLocalUsage.glmProviderID,
                        scannedAt: opencodeUsage?.scannedAt
                    )
                )
            }

        case .deepseek:
            if let usage = DshUsageMerger.mergeDeepseek(dsh: dshUsage, opencode: nil) {
                contributions.append(
                    Self.contribution(
                        clientID: ClientID.dsh,
                        displayName: "DSH",
                        usage: usage,
                        scannedAt: dshUsage?.scannedAt
                    )
                )
            }
            if mergeOpencodeUsage, let usage = opencodeUsage?.deepseekSlice {
                contributions.append(
                    Self.contribution(
                        clientID: ClientID.openCode,
                        displayName: "OpenCode",
                        usage: usage,
                        sourceProviderID: OpencodeLocalUsage.deepseekProviderID,
                        scannedAt: opencodeUsage?.scannedAt
                    )
                )
            }
        }

        return ProviderUsageProjection(contributions: contributions)
    }

    private static func contribution(
        clientID: String,
        displayName: String,
        usage: OpencodeProviderUsage,
        sourceProviderID: String? = nil,
        scannedAt: Date?
    ) -> ClientUsageContribution {
        ClientUsageContribution(
            clientID: clientID,
            displayName: displayName,
            dailyTokenUsage: usage.dailyTokenUsage,
            recentSamples: sourceProviderID.map {
                OpencodeUsageMerger.opencodeSamples(usage, providerID: $0)
            } ?? usage.recentSamples,
            scannedAt: scannedAt
        )
    }
}
