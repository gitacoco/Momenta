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
        private var delegateProxy: LockedSplitViewDelegate?

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
                  let controller = splitView.delegate as? NSSplitViewController,
                  controller.splitViewItems.indices.contains(paneIndex) else { return }

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

            let dividerIndex = paneIndex
            let dividerPosition = splitView.subviews[paneIndex].frame.maxX
            guard dividerPosition > 0 else {
                scheduleConfiguration()
                return
            }

            if let delegateProxy {
                delegateProxy.lockedDividerIndex = dividerIndex
                if splitView.delegate !== delegateProxy {
                    delegateProxy.downstream = splitView.delegate
                    splitView.delegate = delegateProxy
                }
            } else {
                let proxy = LockedSplitViewDelegate(
                    downstream: splitView.delegate,
                    lockedDividerIndex: dividerIndex,
                    lockedPosition: dividerPosition,
                    lockedSubview: splitView.subviews[paneIndex]
                )
                delegateProxy = proxy
                splitView.delegate = proxy
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
    }

    /// Preserves SwiftUI's private split-view delegate behavior while
    /// overriding only the decisions that could move or collapse this pane.
    final class LockedSplitViewDelegate: NSObject, NSSplitViewDelegate {
        weak var downstream: (any NSSplitViewDelegate)?
        weak var lockedSubview: NSView?
        var lockedDividerIndex: Int
        let lockedPosition: CGFloat

        init(
            downstream: (any NSSplitViewDelegate)?,
            lockedDividerIndex: Int,
            lockedPosition: CGFloat,
            lockedSubview: NSView
        ) {
            self.downstream = downstream
            self.lockedDividerIndex = lockedDividerIndex
            self.lockedPosition = lockedPosition
            self.lockedSubview = lockedSubview
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            guard dividerIndex == lockedDividerIndex else {
                return downstream?.splitView?(
                    splitView,
                    constrainMinCoordinate: proposedMinimumPosition,
                    ofSubviewAt: dividerIndex
                ) ?? proposedMinimumPosition
            }
            return lockedPosition
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            guard dividerIndex == lockedDividerIndex else {
                return downstream?.splitView?(
                    splitView,
                    constrainMaxCoordinate: proposedMaximumPosition,
                    ofSubviewAt: dividerIndex
                ) ?? proposedMaximumPosition
            }
            return lockedPosition
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainSplitPosition proposedPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            guard dividerIndex == lockedDividerIndex else {
                return downstream?.splitView?(
                    splitView,
                    constrainSplitPosition: proposedPosition,
                    ofSubviewAt: dividerIndex
                ) ?? proposedPosition
            }
            return lockedPosition
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            guard subview !== lockedSubview else { return false }
            return downstream?.splitView?(splitView, canCollapseSubview: subview) ?? false
        }

        func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
            guard view !== lockedSubview else { return false }
            return downstream?.splitView?(splitView, shouldAdjustSizeOfSubview: view) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || downstream?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if downstream?.responds(to: selector) == true {
                return downstream
            }
            return super.forwardingTarget(for: selector)
        }
    }
}
