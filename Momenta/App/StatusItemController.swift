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
    /// The hosting view that supplies the menu bar's pixels. Held so the width
    /// negotiation can be re-driven when an input changes it without SwiftUI
    /// noticing — see `invalidateLabelWidth()`.
    private weak var labelHosting: NSView?

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
            // The embedded hosting view supplies the pixels, but macOS exposes
            // the outer NSStatusBarButton to menu-bar keyboard navigation.
            // The resulting AXMenuBarItem only forwards AXTitle, AXHelp, and
            // AXPress from the button; AXLabel and AXValue are not exposed.
            // Keep the live progress summary in AXTitle so VoiceOver receives
            // both the app name and the information visible in the menu bar.
            let initialAccessibilityValue = MenuBarPresentation(
                aggregate: appState.menuBarAggregate,
                settings: appState.displaySettings,
                unit: appState.displayUnit
            ).accessibilityValue
            button.setAccessibilityElement(true)
            button.setAccessibilityRole(.button)
            button.setAccessibilityLabel("Momenta")
            button.setAccessibilityHelp("Open dashboard")
            button.setAccessibilityIdentifier("momenta.status-item")
            Self.updateStatusItemAccessibility(
                button,
                value: initialAccessibilityValue
            )
            button.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(
                    name: "Open dashboard",
                    target: self,
                    selector: #selector(openDashboardAccessibilityAction)
                )
            ])

            // SwiftUI renders the label so it live-updates with app state.
            let hosting = IntegralSizeHostingView(
                rootView: MenuBarLabelContainer(
                    accessibilityValueChanged: { [weak self, weak button] value in
                        guard let button else { return }
                        Self.updateStatusItemAccessibility(button, value: value)
                        // The value changes for the same reasons the label's
                        // width does, and rewriting the title re-measures the
                        // cell — which is what the snapshot surfaces are sized
                        // from. Re-publish the real width behind it.
                        self?.invalidateLabelWidth()
                    },
                    visualWidthChanged: { [weak self] in
                        self?.invalidateLabelWidth()
                    }
                )
                .environment(appState)
            )
            hosting.sizingOptions = [.intrinsicContentSize]
            // The hosted label is `.fixedSize(horizontal:)`, so SwiftUI lays it
            // out at its own ideal width and ignores whatever width the button
            // hands it. Nothing else on this path clips — `clipsToBounds`
            // defaults to false on macOS 14+ — so any disagreement between the
            // drawn ideal and the reserved slot escapes the item: it overdraws
            // the neighbouring menu-bar icons on the display that owns the real
            // status window, and is cropped away in the snapshot the other
            // display's menu bar mirrors. Clipping keeps a disagreement
            // contained and visible on both, rather than destructive on one.
            // A drawing property only: it cannot perturb the width negotiation.
            hosting.clipsToBounds = true
            hosting.setContentHuggingPriority(.required, for: .horizontal)
            hosting.setContentCompressionResistancePriority(.required, for: .horizontal)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                hosting.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                hosting.heightAnchor.constraint(lessThanOrEqualTo: button.heightAnchor),
                // The standard 22pt item height is only a priority-250 default
                // inside NSStatusBarWindow, and the sub-point accessibility
                // title leaves the button's own content hugging at that same
                // priority — a tie the solver may break either way once the
                // hosted label's constraints join in (17pt on a notched
                // MacBook Air, 22pt on a Mac mini). The system renders the
                // hover/selection capsule from the button's resolved bounds,
                // so the shrunken solution shows a squashed, pointy-capped
                // base beside standard items. A required floor at the standard
                // thickness breaks the tie deterministically.
                button.heightAnchor.constraint(
                    greaterThanOrEqualToConstant: NSStatusBar.system.thickness
                ),
            ])
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            labelHosting = hosting

            // Settle the width before the item is first shown. The menu bars on
            // the other displays mirror this item through snapshot surfaces the
            // system sizes when it first displays the item; they are not
            // re-derived afterwards. Letting SwiftUI measure a turn later means
            // those surfaces are built at the empty item's width and keep it,
            // and the stale size flashes on every migration between displays.
            button.layoutSubtreeIfNeeded()
            Self.syncCellSize(button, to: hosting)
        }

        #if DEBUG
        startWidthInstrumentation()
        #endif

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
        // The reserved slot is derived once from the hosted label's intrinsic
        // width and then never re-examined: there is no polling and no
        // reconciliation, so a width that changes without an invalidation stays
        // wrong silently. Display changes move the item between per-screen
        // status windows, which is exactly when a stale width becomes visible.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
    }

    /// Re-drives the width negotiation from scratch.
    ///
    /// Always deferred a turn. AppKit takes the other menu bars' snapshots by
    /// drawing this view inside its own redraw pass and warns that dirtying
    /// layout during drawing re-enters the measurement; hopping to the next
    /// runloop turn keeps the invalidation out of any display pass. It also
    /// preserves the non-feedback invariant that `IntegralSizeHostingView`'s
    /// comment depends on: nothing here reads an assigned frame.
    private func invalidateLabelWidth() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let hosting = self.labelHosting else { return }
            hosting.invalidateIntrinsicContentSize()
            // Settle the new width before handing it to the cell, so the two
            // sizing paths publish the same number in the same turn rather than
            // the snapshot surfaces trailing a frame behind.
            hosting.layoutSubtreeIfNeeded()
            if let button = self.statusItem.button {
                Self.syncCellSize(button, to: hosting)
            }
        }
    }

    @objc private func screenConfigurationChanged() {
        invalidateLabelWidth()
    }

    /// The status item pads whatever the cell measures by this much before
    /// sizing its snapshot surfaces. Measured, twice: a 9pt cell produced 25pt
    /// surfaces and a 162pt cell produced 178pt ones. Not a documented value —
    /// the instrumentation's mirror check is what catches it changing.
    private static let statusItemCellInset: CGFloat = 16

    /// Gives the button's cell the width the hosted label actually draws.
    ///
    /// The real status window sizes itself through Auto Layout, which sees the
    /// hosting subview. The snapshot surfaces the other displays' menu bars
    /// mirror are sized from the CELL, which sees only the transparent
    /// accessibility title — 9pt, plus the inset above, hence the 25pt crop
    /// that flashed across both bars whenever the item migrated between
    /// displays. A clear image is the one width both paths agree on.
    private static func syncCellSize(_ button: NSStatusBarButton, to hosting: NSView) {
        let width = ceil(hosting.intrinsicContentSize.width)
        guard width > 0 else { return }
        let size = NSSize(
            width: max(1, width - statusItemCellInset),
            height: NSStatusBar.system.thickness
        )
        // Also the loop breaker: setting the image re-enters sizing, and
        // bailing on an unchanged size is what stops it converging forever.
        if let image = button.image, image.size == size { return }
        // Drawn empty on purpose: the hosting view supplies every visible
        // pixel. This exists only so the cell measures the right width.
        let spacer = NSImage(size: size, flipped: false) { _ in true }
        spacer.isTemplate = true
        button.image = spacer
        // Overlapping, not `.imageOnly`: the transparent attributed title has
        // to keep being rendered for AppKit to expose it as the item's AXTitle,
        // and overlapping takes the wider of the two rather than their sum.
        button.imagePosition = .imageOverlaps
    }

    private static func statusItemAccessibilityTitle(value: String) -> String {
        "Momenta, \(value)"
    }

    private static func updateStatusItemAccessibility(
        _ button: NSStatusBarButton,
        value: String
    ) {
        let title = statusItemAccessibilityTitle(value: value)

        // AppKit derives AXTitle for a status extra from the button's rendered
        // title rather than its accessibilityTitle override. Supply the same
        // semantic text as a transparent, sub-point attributed title: it is
        // available to VoiceOver without competing with the NSHostingView that
        // owns the visible menu-bar pixels or widening the status item.
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 0.1),
                .foregroundColor: NSColor.clear,
            ]
        )
        button.setAccessibilityTitle(title)
        button.setAccessibilityValue(value)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    #if DEBUG
    // MARK: Width instrumentation

    /// Silent tripwire for the three invariants this status item's layout rests
    /// on, sampled fast enough to catch a transient.
    ///
    /// 1. The label must draw inside the width it reports, because that width
    ///    becomes the menu bar's reserved slot and nothing downstream clips it
    ///    back. Breaking it overdraws the neighbouring item on the display that
    ///    owns the real status window and is cropped away in the snapshot the
    ///    other display's menu bar mirrors — the two halves of one bug.
    /// 2. Every step of the negotiation must agree on one width. A slot left
    ///    behind by a content change never re-derives on its own.
    /// 3. Every status-bar window must be as wide as the item. The snapshot
    ///    surfaces the other displays mirror are sized from the cell, not
    ///    through Auto Layout, so they can disagree with a perfectly consistent
    ///    item — which is exactly how the multi-display crop hid from 1 and 2.
    ///
    /// Nothing is logged while all three hold, so a recurrence is the only
    /// thing that ever appears. The label animates over 0.28s with numeric-text
    /// transitions, so the interval has to be well inside that: a half-second
    /// poll samples the endpoints and can miss the whole excursion between.
    private var widthProbeTimer: Timer?
    private var lastWidthProbe: String = ""

    private func startWidthInstrumentation() {
        widthProbeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.logWidthProbe() }
        }
    }

    /// Union of every DESCENDANT layer's frame in `view`'s own coordinates.
    /// Views alone are not enough: the ring's stroke is drawn by a shape layer
    /// whose bounds already carry the half-line-width overshoot. The root layer
    /// is excluded on purpose — it is the hosting view's own bounds, so
    /// including it would define the overflow away.
    private static func drawnExtent(of view: NSView) -> (rect: CGRect, layers: Int) {
        guard let root = view.layer else { return (.null, 0) }
        var rect = CGRect.null
        var count = 0
        func walk(_ layer: CALayer) {
            for sublayer in layer.sublayers ?? [] {
                count += 1
                rect = rect.union(sublayer.convert(sublayer.bounds, to: root))
                walk(sublayer)
            }
        }
        walk(root)
        return (rect, count)
    }

    private func logWidthProbe() {
        guard let button = statusItem.button, let hosting = labelHosting else { return }
        let demanded = ceil(hosting.intrinsicContentSize.width)
        let (drawn, layers) = Self.drawnExtent(of: hosting)
        let overflows = !drawn.isNull
            && (drawn.minX < -0.01 || drawn.maxX > hosting.bounds.width + 0.01)
        // The window is the slot the menu bar actually reserved. `demanded` is
        // what the app asked for. A steady disagreement is a slot that never
        // re-derived; the negotiation defers by one pass, so a single
        // transitional frame of disagreement is normal and not worth a report.
        let reserved = button.window?.frame.width ?? demanded
        let stale = abs(reserved - demanded) > 0.01
        // Every status-bar-class window this process owns. One is the real item;
        // the rest carry the snapshot the other displays' menu bars mirror, and
        // they are sized from the CELL rather than through Auto Layout. That
        // second path is the one that broke: a cell measuring only the
        // transparent accessibility title produced 25pt surfaces beside a 162pt
        // item, and the crop flashed across both bars on every migration.
        let bars = NSApp.windows
            .filter { String(describing: type(of: $0)).contains("StatusBar") }
            // A zero dimension is a window the system has created but not yet
            // laid out; it reports a width no one is drawing through.
            .filter { $0.frame.width > 0 && $0.frame.height > 0 }
        let mirrors = bars.filter { abs($0.frame.width - reserved) > 0.01 }
        guard overflows || stale || !mirrors.isEmpty else { return }

        let line = """
        \(overflows ? "OVERFLOW " : "")\(stale ? "STALE " : "")\
        \(mirrors.isEmpty ? "" : "MIRROR ")\
        demanded=\(demanded) reservedWindow=\(reserved) \
        cell=\(button.cell?.cellSize.width ?? -1) image=\(button.image?.size.width ?? -1) \
        screen=\(button.window?.screen?.localizedName ?? "nil") \
        viz=\(appState.displaySettings.menuBarVisualization) layers=\(layers) \
        drawn=[\(drawn.minX), \(drawn.maxX)] bounds=\(hosting.bounds.width) \
        bars=[\(bars.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: " "))]
        """
        guard line != lastWidthProbe else { return }
        lastWidthProbe = line
        NSLog("MOMENTA_WIDTH %@", line)
    }
    #endif

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

    @objc private func openDashboardAccessibilityAction() -> Bool {
        togglePopover()
        return true
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            closeAnchorWindow()
            // The popover opens on the status item's screen, which is not
            // necessarily `NSScreen.main` (the keyboard-focused window's
            // screen, often another app's). Capture it for the height cap.
            appState.statusItemScreenVisibleHeight = button.window?.screen?.visibleFrame.height
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
            // Activation is asynchronous: `NSApp.isActive` stays false for the
            // rest of this turn, so claiming key here is a no-op and the
            // popover opens unfocused until the next click. Activate now and
            // take key on the following turn, which covers both cases — a
            // background app has activated by then (AppKit assigns key itself),
            // and an already-active app fires no activation event, so it needs
            // this explicit makeKey.
            //
            // The deprecated forced variant is deliberate: cooperative
            // `activate()` is refused for this LSUIElement app while another
            // app holds the front, leaving the popover keyboard-reachable but
            // rendering in its inactive (translucent) material.
            NSApp.activate(ignoringOtherApps: true)
            let shownWindow = popover.contentViewController?.view.window
            DispatchQueue.main.async { [weak self] in
                // The popover may have closed (or reopened elsewhere) within
                // the turn; only claim key for the presentation we started.
                guard let self, self.popover.isShown,
                      let window = self.popover.contentViewController?.view.window,
                      window == shownWindow else { return }
                window.makeKey()
            }
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
        // History browsing is scoped to a viewing session. The status item
        // stays pinned to now, so a reference left behind would be invisible
        // state: the next open would show a past period with nothing in the
        // menu bar to explain it. Closing ends the session.
        appState.resetReferenceToNow()
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

/// Reports the hosted label's ideal size rounded up to whole points. SwiftUI
/// happily measures text at fractional widths, but the status item's width is
/// pinned to this intrinsic size by required constraints while
/// NSStatusBarWindow integralizes its frame — a fractional width (164.5pt was
/// observed) leaves the layout engine re-deriving 164.5 against a 165pt
/// window forever, until AppKit's recursion guard aborts the app at launch.
/// Whole-point sizes keep both sides of that negotiation in agreement; the
/// sub-point of slack is invisible at menu bar scale.
private final class IntegralSizeHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if size.width.isFinite { size.width = ceil(size.width) }
        if size.height.isFinite { size.height = ceil(size.height) }
        // Fail here rather than at AppKit's recursion guard: a fractional width
        // demanded at required priority is the launch-abort described above,
        // and it aborts before any UI exists to say why.
        assert(
            !size.width.isFinite || size.width == size.width.rounded(.up),
            "Status item demanded a fractional width (\(size.width)); see the launch-abort note above."
        )
        return size
    }
}

