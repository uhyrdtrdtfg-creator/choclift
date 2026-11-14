import CryptoKit
import Foundation

/// Reason Sparkle cannot start or replace the running Mac host process.
public enum MacUpdateHostUnavailableReason: Equatable, Sendable {
    /// The process is not running from an `.app` bundle (e.g., CLI binary or SwiftPM test runner).
    case notAppBundle
    /// The `.app` bundle is unsigned or ad-hoc signed without an Apple Developer signing identity.
    case unsignedAppBundle
}

/// Pure-Foundation snapshot of the running Mac host bundle's packaging and code-signing state.
public struct MacUpdateHostDescriptor: Equatable, Sendable {
    public let bundlePathExtension: String
    public let isCodeSignatureValid: Bool
    public let isAdhocSigned: Bool
    public let teamIdentifier: String?
    public let shortVersion: String?
    public let buildVersion: String?

    public init(
        bundlePathExtension: String,
        isCodeSignatureValid: Bool,
        isAdhocSigned: Bool = false,
        teamIdentifier: String? = nil,
        shortVersion: String? = nil,
        buildVersion: String? = nil
    ) {
        self.bundlePathExtension = bundlePathExtension
        self.isCodeSignatureValid = isCodeSignatureValid
        self.isAdhocSigned = isAdhocSigned
        self.teamIdentifier = teamIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
    }

    public var isAppBundle: Bool {
        bundlePathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "app"
    }

    public var hasAppleSigningIdentity: Bool {
        guard isCodeSignatureValid, !isAdhocSigned else {
            return false
        }
        guard let team = teamIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !team.isEmpty else {
            return false
        }
        return true
    }

    /// Concrete reason Sparkle cannot start on this host, or `nil` when Sparkle can start normally.
    public var unavailableReason: MacUpdateHostUnavailableReason? {
        guard isAppBundle else {
            return .notAppBundle
        }
        guard hasAppleSigningIdentity else {
            return .unsignedAppBundle
        }
        return nil
    }

    /// Check for Updates is enabled whenever the host is an `.app` bundle, paired or not.
    public var canCheckForUpdates: Bool {
        isAppBundle
    }

    /// Sparkle (including automatic scheduled checks) starts whenever the host is a signed `.app` bundle, paired or not.
    public var canStartSparkleUpdater: Bool {
        unavailableReason == nil
    }
}

/// Pure-Foundation presentation snapshot for the Settings card and menus, independent of companion pairing state.
public struct MacUpdateStatusPresentation: Equatable, Sendable {
    public let canCheckForUpdates: Bool
    public let startsAutomaticChecksOnLaunch: Bool
    public let menuStatusText: String?
    public let cardStatusTitle: String?
    public let cardStatusDetail: String?
    public let isUpToDate: Bool
    public let isFailure: Bool

    public init(
        canCheckForUpdates: Bool,
        startsAutomaticChecksOnLaunch: Bool,
        menuStatusText: String?,
        cardStatusTitle: String?,
        cardStatusDetail: String?,
        isUpToDate: Bool,
        isFailure: Bool
    ) {
        self.canCheckForUpdates = canCheckForUpdates
        self.startsAutomaticChecksOnLaunch = startsAutomaticChecksOnLaunch
        self.menuStatusText = menuStatusText
        self.cardStatusTitle = cardStatusTitle
        self.cardStatusDetail = cardStatusDetail
        self.isUpToDate = isUpToDate
        self.isFailure = isFailure
    }
}

/// Discrete outcome of a Sparkle update check on macOS.
/// Failed outcomes (`hostCannotUpdate`, `feedUnreachable`, `signatureMismatch`, `checkFailed`) are strictly distinct
/// from `alreadyCurrent` so a failed or unavailable check never claims the app is up to date.
public enum MacUpdateCheckResult: Equatable, Sendable {
    /// A newer valid update was found in the appcast feed.
    case updateFound(shortVersion: String, buildVersion: String?)
    /// The appcast feed was fetched and verified, and the running build is already current (or newer).
    case alreadyCurrent(shortVersion: String?, buildVersion: String?)
    /// Sparkle cannot start because the running host is unsigned or not packaged in an `.app` bundle.
    case hostCannotUpdate(reason: MacUpdateHostUnavailableReason)
    /// The appcast feed or archive could not be reached, returned an HTTP/network error, failed XML parsing, or contained no valid macOS items.
    case feedUnreachable(detail: String?)
    /// Cryptographic Ed25519 / signing validation failed on the feed, enclosure, or downloaded archive.
    case signatureMismatch(detail: String?)
    /// Any other non-up-to-date Sparkle error (e.g., read-only volume, translocated bundle, OS/hardware incompatibility, or installer failure).
    case checkFailed(detail: String?)

    /// True if and only if the check succeeded and confirmed the app is current.
    public var isUpToDate: Bool {
        if case .alreadyCurrent = self {
            return true
        }
        return false
    }

