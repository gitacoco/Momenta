import Foundation
import Testing
@testable import Momenta

struct DaysOffTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let september = YearMonth(year: 2026, month: 9)

    private func day(_ number: Int) -> CalendarDay { CalendarDay(year: 2026, month: 9, day: number) }
    private func date(_ number: Int) -> Date { day(number).date(in: utc) }
    private func client() -> ClientConfig {
        ClientConfig(
            id: 1, workspaceID: 1, workspaceName: "Studio", togglName: "Client",
            colorHex: "#123456", isEnabled: true, isArchivedInToggl: false,
            pacing: .weekdays, daysOff: [day(7)],
            goalHistory: [september: MonthlyGoal(hourlyRate: 100, input: .hours(84))]
        )
    }

    @Test func monthPlanPausesOnDayOffAndStillReachesFullGoal() throws {
        let progress = try #require(ProgressCalculator.progress(
            for: client(), entries: [], month: september, timeZone: utc, now: date(8)
        ))
        #expect(progress.points[6].plannedHours == progress.points[5].plannedHours)
        #expect(abs((progress.points[6].plannedHours ?? 0) - 16) < Decimal(string: "0.000001")!)
        #expect(progress.points.last?.plannedHours == 84)
        #expect(progress.requiredDailyHours == Decimal(84) / 17)
    }

    @Test func dayOffHasNoTargetButLoggedWorkCountsAndReducesFuturePace() throws {
        let entry = TimeEntry(id: 1, clientID: 1, start: date(7), stop: date(7).addingTimeInterval(4 * 3600))
        let progress = try #require(ProgressCalculator.progress(
            for: client(), entries: [entry], month: september, timeZone: utc, now: date(8)
        ))
        let slice = ProgressCalculator.daySlice(progress: progress, entries: [entry], reference: date(7), timeZone: utc, now: date(8))
        #expect(slice.isRestDay)
        #expect(slice.targetHours == nil)
        #expect(slice.actualHours == 4)
        #expect(progress.actualHours == 4)
        #expect(progress.requiredDailyHours == Decimal(80) / 17)
        let next = ProgressCalculator.daySlice(progress: progress, entries: [entry], reference: date(8), timeZone: utc, now: date(8))
        #expect(next.targetHours == Decimal(80) / 17)
    }

    @Test func dayAggregateExcludesOnlyTheClientTakingTimeOff() {
        var other = client()
        other.id = 2
        other.daysOff = nil
        let aggregate = ProgressCalculator.aggregate(
            clients: [client(), other], entries: [], month: september, period: .day,
            timeZone: utc, now: date(7)
        )
        #expect(aggregate.shares[0].hoursTargetIsAvailable == false)
        #expect(aggregate.shares[0].targetHours == 0)
        #expect(aggregate.shares[1].targetHours == Decimal(84) / 18)
        #expect(aggregate.targetHours == aggregate.shares[1].targetHours)
    }

    @Test func crossMonthWeekUsesDateExceptionsInEachMonth() throws {
        var config = client()
        let august = september.previous
        config.goalHistory[august] = MonthlyGoal(hourlyRate: 100, input: .hours(10))
        config.goalHistory[september] = MonthlyGoal(hourlyRate: 100, input: .hours(21))
        config.daysOff = [CalendarDay(year: 2026, month: 8, day: 31), day(1)]
        let augustProgress = try #require(ProgressCalculator.progress(for: config, entries: [], month: august, timeZone: utc, now: date(4)))
        let septemberProgress = try #require(ProgressCalculator.progress(for: config, entries: [], month: september, timeZone: utc, now: date(4)))
        let week = ProgressCalculator.weekSlice(client: config, progressByMonth: [august: augustProgress, september: septemberProgress], reference: date(4), timeZone: utc)
        #expect(week.points[0].plannedHours == 0)
        #expect(week.points[1].plannedHours == 0)
        #expect(week.targetHours == 3)
        #expect(ProgressCalculator.weekAggregate(slices: [week])?.targetHours == 3)
    }

    @Test func takingAnEntireMonthOffDoesNotEraseMonthlyCommitment() {
        var config = client()
        config.daysOff = Set((1...30).map(day))
        let aggregate = ProgressCalculator.aggregate(clients: [config], entries: [], month: september, period: .month, timeZone: utc, now: date(4))
        #expect(aggregate.targetHours == 84)
        #expect(aggregate.targetRevenue == 8400)
        #expect(aggregate.hoursFraction == 0)
        let outlook = GoalOutlook(goalHours: 84, client: config, snapshot: TimeEntrySnapshot(month: september, fetchedAt: date(4), entries: []), timeZone: utc, now: date(4))
        #expect(outlook.plannedDays == 0)
        #expect(outlook.hoursPerPlannedDay == nil)
    }

    @Test func civilDatesSurviveTimeZoneChangesAndDST() throws {
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let november = YearMonth(year: 2026, month: 11)
        let off = CalendarDay(year: 2026, month: 11, day: 1)
        let decoded = try JSONDecoder().decode(CalendarDay.self, from: JSONEncoder().encode(off))
        #expect(CalendarDay(containing: decoded.date(in: losAngeles), timeZone: losAngeles) == off)
        #expect(CalendarDay(containing: decoded.date(in: utc), timeZone: utc) == off)
        for zone in [utc, losAngeles] {
            let weights = ProgressCalculator.dailyWeights(month: november, pacing: .calendarDays, daysOff: [off], timeZone: zone)
            #expect(weights[0] == 0)
            #expect(weights[1] == 1)
            #expect(weights.reduce(0, +) == 29)
        }
    }
}
