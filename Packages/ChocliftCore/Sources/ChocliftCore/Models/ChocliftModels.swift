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
        case .openEmojiPicker: return "face.smiling.inverse"
        }
    }

    public var accentHex: String {
        switch self {
        case .maximizeWindow, .minimizeWindow, .snapWindowLeft, .snapWindowRight, .centerWindow, .toggleFullscreen:
            return "#EDF6FF"
        case .copySelection, .pasteClipboard, .cutSelection, .undoAction, .redoAction:
            return "#F3EEFF"
        case .missionControl, .showDesktop, .screenshotInteractive, .lockScreen, .openEmojiPicker:
            return "#FFF1EC"
        case .mediaPlayPause, .mediaNext, .mediaPrevious, .volumeUp, .volumeDown, .volumeMute:
            return "#ECFAEE"
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
        case .copySelection: return L10n.tr("复制 (⌘C)", "Copy (⌘C)", language: lang)
        case .pasteClipboard: return L10n.tr("粘贴 (⌘V)", "Paste (⌘V)", language: lang)
        case .cutSelection: return L10n.tr("剪切 (⌘X)", "Cut (⌘X)", language: lang)
        case .undoAction: return L10n.tr("撤销 (⌘Z)", "Undo (⌘Z)", language: lang)
        case .redoAction: return L10n.tr("重做 (⇧⌘Z)", "Redo (⇧⌘Z)", language: lang)
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
        }
    }

    public var bundleIdentifier: String? {
        if case .macApp(let bundleID, _, _, _) = kind {
            return bundleID
        }
        return nil
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
        var normalized = Array(slots.prefix(Self.slotsPerPage))
        while normalized.count < Self.slotsPerPage {
            normalized.append(nil)
        }
        self.slots = normalized
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

    public init(
        revision: Int = 1,
        updatedAt: Date = Date(),
        pages: [BarPage],
        emojiSlides: [EmojiSlide],
        gestureConfig: GestureConfiguration,
        settings: CompanionSettings = CompanionSettings(),
        pinnedTimeTravelBundleIDs: [String] = []
    ) {
        self.revision = revision
        self.updatedAt = updatedAt
        self.pages = pages
        self.emojiSlides = emojiSlides
        self.gestureConfig = gestureConfig
        self.settings = settings
        self.pinnedTimeTravelBundleIDs = pinnedTimeTravelBundleIDs
    }

    public mutating func bumpRevision() {
        revision += 1
        updatedAt = Date()
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
    public static let protocolVersion = 2

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
