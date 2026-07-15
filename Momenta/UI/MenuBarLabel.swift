import SwiftUI

/// The always-visible menu bar item: total goal progress for the configured
/// aggregation period, optionally split per client. Revenue-based throughout.
struct MenuBarLabel: View {
    var aggregate: AggregateProgress?
    var split: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.needle")
            Text(text)
                .monospacedDigit()
        }
    }

    private var text: String {
        guard let aggregate, !aggregate.shares.isEmpty else { return "—" }
        if split {
            return aggregate.shares
                .map { "\($0.client.displayName.prefix(1)) \(shareText($0))" }
                .joined(separator: " · ")
        }
        // Zero target: e.g. Day view on a weekend when every client paces by
        // weekdays. Show "no goal" rather than a misleading 0%.
        guard aggregate.targetRevenue > 0 else { return "—" }
        return Format.percent(aggregate.fraction)
    }

    private func shareText(_ share: AggregateProgress.ClientShare) -> String {
        share.targetRevenue > 0 ? Format.percent(share.fraction) : "—"
    }
}
