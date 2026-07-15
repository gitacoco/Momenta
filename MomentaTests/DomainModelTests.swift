import Foundation
import Testing
@testable import Momenta

struct MonthlyGoalTests {
    @Test func hoursAuthoredDerivesRevenue() {
        let goal = MonthlyGoal(hourlyRate: 120, input: .hours(80))
        #expect(goal.hours == 80)
        #expect(goal.revenue == 9600)
        #expect(goal.isAuthoredInHours)
    }

    @Test func revenueAuthoredDerivesHours() {
        let goal = MonthlyGoal(hourlyRate: 95, input: .revenue(5500))
        #expect(goal.revenue == 5500)
        // Derived hours times rate must reproduce the authored revenue.
        #expect(abs(goal.hours * 95 - 5500) < Decimal(string: "0.0001")!)
        #expect(!goal.isAuthoredInHours)
    }

    @Test func rateChangePreservesAuthoritativeInput() {
        var goal = MonthlyGoal(hourlyRate: 120, input: .hours(80))
        goal.hourlyRate = 150
        #expect(goal.hours == 80)
        #expect(goal.revenue == 12000)

        var revenueGoal = MonthlyGoal(hourlyRate: 100, input: .revenue(6000))
        revenueGoal.hourlyRate = 120
        #expect(revenueGoal.revenue == 6000)
        #expect(revenueGoal.hours == 50)
    }

    @Test func incompleteGoalsAreDetected() {
        #expect(!MonthlyGoal(hourlyRate: 0, input: .hours(80)).isComplete)
        #expect(!MonthlyGoal(hourlyRate: 120, input: .hours(0)).isComplete)
        #expect(!MonthlyGoal(hourlyRate: 120, input: .revenue(0)).isComplete)
        #expect(MonthlyGoal(hourlyRate: 120, input: .hours(80)).isComplete)
    }

    @Test func zeroRateRevenueGoalHasZeroHours() {
        let goal = MonthlyGoal(hourlyRate: 0, input: .revenue(5000))
        #expect(goal.hours == 0)
    }
}

struct YearMonthTests {
    let utc = TimeZone(identifier: "UTC")!

    @Test func rolloverAcrossYearBoundary() {
        #expect(YearMonth(year: 2026, month: 12).next == YearMonth(year: 2027, month: 1))
        #expect(YearMonth(year: 2026, month: 1).previous == YearMonth(year: 2025, month: 12))
    }

    @Test func ordering() {
        #expect(YearMonth(year: 2025, month: 12) < YearMonth(year: 2026, month: 1))
        #expect(YearMonth(year: 2026, month: 3) < YearMonth(year: 2026, month: 7))
    }

    @Test func dayCounts() {
        #expect(YearMonth(year: 2026, month: 7).dayCount(in: utc) == 31)
        #expect(YearMonth(year: 2028, month: 2).dayCount(in: utc) == 29)
        #expect(YearMonth(year: 2026, month: 2).dayCount(in: utc) == 28)
    }

    @Test func monthBoundaryRespectsTimeZone() {
        // 2026-07-01T02:00Z is still June 30 in UTC-5.
        let date = YearMonth(year: 2026, month: 7).start(in: utc).addingTimeInterval(2 * 3600)
        let utcMinus5 = TimeZone(secondsFromGMT: -5 * 3600)!
        #expect(YearMonth(containing: date, timeZone: utc) == YearMonth(year: 2026, month: 7))
        #expect(YearMonth(containing: date, timeZone: utcMinus5) == YearMonth(year: 2026, month: 6))
    }

    @Test func containsUsesHalfOpenInterval() {
        let month = YearMonth(year: 2026, month: 7)
        let start = month.start(in: utc)
        let end = month.end(in: utc)
        #expect(month.contains(start, in: utc))
        #expect(!month.contains(end, in: utc))
        #expect(month.contains(end.addingTimeInterval(-1), in: utc))
    }
}

struct ClientConfigTests {
    private func client(goals: [YearMonth: MonthlyGoal], enabled: Bool = true, archived: Bool = false) -> ClientConfig {
        ClientConfig(
            id: 1,
            workspaceID: 101,
            workspaceName: "Freelance",
            togglName: "Acme",
            displayNameOverride: nil,
            colorHex: "#5B8DEF",
            isEnabled: enabled,
            isArchivedInToggl: archived,
            pacing: .weekdays,
            goalHistory: goals
        )
    }

    @Test func goalVersionSelection() {
        let january = YearMonth(year: 2026, month: 1)
        let march = YearMonth(year: 2026, month: 3)
        let januaryGoal = MonthlyGoal(hourlyRate: 100, input: .hours(60))
        let marchGoal = MonthlyGoal(hourlyRate: 120, input: .hours(80))
        let config = client(goals: [january: januaryGoal, march: marchGoal])

        // Exact month wins; gaps inherit the latest earlier version.
        #expect(config.goal(for: january) == januaryGoal)
        #expect(config.goal(for: YearMonth(year: 2026, month: 2)) == januaryGoal)
        #expect(config.goal(for: march) == marchGoal)
        #expect(config.goal(for: YearMonth(year: 2026, month: 6)) == marchGoal)
        #expect(config.goal(for: YearMonth(year: 2025, month: 12)) == nil)
    }

    @Test func stateForMonth() {
        let month = YearMonth(year: 2026, month: 7)
        let goal = MonthlyGoal(hourlyRate: 120, input: .hours(80))

        #expect(client(goals: [month: goal]).state(for: month) == .configured)
        #expect(client(goals: [:]).state(for: month) == .needsSetup)
        #expect(client(goals: [month: goal], enabled: false).state(for: month) == .disabled)
        #expect(client(goals: [month: goal], enabled: false, archived: true).state(for: month) == .archived)
        // Archived wins even if the enabled flag is stale.
        #expect(client(goals: [month: goal], enabled: true, archived: true).state(for: month) == .archived)
        // Enabled but only an incomplete goal recorded: still needs setup.
        let incomplete = MonthlyGoal(hourlyRate: 0, input: .hours(80))
        #expect(client(goals: [month: incomplete]).state(for: month) == .needsSetup)
    }

    @Test func displayNameFallsBackToTogglName() {
        var config = client(goals: [:])
        #expect(config.displayName == "Acme")
        config.displayNameOverride = "ACME Inc."
        #expect(config.displayName == "ACME Inc.")
    }
}
