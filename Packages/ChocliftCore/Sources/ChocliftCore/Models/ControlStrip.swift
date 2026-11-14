import Foundation

// MARK: - Control Strip Level Kind & Clamping

public enum ControlLevelKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case volume
    case brightness

    public var id: String { rawValue }
}

public enum ControlStripLevel {
    /// Clamps any raw floating-point level to `0.0...1.0` (`NaN` maps safely to `0.0`).
    public static func clamp(_ rawValue: Double) -> Double {
        guard !rawValue.isNaN else { return 0.0 }
        return min(1.0, max(0.0, rawValue))
    }

    /// Rounded integer percentage (`0...100`) for display.
    public static func percentage(for level: Double) -> Int {
        Int((clamp(level) * 100.0).rounded())
    }
}

// MARK: - Pure Drag Throttle (<= 1 update / 150 ms during drag + guaranteed final level on end)

public struct ControlLevelDragThrottle: Equatable, Sendable {
    public static let defaultMinimumInterval: TimeInterval = 0.15

    public let minimumInterval: TimeInterval
    public private(set) var isDragging: Bool = false
    public private(set) var lastSentTimestamp: TimeInterval?
    public private(set) var lastSentLevel: Double?
    public private(set) var latestDragLevel: Double?

    public init(minimumInterval: TimeInterval = ControlLevelDragThrottle.defaultMinimumInterval) {
        self.minimumInterval = max(0.0, minimumInterval)
    }

    /// Records an in-progress drag update and returns the clamped level to send if at least
    /// `minimumInterval` (150 ms by default) has elapsed since the previous sent update.
    public mutating func updateDrag(to rawLevel: Double, at timestamp: TimeInterval) -> Double? {
        let clamped = ControlStripLevel.clamp(rawLevel)
        isDragging = true
        latestDragLevel = clamped

        if let lastSent = lastSentTimestamp {
            let elapsed = timestamp - lastSent
            if elapsed + 1e-9 < minimumInterval {
                return nil
            }
        }

        lastSentTimestamp = timestamp
        lastSentLevel = clamped
        return clamped
    }

    /// Ends the current drag and unconditionally returns the final clamped level so the Mac
    /// always converges to the exact release position.
    public mutating func endDrag(at rawLevel: Double, at timestamp: TimeInterval) -> Double {
        let clamped = ControlStripLevel.clamp(rawLevel)
        isDragging = false
        latestDragLevel = nil
        lastSentTimestamp = timestamp
        lastSentLevel = clamped
        return clamped
    }

    public mutating func reset() {
        isDragging = false
        latestDragLevel = nil
        lastSentTimestamp = nil
        lastSentLevel = nil
    }
}

// MARK: - Now Playing & Control Strip Snapshot

public struct NowPlayingStatus: Codable, Equatable, Hashable, Sendable {
    public var title: String?
    public var artist: String?
    public var appName: String?
    public var isPlaying: Bool
    /// System-reported playback elapsed time in seconds (`nil` when unavailable).
    public var elapsedSeconds: Double?
    /// System-reported track duration in seconds (`nil` when missing or non-positive).
    public var durationSeconds: Double?
    /// Bundle identifier of the active Now Playing application when known (`com.spotify.client`, `com.apple.Music`, etc.).
    public var bundleIdentifier: String?

    private enum CodingKeys: String, CodingKey {
        case title
        case artist
        case appName
        case isPlaying
        case elapsedSeconds
        case durationSeconds
        case bundleIdentifier
    }

    public init(
        title: String? = nil,
        artist: String? = nil,
        appName: String? = nil,
        isPlaying: Bool = false,
        elapsedSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        bundleIdentifier: String? = nil
    ) {
        self.title = Self.clean(title)
        self.artist = Self.clean(artist)
        self.appName = Self.clean(appName)
        self.isPlaying = isPlaying
        let validDuration = Self.cleanDuration(durationSeconds)
        self.durationSeconds = validDuration
        self.elapsedSeconds = Self.cleanElapsed(elapsedSeconds, cappedBy: validDuration)
        self.bundleIdentifier = Self.clean(bundleIdentifier)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = Self.clean(try container.decodeIfPresent(String.self, forKey: .title))
        self.artist = Self.clean(try container.decodeIfPresent(String.self, forKey: .artist))
        self.appName = Self.clean(try container.decodeIfPresent(String.self, forKey: .appName))
        self.isPlaying = try container.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        let rawDuration = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        let rawElapsed = try container.decodeIfPresent(Double.self, forKey: .elapsedSeconds)
        let validDuration = Self.cleanDuration(rawDuration)
        self.durationSeconds = validDuration
        self.elapsedSeconds = Self.cleanElapsed(rawElapsed, cappedBy: validDuration)
        self.bundleIdentifier = Self.clean(try container.decodeIfPresent(String.self, forKey: .bundleIdentifier))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(artist, forKey: .artist)
        try container.encodeIfPresent(appName, forKey: .appName)
        try container.encode(isPlaying, forKey: .isPlaying)
        let validDuration = Self.cleanDuration(durationSeconds)
        let validElapsed = Self.cleanElapsed(elapsedSeconds, cappedBy: validDuration)
        try container.encodeIfPresent(validElapsed, forKey: .elapsedSeconds)
        try container.encodeIfPresent(validDuration, forKey: .durationSeconds)
        try container.encodeIfPresent(Self.clean(bundleIdentifier), forKey: .bundleIdentifier)
    }

