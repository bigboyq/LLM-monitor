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
    case agy

    var clientID: String {
        switch self {
        case .codex: return ClientID.codex
        case .antigravity: return ClientID.antigravity
        case .minimaxCode: return ClientID.minimaxCode
        case .zcode: return ClientID.zcode
        case .dsh: return ClientID.dsh
        case .opencode: return ClientID.openCode
        case .agy: return ClientID.agy
        }
    }
}

/// One local scanner source as consumed by a quota-provider status. Shared
/// sources such as DSH, OpenCode, and ZCode can have several consumer rows.
struct LocalUsageConsumer: Equatable, Hashable, Sendable {
    let source: LocalUsageSource
    let clientID: String
    let quotaProviderID: String

    init(source: LocalUsageSource, quotaProviderID: String) {
        self.source = source
        self.clientID = source.clientID
        self.quotaProviderID = quotaProviderID
    }

    var sourceKey: String {
        "\(clientID)|\(quotaProviderID)"
    }
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
