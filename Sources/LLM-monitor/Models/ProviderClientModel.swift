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

    var id: String { "\(clientID):\(quotaProviderID)" }

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
            // 智谱系行进 GLM 卡；同库里的 minimax / deepseek 行按分片并入对应卡
            // （开关见 clientBindings 的 zcode → minimax / deepseek 两条）。
            supportedQuotaProviderIDs: [
                QuotaProviderID.zhipu,
                QuotaProviderID.minimax,
                QuotaProviderID.deepseek
            ],
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

    /// 展示名（`ClientUsageContribution.displayName` / 设置页行标题共用）。
    /// 未登记的 clientID 回退成 ID 本身，避免出现空标题。
    static func displayName(forClientID clientID: String) -> String {
        all.first { $0.id == clientID }?.displayName ?? clientID
    }
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

/// 截断口径提示的共享文案：设置页展开行与 7 天柱图 hover footer 都引用同一
/// 常量，避免两处 UI 文案漂移。
enum ClientUsageTruncationNotice {
    static let text = "会话文件超出单轮扫描预算，已按最新优先截断，最旧的历史用量未计入以上统计。"
}

/// One client's contribution to a quota card.
struct ClientUsageContribution: Equatable, Sendable {
    let clientID: String
    let displayName: String
    let dailyTokenUsage: [UnifiedDailyTokenUsage]
    let recentSamples: [LocalTokenUsageSample]
    let scannedAt: Date?
    /// 来源快照的统计口径被截断（如 DSH 文件数/字节预算挤出最旧 session）。
    /// true 时 UI 必须提示"数字不完整"；无截断概念的来源保持 false。
    let isTruncated: Bool

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
        scannedAt: Date? = nil,
        isTruncated: Bool = false
    ) {
        self.clientID = clientID
        self.displayName = displayName
        let unifiedDaily = dailyTokenUsage.map { UnifiedDailyTokenUsage($0) }
        self.recentSamples = recentSamples
        self.dailyTokenUsage = UnifiedDailyUsageNormalizer.includingCurrentDay(
            dailyTokenUsage: unifiedDaily,
            samples: recentSamples
        )
        self.scannedAt = scannedAt
        self.isTruncated = isTruncated
    }

    /// 从内核投影构造（`UsageProjectionKernel.project` 的产物）。
    /// 投影里的 daily 已在内核做过合并与当日 max 修补，这里不再重复归一化。
    init(projection: ProviderHarnessProjection, displayName: String) {
        self.clientID = projection.clientID
        self.displayName = displayName
        self.dailyTokenUsage = projection.daily
        self.recentSamples = projection.samples
        self.scannedAt = projection.scannedAt
        self.isTruncated = projection.isTruncated
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
    let localUsageFreshness: LocalUsageFreshness

    var clientIDs: [String] { contributions.map(\.clientID) }
    var hasActivity: Bool {
        dailyTokenUsage.contains {
            $0.totalTokens > 0 || $0.turns > 0 || $0.rounds > 0
        } || !recentSamples.isEmpty
    }
    /// 截断标志的聚合规则：任一贡献来源截断即整卡按截断处理（保守取 true）。
    var isTruncated: Bool {
        contributions.contains(where: \.isTruncated)
    }

    init(
        contributions: [ClientUsageContribution],
        localUsageFreshness: LocalUsageFreshness = .clean
    ) {
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
        self.localUsageFreshness = localUsageFreshness
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
    /// 展示的统计口径被来源截断（如 DSH 预算截断）：展开行需提示数字不完整。
    let isTruncated: Bool
    let deepseekPeakWindow: DeepseekPeakWindow

    // These values are derived entirely from the immutable summary inputs. Keep
    // them as part of the value snapshot so a SwiftUI row can read cost,
    // per-day prices, and unpriced details without re-scanning every sample on
    // each property access during one render pass.
    private let cachedCostEstimate: ModelCostEstimate
    private let cachedPriceTextByDay: [Date: String]
    private let cachedUnpricedModelUsage: [UnpricedModelUsage]

    var id: String { "\(clientID):\(quotaProviderID):\(usageGroupID)" }

    /// 内核投影 → 展示行。daily / samples / 截断位全部来自
    /// `UsageProjectionKernel.project` 的产物，本类型只做"展示窗口裁剪 +
    /// 价值缓存"，不再自己算合并规则。
    init(
        projection: ProviderHarnessProjection,
        providerName: String,
        usageGroupID: String = "",
        deepseekPeakWindow: DeepseekPeakWindow = .defaultWindow
    ) {
        self.init(
            clientID: projection.clientID,
            quotaProviderID: projection.quotaProviderID,
            providerName: providerName,
            usageGroupID: usageGroupID,
            dailyTokenUsage: projection.daily,
            recentSamples: projection.samples,
            scannedAt: projection.scannedAt,
            isTruncated: projection.isTruncated,
            deepseekPeakWindow: deepseekPeakWindow
        )
    }

    init(
        clientID: String,
        quotaProviderID: String,
        providerName: String,
        usageGroupID: String = "",
        dailyTokenUsage: [UnifiedDailyTokenUsage],
        recentSamples: [LocalTokenUsageSample],
        scannedAt: Date?,
        isTruncated: Bool = false,
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
        self.isTruncated = isTruncated
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
    ///
    /// 计算链路只有一条：L1 抽取帧 → L2 内核投影 → 视图模型。
    /// 合并规则、命名空间、当日 max 修补、名义价值全部在内核里，视图层不再复算。
    func usageProjection(for info: QuotaInfo?) -> ProviderUsageProjection {
        let frames = Self.usageFrameExtractors[kind]?.flatMap { $0(self, info) } ?? []
        let projections = UsageProjectionKernel.project(
            frames: frames,
            bindings: clientBindings,
            deepseekPeakWindow: deepseekPeakWindow ?? .defaultWindow
        )
        // 卡片只呈现本卡 quota 侧的贡献：dsh 帧不声明归属（由内核按绑定解析），
        // 未被任何启用绑定认领的键会落成空串组，在这里被过滤掉，不产生垃圾贡献行。
        let ownQuotaProjections = projections.filter { $0.quotaProviderID == kind.quotaProviderID }
        return ProviderUsageProjection(
            contributions: ownQuotaProjections.map {
                ClientUsageContribution(
                    projection: $0,
                    displayName: ClientDescriptor.displayName(forClientID: $0.clientID)
                )
            },
            localUsageFreshness: effectiveLocalUsageFreshness
        )
    }

    /// 每个 quota 卡的**帧抽取注册表**（取代旧的 contribution 工厂表）：
    /// `[kind: [帧抽取器]]`。每个抽取器把一个来源（status 字段 / QuotaInfo 详情）
    /// 转成 0..n 个 `HarnessUsageFrame`；返回空数组表示该来源当前无数据。
    ///
    /// 帧的顺序即贡献顺序（内核按首次出现的分组顺序输出），所以这里的数组顺序
    /// 是展示契约的一部分。新增 provider 只需在这里追一个抽取器。
    static let usageFrameExtractors: [ProviderKind: [@Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame]]] = [
        .codexChatGpt: [
            codexFrames,
            opencodeFrames(sourceProviderID: OpencodeLocalUsage.openAIProviderID) { $0.opencodeUsage?.openAISlice }
        ],
        .antigravity: [
            antigravityFrames,
            opencodeFrames(sourceProviderID: OpencodeLocalUsage.antigravitySourceProviderID) {
                $0.opencodeUsage?.antigravitySlice
            }
        ],
        .minimaxTokenPlan: [
            minimaxNativeFrames,
            dshFrames,
            zcodeSliceFrames(.minimax) { $0.glmLocalUsage?.minimaxSlice },
            opencodeFrames(sourceProviderID: OpencodeLocalUsage.minimaxCodingPlanProviderID) {
                $0.opencodeUsage?.minimaxCodingPlanSlice
            }
        ],
        .glmCodingPlan: [
            zcodeNativeFrames,
            dshFrames,
            opencodeFrames(sourceProviderID: OpencodeLocalUsage.glmProviderID) { $0.opencodeUsage?.glmSlice }
        ],
        .deepseek: [
            dshFrames,
            zcodeSliceFrames(.deepseek) { $0.glmLocalUsage?.deepseekSlice },
            opencodeFrames(sourceProviderID: OpencodeLocalUsage.deepseekProviderID) { $0.opencodeUsage?.deepseekSlice }
        ]
    ]

    /// Codex native（`QuotaInfo.codexUsageDetails`）。样本已在 scanner 构造点带
    /// `codex:` 命名空间，这里保持原样。
    private static let codexFrames: @Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame] = { _, info in
        guard let details = info?.codexUsageDetails,
              let daily = details.dailyTokenUsage else { return [] }
        return [HarnessUsageFrame(
            clientID: ClientID.codex,
            quotaProviderID: QuotaProviderID.openAI,
            daily: daily,
            samples: details.recentSamples ?? [],
            namespace: .codex,
            scannedAt: details.scannedAt
        )]
    }

    /// Antigravity native（RPC + .db step 统计）。独立账本 → 裸 promptID。
    private static let antigravityFrames: @Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame] = { status, _ in
        guard let snapshot = status.antigravityLocalUsage else { return [] }
        return [HarnessUsageFrame(
            clientID: ClientID.antigravity,
            quotaProviderID: QuotaProviderID.antigravity,
            daily: snapshot.dailyTokenUsage,
            samples: snapshot.recentSamples ?? [],
            namespace: .native,
            scannedAt: snapshot.scannedAt
        )]
    }

    /// MiniMax Code native（v2 runtime-state 单库 SQL）。独立账本 → 裸 promptID。
    private static let minimaxNativeFrames: @Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame] = { status, _ in
        guard let snapshot = status.minimaxLocalUsage else { return [] }
        return [HarnessUsageFrame(
            clientID: ClientID.minimaxCode,
            quotaProviderID: QuotaProviderID.minimax,
            daily: snapshot.dailyTokenUsage,
            samples: snapshot.recentSamples ?? [],
            namespace: .native,
            scannedAt: snapshot.scannedAt
        )]
    }

    /// ZCode 智谱系 native（`GlmZcodeLocalUsageScanner`）。智谱行走 GLM 卡，
    /// 样本保持裸 promptID（与既有行为一致），非智谱分片见 `zcodeSliceFrames`。
    private static let zcodeNativeFrames: @Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame] = { status, _ in
        guard let snapshot = status.glmLocalUsage else { return [] }
        return [HarnessUsageFrame(
            clientID: ClientID.zcode,
            quotaProviderID: QuotaProviderID.zhipu,
            daily: snapshot.dailyTokenUsage,
            samples: snapshot.recentSamples ?? [],
            namespace: .native,
            scannedAt: snapshot.scannedAt
        )]
    }

    /// DSH（共享 session 账本）→ 每 provider 键一帧。帧**不声明 quota 归属**：
    /// dsh 是多 provider 路由账本，归属与启停都由内核按 `status.clientBindings`
    /// 的 dsh 条目解析；本卡 quota 之外的组由 `usageProjection` 过滤。
    /// `isTruncated` 是快照级口径（文件数/字节预算挤出最旧 session），不随
    /// provider 分片稀释：每一帧都带快照的截断位，由内核做"任一截断即截断"。
    private static let dshFrames: @Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame] = { status, _ in
        DshHarnessFrames.frames(from: status.dshUsage)
    }

    /// ZCode 账本里的非智谱 provider 分片（`minimax` / `deepseek`），并入
    /// MiniMax / DeepSeek 卡。由 `clientBindings` 的 zcode → <quota provider>
    /// 绑定门控（P2 起，取代旧 `mergeZcodeUsage` 派生 bool）。
    private static func zcodeSliceFrames(
        _ provider: ZcodeProviderSlice,
        _ slice: @escaping @Sendable (ProviderStatus) -> OpencodeProviderUsage?
    ) -> @Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame] {
        { status, _ in
            guard status.isClientBindingEnabled(
                    clientID: ClientID.zcode,
                    quotaProviderID: status.kind.quotaProviderID
            ),
                  let usage = slice(status) else { return [] }
            return [HarnessUsageFrame(
                clientID: ClientID.zcode,
                sourceKey: provider.providerPrefix,
                quotaProviderID: status.kind.quotaProviderID,
                daily: usage.dailyTokenUsage,
                samples: usage.recentSamples,
                namespace: .zcodeSlice,
                scannedAt: status.glmLocalUsage?.scannedAt
            )]
        }
    }

    /// OpenCode provider 分片（一份多 provider 账本）。由 `clientBindings` 的
    /// opencode → <quota provider> 绑定门控（P2 起，取代旧 `mergeOpencodeUsage`
    /// 派生 bool）；样本加 `opencode:<provider>:` 命名空间。
    private static func opencodeFrames(
        sourceProviderID: String,
        _ slice: @escaping @Sendable (ProviderStatus) -> OpencodeProviderUsage?
    ) -> @Sendable (ProviderStatus, QuotaInfo?) -> [HarnessUsageFrame] {
        { status, _ in
            guard status.isClientBindingEnabled(
                    clientID: ClientID.openCode,
                    quotaProviderID: status.kind.quotaProviderID
            ),
                  let usage = slice(status) else { return [] }
            return [HarnessUsageFrame(
                clientID: ClientID.openCode,
                sourceKey: sourceProviderID,
                quotaProviderID: status.kind.quotaProviderID,
                daily: usage.dailyTokenUsage,
                samples: usage.recentSamples,
                namespace: .opencode,
                scannedAt: status.opencodeUsage?.scannedAt
            )]
        }
    }
}
