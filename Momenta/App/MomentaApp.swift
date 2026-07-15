import SwiftUI

@main
struct MomentaApp: App {
    @State private var appState = AppState(provider: MockDataProvider())

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environment(appState)
        } label: {
            MenuBarLabel(
                aggregate: appState.menuBarAggregate,
                split: appState.displaySettings.perClientSplit
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
        }
        // Freely resizable above the content's minimum size.
        .windowResizability(.contentMinSize)
    }
}
