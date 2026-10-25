import Foundation
import SQLite3

/// 单条 assistant 消息的"账单 vs 实际"字符分解。
/// scanner 拿这俩字符数按比例分摊 `output_tokens` 出 `reasoning_tokens`。
/// - `reason`：thinking_content 字符数
/// - `output`：msg_content 字符数 (含 tool_call_args 字符,排除 tool_call_result_data)
/// - `messageCount`：当天 assistant 消息行数 (P1-1 v2 sanity check 用)
///   v2 路径 = 真实 local_runtime_message_rows 当天行数
struct MinimaxCharCounts: Equatable, Sendable {
    let reason: Int
    let output: Int
    let messageCount: Int

    static let zero = MinimaxCharCounts(reason: 0, output: 0, messageCount: 0)

    /// 总字符数（用于守恒公式的分母 R+C）
    var total: Int { SaturatingArithmetic.add(reason, output) }
}

/// 单源 .db 读取结果：per-day 聚合 + 总 session / event 数
struct MinimaxDBAggregate: Equatable, Sendable {
    /// dayStart (本地自然日 00:00) → 当日聚合
    let perDay: [Date: MinimaxDailyUsage]
    /// dayStart → 当日字符分解（thinking_content + msg_content + 当天 message 行数）。
    /// v2 路径三个都填 (独立 per-day 聚合,需要 messageCount 验证 token 写入是否完整)。
    /// scanner 用这个按比例分摊 `outputTokens` 出 `reasoningTokens`。
    let perDayChars: [Date: MinimaxCharCounts]
    /// 去重 session 数
    let sessionCount: Int
    /// 总 rounds (= 总行数)
    let eventCount: Int
    /// 总去重 turn 数
    let turnCount: Int
    /// 最近窗口的逐次调用。scanner 会按每日 reasoning 比例做最终校正。
    let samples: [LocalTokenUsageSample]
    /// 字符聚合 SQL 失败时为 true：主 token 账本仍然有效（Reason 按 0 处理），
    /// 但 scanner 不得把该 source 当作完全成功 —— 指纹 entry 会带上 degraded
    /// 标记并在下一轮扫描强制重试。
    let charAggregationDegraded: Bool

    init(
        perDay: [Date: MinimaxDailyUsage],
        perDayChars: [Date: MinimaxCharCounts],
        sessionCount: Int,
        eventCount: Int,
        turnCount: Int,
        samples: [LocalTokenUsageSample] = [],
        charAggregationDegraded: Bool = false
    ) {
        self.perDay = perDay
        self.perDayChars = perDayChars
        self.sessionCount = sessionCount
        self.eventCount = eventCount
        self.turnCount = turnCount
        self.samples = samples
        self.charAggregationDegraded = charAggregationDegraded
    }

    static let empty = MinimaxDBAggregate(
        perDay: [:], perDayChars: [:],
        sessionCount: 0, eventCount: 0, turnCount: 0, samples: []
    )
}

/// 内部 row type（避免 query 闭包返回 unlabeled tuple 字段访问问题）
private struct PerDayRow {
    let dayKey: String
    let rounds: Int
    let turns: Int
    let input: Int
    let output: Int
    let reasoning: Int
    let cacheRead: Int
    let cacheWrite: Int
}

private struct TotalsRow {
    let sessions: Int
    let events: Int
}

/// `local_runtime_message_rows`(role='assistant') 单行的时长回填条目。
/// `inputTokens` / `outputTokens` 是 `data_json.$.usage` 里的未缓存输入与输出——
/// 与 `local_runtime_token_usage` 对应列**逐行相等**（实测 11838/11838，全历史），
/// 用作 FIFO 配对前的核对依据；`nil` = `$.usage` 缺该字段（空行），永不匹配。
/// `durationSeconds` = `$.usage.request_duration_ms` / 1000（缺失 / ≤0 → nil）。
internal struct MinimaxMessageDurationEntry: Equatable {
    let inputTokens: Int?
    let outputTokens: Int?
    let durationSeconds: Double?
}

/// FIFO 配对键：`(session_id, turn_id)`。`turn_id` 为 NULL / 空串的 message 行
/// 不参与配对（无法与样本可靠对齐，宁可缺时长也不猜）。
internal struct MinimaxMessageDurationKey: Hashable {
    let sessionID: String
    let turnID: String
}

