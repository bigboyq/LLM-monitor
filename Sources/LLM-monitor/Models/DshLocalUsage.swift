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
    /// Optional so older persisted snapshots decode unchanged. A partial
    /// result is displayable but must not be promoted to clean freshness.
    var isPartial: Bool? = nil
    /// Optional so older persisted snapshots decode unchanged. True when the
    /// session-file count or raw-byte budget cut the scanned source set short
    /// (oldest sessions excluded), so the totals below undercount what is on
    /// disk. Unlike `isPartial` — which marks failed reads — a truncated scan
    /// is a normal, complete scan of a deliberately reduced file set, so it is
    /// part of the result's meaning rather than a freshness flag (and unlike
    /// `isPartial` it participates in `==`).
    var isTruncated: Bool? = nil

    static let empty = DshLocalUsage(
        byProvider: [:],
        modelsByProvider: [:],
        sessionsRoot: nil,
        sessionCount: 0,
        eventCount: 0,
        scannedAt: nil
    )

    /// Exclude scan metadata from equality so a successful re-scan does not publish a
    /// new UI state solely because `scannedAt` changed. `isPartial` is excluded too:
    /// partialness travels through the freshness channel (`scanResultIsComplete`),
    /// not result content. `isTruncated` stays in equality because there is no such
    /// side channel — it qualifies the numbers themselves, so a truncation flip must
    /// be able to republish.
    static func == (lhs: DshLocalUsage, rhs: DshLocalUsage) -> Bool {
        lhs.byProvider == rhs.byProvider
            && lhs.modelsByProvider == rhs.modelsByProvider
            && lhs.sessionsRoot == rhs.sessionsRoot
            && lhs.sessionCount == rhs.sessionCount
            && lhs.eventCount == rhs.eventCount
            && lhs.isTruncated == rhs.isTruncated
    }
}

struct DshProviderUsage: Equatable, Codable, Sendable {
    let today: DshDailyUsage?
    let dailyTokenUsage: [DshDailyUsage]
    let sessionCount: Int
    let roundCount: Int
    let recentSamples: [LocalTokenUsageSample]
}
