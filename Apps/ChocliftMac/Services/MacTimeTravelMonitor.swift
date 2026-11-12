import AppKit
import ChocliftCore
import Foundation

@MainActor
public final class MacTimeTravelMonitor: ObservableObject {
    @Published public private(set) var timeline: [RecentAppEntry] = []
    @Published public private(set) var frontmostBundleID: String?
    @Published public private(set) var frontmostAppName: String?
    public private(set) var lastExternalAppPID: pid_t?

    public var onTimelineChanged: (([RecentAppEntry]) -> Void)?
    public var onFrontmostChanged: ((String?, String?) -> Void)?

    private var entriesByBundleID: [String: RecentAppEntry] = [:]
    private var pinnedBundleIDs: Set<String> = []
    private var excludedBundleIDs: Set<String> = ["com.apple.loginwindow"]
    private var workspaceObservers: [NSObjectProtocol] = []
    private let selfBundleID: String

    public init(selfBundleID: String = Bundle.main.bundleIdentifier ?? "com.choclift.mac") {
        self.selfBundleID = selfBundleID
    }

    public func start(pinned: [String], excluded: [String]) {
        stop()
        pinnedBundleIDs = Set(pinned)
        excludedBundleIDs = Set(excluded).union([selfBundleID, "com.apple.loginwindow"])

        seedInitialRunningApps()

        let nc = NSWorkspace.shared.notificationCenter
        let activateToken = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, let app else { return }
                self.handleAppActivated(app)
            }
        }

        let launchToken = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, let app else { return }
                self.handleAppLaunched(app)
            }
        }

        let terminateToken = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, let app else { return }
                self.handleAppTerminated(app)
            }
        }

        workspaceObservers = [activateToken, launchToken, terminateToken]
    }

    public func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        for obs in workspaceObservers {
            nc.removeObserver(obs)
        }
        workspaceObservers.removeAll()
    }

    public func updateFilters(pinned: [String], excluded: [String]) {
        pinnedBundleIDs = Set(pinned)
        excludedBundleIDs = Set(excluded).union([selfBundleID, "com.apple.loginwindow"])

        for bundleID in excludedBundleIDs where bundleID != "com.apple.finder" {
            entriesByBundleID.removeValue(forKey: bundleID)
        }

        // Ensure pinned apps appear even if not currently running
        for pinnedID in pinnedBundleIDs where !excludedBundleIDs.contains(pinnedID) {
            if entriesByBundleID[pinnedID] == nil {
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pinnedID) {
                    let rawName = FileManager.default.displayName(atPath: appURL.path)
                    let name = rawName.lowercased().hasSuffix(".app") ? String(rawName.dropLast(4)) : rawName
                    entriesByBundleID[pinnedID] = RecentAppEntry(
                        bundleIdentifier: pinnedID,
                        appName: name,
                        appPath: appURL.path,
                        lastActivatedAt: Date.distantPast,
                        activationCount: 0,
                        isFrontmost: false,
                        isPinned: true,
                        isRunning: false
                    )
                }
            }
        }

        for key in entriesByBundleID.keys {
            entriesByBundleID[key]?.isPinned = pinnedBundleIDs.contains(key)
        }

        rebuildAndPublishTimeline()
    }

    public func quitOrHide(bundleIdentifier: String, shouldQuit: Bool) -> (success: Bool, message: String) {
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        guard let target = matches.first(where: { !$0.isTerminated }) else {
            return (false, L10n.tr("该应用当前未运行", "App is not running"))
        }
        let name = target.localizedName ?? bundleIdentifier
        if shouldQuit {
            let ok = target.terminate()
            return ok
                ? (true, L10n.tr("已退出 \(name)", "Quit \(name)"))
                : (false, L10n.tr("无法退出 \(name)", "Could not quit \(name)"))
        } else {
            let ok = target.hide()
            return ok
                ? (true, L10n.tr("已隐藏 \(name)", "Hid \(name)"))
                : (false, L10n.tr("无法隐藏 \(name)", "Could not hide \(name)"))
        }
    }

    // MARK: - Internal Workspace Handlers

    private func seedInitialRunningApps() {
        entriesByBundleID.removeAll()
        let running = NSWorkspace.shared.runningApplications
        let front = NSWorkspace.shared.frontmostApplication
        var offsetSeconds: TimeInterval = 0

        for app in running where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier,
                  !excludedBundleIDs.contains(bundleID) else {
                continue
            }
            let isFront = (app.processIdentifier == front?.processIdentifier)
            if isFront {
                frontmostBundleID = bundleID
                frontmostAppName = app.localizedName
                lastExternalAppPID = app.processIdentifier
            } else if lastExternalAppPID == nil {
                lastExternalAppPID = app.processIdentifier
            }

            entriesByBundleID[bundleID] = RecentAppEntry(
                bundleIdentifier: bundleID,
                appName: app.localizedName ?? bundleID,
                appPath: app.bundleURL?.path,
                lastActivatedAt: isFront ? Date() : Date().addingTimeInterval(-30 - offsetSeconds),
                activationCount: 1,
                isFrontmost: isFront,
                isPinned: pinnedBundleIDs.contains(bundleID),
                isRunning: true
            )
            offsetSeconds += 5
        }

        updateFilters(pinned: Array(pinnedBundleIDs), excluded: Array(excludedBundleIDs))
    }

    private func handleAppActivated(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }

        if bundleID != selfBundleID && app.activationPolicy == .regular {
            lastExternalAppPID = app.processIdentifier
            frontmostBundleID = bundleID
            frontmostAppName = app.localizedName
            onFrontmostChanged?(bundleID, app.localizedName)
        }

        guard app.activationPolicy == .regular, !excludedBundleIDs.contains(bundleID) else {
            return
        }

        for key in entriesByBundleID.keys {
            entriesByBundleID[key]?.isFrontmost = (key == bundleID)
        }

        if var existing = entriesByBundleID[bundleID] {
            existing.lastActivatedAt = Date()
            existing.activationCount += 1
            existing.isFrontmost = true
            existing.isRunning = true
            existing.appName = app.localizedName ?? existing.appName
            existing.appPath = app.bundleURL?.path ?? existing.appPath
            existing.isPinned = pinnedBundleIDs.contains(bundleID)
            entriesByBundleID[bundleID] = existing
        } else {
            entriesByBundleID[bundleID] = RecentAppEntry(
                bundleIdentifier: bundleID,
                appName: app.localizedName ?? bundleID,
                appPath: app.bundleURL?.path,
                lastActivatedAt: Date(),
                activationCount: 1,
                isFrontmost: true,
                isPinned: pinnedBundleIDs.contains(bundleID),
                isRunning: true
            )
        }

        rebuildAndPublishTimeline()
    }

    private func handleAppLaunched(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier,
              !excludedBundleIDs.contains(bundleID) else {
            return
        }
        if var existing = entriesByBundleID[bundleID] {
            existing.isRunning = true
            existing.lastActivatedAt = Date()
            entriesByBundleID[bundleID] = existing
        } else {
            entriesByBundleID[bundleID] = RecentAppEntry(
                bundleIdentifier: bundleID,
                appName: app.localizedName ?? bundleID,
                appPath: app.bundleURL?.path,
                lastActivatedAt: Date(),
                activationCount: 1,
                isFrontmost: false,
                isPinned: pinnedBundleIDs.contains(bundleID),
                isRunning: true
            )
        }
        rebuildAndPublishTimeline()
    }

    private func handleAppTerminated(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        if pinnedBundleIDs.contains(bundleID), var existing = entriesByBundleID[bundleID] {
            existing.isRunning = false
            existing.isFrontmost = false
            entriesByBundleID[bundleID] = existing
        } else {
            entriesByBundleID.removeValue(forKey: bundleID)
        }
        rebuildAndPublishTimeline()
    }

    private func rebuildAndPublishTimeline() {
        let sorted = Array(RecentAppEntry.sortTimeline(Array(entriesByBundleID.values)).prefix(24))
        if sorted != timeline {
            timeline = sorted
            onTimelineChanged?(sorted)
        }
    }
}
