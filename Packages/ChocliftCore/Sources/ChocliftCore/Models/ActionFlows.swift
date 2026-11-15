import Foundation

// MARK: - Composable Action Flow Step & Flow Models

public enum ActionFlowStepKind: Codable, Equatable, Hashable, Sendable {
    case launchOrActivateApp(
        bundleIdentifier: String,
        appName: String,
        appPath: String? = nil
    )
    case waitForAppFrontmost(
        bundleIdentifier: String,
        appName: String? = nil,
        timeoutSeconds: Double = ActionFlowStep.defaultTimeoutSeconds
    )
    case delay(
        seconds: Double
    )
    case systemAction(
        action: SystemQuickAction,
        targetBundleIdentifier: String? = nil,
        targetAppName: String? = nil
    )
    case unsupported(rawType: String)
    case openWebsite(
        url: String,
        title: String? = nil,
        switchExistingTab: Bool = true,
        browserBundleIdentifier: String? = nil,
        browserAppName: String? = nil
    )
    case runShortcut(
        shortcutName: String
    )
    case insertSnippet(
        snippetID: UUID,
        titleSnapshot: String? = nil
    )
    /// Quit a chosen other app. Never targets Choclift itself.
    case quitApp(
        bundleIdentifier: String,
        appName: String,
        appPath: String? = nil
    )
    /// Open a chosen directory in an app that accepts folders (IDEs, Finder, editors).
    case openFolderInApp(
        folderPath: String,
        bundleIdentifier: String,
        appName: String,
        appPath: String? = nil
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case bundleIdentifier
        case appName
        case appPath
        case timeoutSeconds
        case seconds
        case action
        case targetBundleIdentifier
        case targetAppName
        case url
        case title
        case switchExistingTab
        case shortcutName
        case snippetID
        case titleSnapshot
        case folderPath
        case browserBundleIdentifier
        case browserAppName
    }

    private enum StepTypeTag: String {
        case launchOrActivateApp = "launch_or_activate_app"
        case waitForAppFrontmost = "wait_for_app_frontmost"
        case delay = "delay"
        case systemAction = "system_action"
        case openWebsite = "open_website"
        case runShortcut = "run_shortcut"
        case insertSnippet = "insert_snippet"
        case quitApp = "quit_app"
        case openFolderInApp = "open_folder_in_app"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)

        switch rawType {
        case StepTypeTag.launchOrActivateApp.rawValue:
            let bundleID = try container.decode(String.self, forKey: .bundleIdentifier)
            let appName = try container.decodeIfPresent(String.self, forKey: .appName) ?? bundleID
            let appPath = try container.decodeIfPresent(String.self, forKey: .appPath)
            self = .launchOrActivateApp(bundleIdentifier: bundleID, appName: appName, appPath: appPath)

        case StepTypeTag.waitForAppFrontmost.rawValue:
            let bundleID = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
            let appName = try container.decodeIfPresent(String.self, forKey: .appName)
            let rawTimeout = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
                ?? ActionFlowStep.defaultTimeoutSeconds
            self = .waitForAppFrontmost(
                bundleIdentifier: bundleID,
                appName: appName,
                timeoutSeconds: ActionFlowStep.clampTimeout(rawTimeout)
            )

        case StepTypeTag.delay.rawValue:
            let rawSeconds = try container.decodeIfPresent(Double.self, forKey: .seconds)
                ?? ActionFlowStep.defaultDelaySeconds
            self = .delay(seconds: ActionFlowStep.clampDelay(rawSeconds))

        case StepTypeTag.systemAction.rawValue:
            guard let rawAction = try container.decodeIfPresent(String.self, forKey: .action),
                  let action = SystemQuickAction(rawValue: rawAction) else {
                let unknownAction = (try? container.decodeIfPresent(String.self, forKey: .action)) ?? "unknown_action"
                self = .unsupported(rawType: "\(rawType):\(unknownAction)")
                return
            }
            let targetBundleID = try container.decodeIfPresent(String.self, forKey: .targetBundleIdentifier)
            let targetAppName = try container.decodeIfPresent(String.self, forKey: .targetAppName)
            self = .systemAction(
                action: action,
                targetBundleIdentifier: targetBundleID,
                targetAppName: targetAppName
            )

        case StepTypeTag.openWebsite.rawValue:
            let url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
            let title = try container.decodeIfPresent(String.self, forKey: .title)
            let switchExistingTab = try container.decodeIfPresent(Bool.self, forKey: .switchExistingTab) ?? true
            let browserBundle = try container.decodeIfPresent(String.self, forKey: .browserBundleIdentifier)
            let browserName = try container.decodeIfPresent(String.self, forKey: .browserAppName)
            self = .openWebsite(
                url: url,
                title: title,
                switchExistingTab: switchExistingTab,
                browserBundleIdentifier: browserBundle,
                browserAppName: browserName
            )

        case StepTypeTag.runShortcut.rawValue:
            let shortcutName = try container.decodeIfPresent(String.self, forKey: .shortcutName) ?? ""
            self = .runShortcut(shortcutName: shortcutName)

        case StepTypeTag.insertSnippet.rawValue:
            guard let snippetID = try container.decodeIfPresent(UUID.self, forKey: .snippetID) else {
                self = .unsupported(rawType: "\(rawType):missing_snippet_id")
                return
            }
            let titleSnapshot = try container.decodeIfPresent(String.self, forKey: .titleSnapshot)
            self = .insertSnippet(snippetID: snippetID, titleSnapshot: titleSnapshot)

        case StepTypeTag.quitApp.rawValue:
            let bundleID = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
            let appName = try container.decodeIfPresent(String.self, forKey: .appName) ?? bundleID
            let appPath = try container.decodeIfPresent(String.self, forKey: .appPath)
            self = .quitApp(bundleIdentifier: bundleID, appName: appName, appPath: appPath)

        case StepTypeTag.openFolderInApp.rawValue:
            let folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath) ?? ""
            let bundleID = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? ""
            let appName = try container.decodeIfPresent(String.self, forKey: .appName) ?? bundleID
            let appPath = try container.decodeIfPresent(String.self, forKey: .appPath)
            self = .openFolderInApp(
                folderPath: folderPath,
                bundleIdentifier: bundleID,
                appName: appName,
                appPath: appPath
            )

