import Foundation

/// 截断口径提示的共享文案：设置页展开行与 7 天柱图 hover footer 都引用同一
/// 常量，避免两处 UI 文案漂移。
enum ClientUsageTruncationNotice {
    static let text = "会话文件超出单轮扫描预算，已按最新优先截断，最旧的历史用量未计入以上统计。"
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

/// 「client → Provider 用量行」聚合的共享实现：设置页"客户端"tab 与后续
/// Harness（客户端视角）菜单视图共用同一口径，避免两处各算一套。
///
/// 从 `SettingsView`（原 SettingsClientsPane.swift）提取成纯函数：输入
/// `[ProviderStatus]`（调用方传 `state.statuses`），不再依赖任何视图实例状态。
/// 提取是无损搬移——回归护栏为 `SettingsClientsPaneTests`（ZCode 行序断言在
/// 那里）与 `UIUsageRegressionTests.testSettingsGroupingUsesOnlySevenDisplayedDays`。
enum ClientUsageAggregation {
    /// 按 client 分组的 Provider 用量行。`clientProviderUsageByClient(for:)`
    /// 输出的每个 client 列内行序固定（见 `zcodeRowRank`），调用方不再排序。
    static func clientProviderUsageByClient(
        for statuses: [ProviderStatus]
    ) -> [String: [ClientProviderUsageSummary]] {
        var rowsByClient: [String: [ClientProviderUsageSummary]] = [:]
        for status in statuses {
            let projection = status.usageProjection(for: status.lastSuccess)
            for contribution in projection.contributions {
                guard contribution.hasActivity else { continue }
                if contribution.clientID == ClientID.antigravity, status.kind == .antigravity {
                    rowsByClient[contribution.clientID, default: []].append(
                        contentsOf: antigravityUsageRows(status: status, contribution: contribution)
                    )
                } else if contribution.clientID == ClientID.zcode, status.kind == .glmCodingPlan,
                          !contribution.recentSamples.isEmpty {
                    rowsByClient[contribution.clientID, default: []].append(
                        contentsOf: glmUsageRows(status: status, contribution: contribution)
                    )
                } else {
                    rowsByClient[contribution.clientID, default: []].append(
                        ClientProviderUsageSummary(
                            clientID: contribution.clientID,
                            quotaProviderID: status.kind.quotaProviderID,
                            providerName: status.displayName,
                            usageGroupID: status.kind.quotaProviderID,
                            dailyTokenUsage: contribution.dailyTokenUsage,
                            recentSamples: contribution.recentSamples,
                            scannedAt: contribution.scannedAt,
                            isTruncated: contribution.isTruncated,
                            deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
                        )
                    )
                }
            }
        }
        return rowsByClient.mapValues { rows in
            rows.sorted { lhs, rhs in
                // ZCode 客户端区是唯一混排多种语义行的列：GLM 分类行（套餐名）
                // 与 DeepSeek / MiniMax 分片行（provider 名）必须按固定口径排，
                // 字母序会得到 "Coding Plan → DeepSeek → Start Plan → …"。
                if lhs.clientID == ClientID.zcode {
                    let l = zcodeRowRank(lhs), r = zcodeRowRank(rhs)
                    if l != r { return l < r }
                }
                if lhs.providerName != rhs.providerName {
                    return lhs.providerName.localizedCaseInsensitiveCompare(rhs.providerName) == .orderedAscending
                }
                return lhs.usageGroupID < rhs.usageGroupID
            }
        }
    }

    /// ZCode 列的行序：Coding Plan → Start Plan → 闲时任务 → 其他任务 →
    /// DeepSeek → MiniMax。
    ///
    /// GLM 分类行取 `GlmUsageCategory.allCases` 的声明序（枚举加 case 时行序
    /// 自动跟随）；两个分片行来自 MiniMax / DeepSeek 卡的 ZCode 贡献
    /// （由 `clientBindings` 的 zcode → <quota> 绑定门控），
    /// 它们不是套餐而是 provider，固定排在分类行之后。
    static func zcodeRowRank(_ row: ClientProviderUsageSummary) -> Int {
        let glmCount = GlmUsageCategory.allCases.count
        if row.quotaProviderID == QuotaProviderID.zhipu,
           let category = GlmUsageCategory(rawValue: row.usageGroupID) {
            return GlmUsageCategory.allCases.firstIndex(of: category) ?? 0
        }
        switch row.quotaProviderID {
        case QuotaProviderID.deepseek: return glmCount
        case QuotaProviderID.minimax: return glmCount + 1
        default: return glmCount + 2
        }
    }

