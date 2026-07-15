import SwiftUI
import Charts

/// One client's monthly progress: planned vs actual chart plus pace metrics.
/// The filled gap between the lines communicates ahead/behind status, while
/// the current logged value is labeled directly at the end of the actual line.
struct ClientCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var isGoalChipHovered = false

    var progress: ClientProgress
    var unit: DisplayUnit
    var onEditGoal: () -> Void

    private var clientColor: Color {
        AccessibleBrandColor.color(
            hex: progress.client.colorHex,
            colorScheme: colorScheme,
            colorSchemeContrast: colorSchemeContrast,
            isAhead: progress.isAhead
        )
    }

    private var deltaColor: Color {
        switch (progress.isAhead, colorScheme) {
        case (true, .light): Color(hex: "#24A148")
        case (true, .dark): Color(hex: "#42BE65")
        case (false, .light): Color(hex: "#DA1E28")
        case (false, .dark): Color(hex: "#FA4D56")
        @unknown default: Color(hex: progress.isAhead ? "#24A148" : "#DA1E28")
        }
    }

    private var deltaIcon: String {
        progress.isAhead ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
    }

    private var currencyCode: String {
        progress.client.currency
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ClientAvatar(client: progress.client, size: 16)
                Text(progress.client.displayName)
                    .font(.headline)
                if progress.points.contains(where: { $0.actualHours != nil }) == false {
                    Text("no data yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                goalChip
            }
            .padding(.bottom, 8)
            chart
                .frame(height: 110)
            metrics
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var goalChip: some View {
        Button(action: onEditGoal) {
            HStack(spacing: 4) {
                Text("Goal")
                    .foregroundStyle(.secondary)
                Text(goalMetricText ?? "Not set")
                    .fontWeight(.semibold)
            }
            .font(.callout.monospacedDigit())
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .contentShape(Capsule())
        }
        .buttonStyle(GoalChipButtonStyle(isHovered: isGoalChipHovered))
        .onHover { isGoalChipHovered = $0 }
        .help("Edit \(progress.client.displayName) goal")
        .accessibilityLabel("Edit goal, \(goalMetricText ?? "not set")")
        .accessibilityHint("Opens this client's goal settings")
    }

    // MARK: Chart

    private var todayPoint: DayProgressPoint? {
        progress.points.last(where: { $0.actualHours != nil })
    }

    private var chart: some View {
        Chart {
            if progress.goal != nil {
                // Color the variance only through the latest elapsed day;
                // the planned line continues through the rest of the month.
                ForEach(progress.points.filter { $0.actualHours != nil }) { point in
                    AreaMark(
                        x: .value("Day", point.day),
                        yStart: .value("Actual", value(actual: point)),
                        yEnd: .value("Planned", value(planned: point))
                    )
                    .foregroundStyle(deltaColor.opacity(0.1))
                }
                ForEach(progress.points) { point in
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Planned", value(planned: point)),
                        series: .value("Series", "Planned")
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
            }
            ForEach(progress.points.filter { $0.actualHours != nil }) { point in
                LineMark(
                    x: .value("Day", point.day),
                    y: .value("Actual", value(actual: point)),
                    series: .value("Series", "Actual")
                )
                .lineStyle(StrokeStyle(lineWidth: 2))
                .foregroundStyle(clientColor)
            }
            if let today = todayPoint {
                PointMark(
                    x: .value("Today", today.day),
                    y: .value("Actual", value(actual: today))
                )
                .symbolSize(36)
                .foregroundStyle(clientColor)
                .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                    Text(actualText)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(clientColor)
                }
            }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            // Dates provide enough horizontal orientation; vertical grid
            // lines add noise without improving the comparison.
            AxisMarks {
                AxisValueLabel()
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) {
                AxisGridLine()
                AxisValueLabel()
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            }
        }
    }

    private func value(planned point: DayProgressPoint) -> Double {
        switch unit {
        case .revenue: return (point.plannedRevenue ?? 0).doubleValue
        case .hours: return (point.plannedHours ?? 0).doubleValue
        }
    }

    private func value(actual point: DayProgressPoint) -> Double {
        switch unit {
        case .revenue: return (point.actualRevenue ?? 0).doubleValue
        case .hours: return (point.actualHours ?? 0).doubleValue
        }
    }

    // MARK: Metrics

    private var deltaLineText: String? {
        guard let deltaRevenue = progress.deltaRevenue, let deltaHours = progress.deltaHours else {
            return nil
        }
        let magnitude: String
        switch unit {
        case .revenue: magnitude = Format.currency(abs(deltaRevenue), code: currencyCode)
        case .hours: magnitude = Format.hours(abs(deltaHours))
        }
        return "\(magnitude) \(progress.isAhead ? "ahead" : "behind")"
    }

    private var metrics: some View {
        HStack(alignment: .firstTextBaseline) {
            if let paceValue {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(paceValue)
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text("/day to goal")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let deltaLineText {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: deltaIcon)
                        .foregroundStyle(deltaColor)
                    Text(deltaLineText)
                        .foregroundStyle(.primary)
                }
                .font(.callout.weight(.semibold).monospacedDigit())
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var actualText: String {
        switch unit {
        case .revenue: return Format.currency(progress.actualRevenue, code: currencyCode)
        case .hours: return Format.hours(progress.actualHours)
        }
    }

    private var goalMetricText: String? {
        guard let goal = progress.goal else { return nil }
        switch unit {
        case .revenue: return Format.currency(goal.revenue, code: currencyCode)
        case .hours: return Format.hours(goal.hours)
        }
    }

    private var paceValue: String? {
        guard let requiredDaily = progress.requiredDailyHours else { return nil }
        switch unit {
        case .revenue:
            let requiredDailyRevenue = requiredDaily * progress.hourlyRate
            return Format.currency(requiredDailyRevenue, code: currencyCode)
        case .hours:
            return Format.hours(requiredDaily)
        }
    }
}

private struct GoalChipButtonStyle: ButtonStyle {
    var isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule()
                    .fill(Color.primary.opacity(backgroundOpacity(isPressed: configuration.isPressed)))
            )
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(isHovered ? 0.14 : 0), lineWidth: 0.5)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        if isPressed { return 0.16 }
        return isHovered ? 0.1 : 0
    }
}

extension Color {
    /// Parses "#RRGGBB"; falls back to accentColor on malformed input.
    init(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self = .accentColor
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
