import Foundation

// MARK: - Language & Localization

public enum AppLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case system = "system"
    case chinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return L10n.isSystemChinese ? "跟随系统 (System)" : "System Default"
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
}

public enum L10n {
    public static var isSystemChinese: Bool {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh")
    }

    public static func tr(_ zh: String, _ en: String, language: AppLanguage = .system) -> String {
        switch language {
        case .chinese:
            return zh
        case .english:
            return en
        case .system:
            return isSystemChinese ? zh : en
        }
    }
}

// MARK: - Theme Palette

public enum ChocTheme: String, Codable, CaseIterable, Sendable, Identifiable {
    case darkChocolate = "dark_chocolate"
    case milkChocolate = "milk_chocolate"
    case rubyBerry = "ruby_berry"
    case matchaWhite = "matcha_white"
    case midnightObsidian = "midnight_obsidian"

    public var id: String { rawValue }

    public func title(in lang: AppLanguage = .system) -> String {
        switch self {
        case .darkChocolate: return L10n.tr("亮彩紫罗兰", "Bright Violet", language: lang)
        case .milkChocolate: return L10n.tr("晴日珊瑚", "Sunny Coral", language: lang)
        case .rubyBerry: return L10n.tr("晴空蔚蓝", "Clear Sky", language: lang)
        case .matchaWhite: return L10n.tr("鲜柠青绿", "Fresh Lime", language: lang)
        case .midnightObsidian: return L10n.tr("晨光琥珀", "Warm Amber", language: lang)
        }
    }
}

// MARK: - System Quick Actions & Gesture Actions

public enum SystemQuickAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case maximizeWindow = "maximize_window"
    case minimizeWindow = "minimize_window"
    case snapWindowLeft = "snap_window_left"
    case snapWindowRight = "snap_window_right"
    case centerWindow = "center_window"
    case toggleFullscreen = "toggle_fullscreen"
    case copySelection = "copy_selection"
    case pasteClipboard = "paste_clipboard"
    case cutSelection = "cut_selection"
    case undoAction = "undo_action"
    case redoAction = "redo_action"
    case missionControl = "mission_control"
    case showDesktop = "show_desktop"
    case screenshotInteractive = "screenshot_interactive"
    case mediaPlayPause = "media_play_pause"
    case mediaNext = "media_next"
    case mediaPrevious = "media_previous"
    case volumeUp = "volume_up"
    case volumeDown = "volume_down"
    case volumeMute = "volume_mute"
    case lockScreen = "lock_screen"
    case quitApp = "quit_app"
    case openEmojiPicker = "open_emoji_picker"

    public var id: String { rawValue }

    public var sfSymbol: String {
        switch self {
        case .maximizeWindow: return "arrow.up.left.and.arrow.down.right"
        case .minimizeWindow: return "minus.square.fill"
        case .snapWindowLeft: return "rectangle.lefthalf.inset.filled"
        case .snapWindowRight: return "rectangle.righthalf.inset.filled"
        case .centerWindow: return "rectangle.center.inset.filled"
        case .toggleFullscreen: return "rectangle.expand.vertical"
        case .copySelection: return "doc.on.doc.fill"
        case .pasteClipboard: return "doc.on.clipboard.fill"
        case .cutSelection: return "scissors"
        case .undoAction: return "arrow.uturn.backward.circle.fill"
        case .redoAction: return "arrow.uturn.forward.circle.fill"
        case .missionControl: return "rectangle.3.group.fill"
        case .showDesktop: return "menubar.dock.rectangle"
        case .screenshotInteractive: return "camera.viewfinder"
        case .mediaPlayPause: return "playpause.fill"
        case .mediaNext: return "forward.fill"
        case .mediaPrevious: return "backward.fill"
        case .volumeUp: return "speaker.wave.3.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .volumeMute: return "speaker.slash.fill"
        case .lockScreen: return "lock.display"
        case .quitApp: return "xmark.octagon.fill"
        case .openEmojiPicker: return "face.smiling.inverse"
        }
    }

    public var accentHex: String {
        switch self {
        case .maximizeWindow, .minimizeWindow, .snapWindowLeft, .snapWindowRight, .centerWindow, .toggleFullscreen:
            return "#EDF6FF"
        case .copySelection, .pasteClipboard, .cutSelection, .undoAction, .redoAction:
            return "#F3EEFF"
        case .missionControl, .showDesktop, .screenshotInteractive, .lockScreen, .quitApp, .openEmojiPicker:
            return "#FFF1EC"
        case .mediaPlayPause, .mediaNext, .mediaPrevious, .volumeUp, .volumeDown, .volumeMute:
            return "#ECFAEE"
        }
    }

    public var isWindowAction: Bool {
        switch self {
        case .maximizeWindow, .minimizeWindow, .snapWindowLeft, .snapWindowRight, .centerWindow, .toggleFullscreen:
            return true
        default:
            return false
        }
    }

    public var isUndoableWindowMove: Bool {
        switch self {
        case .maximizeWindow, .snapWindowLeft, .snapWindowRight:
            return true
        default:
            return false
        }
    }

    public var requiresDestructiveConfirmation: Bool {
        switch self {
        case .lockScreen, .quitApp:
            return true
        default:
            return false
        }
    }

    public var targetsApplication: Bool {
        if isWindowAction {
            return true
        }
        switch self {
        case .copySelection, .pasteClipboard, .cutSelection, .undoAction, .redoAction, .quitApp:
            return true
        default:
            return false
        }
    }

    /// Keyboard shortcut string ONLY when Mac execution actually synthesizes a keyboard shortcut.
    /// Window AX frames, process launches, NSRunningApplication.terminate(), and NX media keys return `nil`.
    public var sentKeyboardShortcut: String? {
        switch self {
        case .copySelection:
            return "⌘C"
        case .pasteClipboard:
            return "⌘V"
        case .cutSelection:
            return "⌘X"
        case .undoAction:
            return "⌘Z"
        case .redoAction:
            return "⇧⌘Z"
        case .lockScreen:
            return "⌃⌘Q"
        case .openEmojiPicker:
            return "⌃⌘Space"
        case .maximizeWindow, .minimizeWindow, .snapWindowLeft, .snapWindowRight,
             .centerWindow, .toggleFullscreen, .missionControl, .showDesktop,
             .screenshotInteractive, .mediaPlayPause, .mediaNext, .mediaPrevious,
             .volumeUp, .volumeDown, .volumeMute, .quitApp:
            return nil
        }
    }

    public func title(in lang: AppLanguage = .system) -> String {
        switch self {
        case .maximizeWindow: return L10n.tr("窗口最大化/还原", "Maximize / Restore Window", language: lang)
        case .minimizeWindow: return L10n.tr("最小化窗口", "Minimize Window", language: lang)
        case .snapWindowLeft: return L10n.tr("窗口贴靠左半屏", "Snap Window Left", language: lang)
        case .snapWindowRight: return L10n.tr("窗口贴靠右半屏", "Snap Window Right", language: lang)
        case .centerWindow: return L10n.tr("窗口居中", "Center Window", language: lang)
        case .toggleFullscreen: return L10n.tr("切换全屏", "Toggle Fullscreen", language: lang)
        case .copySelection: return L10n.tr("复制", "Copy", language: lang)
        case .pasteClipboard: return L10n.tr("粘贴", "Paste", language: lang)
        case .cutSelection: return L10n.tr("剪切", "Cut", language: lang)
        case .undoAction: return L10n.tr("撤销", "Undo", language: lang)
        case .redoAction: return L10n.tr("重做", "Redo", language: lang)
        case .missionControl: return L10n.tr("调度中心", "Mission Control", language: lang)
        case .showDesktop: return L10n.tr("显示桌面", "Show Desktop", language: lang)
        case .screenshotInteractive: return L10n.tr("区域截图", "Area Screenshot", language: lang)
        case .mediaPlayPause: return L10n.tr("播放 / 暂停", "Play / Pause", language: lang)
        case .mediaNext: return L10n.tr("下一曲", "Next Track", language: lang)
        case .mediaPrevious: return L10n.tr("上一曲", "Previous Track", language: lang)
        case .volumeUp: return L10n.tr("音量增加", "Volume Up", language: lang)
        case .volumeDown: return L10n.tr("音量减小", "Volume Down", language: lang)
        case .volumeMute: return L10n.tr("静音切换", "Mute Toggle", language: lang)
        case .lockScreen: return L10n.tr("锁定屏幕", "Lock Screen", language: lang)
        case .quitApp: return L10n.tr("退出当前应用", "Quit Application", language: lang)
        case .openEmojiPicker: return L10n.tr("系统表情面板", "macOS Emoji Panel", language: lang)
        }
    }

    public func compactTitle(in lang: AppLanguage = .system) -> String {
        switch self {
        case .maximizeWindow: return L10n.tr("最大化", "Maximize", language: lang)
        case .minimizeWindow: return L10n.tr("最小化", "Minimize", language: lang)
        case .snapWindowLeft: return L10n.tr("左半屏", "Snap Left", language: lang)
        case .snapWindowRight: return L10n.tr("右半屏", "Snap Right", language: lang)
        case .centerWindow: return L10n.tr("居中", "Center", language: lang)
        case .toggleFullscreen: return L10n.tr("全屏", "Fullscreen", language: lang)
        case .copySelection: return L10n.tr("复制", "Copy", language: lang)
        case .pasteClipboard: return L10n.tr("粘贴", "Paste", language: lang)
        case .cutSelection: return L10n.tr("剪切", "Cut", language: lang)
        case .undoAction: return L10n.tr("撤销", "Undo", language: lang)
        case .redoAction: return L10n.tr("重做", "Redo", language: lang)
        case .missionControl: return L10n.tr("调度中心", "Spaces", language: lang)
        case .showDesktop: return L10n.tr("桌面", "Desktop", language: lang)
        case .screenshotInteractive: return L10n.tr("截图", "Capture", language: lang)
        case .mediaPlayPause: return L10n.tr("播放/暂停", "Play", language: lang)
        case .mediaNext: return L10n.tr("下一曲", "Next", language: lang)
        case .mediaPrevious: return L10n.tr("上一曲", "Prev", language: lang)
        case .volumeUp: return L10n.tr("音量+", "Vol +", language: lang)
        case .volumeDown: return L10n.tr("音量-", "Vol -", language: lang)
        case .volumeMute: return L10n.tr("静音", "Mute", language: lang)
        case .lockScreen: return L10n.tr("锁屏", "Lock", language: lang)
        case .quitApp: return L10n.tr("退出", "Quit", language: lang)
        case .openEmojiPicker: return L10n.tr("表情框", "Emoji", language: lang)
        }
    }
}

