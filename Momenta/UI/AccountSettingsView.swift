import SwiftUI

/// Settings → Account: Toggl token entry and validation, connection status,
/// last sync time, and disconnect (with the choice to clear cached data).
struct AccountSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var tokenInput = ""
    @State private var showDisconnectDialog = false

    private var account: AccountManager { appState.account }

    var body: some View {
        Form {
            switch account.state {
            case .disconnected:
                connectSection(errorText: nil)
            case .failed(let error):
                connectSection(errorText: error.errorDescription)
            case .validating:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Validating token…")
                        .foregroundStyle(.secondary)
                }
            case .connected(let snapshot):
                connectedSection(snapshot)
            }
        }
        .formStyle(.grouped)
        .task {
            await account.refreshMetadataIfNeeded()
        }
        .confirmationDialog(
            "Disconnect from Toggl?",
            isPresented: $showDisconnectDialog
        ) {
            Button("Disconnect, Keep Cached Data") {
                account.disconnect()
            }
            Button("Disconnect and Clear Cache", role: .destructive) {
                account.disconnect()
                appState.clearCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The API token is removed from the Keychain either way. Cached month data can be kept for offline viewing.")
        }
    }

    // MARK: Disconnected / failed

    @ViewBuilder
    private func connectSection(errorText: String?) -> some View {
        Section {
            SecureField("Toggl API token", text: $tokenInput, prompt: Text("Paste your API token"))
                .onSubmit(connect)
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            Button("Connect") {
                connect()
            }
            .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
        } footer: {
            Text("Find the token in Toggl Track under Profile → API Token. It is stored only in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func connect() {
        let token = tokenInput
        tokenInput = ""
        Task {
            await account.connect(token: token)
        }
    }

    // MARK: Connected

    @ViewBuilder
    private func connectedSection(_ snapshot: AccountSnapshot) -> some View {
        Section("Connection") {
            LabeledContent("Status") {
                HStack(spacing: 12) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text("Connected")
                            .foregroundStyle(.secondary)
                    }
                    Button("Disconnect…", role: .destructive) {
                        showDisconnectDialog = true
                    }
                }
            }
            LabeledContent("Name", value: snapshot.fullname)
            LabeledContent("Email", value: snapshot.email)
            LabeledContent("Plan") {
                if let organization = snapshot.defaultOrganization {
                    Text(organization.displayPlanName)
                } else {
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Connected", value: snapshot.connectedAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("Last sync") {
                if let lastSync = account.lastSyncAt {
                    Text(lastSync.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("Not synced yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
        if !snapshot.visibleWorkspaces.isEmpty {
            Section("Workspaces") {
                ForEach(snapshot.visibleWorkspaces) { workspace in
                    Label(workspace.name, systemImage: "rectangle.3.group")
                }
            }
        }
    }
}
