import Foundation
import SQLite3

/// opencode.db 读取结果：per-provider × per-day 的原始聚合，scanner 再聚成 7 天窗口。
struct OpencodeDBAggregate: Equatable, Sendable {
    /// providerID → dayStart → 当日聚合
    let perProviderDay: [String: [Date: OpencodeDailyUsage]]
    /// providerID → 累计、有 token 的 LLM round 数
    let roundCount: [String: Int]
    /// providerID → 累计 cost
    let cost: [String: Double]
    /// providerID → 见过的 modelID
    let models: [String: [String]]
    /// providerID → 最近窗口内的逐次 assistant 调用
    let samples: [String: [LocalTokenUsageSample]]

    static let empty = OpencodeDBAggregate(
        perProviderDay: [:], roundCount: [:], cost: [:], models: [:], samples: [:]
    )
}

/// 读 opencode 的 `~/.local/share/opencode/opencode.db` `message` 表。
///
/// 每条 assistant message 的 `data` JSON 带 `providerID` + `tokens{...}`；
/// message 表的 `time_created` 是按日聚合和逐次样本的时间来源。
/// 查询拿到 per-provider × per-day 的 5 类 token、round/turn、recent samples、totals + models。
/// 直接 read 原 .db；CANTOPEN / BUSY 时由调用方（`SQLiteTempCopy.read`）走 /tmp 副本。
final class OpencodeDBReader {
    private let connection: SQLiteConnection

    init(path: URL, readOnly: Bool = false) throws {
        self.connection = try SQLiteConnection(path: path, readOnly: readOnly)
    }

    func close() { connection.close() }

    /// 聚合全部 assistant 调用。`calendar` 用于把 'yyyy-MM-dd' day key 转成本地午夜 Date。
    func aggregate(calendar: Calendar, sampleCutoff: Date? = nil) throws -> OpencodeDBAggregate {
        let perDay = try queryPerDay(calendar: calendar)
        let totals = try queryTotals()
        let models = try queryModels()
        let samples = try querySamples(cutoff: sampleCutoff)

        // 合并三个查询结果到同一 providerID 集合
        var perProviderDay: [String: [Date: OpencodeDailyUsage]] = [:]
        for (provider, byDay) in perDay {
            perProviderDay[provider] = byDay
        }
        return OpencodeDBAggregate(
            perProviderDay: perProviderDay,
            roundCount: totals.rounds,
            cost: totals.cost,
            models: models,
            samples: samples
        )
    }

    // MARK: - queries

