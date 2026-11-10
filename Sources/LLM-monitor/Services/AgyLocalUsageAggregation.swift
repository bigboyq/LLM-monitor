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
/// input = 未缓存输入，cacheRead = 缓存读，output 含思考。reasoning/visible
/// 拆分两级来源：同一 `conversations/<session>.db` gen_metadata `f1.f4` 的原生
/// 真值（f9 reasoning + f10 normalized；2026-11-08 实测 10 库 100% 守恒、与
/// transcript 口径精确一致，逐行校验 `reasoning + normalized == 账面
/// output_tokens` 防 db/transcript 漂移）；`.db` 缺失 / 连接不命中 / 不守恒时
/// 回退 `thinking` 文本按字符占比把 output 守恒拆成 reasoning + output
/// （`ReasoningCharSplit`，逐行与日聚合两级都保持守恒）。
///
/// 单次调用时长（`durationSeconds`）两级来源：方案 A——scanner 预读
/// `conversations/<session>.db` 的 LLM step protobuf（field 1 发起 → field 7
/// 流式完成，真值）；方案 B——`.db` 未覆盖时用同会话内后继 `MODEL:GENERIC`
/// 子工具步骤创建行（created_at 恰为流式完成整秒 ⌊f7⌋）结算近似值。
/// transcript `created_at` 是整秒级**发起**时刻，前驱行差分完全失真，禁止使用。

/// 一条 MODEL 行解析出的原始计数（token 未拆分、模型名未 join）。
struct AgyRawModelRow: Sendable {
    let createdAt: Date
    let stepIndex: Int?
    let inputTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    let thinkingChars: Int
    let visibleChars: Int
    /// 行 `type`（`PLANNER_RESPONSE` / `GENERIC` 等），方案 B 的暂存判定键。
    let rowType: String?
    /// `tool_calls` 是否非空（带工具调用的 planner 响应才有 GENERIC 子步骤后继）。
    let hasToolCalls: Bool
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
    /// 会话内步骤号（方案 A/B 时长映射键；缺失时不参与时长解析）。
    let stepIndex: Int?
    /// 单次调用流式时长（秒）：纯文本流式输出为 `(ttft ?? 0) + streaming`，
    /// 使得 `decode = duration − ttft = f12`；工具调用或非流式短响应为 nil。
    var durationSeconds: Double?
    /// 单次调用首字延迟（TTFT，秒）：来自 .db gen_metadata f1.f11。
    var ttftSeconds: Double?
}

enum AgyLocalUsageAggregation {
    /// MODEL 行的 JSON 键集不固定，用 JSONSerialization 按需取值（缺键 = nil）。
    /// 字节级 `"source":"MODEL"` 预过滤之后的二级解析；超长行 / 坏 JSON 返回 nil。
    /// 计量行判定与方案 B 的 GENERIC 标记行共用这一次解析（见 `consumeLine`）。
    static func parseLineObject(
        _ line: Data,
        maxLineBytes: Int
    ) -> [String: Any]? {
        guard line.count <= maxLineBytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// 计量行判定（`parseLineObject` 结果 → 原始计数）。返回 nil 表示该行与
    /// 计量无关（非 DONE / 无 token 字段 / created_at 缺失或不可解析）。
    static func parseModelRow(_ object: [String: Any]) -> AgyRawModelRow? {
        guard object["source"] as? String == "MODEL",
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
            visibleChars: visibleCharCount(in: object),
            rowType: object["type"] as? String,
            hasToolCalls: hasToolCalls(in: object)
        )
    }

