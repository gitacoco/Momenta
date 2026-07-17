import AppKit
import SwiftUI

private struct PrimarySidebarBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Records the full-width List rather than a fixed child, so the handle
    /// always tracks the real NavigationSplitView divider.
    func marksPrimarySidebarBounds() -> some View {
        anchorPreference(key: PrimarySidebarBoundsPreferenceKey.self, value: .bounds) { $0 }
    }

    /// Locks the primary sidebar boundary. NavigationSplitView never
    /// propagates `navigationSplitViewColumnWidth` into its underlying
    /// AppKit `NSSplitViewItem` (the item ships with min 140 / max
    /// unbounded), so the native divider — reachable through a hit-test
    /// pass-through band in the titlebar — can live-drag the sidebar to any
    /// width. This modifier pins the real split item and shields the
    /// titlebar band so no live drag can start anywhere on the boundary.
    func boundedPrimarySidebarResizeHandle(
        minimumWidth: CGFloat,
        maximumWidth: CGFloat
    ) -> some View {
        modifier(
            BoundedPrimarySidebarResizeModifier(
                minimumWidth: minimumWidth,
                maximumWidth: maximumWidth
            )
        )
    }
}

private struct BoundedPrimarySidebarResizeModifier: ViewModifier {
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat
    @State private var renderedPosition: CGFloat?

    func body(content: Content) -> some View {
        content
            // Resolve the anchor in a full-size layer that never participates
            // in hit testing. Its only output is the divider's x position.
            .overlayPreferenceValue(PrimarySidebarBoundsPreferenceKey.self) { anchor in
                GeometryReader { proxy in
                    if let anchor {
                        let position = proxy[anchor].maxX

                        Color.clear
                            .onAppear {
                                renderedPosition = position
                            }
                            .onChange(of: position) { _, newPosition in
                                renderedPosition = newPosition
                            }
                    }
                }
                .allowsHitTesting(false)
            }
            // Only this narrow strip can receive pointer events. The rest of
            // the split view remains available to forms, lists, and scrolling.
            .overlay(alignment: .topLeading) {
                if let renderedPosition {
                    PrimarySidebarResizeHandle(
                        renderedPosition: renderedPosition,
                        minimumWidth: minimumWidth,
                        maximumWidth: maximumWidth
                    )
                    .frame(width: 12)
                    .frame(maxHeight: .infinity)
                    .offset(x: renderedPosition - 6)
                    .accessibilityHidden(true)
                }
            }
    }
}

private struct PrimarySidebarResizeHandle: NSViewRepresentable {
    let renderedPosition: CGFloat
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat

    func makeNSView(context: Context) -> HandleView {
        HandleView()
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        nsView.minimumWidth = minimumWidth
        nsView.maximumWidth = maximumWidth
        nsView.enforceNow()
    }

    /// Covers the content-area portion of the divider (arrow cursor, no
    /// drag) and owns the AppKit-side enforcement for the whole window.
    final class HandleView: NSView {
        var minimumWidth: CGFloat = 0
        var maximumWidth: CGFloat = .infinity

        private var windowObserver: NSObjectProtocol?
        private weak var observedWindow: NSWindow?
        private weak var cachedSplitView: NSSplitView?
        private weak var cachedController: NSSplitViewController?
        private var titlebarGuard: TitlebarDividerGuardView?

