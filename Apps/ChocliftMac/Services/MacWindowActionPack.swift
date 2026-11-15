import AppKit
import ApplicationServices
import ChocliftCore
import Foundation

enum MacWindowActionPack {
    @MainActor
    private static let windowService = MacAccessibilityAndWindowService()

    @MainActor
    private static var frameStore = WindowPackFrameStore()

    static func run(id: String, preferredPID: pid_t?) -> (success: Bool, message: String) {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                runOnMainActor(id: id, preferredPID: preferredPID)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                runOnMainActor(id: id, preferredPID: preferredPID)
            }
        }
    }

    @MainActor
    private static func runOnMainActor(id: String, preferredPID: pid_t?) -> (success: Bool, message: String) {
        switch id {
        case WindowCompanionActionID.thirdsLeft:
            return snapThird(.left, preferredPID: preferredPID)
        case WindowCompanionActionID.thirdsCenter:
            return snapThird(.center, preferredPID: preferredPID)
        case WindowCompanionActionID.thirdsRight:
            return snapThird(.right, preferredPID: preferredPID)
        case WindowCompanionActionID.almostMaximize:
            return snapAlmostMaximize(preferredPID: preferredPID)
        case WindowCompanionActionID.restorePreviousFrame:
            return restorePreviousFrame()
        case WindowCompanionActionID.leftScreen:
            return moveToNeighborScreen(direction: .left, preferredPID: preferredPID)
        case WindowCompanionActionID.rightScreen:
            return moveToNeighborScreen(direction: .right, preferredPID: preferredPID)
        case WindowCompanionActionID.minimizeAllOthers:
            return minimizeOtherWindowsOfFrontmostApp(preferredPID: preferredPID)
        case WindowCompanionActionID.zoom:
            return zoomFrontmostWindow(preferredPID: preferredPID)
        case WindowCompanionActionID.centerHorizontally:
            return centerHorizontally(preferredPID: preferredPID)
        case WindowCompanionActionID.twoThirdsLeft:
            return snapTwoThirds(.left, preferredPID: preferredPID)
        case WindowCompanionActionID.twoThirdsRight:
            return snapTwoThirds(.right, preferredPID: preferredPID)
        case WindowCompanionActionID.topHalf:
            return snapVerticalHalf(.top, preferredPID: preferredPID)
        case WindowCompanionActionID.bottomHalf:
            return snapVerticalHalf(.bottom, preferredPID: preferredPID)
        default:
            return (false, L10n.tr("不支持此窗口操作：\(id)", "Unsupported window action: \(id)"))
        }
    }

    @MainActor
    private static func snapTwoThirds(
        _ side: WindowTwoThirdsSide,
        preferredPID: pid_t?
    ) -> (success: Bool, message: String) {
        applySnapSavingPreviousFrame(preferredPID: preferredPID) { _, _, appName, _, visibleQuartz, _, _, _ in
            let target = WindowPackGeometry.twoThirdsFrame(for: side, visibleQuartz: visibleQuartz)
            let summary: String
            switch side {
            case .left:
                summary = L10n.tr("已将 \(appName) 贴靠左三分之二", "Snapped \(appName) to left two-thirds")
            case .right:
                summary = L10n.tr("已将 \(appName) 贴靠右三分之二", "Snapped \(appName) to right two-thirds")
            }
            return .success((frame: target, message: summary))
        }
    }

    @MainActor
    private static func snapVerticalHalf(
        _ half: WindowVerticalHalf,
        preferredPID: pid_t?
    ) -> (success: Bool, message: String) {
        applySnapSavingPreviousFrame(preferredPID: preferredPID) { _, _, appName, _, visibleQuartz, _, _, _ in
            let target = WindowPackGeometry.halfFrame(for: half, visibleQuartz: visibleQuartz)
            let summary: String
            switch half {
            case .top:
                summary = L10n.tr("已将 \(appName) 贴靠上半屏", "Snapped \(appName) to top half")
            case .bottom:
                summary = L10n.tr("已将 \(appName) 贴靠下半屏", "Snapped \(appName) to bottom half")
            }
            return .success((frame: target, message: summary))
        }
    }

    @MainActor
    private static func snapThird(
        _ column: WindowThirdColumn,
        preferredPID: pid_t?
    ) -> (success: Bool, message: String) {
        applySnapSavingPreviousFrame(preferredPID: preferredPID) { _, _, appName, _, visibleQuartz, _, _, _ in
            let target = WindowPackGeometry.thirdFrame(for: column, visibleQuartz: visibleQuartz)
            let summary: String
            switch column {
            case .left:
                summary = L10n.tr("已将 \(appName) 贴靠左三分之一", "Snapped \(appName) to left third")
            case .center:
                summary = L10n.tr("已将 \(appName) 贴靠中三分之一", "Snapped \(appName) to center third")
            case .right:
                summary = L10n.tr("已将 \(appName) 贴靠右三分之一", "Snapped \(appName) to right third")
            }
            return .success((frame: target, message: summary))
        }
    }

    @MainActor
    private static func snapAlmostMaximize(preferredPID: pid_t?) -> (success: Bool, message: String) {
        applySnapSavingPreviousFrame(preferredPID: preferredPID) { _, _, appName, _, visibleQuartz, _, _, _ in
            let target = WindowPackGeometry.almostMaximizedFrame(visibleQuartz: visibleQuartz)
            return .success((
                frame: target,
                message: L10n.tr("已留边最大化 \(appName) 窗口", "Almost-maximized \(appName) window")
            ))
        }
    }

    @MainActor
    private static func centerHorizontally(preferredPID: pid_t?) -> (success: Bool, message: String) {
        applySnapSavingPreviousFrame(preferredPID: preferredPID) { _, _, appName, currentFrame, visibleQuartz, _, _, _ in
            let target = WindowPackGeometry.horizontallyCenteredFrame(
                currentFrame: currentFrame,
                visibleQuartz: visibleQuartz
            )
            return .success((
                frame: target,
                message: L10n.tr("已将 \(appName) 窗口水平居中", "Centered \(appName) window horizontally")
            ))
        }
    }

    @MainActor
    private static func moveToNeighborScreen(
        direction: WindowScreenDirection,
        preferredPID: pid_t?
    ) -> (success: Bool, message: String) {
        applySnapSavingPreviousFrame(preferredPID: preferredPID) { _, _, appName, currentFrame, _, quartzScreens, screenNames, allowResize in
            guard let plan = WindowPackGeometry.directionalDisplayTargetFrame(
                direction: direction,
                windowQuartzFrame: currentFrame,
                quartzScreens: quartzScreens,
                allowResize: allowResize
            ) else {
                let err: WindowPackScreenMoveError = direction == .left ? .noDisplayOnLeft : .noDisplayOnRight
                return .failure(WindowPackFrameError(err.message()))
            }
            let fallbackName = direction == .left
                ? L10n.tr("左侧显示器", "Left Display")
                : L10n.tr("右侧显示器", "Right Display")
            let destination = screenNames.indices.contains(plan.targetScreenIndex)
                ? screenNames[plan.targetScreenIndex]
                : fallbackName
            return .success((
                frame: plan.targetFrame,
                message: L10n.tr(
                    "已将 \(appName) 窗口移至 \(destination)",
                    "Moved \(appName) window to \(destination)"
                )
            ))
        }
    }

    @MainActor
    private static func applySnapSavingPreviousFrame(
        preferredPID: pid_t?,
        resolveFrame: (
            _ pid: pid_t,
            _ windowKey: String,
            _ appName: String,
            _ currentFrame: CGRect,
            _ visibleQuartz: CGRect,
            _ quartzScreens: [QuartzScreenBounds],
            _ screenNames: [String],
            _ allowResize: Bool
        ) -> Result<(frame: CGRect, message: String), WindowPackFrameError>
    ) -> (success: Bool, message: String) {
        var capturedBeforeSnap: (pid: pid_t, windowKey: String, appName: String, frame: CGRect)?
        let outcome = windowService.applyCompanionWindowFrame(preferredPID: preferredPID) {
            pid, windowKey, appName, currentFrame, visibleQuartz, quartzScreens, screenNames, allowResize in
            capturedBeforeSnap = (pid, windowKey, appName, currentFrame)
            return resolveFrame(
                pid,
                windowKey,
                appName,
                currentFrame,
                visibleQuartz,
                quartzScreens,
                screenNames,
                allowResize
            )
        }
        if outcome.success, let captured = capturedBeforeSnap {
            frameStore.recordSuccessfulSnap(
                windowKey: captured.windowKey,
                pid: Int32(captured.pid),
                appName: captured.appName,
                previousFrame: captured.frame
            )
        }
        return outcome
    }

    @MainActor
    private static func restorePreviousFrame() -> (success: Bool, message: String) {
        let outcome = frameStore.restorePreviousFrame { saved in
            windowService.applyCompanionWindowFrame(
                preferredPID: pid_t(saved.pid),
                strictTargetPID: true,
                targetWindowKey: saved.windowKey
            ) { _, _, appName, _, _, _, _, _ in
                .success((
                    frame: saved.previousFrame.cgRect,
                    message: L10n.tr("已还原 \(appName) 窗口位置", "Restored \(appName) window frame")
                ))
            }
        }
        switch outcome {
        case .success(let summary):
            return (true, summary)
        case .failure(let error):
            return (false, error.message())
        }
    }

    @MainActor
    private static func minimizeOtherWindowsOfFrontmostApp(preferredPID: pid_t?) -> (success: Bool, message: String) {
        guard windowService.isAccessibilityTrusted() else {
            _ = windowService.promptForAccessibilityPermission()
            return (
                false,
                L10n.tr(
                    "请在系统设置 → 辅助功能中授权 Choclift 控制窗口",
                    "Grant Accessibility permission in System Settings to control windows"
                )
            )
        }

        guard let app = resolveExternalTargetApp(preferredPID: preferredPID) else {
            return (false, L10n.tr("当前没有可用的前台应用窗口", "No active frontmost application found"))
        }

        let appName = app.localizedName ?? app.bundleIdentifier ?? "App"
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var listRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &listRef) == .success,
              let allWindows = listRef as? [AXUIElement],
              !allWindows.isEmpty else {
            return (false, L10n.tr("\(appName) 当前没有打开的窗口", "No open windows in \(appName)"))
        }

        let activeWindow = resolveActiveOpenWindow(for: appElement, windows: allWindows)
        guard let activeWindow else {
            return (false, L10n.tr("\(appName) 当前没有打开的窗口", "No open windows in \(appName)"))
        }

        let otherOpenWindows = allWindows.filter { candidate in
            !CFEqual(candidate, activeWindow) && isOpenStandardWindow(candidate)
        }
        guard !otherOpenWindows.isEmpty else {
            return (
                true,
                L10n.tr(
                    "\(appName) 没有其他需要最小化的窗口",
                    "No other open windows to minimize in \(appName)"
                )
            )
        }

        var minimizedCount = 0
        for win in otherOpenWindows {
            if AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
                minimizedCount += 1
            }
        }

        guard minimizedCount > 0 else {
            return (
                false,
                L10n.tr(
                    "\(appName) 的其他窗口不支持最小化",
                    "Other \(appName) windows cannot be minimized"
                )
            )
        }

        return (
            true,
            L10n.tr(
                "已最小化 \(appName) 的其他 \(minimizedCount) 个窗口",
                "Minimized \(minimizedCount) other \(appName) window\(minimizedCount == 1 ? "" : "s")"
            )
        )
    }

    /// Prefers green-button AX zoom (`AXZoomWindow` or non-fullscreen `AXZoomButton` `AXPress`);
    /// falls back to `performWindowOperation(.maximizeOrRestore)` to avoid opening a fullscreen Space.
    @MainActor
    private static func zoomFrontmostWindow(preferredPID: pid_t?) -> (success: Bool, message: String) {
        guard windowService.isAccessibilityTrusted() else {
            _ = windowService.promptForAccessibilityPermission()
            return (
                false,
                L10n.tr(
                    "请在系统设置 → 辅助功能中授权 Choclift 控制窗口",
                    "Grant Accessibility permission in System Settings to control windows"
                )
            )
        }

        guard let app = resolveExternalTargetApp(preferredPID: preferredPID) else {
            return (false, L10n.tr("未找到活动窗口", "No active application found"))
        }

        let appName = app.localizedName ?? app.bundleIdentifier ?? "App"
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var listRef: CFTypeRef?
        let windows = (AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &listRef) == .success)
            ? (listRef as? [AXUIElement] ?? [])
            : []
        guard let windowElement = resolveActiveOpenWindow(for: appElement, windows: windows) ?? windows.first else {
            return (false, L10n.tr("\(appName) 当前没有可调整的窗口", "No adjustable window in \(appName)"))
        }

        if let zoomMethod = performAXGreenButtonZoomIfNonFullscreen(on: windowElement) {
            return (
                true,
                L10n.tr(
                    "已通过 \(zoomMethod) 切换 \(appName) 窗口缩放",
                    "Toggled \(appName) window zoom via \(zoomMethod)"
                )
            )
        }

        let fallback = windowService.performWindowOperation(
            .maximizeOrRestore,
            preferredPID: app.processIdentifier,
            strictTargetPID: true
        )
        guard fallback.success else {
            return fallback
        }
        return (
            true,
            L10n.tr(
                "AX 绿色缩放不可用（避免新建全屏空间），已通过最大化/还原路径调整 \(appName) 窗口",
                "AX zoom unavailable without fullscreen Space; used maximize/restore AX frame path for \(appName)"
            )
        )
    }

    private static func performAXGreenButtonZoomIfNonFullscreen(on windowElement: AXUIElement) -> String? {
        var zoomRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXZoomButtonAttribute as CFString, &zoomRef) == .success,
              let zoomRef,
              CFGetTypeID(zoomRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let zoomButton = zoomRef as! AXUIElement

        var enabledRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(zoomButton, kAXEnabledAttribute as CFString, &enabledRef) == .success,
           let isEnabled = enabledRef as? Bool,
           !isEnabled {
            return nil
        }

        var actionsRef: CFArray?
        if AXUIElementCopyActionNames(zoomButton, &actionsRef) == .success,
           let actions = actionsRef as? [String],
           actions.contains("AXZoomWindow"),
           AXUIElementPerformAction(zoomButton, "AXZoomWindow" as CFString) == .success {
            return "AXZoomWindow"
        }

        var subroleRef: CFTypeRef?
        let subrole = (AXUIElementCopyAttributeValue(zoomButton, kAXSubroleAttribute as CFString, &subroleRef) == .success)
            ? (subroleRef as? String)
            : nil
        var fsButtonRef: CFTypeRef?
        let isSameAsFullScreenButton: Bool = {
            guard AXUIElementCopyAttributeValue(windowElement, kAXFullScreenButtonAttribute as CFString, &fsButtonRef) == .success,
                  let fsButtonRef,
                  CFGetTypeID(fsButtonRef) == AXUIElementGetTypeID() else {
                return false
            }
            return CFEqual(zoomButton, fsButtonRef)
        }()

        if subrole == (kAXZoomButtonSubrole as String),
           !isSameAsFullScreenButton,
           AXUIElementPerformAction(zoomButton, kAXPressAction as CFString) == .success {
            return "AXZoomButton"
        }

        return nil
    }

    private static func resolveExternalTargetApp(preferredPID: pid_t?) -> NSRunningApplication? {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfBundleID = Bundle.main.bundleIdentifier
        func isEligible(_ app: NSRunningApplication) -> Bool {
            guard !app.isTerminated,
                  app.processIdentifier != selfPID,
                  app.bundleIdentifier != "com.apple.loginwindow",
                  app.bundleIdentifier != "com.choclift.mac" else {
                return false
            }
            if let selfBundleID, app.bundleIdentifier == selfBundleID {
                return false
            }
            return true
        }

        if let front = NSWorkspace.shared.frontmostApplication, isEligible(front) {
            return front
        }
        if let preferredPID,
           let app = NSRunningApplication(processIdentifier: preferredPID),
           isEligible(app) {
            return app
        }
        return nil
    }

    private static func isOpenStandardWindow(_ window: AXUIElement) -> Bool {
        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
           let isMinimized = minRef as? Bool,
           isMinimized {
            return false
        }
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            return role == (kAXWindowRole as String)
        }
        return true
    }

    private static func resolveActiveOpenWindow(
        for appElement: AXUIElement,
        windows: [AXUIElement]
    ) -> AXUIElement? {
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let focusedRef,
           CFGetTypeID(focusedRef) == AXUIElementGetTypeID(),
           isOpenStandardWindow(focusedRef as! AXUIElement) {
            return (focusedRef as! AXUIElement)
        }

        var mainRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainRef) == .success,
           let mainRef,
           CFGetTypeID(mainRef) == AXUIElementGetTypeID(),
           isOpenStandardWindow(mainRef as! AXUIElement) {
            return (mainRef as! AXUIElement)
        }

        return windows.first(where: isOpenStandardWindow)
    }
}