    /// Track title if available, otherwise the active media app name.
    public var primaryDisplayText: String? {
        if let title, !title.isEmpty {
            return title
        }
        if let appName, !appName.isEmpty {
            return appName
        }
        return nil
    }

    /// Artist or app name subtitle when a distinct track title is displayed.
    public var secondaryDisplayText: String? {
        guard let title, !title.isEmpty else { return nil }
        if let artist, !artist.isEmpty {
            return artist
        }
        if let appName, !appName.isEmpty, appName != title {
            return appName
        }
        return nil
    }

    /// Read-only `"elapsed / duration"` string when both `elapsedSeconds` and `durationSeconds` (`> 0`)
    /// are provided by macOS; `nil` whenever duration is missing so the Now Playing row shows title only.
    public var formattedProgressText: String? {
        NowPlayingProgressFormatter.formattedProgress(
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds
        )
    }

    /// True ONLY when `durationSeconds` is present (`> 0` and finite) AND the current Now Playing
    /// app supports background playback position seeking on macOS 13 (`Spotify` or `Music`).
    public var isSeekable: Bool {
        guard let validDuration = Self.cleanDuration(durationSeconds),
              validDuration > 0,
              let cleanedBundle = Self.clean(bundleIdentifier) else {
            return false
        }
        return MacMediaSeekRouter.isSupportedSeekBundleIdentifier(cleanedBundle)
    }

    /// Normalized `0.0...1.0` playback fraction when `durationSeconds` is present (`> 0`); `nil` when duration is missing.
    public var progressFraction: Double? {
        guard let validDuration = Self.cleanDuration(durationSeconds),
              validDuration > 0 else {
            return nil
        }
        let validElapsed = Self.cleanElapsed(elapsedSeconds, cappedBy: validDuration) ?? 0.0
        return ControlStripLevel.clamp(validElapsed / validDuration)
    }

    public var hasActiveMedia: Bool {
        primaryDisplayText != nil
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func cleanDuration(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, !raw.isNaN, raw > 0 else {
            return nil
        }
        return raw
    }

    private static func cleanElapsed(_ raw: Double?, cappedBy duration: Double?) -> Double? {
        guard let raw, raw.isFinite, !raw.isNaN else {
            return nil
        }
        let nonNegative = max(0.0, raw)
        if let duration {
            return min(nonNegative, duration)
        }
        return nonNegative
    }
}

/// Pure, unit-testable playback scrub state machine that tracks local preview position while dragging
/// (sending zero network/player commands per pixel) and emits a single clamped position on finger release.
public struct NowPlayingScrubController: Equatable, Sendable {
    public private(set) var isScrubbing: Bool = false
    public private(set) var previewPositionSeconds: Double?
    public private(set) var scrubbedTrackTitle: String?
    public private(set) var scrubbedBundleIdentifier: String?

    public init() {}

    /// Updates local preview position from a normalized `0.0...1.0` drag fraction without emitting a seek command.
    @discardableResult
    public mutating func updateDrag(
        normalizedProgress: Double,
        for status: NowPlayingStatus?
    ) -> Double? {
        guard let status,
              status.isSeekable,
              let duration = status.durationSeconds,
              duration > 0 else {
            cancel()
            return nil
        }
        let clampedFraction = ControlStripLevel.clamp(normalizedProgress)
        return updateDrag(toPositionSeconds: clampedFraction * duration, for: status)
    }

    /// Updates local preview position in absolute seconds (`0...duration`) without emitting a seek command.
    @discardableResult
    public mutating func updateDrag(
        toPositionSeconds rawSeconds: Double,
        for status: NowPlayingStatus?
    ) -> Double? {
        guard let status,
              status.isSeekable,
              let duration = status.durationSeconds,
              duration > 0 else {
            cancel()
            return nil
        }
        let clamped = MacMediaSeekRouter.clampPosition(rawSeconds, durationSeconds: duration)
        isScrubbing = true
        previewPositionSeconds = clamped
        scrubbedTrackTitle = status.primaryDisplayText
        scrubbedBundleIdentifier = status.bundleIdentifier
        return clamped
    }

    /// Completes a scrub gesture from a normalized `0.0...1.0` release fraction and returns the single
    /// clamped seek position (`0...duration`) to send once when the finger lifts.
    public mutating func endDrag(
        normalizedProgress: Double,
        for status: NowPlayingStatus?
    ) -> Double? {
        defer { cancel() }
        guard let status,
              status.isSeekable,
              let duration = status.durationSeconds,
              duration > 0 else {
            return nil
        }
        let clampedFraction = ControlStripLevel.clamp(normalizedProgress)
        return MacMediaSeekRouter.clampPosition(clampedFraction * duration, durationSeconds: duration)
    }

    /// Completes a scrub gesture at an absolute release position and returns the single clamped
    /// seek position (`0...duration`) to send once when the finger lifts.
    public mutating func endDrag(
        atPositionSeconds rawSeconds: Double,
        for status: NowPlayingStatus?
    ) -> Double? {
        defer { cancel() }
        guard let status,
              status.isSeekable,
              let duration = status.durationSeconds,
              duration > 0 else {
            return nil
        }
        return MacMediaSeekRouter.clampPosition(rawSeconds, durationSeconds: duration)
    }

