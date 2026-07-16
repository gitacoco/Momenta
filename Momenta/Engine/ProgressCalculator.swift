import Foundation

/// One day on the chart: cumulative planned values span the whole month
/// (nil when the month has no recorded goal), cumulative actual values exist
/// only for elapsed days.
struct DayProgressPoint: Identifiable, Sendable {
    var day: Date
    var plannedHours: Decimal?
    var plannedRevenue: Decimal?
    var actualHours: Decimal?
    var actualRevenue: Decimal?

    var id: Date { day }
}

/// A client's computed progress for one month. `goal` is nil for historical
/// months before the first recorded version: hours are priced with the
/// backfilled rate, but no goal line, delta, or pace exists.
struct ClientProgress: Identifiable, Sendable {
    var client: ClientConfig
    var month: YearMonth
    var goal: MonthlyGoal?
    var hourlyRate: Decimal
    var points: [DayProgressPoint]
    var actualHours: Decimal
    var actualRevenue: Decimal
    var plannedHoursToDate: Decimal?
    var plannedRevenueToDate: Decimal?
    /// Average hours per remaining scheduled day needed to hit the goal.
    var requiredDailyHours: Decimal?

    var id: Int { client.id }

    var deltaHours: Decimal? { plannedHoursToDate.map { actualHours - $0 } }
    var deltaRevenue: Decimal? { plannedRevenueToDate.map { actualRevenue - $0 } }
    var isAhead: Bool { (deltaHours ?? 0) >= 0 }
}

/// Cross-client aggregate for the menu bar. Revenue-only: rates differ per
/// client, so hours cannot be meaningfully summed across clients.
struct AggregateProgress: Sendable {
    struct ClientShare: Identifiable, Sendable {
        var client: ClientConfig
        var actualRevenue: Decimal
        var targetRevenue: Decimal
        /// A zero target can still be meaningful: once the monthly goal is
        /// complete, "per day to goal" is zero and today's ring is complete.
        var targetIsAvailable: Bool

        var id: Int { client.id }

        var fraction: Double {
            guard targetRevenue > 0 else { return targetIsAvailable ? 1 : 0 }
            return (actualRevenue / targetRevenue).doubleValue
        }

        init(
            client: ClientConfig,
            actualRevenue: Decimal,
            targetRevenue: Decimal,
            targetIsAvailable: Bool? = nil
        ) {
            self.client = client
            self.actualRevenue = actualRevenue
            self.targetRevenue = targetRevenue
            self.targetIsAvailable = targetIsAvailable ?? (targetRevenue > 0)
        }
    }

    var shares: [ClientShare]

    var actualRevenue: Decimal { shares.reduce(0) { $0 + $1.actualRevenue } }
    var targetRevenue: Decimal { shares.reduce(0) { $0 + $1.targetRevenue } }
    var targetIsAvailable: Bool { shares.contains(where: \.targetIsAvailable) }

    var fraction: Double {
        guard targetRevenue > 0 else { return targetIsAvailable ? 1 : 0 }
        return (actualRevenue / targetRevenue).doubleValue
    }
}

/// Hours not counted toward any configured client, split by cause:
/// - no client (or an unknown client): warn visibly,
/// - enabled client still lacking rate/goal: hint that setup unlocks the hours,
/// - deliberately disabled or archived client: excluded silently.
struct UncategorizedSummary: Sendable {
    var noClientHours: Decimal
    var needsSetupHours: Decimal
    var disabledHours: Decimal
}

/// Pure month-progress math. Full normalization and the complete test matrix
/// land with BON-14; the API here is the one the UI builds against.
enum ProgressCalculator {

    // MARK: Per-client progress

