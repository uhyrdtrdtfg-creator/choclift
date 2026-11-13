import Foundation
#if os(iOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Cross-Platform Companion Device Identity

@MainActor
public enum CompanionDeviceIdentity {
    public struct ResolvedIdentity: Sendable {
        public let deviceID: String
        public let deviceName: String
        public let platform: DevicePlatform

        public init(deviceID: String, deviceName: String, platform: DevicePlatform) {
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.platform = platform
        }
    }

    public static func resolve(
        userDefaults: UserDefaults = .standard,
        idKey: String
    ) -> ResolvedIdentity {
        let persistedID: String = {
            if let existing = userDefaults.string(forKey: idKey), !existing.isEmpty {
                return existing
            }
            let created: String
            #if os(iOS)
            created = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            #elseif os(watchOS)
            created = WKInterfaceDevice.current().identifierForVendor?.uuidString ?? UUID().uuidString
            #else
            created = UUID().uuidString
            #endif
            userDefaults.set(created, forKey: idKey)
            return created
        }()

        #if os(iOS)
        let platform: DevicePlatform = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        let name = UIDevice.current.name
        #elseif os(watchOS)
        let platform: DevicePlatform = .appleWatch
        let rawName = WKInterfaceDevice.current().name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.isEmpty ? "Apple Watch" : rawName
        #elseif os(macOS)
        let platform: DevicePlatform = .mac
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        let platform: DevicePlatform = .iPhone
        let name = ProcessInfo.processInfo.hostName
        #endif

        return ResolvedIdentity(deviceID: persistedID, deviceName: name, platform: platform)
    }
}

// MARK: - Cross-Platform Companion Tactile Feedback

@MainActor
public enum CompanionFeedbackHaptics {
    public enum TapIntensity: Sendable {
        case light
        case medium
        case rigid
    }

    public enum NotificationKind: Sendable {
        case success
        case error
    }

    public static func tap(enabled: Bool, intensity: TapIntensity = .medium) {
        guard enabled else { return }
        #if os(iOS)
        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch intensity {
        case .light: style = .light
        case .medium: style = .medium
        case .rigid: style = .rigid
        }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #elseif os(watchOS)
        switch intensity {
        case .light:
            WKInterfaceDevice.current().play(.click)
        case .medium:
            WKInterfaceDevice.current().play(.click)
        case .rigid:
            WKInterfaceDevice.current().play(.directionUp)
        }
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
        #endif
    }

    public static func notify(enabled: Bool, kind: NotificationKind = .success) {
        guard enabled else { return }
        #if os(iOS)
        let feedbackType: UINotificationFeedbackGenerator.FeedbackType = (kind == .success) ? .success : .error
        UINotificationFeedbackGenerator().notificationOccurred(feedbackType)
        #elseif os(watchOS)
        WKInterfaceDevice.current().play(kind == .success ? .success : .failure)
        #endif
    }
}

// MARK: - Single-Finger Bar Tap vs. Page Swipe Thresholds

public enum BarPageSwipeDirection: String, Equatable, Sendable {
    case previous
    case next
}

public enum BarTouchInteractionOutcome: Equatable, Sendable {
    case tap
    case cancelPress
    case pageSwipe(BarPageSwipeDirection)
}

/// Pure gesture thresholds shared by iPhone and iPad Chocolate Bar surfaces so short finger wobble
/// stays a tile tap while deliberate horizontal swipes change pages without triggering tiles.
public enum BarTouchGestureThresholds {
    /// Movements up to 14pt (for example an 8pt thumb wobble) remain a tap and never pan pages.
    public static let maxTapMovementPoints: CGFloat = 14
    /// Horizontal translation required before releasing a drag commits a page change (for example 40pt).
    public static let minPageSwipeHorizontalPoints: CGFloat = 32
    /// Horizontal-to-vertical ratio required so diagonal/vertical drags cancel without flipping pages.
    public static let horizontalDominanceRatio: CGFloat = 1.35

