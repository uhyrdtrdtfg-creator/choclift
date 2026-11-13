import Foundation

// MARK: - 1. Camera & Microphone Capture Privacy Status (Round 8)

/// Read-only privacy indicator state for the companion control strip.
/// Reports only whether the Mac's camera or microphone is currently capturing, plus the user-facing
/// app name when macOS exposes it via public CoreMediaIO / CoreAudio APIs.
/// Never carries camera frames, previews, audio samples, or shutter controls.
public struct MacPrivacyCaptureStatus: Codable, Equatable, Hashable, Sendable {
    public static let maxAppNameCharacters = 48

    public var isCameraInUse: Bool
    public var cameraAppName: String?
    public var isMicrophoneInUse: Bool
    public var microphoneAppName: String?

    public static let inactive = MacPrivacyCaptureStatus(
        isCameraInUse: false,
        cameraAppName: nil,
        isMicrophoneInUse: false,
        microphoneAppName: nil
    )

    private enum CodingKeys: String, CodingKey {
        case isCameraInUse
        case cameraAppName
        case isMicrophoneInUse
        case microphoneAppName
    }

    public init(
        isCameraInUse: Bool = false,
        cameraAppName: String? = nil,
        isMicrophoneInUse: Bool = false,
        microphoneAppName: String? = nil
    ) {
        self.isCameraInUse = isCameraInUse
        self.cameraAppName = isCameraInUse ? Self.sanitizeAppName(cameraAppName) : nil
        self.isMicrophoneInUse = isMicrophoneInUse
        self.microphoneAppName = isMicrophoneInUse ? Self.sanitizeAppName(microphoneAppName) : nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let camActive = try container.decodeIfPresent(Bool.self, forKey: .isCameraInUse) ?? false
        let micActive = try container.decodeIfPresent(Bool.self, forKey: .isMicrophoneInUse) ?? false
        let rawCamApp = try container.decodeIfPresent(String.self, forKey: .cameraAppName)
        let rawMicApp = try container.decodeIfPresent(String.self, forKey: .microphoneAppName)
        self.init(
            isCameraInUse: camActive,
            cameraAppName: rawCamApp,
            isMicrophoneInUse: micActive,
            microphoneAppName: rawMicApp
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isCameraInUse, forKey: .isCameraInUse)
        if isCameraInUse, let cleanCam = Self.sanitizeAppName(cameraAppName) {
            try container.encode(cleanCam, forKey: .cameraAppName)
        }
        try container.encode(isMicrophoneInUse, forKey: .isMicrophoneInUse)
        if isMicrophoneInUse, let cleanMic = Self.sanitizeAppName(microphoneAppName) {
            try container.encode(cleanMic, forKey: .microphoneAppName)
        }
    }

    public var isAnyCaptureActive: Bool {
        isCameraInUse || isMicrophoneInUse
    }

    /// Returns the active camera indicator text, or `nil` when the camera is idle.
    public func cameraBadgeText(in language: AppLanguage = .system) -> String? {
        guard isCameraInUse else { return nil }
        if let app = Self.sanitizeAppName(cameraAppName) {
            return L10n.tr("摄像头: \(app)", "Cam: \(app)", language: language)
        }
        return L10n.tr("摄像头使用中", "Camera In Use", language: language)
    }

    /// Returns the active microphone indicator text, or `nil` when the microphone is idle.
    public func microphoneBadgeText(in language: AppLanguage = .system) -> String? {
        guard isMicrophoneInUse else { return nil }
        if let app = Self.sanitizeAppName(microphoneAppName) {
            return L10n.tr("麦克风: \(app)", "Mic: \(app)", language: language)
        }
        return L10n.tr("麦克风使用中", "Mic In Use", language: language)
    }

    /// Read-only phone strip summary line showing whether camera or microphone is in use.
    public func stripSummaryText(in language: AppLanguage = .system) -> String {
        switch (cameraBadgeText(in: language), microphoneBadgeText(in: language)) {
        case let (cam?, mic?):
            return "\(cam) · \(mic)"
        case let (cam?, nil):
            return cam
        case let (nil, mic?):
            return mic
        case (nil, nil):
            return L10n.tr("摄像头/麦克风空闲", "Cam & Mic Idle", language: language)
        }
    }

    public static func sanitizeAppName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if cleaned.count <= maxAppNameCharacters {
            return cleaned
        }
        return String(cleaned.prefix(maxAppNameCharacters - 1)) + "…"
    }
}

// MARK: - 2. Wi-Fi Current SSID Formatter (Round 8 — Current SSID Only, Fallback "Wi-Fi")

/// Read-only formatter for the Mac's current Wi-Fi SSID.
/// Never carries passwords, BSSIDs, or nearby scan results. When the SSID is unavailable
/// (Wi-Fi off, Ethernet-only Mac, unassociated, or redacted), displays `"Wi-Fi"` with no name.
public enum MacWiFiStatusFormatter {
    public static let unavailableLabel = "Wi-Fi"
    public static let maxSSIDCharacters = 64

