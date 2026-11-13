import CoreGraphics
import Foundation

// MARK: - Companion Touch & Gesture Threshold Policy

public enum CompanionInteractionPolicy {
    /// Maximum finger movement (in points) still treated as a stationary tap or hold.
    public static let tapMaxTranslationPoints: CGFloat = 8.0

    /// Minimum horizontal finger travel (in points) required to classify a 1-finger drag as a page swipe.
    public static let pageSwipeMinHorizontalPoints: CGFloat = 40.0

    /// Hold duration (in seconds) required on an iPhone or iPad tile to open the slot editor.
    public static let tileLongPressDurationSeconds: TimeInterval = 0.45

    /// Time window (in seconds) within which a second tap confirms a destructive tile or action.
    public static let destructiveConfirmWindowSeconds: TimeInterval = 3.0

    public enum TileTouchClassification: Equatable, Sendable {
        case shortTap
        case longPressEdit
        case pageSwipe(delta: Int)
        case consumedByLongPress
        case sliderScrub
        case cancelled
    }

    public static func translationDistance(_ translation: CGSize) -> CGFloat {
        hypot(translation.width, translation.height)
    }

    /// Returns `true` when an in-progress touch has stayed within the 8-point tap slop
    /// for at least the 0.45-second long-press threshold and did not start on a control slider.
    public static func shouldFireLongPressWhileHolding(
        translation: CGSize,
        elapsedSeconds: TimeInterval,
        isControlSliderDrag: Bool = false
    ) -> Bool {
        guard !isControlSliderDrag else { return false }
        guard elapsedSeconds.isFinite, elapsedSeconds >= tileLongPressDurationSeconds else {
            return false
        }
        return translationDistance(translation) <= tapMaxTranslationPoints
    }

    /// Classifies a completed 1-finger interaction using the 8-point tap slop,
    /// 0.45-second long-press threshold, 40-point horizontal page swipe threshold,
    /// and volume/brightness slider exclusion rule.
    public static func classifyTouchEnded(
        translation: CGSize,
        pressDuration: TimeInterval,
        didTriggerLongPress: Bool = false,
        isControlSliderDrag: Bool = false
    ) -> TileTouchClassification {
        if isControlSliderDrag {
            return .sliderScrub
        }
        if didTriggerLongPress {
            return .consumedByLongPress
        }

        let absDX = abs(translation.width)
        let absDY = abs(translation.height)
        if absDX >= pageSwipeMinHorizontalPoints && absDX > absDY {
            // Swiping left (negative X) advances to next page (+1); swiping right goes to previous (-1).
            return .pageSwipe(delta: translation.width < 0 ? 1 : -1)
        }

        if translationDistance(translation) <= tapMaxTranslationPoints {
            if pressDuration.isFinite && pressDuration >= tileLongPressDurationSeconds {
                return .longPressEdit
            }
            return .shortTap
        }

        return .cancelled
    }
}

// MARK: - Two-Tap Destructive Action Confirmation Gate (3-Second Window)

public enum DestructiveTapDecision: Equatable, Sendable {
    case runImmediately
    case requireSecondTap(expiresAt: TimeInterval)
    case confirmedRun
}

public struct DestructiveActionConfirmGate: Equatable, Sendable {
    public let confirmationWindowSeconds: TimeInterval
    public private(set) var armedTargetID: String?
    public private(set) var armedAtTimestamp: TimeInterval?

    public init(
        confirmationWindowSeconds: TimeInterval = CompanionInteractionPolicy.destructiveConfirmWindowSeconds
    ) {
        self.confirmationWindowSeconds = max(0.1, confirmationWindowSeconds)
    }

    public func isArmed(targetID: String, at now: TimeInterval) -> Bool {
        guard armedTargetID == targetID,
              let armedAt = armedAtTimestamp,
              now >= armedAt else {
            return false
        }
        return (now - armedAt) <= confirmationWindowSeconds
    }

    public mutating func expireIfNeeded(at now: TimeInterval) {
        guard let armedAt = armedAtTimestamp else { return }
        if now < armedAt || (now - armedAt) > confirmationWindowSeconds {
            disarm()
        }
    }

    public mutating func disarm() {
        armedTargetID = nil
        armedAtTimestamp = nil
    }

    public mutating func registerTap(
        targetID: String,
        isDestructive: Bool,
        at now: TimeInterval
    ) -> DestructiveTapDecision {
        guard isDestructive else {
            disarm()
            return .runImmediately
        }

        if isArmed(targetID: targetID, at: now) {
            disarm()
            return .confirmedRun
        }

        armedTargetID = targetID
        armedAtTimestamp = now
        return .requireSecondTap(expiresAt: now + confirmationWindowSeconds)
    }
}

// MARK: - One-Level Window Move Undo Buffer

public struct WindowQuartzRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct WindowMoveSnapshot<WindowID: Hashable & Sendable>: Equatable, Sendable {
    public let windowID: WindowID
    public let appName: String
    public let previousFrame: WindowQuartzRect

    public init(windowID: WindowID, appName: String, previousFrame: WindowQuartzRect) {
        self.windowID = windowID
        self.appName = appName
        self.previousFrame = previousFrame
    }
}

/// Stores at most ONE level of window move history.
/// Supports grouping a multi-window flow (such as Left & Right Split) into a single undoable change.
public struct WindowMoveUndoBuffer<WindowID: Hashable & Sendable>: Equatable, Sendable {
    public private(set) var lastEntry: [WindowMoveSnapshot<WindowID>]?
    private var activeTransactionSnapshots: [WindowMoveSnapshot<WindowID>]?

    public init() {}

    public var canUndo: Bool {
        guard let lastEntry else { return false }
        return !lastEntry.isEmpty
    }

    public var isInTransaction: Bool {
        activeTransactionSnapshots != nil
    }

    public mutating func beginTransaction() {
        activeTransactionSnapshots = []
    }

    public mutating func recordMove(
        windowID: WindowID,
        appName: String,
        previousFrame: WindowQuartzRect
    ) {
        let snapshot = WindowMoveSnapshot(
            windowID: windowID,
            appName: appName,
            previousFrame: previousFrame
        )
        if var transaction = activeTransactionSnapshots {
            // Keep the initial pre-flow frame if the same window is moved more than once in one flow.
            if !transaction.contains(where: { $0.windowID == windowID }) {
                transaction.append(snapshot)
                activeTransactionSnapshots = transaction
            }
        } else {
            lastEntry = [snapshot]
        }
    }

    /// Commits any moves captured during the active flow transaction as a single 1-level undo entry.
    /// If the flow did not move any windows, existing undo state is left untouched.
    @discardableResult
    public mutating func commitTransaction() -> Bool {
        guard let captured = activeTransactionSnapshots else { return false }
        activeTransactionSnapshots = nil
        guard !captured.isEmpty else { return false }
        lastEntry = captured
        return true
    }

    public mutating func cancelTransaction() {
        activeTransactionSnapshots = nil
    }

    /// Pops and clears the single stored window move entry (one level only).
    /// Returns `nil` quietly when there is nothing to undo.
    public mutating func popUndoEntry() -> [WindowMoveSnapshot<WindowID>]? {
        guard let entry = lastEntry, !entry.isEmpty else {
            lastEntry = nil
            return nil
        }
        lastEntry = nil
        return entry
    }

    public mutating func clear() {
        activeTransactionSnapshots = nil
        lastEntry = nil
    }
}
