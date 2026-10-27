import Foundation
import SQLite3

// MARK: - fleet.sqlite 唯一存储（§5.7）

/// `sync_records` 单表内已定义的 kind 值。
enum FleetRecordKind {
    /// 每节点当前接受的报告（日桶 + 额度，通道内合并语义见 `FleetStoredReport`）。
    static let report = "report"
    /// 每节点 high-water seq 与 lastSeen（record_key 固定 `high-water`）。
    static let nodeMeta = "node_meta"
    /// 每节点每个窗口范围一行（record_key = provider|model|kind|start|end）。
    static let window = "window"
    /// hub 的 generation（record_key 固定 `generation`）。
    static let hubMeta = "hub_meta"
    /// 副节点缓存的 hub 快照（record_key 固定 `current`）。
    static let snapshot = "snapshot"
}

/// `kind=report` 的落盘形状：日桶与额度是**独立通道**——新报告省略或校验失败
/// 的通道保留旧值；来源感知日桶只替换健康来源并保留显式不可用来源（§5.1 / §6.5）。
/// `nodeName` / `timezoneID` 随任何被接受的信封更新（快照装配需要展示名；
/// timezoneID 仅诊断，§2.3）。
struct FleetStoredReport: Codable, Equatable, Sendable {
    var dailyBuckets: [FleetDailyBucket]?
    /// Digest of the last accepted input for each stored day. For partial
    /// source-aware buckets this differs from the merged stored bucket digest.
    var dailyInputDigests: [String: String]? = nil
    var quotas: [FleetQuotaReport]?
    var attributionFingerprint: String?
    var nodeName: String?
    var timezoneID: String?
}

/// 报告落库结果：哪些通道被应用。generation 只随可见内容变化递增（2026-10-27
/// 裁定，见 `applyReport`）；心跳本身不再推动 generation。
struct FleetReportApplyOutcome: Equatable, Sendable {
    /// seq 不新于 high-water：所有通道都不应用（§5.6）。
    var rejectedStaleSeq: Bool
    var dailyApplied: Bool
    var quotasApplied: Bool
    /// 本次实际**改变了内容**的窗口行数（数值不变的重复上报不计）。
    var windowRowsApplied: Int
    var heartbeatUpdated: Bool
    /// hub 侧已接受的 high-water。seq 被拒时把它回给 node：node 据此重建
    /// 本机序号（否则同一份报告会**永久**被拒，而 node 只看到 200，
    /// 表现为「在线但数据永远没进 hub」）。
    var highWaterSeq: Int
}

/// hub 对「报告序号落后」的响应体（HTTP 409）。
///
/// - `highWaterSeq`：让 node 一次性把本机序号抬到 hub 之上（§7.3）。
/// - 响应体保持很小（不含快照）：HTTPClient 的错误体只保留前 500 字符，
///   快照塞进来会被截断成非法 JSON。node 拿到 409 后用 GET 兜底取快照。
struct FleetStaleSeqPayload: Codable, Sendable {
    let error: String
    let highWaterSeq: Int
}

/// hub 侧一次快照装配所需的全部落盘状态。
struct FleetHubStoredState: Sendable {
    struct NodeRecord: Sendable {
        let nodeID: UUID
        let report: FleetStoredReport
        let windowRows: [FleetWindowUsage]
        let seq: Int
        let lastSeenAt: Date
    }

    let nodes: [NodeRecord]
    let generation: Int64
}

enum FleetStoreError: Error, CustomStringConvertible, Equatable {
    case openFailed(path: String, code: Int32, message: String)
    case sqlFailed(code: Int32, extendedCode: Int32, message: String, sql: String)
    case corruptedRow(kind: String, recordKey: String)

    var description: String {
        switch self {
        case .openFailed(let path, let code, let message):
            return "fleet.sqlite 打开失败 (\(code)) path=\(path): \(message)"
        case .sqlFailed(let code, let ext, let message, let sql):
            return "fleet.sqlite 语句失败 (code=\(code), ext=\(ext)) sql=\(sql): \(message)"
        case .corruptedRow(let kind, let key):
            return "fleet.sqlite 行损坏 kind=\(kind) record_key=\(key)"
        }
    }
}

