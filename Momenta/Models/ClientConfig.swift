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
    /// Toggl client ID (globally unique across workspaces).
    var id: Int
    /// Workspace the client belongs to. All of the account's workspaces are
    /// imported; the Clients settings page groups by workspace.
    var workspaceID: Int
    var workspaceName: String
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
    /// ISO 4217 code used to render this client's money values. Display-only:
    /// cross-client aggregation still sums raw numbers. Optional so configs
    /// persisted before this field decode cleanly.
    var currencyCode: String? = nil
    /// File name of an uploaded logo in the local logo store; nil falls back
    /// to the brand-color dot.
    var logoFileName: String? = nil

    var currency: String {
        currencyCode ?? "USD"
    }

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

    /// The rate used to price a month's hours. Goals never write backward,
    /// but the hourly rate is a fact about the client: months before the
    /// first recorded version borrow the earliest later version's rate so
    /// historical hours still convert to revenue.
    func effectiveRate(for month: YearMonth) -> Decimal? {
        if let goal = goal(for: month), goal.hourlyRate > 0 {
            return goal.hourlyRate
        }
        return goalHistory
            .filter { $0.key > month && $0.value.hourlyRate > 0 }
            .min { $0.key < $1.key }?
            .value.hourlyRate
    }

    /// Whether this client gets a dashboard card for the month: fully
    /// configured, or a historical month viewable through a backfilled rate
    /// (actuals only, no goal line).
    func isDisplayable(for month: YearMonth) -> Bool {
        switch state(for: month) {
        case .configured:
            return true
        case .needsSetup:
            return effectiveRate(for: month) != nil
        case .disabled, .archived:
            return false
        }
    }
}
