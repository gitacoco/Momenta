import Foundation
import Testing
@testable import Momenta

struct ProgressCalculatorTests {
    let utc = TimeZone(identifier: "UTC")!
    // July 2026: the 1st is a Wednesday; 23 weekdays in total.
    let july = YearMonth(year: 2026, month: 7)

    private func date(day: Int, hour: Int = 0) -> Date {
        july.start(in: utc).addingTimeInterval(TimeInterval((day - 1) * 86400 + hour * 3600))
    }

    private func client(pacing: PacingMode = .weekdays, goal: MonthlyGoal? = nil) -> ClientConfig {
        ClientConfig(
            id: 1,
            workspaceID: 101,
            workspaceName: "Freelance",
            togglName: "Acme",
            displayNameOverride: nil,
            colorHex: "#5B8DEF",
            isEnabled: true,
            isArchivedInToggl: false,
            pacing: pacing,
            goalHistory: goal.map { [july: $0] } ?? [:]
        )
    }

    // MARK: Pacing weights

    @Test func weekdayPacingSkipsWeekends() {
        let weights = ProgressCalculator.dailyWeights(month: july, pacing: .weekdays, timeZone: utc)
        #expect(weights.count == 31)
        // July 4, 2026 is a Saturday; July 5 a Sunday.
        #expect(weights[3] == 0)
        #expect(weights[4] == 0)
        #expect(weights[0] == 1) // Wednesday the 1st
        #expect(weights.reduce(0, +) == 23)
    }

    @Test func calendarPacingCountsEveryDay() {
        let weights = ProgressCalculator.dailyWeights(month: july, pacing: .calendarDays, timeZone: utc)
        #expect(weights.reduce(0, +) == 31)
    }

    @Test func customPacingCountsOnlySelectedWeekdays() {
        // Mon/Wed/Fri (Calendar weekdays 2/4/6). July 2026: 4 Mondays,
        // 5 Wednesdays, 5 Fridays.
        let weights = ProgressCalculator.dailyWeights(
            month: july, pacing: .custom, customWorkDays: [2, 4, 6], timeZone: utc
        )
        #expect(weights[0] == 1) // Wednesday the 1st
        #expect(weights[1] == 0) // Thursday the 2nd
        #expect(weights[5] == 1) // Monday the 6th
        #expect(weights.reduce(0, +) == 14)
    }

    @Test func customPacingWithoutSelectionFallsBackToWeekdays() {
        let missing = ProgressCalculator.dailyWeights(
            month: july, pacing: .custom, customWorkDays: nil, timeZone: utc
        )
        let empty = ProgressCalculator.dailyWeights(
            month: july, pacing: .custom, customWorkDays: [], timeZone: utc
        )
        #expect(missing.reduce(0, +) == 23)
        #expect(empty.reduce(0, +) == 23)
    }

    // MARK: Planned line

    @Test(arguments: [PacingMode.weekdays, PacingMode.calendarDays])
    func plannedLineReachesGoalAtMonthEnd(pacing: PacingMode) {
        let goal = MonthlyGoal(hourlyRate: 120, input: .hours(80))
        let config = client(pacing: pacing, goal: goal)
        let progress = ProgressCalculator.progress(
            for: config, entries: [], month: july, timeZone: utc, now: date(day: 15, hour: 12)
        )
        #expect(progress != nil)
        let lastPoint = progress!.points.last!
        #expect(lastPoint.plannedHours == 80)
        #expect(lastPoint.plannedRevenue == 9600)
    }

