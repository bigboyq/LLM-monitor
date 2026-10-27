import Foundation
import CryptoKit

// MARK: - 角色（§3）

/// 同步角色由配置**单源派生**：无 upstream 的实例是 hub，有 upstream 的是 node，
/// 未启用则完全不参与。角色判定与 server 启动在同一个 switch 分支里，
/// 不存在「既监听又上报」的可能。
enum SyncRole: Equatable, Sendable {
    /// 无 upstream → 主节点
    case hub
    /// 有 upstream → 副节点
    case node
    /// sync 未启用 → 不参与
    case off

    static func derive(config: AppConfig) -> SyncRole {
        guard config.sync?.enabled == true else { return .off }
        let upstream = config.sync?.hubURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return (upstream?.isEmpty == false) ? .node : .hub
    }
}

// MARK: - 协议常量（§4）

enum FleetProtocol {
    static let version = 1
    /// 请求体上限 4 MiB（§4.2）。
    static let maxRequestBodyBytes = 4 * 1024 * 1024
    /// 响应体上限 2 MiB（§4.2）。
    static let maxResponseBodyBytes = 2 * 1024 * 1024
    /// 请求头（含请求行）的解析上限；超过按 431 断开。
    static let maxHeaderBytes = 16 * 1024
    /// 同一 nodeID 两次请求的最小间隔（§4.3）。
    static let minRequestInterval: TimeInterval = 1
    /// 日桶通道的天数上限（today + previous six）。既是校验上限，也是 hub
    /// 侧落库保留的天数（§6：逐日滚动的窗口不裁剪就会一天涨一格）。
    static let maxDailyBuckets = 7
    /// 窗口边界前沿：装配下发与存储修剪对每个 (provider, model, kind) 保留的
    /// 最新边界数（2026-10-27 裁定）。历史边界不会再等来新贡献（聚合按精确
    /// 边界匹配），消费端每组也只取一条（preferredRange）；保留 2 条容忍
    /// 多账号并存的不同边界与跨零点时钟差。
    static let windowFrontierPerGroup = 2
    /// 日桶下行保留的完整桶天数（2026-10-27 裁定）：只有最新 2 天下发
    /// entries/clientProviders 明细，更早的天裁成 totals + 金额汇总——
    /// 消费端对历史天只用日图 totals 与逐日金额文案。留 2 天容忍跨零点
    /// 时钟差，节点眼中的「今天」始终在完整桶里。
    static let fullDailyBucketsForNode = 2

    static let usageDayPath = "/v1/usage/day"
    static let healthPath = "/v1/health"

    /// 参与校验的已注册 quota provider / client ID（§5.6）。
    static let knownQuotaProviderIDs: Set<String> = [
        QuotaProviderID.minimax,
        QuotaProviderID.openAI,
        QuotaProviderID.antigravity,
        QuotaProviderID.zhipu,
        QuotaProviderID.deepseek
    ]
    static let knownClientIDs: Set<String> = [
        ClientID.codex, ClientID.antigravity, ClientID.zcode,
        ClientID.openCode, ClientID.dsh, ClientID.minimaxCode, ClientID.agy
    ]
}

// MARK: - Wire DTO（§5.5）

struct FleetNodeIdentity: Codable, Equatable, Sendable {
    let nodeID: UUID
    let nodeName: String
    /// 诊断元数据：单时区前提下不产生任何换算分支（§2.3）。
    let timezoneID: String
    let platform: String
}

/// wire 侧的计价覆盖度。与既有 `CostCoverage`（非 Codable）分开表达，
/// full 额外要求样本集完整（未截断）——截尾样本的金额不能配完整 token 标 full。
enum FleetCostCoverage: String, Codable, Sendable, Equatable {
    case none, partial, full

    /// 从「价目覆盖度 × 样本完整性」推导：全有价且完整才是 full；
    /// 有价但不完整 / 部分有价是 partial；全无价是 none（§10.7.2）。
    init(priced: Bool, fullyPriced: Bool, complete: Bool) {
        if !priced {
            self = .none
        } else if fullyPriced && complete {
            self = .full
        } else {
            self = .partial
        }
    }
}

struct FleetUsageEntry: Codable, Equatable, Sendable {
    let clientID: String
    let quotaProviderID: String
    let modelName: String?
    let input, cacheRead, output, reasoning: Int
    /// 原币金额。金额与上述 token 必须来自同一批样本（§2.2）。
    let value: Double?
    let currency: ModelPriceCurrency?
    let coverage: FleetCostCoverage
    let truncated: Bool
}

struct FleetClientProviderUsage: Codable, Equatable, Sendable {
    let clientID: String
    let quotaProviderID: String
    let input, cacheRead, output, reasoning, turns, rounds: Int
}

enum FleetDailyUnavailableReason: String, Codable, Sendable, Equatable {
    case failed, scanning, truncated
}

struct FleetDailyUnavailableSource: Codable, Equatable, Sendable {
    let clientID: String
    let quotaProviderID: String
    let reason: FleetDailyUnavailableReason

    var sourceKey: String { clientID + "|" + quotaProviderID }
}

struct FleetTotals: Codable, Equatable, Sendable {
    let input, cacheRead, output, reasoning, turns, rounds: Int

    static let zero = FleetTotals(input: 0, cacheRead: 0, output: 0, reasoning: 0, turns: 0, rounds: 0)

    init(input: Int, cacheRead: Int, output: Int, reasoning: Int, turns: Int, rounds: Int) {
        self.input = input
        self.cacheRead = cacheRead
        self.output = output
        self.reasoning = reasoning
        self.turns = turns
        self.rounds = rounds
    }

