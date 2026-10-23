import Foundation

// MARK: - Fleet UI 投影（L3，§10）

/// 用量 scope：用户在 dock 详情卡上切换，dock 浮层与菜单 hover 卡共用同一个
/// （§10.1）；额度不跟 scope 走（§10.0 两条轴）。仅内存态，不落盘。
enum FleetScope: String, Equatable, Sendable {
    case local
    case fleet
}

/// 生效额度：本机有效 `lastSuccess` 优先，否则 fleet 选举结果（§7.7）。
struct FleetEffectiveQuota: Equatable, Sendable {
    let quota: QuotaInfo?
    let isLocal: Bool
    let sourceNodeName: String?
    let isStale: Bool

    static let unavailable = FleetEffectiveQuota(quota: nil, isLocal: true, sourceNodeName: nil, isStale: false)

    /// 来源标注文案（§10.3）：本机额度不标；他机新鲜 → `来自 X`；陈旧 → `来自 X · 已过期`。
    var sourceTagText: String? {
        guard let quota else { return nil }
        if isLocal { return nil }
        let base = "来自 \(sourceNodeName ?? "其他节点")"
        return isStale ? base + " · 已过期" : base
    }
}

// MARK: - 卡片 fleet 用量（§10.1）

/// 卡片在「全局」scope 下的三个用量区块数据（7 天柱图、逐日价值、额度窗口行）。
struct FleetCardUsage: Equatable, Sendable {
    struct DayValue: Equatable, Sendable {
        let dayKey: String
        let valueText: String
    }

    /// 最近 7 天日桶（柱图口径与本地一致：input 是 uncached、cacheRead 单列）。
    let daily: [UnifiedDailyTokenUsage]
    /// 逐日价值文案（由当日 entries 的金额按币种折算；部分计价会注明）。
    let dayValues: [DayValue]
    /// 额度窗口行（只含该 provider 的 fleet 窗口聚合）。
    let windowRows: [FleetWindowUsageRow]
    /// fleet「今」行（今日 bucket 合计）。
    let todayRow: FleetWindowUsageRow?
    /// fleet 数据本身的新鲜度提示（有节点 stale / 缺范围时说明）。
    let incompleteNotice: String?
}

struct FleetWindowUsageRow: Equatable, Sendable {
    let label: String
    let input: Int
    let cachedInput: Int
    let output: Int
    let reasoning: Int
    /// 单币种原额；多币种混装（罕见）或无计价贡献为 nil。
    let cost: ModelCostEstimate?
    let startAt: Date
    let endAt: Date
    /// 覆盖不完整（缺节点 / 有 stale 贡献者 / incomplete）。
    let incomplete: Bool
}

// MARK: - 菜单 fleet 汇总（§10.2）

/// 菜单顶部「今日全部 / 今日本机」两行 + client → node → model 三层的数据形状。
/// `multiNode == false`（fleet 退化到只有自己）时整棵菜单保持今天的单行形态（§10.6 L）。
struct FleetMenuSummary: Equatable, Sendable {
    struct TotalsRow: Equatable, Sendable {
        let tokens: Int
        let hitRate: Double?
        let valueText: String
        let buckets: TokenUsageBuckets
    }

    struct NodeRow: Identifiable, Equatable, Sendable {
        let id: UUID
        let nodeName: String
        let isLocal: Bool
        let stale: Bool
        let buckets: TokenUsageBuckets
        var totalTokens: Int { buckets.totalTokens }
        let costText: String
    }

    struct ModelRow: Identifiable, Equatable, Sendable {
        var id: String { "\(nodeID.uuidString):\(modelName)" }
        let nodeID: UUID
        let nodeName: String
        let stale: Bool
        let modelName: String
        let buckets: TokenUsageBuckets
        var totalTokens: Int { buckets.totalTokens }
        var hitRate: Double? { HarnessTodaySummary.cacheHitRate(for: buckets) }
        let costText: String
    }

    struct ClientSection: Identifiable, Equatable, Sendable {
        var id: String { clientID }
        let clientID: String
        let displayName: String
        let iconSystemName: String
        /// 段头 = fleet 该 client 的权威日合计（§10.2 口径表）。
        let buckets: TokenUsageBuckets
        var totalTokens: Int { buckets.totalTokens }
        let costText: String
        let isTruncated: Bool
        /// 本机第一，其余按 token 降序（§10.2 节点行排序）。
        let nodes: [NodeRow]
        let models: [ModelRow]
    }