/// minimax v2 runtime 数据库的只读 reader。线程模型：单 instance 单线程使用。
///
/// minimax 的 db reader 跟 antigravity 的关键区别：
/// - antigravity reader 只查 `steps` 表（`step_type=14/15`）算 R/T，token 数据要从 RPC 拉
/// - minimax reader **直接 SELECT 聚合 `local_runtime_token_usage` 表**——SQLite 一次返回完整 per-day
///   输入/输出/缓存/成本数据，零跨源 join
///
/// 重构后：底层 init/close/query helper 复用 `SQLiteConnection`，本 reader
/// 只保留 minimax v2 领域 SQL（`aggregate(calendar:)`）。
final class MinimaxDBReader {
    private let conn: SQLiteConnection
    var path: String { conn.path }

    /// Test-only: 统计字符聚合被尝试的次数，验证 degraded source 的强制重试语义。
    /// Release build 编译期消除。
    #if DEBUG
    nonisolated(unsafe) static var testCharAggregateAttempts = 0
    #endif

    init(path: URL, readOnly: Bool = false) throws {
        self.conn = try SQLiteConnection(path: path, readOnly: readOnly)
    }

    deinit { conn.close() }

    func close() {
        conn.close()
    }

    // MARK: - 聚合查询

    /// v2 runtime 的 token usage 表名。固定为 v2 schema，避免误读旧版数据库。
    /// 目标 runtime 表名
    private static let runtimeTableName = "local_runtime_token_usage"