        default:
            self = .unsupported(rawType: rawType)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .launchOrActivateApp(let bundleIdentifier, let appName, let appPath):
            try container.encode(StepTypeTag.launchOrActivateApp.rawValue, forKey: .type)
            try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
            try container.encode(appName, forKey: .appName)
            try container.encodeIfPresent(appPath, forKey: .appPath)

        case .waitForAppFrontmost(let bundleIdentifier, let appName, let timeoutSeconds):
            try container.encode(StepTypeTag.waitForAppFrontmost.rawValue, forKey: .type)
            try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
            try container.encodeIfPresent(appName, forKey: .appName)
            try container.encode(ActionFlowStep.clampTimeout(timeoutSeconds), forKey: .timeoutSeconds)

        case .delay(let seconds):
            try container.encode(StepTypeTag.delay.rawValue, forKey: .type)
            try container.encode(ActionFlowStep.clampDelay(seconds), forKey: .seconds)

        case .systemAction(let action, let targetBundleIdentifier, let targetAppName):
            try container.encode(StepTypeTag.systemAction.rawValue, forKey: .type)
            try container.encode(action.rawValue, forKey: .action)
            try container.encodeIfPresent(targetBundleIdentifier, forKey: .targetBundleIdentifier)
            try container.encodeIfPresent(targetAppName, forKey: .targetAppName)

        case .unsupported(let rawType):
            try container.encode(rawType, forKey: .type)

        case .openWebsite(let url, let title, let switchExistingTab, let browserBundleIdentifier, let browserAppName):
            try container.encode(StepTypeTag.openWebsite.rawValue, forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encode(switchExistingTab, forKey: .switchExistingTab)
            try container.encodeIfPresent(browserBundleIdentifier, forKey: .browserBundleIdentifier)
            try container.encodeIfPresent(browserAppName, forKey: .browserAppName)

        case .runShortcut(let shortcutName):
            try container.encode(StepTypeTag.runShortcut.rawValue, forKey: .type)
            try container.encode(shortcutName, forKey: .shortcutName)

        case .insertSnippet(let snippetID, let titleSnapshot):
            try container.encode(StepTypeTag.insertSnippet.rawValue, forKey: .type)
            try container.encode(snippetID, forKey: .snippetID)
            try container.encodeIfPresent(titleSnapshot, forKey: .titleSnapshot)

        case .quitApp(let bundleIdentifier, let appName, let appPath):
            try container.encode(StepTypeTag.quitApp.rawValue, forKey: .type)
            try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
            try container.encode(appName, forKey: .appName)
            try container.encodeIfPresent(appPath, forKey: .appPath)

        case .openFolderInApp(let folderPath, let bundleIdentifier, let appName, let appPath):
            try container.encode(StepTypeTag.openFolderInApp.rawValue, forKey: .type)
            try container.encode(folderPath, forKey: .folderPath)
            try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
            try container.encode(appName, forKey: .appName)
            try container.encodeIfPresent(appPath, forKey: .appPath)
        }
    }
}

