import Foundation

/// Provider-card merge rules for DeepSeek Harness session usage.
///
/// dsh is a shared local ledger and may contain more than one provider route. The
/// scanner keeps the original provider ID and this layer selects the route slices
/// that correspond to the existing provider cards.
enum DshUsageMerger {
    static let deepseekProviderIDs = ["deepseek", "deepseek-official", "deepseek-cn", "deepseek-v4"]
    static let minimaxProviderIDs = ["minimax", "minimax-cn", "minimax-cn-coding-plan"]
    static let glmProviderIDs = ["glm", "zhipu", "zhipuai", "bigmodel", "builtin:bigmodel-coding-plan"]

    static func deepseekSlice(_ usage: DshLocalUsage?) -> DshProviderUsage? {
        slice(usage, matching: deepseekProviderIDs)
    }

    static func minimaxSlice(_ usage: DshLocalUsage?) -> DshProviderUsage? {
        slice(usage, matching: minimaxProviderIDs)
    }

    static func glmSlice(_ usage: DshLocalUsage?) -> DshProviderUsage? {
        slice(usage, matching: glmProviderIDs)
    }

    /// Convert dsh's exact native usage slice to the shared card-layer shape and
    /// optionally add the matching OpenCode slice. Both sources are kept
    /// namespaced at the sample level to avoid prompt-ID collisions.
    static func mergeDeepseek(
        dsh: DshLocalUsage?,
        opencode: OpencodeProviderUsage?
    ) -> OpencodeProviderUsage? {
        merge(native: nil, dshSlice: deepseekSlice(dsh), opencode: opencode)
    }

    static func mergeMinimax(
        native: MinimaxLocalUsage? = nil,
        dsh: DshLocalUsage? = nil,
        opencode: OpencodeProviderUsage? = nil
    ) -> OpencodeProviderUsage? {
        let nativeOpencode = native.map(Self.opencodeProvider)
        return merge(
            native: nativeOpencode,
            dshSlice: minimaxSlice(dsh),
            opencode: opencode
        )
    }

    static func mergeGlm(
        native: GlmLocalUsage? = nil,
        dsh: DshLocalUsage? = nil,
        opencode: OpencodeProviderUsage? = nil
    ) -> OpencodeProviderUsage? {
        let nativeOpencode = native.map(Self.opencodeProvider)
        return merge(
            native: nativeOpencode,
            dshSlice: glmSlice(dsh),
            opencode: opencode
        )
    }

    static func dshSamples(_ usage: DshProviderUsage?) -> [LocalTokenUsageSample] {
        guard let usage else { return [] }
        return usage.recentSamples.map { sample in
            let source = sample.sourceProviderID ?? "unknown"
            return sample.withPromptIDPrefix("dsh:\(source):")
        }
    }

    private static func slice(
        _ usage: DshLocalUsage?,
        matching aliases: [String]
    ) -> DshProviderUsage? {
        guard let usage else { return nil }
        let selected = usage.byProvider.filter { key, _ in
            matches(key, aliases: aliases)
        }
        guard !selected.isEmpty else { return nil }
        var daily: [Date: DshDailyUsage] = [:]
        var sessionCount = 0
        var samples: [LocalTokenUsageSample] = []
        var roundCount = 0
        for (_, value) in selected {
            if let today = value.today,
               value.dailyTokenUsage.contains(where: { $0.dayStart == today.dayStart }) == false {
                daily[today.dayStart] = today
            }
            for day in value.dailyTokenUsage {
                daily[day.dayStart] = daily[day.dayStart].map { $0 + day } ?? day
            }
            sessionCount = SaturatingArithmetic.add(sessionCount, value.sessionCount)
            samples.append(contentsOf: value.recentSamples)
            roundCount = SaturatingArithmetic.add(roundCount, value.roundCount)
        }
        let sortedDaily = daily.values.sorted { $0.dayStart < $1.dayStart }
        return DshProviderUsage(
            today: sortedDaily.last.flatMap { $0.hasActivity ? $0 : nil },
            dailyTokenUsage: sortedDaily,
            sessionCount: sessionCount,
            roundCount: roundCount,
            recentSamples: samples
        )
    }

    private static func matches(_ providerID: String, aliases: [String]) -> Bool {
        let value = providerID.lowercased()
        return aliases.contains { alias in
            let needle = alias.lowercased()
            return value == needle || value.contains(needle)
        }
    }

