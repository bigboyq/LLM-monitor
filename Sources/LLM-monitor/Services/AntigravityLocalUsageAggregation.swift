import Foundation
import Combine

// MARK: - Data Models for Turns and Rounds

/// 单个自然日的 (turns, rounds) 计数。
struct DailyTurnRound: Equatable, Sendable, Codable {
    var turns: Int
    var rounds: Int
}

/// per-day turns / rounds 计数。
struct AntigravityTurnRoundCounts: Equatable, Sendable {
    /// dayStart (本地自然日 00:00) → 计数
    var perDay: [Date: DailyTurnRound]

    var totalTurns: Int { perDay.values.reduce(0) { $0 + $1.turns } }
    var totalRounds: Int { perDay.values.reduce(0) { $0 + $1.rounds } }
}

// MARK: - Aggregation (pure functions, unit-testable)

extension AntigravityLocalUsageScanner {
    /// 一次 LLM call 的统一事件形态（数据源无关）。
    ///
    /// 阶段二b 起唯一生产数据源是 `AntigravitySessionDBReader.Call`（`.db`
    /// 直读）；本结构保留原 RPC 事件模型的五类 token 字段命名，让
    /// `aggregateDaily` / `makeSample` 的聚合契约在数据源切换时保持不变。
    ///
    /// - `outputTokens` 是**含思考**的 raw 口径（与旧 RPC `outputTokens` 同口径，
    ///   db 侧 `f1.f4.f3`，恒等 normalized + reasoning），四桶规范化统一走
    ///   `TokenAccountingCatalog.antigravity`。
    /// - `cacheWriteTokens` 恒为 0：`.db` 的 usage 子消息不提供 cacheWrite
    ///   （`f4` 只有 input/cacheRead/rawOutput/reasoning/normalized），本就排除在
    ///   total 外，只有日桶诊断字段失去可见性（有意接受，spec 已注明）。
    struct UsageEvent: Equatable, Sendable {
        let timestamp: Date?
        let model: String?
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
        let reasoningTokens: Int
        /// 单次调用时长（秒）= steps.metadata f7（流式完成）− f1（发起）。
        let durationSeconds: Double?
        /// 单次调用首字延迟（TTFT，秒）= gen blob `f1.f11` timeToFirstToken。
        /// gen 行未携带 / 不可解析 → nil。
        let ttftSeconds: Double?

        init(
            timestamp: Date?,
            model: String?,
            inputTokens: Int,
            outputTokens: Int,
            cacheReadTokens: Int,
            cacheWriteTokens: Int = 0,
            reasoningTokens: Int,
            durationSeconds: Double? = nil,
            ttftSeconds: Double? = nil
        ) {
            self.timestamp = timestamp
            self.model = model
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.reasoningTokens = reasoningTokens
            self.durationSeconds = durationSeconds
            self.ttftSeconds = ttftSeconds
        }
    }

    /// `accountCalls` 的产物：日桶、turns/rounds 计数、样本与入账统计。
    struct CallAccounting: Equatable, Sendable {
        /// 按 `LocalUsageDayKey` 字符串键分桶的日聚合（index 契约形态）。
        let daily: [String: AntigravityDailyUsage]
        let counts: AntigravityTurnRoundCounts
        let samples: [LocalTokenUsageSample]
        /// 进入日统计的事件数（= `eventCount` 口径，见 `accountedEventStats`）。
        let accountedEventCount: Int
        /// 因缺时间戳被排除的 call 数（steps.metadata 缺失）。
        let droppedTimestamplessCount: Int
    }

    /// eventCount 的统一口径：只有带 timestamp、真正进入日统计的事件才计数。
    /// 无 timestamp 的 event 进不了 daily / turns / rounds / samples，也不得计入
    /// eventCount —— 一个字段不得同时代表“收到的 raw event 数”和“入账 event 数”。
    /// raw 总数保留在 scanner 的日志里，用于诊断数据质量。
    nonisolated static func accountedEventStats(
        _ events: [UsageEvent]
    ) -> (accounted: Int, droppedTimestampless: Int) {
        var accounted = 0
        for event in events where event.timestamp != nil {
            accounted = SaturatingArithmetic.add(accounted, 1)
        }
        return (accounted, events.count - accounted)
    }

