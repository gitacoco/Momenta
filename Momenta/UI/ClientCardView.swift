import AppKit
import SwiftUI
import Charts

/// The data behind one popover client card, selected by the active period.
enum ClientCardData {
    case month(ClientProgress)
    case day(ClientPeriodSlice)
    case week(ClientPeriodSlice)
}

/// One per-day chart sample. Identity is the calendar day itself, so a day
/// shared by week and month is the same mark in both periods: a period switch
/// then reads as the x-domain zooming into (or out of) the shared window while
/// values rebase, not as one shape tweening into another.
private struct PeriodChartPoint: Identifiable, Equatable {
    let id: Int
    var day: Date
    var actual: Double
    var planned: Double

    init(day: Date, actual: Double, planned: Double) {
        self.id = Int(day.timeIntervalSinceReferenceDate.rounded())
        self.day = day
        self.actual = actual
        self.planned = planned
    }
}

private struct PeriodChartModel: Equatable {
    var period: AggregationPeriod
    /// The period's real days — the tick source. Transition union models keep
    /// marks outside this range, which is why `xDomain` is stored explicitly
    /// instead of derived from the mark extents.
    var days: [Date]
    var xDomain: ClosedRange<Date>
    var plannedPoints: [PeriodChartPoint]
    var actualPoints: [PeriodChartPoint]
    var hasGoal: Bool
    var marker: String
    var yUpperBound: Double
}

/// One hand-drawn axis tick. Identity is an integer stable across period
/// switches (seconds for dates, micro-units for values), so a tick shared by
/// week and month keeps its view and slides, while period-specific ticks fade
/// in or out at their moving positions.
private struct AxisTick<Value: Equatable>: Identifiable, Equatable {
    let id: Int
    var value: Value
    var label: String
    var labelWidth: CGFloat
    var isActive: Bool
}

/// Metrics and tick factories for the hand-drawn chart axes. Swift Charts'
/// built-in AxisMarks re-resolve wholesale on an animated domain change and
/// cross-fade the old and new axis sets, so the chart hides them and the host
/// draws gridlines and labels itself with per-tick identity.
@MainActor
private enum PeriodChartAxis {
    static let labelFont = NSFont.preferredFont(forTextStyle: .caption2, options: [:])
    static let labelHeight = ceil(labelFont.ascender - labelFont.descender + labelFont.leading)
    static let xGutterHeight = labelHeight + 4
    static let yLabelLeading: CGFloat = 6

    static func labelWidth(_ label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: labelFont]).width)
    }

    static func yGutterWidth(_ ticks: [AxisTick<Double>]) -> CGFloat {
        (ticks.map(\.labelWidth).max() ?? 0) + yLabelLeading
    }

    static func plotWidth(totalWidth: CGFloat, yTicks: [AxisTick<Double>]) -> CGFloat {
        max(totalWidth - yGutterWidth(yTicks), 1)
    }

    static func yTicks(for model: PeriodChartModel) -> [AxisTick<Double>] {
        PeriodChartLayout.yAxisTicks(upperBound: model.yUpperBound).map { value in
            let label = value.formatted(.number.precision(.fractionLength(0...2)))
            return AxisTick(
                id: Int((value * 1_000_000).rounded()),
                value: value,
                label: label,
                labelWidth: labelWidth(label),
                isActive: true
            )
        }
    }

    static func xTicks(for model: PeriodChartModel, plotWidth: CGFloat) -> [AxisTick<Date>] {
        PeriodChartLayout.dateTicks(
            days: model.days,
            availableWidth: Double(plotWidth)
        ).map { date in
            let label = date.formatted(.dateTime.month(.abbreviated).day())
            return AxisTick(
                id: Int(date.timeIntervalSinceReferenceDate.rounded()),
                value: date,
                label: label,
                labelWidth: labelWidth(label),
                isActive: true
            )
        }
    }
}

