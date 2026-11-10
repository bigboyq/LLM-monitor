import Foundation

/// nil selection means the global relay aggregate. A selection always identifies
/// one provider and one independent quota pool; labels never serve as identifiers.
struct StatusBarQuotaSelection: Codable, Equatable, Sendable {
    var providerID: String
    var source: StatusBarQuotaSource = .plan

    init(providerID: String, source: StatusBarQuotaSource = .plan) {
        self.providerID = providerID
        self.source = source
    }

    private enum CodingKeys: String, CodingKey { case providerID, source }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(String.self, forKey: .providerID)
        source = try container.decodeIfPresent(StatusBarQuotaSource.self, forKey: .source) ?? .plan
    }
}

enum StatusBarQuotaSource: Equatable, Hashable, Sendable, Codable {
    case plan
    case apiCredit(keyID: String)
    case activityPlan(planID: String, entitlementID: String)

    var fallbackTitle: String {
        switch self {
        case .plan: return "主套餐"
        case .apiCredit: return "API额度"
        case .activityPlan: return "Start Plan"
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, keyID, planID, entitlementID }
    private enum Kind: String, Codable { case plan, apiCredit, activityPlan }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .plan: self = .plan
        case .apiCredit:
            self = .apiCredit(keyID: try container.decode(String.self, forKey: .keyID))
        case .activityPlan:
            self = .activityPlan(
                planID: try container.decode(String.self, forKey: .planID),
                entitlementID: try container.decode(String.self, forKey: .entitlementID)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .plan:
            try container.encode(Kind.plan, forKey: .kind)
        case .apiCredit(let keyID):
            try container.encode(Kind.apiCredit, forKey: .kind)
            try container.encode(keyID, forKey: .keyID)
        case .activityPlan(let planID, let entitlementID):
            try container.encode(Kind.activityPlan, forKey: .kind)
            try container.encode(planID, forKey: .planID)
            try container.encode(entitlementID, forKey: .entitlementID)
        }
    }
}

struct StatusBarQuotaOption: Identifiable, Equatable, Sendable {
    let source: StatusBarQuotaSource
    let title: String
    var id: StatusBarQuotaSource { source }
}
