import SwiftUI

@main
struct MomentaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A real SwiftUI window scene so the settings window gets the full
        // native treatment (glass toolbar, sheets, resize constraints). It is
        // summoned via the momenta://settings URL from AppKit contexts and
        // never opens on its own at launch.
        Window("Momenta Settings", id: "settings") {
            SettingsView()
                .environment(AppState.shared)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.automatic)
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: ["settings"])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            statusItemController = StatusItemController(appState: AppState.shared)
        }
    }

    /// Momenta is a menu bar app, so closing (or recreating) its only regular
    /// window must not terminate the process that owns the status item.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