    /// Keeps in-progress local drag preview stable across periodic status refreshes of the same seekable track,
    /// and cancels immediately if the player stops, switches tracks/apps, or loses duration.
    public mutating func reconcile(with status: NowPlayingStatus?) {
        guard isScrubbing else { return }
        guard let status,
              status.isSeekable,
              let duration = status.durationSeconds,
              duration > 0 else {
            cancel()
            return
        }
        if let scrubbedBundleIdentifier,
           let incomingBundle = status.bundleIdentifier,
           scrubbedBundleIdentifier.caseInsensitiveCompare(incomingBundle) != .orderedSame {
            cancel()
            return
        }
        if let scrubbedTrackTitle,
           let incomingTitle = status.primaryDisplayText,
           scrubbedTrackTitle != incomingTitle {
            cancel()
            return
        }
        if let currentPreview = previewPositionSeconds {
            previewPositionSeconds = MacMediaSeekRouter.clampPosition(currentPreview, durationSeconds: duration)
        }
    }

    public mutating func cancel() {
        isScrubbing = false
        previewPositionSeconds = nil
        scrubbedTrackTitle = nil
        scrubbedBundleIdentifier = nil
    }

    public func effectiveElapsedSeconds(for status: NowPlayingStatus?) -> Double? {
        guard let status else { return nil }
        if isScrubbing,
           status.isSeekable,
           let previewPositionSeconds,
           let duration = status.durationSeconds,
           duration > 0 {
            return MacMediaSeekRouter.clampPosition(previewPositionSeconds, durationSeconds: duration)
        }
        return status.elapsedSeconds
    }

    public func effectiveProgressFraction(for status: NowPlayingStatus?) -> Double? {
        guard let status,
              let duration = status.durationSeconds,
              duration > 0 else {
            return nil
        }
        let elapsed = effectiveElapsedSeconds(for: status) ?? 0.0
        return ControlStripLevel.clamp(elapsed / duration)
    }
}

public struct ControlStripState: Codable, Equatable, Hashable, Sendable {
    public var volume: Double
    public var isVolumeMuted: Bool
    public var brightness: Double
    public var isBrightnessAvailable: Bool
    public var isMicMuted: Bool
    public var nowPlaying: NowPlayingStatus?
    public var canUndoWindowMove: Bool
    public var connectedDisplays: [MacDisplayInfo]
    public var selectedTargetDisplayID: UInt32?
    /// Soundboard-only playback level on Mac speakers (`0.0 ... 1.0`), independent of system hardware volume.
    public var soundboardVolume: Double
    /// True while the Mac is holding an active `IOPMAssertion` preventing idle system sleep for connected companions.
    public var isKeepMacAwakeEnabled: Bool
    /// Current Mac audio output devices enumerated via public CoreAudio APIs.
    public var audioOutputDevices: [MacAudioOutputDevice]
    /// UID of the Mac's current default audio output device, if reported by CoreAudio.
    public var selectedAudioOutputDeviceID: String?
    /// True when CoreAudio reports `kAudioHardwarePropertyDefaultOutputDevice` as settable on this Mac.
    public var canSwitchAudioOutput: Bool
    /// Read-only Mac battery percentage/charging state or AC power-adapter state (`nil` before first Mac sync).
    public var macBattery: MacBatteryStatus?
    /// True when Finder's `CreateDesktop` preference is enabled so desktop icons are shown on the Mac.
    public var areFinderDesktopIconsVisible: Bool
    /// Read-only Mac camera/microphone active capture status and app names when exposed by macOS.
    public var privacyCapture: MacPrivacyCaptureStatus
    /// Current Mac Wi-Fi SSID only (`nil` when unavailable; formatted as `"Wi-Fi"` with no name).
    public var wifiSSID: String?
    /// Count of mounted external volumes eligible for ejection (excludes startup and fixed internal volumes).
    public var ejectableExternalVolumeCount: Int
    /// Read-only display name of the frontmost Mac app (`nil` before sync or when none).
    public var frontmostAppName: String?

    private enum CodingKeys: String, CodingKey {
        case volume
        case isVolumeMuted
        case brightness
        case isBrightnessAvailable
        case isMicMuted
        case nowPlaying
        case canUndoWindowMove
        case connectedDisplays
        case selectedTargetDisplayID
        case soundboardVolume
        case isKeepMacAwakeEnabled
        case audioOutputDevices
        case selectedAudioOutputDeviceID
        case canSwitchAudioOutput
        case macBattery
        case areFinderDesktopIconsVisible
        case privacyCapture
        case wifiSSID
        case ejectableExternalVolumeCount
        case frontmostAppName
    }

