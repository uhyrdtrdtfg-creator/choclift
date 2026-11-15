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

// MARK: - Companion Display Brightness Availability Policy

public enum CompanionBrightnessControlPolicy {
    /// Returns `true` when the companion is connected to a Mac whose active display cannot be dimmed
    /// through macOS system brightness (`isBrightnessAvailable == false`).
    public static func isSliderDisabled(
        isConnected: Bool,
        isBrightnessAvailable: Bool
    ) -> Bool {
        isConnected && !isBrightnessAvailable
    }

    /// Explanatory caption shown when connected to a display that does not support system brightness,
    /// or `nil` when the brightness slider is enabled.
    public static func unavailableCaption(
        isConnected: Bool,
        isBrightnessAvailable: Bool,
        language: AppLanguage = .system
    ) -> String? {
        guard isSliderDisabled(isConnected: isConnected, isBrightnessAvailable: isBrightnessAvailable) else {
            return nil
        }
        return L10n.tr(
            "当前显示器不支持系统亮度",
            "This display does not support system brightness",
            language: language
        )
    }
}

// MARK: - Multi-Display Window Move Geometry, Real AX Error Formatting & Undo Coordinator

public struct WindowScreenDescriptor: Equatable, Sendable {
    /// Full display frame in AppKit global coordinates (`NSScreen.frame`, bottom-left origin on primary display).
    public let frame: CGRect
    /// Visible display frame in AppKit global coordinates (`NSScreen.visibleFrame`, excluding Dock & Menu Bar).
    public let visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect? = nil) {
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
    }
}

public struct QuartzScreenBounds: Equatable, Sendable {
    /// Full display frame in Quartz global coordinates (top-left origin on primary display).
    public let frame: CGRect
    /// Visible display frame in Quartz global coordinates (excluding Dock & Menu Bar).
    public let visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect? = nil) {
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
    }
}

public struct NextDisplayTargetPlan: Equatable, Sendable {
    public let sourceScreenIndex: Int
    public let targetScreenIndex: Int
    public let targetFrame: CGRect

    public init(sourceScreenIndex: Int, targetScreenIndex: Int, targetFrame: CGRect) {
        self.sourceScreenIndex = sourceScreenIndex
        self.targetScreenIndex = targetScreenIndex
        self.targetFrame = targetFrame
    }
}

public enum WindowQuarterCorner: String, CaseIterable, Equatable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

public enum WindowDisplayGeometry {
    public static func quarterFrame(
        for corner: WindowQuarterCorner,
        visibleQuartz: CGRect
    ) -> CGRect {
        let halfW = floor(visibleQuartz.width / 2.0)
        let halfH = floor(visibleQuartz.height / 2.0)
        let rightX = visibleQuartz.origin.x + (visibleQuartz.width - halfW)
        let bottomY = visibleQuartz.origin.y + (visibleQuartz.height - halfH)
        switch corner {
        case .topLeft:
            return CGRect(x: visibleQuartz.origin.x, y: visibleQuartz.origin.y, width: halfW, height: halfH)
        case .topRight:
            return CGRect(x: rightX, y: visibleQuartz.origin.y, width: halfW, height: halfH)
        case .bottomLeft:
            return CGRect(x: visibleQuartz.origin.x, y: bottomY, width: halfW, height: halfH)
        case .bottomRight:
            return CGRect(x: rightX, y: bottomY, width: halfW, height: halfH)
        }
    }

    public static func convertAppKitRectToQuartz(
        _ appKitRect: CGRect,
        primaryScreenHeight: CGFloat
    ) -> CGRect {
        let quartzY = primaryScreenHeight - appKitRect.maxY
        return CGRect(
            x: appKitRect.origin.x,
            y: quartzY,
            width: appKitRect.width,
            height: appKitRect.height
        )
    }

    public static func quartzScreens(from appKitScreens: [WindowScreenDescriptor]) -> [QuartzScreenBounds] {
        guard let primaryHeight = appKitScreens.first?.frame.height else { return [] }
        return appKitScreens.map { screen in
            QuartzScreenBounds(
                frame: convertAppKitRectToQuartz(screen.frame, primaryScreenHeight: primaryHeight),
                visibleFrame: convertAppKitRectToQuartz(screen.visibleFrame, primaryScreenHeight: primaryHeight)
            )
        }
    }

