import Foundation

public enum AppSettingsCompanionActionID {
    public static let openSettings = "apps.open_settings"
}

extension CompanionActionCatalog {
    public static let appSettingsPack: [CompanionAction] = [
        CompanionAction(
            id: AppSettingsCompanionActionID.openSettings,
            titleZh: "打开当前应用设置",
            titleEn: "Open App Settings",
            sfSymbol: "gear"
        )
    ]
}

public enum AppSettingsMenuMatch {
    public static let settingsKeywords: [String] = [
        "Settings",
        "Preferences",
        "设置",
        "偏好设置"
    ]

    private static let nonApplicationMenuTitles: Set<String> = [
        "file", "edit", "view", "format", "insert", "selection", "find", "go",
        "navigate", "editor", "product", "debug", "source control", "history",
        "bookmarks", "profiles", "tab", "shell", "tools", "window", "help",
        "文件", "编辑", "显示", "视图", "格式", "插入", "选择", "查找", "前往",
        "历史记录", "书签", "标签页", "工具", "窗口", "帮助"
    ]

    public static func isAppleMenuTitle(_ menu: String) -> Bool {
        let trimmed = menu.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        return lower == "apple" || trimmed == "" || trimmed == "\u{F8FF}"
    }

    public static func isSettingsMenuTitle(_ menu: String) -> Bool {
        let cleaned = stripEllipsisAndTrim(menu)
        guard !cleaned.isEmpty else { return false }
        let lower = cleaned.lowercased()
        return lower == "settings"
            || lower == "preferences"
            || cleaned == "设置"
            || cleaned == "偏好设置"
    }

    public static func isSettingsItemTitle(_ item: String) -> Bool {
        let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let cleaned = stripEllipsisAndTrim(trimmed)
        let lowerCleaned = cleaned.lowercased()
        if lowerCleaned == "system settings"
            || lowerCleaned == "system preferences"
            || cleaned == "系统设置"
            || cleaned == "系统偏好设置" {
            return false
        }

        let lowerTrimmed = trimmed.lowercased()
        if lowerTrimmed.hasPrefix("about ")
            || lowerTrimmed.hasPrefix("hide ")
            || lowerTrimmed.hasPrefix("quit ")
            || lowerTrimmed.hasPrefix("force quit")
            || trimmed.hasPrefix("关于")
            || trimmed.hasPrefix("隐藏")
            || trimmed.hasPrefix("退出")
            || trimmed.hasPrefix("强制退出") {
            return false
        }

        return trimmed.range(of: "Settings", options: [.caseInsensitive]) != nil
            || trimmed.range(of: "Preferences", options: [.caseInsensitive]) != nil
            || trimmed.contains("设置")
            || trimmed.contains("偏好设置")
    }

    public static func firstEnabledIndex(
        menuTitles: [(menu: String, item: String, enabled: Bool)]
    ) -> Int? {
        let firstAppMenu: String? = {
            for entry in menuTitles {
                if isAppleMenuTitle(entry.menu) {
                    continue
                }
                let key = normalizedMenuKey(entry.menu)
                if nonApplicationMenuTitles.contains(key) {
                    return nil
                }
                return key
            }
            return nil
        }()

        for (index, entry) in menuTitles.enumerated() {
            guard entry.enabled else { continue }
            guard !isAppleMenuTitle(entry.menu) else { continue }
            let menuKey = normalizedMenuKey(entry.menu)
            let isEligibleMenu = isSettingsMenuTitle(entry.menu)
                || (firstAppMenu != nil && menuKey == firstAppMenu)
            guard isEligibleMenu else { continue }
            if isSettingsItemTitle(entry.item) {
                return index
            }
        }
        return nil
    }

    public static func item(
        menuTitles: [(menu: String, item: String, enabled: Bool)]
    ) -> String? {
        guard let index = firstEnabledIndex(menuTitles: menuTitles) else {
            return nil
        }
        return menuTitles[index].item
    }

    private static func normalizedMenuKey(_ menu: String) -> String {
        menu.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func stripEllipsisAndTrim(_ raw: String) -> String {
        var result = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("…") || result.hasSuffix("...") {
            if result.hasSuffix("…") {
                result.removeLast()
            } else if result.hasSuffix("...") {
                result.removeLast(3)
            }
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}

public struct AppSettingsTargetCandidate: Equatable, Hashable, Sendable {
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

public enum AppSettingsPressOutcome: Equatable, Sendable {
    case pressed(itemTitle: String)
    case missingOrDisabled
    case pressFailed
}

public enum AppSettingsActionRouting {
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
        _ candidate: AppSettingsTargetCandidate,
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

    public static func resolveTarget(
        frontmost: AppSettingsTargetCandidate?,
        preferred: AppSettingsTargetCandidate?,
        selfPID: Int32,
        hostBundleIdentifier: String? = chocliftBundleIdentifier
    ) -> AppSettingsTargetCandidate? {
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
        frontmost: AppSettingsTargetCandidate?,
        preferred: AppSettingsTargetCandidate?,
        selfPID: Int32,
        hostBundleIdentifier: String? = chocliftBundleIdentifier,
        language: AppLanguage = .system,
        ensureAccessibility: () -> Bool,
        activateAndPressSettings: (AppSettingsTargetCandidate) -> AppSettingsPressOutcome
    ) -> (success: Bool, message: String) {
        guard id == AppSettingsCompanionActionID.openSettings else {
            return (
                false,
                L10n.tr("不支持的应用操作：\(id)", "Unsupported apps action: \(id)", language: language)
            )
        }
        guard let target = resolveTarget(
            frontmost: frontmost,
            preferred: preferred,
            selfPID: selfPID,
            hostBundleIdentifier: hostBundleIdentifier
        ) else {
            return (
                false,
                L10n.tr("当前没有可打开设置的前台应用", "No frontmost application available to open settings", language: language)
            )
        }
        guard ensureAccessibility() else {
            return (
                false,
                L10n.tr(
                    "请在系统设置 → 辅助功能中授权 Choclift 后打开应用设置",
                    "Grant Accessibility permission in System Settings to open app settings",
                    language: language
                )
            )
        }
        let name = target.displayName
        switch activateAndPressSettings(target) {
        case .pressed:
            return (
                true,
                L10n.tr("已打开 \(name) 设置", "Opened \(name) settings", language: language)
            )
        case .missingOrDisabled:
            return (
                false,
                L10n.tr(
                    "\(name) 没有可用的设置菜单项",
                    "Settings menu item is unavailable or disabled in \(name)",
                    language: language
                )
            )
        case .pressFailed:
            return (
                false,
                L10n.tr(
                    "无法打开 \(name) 设置",
                    "Could not open settings in \(name)",
                    language: language
                )
            )
        }
    }
}