    public init(
        volume: Double = 0.5,
        isVolumeMuted: Bool = false,
        brightness: Double = 0.75,
        isBrightnessAvailable: Bool = true,
        isMicMuted: Bool = false,
        nowPlaying: NowPlayingStatus? = nil,
        canUndoWindowMove: Bool = false,
        connectedDisplays: [MacDisplayInfo] = [],
        selectedTargetDisplayID: UInt32? = nil,
        soundboardVolume: Double = SoundboardClip.defaultVolume,
        isKeepMacAwakeEnabled: Bool = false,
        audioOutputDevices: [MacAudioOutputDevice] = [],
        selectedAudioOutputDeviceID: String? = nil,
        canSwitchAudioOutput: Bool = true,
        macBattery: MacBatteryStatus? = nil,
        areFinderDesktopIconsVisible: Bool = true,
        privacyCapture: MacPrivacyCaptureStatus = .inactive,
        wifiSSID: String? = nil,
        ejectableExternalVolumeCount: Int = 0,
        frontmostAppName: String? = nil
    ) {
        self.volume = ControlStripLevel.clamp(volume)
        self.isVolumeMuted = isVolumeMuted
        self.brightness = ControlStripLevel.clamp(brightness)
        self.isBrightnessAvailable = isBrightnessAvailable
        self.isMicMuted = isMicMuted
        self.nowPlaying = (nowPlaying?.hasActiveMedia == true) ? nowPlaying : nil
        self.canUndoWindowMove = canUndoWindowMove
        self.connectedDisplays = connectedDisplays
        self.selectedTargetDisplayID = DisplaySnapTargetResolver.resolvedTargetDisplayID(
            selectedDisplayID: selectedTargetDisplayID,
            connectedDisplays: connectedDisplays
        )
        self.soundboardVolume = ControlStripLevel.clamp(soundboardVolume)
        self.isKeepMacAwakeEnabled = isKeepMacAwakeEnabled
        self.audioOutputDevices = audioOutputDevices
        self.selectedAudioOutputDeviceID = Self.resolvedSelectedAudioOutputDeviceID(
            selectedID: selectedAudioOutputDeviceID,
            devices: audioOutputDevices
        )
        self.canSwitchAudioOutput = canSwitchAudioOutput
        self.macBattery = macBattery
        self.areFinderDesktopIconsVisible = areFinderDesktopIconsVisible
        self.privacyCapture = privacyCapture
        self.wifiSSID = MacWiFiStatusFormatter.sanitizedSSID(wifiSSID)
        self.ejectableExternalVolumeCount = max(0, ejectableExternalVolumeCount)
        self.frontmostAppName = FrontmostAppStripFormatter.sanitizedAppName(frontmostAppName)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVolume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.5
        let decodedBrightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0.75
        let decodedSBVolume = try container.decodeIfPresent(Double.self, forKey: .soundboardVolume) ?? SoundboardClip.defaultVolume
        self.volume = ControlStripLevel.clamp(decodedVolume)
        self.isVolumeMuted = try container.decodeIfPresent(Bool.self, forKey: .isVolumeMuted) ?? false
        self.brightness = ControlStripLevel.clamp(decodedBrightness)
        self.isBrightnessAvailable = try container.decodeIfPresent(Bool.self, forKey: .isBrightnessAvailable) ?? true
        self.isMicMuted = try container.decodeIfPresent(Bool.self, forKey: .isMicMuted) ?? false
        let decodedNP = try container.decodeIfPresent(NowPlayingStatus.self, forKey: .nowPlaying)
        self.nowPlaying = (decodedNP?.hasActiveMedia == true) ? decodedNP : nil
        self.canUndoWindowMove = try container.decodeIfPresent(Bool.self, forKey: .canUndoWindowMove) ?? false
        let displays = try container.decodeIfPresent([MacDisplayInfo].self, forKey: .connectedDisplays) ?? []
        let rawSelectedID = try container.decodeIfPresent(UInt32.self, forKey: .selectedTargetDisplayID)
        self.connectedDisplays = displays
        self.selectedTargetDisplayID = DisplaySnapTargetResolver.resolvedTargetDisplayID(
            selectedDisplayID: rawSelectedID,
            connectedDisplays: displays
        )
        self.soundboardVolume = ControlStripLevel.clamp(decodedSBVolume)
        self.isKeepMacAwakeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isKeepMacAwakeEnabled) ?? false
        let decodedAudioDevices = try container.decodeIfPresent([MacAudioOutputDevice].self, forKey: .audioOutputDevices) ?? []
        let rawAudioSelectedID = try container.decodeIfPresent(String.self, forKey: .selectedAudioOutputDeviceID)
        self.audioOutputDevices = decodedAudioDevices
        self.selectedAudioOutputDeviceID = Self.resolvedSelectedAudioOutputDeviceID(
            selectedID: rawAudioSelectedID,
            devices: decodedAudioDevices
        )
        self.canSwitchAudioOutput = try container.decodeIfPresent(Bool.self, forKey: .canSwitchAudioOutput) ?? true
        self.macBattery = try container.decodeIfPresent(MacBatteryStatus.self, forKey: .macBattery)
        self.areFinderDesktopIconsVisible = try container.decodeIfPresent(Bool.self, forKey: .areFinderDesktopIconsVisible) ?? true
        self.privacyCapture = try container.decodeIfPresent(MacPrivacyCaptureStatus.self, forKey: .privacyCapture) ?? .inactive
        self.wifiSSID = MacWiFiStatusFormatter.sanitizedSSID(
            try container.decodeIfPresent(String.self, forKey: .wifiSSID)
        )
        let rawEjectableCount = try container.decodeIfPresent(Int.self, forKey: .ejectableExternalVolumeCount) ?? 0
        self.ejectableExternalVolumeCount = max(0, rawEjectableCount)
        self.frontmostAppName = FrontmostAppStripFormatter.sanitizedAppName(
            try container.decodeIfPresent(String.self, forKey: .frontmostAppName)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ControlStripLevel.clamp(volume), forKey: .volume)
        try container.encode(isVolumeMuted, forKey: .isVolumeMuted)
        try container.encode(ControlStripLevel.clamp(brightness), forKey: .brightness)
        try container.encode(isBrightnessAvailable, forKey: .isBrightnessAvailable)
        try container.encode(isMicMuted, forKey: .isMicMuted)
        try container.encodeIfPresent(nowPlaying, forKey: .nowPlaying)
        try container.encode(canUndoWindowMove, forKey: .canUndoWindowMove)
        if !connectedDisplays.isEmpty {
            try container.encode(connectedDisplays, forKey: .connectedDisplays)
        }
        let resolvedSelected = DisplaySnapTargetResolver.resolvedTargetDisplayID(
            selectedDisplayID: selectedTargetDisplayID,
            connectedDisplays: connectedDisplays
        )
        try container.encodeIfPresent(resolvedSelected, forKey: .selectedTargetDisplayID)
        try container.encode(ControlStripLevel.clamp(soundboardVolume), forKey: .soundboardVolume)
        try container.encode(isKeepMacAwakeEnabled, forKey: .isKeepMacAwakeEnabled)
        if !audioOutputDevices.isEmpty {
            try container.encode(audioOutputDevices, forKey: .audioOutputDevices)
        }
        let resolvedAudioSelectedID = Self.resolvedSelectedAudioOutputDeviceID(
            selectedID: selectedAudioOutputDeviceID,
            devices: audioOutputDevices
        )
        try container.encodeIfPresent(resolvedAudioSelectedID, forKey: .selectedAudioOutputDeviceID)
        try container.encode(canSwitchAudioOutput, forKey: .canSwitchAudioOutput)
        try container.encodeIfPresent(macBattery, forKey: .macBattery)
        try container.encode(areFinderDesktopIconsVisible, forKey: .areFinderDesktopIconsVisible)
        if privacyCapture != .inactive {
            try container.encode(privacyCapture, forKey: .privacyCapture)
        }
        try container.encodeIfPresent(MacWiFiStatusFormatter.sanitizedSSID(wifiSSID), forKey: .wifiSSID)
        if ejectableExternalVolumeCount > 0 {
            try container.encode(max(0, ejectableExternalVolumeCount), forKey: .ejectableExternalVolumeCount)
        }
        try container.encodeIfPresent(FrontmostAppStripFormatter.sanitizedAppName(frontmostAppName), forKey: .frontmostAppName)
    }

