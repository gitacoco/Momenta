import SwiftUI
import Charts

/// One client's monthly progress: planned vs actual chart plus pace metrics.
/// Fully driven by configuration and calculated data — no hard-coded clients.
struct ClientCardView: View {
    var progress: ClientProgress
    var unit: DisplayUnit

    private var clientColor: Color {
        Color(hex: progress.client.colorHex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(clientColor)
                    .frame(width: 9, height: 9)
                Text(progress.client.displayName)
                    .font(.headline)
                if progress.points.contains(where: { $0.actualHours != nil }) == false {
                    Text("no data yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                deltaBadge
            }
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

    // MARK: Chart

    private var chart: some View {
        Chart {
            ForEach(progress.points) { point in
                LineMark(
                    x: .value("Day", point.day),
                    y: .value("Planned", value(planned: point)),
                    series: .value("Series", "Planned")
                )
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .foregroundStyle(.secondary)
            }
            ForEach(progress.points.filter { $0.actualHours != nil }) { point in
                AreaMark(
                    x: .value("Day", point.day),
                    y: .value("Actual", value(actual: point))
                )
                .foregroundStyle(clientColor.opacity(0.12))
                LineMark(
                    x: .value("Day", point.day),
                    y: .value("Actual", value(actual: point)),
                    series: .value("Series", "Actual")
                )
                .lineStyle(StrokeStyle(lineWidth: 2))
                .foregroundStyle(clientColor)
            }
            if let today = progress.points.last(where: { $0.actualHours != nil })?.day {
                RuleMark(x: .value("Today", today))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .foregroundStyle(.tertiary)
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing)
        }
    }

    private func value(planned point: DayProgressPoint) -> Double {
        switch unit {
        case .revenue: return point.plannedRevenue.doubleValue
        case .hours: return point.plannedHours.doubleValue
        }
    }

    private func value(actual point: DayProgressPoint) -> Double {
        switch unit {
        case .revenue: return (point.actualRevenue ?? 0).doubleValue
        case .hours: return (point.actualHours ?? 0).doubleValue
        }
    }

    // MARK: Metrics

    private var deltaBadge: some View {
        Text(deltaText)
            .font(.caption.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(progress.isAhead ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
            )
            .foregroundStyle(progress.isAhead ? .green : .red)
    }

    private var currencyCode: String {
        progress.client.currency
    }

    private var deltaText: String {
        switch unit {
        case .revenue: return Format.signedCurrency(progress.deltaRevenue, code: currencyCode)
        case .hours: return Format.signedHours(progress.deltaHours)
        }
    }

    private var metrics: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(actualText)
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text("of \(goalText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Format.hours(progress.requiredDailyHours))/day to goal")
                    .font(.caption.monospacedDigit())
                Text(secondaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actualText: String {
        switch unit {
        case .revenue: return Format.currency(progress.actualRevenue, code: currencyCode)
        case .hours: return Format.hours(progress.actualHours)
        }
    }

    private var goalText: String {
        switch unit {
        case .revenue: return Format.currency(progress.goal.revenue, code: currencyCode)
        case .hours: return Format.hours(progress.goal.hours)
        }
    }

    private var secondaryText: String {
        switch unit {
        case .revenue: return "\(Format.hours(progress.actualHours)) logged"
        case .hours: return "\(Format.currency(progress.actualRevenue, code: currencyCode)) earned"
        }
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
