import AppKit
import AudioToolbox
import ChocliftCore
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.graphics

@MainActor
public final class MacSystemControlService {
    public var onStateChanged: ((ControlStripState) -> Void)?
    public var canUndoWindowMoveProvider: (() -> Bool)?
    public var displayTopologyProvider: (() -> (displays: [MacDisplayInfo], selectedDisplayID: UInt32?))?
    public var soundboardVolumeProvider: (() -> Double)?
    public var keepMacAwakeProvider: (() -> Bool)?
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
    private static let selectorProcessIsRunningOutput: AudioObjectPropertySelector = 0x7069726f // 'piro'

    private let listenerQueue = DispatchQueue.main
    private var systemAudioListeners: [RegisteredAudioListener] = []
    private var deviceAudioListeners: [RegisteredAudioListener] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var localObservers: [NSObjectProtocol] = []
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
            canSwitchAudioOutput: audioSnapshot.canSwitch
        )
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
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.ingestDistributedPlayerUpdate(
                        bundleID: source.bundleID,
                        appName: source.appName,
                        playerState: state,
                        title: title,
                        artist: artist
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
        artist: String?
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
                isPlaying: playing
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

        getInfoFn(.main) { [titleKey, artistKey, getPIDFn] rawInfo in
            let title = rawInfo?[titleKey] as? String
            let artist = rawInfo?[artistKey] as? String

            getIsPlayingFn(.main) { isPlaying in
                if let getPIDFn {
                    getPIDFn(.main) { pid in
                        let appName: String? = (pid > 0)
                            ? NSRunningApplication(processIdentifier: pid)?.localizedName
                            : nil
                        let status = NowPlayingStatus(
                            title: title,
                            artist: artist,
                            appName: appName,
                            isPlaying: isPlaying
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
                        isPlaying: isPlaying
                    )
                    Task { @MainActor in
                        completion(status.hasActiveMedia ? status : nil)
                    }
                }
            }
        }
    }

    private static func loadCFStringConstant(from handle: UnsafeMutableRawPointer, symbol: String) -> String? {
        guard let sym = dlsym(handle, symbol) else { return nil }
        let cfStrPtr = sym.assumingMemoryBound(to: CFString?.self)
        return cfStrPtr.pointee as String?
    }
}