    /// Antigravity owns one quota account but can produce several billable model
    /// families. Split the settings rows using the model name recorded in each
    /// local sample so each row gets its own token totals and price estimate.
    static func antigravityUsageRows(
        status: ProviderStatus,
        contribution: ClientUsageContribution
    ) -> [ClientProviderUsageSummary] {
        // OpenCode/native recent samples can span eight days while the
        // settings chart is deliberately padded to seven calendar days.  Do
        // the windowing before classifying samples; otherwise an out-of-window
        // model can create a phantom group (and its cost estimate).
        let displayedSamples = samplesInDisplayedWindow(
            contribution.recentSamples,
            matching: contribution.dailyTokenUsage
        )
        let groups: [AntigravityUsageGroup: [LocalTokenUsageSample]]
        if displayedSamples.isEmpty {
            let hasDisplayedDailyActivity = contribution.dailyTokenUsage.contains {
                $0.totalTokens > 0 || $0.turns > 0 || $0.rounds > 0
            }
            groups = hasDisplayedDailyActivity ? [.other: []] : [:]
        } else {
            groups = Dictionary(grouping: displayedSamples) {
                AntigravityUsageGroup.classify(modelName: $0.modelName)
            }
        }

        return groups.keys.sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.rawValue < $1.rawValue
        }.map { group in
            let samples = groups[group] ?? []
            let daily = samples.isEmpty
                ? contribution.dailyTokenUsage
                : dailyUsage(for: samples, matching: contribution.dailyTokenUsage)
            return ClientProviderUsageSummary(
                clientID: ClientID.antigravity,
                quotaProviderID: status.kind.quotaProviderID,
                providerName: group.displayName,
                usageGroupID: group.rawValue,
                dailyTokenUsage: daily,
                recentSamples: samples,
                scannedAt: contribution.scannedAt,
                deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
            )
        }
    }

    /// ZCode 一次扫描覆盖智谱系全部 provider 任务（Coding Plan / Start Plan /
    /// 闲时 / 其他智谱套餐）。按样本上的 `sourceProviderID` 分类拆行，各自独立
    /// token 柱图与计价——对齐 Antigravity 按模型分组拆行的模式；弹窗卡片维持
    /// 合并汇总不拆。空分类不出现（"如有"语义由 `allCases` + 非空判定给出）。
    /// 样本为空（旧缓存 / 无样本）时保持整行不拆，避免把聚合值错标成某一分类。
    static func glmUsageRows(
        status: ProviderStatus,
        contribution: ClientUsageContribution
    ) -> [ClientProviderUsageSummary] {
        let displayedSamples = samplesInDisplayedWindow(
            contribution.recentSamples,
            matching: contribution.dailyTokenUsage
        )
        let groups = Dictionary(grouping: displayedSamples) {
            GlmUsageCategory.classify($0)
        }
        return GlmUsageCategory.allCases.compactMap { category in
            guard let samples = groups[category], !samples.isEmpty else { return nil }
            return ClientProviderUsageSummary(
                clientID: ClientID.zcode,
                quotaProviderID: status.kind.quotaProviderID,
                providerName: category.displayName,
                usageGroupID: category.rawValue,
                dailyTokenUsage: dailyUsage(for: samples, matching: contribution.dailyTokenUsage),
                recentSamples: samples,
                scannedAt: contribution.scannedAt,
                deepseekPeakWindow: status.deepseekPeakWindow ?? .defaultWindow
            )
        }
    }

