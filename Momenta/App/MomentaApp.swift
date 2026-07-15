import SwiftUI

@main
struct MomentaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(AppState.shared)
        }
        // Freely resizable above the content's minimum size.
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            statusItemController = StatusItemController(appState: AppState.shared)
        }
    }
}
