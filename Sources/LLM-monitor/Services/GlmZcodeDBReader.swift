import Foundation
import SQLite3

/// ZCode 库中**非智谱** provider（`ZcodeProviderSlice`）的原始聚合，结构与
/// `OpencodeDBAggregate` 同构：一份 DB 按 provider 切片，供 scanner 再压成 7 天窗口。
struct ZcodeProviderSliceAggregate: Equatable, Sendable {
    /// `ZcodeProviderSlice.rawValue` → dayStart → 当日聚合
    let perSliceDay: [String: [Date: OpencodeDailyUsage]]
    /// 分片 → 累计、有 token 的 LLM round 数
    let roundCount: [String: Int]
    /// 分片 → 见过的 modelID（去重）
    let models: [String: [String]]
    /// 分片 → 最近窗口内的逐次模型调用
    let samples: [String: [LocalTokenUsageSample]]

    static let empty = ZcodeProviderSliceAggregate(
        perSliceDay: [:], roundCount: [:], models: [:], samples: [:]
    )
}

/// ZCode `model_usage` 聚合结果：per-day token + 累计 + samples + 见过的 model + session 数。
/// reasoning 归类与分片统一走 `ReasoningCharSplit` 字符分摊：日聚合在 `queryPerDay`
/// 按 day 分摊、样本在 `querySamples` 按行分摊，native `reasoning_tokens > 0` 时
/// 账单值优先透传——reader 输出的 `GlmDailyUsage.reasoningTokens` 已经是最终值，
/// scanner 直接用。
struct GlmZcodeDBAggregate: Equatable, Sendable {
    /// dayStart → 当日聚合（reasoning 已经按字符分摊归类，outputTokens/reasoningTokens 都是最终值）
    let perDay: [Date: GlmDailyUsage]
    /// 累计、有 token 的 LLM round 数（= COUNT(*)）
    let roundCount: Int
    /// 见过的 modelID（去重）
    let models: [String]
    /// 去重 session_id 数
    let sessionCount: Int
    /// 最近窗口内的逐次模型调用（reader 直接输出分摊后的 realOutput/reasoningOutput）
    let samples: [LocalTokenUsageSample]
    /// 非智谱 provider 分片（`minimax` / `deepseek`）的原始聚合。智谱系行不进这里，
    /// 两者按 `ZcodeProviderSlice` 前缀谓词互斥切分。
    let providerSlices: ZcodeProviderSliceAggregate

    static let empty = GlmZcodeDBAggregate(
        perDay: [:], roundCount: 0, models: [], sessionCount: 0, samples: [],
        providerSlices: .empty
    )
}

/// 读 ZCode 的 `~/.zcode/cli/db/db.sqlite` `model_usage` 表。
///
/// 每行 = 一次模型请求。查询是 GLM 家族超集过滤：`builtin:bigmodel-%` /
/// `account:bigmodel-%` / `account:zai-%` 前缀通配 + 迁移前历史裸值
/// `offpeak-idle-plan` 精确匹配，行上带 `provider_id` + `model_id`
/// （如 GLM-5.3 / GLM-5.3-Flash）+ 5 类 token 列 + 原生 `turn_id`，查询拿到
/// per-day 5 类 token、round/turn、recent samples、totals + models + sessions。
///
/// **provider 三分类**（sample 保留 `provider_id`，按 `OpencodeLocalUsage` 的
/// 显式枚举集合在 `LocalUsageSummaryBuilder` 白名单层判定）：
/// - 正式 Coding Plan（`zcodeGlmCodingPlanProviderIDs` 显式全集）
///   → 正常任务（唯一计入额度窗口的来源）
/// - 闲时（`zcodeOffPeakProviderIDs`：账号化新 ID 经前缀 LIKE 读入，历史裸值
///   `offpeak-idle-plan` 经精确匹配读入）→ 闲时任务
/// - 智谱前缀下未登记进上述两集合的 provider（体验套餐、未知新套餐）→
///   其他任务；非智谱 provider 不带前缀、不会被误算进 GLM 卡
///
/// 直接 read 原 .db；CANTOPEN / BUSY 时由调用方（`SQLiteTempCopy.read`）走 /tmp 副本。
///
/// **多 provider 账本**：除上面的智谱系行外，同表还有用户自带的非智谱 provider 行
/// （`minimax` / `deepseek`）。它们由 `ZcodeProviderSlice` 前缀谓词单独读入
/// `providerSlices`（per-slice × per-day 聚合 + 累计 rounds + models + samples），
/// 与智谱行互斥：两组谓词都不带 `%` 之外的模糊匹配，不会互相吞行。
final class GlmZcodeDBReader {
    /// ZCode 中闲时任务（off-peak idle task）的 provider_id —— 仅 0020 迁移前的
    /// 历史裸值。迁移后的新 ID（`account:bigmodel-offpeak-idle-plan` /
    /// `account:zai-offpeak-idle-plan`）由智谱前缀 LIKE 覆盖读入，分类在 sample
    /// 层由 `OpencodeLocalUsage.isZcodeOffPeakProvider` 判定。闲时任务是系统赠送
    /// 的后台任务，不消耗 Coding Plan 积分，`model_usage` 行写在同一张表但用独立
    /// provider 区分。今日 / 7 天柱图要包含其真实 token 消耗，额度窗口统计优先靠
    /// sample 保存的 provider 身份精确排除；时间窗口只用于兼容旧缓存。
    static let offPeakProviderID = "offpeak-idle-plan"

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
        let providerSlices = try aggregateProviderSlices(calendar: calendar, cutoff: sampleCutoff)