    /// 直接 SQL 聚合 v2 的 `local_runtime_token_usage` 表 → per-day MinimaxDailyUsage
    /// + 总 session/event/turn 数。
    ///
    /// SQL 设计要点：
    /// - **表名**：固定为 v2 的 `local_runtime_token_usage`，不支持旧版 `token_usage` 表。
    /// - **时区**：`strftime('%Y-%m-%d', ts/1000, 'unixepoch', 'localtime')` ——
    ///   `localtime` modifier 让 SQLite 用进程的本地时区（macOS 上是用户时区）转换；
    ///   不用 SQLite 的话要 Swift 端按 `Calendar.current` 算，跨夜边界容易出 bug
    ///   （antigravity `ee165e9` 修过的 timezone mapping bug）
    /// - **R/T**：`COUNT(*)` = rounds，`COUNT(DISTINCT turn_id)` = turns。**同源 SQL
    ///   算完**，没有跨源 join 也就没有"RPC 顺序漂移"的坑
    ///   （对比 antigravity `64ca68b` 修过的间歇性 R/T 空白）
    /// - **空 turn_id 处理**：`NULL` 跟空串都会被 `COUNT(DISTINCT)` 跳过（SQL 标准）；
    ///   实测 minimax 数据里 `turn_id` 全部非 NULL 非空，不需要特殊处理
    /// - **cutoff**：per-day 聚合与字符聚合都带时间下界（对齐 GlmZcode reader 的
    ///   口径）。UI 只消费最近 7 天；dirty 重扫时无下界的全表 GROUP BY 是纯浪费。
    ///   总 session/event 计数仍是全历史口径，不受 cutoff 影响。
    ///
    /// v2 source (runtime-state) 的 `local_runtime_token_usage.turn_id` 是 UUID 格式,跟
    /// `local_runtime_message_rows.msg_id` (msg_xxx 格式)**不匹配**,
    /// 没法 per-turn join。v2 走**独立 per-day 聚合**:
    /// 从 `local_runtime_message_rows.created_at_ms` 直接按 day 桶聚合字符数,
    /// 跟 runtime message rows 按 day 桶对齐 (同一 turn 时间差几秒,大多数 case 同 day)。
    ///
    /// 极端边界 (token_usage 完成在 23:59:58,message_rows 落盘在 00:00:01):
    /// 直接 SQL 聚合 v2 的 `local_runtime_token_usage` 表 → per-day MinimaxDailyUsage + 总 session/event/turn 数。
    func aggregate(calendar: Calendar = .current,
                   cutoff: Date? = nil,
                   sessionModelResolver: MinimaxSessionModelResolver? = nil) throws -> MinimaxDBAggregate {
        // 本地 var：resolver 内部有 per-session 缓存，样本 map 闭包里要能写它
        // （闭包是 non-escaping，捕获的是引用）。
        var resolver = sessionModelResolver
        let resolvedTableName = Self.runtimeTableName
        let cutoffMs = cutoff.map { Int64($0.timeIntervalSince1970 * 1000) }
        let safeRawExpr = "CASE WHEN json_valid(t.raw) THEN t.raw ELSE '{}' END"
        let dayCutoffPredicate = " AND (? IS NULL OR t.ts >= ?)"
        func nonNegativeTotal(_ expression: String) -> String {
            "TOTAL(MAX(CAST(COALESCE(\(expression), 0) AS REAL), 0.0))"
        }
        let rawReasoningValue = "json_extract(\(safeRawExpr), '$.reasoning')"
        let perRowReasoningExpr = """
            MAX(
              MAX(CAST(COALESCE(t.reasoning_tokens, 0) AS REAL), 0.0),
              MAX(CAST(COALESCE(\(rawReasoningValue), 0) AS REAL), 0.0)
            )
            """
        let perDaySQL = """
            SELECT
              strftime('%Y-%m-%d', t.ts/1000, 'unixepoch', 'localtime') AS day_key,
              COUNT(*)                                    AS rounds,
              COUNT(DISTINCT t.turn_id)                   AS turns,
              \(nonNegativeTotal("t.input_tokens"))       AS input,
              \(nonNegativeTotal("t.output_tokens"))      AS output,
              TOTAL(\(perRowReasoningExpr))               AS reasoning,
              \(nonNegativeTotal("t.cache_read_tokens"))  AS cache_read,
              \(nonNegativeTotal("t.cache_write_tokens")) AS cache_write
            FROM \(resolvedTableName) t
            WHERE t.ts IS NOT NULL\(dayCutoffPredicate)
            GROUP BY day_key
            ORDER BY day_key
            """
        let rows = try conn.query(
            sql: perDaySQL,
            bind: SQLiteConnection.bindNullableMsCutoff(cutoffMs, startingAt: 1)
        ) { stmt -> PerDayRow in
            let dayKey = try SQLiteConnection.requiredText(stmt, column: 0)
            let rounds = SQLiteConnection.nnClamp(sqlite3_column_int64(stmt, 1))
            let turns = SQLiteConnection.nnClamp(sqlite3_column_int64(stmt, 2))
            let input = Self.nonNegativeInt(sqlite3_column_double(stmt, 3))
            let output = Self.nonNegativeInt(sqlite3_column_double(stmt, 4))
            let reasoning = Self.nonNegativeInt(sqlite3_column_double(stmt, 5))
            let cacheRead = Self.nonNegativeInt(sqlite3_column_double(stmt, 6))
            let cacheWrite = Self.nonNegativeInt(sqlite3_column_double(stmt, 7))
            return PerDayRow(
                dayKey: dayKey, rounds: rounds, turns: turns,
                input: input, output: output, reasoning: reasoning,
                cacheRead: cacheRead, cacheWrite: cacheWrite
            )
        }

        var perDay: [Date: MinimaxDailyUsage] = [:]
        var perDayChars: [Date: MinimaxCharCounts] = [:]
        var totalTurns = 0
        for r in rows {
            guard let dayStart = parseLocalDayKey(r.dayKey, calendar: calendar) else {
                logWarn("[minimax/reader] skip row with unparseable day_key=\(r.dayKey)")
                continue
            }
            let total = SaturatingArithmetic.sum(
                r.input,
                r.cacheRead,
                r.output,
                r.reasoning
            )
            perDay[dayStart] = MinimaxDailyUsage(
                dayStart: dayStart,
                inputTokens: r.input,
                outputTokens: r.output,
                cacheReadTokens: r.cacheRead,
                cacheWriteTokens: r.cacheWrite,
                reasoningTokens: r.reasoning,
                totalTokens: total,
                turns: r.turns,
                rounds: r.rounds
            )
            totalTurns = SaturatingArithmetic.add(totalTurns, r.turns)
        }

        // 2. 总 session 数 + 总 event 数（一次性拿，跟 per-day 用同一个 connection）
        let totalsSQL = """
            SELECT
              COUNT(DISTINCT session_id)  AS session_count,
              COUNT(*)                    AS event_count
            FROM \(resolvedTableName)
            WHERE ts IS NOT NULL
            """
        let totals = try conn.query(sql: totalsSQL) { stmt -> TotalsRow in
            let sessions = SQLiteConnection.nnClamp(sqlite3_column_int64(stmt, 0))
            let events = SQLiteConnection.nnClamp(sqlite3_column_int64(stmt, 1))
            return TotalsRow(sessions: sessions, events: events)
        }
        let sessionCount = totals.first?.sessions ?? 0
        let eventCount = totals.first?.events ?? 0

        // request_duration_ms 回填队列（独立守门，与字符聚合的 degraded 互不影响）。
        // `local_runtime_message_rows`(role='assistant') 的
        // `data_json.$.usage.request_duration_ms` 是单次 LLM 请求的完整耗时
        // （含 TTFT + decode，严格不含工具执行）。**不能**用
        // `created_at_ms − token 行 ts` 差分替代：95.8% 的 assistant 行
        // finish_reason="toolUse"，其 created_at_ms 记录的是工具执行完成时刻
        // （要把 tool_call_result_data 内嵌进同一条行才落盘），差分会把工具耗时
        // （P90 +30s）算进"模型耗时"。
        // 本查询失败（坏表 / 缺列 / 锁）只让样本 durationSeconds 保持 nil——主
        // token 账本、字符聚合与 charAggregationDegraded 都不受影响。不置
        // degraded 强制重扫：时长是纯增强数据，缺了不改任何 token 数字，只影响
        // tok/s 的分母覆盖面，活跃 runtime 的指纹 diff（~2 min）很快自然重试。
        var durationQueues: [MinimaxMessageDurationKey: [MinimaxMessageDurationEntry]] = [:]
        do {
            durationQueues = try runtimeAssistantDurationQueues(cutoffMs: cutoffMs)
        } catch {
            logWarn(
                "[minimax/reader] request_duration_ms 回填查询失败，样本 durationSeconds 保持 nil: "
                    + "source=\(conn.path), error=\(error.localizedDescription)"
            )
        }

        // 逐次调用只保留 UI 需要的最近窗口。inputTokens 归一为
        // uncached + cacheRead，和 Codex UsageMetricSummary 的语义一致。
        let sampleWhere = cutoffMs == nil
            ? "WHERE t.ts IS NOT NULL"
            : "WHERE t.ts IS NOT NULL AND t.ts >= ?"
        // 旧版/测试 fixture 可能还没有 `model` 列。额度统计本身不依赖它；
        // 缺失时用 NULL，让 general 文本模型仍可匹配，而不是让整个 source 失败。
        let tableColumns = try conn.query(sql: "PRAGMA table_info(\(resolvedTableName))") { stmt in
            try SQLiteConnection.requiredText(stmt, column: 1)
        }
        let hasModelColumn = tableColumns.contains("model")
        let sessionColumns = try conn.query(sql: "PRAGMA table_info(local_runtime_sessions)") { stmt in
            try SQLiteConnection.requiredText(stmt, column: 1)
        }
        // MiniMax runtime 在 2026-08-15 的 schema migration 后，部分 token
        // ledger row 不再写 model，但 session projection 仍可能保留
        // record_json.effectiveModel。优先使用 row 自己的 model，再回退到
        // session model；若整个 ledger 只有一个明确模型，最后再使用这个
        // 唯一模型作为保守回退，避免把多模型数据错误合并。
        //
        // **但这条回退链写出来的模型名是不可信的**：账本行与 session 投影里
        // 存的都是泛化标签 `minimax/MiniMax-M3`，不是真实模型。真实模型只写在
        // session 目录的 `llm-call.json` 里（见 `MinimaxSessionModelResolver`），
        // 由调用方通过 `sessionModelResolver` 传入：它有值时**优先于**下面整条
        // 链。否则窗口内全部 M3.1 Flash 用量都会被归到 M3 名下（模型名错，
        // 定价也跟着错）。
        let hasSessionJoin = sessionColumns.contains("session_id")
            && (sessionColumns.contains("record_json") || sessionColumns.contains("history_relative_dir"))
        let hasSessionModelProjection = hasSessionJoin && sessionColumns.contains("record_json")
        let ledgerModelExpression = hasModelColumn ? "NULLIF(TRIM(t.model), '')" : "NULL"
        let sessionModelExpression = hasSessionModelProjection
            ? "NULLIF(TRIM(json_extract(CASE WHEN json_valid(s.record_json) THEN s.record_json ELSE '{}' END, '$.effectiveModel')), '')"
            : "NULL"
        // session 相对目录（`~/.minimax/v2/sessions/<dir>`）——真实模型的落点。
        let sessionRelativeDirExpression = hasSessionJoin && sessionColumns.contains("history_relative_dir")
            ? "NULLIF(TRIM(s.history_relative_dir), '')"
            : "NULL"
        let observedModels: [String] = hasModelColumn
            ? try conn.query(sql: """
                SELECT DISTINCT TRIM(model)
                FROM \(resolvedTableName)
                WHERE model IS NOT NULL AND TRIM(model) <> ''
                ORDER BY TRIM(model)
                """) { stmt in
                try SQLiteConnection.requiredText(stmt, column: 0)
            }
            : []
        let uniqueObservedModel = observedModels.count == 1 ? observedModels[0] : nil
        let uniqueObservedModelExpression = uniqueObservedModel == nil ? "NULL" : "?"
        let sampleModelExpression = "COALESCE(\(ledgerModelExpression), \(sessionModelExpression), \(uniqueObservedModelExpression))"
        let sessionJoin = hasSessionJoin
            ? "LEFT JOIN local_runtime_sessions s ON s.session_id = t.session_id"
            : ""
        let sampleSQL = """
            SELECT
              t.session_id,
              t.turn_id,
              \(sampleModelExpression) AS model,
              t.ts,
              t.input_tokens,
              t.output_tokens,
              t.reasoning_tokens,
              t.cache_read_tokens,
              \(sessionRelativeDirExpression) AS session_relative_dir
            FROM \(resolvedTableName) t
            \(sessionJoin)
            \(sampleWhere)
            ORDER BY t.ts
        """
        let sampleBind: ((OpaquePointer) -> Int32)? = (uniqueObservedModel != nil || cutoffMs != nil)
            ? { stmt in
                var nextIndex: Int32 = 1
                if let uniqueObservedModel {
                    let code = sqlite3_bind_text(
                        stmt,
                        nextIndex,
                        (uniqueObservedModel as NSString).utf8String,
                        -1,
                        SQLiteConnection.sqliteTransientDestructor
                    )
                    guard code == SQLITE_OK else { return code }
                    nextIndex += 1
                }
                if let cutoffMs {
                    return sqlite3_bind_int64(stmt, nextIndex, cutoffMs)
                }
                return SQLITE_OK
            }
            : nil
        let samples = try conn.query(
            sql: sampleSQL,
            bind: sampleBind,
            map: { stmt -> LocalTokenUsageSample in
                func optionalText(_ column: Int32) -> String? {
                    guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
                          let pointer = sqlite3_column_text(stmt, column) else {
                        return nil
                    }
                    let value = String(cString: pointer)
                    return value.isEmpty ? nil : value
                }

                let sessionID = try SQLiteConnection.requiredText(stmt, column: 0)
                let turnID = optionalText(1)
                let sqlModelName = optionalText(2)
                let timestampMs = SQLiteConnection.nnClamp(
                    try SQLiteConnection.requiredInt64(stmt, column: 3)
                )
                let uncachedInput = SQLiteConnection.nnClamp(sqlite3_column_int64(stmt, 4))
                let output = SQLiteConnection.nnClamp(sqlite3_column_int64(stmt, 5))
                let reasoning = SQLiteConnection.nnClamp(sqlite3_column_int64(stmt, 6))
                let cachedInput = SQLiteConnection.nnClamp(sqlite3_column_int64(stmt, 7))
                // 真实模型（session 目录 llm-call.json）优先于账本/投影里的泛化标签。
                let sessionRelativeDir = optionalText(8)
                var sessionModelName: String?
                if let sessionRelativeDir {
                    sessionModelName = resolver?.modelName(forRelativeDir: sessionRelativeDir)
                }
                let modelName = sessionModelName ?? sqlModelName
                let promptComponent = turnID ?? "event-\(timestampMs)"
                // MiniMax raw input is uncached and cache-read is separate;
                // route raw→桶 through the harness catalog and rebuild the
                // legacy cache-inclusive sample here. Reasoning is split later
                // by the scanner when a safe native/character-based signal
                // exists (the split preserves every field written here).
                let buckets = TokenAccountingCatalog.minimax.normalizedBuckets(
                    rawInput: uncachedInput,
                    cacheRead: cachedInput,
                    rawOutput: output,
                    rawReasoning: reasoning
                )
                // request_duration_ms 回填：同 (session_id, turn_id) 的 message 行
                // 按 FIFO 顺序弹出，`$.usage.input_tokens` / `output_tokens` 与账本
                // 行原始值（nnClamp 后）双核对通过才采纳时长——对不上的条目按序
                // 丢弃（空行 / 窗口边缘不对齐），队列耗尽仍无匹配则保持 nil，
                // 宁可缺时长也不把时长安到错误的调用上。
                var sampleDuration: Double? = nil
                if let turnID, !turnID.isEmpty {
                    let key = MinimaxMessageDurationKey(sessionID: sessionID, turnID: turnID)
                    var queue = durationQueues[key] ?? []
                    sampleDuration = Self.verifiedDuration(
                        from: &queue,
                        ledgerInputTokens: uncachedInput,
                        ledgerOutputTokens: output
                    )
                    durationQueues[key] = queue
                }
                return LocalTokenUsageSample(
                    completedAt: Date(timeIntervalSince1970: Double(timestampMs) / 1000),
                    modelName: modelName,
                    promptID: "\(sessionID):\(promptComponent)",
                    inputTokens: buckets.cacheInclusiveInput,
                    cachedInputTokens: buckets.cacheRead,
                    outputTokens: buckets.output,
                    reasoningOutputTokens: buckets.reasoning,
                    durationSeconds: sampleDuration
                )
            }
        )

        // 字符聚合是 Reason 拆分的增强数据，不是主账本：失败时保留 token 主账本、
        // Reason 按 0 处理，并把 degraded 标记带回给 scanner（强制下一轮重试）。
        // 不得用 try? 静默吞掉 —— 那会让指纹照常推进，Reason=0 氡化且无诊断线索。
        #if DEBUG
        MinimaxDBReader.testCharAggregateAttempts += 1
        #endif
        var charAggregationDegraded = false
        do {
            perDayChars = try runtimePerDayCharAggregate(calendar: calendar, cutoffMs: cutoffMs)
        } catch {
            charAggregationDegraded = true
            perDayChars = [:]
            logWarn(
                "[minimax/reader] 字符聚合 SQL 失败，Reason 按 0 降级并标记重试: "
                    + "source=\(conn.path), error=\(error.localizedDescription)"
            )
        }

        return MinimaxDBAggregate(
            perDay: perDay,
            perDayChars: perDayChars,
            sessionCount: sessionCount,
            eventCount: eventCount,
            turnCount: totalTurns,
            samples: samples,
            charAggregationDegraded: charAggregationDegraded
        )
    }

