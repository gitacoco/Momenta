import Foundation

enum PacingMode: String, Codable, CaseIterable, Sendable {
    /// Only Monday–Friday carry planned progress; weekends create no debt.
    case weekdays
    /// Every calendar day carries equal planned progress.
    case calendarDays
    /// A per-client selection of work weekdays carries planned progress;
    /// the chosen days live in `ClientConfig.customWorkDays`.
    case custom

    /// The scheduled weekdays (Calendar numbering, 1 = Sunday … 7 = Saturday)
    /// this mode plans progress on. An empty or missing custom selection falls
    /// back to Monday–Friday rather than producing a goal with no schedule.
    func workWeekdays(custom: Set<Int>?) -> Set<Int> {
        switch self {
        case .weekdays:
            return [2, 3, 4, 5, 6]
        case .calendarDays:
            return [1, 2, 3, 4, 5, 6, 7]
        case .custom:
            let days = custom ?? []
            return days.isEmpty ? [2, 3, 4, 5, 6] : days
        }
    }
}

/// The hours of the day a client's work is planned in, as minutes from local
/// midnight. The day timeline draws its plan ramp inside this window: flat at
/// zero before it, rising through it, flat at the day's target after it — so a
/// morning before work starts carries no planned progress, the same principle
/// that keeps days off from creating artificial debt.
struct WorkWindow: Hashable, Codable, Sendable {
    var startMinute: Int
    var endMinute: Int

    static let `default` = WorkWindow(startMinute: 9 * 60, endMinute: 18 * 60)

    /// The planned fraction of the day's target at `minute`, ramping linearly
    /// across the window. A degenerate window (end at or before start) steps
    /// from 0 to 1 at the start so the plan stays monotone.
    func plannedFraction(atMinute minute: Double) -> Double {
        guard Double(endMinute) > Double(startMinute) else {
            return minute >= Double(startMinute) ? 1 : 0
        }
        let fraction = (minute - Double(startMinute)) / Double(endMinute - startMinute)
        return min(max(fraction, 0), 1)
    }
}

/// The billing-rate rules, shared by the model's toggle and the sync layer.
///
/// Billing is one flag over a client's whole history, so a billable client
/// must not keep a rate-less goal version: `effectiveRate` backfills a later
/// rate into it, and its hours then render as revenue the stored goal never
/// recorded. The toggle establishes that invariant; merges combine the flag
/// and the goal months independently and can break it, so they re-establish
/// it with the same rules rather than a second implementation of them.
enum BillingRates {
    /// The rate to restore with: the one parked at switch-off, else the
    /// newest positive rate still on record.
    static func restorable(
        dormantRate: Decimal?,
        history: [YearMonth: MonthlyGoal]
    ) -> Decimal? {
        if let dormantRate, dormantRate > 0 { return dormantRate }
        return history
            .filter { $0.value.hourlyRate > 0 }
            .max { $0.key < $1.key }?
            .value.hourlyRate
    }

    /// Every rate-less version rewritten with the restorable rate, keeping
    /// each one's own input. Versions carrying a rate are untouched, and a
    /// non-billable client — or one with no rate to restore from — is
    /// returned unchanged.
    static func normalized(
        history: [YearMonth: MonthlyGoal],
        isBillable: Bool,
        dormantRate: Decimal?
    ) -> [YearMonth: MonthlyGoal] {
        guard isBillable,
              let rate = restorable(dormantRate: dormantRate, history: history),
              rate > 0
        else { return history }

        var restored = history
        for (month, goal) in history where goal.hourlyRate <= 0 {
            restored[month] = MonthlyGoal(hourlyRate: rate, input: goal.input)
        }
        return restored
    }
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
    /// Work weekdays (Calendar numbering, 1 = Sunday … 7 = Saturday) used when
    /// `pacing == .custom`. Optional so configs persisted before this field
    /// decode cleanly.
    var customWorkDays: Set<Int>? = nil
    /// Backing store for `isBillable`. Optional (nil == billable) so configs
    /// persisted before this field decode cleanly — `ConfigStore` decodes
    /// `[ClientConfig]` directly and swallows decode errors, so a non-optional
    /// addition would silently drop every saved client.
    var billableFlag: Bool? = nil
    /// The hourly rate parked when billing was switched off. Editing an
    /// hours-only goal afterwards saves rate 0 over the current and every
    /// later version, so `effectiveRate` can no longer recover the old rate —
    /// this holds it until billing comes back. Optional for the same decoding
    /// reason as the fields above.
    var dormantHourlyRate: Decimal? = nil
    /// Per-month goal versions. A month without an entry inherits the most
    /// recent earlier version ("this month and onward" semantics).
    var goalHistory: [YearMonth: MonthlyGoal]
    /// ISO 4217 code used to render this client's money values. Display-only:
    /// cross-client aggregation still sums raw numbers. Optional so configs
    /// persisted before this field decode cleanly.
    var currencyCode: String? = nil
    /// The client's planned work hours within a day, used by the day timeline's
    /// plan ramp. Optional so configs persisted before this field decode
    /// cleanly; nil falls back to `WorkWindow.default`.
    var workWindow: WorkWindow? = nil
    /// File name of an uploaded logo in the local logo store; nil falls back
    /// to the brand-color dot.
    var logoFileName: String? = nil

