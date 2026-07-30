import SwiftUI

/// Every width the settings window's layout is built from, in one place.
///
/// The window's minimum is *derived* from these rather than written down
/// beside them: the two used to be independent numbers that had to agree by
/// hand, and when the grouped form's insets grew the page quietly outgrew its
/// pane and overflowed across the selector and the window edge. Adjusting any
/// single measurement here now moves the window's minimum with it.
enum SettingsMetrics {
    static let primarySidebar: CGFloat = 180
    /// The sidebar pane reserves a fixed gutter beside its list before the
    /// split view's divider.
    static let primarySidebarGutter: CGFloat = 8
    static let clientSelector: CGFloat = 240
    static let selectorLeadingInset: CGFloat = 20
    static let selectorTrailingInset: CGFloat = 16
    /// The narrowest the client editor may be asked to render. Its widest row
    /// is the three pacing cards at their compressed floor plus the grouped
    /// form's own insets; the remainder is slack, so a row that grows a little
    /// no longer pushes the page out of its pane.
    static let clientEditorMinimum: CGFloat = 420

    static var windowMinimumWidth: CGFloat {
        primarySidebar
            + primarySidebarGutter
            + selectorLeadingInset
            + clientSelector
            + selectorTrailingInset
            + clientEditorMinimum
    }

    static let windowMinimumHeight: CGFloat = 560
}

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
    @FocusState private var clientDetailFocus: ClientField?

    private let primarySidebarWidth = SettingsMetrics.primarySidebar
    private let clientSelectorWidth = SettingsMetrics.clientSelector

    private var currentSection: Section {
        selection ?? .account
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            primarySidebar
        } detail: {
            pageHost
        }
        // One minimum for every destination, so navigating never renegotiates
        // the window's own layout contract. Clients is the widest page, so it
        // sets the figure; the others simply have room to spare.
        .frame(
            minWidth: SettingsMetrics.windowMinimumWidth,
            maxWidth: .infinity,
            minHeight: SettingsMetrics.windowMinimumHeight,
            maxHeight: .infinity
        )
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
            ClientSelectorView(
                selectedClientID: $selectedClientID,
                onMoveFocusToDetail: { clientID in
                    selectedClientID = clientID
                    clientDetailFocus = .displayName
                }
            )
                .frame(width: clientSelectorWidth)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.65))
                }
                .padding(.leading, SettingsMetrics.selectorLeadingInset)
                .padding(.vertical, 16)
                .padding(.trailing, SettingsMetrics.selectorTrailingInset)

            // The window minimum is this figure plus everything to its left,
            // so the editor is guaranteed its share and never has to overflow
            // the pane to lay itself out.
            ClientDetailColumn(
                selectedClientID: selectedClientID,
                focusedField: $clientDetailFocus
            )
                .frame(
                    minWidth: SettingsMetrics.clientEditorMinimum,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
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
                    // Reads the shared displayNow clock via observation — the
                    // preview and the real status item can never disagree.
                    MenuBarLabel(
                        aggregate: appState.menuBarAggregate,
                        settings: appState.displaySettings,
                        unit: appState.displayUnit
                    )
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
                Picker("Refresh data", selection: $appState.displaySettings.refreshMode) {
                    ForEach(RefreshMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                if appState.displaySettings.refreshMode == .interval {
                    LabeledContent("Refresh every") {
                        HStack(spacing: 6) {
                            TextField(
                                "",
                                value: refreshIntervalBinding,
                                format: .number
                            )
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 52)
                            Text("minutes")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text("Toggl's free plan allows 30 API requests per hour. Manual mode spends them only when you ask; interval mode uses the schedule above instead of refreshing when the popover opens (5–240 minutes).")
                    .font(.subheadline)
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

    /// Free text can hold any number, so clamp writes into the supported
    /// range instead of trusting whatever the user typed.
    private var refreshIntervalBinding: Binding<Int> {
        Binding(
            get: { appState.displaySettings.refreshIntervalMinutes },
            set: { newValue in
                let range = DisplaySettings.refreshIntervalRange
                appState.displaySettings.refreshIntervalMinutes =
                    min(max(newValue, range.lowerBound), range.upperBound)
            }
        )
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
