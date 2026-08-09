import Foundation

/// Provider-independent presence state for a quota window.
///
/// Provider APIs may use different raw status codes (for example, Minimax uses
/// `2` for an existing but exhausted window). Fetchers must normalize those
/// codes at their boundary. The UI and shared quota logic only care whether a
/// window exists; exhaustion is represented by the remaining percentage.
enum QuotaWindowStatus: Int, Codable, Equatable, Sendable {
    case absent = 0
    case present = 1

    var isPresent: Bool {
        self == .present
    }

    /// Keep old snapshots readable: any legacy/provider-specific non-present
    /// code (for example Minimax's raw `3`) is normalized to `.absent`.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try container.decode(Int.self) == Self.present.rawValue ? .present : .absent
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
