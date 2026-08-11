import Foundation
import SQLite3

/// ZCode `model_usage` 聚合结果：per-day token + 累计 + samples + 见过的 model + session 数。
/// reasoning 归类在 SQL `queryPerDay` 内通过 Method A（EXISTS reasoning part）一次性算好，
/// 不再有字符分摊 / applyReasoningSplit 步骤——reader 输出的 `GlmDailyUsage.reasoningTokens`
/// 已经是最终值，scanner 直接用。
struct GlmZcodeDBAggregate: Equatable, Sendable {
    /// dayStart → 当日聚合（reasoning 已经走 Method A 归类，outputTokens/reasoningTokens 都是最终值）
    let perDay: [Date: GlmDailyUsage]
    /// 累计、有 token 的 LLM round 数（= COUNT(*)）
    let roundCount: Int
    /// 见过的 modelID（去重）
    let models: [String]
    /// 去重 session_id 数
    let sessionCount: Int
    /// 最近窗口内的逐次模型调用（reader 直接输出 Method A 分类后的 realOutput/reasoningOutput）
    let samples: [LocalTokenUsageSample]

    static let empty = GlmZcodeDBAggregate(
        perDay: [:], roundCount: 0, models: [], sessionCount: 0, samples: []
    )
}

/// 读 ZCode 的 `~/.zcode/cli/db/db.sqlite` `model_usage` 表。
///
/// 每行 = 一次模型请求，带 `provider_id='builtin:bigmodel-coding-plan'`（智谱官方
/// provider）+ `model_id='GLM-5.2'` + 5 类 token 列 + 原生 `turn_id`。查询拿到
/// per-day 5 类 token、round/turn、recent samples、totals + models + sessions。
///
/// 直接 read 原 .db；CANTOPEN / BUSY 时由调用方（`SQLiteTempCopy.read`）走 /tmp 副本。
final class GlmZcodeDBReader {
    /// ZCode 中 GLM Coding Plan 的 provider_id（智谱官方 CLI 固定值）。
    /// 复用 `OpencodeLocalUsage.zcodeGlmProviderID` 作为单一事实源。
    static let glmProviderID = OpencodeLocalUsage.zcodeGlmProviderID
    /// ZCode 中闲时任务（off-peak idle task）的 provider_id。闲时任务是系统赠送的
    /// 后台任务，不消耗 Coding Plan 积分，`model_usage` 行写在同一张表但用独立
    /// provider 区分。今日 / 7 天柱图要包含其真实 token 消耗，额度窗口统计优先靠
    /// sample 保存的 provider 身份精确排除；时间窗口只用于兼容旧缓存。
    static let offPeakProviderID = OpencodeLocalUsage.zcodeOffPeakProviderID

    private let connection: SQLiteConnection

    init(path: URL, readOnly: Bool = false) throws {
        self.connection = try SQLiteConnection(path: path, readOnly: readOnly)
    }

    func close() { connection.close() }

    /// 聚合全部 GLM 模型调用。`calendar` 用于把 'yyyy-MM-dd' day key 转成本地午夜 Date。
    func aggregate(calendar: Calendar, sampleCutoff: Date? = nil) throws -> GlmZcodeDBAggregate {
        let perDay = try queryPerDay(calendar: calendar, cutoff: sampleCutoff)
        let totals = try queryTotals()
        let models = try queryModels()
        let samples = try querySamples(cutoff: sampleCutoff)

        return GlmZcodeDBAggregate(
            perDay: perDay,
            roundCount: totals.roundCount,
            models: models,
            sessionCount: totals.sessionCount,
            samples: samples
        )
    }

    // MARK: - queries

