import Foundation

/// Pure formatter for the frontmost Mac application label displayed on iPhone and Apple Watch.
public enum FrontmostAppLabel {
    public static let maxCharacters: Int = 40
    public static let chocliftBundleIdentifier: String = "com.choclift.mac"
    public static let chocliftBundlePrefix: String = "com.choclift."

    public static func isChocliftBundleIdentifier(
        _ bundleIdentifier: String?,
        hostBundleIdentifier: String? = chocliftBundleIdentifier
    ) -> Bool {
        guard let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return false
        }
        let lower = trimmed.lowercased()
        if lower == "com.choclift"
            || lower == chocliftBundleIdentifier
            || lower.hasPrefix(chocliftBundlePrefix) {
            return true
        }
        if let host = hostBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty,
           lower == host.lowercased() {
            return true
        }
        return false
    }

    /// Returns a single-line trimmed app name capped at 40 characters, or `nil` when empty,
    /// unknown, or when the frontmost app is Choclift itself.
    public static func format(
        appName: String?,
        bundleIdentifier: String? = nil,
        hostBundleIdentifier: String? = chocliftBundleIdentifier
    ) -> String? {
        if isChocliftBundleIdentifier(bundleIdentifier, hostBundleIdentifier: hostBundleIdentifier) {
            return nil
        }
        guard let raw = appName else {
            return nil
        }
        let collapsed = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else {
            return nil
        }
        if bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           collapsed.caseInsensitiveCompare("choclift") == .orderedSame {
            return nil
        }
        if collapsed.count > maxCharacters {
            return String(collapsed.prefix(maxCharacters))
        }
        return collapsed
    }
}
