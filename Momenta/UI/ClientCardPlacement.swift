import SwiftUI

/// Moves a whole card when the displayed client order changes, while the
/// capsule and chart keep control of their own period animations.
struct ClientCardPlacement: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var order: [Int]

    func body(content: Content) -> some View {
        content
            // Clear only the order-change transaction inside the card;
            // later chart and capsule transactions must pass through.
            .transaction(value: order) { $0.animation = nil }
            .geometryGroup()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.48), value: order)
    }
}
