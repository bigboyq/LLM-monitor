import Foundation

/// agy transcript JSONL 行的解析与聚合纯函数（L0 scanner 的领域逻辑收口）。
///
/// 行格式（本机 `~/.gemini/antigravity-cli/brain/` 实测）：
/// - 只有 `source == "MODEL"` 且 `status == "DONE"` 的行带 token 字段
///   （`input_tokens` / `cache_read_tokens` / `output_tokens` 三键成组出现，
///   要么都有要么都没有）；无 token 字段的 DONE 行是未计量响应，整行跳过。
/// - `created_at` 是 ISO8601 UTC；`step_index` 是会话内步骤号。去重键是
///   `(sessionID, created_at, step_index)`：主 transcript 与滚动分块
///   `chunks/transcript/` 在轮转期会同时包含同一行（实测两份集合相等），
///   合并读取后靠该键去重兜底，不重不漏。
/// - 无模型名：模型名由 scanner 用 `log/cli-*.log` 时间线 join 补上
///   （`resolvedModelName`），无命中保持 nil（投影层落 unknownModelName）。
///
/// 计数口径与 antigravity RPC 一致（`TokenAccountingCatalog.antigravity`）：
/// input = 未缓存输入，cacheRead = 缓存读，output 含思考。无原生 reasoning
/// 计数，用 `thinking` 文本按字符占比把 output 守恒拆成 reasoning + output
/// （`ReasoningCharSplit`，逐行与日聚合两级都保持守恒）。

/// 一条 MODEL 行解析出的原始计数（token 未拆分、模型名未 join）。
struct AgyRawModelRow: Sendable {
    let createdAt: Date
    let stepIndex: Int?
    let inputTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    let thinkingChars: Int
    let visibleChars: Int
}

/// join + 分摊后的一次模型响应样本。
struct AgyParsedUsage: Sendable {
    let completedAt: Date
    /// 未缓存输入。
    let inputTokens: Int
    /// 缓存读。
    let cacheReadTokens: Int
    /// 分摊后的可见输出（reasoning + output == 账面 output_tokens）。
    let outputTokens: Int
    /// 分摊出的思考输出。
    let reasoningTokens: Int
    let modelName: String?
    /// 裸 promptID（`session:step:N`）；`agy:` 命名空间由帧构造统一施加。
    let promptID: String
    let sessionID: String
}

enum AgyLocalUsageAggregation {
    /// MODEL 行的 JSON 键集不固定，用 JSONSerialization 按需取值（缺键 = nil）。
    /// 返回 nil 表示该行与计量无关（非 MODEL / 非 DONE / 无 token 字段 /
    /// created_at 缺失或不可解析）。
    static func parseModelRow(
        _ line: Data,
        maxLineBytes: Int
    ) -> AgyRawModelRow? {
        guard line.count <= maxLineBytes,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["source"] as? String == "MODEL",
              object["status"] as? String == "DONE",
              // token 三键成组；全缺 = 未计量响应（非 DONE 的中间行同理被
              // status 过滤），不产出样本也不计轮次。
              object["input_tokens"] != nil
                  || object["cache_read_tokens"] != nil
                  || object["output_tokens"] != nil,
              let createdAt = DateParser.parse(object["created_at"]) else {
            return nil
        }
        return AgyRawModelRow(
            createdAt: createdAt,
            stepIndex: (object["step_index"] as? NSNumber)?.intValue,
            inputTokens: max(intValue(object["input_tokens"]), 0),
            cacheReadTokens: max(intValue(object["cache_read_tokens"]), 0),
            outputTokens: max(intValue(object["output_tokens"]), 0),
            thinkingChars: (object["thinking"] as? String)?.count ?? 0,
            visibleChars: visibleCharCount(in: object)
        )
    }

    /// 同一会话内（跨主文件与分块）的防重复键。
    static func dedupeKey(sessionID: String, row: AgyRawModelRow) -> String {
        "\(sessionID)|\(row.createdAt.timeIntervalSince1970)|\(row.stepIndex ?? -1)"
    }

