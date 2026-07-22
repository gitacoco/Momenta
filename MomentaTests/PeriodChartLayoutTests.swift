import Foundation
import Testing
@testable import Momenta

struct PeriodChartLayoutTests {
    private let start = Date(timeIntervalSince1970: 0)

    @Test func standardCardWidthOffersEveryDayOfAWeek() {
        let days = (0..<7).map { start.addingTimeInterval(Double($0) * 86_400) }

        #expect(PeriodChartLayout.dateTicks(days: days, availableWidth: 332) == days)
    }

    @Test func monthTicksAreEvenStableAndIncludeBothBoundaries() {
        let days = (0..<31).map { start.addingTimeInterval(Double($0) * 86_400) }

        let first = PeriodChartLayout.dateTicks(days: days, availableWidth: 332)
        let second = PeriodChartLayout.dateTicks(days: days, availableWidth: 332)

        #expect(first == second)
        #expect(first == [days[0], days[5], days[10], days[15], days[20], days[25], days[30]])
    }

    @Test func narrowerWidthUsesEveryAvailableTickSlot() {
        let days = (0..<7).map { start.addingTimeInterval(Double($0) * 86_400) }
        let ticks = PeriodChartLayout.dateTicks(days: days, availableWidth: 220)

        #expect(ticks.count == 5)
        #expect(ticks.first == days.first)
        #expect(ticks.last == days.last)
    }

    @Test func yDomainHasRoundedHeadroomAndSafeEmptyFallback() {
        #expect(PeriodChartLayout.yDomainUpperBound(values: []) == 1)
        #expect(PeriodChartLayout.yDomainUpperBound(values: [10, 38]) == 50)
        #expect(PeriodChartLayout.yDomainUpperBound(values: [0.6]) == 0.8)
    }

    @Test func yTicksUseNiceStepsSharedAcrossPeriodScales() {
        // A week topping out at 20 and its month at 80 share the 0 and 20
        // gridlines, which slide during the period transition while the
        // others fade in or out.
        #expect(PeriodChartLayout.yAxisTicks(upperBound: 20) == [0, 5, 10, 15, 20])
        #expect(PeriodChartLayout.yAxisTicks(upperBound: 80) == [0, 20, 40, 60, 80])
    }

    @Test func yTicksStopBelowTheUpperBoundWhenTheStepOvershoots() {
        #expect(PeriodChartLayout.yAxisTicks(upperBound: 50) == [0, 20, 40])
    }

    @Test func yTicksHandleFractionalStepsAndDegenerateBounds() {
        let fractional = PeriodChartLayout.yAxisTicks(upperBound: 1)
        #expect(fractional.count == 5)
        for (tick, expected) in zip(fractional, [0, 0.25, 0.5, 0.75, 1]) {
            #expect(abs(tick - expected) < 1e-9)
        }
        #expect(PeriodChartLayout.yAxisTicks(upperBound: 0) == [0])
    }
}
