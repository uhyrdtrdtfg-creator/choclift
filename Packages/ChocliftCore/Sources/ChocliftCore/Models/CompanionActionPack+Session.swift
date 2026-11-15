import Foundation

public enum SessionCompanionActionID {
    public static let hideFrontmostApp = "session.hide_frontmost_app"
}

extension CompanionActionCatalog {
    public static let sessionPack: [CompanionAction] = [
        CompanionAction(
            id: SessionCompanionActionID.hideFrontmostApp,
            titleZh: "隐藏当前应用",
            titleEn: "Hide Frontmost App",
            sfSymbol: "eye.slash"
        )
    ]
}

public struct SessionAppTarget: Equatable, Sendable {
    public var pid: Int32
    public var bundleIdentifier: String?
    public var localizedName: String?
    public var isRegular: Bool
    public var isTerminated: Bool

    public init(
        pid: Int32,
        bundleIdentifier: String?,
        localizedName: String? = nil,
        isRegular: Bool = true,
        isTerminated: Bool = false
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.isRegular = isRegular
        self.isTerminated = isTerminated
    }

    public var displayName: String {
        if let rawName = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawName.isEmpty {
            return rawName
        }
        if let rawBundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawBundle.isEmpty {
            return rawBundle
        }
        return "App"
    }
}

public enum SessionCompanionActionRouting {
    public static let chocliftBundleIdentifier = "com.choclift.mac"
    public static let chocliftBundlePrefix = "com.choclift."

    public static func isChocliftBundle(
        _ bundleIdentifier: String?,
        hostBundleIdentifier: String? = chocliftBundleIdentifier
    ) -> Bool {
        guard let raw = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return false
        }
        let lower = raw.lowercased()
        if lower == "com.choclift"
            || lower == chocliftBundleIdentifier
            || lower.hasPrefix(chocliftBundlePrefix) {
            return true
        }
        if let hostRaw = hostBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hostRaw.isEmpty,
           lower == hostRaw.lowercased() {
            return true
        }
        return false
    }

    public static func isEligibleExternalApp(
        _ candidate: SessionAppTarget,
        selfPID: Int32,
        hostBundleIdentifier: String? = chocliftBundleIdentifier
    ) -> Bool {
        guard !candidate.isTerminated,
              candidate.isRegular,
              candidate.pid > 0,
              candidate.pid != selfPID else {
            return false
        }
        guard let rawBundle = candidate.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawBundle.isEmpty else {
            return false
        }
        if rawBundle.lowercased() == "com.apple.loginwindow" {
            return false
        }
        return !isChocliftBundle(rawBundle, hostBundleIdentifier: hostBundleIdentifier)
    }

    public static func resolveHideTarget(
        frontmost: SessionAppTarget?,
        preferred: SessionAppTarget?,
        selfPID: Int32,
        hostBundleIdentifier: String? = chocliftBundleIdentifier
    ) -> SessionAppTarget? {
        if let frontBundle = frontmost?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           frontBundle.lowercased() == "com.apple.loginwindow" {
            return nil
        }
        if let frontmost,
           isEligibleExternalApp(frontmost, selfPID: selfPID, hostBundleIdentifier: hostBundleIdentifier) {
            return frontmost
        }
        if let preferred,
           isEligibleExternalApp(preferred, selfPID: selfPID, hostBundleIdentifier: hostBundleIdentifier) {
            return preferred
        }
        return nil
    }

    public static func execute(
        id: String,
        frontmost: SessionAppTarget?,
        preferred: SessionAppTarget?,
        selfPID: Int32,
        hostBundleIdentifier: String? = chocliftBundleIdentifier,
        language: AppLanguage = .system,
        hideApp: (SessionAppTarget) -> Bool
    ) -> (success: Bool, message: String) {
        guard id == SessionCompanionActionID.hideFrontmostApp else {
            return (
                false,
                L10n.tr("不支持的会话操作：\(id)", "Unsupported session action: \(id)", language: language)
            )
        }
        guard let target = resolveHideTarget(
            frontmost: frontmost,
            preferred: preferred,
            selfPID: selfPID,
            hostBundleIdentifier: hostBundleIdentifier
        ) else {
            return (
                false,
                L10n.tr("当前没有可隐藏的前台应用", "No frontmost application available to hide", language: language)
            )
        }
        let name = target.displayName
        guard hideApp(target) else {
            return (
                false,
                L10n.tr("无法隐藏 \(name)", "Could not hide \(name)", language: language)
            )
        }
        return (
            true,
            L10n.tr("已隐藏 \(name)", "Hid \(name)", language: language)
        )
    }
}