        return GlmZcodeDBAggregate(
            perDay: perDay,
            roundCount: totals.roundCount,
            models: models,
            sessionCount: totals.sessionCount,
            samples: samples,
            providerSlices: providerSlices
        )
    }

    /// 非智谱 provider 分片（`ZcodeProviderSlice`）的原始聚合。与智谱查询走同一张
    /// `model_usage` 表，但谓词换成切片前缀 LIKE —— 一次扫描产出 GLM 卡 + 智谱以外
    /// 各卡的原料，不需要第二个 scanner / 第二次开库。
    private func aggregateProviderSlices(
        calendar: Calendar,
        cutoff: Date?
    ) throws -> ZcodeProviderSliceAggregate {
        let perSliceDay = try querySlicePerDay(calendar: calendar, cutoff: cutoff)
        let roundCount = try querySliceTotals()
        let models = try querySliceModels()
        let samples = try querySliceSamples(cutoff: cutoff)
        return ZcodeProviderSliceAggregate(
            perSliceDay: perSliceDay,
            roundCount: roundCount,
            models: models,
            samples: samples
        )
    }

    // MARK: - queries

    /// per-day token 聚合。GLM 行按
    /// `strftime('%Y-%m-%d', started_at/1000,'unixepoch','localtime')` 归到本地自然日。
    /// rounds = `COUNT(*)`，turns = `COUNT(DISTINCT turn_id)`。
    ///
    /// **reasoning 归类（与分片 `querySlicePerDay` 同一日级架构）**：SQL 只做原始
    /// 列求和，归类在 Swift 侧按 day 完成——
    /// 1. 当日 `reasoning_tokens` 列全和 > 0（native priority）: 账单已分好两个桶，
    ///    整日照账单值透传，不做分摊；
    /// 2. 否则用 `queryReasoningChars` 的当日思考/可见字符数走 `ReasoningCharSplit`
    ///    日级守恒分摊（reasoning + output == 当日 output_tokens）;
    /// 3. 都没有（无 part / 无思考字符）: reasoning 保持 0。
    ///
    /// 2026-11-08 实测依据：智谱行原生 `reasoning_tokens` 列 0 行有值，旧 Method A
    /// 的 priority path 从不触发，9,824 次有思考的调用全部整轮 `output_tokens` 归
    /// reasoning、可见输出清零；而思考行 100%（2019/2019）同时有可见 text 块，H1
    /// 字符/token 检验判定 `output_tokens` 含思考——整轮归类系统性清零真实可见输出，
    /// 故与分片统一改为字符分摊。reader 输出的 `GlmDailyUsage.reasoningTokens`
    /// 已经是最终值,scanner 无需再分摊。
    private func queryPerDay(calendar: Calendar, cutoff: Date?) throws -> [Date: GlmDailyUsage] {
        let charsByDay = try queryReasoningChars(calendar: calendar, cutoff: cutoff)
        let sql = """
        SELECT
          strftime('%Y-%m-%d', mu.started_at/1000,'unixepoch','localtime') AS day,
          COUNT(*) AS rounds,
          COUNT(DISTINCT mu.turn_id) AS turns,
          SUM(MAX(COALESCE(mu.input_tokens, 0), 0)) AS tin,
          SUM(MAX(COALESCE(mu.output_tokens, 0), 0)) AS tout,
          SUM(MAX(COALESCE(mu.reasoning_tokens, 0), 0)) AS trsn,
          SUM(MAX(COALESCE(mu.cache_read_input_tokens, 0), 0)) AS tcr,
          SUM(MAX(COALESCE(mu.cache_creation_input_tokens, 0), 0)) AS tcw
        FROM model_usage mu
        WHERE \(Self.providerFilterSQL("mu.provider_id"))
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
                return SQLiteConnection.bindNullableMsCutoff(cutoffMs, startingAt: 1 + Self.providerFilterParameterCount)(stmt)
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
            guard let dayStart = LocalUsageDayKey.parse(dayKey, calendar: calendar) else { continue }
            // R9: 读取层再做非负饱和（单行 MAX 已在 SQL 内 clamp，这里作第二层防御）。
            let toutNN = SQLiteConnection.nnClamp(tout)
            let trsnNN = SQLiteConnection.nnClamp(trsn)
            let tcrNN = SQLiteConnection.nnClamp(tcr)
            let tcwNN = SQLiteConnection.nnClamp(tcw)
            // 三段式 reasoning（与分片 querySlicePerDay 同架构）：native 列全和 > 0
            // 的日子按账单值优先；否则按当日 part 字符比例分摊（守恒：reasoning +
            // output == 当日 output_tokens）；都没有则保持 0。
            let split = trsnNN > 0
                ? nil
                : charsByDay[dayStart].flatMap {
                    ReasoningCharSplit.split(
                        outputTokens: toutNN,
                        reasoningChars: $0.reasoningChars,
                        visibleChars: $0.visibleChars
                    )
                }
            let buckets = TokenAccountingCatalog.zcode.normalizedBuckets(
                rawInput: Int(clamping: tin),
                cacheRead: tcrNN,
                rawOutput: split?.output ?? toutNN,
                rawReasoning: split?.reasoning ?? trsnNN
            )
            let usage = GlmDailyUsage(
                dayStart: dayStart,
                inputTokens: buckets.input,
                outputTokens: buckets.output,
                cacheReadTokens: buckets.cacheRead,
                cacheWriteTokens: tcwNN,
                reasoningTokens: buckets.reasoning,
                totalTokens: buckets.totalTokens,
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

    /// 智谱行 × per-day 的思考/可见字符数（`part` 表）。公式与 `querySliceReasoningChars`
    /// 逐字同源，仅 provider 谓词换成智谱前缀（含历史裸值闲时精确匹配）：
    /// - 思考：`type = 'reasoning'` 的 `$.text`。
    /// - 可见输出：`type = 'text'` 的 `$.text` + `type = 'tool'` 的 `$.state.input`。
    ///
    /// JOIN 会把一条 `model_usage` 行复制成 N 个 part 行；因为只累加字符数、不
    /// 累加 token，复制不影响结果。`assistant_message_id` 为 NULL 的行 JOIN 不上，
    /// 自然不出现在结果里（无思考数据可分摊，保持 reasoning = 0）。
    private func queryReasoningChars(
        calendar: Calendar,
        cutoff: Date?
    ) throws -> [Date: (reasoningChars: Int, visibleChars: Int)] {
        let sql = """
        SELECT
          strftime('%Y-%m-%d', mu.started_at/1000,'unixepoch','localtime') AS day,
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
        FROM model_usage mu
        JOIN part p ON p.message_id = mu.assistant_message_id
        WHERE \(Self.providerFilterSQL("mu.provider_id"))
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
        let rows: [(String, Int64, Int64)] = try connection.query(
            sql: sql,
            bind: { stmt in
                let provider = Self.bindProviders(to: stmt, index: 1)
                guard provider == SQLITE_OK else { return provider }
                return SQLiteConnection.bindNullableMsCutoff(
                    cutoffMs, startingAt: 1 + Self.providerFilterParameterCount
                )(stmt)
            },
            map: { stmt in
            let dayKey = try SQLiteConnection.requiredText(stmt, column: 0)
            let reasoningChars = SQLiteConnection.optionalInt64(stmt, column: 1)
            let visibleChars = SQLiteConnection.optionalInt64(stmt, column: 2)
            return (dayKey, reasoningChars, visibleChars)
            }
        )
        var out: [Date: (reasoningChars: Int, visibleChars: Int)] = [:]
        for (dayKey, reasoningChars, visibleChars) in rows {
            guard let dayStart = LocalUsageDayKey.parse(dayKey, calendar: calendar) else { continue }
            let existing = out[dayStart] ?? (reasoningChars: 0, visibleChars: 0)
            out[dayStart] = (
                reasoningChars: SaturatingArithmetic.add(
                    existing.reasoningChars, SQLiteConnection.nnClamp(reasoningChars)
                ),
                visibleChars: SaturatingArithmetic.add(
                    existing.visibleChars, SQLiteConnection.nnClamp(visibleChars)
                )
            )
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
        WHERE \(Self.providerFilterSQL("provider_id"))
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
    ///
    /// reasoning 与日聚合同公式但粒度更细（与分片 `querySliceSamples` 同架构）：
    /// native `reasoning_tokens > 0` 原样透传（priority path，未来上游真给值时零改动）；
    /// 否则按**行级**字符比例分摊——两个相关子查询取本行 `assistant_message_id` 的
    /// part 字符数（公式与 `querySliceSamples` 逐字同源），无 part 时自然得 0 →
    /// 保持 reasoning = 0。行级与日级都是守恒拆分：reasoning + output == 原始
    /// output_tokens。
    private func querySamples(cutoff: Date?) throws -> [LocalTokenUsageSample] {
        let sql = """
        SELECT
          mu.id,
          mu.session_id,
          mu.started_at,
          mu.turn_id,
          mu.model_id,
          mu.input_tokens,
          mu.output_tokens,
          mu.reasoning_tokens,
          mu.cache_read_input_tokens,
          COALESCE((
            SELECT SUM(LENGTH(COALESCE(json_extract(
              CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.text'), '')))
            FROM part p
            WHERE p.message_id = mu.assistant_message_id
              AND json_extract(
                CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.type') = 'reasoning'
          ), 0) AS reasoning_chars,
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
            WHERE p.message_id = mu.assistant_message_id
          ), 0) AS visible_chars,
          mu.provider_id,
          mu.duration_ms,
          mu.time_to_first_token_ms
        FROM model_usage mu
        WHERE \(Self.providerFilterSQL("mu.provider_id"))
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
        let rows: [(String, String, Int64, String?, String?, Int64, Int64, Int64, Int64, Int64, Int64, String, Int64?, Int64?)] = try connection.query(
            sql: sql,
            bind: { stmt in
                let provider = Self.bindProviders(to: stmt, index: 1)
                guard provider == SQLITE_OK else { return provider }
                return SQLiteConnection.bindNullableMsCutoff(cutoffMs, startingAt: 1 + Self.providerFilterParameterCount)(stmt)
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
                let reasoningChars = SQLiteConnection.optionalInt64(stmt, column: 9)
                let visibleChars = SQLiteConnection.optionalInt64(stmt, column: 10)
                let providerID = try SQLiteConnection.requiredText(stmt, column: 11)
                let durationMs = SQLiteConnection.optionalInt64(stmt, column: 12)
                let ttftMs = Self.optionalInt64OrNull(stmt, column: 13)
                return (id, sessionID, timestamp, turn, model, input, output, reasoning, cacheRead, reasoningChars, visibleChars, providerID, durationMs, ttftMs)
            }
        )

        var samples: [LocalTokenUsageSample] = []
        for (id, sessionID, timestamp, turn, model, input, output, reasoning, cacheRead, reasoningChars, visibleChars, providerID, durationMs, ttftMs) in rows {
            let promptComponent = turn ?? "event-\(id)"
            // R9: 读取层非负饱和；input 用 nn(input)，cachedInput 用 nn(cacheRead)。
            let inNN = SQLiteConnection.nnClamp(input)
            let crNN = SQLiteConnection.nnClamp(cacheRead)
            // ZCode raw input is cache-inclusive. Native reasoning passes through
            // as billed; otherwise output/reasoning are split by char proportion
            // above. Do not subtract cache or split reasoning again downstream.
            let nativeReasoning = SQLiteConnection.nnClamp(reasoning)
            let nativeOutput = SQLiteConnection.nnClamp(output)
            let split: (reasoning: Int, output: Int)?
            if nativeReasoning > 0 {
                split = nil
            } else {
                split = ReasoningCharSplit.split(
                    outputTokens: nativeOutput,
                    reasoningChars: SQLiteConnection.nnClamp(reasoningChars),
                    visibleChars: SQLiteConnection.nnClamp(visibleChars)
                )
            }
            let sample = LocalTokenUsageSample(
                completedAt: Date(timeIntervalSince1970: Double(timestamp) / 1000),
                modelName: model,
                promptID: "\(sessionID):\(promptComponent)",
                inputTokens: inNN,
                cachedInputTokens: crNN,
                outputTokens: split?.output ?? nativeOutput,
                reasoningOutputTokens: split?.reasoning ?? nativeReasoning,
                sourceProviderID: providerID,
                durationSeconds: durationMs.flatMap { $0 > 0 && $0 <= 3_600_000 ? Double($0) / 1000.0 : nil },
                // 原生逐调用 TTFT 列（实测约 71% 行有值，缺口视为未提供）；这里只做
                // ms → 秒换算与非法值剔除（负/缺失 → nil），范围过滤交给聚合层。
                ttftSeconds: ttftMs.flatMap { $0 >= 0 ? Double($0) / 1000.0 : nil }
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
        WHERE \(Self.providerFilterSQL("provider_id"))
          AND model_id IS NOT NULL
        """
        let rows: [String] = try connection.query(sql: sql, bind: { stmt in
            Self.bindProviders(to: stmt, index: 1)
        }) { stmt in
            try SQLiteConnection.requiredText(stmt, column: 0)
        }
        return rows.sorted()
    }

    // MARK: - 非智谱 provider 分片（ZcodeProviderSlice）

    /// 分片 × per-day token 聚合。
    ///
    /// 与智谱查询的结构差异只有 provider 谓词（切片前缀），其余口径同源。reasoning
    /// 走**三段式**判定（与 `TokenAccountingCatalog.zcode` 的 `.normalized` 对齐）：
    /// 1. **native `reasoning_tokens > 0`**：账单已分好两个桶，原样沿用（native 优先）。
    /// 2. **否则 + 该 slice/day 在 `part` 表里有思考文本**：按字符比例分摊 output，
    ///    见 `querySliceReasoningChars` 与 `ReasoningCharSplit`。一轮里思考与正文
    ///    混在同一 message，整轮归类会清零真实可见输出，比例必须按字符算——
    ///    与智谱主卡、MiniMax Code runtime / Dsh M3 同一口径。
    /// 3. **都没有**：保持 `reasoning_tokens = 0`。
    ///
    /// input 口径：ZCode 的 input 是 cache-inclusive，`uncached = max(input - cacheRead, 0)`，
    /// `total = uncached + cacheRead + output + reasoning`（分摊后重算，守恒）。
    private func querySlicePerDay(
        calendar: Calendar,
        cutoff: Date?
    ) throws -> [String: [Date: OpencodeDailyUsage]] {
        let charsBySliceDay = try querySliceReasoningChars(calendar: calendar, cutoff: cutoff)
        let sql = """
        SELECT
          provider_id,
          strftime('%Y-%m-%d', started_at/1000,'unixepoch','localtime') AS day,
          COUNT(*) AS rounds,
          COUNT(DISTINCT turn_id) AS turns,
          SUM(MAX(COALESCE(input_tokens, 0), 0)) AS tin,
          SUM(MAX(COALESCE(output_tokens, 0), 0)) AS tout,
          SUM(MAX(COALESCE(reasoning_tokens, 0), 0)) AS trsn,
          SUM(MAX(COALESCE(cache_read_input_tokens, 0), 0)) AS tcr,
          SUM(MAX(COALESCE(cache_creation_input_tokens, 0), 0)) AS tcw
        FROM model_usage
        WHERE \(Self.sliceFilterSQL("provider_id"))
          AND status = 'completed'
          AND (
            COALESCE(input_tokens,0)
            + COALESCE(output_tokens,0)
            + COALESCE(reasoning_tokens,0)
            + COALESCE(cache_read_input_tokens,0)
          ) > 0
          AND (? IS NULL OR started_at >= ?)
        GROUP BY provider_id, day
        """
        let cutoffMs = cutoff.map { Int64($0.timeIntervalSince1970 * 1000) }
        let rows: [(String, String, Int64, Int64, Int64, Int64, Int64, Int64, Int64)] = try connection.query(
            sql: sql,
            bind: { stmt in
                let provider = Self.bindSlices(to: stmt, index: 1)
                guard provider == SQLITE_OK else { return provider }
                return SQLiteConnection.bindNullableMsCutoff(
                    cutoffMs, startingAt: 1 + Self.sliceFilterParameterCount
                )(stmt)
            },
            map: { stmt in
            let providerID = try SQLiteConnection.requiredText(stmt, column: 0)
            let dayKey = try SQLiteConnection.requiredText(stmt, column: 1)
            let rounds = try SQLiteConnection.requiredInt64(stmt, column: 2)
            let turns = try SQLiteConnection.requiredInt64(stmt, column: 3)
            let tin = SQLiteConnection.optionalInt64(stmt, column: 4)
            let tout = SQLiteConnection.optionalInt64(stmt, column: 5)
            let trsn = SQLiteConnection.optionalInt64(stmt, column: 6)
            let tcr = SQLiteConnection.optionalInt64(stmt, column: 7)
            let tcw = SQLiteConnection.optionalInt64(stmt, column: 8)
            return (providerID, dayKey, rounds, turns, tin, tout, trsn, tcr, tcw)
            }
        )
        var out: [String: [Date: OpencodeDailyUsage]] = [:]
        for (providerID, dayKey, rounds, turns, tin, tout, trsn, tcr, tcw) in rows {
            guard let slice = ZcodeProviderSlice(providerID: providerID),
                  let dayStart = LocalUsageDayKey.parse(dayKey, calendar: calendar) else { continue }
            let toutNN = SQLiteConnection.nnClamp(tout)
            let trsnNN = SQLiteConnection.nnClamp(trsn)
            let tcrNN = SQLiteConnection.nnClamp(tcr)
            let tcwNN = SQLiteConnection.nnClamp(tcw)
            // 三段式 reasoning：native 优先，否则用 part 表字符比例分摊（day 级），
            // 都没有则保持 0。分摊守恒，故 total 重算后仍是 input+cacheRead+output。
            let split = trsnNN > 0
                ? nil
                : charsBySliceDay[slice.rawValue]?[dayStart].flatMap {
                    ReasoningCharSplit.split(
                        outputTokens: toutNN,
                        reasoningChars: $0.reasoningChars,
                        visibleChars: $0.visibleChars
                    )
                }
            let rawReasoning = split?.reasoning ?? trsnNN
            let rawOutput = split?.output ?? toutNN
            let buckets = TokenAccountingCatalog.zcode.normalizedBuckets(
                rawInput: Int(clamping: tin),
                cacheRead: tcrNN,
                rawOutput: rawOutput,
                rawReasoning: rawReasoning
            )
            let usage = OpencodeDailyUsage(
                dayStart: dayStart,
                inputTokens: buckets.input,
                outputTokens: buckets.output,
                cacheReadTokens: buckets.cacheRead,
                cacheWriteTokens: tcwNN,
                reasoningTokens: buckets.reasoning,
                totalTokens: buckets.totalTokens,
                turns: max(0, Int(clamping: turns)),
                rounds: max(0, Int(clamping: rounds))
            )
            var byDay = out[slice.rawValue] ?? [:]
            byDay[dayStart] = byDay[dayStart].map { $0 + usage } ?? usage
            out[slice.rawValue] = byDay
        }
        return out
    }

    /// 分片 × per-day 的思考/可见字符数（`part` 表）。
    ///
    /// ZCode 账本 `model_usage.reasoning_tokens` 对所有 provider 恒 0，真正的思考
    /// 文本在 `part` 表（`model_usage.assistant_message_id` → `part.message_id`）。
    /// 这里按 provider × 本地自然日汇总两类字符数，供 `querySlicePerDay` 做
    /// day 级守恒拆分（公式与 MiniMax Code runtime / Dsh M3 同一口径）：
    /// - 思考：`type = 'reasoning'` 的 `$.text`。
    /// - 可见输出：`type = 'text'` 的 `$.text` + `type = 'tool'` 的 `$.state.input`
    ///   （工具参数同属模型生成输出，对应 MiniMax Code 的 tool_call_args 桶）。
    ///
    /// JOIN 会把一条 `model_usage` 行复制成 N 个 part 行；因为只累加字符数、不
    /// 累加 token，复制不影响结果。`assistant_message_id` 为 NULL 的行 JOIN 不上，
    /// 自然不出现在结果里（无思考数据可分摊，保持 reasoning = 0）。
    private func querySliceReasoningChars(
        calendar: Calendar,
        cutoff: Date?
    ) throws -> [String: [Date: (reasoningChars: Int, visibleChars: Int)]] {
        let sql = """
        SELECT
          mu.provider_id,
          strftime('%Y-%m-%d', mu.started_at/1000,'unixepoch','localtime') AS day,
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
        FROM model_usage mu
        JOIN part p ON p.message_id = mu.assistant_message_id
        WHERE \(Self.sliceFilterSQL("mu.provider_id"))
          AND mu.status = 'completed'
          AND (
            COALESCE(mu.input_tokens,0)
            + COALESCE(mu.output_tokens,0)
            + COALESCE(mu.reasoning_tokens,0)
            + COALESCE(mu.cache_read_input_tokens,0)
          ) > 0
          AND (? IS NULL OR mu.started_at >= ?)
        GROUP BY mu.provider_id, day
        """
        let cutoffMs = cutoff.map { Int64($0.timeIntervalSince1970 * 1000) }
        let rows: [(String, String, Int64, Int64)] = try connection.query(
            sql: sql,
            bind: { stmt in
                let provider = Self.bindSlices(to: stmt, index: 1)
                guard provider == SQLITE_OK else { return provider }
                return SQLiteConnection.bindNullableMsCutoff(
                    cutoffMs, startingAt: 1 + Self.sliceFilterParameterCount
                )(stmt)
            },
            map: { stmt in
            let providerID = try SQLiteConnection.requiredText(stmt, column: 0)
            let dayKey = try SQLiteConnection.requiredText(stmt, column: 1)
            let reasoningChars = SQLiteConnection.optionalInt64(stmt, column: 2)
            let visibleChars = SQLiteConnection.optionalInt64(stmt, column: 3)
            return (providerID, dayKey, reasoningChars, visibleChars)
            }
        )
        var out: [String: [Date: (reasoningChars: Int, visibleChars: Int)]] = [:]
        for (providerID, dayKey, reasoningChars, visibleChars) in rows {
            guard let slice = ZcodeProviderSlice(providerID: providerID),
                  let dayStart = LocalUsageDayKey.parse(dayKey, calendar: calendar) else { continue }
            var byDay = out[slice.rawValue] ?? [:]
            let existing = byDay[dayStart] ?? (reasoningChars: 0, visibleChars: 0)
            byDay[dayStart] = (
                reasoningChars: SaturatingArithmetic.add(
                    existing.reasoningChars, SQLiteConnection.nnClamp(reasoningChars)
                ),
                visibleChars: SaturatingArithmetic.add(
                    existing.visibleChars, SQLiteConnection.nnClamp(visibleChars)
                )
            )
            out[slice.rawValue] = byDay
        }
        return out
    }

    /// 分片累计的有 token LLM round 数。
    private func querySliceTotals() throws -> [String: Int] {
        let sql = """
        SELECT provider_id, COUNT(*) AS calls
        FROM model_usage
        WHERE \(Self.sliceFilterSQL("provider_id"))
          AND status = 'completed'
          AND (
            COALESCE(input_tokens,0)
            + COALESCE(output_tokens,0)
            + COALESCE(reasoning_tokens,0)
            + COALESCE(cache_read_input_tokens,0)
          ) > 0
        GROUP BY provider_id
        """
        var out: [String: Int] = [:]
        let rows: [(String, Int64)] = try connection.query(sql: sql, bind: { stmt in
            Self.bindSlices(to: stmt, index: 1)
        }) { stmt in
            (try SQLiteConnection.requiredText(stmt, column: 0),
             try SQLiteConnection.requiredInt64(stmt, column: 1))
        }
        for (providerID, calls) in rows {
            guard let slice = ZcodeProviderSlice(providerID: providerID) else { continue }
            out[slice.rawValue] = SaturatingArithmetic.add(out[slice.rawValue] ?? 0, Int(clamping: calls))
        }
        return out
    }

    /// 分片见过的 modelID（去重）。
    private func querySliceModels() throws -> [String: [String]] {
        let sql = """
        SELECT DISTINCT provider_id, model_id
        FROM model_usage
        WHERE \(Self.sliceFilterSQL("provider_id"))
          AND model_id IS NOT NULL
        """
        var models: [String: Set<String>] = [:]
        let rows: [(String, String)] = try connection.query(sql: sql, bind: { stmt in
            Self.bindSlices(to: stmt, index: 1)
        }) { stmt in
            (try SQLiteConnection.requiredText(stmt, column: 0),
             try SQLiteConnection.requiredText(stmt, column: 1))
        }
        for (providerID, model) in rows {
            guard let slice = ZcodeProviderSlice(providerID: providerID) else { continue }
            models[slice.rawValue, default: []].insert(model)
        }
        return models.mapValues { $0.sorted() }
    }

    /// 分片最近窗口内的逐次模型调用。口径与智谱样本一致：ZCode 的 `input_tokens`
    /// 已是 cache-inclusive 完整 input，直接作为 `LocalTokenUsageSample.inputTokens`，
    /// `cachedInputTokens = cache_read_input_tokens`。`modelName` 取 `model_id`
    /// （ZCode 不记 model 名），`sourceProviderID` 保留原始 `provider_id`。
    ///
    /// reasoning 与日聚合同口径但粒度更细：native `reasoning_tokens > 0` 原样透传；
    /// 否则按**行级**字符比例分摊（两个相关子查询取本行 `assistant_message_id` 的
    /// part 字符数，无 part 时自然得 0 → 保持 reasoning = 0）。日聚合是 day 级分摊、
    /// 样本是行级分摊，两者都是守恒拆分，公式共用 `ReasoningCharSplit`。
    private func querySliceSamples(cutoff: Date?) throws -> [String: [LocalTokenUsageSample]] {
        let sql = """
        SELECT
          id,
          session_id,
          started_at,
          turn_id,
          model_id,
          provider_id,
          input_tokens,
          output_tokens,
          reasoning_tokens,
          cache_read_input_tokens,
          COALESCE((
            SELECT SUM(LENGTH(COALESCE(json_extract(
              CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.text'), '')))
            FROM part p
            WHERE p.message_id = mu.assistant_message_id
              AND json_extract(
                CASE WHEN json_valid(p.data) THEN p.data ELSE '{}' END, '$.type') = 'reasoning'
          ), 0) AS reasoning_chars,
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
            WHERE p.message_id = mu.assistant_message_id
          ), 0) AS visible_chars,
          mu.duration_ms,
          mu.time_to_first_token_ms
        FROM model_usage mu
        WHERE \(Self.sliceFilterSQL("mu.provider_id"))
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
        let rows: [(String, String, Int64, String?, String?, String, Int64, Int64, Int64, Int64, Int64, Int64, Int64?, Int64?)] = try connection.query(
            sql: sql,
            bind: { stmt in
                let provider = Self.bindSlices(to: stmt, index: 1)
                guard provider == SQLITE_OK else { return provider }
                return SQLiteConnection.bindNullableMsCutoff(
                    cutoffMs, startingAt: 1 + Self.sliceFilterParameterCount
                )(stmt)
            },
            map: { stmt in
            let id = try SQLiteConnection.requiredText(stmt, column: 0)
            let sessionID = try SQLiteConnection.requiredText(stmt, column: 1)
            let timestamp = try SQLiteConnection.requiredInt64(stmt, column: 2)
            let turn = SQLiteConnection.optionalText(stmt, column: 3)
            let model = SQLiteConnection.optionalText(stmt, column: 4)
            let providerID = try SQLiteConnection.requiredText(stmt, column: 5)
            let input = SQLiteConnection.optionalInt64(stmt, column: 6)
            let output = SQLiteConnection.optionalInt64(stmt, column: 7)
            let reasoning = SQLiteConnection.optionalInt64(stmt, column: 8)
            let cacheRead = SQLiteConnection.optionalInt64(stmt, column: 9)
            let reasoningChars = SQLiteConnection.optionalInt64(stmt, column: 10)
            let visibleChars = SQLiteConnection.optionalInt64(stmt, column: 11)
            let durationMs = SQLiteConnection.optionalInt64(stmt, column: 12)
            let ttftMs = Self.optionalInt64OrNull(stmt, column: 13)
            return (
                id, sessionID, timestamp, turn, model, providerID, input, output, reasoning, cacheRead,
                reasoningChars, visibleChars, durationMs, ttftMs
            )
            }
        )
        var out: [String: [LocalTokenUsageSample]] = [:]
        for (id, sessionID, timestamp, turn, model, providerID, input, output, reasoning, cacheRead,
             reasoningChars, visibleChars, durationMs, ttftMs) in rows {
            guard let slice = ZcodeProviderSlice(providerID: providerID) else { continue }
            let promptComponent = turn ?? "event-\(id)"
            // native reasoning 优先原样透传；否则按本行 part 字符比例分摊（守恒：
            // reasoning + output == 原始 output）。
            let nativeReasoning = SQLiteConnection.nnClamp(reasoning)
            let nativeOutput = SQLiteConnection.nnClamp(output)
            let split: (reasoning: Int, output: Int)?
            if nativeReasoning > 0 {
                split = nil
            } else {
                split = ReasoningCharSplit.split(
                    outputTokens: nativeOutput,
                    reasoningChars: SQLiteConnection.nnClamp(reasoningChars),
                    visibleChars: SQLiteConnection.nnClamp(visibleChars)
                )
            }
            let sample = LocalTokenUsageSample(
                completedAt: Date(timeIntervalSince1970: Double(timestamp) / 1000),
                modelName: model,
                promptID: "\(sessionID):\(promptComponent)",
                inputTokens: SQLiteConnection.nnClamp(input),
                cachedInputTokens: SQLiteConnection.nnClamp(cacheRead),
                outputTokens: split?.output ?? nativeOutput,
                reasoningOutputTokens: split?.reasoning ?? nativeReasoning,
                sourceProviderID: providerID,
                durationSeconds: durationMs.flatMap { $0 > 0 && $0 <= 3_600_000 ? Double($0) / 1000.0 : nil },
                // 与主表同口径：原生逐调用 TTFT 列，ms → 秒，非法值 → nil。
                ttftSeconds: ttftMs.flatMap { $0 >= 0 ? Double($0) / 1000.0 : nil }
            )
            out[slice.rawValue, default: []].append(sample)
        }
        return out
    }

    /// 非智谱分片的 `provider_id` 谓词：每个 `ZcodeProviderSlice` 前缀一个
    /// `LIKE ?`（与智谱谓词互斥，前缀增减时谓词与绑定同步生成）。
    /// NULL-aware 整列读取。`SQLiteConnection.optionalInt64` 把 NULL 折叠为 0，
    /// 而 TTFT 列必须区分「账本未提供」（NULL，实测约 29% 行）与真实 0ms——
    /// NULL → nil，真实 0 照收（0 不是非法值，非法=负/缺失）。
    private static func optionalInt64OrNull(_ statement: OpaquePointer, column: Int32) -> Int64? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, column)
    }

    private static func sliceFilterSQL(_ column: String) -> String {
        let likes = ZcodeProviderSlice.allCases
            .map { _ in "\(column) LIKE ?" }
            .joined(separator: " OR ")
        return "(\(likes))"
    }

    private static var sliceFilterParameterCount: Int32 {
        Int32(ZcodeProviderSlice.allCases.count)
    }

    private static func bindSlices(to statement: OpaquePointer, index: Int32) -> Int32 {
        let transient = SQLiteConnection.sqliteTransientDestructor
        var currentIndex = index
        for slice in ZcodeProviderSlice.allCases {
            let code = sqlite3_bind_text(
                statement,
                currentIndex,
                ((slice.providerPrefix + "%") as NSString).utf8String,
                -1,
                transient
            )
            guard code == SQLITE_OK else { return code }
            currentIndex += 1
        }
        return SQLITE_OK
    }

    /// `provider_id` 过滤谓词：每个智谱前缀一个 `LIKE ?`（GLM 家族超集，新格式
    /// offpeak 行也经前缀 LIKE 进来），加历史裸值闲时 `= ?` 精确匹配（只为
    /// 0020 迁移前的 `offpeak-idle-plan` 遗留行）。谓词文本与 `bindProviders`
    /// 的绑定都由 `zcodeBigmodelProviderPrefixes` 生成，前缀增减时二者自动
    /// 同步，不会漂移。
    private static func providerFilterSQL(_ column: String) -> String {
        let likes = OpencodeLocalUsage.zcodeBigmodelProviderPrefixes
            .map { _ in "\(column) LIKE ?" }
            .joined(separator: " OR ")
        return "(\(likes) OR \(column) = ?)"
    }

    /// provider 过滤占用的 `?` 参数个数（前缀数 + 1 个 offpeak 精确匹配），
    /// 供后续 cutoff 等参数确定起始下标。
    private static var providerFilterParameterCount: Int32 {
        Int32(OpencodeLocalUsage.zcodeBigmodelProviderPrefixes.count + 1)
    }

    /// 绑定智谱系 provider 前缀通配（`builtin:bigmodel-%` / `account:bigmodel-%` /
    /// `account:zai-%`，覆盖正式 Coding Plan、账号化闲时、体验套餐及未知新套餐）
    /// 与历史裸值闲时 provider（`offpeak-idle-plan`，0020 迁移前的遗留行）。
    /// `index` 为第一个 `?` 的位置，其余参数按 `zcodeBigmodelProviderPrefixes`
    /// 顺序紧跟其后，与 `providerFilterSQL` 的谓词结构一一对应。
    private static func bindProviders(to statement: OpaquePointer, index: Int32) -> Int32 {
        let transient = SQLiteConnection.sqliteTransientDestructor
        var currentIndex = index
        for prefix in OpencodeLocalUsage.zcodeBigmodelProviderPrefixes {
            let code = sqlite3_bind_text(
                statement,
                currentIndex,
                ((prefix + "%") as NSString).utf8String,
                -1,
                transient
            )
            guard code == SQLITE_OK else { return code }
            currentIndex += 1
        }
        return sqlite3_bind_text(
            statement,
            currentIndex,
            (offPeakProviderID as NSString).utf8String,
            -1,
            transient
        )
    }
}