    public static func sanitizedSSID(_ rawSSID: String?) -> String? {
        guard let rawSSID else { return nil }
        let singleLine = rawSSID
            .components(separatedBy: .controlCharacters)
            .joined()
        guard !singleLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        if singleLine.count <= maxSSIDCharacters {
            return singleLine
        }
        return String(singleLine.prefix(maxSSIDCharacters))
    }

    public static func displayText(ssid: String?) -> String {
        if let clean = sanitizedSSID(ssid) {
            return clean
        }
        return unavailableLabel
    }
}

// MARK: - 3. Mounted External Volume Filtering (Never Ejects Startup or Internal System Disks)

public struct ExternalDiskVolumeCandidate: Equatable, Hashable, Sendable {
    public let url: URL
    public let localizedName: String
    public let isRootFileSystem: Bool
    public let isInternal: Bool?
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isLocal: Bool
    public let isBrowsable: Bool

    public init(
        url: URL,
        localizedName: String? = nil,
        isRootFileSystem: Bool = false,
        isInternal: Bool? = nil,
        isRemovable: Bool = false,
        isEjectable: Bool = false,
        isLocal: Bool = true,
        isBrowsable: Bool = true
    ) {
        self.url = url
        let fallbackName = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
        let cleanedName = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.localizedName = (cleanedName?.isEmpty == false) ? cleanedName! : fallbackName
        self.isRootFileSystem = isRootFileSystem
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isLocal = isLocal
        self.isBrowsable = isBrowsable
    }
}

public enum ExternalDiskFilter {
    /// Determines whether a mounted volume is safe and eligible for "Eject external disks".
    /// Strictly excludes `/`, `isRootFileSystem`, `/System/Volumes/*`, `/Volumes/Recovery`,
    /// hidden/non-browsable system/simulator mounts, network shares, and fixed internal SSD partitions.
    public static func isEligibleExternalVolume(_ candidate: ExternalDiskVolumeCandidate) -> Bool {
        if candidate.isRootFileSystem {
            return false
        }
        if !candidate.isBrowsable || !candidate.isLocal {
            return false
        }

        let path = candidate.url.standardizedFileURL.path
        if path == "/" ||
            path == "/Volumes" ||
            path == "/Volumes/Recovery" ||
            path.hasPrefix("/System") ||
            path.hasPrefix("/private") ||
            path.hasPrefix("/Library/Developer/CoreSimulator") {
            return false
        }

        guard path.hasPrefix("/Volumes/") else {
            return false
        }

        // Fixed internal APFS volumes / partitions (not removable and not ejectable) must never be ejected.
        if candidate.isInternal == true && !candidate.isRemovable && !candidate.isEjectable {
            return false
        }

        return candidate.isRemovable || candidate.isEjectable || candidate.isInternal == false
    }

    public static func eligibleVolumes(
        from candidates: [ExternalDiskVolumeCandidate]
    ) -> [ExternalDiskVolumeCandidate] {
        var seenPaths: Set<String> = []
        var result: [ExternalDiskVolumeCandidate] = []
        for candidate in candidates where isEligibleExternalVolume(candidate) {
            let key = candidate.url.standardizedFileURL.path
            if seenPaths.insert(key).inserted {
                result.append(candidate)
            }
        }
        return result
    }
}

// MARK: - 4. Two-Tap Confirm Controller for Empty Trash & Eject External Disks (3-Second Window)

public enum Round08MaintenanceAction: String, Codable, Equatable, Hashable, Sendable {
    case emptyTrash = "maintenance.emptyTrash"
    case ejectExternalDisks = "maintenance.ejectExternalDisks"

    public func title(
        ejectableCount: Int = 0,
        compact: Bool = false,
        in language: AppLanguage = .system
    ) -> String {
        switch self {
        case .emptyTrash:
            return compact
                ? L10n.tr("清废纸篓", "Empty Trash", language: language)
                : L10n.tr("清空废纸篓", "Empty Trash", language: language)
        case .ejectExternalDisks:
            if ejectableCount > 1 {
                return compact
                    ? L10n.tr("推出 (\(ejectableCount))", "Eject (\(ejectableCount))", language: language)
                    : L10n.tr("推出外置磁盘 (\(ejectableCount))", "Eject Disks (\(ejectableCount))", language: language)
            }
            return compact
                ? L10n.tr("推出磁盘", "Eject", language: language)
                : L10n.tr("推出外置磁盘", "Eject External Disks", language: language)
        }
    }

    public func secondTapPrompt(in language: AppLanguage = .system) -> String {
        let label = title(compact: false, in: language)
        return L10n.tr(
            "3 秒内再点一次确认：\(label)",
            "Tap again within 3s: \(label)",
            language: language
        )
    }
}

public enum Round08MaintenanceTapOutcome: Equatable, Sendable {
    /// Eject External Disks was tapped when 0 external volumes were mounted: stays quiet without arming or running.
    case quietNothingToEject
    /// First tap armed the 3-second confirmation window; action MUST NOT run yet.
    case requireSecondTap(expiresAt: TimeInterval)
    /// Second tap within the 3-second window confirmed execution.
    case confirmedExecute
}

