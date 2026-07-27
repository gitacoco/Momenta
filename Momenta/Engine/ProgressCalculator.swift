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

/// Cross-client aggregate for the menu bar and the popover Overall row.
/// Revenue and hours are both retained so the shared display-unit toggle can
/// choose the Overall calculation used by the popover and menu bar. Revenue
/// remains the cross-client financial view; hours is the explicit summed-hours
/// view.
struct AggregateProgress: Sendable {
    struct ClientShare: Identifiable, Sendable {
        var client: ClientConfig
        var actualRevenue: Decimal
        var targetRevenue: Decimal
        /// A zero target can still be meaningful: once the monthly goal is
        /// complete, "per day to goal" is zero and today's ring is complete.
        var targetIsAvailable: Bool
        /// Hours track, carried alongside revenue so the menu-bar per-client
        /// ring can follow the display unit. Non-billable clients have no
        /// revenue, so the hours ring is the only meaningful one for them.
        var actualHours: Decimal
        var targetHours: Decimal
        var hoursTargetIsAvailable: Bool

        var id: Int { client.id }

        var fraction: Double {
            guard targetRevenue > 0 else { return targetIsAvailable ? 1 : 0 }
            return (actualRevenue / targetRevenue).doubleValue
        }

        var hoursFraction: Double {
            guard targetHours > 0 else { return hoursTargetIsAvailable ? 1 : 0 }
            return (actualHours / targetHours).doubleValue
        }

        init(
            client: ClientConfig,
            actualRevenue: Decimal,
            targetRevenue: Decimal,
            actualHours: Decimal = 0,
            targetHours: Decimal = 0,
            targetIsAvailable: Bool? = nil,
            hoursTargetIsAvailable: Bool? = nil
        ) {
            self.client = client
            self.actualRevenue = actualRevenue
            self.targetRevenue = targetRevenue
            self.actualHours = actualHours
            self.targetHours = targetHours
            self.targetIsAvailable = targetIsAvailable ?? (targetRevenue > 0)
            self.hoursTargetIsAvailable = hoursTargetIsAvailable ?? (targetHours > 0)
        }
    }

    var shares: [ClientShare]
    private var overallActualRevenue: Decimal?
    private var overallTargetRevenue: Decimal?
    private var overallTargetAvailability: Bool?
    private var overallActualHoursValue: Decimal?
    private var overallTargetHoursValue: Decimal?
    private var overallHoursAvailability: Bool?

    var actualRevenue: Decimal {
        overallActualRevenue ?? shares.reduce(0) { $0 + $1.actualRevenue }
    }

    var targetRevenue: Decimal {
        overallTargetRevenue ?? shares.reduce(0) { $0 + $1.targetRevenue }
    }

    var targetIsAvailable: Bool {
        overallTargetAvailability ?? shares.contains(where: \.targetIsAvailable)
    }

    var fraction: Double {
        guard targetRevenue > 0 else { return targetIsAvailable ? 1 : 0 }
        return (actualRevenue / targetRevenue).doubleValue
    }

    /// Summed actual/target hours across clients for the hours-mode Overall.
    var actualHours: Decimal { overallActualHoursValue ?? 0 }

    var targetHours: Decimal { overallTargetHoursValue ?? 0 }

    var hoursTargetIsAvailable: Bool { overallHoursAvailability ?? (targetHours > 0) }

    var hoursFraction: Double {
        guard targetHours > 0 else { return hoursTargetIsAvailable ? 1 : 0 }
        return (actualHours / targetHours).doubleValue
    }

    init(
        shares: [ClientShare],
        overallActualRevenue: Decimal? = nil,
        overallTargetRevenue: Decimal? = nil,
        overallTargetIsAvailable: Bool? = nil,
        overallActualHours: Decimal? = nil,
        overallTargetHours: Decimal? = nil,
        overallHoursTargetIsAvailable: Bool? = nil
    ) {
        self.shares = shares
        self.overallActualRevenue = overallActualRevenue
        self.overallTargetRevenue = overallTargetRevenue
        self.overallTargetAvailability = overallTargetIsAvailable
        self.overallActualHoursValue = overallActualHours
        self.overallTargetHoursValue = overallTargetHours
        self.overallHoursAvailability = overallHoursTargetIsAvailable
    }
}

