import Foundation

/// Provider 卡片层的 OpenCode 合并规则。
///
/// 所有合并都遵守同一条规则：token、rounds、turns/prompts 等计数逐字段相加；
/// OpenCode 的 sample promptID 会加命名空间，避免两个本地账本的 ID 碰撞后被错误去重。
enum OpencodeUsageMerger {
    static func opencodeSamples(
        _ usage: OpencodeProviderUsage?,
        providerID: String
    ) -> [LocalTokenUsageSample] {
        guard let usage else { return [] }
        let prefix = "opencode:\(providerID):"
        return usage.recentSamples.map { $0.withPromptIDPrefix(prefix) }
    }

    static func mergeSamples(
        native: [LocalTokenUsageSample],
        opencode: OpencodeProviderUsage?,
        providerID: String
    ) -> [LocalTokenUsageSample] {
        native + opencodeSamples(opencode, providerID: providerID)
    }

    static func mergeMinimax(
        native: MinimaxLocalUsage?,
        opencode: OpencodeProviderUsage?,
        opencodeScannedAt: Date?
    ) -> MinimaxLocalUsage? {
        guard let opencode else { return native }
        let openDays = opencode.dailyTokenUsage.map(Self.minimaxDay)
        let daily = mergeMinimaxDays(native?.dailyTokenUsage ?? [], openDays)
        let today = mergeMinimaxDay(native?.today, opencode.today.map(Self.minimaxDay))

        return MinimaxLocalUsage(
            today: today,
            dailyTokenUsage: daily,
            scannedAt: [native?.scannedAt, opencodeScannedAt].compactMap { $0 }.max(),
            sessionCount: native?.sessionCount ?? 0,
            eventCount: SaturatingArithmetic.add(native?.eventCount ?? 0, opencode.roundCount),
            failedSessionCount: native?.failedSessionCount ?? 0,
            recentSamples: mergeSamples(
                native: native?.recentSamples ?? [],
                opencode: opencode,
                providerID: OpencodeLocalUsage.minimaxCodingPlanProviderID
            )
        )
    }

    static func mergeAntigravity(
        native: AntigravityLocalUsage?,
        opencode: OpencodeProviderUsage?,
        opencodeScannedAt: Date?
    ) -> AntigravityLocalUsage? {
        guard let opencode else { return native }
        let openDays = opencode.dailyTokenUsage.map(Self.antigravityDay)
        let daily = mergeAntigravityDays(native?.dailyTokenUsage ?? [], openDays)
        let today = mergeAntigravityDay(native?.today, opencode.today.map(Self.antigravityDay))

        return AntigravityLocalUsage(
            today: today,
            dailyTokenUsage: daily,
            scannedAt: [native?.scannedAt, opencodeScannedAt].compactMap { $0 }.max(),
            sessionCount: native?.sessionCount ?? 0,
            eventCount: SaturatingArithmetic.add(native?.eventCount ?? 0, opencode.roundCount),
            failedSessionCount: native?.failedSessionCount ?? 0,
            recentSamples: mergeSamples(
                native: native?.recentSamples ?? [],
                opencode: opencode,
                providerID: OpencodeLocalUsage.antigravityProviderIDs.first ?? "antigravity"
            )
        )
    }

    /// GLM 的 native（ZCode）与 OpenCode 分片都是 uncached input + 单列 cacheRead，
    /// 5 类 token 字段一一对应，直接逐字段相加即可。OpenCode sample 的 promptID 加
    /// 命名空间前缀，避免与 ZCode native sample 的 `session_id:turn_id` 撞库后被去重。
    static func mergeGlm(
        native: GlmLocalUsage?,
        opencode: OpencodeProviderUsage?,
        opencodeScannedAt: Date?
    ) -> GlmLocalUsage? {
        guard let opencode else { return native }
        let openDays = opencode.dailyTokenUsage.map(Self.glmDay)
        let daily = mergeGlmDays(native?.dailyTokenUsage ?? [], openDays)
        let today = mergeGlmDay(native?.today, opencode.today.map(Self.glmDay))

        return GlmLocalUsage(
            today: today,
            dailyTokenUsage: daily,
            scannedAt: [native?.scannedAt, opencodeScannedAt].compactMap { $0 }.max(),
            sessionCount: native?.sessionCount ?? 0,
            eventCount: SaturatingArithmetic.add(native?.eventCount ?? 0, opencode.roundCount),
            failedSessionCount: native?.failedSessionCount ?? 0,
            recentSamples: mergeSamples(
                native: native?.recentSamples ?? [],
                opencode: opencode,
                providerID: OpencodeLocalUsage.glmProviderID
            ),
            // 闲时窗口只来自 native ZCode 源（OpenCode 无此概念）
            offPeakWindows: native?.offPeakWindows ?? []
        )
    }

    /// Codex 的 `inputTokens` 是完整 input（含 cache），而 OpenCode 的 input 字段是
    /// uncached input，因此转换时先补上 cacheRead 再合并。
    static func mergeCodexDaily(
        native: [DailyTokenUsage]?,
        opencode: OpencodeProviderUsage?
    ) -> [DailyTokenUsage] {
        let openDays = opencode?.dailyTokenUsage.map(Self.codexDay) ?? []
        return mergeCodexDays(native ?? [], openDays)
    }

