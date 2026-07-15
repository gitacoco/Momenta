import Foundation

/// Caches the workspace/project catalog needed to resolve entries to clients,
/// so month loads don't refetch it on every popover open. Free-plan friendly.
actor ProjectCatalog {
    private let api: TogglAPIClient
    private var cached: [TogglProjectDTO]?
    private var fetchedAt: Date?
    private let timeToLive: TimeInterval

    init(api: TogglAPIClient, timeToLive: TimeInterval = 15 * 60) {
        self.api = api
        self.timeToLive = timeToLive
    }

    func projects(now: Date) async throws -> [TogglProjectDTO] {
        if let cached, let fetchedAt, now.timeIntervalSince(fetchedAt) < timeToLive {
            return cached
        }
        let workspaces = try await api.workspaces()
        var all: [TogglProjectDTO] = []
        for workspace in workspaces {
            all += try await api.projects(workspaceID: workspace.id)
        }
        cached = all
        fetchedAt = now
        return all
    }
}

/// The real data source: Toggl entries fetched per month, normalized, and
/// filtered by the configured time zone's month boundaries.
struct TogglDataProvider: DataProvider {
    private let api: TogglAPIClient
    private let catalog: ProjectCatalog

    init(api: TogglAPIClient) {
        self.api = api
        self.catalog = ProjectCatalog(api: api)
    }

    func loadSnapshot(for month: YearMonth, timeZone: TimeZone, now: Date) async throws -> TimeEntrySnapshot {
        // Over-fetch a day on both sides, then filter by the configured time
        // zone locally — the API query runs in UTC.
        let margin: TimeInterval = 86_400
        let from = month.start(in: timeZone).addingTimeInterval(-margin)
        let to = min(month.end(in: timeZone).addingTimeInterval(margin), now.addingTimeInterval(60))
        guard to > from else {
            return TimeEntrySnapshot(month: month, fetchedAt: now, entries: [])
        }

        // The ranged query includes the running entry (its start is inside
        // the range), so no separate /current call — every request counts
        // against the free plan's 30/hour quota.
        let dtos = try await api.timeEntries(from: from, to: to)

        let projects = try await catalog.projects(now: now)
        let entries = TogglNormalizer.normalize(entries: dtos, projects: projects)
            .filter { month.contains($0.start, in: timeZone) }
            .sorted { $0.start < $1.start }

        return TimeEntrySnapshot(month: month, fetchedAt: now, entries: entries)
    }

    /// Toggl's v9 time-entries endpoint only reaches back about three months,
    /// so on-demand fetching offers the current month plus two previous ones.
    /// Older months stay viewable through the local cache.
    func availableMonths(asOf now: Date, timeZone: TimeZone) async throws -> [YearMonth] {
        let current = YearMonth(containing: now, timeZone: timeZone)
        return [current.previous.previous, current.previous, current]
    }
}