/// One client's progress for a specific popover period (day / week / month),
/// derived from the month-scoped `ClientProgress`. Values are carried in both
/// hours and revenue so the client card's h/$ toggle and the summed Overall
/// row both read from the same slice.
struct ClientPeriodSlice: Identifiable, Sendable {
    var client: ClientConfig
    var period: AggregationPeriod
    var hourlyRate: Decimal
    /// A goal is in effect for this period (false for rate-backfilled history:
    /// actuals render, but there is no target line, delta, or pace).
    var hasGoal: Bool

    /// Day period only: the reference day is not one of this client's scheduled
    /// work days, so its planned increment is flat (zero). The card shows a
    /// "day off" state with no target and no behind/ahead debt — matching the
    /// Overall ring, which already zeroes an unscheduled day. Always false for
    /// week and month.
    var isRestDay: Bool = false

    /// Cumulative points to chart (week: the week's days; month: the whole
    /// month). Empty for day (the day card is a bullet, not a chart).
    var points: [DayProgressPoint]

    /// Period actual — day: the reference day's own hours; week: cumulative
    /// through the last elapsed day; month: month-to-date cumulative.
    var actualHours: Decimal
    var actualRevenue: Decimal

    /// Period target — day: catch-up pace; week: the catch-up target frozen at
    /// the start of each month segment in the week; month: the whole-month
    /// goal. Nil without a goal.
    var targetHours: Decimal?
    var targetRevenue: Decimal?

    /// Planned value through the reference point, for the behind/ahead delta.
    /// Day reuses the target (the bullet compares actual against the day pace).
    var plannedToDateHours: Decimal?
    var plannedToDateRevenue: Decimal?

    var id: Int { client.id }

    var deltaHours: Decimal? { plannedToDateHours.map { actualHours - $0 } }
    var deltaRevenue: Decimal? { plannedToDateRevenue.map { actualRevenue - $0 } }
    var isAhead: Bool { (deltaHours ?? 0) >= 0 }
}

/// Periods that aggregate within a single month. Week is deliberately absent
/// at the type level: weeks are full Mon–Sun intervals that stitch across
/// month boundaries, and go through `weekAggregate(slices:)` instead.
enum SingleMonthPeriod: Sendable {
    case day
    case month
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
        let goalIsUsable = recordedGoal.map { client.isBillable ? $0.isComplete : $0.hours > 0 } ?? false
        let goal: MonthlyGoal? = goalIsUsable ? recordedGoal : nil
        let rate: Decimal
        if client.isBillable {
            // No goal for the month: still price actuals with the backfilled
            // rate; without even a rate there is nothing meaningful to show.
            guard let resolved = goal?.hourlyRate ?? client.effectiveRate(for: month) else { return nil }
            rate = resolved
        } else {
            // Non-billable clients have no rate. Revenue is a flat zero
            // everywhere; without a goal there is nothing to plan or show.
            guard goal != nil else { return nil }
            rate = 0
        }

