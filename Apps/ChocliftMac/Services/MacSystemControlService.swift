import AppKit
import AudioToolbox
import AVFoundation
import ChocliftCore
import CoreAudio
import CoreGraphics
import CoreMediaIO
import CoreWLAN
import Darwin
import Foundation
import IOKit
import IOKit.graphics
import IOKit.ps
import Network

@MainActor
public final class MacSystemControlService {
    public var onStateChanged: ((ControlStripState) -> Void)?
    public var canUndoWindowMoveProvider: (() -> Bool)?
    public var displayTopologyProvider: (() -> (displays: [MacDisplayInfo], selectedDisplayID: UInt32?))?
    public var soundboardVolumeProvider: (() -> Double)?
    public var keepMacAwakeProvider: (() -> Bool)?
    public var frontmostAppNameProvider: (() -> String?)?
    public private(set) var currentState: ControlStripState

    private struct RegisteredAudioListener {
        let objectID: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private struct CachedDistributedTrack {
        let bundleIdentifier: String
        let status: NowPlayingStatus
        let updatedAt: Date
    }

    // CoreAudio Process Object & Service selectors (safe FourCC constants on macOS 13+ SDK)
    nonisolated fileprivate static let selectorProcessObjectList: AudioObjectPropertySelector = 0x70727323 // 'prs#'
    nonisolated fileprivate static let selectorProcessPID: AudioObjectPropertySelector = 0x70706964        // 'ppid'
    nonisolated fileprivate static let selectorProcessIsRunningInput: AudioObjectPropertySelector = 0x70697269  // 'piri'
    nonisolated fileprivate static let selectorProcessIsRunningOutput: AudioObjectPropertySelector = 0x7069726f // 'piro'
    nonisolated fileprivate static let selectorProcessDevices: AudioObjectPropertySelector = 0x70647623    // 'pdv#'
    nonisolated fileprivate static let selectorServiceRestarted: AudioObjectPropertySelector = 0x73727374  // 'srst'

    private let listenerQueue = DispatchQueue.main
    private var systemAudioListeners: [RegisteredAudioListener] = []
    private var deviceAudioListeners: [RegisteredAudioListener] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var localObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var periodicPollTask: Task<Void, Never>?
    private var postActionRefreshTask: Task<Void, Never>?

    private var observedOutputDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var observedInputDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var savedPreMuteInputVolume: Float32 = 0.75
    private var distributedTracks: [String: CachedDistributedTrack] = [:]
    private var playersWithoutCurrentTrack: Set<String> = []
    private var latestMediaRemoteStatus: NowPlayingStatus?
    private var latestMediaRemoteBundleID: String?
    private var latestMediaRemotePID: pid_t = 0

    private let displayBridge = DisplayBrightnessBridge()
    private let mediaRemoteBridge = MediaRemoteBridge()
    private let airPlayRouteMonitor = MacAirPlayRouteMonitor()

    public init() {
        self.currentState = ControlStripState()
        self.currentState = readSynchronousSnapshot(nowPlaying: nil)
    }

