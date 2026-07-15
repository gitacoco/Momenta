import SwiftUI
import Charts
import UniformTypeIdentifiers

/// Settings → Clients: the full Toggl client list (no manual add) with enable
/// switches, drag-to-reorder, and a detail pane for local configuration.
/// Workspace grouping only appears for multi-workspace (Enterprise) accounts.
struct ClientsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedClientID: Int?

    var body: some View {
        Group {
            if appState.config.clients.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    listPane
                        .frame(width: 230)
                    Divider()
                        .ignoresSafeArea(.container, edges: .top)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .navigationSubtitle(selectedClientName ?? "")
        .task {
            // Fetch once when the page opens; the footer button re-fetches.
            await appState.refreshClientList()
        }
        .onAppear(perform: consumeDeepLink)
        .onChange(of: appState.pendingSettingsDestination) {
            consumeDeepLink()
        }
    }

    private var selectedClientName: String? {
        selectedClientID.flatMap { appState.config.client(id: $0)?.displayName }
    }

    /// Selects the client a popover deep link asked for.
    private func consumeDeepLink() {
        guard case .clients(let clientID) = appState.pendingSettingsDestination else { return }
        if let clientID {
            selectedClientID = clientID
        }
        appState.pendingSettingsDestination = nil
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

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedClientID) {
                if isMultiWorkspace {
                    ForEach(workspaceNames, id: \.self) { workspace in
                        Section(workspace) {
                            clientRows(activeClients.filter { $0.workspaceName == workspace })
                        }
                    }
                } else {
                    clientRows(activeClients)
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
            .scrollContentBackground(.hidden)
            Divider()
            listFooter
        }
        .background(.background.secondary)
    }

    /// Rows for one displayed group, draggable to reorder within the group.
    private func clientRows(_ group: [ClientConfig]) -> some View {
        ForEach(group) { client in
            clientRow(client)
                .tag(client.id)
        }
        .onMove { fromOffsets, toOffset in
            appState.config.move(ids: group.map(\.id), fromOffsets: fromOffsets, toOffset: toOffset)
        }
    }

    /// Footer shares the sidebar's base background — the divider alone
    /// separates it. Errors wrap fully instead of truncating.
    private var listFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = appState.clientListError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            refreshButton
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    private var refreshButton: some View {
        Button {
            Task { await appState.refreshClientList() }
        } label: {
            if appState.clientListLoading {
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing…")
                }
            } else {
                Label("Refresh from Toggl", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .disabled(appState.clientListLoading || !appState.account.isConnected)
    }

    private func clientRow(_ client: ClientConfig) -> some View {
        HStack(spacing: 6) {
            ClientAvatar(client: client, size: 14)
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
            ClientAvatar(client: client, size: 14)
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
    @State private var showLogoImporter = false
    @FocusState private var focusedField: ClientField?

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
                needsSetupSection
            }

            Section("Client Profile") {
                LabeledContent("Name on Toggl", value: client.togglName)
                LabeledContent("Display name") {
                    TextField("Display name", text: displayNameBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .displayName)
                        .labelsHidden()
                }
                logoRow
                ColorPicker("Brand color", selection: colorBinding, supportsOpacity: false)
                if showsWorkspace {
                    LabeledContent("Workspace", value: client.workspaceName)
                }
                LabeledContent("Hourly rate") {
                    HStack(spacing: 6) {
                        TextField("Rate", value: rateBinding, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .focused($focusedField, equals: .rate)
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

            pacingSection

            if client.isArchivedInToggl {
                Section {
                    Label(
                        "This client no longer exists in Toggl. Its history stays available; configuration is read-only.",
                        systemImage: "archivebox"
                    )
                    .foregroundStyle(.secondary)
                }
            } else {
                GoalEditorSection(client: client, draft: $draft, focus: $focusedField)
            }
            GoalHistoryView(client: client)
        }
        .formStyle(.grouped)
        .disabled(client.isArchivedInToggl)
    }

    // MARK: Logo

    private var logoRow: some View {
        LabeledContent("Logo") {
            HStack(spacing: 8) {
                ClientAvatar(client: appState.config.client(id: client.id) ?? client, size: 22)
                Button("Choose…") {
                    showLogoImporter = true
                }
                if appState.config.client(id: client.id)?.logoFileName != nil {
                    Button("Remove") {
                        removeLogo()
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showLogoImporter,
            allowedContentTypes: [.image]
        ) { result in
            guard case .success(let url) = result else { return }
            importLogo(from: url)
        }
    }

    private func importLogo(from url: URL) {
        guard var updated = appState.config.client(id: client.id) else { return }
        guard let fileName = try? LogoStore.importLogo(from: url, for: client.id) else { return }
        updated.logoFileName = fileName
        appState.config.update(updated)
    }

    private func removeLogo() {
        guard var updated = appState.config.client(id: client.id) else { return }
        if let fileName = updated.logoFileName {
            LogoStore.deleteLogo(named: fileName)
        }
        updated.logoFileName = nil
        appState.config.update(updated)
    }

    // MARK: Needs setup (itemized, click-to-focus)

    private var missingRate: Bool {
        (draft.hourlyRate ?? 0) <= 0
    }

    private var missingGoal: Bool {
        (draft.hours ?? 0) <= 0 && (draft.revenue ?? 0) <= 0
    }

    private var needsSetupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Finish setup to start tracking", systemImage: "exclamationmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                if missingRate {
                    setupItem("Set an hourly rate", target: .rate)
                }
                if missingGoal {
                    setupItem("Enter a monthly goal in hours or revenue", target: .hours)
                }
                if !missingRate && !missingGoal {
                    setupItem("Press Save in Monthly Goal to apply", target: .hours)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Each unmet requirement is a link that focuses the matching field.
    private func setupItem(_ text: String, target: ClientField) -> some View {
        Button {
            focusedField = target
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.forward.circle")
                Text(text)
                    .underline()
            }
            .font(.callout)
            .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
    }

    // MARK: Pacing (with preview)

    private var pacingSection: some View {
        Section("Pacing") {
            Picker("Planned progress on", selection: pacingBinding) {
                Text("Weekdays only").tag(PacingMode.weekdays)
                Text("Every calendar day").tag(PacingMode.calendarDays)
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 4) {
                pacingPreview
                    .frame(height: 56)
                Text(pacingCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    /// The month's planned goal line under the selected pacing, so the choice
    /// has a visible consequence before any real data exists.
    private var pacingPreview: some View {
        let month = appState.currentMonth
        let timeZone = appState.timeZone
        let pacing = appState.config.client(id: client.id)?.pacing ?? .weekdays
        let weights = ProgressCalculator.dailyWeights(month: month, pacing: pacing, timeZone: timeZone)
        let total = max(1, weights.reduce(0, +))
        var cumulative = 0
        let points: [(day: Int, fraction: Double)] = weights.enumerated().map { index, weight in
            cumulative += weight
            return (index + 1, Double(cumulative) / Double(total))
        }
        return Chart(points, id: \.day) { point in
            LineMark(
                x: .value("Day", point.day),
                y: .value("Planned", point.fraction)
            )
            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .foregroundStyle(.secondary)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }

    private var pacingCaption: String {
        let pacing = appState.config.client(id: client.id)?.pacing ?? .weekdays
        switch pacing {
        case .weekdays:
            return "The goal line stays flat on weekends — days off create no artificial debt."
        case .calendarDays:
            return "Every day carries the same share of the goal, weekends included."
        }
    }

    private var currencyOptions: [String] {
        var codes = Self.currencyCodes
        if !codes.contains(client.currency) {
            codes.insert(client.currency, at: 0)
        }
        return codes
    }

    // MARK: Bindings

    /// Prefilled with the effective name; storing the Toggl name (or nothing)
    /// clears the override rather than persisting a redundant copy.
    private var displayNameBinding: Binding<String> {
        Binding {
            let config = appState.config.client(id: client.id)
            return config?.displayNameOverride ?? config?.togglName ?? client.togglName
        } set: { newValue in
            guard var updated = appState.config.client(id: client.id) else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            updated.displayNameOverride = (trimmed.isEmpty || trimmed == updated.togglName) ? nil : trimmed
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