        let calendar = YearMonth.calendar(in: timeZone)
        let monthStart = month.start(in: timeZone)
        let dayCount = month.dayCount(in: timeZone)
        let weights = dailyWeights(month: month, pacing: client.pacing, customWorkDays: client.customWorkDays, timeZone: timeZone)
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
                customWorkDays: client.customWorkDays,
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
    /// month selected by `period` (a single day, or the whole month). Weeks
    /// never come through here — they stitch across months via
    /// `weekAggregate(slices:)`.
    static func aggregate(
        clients: [ClientConfig],
        entries: [TimeEntry],
        month: YearMonth,
        period: SingleMonthPeriod,
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
        var totalGoalRevenue: Decimal = 0
        // Work completed strictly before the reference day started. Summed
        // from entry start times directly (not month − referenceDay) so a
        // back-stepped day doesn't count later days' work as "before".
        var actualRevenueBeforeDay: Decimal = 0
        // Summed period actual/target hours across clients — the popover's
        // hours-mode Overall. Meaningless as physics (rates differ), but the
        // user opted into a summed-hours readout.
        var periodActualHours: Decimal = 0
        var periodTargetHours: Decimal = 0
        // The day Overall's hours track, accumulated only over clients
        // scheduled today. Unlike the pooled revenue target, hours are not
        // fungible across clients, so a client that is off today must not
        // push its catch-up onto today's target — and, symmetrically, hours
        // logged on a day off must not complete another client's goal. They
        // still count on that client's card and in the week/month.
        var scheduledHoursTargetToday: Decimal = 0
        var scheduledActualHoursToday: Decimal = 0
        var aggregateWeights = [Int](repeating: 0, count: month.dayCount(in: timeZone))
        for client in clients where client.state(for: month) == .configured {
            guard let goal = client.goal(for: month),
                  (client.isBillable ? goal.isComplete : goal.hours > 0) else { continue }
            let weights = dailyWeights(month: month, pacing: client.pacing, customWorkDays: client.customWorkDays, timeZone: timeZone)
            for index in weights.indices where weights[index] > 0 {
                aggregateWeights[index] = 1
            }
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
            var beforeDayHours: Decimal = 0
            for entry in entries where entry.clientID == client.id {
                let entryHours = Decimal(entry.elapsed(asOf: now)) / 3600
                if entry.start >= interval.start && entry.start < interval.end {
                    hours += entryHours
                }
                if period == .day, month.contains(entry.start, in: timeZone) {
                    monthHours += entryHours
                    if entry.start < interval.start {
                        beforeDayHours += entryHours
                    }
                }
            }
            totalGoalRevenue += goal.revenue
            actualRevenueBeforeDay += beforeDayHours * goal.hourlyRate
            periodActualHours += hours

            // Today's ring uses the same dynamic catch-up pace shown on the
            // client card. Week and month retain their calendar-slice plans.
            // Revenue stays exact (from goal.revenue) rather than re-derived
            // from hours × rate, which could drift for revenue-authored goals.
            let targetHours: Decimal
            let target: Decimal
            let targetIsAvailable: Bool
            let hoursAvailable: Bool
            if period == .day {
                // A day the client doesn't work has no target, so its By-Client
                // ring reads neutral rather than behind — the same treatment the
                // Overall ring already gives an unscheduled day below.
                let workWeekdays = client.pacing.workWeekdays(custom: client.customWorkDays)
                let scheduledToday = workWeekdays.contains(calendar.component(.weekday, from: interval.start))
                if scheduledToday {
                    // The card/ring show the live pace (falls as work is logged
                    // today); the Overall below sums the frozen pace instead.
                    targetHours = requiredDailyHours(
                        goal: goal,
                        actualHours: monthHours,
                        month: month,
                        pacing: client.pacing,
                        customWorkDays: client.customWorkDays,
                        timeZone: timeZone,
                        now: now
                    )
                    target = targetHours * goal.hourlyRate
                    targetIsAvailable = true
                    hoursAvailable = true
                    scheduledActualHoursToday += hours
                    // Freeze the denominator at the reference day (not the live
                    // clock) so a back-stepped day shows the pace it had then,
                    // matching the day slice and the pooled revenue target.
                    scheduledHoursTargetToday += requiredDailyHours(
                        goal: goal,
                        actualHours: beforeDayHours,
                        month: month,
                        pacing: client.pacing,
                        customWorkDays: client.customWorkDays,
                        timeZone: timeZone,
                        now: interval.start
                    )
                } else {
                    targetHours = 0
                    target = 0
                    targetIsAvailable = false
                    hoursAvailable = false
                }
            } else if totalWeight == 0 {
                targetHours = 0
                target = 0
                targetIsAvailable = false
                hoursAvailable = false
            } else {
                // Multiply before dividing so a divisible slice stays exact
                // (e.g. 3680 × 5 / 23 == 800, not 799.99…). This keeps the
                // revenue target byte-identical to the pre-hours behaviour.
                targetHours = goal.hours * Decimal(periodWeight) / Decimal(totalWeight)
                target = goal.revenue * Decimal(periodWeight) / Decimal(totalWeight)
                targetIsAvailable = target > 0
                hoursAvailable = targetHours > 0
            }
            periodTargetHours += targetHours

            shares.append(AggregateProgress.ClientShare(
                client: client,
                actualRevenue: hours * goal.hourlyRate,
                targetRevenue: target,
                actualHours: hours,
                targetHours: targetHours,
                targetIsAvailable: targetIsAvailable,
                hoursTargetIsAvailable: hoursAvailable
            ))
        }

        // Month sums the sliced hours directly; only day needs the day-start
        // freeze below.
        guard period == .day else {
            return AggregateProgress(
                shares: shares,
                overallActualHours: periodActualHours,
                overallTargetHours: periodTargetHours,
                overallHoursTargetIsAvailable: periodTargetHours > 0
            )
        }

        // Overall freezes the day's revenue target at the start of the
        // reference day so work performed that day cannot lower its own
        // denominator. Only work strictly before the day start reduces the
        // remaining goal — a back-stepped day must not have later days' work
        // subtracted either. Revenue above one client's goal offsets another's
        // gap. Hours use the scheduled-clients-only accumulators so both sides
        // of the fraction cover the same cohort: a rest-day client neither
        // raises today's target nor completes it.
        let todayActualRevenue = shares.reduce(0) { $0 + $1.actualRevenue }
        let remainingRevenueAtDayStart = max(0, totalGoalRevenue - actualRevenueBeforeDay)
        let todayActualHours = scheduledActualHoursToday
        let calendar = YearMonth.calendar(in: timeZone)
        let monthStart = month.start(in: timeZone)
        var todayIsScheduled = false
        var remainingScheduledDays = 0
        for dayIndex in aggregateWeights.indices where aggregateWeights[dayIndex] > 0 {
            guard let dayStart = calendar.date(byAdding: .day, value: dayIndex, to: monthStart) else { continue }
            if dayStart == interval.start {
                todayIsScheduled = true
            }
            if dayStart >= interval.start {
                remainingScheduledDays += 1
            }
        }
        let scheduledToday = todayIsScheduled && remainingScheduledDays > 0
        // Revenue is a fungible pool (one client's surplus offsets another's
        // gap), so it keeps the blended per-day pace. Hours are summed per
        // client and already exclude clients who are off today.
        let overallTarget = scheduledToday
            ? remainingRevenueAtDayStart / Decimal(remainingScheduledDays)
            : Decimal(0)
        let overallTargetHours = scheduledHoursTargetToday

        return AggregateProgress(
            shares: shares,
            overallActualRevenue: todayActualRevenue,
            overallTargetRevenue: overallTarget,
            overallTargetIsAvailable: !shares.isEmpty,
            overallActualHours: todayActualHours,
            overallTargetHours: overallTargetHours,
            overallHoursTargetIsAvailable: !shares.isEmpty
        )
    }

