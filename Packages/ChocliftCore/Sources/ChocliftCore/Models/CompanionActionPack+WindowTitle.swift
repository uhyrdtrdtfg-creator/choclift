import Foundation

public enum WindowTitleCompanionActionID {
    public static let copyTitle = "window.copy_title"
}

extension CompanionActionCatalog {
    public static let windowTitlePack: [CompanionAction] = [
        CompanionAction(
            id: WindowTitleCompanionActionID.copyTitle,
            titleZh: "复制窗口标题",
            titleEn: "Copy Window Title",
            sfSymbol: "text.quote"
        )
    ]
}

public enum WindowTitleClipboardText {
    public static let maxCharacters: Int = 200

    /// Trims outer whitespace/newlines, returns `nil` when blank, and caps at 200 `Character`s.
    public static func clamp(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        if trimmed.count > maxCharacters {
            return String(trimmed.prefix(maxCharacters))
        }
        return trimmed
    }
}

public struct WindowTitleAppCandidate: Equatable, Hashable, Sendable {
    public var pid: Int32
    public var bundleIdentifier: String?
    public var localizedName: String?
    public var isTerminated: Bool

    public init(
        pid: Int32,
        bundleIdentifier: String? = nil,
        localizedName: String? = nil,
        isTerminated: Bool = false
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
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

public enum WindowTitleReadResult: Equatable, Sendable {
    case noFocusedWindow
    case title(String?)
}

public enum WindowTitleCompanionRouting {
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
        _ candidate: WindowTitleAppCandidate,
        selfPID: Int32,
        hostBundleIdentifier: String? = chocliftBundleIdentifier
    ) -> Bool {
        guard !candidate.isTerminated,
              candidate.pid > 0,
              candidate.pid != selfPID else {
            return false
        }
        if let rawBundle = candidate.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawBundle.isEmpty {
            if rawBundle.lowercased() == "com.apple.loginwindow" {
                return false
            }
            if isChocliftBundle(rawBundle, hostBundleIdentifier: hostBundleIdentifier) {
                return false
            }
        }
        return true
    }

    public static func resolveTargetApp(
        frontmost: WindowTitleAppCandidate?,
        preferred: WindowTitleAppCandidate?,
        selfPID: Int32,
        hostBundleIdentifier: String? = chocliftBundleIdentifier
    ) -> WindowTitleAppCandidate? {
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
        isAccessibilityTrusted: Bool,
        frontmost: WindowTitleAppCandidate?,
        preferred: WindowTitleAppCandidate?,
        selfPID: Int32,
        hostBundleIdentifier: String? = chocliftBundleIdentifier,
        language: AppLanguage = .system,
        onRequestAccessibilityPermission: () -> Void = {},
        readFocusedWindowTitle: (WindowTitleAppCandidate) -> WindowTitleReadResult,
        writePasteboardString: (String) -> Bool
    ) -> (success: Bool, message: String) {
        guard id == WindowTitleCompanionActionID.copyTitle else {
            return (
                false,
                L10n.tr("不支持此窗口操作：\(id)", "Unsupported window action: \(id)", language: language)
            )
        }

        guard isAccessibilityTrusted else {
            onRequestAccessibilityPermission()
            return (
                false,
                L10n.tr(
                    "请在系统设置 → 辅助功能中授权 Choclift 读取窗口标题",
                    "Grant Accessibility permission in System Settings to read window titles",
                    language: language
                )
            )
        }

        guard let target = resolveTargetApp(
            frontmost: frontmost,
            preferred: preferred,
            selfPID: selfPID,
            hostBundleIdentifier: hostBundleIdentifier
        ) else {
            return (
                false,
                L10n.tr("当前没有可用的前台应用窗口", "No active frontmost application found", language: language)
            )
        }

        let appName = target.displayName
        switch readFocusedWindowTitle(target) {
        case .noFocusedWindow:
            return (
                false,
                L10n.tr("\(appName) 当前没有打开的窗口", "No focused window in \(appName)", language: language)
            )
        case .title(let rawTitle):
            guard let copiedTitle = WindowTitleClipboardText.clamp(rawTitle) else {
                return (
                    false,
                    L10n.tr("\(appName) 当前窗口标题为空", "Focused window in \(appName) has an empty title", language: language)
                )
            }
            guard writePasteboardString(copiedTitle) else {
                return (
                    false,
                    L10n.tr("无法将窗口标题写入剪贴板", "Could not copy window title to clipboard", language: language)
                )
            }
            return (
                true,
                L10n.tr("已复制窗口标题：\(copiedTitle)", "Copied window title: \(copiedTitle)", language: language)
            )
        }
    }
}
