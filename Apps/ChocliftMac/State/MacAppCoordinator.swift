import AppKit
import ChocliftCore
import Foundation
import ServiceManagement
import SwiftUI

public enum MacStudioSection: String, CaseIterable, Identifiable {
    case chocolateBar
    case emojiBar
    case timeTravel
    case gestures
    case devicesAndSettings

    public var id: String { rawValue }

    public var sfSymbol: String {
        switch self {
        case .chocolateBar: return "square.grid.2x2.fill"
        case .emojiBar: return "face.smiling.inverse"
        case .timeTravel: return "clock.arrow.circlepath"
        case .gestures: return "hand.draw.fill"
        case .devicesAndSettings: return "iphone.radiowaves.left.and.right"
        }
    }

    public func title(in lang: AppLanguage) -> String {
        switch self {
        case .chocolateBar: return L10n.tr("巧克力栏", "Chocolate Bar", language: lang)
        case .emojiBar: return L10n.tr("表情栏", "Emoji Bar", language: lang)
        case .timeTravel: return L10n.tr("时间旅行", "Time Travel", language: lang)
        case .gestures: return L10n.tr("触控手势", "Gestures", language: lang)
        case .devicesAndSettings: return L10n.tr("设备与设置", "Devices & Prefs", language: lang)
        }
    }
}

public struct MacActivityEvent: Identifiable, Equatable {
    public let id = UUID()
    public let timestamp = Date()
    public let deviceName: String
    public let summary: String
    public let isSuccess: Bool
}

@MainActor
public final class MacAppCoordinator: ObservableObject, MacServerEngineDelegate {
    @Published public var selectedSection: MacStudioSection = .chocolateBar
    @Published public var selectedPageIndex: Int = 0
    @Published public var selectedEmojiSlideIndex: Int = 0
    @Published public var showPairingPopover: Bool = false

    @Published public var profile: ChocliftWorkspaceProfile
    @Published public private(set) var installedApps: [InstalledAppSummary] = []
    @Published public private(set) var installedShortcuts: [InstalledShortcutSummary] = []
    @Published public private(set) var isScanningCatalog: Bool = false
    @Published public private(set) var isAccessibilityGranted: Bool = false
    @Published public private(set) var isEditingTextOnMac: Bool = false
    @Published public private(set) var focusedTextAppName: String?
    @Published public private(set) var activityLog: [MacActivityEvent] = []
    @Published public private(set) var statusBannerMessage: String?
    @Published public private(set) var launchAtLoginEnabled: Bool = false

    public let server: MacServerEngine
    public let timeTravel: MacTimeTravelMonitor
    public let windowService: MacAccessibilityAndWindowService
    public let inputService: MacInputAndMediaService
    public let catalogService: MacAppAndShortcutCatalogService

    private let appSupportDirectory: URL
    private let profileFileURL: URL
    private let pairedDevicesFileURL: URL
    private var monitorTimerTask: Task<Void, Never>?

    public init() {
        let fm = FileManager.default
        let baseSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = baseSupport.appendingPathComponent("Choclift", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        self.appSupportDirectory = dir
        self.profileFileURL = dir.appendingPathComponent("workspace_profile.json")
        self.pairedDevicesFileURL = dir.appendingPathComponent("paired_devices.json")

        let loadedProfile: ChocliftWorkspaceProfile = {
            if let data = try? Data(contentsOf: dir.appendingPathComponent("workspace_profile.json")),
               let decoded = try? JSONDecoder().decode(ChocliftWorkspaceProfile.self, from: data) {
                return decoded
            }
            return ChocliftDefaults.makeDefaultProfile()
        }()

        let loadedDevices: [PairedDeviceRecord] = {
            if let data = try? Data(contentsOf: dir.appendingPathComponent("paired_devices.json")),
               let decoded = try? JSONDecoder().decode([PairedDeviceRecord].self, from: data) {
                return decoded
            }
            return []
        }()

        let persistedMacID: String = {
            let key = "com.choclift.mac.uniqueHostID"
            if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
                return existing
            }
            let created = UUID().uuidString
            UserDefaults.standard.set(created, forKey: key)
            return created
        }()

        let computerName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

        self.profile = loadedProfile
        let winSvc = MacAccessibilityAndWindowService()
        self.windowService = winSvc
        self.inputService = MacInputAndMediaService(windowService: winSvc)
        self.catalogService = MacAppAndShortcutCatalogService()
        self.timeTravel = MacTimeTravelMonitor()
        self.server = MacServerEngine(
            macID: persistedMacID,
            macName: computerName,
            initialPairedDevices: loadedDevices
        )
        self.isAccessibilityGranted = winSvc.isAccessibilityTrusted()
        self.launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)