    let multiNode: Bool
    /// 「今日全部」（fleet 合计）。
    let fleetTotals: TotalsRow
    /// 各 client 段（含节点分组与模型明细）。
    let sections: [ClientSection]
}

// MARK: - 投影函数

/// FleetSnapshot → UI 值模型。纯函数；不触碰 AppState / 视图。
enum FleetUsageProjection {
    // MARK: 生效额度

    /// 本机有效 `lastSuccess`（有活跃窗口）优先；否则取 elected（按
    /// quotaProviderID 匹配）。远端生效时 `isLocal == false` 并带来源名。
    static func effectiveQuota(
        status: ProviderStatus?,
        elected: [FleetElectedQuota],
        for quotaProviderID: String
    ) -> FleetEffectiveQuota {
        if let info = status?.lastSuccess, !info.activeModels.isEmpty {
            return FleetEffectiveQuota(quota: info, isLocal: true, sourceNodeName: nil, isStale: false)
        }
        guard let winner = elected.first(where: { $0.quotaProviderID == quotaProviderID }) else {
            return .unavailable
        }
        return FleetEffectiveQuota(
            quota: QuotaInfo(
                models: winner.models,
                resetCredits: winner.resetCredits,
                planLabel: winner.planLabel,
                accountEmail: winner.accountEmail,
                codexUsageDetails: nil,
                fetchedAt: winner.fetchedAt,
                balanceDetail: winner.balanceDetail
            ),
            isLocal: false,
            sourceNodeName: winner.sourceNodeName,
            isStale: winner.isStale
        )
    }

    // MARK: 菜单汇总