    /// per-day token 聚合（Method A 已在 SQL CASE 内归类 reasoning）。GLM 行按
    /// `strftime('%Y-%m-%d', started_at/1000,'unixepoch','localtime')` 归到本地自然日。
    /// rounds = `COUNT(*)`，turns = `COUNT(DISTINCT turn_id)`。
    ///
    /// **Method A 归类规则**（per-row `CASE`）：
    /// 1. `mu.reasoning_tokens > 0`（priority path）: `output_tokens` 列报账单值, `reasoning_tokens` 列报账单值（独立加总, 不重分类）
    /// 2. `assistant_message_id` 存在 + `part` 表有 `type='reasoning'` part: `output_tokens = 0`, `reasoning_tokens = output_tokens`（整轮归 reasoning）
    /// 3. 其他（text-only part / 缺 `type` 字段 / `assistant_message_id IS NULL`）: `output_tokens` 保持原值, `reasoning_tokens = 0`
    ///
    /// 100% 基于账单列和 part JSON 直接判断, 不做字符换算;无浮点开销;reader 输出的
    /// `GlmDailyUsage.reasoningTokens` 已经是最终值,scanner 无需再分摊。
    private func queryPerDay(calendar: Calendar, cutoff: Date?) throws -> [Date: GlmDailyUsage] {
        let sql = """
        SELECT
          strftime('%Y-%m-%d', mu.started_at/1000,'unixepoch','localtime') AS day,
          COUNT(*) AS rounds,
          COUNT(DISTINCT mu.turn_id) AS turns,
          SUM(MAX(COALESCE(mu.input_tokens, 0), 0)) AS tin,
          SUM(MAX(CASE
            WHEN COALESCE(mu.reasoning_tokens, 0) > 0 THEN COALESCE(mu.output_tokens, 0)
            WHEN EXISTS (
              SELECT 1 FROM part p WHERE p.message_id = mu.assistant_message_id
                AND json_extract(CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.type') = 'reasoning'
            ) THEN 0
            ELSE COALESCE(mu.output_tokens, 0)
          END, 0)) AS tout,
          SUM(MAX(CASE
            WHEN COALESCE(mu.reasoning_tokens, 0) > 0 THEN COALESCE(mu.reasoning_tokens, 0)
            WHEN EXISTS (
              SELECT 1 FROM part p WHERE p.message_id = mu.assistant_message_id
                AND json_extract(CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.type') = 'reasoning'
            ) THEN COALESCE(mu.output_tokens, 0)
            ELSE 0
          END, 0)) AS trsn,
          SUM(MAX(COALESCE(mu.cache_read_input_tokens, 0), 0)) AS tcr,
          SUM(MAX(COALESCE(mu.cache_creation_input_tokens, 0), 0)) AS tcw
        FROM model_usage mu
        WHERE mu.provider_id IN (?, ?)
          AND mu.status = 'completed'
          AND (
            COALESCE(mu.input_tokens,0)
            + COALESCE(mu.output_tokens,0)
            + COALESCE(mu.reasoning_tokens,0)
            + COALESCE(mu.cache_read_input_tokens,0)
          ) > 0
          AND (? IS NULL OR mu.started_at >= ?)
        GROUP BY day
        """
        let cutoffMs = cutoff.map { Int64($0.timeIntervalSince1970 * 1000) }
        var out: [Date: GlmDailyUsage] = [:]
        let rows: [(String, Int64, Int64, Int64, Int64, Int64, Int64, Int64)] = try connection.query(
            sql: sql,
            bind: { stmt in
                let provider = Self.bindProviders(to: stmt, index: 1)
                guard provider == SQLITE_OK else { return provider }
                let first = cutoffMs.map { sqlite3_bind_int64(stmt, 3, $0) } ?? sqlite3_bind_null(stmt, 3)
                guard first == SQLITE_OK else { return first }
                if let cutoffMs { return sqlite3_bind_int64(stmt, 4, cutoffMs) }
                return sqlite3_bind_null(stmt, 4)
            },
            map: { stmt in
            let dayKey = try SQLiteConnection.requiredText(stmt, column: 0)
            let rounds = try SQLiteConnection.requiredInt64(stmt, column: 1)
            let turns = try SQLiteConnection.requiredInt64(stmt, column: 2)
            let tin = SQLiteConnection.optionalInt64(stmt, column: 3)
            let tout = SQLiteConnection.optionalInt64(stmt, column: 4)
            let trsn = SQLiteConnection.optionalInt64(stmt, column: 5)
            let tcr = SQLiteConnection.optionalInt64(stmt, column: 6)
            let tcw = SQLiteConnection.optionalInt64(stmt, column: 7)
            return (dayKey, rounds, turns, tin, tout, trsn, tcr, tcw)
            }
        )
        for (dayKey, rounds, turns, tin, tout, trsn, tcr, tcw) in rows {
            guard let dayStart = Self.parseDayKey(dayKey, calendar: calendar) else { continue }
            // R9: 读取层再做非负饱和（单行 MAX 已在 SQL 内 clamp，这里作第二层防御）。
            let toutNN = Self.nnClamp(tout)
            let trsnNN = Self.nnClamp(trsn)
            let tcrNN = Self.nnClamp(tcr)
            let tcwNN = Self.nnClamp(tcw)
            // uncached input = max(input_raw - cacheRead, 0)，用原始 Int64 饱和减法
            let uncachedInput = Int(clamping: max(SaturatingArithmetic.subtract(tin, tcr), 0))
            // total = uncached + cacheRead + output + reason（用 uncached 重算，
            // 避免 cacheRead > input_raw 的取整误差让 total 偏小）
            let total = SaturatingArithmetic.sum(uncachedInput, tcrNN, toutNN, trsnNN)
            let usage = GlmDailyUsage(
                dayStart: dayStart,
                inputTokens: uncachedInput,
                outputTokens: toutNN,
                cacheReadTokens: tcrNN,
                cacheWriteTokens: tcwNN,
                reasoningTokens: trsnNN,
                totalTokens: total,
                turns: max(0, Int(clamping: turns)),
                rounds: max(0, Int(clamping: rounds))
            )
            if let existing = out[dayStart] {
                out[dayStart] = existing + usage
            } else {
                out[dayStart] = usage
            }
        }
        return out
    }