// MARK: - Chocolate Bar Items & Pages

public enum BarItemKind: Codable, Equatable, Hashable, Sendable {
    case macApp(
        bundleIdentifier: String,
        appName: String,
        appPath: String? = nil,
        fallbackSymbol: String = "app.fill"
    )
    case shortcut(
        shortcutName: String,
        emoji: String,
        backgroundHex: String
    )
    case website(
        url: String,
        title: String,
        emoji: String,
        backgroundHex: String,
        switchExistingTab: Bool
    )
    case systemAction(
        action: SystemQuickAction,
        customTitle: String? = nil,
        backgroundHex: String? = nil
    )
    case flow(
        flowID: UUID,
        titleSnapshot: String,
        emoji: String = "⚡️",
        backgroundHex: String = "#ECFAFE",
        stepCountSnapshot: Int = 0
    )
    case soundboard(
        soundID: UUID,
        titleSnapshot: String,
        emoji: String = "🔊",
        backgroundHex: String = "#ECFAEE"
    )
    /// Points at another Chocolate Bar slot without copying or duplicating its action payload.
    case slotReference(
        targetPageID: UUID,
        targetSlotIndex: Int
    )

    private enum CodingKeys: String, CodingKey {
        case macApp
        case shortcut
        case website
        case systemAction
        case flow
        case soundboard
        case slotReference
    }

    private enum MacAppKeys: String, CodingKey {
        case bundleIdentifier
        case appName
        case appPath
        case fallbackSymbol
    }

    private enum ShortcutKeys: String, CodingKey {
        case shortcutName
        case emoji
        case backgroundHex
    }

    private enum WebsiteKeys: String, CodingKey {
        case url
        case title
        case emoji
        case backgroundHex
        case switchExistingTab
    }

    private enum SystemActionKeys: String, CodingKey {
        case action
        case customTitle
        case backgroundHex
    }

    private enum FlowKeys: String, CodingKey {
        case flowID
        case titleSnapshot
        case emoji
        case backgroundHex
        case stepCountSnapshot
    }

    private enum SoundboardKeys: String, CodingKey {
        case soundID
        case titleSnapshot
        case emoji
        case backgroundHex
    }

    private enum SlotReferenceKeys: String, CodingKey {
        case targetPageID
        case targetSlotIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.macApp) {
            let nested = try container.nestedContainer(keyedBy: MacAppKeys.self, forKey: .macApp)
            let bundleIdentifier = try nested.decode(String.self, forKey: .bundleIdentifier)
            let appName = try nested.decodeIfPresent(String.self, forKey: .appName) ?? bundleIdentifier
            let appPath = try nested.decodeIfPresent(String.self, forKey: .appPath)
            let fallbackSymbol = try nested.decodeIfPresent(String.self, forKey: .fallbackSymbol) ?? "app.fill"
            self = .macApp(
                bundleIdentifier: bundleIdentifier,
                appName: appName,
                appPath: appPath,
                fallbackSymbol: fallbackSymbol
            )
        } else if container.contains(.shortcut) {
            let nested = try container.nestedContainer(keyedBy: ShortcutKeys.self, forKey: .shortcut)
            let shortcutName = try nested.decode(String.self, forKey: .shortcutName)
            let emoji = try nested.decodeIfPresent(String.self, forKey: .emoji) ?? "⚡️"
            let backgroundHex = try nested.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "#F3EEFF"
            self = .shortcut(
                shortcutName: shortcutName,
                emoji: emoji,
                backgroundHex: backgroundHex
            )
        } else if container.contains(.website) {
            let nested = try container.nestedContainer(keyedBy: WebsiteKeys.self, forKey: .website)
            let url = try nested.decode(String.self, forKey: .url)
            let title = try nested.decodeIfPresent(String.self, forKey: .title) ?? url
            let emoji = try nested.decodeIfPresent(String.self, forKey: .emoji) ?? "🌐"
            let backgroundHex = try nested.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "#FFF1EC"
            let switchExistingTab = try nested.decodeIfPresent(Bool.self, forKey: .switchExistingTab) ?? true
            self = .website(
                url: url,
                title: title,
                emoji: emoji,
                backgroundHex: backgroundHex,
                switchExistingTab: switchExistingTab
            )
        } else if container.contains(.systemAction) {
            let nested = try container.nestedContainer(keyedBy: SystemActionKeys.self, forKey: .systemAction)
            let action = try nested.decode(SystemQuickAction.self, forKey: .action)
            let customTitle = try nested.decodeIfPresent(String.self, forKey: .customTitle)
            let backgroundHex = try nested.decodeIfPresent(String.self, forKey: .backgroundHex)
            self = .systemAction(
                action: action,
                customTitle: customTitle,
                backgroundHex: backgroundHex
            )
        } else if container.contains(.flow) {
            let nested = try container.nestedContainer(keyedBy: FlowKeys.self, forKey: .flow)
            let flowID = try nested.decode(UUID.self, forKey: .flowID)
            let titleSnapshot = try nested.decodeIfPresent(String.self, forKey: .titleSnapshot) ?? ""
            let emoji = try nested.decodeIfPresent(String.self, forKey: .emoji) ?? "⚡️"
            let backgroundHex = try nested.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "#ECFAFE"
            let stepCountSnapshot = try nested.decodeIfPresent(Int.self, forKey: .stepCountSnapshot) ?? 0
            self = .flow(
                flowID: flowID,
                titleSnapshot: titleSnapshot,
                emoji: emoji,
                backgroundHex: backgroundHex,
                stepCountSnapshot: stepCountSnapshot
            )
        } else if container.contains(.soundboard) {
            let nested = try container.nestedContainer(keyedBy: SoundboardKeys.self, forKey: .soundboard)
            let soundID = try nested.decode(UUID.self, forKey: .soundID)
            let titleSnapshot = try nested.decodeIfPresent(String.self, forKey: .titleSnapshot) ?? ""
            let emoji = try nested.decodeIfPresent(String.self, forKey: .emoji) ?? "🔊"
            let backgroundHex = try nested.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "#ECFAEE"
            self = .soundboard(
                soundID: soundID,
                titleSnapshot: titleSnapshot,
                emoji: emoji,
                backgroundHex: backgroundHex
            )
        } else if container.contains(.slotReference) {
            let nested = try container.nestedContainer(keyedBy: SlotReferenceKeys.self, forKey: .slotReference)
            let targetPageID = try nested.decode(UUID.self, forKey: .targetPageID)
            let targetSlotIndex = try nested.decode(Int.self, forKey: .targetSlotIndex)
            self = .slotReference(
                targetPageID: targetPageID,
                targetSlotIndex: targetSlotIndex
            )
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unsupported BarItemKind payload"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .macApp(let bundleIdentifier, let appName, let appPath, let fallbackSymbol):
            var nested = container.nestedContainer(keyedBy: MacAppKeys.self, forKey: .macApp)
            try nested.encode(bundleIdentifier, forKey: .bundleIdentifier)
            try nested.encode(appName, forKey: .appName)
            try nested.encodeIfPresent(appPath, forKey: .appPath)
            try nested.encode(fallbackSymbol, forKey: .fallbackSymbol)

        case .shortcut(let shortcutName, let emoji, let backgroundHex):
            var nested = container.nestedContainer(keyedBy: ShortcutKeys.self, forKey: .shortcut)
            try nested.encode(shortcutName, forKey: .shortcutName)
            try nested.encode(emoji, forKey: .emoji)
            try nested.encode(backgroundHex, forKey: .backgroundHex)

        case .website(let url, let title, let emoji, let backgroundHex, let switchExistingTab):
            var nested = container.nestedContainer(keyedBy: WebsiteKeys.self, forKey: .website)
            try nested.encode(url, forKey: .url)
            try nested.encode(title, forKey: .title)
            try nested.encode(emoji, forKey: .emoji)
            try nested.encode(backgroundHex, forKey: .backgroundHex)
            try nested.encode(switchExistingTab, forKey: .switchExistingTab)

        case .systemAction(let action, let customTitle, let backgroundHex):
            var nested = container.nestedContainer(keyedBy: SystemActionKeys.self, forKey: .systemAction)
            try nested.encode(action, forKey: .action)
            try nested.encodeIfPresent(customTitle, forKey: .customTitle)
            try nested.encodeIfPresent(backgroundHex, forKey: .backgroundHex)

        case .flow(let flowID, let titleSnapshot, let emoji, let backgroundHex, let stepCountSnapshot):
            var nested = container.nestedContainer(keyedBy: FlowKeys.self, forKey: .flow)
            try nested.encode(flowID, forKey: .flowID)
            try nested.encode(titleSnapshot, forKey: .titleSnapshot)
            try nested.encode(emoji, forKey: .emoji)
            try nested.encode(backgroundHex, forKey: .backgroundHex)
            try nested.encode(stepCountSnapshot, forKey: .stepCountSnapshot)

        case .soundboard(let soundID, let titleSnapshot, let emoji, let backgroundHex):
            var nested = container.nestedContainer(keyedBy: SoundboardKeys.self, forKey: .soundboard)
            try nested.encode(soundID, forKey: .soundID)
            try nested.encode(titleSnapshot, forKey: .titleSnapshot)
            try nested.encode(emoji, forKey: .emoji)
            try nested.encode(backgroundHex, forKey: .backgroundHex)

        case .slotReference(let targetPageID, let targetSlotIndex):
            var nested = container.nestedContainer(keyedBy: SlotReferenceKeys.self, forKey: .slotReference)
            try nested.encode(targetPageID, forKey: .targetPageID)
            try nested.encode(targetSlotIndex, forKey: .targetSlotIndex)
        }
    }
}

