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

    public init(
        id: String,
        audioObjectID: UInt32,
        name: String,
        transportKind: MacAudioTransportKind = .virtualOrOther
    ) {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "Audio Output" : trimmedName
        self.id = trimmedID.isEmpty
            ? Self.fallbackID(transportKind: transportKind, name: resolvedName)
            : trimmedID
        self.audioObjectID = audioObjectID
        self.name = resolvedName
        self.transportKind = transportKind
    }

    /// Stable identity across `coreaudiod` restarts used ONLY when a device lacks `kAudioDevicePropertyDeviceUID`.
    public static func fallbackID(transportKind: MacAudioTransportKind, name: String) -> String {
        let normalizedName = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let safeName = normalizedName.isEmpty ? "unnamed" : normalizedName
        return "fallback:\(transportKind.rawValue):\(safeName)"
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

    public init(
        audioObjectID: UInt32,
        uid: String?,
        name: String,
        transportKind: MacAudioTransportKind,
        outputChannelCount: Int,
        isHidden: Bool = false
    ) {
        let cleanedUID = uid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.audioObjectID = audioObjectID
        self.uid = (cleanedUID?.isEmpty == false) ? cleanedUID : nil
        self.name = cleanedName.isEmpty ? "Audio Output" : cleanedName
        self.transportKind = transportKind
        self.outputChannelCount = max(0, outputChannelCount)
        self.isHidden = isHidden
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
    func translateUIDToLiveObjectID(_ uid: String) -> UInt32?
    func readRunningOutputProcesses(excludingCurrentProcess: Bool) -> [MacAudioRunningProcessRecord]?
    func writeProcessOutputDevice(processObjectID: UInt32, targetDeviceObjectID: UInt32) -> Int32
    func isDeviceRunningOutputAudio(_ objectID: UInt32) -> Bool
}

public enum MacAudioOutputSwitchEngine {
    public struct ResolvedTarget: Equatable, Sendable {
        public let record: MacAudioRawDeviceRecord
        public let resolvedID: String
    }

    public static func enumerateSnapshot(using driver: MacAudioOutputHardwareDriver) -> MacAudioOutputSnapshot {
        let defaultOut = driver.readDefaultDevice(for: .defaultOutput).objectID
        let defaultSettable = driver.isSelectorSettable(.defaultOutput).isSettable
        let records = driver.readLiveDeviceRecords()
        return enumerateSnapshot(
            records: records,
            defaultOutputObjectID: defaultOut,
            isDefaultOutputSettable: defaultSettable
        )
    }

    public static func enumerateSnapshot(
        records: [MacAudioRawDeviceRecord],
        defaultOutputObjectID: UInt32,
        isDefaultOutputSettable: Bool
    ) -> MacAudioOutputSnapshot {
        var outputs: [MacAudioOutputDevice] = []
        var indexByID: [String: Int] = [:]
        var fallbackBaseCounts: [String: Int] = [:]
        var resolvedSelectedID: String?

        for record in records where record.audioObjectID != 0 && record.outputChannelCount > 0 {
            // Include the current default output device even if CoreAudio marks it hidden,
            // so the picker checkmark always matches the live output device.
            if record.isHidden && record.audioObjectID != defaultOutputObjectID {
                continue
            }

            let stableID: String
            if let uid = record.uid {
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

            let candidate = MacAudioOutputDevice(
                id: stableID,
                audioObjectID: record.audioObjectID,
                name: record.name,
                transportKind: record.transportKind
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

        let canSwitch = isDefaultOutputSettable && !outputs.isEmpty
        return MacAudioOutputSnapshot(
            devices: outputs,
            selectedID: resolvedSelectedID,
            canSwitch: canSwitch
        )
    }

    /// Resolves `requestedID` against live hardware records:
    /// 1. Matches by non-empty CoreAudio UID first.
    /// 2. Falls back to stable `transport+name` identity ONLY for devices whose UID is missing.
    /// Never matches by raw `AudioObjectID` so stale object IDs after `coreaudiod` restarts cannot hit the wrong device.
    public static func resolveTarget(
        requestedID: String,
        in records: [MacAudioRawDeviceRecord],
        defaultOutputObjectID: UInt32
    ) -> ResolvedTarget? {
        let trimmed = requestedID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let visibleOutputRecords = records.filter { record in
            record.audioObjectID != 0 &&
            record.outputChannelCount > 0 &&
            (!record.isHidden || record.audioObjectID == defaultOutputObjectID)
        }

        // 1. Exact UID match first (prefer live default object if duplicate UID entries exist)
        let uidMatches = visibleOutputRecords.filter { $0.uid == trimmed }
        if let matched = uidMatches.first(where: { $0.audioObjectID == defaultOutputObjectID }) ?? uidMatches.first {
            return ResolvedTarget(record: matched, resolvedID: trimmed)
        }

        // 2. Stable transport+name fallback ONLY when UID is missing on the device
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
        let liveRecords = driver.readLiveDeviceRecords()
        let currentSnapshot = enumerateSnapshot(
            records: liveRecords,
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

        guard let resolved = resolveTarget(
            requestedID: requestedID,
            in: liveRecords,
            defaultOutputObjectID: previousDefault.objectID
        ) else {
            return MacAudioOutputSwitchResult(
                success: false,
                title: L10n.tr("音频输出", "Audio Output", language: language),
                detail: L10n.tr("未找到该输出设备，可能已断开连接。", "That audio output device is no longer connected.", language: language),
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