    static func dailyUsage(
        for samples: [LocalTokenUsageSample],
        matching template: [UnifiedDailyTokenUsage]
    ) -> [UnifiedDailyTokenUsage] {
        let calendar = Calendar.current
        var byDay = Dictionary(
            uniqueKeysWithValues: template.map { day in
                (calendar.startOfDay(for: day.dayStart), UnifiedDailyTokenUsage(dayStart: day.dayStart))
            }
        )

        // `recentSamples` intentionally keeps one extra day for quota-window
        // calculations.  The settings chart, however, is keyed by the seven
        // days in `template`; do not let that extra day grow the chart or its
        // grouped totals.
        let displayedSamples = samplesInDisplayedWindow(samples, matching: template)
        for usage in UnifiedTokenUsageAggregator.days(from: displayedSamples, calendar: calendar) {
            let dayStart = calendar.startOfDay(for: usage.dayStart)
            byDay[dayStart] = byDay[dayStart].map { $0 + usage } ?? usage
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    private static func samplesInDisplayedWindow(
        _ samples: [LocalTokenUsageSample],
        matching dailyUsage: [UnifiedDailyTokenUsage]
    ) -> [LocalTokenUsageSample] {
        // Scanner 的日窗口连续且已补零；按时间边界过滤，避免对每个样本重复换算日历。
        guard let start = dailyUsage.map(\.dayStart).min(),
              let lastDay = dailyUsage.map(\.dayStart).max(),
              let end = Calendar.current.date(byAdding: .day, value: 1, to: lastDay) else { return [] }
        return samples.filter {
            $0.completedAt >= start && $0.completedAt < end
        }
    }
}

// MARK: - Harness（客户端视角）今日汇总

/// 菜单模型行的唯一键：一个客户端在某个 quota provider 下产生的**一个模型名**。
///
/// 模型名缺失（nil / 空白）的样本归一化成 `nil`，与
/// `ModelPricingCatalog.pricing` 对空模型名的判定一致，因此「模型名缺失」行既是
/// 一条真实的数据行，也是一条必然未定价的行——不会出现"同名两行"。
private struct HarnessRowKey: Hashable, Sendable {
    let clientID: String
    let quotaProviderID: String
    let modelName: String?
}

/// 段内单条模型用量行。价值在 `init` 里算一次并缓存（同
/// `ClientProviderUsageSummary` 的做法），SwiftUI 逐帧重排时不会反复扫描样本。
struct HarnessModelRow: Identifiable, Equatable, Sendable {
    let dayStart: Date
    let clientID: String
    let quotaProviderID: String
    /// `nil` = 样本没有可用模型名，UI 渲染成「模型名缺失」行。
    let modelName: String?
    let buckets: TokenUsageBuckets
    /// 行级今日 token 速度（tok/s）：`init` 里对**同一批今日样本**调
    /// `LocalUsageSummaryBuilder.windowTokenRate`（全仓唯一速率口径，
    /// Σ(Output+Reason) ÷ Σ调用时长，时长 ∈ [0.2, 3600]s 的样本才参与）——
    /// 与 `cachedCostEstimate` 同源同批样本：金额算得出来的行，速率也在同一批
    /// 样本上算。`nil` = 批内没有时长有效的样本（不是"速度为 0"），UI 显示「—」。
    let tokensPerSecond: Double?
    private let cachedCostEstimate: ModelCostEstimate

    var id: String { "\(clientID):\(quotaProviderID):\(modelName ?? "")" }

    /// 今日该行的合计 token（四桶，`TokenUsageBuckets` 的既有口径）。
    var totalTokens: Int { buckets.totalTokens }

    /// 缓存命中率 = cacheRead / (input + cacheRead)。分母为 0 时是 `nil`
    /// （UI 显示「—」），与设置页 `ClientProviderUsageSummary.cacheHitRate` 同语义。
    var cacheHitRate: Double? { HarnessTodaySummary.cacheHitRate(for: buckets) }

    /// 行级价值：**单 provider 单币种**的原额（`¥3.21` / `$9.80` / `未定价`）。
    /// 跨币种折算只发生在段头与全局（`MixedCurrencyEstimate`），行级绝不相加。
    var costEstimate: ModelCostEstimate { cachedCostEstimate }
    var costText: String { cachedCostEstimate.displayText }

    var displayName: String {
        modelName ?? HarnessTodaySummary.missingModelNameText
    }

    /// UI 展示用的压缩名：去掉供应商命名空间（`minimax/`）与已知品牌前缀
    /// （`gemini-` / `claude-`），MiniMax 家族另做变体后缀与品牌大小写归一，
    /// 让**模型名本身**在定宽列里完整可见。
    ///
    /// 为什么是「去命名空间 + 去品牌」两步：`minimax/MiniMax-M3` 里
    /// `minimax/` 是供应商命名空间、`MiniMax-` 是品牌段，用户想看的是模型名。
    /// 压缩前供应商名占满整列，模型名被尾截断成 `minimax/MiniMa…`——
    /// 供应商名占位置、模型名看不见。`gemini-` / `claude-` 早就在压。
    ///
    /// 只影响展示：分组键（`id`）、定价与统计一律仍用原始 `modelName`，
    /// hover 提示继续显示完整原始 ID。
    var compactDisplayName: String {
        guard let name = modelName else {
            return HarnessTodaySummary.missingModelNameText
        }
        return HarnessModelRow.compactedDisplayName(for: name)
    }

    /// 展示名压缩的纯函数形式（规则本身可被单测直接钉住）。
    ///
    /// 规则按顺序：
    /// 1. **供应商命名空间**：模型名里第一个 `/` 之前是供应商
    ///    （`minimax/MiniMax-M3` → `MiniMax-M3`）。命名空间在菜单里已经由
    ///    段头（客户端名）与 hover 卡交代过，展示列不必再占宽度。
    /// 2. **MiniMax 家族**：单独归一（见 `minimaxDisplayName`）——变体后缀
    ///    `-Flash[-Preview]` 剥掉、品牌段大小写统一。
    /// 3. **其它家族的品牌前缀**：已知长品牌前缀大小写不敏感地剥掉，让变体
    ///    后缀在定宽列里可区分——原始 ID 下两个变体都会被尾部截断成相同开头，
    ///    肉眼无法分辨。
    ///
    /// 短前缀（如 `gpt-`）不压：压缩收益小，`deepseek-` 去掉后裸 `flash` 在
    /// 多 provider 段里反而更难归属。
    static func compactedDisplayName(for name: String) -> String {
        var result = name
        if let slash = result.firstIndex(of: "/") {
            let stripped = String(result[result.index(after: slash)...])
            // 剥完是空串（原始 ID 形如 `/`）时保留原名，不让展示名变成空白。
            if !stripped.isEmpty {
                result = stripped
            }
        }
        if result.lowercased().hasPrefix(minimaxBrandPrefix) {
            return minimaxDisplayName(result)
        }
        let lowered = result.lowercased()
        for prefix in compactBrandPrefixes where lowered.hasPrefix(prefix) {
            return String(result.dropFirst(prefix.count))
        }
        return result
    }

    /// MiniMax 品牌段前缀（小写比较用）。
    static let minimaxBrandPrefix = "minimax-"

    /// MiniMax 家族的变体后缀，**长后缀在前**：`-flash-preview` 必须排在
    /// `-flash` 前面，否则 `MiniMax-M3.1-Flash-Preview` 只会剥掉 `-preview`。
    static let minimaxVariantSuffixes = ["-flash-preview", "-flash", "-preview"]

    /// MiniMax 家族的展示名：剥掉变体后缀（`-Flash` / `-Flash-Preview`），
    /// 再把品牌段大小写归一成 `MiniMax-`。
    ///
    /// 同一个模型在不同 harness 里写法不同：ZCode 记 `MiniMax-M3.1-Flash-Preview`、
    /// DSH 记 `Minimax-M3.1-flash-preview`、MiniMax Code 记 `MiniMax-M3.1-Flash`。
    /// 不归一的话同一段里会出现三个"看起来不同"的模型，其实它们是同一个模型、
    /// 同一份价目（`3.1-flash` 关键字命中同一条目）。
    ///
    /// 变体后缀**只在 MiniMax 家族内**剥：`gemini-3.8-flash` 的 `-flash` 是
    /// 变体标识（`3.8-flash-n` / `3.8-flash-tiered` 靠它区分），泛化地砍会
    /// 让变体重新变得不可分辨。
    static func minimaxDisplayName(_ name: String) -> String {
        var result = name
        let lowered = result.lowercased()
        for suffix in minimaxVariantSuffixes where lowered.hasSuffix(suffix) {
            result = String(result.dropLast(suffix.count))
            break
        }
        if result.lowercased().hasPrefix(minimaxBrandPrefix) {
            result = "MiniMax-" + String(result.dropFirst(minimaxBrandPrefix.count))
        }
        return result
    }

    /// 只压掉**已知超长品牌前缀**（7 字符档）：能显著缩短且不引入歧义。
    /// 短前缀（如 `gpt-`）压缩收益小，`deepseek-` 去掉后裸 `flash` 在
    /// 多 provider 段里反而更难归属，都不压。
    ///
    /// 大小写不敏感：真实账本里同一个模型家族有两种写法。
    static let compactBrandPrefixes: [String] = ["gemini-", "claude-"]

    init(
        dayStart: Date,
        clientID: String,
        quotaProviderID: String,
        modelName: String?,
        samples: [LocalTokenUsageSample],
        deepseekPeakWindow: DeepseekPeakWindow = .defaultWindow,
        calendar: Calendar = .current
    ) {
        let day = UnifiedTokenUsageAggregator.day(
            from: samples,
            dayStart: dayStart,
            calendar: calendar
        )
        self.dayStart = calendar.startOfDay(for: day.dayStart)
        self.clientID = clientID
        self.quotaProviderID = quotaProviderID
        self.modelName = modelName
        self.buckets = TokenUsageBuckets(
            input: day.input,
            cacheRead: day.cacheRead,
            output: day.output,
            reasoning: day.reasoning
        )
        self.tokensPerSecond = LocalUsageSummaryBuilder.windowTokenRate(samples: samples)
        self.cachedCostEstimate = ModelPricingCatalog.estimate(
            samples: samples,
            quotaProviderID: quotaProviderID,
            deepseekPeakWindow: deepseekPeakWindow
        )
    }
}

/// 菜单里一个客户端（harness）分段。段的今日三桶是段内各行之和，段价值是段内
/// 各行**行级 estimate** 的跨币种归集（`MixedCurrencyEstimate`）——OpenCode / DSH /
/// ZCode 这类一个客户端横跨多个 provider 分片的段会混币，必须走折算而不是裸相加。
struct HarnessSection: Identifiable, Equatable, Sendable {
    let clientID: String
    let displayName: String
    let iconSystemName: String
    let buckets: TokenUsageBuckets
    /// 段级今日 token 速度（tok/s）：对该段（clientID）的**今日全部样本**调
    /// `LocalUsageSummaryBuilder.windowTokenRate`（与行速度同一个全仓唯一口径）。
    /// 样本全集 = 段内各行的分组样本并集（跨 provider 分片一起进 Σ/Σ），
    /// 单 provider 客户段因此与 popwindow「额度窗口」表格「今」行的速度同值
    /// （同一批今日样本、同一函数）。`nil` = 批内没有时长有效的样本（不是
    /// "速度为 0"），UI 显示「—」；fleet 段没有本地样本，恒 nil。
    let tokensPerSecond: Double?
    let value: MixedCurrencyEstimate
    let rows: [HarnessModelRow]
    /// 本段任一贡献来源的统计口径被截断（如 DSH 文件数/字节预算挤出最旧 session）。
    /// 段头据此加橙色截断提示——**段级**聚合，规则与
    /// `ProviderUsageProjection.isTruncated` 相同（任一来源截断即整段截断）。
    let isTruncated: Bool

    var id: String { clientID }
    var totalTokens: Int { buckets.totalTokens }
    var cacheHitRate: Double? { HarnessTodaySummary.cacheHitRate(for: buckets) }
    var valueText: String { value.displayText }

    /// 段头右键「刷新 <客户端名>」要刷的 provider 卡 id：段头右键按**本段今日
    /// 贡献行**决定刷哪些卡——ZCode 段含 GLM / minimax / deepseek 分片行时一次
    /// 刷齐，且只动这些卡，不惊动与该段无关的 provider。
    ///
    /// 取本段行的去重 `quotaProviderID` 集合，映射到 `statuses` 里匹配
    /// `kind.quotaProviderID` 的 status.id：**输出顺序跟随 statuses**（调用方传
    /// 的是展示顺序，与刷新请求次序同源）、按 status.id 去重、匹配不到的
    /// （段里有贡献行但已不在列表里的 provider）忽略。
    func refreshProviderStatusIDs(in statuses: [ProviderStatus]) -> [String] {
        let contributedQuotaProviderIDs = Set(rows.map(\.quotaProviderID))
        var emittedIDs: Set<String> = []
        return statuses.compactMap { status in
            guard contributedQuotaProviderIDs.contains(status.kind.quotaProviderID),
                  emittedIDs.insert(status.id).inserted else { return nil }
            return status.id
        }
    }
}

/// 「今日占比条」的一段：一个今天有 token 活动的客户端（harness）。
///
/// 颜色不进模型：视图层按 `dominantQuotaProviderID` 查 provider 卡 accent
/// （`AccentColor.cardAccentColor`）。同一客户端横跨多个 provider 分片时
/// （ZCode / DSH / OpenCode）只有一个段，颜色取今日 token 最大的一路。
struct HarnessClientSegment: Identifiable, Equatable, Sendable {
    let clientID: String
    let displayName: String
    let totalTokens: Int
    /// 该客户端今日 token 最大的 quota provider；nil = 行没有可归属的 provider
    /// （理论不出现，防御回退灰色）。
    let dominantQuotaProviderID: String?

    var id: String { clientID }

    /// 本地路径（`HarnessSection`）的构造入口：主 provider 由调用方按段内模型行
    /// 现算（`clientSegments(from:)`）。
    init(
        clientID: String,
        displayName: String,
        totalTokens: Int,
        dominantQuotaProviderID: String?
    ) {
        self.clientID = clientID
        self.displayName = displayName
        self.totalTokens = totalTokens
        self.dominantQuotaProviderID = dominantQuotaProviderID
    }

    /// fleet 段（`FleetMenuSummary.ClientSection`）→ 占比条段：主 provider 由
    /// 投影层在同桶 `clientProviders` 行上算好带过来（fleet 行没有本地模型行
    /// 可分组）。
    init(clientSection: FleetMenuSummary.ClientSection) {
        self.clientID = clientSection.clientID
        self.displayName = clientSection.displayName
        self.totalTokens = clientSection.totalTokens
        self.dominantQuotaProviderID = clientSection.dominantQuotaProviderID
    }

    /// 今日 token 最大的 quota provider（并列取 quotaProviderID 字典序小者，
    /// 保证同一批行每次算出同一个归属）。`rows` 是 (quotaProviderID, 今日四桶
    /// 合计) 对；本地路径来自段内模型行，fleet 路径来自同桶 clientProviders 行。
    static func dominantQuotaProviderID(
        _ rows: [(quotaProviderID: String, totalTokens: Int)]
    ) -> String? {
        var totals: [String: Int] = [:]
        for row in rows {
            totals[row.quotaProviderID, default: 0] += max(0, row.totalTokens)
        }
        var best: (id: String, tokens: Int)?
        for (id, tokens) in totals {
            guard let current = best else {
                best = (id, tokens)
                continue
            }
            if tokens > current.tokens || (tokens == current.tokens && id < current.id) {
                best = (id, tokens)
            }
        }
        return best?.id
    }
}

extension HarnessTodaySummary {
    /// 今日占比条的段列表：`sections` 已按今日 token 降序且只含有活动的客户端，
    /// 这里只补「主力 provider 归属」并防御性滤掉零段。
    static func clientSegments(from sections: [HarnessSection]) -> [HarnessClientSegment] {
        sections.filter { $0.totalTokens > 0 }.map { section in
            HarnessClientSegment(
                clientID: section.clientID,
                displayName: section.displayName,
                totalTokens: section.totalTokens,
                dominantQuotaProviderID: HarnessClientSegment.dominantQuotaProviderID(
                    section.rows.map { ($0.quotaProviderID, $0.totalTokens) }
                )
            )
        }
    }
}

/// 状态栏下拉菜单的 Harness 视角数据：全局今日汇总 + 按客户端分段的今日用量。
///
/// 与设置页 `clientProviderUsageByClient` 的区别在时间口径：设置页是「最近 7 天按
/// provider/套餐拆行」的诊断视图，菜单是「今天按客户端 → 模型拆行」的一眼概览。
struct HarnessTodaySummary: Equatable, Sendable {
    /// 模型名缺失行的显示名。取空白/空名归一到这一行，而不是让同一段里出现两行
    /// `nil`。
    static let missingModelNameText = "模型名缺失"

    let dayStart: Date
    let buckets: TokenUsageBuckets
    let value: MixedCurrencyEstimate
    /// 按今日 token 降序；没有今日活动的客户端整段不出现。
    let sections: [HarnessSection]
    /// 任一启用数据源正在扫描本地用量 → 全局汇总块显示「计算中…」。
    /// 取自各卡的 `effectiveLocalUsageFreshness`（卡级聚合已按"扫描 > 失败 > 脏 > 干净"
    /// 取最差），所以任一来源在扫就点亮，与 dock 浮层那枚胶囊同一口径。
    let isScanningLocalUsage: Bool
    /// 各卡本地用量最近一次扫描时间的最大值；`nil` = 还没有任何来源扫出过。
    /// 全 idle 时全局汇总块显示「更新于 HH:mm」。
    let localUsageScannedAt: Date?

    var totalTokens: Int { buckets.totalTokens }
    var cacheHitRate: Double? { Self.cacheHitRate(for: buckets) }
    var valueText: String { value.displayText }
    var isEmpty: Bool { sections.isEmpty }

    /// 从各 provider 卡的 `usageProjection` 汇总出「今天」这一屏。
    ///
    /// 口径：只消费公开的 `status.usageProjection(for:)`，因此投影层重构
    /// （并行任务 D）不牵动这里。空贡献按设置页同一 `hasActivity` 判定跳过
    /// （`ClientUsageAggregation.clientProviderUsageByClient` 的 guard）；贡献里
    /// 没有任何今日样本时同样不产生行——「今天」这一屏不该出现 7 天前的活动。
    static func summarize(
        statuses: [ProviderStatus],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HarnessTodaySummary {
        let dayStart = calendar.startOfDay(for: now)
        var samplesByRow: [HarnessRowKey: HarnessRowAccumulator] = [:]
        // 段级速度的样本全集：按 clientID 收集**今日全部样本**（与行分组同一次
        // 遍历、同一个 isToday 谓词，所以恒等于段内各行样本的并集）。段速度在
        // 并集上算 Σ/Σ，而不是各行速率的平均——后者会被样本量小的行带偏。
        var samplesByClient: [String: [LocalTokenUsageSample]] = [:]
        var displayNameByClient: [String: String] = [:]
        var truncatedClients: Set<String> = []
        var isScanningLocalUsage = false
        var localUsageScannedAt: Date?

        for status in statuses {
            let quotaProviderID = status.kind.quotaProviderID
            let peakWindow = status.deepseekPeakWindow ?? .defaultWindow
            let projection = status.usageProjection(for: status.lastSuccess)
            // 新鲜度取**卡级**聚合：任一来源在扫就报"计算中"，扫描时间取最大值。
            if status.effectiveLocalUsageFreshness == .scanning {
                isScanningLocalUsage = true
            }
            if let scannedAt = projection.scannedAt {
                localUsageScannedAt = max(localUsageScannedAt ?? scannedAt, scannedAt)
            }
            for contribution in projection.contributions {
                guard contribution.hasActivity else { continue }
                if displayNameByClient[contribution.clientID] == nil {
                    displayNameByClient[contribution.clientID] = contribution.displayName
                }
                if contribution.isTruncated {
                    truncatedClients.insert(contribution.clientID)
                }
                for sample in contribution.recentSamples where isToday(sample.completedAt, dayStart: dayStart, calendar: calendar) {
                    let key = HarnessRowKey(
                        clientID: contribution.clientID,
                        quotaProviderID: quotaProviderID,
                        modelName: normalizedModelName(sample.modelName)
                    )
                    samplesByRow[key, default: HarnessRowAccumulator(peakWindow: peakWindow)].samples.append(sample)
                    samplesByClient[contribution.clientID, default: []].append(sample)
                }
            }
        }

        let rows = samplesByRow.map { key, accumulator in
            HarnessModelRow(
                dayStart: dayStart,
                clientID: key.clientID,
                quotaProviderID: key.quotaProviderID,
                modelName: key.modelName,
                samples: accumulator.samples,
                deepseekPeakWindow: accumulator.peakWindow,
                calendar: calendar
            )
        }

        let sections = Dictionary(grouping: rows, by: \.clientID).map { clientID, clientRows in
            let descriptor = ClientDescriptor.all.first { $0.id == clientID }
            return HarnessSection(
                clientID: clientID,
                displayName: descriptor?.displayName
                    ?? displayNameByClient[clientID]
                    ?? clientID,
                iconSystemName: descriptor?.iconSystemName ?? "terminal",
                buckets: Self.sum(clientRows.map(\.buckets)),
                tokensPerSecond: LocalUsageSummaryBuilder.windowTokenRate(
                    samples: samplesByClient[clientID] ?? []
                ),
                value: MixedCurrencyEstimate(estimates: clientRows.map(\.costEstimate)),
                rows: clientRows.sorted(by: modelRowOrder),
                isTruncated: truncatedClients.contains(clientID)
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        return HarnessTodaySummary(
            dayStart: dayStart,
            buckets: Self.sum(rows.map(\.buckets)),
            value: MixedCurrencyEstimate(estimates: rows.map(\.costEstimate)),
            sections: sections,
            isScanningLocalUsage: isScanningLocalUsage,
            localUsageScannedAt: localUsageScannedAt
        )
    }

    /// 行序：今日 token 降序，同量时「模型名缺失」沉底、其余按名称升序。
    static func modelRowOrder(_ lhs: HarnessModelRow, _ rhs: HarnessModelRow) -> Bool {
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        let lhsMissing = lhs.modelName == nil
        let rhsMissing = rhs.modelName == nil
        if lhsMissing != rhsMissing { return rhsMissing }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    /// 缓存命中率 = cacheRead / (input + cacheRead)，分母 0 → nil。
    static func cacheHitRate(for buckets: TokenUsageBuckets) -> Double? {
        let input = max(buckets.input, 0)
        let cache = max(buckets.cacheRead, 0)
        let denominator = Double(input) + Double(cache)
        guard denominator > 0 else { return nil }
        return Double(cache) / denominator
    }

    private static func isToday(_ date: Date, dayStart: Date, calendar: Calendar) -> Bool {
        calendar.isDate(date, inSameDayAs: dayStart)
    }

    /// 空白模型名归一到 `nil`：定价层对空名一律判未定价，保留成两个 key 只会让
    /// 同一段出现两行「无模型名」而其中一行是重复的。
    static func normalizedModelName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else { return nil }
        return trimmed
    }

    private static func sum(_ buckets: [TokenUsageBuckets]) -> TokenUsageBuckets {
        buckets.reduce(TokenUsageBuckets.zero) { acc, next in
            TokenUsageBuckets(
                input: SaturatingArithmetic.add(acc.input, next.input),
                cacheRead: SaturatingArithmetic.add(acc.cacheRead, next.cacheRead),
                output: SaturatingArithmetic.add(acc.output, next.output),
                reasoning: SaturatingArithmetic.add(acc.reasoning, next.reasoning)
            )
        }
    }
}

/// 累加桶：同一个行键可能在多张卡上出现（同一客户端在同一 provider 下的多次
/// 贡献），先攒齐样本再算一次价值，避免同一段出现重复求值。
private struct HarnessRowAccumulator {
    var samples: [LocalTokenUsageSample] = []
    let peakWindow: DeepseekPeakWindow

    init(peakWindow: DeepseekPeakWindow) {
        self.peakWindow = peakWindow
    }
}

/// 「今日汇总」的计算缓存。
///
/// 菜单开着时 `DisplayClock` 每秒 tick 一次，每次 tick 都让 `MenuContentView`
/// 的 body 重 eval，而 body 里原本直接 `HarnessTodaySummary.summarize(...)`——
/// 含每行定价（`MixedCurrencyEstimate` / `ModelCostEstimate`），与改版前同量级，
/// 但**输入没变**。这里把"算一次"与"读一次"分开：body 只读缓存，缓存自己决定
/// 要不要真算。
///
/// 失效口径（诚实版）：**广播驱动**，不靠比对。
/// - `invalidate()` 由 `MenuContentView` 在 `state.statusDidChange` 到达时调用。
///   `AppState` 里所有改 `statuses` 的入口都会 fire 这一次广播
///   （`rebuildStatuses` / `mutateStatus` / `apply*LocalUsage` / `setScanningState`），
///   `statuses` 本身是 `private(set)`，没有旁路写入，所以"没广播 == 数据没变"。
/// - 跨天是唯一不经广播的失效源：`dayStart` 变了意味着"今天"这个口径本身换了，
///   而它不来自任何一次状态变更。这里在读路径上按自然日比对（一次
///   `startOfDay`，可忽略的开销），不额外引入一轮定时器。
///
/// 纯本地状态，不参与任何并发共享：`@MainActor` 隔离，视图以 `@State` 持有。
/// `computeCount` 是留给测试的口径断言（"tick 没有重算"只能这样钉）。
@MainActor
final class HarnessSummaryCache {
    /// 上一次算出的汇总。菜单首次渲染（缓存还是种子的空汇总）读到的就是它。
    private(set) var summary: HarnessTodaySummary
    /// 真算过几次。种子算一次，之后每次真正重算 +1。
    private(set) var computeCount: Int
    private var isStale = true

    init() {
        // 种子：空 statuses 的汇总。空输入是这里唯一"不需要真实数据就能算"的
        // 情形，用它开局省掉"首帧要么崩、要么得等一次广播"的分支。
        summary = HarnessTodaySummary.summarize(statuses: [])
        computeCount = 1
    }

    /// 数据变了（`statusDidChange` 广播 / 配置变更走的是同一条广播）：标脏。
    /// 只标脏不算——真正那次计算留到 body 读的时候（body 未必会重 eval，
    /// 提前算就成了没人读的浪费）。
    func invalidate() {
        isStale = true
    }

    /// body 里的唯一读入口。被标脏或跨天时真算一次，否则原样返回上次的值。
    func value(
        for statuses: [ProviderStatus],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HarnessTodaySummary {
        if isStale || calendar.startOfDay(for: now) != summary.dayStart {
            summary = HarnessTodaySummary.summarize(statuses: statuses, now: now, calendar: calendar)
            computeCount &+= 1
            isStale = false
        }
        return summary
    }
}
