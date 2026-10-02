import Foundation

// MARK: - Cache + index types

extension AntigravityLocalUsageScanner {
    struct SessionIndexEntry: Equatable, Codable, Sendable {
        var mtimeMs: Double
        var sizeBytes: Int
        /// `.db` 的 WAL 是活跃 session 最常变化的文件；主 session 文件可能长期不变。
        var walMtimeMs: Double
        var walSizeBytes: Int
        var fetchedAt: Date?
        var eventCount: Int
        var generatorMetadataOffset: Int
        var lastMaxStepIndex: Int?
        var lastTurnIndex: Int?
        /// Last transient empty incremental response. The file fingerprint is
        /// intentionally not advanced in that case; this timestamp only
        /// prevents hot-loop retries while the local server catches up.
        var lastEmptySuffixAt: Date?
        /// 连续空 suffix 计数。达到 `emptySuffixVerificationThreshold` 后，该
        /// session 的下一个 dirty plan 升级为 offset=0 全量核验；核验确认
        /// metadata 总数未变则按成功收敛并清零。计数跨至少一次 30s 节流，
        /// 相当于给滞后的 language server 两次追赶机会。
        var consecutiveEmptySuffixes: Int

        init(
            mtimeMs: Double,
            sizeBytes: Int,
            walMtimeMs: Double = 0,
            walSizeBytes: Int = 0,
            fetchedAt: Date?,
            eventCount: Int,
            generatorMetadataOffset: Int = 0,
            lastMaxStepIndex: Int? = nil,
            lastTurnIndex: Int? = nil,
            lastEmptySuffixAt: Date? = nil,
            consecutiveEmptySuffixes: Int = 0
        ) {
            self.mtimeMs = mtimeMs
            self.sizeBytes = sizeBytes
            self.walMtimeMs = walMtimeMs
            self.walSizeBytes = walSizeBytes
            self.fetchedAt = fetchedAt
            self.eventCount = eventCount
            self.generatorMetadataOffset = generatorMetadataOffset
            self.lastMaxStepIndex = lastMaxStepIndex
            self.lastTurnIndex = lastTurnIndex
            self.lastEmptySuffixAt = lastEmptySuffixAt
            self.consecutiveEmptySuffixes = consecutiveEmptySuffixes
        }

