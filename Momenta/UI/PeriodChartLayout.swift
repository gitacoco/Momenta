import Foundation

/// Pure presentation math shared by the period chart and its focused tests.
/// Keeping tick selection, resampling, and domain rounding out of the SwiftUI
/// builder keeps the animated week/month transition deterministic.
enum PeriodChartLayout {
    enum MarkerVerticalPlacement: Equatable {
        case above
        case below
    }

    /// `MMM d` at the chart's caption size fits comfortably in this slot on
    /// macOS, including the gap to its neighbor. The fixed slot also makes the
    /// chosen dates stable for a given period and card width.
    private static let minimumDateLabelSlot = 44.0

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

    /// Gives cumulative charts a stable zero baseline and a small rounded
    /// headroom. Passing this domain explicitly makes Y-axis rescaling part of
    /// the same animation as the marks instead of relying on an opaque auto
    /// scale update.
    static func yDomainUpperBound(values: [Double]) -> Double {
        let maximum = values.filter(\.isFinite).max() ?? 0
        guard maximum > 0 else { return 1 }

        let target = maximum * 1.12
        let magnitude = pow(10, floor(log10(target)))
        let normalized = target / magnitude
        let steps = [1.0, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]
        let rounded = steps.first(where: { $0 >= normalized }) ?? 10
        return rounded * magnitude
    }

    /// Gridline values for the hand-drawn Y axis: multiples of a nice step
    /// (1 / 2 / 2.5 / 5 × 10ⁿ) from zero through the domain's upper bound.
    /// Week and month bounds draw from the same step family, so a period
    /// switch usually keeps some tick values identical — those slide with the
    /// rescaling axis while the rest fade in or out.
    static func yAxisTicks(upperBound: Double, targetCount: Int = 4) -> [Double] {
        guard upperBound > 0, upperBound.isFinite else { return [0] }

        let rawStep = upperBound / Double(targetCount)
        let magnitude = pow(10, floor(log10(rawStep)))
        let normalized = rawStep / magnitude
        let candidates = [1.0, 2, 2.5, 5, 10]
        let step = (candidates.first(where: { $0 >= normalized }) ?? 10) * magnitude
        // The epsilon keeps a bound that is an exact multiple of the step
        // from losing its top tick to floating-point noise.
        let count = Int(((upperBound / step) + 1e-9).rounded(.down))
        return (0...count).map { Double($0) * step }
    }

    /// Chooses the marker-label side using the space that will actually remain
    /// inside the plot. The planned line still supplies the preferred side,
    /// but an edge with too little room loses to the opposite side so Charts'
    /// overflow fitting never has to fold the label back over its own point.
    static func markerVerticalPlacement(
        actual: Double,
        planned: Double,
        hasGoal: Bool,
        upperBound: Double,
        plotHeight: Double,
        requiredClearance: Double
    ) -> MarkerVerticalPlacement {
        let preferred: MarkerVerticalPlacement =
            hasGoal && actual <= planned ? .below : .above

        guard upperBound.isFinite, upperBound > 0,
              plotHeight.isFinite, plotHeight > 0 else {
            return preferred
        }

        let normalizedActual = min(max(actual / upperBound, 0), 1)
        let pointY = plotHeight * (1 - normalizedActual)
        let spaceAbove = pointY
        let spaceBelow = plotHeight - pointY
        let clearance = requiredClearance.isFinite
            ? max(requiredClearance, 0)
            : 0

        func hasRoom(_ placement: MarkerVerticalPlacement) -> Bool {
            switch placement {
            case .above: spaceAbove >= clearance
            case .below: spaceBelow >= clearance
            }
        }

        if hasRoom(preferred) {
            return preferred
        }

        let alternate: MarkerVerticalPlacement =
            preferred == .above ? .below : .above
        if hasRoom(alternate) {
            return alternate
        }

        // An unusually short plot may fit neither side. Choose the larger
        // pocket so the overflow resolver makes the smallest adjustment.
        return spaceAbove >= spaceBelow ? .above : .below
    }
}
