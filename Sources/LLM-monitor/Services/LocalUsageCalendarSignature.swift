import Foundation

/// Stable identity of the calendar inputs that determine local-day buckets.
/// Persisting this beside a provider cache prevents a cold start from treating
/// a snapshot grouped under an old time zone as current when the source files
/// themselves have not changed.
enum LocalUsageCalendarSignature {
    static func make(_ calendar: Calendar) -> String {
        let zone = calendar.timeZone
        return [
            String(describing: calendar.identifier),
            zone.identifier
        ].joined(separator: "|")
    }
}