    public static func sourceScreenIndex(
        for windowQuartzFrame: CGRect,
        in screens: [QuartzScreenBounds]
    ) -> Int? {
        guard !screens.isEmpty else { return nil }
        let midpoint = CGPoint(x: windowQuartzFrame.midX, y: windowQuartzFrame.midY)
        if let containingIndex = screens.firstIndex(where: {
            $0.frame.contains(midpoint) || $0.visibleFrame.contains(midpoint)
        }) {
            return containingIndex
        }

        var bestOverlapIndex: Int?
        var bestOverlapArea: CGFloat = 0
        for (idx, screen) in screens.enumerated() {
            let inter = screen.frame.intersection(windowQuartzFrame)
            if !inter.isNull && inter.width > 0 && inter.height > 0 {
                let area = inter.width * inter.height
                if area > bestOverlapArea {
                    bestOverlapArea = area
                    bestOverlapIndex = idx
                }
            }
        }
        if let bestOverlapIndex {
            return bestOverlapIndex
        }

        var nearestIndex = 0
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for (idx, screen) in screens.enumerated() {
            let dist = hypot(screen.frame.midX - midpoint.x, screen.frame.midY - midpoint.y)
            if dist < nearestDistance {
                nearestDistance = dist
                nearestIndex = idx
            }
        }
        return nearestIndex
    }

    public static func centeredFrame(
        currentFrame: CGRect?,
        visibleQuartz: CGRect,
        allowResize: Bool = true
    ) -> CGRect {
        let width: CGFloat
        let height: CGFloat
        if allowResize {
            width = min(currentFrame?.width ?? visibleQuartz.width * 0.72, visibleQuartz.width)
            height = min(currentFrame?.height ?? visibleQuartz.height * 0.78, visibleQuartz.height)
        } else {
            width = currentFrame?.width ?? round(visibleQuartz.width * 0.72)
            height = currentFrame?.height ?? round(visibleQuartz.height * 0.78)
        }
        return CGRect(
            x: round(visibleQuartz.origin.x + (visibleQuartz.width - width) / 2.0),
            y: round(visibleQuartz.origin.y + (visibleQuartz.height - height) / 2.0),
            width: width,
            height: height
        )
    }

    public static func nextDisplayTargetFrame(
        windowQuartzFrame: CGRect,
        quartzScreens: [QuartzScreenBounds],
        allowResize: Bool = true
    ) -> NextDisplayTargetPlan? {
        guard quartzScreens.count >= 2,
              let sourceIndex = sourceScreenIndex(for: windowQuartzFrame, in: quartzScreens) else {
            return nil
        }

        let targetIndex = (sourceIndex + 1) % quartzScreens.count
        let sourceVisible = quartzScreens[sourceIndex].visibleFrame
        let targetVisible = quartzScreens[targetIndex].visibleFrame

        let width: CGFloat = allowResize
            ? min(max(1, windowQuartzFrame.width), targetVisible.width)
            : max(1, windowQuartzFrame.width)
        let height: CGFloat = allowResize
            ? min(max(1, windowQuartzFrame.height), targetVisible.height)
            : max(1, windowQuartzFrame.height)

        let sourceSlackX = sourceVisible.width - windowQuartzFrame.width
        let sourceSlackY = sourceVisible.height - windowQuartzFrame.height
        let ratioX: CGFloat = sourceSlackX > 0
            ? min(max((windowQuartzFrame.minX - sourceVisible.minX) / sourceSlackX, 0), 1)
            : 0.5
        let ratioY: CGFloat = sourceSlackY > 0
            ? min(max((windowQuartzFrame.minY - sourceVisible.minY) / sourceSlackY, 0), 1)
            : 0.5

        let targetSlackX = targetVisible.width - width
        let targetSlackY = targetVisible.height - height

        let x: CGFloat
        if targetSlackX >= 0 {
            let rawX = round(targetVisible.minX + ratioX * targetSlackX)
            x = min(max(rawX, targetVisible.minX), targetVisible.maxX - width)
        } else {
            x = round(targetVisible.minX + targetSlackX / 2.0)
        }

        let y: CGFloat
        if targetSlackY >= 0 {
            let rawY = round(targetVisible.minY + ratioY * targetSlackY)
            y = min(max(rawY, targetVisible.minY), targetVisible.maxY - height)
        } else {
            y = round(targetVisible.minY + targetSlackY / 2.0)
        }

        return NextDisplayTargetPlan(
            sourceScreenIndex: sourceIndex,
            targetScreenIndex: targetIndex,
            targetFrame: CGRect(x: x, y: y, width: width, height: height)
        )
    }