public struct ActionFlowStep: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let minDelaySeconds: Double = 0.05
    public static let maxDelaySeconds: Double = 10.0
    public static let defaultDelaySeconds: Double = 0.5

    public static let minTimeoutSeconds: Double = 0.1
    public static let maxTimeoutSeconds: Double = 10.0
    public static let defaultTimeoutSeconds: Double = 3.0

    public var id: UUID
    public var kind: ActionFlowStepKind
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        kind: ActionFlowStepKind,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = Self.normalizedKind(kind)
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let decodedKind = try container.decode(ActionFlowStepKind.self, forKey: .kind)
        self.kind = Self.normalizedKind(decodedKind)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(Self.normalizedKind(kind), forKey: .kind)
        try container.encode(isEnabled, forKey: .isEnabled)
    }

    public static func clampDelay(_ raw: Double) -> Double {
        guard raw.isFinite else { return defaultDelaySeconds }
        return min(max(0.0, raw), maxDelaySeconds)
    }

    public static func clampTimeout(_ raw: Double) -> Double {
        guard raw.isFinite else { return defaultTimeoutSeconds }
        return min(max(0.01, raw), maxTimeoutSeconds)
    }

    public static func isValidWebsiteURL(_ raw: String) -> Bool {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != "https://", clean != "http://" else { return false }
        let normalized = clean.contains("://") ? clean : "https://\(clean)"
        guard let url = URL(string: normalized), let host = url.host(), !host.isEmpty else {
            return false
        }
        return true
    }

    public static func normalizedWebsiteURL(_ raw: String) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "" }
        return clean.contains("://") ? clean : "https://\(clean)"
    }

    /// Absolute local directory, not a file and not a remote path.
    public static func isValidWorkingDirectoryPath(_ raw: String) -> Bool {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("/"), !clean.contains("\0") else { return false }
        return !clean.hasSuffix(".app")
    }

    public static func normalizedWorkingDirectoryPath(_ raw: String) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 1 else { return clean }
        return clean.hasSuffix("/") ? String(clean.dropLast()) : clean
    }

    /// Choclift must never quit itself from a flow step.
    public static func isChocliftBundleIdentifier(_ raw: String) -> Bool {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clean == "com.choclift.mac" || clean.hasPrefix("com.choclift.")
    }

    private static func normalizedKind(_ kind: ActionFlowStepKind) -> ActionFlowStepKind {
        switch kind {
        case .delay(let seconds):
            return .delay(seconds: clampDelay(seconds))
        case .waitForAppFrontmost(let bundleID, let appName, let timeout):
            return .waitForAppFrontmost(
                bundleIdentifier: bundleID,
                appName: appName,
                timeoutSeconds: clampTimeout(timeout)
            )
        case .openWebsite(let url, let title, let switchExistingTab, let browserBundle, let browserName):
            let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanBrowser = browserBundle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanBrowserName = browserName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .openWebsite(
                url: cleanURL,
                title: (cleanTitle?.isEmpty == false) ? cleanTitle : nil,
                switchExistingTab: switchExistingTab,
                browserBundleIdentifier: (cleanBrowser?.isEmpty == false) ? cleanBrowser : nil,
                browserAppName: (cleanBrowserName?.isEmpty == false) ? cleanBrowserName : nil
            )
        case .runShortcut(let shortcutName):
            return .runShortcut(shortcutName: shortcutName.trimmingCharacters(in: .whitespacesAndNewlines))
        case .insertSnippet(let snippetID, let titleSnapshot):
            let cleanSnapshot = titleSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .insertSnippet(
                snippetID: snippetID,
                titleSnapshot: (cleanSnapshot?.isEmpty == false) ? cleanSnapshot : nil
            )
        case .quitApp(let bundleID, let appName, let appPath):
            return .quitApp(
                bundleIdentifier: bundleID.trimmingCharacters(in: .whitespacesAndNewlines),
                appName: appName.trimmingCharacters(in: .whitespacesAndNewlines),
                appPath: trimmedOptional(appPath)
            )
        case .openFolderInApp(let folderPath, let bundleID, let appName, let appPath):
            return .openFolderInApp(
                folderPath: normalizedWorkingDirectoryPath(folderPath),
                bundleIdentifier: bundleID.trimmingCharacters(in: .whitespacesAndNewlines),
                appName: appName.trimmingCharacters(in: .whitespacesAndNewlines),
                appPath: trimmedOptional(appPath)
            )
        default:
            return kind
        }
    }

    private static func trimmedOptional(_ raw: String?) -> String? {
        let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return clean.isEmpty ? nil : clean
    }

    public var sfSymbol: String {
        switch kind {
        case .launchOrActivateApp:
            return "app.badge.checkmark"
        case .waitForAppFrontmost:
            return "macwindow.on.rectangle"
        case .delay:
            return "timer"
        case .systemAction(let action, _, _):
            return action.sfSymbol
        case .unsupported:
            return "exclamationmark.triangle"
        case .openWebsite:
            return "globe"
        case .runShortcut:
            return "sparkles.rectangle.stack"
        case .insertSnippet:
            return "text.quote"
        case .quitApp:
            return "xmark.octagon.fill"
        case .openFolderInApp:
            return "folder.badge.plus"
        }
    }

    public var accentHex: String {
        switch kind {
        case .launchOrActivateApp:
            return "#2F80ED"
        case .waitForAppFrontmost:
            return "#12B981"
        case .delay:
            return "#F97316"
        case .systemAction:
            return "#7C5CFF"
        case .unsupported:
            return "#E5484D"
        case .openWebsite:
            return "#0EA5E9"
        case .runShortcut:
            return "#EC4899"
        case .insertSnippet:
            return "#D97706"
        case .quitApp:
            return "#E5484D"
        case .openFolderInApp:
            return "#12B981"
        }
    }

    public var referencedBundleIdentifier: String? {
        switch kind {
        case .launchOrActivateApp(let bundleID, _, _):
            let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .waitForAppFrontmost(let bundleID, _, _):
            let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .systemAction(_, let targetBundleID, _):
            let trimmed = targetBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        case .quitApp(let bundleID, _, _), .openFolderInApp(_, let bundleID, _, _):
            let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .delay, .unsupported, .openWebsite, .runShortcut, .insertSnippet:
            return nil
        }
    }

    public var requiresDestructiveConfirmation: Bool {
        guard isEnabled else { return false }
        switch kind {
        case .systemAction(let action, _, _):
            return action.requiresDestructiveConfirmation
        default:
            return false
        }
    }

    public func displayTitle(in lang: AppLanguage = .system) -> String {
        switch kind {
        case .launchOrActivateApp(let bundleID, let appName, _):
            let cleanName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = cleanName.isEmpty ? bundleID : cleanName
            return L10n.tr("打开 \(label)", "Open \(label)", language: lang)

        case .waitForAppFrontmost(let bundleID, let appName, let timeout):
            let cleanName = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let cleanBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            let label: String
            if !cleanName.isEmpty {
                label = cleanName
            } else if !cleanBundle.isEmpty {
                label = cleanBundle
            } else {
                label = L10n.tr("上一步应用", "Previous App", language: lang)
            }
            let secs = Self.formatSeconds(Self.clampTimeout(timeout))
            return L10n.tr("等待 \(label) 前置 (\(secs))", "Wait for \(label) Frontmost (\(secs))", language: lang)

        case .delay(let seconds):
            let secs = Self.formatSeconds(Self.clampDelay(seconds))
            return L10n.tr("等待 \(secs)", "Wait \(secs)", language: lang)

        case .systemAction(let action, let targetBundleID, let targetAppName):
            let base = action.title(in: lang)
            let cleanName = targetAppName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let cleanBundle = targetBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !cleanName.isEmpty {
                return "\(base) · \(cleanName)"
            } else if !cleanBundle.isEmpty {
                return "\(base) · \(cleanBundle)"
            }
            return base

        case .unsupported(let rawType):
            return L10n.tr("不支持的步骤 (\(rawType))", "Unsupported Step (\(rawType))", language: lang)

        case .openWebsite(let url, let title, _, _, _):
            let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let derivedHost: String = {
                guard !cleanURL.isEmpty else { return "" }
                let normalized = cleanURL.contains("://") ? cleanURL : "https://\(cleanURL)"
                if let host = URL(string: normalized)?.host(), !host.isEmpty {
                    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                }
                return cleanURL
            }()
            let label = !cleanTitle.isEmpty ? cleanTitle : derivedHost
            if label.isEmpty {
                return L10n.tr("打开网页", "Open Website", language: lang)
            }
            return L10n.tr("打开网页 \(label)", "Open Website \(label)", language: lang)

        case .runShortcut(let shortcutName):
            let cleanName = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanName.isEmpty {
                return L10n.tr("运行快捷指令", "Run Shortcut", language: lang)
            }
            return L10n.tr("运行快捷指令「\(cleanName)」", "Run Shortcut \"\(cleanName)\"", language: lang)

        case .insertSnippet(_, let titleSnapshot):
            let cleanTitle = titleSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if cleanTitle.isEmpty {
                return L10n.tr("插入文本片段", "Insert Snippet", language: lang)
            }
            return L10n.tr("插入片段「\(cleanTitle)」", "Insert Snippet \"\(cleanTitle)\"", language: lang)

        case .quitApp(let bundleID, let appName, _):
            let label = Self.appLabel(name: appName, bundleID: bundleID, fallback: L10n.tr("应用", "App", language: lang))
            return L10n.tr("退出 \(label)", "Quit \(label)", language: lang)

        case .openFolderInApp(let folderPath, let bundleID, let appName, _):
            let appLabel = Self.appLabel(name: appName, bundleID: bundleID, fallback: L10n.tr("应用", "App", language: lang))
            let folder = Self.folderDisplayName(folderPath)
            if folder.isEmpty {
                return L10n.tr("用 \(appLabel) 打开工作目录", "Open Folder in \(appLabel)", language: lang)
            }
            return L10n.tr("用 \(appLabel) 打开 \(folder)", "Open \(folder) in \(appLabel)", language: lang)
        }
    }

    public func subtitle(in lang: AppLanguage = .system) -> String {
        switch kind {
        case .launchOrActivateApp(let bundleID, _, _):
            return bundleID
        case .waitForAppFrontmost(let bundleID, _, let timeout):
            let secs = Self.formatSeconds(Self.clampTimeout(timeout))
            let target = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            return target.isEmpty
                ? L10n.tr("超时上限 \(secs) · 跟随当前目标应用", "Timeout \(secs) · Follows active flow app", language: lang)
                : L10n.tr("\(target) · 超时上限 \(secs)", "\(target) · Timeout \(secs)", language: lang)
        case .delay(let seconds):
            let secs = Self.formatSeconds(Self.clampDelay(seconds))
            return L10n.tr("固定短延时 \(secs)", "Bounded pause (\(secs))", language: lang)
        case .systemAction(let action, let targetBundleID, _):
            if action.targetsApplication {
                let explicit = targetBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !explicit.isEmpty {
                    return L10n.tr("指定目标：\(explicit)", "Targets \(explicit)", language: lang)
                }
                return L10n.tr("作用于当前步骤打开的应用", "Applies to the intended app in this flow", language: lang)
            }
            return L10n.tr("系统全局快捷操作", "System-wide Mac action", language: lang)
        case .unsupported(let rawType):
            return rawType
        case .openWebsite(let url, _, let switchExistingTab, let browserBundle, let browserName):
            let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let shownURL = cleanURL.isEmpty ? "https://" : cleanURL
            let browser = Self.appLabel(name: browserName ?? "", bundleID: browserBundle ?? "", fallback: "")
            let browserSuffix = browser.isEmpty
                ? ""
                : L10n.tr(" · \(browser)", " · \(browser)", language: lang)
            return switchExistingTab
                ? L10n.tr("\(shownURL) · 优先切换已打开标签页\(browserSuffix)", "\(shownURL) · Switch existing tab\(browserSuffix)", language: lang)
                : L10n.tr("\(shownURL) · 在浏览器中打开\(browserSuffix)", "\(shownURL) · Open in browser\(browserSuffix)", language: lang)
        case .runShortcut(let shortcutName):
            let cleanName = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleanName.isEmpty
                ? L10n.tr("macOS 快捷指令", "macOS Shortcut", language: lang)
                : L10n.tr("macOS 快捷指令 · \(cleanName)", "macOS Shortcut · \(cleanName)", language: lang)
        case .insertSnippet(let snippetID, let titleSnapshot):
            let cleanTitle = titleSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return cleanTitle.isEmpty
                ? L10n.tr("已保存文本片段 (\(snippetID.uuidString.prefix(8)))", "Saved Snippet (\(snippetID.uuidString.prefix(8)))", language: lang)
                : L10n.tr("已保存文本片段 · \(cleanTitle)", "Saved Snippet · \(cleanTitle)", language: lang)
        case .quitApp(let bundleID, _, _):
            let target = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            return target.isEmpty
                ? L10n.tr("退出指定的其它应用，不会退出 Choclift", "Quits another app, never Choclift", language: lang)
                : L10n.tr("退出 \(target)，不会退出 Choclift", "Quits \(target), never Choclift", language: lang)
        case .openFolderInApp(let folderPath, let bundleID, _, _):
            let folder = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let app = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            if folder.isEmpty {
                return L10n.tr("选择工作目录后用应用打开", "Choose a folder, then open it in an app", language: lang)
            }
            return app.isEmpty ? folder : "\(folder) · \(app)"
        }
    }

    private static func appLabel(name: String, bundleID: String, fallback: String) -> String {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty { return cleanName }
        let cleanBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanBundle.isEmpty ? fallback : cleanBundle
    }

    private static func folderDisplayName(_ raw: String) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != "/" else { return clean == "/" ? "/" : "" }
        return URL(fileURLWithPath: clean).lastPathComponent
    }

    public static func formatSeconds(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.001 {
            return String(format: "%.0fs", value)
        } else if abs((value * 10).rounded() - value * 10) < 0.001 {
            return String(format: "%.1fs", value)
        }
        return String(format: "%.2fs", value)
    }
}

