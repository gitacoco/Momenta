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
    /// Whether opening the popover triggers a (throttled) refresh, or data
    /// only moves on the manual refresh button. Manual mode protects Toggl's
    /// tight free-plan quota (30 requests/hour) from unintentional queries.
    var autoRefreshOnOpen: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case aggregationPeriod
        case perClientSplit
        case timeZoneIdentifier
        case autoRefreshOnOpen
    }

    // Custom decoding so settings persisted before a field existed keep
    // their values instead of falling back to a full default reset.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aggregationPeriod = try container.decodeIfPresent(AggregationPeriod.self, forKey: .aggregationPeriod) ?? .month
        perClientSplit = try container.decodeIfPresent(Bool.self, forKey: .perClientSplit) ?? false
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        autoRefreshOnOpen = try container.decodeIfPresent(Bool.self, forKey: .autoRefreshOnOpen) ?? true
    }

    var timeZone: TimeZone {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }
}
