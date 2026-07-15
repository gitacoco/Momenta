import SwiftUI

/// Settings → Clients: the full Toggl client list (no manual add) with enable
/// switches and a detail pane for local configuration. Workspace grouping
/// only appears when the account actually has multiple workspaces
/// (Toggl Enterprise); on single-workspace plans it is meaningless noise.
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
            // Fetch once when the page opens; the footer button re-fetches.
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

    private var isMultiWorkspace: Bool {
        Set(appState.config.clients.map(\.workspaceID)).count > 1
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
                if isMultiWorkspace {
                    ForEach(workspaceNames, id: \.self) { workspace in
                        Section(workspace) {
                            ForEach(activeClients.filter { $0.workspaceName == workspace }) { client in
                                clientRow(client)
                                    .tag(client.id)
                            }
                        }
                    }
                } else {
                    ForEach(activeClients) { client in
                        clientRow(client)
                            .tag(client.id)
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
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: client.colorHex))
                .frame(width: 8, height: 8)
            Text(client.displayName)
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
            ClientDetailView(client: client, showsWorkspace: isMultiWorkspace)
                .id(id) // reset editor state when switching clients
        } else {
            ContentUnavailableView {
                Label("Select a Client", systemImage: "person.crop.rectangle")
            } description: {
                Text("Pick a client to configure its profile, rate, and goal.")
            }
        }
    }
}

/// Right-hand configuration pane for one client. Owns the shared goal draft:
/// the rate lives in the profile section, hours/revenue in the goal section,
/// and one save action versions them together.
private struct ClientDetailView: View {
    @Environment(AppState.self) private var appState
    let client: ClientConfig
    let showsWorkspace: Bool
    @State private var draft: GoalDraft

    init(client: ClientConfig, showsWorkspace: Bool) {
        self.client = client
        self.showsWorkspace = showsWorkspace
        let month = YearMonth(containing: Date(), timeZone: .current)
        _draft = State(initialValue: GoalDraft(goal: client.goal(for: month)))
    }

    private static let currencyCodes = [
        "USD", "EUR", "GBP", "CNY", "JPY", "HKD", "SGD", "CAD",
        "AUD", "CHF", "SEK", "NOK", "DKK", "NZD", "KRW", "TWD", "INR",
    ]

    var body: some View {
        Form {
            if client.isEnabled, !client.isArchivedInToggl,
               client.state(for: appState.currentMonth) == .needsSetup {
                Section {
                    Label(
                        "Needs setup — set an hourly rate and a monthly goal below. Tracked time starts counting once configured.",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }

            Section("Client Profile") {
                TextField(
                    "Display name",
                    text: displayNameBinding,
                    prompt: Text(client.togglName)
                )
                ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                if client.displayNameOverride != nil {
                    LabeledContent("Toggl name", value: client.togglName)
                }
                if showsWorkspace {
                    LabeledContent("Workspace", value: client.workspaceName)
                }
                LabeledContent("Hourly rate") {
                    HStack(spacing: 6) {
                        TextField("Rate", value: rateBinding, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .labelsHidden()
                        Picker("Currency", selection: currencyBinding) {
                            ForEach(currencyOptions, id: \.self) { code in
                                Text(code).tag(code)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
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
                GoalEditorSection(client: client, draft: $draft)
            }
            GoalHistoryView(client: client)
        }
        .formStyle(.grouped)
        .disabled(client.isArchivedInToggl)
    }

    private var currencyOptions: [String] {
        var codes = Self.currencyCodes
        if !codes.contains(client.currency) {
            codes.insert(client.currency, at: 0)
        }
        return codes
    }

    // MARK: Bindings

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

    /// Currency is a display preference, saved immediately (not versioned
    /// with the goal).
    private var currencyBinding: Binding<String> {
        Binding {
            appState.config.client(id: client.id)?.currency ?? "USD"
        } set: { newValue in
            guard var updated = appState.config.client(id: client.id) else { return }
            updated.currencyCode = newValue
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

    private var rateBinding: Binding<Decimal?> {
        Binding { draft.hourlyRate } set: { draft.setRate($0) }
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
