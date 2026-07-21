import SwiftUI

/// The popover's Overall summary row, pinned above the client cards for every
/// period. It follows the h/$ toggle: revenue mode mirrors the menu-bar Overall
/// exactly (same `AggregateProgress`), while hours mode shows summed hours. The
/// ring encodes the same fraction shown after the trailing actual/target pair.
struct OverallRowView: View {
    var aggregate: AggregateProgress
    var unit: DisplayUnit
    var selectedPeriod: AggregationPeriod
    var onSelectPeriod: (AggregationPeriod) -> Void

    private var periodSelection: Binding<AggregationPeriod> {
        Binding(
            get: { selectedPeriod },
            set: { newValue in
                onSelectPeriod(newValue)
            }
        )
    }

    private var fraction: Double {
        unit == .revenue ? aggregate.fraction : aggregate.hoursFraction
    }

    private var isAvailable: Bool {
        unit == .revenue ? aggregate.targetIsAvailable : aggregate.hoursTargetIsAvailable
    }

    private var percentText: String {
        isAvailable ? Format.percent(fraction) : "—"
    }

    private var actualText: String {
        unit == .revenue ? Format.currency(aggregate.actualRevenue) : Format.hours(aggregate.actualHours)
    }

    private var targetText: String {
        unit == .revenue ? Format.currency(aggregate.targetRevenue) : Format.hours(aggregate.targetHours)
    }

    var body: some View {
        HStack(spacing: 9) {
            OverallRingGlyph(fraction: isAvailable ? fraction : nil)
                .frame(width: 20, height: 20)

            HStack(spacing: 4) {
                Text("Overall")
                    .textCase(.uppercase)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)

                OverallPeriodCycleButton(selection: periodSelection)
                    .fixedSize()
            }
            .foregroundStyle(.secondary)
            .font(.caption.weight(.semibold))
            .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(actualText) / \(targetText) · \(percentText)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel("\(percentText), \(actualText) of \(targetText)")
        }
        .padding(.horizontal, 4)
    }
}

private extension AggregationPeriod {
    var overallPickerLabel: String {
        switch self {
        case .day: "Today"
        case .week: "This Week"
        case .month: "This Month"
        }
    }

    /// The next period when the label is clicked, wrapping around. Order follows
    /// `allCases` (day → week → month → day).
    var nextInCycle: AggregationPeriod {
        let all = AggregationPeriod.allCases
        let index = all.firstIndex(of: self) ?? all.startIndex
        return all[(index + 1) % all.count]
    }
}

/// A plain-text period label that cycles Today → This Week → This Month on each
/// click. Deliberately not a native `NSPopUpButton`/`NSMenu` nor a SwiftUI
/// `Menu`/`Picker(.menu)`: those present a real `NSMenu` in a *separate window*
/// whose tracking loop is closed by the trailing physical Force Touch pressure
/// event on the first click (BON-48). This is just a Button flipping state, so
/// that whole failure class cannot occur.
private struct OverallPeriodCycleButton: View {
    @Binding var selection: AggregationPeriod
    @State private var isHovering = false

    var body: some View {
        Button {
            selection = selection.nextInCycle
        } label: {
            HStack(spacing: 4) {
                Text(selection.overallPickerLabel)
                    .textCase(.uppercase)
                    .fixedSize(horizontal: true, vertical: false)
                // The swap glyph makes "click to cycle" legible; the plain
                // label alone read as static text.
                Image(systemName: "arrow.left.arrow.right")
                    .imageScale(.small)
                    .opacity(0.7)
            }
            .foregroundStyle(isHovering ? Color.primary : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            // A soft base fill on hover marks the whole hit target, matching
            // the modern inline-control hover treatment.
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityLabel("Overall period")
        .accessibilityValue(selection.overallPickerLabel)
        .accessibilityHint("Cycles the summary period")
    }
}

/// A compact progress ring for the Overall row, mirroring the menu-bar ring's
/// look at popover scale. A nil fraction renders the track alone (no goal).
private struct OverallRingGlyph: View {
    var fraction: Double?

    private var clampedFraction: Double {
        guard let fraction, fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.16), lineWidth: 2.5)
            if clampedFraction > 0 {
                Circle()
                    .trim(from: 0, to: clampedFraction)
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .accessibilityHidden(true)
    }
}