    static func progress(
        for client: ClientConfig,
        entries: [TimeEntry],
        month: YearMonth,
        timeZone: TimeZone,
        now: Date
    ) -> ClientProgress? {
        let recordedGoal = client.goal(for: month)
        let goal: MonthlyGoal? = (recordedGoal?.isComplete == true) ? recordedGoal : nil
        // No goal for the month: still price actuals with the backfilled
        // rate; without even a rate there is nothing meaningful to show.
        guard let rate = goal?.hourlyRate ?? client.effectiveRate(for: month) else { return nil }

        let calendar = YearMonth.calendar(in: timeZone)
        let monthStart = month.start(in: timeZone)
        let dayCount = month.dayCount(in: timeZone)
        let weights = dailyWeights(month: month, pacing: client.pacing, timeZone: timeZone)
        let totalWeight = weights.reduce(0, +)

        // Actual hours per day, attributed by entry start time.
        var actualByDay = [Int: Decimal](minimumCapacity: dayCount)
        for entry in entries where entry.clientID == client.id {
            guard month.contains(entry.start, in: timeZone) else { continue }
            let dayIndex = calendar.dateComponents([.day], from: monthStart, to: entry.start).day ?? 0
            let hours = Decimal(entry.elapsed(asOf: now)) / 3600
            actualByDay[dayIndex, default: 0] += hours
        }

        var points: [DayProgressPoint] = []
        points.reserveCapacity(dayCount)
        var cumulativePlannedWeight = 0
        var cumulativeActualHours: Decimal = 0
        var plannedHoursToDate: Decimal?
        var plannedRevenueToDate: Decimal?

        for dayIndex in 0..<dayCount {
            guard let dayStart = calendar.date(byAdding: .day, value: dayIndex, to: monthStart) else { continue }
            cumulativePlannedWeight += weights[dayIndex]
            let plannedFraction = totalWeight == 0
                ? 0
                : Decimal(cumulativePlannedWeight) / Decimal(totalWeight)
            let plannedHours = goal.map { $0.hours * plannedFraction }
            let plannedRevenue = goal.map { $0.revenue * plannedFraction }

            let dayHasElapsed = dayStart <= now
            var actualHours: Decimal?
            var actualRevenue: Decimal?
            if dayHasElapsed {
                cumulativeActualHours += actualByDay[dayIndex] ?? 0
                actualHours = cumulativeActualHours
                actualRevenue = cumulativeActualHours * rate
                plannedHoursToDate = plannedHours
                plannedRevenueToDate = plannedRevenue
            }

            points.append(DayProgressPoint(
                day: dayStart,
                plannedHours: plannedHours,
                plannedRevenue: plannedRevenue,
                actualHours: actualHours,
                actualRevenue: actualRevenue
            ))
        }

        let actualHours = cumulativeActualHours
        let requiredDaily = goal.map {
            requiredDailyHours(
                goal: $0,
                actualHours: actualHours,
                month: month,
                pacing: client.pacing,
                timeZone: timeZone,
                now: now
            )
        }

        return ClientProgress(
            client: client,
            month: month,
            goal: goal,
            hourlyRate: rate,
            points: points,
            actualHours: actualHours,
            actualRevenue: actualHours * rate,
            plannedHoursToDate: plannedHoursToDate,
            plannedRevenueToDate: plannedRevenueToDate,
            requiredDailyHours: requiredDaily
        )
    }

    // MARK: Menu bar aggregate

    /// Aggregate progress across all configured clients for the slice of the
    /// month selected by `period` (today / this week / whole month).
    static func aggregate(
        clients: [ClientConfig],
        entries: [TimeEntry],
        month: YearMonth,
        period: AggregationPeriod,
        timeZone: TimeZone,
        now: Date,
        periodReference: Date? = nil
    ) -> AggregateProgress {
        let interval = periodInterval(
            period: period,
            month: month,
            timeZone: timeZone,
            now: periodReference ?? now
        )

        var shares: [AggregateProgress.ClientShare] = []
        for client in clients where client.state(for: month) == .configured {
            guard let goal = client.goal(for: month), goal.isComplete else { continue }
            let weights = dailyWeights(month: month, pacing: client.pacing, timeZone: timeZone)
            let totalWeight = weights.reduce(0, +)
            let calendar = YearMonth.calendar(in: timeZone)
            let monthStart = month.start(in: timeZone)

            // Planned revenue for the days of the month that fall inside the period.
            var periodWeight = 0
            for dayIndex in 0..<weights.count {
                guard let dayStart = calendar.date(byAdding: .day, value: dayIndex, to: monthStart) else { continue }
                if dayStart >= interval.start && dayStart < interval.end {
                    periodWeight += weights[dayIndex]
                }
            }
            // Actual revenue from entries starting inside the period.
            var hours: Decimal = 0
            var monthHours: Decimal = 0
            for entry in entries where entry.clientID == client.id {
                let entryHours = Decimal(entry.elapsed(asOf: now)) / 3600
                if entry.start >= interval.start && entry.start < interval.end {
                    hours += entryHours
                }
                if period == .day, month.contains(entry.start, in: timeZone) {
                    monthHours += entryHours
                }
            }

            // Today's ring uses the same dynamic catch-up pace shown on the
            // client card. Week and month retain their calendar-slice plans.
            let target: Decimal
            let targetIsAvailable: Bool
            if period == .day {
                target = requiredDailyHours(
                    goal: goal,
                    actualHours: monthHours,
                    month: month,
                    pacing: client.pacing,
                    timeZone: timeZone,
                    now: now
                ) * goal.hourlyRate
                targetIsAvailable = true
            } else {
                target = totalWeight == 0
                    ? Decimal(0)
                    : goal.revenue * Decimal(periodWeight) / Decimal(totalWeight)
                targetIsAvailable = target > 0
            }

            shares.append(AggregateProgress.ClientShare(
                client: client,
                actualRevenue: hours * goal.hourlyRate,
                targetRevenue: target,
                targetIsAvailable: targetIsAvailable
            ))
        }
        return AggregateProgress(shares: shares)
    }

