import Foundation

/// A normalized time entry. Raw Toggl quirks (negative running durations, etc.)
/// are resolved by the normalization layer before entries reach this type.
struct TimeEntry: Identifiable, Hashable, Codable, Sendable {
    var id: Int
    /// Toggl client the entry resolves to; nil means uncategorized.
    var clientID: Int?
    var start: Date
    /// nil while the entry is still running.
    var stop: Date?

    var isRunning: Bool { stop == nil }

    /// Elapsed duration as of `now`; running entries count time up to `now`.
    func elapsed(asOf now: Date) -> TimeInterval {
        max(0, (stop ?? now).timeIntervalSince(start))
    }
}

/// A fetched month of entries, cacheable and renderable offline.
struct TimeEntrySnapshot: Codable, Sendable {
    var month: YearMonth
    var fetchedAt: Date
    var entries: [TimeEntry]
}
