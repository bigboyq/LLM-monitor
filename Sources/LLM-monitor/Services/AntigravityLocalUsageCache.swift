import Foundation

// MARK: - Cache + index types

extension AntigravityLocalUsageScanner {
    /// v9（2026-11-08，阶段二b）：数据源从本地 RPC 切换为 `.db` 直读
    /// （`AntigravitySessionDBReader`）后，逐事件增量状态机整体退役——本地读便宜
    /// 且确定性，session 脏了就全量重读，条目只剩文件指纹与入账计数。
    /// v8 及更早的 `generatorMetadataOffset` / `lastMaxStepIndex` /
    /// `lastTurnIndex` / `lastEmptySuffixAt` / `consecutiveEmptySuffixes` 与顶层
    /// 打击/标记字段不再存在；加载旧版本索引一律按空缓存全量重建（见
    /// `AntigravityFilesystem.loadIndex`）。
    struct SessionIndexEntry: Equatable, Codable, Sendable {
        var mtimeMs: Double
        var sizeBytes: Int
        /// `.db` 的 WAL 是活跃 session 最常变化的文件；主 session 文件可能长期不变。
        var walMtimeMs: Double
        var walSizeBytes: Int
        var fetchedAt: Date?
        var eventCount: Int
        /// 连续**可重试**读失败计数（v9 schema 内演进：合成 Codable 对 Optional
        /// 走 `decodeIfPresent` / `encodeIfPresent`，旧 v9 缓存无此键照常解码）。
        /// nil / 0 = 健康；任何成功读取与指纹收敛都会清零。仅可重试 I/O 故障
        /// 递增，达到 `retryableReadFailureConvergenceLimit` 后按现状采纳指纹
        /// 收敛（见 `performScanPureImpl` 失败分支）。
        var consecutiveReadFailures: Int?

        init(
            mtimeMs: Double,
            sizeBytes: Int,
            walMtimeMs: Double = 0,
            walSizeBytes: Int = 0,
            fetchedAt: Date?,
            eventCount: Int,
            consecutiveReadFailures: Int? = nil
        ) {
            self.mtimeMs = mtimeMs
            self.sizeBytes = sizeBytes
            self.walMtimeMs = walMtimeMs
            self.walSizeBytes = walSizeBytes
            self.fetchedAt = fetchedAt
            self.eventCount = eventCount
            self.consecutiveReadFailures = consecutiveReadFailures
        }
    }

    /// 顶层 index 状态，存到应用统一的 `token-monitor/antigravity.json`。
    /// - `sessions`：所有已扫描过的本地 sessionId → session 文件及 WAL 的 mtime/size + 上次读取时间
    /// - `dailyBySession`：每个 session 按本地自然日拆开的 token 聚合
    ///   （让 changed session 只需要替换自己的贡献，不用重新读取其他 session）
    /// - `samplesBySession`：最近 8 天窗口内的逐调用样本
    struct CacheIndex: Equatable, Codable, Sendable {
        var version: Int
        var lastScannedAt: Date
        var sessions: [String: SessionIndexEntry]
        var dailyBySession: [String: [String: AntigravityDailyUsage]]
        var samplesBySession: [String: [LocalTokenUsageSample]]?
        /// Optional for backward decoding; nil deliberately invalidates the
        /// cached day buckets until this source completes one current-calendar scan.
        var calendarSignature: String? = nil

        /// v9：`.db` 直读数据源（阶段二b）。v8 及更早索引自带 RPC 增量状态机字段，
        /// 不做字段级迁移——加载时整体重置为空缓存，首个扫描轮对全部 session
        /// 全量重读（本地读毫秒级）。
        static let empty = CacheIndex(
            version: 9,
            lastScannedAt: Date(timeIntervalSince1970: 0),
            sessions: [:],
            dailyBySession: [:],
            samplesBySession: [:],
            calendarSignature: nil
        )
    }
}