    /// Current Wi-Fi SSID string, or `"Wi-Fi"` with no network name when unavailable.
    public var wifiDisplayLabel: String {
        MacWiFiStatusFormatter.displayText(ssid: wifiSSID)
    }

    /// True when at least one eligible external volume is mounted on the Mac.
    public var hasEjectableExternalDisks: Bool {
        ejectableExternalVolumeCount > 0
    }

    /// Explicit reason line shown on the companion strip ONLY while Choclift's keep-awake assertion is on (`nil` when off).
    public func awakeReasonLine(in language: AppLanguage = .system) -> String? {
        MacAwakeReasonFormatter.reasonLine(
            isAssertionActive: isKeepMacAwakeEnabled,
            language: language
        )
    }

    public var currentAudioOutputDevice: MacAudioOutputDevice? {
        guard let selectedID = Self.resolvedSelectedAudioOutputDeviceID(
            selectedID: selectedAudioOutputDeviceID,
            devices: audioOutputDevices
        ) else {
            return nil
        }
        return audioOutputDevices.first(where: { $0.id == selectedID })
    }

    public func currentAudioOutputLabel(in language: AppLanguage = .system) -> String {
        if let device = currentAudioOutputDevice {
            return device.name
        }
        return L10n.tr("系统音频输出", "System Output", language: language)
    }

    public static func resolvedSelectedAudioOutputDeviceID(
        selectedID: String?,
        devices: [MacAudioOutputDevice]
    ) -> String? {
        guard let cleaned = cleanAudioID(selectedID),
              devices.contains(where: { $0.id == cleaned }) else {
            return nil
        }
        return cleaned
    }

    private static func cleanAudioID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    public var shouldShowDisplayPicker: Bool {
        DisplaySnapTargetResolver.shouldShowPicker(for: connectedDisplays)
    }

    public var effectiveTargetDisplayID: UInt32? {
        DisplaySnapTargetResolver.resolvedTargetDisplayID(
            selectedDisplayID: selectedTargetDisplayID,
            connectedDisplays: connectedDisplays
        )
    }

    public func selectedDisplayLabel(in language: AppLanguage = .system) -> String {
        if let targetID = effectiveTargetDisplayID,
           let matched = connectedDisplays.first(where: { $0.displayID == targetID }) {
            return matched.name
        }
        return L10n.tr("当前窗口屏幕", "Active Window Display", language: language)
    }

