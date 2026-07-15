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
                .map { "\($0.client.displayName.prefix(1)) \(Format.percent($0.fraction))" }
                .joined(separator: " · ")
        }
        return Format.percent(aggregate.fraction)
    }
}
