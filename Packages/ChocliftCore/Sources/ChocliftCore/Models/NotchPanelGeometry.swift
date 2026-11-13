import CoreGraphics
import Foundation

// MARK: - Screen & Anchor Geometry for Mac Notch / Edge Panel

public enum NotchPanelAnchor: String, Codable, CaseIterable, Equatable, Sendable {
    case topNotch = "top_notch"
    case leftEdge = "left_edge"
}

public struct NotchScreenMetrics: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var safeAreaTopInset: CGFloat
    public var auxiliaryTopLeftRect: CGRect?
    public var auxiliaryTopRightRect: CGRect?

    public init(
        frame: CGRect,
        visibleFrame: CGRect,
        safeAreaTopInset: CGFloat = 0,
        auxiliaryTopLeftRect: CGRect? = nil,
        auxiliaryTopRightRect: CGRect? = nil
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTopInset = max(0, safeAreaTopInset)
        self.auxiliaryTopLeftRect = auxiliaryTopLeftRect
        self.auxiliaryTopRightRect = auxiliaryTopRightRect
    }

    public var hasHardwareNotch: Bool {
        safeAreaTopInset > 0
    }

    public var menuBarHeight: CGFloat {
        max(0, frame.maxY - visibleFrame.maxY)
    }

    /// Physical camera housing rectangle in AppKit screen coordinates when present.
    public var notchRect: CGRect? {
        guard hasHardwareNotch else { return nil }
        let height = max(safeAreaTopInset, menuBarHeight)
        if let left = auxiliaryTopLeftRect,
           let right = auxiliaryTopRightRect,
           !left.isEmpty,
           !right.isEmpty,
           right.minX > left.maxX {
            let width = right.minX - left.maxX
            return CGRect(
                x: left.maxX,
                y: frame.maxY - height,
                width: width,
                height: height
            )
        }
        let fallbackWidth = min(210, frame.width * 0.25)
        return CGRect(
            x: frame.midX - fallbackWidth / 2.0,
            y: frame.maxY - height,
            width: fallbackWidth,
            height: height
        )
    }
}

public enum NotchPanelLayout {
    /// Inclusive bounds test so pointers resting right on `frame.maxY` or `frame.minX` still match.
    public static func rectContainsInclusive(
        _ rect: CGRect,
        point: CGPoint,
        edgeSlop: CGFloat = 1.0
    ) -> Bool {
        guard !rect.isNull && rect.width > 0 && rect.height > 0 else { return false }
        return point.x >= rect.minX - edgeSlop &&
            point.x <= rect.maxX + edgeSlop &&
            point.y >= rect.minY - edgeSlop &&
            point.y <= rect.maxY + edgeSlop
    }

    /// Hover entry region at the hardware notch (or top-center menu bar on Macs without a notch).
    public static func topTriggerRect(
        for screen: NotchScreenMetrics,
        minimumWidth: CGFloat = 240,
        autoHiddenFallbackHeight: CGFloat = 10
    ) -> CGRect {
        guard screen.frame.width > 0 && screen.frame.height > 0 else { return .zero }

        let centerX: CGFloat
        let rawWidth: CGFloat
        if let notch = screen.notchRect {
            centerX = notch.midX
            rawWidth = max(minimumWidth, notch.width + 48)
        } else {
            centerX = screen.frame.midX
            rawWidth = minimumWidth
        }

        let maxAllowedWidth = max(120, screen.frame.width * 0.48)
        let width = min(rawWidth, maxAllowedWidth)

        let height: CGFloat
        if screen.hasHardwareNotch {
            height = max(screen.safeAreaTopInset, screen.menuBarHeight, 32)
        } else if screen.menuBarHeight > 0 {
            height = max(screen.menuBarHeight, 24)
        } else {
            height = autoHiddenFallbackHeight
        }

        let clampedHeight = min(height, screen.frame.height * 0.2)
        let minX = max(screen.frame.minX, min(centerX - width / 2.0, screen.frame.maxX - width))

        return CGRect(
            x: round(minX),
            y: round(screen.frame.maxY - clampedHeight),
            width: round(width),
            height: round(clampedHeight)
        )
    }

