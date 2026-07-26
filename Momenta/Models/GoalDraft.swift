import Foundation

/// Editable state behind the goal editor: rate plus hours/revenue where the
/// last-edited side is authoritative and the other is always derived.
/// Pure value type so the currency-converter behavior is unit-testable.
struct GoalDraft: Equatable {
    enum GoalField: Equatable {
        case hours
        case revenue
    }

    private(set) var hourlyRate: Decimal?
    private(set) var hours: Decimal?
    private(set) var revenue: Decimal?
    private(set) var authoritative: GoalField = .hours
    /// Non-billable clients edit hours only: there is no rate, and a complete
    /// goal is just positive hours.
    let isBillable: Bool

    init(goal: MonthlyGoal?, isBillable: Bool = true) {
        self.isBillable = isBillable
        guard let goal else { return }
        hourlyRate = goal.hourlyRate
        hours = goal.hours
        revenue = goal.revenue
        authoritative = goal.isAuthoredInHours ? .hours : .revenue
    }

    mutating func setRate(_ value: Decimal?) {
        hourlyRate = value
        recomputeDerived()
    }

    mutating func setHours(_ value: Decimal?) {
        hours = value
        authoritative = .hours
        recomputeDerived()
    }

    mutating func setRevenue(_ value: Decimal?) {
        revenue = value
        authoritative = .revenue
        recomputeDerived()
    }

    /// Rate changes keep the authoritative side and recompute the other.
    private mutating func recomputeDerived() {
        guard let rate = hourlyRate, rate > 0 else {
            switch authoritative {
            case .hours: revenue = nil
            case .revenue: hours = nil
            }
            return
        }
        switch authoritative {
        case .hours:
            revenue = hours.map { $0 * rate }
        case .revenue:
            hours = revenue.map { $0 / rate }
        }
    }

    /// A complete, saveable goal, or nil while fields are missing/invalid.
    var monthlyGoal: MonthlyGoal? {
        // Non-billable: hours-only, rate 0. Revenue is never authoritative.
        guard isBillable else {
            guard let hours, hours > 0 else { return nil }
            return MonthlyGoal(hourlyRate: 0, input: .hours(hours))
        }
        guard let rate = hourlyRate, rate > 0 else { return nil }
        switch authoritative {
        case .hours:
            guard let hours, hours > 0 else { return nil }
            return MonthlyGoal(hourlyRate: rate, input: .hours(hours))
        case .revenue:
            guard let revenue, revenue > 0 else { return nil }
            return MonthlyGoal(hourlyRate: rate, input: .revenue(revenue))
        }
    }
}
