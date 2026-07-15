import SwiftUI

/// Popover empty state doubling as onboarding entry: walks through the three
/// required setup steps, with live completion state. Everything is done
/// inside the Settings window; remaining settings rely on defaults.
struct EmptyStateView: View {
    @Environment(AppState.self) private var appState

    private var tokenDone: Bool {
        appState.account.isConnected
    }

    private var clientsDone: Bool {
        appState.config.clients.contains { $0.isEnabled && !$0.isArchivedInToggl }
    }

    private var goalsDone: Bool {
        appState.hasConfiguredClients
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Set up Momenta")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                step(1, "Connect your Toggl account", done: tokenDone)
                step(2, "Enable the clients you want to track", done: clientsDone)
                step(3, "Set an hourly rate and monthly goal for each", done: goalsDone)
            }
            Button(tokenDone ? "Continue in Settings" : "Open Settings") {
                // Land on the step the user is actually on.
                appState.pendingSettingsDestination = tokenDone ? .clients(clientID: nil) : .account
                openSettingsWindow()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    private func step(_ number: Int, _ text: String, done: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .frame(width: 18, height: 18)
            } else {
                Text("\(number)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.quaternary))
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(done ? .secondary : .primary)
                .strikethrough(done, color: .secondary)
        }
    }
}
