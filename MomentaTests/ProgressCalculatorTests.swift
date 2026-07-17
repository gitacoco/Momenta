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

    @Test func dayClientShareUsesCatchUpPaceWhileOverallFreezesAtDayStart() {
        let goal = MonthlyGoal(hourlyRate: 100, input: .hours(50))
        let config = client(pacing: .weekdays, goal: goal)
        let now = date(day: 16, hour: 16)
        let entries = [
            TimeEntry(id: 1, clientID: 1, start: date(day: 1, hour: 8), stop: date(day: 1, hour: 18)),
            TimeEntry(id: 2, clientID: 1, start: date(day: 16, hour: 9), stop: date(day: 16, hour: 12)),
        ]

        let clientProgress = ProgressCalculator.progress(
            for: config, entries: entries, month: july, timeZone: utc, now: now
        )!
        let aggregate = ProgressCalculator.aggregate(
            clients: [config], entries: entries, month: july,
            period: .day, timeZone: utc, now: now
        )
        let share = aggregate.shares[0]

        // 13h completed leaves 37h over the 12 scheduled days from July 16
        // through July 31. Today's 3h is therefore below the 37/12h pace.
        #expect(clientProgress.requiredDailyHours == Decimal(37) / Decimal(12))
        #expect(share.targetRevenue == clientProgress.requiredDailyHours! * 100)
        #expect(abs(share.fraction - (36.0 / 37.0)) < 0.000_001)
        #expect(share.fraction < 1)

        // Overall uses the 40h remaining before today's 3h began. Its target
        // stays fixed at 40/12h even while the client card's live pace falls.
        #expect(aggregate.targetRevenue == Decimal(4_000) / Decimal(12))
        #expect(abs(aggregate.fraction - 0.9) < 0.000_001)
    }

    @Test func overallDayTargetCannotBeLoweredByWorkPerformedToday() {
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

        // Ten calendar days remain. The frozen target is 10h, so 9.1h is
        // only 91% rather than a false completion against a falling target.
        #expect(aggregate.targetRevenue == 1_000)
        #expect(abs(aggregate.fraction - 0.91) < 0.000_001)
        #expect(aggregate.shares[0].fraction > 1)
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

    @Test func weekPeriodIntervalIsClippedToMonth() {
        // July 1, 2026 is a Wednesday: its week starts Monday June 29.
        let now = date(day: 1, hour: 10)
        let interval = ProgressCalculator.periodInterval(period: .week, month: july, timeZone: utc, now: now)
        #expect(interval.start == july.start(in: utc))
        #expect(interval.end == date(day: 6)) // Monday July 6, exclusive
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
