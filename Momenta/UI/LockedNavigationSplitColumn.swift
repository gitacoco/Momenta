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
        private weak var observedSplitView: NSSplitView?
        private weak var observedPane: NSView?
        private var observedPaneIndex: Int?
        private var isEnforcingWidth = false

        init(width: CGFloat) {
            self.width = width
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleConfiguration()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stopObservingPane()
            } else {
                scheduleConfiguration()
            }
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
            guard let (splitView, paneIndex) = containingSplitViewPane() else {
                stopObservingPane()
                return
            }

            if let controller = containingSplitViewController(for: splitView),
               controller.splitViewItems.indices.contains(paneIndex) {
                // A split view owned by NSSplitViewController rejects delegate
                // replacement. Keep its supported item constraints in sync.
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

            let pane = splitView.subviews[paneIndex]
            observePane(pane, in: splitView, at: paneIndex)
            enforceWidth(of: pane, in: splitView, at: paneIndex)
        }

        private func observePane(_ pane: NSView, in splitView: NSSplitView, at paneIndex: Int) {
            guard observedSplitView !== splitView
                    || observedPane !== pane
                    || observedPaneIndex != paneIndex else { return }

            stopObservingPane()
            observedSplitView = splitView
            observedPane = pane
            observedPaneIndex = paneIndex
            pane.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(observedPaneFrameDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: pane
            )
        }

        private func stopObservingPane() {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: observedPane
            )
            observedSplitView = nil
            observedPane = nil
            observedPaneIndex = nil
        }

        @objc private func observedPaneFrameDidChange(_ notification: Notification) {
            guard let splitView = observedSplitView,
                  let pane = observedPane,
                  let paneIndex = observedPaneIndex else { return }
            enforceWidth(of: pane, in: splitView, at: paneIndex)
        }

        private func enforceWidth(of pane: NSView, in splitView: NSSplitView, at paneIndex: Int) {
            guard splitView.isVertical,
                  paneIndex < splitView.subviews.count - 1,
                  abs(pane.frame.width - width) > 0.5,
                  !isEnforcingWidth else { return }

            isEnforcingWidth = true
            defer { isEnforcingWidth = false }
            splitView.setPosition(pane.frame.minX + width, ofDividerAt: paneIndex)
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
