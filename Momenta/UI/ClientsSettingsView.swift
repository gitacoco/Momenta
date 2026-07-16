import SwiftUI
import UniformTypeIdentifiers

/// The middle column of Settings → Clients: the full Toggl client list (no
/// manual add), with enable switches and drag-to-reorder. SettingsView owns
/// the single window-level NavigationSplitView that contains this column.
struct ClientsListColumn: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedClientID: Int?

    var body: some View {
        Group {
            if appState.config.clients.isEmpty {
                emptyState
            } else {
                listPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Fetch once when the page opens; the footer button re-fetches.
            await appState.refreshClientList()
        }
        .onAppear(perform: consumeDeepLink)
        .onChange(of: appState.pendingSettingsDestination) {
            consumeDeepLink()
        }
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                listFooter
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(.background.secondary)
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
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if client.state(for: appState.currentMonth) == .needsSetup {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Needs setup")
                    .help("Finish setup to start tracking")
            }
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
                .lineLimit(1)
                .truncationMode(.tail)
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
}

/// The right-hand Clients column. Its no-selection state fills the complete
/// column so ContentUnavailableView receives the correct centered proposal;
/// the selected client's Form remains top-aligned by its own layout.
struct ClientDetailColumn: View {
    @Environment(AppState.self) private var appState
    let selectedClientID: Int?

    private var isMultiWorkspace: Bool {
        Set(appState.config.clients.map(\.workspaceID)).count > 1
    }

    var body: some View {
        ZStack {
            if let id = selectedClientID, let client = appState.config.client(id: id) {
                ClientDetailView(client: client, showsWorkspace: isMultiWorkspace)
                    .id(id) // reset editor state when switching clients
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView {
                    Label("Select a Client", systemImage: "person.crop.rectangle")
                } description: {
                    Text("Pick a client to configure its profile, rate, and goal.")
                }
            }
        }
        // Keep one stable, full-size detail root while switching between the
        // scrolling Form and the centered no-selection state.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// Right-hand configuration pane for one client. Owns the shared goal draft:
/// the rate lives in the profile section, hours/revenue in the goal section,
/// and every complete edit versions them together automatically.
private struct ClientDetailView: View {
    @Environment(AppState.self) private var appState
    let client: ClientConfig
    let showsWorkspace: Bool
    @State private var draft: GoalDraft
    @State private var showLogoImporter = false
    @State private var logoImportError: String?
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
               client.state(for: appState.currentMonth) == .needsSetup,
               missingRate || missingGoal {
                needsSetupSection
            }

            Section("Client Profile") {
                LabeledContent("Name on Toggl", value: client.togglName)
                LabeledContent("Display name") {
                    TextField("Display name", text: displayNameBinding)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 120, idealWidth: 220, maxWidth: 220)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .displayName)
                        .labelsHidden()
                }
                logoRow
                centeredControlRow("Brand color") {
                    ColorPicker("Brand color", selection: colorBinding, supportsOpacity: false)
                        .labelsHidden()
                }
                if showsWorkspace {
                    LabeledContent("Workspace", value: client.workspaceName)
                }
                centeredControlRow("Hourly rate") {
                    HStack(spacing: 6) {
                        TextField("Rate", value: rateBinding, format: .number)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .frame(minWidth: 56, idealWidth: 70, maxWidth: 70)
                            .focused($focusedField, equals: .rate)
                            .labelsHidden()
                        Picker("Currency", selection: currencyBinding) {
                            ForEach(currencyOptions, id: \.self) { code in
                                Text(code).tag(code)
                            }
                        }
                        .labelsHidden()
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
        .fileImporter(
            isPresented: $showLogoImporter,
            allowedContentTypes: [.image]
        ) { result in
            switch result {
            case .success(let url):
                importLogo(from: url)
            case .failure(let error):
                let cocoaError = error as NSError
                guard cocoaError.code != NSUserCancelledError else { return }
                logoImportError = error.localizedDescription
            }
        }
        .alert("Couldn’t Import Logo", isPresented: logoImportErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(logoImportError ?? "The selected image could not be imported.")
        }
        .disabled(client.isArchivedInToggl)
    }

    // MARK: Logo

    private var logoRow: some View {
        centeredControlRow("Logo") {
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
    }

    /// `LabeledContent` aligns on the text baseline, which looks off when the
    /// trailing control is taller than text. Rows with buttons, color wells,
    /// or pickers instead share this explicitly centered layout.
    private func centeredControlRow<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center) {
            Text(title)
            Spacer()
            content()
        }
    }

    private func importLogo(from url: URL) {
        guard var updated = appState.config.client(id: client.id) else { return }
        do {
            updated.logoFileName = try LogoStore.importLogo(from: url, for: client.id)
            appState.config.update(updated)
        } catch {
            logoImportError = error.localizedDescription
        }
    }

    private var logoImportErrorPresented: Binding<Bool> {
        Binding {
            logoImportError != nil
        } set: { isPresented in
            if !isPresented {
                logoImportError = nil
            }
        }
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
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("Finish setup to start tracking")
                        .foregroundStyle(.primary)
                }
                    .font(.callout.weight(.semibold))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 8) {
                    if missingRate {
                        setupItem("Set an hourly rate", target: .rate)
                    }
                    if missingGoal {
                        setupItem("Enter a monthly goal in hours or revenue", target: .hours)
                    }
                }
                .padding(.leading, 24)
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
                    .foregroundStyle(.secondary)
                Text(text)
                    .underline()
                    .foregroundStyle(.primary)
            }
            .font(.callout)
        }
        .buttonStyle(.plain)
    }

    // MARK: Pacing (with preview)

    private var pacingSection: some View {
        Section("Pacing") {
            VStack(alignment: .leading, spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        Text("Planned progress on")
                            .fixedSize()
                        Spacer(minLength: 0)
                        pacingOptions
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Planned progress on")
                        pacingOptions
                    }
                }
                .padding(.bottom, 14)

                Divider()

                Text(pacingCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            .padding(.vertical, 4)
        }
    }

    private var pacingOptions: some View {
        HStack(alignment: .top, spacing: 14) {
            pacingOption(.weekdays, title: "Weekdays only")
            pacingOption(.calendarDays, title: "Every day")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func pacingOption(_ mode: PacingMode, title: LocalizedStringKey) -> some View {
        PacingOptionButton(
            title: title,
            mode: mode,
            isSelected: currentPacing == mode
        ) {
            pacingBinding.wrappedValue = mode
        }
    }

    private var currentPacing: PacingMode {
        appState.config.client(id: client.id)?.pacing ?? .weekdays
    }

    private var pacingCaption: String {
        switch currentPacing {
        case .weekdays:
            return "On weekends, the goal line stays flat so days off do not create artificial debt."
        case .calendarDays:
            return "Every day carries the same share of the goal, including weekends."
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

/// A graphical radio option inspired by System Settings' Appearance picker.
/// The preview intentionally spans one Monday–Sunday week so the weekend
/// plateau is immediately visible instead of disappearing in a monthly chart.
private struct PacingOptionButton: View {
    let title: LocalizedStringKey
    let mode: PacingMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                PacingWeekPreview(mode: mode, isSelected: isSelected)
                    .frame(width: 142, height: 78)

                Text(title)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PacingWeekPreview: View {
    let mode: PacingMode
    let isSelected: Bool

    private let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]

    private var cumulativeFractions: [CGFloat] {
        switch mode {
        case .weekdays:
            return [0.20, 0.40, 0.60, 0.80, 1.00, 1.00, 1.00]
        case .calendarDays:
            return (1...7).map { CGFloat($0) / 7 }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 1) {
                    ForEach(0..<7, id: \.self) { index in
                        Rectangle()
                            .fill(
                                Color(nsColor: .separatorColor)
                                    .opacity(index >= 5 ? 0.16 : 0.045)
                            )
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(3)

                Canvas { context, size in
                    let horizontalInset: CGFloat = 10
                    let topInset: CGFloat = 12
                    let bottomInset: CGFloat = 7
                    let plotWidth = size.width - (horizontalInset * 2)
                    let plotHeight = max(1, size.height - topInset - bottomInset)

                    var grid = Path()
                    for index in 0..<7 {
                        let x = horizontalInset + plotWidth * CGFloat(index) / 6
                        grid.move(to: CGPoint(x: x, y: topInset))
                        grid.addLine(to: CGPoint(x: x, y: topInset + plotHeight))
                    }
                    context.stroke(
                        grid,
                        with: .color(Color(nsColor: .separatorColor).opacity(0.34)),
                        lineWidth: 0.5
                    )

                    let points = cumulativeFractions.enumerated().map { index, fraction in
                        CGPoint(
                            x: horizontalInset + plotWidth * CGFloat(index) / 6,
                            y: topInset + ((1 - fraction) * plotHeight)
                        )
                    }

                    var line = Path()
                    for (index, point) in points.enumerated() {
                        if index == 0 {
                            line.move(to: point)
                        } else {
                            line.addLine(to: point)
                        }
                    }
                    let lineColor = isSelected
                        ? Color.accentColor
                        : Color(nsColor: .secondaryLabelColor)
                    context.stroke(
                        line,
                        with: .color(lineColor),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    )

                    for point in points {
                        let dot = Path(ellipseIn: CGRect(
                            x: point.x - 2,
                            y: point.y - 2,
                            width: 4,
                            height: 4
                        ))
                        context.fill(dot, with: .color(lineColor))
                    }
                }
                .padding(.top, 3)
            }

            HStack(spacing: 0) {
                ForEach(Array(dayLabels.enumerated()), id: \.offset) { index, label in
                    Text(label)
                        .font(.caption2.monospaced())
                        .foregroundStyle(index >= 5 ? .secondary : .tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 5)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isSelected ? 3 : 1
                )
        }
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .accessibilityHidden(true)
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
