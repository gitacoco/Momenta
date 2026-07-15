import Foundation

/// The side of the goal the user edited last. The other side is always derived,
/// so contradictory persisted state is impossible by construction.
enum GoalInput: Hashable, Codable, Sendable {
    case hours(Decimal)
    case revenue(Decimal)
}

/// One month's goal version: an hourly rate plus a single authoritative input.
/// `hours` and `revenue` are two views of the same goal, never stored separately.
struct MonthlyGoal: Hashable, Codable, Sendable {
    var hourlyRate: Decimal
    var input: GoalInput

    var hours: Decimal {
        switch input {
        case .hours(let hours):
            return hours
        case .revenue(let revenue):
            return hourlyRate == 0 ? 0 : revenue / hourlyRate
        }
    }

    var revenue: Decimal {
        switch input {
        case .hours(let hours):
            return hours * hourlyRate
        case .revenue(let revenue):
            return revenue
        }
    }

    var isAuthoredInHours: Bool {
        if case .hours = input { return true }
        return false
    }

    /// A goal only counts as configured when both rate and target are positive.
    var isComplete: Bool {
        guard hourlyRate > 0 else { return false }
        switch input {
        case .hours(let hours): return hours > 0
        case .revenue(let revenue): return revenue > 0
        }
    }
}
