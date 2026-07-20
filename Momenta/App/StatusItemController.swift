import AppKit
import SwiftUI

/// Owns the menu bar presence: an NSStatusItem whose left click toggles the
/// dashboard popover and whose right click opens a context menu (Settings,
/// last query time, Refresh, Quit). MenuBarExtra can't do secondary-click
/// menus, so the status item is managed directly.
@MainActor
final class StatusItemController: NSObject {
    private let appState: AppState
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.animates = false
        let hostingController = NSHostingController(
            rootView: DashboardView().environment(appState)
        )
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController

        if let button = statusItem.button {
            // SwiftUI renders the label so it live-updates with app state.
            let hosting = NSHostingView(
                rootView: MenuBarLabelContainer().environment(appState)
            )
            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.setContentHuggingPriority(.required, for: .horizontal)
            hosting.setContentCompressionResistancePriority(.required, for: .horizontal)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                hosting.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                hosting.heightAnchor.constraint(lessThanOrEqualTo: button.heightAnchor),
            ])
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    // MARK: Interactions

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else {
            // Accessibility's AXPress action has no backing NSEvent and is
            // equivalent to the status item's primary click.
            togglePopover()
            return
        }
        if event.type == .rightMouseUp {
            showContextMenu(with: event)
        } else if event.type == .leftMouseUp {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
        }
    }

    private func showContextMenu(with event: NSEvent) {
        let menu = NSMenu()

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(progressMenuItem())
        menu.addItem(periodMenuItem())
        menu.addItem(indicatorStyleMenuItem())

        menu.addItem(.separator())

        let lastSync = NSMenuItem(title: lastSyncTitle, action: nil, keyEquivalent: "")
        lastSync.isEnabled = false
        menu.addItem(lastSync)

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshAction), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Momenta", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        guard let button = statusItem.button else { return }
        // Begin menu tracking only after the user's secondary click has ended.
        // Calling performClick here would synthesize another click and can end
        // the new tracking session; opening the context menu directly avoids
        // both that race and a late mouse-up closing an expanded submenu.
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    private func progressMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Progress", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Progress")

        for mode in MenuBarObjectMode.allCases {
            let item = NSMenuItem(
                title: mode.label,
                action: #selector(selectProgressMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = appState.displaySettings.menuBarObjectMode == mode ? .on : .off
            submenu.addItem(item)
        }

        parent.submenu = submenu
        return parent
    }

    private func periodMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Period", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Period")

        for period in AggregationPeriod.allCases {
            let item = NSMenuItem(
                title: period.label,
                action: #selector(selectPeriod(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = period.rawValue
            item.state = appState.displaySettings.aggregationPeriod == period ? .on : .off
            submenu.addItem(item)
        }

        parent.submenu = submenu
        return parent
    }

    private func indicatorStyleMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Indicator Style", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Indicator Style")

        for visualization in MenuBarVisualization.allCases {
            let item = NSMenuItem(
                title: visualization.label,
                action: #selector(selectIndicatorStyle(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = visualization.rawValue
            item.state = appState.displaySettings.menuBarVisualization == visualization ? .on : .off
            submenu.addItem(item)
        }

        parent.submenu = submenu
        return parent
    }

    private var lastSyncTitle: String {
        if let at = appState.account.lastSyncAt {
            return "Last query at \(at.formatted(date: .omitted, time: .shortened))"
        }
        return "No queries yet"
    }

    @objc private func openSettingsAction() {
        openSettingsWindow()
    }

    @objc private func selectProgressMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = MenuBarObjectMode(rawValue: rawValue) else { return }
        appState.displaySettings.menuBarObjectMode = mode
    }

    @objc private func selectPeriod(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let period = AggregationPeriod(rawValue: rawValue) else { return }
        appState.displaySettings.aggregationPeriod = period
    }

    @objc private func selectIndicatorStyle(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let visualization = MenuBarVisualization(rawValue: rawValue) else { return }
        appState.displaySettings.menuBarVisualization = visualization
    }

    @objc private func refreshAction() {
        Task {
            await appState.refresh(force: true)
        }
    }
}

/// Summons the SwiftUI settings window scene from AppKit contexts (status
/// item menu, popover buttons) through the app's URL scheme — the supported
/// way to open a scene without a SwiftUI environment at hand.
@MainActor
func openSettingsWindow() {
    NSApp.activate()
    if let url = URL(string: "momenta://settings") {
        NSWorkspace.shared.open(url)
    }
}

/// Thin wrapper so the status item label participates in SwiftUI observation.
private struct MenuBarLabelContainer: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // No local clock: the label re-renders when the shared displayNow (or
        // any snapshot) changes, so it can never disagree with the popover
        // about which day/week/month is current.
        MenuBarLabel(
            aggregate: appState.menuBarAggregate,
            settings: appState.displaySettings
        )
        // Ring mode: 2.5pt leading leaves the ring's 19pt visual circle the
        // same 1.5pt gap on the left as above and below inside the system's
        // 22pt menu bar capsule, keeping ring and capsule cap concentric.
        .padding(.leading, appState.displaySettings.menuBarVisualization == .ring ? 2.5 : 5)
        .padding(.trailing, 5)
        .fixedSize(horizontal: true, vertical: false)
        .allowsHitTesting(false)
    }
}
