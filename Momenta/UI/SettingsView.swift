import SwiftUI

/// Single Settings window (Cmd+,) with an always-visible Account / Clients /
/// Display sidebar. Account and Display use two columns; Clients promotes the
/// same primary sidebar into one native three-column NavigationSplitView.
struct SettingsView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case account
        case clients
        case display

        var id: String { rawValue }

        var label: String {
            switch self {
            case .account: return "Account"
            case .clients: return "Clients"
            case .display: return "Display"
            }
        }

        var icon: String {
            switch self {
            case .account: return "person.crop.circle"
            case .clients: return "person.2"
            case .display: return "slider.horizontal.3"
            }
        }
    }

    @Environment(AppState.self) private var appState
    @State private var selection: Section? = .account
    @State private var backHistory: [Section] = []
    @State private var forwardHistory: [Section] = []
    @State private var isApplyingHistory = false
    @State private var selectedClientID: Int?

    private var currentSection: Section {
        selection ?? .account
    }

    var body: some View {
        Group {
            if currentSection == .clients {
                clientsNavigation
            } else {
                standardNavigation
            }
        }
        // Keep one stable vertical contract while switching between the
        // two- and three-column settings layouts. The split view paints into
        // the window's bottom safe area so its sidebar backgrounds reach the
        // rounded window edge instead of exposing the white window backing.
        .frame(minHeight: 560, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear(perform: consumeDestination)
        .onChange(of: selection, recordNavigation)
        .onChange(of: appState.pendingSettingsDestination) {
            consumeDestination()
        }
    }

    /// Account and Display are native two-column settings pages.
    private var standardNavigation: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            primarySidebar
        } detail: {
            Group {
                switch currentSection {
                case .account:
                    AccountSettingsView()
                        .navigationTitle(Section.account.label)
                case .display:
                    displaySettings
                        .navigationTitle(Section.display.label)
                case .clients:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { navigatorToolbar }
        }
        .frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Clients is one window-level three-column split. Nesting another split
    /// inside the two-column detail makes toolbar titles and width proposals
    /// compete, which can push both outer columns beyond the window bounds.
    private var clientsNavigation: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            primarySidebar
        } content: {
            ClientsListColumn(selectedClientID: $selectedClientID)
                .navigationTitle(Section.clients.label)
                .navigationSplitViewColumnWidth(min: 220, ideal: 230, max: 320)
                .toolbar { navigatorToolbar }
        } detail: {
            ClientDetailColumn(selectedClientID: selectedClientID)
                .navigationSplitViewColumnWidth(min: 480, ideal: 680, max: .infinity)
                .overlay(alignment: .topLeading) {
                    detailTitlebar(title: selectedClientName)
                }
        }
        .frame(minWidth: 900, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var primarySidebar: some View {
        List(Section.allCases, selection: $selection) { section in
            Label(section.label, systemImage: section.icon)
                .tag(section)
        }
        .listStyle(.sidebar)
        .scrollDisabled(true)
        .frame(minWidth: 180, idealWidth: 180, maxWidth: 180)
        .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 180)
        // Settings sidebars never collapse or expose a sidebar toggle.
        .toolbar(removing: .sidebarToggle)
    }

    private var selectedClientName: String? {
        selectedClientID.flatMap { appState.config.client(id: $0)?.displayName }
    }

    private func detailTitlebar(title: String?) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .accessibilityHidden(true)

            if let title {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .padding(.leading, 24)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .frame(height: 52)
        .offset(x: -1, y: -52)
        .allowsHitTesting(false)
    }

    @ToolbarContentBuilder
    private var navigatorToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button(action: navigateBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(backHistory.isEmpty)
                .keyboardShortcut("[", modifiers: .command)

                Button(action: navigateForward) {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(forwardHistory.isEmpty)
                .keyboardShortcut("]", modifiers: .command)
            }
            .controlGroupStyle(.navigation)
            .controlSize(.extraLarge)
            .labelStyle(.iconOnly)
        }
    }

    /// Routes deep links from the popover. The clients destination is left
    /// pending so ClientsListColumn can also pick up the client selection.
    private func consumeDestination() {
        switch appState.pendingSettingsDestination {
        case .account:
            selection = .account
            appState.pendingSettingsDestination = nil
        case .clients:
            selection = .clients
        case nil:
            break
        }
    }

    /// Mirrors System Settings' back/forward navigator while keeping the
    /// settings sidebar permanently visible.
    private func recordNavigation(_ oldSelection: Section?, _ newSelection: Section?) {
        guard let oldSelection, let newSelection, oldSelection != newSelection else { return }

        if isApplyingHistory {
            isApplyingHistory = false
            return
        }

        backHistory.append(oldSelection)
        forwardHistory.removeAll()
    }

    private func navigateBack() {
        guard let destination = backHistory.popLast() else { return }
        forwardHistory.append(currentSection)
        isApplyingHistory = true
        selection = destination
    }

    private func navigateForward() {
        guard let destination = forwardHistory.popLast() else { return }
        backHistory.append(currentSection)
        isApplyingHistory = true
        selection = destination
    }

    private var displaySettings: some View {
        @Bindable var appState = appState
        return Form {
            // Hero: the menu bar item itself — everything below configures it.
            SwiftUI.Section {
                VStack(spacing: 10) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        MenuBarLabel(
                            aggregate: appState.menuBarAggregate(at: context.date),
                            settings: appState.displaySettings
                        )
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
                    Text("Live preview of your menu bar item")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }

            SwiftUI.Section("Menu bar") {
                Picker("Progress", selection: $appState.displaySettings.menuBarObjectMode) {
                    ForEach(MenuBarObjectMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Period", selection: $appState.displaySettings.aggregationPeriod) {
                    ForEach(AggregationPeriod.allCases) { period in
                        Text(period.label).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Indicator style", selection: $appState.displaySettings.menuBarVisualization) {
                    ForEach(MenuBarVisualization.allCases) { visualization in
                        Text(visualization.label).tag(visualization)
                    }
                }
                .pickerStyle(.segmented)
            }

            SwiftUI.Section {
                Picker("Refresh data", selection: $appState.displaySettings.autoRefreshOnOpen) {
                    Text("When the popover opens").tag(true)
                    Text("Manually only").tag(false)
                }

                Text("Toggl's free plan allows 30 API requests per hour. Manual mode spends them only when you ask.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SwiftUI.Section("Time") {
                Picker("Time zone", selection: $appState.displaySettings.timeZoneIdentifier) {
                    Text("System (\(TimeZone.current.identifier))").tag(String?.none)
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
                        Text(identifier).tag(String?.some(identifier))
                    }
                }

                LabeledContent("Current month boundaries") {
                    Text(monthBoundaryExample)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Example of how the chosen time zone resolves the current month, so the
    /// effect of the setting is visible immediately.
    private var monthBoundaryExample: String {
        let timeZone = appState.timeZone
        let month = appState.currentMonth
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = timeZone
        let start = month.start(in: timeZone).formatted(style)
        let end = month.end(in: timeZone).formatted(style)
        return "\(start) – \(end)"
    }
}