    /// 累计、有 token 的 LLM round 数 + 去重 session 数。
    private func queryTotals() throws -> (roundCount: Int, sessionCount: Int) {
        let sql = """
        SELECT
          COUNT(*) AS calls,
          COUNT(DISTINCT session_id) AS sessions
        FROM model_usage
        WHERE provider_id IN (?, ?)
          AND status = 'completed'
          AND (
            COALESCE(input_tokens,0)
            + COALESCE(output_tokens,0)
            + COALESCE(reasoning_tokens,0)
            + COALESCE(cache_read_input_tokens,0)
          ) > 0
        """
        let rows: [(Int64, Int64)] = try connection.query(sql: sql, bind: { stmt in
            Self.bindProviders(to: stmt, index: 1)
        }) { stmt in
            let calls = try SQLiteConnection.requiredInt64(stmt, column: 0)
            let sessions = try SQLiteConnection.requiredInt64(stmt, column: 1)
            return (calls, sessions)
        }
        guard let row = rows.first else {
            return (roundCount: 0, sessionCount: 0)
        }
        return (roundCount: Int(clamping: row.0), sessionCount: Int(clamping: row.1))
    }

    /// 最近窗口内的逐次调用样本。ZCode 的 `input_tokens` 已是**完整 input（含 cacheRead）**，
    /// 与 `LocalTokenUsageSample.inputTokens`（完整 input）口径一致，直接用即可；
    /// `cachedInputTokens` = `cache_read_input_tokens`（input 的子集）。
    /// promptID 用 `session_id:turn_id`（turn_id 缺失时退回 `event-<id>`），
    /// 让一次 user prompt 下的多次调用归为同一组。
    private func querySamples(cutoff: Date?) throws -> [LocalTokenUsageSample] {
        let sql = """
        SELECT
          mu.id,
          mu.session_id,
          mu.started_at,
          mu.turn_id,
          mu.model_id,
          mu.input_tokens,
          CASE
            WHEN COALESCE(mu.reasoning_tokens, 0) > 0 THEN COALESCE(mu.output_tokens, 0)
            WHEN EXISTS (
              SELECT 1 FROM part p WHERE p.message_id = mu.assistant_message_id
                AND json_extract(CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.type') = 'reasoning'
            ) THEN 0
            ELSE COALESCE(mu.output_tokens, 0)
          END AS real_output,
          CASE
            WHEN COALESCE(mu.reasoning_tokens, 0) > 0 THEN COALESCE(mu.reasoning_tokens, 0)
            WHEN EXISTS (
              SELECT 1 FROM part p WHERE p.message_id = mu.assistant_message_id
                AND json_extract(CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.type') = 'reasoning'
            ) THEN COALESCE(mu.output_tokens, 0)
            ELSE 0
          END AS reasoning_output,
          mu.cache_read_input_tokens,
          mu.provider_id
        FROM model_usage mu
        WHERE mu.provider_id IN (?, ?)
          AND mu.status = 'completed'
          AND (
            COALESCE(mu.input_tokens,0)
            + COALESCE(mu.output_tokens,0)
            + COALESCE(mu.reasoning_tokens,0)
            + COALESCE(mu.cache_read_input_tokens,0)
          ) > 0
          AND (? IS NULL OR mu.started_at >= ?)
        ORDER BY mu.started_at, mu.id
        """
        let cutoffMs = cutoff.map { Int64($0.timeIntervalSince1970 * 1000) }
        let rows: [(String, String, Int64, String?, String?, Int64, Int64, Int64, Int64, String)] = try connection.query(
            sql: sql,
            bind: { stmt in
                let provider = Self.bindProviders(to: stmt, index: 1)
                guard provider == SQLITE_OK else { return provider }
                let first = cutoffMs.map { sqlite3_bind_int64(stmt, 3, $0) } ?? sqlite3_bind_null(stmt, 3)
                guard first == SQLITE_OK else { return first }
                if let cutoffMs { return sqlite3_bind_int64(stmt, 4, cutoffMs) }
                return sqlite3_bind_null(stmt, 4)
            },
            map: { stmt in
                let id = try SQLiteConnection.requiredText(stmt, column: 0)
                let sessionID = try SQLiteConnection.requiredText(stmt, column: 1)
                let timestamp = try SQLiteConnection.requiredInt64(stmt, column: 2)
                let turn = SQLiteConnection.optionalText(stmt, column: 3)
                let model = SQLiteConnection.optionalText(stmt, column: 4)
                let input = SQLiteConnection.optionalInt64(stmt, column: 5)
                let output = SQLiteConnection.optionalInt64(stmt, column: 6)
                let reasoning = SQLiteConnection.optionalInt64(stmt, column: 7)
                let cacheRead = SQLiteConnection.optionalInt64(stmt, column: 8)
                let providerID = try SQLiteConnection.requiredText(stmt, column: 9)
                return (id, sessionID, timestamp, turn, model, input, output, reasoning, cacheRead, providerID)
            }
        )

        var samples: [LocalTokenUsageSample] = []
        for (id, sessionID, timestamp, turn, model, input, output, reasoning, cacheRead, providerID) in rows {
            let promptComponent = turn ?? "event-\(id)"
            // R9: 读取层非负饱和；input 用 nn(input)，cachedInput 用 nn(cacheRead)。
            let inNN = Self.nnClamp(input)
            let crNN = Self.nnClamp(cacheRead)
            let sample = LocalTokenUsageSample(
                completedAt: Date(timeIntervalSince1970: Double(timestamp) / 1000),
                modelName: model,
                promptID: "\(sessionID):\(promptComponent)",
                inputTokens: inNN,
                cachedInputTokens: crNN,
                outputTokens: Self.nnClamp(output),
                reasoningOutputTokens: Self.nnClamp(reasoning),
                sourceProviderID: providerID
            )
            samples.append(sample)
        }
        return samples
    }

