import AppKit
import SwiftUI

/// Metrics derived from AppKit's current menu-bar font so custom progress
/// glyphs follow the active system appearance instead of assuming a fixed
/// status-item height.
private enum MenuBarMetrics {
    static var glyphSize: CGFloat {
        ceil(NSFont.menuBarFont(ofSize: 0).boundingRectForFont.height)
    }
}

/// Pure presentation data shared by the real status item, Settings preview,
/// accessibility, and tests. Geometry clamps progress later; raw fractions
/// stay intact so values above 100% remain truthful to assistive technology.
struct MenuBarPresentation: Equatable, Sendable {
    struct ProgressObject: Identifiable, Equatable, Sendable {
        var id: String
        var name: String
        var monogram: String?
        var fraction: Double?

        var accessibilityDescription: String {
            if let fraction {
                return "\(name) \(Format.percent(fraction))"
            }
            return "\(name) no goal"
        }
    }

    var objectMode: MenuBarObjectMode
    var visualization: MenuBarVisualization
    var period: AggregationPeriod
    var aggregation: ProgressObject?
    var clients: [ProgressObject]
    /// Accessibility descriptions for every client the mode covers, including
    /// those whose ring is visually omitted because nothing is planned this
    /// period: sight loses nothing by dropping an empty ring, but VoiceOver
    /// must not conflate a planned day off with missing data.
    var clientAccessibilityDescriptions: [String]
    var overallPercentageText: String?

    init(aggregate: AggregateProgress?, settings: DisplaySettings, unit: DisplayUnit) {
        objectMode = settings.menuBarObjectMode
        visualization = settings.menuBarVisualization
        period = settings.aggregationPeriod
        overallPercentageText = nil

        guard let aggregate, !aggregate.shares.isEmpty else {
            aggregation = nil
            clients = []
            clientAccessibilityDescriptions = []
            return
        }

        // Follow the display unit: a non-billable client has no revenue, so
        // its revenue ring would read a meaningless 100%.
        func fraction(for share: AggregateProgress.ClientShare) -> Double? {
            switch unit {
            case .revenue:
                share.targetIsAvailable ? share.fraction : nil
            case .hours:
                share.hoursTargetIsAvailable ? share.hoursFraction : nil
            }
        }

        let aggregateFraction: Double? = switch unit {
        case .revenue:
            aggregate.targetIsAvailable ? aggregate.fraction : nil
        case .hours:
            aggregate.hoursTargetIsAvailable ? aggregate.hoursFraction : nil
        }
        let aggregateObject = ProgressObject(
            id: "aggregation",
            name: "Overall",
            monogram: nil,
            fraction: aggregateFraction
        )
        let clientObjects = aggregate.shares.compactMap { share -> ProgressObject? in
            // No target for this period — a scheduled day off. Its ring would
            // draw an empty track, pixel-identical to 0% done, reading as debt
            // on a day that plans none. Omit it, as Overall already does.
            guard let clientFraction = fraction(for: share) else { return nil }

            let name = share.client.displayName
            let firstCharacter = name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(1)
                .uppercased()
            return ProgressObject(
                id: "client-\(share.id)",
                name: name,
                monogram: firstCharacter.isEmpty ? "•" : String(firstCharacter.prefix(1)),
                fraction: clientFraction
            )
        }
        // Only day means "off today"; a targetless month/week is a goal that
        // simply doesn't exist in this unit.
        let restingLabel = period == .day ? "day off" : "no goal"
        let clientDescriptions = aggregate.shares.map { share in
            if let clientFraction = fraction(for: share) {
                return "\(share.client.displayName) \(Format.percent(clientFraction))"
            }
            return "\(share.client.displayName), \(restingLabel)"
        }

        switch objectMode {
        case .aggregation:
            aggregation = aggregateObject
            clients = []
            clientAccessibilityDescriptions = []
        case .split:
            aggregation = nil
            clients = clientObjects
            clientAccessibilityDescriptions = clientDescriptions
        case .both:
            aggregation = aggregateObject
            clients = clientObjects
            clientAccessibilityDescriptions = clientDescriptions
        }

        if settings.showsOverallPercentage,
           aggregation != nil,
           let fraction = aggregateObject.fraction {
            overallPercentageText = Format.percent(fraction)
        }
    }

