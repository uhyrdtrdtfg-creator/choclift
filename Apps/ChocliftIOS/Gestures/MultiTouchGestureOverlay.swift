import ChocliftCore
import SwiftUI
import UIKit

@MainActor
public enum CompanionHaptics {
    public static func tap(enabled: Bool, style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        guard enabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }

    public static func notify(enabled: Bool, type: UINotificationFeedbackGenerator.FeedbackType = .success) {
        guard enabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }
}

/// Transparent multi-touch gesture recognizer view that lets 1-finger SwiftUI interactions
/// pass through unimpeded while capturing 2-finger and 3-finger swipes, taps, and pinches.
public struct MultiTouchGestureCaptureView: UIViewRepresentable {
    public typealias Coordinator = CompanionMultiTouchCoordinator

    public var isEnabled: Bool
    public var onGestureTriggered: (TouchGestureType) -> Void

    public init(
        isEnabled: Bool,
        onGestureTriggered: @escaping (TouchGestureType) -> Void
    ) {
        self.isEnabled = isEnabled
        self.onGestureTriggered = onGestureTriggered
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onGestureTriggered: onGestureTriggered)
    }

    public func makeUIView(context: Context) -> PassThroughMultiTouchUIView {
        let view = PassThroughMultiTouchUIView()
        context.coordinator.overlayView = view
        view.installManagedRecognizers(context.coordinator.makeConfiguredRecognizers())
        view.setOverlayEnabled(isEnabled)
        return view
    }

    public func updateUIView(_ uiView: PassThroughMultiTouchUIView, context: Context) {
        context.coordinator.overlayView = uiView
        context.coordinator.onGestureTriggered = onGestureTriggered
        uiView.setOverlayEnabled(isEnabled)
    }

    public final class PassThroughMultiTouchUIView: CompanionPassThroughMultiTouchView {
        public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // Single-finger interactions (< 2 active touches) return nil so SwiftUI buttons,
            // TabViews, and ScrollViews underneath receive normal taps and drags unimpeded.
            super.hitTest(point, with: event)
        }
    }
}