    // MARK: Popover period slices

    /// The day slice: the reference day's own hours against the catch-up pace.
    /// The current day uses the live pace (matching the client card and menu
    /// bar); a past day freezes the pace at that day's start. `points` carries
    /// the intraday cumulative series for the timeline style; the bullet
    /// ignores it.
    static func daySlice(
        progress: ClientProgress,
        entries: [TimeEntry],
        reference: Date,
        isCurrentDay: Bool,
        timeZone: TimeZone,
        now: Date
    ) -> ClientPeriodSlice {
        let calendar = YearMonth.calendar(in: timeZone)
        let refDayStart = calendar.startOfDay(for: reference)
        let index = progress.points.firstIndex { calendar.isDate($0.day, inSameDayAs: refDayStart) }

        let rate = progress.hourlyRate
        var actual: Decimal = 0
        var cumulativeBefore: Decimal = 0
        if let index {
            let cumulativeThrough = progress.points[index].actualHours ?? 0
            cumulativeBefore = index > 0 ? (progress.points[index - 1].actualHours ?? 0) : 0
            actual = max(0, cumulativeThrough - cumulativeBefore)
        }

        // A day the client doesn't work carries a flat plan: no target for the
        // day, so logging nothing is not "behind". The catch-up pace is a
        // month-level idea; surfacing it as this day's goal is exactly the
        // artificial debt the pacing schedule exists to avoid.
        let workWeekdays = progress.client.pacing.workWeekdays(custom: progress.client.customWorkDays)
        let isScheduledDay = workWeekdays.contains(calendar.component(.weekday, from: refDayStart))
        let isRestDay = progress.goal != nil && !isScheduledDay

        // The pace frozen at the day's start: what this day asked for before
        // any of its own work was logged. The timeline's plan ramp targets
        // this, so the plan line holds still while the actual line climbs.
        let dayStartTarget: Decimal? = isRestDay ? nil : progress.goal.map { goal in
            requiredDailyHours(
                goal: goal,
                actualHours: cumulativeBefore,
                month: progress.month,
                pacing: progress.client.pacing,
                customWorkDays: progress.client.customWorkDays,
                timeZone: timeZone,
                now: refDayStart
            )
        }

        let target: Decimal? = isRestDay ? nil : progress.goal.map { goal in
            if isCurrentDay {
                return progress.requiredDailyHours ?? goal.hours
            }
            return dayStartTarget ?? goal.hours
        }

        let points = dayTimelinePoints(
            client: progress.client,
            entries: entries,
            dayStart: refDayStart,
            rampTargetHours: dayStartTarget,
            rate: rate,
            attributedTotalHours: actual,
            calendar: calendar,
            now: now
        )

        return ClientPeriodSlice(
            client: progress.client,
            period: .day,
            hourlyRate: rate,
            hasGoal: progress.goal != nil,
            isRestDay: isRestDay,
            points: points,
            actualHours: actual,
            actualRevenue: actual * rate,
            targetHours: target,
            targetRevenue: target.map { $0 * rate },
            plannedToDateHours: target,
            plannedToDateRevenue: target.map { $0 * rate }
        )
    }

