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

    init(
        perDay: [Date: MinimaxDailyUsage],
        perDayChars: [Date: MinimaxCharCounts],
        sessionCount: Int,
        eventCount: Int,
        turnCount: Int,
        samples: [LocalTokenUsageSample] = []
    ) {
        self.perDay = perDay
        self.perDayChars = perDayChars
        self.sessionCount = sessionCount
        self.eventCount = eventCount
        self.turnCount = turnCount
        self.samples = samples
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
    private static let sqliteTransientDestructor = unsafeBitCast(
        Int(-1), to: sqlite3_destructor_type.self
    )
    var path: String { conn.path }

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
                   sampleCutoff: Date? = nil) throws -> MinimaxDBAggregate {
        let resolvedTableName = Self.runtimeTableName
        let safeRawExpr = "CASE WHEN json_valid(t.raw) THEN t.raw ELSE '{}' END"
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
            WHERE t.ts IS NOT NULL
            GROUP BY day_key
            ORDER BY day_key
            """
        let rows = try conn.query(sql: perDaySQL) { stmt -> PerDayRow in
            let dayKey = try SQLiteConnection.requiredText(stmt, column: 0)
            let rounds = Self.nonNegativeInt(sqlite3_column_int64(stmt, 1))
            let turns = Self.nonNegativeInt(sqlite3_column_int64(stmt, 2))
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
            let sessions = Self.nonNegativeInt(sqlite3_column_int64(stmt, 0))
            let events = Self.nonNegativeInt(sqlite3_column_int64(stmt, 1))
            return TotalsRow(sessions: sessions, events: events)
        }
        let sessionCount = totals.first?.sessions ?? 0
        let eventCount = totals.first?.events ?? 0

        // 逐次调用只保留 UI 需要的最近窗口。inputTokens 归一为
        // uncached + cacheRead，和 Codex UsageMetricSummary 的语义一致。
        let sampleWhere = sampleCutoff == nil
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
        let hasSessionModelProjection = sessionColumns.contains("session_id")
            && sessionColumns.contains("record_json")
        let ledgerModelExpression = hasModelColumn ? "NULLIF(TRIM(t.model), '')" : "NULL"
        let sessionModelExpression = hasSessionModelProjection
            ? "NULLIF(TRIM(json_extract(CASE WHEN json_valid(s.record_json) THEN s.record_json ELSE '{}' END, '$.effectiveModel')), '')"
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
        let sessionJoin = hasSessionModelProjection
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
              t.cache_read_tokens
            FROM \(resolvedTableName) t
            \(sessionJoin)
            \(sampleWhere)
            ORDER BY t.ts
        """
        let cutoffMs = sampleCutoff.map { Int64($0.timeIntervalSince1970 * 1000) }
        let sampleBind: ((OpaquePointer) -> Int32)? = (uniqueObservedModel != nil || cutoffMs != nil)
            ? { stmt in
                var nextIndex: Int32 = 1
                if let uniqueObservedModel {
                    let code = sqlite3_bind_text(
                        stmt,
                        nextIndex,
                        (uniqueObservedModel as NSString).utf8String,
                        -1,
                        Self.sqliteTransientDestructor
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
                let modelName = optionalText(2)
                let timestampMs = Self.nonNegativeInt(
                    try SQLiteConnection.requiredInt64(stmt, column: 3)
                )
                let uncachedInput = Self.nonNegativeInt(sqlite3_column_int64(stmt, 4))
                let output = Self.nonNegativeInt(sqlite3_column_int64(stmt, 5))
                let reasoning = Self.nonNegativeInt(sqlite3_column_int64(stmt, 6))
                let cachedInput = Self.nonNegativeInt(sqlite3_column_int64(stmt, 7))
                let promptComponent = turnID ?? "event-\(timestampMs)"
                return LocalTokenUsageSample(
                    completedAt: Date(timeIntervalSince1970: Double(timestampMs) / 1000),
                    modelName: modelName,
                    promptID: "\(sessionID):\(promptComponent)",
                    inputTokens: SaturatingArithmetic.add(uncachedInput, cachedInput),
                    cachedInputTokens: cachedInput,
                    outputTokens: output,
                    reasoningOutputTokens: reasoning
                )
            }
        )

        perDayChars = (try? runtimePerDayCharAggregate(calendar: calendar)) ?? [:]

        return MinimaxDBAggregate(
            perDay: perDay,
            perDayChars: perDayChars,
            sessionCount: sessionCount,
            eventCount: eventCount,
            turnCount: totalTurns,
            samples: samples
        )
    }

    /// v2 路径: 独立 per-day 字符聚合 (不 join token_usage)
    /// 从 `local_runtime_message_rows` (或 `session_messages` 测试兼容表) 按 day 桶聚合
    /// thinking_content + msg_content 字符数, 跟 runtime token rows 按日配对。
    private func runtimePerDayCharAggregate(calendar: Calendar) throws -> [Date: MinimaxCharCounts] {
        let hasRuntimeTable = try !conn.query(sql: "PRAGMA table_info(local_runtime_message_rows)") { stmt in
            try SQLiteConnection.requiredText(stmt, column: 1)
        }.isEmpty
        guard hasRuntimeTable else { return [:] }

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
            GROUP BY day_key
            """
        struct Row {
            let dayKey: String
            let messageCount: Int
            let reasonChars: Int
            let outputChars: Int
        }
        let rows = try conn.query(sql: sql) { stmt -> Row in
            let dayKey = try SQLiteConnection.requiredText(stmt, column: 0)
            let messageCount = Self.nonNegativeInt(sqlite3_column_int64(stmt, 1))
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

    // MARK: - helpers

    /// SQLite 聚合列进入业务模型的统一边界：计数不允许为负，并对不同 Int
    /// 位宽做饱和转换。当前 macOS 为 64-bit，合法数据数值保持不变。
    private static func nonNegativeInt(_ value: Int64) -> Int {
        guard value > 0 else { return 0 }
        return Int(clamping: value)
    }

    /// `TOTAL()` 返回 Double：正常计数截断到整数，超出平台 Int 或 +∞ 时饱和。
    /// NaN / 负值没有业务含义，统一归零。
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
