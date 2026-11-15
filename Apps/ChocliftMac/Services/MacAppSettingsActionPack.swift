import AppKit
import ApplicationServices
import ChocliftCore
import Foundation

enum MacAppSettingsActionPack {
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

        return AppSettingsActionRouting.execute(
            id: id,
            frontmost: frontApp.map(makeTarget),
            preferred: preferredApp.map(makeTarget),
            selfPID: Int32(selfPID),
            hostBundleIdentifier: hostBundleID,
            language: language,
            ensureAccessibility: {
                if windowService.isAccessibilityTrusted() {
                    return true
                }
                _ = windowService.promptForAccessibilityPermission()
                return false
            },
            activateAndPressSettings: { target in
                let resolvedApp: NSRunningApplication? = {
                    if let frontApp, Int32(frontApp.processIdentifier) == target.pid {
                        return frontApp
                    }
                    if let preferredApp, Int32(preferredApp.processIdentifier) == target.pid {
                        return preferredApp
                    }
                    return NSRunningApplication(processIdentifier: pid_t(target.pid))
                }()
                guard let running = resolvedApp,
                      !running.isTerminated,
                      running.processIdentifier != selfPID,
                      !AppSettingsActionRouting.isChocliftBundle(
                          running.bundleIdentifier,
                          hostBundleIdentifier: hostBundleID
                      ) else {
                    return .missingOrDisabled
                }

                running.unhide()
                let wasFrontmost = (NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier)
                _ = running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                if !wasFrontmost {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }

                return pressAppSettingsMenuItem(
                    forPID: running.processIdentifier,
                    fallbackAppName: target.displayName
                )
            }
        )
    }

    private static func makeTarget(_ app: NSRunningApplication) -> AppSettingsTargetCandidate {
        AppSettingsTargetCandidate(
            pid: Int32(app.processIdentifier),
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName,
            isRegular: app.activationPolicy == .regular,
            isTerminated: app.isTerminated
        )
    }

    private struct AXMenuCandidate {
        let menu: String
        let item: String
        let enabled: Bool
        let element: AXUIElement
    }

    private static func pressAppSettingsMenuItem(
        forPID pid: pid_t,
        fallbackAppName: String
    ) -> AppSettingsPressOutcome {
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            return .missingOrDisabled
        }

        let appElement = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarRef,
              CFGetTypeID(menuBarRef) == AXUIElementGetTypeID() else {
            return .missingOrDisabled
        }
        let menuBar = unsafeBitCast(menuBarRef, to: AXUIElement.self)

        let topItems = copyChildren(of: menuBar)
        guard !topItems.isEmpty else {
            return .missingOrDisabled
        }

        var candidates: [AXMenuCandidate] = []
        var sawStandardApplicationMenu = false

        for (topIndex, topItem) in topItems.enumerated() {
            let rawMenuTitle = copyTitle(of: topItem)
            if topIndex == 0 && (rawMenuTitle.isEmpty || AppSettingsMenuMatch.isAppleMenuTitle(rawMenuTitle)) {
                continue
            }
            if AppSettingsMenuMatch.isAppleMenuTitle(rawMenuTitle) {
                continue
            }

            let isFirstAppMenu = !sawStandardApplicationMenu
            if isFirstAppMenu {
                sawStandardApplicationMenu = true
            }
            let effectiveMenuTitle = rawMenuTitle.isEmpty ? fallbackAppName : rawMenuTitle

            guard isFirstAppMenu || AppSettingsMenuMatch.isSettingsMenuTitle(effectiveMenuTitle) else {
                continue
            }

            for submenu in copyChildren(of: topItem) {
                for menuItem in copyChildren(of: submenu) {
                    let itemTitle = copyTitle(of: menuItem)
                    let nestedMenus = copyChildMenus(of: menuItem)
                    if !nestedMenus.isEmpty {
                        if AppSettingsMenuMatch.isSettingsMenuTitle(itemTitle) {
                            for nestedMenu in nestedMenus {
                                for nestedItem in copyChildren(of: nestedMenu) where copyChildMenus(of: nestedItem).isEmpty {
                                    let nestedTitle = copyTitle(of: nestedItem)
                                    guard !nestedTitle.isEmpty else { continue }
                                    candidates.append(
                                        AXMenuCandidate(
                                            menu: itemTitle,
                                            item: nestedTitle,
                                            enabled: copyEnabled(of: nestedItem),
                                            element: nestedItem
                                        )
                                    )
                                }
                            }
                        }
                        continue
                    }

                    guard !itemTitle.isEmpty else { continue }
                    candidates.append(
                        AXMenuCandidate(
                            menu: effectiveMenuTitle,
                            item: itemTitle,
                            enabled: copyEnabled(of: menuItem),
                            element: menuItem
                        )
                    )
                }
            }
        }

        let menuTitles = candidates.map { (menu: $0.menu, item: $0.item, enabled: $0.enabled) }
        guard let matchedIndex = AppSettingsMenuMatch.firstEnabledIndex(menuTitles: menuTitles),
              candidates.indices.contains(matchedIndex) else {
            return .missingOrDisabled
        }

        let chosen = candidates[matchedIndex]
        guard AXUIElementPerformAction(chosen.element, kAXPressAction as CFString) == .success else {
            return .pressFailed
        }
        return .pressed(itemTitle: chosen.item)
    }

    private static func copyChildren(of element: AXUIElement) -> [AXUIElement] {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return []
        }
        return children
    }

    private static func copyChildMenus(of element: AXUIElement) -> [AXUIElement] {
        copyChildren(of: element).filter { child in
            var roleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
                  let role = roleRef as? String else {
                return false
            }
            return role == (kAXMenuRole as String)
        }
    }

    private static func copyTitle(of element: AXUIElement) -> String {
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else {
            return ""
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func copyEnabled(of element: AXUIElement) -> Bool {
        var enabledRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledRef) == .success,
              let enabled = enabledRef as? Bool else {
            return false
        }
        return enabled
    }
}
