import AppKit
import ApplicationServices
import ChocliftCore
import Foundation

@MainActor
public final class MacAccessibilityAndWindowService {
    private var previousWindowFrames: [String: CGRect] = [:]

    public init() {}

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

    // MARK: - Text Field Focus Detection (Auto Emoji Bar)

    public func inspectFocusedTextInput(excludingPID: pid_t? = nil) -> (isEditing: Bool, appName: String?) {
        guard AXIsProcessTrusted() else {
            return (false, nil)
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return (false, nil)
        }
        if let excludingPID, frontApp.processIdentifier == excludingPID {
            return (false, nil)
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard status == .success, let focusedElement = focusedRef else {
            return (false, nil)
        }

        // Safe CoreFoundation type check: AXUIElementGetTypeID()
        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return (false, nil)
        }
        let axElement = focusedElement as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField"
        ]

        if editableRoles.contains(role) {
            return (true, frontApp.localizedName)
        }

        // Check AXEditable attribute for web inputs (Safari, Chrome, Arc, Electron)
        var editableRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axElement, "AXEditable" as CFString, &editableRef) == .success,
           let isEditable = editableRef as? Bool,
           isEditable {
            return (true, frontApp.localizedName)
        }

        return (false, nil)
    }

    // MARK: - Window Actions

    public enum WindowOperation {
        case maximizeOrRestore
        case minimize
        case snapLeft
        case snapRight
        case center
        case toggleFullscreen
    }

    @discardableResult
    public func performWindowOperation(_ op: WindowOperation, preferredPID: pid_t?) -> (success: Bool, message: String) {
        guard AXIsProcessTrusted() else {
            _ = promptForAccessibilityPermission()
            return (false, L10n.tr("请在系统设置 → 辅助功能中授权 Choclift 控制窗口", "Grant Accessibility permission in System Settings to control windows"))
        }

        let targetApp: NSRunningApplication? = {
            if let preferredPID,
               let app = NSRunningApplication(processIdentifier: preferredPID),
               !app.isTerminated {
                return app
            }
            return NSWorkspace.shared.frontmostApplication
        }()

        guard let app = targetApp else {
            return (false, L10n.tr("未找到活动窗口", "No active application found"))
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let windowElement = resolveTargetWindow(for: appElement) else {
            return (false, L10n.tr("\(app.localizedName ?? "App") 当前没有可调整的窗口", "No adjustable window in \(app.localizedName ?? "app")"))
        }

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

        case .maximizeOrRestore, .snapLeft, .snapRight, .center:
            let currentFrame = readWindowQuartzFrame(windowElement)
            let targetScreen = screenContainingQuartzRect(currentFrame) ?? NSScreen.main ?? NSScreen.screens.first
            guard let screen = targetScreen else {
                return (false, "No screen available")
            }

            let visibleQuartz = convertAppKitScreenRectToQuartz(screen.visibleFrame)
            let windowKey = "\(app.processIdentifier)-\(CFHash(windowElement))"

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
            case .center:
                let w = min(currentFrame?.width ?? visibleQuartz.width * 0.72, visibleQuartz.width)
                let h = min(currentFrame?.height ?? visibleQuartz.height * 0.78, visibleQuartz.height)
                desiredFrame = CGRect(
                    x: round(visibleQuartz.origin.x + (visibleQuartz.width - w) / 2.0),
                    y: round(visibleQuartz.origin.y + (visibleQuartz.height - h) / 2.0),
                    width: w,
                    height: h
                )
            default:
                desiredFrame = visibleQuartz
            }

            let ok = writeWindowQuartzFrame(windowElement, frame: desiredFrame)
            return ok
                ? (true, L10n.tr("已调整 \(app.localizedName ?? "") 窗口", "Adjusted \(app.localizedName ?? "") window"))
                : (false, L10n.tr("无法调整该窗口尺寸", "Unable to resize window"))
        }
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

    // MARK: - AX Geometry Helpers

    private func resolveTargetWindow(for appElement: AXUIElement) -> AXUIElement? {
        var focusedWin: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWin) == .success,
           let fw = focusedWin,
           CFGetTypeID(fw) == AXUIElementGetTypeID() {
            return (fw as! AXUIElement)
        }

        var mainWin: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWin) == .success,
           let mw = mainWin,
           CFGetTypeID(mw) == AXUIElementGetTypeID() {
            return (mw as! AXUIElement)
        }

        var listRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &listRef) == .success,
           let windows = listRef as? [AXUIElement] {
            return windows.first
        }

        return nil
    }

    private func readWindowQuartzFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef,
              let sizeVal = sizeRef,
              CFGetTypeID(posVal) == AXValueGetTypeID(),
              CFGetTypeID(sizeVal) == AXValueGetTypeID() else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private func writeWindowQuartzFrame(_ window: AXUIElement, frame: CGRect) -> Bool {
        var origin = frame.origin
        var size = frame.size
        guard let posVal = AXValueCreate(.cgPoint, &origin),
              let sizeVal = AXValueCreate(.cgSize, &size) else {
            return false
        }
        // Setting size -> position -> size handles multi-monitor clamping cleanly on macOS
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        let posErr = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        let sizeErr = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        return posErr == .success || sizeErr == .success
    }

    private func convertAppKitScreenRectToQuartz(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 1080
        let quartzY = primaryHeight - rect.maxY
        return CGRect(x: rect.origin.x, y: quartzY, width: rect.width, height: rect.height)
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