    /// v2 路径: 独立 per-day 字符聚合 (不 join token_usage)
    /// 从 `local_runtime_message_rows` (或 `session_messages` 测试兼容表) 按 day 桶聚合
    /// thinking_content + msg_content 字符数, 跟 runtime token rows 按日配对。
    /// cutoff 与 token per-day 聚合同口径：只聚合最近窗口内的行。
    private func runtimePerDayCharAggregate(calendar: Calendar, cutoffMs: Int64?) throws -> [Date: MinimaxCharCounts] {
        let hasRuntimeTable = try !conn.query(sql: "PRAGMA table_info(local_runtime_message_rows)") { stmt in
            try SQLiteConnection.requiredText(stmt, column: 1)
        }.isEmpty
        guard hasRuntimeTable else { return [:] }

        let cutoffPredicate = cutoffMs == nil
            ? ""
            : " AND (? IS NULL OR created_at_ms >= ?)"
        let sql = """
            WITH safe_messages AS (
              SELECT
                created_at_ms,
                CASE WHEN json_valid(data_json) THEN data_json ELSE '{}' END AS safe_data
              FROM local_runtime_message_rows
              WHERE role = 'assistant'
            )
            SELECT
              strftime('%Y-%m-%d', created_at_ms/1000, 'unixepoch', 'localtime') AS day_key,
              COUNT(*) AS message_count,
              TOTAL(LENGTH(json_extract(safe_data, '$.thinking_content'))) AS reason_chars,
              TOTAL(LENGTH(json_extract(safe_data, '$.msg_content')))
                + TOTAL((
                    SELECT TOTAL(LENGTH(json_extract(
                      CASE WHEN json_valid(j.value) THEN j.value ELSE '{}' END,
                      '$.tool_call_args'
                    )))
                    FROM json_each(
                      CASE
                        WHEN json_type(safe_data, '$.tool_calls') = 'array'
                        THEN json_extract(safe_data, '$.tool_calls')
                        ELSE '[]'
                      END
                    ) j
                  )) AS output_chars
            FROM safe_messages
            WHERE 1=1\(cutoffPredicate)
            GROUP BY day_key
            """
        struct Row {
            let dayKey: String
            let messageCount: Int
            let reasonChars: Int
            let outputChars: Int
        }
        let rows = try conn.query(
            sql: sql,
            // cutoff 为 nil 时谓词整个不进 SQL（无占位符），必须传 bind: nil。
            bind: cutoffMs == nil ? nil : SQLiteConnection.bindNullableMsCutoff(cutoffMs, startingAt: 1)
        ) { stmt -> Row in
            let dayKey = try SQLiteConnection.requiredText(stmt, column: 0)
            let messageCount = SQLiteConnection.nnClamp(sqlite3_column_int64(stmt, 1))
            let reasonChars = Self.nonNegativeInt(sqlite3_column_double(stmt, 2))
            let outputChars = Self.nonNegativeInt(sqlite3_column_double(stmt, 3))
            return Row(dayKey: dayKey, messageCount: messageCount,
                       reasonChars: reasonChars, outputChars: outputChars)
        }
        var perDayChars: [Date: MinimaxCharCounts] = [:]
        for r in rows {
            guard let dayStart = parseLocalDayKey(r.dayKey, calendar: calendar) else { continue }
            if r.reasonChars > 0 || r.outputChars > 0 {
                perDayChars[dayStart] = MinimaxCharCounts(
                    reason: r.reasonChars, output: r.outputChars,
                    messageCount: r.messageCount
                )
            }
        }
        return perDayChars
    }

