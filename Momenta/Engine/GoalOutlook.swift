import Foundation

/// The effect of the editor's monthly total and schedule on dates strictly
/// after today. Logged hours use the same snapshot cutoff as the dashboard;
/// the planning horizon uses the current clock even when that snapshot is old.
struct GoalOutlook: Equatable, Sendable {
    let loggedHours: Decimal
    let remainingHours: Decimal
    let plannedDays: Int

    var hoursPerPlannedDay: Decimal? {
        if remainingHours == 0 { return 0 }
        guard plannedDays > 0 else { return nil }
        return remainingHours / Decimal(plannedDays)
    }

    init(
        goalHours: Decimal,
        client: ClientConfig,
        snapshot: TimeEntrySnapshot,
        timeZone: TimeZone,
        now: Date
    ) {
        let cutoff = min(snapshot.fetchedAt, now)
        loggedHours = snapshot.entries
            .filter {
                $0.clientID == client.id
                    && snapshot.month.contains($0.start, in: timeZone)
                    && $0.start <= cutoff
            }
            .reduce(0) { $0 + Decimal($1.elapsed(asOf: cutoff)) / 3600 }
        remainingHours = max(0, goalHours - loggedHours)
        plannedDays = ProgressCalculator.remainingScheduledDays(
            month: snapshot.month,
            pacing: client.pacing,
            customWorkDays: client.customWorkDays,
            daysOff: client.daysOff,
            timeZone: timeZone,
            after: now,
            includingToday: false
        )
    }
}
