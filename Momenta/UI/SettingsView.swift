import SwiftUI

/// Single Settings window (Cmd+,) with an always-visible Account / Clients /
/// Display sidebar. Plain fixed layout — settings never collapse the sidebar,
/// so no NavigationSplitView toolbar or toggle button.
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
    @State private var selection: Section = .account

    var body: some View {
        HStack(spacing: 0) {
            List(Section.allCases, selection: $selection) { section in
                Label(section.label, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)
            .frame(width: 170)

            Divider()

            Group {
                switch selection {
                case .account:
                    AccountSettingsView()
                case .clients:
                    ClientsSettingsView()
                case .display:
                    displaySettings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 440)
        .onAppear(perform: consumeDestination)
        .onChange(of: appState.pendingSettingsDestination) {
            consumeDestination()
        }
    }

    /// Routes deep links from the popover. The clients destination is left
    /// pending so ClientsSettingsView can also pick up the client selection.
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

    private var displaySettings: some View {
        @Bindable var appState = appState
        return Form {
            Picker("Menu bar aggregation", selection: $appState.displaySettings.aggregationPeriod) {
                ForEach(AggregationPeriod.allCases) { period in
                    Text(period.label).tag(period)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Split per client", isOn: $appState.displaySettings.perClientSplit)

            LabeledContent("Menu bar preview") {
                MenuBarLabel(
                    aggregate: appState.menuBarAggregate,
                    split: appState.displaySettings.perClientSplit
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            }

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