    static func + (lhs: FleetTotals, rhs: FleetTotals) -> FleetTotals {
        FleetTotals(
            input: SaturatingArithmetic.add(lhs.input, rhs.input),
            cacheRead: SaturatingArithmetic.add(lhs.cacheRead, rhs.cacheRead),
            output: SaturatingArithmetic.add(lhs.output, rhs.output),
            reasoning: SaturatingArithmetic.add(lhs.reasoning, rhs.reasoning),
            turns: SaturatingArithmetic.add(lhs.turns, rhs.turns),
            rounds: SaturatingArithmetic.add(lhs.rounds, rhs.rounds)
        )
    }

    /// 权威日合计与同桶 clientProviders 的规范化汇总逐字段核对（§5.1）。
    static func == (_ lhs: FleetTotals, _ rhs: [FleetClientProviderUsage]) -> Bool {
        lhs == FleetTotals(summing: rhs)
    }
}

extension FleetTotals {
    /// 权威日合计：同桶 clientProviders 的规范化计数汇总（§5.1）。
    init(summing rows: [FleetClientProviderUsage]) {
        self = rows.reduce(FleetTotals.zero) { acc, row in
            FleetTotals(
                input: SaturatingArithmetic.add(acc.input, row.input),
                cacheRead: SaturatingArithmetic.add(acc.cacheRead, row.cacheRead),
                output: SaturatingArithmetic.add(acc.output, row.output),
                reasoning: SaturatingArithmetic.add(acc.reasoning, row.reasoning),
                turns: SaturatingArithmetic.add(acc.turns, row.turns),
                rounds: SaturatingArithmetic.add(acc.rounds, row.rounds)
            )
        }
    }
}

struct FleetDailyBucket: Codable, Equatable, Sendable {
    let dayKey: String                 // today + previous six days
    /// 权威日总量，不能从可能截断的 entries 反推。
    let totals: FleetTotals
    let clientProviders: [FleetClientProviderUsage]
    /// 模型明细；完整度独立于 totals。
    let entries: [FleetUsageEntry]
    let totalsComplete: Bool
    let modelDetailsComplete: Bool
    let sourceTruncated: Bool
    /// nil preserves legacy all-or-nothing validation. A nonnil list declares
    /// provider-scoped coverage; unavailable rows are retained by the hub.
    var unavailableSources: [FleetDailyUnavailableSource]? = nil
    /// 桶级金额汇总（按币种分开，不跨币折算）：合并侧从 entries 顺手算出，
    /// 历史天明细不下发后逐日金额文案从这组值渲染（2026-10-27 裁定）。
    /// nil = 无汇总信息（节点上报桶 / 旧载荷），消费端回退明细路径。
    var valueByCurrency: [String: Double]? = nil
    /// 有贡献未完整计价（未计价 / 截断 / partial coverage）。纯金额汇总
    /// 表达不了它，单独携带以渲染「（部分计价）」标注。
    var costPartial: Bool = false

    /// 下发给副节点的瘦身形态：保留最新 `fullDailyBucketsForNode` 天完整桶，
    /// 更早的天剥掉 entries/clientProviders 明细（消费端只用 totals 与金额
    /// 汇总），完整性标志与不可用来源原样保留。
    func strippedForNode(keepFullDayKeys: Set<String>) -> FleetDailyBucket {
        guard !keepFullDayKeys.contains(dayKey) else { return self }
        return FleetDailyBucket(
            dayKey: dayKey,
            totals: totals,
            clientProviders: [],
            entries: [],
            totalsComplete: totalsComplete,
            modelDetailsComplete: modelDetailsComplete,
            sourceTruncated: sourceTruncated,
            unavailableSources: unavailableSources,
            valueByCurrency: valueByCurrency,
            costPartial: costPartial
        )
    }
}

struct FleetWindowUsage: Codable, Equatable, Sendable {
    let quotaProviderID: String
    let modelID: String
    /// interval / weekly / glmOffPeak / provider 自定义 kind。
    let windowKind: String
    /// 实际观察到的边界；startAt < endAt。接收时刻记在存储行的 updated_at
    /// 列上，不进 payload（payload 内容稳定，数值不变就不产生重写差异）。
    let startAt, endAt: Date
    let input, cacheRead, output, reasoning: Int
    let value: Double?
    let currency: ModelPriceCurrency?
    let coverage: FleetCostCoverage
    let complete: Bool
    let sourceTruncated: Bool

    var recordKey: String {
        [quotaProviderID, modelID, windowKind,
         FleetISO8601.dateString(startAt), FleetISO8601.dateString(endAt)]
            .joined(separator: "|")
    }
}

struct FleetQuotaReport: Codable, Equatable, Sendable {
    let quotaProviderID: String
    let fetchedAt: Date
    let models: [ModelQuota]
    let resetCredits: ResetCreditsInfo?
    let planLabel: String?
    let accountEmail: String?
    let balanceDetail: DeepseekBalanceDetail?

    /// 有效额度：至少一个 model 存在活跃额度窗口。DeepSeek 的 present 余额
    /// 窗口（含零余额）符合有效性（§2.1）。
    var hasActiveQuotaWindow: Bool {
        models.contains(where: \.hasActiveQuotaWindow)
    }
}

struct NodeUsageReport: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let node: FleetNodeIdentity
    /// 对稳定 nodeID 单调递增；hub 只接受更新的序号（§7.3）。
    let seq: Int
    let generatedAt: Date
    let attributionFingerprint: String
    /// nil：本次不更新日桶；存在时最多七个且 dayKey 互异（增量裁定 2026-10-24：
    /// 可只带需要补发/修正的天，见 `FleetDailyBackfill`）。
    var dailyBuckets: [FleetDailyBucket]?
    /// nil：无窗口更新；行按完整边界独立 upsert，空数组不删除旧范围。
    let windowUsage: [FleetWindowUsage]?
    /// nil：不更新；空数组清除该节点额度集合。
    let quotas: [FleetQuotaReport]?
}

