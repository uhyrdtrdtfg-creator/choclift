import Foundation

// MARK: - 1. Pure Mac Awake Assertion State Machine (Round 4)

/// Pure state machine governing when the Mac companion host holds a system idle-sleep
/// prevention assertion (`IOPMAssertionTypePreventUserIdleSystemSleep`).
///
/// Invariants:
/// - The assertion is active iff `isToggleEnabled == true` AND at least one authenticated companion is connected.
/// - Turning the toggle off immediately ends the assertion.
/// - Disconnecting the **last** companion immediately ends the assertion and resets `isToggleEnabled` to `false`,
///   so power state is never permanently altered after companions leave.
public struct MacAwakeAssertionStateMachine: Equatable, Sendable {
    public private(set) var isToggleEnabled: Bool
    public private(set) var connectedDeviceIDs: Set<String>

    public init(
        isToggleEnabled: Bool = false,
        connectedDeviceIDs: Set<String> = []
    ) {
        let normalized = Self.normalizeDeviceIDs(connectedDeviceIDs)
        self.connectedDeviceIDs = normalized
        self.isToggleEnabled = normalized.isEmpty ? false : isToggleEnabled
    }

    public var connectedCompanionCount: Int {
        connectedDeviceIDs.count
    }

    public var shouldHoldAssertion: Bool {
        isToggleEnabled && !connectedDeviceIDs.isEmpty
    }

    /// Updates the user's phone toggle. Enabling requires at least one connected companion.
    @discardableResult
    public mutating func setToggleEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            isToggleEnabled = !connectedDeviceIDs.isEmpty
        } else {
            isToggleEnabled = false
        }
        return shouldHoldAssertion
    }

    /// Reconciles the full set of currently connected companion device IDs.
    /// Ends the assertion and clears the toggle as soon as the last companion disconnects.
    @discardableResult
    public mutating func updateConnectedDevices(_ deviceIDs: Set<String>) -> Bool {
        connectedDeviceIDs = Self.normalizeDeviceIDs(deviceIDs)
        if connectedDeviceIDs.isEmpty {
            isToggleEnabled = false
        }
        return shouldHoldAssertion
    }

    @discardableResult
    public mutating func deviceConnected(_ deviceID: String) -> Bool {
        let trimmed = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return shouldHoldAssertion }
        connectedDeviceIDs.insert(trimmed)
        return shouldHoldAssertion
    }

    @discardableResult
    public mutating func deviceDisconnected(_ deviceID: String) -> Bool {
        let trimmed = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            connectedDeviceIDs.remove(trimmed)
        }
        if connectedDeviceIDs.isEmpty {
            isToggleEnabled = false
        }
        return shouldHoldAssertion
    }

    public mutating func reset() {
        isToggleEnabled = false
        connectedDeviceIDs.removeAll()
    }

    private static func normalizeDeviceIDs(_ raw: Set<String>) -> Set<String> {
        var result = Set<String>()
        for item in raw {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.insert(trimmed)
            }
        }
        return result
    }
}

// MARK: - 2. Mac Audio Output Picker Models (Round 4)

public enum MacAudioTransportKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case builtIn
    case bluetooth
    case usb
    case displayAudio
    case airPlay
    case virtualOrOther

    public var sfSymbol: String {
        switch self {
        case .builtIn:
            return "laptopcomputer"
        case .bluetooth:
            return "headphones"
        case .usb:
            return "cable.connector"
        case .displayAudio:
            return "tv.and.hifispeaker.fill"
        case .airPlay:
            return "airplayaudio"
        case .virtualOrOther:
            return "hifispeaker.fill"
        }
    }

    public func label(in language: AppLanguage = .system) -> String {
        switch self {
        case .builtIn:
            return L10n.tr("内置扬声器/耳机", "Built-in", language: language)
        case .bluetooth:
            return L10n.tr("蓝牙音频", "Bluetooth", language: language)
        case .usb:
            return L10n.tr("USB 音频", "USB Audio", language: language)
        case .displayAudio:
            return L10n.tr("显示器音频", "Display Audio", language: language)
        case .airPlay:
            return L10n.tr("隔空播放", "AirPlay", language: language)
        case .virtualOrOther:
            return L10n.tr("音频输出", "Audio Output", language: language)
        }
    }
}