public struct ActionFlow: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var emoji: String
    public var backgroundHex: String
    public var steps: [ActionFlowStep]
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        emoji: String = "⚡️",
        backgroundHex: String = "#ECFAFE",
        steps: [ActionFlowStep] = [],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.backgroundHex = backgroundHex
        self.steps = steps
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case emoji
        case backgroundHex
        case steps
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? "⚡️"
        self.backgroundHex = try container.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "#ECFAFE"
        self.steps = try container.decodeIfPresent([ActionFlowStep].self, forKey: .steps) ?? []
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public var enabledStepCount: Int {
        steps.filter(\.isEnabled).count
    }

    public var requiresDestructiveConfirmation: Bool {
        steps.contains(where: \.requiresDestructiveConfirmation)
    }

    public var referencedBundleIdentifiers: Set<String> {
        var result = Set<String>()
        for step in steps {
            if let bid = step.referencedBundleIdentifier {
                result.insert(bid)
            }
        }
        return result
    }

    // MARK: - Preset Templates Matching Core Workflows

    public static func makeOpenWaitMaximizeTemplate(
        bundleIdentifier: String = "com.apple.Safari",
        appName: String = "Safari",
        appPath: String? = nil,
        timeoutSeconds: Double = ActionFlowStep.defaultTimeoutSeconds,
        language: AppLanguage = .system
    ) -> ActionFlow {
        ActionFlow(
            name: L10n.tr("\(appName) 全屏专注", "\(appName) Focus Maximize", language: language),
            emoji: "🖥",
            backgroundHex: "#EDF6FF",
            steps: [
                ActionFlowStep(kind: .launchOrActivateApp(bundleIdentifier: bundleIdentifier, appName: appName, appPath: appPath)),
                ActionFlowStep(kind: .waitForAppFrontmost(bundleIdentifier: bundleIdentifier, appName: appName, timeoutSeconds: timeoutSeconds)),
                ActionFlowStep(kind: .systemAction(action: .maximizeWindow, targetBundleIdentifier: bundleIdentifier, targetAppName: appName))
            ]
        )
    }

    public static func makeSplitScreenTemplate(
        leftBundleIdentifier: String = "com.apple.Safari",
        leftAppName: String = "Safari",
        leftAppPath: String? = nil,
        rightBundleIdentifier: String = "com.apple.Notes",
        rightAppName: String = "Notes",
        rightAppPath: String? = nil,
        timeoutSeconds: Double = ActionFlowStep.defaultTimeoutSeconds,
        language: AppLanguage = .system
    ) -> ActionFlow {
        ActionFlow(
            name: L10n.tr("\(leftAppName) + \(rightAppName) 分屏", "\(leftAppName) + \(rightAppName) Split", language: language),
            emoji: "🪟",
            backgroundHex: "#ECFAFE",
            steps: [
                ActionFlowStep(kind: .launchOrActivateApp(bundleIdentifier: leftBundleIdentifier, appName: leftAppName, appPath: leftAppPath)),
                ActionFlowStep(kind: .waitForAppFrontmost(bundleIdentifier: leftBundleIdentifier, appName: leftAppName, timeoutSeconds: timeoutSeconds)),
                ActionFlowStep(kind: .systemAction(action: .snapWindowLeft, targetBundleIdentifier: leftBundleIdentifier, targetAppName: leftAppName)),
                ActionFlowStep(kind: .launchOrActivateApp(bundleIdentifier: rightBundleIdentifier, appName: rightAppName, appPath: rightAppPath)),
                ActionFlowStep(kind: .waitForAppFrontmost(bundleIdentifier: rightBundleIdentifier, appName: rightAppName, timeoutSeconds: timeoutSeconds)),
                ActionFlowStep(kind: .systemAction(action: .snapWindowRight, targetBundleIdentifier: rightBundleIdentifier, targetAppName: rightAppName))
            ]
        )
    }
}

