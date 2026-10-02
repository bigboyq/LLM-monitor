import Foundation

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
}