    /// 方案 B 标记行：`MODEL:GENERIC`（工具子步骤）。status 不限——创建行通常是
    /// 中间态且不带 token 字段；必须带 `step_index` 与可解析 `created_at`。带
    /// tool_calls 的 PLANNER_RESPONSE 流式结束瞬间 agy 立即创建该子步骤，其
    /// `created_at` 恰为流式完成整秒 ⌊f7⌋；同 step 的后续状态行 created_at 只会
    /// 更晚，由 context 的 min 保留创建行。
    static func parseGenericMarkerRow(_ object: [String: Any]) -> (stepIndex: Int, createdAt: Date)? {
        guard object["source"] as? String == "MODEL",
              object["type"] as? String == "GENERIC",
              let stepIndex = (object["step_index"] as? NSNumber)?.intValue,
              let createdAt = DateParser.parse(object["created_at"]) else {
            return nil
        }
        return (stepIndex, createdAt)
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

    /// 原始行 → 可聚合样本：模型名 join + reasoning/visible 拆分（原生 f4 真值
    /// 优先、字符占比估算回退，两级都守恒）+ 方案 A 时长映射（`.db` 未覆盖时
    /// 保持 nil，落给方案 B 会话级结算回填）。
    ///
    /// 拆分回退条件（任一即回退 `ReasoningCharSplit` 字符占比，v4 及以前唯一
    /// 路径，行为不变）：该行 step_index 无原生映射（无 .db / gen 行连接不命中 /
    /// usage 子消息缺失），或守恒校验不过（`reasoning + normalized !=
    /// 账面 output_tokens`，防 db/transcript 漂移）。2026-11-08 实测守恒 100%
    /// 成立（267/267），生产路径预期全量走原生真值。
    static func makeUsage(
        raw: AgyRawModelRow,
        sessionID: String,
        modelName: String?,
        planADurationSeconds: Double? = nil,
        planATiming: AntigravityStepTimestampReader.LLMCallTiming? = nil,
        nativeUsage: AntigravityStepTimestampReader.LLMCallNativeUsage? = nil
    ) -> AgyParsedUsage {
        let split: (reasoning: Int, output: Int)?
        if let nativeUsage,
           nativeUsage.reasoning + nativeUsage.normalized == raw.outputTokens {
            // 原生真值：f9 → reasoning，f10 normalized → 可见 output。
            split = (reasoning: nativeUsage.reasoning, output: nativeUsage.normalized)
        } else {
            split = ReasoningCharSplit.split(
                outputTokens: raw.outputTokens,
                reasoningChars: raw.thinkingChars,
                visibleChars: raw.visibleChars
            )
        }
        let stepKey = raw.stepIndex.map(String.init)
            ?? String(raw.createdAt.timeIntervalSince1970)

        let ttft = planATiming?.ttftSeconds
        let duration: Double?
        if let timing = planATiming {
            let isTool = raw.hasToolCalls || timing.isToolCall
            if !isTool, let stream = timing.streamingSeconds, stream >= 0.5 {
                let total = (ttft ?? 0) + stream
                duration = (total > 0 && total <= 3600) ? total : nil
            } else {
                duration = nil
            }
        } else {
            duration = planADurationSeconds
        }

        return AgyParsedUsage(
            completedAt: raw.createdAt,
            inputTokens: raw.inputTokens,
            cacheReadTokens: raw.cacheReadTokens,
            outputTokens: split?.output ?? raw.outputTokens,
            reasoningTokens: split?.reasoning ?? 0,
            modelName: modelName,
            promptID: "\(sessionID):step:\(stepKey)",
            sessionID: sessionID,
            stepIndex: raw.stepIndex,
            durationSeconds: duration,
            ttftSeconds: ttft
        )
    }

    // MARK: - 单次调用时长（方案 A .db 真值 + 方案 B GENERIC 后继降级）

    /// 单会话的时长解析上下文。方案 A 是 scanner 预读的 `.db` 映射（真值）；
    /// 方案 B 在 transcript 流式扫描中暂存/收集，会话全部文件解析完后结算
    /// （`fallbackDurations` → `settleFallbackDurations`）。
    struct AgySessionDurationContext: Sendable {
        /// 方案 A：`conversations/<session>.db` 的 `step_index → 调用时延与流式信息`。
        var planATimings: [Int: AntigravityStepTimestampReader.LLMCallTiming] = [:]
        /// 方案 A：`conversations/<session>.db` 的 `step_index → 流式时长（秒）`（回退兼容）。
        var planADurations: [Int: Double] = [:]
        /// 同一 `.db` gen_metadata `f1.f4` 的原生 usage（f9 reasoning / f10
        /// normalized / f3 raw），连接键与方案 A 同构（键即 step_index）。守恒
        /// 校验（`reasoning + normalized == 账面 output_tokens`）归 `makeUsage`
        /// ——必须对照 transcript 账面值，防 db/transcript 漂移。`.db` 缺失 /
        /// gen_metadata 表缺失 / 连接不命中 / usage 缺失的行为空映射（该行回退
        /// 字符估算）。
        var nativeUsageByStepIndex: [Int: AntigravityStepTimestampReader.LLMCallNativeUsage] = [:]
        /// 方案 B 暂存：带 tool_calls 的 `MODEL:PLANNER_RESPONSE:DONE` 行
        ///（step_index → created_at = 发起整秒 ⌊f1⌋）。纯文本终答（无
        /// tool_calls）不入暂存，保持 nil——不误食下一轮 USER_INPUT 行。
        var pendingPlanners: [Int: Date] = [:]
        /// 方案 B 标记：`MODEL:GENERIC` 行（step_index → 最早 created_at =
        /// 流式完成整秒 ⌊f7⌋；同 step 的后续状态行更晚，min 保留创建行）。
        var genericMarkers: [Int: Date] = [:]

        init(
            planATimings: [Int: AntigravityStepTimestampReader.LLMCallTiming] = [:],
            planADurations: [Int: Double] = [:],
            nativeUsageByStepIndex: [Int: AntigravityStepTimestampReader.LLMCallNativeUsage] = [:]
        ) {
            self.planATimings = planATimings
            self.planADurations = planADurations
            self.nativeUsageByStepIndex = nativeUsageByStepIndex
        }

        /// 方案 A 时延取值（映射外的 step_index 返回 nil）。
        func planATiming(stepIndex: Int?) -> AntigravityStepTimestampReader.LLMCallTiming? {
            guard let stepIndex else { return nil }
            return planATimings[stepIndex]
        }

        /// 方案 A 取值（映射外的 step_index 返回 nil）。
        func planADuration(stepIndex: Int?) -> Double? {
            guard let stepIndex else { return nil }
            return planADurations[stepIndex]
        }

        /// 同一 `.db` 的原生 usage 取值（映射外的 step_index 返回 nil）。
        func nativeUsage(stepIndex: Int?) -> AntigravityStepTimestampReader.LLMCallNativeUsage? {
            guard let stepIndex else { return nil }
            return nativeUsageByStepIndex[stepIndex]
        }

        /// 计量行入上下文：带 tool_calls 的 PLANNER_RESPONSE 暂存待结算。
        mutating func recordMeteredRow(_ row: AgyRawModelRow) {
            if row.rowType == "PLANNER_RESPONSE", row.hasToolCalls, let stepIndex = row.stepIndex {
                pendingPlanners[stepIndex] = row.createdAt
            }
        }

        mutating func recordGenericMarker(stepIndex: Int, createdAt: Date) {
            if let existing = genericMarkers[stepIndex] {
                genericMarkers[stepIndex] = min(existing, createdAt)
            } else {
                genericMarkers[stepIndex] = createdAt
            }
        }
    }

    /// 方案 B 结算（纯函数）：对每个暂存 planner（step s），取 step_index 大于 s
    /// 的最小 GENERIC 标记——即流式结束瞬间创建的子工具步骤，`duration =
    /// ⌊f7⌋ − ⌊f1⌋`，过 (0, 3600] 有效域。与文件处理顺序无关：标记先于 planner
    /// 到达（主文件先于 chunks 的约定下合法）也在结算期回配。
    static func fallbackDurations(from context: AgySessionDurationContext) -> [Int: Double] {
        var durations: [Int: Double] = [:]
        for (step, plannerStart) in context.pendingPlanners {
            guard let markerStep = context.genericMarkers.keys
                    .filter({ $0 > step })
                    .min(),
                  let streamEnd = context.genericMarkers[markerStep] else { continue }
            let duration = streamEnd.timeIntervalSince(plannerStart)
            if duration > 0, duration <= 3600 {
                durations[step] = duration
            }
        }
        return durations
    }

    /// 结算回填：方案 A 未覆盖（`durationSeconds == nil`）的计量样本按
    /// step_index 取方案 B 结果；已有方案 A 值的样本不覆盖。
    static func settleFallbackDurations(
        into usages: inout [AgyParsedUsage],
        context: AgySessionDurationContext
    ) {
        let fallback = fallbackDurations(from: context)
        guard !fallback.isEmpty else { return }
        for index in usages.indices where usages[index].durationSeconds == nil {
            guard let step = usages[index].stepIndex, let duration = fallback[step] else { continue }
            // 已取得原生 timing 的 nil 是明确排除（工具/非流式），不是缺测。
            guard context.planATimings[step] == nil else { continue }
            usages[index].durationSeconds = duration
        }
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
            sourceProviderID: ClientID.agy,
            durationSeconds: usage.durationSeconds,
            ttftSeconds: usage.ttftSeconds
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

    /// `tool_calls` 是否非空（与 `visibleCharCount` 同一形态约定）。
    private static func hasToolCalls(in object: [String: Any]) -> Bool {
        guard let toolCalls = object["tool_calls"] as? [[String: Any]] else { return false }
        return !toolCalls.isEmpty
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
