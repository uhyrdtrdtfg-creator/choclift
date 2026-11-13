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
        self.id = trimmedID.isEmpty ? "audio-\(audioObjectID)" : trimmedID
        self.audioObjectID = audioObjectID
        self.name = trimmedName.isEmpty ? "Audio Output (\(audioObjectID))" : trimmedName
        self.transportKind = transportKind
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