struct FleetNodeSnapshot: Codable, Equatable, Sendable {
    let nodeID: UUID
    let nodeName: String
    let lastSeenAt: Date
    let seq: Int
    let stale: Bool
    let dailyBuckets: [FleetDailyBucket]
    let windowUsage: [FleetWindowUsage]
    let quotas: [FleetQuotaReport]
    /// 该节点的归因设置指纹（§7.8）：≥2 种不同指纹 → 设置页提示「口径之和」。
    /// 旧快照缺该字段按 nil（未知，不参与比较）。
    let attributionFingerprint: String?
    /// hub 对该节点已存每个日桶的内容摘要回执（dayKey → `FleetDailyDigest`，
    /// 增量裁定 2026-10-24）。副节点据此判断哪些天需要补发/修正；旧快照缺该
    /// 字段按 nil（等效空回执 → 触发全量补发）。
    let dailyDigests: [String: String]?
}

struct FleetElectedQuota: Codable, Equatable, Sendable {
    let quotaProviderID: String
    let sourceNodeID: UUID
    let sourceNodeName: String
    let fetchedAt: Date
    let models: [ModelQuota]
    let resetCredits: ResetCreditsInfo?
    let planLabel: String?
    let accountEmail: String?
    let balanceDetail: DeepseekBalanceDetail?
    let isStale: Bool
}

struct FleetWindowAggregate: Codable, Equatable, Sendable {
    let quotaProviderID, modelID, windowKind: String
    let startAt, endAt: Date
    let input, cacheRead, output, reasoning: Int
    /// 金额按币种分开保存，不做跨币种折算合并（§7.1）。
    let valueByCurrency: [String: Double]
    let coverage: FleetCostCoverage
    let complete: Bool
    let contributingNodeIDs, staleNodeIDs: [UUID]
    /// 已知相关但缺该范围的节点。
    let missingNodeIDs: [UUID]
}

struct FleetAggregate: Codable, Equatable, Sendable {
    let dailyBuckets: [FleetDailyBucket]
    let windowUsage: [FleetWindowAggregate]
}

struct FleetSnapshot: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let hubUUID: UUID
    /// hub 上任何可见状态变更时递增；跨重启持久可比（§5.2）。
    /// hub 装配时若可见签名变化需要改写它，故为 var。
    var generation: Int64
    let hub: FleetNodeIdentity
    let generatedAt: Date
    let nodes: [FleetNodeSnapshot]
    let fleet: FleetAggregate
    let electedQuotas: [FleetElectedQuota]
    /// Hub-side fleet size. Node responses may retain this count while omitting
    /// other nodes' identities and details, so nodes can choose aggregate/local
    /// presentation without learning per-node data.
    var participantCount: Int? = nil

    var isMultiNode: Bool { (participantCount ?? nodes.count) > 1 }

    /// Keep only this node's compact report acknowledgement when a node consumes
    /// a hub snapshot. Old hubs may still send full node records; discard those
    /// details before caching or publishing the snapshot locally.
    func nodeResponse(acknowledging nodeID: UUID? = nil) -> FleetSnapshot {
        let own = nodeID.flatMap { id in nodes.first { $0.nodeID == id } }.map { node in
            FleetNodeSnapshot(
                nodeID: node.nodeID,
                nodeName: "",
                lastSeenAt: node.lastSeenAt,
                seq: node.seq,
                stale: false,
                dailyBuckets: [],
                windowUsage: [],
                quotas: [],
                attributionFingerprint: nil,
                dailyDigests: node.dailyDigests
            )
        }
        let aggregateWindows = fleet.windowUsage.map { row in
            FleetWindowAggregate(
                quotaProviderID: row.quotaProviderID,
                modelID: row.modelID,
                windowKind: row.windowKind,
                startAt: row.startAt,
                endAt: row.endAt,
                input: row.input,
                cacheRead: row.cacheRead,
                output: row.output,
                reasoning: row.reasoning,
                valueByCurrency: row.valueByCurrency,
                coverage: row.coverage,
                complete: row.complete && row.staleNodeIDs.isEmpty && row.missingNodeIDs.isEmpty,
                contributingNodeIDs: [],
                staleNodeIDs: [],
                missingNodeIDs: []
            )
        }
        // 日桶下行瘦身（2026-10-27 裁定）：消费端对非今天桶只用 totals 与
        // 逐日金额文案（合并侧已算好 valueByCurrency/costPartial），历史天
        // 不再下发 entries/clientProviders 明细；保留最新 2 天完整桶，容忍
        // hub/节点跨零点的时钟差。
        let fullDayKeys = Set(
            fleet.dailyBuckets.map(\.dayKey)
                .sorted()
                .suffix(FleetProtocol.fullDailyBucketsForNode)
        )
        let dailyForNode = fleet.dailyBuckets.map { $0.strippedForNode(keepFullDayKeys: fullDayKeys) }
        return FleetSnapshot(
            protocolVersion: protocolVersion,
            hubUUID: hubUUID,
            generation: generation,
            hub: hub,
            generatedAt: generatedAt,
            nodes: own.map { [$0] } ?? [],
            fleet: FleetAggregate(dailyBuckets: dailyForNode, windowUsage: aggregateWindows),
            electedQuotas: electedQuotas,
            participantCount: participantCount ?? nodes.count
        )
    }

    func compactedForNode(_ nodeID: UUID) -> FleetSnapshot {
        nodeResponse(acknowledging: nodeID)
    }
}