    /// per-provider × per-day token 聚合。
    /// `json_extract` 在路径缺失时返回 NULL；`SUM` 忽略 NULL，全 NULL 时返回 NULL → 按 0 计。
    ///
    /// R9: 每个 token 字段在 SUM 前先做 `MAX(COALESCE(value,0),0)`，单行负值不能抵消
    /// 其他行的合法正值；读取层再做非负饱和。
    private func queryPerDay(calendar: Calendar) throws -> [String: [Date: OpencodeDailyUsage]] {
        let sql = """
        SELECT
          json_extract(data,'$.providerID') AS provider,
          strftime('%Y-%m-%d', time_created/1000,'unixepoch','localtime') AS day,
          COUNT(*) AS rounds,
          COUNT(DISTINCT COALESCE(json_extract(data,'$.parentID'), id)) AS turns,
          SUM(MAX(COALESCE(json_extract(data,'$.tokens.input'), 0), 0)) AS tin,
          SUM(MAX(COALESCE(json_extract(data,'$.tokens.output'), 0), 0)) AS tout,
          SUM(MAX(COALESCE(json_extract(data,'$.tokens.reasoning'), 0), 0)) AS trsn,
          SUM(MAX(COALESCE(json_extract(data,'$.tokens.cache.read'), 0), 0)) AS tcr,
          SUM(MAX(COALESCE(json_extract(data,'$.tokens.cache.write'), 0), 0)) AS tcw
        FROM message
        WHERE json_extract(data,'$.role')='assistant'
          AND json_extract(data,'$.tokens') IS NOT NULL
          AND json_extract(data,'$.providerID') IS NOT NULL
          AND (
            COALESCE(json_extract(data,'$.tokens.input'),0)
            + COALESCE(json_extract(data,'$.tokens.output'),0)
            + COALESCE(json_extract(data,'$.tokens.reasoning'),0)
            + COALESCE(json_extract(data,'$.tokens.cache.read'),0)
          ) > 0
        GROUP BY provider, day
        """
        var out: [String: [Date: OpencodeDailyUsage]] = [:]
        let rows: [(String, String, Int64, Int64, Int64, Int64, Int64, Int64, Int64)] = try connection.query(sql: sql) { stmt in
            let provider = try SQLiteConnection.requiredText(stmt, column: 0)
            let dayKey = try SQLiteConnection.requiredText(stmt, column: 1)
            let rounds = try SQLiteConnection.requiredInt64(stmt, column: 2)
            let turns = try SQLiteConnection.requiredInt64(stmt, column: 3)
            let tin = SQLiteConnection.optionalInt64(stmt, column: 4)
            let tout = SQLiteConnection.optionalInt64(stmt, column: 5)
            let trsn = SQLiteConnection.optionalInt64(stmt, column: 6)
            let tcr = SQLiteConnection.optionalInt64(stmt, column: 7)
            let tcw = SQLiteConnection.optionalInt64(stmt, column: 8)
            return (provider, dayKey, rounds, turns, tin, tout, trsn, tcr, tcw)
        }
        for (provider, dayKey, rounds, turns, tin, tout, trsn, tcr, tcw) in rows {
            guard let dayStart = Self.parseDayKey(dayKey, calendar: calendar) else { continue }
            let inNN = Self.nnClamp(tin)
            let outNN = Self.nnClamp(tout)
            let crNN = Self.nnClamp(tcr)
            let cwNN = Self.nnClamp(tcw)
            let rsnNN = Self.nnClamp(trsn)
            let usage = OpencodeDailyUsage(
                dayStart: dayStart,
                inputTokens: inNN,
                outputTokens: outNN,
                cacheReadTokens: crNN,
                cacheWriteTokens: cwNN,
                reasoningTokens: rsnNN,
                totalTokens: SaturatingArithmetic.sum(inNN, outNN, rsnNN, crNN),
                turns: max(0, Int(clamping: turns)),
                rounds: max(0, Int(clamping: rounds))
            )
            var byDay = out[provider] ?? [:]
            if let existing = byDay[dayStart] {
                byDay[dayStart] = existing + usage
            } else {
                byDay[dayStart] = usage
            }
            out[provider] = byDay
        }
        return out
    }

    /// per-provider 累计、有 token 的 LLM round 数 + cost。
    private func queryTotals() throws -> (rounds: [String: Int], cost: [String: Double]) {
        let sql = """
        SELECT
          json_extract(data,'$.providerID') AS provider,
          COUNT(*) AS calls,
          SUM(json_extract(data,'$.cost')) AS cost
        FROM message
        WHERE json_extract(data,'$.role')='assistant'
          AND json_extract(data,'$.providerID') IS NOT NULL
          AND json_extract(data,'$.tokens') IS NOT NULL
          AND (
            COALESCE(json_extract(data,'$.tokens.input'),0)
            + COALESCE(json_extract(data,'$.tokens.output'),0)
            + COALESCE(json_extract(data,'$.tokens.reasoning'),0)
            + COALESCE(json_extract(data,'$.tokens.cache.read'),0)
          ) > 0
        GROUP BY provider
        """
        var rounds: [String: Int] = [:]
        var cost: [String: Double] = [:]
        let rows: [(String, Int64, Double)] = try connection.query(sql: sql) { stmt in
            let provider = try SQLiteConnection.requiredText(stmt, column: 0)
            let c = try SQLiteConnection.requiredInt64(stmt, column: 1)
            let cst = SQLiteConnection.optionalDouble(stmt, column: 2)
            return (provider, c, cst)
        }
        for (provider, c, cst) in rows {
            rounds[provider] = Int(clamping: c)
            cost[provider] = cst
        }
        return (rounds, cost)
    }