    // MARK: Uncategorized

    static func uncategorized(
        entries: [TimeEntry],
        clients: [ClientConfig],
        month: YearMonth,
        timeZone: TimeZone,
        now: Date
    ) -> UncategorizedSummary {
        let clientsByID = Dictionary(uniqueKeysWithValues: clients.map { ($0.id, $0) })
        var noClient: Decimal = 0
        var needsSetup: Decimal = 0
        var disabled: Decimal = 0
        for entry in entries {
            guard month.contains(entry.start, in: timeZone) else { continue }
            let hours = Decimal(entry.elapsed(asOf: now)) / 3600
            guard let clientID = entry.clientID, let client = clientsByID[clientID] else {
                // No client, or a client Momenta doesn't know about.
                noClient += hours
                continue
            }
            // Anything rendered on a card (including rate-backfilled
            // historical months) counts as categorized.
            guard !client.isDisplayable(for: month) else { continue }
            switch client.state(for: month) {
            case .configured:
                break
            case .needsSetup:
                needsSetup += hours
            case .disabled, .archived:
                disabled += hours
            }
        }
        return UncategorizedSummary(
            noClientHours: noClient,
            needsSetupHours: needsSetup,
            disabledHours: disabled
        )
    }

    // MARK: Pacing helpers

    /// Weight of each day of the month under the pacing mode (0 or 1).
    static func dailyWeights(month: YearMonth, pacing: PacingMode, timeZone: TimeZone) -> [Int] {
        let calendar = YearMonth.calendar(in: timeZone)
        let monthStart = month.start(in: timeZone)
        return (0..<month.dayCount(in: timeZone)).map { dayIndex in
            guard pacing == .weekdays else { return 1 }
            guard let dayStart = calendar.date(byAdding: .day, value: dayIndex, to: monthStart) else { return 0 }
            let weekday = calendar.component(.weekday, from: dayStart)
            return (weekday == 1 || weekday == 7) ? 0 : 1
        }
    }

    /// Scheduled days remaining in the month strictly after today (today is
    /// treated as available for catching up, so it is included).
    static func remainingScheduledDays(
        month: YearMonth,
        pacing: PacingMode,
        timeZone: TimeZone,
        after now: Date
    ) -> Int {
        let calendar = YearMonth.calendar(in: timeZone)
        let monthStart = month.start(in: timeZone)
        let weights = dailyWeights(month: month, pacing: pacing, timeZone: timeZone)
        var remaining = 0
        for dayIndex in 0..<weights.count {
            guard let dayStart = calendar.date(byAdding: .day, value: dayIndex, to: monthStart) else { continue }
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }
            if dayEnd > now {
                remaining += weights[dayIndex]
            }
        }
        return remaining
    }

    /// Current average hours needed on each remaining scheduled day. Shared
    /// by the client card and today's menu-bar ring so their denominators stay
    /// identical.
    static func requiredDailyHours(
        goal: MonthlyGoal,
        actualHours: Decimal,
        month: YearMonth,
        pacing: PacingMode,
        timeZone: TimeZone,
        now: Date
    ) -> Decimal {
        let remainingHours = max(0, goal.hours - actualHours)
        let remainingWeight = remainingScheduledDays(
            month: month,
            pacing: pacing,
            timeZone: timeZone,
            after: now
        )
        return remainingWeight > 0
            ? remainingHours / Decimal(remainingWeight)
            : remainingHours
    }

    /// The date interval the menu bar aggregates over, clipped to the month.
    static func periodInterval(
        period: AggregationPeriod,
        month: YearMonth,
        timeZone: TimeZone,
        now: Date
    ) -> DateInterval {
        let calendar = YearMonth.calendar(in: timeZone)
        let monthInterval = DateInterval(start: month.start(in: timeZone), end: month.end(in: timeZone))
        switch period {
        case .month:
            return monthInterval
        case .week:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return monthInterval }
            let start = max(week.start, monthInterval.start)
            let end = min(week.end, monthInterval.end)
            return end > start ? DateInterval(start: start, end: end) : monthInterval
        case .day:
            guard let day = calendar.dateInterval(of: .day, for: now) else { return monthInterval }
            let start = max(day.start, monthInterval.start)
            let end = min(day.end, monthInterval.end)
            return end > start ? DateInterval(start: start, end: end) : monthInterval
        }
    }
}

extension Decimal {
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}
