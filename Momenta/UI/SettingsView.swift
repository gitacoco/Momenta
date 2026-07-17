import SwiftUI

/// Single Settings window (Cmd+,) with one persistent Account / Clients /
/// Display sidebar. Every destination replaces only the detail page so the
/// native split view and the user's chosen sidebar width remain stable.
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
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private let primarySidebarWidth: CGFloat = 180
    private let clientSelectorWidth: CGFloat = 240

    private var currentSection: Section {
        selection ?? .account
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            primarySidebar
        } detail: {
            pageHost
        }
        // The fixed client selector and client editor both fit at this stable
        // minimum, so changing destinations never changes the window's own
        // layout contract.
        .frame(minWidth: 940, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
        .boundedPrimarySidebarResizeHandle(
            minimumWidth: primarySidebarWidth,
            maximumWidth: primarySidebarWidth
        )
        .onChange(of: columnVisibility) { _, newVisibility in
            if newVisibility != .all {
                columnVisibility = .all
            }
        }
        // Paint the sidebar and selector backgrounds into the rounded bottom
        // edge instead of exposing the white window backing.
        .ignoresSafeArea(.container, edges: .bottom)
        .onAppear(perform: consumeDestination)
        .onChange(of: selection, recordNavigation)
        .onChange(of: appState.pendingSettingsDestination) {
            consumeDestination()
        }
    }

    private var pageHost: some View {
        Group {
            switch currentSection {
            case .account:
                AccountSettingsView()
            case .clients:
                clientsWorkspace
            case .display:
                displaySettings
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(currentSection.label)
        .toolbar { navigatorToolbar }
        .scrollEdgeEffectHidden(true, for: .top)
    }

    /// Clients is a normal settings page. Its fixed-width selector belongs to
    /// this page rather than becoming another navigation split column, so it
    /// cannot resize, collapse, or disturb the persistent primary sidebar.
    private var clientsWorkspace: some View {
        HStack(spacing: 0) {
            ClientSelectorView(selectedClientID: $selectedClientID)
                .frame(width: clientSelectorWidth)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.65))
                }
                .padding(.leading, 20)
                .padding(.vertical, 16)
                .padding(.trailing, 16)

            // 476 = 940 window minimum - 188 sidebar pane - 276 selector block
            // (20 leading + 240 card + 16 trailing). One point more and the
            // page's minimums exceed the window minimum, which makes SwiftUI
            // overflow the whole split container 2 pt past each window edge —
            // visibly shifting the sidebar and toolbar left on navigation.
            ClientDetailColumn(selectedClientID: selectedClientID)
                .frame(minWidth: 476, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var primarySidebar: some View {
        List(Section.allCases, selection: $selection) { section in
            Label(section.label, systemImage: section.icon)
                .tag(section)
        }
        .listStyle(.sidebar)
        .scrollDisabled(true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationSplitViewColumnWidth(
            min: primarySidebarWidth,
            ideal: primarySidebarWidth,
            max: primarySidebarWidth
        )
        .marksPrimarySidebarBounds()
        // Settings sidebars never collapse or expose a sidebar toggle.
        .toolbar(removing: .sidebarToggle)
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
    /// pending so ClientSelectorView can also pick up the client selection.
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
                    // Leading equals the vertical padding so the overall
                    // ring stays concentric with the capsule's left cap.
                    .padding(.leading, appState.displaySettings.menuBarVisualization == .ring ? 9 : 18)
                    .padding(.trailing, 18)
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

                Toggle(
                    "Show percentage next to Overall",
                    isOn: $appState.displaySettings.showsOverallPercentage
                )
                .disabled(appState.displaySettings.menuBarObjectMode == .split)
            }

            SwiftUI.Section("Data behavior") {
                Picker("Refresh data", selection: $appState.displaySettings.autoRefreshOnOpen) {
                    Text("When the popover opens").tag(true)
                    Text("Manually only").tag(false)
                }

                Text("Toggl's free plan allows 30 API requests per hour. Manual mode spends them only when you ask.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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
