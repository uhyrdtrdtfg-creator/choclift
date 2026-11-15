import CoreGraphics
import Foundation

public enum WindowCompanionActionID {
    public static let thirdsLeft = "window.thirds_left"
    public static let thirdsCenter = "window.thirds_center"
    public static let thirdsRight = "window.thirds_right"
    public static let almostMaximize = "window.almost_maximize"
    public static let restorePreviousFrame = "window.restore_previous_frame"
    public static let leftScreen = "window.left_screen"
    public static let rightScreen = "window.right_screen"
    public static let minimizeAllOthers = "window.minimize_all_others"
    public static let zoom = "window.zoom"
    public static let centerHorizontally = "window.center_horizontally"
}

extension CompanionActionCatalog {
    public static let windowPack: [CompanionAction] = [
        CompanionAction(
            id: WindowCompanionActionID.thirdsLeft,
            titleZh: "窗口左三分之一",
            titleEn: "Left Third",
            sfSymbol: "rectangle.leftthird.inset.filled"
        ),
        CompanionAction(
            id: WindowCompanionActionID.thirdsCenter,
            titleZh: "窗口中三分之一",
            titleEn: "Center Third",
            sfSymbol: "rectangle.split.3x1"
        ),
        CompanionAction(
            id: WindowCompanionActionID.thirdsRight,
            titleZh: "窗口右三分之一",
            titleEn: "Right Third",
            sfSymbol: "rectangle.rightthird.inset.filled"
        ),
        CompanionAction(
            id: WindowCompanionActionID.almostMaximize,
            titleZh: "留边最大化",
            titleEn: "Almost Maximize",
            sfSymbol: "rectangle.inset.filled"
        ),
        CompanionAction(
            id: WindowCompanionActionID.restorePreviousFrame,
            titleZh: "还原上次窗口位置",
            titleEn: "Restore Previous Frame",
            sfSymbol: "arrow.uturn.backward.square"
        ),
        CompanionAction(
            id: WindowCompanionActionID.leftScreen,
            titleZh: "移至左侧显示器",
            titleEn: "Move to Left Display",
            sfSymbol: "rectangle.lefthalf.inset.filled.arrow.left"
        ),
        CompanionAction(
            id: WindowCompanionActionID.rightScreen,
            titleZh: "移至右侧显示器",
            titleEn: "Move to Right Display",
            sfSymbol: "rectangle.righthalf.inset.filled.arrow.right"
        ),
        CompanionAction(
            id: WindowCompanionActionID.minimizeAllOthers,
            titleZh: "最小化其他窗口",
            titleEn: "Minimize Other Windows",
            sfSymbol: "macwindow.on.rectangle"
        ),
        CompanionAction(
            id: WindowCompanionActionID.zoom,
            titleZh: "缩放窗口",
            titleEn: "Zoom Window",
            sfSymbol: "arrow.up.left.and.arrow.down.right.circle"
        ),
        CompanionAction(
            id: WindowCompanionActionID.centerHorizontally,
            titleZh: "水平居中",
            titleEn: "Center Horizontally",
            sfSymbol: "align.horizontal.center.fill"
        )
    ]
}

public enum WindowThirdColumn: String, CaseIterable, Equatable, Sendable {
    case left
    case center
    case right
}

public enum WindowScreenDirection: String, CaseIterable, Equatable, Sendable {
    case left
    case right
}

public enum WindowPackScreenMoveError: Error, Equatable, Sendable, LocalizedError {
    case noDisplayOnLeft
    case noDisplayOnRight

    public var errorDescription: String? {
        message(in: .system)
    }

    public func message(in language: AppLanguage = .system) -> String {
        switch self {
        case .noDisplayOnLeft:
            return L10n.tr("左侧没有连接的显示器", "No display to the left", language: language)
        case .noDisplayOnRight:
            return L10n.tr("右侧没有连接的显示器", "No display to the right", language: language)
        }
    }
}

public enum WindowPackGeometry {
    public static let almostMaximizeInset: CGFloat = 24

    public static func thirdFrame(
        for column: WindowThirdColumn,
        visibleQuartz: CGRect
    ) -> CGRect {
        let leftEnd = floor(visibleQuartz.width / 3.0)
        let centerEnd = floor((visibleQuartz.width * 2.0) / 3.0)
        switch column {
        case .left:
            return CGRect(
                x: visibleQuartz.origin.x,
                y: visibleQuartz.origin.y,
                width: leftEnd,
                height: visibleQuartz.height
            )
        case .center:
            return CGRect(
                x: visibleQuartz.origin.x + leftEnd,
                y: visibleQuartz.origin.y,
                width: centerEnd - leftEnd,
                height: visibleQuartz.height
            )
        case .right:
            return CGRect(
                x: visibleQuartz.origin.x + centerEnd,
                y: visibleQuartz.origin.y,
                width: visibleQuartz.width - centerEnd,
                height: visibleQuartz.height
            )
        }
    }

