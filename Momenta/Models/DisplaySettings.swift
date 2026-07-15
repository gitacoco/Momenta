import Foundation

enum AggregationPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }
}

/// Chart/metric unit toggle. View state only, never persisted.
enum DisplayUnit: String, CaseIterable, Identifiable, Sendable {
    case revenue
    case hours

    var id: String { rawValue }

    var label: String {
        switch self {
        case .revenue: return "$"
        case .hours: return "h"
        }
    }
}

struct DisplaySettings: Hashable, Codable, Sendable {
    var aggregationPeriod: AggregationPeriod = .month
    var perClientSplit: Bool = false
    /// nil follows the system time zone.
    var timeZoneIdentifier: String?

    var timeZone: TimeZone {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }
}
