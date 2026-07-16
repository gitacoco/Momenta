import AppKit
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
                .background(SettingsWindowChrome())
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.automatic)
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: ["settings"])
    }
}

/// The automatic macOS 26 toolbar style still chooses a hard titlebar
/// separator for some scroll-edge states. An explicit window preference keeps
/// the floating toolbar treatment consistent across every settings page.
private struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowChromeView {
        WindowChromeView()
    }

    func updateNSView(_ nsView: WindowChromeView, context: Context) {
        nsView.applyWindowChrome()
    }

    final class WindowChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyWindowChrome()
        }

        func applyWindowChrome() {
            window?.titlebarSeparatorStyle = .none
        }
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