    public static func nextDisplayTargetFrame(
        windowQuartzFrame: CGRect,
        quartzVisibleFrames: [CGRect],
        allowResize: Bool = true
    ) -> NextDisplayTargetPlan? {
        let screens = quartzVisibleFrames.map { QuartzScreenBounds(frame: $0, visibleFrame: $0) }
        return nextDisplayTargetFrame(
            windowQuartzFrame: windowQuartzFrame,
            quartzScreens: screens,
            allowResize: allowResize
        )
    }

    public static func nextDisplayTargetFrame(
        windowQuartzFrame: CGRect,
        appKitScreens: [WindowScreenDescriptor],
        allowResize: Bool = true
    ) -> NextDisplayTargetPlan? {
        nextDisplayTargetFrame(
            windowQuartzFrame: windowQuartzFrame,
            quartzScreens: quartzScreens(from: appKitScreens),
            allowResize: allowResize
        )
    }
}

public enum WindowAXErrorFormatting {
    public static func symbolName(for rawCode: Int32) -> String {
        switch rawCode {
        case 0: return "kAXErrorSuccess"
        case -25200: return "kAXErrorFailure"
        case -25201: return "kAXErrorIllegalArgument"
        case -25202: return "kAXErrorInvalidUIElement"
        case -25203: return "kAXErrorInvalidUIElementObserver"
        case -25204: return "kAXErrorCannotComplete"
        case -25205: return "kAXErrorAttributeUnsupported"
        case -25206: return "kAXErrorActionUnsupported"
        case -25207: return "kAXErrorNotificationUnsupported"
        case -25208: return "kAXErrorNotImplemented"
        case -25209: return "kAXErrorNotificationAlreadyRegistered"
        case -25210: return "kAXErrorNotificationNotRegistered"
        case -25211: return "kAXErrorAPIDisabled"
        case -25212: return "kAXErrorNoValue"
        case -25213: return "kAXErrorParameterizedAttributeUnsupported"
        case -25214: return "kAXErrorNotEnoughPrecision"
        default: return "AXError"
        }
    }

    public static func describe(rawCode: Int32) -> String {
        "\(symbolName(for: rawCode)) (\(rawCode))"
    }

    public static func moveFailureMessage(rawCode: Int32, language: AppLanguage = .system) -> String {
        let detail = describe(rawCode: rawCode)
        return L10n.tr(
            "无法移动窗口：\(detail)",
            "Unable to move window: \(detail)",
            language: language
        )
    }
}

public struct WindowAXStatusError: Error, Equatable, Sendable, LocalizedError {
    public let code: Int32

    public init(_ code: Int32) {
        self.code = code
    }

    public var errorDescription: String? {
        WindowAXErrorFormatting.moveFailureMessage(rawCode: code)
    }
}

public enum WindowMoveExecutionError: Error, Equatable, Sendable, LocalizedError {
    case noSecondaryDisplay
    case axError(code: Int32)

    public var errorDescription: String? {
        message(in: .system)
    }

    public func message(in language: AppLanguage = .system) -> String {
        switch self {
        case .noSecondaryDisplay:
            return L10n.tr("未检测到下一台显示器", "No secondary display connected", language: language)
        case .axError(let code):
            return WindowAXErrorFormatting.moveFailureMessage(rawCode: code, language: language)
        }
    }
}

public struct WindowMoveCoordinator<WindowID: Hashable & Sendable>: Equatable, Sendable {
    public private(set) var undoBuffer = WindowMoveUndoBuffer<WindowID>()

    public init() {}

    public var canUndo: Bool {
        undoBuffer.canUndo
    }

    public var lastWindowMove: WindowMoveSnapshot<WindowID>? {
        undoBuffer.lastEntry?.last
    }

    public var lastEntry: [WindowMoveSnapshot<WindowID>]? {
        undoBuffer.lastEntry
    }

    public var isInTransaction: Bool {
        undoBuffer.isInTransaction
    }

    public mutating func beginTransaction() {
        undoBuffer.beginTransaction()
    }

    @discardableResult
    public mutating func commitTransaction() -> Bool {
        undoBuffer.commitTransaction()
    }

    public mutating func cancelTransaction() {
        undoBuffer.cancelTransaction()
    }

    public mutating func recordMove(
        windowID: WindowID,
        appName: String,
        previousFrame: WindowQuartzRect
    ) {
        undoBuffer.recordMove(
            windowID: windowID,
            appName: appName,
            previousFrame: previousFrame
        )
    }