    static func menuSummary(
        snapshot: FleetSnapshot,
        localNodeID: UUID?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> FleetMenuSummary? {
        let todayKey = FleetMerger.dayKey(of: now, calendar: calendar)
        guard let todayBucket = snapshot.fleet.dailyBuckets.first(where: { $0.dayKey == todayKey }) else {
            return nil
        }

        let fleetTotals = FleetMenuSummary.TotalsRow(
            tokens: todayBucket.totals.tokensTotal,
            hitRate: hitRate(input: todayBucket.totals.input, cacheRead: todayBucket.totals.cacheRead),
            valueText: costText(entries: todayBucket.entries),
            buckets: buckets(of: todayBucket.totals)
        )

        // client 段：以 fleet 今日 bucket 的 clientProviders 为骨架。
        var sections: [FleetMenuSummary.ClientSection] = []
        let grouped = Dictionary(grouping: todayBucket.clientProviders, by: \.clientID)
        for (clientID, rows) in grouped {
            let descriptor = ClientDescriptor.all.first { $0.id == clientID }
            let sectionBuckets = rows.reduce(TokenUsageBuckets.zero) { acc, row in
                acc + TokenUsageBuckets(input: row.input, cacheRead: row.cacheRead, output: row.output, reasoning: row.reasoning)
            }

            // 节点行：各节点同日 bucket 中该 client 的权威合计。
            var nodeRows: [FleetMenuSummary.NodeRow] = []
            for node in snapshot.nodes {
                guard let nodeToday = node.dailyBuckets.first(where: { $0.dayKey == todayKey }) else { continue }
                let nodeRowsForClient = nodeToday.clientProviders.filter { $0.clientID == clientID }
                guard !nodeRowsForClient.isEmpty else { continue }
                let nodeBuckets = nodeRowsForClient.reduce(TokenUsageBuckets.zero) { acc, row in
                    acc + TokenUsageBuckets(input: row.input, cacheRead: row.cacheRead, output: row.output, reasoning: row.reasoning)
                }
                nodeRows.append(FleetMenuSummary.NodeRow(
                    id: node.nodeID,
                    nodeName: node.nodeName,
                    isLocal: node.nodeID == localNodeID,
                    stale: node.stale,
                    buckets: nodeBuckets,
                    costText: costText(entries: nodeToday.entries.filter { $0.clientID == clientID })
                ))
            }
            nodeRows.sort { lhs, rhs in
                if lhs.isLocal != rhs.isLocal { return lhs.isLocal }
                if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
                return lhs.nodeName < rhs.nodeName
            }

            // 模型行：各节点 entries 明细（不反推段头 totals）。
            var modelRows: [FleetMenuSummary.ModelRow] = []
            for node in snapshot.nodes {
                guard let nodeToday = node.dailyBuckets.first(where: { $0.dayKey == todayKey }) else { continue }
                for entry in nodeToday.entries where entry.clientID == clientID {
                    modelRows.append(FleetMenuSummary.ModelRow(
                        nodeID: node.nodeID,
                        nodeName: node.nodeName,
                        stale: node.stale,
                        modelName: entry.modelName ?? "模型名缺失",
                        buckets: TokenUsageBuckets(input: entry.input, cacheRead: entry.cacheRead, output: entry.output, reasoning: entry.reasoning),
                        costText: entryCostText(value: entry.value, currency: entry.currency)
                    ))
                }
            }

            sections.append(FleetMenuSummary.ClientSection(
                clientID: clientID,
                displayName: descriptor?.displayName ?? clientID,
                iconSystemName: descriptor?.iconSystemName ?? "terminal",
                buckets: sectionBuckets,
                costText: costText(entries: todayBucket.entries.filter { $0.clientID == clientID }),
                isTruncated: todayBucket.sourceTruncated,
                nodes: nodeRows,
                models: modelRows
            ))
        }
        sections.sort { lhs, rhs in
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        return FleetMenuSummary(
            multiNode: snapshot.nodes.count > 1,
            fleetTotals: fleetTotals,
            sections: sections
        )
    }

    // MARK: 卡片用量

    static func cardUsage(
        snapshot: FleetSnapshot,
        quotaProviderID: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> FleetCardUsage? {
        var daily: [UnifiedDailyTokenUsage] = []
        var dayValues: [FleetCardUsage.DayValue] = []
        for bucket in snapshot.fleet.dailyBuckets {
            guard let dayStart = date(fromDayKey: bucket.dayKey, calendar: calendar) else { continue }
            daily.append(UnifiedDailyTokenUsage(
                dayStart: dayStart,
                input: bucket.totals.input,
                cacheRead: bucket.totals.cacheRead,
                output: bucket.totals.output,
                reasoning: bucket.totals.reasoning,
                turns: bucket.totals.turns,
                rounds: bucket.totals.rounds
            ))
            let text = costText(entries: bucket.entries)
            dayValues.append(FleetCardUsage.DayValue(dayKey: bucket.dayKey, valueText: text))
        }

        func singleCurrencyCost(_ valueByCurrency: [String: Double]) -> ModelCostEstimate? {
            guard valueByCurrency.count == 1,
                  let (raw, value) = valueByCurrency.first,
                  let currency = ModelPriceCurrency(rawValue: raw)
            else { return nil }
            return ModelCostEstimate(value: value, currency: currency, pricedModelNames: [], unpricedModelNames: [])
        }

        var windowRows: [FleetWindowUsageRow] = []
        var anyIncomplete = false
        for aggregate in snapshot.fleet.windowUsage where aggregate.quotaProviderID == quotaProviderID {
            let label = windowLabel(for: aggregate.windowKind)
            let incomplete = !aggregate.missingNodeIDs.isEmpty
                || !aggregate.staleNodeIDs.isEmpty
                || !aggregate.complete
            anyIncomplete = anyIncomplete || incomplete
            windowRows.append(FleetWindowUsageRow(
                label: label,
                input: aggregate.input,
                cachedInput: aggregate.cacheRead,
                output: aggregate.output,
                reasoning: aggregate.reasoning,
                cost: singleCurrencyCost(aggregate.valueByCurrency),
                startAt: aggregate.startAt,
                endAt: aggregate.endAt,
                incomplete: incomplete
            ))
        }

        // fleet「今」行：今日 bucket 的权威合计。
        var todayRow: FleetWindowUsageRow?
        let todayKey = FleetMerger.dayKey(of: now, calendar: calendar)
        if let todayBucket = snapshot.fleet.dailyBuckets.first(where: { $0.dayKey == todayKey }) {
            todayRow = FleetWindowUsageRow(
                label: "今",
                input: todayBucket.totals.input,
                cachedInput: todayBucket.totals.cacheRead,
                output: todayBucket.totals.output,
                reasoning: todayBucket.totals.reasoning,
                cost: singleCurrencyCost(dailyValueByCurrency(entries: todayBucket.entries)),
                startAt: date(fromDayKey: todayKey, calendar: calendar) ?? now,
                endAt: now,
                incomplete: todayBucket.sourceTruncated || !todayBucket.totalsComplete
            )
        }

        return FleetCardUsage(
            daily: daily,
            dayValues: dayValues,
            windowRows: windowRows,
            todayRow: todayRow,
            incompleteNotice: anyIncomplete ? "部分节点缺该范围或已离线" : nil
        )
    }

    /// 一批 entries 的金额按币种汇总（供「今」行的单币种 cost 判定）。
    private static func dailyValueByCurrency(entries: [FleetUsageEntry]) -> [String: Double] {
        var result: [String: Double] = [:]
        for entry in entries {
            guard let value = entry.value, let currency = entry.currency else { continue }
            result[currency.rawValue, default: 0] += value
        }
        return result
    }

    static func windowLabel(for kind: String) -> String {
        switch kind {
        case "interval": return "5h"
        case "weekly": return "周"
        case "glmOffPeak": return "闲"
        default: return kind
        }
    }

    // MARK: 数值工具

    private static func buckets(of totals: FleetTotals) -> TokenUsageBuckets {
        TokenUsageBuckets(
            input: totals.input,
            cacheRead: totals.cacheRead,
            output: totals.output,
            reasoning: totals.reasoning
        )
    }

    private static func hitRate(input: Int, cacheRead: Int) -> Double? {
        let denominator = Double(max(0, input)) + Double(max(0, cacheRead))
        guard denominator > 0 else { return nil }
        return Double(max(0, cacheRead)) / denominator
    }

    private static func date(fromDayKey dayKey: String, calendar: Calendar) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return calendar.date(from: comps)
    }

    /// 一批明细行的金额 → 跨币折算文案；有未计价贡献时注明「部分计价」。
    static func costText(entries: [FleetUsageEntry]) -> String {
        let estimates = entries.compactMap { entry -> ModelCostEstimate? in
            guard let value = entry.value, let currency = entry.currency else { return nil }
            return ModelCostEstimate(
                value: value,
                currency: currency,
                pricedModelNames: [entry.modelName ?? entry.clientID],
                unpricedModelNames: []
            )
        }
        guard !estimates.isEmpty else { return "未定价" }
        let mixed = MixedCurrencyEstimate(estimates: estimates).displayText
        let anyUnpriced = entries.contains { $0.value == nil }
        return anyUnpriced ? mixed + "（部分计价）" : mixed
    }

    private static func entryCostText(value: Double?, currency: ModelPriceCurrency?) -> String {
        guard let value, let currency else { return "未定价" }
        return ModelCostEstimate(
            value: value,
            currency: currency,
            pricedModelNames: [],
            unpricedModelNames: []
        ).displayText
    }

}

private extension FleetTotals {
    var tokensTotal: Int {
        SaturatingArithmetic.sum([
            SaturatingArithmetic.add(input, cacheRead),
            SaturatingArithmetic.add(output, reasoning)
        ])
    }
}

private extension TokenUsageBuckets {
    static func + (lhs: TokenUsageBuckets, rhs: TokenUsageBuckets) -> TokenUsageBuckets {
        TokenUsageBuckets(
            input: SaturatingArithmetic.add(lhs.input, rhs.input),
            cacheRead: SaturatingArithmetic.add(lhs.cacheRead, rhs.cacheRead),
            output: SaturatingArithmetic.add(lhs.output, rhs.output),
            reasoning: SaturatingArithmetic.add(lhs.reasoning, rhs.reasoning)
        )
    }
}


/// hover 卡 / dock 浮层共用的 fleet 上下文（§10.1）：scope 分段控制、fleet 用量
/// 区块数据、生效额度（来源标注从它派生）。`onScopeChange` 闭包不参与相等比较。
struct FleetCardContext {
    var scope: FleetScope = .local
    /// fleet 只有 1 台机器时不显示分段（§10.6 L：退化成今天的样子）。
    var multiNode: Bool = false
    var usage: FleetCardUsage?
    var effectiveQuota: FleetEffectiveQuota?
    var onScopeChange: ((FleetScope) -> Void)?
}

extension FleetCardContext: Equatable {
    static func == (lhs: FleetCardContext, rhs: FleetCardContext) -> Bool {
        lhs.scope == rhs.scope
            && lhs.multiNode == rhs.multiNode
            && lhs.usage == rhs.usage
            && lhs.effectiveQuota == rhs.effectiveQuota
    }
}