public struct BarItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: BarItemKind

    public init(id: UUID = UUID(), kind: BarItemKind) {
        self.id = id
        self.kind = kind
    }

    public func displayTitle(in lang: AppLanguage = .system) -> String {
        switch kind {
        case .macApp(_, let appName, _, _):
            return appName
        case .shortcut(let shortcutName, _, _):
            return shortcutName
        case .website(_, let title, _, _, _):
            return title
        case .systemAction(let action, let customTitle, _):
            if let customTitle, !customTitle.isEmpty {
                return customTitle
            }
            return action.title(in: lang)
        case .flow(_, let titleSnapshot, _, _, _):
            let trimmed = titleSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L10n.tr("动作流", "Action Flow", language: lang) : trimmed
        case .soundboard(_, let titleSnapshot, _, _):
            let trimmed = titleSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L10n.tr("音效", "Sound", language: lang) : trimmed
        case .slotReference(_, let targetSlotIndex):
            return L10n.tr("引用 #\(targetSlotIndex + 1)", "Ref #\(targetSlotIndex + 1)", language: lang)
        }
    }

    public var bundleIdentifier: String? {
        if case .macApp(let bundleID, _, _, _) = kind {
            return bundleID
        }
        return nil
    }

    public var flowID: UUID? {
        if case .flow(let id, _, _, _, _) = kind {
            return id
        }
        return nil
    }

    public var soundID: UUID? {
        if case .soundboard(let id, _, _, _) = kind {
            return id
        }
        return nil
    }

    public var slotReferenceCoordinate: SlotCoordinate? {
        if case .slotReference(let targetPageID, let targetSlotIndex) = kind {
            return SlotCoordinate(pageID: targetPageID, slotIndex: targetSlotIndex)
        }
        return nil
    }

    public var isSlotReference: Bool {
        slotReferenceCoordinate != nil
    }

    public func requiresDestructiveConfirmation(in profile: ChocliftWorkspaceProfile, from origin: SlotCoordinate? = nil) -> Bool {
        switch kind {
        case .systemAction(let action, _, _):
            return action.requiresDestructiveConfirmation
        case .flow(let flowID, _, _, _, _):
            return profile.flow(withID: flowID)?.requiresDestructiveConfirmation ?? false
        case .slotReference:
            guard case .resolved(let pageID, _, _, _, let slotIdx, let resolved) = profile.resolveBarItem(self, from: origin) else {
                return false
            }
            return resolved.requiresDestructiveConfirmation(
                in: profile,
                from: SlotCoordinate(pageID: pageID, slotIndex: slotIdx)
            )
        case .macApp, .shortcut, .website, .soundboard:
            return false
        }
    }
}

private struct SafeBarSlotWrapper: Decodable {
    let item: BarItem?

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self.item = nil
            return
        }
        self.item = try? BarItem(from: decoder)
    }
}

public struct BarPage: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let slotsPerPage = 8
    public static let maxPages = 8

    public var id: UUID
    public var index: Int
    public var title: String
    public var iconEmoji: String
    /// Always normalized to 8 slots (2 rows x 4 columns)
    public var slots: [BarItem?]

    private enum CodingKeys: String, CodingKey {
        case id
        case index
        case title
        case iconEmoji
        case slots
    }

    public init(
        id: UUID = UUID(),
        index: Int,
        title: String,
        iconEmoji: String,
        slots: [BarItem?] = Array(repeating: nil, count: BarPage.slotsPerPage)
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.iconEmoji = iconEmoji
        self.slots = Self.normalizeSlots(slots)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Page"
        self.iconEmoji = try container.decodeIfPresent(String.self, forKey: .iconEmoji) ?? "🍫"
        let wrappedSlots = try container.decodeIfPresent([SafeBarSlotWrapper].self, forKey: .slots) ?? []
        self.slots = Self.normalizeSlots(wrappedSlots.map(\.item))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(index, forKey: .index)
        try container.encode(title, forKey: .title)
        try container.encode(iconEmoji, forKey: .iconEmoji)
        try container.encode(Self.normalizeSlots(slots), forKey: .slots)
    }

    private static func normalizeSlots(_ slots: [BarItem?]) -> [BarItem?] {
        var normalized = Array(slots.prefix(Self.slotsPerPage))
        while normalized.count < Self.slotsPerPage {
            normalized.append(nil)
        }
        return normalized
    }
}

// MARK: - Emoji Bar Slides

public struct EmojiSlide: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let emojisPerSlide = 8
    public static let maxSlides = 8

    public var id: UUID
    public var index: Int
    public var title: String
    public var iconEmoji: String
    public var emojis: [String]

    public init(
        id: UUID = UUID(),
        index: Int,
        title: String,
        iconEmoji: String,
        emojis: [String]
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.iconEmoji = iconEmoji
        var normalized = Array(emojis.prefix(Self.emojisPerSlide))
        let defaults = ["😀", "👍", "🔥", "✨", "❤️", "🎉", "🚀", "🍫"]
        var idx = 0
        while normalized.count < Self.emojisPerSlide {
            normalized.append(defaults[idx % defaults.count])
            idx += 1
        }
        self.emojis = normalized
    }
}

// MARK: - One-Tap Text Snippets

public struct TextSnippet: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let maxTitleLength = 40
    public static let maxBodyLength = 2000
    public static let maxLibraryCount = 64

    public var id: UUID
    public var title: String
    public var body: String
    public var insertMode: SnippetInsertMode
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case body
        case insertMode
        case updatedAt
    }

    public init(
        id: UUID = UUID(),
        title: String,
        body: String,
        insertMode: SnippetInsertMode = .focusedFieldInsert,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = Self.clampTitle(title)
        self.body = Self.clampBody(body)
        self.insertMode = insertMode
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let rawTitle = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        let rawBody = try container.decode(String.self, forKey: .body)
        self.title = Self.clampTitle(rawTitle)
        self.body = Self.clampBody(rawBody)
        self.insertMode = try container.decodeIfPresent(SnippetInsertMode.self, forKey: .insertMode) ?? .focusedFieldInsert
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(Self.clampTitle(title), forKey: .title)
        try container.encode(Self.clampBody(body), forKey: .body)
        try container.encode(insertMode, forKey: .insertMode)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    public static func clampTitle(_ raw: String) -> String {
        let singleLine = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(singleLine.prefix(maxTitleLength))
    }

    public static func clampBody(_ raw: String) -> String {
        String(raw.prefix(maxBodyLength))
    }

    public static func resolvedTitle(title: String, body: String, language: AppLanguage = .system) -> String {
        let trimmedTitle = clampTitle(title).trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return String(trimmedTitle.prefix(maxTitleLength))
        }
        let firstLine = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
        if !firstLine.isEmpty {
            return String(firstLine.prefix(maxTitleLength))
        }
        return L10n.tr("未命名片段", "Untitled Snippet", language: language)
    }

    public func displayTitle(in language: AppLanguage = .system) -> String {
        Self.resolvedTitle(title: title, body: body, language: language)
    }

    public var singleLinePreview: String {
        body
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Finger Gestures

public enum TouchGestureType: String, Codable, CaseIterable, Sendable, Identifiable {
    case twoFingerSwipeUp = "two_finger_swipe_up"
    case twoFingerSwipeDown = "two_finger_swipe_down"
    case twoFingerSwipeLeft = "two_finger_swipe_left"
    case twoFingerSwipeRight = "two_finger_swipe_right"
    case threeFingerPinchIn = "three_finger_pinch_in"
    case threeFingerPinchOut = "three_finger_pinch_out"
    case twoFingerDoubleTap = "two_finger_double_tap"
    case threeFingerSwipeUp = "three_finger_swipe_up"
    case threeFingerSwipeDown = "three_finger_swipe_down"

    public var id: String { rawValue }

    public var sfSymbol: String {
        switch self {
        case .twoFingerSwipeUp: return "hand.draw.fill"
        case .twoFingerSwipeDown: return "arrow.down.to.line.compact"
        case .twoFingerSwipeLeft: return "arrow.left.to.line.compact"
        case .twoFingerSwipeRight: return "arrow.right.to.line.compact"
        case .threeFingerPinchIn: return "arrow.down.right.and.arrow.up.left"
        case .threeFingerPinchOut: return "arrow.up.left.and.arrow.down.right"
        case .twoFingerDoubleTap: return "hand.tap.fill"
        case .threeFingerSwipeUp: return "chevron.up.2"
        case .threeFingerSwipeDown: return "chevron.down.2"
        }
    }

    public func title(in lang: AppLanguage = .system) -> String {
        switch self {
        case .twoFingerSwipeUp: return L10n.tr("双指上滑", "Two-Finger Swipe Up", language: lang)
        case .twoFingerSwipeDown: return L10n.tr("双指下滑", "Two-Finger Swipe Down", language: lang)
        case .twoFingerSwipeLeft: return L10n.tr("双指左滑", "Two-Finger Swipe Left", language: lang)
        case .twoFingerSwipeRight: return L10n.tr("双指右滑", "Two-Finger Swipe Right", language: lang)
        case .threeFingerPinchIn: return L10n.tr("三指捏合 (抓取)", "Three-Finger Pinch In (Grab)", language: lang)
        case .threeFingerPinchOut: return L10n.tr("三指张开 (投送)", "Three-Finger Spread (Drop)", language: lang)
        case .twoFingerDoubleTap: return L10n.tr("双指双击", "Two-Finger Double Tap", language: lang)
        case .threeFingerSwipeUp: return L10n.tr("三指上滑", "Three-Finger Swipe Up", language: lang)
        case .threeFingerSwipeDown: return L10n.tr("三指下滑", "Three-Finger Swipe Down", language: lang)
        }
    }

    public func subtitle(in lang: AppLanguage = .system) -> String {
        switch self {
        case .twoFingerSwipeUp: return L10n.tr("在触控栏任意位置双指向上滑动", "Swipe up with 2 fingers anywhere", language: lang)
        case .twoFingerSwipeDown: return L10n.tr("在触控栏任意位置双指向下滑动", "Swipe down with 2 fingers anywhere", language: lang)
        case .twoFingerSwipeLeft: return L10n.tr("在触控栏任意位置双指向左滑动", "Swipe left with 2 fingers anywhere", language: lang)
        case .twoFingerSwipeRight: return L10n.tr("在触控栏任意位置双指向右滑动", "Swipe right with 2 fingers anywhere", language: lang)
        case .threeFingerPinchIn: return L10n.tr("像抓起内容一样三指向内捏合", "Pinch inward with 3 fingers to grab", language: lang)
        case .threeFingerPinchOut: return L10n.tr("像放下内容一样三指向外张开", "Spread outward with 3 fingers to paste", language: lang)
        case .twoFingerDoubleTap: return L10n.tr("双指轻点屏幕两次", "Double-tap quickly with 2 fingers", language: lang)
        case .threeFingerSwipeUp: return L10n.tr("三指向上滑动呼出全局视图", "Swipe up with 3 fingers", language: lang)
        case .threeFingerSwipeDown: return L10n.tr("三指向下滑动快速收起", "Swipe down with 3 fingers", language: lang)
        }
    }
}

public struct GestureBinding: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var gesture: TouchGestureType
    public var action: SystemQuickAction
    public var isEnabled: Bool

    public var id: String { gesture.rawValue }

    public init(gesture: TouchGestureType, action: SystemQuickAction, isEnabled: Bool = true) {
        self.gesture = gesture
        self.action = action
        self.isEnabled = isEnabled
    }
}

