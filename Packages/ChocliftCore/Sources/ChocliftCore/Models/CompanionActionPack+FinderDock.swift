import Foundation

public enum FinderDockPreferenceToggle {
    /// Pure toggle for Finder `AppleShowAllFiles` and Dock `autohide`.
    /// An unset (`nil`) preference corresponds to `false` on macOS, so `nil` toggles to `true`
    /// (show hidden files / enable Dock autohide).
    public static func nextValue(current: Bool?) -> Bool {
        !(current ?? false)
    }

    /// Parses a raw `CFPreferencesCopyAppValue` value into `Bool?`, returning `nil` when unset or unrecognized.
    public static func parsePreferenceValue(_ rawValue: Any?) -> Bool? {
        guard let rawValue else {
            return nil
        }
        if let boolValue = rawValue as? Bool {
            return boolValue
        }
        if let numberValue = rawValue as? NSNumber {
            return numberValue.boolValue
        }
        if let stringValue = rawValue as? String {
            let normalized = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "true", "yes", "1", "on":
                return true
            case "false", "no", "0", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }
}

public enum FinderDockCompanionAction: String, CaseIterable, Equatable, Hashable, Sendable {
    case toggleFinderHiddenFiles = "finder.toggle_hidden_files"
    case toggleDockAutohide = "dock.toggle_autohide"

    public var preferenceDomain: String {
        switch self {
        case .toggleFinderHiddenFiles:
            return "com.apple.finder"
        case .toggleDockAutohide:
            return "com.apple.dock"
        }
    }

    public var preferenceKey: String {
        switch self {
        case .toggleFinderHiddenFiles:
            return "AppleShowAllFiles"
        case .toggleDockAutohide:
            return "autohide"
        }
    }

    public var processName: String {
        switch self {
        case .toggleFinderHiddenFiles:
            return "Finder"
        case .toggleDockAutohide:
            return "Dock"
        }
    }

    public var companionAction: CompanionAction {
        switch self {
        case .toggleFinderHiddenFiles:
            return CompanionAction(
                id: rawValue,
                titleZh: "显示隐藏文件",
                titleEn: "Toggle Hidden Files",
                sfSymbol: "eye"
            )
        case .toggleDockAutohide:
            return CompanionAction(
                id: rawValue,
                titleZh: "自动隐藏程序坞",
                titleEn: "Toggle Dock Autohide",
                sfSymbol: "dock.rectangle"
            )
        }
    }

    public func toggledMessage(isEnabled: Bool, in language: AppLanguage = .system) -> String {
        switch self {
        case .toggleFinderHiddenFiles:
            return isEnabled
                ? L10n.tr("已显示访达隐藏文件", "Hidden files are now shown in Finder", language: language)
                : L10n.tr("已隐藏访达隐藏文件", "Hidden files are now hidden in Finder", language: language)
        case .toggleDockAutohide:
            return isEnabled
                ? L10n.tr("已开启程序坞自动隐藏", "Dock autohide is now enabled", language: language)
                : L10n.tr("已关闭程序坞自动隐藏", "Dock autohide is now disabled", language: language)
        }
    }

    public func failureMessage(in language: AppLanguage = .system) -> String {
        switch self {
        case .toggleFinderHiddenFiles:
            return L10n.tr("无法更新访达隐藏文件偏好设置", "Could not update Finder hidden files preference", language: language)
        case .toggleDockAutohide:
            return L10n.tr("无法更新程序坞自动隐藏偏好设置", "Could not update Dock autohide preference", language: language)
        }
    }

    public static func execute(
        id: String,
        language: AppLanguage = .system,
        readPreference: (_ domain: String, _ key: String) -> Bool?,
        writePreference: (_ domain: String, _ key: String, _ value: Bool) -> Bool,
        restartProcess: (_ processName: String) -> Void
    ) -> (success: Bool, message: String) {
        guard let action = FinderDockCompanionAction(rawValue: id) else {
            return (
                false,
                L10n.tr("不支持的访达或程序坞操作", "Unsupported Finder or Dock action", language: language)
            )
        }

        let current = readPreference(action.preferenceDomain, action.preferenceKey)
        let next = FinderDockPreferenceToggle.nextValue(current: current)
        guard writePreference(action.preferenceDomain, action.preferenceKey, next) else {
            return (false, action.failureMessage(in: language))
        }
        restartProcess(action.processName)
        return (true, action.toggledMessage(isEnabled: next, in: language))
    }
}

extension CompanionActionCatalog {
    public static let finderDockPack: [CompanionAction] = FinderDockCompanionAction.allCases.map(\.companionAction)
}