    /// request_duration_ms 回填队列：保留窗口内 assistant message 行按
    /// `(session_id, turn_id)` 分组，`id` 升序（行写入序；同 turn 内与账本行
    /// `ts` 序实测一致，全历史 11838 对 100% 配对）。与字符聚合同表同过滤风格
    /// （`role = 'assistant'` + created_at_ms cutoff），但**独立守门**——失败由
    /// `aggregate()` 自己的 do/catch 接住，不进 `charAggregationDegraded`。
    /// 表不存在 / 缺列（旧 schema、坏 fixture）在 prepare 阶段抛 SQLITE_ERROR，
    /// 调用方 catch 后队列为空，样本 durationSeconds 全部保持 nil。
    private func runtimeAssistantDurationQueues(
        cutoffMs: Int64?
    ) throws -> [MinimaxMessageDurationKey: [MinimaxMessageDurationEntry]] {
        let cutoffPredicate = cutoffMs == nil
            ? ""
            : " AND (? IS NULL OR created_at_ms >= ?)"
        let sql = """
            SELECT
              session_id,
              turn_id,
              json_extract(data_json, '$.usage.input_tokens'),
              json_extract(data_json, '$.usage.output_tokens'),
              json_extract(data_json, '$.usage.request_duration_ms')
            FROM local_runtime_message_rows
            WHERE role = 'assistant'
              AND turn_id IS NOT NULL AND turn_id <> ''\(cutoffPredicate)
            ORDER BY id
            """
        struct Row {
            let sessionID: String
            let turnID: String
            let inputTokens: Int?
            let outputTokens: Int?
            let durationMs: Double?
        }
        let rows = try conn.query(
            sql: sql,
            // cutoff 为 nil 时谓词整个不进 SQL（无占位符），必须传 bind: nil。
            bind: cutoffMs == nil ? nil : SQLiteConnection.bindNullableMsCutoff(cutoffMs, startingAt: 1)
        ) { stmt -> Row in
            // `$.usage` 缺字段时 json_extract 返回 SQL NULL；nil 让核对永不匹配
            // （空行不能把任何时长锁死在队头），而不是当 0 参与比较。
            func optionalJSONInt(_ column: Int32) -> Int? {
                guard sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
                return SQLiteConnection.nnClamp(sqlite3_column_int64(stmt, column))
            }
            func optionalJSONDouble(_ column: Int32) -> Double? {
                guard sqlite3_column_type(stmt, column) != SQLITE_NULL else { return nil }
                return sqlite3_column_double(stmt, column)
            }
            return Row(
                sessionID: try SQLiteConnection.requiredText(stmt, column: 0),
                turnID: try SQLiteConnection.requiredText(stmt, column: 1),
                inputTokens: optionalJSONInt(2),
                outputTokens: optionalJSONInt(3),
                durationMs: optionalJSONDouble(4)
            )
        }
        var queues: [MinimaxMessageDurationKey: [MinimaxMessageDurationEntry]] = [:]
        queues.reserveCapacity(rows.count)
        for row in rows {
            guard !row.sessionID.isEmpty, !row.turnID.isEmpty else { continue }
            let durationSeconds: Double?
            if let durationMs = row.durationMs, durationMs.isFinite, durationMs > 0 {
                durationSeconds = durationMs / 1000.0
            } else {
                // request_duration_ms 缺失 / 0 / 负值 → nil：tok/s 分母只认有效时长
                // （0.2–3600s），0 会被 0.2 下界滤掉，但直接不写更诚实。
                durationSeconds = nil
            }
            queues[MinimaxMessageDurationKey(sessionID: row.sessionID, turnID: row.turnID), default: []]
                .append(MinimaxMessageDurationEntry(
                    inputTokens: row.inputTokens,
                    outputTokens: row.outputTokens,
                    durationSeconds: durationSeconds
                ))
        }
        return queues
    }

