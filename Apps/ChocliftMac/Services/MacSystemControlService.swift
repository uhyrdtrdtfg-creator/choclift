import AppKit
import AudioToolbox
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

    // CoreAudio Process Object selectors (macOS 14+ runtime capability, safe FourCC constants on macOS 13 SDK)
    private static let selectorProcessObjectList: AudioObjectPropertySelector = 0x70727323 // 'prs#'
    private static let selectorProcessPID: AudioObjectPropertySelector = 0x70706964        // 'ppid'
    private static let selectorProcessIsRunningInput: AudioObjectPropertySelector = 0x70697269  // 'piri'
    private static let selectorProcessIsRunningOutput: AudioObjectPropertySelector = 0x7069726f // 'piro'

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
    private var latestMediaRemoteStatus: NowPlayingStatus?

    private let displayBridge = DisplayBrightnessBridge()
    private let mediaRemoteBridge = MediaRemoteBridge()

    public init() {
        self.currentState = ControlStripState()
        self.currentState = readSynchronousSnapshot(nowPlaying: nil)
    }

    public func start() {
        stop()
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
            mediaRemoteBridge.fetchNowPlaying { [weak self] mrStatus in
                guard let self else { return }
                self.latestMediaRemoteStatus = mrStatus
                let resolved = self.applyRefreshedSnapshot()
                completion?(resolved)
            }
        } else {
            let resolved = applyRefreshedSnapshot()
            completion?(resolved)
        }
    }

    public func schedulePostActionRefresh() {
        postActionRefreshTask?.cancel()
        postActionRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard let self, !Task.isCancelled else { return }
            self.refreshNow()
            try? await Task.sleep(for: .milliseconds(220))
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
        let audioSnapshot = Self.enumerateAudioOutputDevices(defaultOutputID: outDevice)
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

    public func setDefaultAudioOutputDevice(
        id: String,
        language: AppLanguage = .system
    ) -> (success: Bool, title: String, detail: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentOutID = Self.defaultAudioDevice(isInput: false)
        let snapshot = Self.enumerateAudioOutputDevices(defaultOutputID: currentOutID)

        guard snapshot.canSwitch else {
            _ = applyRefreshedSnapshot()
            return (
                false,
                L10n.tr("音频输出只读", "Audio Output Read-Only", language: language),
                L10n.tr(
                    "macOS 当前不允许通过公开 CoreAudio 接口切换默认输出设备。",
                    "macOS 13 reported the default output device as read-only via public CoreAudio API.",
                    language: language
                )
            )
        }

        guard let target = snapshot.devices.first(where: { $0.id == trimmed }) else {
            _ = applyRefreshedSnapshot()
            return (
                false,
                L10n.tr("音频输出", "Audio Output", language: language),
                L10n.tr("未找到该输出设备，可能已断开连接。", "That audio output device is no longer connected.", language: language)
            )
        }

        let targetObjectID = AudioObjectID(target.audioObjectID)
        if targetObjectID == currentOutID {
            _ = applyRefreshedSnapshot()
            return (
                true,
                target.name,
                L10n.tr("当前已是默认音频输出设备", "Already active as default audio output", language: language)
            )
        }

        var defaultOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableTarget = targetObjectID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutAddr,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &mutableTarget
        )

        rebindActiveAudioDeviceListeners()
        let refreshed = applyRefreshedSnapshot()
        let actualAfterID = Self.defaultAudioDevice(isInput: false)
        let didActuallySwitch = (status == noErr) && (actualAfterID == targetObjectID || refreshed.selectedAudioOutputDeviceID == target.id)

        if didActuallySwitch {
            schedulePostActionRefresh()
            return (
                true,
                target.name,
                L10n.tr("已切换 Mac 默认音频输出至 \(target.name)", "Switched Mac audio output to \(target.name)", language: language)
            )
        } else {
            return (
                false,
                target.name,
                L10n.tr(
                    "macOS 拒绝切换默认音频输出（状态码 \(status)）。",
                    "macOS could not switch default audio output (OSStatus \(status)).",
                    language: language
                )
            )
        }
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

    private static func isDeviceRunningAudio(deviceID: AudioObjectID) -> Bool {
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
        defaultOutputID: AudioObjectID
    ) -> (devices: [MacAudioOutputDevice], selectedID: String?, canSwitch: Bool) {
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        var defaultOutAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defaultSettable = isPropertySettable(deviceID: sysObj, address: &defaultOutAddr)

        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sysObj, &devicesAddr, 0, nil, &byteSize) == noErr,
              byteSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return ([], nil, false)
        }

        let count = Int(byteSize) / MemoryLayout<AudioObjectID>.size
        var rawIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sysObj, &devicesAddr, 0, nil, &byteSize, &rawIDs) == noErr else {
            return ([], nil, false)
        }

        var outputs: [MacAudioOutputDevice] = []
        var seenUIDs = Set<String>()
        var resolvedSelectedUID: String?

        for devID in rawIDs where devID != kAudioObjectUnknown {
            if devID != defaultOutputID && isAudioDeviceHidden(deviceID: devID) {
                continue
            }
            guard outputChannelCount(deviceID: devID) > 0 else { continue }

            let uid = readCFStringProperty(deviceID: devID, selector: kAudioDevicePropertyDeviceUID)
                ?? "audio-obj-\(devID)"
            guard !seenUIDs.contains(uid) else { continue }
            seenUIDs.insert(uid)

            let name = readCFStringProperty(deviceID: devID, selector: kAudioObjectPropertyName)
                ?? "Audio Output (\(devID))"
            let transport = readTransportKind(deviceID: devID)

            outputs.append(
                MacAudioOutputDevice(
                    id: uid,
                    audioObjectID: UInt32(devID),
                    name: name,
                    transportKind: transport
                )
            )

            if devID == defaultOutputID {
                resolvedSelectedUID = uid
            }
        }

        if resolvedSelectedUID == nil, defaultOutputID != kAudioObjectUnknown {
            resolvedSelectedUID = outputs.first(where: { $0.audioObjectID == UInt32(defaultOutputID) })?.id
        }

        let canSwitch = defaultSettable && !outputs.isEmpty
        return (outputs, resolvedSelectedUID, canSwitch)
    }

    private static func isAudioDeviceHidden(deviceID: AudioObjectID) -> Bool {
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

    private static func outputChannelCount(deviceID: AudioObjectID) -> Int {
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

    private static func readCFStringProperty(
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

    private static func readTransportKind(deviceID: AudioObjectID) -> MacAudioTransportKind {
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
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDevices
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
        let normalizedState = playerState.lowercased()
        if normalizedState == "stopped" || normalizedState.isEmpty {
            distributedTracks.removeValue(forKey: bundleID)
        } else {
            let playing = (normalizedState == "playing")
            let status = NowPlayingStatus(
                title: title,
                artist: artist,
                appName: appName,
                isPlaying: playing,
                elapsedSeconds: elapsedSeconds,
                durationSeconds: durationSeconds
            )
            if status.hasActiveMedia {
                distributedTracks[bundleID] = CachedDistributedTrack(
                    bundleIdentifier: bundleID,
                    status: status,
                    updatedAt: Date()
                )
            } else {
                distributedTracks.removeValue(forKey: bundleID)
            }
        }
        applyRefreshedSnapshot()
    }

    private func resolveBestNowPlaying() -> NowPlayingStatus? {
        // 1. Prune distributed player entries for apps that have quit
        for (bundleID, _) in distributedTracks {
            let isAlive = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains(where: { !$0.isTerminated })
            if !isAlive {
                distributedTracks.removeValue(forKey: bundleID)
            }
        }

        // 2. Actively playing MediaRemote session
        if let mr = latestMediaRemoteStatus, mr.hasActiveMedia, mr.isPlaying {
            return mr
        }

        // 3. Actively playing Music / Spotify session from DistributedNotificationCenter
        let sortedDistributed = distributedTracks.values.sorted { $0.updatedAt > $1.updatedAt }
        if let playingDist = sortedDistributed.first(where: { $0.status.isPlaying && $0.status.hasActiveMedia }) {
            return playingDist.status
        }

        // 4. CoreAudio active audio-output process fallback (gives exact app name when MediaRemote metadata is restricted)
        let outDevice = Self.defaultAudioDevice(isInput: false)
        if Self.isDeviceRunningAudio(deviceID: outDevice),
           let activeAudioAppName = Self.findActiveAudioOutputAppName() {
            return NowPlayingStatus(
                title: nil,
                artist: nil,
                appName: activeAudioAppName,
                isPlaying: true
            )
        }

        // 5. Paused session with track metadata so the user can see what is paused and tap Play
        if let mr = latestMediaRemoteStatus, mr.hasActiveMedia {
            return mr
        }
        if let pausedDist = sortedDistributed.first(where: { $0.status.hasActiveMedia }) {
            return pausedDist.status
        }

        return nil
    }

    private static func findActiveAudioOutputAppName() -> String? {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: selectorProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteSize: UInt32 = 0
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sysObj, &listAddr, 0, nil, &byteSize) == noErr,
              byteSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return nil
        }

        let count = Int(byteSize) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sysObj, &listAddr, 0, nil, &byteSize, &objects) == noErr else {
            return nil
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        var fallbackAppName: String?

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

            if let resolved = resolveUserFacingAppName(forPID: pid) {
                if resolved.isRegularApp {
                    return resolved.name
                }
                if fallbackAppName == nil {
                    fallbackAppName = resolved.name
                }
            }
        }

        return fallbackAppName
    }

    private static func resolveUserFacingAppName(forPID pid: pid_t) -> (name: String, isRegularApp: Bool)? {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return nil
        }

        if app.activationPolicy == .regular,
           let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return (name, true)
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
                    return (parentName, true)
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
                return (safariName, true)
            }
        }

        return nil
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

    func fetchNowPlaying(completion: @escaping @MainActor (NowPlayingStatus?) -> Void) {
        guard let getInfoFn, let getIsPlayingFn else {
            Task { @MainActor in completion(nil) }
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
                        let appName: String? = (pid > 0)
                            ? NSRunningApplication(processIdentifier: pid)?.localizedName
                            : nil
                        let status = NowPlayingStatus(
                            title: title,
                            artist: artist,
                            appName: appName,
                            isPlaying: isPlaying,
                            elapsedSeconds: timing.elapsedSeconds,
                            durationSeconds: timing.durationSeconds
                        )
                        Task { @MainActor in
                            completion(status.hasActiveMedia ? status : nil)
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
                    Task { @MainActor in
                        completion(status.hasActiveMedia ? status : nil)
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
