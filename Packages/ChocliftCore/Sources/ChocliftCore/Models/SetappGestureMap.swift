import Foundation

public enum SetappFingerCount: Int, Codable, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case one = 1
    case two = 2
    case three = 3
    case four = 4

    public var id: Int { rawValue }
    public var count: Int { rawValue }

    public var identifierWord: String {
        switch self {
        case .one: return "one"
        case .two: return "two"
        case .three: return "three"
        case .four: return "four"
        }
    }

    public init?(touchCount: Int) {
        self.init(rawValue: touchCount)
    }
}

public enum SetappSwipeDirection: String, Codable, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case up
    case down

    public var id: String { rawValue }
}

public enum SetappGestureEffect: String, Codable, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case minimizeApp = "minimize_app"
    case maximizeApp = "maximize_app"
    case copySelection = "copy_selection"
    case pasteClipboard = "paste_clipboard"

    public var id: String { rawValue }

    public var titleZh: String {
        switch self {
        case .minimizeApp:
            return "最小化（隐藏）应用"
        case .maximizeApp:
            return "最大化应用"
        case .copySelection:
            return "复制到剪贴板"
        case .pasteClipboard:
            return "从剪贴板粘贴"
        }
    }

    public var titleEn: String {
        switch self {
        case .minimizeApp:
            return "Minimize (Hide) App"
        case .maximizeApp:
            return "Maximize App"
        case .copySelection:
            return "Copy to Clipboard"
        case .pasteClipboard:
            return "Paste from Clipboard"
        }
    }

    public func title(in language: AppLanguage = .system) -> String {
        L10n.tr(titleZh, titleEn, language: language)
    }

    public var sectionTitleZh: String {
        switch self {
        case .minimizeApp, .maximizeApp:
            return SetappGestureMap.windowSectionTitleZh
        case .copySelection, .pasteClipboard:
            return SetappGestureMap.clipboardSectionTitleZh
        }
    }

    public var sectionTitleEn: String {
        switch self {
        case .minimizeApp, .maximizeApp:
            return SetappGestureMap.windowSectionTitleEn
        case .copySelection, .pasteClipboard:
            return SetappGestureMap.clipboardSectionTitleEn
        }
    }

    public func sectionTitle(in language: AppLanguage = .system) -> String {
        L10n.tr(sectionTitleZh, sectionTitleEn, language: language)
    }
}

public struct SetappGestureEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let fingers: SetappFingerCount
    public let direction: SetappSwipeDirection
    public let effect: SetappGestureEffect
    public let titleZh: String
    public let titleEn: String

    public var id: String {
        SetappGestureMap.remoteIdentifier(fingers: fingers, direction: direction)
    }

    public init(
        fingers: SetappFingerCount,
        direction: SetappSwipeDirection,
        effect: SetappGestureEffect,
        titleZh: String,
        titleEn: String
    ) {
        self.fingers = fingers
        self.direction = direction
        self.effect = effect
        self.titleZh = titleZh
        self.titleEn = titleEn
    }

    public func title(in language: AppLanguage = .system) -> String {
        L10n.tr(titleZh, titleEn, language: language)
    }
}

public enum SetappGestureMap {
    public static let headerTitleZh = "美味手势 🤤"
    public static let headerTitleEn = "Delicious Gestures 🤤"

    public static let windowSectionTitleZh = "窗口管理"
    public static let windowSectionTitleEn = "Window Management"

    public static let clipboardSectionTitleZh = "复制/粘贴"
    public static let clipboardSectionTitleEn = "Copy/Paste"

    public static let comingSoonTitleZh = "更多手势即将推出"
    public static let comingSoonTitleEn = "More gestures coming soon"

    public static let accessibilityNoticeZh = """
    所有手势在 choclift 栏和 App Time Travel 中均可用。请确保 choclift 在 Mac 上具有辅助功能权限（系统设置 > 隐私与安全性 > 辅助功能）

    在 macOS 27 上：系统设置 > 隐私与安全 > 设备控制和数据访问
    """

    public static let accessibilityNoticeEn = """
    All gestures are available in both the choclift bar and App Time Travel. Make sure choclift has Accessibility permission on your Mac (System Settings > Privacy & Security > Accessibility)

    On macOS 27: System Settings > Privacy & Security > Device Control and Data Access
    """