/// 应用自有 `fleet.sqlite`：单表 `sync_records`，所有同步状态（hub 报告、
/// high-water seq、窗口行、generation、副节点快照）都在这一个事务性存储里。
/// 不触碰任何客户端账本或原本机缓存（§5.7 / §11）。
///
/// 线程模型：实例内部互斥（NSLock），调用方可从任意线程同步调用。
final class FleetStore: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let path: String
    private let lock = NSLock()

    // MARK: - 生命周期

    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(url.path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close(db) }
            throw FleetStoreError.openFailed(path: url.path, code: code, message: message)
        }
        sqlite3_busy_timeout(db, 300)
        self.handle = db
        self.path = url.path
        try executeRaw("PRAGMA journal_mode=WAL")
        try executeRaw("""
            CREATE TABLE IF NOT EXISTS sync_records (
              kind TEXT NOT NULL, scope TEXT NOT NULL, node_id TEXT NOT NULL, record_key TEXT NOT NULL,
              seq INTEGER, generation INTEGER, updated_at REAL NOT NULL, payload_json BLOB NOT NULL,
              PRIMARY KEY (kind, scope, node_id, record_key)
            )
            """)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    // MARK: - hub：接受报告（事务）

    /// 校验后的报告落库。`receivedAt` 是 hub 的接收时刻——窗口行的
    /// `updated_at` 与 lastSeen 以它为准（§5.5）。
    ///
    /// 事务保证：报告（daily/quotas）、node_meta high-water、窗口行、
    /// generation 的递增要么全部提交，要么全部回滚（§5.7）。
    @discardableResult
    func applyReport(
        _ report: NodeUsageReport,
        validation: FleetReportValidation,
        scope: String,
        receivedAt: Date = Date()
    ) throws -> FleetReportApplyOutcome {
        lock.lock()
        defer { lock.unlock() }

        let nodeID = report.node.nodeID.uuidString
        let highWater = try highWaterSeq(scope: scope, nodeID: nodeID)
        if report.seq <= highWater {
            return FleetReportApplyOutcome(
                rejectedStaleSeq: true,
                dailyApplied: false,
                quotasApplied: false,
                windowRowsApplied: 0,
                heartbeatUpdated: false,
                highWaterSeq: Int(highWater)
            )
        }

        try beginTransaction()
        do {
            var applied = FleetReportApplyOutcome(
                rejectedStaleSeq: false,
                dailyApplied: false,
                quotasApplied: false,
                windowRowsApplied: 0,
                heartbeatUpdated: false,
                highWaterSeq: Int(highWater)
            )
            var stored = try storedReport(scope: scope, nodeID: nodeID) ?? FleetStoredReport()
            let oldStored = stored

            if let buckets = report.dailyBuckets, validation.dailyBucketsError == nil {
                // 增量日桶（2026-10-24 裁定）：按 dayKey upsert，通道缺席的天保留旧值。
                //
                // 保留策略：**最新的 N 天**（N = 协议上限 7），按 dayKey 排序取尾部。
                // 不按 hub 当前日期裁剪：节点的报告窗口按**节点自己的**时钟滚动，
                // hub 与节点时钟差一点（跨零点、手动改时区）时，按 hub 的窗口裁剪
                // 会把节点最新的那天裁掉（数据凭空消失）。按数据本身保留最新 N 天
                // 与时钟无关，也与「日桶通道最多 7 桶」一致。
                //
                // 不裁剪的后果：节点的窗口逐日滚动，每天多一个 dayKey 且永不删除
                // → 快照载荷越界（2 MiB 上限 → 全员 500）、节点卡片画出 N 根柱子。
                var byDay = Dictionary(
                    (stored.dailyBuckets ?? []).map { ($0.dayKey, $0) },
                    uniquingKeysWith: { _, new in new }
                )
                var inputDigests = stored.dailyInputDigests ?? [:]
                for bucket in buckets {
                    if let unavailableSources = bucket.unavailableSources {
                        byDay[bucket.dayKey] = mergeSourceAwareDailyBucket(
                            incoming: bucket,
                            existing: byDay[bucket.dayKey],
                            unavailableSources: unavailableSources
                        )
                    } else {
                        // Legacy complete buckets retain their original whole-day replacement.
                        byDay[bucket.dayKey] = bucket
                    }
                    inputDigests[bucket.dayKey] = FleetDailyDigest.digest(bucket)
                }
                let retainedBuckets = byDay.values
                    .sorted { $0.dayKey < $1.dayKey }
                    .suffix(FleetProtocol.maxDailyBuckets)
                    .map { $0 }
                let retainedKeys = Set(retainedBuckets.map(\.dayKey))
                inputDigests = inputDigests.filter { retainedKeys.contains($0.key) }
                stored.dailyBuckets = retainedBuckets
                stored.dailyInputDigests = inputDigests.isEmpty ? nil : inputDigests
            }
            if let quotas = report.quotas, validation.quotasError == nil {
                stored.quotas = quotas
            }
            if !report.attributionFingerprint.isEmpty {
                stored.attributionFingerprint = report.attributionFingerprint
            }
            // 信封级信息随任何被接受的报告更新（含心跳，§6.5）。
            if stored.nodeName != report.node.nodeName || stored.timezoneID != report.node.timezoneID {
                stored.nodeName = report.node.nodeName
                stored.timezoneID = report.node.timezoneID
            }
            applied.dailyApplied = report.dailyBuckets != nil
                && validation.dailyBucketsError == nil
                && (stored.dailyBuckets != oldStored.dailyBuckets
                    || stored.dailyInputDigests != oldStored.dailyInputDigests)
            applied.quotasApplied = report.quotas != nil
                && validation.quotasError == nil
                && stored.quotas != oldStored.quotas

            let reportRowChanged = stored != oldStored
            if reportRowChanged {
                try upsertRow(
                    kind: FleetRecordKind.report,
                    scope: scope,
                    nodeID: nodeID,
                    recordKey: "current",
                    seq: Int64(report.seq),
                    generation: nil,
                    updatedAt: receivedAt,
                    payload: try FleetCodec.encode(stored)
                )
            }

            // 窗口行按内容判变：observedAt 出 payload 后，数值不变的重复上报
            // 字节稳定，跳过重写也不计变化（2026-10-27 裁定）。
            let existingWindowPayloads = try queryWindowPayloads(scope: scope, nodeID: nodeID)
            var windowContentChanged = false
            for row in validation.windowRows {
                let payload = try FleetCodec.encode(row)
                guard existingWindowPayloads[row.recordKey] != payload else { continue }
                try upsertRow(
                    kind: FleetRecordKind.window,
                    scope: scope,
                    nodeID: nodeID,
                    recordKey: row.recordKey,
                    seq: Int64(report.seq),
                    generation: nil,
                    updatedAt: receivedAt,
                    payload: payload
                )
                applied.windowRowsApplied += 1
                windowContentChanged = true
            }

            try upsertRow(
                kind: FleetRecordKind.nodeMeta,
                scope: scope,
                nodeID: nodeID,
                recordKey: "high-water",
                seq: Int64(report.seq),
                generation: nil,
                updatedAt: receivedAt,
                payload: try FleetCodec.encode(HighWaterPayload(lastSeenAt: receivedAt))
            )
            applied.heartbeatUpdated = true

            // generation 只随**可见内容**变化递增（2026-10-27 裁定）：纯心跳
            // （所有通道与已存内容一致）不再递增——stale 翻转 / 日切仍由装配
            // 侧 60s 可见签名覆盖；节点据 generation 门控自然跳过无变化的快照，
            // 快照缓存不再每拍整包重写。
            if reportRowChanged || windowContentChanged {
                _ = try bumpGenerationLocked(scope: scope)
            }
            try commit()
            return applied
        } catch {
            try? rollback()
            throw error
        }
    }

    private func mergeSourceAwareDailyBucket(
        incoming: FleetDailyBucket,
        existing: FleetDailyBucket?,
        unavailableSources: [FleetDailyUnavailableSource]
    ) -> FleetDailyBucket {
        let unavailableKeys = Set(unavailableSources.map(\.sourceKey))
        let retainedRows = (existing?.clientProviders ?? []).filter {
            unavailableKeys.contains($0.clientID + "|" + $0.quotaProviderID)
        }
        let retainedEntries = (existing?.entries ?? []).filter {
            unavailableKeys.contains($0.clientID + "|" + $0.quotaProviderID)
        }
        let rows = (incoming.clientProviders + retainedRows).sorted {
            ($0.clientID, $0.quotaProviderID) < ($1.clientID, $1.quotaProviderID)
        }
        let entries = (incoming.entries + retainedEntries).sorted {
            ($0.clientID, $0.quotaProviderID, $0.modelName ?? "")
                < ($1.clientID, $1.quotaProviderID, $1.modelName ?? "")
        }
        return FleetDailyBucket(
            dayKey: incoming.dayKey,
            totals: FleetTotals(summing: rows),
            clientProviders: rows,
            entries: entries,
            totalsComplete: unavailableSources.isEmpty,
            modelDetailsComplete: incoming.modelDetailsComplete && unavailableSources.isEmpty,
            sourceTruncated: incoming.sourceTruncated,
            unavailableSources: unavailableSources
        )
    }

    private struct HighWaterPayload: Codable {
        let lastSeenAt: Date
    }

    /// 该节点已存窗口行的 payload（recordKey → 字节）。applyReport 据此按
    /// 内容判变，数值不变的行不重写、不推 generation。
    private func queryWindowPayloads(scope: String, nodeID: String) throws -> [String: Data] {
        try mapRows(
            sql: "SELECT record_key, payload_json FROM sync_records WHERE kind = ? AND scope = ? AND node_id = ?",
            bind: [.text(FleetRecordKind.window), .text(scope), .text(nodeID)]
        ) { statement in
            (try SQLiteConnection.requiredText(statement, column: 0),
             Self.columnPayload(statement, column: 1))
        }
        .reduce(into: [:]) { result, pair in
            result[pair.0] = pair.1
        }
    }

    // MARK: - hub：读状态 / 快照

    func loadHubState(scope: String) throws -> FleetHubStoredState {
        lock.lock()
        defer { lock.unlock() }

        let nodeIDTexts = try queryTexts(
            sql: "SELECT DISTINCT node_id FROM sync_records WHERE scope = ? AND node_id != '' ORDER BY node_id",
            bind: [.text(scope)]
        )
        var nodes: [FleetHubStoredState.NodeRecord] = []
        var corruptRowIDs: [Int64] = []
        for nodeIDText in nodeIDTexts {
            guard let nodeID = UUID(uuidString: nodeIDText) else { continue }
            var stored = FleetStoredReport()
            if let data = try queryPayload(sql: reportPayloadSQL, bind: [.text(scope), .text(nodeIDText)]) {
                // 坏行（磁盘损坏 / 跨版本 DTO 形状变化写下的旧行）不能让整次
                // 装配失败：一次坏行 = hub 对所有节点都回 500 = 全员中断。
                // 降级成「该节点暂无报告」，并把坏行删掉。
                if let decoded = try? FleetCodec.decode(FleetStoredReport.self, from: data) {
                    stored = decoded
                } else {
                    logWarn("[fleet-hub] 报告行损坏，按空报告处理并清理：node=\(nodeIDText)")
                    corruptRowIDs.append(contentsOf: try queryRowIDs(sql: reportRowIDSQL, bind: [.text(scope), .text(nodeIDText)]))
                }
            }
            let windowRowsResult = try queryRowsSkippingCorrupt(
                FleetWindowUsage.self,
                sql: "SELECT rowid, payload_json FROM sync_records WHERE kind = ? AND scope = ? AND node_id = ?",
                bind: [.text(FleetRecordKind.window), .text(scope), .text(nodeIDText)]
            )
            let windowRows = windowRowsResult.rows.map(\.value)
            if !windowRowsResult.corruptRowIDs.isEmpty {
                logWarn("[fleet-hub] 窗口行损坏 \(windowRowsResult.corruptRowIDs.count) 条，已跳过并清理")
                corruptRowIDs.append(contentsOf: windowRowsResult.corruptRowIDs)
            }
            let meta = try queryInt64AndPayload(
                sql: "SELECT seq, payload_json FROM sync_records WHERE kind = ? AND scope = ? AND node_id = ? AND record_key = 'high-water'",
                bind: [.text(FleetRecordKind.nodeMeta), .text(scope), .text(nodeIDText)]
            )
            var seq = 0
            var lastSeen = Date.distantPast
            if let meta {
                seq = Int(meta.int64)
                if let payload = try? FleetCodec.decode(HighWaterPayload.self, from: meta.payload) {
                    lastSeen = payload.lastSeenAt
                }
            }
            nodes.append(FleetHubStoredState.NodeRecord(
                nodeID: nodeID,
                report: stored,
                windowRows: windowRows,
                seq: seq,
                lastSeenAt: lastSeen
            ))
        }
        if !corruptRowIDs.isEmpty {
            try deleteCorruptRowsLocked(rowIDs: corruptRowIDs, scope: scope)
        }
        return FleetHubStoredState(nodes: nodes, generation: try generationLocked(scope: scope))
    }

    private let reportPayloadSQL = """
        SELECT payload_json FROM sync_records
        WHERE kind = 'report' AND scope = ? AND node_id = ? AND record_key = 'current'
        """

    private let reportRowIDSQL = """
        SELECT rowid FROM sync_records
        WHERE kind = 'report' AND scope = ? AND node_id = ? AND record_key = 'current'
        """

    // MARK: - hub：窗口过期清理 / 节点移除

    /// 清理窗口行（§7.6）：(1) `endAt` 早于 `cutoff` 的过期行；(2) 同
    /// (node, provider, model, kind) 组内 `endAt` 不是最新
    /// `FleetProtocol.windowFrontierPerGroup` 条的行——边界随额度重置滚动，
    /// 历史边界不会再等来新贡献也没有消费方，只增不删会让存储与快照随时间
    /// 线性膨胀（2026-10-27 裁定）。不清理 node_meta（high-water 与
    /// lastSeen 不因窗口清理丢失，§7.6）。
    @discardableResult
    func pruneWindows(scope: String, olderThan cutoff: Date) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        // 坏行（无法解码）跳过并清理：原来这里一抛错，整批过期窗口就再也
        // 清不掉（每次维护节拍都失败 → 窗口表只增不减）。
        let scanned: [(rowid: Int64, nodeID: String, row: FleetWindowUsage?)] = try mapRows(
            sql: "SELECT rowid, node_id, payload_json FROM sync_records WHERE kind = ? AND scope = ?",
            bind: [.text(FleetRecordKind.window), .text(scope)]
        ) { statement in
            (
                sqlite3_column_int64(statement, 0),
                try SQLiteConnection.requiredText(statement, column: 1),
                try? FleetCodec.decode(FleetWindowUsage.self, from: Self.columnPayload(statement, column: 2))
            )
        }
        var rowIDsToDelete: Set<Int64> = []
        var removedWindowRows = 0
        var byGroup: [String: [(rowid: Int64, endAt: Date)]] = [:]
        for item in scanned {
            guard let row = item.row else {
                rowIDsToDelete.insert(item.rowid)
                continue
            }
            if row.endAt < cutoff {
                if rowIDsToDelete.insert(item.rowid).inserted { removedWindowRows += 1 }
            }
            let key = [item.nodeID, row.quotaProviderID, row.modelID, row.windowKind]
                .joined(separator: "\u{0}")
            byGroup[key, default: []].append((item.rowid, row.endAt))
        }
        for members in byGroup.values where members.count > FleetProtocol.windowFrontierPerGroup {
            let excess = members
                .sorted { $0.endAt > $1.endAt }
                .dropFirst(FleetProtocol.windowFrontierPerGroup)
            for member in excess where rowIDsToDelete.insert(member.rowid).inserted {
                removedWindowRows += 1
            }
        }
        guard !rowIDsToDelete.isEmpty else { return 0 }
        try beginTransaction()
        do {
            for rowID in rowIDsToDelete {
                try execute("DELETE FROM sync_records WHERE rowid = ?", bind: [.int64(rowID)])
            }
            _ = try bumpGenerationLocked(scope: scope)
            try commit()
            return removedWindowRows
        } catch {
            try? rollback()
            throw error
        }
    }

    /// 手动移除节点（设置页「移除」）：报告、窗口、node_meta 一并删除（§10.4）。
    func removeNode(scope: String, nodeID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try beginTransaction()
        do {
            try execute(
                "DELETE FROM sync_records WHERE scope = ? AND node_id = ?",
                bind: [.text(scope), .text(nodeID.uuidString)]
            )
            _ = try bumpGenerationLocked(scope: scope)
            try commit()
        } catch {
            try? rollback()
            throw error
        }
    }

    // MARK: - 副节点：快照缓存

    func saveSnapshot(_ snapshot: FleetSnapshot, upstreamScope: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try beginTransaction()
        do {
            try upsertRow(
                kind: FleetRecordKind.snapshot,
                scope: upstreamScope,
                nodeID: "",
                recordKey: "current",
                seq: nil,
                generation: snapshot.generation,
                updatedAt: Date(),
                payload: try FleetCodec.encode(snapshot)
            )
            try commit()
        } catch {
            try? rollback()
            throw error
        }
    }

    func loadSnapshot(upstreamScope: String) throws -> FleetSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try queryPayload(
            sql: "SELECT payload_json FROM sync_records WHERE kind = ? AND scope = ? AND record_key = 'current'",
            bind: [.text(FleetRecordKind.snapshot), .text(upstreamScope)]
        ) else { return nil }
        return try decodePayload(FleetSnapshot.self, data, kind: FleetRecordKind.snapshot, recordKey: "current")
    }

    /// 副节点已缓存的 generation（upstreamKey+hubUUID 隔离；旧 generation 不覆盖，§6.5）。
    func cachedSnapshotGeneration(upstreamScope: String) throws -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        return try queryInt64(
            sql: "SELECT generation FROM sync_records WHERE kind = ? AND scope = ? AND record_key = 'current'",
            bind: [.text(FleetRecordKind.snapshot), .text(upstreamScope)]
        )
    }

    // MARK: - 本机序号

    /// 本机报告序号（`kind=seq` 单行）：事务内 读 → +1 → 写，**持久化成功才
    /// 返回**（§7.3：hub 的 high-water 据此拒绝迟到报告）。存这里而不是
    /// config.json：每轮推送都要递增，写配置文件会把配置管线变成推送回路。
    @discardableResult
    func allocateLocalSeq() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        try beginTransaction()
        do {
            let current = try queryInt64(
                sql: "SELECT seq FROM sync_records WHERE kind = 'seq' AND scope = 'local' AND node_id = '' AND record_key = 'current'",
                bind: []
            ) ?? 0
            let next = current + 1
            try upsertRow(
                kind: "seq",
                scope: "local",
                nodeID: "",
                recordKey: "current",
                seq: next,
                generation: nil,
                updatedAt: Date(),
                payload: Data("{}".utf8)
            )
            try commit()
            return Int(next)
        } catch {
            try? rollback()
            throw error
        }
    }

    /// 重建本机序号基线：hub 回报「你的序号落后」时，把本机序号一次性抬到
    /// hub 的 high-water 之上（§7.3）。否则同一份报告会被**永久**拒收，
    /// 而 node 只看到 200 —— 表现为「在线但数据永远没进 hub」。
    func resetLocalSeq(to seq: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        let target = max(0, seq)
        try beginTransaction()
        do {
            try upsertRow(
                kind: "seq",
                scope: "local",
                nodeID: "",
                recordKey: "current",
                seq: Int64(target),
                generation: nil,
                updatedAt: Date(),
                payload: Data("{}".utf8)
            )
            try commit()
        } catch {
            try? rollback()
            throw error
        }
    }

    // MARK: - generation

    /// hub 本机数据变化也递增 generation（§6.5）。
    @discardableResult
    func bumpGeneration(scope: String) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return try bumpGenerationLocked(scope: scope)
    }

    func generation(scope: String) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return try generationLocked(scope: scope)
    }

    // MARK: - 锁内实现（调用方必须已持锁）

    private func bumpGenerationLocked(scope: String) throws -> Int64 {
        let next = try generationLocked(scope: scope) + 1
        try upsertRow(
            kind: FleetRecordKind.hubMeta,
            scope: scope,
            nodeID: "",
            recordKey: "generation",
            seq: nil,
            generation: next,
            updatedAt: Date(),
            payload: Data("{}".utf8)
        )
        return next
    }

    private func generationLocked(scope: String) throws -> Int64 {
        try queryInt64(
            sql: "SELECT generation FROM sync_records WHERE kind = ? AND scope = ? AND record_key = 'generation'",
            bind: [.text(FleetRecordKind.hubMeta), .text(scope)]
        ) ?? 0
    }

    private func highWaterSeq(scope: String, nodeID: String) throws -> Int {
        try queryInt64(
            sql: "SELECT seq FROM sync_records WHERE kind = ? AND scope = ? AND node_id = ? AND record_key = 'high-water'",
            bind: [.text(FleetRecordKind.nodeMeta), .text(scope), .text(nodeID)]
        ).map(Int.init) ?? 0
    }

    private func storedReport(scope: String, nodeID: String) throws -> FleetStoredReport? {
        guard let data = try queryPayload(sql: reportPayloadSQL, bind: [.text(scope), .text(nodeID)]) else {
            return nil
        }
        return try decodePayload(FleetStoredReport.self, data, kind: FleetRecordKind.report, recordKey: "current")
    }

    private func decodePayload<T: Decodable>(
        _ type: T.Type,
        _ data: Data,
        kind: String,
        recordKey: String
    ) throws -> T {
        do {
            return try FleetCodec.decode(type, from: data)
        } catch {
            throw FleetStoreError.corruptedRow(kind: kind, recordKey: recordKey)
        }
    }

    // MARK: - 坏行处理

    /// 读行并**跳过**无法解码的坏行（返回行 + 坏行 rowid）。
    /// 单条坏行不该让整次查询失败：报告行 / 窗口行的形状会随版本变化，
    /// 旧库里的行解码失败时降级为「这行没有」，而不是让整个 hub 停摆。
    private func queryRowsSkippingCorrupt<T: Decodable>(
        _ type: T.Type,
        sql: String,
        bind: [Bind] = []
    ) throws -> (rows: [(rowid: Int64, value: T)], corruptRowIDs: [Int64]) {
        let stmt = try prepare(sql, bind: bind)
        defer { sqlite3_finalize(stmt) }
        var rows: [(rowid: Int64, value: T)] = []
        var corrupt: [Int64] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                let rowID = sqlite3_column_int64(stmt, 0)
                let data = Self.columnPayload(stmt, column: 1)
                if let value = try? FleetCodec.decode(type, from: data) {
                    rows.append((rowid: rowID, value: value))
                } else {
                    corrupt.append(rowID)
                }
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw FleetStoreError.sqlFailed(
                    code: sqlite3_errcode(handle),
                    extendedCode: sqlite3_extended_errcode(handle),
                    message: String(cString: sqlite3_errmsg(handle)),
                    sql: sql
                )
            }
        }
        return (rows, corrupt)
    }

    /// 查一组 rowid（用于定位坏行）。
    private func queryRowIDs(sql: String, bind: [Bind]) throws -> [Int64] {
        try mapRows(sql: sql, bind: bind) { statement in
            sqlite3_column_int64(statement, 0)
        }
    }

    /// 删除坏行（调用方必须已持锁）。
    private func deleteCorruptRowsLocked(rowIDs: [Int64], scope: String) throws {
        guard !rowIDs.isEmpty else { return }
        try beginTransaction()
        do {
            for rowID in rowIDs {
                try execute("DELETE FROM sync_records WHERE rowid = ?", bind: [.int64(rowID)])
            }
            _ = try bumpGenerationLocked(scope: scope)
            try commit()
        } catch {
            try? rollback()
            throw error
        }
    }

    // MARK: - SQLite 基础设施

    private enum Bind {
        case text(String)
        case int64(Int64)
        case double(Double)
        case blob(Data)
        case null
    }

    private func bindValue(_ bind: Bind, to statement: OpaquePointer, at index: Int32) -> Int32 {
        switch bind {
        case .text(let value):
            return sqlite3_bind_text(statement, index, value, -1, SQLiteConnection.sqliteTransientDestructor)
        case .int64(let value):
            return sqlite3_bind_int64(statement, index, value)
        case .double(let value):
            return sqlite3_bind_double(statement, index, value)
        case .blob(let data):
            return data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else {
                    return sqlite3_bind_zeroblob(statement, index, 0)
                }
                return sqlite3_bind_blob(
                    statement, index, base, Int32(data.count), SQLiteConnection.sqliteTransientDestructor
                )
            }
        case .null:
            return sqlite3_bind_null(statement, index)
        }
    }

    /// prepare + bind + step 一次（UPDATE / DELETE / UPSERT）。
    private func execute(_ sql: String, bind: [Bind] = []) throws {
        let stmt = try prepare(sql, bind: bind)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw sqlFailed(rc, sql)
        }
    }

    private func prepare(_ sql: String, bind: [Bind] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let prep = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prep == SQLITE_OK, let stmt else {
            throw sqlFailed(prep, sql)
        }
        for (offset, value) in bind.enumerated() {
            let code = bindValue(value, to: stmt, at: Int32(offset + 1))
            guard code == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw sqlFailed(code, sql)
            }
        }
        return stmt
    }

    private func sqlFailed(_ code: Int32, _ sql: String) -> FleetStoreError {
        guard let handle else {
            return .sqlFailed(code: code, extendedCode: code, message: "closed", sql: sql)
        }
        return .sqlFailed(
            code: code,
            extendedCode: sqlite3_extended_errcode(handle),
            message: String(cString: sqlite3_errmsg(handle)),
            sql: sql
        )
    }

    private func executeRaw(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let message = errmsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errmsg)
            throw FleetStoreError.sqlFailed(
                code: sqlite3_errcode(handle),
                extendedCode: sqlite3_extended_errcode(handle),
                message: message,
                sql: sql
            )
        }
    }

    private func beginTransaction() throws {
        try executeRaw("BEGIN IMMEDIATE")
    }

    private func commit() throws {
        try executeRaw("COMMIT")
    }

    private func rollback() throws {
        try executeRaw("ROLLBACK")
    }

    // MARK: 查询辅助

    private func queryTexts(sql: String, bind: [Bind] = []) throws -> [String] {
        try mapRows(sql: sql, bind: bind) { statement in
            try SQLiteConnection.requiredText(statement, column: 0)
        }
    }

    private func queryInt64(sql: String, bind: [Bind] = []) throws -> Int64? {
        try mapRows(sql: sql, bind: bind) { statement in
            sqlite3_column_int64(statement, 0)
        }.first
    }

    private func queryPayload(sql: String, bind: [Bind] = []) throws -> Data? {
        try mapRows(sql: sql, bind: bind) { statement in
            Self.columnPayload(statement, column: 0)
        }.first
    }

    private func queryInt64AndPayload(
        sql: String,
        bind: [Bind] = []
    ) throws -> (int64: Int64, payload: Data)? {
        try mapRows(sql: sql, bind: bind) { statement in
            (sqlite3_column_int64(statement, 0), Self.columnPayload(statement, column: 1))
        }.first
    }

    /// 单列 payload 查询（SQL 只 SELECT payload_json 一列）。
    private func queryRows<T>(
        sql: String,
        bind: [Bind] = [],
        map: (Data) throws -> T
    ) throws -> [T] {
        try mapRows(sql: sql, bind: bind) { statement in
            try map(Self.columnPayload(statement, column: 0))
        }
    }

    private func queryRowsWithRowid<T>(
        sql: String,
        bind: [Bind] = [],
        map: (Data) throws -> T
    ) throws -> [(rowid: Int64, value: T)] {
        try mapRows(sql: sql, bind: bind) { statement in
            (sqlite3_column_int64(statement, 0), try map(Self.columnPayload(statement, column: 1)))
        }
    }

    private func mapRows<T>(
        sql: String,
        bind: [Bind] = [],
        map: (OpaquePointer) throws -> T
    ) throws -> [T] {
        let stmt = try prepare(sql, bind: bind)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out.append(try map(stmt))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw sqlFailed(rc, sql)
            }
        }
        return out
    }

    private static func columnPayload(_ statement: OpaquePointer, column: Int32) -> Data {
        if sqlite3_column_type(statement, column) == SQLITE_NULL {
            return Data()
        }
        if let blob = sqlite3_column_blob(statement, column),
           sqlite3_column_bytes(statement, column) > 0 {
            return Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, column)))
        }
        if let text = sqlite3_column_text(statement, column) {
            return Data(String(cString: text).utf8)
        }
        return Data()
    }

    private func upsertRow(
        kind: String,
        scope: String,
        nodeID: String,
        recordKey: String,
        seq: Int64?,
        generation: Int64?,
        updatedAt: Date,
        payload: Data
    ) throws {
        try execute(
            """
            INSERT INTO sync_records (kind, scope, node_id, record_key, seq, generation, updated_at, payload_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (kind, scope, node_id, record_key) DO UPDATE SET
              seq = excluded.seq, generation = excluded.generation,
              updated_at = excluded.updated_at, payload_json = excluded.payload_json
            """,
            bind: [
                .text(kind), .text(scope), .text(nodeID), .text(recordKey),
                seq.map { .int64($0) } ?? .null,
                generation.map { .int64($0) } ?? .null,
                .double(updatedAt.timeIntervalSince1970),
                .blob(payload)
            ]
        )
    }
}
