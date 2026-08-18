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

/// Model families shown under the Antigravity client in Settings.
enum AntigravityUsageGroup: String, CaseIterable, Sendable {
    case gemini
    case claudeAndGPT
    case other

    var displayName: String {
        switch self {
        case .gemini: return "Gemini Models"
        case .claudeAndGPT: return "Claude and GPT Models"
        case .other: return "Other Models"
        }
    }

    static func classify(modelName: String?) -> Self {
        let model = modelName?.lowercased() ?? ""
        if model.contains("gemini") { return .gemini }
        if model.contains("claude") || model.contains("gpt") { return .claudeAndGPT }
        return .other
    }
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
            // Codex CLI 当前只走 OpenAI ChatGPT Plan 一条 quota 通道。
            // DeepSeek / MiniMax 是预留路由：未来 Codex 增加对其它上游的支持时
            // 直接启用，不需要再改 ClientDescriptor 注册。
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

/// Keep the current day complete when a scanner's persisted daily aggregate is
/// one scan behind its per-request samples. This can happen while a local DB
/// is being written: the sample is already visible, but the cached daily row
/// has not been rebuilt yet.
enum UnifiedDailyUsageNormalizer {
    static func includingCurrentDay(
        dailyTokenUsage: [UnifiedDailyTokenUsage],
        samples: [LocalTokenUsageSample],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [UnifiedDailyTokenUsage] {
        guard samples.isEmpty == false else { return dailyTokenUsage }

        let todayStart = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            return dailyTokenUsage
        }
        let todaySamples = samples.filter {
            $0.completedAt >= todayStart && $0.completedAt < tomorrow
        }
        guard todaySamples.isEmpty == false else {
            return dailyTokenUsage
        }

        let sampleToday = UnifiedTokenUsageAggregator.day(
            from: todaySamples,
            dayStart: todayStart,
            calendar: calendar
        )

        var byDay = Dictionary(
            uniqueKeysWithValues: normalized(dailyTokenUsage, calendar: calendar).map {
                ($0.dayStart, $0)
            }
        )
        if let existing = byDay[todayStart] {
            // Daily data remains authoritative for values it already contains;
            // max() fills a stale current-day row without double-counting the
            // same samples when both sources contain the same requests.
            byDay[todayStart] = UnifiedDailyTokenUsage(
                dayStart: todayStart,
                input: max(existing.input, sampleToday.input),
                cacheRead: max(existing.cacheRead, sampleToday.cacheRead),
                cacheWrite: existing.cacheWrite,
                output: max(existing.output, sampleToday.output),
                reasoning: max(existing.reasoning, sampleToday.reasoning),
                turns: max(existing.turns, sampleToday.turns),
                rounds: max(existing.rounds, sampleToday.rounds)
            )
        } else {
            byDay[todayStart] = sampleToday
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    private static func normalized(
        _ dailyTokenUsage: [UnifiedDailyTokenUsage],
        calendar: Calendar
    ) -> [UnifiedDailyTokenUsage] {
        var byDay: [Date: UnifiedDailyTokenUsage] = [:]
        for day in dailyTokenUsage {
            let dayStart = calendar.startOfDay(for: day.dayStart)
            let normalizedDay = UnifiedDailyTokenUsage(
                dayStart: dayStart,
                input: day.input,
                cacheRead: day.cacheRead,
                cacheWrite: day.cacheWrite,
                output: day.output,
                reasoning: day.reasoning,
                turns: day.turns,
                rounds: day.rounds
            )
            byDay[dayStart] = byDay[dayStart].map { $0 + normalizedDay } ?? normalizedDay
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
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
        let unifiedDaily = dailyTokenUsage.map(UnifiedDailyTokenUsage.init)
        self.recentSamples = recentSamples
        self.dailyTokenUsage = UnifiedDailyUsageNormalizer.includingCurrentDay(
            dailyTokenUsage: unifiedDaily,
            samples: recentSamples
        )
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

/// One expandable row in a client tab: a real quota provider with observed
/// local activity. Empty configured providers never reach the view.
struct ClientProviderUsageSummary: Identifiable, Equatable, Sendable {
    let clientID: String
    let quotaProviderID: String
    let providerName: String
    let usageGroupID: String
    let dailyTokenUsage: [UnifiedDailyTokenUsage]
    let recentSamples: [LocalTokenUsageSample]
    let scannedAt: Date?
    let deepseekPeakWindow: DeepseekPeakWindow

    // These values are derived entirely from the immutable summary inputs. Keep
    // them as part of the value snapshot so a SwiftUI row can read cost,
    // per-day prices, and unpriced details without re-scanning every sample on
    // each property access during one render pass.
    private let cachedCostEstimate: ModelCostEstimate
    private let cachedPriceTextByDay: [Date: String]
    private let cachedUnpricedModelUsage: [UnpricedModelUsage]

    var id: String { "\(clientID):\(quotaProviderID):\(usageGroupID)" }

    init(
        clientID: String,
        quotaProviderID: String,
        providerName: String,
        usageGroupID: String = "",
        dailyTokenUsage: [UnifiedDailyTokenUsage],
        recentSamples: [LocalTokenUsageSample],
        scannedAt: Date?,
        deepseekPeakWindow: DeepseekPeakWindow = .defaultWindow
    ) {
        self.clientID = clientID
        self.quotaProviderID = quotaProviderID
        self.providerName = providerName
        self.usageGroupID = usageGroupID
        self.recentSamples = recentSamples
        let normalizedDaily = UnifiedDailyUsageNormalizer.includingCurrentDay(
            dailyTokenUsage: dailyTokenUsage,
            samples: recentSamples
        )
        self.dailyTokenUsage = normalizedDaily
        self.scannedAt = scannedAt
        self.deepseekPeakWindow = deepseekPeakWindow

        let displayedSamples = Self.samplesInDisplayedWindow(
            dailyTokenUsage: normalizedDaily,
            recentSamples: recentSamples
        )
        self.cachedCostEstimate = ModelPricingCatalog.estimate(
            samples: displayedSamples,
            quotaProviderID: quotaProviderID,
            deepseekPeakWindow: deepseekPeakWindow
        )
        self.cachedPriceTextByDay = Self.makePriceTextByDay(
            dailyTokenUsage: normalizedDaily,
            recentSamples: recentSamples,
            quotaProviderID: quotaProviderID,
            deepseekPeakWindow: deepseekPeakWindow
        )
        self.cachedUnpricedModelUsage = Self.makeUnpricedModelUsage(
            samples: displayedSamples,
            quotaProviderID: quotaProviderID
        )
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
        cachedCostEstimate
    }

    var priceTextByDay: [Date: String] {
        cachedPriceTextByDay
    }

    var unpricedModelUsage: [UnpricedModelUsage] {
        cachedUnpricedModelUsage
    }

    private static func makePriceTextByDay(
        dailyTokenUsage: [UnifiedDailyTokenUsage],
        recentSamples: [LocalTokenUsageSample],
        quotaProviderID: String,
        deepseekPeakWindow: DeepseekPeakWindow
    ) -> [Date: String] {
        let estimates = ModelPricingCatalog.estimateByDay(
            samples: recentSamples,
            quotaProviderID: quotaProviderID,
            deepseekPeakWindow: deepseekPeakWindow
        )
        let calendar = Calendar.current
        return Dictionary(uniqueKeysWithValues: dailyTokenUsage.map { day in
            let dayStart = calendar.startOfDay(for: day.dayStart)
            return (day.dayStart, estimates[dayStart]?.displayText ?? "—")
        })
    }

    private static func makeUnpricedModelUsage(
        samples: [LocalTokenUsageSample],
        quotaProviderID: String
    ) -> [UnpricedModelUsage] {
        var grouped: [String: (totalTokens: Int, sampleCount: Int)] = [:]
        for sample in samples {
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
            let components = ModelPricingCatalog.tokenComponents(for: sample)
            let sampleTokens = SaturatingArithmetic.sum(
                components.uncached,
                components.cached,
                components.output
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

    private static func samplesInDisplayedWindow(
        dailyTokenUsage: [UnifiedDailyTokenUsage],
        recentSamples: [LocalTokenUsageSample]
    ) -> [LocalTokenUsageSample] {
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
        let factories = Self.usageContributionFactories[kind] ?? []
        return ProviderUsageProjection(
            contributions: factories.compactMap { $0(self, info) }
        )
    }

    /// 每个 quota 卡消费的客户端来源注册表（配置表驱动，取代 per-kind switch）：
    /// `[kind: [contribution 工厂]]`，工厂返回 nil 表示该来源当前无数据。
    /// 新增 provider 只需在这里追加工厂，不再往 switch 里堆分支。
    static let usageContributionFactories: [ProviderKind: [(ProviderStatus, QuotaInfo?) -> ClientUsageContribution?]] = [
        .codexChatGpt: [
            { status, info in
                guard let details = info?.codexUsageDetails,
                      let daily = details.dailyTokenUsage else { return nil }
                return ClientUsageContribution(
                    clientID: ClientID.codex,
                    displayName: "Codex",
                    dailyTokenUsage: daily,
                    recentSamples: details.recentSamples ?? [],
                    scannedAt: details.scannedAt
                )
            },
            opencodeContribution(slice: { $0.opencodeUsage?.openAISlice },
                                 sourceProviderID: OpencodeLocalUsage.openAIProviderID)
        ],
        .antigravity: [
            nativeContribution(clientID: ClientID.antigravity, displayName: "Antigravity") {
                $0.antigravityLocalUsage
            },
            opencodeContribution(slice: { $0.opencodeUsage?.antigravitySlice },
                                 sourceProviderID: "antigravity")
        ],
        .minimaxTokenPlan: [
            mergedContribution(
                clientID: ClientID.minimaxCode, displayName: "MiniMax Code",
                make: { DshUsageMerger.mergeMinimax(native: $0.minimaxLocalUsage) },
                scannedAt: { $0.minimaxLocalUsage?.scannedAt }),
            mergedContribution(
                clientID: ClientID.dsh, displayName: "DSH",
                make: { DshUsageMerger.mergeMinimax(dsh: $0.dshUsage) },
                scannedAt: { $0.dshUsage?.scannedAt }),
            opencodeContribution(slice: { $0.opencodeUsage?.minimaxCodingPlanSlice },
                                 sourceProviderID: OpencodeLocalUsage.minimaxCodingPlanProviderID)
        ],
        .glmCodingPlan: [
            mergedContribution(
                clientID: ClientID.zcode, displayName: "ZCode",
                make: { DshUsageMerger.mergeGlm(native: $0.glmLocalUsage) },
                scannedAt: { $0.glmLocalUsage?.scannedAt }),
            mergedContribution(
                clientID: ClientID.dsh, displayName: "DSH",
                make: { DshUsageMerger.mergeGlm(dsh: $0.dshUsage) },
                scannedAt: { $0.dshUsage?.scannedAt }),
            opencodeContribution(slice: { $0.opencodeUsage?.glmSlice },
                                 sourceProviderID: OpencodeLocalUsage.glmProviderID)
        ],
        .deepseek: [
            mergedContribution(
                clientID: ClientID.dsh, displayName: "DSH",
                make: { DshUsageMerger.mergeDeepseek(dsh: $0.dshUsage, opencode: nil) },
                scannedAt: { $0.dshUsage?.scannedAt }),
            opencodeContribution(slice: { $0.opencodeUsage?.deepseekSlice },
                                 sourceProviderID: OpencodeLocalUsage.deepseekProviderID)
        ]
    ]

    /// 单源客户端（antigravity native）：快照存在即贡献。
    private static func nativeContribution(
        clientID: String,
        displayName: String,
        _ usage: @escaping (ProviderStatus) -> ProviderLocalUsage?
    ) -> (ProviderStatus, QuotaInfo?) -> ClientUsageContribution? {
        { status, _ in
            guard let snapshot = usage(status) else { return nil }
            return ClientUsageContribution(
                clientID: clientID,
                displayName: displayName,
                dailyTokenUsage: snapshot.dailyTokenUsage,
                recentSamples: snapshot.recentSamples ?? [],
                scannedAt: snapshot.scannedAt
            )
        }
    }

    /// `DshUsageMerger` 产出（OpencodeProviderUsage 形态）→ contribution。
    /// minimax / GLM 的 native+dsh 双源、deepseek 的纯 dsh 都走这条路径。
    private static func mergedContribution(
        clientID: String,
        displayName: String,
        make: @escaping (ProviderStatus) -> OpencodeProviderUsage?,
        scannedAt: @escaping (ProviderStatus) -> Date?
    ) -> (ProviderStatus, QuotaInfo?) -> ClientUsageContribution? {
        { status, _ in
            guard let usage = make(status) else { return nil }
            return ClientUsageContribution(
                clientID: clientID,
                displayName: displayName,
                dailyTokenUsage: usage.dailyTokenUsage,
                recentSamples: usage.recentSamples,
                scannedAt: scannedAt(status)
            )
        }
    }

    /// OpenCode 合并来源：`mergeOpencodeUsage` 开关 + 对应 provider 分片。
    private static func opencodeContribution(
        slice: @escaping (ProviderStatus) -> OpencodeProviderUsage?,
        sourceProviderID: String
    ) -> (ProviderStatus, QuotaInfo?) -> ClientUsageContribution? {
        { status, _ in
            guard status.mergeOpencodeUsage, let usage = slice(status) else { return nil }
            return ClientUsageContribution(
                clientID: ClientID.openCode,
                displayName: "OpenCode",
                dailyTokenUsage: usage.dailyTokenUsage,
                recentSamples: OpencodeUsageMerger.opencodeSamples(usage, providerID: sourceProviderID),
                scannedAt: status.opencodeUsage?.scannedAt
            )
        }
    }
}
