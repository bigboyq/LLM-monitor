import Foundation
import SQLite3

/// opencode.db 读取结果：per-provider × per-day 的原始聚合，scanner 再聚成 7 天窗口。
struct OpencodeDBAggregate: Equatable, Sendable {
    /// providerID → dayStart → 当日聚合
    let perProviderDay: [String: [Date: OpencodeDailyUsage]]
    /// providerID → 累计、有 token 的 LLM round 数
    let roundCount: [String: Int]
    /// providerID → 见过的 modelID
    let models: [String: [String]]
    /// providerID → 最近窗口内的逐次 assistant 调用
    let samples: [String: [LocalTokenUsageSample]]

    static let empty = OpencodeDBAggregate(
        perProviderDay: [:], roundCount: [:], models: [:], samples: [:]
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
            roundCount: totals,
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
    ///
    /// reasoning 走**三段式**判定，公式与 ZCode 分片 / MiniMax Code runtime / Dsh M3
    /// 同一口径（`ReasoningCharSplit`）：
    /// 1. **native `tokens.reasoning > 0`**：provider 已经把两个桶分开上报，原样沿用
    ///    （native 优先）。OpenCode 对 deepseek / openai / zhipuai 都报真实值
    ///    （实测 deepseek 13 万+、zhipuai 14 万+）。
    /// 2. **否则 + provider 前缀是 `minimax` + 当天 `part` 表里有思考文本**：按字符
    ///    比例分摊 output，见 `queryMinimaxReasoningChars`。只对 minimax 生效是因为
    ///    实测 `message.data.$.tokens.reasoning` 对 `minimax`（7904 条）与
    ///    `minimax-cn-coding-plan`（36 条）**恒 0**，但它们 `part` 表里躺着真思考
    ///    （reasoning part 3860 条、318 万字符）——思考被折进了 output 桶。
    /// 3. **都没有**：保持 `reasoning_tokens = 0`（`ollama-cloud` 等零星行）。
    ///
    /// 分摊守恒（`reasoning + output == 原始 output`），所以 `totalTokens` 重算后
    /// 仍等于原来的 `in + out + rsn + cacheRead`。
    private func queryPerDay(calendar: Calendar) throws -> [String: [Date: OpencodeDailyUsage]] {
        let charsByProviderDay = try queryMinimaxReasoningChars(calendar: calendar)
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
            guard let dayStart = LocalUsageDayKey.parse(dayKey, calendar: calendar) else { continue }
            let inNN = SQLiteConnection.nnClamp(tin)
            let outNN = SQLiteConnection.nnClamp(tout)
            let crNN = SQLiteConnection.nnClamp(tcr)
            let cwNN = SQLiteConnection.nnClamp(tcw)
            let rsnNN = SQLiteConnection.nnClamp(trsn)
            // 三段式 reasoning：native 优先，否则仅对 minimax 前缀用 part 表字符比例
            // 分摊（day 级），都没有则保持 0。分摊守恒，故 total 重算后仍是原值。
            let split = rsnNN > 0 || !Self.needsCharSplit(provider: provider)
                ? nil
                : charsByProviderDay[provider]?[dayStart].flatMap {
                    ReasoningCharSplit.split(
                        outputTokens: outNN,
                        reasoningChars: $0.reasoningChars,
                        visibleChars: $0.visibleChars
                    )
                }
            let reasoningTokens = split?.reasoning ?? rsnNN
            let outputTokens = split?.output ?? outNN
            let usage = OpencodeDailyUsage(
                dayStart: dayStart,
                inputTokens: inNN,
                outputTokens: outputTokens,
                cacheReadTokens: crNN,
                cacheWriteTokens: cwNN,
                reasoningTokens: reasoningTokens,
                totalTokens: SaturatingArithmetic.sum(inNN, outputTokens, reasoningTokens, crNN),
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

    /// 该 provider 是否需要走 `part` 字符分摊（Swift 侧门）。
    ///
    /// SQL 层已用 `LIKE 'minimax%'` 收窄，这里再按小写前缀兜一道：SQLite 的 `LIKE`
    /// 对 ASCII 默认不区分大小写，Swift 侧的 `hasPrefix` 把这条约定显式写死，
    /// 两边门径一致。**只对 minimax 生效**：其余 provider（deepseek / openai /
    /// zhipuai）实测能上报 native reasoning，分摊只会覆盖掉真值。
    private static func needsCharSplit(provider: String) -> Bool {
        provider.lowercased().hasPrefix("minimax")
    }

    /// minimax 前缀 provider 的 per-day 思考/可见字符数（`part` 表）。
    ///
    /// `message.data.$.tokens.reasoning` 对 minimax 系列恒 0，真正的思考文本在
    /// `part` 表（`part.message_id = message.id`，实测 reasoning part 3860 条 /
    /// 318 万字符）。这里按 provider × 本地自然日汇总两类字符数，供 `queryPerDay`
    /// 做 day 级守恒拆分，字符口径与 ZCode 分片完全同款：
    /// - 思考：`type = 'reasoning'` 的 `$.text`。
    /// - 可见输出：`type = 'text'` 的 `$.text` + `type = 'tool'` 的 `$.state.input`
    ///   （opencode.db 实测 tool part 的参数路径与 ZCode 一致，都是 `$.state.input`；
    ///   工具参数同属模型生成输出，对应 MiniMax Code 的 tool_call_args 桶）。
    ///
    /// JOIN 会把一条 message 复制成 N 个 part 行；因为只累加字符数、不累加 token，
    /// 复制不影响结果。无 part 的 message JOIN 不上，自然不出现在结果里
    /// （无思考数据可分摊，保持 reasoning = 0）。`json_valid` 守卫防止脏 data
    /// 让 `json_extract` 抛错，`COALESCE` 保证 LENGTH 不为 NULL。
    /// 极老版本库缺 `part` 表时整表降级为空（见函数体首行守卫）。
    private func queryMinimaxReasoningChars(
        calendar: Calendar
    ) throws -> [String: [Date: (reasoningChars: Int, visibleChars: Int)]] {
        guard try partTableExists() else { return [:] }
        let sql = """
        SELECT
          json_extract(m.data,'$.providerID') AS provider,
          strftime('%Y-%m-%d', m.time_created/1000,'unixepoch','localtime') AS day,
          SUM(CASE WHEN json_extract(
                 CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.type') = 'reasoning'
            THEN LENGTH(COALESCE(json_extract(
                 CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.text'), ''))
            ELSE 0 END) AS rchars,
          SUM(CASE WHEN json_extract(
                 CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.type') = 'text'
            THEN LENGTH(COALESCE(json_extract(
                 CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.text'), ''))
            ELSE 0 END)
          + SUM(CASE WHEN json_extract(
                 CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.type') = 'tool'
            THEN LENGTH(COALESCE(json_extract(
                 CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.state.input'), ''))
            ELSE 0 END) AS vchars
        FROM message m
        JOIN part p ON p.message_id = m.id
        WHERE json_extract(m.data,'$.role') = 'assistant'
          AND json_extract(m.data,'$.tokens') IS NOT NULL
          AND json_extract(m.data,'$.providerID') LIKE 'minimax%'
        GROUP BY provider, day
        """
        var out: [String: [Date: (reasoningChars: Int, visibleChars: Int)]] = [:]
        let rows: [(String, String, Int64, Int64)] = try connection.query(sql: sql) { stmt in
            let provider = try SQLiteConnection.requiredText(stmt, column: 0)
            let dayKey = try SQLiteConnection.requiredText(stmt, column: 1)
            let reasoningChars = SQLiteConnection.optionalInt64(stmt, column: 2)
            let visibleChars = SQLiteConnection.optionalInt64(stmt, column: 3)
            return (provider, dayKey, reasoningChars, visibleChars)
        }
        for (provider, dayKey, reasoningChars, visibleChars) in rows {
            guard let dayStart = LocalUsageDayKey.parse(dayKey, calendar: calendar) else { continue }
            var byDay = out[provider] ?? [:]
            let existing = byDay[dayStart] ?? (reasoningChars: 0, visibleChars: 0)
            byDay[dayStart] = (
                reasoningChars: SaturatingArithmetic.add(
                    existing.reasoningChars, SQLiteConnection.nnClamp(reasoningChars)
                ),
                visibleChars: SaturatingArithmetic.add(
                    existing.visibleChars, SQLiteConnection.nnClamp(visibleChars)
                )
            )
            out[provider] = byDay
        }
        return out
    }

    /// 极老版本 opencode.db 可能没有 `part` 表（本 reader 此前从不依赖它）。
    /// 所有字符分摊入口在缺表时降级为「无字符数据」（reasoning 保持 0），不能让
    /// 整条 OpenCode 链路的聚合跟着失败——样本 SQL 的相关子查询在 prepare 阶段
    /// 就会因引用不存在的表而报错，必须在拼 SQL 前判断。
    private func partTableExists() throws -> Bool {
        let rows: [Int64] = try connection.query(
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'part'"
        ) { stmt in
            try SQLiteConnection.requiredInt64(stmt, column: 0)
        }
        return (rows.first ?? 0) > 0
    }

    private func queryTotals() throws -> [String: Int] {
        let sql = """
        SELECT
          json_extract(data,'$.providerID') AS provider,
          COUNT(*) AS calls
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
        let rows: [(String, Int64)] = try connection.query(sql: sql) { stmt in
            let provider = try SQLiteConnection.requiredText(stmt, column: 0)
            let c = try SQLiteConnection.requiredInt64(stmt, column: 1)
            return (provider, c)
        }
        for (provider, c) in rows {
            rounds[provider] = Int(clamping: c)
        }
        return rounds
    }

    /// 最近窗口内的逐次调用样本。`input` 是 uncached input，LocalTokenUsageSample
    /// 需要的完整 input 因此是 `input + cache.read`；promptID 直接复用 assistant
    /// message 的 parentID（通常就是对应 user message）。
    ///
    /// reasoning 与 `queryPerDay` 同一三段式口径，但粒度更细（**行级**分摊）：
    /// native `tokens.reasoning > 0` 原样透传；否则**仅 minimax 前缀**按本行
    /// message 的 `part` 字符比例分摊（两个相关子查询取本行 part 字符数，无 part 时
    /// 自然得 0 → 保持 reasoning = 0）。分摊后的 (output, reasoning) 作为
    /// `rawOutput` / `rawReasoning` 交给 `TokenAccountingCatalog.opencode` 的
    /// `.independent` 桶（reasoning 是独立桶、不做扣减），守恒由
    /// `ReasoningCharSplit` 保证。极老版本库缺 `part` 表时两列降级为常量 0
    /// （见函数体首部），聚合不失败。
    private func querySamples(cutoff: Date?) throws -> [String: [LocalTokenUsageSample]] {
        // 缺 part 表（极老版本）时相关子查询在 prepare 阶段就会因引用不存在的表
        // 而失败：把两列降级为常量 0，列位与映射代码不变，分摊自然走 nil → 原样。
        let rcharsSelect: String
        let vcharsSelect: String
        if try partTableExists() {
            rcharsSelect = """
              COALESCE((
                SELECT SUM(LENGTH(COALESCE(json_extract(
                  CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.text'), '')))
                FROM part p
                WHERE p.message_id = m.id
                  AND json_extract(
                    CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.type') = 'reasoning'
              ), 0)
              """
            vcharsSelect = """
              COALESCE((
                SELECT SUM(
                  CASE WHEN json_extract(
                    CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.type') = 'text'
                  THEN LENGTH(COALESCE(json_extract(
                    CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.text'), ''))
                  ELSE 0 END
                  + CASE WHEN json_extract(
                    CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.type') = 'tool'
                  THEN LENGTH(COALESCE(json_extract(
                    CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.state.input'), ''))
                  ELSE 0 END
                )
                FROM part p
                WHERE p.message_id = m.id
              ), 0)
              """
        } else {
            rcharsSelect = "0"
            vcharsSelect = "0"
        }
        let sql = """
        SELECT
          m.id,
          m.session_id,
          m.time_created,
          json_extract(m.data,'$.providerID') AS provider,
          json_extract(m.data,'$.parentID') AS parent,
          json_extract(m.data,'$.modelID') AS model,
          json_extract(m.data,'$.tokens.input') AS tin,
          json_extract(m.data,'$.tokens.output') AS tout,
          json_extract(m.data,'$.tokens.reasoning') AS trsn,
          json_extract(m.data,'$.tokens.cache.read') AS tcr,
          \(rcharsSelect) AS rchars,
          \(vcharsSelect) AS vchars
        FROM message m
        WHERE json_extract(m.data,'$.role')='assistant'
          AND json_extract(m.data,'$.tokens') IS NOT NULL
          AND json_extract(m.data,'$.providerID') IS NOT NULL
          AND (
            COALESCE(json_extract(m.data,'$.tokens.input'),0)
            + COALESCE(json_extract(m.data,'$.tokens.output'),0)
            + COALESCE(json_extract(m.data,'$.tokens.reasoning'),0)
            + COALESCE(json_extract(m.data,'$.tokens.cache.read'),0)
          ) > 0
          AND (? IS NULL OR m.time_created >= ?)
        ORDER BY m.time_created, m.id
        """
        let cutoffMs = cutoff.map { Int64($0.timeIntervalSince1970 * 1000) }
        let rows: [(String, String, Int64, String, String?, String?, Int64, Int64, Int64, Int64, Int64, Int64)] = try connection.query(
            sql: sql,
            bind: SQLiteConnection.bindNullableMsCutoff(cutoffMs, startingAt: 1),
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
                let reasoningChars = SQLiteConnection.optionalInt64(stmt, column: 10)
                let visibleChars = SQLiteConnection.optionalInt64(stmt, column: 11)
                return (
                    messageID, sessionID, timestamp, provider, parent, model, input, output, reasoning,
                    cacheRead, reasoningChars, visibleChars
                )
            }
        )

        var samplesByProvider: [String: [LocalTokenUsageSample]] = [:]
        for (messageID, sessionID, timestamp, provider, parent, model, input, output, reasoning, cacheRead,
             reasoningChars, visibleChars) in rows {
            let promptComponent = parent ?? "event-\(messageID)"
            // R9: 读取层非负饱和；raw→桶转换统一走 TokenAccountingCatalog。
            let inNN = SQLiteConnection.nnClamp(input)
            let crNN = SQLiteConnection.nnClamp(cacheRead)
            // 行级三段式 reasoning：native 优先，否则仅 minimax 前缀按本行 part 字符
            // 比例分摊（守恒：reasoning + output == 原始 output）。
            let nativeReasoning = SQLiteConnection.nnClamp(reasoning)
            let nativeOutput = SQLiteConnection.nnClamp(output)
            let split: (reasoning: Int, output: Int)?
            if nativeReasoning > 0 || !Self.needsCharSplit(provider: provider) {
                split = nil
            } else {
                split = ReasoningCharSplit.split(
                    outputTokens: nativeOutput,
                    reasoningChars: SQLiteConnection.nnClamp(reasoningChars),
                    visibleChars: SQLiteConnection.nnClamp(visibleChars)
                )
            }
            // OpenCode raw input is uncached; route the raw counters through the
            // harness catalog and rebuild the legacy cache-inclusive sample
            // contract only at this compatibility boundary.
            let buckets = TokenAccountingCatalog.opencode.normalizedBuckets(
                rawInput: inNN,
                cacheRead: crNN,
                rawOutput: split?.output ?? nativeOutput,
                rawReasoning: split?.reasoning ?? nativeReasoning
            )
            let sample = LocalTokenUsageSample(
                completedAt: Date(timeIntervalSince1970: Double(timestamp) / 1000),
                modelName: model,
                promptID: "\(sessionID):\(promptComponent)",
                inputTokens: buckets.cacheInclusiveInput,
                cachedInputTokens: buckets.cacheRead,
                outputTokens: buckets.output,
                reasoningOutputTokens: buckets.reasoning
            )
            samplesByProvider[provider, default: []].append(sample)
        }
        return samplesByProvider
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
}
