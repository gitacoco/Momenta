import AppKit
import SwiftUI

/// A persistent capsule whose fill and value label move together when the
/// period changes. Refreshes and unit changes remain immediate, as in charts.
struct PeriodProgressCapsule: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var fraction: Double
    var actualText: String
    var targetText: String
    var color: Color
    var period: AggregationPeriod

    private var clampedFraction: Double {
        fraction.isFinite ? min(max(fraction, 0), 1) : 0
    }

    private var labelWidth: CGFloat {
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .bold
        )
        return ceil((actualText as NSString).size(withAttributes: [.font: font]).width) + 16
    }

    var body: some View {
        let hasProgress = clampedFraction > 0
        GeometryReader { proxy in
            let fillWidth = hasProgress
                ? min(proxy.size.width, max(proxy.size.width * clampedFraction, labelWidth))
                : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                // Keep the fill mounted at zero so it can grow or shrink
                // continuously, including when a period has no logged work.
                Capsule()
                    .fill(color)
                    .frame(width: fillWidth)
                valueLabel
                    .foregroundStyle(.white)
                    .frame(width: labelWidth, alignment: .trailing)
                    .offset(x: max(fillWidth - labelWidth, 0))
                    .opacity(hasProgress ? 1 : 0)
                valueLabel
                    .foregroundStyle(.secondary)
                    .opacity(hasProgress ? 0 : 1)
            }
            // Match the chart's period transition without animating the
            // card's layout, goal button, or semantic foreground styles.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.48), value: period)
        }
        .frame(height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(actualText) of \(targetText)")
    }

    private var valueLabel: some View {
        Text(actualText)
            .font(.caption.weight(.bold).monospacedDigit())
            .fixedSize()
            .padding(.horizontal, 8)
            .contentTransition(.numericText())
    }
}
