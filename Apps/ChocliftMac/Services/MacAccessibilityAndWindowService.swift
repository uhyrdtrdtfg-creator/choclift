import AppKit
import ApplicationServices
import ChocliftCore
import Foundation

@MainActor
public final class MacAccessibilityAndWindowService {
    public enum WindowUndoOutcome: Equatable {
        case nothingToUndo
        case restored(summary: String)
    }

    private struct RetainedWindowUndoTarget {
        let pid: pid_t
        let windowElement: AXUIElement
        let appName: String
    }

    private struct CachedFrontmostWindowTarget {
        let pid: pid_t
        let appName: String
        let title: String
        let index: Int
        let element: AXUIElement
    }

    public var onUndoAvailabilityChanged: (() -> Void)?
    public var onDisplayConfigurationChanged: (() -> Void)?
    public private(set) var selectedTargetDisplayID: CGDirectDisplayID?

    private var previousWindowFrames: [String: CGRect] = [:]
    private var moveCoordinator = WindowMoveCoordinator<String>()
    private var retainedUndoTargets: [String: RetainedWindowUndoTarget] = [:]
    private var cachedFrontmostWindowTargets: [String: CachedFrontmostWindowTarget] = [:]
    private var screenObserverToken: NSObjectProtocol?

    public init() {
        screenObserverToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcileSelectedTargetDisplay()
                self.onDisplayConfigurationChanged?()
            }
        }
    }

    deinit {
        if let screenObserverToken {
            NotificationCenter.default.removeObserver(screenObserverToken)
        }
    }

    public func currentConnectedDisplays() -> [MacDisplayInfo] {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen in
            guard let id = Self.displayID(for: screen) else { return nil }
            return MacDisplayInfo(
                displayID: id,
                name: screen.localizedName,
                isMain: id == mainID
            )
        }
    }

    public func setTargetDisplayID(_ displayID: UInt32?) {
        let resolved = DisplaySnapTargetResolver.resolvedTargetDisplayID(
            selectedDisplayID: displayID,
            connectedDisplays: currentConnectedDisplays()
        )
        guard selectedTargetDisplayID != resolved else { return }
        selectedTargetDisplayID = resolved
        onDisplayConfigurationChanged?()
    }

    private func reconcileSelectedTargetDisplay() {
        let resolved = DisplaySnapTargetResolver.resolvedTargetDisplayID(
            selectedDisplayID: selectedTargetDisplayID,
            connectedDisplays: currentConnectedDisplays()
        )
        if selectedTargetDisplayID != resolved {
            selectedTargetDisplayID = resolved
        }
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDirectDisplayID(num.uint32Value)
        }
        return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func screen(forDisplayID targetID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(for: $0) == targetID }
    }

    public var lastWindowMove: WindowMoveSnapshot<String>? {
        moveCoordinator.lastWindowMove
    }

    public var canUndoLastWindowMove: Bool {
        moveCoordinator.canUndo
    }

    public func beginWindowUndoTransaction() {
        moveCoordinator.beginTransaction()
    }

    public func commitWindowUndoTransaction() {
        let didReplace = moveCoordinator.commitTransaction()
        if didReplace {
            let activeIDs = Set(moveCoordinator.lastEntry?.map(\.windowID) ?? [])
            retainedUndoTargets = retainedUndoTargets.filter { activeIDs.contains($0.key) }
            onUndoAvailabilityChanged?()
        } else {
            let activeIDs = Set(moveCoordinator.lastEntry?.map(\.windowID) ?? [])
            retainedUndoTargets = retainedUndoTargets.filter { activeIDs.contains($0.key) }
        }
    }

    private func registerRetainedUndoTargetAfterMove(
        windowKey: String,
        pid: pid_t,
        windowElement: AXUIElement,
        appName: String
    ) {
        if moveCoordinator.isInTransaction {
            if retainedUndoTargets[windowKey] == nil {
                retainedUndoTargets[windowKey] = RetainedWindowUndoTarget(
                    pid: pid,
                    windowElement: windowElement,
                    appName: appName
                )
            }
        } else {
            retainedUndoTargets = [
                windowKey: RetainedWindowUndoTarget(
                    pid: pid,
                    windowElement: windowElement,
                    appName: appName
                )
            ]
            onUndoAvailabilityChanged?()
        }
    }

    private func recordWindowMoveForUndo(
        windowKey: String,
        pid: pid_t,
        windowElement: AXUIElement,
        appName: String,
        previousFrame: CGRect
    ) {
        moveCoordinator.recordMove(
            windowID: windowKey,
            appName: appName,
            previousFrame: WindowQuartzRect(previousFrame)
        )
        registerRetainedUndoTargetAfterMove(
            windowKey: windowKey,
            pid: pid,
            windowElement: windowElement,
            appName: appName
        )
    }

    /// Restores the single most recent window move (or multi-window split flow move).
    /// One level only; returns `.nothingToUndo` quietly when empty or when target windows are gone.
    public func undoLastWindowMove(language: AppLanguage = .system) -> WindowUndoOutcome {
        guard let snapshots = moveCoordinator.popUndoEntry(), !snapshots.isEmpty else {
            return .nothingToUndo
        }
        let targets = retainedUndoTargets
        retainedUndoTargets.removeAll()
        onUndoAvailabilityChanged?()

        guard AXIsProcessTrusted() else {
            return .nothingToUndo
        }

        var restoredNames: [String] = []
        for snapshot in snapshots {
            guard let target = targets[snapshot.windowID],
                  let runningApp = NSRunningApplication(processIdentifier: target.pid),
                  !runningApp.isTerminated else {
                continue
            }
            let sizeSettable = isAttributeSettable(kAXSizeAttribute as String, on: target.windowElement)
            if case .success = writeWindowQuartzFrameResult(
                target.windowElement,
                frame: snapshot.previousFrame.cgRect,
                applySize: sizeSettable
            ) {
                previousWindowFrames.removeValue(forKey: snapshot.windowID)
                let cleanName = snapshot.appName.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = cleanName.isEmpty ? (runningApp.localizedName ?? "App") : cleanName
                if !restoredNames.contains(displayName) {
                    restoredNames.append(displayName)
                }
            }
        }

        guard !restoredNames.isEmpty else {
            return .nothingToUndo
        }

        let joinedNames = restoredNames.joined(separator: " · ")
        let summary = L10n.tr(
            "已还原 \(joinedNames) 窗口位置",
            "Restored \(joinedNames) window",
            language: language
        )
        return .restored(summary: summary)
    }

    // MARK: - Permissions

    public func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    public func promptForAccessibilityPermission() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return trusted
    }

    /// Reads selection directly from the frontmost app; never copies via the pasteboard.
    public func readFrontmostSelection() throws -> OrcaSelection {
        guard AXIsProcessTrusted() else {
            _ = promptForAccessibilityPermission()
            throw OrcaSelectionError.unavailable(L10n.tr("请在系统设置 → 辅助功能中授权 Choclift", "Grant Accessibility permission in System Settings"))
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw OrcaSelectionError.emptySelection
        }
        var focused: CFTypeRef?
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            throw OrcaSelectionError.emptySelection
        }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrcaSelectionError.emptySelection
        }
        return OrcaSelection(text: text, appName: app.localizedName ?? "App")
    }

    // MARK: - Text Field Focus Detection & AX Direct Text Insertion

    public struct FocusedTextInputTarget {
        public let element: AXUIElement
        public let appName: String?
        public let processIdentifier: pid_t

        public init(element: AXUIElement, appName: String?, processIdentifier: pid_t) {
            self.element = element
            self.appName = appName
            self.processIdentifier = processIdentifier
        }
    }

    public static let editableAXRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]

    public func isEditableTextElement(_ axElement: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        // Check AXEditable attribute for web/Electron inputs (Safari, Chrome, Arc, Electron)
        var editableRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, "AXEditable" as CFString, &editableRef) == .success,
           let isEditable = editableRef as? Bool {
            if isEditable {
                return true
            }
            var selectedSettable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(axElement, kAXSelectedTextAttribute as CFString, &selectedSettable) == .success,
               selectedSettable.boolValue {
                return true
            }
            return false
        }

        if Self.editableAXRoles.contains(role) {
            var selectedSettable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(axElement, kAXSelectedTextAttribute as CFString, &selectedSettable) == .success,
               selectedSettable.boolValue {
                return true
            }
            var valueSettable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &valueSettable) == .success,
               valueSettable.boolValue {
                return true
            }
            // Terminal emulators expose AXTextArea without settable AXSelectedText/AXValue.
            if role == (kAXTextAreaRole as String) {
                return true
            }
            return false
        }

        return false
    }

    public func focusedTextInput(excludingPID: pid_t? = nil) -> FocusedTextInputTarget? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        if let excludingPID, frontApp.processIdentifier == excludingPID {
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        if status == .success,
           let focusedElement = focusedRef,
           CFGetTypeID(focusedElement) == AXUIElementGetTypeID() {
            let axElement = focusedElement as! AXUIElement
            guard isEditableTextElement(axElement) else {
                return nil
            }
            return FocusedTextInputTarget(
                element: axElement,
                appName: frontApp.localizedName,
                processIdentifier: frontApp.processIdentifier
            )
        }

        return focusedTextInput(inApplicationPID: frontApp.processIdentifier, appName: frontApp.localizedName)
    }

    public func focusedTextInput(inApplicationPID pid: pid_t, appName: String? = nil) -> FocusedTextInputTarget? {
        guard AXIsProcessTrusted() else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
              let focusedElement = focusedRef,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return nil
        }
        let axElement = focusedElement as! AXUIElement
        guard isEditableTextElement(axElement) else {
            return nil
        }
        let resolvedName = appName ?? NSRunningApplication(processIdentifier: pid)?.localizedName
        return FocusedTextInputTarget(
            element: axElement,
            appName: resolvedName,
            processIdentifier: pid
        )
    }

    public func inspectFocusedTextInput(excludingPID: pid_t? = nil) -> (isEditing: Bool, appName: String?) {
        guard let target = focusedTextInput(excludingPID: excludingPID) else {
            return (false, nil)
        }
        return (true, target.appName)
    }

    /// Inserts text directly at the caret (or replaces the current selection) of a focused AX text input
    /// without touching `NSPasteboard`. Returns `false` if the element does not support `kAXSelectedTextAttribute`.
    public func insertTextViaAX(_ text: String, into element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &isSettable
        ) == .success,
              isSettable.boolValue else {
            return false
        }
        let status = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        return status == .success
    }

    // MARK: - Window Actions

    public enum WindowOperation {
        case maximizeOrRestore
        case minimize
        case snapLeft
        case snapRight
        case snapTopLeft
        case snapTopRight
        case snapBottomLeft
        case snapBottomRight
        case center
        case toggleFullscreen
        case moveToNextDisplay
    }

    public func hasAdjustableWindow(forPID pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        return resolveTargetWindow(for: appElement) != nil
    }

    @discardableResult
    public func performWindowOperation(
        _ op: WindowOperation,
        preferredPID: pid_t?,
        strictTargetPID: Bool = false
    ) -> (success: Bool, message: String) {
        guard AXIsProcessTrusted() else {
            _ = promptForAccessibilityPermission()
            return (false, L10n.tr("请在系统设置 → 辅助功能中授权 Choclift 控制窗口", "Grant Accessibility permission in System Settings to control windows"))
        }

        let targetApp: NSRunningApplication? = {
            if strictTargetPID {
                guard let preferredPID,
                      let app = NSRunningApplication(processIdentifier: preferredPID),
                      !app.isTerminated else {
                    return nil
                }
                return app
            }
            if let preferredPID,
               let app = NSRunningApplication(processIdentifier: preferredPID),
               !app.isTerminated {
                return app
            }
            return NSWorkspace.shared.frontmostApplication
        }()

        guard let app = targetApp else {
            if strictTargetPID {
                return (false, L10n.tr("目标应用未运行，已停止窗口操作", "Target application is not running; aborted window operation"))
            }
            return (false, L10n.tr("未找到活动窗口", "No active application found"))
        }

        if strictTargetPID && op != .minimize {
            unminimizeFirstWindowIfAllMinimized(pid: app.processIdentifier)
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windowElement: AXUIElement
        switch resolveTargetWindowResult(for: appElement) {
        case .window(let resolved):
            windowElement = resolved
        case .axFailure(let axErr):
            return (false, WindowAXErrorFormatting.moveFailureMessage(rawCode: axErr.rawValue))
        case .noWindow:
            return (false, L10n.tr("\(app.localizedName ?? "App") 当前没有可调整的窗口", "No adjustable window in \(app.localizedName ?? "app")"))
        }

        let appDisplayName = app.localizedName ?? "App"
        let windowKey = "\(app.processIdentifier)-\(CFHash(windowElement))"

        switch op {
        case .minimize:
            let err = AXUIElementSetAttributeValue(
                windowElement,
                kAXMinimizedAttribute as CFString,
                kCFBooleanTrue
            )
            return err == .success
                ? (true, L10n.tr("已最小化窗口", "Window minimized"))
                : (false, L10n.tr("当前窗口不支持最小化", "Window cannot be minimized"))

        case .toggleFullscreen:
            var fsRef: CFTypeRef?
            let currentFS: Bool = {
                if AXUIElementCopyAttributeValue(windowElement, "AXFullScreen" as CFString, &fsRef) == .success,
                   let val = fsRef as? Bool {
                    return val
                }
                return false
            }()
            let err = AXUIElementSetAttributeValue(
                windowElement,
                "AXFullScreen" as CFString,
                (!currentFS) as CFBoolean
            )
            return err == .success
                ? (true, L10n.tr("已切换全屏状态", "Toggled fullscreen"))
                : (false, L10n.tr("当前窗口不支持全屏切换", "Window does not support fullscreen"))

        case .center:
            let currentFrame = readWindowQuartzFrame(windowElement)
            let targetScreen: NSScreen? = {
                if NSScreen.screens.count > 1,
                   let chosenID = selectedTargetDisplayID,
                   let chosenScreen = screen(forDisplayID: chosenID) {
                    return chosenScreen
                }
                return screenContainingQuartzRect(currentFrame) ?? NSScreen.main ?? NSScreen.screens.first
            }()
            guard let screen = targetScreen else {
                return (false, "No screen available")
            }

            let visibleQuartz = convertAppKitScreenRectToQuartz(screen.visibleFrame)
            let sizeSettable = isAttributeSettable(kAXSizeAttribute as String, on: windowElement)
            let result = moveCoordinator.performCenter(
                windowID: windowKey,
                appName: appDisplayName,
                visibleQuartz: visibleQuartz,
                allowResize: sizeSettable,
                readFrame: {
                    readWindowQuartzFrameResult(windowElement)
                },
                writeFrame: { desiredFrame in
                    switch writeWindowQuartzFrameResult(
                        windowElement,
                        frame: desiredFrame,
                        applySize: sizeSettable,
                        rollbackOrigin: currentFrame?.origin
                    ) {
                    case .success:
                        return AXError.success.rawValue
                    case .failure(let err):
                        return err.code
                    }
                }
            )
            switch result {
            case .success:
                registerRetainedUndoTargetAfterMove(
                    windowKey: windowKey,
                    pid: app.processIdentifier,
                    windowElement: windowElement,
                    appName: appDisplayName
                )
                return (true, L10n.tr("已调整 \(app.localizedName ?? "") 窗口", "Adjusted \(app.localizedName ?? "") window"))
            case .failure(let err):
                return (false, err.message())
            }

        case .moveToNextDisplay:
            let screens = NSScreen.screens
            let screenDescriptors = screens.map {
                WindowScreenDescriptor(frame: $0.frame, visibleFrame: $0.visibleFrame)
            }
            let currentFrame = readWindowQuartzFrame(windowElement)
            let sizeSettable = isAttributeSettable(kAXSizeAttribute as String, on: windowElement)
            let result = moveCoordinator.performMoveToNextDisplay(
                windowID: windowKey,
                appName: appDisplayName,
                appKitScreens: screenDescriptors,
                allowResize: sizeSettable,
                readFrame: {
                    readWindowQuartzFrameResult(windowElement)
                },
                writeFrame: { desiredFrame in
                    switch writeWindowQuartzFrameResult(
                        windowElement,
                        frame: desiredFrame,
                        applySize: sizeSettable,
                        rollbackOrigin: currentFrame?.origin
                    ) {
                    case .success:
                        return AXError.success.rawValue
                    case .failure(let err):
                        return err.code
                    }
                }
            )
            switch result {
            case .success(let plan):
                previousWindowFrames.removeValue(forKey: windowKey)
                registerRetainedUndoTargetAfterMove(
                    windowKey: windowKey,
                    pid: app.processIdentifier,
                    windowElement: windowElement,
                    appName: appDisplayName
                )
                let destinationName = screens.indices.contains(plan.targetScreenIndex)
                    ? screens[plan.targetScreenIndex].localizedName
                    : L10n.tr("下一显示器", "Next Display")
                return (
                    true,
                    L10n.tr(
                        "已将 \(appDisplayName) 窗口移至 \(destinationName)",
                        "Moved \(appDisplayName) window to \(destinationName)"
                    )
                )
            case .failure(let err):
                return (false, err.message())
            }

        case .maximizeOrRestore, .snapLeft, .snapRight,
             .snapTopLeft, .snapTopRight, .snapBottomLeft, .snapBottomRight:
            let currentFrame = readWindowQuartzFrame(windowElement)
            let targetScreen: NSScreen? = {
                if NSScreen.screens.count > 1,
                   let chosenID = selectedTargetDisplayID,
                   let chosenScreen = screen(forDisplayID: chosenID) {
                    return chosenScreen
                }
                return screenContainingQuartzRect(currentFrame) ?? NSScreen.main ?? NSScreen.screens.first
            }()
            guard let screen = targetScreen else {
                return (false, "No screen available")
            }

            let visibleQuartz = convertAppKitScreenRectToQuartz(screen.visibleFrame)

            let desiredFrame: CGRect
            switch op {
            case .maximizeOrRestore:
                if let cur = currentFrame, isApproximatelyEqual(cur, visibleQuartz, tolerance: 16),
                   let saved = previousWindowFrames[windowKey] {
                    desiredFrame = saved
                    previousWindowFrames.removeValue(forKey: windowKey)
                } else {
                    if let cur = currentFrame {
                        previousWindowFrames[windowKey] = cur
                    }
                    desiredFrame = visibleQuartz
                }
            case .snapLeft:
                desiredFrame = CGRect(
                    x: visibleQuartz.origin.x,
                    y: visibleQuartz.origin.y,
                    width: floor(visibleQuartz.width / 2.0),
                    height: visibleQuartz.height
                )
            case .snapRight:
                let halfW = floor(visibleQuartz.width / 2.0)
                desiredFrame = CGRect(
                    x: visibleQuartz.origin.x + (visibleQuartz.width - halfW),
                    y: visibleQuartz.origin.y,
                    width: halfW,
                    height: visibleQuartz.height
                )
            case .snapTopLeft:
                desiredFrame = WindowDisplayGeometry.quarterFrame(for: .topLeft, visibleQuartz: visibleQuartz)
            case .snapTopRight:
                desiredFrame = WindowDisplayGeometry.quarterFrame(for: .topRight, visibleQuartz: visibleQuartz)
            case .snapBottomLeft:
                desiredFrame = WindowDisplayGeometry.quarterFrame(for: .bottomLeft, visibleQuartz: visibleQuartz)
            case .snapBottomRight:
                desiredFrame = WindowDisplayGeometry.quarterFrame(for: .bottomRight, visibleQuartz: visibleQuartz)
            default:
                desiredFrame = visibleQuartz
            }

            let sizeSettable = isAttributeSettable(kAXSizeAttribute as String, on: windowElement)
            switch writeWindowQuartzFrameResult(
                windowElement,
                frame: desiredFrame,
                applySize: sizeSettable,
                rollbackOrigin: currentFrame?.origin
            ) {
            case .success:
                if let cur = currentFrame {
                    recordWindowMoveForUndo(
                        windowKey: windowKey,
                        pid: app.processIdentifier,
                        windowElement: windowElement,
                        appName: appDisplayName,
                        previousFrame: cur
                    )
                }
                return (true, L10n.tr("已调整 \(app.localizedName ?? "") 窗口", "Adjusted \(app.localizedName ?? "") window"))
            case .failure(let axErr):
                return (false, WindowAXErrorFormatting.moveFailureMessage(rawCode: axErr.code))
            }
        }
    }

    @discardableResult
    public func applyCompanionWindowFrame(
        preferredPID: pid_t?,
        strictTargetPID: Bool = false,
        targetWindowKey: String? = nil,
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
        guard AXIsProcessTrusted() else {
            _ = promptForAccessibilityPermission()
            return (false, L10n.tr("请在系统设置 → 辅助功能中授权 Choclift 控制窗口", "Grant Accessibility permission in System Settings to control windows"))
        }

        guard let app = resolveNonSelfWindowTargetApp(
            preferredPID: preferredPID,
            strictTargetPID: strictTargetPID,
            selfPID: ProcessInfo.processInfo.processIdentifier
        ) else {
            if strictTargetPID {
                return (false, L10n.tr("目标应用未运行，已停止窗口操作", "Target application is not running; aborted window operation"))
            }
            return (false, L10n.tr("未找到活动窗口", "No active application found"))
        }

        let appDisplayName = app.localizedName ?? "App"
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windowElement: AXUIElement
        if let targetWindowKey {
            var listRef: CFTypeRef?
            let candidates: [AXUIElement] = {
                if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &listRef) == .success,
                   let list = listRef as? [AXUIElement] {
                    return list
                }
                if let fallback = resolveTargetWindow(for: appElement) {
                    return [fallback]
                }
                return []
            }()
            guard let matched = candidates.first(where: { "\(app.processIdentifier)-\(CFHash($0))" == targetWindowKey }) else {
                return (false, L10n.tr("已保存的窗口已关闭或不可用", "Saved window was closed or is no longer available"))
            }
            var minRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(matched, kAXMinimizedAttribute as CFString, &minRef) == .success,
               let isMin = minRef as? Bool, isMin {
                _ = AXUIElementSetAttributeValue(matched, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            windowElement = matched
        } else {
            switch resolveTargetWindowResult(for: appElement) {
            case .window(let resolved):
                windowElement = resolved
            case .axFailure(let axErr):
                return (false, WindowAXErrorFormatting.moveFailureMessage(rawCode: axErr.rawValue))
            case .noWindow:
                return (false, L10n.tr("\(appDisplayName) 当前没有可调整的窗口", "No adjustable window in \(appDisplayName)"))
            }
        }

        let currentFrame: CGRect
        switch readWindowQuartzFrameResult(windowElement) {
        case .success(let rect):
            currentFrame = rect
        case .failure(let axErr):
            return (false, WindowAXErrorFormatting.moveFailureMessage(rawCode: axErr.code))
        }

        let screens = NSScreen.screens
        let targetScreen: NSScreen? = {
            if screens.count > 1,
               let chosenID = selectedTargetDisplayID,
               let chosenScreen = screen(forDisplayID: chosenID) {
                return chosenScreen
            }
            return screenContainingQuartzRect(currentFrame) ?? NSScreen.main ?? screens.first
        }()
        guard let screen = targetScreen else {
            return (false, L10n.tr("未检测到可用显示器", "No screen available"))
        }

        let visibleQuartz = convertAppKitScreenRectToQuartz(screen.visibleFrame)
        let quartzScreens = WindowDisplayGeometry.quartzScreens(
            from: screens.map { WindowScreenDescriptor(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        )
        let screenNames = screens.map(\.localizedName)
        let windowKey = "\(app.processIdentifier)-\(CFHash(windowElement))"
        let sizeSettable = isAttributeSettable(kAXSizeAttribute as String, on: windowElement)

        let resolved: (frame: CGRect, message: String)
        switch resolveFrame(
            app.processIdentifier,
            windowKey,
            appDisplayName,
            currentFrame,
            visibleQuartz,
            quartzScreens,
            screenNames,
            sizeSettable
        ) {
        case .success(let plan):
            resolved = plan
        case .failure(let reason):
            return (false, reason.message)
        }

        let shouldApplySize = sizeSettable && resolved.frame.size != currentFrame.size
        switch writeWindowQuartzFrameResult(
            windowElement,
            frame: resolved.frame,
            applySize: shouldApplySize,
            rollbackOrigin: currentFrame.origin
        ) {
        case .success:
            recordWindowMoveForUndo(
                windowKey: windowKey,
                pid: app.processIdentifier,
                windowElement: windowElement,
                appName: appDisplayName,
                previousFrame: currentFrame
            )
            return (true, resolved.message)
        case .failure(let axErr):
            return (false, WindowAXErrorFormatting.moveFailureMessage(rawCode: axErr.code))
        }
    }

    @discardableResult
    public func closeFrontmostWindow(
        preferredPID: pid_t?,
        strictTargetPID: Bool = false,
        selfPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> (success: Bool, message: String) {
        guard AXIsProcessTrusted() else {
            _ = promptForAccessibilityPermission()
            return (false, L10n.tr("请在系统设置 → 辅助功能中授权 Choclift 控制窗口", "Grant Accessibility permission in System Settings to control windows"))
        }

        guard let app = resolveNonSelfWindowTargetApp(
            preferredPID: preferredPID,
            strictTargetPID: strictTargetPID,
            selfPID: selfPID
        ) else {
            if strictTargetPID {
                return (false, L10n.tr("目标应用未运行，已停止窗口操作", "Target application is not running; aborted window operation"))
            }
            return (false, L10n.tr("当前没有可关闭的前台窗口", "No frontmost window to close"))
        }

        let appDisplayName = app.localizedName ?? app.bundleIdentifier ?? "App"
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windowElement: AXUIElement
        switch resolveClosableWindowResult(for: appElement) {
        case .window(let resolved):
            windowElement = resolved
        case .axFailure(let axErr):
            return (false, WindowAXErrorFormatting.moveFailureMessage(rawCode: axErr.rawValue))
        case .noWindow:
            return (false, L10n.tr("\(appDisplayName) 当前没有可关闭的窗口", "No open window to close in \(appDisplayName)"))
        }

        var closeButtonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
              let closeButtonRef,
              CFGetTypeID(closeButtonRef) == AXUIElementGetTypeID() else {
            return (false, L10n.tr("当前窗口不支持关闭", "Window does not support closing"))
        }
        let closeButton = closeButtonRef as! AXUIElement

        var enabledRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(closeButton, kAXEnabledAttribute as CFString, &enabledRef) == .success,
           let isEnabled = enabledRef as? Bool,
           !isEnabled {
            return (false, L10n.tr("当前窗口关闭按钮不可用", "Window close button is disabled"))
        }

        let pressErr = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        return pressErr == .success
            ? (true, L10n.tr("已关闭 \(appDisplayName) 窗口", "Closed \(appDisplayName) window"))
            : (false, L10n.tr("无法关闭 \(appDisplayName) 窗口", "Could not close \(appDisplayName) window"))
    }

    public func pressNotificationCenterMenuBarClock() -> Bool {
        guard AXIsProcessTrusted(),
              let controlCenter = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first,
              !controlCenter.isTerminated else {
            return false
        }
        let appElement = AXUIElementCreateApplication(controlCenter.processIdentifier)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXExtrasMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarRef,
              CFGetTypeID(menuBarRef) == AXUIElementGetTypeID() else {
            return false
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBarRef as! AXUIElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement],
              !children.isEmpty else {
            return false
        }
        guard let clockItem = children.first(where: { item in
            var idRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXIdentifierAttribute as CFString, &idRef) == .success,
                  let identifier = idRef as? String else {
                return false
            }
            return identifier == "com.apple.menuextra.clock"
        }) else {
            return false
        }
        return AXUIElementPerformAction(clockItem, kAXPressAction as CFString) == .success
    }

    private func resolveNonSelfWindowTargetApp(
        preferredPID: pid_t?,
        strictTargetPID: Bool,
        selfPID: pid_t
    ) -> NSRunningApplication? {
        let selfBundleID = Bundle.main.bundleIdentifier
        func isEligible(_ app: NSRunningApplication) -> Bool {
            guard !app.isTerminated,
                  app.processIdentifier != selfPID,
                  app.bundleIdentifier != "com.apple.loginwindow" else {
                return false
            }
            if let selfBundleID, app.bundleIdentifier == selfBundleID {
                return false
            }
            return true
        }

        if strictTargetPID {
            guard let preferredPID,
                  let app = NSRunningApplication(processIdentifier: preferredPID),
                  isEligible(app) else {
                return nil
            }
            return app
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

    private func resolveClosableWindowResult(for appElement: AXUIElement) -> ResolvedWindowOutcome {
        func isOpenWindow(_ win: AXUIElement) -> Bool {
            var minRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef) == .success,
               let isMin = minRef as? Bool,
               isMin {
                return false
            }
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String {
                return role == (kAXWindowRole as String)
            }
            return true
        }

        var focusedWin: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWin)
        if focusedErr == .success,
           let fw = focusedWin,
           CFGetTypeID(fw) == AXUIElementGetTypeID(),
           isOpenWindow(fw as! AXUIElement) {
            return .window(fw as! AXUIElement)
        }

        var mainWin: CFTypeRef?
        let mainErr = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWin)
        if mainErr == .success,
           let mw = mainWin,
           CFGetTypeID(mw) == AXUIElementGetTypeID(),
           isOpenWindow(mw as! AXUIElement) {
            return .window(mw as! AXUIElement)
        }

        var listRef: CFTypeRef?
        let winErr = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &listRef)
        if winErr == .success,
           let windows = listRef as? [AXUIElement] {
            if let firstOpen = windows.first(where: isOpenWindow) {
                return .window(firstOpen)
            }
            return .noWindow
        }

        if winErr != .success && winErr != .noValue {
            return .axFailure(winErr)
        }
        if focusedErr != .success && focusedErr != .noValue {
            return .axFailure(focusedErr)
        }
        if mainErr != .success && mainErr != .noValue {
            return .axFailure(mainErr)
        }
        return .noWindow
    }

    public func unminimizeFirstWindowIfAllMinimized(pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              !windows.isEmpty else {
            return
        }

        let anyVisible = windows.contains { win in
            var minRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef) == .success,
               let isMin = minRef as? Bool {
                return !isMin
            }
            return true
        }

        if !anyVisible, let first = windows.first {
            AXUIElementSetAttributeValue(first, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
    }

    public func raiseWindowMatchingTitleHint(_ hint: String?, forPID pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              !windows.isEmpty else {
            return
        }

        let trimmedHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let matchedWindow: AXUIElement? = {
            guard !trimmedHint.isEmpty else { return nil }
            return windows.first { win in
                var titleRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
                      let title = titleRef as? String else {
                    return false
                }
                return title.localizedCaseInsensitiveContains(trimmedHint)
            }
        }()

        let targetWindow = matchedWindow ?? resolveTargetWindow(for: appElement) ?? windows.first
        guard let targetWindow else { return }

        _ = AXUIElementSetAttributeValue(targetWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        _ = AXUIElementSetAttributeValue(targetWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
    }

    // MARK: - Frontmost App Window List & Raise (Round 4 — Metadata Only, Capped at 12)

    public func inspectFrontmostAppWindows(
        preferredExternalPID: pid_t?,
        selfPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        language: AppLanguage = .system
    ) -> FrontmostAppWindowSnapshot {
        let targetApp = resolveFrontmostTargetApp(preferredExternalPID: preferredExternalPID, selfPID: selfPID)
        let bundleID = targetApp?.bundleIdentifier
        let resolvedAppName = targetApp?.localizedName ?? bundleID

        guard AXIsProcessTrusted() else {
            cachedFrontmostWindowTargets.removeAll()
            return FrontmostAppWindowSnapshot(
                bundleIdentifier: bundleID,
                appName: resolvedAppName,
                windows: [],
                totalWindowCount: 0,
                isAccessibilityTrusted: false
            )
        }

        guard let app = targetApp else {
            cachedFrontmostWindowTargets.removeAll()
            return FrontmostAppWindowSnapshot(
                bundleIdentifier: nil,
                appName: nil,
                windows: [],
                totalWindowCount: 0,
                isAccessibilityTrusted: true
            )
        }

        let appTitleFallback = resolvedAppName ?? "App"
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        let focusedElement: AXUIElement? = {
            guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
                  let fw = focusedRef,
                  CFGetTypeID(fw) == AXUIElementGetTypeID() else {
                return nil
            }
            return (fw as! AXUIElement)
        }()

        var mainRef: CFTypeRef?
        let mainElement: AXUIElement? = {
            guard AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainRef) == .success,
                  let mw = mainRef,
                  CFGetTypeID(mw) == AXUIElementGetTypeID() else {
                return nil
            }
            return (mw as! AXUIElement)
        }()

        var listRef: CFTypeRef?
        let rawWindows: [AXUIElement] = {
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &listRef) == .success,
                  let list = listRef as? [AXUIElement] else {
                return []
            }
            return list
        }()

        let validWindows = rawWindows.filter { win in
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String {
                return role == (kAXWindowRole as String)
            }
            return true
        }

        let totalCount = validWindows.count
        var items: [MacFrontmostWindowItem] = []
        var updatedCache: [String: CachedFrontmostWindowTarget] = [:]

        for (idx, win) in validWindows.prefix(FrontmostAppWindowSnapshot.maxWindows).enumerated() {
            var titleRef: CFTypeRef?
            let rawTitle: String = {
                if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let str = titleRef as? String {
                    return str.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return ""
            }()
            let displayTitle = rawTitle.isEmpty
                ? "\(appTitleFallback) — \(L10n.tr("窗口", "Window", language: language)) \(idx + 1)"
                : rawTitle

            var minRef: CFTypeRef?
            let isMinimized: Bool = {
                if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef) == .success,
                   let flag = minRef as? Bool {
                    return flag
                }
                return false
            }()

            let isMainOrFocused: Bool = {
                if let focusedElement, CFEqual(win, focusedElement) {
                    return true
                }
                if let mainElement, CFEqual(win, mainElement) {
                    return true
                }
                var mainAttrRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(win, kAXMainAttribute as CFString, &mainAttrRef) == .success,
                   let isMain = mainAttrRef as? Bool, isMain {
                    return true
                }
                return false
            }()

            let windowID = "win-\(app.processIdentifier)-\(idx)-\(CFHash(win))"
            items.append(
                MacFrontmostWindowItem(
                    id: windowID,
                    title: displayTitle,
                    index: idx,
                    isMainOrFocused: isMainOrFocused,
                    isMinimized: isMinimized
                )
            )
            updatedCache[windowID] = CachedFrontmostWindowTarget(
                pid: app.processIdentifier,
                appName: appTitleFallback,
                title: displayTitle,
                index: idx,
                element: win
            )
        }

        cachedFrontmostWindowTargets = updatedCache
        return FrontmostAppWindowSnapshot(
            bundleIdentifier: bundleID,
            appName: appTitleFallback,
            windows: items,
            totalWindowCount: totalCount,
            isAccessibilityTrusted: true
        )
    }

    public func raiseFrontmostAppWindow(
        windowID: String,
        preferredExternalPID: pid_t?,
        selfPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        language: AppLanguage = .system
    ) -> (success: Bool, title: String, detail: String) {
        let trimmed = windowID.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = L10n.tr("应用窗口", "App Window", language: language)

        guard AXIsProcessTrusted() else {
            _ = promptForAccessibilityPermission()
            return (
                false,
                fallbackTitle,
                L10n.tr(
                    "请在系统设置 → 辅助功能中授权 Choclift 以置顶窗口",
                    "Grant Accessibility permission in System Settings to raise windows",
                    language: language
                )
            )
        }

        if cachedFrontmostWindowTargets[trimmed] == nil {
            _ = inspectFrontmostAppWindows(
                preferredExternalPID: preferredExternalPID,
                selfPID: selfPID,
                language: language
            )
        }

        guard let target = cachedFrontmostWindowTargets[trimmed],
              let runningApp = NSRunningApplication(processIdentifier: target.pid),
              !runningApp.isTerminated else {
            return (
                false,
                fallbackTitle,
                L10n.tr("该窗口已关闭或不可用", "That window was closed or is no longer available", language: language)
            )
        }

        _ = AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        _ = runningApp.activate(options: [.activateIgnoringOtherApps])
        _ = AXUIElementSetAttributeValue(target.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let raiseErr = AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)

        if raiseErr == .success || runningApp.isActive {
            return (
                true,
                target.title,
                L10n.tr(
                    "已置顶 \(target.appName) 窗口：\(target.title)",
                    "Raised \(target.appName): \(target.title)",
                    language: language
                )
            )
        } else {
            return (
                false,
                target.title,
                L10n.tr(
                    "无法置顶窗口：\(target.title)",
                    "Unable to raise window: \(target.title)",
                    language: language
                )
            )
        }
    }

    private func resolveFrontmostTargetApp(
        preferredExternalPID: pid_t?,
        selfPID: pid_t
    ) -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication,
           !front.isTerminated,
           front.processIdentifier != selfPID {
            return front
        }
        if let preferredExternalPID,
           let ext = NSRunningApplication(processIdentifier: preferredExternalPID),
           !ext.isTerminated {
            return ext
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           !front.isTerminated {
            return front
        }
        return nil
    }

    /// Hides every running regular application except the frontmost one (`app.hide()`).
    /// Never quits (`terminate()`) any application, and leaves the one-level `WindowMoveUndoBuffer`
    /// untouched because AX Quartz frame undo cannot restore hidden application visibility.
    public func hideOtherApplications(
        preferredExternalPID: pid_t?,
        selfPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        language: AppLanguage = .system
    ) -> (success: Bool, title: String, detail: String) {
        let title = HideOtherWindowsPolicy.buttonTitle(compact: false, in: language)
        guard let frontApp = resolveFrontmostTargetApp(
            preferredExternalPID: preferredExternalPID,
            selfPID: selfPID
        ), frontApp.bundleIdentifier != "com.apple.loginwindow" else {
            return (
                false,
                title,
                L10n.tr("当前没有可用的前台应用窗口", "No active frontmost app found", language: language)
            )
        }

        let frontName = frontApp.localizedName ?? frontApp.bundleIdentifier ?? "App"
        var hiddenCount = 0

        for candidate in NSWorkspace.shared.runningApplications {
            guard !candidate.isTerminated,
                  candidate.activationPolicy == .regular,
                  candidate.processIdentifier != frontApp.processIdentifier,
                  candidate.bundleIdentifier != "com.apple.loginwindow" else {
                continue
            }
            if !candidate.isHidden, candidate.hide() {
                hiddenCount += 1
            }
        }

        let detail: String
        if hiddenCount > 0 {
            detail = L10n.tr(
                "已隐藏其他 \(hiddenCount) 个应用（仅保留 \(frontName)）",
                "Hid \(hiddenCount) other app\(hiddenCount == 1 ? "" : "s") (kept \(frontName) visible)",
                language: language
            )
        } else {
            detail = L10n.tr(
                "当前仅 \(frontName) 处于可见状态",
                "Only \(frontName) is currently visible",
                language: language
            )
        }
        return (true, title, detail)
    }

    // MARK: - AX Geometry Helpers

    private enum ResolvedWindowOutcome {
        case window(AXUIElement)
        case noWindow
        case axFailure(AXError)
    }

    private func resolveTargetWindow(for appElement: AXUIElement) -> AXUIElement? {
        if case .window(let element) = resolveTargetWindowResult(for: appElement) {
            return element
        }
        return nil
    }

    private func resolveTargetWindowResult(for appElement: AXUIElement) -> ResolvedWindowOutcome {
        var focusedWin: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWin)
        if focusedErr == .success,
           let fw = focusedWin,
           CFGetTypeID(fw) == AXUIElementGetTypeID() {
            return .window(fw as! AXUIElement)
        }

        var mainWin: CFTypeRef?
        let mainErr = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWin)
        if mainErr == .success,
           let mw = mainWin,
           CFGetTypeID(mw) == AXUIElementGetTypeID() {
            return .window(mw as! AXUIElement)
        }

        var listRef: CFTypeRef?
        let winErr = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &listRef)
        if winErr == .success,
           let windows = listRef as? [AXUIElement] {
            if let first = windows.first {
                return .window(first)
            }
            return .noWindow
        }

        if winErr != .success && winErr != .noValue {
            return .axFailure(winErr)
        }
        if focusedErr != .success && focusedErr != .noValue {
            return .axFailure(focusedErr)
        }
        if mainErr != .success && mainErr != .noValue {
            return .axFailure(mainErr)
        }
        return .noWindow
    }

    private func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return status == .success && settable.boolValue
    }

    private func readWindowQuartzFrame(_ window: AXUIElement) -> CGRect? {
        if case .success(let frame) = readWindowQuartzFrameResult(window) {
            return frame
        }
        return nil
    }

    private func readWindowQuartzFrameResult(_ window: AXUIElement) -> Result<CGRect, WindowAXStatusError> {
        var posRef: CFTypeRef?
        let posErr = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        guard posErr == .success else {
            return .failure(WindowAXStatusError(posErr.rawValue))
        }

        var sizeRef: CFTypeRef?
        let sizeErr = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        guard sizeErr == .success else {
            return .failure(WindowAXStatusError(sizeErr.rawValue))
        }

        guard let posVal = posRef,
              let sizeVal = sizeRef,
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else {
            return .failure(WindowAXStatusError(AXError.illegalArgument.rawValue))
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else {
            return .failure(WindowAXStatusError(AXError.illegalArgument.rawValue))
        }
        return .success(CGRect(origin: point, size: size))
    }

    private func writeWindowQuartzFrameResult(
        _ window: AXUIElement,
        frame: CGRect,
        applySize: Bool = true,
        rollbackOrigin: CGPoint? = nil
    ) -> Result<Void, WindowAXStatusError> {
        var origin = frame.origin
        var size = frame.size
        guard let posVal = AXValueCreate(.cgPoint, &origin),
              let sizeVal = AXValueCreate(.cgSize, &size) else {
            return .failure(WindowAXStatusError(AXError.illegalArgument.rawValue))
        }

        var posSettable = DarwinBoolean(false)
        let posSettableStatus = AXUIElementIsAttributeSettable(
            window,
            kAXPositionAttribute as CFString,
            &posSettable
        )

        // Position -> Size -> Position moves across displays cleanly in both large->small
        // and small->large directions while immediately surfacing real AX move errors.
        let posErr = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        guard posErr == .success else {
            return .failure(WindowAXStatusError(posErr.rawValue))
        }
        if posSettableStatus == .success && !posSettable.boolValue {
            return .failure(WindowAXStatusError(AXError.attributeUnsupported.rawValue))
        }

        if applySize {
            let sizeErr = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
            guard sizeErr == .success else {
                if var restore = rollbackOrigin,
                   let restoreVal = AXValueCreate(.cgPoint, &restore) {
                    _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, restoreVal)
                }
                return .failure(WindowAXStatusError(sizeErr.rawValue))
            }
            let finalPosErr = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
            guard finalPosErr == .success else {
                return .failure(WindowAXStatusError(finalPosErr.rawValue))
            }
        }
        return .success(())
    }

    private func convertAppKitScreenRectToQuartz(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080
        return WindowDisplayGeometry.convertAppKitRectToQuartz(rect, primaryScreenHeight: primaryHeight)
    }

    private func screenContainingQuartzRect(_ quartzRect: CGRect?) -> NSScreen? {
        guard let quartzRect else { return NSScreen.main }
        let center = CGPoint(x: quartzRect.midX, y: quartzRect.midY)
        for screen in NSScreen.screens {
            let screenQuartz = convertAppKitScreenRectToQuartz(screen.frame)
            if screenQuartz.contains(center) {
                return screen
            }
        }
        return NSScreen.main
    }

    private func isApproximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance &&
        abs(a.origin.y - b.origin.y) <= tolerance &&
        abs(a.width - b.width) <= tolerance &&
        abs(a.height - b.height) <= tolerance
    }
}