    public func hasMeaningfulDifference(from other: ControlStripState, tolerance: Double = 0.004) -> Bool {
        if isVolumeMuted != other.isVolumeMuted ||
            isBrightnessAvailable != other.isBrightnessAvailable ||
            isMicMuted != other.isMicMuted ||
            nowPlaying != other.nowPlaying ||
            canUndoWindowMove != other.canUndoWindowMove ||
            connectedDisplays != other.connectedDisplays ||
            effectiveTargetDisplayID != other.effectiveTargetDisplayID ||
            isKeepMacAwakeEnabled != other.isKeepMacAwakeEnabled ||
            audioOutputDevices != other.audioOutputDevices ||
            Self.resolvedSelectedAudioOutputDeviceID(selectedID: selectedAudioOutputDeviceID, devices: audioOutputDevices) !=
                Self.resolvedSelectedAudioOutputDeviceID(selectedID: other.selectedAudioOutputDeviceID, devices: other.audioOutputDevices) ||
            canSwitchAudioOutput != other.canSwitchAudioOutput ||
            macBattery != other.macBattery ||
            areFinderDesktopIconsVisible != other.areFinderDesktopIconsVisible ||
            privacyCapture != other.privacyCapture ||
            MacWiFiStatusFormatter.sanitizedSSID(wifiSSID) != MacWiFiStatusFormatter.sanitizedSSID(other.wifiSSID) ||
            max(0, ejectableExternalVolumeCount) != max(0, other.ejectableExternalVolumeCount) ||
            FrontmostAppStripFormatter.sanitizedAppName(frontmostAppName) != FrontmostAppStripFormatter.sanitizedAppName(other.frontmostAppName) {
            return true
        }
        if (volume <= 0.001) != (other.volume <= 0.001) ||
            (volume >= 0.999) != (other.volume >= 0.999) ||
            (brightness <= 0.001) != (other.brightness <= 0.001) ||
            (brightness >= 0.999) != (other.brightness >= 0.999) ||
            (soundboardVolume <= 0.001) != (other.soundboardVolume <= 0.001) ||
            (soundboardVolume >= 0.999) != (other.soundboardVolume >= 0.999) {
            return true
        }
        return abs(volume - other.volume) >= tolerance ||
            abs(brightness - other.brightness) >= tolerance ||
            abs(soundboardVolume - other.soundboardVolume) >= tolerance
    }
}

// MARK: - Media Transport Command Router (Spotify / Now Playing / HID Media Key)

public enum MacMediaTransportCommand: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case playPause
    case nextTrack
    case previousTrack

    public init?(systemAction: SystemQuickAction) {
        switch systemAction {
        case .mediaPlayPause:
            self = .playPause
        case .mediaNext:
            self = .nextTrack
        case .mediaPrevious:
            self = .previousTrack
        default:
            return nil
        }
    }

    public var spotifyScriptVerb: String {
        switch self {
        case .playPause:
            return "playpause"
        case .nextTrack:
            return "next track"
        case .previousTrack:
            return "previous track"
        }
    }

    public var musicScriptVerb: String {
        switch self {
        case .playPause:
            return "playpause"
        case .nextTrack:
            return "next track"
        case .previousTrack:
            return "previous track"
        }
    }

    /// `NX_KEYTYPE_PLAY` (16), `NX_KEYTYPE_NEXT` (17), `NX_KEYTYPE_PREVIOUS` (18).
    public var hidMediaKeyType: Int {
        switch self {
        case .playPause:
            return 16
        case .nextTrack:
            return 17
        case .previousTrack:
            return 18
        }
    }

    public func successMessage(in language: AppLanguage = .system) -> String {
        switch self {
        case .playPause:
            return L10n.tr("播放 / 暂停", "Media Play / Pause", language: language)
        case .nextTrack:
            return L10n.tr("已切至下一曲", "Skipped to Next Track", language: language)
        case .previousTrack:
            return L10n.tr("已切至上一曲", "Returned to Previous Track", language: language)
        }
    }
}

public enum MacMediaTransportFailureReason: String, Codable, Equatable, Hashable, Sendable {
    case noActiveMediaPlayer
    case spotifyNotRunning

    public func message(in language: AppLanguage = .system) -> String {
        switch self {
        case .noActiveMediaPlayer:
            return L10n.tr(
                "当前没有正在运行或播放的媒体应用",
                "No media player is currently running or playing",
                language: language
            )
        case .spotifyNotRunning:
            return L10n.tr(
                "Spotify 当前未运行，且没有其他正在播放的媒体应用",
                "Spotify is not running and no other media player is active",
                language: language
            )
        }
    }
}

public enum MacMediaTransportRoute: Equatable, Hashable, Sendable {
    case spotifyScript
    case mediaKey
    case failure(MacMediaTransportFailureReason)
}

public struct MacMediaTransportContext: Equatable, Hashable, Sendable {
    public var nowPlayingBundleID: String?
    public var isNowPlayingPlaying: Bool
    public var isSpotifyRunning: Bool
    public var isSpotifyPlaying: Bool
    public var frontmostBundleID: String?
    public var hasOtherActiveMediaClient: Bool

    public init(
        nowPlayingBundleID: String? = nil,
        isNowPlayingPlaying: Bool = true,
        isSpotifyRunning: Bool = false,
        isSpotifyPlaying: Bool = false,
        frontmostBundleID: String? = nil,
        hasOtherActiveMediaClient: Bool = false
    ) {
        self.nowPlayingBundleID = Self.normalizedBundleID(nowPlayingBundleID)
        self.isNowPlayingPlaying = isNowPlayingPlaying
        self.isSpotifyRunning = isSpotifyRunning
        self.isSpotifyPlaying = isSpotifyPlaying
        self.frontmostBundleID = Self.normalizedBundleID(frontmostBundleID)
        self.hasOtherActiveMediaClient = hasOtherActiveMediaClient
    }