    private static func merge(
        native: OpencodeProviderUsage?,
        dshSlice: DshProviderUsage?,
        opencode: OpencodeProviderUsage?
    ) -> OpencodeProviderUsage? {
        guard native != nil || dshSlice != nil || opencode != nil else { return nil }
        let daily = mergeDaily(
            native?.dailyTokenUsage ?? [],
            dshSlice?.dailyTokenUsage ?? [],
            opencode?.dailyTokenUsage ?? []
        )
        let today = mergeToday(native?.today, dshSlice?.today, opencode?.today)
        return OpencodeProviderUsage(
            today: today,
            dailyTokenUsage: daily,
            roundCount: SaturatingArithmetic.sum(
                native?.roundCount ?? 0,
                dshSlice?.roundCount ?? 0,
                opencode?.roundCount ?? 0
            ),
            cost: (native?.cost ?? 0) + (opencode?.cost ?? 0),
            recentSamples: (native?.recentSamples ?? [])
                + dshSamples(dshSlice)
                + OpencodeUsageMerger.opencodeSamples(opencode, providerID: "opencode")
        )
    }

    private static func mergeDaily(
        _ native: [OpencodeDailyUsage],
        _ dsh: [DshDailyUsage],
        _ opencode: [OpencodeDailyUsage]
    ) -> [OpencodeDailyUsage] {
        var byDay: [Date: OpencodeDailyUsage] = [:]
        for day in native {
            byDay[day.dayStart] = byDay[day.dayStart].map { $0 + day } ?? day
        }
        for day in dsh {
            byDay[day.dayStart] = byDay[day.dayStart].map { $0 + Self.opencodeDay(day) }
                ?? Self.opencodeDay(day)
        }
        for day in opencode {
            byDay[day.dayStart] = byDay[day.dayStart].map { $0 + day } ?? day
        }
        return byDay.values.sorted { $0.dayStart < $1.dayStart }
    }

    private static func mergeToday(
        _ native: OpencodeDailyUsage?,
        _ dsh: DshDailyUsage?,
        _ opencode: OpencodeDailyUsage?
    ) -> OpencodeDailyUsage? {
        let nativeDay = native
        switch (nativeDay, dsh, opencode) {
        case let (nativeDay?, dsh?, opencode?): return nativeDay + Self.opencodeDay(dsh) + opencode
        case let (nativeDay?, dsh?, nil): return nativeDay + Self.opencodeDay(dsh)
        case let (nativeDay?, nil, opencode?): return nativeDay + opencode
        case let (nativeDay?, nil, nil): return nativeDay
        case let (nil, dsh?, opencode?): return Self.opencodeDay(dsh) + opencode
        case let (nil, dsh?, nil): return Self.opencodeDay(dsh)
        case let (nil, nil, opencode?): return opencode
        case (nil, nil, nil): return nil
        }
    }


    private static func opencodeProvider(_ native: MinimaxLocalUsage) -> OpencodeProviderUsage {
        let daily = native.dailyTokenUsage.map(Self.opencodeDayFromMinimax)
        return OpencodeProviderUsage(
            today: native.today.map(Self.opencodeDayFromMinimax),
            dailyTokenUsage: daily,
            roundCount: native.eventCount,
            cost: 0,
            recentSamples: native.recentSamples ?? []
        )
    }

    private static func opencodeProvider(_ native: GlmLocalUsage) -> OpencodeProviderUsage {
        let daily = native.dailyTokenUsage.map(Self.opencodeDayFromGlm)
        return OpencodeProviderUsage(
            today: native.today.map(Self.opencodeDayFromGlm),
            dailyTokenUsage: daily,
            roundCount: native.eventCount,
            cost: 0,
            recentSamples: native.recentSamples ?? []
        )
    }

    private static func opencodeDayFromMinimax(_ day: MinimaxDailyUsage) -> OpencodeDailyUsage {
        OpencodeDailyUsage(
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

    private static func opencodeDayFromGlm(_ day: GlmDailyUsage) -> OpencodeDailyUsage {
        OpencodeDailyUsage(
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

    private static func opencodeDay(_ day: DshDailyUsage) -> OpencodeDailyUsage {
        OpencodeDailyUsage(
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
}