/// Thin wrapper so the status item label participates in SwiftUI observation.
private struct MenuBarLabelContainer: View {
    @Environment(AppState.self) private var appState
    let accessibilityValueChanged: (String) -> Void
    /// Called for width-affecting changes that leave `accessibilityValue`
    /// untouched, so they still reach the status item's sizing.
    let visualWidthChanged: () -> Void

    private var accessibilityValue: String {
        MenuBarPresentation(
            aggregate: appState.menuBarAggregate,
            settings: appState.displaySettings,
            unit: appState.displayUnit
        ).accessibilityValue
    }

    var body: some View {
        // No local clock: the label re-renders when the shared displayNow (or
        // any snapshot) changes, so it can never disagree with the popover
        // about which day/week/month is current.
        MenuBarLabel(
            aggregate: appState.menuBarAggregate,
            settings: appState.displaySettings,
            unit: appState.displayUnit
        )
        // The selected status-item capsule paints its left cap about 1pt
        // inside the button's layout bounds. Compensate in ring mode so the
        // ring and the visible capsule cap remain concentric.
        .padding(.leading, appState.displaySettings.menuBarVisualization == .ring ? 1.5 : 5)
        .padding(.trailing, 5)
        .fixedSize(horizontal: true, vertical: false)
        .allowsHitTesting(false)
        .onAppear {
            accessibilityValueChanged(accessibilityValue)
        }
        .onChange(of: accessibilityValue) { _, newValue in
            accessibilityValueChanged(newValue)
        }
        // Switching ring/waterline moves both the glyph's own width and the
        // container's leading padding, but writes no new accessibility value —
        // so the attributedTitle rewrite that normally dirties the button's
        // sizing never happens and the reserved slot keeps the old width.
        .onChange(of: appState.displaySettings.menuBarVisualization) { _, _ in
            visualWidthChanged()
        }
    }
}