    /// The day timeline's intraday series: cumulative actual hours at every
    /// entry boundary, and a plan that stays flat at zero before the client's
    /// work window, ramps linearly through it to the day-start pace, and holds
    /// flat after — so a morning before work starts owes nothing.
    ///
    /// Entries attribute to the day by their start time, matching every other
    /// aggregation. Intraday growth is measured inside the day only, but the
    /// final point pins to `attributedTotalHours`, so an entry running past
    /// midnight keeps the tip equal to the day's bullet/marker total (the
    /// spill appears as a rise at the day's edge rather than vanishing).
    static func dayTimelinePoints(
        client: ClientConfig,
        entries: [TimeEntry],
        dayStart: Date,
        rampTargetHours: Decimal?,
        rate: Decimal,
        attributedTotalHours: Decimal,
        calendar: Calendar,
        now: Date
    ) -> [DayProgressPoint] {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let nowClip = min(max(now, dayStart), dayEnd)

        // Spans of work inside the day, from entries the day owns (started
        // within it), clipped to what has elapsed.
        var spans: [(start: Date, end: Date)] = []
        for entry in entries where entry.clientID == client.id {
            guard entry.start >= dayStart, entry.start < dayEnd else { continue }
            let end = min(entry.stop ?? now, nowClip)
            guard end > entry.start else { continue }
            spans.append((start: entry.start, end: end))
        }

        let window = client.effectiveWorkWindow
        let windowStart = dayStart.addingTimeInterval(TimeInterval(window.startMinute * 60))
        let windowEnd = dayStart.addingTimeInterval(TimeInterval(window.endMinute * 60))

        var breakpoints: Set<Date> = [dayStart, dayEnd, nowClip]
        for boundary in [windowStart, windowEnd] where boundary > dayStart && boundary < dayEnd {
            breakpoints.insert(boundary)
        }
        for span in spans {
            breakpoints.insert(span.start)
            breakpoints.insert(span.end)
        }

        func cumulativeHours(at time: Date) -> Decimal {
            let seconds = spans.reduce(0.0) { total, span in
                total + max(0, min(span.end, time).timeIntervalSince(span.start))
            }
            return Decimal(seconds) / 3600
        }

        return breakpoints.sorted().map { time in
            let minutes = time.timeIntervalSince(dayStart) / 60
            let plannedHours = rampTargetHours.map {
                $0 * Decimal(window.plannedFraction(atMinute: minutes))
            }
            var actualHours: Decimal?
            if time <= nowClip {
                // The tip pins to the attributed day total; see above.
                actualHours = time == nowClip ? attributedTotalHours : cumulativeHours(at: time)
            }
            return DayProgressPoint(
                day: time,
                plannedHours: plannedHours,
                plannedRevenue: plannedHours.map { $0 * rate },
                actualHours: actualHours,
                actualRevenue: actualHours.map { $0 * rate }
            )
        }
    }

    /// The week card: a true Monday–Sunday cumulative series, stitched across a
    /// month boundary from each day's own month progress. The planned pace is
    /// frozen at the beginning of each month segment in the week: remaining
    /// monthly hours after actuals strictly before that boundary are spread
    /// over the month's remaining scheduled days. Earlier shortfalls therefore
    /// raise later weekly targets without making the current target move while
    /// work is logged. `progressByMonth` holds this client's progress for every
    /// month the week touches.
    static func weekSlice(
        client: ClientConfig,
        progressByMonth: [YearMonth: ClientProgress],
        reference: Date,
        timeZone: TimeZone
    ) -> ClientPeriodSlice {
        let calendar = YearMonth.calendar(in: timeZone)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: reference)?.start
            ?? calendar.startOfDay(for: reference)

