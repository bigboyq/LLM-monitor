import Foundation
import CryptoKit

// MARK: - Fleet UI 投影（L3，§10）

/// 用量 scope：用户在 dock 详情卡上切换，dock 浮层与菜单 hover 卡共用同一个
/// （§10.1）；额度不跟 scope 走（§10.0 两条轴）。仅内存态，不落盘。
enum FleetScope: Equatable, Hashable, Sendable {
    case local
    case fleet
    /// 看某个具体节点的数据（dock 分段控制 2026-10-24 扩展）。
    case node(UUID)
}

/// dock 分段控制里的节点选项（本机节点由「本机」承担，这里只列远端）。
struct FleetNodeChoice: Equatable, Hashable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let stale: Bool
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
    /// 今日全局日桶缺席时，不能把空数组解释为已同步的零用量。
    var dailyNotice: String? = nil
}

struct FleetWindowUsageRow: Equatable, Sendable {
    let label: String
    let input: Int
    let cachedInput: Int
    let output: Int
    let reasoning: Int
    /// 单币种原额；多币种混装（罕见）或无计价贡献为 nil。
    let cost: ModelCostEstimate?
    /// 混币金额文案（多币种时给出 CNY 折算总额 + USD 构成标注）；单币种为 nil，
    /// 由 `cost` 渲染。两者互斥：文案优先于单币种 estimate。
    let costText: String?
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
        /// 段内今日 token 最大的 quota provider（菜单今日占比条的段色归属）。
        /// 由同桶 clientProviders 行算出；本地路径（`HarnessSection`）在视图层
        /// 按模型行现算，两条路径共用同一个纯函数与并列口径。
        var dominantQuotaProviderID: String? = nil
        /// 本机第一，其余按 token 降序（§10.2 节点行排序）。
        let nodes: [NodeRow]
        let models: [ModelRow]
        /// 跨节点按模型名合并的明细（全局视图用，不分设备）。
        let mergedModels: [ModelRow]
    }

    let multiNode: Bool
    /// false 表示今天的权威日桶尚不可用；此时 totals 的零值只是占位，不得显示为 0。
    var hasDailyData: Bool = true
    /// 日桶缺席或部分来源不可用时给用户的明确说明。
    var dailyNotice: String? = nil
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
            // A singleton continues to use the legacy local menu. For multi-node
            // scope, keep a summary-shaped unavailable state so the caller cannot
            // fall through to local values while the selector still says “全局”.
            guard snapshot.nodes.count > 1 else { return nil }
            return unavailableMenuSummary(
                multiNode: true,
                notice: "全局今日用量尚未同步"
            )
        }

        let fleetTotals = FleetMenuSummary.TotalsRow(
            tokens: todayBucket.totals.tokensTotal,
            hitRate: hitRate(input: todayBucket.totals.input, cacheRead: todayBucket.totals.cacheRead),
            valueText: costText(
                entries: todayBucket.entries,
                complete: todayBucket.modelDetailsComplete && todayBucket.totalsComplete && !todayBucket.sourceTruncated
            ),
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
                // 节点在该客户端下没有实际用量（全零行）→ 不出节点行（用户裁定）。
                guard nodeBuckets.totalTokens > 0 else { continue }
                nodeRows.append(FleetMenuSummary.NodeRow(
                    id: node.nodeID,
                    nodeName: node.nodeName,
                    isLocal: node.nodeID == localNodeID,
                    stale: node.stale,
                    buckets: nodeBuckets,
                    costText: costText(
                        entries: nodeToday.entries.filter { $0.clientID == clientID },
                        complete: nodeToday.modelDetailsComplete && nodeToday.totalsComplete && !nodeToday.sourceTruncated
                    )
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
                    let entryBuckets = TokenUsageBuckets(
                        input: entry.input, cacheRead: entry.cacheRead,
                        output: entry.output, reasoning: entry.reasoning
                    )
                    guard entryBuckets.totalTokens > 0 else { continue }
                    modelRows.append(FleetMenuSummary.ModelRow(
                        nodeID: node.nodeID,
                        nodeName: node.nodeName,
                        stale: node.stale,
                        modelName: entry.modelName ?? "模型名缺失",
                        buckets: TokenUsageBuckets(input: entry.input, cacheRead: entry.cacheRead, output: entry.output, reasoning: entry.reasoning),
                        costText: entryCostText(entry: entry)
                    ))
                }
            }

            // 段本身全零（该客户端今天 fleet 内无实际用量）→ 整段不出。
            guard sectionBuckets.totalTokens > 0 else { continue }
            sections.append(FleetMenuSummary.ClientSection(
                clientID: clientID,
                displayName: descriptor?.displayName ?? clientID,
                iconSystemName: descriptor?.iconSystemName ?? "terminal",
                buckets: sectionBuckets,
                costText: costText(
                    entries: todayBucket.entries.filter { $0.clientID == clientID },
                    complete: todayBucket.modelDetailsComplete && todayBucket.totalsComplete && !todayBucket.sourceTruncated
                ),
                isTruncated: todayBucket.sourceTruncated,
                dominantQuotaProviderID: dominantProviderID(in: rows),
                nodes: nodeRows,
                models: modelRows,
                mergedModels: Self.mergedModelRows(
                    entries: todayBucket.entries.filter { $0.clientID == clientID }
                )
            ))
        }
        sections.sort { lhs, rhs in
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        return FleetMenuSummary(
            multiNode: snapshot.nodes.count > 1,
            dailyNotice: dailyBucketNotice(todayBucket),
            fleetTotals: fleetTotals,
            sections: sections
        )
    }

    /// 段内今日 token 最大的 quota provider。与本地路径（`HarnessSection` 的
    /// 模型行）共用 `HarnessClientSegment.dominantQuotaProviderID` 同一个纯函数，
    /// 并列口径逐字一致：取字典序小者。
    private static func dominantProviderID(in rows: [FleetClientProviderUsage]) -> String? {
        HarnessClientSegment.dominantQuotaProviderID(rows.map { row in
            (row.quotaProviderID, SaturatingArithmetic.sum([
                SaturatingArithmetic.add(row.input, row.cacheRead),
                SaturatingArithmetic.add(row.output, row.reasoning)
            ]))
        })
    }

    private static func unavailableMenuSummary(
        multiNode: Bool,
        notice: String
    ) -> FleetMenuSummary {
        FleetMenuSummary(
            multiNode: multiNode,
            hasDailyData: false,
            dailyNotice: notice,
            fleetTotals: FleetMenuSummary.TotalsRow(
                tokens: 0,
                hitRate: nil,
                valueText: "—",
                buckets: .zero
            ),
            sections: []
        )
    }

    private static func dailyBucketNotice(_ bucket: FleetDailyBucket) -> String? {
        if let sources = bucket.unavailableSources, !sources.isEmpty {
            let sourceLabels = Set(sources.map { source in
                let client = ClientDescriptor.all.first { $0.id == source.clientID }?.displayName
                    ?? source.clientID
                let reason: String
                switch source.reason {
                case .failed: reason = "扫描失败"
                case .scanning: reason = "扫描中"
                case .truncated: reason = "扫描受预算限制"
                }
                return "\(client)\(reason)"
            }).sorted()
            return "部分来源暂不可用（\(sourceLabels.joined(separator: "、"))），当前数据可能包含上次数据"
        }
        guard !bucket.totalsComplete || bucket.sourceTruncated else { return nil }
        return "部分来源暂不可用，当前数据可能包含上次数据"
    }

    /// 单节点的菜单汇总：合成「只含该节点」的快照复用 `menuSummary`——
    /// 段骨架/节点行/模型明细逻辑一份，节点视图天然没有节点层（只有它自己）。
    static func nodeMenuSummary(
        snapshot: FleetSnapshot,
        nodeID: UUID,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> FleetMenuSummary? {
        guard let node = snapshot.nodes.first(where: { $0.nodeID == nodeID }) else { return nil }
        let todayKey = FleetMerger.dayKey(of: now, calendar: calendar)
        guard node.dailyBuckets.contains(where: { $0.dayKey == todayKey }) else {
            return unavailableMenuSummary(
                multiNode: false,
                notice: "该节点今日用量尚未同步"
            )
        }
        let single = FleetSnapshot(
            protocolVersion: snapshot.protocolVersion,
            hubUUID: snapshot.hubUUID,
            generation: snapshot.generation,
            hub: snapshot.hub,
            generatedAt: snapshot.generatedAt,
            nodes: [node],
            fleet: FleetAggregate(dailyBuckets: node.dailyBuckets, windowUsage: []),
            electedQuotas: snapshot.electedQuotas
        )
        return menuSummary(snapshot: single, localNodeID: nil, now: now, calendar: calendar)
    }

    /// 段内明细：直接用 fleet 日桶里**已合并**的模型条目（hub 侧同币相加、
    /// 币种冲突置空），token 四桶 + 金额逐条带出；按 token 降序。
    static func mergedModelRows(entries: [FleetUsageEntry]) -> [FleetMenuSummary.ModelRow] {
        entries.compactMap { entry in
            let buckets = TokenUsageBuckets(
                input: entry.input, cacheRead: entry.cacheRead,
                output: entry.output, reasoning: entry.reasoning
            )
            guard buckets.totalTokens > 0 else { return nil }
            return FleetMenuSummary.ModelRow(
                // 合并行没有「节点」概念，但 ModelRow 的身份由 nodeID 拼出；
                // 这里用条目键派生稳定 UUID（同一模型每次算出同一个身份），
                // 否则每次重算都是全新 id → ForEach 判定为另一批行，整段重建。
                nodeID: Self.stableUUID(for: "\(entry.clientID)|\(entry.quotaProviderID)|\(entry.modelName ?? "")"),
                nodeName: "", stale: false,
                modelName: entry.modelName ?? "模型名缺失",
                buckets: buckets,
                costText: entryCostText(entry: entry)
            )
        }
        .sorted { $0.totalTokens > $1.totalTokens }
    }

    /// 由字符串键派生稳定 UUID（RFC 4122 v4 形）。同一键恒得同一 UUID：
    /// 用来给「无节点归属」的合并行一个跨帧不变的身份。
    static func stableUUID(for key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40   // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: 卡片用量

    static func cardUsage(
        snapshot: FleetSnapshot,
        quotaProviderID: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        preferredWindowEnds: [String: Date] = [:]
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
            let detailsComplete = bucket.modelDetailsComplete && bucket.totalsComplete && !bucket.sourceTruncated
            let text = costText(entries: bucket.entries, complete: detailsComplete)
            dayValues.append(FleetCardUsage.DayValue(dayKey: bucket.dayKey, valueText: text))
        }

        // 范围选择（§10.7.1 W 裁定，2026-10-24 已确认）：同 (model, kind) 存在
        // 多个已报告范围时，优先取与当前生效额度边界**完全一致**的范围，
        // 无匹配取 `endAt` 最新者；其余范围不展示（范围不同的摘要不混加）。
        struct RangeGroupKey: Hashable {
            let modelID: String
            let windowKind: String
        }
        var selectedAggregates: [RangeGroupKey: FleetWindowAggregate] = [:]
        for aggregate in snapshot.fleet.windowUsage where aggregate.quotaProviderID == quotaProviderID {
            let key = RangeGroupKey(modelID: aggregate.modelID, windowKind: aggregate.windowKind)
            if let current = selectedAggregates[key] {
                selectedAggregates[key] = preferredRange(
                    aggregate, over: current,
                    preferredEnd: preferredWindowEnds[aggregate.windowKind]
                )
            } else {
                selectedAggregates[key] = aggregate
            }
        }

        var windowRows: [FleetWindowUsageRow] = []
        var anyIncomplete = false
        for aggregate in selectedAggregates.values.sorted(by: {
            $0.windowKind == $1.windowKind
                ? $0.modelID < $1.modelID
                : $0.windowKind < $1.windowKind
        }) {
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
                costText: currencyCostText(
                    aggregate.valueByCurrency,
                    partial: aggregate.coverage != .full || !aggregate.complete
                        || !aggregate.missingNodeIDs.isEmpty || !aggregate.staleNodeIDs.isEmpty
                ),
                startAt: aggregate.startAt,
                endAt: aggregate.endAt,
                incomplete: incomplete
            ))
        }

        // fleet「今」行：今日 bucket 的权威合计。
        var todayRow: FleetWindowUsageRow?
        let todayKey = FleetMerger.dayKey(of: now, calendar: calendar)
        if let todayBucket = snapshot.fleet.dailyBuckets.first(where: { $0.dayKey == todayKey }) {
            let todayValues = dailyValueByCurrency(entries: todayBucket.entries)
            let todayCostPartial = !todayBucket.modelDetailsComplete || !todayBucket.totalsComplete
                || todayBucket.sourceTruncated || hasPartialCost(entries: todayBucket.entries)
            todayRow = FleetWindowUsageRow(
                label: "今",
                input: todayBucket.totals.input,
                cachedInput: todayBucket.totals.cacheRead,
                output: todayBucket.totals.output,
                reasoning: todayBucket.totals.reasoning,
                cost: singleCurrencyCost(todayValues),
                costText: currencyCostText(todayValues, partial: todayCostPartial),
                startAt: date(fromDayKey: todayKey, calendar: calendar) ?? now,
                endAt: now,
                incomplete: todayBucket.sourceTruncated || !todayBucket.totalsComplete
            )
        }

        let todayBucket = snapshot.fleet.dailyBuckets.first { $0.dayKey == FleetMerger.dayKey(of: now, calendar: calendar) }
        return FleetCardUsage(
            daily: daily,
            dayValues: dayValues,
            windowRows: windowRows,
            todayRow: todayRow,
            incompleteNotice: anyIncomplete || hasStaleDailyContribution(in: snapshot)
                ? "部分节点缺该范围或已离线"
                : nil,
            dailyNotice: todayBucket.map(dailyBucketNotice)
                ?? "全局今日用量尚未同步"
        )
    }

    /// Daily buckets remain visible when a node goes offline. Surface that stale
    /// contribution even if this provider has no current window rows, while ignoring
    /// offline nodes whose displayed daily buckets contain no usage or amount.
    private static func hasStaleDailyContribution(in snapshot: FleetSnapshot) -> Bool {
        let displayedDayKeys = Set(snapshot.fleet.dailyBuckets.map(\.dayKey))
        return snapshot.nodes.contains { node in
            guard node.stale else { return false }
            return node.dailyBuckets.contains { bucket in
                guard displayedDayKeys.contains(bucket.dayKey) else { return false }
                let hasUsage = bucket.totals.tokensTotal > 0
                    || bucket.totals.turns > 0
                    || bucket.totals.rounds > 0
                let hasAmount = bucket.entries.contains { $0.value.map { $0 != 0 } == true }
                return hasUsage || hasAmount
            }
        }
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

    /// 单币种金额 estimate：恰好一种币种时给出原额，多币种 / 无计价为 nil
    /// （多币种走 `mixedCostText` 的文案口径，不给跨币种假总价）。
    private static func singleCurrencyCost(_ valueByCurrency: [String: Double]) -> ModelCostEstimate? {
        guard valueByCurrency.count == 1,
              let (raw, value) = valueByCurrency.first,
              let currency = ModelPriceCurrency(rawValue: raw)
        else { return nil }
        return ModelCostEstimate(value: value, currency: currency, pricedModelNames: [], unpricedModelNames: [])
    }

    /// 混币金额文案（≥2 种币种时给出 CNY 折算总额 + USD 构成标注）；单币种或
    /// 无计价贡献返回 nil，由 `cost`（单币种 estimate）渲染。
    ///
    /// 口径与菜单的 `costText(entries:)` 一致（`MixedCurrencyEstimate.displayText`）：
    /// 混币不是「没有金额」，不能退化成「—」（会被读成无数据）。
    private static func mixedCostText(_ valueByCurrency: [String: Double]) -> String? {
        guard valueByCurrency.count > 1 else { return nil }
        let estimates = valueByCurrency.compactMap { raw, value -> ModelCostEstimate? in
            guard let currency = ModelPriceCurrency(rawValue: raw) else { return nil }
            return ModelCostEstimate(
                value: value, currency: currency,
                pricedModelNames: [], unpricedModelNames: []
            )
        }
        guard !estimates.isEmpty else { return nil }
        return MixedCurrencyEstimate(estimates: estimates).displayText
    }

    /// 单币种完整金额由 `cost` 渲染；混币或覆盖不完整时返回明确文案。
    private static func currencyCostText(_ values: [String: Double], partial: Bool) -> String? {
        if values.count > 1 {
            guard let text = mixedCostText(values) else { return nil }
            return partial ? text + "（部分计价）" : text
        }
        guard let estimate = singleCurrencyCost(values), partial else { return nil }
        return estimate.displayText + "（部分计价）"
    }

    private static func hasPartialCost(entries: [FleetUsageEntry]) -> Bool {
        entries.contains {
            $0.value == nil || $0.currency == nil || $0.coverage != .full || $0.truncated
        }
    }

    /// 边界命中的范围优先于 endAt 更新的范围；两边都不命中取 endAt 新者。
    static func preferredRange(
        _ candidate: FleetWindowAggregate,
        over current: FleetWindowAggregate,
        preferredEnd: Date?
    ) -> FleetWindowAggregate {
        if let preferredEnd {
            let candidateMatches = FleetISO8601.matchesWholeSecond(candidate.endAt, preferredEnd)
            let currentMatches = FleetISO8601.matchesWholeSecond(current.endAt, preferredEnd)
            if candidateMatches && !currentMatches { return candidate }
            if currentMatches && !candidateMatches { return current }
        }
        return candidate.endAt >= current.endAt ? candidate : current
    }

    private static func preferredRange(
        _ candidate: FleetWindowUsage,
        over current: FleetWindowUsage,
        preferredEnd: Date?
    ) -> FleetWindowUsage {
        if let preferredEnd {
            let candidateMatches = FleetISO8601.matchesWholeSecond(candidate.endAt, preferredEnd)
            let currentMatches = FleetISO8601.matchesWholeSecond(current.endAt, preferredEnd)
            if candidateMatches && !currentMatches { return candidate }
            if currentMatches && !candidateMatches { return current }
        }
        return candidate.endAt >= current.endAt ? candidate : current
    }

    /// 单节点口径的卡片用量：该节点的 7 天日桶 + 窗口行 + 今行（不做跨节点聚合）。
    static func nodeCardUsage(
        node: FleetNodeSnapshot,
        quotaProviderID: String,
        now: Date = Date(),
        calendar: Calendar = .current,
        preferredWindowEnds: [String: Date] = [:]
    ) -> FleetCardUsage {
        var daily: [UnifiedDailyTokenUsage] = []
        var dayValues: [FleetCardUsage.DayValue] = []
        for bucket in node.dailyBuckets {
            guard let dayStart = date(fromDayKey: bucket.dayKey, calendar: calendar) else { continue }
            daily.append(UnifiedDailyTokenUsage(
                dayStart: dayStart,
                input: bucket.totals.input, cacheRead: bucket.totals.cacheRead,
                output: bucket.totals.output, reasoning: bucket.totals.reasoning,
                turns: bucket.totals.turns, rounds: bucket.totals.rounds
            ))
            dayValues.append(FleetCardUsage.DayValue(
                dayKey: bucket.dayKey,
                valueText: costText(
                    entries: bucket.entries,
                    complete: bucket.modelDetailsComplete && bucket.totalsComplete && !bucket.sourceTruncated
                )
            ))
        }

        struct RangeGroupKey: Hashable {
            let modelID: String
            let windowKind: String
        }
        var selectedRows: [RangeGroupKey: FleetWindowUsage] = [:]
        for row in node.windowUsage where row.quotaProviderID == quotaProviderID {
            let key = RangeGroupKey(modelID: row.modelID, windowKind: row.windowKind)
            if let current = selectedRows[key] {
                selectedRows[key] = preferredRange(
                    row,
                    over: current,
                    preferredEnd: preferredWindowEnds[row.windowKind]
                )
            } else {
                selectedRows[key] = row
            }
        }
        var windowRows: [FleetWindowUsageRow] = []
        for row in selectedRows.values.sorted(by: {
            $0.windowKind == $1.windowKind
                ? $0.modelID < $1.modelID
                : $0.windowKind < $1.windowKind
        }) {
            let partialCost = row.coverage != .full || !row.complete || row.sourceTruncated
            windowRows.append(FleetWindowUsageRow(
                label: windowLabel(for: row.windowKind),
                input: row.input, cachedInput: row.cacheRead,
                output: row.output, reasoning: row.reasoning,
                cost: ModelCostEstimate(
                    value: row.value, currency: row.currency,
                    pricedModelNames: [], unpricedModelNames: []
                ),
                costText: currencyCostText(
                    row.value.flatMap { value in
                        row.currency.map { [$0.rawValue: value] }
                    } ?? [:],
                    partial: partialCost
                ),
                startAt: row.startAt, endAt: row.endAt,
                incomplete: row.sourceTruncated || !row.complete
            ))
        }
        let todayKey = FleetMerger.dayKey(of: now, calendar: calendar)
        let todayBucket = node.dailyBuckets.first { $0.dayKey == todayKey }
        var todayRow: FleetWindowUsageRow?
        if let todayBucket {
            // 节点口径的「今」行同样给出金额（节点上报的 entries 带金额）；
            // 口径与 fleet scope 一致，避免同一张卡两个 scope 金额自相矛盾。
            let todayValues = dailyValueByCurrency(entries: todayBucket.entries)
            let todayCostPartial = !todayBucket.modelDetailsComplete || !todayBucket.totalsComplete
                || todayBucket.sourceTruncated || hasPartialCost(entries: todayBucket.entries)
            todayRow = FleetWindowUsageRow(
                label: "今",
                input: todayBucket.totals.input, cachedInput: todayBucket.totals.cacheRead,
                output: todayBucket.totals.output, reasoning: todayBucket.totals.reasoning,
                cost: singleCurrencyCost(todayValues),
                costText: currencyCostText(todayValues, partial: todayCostPartial),
                startAt: date(fromDayKey: todayKey, calendar: calendar) ?? now, endAt: now,
                incomplete: todayBucket.sourceTruncated || !todayBucket.totalsComplete || !todayBucket.modelDetailsComplete
            )
        }
        return FleetCardUsage(
            daily: daily, dayValues: dayValues, windowRows: windowRows,
            todayRow: todayRow,
            incompleteNotice: node.stale ? "节点离线，展示最后上报数据" : nil,
            dailyNotice: todayBucket.map(dailyBucketNotice)
                ?? "该节点今日用量尚未同步"
        )
    }

    static func windowLabel(for kind: String) -> String {
        switch kind {
        case "interval": return "5h"
        case "weekly": return "周"
        case "glmOffPeak": return "闲"
        // 「免 / 速 / 它」直接引用本地卡的行标签常量：fleet 路径按行标签从
        // windowRows 取行（`ProviderCardView` 的 fleetRow 映射），两端必须逐字
        // 同源，改文案只动 `QuotaWindowUsageSection` 一处（测试钉住）。
        case "glmStartPlan": return QuotaWindowUsageSection.startPlanRowLabel
        case "glmHighspeed": return QuotaWindowUsageSection.highSpeedRowLabel
        case "glmOtherPlan": return QuotaWindowUsageSection.otherPlanRowLabel
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
        return FleetMerger.gregorianDayCalendar(matching: calendar).date(from: comps)
    }

    /// 一批明细行的金额 → 跨币折算文案；有未计价贡献时注明「部分计价」。
    static func costText(entries: [FleetUsageEntry], complete: Bool = true) -> String {
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
        let partial = !complete || hasPartialCost(entries: entries)
        return partial ? mixed + "（部分计价）" : mixed
    }

    private static func entryCostText(entry: FleetUsageEntry) -> String {
        guard let value = entry.value, let currency = entry.currency else { return "未定价" }
        let text = ModelCostEstimate(
            value: value,
            currency: currency,
            pricedModelNames: [],
            unpricedModelNames: []
        ).displayText
        return entry.coverage == .full && !entry.truncated ? text : text + "（部分计价）"
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
    /// 分段控制里的远端节点选项（全局 / 本机之外）。
    var nodeChoices: [FleetNodeChoice] = []
    /// **全部 scope 的用量变体**一次预构建：dock 浮层卡片是打开时的静态
    /// 快照，切换 scope 不能依赖宿主重建——卡片按当前 scope 自取。
    var fleetUsage: FleetCardUsage?
    var nodeUsages: [UUID: FleetCardUsage] = [:]
    var effectiveQuota: FleetEffectiveQuota?
    var onScopeChange: ((FleetScope) -> Void)?
}

extension FleetCardContext: Equatable {
    static func == (lhs: FleetCardContext, rhs: FleetCardContext) -> Bool {
        lhs.scope == rhs.scope
            && lhs.multiNode == rhs.multiNode
            && lhs.nodeChoices == rhs.nodeChoices
            && lhs.fleetUsage == rhs.fleetUsage
            && lhs.nodeUsages == rhs.nodeUsages
            && lhs.effectiveQuota == rhs.effectiveQuota
    }
}
