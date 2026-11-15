import AppKit
import ChocliftCore
import Foundation

enum MacSessionActionPack {
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

        return SessionCompanionActionRouting.execute(
            id: id,
            frontmost: frontApp.map(makeTarget),
            preferred: preferredApp.map(makeTarget),
            selfPID: Int32(selfPID),
            hostBundleIdentifier: hostBundleID,
            language: language
        ) { target in
            if let frontApp, Int32(frontApp.processIdentifier) == target.pid {
                return frontApp.hide()
            }
            if let preferredApp, Int32(preferredApp.processIdentifier) == target.pid {
                return preferredApp.hide()
            }
            guard let running = NSRunningApplication(processIdentifier: pid_t(target.pid)),
                  !running.isTerminated else {
                return false
            }
            return running.hide()
        }
    }

    private static func makeTarget(_ app: NSRunningApplication) -> SessionAppTarget {
        SessionAppTarget(
            pid: Int32(app.processIdentifier),
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName,
            isRegular: app.activationPolicy == .regular,
            isTerminated: app.isTerminated
        )
    }
}
