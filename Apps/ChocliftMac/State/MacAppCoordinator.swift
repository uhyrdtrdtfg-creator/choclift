import AppKit
import ChocliftCore
import Foundation
import ServiceManagement
import SwiftUI

public enum MacStudioSection: String, CaseIterable, Identifiable {
    case chocolateBar
    case flows
    case soundboard
    case emojiBar
    case timeTravel
    case gestures
    case devicesAndSettings

    public var id: String { rawValue }

    public var sfSymbol: String {
        switch self {
        case .chocolateBar: return "square.grid.2x2.fill"
        case .flows: return "arrow.triangle.branch"
        case .soundboard: return "speaker.wave.2.bubble.left.fill"
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
        case .soundboard: return L10n.tr("音效板", "Soundboard", language: lang)
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

public struct PendingMacSlotEditorTarget: Equatable {
    public let pageIndex: Int
    public let slotIndex: Int

    public init(pageIndex: Int, slotIndex: Int) {
        self.pageIndex = pageIndex
        self.slotIndex = slotIndex
    }
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
    @Published public private(set) var launchAtLoginRequiresApproval: Bool = false
    @Published public private(set) var connectedCompanionCount: Int = 0
    @Published public var pendingSlotEditorTarget: PendingMacSlotEditorTarget?
    @Published public private(set) var notchPanelEnabled: Bool = true
    @Published public private(set) var leftEdgePanelEnabled: Bool = false
    @Published public private(set) var runningFlowID: UUID?
    @Published public private(set) var orcaStatus: OrcaTaskStatusSnapshot?
    @Published public private(set) var canUndoWindowMove: Bool = false
    @Published public private(set) var connectedDisplays: [MacDisplayInfo] = []
    @Published public private(set) var selectedTargetDisplayID: UInt32?
    @Published public private(set) var controlStripState: ControlStripState = ControlStripState()
    @Published public private(set) var nowPlayingScrub = NowPlayingScrubController()
    @Published public private(set) var lastAudioOutputError: String?
    @Published public private(set) var clipboardPreview: ClipboardPreviewSnapshot = .empty
    @Published public private(set) var calendarSnapshot: NextCalendarEventSnapshot = .initial
    @Published public private(set) var isKeepMacAwakeEnabled: Bool = false
    @Published public private(set) var frontmostWindowSnapshot: FrontmostAppWindowSnapshot = .empty

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
    public private(set) var menuBarStatusController: MacMenuBarStatusController?
    public let launchAtLoginService: MacLaunchAtLoginService
    public var openStudioWindowAction: (() -> Void)?
    public let orcaStatusService: MacOrcaStatusService
    public let systemControlService: MacSystemControlService
    public let clipboardService: MacClipboardMonitorService
    public let screenshotService: MacMainDisplayScreenshotService
    public let calendarService: MacCalendarEventService
    public let soundboardService: MacSoundboardService
    public let keepAwakeService: MacKeepAwakeService
    public let updaterService: MacSparkleUpdaterService

    private let appSupportDirectory: URL
    private let profileFileURL: URL
    private let pairedDevicesFileURL: URL
    private var launchAtLoginStateMachine = LaunchAtLoginStateMachine(initialStatus: .notRegistered)
    private var appActiveObserver: NSObjectProtocol?
    private var monitorTimerTask: Task<Void, Never>?
    private var orcaPollTimerTask: Task<Void, Never>?
    private var pendingFlowQueueTask: Task<Void, Never>?
    private var visibleMacSurfaces: Set<MacVisibleSurface> = []
    private var lastOrcaPollStartedAt: Date = .distantPast
    private var isPollingOrcaStatus: Bool = false
    private var frontmostWindowPollTick: Int = 0

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
        self.clipboardService = MacClipboardMonitorService()
        self.screenshotService = MacMainDisplayScreenshotService()
        self.calendarService = MacCalendarEventService()
        self.soundboardService = MacSoundboardService()
        self.keepAwakeService = MacKeepAwakeService()
        self.updaterService = MacSparkleUpdaterService()
        let loginSvc = MacLaunchAtLoginService()
        self.launchAtLoginService = loginSvc
        self.timeTravel = MacTimeTravelMonitor()
        self.server = MacServerEngine(
            macID: persistedMacID,
            macName: computerName,
            initialPairedDevices: loadedDevices
        )
        self.isAccessibilityGranted = winSvc.isAccessibilityTrusted()
        self.connectedDisplays = winSvc.currentConnectedDisplays()
        self.selectedTargetDisplayID = winSvc.selectedTargetDisplayID
        self.clipboardPreview = self.clipboardService.currentPreview
        self.launchAtLoginStateMachine.refresh(using: loginSvc)
        self.launchAtLoginEnabled = self.launchAtLoginStateMachine.isEnabled
        self.launchAtLoginRequiresApproval = self.launchAtLoginStateMachine.requiresApproval
        self.notchPanelEnabled = UserDefaults.standard.object(forKey: Self.notchPanelEnabledKey) as? Bool ?? true
        self.leftEdgePanelEnabled = UserDefaults.standard.object(forKey: Self.leftEdgePanelEnabledKey) as? Bool ?? false

        self.server.delegate = self
        let panelCtrl = MacNotchPanelController(coordinator: self)
        self.notchPanelController = panelCtrl
        let statusCtrl = MacMenuBarStatusController(coordinator: self)
        self.menuBarStatusController = statusCtrl
        setupPipelines()
        panelCtrl.start()
        statusCtrl.start()
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
            self.systemControlService.syncFrontmostAppName(appName)
            self.server.broadcast(.frontmostAppChanged(bundleIdentifier: bundleID, appName: appName))
            self.refreshAndBroadcastFrontmostWindowsIfNeeded(force: true)
        }

        timeTravel.start(
            pinned: profile.pinnedTimeTravelBundleIDs,
            excluded: profile.settings.excludedTimeTravelBundleIDs
        )

        systemControlService.frontmostAppNameProvider = { [weak self] in
            self?.timeTravel.frontmostAppName
        }

        inputService.onSelectionDispatchFeedback = { [weak self] success, message in
            self?.recordActivity(deviceName: "Mac", summary: message, isSuccess: success)
        }
        inputService.mediaTransportContextProvider = { [weak self] in
            self?.systemControlService.currentMediaTransportContext() ?? MacMediaTransportContext()
        }
        inputService.mediaSeekContextProvider = { [weak self] in
            self?.systemControlService.currentMediaSeekContext() ?? MacMediaSeekContext()
        }

        keepAwakeService.onAssertionStateChanged = { [weak self] isHolding in
            guard let self else { return }
            self.isKeepMacAwakeEnabled = isHolding
            self.systemControlService.syncKeepMacAwake(isHolding)
            self.menuBarStatusController?.refresh()
        }
        systemControlService.keepMacAwakeProvider = { [weak self] in
            self?.keepAwakeService.isHoldingAssertion ?? false
        }
        systemControlService.canUndoWindowMoveProvider = { [weak self] in
            self?.windowService.canUndoLastWindowMove ?? false
        }
        systemControlService.displayTopologyProvider = { [weak self] in
            guard let self else { return (displays: [], selectedDisplayID: nil) }
            return (
                displays: self.windowService.currentConnectedDisplays(),
                selectedDisplayID: self.windowService.selectedTargetDisplayID
            )
        }
        systemControlService.soundboardVolumeProvider = { [weak self] in
            self?.profile.soundboardVolume ?? SoundboardClip.defaultVolume
        }
        windowService.onUndoAvailabilityChanged = { [weak self] in
            guard let self else { return }
            self.canUndoWindowMove = self.windowService.canUndoLastWindowMove
            self.systemControlService.syncWindowUndoAvailability()
        }
        windowService.onDisplayConfigurationChanged = { [weak self] in
            guard let self else { return }
            self.connectedDisplays = self.windowService.currentConnectedDisplays()
            self.selectedTargetDisplayID = self.windowService.selectedTargetDisplayID
            self.systemControlService.syncDisplayTopology()
        }
        systemControlService.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.controlStripState = state
            self.nowPlayingScrub.reconcile(with: state.nowPlaying)
            self.server.broadcastControlStripState(state)
        }
        systemControlService.start()
        self.controlStripState = systemControlService.currentState

        clipboardService.isTransientPasteInFlight = { [weak self] in
            self?.inputService.isStagingTransientPasteboard ?? false
        }
        clipboardService.onPreviewChanged = { [weak self] snapshot in
            guard let self else { return }
            self.clipboardPreview = snapshot
            self.server.broadcastClipboardPreview(snapshot)
        }
        clipboardService.refreshImmediately()
        self.clipboardPreview = clipboardService.currentPreview

        calendarService.onSnapshotChanged = { [weak self] snapshot in
            guard let self else { return }
            self.calendarSnapshot = snapshot
            self.server.broadcastCalendarStatus(snapshot)
        }
        calendarService.start()
        self.calendarSnapshot = calendarService.currentSnapshot

        server.start(preferredPort: ChocliftDefaults.defaultTCPPort, advertiseBonjour: true)

        refreshCatalog()
        startAccessibilityAndTextFocusLoop()
        startOrcaStatusPollLoop()

        if let appActiveObserver {
            NotificationCenter.default.removeObserver(appActiveObserver)
        }
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLaunchAtLoginStatus()
            }
        }
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

                self.clipboardService.pollIfNeeded()

                if self.server.hasFrontmostWindowSubscribers {
                    self.frontmostWindowPollTick &+= 1
                    if self.frontmostWindowPollTick % 3 == 0 {
                        self.refreshAndBroadcastFrontmostWindowsIfNeeded(force: false)
                    }
                }
            }
        }
    }

    @discardableResult
    public func refreshFrontmostWindowSnapshot() -> FrontmostAppWindowSnapshot {
        let snapshot = windowService.inspectFrontmostAppWindows(
            preferredExternalPID: timeTravel.lastExternalAppPID,
            language: lang
        )
        frontmostWindowSnapshot = snapshot
        return snapshot
    }

    private func refreshAndBroadcastFrontmostWindowsIfNeeded(force: Bool) {
        guard server.hasFrontmostWindowSubscribers else { return }
        let previous = frontmostWindowSnapshot
        let current = refreshFrontmostWindowSnapshot()
        if force || current != previous {
            server.broadcastFrontmostWindows(current)
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
        let previouslySelectedPageID: UUID? = profile.pages.indices.contains(selectedPageIndex)
            ? profile.pages[selectedPageIndex].id
            : nil
        self.profile = next
        if let previouslySelectedPageID,
           let movedIndex = next.pages.firstIndex(where: { $0.id == previouslySelectedPageID }) {
            if selectedPageIndex != movedIndex {
                selectedPageIndex = movedIndex
            }
        } else if !next.pages.isEmpty {
            let clamped = min(max(0, selectedPageIndex), next.pages.count - 1)
            if selectedPageIndex != clamped {
                selectedPageIndex = clamped
            }
        }
        if let data = try? JSONEncoder().encode(next) {
            try? data.write(to: profileFileURL, options: .atomic)
        }

        soundboardService.updateActivePlaybackVolume(next.soundboardVolume)
        systemControlService.syncSoundboardVolume(next.soundboardVolume)

        timeTravel.updateFilters(
            pinned: next.pinnedTimeTravelBundleIDs,
            excluded: next.settings.excludedTimeTravelBundleIDs
        )

        server.broadcast(.profileUpdated(next), excludingDeviceID: broadcastOriginDeviceID)
        server.pushMissingIconsToAllSessions(bundleIDs: next.referencedAppBundleIdentifiers)
        menuBarStatusController?.refresh()
    }

    private func sanitizeCompanionProfileUpdate(_ incoming: ChocliftWorkspaceProfile) -> ChocliftWorkspaceProfile {
        var merged = incoming
        if merged.pages.count > BarPage.maxPages {
            merged.pages = Array(merged.pages.prefix(BarPage.maxPages))
        }
        for idx in merged.pages.indices {
            merged.pages[idx].index = idx
            merged.pages[idx].slots = BarPage.normalizeSlots(merged.pages[idx].slots)
        }
        // Companion devices never upload audio or define arbitrary local Mac file paths.
        // Reconcile incoming soundboardClips against Mac's validated clips by UUID.
        let authoritativeByID = Dictionary(uniqueKeysWithValues: profile.soundboardClips.map { ($0.id, $0) })
        var reconciled: [SoundboardClip] = []
        for candidate in incoming.soundboardClips {
            guard let trusted = authoritativeByID[candidate.id] else { continue }
            reconciled.append(
                SoundboardClip(
                    id: trusted.id,
                    name: candidate.name,
                    filePath: trusted.filePath,
                    durationSeconds: trusted.durationSeconds,
                    emoji: candidate.emoji,
                    backgroundHex: candidate.backgroundHex,
                    createdAt: trusted.createdAt
                )
            )
        }
        merged.soundboardClips = SoundboardCatalogValidator.sanitizeBoard(reconciled)
        merged.prunePinnedStripSlots()

        // Companions may only pin plain-text items (`<= 280` chars, max 8) that either were already pinned
        // on this Mac or already appeared in the Mac clipboard preview.
        clipboardService.pollIfNeeded()
        var allowedPinTexts = Set(profile.pinnedClipboardItems.map(\.text))
        allowedPinTexts.formUnion(clipboardService.observedSafePreviewTexts)
        if let currentPreviewText = PinnedClipboardItem.sanitizedText(clipboardService.currentPreview.previewText) {
            allowedPinTexts.insert(currentPreviewText)
        }
        merged.sanitizePinnedClipboardItems(allowedTexts: allowedPinTexts)
        return merged
    }

    public func saveFlow(_ flow: ActionFlow) {
        var normalized = flow
        normalized.updatedAt = Date()
        mutateProfile { draft in
            draft.upsertFlow(normalized)
        }
    }

    private var flowDeleteGate = DestructiveActionConfirmGate()

    public func deleteFlow(id: UUID) {
        let decision = flowDeleteGate.registerTap(targetID: id.uuidString, isDestructive: true, at: ProcessInfo.processInfo.systemUptime)
        if case .requireSecondTap = decision {
            flashBanner(L10n.tr("3 秒内再点删除以确认", "Tap Delete again within 3s to confirm", language: lang))
            return
        }

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

    // MARK: - Local Soundboard & Soundboard Volume Actions (Round 3)

    public func setSoundboardVolume(_ level: Double, broadcastExcludingDeviceID: String? = nil) {
        let clamped = ControlStripLevel.clamp(level)
        soundboardService.updateActivePlaybackVolume(clamped)
        if abs(profile.soundboardVolume - clamped) >= 0.001 {
            profile.soundboardVolume = clamped
            if let data = try? JSONEncoder().encode(profile) {
                try? data.write(to: profileFileURL, options: .atomic)
            }
        }
        systemControlService.syncSoundboardVolume(clamped)
        controlStripState = systemControlService.currentState
        server.broadcastControlStripState(
            systemControlService.currentState,
            excludingDeviceID: broadcastExcludingDeviceID
        )
    }

    @discardableResult
    public func selectAudioOutputDevice(
        id: String,
        triggeredBy: String = "Mac Studio"
    ) -> (success: Bool, title: String, detail: String) {
        let res = systemControlService.setDefaultAudioOutputDevice(id: id, language: lang)
        controlStripState = systemControlService.currentState
        lastAudioOutputError = res.success ? nil : res.detail
        server.broadcastControlStripState(systemControlService.currentState)
        recordActivity(deviceName: triggeredBy, summary: res.detail, isSuccess: res.success)
        if res.success {
            flashBanner(res.detail)
        } else {
            flashBanner("\(res.title) · \(res.detail)")
        }
        return res
    }

    @discardableResult
    public func addSoundFilesFromURLs(_ urls: [URL]) -> (added: [SoundboardClip], errors: [String]) {
        guard !urls.isEmpty else { return ([], []) }
        var workingClips = profile.soundboardClips
        var newlyAdded: [SoundboardClip] = []
        var rejectionMessages: [String] = []

        for url in urls {
            switch soundboardService.prepareCandidateClip(from: url, existingClips: workingClips) {
            case .success(let clip):
                workingClips.append(clip)
                newlyAdded.append(clip)
            case .failure(let err):
                let fileName = url.lastPathComponent
                rejectionMessages.append("\(fileName): \(err.localizedDescription(in: lang))")
                if case .boardFull = err {
                    break
                }
            }
        }

        if !newlyAdded.isEmpty {
            mutateProfile { draft in
                for clip in newlyAdded {
                    _ = draft.addSoundboardClip(clip)
                }
            }
        }

        if let firstError = rejectionMessages.first {
            flashBanner(firstError)
        } else if !newlyAdded.isEmpty {
            flashBanner(
                L10n.tr(
                    "已添加 \(newlyAdded.count) 个本地音效（\(profile.soundboardClips.count)/\(SoundboardClip.maxBoardCount)）",
                    "Added \(newlyAdded.count) local sound(s) (\(profile.soundboardClips.count)/\(SoundboardClip.maxBoardCount))",
                    language: lang
                )
            )
        }

        return (newlyAdded, rejectionMessages)
    }

    public func chooseAndAddLocalSoundFiles() {
        let urls = soundboardService.presentOpenPanelForLocalSounds()
        guard !urls.isEmpty else { return }
        _ = addSoundFilesFromURLs(urls)
    }

    public func importBuiltInMacSounds() {
        let urls = soundboardService.discoverBuiltInSystemSoundURLs()
        guard !urls.isEmpty else {
            flashBanner(L10n.tr("未找到系统自带音效目录", "No built-in macOS sounds found", language: lang))
            return
        }
        let remainingSlots = max(0, SoundboardClip.maxBoardCount - profile.soundboardClips.count)
        guard remainingSlots > 0 else {
            flashBanner(SoundboardValidationError.boardFull(limit: SoundboardClip.maxBoardCount).localizedDescription(in: lang))
            return
        }
        _ = addSoundFilesFromURLs(urls)
    }

    public func updateSoundClip(
        id: UUID,
        name: String? = nil,
        emoji: String? = nil,
        backgroundHex: String? = nil
    ) {
        mutateProfile { draft in
            _ = draft.updateSoundboardClip(id: id, name: name, emoji: emoji, backgroundHex: backgroundHex)
        }
    }

    private var soundDeleteGate = DestructiveActionConfirmGate()

    public func deleteSoundClip(id: UUID) {
        let decision = soundDeleteGate.registerTap(targetID: id.uuidString, isDestructive: true, at: ProcessInfo.processInfo.systemUptime)
        if case .requireSecondTap = decision {
            flashBanner(L10n.tr("3 秒内再点移除以确认", "Tap Remove again within 3s to confirm", language: lang))
            return
        }
        if soundboardService.activeSoundID == id {
            soundboardService.stopAll()
        }
        mutateProfile { draft in
            _ = draft.deleteSoundboardClip(id: id)
        }
    }

    public func assignSoundClipToSlot(_ clip: SoundboardClip, pageIndex: Int, slotIndex: Int) {
        guard profile.pages.indices.contains(pageIndex),
              profile.pages[pageIndex].slots.indices.contains(slotIndex) else { return }
        mutateProfile { draft in
            let existingID = draft.pages[pageIndex].slots[slotIndex]?.id ?? UUID()
            draft.pages[pageIndex].slots[slotIndex] = draft.makeBarItem(for: clip, id: existingID)
        }
    }

    @discardableResult
    public func playSoundClip(
        id: UUID,
        fallbackName: String? = nil,
        triggeredBy deviceName: String = "Mac Studio"
    ) -> (success: Bool, title: String, detail: String) {
        guard let clip = profile.soundboardClip(withID: id) else {
            let label = (fallbackName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? fallbackName!
                : L10n.tr("音效", "Sound", language: lang)
            let missingMsg = L10n.tr(
                "未找到音效「\(label)」，可能已从音效板移除",
                "Sound \"\(label)\" is no longer on the soundboard",
                language: lang
            )
            recordActivity(deviceName: deviceName, summary: missingMsg, isSuccess: false)
            return (false, label, missingMsg)
        }

        let res = soundboardService.play(
            clip: clip,
            soundboardVolume: profile.soundboardVolume,
            language: lang
        )
        recordActivity(deviceName: deviceName, summary: res.message, isSuccess: res.success)
        return (res.success, clip.name, res.message)
    }

    public func stopSoundboardPlayback(triggeredBy deviceName: String = "Mac Studio") {
        soundboardService.stopAll()
        let msg = L10n.tr("已停止音效播放", "Stopped soundboard playback", language: lang)
        recordActivity(deviceName: deviceName, summary: msg, isSuccess: true)
    }

    public func setSlotItem(_ item: BarItem?, pageIndex: Int, slotIndex: Int) {
        guard profile.pages.indices.contains(pageIndex),
              profile.pages[pageIndex].slots.indices.contains(slotIndex) else { return }
        mutateProfile { draft in
            _ = draft.setSlotItem(item, pageIndex: pageIndex, slotIndex: slotIndex)
        }
    }

    @discardableResult
    public func movePage(at pageIndex: Int, direction: PageReorderDirection) -> Int? {
        guard profile.canMovePage(at: pageIndex, direction: direction) else { return nil }
        var updatedIndex: Int?
        mutateProfile { draft in
            updatedIndex = draft.movePage(at: pageIndex, direction: direction)
        }
        return updatedIndex
    }

    @discardableResult
    public func togglePinSlotToStrip(pageIndex: Int, slotIndex: Int) -> Bool {
        guard profile.pages.indices.contains(pageIndex),
              profile.pages[pageIndex].slots.indices.contains(slotIndex) else {
            return false
        }
        let coordinate = SlotCoordinate(pageID: profile.pages[pageIndex].id, slotIndex: slotIndex)
        var didSucceed = false
        mutateProfile { draft in
            didSucceed = draft.togglePinSlotToStrip(coordinate)
        }
        return didSucceed
    }

    public func swapSlots(pageIndex: Int, fromSlot: Int, toSlot: Int) {
        guard fromSlot != toSlot,
              profile.pages.indices.contains(pageIndex),
              profile.pages[pageIndex].slots.indices.contains(fromSlot),
              profile.pages[pageIndex].slots.indices.contains(toSlot) else { return }
        mutateProfile { draft in
            draft.swapSlots(pageIndex: pageIndex, fromSlot: fromSlot, toSlot: toSlot)
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
        } else if url.isFileURL && SoundboardCatalogValidator.isSupportedAudioPath(url.path) {
            let normalized = SoundboardCatalogValidator.normalizedFileKey(url.path)
            if let existingClip = profile.soundboardClips.first(where: {
                SoundboardCatalogValidator.normalizedFileKey($0.filePath) == normalized
            }) {
                assignSoundClipToSlot(existingClip, pageIndex: pageIndex, slotIndex: slotIndex)
                return true
            }
            let outcome = addSoundFilesFromURLs([url])
            if let addedClip = outcome.added.first {
                assignSoundClipToSlot(addedClip, pageIndex: pageIndex, slotIndex: slotIndex)
                return true
            }
            return false
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

    public func refreshLaunchAtLoginStatus() {
        launchAtLoginStateMachine.refresh(using: launchAtLoginService)
        launchAtLoginEnabled = launchAtLoginStateMachine.isEnabled
        launchAtLoginRequiresApproval = launchAtLoginStateMachine.requiresApproval
    }

    public func openLoginItemsSettings() {
        launchAtLoginService.openLoginItemsSystemSettings()
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginStateMachine.setEnabled(enabled, using: launchAtLoginService)
            launchAtLoginEnabled = launchAtLoginStateMachine.isEnabled
            launchAtLoginRequiresApproval = launchAtLoginStateMachine.requiresApproval
            if enabled && launchAtLoginRequiresApproval {
                flashBanner(
                    L10n.tr(
                        "请在系统设置 → 登录项中允许 Choclift",
                        "Allow Choclift in System Settings → Login Items to finish enabling",
                        language: lang
                    )
                )
            }
        } catch {
            refreshLaunchAtLoginStatus()
            flashBanner(error.localizedDescription)
        }
    }

    public func openMainStudioWindow(
        selectingSection section: MacStudioSection? = nil,
        editingSlot: PendingMacSlotEditorTarget? = nil
    ) {
        notchPanelController?.dismissPanelImmediately()
        if let section {
            selectedSection = section
        }
        if let editingSlot {
            selectedSection = .chocolateBar
            selectedPageIndex = editingSlot.pageIndex
            pendingSlotEditorTarget = editingSlot
        }

        NSApp.activate(ignoringOtherApps: true)
        openStudioWindowAction?()

        if let studioWin = NSApp.windows.first(where: { win in
            !(win is NSPanel) && (win.identifier?.rawValue.contains("studio-main") == true || win.title == "choclift")
        }) {
            if studioWin.isMiniaturized {
                studioWin.deminiaturize(nil)
            }
            studioWin.makeKeyAndOrderFront(nil)
        } else if openStudioWindowAction == nil {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
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
        if launchAtLoginEnabled || launchAtLoginRequiresApproval {
            setLaunchAtLogin(false)
        }
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
            scheduleControlStripRefreshIfRelevant(for: action, success: result.success)
            recordActivity(deviceName: deviceName, summary: result.message, isSuccess: result.success)
            return (result.success, item.displayTitle(in: lang), result.message)

        case .flow(let flowID, let titleSnapshot, _, _, _):
            let flowResult = await runFlowByID(
                flowID,
                fallbackName: titleSnapshot,
                triggeredBy: deviceName
            )
            return (flowResult.success, flowResult.title, flowResult.detail)

        case .soundboard(let soundID, let titleSnapshot, _, _):
            let soundResult = playSoundClip(
                id: soundID,
                fallbackName: titleSnapshot,
                triggeredBy: deviceName
            )
            return soundResult

        case .folder:
            // Folders open locally on companion/notch surfaces; child BarItems execute individually.
            return (true, "", "")

        case .slotReference:
            switch profile.resolveBarItem(item) {
            case .resolved(_, _, _, _, _, let resolvedItem):
                return await triggerBarItem(resolvedItem, triggeredBy: deviceName)
            case .missing:
                // Quiet missing state: do not run anything and do not raise a failure toast.
                return (true, "", "")
            }
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
        scheduleControlStripRefreshIfRelevant(for: mappedAction, success: result.success)
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

    public func setTargetDisplay(displayID: UInt32?) {
        windowService.setTargetDisplayID(displayID)
        connectedDisplays = windowService.currentConnectedDisplays()
        selectedTargetDisplayID = windowService.selectedTargetDisplayID
        systemControlService.syncDisplayTopology()
    }

    public func openCalendarApp(triggeredBy deviceName: String) async -> (success: Bool, message: String) {
        let result = await catalogService.launchOrActivateApp(
            bundleIdentifier: "com.apple.iCal",
            appPath: "/System/Applications/Calendar.app",
            windowService: windowService
        )
        recordActivity(deviceName: deviceName, summary: result.message, isSuccess: result.success)
        return result
    }

    private func scheduleControlStripRefreshIfRelevant(for action: SystemQuickAction, success: Bool) {
        guard success else { return }
        if action == .mediaPlayPause {
            systemControlService.recordSuccessfulPlayPause()
        }
        switch action {
        case .volumeUp, .volumeDown, .volumeMute, .mediaPlayPause, .mediaNext, .mediaPrevious:
            systemControlService.schedulePostActionRefresh(
                refreshPlayback: [.mediaPlayPause, .mediaNext, .mediaPrevious].contains(action)
            )
        default:
            break
        }
    }

    public func setStudioVolume(_ level: Double) {
        _ = systemControlService.setVolume(level: ControlStripLevel.clamp(level))
        controlStripState = systemControlService.currentState
        server.broadcastControlStripState(controlStripState)
    }

    @discardableResult
    public func performLocalQuickAction(
        _ action: SystemQuickAction,
        triggeredBy deviceName: String = "Mac Studio"
    ) -> (success: Bool, message: String) {
        let res = inputService.executeSystemAction(action, preferredPID: timeTravel.lastExternalAppPID)
        scheduleControlStripRefreshIfRelevant(for: action, success: res.success)
        recordActivity(deviceName: deviceName, summary: res.message, isSuccess: res.success)
        return res
    }

    // MARK: - Playback Scrubbing (Mac Studio + Companion Seek Handler)

    @discardableResult
    public func updateNowPlayingScrub(normalizedProgress: Double) -> Double? {
        nowPlayingScrub.updateDrag(
            normalizedProgress: normalizedProgress,
            for: controlStripState.nowPlaying
        )
    }

    public func cancelNowPlayingScrub() {
        guard nowPlayingScrub.isScrubbing || nowPlayingScrub.previewPositionSeconds != nil else { return }
        nowPlayingScrub.cancel()
    }

    @discardableResult
    public func commitNowPlayingScrub(normalizedProgress: Double) -> Double? {
        guard let targetSeconds = nowPlayingScrub.endDrag(
            normalizedProgress: normalizedProgress,
            for: controlStripState.nowPlaying
        ) else {
            return nil
        }
        let res = seekNowPlaying(to: targetSeconds, triggeredBy: "Mac Studio", originDeviceID: nil)
        return res.appliedPositionSeconds
    }

    @discardableResult
    public func commitNowPlayingScrub(atPositionSeconds rawSeconds: Double) -> Double? {
        guard let targetSeconds = nowPlayingScrub.endDrag(
            atPositionSeconds: rawSeconds,
            for: controlStripState.nowPlaying
        ) else {
            return nil
        }
        let res = seekNowPlaying(to: targetSeconds, triggeredBy: "Mac Studio", originDeviceID: nil)
        return res.appliedPositionSeconds
    }

    @discardableResult
    public func seekNowPlaying(
        to requestedPositionSeconds: Double,
        triggeredBy deviceName: String = "Mac Studio",
        originDeviceID: String? = nil
    ) -> (success: Bool, appliedPositionSeconds: Double?, message: String) {
        let res = inputService.seekNowPlaying(to: requestedPositionSeconds, language: lang)
        if res.success, let applied = res.appliedPositionSeconds {
            systemControlService.recordAppliedSeek(positionSeconds: applied)
            controlStripState = systemControlService.currentState
            nowPlayingScrub.reconcile(with: controlStripState.nowPlaying)
            server.broadcastControlStripState(
                systemControlService.currentState,
                excludingDeviceID: originDeviceID
            )
        } else {
            controlStripState = systemControlService.currentState
            nowPlayingScrub.reconcile(with: controlStripState.nowPlaying)
        }
        recordActivity(deviceName: deviceName, summary: res.message, isSuccess: res.success)
        return res
    }

    private func recordActivity(deviceName: String, summary: String, isSuccess: Bool) {
        let event = MacActivityEvent(deviceName: deviceName, summary: summary, isSuccess: isSuccess)
        activityLog.insert(event, at: 0)
        if activityLog.count > 40 {
            activityLog.removeLast(activityLog.count - 40)
        }
        flashBanner(summary)
    }

    public func sendSelectionToOrca() {
        let result = inputService.executeSystemAction(.sendSelectionToOrca, preferredPID: nil)
        recordActivity(deviceName: "Mac", summary: result.message, isSuccess: result.success)
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
        let connectedIDs = Set(devices.filter(\.isCurrentlyConnected).map(\.deviceID))
        connectedCompanionCount = connectedIDs.count
        let wasHoldingAwake = keepAwakeService.isHoldingAssertion
        keepAwakeService.updateConnectedCompanionDeviceIDs(connectedIDs)
        isKeepMacAwakeEnabled = keepAwakeService.isHoldingAssertion
        systemControlService.syncKeepMacAwake(keepAwakeService.isHoldingAssertion)
        menuBarStatusController?.refresh()
        if wasHoldingAwake && !keepAwakeService.isHoldingAssertion {
            recordActivity(
                deviceName: "Mac",
                summary: L10n.tr(
                    "最后一台伴侣设备已断开，已自动结束防休眠",
                    "Last companion disconnected; ended Keep Mac Awake assertion",
                    language: lang
                ),
                isSuccess: true
            )
        }
        if !connectedIDs.isEmpty {
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
                guard !feedback.title.isEmpty || !feedback.detail.isEmpty else { return }
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

        case .insertSnippet(let text, let mode):
            let res = inputService.executeSnippet(
                text,
                mode: mode,
                preferredPID: timeTravel.lastExternalAppPID,
                allowActivatingPreferredPID: false,
                language: lang
            )
            // When typing mode is triggered with no focused field, do nothing quietly.
            guard res.didPerformAction else { return }
            recordActivity(deviceName: device.deviceName, summary: res.message, isSuccess: res.success)
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
            scheduleControlStripRefreshIfRelevant(for: action, success: res.success)
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

        case .requestCompanionDashboard:
            clipboardService.pollIfNeeded()
            if device.platform != .appleWatch {
                reply(.clipboardPreviewUpdated(clipboardService.currentPreview))
            }
            calendarService.refreshSnapshot(requestAccessIfUndetermined: true)
            reply(.calendarStatusUpdated(calendarService.currentSnapshot))

        case .pasteMacClipboard:
            clipboardService.pollIfNeeded()
            guard let clipboardText = clipboardService.currentInsertablePlainText() else {
                let emptyDetail = L10n.tr(
                    "Mac 剪贴板当前没有可粘贴的纯文本",
                    "Mac clipboard has no plain text to paste",
                    language: lang
                )
                recordActivity(deviceName: device.deviceName, summary: emptyDetail, isSuccess: false)
                reply(.actionFeedback(
                    success: false,
                    title: L10n.tr("剪贴板", "Clipboard", language: lang),
                    detail: emptyDetail
                ))
                return
            }
            let res = insertText(clipboardText, triggeredBy: device.deviceName)
            if device.platform == .appleWatch {
                let watchTitle = res.success
                    ? L10n.tr("已粘贴剪贴板", "Pasted Clipboard", language: lang)
                    : L10n.tr("剪贴板", "Clipboard", language: lang)
                reply(.actionFeedback(
                    success: res.success,
                    title: watchTitle,
                    detail: res.success ? nil : res.message
                ))
            } else {
                let label = MacInputAndMediaService.previewLabel(for: clipboardText)
                reply(.actionFeedback(
                    success: res.success,
                    title: label.isEmpty ? L10n.tr("剪贴板", "Clipboard", language: lang) : label,
                    detail: res.message
                ))
            }

        case .captureMainDisplayScreenshot:
            Task { @MainActor in
                let outcome = await screenshotService.captureMainDisplayToDesktop(language: lang)
                recordActivity(
                    deviceName: device.deviceName,
                    summary: outcome.feedbackDetail,
                    isSuccess: outcome.wireResult.success
                )
                reply(.screenshotCaptured(outcome.wireResult))
            }

        case .setTargetDisplay(let displayID):
            setTargetDisplay(displayID: displayID)
            reply(.controlStripStateUpdated(systemControlService.currentState))

        case .openCalendarApp:
            Task { @MainActor in
                let result = await openCalendarApp(triggeredBy: device.deviceName)
                reply(.actionFeedback(
                    success: result.success,
                    title: L10n.tr("日历", "Calendar", language: lang),
                    detail: result.message
                ))
            }

        case .triggerSoundboardClip(let soundID):
            let result = playSoundClip(id: soundID, triggeredBy: device.deviceName)
            reply(.actionFeedback(
                success: result.success,
                title: result.title,
                detail: result.detail
            ))

        case .stopSoundboardPlayback:
            stopSoundboardPlayback(triggeredBy: device.deviceName)
            reply(.actionFeedback(
                success: true,
                title: L10n.tr("音效板", "Soundboard", language: lang),
                detail: L10n.tr("已停止播放", "Playback stopped", language: lang)
            ))

        case .setSoundboardVolume(let level):
            setSoundboardVolume(level, broadcastExcludingDeviceID: device.deviceID)

        case .setKeepMacAwake(let enabled):
            let connectedIDs = Set(server.pairedDevices.filter(\.isCurrentlyConnected).map(\.deviceID))
                .union([device.deviceID])
            keepAwakeService.updateConnectedCompanionDeviceIDs(connectedIDs)
            let ok = keepAwakeService.setToggleEnabled(enabled)
            isKeepMacAwakeEnabled = keepAwakeService.isHoldingAssertion
            systemControlService.syncKeepMacAwake(keepAwakeService.isHoldingAssertion)
            menuBarStatusController?.refresh()
            server.broadcastControlStripState(systemControlService.currentState)
            reply(.controlStripStateUpdated(systemControlService.currentState))

            let title = L10n.tr("保持 Mac 唤醒", "Keep Mac Awake", language: lang)
            let detail: String = {
                if !ok {
                    return L10n.tr(
                        "macOS 无法创建防休眠断言。",
                        "macOS could not acquire an idle-sleep prevention assertion.",
                        language: lang
                    )
                }
                if keepAwakeService.isHoldingAssertion {
                    return L10n.tr(
                        "已防止系统空闲休眠（屏幕仍可自动熄灭，断开连接后自动恢复）",
                        "Preventing idle system sleep while connected (display may still sleep)",
                        language: lang
                    )
                } else {
                    return L10n.tr(
                        "已恢复系统默认空闲休眠策略",
                        "Idle system sleep prevention turned off",
                        language: lang
                    )
                }
            }()
            recordActivity(deviceName: device.deviceName, summary: detail, isSuccess: ok)
            reply(.actionFeedback(success: ok, title: title, detail: detail))

        case .setAudioOutputDevice(let deviceID):
            let res = systemControlService.setDefaultAudioOutputDevice(id: deviceID, language: lang)
            controlStripState = systemControlService.currentState
            lastAudioOutputError = res.success ? nil : res.detail
            server.broadcastControlStripState(systemControlService.currentState)
            reply(.controlStripStateUpdated(systemControlService.currentState))
            recordActivity(deviceName: device.deviceName, summary: res.detail, isSuccess: res.success)
            reply(.actionFeedback(success: res.success, title: res.title, detail: res.detail))

        case .requestFrontmostAppWindows:
            let snapshot = refreshFrontmostWindowSnapshot()
            reply(.frontmostWindowsUpdated(snapshot))

        case .raiseFrontmostWindow(let windowID):
            let res = windowService.raiseFrontmostAppWindow(
                windowID: windowID,
                preferredExternalPID: timeTravel.lastExternalAppPID,
                language: lang
            )
            recordActivity(deviceName: device.deviceName, summary: res.detail, isSuccess: res.success)
            let snapshot = refreshFrontmostWindowSnapshot()
            server.broadcastFrontmostWindows(snapshot)
            reply(.frontmostWindowsUpdated(snapshot))
            reply(.actionFeedback(success: res.success, title: res.title, detail: res.detail))

        case .sleepMacDisplay:
            // Sleep only the display via IODisplayWrangler without locking the Mac and without
            // mutating or recreating `keepAwakeService`'s PreventUserIdleSystemSleep assertion.
            let res = systemControlService.sleepDisplay(language: lang)
            recordActivity(deviceName: device.deviceName, summary: res.detail, isSuccess: res.success)
            reply(.actionFeedback(success: res.success, title: res.title, detail: res.detail))

        case .lockMacScreen:
            // Dedicated Lock Screen action (confirmed via 3s second-tap gate on companion), separate from sleepMacDisplay.
            let res = systemControlService.lockScreen(language: lang) { [weak self] in
                guard let self else {
                    return (false, L10n.tr("无法锁定屏幕", "Unable to lock screen", language: lang))
                }
                return self.inputService.executeSystemAction(
                    .lockScreen,
                    preferredPID: self.timeTravel.lastExternalAppPID
                )
            }
            recordActivity(deviceName: device.deviceName, summary: res.detail, isSuccess: res.success)
            reply(.actionFeedback(success: res.success, title: res.title, detail: res.detail))

        case .hideOtherApplications:
            // Hides every running regular app except the frontmost one without quitting them;
            // leaves the one-level WindowMoveUndoBuffer untouched.
            let res = windowService.hideOtherApplications(
                preferredExternalPID: timeTravel.lastExternalAppPID,
                language: lang
            )
            recordActivity(deviceName: device.deviceName, summary: res.detail, isSuccess: res.success)
            let snapshot = refreshFrontmostWindowSnapshot()
            server.broadcastFrontmostWindows(snapshot)
            reply(.frontmostWindowsUpdated(snapshot))
            reply(.actionFeedback(success: res.success, title: res.title, detail: res.detail))

        case .setFinderDesktopIconsVisible(let visible):
            let res = systemControlService.setFinderDesktopIconsVisible(visible, language: lang)
            server.broadcastControlStripState(systemControlService.currentState)
            reply(.controlStripStateUpdated(systemControlService.currentState))
            recordActivity(deviceName: device.deviceName, summary: res.detail, isSuccess: res.success)
            reply(.actionFeedback(success: res.success, title: res.title, detail: res.detail))

        case .emptyMacTrash:
            Task { @MainActor in
                let res = await systemControlService.emptyTrash(language: lang)
                server.broadcastControlStripState(systemControlService.currentState)
                reply(.controlStripStateUpdated(systemControlService.currentState))
                recordActivity(deviceName: device.deviceName, summary: res.detail, isSuccess: res.success)
                reply(.actionFeedback(success: res.success, title: res.title, detail: res.detail))
            }

        case .ejectExternalDisks:
            Task { @MainActor in
                let res = await systemControlService.ejectExternalDisks(language: lang)
                server.broadcastControlStripState(systemControlService.currentState)
                reply(.controlStripStateUpdated(systemControlService.currentState))
                recordActivity(deviceName: device.deviceName, summary: res.detail, isSuccess: res.success)
                reply(.actionFeedback(success: res.success, title: res.title, detail: res.detail))
            }

        case .sendCompactKey(let key):
            let res = inputService.sendCompactKey(
                key,
                preferredPID: timeTravel.lastExternalAppPID,
                language: lang
            )
            recordActivity(deviceName: device.deviceName, summary: res.message, isSuccess: res.success)
            reply(.actionFeedback(success: res.success, title: key.title(in: lang), detail: res.message))

        case .seekNowPlaying(let positionSeconds):
            let res = seekNowPlaying(
                to: positionSeconds,
                triggeredBy: device.deviceName,
                originDeviceID: device.deviceID
            )
            reply(.controlStripStateUpdated(systemControlService.currentState))
            if !res.success {
                reply(.actionFeedback(
                    success: false,
                    title: L10n.tr("播放进度", "Playback Position", language: lang),
                    detail: res.message
                ))
            }

        case .updateProfile(let updatedProfile):
            let safeProfile = sanitizeCompanionProfileUpdate(updatedProfile)
            let isUnchangedBySanitizer =
                (safeProfile.soundboardClips == updatedProfile.soundboardClips) &&
                (safeProfile.pinnedClipboardItems == updatedProfile.pinnedClipboardItems)
            let originToExclude = isUnchangedBySanitizer ? device.deviceID : nil
            applyAndSaveProfile(safeProfile, broadcastOriginDeviceID: originToExclude)
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