    /// cli log 时间线 join：取「开始时间 ≤ created_at 的最近一个 log」的模型名；
    /// created_at 早于全部 log 时回退最早已知模型（时间线上最近一次已知的
    /// 模型配置）；时间线为空返回 nil，由调用方保持模型名缺失。
    static func resolvedModelName(
        createdAt: Date,
        timeline: [AgyCliLogEntry]
    ) -> String? {
        guard !timeline.isEmpty else { return nil }
        var candidate: AgyCliLogEntry?
        for entry in timeline {
            guard entry.startedAt <= createdAt else { break }
            candidate = entry
        }
        return candidate?.modelName ?? timeline.first?.modelName
    }

    /// 原始行 → 可聚合样本：模型名 join + thinking 字符占比分摊（守恒）。
    static func makeUsage(
        raw: AgyRawModelRow,
        sessionID: String,
        modelName: String?
    ) -> AgyParsedUsage {
        let split = ReasoningCharSplit.split(
            outputTokens: raw.outputTokens,
            reasoningChars: raw.thinkingChars,
            visibleChars: raw.visibleChars
        )
        let stepKey = raw.stepIndex.map(String.init)
            ?? String(raw.createdAt.timeIntervalSince1970)
        return AgyParsedUsage(
            completedAt: raw.createdAt,
            inputTokens: raw.inputTokens,
            cacheReadTokens: raw.cacheReadTokens,
            outputTokens: split?.output ?? raw.outputTokens,
            reasoningTokens: split?.reasoning ?? 0,
            modelName: modelName,
            promptID: "\(sessionID):step:\(stepKey)",
            sessionID: sessionID
        )
    }

    // MARK: - 聚合

    struct AgyAggregate: Sendable {
        var daily: [Date: AgyDailyUsage] = [:]
        var turnsByDay: [Date: Set<String>] = [:]
        var sessions: Set<String> = []
        var models: Set<String> = []
        var recentSamples: [LocalTokenUsageSample] = []
    }

    static func apply(
        _ usage: AgyParsedUsage,
        to aggregate: inout AgyAggregate,
        calendar: Calendar
    ) {
        let day = calendar.startOfDay(for: usage.completedAt)
        let existing = aggregate.daily[day] ?? AgyDailyUsage(dayStart: day)
        aggregate.daily[day] = AgyDailyUsage(
            dayStart: day,
            inputTokens: SaturatingArithmetic.add(existing.inputTokens, usage.inputTokens),
            outputTokens: SaturatingArithmetic.add(existing.outputTokens, usage.outputTokens),
            cacheReadTokens: SaturatingArithmetic.add(existing.cacheReadTokens, usage.cacheReadTokens),
            cacheWriteTokens: existing.cacheWriteTokens,
            reasoningTokens: SaturatingArithmetic.add(existing.reasoningTokens, usage.reasoningTokens),
            totalTokens: SaturatingArithmetic.add(
                existing.totalTokens,
                SaturatingArithmetic.sum(
                    usage.inputTokens,
                    usage.cacheReadTokens,
                    usage.outputTokens,
                    usage.reasoningTokens
                )
            ),
            turns: existing.turns,
            rounds: SaturatingArithmetic.add(existing.rounds, 1)
        )
        // 同一 promptID 的多条样本是同一次用户请求的多轮模型调用，日聚合的
        // turns 只记一次（与 LocalTokenUsageSample.usage 的 prompts 口径一致）。
        if aggregate.turnsByDay[day, default: []].insert(usage.promptID).inserted {
            aggregate.daily[day] = aggregate.daily[day]?.withIncrementedTurns()
        }
        aggregate.sessions.insert(usage.sessionID)
        if let model = usage.modelName, !model.isEmpty {
            aggregate.models.insert(model)
        }
        aggregate.recentSamples.append(LocalTokenUsageSample(
            completedAt: usage.completedAt,
            modelName: usage.modelName,
            promptID: usage.promptID,
            // sample 层历史语义：inputTokens 是 cache-inclusive 总输入，
            // cachedInputTokens 是独立的缓存读桶（内核 fromSample 还原拆分）。
            inputTokens: SaturatingArithmetic.add(usage.inputTokens, usage.cacheReadTokens),
            cachedInputTokens: usage.cacheReadTokens,
            outputTokens: usage.outputTokens,
            reasoningOutputTokens: usage.reasoningTokens,
            sourceProviderID: ClientID.agy
        ))
    }

