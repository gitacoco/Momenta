import SwiftUI

/// Popover empty state doubling as onboarding entry: walks through the three
/// required setup steps, all completed inside the Settings window.
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Set up Momenta")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Connect your Toggl account")
                step(2, "Enable the clients you want to track")
                step(3, "Set an hourly rate and monthly goal for each")
            }
            SettingsLink {
                Text("Open Settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 18, height: 18)
                .background(Circle().fill(.quaternary))
            Text(text)
                .font(.callout)
        }
    }
}
