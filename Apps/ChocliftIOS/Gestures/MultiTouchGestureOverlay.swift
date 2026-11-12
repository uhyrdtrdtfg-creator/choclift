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
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        // 2-Finger Pan (Maximize / Minimize / Snap Left / Snap Right)
        let twoFingerPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.cancelsTouchesInView = false
        twoFingerPan.delaysTouchesBegan = false
        twoFingerPan.delegate = context.coordinator
        view.addGestureRecognizer(twoFingerPan)

        // 3-Finger Pan (Mission Control / Show Desktop)
        let threeFingerPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleThreeFingerPan(_:)))
        threeFingerPan.minimumNumberOfTouches = 3
        threeFingerPan.maximumNumberOfTouches = 3
        threeFingerPan.cancelsTouchesInView = false
        threeFingerPan.delaysTouchesBegan = false
        threeFingerPan.delegate = context.coordinator
        view.addGestureRecognizer(threeFingerPan)

        // Pinch (3-finger Grab Copy / Spread Paste — or 2-finger pinch in dedicated pad)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delaysTouchesBegan = false
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)

        // 2-Finger Double Tap
        let twoFingerDoubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerDoubleTap(_:)))
        twoFingerDoubleTap.numberOfTouchesRequired = 2
        twoFingerDoubleTap.numberOfTapsRequired = 2
        twoFingerDoubleTap.cancelsTouchesInView = false
        twoFingerDoubleTap.delaysTouchesBegan = false
        twoFingerDoubleTap.delegate = context.coordinator
        view.addGestureRecognizer(twoFingerDoubleTap)

        return view
    }

    public func updateUIView(_ uiView: PassThroughMultiTouchUIView, context: Context) {
        uiView.isUserInteractionEnabled = isEnabled
        context.coordinator.onGestureTriggered = onGestureTriggered
    }

    public final class PassThroughMultiTouchUIView: UIView {}

    public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onGestureTriggered: (TouchGestureType) -> Void
        private var didFireCurrentPan = false
        private var didFireCurrentPinch = false

        init(onGestureTriggered: @escaping (TouchGestureType) -> Void) {
            self.onGestureTriggered = onGestureTriggered
        }

        public func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                didFireCurrentPan = false
            case .changed:
                guard !didFireCurrentPan, let view = recognizer.view else { return }
                let translation = recognizer.translation(in: view)
                let threshold: CGFloat = 52
                if abs(translation.y) > abs(translation.x) && abs(translation.y) >= threshold {
                    didFireCurrentPan = true
                    onGestureTriggered(translation.y < 0 ? .twoFingerSwipeUp : .twoFingerSwipeDown)
                } else if abs(translation.x) > abs(translation.y) && abs(translation.x) >= threshold {
                    didFireCurrentPan = true
                    onGestureTriggered(translation.x < 0 ? .twoFingerSwipeLeft : .twoFingerSwipeRight)
                }
            default:
                didFireCurrentPan = false
            }
        }

        @objc func handleThreeFingerPan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                didFireCurrentPan = false
            case .changed:
                guard !didFireCurrentPan, let view = recognizer.view else { return }
                let translation = recognizer.translation(in: view)
                let threshold: CGFloat = 52
                if abs(translation.y) >= threshold && abs(translation.y) > abs(translation.x) {
                    didFireCurrentPan = true
                    onGestureTriggered(translation.y < 0 ? .threeFingerSwipeUp : .threeFingerSwipeDown)
                }
            default:
                didFireCurrentPan = false
            }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                didFireCurrentPinch = false
            case .changed:
                guard !didFireCurrentPinch, recognizer.numberOfTouches >= 2 else { return }
                if recognizer.scale <= 0.68 {
                    didFireCurrentPinch = true
                    onGestureTriggered(.threeFingerPinchIn)
                } else if recognizer.scale >= 1.42 {
                    didFireCurrentPinch = true
                    onGestureTriggered(.threeFingerPinchOut)
                }
            default:
                didFireCurrentPinch = false
            }
        }

        @objc func handleTwoFingerDoubleTap(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended {
                onGestureTriggered(.twoFingerDoubleTap)
            }
        }
    }
}
