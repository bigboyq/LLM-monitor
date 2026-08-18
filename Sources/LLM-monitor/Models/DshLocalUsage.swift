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
///   DSH MiniMax-M3 may use an internal message-content character estimate when
///   the provider omits `reasoningTokens`; other missing splits remain Reason=0.
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