    /// Optional hover entry strip along the vertical center of the left screen edge.
    public static func leftEdgeTriggerRect(
        for screen: NotchScreenMetrics,
        thickness: CGFloat = 6,
        preferredHeight: CGFloat = 260
    ) -> CGRect {
        guard screen.frame.width > 0 && screen.frame.height > 0 else { return .zero }
        let basis = screen.visibleFrame.height > 0 ? screen.visibleFrame : screen.frame
        let height = min(preferredHeight, max(80, basis.height * 0.5))
        let width = max(2, min(thickness, screen.frame.width * 0.05))
        return CGRect(
            x: screen.frame.minX,
            y: round(basis.midY - height / 2.0),
            width: width,
            height: round(height)
        )
    }

    /// Computes the target `NSPanel` frame (including any transparent shadow inset baked into `panelSize`).
    public static func panelFrame(
        for anchor: NotchPanelAnchor,
        panelSize: CGSize,
        screen: NotchScreenMetrics
    ) -> CGRect {
        let basis = screen.visibleFrame.width > 0 && screen.visibleFrame.height > 0
            ? screen.visibleFrame
            : screen.frame

        switch anchor {
        case .topNotch:
            let trigger = topTriggerRect(for: screen)
            let desiredX = trigger.midX - panelSize.width / 2.0
            let minX = basis.minX + 8
            let maxX = max(minX, basis.maxX - panelSize.width - 8)
            let clampedX = min(max(desiredX, minX), maxX)

            let topClearance = max(screen.safeAreaTopInset, screen.menuBarHeight)
            let topEdgeY = screen.frame.maxY - (topClearance > 0 ? topClearance : 4)
            let desiredY = topEdgeY - panelSize.height

            return CGRect(
                x: round(clampedX),
                y: round(max(basis.minY + 8, desiredY)),
                width: panelSize.width,
                height: panelSize.height
            )

        case .leftEdge:
            let leftX = max(screen.frame.minX + 4, basis.minX + 4)
            let desiredY = basis.midY - panelSize.height / 2.0
            let minY = basis.minY + 12
            let maxY = max(minY, basis.maxY - panelSize.height - 12)
            let clampedY = min(max(desiredY, minY), maxY)

            return CGRect(
                x: round(leftX),
                y: round(clampedY),
                width: panelSize.width,
                height: panelSize.height
            )
        }
    }

    /// Keep-alive region while the panel is open: bridges the trigger zone and the panel so
    /// moving from the notch / left edge into the tiles has zero dead gap, while exiting hides it.
    public static func keepAliveContains(
        point: CGPoint,
        anchor: NotchPanelAnchor,
        panelFrame: CGRect,
        screen: NotchScreenMetrics,
        margin: CGFloat = 10
    ) -> Bool {
        if rectContainsInclusive(panelFrame.insetBy(dx: -margin, dy: -margin), point: point) {
            return true
        }

        switch anchor {
        case .topNotch:
            let trigger = topTriggerRect(for: screen)
            if rectContainsInclusive(trigger.insetBy(dx: -margin, dy: -margin), point: point) {
                return true
            }
            let bridgeMinX = min(trigger.minX, panelFrame.minX) - margin
            let bridgeMaxX = max(trigger.maxX, panelFrame.maxX) + margin
            let bridgeRect = CGRect(
                x: bridgeMinX,
                y: panelFrame.minY - margin,
                width: max(0, bridgeMaxX - bridgeMinX),
                height: max(0, screen.frame.maxY - (panelFrame.minY - margin))
            )
            return rectContainsInclusive(bridgeRect, point: point)

        case .leftEdge:
            let trigger = leftEdgeTriggerRect(for: screen)
            if rectContainsInclusive(trigger.insetBy(dx: -margin, dy: -margin), point: point) {
                return true
            }
            let bridgeMinY = min(trigger.minY, panelFrame.minY) - margin
            let bridgeMaxY = max(trigger.maxY, panelFrame.maxY) + margin
            let bridgeRect = CGRect(
                x: screen.frame.minX,
                y: bridgeMinY,
                width: max(0, (panelFrame.maxX + margin) - screen.frame.minX),
                height: max(0, bridgeMaxY - bridgeMinY)
            )
            return rectContainsInclusive(bridgeRect, point: point)
        }
    }

