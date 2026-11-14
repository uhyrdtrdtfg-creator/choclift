import Foundation

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
}