public struct GestureConfiguration: Codable, Equatable, Hashable, Sendable {
    public var isGlobalOverlayEnabled: Bool
    public var bindings: [GestureBinding]

    public init(isGlobalOverlayEnabled: Bool = true, bindings: [GestureBinding]) {
        self.isGlobalOverlayEnabled = isGlobalOverlayEnabled
        self.bindings = bindings
    }

    public func action(for gesture: TouchGestureType) -> SystemQuickAction? {
        guard let binding = bindings.first(where: { $0.gesture == gesture }), binding.isEnabled else {
            return nil
        }
        return binding.action
    }
}

// MARK: - App Time Travel

public struct RecentAppEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var bundleIdentifier: String
    public var appName: String
    public var appPath: String?
    public var lastActivatedAt: Date
    public var activationCount: Int
    public var isFrontmost: Bool
    public var isPinned: Bool
    public var isRunning: Bool

    public var id: String { bundleIdentifier }

    public init(
        bundleIdentifier: String,
        appName: String,
        appPath: String? = nil,
        lastActivatedAt: Date = Date(),
        activationCount: Int = 1,
        isFrontmost: Bool = false,
        isPinned: Bool = false,
        isRunning: Bool = true
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.appPath = appPath
        self.lastActivatedAt = lastActivatedAt
        self.activationCount = activationCount
        self.isFrontmost = isFrontmost
        self.isPinned = isPinned
        self.isRunning = isRunning
    }

    public static func sortTimeline(_ entries: [RecentAppEntry]) -> [RecentAppEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            if lhs.lastActivatedAt != rhs.lastActivatedAt {
                return lhs.lastActivatedAt > rhs.lastActivatedAt
            }
            return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
    }
}

// MARK: - Companion Settings & Workspace Profile

public struct CompanionSettings: Codable, Equatable, Hashable, Sendable {
    public var autoShowEmojiBarWhenTyping: Bool
    public var autoReturnFromEmojiBarOnBlur: Bool
    public var hapticFeedbackEnabled: Bool
    public var keepCompanionScreenAwake: Bool
    public var theme: ChocTheme
    public var language: AppLanguage
    public var excludedTimeTravelBundleIDs: [String]

    public init(
        autoShowEmojiBarWhenTyping: Bool = true,
        autoReturnFromEmojiBarOnBlur: Bool = true,
        hapticFeedbackEnabled: Bool = true,
        keepCompanionScreenAwake: Bool = true,
        theme: ChocTheme = .darkChocolate,
        language: AppLanguage = .system,
        excludedTimeTravelBundleIDs: [String] = ["com.apple.loginwindow"]
    ) {
        self.autoShowEmojiBarWhenTyping = autoShowEmojiBarWhenTyping
        self.autoReturnFromEmojiBarOnBlur = autoReturnFromEmojiBarOnBlur
        self.hapticFeedbackEnabled = hapticFeedbackEnabled
        self.keepCompanionScreenAwake = keepCompanionScreenAwake
        self.theme = theme
        self.language = language
        self.excludedTimeTravelBundleIDs = excludedTimeTravelBundleIDs
    }
}

public struct ChocliftWorkspaceProfile: Codable, Equatable, Hashable, Sendable {
    public var revision: Int
    public var updatedAt: Date
    public var pages: [BarPage]
    public var emojiSlides: [EmojiSlide]
    public var gestureConfig: GestureConfiguration
    public var settings: CompanionSettings
    public var pinnedTimeTravelBundleIDs: [String]
    public var flows: [ActionFlow]
    /// Maps a Mac app bundle identifier to the `BarPage.id` shown when that app is frontmost.
    /// At most one page is bound per bundle identifier; multiple bundle identifiers may map to one page.
    public var appDeckBindings: [String: UUID]
    public var snippets: [TextSnippet]
    public var soundboardClips: [SoundboardClip]
    public var soundboardVolume: Double
    public var pinnedStripSlots: [SlotCoordinate]

    private enum CodingKeys: String, CodingKey {
        case revision
        case updatedAt
        case pages
        case emojiSlides
        case gestureConfig
        case settings
        case pinnedTimeTravelBundleIDs
        case flows
        case appDeckBindings
        case snippets
        case soundboardClips
        case soundboardVolume
        case pinnedStripSlots
    }

