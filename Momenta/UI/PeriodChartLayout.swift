import Foundation

/// Pure presentation math shared by the period chart and its focused tests.
/// Keeping crossings out of the SwiftUI builder makes the rendered areas
/// deterministic and prevents Charts from joining differently colored spans.
enum PeriodChartLayout {
    /// `MMM d` at the chart's caption size fits comfortably in this slot on
    /// macOS, including the gap to its neighbor. The fixed slot also makes the
    /// chosen dates stable for a given period and card width.
    private static let minimumDateLabelSlot = 44.0

    struct Sample: Equatable, Sendable {
        var day: Date
        var actual: Double
        var planned: Double
    }

    enum VarianceState: Equatable, Sendable {
        case ahead
        case behind
    }

    struct VarianceSegment: Identifiable, Equatable, Sendable {
        var id: Int
        var state: VarianceState
        var points: [Sample]
    }

    /// Splits piecewise-linear actual/planned data at every strict crossing.
    /// The interpolated crossing belongs to both neighboring segments, so the
    /// fills meet exactly without a gap or a wrong-colored triangle.
    static func varianceSegments(samples: [Sample]) -> [VarianceSegment] {
        guard samples.count > 1 else { return [] }

        var segments: [VarianceSegment] = []

        func appendSpan(
            from start: Sample,
            to end: Sample,
            state: VarianceState
        ) {
            if segments.last?.state == state,
               segments.last?.points.last?.day == start.day {
                segments[segments.count - 1].points.append(end)
            } else {
                segments.append(
                    VarianceSegment(
                        id: segments.count,
                        state: state,
                        points: [start, end]
                    )
                )
            }
        }

        for (start, end) in zip(samples, samples.dropFirst()) {
            let startDelta = start.actual - start.planned
            let endDelta = end.actual - end.planned

            if startDelta * endDelta < 0 {
                let fraction = startDelta / (startDelta - endDelta)
                let crossing = Sample(
                    day: start.day.addingTimeInterval(
                        end.day.timeIntervalSince(start.day) * fraction
                    ),
                    actual: start.actual + (end.actual - start.actual) * fraction,
                    planned: start.planned + (end.planned - start.planned) * fraction
                )
                appendSpan(
                    from: start,
                    to: crossing,
                    state: startDelta >= 0 ? .ahead : .behind
                )
                appendSpan(
                    from: crossing,
                    to: end,
                    state: endDelta >= 0 ? .ahead : .behind
                )
            } else {
                // Equality at one endpoint has zero area. Classify the span by
                // its midpoint so the visible interval uses its local state.
                let state: VarianceState = (startDelta + endDelta) / 2 >= 0
                    ? .ahead
                    : .behind
                appendSpan(from: start, to: end, state: state)
            }
        }

        return segments
    }

    /// Uses every date while it fits, then chooses an evenly distributed,
    /// deterministic subset that always includes both period boundaries.
    static func dateTicks(days: [Date], availableWidth: Double) -> [Date] {
        guard !days.isEmpty else { return [] }
        guard days.count > 1 else { return days }

        let safeWidth = availableWidth.isFinite ? max(availableWidth, 0) : 0
        let capacity = max(1, Int(safeWidth / minimumDateLabelSlot))
        guard capacity < days.count else { return days }
        guard capacity > 1 else { return [days[0]] }

        return (0..<capacity).map { slot in
            let position = Double(slot) * Double(days.count - 1) / Double(capacity - 1)
            return days[Int(position.rounded())]
        }
    }
}
