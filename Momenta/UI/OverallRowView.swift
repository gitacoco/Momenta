import AppKit
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

            HStack(spacing: 3) {
                Text("Overall")
                    .textCase(.uppercase)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)

                OverallPeriodPullDown(selection: periodSelection)
                .fixedSize()
                .accessibilityLabel("Overall period")
                .accessibilityValue(selectedPeriod.overallPickerLabel)
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
}

/// A native pull-down button rather than a pop-up picker. AppKit presents a
/// pull-down menu from the requested edge; a pop-up always aligns its selected
/// item with the control, which makes `This Month` expand mostly upward.
private struct OverallPeriodPullDown: NSViewRepresentable {
    @Binding var selection: AggregationPeriod

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let menu = NSMenu()
        menu.autoenablesItems = false

        for (index, period) in AggregationPeriod.allCases.enumerated() {
            let item = NSMenuItem(
                title: period.overallPickerLabel,
                action: #selector(Coordinator.selectPeriod(_:)),
                keyEquivalent: ""
            )
            item.tag = index
            item.target = context.coordinator
            menu.addItem(item)
        }

        let button = NSPopUpButton(
            title: selection.overallPickerLabel,
            pullDownMenu: menu
        )
        button.preferredEdge = .minY
        button.setAccessibilityLabel("Overall period")
        update(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        update(button, coordinator: context.coordinator)
    }

    private func update(_ button: NSPopUpButton, coordinator: Coordinator) {
        button.title = selection.overallPickerLabel
        button.setAccessibilityValue(selection.overallPickerLabel)

        for (index, item) in button.itemArray.enumerated() {
            item.target = coordinator
            item.state = index == AggregationPeriod.allCases.firstIndex(of: selection) ? .on : .off
        }

        button.invalidateIntrinsicContentSize()
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<AggregationPeriod>

        init(selection: Binding<AggregationPeriod>) {
            self.selection = selection
        }

        @objc func selectPeriod(_ sender: NSMenuItem) {
            guard AggregationPeriod.allCases.indices.contains(sender.tag) else { return }
            selection.wrappedValue = AggregationPeriod.allCases[sender.tag]
        }
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