    public static func travelDistance(for translation: CGSize) -> CGFloat {
        hypot(translation.width, translation.height)
    }

    /// True once finger movement exceeds the tap slop and any active tile press must be cancelled.
    public static func shouldCancelPress(translation: CGSize) -> Bool {
        travelDistance(for: translation) > maxTapMovementPoints
    }

    public static func classify(translation: CGSize) -> BarTouchInteractionOutcome {
        guard shouldCancelPress(translation: translation) else {
            return .tap
        }
        let absX = abs(translation.width)
        let absY = abs(translation.height)
        guard absX >= minPageSwipeHorizontalPoints,
              absX >= absY * horizontalDominanceRatio else {
            return .cancelPress
        }
        return translation.width < 0 ? .pageSwipe(.next) : .pageSwipe(.previous)
    }

    public static func resolvedPageIndex(
        currentIndex: Int,
        pageCount: Int,
        translation: CGSize
    ) -> Int {
        guard pageCount > 0 else { return 0 }
        let safeCurrent = min(max(0, currentIndex), pageCount - 1)
        switch classify(translation: translation) {
        case .tap, .cancelPress:
            return safeCurrent
        case .pageSwipe(.next):
            return min(pageCount - 1, safeCurrent + 1)
        case .pageSwipe(.previous):
            return max(0, safeCurrent - 1)
        }
    }
}

// MARK: - Multi-Touch Overlay Pass-Through Support

public enum MultiTouchOverlayPolicy {
    public static let minimumTouchCount = 2

    /// Returns `true` only when the overlay is enabled, visible, contains the hit point,
    /// and the active touch count meets the multi-touch threshold (>= 2 fingers).
    /// Single-finger touches (`activeTouchCount < 2`) and synthetic point queries (`0`)
    /// return `false` so `hitTest(_:with:)` yields `nil` and SwiftUI controls underneath
    /// receive normal taps and drags.
    public static func shouldOwnHit(
        isUserInteractionEnabled: Bool,
        isHidden: Bool,
        alpha: Double,
        isPointInside: Bool,
        activeTouchCount: Int
    ) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01, isPointInside else {
            return false
        }
        return activeTouchCount >= minimumTouchCount
    }
}