    /// 聚合 → 展示快照：只保留最近 8 天的日桶与样本（落盘保留窗口）。
    static func buildSnapshot(
        aggregate: AgyAggregate,
        sessionsRoot: String?,
        calendar: Calendar,
        now: Date,
        limits: AgyLocalUsageScanLimits,
        isTruncated: Bool
    ) -> AgyLocalUsage {
        let today = calendar.startOfDay(for: now)
        let allDaily = aggregate.daily.values.sorted { $0.dayStart < $1.dayStart }
        return AgyLocalUsage(
            dailyTokenUsage: DailyUsageAggregation.filterLast7Days(
                allDaily: allDaily,
                today: today,
                calendar: calendar
            ),
            models: aggregate.models.sorted(),
            recentSamples: boundedRecentSamples(
                aggregate.recentSamples,
                calendar: calendar,
                now: now,
                maxCount: limits.maxRecentSamples
            ),
            sessionsRoot: sessionsRoot,
            sessionCount: aggregate.sessions.count,
            eventCount: aggregate.recentSamples.count,
            scannedAt: now,
            isTruncated: isTruncated
        )
    }

    /// rebase（缓存短路路径）：按当前日历重算 7 天窗口并重剪样本，
    /// 业务字段（models / sessionCount / eventCount / isTruncated）原样保留。
    static func rebaseCached(
        _ snapshot: AgyLocalUsage,
        calendar: Calendar,
        now: Date,
        limits: AgyLocalUsageScanLimits
    ) -> AgyLocalUsage {
        let daily = DailyUsageAggregation.filterLast7Days(
            allDaily: snapshot.dailyTokenUsage,
            today: calendar.startOfDay(for: now),
            calendar: calendar
        )
        // isTruncated 描述的是聚合数字本身的口径（是否被预算截断），不是新鲜
        // 度标记，所以窗口重算时保留；isPartial 是新鲜度标记，刻意不在此保留，
        // 由各扫描路径按当轮结果重新置位。
        return AgyLocalUsage(
            dailyTokenUsage: daily,
            models: snapshot.models,
            recentSamples: boundedRecentSamples(
                snapshot.recentSamples,
                calendar: calendar,
                now: now,
                maxCount: limits.maxRecentSamples
            ),
            sessionsRoot: snapshot.sessionsRoot,
            sessionCount: snapshot.sessionCount,
            eventCount: snapshot.eventCount,
            scannedAt: snapshot.scannedAt,
            isTruncated: snapshot.isTruncated
        )
    }

    /// 统一 recent-samples 契约（与 DSH `boundedRecentSamples` 同款）：
    /// 保留最近 `LocalUsageRetentionWindow.days` 个自然日、按时间升序、
    /// 截到 `maxCount` 条。
    static func boundedRecentSamples(
        _ samples: [LocalTokenUsageSample],
        calendar: Calendar,
        now: Date,
        maxCount: Int
    ) -> [LocalTokenUsageSample] {
        guard let cutoff = calendar.date(
            byAdding: .day,
            value: -(LocalUsageRetentionWindow.days - 1),
            to: calendar.startOfDay(for: now)
        ) else {
            return []
        }
        return Array(
            samples
                .filter { $0.completedAt >= cutoff }
                .sorted { $0.completedAt < $1.completedAt }
                .suffix(maxCount)
        )
    }

    // MARK: - 私有

    private static func intValue(_ raw: Any?) -> Int {
        guard let number = raw as? NSNumber, DateParser.isBoolean(number) == false else {
            return 0
        }
        return number.intValue
    }

    /// 可见输出字符数：content 正文 + tool_calls 的 name/args 序列化文本
    /// （都是模型生成的输出；与 DSH 把 tool-call 参数计入可见侧同口径）。
    private static func visibleCharCount(in object: [String: Any]) -> Int {
        let contentCount = (object["content"] as? String)?.count ?? 0
        guard let toolCalls = object["tool_calls"] as? [[String: Any]],
              !toolCalls.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: toolCalls),
              let text = String(data: data, encoding: .utf8) else {
            return contentCount
        }
        return SaturatingArithmetic.add(contentCount, text.count)
    }
}

private extension AgyDailyUsage {
    func withIncrementedTurns() -> AgyDailyUsage {
        AgyDailyUsage(
            dayStart: dayStart,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            turns: SaturatingArithmetic.add(turns, 1),
            rounds: rounds
        )
    }
}