    public func start() {
        stop()
        airPlayRouteMonitor.onReceiversChanged = { [weak self] in
            self?.refreshNow()
        }
        airPlayRouteMonitor.start()
        registerSystemAudioDeviceListeners()
        rebindActiveAudioDeviceListeners()
        registerNowPlayingObservers()
        registerVolumeMountObservers()
        refreshNow()

        periodicPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.0))
                guard let self, !Task.isCancelled else { break }
                self.pollForHardwareChanges()
            }
        }
    }

    public func stop() {
        periodicPollTask?.cancel()
        periodicPollTask = nil
        postActionRefreshTask?.cancel()
        postActionRefreshTask = nil

        airPlayRouteMonitor.stop()
        airPlayRouteMonitor.onReceiversChanged = nil

        removeAudioListeners(&deviceAudioListeners)
        removeAudioListeners(&systemAudioListeners)

        let dnc = DistributedNotificationCenter.default()
        for token in distributedObservers {
            dnc.removeObserver(token)
        }
        distributedObservers.removeAll()

        let nc = NotificationCenter.default
        for token in localObservers {
            nc.removeObserver(token)
        }
        localObservers.removeAll()

        let wsnc = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            wsnc.removeObserver(token)
        }
        workspaceObservers.removeAll()
    }

    // MARK: - Reading & Refreshing State

    public func refreshNow(completion: (@MainActor (ControlStripState) -> Void)? = nil) {
        if mediaRemoteBridge.isAvailable {
            mediaRemoteBridge.fetchNowPlaying { [weak self] payload in
                guard let self else { return }
                self.latestMediaRemoteStatus = payload.status
                self.latestMediaRemoteBundleID = payload.bundleIdentifier
                self.latestMediaRemotePID = payload.pid
                let resolved = self.applyRefreshedSnapshot()
                completion?(resolved)
            }
        } else {
            let resolved = applyRefreshedSnapshot()
            completion?(resolved)
        }
    }

    /// Publish the command's resulting state before any asynchronous player read.
    public func recordSuccessfulPlayPause() {
        var next = currentState
        next.nowPlaying = NowPlayingStatus.afterPlayPause(currentState.nowPlaying, success: true)
        currentState = next
        onStateChanged?(next)
    }

    public func schedulePostActionRefresh(refreshPlayback: Bool = false) {
        postActionRefreshTask?.cancel()
        postActionRefreshTask = Task { @MainActor [weak self] in
            for delay in [0, 220, 1000, 1500] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, !Task.isCancelled else { return }
                if refreshPlayback {
                    await self.refreshScriptablePlayerState()
                }
                guard !Task.isCancelled else { return }
                self.refreshNow()
            }
        }
    }

    /// Read state separately from the transport command, which remains unchanged.
    private func refreshScriptablePlayerState() async {
        let bundleID = currentState.nowPlaying?.bundleIdentifier
            ?? currentMediaTransportContext().nowPlayingBundleID
        guard let bundleID, ["com.spotify.client", "com.apple.Music"].contains(bundleID) else { return }
        let status = await Task.detached {
            Self.readScriptablePlayerState(bundleID: bundleID)
        }.value
        guard var status, !Task.isCancelled else { return } // Script failure is not a playback-state report.
        if let previous = currentState.nowPlaying,
           previous.bundleIdentifier == bundleID, previous.title == status.title {
            status.elapsedSeconds = previous.elapsedSeconds
            status.durationSeconds = previous.durationSeconds
        }
        let title = status.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if title?.isEmpty != false {
            playersWithoutCurrentTrack.insert(bundleID)
            distributedTracks.removeValue(forKey: bundleID)
        } else {
            playersWithoutCurrentTrack.remove(bundleID)
            distributedTracks[bundleID] = CachedDistributedTrack(
                bundleIdentifier: bundleID, status: status, updatedAt: Date()
            )
        }
        if latestMediaRemoteBundleID == bundleID {
            latestMediaRemoteStatus = title?.isEmpty == false ? status : nil
        }
    }

    nonisolated private static func readScriptablePlayerState(bundleID: String) -> NowPlayingStatus? {
        let source = """
        if application id "\(bundleID)" is running then
            tell application id "\(bundleID)"
                set playbackState to player state as text
                try
                    return {playbackState, name of current track, artist of current track}
                on error
                    return {playbackState, "", ""}
                end try
            end tell
        else
            return {"stopped", "", ""}
        end if
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, result.numberOfItems == 3 else { return nil }
        return NowPlayingStatus(
            title: result.atIndex(2)?.stringValue,
            artist: result.atIndex(3)?.stringValue,
            appName: bundleID == "com.spotify.client" ? "Spotify" : "Music",
            isPlaying: result.atIndex(1)?.stringValue?.lowercased() == "playing",
            bundleIdentifier: bundleID
        )
    }

    private func schedulePostSeekRefresh() {
        postActionRefreshTask?.cancel()
        postActionRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(240))
            guard let self, !Task.isCancelled else { return }
            self.refreshNow()
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled else { return }
            self.refreshNow()
        }
    }

    @discardableResult
    private func applyRefreshedSnapshot() -> ControlStripState {
        let resolvedNowPlaying = resolveBestNowPlaying()
        let next = readSynchronousSnapshot(nowPlaying: resolvedNowPlaying)
        let changed = next.hasMeaningfulDifference(from: currentState)
        currentState = next
        if changed {
            onStateChanged?(next)
        }
        return next
    }

    private func pollForHardwareChanges() {
        rebindActiveAudioDeviceListenersIfChanged()
        refreshNow()
    }

    private func readSynchronousSnapshot(nowPlaying: NowPlayingStatus?) -> ControlStripState {
        let outDevice = Self.defaultAudioDevice(isInput: false)
        let inDevice = Self.defaultAudioDevice(isInput: true)

        let (volume, isOutputMuted) = readOutputVolumeAndMute(deviceID: outDevice)
        let isMicMuted = readInputMicMuted(deviceID: inDevice)
        let brightnessReading = displayBridge.readMainDisplayBrightness()
        let canUndoWindow = canUndoWindowMoveProvider?() ?? currentState.canUndoWindowMove
        let topology = displayTopologyProvider?() ?? (
            displays: currentState.connectedDisplays,
            selectedDisplayID: currentState.selectedTargetDisplayID
        )

        let sbVolume = ControlStripLevel.clamp(soundboardVolumeProvider?() ?? currentState.soundboardVolume)
        let keepAwake = keepMacAwakeProvider?() ?? currentState.isKeepMacAwakeEnabled
        let audioSnapshot = Self.enumerateAudioOutputDevices(
            defaultOutputID: outDevice,
            bonjourAirPlayReceivers: airPlayRouteMonitor.currentBonjourReceivers
        )
        let batteryStatus = Self.readMacBatteryStatus()
        let finderIconsVisible = Self.readFinderDesktopIconsVisible()
        let privacyCapture = Self.readPrivacyCaptureStatus(defaultInputDeviceID: inDevice)
        let currentWiFiSSID = Self.readCurrentWiFiSSID()
        let ejectableVolumeCount = Self.enumerateEjectableExternalVolumes().count
        let resolvedFrontmostAppName = FrontmostAppStripFormatter.sanitizedAppName(
            frontmostAppNameProvider?() ?? NSWorkspace.shared.frontmostApplication?.localizedName
        )

        return ControlStripState(
            volume: volume,
            isVolumeMuted: isOutputMuted,
            brightness: brightnessReading ?? currentState.brightness,
            isBrightnessAvailable: brightnessReading != nil,
            isMicMuted: isMicMuted,
            nowPlaying: nowPlaying,
            canUndoWindowMove: canUndoWindow,
            connectedDisplays: topology.displays,
            selectedTargetDisplayID: topology.selectedDisplayID,
            soundboardVolume: sbVolume,
            isKeepMacAwakeEnabled: keepAwake,
            audioOutputDevices: audioSnapshot.devices,
            selectedAudioOutputDeviceID: audioSnapshot.selectedID,
            canSwitchAudioOutput: audioSnapshot.canSwitch,
            macBattery: batteryStatus,
            areFinderDesktopIconsVisible: finderIconsVisible,
            privacyCapture: privacyCapture,
            wifiSSID: currentWiFiSSID,
            ejectableExternalVolumeCount: ejectableVolumeCount,
            frontmostAppName: resolvedFrontmostAppName
        )
    }

    public func syncFrontmostAppName(_ appName: String?) {
        let sanitized = FrontmostAppStripFormatter.sanitizedAppName(appName)
        guard currentState.frontmostAppName != sanitized else { return }
        var updated = currentState
        updated.frontmostAppName = sanitized
        currentState = updated
        onStateChanged?(updated)
    }

    public func syncKeepMacAwake(_ isEnabled: Bool) {
        guard currentState.isKeepMacAwakeEnabled != isEnabled else { return }
        var updated = currentState
        updated.isKeepMacAwakeEnabled = isEnabled
        currentState = updated
        onStateChanged?(updated)
    }

    /// Puts connected Mac displays to idle sleep immediately via public IOKit `IODisplayWrangler` (`IORequestIdle`).
    /// Does not lock the Mac, does not sleep the system/network, and leaves any `PreventUserIdleSystemSleep`
    /// keep-awake assertion untouched so the display stays asleep.
    public func sleepDisplay(language: AppLanguage = .system) -> (success: Bool, title: String, detail: String) {
        let title = L10n.tr("熄灭屏幕", "Sleep Display", language: language)
        let wrangler = IORegistryEntryFromPath(
            kIOMainPortDefault,
            "IOService:/IOResources/IODisplayWrangler"
        )
        guard wrangler != IO_OBJECT_NULL else {
            return (
                false,
                title,
                L10n.tr(
                    "macOS 未能访问显示器电源控制器（IODisplayWrangler）。",
                    "macOS could not open IODisplayWrangler to sleep the display.",
                    language: language
                )
            )
        }
        defer { IOObjectRelease(wrangler) }

        let status = IORegistryEntrySetCFProperty(
            wrangler,
            "IORequestIdle" as CFString,
            kCFBooleanTrue
        )
        guard status == kIOReturnSuccess else {
            return (
                false,
                title,
                L10n.tr(
                    "显示器未能进入休眠（IOKit 状态码 \(status)）。",
                    "macOS rejected display sleep request (IOKit code \(status)).",
                    language: language
                )
            )
        }
        return (
            true,
            title,
            L10n.tr("已熄灭屏幕（未锁定 Mac，防休眠开关保持不变）", "Display put to sleep (Mac unlocked; Keep Awake unchanged)", language: language)
        )
    }

    /// Locks the Mac screen immediately (separate from `sleepDisplay`, which only idles the display).
    /// Uses macOS `login.framework` `SACLockScreenImmediate` when available, falling back to `⌃⌘Q`.
    public func lockScreen(
        language: AppLanguage = .system,
        fallbackKeystroke: () -> (success: Bool, message: String)
    ) -> (success: Bool, title: String, detail: String) {
        let title = L10n.tr("锁定屏幕", "Lock Screen", language: language)
        if let loginHandle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let lockSym = dlsym(loginHandle, "SACLockScreenImmediate") {
            typealias SACLockScreenImmediateFn = @convention(c) () -> Void
            let lockFn = unsafeBitCast(lockSym, to: SACLockScreenImmediateFn.self)
            lockFn()
            return (
                true,
                title,
                L10n.tr("已锁定 Mac 屏幕", "Locked Mac screen", language: language)
            )
        }

        let fallback = fallbackKeystroke()
        return (fallback.success, title, fallback.message)
    }

    // MARK: - Mac Battery & Finder Desktop Icons (Round 7)

    public static func readMacBatteryStatus() -> MacBatteryStatus {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return .powerAdapter
        }
        var descriptions: [[String: Any]] = []
        descriptions.reserveCapacity(sources.count)
        for source in sources {
            if let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] {
                descriptions.append(desc)
            }
        }
        return MacBatteryStatus.fromPowerSourceDescriptions(descriptions)
    }

    public static func readFinderDesktopIconsVisible() -> Bool {
        let raw = CFPreferencesCopyAppValue(
            "CreateDesktop" as CFString,
            "com.apple.finder" as CFString
        )
        return FinderDesktopIconsToggleCopy.parseCreateDesktopValue(raw)
    }

    /// Toggles Finder desktop icons (`com.apple.finder CreateDesktop`) and restarts Finder.
    /// Does not hide the whole screen, lock the Mac, or enable remote-desktop curtain mode.
    public func setFinderDesktopIconsVisible(
        _ visible: Bool,
        language: AppLanguage = .system
    ) -> (success: Bool, title: String, detail: String) {
        let title = visible
            ? L10n.tr("显示桌面图标", "Show Desktop Icons", language: language)
            : L10n.tr("隐藏桌面图标", "Hide Desktop Icons", language: language)

        let defaultsProcess = Process()
        defaultsProcess.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        defaultsProcess.arguments = [
            "write",
            "com.apple.finder",
            "CreateDesktop",
            "-bool",
            visible ? "true" : "false"
        ]
        do {
            try defaultsProcess.run()
            defaultsProcess.waitUntilExit()
        } catch {
            return (
                false,
                title,
                L10n.tr(
                    "无法更新 Finder 桌面图标设置：\(error.localizedDescription)",
                    "Could not update Finder desktop icons preference: \(error.localizedDescription)",
                    language: language
                )
            )
        }

        guard defaultsProcess.terminationStatus == 0 else {
            return (
                false,
                title,
                L10n.tr(
                    "Finder 偏好设置写入失败（状态码 \(defaultsProcess.terminationStatus)）。",
                    "defaults write exited with code \(defaultsProcess.terminationStatus).",
                    language: language
                )
            )
        }

        _ = CFPreferencesAppSynchronize("com.apple.finder" as CFString)

        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killProcess.arguments = ["Finder"]
        try? killProcess.run()
        killProcess.waitUntilExit()

        var updated = currentState
        updated.areFinderDesktopIconsVisible = visible
        currentState = updated
        onStateChanged?(updated)
        schedulePostActionRefresh()

        let detail = visible
            ? L10n.tr("已显示桌面图标并重启 Finder", "Desktop icons shown (Finder restarted)", language: language)
            : L10n.tr("已隐藏桌面图标并重启 Finder", "Desktop icons hidden (Finder restarted)", language: language)
        return (true, title, detail)
    }

    // MARK: - Round 8: Camera/Mic In Use, Wi-Fi SSID, Empty Trash & Eject External Disks

    private func registerVolumeMountObservers() {
        let wsnc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ]
        for name in names {
            let token = wsnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshNow()
                }
            }
            workspaceObservers.append(token)
        }
    }

    /// Reads only the current Wi-Fi SSID via public `CoreWLAN` (`CWWiFiClient.shared().interface()?.ssid()`).
    /// Never performs a network scan, never reads cached scan lists, and never accesses Wi-Fi passwords.
    public static func readCurrentWiFiSSID() -> String? {
        let rawSSID = CWWiFiClient.shared().interface()?.ssid()
        return MacWiFiStatusFormatter.sanitizedSSID(rawSSID)
    }

    /// Reads whether any Mac camera (`CoreMediaIO`) or microphone (`CoreAudio`) is currently capturing,
    /// along with the user-facing app name when macOS exposes the owning PID via public APIs.
    /// Never opens capture sessions, streams video/audio, or touches shutter controls.
    public static func readPrivacyCaptureStatus(
        defaultInputDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    ) -> MacPrivacyCaptureStatus {
        let camera = readCameraCaptureStatus()
        let resolvedInput = (defaultInputDeviceID != kAudioObjectUnknown)
            ? defaultInputDeviceID
            : defaultAudioDevice(isInput: true)
        let microphone = readMicrophoneCaptureStatus(defaultInputDeviceID: resolvedInput)
        return MacPrivacyCaptureStatus(
            isCameraInUse: camera.isInUse,
            cameraAppName: camera.appName,
            isMicrophoneInUse: microphone.isInUse,
            microphoneAppName: microphone.appName
        )
    }

    private static func readCameraCaptureStatus() -> (isInUse: Bool, appName: String?) {
        let systemObject = CMIOObjectID(kCMIOObjectSystemObject)
        var devicesAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(systemObject, &devicesAddress) else {
            return (false, nil)
        }

        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(systemObject, &devicesAddress, 0, nil, &dataSize) == OSStatus(kCMIOHardwareNoError),
              dataSize >= UInt32(MemoryLayout<CMIODeviceID>.size) else {
            return (false, nil)
        }

        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var deviceIDs = [CMIODeviceID](repeating: 0, count: count)
        let fetchStatus = deviceIDs.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMIOObjectGetPropertyData(systemObject, &devicesAddress, 0, nil, dataSize, &dataUsed, baseAddress)
        }
        guard fetchStatus == OSStatus(kCMIOHardwareNoError) else {
            return (false, nil)
        }

        var anyCameraRunning = false
        var fallbackAppName: String?

        for deviceID in deviceIDs where deviceID != CMIODeviceID(kCMIOObjectUnknown) {
            guard cmioDeviceHasInputStreams(deviceID: deviceID) else { continue }
            guard isCMIODeviceRunningSomewhere(deviceID: deviceID) else { continue }
            anyCameraRunning = true

            if let controllingPID = readCMIODeviceControllingPID(deviceID: deviceID),
               let resolved = resolveUserFacingAppName(forPID: controllingPID) {
                if resolved.isRegularApp {
                    return (true, resolved.name)
                }
                if fallbackAppName == nil {
                    fallbackAppName = resolved.name
                }
            }
        }

        return (anyCameraRunning, anyCameraRunning ? fallbackAppName : nil)
    }

    private static func cmioDeviceHasInputStreams(deviceID: CMIODeviceID) -> Bool {
        var streamsAddr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(deviceID, &streamsAddr) else { return false }
        var byteSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(deviceID, &streamsAddr, 0, nil, &byteSize) == OSStatus(kCMIOHardwareNoError) else {
            return false
        }
        return byteSize >= UInt32(MemoryLayout<CMIOStreamID>.size)
    }

    private static func isCMIODeviceRunningSomewhere(deviceID: CMIODeviceID) -> Bool {
        var runningAddr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        guard CMIOObjectHasProperty(deviceID, &runningAddr) else { return false }
        var isRunning: UInt32 = 0
        var dataUsed: UInt32 = 0
        let status = withUnsafeMutableBytes(of: &isRunning) { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMIOObjectGetPropertyData(
                deviceID,
                &runningAddr,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &dataUsed,
                baseAddress
            )
        }
        return status == OSStatus(kCMIOHardwareNoError) && isRunning != 0
    }

    private static func readCMIODeviceControllingPID(deviceID: CMIODeviceID) -> pid_t? {
        let candidateSelectors: [CMIOObjectPropertySelector] = [
            CMIOObjectPropertySelector(kCMIODevicePropertyHogMode),
            CMIOObjectPropertySelector(kCMIODevicePropertyDeviceControl)
        ]
        for selector in candidateSelectors {
            var addr = CMIOObjectPropertyAddress(
                mSelector: selector,
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            guard CMIOObjectHasProperty(deviceID, &addr) else { continue }
            var ownerPID: pid_t = -1
            var dataUsed: UInt32 = 0
            let status = withUnsafeMutableBytes(of: &ownerPID) { rawBuffer -> OSStatus in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return CMIOObjectGetPropertyData(
                    deviceID,
                    &addr,
                    0,
                    nil,
                    UInt32(MemoryLayout<pid_t>.size),
                    &dataUsed,
                    baseAddress
                )
            }
            if status == OSStatus(kCMIOHardwareNoError), ownerPID > 0 {
                return ownerPID
            }
        }
        return nil
    }

    private static func readMicrophoneCaptureStatus(
        defaultInputDeviceID: AudioObjectID
    ) -> (isInUse: Bool, appName: String?) {
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = AudioObjectPropertyAddress(
            mSelector: selectorProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Preferred path on macOS 14+: per-process CoreAudio input activity + owning PID.
        if AudioObjectHasProperty(sysObj, &listAddr) {
            var byteSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(sysObj, &listAddr, 0, nil, &byteSize) == noErr {
                if byteSize < UInt32(MemoryLayout<AudioObjectID>.size) {
                    return (false, nil)
                }
                let count = Int(byteSize) / MemoryLayout<AudioObjectID>.size
                var procObjects = [AudioObjectID](repeating: 0, count: count)
                if AudioObjectGetPropertyData(sysObj, &listAddr, 0, nil, &byteSize, &procObjects) == noErr {
                    var anyInputRunning = false
                    var fallbackAppName: String?

                    for procObj in procObjects {
                        var isRunningInput: UInt32 = 0
                        var runSize = UInt32(MemoryLayout<UInt32>.size)
                        var inAddr = AudioObjectPropertyAddress(
                            mSelector: selectorProcessIsRunningInput,
                            mScope: kAudioObjectPropertyScopeGlobal,
                            mElement: kAudioObjectPropertyElementMain
                        )
                        guard AudioObjectGetPropertyData(procObj, &inAddr, 0, nil, &runSize, &isRunningInput) == noErr,
                              isRunningInput != 0 else {
                            continue
                        }
                        anyInputRunning = true

                        var pid: pid_t = 0
                        var pidSize = UInt32(MemoryLayout<pid_t>.size)
                        var pidAddr = AudioObjectPropertyAddress(
                            mSelector: selectorProcessPID,
                            mScope: kAudioObjectPropertyScopeGlobal,
                            mElement: kAudioObjectPropertyElementMain
                        )
                        if AudioObjectGetPropertyData(procObj, &pidAddr, 0, nil, &pidSize, &pid) == noErr,
                           pid > 0,
                           let resolved = resolveUserFacingAppName(forPID: pid) {
                            if resolved.isRegularApp {
                                return (true, resolved.name)
                            }
                            if fallbackAppName == nil {
                                fallbackAppName = resolved.name
                            }
                        }
                    }

                    return (anyInputRunning, anyInputRunning ? fallbackAppName : nil)
                }
            }
        }

        // macOS 13 fallback: inspect input-capable CoreAudio devices via public HAL properties.
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sysObj, &devicesAddr, 0, nil, &byteSize) == noErr,
              byteSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return (false, nil)
        }

        let count = Int(byteSize) / MemoryLayout<AudioObjectID>.size
        var rawIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sysObj, &devicesAddr, 0, nil, &byteSize, &rawIDs) == noErr else {
            return (false, nil)
        }

        var anyMicRunning = false
        var fallbackAppName: String?

        for devID in rawIDs where devID != kAudioObjectUnknown {
            if devID != defaultInputDeviceID && isAudioDeviceHidden(deviceID: devID) {
                continue
            }
            guard inputChannelCount(deviceID: devID) > 0 else { continue }
            guard isAudioDeviceCapturingInput(deviceID: devID) else { continue }
            anyMicRunning = true

            var hogAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyHogMode,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            if !AudioObjectHasProperty(devID, &hogAddr) {
                hogAddr.mScope = kAudioObjectPropertyScopeGlobal
            }
            if AudioObjectHasProperty(devID, &hogAddr) {
                var hogPID: pid_t = -1
                var pidSize = UInt32(MemoryLayout<pid_t>.size)
                if AudioObjectGetPropertyData(devID, &hogAddr, 0, nil, &pidSize, &hogPID) == noErr,
                   hogPID > 0,
                   let resolved = resolveUserFacingAppName(forPID: hogPID) {
                    if resolved.isRegularApp {
                        return (true, resolved.name)
                    }
                    if fallbackAppName == nil {
                        fallbackAppName = resolved.name
                    }
                }
            }
        }

        return (anyMicRunning, anyMicRunning ? fallbackAppName : nil)
    }

    private static func isAudioDeviceCapturingInput(deviceID: AudioObjectID) -> Bool {
        var inRunningAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &inRunningAddr) {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &inRunningAddr, 0, nil, &size, &running) == noErr {
                return running != 0
            }
        }

        // Only fall back to global scope if the device is input-only (no output channels).
        guard outputChannelCount(deviceID: deviceID) == 0 else {
            return false
        }
        return isDeviceRunningAudio(deviceID: deviceID)
    }

    private static func inputChannelCount(deviceID: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return 0 }
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &byteSize) == noErr,
              byteSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPtr.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &byteSize, rawPtr) == noErr else {
            return 0
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(rawPtr.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func enumerateEjectableExternalVolumes() -> [ExternalDiskVolumeCandidate] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey,
            .volumeIsRootFileSystemKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsLocalKey,
            .volumeIsBrowsableKey
        ]
        guard let mountedURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        var candidates: [ExternalDiskVolumeCandidate] = []
        candidates.reserveCapacity(mountedURLs.count)
        for url in mountedURLs {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            candidates.append(
                ExternalDiskVolumeCandidate(
                    url: url,
                    localizedName: values.volumeLocalizedName,
                    isRootFileSystem: values.volumeIsRootFileSystem ?? false,
                    isInternal: values.volumeIsInternal,
                    isRemovable: values.volumeIsRemovable ?? false,
                    isEjectable: values.volumeIsEjectable ?? false,
                    isLocal: values.volumeIsLocal ?? true,
                    isBrowsable: values.volumeIsBrowsable ?? true
                )
            )
        }

        return ExternalDiskFilter.eligibleVolumes(from: candidates)
    }

    /// Empties the Mac's Trash via Finder AppleEvents without blocking on Finder's modal warning dialog
    /// (after the user has already completed the 3-second second-tap confirm on the companion).
    public func emptyTrash(
        language: AppLanguage = .system
    ) async -> (success: Bool, title: String, detail: String) {
        let title = L10n.tr("清空废纸篓", "Empty Trash", language: language)
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.runEmptyTrashAppleScript()
        }.value

        schedulePostActionRefresh()

        switch outcome {
        case .alreadyEmpty:
            return (
                true,
                title,
                L10n.tr("废纸篓已经是空的", "Trash is already empty", language: language)
            )
        case .emptied:
            return (
                true,
                title,
                L10n.tr("已清空废纸篓", "Emptied Trash", language: language)
            )
        case .failed(let message):
            return (
                false,
                title,
                L10n.tr("无法清空废纸篓：\(message)", "Could not empty Trash: \(message)", language: language)
            )
        }
    }

    private enum EmptyTrashScriptResult: Sendable {
        case alreadyEmpty
        case emptied
        case failed(String)
    }

    nonisolated private static func runEmptyTrashAppleScript() -> EmptyTrashScriptResult {
        let source = """
        with timeout of 20 seconds
            tell application "Finder"
                if (count of items of trash) is 0 then
                    return "ALREADY_EMPTY"
                end if
                set prevWarn to warns before emptying of trash
                set warns before emptying of trash to false
                try
                    empty the trash
                on error errMsg number errNum
                    try
                        set warns before emptying of trash to prevWarn
                    end try
                    error errMsg number errNum
                end try
                set warns before emptying of trash to prevWarn
                return "EMPTIED"
            end tell
        end timeout
        """
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failed("AppleScript initialization failed")
        }
        let descriptor = script.executeAndReturnError(&errorDict)
        if let errorDict {
            let reason = (errorDict[NSAppleScript.errorMessage] as? String)
                ?? (errorDict[NSAppleScript.errorBriefMessage] as? String)
                ?? "Finder AppleEvent error"
            return .failed(reason)
        }
        if descriptor.stringValue == "ALREADY_EMPTY" {
            return .alreadyEmpty
        }
        return .emptied
    }

    /// Ejects all currently mounted external volumes via `NSWorkspace.unmountAndEjectDevice(at:)`,
    /// strictly excluding the startup disk (`/`) and fixed internal volumes.
    public func ejectExternalDisks(
        language: AppLanguage = .system
    ) async -> (success: Bool, title: String, detail: String) {
        let title = L10n.tr("推出外置磁盘", "Eject External Disks", language: language)
        let eligible = Self.enumerateEjectableExternalVolumes()

        guard !eligible.isEmpty else {
            applyRefreshedSnapshot()
            return (
                true,
                title,
                L10n.tr("当前没有可推出的外置磁盘", "No mounted external disks to eject", language: language)
            )
        }

        let ejectReport = await Task.detached(priority: .userInitiated) {
            Self.unmountAndEjectCandidates(eligible)
        }.value

        applyRefreshedSnapshot()
        schedulePostActionRefresh()

        if ejectReport.failures.isEmpty {
            let names = ejectReport.ejectedNames.joined(separator: ", ")
            return (
                true,
                title,
                L10n.tr("已推出：\(names)", "Ejected: \(names)", language: language)
            )
        } else if !ejectReport.ejectedNames.isEmpty {
            let okNames = ejectReport.ejectedNames.joined(separator: ", ")
            let errSummary = ejectReport.failures.joined(separator: "; ")
            return (
                false,
                title,
                L10n.tr(
                    "已推出 \(okNames)；部分失败：\(errSummary)",
                    "Ejected \(okNames); failed: \(errSummary)",
                    language: language
                )
            )
        } else {
            let errSummary = ejectReport.failures.joined(separator: "; ")
            return (
                false,
                title,
                L10n.tr("无法推出外置磁盘：\(errSummary)", "Could not eject external disks: \(errSummary)", language: language)
            )
        }
    }

    nonisolated private static func unmountAndEjectCandidates(
        _ candidates: [ExternalDiskVolumeCandidate]
    ) -> (ejectedNames: [String], failures: [String]) {
        var ejected: [String] = []
        var failures: [String] = []

        for candidate in candidates {
            // Belt-and-suspenders guard: never touch root or /System even if passed directly.
            let stdPath = candidate.url.standardizedFileURL.path
            guard ExternalDiskFilter.isEligibleExternalVolume(candidate),
                  stdPath != "/",
                  !stdPath.hasPrefix("/System") else {
                continue
            }

            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: candidate.url)
                ejected.append(candidate.localizedName)
            } catch {
                failures.append("\(candidate.localizedName) (\(error.localizedDescription))")
            }
        }

        return (ejected, failures)
    }

    public func syncSoundboardVolume(_ volume: Double) {
        let clamped = ControlStripLevel.clamp(volume)
        guard abs(currentState.soundboardVolume - clamped) >= 0.001 else { return }
        var updated = currentState
        updated.soundboardVolume = clamped
        currentState = updated
        onStateChanged?(updated)
    }

    public func syncWindowUndoAvailability() {
        let canUndo = canUndoWindowMoveProvider?() ?? false
        guard currentState.canUndoWindowMove != canUndo else { return }
        var updated = currentState
        updated.canUndoWindowMove = canUndo
        currentState = updated
        onStateChanged?(updated)
    }

    public func syncDisplayTopology() {
        guard let topology = displayTopologyProvider?() else { return }
        let resolvedSelected = DisplaySnapTargetResolver.resolvedTargetDisplayID(
            selectedDisplayID: topology.selectedDisplayID,
            connectedDisplays: topology.displays
        )
        guard currentState.connectedDisplays != topology.displays ||
              currentState.effectiveTargetDisplayID != resolvedSelected else {
            return
        }
        var updated = currentState
        updated.connectedDisplays = topology.displays
        updated.selectedTargetDisplayID = resolvedSelected
        currentState = updated
        onStateChanged?(updated)
    }

    // MARK: - Setting Volume, Brightness & Mic Mute on macOS 13+

    @discardableResult
    public func setVolume(level: Double) -> Bool {
        let clamped = Float32(ControlStripLevel.clamp(level))
        let deviceID = Self.defaultAudioDevice(isInput: false)
        guard deviceID != kAudioObjectUnknown else { return false }

        var didSet = false

        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if Self.isPropertySettable(deviceID: deviceID, address: &virtualAddr) {
            var mutableLevel = clamped
            let status = AudioObjectSetPropertyData(
                deviceID,
                &virtualAddr,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &mutableLevel
            )
            didSet = (status == noErr)
        }

        if !didSet {
            for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
                var scalarAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: element
                )
                guard Self.isPropertySettable(deviceID: deviceID, address: &scalarAddr) else { continue }
                var mutableLevel = clamped
                if AudioObjectSetPropertyData(
                    deviceID,
                    &scalarAddr,
                    0,
                    nil,
                    UInt32(MemoryLayout<Float32>.size),
                    &mutableLevel
                ) == noErr {
                    didSet = true
                }
            }
        }

        if clamped > 0.001 {
            setHardwareMute(false, deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
        }

        var next = currentState
        next.volume = Double(clamped)
        if clamped > 0.001 {
            next.isVolumeMuted = false
        }
        currentState = next
        return didSet
    }

    @discardableResult
    public func setBrightness(level: Double) -> Bool {
        let clamped = ControlStripLevel.clamp(level)
        let ok = displayBridge.setMainDisplayBrightness(Float(clamped))
        if ok {
            var next = currentState
            next.brightness = clamped
            next.isBrightnessAvailable = true
            currentState = next
        }
        return ok
    }

    @discardableResult
    public func setMicMuted(_ muted: Bool) -> Bool {
        let deviceID = Self.defaultAudioDevice(isInput: true)
        guard deviceID != kAudioObjectUnknown else { return false }

        if setHardwareMute(muted, deviceID: deviceID, scope: kAudioDevicePropertyScopeInput) {
            var next = currentState
            next.isMicMuted = muted
            currentState = next
            return true
        }

        // Fallback for external USB microphones that expose input gain scalar without hardware mute
        if muted {
            if let currentGain = Self.readScalarVolume(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput),
               currentGain > 0.02 {
                savedPreMuteInputVolume = currentGain
            }
            let didZero = Self.writeScalarVolume(0.0, deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
            if didZero {
                var next = currentState
                next.isMicMuted = true
                currentState = next
            }
            return didZero
        } else {
            let targetGain = max(0.1, savedPreMuteInputVolume)
            let didRestore = Self.writeScalarVolume(targetGain, deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
            if didRestore {
                var next = currentState
                next.isMicMuted = false
                currentState = next
            }
            return didRestore
        }
    }

    public func setDefaultAudioOutputDeviceDetailed(
        id: String,
        language: AppLanguage = .system
    ) -> MacAudioOutputSwitchResult {
        let driver = CoreAudioHardwareOutputDriver(
            bonjourAirPlayReceivers: airPlayRouteMonitor.currentBonjourReceivers
        )
        let result = MacAudioOutputSwitchEngine.performSwitch(
            requestedID: id,
            language: language,
            using: driver
        )
        rebindActiveAudioDeviceListeners()
        _ = applyRefreshedSnapshot()
        if result.success {
            schedulePostActionRefresh()
        }
        return result
    }

    public func setDefaultAudioOutputDevice(
        id: String,
        language: AppLanguage = .system
    ) -> (success: Bool, title: String, detail: String) {
        let result = setDefaultAudioOutputDeviceDetailed(id: id, language: language)
        return (result.success, result.title, result.detail)
    }

    // MARK: - CoreAudio Read / Write Helpers

    private func readOutputVolumeAndMute(deviceID: AudioObjectID) -> (Double, Bool) {
        guard deviceID != kAudioObjectUnknown else {
            return (currentState.volume, currentState.isVolumeMuted)
        }
        let scalar = Self.readScalarVolume(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
            ?? Float32(currentState.volume)
        let muted = Self.readHardwareMute(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput) ?? false
        return (ControlStripLevel.clamp(Double(scalar)), muted)
    }

    private func readInputMicMuted(deviceID: AudioObjectID) -> Bool {
        guard deviceID != kAudioObjectUnknown else {
            return currentState.isMicMuted
        }
        if let hwMute = Self.readHardwareMute(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput) {
            return hwMute
        }
        if let gain = Self.readScalarVolume(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput) {
            return gain <= 0.001
        }
        return false
    }

    @discardableResult
    private func setHardwareMute(
        _ muted: Bool,
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        var applied = false
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: scope,
                mElement: element
            )
            guard Self.isPropertySettable(deviceID: deviceID, address: &addr) else { continue }
            var flag: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(
                deviceID,
                &addr,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &flag
            ) == noErr {
                applied = true
                if element == kAudioObjectPropertyElementMain {
                    break
                }
            }
        }
        return applied
    }

    private static func defaultAudioDevice(isInput: Bool) -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : AudioObjectID(kAudioObjectUnknown)
    }

    private static func isPropertySettable(
        deviceID: AudioObjectID,
        address: inout AudioObjectPropertyAddress
    ) -> Bool {
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func readScalarVolume(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Float32? {
        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &virtualAddr) {
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &virtualAddr, 0, nil, &size, &value) == noErr,
               value.isFinite {
                return value
            }
        }

        var channelValues: [Float32] = []
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var scalarAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &scalarAddr) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &scalarAddr, 0, nil, &size, &value) == noErr,
               value.isFinite {
                if element == kAudioObjectPropertyElementMain {
                    return value
                }
                channelValues.append(value)
            }
        }
        guard !channelValues.isEmpty else { return nil }
        return channelValues.reduce(0, +) / Float32(channelValues.count)
    }

    private static func writeScalarVolume(
        _ volume: Float32,
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        var virtualAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        if isPropertySettable(deviceID: deviceID, address: &virtualAddr) {
            var mutable = volume
            if AudioObjectSetPropertyData(
                deviceID,
                &virtualAddr,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &mutable
            ) == noErr {
                return true
            }
        }

        var wrote = false
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var scalarAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope,
                mElement: element
            )
            guard isPropertySettable(deviceID: deviceID, address: &scalarAddr) else { continue }
            var mutable = volume
            if AudioObjectSetPropertyData(
                deviceID,
                &scalarAddr,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &mutable
            ) == noErr {
                wrote = true
            }
        }
        return wrote
    }

    private static func readHardwareMute(
        deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Bool? {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: scope,
                mElement: element
            )
            guard AudioObjectHasProperty(deviceID, &addr) else { continue }
            var muted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &muted) == noErr {
                return muted != 0
            }
        }
        return nil
    }

    nonisolated fileprivate static func isDeviceRunningAudio(deviceID: AudioObjectID) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    private static func enumerateAudioOutputDevices(
        defaultOutputID: AudioObjectID,
        bonjourAirPlayReceivers: [MacDiscoveredAirPlayReceiver]
    ) -> (devices: [MacAudioOutputDevice], selectedID: String?, canSwitch: Bool) {
        let driver = CoreAudioHardwareOutputDriver(bonjourAirPlayReceivers: bonjourAirPlayReceivers)
        let defaultSettable = driver.isSelectorSettable(.defaultOutput).isSettable
        let records = driver.readLiveDeviceRecords()
        let airPlayReceivers = driver.readDiscoveredAirPlayReceivers()
        let snapshot = MacAudioOutputSwitchEngine.enumerateSnapshot(
            records: records,
            airPlayReceivers: airPlayReceivers,
            defaultOutputObjectID: UInt32(defaultOutputID),
            isDefaultOutputSettable: defaultSettable
        )
        return (snapshot.devices, snapshot.selectedID, snapshot.canSwitch)
    }

    nonisolated fileprivate static func isAudioDeviceHidden(deviceID: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return false }
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &hidden) == noErr else {
            return false
        }
        return hidden != 0
    }

    nonisolated fileprivate static func canAudioDeviceBeDefaultOutput(deviceID: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return true }
        var canBeDefault: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &canBeDefault) == noErr else {
            return true
        }
        return canBeDefault != 0
    }

    nonisolated fileprivate static func isPrivateOrAutoAggregateAudioDevice(deviceID: AudioObjectID) -> Bool {
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rawTransport: UInt32 = 0
        if AudioObjectHasProperty(deviceID, &transportAddr) {
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &transportAddr, 0, nil, &size, &rawTransport) == noErr,
               rawTransport == kAudioDeviceTransportTypeAutoAggregate {
                return true
            }
        }

        var privAddr = AudioObjectPropertyAddress(
            mSelector: kAudioEndPointDevicePropertyIsPrivate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &privAddr) {
            var isPriv: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &privAddr, 0, nil, &size, &isPriv) == noErr,
               isPriv != 0 {
                return true
            }
        }

        if rawTransport == kAudioDeviceTransportTypeAggregate {
            var compAddr = AudioObjectPropertyAddress(
                mSelector: kAudioAggregateDevicePropertyComposition,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectHasProperty(deviceID, &compAddr) {
                var unmanagedDict: Unmanaged<CFDictionary>?
                var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
                let status = withUnsafeMutablePointer(to: &unmanagedDict) { ptr in
                    AudioObjectGetPropertyData(deviceID, &compAddr, 0, nil, &size, ptr)
                }
                if status == noErr, let cfDict = unmanagedDict?.takeRetainedValue() as? [String: Any] {
                    if let privNum = cfDict[kAudioAggregateDeviceIsPrivateKey] as? NSNumber, privNum.intValue != 0 {
                        return true
                    }
                    if let taps = cfDict[kAudioAggregateDeviceTapListKey] as? [Any], !taps.isEmpty {
                        return true
                    }
                }
            }
        }

        return false
    }

    nonisolated fileprivate static func outputChannelCount(deviceID: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return 0 }
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &byteSize) == noErr,
              byteSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPtr.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &byteSize, rawPtr) == noErr else {
            return 0
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(rawPtr.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    nonisolated fileprivate static func readCFStringProperty(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return nil }
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfStr = unmanaged?.takeRetainedValue() else {
            return nil
        }
        let trimmed = (cfStr as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated fileprivate static func readTransportKind(deviceID: AudioObjectID) -> MacAudioTransportKind {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return .virtualOrOther }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else {
            return .virtualOrOther
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeThunderbolt:
            return .displayAudio
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
        default:
            return .virtualOrOther
        }
    }

    // MARK: - CoreAudio Property Listeners

    private func registerSystemAudioDeviceListeners() {
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultOutputDevice,
            AudioObjectPropertySelector(MacAudioDefaultSelector.defaultSystemOutput.rawValue),
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyBoxList,
            kAudioHardwarePropertyPlugInList,
            kAudioHardwarePropertyTransportManagerList,
            Self.selectorServiceRestarted
        ]
        for selector in selectors {
            let addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            addAudioListener(on: systemObject, address: addr, into: &systemAudioListeners) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.rebindActiveAudioDeviceListeners()
                    self.refreshNow()
                }
            }
        }
    }

    private func rebindActiveAudioDeviceListenersIfChanged() {
        let outID = Self.defaultAudioDevice(isInput: false)
        let inID = Self.defaultAudioDevice(isInput: true)
        if outID != observedOutputDeviceID || inID != observedInputDeviceID {
            rebindActiveAudioDeviceListeners()
        }
    }

    private func rebindActiveAudioDeviceListeners() {
        removeAudioListeners(&deviceAudioListeners)

        let outID = Self.defaultAudioDevice(isInput: false)
        let inID = Self.defaultAudioDevice(isInput: true)
        observedOutputDeviceID = outID
        observedInputDeviceID = inID

        if outID != kAudioObjectUnknown {
            let outAddresses: [AudioObjectPropertyAddress] = [
                AudioObjectPropertyAddress(
                    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                ),
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                ),
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyMute,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                ),
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            ]
            for addr in outAddresses {
                addAudioListener(on: outID, address: addr, into: &deviceAudioListeners) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.refreshNow()
                    }
                }
            }
        }

        if inID != kAudioObjectUnknown {
            let inAddresses: [AudioObjectPropertyAddress] = [
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyMute,
                    mScope: kAudioDevicePropertyScopeInput,
                    mElement: kAudioObjectPropertyElementMain
                ),
                AudioObjectPropertyAddress(
                    mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                    mScope: kAudioDevicePropertyScopeInput,
                    mElement: kAudioObjectPropertyElementMain
                ),
                AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            ]
            for addr in inAddresses {
                addAudioListener(on: inID, address: addr, into: &deviceAudioListeners) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.refreshNow()
                    }
                }
            }
        }
    }

    private func addAudioListener(
        on objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        into storage: inout [RegisteredAudioListener],
        handler: @escaping () -> Void
    ) {
        var mutableAddr = address
        guard AudioObjectHasProperty(objectID, &mutableAddr) else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        if AudioObjectAddPropertyListenerBlock(objectID, &mutableAddr, listenerQueue, block) == noErr {
            storage.append(RegisteredAudioListener(objectID: objectID, address: address, block: block))
        }
    }

    private func removeAudioListeners(_ storage: inout [RegisteredAudioListener]) {
        for entry in storage {
            var mutableAddr = entry.address
            _ = AudioObjectRemovePropertyListenerBlock(entry.objectID, &mutableAddr, listenerQueue, entry.block)
        }
        storage.removeAll()
    }

    // MARK: - Now Playing Observation & Resolution

    private func registerNowPlayingObservers() {
        let dnc = DistributedNotificationCenter.default()
        let sources: [(notification: String, bundleID: String, appName: String)] = [
            ("com.apple.Music.playerInfo", "com.apple.Music", "Music"),
            ("com.apple.iTunes.playerInfo", "com.apple.Music", "Music"),
            ("com.spotify.client.PlaybackStateChanged", "com.spotify.client", "Spotify")
        ]

        for source in sources {
            let token = dnc.addObserver(
                forName: Notification.Name(source.notification),
                object: nil,
                queue: .main
            ) { [weak self] note in
                let userInfo = note.userInfo
                let state = (userInfo?["Player State"] as? String) ?? ""
                let title = (userInfo?["Name"] as? String)
                let artist = (userInfo?["Artist"] as? String)
                let durationSeconds: Double? = {
                    if let totalMs = (userInfo?["Total Time"] as? NSNumber)?.doubleValue, totalMs > 0, totalMs.isFinite {
                        return (totalMs / 1000.0).rounded(.down)
                    }
                    if let dur = (userInfo?["Duration"] as? NSNumber)?.doubleValue, dur > 0, dur.isFinite {
                        return (dur > 10_000 ? (dur / 1000.0) : dur).rounded(.down)
                    }
                    return nil
                }()
                let elapsedSeconds: Double? = {
                    if let pos = (userInfo?["Player Position"] as? NSNumber)?.doubleValue, pos >= 0, pos.isFinite {
                        return pos.rounded(.down)
                    }
                    if let pos = (userInfo?["Playback Position"] as? NSNumber)?.doubleValue, pos >= 0, pos.isFinite {
                        return pos.rounded(.down)
                    }
                    return nil
                }()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.ingestDistributedPlayerUpdate(
                        bundleID: source.bundleID,
                        appName: source.appName,
                        playerState: state,
                        title: title,
                        artist: artist,
                        elapsedSeconds: elapsedSeconds,
                        durationSeconds: durationSeconds
                    )
                }
            }
            distributedObservers.append(token)
        }

        mediaRemoteBridge.startNotifications()
        for name in mediaRemoteBridge.notificationNames {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshNow()
                }
            }
            localObservers.append(token)
        }
    }

    private func ingestDistributedPlayerUpdate(
        bundleID: String,
        appName: String,
        playerState: String,
        title: String?,
        artist: String?,
        elapsedSeconds: Double? = nil,
        durationSeconds: Double? = nil
    ) {
        if let status = NowPlayingStatus.distributedPlayerUpdate(
            playerState: playerState, title: title, artist: artist, appName: appName,
            bundleIdentifier: bundleID, elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds
        ) {
            playersWithoutCurrentTrack.remove(bundleID)
            distributedTracks[bundleID] = CachedDistributedTrack(
                bundleIdentifier: bundleID, status: status, updatedAt: Date()
            )
        } else {
            playersWithoutCurrentTrack.insert(bundleID)
            distributedTracks.removeValue(forKey: bundleID)
        }
        applyRefreshedSnapshot()
    }

    private func pruneTerminatedNowPlayingSessions() {
        for (bundleID, _) in distributedTracks {
            let isAlive = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains(where: { !$0.isTerminated })
            if !isAlive {
                distributedTracks.removeValue(forKey: bundleID)
            }
        }
        if latestMediaRemotePID > 0 {
            let appAlive = NSRunningApplication(processIdentifier: latestMediaRemotePID)
                .map { !$0.isTerminated } ?? false
            if !appAlive {
                latestMediaRemoteStatus = nil
                latestMediaRemoteBundleID = nil
                latestMediaRemotePID = 0
            }
        }
    }

    private func resolvedDistributedStatus(_ entry: CachedDistributedTrack, now: Date = Date()) -> NowPlayingStatus {
        guard entry.status.isPlaying,
              let baseElapsed = entry.status.elapsedSeconds,
              let duration = entry.status.durationSeconds,
              duration > 0 else {
            return entry.status
        }
        let delta = max(0.0, now.timeIntervalSince(entry.updatedAt))
        let advanced = min(duration, max(0.0, baseElapsed + delta)).rounded(.down)
        var copy = entry.status
        copy.elapsedSeconds = advanced
        return copy
    }

    private func resolveBestNowPlaying() -> NowPlayingStatus? {
        pruneTerminatedNowPlayingSessions()

        let sortedDistributed = distributedTracks.values.sorted { $0.updatedAt > $1.updatedAt }
        let mrBundleID = latestMediaRemoteStatus?.bundleIdentifier ?? latestMediaRemoteBundleID
        let mediaRemote = mrBundleID.map { playersWithoutCurrentTrack.contains($0) } == true
            ? nil : latestMediaRemoteStatus
        // Explicit player metadata outranks generic audio activity. A distributed update
        // also replaces a stale MediaRemote playing bit for that same application.
        if let mr = mediaRemote, mr.hasActiveMedia {
            let bundleID = mr.bundleIdentifier ?? latestMediaRemoteBundleID
            if let entry = sortedDistributed.first(where: { $0.bundleIdentifier == bundleID }) {
                return resolvedDistributedStatus(entry)
            }
            if mr.isPlaying { return mr }
        }
        if let playing = sortedDistributed.first(where: { $0.status.isPlaying && $0.status.hasActiveMedia }) {
            return resolvedDistributedStatus(playing)
        }
        if let paused = sortedDistributed.first(where: { $0.status.hasActiveMedia }) {
            return resolvedDistributedStatus(paused)
        }
        if let mr = mediaRemote, mr.hasActiveMedia { return mr }

        let outDevice = Self.defaultAudioDevice(isInput: false)
        if Self.isDeviceRunningAudio(deviceID: outDevice),
           let activeAudioApp = Self.findActiveAudioOutputApp(),
           activeAudioApp.bundleID.map({ !playersWithoutCurrentTrack.contains($0) }) ?? true {
            return NowPlayingStatus(
                appName: activeAudioApp.name, isPlaying: true,
                bundleIdentifier: activeAudioApp.bundleID
            )
        }

        return nil
    }

    /// Computes live Now Playing session context for `MacMediaSeekRouter` when scrubbing playback position.
    public func currentMediaSeekContext() -> MacMediaSeekContext {
        let resolved = resolveBestNowPlaying() ?? currentState.nowPlaying
        let spotifyRunning = NSRunningApplication.runningApplications(
            withBundleIdentifier: MacMediaSeekRouter.spotifyBundleIdentifier
        ).contains(where: { !$0.isTerminated })
        let musicRunning = NSRunningApplication.runningApplications(
            withBundleIdentifier: MacMediaSeekRouter.musicBundleIdentifier
        ).contains(where: { !$0.isTerminated })

        return MacMediaSeekContext(
            nowPlayingBundleID: resolved?.bundleIdentifier,
            durationSeconds: resolved?.durationSeconds,
            isSpotifyRunning: spotifyRunning,
            isMusicRunning: musicRunning
        )
    }

    /// Immediately updates cached Now Playing elapsed time after a verified background seek and schedules
    /// post-action refreshes so Mac Studio and all companions converge on the player's authoritative position.
    public func recordAppliedSeek(positionSeconds: Double) {
        let now = Date()
        if var mr = latestMediaRemoteStatus, let duration = mr.durationSeconds, duration > 0 {
            mr.elapsedSeconds = MacMediaSeekRouter.clampPosition(positionSeconds, durationSeconds: duration).rounded(.down)
            latestMediaRemoteStatus = mr
        }
        if let activeBundle = (resolveBestNowPlaying() ?? currentState.nowPlaying)?.bundleIdentifier {
            for (key, cached) in distributedTracks where key.caseInsensitiveCompare(activeBundle) == .orderedSame {
                if let duration = cached.status.durationSeconds, duration > 0 {
                    var updatedStatus = cached.status
                    updatedStatus.elapsedSeconds = MacMediaSeekRouter.clampPosition(positionSeconds, durationSeconds: duration).rounded(.down)
                    distributedTracks[key] = CachedDistributedTrack(
                        bundleIdentifier: cached.bundleIdentifier,
                        status: updatedStatus,
                        updatedAt: now
                    )
                }
            }
        }
        if var np = currentState.nowPlaying, let duration = np.durationSeconds, duration > 0 {
            np.elapsedSeconds = MacMediaSeekRouter.clampPosition(positionSeconds, durationSeconds: duration).rounded(.down)
            var next = currentState
            next.nowPlaying = np
            let changed = next.hasMeaningfulDifference(from: currentState)
            currentState = next
            if changed {
                onStateChanged?(next)
            }
        }
        schedulePostSeekRefresh()
    }

    /// Computes live playback & app context for `MacMediaTransportRouter` when the user triggers Play/Pause/Next/Previous.
    public func currentMediaTransportContext() -> MacMediaTransportContext {
        pruneTerminatedNowPlayingSessions()

        let spotifyID = MacMediaTransportRouter.spotifyBundleIdentifier
        let spotifyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: spotifyID)
            .contains(where: { !$0.isTerminated })
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        let activeOutputApps = Self.findActiveAudioOutputApps()
        let spotifyAudioActive = activeOutputApps.contains {
            $0.bundleID?.caseInsensitiveCompare(spotifyID) == .orderedSame
        }
        let spotifyDistributedPlaying = distributedTracks[spotifyID]?.status.isPlaying == true
        let isSpotifyPlaying = spotifyRunning && (spotifyAudioActive || spotifyDistributedPlaying)

        let nonSpotifyActiveAudioApps = activeOutputApps.filter {
            $0.bundleID?.caseInsensitiveCompare(spotifyID) != .orderedSame
        }
        let sortedDistributed = distributedTracks.values.sorted { $0.updatedAt > $1.updatedAt }

        var resolvedNowPlayingBundleID: String?
        var resolvedIsNowPlayingPlaying = false

        if let mr = latestMediaRemoteStatus, mr.hasActiveMedia, mr.isPlaying {
            resolvedNowPlayingBundleID = latestMediaRemoteBundleID ?? nonSpotifyActiveAudioApps.first?.bundleID
            resolvedIsNowPlayingPlaying = true
        } else if let playingDist = sortedDistributed.first(where: { $0.status.isPlaying && $0.status.hasActiveMedia }) {
            resolvedNowPlayingBundleID = playingDist.bundleIdentifier
            resolvedIsNowPlayingPlaying = true
        } else if let activeApp = activeOutputApps.first, let activeBundle = activeApp.bundleID {
            resolvedNowPlayingBundleID = activeBundle
            resolvedIsNowPlayingPlaying = true
        } else if let mr = latestMediaRemoteStatus, mr.hasActiveMedia, let mrBundle = latestMediaRemoteBundleID {
            resolvedNowPlayingBundleID = mrBundle
            resolvedIsNowPlayingPlaying = false
        } else if let pausedDist = sortedDistributed.first(where: { $0.status.hasActiveMedia }) {
            resolvedNowPlayingBundleID = pausedDist.bundleIdentifier
            resolvedIsNowPlayingPlaying = false
        }

        let hasNonSpotifyMediaRemote = (latestMediaRemoteStatus?.hasActiveMedia == true) &&
            (latestMediaRemoteBundleID?.caseInsensitiveCompare(spotifyID) != .orderedSame)
        let hasNonSpotifyDistributed = sortedDistributed.contains {
            $0.status.hasActiveMedia && $0.bundleIdentifier.caseInsensitiveCompare(spotifyID) != .orderedSame
        }
        let hasOtherActiveClient = hasNonSpotifyMediaRemote ||
            hasNonSpotifyDistributed ||
            !nonSpotifyActiveAudioApps.isEmpty

        return MacMediaTransportContext(
            nowPlayingBundleID: resolvedNowPlayingBundleID,
            isNowPlayingPlaying: resolvedIsNowPlayingPlaying,
            isSpotifyRunning: spotifyRunning,
            isSpotifyPlaying: isSpotifyPlaying,
            frontmostBundleID: frontmostBundleID,
            hasOtherActiveMediaClient: hasOtherActiveClient
        )
    }

    private struct ActiveAudioOutputApp {
        let name: String
        let bundleID: String?
        let isRegularApp: Bool
    }

    private static let ignoredSystemAudioBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.powerchime",
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
        "com.apple.coreservices.uiagent",
        "com.apple.accessibility.heard"
    ]

    private static func findActiveAudioOutputApp() -> ActiveAudioOutputApp? {
        let apps = findActiveAudioOutputApps()
        if let regular = apps.first(where: \.isRegularApp) {
            return regular
        }
        return apps.first
    }

    private static func findActiveAudioOutputApps() -> [ActiveAudioOutputApp] {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: selectorProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteSize: UInt32 = 0
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sysObj, &listAddr, 0, nil, &byteSize) == noErr,
              byteSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return []
        }

        let count = Int(byteSize) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sysObj, &listAddr, 0, nil, &byteSize, &objects) == noErr else {
            return []
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        var regularApps: [ActiveAudioOutputApp] = []
        var otherApps: [ActiveAudioOutputApp] = []

        for procObj in objects {
            var isOut: UInt32 = 0
            var outSize = UInt32(MemoryLayout<UInt32>.size)
            var outAddr = AudioObjectPropertyAddress(
                mSelector: selectorProcessIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(procObj, &outAddr, 0, nil, &outSize, &isOut) == noErr,
                  isOut != 0 else {
                continue
            }

            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: selectorProcessPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(procObj, &pidAddr, 0, nil, &pidSize, &pid) == noErr,
                  pid > 0,
                  pid != selfPID else {
                continue
            }

            if let resolved = resolveUserFacingAppInfo(forPID: pid) {
                if let bid = resolved.bundleID?.lowercased(), ignoredSystemAudioBundleIDs.contains(bid) {
                    continue
                }
                let item = ActiveAudioOutputApp(
                    name: resolved.name,
                    bundleID: resolved.bundleID,
                    isRegularApp: resolved.isRegularApp
                )
                if resolved.isRegularApp {
                    regularApps.append(item)
                } else {
                    otherApps.append(item)
                }
            }
        }

        return regularApps + otherApps
    }

    nonisolated fileprivate static func resolveUserFacingAppName(forPID pid: pid_t) -> (name: String, isRegularApp: Bool)? {
        guard let info = resolveUserFacingAppInfo(forPID: pid) else { return nil }
        return (info.name, info.isRegularApp)
    }

    nonisolated fileprivate static func resolveUserFacingAppInfo(
        forPID pid: pid_t
    ) -> (name: String, bundleID: String?, isRegularApp: Bool)? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return nil
        }

        if app.activationPolicy == .regular,
           let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return (name, app.bundleIdentifier, true)
        }

        // Helper process inside a parent .app bundle (e.g., Google Chrome Helper, Arc Helper, FirefoxCP)
        if let bundleURL = app.bundleURL {
            var cursor = bundleURL.deletingLastPathComponent()
            while cursor.path.count > 1 {
                if cursor.pathExtension.lowercased() == "app",
                   let parentBundle = Bundle(url: cursor),
                   let bundleID = parentBundle.bundleIdentifier,
                   let runningParent = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated && $0.activationPolicy == .regular }),
                   let parentName = runningParent.localizedName,
                   !parentName.isEmpty {
                    return (parentName, bundleID, true)
                }
                let next = cursor.deletingLastPathComponent()
                if next.path == cursor.path { break }
                cursor = next
            }
        }

        // WebKit GPU/Audio helper used by Safari
        if let bid = app.bundleIdentifier, bid.hasPrefix("com.apple.WebKit") {
            if let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first(where: { !$0.isTerminated }),
               let safariName = safari.localizedName {
                return (safariName, "com.apple.Safari", true)
            }
        }

        if let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return (name, app.bundleIdentifier, false)
        }

        return nil
    }
}

// MARK: - Live CoreAudio Hardware Output Driver (macOS 13+)

public struct CoreAudioHardwareOutputDriver: MacAudioOutputHardwareDriver {
    private let bonjourAirPlayReceivers: [MacDiscoveredAirPlayReceiver]

    public init(bonjourAirPlayReceivers: [MacDiscoveredAirPlayReceiver] = []) {
        self.bonjourAirPlayReceivers = bonjourAirPlayReceivers
    }

    public func isSelectorAvailable(_ selector: MacAudioDefaultSelector) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(selector.rawValue),
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &addr)
    }

    public func isSelectorSettable(_ selector: MacAudioDefaultSelector) -> (isSettable: Bool, status: Int32) {
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(selector.rawValue),
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(sysObj, &addr) else {
            return (false, kAudioHardwareUnknownPropertyError)
        }
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(sysObj, &addr, &settable)
        return (status == noErr && settable.boolValue, status)
    }

    public func readDefaultDevice(for selector: MacAudioDefaultSelector) -> (objectID: UInt32, status: Int32) {
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(selector.rawValue),
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(sysObj, &addr) else {
            return (UInt32(kAudioObjectUnknown), kAudioHardwareUnknownPropertyError)
        }
        var devID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &size, &devID)
        return (status == noErr ? UInt32(devID) : UInt32(kAudioObjectUnknown), status)
    }

    public func writeDefaultDevice(_ objectID: UInt32, for selector: MacAudioDefaultSelector) -> Int32 {
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(selector.rawValue),
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(sysObj, &addr) else {
            return kAudioHardwareUnknownPropertyError
        }
        var mutableTarget = AudioObjectID(objectID)
        return AudioObjectSetPropertyData(
            sysObj,
            &addr,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &mutableTarget
        )
    }

    public func readLiveDeviceRecords() -> [MacAudioRawDeviceRecord] {
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rawIDs: [AudioObjectID] = []
        var byteSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(sysObj, &devicesAddr, 0, nil, &byteSize) == noErr,
           byteSize >= UInt32(MemoryLayout<AudioObjectID>.size) {
            let count = Int(byteSize) / MemoryLayout<AudioObjectID>.size
            var ids = [AudioObjectID](repeating: 0, count: count)
            if AudioObjectGetPropertyData(sysObj, &devicesAddr, 0, nil, &byteSize, &ids) == noErr {
                rawIDs = ids
            }
        }

        // Also check system-owned AudioDevice objects so any hidden AirPlay AudioDevice omitted from
        // kAudioHardwarePropertyDevices is still inspected by shouldIncludeCoreAudioRecord.
        var seenIDs = Set(rawIDs)
        for ownedDevID in Self.readOwnedAirPlayDeviceIDs() where seenIDs.insert(ownedDevID).inserted {
            rawIDs.append(ownedDevID)
        }

        var records: [MacAudioRawDeviceRecord] = []
        records.reserveCapacity(rawIDs.count)

        for devID in rawIDs where devID != kAudioObjectUnknown {
            let outChannels = MacSystemControlService.outputChannelCount(deviceID: devID)
            let uid = MacSystemControlService.readCFStringProperty(
                deviceID: devID,
                selector: kAudioDevicePropertyDeviceUID
            )
            let modelUID = MacSystemControlService.readCFStringProperty(
                deviceID: devID,
                selector: kAudioDevicePropertyModelUID
            )
            let name = MacSystemControlService.readCFStringProperty(
                deviceID: devID,
                selector: kAudioObjectPropertyName
            ) ?? "Audio Output"
            let transport = MacSystemControlService.readTransportKind(deviceID: devID)
            let hidden = MacSystemControlService.isAudioDeviceHidden(deviceID: devID)
            let privateAgg = MacSystemControlService.isPrivateOrAutoAggregateAudioDevice(deviceID: devID)
            let canBeDefault = MacSystemControlService.canAudioDeviceBeDefaultOutput(deviceID: devID)

            records.append(
                MacAudioRawDeviceRecord(
                    audioObjectID: UInt32(devID),
                    uid: uid,
                    name: name,
                    transportKind: transport,
                    outputChannelCount: outChannels,
                    isHidden: hidden,
                    isPrivateAggregate: privateAgg,
                    canBeDefaultOutput: canBeDefault,
                    modelUID: modelUID
                )
            )
        }

        return records
    }

    public func readDiscoveredAirPlayReceivers() -> [MacDiscoveredAirPlayReceiver] {
        let boxReceivers = Self.readCoreAudioAirPlayBoxes()
        guard !boxReceivers.isEmpty else {
            return bonjourAirPlayReceivers
        }

        var merged = boxReceivers
        for bonjour in bonjourAirPlayReceivers {
            let normKey = bonjour.normalizedDeviceKey
            let nameKey = MacAudioOutputDevice.normalizeDisplayNameKey(bonjour.name)
            if let idx = merged.firstIndex(where: {
                (!normKey.isEmpty && $0.normalizedDeviceKey == normKey) ||
                MacAudioOutputDevice.normalizeDisplayNameKey($0.name) == nameKey
            }) {
                if merged[idx].model == nil, let model = bonjour.model {
                    merged[idx].model = model
                }
                if merged[idx].groupID == nil, let gid = bonjour.groupID {
                    merged[idx].groupID = gid
                }
            } else {
                merged.append(bonjour)
            }
        }
        return merged
    }

    public func acquireAirPlayBox(_ boxObjectID: UInt32) -> (deviceObjectID: UInt32?, status: Int32) {
        let boxID = AudioObjectID(boxObjectID)
        guard boxID != kAudioObjectUnknown else {
            return (nil, kAudioHardwareBadObjectError)
        }

        var acquireAddr = AudioObjectPropertyAddress(
            mSelector: kAudioBoxPropertyAcquired,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(boxID, &acquireAddr) else {
            return (nil, kAudioHardwareUnknownPropertyError)
        }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(boxID, &acquireAddr, &settable) == noErr, settable.boolValue else {
            return (nil, kAudioHardwareUnsupportedOperationError)
        }

        var flag: UInt32 = 1
        let status = AudioObjectSetPropertyData(
            boxID,
            &acquireAddr,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &flag
        )
        guard status == noErr else {
            return (nil, status)
        }

        for _ in 0..<24 {
            if let devID = Self.firstBoxDeviceID(boxID: boxID), devID != kAudioObjectUnknown {
                return (UInt32(devID), noErr)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        return (Self.firstBoxDeviceID(boxID: boxID).map { UInt32($0) }, noErr)
    }

    private static func readOwnedAirPlayDeviceIDs() -> [AudioObjectID] {
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        var ownedAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyOwnedObjects,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(sysObj, &ownedAddr) else { return [] }
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sysObj, &ownedAddr, 0, nil, &byteSize) == noErr,
              byteSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return []
        }
        let count = Int(byteSize) / MemoryLayout<AudioObjectID>.size
        var owned = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sysObj, &ownedAddr, 0, nil, &byteSize, &owned) == noErr else {
            return []
        }

        var airPlayDevs: [AudioObjectID] = []
        for objID in owned where objID != kAudioObjectUnknown {
            var clsAddr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyClass,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cls: AudioClassID = 0
            var clsSize = UInt32(MemoryLayout<AudioClassID>.size)
            guard AudioObjectHasProperty(objID, &clsAddr),
                  AudioObjectGetPropertyData(objID, &clsAddr, 0, nil, &clsSize, &cls) == noErr,
                  cls == kAudioDeviceClassID else {
                continue
            }
            if MacSystemControlService.readTransportKind(deviceID: objID) == .airPlay {
                airPlayDevs.append(objID)
            }
        }
        return airPlayDevs
    }

    private static func readCoreAudioAirPlayBoxes() -> [MacDiscoveredAirPlayReceiver] {
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        var boxListAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyBoxList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(sysObj, &boxListAddr) else { return [] }
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sysObj, &boxListAddr, 0, nil, &byteSize) == noErr,
              byteSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return []
        }
        let count = Int(byteSize) / MemoryLayout<AudioObjectID>.size
        var boxIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sysObj, &boxListAddr, 0, nil, &byteSize, &boxIDs) == noErr else {
            return []
        }

        var results: [MacDiscoveredAirPlayReceiver] = []
        for boxID in boxIDs where boxID != kAudioObjectUnknown {
            var tranAddr = AudioObjectPropertyAddress(
                mSelector: kAudioBoxPropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var tran: UInt32 = 0
            var u32Size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectHasProperty(boxID, &tranAddr),
                  AudioObjectGetPropertyData(boxID, &tranAddr, 0, nil, &u32Size, &tran) == noErr,
                  tran == kAudioDeviceTransportTypeAirPlay else {
                continue
            }

            var hasAudioAddr = AudioObjectPropertyAddress(
                mSelector: kAudioBoxPropertyHasAudio,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectHasProperty(boxID, &hasAudioAddr) {
                var hasAudio: UInt32 = 0
                var haSize = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(boxID, &hasAudioAddr, 0, nil, &haSize, &hasAudio) == noErr,
                   hasAudio == 0 {
                    continue
                }
            }

            let boxUID = MacSystemControlService.readCFStringProperty(
                deviceID: boxID,
                selector: kAudioBoxPropertyBoxUID
            ) ?? ""
            let name = MacSystemControlService.readCFStringProperty(
                deviceID: boxID,
                selector: kAudioObjectPropertyName
            ) ?? "AirPlay Speaker"
            let model = MacSystemControlService.readCFStringProperty(
                deviceID: boxID,
                selector: kAudioDevicePropertyModelUID
            )

            var acqAddr = AudioObjectPropertyAddress(
                mSelector: kAudioBoxPropertyAcquired,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isSettable: DarwinBoolean = false
            let canAcquire = AudioObjectHasProperty(boxID, &acqAddr) &&
                AudioObjectIsPropertySettable(boxID, &acqAddr, &isSettable) == noErr &&
                isSettable.boolValue

            let firstDev = firstBoxDeviceID(boxID: boxID) ?? AudioObjectID(kAudioObjectUnknown)

            results.append(
                MacDiscoveredAirPlayReceiver(
                    deviceID: boxUID,
                    name: name,
                    model: model,
                    audioBoxObjectID: UInt32(boxID),
                    audioDeviceObjectID: UInt32(firstDev),
                    isSelectableViaCoreAudio: canAcquire || (firstDev != kAudioObjectUnknown)
                )
            )
        }
        return results
    }

    private static func firstBoxDeviceID(boxID: AudioObjectID) -> AudioObjectID? {
        var devListAddr = AudioObjectPropertyAddress(
            mSelector: kAudioBoxPropertyDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(boxID, &devListAddr) else { return nil }
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(boxID, &devListAddr, 0, nil, &byteSize) == noErr,
              byteSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return nil
        }
        let count = Int(byteSize) / MemoryLayout<AudioObjectID>.size
        var devs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(boxID, &devListAddr, 0, nil, &byteSize, &devs) == noErr else {
            return nil
        }
        return devs.first(where: { $0 != kAudioObjectUnknown && MacSystemControlService.outputChannelCount(deviceID: $0) > 0 })
            ?? devs.first(where: { $0 != kAudioObjectUnknown })
    }

    public func translateUIDToLiveObjectID(_ uid: String) -> UInt32? {
        let trimmed = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        var translateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(sysObj, &translateAddr) else { return nil }

        var cfUID: CFString = trimmed as CFString
        var resolvedID = AudioObjectID(kAudioObjectUnknown)
        var outSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                sysObj,
                &translateAddr,
                UInt32(MemoryLayout<CFString>.size),
                uidPtr,
                &outSize,
                &resolvedID
            )
        }
        guard status == noErr, resolvedID != kAudioObjectUnknown else { return nil }
        return UInt32(resolvedID)
    }

    public func readRunningOutputProcesses(excludingCurrentProcess: Bool) -> [MacAudioRunningProcessRecord]? {
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = AudioObjectPropertyAddress(
            mSelector: MacSystemControlService.selectorProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(sysObj, &listAddr) else {
            return nil
        }

        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sysObj, &listAddr, 0, nil, &byteSize) == noErr else {
            return []
        }
        guard byteSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return []
        }

        let count = Int(byteSize) / MemoryLayout<AudioObjectID>.size
        var procObjects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sysObj, &listAddr, 0, nil, &byteSize, &procObjects) == noErr else {
            return []
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        var results: [MacAudioRunningProcessRecord] = []

        for procObj in procObjects where procObj != kAudioObjectUnknown {
            var isOut: UInt32 = 0
            var outSize = UInt32(MemoryLayout<UInt32>.size)
            var outAddr = AudioObjectPropertyAddress(
                mSelector: MacSystemControlService.selectorProcessIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(procObj, &outAddr),
                  AudioObjectGetPropertyData(procObj, &outAddr, 0, nil, &outSize, &isOut) == noErr,
                  isOut != 0 else {
                continue
            }

            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: MacSystemControlService.selectorProcessPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(procObj, &pidAddr),
                  AudioObjectGetPropertyData(procObj, &pidAddr, 0, nil, &pidSize, &pid) == noErr,
                  pid > 0 else {
                continue
            }
            if excludingCurrentProcess && pid == selfPID {
                continue
            }

            let (deviceIDs, isSettable) = Self.readProcessDeviceIDsAndSettability(processObjectID: procObj)
            let appName = MacSystemControlService.resolveUserFacingAppName(forPID: pid)?.name

            results.append(
                MacAudioRunningProcessRecord(
                    processObjectID: UInt32(procObj),
                    pid: pid,
                    appName: appName,
                    outputDeviceObjectIDs: deviceIDs,
                    isOutputDeviceSettable: isSettable
                )
            )
        }

        return results
    }

    public func writeProcessOutputDevice(processObjectID: UInt32, targetDeviceObjectID: UInt32) -> Int32 {
        let procObj = AudioObjectID(processObjectID)
        var target = AudioObjectID(targetDeviceObjectID)
        let scopes: [AudioObjectPropertyScope] = [
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyScopeGlobal
        ]
        var lastStatus: Int32 = kAudioHardwareUnknownPropertyError

        for scope in scopes {
            var addr = AudioObjectPropertyAddress(
                mSelector: MacSystemControlService.selectorProcessDevices,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(procObj, &addr) else { continue }
            var settable: DarwinBoolean = false
            let settableStatus = AudioObjectIsPropertySettable(procObj, &addr, &settable)
            guard settableStatus == noErr && settable.boolValue else {
                lastStatus = (settableStatus != noErr) ? settableStatus : kAudioHardwareUnsupportedOperationError
                continue
            }
            let status = AudioObjectSetPropertyData(
                procObj,
                &addr,
                0,
                nil,
                UInt32(MemoryLayout<AudioObjectID>.size),
                &target
            )
            if status == noErr {
                return noErr
            }
            lastStatus = status
        }

        return lastStatus
    }

    public func isDeviceRunningOutputAudio(_ objectID: UInt32) -> Bool {
        MacSystemControlService.isDeviceRunningAudio(deviceID: AudioObjectID(objectID))
    }

    private static func readProcessDeviceIDsAndSettability(
        processObjectID: AudioObjectID
    ) -> (deviceIDs: [UInt32], isSettable: Bool) {
        let scopes: [AudioObjectPropertyScope] = [
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyScopeGlobal
        ]
        var collectedIDs: [UInt32] = []
        var anySettable = false

        for scope in scopes {
            var addr = AudioObjectPropertyAddress(
                mSelector: MacSystemControlService.selectorProcessDevices,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(processObjectID, &addr) else { continue }

            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(processObjectID, &addr, &settable) == noErr && settable.boolValue {
                anySettable = true
            }

            if collectedIDs.isEmpty {
                var byteSize: UInt32 = 0
                if AudioObjectGetPropertyDataSize(processObjectID, &addr, 0, nil, &byteSize) == noErr,
                   byteSize >= UInt32(MemoryLayout<AudioObjectID>.size) {
                    let count = Int(byteSize) / MemoryLayout<AudioObjectID>.size
                    var raw = [AudioObjectID](repeating: 0, count: count)
                    if AudioObjectGetPropertyData(processObjectID, &addr, 0, nil, &byteSize, &raw) == noErr {
                        collectedIDs = raw.filter { $0 != kAudioObjectUnknown }.map { UInt32($0) }
                    }
                }
            }
        }

        return (collectedIDs, anySettable)
    }
}

// MARK: - macOS 13+ Main Display Brightness Bridge (DisplayServices + IOKit Fallback)

private final class DisplayBrightnessBridge {
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getBrightnessFn: GetBrightnessFn?
    private let setBrightnessFn: SetBrightnessFn?

    init() {
        if let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) {
            if let getSym = dlsym(handle, "DisplayServicesGetBrightness") {
                self.getBrightnessFn = unsafeBitCast(getSym, to: GetBrightnessFn.self)
            } else {
                self.getBrightnessFn = nil
            }
            if let setSym = dlsym(handle, "DisplayServicesSetBrightness") {
                self.setBrightnessFn = unsafeBitCast(setSym, to: SetBrightnessFn.self)
            } else {
                self.setBrightnessFn = nil
            }
        } else {
            self.getBrightnessFn = nil
            self.setBrightnessFn = nil
        }
    }

    func readMainDisplayBrightness() -> Double? {
        let mainDisplay = CGMainDisplayID()
        if let getBrightnessFn {
            var value: Float = -1
            if getBrightnessFn(mainDisplay, &value) == 0, value.isFinite, value >= 0.0, value <= 1.0 {
                return ControlStripLevel.clamp(Double(value))
            }
        }
        return readIOKitDisplayBrightness()
    }

    func setMainDisplayBrightness(_ level: Float) -> Bool {
        let bounded = max(0.0, min(1.0, level))
        let mainDisplay = CGMainDisplayID()
        if let setBrightnessFn, setBrightnessFn(mainDisplay, bounded) == 0 {
            return true
        }
        return writeIOKitDisplayBrightness(bounded)
    }

    private func readIOKitDisplayBrightness() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        ) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var value: Float = 0
            if IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value) == kIOReturnSuccess,
               value.isFinite {
                return ControlStripLevel.clamp(Double(value))
            }
        }
        return nil
    }

    private func writeIOKitDisplayBrightness(_ level: Float) -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        ) == kIOReturnSuccess else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        var succeeded = false
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            if IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, level) == kIOReturnSuccess {
                succeeded = true
            }
        }
        return succeeded
    }
}

// MARK: - Dynamic MediaRemote Bridge (macOS 13+ Safe Runtime Lookup)

private final class MediaRemoteBridge {
    private typealias RegisterNotificationsFn = @convention(c) (DispatchQueue) -> Void
    private typealias GetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void
    private typealias GetNowPlayingPIDFn = @convention(c) (DispatchQueue, @escaping (Int32) -> Void) -> Void
    private typealias GetIsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void

    private let registerFn: RegisterNotificationsFn?
    private let getInfoFn: GetNowPlayingInfoFn?
    private let getPIDFn: GetNowPlayingPIDFn?
    private let getIsPlayingFn: GetIsPlayingFn?
    private let titleKey: String
    private let artistKey: String
    private let durationKey: String
    private let elapsedTimeKey: String
    private let timestampKey: String
    private let playbackRateKey: String
    let notificationNames: [Notification.Name]
    private var didRegister = false

    var isAvailable: Bool {
        getInfoFn != nil && getIsPlayingFn != nil
    }

    init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY) else {
            self.registerFn = nil
            self.getInfoFn = nil
            self.getPIDFn = nil
            self.getIsPlayingFn = nil
            self.titleKey = "kMRMediaRemoteNowPlayingInfoTitle"
            self.artistKey = "kMRMediaRemoteNowPlayingInfoArtist"
            self.durationKey = "kMRMediaRemoteNowPlayingInfoDuration"
            self.elapsedTimeKey = "kMRMediaRemoteNowPlayingInfoElapsedTime"
            self.timestampKey = "kMRMediaRemoteNowPlayingInfoTimestamp"
            self.playbackRateKey = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
            self.notificationNames = []
            return
        }

        self.registerFn = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications")
            .map { unsafeBitCast($0, to: RegisterNotificationsFn.self) }
        self.getInfoFn = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo")
            .map { unsafeBitCast($0, to: GetNowPlayingInfoFn.self) }
        self.getPIDFn = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID")
            .map { unsafeBitCast($0, to: GetNowPlayingPIDFn.self) }
        self.getIsPlayingFn = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying")
            .map { unsafeBitCast($0, to: GetIsPlayingFn.self) }

        self.titleKey = Self.loadCFStringConstant(from: handle, symbol: "kMRMediaRemoteNowPlayingInfoTitle")
            ?? "kMRMediaRemoteNowPlayingInfoTitle"
        self.artistKey = Self.loadCFStringConstant(from: handle, symbol: "kMRMediaRemoteNowPlayingInfoArtist")
            ?? "kMRMediaRemoteNowPlayingInfoArtist"
        self.durationKey = Self.loadCFStringConstant(from: handle, symbol: "kMRMediaRemoteNowPlayingInfoDuration")
            ?? "kMRMediaRemoteNowPlayingInfoDuration"
        self.elapsedTimeKey = Self.loadCFStringConstant(from: handle, symbol: "kMRMediaRemoteNowPlayingInfoElapsedTime")
            ?? "kMRMediaRemoteNowPlayingInfoElapsedTime"
        self.timestampKey = Self.loadCFStringConstant(from: handle, symbol: "kMRMediaRemoteNowPlayingInfoTimestamp")
            ?? "kMRMediaRemoteNowPlayingInfoTimestamp"
        self.playbackRateKey = Self.loadCFStringConstant(from: handle, symbol: "kMRMediaRemoteNowPlayingInfoPlaybackRate")
            ?? "kMRMediaRemoteNowPlayingInfoPlaybackRate"

        let noteSymbols = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"
        ]
        self.notificationNames = noteSymbols.compactMap {
            Self.loadCFStringConstant(from: handle, symbol: $0).map { Notification.Name(rawValue: $0) }
        }
    }

    func startNotifications() {
        guard !didRegister, let registerFn else { return }
        didRegister = true
        registerFn(.main)
    }

    struct NowPlayingFetchPayload {
        let status: NowPlayingStatus?
        let bundleIdentifier: String?
        let pid: pid_t
    }

    func fetchNowPlaying(completion: @escaping @MainActor (NowPlayingFetchPayload) -> Void) {
        guard let getInfoFn, let getIsPlayingFn else {
            Task { @MainActor in completion(NowPlayingFetchPayload(status: nil, bundleIdentifier: nil, pid: 0)) }
            return
        }

        getInfoFn(.main) { [titleKey, artistKey, durationKey, elapsedTimeKey, timestampKey, playbackRateKey, getPIDFn] rawInfo in
            let title = rawInfo?[titleKey] as? String
            let artist = rawInfo?[artistKey] as? String
            let rawDuration = (rawInfo?[durationKey] as? NSNumber)?.doubleValue
            let rawElapsed = (rawInfo?[elapsedTimeKey] as? NSNumber)?.doubleValue
            let infoTimestamp = rawInfo?[timestampKey] as? Date
            let rawRate = (rawInfo?[playbackRateKey] as? NSNumber)?.doubleValue

            getIsPlayingFn(.main) { isPlaying in
                let timing = Self.resolveTiming(
                    rawElapsed: rawElapsed,
                    rawDuration: rawDuration,
                    timestamp: infoTimestamp,
                    rawPlaybackRate: rawRate,
                    isPlaying: isPlaying,
                    now: Date()
                )
                if let getPIDFn {
                    getPIDFn(.main) { pid in
                        let resolvedApp = (pid > 0) ? MacSystemControlService.resolveUserFacingAppInfo(forPID: pid) : nil
                        let runningApp = (pid > 0) ? NSRunningApplication(processIdentifier: pid) : nil
                        let appName = resolvedApp?.name ?? runningApp?.localizedName
                        let bundleID = resolvedApp?.bundleID ?? runningApp?.bundleIdentifier
                        let status = NowPlayingStatus(
                            title: title,
                            artist: artist,
                            appName: appName,
                            isPlaying: isPlaying,
                            elapsedSeconds: timing.elapsedSeconds,
                            durationSeconds: timing.durationSeconds,
                            bundleIdentifier: bundleID
                        )
                        let activeStatus = status.hasActiveMedia ? status : nil
                        Task { @MainActor in
                            completion(
                                NowPlayingFetchPayload(
                                    status: activeStatus,
                                    bundleIdentifier: activeStatus != nil ? bundleID : nil,
                                    pid: activeStatus != nil ? pid : 0
                                )
                            )
                        }
                    }
                } else {
                    let status = NowPlayingStatus(
                        title: title,
                        artist: artist,
                        appName: nil,
                        isPlaying: isPlaying,
                        elapsedSeconds: timing.elapsedSeconds,
                        durationSeconds: timing.durationSeconds
                    )
                    let activeStatus = status.hasActiveMedia ? status : nil
                    Task { @MainActor in
                        completion(NowPlayingFetchPayload(status: activeStatus, bundleIdentifier: nil, pid: 0))
                    }
                }
            }
        }
    }

    private static func resolveTiming(
        rawElapsed: Double?,
        rawDuration: Double?,
        timestamp: Date?,
        rawPlaybackRate: Double?,
        isPlaying: Bool,
        now: Date
    ) -> (elapsedSeconds: Double?, durationSeconds: Double?) {
        guard let rawDuration,
              rawDuration.isFinite,
              !rawDuration.isNaN,
              rawDuration > 0 else {
            return (nil, nil)
        }
        let safeDuration = max(1.0, rawDuration.rounded(.down))
        guard let rawElapsed,
              rawElapsed.isFinite,
              !rawElapsed.isNaN else {
            return (nil, safeDuration)
        }
        let rate: Double = {
            if let rawPlaybackRate, rawPlaybackRate.isFinite, !rawPlaybackRate.isNaN {
                return max(0.0, rawPlaybackRate)
            }
            return isPlaying ? 1.0 : 0.0
        }()
        let advanced: Double
        if isPlaying, rate > 0, let timestamp {
            let delta = max(0.0, now.timeIntervalSince(timestamp)) * rate
            advanced = rawElapsed + delta
        } else {
            advanced = rawElapsed
        }
        let clampedElapsed = min(safeDuration, max(0.0, advanced)).rounded(.down)
        return (clampedElapsed, safeDuration)
    }

    private static func loadCFStringConstant(from handle: UnsafeMutableRawPointer, symbol: String) -> String? {
        guard let sym = dlsym(handle, symbol) else { return nil }
        let cfStrPtr = sym.assumingMemoryBound(to: CFString?.self)
        return cfStrPtr.pointee as String?
    }
}

// MARK: - Public macOS 13 AirPlay Receiver Discovery Monitor (NWBrowser + AVRouteDetector)

@MainActor
private final class MacAirPlayRouteMonitor {
    var onReceiversChanged: (() -> Void)?
    private(set) var currentBonjourReceivers: [MacDiscoveredAirPlayReceiver] = []

    private var raopBrowser: NWBrowser?
    private var airPlayBrowser: NWBrowser?
    private let routeDetector = AVRouteDetector()
    private var routeDetectorObserver: NSObjectProtocol?
    private var latestRAOPEntries: [MacAirPlayBonjourServiceEntry] = []
    private var latestAirPlayEntries: [MacAirPlayBonjourServiceEntry] = []
    private let localHardwareIDs: Set<String>

    init() {
        self.localHardwareIDs = Self.readLocalInterfaceMACIdentifiers()
    }

    func start() {
        stop()

        routeDetectorObserver = NotificationCenter.default.addObserver(
            forName: .AVRouteDetectorMultipleRoutesDetectedDidChange,
            object: routeDetector,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recomputeAndNotifyIfChanged(forceNotify: true)
            }
        }
        routeDetector.isRouteDetectionEnabled = true

        let raop = NWBrowser(for: .bonjourWithTXTRecord(type: "_raop._tcp", domain: nil), using: .tcp)
        raop.browseResultsChangedHandler = { [weak self] results, _ in
            let entries = Self.extractBonjourEntries(from: results, fallbackType: "_raop._tcp")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.latestRAOPEntries = entries
                self.recomputeAndNotifyIfChanged(forceNotify: false)
            }
        }
        raop.start(queue: .main)
        self.raopBrowser = raop

        let airPlay = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: .tcp)
        airPlay.browseResultsChangedHandler = { [weak self] results, _ in
            let entries = Self.extractBonjourEntries(from: results, fallbackType: "_airplay._tcp")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.latestAirPlayEntries = entries
                self.recomputeAndNotifyIfChanged(forceNotify: false)
            }
        }
        airPlay.start(queue: .main)
        self.airPlayBrowser = airPlay
    }

    func stop() {
        raopBrowser?.cancel()
        raopBrowser = nil
        airPlayBrowser?.cancel()
        airPlayBrowser = nil
        latestRAOPEntries.removeAll()
        latestAirPlayEntries.removeAll()

        routeDetector.isRouteDetectionEnabled = false
        if let routeDetectorObserver {
            NotificationCenter.default.removeObserver(routeDetectorObserver)
            self.routeDetectorObserver = nil
        }
    }

    private func recomputeAndNotifyIfChanged(forceNotify: Bool) {
        let combined = latestRAOPEntries + latestAirPlayEntries
        let parsed = MacAirPlayBonjourParser.parseReceivers(
            entries: combined,
            localHardwareIdentifiers: localHardwareIDs
        )
        if parsed != currentBonjourReceivers {
            currentBonjourReceivers = parsed
            onReceiversChanged?()
        } else if forceNotify {
            onReceiversChanged?()
        }
    }

    nonisolated private static func extractBonjourEntries(
        from results: Set<NWBrowser.Result>,
        fallbackType: String
    ) -> [MacAirPlayBonjourServiceEntry] {
        var entries: [MacAirPlayBonjourServiceEntry] = []
        entries.reserveCapacity(results.count)

        for result in results {
            guard case let .service(name, type, _, _) = result.endpoint else {
                continue
            }
            let txtDict: [String: String]
            if case let .bonjour(txt) = result.metadata {
                txtDict = txt.dictionary
            } else {
                txtDict = [:]
            }
            entries.append(
                MacAirPlayBonjourServiceEntry(
                    serviceName: name,
                    serviceType: type.isEmpty ? fallbackType : type,
                    txtRecord: txtDict
                )
            )
        }

        return entries
    }

    nonisolated static func readLocalInterfaceMACIdentifiers() -> Set<String> {
        var identifiers = Set<String>()
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return identifiers
        }
        defer { freeifaddrs(firstAddr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  Int32(addr.pointee.sa_family) == AF_LINK else {
                continue
            }
            let dl = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_dl.self).pointee
            let addrLen = Int(dl.sdl_alen)
            guard addrLen == 6 else { continue }
            let nameLen = Int(dl.sdl_nlen)
            let basePtr = UnsafeRawPointer(addr).advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)! + nameLen)
            let bytes = UnsafeBufferPointer(start: basePtr.assumingMemoryBound(to: UInt8.self), count: addrLen)
            if bytes.allSatisfy({ $0 == 0 }) {
                continue
            }
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            identifiers.insert(hex)
        }
        return identifiers
    }
}