        private enum CodingKeys: String, CodingKey {
            case mtimeMs, sizeBytes, walMtimeMs, walSizeBytes, fetchedAt, eventCount
            case generatorMetadataOffset, lastMaxStepIndex, lastTurnIndex, lastEmptySuffixAt
            case consecutiveEmptySuffixes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mtimeMs = try container.decode(Double.self, forKey: .mtimeMs)
            sizeBytes = try container.decode(Int.self, forKey: .sizeBytes)
            // v2 index 没有 WAL 字段；以 0 迁移，若当前存在 WAL 会自然 dirty 一次。
            walMtimeMs = try container.decodeIfPresent(Double.self, forKey: .walMtimeMs) ?? 0
            walSizeBytes = try container.decodeIfPresent(Int.self, forKey: .walSizeBytes) ?? 0
            fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt)
            eventCount = try container.decode(Int.self, forKey: .eventCount)
            generatorMetadataOffset = try container.decodeIfPresent(Int.self, forKey: .generatorMetadataOffset) ?? 0
            lastMaxStepIndex = try container.decodeIfPresent(Int.self, forKey: .lastMaxStepIndex)
            lastTurnIndex = try container.decodeIfPresent(Int.self, forKey: .lastTurnIndex)
            lastEmptySuffixAt = try container.decodeIfPresent(Date.self, forKey: .lastEmptySuffixAt)
            consecutiveEmptySuffixes = try container.decodeIfPresent(Int.self, forKey: .consecutiveEmptySuffixes) ?? 0
        }
    }

    /// 顶层 index 状态，存到应用统一的 `token-monitor/antigravity.json`。
    /// - `sessions`：所有已扫描过的本地 sessionId → session 文件及可选 WAL 的 mtime/size + 上次拉 RPC 的时间
    /// - `dailyBySession`：每个 session 按本地自然日拆开的 token 聚合
    ///   （让 changed session 只需要替换自己的贡献，不用重新拉取其他 session）
    struct CacheIndex: Equatable, Codable, Sendable {
        var version: Int
        var lastScannedAt: Date
        var sessions: [String: SessionIndexEntry]
        var dailyBySession: [String: [String: AntigravityDailyUsage]]
        var samplesBySession: [String: [LocalTokenUsageSample]]?
        /// Optional for backward decoding; nil deliberately invalidates the
        /// cached day buckets until this source completes one current-calendar scan.
        var calendarSignature: String? = nil
        /// 零 metadata 全量结果的连续打击计数（按 session）。全量/核验页返回
        /// 0 条 raw metadata（连错 server/workspace，或 language server 重启后
        /// 丢失 trajectory 记忆）时 +1；达到 `zeroMetadataFullStrikeLimit`
        /// 后该 session 按成功收敛：有 last-good 的保留 last-good 并采用当前
        /// 指纹，无数据的写空终结条目。拿到非零 metadata 即清零。可选字段，
        /// 旧 index.json decode 时默认 nil，保证向后兼容。
        var emptyFullStrikesBySession: [String: Int]? = nil
        /// 旧日历重建待办标记（按 session）。时区/日历变更冷重建中按"零 metadata
        /// 收敛"终结的 session，保留的 last-good daily 仍按旧日历分桶，而零
        /// metadata 使立即重建不可能；签名照常推进（避免每次 reconcile 全量冷
        /// 重建、对零 metadata session 反复发 RPC）。作为补偿：文件重新活跃
        /// （指纹变化）时对该 session 排一次 offset=0 full 按当前日历重建日桶，
        /// full 成功替换日桶后标记清除；下一次日历失效的冷重建也会对它们全量
        /// 重规划，标记不会阻碍。可选字段，旧 index.json decode 时默认 nil，
        /// 保证向后兼容。
        var calendarRebuildPendingSessions: Set<String>? = nil
        /// "有 raw metadata 但零可计账 event"页（全量/增量 alike）的连续打击
        /// 计数（按 session）。解析损坏（token 字段改名/换层级）或天然全零
        /// token 的 session 会让页持续零可计账；无界计失败会打破"所有持久失败
        /// 模式有界收敛"的不变量（failedCount 永不归零 → 签名永不推进 → 每轮
        /// reconcile 全量冷重建）。达到 `zeroAccountedFullStrikeLimit` 轮后按
        /// 成功收敛：采用当前文件指纹并完整保留 last-good（offset 刻意不推进，
        /// 文件再变化时用可能已修复的解析器重试）。拿到可入账 event 的页即
        /// 清零。可选字段，旧 index.json decode 时默认 nil，保证向后兼容。
        var zeroAccountedFullStrikesBySession: [String: Int]? = nil
        /// 全量页 offset 回归（返回的 raw metadata 总数 < 缓存的
        /// `generatorMetadataOffset`，server 丢数据/截断/连错 workspace）的
        /// 连续打击计数（按 session）。照常全量替换会把 offset/eventCount
        /// 直接覆盖成小值、本地已入账历史永久丢失；这里保留 last-good 并累计
        /// 打击，达到 `offsetRegressionStrikeLimit` 轮后按成功收敛：采用当前
        /// 文件指纹、完整保留 last-good（offset 绝不回退），server 端恢复后
        /// 由全量重算或增量消费自然补齐。拿到 count >= 缓存 offset 的页即清零。
        /// 增量页按 raw 条数消费、没有 count vs offset 的对账关系，不参与本
        /// 计数。可选字段，旧 index.json decode 时默认 nil，保证向后兼容。
        var offsetRegressionStrikesBySession: [String: Int]? = nil
        /// 「部分命中分量」告警的去重状态（按 session）：记录该 session 上次
        /// 已告警的未命中分量集合，集合不变时不重复告警（集合变化才再记）。
        /// `parseUsageEvent` 的逐事件 logWarn 在部分命中高频场景（token 字段
        /// 改名后多 session × 数千条 × 周期性重扫）会把轮转日志冲掉好几轮，
        /// 告警上移到聚合点后按 session 收敛为一条汇总；持久化让重启后同样
        /// 收敛。可选字段，旧 index.json decode 时默认 nil，保证向后兼容。
        var partialHitWarnedBySession: [String: Set<String>]? = nil

        static let empty = CacheIndex(
            version: 7,
            lastScannedAt: Date(timeIntervalSince1970: 0),
            sessions: [:],
            dailyBySession: [:],
            samplesBySession: [:],
            calendarSignature: nil
        )
    }
}