/// Owns the only animated state in the card: the rendered chart model plus the
/// hand-drawn axis ticks. A Week <-> Month switch animates both inside one
/// transaction as a zoom: marks are anchored to their calendar days, so the
/// x-domain change stretches the shared window across the plot while values
/// rebase to the incoming period's cumulative baseline and off-window marks
/// slide out through the clip edge. The transition renders the union of both
/// periods' days (three phases: mount union silently, animate, prune), ticks
/// shared by both periods slide, and period-specific ticks fade in or out
/// while riding the rescaling axis. Changes unrelated to a period switch
/// update instantly so no header, metric, or card layout animates.
private struct AnimatedPeriodChartHost<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var target: PeriodChartModel
    var size: CGSize
    var content: (PeriodChartModel) -> Content

    @State private var rendered: PeriodChartModel
    @State private var xTicks: [AxisTick<Date>]
    @State private var yTicks: [AxisTick<Double>]
    /// Invalidates the deferred animation start and its completion prune when
    /// a newer transition or an instant update supersedes them.
    @State private var transitionGeneration = 0

    init(
        target: PeriodChartModel,
        size: CGSize,
        @ViewBuilder content: @escaping (PeriodChartModel) -> Content
    ) {
        self.target = target
        self.size = size
        self.content = content
        let yTicks = PeriodChartAxis.yTicks(for: target)
        _rendered = State(initialValue: target)
        _yTicks = State(initialValue: yTicks)
        _xTicks = State(initialValue: PeriodChartAxis.xTicks(
            for: target,
            plotWidth: PeriodChartAxis.plotWidth(totalWidth: size.width, yTicks: yTicks)
        ))
    }

    var body: some View {
        let plotWidth = PeriodChartAxis.plotWidth(
            totalWidth: size.width,
            yTicks: yTicks.filter(\.isActive)
        )
        let plotHeight = max(size.height - PeriodChartAxis.xGutterHeight, 1)

        // Each layer clips to its own region — the plot for marks and
        // gridlines, the gutters for labels — so nothing the zoom pushes past
        // a coordinate-system boundary is drawn outside it.
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(yTicks) { tick in
                    Rectangle()
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .frame(width: plotWidth, height: 1)
                        .position(
                            x: plotWidth / 2,
                            y: yPosition(tick.value, plotHeight: plotHeight)
                        )
                        .opacity(tick.isActive ? 1 : 0)
                }
            }
            .frame(width: plotWidth, height: plotHeight)
            .clipped()
            content(rendered)
                .frame(width: plotWidth, height: plotHeight)
                .clipped()
            ZStack(alignment: .topLeading) {
                ForEach(yTicks) { tick in
                    axisLabel(tick.label)
                        .position(
                            x: PeriodChartAxis.yLabelLeading + tick.labelWidth / 2,
                            y: yLabelPosition(tick, plotHeight: plotHeight)
                        )
                        .opacity(tick.isActive ? 1 : 0)
                }
            }
            .frame(width: max(size.width - plotWidth, 0), height: plotHeight)
            .clipped()
            .offset(x: plotWidth)
            ZStack(alignment: .topLeading) {
                ForEach(xTicks) { tick in
                    axisLabel(tick.label)
                        .position(
                            x: xLabelPosition(tick, plotWidth: plotWidth),
                            y: PeriodChartAxis.xGutterHeight / 2 + 1
                        )
                        .opacity(tick.isActive ? 1 : 0)
                }
            }
            .frame(width: size.width, height: PeriodChartAxis.xGutterHeight)
            .clipped()
            .offset(y: plotHeight)
        }
        .onChange(of: target) { previous, next in
            transition(from: previous, to: next)
        }
        .onChange(of: size) { _, _ in
            apply(target)
        }
    }

    private func axisLabel(_ label: String) -> some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .fixedSize()
    }

    /// Active ticks clamp to the plot edges so boundary labels stay whole in
    /// the resting states; exiting ticks keep their true projection and slide
    /// out through their layer's clip edge instead of piling at it.
    private func xLabelPosition(_ tick: AxisTick<Date>, plotWidth: CGFloat) -> CGFloat {
        let position = xPosition(tick.value, plotWidth: plotWidth)
        guard tick.isActive else { return position }
        return min(max(position, tick.labelWidth / 2), size.width - tick.labelWidth / 2)
    }

    private func yLabelPosition(_ tick: AxisTick<Double>, plotHeight: CGFloat) -> CGFloat {
        let position = yPosition(tick.value, plotHeight: plotHeight)
        guard tick.isActive else { return position }
        return min(
            max(position, PeriodChartAxis.labelHeight / 2),
            plotHeight - PeriodChartAxis.labelHeight / 2
        )
    }

    /// The tick's center under the currently rendered (animating) domain.
    /// Ticks outside that domain project off-plot.
    private func xPosition(_ date: Date, plotWidth: CGFloat) -> CGFloat {
        let domain = rendered.xDomain
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return 0 }
        return plotWidth * CGFloat(date.timeIntervalSince(domain.lowerBound) / span)
    }

    private func yPosition(_ value: Double, plotHeight: CGFloat) -> CGFloat {
        plotHeight * CGFloat(1 - value / rendered.yUpperBound)
    }

    private func transition(from previous: PeriodChartModel, to next: PeriodChartModel) {
        guard previous.period != next.period, !reduceMotion else {
            apply(next)
            return
        }

        #if DEBUG
        print(
            "[PeriodChart] animate \(previous.period.rawValue) -> \(next.period.rawValue), "
            + "x: \(previous.xDomain) -> \(next.xDomain), "
            + "y: \(previous.yUpperBound) -> \(next.yUpperBound)"
        )
        #endif

        let nextY = PeriodChartAxis.yTicks(for: next)
        let nextX = PeriodChartAxis.xTicks(
            for: next,
            plotWidth: PeriodChartAxis.plotWidth(totalWidth: size.width, yTicks: nextY)
        )

        // Phase 1, not animated: swap in the union-of-days model and mount
        // entering ticks at the outgoing scale's projection. Union marks the
        // current period lacks carry rebased counterpart values and sit
        // outside the visible domain, so this phase changes no pixels. It is
        // committed separately because views inserted and animated in the
        // same update have no prior state to animate from.
        let union = Self.unionModels(from: rendered, to: next)
        var mountTransaction = Transaction(animation: nil)
        mountTransaction.disablesAnimations = true
        withTransaction(mountTransaction) {
            rendered = union.start
            let mountedX = Set(xTicks.map(\.id))
            xTicks.append(contentsOf: nextX.filter { !mountedX.contains($0.id) }.map { tick in
                var entering = tick
                entering.isActive = false
                return entering
            })
            let mountedY = Set(yTicks.map(\.id))
            yTicks.append(contentsOf: nextY.filter { !mountedY.contains($0.id) }.map { tick in
                var entering = tick
                entering.isActive = false
                return entering
            })
        }

        transitionGeneration += 1
        let generation = transitionGeneration
        let activeX = Set(nextX.map(\.id))
        let activeY = Set(nextY.map(\.id))
        Task { @MainActor in
            guard generation == transitionGeneration else { return }
            // Phase 2: the zoom itself. Every union mark keeps its day, so
            // the domain change re-projects the shared window across the
            // plot while values animate to the incoming period's baseline.
            withAnimation(.easeInOut(duration: 0.48)) {
                rendered = union.end
                for index in xTicks.indices {
                    xTicks[index].isActive = activeX.contains(xTicks[index].id)
                }
                for index in yTicks.indices {
                    yTicks[index].isActive = activeY.contains(yTicks[index].id)
                }
            } completion: {
                guard generation == transitionGeneration else { return }
                // Phase 3: drop the off-window union marks (already clipped)
                // and the faded-out ticks.
                var pruneTransaction = Transaction(animation: nil)
                pruneTransaction.disablesAnimations = true
                withTransaction(pruneTransaction) {
                    rendered = next
                    xTicks.removeAll { !$0.isActive }
                    yTicks.removeAll { !$0.isActive }
                }
            }
        }
    }

    /// The transition's start and end models over the union of both periods'
    /// days. Days only one period covers get the other period's value shifted
    /// by the offset measured at the first shared day, so the off-window
    /// extension continues the visible line without a step: cumulative
    /// increments agree wherever the periods overlap, which also makes the
    /// start model pixel-identical to the outgoing chart.
    private static func unionModels(
        from current: PeriodChartModel,
        to next: PeriodChartModel
    ) -> (start: PeriodChartModel, end: PeriodChartModel) {
        let planned = unionSeries(current: current.plannedPoints, next: next.plannedPoints)
        let actual = unionSeries(current: current.actualPoints, next: next.actualPoints)
        var start = current
        start.plannedPoints = planned.start
        start.actualPoints = actual.start
        var end = next
        end.plannedPoints = planned.end
        end.actualPoints = actual.end
        return (start, end)
    }

    private static func unionSeries(
        current: [PeriodChartPoint],
        next: [PeriodChartPoint]
    ) -> (start: [PeriodChartPoint], end: [PeriodChartPoint]) {
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let nextByID = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })

        var actualOffset = 0.0
        var plannedOffset = 0.0
        if let shared = current.first(where: { nextByID[$0.id] != nil }),
           let counterpart = nextByID[shared.id] {
            actualOffset = shared.actual - counterpart.actual
            plannedOffset = shared.planned - counterpart.planned
        }

        let union = (current + next.filter { currentByID[$0.id] == nil })
            .sorted { $0.day < $1.day }
        let start = union.map { point in
            currentByID[point.id]
                ?? rebased(point, actual: actualOffset, planned: plannedOffset)
        }
        let end = union.map { point in
            nextByID[point.id]
                ?? rebased(point, actual: -actualOffset, planned: -plannedOffset)
        }
        return (start, end)
    }

    private static func rebased(
        _ point: PeriodChartPoint,
        actual: Double,
        planned: Double
    ) -> PeriodChartPoint {
        var rebased = point
        rebased.actual += actual
        rebased.planned += planned
        return rebased
    }

    private func apply(_ model: PeriodChartModel) {
        transitionGeneration += 1
        let nextY = PeriodChartAxis.yTicks(for: model)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            rendered = model
            yTicks = nextY
            xTicks = PeriodChartAxis.xTicks(
                for: model,
                plotWidth: PeriodChartAxis.plotWidth(totalWidth: size.width, yTicks: nextY)
            )
        }
    }
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
            if let chartModel {
                GeometryReader { proxy in
                    AnimatedPeriodChartHost(target: chartModel, size: proxy.size) { rendered in
                        periodChart(rendered)
                    }
                }
                .frame(height: 110)

                switch data {
                case .month(let progress):
                    monthMetrics(progress)
                case .week(let slice):
                    weekMetrics(slice)
                case .day:
                    EmptyView()
                }
            } else if case .day(let slice) = data {
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

    private var chartModel: PeriodChartModel? {
        switch data {
        case .month(let progress):
            makeChartModel(
                period: .month,
                points: progress.points,
                hasGoal: progress.goal != nil,
                marker: unitText(
                    hours: progress.actualHours,
                    revenue: progress.actualRevenue
                )
            )
        case .week(let slice):
            makeChartModel(
                period: .week,
                points: slice.points,
                hasGoal: slice.hasGoal,
                marker: unitText(
                    hours: slice.actualHours,
                    revenue: slice.actualRevenue
                )
            )
        case .day:
            nil
        }
    }

    private func makeChartModel(
        period: AggregationPeriod,
        points: [DayProgressPoint],
        hasGoal: Bool,
        marker: String
    ) -> PeriodChartModel {
        precondition(!points.isEmpty, "Period charts require a complete date domain")

        let plannedPoints = points.map { point in
            PeriodChartPoint(
                day: point.day,
                actual: value(actual: point),
                planned: value(planned: point)
            )
        }
        let actualPoints = zip(points, plannedPoints).compactMap { source, point in
            source.actualHours != nil ? point : nil
        }
        let yValues = actualPoints.map(\.actual)
            + (hasGoal ? plannedPoints.map(\.planned) : [])

        return PeriodChartModel(
            period: period,
            days: points.map(\.day),
            xDomain: points.first!.day...points.last!.day,
            plannedPoints: plannedPoints,
            actualPoints: actualPoints,
            hasGoal: hasGoal,
            marker: marker,
            yUpperBound: PeriodChartLayout.yDomainUpperBound(values: yValues)
        )
    }

    private func periodChart(_ model: PeriodChartModel) -> some View {
        Chart {
            if model.hasGoal {
                // Two always-present fills clamped to the planned line: ahead
                // covers the span above plan, behind the span below, each with
                // zero height where the other applies. Clamping keeps every
                // area mark's identity stable (its day) so the fills ride the
                // zoom with the lines on a period switch; the cost is that a
                // color changeover lands within one day of the true crossing
                // instead of exactly on it — invisible at this opacity. Fills
                // and lines must both stay linearly interpolated or the
                // clamped edges detach from the curves near crossings.
                ForEach(model.actualPoints) { point in
                    AreaMark(
                        x: .value("Day", point.day),
                        yStart: .value("Planned", point.planned),
                        yEnd: .value("Actual", max(point.actual, point.planned)),
                        series: .value("Series", "AheadFill")
                    )
                    .foregroundStyle(varianceColor(isAhead: true).opacity(0.1))
                }
                ForEach(model.actualPoints) { point in
                    AreaMark(
                        x: .value("Day", point.day),
                        yStart: .value("Actual", min(point.actual, point.planned)),
                        yEnd: .value("Planned", point.planned),
                        series: .value("Series", "BehindFill")
                    )
                    .foregroundStyle(varianceColor(isAhead: false).opacity(0.1))
                }
                ForEach(model.plannedPoints) { point in
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Planned", point.planned),
                        series: .value("Series", "Planned")
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
            }
            ForEach(model.actualPoints) { point in
                LineMark(
                    x: .value("Day", point.day),
                    y: .value("Actual", point.actual),
                    series: .value("Series", "Actual")
                )
                .lineStyle(StrokeStyle(lineWidth: 2))
                .foregroundStyle(clientColor)
            }
            if let todayPoint = model.actualPoints.last {
                PointMark(
                    x: .value("Today", todayPoint.day),
                    y: .value("Actual", todayPoint.actual)
                )
                // The annotation anchors here, so a zero-size symbol keeps the
                // value label while hiding the dot on past periods.
                .symbolSize(isCurrentPeriod ? 36 : 0)
                .foregroundStyle(clientColor)
                .annotation(
                    position: markerAnnotationPosition(
                        actual: todayPoint.actual,
                        planned: todayPoint.planned,
                        hasGoal: model.hasGoal
                    ),
                    alignment: .center,
                    spacing: 4,
                    overflowResolution: AnnotationOverflowResolution(
                        x: .fit(to: .plot),
                        y: .fit(to: .plot)
                    )
                ) {
                    Text(model.marker)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(clientColor)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: model.xDomain)
        .chartYScale(domain: 0...model.yUpperBound)
        // Built-in axis marks re-resolve and cross-fade wholesale on an
        // animated domain change; AnimatedPeriodChartHost draws gridlines and
        // labels itself with per-tick identity instead.
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    /// At the period boundary the label has no horizontal escape route. Move
    /// it vertically away from the planned line instead of changing X scale.
    private func markerAnnotationPosition(
        actual: Double,
        planned: Double,
        hasGoal: Bool
    ) -> AnnotationPosition {
        guard hasGoal else { return .top }
        return actual <= planned ? .bottom : .top
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
