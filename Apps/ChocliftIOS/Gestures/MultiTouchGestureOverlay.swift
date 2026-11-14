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

/// Scoped multi-touch gesture surface mounted exclusively inside the dedicated Gesture Pad card
/// (never as a full-screen overlay), so control-strip and toolbar buttons always receive direct 1-finger taps.
public struct MultiTouchGestureCaptureView: UIViewRepresentable {
    public var isEnabled: Bool
    public var onGestureTriggered: (TouchGestureType) -> Void

    public init(
        isEnabled: Bool,
        onGestureTriggered: @escaping (TouchGestureType) -> Void
    ) {
        self.isEnabled = isEnabled
        self.onGestureTriggered = onGestureTriggered
    }

    public func makeCoordinator() -> ScopedPadCoordinator {
        ScopedPadCoordinator(onGestureTriggered: onGestureTriggered)
    }

    public func makeUIView(context: Context) -> ScopedMultiTouchPadUIView {
        let view = ScopedMultiTouchPadUIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isUserInteractionEnabled = isEnabled
        context.coordinator.padView = view
        for recognizer in context.coordinator.makeRecognizers() {
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    public func updateUIView(_ uiView: ScopedMultiTouchPadUIView, context: Context) {
        context.coordinator.padView = uiView
        context.coordinator.updateHandler(onGestureTriggered)
        uiView.isUserInteractionEnabled = isEnabled
    }

    public final class ScopedMultiTouchPadUIView: UIView {}

    @MainActor
    public final class ScopedPadCoordinator: NSObject, UIGestureRecognizerDelegate {
        public weak var padView: ScopedMultiTouchPadUIView?
        private let processor: CompanionMultiTouchCoordinator

        public init(onGestureTriggered: @escaping (TouchGestureType) -> Void) {
            self.processor = CompanionMultiTouchCoordinator(onGestureTriggered: onGestureTriggered)
            super.init()
        }

        public func updateHandler(_ handler: @escaping (TouchGestureType) -> Void) {
            processor.onGestureTriggered = handler
        }

        public func makeRecognizers() -> [UIGestureRecognizer] {
            let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2
            twoFingerPan.delaysTouchesBegan = false
            twoFingerPan.delaysTouchesEnded = false
            twoFingerPan.delegate = self

            let threeFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleThreeFingerPan(_:)))
            threeFingerPan.minimumNumberOfTouches = 3
            threeFingerPan.maximumNumberOfTouches = 3
            threeFingerPan.delaysTouchesBegan = false
            threeFingerPan.delaysTouchesEnded = false
            threeFingerPan.delegate = self

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delaysTouchesBegan = false
            pinch.delaysTouchesEnded = false
            pinch.delegate = self

            let twoFingerDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerDoubleTap(_:)))
            twoFingerDoubleTap.numberOfTouchesRequired = 2
            twoFingerDoubleTap.numberOfTapsRequired = 2
            twoFingerDoubleTap.delaysTouchesBegan = false
            twoFingerDoubleTap.delaysTouchesEnded = false
            twoFingerDoubleTap.delegate = self

            return [twoFingerPan, threeFingerPan, pinch, twoFingerDoubleTap]
        }

        public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let padView,
                  padView.isUserInteractionEnabled,
                  !padView.isHidden,
                  padView.alpha > 0.01 else {
                return false
            }
            if gestureRecognizer is UIPinchGestureRecognizer {
                return gestureRecognizer.numberOfTouches >= 2
            }
            return true
        }

        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.view.map { recognizer.translation(in: $0) } ?? .zero
            processor.processTwoFingerPan(state: recognizer.state, translation: translation)
        }

        @objc private func handleThreeFingerPan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.view.map { recognizer.translation(in: $0) } ?? .zero
            processor.processThreeFingerPan(state: recognizer.state, translation: translation)
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            processor.processPinch(
                state: recognizer.state,
                scale: recognizer.scale,
                touchCount: recognizer.numberOfTouches
            )
        }

        @objc private func handleTwoFingerDoubleTap(_ recognizer: UITapGestureRecognizer) {
            processor.processTwoFingerDoubleTap(state: recognizer.state)
        }
    }
}