    public init(
        revision: Int = 1,
        updatedAt: Date = Date(),
        pages: [BarPage],
        emojiSlides: [EmojiSlide],
        gestureConfig: GestureConfiguration,
        settings: CompanionSettings = CompanionSettings(),
        pinnedTimeTravelBundleIDs: [String] = [],
        flows: [ActionFlow] = [],
        appDeckBindings: [String: UUID] = [:],
        snippets: [TextSnippet] = [],
        soundboardClips: [SoundboardClip] = [],
        soundboardVolume: Double = SoundboardClip.defaultVolume,
        pinnedStripSlots: [SlotCoordinate] = []
    ) {
        self.revision = revision
        self.updatedAt = updatedAt
        self.pages = pages
        self.emojiSlides = emojiSlides
        self.gestureConfig = gestureConfig
        self.settings = settings
        self.pinnedTimeTravelBundleIDs = pinnedTimeTravelBundleIDs
        self.flows = flows
        self.appDeckBindings = Self.sanitizeAppDeckBindings(appDeckBindings)
        self.snippets = Array(snippets.prefix(TextSnippet.maxLibraryCount))
        self.soundboardClips = SoundboardCatalogValidator.sanitizeBoard(soundboardClips)
        self.soundboardVolume = ControlStripLevel.clamp(soundboardVolume)
        self.pinnedStripSlots = PinnedStripSlots.sanitize(pinnedStripSlots, in: pages)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        let decodedPages = try container.decodeIfPresent([BarPage].self, forKey: .pages) ?? ChocliftDefaults.makeDefaultPages()
        self.pages = decodedPages
        self.emojiSlides = try container.decodeIfPresent([EmojiSlide].self, forKey: .emojiSlides) ?? ChocliftDefaults.makeDefaultEmojiSlides()
        self.gestureConfig = try container.decodeIfPresent(GestureConfiguration.self, forKey: .gestureConfig) ?? ChocliftDefaults.makeDefaultGestureConfiguration()
        self.settings = try container.decodeIfPresent(CompanionSettings.self, forKey: .settings) ?? CompanionSettings()
        self.pinnedTimeTravelBundleIDs = try container.decodeIfPresent([String].self, forKey: .pinnedTimeTravelBundleIDs) ?? []
        self.flows = try container.decodeIfPresent([ActionFlow].self, forKey: .flows) ?? []
        if let rawStrings = try? container.decodeIfPresent([String: String].self, forKey: .appDeckBindings) {
            var parsed: [String: UUID] = [:]
            for (rawKey, rawUUID) in rawStrings {
                if let uuid = UUID(uuidString: rawUUID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    parsed[rawKey] = uuid
                }
            }
            self.appDeckBindings = Self.sanitizeAppDeckBindings(parsed)
        } else {
            self.appDeckBindings = [:]
        }
        let decodedSnippets = try container.decodeIfPresent([TextSnippet].self, forKey: .snippets) ?? []
        self.snippets = Array(decodedSnippets.prefix(TextSnippet.maxLibraryCount))
        let decodedClips = try container.decodeIfPresent([SoundboardClip].self, forKey: .soundboardClips) ?? []
        self.soundboardClips = SoundboardCatalogValidator.sanitizeBoard(decodedClips)
        let decodedSBVolume = try container.decodeIfPresent(Double.self, forKey: .soundboardVolume) ?? SoundboardClip.defaultVolume
        self.soundboardVolume = ControlStripLevel.clamp(decodedSBVolume)
        let decodedPinnedSlots = try container.decodeIfPresent([SlotCoordinate].self, forKey: .pinnedStripSlots) ?? []
        self.pinnedStripSlots = PinnedStripSlots.sanitize(decodedPinnedSlots, in: decodedPages)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(pages, forKey: .pages)
        try container.encode(emojiSlides, forKey: .emojiSlides)
        try container.encode(gestureConfig, forKey: .gestureConfig)
        try container.encode(settings, forKey: .settings)
        try container.encode(pinnedTimeTravelBundleIDs, forKey: .pinnedTimeTravelBundleIDs)
        try container.encode(flows, forKey: .flows)
        try container.encode(appDeckBindings, forKey: .appDeckBindings)
        try container.encode(Array(snippets.prefix(TextSnippet.maxLibraryCount)), forKey: .snippets)
        try container.encode(SoundboardCatalogValidator.sanitizeBoard(soundboardClips), forKey: .soundboardClips)
        try container.encode(ControlStripLevel.clamp(soundboardVolume), forKey: .soundboardVolume)
        try container.encode(PinnedStripSlots.sanitize(pinnedStripSlots, in: pages), forKey: .pinnedStripSlots)
    }

