import AppKit
import SwiftUI

/// Owns the menu bar presence: an NSStatusItem whose left click toggles the
/// dashboard popover and whose right click opens a context menu (Settings,
/// last query time, Refresh, Quit). MenuBarExtra can't do secondary-click
/// menus, so the status item is managed directly.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let appState: AppState
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var anchorWindow: NSWindow?
    private var dismissMonitors: [Any] = []

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        // Not `.transient`: the popover is anchored to our own always-front
        // anchor window (so it can't drift as the status item resizes), and that
        // arrangement defeats AppKit's built-in transient dismissal. We own
        // dismissal explicitly instead — see installDismissMonitors().
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willOpenSettings),
            name: .momentaWillOpenSettings,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
            closeAnchorWindow()
            // The status item lives in its own window that the system slides
            // sideways whenever the item resizes (as the menu-bar label tracks
            // the period). Anchoring to the button — or any view inside that
            // window — drags the popover along. Instead pin a separate, unmoving
            // anchor window at the item's open-time screen position and anchor
            // there, so the popover holds still while the item keeps updating.
            let target: NSView
            if let buttonWindow = button.window {
                let screenRect = buttonWindow.convertToScreen(
                    button.convert(button.bounds, to: nil)
                )
                let anchor = makeAnchorWindow(at: screenRect)
                anchorWindow = anchor
                target = anchor.contentView ?? button
            } else {
                target = button
            }
            popover.show(relativeTo: target.bounds, of: target, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate()
            installDismissMonitors()
        }
    }

    // MARK: Popover dismissal

    // The popover is `.applicationDefined`, so we close it ourselves: on a click
    // outside it, when the app deactivates, or on Escape. Clicks on the status
    // item are left to the toggle above (its action always fires), so a single
    // click closes cleanly without racing a reopen.
    private func installDismissMonitors() {
        removeDismissMonitors()

        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, self.popover.isShown else { return event }

            if event.type == .keyDown {
                if event.keyCode == 53 { // Escape
                    self.popover.performClose(nil)
                    return nil
                }
                return event
            }

            // Clicks inside the popover are interaction, not dismissal.
            if let eventWindow = event.window,
               eventWindow == self.popover.contentViewController?.view.window {
                return event
            }
            // The status item's own click is handled by the toggle; closing here
            // too would race the reopen.
            if event.window == self.statusItem.button?.window {
                return event
            }

            self.popover.performClose(nil)
            return event
        }

        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }

        dismissMonitors = [local, global].compactMap { $0 }
    }

    private func removeDismissMonitors() {
        for monitor in dismissMonitors {
            NSEvent.removeMonitor(monitor)
        }
        dismissMonitors.removeAll()
    }

    @objc private func appDidResignActive() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    @objc private func willOpenSettings() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    /// A borderless, transparent, click-through window parked at the status
    /// item's screen position. It never moves during the session, so the popover
    /// anchored to it stays put even as the real status item window slides.
    private func makeAnchorWindow(at screenRect: NSRect) -> NSWindow {
        let window = NSWindow(
            contentRect: screenRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = PopoverAnchorView(
            frame: NSRect(origin: .zero, size: screenRect.size)
        )
        window.orderFrontRegardless()
        return window
    }

    private func closeAnchorWindow() {
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
    }

    func popoverDidClose(_ notification: Notification) {
        removeDismissMonitors()
        closeAnchorWindow()
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

extension Notification.Name {
    /// Posted just before the Settings window is summoned, so the popover can
    /// dismiss itself (it is `.applicationDefined` and won't auto-close).
    static let momentaWillOpenSettings = Notification.Name("Momenta.willOpenSettings")
}

/// Summons the SwiftUI settings window scene from AppKit contexts (status
/// item menu, popover buttons) through the app's URL scheme — the supported
/// way to open a scene without a SwiftUI environment at hand.
@MainActor
func openSettingsWindow() {
    NotificationCenter.default.post(name: .momentaWillOpenSettings, object: nil)
    NSApp.activate()
    if let url = URL(string: "momenta://settings") {
        NSWorkspace.shared.open(url)
    }
}

/// The content view of the invisible anchor window. Purely a geometric anchor
/// for the popover; it never intercepts clicks so the status item underneath
/// and the popover's transient dismissal behave normally.
private final class PopoverAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
            settings: appState.displaySettings,
            unit: appState.displayUnit
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
