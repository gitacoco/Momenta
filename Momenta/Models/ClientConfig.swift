import Foundation

enum PacingMode: String, Codable, CaseIterable, Sendable {
    /// Only Monday–Friday carry planned progress; weekends create no debt.
    case weekdays
    /// Every calendar day carries equal planned progress.
    case calendarDays
}

enum ClientState: String, Sendable {
    case configured
    case needsSetup
    case disabled
    case archived
}

/// Local configuration attached to a Toggl client. Toggl is the source of truth
/// for the client's identity; everything else here is Momenta-local.
struct ClientConfig: Identifiable, Hashable, Codable, Sendable {
    /// Toggl client ID.
    var id: Int
    var togglName: String
    var displayNameOverride: String?
    var colorHex: String
    var isEnabled: Bool
    /// Deleted in Toggl but kept locally because historical data exists.
    var isArchivedInToggl: Bool
    var pacing: PacingMode
    /// Per-month goal versions. A month without an entry inherits the most
    /// recent earlier version ("this month and onward" semantics).
    var goalHistory: [YearMonth: MonthlyGoal]

    var displayName: String {
        displayNameOverride ?? togglName
    }

    /// The goal version in effect for the given month: the exact recorded
    /// version if present, otherwise the latest version from an earlier month.
    func goal(for month: YearMonth) -> MonthlyGoal? {
        if let exact = goalHistory[month] {
            return exact
        }
        return goalHistory
            .filter { $0.key < month }
            .max { $0.key < $1.key }?
            .value
    }

    func state(for month: YearMonth) -> ClientState {
        if isArchivedInToggl { return .archived }
        if !isEnabled { return .disabled }
        guard let goal = goal(for: month), goal.isComplete else { return .needsSetup }
        return .configured
    }

    /// Whether this client participates in aggregation and dashboard cards for the month.
    func isDisplayable(for month: YearMonth) -> Bool {
        state(for: month) == .configured
    }
}