// MARK: - Sequential Flow Execution Engine (Shared Contract for Mac & Tests)

public struct FlowAppHandle: Equatable, Sendable {
    public let bundleIdentifier: String
    public let appName: String
    public let processIdentifier: Int32

    public init(bundleIdentifier: String, appName: String, processIdentifier: Int32) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.processIdentifier = processIdentifier
    }
}

public enum FlowSystemActionTarget: Equatable, Sendable {
    /// Action does not target a specific app, or flow has not established a target app yet.
    case defaultTarget(preferredPID: Int32?)
    /// Action must apply strictly to this intended app and never fall back to an unrelated frontmost window.
    case strictApp(bundleIdentifier: String, processIdentifier: Int32)
}

public struct ActionFlowRunResult: Equatable, Sendable {
    public let success: Bool
    public let title: String
    public let detail: String
    public let executedStepCount: Int
    public let failedStepIndex: Int?
    public let failedStepTitle: String?

    public init(
        success: Bool,
        title: String,
        detail: String,
        executedStepCount: Int,
        failedStepIndex: Int? = nil,
        failedStepTitle: String? = nil
    ) {
        self.success = success
        self.title = title
        self.detail = detail
        self.executedStepCount = executedStepCount
        self.failedStepIndex = failedStepIndex
        self.failedStepTitle = failedStepTitle
    }
}