        self.server.delegate = self
        setupPipelines()
    }

    public var lang: AppLanguage {
        profile.settings.language
    }

    public var palette: ChocPalette {
        ChocPalette.forTheme(profile.settings.theme)
    }

    private func setupPipelines() {
        timeTravel.onTimelineChanged = { [weak self] entries in
            guard let self else { return }
            self.server.broadcast(.recentAppsUpdated(entries))
            let bundles = Set(entries.map(\.bundleIdentifier))
            self.server.pushMissingIconsToAllSessions(bundleIDs: bundles)
        }

        timeTravel.onFrontmostChanged = { [weak self] bundleID, appName in
            guard let self else { return }
            self.server.broadcast(.frontmostAppChanged(bundleIdentifier: bundleID, appName: appName))
        }

        timeTravel.start(
            pinned: profile.pinnedTimeTravelBundleIDs,
            excluded: profile.settings.excludedTimeTravelBundleIDs
        )

        server.start(preferredPort: ChocliftDefaults.defaultTCPPort, advertiseBonjour: true)

        refreshCatalog()
        startAccessibilityAndTextFocusLoop()
    }

    public func refreshCatalog() {
        guard !isScanningCatalog else { return }
        isScanningCatalog = true
        Task { @MainActor in
            async let appsTask = catalogService.scanInstalledApps()
            async let shortcutsTask = catalogService.fetchInstalledShortcuts()
            let (apps, shortcuts) = await (appsTask, shortcutsTask)
            self.installedApps = apps
            self.installedShortcuts = shortcuts
            self.isScanningCatalog = false
        }
    }

    private func startAccessibilityAndTextFocusLoop() {
        monitorTimerTask?.cancel()
        let myPID = ProcessInfo.processInfo.processIdentifier
        monitorTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self else { return }

                let trusted = self.windowService.isAccessibilityTrusted()
                if trusted != self.isAccessibilityGranted {
                    self.isAccessibilityGranted = trusted
                    self.server.broadcast(.accessibilityStatusChanged(isTrusted: trusted))
                }

                let focus = self.windowService.inspectFocusedTextInput(excludingPID: myPID)
                if focus.isEditing != self.isEditingTextOnMac || focus.appName != self.focusedTextAppName {
                    self.isEditingTextOnMac = focus.isEditing
                    self.focusedTextAppName = focus.appName
                    if self.profile.settings.autoShowEmojiBarWhenTyping {
                        self.server.broadcast(.textFieldFocusChanged(isEditingText: focus.isEditing, appName: focus.appName))
                    }
                }
            }
        }
    }

    // MARK: - Profile Editing & Persistence

    public func mutateProfile(_ mutation: (inout ChocliftWorkspaceProfile) -> Void, broadcastOriginDeviceID: String? = nil) {
        var next = profile
        mutation(&next)
        next.bumpRevision()
        applyAndSaveProfile(next, broadcastOriginDeviceID: broadcastOriginDeviceID)
    }

    private func applyAndSaveProfile(_ next: ChocliftWorkspaceProfile, broadcastOriginDeviceID: String?) {
        self.profile = next
        if let data = try? JSONEncoder().encode(next) {
            try? data.write(to: profileFileURL, options: .atomic)
        }

        timeTravel.updateFilters(
            pinned: next.pinnedTimeTravelBundleIDs,
            excluded: next.settings.excludedTimeTravelBundleIDs
        )

        server.broadcast(.profileUpdated(next), excludingDeviceID: broadcastOriginDeviceID)

        var referencedBundles = Set<String>()
        for page in next.pages {
            for slot in page.slots {
                if let bid = slot?.bundleIdentifier {
                    referencedBundles.insert(bid)
                }
            }
        }
        server.pushMissingIconsToAllSessions(bundleIDs: referencedBundles)
    }

    public func setSlotItem(_ item: BarItem?, pageIndex: Int, slotIndex: Int) {
        guard profile.pages.indices.contains(pageIndex),
              profile.pages[pageIndex].slots.indices.contains(slotIndex) else { return }
        mutateProfile { draft in
            draft.pages[pageIndex].slots[slotIndex] = item
        }
    }

    public func swapSlots(pageIndex: Int, fromSlot: Int, toSlot: Int) {
        guard fromSlot != toSlot,
              profile.pages.indices.contains(pageIndex),
              profile.pages[pageIndex].slots.indices.contains(fromSlot),
              profile.pages[pageIndex].slots.indices.contains(toSlot) else { return }
        mutateProfile { draft in
            draft.pages[pageIndex].slots.swapAt(fromSlot, toSlot)
        }
    }

    public func handleDroppedFileOrURL(_ url: URL, pageIndex: Int, slotIndex: Int) -> Bool {
        if url.isFileURL && url.pathExtension.lowercased() == "app" {
            guard let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier else {
                return false
            }
            let rawName = FileManager.default.displayName(atPath: url.path)
            let appName = rawName.lowercased().hasSuffix(".app") ? String(rawName.dropLast(4)) : rawName
            _ = catalogService.iconData(forBundleID: bundleID, fallbackPath: url.path)
            let item = BarItem(kind: .macApp(bundleIdentifier: bundleID, appName: appName, appPath: url.path))
            setSlotItem(item, pageIndex: pageIndex, slotIndex: slotIndex)
            return true
        } else if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            let host = url.host()?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
            let item = BarItem(
                kind: .website(
                    url: url.absoluteString,
                    title: host.capitalized,
                    emoji: "🌐",
                    backgroundHex: "#2563EB",
                    switchExistingTab: true
                )
            )
            setSlotItem(item, pageIndex: pageIndex, slotIndex: slotIndex)
            return true
        }
        return false
    }

    public func togglePinApp(bundleIdentifier: String) {
        mutateProfile { draft in
            if let idx = draft.pinnedTimeTravelBundleIDs.firstIndex(of: bundleIdentifier) {
                draft.pinnedTimeTravelBundleIDs.remove(at: idx)
            } else {
                draft.pinnedTimeTravelBundleIDs.append(bundleIdentifier)
            }
        }
    }

    public func requestAccessibilityPermission() {
        isAccessibilityGranted = windowService.promptForAccessibilityPermission()
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        } catch {
            flashBanner(error.localizedDescription)
        }
    }

    public func resetToFactoryDefaults() {
        let defaults = ChocliftDefaults.makeDefaultProfile()
        applyAndSaveProfile(defaults, broadcastOriginDeviceID: nil)
        flashBanner(L10n.tr("已恢复默认巧克力栏布局", "Restored default Chocolate Bar layout", language: lang))
    }

    // MARK: - Local & Remote Action Execution

    public func executeBarItem(_ item: BarItem, triggeredBy deviceName: String) {
        Task { @MainActor in
            let result: (success: Bool, message: String)
            switch item.kind {
            case .macApp(let bundleID, _, let appPath, _):
                result = await catalogService.launchOrActivateApp(
                    bundleIdentifier: bundleID,
                    appPath: appPath,
                    windowService: windowService
                )
            case .shortcut(let shortcutName, _, _):
                result = await catalogService.runShortcut(named: shortcutName)
            case .website(let url, _, _, _, let switchExistingTab):
                result = await catalogService.openWebsite(rawURL: url, switchExistingTab: switchExistingTab)
            case .systemAction(let action, _, _):
                result = inputService.executeSystemAction(action, preferredPID: timeTravel.lastExternalAppPID)
            }
            recordActivity(deviceName: deviceName, summary: result.message, isSuccess: result.success)
        }
    }

    public func executeEmojiInsertion(_ emoji: String, triggeredBy deviceName: String) -> (success: Bool, message: String) {
        if let pid = timeTravel.lastExternalAppPID,
           let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let target = NSRunningApplication(processIdentifier: pid) {
            target.activate()
        }
        let result = inputService.insertEmojiAtCursor(emoji)
        recordActivity(deviceName: deviceName, summary: result.message, isSuccess: result.success)
        return result
    }

    public func executeGesture(_ gesture: TouchGestureType, triggeredBy deviceName: String) -> (success: Bool, message: String) {
        guard let mappedAction = profile.gestureConfig.action(for: gesture) else {
            return (false, L10n.tr("该手势当前已停用", "Gesture is currently disabled", language: lang))
        }
        let result = inputService.executeSystemAction(mappedAction, preferredPID: timeTravel.lastExternalAppPID)
        let summary = "\(gesture.title(in: lang)) → \(result.message)"
        recordActivity(deviceName: deviceName, summary: summary, isSuccess: result.success)
        return result
    }

    private func recordActivity(deviceName: String, summary: String, isSuccess: Bool) {
        let event = MacActivityEvent(deviceName: deviceName, summary: summary, isSuccess: isSuccess)
        activityLog.insert(event, at: 0)
        if activityLog.count > 40 {
            activityLog.removeLast(activityLog.count - 40)
        }
        flashBanner(summary)
    }

    public func flashBanner(_ text: String) {
        statusBannerMessage = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.8))
            if self?.statusBannerMessage == text {
                self?.statusBannerMessage = nil
            }
        }
    }

    // MARK: - MacServerEngineDelegate

    public func serverCurrentProfile() -> ChocliftWorkspaceProfile {
        profile
    }

    public func serverCurrentRecentApps() -> [RecentAppEntry] {
        timeTravel.timeline
    }

    public func serverFrontmostBundleID() -> String? {
        timeTravel.frontmostBundleID
    }

    public func serverTextInputState() -> (isEditing: Bool, appName: String?) {
        (isEditingTextOnMac, focusedTextAppName)
    }

    public func serverIsAccessibilityGranted() -> Bool {
        isAccessibilityGranted
    }

    public func serverIcons(for bundleIDs: [String]) -> [String: Data] {
        catalogService.iconsBatch(for: bundleIDs)
    }

    public func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {
        if let data = try? JSONEncoder().encode(devices) {
            try? data.write(to: pairedDevicesFileURL, options: .atomic)
        }
    }

    public func serverDidReceiveAuthenticatedMessage(
        _ message: ClientMessage,
        from device: PairedDeviceRecord,
        reply: @escaping @MainActor (ServerMessage) -> Void
    ) {
        switch message {
        case .triggerBarItem(let item):
            Task { @MainActor in
                let result: (success: Bool, message: String)
                switch item.kind {
                case .macApp(let bundleID, _, let appPath, _):
                    result = await catalogService.launchOrActivateApp(
                        bundleIdentifier: bundleID,
                        appPath: appPath,
                        windowService: windowService
                    )
                case .shortcut(let shortcutName, _, _):
                    result = await catalogService.runShortcut(named: shortcutName)
                case .website(let url, _, _, _, let switchExistingTab):
                    result = await catalogService.openWebsite(rawURL: url, switchExistingTab: switchExistingTab)
                case .systemAction(let action, _, _):
                    result = inputService.executeSystemAction(action, preferredPID: timeTravel.lastExternalAppPID)
                }
                recordActivity(deviceName: device.deviceName, summary: result.message, isSuccess: result.success)
                reply(.actionFeedback(success: result.success, title: item.displayTitle(in: lang), detail: result.message))
            }

        case .activateRecentApp(let bundleIdentifier, let appPath):
            Task { @MainActor in
                let result = await catalogService.launchOrActivateApp(
                    bundleIdentifier: bundleIdentifier,
                    appPath: appPath,
                    windowService: windowService
                )
                recordActivity(deviceName: device.deviceName, summary: result.message, isSuccess: result.success)
                reply(.actionFeedback(success: result.success, title: bundleIdentifier, detail: result.message))
            }

        case .setRecentAppPinned(let bundleIdentifier, let isPinned):
            mutateProfile { draft in
                if isPinned {
                    if !draft.pinnedTimeTravelBundleIDs.contains(bundleIdentifier) {
                        draft.pinnedTimeTravelBundleIDs.append(bundleIdentifier)
                    }
                } else {
                    draft.pinnedTimeTravelBundleIDs.removeAll { $0 == bundleIdentifier }
                }
            }
            let msg = isPinned
                ? L10n.tr("已固定到时间旅行栏", "Pinned to Time Travel", language: lang)
                : L10n.tr("已取消固定", "Unpinned from Time Travel", language: lang)
            reply(.actionFeedback(success: true, title: msg, detail: nil))

        case .quitOrHideApp(let bundleIdentifier, let shouldQuit):
            let res = timeTravel.quitOrHide(bundleIdentifier: bundleIdentifier, shouldQuit: shouldQuit)
            recordActivity(deviceName: device.deviceName, summary: res.message, isSuccess: res.success)
            reply(.actionFeedback(success: res.success, title: res.message, detail: nil))

        case .insertEmoji(let emoji):
            let res = executeEmojiInsertion(emoji, triggeredBy: device.deviceName)
            reply(.actionFeedback(success: res.success, title: emoji, detail: res.message))

        case .performGesture(let gesture):
            let res = executeGesture(gesture, triggeredBy: device.deviceName)
            reply(.actionFeedback(success: res.success, title: gesture.title(in: lang), detail: res.message))

        case .performQuickAction(let action):
            let res = inputService.executeSystemAction(action, preferredPID: timeTravel.lastExternalAppPID)
            recordActivity(deviceName: device.deviceName, summary: res.message, isSuccess: res.success)
            reply(.actionFeedback(success: res.success, title: action.title(in: lang), detail: res.message))

        case .updateProfile(let updatedProfile):
            applyAndSaveProfile(updatedProfile, broadcastOriginDeviceID: device.deviceID)
            recordActivity(
                deviceName: device.deviceName,
                summary: L10n.tr("已同步来自 \(device.deviceName) 的布局修改", "Synced layout edit from \(device.deviceName)", language: lang),
                isSuccess: true
            )

        case .requestMacCatalog:
            Task { @MainActor in
                if installedApps.isEmpty {
                    installedApps = await catalogService.scanInstalledApps()
                }
                installedShortcuts = await catalogService.fetchInstalledShortcuts()
                reply(.macCatalogSnapshot(apps: installedApps, shortcuts: installedShortcuts))
            }

        default:
            break
        }
    }
}
