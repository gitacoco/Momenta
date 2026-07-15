import SwiftUI
import Charts

/// One client's monthly progress: planned vs actual chart plus pace metrics.
/// The ahead/behind delta is drawn where it exists — as the gap between the
/// two lines at "today" — and restated in the metrics row.
struct ClientCardView: View {
    var progress: ClientProgress
    var unit: DisplayUnit

    private var clientColor: Color {
        Color(hex: progress.client.colorHex)
    }

    private var deltaColor: Color {
        progress.isAhead ? .green : .red
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

    private var todayPoint: DayProgressPoint? {
        progress.points.last(where: { $0.actualHours != nil })
    }

    private var chart: some View {
        Chart {
            if progress.goal != nil {
                ForEach(progress.points) { point in
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Planned", value(planned: point)),
                        series: .value("Series", "Planned")
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                }
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
            // The delta, drawn where it lives: the gap between actual and
            // planned at today, colored by ahead/behind. Only meaningful
            // when the month has a goal.
            if progress.goal != nil, let today = todayPoint {
                let actualY = value(actual: today)
                let plannedY = value(planned: today)
                RuleMark(
                    x: .value("Today", today.day),
                    yStart: .value("From", min(actualY, plannedY)),
                    yEnd: .value("To", max(actualY, plannedY))
                )
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .foregroundStyle(deltaColor.opacity(0.75))
                .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                    Text(deltaShortText)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(deltaColor)
                }
                PointMark(
                    x: .value("Today", today.day),
                    y: .value("Actual", actualY)
                )
                .symbolSize(36)
                .foregroundStyle(clientColor)
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing)
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

    private var deltaShortText: String {
        switch unit {
        case .revenue: return Format.signedCurrency(progress.deltaRevenue ?? 0, code: currencyCode)
        case .hours: return Format.signedHours(progress.deltaHours ?? 0)
        }
    }

    private var deltaLineText: String? {
        guard let deltaRevenue = progress.deltaRevenue, let deltaHours = progress.deltaHours else {
            return nil
        }
        let magnitude: String
        switch unit {
        case .revenue: magnitude = Format.currency(abs(deltaRevenue), code: currencyCode)
        case .hours: magnitude = Format.hours(abs(deltaHours))
        }
        return "\(progress.isAhead ? "▲" : "▼") \(magnitude) \(progress.isAhead ? "ahead" : "behind")"
    }

    private var metrics: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(actualText)
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(goalText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let deltaLineText {
                    Text(deltaLineText)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(deltaColor)
                }
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
        guard let goal = progress.goal else {
            return "no goal recorded for this month"
        }
        switch unit {
        case .revenue: return "of \(Format.currency(goal.revenue, code: currencyCode))"
        case .hours: return "of \(Format.hours(goal.hours))"
        }
    }

    private var secondaryText: String {
        let logged: String
        switch unit {
        case .revenue: logged = "\(Format.hours(progress.actualHours)) logged"
        case .hours: logged = "\(Format.currency(progress.actualRevenue, code: currencyCode)) earned"
        }
        guard let requiredDaily = progress.requiredDailyHours else {
            return logged
        }
        return "\(Format.hours(requiredDaily))/day to goal · \(logged)"
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
