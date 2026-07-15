import SwiftUI

/// Settings → Clients: the full Toggl client list (no manual add), grouped by
/// workspace, with enable switches and a detail pane for local configuration.
struct ClientsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedClientID: Int?

    var body: some View {
        Group {
            if appState.config.clients.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    clientList
                        .frame(width: 230)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .task {
            // Fetch once when the page opens; the toolbar button re-fetches.
            await appState.refreshClientList()
        }
    }

    // MARK: Empty / disconnected

    @ViewBuilder
    private var emptyState: some View {
        if appState.clientListLoading {
            ProgressView("Loading clients from Toggl…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.account.isConnected {
            ContentUnavailableView {
                Label("No Clients in Toggl", systemImage: "person.2.slash")
            } description: {
                Text(appState.clientListError ?? "Create clients in Toggl Track; they appear here automatically.")
            } actions: {
                refreshButton
            }
        } else {
            ContentUnavailableView {
                Label("Not Connected", systemImage: "personalhotspot.slash")
            } description: {
                Text("Connect your Toggl account first — the client list comes straight from Toggl.")
            }
        }
    }

    // MARK: Client list (secondary sidebar)

    private var activeClients: [ClientConfig] {
        appState.config.clients.filter { !$0.isArchivedInToggl }
    }

    private var archivedClients: [ClientConfig] {
        appState.config.clients.filter { $0.isArchivedInToggl }
    }

    private var workspaceNames: [String] {
        var names: [String] = []
        for client in activeClients where !names.contains(client.workspaceName) {
            names.append(client.workspaceName)
        }
        return names
    }

    private var clientList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedClientID) {
                ForEach(workspaceNames, id: \.self) { workspace in
                    Section(workspace) {
                        ForEach(activeClients.filter { $0.workspaceName == workspace }) { client in
                            clientRow(client)
                                .tag(client.id)
                        }
                    }
                }
                if !archivedClients.isEmpty {
                    Section("Archived") {
                        ForEach(archivedClients) { client in
                            archivedRow(client)
                                .tag(client.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                refreshButton
                    .controlSize(.small)
                if let error = appState.clientListError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(6)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await appState.refreshClientList() }
        } label: {
            if appState.clientListLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Refresh from Toggl", systemImage: "arrow.clockwise")
            }
        }
        .disabled(appState.clientListLoading || !appState.account.isConnected)
    }

    private func clientRow(_ client: ClientConfig) -> some View {
        let month = appState.currentMonth
        return HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: client.colorHex))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(client.displayName)
                if client.state(for: month) == .needsSetup {
                    Text("Needs setup")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Toggle("", isOn: enabledBinding(client))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .opacity(client.isEnabled ? 1 : 0.6)
    }

    private func archivedRow(_ client: ClientConfig) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: client.colorHex))
                .frame(width: 8, height: 8)
            Text(client.displayName)
            Spacer()
            Text("Archived")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
    }

    private func enabledBinding(_ client: ClientConfig) -> Binding<Bool> {
        Binding {
            appState.config.client(id: client.id)?.isEnabled ?? false
        } set: { newValue in
            guard var updated = appState.config.client(id: client.id) else { return }
            updated.isEnabled = newValue
            appState.config.update(updated)
        }
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detail: some View {
        if let id = selectedClientID, let client = appState.config.client(id: id) {
            ClientDetailView(client: client)
                .id(id) // reset editor state when switching clients
        } else {
            ContentUnavailableView {
                Label("Select a Client", systemImage: "person.crop.rectangle")
            } description: {
                Text("Pick a client to configure its rate, goal, and appearance.")
            }
        }
    }
}

/// Right-hand configuration pane for one client.
private struct ClientDetailView: View {
    @Environment(AppState.self) private var appState
    let client: ClientConfig

    var body: some View {
        Form {
            Section("Appearance") {
                TextField(
                    "Display name",
                    text: displayNameBinding,
                    prompt: Text(client.togglName)
                )
                ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                LabeledContent("Toggl name", value: client.togglName)
                LabeledContent("Workspace", value: client.workspaceName)
            }
            Section("Pacing") {
                Picker("Planned progress on", selection: pacingBinding) {
                    Text("Weekdays only").tag(PacingMode.weekdays)
                    Text("Every calendar day").tag(PacingMode.calendarDays)
                }
                .pickerStyle(.radioGroup)
            }
            if client.isArchivedInToggl {
                Section {
                    Label(
                        "This client no longer exists in Toggl. Its history stays available; configuration is read-only.",
                        systemImage: "archivebox"
                    )
                    .foregroundStyle(.secondary)
                }
            } else {
                GoalEditorView(client: client)
            }
            GoalHistoryView(client: client)
        }
        .formStyle(.grouped)
        .disabled(client.isArchivedInToggl)
    }

    private var displayNameBinding: Binding<String> {
        Binding {
            appState.config.client(id: client.id)?.displayNameOverride ?? ""
        } set: { newValue in
            guard var updated = appState.config.client(id: client.id) else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            updated.displayNameOverride = trimmed.isEmpty ? nil : trimmed
            appState.config.update(updated)
        }
    }

    private var colorBinding: Binding<Color> {
        Binding {
            Color(hex: appState.config.client(id: client.id)?.colorHex ?? client.colorHex)
        } set: { newValue in
            guard var updated = appState.config.client(id: client.id) else { return }
            updated.colorHex = newValue.hexString
            appState.config.update(updated)
        }
    }

    private var pacingBinding: Binding<PacingMode> {
        Binding {
            appState.config.client(id: client.id)?.pacing ?? .weekdays
        } set: { newValue in
            guard var updated = appState.config.client(id: client.id) else { return }
            updated.pacing = newValue
            appState.config.update(updated)
        }
    }
}

extension Color {
    /// "#RRGGBB" for persistence; sRGB.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .controlAccentColor
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
