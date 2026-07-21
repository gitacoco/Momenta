import SwiftUI

/// Settings → Account: Toggl token entry and validation, connection status,
/// last sync time, and disconnect (with the choice to clear cached data).
struct AccountSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var tokenInput = ""
    @State private var showDisconnectDialog = false

    private var account: AccountManager { appState.account }
    private var iCloudSync: ICloudSyncManager? { appState.iCloudSync }

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
            if let iCloudSync {
                iCloudSection(iCloudSync)
            }
        }
        .formStyle(.grouped)
        .task {
            await account.refreshMetadataIfNeeded()
        }
        .confirmationDialog(
            account.usesICloudCredential ? "Disconnect on all Macs?" : "Disconnect from Toggl?",
            isPresented: $showDisconnectDialog
        ) {
            Button("Disconnect, Keep Cached Data") {
                disconnect(clearCache: false)
            }
            Button("Disconnect and Clear Cache", role: .destructive) {
                disconnect(clearCache: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if account.usesICloudCredential {
                Text("The synchronizable API token will be deleted from iCloud Keychain and the deletion will propagate to your other Macs. Cached month data can be kept for offline viewing.")
            } else {
                Text("The API token is removed from this Mac’s Keychain either way. Cached month data can be kept for offline viewing.")
            }
        }
    }

    private func disconnect(clearCache: Bool) {
        if let iCloudSync, account.usesICloudCredential {
            iCloudSync.disconnectOnAllMacs()
        } else {
            account.disconnect()
        }
        if clearCache {
            appState.clearCache()
        }
    }

    // MARK: Disconnected / failed

    @ViewBuilder
    private func connectSection(errorText: String?) -> some View {
        Section {
            LabeledContent("Toggl API token") {
                HStack(spacing: 8) {
                    SecureField("API token", text: $tokenInput, prompt: Text("Paste your API token"))
                        .labelsHidden()
                        .frame(minWidth: 220)
                        .onSubmit(connect)
                    Button("Connect") {
                        connect()
                    }
                    .disabled(tokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
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

    // MARK: iCloud sync

    @ViewBuilder
    private func iCloudSection(_ sync: ICloudSyncManager) -> some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 8) {
                    if sync.state == .syncing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Circle()
                            .fill(sync.state == .synced ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                    Text(sync.state.label)
                        .foregroundStyle(.secondary)
                    iCloudStatusAction(sync)
                }
            }

            if let discovered = account.discoveredSyncedAccount {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Toggl account found in iCloud")
                        .font(.headline)
                    Text("\(discovered.fullname) · \(discovered.email)")
                        .foregroundStyle(.secondary)
                    Text("Confirm before this Mac uses the synced credential or downloads financial settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Use This Account") {
                            Task { await sync.confirmDiscoveredAccount() }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Cancel") {
                            sync.cancelDiscoveredAccount()
                        }
                    }
                }
            } else if sync.state == .waitingForInitialMerge {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This Mac and iCloud both have client settings.")
                    Text("Momenta will preserve non-conflicting clients and goal months; values already accepted by iCloud win same-field conflicts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Merge with iCloud") {
                            Task { await sync.confirmInitialMerge() }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Not Now") {
                            sync.cancelInitialMerge()
                        }
                    }
                }
            } else if let message = sync.attentionMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if let lastSuccess = sync.lastSuccessfulSyncAt {
                LabeledContent(
                    "Last successful sync",
                    value: lastSuccess.formatted(date: .abbreviated, time: .shortened)
                )
            }

        } header: {
            Text("iCloud Sync")
        } footer: {
            Text("The API token uses iCloud Keychain. Client settings and Logo assets use your private CloudKit database. Stopping on this Mac does not delete the synced credential; disconnecting while sync is enabled removes it from all Macs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func iCloudStatusAction(_ sync: ICloudSyncManager) -> some View {
        switch sync.state {
        case .off:
            if account.discoveredSyncedAccount == nil {
                Button("Set Up…") {
                    Task { await sync.enable() }
                }
                .disabled(account.state == .validating)
            }
        case .needsAttention:
            Button("Retry") {
                if sync.isEnabled {
                    sync.retry()
                } else {
                    Task { await sync.enable() }
                }
            }
            if sync.isEnabled {
                Menu {
                    Button("Stop Using on This Mac") {
                        sync.stopUsingOnThisMac()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More iCloud Sync actions")
            }
        case .synced:
            Button("Stop Using on This Mac") {
                sync.stopUsingOnThisMac()
            }
        case .waitingForAccountConfirmation, .waitingForInitialMerge, .syncing:
            EmptyView()
        }
    }
}