    /// True when the check ended in a failure or host-unavailable state rather than finding an update or confirming currency.
    public var isFailure: Bool {
        switch self {
        case .updateFound, .alreadyCurrent:
            return false
        case .hostCannotUpdate, .feedUnreachable, .signatureMismatch, .checkFailed:
            return true
        }
    }

    public var sfSymbol: String {
        switch self {
        case .updateFound:
            return "arrow.down.circle.fill"
        case .alreadyCurrent:
            return "checkmark.circle.fill"
        case .hostCannotUpdate(let reason):
            switch reason {
            case .unsignedAppBundle:
                return "exclamationmark.shield.fill"
            case .notAppBundle:
                return "exclamationmark.triangle.fill"
            }
        case .feedUnreachable:
            return "wifi.exclamationmark"
        case .signatureMismatch:
            return "xmark.shield.fill"
        case .checkFailed:
            return "exclamationmark.triangle.fill"
        }
    }

    public func title(in language: AppLanguage = .system) -> String {
        switch self {
        case .updateFound(let shortVersion, let buildVersion):
            let badge = MacUpdateConfiguration.formattedVersionBadge(
                shortVersion: shortVersion,
                buildVersion: buildVersion
            )
            return L10n.tr("发现新版本 \(badge)", "Update Available: \(badge)", language: language)
        case .alreadyCurrent(let shortVersion, let buildVersion):
            let hasShort = !(shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let hasBuild = !(buildVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            if hasShort || hasBuild {
                let badge = MacUpdateConfiguration.formattedVersionBadge(
                    shortVersion: shortVersion,
                    buildVersion: buildVersion
                )
                return L10n.tr("已是最新版本（\(badge)）", "Up to Date (\(badge))", language: language)
            }
            return L10n.tr("已是最新版本", "Up to Date", language: language)
        case .hostCannotUpdate(let reason):
            switch reason {
            case .unsignedAppBundle:
                return L10n.tr(
                    "当前应用包未签名，Sparkle 无法启动更新检查。",
                    "Sparkle cannot start because this app bundle is unsigned.",
                    language: language
                )
            case .notAppBundle:
                return L10n.tr(
                    "当前未在应用包中运行，Sparkle 无法启动更新检查。",
                    "Sparkle cannot start because Choclift is not running in an app bundle.",
                    language: language
                )
            }
        case .feedUnreachable:
            return L10n.tr("无法连接更新源", "Update Feed Unreachable", language: language)
        case .signatureMismatch:
            return L10n.tr("更新签名校验失败", "Update Signature Mismatch", language: language)
        case .checkFailed:
            return L10n.tr("检查更新失败", "Update Check Failed", language: language)
        }
    }

    public func detailText(in language: AppLanguage = .system) -> String? {
        switch self {
        case .updateFound:
            return L10n.tr(
                "已从更新源检测到可用新版本。",
                "A newer release is available from the update feed.",
                language: language
            )
        case .alreadyCurrent:
            return nil
        case .hostCannotUpdate(let reason):
            switch reason {
            case .unsignedAppBundle:
                return L10n.tr(
                    "未签名的本地构建无法替换自身，请打开已签名的 /Applications/Choclift.app 检查并安装更新。",
                    "Unsigned local builds cannot replace themselves. Open the signed /Applications/Choclift.app to install updates.",
                    language: language
                )
            case .notAppBundle:
                return L10n.tr(
                    "请从已签名的 /Applications/Choclift.app 应用包启动以检查并安装更新。",
                    "Launch the signed /Applications/Choclift.app bundle to check for and install updates.",
                    language: language
                )
            }
        case .feedUnreachable(let detail):
            let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty
                ? L10n.tr(
                    "无法获取或解析 appcast.xml，请检查网络连接后重试。",
                    "Could not fetch or parse appcast.xml. Check your network connection and try again.",
                    language: language
                )
                : trimmed
        case .signatureMismatch(let detail):
            let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty
                ? L10n.tr(
                    "更新包的 Ed25519 签名与内置公钥 SUPublicEDKey 不匹配，已拒绝安装。",
                    "Update Ed25519 signature did not match SUPublicEDKey and was rejected.",
                    language: language
                )
                : trimmed
        case .checkFailed(let detail):
            let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty
                ? L10n.tr(
                    "未能完成更新检查，请使用已公证的 /Applications/Choclift.app 后重试。",
                    "Could not complete the update check. Make sure you are running /Applications/Choclift.app and try again.",
                    language: language
                )
                : trimmed
        }
    }

    /// Concise single-line status string surfaced in menus and menu-bar popovers, preserving specific error details.
    public func statusText(in language: AppLanguage = .system) -> String {
        switch self {
        case .updateFound, .alreadyCurrent, .hostCannotUpdate:
            return title(in: language)
        case .feedUnreachable(let detail),
             .signatureMismatch(let detail),
             .checkFailed(let detail):
            let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else {
                return title(in: language)
            }
            return L10n.tr(
                "\(title(in: language))：\(trimmed)",
                "\(title(in: language)): \(trimmed)",
                language: language
            )
        }
    }
}

/// Observable lifecycle state of Sparkle update checks in ChocliftMac.
public enum MacUpdateCheckState: Equatable, Sendable {
    case idle
    case checking
    case completed(result: MacUpdateCheckResult, checkedAt: Date)

    public var isChecking: Bool {
        if case .checking = self {
            return true
        }
        return false
    }

    public var result: MacUpdateCheckResult? {
        if case .completed(let result, _) = self {
            return result
        }
        return nil
    }

    public var checkedAt: Date? {
        if case .completed(_, let date) = self {
            return date
        }
        return nil
    }

    public func checkingTitle(in language: AppLanguage = .system) -> String {
        L10n.tr("正在检查更新…", "Checking for updates…", language: language)
    }

    public func menuStatusLine(in language: AppLanguage = .system) -> String? {
        switch self {
        case .idle:
            return nil
        case .checking:
            return checkingTitle(in: language)
        case .completed(let result, _):
            return result.statusText(in: language)
        }
    }
}

/// Pure-Foundation mirror of Sparkle's `SPUNoUpdateFoundReason` raw values.
public enum SparkleNoUpdateReason: Int, Sendable {
    case unknown = 0
    case onLatestVersion = 1
    case onNewerThanLatestVersion = 2
    case systemIsTooOld = 3
    case systemIsTooNew = 4
    case hardwareDoesNotSupportARM64 = 5
}

/// Pure-Foundation snapshot of an `SUAppcastItem` for deterministic signature and outcome evaluation.
public struct SparkleAppcastItemSnapshot: Equatable, Sendable {
    public let shortVersion: String?
    public let buildVersion: String?
    public let hasEnclosureURL: Bool
    public let isInformationOnly: Bool
    public let edSignatureBase64: String?
    public let feedSigningValidationFailed: Bool

    public init(
        shortVersion: String?,
        buildVersion: String?,
        hasEnclosureURL: Bool = true,
        isInformationOnly: Bool = false,
        edSignatureBase64: String?,
        feedSigningValidationFailed: Bool = false
    ) {
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.hasEnclosureURL = hasEnclosureURL
        self.isInformationOnly = isInformationOnly
        self.edSignatureBase64 = edSignatureBase64
        self.feedSigningValidationFailed = feedSigningValidationFailed
    }
}

/// Value-type state machine driving `MacSparkleUpdaterService` across manual and background Sparkle update cycles.
public struct MacUpdateCheckStateMachine: Equatable, Sendable {
    public private(set) var state: MacUpdateCheckState = .idle
    private var previousSettledState: MacUpdateCheckState?
    private var recordedCycleOutcome: Bool = false

    public init(initialState: MacUpdateCheckState = .idle) {
        self.state = initialState
        if case .completed = initialState {
            self.previousSettledState = initialState
        }
    }

    public mutating func beginCheck() {
        if case .completed = state {
            previousSettledState = state
        }
        recordedCycleOutcome = false
        state = .checking
    }

    @discardableResult
    public mutating func recordHostUnavailable(
        _ reason: MacUpdateHostUnavailableReason,
        now: Date = Date()
    ) -> MacUpdateCheckResult {
        let result = MacUpdateCheckResult.hostCannotUpdate(reason: reason)
        let next = MacUpdateCheckState.completed(result: result, checkedAt: now)
        state = next
        previousSettledState = next
        recordedCycleOutcome = true
        return result
    }

    @discardableResult
    public mutating func recordFoundUpdate(
        _ item: SparkleAppcastItemSnapshot,
        now: Date = Date()
    ) -> MacUpdateCheckResult {
        let result = MacUpdateConfiguration.classifyFoundUpdate(item)
        let next = MacUpdateCheckState.completed(result: result, checkedAt: now)
        state = next
        previousSettledState = next
        recordedCycleOutcome = true
        return result
    }

    @discardableResult
    public mutating func recordNoUpdate(
        error: NSError,
        latestItem: SparkleAppcastItemSnapshot?,
        fallbackHostShortVersion: String? = nil,
        fallbackHostBuildVersion: String? = nil,
        now: Date = Date()
    ) -> MacUpdateCheckResult {
        let result = MacUpdateConfiguration.classifyNoUpdate(
            error: error,
            latestItem: latestItem,
            fallbackHostShortVersion: fallbackHostShortVersion,
            fallbackHostBuildVersion: fallbackHostBuildVersion
        )
        let next = MacUpdateCheckState.completed(result: result, checkedAt: now)
        state = next
        previousSettledState = next
        recordedCycleOutcome = true
        return result
    }

    @discardableResult
    public mutating func recordError(
        _ error: NSError,
        latestItem: SparkleAppcastItemSnapshot? = nil,
        fallbackHostShortVersion: String? = nil,
        fallbackHostBuildVersion: String? = nil,
        now: Date = Date()
    ) -> MacUpdateCheckResult? {
        if MacUpdateConfiguration.isUserCancellationError(error) {
            if !recordedCycleOutcome {
                state = previousSettledState ?? .idle
            }
            return state.result
        }

        let result = MacUpdateConfiguration.classifyError(
            error,
            latestItem: latestItem,
            fallbackHostShortVersion: fallbackHostShortVersion,
            fallbackHostBuildVersion: fallbackHostBuildVersion
        )
        let next = MacUpdateCheckState.completed(result: result, checkedAt: now)
        state = next
        previousSettledState = next
        recordedCycleOutcome = true
        return result
    }

    public mutating func finishCycle(
        error: NSError?,
        latestItem: SparkleAppcastItemSnapshot? = nil,
        fallbackHostShortVersion: String? = nil,
        fallbackHostBuildVersion: String? = nil,
        now: Date = Date()
    ) {
        if let error {
            // Avoid overwriting an already-classified SUNoUpdateError if finishCycle lacks the item snapshot.
            if recordedCycleOutcome,
               error.domain == MacUpdateConfiguration.sparkleErrorDomain,
               error.code == MacUpdateConfiguration.SparkleErrorCode.noUpdate {
                return
            }
            _ = recordError(
                error,
                latestItem: latestItem,
                fallbackHostShortVersion: fallbackHostShortVersion,
                fallbackHostBuildVersion: fallbackHostBuildVersion,
                now: now
            )
        } else if !recordedCycleOutcome, state.isChecking {
            state = previousSettledState ?? .idle
        }
    }
}

/// Pure-Foundation configuration and validation rules for Mac in-app Sparkle updates.
/// Kept free of `Sparkle` framework imports so `ChocliftCore` builds identically across macOS, iOS, watchOS, and `swift test`.
public enum MacUpdateConfiguration {
    /// Public Sparkle appcast URL updated on every release commit by `.github/workflows/release.yml`
    /// (`macuhy/macos-app-release-kit/.github/workflows/release-reusable.yml`).
    public static let feedURLString: String = ChocliftDefaults.macSparkleFeedURLString
    public static let feedURL: URL = ChocliftDefaults.macSparkleFeedURL

    /// Daily background check interval in seconds (24 hours).
    public static let scheduledCheckInterval: Int = ChocliftDefaults.macSparkleScheduledCheckInterval

    /// Automatic background update checks enabled by default.
    public static let enableAutomaticChecks: Bool = true

    /// Published `Choclift.zip` archives are Developer ID signed, Hardened Runtime enabled, Apple notarized & stapled,
    /// symlink-preserving (`zip -r -y`), and EdDSA signed via `sign_update`, so Sparkle automatic updates are supported.
    public static let allowsAutomaticUpdates: Bool = true

    /// Base64-encoded 32-byte Ed25519 public key corresponding to the release workflow's `SPARKLE_PRIVATE_KEY`.
    public static let publicEDKey: String = "sW8VDD67w99pj0oQLD8p5nIWgkEzM2FV/sBbmnu5vxw="

    // MARK: - Sparkle Error & UserInfo Constants

    public static let sparkleErrorDomain = "SUSparkleErrorDomain"
    public static let noUpdateFoundReasonKey = "SUNoUpdateFoundReason"
    public static let latestAppcastItemFoundKey = "SULatestAppcastItemFound"
    public static let noUpdateFoundUserInitiatedKey = "SUNoUpdateUserInitiated"
    public static let enclosureDictionaryKey = "enclosure"
    public static let edSignatureAttributeKey = "sparkle:edSignature"

    public enum SparkleErrorCode {
        public static let noPublicDSAFound = 1
        public static let insufficientSigning = 2
        public static let insecureFeedURL = 3
        public static let invalidFeedURL = 4
        public static let invalidUpdater = 5
        public static let invalidHostBundleIdentifier = 6
        public static let invalidHostVersion = 7

        public static let appcastParse = 1000
        public static let noUpdate = 1001
        public static let appcast = 1002
        public static let runningFromDiskImage = 1003
        public static let resumeAppcast = 1004
        public static let runningTranslocated = 1005

        public static let temporaryDirectory = 2000
        public static let download = 2001

        public static let unarchiving = 3000
        public static let signature = 3001
        public static let validation = 3002

        public static let fileCopyFailure = 4000
        public static let authenticationFailure = 4001
        public static let installation = 4005
        public static let installationCanceled = 4007
        public static let installationAuthorizeLater = 4008
        public static let installationWriteNoPermission = 4012
    }

    // MARK: - Host Eligibility & Presentation Evaluation

    /// Builds the initial `MacUpdateCheckStateMachine` for a running Mac host before any user check is triggered.
    /// Signed `.app` bundles start in `.idle` (ready for automatic & manual checks before pairing);
    /// unsigned `.app` bundles and non-`.app` executables immediately surface the concrete startup reason.
    public static func initialStateMachine(
        for host: MacUpdateHostDescriptor,
        now: Date = Date()
    ) -> MacUpdateCheckStateMachine {
        var machine = MacUpdateCheckStateMachine()
        if let reason = host.unavailableReason {
            machine.recordHostUnavailable(reason, now: now)
        }
        return machine
    }

    /// Evaluates how update controls and status text render in the Settings card and menus.
    /// Companion pairing counts (`pairedDeviceCount`, `connectedCompanionCount`) never gate `canCheckForUpdates`,
    /// never gate automatic checks, and never change status text.
    public static func statusPresentation(
        host: MacUpdateHostDescriptor,
        state: MacUpdateCheckState,
        pairedDeviceCount: Int = 0,
        connectedCompanionCount: Int = 0,
        language: AppLanguage = .system
    ) -> MacUpdateStatusPresentation {
        _ = (pairedDeviceCount, connectedCompanionCount)

        let cardTitle: String?
        let cardDetail: String?
        switch state {
        case .idle:
            cardTitle = nil
            cardDetail = nil
        case .checking:
            cardTitle = state.checkingTitle(in: language)
            cardDetail = nil
        case .completed(let result, _):
            cardTitle = result.title(in: language)
            cardDetail = result.detailText(in: language)
        }

        return MacUpdateStatusPresentation(
            canCheckForUpdates: host.canCheckForUpdates,
            startsAutomaticChecksOnLaunch: host.canStartSparkleUpdater && enableAutomaticChecks,
            menuStatusText: state.menuStatusLine(in: language),
            cardStatusTitle: cardTitle,
            cardStatusDetail: cardDetail,
            isUpToDate: state.result?.isUpToDate ?? false,
            isFailure: state.result?.isFailure ?? false
        )
    }

    // MARK: - Info.plist Keys

    public static let feedURLInfoKey = "SUFeedURL"
    public static let publicEDKeyInfoKey = "SUPublicEDKey"
    public static let enableAutomaticChecksInfoKey = "SUEnableAutomaticChecks"
    public static let scheduledCheckIntervalInfoKey = "SUScheduledCheckInterval"
    public static let allowsAutomaticUpdatesInfoKey = "SUAllowsAutomaticUpdates"

    private static let forbiddenPrivateKeyMarkers: Set<String> = [
        "SUPrivateEDKey",
        "SPARKLE_PRIVATE_KEY",
        "SparklePrivateKey"
    ]

    // MARK: - Localized Labels

    public static func checkForUpdatesMenuTitle(in language: AppLanguage = .system) -> String {
        L10n.tr("检查更新…", "Check for Updates…", language: language)
    }

    public static func softwareUpdatesSectionTitle(in language: AppLanguage = .system) -> String {
        L10n.tr("软件更新", "Software Updates", language: language)
    }

    public static func automaticChecksToggleTitle(in language: AppLanguage = .system) -> String {
        L10n.tr("自动检查更新", "Automatically Check for Updates", language: language)
    }

    public static func formattedVersionBadge(shortVersion: String?, buildVersion: String?) -> String {
        let trimmedShort = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedBuild = buildVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (!trimmedShort.isEmpty, !trimmedBuild.isEmpty) {
        case (true, true):
            return "v\(trimmedShort) (\(trimmedBuild))"
        case (true, false):
            return "v\(trimmedShort)"
        case (false, true):
            return "Build \(trimmedBuild)"
        case (false, false):
            return "v1.0"
        }
    }

    // MARK: - Info.plist Validation

    /// Validates a parsed `Apps/ChocliftMac/Info.plist` dictionary against Choclift's Sparkle contract.
    /// Returns an empty array when valid, or human-readable violation strings otherwise.
    public static func validateMacInfoPlist(_ plist: [String: Any]) -> [String] {
        var issues: [String] = []

        for key in plist.keys where forbiddenPrivateKeyMarkers.contains(key) || key.localizedCaseInsensitiveContains("private") {
            issues.append("Forbidden private key entry in Info.plist: \(key)")
        }

        if let rawFeed = plist[feedURLInfoKey] as? String {
            if rawFeed != feedURLString {
                issues.append("Expected \(feedURLInfoKey) == \(feedURLString), got \(rawFeed)")
            }
            if let parsed = URL(string: rawFeed) {
                if parsed.scheme?.lowercased() != "https" {
                    issues.append("\(feedURLInfoKey) must use https scheme")
                }
            } else {
                issues.append("\(feedURLInfoKey) is not a valid URL")
            }
        } else {
            issues.append("Missing \(feedURLInfoKey)")
        }

        if let pubKey = plist[publicEDKeyInfoKey] as? String {
            if pubKey != publicEDKey {
                issues.append("Unexpected \(publicEDKeyInfoKey): \(pubKey)")
            }
            if let decoded = Data(base64Encoded: pubKey) {
                if decoded.count != 32 {
                    issues.append("\(publicEDKeyInfoKey) must decode to 32-byte Ed25519 public key, got \(decoded.count) bytes")
                }
            } else {
                issues.append("\(publicEDKeyInfoKey) is not valid base64")
            }
        } else {
            issues.append("Missing \(publicEDKeyInfoKey)")
        }

        if let autoChecks = plist[enableAutomaticChecksInfoKey] as? Bool {
            if autoChecks != enableAutomaticChecks {
                issues.append("Expected \(enableAutomaticChecksInfoKey) == \(enableAutomaticChecks), got \(autoChecks)")
            }
        } else {
            issues.append("Missing Bool \(enableAutomaticChecksInfoKey)")
        }

        if let interval = plist[scheduledCheckIntervalInfoKey] as? Int {
            if interval != scheduledCheckInterval {
                issues.append("Expected \(scheduledCheckIntervalInfoKey) == \(scheduledCheckInterval), got \(interval)")
            }
        } else {
            issues.append("Missing Int \(scheduledCheckIntervalInfoKey)")
        }

        if let allowsAuto = plist[allowsAutomaticUpdatesInfoKey] as? Bool {
            if allowsAuto != allowsAutomaticUpdates {
                issues.append("Expected \(allowsAutomaticUpdatesInfoKey) == \(allowsAutomaticUpdates), got \(allowsAuto)")
            }
        } else {
            issues.append("Missing Bool \(allowsAutomaticUpdatesInfoKey)")
        }

        if (plist["SURequireSignedFeed"] as? Bool) == true {
            issues.append("SURequireSignedFeed must not be true because update_appcast.py signs enclosures rather than the XML feed")
        }

        return issues
    }

    // MARK: - Ed25519 Signature & Enclosure Validation

    /// Validates that an appcast item carries a well-formed 64-byte Ed25519 signature (`sparkle:edSignature`)
    /// whenever it represents a downloadable update, and that signed-feed validation has not failed.
    /// Returns `nil` when valid, or a human-readable failure reason otherwise.
    public static func validateEnclosureSignature(of snapshot: SparkleAppcastItemSnapshot) -> String? {
        if snapshot.feedSigningValidationFailed {
            return "Appcast feed signature validation failed."
        }
        guard !snapshot.isInformationOnly else {
            return nil
        }
        guard snapshot.hasEnclosureURL else {
            return "Appcast item is missing an enclosure download URL."
        }
        let trimmedSig = snapshot.edSignatureBase64?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedSig.isEmpty else {
            return "Appcast enclosure is missing required sparkle:edSignature."
        }
        guard let decoded = Data(base64Encoded: trimmedSig), decoded.count == 64 else {
            return "Appcast enclosure sparkle:edSignature is malformed (expected 64-byte Ed25519 signature)."
        }
        return nil
    }

    /// Verifies raw archive bytes against a base64-encoded 64-byte Ed25519 signature and 32-byte `SUPublicEDKey`.
    public static func isValidEd25519Signature(
        _ signatureBase64: String,
        for archiveData: Data,
        publicKeyBase64: String = publicEDKey
    ) -> Bool {
        let cleanSig = signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKey = publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let keyData = Data(base64Encoded: cleanKey), keyData.count == 32,
              let sigData = Data(base64Encoded: cleanSig), sigData.count == 64,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            return false
        }
        return publicKey.isValidSignature(sigData, for: archiveData)
    }

    /// Returns `nil` when the archive matches `SUPublicEDKey`, or `.signatureMismatch` if verification fails.
    public static func verifyArchiveSignature(
        archiveData: Data,
        signatureBase64: String,
        publicKeyBase64: String = publicEDKey
    ) -> MacUpdateCheckResult? {
        if isValidEd25519Signature(signatureBase64, for: archiveData, publicKeyBase64: publicKeyBase64) {
            return nil
        }
        return .signatureMismatch(
            detail: "Update Ed25519 signature did not match SUPublicEDKey and was rejected."
        )
    }

    // MARK: - Sparkle Outcome Classification

    public static func isUserCancellationError(_ error: NSError) -> Bool {
        for candidate in flattenedErrorChain(from: error) {
            if candidate.domain == sparkleErrorDomain,
               candidate.code == SparkleErrorCode.installationCanceled
                || candidate.code == SparkleErrorCode.installationAuthorizeLater {
                return true
            }
            if candidate.domain == NSURLErrorDomain, candidate.code == NSURLErrorCancelled {
                return true
            }
        }
        return false
    }

    public static func classifyFoundUpdate(_ snapshot: SparkleAppcastItemSnapshot) -> MacUpdateCheckResult {
        if let issue = validateEnclosureSignature(of: snapshot) {
            if !snapshot.isInformationOnly && !snapshot.hasEnclosureURL {
                return .feedUnreachable(detail: issue)
            }
            return .signatureMismatch(detail: issue)
        }
        let build = nonEmptyTrimmed(snapshot.buildVersion)
        let short = nonEmptyTrimmed(snapshot.shortVersion) ?? build ?? "1.0"
        return .updateFound(shortVersion: short, buildVersion: build)
    }

    public static func classifyNoUpdate(
        error: NSError,
        latestItem: SparkleAppcastItemSnapshot? = nil,
        fallbackHostShortVersion: String? = nil,
        fallbackHostBuildVersion: String? = nil
    ) -> MacUpdateCheckResult {
        let resolvedItem = latestItem ?? (error.userInfo[latestAppcastItemFoundKey] as? SparkleAppcastItemSnapshot)
        guard let item = resolvedItem else {
            // Sparkle emits SUNoUpdateError with nil latestItem when an XML response contains zero <item> entries.
            // Never report an empty or non-appcast XML payload as up to date.
            return .feedUnreachable(detail: nil)
        }

        if let issue = validateEnclosureSignature(of: item) {
            if !item.isInformationOnly && !item.hasEnclosureURL {
                return .feedUnreachable(detail: issue)
            }
            return .signatureMismatch(detail: issue)
        }

        let rawReason: Int? = {
            if let num = error.userInfo[noUpdateFoundReasonKey] as? NSNumber {
                return num.intValue
            }
            return error.userInfo[noUpdateFoundReasonKey] as? Int
        }()
        let reason = rawReason.flatMap(SparkleNoUpdateReason.init(rawValue:)) ?? .unknown

        switch reason {
        case .onLatestVersion, .onNewerThanLatestVersion:
            let short = nonEmptyTrimmed(fallbackHostShortVersion) ?? nonEmptyTrimmed(item.shortVersion)
            let build = nonEmptyTrimmed(fallbackHostBuildVersion) ?? nonEmptyTrimmed(item.buildVersion)
            return .alreadyCurrent(shortVersion: short, buildVersion: build)
        case .systemIsTooOld, .systemIsTooNew, .hardwareDoesNotSupportARM64, .unknown:
            return .checkFailed(detail: sanitizedNonUpToDateDetail(from: error))
        }
    }

    public static func classifyError(
        _ error: NSError,
        latestItem: SparkleAppcastItemSnapshot? = nil,
        fallbackHostShortVersion: String? = nil,
        fallbackHostBuildVersion: String? = nil
    ) -> MacUpdateCheckResult {
        if error.domain == sparkleErrorDomain, error.code == SparkleErrorCode.noUpdate {
            return classifyNoUpdate(
                error: error,
                latestItem: latestItem,
                fallbackHostShortVersion: fallbackHostShortVersion,
                fallbackHostBuildVersion: fallbackHostBuildVersion
            )
        }

        let chain = flattenedErrorChain(from: error)
        if isHostUnsignedErrorChain(chain) {
            return .hostCannotUpdate(reason: .unsignedAppBundle)
        }
        if chain.contains(where: isSignatureFailureError) {
            return .signatureMismatch(detail: bestErrorDetail(from: error))
        }
        if chain.contains(where: isFeedReachabilityOrParseError) {
            return .feedUnreachable(detail: bestErrorDetail(from: error))
        }
        return .checkFailed(detail: nonReplaceableHostDetail(from: chain, rootError: error) ?? bestErrorDetail(from: error))
    }

    /// Extracts the most informative human-readable diagnostic from a potentially nested Sparkle `NSError` chain,
    /// stripping generic outer boilerplate and ensuring "up to date" text never leaks into failure details.
    public static func bestErrorDetail(from error: NSError) -> String? {
        let chain = flattenedErrorChain(from: error)
        var specificCandidates: [String] = []
        var fallbackCandidates: [String] = []

        for candidate in chain {
            let texts: [String?] = [
                candidate.userInfo[NSLocalizedDescriptionKey] as? String ?? candidate.localizedDescription,
                candidate.localizedFailureReason,
                candidate.localizedRecoverySuggestion
            ]
            for raw in texts {
                guard let cleaned = nonEmptyTrimmed(raw), !containsUpToDateClaim(cleaned) else {
                    continue
                }
                if isGenericBoilerplateMessage(cleaned) {
                    if !fallbackCandidates.contains(cleaned) {
                        fallbackCandidates.append(cleaned)
                    }
                } else {
                    if !specificCandidates.contains(cleaned) {
                        specificCandidates.append(cleaned)
                    }
                }
            }
        }

        if let preferred = specificCandidates.first(where: { !isRawFoundationFallback($0) }) {
            return preferred
        }
        return specificCandidates.first ?? fallbackCandidates.first
    }

    // MARK: - Private Classification Helpers

    private static func flattenedErrorChain(from root: NSError) -> [NSError] {
        var result: [NSError] = []
        var queue: [NSError] = [root]
        var seen = Set<ObjectIdentifier>()

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let id = ObjectIdentifier(current)
            guard seen.insert(id).inserted else { continue }
            result.append(current)

            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                queue.append(underlying)
            }
            if #available(macOS 11.3, iOS 14.5, watchOS 7.4, *),
               let multiple = current.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
                queue.append(contentsOf: multiple)
            }
        }
        return result
    }

    private static func isSignatureFailureError(_ error: NSError) -> Bool {
        if error.domain == sparkleErrorDomain {
            switch error.code {
            case SparkleErrorCode.noPublicDSAFound,
                 SparkleErrorCode.insufficientSigning,
                 SparkleErrorCode.signature:
                return true
            case SparkleErrorCode.validation:
                let desc = error.localizedDescription.lowercased()
                if desc.contains("no suitable bundle is found") {
                    return false
                }
                return true
            default:
                let combined = [
                    error.localizedDescription,
                    error.localizedFailureReason,
                    error.localizedRecoverySuggestion
                ]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")

                let markers = [
                    "improperly signed",
                    "eddsa",
                    "ed25519",
                    "dsa signature",
                    "signature verification",
                    "signature validation",
                    "signature does not match",
                    "code signing",
                    "supublicedkey"
                ]
                if markers.contains(where: { combined.contains($0) }) {
                    return true
                }
            }
        }

        // Security.framework code signing OSStatus range (errSecCS* around -67080 ... -67000).
        if error.domain == NSOSStatusErrorDomain, (-67080 ... -67000).contains(error.code) {
            return true
        }
        return false
    }

    private static func isFeedReachabilityOrParseError(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain {
            return error.code != NSURLErrorCancelled
        }
        if error.domain == "kCFErrorDomainCFNetwork" || error.domain == XMLParser.errorDomain {
            return true
        }
        if error.domain == NSPOSIXErrorDomain {
            let networkPOSIXCodes: Set<Int> = [
                Int(ENETDOWN),
                Int(ENETUNREACH),
                Int(ECONNABORTED),
                Int(ECONNRESET),
                Int(ENOBUFS),
                Int(ENOTCONN),
                Int(ETIMEDOUT),
                Int(ECONNREFUSED),
                Int(EHOSTDOWN),
                Int(EHOSTUNREACH)
            ]
            return networkPOSIXCodes.contains(error.code)
        }
        if error.domain == sparkleErrorDomain {
            switch error.code {
            case SparkleErrorCode.insecureFeedURL,
                 SparkleErrorCode.invalidFeedURL,
                 SparkleErrorCode.appcastParse,
                 SparkleErrorCode.appcast,
                 SparkleErrorCode.resumeAppcast,
                 SparkleErrorCode.download:
                return true
            default:
                return false
            }
        }
        return false
    }

    private static func sanitizedNonUpToDateDetail(from error: NSError) -> String? {
        bestErrorDetail(from: error)
    }

    private static func containsUpToDateClaim(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("up to date")
            || lower.contains("up-to-date")
            || lower.contains("newest version")
            || lower.contains("已是最新")
    }

    private static func isHostUnsignedErrorChain(_ chain: [NSError]) -> Bool {
        let combinedChainText = chain
            .flatMap { [$0.localizedDescription, $0.localizedFailureReason, $0.localizedRecoverySuggestion] }
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        let hostUnsignedMarkers = [
            "original app is not code signed",
            "bundle is not code signed",
            "team identifier could not be retrieved from the original app"
        ]
        if hostUnsignedMarkers.contains(where: { combinedChainText.contains($0) }) {
            return true
        }

        let updateTargetMarkers = [
            "new version of the app is not signed",
            "download archive is not apple code signed",
            "update is not code signed",
            "eddsa",
            "ed25519"
        ]
        if !updateTargetMarkers.contains(where: { combinedChainText.contains($0) }),
           chain.contains(where: { $0.domain == NSOSStatusErrorDomain && $0.code == -67062 }) {
            return true
        }

        return false
    }

    private static func nonReplaceableHostDetail(from chain: [NSError], rootError: NSError) -> String? {
        let extracted = bestErrorDetail(from: rootError)
        let hasSpecificDetail = extracted.map { !isGenericBoilerplateMessage($0) && !isRawFoundationFallback($0) } ?? false
        if hasSpecificDetail {
            return extracted
        }

        for candidate in chain {
            if candidate.domain == sparkleErrorDomain {
                switch candidate.code {
                case SparkleErrorCode.runningTranslocated:
                    return "This copy is running under macOS App Translocation and cannot replace itself. Move Choclift.app to /Applications and relaunch."
                case SparkleErrorCode.runningFromDiskImage:
                    return "This copy is running from a read-only disk image and cannot replace itself. Move Choclift.app to /Applications and relaunch."
                case SparkleErrorCode.installationWriteNoPermission,
                     SparkleErrorCode.fileCopyFailure,
                     SparkleErrorCode.authenticationFailure:
                    return "This copy of Choclift.app does not have permission to replace itself. Install and launch /Applications/Choclift.app."
                default:
                    break
                }
            }
            if candidate.domain == NSCocoaErrorDomain, candidate.code == NSFileWriteNoPermissionError {
                return "This copy of Choclift.app does not have permission to replace itself. Install and launch /Applications/Choclift.app."
            }
        }
        return extracted
    }

    private static func isGenericBoilerplateMessage(_ text: String) -> Bool {
        let lower = text.lowercased()
        let prefixes = [
            "an error occurred in retrieving update information",
            "an error occurred while installing the update",
            "an error occurred while downloading the update",
            "an error occurred while parsing the update feed",
            "an error occurred while extracting the archive",
            "an error occurred while running the updater",
            "an error occurred while starting the installer",
            "the update is improperly signed and could not be validated",
            "update error!"
        ]
        return prefixes.contains(where: { lower.hasPrefix($0) })
    }

    private static func isRawFoundationFallback(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("the operation couldn’t be completed")
            || lower.hasPrefix("the operation couldn't be completed")
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
