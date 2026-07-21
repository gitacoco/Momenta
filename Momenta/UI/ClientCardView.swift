import SwiftUI
import Charts

/// The data behind one popover client card, selected by the active period.
enum ClientCardData {
    case month(ClientProgress)
    case day(ClientPeriodSlice)
    case week(ClientPeriodSlice)
}

/// One client's progress card. Month and week render a cumulative planned-vs-
/// actual chart; day renders a bullet bar of the day's hours against the
/// catch-up pace. All three share the header, goal chip, and delta styling.
struct ClientCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var isGoalChipHovered = false

    var data: ClientCardData
    var unit: DisplayUnit
    /// Whether the shown period contains "now". A back-stepped past period
    /// keeps its endpoint value label but drops the marker dot — the dot is
    /// a live-edge cue, and a finished week/month has no live edge.
    var isCurrentPeriod: Bool
    /// Day-stable seed (whole days since 2001) so the day card's encouragement
    /// copy is picked once per day and holds steady across refreshes.
    var dailySeed: Int
    var onEditGoal: () -> Void

    // MARK: Shared derived values

    private var client: ClientConfig {
        switch data {
        case .month(let progress): return progress.client
        case .day(let slice), .week(let slice): return slice.client
        }
    }

    private var isAhead: Bool {
        switch data {
        case .month(let progress): return progress.isAhead
        case .day(let slice), .week(let slice): return slice.isAhead
        }
    }

    private var clientColor: Color {
        AccessibleBrandColor.color(
            hex: client.colorHex,
            colorScheme: colorScheme,
            colorSchemeContrast: colorSchemeContrast,
            isAhead: isAhead
        )
    }

    private var deltaColor: Color {
        varianceColor(isAhead: isAhead)
    }

    private func varianceColor(isAhead: Bool) -> Color {
        switch (isAhead, colorScheme) {
        case (true, .light): Color(hex: "#24A148")
        case (true, .dark): Color(hex: "#42BE65")
        case (false, .light): Color(hex: "#DA1E28")
        case (false, .dark): Color(hex: "#FA4D56")
        @unknown default: Color(hex: isAhead ? "#24A148" : "#DA1E28")
        }
    }

    private var deltaIcon: String {
        isAhead ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
    }

    private var currencyCode: String { client.currency }
    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
                .padding(.bottom, bodyIsChart ? 8 : 4)
            switch data {
            case .month(let progress):
                periodChart(
                    points: progress.points,
                    hasGoal: progress.goal != nil,
                    marker: unitText(hours: progress.actualHours, revenue: progress.actualRevenue)
                )
                .frame(height: 110)
                monthMetrics(progress)
            case .week(let slice):
                periodChart(
                    points: slice.points,
                    hasGoal: slice.hasGoal,
                    marker: unitText(hours: slice.actualHours, revenue: slice.actualRevenue)
                )
                .frame(height: 110)
                weekMetrics(slice)
            case .day(let slice):
                dayBullet(slice)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var bodyIsChart: Bool {
        switch data {
        case .day: return false
        case .month, .week: return true
        }
    }

    // MARK: Header

    private var showsNoDataHint: Bool {
        switch data {
        case .month(let progress):
            return progress.points.contains(where: { $0.actualHours != nil }) == false
        case .week(let slice):
            return slice.points.contains(where: { $0.actualHours != nil }) == false
        case .day:
            return false
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ClientAvatar(client: client, size: 16)
            Text(client.displayName)
                .font(.headline)
            if showsNoDataHint {
                Text("no data yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            goalChip
        }
    }

    private var goalChip: some View {
        Button(action: onEditGoal) {
            HStack(spacing: 4) {
                Text("Goal")
                    .foregroundStyle(.secondary)
                Text(goalChipText ?? "Not set")
                    .fontWeight(.semibold)
            }
            .font(.callout.monospacedDigit())
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .contentShape(Capsule())
        }
        .buttonStyle(GoalChipButtonStyle(isHovered: isGoalChipHovered))
        .onHover { isGoalChipHovered = $0 }
        .help("Edit \(client.displayName) goal")
        .accessibilityLabel("Edit goal, \(goalChipText ?? "not set")")
        .accessibilityHint("Opens this client's goal settings")
    }

    /// The goal chip shows the period's target: the whole-month goal for month,
    /// the day's catch-up pace for day, the week's planned slice for week.
    private var goalChipText: String? {
        switch data {
        case .month(let progress):
            guard let goal = progress.goal else { return nil }
            return unitText(hours: goal.hours, revenue: goal.revenue)
        case .day(let slice), .week(let slice):
            guard let hours = slice.targetHours, let revenue = slice.targetRevenue else { return nil }
            return unitText(hours: hours, revenue: revenue)
        }
    }

    // MARK: Chart (month + week)

    private func periodChart(points: [DayProgressPoint], hasGoal: Bool, marker: String) -> some View {
        precondition(!points.isEmpty, "Period charts require a complete date domain")
        let todayPoint = points.last(where: { $0.actualHours != nil })
        let xDomain = points.first!.day...points.last!.day
        let elapsedPoints = points.filter { $0.actualHours != nil }
        let varianceSegments = PeriodChartLayout.varianceSegments(
            samples: elapsedPoints.map {
                PeriodChartLayout.Sample(
                    day: $0.day,
                    actual: value(actual: $0),
                    planned: value(planned: $0)
                )
            }
        )
        return GeometryReader { proxy in
            let tickDates = PeriodChartLayout.dateTicks(
                days: points.map(\.day),
                availableWidth: Double(proxy.size.width)
            )
            Chart {
                if hasGoal {
                    // Color the variance only through the latest elapsed day; the
                    // planned line continues across the rest of the period. Each
                    // series stops and restarts at an interpolated crossing so a
                    // later final state cannot recolor an earlier interval.
                    ForEach(varianceSegments) { segment in
                        ForEach(segment.points, id: \.day) { point in
                            AreaMark(
                                x: .value("Day", point.day),
                                yStart: .value("Actual", point.actual),
                                yEnd: .value("Planned", point.planned),
                                series: .value("Variance Segment", segment.id)
                            )
                            .foregroundStyle(
                                varianceColor(isAhead: segment.state == .ahead).opacity(0.1)
                            )
                        }
                    }
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Day", point.day),
                            y: .value("Planned", value(planned: point)),
                            series: .value("Series", "Planned")
                        )
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    }
                }
                ForEach(elapsedPoints) { point in
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Actual", value(actual: point)),
                        series: .value("Series", "Actual")
                    )
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(clientColor)
                }
                if let todayPoint {
                    PointMark(
                        x: .value("Today", todayPoint.day),
                        y: .value("Actual", value(actual: todayPoint))
                    )
                    // The annotation anchors here, so a zero-size symbol keeps the
                    // value label while hiding the dot on past periods.
                    .symbolSize(isCurrentPeriod ? 36 : 0)
                    .foregroundStyle(clientColor)
                    .annotation(
                        position: markerAnnotationPosition(for: todayPoint, hasGoal: hasGoal),
                        alignment: .center,
                        spacing: 4,
                        overflowResolution: AnnotationOverflowResolution(
                            x: .fit(to: .plot),
                            y: .fit(to: .plot)
                        )
                    ) {
                        Text(marker)
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(clientColor)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: xDomain)
            .chartXAxis {
                AxisMarks(values: tickDates) {
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
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
    }

    /// At the period boundary the label has no horizontal escape route. Move
    /// it vertically away from the planned line instead of changing X scale.
    private func markerAnnotationPosition(
        for point: DayProgressPoint,
        hasGoal: Bool
    ) -> AnnotationPosition {
        guard hasGoal else { return .top }
        return value(actual: point) <= value(planned: point) ? .bottom : .top
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

    // MARK: Metrics — shared

    /// The trailing up/down delta badge shared by the month and week cards.
    @ViewBuilder
    private func deltaBadge(_ text: String?) -> some View {
        if let text {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: deltaIcon)
                    .foregroundStyle(deltaColor)
                Text(text)
                    .foregroundStyle(.primary)
            }
            .font(.callout.weight(.semibold).monospacedDigit())
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Metrics — month

    private func monthMetrics(_ progress: ClientProgress) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if let pace = paceValue(progress) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(pace)
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text("/day to goal")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            deltaBadge(monthDeltaText(progress))
        }
    }

    private func paceValue(_ progress: ClientProgress) -> String? {
        guard let requiredDaily = progress.requiredDailyHours else { return nil }
        switch unit {
        case .revenue: return Format.currency(requiredDaily * progress.hourlyRate, code: currencyCode)
        case .hours: return Format.hours(requiredDaily)
        }
    }

    private func monthDeltaText(_ progress: ClientProgress) -> String? {
        guard let deltaRevenue = progress.deltaRevenue, let deltaHours = progress.deltaHours else {
            return nil
        }
        let magnitude = unitText(hours: abs(deltaHours), revenue: abs(deltaRevenue))
        return "\(magnitude) \(progress.isAhead ? "ahead" : "behind")"
    }

    // MARK: Metrics — week

    private func weekMetrics(_ slice: ClientPeriodSlice) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(unitText(hours: slice.actualHours, revenue: slice.actualRevenue))
                    .font(.title3.weight(.semibold).monospacedDigit())
                if let target = slice.targetHours, let targetRevenue = slice.targetRevenue {
                    Text("of \(unitText(hours: target, revenue: targetRevenue)) planned")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            deltaBadge(sliceDeltaText(slice))
        }
    }

    /// Behind/ahead delta text for any period slice (week and day). Day reuses
    /// the target as its planned-to-date, so its delta is actual − day pace.
    private func sliceDeltaText(_ slice: ClientPeriodSlice) -> String? {
        guard let deltaHours = slice.deltaHours, let deltaRevenue = slice.deltaRevenue else {
            return nil
        }
        let magnitude = unitText(hours: abs(deltaHours), revenue: abs(deltaRevenue))
        return "\(magnitude) \(slice.isAhead ? "ahead" : "behind")"
    }

    // MARK: Bullet — day

    @ViewBuilder
    private func dayBullet(_ slice: ClientPeriodSlice) -> some View {
        if let targetHours = slice.targetHours, targetHours > 0 {
            let fraction = min(max((slice.actualHours / targetHours).doubleValue, 0), 1)
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { proxy in
                    let fillWidth = fraction > 0 ? max(proxy.size.width * fraction, 46) : 0
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                        if fraction > 0 {
                            Capsule()
                                .fill(clientColor)
                                .frame(width: fillWidth)
                                .overlay(alignment: .trailing) {
                                    Text(unitText(hours: slice.actualHours, revenue: slice.actualRevenue))
                                        .font(.caption.weight(.bold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.trailing, 8)
                                }
                        } else {
                            Text(unitText(hours: slice.actualHours, revenue: slice.actualRevenue))
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                        }
                    }
                }
                .frame(height: 24)

                dayMetrics(slice, targetHours: targetHours)
                    .padding(.top, 6)
            }
        } else {
            // No goal for the day (rate-backfilled history): just the logged time.
            HStack {
                Text(unitText(hours: slice.actualHours, revenue: slice.actualRevenue))
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text("logged")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func dayMetrics(_ slice: ClientPeriodSlice, targetHours: Decimal) -> some View {
        let done = slice.actualHours >= targetHours
        let fraction = (slice.actualHours / targetHours).doubleValue
        return HStack(alignment: .firstTextBaseline) {
            // Left is a short status/encouragement line only. The concrete
            // over/behind number lives in the trailing badge, so it is not
            // repeated here.
            Text(dayMessage(fraction: fraction, done: done))
                .font(.callout.weight(.semibold))
                // Neutral in every state — the trailing badge is the single
                // ahead/behind colour signal, matching week and month.
                .foregroundStyle(.primary)
            Spacer()
            deltaBadge(sliceDeltaText(slice))
        }
    }

    /// One of seven per-bucket encouragements, chosen per client per day: stable
    /// through the day, rotating day to day and differing between clients.
    private func dayMessage(fraction: Double, done: Bool) -> String {
        let options: [String]
        let bucket: Int
        if done {
            options = Self.doneMessages; bucket = 5
        } else if fraction <= 0 {
            options = Self.notStartedMessages; bucket = 0
        } else if fraction < 0.25 {
            options = Self.earlyMessages; bucket = 1
        } else if fraction < 0.50 {
            options = Self.quarterMessages; bucket = 2
        } else if fraction < 0.75 {
            options = Self.halfMessages; bucket = 3
        } else {
            options = Self.lateMessages; bucket = 4
        }
        let seed = (dailySeed &* 73_856_093) ^ (client.id &* 19_349_663) ^ (bucket &* 83_492_791)
        return Self.scrambledChoice(options, seed: seed)
    }

    /// Deterministic pick with a SplitMix64 finalizer so consecutive days and
    /// neighbouring client ids don't fall into an obvious ascending pattern.
    private static func scrambledChoice(_ options: [String], seed: Int) -> String {
        guard !options.isEmpty else { return "" }
        var h = UInt64(bitPattern: Int64(seed))
        h = (h ^ (h >> 30)) &* 0xBF58476D1CE4E5B9
        h = (h ^ (h >> 27)) &* 0x94D049BB133111EB
        h ^= h >> 31
        return options[Int(h % UInt64(options.count))]
    }

    // MARK: Day encouragement copy

    // Seven variants per progress bucket, blended across warm, upbeat, and
    // dry-witty voices. Edit freely — order doesn't matter, the daily pick is
    // hashed. Keep each short enough to sit opposite the trailing delta badge.
    private static let notStartedMessages = [
        "Ready to roll", "Here we go", "Blank canvas", "The day's wide open",
        "Clean slate", "Nothing logged… yet", "Time to dive in",
    ]
    private static let earlyMessages = [
        "Off and running", "Engine's on", "Wheels turning", "Technically started",
        "Warming up", "On the board", "Getting rolling",
    ]
    private static let quarterMessages = [
        "Finding your groove", "Cooking now", "Making a dent", "Picking up steam",
        "In the swing of it", "Hitting your stride", "Rolling along",
    ]
    private static let halfMessages = [
        "Over the hump", "Downhill from here", "More done than not", "Past the midpoint",
        "Cruising now", "The back half", "Well past half",
    ]
    private static let lateMessages = [
        "Home stretch", "So close now", "Basically there", "The final push",
        "Nearly nailed it", "Almost in the bag", "One more push",
    ]
    private static let doneMessages = [
        "Done for today!", "Crushed it!", "Free to log off!", "Nailed it!",
        "That's a wrap!", "Goal met — nice!", "Call it a day!",
    ]

    // MARK: Formatting helpers

    /// Renders a paired hours/revenue value in the active unit.
    private func unitText(hours: Decimal, revenue: Decimal) -> String {
        switch unit {
        case .revenue: return Format.currency(revenue, code: currencyCode)
        case .hours: return Format.hours(hours)
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
