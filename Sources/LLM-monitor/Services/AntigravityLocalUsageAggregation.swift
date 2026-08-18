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
    struct TurnRoundDetails: Equatable, Sendable {
        let counts: AntigravityTurnRoundCounts
        let samples: [LocalTokenUsageSample]
    }

    /// eventCount 的统一口径：只有带 timestamp、真正进入日统计的事件才计数。
    /// 无 timestamp 的 event 进不了 daily / turns / rounds / samples，也不得计入
    /// eventCount —— 一个字段不得同时代表“收到的 raw event 数”和“入账 event 数”。
    /// raw 总数保留在 scanner 的 debug 日志里，用于诊断 RPC 返回质量。
    nonisolated static func accountedEventStats(
        _ events: [AntigravityFetcher.UsageEvent]
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
    /// `counts` 可传入调用方已经预算好的 per-day turns/rounds（避免 scanner 成功分支里
    /// 把同一份 counts 再叠加一次造成双倍计数）；未传时由本函数自行计算，保持原有契约。
    nonisolated static func aggregateDaily(
        events: [AntigravityFetcher.UsageEvent],
        calendar: Calendar,
        counts: AntigravityTurnRoundCounts? = nil
    ) -> [String: AntigravityDailyUsage] {
        let resolvedCounts = counts ?? computeTurnRoundCounts(sessionID: "", events: events, calendar: calendar)
        var byDay: [String: AntigravityDailyUsage] = [:]
        for event in events {
            guard let timestamp = event.timestamp else { continue }
            let dayStart = calendar.startOfDay(for: timestamp)
            let key = LocalUsageDayKey.make(dayStart, calendar: calendar)
            let existing = byDay[key] ?? AntigravityDailyUsage(
                dayStart: dayStart,
                turns: resolvedCounts.perDay[dayStart]?.turns ?? 0,
                rounds: resolvedCounts.perDay[dayStart]?.rounds ?? 0
            )
            byDay[key] = AntigravityDailyUsage(
                dayStart: dayStart,
                inputTokens: SaturatingArithmetic.add(existing.inputTokens, event.inputTokens),
                cacheReadTokens: SaturatingArithmetic.add(existing.cacheReadTokens, event.cacheReadTokens),
                cacheWriteTokens: SaturatingArithmetic.add(existing.cacheWriteTokens, event.cacheWriteTokens),
                outputTokens: SaturatingArithmetic.add(existing.outputTokens, event.outputTokens),
                reasoningTokens: SaturatingArithmetic.add(existing.reasoningTokens, event.reasoningTokens),
                totalTokens: SaturatingArithmetic.add(existing.totalTokens, event.totalTokens),
                turns: existing.turns,
                rounds: existing.rounds
            )
        }
        return byDay
    }

    /// 纯 RPC 模式：基于 RPC 事件推算 per-day turns / rounds 计数。
    nonisolated static func computeTurnRoundCounts(
        sessionID: String,
        events: [AntigravityFetcher.UsageEvent],
        calendar: Calendar
    ) -> AntigravityTurnRoundCounts {
        computeTurnRoundDetails(
            sessionID: sessionID,
            events: events,
            calendar: calendar
        ).counts
    }

    /// 纯基于 RPC 事件生成 Turn/Round 明细及样本组，不再依赖 SQLite .db 读取。
    /// 区分 Prompt (Turn) 与 LLM Call (Round)：根据 stepIndices 的间隙推算新 User Prompt 节点。
    nonisolated static func computeTurnRoundDetails(
        sessionID: String,
        events: [AntigravityFetcher.UsageEvent],
        calendar: Calendar
    ) -> TurnRoundDetails {
        let sortedEvents = events
            .filter { $0.timestamp != nil }
            .sorted { $0.timestamp! < $1.timestamp! }

        var perDay: [Date: DailyTurnRound] = [:]
        var prevMaxStepIndex: Int? = nil

        for event in sortedEvents {
            guard let ts = event.timestamp else { continue }
            let day = calendar.startOfDay(for: ts)
            let existing = perDay[day] ?? DailyTurnRound(turns: 0, rounds: 0)

            var isNewTurn = false
            if let indices = event.stepIndices, let minIdx = indices.min(), let maxIdx = indices.max() {
                if let prevMax = prevMaxStepIndex {
                    if minIdx > prevMax + 1 {
                        isNewTurn = true
                    }
                } else {
                    isNewTurn = true
                }
                prevMaxStepIndex = max(prevMaxStepIndex ?? maxIdx, maxIdx)
            } else if prevMaxStepIndex == nil {
                isNewTurn = true
            }

            perDay[day] = DailyTurnRound(
                turns: SaturatingArithmetic.add(existing.turns, isNewTurn ? 1 : 0),
                rounds: SaturatingArithmetic.add(existing.rounds, 1)
            )
        }

        let samples = fallbackSamples(sessionID: sessionID, events: sortedEvents)
        return TurnRoundDetails(
            counts: AntigravityTurnRoundCounts(perDay: perDay),
            samples: samples
        )
    }

    nonisolated static func fallbackSamples(
        sessionID: String,
        events: [AntigravityFetcher.UsageEvent]
    ) -> [LocalTokenUsageSample] {
        let sortedEvents = events
            .filter { $0.timestamp != nil }
            .sorted { $0.timestamp! < $1.timestamp! }

        var turnIndex = 0
        var prevMaxStepIndex: Int? = nil

        return sortedEvents.map { event in
            var isNewTurn = false
            if let indices = event.stepIndices, let minIdx = indices.min(), let maxIdx = indices.max() {
                if let prevMax = prevMaxStepIndex {
                    if minIdx > prevMax + 1 {
                        isNewTurn = true
                    }
                } else {
                    isNewTurn = true
                }
                prevMaxStepIndex = max(prevMaxStepIndex ?? maxIdx, maxIdx)
            } else if prevMaxStepIndex == nil {
                isNewTurn = true
            }

            if isNewTurn {
                turnIndex += 1
            }

            return makeSample(
                sessionID: sessionID,
                promptComponent: "turn-\(turnIndex)",
                event: event
            )
        }
    }

    private nonisolated static func makeSample(
        sessionID: String,
        promptComponent: String,
        event: AntigravityFetcher.UsageEvent
    ) -> LocalTokenUsageSample {
        // Antigravity events report uncached input and cache-read separately.
        // Samples keep the historical cache-inclusive input field; the daily
        // adapter and TokenUsageBuckets split it for UI/pricing.
        LocalTokenUsageSample(
            completedAt: event.timestamp ?? .distantPast,
            modelName: event.model,
            promptID: "\(sessionID):\(promptComponent)",
            inputTokens: SaturatingArithmetic.add(event.inputTokens, event.cacheReadTokens),
            cachedInputTokens: event.cacheReadTokens,
            outputTokens: event.outputTokens,
            reasoningOutputTokens: event.reasoningTokens
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

    nonisolated static func todayCutoff(now: Date, calendar: Calendar) -> Date {
        DailyUsageAggregation.todayCutoff(now: now, calendar: calendar)
    }
}

// MARK: - LocalUsageScanner 协议
// conformance（lastResultPublisher / isScanningPublisher）由 LocalUsageScannerBase 提供。
