import SwiftUI

/// The popover's Overall summary row, pinned above the client cards for every
/// period. It follows the h/$ toggle: revenue mode mirrors the menu-bar Overall
/// exactly (same `AggregateProgress`), while hours mode shows summed hours.
struct OverallRowView: View {
    var aggregate: AggregateProgress
    var unit: DisplayUnit
    var selectedPeriod: AggregationPeriod
    var onSelectPeriod: (AggregationPeriod) -> Void
    var cardStyle: ClientCardStyle
    var onSelectCardStyle: (ClientCardStyle) -> Void

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

    private var summaryText: String {
        "\(actualText) / \(targetText) · \(percentText)"
    }

    /// Short enough to read as the row settling rather than as motion of its
    /// own — this sits above cards whose charts run a much longer morph.
    private static let valueChange: Animation = .easeOut(duration: 0.28)

    var body: some View {
        HStack(spacing: 9) {
            HStack(spacing: 4) {
                OverallPeriodCycleButton(selection: periodSelection)
                    .fixedSize()

                CardStyleToggle(selection: cardStyle, onSelect: onSelectCardStyle)
                    .fixedSize()
                    .padding(.leading, 2)
            }
            .foregroundStyle(.secondary)
            .font(.caption.weight(.semibold))
            .lineLimit(1)

            // No floor of its own: the stack's own 9pt on each side already
            // separates the label from the figures, and a further 8pt was
            // enough to truncate a six-figure summary that would otherwise
            // have fit.
            Spacer(minLength: 0)

            Text(summaryText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Monospaced digits give the numeric transition fixed columns
                // to roll in, so stepping periods reads as the figures being
                // re-dialled rather than swapped.
                .contentTransition(.numericText())
                .animation(Self.valueChange, value: summaryText)
                .accessibilityLabel("Overall: \(percentText), \(actualText) of \(targetText)")
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

    /// The next period when the label is clicked, wrapping around:
    /// month → week → day → month. Steps backwards through `allCases` so the
    /// settings picker keeps its day/week/month display order.
    var nextInCycle: AggregationPeriod {
        let all = AggregationPeriod.allCases
        let index = all.firstIndex(of: self) ?? all.startIndex
        return all[(index + all.count - 1) % all.count]
    }
}

/// A plain-text period label that cycles This Month → This Week → Today on each
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

/// The capsule/timeline switch for client cards: two icon segments built
/// from plain Buttons, matching the cycle button's inline language. Like it,
/// deliberately not a native menu or `Picker(.menu)` (BON-48); a segmented
/// `Picker` would also read too heavy at this row's caption scale.
private struct CardStyleToggle: View {
    var selection: ClientCardStyle
    var onSelect: (ClientCardStyle) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment(.timeline, icon: "chart.xyaxis.line", help: "Timeline: actual progress against the plan")
            segment(.capsule, icon: "capsule", help: "Capsule: progress toward the period goal")
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Client card style")
    }

    private func segment(_ style: ClientCardStyle, icon: String, help: LocalizedStringKey) -> some View {
        Button {
            onSelect(style)
        } label: {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(selection == style ? Color.primary : Color.secondary)
                .frame(width: 22, height: 16)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(selection == style ? Color.primary.opacity(0.12) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(style.label)
        .accessibilityAddTraits(selection == style ? [.isSelected] : [])
    }
}