@MainActor
public protocol ActionFlowDriver: AnyObject {
    var fallbackExternalAppPID: Int32? { get }

    func launchOrActivateApp(
        bundleIdentifier: String,
        appPath: String?
    ) async -> (success: Bool, message: String, app: FlowAppHandle?)

    func currentFrontmostApp() -> FlowAppHandle?

    func runningApp(forBundleIdentifier bundleIdentifier: String) -> FlowAppHandle?

    func waitForAdjustableWindowIfNeeded(
        for app: FlowAppHandle,
        action: SystemQuickAction
    ) async

    func executeSystemAction(
        _ action: SystemQuickAction,
        target: FlowSystemActionTarget
    ) -> (success: Bool, message: String)

    func openWebsite(
        url: String,
        switchExistingTab: Bool,
        browserBundleIdentifier: String?
    ) async -> (success: Bool, message: String)

    func quitApp(
        bundleIdentifier: String,
        appPath: String?
    ) -> (success: Bool, message: String)

    func openFolderInApp(
        folderPath: String,
        bundleIdentifier: String,
        appPath: String?
    ) async -> (success: Bool, message: String)

    func runShortcut(
        named shortcutName: String
    ) async -> (success: Bool, message: String)

    func insertSnippet(
        snippetID: UUID,
        titleSnapshot: String?,
        preferredPID: Int32?
    ) -> (success: Bool, message: String)

    func sleep(seconds: Double) async
}