    private static func sanitizeAppDeckBindings(_ bindings: [String: UUID]) -> [String: UUID] {
        var cleaned: [String: UUID] = [:]
        for key in bindings.keys.sorted() {
            guard let pageID = bindings[key] else { continue }
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let duplicateKeys = cleaned.keys.filter { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
            for dup in duplicateKeys {
                cleaned.removeValue(forKey: dup)
            }
            cleaned[trimmed] = pageID
        }
        return cleaned
    }

    public mutating func bumpRevision() {
        revision += 1
        updatedAt = Date()
    }

    // MARK: - App-Aware Deck Binding Helpers

    public func page(withID id: UUID) -> BarPage? {
        pages.first(where: { $0.id == id })
    }

    public func pageIndex(forID id: UUID) -> Int? {
        pages.firstIndex(where: { $0.id == id })
    }

    /// Binds `bundleIdentifier` to `pageID` (at most one page per bundle identifier; replaces any previous binding).
    /// Passing `nil` removes any binding for `bundleIdentifier`.
    public mutating func setAppDeckBinding(bundleIdentifier: String, pageID: UUID?) {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let matchingKeys = appDeckBindings.keys.filter {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        for key in matchingKeys {
            appDeckBindings.removeValue(forKey: key)
        }
        if let pageID, pages.contains(where: { $0.id == pageID }) {
            appDeckBindings[trimmed] = pageID
        }
    }

    public mutating func removeAppDeckBinding(bundleIdentifier: String) {
        setAppDeckBinding(bundleIdentifier: bundleIdentifier, pageID: nil)
    }

    public mutating func clearAppDeckBindings(forPageID pageID: UUID) {
        appDeckBindings = appDeckBindings.filter { $0.value != pageID }
    }

    /// Sorted bundle identifiers bound to `pageID`. Returns empty if `pageID` does not exist in `pages`.
    public func boundBundleIdentifiers(forPageID pageID: UUID) -> [String] {
        guard pages.contains(where: { $0.id == pageID }) else { return [] }
        return appDeckBindings
            .compactMap { key, val in val == pageID ? key : nil }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Resolves the `BarPage` bound to `bundleIdentifier`, or `nil` if unbound or if the target page was deleted.
    public func boundPage(forBundleIdentifier bundleIdentifier: String?) -> BarPage? {
        guard let raw = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let matchedPageID: UUID? = {
            if let exact = appDeckBindings[raw] {
                return exact
            }
            return appDeckBindings
                .sorted { $0.key < $1.key }
                .first { $0.key.caseInsensitiveCompare(raw) == .orderedSame }?
                .value
        }()
        guard let pageID = matchedPageID else {
            return nil
        }
        return pages.first(where: { $0.id == pageID })
    }

    /// Resolves the bound page ID for `bundleIdentifier`, ignoring bindings to deleted pages.
    public func boundPageID(forBundleIdentifier bundleIdentifier: String?) -> UUID? {
        boundPage(forBundleIdentifier: bundleIdentifier)?.id
    }

    /// Resolves which page ID should be visible when `bundleIdentifier` becomes frontmost:
    /// - Returns the bound page's `id` if `isFollowingFrontmostApp` is `true` and the bound page exists in `pages`.
    /// - Keeps `currentPageID` if no binding exists, the bound page was deleted, or manual page pinning is active.
    public func resolvePageID(
        forFrontmostBundleIdentifier bundleIdentifier: String?,
        currentPageID: UUID,
        isFollowingFrontmostApp: Bool = true
    ) -> UUID {
        guard isFollowingFrontmostApp,
              let page = boundPage(forBundleIdentifier: bundleIdentifier) else {
            return currentPageID
        }
        return page.id
    }

    /// Best-effort display name for a bundle identifier on companion devices using synced metadata.
    public func resolvedAppDisplayName(
        forBundleIdentifier bundleIdentifier: String,
        preferredAppName: String? = nil,
        recentApps: [RecentAppEntry] = [],
        catalogApps: [InstalledAppSummary] = []
    ) -> String {
        if let preferred = preferredAppName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty {
            return preferred
        }
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if let recent = recentApps.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(trimmed) == .orderedSame }),
           !recent.appName.isEmpty {
            return recent.appName
        }
        if let catalog = catalogApps.first(where: { $0.bundleIdentifier.caseInsensitiveCompare(trimmed) == .orderedSame }),
           !catalog.appName.isEmpty {
            return catalog.appName
        }
        for page in pages {
            for slot in page.slots.compactMap({ $0 }) {
                if case .macApp(let bid, let appName, _, _) = slot.kind,
                   bid.caseInsensitiveCompare(trimmed) == .orderedSame,
                   !appName.isEmpty {
                    return appName
                }
            }
        }
        for flow in flows {
            for step in flow.steps {
                switch step.kind {
                case .launchOrActivateApp(let bid, let appName, _):
                    if bid.caseInsensitiveCompare(trimmed) == .orderedSame, !appName.isEmpty {
                        return appName
                    }
                case .waitForAppFrontmost(let bid, let appName, _):
                    if bid.caseInsensitiveCompare(trimmed) == .orderedSame, let appName, !appName.isEmpty {
                        return appName
                    }
                case .systemAction(_, let targetBid, let targetAppName):
                    if let targetBid, targetBid.caseInsensitiveCompare(trimmed) == .orderedSame,
                       let targetAppName, !targetAppName.isEmpty {
                        return targetAppName
                    }
                case .delay, .unsupported:
                    break
                }
            }
        }
        let tail = trimmed.split(separator: ".").last.map(String.init) ?? trimmed
        if tail == tail.lowercased(), let first = tail.first {
            return String(first).uppercased() + tail.dropFirst()
        }
        return tail
    }

    // MARK: - Text Snippet Profile Helpers

    public var canAddMoreSnippets: Bool {
        snippets.count < TextSnippet.maxLibraryCount
    }

    public func snippet(withID id: UUID) -> TextSnippet? {
        snippets.first(where: { $0.id == id })
    }

    @discardableResult
    public mutating func upsertSnippet(_ snippet: TextSnippet) -> Bool {
        let clampedBody = TextSnippet.clampBody(snippet.body)
        guard !clampedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let normalized = TextSnippet(
            id: snippet.id,
            title: TextSnippet.resolvedTitle(title: snippet.title, body: clampedBody, language: settings.language),
            body: clampedBody,
            insertMode: snippet.insertMode,
            updatedAt: snippet.updatedAt
        )
        if let idx = snippets.firstIndex(where: { $0.id == normalized.id }) {
            snippets[idx] = normalized
            return true
        }
        guard snippets.count < TextSnippet.maxLibraryCount else {
            return false
        }
        snippets.append(normalized)
        return true
    }

    @discardableResult
    public mutating func setSnippetInsertMode(id: UUID, mode: SnippetInsertMode) -> Bool {
        guard let idx = snippets.firstIndex(where: { $0.id == id }) else {
            return false
        }
        snippets[idx].insertMode = mode
        snippets[idx].updatedAt = Date()
        return true
    }

    @discardableResult
    public mutating func renameSnippet(id: UUID, title: String) -> Bool {
        guard let idx = snippets.firstIndex(where: { $0.id == id }) else {
            return false
        }
        snippets[idx].title = TextSnippet.resolvedTitle(
            title: title,
            body: snippets[idx].body,
            language: settings.language
        )
        snippets[idx].updatedAt = Date()
        return true
    }

    @discardableResult
    public mutating func deleteSnippet(id: UUID) -> Bool {
        let before = snippets.count
        snippets.removeAll { $0.id == id }
        return snippets.count != before
    }

    // MARK: - Action Flow Profile Helpers

    public func flow(withID id: UUID) -> ActionFlow? {
        flows.first(where: { $0.id == id })
    }

    public func makeBarItem(for flow: ActionFlow, id: UUID = UUID()) -> BarItem {
        BarItem(
            id: id,
            kind: .flow(
                flowID: flow.id,
                titleSnapshot: flow.name,
                emoji: flow.emoji,
                backgroundHex: flow.backgroundHex,
                stepCountSnapshot: flow.enabledStepCount
            )
        )
    }

    public mutating func upsertFlow(_ flow: ActionFlow) {
        if let idx = flows.firstIndex(where: { $0.id == flow.id }) {
            flows[idx] = flow
        } else {
            flows.append(flow)
        }
        syncFlowBarItems(for: flow)
    }

    @discardableResult
    public mutating func deleteFlow(id: UUID) -> Bool {
        let beforeCount = flows.count
        flows.removeAll { $0.id == id }
        var removedFromSlot = false
        for pIdx in pages.indices {
            for sIdx in pages[pIdx].slots.indices {
                if pages[pIdx].slots[sIdx]?.flowID == id {
                    pages[pIdx].slots[sIdx] = nil
                    removedFromSlot = true
                }
            }
        }
        if removedFromSlot {
            pinnedStripSlots = PinnedStripSlots.sanitize(pinnedStripSlots, in: pages)
        }
        return flows.count != beforeCount || removedFromSlot
    }

    public mutating func moveFlow(from sourceIndex: Int, to destinationIndex: Int) {
        guard flows.indices.contains(sourceIndex) else { return }
        let item = flows.remove(at: sourceIndex)
        let boundedDest = min(max(0, destinationIndex), flows.count)
        flows.insert(item, at: boundedDest)
    }

    public mutating func moveFlows(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let validOffsets = offsets.filter { flows.indices.contains($0) }
        guard !validOffsets.isEmpty else { return }
        let moving = validOffsets.map { flows[$0] }
        for idx in validOffsets.sorted(by: >) {
            flows.remove(at: idx)
        }
        let adjustedDestination = destination - validOffsets.filter { $0 < destination }.count
        let boundedDest = min(max(0, adjustedDestination), flows.count)
        flows.insert(contentsOf: moving, at: boundedDest)
    }

    private mutating func syncFlowBarItems(for flow: ActionFlow) {
        for pIdx in pages.indices {
            for sIdx in pages[pIdx].slots.indices {
                guard let existing = pages[pIdx].slots[sIdx],
                      existing.flowID == flow.id else { continue }
                pages[pIdx].slots[sIdx] = makeBarItem(for: flow, id: existing.id)
            }
        }
    }

    // MARK: - Local Soundboard Profile Helpers (Round 3)

    public var canAddMoreSoundboardClips: Bool {
        soundboardClips.count < SoundboardClip.maxBoardCount
    }

    public func soundboardClip(withID id: UUID) -> SoundboardClip? {
        soundboardClips.first(where: { $0.id == id })
    }

    public func makeBarItem(for clip: SoundboardClip, id: UUID = UUID()) -> BarItem {
        BarItem(
            id: id,
            kind: .soundboard(
                soundID: clip.id,
                titleSnapshot: clip.name,
                emoji: clip.emoji,
                backgroundHex: clip.backgroundHex
            )
        )
    }

    @discardableResult
    public mutating func addSoundboardClip(_ clip: SoundboardClip) -> Result<SoundboardClip, SoundboardValidationError> {
        let validation = SoundboardCatalogValidator.validateAddition(
            filePath: clip.filePath,
            durationSeconds: clip.durationSeconds,
            existingClips: soundboardClips
        )
        switch validation {
        case .failure(let error):
            return .failure(error)
        case .success:
            soundboardClips.append(clip)
            syncSoundboardBarItems(for: clip)
            return .success(clip)
        }
    }

    @discardableResult
    public mutating func updateSoundboardClip(
        id: UUID,
        name: String? = nil,
        emoji: String? = nil,
        backgroundHex: String? = nil
    ) -> Bool {
        guard let idx = soundboardClips.firstIndex(where: { $0.id == id }) else {
            return false
        }
        var updated = soundboardClips[idx]
        if let name {
            updated.name = SoundboardClip.sanitizeName(name, fallback: updated.name)
        }
        if let emoji {
            let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                updated.emoji = String(trimmed.prefix(2))
            }
        }
        if let backgroundHex, !backgroundHex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.backgroundHex = backgroundHex
        }
        soundboardClips[idx] = updated
        syncSoundboardBarItems(for: updated)
        return true
    }

    @discardableResult
    public mutating func deleteSoundboardClip(id: UUID) -> Bool {
        let beforeCount = soundboardClips.count
        soundboardClips.removeAll { $0.id == id }
        var removedFromSlot = false
        for pIdx in pages.indices {
            for sIdx in pages[pIdx].slots.indices {
                if pages[pIdx].slots[sIdx]?.soundID == id {
                    pages[pIdx].slots[sIdx] = nil
                    removedFromSlot = true
                }
            }
        }
        if removedFromSlot {
            pinnedStripSlots = PinnedStripSlots.sanitize(pinnedStripSlots, in: pages)
        }
        return soundboardClips.count != beforeCount || removedFromSlot
    }

    private mutating func syncSoundboardBarItems(for clip: SoundboardClip) {
        for pIdx in pages.indices {
            for sIdx in pages[pIdx].slots.indices {
                guard let existing = pages[pIdx].slots[sIdx],
                      existing.soundID == clip.id else { continue }
                pages[pIdx].slots[sIdx] = makeBarItem(for: clip, id: existing.id)
            }
        }
    }

    // MARK: - Slot Reference Resolution & Editing Helpers (Round 3)

    /// Resolves a `.slotReference` (or concrete `BarItem`) against this profile, safely detecting
    /// deleted pages, cleared/missing slots, out-of-bounds indices, self-references, and cycles.
    public func resolveBarItem(_ item: BarItem, from origin: SlotCoordinate? = nil) -> SlotReferenceResolution {
        switch item.kind {
        case .slotReference(let targetPageID, let targetSlotIndex):
            return resolveSlotReference(
                targetPageID: targetPageID,
                targetSlotIndex: targetSlotIndex,
                from: origin
            )
        default:
            if let origin,
               let pIdx = pages.firstIndex(where: { $0.id == origin.pageID }) {
                let page = pages[pIdx]
                return .resolved(
                    pageID: page.id,
                    pageIndex: pIdx,
                    pageTitle: page.title,
                    pageEmoji: page.iconEmoji,
                    slotIndex: origin.slotIndex,
                    item: item
                )
            }
            return .resolved(
                pageID: origin?.pageID ?? UUID(),
                pageIndex: 0,
                pageTitle: "",
                pageEmoji: "🍫",
                slotIndex: origin?.slotIndex ?? 0,
                item: item
            )
        }
    }

    public func resolveSlotReference(
        targetPageID: UUID,
        targetSlotIndex: Int,
        from origin: SlotCoordinate? = nil
    ) -> SlotReferenceResolution {
        var visited = Set<SlotCoordinate>()
        if let origin {
            visited.insert(origin)
        }
        var currentCoord = SlotCoordinate(pageID: targetPageID, slotIndex: targetSlotIndex)

        for _ in 0..<16 {
            guard !visited.contains(currentCoord) else {
                return .missing
            }
            visited.insert(currentCoord)

            guard let pageIdx = pages.firstIndex(where: { $0.id == currentCoord.pageID }) else {
                return .missing
            }
            let page = pages[pageIdx]
            guard page.slots.indices.contains(currentCoord.slotIndex),
                  let slotItem = page.slots[currentCoord.slotIndex] else {
                return .missing
            }

            if case .slotReference(let nextPageID, let nextSlotIndex) = slotItem.kind {
                currentCoord = SlotCoordinate(pageID: nextPageID, slotIndex: nextSlotIndex)
                continue
            }

            return .resolved(
                pageID: page.id,
                pageIndex: pageIdx,
                pageTitle: page.title,
                pageEmoji: page.iconEmoji,
                slotIndex: currentCoord.slotIndex,
                item: slotItem
            )
        }

        return .missing
    }

    public func displayTitle(
        for item: BarItem,
        from origin: SlotCoordinate? = nil,
        in lang: AppLanguage = .system
    ) -> String {
        switch item.kind {
        case .slotReference:
            switch resolveBarItem(item, from: origin) {
            case .resolved(_, _, _, _, _, let resolved):
                return displayTitle(for: resolved, in: lang)
            case .missing:
                return L10n.tr("原槽位已移除", "Original Missing", language: lang)
            }
        case .soundboard(let soundID, _, _, _):
            if let clip = soundboardClip(withID: soundID) {
                return clip.name
            }
            return item.displayTitle(in: lang)
        case .flow(let flowID, _, _, _, _):
            if let flow = flow(withID: flowID) {
                return flow.name
            }
            return item.displayTitle(in: lang)
        default:
            return item.displayTitle(in: lang)
        }
    }

    /// Returns concrete occupied slots that can be pointed at from `excluding` without creating cycles.
    public func availableReferenceTargets(
        excluding origin: SlotCoordinate? = nil
    ) -> [(pageIndex: Int, page: BarPage, slotIndex: Int, item: BarItem)] {
        var candidates: [(pageIndex: Int, page: BarPage, slotIndex: Int, item: BarItem)] = []
        for (pIdx, page) in pages.enumerated() {
            for (sIdx, maybeItem) in page.slots.enumerated() {
                guard let item = maybeItem else { continue }
                let coord = SlotCoordinate(pageID: page.id, slotIndex: sIdx)
                if coord == origin { continue }
                // Prefer pointing directly at concrete non-reference slots so references stay 1-hop & crystal clear.
                if item.isSlotReference { continue }
                candidates.append((pageIndex: pIdx, page: page, slotIndex: sIdx, item: item))
            }
        }
        return candidates
    }

    /// Swaps two slots on `pageIndex` and keeps any `.slotReference` pointing to those coordinates aligned.
    public mutating func swapSlots(pageIndex: Int, fromSlot: Int, toSlot: Int) {
        guard pages.indices.contains(pageIndex),
              pages[pageIndex].slots.indices.contains(fromSlot),
              pages[pageIndex].slots.indices.contains(toSlot),
              fromSlot != toSlot else { return }
        let pageID = pages[pageIndex].id
        pages[pageIndex].slots.swapAt(fromSlot, toSlot)

        for pIdx in pages.indices {
            for sIdx in pages[pIdx].slots.indices {
                guard let slot = pages[pIdx].slots[sIdx],
                      case .slotReference(let targetPageID, let targetSlotIndex) = slot.kind,
                      targetPageID == pageID else { continue }
                let remappedSlot: Int?
                if targetSlotIndex == fromSlot {
                    remappedSlot = toSlot
                } else if targetSlotIndex == toSlot {
                    remappedSlot = fromSlot
                } else {
                    remappedSlot = nil
                }
                if let remappedSlot {
                    pages[pIdx].slots[sIdx] = BarItem(
                        id: slot.id,
                        kind: .slotReference(targetPageID: pageID, targetSlotIndex: remappedSlot)
                    )
                }
            }
        }

        pinnedStripSlots = PinnedStripSlots.remapAfterSwap(
            coordinates: pinnedStripSlots,
            pageID: pageID,
            fromSlot: fromSlot,
            toSlot: toSlot,
            in: pages
        )
    }

    // MARK: - Persistent Strip Pinned Tiles & Tile Lookup Helpers (Round 5)

    public var activePinnedStripSlots: [SlotCoordinate] {
        PinnedStripSlots.sanitize(pinnedStripSlots, in: pages)
    }

    public var activePinnedStripCount: Int {
        activePinnedStripSlots.count
    }

    public var canPinMoreSlotsToStrip: Bool {
        activePinnedStripCount < PinnedStripSlots.maxPinnedCount
    }

    public func isSlotPinnedToStrip(_ coordinate: SlotCoordinate) -> Bool {
        activePinnedStripSlots.contains(coordinate)
    }

    public func isSlotPinnedToStrip(pageIndex: Int, slotIndex: Int) -> Bool {
        guard pages.indices.contains(pageIndex) else { return false }
        return isSlotPinnedToStrip(SlotCoordinate(pageID: pages[pageIndex].id, slotIndex: slotIndex))
    }

    @discardableResult
    public mutating func pinSlotToStrip(_ coordinate: SlotCoordinate) -> Bool {
        let outcome = PinnedStripSlots.pin(coordinate, into: pinnedStripSlots, in: pages)
        pinnedStripSlots = outcome.updated
        return outcome.didPin
    }

    @discardableResult
    public mutating func unpinSlotFromStrip(_ coordinate: SlotCoordinate) -> Bool {
        let outcome = PinnedStripSlots.unpin(coordinate, from: pinnedStripSlots, in: pages)
        pinnedStripSlots = outcome.updated
        return outcome.didUnpin
    }

    @discardableResult
    public mutating func togglePinSlotToStrip(_ coordinate: SlotCoordinate) -> Bool {
        if isSlotPinnedToStrip(coordinate) {
            return unpinSlotFromStrip(coordinate)
        }
        return pinSlotToStrip(coordinate)
    }

    public mutating func prunePinnedStripSlots() {
        pinnedStripSlots = PinnedStripSlots.sanitize(pinnedStripSlots, in: pages)
    }

    public func resolvedPinnedStripSlots() -> [ResolvedPinnedStripSlot] {
        PinnedStripSlots.resolve(pinnedStripSlots, in: pages)
    }

    public func barItem(at coordinate: SlotCoordinate) -> BarItem? {
        guard let page = pages.first(where: { $0.id == coordinate.pageID }),
              page.slots.indices.contains(coordinate.slotIndex) else {
            return nil
        }
        return page.slots[coordinate.slotIndex]
    }

    public func locateBarItem(
        withID tileID: UUID
    ) -> (pageIndex: Int, slotIndex: Int, coordinate: SlotCoordinate, item: BarItem)? {
        for (pIdx, page) in pages.enumerated() {
            for (sIdx, maybeItem) in page.slots.enumerated() {
                guard let item = maybeItem, item.id == tileID else { continue }
                let coord = SlotCoordinate(pageID: page.id, slotIndex: sIdx)
                return (pageIndex: pIdx, slotIndex: sIdx, coordinate: coord, item: item)
            }
        }
        return nil
    }

    public var referencedAppBundleIdentifiers: Set<String> {
        var result = Set<String>()
        for page in pages {
            for (slotIdx, maybeSlot) in page.slots.enumerated() {
                guard let slot = maybeSlot else { continue }
                if let bundleID = slot.bundleIdentifier {
                    result.insert(bundleID)
                } else if slot.isSlotReference,
                          case .resolved(_, _, _, _, _, let resolved) = resolveBarItem(
                              slot,
                              from: SlotCoordinate(pageID: page.id, slotIndex: slotIdx)
                          ),
                          let bundleID = resolved.bundleIdentifier {
                    result.insert(bundleID)
                }
            }
        }
        for flow in flows {
            result.formUnion(flow.referencedBundleIdentifiers)
        }
        for (bundleID, pageID) in appDeckBindings where pages.contains(where: { $0.id == pageID }) {
            let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.insert(trimmed)
            }
        }
        return result
    }
}