    /// 从 FIFO 队头找出第一条 `input_tokens` / `output_tokens` 都与账本行相等的
    /// message 条目并返回其时长；核对不上的条目按序丢弃（空行 / 窗口边缘
    /// 不对齐的行不阻塞后续配对），队列耗尽仍无匹配返回 nil——宁可缺时长，
    /// 也不把时长安到错误的调用上。`queue` 以 inout 传出让丢弃结果留在队列里。
    /// static 纯逻辑，单测可直接验证 FIFO / 核对语义（不需要构造 DB）。
    static func verifiedDuration(
        from queue: inout [MinimaxMessageDurationEntry],
        ledgerInputTokens: Int,
        ledgerOutputTokens: Int
    ) -> Double? {
        while !queue.isEmpty {
            let entry = queue.removeFirst()
            if let input = entry.inputTokens, let output = entry.outputTokens,
               input == ledgerInputTokens, output == ledgerOutputTokens {
                return entry.durationSeconds
            }
        }
        return nil
    }

    // MARK: - helpers

    /// `TOTAL()` 返回 Double：正常计数截断到整数，超出平台 Int 或 +∞ 时饱和。
    /// NaN / 负值没有业务含义，统一归零。（Int64 列的非负饱和走
    /// `SQLiteConnection.nnClamp`。）
    private static func nonNegativeInt(_ value: Double) -> Int {
        guard !value.isNaN, value > 0 else { return 0 }
        guard value.isFinite, value < Double(Int.max) else { return Int.max }
        return Int(value.rounded(.towardZero))
    }

    /// "yyyy-MM-dd" 本地时区 → Date (本地 00:00)
    /// 跟 `LocalUsageDayKey.make` 反向，3 个 SQLite scanner (antigravity / minimax / opencode)
    /// 共享。失败返回 nil
    /// （之前 fallback to `Date()` 会让脏 row 静默落到"今天"——已经修过）。
    private func parseLocalDayKey(_ key: String, calendar: Calendar) -> Date? {
        LocalUsageDayKey.parse(key, calendar: calendar)
    }
}
