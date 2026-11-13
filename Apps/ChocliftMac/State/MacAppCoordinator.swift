import AppKit
import ChocliftCore
import Foundation
import ServiceManagement
import SwiftUI

public enum MacStudioSection: String, CaseIterable, Identifiable {
    case chocolateBar
    case flows
    case emojiBar
    case timeTravel
    case gestures
    case devicesAndSettings

    public var id: String { rawValue }

    public var sfSymbol: String {
        switch self {
        case .chocolateBar: return "square.grid.2x2.fill"
        case .flows: return "arrow.triangle.branch"
        case .emojiBar: return "face.smiling.inverse"
        case .timeTravel: return "clock.arrow.circlepath"
        case .gestures: return "hand.draw.fill"
        case .devicesAndSettings: return "iphone.radiowaves.left.and.right"
        }
    }

    public func title(in lang: AppLanguage) -> String {
        switch self {
        case .chocolateBar: return L10n.tr("巧克力栏", "Chocolate Bar", language: lang)
        case .flows: return L10n.tr("动作流", "Flows", language: lang)
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
    private static let notchPanelEnabledKey = "com.choclift.mac.notchPanelEnabled"
    private static let leftEdgePanelEnabledKey = "com.choclift.mac.leftEdgePanelEnabled"

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
    @Published public private(set) var notchPanelEnabled: Bool = true
    @Published public private(set) var leftEdgePanelEnabled: Bool = false
    @Published public private(set) var runningFlowID: UUID?
    @Published public private(set) var orcaStatus: OrcaTaskStatusSnapshot?
    @Published public private(set) var canUndoWindowMove: Bool = false

    public enum MacVisibleSurface: Hashable {
        case studioWindow
        case menuBarPopover
    }

    private static let orcaMinPollIntervalSeconds: TimeInterval = 5.0

    public let server: MacServerEngine
    public let timeTravel: MacTimeTravelMonitor
    public let windowService: MacAccessibilityAndWindowService
    public let inputService: MacInputAndMediaService
    public let catalogService: MacAppAndShortcutCatalogService
    public private(set) var notchPanelController: MacNotchPanelController?
    public let orcaStatusService: MacOrcaStatusService
    public let systemControlService: MacSystemControlService

    private let appSupportDirectory: URL
    private let profileFileURL: URL
    private let pairedDevicesFileURL: URL
    private var monitorTimerTask: Task<Void, Never>?
    private var orcaPollTimerTask: Task<Void, Never>?
    private var pendingFlowQueueTask: Task<Void, Never>?
    private var visibleMacSurfaces: Set<MacVisibleSurface> = []
    private var lastOrcaPollStartedAt: Date = .distantPast
    private var isPollingOrcaStatus: Bool = false

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
        self.orcaStatusService = MacOrcaStatusService()
        self.systemControlService = MacSystemControlService()
        self.timeTravel = MacTimeTravelMonitor()
        self.server = MacServerEngine(
            macID: persistedMacID,
            macName: computerName,
            initialPairedDevices: loadedDevices
        )
        self.isAccessibilityGranted = winSvc.isAccessibilityTrusted()
        self.launchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
        self.notchPanelEnabled = UserDefaults.standard.object(forKey: Self.notchPanelEnabledKey) as? Bool ?? true
        self.leftEdgePanelEnabled = UserDefaults.standard.object(forKey: Self.leftEdgePanelEnabledKey) as? Bool ?? false

        self.server.delegate = self
        let panelCtrl = MacNotchPanelController(coordinator: self)
        self.notchPanelController = panelCtrl
        setupPipelines()
        panelCtrl.start()
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

        systemControlService.canUndoWindowMoveProvider = { [weak self] in
            self?.windowService.canUndoLastWindowMove ?? false
        }
        windowService.onUndoAvailabilityChanged = { [weak self] in
            guard let self else { return }
            self.canUndoWindowMove = self.windowService.canUndoLastWindowMove
            self.systemControlService.syncWindowUndoAvailability()
        }
        systemControlService.onStateChanged = { [weak self] state in
            self?.server.broadcastControlStripState(state)
        }
        systemControlService.start()

        server.start(preferredPort: ChocliftDefaults.defaultTCPPort, advertiseBonjour: true)

        refreshCatalog()
        startAccessibilityAndTextFocusLoop()
        startOrcaStatusPollLoop()
    }

    public func setMacSurfaceVisible(_ surface: MacVisibleSurface, isVisible: Bool) {
        if isVisible {
            visibleMacSurfaces.insert(surface)
            pollOrcaStatusIfEligible()
        } else {
            visibleMacSurfaces.remove(surface)
        }
    }

    private var shouldPollOrcaStatus: Bool {
        if server.connectedDeviceCount > 0 {
            return true
        }
        if visibleMacSurfaces.contains(.menuBarPopover) {
            return true
        }
        if visibleMacSurfaces.contains(.studioWindow) {
            if let app = NSApp {
                let anyStudioWindowVisible = app.windows.contains { win in
                    win.isVisible && !win.isMiniaturized && win.frame.width >= 240 && win.frame.height >= 180
                }
                if anyStudioWindowVisible {
                    return true
                }
            } else {
                return true
            }
        }
        return false
    }

    private func startOrcaStatusPollLoop() {
        orcaPollTimerTask?.cancel()
        orcaPollTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pollOrcaStatusIfEligible()
                try? await Task.sleep(for: .seconds(1.0))
            }
        }
    }

    private func pollOrcaStatusIfEligible() {
        guard shouldPollOrcaStatus, !isPollingOrcaStatus else { return }
        let now = Date()
        guard now.timeIntervalSince(lastOrcaPollStartedAt) >= Self.orcaMinPollIntervalSeconds else {
            return
        }
        isPollingOrcaStatus = true
        lastOrcaPollStartedAt = now

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isPollingOrcaStatus = false }
            let snapshot = await self.orcaStatusService.pollStatus()
            if snapshot != self.orcaStatus {
                self.orcaStatus = snapshot
                self.server.broadcast(
                    .orcaStatusUpdated(snapshot),
                    minimumProtocolVersion: ChocliftDefaults.orcaStatusMinProtocolVersion
                )
            }
        }
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
        server.pushMissingIconsToAllSessions(bundleIDs: next.referencedAppBundleIdentifiers)
    }

    public func saveFlow(_ flow: ActionFlow) {
        var normalized = flow
        normalized.updatedAt = Date()
        mutateProfile { draft in
            draft.upsertFlow(normalized)
        }
    }

    public func deleteFlow(id: UUID) {
        mutateProfile { draft in
            _ = draft.deleteFlow(id: id)
        }
    }

    public func moveFlow(from sourceIndex: Int, to destinationIndex: Int) {
        mutateProfile { draft in
            draft.moveFlow(from: sourceIndex, to: destinationIndex)
        }
    }

    public func moveFlows(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        mutateProfile { draft in
            draft.moveFlows(fromOffsets: offsets, toOffset: destination)
        }
    }

    public func assignFlowToSlot(_ flow: ActionFlow, pageIndex: Int, slotIndex: Int) {
        guard profile.pages.indices.contains(pageIndex),
              profile.pages[pageIndex].slots.indices.contains(slotIndex) else { return }
        mutateProfile { draft in
            draft.upsertFlow(flow)
            let existingID = draft.pages[pageIndex].slots[slotIndex]?.id ?? UUID()
            draft.pages[pageIndex].slots[slotIndex] = draft.makeBarItem(for: flow, id: existingID)
        }
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
                    backgroundHex: "#FFF1EC",
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

    public func setNotchPanelEnabled(_ enabled: Bool) {
        guard notchPanelEnabled != enabled else { return }
        notchPanelEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.notchPanelEnabledKey)
        notchPanelController?.syncSettingsChanged()
    }

    public func setLeftEdgePanelEnabled(_ enabled: Bool) {
        guard leftEdgePanelEnabled != enabled else { return }
        leftEdgePanelEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.leftEdgePanelEnabledKey)
        notchPanelController?.syncSettingsChanged()
    }

    public func resetToFactoryDefaults() {
        let defaults = ChocliftDefaults.makeDefaultProfile()
        applyAndSaveProfile(defaults, broadcastOriginDeviceID: nil)
        setNotchPanelEnabled(true)
        setLeftEdgePanelEnabled(false)
        flashBanner(L10n.tr("已恢复默认巧克力栏布局", "Restored default Chocolate Bar layout", language: lang))
    }

    // MARK: - Local & Remote Action Execution

    public func executeFlow(_ flow: ActionFlow, triggeredBy deviceName: String = "Mac Studio") {
        Task { @MainActor in
            _ = await enqueueAndExecuteFlow(flow, triggeredBy: deviceName)
        }
    }

    public func executeBarItem(_ item: BarItem, triggeredBy deviceName: String) {
        Task { @MainActor in
            _ = await triggerBarItem(item, triggeredBy: deviceName)
        }
    }

    @discardableResult
    public func triggerBarItem(
        _ item: BarItem,
        triggeredBy deviceName: String
    ) async -> (success: Bool, title: String, detail: String) {
        switch item.kind {
        case .macApp(let bundleID, _, let appPath, _):
            let result = await catalogService.launchOrActivateApp(
                bundleIdentifier: bundleID,
                appPath: appPath,
                windowService: windowService
            )
            recordActivity(deviceName: deviceName, summary: result.message, isSuccess: result.success)
            return (result.success, item.displayTitle(in: lang), result.message)

        case .shortcut(let shortcutName, _, _):
            let result = await catalogService.runShortcut(named: shortcutName)
            recordActivity(deviceName: deviceName, summary: result.message, isSuccess: result.success)
            return (result.success, item.displayTitle(in: lang), result.message)

        case .website(let url, _, _, _, let switchExistingTab):
            let result = await catalogService.openWebsite(rawURL: url, switchExistingTab: switchExistingTab)
            recordActivity(deviceName: deviceName, summary: result.message, isSuccess: result.success)
            return (result.success, item.displayTitle(in: lang), result.message)

        case .systemAction(let action, _, _):
            let result = inputService.executeSystemAction(action, preferredPID: timeTravel.lastExternalAppPID)
            scheduleControlStripRefreshIfRelevant(for: action)
            recordActivity(deviceName: deviceName, summary: result.message, isSuccess: result.success)
            return (result.success, item.displayTitle(in: lang), result.message)

        case .flow(let flowID, let titleSnapshot, _, _, _):
            let flowResult = await runFlowByID(
                flowID,
                fallbackName: titleSnapshot,
                triggeredBy: deviceName
            )
            return (flowResult.success, flowResult.title, flowResult.detail)
        }
    }

    public func runFlowByID(
        _ flowID: UUID,
        fallbackName: String? = nil,
        triggeredBy deviceName: String
    ) async -> ActionFlowRunResult {
        guard let flow = profile.flow(withID: flowID) else {
            let label = (fallbackName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? fallbackName!
                : L10n.tr("动作流", "Action Flow", language: lang)
            let msg = L10n.tr(
                "未找到动作流「\(label)」，可能已被删除",
                "Flow \"\(label)\" was not found (it may have been deleted)",
                language: lang
            )
            recordActivity(deviceName: deviceName, summary: msg, isSuccess: false)
            return ActionFlowRunResult(success: false, title: msg, detail: msg, executedStepCount: 0)
        }
        return await enqueueAndExecuteFlow(flow, triggeredBy: deviceName)
    }

    private func enqueueAndExecuteFlow(
        _ flow: ActionFlow,
        triggeredBy deviceName: String
    ) async -> ActionFlowRunResult {
        let previousTask = pendingFlowQueueTask
        var capturedResult: ActionFlowRunResult?

        let nextTask = Task { @MainActor [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard let self else { return }
            self.runningFlowID = flow.id
            defer {
                if self.runningFlowID == flow.id {
                    self.runningFlowID = nil
                }
            }
            let driver = MacCoordinatorFlowDriver(coordinator: self)
            self.windowService.beginWindowUndoTransaction()
            defer {
                self.windowService.commitWindowUndoTransaction()
            }
            let res = await ActionFlowRunner.run(flow, driver: driver, language: self.lang)
            capturedResult = res
            self.recordActivity(deviceName: deviceName, summary: res.detail, isSuccess: res.success)
        }

        pendingFlowQueueTask = nextTask
        await nextTask.value

        if let capturedResult {
            return capturedResult
        }
        let fallbackMsg = L10n.tr("动作流已取消", "Flow was cancelled", language: lang)
        return ActionFlowRunResult(success: false, title: fallbackMsg, detail: fallbackMsg, executedStepCount: 0)
    }

    @discardableResult
    public func insertText(_ text: String, triggeredBy deviceName: String = "Mac Studio") -> (success: Bool, message: String) {
        let allowActivatePreferred = (deviceName == "Mac Studio") &&
            (NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier)
        let result = inputService.insertText(
            text,
            preferredPID: timeTravel.lastExternalAppPID,
            allowActivatingPreferredPID: allowActivatePreferred,
            language: lang
        )
        recordActivity(deviceName: deviceName, summary: result.message, isSuccess: result.success)
        return result
    }

    public func executeGesture(_ gesture: TouchGestureType, triggeredBy deviceName: String) -> (success: Bool, message: String) {
        guard let mappedAction = profile.gestureConfig.action(for: gesture) else {
            return (false, L10n.tr("该手势当前已停用", "Gesture is currently disabled", language: lang))
        }
        let result = inputService.executeSystemAction(mappedAction, preferredPID: timeTravel.lastExternalAppPID)
        scheduleControlStripRefreshIfRelevant(for: mappedAction)
        let summary = "\(gesture.title(in: lang)) → \(result.message)"
        recordActivity(deviceName: deviceName, summary: summary, isSuccess: result.success)
        return result
    }

    @discardableResult
    public func undoLastWindowMove(
        triggeredBy deviceName: String
    ) -> MacAccessibilityAndWindowService.WindowUndoOutcome {
        let outcome = windowService.undoLastWindowMove(language: lang)
        if case .restored(let summary) = outcome {
            recordActivity(deviceName: deviceName, summary: summary, isSuccess: true)
        }
        return outcome
    }

    private func scheduleControlStripRefreshIfRelevant(for action: SystemQuickAction) {
        switch action {
        case .volumeUp, .volumeDown, .volumeMute, .mediaPlayPause, .mediaNext, .mediaPrevious:
            systemControlService.schedulePostActionRefresh()
        default:
            break
        }
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

    public func serverCurrentOrcaStatus() -> OrcaTaskStatusSnapshot? {
        orcaStatus
    }

    public func serverIcons(for bundleIDs: [String]) -> [String: Data] {
        catalogService.iconsBatch(for: bundleIDs)
    }

    public func serverDidUpdatePairedDevices(_ devices: [PairedDeviceRecord]) {
        if let data = try? JSONEncoder().encode(devices) {
            try? data.write(to: pairedDevicesFileURL, options: .atomic)
        }
        if devices.contains(where: \.isCurrentlyConnected) {
            pollOrcaStatusIfEligible()
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
                let feedback = await triggerBarItem(item, triggeredBy: device.deviceName)
                reply(.actionFeedback(success: feedback.success, title: feedback.title, detail: feedback.detail))
            }

        case .triggerFlow(let flowID):
            Task { @MainActor in
                let flowResult = await runFlowByID(
                    flowID,
                    fallbackName: nil,
                    triggeredBy: device.deviceName
                )
                reply(.actionFeedback(success: flowResult.success, title: flowResult.title, detail: flowResult.detail))
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

        case .insertEmoji(let text):
            let res = insertText(text, triggeredBy: device.deviceName)
            let label = MacInputAndMediaService.previewLabel(for: text)
            reply(.actionFeedback(
                success: res.success,
                title: label.isEmpty ? L10n.tr("文本片段", "Snippet", language: lang) : label,
                detail: res.message
            ))

        case .performGesture(let gesture):
            let res = executeGesture(gesture, triggeredBy: device.deviceName)
            reply(.actionFeedback(success: res.success, title: gesture.title(in: lang), detail: res.message))

        case .performQuickAction(let action):
            let res = inputService.executeSystemAction(action, preferredPID: timeTravel.lastExternalAppPID)
            scheduleControlStripRefreshIfRelevant(for: action)
            recordActivity(deviceName: device.deviceName, summary: res.message, isSuccess: res.success)
            reply(.actionFeedback(success: res.success, title: action.title(in: lang), detail: res.message))

        case .requestControlStripState:
            let immediate = systemControlService.currentState
            reply(.controlStripStateUpdated(immediate))
            systemControlService.refreshNow { refreshed in
                if refreshed.hasMeaningfulDifference(from: immediate) {
                    reply(.controlStripStateUpdated(refreshed))
                }
            }

        case .setControlLevel(let kind, let level):
            let didApply: Bool
            switch kind {
            case .volume:
                didApply = systemControlService.setVolume(level: level)
            case .brightness:
                didApply = systemControlService.setBrightness(level: level)
            }
            if didApply {
                server.broadcastControlStripState(
                    systemControlService.currentState,
                    excludingDeviceID: device.deviceID
                )
            } else {
                reply(.controlStripStateUpdated(systemControlService.currentState))
            }

        case .setMicMuted(let isMuted):
            let ok = systemControlService.setMicMuted(isMuted)
            server.broadcastControlStripState(systemControlService.currentState)
            let summary = isMuted
                ? L10n.tr("已将麦克风静音", "Microphone Muted", language: lang)
                : L10n.tr("已取消麦克风静音", "Microphone Unmuted", language: lang)
            let failureDetail = L10n.tr(
                "无法切换麦克风静音状态，请检查音频输入设备。",
                "Could not change microphone mute state. Check your audio input device.",
                language: lang
            )
            recordActivity(deviceName: device.deviceName, summary: ok ? summary : failureDetail, isSuccess: ok)
            if !ok {
                reply(.actionFeedback(
                    success: false,
                    title: L10n.tr("麦克风", "Microphone", language: lang),
                    detail: failureDetail
                ))
            }

        case .undoLastWindowMove:
            let outcome = undoLastWindowMove(triggeredBy: device.deviceName)
            switch outcome {
            case .restored(let summary):
                reply(.actionFeedback(
                    success: true,
                    title: L10n.tr("已撤销窗口移动", "Undid Window Move", language: lang),
                    detail: summary
                ))
            case .nothingToUndo:
                reply(.controlStripStateUpdated(systemControlService.currentState))
            }

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

        case .focusOrcaTask(let dispatchID):
            Task { @MainActor in
                let result = await orcaStatusService.focusTaskWindow(
                    dispatchID: dispatchID,
                    language: lang,
                    windowService: windowService
                )
                recordActivity(deviceName: device.deviceName, summary: result.message, isSuccess: result.success)
                reply(.actionFeedback(success: result.success, title: "Orca", detail: result.message))
            }

        default:
            break
        }
    }
}

// MARK: - Existing-Services ActionFlowDriver Adapter

@MainActor
private final class MacCoordinatorFlowDriver: ActionFlowDriver {
    private weak var coordinator: MacAppCoordinator?

    init(coordinator: MacAppCoordinator) {
        self.coordinator = coordinator
    }

    var fallbackExternalAppPID: Int32? {
        coordinator?.timeTravel.lastExternalAppPID
    }

    func launchOrActivateApp(
        bundleIdentifier: String,
        appPath: String?
    ) async -> (success: Bool, message: String, app: FlowAppHandle?) {
        guard let coordinator else {
            return (false, "Mac coordinator unavailable", nil)
        }
        return await coordinator.catalogService.launchOrActivateAppWithHandle(
            bundleIdentifier: bundleIdentifier,
            appPath: appPath,
            windowService: coordinator.windowService
        )
    }

    func currentFrontmostApp() -> FlowAppHandle? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              !front.isTerminated,
              let bundleID = front.bundleIdentifier else {
            return nil
        }
        return FlowAppHandle(
            bundleIdentifier: bundleID,
            appName: front.localizedName ?? bundleID,
            processIdentifier: front.processIdentifier
        )
    }

    func runningApp(forBundleIdentifier bundleIdentifier: String) -> FlowAppHandle? {
        let direct = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { !$0.isTerminated })
        let resolved = direct ?? NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated &&
            $0.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
        guard let app = resolved else { return nil }
        let bid = app.bundleIdentifier ?? bundleIdentifier
        return FlowAppHandle(
            bundleIdentifier: bid,
            appName: app.localizedName ?? bid,
            processIdentifier: app.processIdentifier
        )
    }

    func waitForAdjustableWindowIfNeeded(
        for app: FlowAppHandle,
        action: SystemQuickAction
    ) async {
        guard let coordinator,
              action.isWindowAction,
              coordinator.windowService.isAccessibilityTrusted() else {
            return
        }
        coordinator.windowService.unminimizeFirstWindowIfAllMinimized(pid: app.processIdentifier)
        if coordinator.windowService.hasAdjustableWindow(forPID: app.processIdentifier) {
            return
        }
        for _ in 0..<30 {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(50))
            coordinator.windowService.unminimizeFirstWindowIfAllMinimized(pid: app.processIdentifier)
            if coordinator.windowService.hasAdjustableWindow(forPID: app.processIdentifier) {
                return
            }
        }
    }

    func executeSystemAction(
        _ action: SystemQuickAction,
        target: FlowSystemActionTarget
    ) -> (success: Bool, message: String) {
        guard let coordinator else {
            return (false, "Mac coordinator unavailable")
        }
        switch target {
        case .defaultTarget(let preferredPID):
            return coordinator.inputService.executeSystemAction(
                action,
                preferredPID: preferredPID,
                strictTargetPID: false
            )
        case .strictApp(_, let processIdentifier):
            return coordinator.inputService.executeSystemAction(
                action,
                preferredPID: processIdentifier,
                strictTargetPID: true
            )
        }
    }

    func sleep(seconds: Double) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds))
    }
}
