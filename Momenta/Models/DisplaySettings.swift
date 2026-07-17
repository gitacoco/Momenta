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

    var menuBarLabel: String {
        switch self {
        case .day: return "today"
        case .week: return "week"
        case .month: return "month"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .day: return "Today"
        case .week: return "This week"
        case .month: return "This month"
        }
    }
}

enum MenuBarObjectMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case aggregation
    case split
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .aggregation: return "Overall"
        case .split: return "By Client"
        case .both: return "Overall + Clients"
        }
    }
}

enum MenuBarVisualization: String, Codable, CaseIterable, Identifiable, Sendable {
    case ring
    case waterline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ring: return "Ring"
        case .waterline: return "Waterline"
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
    var menuBarObjectMode: MenuBarObjectMode = .aggregation
    var menuBarVisualization: MenuBarVisualization = .ring
    var showsOverallPercentage: Bool = false
    /// nil follows the system time zone.
    var timeZoneIdentifier: String?
    /// Whether opening the popover triggers a (throttled) refresh, or data
    /// only moves on the manual refresh button. Manual mode protects Toggl's
    /// tight free-plan quota (30 requests/hour) from unintentional queries.
    var autoRefreshOnOpen: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case aggregationPeriod
        case menuBarObjectMode
        case menuBarVisualization
        case showsOverallPercentage
        // Read-only compatibility with settings written before object modes.
        case perClientSplit
        case timeZoneIdentifier
        case autoRefreshOnOpen
    }

    // Custom decoding so settings persisted before a field existed keep
    // their values instead of falling back to a full default reset.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aggregationPeriod =
            (try? container.decode(AggregationPeriod.self, forKey: .aggregationPeriod)) ?? .month

        let legacySplit =
            (try? container.decode(Bool.self, forKey: .perClientSplit)) ?? false
        menuBarObjectMode =
            (try? container.decode(MenuBarObjectMode.self, forKey: .menuBarObjectMode))
            ?? (legacySplit ? .split : .aggregation)
        menuBarVisualization =
            (try? container.decode(MenuBarVisualization.self, forKey: .menuBarVisualization)) ?? .ring
        showsOverallPercentage =
            (try? container.decode(Bool.self, forKey: .showsOverallPercentage)) ?? false

        timeZoneIdentifier = try? container.decode(String.self, forKey: .timeZoneIdentifier)
        autoRefreshOnOpen =
            (try? container.decode(Bool.self, forKey: .autoRefreshOnOpen)) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(aggregationPeriod, forKey: .aggregationPeriod)
        try container.encode(menuBarObjectMode, forKey: .menuBarObjectMode)
        try container.encode(menuBarVisualization, forKey: .menuBarVisualization)
        try container.encode(showsOverallPercentage, forKey: .showsOverallPercentage)
        try container.encodeIfPresent(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try container.encode(autoRefreshOnOpen, forKey: .autoRefreshOnOpen)
    }

    var timeZone: TimeZone {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }
}
