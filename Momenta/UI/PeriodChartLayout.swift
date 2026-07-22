import Foundation

/// Pure presentation math shared by the period chart and its focused tests.
/// Keeping tick selection, resampling, and domain rounding out of the SwiftUI
/// builder keeps the animated week/month transition deterministic.
enum PeriodChartLayout {
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
}