    /// 把 events 按本地自然日分组聚合。
    /// 没有 timestamp 的事件跳过（没法归到任何一天）。
    ///
    /// raw→桶与 `makeSample` 同走 `TokenAccountingCatalog.antigravity` 唯一入口：
    /// raw `outputTokens` 已含思考（db `f3` 恒等 `f10 + f9`），规范化
    /// Output = rawOutput − reasoning、Reason = reasoning，daily 四桶才与
    /// sample / 计价口径守恒（`totalTokens` = 四桶和；cacheWrite 恒 0、本就
    /// 不在 total 内，仅作为诊断字段原样保留）。
    ///
    /// `counts` 传入调用方已经预算好的 per-day turns/rounds（`accountCalls` 的
    /// 路径），避免把同一份 counts 再叠加一次造成双倍计数；未传时日桶的
    /// turns/rounds 记 0（旧 `stepIndices` 间隙推断已随 RPC 数据源退役，生产
    /// 路径恒传 `accountCalls` 预算好的计数）。
    nonisolated static func aggregateDaily(
        events: [UsageEvent],
        calendar: Calendar,
        counts: AntigravityTurnRoundCounts? = nil
    ) -> [String: AntigravityDailyUsage] {
        let resolvedCounts = counts ?? AntigravityTurnRoundCounts(perDay: [:])
        var byDay: [String: AntigravityDailyUsage] = [:]
        for event in events {
            guard let timestamp = event.timestamp else { continue }
            let dayStart = calendar.startOfDay(for: timestamp)
            let key = LocalUsageDayKey.make(dayStart, calendar: calendar)
            let buckets = TokenAccountingCatalog.antigravity.normalizedBuckets(
                rawInput: event.inputTokens,
                cacheRead: event.cacheReadTokens,
                rawOutput: event.outputTokens,
                rawReasoning: event.reasoningTokens
            )
            let existing = byDay[key] ?? AntigravityDailyUsage(
                dayStart: dayStart,
                turns: resolvedCounts.perDay[dayStart]?.turns ?? 0,
                rounds: resolvedCounts.perDay[dayStart]?.rounds ?? 0
            )
            byDay[key] = AntigravityDailyUsage(
                dayStart: dayStart,
                inputTokens: SaturatingArithmetic.add(existing.inputTokens, buckets.input),
                outputTokens: SaturatingArithmetic.add(existing.outputTokens, buckets.output),
                cacheReadTokens: SaturatingArithmetic.add(existing.cacheReadTokens, buckets.cacheRead),
                // cacheWrite 是缓存簿记，在四桶规范化之外原样保留诊断值（.db 数据源恒 0）。
                cacheWriteTokens: SaturatingArithmetic.add(existing.cacheWriteTokens, event.cacheWriteTokens),
                reasoningTokens: SaturatingArithmetic.add(existing.reasoningTokens, buckets.reasoning),
                totalTokens: SaturatingArithmetic.add(existing.totalTokens, buckets.totalTokens),
                turns: existing.turns,
                rounds: existing.rounds
            )
        }
        return byDay
    }