    public static func almostMaximizedFrame(
        visibleQuartz: CGRect,
        inset: CGFloat = almostMaximizeInset
    ) -> CGRect {
        let clampedWidth = max(1, visibleQuartz.width - inset * 2.0)
        let clampedHeight = max(1, visibleQuartz.height - inset * 2.0)
        let originX = visibleQuartz.width > inset * 2.0
            ? visibleQuartz.origin.x + inset
            : round(visibleQuartz.midX - clampedWidth / 2.0)
        let originY = visibleQuartz.height > inset * 2.0
            ? visibleQuartz.origin.y + inset
            : round(visibleQuartz.midY - clampedHeight / 2.0)
        return CGRect(x: originX, y: originY, width: clampedWidth, height: clampedHeight)
    }

    public static func horizontallyCenteredFrame(
        currentFrame: CGRect,
        visibleQuartz: CGRect
    ) -> CGRect {
        CGRect(
            x: round(visibleQuartz.origin.x + (visibleQuartz.width - currentFrame.width) / 2.0),
            y: currentFrame.origin.y,
            width: currentFrame.width,
            height: currentFrame.height
        )
    }

    public static func directionalDisplayTargetFrame(
        direction: WindowScreenDirection,
        windowQuartzFrame: CGRect,
        quartzScreens: [QuartzScreenBounds],
        allowResize: Bool = true
    ) -> NextDisplayTargetPlan? {
        guard quartzScreens.count >= 2,
              let sourceIndex = WindowDisplayGeometry.sourceScreenIndex(for: windowQuartzFrame, in: quartzScreens) else {
            return nil
        }

        let sourceBounds = quartzScreens[sourceIndex]
        let targetIndex: Int?
        switch direction {
        case .left:
            targetIndex = quartzScreens.enumerated()
                .filter { idx, candidate in
                    idx != sourceIndex &&
                    candidate.frame.midX < sourceBounds.frame.midX &&
                    candidate.frame.maxX <= sourceBounds.frame.midX
                }
                .max(by: { $0.element.frame.midX < $1.element.frame.midX })?
                .offset
        case .right:
            targetIndex = quartzScreens.enumerated()
                .filter { idx, candidate in
                    idx != sourceIndex &&
                    candidate.frame.midX > sourceBounds.frame.midX &&
                    candidate.frame.minX >= sourceBounds.frame.midX
                }
                .min(by: { $0.element.frame.midX < $1.element.frame.midX })?
                .offset
        }

        guard let targetIndex else {
            return nil
        }

        let sourceVisible = sourceBounds.visibleFrame
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

    public static func directionalDisplayTargetFrame(
        direction: WindowScreenDirection,
        windowQuartzFrame: CGRect,
        quartzVisibleFrames: [CGRect],
        allowResize: Bool = true
    ) -> NextDisplayTargetPlan? {
        let screens = quartzVisibleFrames.map { QuartzScreenBounds(frame: $0, visibleFrame: $0) }
        return directionalDisplayTargetFrame(
            direction: direction,
            windowQuartzFrame: windowQuartzFrame,
            quartzScreens: screens,
            allowResize: allowResize
        )
    }

    public static func directionalDisplayTargetFrame(
        direction: WindowScreenDirection,
        windowQuartzFrame: CGRect,
        appKitScreens: [WindowScreenDescriptor],
        allowResize: Bool = true
    ) -> NextDisplayTargetPlan? {
        directionalDisplayTargetFrame(
            direction: direction,
            windowQuartzFrame: windowQuartzFrame,
            quartzScreens: WindowDisplayGeometry.quartzScreens(from: appKitScreens),
            allowResize: allowResize
        )
    }
}

public struct WindowPackFrameError: Error, Equatable, Sendable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public struct WindowPackSavedFrame: Equatable, Sendable {
    public let windowKey: String
    public let pid: Int32
    public let appName: String
    public let previousFrame: WindowQuartzRect

    public init(windowKey: String, pid: Int32, appName: String, previousFrame: CGRect) {
        self.windowKey = windowKey
        self.pid = pid
        self.appName = appName
        self.previousFrame = WindowQuartzRect(previousFrame)
    }
}

public enum WindowPackRestoreError: Error, Equatable, Sendable, LocalizedError {
    case noSavedFrame
    case windowUnavailable(message: String)

    public var errorDescription: String? {
        message(in: .system)
    }

    public func message(in language: AppLanguage = .system) -> String {
        switch self {
        case .noSavedFrame:
            return L10n.tr(
                "尚无已保存的窗口位置可供还原",
                "No previous window frame saved",
                language: language
            )
        case .windowUnavailable(let msg):
            return msg
        }
    }
}

public struct WindowPackFrameStore: Equatable, Sendable {
    public private(set) var lastSavedFrame: WindowPackSavedFrame?

    public init() {}

    public mutating func recordSuccessfulSnap(
        windowKey: String,
        pid: Int32,
        appName: String,
        previousFrame: CGRect
    ) {
        lastSavedFrame = WindowPackSavedFrame(
            windowKey: windowKey,
            pid: pid,
            appName: appName,
            previousFrame: previousFrame
        )
    }

    public mutating func restorePreviousFrame(
        apply: (WindowPackSavedFrame) -> (success: Bool, message: String)
    ) -> Result<String, WindowPackRestoreError> {
        guard let saved = lastSavedFrame else {
            return .failure(.noSavedFrame)
        }
        let outcome = apply(saved)
        if outcome.success {
            lastSavedFrame = nil
            return .success(outcome.message)
        }
        return .failure(.windowUnavailable(message: outcome.message))
    }

    public mutating func clear() {
        lastSavedFrame = nil
    }
}