    public static func effect(
        fingers: SetappFingerCount,
        direction: SetappSwipeDirection
    ) -> SetappGestureEffect {
        switch (fingers, direction) {
        case (.one, .down), (.two, .down):
            return .minimizeApp
        case (.one, .up), (.two, .up):
            return .maximizeApp
        case (.three, .down), (.four, .down):
            return .copySelection
        case (.three, .up), (.four, .up):
            return .pasteClipboard
        }
    }

    public static func remoteIdentifier(
        fingers: SetappFingerCount,
        direction: SetappSwipeDirection
    ) -> String {
        "\(fingers.identifierWord)_finger_swipe_\(direction.rawValue)"
    }

    public static func parseRemoteIdentifier(
        _ rawIdentifier: String
    ) -> (fingers: SetappFingerCount, direction: SetappSwipeDirection)? {
        let normalized = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "one_finger_swipe_down":
            return (.one, .down)
        case "one_finger_swipe_up":
            return (.one, .up)
        case "two_finger_swipe_down":
            return (.two, .down)
        case "two_finger_swipe_up":
            return (.two, .up)
        case "three_finger_swipe_down":
            return (.three, .down)
        case "three_finger_swipe_up":
            return (.three, .up)
        case "four_finger_swipe_down":
            return (.four, .down)
        case "four_finger_swipe_up":
            return (.four, .up)
        default:
            return nil
        }
    }

    public static func effect(remoteIdentifier: String) -> SetappGestureEffect? {
        guard let parsed = parseRemoteIdentifier(remoteIdentifier) else {
            return nil
        }
        return effect(fingers: parsed.fingers, direction: parsed.direction)
    }

    public static func titleZh(
        fingers: SetappFingerCount,
        direction: SetappSwipeDirection
    ) -> String {
        switch (fingers, direction) {
        case (.one, .down):
            return "用一根手指向下滑动即可最小化（隐藏）应用。"
        case (.one, .up):
            return "用一根手指向上滑动即可最大化应用。"
        case (.two, .down):
            return "两指任意处向下滑动以最小化（隐藏）App。"
        case (.two, .up):
            return "两指任意处向上滑动以最大化 App。"
        case (.three, .down):
            return "三指任意处向下滑动以复制到剪贴板。"
        case (.three, .up):
            return "三指任意处向上滑动以从剪贴板粘贴。"
        case (.four, .down):
            return "四指任意处向下滑动以复制到剪贴板。"
        case (.four, .up):
            return "四指任意处向上滑动以从剪贴板粘贴。"
        }
    }

    public static func titleEn(
        fingers: SetappFingerCount,
        direction: SetappSwipeDirection
    ) -> String {
        switch (fingers, direction) {
        case (.one, .down):
            return "Swipe down anywhere with one finger to minimize (hide) an app."
        case (.one, .up):
            return "Swipe up anywhere with one finger to maximize an app."
        case (.two, .down):
            return "Swipe down anywhere with two fingers to minimize (hide) an app."
        case (.two, .up):
            return "Swipe up anywhere with two fingers to maximize an app."
        case (.three, .down):
            return "Swipe down anywhere with three fingers to copy content to your clipboard."
        case (.three, .up):
            return "Swipe up anywhere with three fingers to paste content from your clipboard."
        case (.four, .down):
            return "Swipe down anywhere with four fingers to copy content to your clipboard."
        case (.four, .up):
            return "Swipe up anywhere with four fingers to paste content from your clipboard."
        }
    }

    public static func title(
        fingers: SetappFingerCount,
        direction: SetappSwipeDirection,
        in language: AppLanguage = .system
    ) -> String {
        L10n.tr(
            titleZh(fingers: fingers, direction: direction),
            titleEn(fingers: fingers, direction: direction),
            language: language
        )
    }

    public static func entry(
        fingers: SetappFingerCount,
        direction: SetappSwipeDirection
    ) -> SetappGestureEntry {
        SetappGestureEntry(
            fingers: fingers,
            direction: direction,
            effect: effect(fingers: fingers, direction: direction),
            titleZh: titleZh(fingers: fingers, direction: direction),
            titleEn: titleEn(fingers: fingers, direction: direction)
        )
    }

    public static let allCombinations: [SetappGestureEntry] = SetappFingerCount.allCases.flatMap { fingers in
        [SetappSwipeDirection.down, .up].map { direction in
            entry(fingers: fingers, direction: direction)
        }
    }
}
