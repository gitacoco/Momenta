import Foundation

/// Abstraction over where Momenta's data comes from. M1 ships a deterministic
/// mock; M2 replaces it with a Toggl-backed implementation behind the same API.
protocol DataProvider: Sendable {
    func loadClients() async throws -> [ClientConfig]
    func loadSnapshot(for month: YearMonth, timeZone: TimeZone, now: Date) async throws -> TimeEntrySnapshot
    func availableMonths(asOf now: Date, timeZone: TimeZone) async throws -> [YearMonth]
}