    var isEmpty: Bool {
        aggregation == nil && clients.isEmpty
    }

    var accessibilityValue: String {
        var parts = [aggregation?.accessibilityDescription].compactMap { $0 }
        parts += clientAccessibilityDescriptions
        guard !parts.isEmpty else {
            return "\(period.accessibilityLabel), progress unavailable"
        }
        return ([period.accessibilityLabel] + parts)
            .joined(separator: ", ")
    }
}

/// The compact status-item label. Progress is encoded in ring or waterline
/// glyphs, with an optional numeric percentage beside Overall.
struct MenuBarLabel: View {
    var aggregate: AggregateProgress?
    var settings: DisplaySettings
    var unit: DisplayUnit

    var body: some View {
        let presentation = MenuBarPresentation(aggregate: aggregate, settings: settings, unit: unit)

        HStack(spacing: 6) {
            if presentation.isEmpty {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                if let aggregation = presentation.aggregation {
                    HStack(spacing: 3) {
                        progressGlyph(aggregation, style: presentation.visualization)
                        if let percentage = presentation.overallPercentageText {
                            Text(percentage)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                    }
                }

                if presentation.aggregation != nil, !presentation.clients.isEmpty {
                    Divider()
                        .frame(height: MenuBarMetrics.glyphSize)
                        .padding(.horizontal, 2)
                }

                if !presentation.clients.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(presentation.clients) { client in
                            progressGlyph(client, style: presentation.visualization)
                        }
                    }
                }
            }

            Text(presentation.period.menuBarLabel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Momenta")
        .accessibilityValue(presentation.accessibilityValue)
    }

    @ViewBuilder
    private func progressGlyph(
        _ object: MenuBarPresentation.ProgressObject,
        style: MenuBarVisualization
    ) -> some View {
        switch style {
        case .ring:
            RingProgressGlyph(fraction: object.fraction, monogram: object.monogram)
        case .waterline:
            HStack(spacing: 1) {
                if let monogram = object.monogram {
                    Text(monogram)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }
                WaterlineProgressGlyph(fraction: object.fraction)
            }
            .frame(height: MenuBarMetrics.glyphSize)
        }
    }
}

private struct RingProgressGlyph: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var fraction: Double?
    var monogram: String?

    private var clampedFraction: Double {
        guard let fraction, fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }

    private var trackOpacity: Double {
        colorSchemeContrast == .increased ? 0.45 : 0.24
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(trackOpacity), lineWidth: 2)

            if clampedFraction > 0 {
                Circle()
                    .trim(from: 0, to: clampedFraction)
                    .stroke(
                        Color.primary,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }

            if let monogram {
                Text(monogram)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: MenuBarMetrics.glyphSize, height: MenuBarMetrics.glyphSize)
        .accessibilityHidden(true)
    }
}

private struct WaterlineProgressGlyph: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.displayScale) private var displayScale

    var fraction: Double?

    private var clampedFraction: Double {
        guard let fraction, fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }

    private var trackOpacity: Double {
        colorSchemeContrast == .increased ? 0.45 : 0.24
    }

    var body: some View {
        GeometryReader { proxy in
            let rawHeight = proxy.size.height * clampedFraction
            let pixelAlignedHeight = (rawHeight * displayScale).rounded(.down) / displayScale

            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.primary.opacity(trackOpacity))

                if pixelAlignedHeight > 0 {
                    Rectangle()
                        .fill(Color.primary)
                        .frame(height: pixelAlignedHeight)
                }
            }
            .clipShape(Capsule())
        }
        .frame(width: 4, height: MenuBarMetrics.glyphSize)
        .accessibilityHidden(true)
    }
}
