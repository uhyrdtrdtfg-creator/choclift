import AppKit
import ChocliftCore
import Foundation

enum MacSessionShowActionPack {
    static func run(
        id: String,
        language: AppLanguage = .system
    ) -> (success: Bool, message: String) {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                runOnMainActor(id: id, language: language)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                runOnMainActor(id: id, language: language)
            }
        }
    }

    @MainActor
    private static func runOnMainActor(
        id: String,
        language: AppLanguage
    ) -> (success: Bool, message: String) {
        let runningApps = NSWorkspace.shared.runningApplications
        var appByPID: [Int32: NSRunningApplication] = [:]
        appByPID.reserveCapacity(runningApps.count)

        var candidates: [SessionShowAppCandidate] = []
        candidates.reserveCapacity(runningApps.count)

        for app in runningApps {
            let pid = app.processIdentifier
            if pid > 0 {
                appByPID[pid] = app
            }
            candidates.append(
                SessionShowAppCandidate(
                    pid: pid,
                    bundleIdentifier: app.bundleIdentifier,
                    localizedName: app.localizedName,
                    isRegularActivationPolicy: app.activationPolicy == .regular,
                    isTerminated: app.isTerminated,
                    isHidden: app.isHidden
                )
            )
        }

        let outcome = SessionShowCompanionAction.execute(
            id: id,
            candidates: candidates,
            selfPID: ProcessInfo.processInfo.processIdentifier,
            selfBundleIdentifier: Bundle.main.bundleIdentifier ?? SessionShowCompanionAction.chocliftBundleIdentifier,
            language: language,
            unhide: { candidate in
                guard let app = appByPID[candidate.pid], !app.isTerminated else {
                    return false
                }
                return app.unhide()
            }
        )
        return (outcome.success, outcome.message)
    }
}