#if os(iOS)
/// Full-screen pass-through multi-touch view that yields `nil` from `hitTest(_:with:)` for
/// single-finger interactions while installing 2-finger and 3-finger gesture recognizers on
/// the enclosing root host view so both simultaneous and staggered multi-touch gestures work.
@MainActor
open class CompanionPassThroughMultiTouchView: UIView {
    public private(set) var managedRecognizers: [UIGestureRecognizer] = []
    private weak var installedHostView: UIView?
    public private(set) var isOverlayEnabled: Bool = true

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
    }

    public static func activeTouchCount(in event: UIEvent?) -> Int {
        guard let allTouches = event?.allTouches else { return 0 }
        return allTouches.reduce(into: 0) { count, touch in
            if touch.phase != .ended && touch.phase != .cancelled {
                count += 1
            }
        }
    }

    public func shouldCaptureHit(at point: CGPoint, activeTouchCount: Int, with event: UIEvent?) -> Bool {
        MultiTouchOverlayPolicy.shouldOwnHit(
            isUserInteractionEnabled: isOverlayEnabled && isUserInteractionEnabled,
            isHidden: isHidden,
            alpha: Double(alpha),
            isPointInside: self.point(inside: point, with: event),
            activeTouchCount: activeTouchCount
        )
    }

    open override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let touches = Self.activeTouchCount(in: event)
        guard shouldCaptureHit(at: point, activeTouchCount: touches, with: event) else {
            return nil
        }
        return self
    }

    public func installManagedRecognizers(_ recognizers: [UIGestureRecognizer]) {
        detachManagedRecognizers()
        managedRecognizers = recognizers
        for recognizer in managedRecognizers {
            recognizer.isEnabled = isOverlayEnabled
        }
        syncRecognizerAttachment()
    }

    public func setOverlayEnabled(_ enabled: Bool) {
        isOverlayEnabled = enabled
        isUserInteractionEnabled = enabled
        for recognizer in managedRecognizers {
            recognizer.isEnabled = enabled
        }
    }

    open override func didMoveToSuperview() {
        super.didMoveToSuperview()
        syncRecognizerAttachment()
    }

    open override func didMoveToWindow() {
        super.didMoveToWindow()
        syncRecognizerAttachment()
    }

    open override func layoutSubviews() {
        super.layoutSubviews()
        syncRecognizerAttachment()
    }

    public var currentRecognizerHostView: UIView? {
        installedHostView
    }

    public func hasPresentedModalAboveOverlay() -> Bool {
        guard let window else { return false }
        var candidate = window.rootViewController
        var owningVC: UIViewController?
        while let vc = candidate {
            if let vcView = vc.viewIfLoaded, self.isDescendant(of: vcView) {
                owningVC = vc
            }
            candidate = vc.presentedViewController
        }
        return owningVC?.presentedViewController != nil
    }

    private func resolveTargetHostView() -> UIView {
        if window == nil && superview == nil {
            return self
        }
        if let window {
            var candidate = window.rootViewController
            var matchingView: UIView?
            while let vc = candidate {
                if let vcView = vc.viewIfLoaded, self.isDescendant(of: vcView) {
                    matchingView = vcView
                }
                candidate = vc.presentedViewController
            }
            if let matchingView {
                return matchingView
            }
        }
        var current: UIView = self
        while let parent = current.superview, !(parent is UIWindow) {
            current = parent
        }
        return current
    }

    public func syncRecognizerAttachment() {
        guard !managedRecognizers.isEmpty else { return }
        let target = resolveTargetHostView()
        target.isMultipleTouchEnabled = true
        guard installedHostView !== target else { return }
        for recognizer in managedRecognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
            target.addGestureRecognizer(recognizer)
        }
        installedHostView = target
    }

    private func detachManagedRecognizers() {
        for recognizer in managedRecognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        installedHostView = nil
    }
}

@MainActor
public final class CompanionMultiTouchCoordinator: NSObject, UIGestureRecognizerDelegate {
    public var onGestureTriggered: (TouchGestureType) -> Void
    public weak var overlayView: CompanionPassThroughMultiTouchView?

    private var didFireCurrentTwoFingerPan = false
    private var didFireCurrentThreeFingerPan = false
    private var didFireCurrentPinch = false

    public init(onGestureTriggered: @escaping (TouchGestureType) -> Void) {
        self.onGestureTriggered = onGestureTriggered
    }