        var points: [DayProgressPoint] = []
        var cumulativePlannedHours: Decimal?
        var cumulativePlannedRevenue: Decimal?
        var cumulativeActualHours: Decimal?
        var cumulativeActualRevenue: Decimal?
        var hasGoal = false
        var rate = client.effectiveRate(for: YearMonth(containing: reference, timeZone: timeZone)) ?? 0

        var actualToDateHours: Decimal = 0
        var actualToDateRevenue: Decimal = 0
        var plannedToDateHours: Decimal?
        var plannedToDateRevenue: Decimal?
        var catchUpHoursPerScheduledDay: [YearMonth: Decimal] = [:]
        var scheduledWeightsByMonth: [YearMonth: [Int]] = [:]

        for offset in 0..<7 {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: weekStart) else { continue }
            let dayMonth = YearMonth(containing: dayStart, timeZone: timeZone)
            let progress = progressByMonth[dayMonth]
            let dayIndex = progress.flatMap { p in
                p.points.firstIndex { calendar.isDate($0.day, inSameDayAs: dayStart) }
            }

            var dailyPlannedHours: Decimal?
            var dailyActualHours: Decimal?
            if let progress, let dayIndex {
                rate = progress.hourlyRate
                let point = progress.points[dayIndex]
                if let goal = progress.goal {
                    hasGoal = true
                    let weights = scheduledWeightsByMonth[dayMonth] ?? dailyWeights(
                        month: dayMonth,
                        pacing: client.pacing,
                        customWorkDays: client.customWorkDays,
                        timeZone: timeZone
                    )
                    scheduledWeightsByMonth[dayMonth] = weights
                    let catchUpHours = catchUpHoursPerScheduledDay[dayMonth] ?? {
                        let segmentStart = max(weekStart, dayMonth.start(in: timeZone))
                        let segmentStartIndex = max(
                            0,
                            calendar.dateComponents(
                                [.day],
                                from: dayMonth.start(in: timeZone),
                                to: segmentStart
                            ).day ?? 0
                        )
                        let actualBeforeSegment = progress.points
                            .prefix(segmentStartIndex)
                            .compactMap(\.actualHours)
                            .last ?? 0
                        let remainingHours = max(0, goal.hours - actualBeforeSegment)
                        let remainingWeight = weights
                            .dropFirst(segmentStartIndex)
                            .reduce(0, +)
                        return remainingWeight > 0
                            ? remainingHours / Decimal(remainingWeight)
                            : 0
                    }()
                    catchUpHoursPerScheduledDay[dayMonth] = catchUpHours
                    dailyPlannedHours = catchUpHours * Decimal(weights[dayIndex])
                }
                if let actual = point.actualHours {
                    let previousActual = dayIndex > 0 ? (progress.points[dayIndex - 1].actualHours ?? 0) : 0
                    dailyActualHours = max(0, actual - previousActual)
                }
            }

            if let dailyPlannedHours {
                cumulativePlannedHours = (cumulativePlannedHours ?? 0) + dailyPlannedHours
                cumulativePlannedRevenue = (cumulativePlannedRevenue ?? 0) + dailyPlannedHours * rate
            }
            let dayIsElapsed = dailyActualHours != nil
            if let dailyActualHours {
                cumulativeActualHours = (cumulativeActualHours ?? 0) + dailyActualHours
                cumulativeActualRevenue = (cumulativeActualRevenue ?? 0) + dailyActualHours * rate
                actualToDateHours = cumulativeActualHours ?? 0
                actualToDateRevenue = cumulativeActualRevenue ?? 0
                plannedToDateHours = cumulativePlannedHours
                plannedToDateRevenue = cumulativePlannedRevenue
            }

