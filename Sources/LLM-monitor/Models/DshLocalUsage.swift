import Foundation

/// DeepSeek Harness (dsh) session-log token usage.
///
/// dsh persists each session as an append-only JSONL artifact under `$DSH_HOME/sessions`.
/// The durable log records provider-billed usage on every `assistant/message` event, so
/// this view can use exact usage buckets rather than the heuristic used by
/// `@deepseek-ai/dsh-token-meter` when provider usage is absent.
///
/// Token semantics follow dsh's own `tokenUsage` projection:
/// - `inputTokens` is the uncached prompt input (`uncachedInputTokens`);
/// - `cacheReadTokens` is a separate cache-read bucket;
/// - `cacheWriteTokens` is reported but excluded from the displayed consumption total;
/// - `outputTokens` includes reasoning. The UI splits that inclusive output into
///   visible output and reasoning, with `output + reasoning == raw dsh output`.
///
/// The snapshot is split by the provider recorded in the session's `request/context`.
/// Keeping that split lets a dsh session using multiple providers be merged into the
/// corresponding provider cards without mixing DeepSeek and MiniMax usage.
struct DshLocalUsage: Equatable, Codable, Sendable {
    let byProvider: [String: DshProviderUsage]
    let modelsByProvider: [String: [String]]
    let sessionsRoot: String?
    let sessionCount: Int
    let eventCount: Int
    let scannedAt: Date?

    static let empty = DshLocalUsage(
        byProvider: [:],
        modelsByProvider: [:],
        sessionsRoot: nil,
        sessionCount: 0,
        eventCount: 0,
        scannedAt: nil
    )

    /// Exclude scan metadata from equality so a successful re-scan does not publish a
    /// new UI state solely because `scannedAt` changed.
    static func == (lhs: DshLocalUsage, rhs: DshLocalUsage) -> Bool {
        lhs.byProvider == rhs.byProvider
            && lhs.modelsByProvider == rhs.modelsByProvider
            && lhs.sessionsRoot == rhs.sessionsRoot
            && lhs.sessionCount == rhs.sessionCount
            && lhs.eventCount == rhs.eventCount
    }
}

struct DshProviderUsage: Equatable, Codable, Sendable {
    let today: DshDailyUsage?
    let dailyTokenUsage: [DshDailyUsage]
    let sessionCount: Int
    let roundCount: Int
    let recentSamples: [LocalTokenUsageSample]
}

/// One local calendar day from dsh's append-only session log.
struct DshDailyUsage: Equatable, Codable, Sendable, Identifiable {
    let dayStart: Date
    let inputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let turns: Int
    let rounds: Int

    var id: Date { dayStart }

    init(
        dayStart: Date,
        inputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningTokens: Int = 0,
        totalTokens: Int = 0,
        turns: Int = 0,
        rounds: Int = 0
    ) {
        self.dayStart = dayStart
        self.inputTokens = inputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.turns = turns
        self.rounds = rounds
    }

    var hasActivity: Bool {
        inputTokens > 0
            || cacheReadTokens > 0
            || cacheWriteTokens > 0
            || outputTokens > 0
            || reasoningTokens > 0
            || rounds > 0
            || turns > 0
    }

    /// Merge two provider/day slices with saturating arithmetic. Cache write is
    /// intentionally kept out of `totalTokens`, matching dsh's projection.
    static func + (lhs: DshDailyUsage, rhs: DshDailyUsage) -> DshDailyUsage {
        DshDailyUsage(
            dayStart: lhs.dayStart,
            inputTokens: SaturatingArithmetic.add(lhs.inputTokens, rhs.inputTokens),
            cacheReadTokens: SaturatingArithmetic.add(lhs.cacheReadTokens, rhs.cacheReadTokens),
            cacheWriteTokens: SaturatingArithmetic.add(lhs.cacheWriteTokens, rhs.cacheWriteTokens),
            outputTokens: SaturatingArithmetic.add(lhs.outputTokens, rhs.outputTokens),
            reasoningTokens: SaturatingArithmetic.add(lhs.reasoningTokens, rhs.reasoningTokens),
            totalTokens: SaturatingArithmetic.add(lhs.totalTokens, rhs.totalTokens),
            turns: SaturatingArithmetic.add(lhs.turns, rhs.turns),
            rounds: SaturatingArithmetic.add(lhs.rounds, rhs.rounds)
        )
    }
}

extension DshDailyUsage: DailyUsageAddable {
    init(dayStart: Date) {
        self.init(
            dayStart: dayStart,
            inputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            totalTokens: 0,
            turns: 0,
            rounds: 0
        )
    }

    func withDayStart(_ date: Date) -> DshDailyUsage {
        DshDailyUsage(
            dayStart: date,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            totalTokens: totalTokens,
            turns: turns,
            rounds: rounds
        )
    }
}