        override var isOpaque: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        // The boundary is fixed: swallow the full click-drag sequence so it
        // can neither reach the native divider nor fall through to content.
        override func mouseDown(with event: NSEvent) {}
        override func mouseDragged(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .arrow)
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                teardown()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            teardown()
            observedWindow = window
            // Fires once per event-loop pass in which the window updates.
            // Every check in enforceNow is a compare-before-write, so steady
            // state costs a few loads and no AppKit mutations. This is what
            // keeps the lock alive when SwiftUI rebuilds toolbar/navigation
            // state, without timers or delayed clamps.
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.enforceNow()
            }
            enforceNow()
        }

        private func teardown() {
            if let windowObserver {
                NotificationCenter.default.removeObserver(windowObserver)
            }
            windowObserver = nil
            titlebarGuard?.removeFromSuperview()
            titlebarGuard = nil
            cachedSplitView = nil
            cachedController = nil
            observedWindow = nil
        }

        func enforceNow() {
            guard let window = observedWindow ?? self.window else { return }

            // The intermittent hairline under the toolbar is the automatic
            // per-section titlebar separator of the detail split section.
            // An explicit window-level style overrides every per-item
            // preference (documented), and reasserting here survives any
            // later reset by toolbar/navigation updates.
            if window.titlebarSeparatorStyle != .none {
                window.titlebarSeparatorStyle = .none
            }

            if cachedSplitView?.window !== window {
                cachedSplitView = primarySplitView(in: window)
                cachedController = cachedSplitView.flatMap(splitViewController(for:))
            }
            guard let splitView = cachedSplitView,
                  let controller = cachedController else { return }

            pinSidebarItem(of: controller)
            updateTitlebarGuard(in: splitView)
        }

        /// NavigationSplitView is backed by a real vertical NSSplitView whose
        /// delegate is SwiftUI's NSSplitViewController subclass.
        private func primarySplitView(in window: NSWindow) -> NSSplitView? {
            guard let contentView = window.contentView else { return nil }
            var stack: [NSView] = [contentView]
            while let view = stack.popLast() {
                if let splitView = view as? NSSplitView, splitView.isVertical {
                    return splitView
                }
                stack.append(contentsOf: view.subviews)
            }
            return nil
        }

        private func splitViewController(for splitView: NSSplitView) -> NSSplitViewController? {
            if let controller = splitView.delegate as? NSSplitViewController {
                return controller
            }

            var responder: NSResponder? = splitView
            while let current = responder {
                if let controller = current as? NSSplitViewController {
                    return controller
                }
                responder = current.nextResponder
            }
            return nil
        }

        /// NSSplitViewItem thickness measures the SwiftUI content width (the
        /// wrapper pane adds its own fixed gutter on top), so the pin uses
        /// the same 180pt the SwiftUI layer renders. With min == max the
        /// divider's constrain callbacks clamp every proposed drag position
        /// to the current one: zero live movement, nothing to snap back.
        private func pinSidebarItem(of controller: NSSplitViewController) {
            guard let item = controller.splitViewItems.first else { return }

            if item.canCollapse {
                item.canCollapse = false
            }
            if item.canCollapseFromWindowResize {
                item.canCollapseFromWindowResize = false
            }
            if item.minimumThickness != minimumWidth {
                item.minimumThickness = minimumWidth
            }
            if item.maximumThickness != maximumWidth {
                item.maximumThickness = maximumWidth
            }
            if item.automaticMaximumThickness != maximumWidth {
                item.automaticMaximumThickness = maximumWidth
            }
            if item.isCollapsed {
                item.isCollapsed = false
            }
        }

        /// The titlebar declines hits in a narrow band around the divider so
        /// the split view can track drags that start in the titlebar. This
        /// guard sits above the split view's panes inside that band, shows
        /// the arrow cursor, and swallows the click before NSSplitView's
        /// divider tracking can begin.
        private func updateTitlebarGuard(in splitView: NSSplitView) {
            guard let window = splitView.window else { return }

            let guardView: TitlebarDividerGuardView
            if let existing = titlebarGuard, existing.superview === splitView {
                guardView = existing
            } else {
                titlebarGuard?.removeFromSuperview()
                guardView = TitlebarDividerGuardView()
                splitView.addSubview(guardView, positioned: .above, relativeTo: nil)
                titlebarGuard = guardView
            }

            if splitView.subviews.last !== guardView {
                splitView.addSubview(guardView, positioned: .above, relativeTo: nil)
            }

            let titlebarHeight = window.frame.height - window.contentLayoutRect.height
            let dividerX = splitView.arrangedSubviews.first?.frame.maxX ?? minimumWidth
            let guardFrame = NSRect(
                x: dividerX - 6,
                y: 0,
                width: 12 + splitView.dividerThickness,
                height: max(titlebarHeight, 0)
            )
            if guardView.frame != guardFrame {
                guardView.frame = guardFrame
            }
        }
    }
}

/// Transparent shield over the titlebar segment of the sidebar boundary.
private final class TitlebarDividerGuardView: NSView {
    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // hitTest receives the point in the superview's coordinate space.
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.cursorUpdate, .activeAlways],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}
