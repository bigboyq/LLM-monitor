import Foundation

/// Freshness of local token usage data. This is deliberately independent from
/// quota health: a provider can have healthy quota while its local usage is
/// dirty (or still being scanned).
enum LocalUsageFreshness: String, Equatable, Sendable {
    case clean
    case dirty
    case scanning
    case failed

    /// Used when several local sources contribute to one provider card.
    /// Scanning wins so the UI stays yellow while work is in flight; a failed
    /// source is otherwise more important than merely stale data.
    fileprivate var priority: Int {
        switch self {
        case .clean:    return 0
        case .dirty:    return 1
        case .failed:   return 2
        case .scanning: return 3
        }
    }
}

/// Stable identities for local usage producers. A source is intentionally
/// separate from both `ProviderKind` and `ClientID`: OpenCode and DSH are
/// shared sources consumed by multiple provider cards.
enum LocalUsageSource: String, CaseIterable, Hashable, Sendable {
    case codex
    case antigravity
    case minimaxCode
    case zcode
    case dsh
    case opencode
}

/// Value-type storage for source freshness on `ProviderStatus`.
///
/// Missing entries mean `.clean`, which keeps existing callers source
/// compatible until AppState starts writing freshness transitions explicitly.
struct LocalUsageFreshnessSnapshot: Equatable, Sendable {
    private var states: [LocalUsageSource: LocalUsageFreshness]

    init(states: [LocalUsageSource: LocalUsageFreshness] = [:]) {
        self.states = states
    }

    static let clean = Self()

    subscript(source: LocalUsageSource) -> LocalUsageFreshness {
        get { states[source] ?? .clean }
        set { states[source] = newValue }
    }

    func resolved(for sources: [LocalUsageSource]) -> LocalUsageFreshness {
        sources
            .map { self[$0] }
            .max { $0.priority < $1.priority } ?? .clean
    }
}
