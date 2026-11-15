import Foundation

public enum SelectionCompanionAction: String, Sendable {
    case copyToPhone = "selection.copy_to_phone"
}

extension CompanionActionCatalog {
    public static let selectionPack: [CompanionAction] = [
        CompanionAction(
            id: SelectionCompanionAction.copyToPhone.rawValue,
            titleZh: "复制选中到手机",
            titleEn: "Copy Selection to Phone",
            sfSymbol: "iphone.and.arrow.forward"
        )
    ]
}

public struct SelectionPreviewSnapshot: Codable, Equatable, Hashable, Sendable {
    public let text: String
    public let capturedAt: Date

    public init(text: String, capturedAt: Date = Date()) {
        self.text = text
        self.capturedAt = capturedAt
    }

    public var watchPreviewText: String {
        if text.count > SelectionPreviewText.watchMaxCharacters {
            return String(text.prefix(SelectionPreviewText.watchMaxCharacters))
        }
        return text
    }
}

public enum SelectionPreviewText {
    public static let maxCharacters = 400
    public static let watchMaxCharacters = 80

    public static let blockedBundleIdentifiers: Set<String> = [
        "com.apple.securityagent",
        "com.apple.loginwindow",
        "com.apple.keychainaccess",
        "com.apple.passwords",
        "com.agilebits.onepassword",
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.bitwarden.desktop"
    ]

    /// Rejects nil/empty/whitespace-only selections and caps valid plain-text previews at 400 characters.
    public static func clamp(_ raw: String?) -> String? {
        guard let raw,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let capped = raw.count > maxCharacters ? String(raw.prefix(maxCharacters)) : raw
        guard !capped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return capped
    }

    /// Clamps to 400 characters first, then truncates to the first 80 characters for Apple Watch.
    public static func watchPreview(_ raw: String?) -> String? {
        guard let clamped = clamp(raw) else {
            return nil
        }
        return clamped.count > watchMaxCharacters ? String(clamped.prefix(watchMaxCharacters)) : clamped
    }

    /// Detects AX password fields and system/password-manager bundles whose selections must never leave the Mac.
    public static func isSecureElement(
        role: String?,
        subrole: String?,
        bundleIdentifier: String? = nil
    ) -> Bool {
        if let role = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !role.isEmpty,
           role.contains("securetextfield") {
            return true
        }
        if let subrole = subrole?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !subrole.isEmpty,
           subrole.contains("securetextfield") {
            return true
        }
        if let bundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !bundle.isEmpty {
            if blockedBundleIdentifiers.contains(bundle) || bundle.hasPrefix("com.agilebits.onepassword") {
                return true
            }
        }
        return false
    }
}