/// Shared 3-second second-tap gate wrapping `DestructiveActionConfirmGate` for Empty Trash and Eject External Disks.
public struct Round08MaintenanceConfirmController: Equatable, Sendable {
    public private(set) var gate: DestructiveActionConfirmGate

    public init(
        confirmationWindowSeconds: TimeInterval = CompanionInteractionPolicy.destructiveConfirmWindowSeconds
    ) {
        self.gate = DestructiveActionConfirmGate(confirmationWindowSeconds: confirmationWindowSeconds)
    }

    public var confirmationWindowSeconds: TimeInterval {
        gate.confirmationWindowSeconds
    }

    public func isArmed(_ action: Round08MaintenanceAction, at now: TimeInterval) -> Bool {
        gate.isArmed(targetID: action.rawValue, at: now)
    }

    public mutating func registerTap(
        action: Round08MaintenanceAction,
        ejectableVolumeCount: Int,
        at now: TimeInterval
    ) -> Round08MaintenanceTapOutcome {
        if action == .ejectExternalDisks && ejectableVolumeCount <= 0 {
            gate.disarm()
            return .quietNothingToEject
        }

        let decision = gate.registerTap(
            targetID: action.rawValue,
            isDestructive: true,
            at: now
        )
        switch decision {
        case .requireSecondTap(let expiresAt):
            return .requireSecondTap(expiresAt: expiresAt)
        case .confirmedRun, .runImmediately:
            return .confirmedExecute
        }
    }

    public mutating func expireIfNeeded(at now: TimeInterval) {
        gate.expireIfNeeded(at: now)
    }

    public mutating func disarm() {
        gate.disarm()
    }
}

// MARK: - 5. Strict Count-Only Notification Payload Validator (Round 8)

public enum MacNotificationPayloadValidationError: Error, Equatable, Sendable, LocalizedError {
    case missingCount
    case negativeCount(Int)
    case forbiddenContentField(String)
    case unexpectedField(String)

    public var errorDescription: String? {
        switch self {
        case .missingCount:
            return "Notification payload is missing required integer 'count'."
        case .negativeCount(let value):
            return "Notification count must be non-negative (got \(value))."
        case .forbiddenContentField(let field):
            return "Notification payload rejected forbidden privacy field '\(field)'."
        case .unexpectedField(let field):
            return "Notification payload rejected unexpected field '\(field)'; only 'count' is allowed."
        }
    }
}

/// Strict count-only notification wire payload validator.
///
/// Privacy rule: Only a non-negative integer `count` is permitted. Any fixture or payload containing
/// `title`, `subtitle`, `body`, `sender`, `message`, or any other extra field is rejected during decoding.
///
/// macOS 13 Public API Audit (why live system-wide Notification Center count is skipped at runtime):
/// - `UNUserNotificationCenter.current().getDeliveredNotifications(completionHandler:)` (`UserNotifications`)
///   returns notifications delivered only by the calling app (`com.choclift.mac`), not other macOS apps.
/// - `NSUserNotificationCenter.default.deliveredNotifications` (`Foundation`, deprecated macOS 11)
///   is likewise scoped strictly to the calling app.
/// - `NotificationCenter.framework` (`NCWidgetController`) provides legacy Today widgets only, with no
///   delivered-notification count API.
/// - `NSApplication.shared.dockTile.badgeLabel` (`AppKit`) reads only Choclift's own Dock tile badge.
/// Reading system-wide counts on macOS 13 would require private `com.apple.notificationcenter` SQLite/XPC access,
/// so Choclift skips live system notification counting rather than using private APIs or faking a number.
public struct MacNotificationCountPayload: Codable, Equatable, Hashable, Sendable {
    private static let forbiddenPrivacyKeys: Set<String> = [
        "title",
        "subtitle",
        "body",
        "sender",
        "author",
        "from",
        "message",
        "messages",
        "text",
        "apptext",
        "app_text",
        "appname",
        "app_name",
        "bundleid",
        "bundleidentifier",
        "summary",
        "content",
        "preview",
        "notifications",
        "items",
        "threadid"
    ]

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init(_ string: String) {
            self.stringValue = string
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    public let count: Int

    public init(count: Int) throws {
        guard count >= 0 else {
            throw MacNotificationPayloadValidationError.negativeCount(count)
        }
        self.count = count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let sortedKeys = container.allKeys.map(\.stringValue).sorted()

        for key in sortedKeys where key != "count" {
            let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if Self.forbiddenPrivacyKeys.contains(normalized) {
                throw MacNotificationPayloadValidationError.forbiddenContentField(key)
            }
            throw MacNotificationPayloadValidationError.unexpectedField(key)
        }

        let countKey = DynamicCodingKey("count")
        guard container.contains(countKey) else {
            throw MacNotificationPayloadValidationError.missingCount
        }

        let decodedCount = try container.decode(Int.self, forKey: countKey)
        guard decodedCount >= 0 else {
            throw MacNotificationPayloadValidationError.negativeCount(decodedCount)
        }
        self.count = decodedCount
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(count, forKey: DynamicCodingKey("count"))
    }

    /// Number-only display string.
    public var displayText: String {
        "\(count)"
    }
}