    /// Whether this client bills money. Non-billable clients (personal or
    /// career-development projects) track hours toward a goal with no hourly
    /// rate and no revenue. Absent in older configs means billable.
    var isBillable: Bool {
        get { billableFlag ?? true }
        set { billableFlag = newValue }
    }

    /// Flips billing, carrying the rate across in the same mutation.
    ///
    /// Switching off parks the rate: it is the last moment the value is still
    /// recoverable, because the next hours-only goal edit overwrites it with
    /// zero in this month and every later one. Switching back on immediately
    /// writes it into those zeroed goals — persisting `billable == true` while
    /// a goal still carries rate 0 would leave the client billable but stuck
    /// in "needs setup", with nothing afterwards going back for the parked
    /// value.
    mutating func setBillable(_ billable: Bool, referenceMonth: YearMonth) {
        guard billable else {
            dormantHourlyRate = effectiveRate(for: referenceMonth) ?? dormantHourlyRate
            billableFlag = false
            return
        }
        billableFlag = true
        goalHistory = BillingRates.normalized(
            history: goalHistory,
            isBillable: true,
            dormantRate: dormantHourlyRate
        )
    }

    /// The rate the goal editor should show for `month`: the one the goal
    /// records, or the restorable rate when a billable client's goal carries
    /// none. That combination means a re-enable never completed — a crash
    /// between the two saves, or a merge that took the flag from one side and
    /// the goal from the other.
    ///
    /// Surfacing the parked rate here makes that state repairable instead of
    /// stranding the client in "needs setup". It is offered, not yet stored:
    /// the editor's ordinary auto-save writes it on the next edit, focus
    /// change, or when the pane closes.
    func editorHourlyRate(for month: YearMonth) -> Decimal? {
        let recorded = goal(for: month)?.hourlyRate ?? 0
        if recorded > 0 { return recorded }
        return isBillable ? restorableHourlyRate : nil
    }

    /// The rate to offer when billing is switched back on: the parked one,
    /// or the newest positive rate still in history for a client that never
    /// went through the toggle.
    var restorableHourlyRate: Decimal? {
        BillingRates.restorable(dormantRate: dormantHourlyRate, history: goalHistory)
    }

    var currency: String {
        currencyCode ?? "USD"
    }

    var displayName: String {
        displayNameOverride ?? togglName
    }

    /// The weekdays this client's goal is planned across, with the custom
    /// selection applied when active.
    var workWeekdays: Set<Int> {
        pacing.workWeekdays(custom: customWorkDays)
    }

    /// The work window in effect, with the shared default applied.
    var effectiveWorkWindow: WorkWindow {
        workWindow ?? .default
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

    /// Whether the month's goal is usable. Billable clients need a positive
    /// rate and target; non-billable clients only need positive hours (no rate
    /// exists to complete).
    func hasCompleteGoal(for month: YearMonth) -> Bool {
        guard let goal = goal(for: month) else { return false }
        return isBillable ? goal.isComplete : goal.hours > 0
    }

    func state(for month: YearMonth) -> ClientState {
        if isArchivedInToggl { return .archived }
        if !isEnabled { return .disabled }
        guard hasCompleteGoal(for: month) else { return .needsSetup }
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