            points.append(DayProgressPoint(
                day: dayStart,
                plannedHours: cumulativePlannedHours,
                plannedRevenue: cumulativePlannedRevenue,
                actualHours: dayIsElapsed ? cumulativeActualHours : nil,
                actualRevenue: dayIsElapsed ? cumulativeActualRevenue : nil
            ))
        }

        return ClientPeriodSlice(
            client: client,
            period: .week,
            hourlyRate: rate,
            hasGoal: hasGoal,
            points: points,
            actualHours: actualToDateHours,
            actualRevenue: actualToDateRevenue,
            targetHours: hasGoal ? (cumulativePlannedHours ?? 0) : nil,
            targetRevenue: hasGoal ? (cumulativePlannedRevenue ?? 0) : nil,
            plannedToDateHours: plannedToDateHours,
            plannedToDateRevenue: plannedToDateRevenue
        )
    }

    /// Cross-client week aggregate built from the same per-client slices the
    /// week cards render, so the Overall ring, the per-client menu-bar shares,
    /// and the cards agree by construction — including cross-month stitching.
    /// Pass slices in config order; shares preserve it. Nil when no slice
    /// carries a goal.
    static func weekAggregate(slices: [ClientPeriodSlice]) -> AggregateProgress? {
        let contributing = slices.filter(\.hasGoal)
        guard !contributing.isEmpty else { return nil }
        let shares = contributing.map { slice in
            AggregateProgress.ClientShare(
                client: slice.client,
                actualRevenue: slice.actualRevenue,
                targetRevenue: slice.targetRevenue ?? 0,
                actualHours: slice.actualHours,
                targetHours: slice.targetHours ?? 0,
                targetIsAvailable: true,
                hoursTargetIsAvailable: true
            )
        }
        let actualHours = contributing.reduce(Decimal(0)) { $0 + $1.actualHours }
        let targetHours = contributing.reduce(Decimal(0)) { $0 + ($1.targetHours ?? 0) }
        let actualRevenue = contributing.reduce(Decimal(0)) { $0 + $1.actualRevenue }
        let targetRevenue = contributing.reduce(Decimal(0)) { $0 + ($1.targetRevenue ?? 0) }
        return AggregateProgress(
            shares: shares,
            overallActualRevenue: actualRevenue,
            overallTargetRevenue: targetRevenue,
            overallTargetIsAvailable: true,
            overallActualHours: actualHours,
            overallTargetHours: targetHours,
            overallHoursTargetIsAvailable: true
        )
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
    /// `customWorkDays` is the client's work-weekday selection, used only by
    /// `.custom` pacing (see `PacingMode.workWeekdays(custom:)`).
    static func dailyWeights(
        month: YearMonth,
        pacing: PacingMode,
        customWorkDays: Set<Int>? = nil,
        timeZone: TimeZone
    ) -> [Int] {
        let calendar = YearMonth.calendar(in: timeZone)
        let monthStart = month.start(in: timeZone)
        let workWeekdays = pacing.workWeekdays(custom: customWorkDays)
        return (0..<month.dayCount(in: timeZone)).map { dayIndex in
            guard let dayStart = calendar.date(byAdding: .day, value: dayIndex, to: monthStart) else { return 0 }
            return workWeekdays.contains(calendar.component(.weekday, from: dayStart)) ? 1 : 0
        }
    }

    /// Scheduled days remaining in the month strictly after today (today is
    /// treated as available for catching up, so it is included).
    static func remainingScheduledDays(
        month: YearMonth,
        pacing: PacingMode,
        customWorkDays: Set<Int>? = nil,
        timeZone: TimeZone,
        after now: Date
    ) -> Int {
        let calendar = YearMonth.calendar(in: timeZone)
        let monthStart = month.start(in: timeZone)
        let weights = dailyWeights(month: month, pacing: pacing, customWorkDays: customWorkDays, timeZone: timeZone)
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
        customWorkDays: Set<Int>? = nil,
        timeZone: TimeZone,
        now: Date
    ) -> Decimal {
        let remainingHours = max(0, goal.hours - actualHours)
        let remainingWeight = remainingScheduledDays(
            month: month,
            pacing: pacing,
            customWorkDays: customWorkDays,
            timeZone: timeZone,
            after: now
        )
        return remainingWeight > 0
            ? remainingHours / Decimal(remainingWeight)
            : remainingHours
    }

    /// The date interval a single-month aggregate covers, clipped to the month.
    static func periodInterval(
        period: SingleMonthPeriod,
        month: YearMonth,
        timeZone: TimeZone,
        now: Date
    ) -> DateInterval {
        let calendar = YearMonth.calendar(in: timeZone)
        let monthInterval = DateInterval(start: month.start(in: timeZone), end: month.end(in: timeZone))
        switch period {
        case .month:
            return monthInterval
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