    private static func minimaxDay(_ day: OpencodeDailyUsage) -> MinimaxDailyUsage {
        MinimaxDailyUsage(
            dayStart: day.dayStart,
            inputTokens: day.inputTokens,
            outputTokens: day.outputTokens,
            cacheReadTokens: day.cacheReadTokens,
            cacheWriteTokens: day.cacheWriteTokens,
            reasoningTokens: day.reasoningTokens,
            totalTokens: day.totalTokens,
            turns: day.turns,
            rounds: day.rounds
        )
    }

    private static func antigravityDay(_ day: OpencodeDailyUsage) -> AntigravityDailyUsage {
        AntigravityDailyUsage(
            dayStart: day.dayStart,
            inputTokens: day.inputTokens,
            cacheReadTokens: day.cacheReadTokens,
            cacheWriteTokens: day.cacheWriteTokens,
            outputTokens: day.outputTokens,
            reasoningTokens: day.reasoningTokens,
            totalTokens: day.totalTokens,
            turns: day.turns,
            rounds: day.rounds
        )
    }

    private static func glmDay(_ day: OpencodeDailyUsage) -> GlmDailyUsage {
        GlmDailyUsage(
            dayStart: day.dayStart,
            inputTokens: day.inputTokens,
            outputTokens: day.outputTokens,
            cacheReadTokens: day.cacheReadTokens,
            cacheWriteTokens: day.cacheWriteTokens,
            reasoningTokens: day.reasoningTokens,
            totalTokens: day.totalTokens,
            turns: day.turns,
            rounds: day.rounds
        )
    }

    private static func codexDay(_ day: OpencodeDailyUsage) -> DailyTokenUsage {
        DailyTokenUsage(
            dayStart: day.dayStart,
            inputTokens: SaturatingArithmetic.add(day.inputTokens, day.cacheReadTokens),
            cachedInputTokens: day.cacheReadTokens,
            outputTokens: day.outputTokens,
            reasoningOutputTokens: day.reasoningTokens,
            rounds: day.rounds,
            turns: day.turns
        )
    }

    private static func mergeMinimaxDays(
        _ lhs: [MinimaxDailyUsage],
        _ rhs: [MinimaxDailyUsage]
    ) -> [MinimaxDailyUsage] {
        var byDay = Dictionary(uniqueKeysWithValues: lhs.map { ($0.dayStart, $0) })
        for day in rhs {
            byDay[day.dayStart] = byDay[day.dayStart].map { $0 + day } ?? day
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    private static func mergeAntigravityDays(
        _ lhs: [AntigravityDailyUsage],
        _ rhs: [AntigravityDailyUsage]
    ) -> [AntigravityDailyUsage] {
        var byDay = Dictionary(uniqueKeysWithValues: lhs.map { ($0.dayStart, $0) })
        for day in rhs {
            byDay[day.dayStart] = byDay[day.dayStart].map { $0 + day } ?? day
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    private static func mergeGlmDays(
        _ lhs: [GlmDailyUsage],
        _ rhs: [GlmDailyUsage]
    ) -> [GlmDailyUsage] {
        var byDay = Dictionary(uniqueKeysWithValues: lhs.map { ($0.dayStart, $0) })
        for day in rhs {
            byDay[day.dayStart] = byDay[day.dayStart].map { $0 + day } ?? day
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    private static func mergeCodexDays(
        _ lhs: [DailyTokenUsage],
        _ rhs: [DailyTokenUsage]
    ) -> [DailyTokenUsage] {
        var byDay = Dictionary(uniqueKeysWithValues: lhs.map { ($0.dayStart, $0) })
        for day in rhs {
            if let existing = byDay[day.dayStart] {
                byDay[day.dayStart] = DailyTokenUsage(
                    dayStart: day.dayStart,
                    inputTokens: SaturatingArithmetic.add(existing.inputTokens, day.inputTokens),
                    cachedInputTokens: SaturatingArithmetic.add(
                        existing.cachedInputTokens,
                        day.cachedInputTokens
                    ),
                    outputTokens: SaturatingArithmetic.add(existing.outputTokens, day.outputTokens),
                    reasoningOutputTokens: SaturatingArithmetic.add(
                        existing.reasoningOutputTokens,
                        day.reasoningOutputTokens
                    ),
                    rounds: SaturatingArithmetic.add(existing.rounds, day.rounds),
                    turns: SaturatingArithmetic.add(existing.turns, day.turns)
                )
            } else {
                byDay[day.dayStart] = day
            }
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    private static func mergeMinimaxDay(
        _ lhs: MinimaxDailyUsage?,
        _ rhs: MinimaxDailyUsage?
    ) -> MinimaxDailyUsage? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return lhs + rhs
        case let (value?, nil), let (nil, value?): return value
        case (nil, nil): return nil
        }
    }

    private static func mergeAntigravityDay(
        _ lhs: AntigravityDailyUsage?,
        _ rhs: AntigravityDailyUsage?
    ) -> AntigravityDailyUsage? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return lhs + rhs
        case let (value?, nil), let (nil, value?): return value
        case (nil, nil): return nil
        }
    }

    private static func mergeGlmDay(
        _ lhs: GlmDailyUsage?,
        _ rhs: GlmDailyUsage?
    ) -> GlmDailyUsage? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return lhs + rhs
        case let (value?, nil), let (nil, value?): return value
        case (nil, nil): return nil
        }
    }
}
