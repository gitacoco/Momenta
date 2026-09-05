import Foundation
import Testing
@testable import Momenta

struct GoalOutlookTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let september = YearMonth(year: 2026, month: 9)

    private func date(_ day: Int, hour: Int = 0) -> Date {
        CalendarDay(year: 2026, month: 9, day: day).date(in: utc)
            .addingTimeInterval(TimeInterval(hour * 3600))
    }

    private func client() -> ClientConfig {
        ClientConfig(
            id: 1, workspaceID: 1, workspaceName: "Studio", togglName: "Client",
            colorHex: "#123456", isEnabled: true, isArchivedInToggl: false,
            pacing: .weekdays, goalHistory: [september: MonthlyGoal(hourlyRate: 200, input: .hours(80))]
        )
    }

    private func snapshot() -> TimeEntrySnapshot {
        TimeEntrySnapshot(month: september, fetchedAt: date(4, hour: 10), entries: [
            TimeEntry(id: 1, clientID: 1, start: date(2), stop: date(2, hour: 18)),
            TimeEntry(id: 2, clientID: 1, start: date(4, hour: 8), stop: date(4, hour: 10)),
        ])
    }

    @Test func monthlyTotalSubtractsLoggedHoursIncludingToday() {
        let original = GoalOutlook(goalHours: 80, client: client(), snapshot: snapshot(), timeZone: utc, now: date(4, hour: 10))
        let revised = GoalOutlook(goalHours: 70, client: client(), snapshot: snapshot(), timeZone: utc, now: date(4, hour: 10))
        #expect(original.loggedHours == 20)
        #expect(original.plannedDays == 18)
        #expect(original.remainingHours == 60)
        #expect(Format.hoursAndMinutes(original.hoursPerPlannedDay!) == "3h 20m")
        #expect(revised.remainingHours == 50)
        #expect(Format.hoursAndMinutes(revised.hoursPerPlannedDay!) == "2h 47m")
    }

    @Test(arguments: [PacingMode.weekdays, .calendarDays, .custom])
    func denominatorFollowsPlannedDays(pacing: PacingMode) {
        var config = client()
        config.pacing = pacing
        config.customWorkDays = [2, 4, 6]
        let result = GoalOutlook(goalHours: 80, client: config, snapshot: snapshot(), timeZone: utc, now: date(4, hour: 10))
        let expected = pacing == .weekdays ? 18 : (pacing == .calendarDays ? 26 : 11)
        #expect(result.plannedDays == expected)
    }

    @Test func daysOffExcludeOnlyMatchingFuturePlannedDates() {
        var config = client()
        config.daysOff = [
            CalendarDay(year: 2026, month: 9, day: 4), // Today, already excluded.
            CalendarDay(year: 2026, month: 9, day: 6), // Sunday, already excluded.
            CalendarDay(year: 2026, month: 9, day: 7), // Future planned Monday.
            CalendarDay(year: 2026, month: 10, day: 7),
        ]
        let result = GoalOutlook(goalHours: 80, client: config, snapshot: snapshot(), timeZone: utc, now: date(4, hour: 10))
        #expect(result.plannedDays == 17)
        #expect(result.loggedHours == 20) // Work on today's day off still counts.
        #expect(result.hoursPerPlannedDay == Decimal(60) / 17)
        #expect(config.goal(for: september)?.hours == 80)
    }

    @Test func actualsStayAtSnapshotWhilePlanningHorizonUsesCurrentDay() {
        var snapshot = snapshot()
        snapshot.entries[1].stop = nil
        snapshot.entries += [
            TimeEntry(id: 3, clientID: 2, start: date(3), stop: date(3, hour: 10)),
            TimeEntry(id: 4, clientID: 1, start: september.previous.start(in: utc), stop: september.previous.start(in: utc).addingTimeInterval(3600)),
            TimeEntry(id: 5, clientID: 1, start: date(20), stop: date(20, hour: 10)),
        ]
        let result = GoalOutlook(goalHours: 80, client: client(), snapshot: snapshot, timeZone: utc, now: date(7, hour: 12))
        #expect(result.loggedHours == 20) // Running entry stops at the snapshot's 10 AM cutoff.
        #expect(result.plannedDays == 17) // Today is now Monday, not the snapshot's Friday.
    }

    @Test func lastDayPreservesRemainingGoalWithoutInventingADailyRate() {
        let result = GoalOutlook(goalHours: 100, client: client(), snapshot: snapshot(), timeZone: utc, now: date(30, hour: 10))
        #expect(result.plannedDays == 0)
        #expect(result.remainingHours == 80)
        #expect(result.hoursPerPlannedDay == nil)
    }

    @Test(arguments: [Decimal(0), 15, 20])
    func completedGoalNeedsNoAdditionalHoursEvenWithoutFutureDays(goal: Decimal) {
        let result = GoalOutlook(goalHours: goal, client: client(), snapshot: snapshot(), timeZone: utc, now: date(30, hour: 10))
        #expect(result.remainingHours == 0)
        #expect(result.hoursPerPlannedDay == 0)
    }

    @Test func durationFormattingCarriesRoundedMinutesAndKeepsSmallRemaindersVisible() {
        #expect(Format.hoursAndMinutes(Decimal(string: "2.999")!) == "3h")
        #expect(Format.hoursAndMinutes(Decimal(string: "0.001")!) == "<1m")
        #expect(Format.hoursAndMinutes(0) == "0h")
        #expect(Format.hoursAndMinutes(100) == "100h")
    }
}
