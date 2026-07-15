import SwiftUI

/// Single Settings window (Cmd+,) with the Account / Clients / Display
/// primary sidebar. Account and Clients arrive with BON-12/13; Display is
/// already live so the menu bar modes can be exercised against mock data.
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
    @State private var selection: Section = .display

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.label, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            switch selection {
            case .account:
                placeholder(
                    icon: "person.crop.circle",
                    title: "Toggl Account",
                    message: "Token entry, validation, and connection status arrive with BON-12."
                )
            case .clients:
                placeholder(
                    icon: "person.2",
                    title: "Clients",
                    message: "The Toggl client list, enable switches, and the goal editor arrive with BON-13."
                )
            case .display:
                displaySettings
            }
        }
        .frame(minWidth: 560, minHeight: 380)
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

            LabeledContent("Time zone") {
                Text("System (\(TimeZone.current.identifier)) — picker arrives with BON-13")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func placeholder(icon: String, title: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(message)
        }
    }
}