    /// 见过的 modelID（去重）。
    private func queryModels() throws -> [String] {
        let sql = """
        SELECT DISTINCT model_id
        FROM model_usage
        WHERE provider_id IN (?, ?)
          AND model_id IS NOT NULL
        """
        let rows: [String] = try connection.query(sql: sql, bind: { stmt in
            Self.bindProviders(to: stmt, index: 1)
        }) { stmt in
            try SQLiteConnection.requiredText(stmt, column: 0)
        }
        return rows.sorted()
    }

    /// 'yyyy-MM-dd' → 本地午夜 Date。
    private static func parseDayKey(_ dayKey: String, calendar: Calendar) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// R9: Int64? → 非负 Int 饱和（NULL 当 0，负值当 0，超出 Int 范围封顶）。
    @inline(__always)
    private static func nnClamp(_ x: Int64?) -> Int {
        let v = Int(clamping: x ?? 0)
        return v < 0 ? 0 : v
    }

    private static let sqliteTransientDestructor = unsafeBitCast(
        Int(-1), to: sqlite3_destructor_type.self
    )

    /// 绑定 GLM Coding Plan 与闲时任务两个 provider（`provider_id IN (?, ?)`）。
    /// `index` 为第一个 `?` 的位置，第二个紧跟其后。
    private static func bindProviders(to statement: OpaquePointer, index: Int32) -> Int32 {
        let first = sqlite3_bind_text(
            statement,
            index,
            (glmProviderID as NSString).utf8String,
            -1,
            sqliteTransientDestructor
        )
        guard first == SQLITE_OK else { return first }
        return sqlite3_bind_text(
            statement,
            index + 1,
            (offPeakProviderID as NSString).utf8String,
            -1,
            sqliteTransientDestructor
        )
    }
}