// MARK: - Companion App-Aware Deck Follower State

/// Tracks visible Chocolate Bar page selection and auto-follow vs. manual-pin mode across iPhone, iPad, and Watch.
public struct AppDeckFollowerState: Equatable, Sendable {
    public private(set) var currentPageIndex: Int
    public private(set) var currentPageID: UUID?
    public private(set) var isFollowingFrontmostApp: Bool

    public init(
        currentPageIndex: Int = 0,
        currentPageID: UUID? = nil,
        isFollowingFrontmostApp: Bool = true
    ) {
        self.currentPageIndex = max(0, currentPageIndex)
        self.currentPageID = currentPageID
        self.isFollowingFrontmostApp = isFollowingFrontmostApp
    }

    public mutating func syncCurrentPage(with profile: ChocliftWorkspaceProfile) {
        guard !profile.pages.isEmpty else {
            currentPageIndex = 0
            currentPageID = nil
            return
        }
        if let id = currentPageID,
           let existingIdx = profile.pages.firstIndex(where: { $0.id == id }) {
            currentPageIndex = existingIdx
            return
        }
        let clamped = min(max(0, currentPageIndex), profile.pages.count - 1)
        currentPageIndex = clamped
        currentPageID = profile.pages[clamped].id
    }

    /// Updates the visible page when the frontmost Mac app changes.
    /// Does not switch pages if manually pinned, if no deck is bound to `bundleIdentifier`, or if the bound page was deleted.
    public mutating func handleFrontmostAppChanged(
        _ bundleIdentifier: String?,
        in profile: ChocliftWorkspaceProfile
    ) {
        syncCurrentPage(with: profile)
        guard isFollowingFrontmostApp,
              let bound = profile.boundPage(forBundleIdentifier: bundleIdentifier),
              let idx = profile.pages.firstIndex(where: { $0.id == bound.id }) else {
            return
        }
        currentPageIndex = idx
        currentPageID = bound.id
    }

    /// Reconciles page state when the workspace profile updates (e.g. on initial connection or after Mac Studio edits).
    public mutating func handleProfileUpdated(
        _ profile: ChocliftWorkspaceProfile,
        frontmostBundleIdentifier: String?
    ) {
        syncCurrentPage(with: profile)
        guard isFollowingFrontmostApp,
              let bound = profile.boundPage(forBundleIdentifier: frontmostBundleIdentifier),
              let idx = profile.pages.firstIndex(where: { $0.id == bound.id }) else {
            return
        }
        currentPageIndex = idx
        currentPageID = bound.id
    }

    /// Pins the companion to a manually chosen page index until `followFrontmostApp` is invoked again.
    public mutating func selectManualPage(index: Int, in profile: ChocliftWorkspaceProfile) {
        isFollowingFrontmostApp = false
        guard !profile.pages.isEmpty else {
            currentPageIndex = 0
            currentPageID = nil
            return
        }
        let clamped = min(max(0, index), profile.pages.count - 1)
        currentPageIndex = clamped
        currentPageID = profile.pages[clamped].id
    }

    /// Steps backward/forward manually and pins to that page until `followFrontmostApp` is invoked again.
    public mutating func stepManualPage(by delta: Int, in profile: ChocliftWorkspaceProfile) {
        guard !profile.pages.isEmpty else {
            isFollowingFrontmostApp = false
            currentPageIndex = 0
            currentPageID = nil
            return
        }
        syncCurrentPage(with: profile)
        let count = profile.pages.count
        let next = (currentPageIndex + delta + count) % count
        selectManualPage(index: next, in: profile)
    }

