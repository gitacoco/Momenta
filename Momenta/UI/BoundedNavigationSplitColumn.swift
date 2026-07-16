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

    /// Replaces the unconstrained native divider hit target with a bounded
    /// resize handle while leaving NavigationSplitView responsible for layout
    /// and rendering.
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
        nsView.renderedPosition = renderedPosition
        nsView.minimumWidth = minimumWidth
        nsView.maximumWidth = maximumWidth
        nsView.scheduleClamp()
    }

    final class HandleView: NSView {
        var renderedPosition: CGFloat = 0
        var minimumWidth: CGFloat = 0
        var maximumWidth: CGFloat = .infinity

        private var dragStartX: CGFloat?
        private var dragStartPosition: CGFloat?

        override var isOpaque: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                scheduleClamp()
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            dragStartX = event.locationInWindow.x
            dragStartPosition = primarySplitterPosition() ?? renderedPosition
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragStartX, let dragStartPosition else { return }
            let proposedPosition = dragStartPosition + event.locationInWindow.x - dragStartX
            setPrimarySplitterPosition(bounded(proposedPosition))
        }

        override func mouseUp(with event: NSEvent) {
            dragStartX = nil
            dragStartPosition = nil
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        func scheduleClamp(attemptsRemaining: Int = 40) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.clampCurrentPosition(), attemptsRemaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.scheduleClamp(attemptsRemaining: attemptsRemaining - 1)
                    }
                }
            }
        }

        @discardableResult
        private func clampCurrentPosition() -> Bool {
            guard let position = primarySplitterPosition() else { return false }
            let boundedPosition = bounded(position)
            if abs(position - boundedPosition) > 0.5 {
                setPrimarySplitterPosition(boundedPosition)
            }
            return true
        }

        private func bounded(_ position: CGFloat) -> CGFloat {
            min(max(position, minimumWidth), maximumWidth)
        }

        private func primarySplitterPosition() -> CGFloat? {
            guard let splitter = primarySplitter(),
                  let number = accessibilityValue(of: splitter) as? NSNumber else { return nil }
            return CGFloat(number.doubleValue)
        }

        private func setPrimarySplitterPosition(_ position: CGFloat) {
            guard let splitter = primarySplitter() else { return }
            setAccessibilityValue(NSNumber(value: Double(position)), on: splitter)
        }

        /// SwiftUI's macOS 26 split view vends virtual accessibility elements
        /// rather than an NSSplitView. Its first splitter is the primary one.
        private func primarySplitter() -> NSObject? {
            guard let window else { return nil }
            var visited = Set<ObjectIdentifier>()
            return firstSplitter(in: window, visited: &visited)
        }

        private func firstSplitter(
            in element: NSObject,
            visited: inout Set<ObjectIdentifier>
        ) -> NSObject? {
            let identifier = ObjectIdentifier(element)
            guard visited.insert(identifier).inserted else { return nil }

            if accessibilityRole(of: element) == .splitter {
                return element
            }

            for case let child as NSObject in accessibilityChildren(of: element) {
                if let splitter = firstSplitter(in: child, visited: &visited) {
                    return splitter
                }
            }
            return nil
        }

        private func accessibilityRole(of element: NSObject) -> NSAccessibility.Role? {
            let selector = NSSelectorFromString("accessibilityRole")
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue() as? NSAccessibility.Role
        }

        private func accessibilityChildren(of element: NSObject) -> [Any] {
            let selector = NSSelectorFromString("accessibilityChildren")
            guard element.responds(to: selector) else { return [] }
            return element.perform(selector)?.takeUnretainedValue() as? [Any] ?? []
        }

        private func accessibilityValue(of element: NSObject) -> Any? {
            let selector = NSSelectorFromString("accessibilityValue")
            guard element.responds(to: selector) else { return nil }
            return element.perform(selector)?.takeUnretainedValue()
        }

        private func setAccessibilityValue(_ value: Any, on element: NSObject) {
            let selector = NSSelectorFromString("setAccessibilityValue:")
            guard element.responds(to: selector) else { return }
            _ = element.perform(selector, with: value)
        }
    }
}