// MARK: - 编解码（§5.3）

/// ISO8601 时刻的统一格式化入口：wire / 存储键共用，避免两处格式漂移。
enum FleetISO8601 {
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func dateString(_ date: Date) -> String {
        formatter.string(from: date)
    }

    /// Wire/storage ISO8601 dates carry whole-second precision. Match boundaries at
    /// that same precision when comparing a decoded snapshot with a local reset time.
    static func matchesWholeSecond(_ lhs: Date, _ rhs: Date) -> Bool {
        let left = lhs.timeIntervalSince1970
        let right = rhs.timeIntervalSince1970
        guard left.isFinite, right.isFinite else { return false }
        return floor(left) == floor(right)
    }
}

/// 唯一的出网/入网 JSON 编解码入口：date 策略只写一次。任何一侧漏设
/// iso8601，`Date` 会被编成 2001 基准的 Double，静默错出几十年的时刻。
enum FleetCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

// MARK: - 逐天摘要回执（增量日桶，2026-10-24 裁定）

/// 日桶内容摘要：`FleetCodec` 规范编码（sortedKeys）后取 SHA256 前 16 个十六进制
/// 字符。副节点对本机构建的输入桶计算；hub通常按已存桶回执，来源感知partial桶
/// 则回执最后接受的输入摘要（落在 `FleetStoredReport.dailyInputDigests`）。摘要失配
/// 最坏多发一次幂等补发，不会丢数据——绝不为对齐摘要改变日桶内容。
enum FleetDailyDigest {
    static func digest(_ bucket: FleetDailyBucket) -> String {
        guard let data = try? FleetCodec.encode(bucket) else { return "" }
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

/// 副节点上报侧的增量过滤：把报告的日桶通道收窄到「回执摘要与本地不一致」的天。
/// - `cachedDigests` 为空（首次接触该 hub / 本机重启 / hub 丢数据）→ 保持全量
///   七天，重建回执基线；
/// - 否则只保留摘要不一致的天——历史天被扫描修正、hub 缺天都表现为不一致；
/// - 全部一致 → 整条通道置 nil（等价心跳，仅刷新 lastSeen）。
enum FleetDailyBackfill {
    static func filterReport(_ report: inout NodeUsageReport, cachedDigests: [String: String]) {
        guard var buckets = report.dailyBuckets else { return }
        guard !cachedDigests.isEmpty else { return }
        buckets = buckets.filter { FleetDailyDigest.digest($0) != cachedDigests[$0.dayKey] }
        report.dailyBuckets = buckets.isEmpty ? nil : buckets
    }
}

// MARK: - 报告校验（§5.6）

/// hub 收到报告后的通道级校验结果：信封、日桶、窗口、额度分别裁决，
/// 单一通道失败不卡住其余通道（心跳与额度通道不被用量问题阻塞，§6.5）。
struct FleetReportValidation: Equatable, Sendable {
    /// 整包拒绝（protocolVersion / 身份 / seq 结构问题）→ HTTP 400。
    let envelopeError: String?
    /// nil = 通道缺席；非 nil = 通道存在但校验失败（保留旧数据）。
    let dailyBucketsError: String?
    /// 行级过滤后的窗口行（校验失败的行被丢弃，不整通道拒绝）。
    let windowRows: [FleetWindowUsage]
    let windowDroppedRowCount: Int
    /// nil = 通道缺席；非 nil = 通道存在但校验失败。
    let quotasError: String?

    var envelopeValid: Bool { envelopeError == nil }
}

enum FleetReportValidator {
    static func validate(_ report: NodeUsageReport) -> FleetReportValidation {
        var envelopeError: String?
        if report.protocolVersion != FleetProtocol.version {
            envelopeError = "protocolVersion \(report.protocolVersion) != \(FleetProtocol.version)"
        } else if report.node.nodeID.uuidString == "00000000-0000-0000-0000-000000000000" {
            envelopeError = "nodeID 全零"
        } else if report.seq < 0 {
            envelopeError = "seq \(report.seq) 为负"
        } else if report.generatedAt.timeIntervalSinceReferenceDate.isFinite == false {
            envelopeError = "generatedAt 非有限时刻"
        }

        var dailyError: String?
        if let buckets = report.dailyBuckets {
            dailyError = validateDailyBuckets(buckets)
        }

        var windowRows: [FleetWindowUsage] = []
        var dropped = 0
        if let rows = report.windowUsage {
            for row in rows where rowPassesValidation(row) {
                windowRows.append(row)
            }
            dropped = rows.count - windowRows.count
        }

        var quotasError: String?
        if let quotas = report.quotas {
            quotasError = validateQuotas(quotas)
        }

        return FleetReportValidation(
            envelopeError: envelopeError,
            dailyBucketsError: dailyError,
            windowRows: windowRows,
            windowDroppedRowCount: dropped,
            quotasError: quotasError
        )
    }

    private static func validateDailyBuckets(_ buckets: [FleetDailyBucket]) -> String? {
        // 增量裁定 2026-10-24：允许 0–7 桶（只补发/修正部分天），dayKey 仍须互异。
        guard buckets.count <= FleetProtocol.maxDailyBuckets else {
            return "dailyBuckets 最多 \(FleetProtocol.maxDailyBuckets) 桶，实际 \(buckets.count)"
        }
        let dayKeys = buckets.map(\.dayKey)
        guard Set(dayKeys).count == dayKeys.count else { return "dailyBuckets 存在重复 dayKey" }
        for bucket in buckets {
            guard isValidDayKey(bucket.dayKey) else { return "dayKey \(bucket.dayKey) 不是 yyyy-MM-dd" }
            let unavailableKeys: Set<String>
            if let unavailableSources = bucket.unavailableSources {
                let keys = unavailableSources.map(\.sourceKey)
                guard Set(keys).count == keys.count else {
                    return "日桶 \(bucket.dayKey) 的 unavailableSources 存在重复来源"
                }
                for source in unavailableSources {
                    guard FleetProtocol.knownClientIDs.contains(source.clientID),
                          FleetProtocol.knownQuotaProviderIDs.contains(source.quotaProviderID) else {
                        return "unavailableSources 含未注册 ID: \(source.clientID)/\(source.quotaProviderID)"
                    }
                }
                let expectsComplete = unavailableSources.isEmpty
                guard bucket.totalsComplete == expectsComplete else {
                    return "日桶 \(bucket.dayKey) totalsComplete 与 unavailableSources 不一致"
                }
                let expectsTruncated = unavailableSources.contains { $0.reason == .truncated }
                guard bucket.sourceTruncated == expectsTruncated else {
                    return "日桶 \(bucket.dayKey) sourceTruncated 与 unavailableSources 不一致"
                }
                guard unavailableSources.isEmpty || !bucket.modelDetailsComplete else {
                    return "日桶 \(bucket.dayKey) 不完整来源不能标记 modelDetailsComplete"
                }
                unavailableKeys = Set(keys)
            } else {
                // Legacy reports have no source-level coverage. Preserve the
                // original all-or-nothing contract for incomplete totals.
                guard bucket.totalsComplete else {
                    return "dailyBuckets 含非权威 totals，保留 hub 已存日桶"
                }
                unavailableKeys = []
            }
            guard bucket.totals == bucket.clientProviders else {
                return "日桶 \(bucket.dayKey) 的 totals 与 clientProviders 汇总不一致"
            }
            for row in bucket.clientProviders {
                guard FleetProtocol.knownClientIDs.contains(row.clientID),
                      FleetProtocol.knownQuotaProviderIDs.contains(row.quotaProviderID) else {
                    return "clientProviders 含未注册 ID: \(row.clientID)/\(row.quotaProviderID)"
                }
                guard nonNegative(row.input, row.cacheRead, row.output, row.reasoning, row.turns, row.rounds) else {
                    return "clientProviders 含负计数"
                }
                guard !unavailableKeys.contains(row.clientID + "|" + row.quotaProviderID) else {
                    return "日桶 \(bucket.dayKey) 本次数据包含不可用来源 \(row.clientID)/\(row.quotaProviderID)"
                }
            }
            for entry in bucket.entries {
                guard FleetProtocol.knownClientIDs.contains(entry.clientID),
                      FleetProtocol.knownQuotaProviderIDs.contains(entry.quotaProviderID) else {
                    return "entries 含未注册 ID: \(entry.clientID)/\(entry.quotaProviderID)"
                }
                guard nonNegative(entry.input, entry.cacheRead, entry.output, entry.reasoning),
                      amountIsConsistent(entry.value, entry.currency) else {
                    return "entries \(entry.clientID)/\(entry.quotaProviderID) 数值非法"
                }
                guard !unavailableKeys.contains(entry.clientID + "|" + entry.quotaProviderID) else {
                    return "日桶 \(bucket.dayKey) entries 包含不可用来源 \(entry.clientID)/\(entry.quotaProviderID)"
                }
            }
        }
        return nil
    }

    private static func validateQuotas(_ quotas: [FleetQuotaReport]) -> String? {
        let ids = quotas.map(\.quotaProviderID)
        guard Set(ids).count == ids.count else { return "quotas 存在重复 provider" }
        for quota in quotas {
            guard FleetProtocol.knownQuotaProviderIDs.contains(quota.quotaProviderID) else {
                return "quotas 含未注册 provider: \(quota.quotaProviderID)"
            }
            guard quota.fetchedAt.timeIntervalSinceReferenceDate.isFinite else {
                return "quotas \(quota.quotaProviderID) fetchedAt 非有限时刻"
            }
        }
        return nil
    }

    static func rowPassesValidation(_ row: FleetWindowUsage) -> Bool {
        guard FleetProtocol.knownQuotaProviderIDs.contains(row.quotaProviderID),
              !row.modelID.isEmpty,
              !row.windowKind.isEmpty,
              row.startAt < row.endAt,
              nonNegative(row.input, row.cacheRead, row.output, row.reasoning),
              amountIsConsistent(row.value, row.currency)
        else { return false }
        return true
    }

    static func isValidDayKey(_ dayKey: String) -> Bool {
        let bytes = Array(dayKey.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return false }
        let digitPositions = [0, 1, 2, 3, 5, 6, 8, 9]
        guard digitPositions.allSatisfy({ (48...57).contains(bytes[$0]) }) else { return false }

        func number(_ range: Range<Int>) -> Int {
            range.reduce(0) { $0 * 10 + Int(bytes[$1] - 48) }
        }
        let year = number(0..<4)
        let month = number(5..<7)
        let day = number(8..<10)
        guard (2000...2999).contains(year), (1...12).contains(month) else { return false }

        var gregorianUTC = Calendar(identifier: .gregorian)
        gregorianUTC.timeZone = TimeZone(secondsFromGMT: 0)!
        var requested = DateComponents()
        requested.year = year
        requested.month = month
        requested.day = day
        requested.hour = 12
        guard let date = gregorianUTC.date(from: requested) else { return false }
        let resolved = gregorianUTC.dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }

    private static func nonNegative(_ values: Int...) -> Bool {
        values.allSatisfy { $0 >= 0 }
    }

    /// 配对金额/币种不一致（一有一无）时金额视为缺失（§5.6）；
    /// 双双存在还要求金额有限。
    static func amountIsConsistent(_ value: Double?, _ currency: ModelPriceCurrency?) -> Bool {
        switch (value, currency) {
        case (nil, nil): return true
        case let (value?, currency?): return value.isFinite && value >= 0 && currency.rawValue.isEmpty == false
        default: return false
        }
    }
}

// MARK: - 归因指纹（§7.8）

/// 跨机可比较的归因设置指纹：SHA256 前 8 个十六进制字符。不能用 `Hasher`
/// ——它的种子每个进程不同。别名与 enabled 都进指纹：两者任何一个变化都会
/// 改变归属结果。
enum FleetAttributionFingerprint {
    static func compute(_ bindings: [ClientProviderBinding]) -> String {
        let normalized = bindings
            .sorted { lhs, rhs in
                if lhs.clientID != rhs.clientID { return lhs.clientID < rhs.clientID }
                return lhs.quotaProviderID < rhs.quotaProviderID
            }
            .map { binding in
                [
                    binding.clientID,
                    binding.quotaProviderID,
                    binding.enabled ? "1" : "0",
                    binding.sourceProviderAliases.joined(separator: ",")
                ].joined(separator: "|")
            }
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }
}

// MARK: - 合并与选举（§7）

/// 纯函数合并内核：hub 与测试共用，不持有任何状态。
enum FleetMerger {
    // MARK: 日桶

    /// 各节点的当前七日日桶按 dayKey 合并成 fleet 聚合：
    /// totals 独立求和；clientProviders 按 (client, provider) 求和；
    /// entries 按 (client, provider, model) 求和、金额仅同币种相加、
    /// coverage 按「有价 + 完整」重推导；不可用来源稳定去重并保留partial标志。
    /// 只保留 today + previous six。
    static func mergeDailyBuckets(
        _ nodeBuckets: [[FleetDailyBucket]],
        now: Date,
        calendar: Calendar = .current
    ) -> [FleetDailyBucket] {
        let allowedKeys = Set(dayKeyWindow(now: now, calendar: calendar))
        var byDay: [String: [FleetDailyBucket]] = [:]
        for buckets in nodeBuckets {
            for bucket in buckets where allowedKeys.contains(bucket.dayKey) {
                byDay[bucket.dayKey, default: []].append(bucket)
            }
        }
        return dayKeyWindow(now: now, calendar: calendar).compactMap { dayKey in
            guard let contributions = byDay[dayKey], !contributions.isEmpty else { return nil }
            return mergeSingleDay(dayKey: dayKey, contributions: contributions)
        }
    }

    private static func mergeSingleDay(dayKey: String, contributions: [FleetDailyBucket]) -> FleetDailyBucket {
        let totals = contributions.map(\.totals).reduce(FleetTotals.zero, +)

        var clientRows: [String: FleetClientProviderUsage] = [:]
        for bucket in contributions {
            for row in bucket.clientProviders {
                let key = row.clientID + "\u{0}" + row.quotaProviderID
                if let existing = clientRows[key] {
                    clientRows[key] = FleetClientProviderUsage(
                        clientID: existing.clientID,
                        quotaProviderID: existing.quotaProviderID,
                        input: SaturatingArithmetic.add(existing.input, row.input),
                        cacheRead: SaturatingArithmetic.add(existing.cacheRead, row.cacheRead),
                        output: SaturatingArithmetic.add(existing.output, row.output),
                        reasoning: SaturatingArithmetic.add(existing.reasoning, row.reasoning),
                        turns: SaturatingArithmetic.add(existing.turns, row.turns),
                        rounds: SaturatingArithmetic.add(existing.rounds, row.rounds)
                    )
                } else {
                    clientRows[key] = row
                }
            }
        }

        var entryRows: [String: EntryAccumulator] = [:]
        for bucket in contributions {
            for entry in bucket.entries {
                let key = [entry.clientID, entry.quotaProviderID, entry.modelName ?? ""].joined(separator: "\u{0}")
                entryRows[key, default: EntryAccumulator(entry: entry)].add(entry)
            }
        }

        let unavailableSources = mergedUnavailableSources(contributions)
        let finalizedEntries = entryRows.values
            .map(\.finalized)
            .sorted {
                ($0.clientID, $0.quotaProviderID, $0.modelName ?? "")
                    < ($1.clientID, $1.quotaProviderID, $1.modelName ?? "")
            }
        // 桶级金额汇总（2026-10-27 裁定）：与展示端 costText 同口径——按币种
        // 分列、跨币不折算；任何贡献未完整计价则置 costPartial。
        var valueByCurrency: [String: Double] = [:]
        var costPartial = false
        for entry in finalizedEntries {
            if let value = entry.value, let currency = entry.currency {
                valueByCurrency[currency.rawValue, default: 0] += value
            }
            if entry.value == nil || entry.currency == nil
                || entry.coverage != .full || entry.truncated {
                costPartial = true
            }
        }
        return FleetDailyBucket(
            dayKey: dayKey,
            totals: totals,
            clientProviders: clientRows.values.sorted {
                $0.clientID == $1.clientID
                    ? $0.quotaProviderID < $1.quotaProviderID
                    : $0.clientID < $1.clientID
            },
            entries: finalizedEntries,
            totalsComplete: contributions.allSatisfy(\.totalsComplete),
            modelDetailsComplete: contributions.allSatisfy(\.modelDetailsComplete),
            sourceTruncated: contributions.contains(where: \.sourceTruncated)
                || (unavailableSources?.contains { $0.reason == .truncated } ?? false),
            unavailableSources: unavailableSources,
            valueByCurrency: valueByCurrency,
            costPartial: costPartial
        )
    }

    private static func mergedUnavailableSources(
        _ contributions: [FleetDailyBucket]
    ) -> [FleetDailyUnavailableSource]? {
        guard contributions.contains(where: { $0.unavailableSources != nil }) else { return nil }
        var byKey: [String: FleetDailyUnavailableSource] = [:]
        for source in contributions.flatMap({ $0.unavailableSources ?? [] }) {
            if let existing = byKey[source.sourceKey] {
                // Deterministic if nodes report different unavailable reasons
                // for the same source in the same day.
                if unavailableReasonPriority(source.reason) > unavailableReasonPriority(existing.reason) {
                    byKey[source.sourceKey] = source
                }
            } else {
                byKey[source.sourceKey] = source
            }
        }
        return byKey.values.sorted { $0.sourceKey < $1.sourceKey }
    }

    private static func unavailableReasonPriority(_ reason: FleetDailyUnavailableReason) -> Int {
        switch reason {
        case .scanning: return 1
        case .failed: return 2
        case .truncated: return 3
        }
    }

    /// 模型明细行：token 从样本聚合，金额由同一批样本计价（同源硬纪律）。
    /// init 不做累加——首条贡献由调用点的 `.add` 统一处理，避免默认值
    /// 下标 + 显式 add 重复计数。
    private struct EntryAccumulator {
        let clientID: String
        let quotaProviderID: String
        let modelName: String?
        var input = 0, cacheRead = 0, output = 0, reasoning = 0
        var value: Double?
        var currency: ModelPriceCurrency?
        var anyPriced = false
        var hasUnpriced = false
        /// 币种冲突后金额整体作废：宁可缺金额，不给跨币种假总价（§7.1）。
        var currencyConflict = false
        var truncated = false

        init(entry: FleetUsageEntry) {
            self.clientID = entry.clientID
            self.quotaProviderID = entry.quotaProviderID
            self.modelName = entry.modelName
        }

        mutating func add(_ entry: FleetUsageEntry) {
            input = SaturatingArithmetic.add(input, entry.input)
            cacheRead = SaturatingArithmetic.add(cacheRead, entry.cacheRead)
            output = SaturatingArithmetic.add(output, entry.output)
            reasoning = SaturatingArithmetic.add(reasoning, entry.reasoning)
            truncated = truncated || entry.truncated
            if entry.coverage != .none { anyPriced = true }
            if entry.coverage != .full { hasUnpriced = true }
            if let amount = entry.value, let coin = entry.currency {
                anyPriced = true
                if let existing = value, let base = currency, base == coin {
                    value = existing + amount
                } else if value == nil, currency == nil, !currencyConflict {
                    value = amount
                    currency = coin
                } else {
                    currencyConflict = true
                    value = nil
                    currency = nil
                }
            } else {
                hasUnpriced = true
            }
        }

        var finalized: FleetUsageEntry {
            let hasAmount = value != nil && currency != nil && !currencyConflict
            return FleetUsageEntry(
                clientID: clientID,
                quotaProviderID: quotaProviderID,
                modelName: modelName,
                input: input,
                cacheRead: cacheRead,
                output: output,
                reasoning: reasoning,
                value: value,
                currency: currency,
                coverage: FleetCostCoverage(
                    priced: anyPriced,
                    fullyPriced: hasAmount && !hasUnpriced,
                    complete: !truncated
                ),
                truncated: truncated
            )
        }
    }

    // MARK: 窗口

    struct NodeWindowContribution: Sendable {
        let nodeID: UUID
        let stale: Bool
        let rows: [FleetWindowUsage]
    }

    /// 窗口聚合只合并边界**完全相同**的行（键含 provider/model/kind/start/end，
    /// 时刻精确比较不舍入）；范围不同不混加；缺该范围的已知节点进 missingNodeIDs。
    static func aggregateWindows(
        _ contributions: [NodeWindowContribution],
        knownNodeIDs: [UUID]
    ) -> [FleetWindowAggregate] {
        struct Key: Hashable {
            let quotaProviderID: String
            let modelID: String
            let windowKind: String
            let startAt: Date
            let endAt: Date
        }
        var grouped: [Key: [(nodeID: UUID, stale: Bool, row: FleetWindowUsage)]] = [:]
        for contribution in contributions {
            for row in contribution.rows {
                let key = Key(
                    quotaProviderID: row.quotaProviderID,
                    modelID: row.modelID,
                    windowKind: row.windowKind,
                    startAt: row.startAt,
                    endAt: row.endAt
                )
                grouped[key, default: []].append((contribution.nodeID, contribution.stale, row))
            }
        }
        let known = Set(knownNodeIDs)
        return grouped.map { key, members in
            let contributing = members.map(\.nodeID)
            let missing = known.subtracting(contributing).sorted { $0.uuidString < $1.uuidString }
            var valueByCurrency: [String: Double] = [:]
            var anyPriced = false
            var allPriced = true
            for (_, _, row) in members {
                if let value = row.value, let currency = row.currency {
                    valueByCurrency[currency.rawValue, default: 0] += value
                    anyPriced = true
                }
                if row.coverage != .full || !row.complete || row.sourceTruncated
                    || row.value == nil || row.currency == nil {
                    allPriced = false
                }
            }
            return FleetWindowAggregate(
                quotaProviderID: key.quotaProviderID,
                modelID: key.modelID,
                windowKind: key.windowKind,
                startAt: key.startAt,
                endAt: key.endAt,
                input: SaturatingArithmetic.sum(members.lazy.map { $0.row.input }),
                cacheRead: SaturatingArithmetic.sum(members.lazy.map { $0.row.cacheRead }),
                output: SaturatingArithmetic.sum(members.lazy.map { $0.row.output }),
                reasoning: SaturatingArithmetic.sum(members.lazy.map { $0.row.reasoning }),
                valueByCurrency: valueByCurrency,
                coverage: FleetCostCoverage(
                    priced: anyPriced || members.contains { $0.row.coverage != .none },
                    fullyPriced: allPriced,
                    complete: members.allSatisfy { $0.row.complete && !$0.row.sourceTruncated }
                ),
                complete: members.allSatisfy(\.row.complete),
                contributingNodeIDs: contributing,
                staleNodeIDs: members.filter(\.stale).map(\.nodeID),
                missingNodeIDs: Array(missing)
            )
        }
        .sorted {
            if $0.quotaProviderID != $1.quotaProviderID { return $0.quotaProviderID < $1.quotaProviderID }
            if $0.modelID != $1.modelID { return $0.modelID < $1.modelID }
            if $0.windowKind != $1.windowKind { return $0.windowKind < $1.windowKind }
            return $0.startAt < $1.startAt
        }
    }

    /// 窗口前沿过滤（2026-10-27 裁定）：每个 (provider, model, kind) 只保留
    /// `endAt` 最新的 `FleetProtocol.windowFrontierPerGroup` 个边界组。窗口
    /// 边界随额度重置滚动，历史边界组在聚合里永远等不来新贡献（精确边界
    /// 匹配），消费端每组也只取一条（preferredRange）；不过滤的话快照载荷
    /// 会把存储的历史累积原样透传给每个节点。
    static func windowFrontier(_ rows: [FleetWindowAggregate]) -> [FleetWindowAggregate] {
        var byGroup: [String: [FleetWindowAggregate]] = [:]
        for row in rows {
            let key = [row.quotaProviderID, row.modelID, row.windowKind].joined(separator: "\u{0}")
            byGroup[key, default: []].append(row)
        }
        return byGroup.flatMap { _, group in
            group.sorted { lhs, rhs in
                lhs.endAt == rhs.endAt ? lhs.startAt > rhs.startAt : lhs.endAt > rhs.endAt
            }
            .prefix(FleetProtocol.windowFrontierPerGroup)
        }
        .sorted {
            if $0.quotaProviderID != $1.quotaProviderID { return $0.quotaProviderID < $1.quotaProviderID }
            if $0.modelID != $1.modelID { return $0.modelID < $1.modelID }
            if $0.windowKind != $1.windowKind { return $0.windowKind < $1.windowKind }
            return $0.startAt < $1.startAt
        }
    }

    // MARK: 额度选举（§2.1 / §7.7）

    struct QuotaCandidate: Sendable {
        let sourceNodeID: UUID
        let sourceNodeName: String
        let report: FleetQuotaReport
    }

    /// hub 本机有效额度优先（即使本机最近抓取失败，有有效 lastSuccess 就用）；
    /// 本机无有效额度才从副节点候选里选 `fetchedAt` 最新的一份
    /// （2026-10-24 裁定按 fetchedAt，不按上报时刻）。过期只标 stale 不淘汰。
    static func electQuotas(
        candidates: [QuotaCandidate],
        hubNodeID: UUID,
        quotaMaxAgeSeconds: TimeInterval,
        now: Date
    ) -> [FleetElectedQuota] {
        var byProvider: [String: [QuotaCandidate]] = [:]
        for candidate in candidates where candidate.report.hasActiveQuotaWindow {
            byProvider[candidate.report.quotaProviderID, default: []].append(candidate)
        }
        return byProvider.map { providerID, list -> FleetElectedQuota in
            let winner: QuotaCandidate
            if let hubLocal = list.first(where: { $0.sourceNodeID == hubNodeID }) {
                winner = hubLocal
            } else {
                winner = list.max { lhs, rhs in
                    lhs.report.fetchedAt < rhs.report.fetchedAt
                }!
            }
            let stale = now.timeIntervalSince(winner.report.fetchedAt) > quotaMaxAgeSeconds
            return FleetElectedQuota(
                quotaProviderID: providerID,
                sourceNodeID: winner.sourceNodeID,
                sourceNodeName: winner.sourceNodeName,
                fetchedAt: winner.report.fetchedAt,
                models: winner.report.models,
                resetCredits: winner.report.resetCredits,
                planLabel: winner.report.planLabel,
                accountEmail: winner.report.accountEmail,
                balanceDetail: winner.report.balanceDetail,
                isStale: stale
            )
        }
        .sorted { $0.quotaProviderID < $1.quotaProviderID }
    }

    // MARK: dayKey 工具

    /// Gregorian today + previous six 的 dayKey 序列（升序，旧 → 新），保留调用方时区。
    static func dayKeyWindow(now: Date, calendar: Calendar = .current) -> [String] {
        let dayCalendar = gregorianDayCalendar(matching: calendar)
        let today = dayCalendar.startOfDay(for: now)
        return (0..<7).reversed().compactMap { offset in
            dayCalendar.date(byAdding: .day, value: -offset, to: today)
                .map { dayKey(of: $0, calendar: dayCalendar) }
        }
    }

    static func dayKey(of date: Date, calendar: Calendar = .current) -> String {
        let comps = gregorianDayCalendar(matching: calendar).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Day keys always carry Gregorian civil dates; inherit only the caller's time zone.
    static func gregorianDayCalendar(matching calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }
}
