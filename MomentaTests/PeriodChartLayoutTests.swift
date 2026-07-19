import Foundation
import Testing
@testable import Momenta

struct PeriodChartLayoutTests {
    private let start = Date(timeIntervalSince1970: 0)

    private func sample(day: Int, actual: Double, planned: Double) -> PeriodChartLayout.Sample {
        PeriodChartLayout.Sample(
            day: start.addingTimeInterval(Double(day) * 86_400),
            actual: actual,
            planned: planned
        )
    }

    @Test func varianceKeepsOneSegmentWhenLocalStateDoesNotChange() throws {
        let samples = [
            sample(day: 0, actual: 1, planned: 2),
            sample(day: 1, actual: 2, planned: 3),
            sample(day: 2, actual: 3, planned: 4),
        ]

        let segment = try #require(PeriodChartLayout.varianceSegments(samples: samples).only)
        #expect(segment.state == .behind)
        #expect(segment.points == samples)
    }

    @Test func varianceInterpolatesAndSharesExactCrossing() throws {
        let samples = [
            sample(day: 0, actual: 1, planned: 3),
            sample(day: 1, actual: 5, planned: 3),
        ]

        let segments = PeriodChartLayout.varianceSegments(samples: samples)
        #expect(segments.count == 2)
        #expect(segments.map(\.state) == [.behind, .ahead])

        let firstCrossing = try #require(segments.first?.points.last)
        let secondCrossing = try #require(segments.last?.points.first)
        #expect(firstCrossing == secondCrossing)
        #expect(firstCrossing.day == start.addingTimeInterval(43_200))
        #expect(firstCrossing.actual == 3)
        #expect(firstCrossing.planned == 3)
    }

    @Test func varianceCanCrossMoreThanOnceWithoutJoiningSeparatedColors() {
        let samples = [
            sample(day: 0, actual: 0, planned: 2),
            sample(day: 1, actual: 4, planned: 2),
            sample(day: 2, actual: 0, planned: 2),
        ]

        let segments = PeriodChartLayout.varianceSegments(samples: samples)
        #expect(segments.map(\.state) == [.behind, .ahead, .behind])
        #expect(segments.map { $0.points.count } == [2, 3, 2])
        #expect(segments[0].points.last == segments[1].points.first)
        #expect(segments[1].points.last == segments[2].points.first)
    }

    @Test func equalityEndpointUsesTheVisibleIntervalsState() {
        let samples = [
            sample(day: 0, actual: 1, planned: 1),
            sample(day: 1, actual: 0, planned: 1),
            sample(day: 2, actual: 2, planned: 1),
        ]

        let segments = PeriodChartLayout.varianceSegments(samples: samples)
        #expect(segments.map(\.state) == [.behind, .ahead])
        #expect(segments[0].points.first == samples[0])
        #expect(segments[0].points.last == segments[1].points.first)
    }

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
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