    @Test func weekendAddsNoPlannedProgressUnderWeekdayPacing() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(46))
        let config = client(pacing: .weekdays, goal: goal)
        let progress = ProgressCalculator.progress(
            for: config, entries: [], month: july, timeZone: utc, now: date(day: 20)
        )!
        // Saturday July 4 (index 3) and Sunday July 5 (index 4) hold the
        // planned line flat at Friday's value.
        #expect(progress.points[3].plannedHours == progress.points[2].plannedHours)
        #expect(progress.points[4].plannedHours == progress.points[2].plannedHours)
        #expect(progress.points[5].plannedHours! > progress.points[4].plannedHours!)
    }

    @Test func noProgressForClientWithoutAnyRate() {
        let progress = ProgressCalculator.progress(
            for: client(goal: nil), entries: [], month: july, timeZone: utc, now: date(day: 10)
        )
        #expect(progress == nil)
    }

    @Test func historicalMonthBackfillsRateButNotGoal() {
        // Goal first recorded in July; June has tracked hours. June must show
        // actuals priced at July's rate — but no goal line, delta, or pace.
        let june = YearMonth(year: 2026, month: 6)
        let config = client(goal: MonthlyGoal(hourlyRate: 120, input: .hours(80)))
        let juneStart = june.start(in: utc)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: juneStart.addingTimeInterval(9 * 3600),
                      stop: juneStart.addingTimeInterval(12 * 3600)),
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: june, timeZone: utc, now: date(day: 10)
        )!
        #expect(progress.goal == nil)
        #expect(progress.hourlyRate == 120)
        #expect(progress.actualHours == 3)
        #expect(progress.actualRevenue == 360)
        #expect(progress.deltaHours == nil)
        #expect(progress.requiredDailyHours == nil)
        #expect(progress.points.allSatisfy { $0.plannedHours == nil })
    }

    @Test func backfilledMonthCountsAsDisplayableAndCategorized() {
        let june = YearMonth(year: 2026, month: 6)
        let config = client(goal: MonthlyGoal(hourlyRate: 120, input: .hours(80)))
        #expect(config.isDisplayable(for: june))

        // Its entries are on a card, so they are not "uncategorized".
        let juneStart = june.start(in: utc)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: juneStart.addingTimeInterval(9 * 3600),
                      stop: juneStart.addingTimeInterval(10 * 3600)),
        ]
        let summary = ProgressCalculator.uncategorized(
            entries: entries, clients: [config], month: june, timeZone: utc, now: date(day: 1)
        )
        #expect(summary.needsSetupHours == 0)
        #expect(summary.noClientHours == 0)
    }

    // MARK: Actuals

    @Test func actualsAccumulateAndConvertToRevenue() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(80))
        let config = client(goal: goal)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 1, hour: 9), stop: date(day: 1, hour: 12)),
            TimeEntry(id: 2, clientID: 1, start: date(day: 2, hour: 9), stop: date(day: 2, hour: 14)),
            TimeEntry(id: 3, clientID: 2, start: date(day: 2, hour: 9), stop: date(day: 2, hour: 17)), // other client
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: date(day: 3)
        )!
        #expect(progress.actualHours == 8)
        #expect(progress.actualRevenue == 800)
    }

    @Test func runningEntryCountsElapsedTimeOnly() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(80))
        let config = client(goal: goal)
        let now = date(day: 10, hour: 11)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 10, hour: 9), stop: nil),
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: now
        )!
        #expect(progress.actualHours == 2)
    }

    @Test func crossMidnightEntryBelongsToStartDay() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(80))
        let config = client(goal: goal)
        // Starts 23:00 on the 6th, ends 01:00 on the 7th: all 2h attributed to the 6th.
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 6, hour: 23), stop: date(day: 7, hour: 1)),
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: date(day: 8)
        )!
        let daySix = progress.points[5]
        let daySeven = progress.points[6]
        #expect(daySix.actualHours == 2)
        #expect(daySeven.actualHours == 2) // cumulative, unchanged on the 7th
    }

    @Test func entryOutsideMonthIsIgnored() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(80))
        let config = client(goal: goal)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 1).addingTimeInterval(-3600), stop: date(day: 1, hour: 1)),
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: date(day: 2)
        )!
        #expect(progress.actualHours == 0)
    }

    @Test func monthRolloverRunningEntryStillCountsIntoStartMonth() {
        // Running entry starts July 31 at 23:00; the popover opens August 1 at
        // 01:00. The entry belongs to July (start month) and its elapsed 2h
        // count into July's total.
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(80))
        let config = client(goal: goal)
        let augustFirst = july.end(in: utc).addingTimeInterval(3600)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 31, hour: 23), stop: nil),
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: augustFirst
        )!
        #expect(progress.actualHours == 2)
        // The whole month has elapsed: planned-to-date equals the full goal.
        #expect(progress.plannedHoursToDate == 80)
    }

    @Test func manualTimeZoneMovesMonthAttribution() {
        // 2026-07-01T02:00Z is July 1 in UTC but June 30 in UTC-5: with the
        // manual UTC-5 time zone the entry must not count into July.
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(80))
        let config = client(goal: goal)
        let entry = TimeEntry(
            id: 1, clientID: 1,
            start: july.start(in: utc).addingTimeInterval(2 * 3600),
            stop: july.start(in: utc).addingTimeInterval(3 * 3600)
        )
        let utcMinus5 = TimeZone(secondsFromGMT: -5 * 3600)!

        let inUTC = ProgressCalculator.progress(
            for: config, entries: [entry], month: july, timeZone: utc, now: date(day: 10)
        )!
        let inUTCMinus5 = ProgressCalculator.progress(
            for: config, entries: [entry], month: july, timeZone: utcMinus5, now: date(day: 10)
        )!
        #expect(inUTC.actualHours == 1)
        #expect(inUTCMinus5.actualHours == 0)
    }

    @Test func historicalMonthUsesItsRecordedGoalVersion() {
        let june = YearMonth(year: 2026, month: 6)
        let juneGoal = MonthlyGoal(hourlyRate: 100, input: .hours(60))
        let julyGoal = MonthlyGoal(hourlyRate: 120, input: .hours(80))
        var config = client(goal: julyGoal)
        config.goalHistory[june] = juneGoal

        let juneProgress = ProgressCalculator.progress(
            for: config, entries: [], month: june, timeZone: utc, now: date(day: 10)
        )!
        let julyProgress = ProgressCalculator.progress(
            for: config, entries: [], month: july, timeZone: utc, now: date(day: 10)
        )!
        // Each month renders against the version recorded for it.
        #expect(juneProgress.goal == juneGoal)
        #expect(julyProgress.goal == julyGoal)
        #expect(juneProgress.points.last?.plannedHours == 60)
        #expect(julyProgress.points.last?.plannedHours == 80)
    }

    @Test func decimalRevenueStaysExact() {
        // 3h at 33.33/h must be exactly 99.99 — no binary floating point drift.
        let goal = MonthlyGoal(hourlyRate: Decimal(string: "33.33")!, input: .hours(100))
        let config = client(goal: goal)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 2, hour: 9), stop: date(day: 2, hour: 12)),
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: date(day: 3)
        )!
        #expect(progress.actualRevenue == Decimal(string: "99.99")!)
    }

    // MARK: Uncategorized

    @Test func uncategorizedSplitsByCause() {
        let month = july
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(80))
        let configured = client(goal: goal)
        var disabled = client(goal: goal)
        disabled.id = 2
        disabled.isEnabled = false
        var needsSetup = client(goal: nil)
        needsSetup.id = 3

        let entries = [
            TimeEntry(id: 1, clientID: nil, start: date(day: 3, hour: 9), stop: date(day: 3, hour: 10)),
            TimeEntry(id: 2, clientID: 2, start: date(day: 3, hour: 11), stop: date(day: 3, hour: 13)),
            TimeEntry(id: 3, clientID: 1, start: date(day: 3, hour: 14), stop: date(day: 3, hour: 15)),
            TimeEntry(id: 4, clientID: 3, start: date(day: 3, hour: 16), stop: date(day: 3, hour: 19)),
            // Entry pointing at a client Momenta has never seen: warn like no-client.
            TimeEntry(id: 5, clientID: 99, start: date(day: 3, hour: 20), stop: date(day: 3, hour: 20).addingTimeInterval(1800)),
        ]
        let summary = ProgressCalculator.uncategorized(
            entries: entries, clients: [configured, disabled, needsSetup],
            month: month, timeZone: utc, now: date(day: 4)
        )
        #expect(summary.noClientHours == 1.5)
        #expect(summary.disabledHours == 2)
        #expect(summary.needsSetupHours == 3)
    }

    // MARK: Aggregate

    @Test func monthAggregateComputesRevenueFraction() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(10))
        let config = client(pacing: .calendarDays, goal: goal)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 1, hour: 9), stop: date(day: 1, hour: 14)),
        ]
        let aggregate = ProgressCalculator.aggregate(
            clients: [config], entries: entries, month: july,
            period: .month, timeZone: utc, now: date(day: 15)
        )
        #expect(aggregate.targetRevenue == 1000)
        #expect(aggregate.actualRevenue == 500)
        #expect(aggregate.fraction == 0.5)
    }

    @Test func dayClientShareAndOverallBothFreezeTodaysGoalAtDayStart() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(50))
        let config = client(pacing: .weekdays, goal: goal)
        let now = date(day: 16, hour: 16)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 1, hour: 8), stop: date(day: 1, hour: 18)),   // 10h before today
            TimeEntry(id: 2, clientID: 1, start: date(day: 16, hour: 9), stop: date(day: 16, hour: 12)), // 3h today
        ]

        let clientProgress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: now
        )!
        let aggregate = ProgressCalculator.aggregate(
            clients: [config], entries: entries, month: july,
            period: .day, timeZone: utc, now: now
        )
        let share = aggregate.shares[0]

        // Today's goal comes from the 40h that remained before today began,
        // over the 12 scheduled days from July 16 through July 31. Today's own
        // 3h never enters its own denominator, so the By-Client ring and
        // Overall read the same fraction instead of diverging.
        #expect(share.targetHours == Decimal(40) / Decimal(12))
        #expect(share.targetRevenue == Decimal(4_000) / Decimal(12))
        #expect(abs(share.fraction - 0.9) < 0.000_001)
        #expect(aggregate.targetRevenue == share.targetRevenue)
        #expect(abs(aggregate.fraction - 0.9) < 0.000_001)

        // The month card's "/day to goal" keeps the live catch-up pace, which
        // today's 3h has already pulled below today's goal. That divergence is
        // the point: one is a rate going forward, the other is today's target.
        #expect(clientProgress.requiredDailyHours == Decimal(37) / Decimal(12))
        #expect(clientProgress.requiredDailyHours! < share.targetHours)
    }

    @Test func dayTargetCannotBeLoweredByWorkPerformedToday() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(100))
        let config = client(pacing: .calendarDays, goal: goal)
        let start = date(day: 22, hour: 8)
        let entries = [
            TimeEntry(
                id: 1,
                clientID: 1,
                start: start,
                stop: start.addingTimeInterval(9.1 * 3600)
            ),
        ]

        let aggregate = ProgressCalculator.aggregate(
            clients: [config], entries: entries, month: july,
            period: .day, timeZone: utc, now: date(day: 22, hour: 20)
        )

        // Ten calendar days remain, so today's goal freezes at 10h and 9.1h
        // reads as 91% — for Overall and the By-Client ring alike. Against a
        // target that fell as the work landed, the ring would already have
        // passed 100%: (100 − 9.1) / 10 = 9.09h is less than the 9.1h logged.
        #expect(aggregate.targetRevenue == 1_000)
        #expect(abs(aggregate.fraction - 0.91) < 0.000_001)
        #expect(aggregate.shares[0].targetRevenue == 1_000)
        #expect(abs(aggregate.shares[0].fraction - 0.91) < 0.000_001)
    }

    @Test func overallRevenueAllowsOneClientToOffsetAnother() {
        var cornerstone = client(
            pacing: .calendarDays,
            goal: MonthlyGoal(hourlyRate: 200, input: .hours(10))
        )
        cornerstone.id = 1
        var providence = client(
            pacing: .calendarDays,
            goal: MonthlyGoal(hourlyRate: 100, input: .hours(10))
        )
        providence.id = 2
        let entries = [
            // Cornerstone already produced $2,400 before the final day,
            // exceeding its own $2,000 goal while Providence remains at $0.
            TimeEntry(id: 1, clientID: 1, start: date(day: 1, hour: 8), stop: date(day: 1, hour: 20)),
            // Another $600 from Cornerstone reaches the combined $3,000 goal.
            TimeEntry(id: 2, clientID: 1, start: date(day: 31, hour: 9), stop: date(day: 31, hour: 12)),
        ]

        let aggregate = ProgressCalculator.aggregate(
            clients: [cornerstone, providence], entries: entries, month: july,
            period: .day, timeZone: utc, now: date(day: 31, hour: 13)
        )

        #expect(aggregate.targetRevenue == 600)
        #expect(aggregate.actualRevenue == 600)
        #expect(aggregate.fraction == 1)
        #expect(aggregate.shares[0].fraction == 1)
        #expect(aggregate.shares[1].fraction == 0)
    }

    @Test func completedMonthlyGoalMakesTodayRingCompleteAtZeroPace() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(10))
        let config = client(pacing: .weekdays, goal: goal)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 1, hour: 8), stop: date(day: 1, hour: 18)),
        ]

        let aggregate = ProgressCalculator.aggregate(
            clients: [config], entries: entries, month: july,
            period: .day, timeZone: utc, now: date(day: 16, hour: 16)
        )

        #expect(aggregate.shares[0].targetRevenue == 0)
        #expect(aggregate.shares[0].targetIsAvailable)
        #expect(aggregate.shares[0].fraction == 1)
        #expect(aggregate.fraction == 1)
    }

    @Test func needsSetupClientIsExcludedFromAggregate() {
        let configured = client(goal: MonthlyGoal(hourlyRate: 100, input: .hours(10)))
        var needsSetup = client(goal: nil)
        needsSetup.id = 3
        let entries = [
            TimeEntry(id: 1, clientID: 3, start: date(day: 1, hour: 9), stop: date(day: 1, hour: 14)),
        ]
        let aggregate = ProgressCalculator.aggregate(
            clients: [configured, needsSetup], entries: entries, month: july,
            period: .month, timeZone: utc, now: date(day: 15)
        )
        #expect(aggregate.shares.count == 1)
        #expect(aggregate.shares.first?.client.id == 1)
        #expect(aggregate.actualRevenue == 0)
    }

    @Test func periodReferenceCanAdvanceWithoutRepricingCachedActuals() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(31))
        let config = client(pacing: .calendarDays, goal: goal)
        let entries = [
            TimeEntry(
                id: 1,
                clientID: 1,
                start: date(day: 15, hour: 9),
                stop: date(day: 15, hour: 10)
            ),
        ]

        let aggregate = ProgressCalculator.aggregate(
            clients: [config],
            entries: entries,
            month: july,
            period: .day,
            timeZone: utc,
            now: date(day: 15, hour: 12),
            periodReference: date(day: 16, hour: 8)
        )

        // The cached snapshot says 30h remained before July 16, spread over
        // the 16 calendar days from the period reference through month end.
        #expect(aggregate.targetRevenue == Decimal(3_000) / Decimal(16))
        #expect(aggregate.actualRevenue == 0)
    }

    @Test func dayPeriodIntervalIsSingleDayInsideMonth() {
        let now = date(day: 15, hour: 10)
        let interval = ProgressCalculator.periodInterval(period: .day, month: july, timeZone: utc, now: now)
        #expect(interval.start == date(day: 15))
        #expect(interval.end == date(day: 16))
    }


    // MARK: Popover — day slice

    @Test func daySliceUsesTodaysGoalFrozenAtDayStart() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(50))
        let config = client(pacing: .weekdays, goal: goal)
        let now = date(day: 16, hour: 16)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 1, hour: 8), stop: date(day: 1, hour: 18)),   // 10h
            TimeEntry(id: 2, clientID: 1, start: date(day: 16, hour: 9), stop: date(day: 16, hour: 12)), // 3h today
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: now
        )!
        let slice = ProgressCalculator.daySlice(
            progress: progress, entries: entries, reference: now, timeZone: utc, now: now
        )
        // The reference day's own hours, not the 13h month cumulative.
        #expect(slice.actualHours == 3)
        #expect(slice.actualRevenue == 300)
        // Today's goal: the 40h banked before today, over the 12 scheduled
        // days from July 16 — not the live pace, which today's own 3h has
        // already pulled down to 37/12.
        #expect(slice.targetHours == Decimal(40) / Decimal(12))
        #expect(progress.requiredDailyHours == Decimal(37) / Decimal(12))
    }

    @Test func todaysGoalHoldsStillWhileWorkIsLoggedAgainstIt() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(40))
        let config = client(pacing: .calendarDays, goal: goal)

        // July 22 leaves 10 calendar days including today, so today asks 4h.
        func slice(loggedToday: Int, at now: Date) -> ClientPeriodSlice {
            let entries = loggedToday > 0
                ? [TimeEntry(
                    id: 1,
                    clientID: 1,
                    start: date(day: 22, hour: 8),
                    stop: date(day: 22, hour: 8 + loggedToday)
                  )]
                : []
            let progress = ProgressCalculator.progress(
                for: config, entries: entries, month: july, timeZone: utc, now: now
            )!
            return ProgressCalculator.daySlice(
                progress: progress, entries: entries, reference: now, timeZone: utc, now: now
            )
        }

        let morning = slice(loggedToday: 0, at: date(day: 22, hour: 7))
        let midday = slice(loggedToday: 2, at: date(day: 22, hour: 11))
        let done = slice(loggedToday: 4, at: date(day: 22, hour: 13))

        // One number for the whole day, whatever has been logged against it.
        #expect(morning.targetHours == 4)
        #expect(midday.targetHours == 4)
        #expect(done.targetHours == 4)
        // So 2h reads as half of today, and the day completes at 4h — not at
        // the 40/11 ≈ 3.64h a target that retreated as work landed would have.
        #expect(midday.actualHours * 2 == midday.targetHours)
        #expect(done.actualHours == done.targetHours)

        let almost = slice(loggedToday: 3, at: date(day: 22, hour: 12))
        #expect(almost.actualHours < almost.targetHours!)
    }

    @Test func todaysGoalAbsorbsYesterdaysShortfallAndSurplus() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(40))
        let config = client(pacing: .calendarDays, goal: goal)

        // July 21 leaves 11 days including itself, so it asked for 40/11h.
        func todaysGoal(yesterdayHours: Int) -> Decimal? {
            let entries = yesterdayHours > 0
                ? [TimeEntry(
                    id: 1,
                    clientID: 1,
                    start: date(day: 21, hour: 8),
                    stop: date(day: 21, hour: 8 + yesterdayHours)
                  )]
                : []
            let now = date(day: 22, hour: 10)
            let progress = ProgressCalculator.progress(
                for: config, entries: entries, month: july, timeZone: utc, now: now
            )!
            return ProgressCalculator.daySlice(
                progress: progress, entries: entries, reference: now, timeZone: utc, now: now
            ).targetHours
        }

        // Whatever yesterday left is spread over the 10 days from July 22.
        #expect(todaysGoal(yesterdayHours: 4) == Decimal(36) / Decimal(10))
        #expect(todaysGoal(yesterdayHours: 2) == Decimal(38) / Decimal(10))
        #expect(todaysGoal(yesterdayHours: 6) == Decimal(34) / Decimal(10))
        // Working short raises today; working over lowers it.
        #expect(todaysGoal(yesterdayHours: 2)! > todaysGoal(yesterdayHours: 4)!)
        #expect(todaysGoal(yesterdayHours: 6)! < todaysGoal(yesterdayHours: 4)!)
    }

    @Test func theLastScheduledDayAsksForEverythingStillOwed() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(40))
        let config = client(pacing: .calendarDays, goal: goal)
        let now = date(day: 31, hour: 10)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 1, hour: 8), stop: date(day: 1, hour: 8 + 33)),
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: now
        )!
        let slice = ProgressCalculator.daySlice(
            progress: progress, entries: entries, reference: now, timeZone: utc, now: now
        )
        // Meeting each day's shown goal lands the month exactly on target, so
        // the final day carries the whole remainder.
        #expect(slice.targetHours == 7)
    }

    @Test func daySlicePastDayFreezesPaceAtDayStart() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(50))
        let config = client(pacing: .weekdays, goal: goal)
        let now = date(day: 20, hour: 16)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 1, hour: 8), stop: date(day: 1, hour: 18)),   // 10h
            TimeEntry(id: 2, clientID: 1, start: date(day: 16, hour: 9), stop: date(day: 16, hour: 12)), // 3h on the 16th
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: now
        )!
        // Back-stepped to July 16 while the current day is July 20.
        let slice = ProgressCalculator.daySlice(
            progress: progress, entries: entries, reference: date(day: 16, hour: 8),
            timeZone: utc, now: now
        )
        // 10h logged before the 16th, frozen over the scheduled weekdays from
        // the 16th onward — the same pace requiredDailyHours produces at day start.
        let expected = ProgressCalculator.requiredDailyHours(
            goal: goal, actualHours: 10, month: july, pacing: .weekdays, timeZone: utc, now: date(day: 16)
        )
        #expect(slice.actualHours == 3)
        #expect(slice.targetHours == expected)
    }

    // MARK: Non-billable clients

    @Test func switchingBillingOffParksTheRateForTheWholeRoundTrip() {
        // The worst case: the current month is the only version carrying a
        // positive rate, so nothing earlier survives the hours-only edit.
        var config = client(pacing: .weekdays, goal: MonthlyGoal(hourlyRate: 120, input: .hours(40)))
        #expect(config.restorableHourlyRate == 120)

        config.setBillable(false, referenceMonth: july)
        // Editing hours while non-billable saves rate 0 over this month and
        // every later version, exactly as `ConfigStore.setGoal` does.
        config.goalHistory[july] = MonthlyGoal(hourlyRate: 0, input: .hours(15))

        // The rate is gone from history…
        #expect(config.effectiveRate(for: july) == nil)
        // …but survives for the prefill when billing comes back.
        #expect(config.restorableHourlyRate == 120)

        // Re-enabling restores the rate into the goal in the same mutation, so
        // the client is immediately configured again — not billable-but-
        // rate-less, which nothing afterwards would go back and repair.
        config.setBillable(true, referenceMonth: july)
        #expect(config.isBillable)
        #expect(config.goal(for: july)?.hourlyRate == 120)
        #expect(config.goal(for: july)?.hours == 15)
        #expect(config.hasCompleteGoal(for: july))
        #expect(config.state(for: july) == .configured)
    }

    @Test func reEnablingBillingRestoresEveryRatelessMonthButKeepsRecordedRates() {
        let june = YearMonth(year: 2026, month: 6)
        let august = YearMonth(year: 2026, month: 8)
        var config = client(goal: nil)
        config.goalHistory = [
            june: MonthlyGoal(hourlyRate: 80, input: .hours(30)),
            july: MonthlyGoal(hourlyRate: 120, input: .hours(40)),
        ]
        config.setBillable(false, referenceMonth: july)
        // The hours-only edit zeroes this month and every later one, exactly
        // as `ConfigStore.setGoal` forward-fills.
        config.goalHistory[july] = MonthlyGoal(hourlyRate: 0, input: .hours(15))
        config.goalHistory[august] = MonthlyGoal(hourlyRate: 0, input: .hours(15))

        config.setBillable(true, referenceMonth: july)

        #expect(config.goal(for: july)?.hourlyRate == 120)
        #expect(config.goal(for: august)?.hourlyRate == 120)
        // June carries a rate of its own, so it is left exactly as recorded.
        #expect(config.goal(for: june)?.hourlyRate == 80)
    }

    @Test func reEnablingBillingLeavesNoMonthPricedWithoutRecordingARate() {
        // One flag governs the whole history, and `effectiveRate` backfills a
        // later rate into any rate-less month — so a month left at rate 0
        // would render its hours as revenue its stored goal never recorded.
        let june = YearMonth(year: 2026, month: 6)
        var config = client(goal: nil)
        config.goalHistory = [june: MonthlyGoal(hourlyRate: 120, input: .hours(40))]
        config.setBillable(false, referenceMonth: june)
        config.goalHistory[june] = MonthlyGoal(hourlyRate: 0, input: .hours(15))

        config.setBillable(true, referenceMonth: july)

        // June is priced at 120 by the display layer either way; now the
        // stored goal says so too, and counts as configured rather than
        // sitting in needs-setup while its hours show revenue.
        #expect(config.goal(for: june)?.hourlyRate == 120)
        #expect(config.effectiveRate(for: june) == 120)
        #expect(config.hasCompleteGoal(for: june))
        #expect(config.state(for: june) == .configured)
    }

    @Test func reEnablingRestoresAGoalInheritedFromAnEarlierMonth() {
        // Switched off in June and switched back on in July, with no July
        // version of its own: July only inherits June's zeroed goal, so there
        // is no key at or after July for a restore to rewrite.
        let june = YearMonth(year: 2026, month: 6)
        var config = client(goal: nil)
        config.goalHistory = [june: MonthlyGoal(hourlyRate: 120, input: .hours(40))]
        config.setBillable(false, referenceMonth: june)
        config.goalHistory[june] = MonthlyGoal(hourlyRate: 0, input: .hours(15))
        #expect(config.goalHistory[july] == nil)

        config.setBillable(true, referenceMonth: july)

        #expect(config.goal(for: july)?.hourlyRate == 120)
        #expect(config.goal(for: july)?.hours == 15)
        #expect(config.hasCompleteGoal(for: july))
        #expect(config.state(for: july) == .configured)
    }

    @Test func aBillableClientWithARatelessGoalIsOfferedTheParkedRate() {
        // The state a crash between the two saves — or a merge that took the
        // flag from one side and the goal from the other — can leave behind.
        var config = client(goal: MonthlyGoal(hourlyRate: 0, input: .hours(15)))
        config.billableFlag = true
        config.dormantHourlyRate = 120

        #expect(!config.hasCompleteGoal(for: july))
        // The editor offers the parked rate; the ordinary auto-save stores it
        // on the next edit, focus change, or when the pane closes.
        #expect(config.editorHourlyRate(for: july) == 120)
    }

    @Test func aNonBillableClientIsNeverOfferedARate() {
        var config = client(goal: MonthlyGoal(hourlyRate: 0, input: .hours(15)))
        config.billableFlag = false
        config.dormantHourlyRate = 120

        #expect(config.editorHourlyRate(for: july) == nil)
    }

    @Test func aClientThatNeverToggledStillOffersItsHistoricRate() {
        // No parked rate: fall back to the newest positive rate on record.
        let june = YearMonth(year: 2026, month: 6)
        var config = client(goal: nil)
        config.goalHistory = [
            june: MonthlyGoal(hourlyRate: 90, input: .hours(30)),
            july: MonthlyGoal(hourlyRate: 110, input: .hours(40)),
        ]
        #expect(config.dormantHourlyRate == nil)
        #expect(config.restorableHourlyRate == 110)
    }

    @Test func nonBillableClientRendersHoursWithoutARate() {
        var config = client(pacing: .weekdays, goal: MonthlyGoal(hourlyRate: 0, input: .hours(40)))
        config.isBillable = false
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 1, hour: 8), stop: date(day: 1, hour: 12)), // 4h
        ]
        // An hours-only goal is complete without a rate.
        #expect(config.hasCompleteGoal(for: july))
        #expect(config.state(for: july) == .configured)

        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: date(day: 2, hour: 9)
        )
        #expect(progress != nil)
        #expect(progress?.hourlyRate == 0)
        #expect(progress?.actualHours == 4)
        // Revenue is a flat zero, but the hours goal line is present.
        #expect(progress?.actualRevenue == 0)
        #expect(progress?.plannedHoursToDate != nil)
    }

    @Test func nonBillableClientCountsInHoursAggregateWithZeroRevenue() {
        var config = client(pacing: .calendarDays, goal: MonthlyGoal(hourlyRate: 0, input: .hours(31)))
        config.isBillable = false
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 1, hour: 8), stop: date(day: 1, hour: 10)), // 2h
        ]
        let aggregate = ProgressCalculator.aggregate(
            clients: [config], entries: entries, month: july,
            period: .month, timeZone: utc, now: date(day: 15)
        )
        #expect(aggregate.shares.count == 1)
        #expect(aggregate.actualHours == 2)
        #expect(aggregate.targetHours == 31)
        // No rate, so the revenue track is a flat zero.
        #expect(aggregate.targetRevenue == 0)
    }

    @Test func daySliceOnRestDayHasNoTargetOrDebt() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(50))
        var config = client(pacing: .custom, goal: goal)
        config.customWorkDays = [1, 2, 3, 4, 7] // Thursday and Friday off
        let now = date(day: 23, hour: 16) // Thursday — a scheduled day off
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 1, hour: 8), stop: date(day: 1, hour: 18)),
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: now
        )!
        let slice = ProgressCalculator.daySlice(
            progress: progress, entries: entries, reference: now, timeZone: utc, now: now
        )
        // A day off carries a flat plan: no target and no behind/ahead debt,
        // even though the client still has a monthly goal in effect.
        #expect(slice.isRestDay)
        #expect(slice.hasGoal)
        #expect(slice.targetHours == nil)
        #expect(slice.deltaHours == nil)
    }

    @Test func daySliceOnAScheduledDayCarriesTodaysGoal() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(50))
        var config = client(pacing: .custom, goal: goal)
        config.customWorkDays = [1, 2, 3, 4, 7] // Thursday and Friday off
        let now = date(day: 22, hour: 16) // Wednesday — a work day
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 1, hour: 8), stop: date(day: 1, hour: 18)),
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: now
        )!
        let slice = ProgressCalculator.daySlice(
            progress: progress, entries: entries, reference: now, timeZone: utc, now: now
        )
        let expected = ProgressCalculator.requiredDailyHours(
            goal: goal, actualHours: 10, month: july, pacing: .custom,
            customWorkDays: config.customWorkDays, timeZone: utc, now: date(day: 22)
        )
        #expect(!slice.isRestDay)
        #expect(slice.targetHours == expected)
    }

    // MARK: Day timeline points

    @Test func dayTimelinePlanRampsOnlyInsideWorkWindow() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(50))
        var config = client(pacing: .calendarDays, goal: goal)
        config.workWindow = WorkWindow(startMinute: 9 * 60, endMinute: 17 * 60)
        let now = date(day: 16, hour: 20)
        let progress = ProgressCalculator.progress(
            for: config, entries: [], month: july, timeZone: utc, now: now
        )!
        let slice = ProgressCalculator.daySlice(
            progress: progress, entries: [], reference: now, timeZone: utc, now: now
        )
        let target = slice.targetHours!

        func planned(at hour: Int) -> Decimal? {
            slice.points.first { $0.day == date(day: 16, hour: hour) }?.plannedHours
        }
        // Flat zero before the window: an early morning owes nothing.
        #expect(planned(at: 0) == 0)
        #expect(planned(at: 9) == 0)
        // Full target at the window's end and through the rest of the day.
        #expect(planned(at: 17) == target)
        // The plan spans the whole day, so the last point sits at the day end.
        #expect(slice.points.last?.day == date(day: 17))
        #expect(slice.points.last?.plannedHours == target)
    }

    @Test func dayTimelineActualAccumulatesAlongEntriesAndStopsAtNow() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(50))
        let config = client(pacing: .calendarDays, goal: goal)
        let now = date(day: 16, hour: 14)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 16, hour: 9), stop: date(day: 16, hour: 11)), // 2h
            TimeEntry(id: 2, clientID: 1, start: date(day: 16, hour: 13), stop: nil), // running, 1h so far
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: now
        )!
        let slice = ProgressCalculator.daySlice(
            progress: progress, entries: entries, reference: now, timeZone: utc, now: now
        )

        func actual(at hour: Int) -> Decimal? {
            slice.points.first { $0.day == date(day: 16, hour: hour) }?.actualHours
        }
        #expect(actual(at: 9) == 0)
        #expect(actual(at: 11) == 2)
        // Flat between entries.
        #expect(actual(at: 13) == 2)
        // The tip sits at now with the day's attributed total (running entry
        // counted to the shared clock), then the future is unmeasured.
        #expect(actual(at: 14) == 3)
        #expect(actual(at: 14) == slice.actualHours)
        let futurePoints = slice.points.filter { $0.day > now }
        #expect(!futurePoints.isEmpty)
        #expect(futurePoints.allSatisfy { $0.actualHours == nil })
    }

    @Test func dayTimelineRestDayHasNoPlanButKeepsActual() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(50))
        var config = client(pacing: .custom, goal: goal)
        config.customWorkDays = [1, 2, 3, 4, 7] // Thursday and Friday off
        let now = date(day: 23, hour: 16) // Thursday — a scheduled day off
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 23, hour: 9), stop: date(day: 23, hour: 10)),
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: now
        )!
        let slice = ProgressCalculator.daySlice(
            progress: progress, entries: entries, reference: now, timeZone: utc, now: now
        )
        // Bonus hours still draw; the plan stays absent so nothing reads as debt.
        #expect(slice.points.allSatisfy { $0.plannedHours == nil })
        #expect(slice.points.contains { $0.actualHours == 1 })
    }

    @Test func dayTimelineTipPinsToAttributedTotalWhenEntrySpillsPastMidnight() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(50))
        let config = client(pacing: .calendarDays, goal: goal)
        let now = date(day: 20, hour: 12)
        let entries = [
            // Starts July 16 at 23:00, runs to July 17 at 02:00: 3h, all
            // attributed to the 16th by start time.
            TimeEntry(id: 1, clientID: 1, start: date(day: 16, hour: 23), stop: date(day: 17, hour: 2)),
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: now
        )!
        let slice = ProgressCalculator.daySlice(
            progress: progress, entries: entries, reference: date(day: 16, hour: 8),
            timeZone: utc, now: now
        )
        #expect(slice.actualHours == 3)
        // The curve grows only inside the day, but the final point pins to the
        // attributed total so the tip matches the bullet and marker.
        #expect(slice.points.last?.day == date(day: 17))
        #expect(slice.points.last?.actualHours == 3)
    }

    @Test func dayClientShareAndOverallAreNeutralOnRestDay() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(50))
        var config = client(pacing: .custom, goal: goal)
        config.customWorkDays = [1, 2, 3, 4, 7] // Thursday and Friday off
        let now = date(day: 23, hour: 16) // Thursday — a scheduled day off
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 1, hour: 8), stop: date(day: 1, hour: 18)),
        ]
        let aggregate = ProgressCalculator.aggregate(
            clients: [config], entries: entries, month: july,
            period: .day, timeZone: utc, now: now
        )
        // The By-Client ring reads neutral, not behind, and the Overall ring
        // zeroes the unscheduled day (100% against a 0 target) — the two views
        // now agree instead of diverging.
        #expect(aggregate.shares[0].targetRevenue == 0)
        #expect(!aggregate.shares[0].targetIsAvailable)
        #expect(aggregate.targetRevenue == 0)
        #expect(aggregate.fraction == 1)
    }

    @Test func nonBillableScheduledClientRingReadsHoursNotRevenue() {
        var config = client(pacing: .weekdays, goal: MonthlyGoal(hourlyRate: 0, input: .hours(20)))
        config.isBillable = false
        let now = date(day: 22, hour: 16) // Wednesday work day, nothing logged
        let aggregate = ProgressCalculator.aggregate(
            clients: [config], entries: [], month: july,
            period: .day, timeZone: utc, now: now
        )
        let share = aggregate.shares[0]
        // The revenue ring is a meaningless full ring (target 0, available)…
        #expect(share.fraction == 1)
        // …but the hours ring correctly shows nothing done against a real pace,
        // which is what the menu bar now draws in hours mode.
        #expect(share.hoursTargetIsAvailable)
        #expect(share.targetHours > 0)
        #expect(share.hoursFraction == 0)
    }

    @Test func dayOverallHoursCountsOnlyClientsScheduledToday() {
        var working = client(pacing: .calendarDays, goal: MonthlyGoal(hourlyRate: 100, input: .hours(9)))
        working.id = 1
        var offToday = client(pacing: .custom, goal: MonthlyGoal(hourlyRate: 100, input: .hours(50)))
        offToday.id = 2
        offToday.customWorkDays = [1, 2, 3, 4, 6, 7] // Thursday off
        let now = date(day: 23, hour: 16) // Thursday
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 23, hour: 9), stop: date(day: 23, hour: 10)),  // 1h scheduled
            TimeEntry(id: 2, clientID: 2, start: date(day: 23, hour: 10), stop: date(day: 23, hour: 12)), // 2h on a day off
        ]
        let aggregate = ProgressCalculator.aggregate(
            clients: [working, offToday], entries: entries, month: july,
            period: .day, timeZone: utc, now: now
        )
        // Only the calendar-days client works today: its frozen pace is
        // 9h over the 9 remaining days = 1h. The off-today client must not
        // push its 50h catch-up onto a day it does not work — and its 2h of
        // rest-day work must not complete the working client's target either:
        // both sides of the Overall fraction cover the scheduled cohort only.
        #expect(aggregate.targetHours == 1)
        #expect(aggregate.actualHours == 1)
        let scheduled = aggregate.shares.first { $0.id == 1 }
        let off = aggregate.shares.first { $0.id == 2 }
        #expect(scheduled?.hoursTargetIsAvailable == true)
        #expect(off?.hoursTargetIsAvailable == false)
    }

    // MARK: Popover — week slice

    @Test func weekSliceIsWeekLocalAndStopsAtElapsedDays() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(46)) // 2h across each of 23 weekdays
        let config = client(pacing: .weekdays, goal: goal)
        let now = date(day: 15, hour: 23) // Wed July 15
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 6, hour: 9), stop: date(day: 6, hour: 14)),   // prior week, excluded
            TimeEntry(id: 2, clientID: 1, start: date(day: 13, hour: 9), stop: date(day: 13, hour: 13)), // Mon 4h
            TimeEntry(id: 3, clientID: 1, start: date(day: 14, hour: 9), stop: date(day: 14, hour: 11)), // Tue 2h
            TimeEntry(id: 4, clientID: 1, start: date(day: 15, hour: 9), stop: date(day: 15, hour: 12)), // Wed 3h
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: now
        )!
        let slice = ProgressCalculator.weekSlice(
            client: config, progressByMonth: [july: progress], reference: date(day: 15, hour: 12), timeZone: utc
        )
        #expect(slice.points.count == 7)
        // Week-local cumulative, excluding the prior week's 5h.
        #expect(slice.points[0].actualHours == 4) // Mon 13
        #expect(slice.points[2].actualHours == 9) // Wed 15
        #expect(slice.actualHours == 9)
        // Days after Wednesday are not elapsed.
        #expect(slice.points[3].actualHours == nil) // Thu 16
        #expect(slice.points[6].actualHours == nil) // Sun 19
        // Weekends add no planned progress under weekday pacing.
        #expect(slice.points[5].plannedHours == slice.points[4].plannedHours) // Sat 18 flat
        #expect(slice.points[6].plannedHours == slice.points[5].plannedHours) // Sun 19 flat
        // Only 5h was completed before Monday. The remaining 41h is spread
        // across the 15 weekdays from Jul 13 through month end, so this week's
        // frozen catch-up target is 41 / 15 × 5 rather than the static 10h.
        #expect(abs(((slice.targetHours ?? 0) - Decimal(41) / Decimal(3)).doubleValue) < 0.000_001)
        #expect(abs(((slice.plannedToDateHours ?? 0) - Decimal(41) / Decimal(5)).doubleValue) < 0.000_001)
        #expect(abs(((slice.deltaHours ?? 0) - Decimal(4) / Decimal(5)).doubleValue) < 0.000_001)
    }

    @Test func weeklyCatchUpCarriesEarlierShortfallThroughRemainingWeeks() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(46))
        let config = client(pacing: .weekdays, goal: goal)
        let entries = [
            // Only 10h completed before Jul 13, versus the original 16h pace.
            TimeEntry(id: 1, clientID: 1, start: date(day: 6, hour: 8), stop: date(day: 6, hour: 18)),
            // Then follow the catch-up target exactly in each remaining week.
            TimeEntry(id: 2, clientID: 1, start: date(day: 13, hour: 8), stop: date(day: 13, hour: 20)),
            TimeEntry(id: 3, clientID: 1, start: date(day: 20, hour: 8), stop: date(day: 20, hour: 20)),
            TimeEntry(id: 4, clientID: 1, start: date(day: 27, hour: 8), stop: date(day: 27, hour: 20)),
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: date(day: 31, hour: 23)
        )!

        func target(for day: Int) -> Decimal? {
            ProgressCalculator.weekSlice(
                client: config,
                progressByMonth: [july: progress],
                reference: date(day: day, hour: 12),
                timeZone: utc
            ).targetHours
        }

        // At Jul 13, 36h remains across 15 weekdays: 12h per five-day week.
        // Meeting each frozen target keeps the later targets at 12h and lands
        // exactly on the 46h monthly goal.
        #expect(target(for: 13) == 12)
        #expect(target(for: 20) == 12)
        #expect(target(for: 27) == 12)
        #expect(progress.actualHours == 46)
    }

    @Test func weeklyCatchUpTargetIsFrozenAgainstWorkInsideTheWeek() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(46))
        let config = client(pacing: .weekdays, goal: goal)
        let beforeOnly = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 6, hour: 8), stop: date(day: 6, hour: 18)),
        ]
        let withCurrentWeek = beforeOnly + [
            TimeEntry(id: 2, clientID: 1, start: date(day: 13, hour: 8), stop: date(day: 13, hour: 20)),
        ]
        let beforeProgress = ProgressCalculator.progress(
            for: config, entries: beforeOnly, month: july, timeZone: utc, now: date(day: 15, hour: 23)
        )!
        let currentProgress = ProgressCalculator.progress(
            for: config, entries: withCurrentWeek, month: july, timeZone: utc, now: date(day: 15, hour: 23)
        )!

        let beforeTarget = ProgressCalculator.weekSlice(
            client: config,
            progressByMonth: [july: beforeProgress],
            reference: date(day: 15),
            timeZone: utc
        ).targetHours
        let currentTarget = ProgressCalculator.weekSlice(
            client: config,
            progressByMonth: [july: currentProgress],
            reference: date(day: 15),
            timeZone: utc
        ).targetHours

        #expect(beforeTarget == 12)
        #expect(currentTarget == beforeTarget)
    }

    @Test func weekSliceStitchesAcrossMonthBoundary() {
        let june = YearMonth(year: 2026, month: 6)
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(46))
        var config = client(pacing: .weekdays, goal: goal)
        config.goalHistory[june] = goal
        let juneStart = june.start(in: utc)
        func juneDate(day: Int, hour: Int) -> Date {
            juneStart.addingTimeInterval(TimeInterval((day - 1) * 86400 + hour * 3600))
        }
        // The week of Mon June 29 – Sun July 5 straddles the boundary.
        let now = date(day: 2, hour: 23) // Thu July 2, evening
        let juneEntries = [
            TimeEntry(id: 1, clientID: 1, start: juneDate(day: 29, hour: 9), stop: juneDate(day: 29, hour: 11)), // Mon 2h
            TimeEntry(id: 2, clientID: 1, start: juneDate(day: 30, hour: 9), stop: juneDate(day: 30, hour: 12)), // Tue 3h
        ]
        let julyEntries = [
            TimeEntry(id: 3, clientID: 1, start: date(day: 1, hour: 9), stop: date(day: 1, hour: 10)), // Wed 1h
            TimeEntry(id: 4, clientID: 1, start: date(day: 2, hour: 9), stop: date(day: 2, hour: 11)), // Thu 2h
        ]
        let juneProgress = ProgressCalculator.progress(
            for: config, entries: juneEntries, month: june, timeZone: utc, now: now
        )!
        let julyProgress = ProgressCalculator.progress(
            for: config, entries: julyEntries, month: july, timeZone: utc, now: now
        )!
        let slice = ProgressCalculator.weekSlice(
            client: config,
            progressByMonth: [june: juneProgress, july: julyProgress],
            reference: date(day: 2, hour: 12),
            timeZone: utc
        )
        #expect(slice.points.count == 7)
        // Stitched cumulative across the boundary: 2, 5, 6, 8.
        #expect(slice.points[0].actualHours == 2) // Mon Jun 29
        #expect(slice.points[1].actualHours == 5) // Tue Jun 30
        #expect(slice.points[2].actualHours == 6) // Wed Jul 1
        #expect(slice.points[3].actualHours == 8) // Thu Jul 2
        #expect(slice.points[4].actualHours == nil) // Fri Jul 3 not elapsed
        #expect(slice.actualHours == 8)
    }

    // MARK: Popover — Overall hours

    @Test func monthAggregateSumsHours() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(10))
        let config = client(pacing: .calendarDays, goal: goal)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 1, hour: 9), stop: date(day: 1, hour: 14)), // 5h
        ]
        let aggregate = ProgressCalculator.aggregate(
            clients: [config], entries: entries, month: july, period: .month, timeZone: utc, now: date(day: 15)
        )
        #expect(aggregate.actualHours == 5)
        #expect(aggregate.targetHours == 10)
        #expect(aggregate.hoursFraction == 0.5)
    }

    @Test func overallDayHoursTargetMirrorsRevenueFreeze() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(100))
        let config = client(pacing: .calendarDays, goal: goal)
        let start = date(day: 22, hour: 8)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: start, stop: start.addingTimeInterval(9.1 * 3600)),
        ]
        let aggregate = ProgressCalculator.aggregate(
            clients: [config], entries: entries, month: july, period: .day, timeZone: utc, now: date(day: 22, hour: 20)
        )
        // Ten calendar days remain; frozen hours target = 100h / 10 days.
        #expect(aggregate.targetHours == 10)
        #expect(aggregate.actualHours == Decimal(string: "9.1")!)
        #expect(abs(aggregate.hoursFraction - 0.91) < 0.000_001)
    }

    @Test func backSteppedDayOverallFreezeIgnoresLaterWork() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(100))
        let config = client(pacing: .calendarDays, goal: goal)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 10, hour: 8), stop: date(day: 10, hour: 18)), // 10h before
            TimeEntry(id: 2, clientID: 1, start: date(day: 15, hour: 9), stop: date(day: 15, hour: 13)), // 4h on the day
            TimeEntry(id: 3, clientID: 1, start: date(day: 18, hour: 8), stop: date(day: 18, hour: 16)), // 8h after
        ]
        // Popover back-stepped to July 15 while "now" is July 20.
        let aggregate = ProgressCalculator.aggregate(
            clients: [config], entries: entries, month: july,
            period: .day, timeZone: utc, now: date(day: 20, hour: 12),
            periodReference: date(day: 15, hour: 8)
        )
        // Only the 10h logged before July 15 reduce the day-start remaining;
        // the 8h logged July 18 must not. 90h spread over the 17 calendar
        // days from July 15 through 31, in both units.
        #expect(aggregate.actualHours == 4)
        #expect(aggregate.actualRevenue == 400)
        #expect(aggregate.targetHours == Decimal(90) / Decimal(17))
        #expect(aggregate.targetRevenue == Decimal(9_000) / Decimal(17))
    }

    @Test func weekAggregateBuildsSharesAndTotalsFromSlices() {
        // Two clients with different rates: the aggregate's Overall and its
        // per-client shares must both come from the same slices the cards
        // render, in the order given.
        var cornerstone = client(
            pacing: .weekdays, goal: MonthlyGoal(hourlyRate: 80, input: .hours(46))
        )
        cornerstone.id = 1
        var providence = client(
            pacing: .weekdays, goal: MonthlyGoal(hourlyRate: 100, input: .hours(46))
        )
        providence.id = 2
        let now = date(day: 15, hour: 23)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 13, hour: 9), stop: date(day: 13, hour: 13)),
            TimeEntry(id: 2, clientID: 2, start: date(day: 15, hour: 9), stop: date(day: 15, hour: 12)),
        ]
        let slices = [cornerstone, providence].map { config in
            ProgressCalculator.weekSlice(
                client: config,
                progressByMonth: [july: ProgressCalculator.progress(
                    for: config, entries: entries, month: july, timeZone: utc, now: now
                )!],
                reference: now,
                timeZone: utc
            )
        }

        let aggregate = ProgressCalculator.weekAggregate(slices: slices)!

        #expect(aggregate.shares.count == 2)
        #expect(aggregate.shares[0].client.id == 1)
        #expect(aggregate.shares[1].client.id == 2)
        #expect(aggregate.shares[0].actualRevenue == slices[0].actualRevenue)
        #expect(aggregate.shares[0].targetRevenue == slices[0].targetRevenue)
        #expect(aggregate.shares[1].actualRevenue == slices[1].actualRevenue)
        #expect(aggregate.actualHours == slices[0].actualHours + slices[1].actualHours)
        #expect(aggregate.targetHours == (slices[0].targetHours ?? 0) + (slices[1].targetHours ?? 0))
        #expect(aggregate.actualRevenue == slices[0].actualRevenue + slices[1].actualRevenue)
        #expect(aggregate.targetRevenue == (slices[0].targetRevenue ?? 0) + (slices[1].targetRevenue ?? 0))
    }

    @Test func weekAggregateIsNilWithoutAnyGoal() {
        // A rate-backfilled history slice (no goal) renders a card but must
        // not fabricate an Overall.
        let june = YearMonth(year: 2026, month: 6)
        let config = client(goal: MonthlyGoal(hourlyRate: 120, input: .hours(80)))
        let juneStart = june.start(in: utc)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: juneStart.addingTimeInterval(9 * 3600),
                      stop: juneStart.addingTimeInterval(12 * 3600)),
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: june, timeZone: utc, now: date(day: 10)
        )!
        let slice = ProgressCalculator.weekSlice(
            client: config,
            progressByMonth: [june: progress],
            reference: juneStart.addingTimeInterval(3600),
            timeZone: utc
        )
        #expect(slice.hasGoal == false)
        #expect(ProgressCalculator.weekAggregate(slices: [slice]) == nil)
    }

    @Test func completedMonthlyGoalMakesZeroCatchUpWeekComplete() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(10))
        let config = client(pacing: .weekdays, goal: goal)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 6, hour: 8), stop: date(day: 6, hour: 18)),
        ]
        let progress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: date(day: 15, hour: 12)
        )!
        let slice = ProgressCalculator.weekSlice(
            client: config,
            progressByMonth: [july: progress],
            reference: date(day: 15),
            timeZone: utc
        )
        let aggregate = ProgressCalculator.weekAggregate(slices: [slice])!

        #expect(slice.hasGoal)
        #expect(slice.targetHours == 0)
        #expect(slice.targetRevenue == 0)
        #expect(aggregate.targetIsAvailable)
        #expect(aggregate.hoursTargetIsAvailable)
        #expect(aggregate.fraction == 1)
        #expect(aggregate.hoursFraction == 1)
    }

    @Test func forwardStraddleWeekIncludesSynthesizedNextMonthPlanned() {
        // The week of Mon July 27 – Sun Aug 2 straddles forward. August's
        // progress is synthesized locally: empty entries, planned line from
        // the inherited goal, all actuals nil.
        let august = YearMonth(year: 2026, month: 8)
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(31)) // 1h/day in July (31 days)
        let config = client(pacing: .calendarDays, goal: goal)
        let now = date(day: 31, hour: 18)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 27, hour: 9), stop: date(day: 27, hour: 11)), // Mon 2h
        ]
        let julyProgress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: now
        )!
        // Synthesis: no entries, `now` still inside July.
        let augustProgress = ProgressCalculator.progress(
            for: config, entries: [], month: august, timeZone: utc, now: now
        )!
        #expect(augustProgress.points.allSatisfy { $0.actualHours == nil })

        let slice = ProgressCalculator.weekSlice(
            client: config,
            progressByMonth: [july: julyProgress, august: augustProgress],
            reference: date(day: 29),
            timeZone: utc
        )
        #expect(slice.points.count == 7)
        // Planned values telescope through 31 × (k/31) Decimal divisions, so
        // compare at display precision rather than bit-exact equality.
        func expectClose(_ value: Decimal?, _ expected: Decimal) {
            #expect(value != nil && abs(((value ?? 0) - expected).doubleValue) < 0.000_001)
        }
        // At the Jul 27 freeze no July work existed, so all 31h remaining are
        // assigned across Jul 27–31. August starts a new monthly segment and
        // contributes its normal first two calendar days at 1h/day.
        expectClose(slice.targetHours, 33)
        expectClose(slice.targetRevenue, 3_300)
        // August days chart planned but stay non-elapsed.
        #expect(slice.points[5].actualHours == nil) // Sat Aug 1
        #expect(slice.points[6].actualHours == nil) // Sun Aug 2
        expectClose(slice.points[6].plannedHours, 33)
        // Actuals stop at the last elapsed July day.
        #expect(slice.actualHours == 2)
        expectClose(slice.plannedToDateHours, 31) // July remainder due by Jul 31
    }
}