    public func makeConfiguredRecognizers() -> [UIGestureRecognizer] {
        // 2-Finger Pan (Maximize / Minimize / Snap Left / Snap Right)
        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.cancelsTouchesInView = true
        twoFingerPan.delaysTouchesBegan = false
        twoFingerPan.delaysTouchesEnded = false
        twoFingerPan.delegate = self

        // 3-Finger Pan (Mission Control / Show Desktop)
        let threeFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleThreeFingerPan(_:)))
        threeFingerPan.minimumNumberOfTouches = 3
        threeFingerPan.maximumNumberOfTouches = 3
        threeFingerPan.cancelsTouchesInView = true
        threeFingerPan.delaysTouchesBegan = false
        threeFingerPan.delaysTouchesEnded = false
        threeFingerPan.delegate = self

        // Pinch (Grab Copy / Spread Paste)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = true
        pinch.delaysTouchesBegan = false
        pinch.delaysTouchesEnded = false
        pinch.delegate = self

        // 2-Finger Double Tap
        let twoFingerDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerDoubleTap(_:)))
        twoFingerDoubleTap.numberOfTouchesRequired = 2
        twoFingerDoubleTap.numberOfTapsRequired = 2
        twoFingerDoubleTap.cancelsTouchesInView = true
        twoFingerDoubleTap.delaysTouchesBegan = false
        twoFingerDoubleTap.delaysTouchesEnded = false
        twoFingerDoubleTap.delegate = self

        return [twoFingerPan, threeFingerPan, pinch, twoFingerDoubleTap]
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        guard let overlayView,
              overlayView.isOverlayEnabled,
              overlayView.isUserInteractionEnabled,
              !overlayView.isHidden,
              overlayView.alpha > 0.01,
              !overlayView.hasPresentedModalAboveOverlay() else {
            return false
        }
        let point = touch.location(in: overlayView)
        return overlayView.bounds.contains(point)
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let overlayView,
              overlayView.isOverlayEnabled,
              overlayView.isUserInteractionEnabled,
              !overlayView.isHidden,
              overlayView.alpha > 0.01,
              !overlayView.hasPresentedModalAboveOverlay() else {
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

    @objc public func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
        let view = overlayView ?? recognizer.view
        let translation = view.map { recognizer.translation(in: $0) } ?? .zero
        processTwoFingerPan(state: recognizer.state, translation: translation)
    }

    @objc public func handleThreeFingerPan(_ recognizer: UIPanGestureRecognizer) {
        let view = overlayView ?? recognizer.view
        let translation = view.map { recognizer.translation(in: $0) } ?? .zero
        processThreeFingerPan(state: recognizer.state, translation: translation)
    }

    @objc public func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        processPinch(state: recognizer.state, scale: recognizer.scale, touchCount: recognizer.numberOfTouches)
    }

    @objc public func handleTwoFingerDoubleTap(_ recognizer: UITapGestureRecognizer) {
        processTwoFingerDoubleTap(state: recognizer.state)
    }

    public func processTwoFingerPan(state: UIGestureRecognizer.State, translation: CGPoint) {
        switch state {
        case .began:
            didFireCurrentTwoFingerPan = false
        case .changed:
            guard !didFireCurrentTwoFingerPan else { return }
            let threshold: CGFloat = 52
            if abs(translation.y) > abs(translation.x) && abs(translation.y) >= threshold {
                didFireCurrentTwoFingerPan = true
                onGestureTriggered(translation.y < 0 ? .twoFingerSwipeUp : .twoFingerSwipeDown)
            } else if abs(translation.x) > abs(translation.y) && abs(translation.x) >= threshold {
                didFireCurrentTwoFingerPan = true
                onGestureTriggered(translation.x < 0 ? .twoFingerSwipeLeft : .twoFingerSwipeRight)
            }
        default:
            didFireCurrentTwoFingerPan = false
        }
    }

    public func processThreeFingerPan(state: UIGestureRecognizer.State, translation: CGPoint) {
        switch state {
        case .began:
            didFireCurrentThreeFingerPan = false
        case .changed:
            guard !didFireCurrentThreeFingerPan else { return }
            let threshold: CGFloat = 52
            if abs(translation.y) >= threshold && abs(translation.y) > abs(translation.x) {
                didFireCurrentThreeFingerPan = true
                onGestureTriggered(translation.y < 0 ? .threeFingerSwipeUp : .threeFingerSwipeDown)
            }
        default:
            didFireCurrentThreeFingerPan = false
        }
    }

    public func processPinch(state: UIGestureRecognizer.State, scale: CGFloat, touchCount: Int) {
        switch state {
        case .began:
            didFireCurrentPinch = false
        case .changed:
            guard !didFireCurrentPinch, touchCount >= 2 else { return }
            if scale <= 0.68 {
                didFireCurrentPinch = true
                onGestureTriggered(.threeFingerPinchIn)
            } else if scale >= 1.42 {
                didFireCurrentPinch = true
                onGestureTriggered(.threeFingerPinchOut)
            }
        default:
            didFireCurrentPinch = false
        }
    }

    public func processTwoFingerDoubleTap(state: UIGestureRecognizer.State) {
        if state == .ended {
            onGestureTriggered(.twoFingerDoubleTap)
        }
    }
}
#endif
