import AppKit
import SwiftUI

private struct PrimarySidebarBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct DetailColumnBoundsKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Records the primary sidebar's rendered trailing edge, so the divider
    /// position follows NavigationSplitView instead of a window coordinate.
    func marksPrimarySidebarBounds() -> some View {
        anchorPreference(key: PrimarySidebarBoundsKey.self, value: .bounds) { $0 }
    }

    func marksDetailColumnBounds() -> some View {
        anchorPreference(key: DetailColumnBoundsKey.self, value: .bounds) { $0 }
    }

    /// Keeps SwiftUI's native NavigationSplitView intact and only removes
    /// pointer interaction from the first divider.
    func blocksPrimarySidebarDivider() -> some View {
        overlayPreferenceValue(PrimarySidebarBoundsKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let sidebarBounds = proxy[anchor]

                    PrimaryDividerMouseBlocker()
                        .frame(width: 12, height: proxy.size.height)
                        .position(x: sidebarBounds.maxX, y: proxy.size.height / 2)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// Draws the existing detail title in the native titlebar section after
    /// the divider overlay establishes a root compositing boundary.
    func addsDetailTitlebar<Titlebar: View>(
        @ViewBuilder titlebar: @escaping () -> Titlebar
    ) -> some View {
        overlayPreferenceValue(DetailColumnBoundsKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let detailBounds = proxy[anchor]

                    titlebar()
                        .frame(width: detailBounds.width, height: 52)
                        .position(x: detailBounds.midX, y: detailBounds.minY - 26)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private struct PrimaryDividerMouseBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> BlockerView {
        BlockerView()
    }

    func updateNSView(_ nsView: BlockerView, context: Context) {}

    final class BlockerView: NSView {
        override var isOpaque: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {}
        override func mouseDragged(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}