@MainActor
public enum ActionFlowRunner {
    public static func run(
        _ flow: ActionFlow,
        driver: ActionFlowDriver,
        language: AppLanguage = .system
    ) async -> ActionFlowRunResult {
        guard flow.steps.contains(where: \.isEnabled) else {
            let msg = L10n.tr(
                "动作流「\(flow.name)」没有可执行的步骤",
                "Flow \"\(flow.name)\" has no executable steps",
                language: language
            )
            return ActionFlowRunResult(
                success: false,
                title: msg,
                detail: msg,
                executedStepCount: 0
            )
        }

        var currentTargetBundleID: String?
        var currentTargetAppName: String?
        var currentTargetApp: FlowAppHandle?
        var executedCount = 0

        for (idx, step) in flow.steps.enumerated() where step.isEnabled {
            let stepNumber = idx + 1
            let stepTitle = step.displayTitle(in: language)

            func fail(_ reason: String) -> ActionFlowRunResult {
                let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                let effectiveReason = trimmedReason.isEmpty
                    ? L10n.tr("执行失败", "Step execution failed", language: language)
                    : trimmedReason
                let failTitle = L10n.tr(
                    "\(flow.name)：第 \(stepNumber) 步「\(stepTitle)」失败",
                    "\(flow.name): Step \(stepNumber) (\(stepTitle)) failed",
                    language: language
                )
                let failDetail = L10n.tr(
                    "第 \(stepNumber) 步「\(stepTitle)」失败：\(effectiveReason)",
                    "Step \(stepNumber) (\(stepTitle)) failed: \(effectiveReason)",
                    language: language
                )
                return ActionFlowRunResult(
                    success: false,
                    title: failTitle,
                    detail: failDetail,
                    executedStepCount: executedCount,
                    failedStepIndex: idx,
                    failedStepTitle: stepTitle
                )
            }

            if Task.isCancelled {
                return fail(L10n.tr("动作流已取消", "Flow was cancelled", language: language))
            }

            switch step.kind {
            case .launchOrActivateApp(let bundleID, let appName, let appPath):
                let trimmedBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedBundle.isEmpty else {
                    return fail(L10n.tr("应用 Bundle ID 为空", "App bundle identifier is empty", language: language))
                }

                let outcome = await driver.launchOrActivateApp(
                    bundleIdentifier: trimmedBundle,
                    appPath: appPath
                )
                guard outcome.success else {
                    return fail(outcome.message)
                }

                let resolvedHandle = outcome.app ?? driver.runningApp(forBundleIdentifier: trimmedBundle)
                currentTargetBundleID = resolvedHandle?.bundleIdentifier ?? trimmedBundle
                let cleanAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
                currentTargetAppName = cleanAppName.isEmpty ? (resolvedHandle?.appName ?? trimmedBundle) : cleanAppName
                currentTargetApp = resolvedHandle
                executedCount += 1

            case .waitForAppFrontmost(let bundleID, let appName, let timeoutSeconds):
                let trimmedBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedBundleID = trimmedBundle.isEmpty ? (currentTargetBundleID ?? "") : trimmedBundle
                guard !resolvedBundleID.isEmpty else {
                    return fail(L10n.tr("未指定要等待前置的目标应用", "No target app specified to wait for", language: language))
                }

                let boundedTimeout = ActionFlowStep.clampTimeout(timeoutSeconds)
                let pollInterval = min(0.05, max(0.005, boundedTimeout / 10.0))
                let startWall = Date()
                var simulatedElapsed: Double = 0
                var matched = matchingFrontmost(bundleIdentifier: resolvedBundleID, driver: driver)

                while matched == nil && simulatedElapsed < boundedTimeout && Date().timeIntervalSince(startWall) < boundedTimeout {
                    if Task.isCancelled {
                        return fail(L10n.tr("动作流已取消", "Flow was cancelled", language: language))
                    }
                    let elapsed = max(simulatedElapsed, Date().timeIntervalSince(startWall))
                    let remaining = boundedTimeout - elapsed
                    guard remaining > 0 else { break }
                    let slice = min(pollInterval, remaining)
                    await driver.sleep(seconds: slice)
                    simulatedElapsed += slice
                    matched = matchingFrontmost(bundleIdentifier: resolvedBundleID, driver: driver)
                }

                guard let frontApp = matched else {
                    let cleanName = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let displayApp = !cleanName.isEmpty ? cleanName : (currentTargetAppName ?? resolvedBundleID)
                    let formattedSecs = ActionFlowStep.formatSeconds(boundedTimeout)
                    return fail(
                        L10n.tr(
                            "\(displayApp) 未在 \(formattedSecs) 内切换到前台",
                            "\(displayApp) did not become frontmost within \(formattedSecs)",
                            language: language
                        )
                    )
                }

                currentTargetBundleID = frontApp.bundleIdentifier
                let cleanName = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                currentTargetAppName = cleanName.isEmpty ? frontApp.appName : cleanName
                currentTargetApp = frontApp
                executedCount += 1

            case .delay(let seconds):
                let boundedSeconds = ActionFlowStep.clampDelay(seconds)
                if boundedSeconds > 0 {
                    await driver.sleep(seconds: boundedSeconds)
                }
                if Task.isCancelled {
                    return fail(L10n.tr("动作流已取消", "Flow was cancelled", language: language))
                }
                executedCount += 1

            case .systemAction(let action, let explicitBundleID, let explicitAppName):
                if action.targetsApplication {
                    let trimmedExplicit = explicitBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let intendedBundleID: String? = !trimmedExplicit.isEmpty ? trimmedExplicit : currentTargetBundleID

                    if let targetBundle = intendedBundleID {
                        let resolvedApp: FlowAppHandle? = {
                            if let live = driver.runningApp(forBundleIdentifier: targetBundle) {
                                return live
                            }
                            if let cached = currentTargetApp,
                               cached.bundleIdentifier.caseInsensitiveCompare(targetBundle) == .orderedSame,
                               driver.runningApp(forBundleIdentifier: cached.bundleIdentifier) != nil {
                                return cached
                            }
                            return nil
                        }()

                        guard let targetHandle = resolvedApp else {
                            let cleanExplicitName = explicitAppName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            let label = !cleanExplicitName.isEmpty
                                ? cleanExplicitName
                                : (currentTargetAppName ?? targetBundle)
                            return fail(
                                L10n.tr(
                                    "目标应用「\(label)」当前未运行，已停止以避免误操作其它窗口",
                                    "Target app \"\(label)\" is not running; stopped instead of acting on another window",
                                    language: language
                                )
                            )
                        }

                        if action.isWindowAction {
                            await driver.waitForAdjustableWindowIfNeeded(for: targetHandle, action: action)
                        }

                        let res = driver.executeSystemAction(
                            action,
                            target: .strictApp(
                                bundleIdentifier: targetHandle.bundleIdentifier,
                                processIdentifier: targetHandle.processIdentifier
                            )
                        )
                        guard res.success else {
                            return fail(res.message)
                        }
                    } else {
                        let res = driver.executeSystemAction(
                            action,
                            target: .defaultTarget(preferredPID: driver.fallbackExternalAppPID)
                        )
                        guard res.success else {
                            return fail(res.message)
                        }
                    }
                } else {
                    let res = driver.executeSystemAction(
                        action,
                        target: .defaultTarget(preferredPID: driver.fallbackExternalAppPID)
                    )
                    guard res.success else {
                        return fail(res.message)
                    }
                }
                executedCount += 1

            case .unsupported(let rawType):
                return fail(
                    L10n.tr(
                        "当前版本不支持步骤类型「\(rawType)」",
                        "Step type \"\(rawType)\" is not supported by this version",
                        language: language
                    )
                )

            case .openWebsite(let url, _, let switchExistingTab, let browserBundle, _):
                let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedURL.isEmpty else {
                    return fail(L10n.tr("网址为空", "Website URL is empty", language: language))
                }
                guard ActionFlowStep.isValidWebsiteURL(trimmedURL) else {
                    return fail(L10n.tr("无效的网址：\(trimmedURL)", "Invalid URL: \(trimmedURL)", language: language))
                }
                let normalizedURL = ActionFlowStep.normalizedWebsiteURL(trimmedURL)
                let cleanBrowser = browserBundle?.trimmingCharacters(in: .whitespacesAndNewlines)
                let res = await driver.openWebsite(
                    url: normalizedURL,
                    switchExistingTab: switchExistingTab,
                    browserBundleIdentifier: (cleanBrowser?.isEmpty == false) ? cleanBrowser : nil
                )
                guard res.success else {
                    return fail(res.message)
                }
                executedCount += 1

            case .runShortcut(let shortcutName):
                let trimmedName = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else {
                    return fail(L10n.tr("快捷指令名称为空", "Shortcut name is empty", language: language))
                }
                let res = await driver.runShortcut(named: trimmedName)
                guard res.success else {
                    return fail(res.message)
                }
                executedCount += 1

            case .insertSnippet(let snippetID, let titleSnapshot):
                let preferredPID: Int32? = {
                    if let targetBundle = currentTargetBundleID,
                       let live = driver.runningApp(forBundleIdentifier: targetBundle) {
                        return live.processIdentifier
                    }
                    return currentTargetApp?.processIdentifier ?? driver.fallbackExternalAppPID
                }()
                let res = driver.insertSnippet(
                    snippetID: snippetID,
                    titleSnapshot: titleSnapshot,
                    preferredPID: preferredPID
                )
                guard res.success else {
                    return fail(res.message)
                }
                executedCount += 1

            case .quitApp(let bundleID, let appName, let appPath):
                let trimmedBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedBundle.isEmpty else {
                    return fail(L10n.tr("未选择要退出的应用", "No app selected to quit", language: language))
                }
                guard !ActionFlowStep.isChocliftBundleIdentifier(trimmedBundle) else {
                    return fail(L10n.tr("不能通过动作流退出 Choclift", "Action flows cannot quit Choclift", language: language))
                }
                let res = driver.quitApp(bundleIdentifier: trimmedBundle, appPath: appPath)
                guard res.success else {
                    return fail(res.message)
                }
                if currentTargetBundleID?.caseInsensitiveCompare(trimmedBundle) == .orderedSame {
                    currentTargetBundleID = nil
                    currentTargetAppName = nil
                    currentTargetApp = nil
                }
                _ = appName
                executedCount += 1

            case .openFolderInApp(let folderPath, let bundleID, let appName, let appPath):
                let trimmedFolder = ActionFlowStep.normalizedWorkingDirectoryPath(folderPath)
                guard ActionFlowStep.isValidWorkingDirectoryPath(trimmedFolder) else {
                    return fail(L10n.tr("工作目录无效", "Working directory is invalid", language: language))
                }
                let trimmedBundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedBundle.isEmpty else {
                    return fail(L10n.tr("未选择用来打开目录的应用", "No app selected to open the folder", language: language))
                }
                let res = await driver.openFolderInApp(
                    folderPath: trimmedFolder,
                    bundleIdentifier: trimmedBundle,
                    appPath: appPath
                )
                guard res.success else {
                    return fail(res.message)
                }
                currentTargetBundleID = trimmedBundle
                let cleanName = appName.trimmingCharacters(in: .whitespacesAndNewlines)
                currentTargetAppName = cleanName.isEmpty ? trimmedBundle : cleanName
                currentTargetApp = driver.runningApp(forBundleIdentifier: trimmedBundle)
                executedCount += 1
            }
        }

        let doneDetail = L10n.tr(
            "已完成动作流「\(flow.name)」（共 \(executedCount) 步）",
            "Completed flow \"\(flow.name)\" (\(executedCount) steps)",
            language: language
        )
        return ActionFlowRunResult(
            success: true,
            title: flow.name,
            detail: doneDetail,
            executedStepCount: executedCount
        )
    }

    private static func matchingFrontmost(
        bundleIdentifier: String,
        driver: ActionFlowDriver
    ) -> FlowAppHandle? {
        guard let front = driver.currentFrontmostApp(),
              front.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame else {
            return nil
        }
        return front
    }
}