    /// Unpins manual page lock and resumes following the frontmost Mac app immediately.
    public mutating func followFrontmostApp(
        frontmostBundleIdentifier: String?,
        in profile: ChocliftWorkspaceProfile
    ) {
        isFollowingFrontmostApp = true
        handleFrontmostAppChanged(frontmostBundleIdentifier, in: profile)
    }
}

// MARK: - Device & Catalog Metadata

public enum DevicePlatform: String, Codable, CaseIterable, Sendable {
    case iPhone = "iPhone"
    case iPad = "iPad"
    case appleWatch = "Apple Watch"
    case mac = "Mac"

    public var sfSymbol: String {
        switch self {
        case .iPhone:
            return "iphone.gen3.landscape"
        case .iPad:
            return "ipad.landscape"
        case .appleWatch:
            return "applewatch"
        case .mac:
            return "laptopcomputer"
        }
    }
}

public struct PairedDeviceRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var deviceID: String
    public var deviceName: String
    public var platform: DevicePlatform
    public var authToken: String
    public var pairedAt: Date
    public var lastSeenAt: Date
    public var isCurrentlyConnected: Bool
    public var activeLink: CompanionLinkKind?

    public var id: String { deviceID }

    public init(
        deviceID: String,
        deviceName: String,
        platform: DevicePlatform,
        authToken: String,
        pairedAt: Date = Date(),
        lastSeenAt: Date = Date(),
        isCurrentlyConnected: Bool = false,
        activeLink: CompanionLinkKind? = nil
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.authToken = authToken
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
        self.isCurrentlyConnected = isCurrentlyConnected
        self.activeLink = activeLink
    }
}

public struct InstalledAppSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var bundleIdentifier: String
    public var appName: String
    public var appPath: String
    public var iconPNGData: Data?

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, appName: String, appPath: String, iconPNGData: Data? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.appPath = appPath
        self.iconPNGData = iconPNGData
    }
}

public struct InstalledShortcutSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var name: String
    public var id: String { name }

    public init(name: String) {
        self.name = name
    }
}

// MARK: - Rich Default Factory

public enum ChocliftDefaults {
    public static let bonjourServiceType = "_choclift._tcp"
    public static let defaultTCPPort: UInt16 = 54821
    public static let protocolVersion = 3
    public static let orcaStatusMinProtocolVersion = 3

    public static func makeDefaultGestureConfiguration() -> GestureConfiguration {
        GestureConfiguration(
            isGlobalOverlayEnabled: true,
            bindings: [
                GestureBinding(gesture: .twoFingerSwipeUp, action: .maximizeWindow, isEnabled: true),
                GestureBinding(gesture: .twoFingerSwipeDown, action: .minimizeWindow, isEnabled: true),
                GestureBinding(gesture: .twoFingerSwipeLeft, action: .snapWindowLeft, isEnabled: true),
                GestureBinding(gesture: .twoFingerSwipeRight, action: .snapWindowRight, isEnabled: true),
                GestureBinding(gesture: .threeFingerPinchIn, action: .copySelection, isEnabled: true),
                GestureBinding(gesture: .threeFingerPinchOut, action: .pasteClipboard, isEnabled: true),
                GestureBinding(gesture: .twoFingerDoubleTap, action: .undoAction, isEnabled: true),
                GestureBinding(gesture: .threeFingerSwipeUp, action: .missionControl, isEnabled: true),
                GestureBinding(gesture: .threeFingerSwipeDown, action: .showDesktop, isEnabled: true)
            ]
        )
    }

    public static func makeDefaultEmojiSlides() -> [EmojiSlide] {
        [
            EmojiSlide(index: 0, title: "Favorites", iconEmoji: "⭐️", emojis: ["👍", "🔥", "✨", "❤️", "😂", "🙌", "🚀", "🍫"]),
            EmojiSlide(index: 1, title: "Work & Status", iconEmoji: "💼", emojis: ["✅", "👀", "📌", "🎯", "💡", "⚡️", "🚧", "📅"]),
            EmojiSlide(index: 2, title: "Reactions", iconEmoji: "😄", emojis: ["🥳", "🥹", "🤔", "😎", "🤯", "🫡", "🤝", "🙏"]),
            EmojiSlide(index: 3, title: "Coding & Tech", iconEmoji: "💻", emojis: ["🐛", "🛠️", "📦", "🧪", "🔒", "📈", "🤖", "⌨️"]),
            EmojiSlide(index: 4, title: "Arrows & Marks", iconEmoji: "➡️", emojis: ["➡️", "⬅️", "⬆️", "⬇️", "⚠️", "❗️", "❓", "💯"]),
            EmojiSlide(index: 5, title: "Hands", iconEmoji: "👋", emojis: ["👋", "👏", "✌️", "🤞", "🫶", "💪", "✍️", "👆"]),
            EmojiSlide(index: 6, title: "Sweet & Cafe", iconEmoji: "☕️", emojis: ["🍫", "☕️", "🍵", "🥐", "🍩", "🍪", "🍓", "🥂"]),
            EmojiSlide(index: 7, title: "Vibes", iconEmoji: "🌈", emojis: ["🌟", "🌈", "☀️", "🌙", "🎵", "🎬", "🏆", "💎"])
        ]
    }

    public static func makeDefaultPages() -> [BarPage] {
        let page1 = BarPage(
            index: 0,
            title: "Daily",
            iconEmoji: "🍫",
            slots: [
                BarItem(kind: .macApp(bundleIdentifier: "com.apple.finder", appName: "Finder", fallbackSymbol: "face.smiling")),
                BarItem(kind: .macApp(bundleIdentifier: "com.apple.Safari", appName: "Safari", fallbackSymbol: "safari.fill")),
                BarItem(kind: .macApp(bundleIdentifier: "com.apple.Notes", appName: "Notes", fallbackSymbol: "note.text")),
                BarItem(kind: .macApp(bundleIdentifier: "com.apple.iCal", appName: "Calendar", fallbackSymbol: "calendar")),
                BarItem(kind: .macApp(bundleIdentifier: "com.apple.Music", appName: "Music", fallbackSymbol: "music.note")),
                BarItem(kind: .macApp(bundleIdentifier: "com.apple.MobileSMS", appName: "Messages", fallbackSymbol: "message.fill")),
                BarItem(kind: .website(url: "https://www.youtube.com", title: "YouTube", emoji: "▶️", backgroundHex: "#FFF1EC", switchExistingTab: true)),
                BarItem(kind: .shortcut(shortcutName: "Morning Workflow", emoji: "⚡️", backgroundHex: "#F3EEFF"))
            ]
        )

        let page2 = BarPage(
            index: 1,
            title: "Workspace",
            iconEmoji: "🚀",
            slots: [
                BarItem(kind: .macApp(bundleIdentifier: "com.apple.Terminal", appName: "Terminal", fallbackSymbol: "terminal.fill")),
                BarItem(kind: .macApp(bundleIdentifier: "com.apple.dt.Xcode", appName: "Xcode", fallbackSymbol: "hammer.fill")),
                BarItem(kind: .macApp(bundleIdentifier: "com.apple.mail", appName: "Mail", fallbackSymbol: "envelope.fill")),
                BarItem(kind: .macApp(bundleIdentifier: "com.apple.reminders", appName: "Reminders", fallbackSymbol: "checklist")),
                BarItem(kind: .website(url: "https://github.com", title: "GitHub", emoji: "🐙", backgroundHex: "#EDF6FF", switchExistingTab: true)),
                BarItem(kind: .website(url: "https://www.figma.com", title: "Figma", emoji: "🎨", backgroundHex: "#FFF6E3", switchExistingTab: true)),
                BarItem(kind: .systemAction(action: .snapWindowLeft)),
                BarItem(kind: .systemAction(action: .snapWindowRight))
            ]
        )

        let page3 = BarPage(
            index: 2,
            title: "Quick Actions",
            iconEmoji: "⚡️",
            slots: [
                BarItem(kind: .systemAction(action: .maximizeWindow)),
                BarItem(kind: .systemAction(action: .minimizeWindow)),
                BarItem(kind: .systemAction(action: .copySelection)),
                BarItem(kind: .systemAction(action: .pasteClipboard)),
                BarItem(kind: .systemAction(action: .screenshotInteractive)),
                BarItem(kind: .systemAction(action: .missionControl)),
                BarItem(kind: .systemAction(action: .mediaPlayPause)),
                BarItem(kind: .systemAction(action: .volumeMute))
            ]
        )

        let extraMeta: [(Int, String, String)] = [
            (3, "Web & Docs", "🌐"),
            (4, "Shortcuts", "🔮"),
            (5, "Creative", "🎨"),
            (6, "Media", "🎧"),
            (7, "Focus", "🌙")
        ]

        var allPages = [page1, page2, page3]
        for (idx, title, emoji) in extraMeta {
            allPages.append(BarPage(index: idx, title: title, iconEmoji: emoji))
        }
        return allPages
    }

    public static func makeDefaultProfile() -> ChocliftWorkspaceProfile {
        ChocliftWorkspaceProfile(
            revision: 1,
            updatedAt: Date(),
            pages: makeDefaultPages(),
            emojiSlides: makeDefaultEmojiSlides(),
            gestureConfig: makeDefaultGestureConfiguration(),
            settings: CompanionSettings(),
            pinnedTimeTravelBundleIDs: ["com.apple.finder", "com.apple.Safari"]
        )
    }
}