    /// 轮序推断：call 的当前轮序 N = `steps.idx` 小于该 call `stepIndex` 的
    /// `step_type=14`（用户轮次边界）行数。
    ///
    /// 直计口径（2026-11-08 实测：step_type=14 与 transcript USER_INPUT 23/23
    /// 逐一对应），取代旧 RPC `stepIndices` 间隙推断（对真实会话虚高 +37%~+273%）。
    /// `userTurnStepIndexes` 必须升序（reader 按 idx 升序返回）；二分定位首个
    /// `>= stepIndex` 的行，其下标即小于 `stepIndex` 的行数。轮次行之前就出现的
    /// call（克隆/后台会话没有 USER_INPUT，或首条用户输入之前的副调用）得到
    /// N = 0（promptID `turn-0`，语义 = 背景调用）；`accountCalls` 的 turns
    /// 首见计数只对 N >= 1 生效，turn-0 不开轮。
    nonisolated static func turnNumber(
        forCallStepIndex stepIndex: Int,
        userTurnStepIndexes: [Int]
    ) -> Int {
        var low = 0
        var high = userTurnStepIndexes.count
        while low < high {
            let mid = (low + high) / 2
            if userTurnStepIndexes[mid] < stepIndex {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// 把 `.db` 直读的连接命中 Call 序列归入日桶、turns/rounds 与样本。
    ///
    /// - 输入按 `AntigravitySessionDBReader.readCalls` 的顺序（gen idx 升序 =
    ///   时间序）；`turnStepIndexes` 是 `step_type=14` 行的 idx 升序数组。
    /// - **rounds** = 带 `completedAt` 的 call 数（无时间戳的 call 整条排除出
    ///   daily / turns / rounds / samples，沿用旧「无 timestamp 不入账」口径）。
    /// - **turns** = `step_type=14` 直计，但只对 `turnIndex >= 1` 首见计数：
    ///   `turnNumber` 对「无前置用户输入」的 call（克隆/后台会话、首条用户
    ///   输入之前的副调用）返回 0——turn-0 不是真实用户轮，不开轮（否则 0 个
    ///   step14 行的会话得 turns=1，首输入前的后台调用会把 1 个真实轮虚增成
    ///   2）。turn-0 的 call 保留 rounds / tokens / daily 归属；样本 `promptID`
    ///   维持 `turn-0` 标签，语义 = 背景调用（无前置用户轮），仅作样本命名
    ///   空间，不代表一次用户轮。
    ///   轮 N 归入「该轮第一条带时间戳 call」的本地日历日——与旧实现「触发新
    ///   轮的第一个事件落在哪天就算哪天」一致。这是**可入账轮次**口径：某轮
    ///   有 step14 行但该轮全部 call 无时间戳被排除时，该轮不计入 turns——与
    ///   spec「step_type=14 直计」的差异仅在该无时间戳退化场景。
    /// - 样本 `promptID` = `<sessionID>:turn-N`，N 由 `turnNumber` 推得。
    /// - `cacheWrite` 恒 0（db 不提供；见 `UsageEvent` 注释）。
    nonisolated static func accountCalls(
        sessionID: String,
        calls: [AntigravitySessionDBReader.Call],
        turnStepIndexes: [Int],
        calendar: Calendar
    ) -> CallAccounting {
        var events: [UsageEvent] = []
        events.reserveCapacity(calls.count)
        var samples: [LocalTokenUsageSample] = []
        samples.reserveCapacity(calls.count)
        var perDay: [Date: DailyTurnRound] = [:]
        // 轮号 → 该轮第一条带时间戳 call 的日。轮的日归属只在首见时确定。
        var turnDays: [Int: Date] = [:]
        var dropped = 0

        for call in calls {
            guard let completedAt = call.completedAt else {
                dropped = SaturatingArithmetic.add(dropped, 1)
                continue
            }
            let turnIndex = turnNumber(
                forCallStepIndex: call.stepIndex,
                userTurnStepIndexes: turnStepIndexes
            )
            let event = UsageEvent(
                timestamp: completedAt,
                model: call.modelName,
                inputTokens: call.uncachedInputTokens,
                outputTokens: call.rawOutputTokens,
                cacheReadTokens: call.cacheReadTokens,
                cacheWriteTokens: 0,
                reasoningTokens: call.reasoningTokens,
                durationSeconds: call.durationSeconds,
                ttftSeconds: call.ttftSeconds
            )
            let day = calendar.startOfDay(for: completedAt)
            var dayCounts = perDay[day] ?? DailyTurnRound(turns: 0, rounds: 0)
            dayCounts.rounds = SaturatingArithmetic.add(dayCounts.rounds, 1)
            // turns 首见计数只对 turnIndex >= 1 生效：turnIndex == 0 是「无前置
            // 用户轮」的背景调用（见函数注释），不开轮。
            if turnIndex >= 1, turnDays[turnIndex] == nil {
                turnDays[turnIndex] = day
                dayCounts.turns = SaturatingArithmetic.add(dayCounts.turns, 1)
            }
            perDay[day] = dayCounts
            events.append(event)
            samples.append(makeSample(
                sessionID: sessionID,
                promptComponent: "turn-\(turnIndex)",
                event: event
            ))
        }

        let daily = aggregateDaily(events: events, calendar: calendar, counts: AntigravityTurnRoundCounts(perDay: perDay))
        return CallAccounting(
            daily: daily,
            counts: AntigravityTurnRoundCounts(perDay: perDay),
            samples: samples,
            accountedEventCount: events.count,
            droppedTimestamplessCount: dropped
        )
    }

    private nonisolated static func makeSample(
        sessionID: String,
        promptComponent: String,
        event: UsageEvent
    ) -> LocalTokenUsageSample {
        // Antigravity events report uncached input and cache-read separately.
        // Route raw→桶 through the harness catalog and rebuild the historical
        // cache-inclusive sample contract only here; the daily adapter and
        // TokenUsageBuckets split it for UI/pricing.
        let buckets = TokenAccountingCatalog.antigravity.normalizedBuckets(
            rawInput: event.inputTokens,
            cacheRead: event.cacheReadTokens,
            rawOutput: event.outputTokens,
            rawReasoning: event.reasoningTokens
        )
        // timestamp 缺失落 .distantPast 的兜底样本不携带时长：时长与 timestamp
        // 同源于一次真实调用，时间戳都无法归日的事件其时长也不可信。
        let durationSeconds = event.timestamp == nil ? nil : event.durationSeconds
        return LocalTokenUsageSample(
            completedAt: event.timestamp ?? .distantPast,
            modelName: event.model,
            promptID: "\(sessionID):\(promptComponent)",
            inputTokens: buckets.cacheInclusiveInput,
            cachedInputTokens: buckets.cacheRead,
            outputTokens: buckets.output,
            reasoningOutputTokens: buckets.reasoning,
            durationSeconds: durationSeconds,
            ttftSeconds: event.ttftSeconds
        )
    }

    nonisolated static func computeGlobalDaily(
        from dailyBySession: [String: [String: AntigravityDailyUsage]],
        calendar: Calendar
    ) -> [AntigravityDailyUsage] {
        DailyUsageAggregation.computeGlobalDaily(from: dailyBySession, calendar: calendar)
    }

    /// 保留最近 7 个本地自然日（含 today），并补齐缺失的日期，使其恒定返回包含 7 天（按日升序）的数组。
    nonisolated static func filterLast7Days(
        allDaily: [AntigravityDailyUsage],
        today: Date,
        calendar: Calendar = .current
    ) -> [AntigravityDailyUsage] {
        DailyUsageAggregation.filterLast7Days(allDaily: allDaily, today: today, calendar: calendar)
    }
}

// MARK: - LocalUsageScanner 协议
// conformance（lastResultPublisher / isScanningPublisher）由 LocalUsageScannerBase 提供。