struct MockDataProviderTests {
    let utc = TimeZone(identifier: "UTC")!

    @Test func snapshotsAreDeterministic() async throws {
        let provider = MockDataProvider()
        let month = YearMonth(year: 2026, month: 6)
        let now = YearMonth(year: 2026, month: 7).start(in: utc)
        let first = try await provider.loadSnapshot(for: month, timeZone: utc, now: now)
        let second = try await provider.loadSnapshot(for: month, timeZone: utc, now: now)
        #expect(first.entries == second.entries)
        #expect(!first.entries.isEmpty)
    }

    @Test func snapshotContainsNoFutureEntries() async throws {
        let provider = MockDataProvider()
        let now = Date()
        let month = YearMonth(containing: now, timeZone: utc)
        let snapshot = try await provider.loadSnapshot(for: month, timeZone: utc, now: now)
        #expect(snapshot.entries.allSatisfy { $0.start <= now && ($0.stop ?? now) <= now })
    }

    @Test func clientsCoverAllFourStates() {
        let clients = MockDataProvider.sampleClients()
        let month = YearMonth(containing: Date(), timeZone: .current)
        let states = Set(clients.map { $0.state(for: month) })
        #expect(states.contains(.configured))
        #expect(states.contains(.needsSetup))
        #expect(states.contains(.disabled))
        #expect(states.contains(.archived))
    }
}
