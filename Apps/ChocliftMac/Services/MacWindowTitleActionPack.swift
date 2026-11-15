import AppKit
import ApplicationServices
import ChocliftCore
import Foundation

enum MacWindowTitleActionPack {
    @MainActor
    private static let windowService = MacAccessibilityAndWindowService()

    static func run(
        id: String,
        preferredPID: pid_t?,
        language: AppLanguage = .system
    ) -> (success: Bool, message: String) {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                runOnMainActor(id: id, preferredPID: preferredPID, language: language)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                runOnMainActor(id: id, preferredPID: preferredPID, language: language)
            }
        }
    }

    @MainActor
    private static func runOnMainActor(
        id: String,
        preferredPID: pid_t?,
        language: AppLanguage
    ) -> (success: Bool, message: String) {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let hostBundleID = Bundle.main.bundleIdentifier
        let frontApp = NSWorkspace.shared.frontmostApplication
        let preferredApp: NSRunningApplication? = {
            guard let preferredPID, preferredPID > 0 else { return nil }
            return NSRunningApplication(processIdentifier: preferredPID)
        }()

        return WindowTitleCompanionRouting.execute(
            id: id,
            isAccessibilityTrusted: windowService.isAccessibilityTrusted(),
            frontmost: frontApp.map(makeCandidate),
            preferred: preferredApp.map(makeCandidate),
            selfPID: Int32(selfPID),
            hostBundleIdentifier: hostBundleID,
            language: language,
            onRequestAccessibilityPermission: {
                _ = windowService.promptForAccessibilityPermission()
            },
            readFocusedWindowTitle: { target in
                readFocusedWindowAXTitle(pid: pid_t(target.pid))
            },
            writePasteboardString: { text in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                return pasteboard.setString(text, forType: .string)
            }
        )
    }

    private static func makeCandidate(_ app: NSRunningApplication) -> WindowTitleAppCandidate {
        WindowTitleAppCandidate(
            pid: Int32(app.processIdentifier),
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName,
            isTerminated: app.isTerminated
        )
    }

    /// Reads only `kAXTitleAttribute` on the focused window.
    private static func readFocusedWindowAXTitle(pid: pid_t) -> WindowTitleReadResult {
        let appElement = AXUIElementCreateApplication(pid)
        guard let windowElement = resolveFocusedOpenWindow(for: appElement) else {
            return .noFocusedWindow
        }

        var titleRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            windowElement,
            kAXTitleAttribute as CFString,
            &titleRef
        )
        let rawTitle = (status == .success) ? (titleRef as? String) : nil
        return .title(rawTitle)
    }

    private static func resolveFocusedOpenWindow(for appElement: AXUIElement) -> AXUIElement? {
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

        var listRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &listRef) == .success,
           let windows = listRef as? [AXUIElement] {
            return windows.first(where: isOpenStandardWindow)
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
}