    /// 最近窗口内的逐次调用样本。`input` 是 uncached input，LocalTokenUsageSample
    /// 需要的完整 input 因此是 `input + cache.read`；promptID 直接复用 assistant
    /// message 的 parentID（通常就是对应 user message）。
    private func querySamples(cutoff: Date?) throws -> [String: [LocalTokenUsageSample]] {
        let sql = """
        SELECT
          id,
          session_id,
          time_created,
          json_extract(data,'$.providerID') AS provider,
          json_extract(data,'$.parentID') AS parent,
          json_extract(data,'$.modelID') AS model,
          json_extract(data,'$.tokens.input') AS tin,
          json_extract(data,'$.tokens.output') AS tout,
          json_extract(data,'$.tokens.reasoning') AS trsn,
          json_extract(data,'$.tokens.cache.read') AS tcr
        FROM message
        WHERE json_extract(data,'$.role')='assistant'
          AND json_extract(data,'$.tokens') IS NOT NULL
          AND json_extract(data,'$.providerID') IS NOT NULL
          AND (
            COALESCE(json_extract(data,'$.tokens.input'),0)
            + COALESCE(json_extract(data,'$.tokens.output'),0)
            + COALESCE(json_extract(data,'$.tokens.reasoning'),0)
            + COALESCE(json_extract(data,'$.tokens.cache.read'),0)
          ) > 0
          AND (? IS NULL OR time_created >= ?)
        ORDER BY time_created, id
        """
        let cutoffMs = cutoff.map { Int64($0.timeIntervalSince1970 * 1000) }
        let rows: [(String, String, Int64, String, String?, String?, Int64, Int64, Int64, Int64)] = try connection.query(
            sql: sql,
            bind: { stmt in
                let first = cutoffMs.map { sqlite3_bind_int64(stmt, 1, $0) } ?? sqlite3_bind_null(stmt, 1)
                guard first == SQLITE_OK else { return first }
                if let cutoffMs { return sqlite3_bind_int64(stmt, 2, cutoffMs) }
                return sqlite3_bind_null(stmt, 2)
            },
            map: { stmt in
                let messageID = try SQLiteConnection.requiredText(stmt, column: 0)
                let sessionID = try SQLiteConnection.requiredText(stmt, column: 1)
                let timestamp = try SQLiteConnection.requiredInt64(stmt, column: 2)
                let provider = try SQLiteConnection.requiredText(stmt, column: 3)
                let parent = SQLiteConnection.optionalText(stmt, column: 4)
                let model = SQLiteConnection.optionalText(stmt, column: 5)
                let input = SQLiteConnection.optionalInt64(stmt, column: 6)
                let output = SQLiteConnection.optionalInt64(stmt, column: 7)
                let reasoning = SQLiteConnection.optionalInt64(stmt, column: 8)
                let cacheRead = SQLiteConnection.optionalInt64(stmt, column: 9)
                return (messageID, sessionID, timestamp, provider, parent, model, input, output, reasoning, cacheRead)
            }
        )

        var samplesByProvider: [String: [LocalTokenUsageSample]] = [:]
        for (messageID, sessionID, timestamp, provider, parent, model, input, output, reasoning, cacheRead) in rows {
            let promptComponent = parent ?? "event-\(messageID)"
            // R9: 读取层非负饱和；input = nn(input) + nn(cacheRead)。
            let inNN = Self.nnClamp(input)
            let crNN = Self.nnClamp(cacheRead)
            // OpenCode raw input is uncached; preserve the sample contract by
            // combining it with cache-read only at this compatibility boundary.
            let sample = LocalTokenUsageSample(
                completedAt: Date(timeIntervalSince1970: Double(timestamp) / 1000),
                modelName: model,
                promptID: "\(sessionID):\(promptComponent)",
                inputTokens: SaturatingArithmetic.add(inNN, crNN),
                cachedInputTokens: crNN,
                outputTokens: Self.nnClamp(output),
                reasoningOutputTokens: Self.nnClamp(reasoning)
            )
            samplesByProvider[provider, default: []].append(sample)
        }
        return samplesByProvider
    }

    /// R9: Int64? → 非负 Int 饱和（NULL 当 0，负值当 0，超出 Int 范围封顶）。
    @inline(__always)
    private static func nnClamp(_ x: Int64?) -> Int {
        let v = Int(clamping: x ?? 0)
        return v < 0 ? 0 : v
    }

    /// per-provider 见过的 modelID（去重）。
    private func queryModels() throws -> [String: [String]] {
        let sql = """
        SELECT DISTINCT
          json_extract(data,'$.providerID') AS provider,
          json_extract(data,'$.modelID') AS model
        FROM message
        WHERE json_extract(data,'$.role')='assistant'
          AND json_extract(data,'$.providerID') IS NOT NULL
        """
        var models: [String: Set<String>] = [:]
        let rows: [(String, String)] = try connection.query(sql: sql) { stmt in
            let provider = try SQLiteConnection.requiredText(stmt, column: 0)
            let model = SQLiteConnection.optionalText(stmt, column: 1) ?? "unknown"
            return (provider, model)
        }
        for (provider, model) in rows {
            models[provider, default: []].insert(model)
        }
        return models.mapValues { $0.sorted() }
    }

    /// 'yyyy-MM-dd' → 本地午夜 Date。
    private static func parseDayKey(_ dayKey: String, calendar: Calendar) -> Date? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
