import AppKit
import SwiftUI

/// Applies the invariant that SwiftUI's `NavigationSplitView` cannot express:
/// a column whose divider is neither draggable nor collapsible.
struct LockedNavigationSplitColumn: NSViewRepresentable {
    var width: CGFloat

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(width: width)
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.width = width
        nsView.scheduleConfiguration()
    }

    final class ProbeView: NSView {
        var width: CGFloat

        init(width: CGFloat) {
            self.width = width
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleConfiguration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleConfiguration()
        }

        override func layout() {
            super.layout()
            configureSplitViewItem()
        }

        func scheduleConfiguration() {
            DispatchQueue.main.async { [weak self] in
                self?.configureSplitViewItem()
            }
        }

        private func configureSplitViewItem() {
            guard let (splitView, paneIndex) = containingSplitViewPane(),
                  let controller = containingSplitViewController(for: splitView),
                  controller.splitViewItems.indices.contains(paneIndex) else { return }

            // A split view owned by NSSplitViewController rejects delegate
            // replacement. Lock its supported item constraints instead.
            let item = controller.splitViewItems[paneIndex]
            item.canCollapse = false
            item.canCollapseFromWindowResize = false
            item.minimumThickness = width
            item.maximumThickness = width
            item.automaticMaximumThickness = width
            item.holdingPriority = .required

            if item.isCollapsed {
                item.isCollapsed = false
            }
        }

        private func containingSplitViewPane() -> (NSSplitView, Int)? {
            var pane: NSView = self

            while let parent = pane.superview {
                if let splitView = parent as? NSSplitView,
                   let index = splitView.subviews.firstIndex(where: { $0 === pane }) {
                    return (splitView, index)
                }
                pane = parent
            }

            return nil
        }

        private func containingSplitViewController(for splitView: NSSplitView) -> NSSplitViewController? {
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
    }
}