    /// Pure check for whether an external window covers the entire display (including menu bar area),
    /// such as full-screen video or a dedicated full-screen space.
    public static func windowCoversFullScreen(
        windowFrameInScreenCoords: CGRect,
        screen: NotchScreenMetrics,
        tolerance: CGFloat = 2.0
    ) -> Bool {
        guard screen.frame.width > 0 && screen.frame.height > 0 else { return false }
        let coversWidth = windowFrameInScreenCoords.minX <= screen.frame.minX + tolerance &&
            windowFrameInScreenCoords.maxX >= screen.frame.maxX - tolerance
        let coversHeight = windowFrameInScreenCoords.minY <= screen.frame.minY + tolerance &&
            windowFrameInScreenCoords.maxY >= screen.frame.maxY - tolerance
        return coversWidth && coversHeight
    }

    /// Converts a Quartz global window rect (origin at top-left of primary screen) into AppKit screen coordinates.
    public static func appKitScreenRect(
        fromQuartzRect quartzRect: CGRect,
        primaryScreenHeight: CGFloat
    ) -> CGRect {
        CGRect(
            x: quartzRect.origin.x,
            y: primaryScreenHeight - quartzRect.maxY,
            width: quartzRect.width,
            height: quartzRect.height
        )
    }
}

// MARK: - Pure Show / Hide Hover Timing State Machine

public enum NotchPanelTransition: Equatable, Sendable {
    case none
    case show(anchor: NotchPanelAnchor, screenIndex: Int)
    case hide
}

public struct NotchPanelTimingConfig: Equatable, Sendable {
    public var topHoverDwell: TimeInterval
    public var leftEdgeHoverDwell: TimeInterval
    public var pointerExitDelay: TimeInterval

    public init(
        topHoverDwell: TimeInterval = 0.14,
        leftEdgeHoverDwell: TimeInterval = 0.18,
        pointerExitDelay: TimeInterval = 0.12
    ) {
        self.topHoverDwell = max(0, topHoverDwell)
        self.leftEdgeHoverDwell = max(0, leftEdgeHoverDwell)
        self.pointerExitDelay = max(0, pointerExitDelay)
    }
}

public struct NotchPanelHoverStateMachine: Equatable, Sendable {
    public struct PendingHover: Equatable, Sendable {
        public var anchor: NotchPanelAnchor
        public var screenIndex: Int
        public var enteredAt: TimeInterval

        public init(anchor: NotchPanelAnchor, screenIndex: Int, enteredAt: TimeInterval) {
            self.anchor = anchor
            self.screenIndex = screenIndex
            self.enteredAt = enteredAt
        }
    }

    public struct VisibleSession: Equatable, Sendable {
        public var anchor: NotchPanelAnchor
        public var screenIndex: Int
        public var pointerExitedAt: TimeInterval?

        public init(anchor: NotchPanelAnchor, screenIndex: Int, pointerExitedAt: TimeInterval? = nil) {
            self.anchor = anchor
            self.screenIndex = screenIndex
            self.pointerExitedAt = pointerExitedAt
        }
    }

    public var config: NotchPanelTimingConfig
    public private(set) var pendingHover: PendingHover?
    public private(set) var visibleSession: VisibleSession?

    /// After an explicit dismiss (e.g. Escape or tile action), suppresses immediate re-trigger
    /// while the pointer remains parked in the same trigger rect until the pointer leaves it once.
    public private(set) var suppressedTriggerUntilExit: Bool = false

    public init(config: NotchPanelTimingConfig = NotchPanelTimingConfig()) {
        self.config = config
    }

    public var isVisible: Bool {
        visibleSession != nil
    }

    public mutating func dismissImmediately(suppressUntilTriggerExit: Bool = true) -> NotchPanelTransition {
        let wasVisible = (visibleSession != nil)
        pendingHover = nil
        visibleSession = nil
        if suppressUntilTriggerExit {
            suppressedTriggerUntilExit = true
        }
        return wasVisible ? .hide : .none
    }

