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

            HStack(spacing: 8) {
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

            Text("\(Text(actualText).foregroundStyle(.primary).fontWeight(.semibold))\(Text(" / \(targetText) · ").foregroundStyle(.secondary))\(Text(percentText).foregroundStyle(.primary).fontWeight(.semibold))")
                .font(.caption.monospacedDigit())
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
            Text(selection.overallPickerLabel)
                .textCase(.uppercase)
                .fixedSize(horizontal: true, vertical: false)
                // Pop from secondary to primary on hover so the plain text
                // still reads as clickable.
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
