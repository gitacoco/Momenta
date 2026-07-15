import Foundation

/// Abstraction over where time entry data comes from. M1 ships a
/// deterministic mock; the Toggl-backed implementation replaces it behind the
/// same API. Client configuration lives in ConfigStore, not here.
protocol DataProvider: Sendable {
    func loadSnapshot(for month: YearMonth, timeZone: TimeZone, now: Date) async throws -> TimeEntrySnapshot
    func availableMonths(asOf now: Date, timeZone: TimeZone) async throws -> [YearMonth]
}