public struct MacAudioOutputDevice: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var audioObjectID: UInt32
    public var name: String
    public var transportKind: MacAudioTransportKind
    public var isSelectable: Bool
    public var modelUID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case audioObjectID
        case name
        case transportKind
        case isSelectable
        case modelUID
    }

    public init(
        id: String,
        audioObjectID: UInt32,
        name: String,
        transportKind: MacAudioTransportKind = .virtualOrOther,
        isSelectable: Bool = true,
        modelUID: String? = nil
    ) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "Audio Output" : trimmedName
        self.id = trimmedID.isEmpty
            ? Self.fallbackID(transportKind: transportKind, name: resolvedName)
            : trimmedID
        self.audioObjectID = audioObjectID
        self.name = resolvedName
        self.transportKind = transportKind
        self.isSelectable = isSelectable
        self.modelUID = (trimmedModel?.isEmpty == false) ? trimmedModel : nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        let rawObjectID = try container.decode(UInt32.self, forKey: .audioObjectID)
        let rawName = try container.decode(String.self, forKey: .name)
        let rawTransport = try container.decode(MacAudioTransportKind.self, forKey: .transportKind)
        let rawSelectable = try container.decodeIfPresent(Bool.self, forKey: .isSelectable) ?? true
        let rawModel = try container.decodeIfPresent(String.self, forKey: .modelUID)
        self.init(
            id: rawID,
            audioObjectID: rawObjectID,
            name: rawName,
            transportKind: rawTransport,
            isSelectable: rawSelectable,
            modelUID: rawModel
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(audioObjectID, forKey: .audioObjectID)
        try container.encode(name, forKey: .name)
        try container.encode(transportKind, forKey: .transportKind)
        if !isSelectable {
            try container.encode(false, forKey: .isSelectable)
        }
        if let modelUID, !modelUID.isEmpty {
            try container.encode(modelUID, forKey: .modelUID)
        }
    }

    public var isAirPlay: Bool {
        transportKind == .airPlay
    }

    public var isHomePod: Bool {
        if let model = modelUID?.lowercased(), model.hasPrefix("audioaccessory") {
            return true
        }
        return name.localizedCaseInsensitiveContains("homepod")
    }

    public var sfSymbol: String {
        guard transportKind == .airPlay else {
            return transportKind.sfSymbol
        }
        let lowerModel = modelUID?.lowercased() ?? ""
        if lowerModel.hasPrefix("audioaccessory5") || name.localizedCaseInsensitiveContains("homepod mini") {
            return "homepodmini.fill"
        }
        if isHomePod {
            return "homepod.fill"
        }
        if lowerModel.hasPrefix("appletv") {
            return "appletv.fill"
        }
        return "airplayaudio"
    }

    public func transportSubtitle(in language: AppLanguage = .system) -> String {
        guard transportKind == .airPlay else {
            return transportKind.label(in: language)
        }
        let lowerModel = modelUID?.lowercased() ?? ""
        if lowerModel.hasPrefix("audioaccessory5") || name.localizedCaseInsensitiveContains("homepod mini") {
            return L10n.tr("HomePod mini · 隔空播放", "HomePod mini · AirPlay", language: language)
        }
        if isHomePod {
            return L10n.tr("HomePod · 隔空播放", "HomePod · AirPlay", language: language)
        }
        if lowerModel.hasPrefix("appletv") {
            return L10n.tr("Apple TV · 隔空播放", "Apple TV · AirPlay", language: language)
        }
        return transportKind.label(in: language)
    }

    public func selectionUnavailableReason(in language: AppLanguage = .system) -> String? {
        guard !isSelectable else { return nil }
        return L10n.tr(
            "需在 macOS 控制中心 → 声音中连接隔空播放",
            "Select in macOS Control Center → Sound to connect AirPlay",
            language: language
        )
    }

    /// Stable identity across `coreaudiod` restarts used ONLY when a device lacks `kAudioDevicePropertyDeviceUID`.
    public static func fallbackID(transportKind: MacAudioTransportKind, name: String) -> String {
        let normalizedName = normalizeDisplayNameKey(name)
        let safeName = normalizedName.isEmpty ? "unnamed" : normalizedName
        return "fallback:\(transportKind.rawValue):\(safeName)"
    }

    public static func normalizeDisplayNameKey(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public struct MacDiscoveredAirPlayReceiver: Codable, Equatable, Hashable, Sendable {
    public var deviceID: String
    public var name: String
    public var model: String?
    public var groupID: String?
    public var isGroupLeader: Bool
    public var audioBoxObjectID: UInt32
    public var audioDeviceObjectID: UInt32
    public var isSelectableViaCoreAudio: Bool

    public init(
        deviceID: String,
        name: String,
        model: String? = nil,
        groupID: String? = nil,
        isGroupLeader: Bool = true,
        audioBoxObjectID: UInt32 = 0,
        audioDeviceObjectID: UInt32 = 0,
        isSelectableViaCoreAudio: Bool = false
    ) {
        let cleanedID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedGroup = groupID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.deviceID = cleanedID
        self.name = cleanedName.isEmpty ? "AirPlay Speaker" : cleanedName
        self.model = (cleanedModel?.isEmpty == false) ? cleanedModel : nil
        self.groupID = (cleanedGroup?.isEmpty == false) ? cleanedGroup : nil
        self.isGroupLeader = isGroupLeader
        self.audioBoxObjectID = audioBoxObjectID
        self.audioDeviceObjectID = audioDeviceObjectID
        self.isSelectableViaCoreAudio = isSelectableViaCoreAudio
    }

    public var normalizedDeviceKey: String {
        Self.normalizeHardwareIdentifier(deviceID)
    }

    public var stableOutputID: String {
        let normID = normalizedDeviceKey
        let normName = MacAudioOutputDevice.normalizeDisplayNameKey(name)
        if !normID.isEmpty {
            if Self.isPlaceholderHardwareID(normID) {
                let safeName = normName.isEmpty ? "speaker" : normName
                return "airplay:\(normID):\(safeName)"
            }
            return "airplay:\(normID)"
        }
        let safeName = normName.isEmpty ? "speaker" : normName
        return "airplay:name:\(safeName)"
    }

    public static func normalizeHardwareIdentifier(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = raw.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }

    public static func isPlaceholderHardwareID(_ normalizedLowerHex: String) -> Bool {
        normalizedLowerHex == "000000000000" ||
            normalizedLowerHex == "100000000000" ||
            normalizedLowerHex == "ffffffffffff"
    }
}

public struct MacAirPlayBonjourServiceEntry: Equatable, Hashable, Sendable {
    public var serviceName: String
    public var serviceType: String
    public var txtRecord: [String: String]

    public init(serviceName: String, serviceType: String, txtRecord: [String: String] = [:]) {
        self.serviceName = serviceName
        self.serviceType = serviceType
        self.txtRecord = txtRecord
    }
}

/// Pure parser converting `_raop._tcp` and `_airplay._tcp` Bonjour browse results into deduplicated
/// audio-capable AirPlay receivers (HomePod, HomePod mini, stereo pairs, Apple TV, AirPlay speakers).
public enum MacAirPlayBonjourParser {
    /// Bit 9 (`0x200`) in the lower 32-bit `_airplay._tcp` `features` mask indicates AirPlay audio support.
    private static let airPlayAudioFeatureMask: UInt64 = 0x200

    public static func parseReceivers(
        entries: [MacAirPlayBonjourServiceEntry],
        localHardwareIdentifiers: Set<String> = []
    ) -> [MacDiscoveredAirPlayReceiver] {
        let normalizedLocalIDs = Set(localHardwareIdentifiers.map(MacDiscoveredAirPlayReceiver.normalizeHardwareIdentifier))

        struct Candidate {
            var rawDeviceID: String
            var normalizedID: String
            var name: String
            var model: String?
            var groupID: String?
            var isGroupLeader: Bool
            var supportsAudio: Bool
        }

        var byCompositeKey: [String: Candidate] = [:]

        func compositeKey(normalizedID: String, name: String) -> String {
            let nameKey = MacAudioOutputDevice.normalizeDisplayNameKey(name)
            if normalizedID.isEmpty || MacDiscoveredAirPlayReceiver.isPlaceholderHardwareID(normalizedID) {
                return "name:\(normalizedID):\(nameKey)"
            }
            return "id:\(normalizedID)"
        }

        for entry in entries {
            let lowerType = entry.serviceType.lowercased()
            let txt = entry.txtRecord

            if lowerType.contains("_raop._tcp") {
                let (parsedID, parsedName) = splitRAOPServiceName(entry.serviceName)
                let cleanedName = parsedName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanedName.isEmpty else { continue }
                let normID = MacDiscoveredAirPlayReceiver.normalizeHardwareIdentifier(parsedID)
                if !normID.isEmpty, normalizedLocalIDs.contains(normID) {
                    continue
                }
                let model = txt["am"] ?? txt["model"]
                let key = compositeKey(normalizedID: normID, name: cleanedName)
                if var existing = byCompositeKey[key] {
                    existing.supportsAudio = true
                    if existing.model == nil, let model {
                        existing.model = model
                    }
                    byCompositeKey[key] = existing
                } else {
                    byCompositeKey[key] = Candidate(
                        rawDeviceID: parsedID,
                        normalizedID: normID,
                        name: cleanedName,
                        model: model,
                        groupID: nil,
                        isGroupLeader: true,
                        supportsAudio: true
                    )
                }
            } else if lowerType.contains("_airplay._tcp") {
                let cleanedName = entry.serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanedName.isEmpty else { continue }
                let rawID = txt["deviceid"] ?? ""
                let normID = MacDiscoveredAirPlayReceiver.normalizeHardwareIdentifier(rawID)
                if !normID.isEmpty, normalizedLocalIDs.contains(normID) {
                    continue
                }
                let model = txt["model"] ?? txt["am"]
                let gid = txt["gid"]
                let isLeader: Bool = {
                    if let igl = txt["igl"] {
                        return igl != "0"
                    }
                    return true
                }()
                let audioCapable = hasAirPlayAudioFeature(txt["features"]) ||
                    (model?.lowercased().hasPrefix("audioaccessory") == true)

                let key = compositeKey(normalizedID: normID, name: cleanedName)
                if var existing = byCompositeKey[key] {
                    if let model, !model.isEmpty {
                        existing.model = model
                    }
                    if let gid, !gid.isEmpty {
                        existing.groupID = gid
                    }
                    existing.isGroupLeader = isLeader
                    existing.supportsAudio = existing.supportsAudio || audioCapable
                    byCompositeKey[key] = existing
                } else {
                    byCompositeKey[key] = Candidate(
                        rawDeviceID: rawID,
                        normalizedID: normID,
                        name: cleanedName,
                        model: model,
                        groupID: gid,
                        isGroupLeader: isLeader,
                        supportsAudio: audioCapable
                    )
                }
            }
        }

        // Keep only audio-capable AirPlay receivers and deduplicate HomePod stereo pairs sharing (groupID, name)
        var groupBest: [String: Candidate] = [:]
        var ungrouped: [Candidate] = []

        for candidate in byCompositeKey.values where candidate.supportsAudio {
            if let gid = candidate.groupID?.trimmingCharacters(in: .whitespacesAndNewlines), !gid.isEmpty {
                let pairKey = "\(gid.lowercased())|\(MacAudioOutputDevice.normalizeDisplayNameKey(candidate.name))"
                if let current = groupBest[pairKey] {
                    // Prefer group leader; tie-break deterministically by normalizedID so IDs stay stable
                    if (!current.isGroupLeader && candidate.isGroupLeader) ||
                        (current.isGroupLeader == candidate.isGroupLeader && candidate.normalizedID < current.normalizedID) {
                        groupBest[pairKey] = candidate
                    }
                } else {
                    groupBest[pairKey] = candidate
                }
            } else {
                ungrouped.append(candidate)
            }
        }

        let combined = ungrouped + Array(groupBest.values)
        return combined
            .map { cand in
                MacDiscoveredAirPlayReceiver(
                    deviceID: cand.rawDeviceID.isEmpty ? cand.normalizedID : cand.rawDeviceID,
                    name: cand.name,
                    model: cand.model,
                    groupID: cand.groupID,
                    isGroupLeader: cand.isGroupLeader,
                    audioBoxObjectID: 0,
                    audioDeviceObjectID: 0,
                    isSelectableViaCoreAudio: false
                )
            }
            .sorted { lhs, rhs in
                let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if cmp != .orderedSame {
                    return cmp == .orderedAscending
                }
                return lhs.stableOutputID < rhs.stableOutputID
            }
    }

    public static func splitRAOPServiceName(_ raw: String) -> (deviceID: String, displayName: String) {
        guard let atIndex = raw.firstIndex(of: "@") else {
            return ("", raw)
        }
        let prefix = String(raw[..<atIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(raw[raw.index(after: atIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let isHexPrefix = prefix.count >= 6 && prefix.unicodeScalars.allSatisfy { scalar in
            CharacterSet(charactersIn: "0123456789abcdefABCDEF:-").contains(scalar)
        }
        if isHexPrefix && !suffix.isEmpty {
            return (prefix, suffix)
        }
        return ("", raw)
    }

    public static func hasAirPlayAudioFeature(_ rawFeatures: String?) -> Bool {
        guard let raw = rawFeatures?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return false
        }
        let firstPart = raw.split(separator: ",").first.map(String.init) ?? raw
        let cleaned = firstPart.lowercased().hasPrefix("0x")
            ? String(firstPart.dropFirst(2))
            : firstPart
        guard let lowBits = UInt64(cleaned, radix: 16) else {
            return false
        }
        return (lowBits & airPlayAudioFeatureMask) != 0
    }
}

public enum MacAudioDefaultSelector: UInt32, CaseIterable, Equatable, Hashable, Sendable {
    /// `kAudioHardwarePropertyDefaultOutputDevice` (`'dOut'`)
    case defaultOutput = 0x644F7574
    /// `kAudioHardwarePropertyDefaultSystemOutputDevice` (`'sOut'`)
    case defaultSystemOutput = 0x734F7574

    public static func selectorsToApply(
        hasDefaultSystemOutput: Bool,
        isDefaultSystemOutputSettable: Bool
    ) -> [MacAudioDefaultSelector] {
        if hasDefaultSystemOutput && isDefaultSystemOutputSettable {
            return [.defaultOutput, .defaultSystemOutput]
        }
        return [.defaultOutput]
    }
}

public struct MacAudioRawDeviceRecord: Equatable, Hashable, Sendable {
    public var audioObjectID: UInt32
    public var uid: String?
    public var name: String
    public var transportKind: MacAudioTransportKind
    public var outputChannelCount: Int
    public var isHidden: Bool
    public var isPrivateAggregate: Bool
    public var canBeDefaultOutput: Bool
    public var modelUID: String?

    public init(
        audioObjectID: UInt32,
        uid: String?,
        name: String,
        transportKind: MacAudioTransportKind,
        outputChannelCount: Int,
        isHidden: Bool = false,
        isPrivateAggregate: Bool = false,
        canBeDefaultOutput: Bool = true,
        modelUID: String? = nil
    ) {
        let cleanedUID = uid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedModel = modelUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.audioObjectID = audioObjectID
        self.uid = (cleanedUID?.isEmpty == false) ? cleanedUID : nil
        self.name = cleanedName.isEmpty ? "Audio Output" : cleanedName
        self.transportKind = transportKind
        self.outputChannelCount = max(0, outputChannelCount)
        self.isHidden = isHidden
        self.isPrivateAggregate = isPrivateAggregate
        self.canBeDefaultOutput = canBeDefaultOutput
        self.modelUID = (cleanedModel?.isEmpty == false) ? cleanedModel : nil
    }
}

public struct MacAudioRunningProcessRecord: Equatable, Hashable, Sendable {
    public var processObjectID: UInt32
    public var pid: Int32
    public var appName: String?
    public var outputDeviceObjectIDs: [UInt32]
    public var isOutputDeviceSettable: Bool

    public init(
        processObjectID: UInt32,
        pid: Int32,
        appName: String?,
        outputDeviceObjectIDs: [UInt32],
        isOutputDeviceSettable: Bool
    ) {
        let cleanedApp = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.processObjectID = processObjectID
        self.pid = pid
        self.appName = (cleanedApp?.isEmpty == false) ? cleanedApp : nil
        self.outputDeviceObjectIDs = outputDeviceObjectIDs
        self.isOutputDeviceSettable = isOutputDeviceSettable
    }

    public var displayName: String {
        appName ?? "PID \(pid)"
    }
}

public struct MacAudioOutputSnapshot: Equatable, Sendable {
    public var devices: [MacAudioOutputDevice]
    public var selectedID: String?
    public var canSwitch: Bool

    public init(
        devices: [MacAudioOutputDevice],
        selectedID: String?,
        canSwitch: Bool
    ) {
        self.devices = devices
        self.selectedID = ControlStripState.resolvedSelectedAudioOutputDeviceID(
            selectedID: selectedID,
            devices: devices
        )
        self.canSwitch = canSwitch
    }
}

public struct MacAudioOutputSwitchResult: Equatable, Sendable {
    public var success: Bool
    public var title: String
    public var detail: String
    public var snapshot: MacAudioOutputSnapshot
    public var appliedSelectors: [MacAudioDefaultSelector]
    public var defaultOutputStatus: Int32?
    public var systemOutputStatus: Int32?
    public var readBackDefaultOutputObjectID: UInt32
    public var readBackSystemOutputObjectID: UInt32?
    public var movedProcessCount: Int
    public var unmovedAppNames: [String]

    public init(
        success: Bool,
        title: String,
        detail: String,
        snapshot: MacAudioOutputSnapshot,
        appliedSelectors: [MacAudioDefaultSelector] = [],
        defaultOutputStatus: Int32? = nil,
        systemOutputStatus: Int32? = nil,
        readBackDefaultOutputObjectID: UInt32 = 0,
        readBackSystemOutputObjectID: UInt32? = nil,
        movedProcessCount: Int = 0,
        unmovedAppNames: [String] = []
    ) {
        self.success = success
        self.title = title
        self.detail = detail
        self.snapshot = snapshot
        self.appliedSelectors = appliedSelectors
        self.defaultOutputStatus = defaultOutputStatus
        self.systemOutputStatus = systemOutputStatus
        self.readBackDefaultOutputObjectID = readBackDefaultOutputObjectID
        self.readBackSystemOutputObjectID = readBackSystemOutputObjectID
        self.movedProcessCount = movedProcessCount
        self.unmovedAppNames = unmovedAppNames
    }
}

public protocol MacAudioOutputHardwareDriver {
    func isSelectorAvailable(_ selector: MacAudioDefaultSelector) -> Bool
    func isSelectorSettable(_ selector: MacAudioDefaultSelector) -> (isSettable: Bool, status: Int32)
    func readDefaultDevice(for selector: MacAudioDefaultSelector) -> (objectID: UInt32, status: Int32)
    func writeDefaultDevice(_ objectID: UInt32, for selector: MacAudioDefaultSelector) -> Int32
    func readLiveDeviceRecords() -> [MacAudioRawDeviceRecord]
    func readDiscoveredAirPlayReceivers() -> [MacDiscoveredAirPlayReceiver]
    func acquireAirPlayBox(_ boxObjectID: UInt32) -> (deviceObjectID: UInt32?, status: Int32)
    func translateUIDToLiveObjectID(_ uid: String) -> UInt32?
    func readRunningOutputProcesses(excludingCurrentProcess: Bool) -> [MacAudioRunningProcessRecord]?
    func writeProcessOutputDevice(processObjectID: UInt32, targetDeviceObjectID: UInt32) -> Int32
    func isDeviceRunningOutputAudio(_ objectID: UInt32) -> Bool
}

public extension MacAudioOutputHardwareDriver {
    func readDiscoveredAirPlayReceivers() -> [MacDiscoveredAirPlayReceiver] {
        []
    }

    func acquireAirPlayBox(_ boxObjectID: UInt32) -> (deviceObjectID: UInt32?, status: Int32) {
        (nil, -1)
    }
}

public enum MacAudioOutputSwitchEngine {
    public struct ResolvedTarget: Equatable, Sendable {
        public let record: MacAudioRawDeviceRecord
        public let resolvedID: String
    }

    private static let hiddenSystemUIDPrefixes: [String] = [
        "cadefaultdeviceaggregate",
        "com.apple.audio.cadefaultdeviceaggregate",
        "com.apple.accessibility.",
        "hureachablehearingaidsdeviceuid",
        "tap-"
    ]

    /// Returns true when `record` represents a private/system aggregate or internal tap that macOS Sound menu hides.
    public static func isSystemHiddenAggregate(_ record: MacAudioRawDeviceRecord) -> Bool {
        if record.isPrivateAggregate {
            return true
        }
        if let lowerUID = record.uid?.lowercased() {
            for prefix in hiddenSystemUIDPrefixes where lowerUID.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }

    /// Mirrors macOS Sound menu visibility for CoreAudio device records:
    /// - Always includes the live default output device if it has output channels (or is AirPlay) so the checkmark matches reality.
    /// - Hides private/auto-aggregate devices (`CADefaultDeviceAggregate`, `isPrivateAggregate`, etc.).
    /// - Omits `isHidden` devices UNLESS they are the live default OR an AirPlay receiver the system menu would show.
    /// - Includes visible output devices (`outputChannelCount > 0` and `canBeDefaultOutput`) and visible AirPlay outputs.
    public static func shouldIncludeCoreAudioRecord(
        _ record: MacAudioRawDeviceRecord,
        defaultOutputObjectID: UInt32
    ) -> Bool {
        guard record.audioObjectID != 0 else { return false }

        let isLiveDefault = (defaultOutputObjectID != 0 && record.audioObjectID == defaultOutputObjectID)
        if isLiveDefault {
            return record.outputChannelCount > 0 || record.transportKind == .airPlay
        }

        if isSystemHiddenAggregate(record) {
            return false
        }

        if record.isHidden {
            return record.transportKind == .airPlay
        }

        if record.transportKind == .airPlay {
            return true
        }

        return record.outputChannelCount > 0 && record.canBeDefaultOutput
    }

    public static func isCoreAudioRecordDirectlySelectable(_ record: MacAudioRawDeviceRecord) -> Bool {
        record.audioObjectID != 0 && record.outputChannelCount > 0 && record.canBeDefaultOutput
    }

    public static func enumerateSnapshot(using driver: MacAudioOutputHardwareDriver) -> MacAudioOutputSnapshot {
        let defaultOut = driver.readDefaultDevice(for: .defaultOutput).objectID
        let defaultSettable = driver.isSelectorSettable(.defaultOutput).isSettable
        let records = driver.readLiveDeviceRecords()
        let airPlayReceivers = driver.readDiscoveredAirPlayReceivers()
        return enumerateSnapshot(
            records: records,
            airPlayReceivers: airPlayReceivers,
            defaultOutputObjectID: defaultOut,
            isDefaultOutputSettable: defaultSettable
        )
    }

    public static func enumerateSnapshot(
        records: [MacAudioRawDeviceRecord],
        airPlayReceivers: [MacDiscoveredAirPlayReceiver] = [],
        defaultOutputObjectID: UInt32,
        isDefaultOutputSettable: Bool
    ) -> MacAudioOutputSnapshot {
        var outputs: [MacAudioOutputDevice] = []
        var indexByID: [String: Int] = [:]
        var fallbackBaseCounts: [String: Int] = [:]
        var resolvedSelectedID: String?
        var consumedReceiverIndices = Set<Int>()

        func findMatchingAirPlayReceiverIndex(for record: MacAudioRawDeviceRecord) -> Int? {
            guard record.transportKind == .airPlay else { return nil }
            let recordNormUID = record.uid.map(MacDiscoveredAirPlayReceiver.normalizeHardwareIdentifier) ?? ""
            let recordNameKey = MacAudioOutputDevice.normalizeDisplayNameKey(record.name)

            if record.audioObjectID != 0,
               let byObj = airPlayReceivers.firstIndex(where: { $0.audioDeviceObjectID == record.audioObjectID }) {
                return byObj
            }
            if !recordNormUID.isEmpty,
               !MacDiscoveredAirPlayReceiver.isPlaceholderHardwareID(recordNormUID),
               let byUID = airPlayReceivers.firstIndex(where: { $0.normalizedDeviceKey == recordNormUID }) {
                return byUID
            }
            if !recordNameKey.isEmpty,
               let byName = airPlayReceivers.firstIndex(where: {
                   MacAudioOutputDevice.normalizeDisplayNameKey($0.name) == recordNameKey
               }) {
                return byName
            }
            return nil
        }

        for record in records where shouldIncludeCoreAudioRecord(record, defaultOutputObjectID: defaultOutputObjectID) {
            let matchedReceiverIndex = findMatchingAirPlayReceiverIndex(for: record)
            let matchedReceiver = matchedReceiverIndex.map { airPlayReceivers[$0] }
            if let matchedReceiverIndex {
                consumedReceiverIndices.insert(matchedReceiverIndex)
            }

            let stableID: String
            if let matchedReceiver {
                stableID = matchedReceiver.stableOutputID
            } else if let uid = record.uid {
                stableID = uid
            } else {
                let base = MacAudioOutputDevice.fallbackID(
                    transportKind: record.transportKind,
                    name: record.name
                )
                let nextCount = (fallbackBaseCounts[base] ?? 0) + 1
                fallbackBaseCounts[base] = nextCount
                stableID = nextCount == 1 ? base : "\(base)#\(nextCount)"
            }

            let canSelectDevice = isDefaultOutputSettable && (
                isCoreAudioRecordDirectlySelectable(record) ||
                (matchedReceiver?.isSelectableViaCoreAudio == true)
            )

            let candidate = MacAudioOutputDevice(
                id: stableID,
                audioObjectID: record.audioObjectID,
                name: record.name,
                transportKind: record.transportKind,
                isSelectable: canSelectDevice,
                modelUID: matchedReceiver?.model ?? record.modelUID
            )

            if let existingIndex = indexByID[stableID] {
                if record.audioObjectID == defaultOutputObjectID {
                    outputs[existingIndex] = candidate
                    resolvedSelectedID = stableID
                }
                continue
            }

            indexByID[stableID] = outputs.count
            outputs.append(candidate)

            if defaultOutputObjectID != 0 && record.audioObjectID == defaultOutputObjectID {
                resolvedSelectedID = stableID
            }
        }

        // Merge discovered AirPlay receivers (HomePod, HomePod mini, Apple TV, AirPlay speakers)
        // that are not currently instantiated as CoreAudio device records.
        for (idx, receiver) in airPlayReceivers.enumerated() where !consumedReceiverIndices.contains(idx) {
            let stableID = receiver.stableOutputID
            guard indexByID[stableID] == nil else { continue }

            let canSelectReceiver = isDefaultOutputSettable && receiver.isSelectableViaCoreAudio
            let device = MacAudioOutputDevice(
                id: stableID,
                audioObjectID: receiver.audioDeviceObjectID,
                name: receiver.name,
                transportKind: .airPlay,
                isSelectable: canSelectReceiver,
                modelUID: receiver.model
            )
            indexByID[stableID] = outputs.count
            outputs.append(device)

            if defaultOutputObjectID != 0 &&
                receiver.audioDeviceObjectID != 0 &&
                receiver.audioDeviceObjectID == defaultOutputObjectID {
                resolvedSelectedID = stableID
            }
        }

        let canSwitch = isDefaultOutputSettable && outputs.contains(where: \.isSelectable)
        return MacAudioOutputSnapshot(
            devices: outputs,
            selectedID: resolvedSelectedID,
            canSwitch: canSwitch
        )
    }

    /// Resolves `requestedID` against live hardware records (and optional AirPlay receivers):
    /// 1. Matches by non-empty CoreAudio UID first.
    /// 2. Matches AirPlay `stableOutputID` when an AirPlay receiver is backed by a live CoreAudio device.
    /// 3. Falls back to stable `transport+name` identity ONLY for devices whose UID is missing.
    /// Never matches by raw `AudioObjectID` so stale object IDs after `coreaudiod` restarts cannot hit the wrong device.
    public static func resolveTarget(
        requestedID: String,
        in records: [MacAudioRawDeviceRecord],
        airPlayReceivers: [MacDiscoveredAirPlayReceiver] = [],
        defaultOutputObjectID: UInt32
    ) -> ResolvedTarget? {
        let trimmed = requestedID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let visibleOutputRecords = records.filter { record in
            shouldIncludeCoreAudioRecord(record, defaultOutputObjectID: defaultOutputObjectID)
        }

        // 1. Exact UID match first (prefer live default object if duplicate UID entries exist)
        let uidMatches = visibleOutputRecords.filter { $0.uid == trimmed }
        if let matched = uidMatches.first(where: { $0.audioObjectID == defaultOutputObjectID }) ?? uidMatches.first {
            // Determine canonical snapshot ID (if merged with an AirPlay receiver, snapshot uses stableOutputID)
            let snapshot = enumerateSnapshot(
                records: records,
                airPlayReceivers: airPlayReceivers,
                defaultOutputObjectID: defaultOutputObjectID,
                isDefaultOutputSettable: true
            )
            let canonicalID = snapshot.devices.first(where: { $0.audioObjectID == matched.audioObjectID })?.id ?? trimmed
            return ResolvedTarget(record: matched, resolvedID: canonicalID)
        }

        // 2. Match AirPlay stableOutputID against a live CoreAudio AirPlay record
        if let matchedReceiver = airPlayReceivers.first(where: { $0.stableOutputID == trimmed }) {
            let normKey = matchedReceiver.normalizedDeviceKey
            let nameKey = MacAudioOutputDevice.normalizeDisplayNameKey(matchedReceiver.name)
            let airPlayMatches = visibleOutputRecords.filter { record in
                guard record.transportKind == .airPlay else { return false }
                if matchedReceiver.audioDeviceObjectID != 0 && record.audioObjectID == matchedReceiver.audioDeviceObjectID {
                    return true
                }
                if !normKey.isEmpty,
                   let recUID = record.uid,
                   MacDiscoveredAirPlayReceiver.normalizeHardwareIdentifier(recUID) == normKey {
                    return true
                }
                return MacAudioOutputDevice.normalizeDisplayNameKey(record.name) == nameKey
            }
            if let matched = airPlayMatches.first(where: { $0.audioObjectID == defaultOutputObjectID }) ?? airPlayMatches.first {
                return ResolvedTarget(record: matched, resolvedID: trimmed)
            }
        }

        // 3. Stable transport+name fallback ONLY when UID is missing on the device
        var fallbackBaseCounts: [String: Int] = [:]
        for record in visibleOutputRecords where record.uid == nil {
            let base = MacAudioOutputDevice.fallbackID(
                transportKind: record.transportKind,
                name: record.name
            )
            let nextCount = (fallbackBaseCounts[base] ?? 0) + 1
            fallbackBaseCounts[base] = nextCount
            let candidateID = nextCount == 1 ? base : "\(base)#\(nextCount)"
            if candidateID == trimmed {
                return ResolvedTarget(record: record, resolvedID: candidateID)
            }
        }

        return nil
    }

    public static func performSwitch(
        requestedID: String,
        language: AppLanguage = .system,
        using driver: MacAudioOutputHardwareDriver
    ) -> MacAudioOutputSwitchResult {
        let settableCheck = driver.isSelectorSettable(.defaultOutput)
        let previousDefault = driver.readDefaultDevice(for: .defaultOutput)
        var liveRecords = driver.readLiveDeviceRecords()
        let airPlayReceivers = driver.readDiscoveredAirPlayReceivers()
        let currentSnapshot = enumerateSnapshot(
            records: liveRecords,
            airPlayReceivers: airPlayReceivers,
            defaultOutputObjectID: previousDefault.objectID,
            isDefaultOutputSettable: settableCheck.isSettable
        )

        guard settableCheck.isSettable else {
            return MacAudioOutputSwitchResult(
                success: false,
                title: L10n.tr("音频输出只读", "Audio Output Read-Only", language: language),
                detail: L10n.tr(
                    "macOS 报告默认音频输出属性为只读，无法通过公开 CoreAudio 接口切换。",
                    "macOS reported the default audio output property as read-only via public CoreAudio API.",
                    language: language
                ),
                snapshot: currentSnapshot,
                readBackDefaultOutputObjectID: previousDefault.objectID
            )
        }

        guard !currentSnapshot.devices.isEmpty else {
            return MacAudioOutputSwitchResult(
                success: false,
                title: L10n.tr("音频输出", "Audio Output", language: language),
                detail: L10n.tr("Mac 当前没有可用的音频输出设备。", "No audio output devices are currently available on this Mac.", language: language),
                snapshot: currentSnapshot,
                readBackDefaultOutputObjectID: previousDefault.objectID
            )
        }

        let trimmedID = requestedID.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolved = resolveTarget(
            requestedID: trimmedID,
            in: liveRecords,
            airPlayReceivers: airPlayReceivers,
            defaultOutputObjectID: previousDefault.objectID
        )

        // If target is an AirPlay receiver backed by an acquirable CoreAudio AudioBox (and not yet active in liveRecords),
        // acquire the box via public CoreAudio API first so its AudioDevice becomes selectable.
        if (resolved == nil || (resolved != nil && !isCoreAudioRecordDirectlySelectable(resolved!.record))),
           let matchedReceiver = airPlayReceivers.first(where: { $0.stableOutputID == trimmedID || $0.deviceID == trimmedID }) {
            if matchedReceiver.isSelectableViaCoreAudio, matchedReceiver.audioBoxObjectID != 0 {
                let acquired = driver.acquireAirPlayBox(matchedReceiver.audioBoxObjectID)
                liveRecords = driver.readLiveDeviceRecords()
                resolved = resolveTarget(
                    requestedID: trimmedID,
                    in: liveRecords,
                    airPlayReceivers: driver.readDiscoveredAirPlayReceivers(),
                    defaultOutputObjectID: previousDefault.objectID
                )
                if resolved == nil, let devObjID = acquired.deviceObjectID, devObjID != 0,
                   let byAcquiredObj = liveRecords.first(where: { $0.audioObjectID == devObjID }) {
                    resolved = ResolvedTarget(record: byAcquiredObj, resolvedID: matchedReceiver.stableOutputID)
                }
            } else if resolved == nil || !isCoreAudioRecordDirectlySelectable(resolved!.record) {
                return MacAudioOutputSwitchResult(
                    success: false,
                    title: matchedReceiver.name,
                    detail: L10n.tr(
                        "无法直接切换至“\(matchedReceiver.name)”：macOS 13 公开接口不支持发起新的系统级隔空播放连接，请在控制中心 → 声音中选择该设备。",
                        "Cannot switch directly to “\(matchedReceiver.name)”: macOS 13 public APIs cannot initiate a new system-wide AirPlay connection. Select it in Control Center → Sound.",
                        language: language
                    ),
                    snapshot: currentSnapshot,
                    readBackDefaultOutputObjectID: previousDefault.objectID
                )
            }
        }

        guard let resolved else {
            return MacAudioOutputSwitchResult(
                success: false,
                title: L10n.tr("音频输出", "Audio Output", language: language),
                detail: L10n.tr("未找到该输出设备，可能已断开连接。", "That audio output device is no longer connected.", language: language),
                snapshot: currentSnapshot,
                readBackDefaultOutputObjectID: previousDefault.objectID
            )
        }

        if !isCoreAudioRecordDirectlySelectable(resolved.record) {
            return MacAudioOutputSwitchResult(
                success: false,
                title: resolved.record.name,
                detail: L10n.tr(
                    "无法直接切换至“\(resolved.record.name)”：macOS 需通过控制中心 → 声音激活该隔空播放接收端。",
                    "Cannot switch directly to “\(resolved.record.name)”: select it in macOS Control Center → Sound to activate AirPlay.",
                    language: language
                ),
                snapshot: currentSnapshot,
                readBackDefaultOutputObjectID: previousDefault.objectID
            )
        }

        // Re-resolve UID to the live AudioObjectID immediately before AudioObjectSetPropertyData,
        // never trusting a cached or client-supplied AudioObjectID.
        var liveTargetObjectID = resolved.record.audioObjectID
        if let uid = resolved.record.uid,
           let translated = driver.translateUIDToLiveObjectID(uid),
           translated != 0 {
            liveTargetObjectID = translated
        }

        let hasSystemSelector = driver.isSelectorAvailable(.defaultSystemOutput)
        let isSystemSettable = hasSystemSelector && driver.isSelectorSettable(.defaultSystemOutput).isSettable
        let selectors = MacAudioDefaultSelector.selectorsToApply(
            hasDefaultSystemOutput: hasSystemSelector,
            isDefaultSystemOutputSettable: isSystemSettable
        )

        let outStatus = driver.writeDefaultDevice(liveTargetObjectID, for: .defaultOutput)
        let readBackOut = driver.readDefaultDevice(for: .defaultOutput)
        let afterOutSnapshot = enumerateSnapshot(using: driver)

        if outStatus != 0 {
            return MacAudioOutputSwitchResult(
                success: false,
                title: resolved.record.name,
                detail: L10n.tr(
                    "切换默认音频输出失败（CoreAudio OSStatus \(outStatus)）。",
                    "Failed to switch default audio output (CoreAudio OSStatus \(outStatus)).",
                    language: language
                ),
                snapshot: afterOutSnapshot,
                appliedSelectors: [.defaultOutput],
                defaultOutputStatus: outStatus,
                readBackDefaultOutputObjectID: readBackOut.objectID
            )
        }

        let didConfirmDefaultSwitch = (readBackOut.objectID == liveTargetObjectID) ||
            (afterOutSnapshot.selectedID == resolved.resolvedID)
        if !didConfirmDefaultSwitch {
            let statusToReport = (readBackOut.status != 0) ? readBackOut.status : outStatus
            return MacAudioOutputSwitchResult(
                success: false,
                title: resolved.record.name,
                detail: L10n.tr(
                    "切换默认音频输出未生效（CoreAudio OSStatus \(statusToReport)）。",
                    "CoreAudio kept the previous default output device (OSStatus \(statusToReport)).",
                    language: language
                ),
                snapshot: afterOutSnapshot,
                appliedSelectors: [.defaultOutput],
                defaultOutputStatus: statusToReport,
                readBackDefaultOutputObjectID: readBackOut.objectID
            )
        }

        var sysStatus: Int32?
        var readBackSysObjectID: UInt32?
        if selectors.contains(.defaultSystemOutput) {
            let status = driver.writeDefaultDevice(liveTargetObjectID, for: .defaultSystemOutput)
            sysStatus = status
            readBackSysObjectID = driver.readDefaultDevice(for: .defaultSystemOutput).objectID
        }

        // Move active output of currently playing processes onto the new output device via public CoreAudio
        // process/device properties when available; otherwise record unmovable playing apps accurately.
        let outputObjectIDs = Set(
            liveRecords
                .filter { $0.audioObjectID != 0 && $0.outputChannelCount > 0 }
                .map(\.audioObjectID)
        )
        var movedProcessCount = 0
        var unmovedAppsOrdered: [String] = []
        var seenUnmovedApps = Set<String>()
        var hasUnmovableLegacyStream = false

        if let runningProcesses = driver.readRunningOutputProcesses(excludingCurrentProcess: true) {
            for proc in runningProcesses {
                let boundOutputIDs = proc.outputDeviceObjectIDs.filter { outputObjectIDs.contains($0) }
                let isStillOnOtherOutput: Bool
                if !boundOutputIDs.isEmpty {
                    isStillOnOtherOutput = boundOutputIDs.contains(where: { $0 != liveTargetObjectID })
                } else {
                    isStillOnOtherOutput = previousDefault.objectID != 0 &&
                        previousDefault.objectID != liveTargetObjectID &&
                        driver.isDeviceRunningOutputAudio(previousDefault.objectID)
                }

                guard isStillOnOtherOutput else { continue }

                if proc.isOutputDeviceSettable {
                    let moveStatus = driver.writeProcessOutputDevice(
                        processObjectID: proc.processObjectID,
                        targetDeviceObjectID: liveTargetObjectID
                    )
                    if moveStatus == 0 {
                        movedProcessCount += 1
                    } else if seenUnmovedApps.insert(proc.displayName).inserted {
                        unmovedAppsOrdered.append(proc.displayName)
                    }
                } else if seenUnmovedApps.insert(proc.displayName).inserted {
                    unmovedAppsOrdered.append(proc.displayName)
                }
            }
        } else if previousDefault.objectID != 0,
                  previousDefault.objectID != liveTargetObjectID,
                  driver.isDeviceRunningOutputAudio(previousDefault.objectID) {
            hasUnmovableLegacyStream = true
        }

        let finalSnapshot = enumerateSnapshot(using: driver)
        let detail: String
        if !unmovedAppsOrdered.isEmpty {
            let appsList = unmovedAppsOrdered.joined(separator: ", ")
            detail = L10n.tr(
                "已将默认输出切换至 \(resolved.record.name)；公开 CoreAudio 接口无法自动迁移正在播放的 \(appsList) 音频流。",
                "Switched default output to \(resolved.record.name); public CoreAudio API cannot move already-playing audio in \(appsList).",
                language: language
            )
        } else if hasUnmovableLegacyStream {
            detail = L10n.tr(
                "已将默认输出切换至 \(resolved.record.name)；公开 CoreAudio 接口无法自动迁移原设备上固定播放的应用。",
                "Switched default output to \(resolved.record.name); public CoreAudio API cannot move apps pinned to the previous output.",
                language: language
            )
        } else if let sysStatus, sysStatus != 0 {
            detail = L10n.tr(
                "已切换默认音频输出至 \(resolved.record.name)（系统提示音输出返回 OSStatus \(sysStatus)）。",
                "Switched default audio output to \(resolved.record.name) (system alert output returned OSStatus \(sysStatus)).",
                language: language
            )
        } else {
            detail = L10n.tr(
                "已切换 Mac 音频输出至 \(resolved.record.name)",
                "Switched Mac audio output to \(resolved.record.name)",
                language: language
            )
        }

        return MacAudioOutputSwitchResult(
            success: true,
            title: resolved.record.name,
            detail: detail,
            snapshot: finalSnapshot,
            appliedSelectors: selectors,
            defaultOutputStatus: outStatus,
            systemOutputStatus: sysStatus,
            readBackDefaultOutputObjectID: readBackOut.objectID,
            readBackSystemOutputObjectID: readBackSysObjectID,
            movedProcessCount: movedProcessCount,
            unmovedAppNames: unmovedAppsOrdered
        )
    }
}

// MARK: - 3. Frontmost App Window List Models (Capped at 12, No Pixel Streaming)

public struct MacFrontmostWindowItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var index: Int
    public var isMainOrFocused: Bool
    public var isMinimized: Bool

    public init(
        id: String,
        title: String,
        index: Int,
        isMainOrFocused: Bool = false,
        isMinimized: Bool = false
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.index = max(0, index)
        self.isMainOrFocused = isMainOrFocused
        self.isMinimized = isMinimized
    }
}

public struct FrontmostAppWindowSnapshot: Codable, Equatable, Hashable, Sendable {
    public static let maxWindows: Int = 12

    public var bundleIdentifier: String?
    public var appName: String?
    public var windows: [MacFrontmostWindowItem]
    public var totalWindowCount: Int
    public var isAccessibilityTrusted: Bool

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case appName
        case windows
        case totalWindowCount
        case isAccessibilityTrusted
    }

    public static let empty = FrontmostAppWindowSnapshot()

    public init(
        bundleIdentifier: String? = nil,
        appName: String? = nil,
        windows: [MacFrontmostWindowItem] = [],
        totalWindowCount: Int? = nil,
        isAccessibilityTrusted: Bool = true
    ) {
        self.bundleIdentifier = Self.clean(bundleIdentifier)
        self.appName = Self.clean(appName)
        let capped = Self.capWindows(windows)
        self.windows = capped
        self.totalWindowCount = max(capped.count, totalWindowCount ?? windows.count)
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bundleIdentifier = Self.clean(try container.decodeIfPresent(String.self, forKey: .bundleIdentifier))
        self.appName = Self.clean(try container.decodeIfPresent(String.self, forKey: .appName))
        let rawWindows = try container.decodeIfPresent([MacFrontmostWindowItem].self, forKey: .windows) ?? []
        let capped = Self.capWindows(rawWindows)
        self.windows = capped
        let decodedTotal = try container.decodeIfPresent(Int.self, forKey: .totalWindowCount) ?? rawWindows.count
        self.totalWindowCount = max(capped.count, decodedTotal)
        self.isAccessibilityTrusted = try container.decodeIfPresent(Bool.self, forKey: .isAccessibilityTrusted) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(appName, forKey: .appName)
        let capped = Self.capWindows(windows)
        try container.encode(capped, forKey: .windows)
        try container.encode(max(capped.count, totalWindowCount), forKey: .totalWindowCount)
        try container.encode(isAccessibilityTrusted, forKey: .isAccessibilityTrusted)
    }

    public static func capWindows(
        _ candidates: [MacFrontmostWindowItem],
        limit: Int = FrontmostAppWindowSnapshot.maxWindows
    ) -> [MacFrontmostWindowItem] {
        let clampedLimit = max(0, min(limit, maxWindows))
        guard candidates.count > clampedLimit else { return candidates }
        return Array(candidates.prefix(clampedLimit))
    }

    public var isCapped: Bool {
        totalWindowCount > windows.count
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

// MARK: - 4. Last-Ran Tile Action Status Tracker (Round 4)

public enum TileActionOutcome: String, Codable, Equatable, Hashable, Sendable {
    case success
    case failure
}

public struct TileActionFeedbackBanner: Equatable, Sendable {
    public static let defaultDisplayDurationSeconds: TimeInterval = 1.4

    public let token: UInt64
    public let slot: SlotCoordinate
    public let outcome: TileActionOutcome

    public init(token: UInt64, slot: SlotCoordinate, outcome: TileActionOutcome) {
        self.token = token
        self.slot = slot
        self.outcome = outcome
    }
}

/// Pure tracker for showing brief post-action success/failure feedback on the single tile that last ran.
public struct TileActionFeedbackTracker: Equatable, Sendable {
    public private(set) var pendingSlot: SlotCoordinate?
    public private(set) var activeFeedback: TileActionFeedbackBanner?
    private var nextToken: UInt64 = 0

    public init() {}

    public mutating func recordTileTriggered(slot: SlotCoordinate) {
        pendingSlot = slot
    }

    public mutating func clearPendingWithoutFeedback() {
        pendingSlot = nil
    }

    @discardableResult
    public mutating func recordImmediateOutcome(
        slot: SlotCoordinate,
        outcome: TileActionOutcome
    ) -> TileActionFeedbackBanner {
        pendingSlot = nil
        nextToken &+= 1
        let banner = TileActionFeedbackBanner(token: nextToken, slot: slot, outcome: outcome)
        activeFeedback = banner
        return banner
    }

    @discardableResult
    public mutating func resolvePending(success: Bool) -> TileActionFeedbackBanner? {
        guard let slot = pendingSlot else { return nil }
        pendingSlot = nil
        nextToken &+= 1
        let banner = TileActionFeedbackBanner(
            token: nextToken,
            slot: slot,
            outcome: success ? .success : .failure
        )
        activeFeedback = banner
        return banner
    }

    @discardableResult
    public mutating func failPendingOnDisconnect() -> TileActionFeedbackBanner? {
        guard let slot = pendingSlot else { return nil }
        pendingSlot = nil
        nextToken &+= 1
        let banner = TileActionFeedbackBanner(token: nextToken, slot: slot, outcome: .failure)
        activeFeedback = banner
        return banner
    }

    @discardableResult
    public mutating func expireFeedback(matchingToken token: UInt64) -> Bool {
        guard activeFeedback?.token == token else { return false }
        activeFeedback = nil
        return true
    }

    public func outcome(for slot: SlotCoordinate) -> TileActionOutcome? {
        guard let activeFeedback, activeFeedback.slot == slot else { return nil }
        return activeFeedback.outcome
    }
}