    public mutating func step(
        pointerLocation: CGPoint,
        screens: [NotchScreenMetrics],
        isPanelEnabled: Bool,
        isLeftEdgeEnabled: Bool,
        isFullScreenSuppressed: Bool,
        isMouseButtonPressed: Bool,
        currentPanelFrame: CGRect?,
        now: TimeInterval
    ) -> NotchPanelTransition {
        guard isPanelEnabled && !isFullScreenSuppressed && !screens.isEmpty else {
            return dismissImmediately(suppressUntilTriggerExit: false)
        }

        if var session = visibleSession {
            guard screens.indices.contains(session.screenIndex),
                  let panelFrame = currentPanelFrame else {
                return dismissImmediately(suppressUntilTriggerExit: false)
            }

            let screen = screens[session.screenIndex]
            let inside = NotchPanelLayout.keepAliveContains(
                point: pointerLocation,
                anchor: session.anchor,
                panelFrame: panelFrame,
                screen: screen
            )

            if inside {
                session.pointerExitedAt = nil
                visibleSession = session
                return .none
            }

            if let exitedAt = session.pointerExitedAt {
                if now - exitedAt >= config.pointerExitDelay {
                    visibleSession = nil
                    pendingHover = nil
                    return .hide
                }
                return .none
            } else {
                session.pointerExitedAt = now
                visibleSession = session
                if config.pointerExitDelay == 0 {
                    visibleSession = nil
                    return .hide
                }
                return .none
            }
        }

        // Not currently visible: avoid opening while dragging windows/selections.
        if isMouseButtonPressed {
            pendingHover = nil
            return .none
        }

        let matchedHit = Self.hitTestTrigger(
            pointerLocation: pointerLocation,
            screens: screens,
            isLeftEdgeEnabled: isLeftEdgeEnabled
        )

        if suppressedTriggerUntilExit {
            if matchedHit == nil {
                suppressedTriggerUntilExit = false
            } else {
                pendingHover = nil
                return .none
            }
        }

        guard let hit = matchedHit else {
            pendingHover = nil
            return .none
        }

        let requiredDwell: TimeInterval = (hit.anchor == .topNotch)
            ? config.topHoverDwell
            : config.leftEdgeHoverDwell

        if let pending = pendingHover,
           pending.anchor == hit.anchor,
           pending.screenIndex == hit.screenIndex {
            if now - pending.enteredAt >= requiredDwell {
                pendingHover = nil
                visibleSession = VisibleSession(anchor: hit.anchor, screenIndex: hit.screenIndex)
                return .show(anchor: hit.anchor, screenIndex: hit.screenIndex)
            }
            return .none
        } else {
            if requiredDwell == 0 {
                pendingHover = nil
                visibleSession = VisibleSession(anchor: hit.anchor, screenIndex: hit.screenIndex)
                return .show(anchor: hit.anchor, screenIndex: hit.screenIndex)
            }
            pendingHover = PendingHover(anchor: hit.anchor, screenIndex: hit.screenIndex, enteredAt: now)
            return .none
        }
    }

    /// Next timer wakeup interval needed when dwelling or waiting for pointer-exit grace, or `nil` when idle.
    public func nextWakeupDelay(now: TimeInterval? = nil) -> TimeInterval? {
        if let pending = pendingHover {
            let total = (pending.anchor == .topNotch) ? config.topHoverDwell : config.leftEdgeHoverDwell
            if let now {
                return max(0.01, total - max(0, now - pending.enteredAt))
            }
            return total
        }
        if visibleSession != nil {
            return max(0.05, min(0.08, config.pointerExitDelay))
        }
        return nil
    }

    public static func hitTestTrigger(
        pointerLocation: CGPoint,
        screens: [NotchScreenMetrics],
        isLeftEdgeEnabled: Bool
    ) -> (anchor: NotchPanelAnchor, screenIndex: Int)? {
        for (idx, screen) in screens.enumerated() {
            let topRect = NotchPanelLayout.topTriggerRect(for: screen)
            if NotchPanelLayout.rectContainsInclusive(topRect, point: pointerLocation) {
                return (.topNotch, idx)
            }
            if isLeftEdgeEnabled {
                let leftRect = NotchPanelLayout.leftEdgeTriggerRect(for: screen)
                if NotchPanelLayout.rectContainsInclusive(leftRect, point: pointerLocation) {
                    return (.leftEdge, idx)
                }
            }
        }
        return nil
    }
}
