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
        #expect(progress.points[5].plannedHours > progress.points[4].plannedHours)
    }

    @Test func noProgressForClientWithoutCompleteGoal() {
        let progress = ProgressCalculator.progress(
            for: client(goal: nil), entries: [], month: july, timeZone: utc, now: date(day: 10)
        )
        #expect(progress == nil)
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

    @Test func clientsCoverAllFourStates() async throws {
        let provider = MockDataProvider()
        let clients = try await provider.loadClients()
        let month = YearMonth(containing: Date(), timeZone: .current)
        let states = Set(clients.map { $0.state(for: month) })
        #expect(states.contains(.configured))
        #expect(states.contains(.needsSetup))
        #expect(states.contains(.disabled))
        #expect(states.contains(.archived))
    }
}