    public static func normalizedBundleID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Pure, unit-testable router choosing between Spotify's background AppleEvent/AppleScript path,
/// the system Now Playing HID media-key path, or an explicit failure when no player is active.
public enum MacMediaTransportRouter {
    public static let spotifyBundleIdentifier = "com.spotify.client"
    public static let musicBundleIdentifier = "com.apple.Music"

    public static func chooseRoute(
        nowPlayingBundleID: String?,
        isSpotifyRunning: Bool,
        isNowPlayingPlaying: Bool = true,
        isSpotifyPlaying: Bool = false,
        frontmostBundleID: String? = nil,
        hasOtherActiveMediaClient: Bool = false
    ) -> MacMediaTransportRoute {
        chooseRoute(
            context: MacMediaTransportContext(
                nowPlayingBundleID: nowPlayingBundleID,
                isNowPlayingPlaying: isNowPlayingPlaying,
                isSpotifyRunning: isSpotifyRunning,
                isSpotifyPlaying: isSpotifyPlaying,
                frontmostBundleID: frontmostBundleID,
                hasOtherActiveMediaClient: hasOtherActiveMediaClient
            )
        )
    }

    public static func chooseRoute(context: MacMediaTransportContext) -> MacMediaTransportRoute {
        let nowPlaying = context.nowPlayingBundleID
        let frontmost = context.frontmostBundleID
        let spotifyID = spotifyBundleIdentifier

        // 1. Spotify explicitly owns the Now Playing session.
        if nowPlaying?.caseInsensitiveCompare(spotifyID) == .orderedSame {
            if context.isSpotifyRunning {
                return .spotifyScript
            }
            if context.hasOtherActiveMediaClient {
                return .mediaKey
            }
            return .failure(.spotifyNotRunning)
        }

        // 2. Spotify is actively outputting/playing audio while no other Now Playing client is actively playing
        // (or Spotify is the frontmost player).
        if context.isSpotifyRunning && context.isSpotifyPlaying {
            if nowPlaying == nil || !context.isNowPlayingPlaying || frontmost?.caseInsensitiveCompare(spotifyID) == .orderedSame {
                return .spotifyScript
            }
        }

        // 3. Another client (e.g. Music, Safari, Chrome, Podcasts, VLC) owns Now Playing.
        if nowPlaying != nil {
            // If that session is paused and the user is actively in Spotify, control Spotify directly.
            if !context.isNowPlayingPlaying &&
                context.isSpotifyRunning &&
                frontmost?.caseInsensitiveCompare(spotifyID) == .orderedSame {
                return .spotifyScript
            }
            return .mediaKey
        }

        // 4. No Now Playing session is registered (Spotify on modern macOS frequently does not register with MediaRemote).
        if context.isSpotifyRunning {
            if context.hasOtherActiveMediaClient &&
                !context.isSpotifyPlaying &&
                frontmost?.caseInsensitiveCompare(spotifyID) != .orderedSame {
                return .mediaKey
            }
            return .spotifyScript
        }

        if context.hasOtherActiveMediaClient {
            return .mediaKey
        }

        return .failure(.noActiveMediaPlayer)
    }
}

// MARK: - Playback Scrub / Seek Router (Spotify & Music Background AppleEvent Only; macOS 13)

public enum MacMediaSeekTargetPlayer: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case spotify
    case music

    public var bundleIdentifier: String {
        switch self {
        case .spotify:
            return MacMediaTransportRouter.spotifyBundleIdentifier
        case .music:
            return MacMediaTransportRouter.musicBundleIdentifier
        }
    }

    public var displayName: String {
        switch self {
        case .spotify:
            return "Spotify"
        case .music:
            return "Music"
        }
    }

    public init?(bundleIdentifier raw: String?) {
        guard let cleaned = MacMediaTransportContext.normalizedBundleID(raw) else {
            return nil
        }
        if cleaned.caseInsensitiveCompare(MacMediaTransportRouter.spotifyBundleIdentifier) == .orderedSame {
            self = .spotify
        } else if cleaned.caseInsensitiveCompare(MacMediaTransportRouter.musicBundleIdentifier) == .orderedSame {
            self = .music
        } else {
            return nil
        }
    }

    /// Background AppleScript source using `if application id "<bundleID>" is running` so the player
    /// is never launched, never activated, and never steals focus.
    public func scriptSource(positionSeconds: Double) -> String {
        let literal = MacMediaSeekRouter.formattedScriptSeconds(positionSeconds)
        return """
        if application id "\(bundleIdentifier)" is running then
            tell application id "\(bundleIdentifier)" to set player position to \(literal)
            return "OK"
        else
            return "NOT_RUNNING"
        end if
        """
    }
}

public enum MacMediaSeekRejectionReason: Equatable, Hashable, Sendable {
    case missingDuration
    case noActiveMediaPlayer
    case playerNotRunning(bundleID: String)
    case unsupportedPlayer(bundleID: String)