    public mutating func popUndoEntry() -> [WindowMoveSnapshot<WindowID>]? {
        undoBuffer.popUndoEntry()
    }

    public mutating func clear() {
        undoBuffer.clear()
    }

    public mutating func performCenter(
        windowID: WindowID,
        appName: String,
        visibleQuartz: CGRect,
        allowResize: Bool = true,
        readFrame: () -> Result<CGRect, WindowAXStatusError>,
        writeFrame: (CGRect) -> Int32
    ) -> Result<CGRect, WindowMoveExecutionError> {
        let currentFrame: CGRect
        switch readFrame() {
        case .success(let rect):
            currentFrame = rect
        case .failure(let axStatus):
            return .failure(.axError(code: axStatus.code))
        }

        let targetFrame = WindowDisplayGeometry.centeredFrame(
            currentFrame: currentFrame,
            visibleQuartz: visibleQuartz,
            allowResize: allowResize
        )
        let writeCode = writeFrame(targetFrame)
        guard writeCode == 0 else {
            return .failure(.axError(code: writeCode))
        }

        recordMove(
            windowID: windowID,
            appName: appName,
            previousFrame: WindowQuartzRect(currentFrame)
        )
        return .success(targetFrame)
    }

    public mutating func performMoveToNextDisplay(
        windowID: WindowID,
        appName: String,
        quartzScreens: [QuartzScreenBounds],
        allowResize: Bool = true,
        readFrame: () -> Result<CGRect, WindowAXStatusError>,
        writeFrame: (CGRect) -> Int32
    ) -> Result<NextDisplayTargetPlan, WindowMoveExecutionError> {
        let currentFrame: CGRect
        switch readFrame() {
        case .success(let rect):
            currentFrame = rect
        case .failure(let axStatus):
            return .failure(.axError(code: axStatus.code))
        }

        guard let plan = WindowDisplayGeometry.nextDisplayTargetFrame(
            windowQuartzFrame: currentFrame,
            quartzScreens: quartzScreens,
            allowResize: allowResize
        ) else {
            return .failure(.noSecondaryDisplay)
        }

        let writeCode = writeFrame(plan.targetFrame)
        guard writeCode == 0 else {
            return .failure(.axError(code: writeCode))
        }

        recordMove(
            windowID: windowID,
            appName: appName,
            previousFrame: WindowQuartzRect(currentFrame)
        )
        return .success(plan)
    }

    public mutating func performMoveToNextDisplay(
        windowID: WindowID,
        appName: String,
        quartzVisibleFrames: [CGRect],
        allowResize: Bool = true,
        readFrame: () -> Result<CGRect, WindowAXStatusError>,
        writeFrame: (CGRect) -> Int32
    ) -> Result<NextDisplayTargetPlan, WindowMoveExecutionError> {
        let screens = quartzVisibleFrames.map { QuartzScreenBounds(frame: $0, visibleFrame: $0) }
        return performMoveToNextDisplay(
            windowID: windowID,
            appName: appName,
            quartzScreens: screens,
            allowResize: allowResize,
            readFrame: readFrame,
            writeFrame: writeFrame
        )
    }

    public mutating func performMoveToNextDisplay(
        windowID: WindowID,
        appName: String,
        appKitScreens: [WindowScreenDescriptor],
        allowResize: Bool = true,
        readFrame: () -> Result<CGRect, WindowAXStatusError>,
        writeFrame: (CGRect) -> Int32
    ) -> Result<NextDisplayTargetPlan, WindowMoveExecutionError> {
        performMoveToNextDisplay(
            windowID: windowID,
            appName: appName,
            quartzScreens: WindowDisplayGeometry.quartzScreens(from: appKitScreens),
            allowResize: allowResize,
            readFrame: readFrame,
            writeFrame: writeFrame
        )
    }

    public mutating func performUndo(
        writeFrame: (WindowID, CGRect) -> Int32
    ) -> Result<[WindowMoveSnapshot<WindowID>], WindowMoveExecutionError>? {
        guard let snapshots = popUndoEntry() else {
            return nil
        }
        var restored: [WindowMoveSnapshot<WindowID>] = []
        var firstError: Int32?
        for snapshot in snapshots {
            let code = writeFrame(snapshot.windowID, snapshot.previousFrame.cgRect)
            if code == 0 {
                restored.append(snapshot)
            } else if firstError == nil {
                firstError = code
            }
        }
        if !restored.isEmpty {
            return .success(restored)
        }
        return .failure(.axError(code: firstError ?? -25200))
    }
}
