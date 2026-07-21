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

/// How the app decides when to pull fresh data. Manual mode protects Toggl's
/// tight free-plan quota (30 requests/hour); interval mode spends it on a
/// predictable schedule the user picks.
enum RefreshMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case onOpen
    case interval
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .onOpen: return "When the popover opens"
        case .interval: return "On a set interval"
        case .manual: return "Manually only"
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
    /// When the app pulls fresh data. See `RefreshMode`.
    var refreshMode: RefreshMode = .onOpen
    /// Minutes between automatic refreshes while in `.interval` mode. Kept
    /// inside `refreshIntervalRange` so the schedule can never outrun Toggl's
    /// 30 requests/hour quota.
    var refreshIntervalMinutes: Int = defaultRefreshIntervalMinutes

    /// Allowed spacing for interval refreshes, in minutes.
    static let refreshIntervalRange: ClosedRange<Int> = 5...240
    static let defaultRefreshIntervalMinutes = 15

    /// Passive (non-user-initiated) fetches — popover open, day rollover,
    /// week-neighbor prep — happen in every mode except manual.
    var allowsPassiveFetch: Bool { refreshMode != .manual }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case aggregationPeriod
        case menuBarObjectMode
        case menuBarVisualization
        case showsOverallPercentage
        // Read-only compatibility with settings written before object modes.
        case perClientSplit
        case timeZoneIdentifier
        case refreshMode
        case refreshIntervalMinutes
        // Read-only compatibility with the boolean that predated RefreshMode.
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

        // Prefer the new mode; fall back to the legacy boolean so settings
        // written before RefreshMode keep on-open vs. manual behavior.
        if let mode = try? container.decode(RefreshMode.self, forKey: .refreshMode) {
            refreshMode = mode
        } else {
            let legacyAutoRefresh =
                (try? container.decode(Bool.self, forKey: .autoRefreshOnOpen)) ?? true
            refreshMode = legacyAutoRefresh ? .onOpen : .manual
        }

        let minutes =
            (try? container.decode(Int.self, forKey: .refreshIntervalMinutes))
            ?? Self.defaultRefreshIntervalMinutes
        refreshIntervalMinutes = minutes.clamped(to: Self.refreshIntervalRange)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(aggregationPeriod, forKey: .aggregationPeriod)
        try container.encode(menuBarObjectMode, forKey: .menuBarObjectMode)
        try container.encode(menuBarVisualization, forKey: .menuBarVisualization)
        try container.encode(showsOverallPercentage, forKey: .showsOverallPercentage)
        try container.encodeIfPresent(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try container.encode(refreshMode, forKey: .refreshMode)
        try container.encode(refreshIntervalMinutes, forKey: .refreshIntervalMinutes)
    }

    var timeZone: TimeZone {
        timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