    public func message(in language: AppLanguage = .system) -> String {
        switch self {
        case .missingDuration:
            return L10n.tr(
                "当前曲目未提供总时长，无法拖动跳转",
                "Track duration is unavailable for seeking",
                language: language
            )
        case .noActiveMediaPlayer:
            return L10n.tr(
                "当前没有正在播放的媒体会话",
                "No active Now Playing session to seek",
                language: language
            )
        case .playerNotRunning(let bundleID):
            let appName = MacMediaSeekTargetPlayer(bundleIdentifier: bundleID)?.displayName ?? bundleID
            return L10n.tr(
                "\(appName) 当前未在运行",
                "\(appName) is not currently running",
                language: language
            )
        case .unsupportedPlayer:
            return L10n.tr(
                "当前播放器在 macOS 13 上不支持直接跳转进度",
                "Seeking is not supported for this player on macOS 13",
                language: language
            )
        }
    }
}

public enum MacMediaSeekRoute: Equatable, Hashable, Sendable {
    case spotifyScript(positionSeconds: Double)
    case musicScript(positionSeconds: Double)
    case rejected(MacMediaSeekRejectionReason)
}

public struct MacMediaSeekContext: Equatable, Hashable, Sendable {
    public var nowPlayingBundleID: String?
    public var durationSeconds: Double?
    public var isSpotifyRunning: Bool
    public var isMusicRunning: Bool

    public init(
        nowPlayingBundleID: String? = nil,
        durationSeconds: Double? = nil,
        isSpotifyRunning: Bool = false,
        isMusicRunning: Bool = false
    ) {
        self.nowPlayingBundleID = MacMediaTransportContext.normalizedBundleID(nowPlayingBundleID)
        if let durationSeconds, durationSeconds.isFinite, !durationSeconds.isNaN, durationSeconds > 0 {
            self.durationSeconds = durationSeconds
        } else {
            self.durationSeconds = nil
        }
        self.isSpotifyRunning = isSpotifyRunning
        self.isMusicRunning = isMusicRunning
    }
}

/// Pure, unit-testable seek router for playback scrubbing:
/// - `com.spotify.client` + running + valid duration -> background Spotify `player position` AppleEvent
/// - `com.apple.Music` + running + valid duration -> background Music `player position` AppleEvent
/// - Missing/invalid duration -> `.rejected(.missingDuration)`
/// - Any other bundle or nil bundle -> `.rejected(...)` (no script, no HID keys, no fake success)
public enum MacMediaSeekRouter {
    public static let spotifyBundleIdentifier = MacMediaTransportRouter.spotifyBundleIdentifier
    public static let musicBundleIdentifier = MacMediaTransportRouter.musicBundleIdentifier

    public static func isSupportedSeekBundleIdentifier(_ raw: String?) -> Bool {
        MacMediaSeekTargetPlayer(bundleIdentifier: raw) != nil
    }

    /// Clamps any requested playback position in seconds to `0...durationSeconds`
    /// (`NaN` and negative values map to `0`; `+infinity` and past-end values map to `durationSeconds`).
    public static func clampPosition(_ requestedSeconds: Double, durationSeconds: Double) -> Double {
        guard durationSeconds.isFinite, !durationSeconds.isNaN, durationSeconds > 0 else {
            return 0.0
        }
        if requestedSeconds.isNaN || requestedSeconds <= 0.0 {
            return 0.0
        }
        if requestedSeconds >= durationSeconds {
            return durationSeconds
        }
        return min(durationSeconds, max(0.0, requestedSeconds))
    }

    /// Locale-independent decimal seconds literal for AppleScript (`en_US_POSIX`).
    public static func formattedScriptSeconds(_ positionSeconds: Double) -> String {
        let safe = (positionSeconds.isFinite && !positionSeconds.isNaN) ? max(0.0, positionSeconds) : 0.0
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), safe)
    }

    public static func chooseRoute(
        requestedPositionSeconds: Double,
        nowPlayingBundleID: String?,
        durationSeconds: Double?,
        isSpotifyRunning: Bool,
        isMusicRunning: Bool
    ) -> MacMediaSeekRoute {
        chooseRoute(
            requestedPositionSeconds: requestedPositionSeconds,
            context: MacMediaSeekContext(
                nowPlayingBundleID: nowPlayingBundleID,
                durationSeconds: durationSeconds,
                isSpotifyRunning: isSpotifyRunning,
                isMusicRunning: isMusicRunning
            )
        )
    }

    public static func chooseRoute(
        requestedPositionSeconds: Double,
        context: MacMediaSeekContext
    ) -> MacMediaSeekRoute {
        guard let validDuration = context.durationSeconds,
              validDuration.isFinite,
              !validDuration.isNaN,
              validDuration > 0 else {
            return .rejected(.missingDuration)
        }

        let clampedPosition = clampPosition(requestedPositionSeconds, durationSeconds: validDuration)

        guard let bundleID = MacMediaTransportContext.normalizedBundleID(context.nowPlayingBundleID) else {
            return .rejected(.noActiveMediaPlayer)
        }

        guard let target = MacMediaSeekTargetPlayer(bundleIdentifier: bundleID) else {
            return .rejected(.unsupportedPlayer(bundleID: bundleID))
        }

        switch target {
        case .spotify:
            guard context.isSpotifyRunning else {
                return .rejected(.playerNotRunning(bundleID: spotifyBundleIdentifier))
            }
            return .spotifyScript(positionSeconds: clampedPosition)
        case .music:
            guard context.isMusicRunning else {
                return .rejected(.playerNotRunning(bundleID: musicBundleIdentifier))
            }
            return .musicScript(positionSeconds: clampedPosition)
        }
    }
}
